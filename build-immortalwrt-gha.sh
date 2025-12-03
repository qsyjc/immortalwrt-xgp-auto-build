#!/bin/bash
set -e

WORKDIR="$(pwd)"
LOG="$WORKDIR/immortalwrt-build.log"

echo "🚀 ImmortalWrt Auto Build" | tee "$LOG"
echo "📂 Workdir: $WORKDIR" | tee -a "$LOG"

##### 1. 获取 / 更新源码 #####
if [ ! -d immortalwrt ]; then
  git clone https://github.com/immortalwrt/immortalwrt.git
fi

cd immortalwrt

git config pull.rebase false
git stash >/dev/null 2>&1 || true
git pull | tee -a "$LOG"

##### 2. feeds 基础 #####
./scripts/feeds update -a | tee -a "$LOG"
./scripts/feeds install -a | tee -a "$LOG"

##### 3. QModem feed #####
grep -q qmodem feeds.conf.default || \
  echo "src-git qmodem https://github.com/FUjr/QModem.git;main" >> feeds.conf.default

./scripts/feeds update qmodem
./scripts/feeds install -a -f -p qmodem

##### 4. 第三方插件检测 #####
clone_or_update() {
  local url=$1
  local dir=$2
  if [ ! -d "$dir/.git" ]; then
    git clone "$url" "$dir"
  else
    git -C "$dir" pull
  fi
}

clone_or_update https://github.com/asvow/luci-app-tailscale package/luci-app-tailscale
clone_or_update https://github.com/EasyTier/luci-app-easytier package/luci-app-easytier
clone_or_update https://github.com/sirpdboy/luci-app-lucky package/lucky
clone_or_update https://github.com/zzzz0317/kmod-fb-tft-gc9307 package/zz/kmod-fb-tft-gc9307
clone_or_update https://github.com/zzzz0317/xgp-v3-screen package/zz/xgp-v3-screen

##### 5. 默认配置 #####
[ -f .config ] || make defconfig

##### 6. LAN / WiFi / 国家码 / WiFi密码 #####
mkdir -p files/etc/uci-defaults

cat > files/etc/uci-defaults/99-network << 'EOF'
uci batch <<EOT
set network.lan=interface
set network.lan.device='br-lan'
set network.lan.proto='static'
set network.lan.ipaddr='192.168.1.1'
set network.lan.netmask='255.255.255.0'
commit network
EOT
EOF

cat > files/etc/uci-defaults/99-wireless << 'EOF'
uci batch <<EOT
set wireless.radio0=wifi-device
set wireless.radio0.type='mac80211'
set wireless.radio0.disabled='0'
set wireless.radio0.country='US'

set wireless.default_radio0=wifi-iface
set wireless.default_radio0.device='radio0'
set wireless.default_radio0.network='lan'
set wireless.default_radio0.mode='ap'
set wireless.default_radio0.ssid='ImmortalWrt'
set wireless.default_radio0.encryption='psk2'
set wireless.default_radio0.key='88888888'
commit wireless
EOT
EOF

chmod +x files/etc/uci-defaults/*

##### 7. QModem 多模块热插 #####
mkdir -p files/etc/hotplug.d/{usb,pci}

# USB 热插
cat > files/etc/hotplug.d/usb/30-qmodem-autoslot <<'EOF'
#!/bin/sh
[ "$ACTION" != "add" ] && exit 0
case "$DEVPATH" in
  */usb*)
    uci -q set qmodem.wwan=modem-slot
    uci -q set qmodem.wwan.type='usb'
    uci -q set qmodem.wwan.slot="${DEVPATH##*/}"
    uci -q set qmodem.wwan.alias='wwan'
    uci -q set qmodem.wwan.ipv6='1'
    uci commit qmodem
    /etc/init.d/qmodem restart
    ;;
esac
EOF

# PCIe 热插
cat > files/etc/hotplug.d/pci/30-qmodem-autoslot <<'EOF'
#!/bin/sh
[ "$ACTION" != "add" ] && exit 0
uci -q set qmodem.mpcie1=modem-slot
uci -q set qmodem.mpcie1.type='pcie'
uci -q set qmodem.mpcie1.slot="$PCI_SLOT_NAME"
uci -q set qmodem.mpcie1.alias='mpcie1'
uci -q set qmodem.mpcie1.ipv6='1'

uci -q set qmodem.mpcie2=modem-slot
uci -q set qmodem.mpcie2.type='pcie'
uci -q set qmodem.mpcie2.slot="$PCI_SLOT_NAME"
uci -q set qmodem.mpcie2.alias='mpcie2'
uci -q set qmodem.mpcie2.ipv6='1'

uci commit qmodem
/etc/init.d/qmodem restart
EOF

chmod +x files/etc/hotplug.d/usb/* files/etc/hotplug.d/pci/*

##### 8. mwan3 IPv4 + IPv6 策略 #####
mkdir -p files/etc/uci-defaults

# IPv4
cat > files/etc/uci-defaults/91-mwan3-qmodem <<'EOF'
uci batch <<EOF2
set mwan3.modem=interface
set mwan3.modem.enabled='1'
set mwan3.modem.family='ipv4'
set mwan3.modem.track_ip='1.1.1.1'
set mwan3.modem.reliability='2'
set mwan3.modem.interval='5'

set mwan3.wan=interface
set mwan3.wan.enabled='1'
set mwan3.wan.track_ip='8.8.8.8'

set mwan3.modem_m=member
set mwan3.modem_m.interface='modem'
set mwan3.modem_m.metric='1'
set mwan3.modem_m.weight='3'

set mwan3.wan_m=member
set mwan3.wan_m.interface='wan'
set mwan3.wan_m.metric='2'
set mwan3.wan_m.weight='1'

set mwan3.default=policy
add_list mwan3.default.use_member='modem_m'
add_list mwan3.default.use_member='wan_m'

set mwan3.rule_all=rule
set mwan3.rule_all.dest_ip='0.0.0.0/0'
set mwan3.rule_all.use_policy='default'
EOF2
uci commit mwan3
EOF

# IPv6
cat > files/etc/uci-defaults/92-mwan3-ipv6 <<'EOF'
uci batch <<EOF2
set mwan3.modem6=interface
set mwan3.modem6.enabled='1'
set mwan3.modem6.family='ipv6'
set mwan3.modem6.track_ip='2001:4860:4860::8888'
set mwan3.modem6.reliability='2'
set mwan3.modem6.interval='5'

set mwan3.wan6=interface
set mwan3.wan6.enabled='1'
set mwan3.wan6.family='ipv6'
set mwan3.wan6.track_ip='2606:4700:4700::1111'

set mwan3.modem6_m=member
set mwan3.modem6_m.interface='modem6'
set mwan3.modem6_m.metric='1'
set mwan3.modem6_m.weight='3'

set mwan3.wan6_m=member
set mwan3.wan6_m.interface='wan6'
set mwan3.wan6_m.metric='2'
set mwan3.wan6_m.weight='1'

set mwan3.default6=policy
add_list mwan3.default6.use_member='modem6_m'
add_list mwan3.default6.use_member='wan6_m'

set mwan3.rule_all6=rule
set mwan3.rule_all6.dest_ip='::/0'
set mwan3.rule_all6.use_policy='default6'
EOF2
uci commit mwan3
EOF

chmod +x files/etc/uci-defaults/*

##### 9. sysupgrade 保留 QModem / mwan3 / 网络配置 #####
mkdir -p files/etc
cat > files/etc/sysupgrade.conf <<'EOF'
/etc/config/qmodem
/etc/config/mwan3
/etc/config/network
/etc/config/wireless
EOF

##### 10. 下载 + 编译 #####
make download -j$(nproc) || exit 1

if ! make -j$(nproc); then
  echo "❌ BUILD FAILED"
  grep -R "error:" build_dir | head -n 20
  exit 1
fi

echo "✅ BUILD SUCCESS"
