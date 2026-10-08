# Hiveton H5000M — ImmortalWrt 25.12.2 official stable

This repository builds a deliberately small, auditable Hiveton H5000M image from the **official ImmortalWrt v25.12.2 release tag**.

## Baseline

| Item | Value |
|---|---|
| Source | `immortalwrt/immortalwrt` |
| Release tag | `v25.12.2` |
| Resolved source commit | `4fc16f2985a358bd43bb522e43f05395fcbd6ed5` |
| Target | `mediatek/filogic` |
| Device | `hiveton_h5000m` |
| Kernel | official 6.12.103 source definition |
| Wi-Fi | official upstream `mt76` (`kmod-mt7996e` + `kmod-mt7992-23-firmware`) |
| OpenClash | official ImmortalWrt LuCI feed, 0.47.156 |
| QModem | stable `v3.3.0`, commit `5cc80e5f9fc218cd50bef9749dc7d0027e8b3072` |

The official v25.12.2 H5000M target already supplies the official DTS, board network/MAC logic, MT7987 PHY firmware, MT7992 firmware, USB3, PWM fan, image definition and partition/sysupgrade logic. This repository does **not** replace any of those.

## What is selected

Only these two top-level third-party functions are selected:

1. OpenClash
2. `luci-app-qmodem-next`

QModem's stable feed supplies the modem core, AT daemon, serial/QMI dependencies, Quectel vendor QMI WWAN driver and supporting tools. The legacy `luci-app-qmodem`, ModemManager and generic modem UI are not selected.

The stock H5000M image also retains the packages declared by the official device definition:

- `kmod-hwmon-pwmfan`
- `kmod-usb3`
- `mt7987-2p5g-phy-firmware`
- `kmod-mt7996e`
- `kmod-mt7992-23-firmware`
- filesystem/automount utilities declared upstream

No custom network, firewall, DHCP, WAN, IPv6, DNS or OpenClash routing configuration is baked into the image.

## Community patch audit

| Patch / change | Origin and original purpose | v25.12.2 status | Decision |
|---|---|---|---|
| H5000M DTS replacement | Old vendor/community trees | Official DTS already exists and is used by the official device profile | **Not imported** |
| `mtwifi-apcli-active-only.patch` | Old closed MediaTek mtwifi tree | No official mtwifi tree is used by v25.12.2 H5000M | **Forbidden / not imported** |
| old mtwifi/mtwifi-cfg edits | Vendor Wi-Fi SDK integration | Not part of official 25.12.2 | **Forbidden / not imported** |
| HNAT local-destination patch | Old vendor HNAT behaviour workaround | No evidence required for the official baseline | **Not imported** |
| QMI WWAN 6.6 patch | Old kernel/vendor QMI tree | Official baseline is kernel 6.12; QModem stable supplies its own compatible vendor QMI package | **Not imported** |
| MT7992 firmware/eeprom changes | Vendor Wi-Fi tree changes | Official target selects upstream mt76 and `kmod-mt7992-23-firmware`; official DTS binds `mediatek,mt76` | **Not imported** |
| fan startup patch | Official 6.12 `pwm-fan` probes at 100% and has no boot-duty property | Not upstream; verified necessary for the requested startup-noise fix | **Minimal patch only** |

## Fan change

Three minimal, separately auditable changes are applied:

- `970-pwm-fan-boot-duty.patch`: optional `pwm-fan,boot-duty` property in the official 6.12 `pwm-fan` driver. It changes only the initial probe duty; it does not alter thermal trips or cooling levels.
- `971-hwmon-pwmfan-boot-autoload.patch`: uses the official `AutoLoad(..., boot=1)` mechanism for Mediatek so `pwm-fan` is included in `modules-boot.d`.
- `972-h5000m-fan-boot-duty.patch`: official H5000M DTS only adds `pwm-fan,boot-duty = <89>` (35%). This value matches the vendor firmware's observed `start_speed=35`; 20% was rejected as insufficiently evidenced.

Official thermal cooling levels and protection remain unchanged: `<0 128 192 255>`, with the upstream thermal trip points. There is no second fan daemon and no forced CPU/fan policy.

## CPUFreq

The official v25.12.2 MT7987 implementation is retained:

- `CONFIG_ARM_MEDIATEK_CPUFREQ=y`
- four upstream OPPs: 500 / 1300 / 1600 / 2000 MHz
- `CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y`
- maximum remains 2.0 GHz
- no voltage patch, overclock, undervolt or fixed-frequency script
- no `performance` governor forcing in this repository

The expanded `.config` and the verification report are uploaded with every build.

## Build locally

```sh
scripts/local-build.sh --config-only
scripts/local-build.sh
```

The script refuses to proceed unless the exact release tag/commit, pinned official feeds, official H5000M profile, mt76 stack and the allowed patch set pass `scripts/verify-config.sh`.

## GitHub Actions

- Pushes run the static/config validation job.
- `workflow_dispatch` with `confirm_firmware_build=true` runs the official baseline firmware build.
- The build artifact contains images, expanded `.config`, manifest, source/feed/plugin provenance and SHA256 sums.
- Cache keys include source commit, target, config hash and patch-set hash. Old padavanonly/chasey source/object caches are not reused.

The vendor/closed-source Wi-Fi branch is intentionally **not built**. It would require a separate non-official kernel/driver integration and is excluded from the stable baseline.