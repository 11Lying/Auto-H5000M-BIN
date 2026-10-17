The bundled `webuiserver` and `sendat.real` are the H5000M vendor binaries
from the installed `webuiserver` 2.0.0-r1 and `sendat` 6.9.0-r1 packages.
Their package control metadata identifies each as MIT-licensed. The original
source feed is `feeds/base/otherapp/luci-app-modemwebui`.

The WebUI frontend is derived from
`lonelysix-editor/luci-app-modemwebui` at commit
`eaa797805a19518fc1701b0192421f34c3c49e93`, whose repository license is
GPL-3.0; the matching license text is in `LICENSE.webui.GPL-3.0`. The shipped
network-settings chunk includes the documented H5000M QSCAN/neighbour-cell
fixes and cache-bust (`?v=8`).

The QSCAN C helpers in `src/` are built for the target from source and are
licensed MIT. No device credentials, subscriptions, webhook keys, or user UCI
configuration are included.
