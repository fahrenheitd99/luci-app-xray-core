#!/bin/sh

echo "================================================================================"
echo "                    luci-app-xray-core :: Complete Uninstall                    "
echo "================================================================================"

# Считываем путь к геофайлам до удаления UCI-конфига
ASSET_DIR=$(uci -q get xray_ui.main.asset_dir 2>/dev/null || echo "/usr/bin/")
[ -z "$ASSET_DIR" ] && ASSET_DIR="/usr/bin/"
case "$ASSET_DIR" in
    */) ;;
    *) ASSET_DIR="${ASSET_DIR}/" ;;
esac

echo "===> Stopping and removing Xray service..."
if [ -x "/etc/init.d/xray" ]; then
    /etc/init.d/xray stop >/dev/null 2>&1 || true
    /etc/init.d/xray disable >/dev/null 2>&1 || true
fi
killall -9 xray 2>/dev/null || true
rm -f /etc/init.d/xray

echo "===> Removing cron jobs..."
if [ -f "/etc/crontabs/root" ] && grep -q "^# XRAY_UI_CRON_BEGIN$" /etc/crontabs/root; then
    awk '
        /^# XRAY_UI_CRON_BEGIN$/ { skip = 1; next }
        /^# XRAY_UI_CRON_END$/   { skip = 0; next }
        !skip { print }
    ' /etc/crontabs/root > /tmp/xray_crontab.tmp && mv /tmp/xray_crontab.tmp /etc/crontabs/root
    /etc/init.d/cron restart >/dev/null 2>&1 || true
fi

echo "===> Removing nftables, hotplug, and policy routing rules..."
rm -f /etc/nftables.d/xray.nft
rm -f /etc/hotplug.d/iface/99-xray-route
nft delete chain inet fw4 xray_prerouting 2>/dev/null || true
while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
while ip route del local default dev lo table 100 2>/dev/null; do :; done
fw4 reload >/dev/null 2>&1 || true

echo "===> Removing LuCI components and Lua backend..."
rm -f /usr/libexec/xray-ui-core.lua
rm -f /usr/libexec/xray-generate.sh
rm -f /usr/lib/lua/luci/controller/xray.lua
rm -f /usr/lib/lua/luci/model/cbi/xray.lua
rm -f /usr/lib/lua/luci/view/xray_status.htm
rm -f /usr/lib/lua/luci/view/xray_service_extra.htm
rm -f /usr/lib/lua/luci/view/xray_nodes.htm
rm -f /usr/lib/lua/luci/view/xray_subs.htm
rm -f /usr/lib/lua/luci/view/xray_rules.htm

echo "===> Removing Xray configuration, database, and UCI config..."
rm -rf /etc/xray
rm -f /etc/config/xray_ui

echo "===> Removing temporary files and logs..."
rm -f /tmp/xray_ping.log
rm -f /tmp/xray_p_*
rm -f /tmp/xray_ping_req_*
rm -f /tmp/xray_add_node.tmp
rm -f /tmp/xray-ui-core.lua.bak
rm -f /tmp/sub.raw /tmp/sub.json /tmp/sub.err /tmp/sub.jq /tmp/sub.jqerr /tmp/sub_parsed.json /tmp/sub.b64 /tmp/sub.dec

printf "Remove all .dat geofiles in %s? [y/N]: " "$ASSET_DIR"
read DEL_GEO < /dev/tty
case "$DEL_GEO" in
    y|Y|yes|YES)
        if [ -d "$ASSET_DIR" ]; then
            echo "===> Removing .dat files from ${ASSET_DIR}..."
            rm -f "${ASSET_DIR}"*.dat
        fi
        ;;
    *)
        echo "===> Keeping .dat files in ${ASSET_DIR}."
        ;;
esac

printf "Uninstall packages (xray-core, tcping, kmod-nft-tproxy) and Passwall feed? [y/N]: "
read DEL_PKGS < /dev/tty
case "$DEL_PKGS" in
    y|Y|yes|YES)
        echo "===> Removing packages..."
        apk del xray-core tcping kmod-nft-tproxy 2>/dev/null || true

        if [ -f "/etc/apk/repositories.d/customfeeds.list" ]; then
            sed -i '/openwrt-passwall-build/d' /etc/apk/repositories.d/customfeeds.list
            if [ ! -s "/etc/apk/repositories.d/customfeeds.list" ]; then
                rm -f /etc/apk/repositories.d/customfeeds.list
            fi
        fi

        if [ ! -f "/etc/apk/repositories.d/customfeeds.list" ] || ! grep -q "openwrt-passwall-build" /etc/apk/repositories.d/customfeeds.list 2>/dev/null; then
            rm -f /etc/apk/keys/passwall.pub
        fi
        ;;
    *)
        echo "===> Keeping installed packages."
        ;;
esac

echo "===> Clearing LuCI cache..."
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache/ /tmp/luci-uci-cache

echo "===> Uninstall completed! Refresh your LuCI web interface."
