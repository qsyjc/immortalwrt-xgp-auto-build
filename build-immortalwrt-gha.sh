#!/usr/bin/env bash
set -euo pipefail

# -------------------------
# build-immortalwrt.sh
# place at repo root and run from there
# -------------------------
ROOT="$PWD"
IW_DIR="$ROOT/immortalwrt"
LOG="$ROOT/immortalwrt-build.log"
NUMJOBS="${NUMJOBS:-$(nproc)}"
IMMORTAL_REPO="${IMMORTAL_REPO:-https://github.com/immortalwrt/immortalwrt.git}"
IMMORTAL_BRANCH="${IMMORTAL_BRANCH:-master}"   # or your snapshot branch
QMODEM_FEED_LINE="src-git qmodem https://github.com/FUjr/QModem.git;main"

echo "=== ImmortalWrt Auto Build ==="
echo "Workdir: $ROOT"
echo "Immortal dir: $IW_DIR"
echo "Log: $LOG"

# tee everything to log
exec > >(tee -a "$LOG") 2>&1

# helper
git_clone_or_pull() {
  url="$1"; dir="$2"
  if [ ! -d "$dir/.git" ]; then
    echo "[+] Cloning $url -> $dir"
    git clone "$url" "$dir"
  else
    echo "[+] Pulling $dir"
    (cd "$dir" && git pull --ff-only || true)
  fi
}

# 1. clone or update immortalwrt
if [ ! -d "$IW_DIR/.git" ]; then
  echo "[+] Cloning immortalwrt..."
  git clone --depth=1 --branch "$IMMORTAL_BRANCH" "$IMMORTAL_REPO" "$IW_DIR"
else
  echo "[+] Updating immortalwrt..."
  cd "$IW_DIR"
  # if working tree dirty, stash then pull
  if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
    echo "  - local changes: stash -> pull -> pop"
    git stash save -u "auto-stash-before-ci" || true
    git pull --rebase || git pull || true
    git stash pop || true
  else
    git pull --rebase || git pull || true
  fi
  cd "$ROOT"
fi

cd "$IW_DIR"

# 2. ensure qmodem feed line exists
if ! grep -qF "$QMODEM_FEED_LINE" feeds.conf.default 2>/dev/null; then
  echo "$QMODEM_FEED_LINE" >> feeds.conf.default
  echo "[+] Added qmodem feed to feeds.conf.default"
fi

# 3. update & install feeds
echo "[+] Updating feeds"
./scripts/feeds update -a || { echo "feeds update failed"; exit 1; }
./scripts/feeds install -a || { echo "feeds install failed"; exit 1; }

# 4. ensure third-party packages (tailscale, easytier, lucky, screen drivers)
mkdir -p package/zz
git_clone_or_pull https://github.com/zzzz0317/kmod-fb-tft-gc9307.git package/zz/kmod-fb-tft-gc9307
git_clone_or_pull https://github.com/zzzz0317/xgp-v3-screen.git package/zz/xgp-v3-screen
git_clone_or_pull https://github.com/asvow/luci-app-tailscale package/luci-app-tailscale
git_clone_or_pull https://github.com/EasyTier/luci-app-easytier.git package/luci-app-easytier
git_clone_or_pull https://github.com/sirpdboy/luci-app-lucky.git package/lucky

# 5. sanitize tailscale default install options (like the example repo)
if [ -f feeds/packages/net/tailscale/Makefile ]; then
  sed -i '/\/etc\/init\.d\/tailscale/d;/\/etc\/config\/tailscale/d;' feeds/packages/net/tailscale/Makefile || true
fi

# 6. pin odhcpd and odhcp6c versions if files exist
if [ -f package/network/services/odhcpd/Makefile ]; then
  echo "[+] Pinning odhcpd version"
  sed -i "s/^PKG_SOURCE_DATE:=.*/PKG_SOURCE_DATE:=2025-10-26/" package/network/services/odhcpd/Makefile || true
  sed -i "s/^PKG_SOURCE_VERSION:=.*/PKG_SOURCE_VERSION:=fc27940fe9939f99aeb988d021c7edfa54460123/" package/network/services/odhcpd/Makefile || true
  sed -i "s/^PKG_MIRROR_HASH:=.*/PKG_MIRROR_HASH:=acb086731fd7d072ddddc1d5f3bad9377e89a05597ce004d24bd0cdb60586f0a/" package/network/services/odhcpd/Makefile || true
fi

if [ -f package/network/ipv6/odhcp6c/Makefile ]; then
  echo "[+] Pinning odhcp6c version"
  sed -i "s/^PKG_SOURCE_DATE:=.*/PKG_SOURCE_DATE:=2025-10-21/" package/network/ipv6/odhcp6c/Makefile || true
  sed -i "s/^PKG_SOURCE_VERSION:=.*/PKG_SOURCE_VERSION:=77e1ae21e67f81840024ffe5bb7cf69a8fb0d2f0/" package/network/ipv6/odhcp6c/Makefile || true
  sed -i "s/^PKG_MIRROR_HASH:=.*/PKG_MIRROR_HASH:=78f1c2342330da5f6bf08a4be89df1d771661966bbff13bd15462035de46837b/" package/network/ipv6/odhcp6c/Makefile || true
fi

# 7. prepare files/ for firstboot and runtime (uci-defaults + sysupgrade keep)
mkdir -p files/etc/uci-defaults files/etc/hotplug.d/usb files/etc/hotplug.d/pci files/lib/upgrade/keep.d

# copy qmodem default config from feed if available
if [ -f feeds/qmodem/application/qmodem/files/etc/config/qmodem ]; then
  mkdir -p files/etc/config
  cp -f feeds/qmodem/application/qmodem/files/etc/config/qmodem files/etc/config/qmodem || true
fi

# ensure sysupgrade keeps qmodem and mwan3
cat > files/lib/upgrade/keep.d/zz-qmodem <<'EOF'
etc/config/qmodem
etc/config/mwan3
etc/config/network
etc/config/wireless
EOF

# inject firstboot wifi/network safe default (safe and deterministic)
cat > files/etc/uci-defaults/99-firstboot-safe <<'EOF'
#!/bin/sh
uci batch <<EOT
set network.lan=interface
set network.lan.proto='static'
set network.lan.device='br-lan'
set network.lan.ipaddr='10.0.0.1'
set network.lan.netmask='255.255.255.0'
commit network
EOT

# basic wifi uci (if no wifi-iface exist, create one)
if ! uci show wireless 2>/dev/null | grep -q '=wifi-iface'; then
  uci add wireless wifi-iface
  last=\$(uci show wireless | tail -n1 | cut -d. -f2)
  uci set wireless.\$last.device='radio0'
  uci set wireless.\$last.mode='ap'
  uci set wireless.\$last.network='lan'
  uci set wireless.\$last.ssid='zzXGP'
  uci set wireless.\$last.encryption='psk2+ccmp'
  uci set wireless.\$last.key='xgpxgpxgp'
fi

uci commit wireless || true
uci commit network || true

# enable runtime optimizer if exists
[ -f /etc/init.d/zz-runtime-optimize ] && /etc/init.d/zz-runtime-optimize enable || true

exit 0
EOF
chmod +x files/etc/uci-defaults/99-firstboot-safe

# 8. add hotplug scripts for qmodem auto-detect (usb + pci)
cat > files/etc/hotplug.d/usb/30-qmodem-autoslot <<'EOF'
#!/bin/sh
[ "$ACTION" != "add" ] && exit 0
case "$DEVPATH" in
  */usb*)
    # simple slot name
    SLOT="$(basename $DEVPATH)"
    uci -q add qmodem modem-slot
    sec=$(uci show qmodem 2>/dev/null | tail -n1 | cut -d. -f2)
    uci -q set qmodem.$sec.type='usb'
    uci -q set qmodem.$sec.slot="$SLOT"
    uci -q set qmodem.$sec.alias="wwan_$SLOT"
    uci commit qmodem
    /etc/init.d/qmodem restart
    ;;
esac
EOF
chmod +x files/etc/hotplug.d/usb/30-qmodem-autoslot

cat > files/etc/hotplug.d/pci/30-qmodem-autoslot <<'EOF'
#!/bin/sh
[ "$ACTION" != "add" ] && exit 0
# PCI_SLOT_NAME is provided by kernel hotplug
SLOT="$PCI_SLOT_NAME"
uci -q add qmodem modem-slot
sec=$(uci show qmodem 2>/dev/null | tail -n1 | cut -d. -f2)
uci -q set qmodem.$sec.type='pcie'
uci -q set qmodem.$sec.slot="$SLOT"
uci -q set qmodem.$sec.alias="mpcie_$SLOT"
uci commit qmodem
/etc/init.d/qmodem restart
EOF
chmod +x files/etc/hotplug.d/pci/30-qmodem-autoslot

# 9. add uci-defaults to setup simple mwan3 mapping (best-effort, will not override complex setups)
cat > files/etc/uci-defaults/91-mwan3-qmodem <<'EOF'
#!/bin/sh
# best-effort create simple mwan3 policy mapping modem <-> wan
if [ -f /etc/config/mwan3 ] ; then
  ucicmd() { uci -q set "$@"; }
  if ! uci -q get mwan3.default >/dev/null 2>&1; then
    uci add mwan3 policy
    uci set mwan3.@policy[-1].name='balanced'
    uci commit mwan3
  fi
fi
exit 0
EOF
chmod +x files/etc/uci-defaults/91-mwan3-qmodem

# 10. ensure sysupgrade keep list (also create files/etc/sysupgrade.conf)
cat > files/etc/sysupgrade.conf <<'EOF'
/etc/config/qmodem
/etc/config/mwan3
/etc/config/network
/etc/config/wireless
EOF

# 11. ensure .config exists (from xgp.config if provided, else use existing .config or make defconfig)
if [ -f "$ROOT/xgp.config" ]; then
  echo "[+] using xgp.config as .config"
  cp "$ROOT/xgp.config" .config
else
  if [ ! -f .config ]; then
    echo "[+] generating default .config via make defconfig"
    make defconfig
  else
    echo "[+] .config exists, using it"
  fi
fi

# 12. show diff vs original xgp.config if exists
if [ -f "$ROOT/xgp.config" ]; then
  echo "=== diff xgp.config -> .config ==="
  diff -u "$ROOT/xgp.config" .config || true
fi

# 13. make download
echo "[+] make download"
make download -j"$NUMJOBS" || { echo "download failed"; exit 1; }

# 14. build, capture first 'error:' if fails
echo "[+] make"
if ! make -j"$NUMJOBS" V=s 2>&1 | tee -a "$LOG"; then
  echo "❌ BUILD FAILED, extracting first error..."
  FIRSTERR=$(grep -n -i "error:" "$LOG" | head -n1 || true)
  if [ -n "$FIRSTERR" ]; then
    echo "First error in build log: $FIRSTERR"
    sed -n "$(( ( $(echo $FIRSTERR | cut -d: -f1) - 10 ) > 1 ? $(echo $FIRSTERR | cut -d: -f1) - 10 : 1 )),$(( $(echo $FIRSTERR | cut -d: -f1) + 10 ))p" "$LOG" || true
  else
    tail -n200 "$LOG"
  fi
  exit 1
fi

echo "✅ BUILD SUCCESS"
echo "Artifacts in $IW_DIR/bin/targets/"
