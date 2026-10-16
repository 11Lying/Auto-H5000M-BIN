# Hiveton H5000M — ImmortalWrt 25.12 HNAT build

This repository builds a small, auditable Hiveton H5000M image from the pinned ImmortalWrt 25.12-based MTK tree. It explicitly packages the MediaTek HNAT driver; CI verifies that `kmod-mediatek_hnat` is present in the final image manifest, not merely compiled as a kernel object.

## Baseline

| Item | Value |
|---|---|
| Source | `chasey-dev/immortalwrt-mt798x-rebase` |
| Source ref | `25.12` |
| Pinned source commit | `468e251661cb46face4ca0c961238282a6eaaa0a` |
| ImmortalWrt upstream merge base | `ce35a9e4ef1b87fbbc2146036ce6693e4242861a` |
| Target | `mediatek/filogic` |
| Device | `hiveton_h5000m` |
| Kernel | 6.12.112 |
| Wi-Fi | vendored ImmortalWrt `mt76` package (`kmod-mt7996e` + `kmod-mt7992-23-firmware`) |
| OpenClash | pinned ImmortalWrt LuCI feed, 0.47.156 |
| QModem | stable `v3.3.0`, commit `5cc80e5f9fc218cd50bef9749dc7d0027e8b3072` |

The pinned base supplies the H5000M DTS, board network/MAC logic, MT7987 PHY firmware, USB3, PWM fan, image definition and partition/sysupgrade logic. The base does not include `package/kernel/mt76`; this repository vendors the official ImmortalWrt 25.12 package under `vendor/mt76/` and stages it into the source tree so the MT7992 Wi-Fi driver and firmware are actually built into the image.

## What is selected

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

## Fan control and startup handover

The official H5000M DTS remains the base. A narrowly-scoped board overlay adds `pwm-fan,boot-duty = <89>` (about 35% of 255) to prevent the upstream driver's 100% probe duty. The upstream `pwm-fan` driver gets the matching optional-property patch; the stock thermal cooling levels and critical trips are unchanged. A module autoload patch loads pwm-fan in the early module pass.

The local `h5000m-fancontrol` package starts at init priority 15. It applies the configured temperature curve, immediately raises PWM, delays/hysteresis-protects reductions, takes over the shared CPU thermal governor, and restores it on exit. The defaults use the existing H5000M curve, 5-second sampling, 3°C hysteresis, 5-second down-delay, Wi-Fi temperature with 5°C offset, and a 153/255 safe PWM only if both temperature sources fail at startup. Runtime boot timing and acoustic behavior still require a post-flash hardware check.

## Performance optimizations

On top of the stock device packages:

- **BBR** (`kmod-tcp-bbr`) — set as default at first boot via uci-defaults (`91-h5000m-bbr` writes `/etc/sysctl.d/10-bbr.conf`). It is software TCP congestion control, useful for variable-latency 5G links and the proxy's outer TCP socket; it is not hardware encryption/offload.
- **OpenClash/Mihomo TUN proxy traffic is not HNAT-accelerated end-to-end**: packets pass through userspace proxy processing and encryption. HNAT can accelerate eligible direct/forwarded flows, including supported QMI/USB WAN flows, but cannot skip Mihomo's userspace work. `kmod-cryptodev` and `kmod-tls` are retained as kernel interfaces for compatible applications; Mihomo does not automatically consume them, so they are not claimed as proxy acceleration.
- **SQM** (`luci-app-sqm`, cake) — keeps latency stable when the 5G uplink jitters. Installed but not enabled; set per-link speeds in LuCI after flashing.
- **irqbalance** — selected to distribute hardware interrupts across CPU cores; verify its service state after first boot.

Deliberately not added: fullcone NAT (no usable package source found for 25.12), EHT160 wireless tuning (runtime wireless config, out of scope for this repo — the firmware boots with stock wireless defaults).

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