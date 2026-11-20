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
LOG=/var/log/kiosk-install.log

# ---------------------------------------------------------------- colours
# Auto-off when stdout is not a terminal, so `| tee` / cron get clean text.
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_RST=$(printf '\033[0m');  C_BLD=$(printf '\033[1m')
  C_DIM=$(printf '\033[2m');  C_RED=$(printf '\033[31m')
  C_GRN=$(printf '\033[32m'); C_YEL=$(printf '\033[33m')
  C_BLU=$(printf '\033[34m'); C_CYN=$(printf '\033[36m')
else
  C_RST= C_BLD= C_DIM= C_RED= C_GRN= C_YEL= C_BLU= C_CYN=
fi

ok()   { printf '%s  ok%s %s\n'   "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%swarn%s %s\n'   "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%s err%s %s\n'   "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- spinner
# spin "Label, Please Wait" LOGFILE ["done message"] -- cmd [args...]
#   hides command output in LOGFILE, animates . .. ... with elapsed seconds,
#   prints "ok <done message>" on success, or the log tail on failure.
#   Exit status is the command's.
spin() {
  local label=$1 logf=$2 donemsg=""
  shift 2
  if [[ ${1:-} != -- ]]; then donemsg=$1; shift; fi
  [[ ${1:-} == -- ]] && shift
  [[ -n $donemsg ]] || donemsg=$label

  local rcf spid rc i=0 start=$SECONDS el
  local -a dots=('.  ' '.. ' '...')

  # pre-flight the log: the redirect below runs as the *invoking user*,
  # so a root-owned file fails here with a bare "Permission denied"
  if [[ ! -w $logf ]]; then
    printf '%s err%s log not writable by %s: %s\n' \
      "$C_RED" "$C_RST" "$(id -un)" "$logf" >&2
    printf '%s      fix: sudo chown %s:%s %s%s\n' \
      "$C_YEL" "$(id -un)" "$(id -gn)" "$logf" "$C_RST" >&2
    return 1
  fi

  # non-tty: no cursor tricks, no escape soup in the log
  if [[ ! -t 1 ]]; then
    printf '%s\n' "$label"
    "$@" >>"$logf" 2>&1 || return $?
    printf '  ok %s\n' "$donemsg"
    return 0
  fi

  # status via file: a finished child stays a zombie, so `kill -0` never
  # goes false and the classic poll loop can hang forever
  rcf=$(mktemp) || return 1
  ( "$@" >>"$logf" 2>&1; printf '%s' "$?" >"$rcf" ) &
  spid=$!

  printf '\033[?25l'
  trap 'printf "\033[?25h"' EXIT INT TERM
  while [[ ! -s $rcf ]]; do
    printf '\r\033[K  %s%s%s%s  %s%ds%s' \
      "$C_BLU" "$label" "${dots[i++%3]}" "$C_BLD" "$C_DIM" "$((SECONDS-start))" "$C_RST"
    sleep 0.2
  done
  wait "$spid" 2>/dev/null || true
  rc=$(cat "$rcf"); rm -f "$rcf"
  printf '\033[?25h'; trap - EXIT INT TERM

  el=$((SECONDS-start)); printf '\r\033[K'
  if ((rc == 0)); then
    printf '%s  ok%s %s %s(%ds)%s\n' "$C_GRN" "$C_RST" "$donemsg" "$C_DIM" "$el" "$C_RST"
  else
    # on failure report the label, not the success wording
    printf '%s err%s %s %s(failed after %ds, exit %d)%s\n' \
      "$C_RED" "$C_RST" "$label" "$C_DIM" "$el" "$rc" "$C_RST" >&2
    printf '%s--- last 40 lines of %s ---%s\n' "$C_YEL" "$logf" "$C_RST" >&2
    tail -n 40 "$logf" | sed 's/^/  /' >&2
  fi
  return "$rc"
}

while (($#)); do
  case $1 in
    --url)  URL=${2:?--url needs a value}; shift 2 ;;
    --user) U=${2:?--user needs a value};   shift 2 ;;
    --slim) SLIM=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------- 0. pre-flight
[[ $EUID -ne 0 ]] || die "run as a normal user with sudo, not as root"
[[ -e /boot/firmware/cmdline.txt ]] || die "not Pi OS: /boot/firmware/cmdline.txt missing"
# cache sudo BEFORE any spinner: a password prompt behind hidden output hangs
sudo -n true 2>/dev/null || sudo -v || die "sudo authentication failed"

ME=$(id -un); MG=$(id -gn)
# Owned by the invoking user, because spin() redirects into it as that user.
sudo install -d -m 0755 "$(dirname "$LOG")"
sudo install -m 0644 -o "$ME" -g "$MG" /dev/null "$LOG" \
  || die "could not create $LOG"
[[ -w $LOG ]] || die "$LOG not writable by $ME"
ok "sudo cached, log: $LOG"

ARCH=$(dpkg --print-architecture)
LONGBIT=$(getconf LONG_BIT)
case $ARCH in
  armhf) ok "32-bit OS Detected using kernel release: $(uname -r)" ;;
  arm64) ok "64-bit OS Detected using kernel release: $(uname -r)" ;;
  *)     die "Detected unsupported architecture '$ARCH' — this script has been tested to run on Raspberry Pi OS Lite 32/64bit (Trixie)" ;;
esac

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
# hidden output means an invisible conffile prompt would hang forever
DPKG_SAFE=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

spin "Updating Repos, Please Wait" "$LOG" "Repositories Updated" -- \
  sudo env DEBIAN_FRONTEND=noninteractive apt-get update -q \
  || die "apt-get update failed — see $LOG"

spin "Installing Packages, Please Wait" "$LOG" \
  "Successful Package Installation: ${PKGS[*]}" -- \
  sudo env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -q "${APT_OPTS[@]}" "${DPKG_SAFE[@]}" "${PKGS[@]}" \
  || die "package installation failed — see $LOG"

# rpi-swap owns zram on Trixie; purge zram-tools if an older image left it
if dpkg-query -W -f='${Status}' zram-tools 2>/dev/null | grep -q 'ok installed'; then
  spin "Removing zram-tools, Please Wait" "$LOG" "Removed conflicting zram-tools" -- \
    sudo env DEBIAN_FRONTEND=noninteractive apt-get purge -y -q zram-tools \
    || warn "zram-tools purge failed — see $LOG"
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
ok "Changes made to config.txt for presence of DRM + Mesa EGL"

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
printf '[Journal]\nStorage=persistent\nSystemMaxUse=64M\n' \
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
ok "journald persistent (64M cap), powersave off, tty1 autologin"

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

  ${C_CYN}Kiosk${C_RST}   : $URL
  ${C_CYN}User${C_RST}    : $U   log: /home/$U/cog.log
  ${C_CYN}Install${C_RST} : $LOG
  ${C_CYN}reload${C_RST}  : sudo pkill -x cog        ${C_DIM}(loop relaunches in 5s)${C_RST}

EOF
