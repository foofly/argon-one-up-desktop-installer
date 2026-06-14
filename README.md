# Argon ONE UP — Desktop / Window Manager installer

A single Bash + `whiptail` TUI that turns a fresh **Raspberry Pi OS Lite 64-bit**
install on an **Argon ONE UP** (Raspberry Pi CM5, Pi 5–class) into a graphical
system with the desktop(s) or window manager(s) of your choice.

It is based on the
[Argon ONE UP setup guide](https://forum.argon40.com/t/my-argon-one-up-setup-guide-user-experience-rpi-os-lite-gnome-desktop/9151),
generalised beyond GNOME to also cover XFCE, KDE Plasma, and several window managers.

## What it does

1. **Argon ONE UP hardware/boot setup** (runs first, idempotent):
   - Appends the guide's overlays to `/boot/firmware/config.txt`
     (`nvme`, `pciex1_gen=3`, `dwc2` USB host, `usb_max_current_enable`,
     `uart0`, `ant2`) — only if not already present.
   - Optionally forces the HDMI mode `video=HDMI-A-2:1920x1200@60e` in
     `/boot/firmware/cmdline.txt` (skippable — display-specific).
   - Optionally runs the official Argon support script
     (`curl https://download.argon40.com/argononeup.sh | bash`).
   - Backs up `config.txt` / `cmdline.txt` to `*.argon-installer.bak` before editing.
2. **Optional full system upgrade** (`apt-get full-upgrade` + `autoremove`).
3. **Multi-select install** of any combination of:

   | Choice | Packages |
   |--------|----------|
   | XFCE desktop | `xfce4`, `xfce4-goodies` |
   | KDE Plasma desktop | `kde-plasma-desktop` |
   | GNOME desktop | `gnome-core` (+ optional extras) |
   | i3 (X11 tiling WM) | `i3` (incl. dmenu/i3status/i3lock) |
   | Sway (Wayland tiling WM) | `sway`, `swaybg`, `foot`, `wmenu` |
   | LXQt desktop | `lxqt-core` |
   | LXDE desktop | `lxde-core` |

   Lean metapackages are used so they don't drag in their own display manager.
4. **Display manager** — picked automatically and installed for you:
   - GNOME selected → `gdm3`
   - else KDE selected → `sddm`
   - else Sway selected → `gdm3` (better Wayland support than lightdm)
   - else → `lightdm` + `lightdm-gtk-greeter`

   The choice is made deterministic by writing `/etc/X11/default-display-manager`
   and running `dpkg-reconfigure -f noninteractive`.
5. **Switches to graphical boot** (`systemctl set-default graphical.target`) and
   offers to reboot.

Every `apt` step is shown behind a live **whiptail progress gauge** (driven by
apt's `APT::Status-Fd` output: download maps to 0–50%, install/configure to
50–100%), with a step counter (e.g. "Installing KDE Plasma (2 of 3)"). Long
non-apt steps (the Argon support script, display-manager configuration) show an
info box. Full apt output still streams to the log file.

All selected desktops/WMs coexist. At the login screen, use the session menu to
choose which one to start.

## Usage

```bash
sudo ./install.sh
```

(The script re-executes itself with `sudo` if not run as root.)

Everything is logged to `/var/log/argon-desktop-installer.log`.

## Requirements

- Raspberry Pi OS Lite 64-bit (Debian 13 "Trixie") on an Argon ONE UP / CM5.
- Network access (apt + the optional Argon vendor script).
- `whiptail` (installed automatically if missing).

## Testing

- Lint locally: `bash -n install.sh` and `shellcheck install.sh`.
- On-device: flash RPi OS Lite, run `sudo ./install.sh`, select e.g. XFCE + Sway,
  reboot, and confirm both sessions appear at the login screen and start.

## Out of scope (manual extras)

The forum guide also covers items intentionally **not** automated here — add them
manually if you want them:

- Spanish locale / LibreOffice language packs
- Chromium + Widevine (`libwidevinecdm0`) DRM streaming
- Yaru theme `.deb`s, Plymouth `pix` splash theming, GdmSettings
- Pi-Apps (Botspot) app store
- The third-party battery DKMS driver for the laptop shell

## Known issue

Some Trixie builds have reported a **V3D GPU hang/reset under Wayland** on Pi 4/5
after extended use. It's a kernel/Mesa stability bug (mitigated by staying updated),
not something this installer changes. If you hit it, prefer an X11 session
(XFCE/i3/LXDE) or keep firmware/Mesa current.
