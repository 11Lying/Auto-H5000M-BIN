#!/bin/sh
# v6fastfail -- 2026-10-03
# 目的: 让"国外 IPv6"快速失败(回 ICMPv6 unreachable),而不是被上游黑洞后
#       让客户端 TCP 干等 1~3 秒才回落 IPv4。国内 IPv6 完全不受影响。
# 挂载点: uci firewall.v6fastfail=include -> /usr/bin/ipv6-cn-fastfail.sh
#         (每次 fw4 reload / 开机都会执行)
# 关闭:   uci delete firewall.v6fastfail; uci commit firewall; fw4 reload
#         (或临时: nft delete table inet v6fastfail)
LIST=/etc/ipv6-cn.list
EXTRA=/etc/ipv6-cn-extra.list
LOG=/tmp/v6fastfail.log
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

[ -f "$LIST" ] || { log "no list, skip"; exit 0; }
N=$(grep -c '/' "$LIST" 2>/dev/null)
[ "$N" -ge 500 ] 2>/dev/null || { log "list too small ($N), skip"; exit 0; }

TMP=/tmp/v6fastfail.nft
ELEMS=/tmp/v6fastfail.elems
{ grep '/' "$LIST"; [ -f "$EXTRA" ] && grep '/' "$EXTRA"; } \
  | tr -d '\r' | awk '{printf "%s, ", $0}' > "$ELEMS"
sed -i 's/, $//' "$ELEMS"

{
  echo 'table inet v6fastfail {'
  echo '  set cn6 {'
  echo '    type ipv6_addr'
  echo '    flags interval'
  echo '    auto-merge'
  echo -n '    elements = { '
  cat "$ELEMS"
  echo ' }'
  echo '  }'
  cat <<'EOF'
  chain pre_forward {
    type filter hook forward priority -5; policy accept;
    ct state established,related counter accept
    ip6 daddr @cn6 counter accept
    ip6 daddr { fc00::/7, fe80::/10, ff00::/8 } counter accept
    ip6 nexthdr ipv6-icmp icmpv6 type { 1, 2, 3, 4 } counter accept
    ip6 daddr 2000::/3 counter reject with icmpv6 admin-prohibited
  }
EOF
  echo '}'
} > "$TMP"

nft delete table inet v6fastfail 2>/dev/null
if nft -f "$TMP" 2>>"$LOG"; then
  log "applied ok, cn prefixes=$N"
else
  log "APPLY FAILED"
  exit 1
fi
exit 0
