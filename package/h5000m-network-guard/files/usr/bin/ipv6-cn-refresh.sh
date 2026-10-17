#!/bin/sh
# 刷新 /etc/ipv6-cn.list (中国大陆 IPv6 网段, clang/APNIC 来源) 并重新应用
URL="https://ispip.clang.cn/all_cn_ipv6.txt"
NEW=/tmp/cn6.new
LOG=/tmp/v6fastfail.log
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

rm -f "$NEW"
uclient-fetch -q -O "$NEW" --timeout=25 "$URL" 2>/dev/null || { log "refresh: fetch failed"; exit 1; }
[ -s "$NEW" ] || { log "refresh: empty"; exit 1; }

TOT=$(wc -l < "$NEW")
BAD=$(grep -vcE '^[0-9a-fA-F:]+/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8])[[:space:]]*$' "$NEW")
GOOD=$(grep -cE '^[0-9a-fA-F:]+/' "$NEW")
log "refresh: total=$TOT good=$GOOD bad=$BAD"
[ "$GOOD" -ge 1000 ] || { log "refresh: too few good lines, keep old"; exit 1; }
[ "$BAD" -le 5 ] || { log "refresh: too many malformed lines, keep old"; exit 1; }

cp -f "$NEW" /etc/ipv6-cn.list
/usr/bin/ipv6-cn-fastfail.sh
log "refresh: list updated and re-applied"
