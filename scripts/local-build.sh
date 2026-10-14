#!/usr/bin/env bash
# ============================================================================
# Hiveton H5000M x closed-driver performance build
# (padavanonly/immortalwrt-mt798x-6.6 @ mt798x-mt799x-6.6-mtwifi, kernel 6.6)
#
# The whole build, in order, and nothing else:
#
#   1. clone padavanonly/immortalwrt-mt798x-6.6 and check out the pinned commit
#      REPO_COMMIT on branch REPO_BRANCH (reproducible, not a moving target)
#   2. install our feeds.conf.default (branch pins proven with this base),
#      then feeds update / install
#   3. stage extra packages: luci-app-turboacc-mtk (hanwckf),
#      luci-app-openclash (vernesong), h5000m-fancontrol (local)
#   4. apply patches: 970/971/972 (fan) + mtk-hnat-local-dest +
#      mtwifi-apcli-active-only + 973 (hnat wwan whitelist)
#   5. fetch the base defconfig (mt7987_mt7992.config) at the pinned commit,
#      append config/h5000m.config delta, run `make defconfig`
#   6. run the static verification suite (scripts/verify-config.sh)
#   7. make
#   8. collect images + the expanded .config + manifest + identity
#
# Usage:
#   scripts/local-build.sh [--config-only] [--verify-only] [--skip-feeds-update]
# ============================================================================
set -Eeuo pipefail
umask 022

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REPO_URL="${REPO_URL:-https://github.com/padavanonly/immortalwrt-mt798x-6.6}"
REPO_BRANCH="${REPO_BRANCH:-mt798x-mt799x-6.6-mtwifi}"
# Pinned commit of the branch above (2026-07-23). Asserted after checkout:
# the build must never follow a moving branch.
REPO_COMMIT="${REPO_COMMIT:-30fbc1d6deba23c0e850185021e9ee42214925eb}"
# Base defconfig fetched at the pinned commit for reproducibility.
BASE_DEFCONFIG_URL="${BASE_DEFCONFIG_URL:-https://raw.githubusercontent.com/padavanonly/immortalwrt-mt798x-6.6/${REPO_COMMIT}/defconfig/mt7987_mt7992.config}"

SOURCE_DIR="${SOURCE_DIR:-immortalwrt}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"
CONFIG_FILE="${CONFIG_FILE:-$ROOT_DIR/config/h5000m.config}"
EXPECTED_FEEDS="${EXPECTED_FEEDS:-$ROOT_DIR/feeds.conf.default}"
THREADS="${THREADS:-$(nproc 2>/dev/null || echo 2)}"

# Optional GitHub mirror for cloning (only used when set).
GITHUB_PROXY_PREFIXES="${GITHUB_PROXY_PREFIXES:-}"
GIT_CLONE_DEPTH="${GIT_CLONE_DEPTH:-1}"

CONFIG_ONLY=false
VERIFY_ONLY=false
LIBFFI_ONLY=false
LIBFFI_THEN_BUILD=false
SKIP_FEEDS_UPDATE="${SKIP_FEEDS_UPDATE:-false}"

usage() {
	cat <<'EOF'
Usage: scripts/local-build.sh [options]

  --config-only         clone + feeds + patches + .config + verify, do not build
  --verify-only         skip clone/feeds; just apply patches + verify what is there
  --libffi-only         clean/build only libffi and required prerequisites with V=s
  --libffi-then-build   clean/build libffi with V=s, then continue full firmware build
  --skip-feeds-update   reuse an existing feeds/ tree

Environment: REPO_URL REPO_BRANCH REPO_COMMIT BASE_DEFCONFIG_URL SOURCE_DIR CONFIG_FILE THREADS
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--config-only)       CONFIG_ONLY=true ;;
		--verify-only)       VERIFY_ONLY=true ;;
		--libffi-only)       LIBFFI_ONLY=true ;;
		--libffi-then-build) LIBFFI_THEN_BUILD=true ;;
		--skip-feeds-update) SKIP_FEEDS_UPDATE=true ;;
		-h|--help)           usage; exit 0 ;;
		*) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
	esac
	shift
done

log()  { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '\n[%s] WARNING: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '::error::H5000M build: %s\n' "$*" >&2; printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. source
# ---------------------------------------------------------------------------
clone_source() {
	if [ -d "$SOURCE_DIR/.git" ]; then
		log "source tree already present: $SOURCE_DIR"
	else
		log "cloning $REPO_URL @ $REPO_BRANCH"
		local ok=false
		local prefix
		for prefix in "" $GITHUB_PROXY_PREFIXES; do
			rm -rf "$SOURCE_DIR"
			if git clone --depth "$GIT_CLONE_DEPTH" --branch "$REPO_BRANCH" \
				"${prefix}${REPO_URL}" "$SOURCE_DIR"; then ok=true; break; fi
			warn "clone failed via '${prefix:-direct}', trying next"
		done
		$ok || die "could not clone $REPO_URL"
	fi

	# Pin to the exact commit: a moving branch must never change the build.
	( cd "$SOURCE_DIR" && git fetch --depth 1 origin "$REPO_COMMIT" 2>/dev/null || true )
	( cd "$SOURCE_DIR" && git checkout -q "$REPO_COMMIT" ) \
		|| die "could not check out $REPO_COMMIT"

	local head
	head="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
	[ "$head" = "$REPO_COMMIT" ] || die "HEAD is $head, expected $REPO_COMMIT"

	# Compiler cache directory, cached by CI as immortalwrt/.ccache. Created here
	# (never in the workflow) so the clone step still sees an empty/missing path.
	mkdir -p "$SOURCE_DIR/.ccache"

	local kv
	kv="$(sed -n 's/^LINUX_VERSION-6\.6 = //p' \
		"$SOURCE_DIR/target/linux/generic/kernel-6.6" 2>/dev/null || true)"
	log "source: $REPO_BRANCH @ $head (kernel ${kv:-unknown})"
}

# ---------------------------------------------------------------------------
# 2. feeds - official lines must be untouched, then add QModem
# ---------------------------------------------------------------------------
prepare_feeds() {
	[ -f "$SOURCE_DIR/feeds.conf.default" ] || die "missing $SOURCE_DIR/feeds.conf.default"
	[ -f "$EXPECTED_FEEDS" ] || die "missing $EXPECTED_FEEDS"

	# ...and we must not have re-pointed any feed at an unexpected remote.
	# NOTE: branch pins (e.g. ;openwrt-24.10) are intentional on this base:
	# reproducibility comes from the pinned base commit (REPO_COMMIT), and
	# these are the branch pins the base was tested against.
	while read -r line; do
		[ -n "$line" ] || continue
		grep -qxF "$line" "$EXPECTED_FEEDS" \
			|| die "upstream feed line not mirrored in $EXPECTED_FEEDS: $line"
	done < <(grep '^src-git' "$SOURCE_DIR/feeds.conf.default" || true)

	cp -f "$EXPECTED_FEEDS" "$SOURCE_DIR/feeds.conf.default"
	log "feeds.conf.default installed"
	grep '^src-git' "$SOURCE_DIR/feeds.conf.default" | sed 's/^/    /'
}

run_feeds() {
	if [ "$SKIP_FEEDS_UPDATE" = true ] && [ -d "$SOURCE_DIR/feeds/luci" ]; then
		log "reusing existing feeds tree"
	else
		log "feeds update"
		( cd "$SOURCE_DIR" && ./scripts/feeds update -a )
	fi
	log "feeds install -a"
	( cd "$SOURCE_DIR" && ./scripts/feeds install -a )
}

# ---------------------------------------------------------------------------
# 3. patches
# ---------------------------------------------------------------------------
apply_patches() {
	local p dir
	# 970 is a kernel patch: it only has to be dropped into the mediatek
	# kernel patch directory, the kernel build applies it with -p1.
	dir="$SOURCE_DIR/target/linux/mediatek/patches-6.6"
	[ -d "$dir" ] || die "missing $dir"
	cp -f "$ROOT_DIR/patches/970-pwm-fan-boot-duty.patch" "$dir/" \
		|| die "could not stage kernel patch"
	log "staged target/linux/mediatek/patches-6.6/970-pwm-fan-boot-duty.patch"
	# Include the maintained userspace controller and read-only audit utility.
	rm -rf "$SOURCE_DIR/package/h5000m-fancontrol"
	cp -a "$ROOT_DIR/package/h5000m-fancontrol" "$SOURCE_DIR/package/h5000m-fancontrol"
	log "staged H5000M fan-control package"

	# Tree patches, applied idempotently (-N: skip hunks already applied).
	for p in 971-hwmon-pwmfan-boot-autoload.patch \
		 972-h5000m-fan-boot-duty.patch \
		 973-hnat-wwan-whitelist.patch \
		 mtk-hnat-local-dest.patch \
		 mtwifi-apcli-active-only.patch; do
		[ -f "$ROOT_DIR/patches/$p" ] || die "missing patch $p"
		if patch -d "$SOURCE_DIR" -p1 -N --silent < "$ROOT_DIR/patches/$p"; then
			log "applied $p"
		elif patch -d "$SOURCE_DIR" -p1 -R --dry-run --silent < "$ROOT_DIR/patches/$p" >/dev/null 2>&1; then
			log "$p already applied, skipping"
		else
			die "failed to apply $p"
		fi
	done

	# luci-app-turboacc-mtk: HNAT/SFE control panel (not in any feed).
	if [ ! -d "$SOURCE_DIR/package/mtk/applications/luci-app-turboacc-mtk" ]; then
		rm -rf /tmp/luci-app-turboacc-mtk
		git clone --depth 1 https://github.com/hanwckf/immortalwrt-mt798x.git \
			/tmp/luci-app-turboacc-mtk \
			|| die "could not clone luci-app-turboacc-mtk"
		if [ -d "/tmp/luci-app-turboacc-mtk/package/mtk/applications/luci-app-turboacc-mtk" ]; then
			mkdir -p "$SOURCE_DIR/package/mtk/applications"
			cp -r /tmp/luci-app-turboacc-mtk/package/mtk/applications/luci-app-turboacc-mtk \
				"$SOURCE_DIR/package/mtk/applications/luci-app-turboacc-mtk"
			log "staged luci-app-turboacc-mtk"
		else
			die "luci-app-turboacc-mtk layout changed upstream"
		fi
		rm -rf /tmp/luci-app-turboacc-mtk
	fi

	# luci-app-openclash (not in any feed).
	if [ ! -d "$SOURCE_DIR/package/luci-app-openclash" ]; then
		rm -rf /tmp/openclash
		git clone --depth 1 https://github.com/vernesong/OpenClash.git /tmp/openclash \
			|| die "could not clone OpenClash"
		[ -d "/tmp/openclash/luci-app-openclash" ] \
			|| die "OpenClash repository layout changed"
		cp -r /tmp/openclash/luci-app-openclash "$SOURCE_DIR/package/luci-app-openclash"
		log "staged luci-app-openclash"
		rm -rf /tmp/openclash
	fi

	# libffi 3.4.7's configure chooses the target-specific multi-os build
	# directory (mediatek/filogic here), not GNU_TARGET_NAME*.  InstallDev in
	# the packages feed still looks only for the obsolete tuple path.
	# Narrowly fix only this generated-header lookup when the exact string
	# is present; otherwise warn (feed may have fixed it upstream).
	local ffi_makefile="$SOURCE_DIR/feeds/packages/libs/libffi/Makefile"
	if [ -f "$ffi_makefile" ]; then
		python3 - "$ffi_makefile" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = "$(PKG_BUILD_DIR)/$(GNU_TARGET_NAME)*/fficonfig.h"
new = "$(PKG_BUILD_DIR)/*/*/fficonfig.h"
if old in s:
    p.write_text(s.replace(old, new, 1))
    print("patched libffi InstallDev lookup")
else:
    print("libffi InstallDev lookup already fixed or changed; leaving alone")
PY
	else
		warn "missing libffi Makefile: $ffi_makefile"
	fi
}

# ---------------------------------------------------------------------------
# 4. config
# ---------------------------------------------------------------------------
make_config() {
	[ -s "$CONFIG_FILE" ] || die "missing delta config $CONFIG_FILE"
	log "fetching base defconfig at pinned commit"
	( cd "$SOURCE_DIR" && curl -fsSL --retry 3 "$BASE_DEFCONFIG_URL" -o base-defconfig ) \
		|| die "could not fetch base defconfig: $BASE_DEFCONFIG_URL"
	grep -q "CONFIG_PACKAGE_kmod-mt_wifi7=y" "$SOURCE_DIR/base-defconfig" \
		|| die "base defconfig does not look like the 6.6-mtwifi one"
	cp -f "$SOURCE_DIR/base-defconfig" "$SOURCE_DIR/.config"
	cat "$CONFIG_FILE" >> "$SOURCE_DIR/.config"
	log "base + delta installed, running make defconfig"
	( cd "$SOURCE_DIR" && make defconfig ) || die "make defconfig failed"
}

# ---------------------------------------------------------------------------
# 5. build
# ---------------------------------------------------------------------------
run_build() {
	log "building verbosely with $THREADS threads; preserving first-run log"
	# Do not retry a failed build: the first failure is the diagnostic evidence.
	# V=s exposes the actual failing command, and tee preserves it for upload.
	( cd "$SOURCE_DIR" && make -j"$THREADS" V=s ) 2>&1 | tee "$ROOT_DIR/build.log"
}

run_libffi_only() {
	log "host-tools gate: build the official tools phase, then verify Meson/Lua/APK/libffi in dependency order"
	# Package-only targets bypass tools/compile. The pinned source already
	# registers Meson as a default host tool; run the standard tools phase so
	# Meson's native/cross templates (and the other host tools) are staged before
	# any package host configure target is entered. This preserves all outputs.
	# Package-only goals bypass the top-level target-toolchain phase. Stage
	# libgcc_s explicitly so the libgcc IPK prerequisite is present.
	# The staging_dir/host/llvm-bpf* assertions below are a cost guard: that
	# toolchain costs ~64 min per run and nothing in this device selects
	# NEED_BPF_TOOLCHAIN, so it must never appear.
	( cd "$SOURCE_DIR" && \
		make -j"$THREADS" tools/compile V=s && \
		make -j"$THREADS" toolchain/compile V=s && \
		make -j"$THREADS" toolchain/install V=s && \
		test -n "$(find staging_dir/toolchain-* -type f -name 'libgcc_s.so.*' -print -quit)" && \
		test -x staging_dir/host/bin/libdeflate-gzip && \
		test -s staging_dir/host/lib/meson/openwrt-native.txt.in && \
		test -s staging_dir/host/lib/meson/openwrt-cross.txt.in && \
		test ! -e staging_dir/host/llvm-bpf && \
		test -z "$(ls -d staging_dir/host/llvm-bpf-* 2>/dev/null || true)" && \
		make -j"$THREADS" package/utils/lua/host/compile V=s && \
		make -j"$THREADS" package/system/apk/host/compile V=s && \
		log "host tools, target toolchain, Lua, and APK staged; now clean only libffi" && \
		make package/feeds/packages/libffi/clean V=s && \
		make -j1 package/feeds/packages/libffi/compile V=s && \
		for f in fficonfig.h ffi.h ffitarget.h; do \
			found=0; for h in staging_dir/target-*/usr/include/"$f"; do \
				[ -s "$h" ] && { found=1; printf 'verified %s (%s bytes)\n' "$h" "$(wc -c < "$h")"; break; }; \
			done; [ "$found" = 1 ] || { echo "missing/empty target header: $f" >&2; exit 1; }; \
		done && \
		found=0; for so in staging_dir/target-*/usr/lib/libffi.so*; do \
			[ -s "$so" ] && { found=1; printf 'verified %s (%s bytes)\n' "$so" "$(wc -c < "$so")"; }; \
		done; [ "$found" = 1 ] || { echo "missing/empty target libffi shared library" >&2; exit 1; } ) \
		2>&1 | tee "$ROOT_DIR/build.log"
}

# ---------------------------------------------------------------------------
# 6. collect
# ---------------------------------------------------------------------------
collect() {
	rm -rf "$ARTIFACTS_DIR"
	mkdir -p "$ARTIFACTS_DIR"

	local tgt="$SOURCE_DIR/bin/targets/mediatek/filogic"
	[ -d "$tgt" ] || die "no image directory $tgt"

	local n=0 f
	for f in "$tgt"/*hiveton-h5000m*; do
		[ -f "$f" ] || continue
		cp -f "$f" "$ARTIFACTS_DIR/"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || die "no hiveton-h5000m image was produced"

	# fully expanded config + package manifest + build identity
	cp -f "$SOURCE_DIR/.config" "$ARTIFACTS_DIR/build.config"
	if [ -f "$tgt/immortalwrt-mediatek-filogic-hiveton-h5000m.manifest" ]; then
		cp -f "$tgt/immortalwrt-mediatek-filogic-hiveton-h5000m.manifest" \
			"$ARTIFACTS_DIR/openwrt-image.manifest"
	fi
	[ -f "$tgt/profiles.json" ] && cp -f "$tgt/profiles.json" "$ARTIFACTS_DIR/" || true

	# provenance
	{
		echo "build_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		echo "source=padavanonly/immortalwrt-mt798x-6.6"
		echo "source_branch=$REPO_BRANCH"
		echo "source_commit=$(git -C "$SOURCE_DIR" rev-parse HEAD)"
		echo "device=hiveton-h5000m"
		echo "target=mediatek/filogic"
		echo "kernel=$(sed -n 's/^LINUX_VERSION-6\.6 = //p' "$SOURCE_DIR/target/linux/generic/kernel-6.6")"
		echo "wifi_stack=closed mt_wifi7 (kmod-mt_wifi7 + mtwifi-cfg)"
		echo "nat_offload=mediatek_hnat (kmod-mediatek_hnat) + mtk_wed"
		echo "qos=luci-app-eqos-mtk (tc-based + mtkhqos_util)"
		echo "congestion_control=bbr (default)"
		echo "proxy_accel=kmod-cryptodev + kmod-tls (EIP-197)"
		echo "usb_wwan_hnat=973 whitelist applied; qmi_fix_skb pending port (KPROBES enabled)"
		echo "fan_patches=970+971+972+973 applied; upstream thermal trips retained"
		echo "--- feeds ---"
		grep '^src-git' "$SOURCE_DIR/feeds.conf.default"
		echo "--- openclash ---"
		grep -m1 '^PKG_VERSION' \
			"$SOURCE_DIR/package/luci-app-openclash/Makefile" 2>/dev/null || true
		echo "--- qmodem ---"
		grep -m1 '^QMODEM_VERSION' "$SOURCE_DIR/feeds/qmodem/version.mk" 2>/dev/null || true
	} > "$ARTIFACTS_DIR/H5000M-IDENTITY.txt"

	( cd "$ARTIFACTS_DIR" && sha256sum ./* > sha256sums.txt )

	log "artifacts:"
	ls -lh "$ARTIFACTS_DIR"
}

# ---------------------------------------------------------------------------
main() {
	cd "$ROOT_DIR"

	if [ "$VERIFY_ONLY" = true ]; then
		[ -d "$SOURCE_DIR" ] || die "--verify-only needs an existing $SOURCE_DIR"
		apply_patches
		bash "$ROOT_DIR/scripts/verify-config.sh" "$SOURCE_DIR"
		exit 0
	fi

	clone_source
	prepare_feeds
	run_feeds
	apply_patches
	make_config
	bash "$ROOT_DIR/scripts/verify-config.sh" "$SOURCE_DIR"

	if [ "$LIBFFI_ONLY" = true ] || [ "$LIBFFI_THEN_BUILD" = true ]; then
		run_libffi_only
		if [ "$LIBFFI_ONLY" = true ]; then
			log "libffi-only diagnostic complete; stopping before full firmware build"
			exit 0
		fi
		log "libffi gate passed; continuing full firmware build with this runner's existing outputs"
	fi

	if [ "$CONFIG_ONLY" = true ]; then
		log "--config-only: stopping before the build"
		exit 0
	fi

	run_build
	collect
	log "done"
}

main "$@"
