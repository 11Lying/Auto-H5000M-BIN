#!/bin/sh
# Build /etc/openclash/config/gzcloud.yaml from provider files with INLINE node defs
# and INLINE group members (max dashboard/panel compatibility).
# 自动选择/故障转移 直接使用「付费节点全集」(固定成员)，不再用动态候选池，
# 避免网络抖动时健康检查把成员清空 -> 分组变 0 个节点。
PROV="/etc/openclash/proxy_provider"
OUT="/etc/openclash/config/gzcloud.yaml"
HEAD="/etc/openclash/oc-config-head.yaml"
TAIL="/etc/openclash/oc-config-tail.yaml"

names_of(){  # $1=provider yaml -> node names, one per line
  awk '
    /^[ \t]*- name:/{ n=$0; sub(/^[ \t]*- name:[ \t]*/,"",n); gsub(/^"|"$/,"",n); print n; next }
    /^[ \t]*-[ \t]*\{/{
      s=$0
      pos=index(s,"name:")
      if(pos==0) next
      s=substr(s,pos+5); sub(/^[ \t]+/,"",s)
      q=substr(s,1,1); out=""
      if(q=="\"" || q=="'"'"'"){ s=substr(s,2); pp=index(s,q); out=substr(s,1,pp-1) }
      else { pp=index(s,","); if(pp==0)pp=length(s)+1; out=substr(s,1,pp-1) }
      gsub(/^[ \t]+|[ \t]+$/,"",out)
      print out
    }
  ' "$1"
}
emit_group_members(){ # $1=provider ; 6空格缩进列表项
  names_of "$1" | while IFS= read -r n; do
     [ -z "$n" ] && continue
     echo "      - \"$n\""
  done
}

# FREE subscription toggle: presence of the flag file disables the free 机场
# entirely (no free proxies inlined, no 免费订阅/自动选择2 groups, no free in
# 故障转移). Re-enable by: rm /etc/openclash/free_disabled && oc-build-config.sh
FREE=1
[ -f /etc/openclash/free_disabled ] && FREE=0

PAID_N=$(names_of "$PROV/paidaer.yml" | wc -l)
if [ "$FREE" = 1 ]; then FREE_N=$(names_of "$PROV/freesub.yml" | wc -l); else FREE_N=0; fi

{
  cat "$HEAD"
  echo ""
  # ---------- inline proxies ----------
  echo "# ---------- proxies (inline from providers) ----------"
  echo "proxies:"
  grep -vE '^proxies:[ \t]*$' "$PROV/paidaer.yml" | grep -vE '^[ \t]*#' | sed '/^[ \t]*$/d'
  [ "$FREE" = 1 ] && grep -vE '^proxies:[ \t]*$' "$PROV/freesub.yml" | grep -vE '^[ \t]*#' | sed '/^[ \t]*$/d'
  echo ""
  # ---------- proxy-groups ----------
  echo "# ---------- proxy-groups ----------"
  echo "proxy-groups:"
  echo '  - name: "🚀 Proxy"'
  echo '    type: select'
  echo '    proxies:'
  echo '      - "♻️ 自动选择"'
  [ "$FREE" = 1 ] && echo '      - "♻️ 自动选择2"'
  echo '      - "⚡ 故障转移"'
  echo '      - "✈️ 机场节点"'
  [ "$FREE" = 1 ] && echo '      - "🆓 免费订阅"'
  echo '      - "DIRECT"'
  # 自动选择：固定 = 全部付费节点(url-test 自动选延迟最低; 抖动也保留全部成员,不清零)
  echo '  - name: "♻️ 自动选择"'
  echo '    type: url-test'
  echo '    url: "https://www.gstatic.com/generate_204"'
  echo '    interval: 900'
  echo '    tolerance: 100'
  echo '    lazy: true'
  echo '    proxies:'
  emit_group_members "$PROV/paidaer.yml"
  # 自动选择2：免费订阅节点(url-test 自动选延迟最低; 随免费订阅更新)
  if [ "$FREE" = 1 ]; then
  echo '  - name: "♻️ 自动选择2"'
  echo '    type: url-test'
  echo '    url: "https://www.gstatic.com/generate_204"'
  echo '    interval: 900'
  echo '    tolerance: 100'
  echo '    lazy: true'
  echo '    proxies:'
  emit_group_members "$PROV/freesub.yml"
  fi
  # 故障转移：付费+免费全部节点(fallback 顺序取第一个可用)
  # interval:0 关闭周期性健康检查; 靠 max-failed-times 在当前节点连续失败时才触发检查+切换
  echo '  - name: "⚡ 故障转移"'
  echo '    type: fallback'
  echo '    url: "https://www.gstatic.com/generate_204"'
  echo '    interval: 0'
  echo '    lazy: true'
  echo '    max-failed-times: 2'
  echo '    proxies:'
  emit_group_members "$PROV/paidaer.yml"
  [ "$FREE" = 1 ] && emit_group_members "$PROV/freesub.yml"
  # 机场节点：手动选(付费全集 + DIRECT)
  echo '  - name: "✈️ 机场节点"'
  echo '    type: select'
  echo '    proxies:'
  emit_group_members "$PROV/paidaer.yml"
  echo '      - "DIRECT"'
  # 免费订阅：手动选(备用)
  if [ "$FREE" = 1 ]; then
  echo '  - name: "🆓 免费订阅"'
  echo '    type: select'
  echo '    proxies:'
  emit_group_members "$PROV/freesub.yml"
  echo '      - "DIRECT"'
  fi
  echo ""
  cat "$TAIL"
} > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
if [ "$FREE" = 1 ]; then FS="on"; else FS="OFF(disabled)"; fi
echo "built $OUT : paid=$PAID_N free=$FREE_N (free=$FS; auto/fallback=付费全集,无候选池)"
