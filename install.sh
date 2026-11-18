#!/bin/sh
set -e

echo "╔────────────────────────────────────────────────────────────────────────────────────────────────────────────────╗"
echo "│ :::===== :::====  :::  === :::====  :::===== :::= === :::  === :::===== ::: :::==== :::====  :::====  :::====  │"
echo "│ :::      :::  === :::  === :::  === :::      :::===== :::  === :::      ::: :::==== :::  === :::  === :::  === │"
echo "│ ======   ======== ======== =======  ======   ======== ======== ======   ===   ===   ===  ===  =======  ======= │"
echo "│ ===      ===  === ===  === === ===  ===      === ==== ===  === ===      ===   ===   ===  ===      ===      === │"
echo "│ ===      ===  === ===  === ===  === ======== ===  === ===  === ======== ===   ===   =======   =====    =====   │"
echo "╚────────────────────────────────────────────────────────────────────────────────────────────────────────────────╝"

printf "geosite.dat URL (if skip, just press Enter): "
read GEOSITE_URL < /dev/tty
printf "geoip.dat URL (if skip, just press Enter): "
read GEOIP_URL < /dev/tty

echo "===> Updating package lists..."
apk update

echo "===> Installing required packages..."
apk add xray-core kmod-nft-tproxy nano wget luci-compat curl coreutils-base64 ca-bundle jq

echo "===> Installing tcping from Passwall2..."
if [ ! -x "/usr/bin/tcping" ]; then
    (
        . /etc/openwrt_release
        release="${DISTRIB_RELEASE%.*}"
        arch="$DISTRIB_ARCH"
        mkdir -p /etc/apk/keys /etc/apk/repositories.d
        if [ ! -f "/etc/apk/keys/passwall.pub" ]; then
            wget -qO /etc/apk/keys/passwall.pub \
                https://sourceforge.net/projects/openwrt-passwall-build/files/apk.pub
        fi
        FEED_URL="https://sourceforge.net/projects/openwrt-passwall-build/files/releases/packages-${release}/${arch}/passwall_packages/packages.adb"
        touch /etc/apk/repositories.d/customfeeds.list
        if ! grep -qF "$FEED_URL" /etc/apk/repositories.d/customfeeds.list; then
            echo "$FEED_URL" >> /etc/apk/repositories.d/customfeeds.list
        fi
        apk update && apk add tcping
    ) || echo "===> Warning: could not install tcping from Passwall2 feed, fallback TCP ping will be used."
fi

if [ -n "$GEOSITE_URL" ]; then
    echo "===> Downloading geosite.dat..."
    wget -O /usr/bin/geosite.dat "$GEOSITE_URL"
fi

if [ -n "$GEOIP_URL" ]; then
    echo "===> Downloading geoip.dat..."
    wget -O /usr/bin/geoip.dat "$GEOIP_URL"
fi

echo "===> Preparing Xray configuration directory..."
mkdir -p /etc/xray
mkdir -p /usr/libexec

if [ ! -f "/etc/xray/nodes.json" ]; then
cat << 'EOF' > /etc/xray/nodes.json
{
  "manual_nodes": [],
  "managed_tags": [],
  "settings": {
    "ping_mode": "head",
    "auto_sort": false
  },
  "nodes": [],
  "subs": [],
  "rules": [
    {
      "name": "BitTorrent Direct",
      "ip": "",
      "domain": "",
      "protocol": "bittorrent",
      "network": "",
      "port": "",
      "outbound": "direct"
    }
  ]
}
EOF
fi

echo "===> Writing base /etc/xray/config.json..."
cat << 'EOF' > /etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "queryStrategy": "UseIPv4",
    "servers": [
      "https://1.1.1.1/dns-query",
      "https://8.8.8.8/dns-query"
    ]
  },
  "inbounds": [
    {
      "tag": "tproxy-in",
      "port": 12345,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ],
        "routeOnly": true
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
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "direct"
      }
    ]
  }
}
EOF

echo "===> Creating hotplug network routing script..."
cat << 'EOF' > /etc/hotplug.d/iface/99-xray-route
#!/bin/sh
if [ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "lan" ]; then
    ip rule del fwmark 1 table 100 2>/dev/null || true
    ip route del local default dev lo table 100 2>/dev/null || true
    ip rule add fwmark 1 table 100 2>/dev/null || true
    ip route add local default dev lo table 100 2>/dev/null || true
fi
EOF
chmod +x /etc/hotplug.d/iface/99-xray-route

echo "===> Configuring nftables rules..."
cat << 'EOF' > /etc/nftables.d/xray.nft
chain xray_prerouting {
    type filter hook prerouting priority mangle; policy accept;
    ip6 daddr { ::1/128, fe80::/10, fc00::/7, ff00::/8 } return
    ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 255.255.255.255/32 } return
    meta mark 255 return
    meta nfproto ipv4 meta l4proto { tcp, udp } tproxy ip to :12345 meta mark set 1 accept
}
EOF

ip rule add fwmark 1 table 100 2>/dev/null || true
ip route add local default dev lo table 100 2>/dev/null || true
fw4 reload 2>/dev/null || true

echo "===> Creating Lua Runtime Core (/usr/libexec/xray-ui-core.lua)..."
cat << 'EOF' > /usr/libexec/xray-ui-core.lua
local json = require "luci.jsonc"
local fs = require "nixio.fs"
local nixio = require "nixio"
local sys = require "luci.sys"

local CONFIG_PATH = "/etc/xray/config.json"
local DB_PATH = "/etc/xray/nodes.json"
local PING_LOG_PATH = "/tmp/xray_ping.log"

local function urldecode(s)
    if not s then return "" end
    s = s:gsub("+", " ")
    s = s:gsub("%%(%x%x)", function(h)
        local n = tonumber(h, 16)
        return n and string.char(n) or ("%" .. h)
    end)
    return s
end

local function urldecode_strict(s)
    if not s then return "" end
    s = s:gsub("%%(%x%x)", function(h)
        local n = tonumber(h, 16)
        return n and string.char(n) or ("%" .. h)
    end)
    return s
end

local function sh_quote(s)
    return "'" .. tostring(s or ""):gsub("'", "") .. "'"
end

local function append_ping_log(line)
    local ts = os.date("%H:%M:%S")
    local entry = string.format("[%s] %s", ts, tostring(line or ""):gsub("[\r\n]+", " "))
    local existing = fs.readfile(PING_LOG_PATH) or ""
    local lines = {}
    for l in existing:gmatch("[^\r\n]+") do
        table.insert(lines, l)
    end
    table.insert(lines, entry)
    local max_lines = 200
    if #lines > max_lines then
        local trimmed = {}
        for i = #lines - max_lines + 1, #lines do
            table.insert(trimmed, lines[i])
        end
        lines = trimmed
    end
    fs.writefile(PING_LOG_PATH, table.concat(lines, "\n") .. "\n")
end

local function decode_base64_str(str)
    if not str or str == "" then return nil end
    local clean = str:gsub("%s+", ""):gsub("%-", "+"):gsub("_", "/")
    local rem = #clean % 4
    if rem == 2 then
        clean = clean .. "=="
    elseif rem == 3 then
        clean = clean .. "="
    end
    fs.writefile("/tmp/sub.b64", clean)
    os.execute("base64 -d /tmp/sub.b64 > /tmp/sub.dec 2>/dev/null")
    local dec = fs.readfile("/tmp/sub.dec")
    fs.remove("/tmp/sub.b64")
    fs.remove("/tmp/sub.dec")
    return dec
end

local function deep_copy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = deep_copy(v)
    end
    return copy
end

-- Рекурсивная очистка null (userdata) и пустых таблиц {}, чтобы jsonc не превращал их в []
local function deep_clean(t)
    if type(t) ~= "table" then return t end
    local keys = {}
    for k, _ in pairs(t) do
        table.insert(keys, k)
    end
    for _, k in ipairs(keys) do
        local v = t[k]
        if type(v) == "userdata" then
            t[k] = nil
        elseif type(v) == "table" then
            deep_clean(v)
            if next(v) == nil then
                t[k] = nil
            end
        end
    end
    return t
end

local function sanitize_outbound(ob, tag_name)
    if type(ob) == "table" then
        deep_clean(ob)
        if tag_name and tag_name ~= "" then
            ob.tag = tag_name
        elseif not ob.tag or ob.tag == "" then
            ob.tag = "proxy"
        end
    end
end

local function split_host_port(hp)
    if not hp then return nil, nil end
    local host, port = hp:match("^%[([^%]]+)%]:(%d+)$")
    if host and port then return host, tonumber(port) end
    host, port = hp:match("^([^:]+):(%d+)$")
    if host and port then return host, tonumber(port) end
    return nil, nil
end

local function parse_query_params(query)
    local params = {}
    if not query or query == "" then return params end
    for kv in query:gmatch("[^&]+") do
        local k, v = kv:match("^([^=]+)=(.*)$")
        if k then
            params[urldecode_strict(k)] = urldecode_strict(v)
        end
    end
    return params
end

local function split_csv(str)
    local arr = {}
    if not str or str == "" then return arr end
    for item in str:gmatch("[^,]+") do
        local t = item:gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= "" then table.insert(arr, t) end
    end
    return arr
end

-- Извлечение host:port из любого outbound для TCP Ping
local function extract_endpoint(ob)
    if type(ob) ~= "table" or type(ob.settings) ~= "table" then return nil, nil end
    local s = ob.settings
    if type(s.vnext) == "table" and type(s.vnext[1]) == "table" then
        return s.vnext[1].address, tonumber(s.vnext[1].port)
    elseif type(s.servers) == "table" and type(s.servers[1]) == "table" then
        return s.servers[1].address, tonumber(s.servers[1].port)
    elseif s.address and s.port then
        return s.address, tonumber(s.port)
    elseif type(s.peers) == "table" and type(s.peers[1]) == "table" and type(s.peers[1].endpoint) == "string" then
        return split_host_port(s.peers[1].endpoint)
    end
    return nil, nil
end

-- TCP Ping: сначала /usr/bin/tcping (из Passwall2), если нет — резервный nixio
local function do_tcp_ping(host, port, label)
    local tag = label or (tostring(host or "?") .. ":" .. tostring(port or "?"))
    if not host or not port then
        append_ping_log(string.format("[TCP] %s -> FAIL (no endpoint)", tag))
        return nil, "no endpoint"
    end

    if fs.access("/usr/bin/tcping") then
        local cmd = string.format("/usr/bin/tcping -c 1 -i 1 -t 2 -p %d %s 2>&1; printf '\\nRC=%%d' $?", tonumber(port), sh_quote(host))
        local out = sys.exec(cmd) or ""
        local rc = tonumber(out:match("RC=(%d+)%s*$")) or 1
        local body = out:gsub("RC=%d+%s*$", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        local ms_str = body:match("time=([%d%.]+)%s*ms") or body:match("([%d%.]+)%s*ms")
        if rc == 0 and ms_str then
            local ms = math.floor(tonumber(ms_str) + 0.5)
            if ms < 1 then ms = 1 end
            append_ping_log(string.format("[TCP/tcping] %s (%s:%d) -> %d ms", tag, host, port, ms))
            return ms, nil
        end
        append_ping_log(string.format("[TCP/tcping] %s (%s:%d) -> FAIL (rc=%d, out=%s)", tag, host, port, rc, body:sub(1, 140)))
        return nil, (body ~= "" and body:sub(1, 80) or "timeout")
    end

    local addrs = nixio.getaddrinfo(tostring(host), "inet")
    local fam = "inet"
    if not addrs or #addrs == 0 then
        addrs = nixio.getaddrinfo(tostring(host), "inet6")
        fam = "inet6"
    end
    if not addrs or #addrs == 0 or not addrs[1] or not addrs[1].address then
        append_ping_log(string.format("[TCP/nixio] %s (%s:%d) -> FAIL (dns err)", tag, host, port))
        return nil, "dns err"
    end

    local sock = nixio.socket(fam, "stream")
    if not sock then
        append_ping_log(string.format("[TCP/nixio] %s (%s:%d) -> FAIL (socket err)", tag, host, port))
        return nil, "socket err"
    end
    sock:setblocking(false)

    local pollout = (nixio.poll_flags and nixio.poll_flags("out")) or 4
    local s1, u1 = nixio.gettimeofday()
    local ok_conn = sock:connect(addrs[1].address, tonumber(port))
    local connected = false
    local serr = -1
    if ok_conn then
        connected = true
        serr = 0
    else
        local rev = nixio.poll({ { fd = sock, events = pollout } }, 2000)
        if rev and rev > 0 then
            serr = sock:getopt("socket", "error")
            if serr == 0 then connected = true end
        end
    end
    local s2, u2 = nixio.gettimeofday()
    sock:close()

    if not connected then
        append_ping_log(string.format("[TCP/nixio] %s (%s:%d) -> FAIL (timeout/err=%s)", tag, host, port, tostring(serr)))
        return nil, "timeout"
    end
    local ms = (s2 - s1) * 1000 + math.floor((u2 - u1) / 1000)
    if ms < 1 then ms = 1 end
    append_ping_log(string.format("[TCP/nixio] %s (%s:%d) -> %d ms", tag, host, port, ms))
    return ms, nil
end

-- Гарантированное выделение свободного локального TCP-порта (без getsockname)
local function alloc_free_port()
    local s_now, u_now = nixio.gettimeofday()
    math.randomseed((nixio.getpid() * 997) + (u_now or 0) + (s_now or 0))
    for _ = 1, 30 do
        local p = math.random(22000, 45000)
        local sock = nixio.socket("inet", "stream")
        if sock then
            sock:setopt("socket", "reuseaddr", 1)
            local ok = sock:bind("127.0.0.1", p)
            sock:close()
            if ok then return p end
        end
    end
    return 22000 + ((nixio.getpid() + (u_now or 0)) % 20000)
end

-- Реальный пинг Via Proxy (HTTP HEAD через изолированный временный Xray, без direct/freedom)
local function do_proxy_head_ping(raw_ob, label)
    local host, eport = extract_endpoint(raw_ob)
    local tag = label or (tostring(host or "?") .. ":" .. tostring(eport or "?"))
    if type(raw_ob) ~= "table" then
        append_ping_log(string.format("[HEAD] %s -> FAIL (invalid outbound)", tag))
        return nil, "invalid outbound"
    end

    local ob = deep_copy(raw_ob)
    sanitize_outbound(ob, "p-out")

    local port = alloc_free_port()
    local hex_port = string.format("%04X", port)
    local _, u_now = nixio.gettimeofday()
    local base_tmp = string.format("/tmp/xray_p_%d_%d_%d", nixio.getpid(), port, u_now or 0)
    local cfg_file = base_tmp .. ".json"
    local xlog_file = base_tmp .. ".xlog"
    local cout_file = base_tmp .. ".cout"
    local cerr_file = base_tmp .. ".cerr"
    local sh_file = base_tmp .. ".sh"

    local ping_cfg = {
        log = { loglevel = "warning" },
        inbounds = {
            {
                tag = "p-in",
                listen = "127.0.0.1",
                port = port,
                protocol = "socks",
                settings = {
                    auth = "noauth",
                    udp = true
                }
            }
        },
        outbounds = { ob },
        routing = {
            rules = {
                {
                    type = "field",
                    inboundTag = { "p-in" },
                    outboundTag = "p-out"
                }
            }
        }
    }

    fs.writefile(cfg_file, json.stringify(ping_cfg):gsub("\\/", "/"))

    local asset_dir = (sys.exec("uci -q get xray_ui.main.asset_dir") or "/usr/bin/"):gsub("%s+", "")
    if asset_dir == "" then asset_dir = "/usr/bin/" end

    local sh_body = string.format([[#!/bin/sh
GOMEMLIMIT=64MiB GOGC=40 XRAY_LOCATION_ASSET=%s /usr/bin/xray run -c %s >%s 2>&1 &
XPID=$!
READY=0
i=0
while [ $i -lt 40 ]; do
    [ ! -d "/proc/$XPID" ] && break
    if grep -qi ":%s 00000000:0000 0A " /proc/net/tcp 2>/dev/null; then
        READY=1
        break
    fi
    lua -e 'local n=require"nixio"; if n.nanosleep then n.nanosleep(0, 50000000) end' 2>/dev/null || sleep 1
    i=$((i + 1))
done
if [ "$READY" = "1" ]; then
    curl -I -sS -o /dev/null --connect-timeout 4 --max-time 6 -x "socks5h://127.0.0.1:%d" -w 'code=%%{http_code} ttfb=%%{time_starttransfer}' http://www.gstatic.com/generate_204 >%s 2>%s
    echo " rc=$?" >>%s
else
    echo "NOT_READY" >%s
fi
kill -9 "$XPID" 2>/dev/null
wait "$XPID" 2>/dev/null
]], sh_quote(asset_dir), sh_quote(cfg_file), sh_quote(xlog_file), hex_port, port, sh_quote(cout_file), sh_quote(cerr_file), sh_quote(cout_file), sh_quote(cout_file))

    fs.writefile(sh_file, sh_body)
    os.execute("sh " .. sh_quote(sh_file) .. " >/dev/null 2>&1")

    local cout = (fs.readfile(cout_file) or ""):gsub("%s+", " ")
    local cerr = (fs.readfile(cerr_file) or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local xlog = (fs.readfile(xlog_file) or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

    fs.remove(cfg_file)
    fs.remove(xlog_file)
    fs.remove(cout_file)
    fs.remove(cerr_file)
    fs.remove(sh_file)

    local code, sec_str = cout:match("code=(%d+)%s+ttfb=([%d%.,]+)")
    if code and (code == "204" or code == "200" or code == "301" or code == "302") and sec_str then
        local sec = tonumber(sec_str:gsub(",", "."))
        if sec and sec > 0 then
            local ms = math.floor(sec * 1000)
            if ms < 1 then ms = 1 end
            append_ping_log(string.format("[HEAD] %s (%s:%s) -> %d ms (HTTP %s)", tag, tostring(host or "?"), tostring(eport or "?"), ms, code))
            return ms, nil
        end
    end

    local reason = cout:match("NOT_READY") and "xray_not_ready" or (cerr ~= "" and cerr or cout)
    if xlog ~= "" and reason == "xray_not_ready" then
        reason = reason .. " | xray: " .. xlog:sub(-140)
    end
    append_ping_log(string.format("[HEAD] %s (%s:%s) -> FAIL (%s)", tag, tostring(host or "?"), tostring(eport or "?"), reason:sub(1, 200)))
    return nil, reason:sub(1, 100)
end

local function build_stream_settings(params, default_host, default_sec)
    local net = (params.type and params.type ~= "") and params.type:lower() or "tcp"
    local sec = (params.security and params.security ~= "") and params.security:lower() or (default_sec or "none")
    if net == "splithttp" then net = "xhttp" end
    if net == "mkcp" then net = "kcp" end
    if net == "http" then net = "h2" end

    local stream = {
        network = net,
        security = sec
    }

    if sec == "reality" then
        stream.realitySettings = {
            serverName = params.sni or "",
            fingerprint = (params.fp and params.fp ~= "") and params.fp or "firefox",
            publicKey = params.pbk or "",
            shortId = params.sid or "",
            spiderX = params.spx or ""
        }
    elseif sec == "tls" then
        local sni = (params.sni and params.sni ~= "") and params.sni
            or (params.host and params.host ~= "" and params.host)
            or default_host or ""
        local tls = { serverName = sni }
        if params.fp and params.fp ~= "" then tls.fingerprint = params.fp end
        local alpn = split_csv(params.alpn)
        if #alpn > 0 then tls.alpn = alpn end
        if params.insecure == "1" or params.insecure == "true" or params.allowInsecure == "1" or params.allowInsecure == "true" then
            tls.allowInsecure = true
        end
        stream.tlsSettings = tls
    end

    if net == "xhttp" then
        local xhttp = {
            host = params.host or "",
            path = (params.path and params.path ~= "") and params.path or "/",
            mode = (params.mode and params.mode ~= "") and params.mode or "packet-up"
        }
        if params.extra and params.extra ~= "" then
            local succ, res = pcall(json.parse, params.extra)
            if succ and type(res) == "table" and next(res) ~= nil then
                xhttp.extra = res
            end
        end
        stream.xhttpSettings = xhttp
    elseif net == "ws" then
        local ws = { path = (params.path and params.path ~= "") and params.path or "/" }
        if params.host and params.host ~= "" then
            ws.host = params.host
            ws.headers = { Host = params.host }
        end
        stream.wsSettings = ws
    elseif net == "grpc" then
        local grpc = {
            serviceName = params.serviceName or params.path or "",
            multiMode = (params.mode == "multi")
        }
        if params.authority and params.authority ~= "" then grpc.authority = params.authority end
        stream.grpcSettings = grpc
    elseif net == "httpupgrade" then
        stream.httpupgradeSettings = {
            host = params.host or "",
            path = (params.path and params.path ~= "") and params.path or "/"
        }
    elseif net == "kcp" then
        local kcp = {
            header = { type = (params.headerType and params.headerType ~= "") and params.headerType or "none" }
        }
        if params.seed and params.seed ~= "" then kcp.seed = params.seed end
        stream.kcpSettings = kcp
    elseif net == "h2" then
        local h2 = { path = (params.path and params.path ~= "") and params.path or "/" }
        local hosts = split_csv(params.host)
        if #hosts > 0 then h2.host = hosts end
        stream.httpSettings = h2
    elseif (net == "tcp" or net == "raw") and params.headerType == "http" then
        local req = { path = { (params.path and params.path ~= "") and params.path or "/" } }
        local hosts = split_csv(params.host)
        if #hosts > 0 then req.headers = { Host = hosts } end
        stream.tcpSettings = { header = { type = "http", request = req } }
    end

    return stream
end

-- Универсальный парсер любых ссылок и JSON-outbound для вкладки Nodes
local function parse_any_link(raw)
    if not raw then return nil, "Link is empty" end
    local link = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if link == "" then return nil, "Link is empty" end

    -- 1. Прямая вставка JSON outbound или фрагмента конфига
    if link:sub(1, 1) == "{" then
        local ok, obj = pcall(json.parse, link)
        if not ok or type(obj) ~= "table" then
            return nil, "Invalid JSON payload"
        end
        local ob = obj
        if type(obj.outbounds) == "table" then
            ob = nil
            for _, item in ipairs(obj.outbounds) do
                if type(item) == "table" and item.protocol and item.protocol ~= "freedom" and item.protocol ~= "blackhole" and item.protocol ~= "dns" and item.protocol ~= "loopback" then
                    ob = item
                    break
                end
            end
        end
        if type(ob) ~= "table" or type(ob.protocol) ~= "string" or ob.protocol == "" then
            return nil, "JSON must contain a valid outbound object with protocol"
        end
        local name = tostring(obj.remarks or (ob.tag and ob.tag ~= "proxy" and ob.tag) or (ob.protocol .. " node")):gsub("^%s+", ""):gsub("%s+$", "")
        sanitize_outbound(ob, name)
        return { name = name, outbound = ob }, nil
    end

    -- 2. Разбор URI-схемы
    local frag_name = nil
    local hash_idx = link:find("#", 1, true)
    if hash_idx then
        local raw_frag = link:sub(hash_idx + 1)
        if raw_frag ~= "" then
            frag_name = urldecode_strict(raw_frag):gsub("^%s+", ""):gsub("%s+$", "")
        end
        link = link:sub(1, hash_idx - 1)
    end

    local scheme, rest = link:match("^([%a][%w%+%-%.]*)://(.*)$")
    if not scheme or not rest or rest == "" then
        return nil, "Unrecognized link format (expected scheme://... or JSON)"
    end
    scheme = scheme:lower()

    -- VMess (стандартный Base64 JSON или URI)
    if scheme == "vmess" then
        local q_idx = rest:find("?", 1, true)
        local auth_part = q_idx and rest:sub(1, q_idx - 1) or rest
        local at_idx = auth_part:match(".*()@")
        if at_idx then
            local id = urldecode_strict(auth_part:sub(1, at_idx - 1))
            local host, port = split_host_port(auth_part:sub(at_idx + 1):gsub("/.*$", ""))
            if not host or not port then return nil, "Invalid vmess host:port" end
            local params = parse_query_params(q_idx and rest:sub(q_idx + 1) or "")
            local name = frag_name or (host .. ":" .. port)
            local out = {
                tag = name,
                protocol = "vmess",
                settings = {
                    vnext = { {
                        address = host,
                        port = port,
                        users = { {
                            id = id,
                            alterId = tonumber(params.aid or params.alterId) or 0,
                            security = (params.encryption and params.encryption ~= "") and params.encryption or "auto"
                        } }
                    } }
                },
                streamSettings = build_stream_settings(params, host, "none")
            }
            return { name = name, outbound = out }, nil
        else
            local decoded = decode_base64_str(rest)
            if not decoded or decoded == "" then return nil, "Failed to decode vmess base64" end
            local ok, v = pcall(json.parse, decoded)
            if not ok or type(v) ~= "table" or not v.add or not v.port or not v.id then
                return nil, "Invalid vmess JSON payload"
            end
            local params = {
                type = v.net or "tcp",
                headerType = v.type or "",
                host = v.host or "",
                path = v.path or "",
                security = (v.tls == "tls" or v.tls == "reality") and v.tls or "none",
                sni = (v.sni and v.sni ~= "") and v.sni or (v.host or ""),
                fp = v.fp or "",
                alpn = v.alpn or ""
            }
            local name = frag_name or (v.ps and tostring(v.ps) ~= "" and tostring(v.ps)) or (tostring(v.add) .. ":" .. tostring(v.port))
            local out = {
                tag = name,
                protocol = "vmess",
                settings = {
                    vnext = { {
                        address = tostring(v.add),
                        port = tonumber(v.port),
                        users = { {
                            id = tostring(v.id),
                            alterId = tonumber(v.aid) or 0,
                            security = (v.scy and v.scy ~= "") and tostring(v.scy) or "auto"
                        } }
                    } }
                },
                streamSettings = build_stream_settings(params, tostring(v.add), "none")
            }
            return { name = name, outbound = out }, nil
        end
    end

    -- Общее разбиение authority и query
    local q_idx = rest:find("?", 1, true)
    local authority = q_idx and rest:sub(1, q_idx - 1) or rest
    local query = q_idx and rest:sub(q_idx + 1) or ""
    authority = authority:gsub("/.*$", "")
    local params = parse_query_params(query)

    local at_idx = authority:match(".*()@")
    local userinfo = at_idx and authority:sub(1, at_idx - 1) or nil
    local hostport = at_idx and authority:sub(at_idx + 1) or authority

    -- VLESS
    if scheme == "vless" then
        if not userinfo or userinfo == "" then return nil, "Missing UUID in vless link" end
        local host, port = split_host_port(hostport)
        if not host or not port then return nil, "Invalid host:port in vless link" end
        local name = frag_name or (host .. ":" .. port)
        local out = {
            tag = name,
            protocol = "vless",
            settings = {
                vnext = { {
                    address = host,
                    port = port,
                    users = { {
                        id = urldecode_strict(userinfo),
                        encryption = (params.encryption and params.encryption ~= "") and params.encryption or "none",
                        flow = params.flow or ""
                    } }
                } }
            },
            streamSettings = build_stream_settings(params, host, "none")
        }
        return { name = name, outbound = out }, nil

    -- Trojan
    elseif scheme == "trojan" then
        if not userinfo or userinfo == "" then return nil, "Missing password in trojan link" end
        local host, port = split_host_port(hostport)
        if not host or not port then return nil, "Invalid host:port in trojan link" end
        local name = frag_name or (host .. ":" .. port)
        local out = {
            tag = name,
            protocol = "trojan",
            settings = {
                servers = { {
                    address = host,
                    port = port,
                    password = urldecode_strict(userinfo)
                } }
            },
            streamSettings = build_stream_settings(params, host, "tls")
        }
        return { name = name, outbound = out }, nil

    -- Hysteria / Hysteria2 (нативный формат Xray-core 26)
    elseif scheme == "hysteria2" or scheme == "hy2" or scheme == "hysteria" then
        local host, port = split_host_port(hostport)
        if not host or not port then return nil, "Invalid host:port in hysteria link" end
        local auth = (userinfo and userinfo ~= "") and urldecode_strict(userinfo) or (params.auth or "")
        local sec = (params.security and params.security ~= "") and params.security:lower() or "tls"

        local tls = {
            serverName = (params.sni and params.sni ~= "") and params.sni or host,
            enableSessionResumption = false
        }
        if params.fp and params.fp ~= "" then tls.fingerprint = params.fp end
        local alpn = split_csv(params.alpn)
        tls.alpn = (#alpn > 0) and alpn or { "h3" }
        if params.insecure == "1" or params.insecure == "true" or params.allowInsecure == "1" or params.allowInsecure == "true" then
            tls.allowInsecure = true
        end

        local hy_settings = {
            version = 2,
            auth = auth
        }
        if params.mport and params.mport ~= "" then
            hy_settings.udphop = { port = params.mport, interval = 30 }
        end

        local finalmask = {
            quicParams = {
                debug = false,
                congestion = (params.congestion and params.congestion ~= "") and params.congestion or "bbr"
            }
        }
        local obfs = params.obfs and params.obfs:lower() or ""
        local obfs_pass = params["obfs-password"] or params.obfs_password or params.obfsParam or ""
        if obfs == "salamander" and obfs_pass ~= "" then
            finalmask.udp = {
                {
                    type = "salamander",
                    settings = { password = obfs_pass }
                }
            }
        end

        local stream = {
            network = "hysteria",
            security = sec,
            hysteriaSettings = hy_settings,
            finalmask = finalmask
        }
        if sec == "tls" then stream.tlsSettings = tls end

        local name = frag_name or (host .. ":" .. port)
        local out = {
            tag = name,
            protocol = "hysteria",
            settings = {
                address = host,
                port = port,
                version = 2
            },
            streamSettings = stream
        }
        return { name = name, outbound = out }, nil

    -- Shadowsocks (SIP002, SS-2022, Legacy Base64)
    elseif scheme == "ss" then
        local method, pass, host, port
        if at_idx then
            host, port = split_host_port(hostport)
            if not host or not port then return nil, "Invalid host:port in ss link" end
            local decoded_ui = urldecode_strict(userinfo)
            if decoded_ui:find(":", 1, true) then
                method, pass = decoded_ui:match("^([^:]+):(.*)$")
            else
                local b64_ui = decode_base64_str(userinfo)
                if b64_ui then
                    method, pass = b64_ui:match("^([^:]+):(.*)$")
                end
            end
        else
            local full_dec = decode_base64_str(authority)
            if not full_dec then return nil, "Failed to decode legacy ss base64" end
            local dec_at = full_dec:match(".*()@")
            if not dec_at then return nil, "Invalid legacy ss payload" end
            local cred = full_dec:sub(1, dec_at - 1)
            method, pass = cred:match("^([^:]+):(.*)$")
            host, port = split_host_port(full_dec:sub(dec_at + 1))
        end

        if not method or not pass or not host or not port then
            return nil, "Invalid shadowsocks credentials or host:port"
        end
        local name = frag_name or (host .. ":" .. port)
        local out = {
            tag = name,
            protocol = "shadowsocks",
            settings = {
                servers = { {
                    address = host,
                    port = port,
                    method = method,
                    password = pass
                } }
            }
        }
        if params.type and params.type ~= "" then
            out.streamSettings = build_stream_settings(params, host, "none")
        end
        return { name = name, outbound = out }, nil

    -- SOCKS / SOCKS5 / HTTP / HTTPS
    elseif scheme == "socks" or scheme == "socks5" or scheme == "socks4" or scheme == "http" or scheme == "https" then
        local host, port = split_host_port(hostport)
        if not host or not port then return nil, "Invalid host:port in " .. scheme .. " link" end
        local srv = { address = host, port = port }
        if userinfo and userinfo ~= "" then
            local dec_ui = urldecode_strict(userinfo)
            local u, p = dec_ui:match("^([^:]+):(.*)$")
            if not u then
                local b64_ui = decode_base64_str(userinfo)
                if b64_ui and b64_ui:find(":", 1, true) then
                    u, p = b64_ui:match("^([^:]+):(.*)$")
                end
            end
            if u and u ~= "" then
                srv.users = { { user = u, pass = p or "" } }
            end
        end
        local proto = (scheme == "http" or scheme == "https") and "http" or "socks"
        local name = frag_name or (host .. ":" .. port)
        local out = {
            tag = name,
            protocol = proto,
            settings = { servers = { srv } }
        }
        if scheme == "https" or params.security == "tls" then
            out.streamSettings = build_stream_settings(params, host, "tls")
        end
        return { name = name, outbound = out }, nil

    -- WireGuard
    elseif scheme == "wireguard" or scheme == "wg" then
        if not userinfo or userinfo == "" then return nil, "Missing private key in wireguard link" end
        local host, port = split_host_port(hostport)
        if not host or not port then return nil, "Invalid endpoint in wireguard link" end
        local pubkey = params.publickey or params.publicKey or params.pbk or ""
        if pubkey == "" then return nil, "Missing publickey in wireguard link" end
        local addrs = split_csv(params.address or params.ip or "10.0.0.2/32")
        local wg_settings = {
            secretKey = urldecode_strict(userinfo),
            address = addrs,
            peers = { {
                publicKey = pubkey,
                endpoint = host .. ":" .. tostring(port)
            } },
            mtu = tonumber(params.mtu) or 1420
        }
        if params.reserved and params.reserved ~= "" then
            local res = {}
            for num in params.reserved:gmatch("%d+") do table.insert(res, tonumber(num)) end
            if #res > 0 then wg_settings.reserved = res end
        end
        local name = frag_name or (host .. ":" .. port)
        local out = {
            tag = name,
            protocol = "wireguard",
            settings = wg_settings
        }
        return { name = name, outbound = out }, nil
    end

    return nil, "Unsupported protocol: " .. scheme
end

local function parse_vless(link)
    if not link then return nil end
    link = link:gsub("^%s+", ""):gsub("%s+$", "")
    local id, addr, port, query = link:match("^vless://([^@]+)@([^:?/]+):(%d+)/?%??(.*)$")
    if not id then return nil end

    local hash_idx = query:find("#", 1, true)
    local name = "Custom Node"
    if hash_idx then
        name = urldecode(query:sub(hash_idx + 1))
        query = query:sub(1, hash_idx - 1)
    end

    local params = {}
    for kv in query:gmatch("[^&]+") do
        local k, v = kv:match("^([^=]+)=(.*)$")
        if k then
            params[urldecode(k)] = urldecode(v)
        end
    end

    local net = (params.type and params.type ~= "") and params.type or "tcp"
    local sec = (params.security and params.security ~= "") and params.security or "none"

    local out = {
        tag = name,
        protocol = "vless",
        settings = {
            vnext = {
                {
                    address = addr,
                    port = tonumber(port),
                    users = {
                        {
                            id = id,
                            encryption = params.encryption or "none",
                            flow = params.flow or ""
                        }
                    }
                }
            }
        },
        streamSettings = {
            network = net,
            security = sec
        }
    }

    if sec == "reality" then
        out.streamSettings.realitySettings = {
            serverName = params.sni or "",
            fingerprint = params.fp or "firefox",
            publicKey = params.pbk or "",
            shortId = params.sid or "",
            spiderX = params.spx or ""
        }
    elseif sec == "tls" then
        local tls = {
            serverName = (params.sni and params.sni ~= "") and params.sni or addr
        }
        if params.fp and params.fp ~= "" then tls.fingerprint = params.fp end
        if params.alpn and params.alpn ~= "" then
            local alpn = {}
            for a in params.alpn:gmatch("[^,]+") do table.insert(alpn, a) end
            if #alpn > 0 then tls.alpn = alpn end
        end
        out.streamSettings.tlsSettings = tls
    end

    if net == "xhttp" or net == "splithttp" then
        out.streamSettings.network = "xhttp"
        local xhttp = {
            host = params.host or "",
            path = params.path or "/",
            mode = params.mode or "packet-up"
        }
        if params.extra and params.extra ~= "" then
            local decoded = urldecode(params.extra)
            local succ, res = pcall(json.parse, decoded)
            if succ and type(res) == "table" and next(res) ~= nil then
                xhttp.extra = res
            end
        end
        out.streamSettings.xhttpSettings = xhttp
    elseif net == "ws" then
        local ws = { path = params.path or "/" }
        if params.host and params.host ~= "" then ws.headers = { Host = params.host } end
        out.streamSettings.wsSettings = ws
    elseif net == "grpc" then
        out.streamSettings.grpcSettings = {
            serviceName = params.serviceName or params.path or "",
            multiMode = (params.mode == "multi")
        }
    elseif net == "httpupgrade" then
        out.streamSettings.httpupgradeSettings = {
            host = params.host or "",
            path = params.path or "/"
        }
    end

    return { name = name, outbound = out }
end

local function parse_happ_json_file(json_file)
    -- Минимальный jq-фильтр без regex/gsub: вырезает всё лишнее, оставляя только {name, outbound}
    local jq_filter = [=[
(if type == "array" then . else [.] end)
| map(select(type == "object" and (.outbounds | type) == "array"))
| (map(select(((.routing | type) == "object" and (.routing.balancers | type) == "array" and (.routing.balancers | length) > 0) | not)) as $single
   | if ($single | length) > 0 then $single else . end)
| [ .[]
  | (.outbounds | map(select(type == "object" and .protocol != "freedom" and .protocol != "blackhole" and .protocol != "dns" and .protocol != "loopback")) | .[0]) as $ob
  | select($ob != null)
  | {
      name: ((.remarks // .ps // $ob.tag // "Unnamed Node") | tostring),
      outbound: $ob
    }
]
]=]
    local errs = {}
    fs.writefile("/tmp/sub.jq", jq_filter)
    fs.remove("/tmp/sub_parsed.json")
    fs.remove("/tmp/sub.jqerr")

    local rc = os.execute("jq -c -f /tmp/sub.jq " .. sh_quote(json_file) .. " > /tmp/sub_parsed.json 2>/tmp/sub.jqerr")
    fs.remove("/tmp/sub.jq")

    local jq_err = (fs.readfile("/tmp/sub.jqerr") or ""):gsub("%s+", " ")
    fs.remove("/tmp/sub.jqerr")
    if jq_err ~= "" then table.insert(errs, "jq: " .. jq_err:sub(1, 120)) end

    local parsed_raw = fs.readfile("/tmp/sub_parsed.json")
    fs.remove("/tmp/sub_parsed.json")

    if parsed_raw and #parsed_raw > 2 then
        local ok, arr, perr = pcall(json.parse, parsed_raw)
        if ok and type(arr) == "table" and #arr > 0 then
            for _, item in ipairs(arr) do
                if type(item.name) == "string" then
                    item.name = item.name:gsub("^%s+", ""):gsub("%s+$", "")
                end
                if type(item.outbound) == "table" then
                    sanitize_outbound(item.outbound, item.name)
                end
            end
            return arr, nil
        else
            table.insert(errs, "jsonc(jq): " .. tostring(perr or arr))
        end
    elseif rc ~= 0 and rc ~= true then
        table.insert(errs, "jq rc=" .. tostring(rc))
    end

    -- Резервный разбор напрямую через luci.jsonc (если jq недоступен)
    local raw_txt = fs.readfile(json_file)
    if raw_txt and raw_txt ~= "" then
        local ok, jdata, perr = pcall(json.parse, raw_txt)
        if ok and type(jdata) == "table" then
            local blocks = (#jdata > 0) and jdata or { jdata }
            local single_blocks = {}
            for _, b in ipairs(blocks) do
                local has_bal = (type(b) == "table" and type(b.routing) == "table" and type(b.routing.balancers) == "table" and #b.routing.balancers > 0)
                if type(b) == "table" and type(b.outbounds) == "table" and not has_bal then
                    table.insert(single_blocks, b)
                end
            end
            local use_blocks = (#single_blocks > 0) and single_blocks or blocks
            local out_arr = {}
            for _, block in ipairs(use_blocks) do
                if type(block) == "table" and type(block.outbounds) == "table" then
                    local proxy_ob = nil
                    for _, ob in ipairs(block.outbounds) do
                        if type(ob) == "table" and ob.protocol and ob.protocol ~= "freedom" and ob.protocol ~= "blackhole" and ob.protocol ~= "dns" and ob.protocol ~= "loopback" then
                            proxy_ob = ob
                            break
                        end
                    end
                    if proxy_ob then
                        local name = tostring(block.remarks or block.ps or proxy_ob.tag or "Unnamed Node"):gsub("^%s+", ""):gsub("%s+$", "")
                        sanitize_outbound(proxy_ob, name)
                        table.insert(out_arr, { name = name, outbound = proxy_ob })
                    end
                end
            end
            if #out_arr > 0 then
                return out_arr, nil
            end
        else
            table.insert(errs, "jsonc(raw): " .. tostring(perr or jdata))
        end
    end

    return nil, (#errs > 0 and table.concat(errs, " | ") or nil)
end

-- Поиск ноды по имени среди Nodes и Subscriptions
local function find_node_by_name(db, target_name)
    if not target_name or target_name == "" then return nil end
    if type(db.nodes) == "table" then
        for _, n in ipairs(db.nodes) do
            if type(n) == "table" and n.name == target_name and type(n.outbound) == "table" then
                return n
            end
        end
    end
    if type(db.subs) == "table" then
        for _, sub in ipairs(db.subs) do
            if type(sub) == "table" and type(sub.nodes) == "table" then
                for _, n in ipairs(sub.nodes) do
                    if type(n) == "table" and n.name == target_name and type(n.outbound) == "table" then
                        return n
                    end
                end
            end
        end
    end
    return nil
end

-- Преобразование правила из UI в нативный JSON-объект правила Xray
local function build_xray_rule(r)
    if type(r) ~= "table" then return nil end
    local out_tag = tostring(r.outbound or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if out_tag == "" then return nil end

    local xr = {
        type = "field",
        outboundTag = out_tag
    }
    local has_matcher = false

    -- IP (CIDR / IP / geoip:)
    if type(r.ip) == "string" and r.ip:gsub("%s+", "") ~= "" then
        local ips = {}
        for _, item in ipairs(split_csv(r.ip)) do
            if not item:find("[.:/]") and item:match("^!?[%a][%w_%-]*$") then
                item = "geoip:" .. item
            end
            table.insert(ips, item)
        end
        if #ips > 0 then
            xr.ip = ips
            has_matcher = true
        end
    end

    -- Domain (domain: / geosite: / regexp: / full: / keyword: / ext:)
    if type(r.domain) == "string" and r.domain:gsub("%s+", "") ~= "" then
        local domains = {}
        for _, item in ipairs(split_csv(r.domain)) do
            local low = item:lower()
            if not (low:match("^domain:") or low:match("^geosite:") or low:match("^regexp:") or low:match("^full:") or low:match("^keyword:") or low:match("^ext:")) then
                item = "domain:" .. item
            end
            table.insert(domains, item)
        end
        if #domains > 0 then
            xr.domain = domains
            has_matcher = true
        end
    end

    -- Protocol (bittorrent, http, tls, quic, ...)
    if type(r.protocol) == "string" and r.protocol:gsub("%s+", "") ~= "" then
        local protos = {}
        for _, item in ipairs(split_csv(r.protocol)) do
            table.insert(protos, item:lower())
        end
        if #protos > 0 then
            xr.protocol = protos
            has_matcher = true
        end
    end

    -- Network (tcp, udp, tcp,udp)
    if type(r.network) == "string" then
        local net = r.network:gsub("%s+", ""):lower()
        if net ~= "" then
            xr.network = net
            has_matcher = true
        end
    end

    -- Port (0-65535, список или диапазон)
    if r.port ~= nil then
        local port_str = tostring(r.port):gsub("%s+", "")
        if port_str ~= "" then
            xr.port = port_str
            has_matcher = true
        end
    end

    if not has_matcher then return nil end
    return xr
end

-- Миграция старого формата nodes.json (одна активная нода -> manual_nodes + rules)
local function normalize_db(db, base_cfg)
    local changed = false
    if type(db.nodes) ~= "table" then db.nodes = {}; changed = true end
    if type(db.subs) ~= "table" then db.subs = {}; changed = true end
    if type(db.managed_tags) ~= "table" then db.managed_tags = {}; changed = true end
    if type(db.settings) ~= "table" then
        db.settings = { ping_mode = "head", auto_sort = false }
        changed = true
    end

    if type(db.manual_nodes) ~= "table" then
        db.manual_nodes = {}
        if db.active_type == "node" and type(db.active_index) == "number" then
            local n = db.nodes[db.active_index + 1]
            if n and n.name then table.insert(db.manual_nodes, n.name) end
        elseif db.active_type == "sub" and type(db.active_sub_index) == "number" and type(db.active_node_index) == "number" then
            local sub = db.subs[db.active_sub_index + 1]
            if sub and type(sub.nodes) == "table" then
                local n = sub.nodes[db.active_node_index + 1]
                if n and n.name then table.insert(db.manual_nodes, n.name) end
            end
        end
        db.active_type = nil
        db.active_index = nil
        db.active_sub_index = nil
        db.active_node_index = nil
        changed = true
    end

    if type(db.rules) ~= "table" then
        db.rules = {}
        if type(base_cfg) == "table" and type(base_cfg.routing) == "table" and type(base_cfg.routing.rules) == "table" then
            for i, xr in ipairs(base_cfg.routing.rules) do
                if type(xr) == "table" and xr.outboundTag then
                    table.insert(db.rules, {
                        name = "Rule " .. i,
                        ip = (type(xr.ip) == "table") and table.concat(xr.ip, ", ") or "",
                        domain = (type(xr.domain) == "table") and table.concat(xr.domain, ", ") or "",
                        protocol = (type(xr.protocol) == "table") and table.concat(xr.protocol, ", ") or "",
                        network = (type(xr.network) == "string") and xr.network or "",
                        port = (xr.port ~= nil) and tostring(xr.port) or "",
                        outbound = tostring(xr.outboundTag)
                    })
                end
            end
        end
        changed = true
    end

    return changed
end

local cmd = arg[1]

if cmd == "generate" then
    local base = json.parse(fs.readfile(CONFIG_PATH) or "{}") or {}
    if type(base.outbounds) ~= "table" then base.outbounds = {} end

    local db = json.parse(fs.readfile(DB_PATH) or "{}") or {}
    local db_changed = normalize_db(db, base)

    -- Собираем множество всех тегов, управляемых приложением (кроме direct и block)
    local managed_set = { proxy = true }
    for _, t in ipairs(db.managed_tags) do
        if t ~= "direct" and t ~= "block" then managed_set[t] = true end
    end
    for _, n in ipairs(db.nodes) do
        if type(n) == "table" and n.name and n.name ~= "direct" and n.name ~= "block" then
            managed_set[n.name] = true
        end
    end
    for _, sub in ipairs(db.subs) do
        if type(sub) == "table" and type(sub.nodes) == "table" then
            for _, n in ipairs(sub.nodes) do
                if type(n) == "table" and n.name and n.name ~= "direct" and n.name ~= "block" then
                    managed_set[n.name] = true
                end
            end
        end
    end

    -- Оставляем базовые outbounds (direct, block и любые пользовательские, прописанные вручную в Config)
    local kept_outbounds = {}
    local kept_tags = {}
    for _, ob in ipairs(base.outbounds) do
        if type(ob) == "table" and not managed_set[ob.tag or ""] then
            table.insert(kept_outbounds, ob)
            if ob.tag then kept_tags[ob.tag] = true end
        end
    end

    local injected_set = {}
    local new_managed_tags = {}
    local manual_obs = {}
    local rule_obs = {}

    -- 1. Вручную запущенные ноды (идут первыми, как основной маршрут по умолчанию)
    for _, tag_name in ipairs(db.manual_nodes) do
        if type(tag_name) == "string" and tag_name ~= "" and tag_name ~= "direct" and tag_name ~= "block" and not injected_set[tag_name] then
            local node = find_node_by_name(db, tag_name)
            if node then
                local ob = deep_copy(node.outbound)
                sanitize_outbound(ob, node.name)
                table.insert(manual_obs, ob)
                injected_set[node.name] = true
                table.insert(new_managed_tags, node.name)
            end
        end
    end

    -- 2. Ноды, автоматически активированные правилами (идут после direct/block, чтобы не перехватывать чужой трафик)
    for _, r in ipairs(db.rules) do
        local tag_name = (type(r) == "table" and type(r.outbound) == "string") and r.outbound or ""
        if tag_name ~= "" and tag_name ~= "direct" and tag_name ~= "block" and not injected_set[tag_name] then
            local node = find_node_by_name(db, tag_name)
            if node then
                local ob = deep_copy(node.outbound)
                sanitize_outbound(ob, node.name)
                table.insert(rule_obs, ob)
                injected_set[node.name] = true
                table.insert(new_managed_tags, node.name)
            end
        end
    end

    -- Итоговый массив outbounds: [вручную запущенные] + [direct, block, ...] + [автозапущенные из правил]
    local final_outbounds = {}
    for _, ob in ipairs(manual_obs) do table.insert(final_outbounds, ob) end
    for _, ob in ipairs(kept_outbounds) do table.insert(final_outbounds, ob) end
    for _, ob in ipairs(rule_obs) do table.insert(final_outbounds, ob) end
    base.outbounds = final_outbounds

    -- Генерация routing.rules строго в порядке из вкладки Rules
    if type(base.routing) ~= "table" then
        base.routing = { domainStrategy = "IPIfNonMatch", rules = {} }
    end
    local final_rules = {}
    for _, r in ipairs(db.rules) do
        local xr = build_xray_rule(r)
        if xr then
            local t = xr.outboundTag
            if t == "direct" or t == "block" or injected_set[t] or kept_tags[t] then
                table.insert(final_rules, xr)
            end
        end
    end
    base.routing.rules = final_rules

    local final_json = json.stringify(base, true):gsub("\\/", "/")
    fs.writefile(CONFIG_PATH, final_json)

    db.managed_tags = new_managed_tags
    if db_changed or true then
        fs.writefile(DB_PATH, json.stringify(db))
    end

elseif cmd == "add_node" then
    local raw_arg = arg[2]
    local raw_input = nil
    if raw_arg and fs.access(raw_arg) then
        raw_input = fs.readfile(raw_arg)
    else
        raw_input = raw_arg
    end

    local parsed, err = parse_any_link(raw_input)
    if parsed then
        sanitize_outbound(parsed.outbound, parsed.name)
        local db = json.parse(fs.readfile(DB_PATH) or "{}") or {}
        if not db.nodes then db.nodes = {} end
        table.insert(db.nodes, { name = parsed.name, outbound = parsed.outbound })
        fs.writefile(DB_PATH, json.stringify(db))
        print(json.stringify({ success = true, name = parsed.name, protocol = parsed.outbound.protocol }))
    else
        print(json.stringify({ success = false, error = err or "Invalid link" }))
    end

elseif cmd == "ping" then
    local req_file = arg[2]
    local raw_req = (req_file and fs.access(req_file)) and fs.readfile(req_file) or req_file
    local req = raw_req and json.parse(raw_req) or nil
    if type(req) ~= "table" or type(req.outbound) ~= "table" then
        append_ping_log("[PING] invalid request payload")
        print(json.stringify({ success = false, ms = -1, error = "invalid payload" }))
        return
    end
    local mode = (req.mode == "head") and "head" or "tcp"
    local label = (type(req.name) == "string" and req.name ~= "") and req.name or nil
    local ms, perr
    if mode == "head" then
        ms, perr = do_proxy_head_ping(req.outbound, label)
    else
        local host, port = extract_endpoint(req.outbound)
        ms, perr = do_tcp_ping(host, port, label)
    end
    if ms then
        print(json.stringify({ success = true, ms = ms, mode = mode }))
    else
        print(json.stringify({ success = false, ms = -1, mode = mode, error = perr or "timeout" }))
    end

elseif cmd == "fetch" then
    local function fail(msg)
        print(json.stringify({ success = false, error = msg }))
    end

    local sub_idx = tonumber(arg[2])
    local db = json.parse(fs.readfile(DB_PATH) or "{}") or {}
    local sub = db.subs and db.subs[(sub_idx or 0) + 1]
    if not sub or not sub.url or sub.url == "" then
        fail("Subscription URL is empty")
        return
    end

    local url = sub.url:gsub("^%s+", ""):gsub("%s+$", "")
    local use_headers = (sub.use_headers ~= false)
    local ua = (sub.ua and sub.ua ~= "") and sub.ua or "Happ/4.3.0/Android/17877369741321921609"
    local locale = (sub.locale and sub.locale ~= "") and sub.locale or "ru"
    local hwid = (sub.hwid and sub.hwid ~= "") and sub.hwid or "74ca5b6e0448953d"
    local os_val = (sub.os and sub.os ~= "") and sub.os or "Android"
    local ver_os = (sub.ver_os and sub.ver_os ~= "") and sub.ver_os or "17"
    local model = (sub.model and sub.model ~= "") and sub.model or "A024"

    local function run_curl(extra_flags)
        fs.remove("/tmp/sub.raw")
        fs.remove("/tmp/sub.err")
        local parts = {
            "curl -sSL -m 25 --connect-timeout 15",
            extra_flags or ""
        }
        if use_headers then
            table.insert(parts, "-H " .. sh_quote("User-Agent: " .. ua))
            table.insert(parts, "-H " .. sh_quote("x-device-locale: " .. locale))
            table.insert(parts, "-H " .. sh_quote("x-hwid: " .. hwid))
            table.insert(parts, "-H " .. sh_quote("x-device-os: " .. os_val))
            table.insert(parts, "-H " .. sh_quote("x-ver-os: " .. ver_os))
            table.insert(parts, "-H " .. sh_quote("x-device-model: " .. model))
            table.insert(parts, "-H 'accept-encoding: gzip'")
        else
            table.insert(parts, "-H 'User-Agent: v2rayNG/1.8.23'")
        end
        table.insert(parts, "-o /tmp/sub.raw -w '%{http_code}'")
        table.insert(parts, sh_quote(url))
        local cmd_str = table.concat(parts, " ") .. " 2>/tmp/sub.err; printf '|%d' $?"
        local out = sys.exec(cmd_str) or ""
        local hcode, ecode = out:match("(%d+)|(%d+)$")
        return tonumber(hcode) or 0, tonumber(ecode) or 1
    end

    local http_code, exit_code = run_curl("")
    if exit_code ~= 0 or http_code == 0 then
        http_code, exit_code = run_curl("-4 -k --http1.1")
    end

    if exit_code ~= 0 then
        local err_txt = (fs.readfile("/tmp/sub.err") or ""):gsub("%s+", " ")
        fs.remove("/tmp/sub.raw")
        fs.remove("/tmp/sub.err")
        fail(string.format("curl error (%d): %s", exit_code, err_txt ~= "" and err_txt:sub(1, 140) or "network unreachable"))
        return
    end

    if http_code >= 400 then
        fs.remove("/tmp/sub.raw")
        fs.remove("/tmp/sub.err")
        fail(string.format("Server returned HTTP %d", http_code))
        return
    end

    local raw_data = fs.readfile("/tmp/sub.raw")
    fs.remove("/tmp/sub.err")
    if not raw_data or #raw_data == 0 then
        fs.remove("/tmp/sub.raw")
        fail(string.format("Empty response body (HTTP %d)", http_code))
        return
    end

    -- Проверяем GZIP magic bytes (0x1f 0x8b) и распаковываем встроенным BusyBox gunzip/zcat
    fs.remove("/tmp/sub.json")
    if #raw_data >= 2 and raw_data:byte(1) == 31 and raw_data:byte(2) == 139 then
        os.execute("gunzip -c /tmp/sub.raw > /tmp/sub.json 2>/dev/null || zcat /tmp/sub.raw > /tmp/sub.json 2>/dev/null")
    else
        fs.writefile("/tmp/sub.json", raw_data)
    end
    fs.remove("/tmp/sub.raw")

    local content = fs.readfile("/tmp/sub.json")
    if not content or #content == 0 then
        fs.remove("/tmp/sub.json")
        fail("Failed to decompress gzip response")
        return
    end

    -- Убираем UTF-8 BOM, если сервер его прислал
    if #content >= 3 and content:byte(1) == 239 and content:byte(2) == 187 and content:byte(3) == 191 then
        content = content:sub(4)
        fs.writefile("/tmp/sub.json", content)
    end

    local trimmed = content:gsub("^%s+", "")
    local new_nodes = {}
    local parse_err = nil

    -- Формат 1: JSON-массив или JSON-объект Xray/Happ
    if trimmed:sub(1, 1) == "[" or trimmed:sub(1, 1) == "{" then
        local parsed_json, jerr = parse_happ_json_file("/tmp/sub.json")
        if parsed_json and #parsed_json > 0 then
            new_nodes = parsed_json
        elseif jerr then
            parse_err = jerr
        end
    end

    -- Формат 2: Прямой список URI-ссылок (любые протоколы) или Base64 (в т.ч. Base64-обёртка вокруг JSON)
    if #new_nodes == 0 then
        local source_text = content
        if not content:match("[%a][%w%+%-%.]*://") then
            local decoded = decode_base64_str(content)
            if decoded and #decoded > 0 then
                source_text = decoded
                local dec_trim = decoded:gsub("^%s+", "")
                if dec_trim:sub(1, 1) == "[" or dec_trim:sub(1, 1) == "{" then
                    fs.writefile("/tmp/sub.json", decoded)
                    local parsed_json, jerr = parse_happ_json_file("/tmp/sub.json")
                    if parsed_json and #parsed_json > 0 then
                        new_nodes = parsed_json
                    elseif jerr then
                        parse_err = jerr
                    end
                end
            end
        end

        if #new_nodes == 0 then
            for line in source_text:gmatch("[^\r\n]+") do
                local clean_line = line:gsub("^%s+", ""):gsub("%s+$", "")
                if clean_line:match("^[%a][%w%+%-%.]*://") then
                    local p = parse_any_link(clean_line)
                    if p then
                        sanitize_outbound(p.outbound, p.name)
                        table.insert(new_nodes, p)
                    end
                end
            end
        end
    end

    fs.remove("/tmp/sub.json")

    if #new_nodes > 0 then
        sub.nodes = new_nodes
        fs.writefile(DB_PATH, json.stringify(db))
        print(json.stringify({ success = true, count = #new_nodes }))
    else
        local preview = trimmed:sub(1, 80):gsub("[%c]", " ")
        local extra_info = parse_err and ("; " .. parse_err) or ""
        fail(string.format("No supported nodes found (HTTP %d, %d bytes%s, start: %s)", http_code, #content, extra_info, preview))
    end
end
EOF
chmod +x /usr/libexec/xray-ui-core.lua

echo "===> Writing procd init script (/etc/init.d/xray)..."
cat << 'EOF' > /etc/init.d/xray
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

start_service() {
    if [ ! -f "/etc/xray/config.json" ]; then
        lua /usr/libexec/xray-ui-core.lua generate
    fi

    if [ ! -f "/etc/xray/config.json" ]; then return 1; fi
    local asset_dir=$(uci -q get xray_ui.main.asset_dir || echo "/usr/bin/")

    procd_open_instance
    procd_set_param command /usr/bin/xray run -c /etc/xray/config.json
    procd_set_param env GOMEMLIMIT=65MiB GOGC=40 XRAY_LOCATION_ASSET="$asset_dir"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn
    procd_close_instance
}

reload_service() {
    restart
}
EOF
chmod +x /etc/init.d/xray
/etc/init.d/xray enable

echo "===> Setting up LuCI components..."
touch /etc/config/xray_ui
uci set xray_ui.main=xray_ui 2>/dev/null || true
uci set xray_ui.main.asset_dir="/usr/bin/" 2>/dev/null || true
uci commit xray_ui

mkdir -p /usr/lib/lua/luci/controller/ /usr/lib/lua/luci/model/cbi/ /usr/lib/lua/luci/view/

cat << 'EOF' > /usr/lib/lua/luci/controller/xray.lua
module("luci.controller.xray", package.seeall)

function index()
    entry({"admin", "services", "xray"}, cbi("xray"), _("Xray Core"), 50).dependent = true
    entry({"admin", "services", "xray", "api"}, call("action_api")).leaf = true
    entry({"admin", "services", "xray", "fetch_sub"}, call("action_fetch_sub")).leaf = true
    entry({"admin", "services", "xray", "add_node"}, call("action_add_node")).leaf = true
    entry({"admin", "services", "xray", "ping"}, call("action_ping")).leaf = true
    entry({"admin", "services", "xray", "ping_log"}, call("action_ping_log")).leaf = true
    entry({"admin", "services", "xray", "service_ctl"}, call("action_service_ctl")).leaf = true
    entry({"admin", "services", "xray", "get_config"}, call("action_get_config")).leaf = true
end

local fs = require "nixio.fs"
local nixio = require "nixio"
local sys = require "luci.sys"
local http = require "luci.http"
local json = require "luci.jsonc"
local db_path = "/etc/xray/nodes.json"
local cfg_path = "/etc/xray/config.json"
local ping_log_path = "/tmp/xray_ping.log"

local function get_service_status()
    local pid = sys.exec("pidof xray"):gsub("%s+", "")
    local is_running = (pid ~= "")
    local is_enabled = (sys.call("/etc/init.d/xray enabled >/dev/null 2>&1") == 0)
    return {
        running = is_running,
        pid = is_running and pid or "-",
        enabled = is_enabled
    }
end

function action_api()
    local method = http.getenv("REQUEST_METHOD")
    if method == "GET" then
        http.prepare_content("application/json")
        http.write(fs.readfile(db_path) or "{}")
    elseif method == "POST" then
        local qs = http.getenv("QUERY_STRING") or ""
        local norestart = qs:match("norestart=1")
        local content = http.content()
        if content and content ~= "" then
            fs.writefile(db_path, content)
            if not norestart then
                sys.call("lua /usr/libexec/xray-ui-core.lua generate >/dev/null 2>&1")
                sys.call("/etc/init.d/xray restart >/dev/null 2>&1")
            end
            http.prepare_content("application/json")
            http.write(json.stringify({
                status = "ok",
                service = get_service_status(),
                config = fs.readfile(cfg_path) or "{}"
            }))
        end
    end
end

function action_add_node()
    local link = http.formvalue("link")
    http.prepare_content("application/json")
    if not link or link == "" then
        http.write(json.stringify({ success = false, error = "Link is empty" }))
        return
    end
    local tmp = "/tmp/xray_add_node.tmp"
    fs.writefile(tmp, link)
    local res = sys.exec("lua /usr/libexec/xray-ui-core.lua add_node " .. tmp .. " 2>&1")
    fs.remove(tmp)
    local parsed = res and json.parse(res)
    if type(parsed) == "table" and parsed.success ~= nil then
        http.write(res)
    else
        http.write(json.stringify({
            success = false,
            error = (res and res ~= "") and res:sub(1, 200) or "Failed to parse node"
        }))
    end
end

function action_ping()
    local content = http.content()
    http.prepare_content("application/json")
    if not content or content == "" then
        http.write(json.stringify({ success = false, ms = -1, error = "empty request" }))
        return
    end
    local _, u = nixio.gettimeofday()
    local tmp = string.format("/tmp/xray_ping_req_%d_%d.json", nixio.getpid(), u or 0)
    fs.writefile(tmp, content)
    local res = sys.exec("lua /usr/libexec/xray-ui-core.lua ping " .. tmp .. " 2>&1")
    fs.remove(tmp)
    local parsed = res and json.parse(res)
    if type(parsed) == "table" and parsed.success ~= nil then
        http.write(res)
    else
        local err_msg = (res and res ~= "") and res:gsub("%s+", " "):sub(1, 200) or "ping script failed"
        local cur = fs.readfile(ping_log_path) or ""
        fs.writefile(ping_log_path, cur .. "[" .. os.date("%H:%M:%S") .. "] [ERR] " .. err_msg .. "\n")
        http.write(json.stringify({ success = false, ms = -1, error = err_msg }))
    end
end

function action_ping_log()
    local method = http.getenv("REQUEST_METHOD")
    if method == "POST" and http.formvalue("clear") == "1" then
        fs.writefile(ping_log_path, "")
        http.prepare_content("application/json")
        http.write('{"ok":true}')
        return
    end
    http.prepare_content("text/plain; charset=utf-8")
    http.write(fs.readfile(ping_log_path) or "")
end

function action_fetch_sub()
    local sub_idx = tonumber(http.formvalue("index"))
    local res = sys.exec("lua /usr/libexec/xray-ui-core.lua fetch " .. tostring(sub_idx or 0) .. " 2>&1")
    http.prepare_content("application/json")
    local parsed = res and json.parse(res)
    if type(parsed) == "table" and parsed.success ~= nil then
        http.write(res)
    else
        http.write(json.stringify({
            success = false,
            error = (res and res ~= "") and res:sub(1, 200) or "Empty output from fetch script"
        }))
    end
end

function action_service_ctl()
    local act = http.formvalue("action")
    if act == "start" then sys.call("/etc/init.d/xray start >/dev/null 2>&1")
    elseif act == "stop" then sys.call("/etc/init.d/xray stop >/dev/null 2>&1")
    elseif act == "restart" then sys.call("/etc/init.d/xray restart >/dev/null 2>&1")
    elseif act == "enable" then sys.call("/etc/init.d/xray enable >/dev/null 2>&1")
    elseif act == "disable" then sys.call("/etc/init.d/xray disable >/dev/null 2>&1")
    end
    http.prepare_content("application/json")
    http.write(json.stringify(get_service_status()))
end

function action_get_config()
    http.prepare_content("application/json")
    http.write(json.stringify({
        service = get_service_status(),
        config = fs.readfile(cfg_path) or "{}"
    }))
end
EOF

cat << 'EOF' > /usr/lib/lua/luci/model/cbi/xray.lua
local fs = require "nixio.fs"
local sys = require "luci.sys"

local m = Map("xray_ui", "Xray Core")
local s = m:section(NamedSection, "main", "xray_ui")
s.addremove = false

s:tab("service", "Service")
s:tab("nodes", "Nodes")
s:tab("subs", "Subscriptions")
s:tab("rules", "Rules")
s:tab("config", "Config")

local status = s:taboption("service", DummyValue, "_status")
status.template = "xray_status"

local asset_dir = s:taboption("service", Value, "asset_dir", "Asset Directory")
asset_dir.default = "/usr/bin/"
asset_dir.description = "Path to geoip.dat and geosite.dat"

local nodes_ui = s:taboption("nodes", DummyValue, "_nodes")
nodes_ui.template = "xray_nodes"

local subs_ui = s:taboption("subs", DummyValue, "_subs")
subs_ui.template = "xray_subs"

local rules_ui = s:taboption("rules", DummyValue, "_rules")
rules_ui.template = "xray_rules"

local conf = s:taboption("config", TextValue, "_conf")
conf.wrap = "off"
conf.rows = 30
conf.description = "Единый конфигурационный файл /etc/xray/config.json. Активные ноды (из Nodes/Subscriptions и Rules) вставляются в outbounds со своими именами в качестве tag, а правила — в routing.rules."
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

cat << 'EOF' > /usr/lib/lua/luci/view/xray_status.htm
<%
    local sys = require "luci.sys"
    local xray_ver = sys.exec("xray version 2>/dev/null | head -n1 | awk '{print $2}'"):gsub("%s+", "")
    if xray_ver == "" then xray_ver = "Unknown" end

    local pid = sys.exec("pidof xray"):gsub("%s+", "")
    local is_running = (pid ~= "")
    if not is_running then pid = "-" end

    local is_enabled = (sys.call("/etc/init.d/xray enabled >/dev/null 2>&1") == 0)
%>
<style>
    .xr-card {
        background: rgba(255, 255, 255, 0.03);
        border: 1px solid rgba(255, 255, 255, 0.12);
        border-radius: 6px;
        padding: 16px;
        margin-bottom: 16px;
    }
    .xr-status-line {
        display: flex;
        flex-wrap: wrap;
        gap: 18px;
        align-items: center;
        margin: 12px 0 18px 0;
        font-size: 1.02em;
    }
    .xr-badge {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        padding: 3px 10px;
        border-radius: 4px;
        font-weight: 600;
        font-size: 0.85em;
        letter-spacing: 0.4px;
    }
    .xr-badge-run { background: rgba(76, 175, 80, 0.18); color: #66bb6a; border: 1px solid rgba(76, 175, 80, 0.4); }
    .xr-badge-rule { background: rgba(79, 195, 247, 0.16); color: #4fc3f7; border: 1px solid rgba(79, 195, 247, 0.4); }
    .xr-badge-stop { background: rgba(244, 67, 54, 0.18); color: #ef5350; border: 1px solid rgba(244, 67, 54, 0.4); }
    .xr-badge-idle { background: rgba(158, 158, 158, 0.15); color: #9e9e9e; border: 1px solid rgba(158, 158, 158, 0.3); }
    .xr-controls { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
    .xr-input-row { display: flex; gap: 8px; margin-bottom: 14px; }
    .xr-input-row input { flex: 1; }
    .xr-sub-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
        gap: 10px;
        margin: 10px 0 14px 0;
    }
    .xr-field label { display: block; font-size: 0.8em; opacity: 0.75; margin-bottom: 3px; }
    .xr-field input, .xr-field select { width: 100%; box-sizing: border-box; }
    .xr-drag-handle {
        cursor: grab;
        user-select: none;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        padding: 4px 6px;
        opacity: 0.55;
        transition: opacity 0.15s;
    }
    .xr-drag-handle:hover { opacity: 1; }
    .xr-drag-handle:active { cursor: grabbing; }
    .xr-row-dragging { opacity: 0.35; }
    .xr-row-over-top td { border-top: 2px solid #4fc3f7 !important; }
    .xr-row-over-bottom td { border-bottom: 2px solid #4fc3f7 !important; }
    .xr-chip {
        display: inline-block;
        background: rgba(255, 255, 255, 0.06);
        border: 1px solid rgba(255, 255, 255, 0.14);
        border-radius: 4px;
        padding: 2px 7px;
        margin: 2px 4px 2px 0;
        font-size: 0.84em;
        font-family: monospace;
    }

    /* Ping buttons & radar animation */
    .xr-ping-btn {
        min-width: 74px !important;
        font-weight: 600 !important;
        display: inline-flex !important;
        align-items: center;
        justify-content: center;
        gap: 5px;
        transition: background 0.18s, border-color 0.18s, color 0.18s;
    }
    .xr-ping-unpinged {
        background: rgba(0, 195, 255, 0.22) !important;
        color: #29d9ff !important;
        border: 1px solid #00c8ff !important;
    }
    .xr-ping-unpinged:hover {
        background: rgba(0, 195, 255, 0.36) !important;
    }
    .xr-ping-loading {
        background: rgba(0, 195, 255, 0.16) !important;
        color: #29d9ff !important;
        border: 1px solid #00c8ff !important;
        cursor: wait !important;
    }
    .xr-ping-good {
        background: rgba(0, 230, 118, 0.22) !important;
        color: #00e676 !important;
        border: 1px solid #00e676 !important;
    }
    .xr-ping-good:hover { background: rgba(0, 230, 118, 0.34) !important; }
    .xr-ping-mid {
        background: rgba(255, 234, 0, 0.22) !important;
        color: #ffea00 !important;
        border: 1px solid #ffd600 !important;
    }
    .xr-ping-mid:hover { background: rgba(255, 234, 0, 0.34) !important; }
    .xr-ping-slow {
        background: rgba(255, 145, 0, 0.24) !important;
        color: #ff9100 !important;
        border: 1px solid #ff9100 !important;
    }
    .xr-ping-slow:hover { background: rgba(255, 145, 0, 0.36) !important; }
    .xr-ping-fail {
        background: rgba(255, 23, 68, 0.22) !important;
        color: #ff5252 !important;
        border: 1px solid #ff1744 !important;
    }
    .xr-ping-fail:hover { background: rgba(255, 23, 68, 0.34) !important; }

    .xr-ping-radar {
        position: relative;
        display: inline-block;
        width: 12px;
        height: 12px;
        border-radius: 50%;
        background: #29d9ff;
        box-shadow: 0 0 6px #29d9ff;
    }
    .xr-ping-radar::after {
        content: "";
        position: absolute;
        inset: -3px;
        border-radius: 50%;
        border: 2px solid #29d9ff;
        animation: xr-radar-pulse 1s cubic-bezier(0.2, 0.8, 0.4, 1) infinite;
    }
    @keyframes xr-radar-pulse {
        0% { transform: scale(0.5); opacity: 1; }
        100% { transform: scale(1.85); opacity: 0; }
    }
    .xr-ping-opts {
        display: flex;
        flex-wrap: wrap;
        gap: 18px;
        align-items: center;
        margin-top: 8px;
    }
    .xr-ping-opts label {
        display: inline-flex;
        align-items: center;
        gap: 7px;
        cursor: pointer;
        font-size: 0.94em;
        user-select: none;
    }
    .xr-log-box {
        margin-top: 10px;
        background: rgba(0, 0, 0, 0.35);
        border: 1px solid rgba(255, 255, 255, 0.12);
        border-radius: 4px;
        padding: 10px;
        font-family: monospace;
        font-size: 0.82em;
        max-height: 220px;
        overflow-y: auto;
        white-space: pre-wrap;
        word-break: break-all;
        display: none;
    }
</style>

<div class="cbi-section xr-card">
    <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px;">
        <h3 style="margin:0;">Xray-core <span style="opacity:0.65; font-weight:normal;">v<%=xray_ver%></span></h3>
        <a href="https://github.com/XTLS/Xray-core" target="_blank" rel="noreferrer" style="font-size:0.85em; opacity:0.75;">github.com/XTLS/Xray-core</a>
    </div>

    <div class="xr-status-line">
        <div>
            Status:
            <span id="xr-svc-badge" class="xr-badge <%=is_running and 'xr-badge-run' or 'xr-badge-stop'%>">
                <%=is_running and "RUNNING" or "STOPPED"%>
            </span>
        </div>
        <div>PID: <code id="xr-svc-pid"><%=pid%></code></div>
        <div>Active Outbounds: <strong id="xr-active-profile" style="color:#4fc3f7;">None (Direct)</strong></div>
    </div>

    <div class="xr-controls">
        <button type="button" id="btn-svc-start" class="cbi-button cbi-button-apply" onclick="xrayServiceCtl('start')" <%=is_running and 'disabled' or ''%>>Start</button>
        <button type="button" id="btn-svc-restart" class="cbi-button cbi-button-action" onclick="xrayServiceCtl('restart')" <%=not is_running and 'disabled' or ''%>>Restart</button>
        <button type="button" id="btn-svc-stop" class="cbi-button cbi-button-reset" onclick="xrayServiceCtl('stop')" <%=not is_running and 'disabled' or ''%>>Stop</button>
        <span style="opacity:0.3; margin:0 6px;">|</span>
        <button type="button" id="btn-svc-enable" class="cbi-button cbi-button-save" onclick="xrayServiceCtl('enable')" <%=is_enabled and 'disabled' or ''%>>Enable Autostart</button>
        <button type="button" id="btn-svc-disable" class="cbi-button cbi-button-reset" onclick="xrayServiceCtl('disable')" <%=not is_enabled and 'disabled' or ''%>>Disable Autostart</button>
    </div>

    <hr style="border:none; border-top:1px solid rgba(255,255,255,0.1); margin:16px 0 12px 0;">

    <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px;">
        <strong style="font-size:0.95em;">Ping Settings</strong>
        <div style="display:flex; gap:8px; align-items:center;">
            <span id="xr-ping-settings-status" style="font-size:0.84em;"></span>
            <button type="button" id="btn-toggle-ping-log" class="cbi-button cbi-button-action" onclick="togglePingLog()">Show Ping Log</button>
            <button type="button" class="cbi-button cbi-button-reset" onclick="clearPingLog()">Clear Log</button>
        </div>
    </div>
    <div class="xr-ping-opts">
        <label title="Direct TCP handshake latency (uses tcping if installed)">
            <input type="checkbox" id="chk-ping-tcp" onchange="setPingModeSetting('tcp')">
            TCP Ping
        </label>
        <label title="Real HTTP HEAD request through isolated proxy tunnel (supports all protocols including Hysteria2)">
            <input type="checkbox" id="chk-ping-head" checked onchange="setPingModeSetting('head')">
            Via Proxy (HTTP HEAD)
        </label>
        <span style="opacity:0.25;">|</span>
        <label title="Dynamically sort nodes from lowest to highest ping during Ping All">
            <input type="checkbox" id="chk-ping-autosort" onchange="setAutoSortSetting(this.checked)">
            Auto-sort nodes by ping (Ping All)
        </label>
    </div>
    <pre id="xr-ping-log-box" class="xr-log-box"></pre>
</div>
EOF

cat << 'EOF' > /usr/lib/lua/luci/view/xray_nodes.htm
<div class="cbi-section xr-card" id="app-nodes">
    <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px; margin-bottom:12px;">
        <h3 style="margin:0;">Custom Nodes</h3>
        <div style="display:flex; gap:8px; align-items:center;">
            <button type="button" id="btn-ping-all-nodes" class="cbi-button xr-ping-btn xr-ping-unpinged" onclick="pingAllNodes()">Ping All</button>
            <button type="button" class="cbi-button cbi-button-action" onclick="sortNodesByPing()">Sort</button>
        </div>
    </div>
    <div class="xr-input-row">
        <input type="text" id="new-vless-link" class="cbi-input-text" placeholder="vless://, vmess://, trojan://, ss://, hysteria2://, socks://, http://, wireguard:// or JSON outbound" onkeydown="if(event.key==='Enter'){event.preventDefault();addNode();}">
        <button type="button" id="btn-add-node" class="cbi-button cbi-button-add" onclick="addNode()">Add Node</button>
    </div>
    <div id="node-status" style="font-size:0.88em; margin:-6px 0 12px 0; min-height:1.1em;"></div>

    <table class="table cbi-section-table">
        <tr class="tr cbi-section-table-titles">
            <th class="th" style="width:14%">Status</th>
            <th class="th" style="width:26%">Name (Tag)</th>
            <th class="th" style="width:23%">Endpoint</th>
            <th class="th" style="width:15%">Stack</th>
            <th class="th" style="width:22%; text-align:right;">Actions</th>
        </tr>
        <tbody id="nodes-table-body"></tbody>
    </table>
</div>

<script>
let db = { manual_nodes: [], managed_tags: [], settings: { ping_mode: 'head', auto_sort: false }, nodes: [], subs: [], rules: [] };

// Хранилище результатов пинга (по ссылке на объект и резервно по ключу) + активные задачи Ping All
const pingObjMap = new WeakMap();
const pingKeyMap = new Map();
const pingJobs = {};

function escapeHtml(s) {
    if (!s) return '';
    return String(s).replace(/[&<>"']/g, function(m) {
        return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[m];
    });
}

function normalizeClientDB(data) {
    if (!data || typeof data !== 'object') data = {};
    if (!Array.isArray(data.nodes)) data.nodes = [];
    if (!Array.isArray(data.subs)) data.subs = [];
    if (!Array.isArray(data.rules)) data.rules = [];
    if (!Array.isArray(data.managed_tags)) data.managed_tags = [];
    if (!data.settings || typeof data.settings !== 'object') {
        data.settings = { ping_mode: 'head', auto_sort: false };
    }
    if (data.settings.ping_mode !== 'tcp' && data.settings.ping_mode !== 'head') {
        data.settings.ping_mode = 'head';
    }
    data.settings.auto_sort = !!data.settings.auto_sort;

    if (!Array.isArray(data.manual_nodes)) {
        data.manual_nodes = [];
        if (data.active_type === 'node' && data.nodes[data.active_index]) {
            data.manual_nodes.push(data.nodes[data.active_index].name);
        } else if (data.active_type === 'sub' && data.subs[data.active_sub_index]) {
            const sub = data.subs[data.active_sub_index];
            if (sub.nodes && sub.nodes[data.active_node_index]) {
                data.manual_nodes.push(sub.nodes[data.active_node_index].name);
            }
        }
    }
    return data;
}

function getPingKey(scope, node) {
    const meta = getOutboundMeta(node && node.outbound);
    return scope + '::' + (node && node.name ? node.name : '') + '::' + meta.endpoint;
}

function getPingState(scope, node) {
    if (!node) return null;
    if (pingObjMap.has(node)) return pingObjMap.get(node);
    const k = getPingKey(scope, node);
    return pingKeyMap.has(k) ? pingKeyMap.get(k) : null;
}

function setPingState(scope, node, st) {
    if (!node) return;
    pingObjMap.set(node, st);
    pingKeyMap.set(getPingKey(scope, node), st);
}

function applyPingBtnStyle(btn, st) {
    if (!btn) return;
    btn.classList.remove('xr-ping-unpinged', 'xr-ping-loading', 'xr-ping-good', 'xr-ping-mid', 'xr-ping-slow', 'xr-ping-fail');
    if (!st || st.status === 'idle') {
        btn.classList.add('xr-ping-unpinged');
        btn.disabled = false;
        btn.textContent = 'Ping';
    } else if (st.status === 'loading') {
        btn.classList.add('xr-ping-loading');
        btn.disabled = true;
        btn.innerHTML = '<span class="xr-ping-radar"></span>';
    } else if (st.status === 'ok' && typeof st.ms === 'number') {
        btn.disabled = false;
        if (st.ms < 500) btn.classList.add('xr-ping-good');
        else if (st.ms < 1000) btn.classList.add('xr-ping-mid');
        else btn.classList.add('xr-ping-slow');
        btn.textContent = st.ms + ' ms';
    } else {
        btn.disabled = false;
        btn.classList.add('xr-ping-fail');
        btn.textContent = '-';
    }
}

function syncPingSettingsUI() {
    const chkTcp = document.getElementById('chk-ping-tcp');
    const chkHead = document.getElementById('chk-ping-head');
    const chkAuto = document.getElementById('chk-ping-autosort');
    const mode = (db.settings && db.settings.ping_mode) || 'head';
    if (chkTcp) chkTcp.checked = (mode === 'tcp');
    if (chkHead) chkHead.checked = (mode === 'head');
    if (chkAuto) chkAuto.checked = !!(db.settings && db.settings.auto_sort);
}

function refreshPingLog() {
    const box = document.getElementById('xr-ping-log-box');
    if (!box) return;
    fetch('<%=url("admin/services/xray/ping_log")%>')
        .then(r => r.text())
        .then(txt => {
            box.textContent = txt.trim() || '(Ping log is empty)';
            box.scrollTop = box.scrollHeight;
        });
}

function togglePingLog() {
    const box = document.getElementById('xr-ping-log-box');
    const btn = document.getElementById('btn-toggle-ping-log');
    if (!box) return;
    if (box.style.display === 'block') {
        box.style.display = 'none';
        if (btn) btn.textContent = 'Show Ping Log';
    } else {
        box.style.display = 'block';
        if (btn) btn.textContent = 'Hide Ping Log';
        refreshPingLog();
    }
}

function clearPingLog() {
    fetch('<%=url("admin/services/xray/ping_log")%>', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'clear=1'
    }).then(() => {
        const box = document.getElementById('xr-ping-log-box');
        if (box && box.style.display === 'block') box.textContent = '(Ping log is empty)';
    });
}

function saveSettingsSilent(msg) {
    const stEl = document.getElementById('xr-ping-settings-status');
    fetch('<%=url("admin/services/xray/api")%>?norestart=1', {
        method: 'POST',
        body: JSON.stringify(db)
    }).then(() => {
        if (stEl && msg) {
            stEl.style.color = '#66bb6a';
            stEl.textContent = msg;
            setTimeout(() => { if (stEl.textContent === msg) stEl.textContent = ''; }, 2000);
        }
    });
}

function setPingModeSetting(mode) {
    if (!db.settings) db.settings = {};
    db.settings.ping_mode = (mode === 'head') ? 'head' : 'tcp';
    syncPingSettingsUI();
    saveSettingsSilent(db.settings.ping_mode === 'head' ? 'Mode: Via Proxy (HEAD)' : 'Mode: TCP Ping');
}

function setAutoSortSetting(checked) {
    if (!db.settings) db.settings = {};
    db.settings.auto_sort = !!checked;
    syncPingSettingsUI();
    saveSettingsSilent(db.settings.auto_sort ? 'Auto-sort enabled' : 'Auto-sort disabled');
}

async function requestNodePing(node) {
    const mode = (db.settings && db.settings.ping_mode === 'head') ? 'head' : 'tcp';
    try {
        const resp = await fetch('<%=url("admin/services/xray/ping")%>', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ mode: mode, name: node.name || '', outbound: node.outbound })
        });
        const data = await resp.json();
        const box = document.getElementById('xr-ping-log-box');
        if (box && box.style.display === 'block') refreshPingLog();
        if (data && data.success && typeof data.ms === 'number' && data.ms >= 0) {
            return { status: 'ok', ms: data.ms };
        }
        return { status: 'fail', ms: null };
    } catch (e) {
        return { status: 'fail', ms: null };
    }
}

async function pingSingleNode(scope, node, btn) {
    const cur = getPingState(scope, node);
    if (cur && cur.status === 'loading') return;
    setPingState(scope, node, { status: 'loading', ms: null });
    applyPingBtnStyle(btn, { status: 'loading', ms: null });
    const res = await requestNodePing(node);
    setPingState(scope, node, res);
    applyPingBtnStyle(btn, res);
}

function getPingSortRank(scope, node) {
    const st = getPingState(scope, node);
    if (st && st.status === 'ok' && typeof st.ms === 'number') return { grp: 0, val: st.ms };
    if (st && st.status === 'fail') return { grp: 2, val: 9999999 };
    return { grp: 1, val: 9999999 };
}

function sortListAndAnimateTbody(list, tbody, scope, persistToDisk) {
    if (!Array.isArray(list) || list.length < 2) return;
    const rows = tbody ? Array.from(tbody.querySelectorAll('tr')) : [];
    const rowByNode = new Map();
    const firstTops = new Map();
    rows.forEach(tr => {
        if (tr._nodeRef) {
            rowByNode.set(tr._nodeRef, tr);
            firstTops.set(tr, tr.getBoundingClientRect().top);
        }
    });

    const decorated = list.map((n, i) => ({ node: n, idx: i, rank: getPingSortRank(scope, n) }));
    decorated.sort((a, b) => {
        if (a.rank.grp !== b.rank.grp) return a.rank.grp - b.rank.grp;
        if (a.rank.val !== b.rank.val) return a.rank.val - b.rank.val;
        return a.idx - b.idx;
    });

    for (let i = 0; i < decorated.length; i++) {
        list[i] = decorated[i].node;
    }

    if (tbody) {
        list.forEach(n => {
            const tr = rowByNode.get(n);
            if (tr) tbody.appendChild(tr);
        });
        list.forEach(n => {
            const tr = rowByNode.get(n);
            if (!tr) return;
            const prevTop = firstTops.get(tr);
            const newTop = tr.getBoundingClientRect().top;
            const dy = prevTop - newTop;
            if (Math.abs(dy) > 1) {
                tr.style.transition = 'none';
                tr.style.transform = `translateY(${dy}px)`;
                tr.offsetHeight;
                tr.style.transition = 'transform 220ms cubic-bezier(0.22, 1, 0.36, 1)';
                tr.style.transform = '';
            }
        });
    }

    if (persistToDisk) {
        fetch('<%=url("admin/services/xray/api")%>?norestart=1', {
            method: 'POST',
            body: JSON.stringify(db)
        }).catch(() => {});
    }
}

async function runPingAllBatch(scope, list, tbodyId, allBtn) {
    if (pingJobs[scope] && pingJobs[scope].running) {
        pingJobs[scope].cancelled = true;
        return;
    }
    if (!Array.isArray(list) || list.length === 0) return;

    const snapshot = list.slice();
    const job = {
        running: true,
        cancelled: false,
        liveSort: !!(db.settings && db.settings.auto_sort)
    };
    pingJobs[scope] = job;

    const origText = 'Ping All';
    let doneCount = 0;
    const total = snapshot.length;
    if (allBtn) allBtn.textContent = `Stop (0/${total})`;

    const getBtnForNode = (n) => {
        const tb = document.getElementById(tbodyId);
        if (!tb) return null;
        const rows = tb.querySelectorAll('tr');
        for (let i = 0; i < rows.length; i++) {
            if (rows[i]._nodeRef === n) return rows[i]._pingBtn || null;
        }
        return null;
    };

    snapshot.forEach(n => {
        setPingState(scope, n, { status: 'loading', ms: null });
        applyPingBtnStyle(getBtnForNode(n), { status: 'loading', ms: null });
    });

    const mode = (db.settings && db.settings.ping_mode === 'head') ? 'head' : 'tcp';
    const concurrency = (mode === 'head') ? 2 : 5;
    let cursor = 0;

    async function worker() {
        while (cursor < snapshot.length && !job.cancelled) {
            const node = snapshot[cursor++];
            const res = await requestNodePing(node);
            if (job.cancelled) {
                setPingState(scope, node, { status: 'idle', ms: null });
                applyPingBtnStyle(getBtnForNode(node), { status: 'idle', ms: null });
                break;
            }
            setPingState(scope, node, res);
            applyPingBtnStyle(getBtnForNode(node), res);
            doneCount++;
            if (allBtn) allBtn.textContent = `Stop (${doneCount}/${total})`;

            if (job.liveSort || (db.settings && db.settings.auto_sort)) {
                job.liveSort = true;
                sortListAndAnimateTbody(list, document.getElementById(tbodyId), scope, false);
            }
        }
    }

    const workers = [];
    for (let w = 0; w < Math.min(concurrency, snapshot.length); w++) {
        workers.push(worker());
    }
    await Promise.all(workers);

    if (job.cancelled) {
        snapshot.forEach(n => {
            const st = getPingState(scope, n);
            if (st && st.status === 'loading') {
                setPingState(scope, n, { status: 'idle', ms: null });
                applyPingBtnStyle(getBtnForNode(n), { status: 'idle', ms: null });
            }
        });
    }

    const shouldPersist = job.liveSort;
    job.running = false;
    delete pingJobs[scope];

    if (allBtn) allBtn.textContent = origText;
    if (shouldPersist) {
        sortListAndAnimateTbody(list, document.getElementById(tbodyId), scope, true);
    }
}

function pingAllNodes() {
    const btn = document.getElementById('btn-ping-all-nodes');
    runPingAllBatch('nodes', db.nodes, 'nodes-table-body', btn);
}

function sortNodesByPing() {
    const job = pingJobs['nodes'];
    if (job && job.running) {
        job.liveSort = true;
        sortListAndAnimateTbody(db.nodes, document.getElementById('nodes-table-body'), 'nodes', false);
    } else {
        sortListAndAnimateTbody(db.nodes, document.getElementById('nodes-table-body'), 'nodes', true);
    }
}

function isManualActive(name) {
    return Array.isArray(db.manual_nodes) && db.manual_nodes.indexOf(name) !== -1;
}

function isRuleActive(name) {
    if (!name || !Array.isArray(db.rules)) return false;
    return db.rules.some(r => r && r.outbound === name);
}

function getAllActiveNames() {
    const seen = new Set();
    const list = [];
    if (Array.isArray(db.manual_nodes)) {
        db.manual_nodes.forEach(n => {
            if (n && n !== 'direct' && n !== 'block' && !seen.has(n)) {
                seen.add(n);
                list.push(n);
            }
        });
    }
    if (Array.isArray(db.rules)) {
        db.rules.forEach(r => {
            const n = r && r.outbound;
            if (n && n !== 'direct' && n !== 'block' && !seen.has(n)) {
                seen.add(n);
                list.push(n);
            }
        });
    }
    return list;
}

function setNodeStatus(text, isError) {
    const el = document.getElementById('node-status');
    if (!el) return;
    el.style.color = isError ? '#ef5350' : '#66bb6a';
    el.innerText = text || '';
}

function updateConfigTextarea(cfgText) {
    if (typeof cfgText !== 'string') return;
    const ta = document.getElementById('cbid.xray_ui.main._conf');
    if (ta) ta.value = cfgText;
}

function updateServiceUI(svc) {
    if (!svc) return;
    const badge = document.getElementById('xr-svc-badge');
    const pidEl = document.getElementById('xr-svc-pid');
    if (badge) {
        badge.className = 'xr-badge ' + (svc.running ? 'xr-badge-run' : 'xr-badge-stop');
        badge.innerText = svc.running ? 'RUNNING' : 'STOPPED';
    }
    if (pidEl) pidEl.innerText = svc.pid || '-';

    const bStart = document.getElementById('btn-svc-start');
    const bRestart = document.getElementById('btn-svc-restart');
    const bStop = document.getElementById('btn-svc-stop');
    const bEnable = document.getElementById('btn-svc-enable');
    const bDisable = document.getElementById('btn-svc-disable');

    if (bStart) bStart.disabled = !!svc.running;
    if (bRestart) bRestart.disabled = !svc.running;
    if (bStop) bStop.disabled = !svc.running;
    if (bEnable) bEnable.disabled = !!svc.enabled;
    if (bDisable) bDisable.disabled = !svc.enabled;
}

function updateActiveProfileLabel() {
    const el = document.getElementById('xr-active-profile');
    if (!el) return;
    const active = getAllActiveNames();
    el.innerText = active.length > 0 ? active.join(', ') : 'None (Direct)';
}

function xrayServiceCtl(action) {
    fetch('<%=url("admin/services/xray/service_ctl")%>', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'action=' + encodeURIComponent(action)
    }).then(r => r.json()).then(svc => {
        updateServiceUI(svc);
    });
}

function syncConfigAndStatus() {
    fetch('<%=url("admin/services/xray/get_config")%>')
        .then(r => r.json())
        .then(res => {
            if (res.service) updateServiceUI(res.service);
            if (res.config) updateConfigTextarea(res.config);
        });
}

function getOutboundMeta(ob) {
    if (!ob) return { endpoint: '-', stack: '-' };
    let endpoint = '-';
    if (ob.settings && ob.settings.vnext && ob.settings.vnext[0]) {
        endpoint = ob.settings.vnext[0].address + ':' + ob.settings.vnext[0].port;
    } else if (ob.settings && ob.settings.servers && ob.settings.servers[0]) {
        endpoint = ob.settings.servers[0].address + ':' + ob.settings.servers[0].port;
    } else if (ob.settings && ob.settings.address && ob.settings.port) {
        endpoint = ob.settings.address + ':' + ob.settings.port;
    } else if (ob.settings && ob.settings.peers && ob.settings.peers[0] && ob.settings.peers[0].endpoint) {
        endpoint = ob.settings.peers[0].endpoint;
    }
    const proto = ob.protocol || 'unknown';
    const net = (ob.streamSettings && ob.streamSettings.network) || (proto === 'wireguard' ? 'udp' : 'tcp');
    const sec = (ob.streamSettings && ob.streamSettings.security) || 'none';
    return { endpoint: endpoint, stack: proto + ' / ' + net + ' / ' + sec };
}

function renderAllViews() {
    syncPingSettingsUI();
    updateActiveProfileLabel();
    renderNodes();
    if (typeof renderSubs === 'function') renderSubs();
    if (typeof renderRules === 'function') renderRules();
}

function loadDB(callback) {
    fetch('<%=url("admin/services/xray/api")%>')
        .then(r => r.json())
        .then(data => {
            db = normalizeClientDB(data);
            renderAllViews();
            syncConfigAndStatus();
            if (callback) callback();
        });
}

function saveDB(callback) {
    fetch('<%=url("admin/services/xray/api")%>', {
        method: 'POST',
        body: JSON.stringify(db)
    }).then(r => r.json()).then(res => {
        if (res && res.service) updateServiceUI(res.service);
        if (res && res.config) updateConfigTextarea(res.config);
        renderAllViews();
        if (callback) callback();
    });
}

function renderNodes() {
    const tbody = document.getElementById('nodes-table-body');
    if (!tbody) return;
    tbody.innerHTML = '';

    if (!db.nodes || db.nodes.length === 0) {
        tbody.innerHTML = '<tr class="tr"><td class="td" colspan="5"><em>No nodes added yet.</em></td></tr>';
        return;
    }

    db.nodes.forEach((n) => {
        const manual = isManualActive(n.name);
        const byRule = isRuleActive(n.name);
        const active = manual || byRule;
        const badgeClass = manual ? 'xr-badge-run' : (byRule ? 'xr-badge-rule' : 'xr-badge-idle');
        const badgeText = manual ? 'ACTIVE' : (byRule ? 'ACTIVE (RULE)' : 'IDLE');
        const btnClass = active ? 'cbi-button-reset' : 'cbi-button-apply';
        const btnText = active ? 'Stop' : 'Start';
        const meta = getOutboundMeta(n.outbound);

        const tr = document.createElement('tr');
        tr.className = 'tr cbi-section-table-row';
        tr._nodeRef = n;
        tr.innerHTML = `
            <td class="td"><span class="xr-badge ${badgeClass}">${badgeText}</span></td>
            <td class="td"><strong>${escapeHtml(n.name || 'Unnamed')}</strong></td>
            <td class="td"><code>${escapeHtml(meta.endpoint)}</code></td>
            <td class="td"><span style="font-size:0.88em; opacity:0.85;">${escapeHtml(meta.stack)}</span></td>
            <td class="td" style="text-align:right; white-space:nowrap;">
                <button type="button" class="cbi-button xr-ping-btn"></button>
                <button type="button" class="cbi-button ${btnClass} xr-btn-toggle">${btnText}</button>
                <button type="button" class="cbi-button cbi-button-remove xr-btn-del">Delete</button>
            </td>
        `;

        const pingBtn = tr.querySelector('.xr-ping-btn');
        tr._pingBtn = pingBtn;
        applyPingBtnStyle(pingBtn, getPingState('nodes', n));
        pingBtn.addEventListener('click', () => pingSingleNode('nodes', n, pingBtn));

        tr.querySelector('.xr-btn-toggle').addEventListener('click', () => {
            const idx = db.nodes.indexOf(n);
            if (idx !== -1) toggleNode(idx);
        });
        tr.querySelector('.xr-btn-del').addEventListener('click', () => {
            const idx = db.nodes.indexOf(n);
            if (idx !== -1) deleteNode(idx);
        });

        tbody.appendChild(tr);
    });
}

function addNode() {
    const input = document.getElementById('new-vless-link');
    const btn = document.getElementById('btn-add-node');
    const link = input ? input.value.trim() : '';
    if (!link) {
        setNodeStatus('Paste a proxy link or JSON outbound.', true);
        if (input) input.focus();
        return;
    }

    if (btn) {
        btn.disabled = true;
        btn.innerText = 'Adding...';
    }
    setNodeStatus('Parsing link...', false);

    fetch('<%=url("admin/services/xray/add_node")%>', {
        method: 'POST',
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'link=' + encodeURIComponent(link)
    }).then(r => r.json()).then(res => {
        if (res && res.success) {
            if (input) input.value = '';
            loadDB(() => setNodeStatus(`Added: ${res.name || 'Node'} (${res.protocol || 'ok'})`, false));
        } else {
            setNodeStatus((res && res.error) ? res.error : 'Invalid link', true);
        }
    }).catch(err => {
        setNodeStatus('Request error: ' + err, true);
    }).finally(() => {
        if (btn) {
            btn.disabled = false;
            btn.innerText = 'Add Node';
        }
    });
}

function toggleNode(idx) {
    const node = db.nodes[idx];
    if (!node) return;
    const name = node.name;
    const pos = db.manual_nodes.indexOf(name);
    if (pos !== -1) {
        db.manual_nodes.splice(pos, 1);
        saveDB(() => setNodeStatus(isRuleActive(name) ? `Removed from default (still active via Rules): ${name}` : `Stopped: ${name}`, false));
    } else if (isRuleActive(name)) {
        setNodeStatus(`"${name}" is active via Rules tab — remove it from Rules to stop.`, true);
    } else {
        db.manual_nodes.push(name);
        saveDB(() => setNodeStatus(`Started: ${name}`, false));
    }
}

function deleteNode(idx) {
    const node = db.nodes[idx];
    if (!node) return;
    if (isRuleActive(node.name)) {
        setNodeStatus(`Cannot delete "${node.name}" while it is used in Rules tab.`, true);
        return;
    }
    const pos = db.manual_nodes.indexOf(node.name);
    const wasActive = (pos !== -1);
    if (wasActive) db.manual_nodes.splice(pos, 1);
    db.nodes.splice(idx, 1);

    if (wasActive) {
        saveDB(() => setNodeStatus(`Removed active node: ${node.name}`, false));
    } else {
        fetch('<%=url("admin/services/xray/api")%>?norestart=1', {
            method: 'POST',
            body: JSON.stringify(db)
        }).then(r => r.json()).then(() => {
            renderAllViews();
            setNodeStatus(`Deleted: ${node.name}`, false);
        });
    }
}

document.addEventListener("DOMContentLoaded", () => loadDB());
</script>
EOF

cat << 'EOF' > /usr/lib/lua/luci/view/xray_subs.htm
<div class="cbi-section xr-card" id="app-subs">
    <h3 style="margin-top:0; margin-bottom:12px;">Subscriptions</h3>
    <div class="xr-input-row">
        <input type="text" id="new-sub-name" class="cbi-input-text" placeholder="Subscription alias (e.g. Happ / Main)" onkeydown="if(event.key==='Enter'){event.preventDefault();addSub();}">
        <button type="button" class="cbi-button cbi-button-add" onclick="addSub()">Add Subscription</button>
    </div>
    <div id="subs-container"></div>
</div>

<script>
function saveSubDB(callback) {
    fetch('<%=url("admin/services/xray/api")%>?norestart=1', {
        method: 'POST',
        body: JSON.stringify(db)
    }).then(r => r.json()).then(() => {
        if (callback) callback();
    });
}

function setSubStatus(sIdx, text, isError) {
    const el = document.getElementById(`sub-status-${sIdx}`);
    if (!el) return;
    el.style.color = isError ? '#ef5350' : '#66bb6a';
    el.innerText = text || '';
}

function toggleSubHeadersUI(sIdx) {
    const chk = document.getElementById(`sub-hdr-${sIdx}`);
    const grid = document.getElementById(`sub-hdr-grid-${sIdx}`);
    if (chk && grid) grid.style.display = chk.checked ? 'grid' : 'none';
}

function pingAllSub(sIdx, btn) {
    const sub = db.subs[sIdx];
    if (!sub || !Array.isArray(sub.nodes)) return;
    runPingAllBatch('sub:' + sIdx, sub.nodes, `sub-nodes-${sIdx}`, btn);
}

function sortSubNodes(sIdx) {
    const sub = db.subs[sIdx];
    if (!sub || !Array.isArray(sub.nodes)) return;
    const scope = 'sub:' + sIdx;
    const tbody = document.getElementById(`sub-nodes-${sIdx}`);
    const job = pingJobs[scope];
    if (job && job.running) {
        job.liveSort = true;
        sortListAndAnimateTbody(sub.nodes, tbody, scope, false);
    } else {
        sortListAndAnimateTbody(sub.nodes, tbody, scope, true);
    }
}

function renderSubs() {
    const cont = document.getElementById('subs-container');
    if (!cont) return;
    cont.innerHTML = '';
    if (!db.subs || db.subs.length === 0) {
        cont.innerHTML = '<p style="opacity:0.7;"><em>No subscriptions added.</em></p>';
        return;
    }
    db.subs.forEach((sub, sIdx) => {
        const useHeaders = (sub.use_headers !== false);
        const scope = 'sub:' + sIdx;
        let div = document.createElement('div');
        div.className = 'xr-card';
        div.style.marginBottom = '15px';
        div.innerHTML = `
            <div style="margin-bottom:12px;">
                <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px; margin-bottom:10px;">
                    <h4 style="margin:0;">${escapeHtml(sub.name)}</h4>
                    <label style="font-size:0.85em; cursor:pointer; display:inline-flex; align-items:center; gap:6px;">
                        <input type="checkbox" id="sub-hdr-${sIdx}" ${useHeaders ? 'checked' : ''} onchange="toggleSubHeadersUI(${sIdx})">
                        Send Happ Headers (User-Agent & HWID)
                    </label>
                </div>
                <div class="xr-field" style="margin-bottom:10px;">
                    <label>Subscription URL</label>
                    <input type="text" id="sub-url-${sIdx}" class="cbi-input-text" value="${escapeHtml(sub.url || '')}" placeholder="https://...">
                </div>
                <div class="xr-sub-grid" id="sub-hdr-grid-${sIdx}" style="display:${useHeaders ? 'grid' : 'none'};">
                    <div class="xr-field">
                        <label>User-Agent</label>
                        <input type="text" id="sub-ua-${sIdx}" class="cbi-input-text" value="${escapeHtml(sub.ua || 'Happ/4.3.0/Android/17877369741321921609')}" placeholder="User-Agent">
                    </div>
                    <div class="xr-field">
                        <label>x-hwid</label>
                        <input type="text" id="sub-hwid-${sIdx}" class="cbi-input-text" value="${escapeHtml(sub.hwid || '74ca5b6e0448953d')}" placeholder="x-hwid">
                    </div>
                    <div class="xr-field">
                        <label>x-device-locale</label>
                        <input type="text" id="sub-loc-${sIdx}" class="cbi-input-text" value="${escapeHtml(sub.locale || 'ru')}" placeholder="x-device-locale">
                    </div>
                    <div class="xr-field">
                        <label>x-device-os</label>
                        <input type="text" id="sub-os-${sIdx}" class="cbi-input-text" value="${escapeHtml(sub.os || 'Android')}" placeholder="x-device-os">
                    </div>
                    <div class="xr-field">
                        <label>x-ver-os</label>
                        <input type="text" id="sub-ver-${sIdx}" class="cbi-input-text" value="${escapeHtml(sub.ver_os || '17')}" placeholder="x-ver-os">
                    </div>
                    <div class="xr-field">
                        <label>x-device-model</label>
                        <input type="text" id="sub-model-${sIdx}" class="cbi-input-text" value="${escapeHtml(sub.model || 'A024')}" placeholder="x-device-model">
                    </div>
                </div>
                <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px;">
                    <div style="display:flex; gap:8px; align-items:center; flex-wrap:wrap;">
                        <button type="button" class="cbi-button cbi-button-save" onclick="saveSubFields(${sIdx})">Save Settings</button>
                        <button type="button" class="cbi-button cbi-button-action" onclick="updateSub(${sIdx}, this)">Update Nodes</button>
                        <button type="button" class="cbi-button cbi-button-remove" onclick="deleteSub(${sIdx})">Delete Sub</button>
                        <span id="sub-status-${sIdx}" style="font-size:0.88em; margin-left:6px;"></span>
                    </div>
                    <div style="display:flex; gap:8px; align-items:center;">
                        <button type="button" id="btn-ping-all-sub-${sIdx}" class="cbi-button xr-ping-btn xr-ping-unpinged" onclick="pingAllSub(${sIdx}, this)">Ping All</button>
                        <button type="button" class="cbi-button cbi-button-action" onclick="sortSubNodes(${sIdx})">Sort</button>
                    </div>
                </div>
            </div>
            <table class="table cbi-section-table" style="width: 100%; margin-bottom: 0;">
                <tr class="tr cbi-section-table-titles">
                    <th class="th" style="width:14%">Status</th>
                    <th class="th" style="width:27%">Node Name (Tag)</th>
                    <th class="th" style="width:23%">Endpoint</th>
                    <th class="th" style="width:15%">Stack</th>
                    <th class="th" style="width:21%; text-align:right;">Action</th>
                </tr>
                <tbody id="sub-nodes-${sIdx}"></tbody>
            </table>
        `;
        cont.appendChild(div);

        let tbody = document.getElementById(`sub-nodes-${sIdx}`);
        if (!sub.nodes || sub.nodes.length === 0) {
            tbody.innerHTML = '<tr class="tr"><td class="td" colspan="5"><em>Click Update Nodes to fetch.</em></td></tr>';
        } else {
            sub.nodes.forEach((n) => {
                const manual = isManualActive(n.name);
                const byRule = isRuleActive(n.name);
                const active = manual || byRule;
                const badgeClass = manual ? 'xr-badge-run' : (byRule ? 'xr-badge-rule' : 'xr-badge-idle');
                const badgeText = manual ? 'ACTIVE' : (byRule ? 'ACTIVE (RULE)' : 'IDLE');
                const btnClass = active ? 'cbi-button-reset' : 'cbi-button-apply';
                const btnText = active ? 'Stop' : 'Start';
                let meta = getOutboundMeta(n.outbound);
                let tr = document.createElement('tr');
                tr.className = 'tr cbi-section-table-row';
                tr._nodeRef = n;
                tr.innerHTML = `
                    <td class="td"><span class="xr-badge ${badgeClass}">${badgeText}</span></td>
                    <td class="td"><strong>${escapeHtml(n.name)}</strong></td>
                    <td class="td"><code>${escapeHtml(meta.endpoint)}</code></td>
                    <td class="td"><span style="font-size:0.88em; opacity:0.85;">${escapeHtml(meta.stack)}</span></td>
                    <td class="td" style="text-align: right; white-space:nowrap;">
                        <button type="button" class="cbi-button xr-ping-btn"></button>
                        <button type="button" class="cbi-button ${btnClass} xr-btn-sub-toggle">${btnText}</button>
                    </td>
                `;

                const pingBtn = tr.querySelector('.xr-ping-btn');
                tr._pingBtn = pingBtn;
                applyPingBtnStyle(pingBtn, getPingState(scope, n));
                pingBtn.addEventListener('click', () => pingSingleNode(scope, n, pingBtn));

                tr.querySelector('.xr-btn-sub-toggle').addEventListener('click', () => {
                    const nIdx = sub.nodes.indexOf(n);
                    if (nIdx !== -1) toggleSubNode(sIdx, nIdx);
                });

                tbody.appendChild(tr);
            });
        }
    });
}

function addSub() {
    const input = document.getElementById('new-sub-name');
    const name = input ? input.value.trim() : '';
    if (!name) {
        if (input) input.focus();
        return;
    }
    if (!db.subs) db.subs = [];
    db.subs.push({
        name: name,
        url: '',
        use_headers: true,
        ua: 'Happ/4.3.0/Android/17877369741321921609',
        hwid: '74ca5b6e0448953d',
        locale: 'ru',
        os: 'Android',
        ver_os: '17',
        model: 'A024',
        nodes: []
    });
    input.value = '';
    saveSubDB(() => renderAllViews());
}

function readSubInputs(sIdx) {
    db.subs[sIdx].url = document.getElementById(`sub-url-${sIdx}`).value.trim();
    db.subs[sIdx].use_headers = document.getElementById(`sub-hdr-${sIdx}`).checked;
    db.subs[sIdx].ua = document.getElementById(`sub-ua-${sIdx}`).value.trim();
    db.subs[sIdx].hwid = document.getElementById(`sub-hwid-${sIdx}`).value.trim();
    db.subs[sIdx].locale = document.getElementById(`sub-loc-${sIdx}`).value.trim();
    db.subs[sIdx].os = document.getElementById(`sub-os-${sIdx}`).value.trim();
    db.subs[sIdx].ver_os = document.getElementById(`sub-ver-${sIdx}`).value.trim();
    db.subs[sIdx].model = document.getElementById(`sub-model-${sIdx}`).value.trim();
}

function saveSubFields(sIdx) {
    readSubInputs(sIdx);
    saveSubDB(() => setSubStatus(sIdx, 'Settings saved', false));
}

function updateSub(sIdx, btn) {
    readSubInputs(sIdx);
    btn.disabled = true;
    btn.innerText = "Fetching...";
    setSubStatus(sIdx, 'Downloading...', false);

    saveSubDB(() => {
        fetch('<%=url("admin/services/xray/fetch_sub")%>', {
            method: 'POST',
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: 'index=' + sIdx
        }).then(r => r.json()).then(res => {
            if (res && res.success) {
                const count = res.count || 0;
                loadDB(() => setSubStatus(sIdx, `Updated: ${count} nodes`, false));
            } else {
                setSubStatus(sIdx, (res && res.error) ? res.error : 'Update failed', true);
            }
        }).catch(err => {
            setSubStatus(sIdx, 'Request error: ' + err, true);
        }).finally(() => {
            btn.disabled = false;
            btn.innerText = "Update Nodes";
        });
    });
}

function toggleSubNode(sIdx, nIdx) {
    const sub = db.subs[sIdx];
    const node = sub && sub.nodes && sub.nodes[nIdx];
    if (!node) return;
    const name = node.name;
    const pos = db.manual_nodes.indexOf(name);
    if (pos !== -1) {
        db.manual_nodes.splice(pos, 1);
        saveDB(() => setSubStatus(sIdx, isRuleActive(name) ? `Removed from default (still active via Rules): ${name}` : `Stopped: ${name}`, false));
    } else if (isRuleActive(name)) {
        setSubStatus(sIdx, `"${name}" is active via Rules tab — remove it from Rules to stop.`, true);
    } else {
        db.manual_nodes.push(name);
        saveDB(() => setSubStatus(sIdx, `Started: ${name}`, false));
    }
}

function deleteSub(sIdx) {
    const sub = db.subs[sIdx];
    if (!sub) return;
    let hadActive = false;
    if (Array.isArray(sub.nodes)) {
        sub.nodes.forEach(n => {
            const pos = db.manual_nodes.indexOf(n.name);
            if (pos !== -1) {
                db.manual_nodes.splice(pos, 1);
                hadActive = true;
            }
            if (isRuleActive(n.name)) hadActive = true;
        });
    }
    db.subs.splice(sIdx, 1);
    if (hadActive) {
        saveDB();
    } else {
        saveSubDB(() => renderAllViews());
    }
}
</script>
EOF

cat << 'EOF' > /usr/lib/lua/luci/view/xray_rules.htm
<div class="cbi-section xr-card" id="app-rules">
    <h3 style="margin-top:0; margin-bottom:12px;">Routing Rules</h3>

    <div class="xr-card" style="margin-bottom:14px;">
        <h4 id="rule-form-title" style="margin:0 0 10px 0;">New Rule</h4>
        <div class="xr-sub-grid">
            <div class="xr-field">
                <label>Rule Name</label>
                <input type="text" id="rule-name" class="cbi-input-text" placeholder="e.g. RU Direct / Streaming">
            </div>
            <div class="xr-field">
                <label>IP (CIDR / geoip:)</label>
                <input type="text" id="rule-ip" class="cbi-input-text" placeholder="geoip:ru, 192.168.0.0/16">
            </div>
            <div class="xr-field">
                <label>Domain (domain / geosite: / regexp:)</label>
                <input type="text" id="rule-domain" class="cbi-input-text" placeholder="example.com, geosite:category-ru">
            </div>
            <div class="xr-field">
                <label>Protocol</label>
                <input type="text" id="rule-protocol" class="cbi-input-text" placeholder="bittorrent, http, tls, quic">
            </div>
            <div class="xr-field">
                <label>Network</label>
                <select id="rule-network" class="cbi-input-select">
                    <option value="">Any</option>
                    <option value="tcp">tcp</option>
                    <option value="udp">udp</option>
                    <option value="tcp,udp">tcp,udp</option>
                </select>
            </div>
            <div class="xr-field">
                <label>Port (0-65535)</label>
                <input type="text" id="rule-port" class="cbi-input-text" placeholder="443 or 80,443 or 1000-2000">
            </div>
            <div class="xr-field">
                <label>Outbound (Node)</label>
                <select id="rule-outbound" class="cbi-input-select"></select>
            </div>
        </div>

        <div style="display:flex; gap:8px; align-items:center; flex-wrap:wrap;">
            <button type="button" id="btn-save-rule" class="cbi-button cbi-button-save" onclick="saveRule()">Add &amp; Save Rule</button>
            <button type="button" id="btn-cancel-rule" class="cbi-button cbi-button-reset" style="display:none;" onclick="resetRuleForm()">Cancel</button>
            <span id="rule-status" style="font-size:0.88em; margin-left:6px;"></span>
        </div>
    </div>

    <table class="table cbi-section-table" style="width:100%;">
        <tr class="tr cbi-section-table-titles">
            <th class="th" style="width:4%; text-align:center;" title="Drag to reorder"></th>
            <th class="th" style="width:5%">#</th>
            <th class="th" style="width:18%">Name</th>
            <th class="th" style="width:41%">Match Conditions</th>
            <th class="th" style="width:18%">Outbound</th>
            <th class="th" style="width:14%; text-align:right;">Actions</th>
        </tr>
        <tbody id="rules-table-body"></tbody>
    </table>
</div>

<script>
let editingRuleIdx = -1;
let dragRuleIdx = -1;
let dragDropBelow = false;

function setRuleStatus(text, isError) {
    const el = document.getElementById('rule-status');
    if (!el) return;
    el.style.color = isError ? '#ef5350' : '#66bb6a';
    el.innerText = text || '';
}

function validatePortField(val) {
    if (!val) return true;
    const parts = val.split(',');
    for (let i = 0; i < parts.length; i++) {
        const p = parts[i].trim();
        if (!p) continue;
        if (/^\d+$/.test(p)) {
            const n = Number(p);
            if (n < 0 || n > 65535) return false;
        } else if (/^\d+-\d+$/.test(p)) {
            const [a, b] = p.split('-').map(Number);
            if (a < 0 || b > 65535 || a > b) return false;
        } else {
            return false;
        }
    }
    return true;
}

function populateRuleOutboundSelect(selectedVal) {
    const sel = document.getElementById('rule-outbound');
    if (!sel) return;
    const prev = (selectedVal !== undefined) ? selectedVal : sel.value;
    sel.innerHTML = '';

    const optDirect = document.createElement('option');
    optDirect.value = 'direct';
    optDirect.textContent = 'direct';
    sel.appendChild(optDirect);

    const optBlock = document.createElement('option');
    optBlock.value = 'block';
    optBlock.textContent = 'block';
    sel.appendChild(optBlock);

    if (Array.isArray(db.nodes) && db.nodes.length > 0) {
        const grp = document.createElement('optgroup');
        grp.label = 'Custom Nodes';
        db.nodes.forEach(n => {
            if (!n || !n.name) return;
            const o = document.createElement('option');
            o.value = n.name;
            o.textContent = n.name;
            grp.appendChild(o);
        });
        if (grp.children.length > 0) sel.appendChild(grp);
    }

    if (Array.isArray(db.subs) && db.subs.length > 0) {
        db.subs.forEach(sub => {
            if (!sub || !Array.isArray(sub.nodes) || sub.nodes.length === 0) return;
            const grp = document.createElement('optgroup');
            grp.label = 'Sub: ' + (sub.name || 'Unnamed');
            sub.nodes.forEach(n => {
                if (!n || !n.name) return;
                const o = document.createElement('option');
                o.value = n.name;
                o.textContent = n.name;
                grp.appendChild(o);
            });
            if (grp.children.length > 0) sel.appendChild(grp);
        });
    }

    if (prev) {
        const exists = Array.from(sel.options).some(o => o.value === prev);
        if (!exists) {
            const missing = document.createElement('option');
            missing.value = prev;
            missing.textContent = prev + ' (not in list)';
            sel.appendChild(missing);
        }
        sel.value = prev;
    }
}

function resetRuleForm() {
    editingRuleIdx = -1;
    document.getElementById('rule-form-title').innerText = 'New Rule';
    document.getElementById('btn-save-rule').innerText = 'Add & Save Rule';
    document.getElementById('btn-cancel-rule').style.display = 'none';
    document.getElementById('rule-name').value = '';
    document.getElementById('rule-ip').value = '';
    document.getElementById('rule-domain').value = '';
    document.getElementById('rule-protocol').value = '';
    document.getElementById('rule-network').value = '';
    document.getElementById('rule-port').value = '';
    populateRuleOutboundSelect('direct');
}

function editRule(idx) {
    const r = db.rules[idx];
    if (!r) return;
    editingRuleIdx = idx;
    document.getElementById('rule-form-title').innerText = 'Edit Rule #' + (idx + 1);
    document.getElementById('btn-save-rule').innerText = 'Save Changes';
    document.getElementById('btn-cancel-rule').style.display = '';
    document.getElementById('rule-name').value = r.name || '';
    document.getElementById('rule-ip').value = r.ip || '';
    document.getElementById('rule-domain').value = r.domain || '';
    document.getElementById('rule-protocol').value = r.protocol || '';
    document.getElementById('rule-network').value = r.network || '';
    document.getElementById('rule-port').value = r.port || '';
    populateRuleOutboundSelect(r.outbound || 'direct');
    setRuleStatus('Editing rule #' + (idx + 1), false);
    document.getElementById('rule-name').focus();
}

function saveRule() {
    const name = document.getElementById('rule-name').value.trim();
    const ip = document.getElementById('rule-ip').value.trim();
    const domain = document.getElementById('rule-domain').value.trim();
    const protocol = document.getElementById('rule-protocol').value.trim();
    const network = document.getElementById('rule-network').value.trim();
    const port = document.getElementById('rule-port').value.trim();
    const outbound = document.getElementById('rule-outbound').value;

    if (!ip && !domain && !protocol && !network && !port) {
        setRuleStatus('Fill at least one condition (IP, Domain, Protocol, Network, or Port).', true);
        return;
    }
    if (!validatePortField(port)) {
        setRuleStatus('Invalid port. Use 0-65535 (single, comma-separated, or range a-b).', true);
        return;
    }
    if (!outbound) {
        setRuleStatus('Select an outbound node.', true);
        return;
    }

    const ruleObj = {
        name: name || ('Rule #' + (editingRuleIdx >= 0 ? editingRuleIdx + 1 : (db.rules.length + 1))),
        ip: ip,
        domain: domain,
        protocol: protocol,
        network: network,
        port: port,
        outbound: outbound
    };

    if (!Array.isArray(db.rules)) db.rules = [];
    const wasEditing = (editingRuleIdx >= 0 && editingRuleIdx < db.rules.length);
    if (wasEditing) {
        db.rules[editingRuleIdx] = ruleObj;
    } else {
        db.rules.push(ruleObj);
    }

    resetRuleForm();
    setRuleStatus('Saving & applying config...', false);
    saveDB(() => {
        setRuleStatus(wasEditing ? `Rule "${ruleObj.name}" updated.` : `Rule "${ruleObj.name}" added & applied.`, false);
    });
}

function deleteRule(idx) {
    const r = db.rules[idx];
    if (!r) return;
    if (editingRuleIdx === idx) resetRuleForm();
    else if (editingRuleIdx > idx) editingRuleIdx -= 1;

    db.rules.splice(idx, 1);
    setRuleStatus('Applying changes...', false);
    saveDB(() => {
        setRuleStatus(`Rule "${r.name}" removed.`, false);
    });
}

function formatRuleMatchChips(r) {
    const chips = [];
    if (r.domain) chips.push(`<span class="xr-chip">domain: ${escapeHtml(r.domain)}</span>`);
    if (r.ip) chips.push(`<span class="xr-chip">ip: ${escapeHtml(r.ip)}</span>`);
    if (r.protocol) chips.push(`<span class="xr-chip">proto: ${escapeHtml(r.protocol)}</span>`);
    if (r.network) chips.push(`<span class="xr-chip">net: ${escapeHtml(r.network)}</span>`);
    if (r.port) chips.push(`<span class="xr-chip">port: ${escapeHtml(r.port)}</span>`);
    return chips.length > 0 ? chips.join('') : '<em>-</em>';
}

function clearDragIndicators() {
    const tbody = document.getElementById('rules-table-body');
    if (!tbody) return;
    tbody.querySelectorAll('tr').forEach(row => {
        row.classList.remove('xr-row-over-top', 'xr-row-over-bottom', 'xr-row-dragging');
    });
}

function renderRules() {
    populateRuleOutboundSelect();
    const tbody = document.getElementById('rules-table-body');
    if (!tbody) return;
    tbody.innerHTML = '';

    if (!Array.isArray(db.rules) || db.rules.length === 0) {
        tbody.innerHTML = '<tr class="tr"><td class="td" colspan="6"><em>No routing rules configured. Add a rule above.</em></td></tr>';
        return;
    }

    db.rules.forEach((r, idx) => {
        const outBadgeClass = (r.outbound === 'block') ? 'xr-badge-stop'
            : (r.outbound === 'direct' ? 'xr-badge-idle' : 'xr-badge-run');

        const tr = document.createElement('tr');
        tr.className = 'tr cbi-section-table-row';
        tr.dataset.ruleIdx = String(idx);
        tr.draggable = false;

        tr.innerHTML = `
            <td class="td" style="text-align:center; vertical-align:middle;">
                <span class="xr-drag-handle" title="Drag to reorder">
                    <svg width="12" height="16" viewBox="0 0 12 16" fill="currentColor">
                        <circle cx="3" cy="3" r="1.4"/><circle cx="9" cy="3" r="1.4"/>
                        <circle cx="3" cy="8" r="1.4"/><circle cx="9" cy="8" r="1.4"/>
                        <circle cx="3" cy="13" r="1.4"/><circle cx="9" cy="13" r="1.4"/>
                    </svg>
                </span>
            </td>
            <td class="td"><code>${idx + 1}</code></td>
            <td class="td"><strong>${escapeHtml(r.name || ('Rule #' + (idx + 1)))}</strong></td>
            <td class="td">${formatRuleMatchChips(r)}</td>
            <td class="td"><span class="xr-badge ${outBadgeClass}">${escapeHtml(r.outbound || 'direct')}</span></td>
            <td class="td" style="text-align:right; white-space:nowrap;">
                <button type="button" class="cbi-button cbi-button-action" onclick="editRule(${idx})">Edit</button>
                <button type="button" class="cbi-button cbi-button-remove" onclick="deleteRule(${idx})">Delete</button>
            </td>
        `;

        const handle = tr.querySelector('.xr-drag-handle');
        handle.addEventListener('mousedown', () => { tr.draggable = true; });
        handle.addEventListener('mouseup', () => { tr.draggable = false; });

        tr.addEventListener('dragstart', (e) => {
            if (!tr.draggable) {
                e.preventDefault();
                return;
            }
            dragRuleIdx = idx;
            tr.classList.add('xr-row-dragging');
            e.dataTransfer.effectAllowed = 'move';
            e.dataTransfer.setData('text/plain', String(idx));
        });

        tr.addEventListener('dragover', (e) => {
            if (dragRuleIdx === -1) return;
            e.preventDefault();
            e.dataTransfer.dropEffect = 'move';
            const rect = tr.getBoundingClientRect();
            dragDropBelow = (e.clientY - rect.top) > (rect.height / 2);
            clearDragIndicators();
            const srcRow = tbody.querySelector(`tr[data-rule-idx="${dragRuleIdx}"]`);
            if (srcRow) srcRow.classList.add('xr-row-dragging');
            if (idx !== dragRuleIdx) {
                tr.classList.add(dragDropBelow ? 'xr-row-over-bottom' : 'xr-row-over-top');
            }
        });

        tr.addEventListener('drop', (e) => {
            e.preventDefault();
            if (dragRuleIdx === -1 || dragRuleIdx === idx) {
                clearDragIndicators();
                dragRuleIdx = -1;
                return;
            }
            let targetIdx = idx;
            if (dragRuleIdx < idx) {
                targetIdx = dragDropBelow ? idx : (idx - 1);
            } else {
                targetIdx = dragDropBelow ? (idx + 1) : idx;
            }
            clearDragIndicators();
            if (targetIdx !== dragRuleIdx) {
                const moved = db.rules.splice(dragRuleIdx, 1)[0];
                db.rules.splice(targetIdx, 0, moved);
                if (editingRuleIdx !== -1) resetRuleForm();
                setRuleStatus('Updating rule order...', false);
                saveDB(() => setRuleStatus('Rule order saved.', false));
            }
            dragRuleIdx = -1;
        });

        tr.addEventListener('dragend', () => {
            tr.draggable = false;
            dragRuleIdx = -1;
            clearDragIndicators();
        });

        tbody.appendChild(tr);
    });
}
</script>
EOF

#!/bin/sh
set -e

echo "===> Ensuring line 337 fix in /usr/libexec/xray-ui-core.lua..."
if [ -f "/usr/libexec/xray-ui-core.lua" ]; then
    sed -i 's/tonumber(sec_str:gsub(",", "\."))/tonumber((sec_str:gsub(",", ".")))/' /usr/libexec/xray-ui-core.lua
fi

echo "===> Initializing UCI runtime limits if missing..."
touch /etc/config/xray_ui
uci -q get xray_ui.main >/dev/null 2>&1 || uci set xray_ui.main=xray_ui
uci -q get xray_ui.main.asset_dir >/dev/null 2>&1 || uci set xray_ui.main.asset_dir="/usr/bin/"
uci -q get xray_ui.main.gomemlimit >/dev/null 2>&1 || uci set xray_ui.main.gomemlimit="65MiB"
uci -q get xray_ui.main.gogc >/dev/null 2>&1 || uci set xray_ui.main.gogc="40"
uci commit xray_ui

echo "===> Updating /etc/init.d/xray with configurable GOMEMLIMIT and GOGC..."
cat << 'EOF' > /etc/init.d/xray
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

start_service() {
    if [ ! -f "/etc/xray/config.json" ]; then
        lua /usr/libexec/xray-ui-core.lua generate
    fi

    if [ ! -f "/etc/xray/config.json" ]; then return 1; fi
    local asset_dir=$(uci -q get xray_ui.main.asset_dir || echo "/usr/bin/")
    local gomem=$(uci -q get xray_ui.main.gomemlimit || echo "65MiB")
    local gogc=$(uci -q get xray_ui.main.gogc || echo "40")
    [ -z "$asset_dir" ] && asset_dir="/usr/bin/"
    [ -z "$gomem" ] && gomem="65MiB"
    [ -z "$gogc" ] && gogc="40"

    procd_open_instance
    procd_set_param command /usr/bin/xray run -c /etc/xray/config.json
    procd_set_param env GOMEMLIMIT="$gomem" GOGC="$gogc" XRAY_LOCATION_ASSET="$asset_dir"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn
    procd_close_instance
}

reload_service() {
    restart
}
EOF
chmod +x /etc/init.d/xray

echo "===> Updating /usr/lib/lua/luci/controller/xray.lua..."
cat << 'EOF' > /usr/lib/lua/luci/controller/xray.lua
module("luci.controller.xray", package.seeall)

function index()
    entry({"admin", "services", "xray"}, cbi("xray"), _("Xray Core"), 50).dependent = true
    entry({"admin", "services", "xray", "api"}, call("action_api")).leaf = true
    entry({"admin", "services", "xray", "fetch_sub"}, call("action_fetch_sub")).leaf = true
    entry({"admin", "services", "xray", "add_node"}, call("action_add_node")).leaf = true
    entry({"admin", "services", "xray", "ping"}, call("action_ping")).leaf = true
    entry({"admin", "services", "xray", "ping_log"}, call("action_ping_log")).leaf = true
    entry({"admin", "services", "xray", "service_ctl"}, call("action_service_ctl")).leaf = true
    entry({"admin", "services", "xray", "get_config"}, call("action_get_config")).leaf = true
    entry({"admin", "services", "xray", "geo_list"}, call("action_geo_list")).leaf = true
    entry({"admin", "services", "xray", "geo_download"}, call("action_geo_download")).leaf = true
    entry({"admin", "services", "xray", "service_ext"}, call("action_service_ext")).leaf = true
end

local fs = require "nixio.fs"
local nixio = require "nixio"
local sys = require "luci.sys"
local http = require "luci.http"
local json = require "luci.jsonc"

local db_path = "/etc/xray/nodes.json"
local cfg_path = "/etc/xray/config.json"
local ping_log_path = "/tmp/xray_ping.log"
local cron_cfg_path = "/etc/xray/cron.json"
local crontab_path = "/etc/crontabs/root"

local INTERVAL_MAP = {
    ["1h"]  = "0 * * * *",
    ["3h"]  = "0 */3 * * *",
    ["6h"]  = "0 */6 * * *",
    ["12h"] = "0 */12 * * *",
    ["1d"]  = "0 4 * * *",
    ["3d"]  = "0 4 */3 * *",
    ["7d"]  = "0 4 * * 1",
    ["14d"] = "0 4 1,15 * *",
    ["30d"] = "0 4 1 * *"
}

local function get_asset_dir()
    local d = (sys.exec("uci -q get xray_ui.main.asset_dir") or "/usr/bin/"):gsub("%s+", "")
    if d == "" then d = "/usr/bin/" end
    if d:sub(-1) ~= "/" then d = d .. "/" end
    return d
end

local function list_dat_files(dir)
    local files = {}
    local iter = fs.dir(dir)
    if iter then
        for name in iter do
            if name:lower():match("%.dat$") then
                local st = fs.stat(dir .. name)
                if st and st.type == "reg" then
                    table.insert(files, {
                        name = name,
                        size = st.size or 0,
                        mtime = st.mtime or 0
                    })
                end
            end
        end
    end
    table.sort(files, function(a, b) return a.name < b.name end)
    return files
end

local function is_safe_filename(name)
    if type(name) ~= "string" or name == "" then return false end
    if name:find("/", 1, true) or name:find("..", 1, true) then return false end
    return name:match("^[%w%.%-%_]+$") ~= nil
end

local function is_safe_url(url)
    if type(url) ~= "string" or url == "" then return false end
    if not url:match("^https?://") then return false end
    if url:find("[%s\"'`$;|&<>]") then return false end
    return true
end

local function get_service_status()
    local pid = sys.exec("pidof xray"):gsub("%s+", "")
    local is_running = (pid ~= "")
    local is_enabled = (sys.call("/etc/init.d/xray enabled >/dev/null 2>&1") == 0)
    return {
        running = is_running,
        pid = is_running and pid or "-",
        enabled = is_enabled
    }
end

local function default_cron_cfg()
    return {
        geo_enabled = false,
        geofiles = {
            { enabled = false, url = "", filename = "geosite.dat", interval = "7d" },
            { enabled = false, url = "", filename = "geoip.dat", interval = "7d" }
        },
        restart_enabled = false,
        restart_interval = "1d"
    }
end

local function load_cron_cfg()
    local raw = fs.readfile(cron_cfg_path)
    local parsed = raw and json.parse(raw) or nil
    if type(parsed) ~= "table" then return default_cron_cfg() end
    if type(parsed.geofiles) ~= "table" then parsed.geofiles = {} end
    return parsed
end

local function apply_crontab(cron_cfg)
    local dir = get_asset_dir()
    fs.mkdirr("/etc/crontabs")
    local existing = fs.readfile(crontab_path) or ""
    local kept = {}
    local inside = false
    for line in (existing .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        if line == "# XRAY_UI_CRON_BEGIN" then
            inside = true
        elseif line == "# XRAY_UI_CRON_END" then
            inside = false
        elseif not inside then
            table.insert(kept, line)
        end
    end
    while #kept > 0 and kept[#kept] == "" do
        table.remove(kept)
    end

    local jobs = {}
    if cron_cfg.geo_enabled and type(cron_cfg.geofiles) == "table" then
        for _, g in ipairs(cron_cfg.geofiles) do
            if type(g) == "table" and g.enabled then
                local url = tostring(g.url or ""):gsub("^%s+", ""):gsub("%s+$", "")
                local fname = tostring(g.filename or ""):gsub("^%s+", ""):gsub("%s+$", "")
                local sched = INTERVAL_MAP[tostring(g.interval or "")]
                if sched and is_safe_url(url) and is_safe_filename(fname) then
                    table.insert(jobs, string.format('%s wget -O "%s%s" "%s"', sched, dir, fname, url))
                end
            end
        end
    end

    if cron_cfg.restart_enabled then
        local sched = INTERVAL_MAP[tostring(cron_cfg.restart_interval or "")]
        if sched then
            table.insert(jobs, string.format('%s /etc/init.d/xray restart', sched))
        end
    end

    if #jobs > 0 then
        table.insert(kept, "# XRAY_UI_CRON_BEGIN")
        for _, j in ipairs(jobs) do
            table.insert(kept, j)
        end
        table.insert(kept, "# XRAY_UI_CRON_END")
    end

    local final_text = (#kept > 0) and (table.concat(kept, "\n") .. "\n") or ""
    fs.writefile(crontab_path, final_text)
    sys.call("/etc/init.d/cron enable >/dev/null 2>&1; /etc/init.d/cron restart >/dev/null 2>&1")
    return #jobs
end

function action_api()
    local method = http.getenv("REQUEST_METHOD")
    if method == "GET" then
        http.prepare_content("application/json")
        http.write(fs.readfile(db_path) or "{}")
    elseif method == "POST" then
        local qs = http.getenv("QUERY_STRING") or ""
        local norestart = qs:match("norestart=1")
        local content = http.content()
        if content and content ~= "" then
            fs.writefile(db_path, content)
            if not norestart then
                sys.call("lua /usr/libexec/xray-ui-core.lua generate >/dev/null 2>&1")
                sys.call("/etc/init.d/xray restart >/dev/null 2>&1")
            end
            http.prepare_content("application/json")
            http.write(json.stringify({
                status = "ok",
                service = get_service_status(),
                config = fs.readfile(cfg_path) or "{}"
            }))
        end
    end
end

function action_add_node()
    local link = http.formvalue("link")
    http.prepare_content("application/json")
    if not link or link == "" then
        http.write(json.stringify({ success = false, error = "Link is empty" }))
        return
    end
    local tmp = "/tmp/xray_add_node.tmp"
    fs.writefile(tmp, link)
    local res = sys.exec("lua /usr/libexec/xray-ui-core.lua add_node " .. tmp .. " 2>&1")
    fs.remove(tmp)
    local parsed = res and json.parse(res)
    if type(parsed) == "table" and parsed.success ~= nil then
        http.write(res)
    else
        http.write(json.stringify({
            success = false,
            error = (res and res ~= "") and res:sub(1, 200) or "Failed to parse node"
        }))
    end
end

function action_ping()
    local content = http.content()
    http.prepare_content("application/json")
    if not content or content == "" then
        http.write(json.stringify({ success = false, ms = -1, error = "empty request" }))
        return
    end
    local _, u = nixio.gettimeofday()
    local tmp = string.format("/tmp/xray_ping_req_%d_%d.json", nixio.getpid(), u or 0)
    fs.writefile(tmp, content)
    local res = sys.exec("lua /usr/libexec/xray-ui-core.lua ping " .. tmp .. " 2>&1")
    fs.remove(tmp)
    local parsed = res and json.parse(res)
    if type(parsed) == "table" and parsed.success ~= nil then
        http.write(res)
    else
        local err_msg = (res and res ~= "") and res:gsub("%s+", " "):sub(1, 200) or "ping script failed"
        local cur = fs.readfile(ping_log_path) or ""
        fs.writefile(ping_log_path, cur .. "[" .. os.date("%H:%M:%S") .. "] [ERR] " .. err_msg .. "\n")
        http.write(json.stringify({ success = false, ms = -1, error = err_msg }))
    end
end

function action_ping_log()
    local method = http.getenv("REQUEST_METHOD")
    if method == "POST" and http.formvalue("clear") == "1" then
        fs.writefile(ping_log_path, "")
        http.prepare_content("application/json")
        http.write('{"ok":true}')
        return
    end
    http.prepare_content("text/plain; charset=utf-8")
    http.write(fs.readfile(ping_log_path) or "")
end

function action_fetch_sub()
    local sub_idx = tonumber(http.formvalue("index"))
    local res = sys.exec("lua /usr/libexec/xray-ui-core.lua fetch " .. tostring(sub_idx or 0) .. " 2>&1")
    http.prepare_content("application/json")
    local parsed = res and json.parse(res)
    if type(parsed) == "table" and parsed.success ~= nil then
        http.write(res)
    else
        http.write(json.stringify({
            success = false,
            error = (res and res ~= "") and res:sub(1, 200) or "Empty output from fetch script"
        }))
    end
end

function action_service_ctl()
    local act = http.formvalue("action")
    if act == "start" then sys.call("/etc/init.d/xray start >/dev/null 2>&1")
    elseif act == "stop" then sys.call("/etc/init.d/xray stop >/dev/null 2>&1")
    elseif act == "restart" then sys.call("/etc/init.d/xray restart >/dev/null 2>&1")
    elseif act == "enable" then sys.call("/etc/init.d/xray enable >/dev/null 2>&1")
    elseif act == "disable" then sys.call("/etc/init.d/xray disable >/dev/null 2>&1")
    end
    http.prepare_content("application/json")
    http.write(json.stringify(get_service_status()))
end

function action_get_config()
    http.prepare_content("application/json")
    http.write(json.stringify({
        service = get_service_status(),
        config = fs.readfile(cfg_path) or "{}"
    }))
end

function action_geo_list()
    local dir = get_asset_dir()
    http.prepare_content("application/json")
    http.write(json.stringify({
        dir = dir,
        files = list_dat_files(dir)
    }))
end

function action_geo_download()
    local content = http.content()
    local req = content and json.parse(content) or nil
    local dir = get_asset_dir()
    http.prepare_content("application/json")

    if type(req) ~= "table" then
        http.write(json.stringify({ success = false, error = "Invalid request" }))
        return
    end

    local url = tostring(req.url or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local fname = tostring(req.filename or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if not is_safe_url(url) then
        http.write(json.stringify({ success = false, error = "Invalid URL (expected http:// or https://)" }))
        return
    end
    if not is_safe_filename(fname) then
        http.write(json.stringify({ success = false, error = "Invalid filename (use letters, digits, '.', '-', '_')" }))
        return
    end

    fs.mkdirr(dir)
    local dest = dir .. fname
    local cmd = string.format('wget -O "%s" "%s" 2>&1; printf "\\nRC=%%d" $?', dest, url)
    local out = sys.exec(cmd) or ""
    local rc = tonumber(out:match("RC=(%d+)%s*$")) or 1
    local msg = out:gsub("RC=%d+%s*$", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

    if rc == 0 then
        http.write(json.stringify({
            success = true,
            dir = dir,
            files = list_dat_files(dir)
        }))
    else
        http.write(json.stringify({
            success = false,
            error = (msg ~= "" and msg:sub(-160) or "wget failed (rc=" .. rc .. ")"),
            dir = dir,
            files = list_dat_files(dir)
        }))
    end
end

function action_service_ext()
    local method = http.getenv("REQUEST_METHOD")
    http.prepare_content("application/json")

    if method == "GET" then
        local gomem = (sys.exec("uci -q get xray_ui.main.gomemlimit") or "65MiB"):gsub("%s+", "")
        local gogc = (sys.exec("uci -q get xray_ui.main.gogc") or "40"):gsub("%s+", "")
        if gomem == "" then gomem = "65MiB" end
        if gogc == "" then gogc = "40" end
        http.write(json.stringify({
            cron = load_cron_cfg(),
            limits = { gomemlimit = gomem, gogc = gogc }
        }))
        return
    end

    local content = http.content()
    local req = content and json.parse(content) or nil
    if type(req) ~= "table" then
        http.write(json.stringify({ success = false, error = "Invalid payload" }))
        return
    end

    if req.section == "cron" and type(req.cron) == "table" then
        fs.writefile(cron_cfg_path, json.stringify(req.cron, true))
        local count = apply_crontab(req.cron)
        http.write(json.stringify({ success = true, jobs = count }))
        return
    end

    if req.section == "limits" and type(req.limits) == "table" then
        local gomem = tostring(req.limits.gomemlimit or ""):gsub("%s+", "")
        local gogc = tostring(req.limits.gogc or ""):gsub("%s+", "")
        if gomem == "" or not gomem:match("^[%w]+$") then
            http.write(json.stringify({ success = false, error = "Invalid GOMEMLIMIT (e.g. 65MiB, 128MiB)" }))
            return
        end
        if gogc == "" or not (gogc:match("^%d+$") or gogc == "off") then
            http.write(json.stringify({ success = false, error = "Invalid GOGC (integer or 'off')" }))
            return
        end
        sys.call(string.format("uci set xray_ui.main.gomemlimit='%s' && uci set xray_ui.main.gogc='%s' && uci commit xray_ui", gomem, gogc))
        local restarted = false
        if sys.call("pidof xray >/dev/null 2>&1") == 0 then
            sys.call("/etc/init.d/xray restart >/dev/null 2>&1")
            restarted = true
        end
        http.write(json.stringify({
            success = true,
            restarted = restarted,
            service = get_service_status()
        }))
        return
    end

    http.write(json.stringify({ success = false, error = "Unknown section" }))
end
EOF

echo "===> Updating /usr/lib/lua/luci/model/cbi/xray.lua..."
cat << 'EOF' > /usr/lib/lua/luci/model/cbi/xray.lua
local fs = require "nixio.fs"
local sys = require "luci.sys"

local m = Map("xray_ui", "Xray Core")
local s = m:section(NamedSection, "main", "xray_ui")
s.addremove = false

s:tab("service", "Service")
s:tab("nodes", "Nodes")
s:tab("subs", "Subscriptions")
s:tab("rules", "Rules")
s:tab("config", "Config")

local status = s:taboption("service", DummyValue, "_status")
status.template = "xray_status"

local asset_dir = s:taboption("service", Value, "asset_dir", "Asset Directory")
asset_dir.default = "/usr/bin/"
asset_dir.description = "Directory containing .dat geofiles"

local service_extra = s:taboption("service", DummyValue, "_service_extra")
service_extra.template = "xray_service_extra"

local nodes_ui = s:taboption("nodes", DummyValue, "_nodes")
nodes_ui.template = "xray_nodes"

local subs_ui = s:taboption("subs", DummyValue, "_subs")
subs_ui.template = "xray_subs"

local rules_ui = s:taboption("rules", DummyValue, "_rules")
rules_ui.template = "xray_rules"

local conf = s:taboption("config", TextValue, "_conf")
conf.wrap = "off"
conf.rows = 30
conf.description = "Direct editor for /etc/xray/config.json"
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

echo "===> Creating /usr/lib/lua/luci/view/xray_service_extra.htm..."
cat << 'EOF' > /usr/lib/lua/luci/view/xray_service_extra.htm
<style>
    .xr-geo-split {
        display: grid;
        grid-template-columns: 1fr 1fr;
        gap: 16px;
        margin-top: 12px;
        margin-bottom: 16px;
    }
    @media (max-width: 820px) {
        .xr-geo-split { grid-template-columns: 1fr; }
    }
    .xr-geo-split > .xr-card {
        margin-bottom: 0;
        display: flex;
        flex-direction: column;
    }
    .xr-geo-table-wrap {
        max-height: 220px;
        overflow-y: auto;
        margin-top: 8px;
    }
    .xr-cron-row {
        display: grid;
        grid-template-columns: 26px 1fr 200px 150px 36px;
        gap: 8px;
        align-items: center;
        margin-bottom: 8px;
    }
    @media (max-width: 820px) {
        .xr-cron-row { grid-template-columns: 26px 1fr; }
    }
    .xr-cron-row input[type="text"],
    .xr-cron-row select {
        width: 100%;
        box-sizing: border-box;
    }
    .xr-cron-disabled {
        opacity: 0.5;
    }
    .xr-limits-row {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
        gap: 12px;
        align-items: end;
    }
</style>

<!-- 1. Geofiles: two equal boxes -->
<div class="xr-geo-split">
    <div class="cbi-section xr-card">
        <div style="display:flex; justify-content:space-between; align-items:center; gap:8px; margin-bottom:6px;">
            <strong style="font-size:0.95em;">Geofiles (.dat)</strong>
            <code id="xr-geo-dir-label" style="font-size:0.86em;">/usr/bin/</code>
        </div>
        <div class="xr-geo-table-wrap">
            <table class="table cbi-section-table" style="width:100%; margin-bottom:0;">
                <tr class="tr cbi-section-table-titles">
                    <th class="th">Filename</th>
                    <th class="th" style="width:24%; text-align:right;">Size</th>
                    <th class="th" style="width:32%; text-align:right;">Modified</th>
                </tr>
                <tbody id="xr-geo-files-body">
                    <tr class="tr"><td class="td" colspan="3"><em>Loading...</em></td></tr>
                </tbody>
            </table>
        </div>
    </div>

    <div class="cbi-section xr-card">
        <strong style="font-size:0.95em; margin-bottom:10px; display:block;">Download Geofile</strong>
        <div class="xr-field" style="margin-bottom:10px;">
            <label>File URL</label>
            <input type="text" id="xr-geo-dl-url" class="cbi-input-text" placeholder="https://github.com/.../releases/latest/download/geosite.dat">
        </div>
        <div class="xr-field" style="margin-bottom:12px;">
            <label>Filename</label>
            <input type="text" id="xr-geo-dl-name" class="cbi-input-text" placeholder="geosite.dat">
        </div>
        <div style="display:flex; gap:10px; align-items:center; flex-wrap:wrap; margin-top:auto;">
            <button type="button" id="xr-geo-dl-btn" class="cbi-button cbi-button-apply" onclick="xrDownloadGeofile()">Download</button>
            <span id="xr-geo-dl-status" style="font-size:0.86em;"></span>
        </div>
    </div>
</div>

<!-- 2. Horizontal Auto-update & Runtime Limits section -->
<div class="cbi-section xr-card">
    <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px; margin-bottom:10px;">
        <label style="display:inline-flex; align-items:center; gap:8px; cursor:pointer; font-weight:600; font-size:0.95em; margin:0;">
            <input type="checkbox" id="xr-cron-geo-master" onchange="xrToggleGeoCronMaster(this.checked)">
            Geofile Auto-Update (Cron)
        </label>
        <button type="button" id="xr-cron-geo-add" class="cbi-button cbi-button-add" onclick="xrAddGeoCronRow()">+ Add Geofile</button>
    </div>

    <div id="xr-cron-geo-rows"></div>

    <hr style="border:none; border-top:1px solid rgba(255,255,255,0.1); margin:16px 0 14px 0;">

    <strong style="font-size:0.95em; display:block; margin-bottom:10px;">Xray Service Schedule &amp; Runtime Limits</strong>

    <div style="display:flex; flex-wrap:wrap; gap:12px; align-items:center; margin-bottom:14px;">
        <label style="display:inline-flex; align-items:center; gap:8px; cursor:pointer; margin:0;">
            <input type="checkbox" id="xr-cron-restart-en" onchange="xrToggleRestartCron(this.checked)">
            Auto-Restart Xray (Cron)
        </label>
        <select id="xr-cron-restart-int" class="cbi-input-select" style="width:180px;">
            <option value="1h">Every 1 hour</option>
            <option value="3h">Every 3 hours</option>
            <option value="6h">Every 6 hours</option>
            <option value="12h">Every 12 hours</option>
            <option value="1d" selected>Every 1 day</option>
            <option value="3d">Every 3 days</option>
            <option value="7d">Every 7 days</option>
            <option value="14d">Every 14 days</option>
            <option value="30d">Every 30 days</option>
        </select>
        <button type="button" id="xr-cron-save-btn" class="cbi-button cbi-button-save" onclick="xrSaveCronSettings()">Save Schedule</button>
        <span id="xr-cron-status" style="font-size:0.86em;"></span>
    </div>

    <hr style="border:none; border-top:1px dashed rgba(255,255,255,0.1); margin:14px 0;">

    <div class="xr-limits-row">
        <div class="xr-field">
            <label>GOMEMLIMIT</label>
            <input type="text" id="xr-lim-mem" class="cbi-input-text" placeholder="65MiB">
        </div>
        <div class="xr-field">
            <label>GOGC</label>
            <input type="text" id="xr-lim-gc" class="cbi-input-text" placeholder="40">
        </div>
        <div style="display:flex; gap:10px; align-items:center;">
            <button type="button" id="xr-lim-save-btn" class="cbi-button cbi-button-save" onclick="xrSaveLimits()">Save Limits</button>
            <span id="xr-lim-status" style="font-size:0.86em;"></span>
        </div>
    </div>
</div>

<script>
(function() {
    let cronState = {
        geo_enabled: false,
        geofiles: [
            { enabled: false, url: '', filename: 'geosite.dat', interval: '7d' },
            { enabled: false, url: '', filename: 'geoip.dat', interval: '7d' }
        ],
        restart_enabled: false,
        restart_interval: '1d'
    };

    const INTERVAL_OPTIONS = [
        ['1h',  'Every 1 hour'],
        ['3h',  'Every 3 hours'],
        ['6h',  'Every 6 hours'],
        ['12h', 'Every 12 hours'],
        ['1d',  'Every 1 day'],
        ['3d',  'Every 3 days'],
        ['7d',  'Every 7 days'],
        ['14d', 'Every 14 days'],
        ['30d', 'Every 30 days']
    ];

    function xrEsc(s) {
        if (!s) return '';
        return String(s).replace(/[&<>"']/g, function(m) {
            return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[m];
        });
    }

    function fmtSize(bytes) {
        const b = Number(bytes) || 0;
        if (b >= 1048576) return (b / 1048576).toFixed(2) + ' MB';
        if (b >= 1024) return (b / 1024).toFixed(1) + ' KB';
        return b + ' B';
    }

    function fmtMtime(ts) {
        if (!ts) return '-';
        const d = new Date(ts * 1000);
        const pad = n => String(n).padStart(2, '0');
        return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
    }

    function renderGeoFiles(dir, files) {
        const lbl = document.getElementById('xr-geo-dir-label');
        const tbody = document.getElementById('xr-geo-files-body');
        if (lbl && dir) lbl.textContent = dir;
        if (!tbody) return;
        tbody.innerHTML = '';
        if (!Array.isArray(files) || files.length === 0) {
            tbody.innerHTML = '<tr class="tr"><td class="td" colspan="3"><em>No .dat files found in directory.</em></td></tr>';
            return;
        }
        files.forEach(f => {
            const tr = document.createElement('tr');
            tr.className = 'tr cbi-section-table-row';
            tr.innerHTML = `
                <td class="td"><code>${xrEsc(f.name)}</code></td>
                <td class="td" style="text-align:right; white-space:nowrap;">${xrEsc(fmtSize(f.size))}</td>
                <td class="td" style="text-align:right; white-space:nowrap; opacity:0.8;">${xrEsc(fmtMtime(f.mtime))}</td>
            `;
            tbody.appendChild(tr);
        });
    }

    function loadGeoFiles() {
        fetch('<%=url("admin/services/xray/geo_list")%>')
            .then(r => r.json())
            .then(data => renderGeoFiles(data.dir, data.files))
            .catch(() => renderGeoFiles('/usr/bin/', []));
    }

    window.xrDownloadGeofile = function() {
        const urlEl = document.getElementById('xr-geo-dl-url');
        const nameEl = document.getElementById('xr-geo-dl-name');
        const btn = document.getElementById('xr-geo-dl-btn');
        const st = document.getElementById('xr-geo-dl-status');

        const url = urlEl ? urlEl.value.trim() : '';
        const filename = nameEl ? nameEl.value.trim() : '';

        if (!url || !filename) {
            if (st) { st.style.color = '#ef5350'; st.textContent = 'Enter both URL and filename.'; }
            return;
        }

        if (btn) { btn.disabled = true; btn.textContent = 'Downloading...'; }
        if (st) { st.style.color = '#4fc3f7'; st.textContent = 'Running wget...'; }

        fetch('<%=url("admin/services/xray/geo_download")%>', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ url: url, filename: filename })
        }).then(r => r.json()).then(res => {
            if (res && res.files) renderGeoFiles(res.dir, res.files);
            if (res && res.success) {
                if (st) { st.style.color = '#66bb6a'; st.textContent = 'Downloaded: ' + filename; }
            } else {
                if (st) { st.style.color = '#ef5350'; st.textContent = (res && res.error) ? res.error : 'Download failed'; }
            }
        }).catch(err => {
            if (st) { st.style.color = '#ef5350'; st.textContent = 'Request error: ' + err; }
        }).finally(() => {
            if (btn) { btn.disabled = false; btn.textContent = 'Download'; }
        });
    };

    function syncCronStateFromDOM() {
        const master = document.getElementById('xr-cron-geo-master');
        if (master) cronState.geo_enabled = master.checked;

        const rows = document.querySelectorAll('#xr-cron-geo-rows .xr-cron-row');
        const list = [];
        rows.forEach(row => {
            list.push({
                enabled: row.querySelector('.xr-cg-en').checked,
                url: row.querySelector('.xr-cg-url').value.trim(),
                filename: row.querySelector('.xr-cg-name').value.trim(),
                interval: row.querySelector('.xr-cg-int').value
            });
        });
        cronState.geofiles = list;

        const rEn = document.getElementById('xr-cron-restart-en');
        const rInt = document.getElementById('xr-cron-restart-int');
        if (rEn) cronState.restart_enabled = rEn.checked;
        if (rInt) cronState.restart_interval = rInt.value;
    }

    function renderCronUI() {
        const master = document.getElementById('xr-cron-geo-master');
        const addBtn = document.getElementById('xr-cron-geo-add');
        const cont = document.getElementById('xr-cron-geo-rows');
        const enabledMaster = !!cronState.geo_enabled;

        if (master) master.checked = enabledMaster;
        if (addBtn) addBtn.disabled = !enabledMaster;
        if (!cont) return;

        cont.innerHTML = '';
        if (!Array.isArray(cronState.geofiles) || cronState.geofiles.length === 0) {
            cronState.geofiles = [{ enabled: false, url: '', filename: 'geosite.dat', interval: '7d' }];
        }

        cronState.geofiles.forEach((g, idx) => {
            const row = document.createElement('div');
            row.className = 'xr-cron-row' + (enabledMaster ? '' : ' xr-cron-disabled');
            const optsHtml = INTERVAL_OPTIONS.map(o =>
                `<option value="${o[0]}" ${g.interval === o[0] ? 'selected' : ''}>${o[1]}</option>`
            ).join('');

            row.innerHTML = `
                <input type="checkbox" class="xr-cg-en" ${g.enabled ? 'checked' : ''} ${enabledMaster ? '' : 'disabled'}>
                <input type="text" class="cbi-input-text xr-cg-url" value="${xrEsc(g.url || '')}" placeholder="https://.../geosite.dat" ${enabledMaster ? '' : 'disabled'}>
                <input type="text" class="cbi-input-text xr-cg-name" value="${xrEsc(g.filename || '')}" placeholder="geosite.dat" ${enabledMaster ? '' : 'disabled'}>
                <select class="cbi-input-select xr-cg-int" ${enabledMaster ? '' : 'disabled'}>${optsHtml}</select>
                <button type="button" class="cbi-button cbi-button-remove xr-cg-del" title="Remove row" ${enabledMaster ? '' : 'disabled'}>&times;</button>
            `;
            row.querySelector('.xr-cg-del').addEventListener('click', () => {
                syncCronStateFromDOM();
                cronState.geofiles.splice(idx, 1);
                renderCronUI();
            });
            cont.appendChild(row);
        });

        const rEn = document.getElementById('xr-cron-restart-en');
        const rInt = document.getElementById('xr-cron-restart-int');
        if (rEn) rEn.checked = !!cronState.restart_enabled;
        if (rInt) {
            rInt.value = cronState.restart_interval || '1d';
            rInt.disabled = !cronState.restart_enabled;
        }
    }

    window.xrToggleGeoCronMaster = function(checked) {
        syncCronStateFromDOM();
        cronState.geo_enabled = !!checked;
        renderCronUI();
    };

    window.xrAddGeoCronRow = function() {
        syncCronStateFromDOM();
        cronState.geofiles.push({ enabled: true, url: '', filename: '', interval: '7d' });
        renderCronUI();
    };

    window.xrToggleRestartCron = function(checked) {
        const rInt = document.getElementById('xr-cron-restart-int');
        cronState.restart_enabled = !!checked;
        if (rInt) rInt.disabled = !checked;
    };

    window.xrSaveCronSettings = function() {
        syncCronStateFromDOM();
        const btn = document.getElementById('xr-cron-save-btn');
        const st = document.getElementById('xr-cron-status');
        if (btn) btn.disabled = true;
        if (st) { st.style.color = '#4fc3f7'; st.textContent = 'Applying crontab...'; }

        fetch('<%=url("admin/services/xray/service_ext")%>', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ section: 'cron', cron: cronState })
        }).then(r => r.json()).then(res => {
            if (res && res.success) {
                if (st) { st.style.color = '#66bb6a'; st.textContent = `Saved (${res.jobs || 0} active cron jobs)`; }
            } else {
                if (st) { st.style.color = '#ef5350'; st.textContent = (res && res.error) ? res.error : 'Save failed'; }
            }
        }).catch(err => {
            if (st) { st.style.color = '#ef5350'; st.textContent = 'Request error: ' + err; }
        }).finally(() => {
            if (btn) btn.disabled = false;
        });
    };

    window.xrSaveLimits = function() {
        const memEl = document.getElementById('xr-lim-mem');
        const gcEl = document.getElementById('xr-lim-gc');
        const btn = document.getElementById('xr-lim-save-btn');
        const st = document.getElementById('xr-lim-status');

        const gomemlimit = memEl ? memEl.value.trim() : '';
        const gogc = gcEl ? gcEl.value.trim() : '';

        if (btn) btn.disabled = true;
        if (st) { st.style.color = '#4fc3f7'; st.textContent = 'Saving...'; }

        fetch('<%=url("admin/services/xray/service_ext")%>', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ section: 'limits', limits: { gomemlimit: gomemlimit, gogc: gogc } })
        }).then(r => r.json()).then(res => {
            if (res && res.success) {
                if (res.service && typeof updateServiceUI === 'function') updateServiceUI(res.service);
                if (st) {
                    st.style.color = '#66bb6a';
                    st.textContent = res.restarted ? 'Saved & Xray restarted' : 'Saved';
                }
            } else {
                if (st) { st.style.color = '#ef5350'; st.textContent = (res && res.error) ? res.error : 'Save failed'; }
            }
        }).catch(err => {
            if (st) { st.style.color = '#ef5350'; st.textContent = 'Request error: ' + err; }
        }).finally(() => {
            if (btn) btn.disabled = false;
        });
    };

    function loadServiceExt() {
        fetch('<%=url("admin/services/xray/service_ext")%>')
            .then(r => r.json())
            .then(data => {
                if (data && data.cron) cronState = data.cron;
                renderCronUI();
                if (data && data.limits) {
                    const memEl = document.getElementById('xr-lim-mem');
                    const gcEl = document.getElementById('xr-lim-gc');
                    if (memEl) memEl.value = data.limits.gomemlimit || '65MiB';
                    if (gcEl) gcEl.value = data.limits.gogc || '40';
                }
            })
            .catch(() => renderCronUI());
    }

    document.addEventListener('DOMContentLoaded', function() {
        loadGeoFiles();
        loadServiceExt();
    });
})();
</script>
EOF

#!/bin/sh
set -e

echo "===> Patching /usr/libexec/xray-ui-core.lua (line 337 + domainStrategy)..."
cp /usr/libexec/xray-ui-core.lua /tmp/xray-ui-core.lua.bak
lua -e '
local fs = require "nixio.fs"
local path = "/usr/libexec/xray-ui-core.lua"
local src = fs.readfile(path)
assert(src, "cannot read " .. path)

-- 1. Фикс строки 337 (tonumber + gsub)
src = src:gsub("tonumber%(sec_str:gsub%(\",\", \"%%.\"%)%)", "tonumber((sec_str:gsub(\",\", \".\")))")

-- 2. Поддержка глобального routing.domainStrategy из вкладки Rules
if not src:find("db.routing_settings", 1, true) then
    local anchor = "base.routing = { domainStrategy = \"IPIfNonMatch\", rules = {} }\n    end"
    local s, e = src:find(anchor, 1, true)
    assert(s, "anchor for base.routing not found in xray-ui-core.lua")
    local inject = anchor .. [[

    if type(db.routing_settings) == "table" and type(db.routing_settings.domainStrategy) == "string" then
        local ds = db.routing_settings.domainStrategy
        if ds == "AsIs" or ds == "IPIfNonMatch" or ds == "IPOnDemand" then
            base.routing.domainStrategy = ds
        end
    end]]
    src = src:sub(1, s - 1) .. inject .. src:sub(e + 1)
end

fs.writefile(path, src)
assert(loadfile(path), "syntax check failed for " .. path)
' || {
    mv /tmp/xray-ui-core.lua.bak /usr/libexec/xray-ui-core.lua
    echo "===> Error patching xray-ui-core.lua, restored backup."
    exit 1
}
rm -f /tmp/xray-ui-core.lua.bak

echo "===> Updating /usr/lib/lua/luci/view/xray_status.htm..."
cat << 'EOF' > /usr/lib/lua/luci/view/xray_status.htm
<%
    local sys = require "luci.sys"
    local xray_ver = sys.exec("xray version 2>/dev/null | head -n1 | awk '{print $2}'"):gsub("%s+", "")
    if xray_ver == "" then xray_ver = "Unknown" end

    local pid = sys.exec("pidof xray"):gsub("%s+", "")
    local is_running = (pid ~= "")
    if not is_running then pid = "-" end

    local is_enabled = (sys.call("/etc/init.d/xray enabled >/dev/null 2>&1") == 0)
%>
<style>
    .xr-card {
        background: rgba(255, 255, 255, 0.03);
        border: 1px solid rgba(255, 255, 255, 0.12);
        border-radius: 6px;
        padding: 16px;
        margin-bottom: 16px;
    }
    .xr-status-line {
        display: flex;
        flex-wrap: wrap;
        gap: 18px;
        align-items: center;
        margin: 12px 0 18px 0;
        font-size: 1.02em;
    }
    .xr-badge {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        padding: 3px 10px;
        border-radius: 4px;
        font-weight: 600;
        font-size: 0.85em;
        letter-spacing: 0.4px;
    }
    .xr-badge-run { background: rgba(76, 175, 80, 0.18); color: #66bb6a; border: 1px solid rgba(76, 175, 80, 0.4); }
    .xr-badge-rule { background: rgba(79, 195, 247, 0.16); color: #4fc3f7; border: 1px solid rgba(79, 195, 247, 0.4); }
    .xr-badge-stop { background: rgba(244, 67, 54, 0.18); color: #ef5350; border: 1px solid rgba(244, 67, 54, 0.4); }
    .xr-badge-idle { background: rgba(158, 158, 158, 0.15); color: #9e9e9e; border: 1px solid rgba(158, 158, 158, 0.3); }
    .xr-controls { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
    .xr-input-row { display: flex; gap: 8px; margin-bottom: 14px; }
    .xr-input-row input { flex: 1; }
    .xr-sub-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
        gap: 10px;
        margin: 10px 0 14px 0;
    }
    .xr-field label { display: block; font-size: 0.8em; opacity: 0.75; margin-bottom: 3px; }
    .xr-field input, .xr-field select { width: 100%; box-sizing: border-box; }
    .xr-drag-handle {
        cursor: grab;
        user-select: none;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        padding: 4px 6px;
        opacity: 0.55;
        transition: opacity 0.15s;
    }
    .xr-drag-handle:hover { opacity: 1; }
    .xr-drag-handle:active { cursor: grabbing; }
    .xr-row-dragging { opacity: 0.35; }
    .xr-row-over-top td { border-top: 2px solid #4fc3f7 !important; }
    .xr-row-over-bottom td { border-bottom: 2px solid #4fc3f7 !important; }
    .xr-chip {
        display: inline-block;
        background: rgba(255, 255, 255, 0.06);
        border: 1px solid rgba(255, 255, 255, 0.14);
        border-radius: 4px;
        padding: 2px 7px;
        margin: 2px 4px 2px 0;
        font-size: 0.84em;
        font-family: monospace;
    }

    /* Ping buttons (fixed rectangle size + 3 blinking dots) */
    .xr-ping-btn {
        width: 78px !important;
        min-width: 78px !important;
        max-width: 78px !important;
        padding-left: 0 !important;
        padding-right: 0 !important;
        box-sizing: border-box !important;
        font-weight: 600 !important;
        display: inline-flex !important;
        align-items: center;
        justify-content: center;
        vertical-align: middle;
        transition: background 0.18s, border-color 0.18s, color 0.18s;
    }
    .xr-ping-all-btn {
        min-width: 82px !important;
        font-weight: 600 !important;
        display: inline-flex !important;
        align-items: center;
        justify-content: center;
        transition: background 0.18s, border-color 0.18s, color 0.18s;
    }
    .xr-ping-unpinged {
        background: rgba(0, 195, 255, 0.22) !important;
        color: #29d9ff !important;
        border: 1px solid #00c8ff !important;
    }
    .xr-ping-unpinged:hover {
        background: rgba(0, 195, 255, 0.36) !important;
    }
    .xr-ping-loading {
        background: rgba(0, 195, 255, 0.16) !important;
        color: #29d9ff !important;
        border: 1px solid #00c8ff !important;
        cursor: wait !important;
    }
    .xr-ping-good {
        background: rgba(0, 230, 118, 0.22) !important;
        color: #00e676 !important;
        border: 1px solid #00e676 !important;
    }
    .xr-ping-good:hover { background: rgba(0, 230, 118, 0.34) !important; }
    .xr-ping-mid {
        background: rgba(255, 234, 0, 0.22) !important;
        color: #ffea00 !important;
        border: 1px solid #ffd600 !important;
    }
    .xr-ping-mid:hover { background: rgba(255, 234, 0, 0.34) !important; }
    .xr-ping-slow {
        background: rgba(255, 145, 0, 0.24) !important;
        color: #ff9100 !important;
        border: 1px solid #ff9100 !important;
    }
    .xr-ping-slow:hover { background: rgba(255, 145, 0, 0.36) !important; }
    .xr-ping-fail {
        background: rgba(255, 23, 68, 0.22) !important;
        color: #ff5252 !important;
        border: 1px solid #ff1744 !important;
    }
    .xr-ping-fail:hover { background: rgba(255, 23, 68, 0.34) !important; }

    .xr-ping-dots {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        gap: 4px;
        height: 1.2em;
    }
    .xr-ping-dots span {
        width: 4px;
        height: 4px;
        border-radius: 50%;
        background: currentColor;
        opacity: 0.22;
        animation: xr-dot-seq 1.05s infinite ease-in-out;
    }
    .xr-ping-dots span:nth-child(2) { animation-delay: 0.22s; }
    .xr-ping-dots span:nth-child(3) { animation-delay: 0.44s; }
    @keyframes xr-dot-seq {
        0%, 80%, 100% { opacity: 0.22; }
        40% { opacity: 1; }
    }

    .xr-ping-opts {
        display: flex;
        flex-wrap: wrap;
        gap: 18px;
        align-items: center;
        margin-top: 8px;
    }
    .xr-ping-opts label {
        display: inline-flex;
        align-items: center;
        gap: 7px;
        cursor: pointer;
        font-size: 0.94em;
        user-select: none;
    }
    .xr-log-box {
        margin-top: 10px;
        background: rgba(0, 0, 0, 0.35);
        border: 1px solid rgba(255, 255, 255, 0.12);
        border-radius: 4px;
        padding: 10px;
        font-family: monospace;
        font-size: 0.82em;
        max-height: 220px;
        overflow-y: auto;
        white-space: pre-wrap;
        word-break: break-all;
        display: none;
    }

    /* Collapsible subscription header */
    .xr-sub-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        flex-wrap: wrap;
        gap: 8px;
        margin-bottom: 10px;
    }
    .xr-sub-toggle {
        display: inline-flex;
        align-items: center;
        gap: 8px;
        cursor: pointer;
        user-select: none;
        padding: 2px 4px;
        border-radius: 4px;
    }
    .xr-sub-toggle:hover {
        background: rgba(255, 255, 255, 0.05);
    }
    .xr-sub-arrow {
        display: inline-block;
        width: 14px;
        text-align: center;
        font-size: 0.9em;
        opacity: 0.8;
    }
    .xr-sub-settings-body {
        padding: 10px 12px;
        margin-bottom: 12px;
        border: 1px solid rgba(255, 255, 255, 0.08);
        border-radius: 4px;
        background: rgba(0, 0, 0, 0.14);
    }
</style>

<div class="cbi-section xr-card">
    <div style="display:flex; justify-content:space-between; align-items:flex-start; flex-wrap:wrap; gap:8px;">
        <h3 style="margin:0;">Xray-core <span style="opacity:0.65; font-weight:normal;">v<%=xray_ver%></span></h3>
        <div style="text-align:right; font-size:0.85em; line-height:1.55;">
            <div><a href="https://github.com/XTLS/Xray-core" target="_blank" rel="noreferrer">https://github.com/XTLS/Xray-core</a></div>
            <div><a href="https://github.com/fahrenheitd99/luci-app-xray-core" target="_blank" rel="noreferrer">https://github.com/fahrenheitd99/luci-app-xray-core</a></div>
        </div>
    </div>

    <div class="xr-status-line">
        <div>
            Status:
            <span id="xr-svc-badge" class="xr-badge <%=is_running and 'xr-badge-run' or 'xr-badge-stop'%>">
                <%=is_running and "RUNNING" or "STOPPED"%>
            </span>
        </div>
        <div>PID: <code id="xr-svc-pid"><%=pid%></code></div>
        <div>Active Outbounds: <strong id="xr-active-profile" style="color:#4fc3f7;">None (Direct)</strong></div>
    </div>

    <div class="xr-controls">
        <button type="button" id="btn-svc-start" class="cbi-button cbi-button-apply" onclick="xrayServiceCtl('start')" <%=is_running and 'disabled' or ''%>>Start</button>
        <button type="button" id="btn-svc-restart" class="cbi-button cbi-button-action" onclick="xrayServiceCtl('restart')" <%=not is_running and 'disabled' or ''%>>Restart</button>
        <button type="button" id="btn-svc-stop" class="cbi-button cbi-button-reset" onclick="xrayServiceCtl('stop')" <%=not is_running and 'disabled' or ''%>>Stop</button>
        <span style="opacity:0.3; margin:0 6px;">|</span>
        <button type="button" id="btn-svc-enable" class="cbi-button cbi-button-save" onclick="xrayServiceCtl('enable')" <%=is_enabled and 'disabled' or ''%>>Enable Autostart</button>
        <button type="button" id="btn-svc-disable" class="cbi-button cbi-button-reset" onclick="xrayServiceCtl('disable')" <%=not is_enabled and 'disabled' or ''%>>Disable Autostart</button>
    </div>

    <hr style="border:none; border-top:1px solid rgba(255,255,255,0.1); margin:16px 0 12px 0;">

    <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px;">
        <strong style="font-size:0.95em;">Ping Settings</strong>
        <div style="display:flex; gap:8px; align-items:center;">
            <span id="xr-ping-settings-status" style="font-size:0.84em;"></span>
            <button type="button" id="btn-toggle-ping-log" class="cbi-button cbi-button-action" onclick="togglePingLog()">Show Ping Log</button>
            <button type="button" class="cbi-button cbi-button-reset" onclick="clearPingLog()">Clear Log</button>
        </div>
    </div>
    <div class="xr-ping-opts">
        <label title="Direct TCP handshake latency">
            <input type="checkbox" id="chk-ping-tcp" onchange="setPingModeSetting('tcp')">
            TCP Ping
        </label>
        <label title="HTTP HEAD request through an isolated proxy instance">
            <input type="checkbox" id="chk-ping-head" checked onchange="setPingModeSetting('head')">
            Via Proxy (HTTP HEAD)
        </label>
        <span style="opacity:0.25;">|</span>
        <label title="Dynamically sort nodes from lowest to highest latency during Ping All">
            <input type="checkbox" id="chk-ping-autosort" onchange="setAutoSortSetting(this.checked)">
            Auto-sort nodes by ping (Ping All)
        </label>
    </div>
    <pre id="xr-ping-log-box" class="xr-log-box"></pre>
</div>
EOF

echo "===> Updating /usr/lib/lua/luci/view/xray_nodes.htm..."
cat << 'EOF' > /usr/lib/lua/luci/view/xray_nodes.htm
<div class="cbi-section xr-card" id="app-nodes">
    <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px; margin-bottom:12px;">
        <h3 style="margin:0;">Custom Nodes</h3>
        <div style="display:flex; gap:8px; align-items:center;">
            <button type="button" id="btn-ping-all-nodes" class="cbi-button xr-ping-all-btn xr-ping-unpinged" onclick="pingAllNodes()">Ping All</button>
            <button type="button" class="cbi-button cbi-button-action" onclick="sortNodesByPing()">Sort</button>
        </div>
    </div>
    <div class="xr-input-row">
        <input type="text" id="new-vless-link" class="cbi-input-text" placeholder="vless://, vmess://, trojan://, ss://, hysteria2://, socks://, http://, wireguard:// or JSON outbound" onkeydown="if(event.key==='Enter'){event.preventDefault();addNode();}">
        <button type="button" id="btn-add-node" class="cbi-button cbi-button-add" onclick="addNode()">Add Node</button>
    </div>
    <div id="node-status" style="font-size:0.88em; margin:-6px 0 12px 0; min-height:1.1em;"></div>

    <table class="table cbi-section-table">
        <tr class="tr cbi-section-table-titles">
            <th class="th" style="width:14%">Status</th>
            <th class="th" style="width:26%">Name (Tag)</th>
            <th class="th" style="width:23%">Endpoint</th>
            <th class="th" style="width:15%">Stack</th>
            <th class="th" style="width:22%; text-align:right;">Actions</th>
        </tr>
        <tbody id="nodes-table-body"></tbody>
    </table>
</div>

<script>
let db = {
    manual_nodes: [],
    managed_tags: [],
    settings: { ping_mode: 'head', auto_sort: false },
    routing_settings: { domainStrategy: 'IPIfNonMatch' },
    nodes: [],
    subs: [],
    rules: []
};

const pingObjMap = new WeakMap();
const pingKeyMap = new Map();
const pingJobs = {};

function escapeHtml(s) {
    if (!s) return '';
    return String(s).replace(/[&<>"']/g, function(m) {
        return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[m];
    });
}

function normalizeClientDB(data) {
    if (!data || typeof data !== 'object') data = {};
    if (!Array.isArray(data.nodes)) data.nodes = [];
    if (!Array.isArray(data.subs)) data.subs = [];
    if (!Array.isArray(data.rules)) data.rules = [];
    if (!Array.isArray(data.managed_tags)) data.managed_tags = [];
    if (!data.settings || typeof data.settings !== 'object') {
        data.settings = { ping_mode: 'head', auto_sort: false };
    }
    if (data.settings.ping_mode !== 'tcp' && data.settings.ping_mode !== 'head') {
        data.settings.ping_mode = 'head';
    }
    data.settings.auto_sort = !!data.settings.auto_sort;

    if (!data.routing_settings || typeof data.routing_settings !== 'object') {
        data.routing_settings = { domainStrategy: 'IPIfNonMatch' };
    }
    if (['AsIs', 'IPIfNonMatch', 'IPOnDemand'].indexOf(data.routing_settings.domainStrategy) === -1) {
        data.routing_settings.domainStrategy = 'IPIfNonMatch';
    }

    if (!Array.isArray(data.manual_nodes)) {
        data.manual_nodes = [];
        if (data.active_type === 'node' && data.nodes[data.active_index]) {
            data.manual_nodes.push(data.nodes[data.active_index].name);
        } else if (data.active_type === 'sub' && data.subs[data.active_sub_index]) {
            const sub = data.subs[data.active_sub_index];
            if (sub.nodes && sub.nodes[data.active_node_index]) {
                data.manual_nodes.push(sub.nodes[data.active_node_index].name);
            }
        }
    }
    return data;
}

function getPingKey(scope, node) {
    const meta = getOutboundMeta(node && node.outbound);
    return scope + '::' + (node && node.name ? node.name : '') + '::' + meta.endpoint;
}

function getPingState(scope, node) {
    if (!node) return null;
    if (pingObjMap.has(node)) return pingObjMap.get(node);
    const k = getPingKey(scope, node);
    return pingKeyMap.has(k) ? pingKeyMap.get(k) : null;
}

function setPingState(scope, node, st) {
    if (!node) return;
    pingObjMap.set(node, st);
    pingKeyMap.set(getPingKey(scope, node), st);
}

function clearScopePings(scope) {
    const prefix = scope + '::';
    for (const key of Array.from(pingKeyMap.keys())) {
        if (key.startsWith(prefix)) pingKeyMap.delete(key);
    }
}

function applyPingBtnStyle(btn, st) {
    if (!btn) return;
    btn.classList.remove('xr-ping-unpinged', 'xr-ping-loading', 'xr-ping-good', 'xr-ping-mid', 'xr-ping-slow', 'xr-ping-fail');
    if (!st || st.status === 'idle') {
        btn.classList.add('xr-ping-unpinged');
        btn.disabled = false;
        btn.textContent = 'Ping';
    } else if (st.status === 'loading') {
        btn.classList.add('xr-ping-loading');
        btn.disabled = true;
        btn.innerHTML = '<span class="xr-ping-dots"><span></span><span></span><span></span></span>';
    } else if (st.status === 'ok' && typeof st.ms === 'number') {
        btn.disabled = false;
        if (st.ms < 500) btn.classList.add('xr-ping-good');
        else if (st.ms < 1000) btn.classList.add('xr-ping-mid');
        else btn.classList.add('xr-ping-slow');
        btn.textContent = st.ms + ' ms';
    } else {
        btn.disabled = false;
        btn.classList.add('xr-ping-fail');
        btn.textContent = '-';
    }
}

function syncPingSettingsUI() {
    const chkTcp = document.getElementById('chk-ping-tcp');
    const chkHead = document.getElementById('chk-ping-head');
    const chkAuto = document.getElementById('chk-ping-autosort');
    const mode = (db.settings && db.settings.ping_mode) || 'head';
    if (chkTcp) chkTcp.checked = (mode === 'tcp');
    if (chkHead) chkHead.checked = (mode === 'head');
    if (chkAuto) chkAuto.checked = !!(db.settings && db.settings.auto_sort);
}

function refreshPingLog() {
    const box = document.getElementById('xr-ping-log-box');
    if (!box) return;
    fetch('<%=url("admin/services/xray/ping_log")%>')
        .then(r => r.text())
        .then(txt => {
            box.textContent = txt.trim() || '(Ping log is empty)';
            box.scrollTop = box.scrollHeight;
        });
}

function togglePingLog() {
    const box = document.getElementById('xr-ping-log-box');
    const btn = document.getElementById('btn-toggle-ping-log');
    if (!box) return;
    if (box.style.display === 'block') {
        box.style.display = 'none';
        if (btn) btn.textContent = 'Show Ping Log';
    } else {
        box.style.display = 'block';
        if (btn) btn.textContent = 'Hide Ping Log';
        refreshPingLog();
    }
}

function clearPingLog() {
    fetch('<%=url("admin/services/xray/ping_log")%>', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'clear=1'
    }).then(() => {
        const box = document.getElementById('xr-ping-log-box');
        if (box && box.style.display === 'block') box.textContent = '(Ping log is empty)';
    });
}

function saveSettingsSilent(msg) {
    const stEl = document.getElementById('xr-ping-settings-status');
    fetch('<%=url("admin/services/xray/api")%>?norestart=1', {
        method: 'POST',
        body: JSON.stringify(db)
    }).then(() => {
        if (stEl && msg) {
            stEl.style.color = '#66bb6a';
            stEl.textContent = msg;
            setTimeout(() => { if (stEl.textContent === msg) stEl.textContent = ''; }, 2000);
        }
    });
}

function setPingModeSetting(mode) {
    if (!db.settings) db.settings = {};
    db.settings.ping_mode = (mode === 'head') ? 'head' : 'tcp';
    syncPingSettingsUI();
    saveSettingsSilent(db.settings.ping_mode === 'head' ? 'Mode: Via Proxy (HEAD)' : 'Mode: TCP Ping');
}

function setAutoSortSetting(checked) {
    if (!db.settings) db.settings = {};
    db.settings.auto_sort = !!checked;
    syncPingSettingsUI();
    saveSettingsSilent(db.settings.auto_sort ? 'Auto-sort enabled' : 'Auto-sort disabled');
}

async function requestNodePing(node) {
    const mode = (db.settings && db.settings.ping_mode === 'head') ? 'head' : 'tcp';
    try {
        const resp = await fetch('<%=url("admin/services/xray/ping")%>', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ mode: mode, name: node.name || '', outbound: node.outbound })
        });
        const data = await resp.json();
        const box = document.getElementById('xr-ping-log-box');
        if (box && box.style.display === 'block') refreshPingLog();
        if (data && data.success && typeof data.ms === 'number' && data.ms >= 0) {
            return { status: 'ok', ms: data.ms };
        }
        return { status: 'fail', ms: null };
    } catch (e) {
        return { status: 'fail', ms: null };
    }
}

async function pingSingleNode(scope, node, btn) {
    const cur = getPingState(scope, node);
    if (cur && cur.status === 'loading') return;
    setPingState(scope, node, { status: 'loading', ms: null });
    applyPingBtnStyle(btn, { status: 'loading', ms: null });
    const res = await requestNodePing(node);
    setPingState(scope, node, res);
    applyPingBtnStyle(btn, res);
}

function getPingSortRank(scope, node) {
    const st = getPingState(scope, node);
    if (st && st.status === 'ok' && typeof st.ms === 'number') return { grp: 0, val: st.ms };
    if (st && st.status === 'fail') return { grp: 2, val: 9999999 };
    return { grp: 1, val: 9999999 };
}

function sortListAndAnimateTbody(list, tbody, scope, persistToDisk) {
    if (!Array.isArray(list) || list.length < 2) return;
    const rows = tbody ? Array.from(tbody.querySelectorAll('tr')) : [];
    const rowByNode = new Map();
    const firstTops = new Map();
    rows.forEach(tr => {
        if (tr._nodeRef) {
            rowByNode.set(tr._nodeRef, tr);
            firstTops.set(tr, tr.getBoundingClientRect().top);
        }
    });

    const decorated = list.map((n, i) => ({ node: n, idx: i, rank: getPingSortRank(scope, n) }));
    decorated.sort((a, b) => {
        if (a.rank.grp !== b.rank.grp) return a.rank.grp - b.rank.grp;
        if (a.rank.val !== b.rank.val) return a.rank.val - b.rank.val;
        return a.idx - b.idx;
    });

    for (let i = 0; i < decorated.length; i++) {
        list[i] = decorated[i].node;
    }

    if (tbody) {
        list.forEach(n => {
            const tr = rowByNode.get(n);
            if (tr) tbody.appendChild(tr);
        });
        list.forEach(n => {
            const tr = rowByNode.get(n);
            if (!tr) return;
            const prevTop = firstTops.get(tr);
            const newTop = tr.getBoundingClientRect().top;
            const dy = prevTop - newTop;
            if (Math.abs(dy) > 1) {
                tr.style.transition = 'none';
                tr.style.transform = `translateY(${dy}px)`;
                tr.offsetHeight;
                tr.style.transition = 'transform 220ms cubic-bezier(0.22, 1, 0.36, 1)';
                tr.style.transform = '';
            }
        });
    }

    if (persistToDisk) {
        fetch('<%=url("admin/services/xray/api")%>?norestart=1', {
            method: 'POST',
            body: JSON.stringify(db)
        }).catch(() => {});
    }
}

async function runPingAllBatch(scope, list, tbodyId, allBtn) {
    if (pingJobs[scope] && pingJobs[scope].running) {
        pingJobs[scope].cancelled = true;
        return;
    }
    if (!Array.isArray(list) || list.length === 0) return;

    const snapshot = list.slice();
    const job = {
        running: true,
        cancelled: false,
        liveSort: !!(db.settings && db.settings.auto_sort)
    };
    pingJobs[scope] = job;

    const origText = 'Ping All';
    let doneCount = 0;
    const total = snapshot.length;
    if (allBtn) allBtn.textContent = `Stop (0/${total})`;

    const getBtnForNode = (n) => {
        const tb = document.getElementById(tbodyId);
        if (!tb) return null;
        const rows = tb.querySelectorAll('tr');
        for (let i = 0; i < rows.length; i++) {
            if (rows[i]._nodeRef === n) return rows[i]._pingBtn || null;
        }
        return null;
    };

    snapshot.forEach(n => {
        setPingState(scope, n, { status: 'loading', ms: null });
        applyPingBtnStyle(getBtnForNode(n), { status: 'loading', ms: null });
    });

    const mode = (db.settings && db.settings.ping_mode === 'head') ? 'head' : 'tcp';
    const concurrency = (mode === 'head') ? 2 : 5;
    let cursor = 0;

    async function worker() {
        while (cursor < snapshot.length && !job.cancelled) {
            const node = snapshot[cursor++];
            const res = await requestNodePing(node);
            if (job.cancelled) {
                setPingState(scope, node, { status: 'idle', ms: null });
                applyPingBtnStyle(getBtnForNode(node), { status: 'idle', ms: null });
                break;
            }
            setPingState(scope, node, res);
            applyPingBtnStyle(getBtnForNode(node), res);
            doneCount++;
            if (allBtn) allBtn.textContent = `Stop (${doneCount}/${total})`;

            if (job.liveSort || (db.settings && db.settings.auto_sort)) {
                job.liveSort = true;
                sortListAndAnimateTbody(list, document.getElementById(tbodyId), scope, false);
            }
        }
    }

    const workers = [];
    for (let w = 0; w < Math.min(concurrency, snapshot.length); w++) {
        workers.push(worker());
    }
    await Promise.all(workers);

    if (job.cancelled) {
        snapshot.forEach(n => {
            const st = getPingState(scope, n);
            if (st && st.status === 'loading') {
                setPingState(scope, n, { status: 'idle', ms: null });
                applyPingBtnStyle(getBtnForNode(n), { status: 'idle', ms: null });
            }
        });
    }

    const shouldPersist = job.liveSort && !job.cancelled;
    job.running = false;
    delete pingJobs[scope];

    if (allBtn) allBtn.textContent = origText;
    if (shouldPersist) {
        sortListAndAnimateTbody(list, document.getElementById(tbodyId), scope, true);
    }
}

function pingAllNodes() {
    const btn = document.getElementById('btn-ping-all-nodes');
    runPingAllBatch('nodes', db.nodes, 'nodes-table-body', btn);
}

function sortNodesByPing() {
    const job = pingJobs['nodes'];
    if (job && job.running) {
        job.liveSort = true;
        sortListAndAnimateTbody(db.nodes, document.getElementById('nodes-table-body'), 'nodes', false);
    } else {
        sortListAndAnimateTbody(db.nodes, document.getElementById('nodes-table-body'), 'nodes', true);
    }
}

function isManualActive(name) {
    return Array.isArray(db.manual_nodes) && db.manual_nodes.indexOf(name) !== -1;
}

function isRuleActive(name) {
    if (!name || !Array.isArray(db.rules)) return false;
    return db.rules.some(r => r && r.outbound === name);
}

function getAllActiveNames() {
    const seen = new Set();
    const list = [];
    if (Array.isArray(db.manual_nodes)) {
        db.manual_nodes.forEach(n => {
            if (n && n !== 'direct' && n !== 'block' && !seen.has(n)) {
                seen.add(n);
                list.push(n);
            }
        });
    }
    if (Array.isArray(db.rules)) {
        db.rules.forEach(r => {
            const n = r && r.outbound;
            if (n && n !== 'direct' && n !== 'block' && !seen.has(n)) {
                seen.add(n);
                list.push(n);
            }
        });
    }
    return list;
}

function setNodeStatus(text, isError) {
    const el = document.getElementById('node-status');
    if (!el) return;
    el.style.color = isError ? '#ef5350' : '#66bb6a';
    el.innerText = text || '';
}

function updateConfigTextarea(cfgText) {
    if (typeof cfgText !== 'string') return;
    const ta = document.getElementById('cbid.xray_ui.main._conf');
    if (ta) ta.value = cfgText;
}

function updateServiceUI(svc) {
    if (!svc) return;
    const badge = document.getElementById('xr-svc-badge');
    const pidEl = document.getElementById('xr-svc-pid');
    if (badge) {
        badge.className = 'xr-badge ' + (svc.running ? 'xr-badge-run' : 'xr-badge-stop');
        badge.innerText = svc.running ? 'RUNNING' : 'STOPPED';
    }
    if (pidEl) pidEl.innerText = svc.pid || '-';

    const bStart = document.getElementById('btn-svc-start');
    const bRestart = document.getElementById('btn-svc-restart');
    const bStop = document.getElementById('btn-svc-stop');
    const bEnable = document.getElementById('btn-svc-enable');
    const bDisable = document.getElementById('btn-svc-disable');

    if (bStart) bStart.disabled = !!svc.running;
    if (bRestart) bRestart.disabled = !svc.running;
    if (bStop) bStop.disabled = !svc.running;
    if (bEnable) bEnable.disabled = !!svc.enabled;
    if (bDisable) bDisable.disabled = !svc.enabled;
}

function updateActiveProfileLabel() {
    const el = document.getElementById('xr-active-profile');
    if (!el) return;
    const active = getAllActiveNames();
    el.innerText = active.length > 0 ? active.join(', ') : 'None (Direct)';
}

function xrayServiceCtl(action) {
    fetch('<%=url("admin/services/xray/service_ctl")%>', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'action=' + encodeURIComponent(action)
    }).then(r => r.json()).then(svc => {
        updateServiceUI(svc);
    });
}

function syncConfigAndStatus() {
    fetch('<%=url("admin/services/xray/get_config")%>')
        .then(r => r.json())
        .then(res => {
            if (res.service) updateServiceUI(res.service);
            if (res.config) updateConfigTextarea(res.config);
        });
}

function getOutboundMeta(ob) {
    if (!ob) return { endpoint: '-', stack: '-' };
    let endpoint = '-';
    if (ob.settings && ob.settings.vnext && ob.settings.vnext[0]) {
        endpoint = ob.settings.vnext[0].address + ':' + ob.settings.vnext[0].port;
    } else if (ob.settings && ob.settings.servers && ob.settings.servers[0]) {
        endpoint = ob.settings.servers[0].address + ':' + ob.settings.servers[0].port;
    } else if (ob.settings && ob.settings.address && ob.settings.port) {
        endpoint = ob.settings.address + ':' + ob.settings.port;
    } else if (ob.settings && ob.settings.peers && ob.settings.peers[0] && ob.settings.peers[0].endpoint) {
        endpoint = ob.settings.peers[0].endpoint;
    }
    const proto = ob.protocol || 'unknown';
    const net = (ob.streamSettings && ob.streamSettings.network) || (proto === 'wireguard' ? 'udp' : 'tcp');
    const sec = (ob.streamSettings && ob.streamSettings.security) || 'none';
    return { endpoint: endpoint, stack: proto + ' / ' + net + ' / ' + sec };
}

function renderAllViews() {
    syncPingSettingsUI();
    updateActiveProfileLabel();
    renderNodes();
    if (typeof renderSubs === 'function') renderSubs();
    if (typeof renderRules === 'function') renderRules();
}

function loadDB(callback) {
    fetch('<%=url("admin/services/xray/api")%>')
        .then(r => r.json())
        .then(data => {
            db = normalizeClientDB(data);
            renderAllViews();
            syncConfigAndStatus();
            if (callback) callback();
        });
}

function saveDB(callback) {
    fetch('<%=url("admin/services/xray/api")%>', {
        method: 'POST',
        body: JSON.stringify(db)
    }).then(r => r.json()).then(res => {
        if (res && res.service) updateServiceUI(res.service);
        if (res && res.config) updateConfigTextarea(res.config);
        renderAllViews();
        if (callback) callback();
    });
}

function renderNodes() {
    const tbody = document.getElementById('nodes-table-body');
    if (!tbody) return;
    tbody.innerHTML = '';

    if (!db.nodes || db.nodes.length === 0) {
        tbody.innerHTML = '<tr class="tr"><td class="td" colspan="5"><em>No nodes added yet.</em></td></tr>';
        return;
    }

    db.nodes.forEach((n) => {
        const manual = isManualActive(n.name);
        const byRule = isRuleActive(n.name);
        const active = manual || byRule;
        const badgeClass = manual ? 'xr-badge-run' : (byRule ? 'xr-badge-rule' : 'xr-badge-idle');
        const badgeText = manual ? 'ACTIVE' : (byRule ? 'ACTIVE (RULE)' : 'IDLE');
        const btnClass = active ? 'cbi-button-reset' : 'cbi-button-apply';
        const btnText = active ? 'Stop' : 'Start';
        const meta = getOutboundMeta(n.outbound);

        const tr = document.createElement('tr');
        tr.className = 'tr cbi-section-table-row';
        tr._nodeRef = n;
        tr.innerHTML = `
            <td class="td"><span class="xr-badge ${badgeClass}">${badgeText}</span></td>
            <td class="td"><strong>${escapeHtml(n.name || 'Unnamed')}</strong></td>
            <td class="td"><code>${escapeHtml(meta.endpoint)}</code></td>
            <td class="td"><span style="font-size:0.88em; opacity:0.85;">${escapeHtml(meta.stack)}</span></td>
            <td class="td" style="text-align:right; white-space:nowrap;">
                <button type="button" class="cbi-button xr-ping-btn"></button>
                <button type="button" class="cbi-button ${btnClass} xr-btn-toggle">${btnText}</button>
                <button type="button" class="cbi-button cbi-button-remove xr-btn-del">Delete</button>
            </td>
        `;

        const pingBtn = tr.querySelector('.xr-ping-btn');
        tr._pingBtn = pingBtn;
        applyPingBtnStyle(pingBtn, getPingState('nodes', n));
        pingBtn.addEventListener('click', () => pingSingleNode('nodes', n, pingBtn));

        tr.querySelector('.xr-btn-toggle').addEventListener('click', () => {
            const idx = db.nodes.indexOf(n);
            if (idx !== -1) toggleNode(idx);
        });
        tr.querySelector('.xr-btn-del').addEventListener('click', () => {
            const idx = db.nodes.indexOf(n);
            if (idx !== -1) deleteNode(idx);
        });

        tbody.appendChild(tr);
    });
}

function addNode() {
    const input = document.getElementById('new-vless-link');
    const btn = document.getElementById('btn-add-node');
    const link = input ? input.value.trim() : '';
    if (!link) {
        setNodeStatus('Paste a proxy link or JSON outbound.', true);
        if (input) input.focus();
        return;
    }

    if (btn) {
        btn.disabled = true;
        btn.innerText = 'Adding...';
    }
    setNodeStatus('Parsing link...', false);

    fetch('<%=url("admin/services/xray/add_node")%>', {
        method: 'POST',
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'link=' + encodeURIComponent(link)
    }).then(r => r.json()).then(res => {
        if (res && res.success) {
            if (input) input.value = '';
            loadDB(() => setNodeStatus(`Added: ${res.name || 'Node'} (${res.protocol || 'ok'})`, false));
        } else {
            setNodeStatus((res && res.error) ? res.error : 'Invalid link', true);
        }
    }).catch(err => {
        setNodeStatus('Request error: ' + err, true);
    }).finally(() => {
        if (btn) {
            btn.disabled = false;
            btn.innerText = 'Add Node';
        }
    });
}

function toggleNode(idx) {
    const node = db.nodes[idx];
    if (!node) return;
    const name = node.name;
    const pos = db.manual_nodes.indexOf(name);
    if (pos !== -1) {
        db.manual_nodes.splice(pos, 1);
        saveDB(() => setNodeStatus(isRuleActive(name) ? `Removed from default (still active via Rules): ${name}` : `Stopped: ${name}`, false));
    } else if (isRuleActive(name)) {
        setNodeStatus(`"${name}" is active via Rules tab — remove it from Rules to stop.`, true);
    } else {
        db.manual_nodes.push(name);
        saveDB(() => setNodeStatus(`Started: ${name}`, false));
    }
}

function deleteNode(idx) {
    const node = db.nodes[idx];
    if (!node) return;
    if (isRuleActive(node.name)) {
        setNodeStatus(`Cannot delete "${node.name}" while it is used in Rules tab.`, true);
        return;
    }
    const pos = db.manual_nodes.indexOf(node.name);
    const wasActive = (pos !== -1);
    if (wasActive) db.manual_nodes.splice(pos, 1);
    db.nodes.splice(idx, 1);

    if (wasActive) {
        saveDB(() => setNodeStatus(`Removed active node: ${node.name}`, false));
    } else {
        fetch('<%=url("admin/services/xray/api")%>?norestart=1', {
            method: 'POST',
            body: JSON.stringify(db)
        }).then(r => r.json()).then(() => {
            renderAllViews();
            setNodeStatus(`Deleted: ${node.name}`, false);
        });
    }
}

document.addEventListener("DOMContentLoaded", () => loadDB());
</script>
EOF

echo "===> Updating /usr/lib/lua/luci/view/xray_subs.htm..."
cat << 'EOF' > /usr/lib/lua/luci/view/xray_subs.htm
<div class="cbi-section xr-card" id="app-subs">
    <h3 style="margin-top:0; margin-bottom:12px;">Subscriptions</h3>
    <div class="xr-input-row">
        <input type="text" id="new-sub-name" class="cbi-input-text" placeholder="Subscription alias" onkeydown="if(event.key==='Enter'){event.preventDefault();addSub();}">
        <button type="button" class="cbi-button cbi-button-add" onclick="addSub()">Add Subscription</button>
    </div>
    <div id="subs-container"></div>
</div>

<script>
const subPanelState = new Map();

function saveSubDB(callback) {
    fetch('<%=url("admin/services/xray/api")%>?norestart=1', {
        method: 'POST',
        body: JSON.stringify(db)
    }).then(r => r.json()).then(() => {
        if (callback) callback();
    });
}

function setSubStatus(sIdx, text, isError) {
    const el = document.getElementById(`sub-status-${sIdx}`);
    if (!el) return;
    el.style.color = isError ? '#ef5350' : '#66bb6a';
    el.innerText = text || '';
}

function isSubPanelOpen(sIdx, sub) {
    if (subPanelState.has(sIdx)) return subPanelState.get(sIdx);
    return !(sub && sub.url && sub.url.trim() !== '');
}

function toggleSubSettingsPanel(sIdx) {
    const body = document.getElementById(`sub-settings-${sIdx}`);
    const arrow = document.getElementById(`sub-arrow-${sIdx}`);
    const cur = isSubPanelOpen(sIdx, db.subs[sIdx]);
    const next = !cur;
    subPanelState.set(sIdx, next);
    if (body) body.style.display = next ? 'block' : 'none';
    if (arrow) arrow.textContent = next ? '▾' : '▸';
}

function toggleSubHeadersUI(sIdx) {
    const chk = document.getElementById(`sub-hdr-${sIdx}`);
    const grid = document.getElementById(`sub-hdr-grid-${sIdx}`);
    if (chk && grid) grid.style.display = chk.checked ? 'grid' : 'none';
}

function pingAllSub(sIdx, btn) {
    const sub = db.subs[sIdx];
    if (!sub || !Array.isArray(sub.nodes)) return;
    runPingAllBatch('sub:' + sIdx, sub.nodes, `sub-nodes-${sIdx}`, btn);
}

function sortSubNodes(sIdx) {
    const sub = db.subs[sIdx];
    if (!sub || !Array.isArray(sub.nodes)) return;
    const scope = 'sub:' + sIdx;
    const tbody = document.getElementById(`sub-nodes-${sIdx}`);
    const job = pingJobs[scope];
    if (job && job.running) {
        job.liveSort = true;
        sortListAndAnimateTbody(sub.nodes, tbody, scope, false);
    } else {
        sortListAndAnimateTbody(sub.nodes, tbody, scope, true);
    }
}

function renderSubs() {
    const cont = document.getElementById('subs-container');
    if (!cont) return;
    cont.innerHTML = '';
    if (!db.subs || db.subs.length === 0) {
        cont.innerHTML = '<p style="opacity:0.7;"><em>No subscriptions added.</em></p>';
        return;
    }
    db.subs.forEach((sub, sIdx) => {
        const useHeaders = (sub.use_headers === true);
        const isOpen = isSubPanelOpen(sIdx, sub);
        const scope = 'sub:' + sIdx;
        const nodeCount = Array.isArray(sub.nodes) ? sub.nodes.length : 0;

        let div = document.createElement('div');
        div.className = 'xr-card';
        div.style.marginBottom = '15px';
        div.innerHTML = `
            <div class="xr-sub-header">
                <div style="display:flex; align-items:center; gap:10px; flex-wrap:wrap;">
                    <div class="xr-sub-toggle" onclick="toggleSubSettingsPanel(${sIdx})" title="Toggle subscription settings">
                        <span id="sub-arrow-${sIdx}" class="xr-sub-arrow">${isOpen ? '▾' : '▸'}</span>
                        <h4 style="margin:0;">${escapeHtml(sub.name)}</h4>
                        <span style="font-size:0.82em; opacity:0.65;">(${nodeCount})</span>
                    </div>
                    <span id="sub-status-${sIdx}" style="font-size:0.86em;"></span>
                </div>
                <div style="display:flex; gap:8px; align-items:center;">
                    <button type="button" id="btn-ping-all-sub-${sIdx}" class="cbi-button xr-ping-all-btn xr-ping-unpinged" onclick="pingAllSub(${sIdx}, this)">Ping All</button>
                    <button type="button" class="cbi-button cbi-button-action" onclick="sortSubNodes(${sIdx})">Sort</button>
                </div>
            </div>

            <div id="sub-settings-${sIdx}" class="xr-sub-settings-body" style="display:${isOpen ? 'block' : 'none'};">
                <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px; margin-bottom:10px;">
                    <strong style="font-size:0.88em; opacity:0.85;">Subscription Settings</strong>
                    <label style="font-size:0.85em; cursor:pointer; display:inline-flex; align-items:center; gap:6px; margin:0;">
                        <input type="checkbox" id="sub-hdr-${sIdx}" ${useHeaders ? 'checked' : ''} onchange="toggleSubHeadersUI(${sIdx})">
                        Custom Request Headers (User-Agent / HWID)
                    </label>
                </div>
                <div class="xr-field" style="margin-bottom:10px;">
                    <label>Subscription URL</label>
                    <input type="text" id="sub-url-${sIdx}" class="cbi-input-text" value="${escapeHtml(sub.url || '')}" placeholder="https://...">
                </div>
                <div class="xr-sub-grid" id="sub-hdr-grid-${sIdx}" style="display:${useHeaders ? 'grid' : 'none'};">
                    <div class="xr-field">
                        <label>User-Agent</label>
                        <input type="text" id="sub-ua-${sIdx}" class="cbi-input-text" value="${escapeHtml(sub.ua || '')}" placeholder="User-Agent">
                    </div>
                    <div class="xr-field">
                        <label>x-hwid</label>
                        <input type="text" id="sub-hwid-${sIdx}" class="cbi-input-text" value="${escapeHtml(sub.hwid || '')}" placeholder="x-hwid">
                    </div>
                    <div class="xr-field">
                        <label>x-device-locale</label>
                        <input type="text" id="sub-loc-${sIdx}" class="cbi-input-text" value="${escapeHtml(sub.locale || '')}" placeholder="x-device-locale">
                    </div>
                    <div class="xr-field">
                        <label>x-device-os</label>
                        <input type="text" id="sub-os-${sIdx}" class="cbi-input-text" value="${escapeHtml(sub.os || '')}" placeholder="x-device-os">
                    </div>
                    <div class="xr-field">
                        <label>x-ver-os</label>
                        <input type="text" id="sub-ver-${sIdx}" class="cbi-input-text" value="${escapeHtml(sub.ver_os || '')}" placeholder="x-ver-os">
                    </div>
                    <div class="xr-field">
                        <label>x-device-model</label>
                        <input type="text" id="sub-model-${sIdx}" class="cbi-input-text" value="${escapeHtml(sub.model || '')}" placeholder="x-device-model">
                    </div>
                </div>
                <div style="display:flex; gap:8px; align-items:center; flex-wrap:wrap;">
                    <button type="button" class="cbi-button cbi-button-save" onclick="saveSubFields(${sIdx})">Save Settings</button>
                    <button type="button" class="cbi-button cbi-button-action" onclick="updateSub(${sIdx}, this)">Update Nodes</button>
                    <button type="button" class="cbi-button cbi-button-remove" onclick="deleteSub(${sIdx})">Delete Sub</button>
                </div>
            </div>

            <table class="table cbi-section-table" style="width: 100%; margin-bottom: 0;">
                <tr class="tr cbi-section-table-titles">
                    <th class="th" style="width:14%">Status</th>
                    <th class="th" style="width:27%">Node Name (Tag)</th>
                    <th class="th" style="width:23%">Endpoint</th>
                    <th class="th" style="width:15%">Stack</th>
                    <th class="th" style="width:21%; text-align:right;">Action</th>
                </tr>
                <tbody id="sub-nodes-${sIdx}"></tbody>
            </table>
        `;
        cont.appendChild(div);

        let tbody = document.getElementById(`sub-nodes-${sIdx}`);
        if (!sub.nodes || sub.nodes.length === 0) {
            tbody.innerHTML = '<tr class="tr"><td class="td" colspan="5"><em>Open settings above and click Update Nodes.</em></td></tr>';
        } else {
            sub.nodes.forEach((n) => {
                const manual = isManualActive(n.name);
                const byRule = isRuleActive(n.name);
                const active = manual || byRule;
                const badgeClass = manual ? 'xr-badge-run' : (byRule ? 'xr-badge-rule' : 'xr-badge-idle');
                const badgeText = manual ? 'ACTIVE' : (byRule ? 'ACTIVE (RULE)' : 'IDLE');
                const btnClass = active ? 'cbi-button-reset' : 'cbi-button-apply';
                const btnText = active ? 'Stop' : 'Start';
                let meta = getOutboundMeta(n.outbound);
                let tr = document.createElement('tr');
                tr.className = 'tr cbi-section-table-row';
                tr._nodeRef = n;
                tr.innerHTML = `
                    <td class="td"><span class="xr-badge ${badgeClass}">${badgeText}</span></td>
                    <td class="td"><strong>${escapeHtml(n.name)}</strong></td>
                    <td class="td"><code>${escapeHtml(meta.endpoint)}</code></td>
                    <td class="td"><span style="font-size:0.88em; opacity:0.85;">${escapeHtml(meta.stack)}</span></td>
                    <td class="td" style="text-align: right; white-space:nowrap;">
                        <button type="button" class="cbi-button xr-ping-btn"></button>
                        <button type="button" class="cbi-button ${btnClass} xr-btn-sub-toggle">${btnText}</button>
                    </td>
                `;

                const pingBtn = tr.querySelector('.xr-ping-btn');
                tr._pingBtn = pingBtn;
                applyPingBtnStyle(pingBtn, getPingState(scope, n));
                pingBtn.addEventListener('click', () => pingSingleNode(scope, n, pingBtn));

                tr.querySelector('.xr-btn-sub-toggle').addEventListener('click', () => {
                    const nIdx = sub.nodes.indexOf(n);
                    if (nIdx !== -1) toggleSubNode(sIdx, nIdx);
                });

                tbody.appendChild(tr);
            });
        }
    });
}

function addSub() {
    const input = document.getElementById('new-sub-name');
    const name = input ? input.value.trim() : '';
    if (!name) {
        if (input) input.focus();
        return;
    }
    if (!db.subs) db.subs = [];
    const newIdx = db.subs.length;
    db.subs.push({
        name: name,
        url: '',
        use_headers: false,
        ua: '',
        hwid: '',
        locale: '',
        os: '',
        ver_os: '',
        model: '',
        nodes: []
    });
    subPanelState.set(newIdx, true);
    input.value = '';
    saveSubDB(() => renderAllViews());
}

function readSubInputs(sIdx) {
    db.subs[sIdx].url = document.getElementById(`sub-url-${sIdx}`).value.trim();
    db.subs[sIdx].use_headers = document.getElementById(`sub-hdr-${sIdx}`).checked;
    db.subs[sIdx].ua = document.getElementById(`sub-ua-${sIdx}`).value.trim();
    db.subs[sIdx].hwid = document.getElementById(`sub-hwid-${sIdx}`).value.trim();
    db.subs[sIdx].locale = document.getElementById(`sub-loc-${sIdx}`).value.trim();
    db.subs[sIdx].os = document.getElementById(`sub-os-${sIdx}`).value.trim();
    db.subs[sIdx].ver_os = document.getElementById(`sub-ver-${sIdx}`).value.trim();
    db.subs[sIdx].model = document.getElementById(`sub-model-${sIdx}`).value.trim();
}

function saveSubFields(sIdx) {
    readSubInputs(sIdx);
    saveSubDB(() => setSubStatus(sIdx, 'Settings saved', false));
}

function updateSub(sIdx, btn) {
    const scope = 'sub:' + sIdx;
    if (pingJobs[scope] && pingJobs[scope].running) {
        pingJobs[scope].cancelled = true;
    }
    readSubInputs(sIdx);
    btn.disabled = true;
    btn.innerText = 'Fetching...';
    setSubStatus(sIdx, 'Downloading...', false);

    saveSubDB(() => {
        fetch('<%=url("admin/services/xray/fetch_sub")%>', {
            method: 'POST',
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: 'index=' + sIdx
        }).then(r => r.json()).then(res => {
            if (res && res.success) {
                const count = res.count || 0;
                clearScopePings(scope);
                loadDB(() => setSubStatus(sIdx, `Updated: ${count} nodes`, false));
            } else {
                setSubStatus(sIdx, (res && res.error) ? res.error : 'Update failed', true);
            }
        }).catch(err => {
            setSubStatus(sIdx, 'Request error: ' + err, true);
        }).finally(() => {
            btn.disabled = false;
            btn.innerText = 'Update Nodes';
        });
    });
}

function toggleSubNode(sIdx, nIdx) {
    const sub = db.subs[sIdx];
    const node = sub && sub.nodes && sub.nodes[nIdx];
    if (!node) return;
    const name = node.name;
    const pos = db.manual_nodes.indexOf(name);
    if (pos !== -1) {
        db.manual_nodes.splice(pos, 1);
        saveDB(() => setSubStatus(sIdx, isRuleActive(name) ? `Removed from default (still active via Rules): ${name}` : `Stopped: ${name}`, false));
    } else if (isRuleActive(name)) {
        setSubStatus(sIdx, `"${name}" is active via Rules tab — remove it from Rules to stop.`, true);
    } else {
        db.manual_nodes.push(name);
        saveDB(() => setSubStatus(sIdx, `Started: ${name}`, false));
    }
}

function deleteSub(sIdx) {
    const sub = db.subs[sIdx];
    if (!sub) return;
    const scope = 'sub:' + sIdx;
    if (pingJobs[scope] && pingJobs[scope].running) {
        pingJobs[scope].cancelled = true;
    }
    for (let i = sIdx; i < db.subs.length; i++) {
        clearScopePings('sub:' + i);
    }
    subPanelState.clear();

    let hadActive = false;
    if (Array.isArray(sub.nodes)) {
        sub.nodes.forEach(n => {
            const pos = db.manual_nodes.indexOf(n.name);
            if (pos !== -1) {
                db.manual_nodes.splice(pos, 1);
                hadActive = true;
            }
            if (isRuleActive(n.name)) hadActive = true;
        });
    }
    db.subs.splice(sIdx, 1);
    if (hadActive) {
        saveDB();
    } else {
        saveSubDB(() => renderAllViews());
    }
}
</script>
EOF

echo "===> Updating /usr/lib/lua/luci/view/xray_rules.htm..."
cat << 'EOF' > /usr/lib/lua/luci/view/xray_rules.htm
<div class="cbi-section xr-card" id="app-rules">
    <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:10px; margin-bottom:14px;">
        <h3 style="margin:0;">Routing Rules</h3>
        <div style="display:flex; align-items:center; gap:8px; flex-wrap:wrap;">
            <label for="rule-domain-strategy" style="font-size:0.9em; opacity:0.85; margin:0;">Domain Strategy:</label>
            <select id="rule-domain-strategy" class="cbi-input-select" style="width:165px;" onchange="setDomainStrategy(this.value)">
                <option value="AsIs">AsIs</option>
                <option value="IPIfNonMatch">IPIfNonMatch</option>
                <option value="IPOnDemand">IPOnDemand</option>
            </select>
            <span id="rule-ds-status" style="font-size:0.84em;"></span>
        </div>
    </div>

    <div class="xr-card" style="margin-bottom:14px;">
        <h4 id="rule-form-title" style="margin:0 0 10px 0;">New Rule</h4>
        <div class="xr-sub-grid">
            <div class="xr-field">
                <label>Rule Name</label>
                <input type="text" id="rule-name" class="cbi-input-text" placeholder="e.g. Direct / Proxy">
            </div>
            <div class="xr-field">
                <label>IP (CIDR / geoip:)</label>
                <input type="text" id="rule-ip" class="cbi-input-text" placeholder="geoip:private, 192.168.0.0/16">
            </div>
            <div class="xr-field">
                <label>Domain (domain / geosite: / regexp:)</label>
                <input type="text" id="rule-domain" class="cbi-input-text" placeholder="example.com, geosite:private">
            </div>
            <div class="xr-field">
                <label>Protocol</label>
                <input type="text" id="rule-protocol" class="cbi-input-text" placeholder="bittorrent, http, tls, quic">
            </div>
            <div class="xr-field">
                <label>Network</label>
                <select id="rule-network" class="cbi-input-select">
                    <option value="">Any</option>
                    <option value="tcp">tcp</option>
                    <option value="udp">udp</option>
                    <option value="tcp,udp">tcp,udp</option>
                </select>
            </div>
            <div class="xr-field">
                <label>Port (0-65535)</label>
                <input type="text" id="rule-port" class="cbi-input-text" placeholder="443 or 80,443 or 1000-2000">
            </div>
            <div class="xr-field">
                <label>Outbound (Node)</label>
                <select id="rule-outbound" class="cbi-input-select"></select>
            </div>
        </div>

        <div style="display:flex; gap:8px; align-items:center; flex-wrap:wrap;">
            <button type="button" id="btn-save-rule" class="cbi-button cbi-button-save" onclick="saveRule()">Add &amp; Save Rule</button>
            <button type="button" id="btn-cancel-rule" class="cbi-button cbi-button-reset" style="display:none;" onclick="resetRuleForm()">Cancel</button>
            <span id="rule-status" style="font-size:0.88em; margin-left:6px;"></span>
        </div>
    </div>

    <table class="table cbi-section-table" style="width:100%;">
        <tr class="tr cbi-section-table-titles">
            <th class="th" style="width:4%; text-align:center;" title="Drag to reorder"></th>
            <th class="th" style="width:5%">#</th>
            <th class="th" style="width:18%">Name</th>
            <th class="th" style="width:41%">Match Conditions</th>
            <th class="th" style="width:18%">Outbound</th>
            <th class="th" style="width:14%; text-align:right;">Actions</th>
        </tr>
        <tbody id="rules-table-body"></tbody>
    </table>
</div>

<script>
let editingRuleIdx = -1;
let dragRuleIdx = -1;
let dragDropBelow = false;

function setRuleStatus(text, isError) {
    const el = document.getElementById('rule-status');
    if (!el) return;
    el.style.color = isError ? '#ef5350' : '#66bb6a';
    el.innerText = text || '';
}

function setDomainStrategy(val) {
    if (!db.routing_settings) db.routing_settings = {};
    db.routing_settings.domainStrategy = val;
    const st = document.getElementById('rule-ds-status');
    if (st) { st.style.color = '#4fc3f7'; st.textContent = 'Applying...'; }
    saveDB(() => {
        if (st) {
            st.style.color = '#66bb6a';
            st.textContent = 'Applied';
            setTimeout(() => { if (st.textContent === 'Applied') st.textContent = ''; }, 2000);
        }
    });
}

function validatePortField(val) {
    if (!val) return true;
    const parts = val.split(',');
    for (let i = 0; i < parts.length; i++) {
        const p = parts[i].trim();
        if (!p) continue;
        if (/^\d+$/.test(p)) {
            const n = Number(p);
            if (n < 0 || n > 65535) return false;
        } else if (/^\d+-\d+$/.test(p)) {
            const [a, b] = p.split('-').map(Number);
            if (a < 0 || b > 65535 || a > b) return false;
        } else {
            return false;
        }
    }
    return true;
}

function populateRuleOutboundSelect(selectedVal) {
    const sel = document.getElementById('rule-outbound');
    if (!sel) return;
    const prev = (selectedVal !== undefined) ? selectedVal : sel.value;
    sel.innerHTML = '';

    const optDirect = document.createElement('option');
    optDirect.value = 'direct';
    optDirect.textContent = 'direct';
    sel.appendChild(optDirect);

    const optBlock = document.createElement('option');
    optBlock.value = 'block';
    optBlock.textContent = 'block';
    sel.appendChild(optBlock);

    if (Array.isArray(db.nodes) && db.nodes.length > 0) {
        const grp = document.createElement('optgroup');
        grp.label = 'Custom Nodes';
        db.nodes.forEach(n => {
            if (!n || !n.name) return;
            const o = document.createElement('option');
            o.value = n.name;
            o.textContent = n.name;
            grp.appendChild(o);
        });
        if (grp.children.length > 0) sel.appendChild(grp);
    }

    if (Array.isArray(db.subs) && db.subs.length > 0) {
        db.subs.forEach(sub => {
            if (!sub || !Array.isArray(sub.nodes) || sub.nodes.length === 0) return;
            const grp = document.createElement('optgroup');
            grp.label = 'Sub: ' + (sub.name || 'Unnamed');
            sub.nodes.forEach(n => {
                if (!n || !n.name) return;
                const o = document.createElement('option');
                o.value = n.name;
                o.textContent = n.name;
                grp.appendChild(o);
            });
            if (grp.children.length > 0) sel.appendChild(grp);
        });
    }

    if (prev) {
        const exists = Array.from(sel.options).some(o => o.value === prev);
        if (!exists) {
            const missing = document.createElement('option');
            missing.value = prev;
            missing.textContent = prev + ' (not in list)';
            sel.appendChild(missing);
        }
        sel.value = prev;
    }
}

function resetRuleForm() {
    editingRuleIdx = -1;
    document.getElementById('rule-form-title').innerText = 'New Rule';
    document.getElementById('btn-save-rule').innerText = 'Add & Save Rule';
    document.getElementById('btn-cancel-rule').style.display = 'none';
    document.getElementById('rule-name').value = '';
    document.getElementById('rule-ip').value = '';
    document.getElementById('rule-domain').value = '';
    document.getElementById('rule-protocol').value = '';
    document.getElementById('rule-network').value = '';
    document.getElementById('rule-port').value = '';
    populateRuleOutboundSelect('direct');
}

function editRule(idx) {
    const r = db.rules[idx];
    if (!r) return;
    editingRuleIdx = idx;
    document.getElementById('rule-form-title').innerText = 'Edit Rule #' + (idx + 1);
    document.getElementById('btn-save-rule').innerText = 'Save Changes';
    document.getElementById('btn-cancel-rule').style.display = '';
    document.getElementById('rule-name').value = r.name || '';
    document.getElementById('rule-ip').value = r.ip || '';
    document.getElementById('rule-domain').value = r.domain || '';
    document.getElementById('rule-protocol').value = r.protocol || '';
    document.getElementById('rule-network').value = r.network || '';
    document.getElementById('rule-port').value = r.port || '';
    populateRuleOutboundSelect(r.outbound || 'direct');
    setRuleStatus('Editing rule #' + (idx + 1), false);
    document.getElementById('rule-name').focus();
}

function saveRule() {
    const name = document.getElementById('rule-name').value.trim();
    const ip = document.getElementById('rule-ip').value.trim();
    const domain = document.getElementById('rule-domain').value.trim();
    const protocol = document.getElementById('rule-protocol').value.trim();
    const network = document.getElementById('rule-network').value.trim();
    const port = document.getElementById('rule-port').value.trim();
    const outbound = document.getElementById('rule-outbound').value;

    if (!ip && !domain && !protocol && !network && !port) {
        setRuleStatus('Fill at least one condition (IP, Domain, Protocol, Network, or Port).', true);
        return;
    }
    if (!validatePortField(port)) {
        setRuleStatus('Invalid port. Use 0-65535 (single, comma-separated, or range a-b).', true);
        return;
    }
    if (!outbound) {
        setRuleStatus('Select an outbound node.', true);
        return;
    }

    const ruleObj = {
        name: name || ('Rule #' + (editingRuleIdx >= 0 ? editingRuleIdx + 1 : (db.rules.length + 1))),
        ip: ip,
        domain: domain,
        protocol: protocol,
        network: network,
        port: port,
        outbound: outbound
    };

    if (!Array.isArray(db.rules)) db.rules = [];
    const wasEditing = (editingRuleIdx >= 0 && editingRuleIdx < db.rules.length);
    if (wasEditing) {
        db.rules[editingRuleIdx] = ruleObj;
    } else {
        db.rules.push(ruleObj);
    }

    resetRuleForm();
    setRuleStatus('Saving & applying config...', false);
    saveDB(() => {
        setRuleStatus(wasEditing ? `Rule "${ruleObj.name}" updated.` : `Rule "${ruleObj.name}" added & applied.`, false);
    });
}

function deleteRule(idx) {
    const r = db.rules[idx];
    if (!r) return;
    if (editingRuleIdx === idx) resetRuleForm();
    else if (editingRuleIdx > idx) editingRuleIdx -= 1;

    db.rules.splice(idx, 1);
    setRuleStatus('Applying changes...', false);
    saveDB(() => {
        setRuleStatus(`Rule "${r.name}" removed.`, false);
    });
}

function formatRuleMatchChips(r) {
    const chips = [];
    if (r.domain) chips.push(`<span class="xr-chip">domain: ${escapeHtml(r.domain)}</span>`);
    if (r.ip) chips.push(`<span class="xr-chip">ip: ${escapeHtml(r.ip)}</span>`);
    if (r.protocol) chips.push(`<span class="xr-chip">proto: ${escapeHtml(r.protocol)}</span>`);
    if (r.network) chips.push(`<span class="xr-chip">net: ${escapeHtml(r.network)}</span>`);
    if (r.port) chips.push(`<span class="xr-chip">port: ${escapeHtml(r.port)}</span>`);
    return chips.length > 0 ? chips.join('') : '<em>-</em>';
}

function clearDragIndicators() {
    const tbody = document.getElementById('rules-table-body');
    if (!tbody) return;
    tbody.querySelectorAll('tr').forEach(row => {
        row.classList.remove('xr-row-over-top', 'xr-row-over-bottom', 'xr-row-dragging');
    });
}

function renderRules() {
    const dsSel = document.getElementById('rule-domain-strategy');
    if (dsSel && db.routing_settings && db.routing_settings.domainStrategy) {
        dsSel.value = db.routing_settings.domainStrategy;
    }

    populateRuleOutboundSelect();
    const tbody = document.getElementById('rules-table-body');
    if (!tbody) return;
    tbody.innerHTML = '';

    if (!Array.isArray(db.rules) || db.rules.length === 0) {
        tbody.innerHTML = '<tr class="tr"><td class="td" colspan="6"><em>No routing rules configured. Add a rule above.</em></td></tr>';
        return;
    }

    db.rules.forEach((r, idx) => {
        const outBadgeClass = (r.outbound === 'block') ? 'xr-badge-stop'
            : (r.outbound === 'direct' ? 'xr-badge-idle' : 'xr-badge-run');

        const tr = document.createElement('tr');
        tr.className = 'tr cbi-section-table-row';
        tr.dataset.ruleIdx = String(idx);
        tr.draggable = false;

        tr.innerHTML = `
            <td class="td" style="text-align:center; vertical-align:middle;">
                <span class="xr-drag-handle" title="Drag to reorder">
                    <svg width="12" height="16" viewBox="0 0 12 16" fill="currentColor">
                        <circle cx="3" cy="3" r="1.4"/><circle cx="9" cy="3" r="1.4"/>
                        <circle cx="3" cy="8" r="1.4"/><circle cx="9" cy="8" r="1.4"/>
                        <circle cx="3" cy="13" r="1.4"/><circle cx="9" cy="13" r="1.4"/>
                    </svg>
                </span>
            </td>
            <td class="td"><code>${idx + 1}</code></td>
            <td class="td"><strong>${escapeHtml(r.name || ('Rule #' + (idx + 1)))}</strong></td>
            <td class="td">${formatRuleMatchChips(r)}</td>
            <td class="td"><span class="xr-badge ${outBadgeClass}">${escapeHtml(r.outbound || 'direct')}</span></td>
            <td class="td" style="text-align:right; white-space:nowrap;">
                <button type="button" class="cbi-button cbi-button-action" onclick="editRule(${idx})">Edit</button>
                <button type="button" class="cbi-button cbi-button-remove" onclick="deleteRule(${idx})">Delete</button>
            </td>
        `;

        const handle = tr.querySelector('.xr-drag-handle');
        handle.addEventListener('mousedown', () => { tr.draggable = true; });
        handle.addEventListener('mouseup', () => { tr.draggable = false; });

        tr.addEventListener('dragstart', (e) => {
            if (!tr.draggable) {
                e.preventDefault();
                return;
            }
            dragRuleIdx = idx;
            tr.classList.add('xr-row-dragging');
            e.dataTransfer.effectAllowed = 'move';
            e.dataTransfer.setData('text/plain', String(idx));
        });

        tr.addEventListener('dragover', (e) => {
            if (dragRuleIdx === -1) return;
            e.preventDefault();
            e.dataTransfer.dropEffect = 'move';
            const rect = tr.getBoundingClientRect();
            dragDropBelow = (e.clientY - rect.top) > (rect.height / 2);
            clearDragIndicators();
            const srcRow = tbody.querySelector(`tr[data-rule-idx="${dragRuleIdx}"]`);
            if (srcRow) srcRow.classList.add('xr-row-dragging');
            if (idx !== dragRuleIdx) {
                tr.classList.add(dragDropBelow ? 'xr-row-over-bottom' : 'xr-row-over-top');
            }
        });

        tr.addEventListener('drop', (e) => {
            e.preventDefault();
            if (dragRuleIdx === -1 || dragRuleIdx === idx) {
                clearDragIndicators();
                dragRuleIdx = -1;
                return;
            }
            let targetIdx = idx;
            if (dragRuleIdx < idx) {
                targetIdx = dragDropBelow ? idx : (idx - 1);
            } else {
                targetIdx = dragDropBelow ? (idx + 1) : idx;
            }
            clearDragIndicators();
            if (targetIdx !== dragRuleIdx) {
                const moved = db.rules.splice(dragRuleIdx, 1)[0];
                db.rules.splice(targetIdx, 0, moved);
                if (editingRuleIdx !== -1) resetRuleForm();
                setRuleStatus('Updating rule order...', false);
                saveDB(() => setRuleStatus('Rule order saved.', false));
            }
            dragRuleIdx = -1;
        });

        tr.addEventListener('dragend', () => {
            tr.draggable = false;
            dragRuleIdx = -1;
            clearDragIndicators();
        });

        tbody.appendChild(tr);
    });
}
</script>
EOF

echo "===> Clearing LuCI cache..."
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/ /tmp/luci-uci-cache

echo "===> UI patch completed! Refresh LuCI."

echo "===> Clearing LuCI cache..."
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/ /tmp/luci-uci-cache

echo "===> Service tab update completed! Refresh LuCI."

#!/bin/sh
set -e

echo "===> Initializing logging flags in UCI and setting default loglevel..."
touch /etc/config/xray_ui
uci -q get xray_ui.main >/dev/null 2>&1 || uci set xray_ui.main=xray_ui
uci -q get xray_ui.main.ping_log_enabled >/dev/null 2>&1 || uci set xray_ui.main.ping_log_enabled="0"
uci -q get xray_ui.main.xray_log_enabled >/dev/null 2>&1 || uci set xray_ui.main.xray_log_enabled="0"
uci commit xray_ui

lua -e '
local fs = require "nixio.fs"
local json = require "luci.jsonc"
local sys = require "luci.sys"
local cfg_path = "/etc/xray/config.json"
local en = (sys.exec("uci -q get xray_ui.main.xray_log_enabled") or "0"):gsub("%s+", "")
local raw = fs.readfile(cfg_path)
if raw and raw ~= "" then
    local cfg = json.parse(raw)
    if type(cfg) == "table" then
        if type(cfg.log) ~= "table" then cfg.log = {} end
        cfg.log.loglevel = (en == "1") and "info" or "error"
        fs.writefile(cfg_path, json.stringify(cfg, true):gsub("\\/", "/"))
    end
end
'

echo "===> Patching /usr/libexec/xray-ui-core.lua (respect ping_log_enabled flag)..."
cp /usr/libexec/xray-ui-core.lua /tmp/xray-ui-core.lua.bak
lua -e '
local fs = require "nixio.fs"
local path = "/usr/libexec/xray-ui-core.lua"
local src = fs.readfile(path)
assert(src, "cannot read " .. path)

if not src:find("ping_log_enabled", 1, true) then
    local anchor = "local function append_ping_log(line)\n"
    local s, e = src:find(anchor, 1, true)
    assert(s, "append_ping_log anchor not found")
    local inject = anchor .. "    if (sys.exec(\"uci -q get xray_ui.main.ping_log_enabled\") or \"0\"):gsub(\"%s+\", \"\") ~= \"1\" then return end\n"
    src = src:sub(1, s - 1) .. inject .. src:sub(e + 1)
end

fs.writefile(path, src)
assert(loadfile(path), "syntax check failed for " .. path)
' || {
    mv /tmp/xray-ui-core.lua.bak /usr/libexec/xray-ui-core.lua
    echo "===> Error patching xray-ui-core.lua, restored backup."
    exit 1
}
rm -f /tmp/xray-ui-core.lua.bak

echo "===> Updating /usr/lib/lua/luci/controller/xray.lua..."
cat << 'EOF' > /usr/lib/lua/luci/controller/xray.lua
module("luci.controller.xray", package.seeall)

function index()
    entry({"admin", "services", "xray"}, cbi("xray"), _("Xray Core"), 50).dependent = true
    entry({"admin", "services", "xray", "api"}, call("action_api")).leaf = true
    entry({"admin", "services", "xray", "fetch_sub"}, call("action_fetch_sub")).leaf = true
    entry({"admin", "services", "xray", "add_node"}, call("action_add_node")).leaf = true
    entry({"admin", "services", "xray", "ping"}, call("action_ping")).leaf = true
    entry({"admin", "services", "xray", "ping_log"}, call("action_ping_log")).leaf = true
    entry({"admin", "services", "xray", "xray_log"}, call("action_xray_log")).leaf = true
    entry({"admin", "services", "xray", "service_ctl"}, call("action_service_ctl")).leaf = true
    entry({"admin", "services", "xray", "get_config"}, call("action_get_config")).leaf = true
    entry({"admin", "services", "xray", "geo_list"}, call("action_geo_list")).leaf = true
    entry({"admin", "services", "xray", "geo_download"}, call("action_geo_download")).leaf = true
    entry({"admin", "services", "xray", "service_ext"}, call("action_service_ext")).leaf = true
end

local fs = require "nixio.fs"
local nixio = require "nixio"
local sys = require "luci.sys"
local http = require "luci.http"
local json = require "luci.jsonc"

local db_path = "/etc/xray/nodes.json"
local cfg_path = "/etc/xray/config.json"
local ping_log_path = "/tmp/xray_ping.log"
local cron_cfg_path = "/etc/xray/cron.json"
local crontab_path = "/etc/crontabs/root"

local INTERVAL_MAP = {
    ["1h"]  = "0 * * * *",
    ["3h"]  = "0 */3 * * *",
    ["6h"]  = "0 */6 * * *",
    ["12h"] = "0 */12 * * *",
    ["1d"]  = "0 4 * * *",
    ["3d"]  = "0 4 */3 * *",
    ["7d"]  = "0 4 * * 1",
    ["14d"] = "0 4 1,15 * *",
    ["30d"] = "0 4 1 * *"
}

local function get_asset_dir()
    local d = (sys.exec("uci -q get xray_ui.main.asset_dir") or "/usr/bin/"):gsub("%s+", "")
    if d == "" then d = "/usr/bin/" end
    if d:sub(-1) ~= "/" then d = d .. "/" end
    return d
end

local function is_safe_dirpath(dir)
    if type(dir) ~= "string" or dir == "" then return false end
    if dir:sub(1, 1) ~= "/" then return false end
    if dir:find("..", 1, true) then return false end
    return dir:match("^/[%w%/%._%-]*$") ~= nil
end

local function list_dat_files(dir)
    local files = {}
    local iter = fs.dir(dir)
    if iter then
        for name in iter do
            if name:lower():match("%.dat$") then
                local st = fs.stat(dir .. name)
                if st and st.type == "reg" then
                    table.insert(files, {
                        name = name,
                        size = st.size or 0,
                        mtime = st.mtime or 0
                    })
                end
            end
        end
    end
    table.sort(files, function(a, b) return a.name < b.name end)
    return files
end

local function is_safe_filename(name)
    if type(name) ~= "string" or name == "" then return false end
    if name:find("/", 1, true) or name:find("..", 1, true) then return false end
    return name:match("^[%w%.%-%_]+$") ~= nil
end

local function is_safe_url(url)
    if type(url) ~= "string" or url == "" then return false end
    if not url:match("^https?://") then return false end
    if url:find("[%s\"'`$;|&<>]") then return false end
    return true
end

local function get_service_status()
    local pid = sys.exec("pidof xray"):gsub("%s+", "")
    local is_running = (pid ~= "")
    local is_enabled = (sys.call("/etc/init.d/xray enabled >/dev/null 2>&1") == 0)
    return {
        running = is_running,
        pid = is_running and pid or "-",
        enabled = is_enabled
    }
end

local function default_cron_cfg()
    return {
        geo_enabled = false,
        geofiles = {
            { enabled = false, url = "", filename = "geosite.dat", interval = "7d" },
            { enabled = false, url = "", filename = "geoip.dat", interval = "7d" }
        },
        restart_enabled = false,
        restart_interval = "1d"
    }
end

local function load_cron_cfg()
    local raw = fs.readfile(cron_cfg_path)
    local parsed = raw and json.parse(raw) or nil
    if type(parsed) ~= "table" then return default_cron_cfg() end
    if type(parsed.geofiles) ~= "table" then parsed.geofiles = {} end
    return parsed
end

local function apply_crontab(cron_cfg)
    local dir = get_asset_dir()
    fs.mkdirr("/etc/crontabs")
    local existing = fs.readfile(crontab_path) or ""
    local kept = {}
    local inside = false
    for line in (existing .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        if line == "# XRAY_UI_CRON_BEGIN" then
            inside = true
        elseif line == "# XRAY_UI_CRON_END" then
            inside = false
        elseif not inside then
            table.insert(kept, line)
        end
    end
    while #kept > 0 and kept[#kept] == "" do
        table.remove(kept)
    end

    local jobs = {}
    if cron_cfg.geo_enabled and type(cron_cfg.geofiles) == "table" then
        for _, g in ipairs(cron_cfg.geofiles) do
            if type(g) == "table" and g.enabled then
                local url = tostring(g.url or ""):gsub("^%s+", ""):gsub("%s+$", "")
                local fname = tostring(g.filename or ""):gsub("^%s+", ""):gsub("%s+$", "")
                local sched = INTERVAL_MAP[tostring(g.interval or "")]
                if sched and is_safe_url(url) and is_safe_filename(fname) then
                    table.insert(jobs, string.format('%s wget -O "%s%s" "%s"', sched, dir, fname, url))
                end
            end
        end
    end

    if cron_cfg.restart_enabled then
        local sched = INTERVAL_MAP[tostring(cron_cfg.restart_interval or "")]
        if sched then
            table.insert(jobs, string.format('%s /etc/init.d/xray restart', sched))
        end
    end

    if #jobs > 0 then
        table.insert(kept, "# XRAY_UI_CRON_BEGIN")
        for _, j in ipairs(jobs) do
            table.insert(kept, j)
        end
        table.insert(kept, "# XRAY_UI_CRON_END")
    end

    local final_text = (#kept > 0) and (table.concat(kept, "\n") .. "\n") or ""
    fs.writefile(crontab_path, final_text)
    sys.call("/etc/init.d/cron enable >/dev/null 2>&1; /etc/init.d/cron restart >/dev/null 2>&1")
    return #jobs
end

local function is_xray_log_enabled()
    local raw = fs.readfile(cfg_path)
    if raw and raw ~= "" then
        local cfg = json.parse(raw)
        if type(cfg) == "table" and type(cfg.log) == "table" and type(cfg.log.loglevel) == "string" then
            local lv = cfg.log.loglevel:lower()
            return (lv == "info" or lv == "debug")
        end
    end
    local v = (sys.exec("uci -q get xray_ui.main.xray_log_enabled") or "0"):gsub("%s+", "")
    return v == "1"
end

function action_api()
    local method = http.getenv("REQUEST_METHOD")
    if method == "GET" then
        http.prepare_content("application/json")
        http.write(fs.readfile(db_path) or "{}")
    elseif method == "POST" then
        local qs = http.getenv("QUERY_STRING") or ""
        local norestart = qs:match("norestart=1")
        local content = http.content()
        if content and content ~= "" then
            fs.writefile(db_path, content)
            if not norestart then
                sys.call("lua /usr/libexec/xray-ui-core.lua generate >/dev/null 2>&1")
                sys.call("/etc/init.d/xray restart >/dev/null 2>&1")
            end
            http.prepare_content("application/json")
            http.write(json.stringify({
                status = "ok",
                service = get_service_status(),
                config = fs.readfile(cfg_path) or "{}"
            }))
        end
    end
end

function action_add_node()
    local link = http.formvalue("link")
    http.prepare_content("application/json")
    if not link or link == "" then
        http.write(json.stringify({ success = false, error = "Link is empty" }))
        return
    end
    local tmp = "/tmp/xray_add_node.tmp"
    fs.writefile(tmp, link)
    local res = sys.exec("lua /usr/libexec/xray-ui-core.lua add_node " .. tmp .. " 2>&1")
    fs.remove(tmp)
    local parsed = res and json.parse(res)
    if type(parsed) == "table" and parsed.success ~= nil then
        http.write(res)
    else
        http.write(json.stringify({
            success = false,
            error = (res and res ~= "") and res:sub(1, 200) or "Failed to parse node"
        }))
    end
end

function action_ping()
    local content = http.content()
    http.prepare_content("application/json")
    if not content or content == "" then
        http.write(json.stringify({ success = false, ms = -1, error = "empty request" }))
        return
    end
    local _, u = nixio.gettimeofday()
    local tmp = string.format("/tmp/xray_ping_req_%d_%d.json", nixio.getpid(), u or 0)
    fs.writefile(tmp, content)
    local res = sys.exec("lua /usr/libexec/xray-ui-core.lua ping " .. tmp .. " 2>&1")
    fs.remove(tmp)
    local parsed = res and json.parse(res)
    if type(parsed) == "table" and parsed.success ~= nil then
        http.write(res)
    else
        local err_msg = (res and res ~= "") and res:gsub("%s+", " "):sub(1, 200) or "ping script failed"
        local plog_en = (sys.exec("uci -q get xray_ui.main.ping_log_enabled") or "0"):gsub("%s+", "")
        if plog_en == "1" then
            local cur = fs.readfile(ping_log_path) or ""
            fs.writefile(ping_log_path, cur .. "[" .. os.date("%H:%M:%S") .. "] [ERR] " .. err_msg .. "\n")
        end
        http.write(json.stringify({ success = false, ms = -1, error = err_msg }))
    end
end

function action_ping_log()
    local method = http.getenv("REQUEST_METHOD")
    if method == "POST" and http.formvalue("clear") == "1" then
        fs.writefile(ping_log_path, "")
        http.prepare_content("application/json")
        http.write('{"ok":true}')
        return
    end
    http.prepare_content("text/plain; charset=utf-8")
    http.write(fs.readfile(ping_log_path) or "")
end

function action_xray_log()
    local out = sys.exec("logread 2>/dev/null | grep -iE 'xray\\[|xray:' | tail -n 200")
    if not out or out == "" then
        out = sys.exec("logread -e xray 2>/dev/null | tail -n 200")
    end
    http.prepare_content("text/plain; charset=utf-8")
    http.write(out or "")
end

function action_fetch_sub()
    local sub_idx = tonumber(http.formvalue("index"))
    local res = sys.exec("lua /usr/libexec/xray-ui-core.lua fetch " .. tostring(sub_idx or 0) .. " 2>&1")
    http.prepare_content("application/json")
    local parsed = res and json.parse(res)
    if type(parsed) == "table" and parsed.success ~= nil then
        http.write(res)
    else
        http.write(json.stringify({
            success = false,
            error = (res and res ~= "") and res:sub(1, 200) or "Empty output from fetch script"
        }))
    end
end

function action_service_ctl()
    local act = http.formvalue("action")
    if act == "start" then sys.call("/etc/init.d/xray start >/dev/null 2>&1")
    elseif act == "stop" then sys.call("/etc/init.d/xray stop >/dev/null 2>&1")
    elseif act == "restart" then sys.call("/etc/init.d/xray restart >/dev/null 2>&1")
    elseif act == "enable" then sys.call("/etc/init.d/xray enable >/dev/null 2>&1")
    elseif act == "disable" then sys.call("/etc/init.d/xray disable >/dev/null 2>&1")
    end
    http.prepare_content("application/json")
    http.write(json.stringify(get_service_status()))
end

function action_get_config()
    http.prepare_content("application/json")
    http.write(json.stringify({
        service = get_service_status(),
        config = fs.readfile(cfg_path) or "{}"
    }))
end

function action_geo_list()
    local dir = get_asset_dir()
    http.prepare_content("application/json")
    http.write(json.stringify({
        dir = dir,
        files = list_dat_files(dir)
    }))
end

function action_geo_download()
    local content = http.content()
    local req = content and json.parse(content) or nil
    local dir = get_asset_dir()
    http.prepare_content("application/json")

    if type(req) ~= "table" then
        http.write(json.stringify({ success = false, error = "Invalid request" }))
        return
    end

    local url = tostring(req.url or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local fname = tostring(req.filename or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if not is_safe_url(url) then
        http.write(json.stringify({ success = false, error = "Invalid URL (expected http:// or https://)" }))
        return
    end
    if not is_safe_filename(fname) then
        http.write(json.stringify({ success = false, error = "Invalid filename (use letters, digits, '.', '-', '_')" }))
        return
    end

    fs.mkdirr(dir)
    local dest = dir .. fname
    local cmd = string.format('wget -O "%s" "%s" 2>&1; printf "\\nRC=%%d" $?', dest, url)
    local out = sys.exec(cmd) or ""
    local rc = tonumber(out:match("RC=(%d+)%s*$")) or 1
    local msg = out:gsub("RC=%d+%s*$", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

    if rc == 0 then
        http.write(json.stringify({
            success = true,
            dir = dir,
            files = list_dat_files(dir)
        }))
    else
        http.write(json.stringify({
            success = false,
            error = (msg ~= "" and msg:sub(-160) or "wget failed (rc=" .. rc .. ")"),
            dir = dir,
            files = list_dat_files(dir)
        }))
    end
end

function action_service_ext()
    local method = http.getenv("REQUEST_METHOD")
    http.prepare_content("application/json")

    if method == "GET" then
        local gomem = (sys.exec("uci -q get xray_ui.main.gomemlimit") or "65MiB"):gsub("%s+", "")
        local gogc = (sys.exec("uci -q get xray_ui.main.gogc") or "40"):gsub("%s+", "")
        local ping_en = (sys.exec("uci -q get xray_ui.main.ping_log_enabled") or "0"):gsub("%s+", "")
        if gomem == "" then gomem = "65MiB" end
        if gogc == "" then gogc = "40" end
        http.write(json.stringify({
            asset_dir = get_asset_dir(),
            cron = load_cron_cfg(),
            limits = { gomemlimit = gomem, gogc = gogc },
            logging = {
                ping_log = (ping_en == "1"),
                xray_log = is_xray_log_enabled()
            }
        }))
        return
    end

    local content = http.content()
    local req = content and json.parse(content) or nil
    if type(req) ~= "table" then
        http.write(json.stringify({ success = false, error = "Invalid payload" }))
        return
    end

    if req.section == "asset_dir" then
        local dir = tostring(req.asset_dir or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if not is_safe_dirpath(dir) then
            http.write(json.stringify({ success = false, error = "Invalid directory path (must start with /)" }))
            return
        end
        if dir:sub(-1) ~= "/" then dir = dir .. "/" end
        fs.mkdirr(dir)
        sys.call(string.format("uci set xray_ui.main.asset_dir='%s' && uci commit xray_ui", dir))
        local cron_cfg = load_cron_cfg()
        if cron_cfg.geo_enabled then apply_crontab(cron_cfg) end
        local restarted = false
        if sys.call("pidof xray >/dev/null 2>&1") == 0 then
            sys.call("/etc/init.d/xray restart >/dev/null 2>&1")
            restarted = true
        end
        http.write(json.stringify({
            success = true,
            dir = dir,
            files = list_dat_files(dir),
            restarted = restarted,
            service = get_service_status()
        }))
        return
    end

    if req.section == "cron" and type(req.cron) == "table" then
        fs.writefile(cron_cfg_path, json.stringify(req.cron, true))
        local count = apply_crontab(req.cron)
        http.write(json.stringify({ success = true, jobs = count }))
        return
    end

    if req.section == "limits" and type(req.limits) == "table" then
        local gomem = tostring(req.limits.gomemlimit or ""):gsub("%s+", "")
        local gogc = tostring(req.limits.gogc or ""):gsub("%s+", "")
        if gomem == "" or not gomem:match("^[%w]+$") then
            http.write(json.stringify({ success = false, error = "Invalid GOMEMLIMIT (e.g. 65MiB, 128MiB)" }))
            return
        end
        if gogc == "" or not (gogc:match("^%d+$") or gogc == "off") then
            http.write(json.stringify({ success = false, error = "Invalid GOGC (integer or 'off')" }))
            return
        end
        sys.call(string.format("uci set xray_ui.main.gomemlimit='%s' && uci set xray_ui.main.gogc='%s' && uci commit xray_ui", gomem, gogc))
        local restarted = false
        if sys.call("pidof xray >/dev/null 2>&1") == 0 then
            sys.call("/etc/init.d/xray restart >/dev/null 2>&1")
            restarted = true
        end
        http.write(json.stringify({
            success = true,
            restarted = restarted,
            service = get_service_status()
        }))
        return
    end

    if req.section == "logging" then
        local restarted = false
        local new_loglevel = nil
        if req.ping_log ~= nil then
            local pv = req.ping_log and "1" or "0"
            sys.call("uci set xray_ui.main.ping_log_enabled='" .. pv .. "' && uci commit xray_ui")
        end
        if req.xray_log ~= nil then
            local xv = req.xray_log and "1" or "0"
            new_loglevel = req.xray_log and "info" or "error"
            sys.call("uci set xray_ui.main.xray_log_enabled='" .. xv .. "' && uci commit xray_ui")
            local raw_cfg = fs.readfile(cfg_path) or "{}"
            local cfg = json.parse(raw_cfg)
            if type(cfg) == "table" then
                if type(cfg.log) ~= "table" then cfg.log = {} end
                cfg.log.loglevel = new_loglevel
                fs.writefile(cfg_path, json.stringify(cfg, true):gsub("\\/", "/"))
                if sys.call("pidof xray >/dev/null 2>&1") == 0 then
                    sys.call("/etc/init.d/xray restart >/dev/null 2>&1")
                    restarted = true
                end
            end
        end
        local ping_en = (sys.exec("uci -q get xray_ui.main.ping_log_enabled") or "0"):gsub("%s+", "")
        http.write(json.stringify({
            success = true,
            ping_log = (ping_en == "1"),
            xray_log = is_xray_log_enabled(),
            loglevel = new_loglevel,
            restarted = restarted,
            service = get_service_status(),
            config = fs.readfile(cfg_path) or "{}"
        }))
        return
    end

    http.write(json.stringify({ success = false, error = "Unknown section" }))
end
EOF

echo "===> Updating /usr/lib/lua/luci/model/cbi/xray.lua (removing standalone Asset Directory)..."
cat << 'EOF' > /usr/lib/lua/luci/model/cbi/xray.lua
local fs = require "nixio.fs"
local sys = require "luci.sys"

local m = Map("xray_ui", "Xray Core")
local s = m:section(NamedSection, "main", "xray_ui")
s.addremove = false

s:tab("service", "Service")
s:tab("nodes", "Nodes")
s:tab("subs", "Subscriptions")
s:tab("rules", "Rules")
s:tab("config", "Config")

local status = s:taboption("service", DummyValue, "_status")
status.template = "xray_status"

local service_extra = s:taboption("service", DummyValue, "_service_extra")
service_extra.template = "xray_service_extra"

local nodes_ui = s:taboption("nodes", DummyValue, "_nodes")
nodes_ui.template = "xray_nodes"

local subs_ui = s:taboption("subs", DummyValue, "_subs")
subs_ui.template = "xray_subs"

local rules_ui = s:taboption("rules", DummyValue, "_rules")
rules_ui.template = "xray_rules"

local conf = s:taboption("config", TextValue, "_conf")
conf.wrap = "off"
conf.rows = 30
conf.description = "Direct editor for /etc/xray/config.json"
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

echo "===> Updating /usr/lib/lua/luci/view/xray_status.htm (uniform card spacing, move log controls down)..."
cat << 'EOF' > /usr/lib/lua/luci/view/xray_status.htm
<%
    local sys = require "luci.sys"
    local xray_ver = sys.exec("xray version 2>/dev/null | head -n1 | awk '{print $2}'"):gsub("%s+", "")
    if xray_ver == "" then xray_ver = "Unknown" end

    local pid = sys.exec("pidof xray"):gsub("%s+", "")
    local is_running = (pid ~= "")
    if not is_running then pid = "-" end

    local is_enabled = (sys.call("/etc/init.d/xray enabled >/dev/null 2>&1") == 0)
%>
<style>
    .xr-card {
        background: rgba(255, 255, 255, 0.03);
        border: 1px solid rgba(255, 255, 255, 0.12);
        border-radius: 6px;
        padding: 16px;
        margin: 0 0 12px 0 !important;
    }
    .xr-status-line {
        display: flex;
        flex-wrap: wrap;
        gap: 18px;
        align-items: center;
        margin: 12px 0 18px 0;
        font-size: 1.02em;
    }
    .xr-badge {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        padding: 3px 10px;
        border-radius: 4px;
        font-weight: 600;
        font-size: 0.85em;
        letter-spacing: 0.4px;
    }
    .xr-badge-run { background: rgba(76, 175, 80, 0.18); color: #66bb6a; border: 1px solid rgba(76, 175, 80, 0.4); }
    .xr-badge-rule { background: rgba(79, 195, 247, 0.16); color: #4fc3f7; border: 1px solid rgba(79, 195, 247, 0.4); }
    .xr-badge-stop { background: rgba(244, 67, 54, 0.18); color: #ef5350; border: 1px solid rgba(244, 67, 54, 0.4); }
    .xr-badge-idle { background: rgba(158, 158, 158, 0.15); color: #9e9e9e; border: 1px solid rgba(158, 158, 158, 0.3); }
    .xr-controls { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
    .xr-input-row { display: flex; gap: 8px; margin-bottom: 14px; }
    .xr-input-row input { flex: 1; }
    .xr-sub-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
        gap: 10px;
        margin: 10px 0 14px 0;
    }
    .xr-field label { display: block; font-size: 0.8em; opacity: 0.75; margin-bottom: 3px; }
    .xr-field input, .xr-field select { width: 100%; box-sizing: border-box; }
    .xr-drag-handle {
        cursor: grab;
        user-select: none;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        padding: 4px 6px;
        opacity: 0.55;
        transition: opacity 0.15s;
    }
    .xr-drag-handle:hover { opacity: 1; }
    .xr-drag-handle:active { cursor: grabbing; }
    .xr-row-dragging { opacity: 0.35; }
    .xr-row-over-top td { border-top: 2px solid #4fc3f7 !important; }
    .xr-row-over-bottom td { border-bottom: 2px solid #4fc3f7 !important; }
    .xr-chip {
        display: inline-block;
        background: rgba(255, 255, 255, 0.06);
        border: 1px solid rgba(255, 255, 255, 0.14);
        border-radius: 4px;
        padding: 2px 7px;
        margin: 2px 4px 2px 0;
        font-size: 0.84em;
        font-family: monospace;
    }

    /* Ping buttons (fixed rectangle size + 3 blinking dots) */
    .xr-ping-btn {
        width: 78px !important;
        min-width: 78px !important;
        max-width: 78px !important;
        padding-left: 0 !important;
        padding-right: 0 !important;
        box-sizing: border-box !important;
        font-weight: 600 !important;
        display: inline-flex !important;
        align-items: center;
        justify-content: center;
        vertical-align: middle;
        transition: background 0.18s, border-color 0.18s, color 0.18s;
    }
    .xr-ping-all-btn {
        min-width: 82px !important;
        font-weight: 600 !important;
        display: inline-flex !important;
        align-items: center;
        justify-content: center;
        transition: background 0.18s, border-color 0.18s, color 0.18s;
    }
    .xr-ping-unpinged {
        background: rgba(0, 195, 255, 0.22) !important;
        color: #29d9ff !important;
        border: 1px solid #00c8ff !important;
    }
    .xr-ping-unpinged:hover {
        background: rgba(0, 195, 255, 0.36) !important;
    }
    .xr-ping-loading {
        background: rgba(0, 195, 255, 0.16) !important;
        color: #29d9ff !important;
        border: 1px solid #00c8ff !important;
        cursor: wait !important;
    }
    .xr-ping-good {
        background: rgba(0, 230, 118, 0.22) !important;
        color: #00e676 !important;
        border: 1px solid #00e676 !important;
    }
    .xr-ping-good:hover { background: rgba(0, 230, 118, 0.34) !important; }
    .xr-ping-mid {
        background: rgba(255, 234, 0, 0.22) !important;
        color: #ffea00 !important;
        border: 1px solid #ffd600 !important;
    }
    .xr-ping-mid:hover { background: rgba(255, 234, 0, 0.34) !important; }
    .xr-ping-slow {
        background: rgba(255, 145, 0, 0.24) !important;
        color: #ff9100 !important;
        border: 1px solid #ff9100 !important;
    }
    .xr-ping-slow:hover { background: rgba(255, 145, 0, 0.36) !important; }
    .xr-ping-fail {
        background: rgba(255, 23, 68, 0.22) !important;
        color: #ff5252 !important;
        border: 1px solid #ff1744 !important;
    }
    .xr-ping-fail:hover { background: rgba(255, 23, 68, 0.34) !important; }

    .xr-ping-dots {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        gap: 4px;
        height: 1.2em;
    }
    .xr-ping-dots span {
        width: 4px;
        height: 4px;
        border-radius: 50%;
        background: currentColor;
        opacity: 0.22;
        animation: xr-dot-seq 1.05s infinite ease-in-out;
    }
    .xr-ping-dots span:nth-child(2) { animation-delay: 0.22s; }
    .xr-ping-dots span:nth-child(3) { animation-delay: 0.44s; }
    @keyframes xr-dot-seq {
        0%, 80%, 100% { opacity: 0.22; }
        40% { opacity: 1; }
    }

    .xr-ping-opts {
        display: flex;
        flex-wrap: wrap;
        gap: 18px;
        align-items: center;
        margin-top: 8px;
    }
    .xr-ping-opts label {
        display: inline-flex;
        align-items: center;
        gap: 7px;
        cursor: pointer;
        font-size: 0.94em;
        user-select: none;
    }
    .xr-log-box {
        margin-top: 10px;
        margin-bottom: 0;
        background: rgba(0, 0, 0, 0.35);
        border: 1px solid rgba(255, 255, 255, 0.12);
        border-radius: 4px;
        padding: 10px;
        font-family: monospace;
        font-size: 0.82em;
        max-height: 260px;
        overflow-y: auto;
        white-space: pre-wrap;
        word-break: break-all;
        display: none;
    }
    .xr-log-btn-active {
        background: rgba(79, 195, 247, 0.22) !important;
        color: #4fc3f7 !important;
        border: 1px solid #4fc3f7 !important;
    }

    /* Collapsible subscription header */
    .xr-sub-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        flex-wrap: wrap;
        gap: 8px;
        margin-bottom: 10px;
    }
    .xr-sub-toggle {
        display: inline-flex;
        align-items: center;
        gap: 8px;
        cursor: pointer;
        user-select: none;
        padding: 2px 4px;
        border-radius: 4px;
    }
    .xr-sub-toggle:hover {
        background: rgba(255, 255, 255, 0.05);
    }
    .xr-sub-arrow {
        display: inline-block;
        width: 14px;
        text-align: center;
        font-size: 0.9em;
        opacity: 0.8;
    }
    .xr-sub-settings-body {
        padding: 10px 12px;
        margin-bottom: 12px;
        border: 1px solid rgba(255, 255, 255, 0.08);
        border-radius: 4px;
        background: rgba(0, 0, 0, 0.14);
    }
</style>

<div class="cbi-section xr-card">
    <div style="display:flex; justify-content:space-between; align-items:flex-start; flex-wrap:wrap; gap:8px;">
        <h3 style="margin:0;">Xray-core <span style="opacity:0.65; font-weight:normal;">v<%=xray_ver%></span></h3>
        <div style="text-align:right; font-size:0.85em; line-height:1.55;">
            <div><a href="https://github.com/XTLS/Xray-core" target="_blank" rel="noreferrer">https://github.com/XTLS/Xray-core</a></div>
            <div><a href="https://github.com/fahrenheitd99/luci-app-xray-core" target="_blank" rel="noreferrer">https://github.com/fahrenheitd99/luci-app-xray-core</a></div>
        </div>
    </div>

    <div class="xr-status-line">
        <div>
            Status:
            <span id="xr-svc-badge" class="xr-badge <%=is_running and 'xr-badge-run' or 'xr-badge-stop'%>">
                <%=is_running and "RUNNING" or "STOPPED"%>
            </span>
        </div>
        <div>PID: <code id="xr-svc-pid"><%=pid%></code></div>
        <div>Active Outbounds: <strong id="xr-active-profile" style="color:#4fc3f7;">None (Direct)</strong></div>
    </div>

    <div class="xr-controls">
        <button type="button" id="btn-svc-start" class="cbi-button cbi-button-apply" onclick="xrayServiceCtl('start')" <%=is_running and 'disabled' or ''%>>Start</button>
        <button type="button" id="btn-svc-restart" class="cbi-button cbi-button-action" onclick="xrayServiceCtl('restart')" <%=not is_running and 'disabled' or ''%>>Restart</button>
        <button type="button" id="btn-svc-stop" class="cbi-button cbi-button-reset" onclick="xrayServiceCtl('stop')" <%=not is_running and 'disabled' or ''%>>Stop</button>
        <span style="opacity:0.3; margin:0 6px;">|</span>
        <button type="button" id="btn-svc-enable" class="cbi-button cbi-button-save" onclick="xrayServiceCtl('enable')" <%=is_enabled and 'disabled' or ''%>>Enable Autostart</button>
        <button type="button" id="btn-svc-disable" class="cbi-button cbi-button-reset" onclick="xrayServiceCtl('disable')" <%=not is_enabled and 'disabled' or ''%>>Disable Autostart</button>
    </div>

    <hr style="border:none; border-top:1px solid rgba(255,255,255,0.1); margin:16px 0 12px 0;">

    <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px;">
        <strong style="font-size:0.95em;">Ping Settings</strong>
        <span id="xr-ping-settings-status" style="font-size:0.84em;"></span>
    </div>
    <div class="xr-ping-opts">
        <label title="Direct TCP handshake latency">
            <input type="checkbox" id="chk-ping-tcp" onchange="setPingModeSetting('tcp')">
            TCP Ping
        </label>
        <label title="HTTP HEAD request through an isolated proxy instance">
            <input type="checkbox" id="chk-ping-head" checked onchange="setPingModeSetting('head')">
            Via Proxy (HTTP HEAD)
        </label>
        <span style="opacity:0.25;">|</span>
        <label title="Dynamically sort nodes from lowest to highest latency during Ping All">
            <input type="checkbox" id="chk-ping-autosort" onchange="setAutoSortSetting(this.checked)">
            Auto-sort nodes by ping (Ping All)
        </label>
    </div>
</div>
EOF

echo "===> Updating /usr/lib/lua/luci/view/xray_service_extra.htm..."
cat << 'EOF' > /usr/lib/lua/luci/view/xray_service_extra.htm
<style>
    .xr-geo-split {
        display: grid;
        grid-template-columns: 1fr 1fr;
        gap: 12px;
        margin: 0 0 12px 0 !important;
    }
    @media (max-width: 820px) {
        .xr-geo-split { grid-template-columns: 1fr; }
    }
    .xr-geo-split > .xr-card {
        margin: 0 !important;
        display: flex;
        flex-direction: column;
    }
    .xr-geo-dir-wrap {
        display: inline-flex;
        align-items: center;
        gap: 6px;
    }
    .xr-geo-dir-input {
        width: 155px !important;
        min-width: 110px;
        font-family: monospace;
        font-size: 0.86em !important;
        padding: 3px 7px !important;
        height: auto !important;
    }
    .xr-geo-table-wrap {
        max-height: 220px;
        overflow-y: auto;
        margin-top: 8px;
    }
    .xr-cron-row {
        display: grid;
        grid-template-columns: 26px 1fr 200px 150px 36px;
        gap: 8px;
        align-items: center;
        margin-bottom: 8px;
    }
    @media (max-width: 820px) {
        .xr-cron-row { grid-template-columns: 26px 1fr; }
    }
    .xr-cron-row input[type="text"],
    .xr-cron-row select {
        width: 100%;
        box-sizing: border-box;
    }
    .xr-cron-disabled {
        opacity: 0.5;
    }
    .xr-limits-row {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
        gap: 12px;
        align-items: end;
    }
    .xr-logs-bar {
        display: flex;
        flex-wrap: wrap;
        gap: 14px;
        align-items: center;
        justify-content: space-between;
    }
    .xr-logs-checks, .xr-logs-btns {
        display: flex;
        flex-wrap: wrap;
        gap: 12px;
        align-items: center;
    }
    .xr-logs-checks label {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        cursor: pointer;
        user-select: none;
        margin: 0;
        font-size: 0.93em;
    }
</style>

<!-- 1. Geofiles: two equal boxes with inline Asset Directory -->
<div class="xr-geo-split">
    <div class="cbi-section xr-card">
        <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px; margin-bottom:4px;">
            <strong style="font-size:0.95em;">Geofiles (.dat)</strong>
            <div class="xr-geo-dir-wrap">
                <input type="text" id="xr-geo-dir-input" class="cbi-input-text xr-geo-dir-input" value="/usr/bin/" placeholder="/usr/bin/" title="Asset Directory path" onkeydown="if(event.key==='Enter'){event.preventDefault();xrSaveAssetDir();}">
                <button type="button" id="xr-geo-dir-save" class="cbi-button cbi-button-save" style="padding:3px 10px;" onclick="xrSaveAssetDir()">Save</button>
            </div>
        </div>
        <div id="xr-geo-dir-status" style="font-size:0.82em; text-align:right; min-height:0;"></div>
        <div class="xr-geo-table-wrap">
            <table class="table cbi-section-table" style="width:100%; margin-bottom:0;">
                <tr class="tr cbi-section-table-titles">
                    <th class="th">Filename</th>
                    <th class="th" style="width:24%; text-align:right;">Size</th>
                    <th class="th" style="width:32%; text-align:right;">Modified</th>
                </tr>
                <tbody id="xr-geo-files-body">
                    <tr class="tr"><td class="td" colspan="3"><em>Loading...</em></td></tr>
                </tbody>
            </table>
        </div>
    </div>

    <div class="cbi-section xr-card">
        <strong style="font-size:0.95em; margin-bottom:10px; display:block;">Download Geofile</strong>
        <div class="xr-field" style="margin-bottom:10px;">
            <label>File URL</label>
            <input type="text" id="xr-geo-dl-url" class="cbi-input-text" placeholder="https://github.com/.../releases/latest/download/geosite.dat">
        </div>
        <div class="xr-field" style="margin-bottom:12px;">
            <label>Filename</label>
            <input type="text" id="xr-geo-dl-name" class="cbi-input-text" placeholder="geosite.dat">
        </div>
        <div style="display:flex; gap:10px; align-items:center; flex-wrap:wrap; margin-top:auto;">
            <button type="button" id="xr-geo-dl-btn" class="cbi-button cbi-button-apply" onclick="xrDownloadGeofile()">Download</button>
            <span id="xr-geo-dl-status" style="font-size:0.86em;"></span>
        </div>
    </div>
</div>

<!-- 2. Automation (Cron) & Runtime Limits -->
<div class="cbi-section xr-card">
    <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px; margin-bottom:10px;">
        <label style="display:inline-flex; align-items:center; gap:8px; cursor:pointer; font-weight:600; font-size:0.95em; margin:0;">
            <input type="checkbox" id="xr-cron-geo-master" onchange="xrToggleGeoCronMaster(this.checked)">
            Geofile Auto-Update (Cron)
        </label>
        <button type="button" id="xr-cron-geo-add" class="cbi-button cbi-button-add" onclick="xrAddGeoCronRow()">+ Add Geofile</button>
    </div>

    <div id="xr-cron-geo-rows"></div>

    <hr style="border:none; border-top:1px solid rgba(255,255,255,0.1); margin:14px 0;">

    <strong style="font-size:0.95em; display:block; margin-bottom:10px;">Xray Service Schedule &amp; Runtime Limits</strong>

    <div style="display:flex; flex-wrap:wrap; gap:12px; align-items:center; margin-bottom:14px;">
        <label style="display:inline-flex; align-items:center; gap:8px; cursor:pointer; margin:0;">
            <input type="checkbox" id="xr-cron-restart-en" onchange="xrToggleRestartCron(this.checked)">
            Auto-Restart Xray (Cron)
        </label>
        <select id="xr-cron-restart-int" class="cbi-input-select" style="width:180px;">
            <option value="1h">Every 1 hour</option>
            <option value="3h">Every 3 hours</option>
            <option value="6h">Every 6 hours</option>
            <option value="12h">Every 12 hours</option>
            <option value="1d" selected>Every 1 day</option>
            <option value="3d">Every 3 days</option>
            <option value="7d">Every 7 days</option>
            <option value="14d">Every 14 days</option>
            <option value="30d">Every 30 days</option>
        </select>
        <button type="button" id="xr-cron-save-btn" class="cbi-button cbi-button-save" onclick="xrSaveCronSettings()">Save Schedule</button>
        <span id="xr-cron-status" style="font-size:0.86em;"></span>
    </div>

    <hr style="border:none; border-top:1px dashed rgba(255,255,255,0.1); margin:14px 0;">

    <div class="xr-limits-row">
        <div class="xr-field">
            <label>GOMEMLIMIT</label>
            <input type="text" id="xr-lim-mem" class="cbi-input-text" placeholder="65MiB">
        </div>
        <div class="xr-field">
            <label>GOGC</label>
            <input type="text" id="xr-lim-gc" class="cbi-input-text" placeholder="40">
        </div>
        <div style="display:flex; gap:10px; align-items:center;">
            <button type="button" id="xr-lim-save-btn" class="cbi-button cbi-button-save" onclick="xrSaveLimits()">Save Limits</button>
            <span id="xr-lim-status" style="font-size:0.86em;"></span>
        </div>
    </div>
</div>

<!-- 3. Logs (Ping Log + Xray-core Log) -->
<div class="cbi-section xr-card">
    <div class="xr-logs-bar">
        <div class="xr-logs-checks">
            <strong style="font-size:0.95em; margin-right:4px;">Logs</strong>
            <label title="Write ping diagnostics to /tmp/xray_ping.log">
                <input type="checkbox" id="xr-log-ping-en" onchange="xrSetLogToggle('ping', this.checked)">
                Ping Log
            </label>
            <label title="Set Xray loglevel to info (off = error)">
                <input type="checkbox" id="xr-log-xray-en" onchange="xrSetLogToggle('xray', this.checked)">
                Xray-core Log
            </label>
            <span id="xr-log-status" style="font-size:0.84em;"></span>
        </div>

        <div class="xr-logs-btns">
            <button type="button" id="btn-show-ping-log" class="cbi-button cbi-button-action" onclick="xrSwitchLogView('ping')">Show Ping Log</button>
            <button type="button" id="btn-show-xray-log" class="cbi-button cbi-button-action" onclick="xrSwitchLogView('xray')">Show Xray-core Log</button>
            <button type="button" id="btn-refresh-active-log" class="cbi-button cbi-button-neutral" style="display:none;" onclick="xrRefreshActiveLog()">Refresh</button>
            <button type="button" id="btn-clear-ping-log" class="cbi-button cbi-button-reset" style="display:none;" onclick="xrClearActivePingLog()">Clear</button>
        </div>
    </div>
    <pre id="xr-unified-log-box" class="xr-log-box"></pre>
</div>

<script>
(function() {
    let cronState = {
        geo_enabled: false,
        geofiles: [
            { enabled: false, url: '', filename: 'geosite.dat', interval: '7d' },
            { enabled: false, url: '', filename: 'geoip.dat', interval: '7d' }
        ],
        restart_enabled: false,
        restart_interval: '1d'
    };

    let activeLogView = null; // null | 'ping' | 'xray'

    const INTERVAL_OPTIONS = [
        ['1h',  'Every 1 hour'],
        ['3h',  'Every 3 hours'],
        ['6h',  'Every 6 hours'],
        ['12h', 'Every 12 hours'],
        ['1d',  'Every 1 day'],
        ['3d',  'Every 3 days'],
        ['7d',  'Every 7 days'],
        ['14d', 'Every 14 days'],
        ['30d', 'Every 30 days']
    ];

    function xrEsc(s) {
        if (!s) return '';
        return String(s).replace(/[&<>"']/g, function(m) {
            return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[m];
        });
    }

    function fmtSize(bytes) {
        const b = Number(bytes) || 0;
        if (b >= 1048576) return (b / 1048576).toFixed(2) + ' MB';
        if (b >= 1024) return (b / 1024).toFixed(1) + ' KB';
        return b + ' B';
    }

    function fmtMtime(ts) {
        if (!ts) return '-';
        const d = new Date(ts * 1000);
        const pad = n => String(n).padStart(2, '0');
        return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
    }

    function renderGeoFiles(dir, files) {
        const dirInput = document.getElementById('xr-geo-dir-input');
        const tbody = document.getElementById('xr-geo-files-body');
        if (dirInput && dir) dirInput.value = dir;
        if (!tbody) return;
        tbody.innerHTML = '';
        if (!Array.isArray(files) || files.length === 0) {
            tbody.innerHTML = '<tr class="tr"><td class="td" colspan="3"><em>No .dat files found in directory.</em></td></tr>';
            return;
        }
        files.forEach(f => {
            const tr = document.createElement('tr');
            tr.className = 'tr cbi-section-table-row';
            tr.innerHTML = `
                <td class="td"><code>${xrEsc(f.name)}</code></td>
                <td class="td" style="text-align:right; white-space:nowrap;">${xrEsc(fmtSize(f.size))}</td>
                <td class="td" style="text-align:right; white-space:nowrap; opacity:0.8;">${xrEsc(fmtMtime(f.mtime))}</td>
            `;
            tbody.appendChild(tr);
        });
    }

    function loadGeoFiles() {
        fetch('<%=url("admin/services/xray/geo_list")%>')
            .then(r => r.json())
            .then(data => renderGeoFiles(data.dir, data.files))
            .catch(() => renderGeoFiles('/usr/bin/', []));
    }

    window.xrSaveAssetDir = function() {
        const input = document.getElementById('xr-geo-dir-input');
        const btn = document.getElementById('xr-geo-dir-save');
        const st = document.getElementById('xr-geo-dir-status');
        const dir = input ? input.value.trim() : '';

        if (!dir || dir.charAt(0) !== '/') {
            if (st) { st.style.color = '#ef5350'; st.textContent = 'Path must start with /'; }
            return;
        }

        if (btn) btn.disabled = true;
        if (st) { st.style.color = '#4fc3f7'; st.textContent = 'Saving...'; }

        fetch('<%=url("admin/services/xray/service_ext")%>', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ section: 'asset_dir', asset_dir: dir })
        }).then(r => r.json()).then(res => {
            if (res && res.success) {
                renderGeoFiles(res.dir, res.files);
                if (res.service && typeof updateServiceUI === 'function') updateServiceUI(res.service);
                if (st) {
                    st.style.color = '#66bb6a';
                    st.textContent = res.restarted ? 'Saved & Xray restarted' : 'Saved';
                    setTimeout(() => { if (st.textContent === 'Saved' || st.textContent === 'Saved & Xray restarted') st.textContent = ''; }, 2500);
                }
            } else {
                if (st) { st.style.color = '#ef5350'; st.textContent = (res && res.error) ? res.error : 'Save failed'; }
            }
        }).catch(err => {
            if (st) { st.style.color = '#ef5350'; st.textContent = 'Request error: ' + err; }
        }).finally(() => {
            if (btn) btn.disabled = false;
        });
    };

    window.xrDownloadGeofile = function() {
        const urlEl = document.getElementById('xr-geo-dl-url');
        const nameEl = document.getElementById('xr-geo-dl-name');
        const btn = document.getElementById('xr-geo-dl-btn');
        const st = document.getElementById('xr-geo-dl-status');

        const url = urlEl ? urlEl.value.trim() : '';
        const filename = nameEl ? nameEl.value.trim() : '';

        if (!url || !filename) {
            if (st) { st.style.color = '#ef5350'; st.textContent = 'Enter both URL and filename.'; }
            return;
        }

        if (btn) { btn.disabled = true; btn.textContent = 'Downloading...'; }
        if (st) { st.style.color = '#4fc3f7'; st.textContent = 'Running wget...'; }

        fetch('<%=url("admin/services/xray/geo_download")%>', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ url: url, filename: filename })
        }).then(r => r.json()).then(res => {
            if (res && res.files) renderGeoFiles(res.dir, res.files);
            if (res && res.success) {
                if (st) { st.style.color = '#66bb6a'; st.textContent = 'Downloaded: ' + filename; }
            } else {
                if (st) { st.style.color = '#ef5350'; st.textContent = (res && res.error) ? res.error : 'Download failed'; }
            }
        }).catch(err => {
            if (st) { st.style.color = '#ef5350'; st.textContent = 'Request error: ' + err; }
        }).finally(() => {
            if (btn) { btn.disabled = false; btn.textContent = 'Download'; }
        });
    };

    function syncCronStateFromDOM() {
        const master = document.getElementById('xr-cron-geo-master');
        if (master) cronState.geo_enabled = master.checked;

        const rows = document.querySelectorAll('#xr-cron-geo-rows .xr-cron-row');
        const list = [];
        rows.forEach(row => {
            list.push({
                enabled: row.querySelector('.xr-cg-en').checked,
                url: row.querySelector('.xr-cg-url').value.trim(),
                filename: row.querySelector('.xr-cg-name').value.trim(),
                interval: row.querySelector('.xr-cg-int').value
            });
        });
        cronState.geofiles = list;

        const rEn = document.getElementById('xr-cron-restart-en');
        const rInt = document.getElementById('xr-cron-restart-int');
        if (rEn) cronState.restart_enabled = rEn.checked;
        if (rInt) cronState.restart_interval = rInt.value;
    }

    function renderCronUI() {
        const master = document.getElementById('xr-cron-geo-master');
        const addBtn = document.getElementById('xr-cron-geo-add');
        const cont = document.getElementById('xr-cron-geo-rows');
        const enabledMaster = !!cronState.geo_enabled;

        if (master) master.checked = enabledMaster;
        if (addBtn) addBtn.disabled = !enabledMaster;
        if (!cont) return;

        cont.innerHTML = '';
        if (!Array.isArray(cronState.geofiles) || cronState.geofiles.length === 0) {
            cronState.geofiles = [{ enabled: false, url: '', filename: 'geosite.dat', interval: '7d' }];
        }

        cronState.geofiles.forEach((g, idx) => {
            const row = document.createElement('div');
            row.className = 'xr-cron-row' + (enabledMaster ? '' : ' xr-cron-disabled');
            const optsHtml = INTERVAL_OPTIONS.map(o =>
                `<option value="${o[0]}" ${g.interval === o[0] ? 'selected' : ''}>${o[1]}</option>`
            ).join('');

            row.innerHTML = `
                <input type="checkbox" class="xr-cg-en" ${g.enabled ? 'checked' : ''} ${enabledMaster ? '' : 'disabled'}>
                <input type="text" class="cbi-input-text xr-cg-url" value="${xrEsc(g.url || '')}" placeholder="https://.../geosite.dat" ${enabledMaster ? '' : 'disabled'}>
                <input type="text" class="cbi-input-text xr-cg-name" value="${xrEsc(g.filename || '')}" placeholder="geosite.dat" ${enabledMaster ? '' : 'disabled'}>
                <select class="cbi-input-select xr-cg-int" ${enabledMaster ? '' : 'disabled'}>${optsHtml}</select>
                <button type="button" class="cbi-button cbi-button-remove xr-cg-del" title="Remove row" ${enabledMaster ? '' : 'disabled'}>&times;</button>
            `;
            row.querySelector('.xr-cg-del').addEventListener('click', () => {
                syncCronStateFromDOM();
                cronState.geofiles.splice(idx, 1);
                renderCronUI();
            });
            cont.appendChild(row);
        });

        const rEn = document.getElementById('xr-cron-restart-en');
        const rInt = document.getElementById('xr-cron-restart-int');
        if (rEn) rEn.checked = !!cronState.restart_enabled;
        if (rInt) {
            rInt.value = cronState.restart_interval || '1d';
            rInt.disabled = !cronState.restart_enabled;
        }
    }

    window.xrToggleGeoCronMaster = function(checked) {
        syncCronStateFromDOM();
        cronState.geo_enabled = !!checked;
        renderCronUI();
    };

    window.xrAddGeoCronRow = function() {
        syncCronStateFromDOM();
        cronState.geofiles.push({ enabled: true, url: '', filename: '', interval: '7d' });
        renderCronUI();
    };

    window.xrToggleRestartCron = function(checked) {
        const rInt = document.getElementById('xr-cron-restart-int');
        cronState.restart_enabled = !!checked;
        if (rInt) rInt.disabled = !checked;
    };

    window.xrSaveCronSettings = function() {
        syncCronStateFromDOM();
        const btn = document.getElementById('xr-cron-save-btn');
        const st = document.getElementById('xr-cron-status');
        if (btn) btn.disabled = true;
        if (st) { st.style.color = '#4fc3f7'; st.textContent = 'Applying crontab...'; }

        fetch('<%=url("admin/services/xray/service_ext")%>', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ section: 'cron', cron: cronState })
        }).then(r => r.json()).then(res => {
            if (res && res.success) {
                if (st) { st.style.color = '#66bb6a'; st.textContent = `Saved (${res.jobs || 0} active cron jobs)`; }
            } else {
                if (st) { st.style.color = '#ef5350'; st.textContent = (res && res.error) ? res.error : 'Save failed'; }
            }
        }).catch(err => {
            if (st) { st.style.color = '#ef5350'; st.textContent = 'Request error: ' + err; }
        }).finally(() => {
            if (btn) btn.disabled = false;
        });
    };

    window.xrSaveLimits = function() {
        const memEl = document.getElementById('xr-lim-mem');
        const gcEl = document.getElementById('xr-lim-gc');
        const btn = document.getElementById('xr-lim-save-btn');
        const st = document.getElementById('xr-lim-status');

        const gomemlimit = memEl ? memEl.value.trim() : '';
        const gogc = gcEl ? gcEl.value.trim() : '';

        if (btn) btn.disabled = true;
        if (st) { st.style.color = '#4fc3f7'; st.textContent = 'Saving...'; }

        fetch('<%=url("admin/services/xray/service_ext")%>', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ section: 'limits', limits: { gomemlimit: gomemlimit, gogc: gogc } })
        }).then(r => r.json()).then(res => {
            if (res && res.success) {
                if (res.service && typeof updateServiceUI === 'function') updateServiceUI(res.service);
                if (st) {
                    st.style.color = '#66bb6a';
                    st.textContent = res.restarted ? 'Saved & Xray restarted' : 'Saved';
                }
            } else {
                if (st) { st.style.color = '#ef5350'; st.textContent = (res && res.error) ? res.error : 'Save failed'; }
            }
        }).catch(err => {
            if (st) { st.style.color = '#ef5350'; st.textContent = 'Request error: ' + err; }
        }).finally(() => {
            if (btn) btn.disabled = false;
        });
    };

    function updateLogButtonsUI() {
        const bPing = document.getElementById('btn-show-ping-log');
        const bXray = document.getElementById('btn-show-xray-log');
        const bRef = document.getElementById('btn-refresh-active-log');
        const bClr = document.getElementById('btn-clear-ping-log');
        const box = document.getElementById('xr-unified-log-box');

        if (bPing) bPing.classList.toggle('xr-log-btn-active', activeLogView === 'ping');
        if (bXray) bXray.classList.toggle('xr-log-btn-active', activeLogView === 'xray');
        if (bRef) bRef.style.display = activeLogView ? '' : 'none';
        if (bClr) bClr.style.display = (activeLogView === 'ping') ? '' : 'none';
        if (box) box.style.display = activeLogView ? 'block' : 'none';
    }

    window.xrRefreshActiveLog = function() {
        const box = document.getElementById('xr-unified-log-box');
        if (!box || !activeLogView) return;
        const url = (activeLogView === 'xray')
            ? '<%=url("admin/services/xray/xray_log")%>'
            : '<%=url("admin/services/xray/ping_log")%>';
        fetch(url)
            .then(r => r.text())
            .then(txt => {
                const trimmed = (txt || '').trim();
                if (trimmed) {
                    box.textContent = trimmed;
                } else {
                    box.textContent = (activeLogView === 'xray')
                        ? '(No Xray-core log entries)'
                        : '(Ping log is empty)';
                }
                box.scrollTop = box.scrollHeight;
            })
            .catch(err => {
                box.textContent = 'Error loading log: ' + err;
            });
    };

    window.xrSwitchLogView = function(target) {
        if (activeLogView === target) {
            activeLogView = null;
            updateLogButtonsUI();
            return;
        }
        activeLogView = target;
        updateLogButtonsUI();
        xrRefreshActiveLog();
    };

    window.xrClearActivePingLog = function() {
        fetch('<%=url("admin/services/xray/ping_log")%>', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: 'clear=1'
        }).then(() => {
            if (activeLogView === 'ping') {
                const box = document.getElementById('xr-unified-log-box');
                if (box) box.textContent = '(Ping log is empty)';
            }
        });
    };

    window.xrSetLogToggle = function(kind, checked) {
        const st = document.getElementById('xr-log-status');
        const payload = { section: 'logging' };
        if (kind === 'ping') payload.ping_log = !!checked;
        if (kind === 'xray') payload.xray_log = !!checked;

        if (st) { st.style.color = '#4fc3f7'; st.textContent = 'Applying...'; }

        fetch('<%=url("admin/services/xray/service_ext")%>', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        }).then(r => r.json()).then(res => {
            if (res && res.success) {
                if (res.service && typeof updateServiceUI === 'function') updateServiceUI(res.service);
                if (res.config && typeof updateConfigTextarea === 'function') updateConfigTextarea(res.config);
                if (st) {
                    st.style.color = '#66bb6a';
                    if (kind === 'xray') {
                        st.textContent = `loglevel: ${res.loglevel || (checked ? 'info' : 'error')}` + (res.restarted ? ' (restarted)' : '');
                    } else {
                        st.textContent = checked ? 'Ping log enabled' : 'Ping log disabled';
                    }
                    setTimeout(() => { if (st) st.textContent = ''; }, 2500);
                }
                if (activeLogView === 'xray' && kind === 'xray') {
                    setTimeout(xrRefreshActiveLog, 500);
                }
            } else {
                if (st) { st.style.color = '#ef5350'; st.textContent = (res && res.error) ? res.error : 'Failed'; }
            }
        }).catch(err => {
            if (st) { st.style.color = '#ef5350'; st.textContent = 'Request error: ' + err; }
        });
    };

    function loadServiceExt() {
        fetch('<%=url("admin/services/xray/service_ext")%>')
            .then(r => r.json())
            .then(data => {
                if (data && data.asset_dir) {
                    const dirIn = document.getElementById('xr-geo-dir-input');
                    if (dirIn) dirIn.value = data.asset_dir;
                }
                if (data && data.cron) cronState = data.cron;
                renderCronUI();
                if (data && data.limits) {
                    const memEl = document.getElementById('xr-lim-mem');
                    const gcEl = document.getElementById('xr-lim-gc');
                    if (memEl) memEl.value = data.limits.gomemlimit || '65MiB';
                    if (gcEl) gcEl.value = data.limits.gogc || '40';
                }
                if (data && data.logging) {
                    const pChk = document.getElementById('xr-log-ping-en');
                    const xChk = document.getElementById('xr-log-xray-en');
                    if (pChk) pChk.checked = !!data.logging.ping_log;
                    if (xChk) xChk.checked = !!data.logging.xray_log;
                }
            })
            .catch(() => renderCronUI());
    }

    document.addEventListener('DOMContentLoaded', function() {
        loadGeoFiles();
        loadServiceExt();
    });
})();
</script>
EOF

echo "===> Clearing LuCI cache..."
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/ /tmp/luci-uci-cache

echo "===> Service layout & Logs update completed! Refresh LuCI."

lua /usr/libexec/xray-ui-core.lua generate
/etc/init.d/xray restart

echo "===> Clearing LuCI cache..."
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/ /tmp/luci-uci-cache

echo "===> Setup completed! Refresh your LuCI web interface."
