#!/bin/bash
# lidsleep.sh — what the laptop does when the lid closes (gdeyoung.powercore).
#
# Mechanism vendored from Daferia/omarchy-lid-sleep (MIT), commit 64eadcd
# 2026-10-22: systemd logind/sleep drop-ins + a system-sleep hook that logs
# battery % around each sleep. Adaptations for PowerCore:
#   - "system" mode removes the drop-ins (platform default behavior)
#   - HandleLidSwitchDocked is NEVER written here: PowerCore's session
#     inhibit lock owns clamshell/docked behavior dynamically
#   - delay is an integer minute count; the panel offers 15/30/60/120/180
#   - hibernate readiness also rejects zram-only swap (zram cannot hibernate)
#
# Modes:
#   smart    lid closed -> suspend, then hibernate after the delay (battery
#            only; HibernateOnACPower=no keeps AC in light sleep)
#   suspend  light sleep only (s2idle drains ~1%/h on this hardware)
#   hibernate hibernate immediately
#   lock     lock the session, stay awake
#   ignore   do nothing
#   system   remove PowerCore's drop-ins; logind defaults apply
#
# Root is required only for set/delay/remove; json/status/history read.
set -euo pipefail

LOGIND_CONF=/etc/systemd/logind.conf.d/30-powercore-lid.conf
SLEEP_CONF=/etc/systemd/sleep.conf.d/30-powercore-lid.conf
HOOK=/usr/lib/systemd/system-sleep/powercore-lid-log
STATE_DIR=/var/lib/powercore-lid

SUDO=sudo; [[ $EUID -eq 0 ]] && SUDO=

usage() {
  cat <<USAGE
Usage: lidsleep.sh <command>

  status                    Current lid settings and recent sleep history
  json                      Status as JSON (used by the PowerCore panel)
  set smart [MINUTES]       Sleep, then hibernate after MINUTES (default 60)
  set suspend|hibernate|lock|ignore|system
  delay MINUTES             Change the smart-mode hibernate delay
  history                   Battery used during each recent sleep
  test-hibernate            Hibernate right now to verify resume works
  remove                    Remove all PowerCore lid settings and the logger

MINUTES: integer 5..720 (panel offers 15/30/60/120/180).
USAGE
}

hibernation_ready() {
  grep -qw disk /sys/power/state &&
    [[ -n $(cat /sys/power/resume 2>/dev/null | grep -v '^0:0$') ]] &&
    swapon --noheadings --show=NAME,TYPE 2>/dev/null | grep -v '/dev/zram' | grep -q .
}

valid_minutes() {
  [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 5 && $1 <= 720 ))
}

write_root_file() { # path; content on stdin
  $SUDO install -d -m 755 "$(dirname "$1")"
  $SUDO tee "$1" >/dev/null
}

reload_logind() {
  # SIGHUP makes logind re-read config without ending the session.
  $SUDO systemctl kill -s HUP systemd-logind
}

install_hook() {
  write_root_file "$HOOK" <<'HOOK_EOF'
#!/bin/sh
# Managed by gdeyoung.powercore: log battery % around each sleep so the
# panel can show what a closed lid really cost. Runs as root.
bat=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -1)
[ -n "$bat" ] || exit 0
pct=$(cat "$bat/capacity" 2>/dev/null)
mkdir -p /var/lib/powercore-lid
echo "$(date +%s) $1 $2 ${SYSTEMD_SLEEP_ACTION:-$2} $pct" >> /var/lib/powercore-lid/history
tail -n 400 /var/lib/powercore-lid/history > /var/lib/powercore-lid/history.tmp && mv /var/lib/powercore-lid/history.tmp /var/lib/powercore-lid/history
logger -t powercore-lid "$1 $2 (${SYSTEMD_SLEEP_ACTION:-$2}) battery=${pct}%"
HOOK_EOF
  $SUDO chmod 755 "$HOOK"
}

apply_mode() { # logind action (may be empty = remove), delay minutes
  local action=${1:-} delay=${2:-}

  if [[ -n $action ]]; then
    write_root_file "$LOGIND_CONF" "# Managed by gdeyoung.powercore
[Login]
HandleLidSwitch=$action
HandleLidSwitchExternalPower=$action
# Docked lid behavior is owned by PowerCore's session inhibit lock
# (clamshell toggle); no HandleLidSwitchDocked line is written here."
  else
    $SUDO rm -f "$LOGIND_CONF"
  fi

  if [[ $action == suspend-then-hibernate ]]; then
    write_root_file "$SLEEP_CONF" "# Managed by gdeyoung.powercore
[Sleep]
AllowSuspendThenHibernate=yes
HibernateDelaySec=${delay}min
# On AC power, stay in light sleep instead of hibernating
HibernateOnACPower=no"
  else
    $SUDO rm -f "$SLEEP_CONF"
  fi

  install_hook
  reload_logind
}

cmd_set() {
  local mode=${1:-} delay=${2:-60}
  case $mode in
    smart)
      valid_minutes "$delay" || { echo "Invalid delay: $delay (5..720 minutes)" >&2; exit 1; }
      hibernation_ready || {
        echo "Hibernation isn't set up. Run: omarchy hibernation setup  (then reboot)" >&2
        exit 1
      }
      apply_mode suspend-then-hibernate "$delay"
      echo "Lid close: sleep, then hibernate after ${delay}min on battery."
      ;;
    suspend) apply_mode suspend; echo "Lid close: sleep only." ;;
    hibernate)
      hibernation_ready || { echo "Hibernation isn't set up. Run: omarchy hibernation setup" >&2; exit 1; }
      apply_mode hibernate; echo "Lid close: hibernate immediately." ;;
    lock)    apply_mode lock;    echo "Lid close: lock only." ;;
    ignore)  apply_mode ignore;  echo "Lid close: do nothing." ;;
    system)  apply_mode "";      echo "Lid close: system default (PowerCore drop-ins removed)." ;;
    *) usage; exit 1 ;;
  esac
}

cmd_delay() {
  local delay=${1:?Give a delay in minutes, e.g. 45}
  valid_minutes "$delay" || { echo "Invalid delay: $delay (5..720 minutes)" >&2; exit 1; }
  grep -q 'suspend-then-hibernate' "$LOGIND_CONF" 2>/dev/null ||
    { echo "Delay only applies to smart mode. Run: lidsleep.sh set smart $delay" >&2; exit 1; }
  apply_mode suspend-then-hibernate "$delay"
  echo "Hibernate delay set to ${delay}min."
}

# Pair each "pre" line with the next "post" line; $4 is the FINAL action
# (suspend vs hibernate after a suspend-then-hibernate escalation).
history_awk='
  $2=="pre"  { t=$1; p=$5; next }
  $2=="post" && t {
    mins=($1-t)/60; used=p-$5
    rate = mins>0 ? used/(mins/60) : 0
    printf "%s  %-16s %6.0f min  %3d%% -> %3d%%  (%.1f%%/hour)\n",
      strftime("%Y-%m-%d %H:%M", t), $4, mins, p, $5, rate
    t=0
  }'

cmd_history() {
  if [[ ! -x $HOOK ]]; then
    echo "Not recording: no lid mode has been applied yet. Run: lidsleep.sh set smart"
    return
  fi
  [[ -s $STATE_DIR/history ]] || { echo "No sleep history yet. Close the lid for a while first."; return; }
  awk "$history_awk" "$STATE_DIR/history" | tail -n 15
}

cmd_status() {
  echo "Lid close (battery): $(systemd-analyze cat-config systemd/logind.conf | awk -F= '/^HandleLidSwitch=/{v=$2} END{print v?v:"suspend (default)"}')"
  echo "Lid close (AC):      $(systemd-analyze cat-config systemd/logind.conf | awk -F= '/^HandleLidSwitchExternalPower=/{v=$2} END{print v?v:"same as battery"}')"
  local d; d=$(systemd-analyze cat-config systemd/sleep.conf | awk -F= '/^HibernateDelaySec=/{v=$2} END{print v}')
  [[ -n $d ]] && echo "Hibernate after:     $d (battery only)"
  echo "Sleep type:          $(cat /sys/power/mem_sleep)"
  echo "Hibernation ready:   $(hibernation_ready && echo yes || echo no)"
  echo
  echo "Recent sleeps:"
  cmd_history | sed 's/^/  /'
}

# Line-wise: logind.conf and sleep.conf merged (cat-config), later files
# override, so the LAST matching directive line wins. delay parses systemd
# timespans (min/h/s) into whole minutes.
json_awk='
  function mins(spec,  n, u, total) {
    total=0
    while (match(spec, /[0-9]+(min|h|s)/)) {
      n=substr(spec, RSTART, RLENGTH); u=n; sub(/[0-9]+/, "", u); sub(/[a-z]+$/, "", n)
      if (u=="h") total+=n*60; else if (u=="s") total+=n/60; else total+=n
      spec=substr(spec, RSTART+RLENGTH)
    }
    return int(total+0.5)
  }
  BEGIN { mode="system"; delayMin=0 }
  /^HandleLidSwitch=/ {
    v=$0; sub(/^HandleLidSwitch=/, "", v)
    mode = (v=="suspend-then-hibernate" ? "smart" : v)
  }
  /^HibernateDelaySec=/ { v=$0; sub(/^[^=]*=/, "", v); delayMin=mins(v) }
  END {
    printf "{\"mode\":\"%s\",\"delayMin\":%d,\"hibernationReady\":%s",
      mode, delayMin, (ready == "true" ? "true" : "false")
  }'

cmd_json() {
  local ready=false recording=false
  hibernation_ready && ready=true
  [[ -x $HOOK ]] && recording=true
  local cfg
  cfg=$(systemd-analyze cat-config systemd/logind.conf systemd/sleep.conf 2>/dev/null || true)
  # systemd-analyze prints file headers as "# path"; strip them so only
  # effective directives remain for the awk below.
  cfg=$(printf '%s\n' "$cfg" | grep -vE '^\s*#' || true)
  local head
  head=$(printf '%s\n' "$cfg" | awk -v ready="$ready" "$json_awk")
  local hist=""
  # Buffer pairs in awk and emit only the last 20 — a byte-level tail could
  # chop the JSON mid-token.
  [[ -s $STATE_DIR/history ]] && hist=$(awk '
    $2=="pre"  { t=$1; p=$5; next }
    $2=="post" && t {
      n++; st[n]=t; mn[n]=($1-t)/60; ty[n]=$4; pf[n]=p; pt[n]=$5; t=0
    }
    END {
      first=(n>20 ? n-19 : 1)
      for (i=first; i<=n; i++)
        printf "%s{\"start\":%d,\"minutes\":%.0f,\"type\":\"%s\",\"from\":%d,\"to\":%d}",
          (i>first ? "," : ""), st[i], mn[i], ty[i], pf[i], pt[i]
    }' "$STATE_DIR/history")
  printf '%s,"recording":%s,"history\":[%s]}\n' "$head" "$recording" "$hist"
}

cmd_remove() {
  $SUDO rm -f "$LOGIND_CONF" "$SLEEP_CONF" "$HOOK"
  reload_logind
  echo "Removed. Lid close is back to the system default; drain logging is off."
}

case ${1:-status} in
  status) cmd_status ;;
  set) shift; cmd_set "$@" ;;
  delay) shift; cmd_delay "$@" ;;
  history) cmd_history ;;
  json) cmd_json ;;
  test-hibernate) echo "Hibernating in 3s... power on again to resume."; sleep 3; systemctl hibernate ;;
  remove) cmd_remove ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
