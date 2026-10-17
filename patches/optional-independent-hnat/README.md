# Independent `mtkhnat.ko` HNAT/USB route

The HNAT/USB route is active only in the separate `hnat-usb-experimental-20261017`
build branch. The PPE-only baseline remains available on
`audit-upgrade-2026-10` and the local `ppe-rollback-20261017` tag.

The source patches in this directory are historical originals. The active,
reviewed copies are staged from the root `patches/` directory by
`scripts/local-build.sh`; do not apply these historical copies manually.

The selected route uses upstream `mtkhnat` as the sole PPE register owner.
`999-eth-91` disables the integrated `mtk_eth_soc` PPE init/start/stop path when
`CONFIG_NET_MEDIATEK_HNAT` is selected. The H5000M DTS adds the HNAT v5 node
and USB/WWAN/RMNET prefixes; upstream `hnat-detect` configures the Rx-PPD path
for the QMI WAN. Build checks prove package/patch/DT integration, but real
USB/QMI acceleration still requires post-flash counter and traffic tests.
