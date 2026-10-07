# H5000M × ImmortalWrt 25.12 + MTK Wi-Fi 7 SDK（分支 `wrt2512`）

> `main` 分支保持原样（24.10 + padavanonly 闭源 mtwifi 那条老基座，正在跑的固件），
> 本分支是**新基座**：**ImmortalWrt 25.12 / 内核 6.12 / apk**，Wi-Fi 仍然是
> **同一套 MTK 闭源驱动（mt_wifi7 + mt7992）**，只是换到了 r8 SDK + 25.12 基座。

## 基座

| 项 | main（现行固件） | 本分支 |
|---|---|---|
| 源码 | `padavanonly/immortalwrt-mt798x-24.10` @ `mt798x-mt799x-6.6-mtwifi` | **`chasey-dev/immortalwrt-mt798x-rebase` @ `25.12-dev-wifi7`** |
| ImmortalWrt | 24.10（2026-07-23 停更） | **25.12（openwrt-25.12）** |
| 内核 | 6.6.94 | **6.12** |
| 包管理器 | opkg（ipk） | **apk** |
| Wi-Fi | 闭源 mt_wifi7（24.10 SDK） | **闭源 mt_wifi7（Wi-Fi 7 SDK r8，`mt7987-25.12-wifi7-r8`）** |
| HNAT | SDK HNAT + turboacc | **同样 SDK HNAT + luci-app-turboacc-mtk** |
| 设备名 | `hiveton-h5000m` | `hiveton_h5000m`（下划线） |

`chasey-dev/immortalwrt-mt798x-rebase` = 把 padavanonly 那条 MTK feeds 线重基到
ImmortalWrt 25.12 的仓库；`25.12-dev-wifi7` 分支带完整 MTK 闭源 Wi-Fi 7 驱动
（`package/mtk/drivers/{mt_wifi7,mt_wifi_cmn,mt_wifi_osal,mt_hwifi,warp,wifi-profile}`）。
**上游官方 `immortalwrt/immortalwrt@openwrt-25.12` 没有闭源驱动**（只有开源 mt76），
所以要走"闭源 + 25.x"就必须用这个仓库。

## 关键文件

```
config/h5000m-25.12.config   完整 .config（底稿=chasey 的 MT7987+MT7992 配置 → 设备换成 H5000M、
                             SKU 改成 BE6500 → 追加我们的功能包。★SDK 符号整块保留，
                             别按 24.10 基座的名字改）
feeds.conf.default           openwrt-25.12 各 feed + QModem
patches/
  dts-h5000m-fan-boot-duty.patch        给 &fan 加 pwm-fan,boot-duty=<51>（对 25.12 的 dts 重新生成过）
  999-h5000m-pwm-fan-boot-duty.kernel-patch  内核 pwm-fan.c 读该属性（6.12 上下文一致，原样可用）
  qmodem-*.patch                        QModem feed 的兼容补丁（打不上会跳过）
h5000m-kit/                  家当（AT 双口隔离 / 面板 / QSCAN 前端 / 风扇 / IPv6 / 短信 / OpenClash 辅助）
scripts/local-build.sh       构建脚本（简单版：clone → feeds → 补丁/家当 → cp .config → defconfig → make）
.github/workflows/build-test.yml  CI（push → config-validation；手动 dispatch → 真正编译）
```

## 怎么编

1. **配置校验**：往本分支 push 就会自动跑 `config-validation`（不需要手动确认）。
2. **真正编译**：Actions → `Build ImmortalWrt 25.12 H5000M (MTK Wi-Fi7 SDK)` →
   `Run workflow` → 分支选 `wrt2512` → **把 `confirm_firmware_build` 勾成 true**。
   产物是 artifact `H5000M-firmware`（含 sysupgrade bin + manifest + build.config + sha256）。
3. 本地手动：`bash scripts/local-build.sh --config-only` 只做配置；不加参数则整机编译。
   流程和别的 H5000M 云编译仓库一样（`feeds update/install` → `cp config/… .config` → `make defconfig` → `make`），
   不做符号强校验——kconfig 丢掉什么就以最终 `artifacts/build.config` 为准。

## 刷机前后

* 镜像格式与 main 一致（`sysupgrade-tar | append-metadata`），LuCI 里直接 sysupgrade 即可。
* **overlay 会被清空**（sysupgrade 只保 `/etc/config`），我们全部定制靠 `h5000m-kit` 的首启脚本重建。
* 刷前确认恢复通道（u-boot/TFTP/救援固件）在手。
* 首启后必须手动补 3 个占位符（都不在公开仓库里）：
  ```sh
  # 1) WiFi 密码（5G 段）
  uci set wireless.<5G设备段对应的iface>.key='你的密码'; uci commit wireless; wifi reload
  # 2) 企微群机器人 webhook
  uci set sms_forwarder.wecom.api_config='{"webhook_url":"https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=<你的key>"}'
  uci commit sms_forwarder && /etc/init.d/sms_forwarder restart
  # 3) OpenClash 面板密码/订阅
  ```

## 首启后要核对的 8 项（新基座待验证清单）

```sh
# 1 CPU 变频（新基座新增！见下）
cat /sys/devices/system/cpu/cpufreq/policy0/{scaling_driver,scaling_governor,scaling_available_frequencies,scaling_cur_freq}
# 2 无线是否起来 / SKU 是否正确（日志里应看到 MT7992 / BE6500）
iwinfo rai0 info; dmesg | grep -i -E "mt7992|mt_wifi|sku" | tail -20
# 3 HNAT / turboacc
cat /sys/kernel/debug/hnat/hnat_stats 2>/dev/null | head; uci show turboacc 2>/dev/null
# 4 AT 双口隔离（应仍是 qmodem=3 / webui=2，valid_at_ports 只有 /dev/ttyUSB3）
cat /run/rm502q-at/qmodem /run/rm502q-at/webui; uci get qmodem.2_1.valid_at_ports
# 5 拨号 + 面板
ubus call at-daemon sendat '{"at_port":"/dev/ttyUSB3","at_cmd":"ATI","timeout":5}'
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8001/
# 6 风扇（CPU 温度 / pwm）
logread | grep fancontrol | tail -5
# 7 短信转发（发条测试短信看企微）
ubus call qmodem_sms list_sms | head -c 400
# 8 OpenClash
/etc/init.d/openclash status; curl -s -H "Authorization: Bearer $(uci get openclash.config.dashboard_password)" http://127.0.0.1:9090/version
```

## 已知差异 / 风险（都在本分支显式处理或待实机确认）

1. **CPU 变频**：24.10 基座的 DTS 里 4 条 OPP 全是 2GHz → 只能跑 2GHz；25.12 的
   `target/linux/mediatek/dts/mt7987.dtsi` 里是 **500M / 1.3G / 1.6G / 2.0G 四档**，
   驱动 `proc_fixed_volt=true`（只调频不调压），默认 governor = `schedutil`。
   预期首启后能看到 4 档并自动降频（能省电降温，但没有深睡 C-state：`CONFIG_CPU_IDLE` 仍关）。
   若 `scaling_available_frequencies` 只有 `2000000`，说明这条路径没生效，那就维持原状。
2. **Wi-Fi SKU**：`config/h5000m-25.12.seed` 里是 `CONFIG_MTK_WIFI7_SKU_TYPE="BE6500"`（本机
   MT7992 的 SKU 就是 BE6500，dat 集里有 `mt7992.6500.*`）；若无线异常，先试改回
   `"BE5040"`（24.10 基座在用的值）再编。
3. **AT 双口隔离要重验**：QModem 从 3.0.0 升到 **3.4.0_rc3**，其内部
   `modem_scan.sh` / `valid_at_ports` 行为可能变，`/usr/bin/rm502q-at-map` 的
   "收窄 valid_at_ports" 逻辑要到实机上再确认一次。
4. **24.10 时代我们自己打的 mtwifi 补丁没搬**（apcli bssid 预算 / sta_mgmt_assoc
   hostapd guard / wifi-utility rbus）。r8 SDK 里这些位置要么已修、要么路径变了；
   如果实机出现同名症状，再按新路径补。
5. **`rootfs-preflight` 作业未适配 apk**：脚本在检测到 `tmp/apk_install_list` 时会
   明确报错退出（不会给假结论）。要用这个预检得先把 IPK 解析改成 `.apk`（tar + `.PKGINFO`）。
6. **`config-coverage` 作业**里的 nikki/mosdns/homeproxy/adblock 等开关在本基座上不再
   产生差异（那些包不引入），该作业是可选的手动项。
7. 面板 / QSCAN / 邻区 v8 / 短信时区 / IPv6 快失败 / OpenClash 辅助脚本全部原样搬过来
   （纯用户态，不依赖内核版本），但仍按上面的清单实机核对一遍。
