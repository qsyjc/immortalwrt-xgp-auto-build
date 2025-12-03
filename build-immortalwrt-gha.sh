#!/usr/bin/env bash
set -Eeuo pipefail

# build-immortalwrt.sh
# 用途：准备 files/（首启脚本、udev 热插、qmodem/mwan3 watcher、版本信息等），更新 feeds、拉插件、编译 ImmortalWrt。
# 兼容本地和 GitHub Actions（会把日志输出到文件）。

WORKDIR="$(pwd)"
IW_DIR="$WORKDIR/immortalwrt"
LOG_FILE="$WORKDIR/immortalwrt-build.log"
NPROC=$(nproc || echo 2)

exec > >(tee -a "$LOG_FILE") 2>&1

echo "🚀 ImmortalWrt Auto Build (full pipeline)"
echo "📁 Workdir: $WORKDIR"
echo "🧾 Log: $LOG_FILE"

# ---- clone / update (auto-stash safe) ----
if [ ! -d "$IW_DIR/.git" ]; then
  echo "[+] Clone ImmortalWrt"
  git clone https://github.com/immortalwrt/immortalwrt.git "$IW_DIR"
fi
cd "$IW_DIR"

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  echo "[!] Local changes detected in immortalwrt, auto-stash"
  git stash push -u -m "auto-stash-before-build" >/dev/null || true
fi
git pull --rebase || git pull || true

# ---- ensure feeds helper is executable ----
if [ -f "./scripts/feeds" ]; then
  chmod +x ./scripts/feeds || true
fi

# ---- ensure feeds + qmodem feed present ----
grep -q "^src-git qmodem " feeds.conf.default 2>/dev/null || \
  echo "src-git qmodem https://github.com/FUjr/QModem.git;main" >> feeds.conf.default

echo "[+] Update and install all feeds"
./scripts/feeds update -a
./scripts/feeds install -a

echo "[+] Update/install QModem feed"
./scripts/feeds update qmodem || true
./scripts/feeds install -a -p qmodem || true
./scripts/feeds install -a -f -p qmodem || true

# ---- enforce odhcpd / odhcp6c specific versions to avoid qmodem ipv6 breakage ----
fix_makefile() {
  local file="$1" date="$2" ver="$3" hash="$4"
  if [ -f "$file" ]; then
    echo "[*] Ensuring $file uses pinned version"
    sed -i "s/^PKG_SOURCE_DATE:=.*/PKG_SOURCE_DATE:=${date}/" "$file" || true
    sed -i "s/^PKG_SOURCE_VERSION:=.*/PKG_SOURCE_VERSION:=${ver}/" "$file" || true
    sed -i "s/^PKG_MIRROR_HASH:=.*/PKG_MIRROR_HASH:=${hash}/" "$file" || true
  fi
}

fix_makefile package/network/services/odhcpd/Makefile \
  2025-10-26 \
  fc27940fe9939f99aeb988d021c7edfa54460123 \
  acb086731fd7d072ddddc1d5f3bad9377e89a05597ce004d24bd0cdb60586f0a

fix_makefile package/network/ipv6/odhcp6c/Makefile \
  2025-10-21 \
  77e1ae21e67f81840024ffe5bb7cf69a8fb0d2f0 \
  78f1c2342330da5f6bf08a4be89df1d771661966bbff13bd15462035de46837b

# ---- screen driver packages (clone or update) ----
mkdir -p package/zz
clone_or_update() {
  local url="$1" dir="$2"
  if [ -d "$dir/.git" ]; then
    echo "[=] update $dir"
    git -C "$dir" pull --ff-only || true
  else
    echo "[+] clone $dir"
    git clone "$url" "$dir" || true
  fi
}
clone_or_update https://github.com/zzzz0317/kmod-fb-tft-gc9307.git package/zz/kmod-fb-tft-gc9307
clone_or_update https://github.com/zzzz0317/xgp-v3-screen.git        package/zz/xgp-v3-screen

# ---- prepare files/ (firstboot scripts, udev, hotplug, watcher, keep list) ----
FILES_DIR="$IW_DIR/files"
mkdir -p "$FILES_DIR/etc" \
         "$FILES_DIR/etc/config" \
         "$FILES_DIR/etc/uci-defaults" \
         "$FILES_DIR/etc/udev/rules.d" \
         "$FILES_DIR/etc/init.d" \
         "$FILES_DIR/lib/upgrade/keep.d"

### 1) version info and build id (will be included in image)
BUILD_UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
BUILD_DATE="$(date '+%Y-%m-%d %H:%M:%S %z')"
BUILD_REVISION="R$(date +%y).$(date +%-m).$(date +%-d).$(date +%-H)"
IMMORTAL_HASH="$(git rev-parse --short HEAD || true)"
REPO_HASH="$(git rev-parse --short HEAD || true)"
cat > "$FILES_DIR/etc/uci-defaults/zzzz-version" <<EOF
#!/bin/sh
echo "DISTRIB_REVISION='${BUILD_REVISION}'" >> /etc/openwrt_release
/bin/sync
exit 0
EOF
chmod +x "$FILES_DIR/etc/uci-defaults/zzzz-version"

cat > "$FILES_DIR/etc/zz_build_id" <<EOF
ZZ_BUILD_UUID='${BUILD_UUID}'
ZZ_BUILD_DATE='${BUILD_DATE}'
ZZ_BUILD_REVISION='${BUILD_REVISION}'
ZZ_BUILD_IMMORTAL_HASH='${IMMORTAL_HASH}'
ZZ_BUILD_REPO_HASH='${REPO_HASH}'
ZZ_BUILD_HOST='$(hostname)'
ZZ_BUILD_USER='builder'
EOF

# ---- keep qmodem config across sysupgrade ----
echo "etc/config/qmodem" > "$FILES_DIR/lib/upgrade/keep.d/zz-qmodem"
# also ensure sysupgrade.conf entry for old systems
echo "/etc/config/qmodem" >> "$FILES_DIR/etc/sysupgrade.conf" || true

# ---- qmodem default config copy (if exists in feed) ----
if [ -f "feeds/qmodem/application/qmodem/files/etc/config/qmodem" ]; then
  cp -f feeds/qmodem/application/qmodem/files/etc/config/qmodem "$FILES_DIR/etc/config/qmodem"
else
  # create a minimal placeholder
  cat > "$FILES_DIR/etc/config/qmodem" <<EOF
config global 'global'
	option keep_config '1'
EOF
fi

# ---- firstboot: LAN / WiFi / UI / qmodem setup (uci-defaults) ----
cat > "$FILES_DIR/etc/uci-defaults/99-firstboot-xgp" <<'EOF'
#!/bin/sh
# firstboot initialization - run once
uci set system.@system[0].hostname='zzXGP'
uci commit system

uci set network.lan.ipaddr='10.0.11.1'
uci commit network

# set luci defaults
uci set luci.main.lang='zh_cn'
uci set luci.main.mediaurlbase='/luci-static/argon'
uci commit luci

# Basic wifi auto-config: set country US and create ifaces for available radios
SSID_BASE='zzXGP'
WIFI_KEY='xgpxgpxgp'
idx=0
for r in $(uci show wireless 2>/dev/null | grep "=wifi-device" | cut -d. -f2); do
  uci set wireless.$r.country='US'
  # create iface if not exist referencing this radio
  iface=$(uci show wireless 2>/dev/null | grep "\.$r" | grep -o "wifi-iface\\[[0-9]*\\]" | head -n1 | sed 's/\\[//;s/\\]//;s/wifi-iface/wifi-iface/' || true)
  # fallback: add one
  uci add wireless wifi-iface >/dev/null 2>&1 || true
  # find last iface index
  last=$(uci show wireless | tail -n1 | cut -d. -f2)
  uci rename wireless."$last" "default_$r" 2>/dev/null || true
  uci set wireless.default_$r.device="$r"
  uci set wireless.default_$r.mode='ap'
  uci set wireless.default_$r.network='lan'
  uci set wireless.default_$r.ssid="${SSID_BASE}_${idx}"
  uci set wireless.default_$r.encryption='psk2+ccmp'
  uci set wireless.default_$r.key="$WIFI_KEY"
  idx=$((idx+1))
done
uci commit wireless
# mark firstboot done (if zz_config exists)
uci -q set zz_config.@status[0].first_boot=0
uci commit zz_config 2>/dev/null || true

exit 0
EOF
chmod +x "$FILES_DIR/etc/uci-defaults/99-firstboot-xgp"

# ---- udev rules to call hotplug script for USB/PCI modems ----
cat > "$FILES_DIR/etc/udev/rules.d/99-qmodem-hotplug.rules" <<'EOF'
# run qmodem-hotplug script on add/remove of USB devices
SUBSYSTEM=="usb", ACTION=="add", RUN+="/etc/qmodem-hotplug.sh add %p"
SUBSYSTEM=="usb", ACTION=="remove", RUN+="/etc/qmodem-hotplug.sh remove %p"
# NOTE: PCI hotplug environment in OpenWrt/ImmortalWrt differs; we also support hotplug.d handlers
EOF

# ---- hotplug handler script (packaged into image, executed by udev on device) ----
cat > "$FILES_DIR/etc/qmodem-hotplug.sh" <<'EOF'
#!/bin/sh
# /etc/qmodem-hotplug.sh <add|remove> <devpath>
action=$1
devpath=$2

logger -t qmodem-hotplug "action=$action devpath=$devpath"

if [ "$action" = "add" ]; then
  # ensure qmodem config exists
  [ -f /etc/config/qmodem ] || { logger -t qmodem-hotplug "no qmodem config"; exit 0; }
  # register a modem-slot entry (if not exists with same slot)
  # Use slot name based on devpath basename (e.g., 8-1)
  slotname=$(basename "$devpath")
  # check if any slot already uses same slot
  uci show qmodem | grep -q "slot='$slotname'" && exit 0
  # create a new slot
  uci add qmodem modem-slot
  idx=$(uci show qmodem | tail -n1 | cut -d. -f2)
  uci set qmodem.$idx.type='usb'
  uci set qmodem.$idx.slot="$slotname"
  uci set qmodem.$idx.alias="wwan_$slotname"
  uci set qmodem.$idx.net_led='blue:net'
  uci commit qmodem
  # add network interface for mwan3
  if ! uci -q get network."wwan_$slotname" >/dev/null; then
    uci set network."wwan_$slotname"=interface
    uci set network."wwan_$slotname".proto='dhcp'
    uci set network."wwan_$slotname".enabled='1'
    uci commit network
  fi
  # restart qmodem service to pick up
  /etc/init.d/qmodem restart 2>/dev/null || true
  # reload network/mwan3
  /etc/init.d/network restart 2>/dev/null || true
  /etc/init.d/mwan3 restart 2>/dev/null || true
elif [ "$action" = "remove" ]; then
  # best-effort: do nothing destructive; user can clean config
  exit 0
fi
EOF
chmod +x "$FILES_DIR/etc/qmodem-hotplug.sh"

# ---- simple watcher service: check modem link quality and adjust mwan3 policy ----
# This will be packaged as /etc/init.d/qmodem-mwan-watchdog on device (lightweight)
cat > "$FILES_DIR/etc/init.d/qmodem-mwan-watchdog" <<'EOF'
#!/bin/sh /etc/rc.common
# Simple watchdog to monitor qmodem interfaces and adjust mwan3 policy
START=99
STOP=10

boot() {
  # run background task
  qmodem_mwan_watchdog &
}

qmodem_mwan_watchdog() {
  while true; do
    # list interfaces from qmodem config
    for s in $(uci show qmodem 2>/dev/null | cut -d. -f2 | sort -u); do
      # check if section is modem-slot by checking type
      t=$(uci -q get qmodem.$s.type)
      [ -z "$t" ] && continue
      # build interface name heuristic: wwan_<slot> or alias
      alias=$(uci -q get qmodem.$s.alias)
      slot=$(uci -q get qmodem.$s.slot)
      if [ -n "$alias" ]; then
        iface="$alias"
      elif [ -n "$slot" ]; then
        iface="wwan_$slot"
      else
        continue
      fi
      # check if interface exists and has IP
      if ip link show "$iface" >/dev/null 2>&1; then
        # ping test via the interface (best-effort)
        if ping -I "$iface" -c 2 -W 2 1.1.1.1 >/dev/null 2>&1; then
          # mark interface up in mwan3 (create if needed)
          if ! uci -q get mwan3."$iface" >/dev/null; then
            uci set mwan3."$iface"='interface'
            uci set mwan3."$iface".enabled='1'
            uci set mwan3."$iface".proto='static' 2>/dev/null || true
            uci commit mwan3
            /etc/init.d/mwan3 restart 2>/dev/null || true
          fi
        fi
      fi
    done
    sleep 30
  done
}
EOF
chmod +x "$FILES_DIR/etc/init.d/qmodem-mwan-watchdog"

# ---- ensure files are executable where needed (udev etc) ----
chmod +x "$FILES_DIR/etc/qmodem-hotplug.sh" || true
chmod +x "$FILES_DIR/etc/init.d/qmodem-mwan-watchdog" || true

# ---- final: apply .config or default ----
if [ -f "$WORKDIR/xgp.config" ]; then
  echo "[*] Using xgp.config from root dir"
  cp -f "$WORKDIR/xgp.config" "$IW_DIR/.config"
elif [ -f "$IW_DIR/.config" ]; then
  echo "[*] Using existing .config in repo"
else
  echo "[*] No .config found, generating default defconfig"
  make defconfig
fi

# ---- download + build with logging, capture first error ----
BUILD_LOG="$WORKDIR/immortalwrt_build_output.log"
set +e
make download -j"$NPROC" V=s 2>&1 | tee -a "$BUILD_LOG"
make -j"$NPROC" V=s 2>&1 | tee -a "$BUILD_LOG"
RET=${PIPESTATUS[0]}
set -e

if [ "$RET" -ne 0 ]; then
  echo "❌ BUILD FAILED"
  FIRST_ERR_LINE=$(grep -n -m1 -E " error:|^make\\[.*\\]: \\*\\*\\*" "$BUILD_LOG" || true)
  if [ -n "$FIRST_ERR_LINE" ]; then
    echo "=== first error context ==="
    LINE_NUM=$(echo "$FIRST_ERR_LINE" | cut -d: -f1)
    sed -n "$((LINE_NUM-5)),$((LINE_NUM+5))p" "$BUILD_LOG" || true
    echo "==========================="
  else
    echo "No explicit 'error:' line found; tail of log:"
    tail -n 200 "$BUILD_LOG"
  fi
  exit 1
fi

# ---- Build success: print artifact path and write summary file ----
echo "✅ BUILD SUCCESS"
ARTIFACT_DIR="$IW_DIR/bin/targets"
echo "Artifacts under: $ARTIFACT_DIR"

# write summary file for workflow
cat > "$WORKDIR/build_summary.txt" <<EOF
BUILD_UUID=${BUILD_UUID}
BUILD_DATE=${BUILD_DATE}
BUILD_REVISION=${BUILD_REVISION}
IMMORTAL_HASH=${IMMORTAL_HASH}
REPO_HASH=${REPO_HASH}
ARTIFACT_DIR=${ARTIFACT_DIR}
EOF

echo "Done."
