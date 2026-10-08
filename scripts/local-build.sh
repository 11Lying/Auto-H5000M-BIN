#!/usr/bin/env bash
# ============================================================================
# Hiveton H5000M x ImmortalWrt v25.12.2 (official stable)
#
# The whole build, in order, and nothing else:
#
#   1. clone official immortalwrt/immortalwrt at the released tag
#   2. verify our feeds.conf.default against the one shipped in that tag,
#      then add the single extra feed (QModem, pinned)
#   3. feeds update / install
#   4. apply three H5000M patches (all documented in README.md)
#   5. copy config/h5000m.config -> .config, run `make defconfig`
#   6. run the static verification suite (scripts/verify-config.sh)
#   7. make
#   8. collect images + the expanded .config + manifest + identity
#
# Usage:
#   scripts/local-build.sh [--config-only] [--verify-only] [--skip-feeds-update]
# ============================================================================
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REPO_URL="${REPO_URL:-https://github.com/immortalwrt/immortalwrt}"
REPO_REF="${REPO_REF:-v25.12.2}"
# The commit the v25.12.2 tag points at. Asserted after cloning.
REPO_COMMIT="${REPO_COMMIT:-4fc16f2985a358bd43bb522e43f05395fcbd6ed5}"

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
SKIP_FEEDS_UPDATE="${SKIP_FEEDS_UPDATE:-false}"

usage() {
	cat <<'EOF'
Usage: scripts/local-build.sh [options]

  --config-only         clone + feeds + patches + .config + verify, do not build
  --verify-only         skip clone/feeds; just apply patches + verify what is there
  --skip-feeds-update   reuse an existing feeds/ tree

Environment: REPO_URL REPO_REF REPO_COMMIT SOURCE_DIR CONFIG_FILE THREADS
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--config-only)       CONFIG_ONLY=true ;;
		--verify-only)       VERIFY_ONLY=true ;;
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

	# The clone must be the released stable tag, not a moving branch.
	local describe
	describe="$(git -C "$SOURCE_DIR" describe --tags --exact-match 2>/dev/null || true)"
	[ "$describe" = "$REPO_REF" ] || die "expected tag $REPO_REF, got '${describe:-<none>}'"

	local head
	head="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
	if [ "$REPO_REF" = "v25.12.2" ] && [ "$head" != "$REPO_COMMIT" ]; then
		die "v25.12.2 resolves to $head, expected $REPO_COMMIT"
	fi

	local kv
	kv="$(sed -n 's/^LINUX_VERSION-6\.12 = //p' \
		"$SOURCE_DIR/target/linux/generic/kernel-6.12" 2>/dev/null || true)"
	log "source: $describe @ $head (kernel ${kv:-unknown})"
}

# ---------------------------------------------------------------------------
# 2. feeds - official lines must be untouched, then add QModem
# ---------------------------------------------------------------------------
prepare_feeds() {
	[ -f "$SOURCE_DIR/feeds.conf.default" ] || die "missing $SOURCE_DIR/feeds.conf.default"
	[ -f "$EXPECTED_FEEDS" ] || die "missing $EXPECTED_FEEDS"

	# Every upstream feed line in the tree must also be in our file, unchanged.
	local line
	while read -r line; do
		[ -n "$line" ] || continue
		grep -qxF "$line" "$EXPECTED_FEEDS" \
			|| die "upstream feed line not mirrored in $EXPECTED_FEEDS: $line"
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

	for p in 971-hwmon-pwmfan-boot-autoload.patch 972-h5000m-fan-boot-duty.patch; do
		[ -f "$ROOT_DIR/patches/$p" ] || die "missing patch $p"
		if patch -d "$SOURCE_DIR" -p1 --forward --silent < "$ROOT_DIR/patches/$p"; then
			log "applied $p"
		else
			die "failed to apply $p"
		fi
	done
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
	log "building with $THREADS threads"
	( cd "$SOURCE_DIR" && make -j"$THREADS" ) \
		|| ( cd "$SOURCE_DIR" && make -j"$THREADS" V=s )
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
	if [ -f "$tgt/immortalwrt-mediatek-filogic-hiveton_h5000m.manifest" ]; then
		cp -f "$tgt/immortalwrt-mediatek-filogic-hiveton_h5000m.manifest" \
			"$ARTIFACTS_DIR/openwrt-image.manifest"
	fi
	[ -f "$tgt/profiles.json" ] && cp -f "$tgt/profiles.json" "$ARTIFACTS_DIR/" || true

	# provenance
	{
		echo "build_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		echo "source=immortalwrt/immortalwrt"
		echo "source_ref=$REPO_REF"
		echo "source_commit=$(git -C "$SOURCE_DIR" rev-parse HEAD)"
		echo "device=hiveton_h5000m"
		echo "target=mediatek/filogic"
		echo "kernel=$(sed -n 's/^LINUX_VERSION-6\.12 = //p' "$SOURCE_DIR/target/linux/generic/kernel-6.12")"
		echo "wifi_stack=official mt76 (kmod-mt7996e + kmod-mt7992-23-firmware)"
		echo "fan_boot_duty=89 (35%)"
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

	if [ "$CONFIG_ONLY" = true ]; then
		log "--config-only: stopping before the build"
		exit 0
	fi

	run_build
	collect
	log "done"
}

main "$@"
