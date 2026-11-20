#!/usr/bin/env bash
# =============================================================================
#  MagicMirror kiosk installer — Raspberry Pi OS Lite (Debian Trixie)
#  Works on armhf (32-bit) and arm64 (64-bit) images.
#
#  Run as a sudo-capable user, never as root:
#      chmod +x kiosk-install.sh
#      ./kiosk-install.sh                    # prompts for URL
#      ./kiosk-install.sh --url host:8080    # unattended
#
#  Options: --url URL   --user NAME   --slim (bigger saving, see notes)
#
#  Wi-Fi: the Zero 2 W (BCM43430/1) cannot complete SAE. The 2.4 GHz SSID
#  must be WPA2-PSK only, not WPA2/WPA3 mixed. If Wi-Fi dies after a router
#  change, check the AP's security mode before touching the Pi.
# =============================================================================
set -euo pipefail

U=mm
SLIM=0
URL=""

ok()   { printf '\033[32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m err\033[0m %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case $1 in
    --url)  URL=${2:?--url needs a value}; shift 2 ;;
    --user) U=${2:?--user needs a value};   shift 2 ;;
    --slim) SLIM=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------- 0. pre-flight
[[ $EUID -ne 0 ]] || die "run as a normal user with sudo, not as root"
[[ -e /boot/firmware/cmdline.txt ]] || die "not Pi OS: /boot/firmware/cmdline.txt missing"
sudo -v || die "sudo authentication failed"

ARCH=$(dpkg --print-architecture)
LONGBIT=$(getconf LONG_BIT)
case $ARCH in
  armhf) ok "arch armhf — 32-bit userland on ${LONGBIT}-bit kernel" ;;
  arm64) ok "arch arm64 — 64-bit" ;;
  *)     die "unsupported arch '$ARCH' — this targets Pi OS armhf/arm64" ;;
esac
ok "kernel $(uname -r)"

# ------------------------------------------------------------ 1. packages
# libegl1 and libgbm1 are hard deps of cog / libwpewebkit, so they are not
# listed. libgl1-mesa-dri (the v3d driver) and libgles2 are dlopen()ed at
# runtime and nothing pulls them in, so they must be explicit.
PKGS=(cog libegl-mesa0 libgl1-mesa-dri libgles2 curl ca-certificates)
APT_OPTS=(--no-install-recommends)
if (( SLIM )); then
  APT_OPTS+=(
    -o Dpkg::Options::=--path-exclude=/usr/share/doc/*
    -o Dpkg::Options::=--path-exclude=/usr/share/locale/*
    -o Dpkg::Options::=--path-include=/usr/share/locale/en*
  )
fi

sudo apt-get update
sudo apt-get install -y "${APT_OPTS[@]}" "${PKGS[@]}"
ok "packages: ${PKGS[*]}"

# rpi-swap owns zram on Trixie; purge zram-tools if an older image left it
if dpkg-query -W -f='${Status}' zram-tools 2>/dev/null | grep -q 'ok installed'; then
  sudo apt-get purge -y zram-tools
  ok "removed conflicting zram-tools"
fi

# DRM: distinguish "not configured" from "configured, not booted"
if [[ ! -e /dev/dri/card0 ]]; then
  if grep -qE '^[[:space:]]*dtoverlay=vc4-kms-v3d' /boot/firmware/config.txt; then
    die "/dev/dri/card0 missing but vc4-kms-v3d is enabled — reboot and re-run"
  else
    die "add 'dtoverlay=vc4-kms-v3d' to /boot/firmware/config.txt, reboot, re-run"
  fi
fi
ldconfig -p | grep -q 'libEGL_mesa\.so\.0' || die "libEGL_mesa.so.0 missing"
ok "DRM + Mesa EGL present"

# ------------------------------------------------------------ 2. kiosk URL
if [[ -z $URL ]]; then
  while :; do
    read -rp "MagicMirror host[:port] or full URL: " raw || die "no input"
    raw=${raw//[[:space:]]/}
    [[ -n $raw ]] || continue
    if [[ $raw != *://* ]]; then
      [[ $raw == *:* ]] || raw+=":8080"
      raw="http://$raw/"
    fi
    URL=$raw
    code=$(curl -s -o /dev/null -L -m 15 -w '%{http_code}' "$URL" || true)
    case $code in
      2*|3*|401|403|404) ok "$URL -> HTTP $code"; break ;;
    esac
    warn "$URL -> ${code/#000/no response}"
    read -rp "  use it anyway? [y/N] " a || die "no input"
    [[ $a == [yY] ]] && break
  done
fi
ok "kiosk URL: $URL"

# ------------------------------------------------------------ 3. kiosk user
id "$U" &>/dev/null || sudo adduser --disabled-password --gecos "" "$U"
sudo usermod -aG video,render,audio,input "$U"
ok "user $U (video,render,audio,input)"

# ------------------------------------------------------- 4. system drop-ins
sudo install -d /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=persistent\n' \
  | sudo tee /etc/systemd/journald.conf.d/99-persistent.conf >/dev/null

sudo install -d /etc/NetworkManager/conf.d
printf '[connection]\nwifi.powersave=2\n' \
  | sudo tee /etc/NetworkManager/conf.d/99-kiosk-powersave.conf >/dev/null

sudo install -d /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $U --noclear %I \$TERM
Type=simple
EOF
ok "journald persistent, powersave off, tty1 autologin"

# ------------------------------------------------------ 5. cog launch loop
if [[ -e "/home/$U/.bash_profile" ]]; then
  sudo cp -a "/home/$U/.bash_profile" "/home/$U/.bash_profile.bak.$(date +%s)"
  ok "backed up existing .bash_profile"
fi
{ printf 'URL=%q\n' "$URL"; cat <<'EOF'
[ -f ~/.profile ] && . ~/.profile

# physical console only, never over SSH
if [ "$(tty)" = /dev/tty1 ]; then
  setterm --blank 0 --powerdown 0 2>/dev/null
  while :; do
    cog -P drm --webprocess-failure=restart -b '#000000' "$URL" >>~/cog.log 2>&1
    rc=$?
    echo "$(date -Is) cog exited ($rc), restarting in 5s" >>~/cog.log
    sleep 5
  done
fi
EOF
} | sudo tee "/home/$U/.bash_profile" >/dev/null
sudo chown "$U:$U" "/home/$U/.bash_profile"
ok "cog loop -> $URL"

# --------------------------------------------------------------- 6. apply
sudo systemctl daemon-reload
sudo systemctl restart getty@tty1

cat <<EOF

Installed on $ARCH. Kiosk: $URL
  user    : $U   log: /home/$U/cog.log
  reload  : sudo pkill -x cog        (loop relaunches in 5s)
  remove  : sudo ./kiosk-uninstall.sh

Reboot once, then check:
  nmcli -f GENERAL.STATE device show wlan0   # 100 (connected)
  pgrep -a cog                               # cog -P drm ...
  systemctl --failed                         # empty
EOF
