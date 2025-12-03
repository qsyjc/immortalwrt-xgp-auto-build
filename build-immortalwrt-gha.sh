#!/usr/bin/env bash
set -euo pipefail

echo "🚀 ImmortalWrt Build Script"

WORKDIR="$(pwd)"
LOG="$WORKDIR/immortalwrt-build.log"

exec > >(tee "$LOG") 2>&1

REPO_URL="https://github.com/immortalwrt/immortalwrt.git"
REPO_DIR="immortalwrt"

echo "📁 Workdir: $WORKDIR"
echo "📄 Log file: $LOG"

#############################################
# 1️⃣ 获取 / 更新 ImmortalWrt 源码
#############################################
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  echo "🔧 GitHub Actions mode detected"

  if [ ! -d "$REPO_DIR" ]; then
    echo "❌ immortalwrt directory missing in GHA"
    exit 1
  fi

else
  echo "🔧 Local build mode"

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
fi

cd "$REPO_DIR"

#############################################
# 2️⃣ feeds
#############################################
echo "🔄 Update feeds"
./scripts/feeds update -a
./scripts/feeds install -a

#############################################
# 3️⃣ QModem feed
#############################################
if ! grep -q "^src-git qmodem " feeds.conf.default; then
  echo "➕ add qmodem feed"
  echo "src-git qmodem https://github.com/FUjr/QModem.git;main" >> feeds.conf.default
fi

./scripts/feeds update qmodem
./scripts/feeds install -a -f -p qmodem

#############################################
# 4️⃣ 自定义插件（存在就更新，不在就拉）
#############################################
mkdir -p package/zz

clone_or_update() {
  local url="$1"
  local dir="$2"

  if [ ! -d "$dir/.git" ]; then
    echo "[+] clone $dir"
    git clone --depth=1 "$url" "$dir"
  else
    echo "[=] update $dir"
    git -C "$dir" reset --hard || true
    git -C "$dir" pull --ff-only || true
  fi
}

clone_or_update https://github.com/zzzz0317/kmod-fb-tft-gc9307.git package/zz/kmod-fb-tft-gc9307
clone_or_update https://github.com/zzzz0317/xgp-v3-screen.git        package/zz/xgp-v3-screen
clone_or_update https://github.com/asvow/luci-app-tailscale.git     package/luci-app-tailscale
clone_or_update https://github.com/EasyTier/luci-app-easytier.git   package/luci-app-easytier
clone_or_update https://github.com/sirpdboy/luci-app-lucky.git      package/lucky

#############################################
# 5️⃣ 修 tailscale Makefile
#############################################
sed -i '/\/etc\/init\.d\/tailscale/d;/\/etc\/config\/tailscale/d;' \
  feeds/packages/net/tailscale/Makefile || true

#############################################
# 6️⃣ files 目录
#############################################
mkdir -p files/etc/uci-defaults
mkdir -p files/etc/config

#############################################
# 7️⃣ WiFi 默认配置（US + 固定密码）
#############################################
cat > files/etc/uci-defaults/99-wifi <<'EOF'
#!/bin/sh
uci set wireless.@wifi-device[0].country='US'
uci set wireless.@wifi-iface[0].encryption='psk2'
uci set wireless.@wifi-iface[0].key='88888888'
uci commit wireless
EOF
chmod +x files/etc/uci-defaults/99-wifi

#############################################
# 8️⃣ 使用 xgp.config
#############################################
if [ ! -f "$WORKDIR/xgp.config" ]; then
  echo "❌ xgp.config not found in repo root"
  exit 1
fi

echo "⚙️ apply xgp.config"
cp "$WORKDIR/xgp.config" .config
make defconfig

#############################################
# 9️⃣ 下载源码
#############################################
echo "⬇️ make download"
make download -j"$(nproc)"

#############################################
# 🔟 正式编译
#############################################
echo "🔥 building firmware..."
if ! make -j"$(nproc)"; then
  echo "❌ BUILD FAILED"
  echo "🔍 First error:"
  grep -n -E " error:|^make\\[.*Error|^ERROR:" "$LOG" | head -n 1 || true
  exit 1
fi

#############################################
# ✅ 编译结果检查
#############################################
TARGET_DIR="bin/targets"

if [ ! -d "$TARGET_DIR" ]; then
  echo "❌ No targets directory generated"
  exit 1
fi

if ! find "$TARGET_DIR" -name "*sysupgrade*.img*" | grep -q .; then
  echo "❌ No firmware image generated"
  exit 1
fi

#############################################
# ✅ 成功输出
#############################################
echo "✅ BUILD SUCCESS"
echo "📦 Firmware output:"
find "$TARGET_DIR" -name "*sysupgrade*.img*" -ls
