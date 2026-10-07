# ImmortalWrt H5000M 自动编译

[![Build](https://github.com/existyay/Auto-H5000M-BIN/actions/workflows/build-test.yml/badge.svg)](https://github.com/existyay/Auto-H5000M-BIN/actions/workflows/build-test.yml)

基于 [`padavanonly/immortalwrt-mt798x-24.10`](https://github.com/padavanonly/immortalwrt-mt798x-24.10) 的 `mt798x-mt799x-6.6-mtwifi` 分支，为 **Hiveton H5000M (MT7992 filogic)** 自动编译固件。

固件下载：[Releases](https://github.com/existyay/Auto-H5000M-BIN/releases)

| 项目 | 值 |
| --- | --- |
| 默认地址 | `192.168.6.1` / `immortalwrt.lan` |
| 用户名 | `root` |
| 密码 | `admin` |

---

## 仓库结构

```
.
├── .github/workflows/build-test.yml   # GitHub Actions 工作流 (调用 local-build.sh)
├── feeds.conf.default                 # OpenWrt feeds 配置
├── h5000m.extra.config              # 追加到 .config 的本机特定配置
├── patches/
│   ├── mtwifi-apcli-active-only.patch # MTK WiFi AP/APCLI active-only 持久补丁
│   └── mtk-hnat-local-dest.patch      # MTK HNAT 本地地址不卸载补丁（修复 WiFi 访问后台）
└── scripts/
    ├── local-build.sh                 # 本地/CI 共用的唯一构建入口
    ├── local-build.ps1               # Windows + WSL2 包装脚本
    └── coverage-test.sh              # 覆盖性配置测试
```

CI 与本地复用同一份 `scripts/local-build.sh`，不存在第二处脚本来源。

---

## 本地编译

### Windows + WSL2（推荐）

WSL2 是本地编译的推荐方式——原生 ext4 文件系统、无线程限制、ccache 持久化，相比 Docker 可节省数倍编译时间。

首次安装依赖：

```powershell
.\scripts\local-build.ps1 -InstallDeps
```

完整构建（默认会同步到 WSL 原生路径 `~/Auto-H5000M-BIN-localbuild`）：

```powershell
.\scripts\local-build.ps1
```

只跑准备/配置不编译：

```powershell
.\scripts\local-build.ps1 -ConfigOnly
.\scripts\local-build.ps1 -PrepareOnly
```

调整功能开关（任何 `ENABLE_*` 会被自动转发到 WSL bash）：

```powershell
$env:ENABLE_MOSDNS = 'false'
$env:ENABLE_ADBLOCK = 'true'
.\scripts\local-build.ps1
```

全兼容插件本地编译示例（同时启用 QModem + Adblock + HomeProxy + 原版 Modem + AdGuardHome + OpenClash + MosDNS + Nikki + UPnP + VLMCSd + DockerMan）：

```powershell
$env:ENABLE_ADGUARDHOME = 'true'
$env:ENABLE_OPENCLASH = 'true'
$env:ENABLE_NIKKI = 'true'
$env:ENABLE_UPNP = 'true'
$env:ENABLE_VLMCSD = 'true'
$env:ENABLE_MOSDNS = 'true'
$env:ENABLE_DOCKERMAN = 'true'
$env:ENABLE_QMODEM = 'true'
$env:ENABLE_HOMEPROXY = 'true'
$env:ENABLE_ORIGINAL_MODEM = 'true'
$env:ENABLE_ADBLOCK = 'true'
.\scripts\local-build.ps1

# 关闭原版 Modem 仅保留 QModem（适合仅使用 Quectel RG501Q-EU 的场景）：
$env:ENABLE_ORIGINAL_MODEM = 'false'
$env:ENABLE_QMODEM = 'true'
$env:ENABLE_QMODEM_NEXT = 'true'
$env:ENABLE_QMODEM_LUA = 'false'
.\scripts\local-build.ps1

# 切换 QModem 到经典 Lua 版：
$env:ENABLE_QMODEM_NEXT = 'false'
$env:ENABLE_QMODEM_LUA = 'true'
.\scripts\local-build.ps1

# 关闭 QModem 只用原版 modem：
$env:ENABLE_ORIGINAL_MODEM = 'true'
$env:ENABLE_QMODEM = 'false'
.\scripts\local-build.ps1
```

国内网络可按需覆盖下载镜像：

```powershell
$env:GOPROXY = 'https://goproxy.cn,https://proxy.golang.org,direct'
$env:GOSUMDB = 'sum.golang.google.cn'
$env:DOWNLOAD_MIRROR = 'https://mirrors.tuna.tsinghua.edu.cn/openwrt/sources;https://mirrors.ustc.edu.cn/openwrt/sources;https://mirrors.bfsu.edu.cn/openwrt/sources'
$env:GITHUB_PROXY_PREFIXES = 'https://ghfast.top/ https://gh-proxy.com/ https://gh.llkk.cc/'
```

### Linux / 直接在 WSL Shell 中

```bash
bash scripts/local-build.sh --install-deps   # 仅首次
ENABLE_MOSDNS=false THREADS=8 bash scripts/local-build.sh
```

只验证配置（快速迭代，不下载不编译）：

```bash
bash scripts/local-build.sh --config-only
SKIP_TOOLCHAIN=true SKIP_DOWNLOAD=true bash scripts/local-build.sh  # 最快迭代
```

覆盖性配置测试（不完整编译固件，只跑到补丁、feeds、defconfig 和关键包校验）：

```bash
bash scripts/coverage-test.sh quick
PROFILE_SET=full bash scripts/coverage-test.sh
FULL_BUILD_PROFILE=proxy-stack PROFILE_SET=quick bash scripts/coverage-test.sh
```

`quick` 覆盖默认构建和代理栈组合；`full` 会额外覆盖最小系统、HomeProxy-only、MosDNS-only、Nikki-only、原版 modem、Adblock、常用可选服务、全兼容插件和 DockerMan。`FULL_BUILD_PROFILE` 会在配置覆盖后额外完整编译一个指定 profile。

成功后产物在 `artifacts/`，并打包成 `artifacts.tar.gz`。

---

### 命令行选项

| PowerShell 开关 | bash 选项 | 说明 |
| --- | --- | --- |
| `-InstallDeps` | `--install-deps` | apt-get 安装编译依赖 |
| `-PrepareOnly` | `--prepare-only` | 拉源码 + feeds + 补丁后停止 |
| `-ConfigOnly` | `--config-only` | 上述 + defconfig 后停止 |
| `-SkipToolchain` | `--skip-toolchain` | 跳过显式 `make toolchain/install` |
| `-SkipDownload` | `--skip-download` | 跳过 `make download` |
| `-SkipFeedsUpdate` | `--skip-feeds-update` | 跳过 `./scripts/feeds update -a` (本地迭代提速) |

### 功能开关（环境变量）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `ENABLE_NIKKI` | `true` | Nikki / mihomo-meta 代理 |
| `ENABLE_UPNP` | `true` | UPnP IGD |
| `ENABLE_VLMCSD` | `true` | KMS 激活服务 |
| `ENABLE_MOSDNS` | `true` | MosDNS + v2ray-geodata |
| `ENABLE_ADGUARDHOME` | `false` | AdGuardHome |
| `ENABLE_OPENCLASH` | `false` | OpenClash |
| `ENABLE_DOCKERMAN` | `false` | DockerMan + dockerd |
| `ENABLE_HOMEPROXY` | `false` | HomeProxy |
| `ENABLE_ORIGINAL_MODEM` | `false` | 上游原版 modem（luci-app-modem + ModemManager，支持 Quectel RG501Q-EU/RM5xxQ 等 QMI 5G 模块）。与 QModem **互斥**——同时启用会被自动关闭 |
| `ENABLE_QMODEM` | `true` | QModem（FUjr/QModem，Quectel/Fibocom/MEIG/SIMCOM 5G modem LuCI 面板，原版 luci-app-modem 不覆盖 RG501Q-EU 等专用 5G 驱动时启用）。与原版 modem **互斥** |
| `ENABLE_QMODEM_NEXT` | `true` | QModem 新版 JS LuCI (`luci-app-qmodem-next`)。与 `ENABLE_QMODEM_LUA` 互斥——默认启用新版 |
| `ENABLE_QMODEM_LUA` | `false` | QModem 经典 Lua LuCI (`luci-app-qmodem`)。与 `ENABLE_QMODEM_NEXT` 互斥 |
| `ENABLE_ADBLOCK` | `true` | Adblock（DNS 层广告/恶意域名过滤，依赖 dnsmasq/unbound/smartdns） |

### 下载优化变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `GOPROXY` | `https://goproxy.cn,https://proxy.golang.org,direct` | Go 模块代理，覆盖 MosDNS / Nikki / HomeProxy 的 Go 依赖下载 |
| `GOSUMDB` | `sum.golang.google.cn` | Go 校验数据库，避免 `sum.golang.org` 网络不可达 |
| `DOWNLOAD_MIRROR` | 清华/中科大/北外 OpenWrt sources | 传给 OpenWrt `scripts/download.pl` 的源码镜像列表 |
| `GITHUB_PROXY_PREFIXES` | `ghfast` / `gh-proxy` / `gh.llkk` | GitHub clone/raw 失败后的代理前缀回退，原始 URL 总是优先尝试 |
| `HOMEPROXY_REPO_URL` / `HOMEPROXY_REPO_BRANCH` | `immortalwrt/homeproxy` / `master` | HomeProxy 主源码 |
| `HOMEPROXY_FALLBACK_REPO_URL` / `HOMEPROXY_FALLBACK_REPO_BRANCH` | `VIKINGYFY/homeproxy` / `main` | HomeProxy 主源失败时的备用源码 |

---

## GitHub Actions

- 触发：每周日 16:00 UTC（北京时间周一 00:00）自动构建；亦可在 Actions 页面手动 `workflow_dispatch`。
- 手动触发时所有 `ENABLE_*` 与 `publish_release` 都是布尔输入；不勾选 `publish_release` 时只上传 Artifact，不创建 Release。
- 勾选 `publish_release` 时发布到固定 `latest` tag，并标记为 GitHub Latest Release；不会再作为 pre-release 发布。
- 手动触发时可勾选 `run_config_coverage`，并选择 `coverage_profile_set=quick/full`；需要固件级冒烟时填写 `full_build_smoke_profile`。
- coverage 配置测试与固件编译并行运行，不阻塞 Release 发布时间。
- feeds 更新失败会直接中止，避免在 GitHub Actions 中生成缺插件/缺依赖的固件。
- Artifact 内会包含 `build.config` 与 `enabled-packages.txt`，可直接确认 WiFi 补丁、MosDNS、HomeProxy、Nikki 等功能是否进入最终配置。
- 运行器可在手动触发时选择：`github-hosted`（默认）或 `self-hosted`。选择 `self-hosted` 走你自己注册的 runner（详见下节），避免 free 账户被锁或分钟数不够时编译中断。

覆盖测试能显著降低回归风险，但不能证明固件“完全没有 bug”。无线环境、硬件状态、运营商网络、插件上游服务、运行时配置和客户端行为仍需要刷机后的真实设备验证。

---

## Self-hosted runner（free 账户被锁时仍能编译）

GitHub Actions 的免费额度（私有仓 2000 分钟/月）或 billing 锁定时，github-hosted runner 会被拒绝拉 job。本 workflow 支持 `runner_type=self-hosted` 走你自己的机器。

### 1. 在仓库上添加 runner

1. 进入仓库页面 → **Settings** → **Actions** → **Runners** → **New self-hosted runner**
2. 选择 Linux x64，GitHub 会给出一段注册脚本。推荐同时勾选"Disable default runners on this repo"以外的额外能力。
3. 在 runner 标签处至少加：`linux`, `x64`, `h5000m`（默认值。如需加 GPU/快存机器也可自定义标签，运行时在 workflow_dispatch 的 `self_hosted_labels` 里填入）。

### 2. 准备 runner 环境

```bash
# Ubuntu 22.04/24.04 推荐。Runner 需要以下依赖（参考 local-build.sh “安装编译依赖”步骤）：
sudo apt-get update && sudo apt-get install -y --no-install-recommends \
  build-essential ccache python3 libncurses5-dev libssl-dev libgmp3-dev libmbedtls-dev \
  zlib1g-dev autoconf automake libtool patch gcc g++ gawk gettext unzip file wget curl \
  rsync zstd golang-go rustc cargo git ack antlr3 asciidoc binutils bison bzip2 clang cmake \
  cpio device-tree-compiler fastjar flex gcc-multilib g++-multilib gnutls-dev gperf haveged \
  help2man intltool lib32gcc-s1 libc6-dev-i386 libelf-dev libfuse-dev libglib2.0-dev \
  libltdl-dev libmpc-dev libmpfr-dev libncursesw5-dev libpython3-dev libreadline-dev lld llvm \
  lrzsz mkisofs msmtp nano ninja-build p7zip p7zip-full pkgconf python3-pip python3-ply \
  python3-pyelftools python3-setuptools qemu-utils re2c scons squashfs-tools subversion swig \
  texinfo uglifyjs upx-ucl vim xmlto xxd

# 起码 30 GB 空闲磁盘（ccache 拉满可上 50 GB）。
# 编译时会创建 `work/_temp` 、调用 `chmod` 、`sudo` 不是必须的（自托管步骤已跳过 apt 安装）。
```

### 3. 启动 runner

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner
# （从 GitHub 页面拷贝的 ./config.sh --url ... --token ...）
./config.sh --labels linux,x64,h5000m
./svc.sh install && ./svc.sh start    # 作为 systemd 服务运行
```

### 4. 手动触发走 self-hosted

Actions → Run workflow → `runner_type` 选 `self-hosted`（默认 `linux,x64,h5000m` 标签）→ Run。任务会在你自己的 runner 上跑，不走 GitHub 额度。

### 5. 重要限制

- 如果 GitHub **org 整体**被锁定（例如未付款超过某些阈值），self-hosted runner 也可能拉不到 job——这种情况必须先在 https://github.com/settings/billing 解锁。
- self-hosted runner 必须是本 workflow 信任的机器。GitHub 仓库的设置默认要求组织所有者批准新 runner。
- 不要让 runner 以 root 运行（用普通用户 + sudo；脚本里 `apt-get` / 磁盘清理步骤会在 self-hosted 下自动跳过）。

---

## 持久修复要点

`patches/mtwifi-apcli-active-only.patch` 解决 MTK WiFi AP/APCLI 在禁用部分 VIF 时仍占用 BSSID 预算导致 AP 无法起来的问题：

- `mtwifi_cfg` 增加 `cfg_is_true` / `vif_is_enabled` / `sorted_vif_indices`；按启用 VIF 计算 `BssidNum` 并跳过 disabled VIF；
- `netifd/mtwifi.sh` 中 `mtwifi_vif_ap_set_data` / `mtwifi_vif_sta_set_data` 对 `disabled="1"` 早退；
- 应用方式：`local-build.sh` 在 `apply_package_fixes` 阶段对 `immortalwrt/` 执行幂等 forward / reverse dry-run；重复运行安全。

`patches/mtk-hnat-local-dest.patch` 修复开启 HNAT 后 WiFi 客户端无法访问路由器后台（且无线本地流量被误卸载）的问题：

- 在 `mtk_hnat` 驱动的 `is_ppe_support_type()` 里对 IPv4 / IPv6 增加"目的地址为本地地址（`RTN_LOCAL` / `ipv6_chk_addr`）则不卸载"的判断；
- 该函数是 IPv4 / IPv6 / bridge 三个 pre-routing hook 的公共闸门，因此一处修复覆盖所有无线/有线入口，转发流量不受影响；
- 应用方式同 `mtwifi` 补丁：`apply_package_fixes` 幂等 forward / reverse dry-run + `grep` 校验，重复运行安全。

其它内嵌修复：QMI WWAN 驱动适配 Linux 6.6、Go feed 强制 `sbwml/packages_lang_golang -b 24.x`、`mihomo-meta` 冲突剥离、`ebtables` 源镜像在匹配到 netfilter URL 时才替换。MosDNS 的 Go 1.24 兼容不再用逐条硬编码依赖版本降级：脚本会在补丁层归一化（mosdns 剥掉 update-dependencies 补丁里的 go.mod/go.sum hunk），并在 `Build/Prepare` 里用通用正则重新钉住 `go`/`toolchain` 指令，上游再次升级版本时不会静默失效，而是被归一化或直接报错。

插件源码修复：启用 Nikki 时会在 feed 更新失败/缺失后补拉 `nikkinikki-org/OpenWrt-nikki`，并校验 `nikki` / `mihomo-meta`；启用 OpenClash 时补拉 `vernesong/OpenClash` 内的 `luci-app-openclash`；启用 MosDNS 时补拉 `sbwml/luci-app-mosdns` 与 `sbwml/v2ray-geodata`，清理 feeds 内同名旧包，并校验 `mosdns` / `v2ray-geoip` / `v2ray-geosite`；启用 HomeProxy 时补拉 `immortalwrt/homeproxy`，失败后回退到 `VIKINGYFY/homeproxy`，并强制校验 `luci-app-homeproxy` / `sing-box` / `kmod-nft-tproxy` 是否进入最终 `.config`。`luci-app-turboacc-mtk`（MTK HNAT / SFE / Shortcut-FE LuCI 面板）与 `luci-app-Airpifanctrl` 不在所用 feeds 中（immortalwrt 24.10 luci 与 immortalwrt-mt798x-24.10 上游分支都未携带），脚本会从 `hanwckf/immortalwrt-mt798x` 与 `padavanonly/immortalwrt-mt798x-6.6` 仓库拉取后拷贝到 `package/mtk/applications/` 下，并加上 verify 校验，避免 `.config` 静默丢失。

UPnP 修复：`luci-app-upnp` 依赖虚拟包 `miniupnpd`，fw4 构建中显式选择 `miniupnpd-nftables` 与 `rpcd-mod-ucode`，避免 `defconfig` 将 `luci-app-upnp` 自动关闭。若上游源码引用 `libcrypt-compat` 但当前 feeds 未定义该包，构建脚本会补一个 glibc 条件下的兼容包定义，避免包扫描阶段刷屏 warning。

原版 Modem（默认关闭）：`ENABLE_ORIGINAL_MODEM=false`（默认）。需设 `ENABLE_ORIGINAL_MODEM=true ENABLE_QMODEM=false` 启用。启用上游 `luci-app-modem` + `modem` + `luci-i18n-modem-zh-cn`，底层走 `modemmanager` + `libqmi` + immortalwrt feeds 的 `quectel-qmi-wwan` / `fibocom-qmi-wwan`（`kmod-usb-net-qmi-wwan-{quectel,fibocom}`），支持 Quectel RG501Q-EU/RM5xxQ 系列等所有 QMI 5G 模块（USB/PCIe 双形态）。MTK `package/mtk/applications/5g-modem/quectel_QMI_WWAN` 等内核驱动模块已存在于 immortalwrt 源中，由 package-metadata 自动解析。**注意：与 QModem 互斥**——同时启用两者，`resolve_modem_stack()` 会自动关闭原版。`enable_modem_stack_config()` 在原版 modem 路径下还会强制启用通用 USB/PCIe/netfilter/crypto/filesystem kmod 全集（kmod-usb-core/ehci/xhci/storage、kmod-nf-*、kmod-crypto-*、kmod-fs-{exfat,ext4,vfat,ntfs3} 等）。

QModem（默认）：`ENABLE_QMODEM=true`（默认与原版 modem **互斥**——同时启用会被自动关闭原版）启用 `FUjr/QModem` 的 `qmodem` + `qmodem-modemband` + LuCI 前端（默认 `luci-app-qmodem-next`，即新版纯 JS LuCI；可选 `luci-app-qmodem` 经典 Lua 版），覆盖 Quectel RG501Q-EU / RM5xxQ、Fibocom FM350、MEIG SLM320、SIMCom SIM8200 等 5G 模块（USB qmi/gobinet/ecm/mbim/rndis/ncm + PCIe qmi/gobinet/mbim）。`enable_modem_stack_config()` 显式启用 QModem 自带的 `kmod-qmi_wwan_q|f`（Quectel/Fibocom 专用 QMI 驱动，**与** immortalwrt feeds 的 `kmod-usb-net-qmi-wwan-{quectel,fibocom}` 互斥——同一 qmi_wwan_q.ko 不能加载两次）、`modemmanager` + `modemmanager-rpcd` + `luci-proto-modemmanager` + `dbus` + `glib2` + `libqmi` + `libmbim` + `qmi-utils` + `uqmi`，以及通用 USB/PCIe/netfilter/crypto/filesystem kmod 全集。**只启用 QModem、不启用原版** 即可支持 RG501Q-EU；只启用原版 modem（`ENABLE_ORIGINAL_MODEM=true ENABLE_QMODEM=false`）则使用 immortalwrt feeds 的 Quectel/Fibocom 驱动。`coverage-test.sh` 提供 `qmodem` 与 `qmodem-lua` 两个 profile 分别验证。

Adblock（默认）：`ENABLE_ADBLOCK=true` 启用上游 `adblock` + `luci-app-adblock` + `luci-i18n-adblock-zh-cn`，再加 `enable_adblock_stack_config()` 显式声明全部运行时依赖（`jshn` / `jsonfilter` / `coreutils` / `coreutils-sort` / `gawk` / `ca-bundle` / `rpcd` / `rpcd-mod-rpcsys` / `curl` / `ca-certificates`），作为 defconfig 鲁棒性网。原先 `adbyby-plus` Lite 的 `kongfl888` 私有源克隆、`ADBYBY_PLUS_I18N_IPK_URL` 预编译 ipk 下载、`luci-app-adbyby-plus` + `ipset` 注入等全部移除。

IPv6 基础设施：上游 `mt7987_mt7992.config` 默认开启了 `IPV6=y` 但保留 IPv6 netfilter 链路（kmod-ip6tables / kmod-ipt-nat6 / libip6tc / ip6tables-extra 等）全部 `is not set`。本项目同时启用多代组件（Nikki / HomeProxy / MosDNS），它们都在 IPv6 路由转发时调用 ip6tables / ip6tables-mod-nat，若不补齐 IPv6 netfilter 栈，运行时会拿到 `can't initialize iptables table 'filter'+ 模块缺失`。`h5000m.extra.config` 默认补齐 `kmod-nf-ipt6` / `kmod-ip6tables` / `kmod-ip6tables-extra` / `kmod-ipt-nat6` / `kmod-nf-nat6` / `kmod-ip6-tunnel` / `libip6tc` / `ip6tables-mod-nat` / `ip6tables-extra` / `ip6tables-nft` / `ip6tables-zz-legacy`，使 LAN/WAN IPv6 RA+DHCPv6、NDP、IPv6 NAT、fw4 IPv6 转发均能工作。原先 `enable_mwan3_stack_config` 注入的 `kmod-vrf` / `iptables-mod-conntrack-extra` / `iptables-mod-ipopt` / `kmod-ipt-ipset` 等多 WAN 专用模块已不需要（mwan3 已移除），其中与 IPv6 netfilter 栈重叠的依赖继续保留在 `h5000m.extra.config` 中供 Nikki / HomeProxy / MosDNS 共用。

MTK HNAT / 网络加速：MT798x 默认启用 `kmod-mediatek_hnat`（硬件 NAT offload），`mtk_hnat_nf_hook` 在 `NF_INET_PRE_ROUTING @ NF_IP_PRI_MANGLE-1` 与 `NF_INET_PRE_ROUTING @ NF_IP_PRI_FIRST+1` 等多个优先级点向 netfilter 注册 hook，在命中硬件流表时调用 `dev_queue_xmit` 直接转发，避免 fw4 / nftables 介入。

**本仓库已内置修复**：`patches/mtk-hnat-local-dest.patch` 在 `is_ppe_support_type()`（IPv4/IPv6/bridge 三个 pre-routing hook 的公共入口）里加入"目的地址是本地地址（`RTN_LOCAL`）就不卸载"的判断。这样发往路由器自身 IP（192.168.6.1）的流永远不会被 HNAT 变成 LAN→WAN 硬件捷径，而是正常走 INPUT 链。转发型 LAN↔WAN 流量不受影响（其目的地址不是 `RTN_LOCAL`）。`local-build.sh` 在 `apply_package_fixes` 阶段幂等应用并校验该补丁。

修复前的问题表现：

- **从 LAN（插线）访问路由器后台**（192.168.6.1）：包被识别为本地 INPUT，HNAT hook 返回 NF_ACCEPT，流走 INPUT 链。正常工作。
- **从 WiFi 客户端访问路由器后台**（192.168.6.1）：HNAT 为该流（5 元组）生成 hardware shortcut 后，后续包被 `do_hnat_ge_to_ext()` → `dev_queue_xmit()` 直接转走，跳过 INPUT 链。表现是 `curl http://192.168.6.1/` 超时/拒接、浏览器白页，同时无线客户端侧的网络加速也可能把本地流量误卸载导致无线网络异常。

`luci-app-turboacc-mtk` 面板中的"软件流卸载" / "HNAT"开关实际控制 UCI 选项转 sysfs 写入（`/sys/kernel/debug/hnat/`）。若刷入的是未带本补丁的旧固件，临时规避方式：路由器后台 → 网络 → Turbo ACC → 取消启用 **Software flow offloading**（Shortcut-FE）和 **Hardware NAT** → "Apply"；或运行 `echo 0 > /sys/kernel/debug/hnat/hooks` 临时挂起 HNAT hook。

---

## 许可证

继承上游 ImmortalWrt 项目许可证。

---

## h5000m-kit：把全部定制烤进固件

`h5000m-kit/` 是仓库根下的一个 OpenWrt 包，由 `scripts/local-build.sh` 的
`stage_h5000m_kit` 拷进源码树 `package/h5000m-kit`。它把本机（Hiveton H5000M +
Quectel RM502Q-AE）的全部自研改造固化进固件，刷机后不再需要手工重建：

- AT 双口物理隔离（`/bin/sendat` wrapper + `/usr/bin/rm502q-at-map` + usb hotplug + init）
- 短信转发（企微群机器人 + 时区修正的 `sms_forwarder_next`）
- ModemWebUI 面板整套（含 QSCAN 主动扫描、邻区 v8 前端补丁、`?v=N` 缓存戳）
- 风扇控制（`/usr/bin/fancontrol` CPU+WiFi 取高 / `fanearly`）
- QMI 断线自愈（`qmi-recovery`）、WebUI 看门狗（`webui-ws-guard`）
- IPv6 快失败（`v6fastfail` + 每周刷新）、OpenClash 动态运营商 DNS 注入
- `etc/uci-defaults/99-h5000m-kit` 首次启动自动写好 uci、启用服务、装 cron

配套：
- `patches/999-h5000m-pwm-fan-boot-duty.kernel-patch` —— pwm-fan probe 原本一加载就
  写满 PWM；补丁改为读 DTS `pwm-fan,boot-duty`（配合 `patches/dts-h5000m-fan-boot-duty.patch`
  板级取值 51 = 20%），开机不再满转。
- `ipk/` —— 厂商私有 feed 的 5 个面板包存档（内容已并进 h5000m-kit，编译不使用）。

### 与 fork 默认行为的**有意**差异

| 项 | 差异 | 原因 |
|---|---|---|
| `luci-app-Airpifanctrl` | **关闭**（`local-build.sh` 与 workflow 的断言已相应改为校验 `h5000m-kit`） | 它自带 `/etc/init.d/Airpifanctrl` + `/usr/bin/fancts.sh`，会与 h5000m-kit 的 `/usr/bin/fancontrol` **争抢 pwm1**，两个控制器互相打架 |
| `modemmanager` | 保持 fork 默认（启用） | 本机不使用它拨号，但 `local-build.sh` 有硬校验；关闭需同时改脚本与 workflow，暂不做 |
| 精简清单 | 去掉 Nikki/MosDNS/PassWall/HomeProxy/adblock/UPnP/VLMCSD/DockerMan/argon/ramfree/watchcat/ip6tables 全家等 | 本机不用；OpenClash 走 nft，不需要 iptables 后端 |
