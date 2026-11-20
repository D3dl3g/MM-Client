#!/usr/bin/env bash
# =============================================================================
#  MagicMirror² Kiosk Auto Installer — Raspberry Pi OS Lite (Debian Trixie)
#  armhf (32-bit) and arm64 (64-bit). All output goes to screen and log file.
#
#  Usage:
#    ./kiosk-install.sh                        # interactive
#    ./kiosk-install.sh --url host:8080        # unattended
#    ./kiosk-install.sh --url host:8080 --slim --no-reboot
#
#  Options:
#    --url URL      MagicMirror address (host[:port] or full URL)
#    --user NAME    kiosk user to create/use (default: mm)
#    --slim         exclude docs and non-English locales
#    --no-reboot    skip the end-of-install reboot countdown
#    -h, --help     this text
#
#  Wi-Fi: the Zero 2 W (BCM43430/1) cannot complete SAE. The 2.4 GHz SSID must
#  be WPA2-PSK only, not WPA2/WPA3 mixed. If Wi-Fi dies after a router change,
#  check the AP's security mode before touching the Pi.
# =============================================================================
set -Eeuo pipefail

U=mm
SLIM=0
URL=""
DO_REBOOT=1
LOG=/var/log/kiosk-install.log
APTLOG=/var/log/kiosk-install-apt.log

# --------------------------------------------------------------- arguments
while (($#)); do
  case $1 in
    --url)       URL=${2:?--url needs a value}; shift 2 ;;
    --user)      U=${2:?--user needs a value};   shift 2 ;;
    --slim)      SLIM=1; shift ;;
    --no-reboot) DO_REBOOT=0; shift ;;
    -h|--help)   sed -n '2,19p' "$0"; exit 0 ;;
    *)           printf 'err unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- palette
# initialised empty: die() is reachable before colours are enabled
RED= GREEN= YELLOW= BLUE= ORANGE= BOLD= DIM= NC=
RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
COLOUR=0
ISTTY=0

# --------------------------------------------------------------- messages
ok()   { printf '  %s✔%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '  %s⚠%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()  { printf '  %s✖%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }
hdr()  { printf '\n%s%s%s\n%s%s%s\n' "$BOLD" "$*" "$NC" "$DIM" "$RULE" "$NC"; }
# prompt/read are separate: read -p counts escape bytes as visible width and
# mangles redraws on narrow consoles
prompt() { printf '  %s%s%s ' "$1" "$2" "$NC"; }
# OSC 8 hyperlink; terminals without support print the text and drop the code
link() {
  if ((COLOUR)); then printf '%s\033]8;;%s\033\\%s\033]8;;\033\\%s' "$BLUE" "$1" "$2" "$NC"
  else printf '%s' "$2"; fi
}

# ---------------------------------------------------------------- spinner
# spin "Label, Please Wait" LOGFILE ["done message"] -- cmd [args...]
#   command output goes to LOGFILE only (screen stays quiet); braille spinner
#   with elapsed seconds on the tty; result line goes through tee into $LOG.
spin() {
  local label=$1 logf=$2 donemsg=""
  shift 2
  if [[ ${1:-} != -- ]]; then donemsg=$1; shift; fi
  [[ ${1:-} == -- ]] && shift
  [[ -n $donemsg ]] || donemsg=$label

  local rcf spid rc i=0 start=$SECONDS el nfr
  local -a frames=()
  case ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') ;;
    *)                                frames=('|' '/' '-' '\') ;;
  esac
  nfr=${#frames[@]}

  # the redirect runs as the invoking user, not root
  if [[ ! -w $logf ]]; then
    die "log not writable by $(id -un): $logf — fix: sudo chown $(id -un):$(id -gn) $logf"
  fi

  rcf=$(mktemp) || die "mktemp failed"
  # set +eE / trap - ERR: otherwise errexit kills the worker before it can
  # record the status, and the spinner waits forever on an empty status file
  if ((ISTTY)); then
    ( set +eE; trap - ERR; "$@" >>"$logf" 2>&1; printf '%s' "$?" >"$rcf" ) &
    spid=$!
    printf '\033[?25l' >&3
    while [[ ! -s $rcf ]]; do
      printf '\r\033[K  %s%s%s %s%s%s  %s%3ds%s' \
        "$BLUE" "$label" "$NC" "$BOLD" "${frames[i++%nfr]}" "$NC" \
        "$DIM" "$((SECONDS-start))" "$NC" >&3
      sleep 0.2
    done
    wait "$spid" 2>/dev/null || true
    printf '\r\033[K\033[?25h' >&3
    sleep 0.05                      # let tee catch up before the result line
    rc=$(cat "$rcf")
  else
    "$@" >>"$logf" 2>&1; rc=$?
  fi
  rm -f "$rcf"

  el=$((SECONDS-start))
  if ((rc == 0)); then
    ok "$donemsg ${DIM}(${el}s)${NC}"
  else
    printf '  %s✖ %s%s %s(failed after %ss, exit %d)%s\n' \
      "$RED" "$label" "$NC" "$DIM" "$el" "$rc" "$NC" >&2
    printf '  %s--- last 40 lines of %s ---%s\n' "$YELLOW" "$logf" "$NC" >&2
    # strip SGR + OSC so a package's control codes cannot reach our terminal
    tail -n 40 "$logf" \
      | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07\x1b]*(\x07|\x1b\\)//g' \
      | sed 's/^/  /' >&2
  fi
  return "$rc"
}

# ---------------------------------------------------------- pre-flight
[[ $EUID -ne 0 ]] || die "run as a normal user with sudo, never as root"
[[ -e /boot/firmware/cmdline.txt ]] || die "not Pi OS: /boot/firmware/cmdline.txt missing"

sudo -n true 2>/dev/null || sudo -v || die "sudo authentication failed"

ME=$(id -un); MG=$(id -gn)
sudo install -d -m 0755 /var/log
sudo install -m 0644 -o "$ME" -g "$MG" /dev/null "$LOG"    || die "cannot create $LOG"
sudo install -m 0644 -o "$ME" -g "$MG" /dev/null "$APTLOG" || die "cannot create $APTLOG"
[[ -w $LOG && -w $APTLOG ]] || die "logs not writable by $ME"

# save the real terminal on fd 3, then tee everything else into the log.
# ISTTY must be decided BEFORE the redirect: after it, fd 1 is a pipe and
# every `[[ -t 1 ]]` test would fail, killing colour and the spinner.
exec 3>&1
[[ -t 3 ]] && ISTTY=1
exec > >(tee -a "$LOG") 2>&1

if ((ISTTY)) && [[ -z ${NO_COLOR:-} ]]; then
  COLOUR=1
  RED=$(printf '\033[1;31m')
  GREEN=$(printf '\033[1;32m')
  YELLOW=$(printf '\033[1;33m')
  BLUE=$(printf '\033[1;34m')
  ORANGE=$(printf '\033[1;38;5;208m')   # 256-colour: a true orange, unlike 0;33
  BOLD=$(printf '\033[1m')
  DIM=$(printf '\033[2m')
  NC=$(printf '\033[0m')
fi

trap 'printf "\033[?25h" >&3 2>/dev/null || true
      printf "\n%serr%s interrupted — log: %s\n" "$RED" "$NC" "$LOG" >&2
      exit 130' INT
trap 'printf "  %serr%s command failed: %s (line %s)\n" "$RED" "$NC" "$BASH_COMMAND" "$LINENO" >&2' ERR

echo
printf '%sMagicMirror² Kiosk Auto Installer%s\n' "$YELLOW" "$NC"
echo
echo "Date: $(date)"
echo "Log : $LOG"
printf '%s%s%s\n' "$DIM" "$RULE" "$NC"

# ---------------------------------------------------------------- platform
hdr "⚙️  PLATFORM"
ARCH=$(dpkg --print-architecture)
KREL=$(uname -r)
case $ARCH in
  armhf) DESC="32-bit OS (armhf)" ;;
  arm64) DESC="64-bit OS (arm64)" ;;
  *) die "unsupported architecture '$ARCH' — tested on Raspberry Pi OS Lite 32/64-bit (Trixie)" ;;
esac
printf '  %s✔%s %s%s%s %sDetected using kernel release:%s %s%s%s\n' \
  "$GREEN" "$NC" "$ORANGE" "$DESC" "$NC" "$GREEN" "$NC" "$ORANGE" "$KREL" "$NC"
ok "sudo cached, logs writable"

# ---------------------------------------------------------------- packages
hdr "⚙️  PACKAGES"
# libegl1 and libgbm1 are hard deps of cog/libwpewebkit, so they are not
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

spin "Updating Repos, Please Wait" "$APTLOG" "⚙️  Repositories Updated" -- \
  sudo env DEBIAN_FRONTEND=noninteractive apt-get update -q \
  || die "apt-get update failed — see $APTLOG"

spin "Installing Packages, Please Wait" "$APTLOG" \
  "⚙️  Installed: ${PKGS[*]}" -- \
  sudo env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -q "${APT_OPTS[@]}" "${DPKG_SAFE[@]}" "${PKGS[@]}" \
  || die "package installation failed — see $APTLOG"

# rpi-swap owns zram on Trixie; purge zram-tools if an older image left it
if dpkg-query -W -f='${Status}' zram-tools 2>/dev/null | grep -q 'ok installed'; then
  spin "Removing zram-tools, Please Wait" "$APTLOG" \
    "⚙️  Removed conflicting zram-tools" -- \
    sudo env DEBIAN_FRONTEND=noninteractive apt-get purge -y -q zram-tools \
    || warn "zram-tools purge failed — see $APTLOG"
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
ok "⚙️  DRM device and Mesa EGL present"

# ---------------------------------------------------------------- network
hdr "🌐  KIOSK ADDRESS"
if [[ -z $URL ]]; then
  while :; do
    prompt "$BLUE" "🌐  MagicMirror host[:port] or full URL:"
    read -r raw || die "no input"
    raw=${raw//[[:space:]]/}
    [[ -n $raw ]] || continue
    if [[ $raw != *://* ]]; then
      [[ $raw == *:* ]] || raw+=":8080"
      raw="http://$raw/"
    fi
    code=$(curl -s -o /dev/null -L -m 15 -w '%{http_code}' "$raw" || true)
    if [[ $code == [234]* ]]; then
      URL=$raw; ok "🌐  Reachable: $raw (HTTP $code)"; break
    fi
    printf '  %s!%s %s%s -> %s%s\n' "$YELLOW" "$NC" "$ORANGE" "$raw" \
      "${code/#000/no response}" "$NC" >&2
    prompt "$ORANGE" "🌐  use it anyway? [y/N]"
    read -r a || die "no input"
    if [[ $a == [yY] ]]; then URL=$raw; ok "🌐  Accepted: $URL"; break; fi
  done
fi

# ---------------------------------------------------------------- kiosk user
hdr "👤  KIOSK USER"
# no password and no sudo group: tty1 autologin needs neither, and a kiosk
# account that cannot sudo is the safer default
id "$U" &>/dev/null || sudo adduser --disabled-password --gecos "" "$U"
sudo usermod -aG video,render,audio,input "$U"
ok "👤  user $U in groups video,render,audio,input (no password, no sudo)"

# ---------------------------------------------------------------- drop-ins
hdr "⚙️  SYSTEM DROP-INS"
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
ok "⚙️  journald persistent (64M cap), wifi powersave off, tty1 autologin"

# ---------------------------------------------------------------- launcher
hdr "🖥️  KIOSK LAUNCHER"
if [[ -e "/home/$U/.bash_profile" ]]; then
  sudo cp -a "/home/$U/.bash_profile" "/home/$U/.bash_profile.bak.$(date +%s)"
  ok "🖥️  backed up existing .bash_profile"
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
ok "🖥️  cog watchdog loop -> $URL"

sudo systemctl daemon-reload
sudo systemctl restart getty@tty1
ok "⚙️  getty@tty1 reloaded"

# ---------------------------------------------------------------- summary
CLOG="/home/$U/cog.log"
echo
printf '%s%s%s\n' "$GREEN" "$RULE" "$NC"
printf '  %s👤 User%s      : %s%s%s\n'        "$BOLD" "$NC" "$GREEN" "$U" "$NC"
printf '  %s🖥️  Kiosk%s     : %s\n'           "$BOLD" "$NC" "$(link "$URL" "$URL")"
printf '  %s📝 User log%s  : %s%s%s\n'        "$BOLD" "$NC" "$GREEN" "$CLOG" "$NC"
printf '               %scat %s%s\n'          "$DIM" "$CLOG" "$NC"
printf '  %s📝 Install%s   : %s%s%s\n'        "$BOLD" "$NC" "$GREEN" "$LOG" "$NC"
printf '               %scat %s%s\n'          "$DIM" "$LOG" "$NC"
printf '  %s📝 Apt log%s   : %s%s%s\n'        "$BOLD" "$NC" "$GREEN" "$APTLOG" "$NC"
printf '               %scat %s%s\n'          "$DIM" "$APTLOG" "$NC"
printf '  %s⚙️  Reload%s    : %ssudo pkill -x cog%s (relaunches in 5s)\n' \
  "$BOLD" "$NC" "$DIM" "$NC"
printf '%s%s%s\n' "$GREEN" "$RULE" "$NC"

# ---------------------------------------------------------------- reboot
if (( DO_REBOOT )); then
  if (( ISTTY )); then
    echo
    printf '  %s⚙️  Rebooting in 30s — press any key to cancel%s\n' "$ORANGE" "$NC"
    for ((i=30; i>0; i--)); do
      printf '\r  %s⚙️  Rebooting in %2ds — any key to cancel%s ' "$ORANGE" "$NC" >&3
      if IFS= read -rsn1 -t 1 _ </dev/tty; then
        printf '\r\033[K' >&3
        printf '  %s⚠  Reboot cancelled — run %ssudo reboot%s when ready\n' \
          "$YELLOW" "$NC" "$BOLD" "$NC"
        DO_REBOOT=0
        break
      fi
    done
    printf '\r\033[K' >&3
  else
    printf '\n  %s⚙️  Reboot to finish: sudo reboot%s\n' "$ORANGE" "$NC"
    DO_REBOOT=0
  fi
fi

if (( DO_REBOOT )); then
  printf '\n  %s⚙️  SETUP COMPLETE — rebooting now%s\n' "$ORANGE" "$NC"
  sleep 0.5              # give tee time to flush the last lines
  sudo systemctl reboot
else
  printf '\n  %s⚙️  SETUP COMPLETE%s\n' "$ORANGE" "$NC"
fi
