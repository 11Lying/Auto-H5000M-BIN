# Hiveton H5000M — ImmortalWrt 25.12 HNAT/WED repair build

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
that exact package. The base's MTK Ethernet/HNAT sources are patched below;
no closed-source mtwifi tree is selected.

## Hardware-acceleration repairs

The build applies seven persistent, version-checked changes:

- `970/971/972`: existing fan startup handover only; thermal levels/trips are untouched.
- `973`: adds the four MT7987 PDMA IRQ resources (189–192) before the four FE
  resources (196–199), matching the pinned RSS driver, and adds the required
  HNAT `mtketh-soc = <&eth>` phandle to the H5000M node.
- `974`: makes HNAT probe failure cleanup conditional on a successfully mapped
  `fe_base`, preventing the previously observed NULL MMIO access/panic.
- `975`: generates `wed_enable=Y` for the MT7996E module. It does not enable
  RRO; WED activation still depends on a successful Ethernet provider probe.
- `976`: autoloads the packaged HNAT module after built-in Ethernet probing.

The final image must contain `kmod-mediatek_hnat`, `hnat-detect`, the NF
conntrack/NAT/flow packages, MT76/MT7992, QMI/QMAP and OpenClash. The build
collector checks the expanded config and image manifest, not just the presence
of a source `.ko`.

The source and build checks intentionally do **not** claim runtime PPE/HNAT,
WED or QMI external-device acceleration until a later approved on-device
counter check proves it. No router-side module load or stress test is part of
this workspace build.

The two primary application services selected are:

1. OpenClash
2. `luci-app-qmodem-next`

QModem's stable feed supplies the modem core, AT daemon, serial/QMI dependencies, Quectel vendor QMI WWAN driver and supporting tools. The legacy `luci-app-qmodem`, ModemManager and generic modem UI are not selected.

The image retains the official H5000M device packages and adds the explicit acceleration/data-path packages below:

- Official: `kmod-hwmon-pwmfan`, `kmod-usb3`, `mt7987-2p5g-phy-firmware`, `kmod-mt7996e`, `kmod-mt7992-23-firmware`, and filesystem/automount utilities.
- Added: `kmod-mediatek_hnat` (IPv4/IPv6 HNAT/PPE), `kmod-nf-conntrack`, `kmod-nf-nat`, `kmod-nf-flow` (nft flowtable HW/SW offload API), and `hnat-detect` (interface selection and USB/WWAN Rx-PPD handling).

`hnat-detect` is not the HNAT driver; `kmod-mediatek_hnat` is required in the final image.

The first-boot defaults request fw4 software+hardware flow offload. The HNAT module and USB/WWAN detector are included so eligible direct/NAT flows can use the MT7987 PPE path; the final manifest is checked for both. IPv6 is enabled in the kernel and the MTK HNAT driver has IPv6 flow paths. USB 5-Gbps is the physical link capability; HNAT/PPD is a separate forwarding fast path for eligible QMI/WWAN traffic. Actual acceleration still must be confirmed after flashing from HNAT/PPE counters and IPv4/IPv6/USB throughput tests; a config flag alone is not proof. Auxiliary selected packages include SmartDNS, SQM and irqbalance (SQM is installed but not enabled by default because shaping commonly bypasses hardware offload).

## Community patch audit

| Patch / change | Origin and original purpose | Pinned 25.12 HNAT base status | Decision |
|---|---|---|---|
| H5000M DTS replacement | Old vendor/community trees | Official DTS already exists and is used by the official device profile | **Not imported** |
| `mtwifi-apcli-active-only.patch` | Old closed MediaTek mtwifi tree | Not used by the pinned 25.12 HNAT build | **Not imported** |
| old mtwifi/mtwifi-cfg edits | Vendor Wi-Fi SDK integration | Not part of the pinned 25.12 HNAT build | **Not imported** |
| HNAT local-destination patch | Old vendor HNAT behaviour workaround | No board-specific requirement identified for this integration | **Not imported** |
| QMI WWAN 6.6 patch | Old kernel/vendor QMI tree | Official baseline is kernel 6.12; QModem stable supplies its own compatible vendor QMI package | **Not imported** |
| MT7992 firmware/eeprom changes | Vendor Wi-Fi tree changes | Upstream mt76 and its MT7992 firmware are supplied by `vendor/mt76`; the DTS binds `mediatek,mt76` | **No vendor EEPROM changes** |
| fan startup patch | Official 6.12 `pwm-fan` probes at 100% and has no boot-duty property | Not upstream; verified necessary for the requested startup-noise fix | **Minimal patch only** |

## Full-cone NAT decision

The pinned firewall4/fullconenat-nft source is real and is packaged as a
firewall4 dependency, but full-cone rules are disabled in the H5000M first-boot
defaults. The nft full-cone expression is UDP-oriented and has not been proven
compatible with this MT7987 PPE/HNAT path; enabling it by default would trade
away the stable hardware-offload path for an unverified behavior. It remains
available for a separately tested UCI decision.


The official H5000M DTS remains the base. A narrowly-scoped board overlay adds `pwm-fan,boot-duty = <89>` (about 35% of 255) to prevent the upstream driver's 100% probe duty. The upstream `pwm-fan` driver gets the matching optional-property patch; the stock thermal cooling levels and critical trips are unchanged. A module autoload patch loads pwm-fan in the early module pass.

The local `h5000m-fancontrol` package starts at init priority 15. It applies
the configured temperature curve, immediately raises PWM only after the
configured sustained-rise debounce (with an emergency high-temperature bypass),
delays/hysteresis-protects reductions, takes over the shared CPU thermal
governor, and restores it on exit. The defaults use the existing H5000M curve,
5-second sampling, 3°C hysteresis, 3-second down-delay, 15-second up-delay,
Wi-Fi temperature with 5°C offset, and a 153/255 safe PWM only if both
temperature sources fail at startup. Runtime boot timing and acoustic behavior
still require a post-flash hardware check.

## Performance optimizations

On top of the stock device packages:

- **BBR** (`kmod-tcp-bbr`) — set as default at first boot via uci-defaults (`91-h5000m-bbr` writes `/etc/sysctl.d/10-bbr.conf`). It is software TCP congestion control, useful for variable-latency 5G links and the proxy's outer TCP socket; it is not hardware encryption/offload.
- **OpenClash/Mihomo TUN proxy traffic is not HNAT-accelerated end-to-end**: packets pass through userspace proxy processing and encryption. HNAT can accelerate eligible direct/forwarded flows, including supported QMI/USB WAN flows, but cannot skip Mihomo's userspace work. `kmod-cryptodev` and `kmod-tls` are retained as kernel interfaces for compatible applications; Mihomo does not automatically consume them, so they are not claimed as proxy acceleration.
- **SQM** (`luci-app-sqm`, cake) — keeps latency stable when the 5G uplink jitters. Installed but not enabled; set per-link speeds in LuCI after flashing.
- **irqbalance** — selected to distribute hardware interrupts across CPU cores; verify its service state after first boot.

Deliberately not enabled by default: full-cone NAT (the real `kmod-nft-fullcone`
package is included because firewall4 provides it, but H5000M defaults set
`fullcone=0` and `fullcone6=0` until PPE compatibility is separately proven).
EHT160 wireless tuning is also not forced; the firmware keeps stock wireless
runtime defaults.

A read-only `/usr/bin/h5000m-audit` reports board, Wi-Fi/WED, HNAT/PPE, flow-offload, USB/QMI, BBR, OpenClash and fan state. The first-boot defaults request fw4 software and hardware flow offload; this is only configuration. Runtime proof requires driver binding plus increasing HNAT/PPE flow counters under eligible traffic.

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
- `workflow_dispatch` with `confirm_firmware_build=true` runs the H5000M HNAT firmware build.
- The build artifact contains images, expanded `.config`, manifest, source/feed/plugin provenance and SHA256 sums.
- Cache keys include the pinned source commit, target, config hash and patch-set hash.

The vendor/closed-source Wi-Fi branch is intentionally **not built**. It would require a separate non-official kernel/driver integration and is excluded from the stable baseline.