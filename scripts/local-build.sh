#!/usr/bin/env bash
# =============================================================================
# Hiveton H5000M —— ImmortalWrt 25.12 + MTK Wi-Fi 7 SDK 构建脚本
#
# 基座：chasey-dev/immortalwrt-mt798x-rebase @ 25.12-dev-wifi7
#       = ImmortalWrt 25.12（openwrt-25.12，内核 6.12，apk 包管理器）
#         + MTK OpenWrt Feeds 补丁（闭源 mt_wifi7 / mt_hwifi / warp / HNAT）
#       H5000M 设备支持（dts + Device/hiveton_h5000m）就在树内。
#
# 与 main 分支（padavanonly 24.10 + 内核 6.6）的差异：
#   * 内核 6.6 → 6.12、包管理器 opkg → apk（脚本内不依赖任何包管理器）
#   * MTK SDK 的 Kconfig 符号名变了（RRO_MODE/OPTION_TYPE 4/0 → 5/5，新增
#     MEM_SHRINK / WARP_BM_SHRINK_RING 等），这些符号集中在
#     config/h5000m-25.12.seed 里，跟着 SDK 版本走
#   * 设备名从 hiveton-h5000m 变成 hiveton_h5000m（下划线）
#   * 24.10 基座里我们自己打的 mtwifi 补丁（apcli bssid / sta_mgmt_assoc /
#     wifi-utility rbus）在本分支的 r8 SDK 里已被上游吸收或路径变更，
#     本脚本不再打这些补丁 —— 若实机发现同样症状再按新路径补
#   * 内核 pwm-fan 补丁与 DTS boot-duty 补丁仍然适用（6.12 上下文一致）
# =============================================================================
# 用法（与旧脚本一致）：
#   scripts/local-build.sh [--config-only|--prepare-only|--install-deps|
#                           --skip-toolchain|--skip-download|--skip-feeds-update]
# 功能开关仍从环境变量读（ENABLE_OPENCLASH / ENABLE_QMODEM / ...），
# 便于 workflow 与 coverage-test 复用。
# =============================================================================
set -Euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_URL="${REPO_URL:-https://github.com/chasey-dev/immortalwrt-mt798x-rebase}"
REPO_BRANCH="${REPO_BRANCH:-25.12-dev-wifi7}"
SOURCE_DIR="${SOURCE_DIR:-immortalwrt}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"
SEED_CONFIG="${SEED_CONFIG:-$ROOT_DIR/config/h5000m-25.12.seed}"
EXTRA_CONFIG="${EXTRA_CONFIG:-$ROOT_DIR/h5000m.extra.config}"
KERNEL_PATCHVER="${KERNEL_PATCHVER:-6.12}"

THREADS="${THREADS:-$(nproc 2>/dev/null || echo 2)}"
GIT_TIMEOUT="${GIT_TIMEOUT:-1800}"
FEEDS_TIMEOUT="${FEEDS_TIMEOUT:-3600}"
CONFIG_TIMEOUT="${CONFIG_TIMEOUT:-1800}"
DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-7200}"
TOOLCHAIN_TIMEOUT="${TOOLCHAIN_TIMEOUT:-21600}"
COMPILE_TIMEOUT="${COMPILE_TIMEOUT:-28800}"
GIT_DEPTH="${GIT_DEPTH:-1}"
DOWNLOAD_MIRROR="${DOWNLOAD_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/openwrt/sources;https://mirrors.ustc.edu.cn/openwrt/sources;https://mirrors.bfsu.edu.cn/openwrt/sources}"
GITHUB_PROXY_PREFIXES="${GITHUB_PROXY_PREFIXES:-https://ghfast.top/ https://gh-proxy.com/ https://gh.llkk.cc/}"
export DOWNLOAD_MIRROR
export MAKEFLAGS="-j${THREADS}"

# ---- 功能开关（默认与 CI 一致）---------------------------------------------
ENABLE_OPENCLASH="${ENABLE_OPENCLASH:-true}"
ENABLE_QMODEM="${ENABLE_QMODEM:-true}"
ENABLE_QMODEM_NEXT="${ENABLE_QMODEM_NEXT:-true}"
ENABLE_QMODEM_LUA="${ENABLE_QMODEM_LUA:-false}"
# 这些开关在 25.12 基座里没有对应包，保留变量只为兼容旧 workflow 的 inputs
ENABLE_ADGUARDHOME="${ENABLE_ADGUARDHOME:-false}"
ENABLE_NIKKI="${ENABLE_NIKKI:-false}"
ENABLE_UPNP="${ENABLE_UPNP:-false}"
ENABLE_VLMCSD="${ENABLE_VLMCSD:-false}"
ENABLE_MOSDNS="${ENABLE_MOSDNS:-false}"
ENABLE_DOCKERMAN="${ENABLE_DOCKERMAN:-false}"
ENABLE_HOMEPROXY="${ENABLE_HOMEPROXY:-false}"
ENABLE_ADBLOCK="${ENABLE_ADBLOCK:-false}"
ENABLE_ORIGINAL_MODEM="${ENABLE_ORIGINAL_MODEM:-false}"

INSTALL_DEPS=false
PREPARE_ONLY="${PREPARE_ONLY:-false}"
CONFIG_ONLY="${CONFIG_ONLY:-false}"
SKIP_TOOLCHAIN="${SKIP_TOOLCHAIN:-false}"
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-false}"
SKIP_FEEDS_UPDATE="${SKIP_FEEDS_UPDATE:-false}"

usage() {
  cat <<'EOF'
Usage: scripts/local-build.sh [options]

Options:
  --install-deps        Install Ubuntu/Debian build dependencies with apt-get.
  --prepare-only        Clone source, feeds, patches, kit and config only.
  --config-only         Stop after make defconfig and package verification.
  --skip-toolchain      Skip explicit toolchain prebuild step.
  --skip-download       Skip make download prefetch step.
  --skip-feeds-update   Skip ./scripts/feeds update -a (reuse existing checkouts).
  -h, --help            Show this help.

Env: REPO_URL REPO_BRANCH SOURCE_DIR THREADS ENABLE_OPENCLASH ENABLE_QMODEM ...
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-deps) INSTALL_DEPS=true ;;
    --prepare-only) PREPARE_ONLY=true ;;
    --config-only) CONFIG_ONLY=true ;;
    --skip-toolchain) SKIP_TOOLCHAIN=true ;;
    --skip-download) SKIP_DOWNLOAD=true ;;
    --skip-feeds-update) SKIP_FEEDS_UPDATE=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

log()  { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '\n[%s] WARNING: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
# GitHub Actions 注解通道：`::error::xxx` 会被 GitHub 记成 annotation，
# 而 annotations 是**匿名可读**的（/check-runs/<job>/annotations）——CI 失败时
# 不必翻日志就能拿到确切原因。
emit_ann() { printf '::error::%s\n' "$*" >&2; }
die()  { emit_ann "H5000M: $*"; printf '\nERROR: %s\n' "$*" >&2; exit 1; }
is_true() { case "${1:-}" in 1|true|TRUE|yes|YES|on) return 0 ;; *) return 1 ;; esac; }
trap 'rc=$?; [ "$rc" -eq 0 ] || printf "::warning::local-build.sh: step failed at line %s (rc=%s): %s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2' ERR

run_with_timeout() {
  local t="$1" label="$2"; shift 2
  log "$label (timeout ${t}s)"
  if timeout --foreground "$t" "$@"; then return 0; fi
  warn "$label failed or timed out"
  return 1
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

install_deps() {
  log "Installing build dependencies"
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends \
    build-essential ack antlr3 asciidoc autoconf automake autopoint binutils bison \
    bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar flex gawk \
    gettext gcc-multilib g++-multilib git gnutls-dev gperf haveged help2man intltool perl \
    lib32gcc-s1 libc6-dev-i386 libelf-dev libfuse-dev libglib2.0-dev libgmp3-dev \
    libltdl-dev libmbedtls-dev libmpc-dev libmpfr-dev libncurses5-dev libncursesw5-dev \
    libpython3-dev libreadline-dev libssl-dev libtool lld llvm lrzsz mkisofs msmtp \
    nano ninja-build p7zip p7zip-full patch pkgconf python3 python3-pip python3-ply \
    python3-pyelftools python3-setuptools qemu-utils re2c rsync scons squashfs-tools \
    subversion swig texinfo uglifyjs unzip upx-ucl vim wget xmlto xxd zlib1g-dev \
    rustc cargo golang-go zstd file
}

check_environment() {
  log "Checking build environment"
  for c in git curl patch make gcc; do require_cmd "$c"; done
  local free_kb
  free_kb=$(df -Pk "$ROOT_DIR" | awk 'NR==2{print $4}')
  [ "$free_kb" -ge 12000000 ] || warn "less than ~12GB free disk ($((free_kb/1024))MB); the build may run out of space"
  echo "repo   : $REPO_URL ($REPO_BRANCH)"
  echo "threads: $THREADS"
  echo "kernel : $KERNEL_PATCHVER"
}

github_url_candidates() { echo "$1"; for p in $GITHUB_PROXY_PREFIXES; do echo "${p%/}/$1"; done; }

git_clone_retry() {  # <url> <branch> <dest>
  local url="$1" branch="$2" dest="$3" u
  for u in $(github_url_candidates "$url"); do
    rm -rf "$dest"
    if run_with_timeout "$GIT_TIMEOUT" "git clone $u($branch)" \
        git clone --depth "$GIT_DEPTH" --single-branch --branch "$branch" "$u" "$dest"; then
      return 0
    fi
  done
  return 1
}

curl_fetch_retry() {  # <url> <dest>
  local url="$1" dest="$2" attempt
  for attempt in 1 2 3; do
    if curl -fsSL --retry 3 --connect-timeout 20 -o "$dest" "$url" && [ -s "$dest" ]; then
      return 0
    fi
    sleep 3
  done
  return 1
}

# ------------------------------------------------------------------ 源码 / feeds
prepare_source() {
  log "Preparing ImmortalWrt 25.12 source tree"
  cd "$ROOT_DIR"
  if [ -d "$SOURCE_DIR/.git" ]; then
    local cur
    cur=$(git -C "$SOURCE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    git -C "$SOURCE_DIR" fetch --depth "$GIT_DEPTH" origin "$REPO_BRANCH" || warn "git fetch failed; using existing checkout"
    if git -C "$SOURCE_DIR" rev-parse --verify -q FETCH_HEAD >/dev/null 2>&1; then
      git -C "$SOURCE_DIR" checkout -q -B "$REPO_BRANCH" FETCH_HEAD || true
    fi
    echo "existing checkout branch: ${cur:-unknown}"
  else
    git_clone_retry "$REPO_URL" "$REPO_BRANCH" "$SOURCE_DIR" || die "unable to clone $REPO_URL"
  fi
  [ -f "$SOURCE_DIR/rules.mk" ] || die "$SOURCE_DIR does not look like an OpenWrt tree"
  grep -q "KERNEL_PATCHVER:=${KERNEL_PATCHVER}" "$SOURCE_DIR/target/linux/mediatek/Makefile" \
    || warn "target/linux/mediatek/Makefile does not advertise kernel ${KERNEL_PATCHVER}"
  echo "source HEAD: $(git -C "$SOURCE_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
}

prepare_feeds() {
  log "Preparing feeds"
  cd "$ROOT_DIR/$SOURCE_DIR"
  cp -f "$ROOT_DIR/feeds.conf.default" feeds.conf.default

  if ! is_true "$ENABLE_QMODEM"; then
    sed -i '/src-git qmodem/d; /qmodem/d' feeds.conf.default
    rm -rf feeds/qmodem package/feeds/qmodem 2>/dev/null || true
  fi

  if ! is_true "$SKIP_FEEDS_UPDATE"; then
    find feeds -mindepth 1 -maxdepth 1 -type d -exec sh -c 'git -C "$1" clean -qfd 2>/dev/null || true' _ {} \; 2>/dev/null || true
    run_with_timeout "$FEEDS_TIMEOUT" "feeds update -a" ./scripts/feeds update -a \
      || die "feeds update failed"
  else
    log "Skipping feeds update (per --skip-feeds-update)"
  fi

  # 所有 feed 包都建立链接：qmodem 的菜单选项（含 PACKAGE_qmodem_* 子选项）
  # 只有 install 之后 make defconfig 才能看到。
  run_with_timeout "$FEEDS_TIMEOUT" "feeds install -a" ./scripts/feeds install -a -f \
    || warn "feeds install -a reported errors; verifying explicitly requested packages below"

  if is_true "$ENABLE_QMODEM"; then
    [ -d feeds/qmodem ] || die "QModem feed is missing (feeds/qmodem)"
  fi
  if is_true "$ENABLE_OPENCLASH"; then
    [ -d package/feeds/luci/luci-app-openclash ] || [ -d feeds/luci/applications/luci-app-openclash ] \
      || warn "luci-app-openclash not found in luci feed (openwrt-25.12)"
  fi
}

# ------------------------------------------------------------------ 家当 / 补丁
stage_h5000m_kit() {
  log "Staging h5000m-kit package"
  [ -d "$ROOT_DIR/h5000m-kit" ] || die "h5000m-kit not found in repo"
  rm -rf "$ROOT_DIR/$SOURCE_DIR/package/h5000m-kit"
  cp -a "$ROOT_DIR/h5000m-kit" "$ROOT_DIR/$SOURCE_DIR/package/h5000m-kit"
  # uci-defaults 必须可执行，否则整包静默失效（踩过一次）
  chmod 755 "$ROOT_DIR/$SOURCE_DIR/package/h5000m-kit/files/etc/uci-defaults/"* 2>/dev/null || true
  chmod 755 "$ROOT_DIR/$SOURCE_DIR/package/h5000m-kit/files/etc/init.d/"* 2>/dev/null || true
  chmod 755 "$ROOT_DIR/$SOURCE_DIR/package/h5000m-kit/files/etc/hotplug.d/"*/* 2>/dev/null || true
  chmod 755 "$ROOT_DIR/$SOURCE_DIR/package/h5000m-kit/files/bin/"* 2>/dev/null || true
  chmod 755 "$ROOT_DIR/$SOURCE_DIR/package/h5000m-kit/files/usr/bin/"* 2>/dev/null || true
  chmod 755 "$ROOT_DIR/$SOURCE_DIR/package/h5000m-kit/files/usr/libexec/qscan/"* 2>/dev/null || true
  chmod 755 "$ROOT_DIR/$SOURCE_DIR/package/h5000m-kit/files/usr/share/sms_forwarder/"* 2>/dev/null || true
}

stage_fan_kernel_patch() {
  local p="$ROOT_DIR/patches/999-h5000m-pwm-fan-boot-duty.kernel-patch"
  local d="$ROOT_DIR/$SOURCE_DIR/target/linux/mediatek/patches-${KERNEL_PATCHVER}"
  [ -f "$p" ] || { warn "fan kernel patch missing at $p"; return 0; }
  mkdir -p "$d"
  cp -a "$p" "$d/999-h5000m-pwm-fan-boot-duty.patch"
  log "Staged 999-h5000m-pwm-fan-boot-duty.patch into patches-${KERNEL_PATCHVER}"
}

apply_tree_patch() {  # <patch file> <label>
  local f="$1" label="$2"
  [ -f "$f" ] || { warn "$label patch missing ($f)"; return 0; }
  if patch -p1 --forward --dry-run < "$f" >/dev/null 2>&1; then
    patch -p1 --forward < "$f" >/dev/null && log "Applied $label"
  elif patch -p1 --forward --reverse --dry-run < "$f" >/dev/null 2>&1; then
    log "$label already applied"
  else
    warn "unable to apply $label (upstream file changed?)"
  fi
}

patch_h5000m_fan_dts() {
  cd "$ROOT_DIR/$SOURCE_DIR"
  apply_tree_patch "$ROOT_DIR/patches/dts-h5000m-fan-boot-duty.patch" "H5000M fan boot-duty DTS"
}

patch_qmodem_voip_libwebsockets_variant() {
  local feed="$ROOT_DIR/$SOURCE_DIR/feeds/qmodem"
  local mk="$feed/application/voipd/Makefile"
  [ -f "$mk" ] || { warn "QModem voipd Makefile not found; skipping libwebsockets fix"; return 0; }
  if grep -qE 'PACKAGE_libwebsockets-full:libwebsockets-full|libwebsockets-full' "$mk"; then
    log "QModem voipd already handles libwebsockets-full; nothing to patch"
    return 0
  fi
  sed -i 's/+libwebsockets-mbedtls/+libwebsockets-full/' "$mk" 2>/dev/null || true
  sed -i 's/+libwebsockets-openssl/+libwebsockets-full/' "$mk" 2>/dev/null || true
  if grep -q 'libwebsockets-full' "$mk"; then
    log "Patched QModem voipd to use libwebsockets-full"
  else
    warn "QModem voipd libwebsockets dependency unknown; leaving as-is"
  fi
}

patch_qmodem_sipd_pjproject_compat() {
  local f="$ROOT_DIR/$SOURCE_DIR/feeds/qmodem/application/qmodem_sipd/src/sip_consumer.c"
  [ -f "$f" ] || { warn "QModem sipd source not found; skipping pjproject compat"; return 0; }
  if ! grep -q 'algorithm_type' "$f"; then
    log "QModem sipd no longer uses algorithm_type; patch not needed"
    return 0
  fi
  # 上游 pjproject 2.14 去掉了该字段 → 用默认算法
  sed -i 's/\balgorithm_type\b/0/g' "$f" && log "Patched QModem sipd for pjproject 2.14"
}

# 模组上报的短信 timestamp 是"本地墙上时间当 UTC"（比真实 epoch 大 28800s）。
# QModem 上游只在前端做 -28800，转发脚本没修 → 这里直接补进 feed 源码。
patch_qmodem_sms_tz() {
  local f="$ROOT_DIR/$SOURCE_DIR/feeds/qmodem/application/sms_forwarder_next/files/sms_forwarder_next"
  [ -f "$f" ] || { warn "sms_forwarder_next not found in QModem feed; SMS timezone fix skipped"; return 0; }
  if grep -q 'SMS_TZ_FIX' "$f"; then log "sms_forwarder_next timezone fix already applied"; return 0; fi
  if grep -q 'date -d @\${timestamp}' "$f"; then
    sed -i 's|date -d @${timestamp}|date -d @$((timestamp - 28800))|g' "$f"
    log "Applied +8h timezone fix to sms_forwarder_next"
  else
    warn "sms_forwarder_next time format pattern not found (QModem changed?); SMS timestamps may be 8h off"
  fi
}

ensure_no_duplicate_qmi_driver() {
  cd "$ROOT_DIR/$SOURCE_DIR"
  # QModem 的 driver/quectel_QMI_WWAN 与 immortalwrt/packages 的 quectel-qmi-wwan
  # 都会生成 qmi_wwan_q.ko —— 同时启用会在安装阶段撞名。
  if grep -q '^CONFIG_PACKAGE_kmod-qmi_wwan_q=y$' .config \
     && grep -q '^CONFIG_PACKAGE_kmod-usb-net-qmi-wwan-quectel=y$' .config; then
    die "both kmod-qmi_wwan_q (QModem) and kmod-usb-net-qmi-wwan-quectel (packages) are enabled; drop the latter"
  fi
}

# luci-app-mtwifi-cfg（MTK 无线 LuCI 页）在 25.12 里还带着两个**已经不存在的**
# 依赖：rpcd-mod-ucode / rpcd-mod-iwinfo（25.12 把这两个模块并进了 rpcd 本体与
# iwinfo-ucode 包）。不去掉的话该包的依赖永远不满足，kconfig 会静默丢弃它，
# 无线页面就没了。页面自身的 RPC 后端是它自带的 usr/share/rpcd/ucode/luci.mtwifi。
patch_mtwifi_luci_deps() {
  local f="$ROOT_DIR/$SOURCE_DIR/package/mtk/applications/luci-app-mtwifi-cfg/Makefile"
  [ -f "$f" ] || { warn "luci-app-mtwifi-cfg Makefile not found; skipping dep fix"; return 0; }
  if grep -q 'rpcd-mod-ucode\|rpcd-mod-iwinfo' "$f"; then
    sed -i 's/ +rpcd-mod-ucode//g; s/ +rpcd-mod-iwinfo//g; s/+rpcd-mod-ucode//g; s/+rpcd-mod-iwinfo//g' "$f"
    log "luci-app-mtwifi-cfg: dropped dead deps (rpcd-mod-ucode/rpcd-mod-iwinfo 在 25.12 已并入 rpcd/iwinfo-ucode)"
  else
    log "luci-app-mtwifi-cfg deps already clean"
  fi
}

apply_patches() {
  log "Applying H5000M patches"
  cd "$ROOT_DIR/$SOURCE_DIR"
  stage_fan_kernel_patch
  patch_h5000m_fan_dts
  patch_mtwifi_luci_deps
  if is_true "$ENABLE_QMODEM"; then
    patch_qmodem_voip_libwebsockets_variant
    patch_qmodem_sipd_pjproject_compat
    patch_qmodem_sms_tz
  fi
}

# ------------------------------------------------------------------ 配置
config_enforce_block() {
  cat <<'EOF'
# ---- H5000M 25.12 + MTK Wi-Fi7 SDK 强制项（由 local-build.sh 注入）---------
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_hiveton_h5000m=y
CONFIG_PACKAGE_kmod-hwmon-pwmfan=y
CONFIG_PACKAGE_kmod-mediatek_hnat=y
CONFIG_PACKAGE_kmod-warp=y
CONFIG_PACKAGE_kmod-mt_wifi7=y
CONFIG_PACKAGE_kmod-mt_hwifi=y
CONFIG_PACKAGE_kmod-mt7992=y
CONFIG_PACKAGE_mtwifi-cfg-ucode=y
CONFIG_PACKAGE_luci-app-mtwifi-cfg=y
CONFIG_PACKAGE_luci-app-turboacc-mtk=y
CONFIG_PACKAGE_wifi-profile=y
CONFIG_PACKAGE_wpad-openssl=y
CONFIG_MTK_HWIFI_MT7992=y
CONFIG_MTK_HWIFI_WED_SUPPORT=y
CONFIG_MTK_WIFI7_CHIP_MT7992=y
CONFIG_MTK_WIFI7_SKU_TYPE="BE6500"
CONFIG_WARP_CHIPSET="mt7987"
CONFIG_first_card=y
CONFIG_first_card_name="MT7992"
CONFIG_first_card_main_ifname="ra0;rai0"
CONFIG_PACKAGE_h5000m-kit=y
CONFIG_PACKAGE_dnsmasq-full=y
CONFIG_PACKAGE_luci-compat=y
CONFIG_PACKAGE_ruby=y
CONFIG_PACKAGE_ruby-yaml=y
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_kmod-nft-tproxy=y
CONFIG_PACKAGE_kmod-inet-diag=y
CONFIG_PACKAGE_kmod-usb-net-qmi-wwan=y
CONFIG_USE_APK=y
EOF
}

configure_build() {
  log "Generating .config from seed + extra config"
  cd "$ROOT_DIR/$SOURCE_DIR"
  [ -f "$SEED_CONFIG" ] || die "seed config missing: $SEED_CONFIG"
  [ -f "$EXTRA_CONFIG" ] || die "extra config missing: $EXTRA_CONFIG"

  cp "$SEED_CONFIG" .config
  cat "$EXTRA_CONFIG" >> .config
  config_enforce_block >> .config

  if is_true "$ENABLE_OPENCLASH"; then
    echo "CONFIG_PACKAGE_luci-app-openclash=y" >> .config
  else
    echo "# CONFIG_PACKAGE_luci-app-openclash is not set" >> .config
  fi
  if is_true "$ENABLE_QMODEM"; then
    echo "CONFIG_PACKAGE_qmodem=y" >> .config
    is_true "$ENABLE_QMODEM_NEXT" && echo "CONFIG_PACKAGE_luci-app-qmodem-next=y" >> .config
    echo "CONFIG_PACKAGE_kmod-usb-serial-option=y" >> .config
  else
    echo "# CONFIG_PACKAGE_qmodem is not set" >> .config
  fi

  run_with_timeout "$CONFIG_TIMEOUT" "make defconfig (pass 1)" make defconfig || die "make defconfig failed"

  # defconfig 可能丢弃了"不存在/依赖不满足"的符号：把强制项再补一遍，
  # 让 make defconfig 的依赖求解器去处理（它知道 symbol 的真实名字）。
  local pass=2
  while [ "$pass" -le 3 ]; do
    local missing=()
    while IFS= read -r sym; do
      [ -n "$sym" ] || continue
      grep -qx "$sym" .config || missing+=("$sym")
    done < <(config_enforce_block | grep '^CONFIG_.*=y$')
    if [ "${#missing[@]}" -eq 0 ]; then break; fi
    warn "defconfig dropped ${#missing[@]} symbol(s); re-applying (pass $pass): ${missing[*]}"
    printf '%s\n' "${missing[@]}" >> .config
    run_with_timeout "$CONFIG_TIMEOUT" "make defconfig (pass $pass)" make defconfig || die "make defconfig failed (pass $pass)"
    pass=$((pass + 1))
  done

  ensure_no_duplicate_qmi_driver
  verify_final_config

  printf '\n===== 关键配置 =====\n'
  grep -E '^CONFIG_(TARGET_mediatek_filogic_DEVICE_hiveton_h5000m|MTK_WIFI7_SKU_TYPE|WARP_CHIPSET|first_card_main_ifname|PACKAGE_(h5000m-kit|luci-app-qmodem-next|luci-app-openclash|kmod-mt7992|kmod-mt_hwifi|kmod-mt_wifi7|kmod-mediatek_hnat|kmod-warp|luci-app-turboacc-mtk|kmod-hwmon-pwmfan|kmod-qmi_wwan_q|quectel-CM-5G-M|kmod-usb-net-qmi-wwan|wpad-openssl|dnsmasq-full))=' .config | sort
}

# 失败诊断：把某符号在 kconfig 里的 depends/select 块压成一行，便于走 annotation。
symbol_kconfig_deps() {  # <CONFIG_SYMBOL>
  local sym="${1#CONFIG_}" f="tmp/.config-package.in"
  [ -f "$f" ] || { echo "(no .config-package.in)"; return 0; }
  awk -v s="config $sym" '$0==s{found=1} found{print} found&&/^$/{exit}' "$f" \
    | tr '\n' ';' | sed 's/; */;/g' | cut -c1-500
}

# 配置失败的根因诊断（结果走 annotation，CI 里匿名可读，不必翻日志）
diag_env() {
  emit_ann "diag: pwd=$PWD"
  emit_ann "diag: tmp/.config-package.in exists=$([ -f tmp/.config-package.in ] && echo yes || echo no) size=$(wc -c < tmp/.config-package.in 2>/dev/null || echo 0)"
  emit_ann "diag: 'mtwifi' hits in .config-package.in = $(grep -c 'mtwifi' tmp/.config-package.in 2>/dev/null || echo 0)"
  emit_ann "diag: 'mtwifi' hits in tmp/.packagedeps = $(grep -c 'mtwifi' tmp/.packagedeps 2>/dev/null || echo 0)"
  emit_ann "diag: 'package/mtk' hits in tmp/.packagedeps = $(grep -c 'package/mtk' tmp/.packagedeps 2>/dev/null || echo 0)"
  emit_ann "diag: feeds/luci/luci.mk=$([ -f feeds/luci/luci.mk ] && echo yes || echo no)"
  emit_ann "diag: mtwifi-cfg-ucode Makefile dep line = $(grep -m1 'DEPENDS' package/mtk/applications/mtwifi-cfg-ucode/Makefile 2>/dev/null || echo NA)"
  emit_ann "diag: luci-app-mtwifi-cfg dep line = $(grep -m1 'LUCI_DEPENDS' package/mtk/applications/luci-app-mtwifi-cfg/Makefile 2>/dev/null || echo NA)"
  emit_ann "diag: turboacc block = $(awk '/^config PACKAGE_luci-app-turboacc-mtk$/{f=1} f{print} f&&/^$/{exit}' tmp/.config-package.in 2>/dev/null | tr '\n' ';' | cut -c1-300)"
  emit_ann "diag: iwinfo-ucode pkg name = $(grep -m2 -E 'define Package/' package/network/utils/iwinfo-ucode/Makefile 2>/dev/null | tr '\n' ' ' || echo NA)"
  emit_ann "diag: datconf pkg name = $(grep -m2 -E 'define Package/' package/mtk/applications/datconf/Makefile 2>/dev/null | tr '\n' ' ' || echo NA)"
  emit_ann "diag: l1parser pkg name = $(grep -m2 -E 'define Package/' package/mtk/applications/l1parser/Makefile 2>/dev/null | tr '\n' ' ' || echo NA)"
  emit_ann "diag: ucode-mod-datconf in .config = $(grep -c 'ucode-mod-datconf' .config 2>/dev/null || echo 0)"
}

verify_final_config() {
  cd "$ROOT_DIR/$SOURCE_DIR"
  local required=(
    'CONFIG_TARGET_mediatek_filogic_DEVICE_hiveton_h5000m=y'
    'CONFIG_PACKAGE_kmod-hwmon-pwmfan=y'
    'CONFIG_PACKAGE_kmod-mt_wifi7=y'
    'CONFIG_PACKAGE_kmod-mt_hwifi=y'
    'CONFIG_PACKAGE_kmod-mt7992=y'
    'CONFIG_PACKAGE_kmod-mediatek_hnat=y'
    'CONFIG_PACKAGE_kmod-warp=y'
    'CONFIG_PACKAGE_luci-app-turboacc-mtk=y'
    'CONFIG_PACKAGE_luci-app-mtwifi-cfg=y'
    'CONFIG_PACKAGE_mtwifi-cfg-ucode=y'
    'CONFIG_PACKAGE_wifi-profile=y'
    'CONFIG_MTK_HWIFI_MT7992=y'
    'CONFIG_MTK_HWIFI_WED_SUPPORT=y'
    'CONFIG_MTK_WIFI7_SKU_TYPE="BE6500"'
    'CONFIG_WARP_CHIPSET="mt7987"'
    'CONFIG_first_card_main_ifname="ra0;rai0"'
    'CONFIG_PACKAGE_h5000m-kit=y'
    'CONFIG_PACKAGE_kmod-usb-net-qmi-wwan=y'
    'CONFIG_PACKAGE_kmod-usb-serial-option=y'
    'CONFIG_USE_APK=y'
  )
  is_true "$ENABLE_OPENCLASH" && required+=('CONFIG_PACKAGE_luci-app-openclash=y' 'CONFIG_PACKAGE_ruby-yaml=y')
  is_true "$ENABLE_QMODEM_NEXT" && required+=('CONFIG_PACKAGE_luci-app-qmodem-next=y' 'CONFIG_PACKAGE_qmodem=y')

  # 明确不能出现的（会抢 pwm1 / 换掉我们的 AT wrapper / 冲突驱动 / 两套 SDK 页）
  local forbidden=(
    'CONFIG_PACKAGE_luci-app-Airpifanctrl=y'
    'CONFIG_PACKAGE_luci-app-fancontrol-mtk=y'
    'CONFIG_PACKAGE_luci-app-mtk=y'
    'CONFIG_PACKAGE_luci-app-eqos-mtk=y'
    'CONFIG_PACKAGE_fancontrol=y'
    'CONFIG_PACKAGE_sendat=y'
    'CONFIG_PACKAGE_kmod-usb-net-qmi-wwan-quectel=y'
    'CONFIG_PACKAGE_luci-app-qmodem=y'
    'CONFIG_PACKAGE_kmod-mt7996e=y'
    'CONFIG_PACKAGE_kmod-mt7992-23-firmware=y'
  )

  # 一次报全部问题（别让 CI 每轮只暴露一个），并把依赖细节写进 annotation
  local missing=() problems=() s
  for s in "${required[@]}"; do
    grep -qx "$s" .config || missing+=("$s")
  done
  for s in "${forbidden[@]}"; do
    if grep -qx "$s" .config; then problems+=("FORBIDDEN $s"); fi
  done

  if [ "${#missing[@]}" -gt 0 ] || [ "${#problems[@]}" -gt 0 ]; then
    emit_ann "final config verification failed: ${#missing[@]} missing, ${#problems[@]} forbidden"
    local i=0
    for s in "${missing[@]:-}"; do
      [ -n "$s" ] || continue
      emit_ann "MISSING $s"
      # 依赖细节只给前 6 个符号，避免 annotation 数量超限
      if [ "$i" -lt 6 ]; then
        emit_ann "    deps: $(symbol_kconfig_deps "$s")"
      fi
      i=$((i + 1))
    done
    for s in "${problems[@]:-}"; do
      [ -n "$s" ] || continue
      emit_ann "PROBLEM $s"
    done
    diag_env
    die "final .config verification failed: ${missing[*]:-} ${problems[*]:-}"
  fi
}

# ------------------------------------------------------------------ 编译
prefetch_and_toolchain() {
  cd "$ROOT_DIR/$SOURCE_DIR"
  if ! is_true "$SKIP_DOWNLOAD"; then
    find dl -size -1024c -delete 2>/dev/null || true
    run_with_timeout "$DOWNLOAD_TIMEOUT" "make download" make -j"$THREADS" download \
      || warn "make download did not complete cleanly"
  fi
  if is_true "$SKIP_TOOLCHAIN"; then return 0; fi

  if [ -z "$(find build_dir/toolchain-* -maxdepth 3 -name gcc -type f 2>/dev/null | head -1)" ]; then
    log "Building host tools and target toolchain"
    run_with_timeout "$TOOLCHAIN_TIMEOUT" "make tools/install toolchain/install" \
      make -j"$THREADS" tools/install toolchain/install || die "toolchain build failed"
  else
    log "Toolchain build dir looks usable; reusing cache"
  fi
}

compile_firmware() {
  cd "$ROOT_DIR/$SOURCE_DIR"
  export CCACHE_DIR="${CCACHE_DIR:-$ROOT_DIR/$SOURCE_DIR/build_dir/ccache}"
  export CCACHE_SIZE="${CCACHE_SIZE:-10G}"
  mkdir -p "$CCACHE_DIR"
  local start end
  start=$(date +%s)
  if run_with_timeout "$COMPILE_TIMEOUT" "make firmware" make -j"$THREADS" IGNORE_ERRORS=n; then
    end=$(date +%s); echo "Build succeeded in $((end - start))s"
  else
    warn "parallel build failed; retrying single-threaded for diagnostics"
    run_with_timeout "$COMPILE_TIMEOUT" "make firmware -j1 V=s" make -j1 V=s
  fi
}

collect_artifacts() {
  log "Collecting artifacts"
  cd "$ROOT_DIR"
  rm -rf "$ARTIFACTS_DIR"; mkdir -p "$ARTIFACTS_DIR"
  find "$SOURCE_DIR/bin/targets" -type f \( -name '*.bin' -o -name '*.img.gz' \) -exec cp -f {} "$ARTIFACTS_DIR/" \;
  find "$SOURCE_DIR/bin/targets" -type f -name '*hiveton*h5000m*.manifest' -exec cp -f {} "$ARTIFACTS_DIR/openwrt-image.manifest" \; -quit
  [ -n "$(ls -A "$ARTIFACTS_DIR" 2>/dev/null)" ] || die "no firmware artifacts under $SOURCE_DIR/bin/targets"
  [ -f "$ARTIFACTS_DIR/openwrt-image.manifest" ] || die "H5000M image manifest was not generated"

  # 镜像清单里必须真的含有这些包（比只查 .config 更可信）
  local pkgs=(kmod-mt7992 kmod-mt_hwifi kmod-mt_wifi7 kmod-mediatek_hnat kmod-warp kmod-hwmon-pwmfan h5000m-kit luci-app-turboacc-mtk)
  is_true "$ENABLE_OPENCLASH" && pkgs+=(luci-app-openclash)
  is_true "$ENABLE_QMODEM_NEXT" && pkgs+=(luci-app-qmodem-next qmodem)
  local p
  for p in "${pkgs[@]}"; do
    grep -q "^${p}[[:space:]-]" "$ARTIFACTS_DIR/openwrt-image.manifest" \
      || die "image manifest is missing required package: $p"
  done

  {
    echo "ImmortalWrt 25.12 + MTK Wi-Fi7 SDK H5000M build (kernel 6.12 / apk)"
    echo "Build time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Source: $REPO_URL ($REPO_BRANCH)"
    echo
    echo "Artifacts:"
    (cd "$ARTIFACTS_DIR" && ls -lh | sed 's/^/  /')
  } > "$ARTIFACTS_DIR/MANIFEST.txt"

  cp -f "$SOURCE_DIR/.config" "$ARTIFACTS_DIR/build.config"
  grep '^CONFIG_PACKAGE_.*=y$' "$SOURCE_DIR/.config" | sort > "$ARTIFACTS_DIR/enabled-packages.txt"
  find "$ARTIFACTS_DIR" -maxdepth 1 -type f \( -name '*.bin' -o -name '*.img.gz' \) -print0 \
    | xargs -0 -r sha256sum > "$ARTIFACTS_DIR/sha256sums.txt"
  [ -s "$ARTIFACTS_DIR/sha256sums.txt" ] || die "no firmware checksums generated"
  tar -czf artifacts.tar.gz "$ARTIFACTS_DIR"
  ls -lh "$ARTIFACTS_DIR"
}

main() {
  cd "$ROOT_DIR"
  is_true "$INSTALL_DEPS" && install_deps
  check_environment
  echo "OpenClash=${ENABLE_OPENCLASH} QModem=${ENABLE_QMODEM} QModemNext=${ENABLE_QMODEM_NEXT}"
  prepare_source
  prepare_feeds
  stage_h5000m_kit
  apply_patches
  configure_build
  is_true "$PREPARE_ONLY" && { log "prepare-only requested; stopping"; exit 0; }
  is_true "$CONFIG_ONLY" && { log "config-only requested; stopping"; exit 0; }
  prefetch_and_toolchain
  compile_firmware
  collect_artifacts
}

main "$@"
