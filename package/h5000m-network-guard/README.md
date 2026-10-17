# H5000M IPv6 network guard

Restored from the user's 2026-10-14 minimal backup and validated by the
2026-10-15 IPv6 A/B test. The package installs:

- `ipv6-guard.sh`: only restores the LAN /64 return-route preference and
  removes a deprecated table; it does not configure DNS or proxy routing.
- `ipv6-cn-fastfail.sh`: a forward-hook nftables table. Established/related,
  China IPv6, local scopes, and ICMPv6 control/error traffic are accepted;
  other global IPv6 destinations are rejected with ICMPv6 admin-prohibited.
- A pinned/static China IPv6 prefix list plus a weekly updater. The updater
  validates the downloaded prefix count/format and keeps the old list if the
  download is bad.

The first-boot UCI defaults add only the two script includes, set
`dhcp.lan.ra_default=2`, and add the weekly refresh cron entry. They do not
change WAN, DNS targets, OpenClash policy, Wi-Fi, or IPv4 routing. The guard
covers forwarded LAN traffic only; it does not claim to filter router-originated
IPv6. It is not proof of correct runtime firewall behavior on the final image;
that requires a post-build, read-only device check.
