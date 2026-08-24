#!/bin/sh
set -e

echo "╔────────────────────────────────────────────────────────────────────────────────────────────────────────────────╗";
echo "│ :::===== :::====  :::  === :::====  :::===== :::= === :::  === :::===== ::: :::==== :::====  :::====  :::====  │";
echo "│ :::      :::  === :::  === :::  === :::      :::===== :::  === :::      ::: :::==== :::  === :::  === :::  === │";
echo "│ ======   ======== ======== =======  ======   ======== ======== ======   ===   ===   ===  ===  =======  ======= │";
echo "│ ===      ===  === ===  === === ===  ===      === ==== ===  === ===      ===   ===   ===  ===      ===      === │";
echo "│ ===      ===  === ===  === ===  === ======== ===  === ===  === ======== ===   ===   =======   =====    =====   │";
echo "╚────────────────────────────────────────────────────────────────────────────────────────────────────────────────╝";
echo "==========> https://github.com/XTLS/Xray-core <=> https://github.com/fahrenheitd99/luci-app-xray-core <===========";

echo "===> Xray backend setup initialization..."
printf "geosite.dat URL (if skip, just press Enter): "
read GEOSITE_URL
printf "geoip.dat URL (if skip, just press Enter): "
read GEOIP_URL

echo "===> Updating package lists..."
apk update

echo "===> Installing required packages..."
apk add xray-core kmod-nft-tproxy nano wget luci-compat curl

if [ -n "$GEOSITE_URL" ]; then
    echo "===> Downloading geosite.dat..."
    wget -O /usr/bin/geosite.dat "$GEOSITE_URL"
else
    echo "===> Skipping geosite.dat download."
fi

if [ -n "$GEOIP_URL" ]; then
    echo "===> Downloading geoip.dat..."
    wget -O /usr/bin/geoip.dat "$GEOIP_URL"
else
    echo "===> Skipping geoip.dat download."
fi

echo "===> Preparing Xray configuration directory..."
mkdir -p /etc/xray

echo "===> Writing minimal valid config.json..."
cat << 'EOF' > /etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 12345,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

echo "===> Creating hotplug network routing script..."
cat << 'EOF' > /etc/hotplug.d/iface/99-xray-route
#!/bin/sh
if [ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "lan" ]; then
    ip rule del fwmark 1 table 100 2>/dev/null
    ip route del local default dev lo table 100 2>/dev/null
    
    ip rule add fwmark 1 table 100
    ip route add local default dev lo table 100
fi
EOF

chmod +x /etc/hotplug.d/iface/99-xray-route

echo "===> Configuring nftables rules..."
cat << 'EOF' > /etc/nftables.d/xray.nft
chain xray_prerouting {
    type filter hook prerouting priority mangle; policy accept;
    ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 255.255.255.255/32 } return
    meta mark 255 return
    meta l4proto { tcp, udp } tproxy to :12345 meta mark set 1 accept
}
EOF

echo "===> Applying network routing rules and reloading firewall..."
ip rule add fwmark 1 table 100 2>/dev/null
ip route add local default dev lo table 100 2>/dev/null
fw4 reload

echo "===> Writing procd init script with dynamic SOCKS generation..."
cat << 'EOF' > /etc/init.d/xray
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

generate_internal_socks() {
    lua -e '
        local json = require "luci.jsonc"
        local fs = require "nixio.fs"

        local content = fs.readfile("/etc/xray/config.json")
        if not content then return end

        local cfg = json.parse(content)
        if not cfg or type(cfg.outbounds) ~= "table" then return end

        local inbounds = {}
        local rules = {}
        local port_base = 10800
        local idx = 0

        for _, o in ipairs(cfg.outbounds) do
            local p = o.protocol
            if p and p ~= "freedom" and p ~= "blackhole" and p ~= "dns" and p ~= "loopback" then
                if o.tag and o.tag ~= "" then
                    idx = idx + 1
                    local current_port = port_base + idx
                    local in_tag = "internal-socks-" .. idx

                    table.insert(inbounds, {
                        tag = in_tag,
                        listen = "127.0.0.1",
                        port = current_port,
                        protocol = "socks",
                        settings = { auth = "noauth" }
                    })

                    table.insert(rules, {
                        type = "field",
                        inboundTag = { in_tag },
                        outboundTag = o.tag
                    })
                end
            end
        end

        local result = {
            inbounds = inbounds,
            routing = { rules = rules }
        }

        fs.writefile("/etc/xray/internal_socks.json", json.stringify(result))
    ' 2>/dev/null
}

start_service() {
    local asset_dir=$(uci -q get xray_ui.main.asset_dir || echo "/usr/bin/")

    generate_internal_socks

    procd_open_instance
    procd_set_param command /usr/bin/xray run
    procd_append_param command -c /etc/xray/internal_socks.json
    procd_append_param command -c /etc/xray/config.json

    procd_set_param env GOMEMLIMIT=55MiB GOGC=20 XRAY_LOCATION_ASSET="$asset_dir"
    procd_set_param respawn
    procd_set_param file /etc/xray/config.json
    procd_close_instance
}
EOF

chmod +x /etc/init.d/xray

/etc/init.d/xray enable
/etc/init.d/xray restart

sleep 2
STATUS_OUT=$(/etc/init.d/xray status 2>&1)
echo "$STATUS_OUT" | grep -q "running"
if [ ! $? -eq 0 ]; then
    echo "===> Error: Backend failed to start!"
    exit 1
fi

echo "===> Frontend (LuCI) setup initialization..."

echo "===> Create empty config file xray_ui in /etc/config/ directory"
touch /etc/config/xray_ui

echo "===> Set main section of type xray_ui in UCI configuration"
uci set xray_ui.main=xray_ui

echo "===> Set default asset directory path in UCI configuration"
uci set xray_ui.main.asset_dir="/usr/bin/"

echo "===> Commit changes to xray_ui UCI configuration"
uci commit xray_ui

echo "===> Create LuCI controller directory if it does not exist"
mkdir -p /usr/lib/lua/luci/controller/

echo "===> Create and write LuCI controller file /usr/lib/lua/luci/controller/xray.lua"
cat << 'EOF' > /usr/lib/lua/luci/controller/xray.lua
module("luci.controller.xray", package.seeall)

function index()
    entry({"admin", "services", "xray"}, cbi("xray"), _("Xray Core"), 50).dependent = true
    entry({"admin", "services", "xray", "ping"}, call("action_ping")).leaf = true
end

function action_ping()
    local sys = require "luci.sys"
    local fs = require "nixio.fs"
    local json = require "luci.jsonc"
    local nixio = require "nixio"
    local http = require "luci.http"

    local pid = sys.exec("pgrep -f /usr/bin/xray")
    local is_running = (pid ~= "")

    local function check_direct_ping(address, port)
        if not address or not port then return "-" end
        local addrs = nixio.getaddrinfo(address, "inet")
        if not addrs or #addrs == 0 or not addrs[1] or not addrs[1].address then
            return "DNS Err"
        end
        local sock = nixio.socket("inet", "stream")
        if not sock then return "Err" end
        sock:setblocking(false)
        local s1, u1 = nixio.gettimeofday()
        sock:connect(addrs[1].address, tonumber(port))
        local pollout = nixio.POLLOUT or 4
        local fds = { {fd = sock, events = pollout} }
        local revents = nixio.poll(fds, 1500)
        local s2, u2 = nixio.gettimeofday()
        local is_connected = false
        if revents and revents > 0 then
            local err = sock:getopt("socket", "error")
            if err == 0 then is_connected = true end
        end
        sock:close()
        if is_connected then
            local ms = (s2 - s1) * 1000 + math.floor((u2 - u1) / 1000)
            if ms < 1 then ms = 1 end
            return string.format("%d ms", ms)
        end
        return "Timeout"
    end

    local function check_tunnel_ping(socks_port)
        if not is_running then return "Xray stopped" end
        local cmd = string.format('/usr/bin/curl -sL --connect-timeout 4 --max-time 6 -x socks5h://127.0.0.1:%d -w "%%{http_code} %%{time_starttransfer}" -o /dev/null http://cp.cloudflare.com/generate_204 2>/dev/null', socks_port)
        local res = sys.exec(cmd)
        if res and res ~= "" then
            local code, sec_str = res:match("(%d+)%s+([%d%.,]+)")
            if code == "204" or code == "200" then
                sec_str = sec_str:gsub(",", ".")
                local sec = tonumber(sec_str)
                if sec and sec > 0 then
                    local ms = math.floor(sec * 1000)
                    if ms < 1 then ms = 1 end
                    return string.format("%d ms", ms)
                end
            end
        end
        return "Timeout"
    end

    local function get_outbound_target(o)
        if not o or type(o) ~= "table" then return nil, nil end
        local proto = o.protocol
        if proto == "freedom" or proto == "blackhole" or proto == "dns" or proto == "loopback" then
            return nil, nil
        end
        local s = (type(o.settings) == "table") and o.settings or o
        if type(s) == "table" then
            if type(s.vnext) == "table" and s.vnext[1] then
                return s.vnext[1].address, s.vnext[1].port
            elseif type(s.servers) == "table" and s.servers[1] then
                return s.servers[1].address, s.servers[1].port
            elseif type(s.peers) == "table" and s.peers[1] and s.peers[1].endpoint then
                local host, port = s.peers[1].endpoint:match("^([^:]+):(%d+)$")
                if host and port then return host, port end
            end
        end
        return nil, nil
    end

    local results = {}
    local content = fs.readfile("/etc/xray/config.json")
    if content then
        local p = json.parse(content)
        if p and type(p.outbounds) == "table" then
            local proxy_idx = 0
            for _, o in ipairs(p.outbounds) do
                local tag = o.tag or "unnamed"
                local addr, port = get_outbound_target(o)
                if addr and port then
                    proxy_idx = proxy_idx + 1
                    local socks_port = 10800 + proxy_idx
                    table.insert(results, {
                        tag = tag,
                        direct_ping = check_direct_ping(addr, port),
                        tunnel_ping = check_tunnel_ping(socks_port)
                    })
                end
            end
        end
    end

    http.prepare_content("application/json")
    http.write(json.stringify(results))
end
EOF

echo "===> Create LuCI CBI model directory if it does not exist"
mkdir -p /usr/lib/lua/luci/model/cbi/

echo "===> Create and write LuCI CBI model file /usr/lib/lua/luci/model/cbi/xray.lua"
cat << 'EOF' > /usr/lib/lua/luci/model/cbi/xray.lua
local fs = require "nixio.fs"
local sys = require "luci.sys"
local http = require "luci.http"

local action = http.formvalue("xray_action")
if action == "start" then sys.call("/etc/init.d/xray start >/dev/null 2>&1")
elseif action == "stop" then sys.call("/etc/init.d/xray stop >/dev/null 2>&1")
elseif action == "restart" then sys.call("/etc/init.d/xray restart >/dev/null 2>&1")
elseif action == "enable" then sys.call("/etc/init.d/xray enable >/dev/null 2>&1")
elseif action == "disable" then sys.call("/etc/init.d/xray disable >/dev/null 2>&1")
end

local m = Map("xray_ui", "Xray Core")
local s = m:section(NamedSection, "main", "xray_ui")
s.addremove = false

s:tab("service", "Service")
s:tab("config", "Config")

local status = s:taboption("service", DummyValue, "_status")
status.template = "xray_status"

local asset_dir = s:taboption("service", Value, "asset_dir", "Asset Directory")
asset_dir.default = "/usr/bin/"
asset_dir.description = "geoip.dat and geosite.dat path"

local conf = s:taboption("config", TextValue, "_conf")
conf.wrap = "off"
conf.rows = 30
conf.cfgvalue = function(self, section)
    return fs.readfile("/etc/xray/config.json") or "{}"
end
conf.write = function(self, section, value)
    if value then
        value = value:gsub("\r\n", "\n")
        fs.writefile("/etc/xray/config.json", value)
        sys.call("/etc/init.d/xray restart >/dev/null 2>&1")
    end
end

return m
EOF

echo "===> Create LuCI view directory if it does not exist"
mkdir -p /usr/lib/lua/luci/view/

echo "===> Create and write LuCI view template /usr/lib/lua/luci/view/xray_status.htm"
cat << 'EOF' > /usr/lib/lua/luci/view/xray_status.htm
<%
    local sys = require "luci.sys"
    local fs = require "nixio.fs"
    local json = require "luci.jsonc"

    local xray_ver = sys.exec("xray version 2>/dev/null | head -n1 | awk '{print $2}'")
    if xray_ver == "" then xray_ver = "Unknown" end

    local pid = sys.exec("pgrep -f /usr/bin/xray")
    local is_running = (pid ~= "")
    if pid == "" then pid = "-" end

    local is_enabled = (sys.call("/etc/init.d/xray enabled >/dev/null 2>&1") == 0)

    local function get_outbound_target(o)
        if not o or type(o) ~= "table" then return nil, nil end
        local proto = o.protocol
        if proto == "freedom" or proto == "blackhole" or proto == "dns" or proto == "loopback" then
            return nil, nil
        end
        local s = (type(o.settings) == "table") and o.settings or o
        if type(s) == "table" then
            if type(s.vnext) == "table" and s.vnext[1] then
                return s.vnext[1].address, s.vnext[1].port
            elseif type(s.servers) == "table" and s.servers[1] then
                return s.servers[1].address, s.servers[1].port
            elseif type(s.peers) == "table" and s.peers[1] and s.peers[1].endpoint then
                local host, port = s.peers[1].endpoint:match("^([^:]+):(%d+)$")
                if host and port then return host, port end
            end
        end
        return nil, nil
    end

    local servers = {}
    local content = fs.readfile("/etc/xray/config.json")
    if content then
        local p = json.parse(content)
        if p and type(p.outbounds) == "table" then
            for _, o in ipairs(p.outbounds) do
                local tag = o.tag or "unnamed"
                local proto = o.protocol or "unknown"
                local addr, port = get_outbound_target(o)
                if addr and port then
                    table.insert(servers, {
                        tag = tag,
                        target = string.format("%s:%s", addr, port),
                        protocol = proto
                    })
                end
            end
        end
    end
%>

<div class="cbi-section">
    <h3 style="margin-bottom: 5px;">Version <%=xray_ver%></h3>
    <p style="margin-top: 0; margin-bottom: 2px;">
        <a href="https://github.com/XTLS/Xray-core" target="_blank" rel="noreferrer">https://github.com/XTLS/Xray-core</a>
    </p>
    <p style="margin-top: 0; margin-bottom: 10px;">
        <a href="https://github.com/fahrenheitd99/luci-app-xray-core" target="_blank" rel="noreferrer">https://github.com/fahrenheitd99/luci-app-xray-core</a>
    </p>

    <p style="font-size: 1em; margin-bottom: 15px;">
        Status: <%=is_running and "Running" or "Stopped"%>, PID: <%=pid%>
    </p>

    <div style="display: flex; gap: 8px; align-items: center; margin-bottom: 20px;">
        <strong>Service control:</strong>
        <button type="submit" class="cbi-button cbi-button-apply" name="xray_action" value="start" <%=is_running and 'disabled="disabled"' or ''%>>Start</button>
        <button type="submit" class="cbi-button cbi-button-restart" name="xray_action" value="restart" <%=not is_running and 'disabled="disabled"' or ''%>>Restart</button>
        <button type="submit" class="cbi-button cbi-button-reset" name="xray_action" value="stop" <%=not is_running and 'disabled="disabled"' or ''%>>Stop</button>
        
        <span style="margin: 0 12px;"></span>

        <button type="submit" class="cbi-button cbi-button-save" name="xray_action" value="enable" <%=is_enabled and 'disabled="disabled"' or ''%>>Enable</button>
        <button type="submit" class="cbi-button cbi-button-reset" name="xray_action" value="disable" <%=not is_enabled and 'disabled="disabled"' or ''%>>Disable</button>
    </div>

    <hr style="margin: 20px 0 15px 0;">

    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px;">
        <h4 style="margin: 0;">Server list:</h4>
        <button type="button" id="btn-update-ping" class="cbi-button cbi-button-action" onclick="updatePings()">Ping All</button>
    </div>

    <table class="table cbi-section-table" style="width: 100%; text-align: left; margin-bottom: 15px;">
        <tr class="tr cbi-section-table-titles">
            <th class="th">Tag</th>
            <th class="th">Target (Host:Port)</th>
            <th class="th">Protocol</th>
            <th class="th">Direct Ping</th>
            <th class="th">Tunnel Ping</th>
        </tr>
        <% if #servers > 0 then %>
            <% for _, srv in ipairs(servers) do %>
                <tr class="tr cbi-section-table-row" data-tag="<%=srv.tag%>">
                    <td class="td"><strong><%=srv.tag%></strong></td>
                    <td class="td"><code><%=srv.target%></code></td>
                    <td class="td"><%=srv.protocol%></td>
                    <td class="td direct-ping">Unchecked</td>
                    <td class="td tunnel-ping">Unchecked</td>
                </tr>
            <% end %>
        <% else %>
            <tr class="tr cbi-section-table-row"><td class="td" colspan="5"><em>No external servers found in config</em></td></tr>
        <% end %>
    </table>
</div>

<script type="text/javascript">
    function updatePings() {
        var btn = document.getElementById('btn-update-ping');
        if (btn) {
            btn.disabled = true;
            btn.innerText = 'Checking...';
        }

        var rows = document.querySelectorAll('tr[data-tag]');
        rows.forEach(function(row) {
            row.querySelector('.direct-ping').innerText = '...';
            row.querySelector('.tunnel-ping').innerText = '...';
        });

        fetch('<%=url("admin/services/xray/ping")%>')
            .then(function(res) { return res.json(); })
            .then(function(data) {
                if (Array.isArray(data)) {
                    data.forEach(function(item) {
                        var row = document.querySelector('tr[data-tag="' + item.tag + '"]');
                        if (row) {
                            row.querySelector('.direct-ping').innerText = item.direct_ping;
                            row.querySelector('.tunnel-ping').innerText = item.tunnel_ping;
                        }
                    });
                }
            })
            .catch(function(err) {
                console.error(err);
            })
            .finally(function() {
                if (btn) {
                    btn.disabled = false;
                    btn.innerText = 'Ping All';
                }
            });
    }
</script>
EOF

/etc/init.d/xray restart

echo "===> Clearing LuCI module and index cache..."
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/ /tmp/luci-uci-cache

echo "===> Setup completed successfully!"
