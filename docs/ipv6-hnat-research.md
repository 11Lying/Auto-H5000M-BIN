# IPv6 HNAT 调研结论（hnat-6.12）

> **Packaging gate (2026-10-16):** the first successful run compiled `mtkhnat.ko` as a kernel module but left `CONFIG_PACKAGE_kmod-mediatek_hnat` unset, so the module was absent from the sysupgrade image. The seed now selects `kmod-mediatek_hnat`; CI and the build collector require it in the final image manifest. Do not infer runtime acceleration from a source config line or a successful build alone.

## 结论
**当前 973 DTS 节点无需任何改动即可支持 IPv6 硬件加速。**

## 依据

### 1. 驱动有独立的 IPv6 路径
6.12 内核的 `mtk_hnat` 驱动在 `drivers/net/ethernet/mediatek/mtk_hnat/hnat_nf_hook.c` 中有独立的 IPv6 处理函数：
- `mtk_hnat_ipv6_nf_pre_routing()`（IPv6）
- `mtk_hnat_ipv4_nf_pre_routing()`（IPv4）

Kconfig 依赖已从 `IP_NF_NAT`（仅 IPv4）改为 `NF_NAT`（通用，覆盖双栈），见补丁 `999-zzz-5117`。

### 2. DTS 无需 IPv6 专有属性
MTK 官方 MT7987 参考节点（`999-dts-mt7987a-rfb-06` 补丁中的 `mt7987-netsys.dtsi`）不含任何 IPv6 专有属性。当前 973 节点的 `mtketh-wan`、`mtketh-lan` 等字符串属性与官方的 `mtketh-soc` phandle 方式等效，驱动两种都支持。

### 3. 内核配置
所需选项均为 OpenWrt 默认已开：
- `CONFIG_IPV6=y`
- `CONFIG_NF_NAT`（通用 NAT）
- `CONFIG_NET_MEDIATEK_HNAT`（驱动本身）

无 IPv6 专用的 HNAT 配置项。

### 4. USB/WWAN 白名单对 IPv6 同样生效
补丁 `999-zzz-5111`（非 WHNAT 外接设备 ingress hook 支持）在 IPv4 和 IPv6 的 pre_routing 函数中**完全相同地**添加了外接设备 hook：
- `mtk_hnat_ipv6_nf_pre_routing()` 第 1261 行
- `mtk_hnat_ipv4_nf_pre_routing()` 第 1397 行

两者都用同一个 `IS_EXT(state->in)` 检查。**没有独立的 IPv6 白名单**——`ext-devices-prefix = "usb", "wwan", "rmnet", "eth2", "eth3"` 和 `ext-devices = "wwan0", "usb0"` 对 IPv4 和 IPv6 的 USB/WWAN 流量同时生效。

### 5. 已知问题
- `999-hnat-12` 已修复 IPv6 skb headroom 扩展问题
- 80+ 个 HNAT/PPE 补丁中未发现其他 IPv6 相关问题
- 6.12 上的 IPv6 HNAT 已成熟

## 审查要点
- 无需改动 973 补丁
- 刷机后验证 IPv6 加速：`dmesg | grep -i hnat` 应显示 IPv6 hook 注册；`cat /sys/kernel/debug/hnat/hnat_stats` 看 IPv6 flow 计数是否增长
- 注意：SQM 开启时会旁路硬件加速（IPv4/IPv6 均如此），这是预期行为

## 参考
- 驱动源码：`drivers/net/ethernet/mediatek/mtk_hnat/hnat_nf_hook.c`（chasey-dev 25.12，6.12.112）
- 补丁：`999-zzz-5111`、`999-zzz-5117`、`999-hnat-12`、`999-dts-mt7987a-rfb-06`
