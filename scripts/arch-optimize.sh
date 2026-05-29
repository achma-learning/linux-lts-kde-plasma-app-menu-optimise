#!/usr/bin/env bash
# ============================================================
# Arch Linux Optimization Script
# Inspired by ChrisTitusTech/linutil
# System: Intel i5-5200U | 16GB RAM | SSD | KDE Plasma Wayland
# ============================================================

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE} $*${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] Run as root: sudo bash arch-optimize.sh${NC}"
    exit 1
fi

# ── 1. LID CLOSE → SCREEN OFF, STAY AWAKE ──────────────────
section "1. Lid Close: Screen Off + Stay Awake"
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/lid.conf << 'EOF'
[Login]
# Lid close: lock screen (turns display off) — system stays awake
HandleLidSwitch=lock
HandleLidSwitchExternalPower=lock
HandleLidSwitchDocked=ignore
LidSwitchIgnoreInhibited=no
EOF
success "Lid close → lock screen (display off, PC awake)"
info  "KDE's screen locker will blank the display automatically"

# ── 2. FIX BOOTLOADER → DEFAULT TO LTS KERNEL ──────────────
section "2. Fix Bootloader — Default to LTS Kernel"
LTS_ENTRY=$(ls /boot/loader/entries/ | grep -i "lts" | head -1)
if [[ -n "$LTS_ENTRY" ]]; then
    # Update default in loader.conf
    sed -i "s|^default .*|default $LTS_ENTRY|" /boot/loader/loader.conf
    success "Default boot entry set to: $LTS_ENTRY"
    cat /boot/loader/loader.conf
else
    warn "No LTS boot entry found — skipping"
fi

# Add quiet splash and performance kernel params to LTS entry
LTS_CONF="/boot/loader/entries/$LTS_ENTRY"
if [[ -f "$LTS_CONF" ]] && ! grep -q "quiet" "$LTS_CONF"; then
    # Append performance options to kernel cmdline
    sed -i '/^options / s/$/ quiet loglevel=3 nowatchdog nmi_watchdog=0 mitigations=auto/' "$LTS_CONF"
    success "Added kernel parameters: quiet, reduced logging, watchdog disabled"
fi

# ── 3. PACMAN OPTIMIZATIONS ─────────────────────────────────
section "3. Pacman Optimizations"
PACMAN_CONF="/etc/pacman.conf"

# Enable ILoveCandy (Pac-Man progress bar)
if ! grep -q "^ILoveCandy" "$PACMAN_CONF"; then
    sed -i '/^Color/a ILoveCandy' "$PACMAN_CONF"
    success "ILoveCandy enabled (Pac-Man progress bar)"
fi

# Enable VerbosePkgLists
if ! grep -q "^VerbosePkgLists" "$PACMAN_CONF"; then
    sed -i '/^Color/a VerbosePkgLists' "$PACMAN_CONF"
    success "VerbosePkgLists enabled"
fi

# Bump parallel downloads
sed -i 's/^ParallelDownloads = .*/ParallelDownloads = 10/' "$PACMAN_CONF"
success "ParallelDownloads set to 10"

# ── 4. INSTALL PACKAGES ─────────────────────────────────────
section "4. Installing Optimization Packages"

# tuned and TLP conflict — TLP is better for laptops, replace tuned
if pacman -Q tuned &>/dev/null; then
    info "Removing tuned (conflicts with TLP — TLP is better for laptops)"
    systemctl disable --now tuned.service 2>/dev/null || true
    pacman -R --noconfirm tuned
    success "tuned removed"
fi

pacman -Sy --needed --noconfirm \
    tlp \
    tlp-rdw \
    irqbalance \
    thermald \
    pacman-contrib \
    reflector \
    powertop \
    htop \
    btop \
    earlyoom
success "Packages installed"

# ── 5. SYSCTL PERFORMANCE TWEAKS ───────────────────────────
section "5. Sysctl Performance Tweaks"
cat > /etc/sysctl.d/99-performance.conf << 'EOF'
# ── Memory Management ──────────────────────────────────────
# Low swappiness for 16GB RAM — avoid swapping until really needed
vm.swappiness = 10

# Reduce dirty page writeback — smoother I/O
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# Keep more cache for filesystem metadata
vm.vfs_cache_pressure = 50

# ── SSD / Storage ──────────────────────────────────────────
# Disable write-back cache lag
vm.dirty_writeback_centisecs = 1500

# ── Network Performance ─────────────────────────────────────
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# ── Kernel ─────────────────────────────────────────────────
# Disable NMI watchdog (saves power on laptop)
kernel.nmi_watchdog = 0

# Reduce kernel log noise
kernel.printk = 3 3 3 3

# Increase inotify watches (for KDE file watchers)
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# Increase file descriptor limit
fs.file-max = 2097152
EOF
sysctl --system > /dev/null 2>&1
success "Sysctl tweaks applied (swappiness=10, network tuned, inotify increased)"

# ── 6. IO SCHEDULER → NONE FOR SSD ─────────────────────────
section "6. IO Scheduler → none for SSD"
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/60-io-scheduler.rules << 'EOF'
# SSD/NVMe: use 'none' scheduler (kernel handles it best)
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="0", \
    ATTR{queue/scheduler}="none"

# HDD: use 'bfq' scheduler (best latency for spinning disks)
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", \
    ATTR{queue/scheduler}="bfq"

# Apply to current devices immediately
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
EOF
# Apply immediately for sdb (SSD) and sda (HDD)
echo none > /sys/block/sdb/queue/scheduler 2>/dev/null && success "SSD (sdb) IO scheduler → none" || warn "Could not set sdb scheduler"
echo bfq  > /sys/block/sda/queue/scheduler 2>/dev/null && success "HDD (sda) IO scheduler → bfq" || warn "Could not set sda scheduler"

# ── 7. FSTAB → NOATIME FOR SSD ─────────────────────────────
section "7. fstab noatime for SSD Partitions"
cp /etc/fstab /etc/fstab.bak
# Change relatime to noatime on ext4 partitions (SSD root + home = sdb2, sdb3)
sed -i '/ext4.*rw,relatime/ s/rw,relatime/rw,noatime/' /etc/fstab
success "fstab updated: relatime → noatime on ext4 partitions"
diff /etc/fstab.bak /etc/fstab || true

# ── 8. TRANSPARENT HUGE PAGES → MADVISE ────────────────────
section "8. Transparent Huge Pages → madvise"
cat > /etc/tmpfiles.d/thp.conf << 'EOF'
w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise
w /sys/kernel/mm/transparent_hugepage/defrag  - - - - defer+madvise
EOF
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
success "THP set to madvise (better than 'always' for desktop use)"

# ── 9. SYSTEMD JOURNAL SIZE LIMIT ──────────────────────────
section "9. Journal Size Limit"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/size.conf << 'EOF'
[Journal]
SystemMaxUse=100M
SystemKeepFree=200M
MaxFileSec=1month
Compress=yes
EOF
systemctl restart systemd-journald
success "Journal capped at 100MB, compression enabled"

# ── 10. ENABLE/CONFIGURE SERVICES ──────────────────────────
section "10. Services: TLP, irqbalance, thermald, earlyoom"

# TLP — laptop power management
if pacman -Q tlp &>/dev/null; then
    # Configure TLP for Intel i5-5200U (Broadwell) laptop
    cat > /etc/tlp.conf << 'EOF'
# TLP Config for Intel i5-5200U laptop
TLP_ENABLE=1
TLP_DEFAULT_MODE=AC

# CPU power
CPU_SCALING_GOVERNOR_ON_AC=schedutil
CPU_SCALING_GOVERNOR_ON_BAT=powersave

# CPU turbo
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=0

# Intel HWP energy performance (Broadwell supports this)
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=power

# Disk power
DISK_APM_LEVEL_ON_AC="254 254"
DISK_APM_LEVEL_ON_BAT="128 128"

# AHCI link power: med_power_with_dipm for SSD, max_performance for HDD
AHCI_RUNTIME_PM_ON_AC=on
AHCI_RUNTIME_PM_ON_BAT=auto

# PCIe / ASPM power
PCIE_ASPM_ON_AC=default
PCIE_ASPM_ON_BAT=powersupersave

# NIC power
NMI_WATCHDOG=0
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on

# USB autosuspend
USB_AUTOSUSPEND=1

# Runtime power management
RUNTIME_PM_ON_AC=auto
RUNTIME_PM_ON_BAT=auto
EOF
    systemctl enable --now tlp.service
    systemctl enable tlp-sleep.service 2>/dev/null || true
    success "TLP enabled and configured for i5-5200U"
fi

# irqbalance — distribute hardware interrupts across CPU cores
if pacman -Q irqbalance &>/dev/null; then
    systemctl enable --now irqbalance
    success "irqbalance enabled (distributes IRQs across 4 CPU threads)"
fi

# thermald — Intel thermal management daemon
if pacman -Q thermald &>/dev/null; then
    systemctl enable --now thermald
    success "thermald enabled (Intel thermal management)"
fi

# earlyoom — kills processes when RAM is near-full (prevents freeze)
if pacman -Q earlyoom &>/dev/null; then
    systemctl enable --now earlyoom
    success "earlyoom enabled (prevents OOM freeze)"
fi

# fstrim — weekly TRIM for SSD (already active, ensure it's enabled)
systemctl enable fstrim.timer
success "fstrim.timer enabled (weekly SSD TRIM)"

# preload — preloads frequently used apps into RAM
if pacman -Q preload &>/dev/null; then
    systemctl enable --now preload
    success "preload enabled (pre-loads apps into RAM)"
fi

# ── 11. DISABLE BOOT-DELAY SERVICES ────────────────────────
section "11. Remove Boot Delays"

# NetworkManager-wait-online causes 20-30s boot delay
systemctl disable NetworkManager-wait-online.service 2>/dev/null && \
    success "Disabled NetworkManager-wait-online (was causing boot delay)" || true

# systemd-networkd-wait-online — same issue if NM is primary
systemctl disable systemd-networkd-wait-online.service 2>/dev/null && \
    success "Disabled systemd-networkd-wait-online" || true

# ── 12. CLEAN PACMAN CACHE ─────────────────────────────────
section "12. Pacman Cache Cleanup"
if command -v paccache &>/dev/null; then
    BEFORE=$(du -sh /var/cache/pacman/pkg/ | cut -f1)
    paccache -r   # Keep 3 most recent versions
    paccache -ruk0 # Remove uninstalled packages
    AFTER=$(du -sh /var/cache/pacman/pkg/ | cut -f1)
    success "Pacman cache: ${BEFORE} → ${AFTER}"
fi

# ── 13. TLP AUTO-PROFILE NOTE ───────────────────────────────
section "13. Power Management Note"
info "TLP manages all power profiles automatically (AC vs Battery)"
info "On battery: powersave governor, turbo boost OFF"
info "On AC:      schedutil governor, turbo boost ON"
success "No manual profile switching needed — TLP handles it all"

# ── 14. REFLECTOR — FASTEST MIRRORS ────────────────────────
section "14. Reflector — Optimise Mirrors"
if command -v reflector &>/dev/null; then
    # Configure reflector
    cat > /etc/xdg/reflector/reflector.conf << 'EOF'
--save /etc/pacman.d/mirrorlist
--protocol https
--country France,Germany,Netherlands,United Kingdom
--latest 10
--sort rate
EOF
    reflector --save /etc/pacman.d/mirrorlist \
        --protocol https \
        --country "France,Germany,Netherlands,United Kingdom" \
        --latest 10 --sort rate 2>/dev/null && \
        success "Mirrors updated to fastest European HTTPS mirrors" || \
        warn "Reflector failed — check internet connection"

    # Enable weekly mirror refresh
    systemctl enable reflector.timer
    success "reflector.timer enabled (weekly mirror refresh)"
fi

# ── SUMMARY ────────────────────────────────────────────────
section "✅ Optimization Complete!"
echo ""
echo -e "  ${GREEN}Lid close${NC}       → Lock screen (display off, PC stays awake)"
echo -e "  ${GREEN}LTS Kernel${NC}      → Set as default boot ($(ls /boot/loader/entries/ | grep -i lts | head -1))"
echo -e "  ${GREEN}Swappiness${NC}      → $(cat /proc/sys/vm/swappiness) (was 60)"
echo -e "  ${GREEN}IO Scheduler${NC}    → $(cat /sys/block/sdb/queue/scheduler) for SSD"
echo -e "  ${GREEN}THP${NC}             → $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
echo -e "  ${GREEN}fstab${NC}           → noatime on SSD partitions"
echo -e "  ${GREEN}TLP${NC}             → $(systemctl is-active tlp 2>/dev/null)"
echo -e "  ${GREEN}irqbalance${NC}      → $(systemctl is-active irqbalance 2>/dev/null)"
echo -e "  ${GREEN}thermald${NC}        → $(systemctl is-active thermald 2>/dev/null)"
echo -e "  ${GREEN}earlyoom${NC}        → $(systemctl is-active earlyoom 2>/dev/null)"
echo ""
echo -e "  ${YELLOW}⚠ REBOOT REQUIRED${NC} to boot into LTS kernel and apply fstab changes"
echo ""
echo -e "  After reboot, verify with: ${BLUE}uname -r${NC}  (should show linux-lts)"
