# Vendored mt76 package

This directory is the official `package/kernel/mt76` package from
`immortalwrt/immortalwrt` branch `openwrt-25.12`, pinned at:

- package source commit: `ce35a9e4ef1b87fbbc2146036ce6693e4242861a`
- mt76 source commit: `39c960c3ada558b4c2e7915772483d3731573d09`
- mt76 source date: `2026-03-19`

The chasey-dev 25.12 base used by this branch does not contain
`package/kernel/mt76`, although the H5000M device profile selects the official
MT7992 stack (`kmod-mt7996e` and `kmod-mt7992-23-firmware`). Without this
package the expanded configuration silently drops those symbols and the image
has no MT7992 Wi-Fi driver.

`scripts/local-build.sh` stages this directory as
`immortalwrt/package/kernel/mt76` before `make defconfig`.

The package also carries `patches/110-mtk-wed-v3.1-compat.patch`, an adaptation
of MediaTek MTK OpenWrt Feeds patch 0049 (commit
`7a38cb57511c6884638d72e26aaa14eb34c496c6`). It bridges the mt76 WED setup to
the MT7987 WED 3.1 kernel API used by the pinned base; without it, upstream
mt76 assigns a scalar to the kernel's `wpdma_tx[]` array and does not initialize
the WED 3.1 ring layout.
