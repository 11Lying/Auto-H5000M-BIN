#!/usr/bin/env bash
# ============================================================================
# Hiveton H5000M x ImmortalWrt 25.12-based HNAT build
#
# The whole build, in order:
#
#   1. clone the pinned chasey-dev ImmortalWrt 25.12-based MTK tree
#   2. install the pinned ImmortalWrt feeds plus the pinned QModem feed
#   3. stage the vendored upstream mt76 package and H5000M fan controller
#   4. select the HNAT kernel package, enable IPv6 and apply reviewed DTS patches
#   5. copy config/h5000m.config -> .config, run `make defconfig`
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

REPO_URL="${REPO_URL:-https://github.com/chasey-dev/immortalwrt-mt798x-rebase}"
REPO_REF="${REPO_REF:-25.12}"
# Pinned commit on the 25.12 branch (2026-10-13). Has HNAT driver on 6.12
# but H5000M defaults to open mt76 (no MT7992 in closed SDK).
REPO_COMMIT="${REPO_COMMIT:-468e251661cb46face4ca0c961238282a6eaaa0a}"

SOURCE_DIR="${SOURCE_DIR:-immortalwrt}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"
CONFIG_FILE="${CONFIG_FILE:-$ROOT_DIR/config/h5000m.config}"
EXPECTED_FEEDS="${EXPECTED_FEEDS:-$ROOT_DIR/feeds.conf.default}"
detect_build_jobs() {
	local jobs mem_kb mem_mb mem_jobs
	jobs="$(nproc 2>/dev/null || echo 2)"
	case "$jobs" in ''|*[!0-9]*) jobs=2;; esac
	# Leave 4 GiB for the OS and budget ~1.7 GiB per active compiler job.
	# A 24-GiB laptop therefore defaults to 12 jobs instead of nproc's 32.
	mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
	case "$mem_kb" in ''|*[!0-9]*) mem_kb=0;; esac
	if [ "$mem_kb" -gt 0 ]; then
		mem_mb=$((mem_kb / 1024))
		mem_jobs=$(((mem_mb - 4096) / 1700))
		[ "$mem_jobs" -ge 1 ] || mem_jobs=1
		[ "$jobs" -le "$mem_jobs" ] || jobs=$mem_jobs
	fi
	# Beyond 16 jobs, this target is generally limited by memory and I/O.
	[ "$jobs" -le 16 ] || jobs=16
	printf '%s\n' "$jobs"
}
THREADS="${THREADS:-$(detect_build_jobs)}"

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

Environment: REPO_URL REPO_REF REPO_COMMIT SOURCE_DIR CONFIG_FILE THREADS CCACHE_DIR CCACHE_MAXSIZE

If THREADS is unset, jobs are capped by detected RAM/CPU (24 GiB -> 12 jobs).
The local ccache defaults to <SOURCE_DIR>/.ccache and is reused across builds.
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
		log "cloning $REPO_URL @ $REPO_REF"
		local ok=false
		local prefix
		for prefix in "" $GITHUB_PROXY_PREFIXES; do
			rm -rf "$SOURCE_DIR"
			if git clone --depth "$GIT_CLONE_DEPTH" --branch "$REPO_REF" \
				"${prefix}${REPO_URL}" "$SOURCE_DIR"; then ok=true; break; fi
			warn "clone failed via '${prefix:-direct}', trying next"
		done
		$ok || die "could not clone $REPO_URL"
	fi

	# For branch-based sources (chasey-dev 25.12), checkout the pinned commit.
	# The shallow clone only has the branch tip; fetch the pinned commit.
	local head
	head="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
	if [ "$head" != "$REPO_COMMIT" ]; then
		log "fetching pinned commit $REPO_COMMIT"
		git -C "$SOURCE_DIR" fetch --depth 1 origin "$REPO_COMMIT" || \
			git -C "$SOURCE_DIR" fetch origin "$REPO_COMMIT"
		git -C "$SOURCE_DIR" checkout "$REPO_COMMIT" || \
			die "could not checkout pinned commit $REPO_COMMIT"
		head="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
	fi
	[ "$head" = "$REPO_COMMIT" ] || die "expected commit $REPO_COMMIT, got $head"

	# Persistent compiler cache. Local builds use the source tree by default;
	# CI may point CCACHE_DIR at its cache mount. Never clean this directory.
	export CCACHE_DIR="${CCACHE_DIR:-$SOURCE_DIR/.ccache}"
	export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-20G}"
	export CCACHE_COMPRESS="${CCACHE_COMPRESS:-1}"
	mkdir -p "$CCACHE_DIR"
	for d in /usr/lib/ccache/bin /usr/lib/ccache; do
		[ -d "$d" ] && PATH="$d:$PATH"
	done
	export PATH
	command -v ccache >/dev/null 2>&1 && ccache -M "$CCACHE_MAXSIZE" >/dev/null 2>&1 || true
	log "ccache directory: $CCACHE_DIR (max $CCACHE_MAXSIZE)"

	local kv
	kv="$(sed -n 's/^LINUX_VERSION-6\.12 = //p' \
		"$SOURCE_DIR/target/linux/generic/kernel-6.12" 2>/dev/null || true)"
	log "source: $REPO_REF @ $head (kernel ${kv:-unknown})"
}

# ---------------------------------------------------------------------------
# 2. feeds - official lines must be untouched, then add QModem
# ---------------------------------------------------------------------------
prepare_feeds() {
	[ -f "$SOURCE_DIR/feeds.conf.default" ] || die "missing $SOURCE_DIR/feeds.conf.default"
	[ -f "$EXPECTED_FEEDS" ] || die "missing $EXPECTED_FEEDS"

	# For chasey-dev base: upstream uses branch names (;openwrt-25.12), we use
	# pinned commits (^<sha>). Verify the feed URLs match, allowing pin vs branch.
	local line url
	while read -r line; do
		[ -n "$line" ] || continue
		url="$(printf '%s' "$line" | sed -E 's/^src-git [^ ]+ //; s/[;^].*$//')"
		grep -qE "^src-git [^ ]+ ${url}[;^]" "$EXPECTED_FEEDS" \
			|| die "upstream feed URL not mirrored in $EXPECTED_FEEDS: $url"
	done < <(grep '^src-git' "$SOURCE_DIR/feeds.conf.default")

	# ...and we must not have re-pointed any official feed at another branch.
	if grep -E '^src-git (packages|luci|routing|telephony|video) ' "$EXPECTED_FEEDS" \
		| grep -qE ';(openwrt|master|main|openwrt-2[0-4])'; then
		die "an official feed in $EXPECTED_FEEDS is pinned to a branch, not a commit"
	fi

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
	dir="$SOURCE_DIR/target/linux/mediatek/patches-6.12"
	[ -d "$dir" ] || die "missing $dir"
	cp -f "$ROOT_DIR/patches/970-pwm-fan-boot-duty.patch" "$dir/" \
		|| die "could not stage kernel patch"
	log "staged target/linux/mediatek/patches-6.12/970-pwm-fan-boot-duty.patch"
	# HNAT is selected as CONFIG_PACKAGE_kmod-mediatek_hnat in the seed.
	# This is essential: adding CONFIG_NET_MEDIATEK_HNAT to the kernel fragment
	# can compile mtkhnat.ko as M while omitting the package from the image.
	# Keep IPv6 explicit in the kernel fragment for the driver's IPv6 path.
	local kernel_config="$SOURCE_DIR/target/linux/mediatek/filogic/config-6.12"
	if ! grep -qx 'CONFIG_IPV6=y' "$kernel_config"; then
		{
			echo ""
			echo "# H5000M: enable IPv6 for MediaTek HNAT IPv6 flow acceleration"
			echo "CONFIG_IPV6=y"
		} >> "$kernel_config"
		log "enabled IPv6 in filogic kernel config"
	else
		log "IPv6 already enabled in filogic kernel config"
	fi
	log "HNAT selected as packaged module via CONFIG_PACKAGE_kmod-mediatek_hnat"
	# Include the maintained userspace controller and read-only audit utility.
	rm -rf "$SOURCE_DIR/package/h5000m-fancontrol"
	cp -a "$ROOT_DIR/package/h5000m-fancontrol" "$SOURCE_DIR/package/h5000m-fancontrol"
	log "staged H5000M fan-control package"

	# The chasey-dev 25.12 base does not ship package/kernel/mt76, while the
	# H5000M device profile still declares the upstream MT7992 stack. Stage the
	# official ImmortalWrt 25.12 package so kmod-mt7996e, mt76-core and the
	# MT7992 firmware are actually selected and installed in the image.
	[ -f "$ROOT_DIR/vendor/mt76/Makefile" ] || die "missing vendored mt76 package"
	[ -f "$ROOT_DIR/vendor/mt76/patches/110-mtk-wed-v3.1-compat.patch" ] || die "missing MTK WED 3.1 compatibility patch"
	rm -rf "$SOURCE_DIR/package/kernel/mt76"
	mkdir -p "$SOURCE_DIR/package/kernel"
	cp -a "$ROOT_DIR/vendor/mt76" "$SOURCE_DIR/package/kernel/mt76"
	[ -f "$SOURCE_DIR/package/kernel/mt76/Makefile" ] || die "could not stage vendored mt76 package"
	log "staged vendored official mt76 package (MT7992 Wi-Fi)"

	# 970 (kernel driver) + 971 (early autoload) + 972 (board DTS overlay).
	for p in 971-hwmon-pwmfan-boot-autoload.patch 972-h5000m-fan-boot-duty.patch 973-h5000m-hnat-node.patch; do
		[ -f "$ROOT_DIR/patches/$p" ] || die "missing patch $p"
		if patch -d "$SOURCE_DIR" -p1 --dry-run --forward --silent < "$ROOT_DIR/patches/$p" >/dev/null 2>&1; then
			patch -d "$SOURCE_DIR" -p1 --forward --silent < "$ROOT_DIR/patches/$p" \
				|| die "failed to apply $p"
			log "applied $p"
		elif patch -d "$SOURCE_DIR" -p1 --dry-run --reverse --silent < "$ROOT_DIR/patches/$p" >/dev/null 2>&1; then
			log "$p already applied; reusing source tree"
		else
			die "$p neither applies cleanly nor appears already applied"
		fi
	done

	# libffi 3.4.7's configure chooses the target-specific multi-os build
	# directory (mediatek/filogic here), not GNU_TARGET_NAME*.  InstallDev in
	# the pinned packages feed still looks only for the obsolete tuple path.
	# Keep the feed commit pinned and narrowly fix only this generated-header
	# lookup; the two-level glob matches the configure-created target/subtarget
	# directory without changing libffi's configure/build behavior.
	local ffi_makefile="$SOURCE_DIR/feeds/packages/libs/libffi/Makefile"
	[ -f "$ffi_makefile" ] || die "missing pinned libffi Makefile: $ffi_makefile"
	python3 - "$ffi_makefile" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = "$(PKG_BUILD_DIR)/$(GNU_TARGET_NAME)*/fficonfig.h"
new = "$(PKG_BUILD_DIR)/*/*/fficonfig.h"
if s.count(old) == 1:
    p.write_text(s.replace(old, new))
elif s.count(new) == 1:
    print("libffi lookup patch already applied")
else:
    raise SystemExit(f"expected one stock or patched libffi header lookup; old={s.count(old)} new={s.count(new)}")
PY
	log "patched pinned libffi InstallDev lookup for target/subtarget build directory"

	# Ruby 3.4.9's configure.ac has a broken AC_CONFIG_MACRO_DIR line referencing
	# 'tool/m4/$1' (unexpanded shell variable), causing autoreconf to fail.
	# Disable autoreconf for Ruby; use the pre-generated configure script.
	local ruby_makefile="$SOURCE_DIR/feeds/packages/lang/ruby/Makefile"
	if [ -f "$ruby_makefile" ]; then
		# Remove any existing PKG_FIXUP line and ensure autoreconf is disabled
		sed -i '/^PKG_FIXUP:=/d' "$ruby_makefile"
		# Add explicit empty PKG_FIXUP to prevent autoreconf
		echo "PKG_FIXUP:=" >> "$ruby_makefile"
		log "disabled autoreconf for ruby (broken configure.ac in 3.4.9)"
	fi
}

# ---------------------------------------------------------------------------
# 4. config
# ---------------------------------------------------------------------------
make_config() {
	[ -s "$CONFIG_FILE" ] || die "missing seed config $CONFIG_FILE"
	cp -f "$CONFIG_FILE" "$SOURCE_DIR/.config"
	log "seed .config installed, running make defconfig"
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
	for f in "$tgt"/*hiveton_h5000m*; do
		[ -f "$f" ] || continue
		cp -f "$f" "$ARTIFACTS_DIR/"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || die "no hiveton_h5000m image was produced"

	# fully expanded config + package manifest + build identity
	cp -f "$SOURCE_DIR/.config" "$ARTIFACTS_DIR/build.config"
	grep -q '^CONFIG_PACKAGE_kmod-mediatek_hnat=y$' "$ARTIFACTS_DIR/build.config" \
		|| die "expanded config did not select kmod-mediatek_hnat"
	local manifest="$tgt/immortalwrt-mediatek-filogic-hiveton_h5000m.manifest"
	[ -s "$manifest" ] || die "missing H5000M image manifest"
	# Gate the published image, not just source config. In particular, this
	# catches a compiled-but-unpackaged HNAT .ko before firmware is uploaded.
	for pkg in kmod-mediatek_hnat kmod-nf-conntrack kmod-nf-nat kmod-nf-flow \
		   kmod-tcp-bbr kmod-usb3 kmod-qmi_wwan_q kmod-mt7996e hnat-detect; do
		grep -q "^${pkg} - " "$manifest" || die "required acceleration/data-path package absent from image manifest: $pkg"
	done
	find "$SOURCE_DIR/bin" -type f -name 'kmod-mediatek_hnat-*.apk' -print -quit | grep -q . \
		|| die "HNAT kernel module APK was not built"
	cp -f "$manifest" "$ARTIFACTS_DIR/openwrt-image.manifest"
	[ -f "$tgt/profiles.json" ] && cp -f "$tgt/profiles.json" "$ARTIFACTS_DIR/" || true

	# provenance
	{
		echo "build_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		echo "source=chasey-dev/immortalwrt-mt798x-rebase"
		echo "source_ref=$REPO_REF"
		echo "source_commit=$(git -C "$SOURCE_DIR" rev-parse HEAD)"
		echo "device=hiveton_h5000m"
		echo "target=mediatek/filogic"
		echo "kernel=$(sed -n 's/^LINUX_VERSION-6\.12 = //p' "$SOURCE_DIR/target/linux/generic/kernel-6.12")"
		echo "wifi_stack=official mt76 (kmod-mt7996e + kmod-mt7992-23-firmware)"
		echo "fan_patches=970+971+972 applied; upstream thermal trips retained"
		echo "acceleration=HNAT module packaged; nft flow HW+SW; IPv6; USB-QMI; BBR; MT76/WED3.1"
		echo "--- feeds ---"
		grep '^src-git' "$SOURCE_DIR/feeds.conf.default"
		echo "--- openclash ---"
		grep -m1 '^PKG_VERSION' \
			"$SOURCE_DIR/feeds/luci/applications/luci-app-openclash/Makefile" 2>/dev/null || true
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

	log "build parallelism: $THREADS jobs; source cache: ${CCACHE_DIR:-$SOURCE_DIR/.ccache}"
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
