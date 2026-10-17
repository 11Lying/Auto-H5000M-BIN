# Hiveton H5000M — ImmortalWrt 25.12 HNAT + USB/WWAN offload build

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
The upstream `25.12` and `25.12-dev` refs currently point to
`03eb30617955519e35845838c6255ebe687eb717`, two commits ahead. That range only
changes the closed `wifi_utility` EEPROM backend for multi-card devices; this
build uses open-source mt76, so that vendor-only change is not relevant. The
older base remains pinned to keep the build reproducible.

The kernel tarball alone is advanced to upstream stable `v6.12.113`
(commit `7fdb7c1824a1f9979d648d7ae28ac446bcee9c6e`, SHA256
`e09b6727e5c521253f0d41694900b9c38fb7604db7d35238a8197aa9f7de2428`). This
stable release includes netfilter flowtable/conntrack offload-bit fixes, an
mt7996 WED-RRO event-layout fix, and an mtk_eth_soc probe-ordering fix. The
kernel pin is verified in the source preflight. The previous PPE rollback
passed a local `make target/linux/prepare` and Ethernet-object compile against
this tarball; the HNAT-specific additions in this branch must pass a fresh
`target/linux/prepare`/module compile on the PC before flashing. The full image
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
`999-eth-91` HNAT integration patch is preserved and used. Its final unwind
hunk is rebased for 6.12.113: `975` removes the stale old-context hunk, while
`999-eth-96` reinstates the HNAT conditional around `mtk_ppe_deinit()` at the
new source location. The HNAT module is selected as the sole PPE owner; the
integrated PPE path is deliberately not started at the same time.

The pinned base supplies the H5000M DTS, MT7987 PHY firmware, USB3, image
layout, and sysupgrade logic. This build vendors the official ImmortalWrt 25.12
`mt76` package for MT7992 Wi-Fi; no closed-source mtwifi tree is selected.

## HNAT/PPE and USB/WWAN offload path

The HNAT variant selects the official `kmod-mediatek_hnat` driver as the sole
owner of the MT7987's two PPEs. The upstream `999-eth-91` integration guards
suppress `mtk_eth_soc`'s integrated PPE probe/start/stop path when
`CONFIG_NET_MEDIATEK_HNAT` is enabled. Running both owners would be unsafe.
The ordinary `mtk_eth_soc` Ethernet/DMA driver and mt76/WED Wi-Fi path remain
in use.

The USB/WWAN support is not just a config flag. The selected source and board
overlays include:

- Upstream `999-zzz-5111` external-device ingress/PPD handling and
  `999-zzz-5112` `ext-devices-prefix` matching.
- The H5000M HNAT v5 DTS node (`mtketh-soc`, two PPEs, flow-check IRQ 198) with
  prefixes `usb`, `wwan`, and `rmnet`. The live RM502Q QMI/QMAP netdev name
  `wwan0_1` matches the `wwan` prefix.
- The official `hnat-detect` hotplug utility. It resolves fw4 zones and creates
  the Rx-PPD bridge path for an external USB/WWAN WAN; it deliberately does
  not pretend the USB netdev is a physical GMAC.
- `CONFIG_MEDIATEK_NETSYS_V3=y` for HNAT v5's MT7987 register/entry layout,
  IPv6, conntrack/NAT/flow-table support, and `kmod-nft-offload`.
- The 6.12.113 Ethernet IRQ correction: PDMA IRQs 189–192 followed by FE IRQs
  196–199. The separate HNAT flow-check IRQ is 198. Both resources are checked
  in the DTS and build validation.
- A bounded HNAT probe/teardown safety patch, ordered module autoload, and an
  unwind guard so the non-owner integrated PPE is not deinitialized.

First boot requests fw4 software/hardware flow offload; full-cone remains off.
The source config, package manifest, HNAT DTS properties, and patch set are
checked before publishing an image. OpenClash/Mihomo TUN processing still runs
in userspace; HNAT cannot offload the proxy's userspace encryption work.

**Build-level support is not proof of live hardware acceleration.** After
flashing, verify: Ethernet and HNAT drivers bind without IRQ/Oops errors;
`hnat-detect` identifies the USB/WWAN WAN and creates Rx-PPD; HNAT/PPE counters
and entries increase during eligible `wwan0_1` upload/download traffic; IPv4
and IPv6 forwarding work; and Wi-Fi/WED, QModem/SMS/WebUI, OpenClash, and fan
control remain healthy. The build collector cannot claim these runtime results
without testing on the actual router.

Active acceleration-related patches include:

- `973`: MT7987 6.12 RSS/PDMA/FE IRQ resources.
- `975`: rebases the vendor 999-eth-91 patch for 6.12.113; original is preserved.
- `976/977/978`: HNAT probe safety, module autoload, and H5000M USB/WWAN HNAT DTS.
- `999-eth-94/95`: sparse-GMAC debugfs safety and lifecycle fixes.
- `999-eth-96`: skips integrated-PPE teardown when HNAT owns the PPE.
- `vendor/mt76/patches/0118`: targeted MT7996 WED-RRO event-layout fix; RRO is not forced.

The Oops audit remains separately documented: the source-level sparse-GMAC
MIB bug is guarded, but the original dump lacked enough registers to claim an
exact faulting instruction.

## Packaged services and first boot

The image includes OpenClash, SmartDNS plus LuCI, QModem Next, the standalone
ModemWebUI/AT-isolation/QSCAN support package, SMS-forwarder-next, the HNAT
interface detector, fan control, and IPv6 network guard. OpenClash node
subscriptions, credentials, dashboard secrets, and the WeCom webhook key are
not embedded. SmartDNS is packaged but the user's SmartDNS-to-OpenClash DNS
chain must be restored/configured separately. The first-boot packages do not
rewrite WAN, DNS, OpenClash rules, Wi-Fi credentials, or private UCI settings.

BBR is enabled as the default TCP congestion control on first boot. SQM/cake
is installed but off by default because shaping can bypass hardware offload.
`irqbalance` is packaged; verify its service after first boot. `kmod-cryptodev`
and `kmod-tls` are present as compatibility interfaces, not a claim of Mihomo
proxy acceleration. CPUFreq retains the upstream four OPPs (500/1300/1600/2000
MHz) and schedutil; no deep-idle support is claimed.

## Community patch audit

| Patch / change | Origin and purpose | HNAT+USB build status | Decision |
|---|---|---|---|
| H5000M DTS replacement | Old vendor/community trees | Official DTS already exists and is used by the official device profile | **Not imported** |
| `mtwifi-apcli-active-only.patch` | Old closed MediaTek mtwifi tree | Build uses open-source mt76 | **Not imported** |
| old mtwifi/mtwifi-cfg edits | Vendor Wi-Fi SDK integration | Not part of the mt76 build | **Not imported** |
| HNAT USB/WWAN ext-prefix + Rx-PPD | Upstream MediaTek HNAT patches | Included; runtime offload still requires counter validation | **Selected** |
| HNAT local-destination patch | Old vendor HNAT behaviour workaround | No H5000M-specific evidence it is required | **Not imported** |
| QMI WWAN 6.6 patch | Old kernel/vendor QMI tree | Kernel is 6.12.113; QModem supplies the RM502Q driver | **Not imported** |
| MT7992 firmware/eeprom changes | Vendor Wi-Fi tree changes | Upstream mt76 and its MT7992 firmware are supplied by `vendor/mt76`; the DTS binds `mediatek,mt76` | **No vendor EEPROM changes** |
| fan startup patch | Official 6.12 `pwm-fan` probes at 100% and has no boot-duty property | Not upstream; verified necessary for the requested startup-noise fix | **Minimal patch only** |

## Full-cone NAT decision

The pinned firewall4/fullconenat-nft source is packaged, but full-cone rules
are disabled in the H5000M first-boot defaults. The nft full-cone expression is UDP-oriented and has not been proven
compatible with the independent MT7987 HNAT path; enabling it by default would
add an unverified behavior to the initial validation matrix. It remains
available for a separately tested UCI decision.


The official H5000M DTS remains the base. Narrowly-scoped overlays add the HNAT node and `pwm-fan,boot-duty = <89>` (about 35% of 255) to prevent the upstream driver's 100% probe duty. The upstream `pwm-fan` driver gets the matching optional-property patch; the stock thermal cooling levels and critical trips are unchanged. A module autoload patch loads pwm-fan in the early module pass.

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
- **HNAT** is wired for eligible forwarded flows, including the USB/WWAN path, but that path remains a post-flash validation item. OpenClash/Mihomo TUN traffic still traverses userspace proxy processing/encryption and is not accelerated end-to-end by HNAT. `kmod-cryptodev` and `kmod-tls` are kernel interfaces for compatible applications; Mihomo does not automatically consume them.
- **SQM** (`luci-app-sqm`, cake) — keeps latency stable when the 5G uplink jitters. Installed but not enabled; set per-link speeds in LuCI after flashing.
- **irqbalance** — selected to distribute hardware interrupts across CPU cores; verify its service state after first boot.

Deliberately not enabled by default: full-cone NAT (the real `kmod-nft-fullcone`
package is included because firewall4 provides it, but H5000M defaults set
`fullcone=0` and `fullcone6=0` until HNAT compatibility is separately proven).
EHT160 wireless tuning is also not forced; the firmware keeps stock wireless
runtime defaults.

A read-only `/usr/bin/h5000m-audit` reports board, Wi-Fi/WED, HNAT/PPE,
flow-offload, USB/QMI, BBR, OpenClash and fan state. Runtime proof requires the
HNAT driver to bind and PPE counters/entries to increase under eligible traffic,
including a controlled USB/WWAN forwarding test.

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

The script refuses to proceed unless the pinned source commit, pinned feeds, H5000M profile, mt76/HNAT stack, USB/WWAN DTS path, and allowed patch set pass `scripts/verify-config.sh`.

## GitHub Actions

- Pushes to `main`, `audit-upgrade-2026-10`, and `hnat-usb-experimental-20261017` run the static/config validation job.
- `workflow_dispatch` with `confirm_firmware_build=true` runs the H5000M HNAT/USB firmware build.
- The build artifact contains images, expanded `.config`, manifest, source/feed/plugin provenance and SHA256 sums.
- Cache keys include the pinned source commit, target, config hash and patch-set hash.

The vendor/closed-source Wi-Fi branch is intentionally **not built**. The PPE-only rollback remains on `audit-upgrade-2026-10`; the HNAT/USB variant is isolated on its own branch. The public build contains no user credentials, subscriptions, Wi-Fi key, or webhook secret.