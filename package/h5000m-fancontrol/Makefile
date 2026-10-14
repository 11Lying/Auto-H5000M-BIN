include $(TOPDIR)/rules.mk

PKG_NAME:=h5000m-fancontrol
PKG_VERSION:=1.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/h5000m-fancontrol
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Hiveton H5000M thermal fan controller
  DEPENDS:=+uci +ubus +kmod-hwmon-pwmfan +kmod-thermal
endef

define Package/h5000m-fancontrol/description
 Lightweight H5000M CPU/Wi-Fi temperature fan controller with hysteresis.
endef

# Script/data-only package: no source to build. Override the default
# Build/* steps so OpenWrt does not try to run `make` in an empty build dir
# (which fails with "No targets specified and no makefile found").
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/h5000m-fancontrol/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/etc/init.d $(1)/etc/config $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/usr/bin/fancontrol $(1)/usr/bin/fancontrol
	$(INSTALL_BIN) ./files/etc/init.d/fancontrol $(1)/etc/init.d/fancontrol
	$(INSTALL_CONF) ./files/etc/config/fancontrol $(1)/etc/config/fancontrol
	$(INSTALL_BIN) ./files/etc/uci-defaults/90-h5000m-hw-offload $(1)/etc/uci-defaults/90-h5000m-hw-offload
	$(INSTALL_BIN) ./files/usr/bin/h5000m-audit $(1)/usr/bin/h5000m-audit
endef

$(eval $(call BuildPackage,h5000m-fancontrol))
