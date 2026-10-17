#!/bin/sh
# qscan-run.sh <mode_num 1-3> <mode_name lte|nr|all> <task_id>
# Detached QSCAN job. Holds the webui AT lock for the whole scan, drains,
# then does a bounded network-recovery check. Talks ONLY to ttyUSB2 (webui port).
# All state under /tmp/qscan (tmpfs, cleared on reboot). Never touches ttyUSB3.

QDIR=/tmp/qscan
WORKER=/usr/libexec/qscan/qscan-worker
WEBUI_NUM_FILE=/run/rm502q-at/webui
WEBUI_LOCK=/tmp/rm502q-webui-at.lock
HARD_MS=240000          # hard cap (NR measured ~186s, margin to 240s)
DRAIN_MS=3000

MODE_NUM="$1"; MODE_NAME="$2"; TID="$3"
[ -n "$MODE_NUM" ] && [ -n "$MODE_NAME" ] && [ -n "$TID" ] || exit 5

TDIR="$QDIR/tasks/$TID"
mkdir -p "$TDIR" 2>/dev/null
META="$TDIR/meta"
RAW="$TDIR/raw.txt"
CELLS="$TDIR/cells.txt"

now(){ date +%s; }
log(){ echo "$(date '+%m-%d %H:%M:%S') [qscan #$TID] $*" >> "$QDIR/qscan.log"; }

# meta writer: set_meta key value
set_meta(){
  k="$1"; shift; v="$*"
  if [ -f "$META" ] && grep -q "^$k=" "$META" 2>/dev/null; then
    sed -i "s|^$k=.*|$k=$v|" "$META"
  else
    echo "$k=$v" >> "$META"
  fi
}

STARTED=$(now)
: > "$META"
set_meta task_id "$TID"
set_meta mode "$MODE_NAME"
set_meta mode_num "$MODE_NUM"
set_meta status running
set_meta created_at "$STARTED"
set_meta started_at "$STARTED"
set_meta finished_at ""
set_meta elapsed 0
set_meta ncells 0
set_meta network_status ""
set_meta error ""

echo "$TID" > "$QDIR/current"
echo "$$"  > "$QDIR/scanning"     # PID of this job = scanning indicator
log "start mode=$MODE_NAME ($MODE_NUM)"

cleanup(){
  # ensure the scanning flag is cleared no matter how we exit
  [ -f "$QDIR/scanning" ] && rm -f "$QDIR/scanning"
}
trap 'cleanup' EXIT INT TERM

# resolve the webui AT tty (dynamic) — MUST be the webui port, never ttyUSB3
IDX=$(cat "$WEBUI_NUM_FILE" 2>/dev/null)
case "$IDX" in ""|*[!0-9]*)
  log "serial_error: webui port index not ready ('$IDX')"
  set_meta status error; set_meta error serial_error
  set_meta finished_at "$(now)"; set_meta elapsed $(( $(now) - STARTED ))
  exit 4
esac
DEV="/dev/ttyUSB$IDX"
if [ ! -c "$DEV" ]; then
  log "serial_error: $DEV missing"
  set_meta status error; set_meta error serial_error
  set_meta finished_at "$(now)"; set_meta elapsed $(( $(now) - STARTED ))
  exit 4
fi
set_meta tty "$DEV"
log "using $DEV; sending AT+QSCAN=$MODE_NUM"

# --- the scan: exclusive lock for the ENTIRE worker lifetime + drain ---
flock -x "$WEBUI_LOCK" "$WORKER" "$DEV" "$MODE_NUM" "$RAW" "$HARD_MS" "$HARD_MS" "$DRAIN_MS"
WEXIT=$?
END=$(now)
ELAPSED=$(( END - STARTED ))
set_meta elapsed "$ELAPSED"
log "worker exit=$WEXIT elapsed=${ELAPSED}s"

# scan is done -> drop the scanning indicator so normal AT can resume
cleanup

# extract cell lines (only real +QSCAN rows)
grep '^+QSCAN:' "$RAW" > "$CELLS" 2>/dev/null
NC=$(wc -l < "$CELLS" 2>/dev/null | tr -d ' ')
[ -n "$NC" ] || NC=0
set_meta ncells "$NC"
log "raw_lines=$NC"

case "$WEXIT" in
  0)  set_meta status scan_complete ;;
  2)  set_meta status error; set_meta error modem_error
      set_meta finished_at "$END"; log "modem_error"; exit 2 ;;
  3)  set_meta status error; set_meta error timeout
      set_meta finished_at "$END"; log "timeout"; exit 3 ;;
  4|5)set_meta status error; set_meta error serial_error
      set_meta finished_at "$END"; log "serial_error"; exit 4 ;;
  *)  set_meta status error; set_meta error worker_error
      set_meta finished_at "$END"; log "worker_error($WEXIT)"; exit 1 ;;
esac

# --- bounded network recovery check (no serial; uses QMI data path only) ---
set_meta status recovering_network
NETOK=0
i=0
while [ "$i" -lt 10 ]; do          # up to ~20s
  if ip -4 addr show wwan0_1 2>/dev/null | grep -q "inet "; then
    if ping -c1 -W2 223.5.5.5 >/dev/null 2>&1; then NETOK=1; break; fi
  fi
  i=$((i+1)); sleep 2
done
if [ "$NETOK" = 1 ]; then
  set_meta network_status ready
  log "network recovery=ready"
else
  set_meta network_status recovery_timeout
  log "network recovery=timeout"
fi

set_meta status success
set_meta finished_at "$(now)"
log "done status=success network=$(grep '^network_status=' "$META" | cut -d= -f2)"
exit 0
