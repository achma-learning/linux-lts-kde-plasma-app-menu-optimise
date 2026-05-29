#!/usr/bin/env bash
# arch-ac-appmenu-fix.sh
# 1. AC-mode optimisation (tighten 3 remaining TLP gaps)
# 2. Global app menu for all GTK apps in KDE Plasma X11
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
success() { echo -e "${GREEN}[✓]${NC} $*"; }
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE} $*${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# ── 1. AC OPTIMISATION ──────────────────────────────────────
section "1. AC Mode — tighten remaining TLP gaps"

# 1a. CPU minimum frequency on AC: 500MHz → 1GHz
# At 500MHz the scheduler wastes cycles ramping up before every burst.
# On AC there's no reason to idle below 1GHz.
sed -i 's/^CPU_SCALING_MIN_FREQ_ON_AC=.*/CPU_SCALING_MIN_FREQ_ON_AC=1000000/' /etc/tlp.conf
success "CPU min freq on AC: 500MHz → 1GHz (faster burst response)"

# 1b. PCIe ASPM on AC: default → performance
# 'default' lets the firmware throttle PCIe links to save power.
# On AC that's wasted latency — disable it.
sed -i 's/^PCIE_ASPM_ON_AC=.*/PCIE_ASPM_ON_AC=performance/' /etc/tlp.conf
success "PCIe ASPM on AC: default → performance (no link-power throttling)"

# 1c. USB autosuspend: off on AC
# USB_AUTOSUSPEND is global (TLP has no AC/BAT split for USB).
# On an AC-primary machine, peripherals should never auto-suspend.
sed -i 's/^USB_AUTOSUSPEND=.*/USB_AUTOSUSPEND=0/' /etc/tlp.conf
success "USB autosuspend: disabled (AC-primary machine — peripherals always active)"

# Reload TLP with new config
tlp start > /dev/null 2>&1
success "TLP reloaded with new AC config"

# ── 2. GLOBAL APP MENU — GTK INTEGRATION ───────────────────
section "2. Global App Menu — wire GTK modules into KDE session"

# 2a. Install libdbusmenu-gtk2 (missing — needed for any GTK2 app)
if ! pacman -Q libdbusmenu-gtk2 &>/dev/null; then
    pacman -Sy --needed --noconfirm libdbusmenu-gtk2
    success "libdbusmenu-gtk2 installed (GTK2 app menu export support)"
else
    success "libdbusmenu-gtk2 already installed"
fi

# 2b. KDE plasma-workspace env script (sourced by startplasma-x11 at login)
# This is the reliable path for X11 KDE sessions — loaded before any app starts.
mkdir -p /home/achma/.config/plasma-workspace/env
cat > /home/achma/.config/plasma-workspace/env/gtk-global-menu.sh << 'EOF'
# Export GTK menus to the KDE Global Menu widget via appmenu-gtk-module.
# Needed for Firefox, Thunar, and any GTK2/GTK3 app.
export GTK_MODULES=appmenu-gtk-module
export GTK3_MODULES=appmenu-gtk-module
EOF
chown achma:achma /home/achma/.config/plasma-workspace/env/gtk-global-menu.sh
chmod 644 /home/achma/.config/plasma-workspace/env/gtk-global-menu.sh
success "plasma-workspace env script created (GTK_MODULES exported at KDE login)"

# 2c. systemd user environment (belt-and-suspenders for any app launched
# outside the KDE session, e.g. via .desktop file or terminal)
mkdir -p /home/achma/.config/environment.d
cat > /home/achma/.config/environment.d/gtk-global-menu.conf << 'EOF'
GTK_MODULES=appmenu-gtk-module
GTK3_MODULES=appmenu-gtk-module
EOF
chown achma:achma /home/achma/.config/environment.d/gtk-global-menu.conf
success "systemd user environment set (belt-and-suspenders for non-KDE launchers)"

# ── 3. CHROME GLOBAL MENU ──────────────────────────────────
section "3. Google Chrome — enable native window decorations for global menu"
# Chrome on Linux by default uses its own title bar, bypassing the WM.
# With native decorations, KWin manages the window and Chrome's menu
# bar becomes visible to gmenudbusmenuproxy.
CHROME_FLAGS="/home/achma/.config/chrome-flags.conf"
if [[ ! -f "$CHROME_FLAGS" ]]; then
    cat > "$CHROME_FLAGS" << 'EOF'
--use-system-title-bar
--ozone-platform-hint=x11
EOF
    chown achma:achma "$CHROME_FLAGS"
    success "Chrome flags set: native title bar + forced X11 backend"
else
    # Add flags if not already present
    grep -q "use-system-title-bar" "$CHROME_FLAGS" || echo "--use-system-title-bar" >> "$CHROME_FLAGS"
    grep -q "ozone-platform-hint"  "$CHROME_FLAGS" || echo "--ozone-platform-hint=x11" >> "$CHROME_FLAGS"
    success "Chrome flags updated"
fi

# ── SUMMARY ────────────────────────────────────────────────
echo ""
echo -e "  ${GREEN}AC: CPU min freq${NC}    → 1GHz (was 500MHz)"
echo -e "  ${GREEN}AC: PCIe ASPM${NC}       → performance (was default)"
echo -e "  ${GREEN}AC: USB autosuspend${NC} → off (was on)"
echo -e "  ${GREEN}libdbusmenu-gtk2${NC}    → installed"
echo -e "  ${GREEN}GTK_MODULES${NC}         → set in KDE session env + systemd user env"
echo -e "  ${GREEN}Chrome flags${NC}        → native title bar + X11 backend"
echo ""
echo -e "  ${YELLOW}Requires re-login${NC} to apply GTK_MODULES to running KDE session"
echo ""
echo -e "  ${BLUE}Note:${NC} GTK4 apps (newer GNOME apps) cannot export menus — GTK4"
echo -e "        removed dbusmenu support. This affects ~5% of apps. No fix exists."
echo -e "        Qt/KDE apps, GTK2/GTK3 apps (Firefox, etc.) all work after re-login."
