#!/bin/sh
# IPv6 LAN prefix route fix (Hiveton H5000M)
# Restores the current architecture: domestic IPv6 remains direct, foreign
# client IPv6 is handled by the separate v6fastfail forward hook, and OpenClash
# IPv6 proxy is not enabled. This script only makes the LAN /64 route win over
# the WAN on-link /64 and removes a deprecated reject table.
LOG=/tmp/ipv6-guard.log
LOG_LINES_MAX=200
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }

# ---------- 1) LAN prefix route fix (shared /64 return path) ----------
for p in $(ip -6 route show dev br-lan proto static 2>/dev/null | awk "{print \$1}" | grep "/64"); do
  ip -6 route replace "$p" dev br-lan metric 50 2>/dev/null && log "route: $p dev br-lan metric 50"
done

# ---------- 2) remove the deprecated reject table (foreign IPv6 no longer blocked) ----------
if nft list table inet ipv6guard >/dev/null 2>&1; then
  nft delete table inet ipv6guard 2>/dev/null && log "removed legacy inet ipv6guard reject table (foreign v6 now proxied via OpenClash)"
fi

[ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt $LOG_LINES_MAX ] && { tail -n 100 "$LOG" > "$LOG.t"; mv "$LOG.t" "$LOG"; }
true
