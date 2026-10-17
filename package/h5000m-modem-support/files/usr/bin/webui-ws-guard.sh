#!/bin/sh
# webui-ws-guard v2 - 轻量自愈: 同时探测 8765 WebSocket + 8001 HTTP 两个服务面
# 原则: 正常时零动作零输出; 卡死才重启 webuiserver(释放异常连接的唯一手段)
# 不碰 AT / QMI / qmodem / OpenClash / 网络拨号
# v2 变更: 补上 8001 HTTP 探针(填补"8765 握手 101 正常、但 8001 HTTP 卡死"的盲区)
WS_URL="http://127.0.0.1:8765/"
HTTP_URL="http://127.0.0.1:8001/"
STATE=/tmp/webui-ws-guard.state
LOG=/tmp/webui-ws-guard.log
NEED=2         # 慢通道: 连续失败几次才重启(防瞬时抖动误判)
EST_FAST=4     # 快通道: 僵尸连接(ESTABLISHED+CLOSE_WAIT) >= 此值 + 探针失败 = 立即重启

log() { echo "$(date '+%m-%d %H:%M:%S') [ws-guard] $*" >> "$LOG"; }

# 8765 WebSocket 握手探针: 健康返回 "HTTP/1.1 101 ...", 卡死为空
ws_probe() {
  curl -s -i --max-time 3 \
    -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    -H "Sec-WebSocket-Version: 13" \
    "$WS_URL" 2>/dev/null | head -1 | tr -d '\r'
}

# 8001 HTTP 探针: 健康时 curl 正常返回(exit 0); 卡死时 --max-time 超时(exit 非0) -> 无输出
http_ok() {
  curl -s -o /dev/null --max-time 3 "$HTTP_URL" 2>/dev/null && echo OK
}

# 服务不在(procd 负责拉起) -> 直接退出
pgrep -f '/usr/bin/webuiserver' >/dev/null 2>&1 || exit 0

# 监听缺失 -> 轻量重启
miss=""
netstat -ltn 2>/dev/null | grep -q ':8765 ' || miss="8765"
netstat -ltn 2>/dev/null | grep -q ':8001 ' || miss="${miss:+$miss+}8001"
if [ -n "$miss" ]; then
  log "$miss 无 LISTEN -> restart"
  /etc/init.d/modemwebui restart >/dev/null 2>&1
  rm -f "$STATE"; exit 0
fi

# 两个数据面探针
ws=$(ws_probe); case "$ws" in *101*) ws_bad=0;; *) ws_bad=1;; esac
[ "$(http_ok)" = OK ] && http_bad=0 || http_bad=1

# 都正常 -> 清零计数, 静默退出(绝不因连接数多而动手)
if [ "$ws_bad" = 0 ] && [ "$http_bad" = 0 ]; then
  rm -f "$STATE"; exit 0
fi

# 有探针失败 -> 统计两个端口的僵尸连接(ESTABLISHED + CLOSE_WAIT)
est=$(netstat -tn 2>/dev/null | grep -E ':(8765|8001) ' | grep -Ec 'ESTABLISHED|CLOSE_WAIT')

which=""
[ "$ws_bad" = 1 ] && which="8765"
[ "$http_bad" = 1 ] && which="${which:+$which+}8001"

# 快速通道: 探针失败 + 僵尸连接堆积(>=EST_FAST) = 典型卡死, 立即重启不等待
if [ "$est" -ge "$EST_FAST" ]; then
  log "探针失败($which) + 僵尸连接=$est(>=$EST_FAST) -> 立即 restart webuiserver"
else
  # 慢通道: 连接数不多, 可能瞬时抖动 -> 连续 NEED 次才动手
  n=$(cat "$STATE" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0;; esac
  n=$((n+1)); echo "$n" > "$STATE"
  if [ "$n" -lt "$NEED" ]; then
    log "探针失败($which) $n/$NEED (僵尸连接=$est, 容忍中)"
    exit 0
  fi
  log "连续 $n 次探测失败($which, 僵尸连接=$est) -> restart webuiserver"
fi

/etc/init.d/modemwebui restart >/dev/null 2>&1
sleep 8

# 立即轻量复验(两个面都验)
ws2=$(ws_probe); [ "$(http_ok)" = OK ] && h2=OK || h2=BAD
case "$ws2" in
  *101*) [ "$h2" = OK ] && log "restart 后复验 OK, 恢复正常" || log "restart 后 8765 OK 但 8001 仍异常: HTTP=$h2" ;;
  *)     log "restart 后仍异常: WS=[$ws2] HTTP=$h2" ;;
esac
rm -f "$STATE"
exit 0
