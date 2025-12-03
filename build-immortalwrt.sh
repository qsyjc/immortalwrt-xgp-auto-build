#!/bin/bash
set -e
echo "=== ImmortalWrt 自动构建 ==="

WORKDIR="$PWD"
IMMORTAL_DIR="$WORKDIR/immortalwrt"
LOGFILE="$WORKDIR/immortalwrt-build.log"

echo "工作目录：$WORKDIR"
echo "Immortal 目录：$IMMORTAL_DIR"
echo "日志：$LOGFILE"

# 1. 克隆或更新 ImmortalWrt
if [ -d "$IMMORTAL_DIR/.git" ]; then
    echo "[+] ImmortalWrt 已存在，执行 git pull 更新源码"
    cd "$IMMORTAL_DIR"
    git reset --hard HEAD
    git clean -fd
    git pull
else
    echo "[+] 克隆 ImmortalWrt"
    git clone https://github.com/immortalwrt/immortalwrt.git "$IMMORTAL_DIR"
fi

cd "$IMMORTAL_DIR"

# 2. 检测插件拉取
PLUGINS=(
  "https://github.com/FUjr/QModem.git package/qmodem"
  "https://github.com/asvow/luci-app-tailscale.git package/luci-app-tailscale"
  "https://github.com/EasyTier/luci-app-easytier.git package/luci-app-easytier"
  "https://github.com/sirpdboy/luci-app-lucky.git package/lucky"
  "https://github.com/zzzz0317/kmod-fb-tft-gc9307.git package/zz/kmod-fb-tft-gc9307"
  "https://github.com/zzzz0317/xgp-v3-screen.git package/zz/xgp-v3-screen"
)

for p in "${PLUGINS[@]}"; do
  URL=$(echo $p | awk '{print $1}')
  DIR=$(echo $p | awk '{print $2}')
  if [ -d "$DIR/.git" ]; then
    echo "[=] update $DIR"
    cd "$DIR"
    git reset --hard HEAD
    git clean -fd
    git pull
    cd "$IMMORTAL_DIR"
  else
    echo "[=] clone $DIR"
    git clone "$URL" "$DIR"
  fi
done

# 3. 更新 feeds
./scripts/feeds update -a
./scripts/feeds install -a
./scripts/feeds install -a -f -p qmodem

# 4. 检测 odhcpd 和 odhcp6c 版本并修正
sed -i "s?PKG_MIRROR_HASH:=.*?PKG_MIRROR_HASH:=acb086731fd7d072ddddc1d5f3bad9377e89a05597ce004d24bd0cdb60586f0a?" package/network/services/odhcpd/Makefile
sed -i "s?PKG_SOURCE_DATE:=.*?PKG_SOURCE_DATE:=2025-10-26?" package/network/services/odhcpd/Makefile
sed -i "s?PKG_SOURCE_VERSION:=.*?PKG_SOURCE_VERSION:=fc27940fe9939f99aeb988d021c7edfa54460123?" package/network/services/odhcpd/Makefile

sed -i "s?PKG_SOURCE_DATE:=.*?PKG_SOURCE_DATE:=2025-10-21?" package/network/ipv6/odhcp6c/Makefile
sed -i "s?PKG_SOURCE_VERSION:=.*?PKG_SOURCE_VERSION:=77e1ae21e67f81840024ffe5bb7cf69a8fb0d2f0?" package/network/ipv6/odhcp6c/Makefile
sed -i "s?PKG_MIRROR_HASH:=.*?PKG_MIRROR_HASH:=78f1c2342330da5f6bf08a4be89df1d771661966bbff13bd15462035de46837b?" package/network/ipv6/odhcp6c/Makefile

# 5. 使用默认配置
cp .config .config.backup || true
make defconfig

# 6. 构建
echo "[+] 开始构建..."
make -j$(nproc) V=0

# 7. WiFi 默认配置（US, 密码88888888）
cat > files/etc/uci-defaults/99-wifi <<'EOF'
#!/bin/sh
uci set wireless.radio0.country='US'
uci set wireless.default_radio0.ssid='ImmortalXGP'
uci set wireless.default_radio0.encryption='psk2+ccmp'
uci set wireless.default_radio0.key='88888888'
uci set wireless.default_radio1.ssid='ImmortalXGP'
uci set wireless.default_radio1.encryption='psk2+ccmp'
uci set wireless.default_radio1.key='88888888'
uci commit wireless
EOF
chmod +x files/etc/uci-defaults/99-wifi

echo "[+] 构建完成，固件在 bin/targets/ 目录下"
