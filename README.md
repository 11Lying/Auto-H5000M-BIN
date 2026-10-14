# Hiveton H5000M — closed-driver performance build

This repository builds a performance-tuned Hiveton H5000M image on the
**closed MediaTek driver stack**: `padavanonly/immortalwrt-mt798x-6.6`
(`mt798x-mt799x-6.6-mtwifi` branch, kernel 6.6.94), pinned to an exact
commit for reproducibility.

## Baseline

| Item | Value |
|---|---|
| Source | `padavanonly/immortalwrt-mt798x-6.6` |
| Branch | `mt798x-mt799x-6.6-mtwifi` |
| Pinned source commit | `30fbc1d6deba23c0e850185021e9ee42214925eb` |
| Target | `mediatek/filogic` |
| Device | `hiveton-h5000m` (hyphenated name on this base) |
| Kernel | 6.6.94 |
| Wi-Fi | closed `mt_wifi7` (`kmod-mt_wifi7` + `mtwifi-cfg` + `luci-app-mtwifi-cfg`) |
| NAT offload | `mediatek_hnat` (`kmod-mediatek_hnat`) + `mtk_wed`, via `luci-app-turboacc-mtk` |
| QoS | `luci-app-eqos-mtk` (tc-based + `mtkhqos_util`) |
| Congestion control | BBR (module + default) |
| Proxy acceleration | `kmod-cryptodev` + `kmod-tls` (EIP-197) |
| OpenClash | `vernesong/OpenClash` master |
| QModem | `FUjr/QModem` main, `luci-app-qmodem-next` |

## What is selected

On top of the base defconfig (`mt7987_mt7992.config`), `config/h5000m.config`
adds:

1. **Closed stack reaffirmed**: mt_wifi7, mediatek_hnat, mtk_wed, warp,
   turboacc-mtk, mtwifi-cfg, eqos-mtk
2. **Optimizations**: BBR as default congestion control, cryptodev + kTLS,
   `KPROBES` (prerequisite for the USB/WWAN headroom fix, see below)
3. **User packages**: `h5000m-fancontrol` (local PWM fan daemon),
   OpenClash, `luci-app-qmodem-next` + QMI data path for the
   user-swappable 5G module (Fibocom FM170 / Quectel / …)

Deliberately **not** selected (device profile defaults overridden):
`luci-app-modem`, `quectel-CM-5G`, `sms-tool` (QModem owns the modem),
`luci-app-Airpifanctrl` (single PWM writer rule: `h5000m-fancontrol`
instead), open `mt76` Wi-Fi, SFE TurboACC.

## Patch audit

| Patch | Purpose | Status |
|---|---|---|
| `970-pwm-fan-boot-duty.patch` | `pwm-fan` driver: optional `pwm-fan,boot-duty` DTS property instead of 100% at probe | Ported to 6.6 (probe logic identical) |
| `971-hwmon-pwmfan-boot-autoload.patch` | Load `pwm-fan` in the early module pass on mediatek targets | Kept |
| `972-h5000m-fan-boot-duty.patch` | H5000M DTS: `pwm-fan,boot-duty = <89>` (~35%) | Kept |
| `973-hnat-wwan-whitelist.patch` | hnat node: `ext-devices-prefix = "wwan"` so USB WWAN can be offloaded | New (whitepaper recipe) |
| `mtk-hnat-local-dest.patch` | Never offload flows destined to the router itself (fixes LuCI access) | From upstream existyay |
| `mtwifi-apcli-active-only.patch` | mtwifi APCLI active-only fix | From upstream existyay |

## USB / WWAN hardware acceleration

The HNAT whitelist (973) lets `wwan0` flows enter the HNAT path. The
`qmi_fix_skb.ko` headroom fix (KPROBES-based, from the H5000M HNAT whitepaper)
is **not** in the 6.6 base tree and still needs to be ported; `KPROBES` is
already enabled so the module can be dropped in without a kernel rebuild.
Verify with `/sys/kernel/debug/hnat/hnat_stats`: a BIND entry with
`bytes > 0` for the wwan path means true offload.

## Fan control and startup handover

Patches 970–972 are the same narrowly-scoped fan work as before: the
`pwm-fan` driver no longer probes at 100% thanks to the `boot-duty`
property, the module loads early, and the local `h5000m-fancontrol`
package (init priority 15) applies the temperature curve. Stock thermal
cooling levels and trip points are unchanged.

## Reproducibility

The base moves as a branch upstream; this build pins it to
`30fbc1d6deba23c0e850185021e9ee42214925eb` and asserts the checkout.
Feeds track the branches the base was tested against
(`openwrt-24.10` + nikki + qmodem). `scripts/verify-config.sh` audits
source identity, the closed stack, the optimizations and the patch
inventory before every compile, and the workflow reverse-audits the
final image.
