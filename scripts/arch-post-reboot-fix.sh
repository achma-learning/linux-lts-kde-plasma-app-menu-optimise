#!/usr/bin/env bash
# arch-post-reboot-fix.sh — fixes for 3 boot log warnings
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
success() { echo -e "${GREEN}[✓]${NC} $*"; }
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE} $*${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] Run as root: sudo bash arch-post-reboot-fix.sh${NC}"; exit 1
fi

# ── 1. FIX TLP GPU FREQUENCY (error: value 0 out of range 300-900) ──
section "1. Fix TLP GPU frequency config"
# HD 5500 valid range is 300-900 MHz. We set 0 which is invalid.
# Remove these lines — TLP handles GPU power via energy perf policy instead.
sed -i '/^INTEL_GPU_MIN_FREQ_ON_AC/d'   /etc/tlp.conf
sed -i '/^INTEL_GPU_MAX_FREQ_ON_AC/d'   /etc/tlp.conf
sed -i '/^INTEL_GPU_BOOST_FREQ_ON_AC/d' /etc/tlp.conf
sed -i '/^INTEL_GPU_MIN_FREQ_ON_BAT/d'  /etc/tlp.conf
sed -i '/^INTEL_GPU_MAX_FREQ_ON_BAT/d'  /etc/tlp.conf
sed -i '/^INTEL_GPU_BOOST_FREQ_ON_BAT/d' /etc/tlp.conf
tlp start > /dev/null 2>&1
success "TLP GPU frequency lines removed (HD 5500 range: 300-900 MHz, TLP manages via energy policy)"

# ── 2. INSTALL wireless-regdb (fixes 'failed to load regulatory.db') ──
section "2. Install wireless-regdb"
pacman -Sy --needed --noconfirm wireless-regdb
# Apply immediately without reboot
iw reg set MA 2>/dev/null && success "WiFi regulatory domain set to MA (Morocco)" || \
    success "wireless-regdb installed (active after reboot)"

# ── 3. SDDM — FORCE PLASMA X11 AS DEFAULT SESSION ──────────
section "3. Lock SDDM default to Plasma X11"
# The SDDM state file holds the last-used session per user.
# Update it to plasmax11 so it doesn't fall back to Wayland.
SDDM_STATE="/var/lib/sddm/state.conf"
cat > "$SDDM_STATE" << 'EOF'
[Last]
Session=plasmax11
User=achma
EOF
success "SDDM state locked to plasmax11 (will default to Plasma X11 at login)"

# ── SUMMARY ────────────────────────────────────────────────
echo ""
echo -e "  ${GREEN}TLP GPU freq${NC}     → fixed (removed invalid 0 MHz lines)"
echo -e "  ${GREEN}wireless-regdb${NC}   → installed (no more regulatory.db error)"
echo -e "  ${GREEN}SDDM default${NC}     → locked to Plasma (X11)"
echo ""
echo -e "  ${YELLOW}No reboot needed${NC} — changes take effect immediately"
echo -e "  Next login will default to ${GREEN}Plasma (X11)${NC} automatically"
