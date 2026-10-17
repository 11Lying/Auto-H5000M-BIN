#!/bin/sh
# rm502q-at-check: repair the RM502Q AT role mapping if it drifted from hardware.
# Cron safety net (every 2 min). Silent when healthy; exits 0.
# The rm502q-at-map script itself is idempotent and only touches AT-port config.
# 2026-10-13: created after the "at-daemon grabbed the WebUI port after a modem
# USB re-enumeration" incident (hotplug path was hardcoded to 1-1).
USBROOT=/sys/bus/usb/devices
USBDEV=""
for d in "$USBROOT"/*; do
  [ -r "$d/idVendor" ] || continue
  [ "$(cat "$d/idVendor" 2>/dev/null)" = "2c7c" ] || continue
  [ "$(cat "$d/idProduct" 2>/dev/null)" = "0800" ] || continue
  [ -z "$USBDEV" ] && USBDEV=${d##*/}
done
[ -n "$USBDEV" ] || exit 0
read_tty() {
  for dev in /dev/ttyUSB*; do
    [ -e "$dev" ] || continue
    t=${dev##*/}
    r=$(readlink -f "/sys/class/tty/$t/device" 2>/dev/null)
    case "$r" in *"$USBDEV:$1"/*) echo "$t"; return 0;; esac
  done
  return 1
}
Q=$(read_tty 1.3) || exit 0
W=$(read_tty 1.2) || exit 0
[ -n "$Q" ] && [ -n "$W" ] || exit 0
QN=${Q#ttyUSB}; WN=${W#ttyUSB}
if [ "$QN" != "$(cat /run/rm502q-at/qmodem 2>/dev/null)" ] || [ "$WN" != "$(cat /run/rm502q-at/webui 2>/dev/null)" ]; then
  exec /usr/bin/rm502q-at-map
fi
# numbers match; verify qmodem's eligible AT pool is still narrowed to the role port
# (qmodem's scanner can widen it to all AT ports after modem add events)
sec=""
for s in $(uci -q show qmodem 2>/dev/null | sed -n 's/^qmodem\.\([^.=]*\)=modem-device$/\1/p'); do
  p=$(uci -q get "qmodem.$s.path"); p=${p%/}
  [ "${p##*/}" = "$USBDEV" ] && sec=$s
done
[ -n "$sec" ] || exit 0
[ "$(uci -q get "qmodem.$sec.valid_at_ports")" = "/dev/$Q" ] || exec /usr/bin/rm502q-at-map
# QModem's scanner can leave at-daemon holding the WebUI role after the UCI
# pool is narrowed. The map files/config can look correct while that stale FD
# still blocks sendat.real on ttyUSB${WN}; detect and close that exact port.
if ubus call at-daemon list 2>/dev/null | jq -e --arg p "/dev/$W" '.ports[]? | select(.port == $p and .is_open == 1)' >/dev/null 2>&1; then
  exec /usr/bin/rm502q-at-map
fi
exit 0
