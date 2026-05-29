#!/usr/bin/env bash
# Continue from where arch-optimize.sh left off (steps 4–14)
# Steps 1–3 already completed successfully.

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE} $*${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] Run as root: sudo bash arch-optimize-continue.sh${NC}"
    exit 1
fi

# ── 4. INSTALL PACKAGES (remove tuned first, then install TLP etc.) ──
section "4. Installing Optimization Packages"

if pacman -Q tuned &>/dev/null; then
    info "Removing tuned + tuned-ppd (both conflict with TLP)"
    systemctl disable --now tuned.service 2>/dev/null || true
    systemctl disable --now tuned-ppd.service 2>/dev/null || true
    # Remove tuned-ppd first (it depends on tuned), then tuned
    pacman -R --noconfirm tuned-ppd 2>/dev/null || true
    pacman -R --noconfirm tuned
    success "tuned and tuned-ppd removed"
fi

pacman -Sy --needed --noconfirm \
    tlp \
    tlp-rdw \
    irqbalance \
    thermald \
    pacman-contrib \
    reflector \
    powertop \
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
section "6. IO Scheduler → none for SSD, bfq for HDD"
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/60-io-scheduler.rules << 'EOF'
# SSD: use 'none' scheduler (best for flash storage)
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="0", \
    ATTR{queue/scheduler}="none"

# HDD: use 'bfq' scheduler (best latency for spinning disks)
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", \
    ATTR{queue/scheduler}="bfq"
EOF
echo none > /sys/block/sdb/queue/scheduler 2>/dev/null && success "SSD (sdb) IO scheduler → none" || warn "Could not set sdb scheduler live"
echo bfq  > /sys/block/sda/queue/scheduler 2>/dev/null && success "HDD (sda) IO scheduler → bfq"  || warn "Could not set sda scheduler live"

# ── 7. FSTAB → NOATIME FOR SSD ─────────────────────────────
section "7. fstab noatime for SSD Partitions"
if grep -q "rw,relatime" /etc/fstab; then
    cp /etc/fstab /etc/fstab.bak
    sed -i '/ext4.*rw,relatime/ s/rw,relatime/rw,noatime/' /etc/fstab
    success "fstab updated: relatime → noatime on ext4 partitions"
    diff /etc/fstab.bak /etc/fstab || true
else
    success "fstab already uses noatime — skipping"
fi

# ── 8. TRANSPARENT HUGE PAGES → MADVISE ────────────────────
section "8. Transparent Huge Pages → madvise"
cat > /etc/tmpfiles.d/thp.conf << 'EOF'
w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise
w /sys/kernel/mm/transparent_hugepage/defrag  - - - - defer+madvise
EOF
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
success "THP set to madvise"

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
success "Journal capped at 100MB with compression"

# ── 10. ENABLE SERVICES ─────────────────────────────────────
section "10. Services: TLP, irqbalance, thermald, earlyoom"

# TLP — laptop power management (i5-5200U, old battery ~1h, max perf on AC)
if pacman -Q tlp &>/dev/null; then
    cat > /etc/tlp.conf << 'EOF'
# ══════════════════════════════════════════════════════
# TLP Config — Intel i5-5200U | Old battery (~1h life)
# AC   → MAX PERFORMANCE  (no throttling, full power)
# BAT  → MAX BATTERY SAVE (squeeze every minute out)
# ══════════════════════════════════════════════════════
TLP_ENABLE=1
TLP_DEFAULT_MODE=AC

# ── CPU Governor ───────────────────────────────────────
# AC:  performance = always max clock, no scaling delay
# BAT: powersave   = lowest possible clocks always
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_SCALING_GOVERNOR_ON_BAT=powersave

# ── CPU Frequency Limits ───────────────────────────────
# AC:  uncapped (2700 MHz turbo allowed)
# BAT: cap at 800 MHz — saves ~40% power vs full speed
CPU_SCALING_MIN_FREQ_ON_AC=500000
CPU_SCALING_MAX_FREQ_ON_AC=2700000
CPU_SCALING_MIN_FREQ_ON_BAT=500000
CPU_SCALING_MAX_FREQ_ON_BAT=800000

# ── Turbo Boost ────────────────────────────────────────
# AC:  ON  (full 2.7GHz burst speed)
# BAT: OFF (turbo uses 2–3× power for small speed gains)
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=0

# ── Intel HWP Energy Policy ────────────────────────────
# AC:  performance (max throughput, no power compromise)
# BAT: power       (absolute minimum power draw)
CPU_ENERGY_PERF_POLICY_ON_AC=performance
CPU_ENERGY_PERF_POLICY_ON_BAT=power

# ── CPU min/max perf percentage ────────────────────────
CPU_MIN_PERF_ON_AC=0
CPU_MAX_PERF_ON_AC=100
CPU_MIN_PERF_ON_BAT=0
CPU_MAX_PERF_ON_BAT=30

# ── Disk APM ───────────────────────────────────────────
# AC:  254 = disabled (max SSD/HDD performance)
# BAT: 1   = aggressive spindown (minimum power on HDD)
DISK_APM_LEVEL_ON_AC="254 254"
DISK_APM_LEVEL_ON_BAT="1 1"

# ── Disk spindown timeout ──────────────────────────────
# BAT: spin down HDD after 60s idle
DISK_SPINDOWN_TIMEOUT_ON_AC="0 0"
DISK_SPINDOWN_TIMEOUT_ON_BAT="12 12"

# ── PCIe ASPM ─────────────────────────────────────────
# AC:  default (no restriction, max performance)
# BAT: powersupersave (deepest PCIe power states)
PCIE_ASPM_ON_AC=default
PCIE_ASPM_ON_BAT=powersupersave

# ── WiFi Power Saving ──────────────────────────────────
# AC:  off (no WiFi throttling, full speed)
# BAT: on  (WiFi sleeps between packets, saves ~1W)
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on

# ── USB Autosuspend ────────────────────────────────────
# AC:  off (no USB device interruptions)
# BAT: on  (suspend idle USB devices)
USB_AUTOSUSPEND=1
USB_AUTOSUSPEND_DISABLE_ON_SHUTDOWN=1

# ── Runtime Power Management ──────────────────────────
# AC:  on  (devices always active)
# BAT: auto (devices sleep when idle)
RUNTIME_PM_ON_AC=on
RUNTIME_PM_ON_BAT=auto

# ── Platform Profile ───────────────────────────────────
# AC:  performance
# BAT: low-power
PLATFORM_PROFILE_ON_AC=performance
PLATFORM_PROFILE_ON_BAT=low-power

# ── Intel GPU power saving ─────────────────────────────
# BAT only: enable RC6 deep power states on Intel GPU
INTEL_GPU_MIN_FREQ_ON_AC=0
INTEL_GPU_MAX_FREQ_ON_AC=1000
INTEL_GPU_BOOST_FREQ_ON_AC=1000
INTEL_GPU_MIN_FREQ_ON_BAT=0
INTEL_GPU_MAX_FREQ_ON_BAT=300
INTEL_GPU_BOOST_FREQ_ON_BAT=300

# ── NMI Watchdog ───────────────────────────────────────
# Disable on both — saves ~1W, not needed on desktop/laptop
NMI_WATCHDOG=0
EOF
    systemctl enable --now tlp.service
    systemctl enable tlp-sleep.service 2>/dev/null || true
    success "TLP enabled and configured for i5-5200U"
fi

# irqbalance
if pacman -Q irqbalance &>/dev/null; then
    systemctl enable --now irqbalance
    success "irqbalance enabled (IRQs across 4 CPU threads)"
fi

# thermald
if pacman -Q thermald &>/dev/null; then
    systemctl enable --now thermald
    success "thermald enabled (Intel thermal management)"
fi

# earlyoom
if pacman -Q earlyoom &>/dev/null; then
    systemctl enable --now earlyoom
    success "earlyoom enabled (prevents OOM freeze)"
fi

# fstrim weekly
systemctl enable fstrim.timer
success "fstrim.timer enabled (weekly SSD TRIM)"

# ── LOW BATTERY AUTO-SUSPEND (old battery protection) ──────
section "10b. Low Battery Auto-Suspend (old battery guard)"
# Old batteries drop voltage fast — auto-suspend at 10% to prevent hard shutdown
# which can corrupt the filesystem on SSD
cat > /etc/udev/rules.d/99-low-battery.rules << 'EOF'
# Auto-suspend at 10% battery — protects against sudden power loss
# Critical for old batteries that drop quickly near empty
SUBSYSTEM=="power_supply", ATTR{status}=="Discharging", \
    ATTR{capacity}=="[0-9]", RUN+="/usr/bin/systemctl suspend"
SUBSYSTEM=="power_supply", ATTR{status}=="Discharging", \
    ATTR{capacity}=="10",    RUN+="/usr/bin/systemctl suspend"
EOF

# Also configure systemd-logind for low battery action
mkdir -p /etc/systemd/logind.conf.d
# Already handled lid — add battery action to same drop-in or new file
cat > /etc/systemd/logind.conf.d/battery.conf << 'EOF'
[Login]
# Old battery: suspend when critically low (prevents hard shutdown + FS corruption)
HandlePowerKey=suspend
EOF

# systemd also has its own sleep/battery config via UPower — set via upower if available
if command -v upower &>/dev/null; then
    info "UPower detected — battery thresholds are also managed by KDE Power Management"
    info "Go to: System Settings → Power Management → On Low Battery → Suspend at 10%"
fi

# Also set kernel watchdog for battery via /sys directly now
BAT_PATH=$(ls /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -1)
if [[ -n "$BAT_PATH" ]]; then
    CURRENT_CAP=$(cat "$BAT_PATH")
    success "Battery auto-suspend at ≤10% capacity configured (currently at ${CURRENT_CAP}%)"
else
    success "Low battery udev rule installed (suspends at ≤10%)"
fi

# ── 11. DISABLE BOOT-DELAY SERVICES ────────────────────────
section "11. Remove Boot Delays"
systemctl disable NetworkManager-wait-online.service 2>/dev/null && \
    success "Disabled NetworkManager-wait-online (removes ~25s boot delay)" || true
systemctl disable systemd-networkd-wait-online.service 2>/dev/null && \
    success "Disabled systemd-networkd-wait-online" || true

# ── 12. CLEAN PACMAN CACHE ─────────────────────────────────
section "12. Pacman Cache Cleanup"
if command -v paccache &>/dev/null; then
    BEFORE=$(du -sh /var/cache/pacman/pkg/ | cut -f1)
    paccache -rk3   # Keep 3 most recent versions
    paccache -ruk0  # Remove all cached uninstalled packages
    AFTER=$(du -sh /var/cache/pacman/pkg/ | cut -f1)
    success "Pacman cache: ${BEFORE} → ${AFTER}"
fi

# ── 13. REFLECTOR — FASTEST MIRRORS ────────────────────────
section "13. Reflector — Fastest Mirrors"
if command -v reflector &>/dev/null; then
    cat > /etc/xdg/reflector/reflector.conf << 'EOF'
--save /etc/pacman.d/mirrorlist
--protocol https
--country France,Germany,Netherlands,"United Kingdom"
--latest 10
--sort rate
EOF
    info "Finding fastest mirrors (may take ~30s)..."
    reflector --save /etc/pacman.d/mirrorlist \
        --protocol https \
        --country "France,Germany,Netherlands,United Kingdom" \
        --latest 10 --sort rate 2>/dev/null && \
        success "Mirrors updated to fastest European HTTPS mirrors" || \
        warn "Reflector failed — mirrors unchanged, will retry on next weekly run"
    systemctl enable reflector.timer
    success "reflector.timer enabled (weekly mirror refresh)"
fi

# ── FINAL SUMMARY ───────────────────────────────────────────
section "✅ All Done!"
echo ""
echo -e "  ${GREEN}Lid close${NC}         → Lock screen (display off, PC stays awake)"
echo -e "  ${GREEN}LTS Kernel${NC}        → Default boot set to linux-lts 6.18"
echo -e "  ${GREEN}Swappiness${NC}        → $(cat /proc/sys/vm/swappiness) (was 60)"
echo -e "  ${GREEN}IO Scheduler SSD${NC}  → $(cat /sys/block/sdb/queue/scheduler)"
echo -e "  ${GREEN}IO Scheduler HDD${NC}  → $(cat /sys/block/sda/queue/scheduler)"
echo -e "  ${GREEN}THP${NC}               → $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
echo -e "  ${GREEN}TLP${NC}               → $(systemctl is-active tlp 2>/dev/null)"
echo -e "  ${GREEN}irqbalance${NC}        → $(systemctl is-active irqbalance 2>/dev/null)"
echo -e "  ${GREEN}thermald${NC}          → $(systemctl is-active thermald 2>/dev/null)"
echo -e "  ${GREEN}earlyoom${NC}          → $(systemctl is-active earlyoom 2>/dev/null)"
echo ""
echo -e "  ${YELLOW}⚠  REBOOT to activate:${NC}"
echo -e "  • LTS kernel (linux-lts 6.18)"
echo -e "  • noatime fstab mounts"
echo -e "  • All kernel parameters"
echo ""
echo -e "  After reboot → verify: ${BLUE}uname -r${NC}"
