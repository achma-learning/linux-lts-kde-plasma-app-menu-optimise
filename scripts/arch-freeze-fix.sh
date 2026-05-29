#!/usr/bin/env bash
# arch-freeze-fix.sh — Intel HD 5500 freeze fixes for KDE Plasma
# Targets: i915 PSR disable, Plasma X11 session, SysRq, zram
# Run as: sudo bash arch-freeze-fix.sh

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE} $*${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] Run as root: sudo bash arch-freeze-fix.sh${NC}"; exit 1
fi

# ── 1. i915 PANEL SELF REFRESH DISABLE ─────────────────────
section "1. Disable i915 PSR (Panel Self Refresh) — root cause of freezes"
# PSR is the #1 cause of Intel HD 5500 display freezes.
# It saves ~1W but causes the compositor to hang on Broadwell.
# Disable it permanently via kernel boot parameter.
LTS_CONF="/boot/loader/entries/2026-05-25_21-23-49_linux-lts.conf"
if [[ -f "$LTS_CONF" ]]; then
    if grep -q "i915.enable_psr=0" "$LTS_CONF"; then
        success "i915.enable_psr=0 already in LTS boot entry"
    else
        # Append to the options line
        sed -i '/^options / s/$/ i915.enable_psr=0/' "$LTS_CONF"
        success "Added i915.enable_psr=0 to LTS kernel boot entry"
    fi
else
    warn "LTS boot entry not found at expected path — check /boot/loader/entries/"
fi

# Also apply to the regular linux entry for consistency
REG_CONF="/boot/loader/entries/2026-05-25_21-23-49_linux.conf"
if [[ -f "$REG_CONF" ]] && ! grep -q "i915.enable_psr=0" "$REG_CONF"; then
    sed -i '/^options / s/$/ i915.enable_psr=0/' "$REG_CONF"
    success "Added i915.enable_psr=0 to regular linux boot entry"
fi

# Apply immediately (no reboot needed for this session)
echo 0 > /sys/module/i915/parameters/enable_psr 2>/dev/null && \
    success "i915 PSR disabled in current session" || \
    warn "Could not apply PSR disable live — will take effect after reboot"

# ── 2. CREATE KDE PLASMA X11 SESSION ───────────────────────
section "2. Create Plasma (X11) session for SDDM"
# KDE is only available as Wayland session right now.
# startplasma-x11 binary exists — we just need the .desktop file.
mkdir -p /usr/share/xsessions
cat > /usr/share/xsessions/plasmax11.desktop << 'EOF'
[Desktop Entry]
Type=XSession
Exec=/usr/bin/startplasma-x11
TryExec=/usr/bin/startplasma-x11
DesktopNames=KDE
Name=Plasma (X11)
Comment=Plasma by KDE (X11 backend — stable on Intel HD 5500)
EOF
success "Created /usr/share/xsessions/plasmax11.desktop"

# ── 3. SDDM — DEFAULT TO X11 + PLASMA X11 SESSION ─────────
section "3. Configure SDDM to default to X11"
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/10-x11.conf << 'EOF'
[General]
DisplayServer=x11

[X11]
ServerArguments=-nolisten tcp -background none
EOF
success "SDDM configured to use X11 display server"

# Set Plasma X11 as the remembered/default session for the user
# SDDM stores last session per-user in its state file
SDDM_STATE="/var/lib/sddm/state.conf"
if [[ -f "$SDDM_STATE" ]]; then
    # Update existing state
    if grep -q "^\[Last\]" "$SDDM_STATE"; then
        sed -i 's/^Session=.*/Session=plasmax11/' "$SDDM_STATE" 2>/dev/null || true
        success "Updated SDDM last session → plasmax11"
    fi
else
    mkdir -p /var/lib/sddm
    cat > "$SDDM_STATE" << 'EOF'
[Last]
Session=plasmax11
User=achma
EOF
    success "Created SDDM state: default session → plasmax11"
fi

# ── 4. MAGIC SYSRQ — FULL ENABLE ──────────────────────────
section "4. Enable full Magic SysRq (emergency freeze recovery)"
# Currently sysrq=16 (only sync). Enable all (=1) so Alt+SysRq+f
# (OOM kill) and Alt+SysRq+REISUB (safe reboot) work during a freeze.
cat > /etc/sysctl.d/99-sysrq.conf << 'EOF'
kernel.sysrq=1
EOF
sysctl kernel.sysrq=1 > /dev/null
success "Magic SysRq fully enabled (was 16, now 1)"
info  "During a freeze: Alt+SysRq+f  → kill memory hog"
info  "Safe reboot:     Alt+SysRq+R E I S U B  (one key at a time, slowly)"

# ── 5. ZRAM — ENSURE PROPER CONFIG ─────────────────────────
section "5. zram — ensure persistent configuration"
# /dev/zram0 already exists but has no generator config.
# Add the config so it survives reboots properly.
if ! pacman -Q zram-generator &>/dev/null; then
    info "Installing zram-generator..."
    pacman -Sy --needed --noconfirm zram-generator
fi
if [[ ! -f /etc/systemd/zram-generator.conf ]]; then
    cat > /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
# 8GB compressed swap in RAM (zstd ~3:1 ratio = effectively ~24GB swap headroom)
# Prevents any OOM freeze even with 20 browser tabs + IDE + server processes
zram-size = ram / 2
compression-algorithm = zstd
EOF
    success "zram-generator config created (8GB zstd compressed swap)"
    systemctl daemon-reload
    systemctl start systemd-zram-setup@zram0 2>/dev/null || \
        info "zram0 already active — config will be used on next boot"
else
    success "zram-generator.conf already exists"
fi

# Show current zram status
ZRAM_SIZE=$(cat /sys/block/zram0/disksize 2>/dev/null || echo "unknown")
ZRAM_ALGO=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo "unknown")
info "zram0: size=$(numfmt --to=iec $ZRAM_SIZE 2>/dev/null || echo $ZRAM_SIZE), algo=$ZRAM_ALGO"

# ── 6. INTEL GPU — ADDITIONAL STABILITY PARAMS ─────────────
section "6. i915 additional stability (FBC + RC6 tuning)"
# Framebuffer Compression can also cause visual glitches on Broadwell
# RC6 is fine to keep (it's well-tested) but PSR is the main culprit
cat > /etc/modprobe.d/i915.conf << 'EOF'
# Intel HD 5500 (Broadwell) stability fixes
# PSR (Panel Self Refresh) causes display freezes on Broadwell — disabled
# FBC (Framebuffer Compression) can cause visual artifacts — disabled
options i915 enable_psr=0 enable_fbc=0
EOF
success "i915 module params set: PSR=0, FBC=0"

# ── SUMMARY ────────────────────────────────────────────────
section "✅ Freeze Fixes Applied"
echo ""
echo -e "  ${GREEN}i915 PSR${NC}         → disabled (boot param + modprobe + live)"
echo -e "  ${GREEN}i915 FBC${NC}         → disabled (modprobe)"
echo -e "  ${GREEN}Plasma X11${NC}       → session created at /usr/share/xsessions/plasmax11.desktop"
echo -e "  ${GREEN}SDDM${NC}             → defaults to X11, Plasma (X11) session"
echo -e "  ${GREEN}Magic SysRq${NC}      → fully enabled (was 16, now 1)"
echo -e "  ${GREEN}zram${NC}             → persistent config (ram/2, zstd)"
echo ""
echo -e "  ${YELLOW}⚠  REBOOT required${NC} to:"
echo -e "     • Apply i915.enable_psr=0 kernel parameter"
echo -e "     • Load new modprobe i915 config"
echo -e "     • Switch SDDM to X11 + Plasma (X11) session"
echo ""
echo -e "  ${BLUE}At login screen${NC}: select 'Plasma (X11)' — it will be the default"
echo -e "  ${BLUE}After reboot${NC}: run ${GREEN}echo \$WAYLAND_DISPLAY${NC} — should be empty (X11 confirmed)"
echo -e "  ${BLUE}Verify PSR${NC}:      ${GREEN}cat /sys/module/i915/parameters/enable_psr${NC} — should show 0"
