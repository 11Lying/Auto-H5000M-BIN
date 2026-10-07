#!/usr/bin/env bash
# =============================================================================
# H5000M × ImmortalWrt 25.12 + MTK Wi-Fi 7 SDK —— 构建脚本（简单版）
#
# 就是标准那一套，没有别的花活：
#   克隆源码 → feeds update/install → 打几个必要补丁 + 放家当包
#   → cp 一份完整 .config → make defconfig → make -j → 收产物
#
# 基座：chasey-dev/immortalwrt-mt798x-rebase @ 25.12-dev-wifi7
#       （ImmortalWrt 25.12 / 内核 6.12 / apk + MTK 闭源 mt_wifi7）
# 配置：config/h5000m-25.12.config（完整 .config，包含 SDK 全部符号）
# =============================================================================
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_URL="${REPO_URL:-https://github.com/chasey-dev/immortalwrt-mt798x-rebase}"
REPO_BRANCH="${REPO_BRANCH:-25.12-dev-wifi7}"
SOURCE_DIR="${SOURCE_DIR:-immortalwrt}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"
CONFIG_FILE="${CONFIG_FILE:-$ROOT_DIR/config/h5000m-25.12.config}"
KERNEL_PATCHVER="${KERNEL_PATCHVER:-6.12}"
THREADS="${THREADS:-$(nproc 2>/dev/null || echo 2)}"
GIT_DEPTH="${GIT_DEPTH:-1}"
GITHUB_PROXIES="${GITHUB_PROXIES:-https://ghfast.top/ https://gh-proxy.com/ https://gh.llkk.cc/}"

CONFIG_ONLY=false
SKIP_FEEDS_UPDATE="${SKIP_FEEDS_UPDATE:-false}"

usage() {
  cat <<'EOF'
Usage: scripts/local-build.sh [--config-only] [--skip-feeds-update] [-h]

  --config-only        只克隆源码/feeds/补丁/生成 .config，不编译
  --skip-feeds-update  跳过 ./scripts/feeds update -a（复用已有 feeds）
环境变量：REPO_URL REPO_BRANCH SOURCE_DIR CONFIG_FILE THREADS
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config-only) CONFIG_ONLY=true ;;
    --skip-feeds-update) SKIP_FEEDS_UPDATE=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

log()  { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '\n[%s] WARNING: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '::error::H5000M build: %s\n' "$*" >&2; printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 源码
prepare_source() {
  log "源码：$REPO_URL ($REPO_BRANCH)"
  if [ -d "$SOURCE_DIR/.git" ]; then
    git -C "$SOURCE_DIR" fetch --depth "$GIT_DEPTH" origin "$REPO_BRANCH" || warn "fetch 失败，用现有 checkout"
    git -C "$SOURCE_DIR" checkout -q -B "$REPO_BRANCH" FETCH_HEAD 2>/dev/null || true
  else
    local u ok=0
    for u in "$REPO_URL" $(for p in $GITHUB_PROXIES; do echo "${p%/}/$REPO_URL"; done); do
      log "  git clone $u"
      if git clone --depth "$GIT_DEPTH" --single-branch --branch "$REPO_BRANCH" "$u" "$SOURCE_DIR"; then ok=1; break; fi
      rm -rf "$SOURCE_DIR"
    done
    [ "$ok" = 1 ] || die "克隆失败：$REPO_URL"
  fi
  [ -f "$SOURCE_DIR/rules.mk" ] || die "$SOURCE_DIR 不像 OpenWrt 源码树"
  echo "源码 HEAD: $(git -C "$SOURCE_DIR" rev-parse --short HEAD)"
}

# ---------------------------------------------------------------- feeds
prepare_feeds() {
  log "feeds"
  cd "$ROOT_DIR/$SOURCE_DIR"
  cp -f "$ROOT_DIR/feeds.conf.default" feeds.conf.default
  if [ "$SKIP_FEEDS_UPDATE" != "true" ]; then
    ./scripts/feeds update -a || die "feeds update 失败"
  fi
  ./scripts/feeds install -a -f || warn "feeds install 有报错，继续"
}

# ---------------------------------------------------------------- 补丁 / 家当
apply_patches() {
  log "补丁"
  cd "$ROOT_DIR/$SOURCE_DIR"

  # 内核：pwm-fan 支持 pwm-fan,boot-duty（开机别满转）
  mkdir -p "target/linux/mediatek/patches-${KERNEL_PATCHVER}"
  cp -f "$ROOT_DIR/patches/999-h5000m-pwm-fan-boot-duty.kernel-patch" \
        "target/linux/mediatek/patches-${KERNEL_PATCHVER}/999-h5000m-pwm-fan-boot-duty.patch"

  # 板级 DTS：给 &fan 加 boot-duty=51（幂等）
  local dts="$ROOT_DIR/patches/dts-h5000m-fan-boot-duty.patch"
  if patch -p1 --forward --dry-run < "$dts" >/dev/null 2>&1; then
    patch -p1 --forward < "$dts" >/dev/null && log "  DTS fan boot-duty 已应用"
  else
    log "  DTS fan boot-duty 已存在或上游已改（跳过）"
  fi

  # QModem feed：短信时间 +8h 修正（上游只在前端修）
  local sms="feeds/qmodem/application/sms_forwarder_next/files/sms_forwarder_next"
  if [ -f "$sms" ]; then
    if grep -q 'SMS_TZ_FIX' "$sms"; then
      log "  短信时区修正已在"
    elif grep -q 'date -d @${timestamp}' "$sms"; then
      sed -i 's|date -d @${timestamp}|date -d @$((timestamp - 28800))|g' "$sms"
      log "  短信时区修正已打"
    else
      warn "  sms_forwarder_next 格式变了，时区修正跳过"
    fi
  fi

  # QModem voipd：libwebsockets 变体（已处理则跳过）
  local voip="feeds/qmodem/application/voipd/Makefile"
  if [ -f "$voip" ] && ! grep -q 'libwebsockets-full' "$voip"; then
    sed -i 's/+libwebsockets-mbedtls/+libwebsockets-full/; s/+libwebsockets-openssl/+libwebsockets-full/' "$voip"
    log "  QModem voipd 依赖已改为 libwebsockets-full"
  fi
}

stage_kit() {
  log "家当包 h5000m-kit"
  rm -rf "$ROOT_DIR/$SOURCE_DIR/package/h5000m-kit"
  cp -a "$ROOT_DIR/h5000m-kit" "$ROOT_DIR/$SOURCE_DIR/package/h5000m-kit"
  chmod 755 "$ROOT_DIR/$SOURCE_DIR/package/h5000m-kit/files/etc/uci-defaults/"* 2>/dev/null || true
  chmod 755 "$ROOT_DIR/$SOURCE_DIR/package/h5000m-kit/files/etc/init.d/"* 2>/dev/null || true
  chmod 755 "$ROOT_DIR/$SOURCE_DIR/package/h5000m-kit/files/etc/hotplug.d/"*/* 2>/dev/null || true
  chmod 755 "$ROOT_DIR/$SOURCE_DIR/package/h5000m-kit/files/bin/"* 2>/dev/null || true
  chmod 755 "$ROOT_DIR/$SOURCE_DIR/package/h5000m-kit/files/usr/bin/"* 2>/dev/null || true
  chmod 755 "$ROOT_DIR/$SOURCE_DIR/package/h5000m-kit/files/usr/libexec/qscan/"* 2>/dev/null || true
  chmod 755 "$ROOT_DIR/$SOURCE_DIR/package/h5000m-kit/files/usr/share/sms_forwarder/"* 2>/dev/null || true
}

# ---------------------------------------------------------------- 内核配置
#
# 这些是 Linux 6.12 PHY Kconfig 符号，不属于 OpenWrt 顶层 .config。
# 必须写入 target/linux/mediatek/filogic/config-6.12；只把
# CONFIG_* 放进顶层 .config 对 kernel syncconfig 没有任何作用，仍会在
# syncconfig 时出现 [NEW] 交互提示并在 CI 中失败。
seed_kernel_config() {
  local cfg="target/linux/mediatek/filogic/config-${KERNEL_PATCHVER}"
  [ -f "$cfg" ] || die "找不到 Mediatek kernel config：$cfg"

  # 取值按本次 25.12-dev-wifi7 的 Kconfig 提示和现有 H5000M
  # filogic fragment 固定；不需要的通用 PHY 明确关闭，避免 NEW prompt。
  local entries=(
    'CONFIG_AIROHA_AN8801_PHY is not set'
    'CONFIG_AIROHA_EN8801SC_PHY=y'
    'CONFIG_AIR_AN8811HB_PHY is not set'
    'CONFIG_AIR_AN8855_PHY=y'
    'CONFIG_AIR_EN8811H_PHY=m'
    'CONFIG_AMD_PHY is not set'
    'CONFIG_ADIN_PHY is not set'
    'CONFIG_ADIN1100_PHY is not set'
    'CONFIG_AQUANTIA_PHY is not set'
    'CONFIG_AX88796B_PHY is not set'
    'CONFIG_BROADCOM_PHY is not set'
    'CONFIG_BCM54140_PHY is not set'
    'CONFIG_BCM7XXX_PHY is not set'
    'CONFIG_BCM84881_PHY is not set'
    'CONFIG_BCM87XX_PHY is not set'
    'CONFIG_CICADA_PHY is not set'
    'CONFIG_CORTINA_PHY is not set'
    'CONFIG_DAVICOM_PHY is not set'
    'CONFIG_ICPLUS_PHY=y'
    'CONFIG_LXT_PHY is not set'
    'CONFIG_INTEL_XWAY_PHY is not set'
    'CONFIG_LSI_ET1011C_PHY is not set'
    'CONFIG_MARVELL_PHY is not set'
    'CONFIG_MARVELL_10G_PHY is not set'
    'CONFIG_MARVELL_88Q2XXX_PHY is not set'
    'CONFIG_MARVELL_88X2222_PHY is not set'
    'CONFIG_MAXLINEAR_GPHY=y'
    'CONFIG_MEDIATEK_GE_PHY=y'
    'CONFIG_MEDIATEK_GE_SOC_PHY=y'
    'CONFIG_MEDIATEK_2P5GE_PHY is not set'
  )

  local e sym
  for e in "${entries[@]}"; do
    sym="${e%%=*}"
    sym="${sym%% *}"
    # Remove an existing assignment for this exact symbol, then append one.
    # This makes the operation idempotent across cached/reused source trees.
    grep -v -E "^(# )?${sym}(=.*| is not set)$" "$cfg" > "${cfg}.tmp"
    mv "${cfg}.tmp" "$cfg"
    if [[ "$e" == *" is not set" ]]; then
      printf '# %s\n' "$e" >> "$cfg"
    else
      printf '%s\n' "$e" >> "$cfg"
    fi
  done
  log "  kernel PHY Kconfig 已写入 $cfg（非交互）"
}

# ---------------------------------------------------------------- 配置
configure() {
  log "生成 .config"
  cd "$ROOT_DIR/$SOURCE_DIR"
  [ -f "$CONFIG_FILE" ] || die "配置文件不存在：$CONFIG_FILE"
  cp -f "$CONFIG_FILE" .config
  make defconfig || die "make defconfig 失败"
  echo "---- 关键项 ----"
  grep -E '^CONFIG_(TARGET_mediatek_filogic_DEVICE_hiveton_h5000m|MTK_WIFI7_SKU_TYPE|WARP_CHIPSET|PACKAGE_(kmod-mt7992|kmod-mt_hwifi|kmod-mt_wifi7|kmod-mediatek_hnat|luci-app-mtwifi-cfg|mtwifi-cfg-ucode|h5000m-kit|luci-app-openclash|luci-app-qmodem-next))=' .config || true
}

# ---------------------------------------------------------------- 编译
build() {
  cd "$ROOT_DIR/$SOURCE_DIR"
  log "编译（${THREADS} 线程）"
  export CCACHE_DIR="${CCACHE_DIR:-$ROOT_DIR/$SOURCE_DIR/build_dir/ccache}"
  make -j"$THREADS" IGNORE_ERRORS=n || make -j1 V=s
}

collect_artifacts() {
  log "收集产物"
  cd "$ROOT_DIR"
  rm -rf "$ARTIFACTS_DIR"; mkdir -p "$ARTIFACTS_DIR"
  find "$SOURCE_DIR/bin/targets" -type f \( -name '*.bin' -o -name '*.img.gz' \) -exec cp -f {} "$ARTIFACTS_DIR/" \;
  find "$SOURCE_DIR/bin/targets" -type f -name '*hiveton*h5000m*.manifest' -exec cp -f {} "$ARTIFACTS_DIR/openwrt-image.manifest" \; -quit
  [ -n "$(ls -A "$ARTIFACTS_DIR" 2>/dev/null)" ] || die "没找到固件产物"
  cp -f "$SOURCE_DIR/.config" "$ARTIFACTS_DIR/build.config"
  grep '^CONFIG_PACKAGE_.*=y$' "$SOURCE_DIR/.config" | sort > "$ARTIFACTS_DIR/enabled-packages.txt"
  find "$ARTIFACTS_DIR" -maxdepth 1 -type f \( -name '*.bin' -o -name '*.img.gz' \) -print0 \
    | xargs -0 -r sha256sum > "$ARTIFACTS_DIR/sha256sums.txt"
  { echo "ImmortalWrt 25.12 + MTK Wi-Fi7 SDK H5000M"; echo "time: $(date '+%F %T')"; echo "src: $REPO_URL ($REPO_BRANCH)"; } > "$ARTIFACTS_DIR/MANIFEST.txt"
  tar -czf artifacts.tar.gz "$ARTIFACTS_DIR"
  ls -lh "$ARTIFACTS_DIR"
}

main() {
  cd "$ROOT_DIR"
  command -v make >/dev/null || die "缺少 make"
  prepare_source
  prepare_feeds
  apply_patches
  seed_kernel_config
  stage_kit
  configure
  if [ "$CONFIG_ONLY" = "true" ]; then log "--config-only：到此为止"; exit 0; fi
  build
  collect_artifacts
}

main "$@"
