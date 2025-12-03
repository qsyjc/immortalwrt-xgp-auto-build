#!/bin/bash
set -e
set -o pipefail

# -----------------------------
# 工作目录和日志
# -----------------------------
ROOT_DIR="$PWD"
IW_DIR="$ROOT_DIR/immortalwrt"
BUILD_LOG="$ROOT_DIR/immortalwrt-build.log"

echo "🚀 ImmortalWrt GHA Full Build"
echo "📁 Workdir: $ROOT_DIR"
echo "🧾 Log: $BUILD_LOG"

# -----------------------------
# 1️⃣ 获取 / 更新源码
# -----------------------------
if [ ! -d "$IW_DIR/.git" ]; then
    echo "[+] Clone ImmortalWrt"
    git clone https://github.com/immortalwrt/immortalwrt.git "$IW_DIR"
else
    echo "[+] Update ImmortalWrt"
    cd "$IW_DIR"
    if [ -n "$(git status --porcelain)" ]; then
        echo "[!] Local changes detected, auto stash"
        git stash save "auto-stash-before-build"
        git pull --rebase
        git stash pop || true
    else
        git pull --rebase
    fi
fi

cd "$IW_DIR"

# -----------------------------
# 2️⃣ feeds + QModem
# -----------------------------
grep -q "src-git qmodem" feeds.conf.default || \
echo "src-git qmodem https://github.com/FUjr/QModem.git;main" >> feeds.conf.default

echo "[+] Update all feeds"
./scripts/feeds update -a
./scripts/feeds install -a

echo "[+] Update QModem feed"
./scripts/feeds update qmodem
./scripts/feeds install -a -p qmodem
./scripts/feeds install -a -f -p qmodem

# -----------------------------
# 3️⃣ 检测屏幕驱动插件
# -----------------------------
mkdir -p package/zz
for pkg in kmod-fb-tft-gc9307 xgp-v3-screen; do
    if [ ! -d "package/zz/$pkg/.git" ]; then
        echo "[+] Clone $pkg"
        git clone https://github.com/zzzz0317/$pkg.git package/zz/$pkg
    else
        echo "[=] Update package/zz/$pkg"
        cd package/zz/$pkg && git pull && cd -
    fi
done

# -----------------------------
# 4️⃣ 准备 files 目录
# -----------------------------
mkdir -p files/etc \
         files/etc/config \
         files/etc/uci-defaults \
         files/etc/udev/rules.d

# -----------------------------
# 5️⃣ QModem 默认配置 + 保留升级
# -----------------------------
cp feeds/qmodem/application/qmodem/files/etc/config/qmodem files/etc/config/qmodem
echo '/etc/config/qmodem' >> files/etc/sysupgrade.conf

cat >> files/etc/config/qmodem <<'EOF'
config global
	option keep_config '1'
EOF

# -----------------------------
# 6️⃣ 首次启动初始化 LAN/WiFi/UI
# -----------------------------
cat > files/etc/uci-defaults/99-firstboot <<'EOF'
#!/bin/sh
uci set system.@system[0].hostname='zzXGP'
uci commit system

uci set network.lan.ipaddr='10.0.11.1'
uci commit network

for radio in $(uci show wireless | grep "=wifi-device" | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.$radio.country='US'
    idx=$(echo $radio | tr -cd 0-9)
    iface="default_radio$idx"
    uci set wireless.$iface.ssid='zzXGP'
    uci set wireless.$iface.encryption='psk2+ccmp'
    uci set wireless.$iface.key='xgpxgpxgp'
done
uci commit wireless

uci set luci.main.lang='zh_cn'
uci set luci.main.mediaurlbase='/luci-static/argon'
uci commit luci
exit 0
EOF
chmod +x files/etc/uci-defaults/99-firstboot

# -----------------------------
# 7️⃣ QModem 热插 USB/PCIe + mwan3 自动策略
# -----------------------------
# udev 规则
cat > files/etc/udev/rules.d/99-qmodem-hotplug.rules <<'EOF'
SUBSYSTEM=="usb", ACTION=="add", RUN+="/etc/qmodem-hotplug.sh add %p"
SUBSYSTEM=="usb", ACTION=="remove", RUN+="/etc/qmodem-hotplug.sh remove %p"
EOF

# 热插 shell 脚本
cat > files/etc/qmodem-hotplug.sh <<'EOF'
#!/bin/sh
action=$1
path=$2

if [ "$action" = "add" ]; then
    [ -f "$path/idVendor" ] || exit 0
    uci add qmodem modem-slot
    uci set qmodem.@modem[-1].type='usb_auto'
    uci set qmodem.@modem[-1].slot="$path"
    uci set qmodem.@modem[-1].alias="$(basename $path)"
    uci commit qmodem

    # mwan3 自动注册接口
    iface="wan_$(basename $path)"
    uci set network.$iface=interface
    uci set network.$iface.proto='dhcp'
    uci set network.$iface.ifname="$path"
    uci set network.$iface.enabled='1'
    uci commit network
    uci commit mwan3
elif [ "$action" = "remove" ]; then
    # 可扩展删除逻辑
    exit 0
fi
EOF
chmod +x files/etc/qmodem-hotplug.sh

# -----------------------------
# 8️⃣ 应用 .config 或 defconfig
# -----------------------------
if [ -f "$ROOT_DIR/xgp.config" ]; then
    cp "$ROOT_DIR/xgp.config" .config
elif [ ! -f ".config" ]; then
    echo "[!] No config found, generate default defconfig"
    make defconfig
fi

# -----------------------------
# 9️⃣ download + build
# -----------------------------
set +e
make download -j$(nproc) V=s 2>&1 | tee "$BUILD_LOG"
make -j$(nproc) V=s 2>&1 | tee -a "$BUILD_LOG"
RET=$?
set -e

if [ $RET -ne 0 ]; then
    echo "❌ BUILD FAILED"
    grep -n "error:" "$BUILD_LOG" | head -n 1
    exit 1
fi

echo "✅ BUILD SUCCESS"

# -----------------------------
# 10️⃣ 打包 bin 路径检查
# -----------------------------
BIN_DIR="$IW_DIR/bin/targets/rockchip/armv8"
if [ -d "$BIN_DIR" ]; then
    echo "[+] Build artifacts at $BIN_DIR"
else
    echo "[!] Build output not found"
fi
