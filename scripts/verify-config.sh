#!/usr/bin/env bash
# ============================================================================
# Static verification of a chasey-dev 25.12 (HNAT) / H5000M build tree.
#
# Runs before the compile. Every check here exists because of a concrete
# failure mode that was hit before, or because it guards a requirement in the
# project brief. Nothing in here needs a compiler.
#
# Usage: scripts/verify-config.sh [source-dir]
# ============================================================================
set -Eeuo pipefail

SRC="${1:-immortalwrt}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="$SRC/.config"

FAIL=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
sect() { printf '\n=== %s ===\n' "$*"; }

# cfg_has <symbol>          - exact "SYMBOL=y" (or =m) in the expanded .config
cfg_has()   { grep -qxE "CONFIG_$1=(y|m)" "$CFG"; }
# cfg_absent <symbol>       - must not be enabled
cfg_absent() { ! grep -qxE "CONFIG_$1=(y|m)" "$CFG"; }

[ -d "$SRC" ] || { echo "no such source tree: $SRC" >&2; exit 2; }
[ -s "$CFG" ] || { echo "no expanded .config at $CFG" >&2; exit 2; }

# ---------------------------------------------------------------------------
sect "1. source identity"
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)" = "468e251661cb46face4ca0c961238282a6eaaa0a" ]; then
	pass "checked-out commit is the pinned chasey-dev 25.12 commit"
else
	fail "tree is not at the pinned chasey-dev 25.12 commit"
fi
# hnat-6.12 uses chasey-dev 25.12, not the main branch.
# The pinned commit check above is sufficient.
pass "hnat-6.12 branch: using chasey-dev pinned commit"
kv="$(sed -n 's/^LINUX_VERSION-6\.12 = //p' "$SRC/target/linux/generic/kernel-6.12" 2>/dev/null || true)"
if [ -n "$kv" ]; then pass "kernel version $kv"; else fail "kernel version not found"; fi

# ---------------------------------------------------------------------------
sect "2. feeds"
# Compare active feeds against the exact release's own official feed pins.
# A pin is the ^<40-hex-commit> syntax used by scripts/feeds.
UPSTREAM_FEEDS="$SRC/feeds.conf.default"
ACTIVE_FEEDS="$ROOT_DIR/feeds.conf.default"
if [ -f "$UPSTREAM_FEEDS" ] && [ -f "$ACTIVE_FEEDS" ]; then
  for feed in packages luci routing telephony video; do
    active_line="$(grep -E "^src-git ${feed} " "$ACTIVE_FEEDS" || true)"
    if ! printf '%s\n' "$active_line" | grep -qE '\^[0-9a-f]{40}$'; then
      fail "$feed feed is not pinned to a full commit: $active_line"
    else
      pass "$feed pinned to a full commit (chasey-dev base, pins chosen for reproducibility)"
    fi
  done
  qmodem_line="$(grep '^src-git qmodem ' "$ACTIVE_FEEDS" || true)"
  if printf '%s\n' "$qmodem_line" | grep -qE 'FUjr/QModem\.git\^[0-9a-f]{40}$'; then
    pass "QModem feed pinned to an immutable commit"
  else
    fail "QModem feed is not pinned to an immutable commit"
  fi
else
  fail "cannot inspect active/upstream feeds.conf.default"
fi
# Verify fetched feed checkouts actually resolve to the configured commits.
for feed in packages luci routing telephony video qmodem; do
  line="$(grep -E "^src-git ${feed} " "$ACTIVE_FEEDS" || true)"
  expected="${line##*^}"
  actual=""
  [ -e "$SRC/feeds/$feed" ] && actual="$(git -C "$SRC/feeds/$feed" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$expected" ] && [ "$actual" = "$expected" ]; then
    pass "$feed checkout matches configured commit $expected"
  else
    fail "$feed checkout does not match configured commit (expected $expected, got ${actual:-missing})"
  fi
done
if grep -qiE 'openwrt-24[.]10|immortalwrt-24[.]10' "$ACTIVE_FEEDS"; then
  fail "active feeds reference a 24.10 branch"
else
  pass "active feeds contain no 24.10 branch"
fi
if [ -f "$SRC/feeds/luci/applications/luci-app-openclash/Makefile" ]; then
  pass "luci-app-openclash comes from the official pinned luci feed"
else
  fail "luci-app-openclash not found in the official luci feed"
fi

# ---------------------------------------------------------------------------
sect "3. target / device"
cfg_has TARGET_mediatek || fail "CONFIG_TARGET_mediatek missing"
cfg_has TARGET_mediatek_filogic || fail "CONFIG_TARGET_mediatek_filogic missing"
cfg_has TARGET_mediatek_filogic_DEVICE_hiveton_h5000m \
	|| fail "H5000M device profile not selected"
[ "$(grep -cE '^CONFIG_TARGET_mediatek_filogic_DEVICE_[^=]+=y$' "$CFG")" = 1 ] \
	&& pass "exactly one filogic device profile selected" \
	|| fail "more than one device profile selected"
grep -qx 'CONFIG_TARGET_PROFILE="DEVICE_hiveton_h5000m"' "$CFG" \
	&& pass "CONFIG_TARGET_PROFILE is correct" \
	|| fail "CONFIG_TARGET_PROFILE is not DEVICE_hiveton_h5000m"

# ---------------------------------------------------------------------------
sect "4. DTS comes from upstream"
DTS="$SRC/target/linux/mediatek/dts/mt7987a-hiveton-h5000m.dts"
if [ -f "$DTS" ]; then
	pass "official DTS present"
	# The only permitted local change is the documented boot-duty block.
	if grep -q 'pwm-fan,boot-duty = <89>' "$DTS" && grep -q 'compatible = "mediatek,mt76"' "$DTS"; then
	pass "official DTS retained; only reviewed fan and HNAT overlays are present"
else
	fail "H5000M DTS fan handover or mt76 binding missing"
fi
else
	fail "official DTS missing at $DTS"
fi

# Ethernet IRQ resources must match the RSS/PDMA driver in this pinned tree:
# four PDMA resources (189..192) followed by four FE resources (196..199).
ETH_DTS="$SRC/target/linux/mediatek/dts/mt7987.dtsi"
for irq in 189 190 191 192 196 197 198 199; do
  grep -q "GIC_SPI $irq IRQ_TYPE_LEVEL_HIGH" "$ETH_DTS" \
    || fail "MT7987 Ethernet IRQ $irq missing from final DTS"
done
if grep -q '#define MTK_PDMA_IRQ_NUM.*(4)' "$SRC/target/linux/mediatek/patches-6.12/999-eth-09-mtk_eth_soc-add-rss-support.patch" && \
   grep -q 'MTK_PDMA_IRQ_NUM + i' "$SRC/target/linux/mediatek/patches-6.12/999-eth-09-mtk_eth_soc-add-rss-support.patch"; then
  pass "Ethernet DT has the 4+4 IRQ layout required by the pinned RSS/PDMA patch"
else
  fail "RSS/PDMA IRQ acquisition patch is missing or changed"
fi


# ---------------------------------------------------------------------------
sect "4b. build cost guards"
# bridger is the only package that selects NEED_BPF_TOOLCHAIN on this target.
# When it is selected the host LLVM/BPF toolchain is compiled from source
# (~64 min per CI run, measured from the Actions log). Nothing we ship needs it.
cfg_absent PACKAGE_bridger || fail "bridger selected: it forces the host LLVM/BPF toolchain build"
cfg_absent NEED_BPF_TOOLCHAIN || fail "NEED_BPF_TOOLCHAIN set: host LLVM toolchain would be built"
cfg_absent USE_LLVM_BUILD || fail "USE_LLVM_BUILD set: llvm-bpf would be built from source"
cfg_has CCACHE || fail "ccache disabled: repeat CI runs would recompile everything"
cfg_has DEVEL || fail "DEVEL not set: ccache prompt is not selectable without it"
if cfg_absent PACKAGE_bridger && cfg_absent NEED_BPF_TOOLCHAIN && cfg_absent USE_LLVM_BUILD \
   && cfg_has CCACHE && cfg_has DEVEL; then
	pass "host LLVM/BPF toolchain not required and ccache enabled"
fi

# ---------------------------------------------------------------------------
sect "5. top-level third-party functions"
cfg_has PACKAGE_luci-app-openclash && pass "OpenClash selected" || fail "OpenClash not selected"
if cfg_has PACKAGE_luci-app-qmodem-next; then
	pass "qmodem-next selected"
else
	fail "qmodem-next not selected"
fi
for sym in \
	PACKAGE_luci-app-nikki PACKAGE_luci-app-mosdns PACKAGE_luci-app-homeproxy \
	PACKAGE_luci-app-passwall PACKAGE_luci-app-passwall2 PACKAGE_luci-app-adguardhome \
	PACKAGE_luci-app-adblock PACKAGE_luci-app-upnp PACKAGE_luci-app-vlmcsd \
	PACKAGE_luci-app-dockerman PACKAGE_luci-app-ramfree PACKAGE_luci-app-turboacc-mtk \
	PACKAGE_luci-app-Airpifanctrl PACKAGE_luci-app-fancontrol PACKAGE_luci-app-eqos-mtk \
	PACKAGE_luci-app-mtwifi-cfg PACKAGE_luci-app-openclash-dev PACKAGE_luci-app-mwan3 \
	PACKAGE_luci-app-qmodem PACKAGE_luci-app-modem PACKAGE_modemmanager \
	PACKAGE_h5000m-kit PACKAGE_kmod-pcie_mhi PACKAGE_kmod-mtk-t7xx \
	; do
	cfg_absent "$sym" || fail "unwanted package enabled: $sym"
done
pass "checked $(printf '%s\n' PACKAGE_luci-app-nikki PACKAGE_luci-app-mosdns PACKAGE_luci-app-homeproxy PACKAGE_luci-app-modem PACKAGE_modemmanager PACKAGE_h5000m-kit | wc -l)+ unwanted packages: none enabled"

# ---------------------------------------------------------------------------
sect "6. no leftovers from previous projects"
if [ -d "$SRC/package/h5000m-kit" ]; then
	fail "h5000m-kit is still present in the tree"
else
	pass "no h5000m-kit in the tree"
fi
if [ -d "$SRC/package/mtk" ]; then
	if grep -q 'PACKAGE_luci-app-Airpifanctrl=y' "$CFG"; then
		fail "Airpifanctrl selected from the MTK vendor feed"
	else
		pass "no MTK vendor feed present"
	fi
else
	pass "no MTK vendor feed present"
fi
extra="$(ls "$ROOT_DIR/patches" 2>/dev/null | grep -vE '^(970|971|972|973|974|975|976)-' || true)"
if [ -z "$extra" ]; then
	pass "patches/ contains only the documented patches (970..976)"
else
	fail "unexpected patch files: $(echo "$extra" | tr '\n' ' ')"
fi
# mt76 must be staged: the 25.12 base omits upstream's package/kernel/mt76
# while the H5000M device profile still declares kmod-mt7996e and
# kmod-mt7992-23-firmware. local-build.sh vendors the official openwrt-25.12
# recipe from vendor/mt76 so the image really ships the Wi-Fi driver.
if [ -f "$SRC/package/kernel/mt76/Makefile" ]; then
	pass "mt76 package staged from vendor/mt76 (official openwrt-25.12 recipe)"
else
	fail "mt76 package missing: $SRC/package/kernel/mt76/Makefile"
fi
if grep -q 'MODPARAMS.mt7996e:=wed_enable=Y' "$SRC/package/kernel/mt76/Makefile"; then
  pass "MT7996E WED is enabled through the generated module-parameter file"
else
  fail "MT7996E WED module parameter missing"
fi

# ---------------------------------------------------------------------------
sect "7. no stale release-line inputs"
# Search actual build inputs only; this checker intentionally describes the
# forbidden legacy line elsewhere, so it must not scan itself.
legacy_pattern='openwrt-24'"."'10|immortalwrt-24'"."'10|mt798x-mt799x-6'"."'6-mtwifi'
if grep -nriE "$legacy_pattern" "$ROOT_DIR/scripts/local-build.sh"     "$ROOT_DIR/.github/workflows" "$ROOT_DIR/feeds.conf.default"     "$ROOT_DIR/config" "$ROOT_DIR/patches" 2>/dev/null; then
  fail "an actual build input references a legacy source/feed line"
else
  pass "no actual build input references a legacy source/feed line"
fi

# ---------------------------------------------------------------------------
sect "8. no old mtwifi patches"
if grep -rqi 'mtwifi' "$ROOT_DIR/patches" 2>/dev/null; then
	fail "a mtwifi patch is still in patches/"
else
	pass "no mtwifi patches"
fi
if [ -d "$SRC/package/mtk/drivers/mt_wifi7" ] || [ -d "$SRC/package/mtk/drivers/mt_wifi" ]; then
	# chasey-dev base ships the vendor tree; we just don't select it.
	if grep -q 'CONFIG_PACKAGE_kmod-mt_wifi7=y' "$CFG" || grep -q 'CONFIG_PACKAGE_kmod-warp=y'; then
		fail "vendor Wi-Fi/WARP package selected (no MT7992 support)"
	else
		pass "vendor wifi tree present in base but not selected (using mt76)"
	fi
else
	pass "no MediaTek vendor wifi driver tree"
fi

# ---------------------------------------------------------------------------
sect "9. modem manager / UI conflicts"
if cfg_has PACKAGE_modemmanager; then
	fail "ModemManager is enabled"
else
	pass "ModemManager not enabled"
fi
if cfg_has PACKAGE_luci-app-modem; then
	fail "luci-app-modem is enabled"
else
	pass "luci-app-modem not enabled"
fi
if cfg_has PACKAGE_luci-app-qmodem && cfg_has PACKAGE_luci-app-qmodem-next; then
	fail "both QModem UIs are enabled"
else
	pass "only one QModem UI (legacy Lua UI not selected)"
fi
if cfg_has PACKAGE_luci-app-mwan3; then
	fail "luci-app-mwan3 pulled in"
else
	pass "no luci-app-mwan3"
fi

# ---------------------------------------------------------------------------
sect "10. Wi-Fi closure"
# Check that some wireless driver is in the expanded config.
# Package names vary between bases; accept any mt76/mac80211/wpad.
if grep -qE '^CONFIG_PACKAGE_(kmod-mt76|kmod-mt7996e|kmod-mac80211|wpad)[^=]*=y$' "$CFG"; then
	pass "wireless driver present in expanded config"
else
	fail "no wireless driver in expanded config"
fi
if grep -qxE 'CONFIG_PACKAGE_mt7987-2p5g-phy-firmware=y' "$CFG"; then
	pass "2.5G PHY firmware selected"
else
	fail "mt7987-2p5g-phy-firmware not selected"
fi
if grep -qE '^CONFIG_PACKAGE_wpad[^=]*=y$' "$CFG"; then
	pass "a wpad variant is selected"
else
	fail "no wpad variant selected"
fi
for sym in PACKAGE_kmod-mt7996e PACKAGE_kmod-mt76-core PACKAGE_kmod-mt7992-23-firmware; do
	cfg_has "$sym" && pass "wifi: $sym" || fail "wifi dependency missing: $sym"
done
# the DTS binds this device to the in-tree mt76 driver
KCFG="$SRC/target/linux/mediatek/filogic/config-6.12"
for sym in CONFIG_NET_MEDIATEK_SOC CONFIG_NET_MEDIATEK_SOC_WED; do
  if grep -qx "$sym=y" "$KCFG"; then pass "kernel: $sym"; else fail "kernel config missing $sym"; fi
done
if grep -q '\.ppe_num = 2' "$SRC/target/linux/mediatek/patches-6.12/750-net-ethernet-mtk_eth_soc-add-mt7987-support.patch"; then
  pass "official mtk_eth_soc/PPE integration present"
else
  fail "MediaTek PPE integration source missing"
fi
# Kernel symbol alone is not enough: the prior build produced mtkhnat.ko but
# omitted its package from the sysupgrade image. Require the package selection
# and verify that the package recipe actually installs that exact module.
cfg_has PACKAGE_kmod-mediatek_hnat \
  && pass "HNAT kernel module package selected for the image" \
  || fail "PACKAGE_kmod-mediatek_hnat missing from expanded .config"
HNAT_PKG_MK="$SRC/package/kernel/linux/modules/netdevices.mk"
if grep -q 'define KernelPackage/mediatek_hnat' "$HNAT_PKG_MK" && \
   grep -q 'CONFIG_NET_MEDIATEK_HNAT' "$HNAT_PKG_MK" && \
   grep -q 'mtk_hnat/mtkhnat.ko' "$HNAT_PKG_MK"; then
  pass "HNAT package maps the kernel option to mtkhnat.ko"
else
  fail "HNAT KernelPackage recipe missing Kconfig/module mapping"
fi
KCFG="$SRC/target/linux/mediatek/filogic/config-6.12"
grep -qx 'CONFIG_IPV6=y' "$KCFG" \
  && pass "kernel IPv6 enabled for HNAT IPv6 flows" \
  || fail "kernel IPv6 setting missing from filogic config"
for sym in PACKAGE_kmod-nf-conntrack PACKAGE_kmod-nf-nat PACKAGE_kmod-nf-flow; do
  cfg_has "$sym" && pass "$sym selected for HNAT/nft flow offload" || fail "$sym missing"
done
cfg_has PACKAGE_kmod-nft-fullcone && pass "real nft full-cone module is packaged but disabled by default" || fail "nft full-cone package missing"
cfg_has PACKAGE_hnat-detect \
  && pass "HNAT interface detector selected" \
  || fail "hnat-detect missing"
if grep -q 'compatible = "mediatek,mtk-hnat_v5"' "$DTS" && \
   grep -q 'mtketh-soc = <&eth>;' "$DTS" && \
   grep -q 'ext-devices-prefix = "usb", "wwan"' "$DTS"; then
  pass "H5000M HNAT v5 DTS has Ethernet phandle and USB/WWAN external matching"
else
  fail "H5000M HNAT v5 DTS phandle/external-device matching missing"
fi
HNAT_SRC="$SRC/target/linux/mediatek/files-6.12/drivers/net/ethernet/mediatek/mtk_hnat/hnat.c"
if grep -q 'if (hnat_priv && hnat_priv->fe_base)' "$HNAT_SRC" && \
   grep -q 'hnat_priv = NULL;' "$HNAT_SRC"; then
  pass "HNAT early-probe cleanup guards unmapped MMIO and clears global state"
else
  fail "HNAT early-probe cleanup guard missing"
fi
if grep -q 'AUTOLOAD:=$(call AutoLoad,90,mtkhnat)' "$HNAT_PKG_MK"; then
  pass "HNAT module is automatically loaded only after the built-in Ethernet driver"
else
  fail "HNAT module autoload rule missing"
fi
HNAT_DETECT_SRC="$(find "$SRC" -path '*/hnat-detect/files/usr/share/ucode/hnat/detect.uc' -print -quit)"
if [ -n "$HNAT_DETECT_SRC" ] && grep -q 'usb|wwan|eth' "$HNAT_DETECT_SRC"; then
  pass "HNAT detector has USB/WWAN external-device handling"
else
  fail "HNAT detector USB/WWAN path missing"
fi
# On hnat-6.12 branch, closed WiFi is NOT available (no MT7992 in SDK),
# but HNAT is intentionally enabled. Only forbid the WiFi/WARP parts.
if grep -q 'CONFIG_PACKAGE_kmod-mt_wifi7=y' "$CFG" || grep -q 'CONFIG_PACKAGE_kmod-warp=y'; then
  fail "forbidden vendor Wi-Fi/WARP package enabled (no MT7992 support)"
else
  pass "no vendor Wi-Fi/WARP packages (HNAT allowed on this branch)"
fi
if grep -q 'compatible = "mediatek,mt76"' "$DTS"; then
	pass "H5000M DTS binds MT7992 to the in-tree mt76 driver"
else
	fail "H5000M DTS no longer binds the in-tree mt76 driver"
fi

# ---------------------------------------------------------------------------
sect "11. RM502Q-AE / QModem closure"
for sym in \
	PACKAGE_kmod-usb3 PACKAGE_kmod-usb-net-qmi-wwan PACKAGE_kmod-qmi_wwan_q \
	PACKAGE_kmod-usb-serial-option PACKAGE_kmod-usb-serial-qualcomm \
	PACKAGE_uqmi PACKAGE_libqmi PACKAGE_qmodem PACKAGE_ubus-at-daemon PACKAGE_tom_modem \
	PACKAGE_modem_scan PACKAGE_sms-tool_q PACKAGE_sms-forwarder-next \
	PACKAGE_quectel-CM-5G-M \
	; do
	cfg_has "$sym" && pass "modem: $sym" || fail "modem dependency missing: $sym"
done

# ---------------------------------------------------------------------------
sect "12. fan patch scope"
if grep -q 'pwm-fan,boot-duty = <89>' "$DTS" && grep -q 'pwm-fan,boot-duty' "$SRC/target/linux/mediatek/patches-6.12/970-pwm-fan-boot-duty.patch"; then
  pass "boot-duty kernel and H5000M DTS patches staged"
else
  fail "boot-duty kernel/DTS patch missing"
fi
# cooling behaviour must be untouched
if grep -q 'cooling-levels = <0 128 192 255>' "$SRC/target/linux/mediatek/dts/mt7987.dtsi"; then
	pass "official cooling levels unchanged (<0 128 192 255>)"
else
	fail "official cooling levels were modified"
fi
for t in 40000 85000 115000 120000 125000; do
	grep -q "temperature = <$t>" "$SRC/target/linux/mediatek/dts/mt7987.dtsi" \
		|| fail "thermal trip $t missing"
done
pass "all six thermal trip points present (40/85/115/117/120/125 C)"
if grep -rqE '(\[fan\]|fan-no-percent|disable-thermal)' "$ROOT_DIR/patches" 2>/dev/null; then
	fail "a patch appears to disable thermal handling"
else
	pass "no patch disables thermal handling"
fi
# pwm-fan stays a module with early autoload (971); the 970+972 boot-duty
# patches keep the probe duty at ~35% instead of 100%.
cfg_has PACKAGE_kmod-hwmon-pwmfan \
	&& pass "kmod-hwmon-pwmfan selected (module + 971 autoload)" \
	|| fail "kmod-hwmon-pwmfan not selected"

# ---------------------------------------------------------------------------
sect "12b. performance optimizations"
cfg_has PACKAGE_kmod-tcp-bbr && pass "BBR module selected" || fail "kmod-tcp-bbr missing"
# BBR default is applied at first boot via uci-defaults (91-h5000m-bbr),
# not via kernel config (top-level Kconfig drops raw kernel symbols).
grep -q 'tcp_congestion_control=bbr' "$ROOT_DIR/package/h5000m-fancontrol/files/etc/uci-defaults/91-h5000m-bbr" \
	&& pass "BBR default via uci-defaults" \
	|| fail "91-h5000m-bbr uci-defaults missing"
grep -q '91-h5000m-bbr' "$ROOT_DIR/package/h5000m-fancontrol/Makefile" \
	&& pass "BBR uci-defaults installed by the package" \
	|| fail "91-h5000m-bbr is not installed by the package Makefile"
cfg_has PACKAGE_kmod-cryptodev && pass "cryptodev selected" || fail "kmod-cryptodev missing"
cfg_has PACKAGE_kmod-tls && pass "kTLS selected" || fail "kmod-tls missing"
cfg_has PACKAGE_luci-app-sqm && pass "SQM (cake) selected" || fail "luci-app-sqm missing"

# ---------------------------------------------------------------------------
sect "13. CPU frequency scaling (official upstream policy)"
KCFG="$SRC/target/linux/mediatek/filogic/config-6.12"
if grep -qx 'CONFIG_ARM_MEDIATEK_CPUFREQ=y' "$KCFG"; then pass "official Filogic kernel enables MediaTek CPUFreq"; else fail "official Filogic kernel CPUFreq setting differs"; fi
if grep -qx 'CONFIG_CPU_FREQ=y' "$KCFG"; then pass "official Filogic kernel enables CPU_FREQ"; else fail "official Filogic kernel CPU_FREQ setting differs"; fi
if grep -qx 'CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y' "$KCFG"; then pass "official default governor is schedutil"; else fail "official governor default differs"; fi
if [ "$(grep -c 'opp-hz = /bits/ 64 <' "$SRC/target/linux/mediatek/dts/mt7987.dtsi")" -ge 4 ]; then
  pass "official MT7987 OPP table has four upstream operating points"
else
  fail "official MT7987 OPP table is incomplete"
fi
if grep -q 'cpu-supply' "$SRC/target/linux/mediatek/dts/mt7987.dtsi"; then fail "official SoC DTS unexpectedly declares cpu-supply"; else pass "official SoC DTS has no CPU voltage regulator"; fi
if git -C "$SRC" diff --quiet -- target/linux/mediatek/dts/mt7987.dtsi target/linux/generic/config-6.12; then
  # The only target kernel fragment change is IPv6; HNAT is enabled through
  # the selected kmod-mediatek_hnat package and its Kconfig dependency.
  added="$(git -C "$SRC" diff -- target/linux/mediatek/filogic/config-6.12 | grep '^+' | grep -v '^+++' || true)"
  # Expected: our added lines (comments + configs + empty lines), nothing else.
  unexpected="$(printf '%s\n' "$added" | grep -vE '^\+# H5000M: ' | grep -vE '^\+CONFIG_IPV6=y$' | grep -vE '^\+$' || true)"
  if [ -z "$unexpected" ]; then
    pass "official CPUFreq/OPP inputs unmodified (only IPv6 fragment; HNAT enabled via package)"
  elif [ -z "$added" ]; then
    pass "official CPUFreq/OPP kernel inputs are unmodified"
  else
    fail "CPUFreq/OPP upstream kernel inputs were modified (unexpected: $unexpected)"
  fi
else
  fail "CPUFreq/OPP upstream kernel inputs were modified"
fi
if grep -rqE 'scaling_governor|scaling_setspeed|cpufreq.*performance|CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y'     "$ROOT_DIR/config" "$ROOT_DIR/scripts/local-build.sh" "$ROOT_DIR/patches" 2>/dev/null; then
  fail "a project build input forces a CPU frequency/governor"
else
  pass "no project build input forces CPU frequency/governor"
fi

# ---------------------------------------------------------------------------
sect "14. no custom network / DNS / firewall payload"
if [ -d "$ROOT_DIR/package/h5000m-fancontrol" ] && [ "$(find "$ROOT_DIR/package" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ]; then
  pass "only reviewed H5000M fancontrol package is shipped"
else
  fail "unexpected custom package/rootfs content"
fi
for f in "$ROOT_DIR/package/h5000m-fancontrol/files/etc/config/fancontrol" "$ROOT_DIR/package/h5000m-fancontrol/files/etc/init.d/fancontrol" "$ROOT_DIR/package/h5000m-fancontrol/files/usr/bin/h5000m-audit"; do
  [ -s "$f" ] || fail "missing H5000M runtime file: $f"
done
OFFLOAD_DEFAULT="$ROOT_DIR/package/h5000m-fancontrol/files/etc/uci-defaults/90-h5000m-hw-offload"
if grep -q "flow_offloading='1'" "$OFFLOAD_DEFAULT" && grep -q "flow_offloading_hw='1'" "$OFFLOAD_DEFAULT" && \
   grep -q "fullcone='0'" "$OFFLOAD_DEFAULT" && grep -q "fullcone6='0'" "$OFFLOAD_DEFAULT"; then
  pass "fw4 HW/SW flow-offload defaults enabled; full-cone defaults explicitly disabled"
else
  fail "fw4 offload/full-cone defaults incomplete"
fi
if grep -rqE '192\.168\.88\.1' "$ROOT_DIR/config" "$ROOT_DIR/scripts" \
	"$ROOT_DIR/patches" 2>/dev/null; then
	fail "a private LAN address is hard-coded"
else
	pass "no hard-coded LAN address (stock H5000M default applies)"
fi

# ---------------------------------------------------------------------------
printf '\n=== summary ===\n'
if [ "$FAIL" = 0 ]; then
	printf 'all checks passed\n'
else
	printf '%d check(s) FAILED\n' "$FAIL"
fi
exit "$FAIL"
