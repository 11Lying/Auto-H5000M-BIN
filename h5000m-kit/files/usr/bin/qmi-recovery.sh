#!/bin/sh
# qmi-recovery v2: RM502Q-AE QMI WDS wedge 事件驱动恢复
# 原理: quectel-CM-M 在 QMI 请求超时时不退出, 一直死循环重发; qmodem 的 qmi_dial 只在 CM"退出"才重启。
#       本脚本补上"wedge 判定"+"让 CM 退出", 触发 qmodem 自动重建 QMI session。
# v2 修正(2026-09-22, 依据真实故障复盘):
#   1) 按"超时次数"计数(不再按读取增量), 因为 quectel-CM 日志带缓冲会成批到达;
#   2) 阈值降到 2(真实 wedge 只出现 2 次会话超时), 加 300s 计数窗口;
#   3) 新增 NETDEV WATCHDOG 作为独立触发信号(两次 wedge 各出现1次, 正常态从不出现);
#   4) 排除 QmiWwanInit 初始化超时(可自愈, 非 wedge)。
# 不改 qmodem 配置/二进制/驱动/QMAP/HNAT/AT隔离/SMS/OpenClash。
# 回滚: /etc/init.d/qmi-recovery disable && rm -f /etc/init.d/qmi-recovery /usr/bin/qmi-recovery.sh

DIAL_LOG="${QMI_REC_DIAL_LOG:-/tmp/run/qmodem/2_1_dir/dial_log}"
LOG="${QMI_REC_LOG:-/tmp/qmi-recovery.log}"
RUN="${QMI_REC_RUN:-/tmp/qmi-recovery}"

THRESHOLD="${QMI_REC_THRESHOLD:-2}"      # 窗口内会话层QMI超时"次数"阈值
WINDOW="${QMI_REC_WINDOW:-300}"          # 计数窗口(秒), 超过则清零
COOLDOWN="${QMI_REC_COOLDOWN:-120}"      # 触发后冷却(秒)
RECOVERY_WAIT="${QMI_REC_RECOVERY_WAIT:-30}"
DRYRUN="${QMI_REC_DRYRUN:-0}"            # 1=演练: 不真杀 CM
WD_CMD="${QMI_REC_WD_CMD:-dmesg}"        # 可覆盖以便测试
WD_EVERY="${QMI_REC_WD_EVERY:-10}"       # 每 N 轮检查一次 watchdog(≈N秒)

log() { echo "$(date '+%m-%d %H:%M:%S') [qmi-recovery] $*" >> "$LOG"; }
cm_alive() { ps w | grep "[q]uectel-CM-M" | head -1 >/dev/null 2>&1; }

watchdog_count() {
    c=$($WD_CMD 2>/dev/null | grep -c "NETDEV WATCHDOG" 2>/dev/null)
    case "$c" in ''|*[!0-9]*) c=0;; esac
    echo "$c"
}

trigger_recovery() {
    [ "$DRYRUN" = "1" ] && { log "DRYRUN: would kill CM (skipped)"; return 0; }
    local pid
    pid=$(ps w | grep "[q]uectel-CM-M" | awk '{print $1}' | head -1)
    [ -n "$pid" ] || { log "no CM process to kill"; return 1; }
    log "killing CM pid=$pid (SIGTERM)"
    kill "$pid" 2>/dev/null
    sleep 2
    if ps -p "$pid" >/dev/null 2>&1; then
        log "pid=$pid alive after SIGTERM, SIGKILL"
        kill -9 "$pid" 2>/dev/null
    fi
    log "waiting up to ${RECOVERY_WAIT}s for qmodem rebuild..."
    local n=$((RECOVERY_WAIT / 3)); [ "$n" -lt 1 ] && n=1
    local i
    for i in $(seq 1 "$n"); do
        sleep 3
        cm_alive && return 0
    done
    log "WARN: no new CM within ${RECOVERY_WAIT}s"
    return 1
}

mkdir -p "$RUN"
log "monitor v2 started threshold=$THRESHOLD window=$WINDOW cooldown=$COOLDOWN"

hits=0; last_hit_ts=0; last_ev_ts=""; armed=0; last_ts=0; tick=0
wd_last=$(watchdog_count); wd_seen=0
pos_file="$RUN/lastpos"
[ -f "$pos_file" ] || echo 0 > "$pos_file"
log "initial NETDEV WATCHDOG count = $wd_last"

while true; do
    now=$(date +%s)

    if [ "$armed" = "1" ] && [ $(( now - last_ts )) -ge "$COOLDOWN" ]; then
        armed=0; hits=0; wd_seen=0
        log "cooldown elapsed, re-arming"
    fi

    if [ "$armed" = "0" ]; then
        # 1) dial_log 增量 -> 统计超时"次数"
        pos=$(cat "$pos_file" 2>/dev/null || echo 0)
        cur=$(wc -c < "$DIAL_LOG" 2>/dev/null || echo 0)
        new=""
        if [ "$cur" -ge "$pos" ]; then
            new=$(tail -c +$((pos+1)) "$DIAL_LOG" 2>/dev/null | tail -c 65536)
        fi
        echo "$cur" > "$pos_file"

        if [ -n "$new" ]; then
            # 按行(时间顺序)更新状态: 超时 -> hits++, 正常响应 -> hits=0
            # 这样同一块里"先超时后恢复"会正确归零, 不会把恢复前的旧超时误计为新命中
            oifs=$IFS; IFS='
'
            n_add=0; n_reset=0
            for line in $new; do
                case "$line" in
                    *QmiWwanInit*) : ;;
                    *"err = 110"*|*"message timeout"*)
                        # 按"事件"计数: 同一次超时会写 message timeout + err=110 两行,
                        # 时间戳相同 -> 用时间戳去重, 保证 1 次超时只算 1
                        ts="${line%%]*}"
                        if [ "$ts" != "$last_ev_ts" ]; then
                            if [ $(( now - last_hit_ts )) -gt "$WINDOW" ]; then hits=0; fi
                            hits=$((hits + 1)); last_hit_ts=$now
                            last_ev_ts="$ts"; n_add=$((n_add + 1))
                        fi ;;
                    *WdsConnectionIPv4Handle*|*WdsConnectionIPv6Handle*|*requestRegistrationState2*|*IPv4ConnectionStatus*|*QMUXResult*|*call_end_reason*)
                        if [ "$hits" -gt 0 ]; then hits=0; n_reset=1; fi ;;
                esac
            done
            IFS=$oifs
            [ "$n_add" -gt 0 ] && log "QMI session timeout x$n_add (window total $hits/$THRESHOLD)"
            [ "$n_reset" = "1" ] && log "QMI responded (normal), reset count"
        fi

        # 2) NETDEV WATCHDOG (内核环形缓冲计数增量)
        tick=$((tick + 1))
        if [ $((tick % WD_EVERY)) -eq 0 ]; then
            wc=$(watchdog_count)
            case "$wc" in ''|*[!0-9]*) wc=0;; esac
            if [ "$wc" -gt "$wd_last" ]; then
                wd_seen=1
                log "NETDEV WATCHDOG detected (count $wd_last -> $wc)"
            fi
            wd_last=$wc
        fi

        # 3) 触发判定
        trigger=0; reason=""
        [ "$wd_seen" = "1" ] && { trigger=1; reason="NETDEV WATCHDOG"; }
        if [ "$hits" -ge "$THRESHOLD" ]; then
            trigger=1
            case "$reason" in "") reason="$hits QMI timeouts/$(echo $WINDOW)s";; *) reason="$reason + $hits QMI timeouts";; esac
        fi
        if [ "$trigger" = "1" ]; then
            log "WEDGE confirmed ($reason) -> recovery"
            trigger_recovery
            last_ts=$(date +%s); armed=1
            hits=0; wd_seen=0; last_hit_ts=0
            wc -c < "$DIAL_LOG" > "$pos_file" 2>/dev/null   # 跳过恢复前积压内容
            log "recovery done, cooling ${COOLDOWN}s"
        fi
    fi

    sleep 1
done
