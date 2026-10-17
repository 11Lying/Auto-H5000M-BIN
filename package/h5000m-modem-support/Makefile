include $(TOPDIR)/rules.mk

PKG_NAME:=h5000m-modem-support
PKG_VERSION:=2026.10.16
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-only MIT
PKG_LICENSE_FILES:=LICENSE.webui.GPL-3.0 LICENSE.qscan.MIT
PKG_MAINTAINER:=11Lying

include $(INCLUDE_DIR)/package.mk

define Package/h5000m-modem-support
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=H5000M RM502Q modem support and independent ModemWebUI
  DEPENDS:=+luci-app-qmodem-next +sms-forwarder-next +libgcc +curl +jq +kmod-usb-serial-option +kmod-usb-serial-qualcomm
endef

define Package/h5000m-modem-support/description
 H5000M RM502Q-AE integration: independent port-8001 ModemWebUI, WebSocket,
 dynamic ttyUSB role mapping, QSCAN tools, QMI wedge recovery and a generic
 WeCom SMS adapter. No user webhook key, subscription, WAN, DNS or OpenClash
 configuration is included.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/. $(PKG_BUILD_DIR)/
	$(CP) ./LICENSE.webui.GPL-3.0 ./LICENSE.qscan.MIT $(PKG_BUILD_DIR)/
endef

define Build/Configure
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) -D_GNU_SOURCE -static -o $(PKG_BUILD_DIR)/atsend $(PKG_BUILD_DIR)/atsend.c
	$(TARGET_CC) $(TARGET_CFLAGS) -D_GNU_SOURCE -static -o $(PKG_BUILD_DIR)/qscan-worker $(PKG_BUILD_DIR)/qscan-worker.c
endef

define Package/h5000m-modem-support/install
	$(INSTALL_DIR) $(1)
	$(CP) ./files/. $(1)/
	$(INSTALL_DIR) $(1)/usr/libexec/qscan
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/atsend $(1)/usr/libexec/qscan/atsend
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/qscan-worker $(1)/usr/libexec/qscan/qscan-worker
endef

$(eval $(call BuildPackage,h5000m-modem-support))
