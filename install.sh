#!/usr/bin/env bash
#
# Argon ONE UP — Desktop Environment / Window Manager installer
#
# A whiptail TUI that layers a desktop (XFCE, KDE Plasma, GNOME) and/or a window
# manager (i3, Sway, LXQt, LXDE) on top of a fresh Raspberry Pi OS Lite 64-bit
# install running on an Argon ONE UP (Raspberry Pi CM5).
#
# It first applies the Argon ONE UP hardware/boot setup (idempotently), then lets
# you multi-select what to install, auto-picks a suitable display manager, wires up
# dependencies, and switches the system to graphical boot.
#
# Usage:  sudo ./install.sh
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Globals
# ----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

LOGFILE="/var/log/argon-desktop-installer.log"
CONFIG_TXT="/boot/firmware/config.txt"
CMDLINE_TXT="/boot/firmware/cmdline.txt"
ARGON_SCRIPT_URL="https://download.argon40.com/argononeup.sh"
HDMI_MODE="video=HDMI-A-2:1920x1200@60e"

# Filled in by the selection step.
SELECTED=()            # tags chosen by the user, e.g. ("xfce" "sway")
DM=""                  # chosen display manager: lightdm | sddm | gdm3
INSTALLED_SUMMARY=""   # human-readable summary for the final dialog

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log() {
    # Timestamped line to both stdout and the logfile.
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE"
}

die() {
    log "ERROR: $*"
    if command -v whiptail >/dev/null 2>&1; then
        whiptail --title "Installer error" --msgbox "$*\n\nSee $LOGFILE for details." 12 70 || true
    fi
    exit 1
}

# Run a command, streaming all output to the logfile (and the console).
run() {
    log "RUN: $*"
    if ! "$@" >>"$LOGFILE" 2>&1; then
        die "Command failed: $*"
    fi
}

# Parse apt's machine-readable progress (APT::Status-Fd) into whiptail --gauge
# update blocks. Download phase maps to 0-50%, install/configure phase to 50-100%.
parse_apt_status() {
    local msg="$1"
    local kind pkg pct desc ipct
    printf 'XXX\n0\n%s\nPreparing...\nXXX\n' "$msg"
    while IFS=: read -r kind pkg pct desc; do
        [[ "$pct" =~ ^[0-9] ]] || continue
        case "$kind" in
            dlstatus) ipct=$(( ${pct%%.*} / 2 )) ;;
            pmstatus) ipct=$(( 50 + ${pct%%.*} / 2 )) ;;
            *) continue ;;
        esac
        (( ipct < 0 ))   && ipct=0
        (( ipct > 100 )) && ipct=100
        printf 'XXX\n%d\n%s\n%s\nXXX\n' "$ipct" "$msg" "${desc:-working...}"
    done
    printf 'XXX\n100\n%s\nDone.\nXXX\n' "$msg"
}

# Run an apt-get operation behind a whiptail progress gauge.
# Usage: apt_gauge "Title shown in the gauge" <apt-get subcommand and args...>
# `-y` and the Status-Fd options are added automatically.
apt_gauge() {
    local msg="$1"; shift
    log "RUN(gauge): apt-get $* -y"
    local rc_file
    rc_file="$(mktemp)"
    set +e
    (
        apt-get "$@" -y -o APT::Status-Fd=3 -o Dpkg::Use-Pty=0 \
            3>&1 1>>"$LOGFILE" 2>&1
        echo "$?" >"$rc_file"
    ) | parse_apt_status "$msg" | whiptail --gauge "$msg" 8 72 0
    set -e
    local rc
    rc="$(cat "$rc_file" 2>/dev/null || echo 1)"
    rm -f "$rc_file"
    [[ "$rc" == "0" ]] || die "apt-get $* failed (exit $rc). See $LOGFILE."
}

# Show a non-blocking message while a long, non-apt step runs.
infobox() {
    whiptail --title "$1" --infobox "$2" 9 72
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "This installer must run as root. Re-executing with sudo..." >&2
        exec sudo -E bash "$0" "$@"
    fi
}

ensure_whiptail() {
    if ! command -v whiptail >/dev/null 2>&1; then
        echo "Installing whiptail (libnewt)..." >&2
        apt-get update >>"$LOGFILE" 2>&1 || true
        apt-get install -y whiptail >>"$LOGFILE" 2>&1 \
            || { echo "Could not install whiptail; aborting." >&2; exit 1; }
    fi
}

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------
preflight() {
    : >>"$LOGFILE" || die "Cannot write to $LOGFILE"
    log "=== Argon ONE UP desktop installer started ==="

    if [[ ! -f "$CONFIG_TXT" ]]; then
        if ! whiptail --title "Not Raspberry Pi OS?" \
            --yesno "Could not find $CONFIG_TXT.\n\nThis does not look like Raspberry Pi OS. Hardware setup steps will be skipped if files are missing.\n\nContinue anyway?" 14 70; then
            die "Aborted by user (not Raspberry Pi OS)."
        fi
    fi

    log "Running apt-get update..."
    apt_gauge "Updating package lists" update
}

# ----------------------------------------------------------------------------
# 1. Argon ONE UP hardware / boot setup (idempotent)
# ----------------------------------------------------------------------------

# Append a line to a file only if an exact match is not already present.
ensure_line() {
    local line="$1" file="$2"
    [[ -f "$file" ]] || return 0
    if grep -qxF "$line" "$file"; then
        log "config: '$line' already present in $file"
    else
        printf '%s\n' "$line" >>"$file"
        log "config: appended '$line' to $file"
    fi
}

backup_once() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    if [[ ! -f "${file}.argon-installer.bak" ]]; then
        cp -a "$file" "${file}.argon-installer.bak"
        log "backup: ${file} -> ${file}.argon-installer.bak"
    fi
}

hardware_setup() {
    log "--- Argon ONE UP hardware setup ---"

    if [[ -f "$CONFIG_TXT" ]]; then
        backup_once "$CONFIG_TXT"
        local lines=(
            "dtparam=uart0=on"
            "dtoverlay=dwc2,dr_mode=host"
            "dtparam=nvme"
            "dtparam=pciex1_gen=3"
            "usb_max_current_enable=1"
            "dtparam=ant2"
        )
        local l
        for l in "${lines[@]}"; do
            ensure_line "$l" "$CONFIG_TXT"
        done
    else
        log "skip: $CONFIG_TXT not found"
    fi

    # HDMI mode is display-specific, so ask before forcing it.
    if [[ -f "$CMDLINE_TXT" ]]; then
        if whiptail --title "HDMI output mode" \
            --yesno "Force HDMI output mode?\n\n  $HDMI_MODE\n\nThis matches the Argon ONE UP guide (1920x1200@60). Skip if you use a different display." 14 72; then
            backup_once "$CMDLINE_TXT"
            if grep -qF "$HDMI_MODE" "$CMDLINE_TXT"; then
                log "cmdline: HDMI mode already present"
            else
                # cmdline.txt is a single line of space-separated params.
                sed -i "1 s|\$| ${HDMI_MODE}|" "$CMDLINE_TXT"
                log "cmdline: appended '$HDMI_MODE'"
            fi
        else
            log "cmdline: HDMI mode skipped by user"
        fi
    else
        log "skip: $CMDLINE_TXT not found"
    fi

    # Official Argon ONE UP vendor/support script (third-party, networked).
    if whiptail --title "Argon ONE UP support script" \
        --yesno "Run the official Argon ONE UP setup script?\n\n  curl ${ARGON_SCRIPT_URL} | bash\n\nThis installs Argon's hardware support (fan/power/battery helpers). It is downloaded from the internet and run as root." 15 74; then
        log "Running Argon vendor script from $ARGON_SCRIPT_URL"
        infobox "Argon ONE UP support script" "Downloading and running the Argon support script...\n\nThis may take a few minutes."
        if curl -fsSL "$ARGON_SCRIPT_URL" | bash >>"$LOGFILE" 2>&1; then
            log "Argon vendor script completed"
        else
            log "WARNING: Argon vendor script returned non-zero (continuing)"
            whiptail --title "Vendor script" --msgbox \
                "The Argon support script reported an error. Continuing with desktop install.\n\nSee $LOGFILE." 10 70 || true
        fi
    else
        log "Argon vendor script skipped by user"
    fi
}

# ----------------------------------------------------------------------------
# 2. Base system upgrade (optional)
# ----------------------------------------------------------------------------
base_upgrade() {
    if whiptail --title "System upgrade" \
        --yesno "Run a full system upgrade now?\n\n  apt-get full-upgrade\n  apt-get autoremove\n\nRecommended on a fresh image, but can be skipped if you just upgraded." 13 72; then
        log "--- Base upgrade ---"
        apt_gauge "Upgrading system (full-upgrade)" full-upgrade
        apt_gauge "Removing unused packages" autoremove
    else
        log "Base upgrade skipped by user"
    fi
}

# ----------------------------------------------------------------------------
# 3. Desktop / WM selection
# ----------------------------------------------------------------------------
select_desktops() {
    local choices
    # tag  label  on/off
    choices=$(whiptail --title "Select desktops / window managers" \
        --checklist \
        "Choose what to install (Space to toggle, Enter to confirm). You can pick several; each becomes a session at the login screen." \
        20 78 7 \
        "xfce"  "XFCE desktop (lightweight, full DE)"        OFF \
        "kde"   "KDE Plasma desktop (full-featured DE)"      OFF \
        "gnome" "GNOME desktop (the forum guide's choice)"   OFF \
        "i3"    "i3 — tiling window manager (X11)"           OFF \
        "sway"  "Sway — tiling window manager (Wayland)"     OFF \
        "lxqt"  "LXQt desktop (light, Qt-based)"             OFF \
        "lxde"  "LXDE desktop (very light)"                  OFF \
        3>&1 1>&2 2>&3) || die "Selection cancelled."

    # whiptail returns quoted, space-separated tags: "xfce" "sway"
    eval "SELECTED=($choices)"

    if [[ ${#SELECTED[@]} -eq 0 ]]; then
        die "Nothing selected — exiting."
    fi
    log "Selected: ${SELECTED[*]}"
}

contains() {
    # contains needle "${haystack[@]}"
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

install_desktops() {
    log "--- Installing desktops / window managers ---"
    local tag total idx
    total=${#SELECTED[@]}
    idx=0
    for tag in "${SELECTED[@]}"; do
        idx=$((idx + 1))
        case "$tag" in
            xfce)
                log "Installing XFCE"
                apt_gauge "Installing XFCE ($idx of $total)" install xfce4 xfce4-goodies
                INSTALLED_SUMMARY+=$'\n  - XFCE (xfce4, xfce4-goodies)'
                ;;
            kde)
                log "Installing KDE Plasma"
                apt_gauge "Installing KDE Plasma ($idx of $total)" install kde-plasma-desktop
                INSTALLED_SUMMARY+=$'\n  - KDE Plasma (kde-plasma-desktop)'
                ;;
            gnome)
                log "Installing GNOME core"
                apt_gauge "Installing GNOME ($idx of $total)" install gnome-core
                INSTALLED_SUMMARY+=$'\n  - GNOME (gnome-core)'
                install_gnome_extras
                ;;
            i3)
                log "Installing i3"
                apt_gauge "Installing i3 ($idx of $total)" install i3
                INSTALLED_SUMMARY+=$'\n  - i3 (i3 + dmenu/i3status/i3lock)'
                ;;
            sway)
                log "Installing Sway"
                # Recommends aren't pulled, so add terminal + launcher explicitly.
                apt_gauge "Installing Sway ($idx of $total)" install --no-install-recommends sway swaybg foot wmenu
                INSTALLED_SUMMARY+=$'\n  - Sway (sway, swaybg, foot, wmenu)'
                ;;
            lxqt)
                log "Installing LXQt"
                apt_gauge "Installing LXQt ($idx of $total)" install lxqt-core
                INSTALLED_SUMMARY+=$'\n  - LXQt (lxqt-core)'
                ;;
            lxde)
                log "Installing LXDE"
                apt_gauge "Installing LXDE ($idx of $total)" install lxde-core
                INSTALLED_SUMMARY+=$'\n  - LXDE (lxde-core)'
                ;;
            *)
                log "WARNING: unknown selection tag '$tag' — skipping"
                ;;
        esac
    done
}

install_gnome_extras() {
    if whiptail --title "GNOME extras" \
        --yesno "Install the optional GNOME extras from the Argon guide?\n\n  gnome-tweaks, gnome-shell-extensions, dconf-editor,\n  flatpak, fonts-ubuntu, gir1.2-gnomedesktop-3.0\n\n(gir1.2-gnomedesktop-3.0 is needed by some shell extensions such as ArcMenu.)" 15 76; then
        log "Installing GNOME extras"
        apt_gauge "Installing GNOME extras" install gnome-tweaks gnome-shell-extensions \
            dconf-editor flatpak fonts-ubuntu gir1.2-gnomedesktop-3.0
        INSTALLED_SUMMARY+=$'\n      (+ GNOME extras)'
    else
        log "GNOME extras skipped by user"
    fi
}

# ----------------------------------------------------------------------------
# 4. Display manager
# ----------------------------------------------------------------------------
pick_display_manager() {
    # One DM is enough; it lists every installed session. Pick the one with the
    # best integration for the heaviest selected environment.
    if contains gnome "${SELECTED[@]}"; then
        DM="gdm3"
    elif contains kde "${SELECTED[@]}"; then
        DM="sddm"
    elif contains sway "${SELECTED[@]}"; then
        # lightdm's Wayland session launching is weak; prefer gdm3 for Sway.
        DM="gdm3"
    else
        DM="lightdm"
    fi
    log "Chosen display manager: $DM"
}

install_display_manager() {
    log "--- Installing display manager: $DM ---"

    # Pre-seed the shared default-DM question (best effort; reinforced below).
    echo "${DM} shared/default-x-display-manager select ${DM}" | debconf-set-selections

    case "$DM" in
        lightdm) apt_gauge "Installing display manager (lightdm)" install lightdm lightdm-gtk-greeter ;;
        sddm)    apt_gauge "Installing display manager (sddm)" install sddm ;;
        gdm3)    apt_gauge "Installing display manager (gdm3)" install gdm3 ;;
    esac

    # Make the choice deterministic: the debconf pre-seed is often ignored because
    # each DM postinst recomputes the default, so write the authoritative file too.
    echo "/usr/sbin/${DM}" >/etc/X11/default-display-manager
    log "Wrote /etc/X11/default-display-manager -> /usr/sbin/${DM}"
    infobox "Display manager" "Configuring ${DM} as the default login screen..."
    run dpkg-reconfigure -f noninteractive "$DM"

    run systemctl enable "${DM}.service"
}

# ----------------------------------------------------------------------------
# 5. Xorg driver fix for Pi VideoCore (vc4) KMS
# ----------------------------------------------------------------------------
# The lean DE/WM metapackages don't ship the Raspberry Pi desktop's Xorg config,
# so X auto-selects the legacy fbdev driver and dies with
#   "Cannot run in framebuffer mode. Please specify busIDs ..."
# This OutputClass forces the modesetting driver on the vc4 GPU. It only affects
# Xorg sessions, so it is harmless for Wayland-only setups (GNOME/Sway).
ensure_vc4_xorg_config() {
    local dir="/usr/share/X11/xorg.conf.d"
    local file="${dir}/99-vc4.conf"
    [[ -f "$file" ]] && { log "Xorg vc4 config already present"; return 0; }
    mkdir -p "$dir"
    cat >"$file" <<'EOF'
Section "OutputClass"
    Identifier "vc4"
    MatchDriver "vc4"
    Driver "modesetting"
    Option "PrimaryGPU" "true"
EndSection
EOF
    log "Wrote $file (forces modesetting driver on vc4 KMS)"
}

# ----------------------------------------------------------------------------
# 6. Graphical boot
# ----------------------------------------------------------------------------
enable_graphical_boot() {
    log "Setting default systemd target to graphical"
    run systemctl set-default graphical.target
}

# ----------------------------------------------------------------------------
# 7. Finish
# ----------------------------------------------------------------------------
finish() {
    local msg
    msg="Installation complete.

Installed:${INSTALLED_SUMMARY}

Display manager: ${DM}
Default boot target: graphical

Log file: ${LOGFILE}

At the login screen, use the session menu (gear / top-right) to pick which desktop or window manager to start.

A reboot is recommended (and required for the Argon boot-config changes to take effect)."

    whiptail --title "Done" --msgbox "$msg" 22 76 || true
    log "=== Installer finished ==="

    if whiptail --title "Reboot" --yesno "Reboot now?" 8 50; then
        log "Rebooting at user request"
        reboot
    fi
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    require_root "$@"
    ensure_whiptail
    preflight

    hardware_setup
    base_upgrade
    select_desktops
    install_desktops
    pick_display_manager
    install_display_manager
    ensure_vc4_xorg_config
    enable_graphical_boot
    finish
}

main "$@"
