# Optional independent `mtkhnat.ko` route

These patches are retained as the previous branch work for reference only.
They are **not applied by `scripts/local-build.sh`**.

The active `hnat-6.12` build uses the integrated 6.12 `mtk_eth_soc`/`mtk_ppe`
flow-offload path instead. Enabling `CONFIG_NET_MEDIATEK_HNAT` changes the
Ethernet driver through `999-eth-91` and disables the integrated PPE start/
stop/probe path, so the independent module is intentionally not selected until
it can be tested safely on this board.
