#!/bin/sh
# Dynamic QMI WAN DNS tracker for OpenClash.
# Reads operator DNS from the live network interface state (ubus), persists it,
# compares against last known, and only when it *really* changes: validates and
# (re)generates the OpenClash config so the fresh operator IPv6 DNS is applied.
#
# IPv4 is followed natively by Mihomo `dhcp://"wwan0_1"` (no reload needed);
# IPv6 has no dhcpv6 DNS mechanism in Mihomo, so a genuine IPv6 operator-DNS
# change needs one config regeneration (via one OpenClash restart).
#
# ---------------------------------------------------------------------------
# v2 2026-10-03  (fixes: one WWAN reconnect caused 2 OpenClash restarts and a
#                  ~1 minute CPU spike / fan surge)
#
#  1) DEBOUNCE + COALESCE.
#     The first caller becomes the single "settler" (atomic mkdir lock) and
#     waits until the WAN event storm has been quiet for OC_WANDNS_SETTLE
#     seconds before acting. Any further event that arrives meanwhile only
#     touches a `pending` marker (which extends the wait, hard-capped by
#     OC_WANDNS_MAXWAIT); followers never spawn workers and exit immediately.
#     => one WWAN flap can only ever produce ONE decision / ONE restart.
#
#  2) TRANSIENT IPv6-DNS LOSS IS NOT A CHANGE.
#     While USBv6 is being torn down and rebuilt, the IPv6 DNS is momentarily
#     absent (ubus USBv6 returns nothing) while the IPv4 half is still there.
#     The old version treated that as "IPv6 DNS disappeared" (restart #1) and
#     then, when USBv6 came back, as "IPv6 DNS appeared" (restart #2). Now such
#     a transient disappearance is ignored and the last known IPv6 value is
#     kept in the state file, so the reappearance compares equal -> no action.
#
#  3) THE RESTART MUST REALLY REGENERATE THE CONFIG.
#     /tmp/openclash.change (the quick-start fingerprint cache) is removed
#     before restarting, so check_run_quick() cannot silently take the
#     "Quick Start Mode, Skip Modify The Config File" path - which would
#     restart mihomo with the *unchanged* config and make the restart useless.
#
# Usage: oc-wandns.sh [--force]
#
# Overridable knobs (defaults reproduce the production behaviour; the
# OC_WANDNS_* ones exist for dry-run testing):
#   OC_WANDNS_SETTLE      quiet seconds required before acting   (default 20)
#   OC_WANDNS_MAXWAIT     hard cap for one settle cycle, seconds (default 75)
#   OC_WANDNS_LOG/STATE/STATE_TXT/LOCK/CHANGE/RESTART_CMD
#   OC_WANDNS_DRYRUN=1    do not touch uci / do not restart OpenClash
# ---------------------------------------------------------------------------
LOG="${OC_WANDNS_LOG:-/tmp/oc-wandns.log}"
STATE="${OC_WANDNS_STATE:-/etc/openclash/wan_dns_state}"
STATE_TXT="${OC_WANDNS_STATE_TXT:-/etc/openclash/wan_dns.txt}"
LOCK="${OC_WANDNS_LOCK:-/var/lock/oc-wandns.debounce}"
CHANGE="${OC_WANDNS_CHANGE:-/tmp/openclash.change}"
RESTART_CMD="${OC_WANDNS_RESTART_CMD:-/etc/init.d/openclash restart}"
SETTLE="${OC_WANDNS_SETTLE:-20}"
MAXWAIT="${OC_WANDNS_MAXWAIT:-75}"
FORCE=0
[ "$1" = "--force" ] && FORCE=1

log(){ echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# WAN logical interfaces (QMI modem)
WAN_V4="USB"
WAN_V6="USBv6"

# --- read operator DNS from live interface state (ubus) ---
read_dns_iface(){
  ubus call network.interface."$1" status 2>/dev/null \
    | jsonfilter -e '@["dns-server"][*]' 2>/dev/null
}

read_dns(){
  DNS=""
  for i in $WAN_V4 $WAN_V6; do
     for d in $(read_dns_iface "$i"); do
        [ -n "$d" ] && DNS="$DNS $d"
     done
  done
  # fallback: resolv.conf.auto (still interface-derived)
  if [ -z "$DNS" ] && [ -f /tmp/resolv.conf.d/resolv.conf.auto ]; then
     DNS=$(grep -E '^nameserver' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
  fi

  # validate format (v4 or v6), keep only valid, dedupe
  VALID=""
  for d in $DNS; do
     case "$d" in
       *:*) echo "$d" | grep -qE '^[0-9a-fA-F:]+$' && VALID="$VALID $d" ;;
       *.*) echo "$d" | grep -qE '^[0-9]+(\.[0-9]+){3}$' && VALID="$VALID $d" ;;
     esac
  done
  VALID=$(echo "$VALID" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')
  VALID=$(echo "$VALID" | sed 's/^ *//;s/ *$//')
}

v6_of(){ echo "$1" | tr ' ' '\n' | grep ':' | sort | tr '\n' ' ' | sed 's/^ *//;s/ *$//'; }
v4_of(){ echo "$1" | tr ' ' '\n' | grep -v ':' | sort | tr '\n' ' ' | sed 's/^ *//;s/ *$//'; }

do_restart(){
  if [ "$OC_WANDNS_DRYRUN" = "1" ]; then
     log "[dryrun] would set openclash.config.wandns_fix and run: $RESTART_CMD"
     return 0
  fi
  uci set openclash.config.wandns_fix="v6-$(date +%s)" 2>/dev/null
  uci commit openclash 2>/dev/null
  # Make sure the restart really regenerates the YAML (not the quick-start path)
  rm -f "$CHANGE"
  $RESTART_CMD >/dev/null 2>&1 &
  return 0
}

# ---------------------------------------------------------------- one decision
do_sync(){
  read_dns

  # no DNS from WAN at all: keep previous, do not clobber
  if [ -z "$VALID" ]; then
     log "WAN has no DNS yet; keeping previous state (no change)"
     return 0
  fi

  PREV=""
  [ -f "$STATE" ] && PREV=$(sed 's/^ *//;s/ *$//' "$STATE" 2>/dev/null)

  if [ "$FORCE" != "1" ] && [ "$VALID" = "$PREV" ]; then
     return 0                       # unchanged -> nothing to do
  fi

  V4_NEW=$(v4_of "$VALID"); V6_NEW=$(v6_of "$VALID")
  V4_OLD=$(v4_of "$PREV");  V6_OLD=$(v6_of "$PREV")

  # (2) transient IPv6-DNS loss while USBv6 is rebuilding is NOT a change
  if [ -z "$V6_NEW" ] && [ -n "$V6_OLD" ]; then
     if [ "$V4_NEW" = "$V4_OLD" ]; then
        log "IPv6 WAN DNS transiently absent (IPv4 unchanged: [$V4_NEW]) -> ignoring, keeping state [$( [ -n "$V6_OLD" ] && echo v6 known )]"
        return 0                    # <- this is the 21:48 false restart, now a no-op
     fi
     log "IPv6 WAN DNS transiently absent; keep last known v6 [$V6_OLD], update IPv4 only"
     VALID="$V4_NEW $V6_OLD"
  fi

  log "WAN DNS changed: [old: $PREV] -> [new: $VALID]"

  # persist (persistent dir, not /tmp)
  echo "$VALID" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  echo "$VALID" | tr ' ' '\n' > "$STATE_TXT"

  V6_REAL_CHANGE=0
  [ -n "$V6_NEW" ] && [ "$V6_NEW" != "$V6_OLD" ] && V6_REAL_CHANGE=1

  if [ "$FORCE" = "1" ] || [ "$V6_REAL_CHANGE" = "1" ]; then
     log "IPv6 WAN DNS changed [old: $V6_OLD] -> [new: $V6_NEW]; regenerating OpenClash config (one restart)"
     do_restart
     return 0
  fi

  # IPv4-only change: Mihomo dhcp://"wwan0_1" follows natively; just verify
  for probe in www.baidu.com www.qq.com; do
     if ! nslookup "$probe" 127.0.0.1 >/dev/null 2>&1; then
        log "resolution failed after IPv4 DNS change -> reloading OpenClash"
        do_restart
        break
     fi
  done
  return 0
}

# ------------------------------------------------------- debounce / lock layer
acquire_lock(){
  if mkdir "$LOCK" 2>/dev/null; then
     echo $$ > "$LOCK/pid"
     return 0
  fi
  lpid=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
     return 1                       # leader alive -> we are only a follower
  fi
  log "stale debounce lock (pid '$lpid') -> taking over"
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || return 1
  echo $$ > "$LOCK/pid"
  return 0
}

if ! acquire_lock; then
   touch "$LOCK/pending" 2>/dev/null
   log "event during settle window -> extended (leader pid $(cat "$LOCK/pid" 2>/dev/null))"
   exit 0
fi

trap 'rm -rf "$LOCK"' EXIT INT TERM HUP

start=$(date +%s)
while : ; do
   sleep "$SETTLE"
   if [ -f "$LOCK/pending" ]; then
      rm -f "$LOCK/pending"
      now=$(date +%s)
      [ $((now - start)) -lt "$MAXWAIT" ] && continue   # more events -> wait again
   fi
   break
done

do_sync

if [ -f "$LOCK/pending" ]; then        # an event slipped in while acting: one more pass
   rm -f "$LOCK/pending"
   do_sync
fi

rm -rf "$LOCK"
exit 0
