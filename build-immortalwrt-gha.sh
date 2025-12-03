#!/usr/bin/env bash
set -e

echo "🚀 ImmortalWrt GHA Build"
WORKDIR="$(pwd)"
LOG="$WORKDIR/immortalwrt-build.log"

exec > >(tee "$LOG") 2>&1

# 基础变量
REPO_URL="https://github.com/immortalwrt/immortalwrt.git"
REPO_DIR="immortalwrt"

echo "📁 Workdir: $WORKDIR"

# 1️⃣ 拉取 / 更新 ImmortalWrt
if [ ! -d "$REPO_DIR/.git" ]; then
  echo "[+] clone immortalwrt"
  git clone --depth=1 "$REPO_URL" "$REPO_DIR"
else
  echo "[+] update immortalwrt"
  cd "$REPO_DIR"
  git reset --hard
  git pull --ff-only
  cd ..
fi

cd "$REPO_DIR"

# 2️⃣ feeds
./scripts/feeds update -a
./scripts/feeds install -a

# 3️⃣ QModem feed
if ! grep -q "^src-git qmodem " feeds.conf.default; then
  echo "src-git qmodem https://github.com/FUjr/QModem.git;main" >> feeds.conf.default
fi
./scripts/feeds update qmodem
./scripts/feeds install -a -f -p qmodem

# 4️⃣ 自定义插件（存在就更新，不在就拉）
mkdir -p package/zz

clone_or_update() {
  local url=$1
  local dir=$2
  if [ ! -d "$dir/.git" ]; then
    echo "[+] clone $dir"
    git clone --depth=1 "$url" "$dir"
  else
    echo "[=] update $dir"
    git -C "$dir" pull --ff-only || true
  fi
}

clone_or_update https://github.com/zzzz0317/kmod-fb-tft-gc9307.git package/zz/kmod-fb-tft-gc9307
clone_or_update https://github.com/zzzz0317/xgp-v3-screen.git        package/zz/xgp-v3-screen
clone_or_update https://github.com/asvow/luci-app-tailscale.git     package/luci-app-tailscale
clone_or_update https://github.com/EasyTier/luci-app-easytier.git   package/luci-app-easytier
clone_or_update https://github.com/sirpdboy/luci-app-lucky.git      package/lucky

# 5️⃣ 修 tailscale Makefile
sed -i '/\/etc\/init\.d\/tailscale/d;/\/etc\/config\/tailscale/d;' \
  feeds/packages/net/tailscale/Makefile || true

# 6️⃣ 防止文件目录不存在
mkdir -p files/etc/uci-defaults
mkdir -p files/etc/config

# 7️⃣ WiFi 默认配置（US + 固定密码）
cat > files/etc/uci-defaults/99-wifi <<'EOF'
#!/bin/sh
uci set wireless.@wifi-device[0].country='US'
uci set wireless.@wifi-iface[0].encryption='psk2'
uci set wireless.@wifi-iface[0].key='88888888'
uci commit wireless
EOF
chmod +x files/etc/uci-defaults/99-wifi

# 8️⃣ 使用 xgp.config
if [ ! -f "$WORKDIR/xgp.config" ]; then
  echo "❌ xgp.config not found"
  exit 1
fi

cp "$WORKDIR/xgp.config" .config
make defconfig

# 9️⃣ 下载源码
make download -j$(nproc)

# 🔟 正式编译（失败自动抓第一个 error）
echo "🔥 building firmware..."
if ! make -j$(nproc); then
  echo "❌ BUILD FAILED"
  echo "🔍 First error:"
  grep -n "error:" "$LOG" | head -n 1 || true
  exit 1
fi

echo "✅ BUILD SUCCESS"

# 1️⃣1️⃣ 输出产物路径（rockchip / xgp）
echo "📦 Firmware output:"
ls -lh bin/targets/*/* || true
