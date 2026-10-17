# H5000M modem-support package

This package restores the independently tested RM502Q-AE ModemWebUI stack from
the 2026-10-16 H5000M recovery. That recovery was exercised on ImmortalWrt
25.12-SNAPSHOT/6.12.112; the current build advances the kernel tarball to
6.12.113, so the final image still needs a post-build/runtime check.

The frontend is derived from `lonelysix-editor/luci-app-modemwebui` at commit
`eaa797805a19518fc1701b0192421f34c3c49e93` (GPL-3.0; license text included).
The H5000M neighbour-cell/QSCAN v8 changes and `?v=8` cache-bust are retained
in the shipped JS bundle. The vendor `webuiserver` and `sendat.real` binaries
come from the installed vendor packages whose package metadata identifies
both as MIT-licensed; see `LICENSE.vendor-binaries.md`.

The QSCAN C helpers are built from the included `src/` files with the target
cross-compiler and static linking. They use the included MIT license. `sendat`
and `webuiserver` remain prebuilt aarch64-musl userspace binaries (not kernel
modules); their dynamic dependencies are `libc.so` and `libgcc_s.so.1`.

Included functionality:

- `/usr/bin/webuiserver` and the standalone HTTP/WebSocket ModemWebUI (ports
  8001/8765), including the 55-file `www/webui/webui000` tree.
- `/bin/sendat` wrapper plus `sendat.real`, dynamic RM502Q USB interface/tty
  mapping, QSCAN tools, and the WebUI health guard.
- QModem AT isolation (interface 1.3 is QModem/SMS; interface 1.2 is WebUI),
  QModem's ubus AT path, and dynamic QMI WDS wedge-recovery service.
- Generic WeCom SMS adapter at `/usr/share/sms_forwarder/sms_forward_wecom.sh`.

The first-boot defaults enable the modem services, add idempotent WebUI/AT
health-check cron entries, and install an explicit WAN-only reject rule for
management ports. They do not rewrite WAN interfaces, DNS targets, SmartDNS,
OpenClash, Wi-Fi, or user SMS configuration. They do not create or ship a
webhook URL/key, subscription, proxy node, dashboard password, or other router
credential. Existing `/etc/config/sms_forwarder` is only used if separately
restored from the user's private configuration.

The ModemWebUI itself has no authentication; do not expose 8001/8765 to the
Internet or port-forward them. The package's first-boot rule protects them on
the `wan` zone; verify that rule after boot. The final package/image manifest
and binaries still require CI and hardware acceptance checks.
