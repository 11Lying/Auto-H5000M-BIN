include $(TOPDIR)/rules.mk

PKG_NAME:=h5000m-network-guard
PKG_VERSION:=2026.10.15
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=11Lying

include $(INCLUDE_DIR)/package.mk

define Package/h5000m-network-guard
  SECTION:=net
  CATEGORY:=Network
  TITLE:=H5000M IPv6 LAN-route guard and foreign IPv6 fast-fail
  DEPENDS:=+firewall4 +uclient-fetch
  PKGARCH:=all
endef

define Package/h5000m-network-guard/description
 Restores the verified H5000M IPv6 design: preserve the LAN shared-/64
 return route, allow China IPv6 and local scopes, and reject other global
 IPv6 in forwarded traffic with ICMPv6 admin-prohibited. It does not change
 WAN, DNS targets, OpenClash rules, or proxy settings.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
	true
endef

define Package/h5000m-network-guard/install
	$(INSTALL_DIR) $(1)
	$(CP) ./files/. $(1)/
endef

$(eval $(call BuildPackage,h5000m-network-guard))
