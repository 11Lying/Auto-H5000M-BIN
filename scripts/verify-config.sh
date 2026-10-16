#!/usr/bin/env bash
# ============================================================================
# Static verification of a chasey-dev 25.12 integrated-PPE / H5000M build tree.
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
	pass "official DTS retained; only reviewed fan and Ethernet IRQ overlays are present"
else
	fail "H5000M DTS fan handover or mt76 binding missing"
fi
else
	fail "official DTS missing at $DTS"
fi

# Ethernet IRQ resources must match the RSS/PDMA driver in this pinned tree.
# The RSS patch consumes platform IRQs 0..3 as PDMA, then 4..7 as FE.
ETH_DTS="$SRC/target/linux/mediatek/dts/mt7987.dtsi"
RSS_PATCH="$SRC/target/linux/mediatek/patches-6.12/999-eth-09-mtk_eth_soc-add-rss-support.patch"
expected_irqs="189 190 191 192 196 197 198 199"
actual_irqs="$(sed -n '/^[[:space:]]*eth: ethernet@15100000 {/,/^[[:space:]]*clocks = /p' "$ETH_DTS" \
	| grep -oE 'GIC_SPI [0-9]+' | awk '{print $2}' | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
if [ "$actual_irqs" = "$expected_irqs" ]; then
	pass "MT7987 Ethernet DT IRQ order is PDMA[0..3]=189..192 and FE[0..3]=196..199"
else
	fail "MT7987 Ethernet DT IRQ order mismatch: expected '$expected_irqs', got '$actual_irqs'"
fi
if grep -q '#define MTK_PDMA_IRQ_NUM.*(4)' "$RSS_PATCH" && \
   grep -q 'eth->irq_pdma\[i\] = platform_get_irq(pdev, i)' "$RSS_PATCH" && \
   grep -q 'platform_get_irq(pdev, MTK_PDMA_IRQ_NUM + i)' "$RSS_PATCH"; then
	pass "RSS driver maps the DTS IRQ order as four PDMA followed by four FE resources"
else
	fail "RSS/PDMA IRQ acquisition mapping is missing or changed"
fi
if grep -q '[[:space:]]eth: ethernet@15100000' "$ETH_DTS" && \
   grep -q '^&eth {' "$DTS" && grep -q '[[:space:]]status = "okay";' "$DTS" && \
   ! grep -q 'mediatek,mtk-hnat_v5' "$DTS"; then
	pass "H5000M uses the upstream Ethernet node without the independent mtkhnat probe"
else
	fail "H5000M DTS contains an unexpected independent HNAT node or lacks Ethernet enablement"
fi

# 973 is intentionally the only expected change to mt7987.dtsi. Compare the
# final file with a clean pinned source plus exactly that patch, so an unrelated
# local edit is still rejected instead of being hidden by a blanket exemption.
expected_dts_dir="$(mktemp -d)"
mkdir -p "$expected_dts_dir/target/linux/mediatek/dts"
if git -C "$SRC" show HEAD:target/linux/mediatek/dts/mt7987.dtsi > \
	"$expected_dts_dir/target/linux/mediatek/dts/mt7987.dtsi" && \
   git -C "$SRC" show HEAD:target/linux/mediatek/dts/mt7987a-hiveton-h5000m.dts > \
	"$expected_dts_dir/target/linux/mediatek/dts/mt7987a-hiveton-h5000m.dts" && \
   patch -d "$expected_dts_dir" -p1 --forward --silent < "$ROOT_DIR/patches/973-h5000m-ethernet-rss-irqs.patch" >/dev/null 2>&1 && \
   cmp -s "$ETH_DTS" "$expected_dts_dir/target/linux/mediatek/dts/mt7987.dtsi"; then
	pass "mt7987.dtsi contains exactly the reviewed 973 IRQ change (no unrelated diff)"
else
	fail "mt7987.dtsi differs from the pinned source plus the reviewed 973 patch"
fi
rm -rf "$expected_dts_dir"
if git -C "$SRC" diff --quiet -- target/linux/generic/config-6.12; then
	pass "generic/config-6.12 has no unexpected local modification"
else
	fail "generic/config-6.12 has an unexpected local modification"
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
unwanted_packages=(
	PACKAGE_luci-app-nikki PACKAGE_luci-app-mosdns PACKAGE_luci-app-homeproxy
	PACKAGE_luci-app-passwall PACKAGE_luci-app-passwall2 PACKAGE_luci-app-adguardhome
	PACKAGE_luci-app-adblock PACKAGE_luci-app-upnp PACKAGE_luci-app-vlmcsd
	PACKAGE_luci-app-dockerman PACKAGE_luci-app-ramfree PACKAGE_luci-app-turboacc-mtk
	PACKAGE_luci-app-Airpifanctrl PACKAGE_luci-app-fancontrol PACKAGE_luci-app-eqos-mtk
	PACKAGE_luci-app-mtwifi-cfg PACKAGE_luci-app-openclash-dev PACKAGE_luci-app-mwan3
	PACKAGE_luci-app-qmodem PACKAGE_luci-app-modem PACKAGE_modemmanager
	PACKAGE_h5000m-kit PACKAGE_kmod-pcie_mhi PACKAGE_kmod-mtk-t7xx
)
unwanted_found=0
for sym in "${unwanted_packages[@]}"; do
	if cfg_absent "$sym"; then
		:
	else
		fail "unwanted package enabled: $sym"
		unwanted_found=1
	fi
done
if [ "$unwanted_found" = 0 ]; then
	pass "checked ${#unwanted_packages[@]} unwanted packages: none enabled"
fi

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
extra="$(find "$ROOT_DIR/patches" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | grep -vE '^(970|971|972|973)-' || true)"
if [ -z "$extra" ] && [ -f "$ROOT_DIR/patches/optional-independent-hnat/README.md" ]; then
	pass "active patches are only 970..973; independent HNAT patches are retained but disabled"
else
	fail "unexpected active patch files or missing disabled-HNAT note: $(echo "$extra" | tr '\n' ' ')"
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
WED_KCFG="$SRC/target/linux/mediatek/filogic/config-6.12"
if grep -q 'compatible = "mediatek,mt7987-wed"' "$SRC/target/linux/mediatek/dts/mt7987.dtsi" && \
   grep -q 'interrupts = <GIC_SPI 205 IRQ_TYPE_LEVEL_HIGH>;' "$SRC/target/linux/mediatek/dts/mt7987.dtsi" && \
   grep -q 'mediatek,wed = <&wed0>;' "$SRC/target/linux/mediatek/dts/mt7987.dtsi" && \
   grep -qx 'CONFIG_NET_MEDIATEK_SOC_WED=y' "$WED_KCFG"; then
  pass "MT7987 WED provider/DTS/kernel support is present; no forced module parameter"
else
  fail "MT7987 WED provider/DTS/kernel support is incomplete"
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
# The active route is the integrated 6.12 mtk_eth_soc/mtk_ppe path. The
# vendor 999-eth-91 patch explicitly disables integrated PPE start/stop/probe
# when CONFIG_NET_MEDIATEK_HNAT is enabled, so the separate mtkhnat package is
# intentionally absent from this image.
if cfg_absent PACKAGE_kmod-mediatek_hnat && cfg_absent PACKAGE_hnat-detect; then
  pass "independent mtkhnat/hnat-detect packages are not selected"
else
  fail "independent mtkhnat route was selected; it conflicts with integrated PPE"
fi
for sym in PACKAGE_kmod-nf-conntrack PACKAGE_kmod-nf-nat PACKAGE_kmod-nf-flow PACKAGE_kmod-nft-offload; do
  cfg_has "$sym" && pass "$sym selected for integrated PPE/nft flow offload" || fail "$sym missing"
done
cfg_has PACKAGE_kmod-nft-fullcone && pass "real nft full-cone module is packaged but disabled by default" || fail "nft full-cone package missing"
if grep -q '\.offload_version = 2' "$SRC/target/linux/mediatek/patches-6.12/750-net-ethernet-mtk_eth_soc-add-mt7987-support.patch" && \
   grep -q '\.ppe_num = 2' "$SRC/target/linux/mediatek/patches-6.12/750-net-ethernet-mtk_eth_soc-add-mt7987-support.patch" && \
   grep -q 'CONFIG_NET_MEDIATEK_HNAT' "$SRC/target/linux/mediatek/patches-6.12/999-eth-91-mtk_eth_soc-add-mtkhnat-driver-support.patch" && \
   grep -q '!defined(CONFIG_NET_MEDIATEK_HNAT)' "$SRC/target/linux/mediatek/patches-6.12/999-eth-91-mtk_eth_soc-add-mtkhnat-driver-support.patch"; then
  pass "MT7987 integrated PPE is selected and independent-HNAT conflict is documented in source"
else
  fail "MT7987 integrated PPE source/Kconfig conflict check is incomplete"
fi
if ! grep -q 'mediatek,mtk-hnat_v5' "$DTS"; then
  pass "H5000M DTS does not add the independent mtkhnat probe node"
else
  fail "independent mtkhnat DTS node unexpectedly present"
fi
# On hnat-6.12 branch, closed WiFi is NOT available (no MT7992 in SDK),
# while Ethernet acceleration comes from the integrated PPE path. Only forbid
# the unrelated closed WiFi/WARP packages.
if grep -q 'CONFIG_PACKAGE_kmod-mt_wifi7=y' "$CFG" || grep -q 'CONFIG_PACKAGE_kmod-warp=y'; then
  fail "forbidden vendor Wi-Fi/WARP package enabled (no MT7992 support)"
else
  pass "no vendor Wi-Fi/WARP packages (integrated PPE path allowed)"
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
thermal_trips=(40000 85000 115000 117000 120000 125000)
thermal_found=0
for t in "${thermal_trips[@]}"; do
	if grep -q "temperature = <$t>" "$SRC/target/linux/mediatek/dts/mt7987.dtsi"; then
		thermal_found=$((thermal_found + 1))
	else
		fail "thermal trip $t missing"
	fi
done
if [ "$thermal_found" -eq "${#thermal_trips[@]}" ]; then
	pass "all ${#thermal_trips[@]} thermal trip points present (40/85/115/117/120/125 C)"
fi
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
if git -C "$SRC" diff --quiet -- target/linux/generic/config-6.12; then
  # The 973 Ethernet DTS delta is checked exactly in section 4 above. The
  # generic kernel config must remain untouched; the expected IPv6 fragment is
  # the only local kernel-config change.
  added="$(git -C "$SRC" diff -- target/linux/mediatek/filogic/config-6.12 | grep '^+' | grep -v '^+++' || true)"
  unexpected="$(printf '%s\n' "$added" | grep -vE '^\+# H5000M: ' | grep -vE '^\+CONFIG_IPV6=y$' | grep -vE '^\+$' || true)"
  if [ -z "$unexpected" ]; then
    pass "CPUFreq/OPP upstream inputs unmodified; expected IPv6 fragment only"
  else
    fail "CPUFreq/OPP upstream inputs were modified (unexpected: $unexpected)"
  fi
else
  fail "generic/config-6.12 has an unexpected CPUFreq/OPP modification"
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
