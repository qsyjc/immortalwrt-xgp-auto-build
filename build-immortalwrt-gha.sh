#!/usr/bin/env bash
set -e
set -o pipefail

WORKDIR="$PWD"
REPO_DIR="$WORKDIR/immortalwrt"
LOG="$WORKDIR/immortalwrt-build.log"

echo "🚀 ImmortalWrt Auto Build"
echo "📁 Workdir: $WORKDIR"
echo "📝 Log: $LOG"

exec > >(tee -a "$LOG") 2>&1

# 1. 拉取 / 更新源码
if [ -d "$REPO_DIR/.git" ]; then
  echo "[+] Update ImmortalWrt source"
  cd "$REPO_DIR"
  git reset --hard
  git clean -fd
  git pull
else
  echo "[+] Clone ImmortalWrt source"
  git clone https://github.com/immortalwrt/immortalwrt.git
  cd "$REPO_DIR"
fi

# 2. feeds
echo "[+] Update feeds"
./scripts/feeds update -a
./scripts/feeds install -a

# 3. 默认 config（你后面可以替换成自定义）
echo "[+] Generate default config"
make defconfig

# 4. 下载源码
echo "[+] make download"
make download -j$(nproc)

# 5. 编译
echo "[+] Compile firmware"
make -j$(nproc) || {
  echo "❌ BUILD FAILED"
  grep -R "error:" -n build_dir | head -n 1 || true
  exit 1
}

echo "✅ BUILD SUCCESS"
