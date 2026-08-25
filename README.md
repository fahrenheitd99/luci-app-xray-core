# LuCI App for Xray Core
---
* This project is not a full-featured multi-protocol proxy client. It is simply a lightweight visual GUI wrapper and management overlay built directly on top of the xray-core daemon.
---
## ❗ Requirements:
* 256MB of RAM or higher
* **OpenWRT 25.X.X**
---
### ⚙️ Backend:
* Uses Transparent Proxy to route your internet traffic into Xray inbounds.
* Uses **xray-core** and **kmod-nft-tproxy** packages that available from OpenWRT repo's.
* Sets GOMEMLIMIT=55MiB and GOGC=20 to trigger the Go's garbage collector to run more frequently. Provides better RAM optimization.

### 🖥️ Frontend:
* Simple interface that provides core management almost without using a terminal.
* Ping all servers direct and through the tunnel.
* Write your xray config right in web interface.

## ⚡ Quick Start:
```Shell
wget -O install.sh "https://raw.githubusercontent.com/fahrenheitd99/luci-app-xray-core/main/luci-app-xray-core.sh" && chmod +x install.sh && ./install.sh
```
*After installation you can delete the **install.sh** script if you want to*

---

**⭐ Sources:**
https://github.com/xtls/xray-core | https://github.com/openwrt/openwrt
