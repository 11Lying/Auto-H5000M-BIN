#!/bin/sh
# OpenClash subscription updater (gzcloud): paid + free providers.
# Order: download(with retry) -> parse -> write node files(.new) -> light-validate ->
#        [skip if unchanged] -> commit -> rebuild config -> restart OpenClash
# Safe: validates before applying; keeps old files on any failure.
# Usage: oc-sub-update.sh [--no-reload]
# Env:   OC_SUB_DRYRUN=1   validate only, no commit/rebuild/restart (troubleshooting)
#
# 2026-09-24: 付费机场保留"官网/剩余流量/套餐到期/频道"这几个信息节点(它们其实是同一台
#   真实可用服务器 hysteria2, 用户要求保留). 免费机场行为不变(仍过滤公告伪节点).
#   实现: uri_or_yaml/extract_proxies 增加第 3/2 个参数 keepinfo=1 时不做公告过滤;
#         oc-uri2yaml.awk 增加 -v keepinfo=1 时不跳过信息名节点.
#
# 2026-10-05 CPU/风扇优化 (起因: 10-05 19:30 这次更新把 CPU 顶到 67-68C, 风扇 68%):
#   (a) 原第3步用 `clash_meta -t` 校验"整份 config", 但本配置的节点是内联(proxies:)的,
#       那两句 sed 替换匹配不到任何东西 -> 校验的其实是"上一版旧配置的副本", 对刚下载的
#       新节点毫无校验作用; 却要整份加载 geosite(11万条)/geoip, 实测 1.5~12s 且波动大,
#       正是升温最快的一段. 现改为只校验"新节点文件本身"(mixed-port + 新 proxies + MATCH
#       规则), 完全不加载 geo 数据, 实测 <0.2s, 而且这次是真的在校验新节点.
#   (b) 新增"输入未变则整体跳过": 新节点文件 / head / tail 模板 / 本脚本自身 / 免费开关
#       的 md5 与上次成功构建时相同, 且核心在跑 -> 连 commit 都省掉, 直接退出.
#       机场没换节点的那次更新, CPU 峰值 ~= 0.
#   (c) OC_SUB_DRYRUN=1: 走到校验为止, 不提交/不重建/不重启.

PROV_DIR="/etc/openclash/proxy_provider"
STATE_DIR="/etc/openclash"
LOG="/tmp/oc-sub-update.log"
LOCK="/tmp/lock/oc-sub-update.lock"
CFG="/etc/openclash/config/gzcloud.yaml"
RUNCFG="/etc/openclash/gzcloud.yaml"
HEAD="/etc/openclash/oc-config-head.yaml"
TAIL="/etc/openclash/oc-config-tail.yaml"
BUILDER="/usr/bin/oc-build-config.sh"
FPFILE="/etc/openclash/.sub_build_fp"
CLASH="/etc/openclash/core/clash_meta"
API="http://127.0.0.1:9090"
SECRET="$(uci get openclash.config.dashboard_password 2>/dev/null)"
[ -z "$SECRET" ] && SECRET="KNPeboRn"
RELOAD=1
[ "$1" = "--no-reload" ] && RELOAD=0
DRYRUN=0
[ "$OC_SUB_DRYRUN" = "1" ] && DRYRUN=1

# FREE subscription toggle: presence of the flag file disables the free 机场.
# When disabled we skip downloading/parsing/committing the free provider so a
# broken free sub can never break the config again. Re-enable: rm the flag file.
FREE=1
[ -f /etc/openclash/free_disabled ] && FREE=0

log(){ echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

PAID_URL=$(head -1 "$STATE_DIR/sub_paid.url" 2>/dev/null)
FREE_URL=$(head -1 "$STATE_DIR/sub_free.url" 2>/dev/null)
[ -n "$PAID_URL" ] || { log "no paid sub url"; exit 1; }
[ "$FREE" = 1 ] && [ -z "$FREE_URL" ] && { log "free url missing; free disabled for this run"; FREE=0; }

mkdir -p "$PROV_DIR" /tmp/lock
exec 9>"$LOCK"; flock -x 9
log "=== update start ===$([ "$DRYRUN" = 1 ] && echo ' (dry-run)')"

# ---------- helpers ----------
dl(){  # $1=url $2=out ; up to 3 attempts
  i=1
  while [ "$i" -le 3 ]; do
     curl -4 -s --max-time 60 -A "clash.meta" "$1" -o "$2" && [ -s "$2" ] && return 0
     log "download attempt $i failed"; sleep 5; i=$((i+1))
  done
  return 1
}
extract_proxies(){  # $1=raw yaml  $2=keepinfo(1=保留信息节点,不过滤公告)
  if [ "$2" = "1" ]; then
     # 保留全部节点(含官网/剩余流量/套餐到期/频道等信息节点)
     awk '
       /^proxies:/{f=1;next}
       /^[a-zA-Z_][a-zA-Z0-9_-]*:/{if(f)f=0}
       f{print}
     ' "$1"
  else
     awk '
       /^proxies:/{f=1;next}
       /^[a-zA-Z_][a-zA-Z0-9_-]*:/{if(f)f=0}
       f{print}
     ' "$1" | awk '
       function bad(s){ return (s ~ /剩余|流量|到期|套餐|官网|客服|公告|群组|频道|请勿滥用|@honghong|官方网站|订阅地址|更新时间/) }
       /^[ \t]*- name:/{ if (bad($0)) { skip=1 } else { skip=0; print }; next }
       /^[ \t]*-[ \t]*\{/{ if (bad($0)) next; print; next }
       { if (!skip) print }
     '
  fi
}
ensure_hdr(){ f="$1"; head -1 "$f" | grep -q "^proxies:" || { { echo "proxies:"; cat "$f"; } > "$f.h" && mv "$f.h" "$f"; }; }
uri_or_yaml(){  # $1=raw $2=out(proxies block) $3=keepinfo(1=付费保留信息节点)
  KI="${3:-0}"
  if grep -q "^proxies:" "$1"; then extract_proxies "$1" "$KI" > "$2"
  else
     if head -c 200 "$1" | grep -q "://"; then cp "$1" /tmp/oc_uri.tmp
     else tr -d '\r\n \t' < "$1" | openssl base64 -d -A > /tmp/oc_uri.tmp 2>/dev/null; fi
     awk -v keepinfo="$KI" -f /usr/bin/oc-uri2yaml.awk /tmp/oc_uri.tmp > "$2"
  fi
}
# 输入指纹: 决定"重建后的 config 会不会变"的全部输入
build_fp(){
  {
    echo "free=$FREE"
    cat "$PROV_DIR/paidaer.yml.new" "$HEAD" "$TAIL" 2>/dev/null
    [ "$FREE" = 1 ] && cat "$PROV_DIR/freesub.yml.new" 2>/dev/null
    md5sum "$BUILDER" 2>/dev/null | awk '{print $1}'
  } | md5sum | awk '{print $1}'
}

# ---------- 1. download (with retry) ----------
dl "$PAID_URL" /tmp/oc_paid.raw || { log "ERROR paid download failed after retries"; exit 2; }
[ "$FREE" = 1 ] && { dl "$FREE_URL" /tmp/oc_free.raw || { log "ERROR free download failed after retries"; exit 2; }; }

# ---------- 2. parse ----------
uri_or_yaml /tmp/oc_paid.raw /tmp/oc_paid.yml 1
PAID_N=$(grep -cE "^[ \t]*- " /tmp/oc_paid.yml)
[ "$PAID_N" -ge 3 ] || { log "ERROR paid nodes too few ($PAID_N)"; exit 3; }
awk '!seen[$0]++' /tmp/oc_paid.yml > /tmp/p2 && mv /tmp/p2 /tmp/oc_paid.yml
ensure_hdr /tmp/oc_paid.yml
awk -f /usr/bin/oc-normalize.awk /tmp/oc_paid.yml > "$PROV_DIR/paidaer.yml.new"
FREE_N=0
if [ "$FREE" = 1 ]; then
  uri_or_yaml /tmp/oc_free.raw /tmp/oc_free.yml 0
  FREE_N=$(grep -cE "^[ \t]*- " /tmp/oc_free.yml)
  [ "$FREE_N" -ge 3 ] || { log "ERROR free nodes too few ($FREE_N)"; rm -f "$PROV_DIR"/*.new; exit 3; }
  awk '!seen[$0]++' /tmp/oc_free.yml > /tmp/f2 && mv /tmp/f2 /tmp/oc_free.yml
  ensure_hdr /tmp/oc_free.yml
  awk -f /usr/bin/oc-normalize.awk /tmp/oc_free.yml > "$PROV_DIR/freesub.yml.new"
fi
log "parsed paid=$PAID_N free=$FREE_N (free=$FREE)"

# ---------- 3. validate the NEW NODE FILES only (light: no geo data loaded) ----------
: > /tmp/oc_nodes_check.yml
echo "mixed-port: 7890"   >> /tmp/oc_nodes_check.yml
echo "mode: rule"         >> /tmp/oc_nodes_check.yml
echo "log-level: silent"  >> /tmp/oc_nodes_check.yml
cat "$PROV_DIR/paidaer.yml.new" >> /tmp/oc_nodes_check.yml
[ "$FREE" = 1 ] && tail -n +2 "$PROV_DIR/freesub.yml.new" >> /tmp/oc_nodes_check.yml
echo "rules:"             >> /tmp/oc_nodes_check.yml
echo "  - MATCH,DIRECT"   >> /tmp/oc_nodes_check.yml
if SAFE_PATHS=/usr/share/openclash:/etc/ssl "$CLASH" -t -d /etc/openclash -f /tmp/oc_nodes_check.yml >/tmp/oc_sub_val.log 2>&1; then
   log "new node files valid (light check, no geo)"
else
   log "ERROR new node files INVALID: $(grep -iE 'error|invalid' /tmp/oc_sub_val.log | tail -1)"
   rm -f "$PROV_DIR"/*.new /tmp/oc_nodes_check.yml; exit 5
fi
rm -f /tmp/oc_nodes_check.yml

# ---------- 3.5 skip entirely if nothing changed since last successful build ----------
FP="$(build_fp)"
if [ "$RELOAD" = "1" ] && [ -f "$FPFILE" ] && [ "$(cat "$FPFILE" 2>/dev/null)" = "$FP" ] \
   && [ -f "$RUNCFG" ] && pidof clash >/dev/null 2>&1; then
   log "inputs unchanged (fp=$FP); skip commit/rebuild/restart"
   rm -f "$PROV_DIR"/*.new
   log "=== update done: paid=$PAID_N free=$FREE_N (no change) ==="
   exit 0
fi

if [ "$DRYRUN" = "1" ]; then
   log "(dry-run) would commit + rebuild + restart (fp=$FP)"
   rm -f "$PROV_DIR"/*.new
   exit 0
fi

# ---------- 4. commit ----------
cp "$PROV_DIR/paidaer.yml" "$STATE_DIR/last_good_paidaer.yml" 2>/dev/null
mv "$PROV_DIR/paidaer.yml.new" "$PROV_DIR/paidaer.yml"
if [ "$FREE" = 1 ]; then
  cp "$PROV_DIR/freesub.yml" "$STATE_DIR/last_good_freesub.yml" 2>/dev/null
  mv "$PROV_DIR/freesub.yml.new" "$PROV_DIR/freesub.yml"
fi
log "committed node files"

[ "$RELOAD" = "1" ] || { log "=== update done (no reload) ==="; exit 0; }

# ---------- 5. rebuild config + restart (loads all nodes so API health-check works) ----------
/usr/bin/oc-build-config.sh >> "$LOG" 2>&1
if SAFE_PATHS=/usr/share/openclash:/etc/ssl "$CLASH" -t -d /etc/openclash -f "$CFG" >/tmp/oc_rebuild_val.log 2>&1; then
   log "rebuilt config valid; restarting OpenClash"
   uci set openclash.config.enable=1; uci commit openclash
   /etc/init.d/openclash restart >/dev/null 2>&1
   # wait for API up (max ~90s)
   n=0; while [ "$n" -lt 30 ]; do
      curl -s -o /dev/null -H "Authorization: Bearer $SECRET" --max-time 4 "$API/version" && break
      sleep 3; n=$((n+1))
   done
   log "OpenClash restarted (waited $((n*3))s)"
   echo "$FP" > "$FPFILE"
else
   log "ERROR rebuilt config invalid; NOT applying"; exit 6
fi

# ---------- 6. (候选池机制已移除: 自动选择/故障转移直接用付费全集, 已在第5步随配置重建) ----------
log "=== update done: paid=$PAID_N free=$FREE_N pool=${CAND_N:-0} ==="
exit 0
