#!/usr/bin/env bash
set -e
set -o pipefail

WORKDIR="$PWD"
LOG="$WORKDIR/immortalwrt-build.log"
REPO="https://github.com/immortalwrt/immortalwrt.git"
BRANCH="openwrt-23.05"

echo "🧠 ImmortalWrt Auto Build"
echo "📁 Workdir: $WORKDIR"
echo "📄 Log: $LOG"

exec > >(tee -a "$LOG") 2>&1

# ---------- clone or update ----------
if [ ! -d immortalwrt ]; then
  git clone -b $BRANCH --depth=1 $REPO immortalwrt
else
  cd immortalwrt
  git reset --hard
  git clean -fd
  git pull
  cd ..
fi

cd immortalwrt

# ---------- feeds ----------
./scripts/feeds update -a
./scripts/feeds install -a

# ---------- extra packages ----------
ensure_pkg() {
  local url="$1"
  local dir="$2"

  if [ ! -d "$dir/.git" ]; then
    git clone "$url" "$dir"
  else
    (cd "$dir" && git pull)
  fi
}

mkdir -p package/zz

ensure_pkg https://github.com/zzzz0317/kmod-fb-tft-gc9307.git package/zz/kmod-fb-tft-gc9307
ensure_pkg https://github.com/zzzz0317/xgp-v3-screen.git package/zz/xgp-v3-screen
ensure_pkg https://github.com/asvow/luci-app-tailscale package/luci-app-tailscale
ensure_pkg https://github.com/EasyTier/luci-app-easytier.git package/luci-app-easytier
ensure_pkg https://github.com/sirpdboy/luci-app-lucky.git package/lucky

# ---------- fix tailscale ----------
sed -i '/\/etc\/init\.d\/tailscale/d;/\/etc\/config\/tailscale/d;' \
  feeds/packages/net/tailscale/Makefile || true

# ---------- odhcpd pin ----------
sed -i '
/^PKG_SOURCE_DATE:=/c\PKG_SOURCE_DATE:=2025-10-26
/^PKG_SOURCE_VERSION:=/c\PKG_SOURCE_VERSION:=fc27940fe9939f99aeb988d021c7edfa54460123
/^PKG_MIRROR_HASH:=/c\PKG_MIRROR_HASH:=acb086731fd7d072ddddc1d5f3bad9377e89a05597ce004d24bd0cdb60586f0a
' package/network/services/odhcpd/Makefile

# ---------- odhcp6c pin ----------
sed -i '
/^PKG_SOURCE_DATE:=/c\PKG_SOURCE_DATE:=2025-10-21
/^PKG_SOURCE_VERSION:=/c\PKG_SOURCE_VERSION:=77e1ae21e67f81840024ffe5bb7cf69a8fb0d2f0
/^PKG_MIRROR_HASH:=/c\PKG_MIRROR_HASH:=78f1c2342330da5f6bf08a4be89df1d771661966bbff13bd15462035de46837b
' package/network/ipv6/odhcp6c/Makefile

# ---------- wifi defaults ----------
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-wifi << 'EOF'
#!/bin/sh
uci batch <<EOT
set wireless.@wifi-device[0].country='US'
set wireless.@wifi-iface[0].ssid='ImmortalWrt'
set wireless.@wifi-iface[0].encryption='psk2'
set wireless.@wifi-iface[0].key='88888888'
set wireless.@wifi-iface[0].disabled='0'
EOT
uci commit wireless
rm -f /etc/uci-defaults/99-wifi
EOF
chmod +x files/etc/uci-defaults/99-wifi

# ---------- config ----------
cp defconfig .config
make defconfig

# ---------- build ----------
make -j$(nproc) || {
  echo "❌ BUILD FAILED"
  grep -n "error:" -m1 "$LOG" || true
  exit 1
}

echo "✅ BUILD SUCCESS"
