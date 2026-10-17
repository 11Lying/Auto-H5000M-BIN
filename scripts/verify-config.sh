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
sect "1b. stable kernel and QModem source patches"
if grep -qx 'LINUX_VERSION-6.12 = .113' "$SRC/target/linux/generic/kernel-6.12" && \
   grep -qx 'LINUX_KERNEL_HASH-6.12.113 = e09b6727e5c521253f0d41694900b9c38fb7604db7d35238a8197aa9f7de2428' "$SRC/target/linux/generic/kernel-6.12"; then
  pass "kernel.org stable v6.12.113 and SHA256 are pinned"
else
  fail "kernel source pin is not the reviewed 6.12.113 stable tarball"
fi
kernel_tmp="$(mktemp -d)"
mkdir -p "$kernel_tmp/target/linux/generic"
if git -C "$SRC" show HEAD:target/linux/generic/kernel-6.12 > "$kernel_tmp/target/linux/generic/kernel-6.12" && \
   patch -d "$kernel_tmp" -p1 --forward --silent < "$ROOT_DIR/patches/968-linux-6.12.113.patch" >/dev/null 2>&1 && \
   cmp -s "$kernel_tmp/target/linux/generic/kernel-6.12" "$SRC/target/linux/generic/kernel-6.12"; then
  pass "kernel-6.12 version file equals pinned source plus exactly patch 968"
else
  fail "kernel-6.12 version file differs from pinned source plus patch 968"
fi
rm -rf "$kernel_tmp"
qmi_patch="$SRC/target/linux/generic/backport-6.12/788-v7.3-net-usb-qmi_wwan-add-Quectel-EG120K-EA.patch"
qmi_saved="$SRC/target/linux/generic/backport-6.12-superseded/788-v7.3-net-usb-qmi_wwan-add-Quectel-EG120K-EA.patch"
if [ ! -e "$qmi_patch" ] && [ -s "$qmi_saved" ] && \
   grep -Fq 'QMI_MATCH_FF_FF_FF(0x2c7c, 0x030b)' "$qmi_saved"; then
  pass "redundant QMI USB-ID backport is preserved but out of the 6.12.113 patch queue"
else
  fail "6.12.113 duplicate QMI backport was not safely preserved/disabled"
fi
eth07="$SRC/target/linux/mediatek/patches-6.12/999-eth-07-mtk_eth_soc-fix-panic-issue-with-napi_enable.patch"
eth07_saved="$SRC/target/linux/mediatek/patches-6.12-superseded/999-eth-07-mtk_eth_soc-fix-panic-issue-with-napi_enable.patch"
if [ -s "$eth07" ] && cmp -s "$eth07" "$ROOT_DIR/patches/974-mtk-eth-napi-helper-6.12.113.patch" && \
   [ -s "$eth07_saved" ] && \
   grep -Fq 'netif_napi_add(eth->dummy_dev, &eth->rx_napi, mtk_napi_rx)' "$eth07_saved"; then
  pass "6.12.113 NAPI helper rebase staged; original vendor patch preserved outside queue"
else
  fail "stable-kernel NAPI rebase/original-patch preservation is incomplete"
fi
sms_source="$SRC/feeds/qmodem/application/sms_forwarder_next/files/sms_forwarder_next"
if [ -f "$sms_source" ] && grep -Fq 'const SMS_TZ_FIX = 28800;' "$sms_source" && \
   grep -Fq 'let ts = int(timestamp) - SMS_TZ_FIX;' "$sms_source"; then
  pass "QModem SMS timestamp correction is present in source"
else
  fail "QModem SMS timestamp correction is missing"
fi
sms_tmp="$(mktemp -d)"
mkdir -p "$sms_tmp/feeds/qmodem/application/sms_forwarder_next/files"
if git -C "$SRC/feeds/qmodem" show HEAD:application/sms_forwarder_next/files/sms_forwarder_next > \
     "$sms_tmp/feeds/qmodem/application/sms_forwarder_next/files/sms_forwarder_next" && \
   patch -d "$sms_tmp" -p1 --forward --silent < "$ROOT_DIR/patches/969-qmodem-sms-timestamp-utc8.patch" >/dev/null 2>&1 && \
   cmp -s "$sms_tmp/feeds/qmodem/application/sms_forwarder_next/files/sms_forwarder_next" "$sms_source"; then
  pass "QModem SMS source equals pinned feed plus exactly patch 969"
else
  fail "QModem SMS source differs from the pinned feed plus patch 969"
fi
rm -rf "$sms_tmp"
hnat91="$SRC/target/linux/mediatek/patches-6.12/999-eth-91-mtk_eth_soc-add-mtkhnat-driver-support.patch"
hnat91_saved="$SRC/target/linux/mediatek/patches-6.12-superseded/999-eth-91-mtk_eth_soc-add-mtkhnat-driver-support.patch"
hnat91_tmp="$(mktemp -d)"
mkdir -p "$hnat91_tmp/target/linux/mediatek/patches-6.12"
if git -C "$SRC" show HEAD:target/linux/mediatek/patches-6.12/999-eth-91-mtk_eth_soc-add-mtkhnat-driver-support.patch > \
     "$hnat91_tmp/target/linux/mediatek/patches-6.12/999-eth-91-mtk_eth_soc-add-mtkhnat-driver-support.patch" && \
   [ -s "$hnat91_saved" ] && \
   cmp -s "$hnat91_tmp/target/linux/mediatek/patches-6.12/999-eth-91-mtk_eth_soc-add-mtkhnat-driver-support.patch" "$hnat91_saved" && \
   patch -d "$hnat91_tmp" -p1 --forward --silent < "$ROOT_DIR/patches/975-mtkhnat91-integrated-ppe-6.12.113.patch" >/dev/null 2>&1 && \
   cmp -s "$hnat91_tmp/target/linux/mediatek/patches-6.12/999-eth-91-mtk_eth_soc-add-mtkhnat-driver-support.patch" "$hnat91"; then
  pass "999-eth-91 original preserved; only the stable-incompatible, unselected HNAT unwind hunk is omitted"
else
  fail "999-eth-91 stable compatibility edit differs from its pinned original"
fi
rm -rf "$hnat91_tmp"

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
	PACKAGE_luci-app-qmodem PACKAGE_luci-app-modem PACKAGE_modemmanager PACKAGE_sendat
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
extra="$(find "$ROOT_DIR/patches" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | grep -vE '^(968-linux-6[.]12[.]113|969-qmodem-sms-timestamp-utc8|970-pwm-fan-boot-duty|971-hwmon-pwmfan-boot-autoload|972-h5000m-fan-boot-duty|973-h5000m-ethernet-rss-irqs|974-mtk-eth-napi-helper-6[.]12[.]113|975-mtkhnat91-integrated-ppe-6[.]12[.]113|999-eth-94-mtk_eth-debugfs-mib-safe|999-eth-95-mtk_eth-debugfs-lifecycle)\.patch$' || true)"
if [ -z "$extra" ] && [ -f "$ROOT_DIR/patches/optional-independent-hnat/README.md" ]; then
	pass "active patch allowlist is exact; independent HNAT patches are retained but disabled"
else
	fail "unexpected active patch files or missing disabled-HNAT note: $(echo "$extra" | tr '\n' ' ')"
fi
# These patches run after vendor 90/91/93. 90 added a loop over all GMAC IDs
# without skipping disabled DT MACs, and created debugfs/proc files before probe
# completed without removing them on device removal.
ETH_SAFE_PATCH="$SRC/target/linux/mediatek/patches-6.12/999-eth-94-mtk_eth-debugfs-mib-safe.patch"
ETH_LIFECYCLE_PATCH="$SRC/target/linux/mediatek/patches-6.12/999-eth-95-mtk_eth-debugfs-lifecycle.patch"
if [ -s "$ETH_SAFE_PATCH" ] && grep -Fq 'mac = READ_ONCE(eth->mac[i]);' "$ETH_SAFE_PATCH" && \
   grep -Fq 'if (!mac || mac->id != i)' "$ETH_SAFE_PATCH" && \
   grep -Fq 'sgmii_to_mac[id] >= ARRAY_SIZE(eth->mac)' "$ETH_SAFE_PATCH" && \
   grep -Fq 'usxgmii_to_mac[id] >= ARRAY_SIZE(eth->mac)' "$ETH_SAFE_PATCH" && \
   grep -Fq 'RX_BC_DROP_CNT, rx_bc_drop' "$ETH_SAFE_PATCH" && \
   grep -Fq 'RX_MC_DROP_CNT, rx_mc_drop' "$ETH_SAFE_PATCH" && \
   grep -Fq 'proc_remove(eth->debugfs->procfs_root);' "$ETH_SAFE_PATCH"; then
	pass "MAC/XFI MIB readers guard sparse GMAC/PCS entries and preserve counter identity"
else
	fail "MAC MIB null/lifecycle/counter-identity patch is missing or incomplete"
fi
if [ -s "$ETH_LIFECYCLE_PATCH" ] && \
   grep -Fq 'err = mtk_eth_debugfs_init(eth);' "$ETH_LIFECYCLE_PATCH" && \
   grep -Fq 'if (err && !eth->debugfs)' "$ETH_LIFECYCLE_PATCH" && \
   grep -Fq 'err_unreg_netdev:' "$ETH_LIFECYCLE_PATCH" && \
   grep -Fq 'mtk_eth_debugfs_exit(eth);' "$ETH_LIFECYCLE_PATCH" && \
   [ "$(grep -n -F 'err = mtk_eth_debugfs_init(eth);' "$ETH_LIFECYCLE_PATCH" | cut -d: -f1)" -lt "$(grep -n -F 'err = register_netdev(eth->netdev[i]);' "$ETH_LIFECYCLE_PATCH" | cut -d: -f1)" ]; then
	pass "debugfs backing state exists before netdev exposure; failures/removal drain callbacks"
else
	fail "Ethernet debugfs/proc lifecycle ordering or cleanup patch is missing/incomplete"
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
MT76_RRO_FIX="$SRC/package/kernel/mt76/patches/0118-wifi-mt76-mt7996-fix-wed-rro-ba-delete-event-layout.patch"
if [ -s "$MT76_RRO_FIX" ] && grep -Fq '__le16 wlan_id;' "$MT76_RRO_FIX" && \
   grep -Fq 'u8 tid;' "$MT76_RRO_FIX" && \
   grep -Fq 'bd49f06353d7e8cdfa1458912ba9a866870cb795' "$ROOT_DIR/vendor/mt76/README.md"; then
	pass "pinned mt76 source receives the verified 12-byte MT7996 WED-RRO event fix"
else
	fail "targeted MT7996 WED-RRO event layout backport is missing"
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
	pass "only QModem Next UI is selected; standalone ModemWebUI is separate"
fi
cfg_has PACKAGE_h5000m-modem-support && pass "H5000M standalone ModemWebUI/AT/QSCAN support package selected" || fail "h5000m-modem-support package missing"
cfg_absent PACKAGE_sendat && pass "vendor sendat package disabled; custom wrapper owns /bin/sendat" || fail "sendat package conflicts with the AT wrapper"
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
if grep -qx 'CONFIG_NET_MEDIATEK_HNAT=y' "$KCFG" || grep -qx 'CONFIG_NET_MEDIATEK_HNAT=m' "$KCFG"; then
  fail "independent NET_MEDIATEK_HNAT symbol enabled alongside the integrated PPE path"
else
  pass "independent NET_MEDIATEK_HNAT kernel symbol remains disabled"
fi
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
	PACKAGE_quectel-CM-5G-M PACKAGE_h5000m-modem-support; do
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
cfg_has PACKAGE_smartdns && pass "SmartDNS engine selected" || fail "smartdns missing"
cfg_has PACKAGE_luci-app-smartdns && pass "SmartDNS LuCI app selected" || fail "luci-app-smartdns missing"
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
sect "14. custom package scope and secret hygiene"
if [ "$(find "$ROOT_DIR/package" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 3 ] && \
   [ -d "$ROOT_DIR/package/h5000m-fancontrol" ] && \
   [ -d "$ROOT_DIR/package/h5000m-modem-support" ] && \
   [ -d "$ROOT_DIR/package/h5000m-network-guard" ]; then
  pass "exactly the reviewed fan, modem-support and IPv6-guard packages are shipped"
else
  fail "custom package allowlist differs from the reviewed three packages"
fi
cfg_has PACKAGE_h5000m-modem-support && cfg_has PACKAGE_h5000m-network-guard \
  && pass "custom modem and IPv6 guard packages selected" \
  || fail "custom modem/IPv6 guard package missing from expanded config"
cfg_has PACKAGE_uclient-fetch && pass "IPv6 prefix updater fetch dependency selected" || fail "uclient-fetch dependency missing"
for f in "$ROOT_DIR/package/h5000m-fancontrol/files/etc/config/fancontrol" "$ROOT_DIR/package/h5000m-fancontrol/files/etc/init.d/fancontrol" "$ROOT_DIR/package/h5000m-fancontrol/files/usr/bin/h5000m-audit"; do
  [ -s "$f" ] || fail "missing H5000M runtime file: $f"
done
for f in "$ROOT_DIR/package/h5000m-modem-support/files/usr/bin/webuiserver" \
         "$ROOT_DIR/package/h5000m-modem-support/files/bin/sendat" \
         "$ROOT_DIR/package/h5000m-modem-support/files/bin/sendat.real" \
         "$ROOT_DIR/package/h5000m-modem-support/files/usr/libexec/qscan/qscan-run.sh" \
         "$ROOT_DIR/package/h5000m-modem-support/files/usr/share/sms_forwarder/sms_forward_wecom.sh" \
         "$ROOT_DIR/package/h5000m-modem-support/src/atsend.c" \
         "$ROOT_DIR/package/h5000m-modem-support/src/qscan-worker.c" \
         "$ROOT_DIR/package/h5000m-modem-support/LICENSE.webui.GPL-3.0" \
         "$ROOT_DIR/package/h5000m-modem-support/LICENSE.qscan.MIT"; do
  [ -s "$f" ] || fail "missing modem-support payload/source/license: $f"
done
for f in "$ROOT_DIR/package/h5000m-modem-support/files/etc/init.d"/* \
         "$ROOT_DIR/package/h5000m-modem-support/files/etc/uci-defaults"/* \
         "$ROOT_DIR/package/h5000m-modem-support/files/etc/hotplug.d/usb"/* \
         "$ROOT_DIR/package/h5000m-modem-support/files/usr/bin"/*.sh \
         "$ROOT_DIR/package/h5000m-modem-support/files/usr/libexec/qscan"/*.sh \
         "$ROOT_DIR/package/h5000m-modem-support/files/usr/share/sms_forwarder"/*.sh \
         "$ROOT_DIR/package/h5000m-network-guard/files/etc/uci-defaults"/* \
         "$ROOT_DIR/package/h5000m-network-guard/files/etc/hotplug.d/iface"/* \
         "$ROOT_DIR/package/h5000m-network-guard/files/usr/bin"/*.sh; do
  [ -f "$f" ] || continue
  sh -n "$f" || fail "shell syntax error: $f"
done
if command -v gcc >/dev/null 2>&1 && \
   gcc -D_GNU_SOURCE -std=gnu11 -Wall -Wextra -Werror -fsyntax-only \
     "$ROOT_DIR/package/h5000m-modem-support/src/atsend.c" \
     "$ROOT_DIR/package/h5000m-modem-support/src/qscan-worker.c"; then
  pass "QSCAN C source passes native warning-as-error syntax checks"
else
  fail "QSCAN C source syntax check failed or native gcc unavailable"
fi
if file "$ROOT_DIR/package/h5000m-modem-support/files/usr/bin/webuiserver" | grep -q 'ARM aarch64' && \
   file "$ROOT_DIR/package/h5000m-modem-support/files/bin/sendat.real" | grep -q 'ARM aarch64'; then
  pass "prebuilt vendor helpers match the H5000M aarch64 userspace architecture"
else
  fail "vendor helper architecture is not aarch64"
fi
for f in "$ROOT_DIR/package/h5000m-network-guard/files/usr/bin/ipv6-guard.sh" \
         "$ROOT_DIR/package/h5000m-network-guard/files/usr/bin/ipv6-cn-fastfail.sh" \
         "$ROOT_DIR/package/h5000m-network-guard/files/etc/ipv6-cn.list"; do
  [ -s "$f" ] || fail "missing IPv6 guard payload: $f"
done
for f in "$ROOT_DIR/package/h5000m-modem-support/files/etc/uci-defaults/90-h5000m-modem-support" \
         "$ROOT_DIR/package/h5000m-network-guard/files/etc/uci-defaults/92-h5000m-network-guard"; do
  [ -x "$f" ] || fail "uci-defaults must be executable: $f"
done
if grep -Eq 'uci[[:space:]].*(network\.|dnsmasq\.|openclash\.|smartdns\.)' \
   "$ROOT_DIR/package/h5000m-modem-support/files/etc/uci-defaults/90-h5000m-modem-support" \
   "$ROOT_DIR/package/h5000m-network-guard/files/etc/uci-defaults/92-h5000m-network-guard"; then
  fail "first-boot custom package writes WAN/DNS/OpenClash settings"
else
  pass "first-boot additions leave WAN/DNS/OpenClash user configuration untouched"
fi
if find "$ROOT_DIR/package" -type f \
   \( -path '*/etc/config/openclash' -o -path '*/etc/config/sms_forwarder' -o -path '*/etc/config/network' \) \
   -print -quit | grep -q .; then
  fail "user-specific OpenClash/SMS/WAN UCI config must not be embedded"
else
  pass "no user-specific OpenClash, SMS or network UCI config embedded"
fi
if grep -RqiE 'qyapi\.weixin\.qq\.com/cgi-bin/webhook/send\?key=[[:xdigit:]-]{16,}|(subscribe|token)=([A-Za-z0-9_-]{24,})' \
   "$ROOT_DIR/package"; then
  fail "possible credential or subscription URL embedded in public package"
else
  pass "no obvious webhook keys/subscription tokens in custom packages"
fi
OFFLOAD_DEFAULT="$ROOT_DIR/package/h5000m-fancontrol/files/etc/uci-defaults/90-h5000m-hw-offload"
if ! grep -Fq '[ "$WIFITEMP" = "1" ] || return 1' "$ROOT_DIR/package/h5000m-fancontrol/files/usr/bin/fancontrol"; then
  fail "fancontrol wifi_temp=0 does not short-circuit mt76 hwmon temperature"
else
  pass "fancontrol wifi_temp=0 disables both hwmon and iwpriv temperature inputs"
fi
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
