#
# h5000m-kit —— 把 H5000M 的全部定制烤进固件
#
# 安装方式：整棵 files/ 树原样拷进包目录（files/bin files/etc files/usr files/www）。
# 不要逐个子目录列举 —— 曾经漏掉 /www/webui 与 /usr/lib/lua/luci，导致整个
# ModemWebUI 面板不进固件。
#
# 设计原则：
#  1) 自己新增的文件（/usr/bin/*.sh、/www/webui、lua controller/view 等）直接安装，
#     不与任何厂商包冲突（厂商面板包的内容已预先并入本包）。
#  2) 唯一需要"盖住别人文件"的是 /bin/sendat（feed 里另有一个同名 sendat 包），
#     放在 files/usr/share/h5000m-kit/overlay/ 下，由
#     /etc/uci-defaults/99-h5000m-kit 首次启动时注入，避免依赖包安装顺序。
#  3) 配置改动也在这个 uci-defaults 里做（幂等），不直接覆盖 /etc/config/*，
#     以免和 qmodem / openclash 等包自己的默认配置打架。
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
	$(INSTALL_DIR) $(1)
	$(CP) ./files/. $(1)/
endef

$(eval $(call BuildPackage,h5000m-kit))
