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
