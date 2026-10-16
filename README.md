# Hiveton H5000M — ImmortalWrt 25.12 integrated PPE/flow-offload build

This repository builds a reproducible Hiveton H5000M image from the pinned
`chasey-dev/immortalwrt-mt798x-rebase` 25.12 tree that matches the audited
MT7987A/6.12.112 device. The final source is intentionally one baseline only;
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
| Kernel | 6.12.112 |
| Wi-Fi | vendored official ImmortalWrt 25.12 `mt76` + MT7992 firmware |
| OpenClash | pinned ImmortalWrt LuCI feed, 0.47.156 |
| QModem | stable `v3.3.0`, commit `5cc80e5f9fc218cd50bef9749dc7d0027e8b3072` |

The pinned base supplies the H5000M board DTS, MT7987 PHY firmware, USB3,
image definition and partition/sysupgrade logic. The base does not contain the
upstream `package/kernel/mt76` package, so this repository vendors and stages
that exact package. The base's MTK Ethernet/PPE integration is retained;
no closed-source mtwifi tree or independent mtkhnat probe is selected.

## Hardware-acceleration path

The active build follows the integrated upstream 6.12 route used by the
reference project's newer builds: MT7987 `mtk_eth_soc` initializes its two PPE
instances (`offload_version=2`, `ppe_num=2`), and firewall4 uses
`kmod-nft-offload` with `flow_offloading_hw=1`.

The reference v4 commit `219943d349` is based on a newer kernel and its DTS
has only the four FE IRQs 196–199. That IRQ list cannot be copied into this
6.12 tree: this pinned 6.12 RSS patch explicitly calls
`platform_get_irq(pdev, 0..3)` for four PDMA IRQs and
`platform_get_irq(pdev, 4..7)` for four FE IRQs. Therefore the active `973`
overlay adds 189–192 before 196–199. This is based on the actual 6.12 driver
request sequence, not on the reference DTS alone.

The separate `mtkhnat.ko` route is **not selected**. The 6.12
`999-eth-91` integration patch disables the normal integrated PPE probe/start
path whenever `CONFIG_NET_MEDIATEK_HNAT` is enabled; enabling both routes was
therefore unsafe. The previous independent-HNAT patches remain under
`patches/optional-independent-hnat/` as a preserved reference, but the build
script does not apply them.

Active patches:

- `970/971/972`: fan boot-duty and early pwm-fan loading; thermal levels/trips
  remain unchanged.
- `973`: only the 6.12 Ethernet RSS/PDMA IRQ resource correction.

WED/RRO is not forced. The MT7987 WED provider, IRQ 205, Ethernet
`mediatek,wed = <&wed0>` binding and kernel WED option remain from the pinned
source, but no extra mt76 WED module parameter is injected.

The image explicitly selects `kmod-nf-conntrack`, `kmod-nf-nat`, `kmod-nf-flow`
and `kmod-nft-offload`. The collector verifies the expanded `.config` and the
final image manifest. It also rejects an accidental `kmod-mediatek_hnat` or
`hnat-detect` package.

This proves only the build route and package closure, not runtime PPE counters.
USB QMI/QMAP `wwan0_1` is deliberately **not claimed** as hardware-offloaded;
its compatibility with the Ethernet PPE must be tested separately after a
successful boot. OpenClash/Mihomo TUN traffic remains userspace traffic.

The two primary application services selected are:

1. OpenClash
2. `luci-app-qmodem-next`

QModem's stable feed supplies the modem core, AT daemon, serial/QMI dependencies, Quectel vendor QMI WWAN driver and supporting tools. The legacy `luci-app-qmodem`, ModemManager and generic modem UI are not selected.

The image retains the official H5000M device packages and adds the explicit acceleration/data-path packages below:

- Official: `kmod-hwmon-pwmfan`, `kmod-usb3`, `mt7987-2p5g-phy-firmware`, `kmod-mt7996e`, `kmod-mt7992-23-firmware`, and filesystem/automount utilities.
- Added: `kmod-nf-conntrack`, `kmod-nf-nat`, `kmod-nf-flow`, `kmod-nft-offload`, SmartDNS, SQM and BBR.

The first-boot defaults request fw4 software+hardware flow offload. This is
configuration for the integrated PPE path, not proof that USB/QMI/QMAP traffic
will enter PPE. Runtime confirmation requires Ethernet probe success, driver
binding and increasing PPE/flowtable counters.

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
shared CPU thermal governor, and restores it on exit. The defaults use the
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
# First run: config validation + full firmware build (auto jobs/ccache)
scripts/local-build.sh

# Reuse existing pinned feeds on later local builds; source tree and ccache stay intact
scripts/local-build.sh --skip-feeds-update

# Optional explicit tuning; 7945HX / 24 GiB: THREADS=12 is a safe starting point
THREADS=12 CCACHE_MAXSIZE=20G scripts/local-build.sh --skip-feeds-update
```

The script refuses to proceed unless the pinned source commit, pinned feeds, H5000M profile, mt76 stack and allowed patch set pass `scripts/verify-config.sh`.

## GitHub Actions

- Pushes run the static/config validation job.
- `workflow_dispatch` with `confirm_firmware_build=true` runs the H5000M integrated-PPE firmware build.
- The build artifact contains images, expanded `.config`, manifest, source/feed/plugin provenance and SHA256 sums.
- Cache keys include the pinned source commit, target, config hash and patch-set hash.

The vendor/closed-source Wi-Fi branch is intentionally **not built**. It would require a separate non-official kernel/driver integration and is excluded from the stable baseline.