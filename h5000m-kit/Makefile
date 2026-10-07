#
# h5000m-kit —— 把 H5000M 的全部定制烤进固件
#
# 设计原则：
#  1) 自己新增的文件（/usr/bin/*.sh 等）直接安装，不与任何厂商包冲突。
#  2) 需要"覆盖厂商文件/必须最后生效"的东西（sendat wrapper、ModemWebUI 前端 chunk、
#     sms_forwarder_next 时区修正版），放到 /usr/share/h5000m-kit/overlay/ 下，
#     由 /etc/uci-defaults/99-h5000m-kit 在首次启动时注入 —— 这样不受包安装顺序影响。
#  3) 配置改动也在这个 uci-defaults 里做（幂等），不直接覆盖 /etc/config/* 以免
#     和 qmodem / openclash 等包自己的默认配置打架。
#
include $(TOPDIR)/rules.mk

PKG_NAME:=h5000m-kit
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=11Lying

include $(INCLUDE_DIR)/package.mk

define Package/h5000m-kit
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Hiveton H5000M full customization kit (AT isolation / SMS / QSCAN / fan / ipv6)
  DEPENDS:=+coreutils-sha1sum +jq +curl +kmod-usb-serial-option
  PKGARCH:=all
endef

define Package/h5000m-kit/description
  Everything we built on top of the stock H5000M firmware, baked in so that a
  clean flash comes up already configured:
   - AT dual-port isolation (ttyUSB3=qmodem/SMS, ttyUSB2=WebUI)
   - SMS -> WeCom forwarding (+8h timestamp fix)
   - ModemWebUI QSCAN / neighbour-cell v8 frontend patches
   - QMI auto-recovery, ModemWebUI websocket guard
   - fancontrol (CPU+WiFi) + early-boot PWM init
   - IPv6 fast-fail for foreign destinations
   - OpenClash WAN-DNS injection + subscription build helpers
endef

define Build/Compile
	true
endef

define Package/h5000m-kit/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(CP) ./files/usr/bin/* $(1)/usr/bin/

	$(INSTALL_DIR) $(1)/usr/libexec/qscan
	$(CP) ./files/usr/libexec/qscan/* $(1)/usr/libexec/qscan/

	$(INSTALL_DIR) $(1)/usr/share/sms_forwarder
	$(CP) ./files/usr/share/sms_forwarder/* $(1)/usr/share/sms_forwarder/

	$(INSTALL_DIR) $(1)/etc/init.d
	$(CP) ./files/etc/init.d/* $(1)/etc/init.d/

	$(INSTALL_DIR) $(1)/etc/hotplug.d/usb $(1)/etc/hotplug.d/iface
	$(CP) ./files/etc/hotplug.d/usb/* $(1)/etc/hotplug.d/usb/
	$(CP) ./files/etc/hotplug.d/iface/* $(1)/etc/hotplug.d/iface/

	$(INSTALL_DIR) $(1)/etc
	$(CP) ./files/etc/ipv6-cn.list $(1)/etc/
	$(CP) ./files/etc/ipv6-cn-extra.list $(1)/etc/

	# 首次启动注入源（含需要覆盖厂商文件的东西）
	$(INSTALL_DIR) $(1)/usr/share/h5000m-kit
	$(CP) ./files/usr/share/h5000m-kit/overlay $(1)/usr/share/h5000m-kit/
	$(CP) ./files/usr/share/h5000m-kit/patch-webui.sh $(1)/usr/share/h5000m-kit/

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(CP) ./files/etc/uci-defaults/99-h5000m-kit $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,h5000m-kit))
