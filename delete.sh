#!/bin/sh
set +e

printf "Are you sure you want to completely uninstall Xray and the LuCI interface? [y/N]: "
read -r CONFIRM < /dev/tty

case "$CONFIRM" in
    [yY]|[yY][eE][sS])
        echo "===> Starting uninstallation..."
        ;;
    *)
        echo "Uninstallation canceled."
        exit 0
        ;;
esac

echo "===> Stopping and disabling Xray service..."
if [ -f /etc/init.d/xray ]; then
    /etc/init.d/xray stop >/dev/null 2>&1
    /etc/init.d/xray disable >/dev/null 2>&1
    rm -f /etc/init.d/xray
fi

echo "===> Removing network routing rules..."
ip rule del fwmark 1 table 100 >/dev/null 2>&1
ip route del local default dev lo table 100 >/dev/null 2>&1

echo "===> Removing hotplug script..."
rm -f /etc/hotplug.d/iface/99-xray-route

echo "===> Removing nftables rules and reloading firewall..."
rm -f /etc/nftables.d/xray.nft
fw4 reload >/dev/null 2>&1

echo "===> Removing Xray packages..."
apk del xray-core || echo "   -> xray-core not found or already removed."

echo "===> Removing configuration files and databases..."
rm -rf /etc/xray
rm -f /usr/bin/geosite.dat
rm -f /usr/bin/geoip.dat

echo "===> Removing LuCI frontend files..."
rm -f /usr/lib/lua/luci/controller/xray.lua
rm -f /usr/lib/lua/luci/model/cbi/xray.lua
rm -f /usr/lib/lua/luci/view/xray_status.htm

echo "===> Cleaning up UCI configuration..."
uci delete xray_ui >/dev/null 2>&1
uci commit xray_ui >/dev/null 2>&1
rm -f /etc/config/xray_ui

echo "===> Clearing LuCI cache..."
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/ /tmp/luci-uci-cache

echo "===> Xray and LuCI wrapper successfully uninstalled!"

[ -f "$0" ] && rm -- "$0"
