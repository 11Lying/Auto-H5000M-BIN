# Hiveton H5000M — ImmortalWrt 25.12 integrated PPE/flow-offload build

This repository builds a reproducible Hiveton H5000M image from the pinned
`chasey-dev/immortalwrt-mt798x-rebase` 25.12 tree that matches the audited
MT7987A/6.12.113 device. The final source is intentionally one baseline only;
it does not mix the older official `v25.12.2`/6.12.103 tree with the
chasey-dev tree.

## Baseline

| Item | Value |
|---|---|
| Source | `chasey-dev/immortalwrt-mt798x-rebase` |
| Source ref | `25.12` |
| Pinned source commit | `468e251661cb46face4ca0c961238282a6eaaa0a` |
| Target | `mediatek/filogic` |
| Device | `hiveton_h5000m` |
| Kernel | 6.12.113 (kernel.org stable tag `v6.12.113`) |
| Wi-Fi | vendored official ImmortalWrt 25.12 `mt76` + MT7992 firmware |
| OpenClash | pinned ImmortalWrt LuCI feed, 0.47.156 |
| QModem | stable `v3.3.0`, commit `5cc80e5f9fc218cd50bef9749dc7d0027e8b3072` |

The OpenWrt base remains pinned at `468e251661cb46face4ca0c961238282a6eaaa0a`.
The upstream 25.12 branch has since advanced to `03eb30617955519e35845838c6255ebe687eb717` (two commits); the only code change in that range adjusts the closed `wifi_utility` EEPROM backend for multi-card devices. This build uses open-source mt76, so that vendor-only change is not imported.

The kernel tarball alone is advanced to upstream stable `v6.12.113`
(commit `7fdb7c1824a1f9979d648d7ae28ac446bcee9c6e`, SHA256
`e09b6727e5c521253f0d41694900b9c38fb7604db7d35238a8197aa9f7de2428`). This
stable release includes netfilter flowtable/conntrack offload-bit fixes, an
mt7996 WED-RRO event-layout fix, and an mtk_eth_soc probe-ordering fix. The
kernel pin is verified in the source preflight, and the complete 6.12 target
patch queue has additionally passed a local `make target/linux/prepare` +
defconfig + Ethernet-object compile against this exact tarball; the full image
build runs via `scripts/local-build.sh`.

The base's `788-v7.3-net-usb-qmi_wwan-add-Quectel-EG120K-EA.patch` is also
preserved, but moved outside the active patch queue: upstream 6.12.113 already
contains the same `2c7c:030b` USB ID. The build checks the prepared 6.12.113
`qmi_wwan.c` for that ID, so the patch is neither silently dropped nor applied
twice. The RM502Q-AE QMI/QMAP path is separate and remains provided by the
pinned QModem `qmi_wwan_q` package.

The same stable release also upstreamed the NAPI/dummy-netdev registration
ordering fix carried by the base's `999-eth-07`. The original patch is retained
outside the active queue; `974` keeps only the `mtk_napi_del()` helper and
cleanup call sites required by the 6.12 RSS patch `999-eth-09`. The original
`999-eth-91` HNAT integration patch is also preserved. Patch `975` omits only
its now-stale HNAT-specific probe-unwind guard; the independent HNAT module is
not selected, and the integrated PPE remains the only supported route here.

The pinned base supplies the H5000M board DTS, MT7987 PHY firmware, USB3,
image definition and partition/sysupgrade logic. The base does not contain the
upstream `package/kernel/mt76` package, so this repository vendors and stages
that exact package. The base's MTK Ethernet/PPE integration is retained;
no closed-source mtwifi tree or independent mtkhnat probe is selected.

## Hardware-acceleration path

The active build follows the pinned tree's integrated 6.12 route: MT7987
`mtk_eth_soc` initializes its two PPE
instances (`offload_version=2`, `ppe_num=2`), and firewall4 uses
`kmod-nft-offload` with `flow_offloading_hw=1`.

The reference tag `v2026.08.19-h5000m-pro` peels to `219943d3499eb9d76d0d41ca1e473f183aced98c` (also current `main`) and targets Linux 6.18.57. Its DTS has only the four FE IRQs 196–199. That IRQ list cannot be copied into this
6.12 tree: this pinned 6.12 RSS patch explicitly calls
`platform_get_irq(pdev, 0..3)` for four PDMA IRQs and
`platform_get_irq(pdev, 4..7)` for four FE IRQs. Therefore the active `973`
overlay adds 189–192 before 196–199. The 189–192 values also occur in the pinned tree's MT7987 kernel DTS patch. This is based on the 6.12 driver request sequence and the same tree's SoC DTS, not on the 6.18 reference DTS alone. The final image must still be checked for all eight IRQs in its compiled DTB.

The separate `mtkhnat.ko` route is **not selected**. The 6.12
`999-eth-91` integration patch disables the normal integrated PPE probe/start
path whenever `CONFIG_NET_MEDIATEK_HNAT` is enabled; enabling both routes was
therefore unsafe. The previous independent-HNAT patches remain under
`patches/optional-independent-hnat/` as a preserved reference, but the build
script does not apply them.

Active patches:

- `968`: pins the official Linux 6.12.113 tarball and SHA256.
- `969`: applies the tested 8-hour RM502Q SMS timestamp correction to the pinned QModem source without replacing the upstream script.
- `970/971/972`: fan boot-duty and early pwm-fan loading; thermal levels/trips remain unchanged.
- `973`: only the 6.12 Ethernet RSS/PDMA IRQ resource correction.
- `974`: rebases the NAPI cleanup helper/call sites needed by RSS onto 6.12.113
  while preserving the stable kernel's upstream dummy-netdev ordering fix.
- `975`: removes the obsolete HNAT-only cleanup guard from the patch queue for
  this integrated-PPE build; the original patch file remains preserved in the
  build source outside the active queue.
- `vendor/mt76/patches/0118`: exact upstream MT7996 WED-RRO BA-delete event
  layout fix backported from `bd49f063...`; it corrects the 12-byte firmware
  record size in the pinned March mt76 source without a broad driver update.
- `999-eth-94`: guard the vendor GMAC/XFI MIB readers against sparse/disabled
  MAC indices, absent `hw_stats`, and missing SGMII/USXGMII PCS pointers. It
  snapshots accumulated MAC counters under the existing per-MAC stats lock,
  formats after releasing the lock, and corrects the source-confirmed swapped
  RX broadcast/multicast drop labels.
- `999-eth-95`: create debugfs/proc entries after internal storage and NAPI are ready but before `register_netdev()` exposes traffic; fail probe only if required storage allocation fails; drain entries on registration failure and removal.

The basis for `999-eth-94` is the pinned 6.12 vendor debugfs implementation:
`mtk_eth_debugfs_mac_cnt_show()` iterates `MTK_GMAC_ID_MAX` and dereferences
`eth->mac[i]` and `hw_stats` without checking them, while the H5000M DTS leaves
GMAC2 absent. The captured Oops PC is inside this function
(`+0x78/0x280`), which is consistent with that unsafe path. The retained Oops
record does not include fault-address/register details, so this project does
not claim to have proven the exact faulting instruction; the patch guards the
verified source-level defect for every sparse index. The same audit found
unguarded GMAC lookups in the SGMII/USXGMII debugfs helpers and a swapped pair
of XFI counter labels; both are covered by the same evidence-based patch.

WED/RRO is not forced. The MT7987 WED provider, IRQ 205, Ethernet
`mediatek,wed = <&wed0>` binding and kernel WED option remain from the pinned
source, but no extra mt76 WED module parameter is injected. The separately
reviewed `vendor/mt76/patches/0118` fixes the confirmed 12-byte WED-RRO BA-delete
event layout; it does not enable RRO or change the driver source baseline.

The image explicitly selects `kmod-nf-conntrack`, `kmod-nf-nat`, `kmod-nf-flow`
and `kmod-nft-offload`. The collector verifies the expanded `.config` and the
final image manifest. It also rejects an accidental `kmod-mediatek_hnat` or
`hnat-detect` package.

This proves only the build route and package closure, not runtime PPE counters.
USB QMI/QMAP `wwan0_1` is deliberately **not claimed** as hardware-offloaded;
its compatibility with the Ethernet PPE must be tested separately after a
successful boot. OpenClash/Mihomo TUN traffic remains userspace traffic.

The selected application stack includes OpenClash, SmartDNS, `luci-app-qmodem-next`,
`h5000m-modem-support`, and `h5000m-network-guard`. QModem's pinned stable feed
supplies the modem core, AT daemon, serial/QMI dependencies, Quectel vendor QMI
WWAN driver and SMS forwarder. The separate ModemWebUI is shipped by the
H5000M package at its existing HTTP/WebSocket ports; the legacy Lua QModem UI
and ModemManager remain unselected. The `h5000m-network-guard` package restores
the existing IPv6 LAN-route and foreign-client-v6 fast-fail policy, without
changing DNS targets or OpenClash rules.

The modem package contains the previously deployed WebUI v8/QSCAN frontend,
AT role isolation, QMI wedge recovery, and generic WeCom adapter. Its first-boot
setup enables the services, adds a WAN-only reject rule for management ports,
and does not create a webhook config or rewrite WAN/DNS/OpenClash UCI. Private
OpenClash subscriptions, node credentials, dashboard passwords, and WeCom
keys are deliberately excluded from this public repository and firmware; they
must be restored from the user's private backup/configuration.

The `luci-app-smartdns` and SmartDNS engine are packaged, but this public image
intentionally does not ship `/etc/config/openclash`, subscription URLs, node
credentials, dashboard secrets, or a user-specific SmartDNS/Mihomo DNS chain.
Consequently, selecting the packages is not a claim that the SmartDNS →
OpenClash runtime chain is already configured. Restore those private settings
from the user's backup after installation; the build does not rewrite DNS
servers, domain rules, strategy groups, or subscriptions.

The image retains the official H5000M device packages and adds these explicit data-path and application packages:

- Official: `kmod-hwmon-pwmfan`, `kmod-usb3`, `mt7987-2p5g-phy-firmware`, `kmod-mt7996e`, `kmod-mt7992-23-firmware`, and filesystem/automount utilities.
- Added: `kmod-nf-conntrack`, `kmod-nf-nat`, `kmod-nf-flow`, `kmod-nft-offload`, SmartDNS, SQM, BBR, `h5000m-modem-support`, and `h5000m-network-guard`.

The first-boot defaults request fw4 software+hardware flow offload. This is
configuration for the integrated PPE path, not proof that USB/QMI/QMAP traffic
will enter PPE. The network-guard first-boot defaults add only the known IPv6
route/firewall includes and `ra_default=2`; they do not alter WAN or DNS targets.
Runtime confirmation requires Ethernet probe success, driver binding and
increasing PPE/flowtable counters.

## Community patch audit

| Patch / change | Origin and original purpose | Pinned 25.12 integrated-PPE status | Decision |
|---|---|---|---|
| H5000M DTS replacement | Old vendor/community trees | Official DTS already exists and is used by the official device profile | **Not imported** |
| `mtwifi-apcli-active-only.patch` | Old closed MediaTek mtwifi tree | Not used by the pinned 25.12 integrated-PPE build | **Not imported** |
| old mtwifi/mtwifi-cfg edits | Vendor Wi-Fi SDK integration | Not part of the pinned 25.12 integrated-PPE build | **Not imported** |
| HNAT local-destination patch | Old vendor HNAT behaviour workaround | No board-specific requirement identified for this integration | **Not imported** |
| QMI WWAN 6.6 patch | Old kernel/vendor QMI tree | Official baseline is kernel 6.12; QModem stable supplies its own compatible vendor QMI package | **Not imported** |
| MT7992 firmware/eeprom changes | Vendor Wi-Fi tree changes | Upstream mt76 and its MT7992 firmware are supplied by `vendor/mt76`; the DTS binds `mediatek,mt76` | **No vendor EEPROM changes** |
| fan startup patch | Official 6.12 `pwm-fan` probes at 100% and has no boot-duty property | Not upstream; verified necessary for the requested startup-noise fix | **Minimal patch only** |

## Full-cone NAT decision

The pinned firewall4/fullconenat-nft source is real and is packaged as a
firewall4 dependency, but full-cone rules are disabled in the H5000M first-boot
defaults. The nft full-cone expression is UDP-oriented and has not been proven
compatible with this MT7987 integrated PPE path; enabling it by default would
trade away the conservative hardware-offload path for an unverified behavior. It remains
available for a separately tested UCI decision.


The official H5000M DTS remains the base. A narrowly-scoped board overlay adds `pwm-fan,boot-duty = <89>` (about 35% of 255) to prevent the upstream driver's 100% probe duty. The upstream `pwm-fan` driver gets the matching optional-property patch; the stock thermal cooling levels and critical trips are unchanged. A module autoload patch loads pwm-fan in the early module pass.

The local `h5000m-fancontrol` package starts at init priority 15. It applies
the configured temperature curve, raises PWM immediately when the requested
curve value increases, delays/hysteresis-protects reductions, takes over the
shared CPU thermal governor, and restores it on exit. The `wifi_temp=0` UCI
setting now bypasses mt76 hwmon as well as the legacy iwpriv fallback. The
defaults use the
existing H5000M curve, 5-second sampling, 3°C hysteresis, 5-second down-delay,
Wi-Fi temperature with 5°C offset, and a 153/255 safe PWM only if both
temperature sources fail at startup. Runtime boot timing and acoustic behavior
still require a post-flash hardware check.

## Performance optimizations

On top of the stock device packages:

- **BBR** (`kmod-tcp-bbr`) — set as default at first boot via uci-defaults (`91-h5000m-bbr` writes `/etc/sysctl.d/10-bbr.conf`). It is software TCP congestion control, useful for variable-latency 5G links and the proxy's outer TCP socket; it is not hardware encryption/offload.
- **OpenClash/Mihomo TUN proxy traffic is not integrated-PPE-accelerated end-to-end**: packets pass through userspace proxy processing and encryption. The integrated PPE may accelerate eligible direct Ethernet flows after successful runtime initialization; this repository does not claim USB/QMI/QMAP or proxy hardware offload. `kmod-cryptodev` and `kmod-tls` are retained as kernel interfaces for compatible applications; Mihomo does not automatically consume them, so they are not claimed as proxy acceleration.
- **SQM** (`luci-app-sqm`, cake) — keeps latency stable when the 5G uplink jitters. Installed but not enabled; set per-link speeds in LuCI after flashing.
- **irqbalance** — selected to distribute hardware interrupts across CPU cores; verify its service state after first boot.

Deliberately not enabled by default: full-cone NAT (the real `kmod-nft-fullcone`
package is included because firewall4 provides it, but H5000M defaults set
`fullcone=0` and `fullcone6=0` until PPE compatibility is separately proven).
EHT160 wireless tuning is also not forced; the firmware keeps stock wireless
runtime defaults.

A read-only `/usr/bin/h5000m-audit` reports board, Wi-Fi/WED, integrated PPE,
flow-offload, USB/QMI, BBR, OpenClash and fan state. The first-boot defaults
request fw4 software and hardware flow offload; this is only configuration.
Runtime proof requires Ethernet driver binding plus increasing PPE/flowtable
counters under eligible traffic.

## CPUFreq

The pinned base retains the upstream MT7987 CPUFreq implementation:

- `CONFIG_ARM_MEDIATEK_CPUFREQ=y`
- four upstream OPPs: 500 / 1300 / 1600 / 2000 MHz
- `CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y`
- maximum remains 2.0 GHz
- no voltage patch, overclock, undervolt or fixed-frequency script
- no `performance` governor forcing in this repository

The expanded `.config` and the verification report are uploaded with every build.

## Build locally

```sh
# Use a new clean source directory for each build; keep ccache outside it.
CCACHE_DIR="$HOME/.cache/h5000m-ccache" \\
SOURCE_DIR="$HOME/immortalwrt-h5000m-audit-1" scripts/local-build.sh

# A later independent build uses another clean source directory, but reuses ccache:
CCACHE_DIR="$HOME/.cache/h5000m-ccache" \\
SOURCE_DIR="$HOME/immortalwrt-h5000m-audit-2" THREADS=12 \\
  CCACHE_MAXSIZE=20G scripts/local-build.sh
```

The build script intentionally refuses dirty source/feeds rather than resetting
or cleaning user data. It stages patches and vendor package overlays into its
source tree, so reusing a previously built tree requires a reviewed cleanup;
use a new `SOURCE_DIR` instead. The source/download cache and ccache can be
shared safely.

The script refuses to proceed unless the pinned source commit, pinned feeds, H5000M profile, mt76 stack and allowed patch set pass `scripts/verify-config.sh`.

## GitHub Actions

- Pushes to `main` and `audit-upgrade-2026-10` run the static/config validation job.
- `workflow_dispatch` with `confirm_firmware_build=true` runs the H5000M integrated-PPE firmware build.
- The build artifact contains images, expanded `.config`, manifest, source/feed/plugin provenance and SHA256 sums.
- Cache keys include the pinned source commit, target, config hash and patch-set hash.

The vendor/closed-source Wi-Fi branch is intentionally **not built**. It would require a separate non-official kernel/driver integration and is excluded from the stable baseline.