# xray-manager

Xray 一键安装与管理脚本：多协议多节点、落地分流、配置导出，兼容 Alpine。

## 特性

- **12 种节点**：VLESS（REALITY / XHTTP / Vision / TLS / 后量子 Encryption / WebSocket）、VMess、Trojan、Shadowsocks 2022、Hysteria2、SOCKS5/HTTP、端口转发
- **每个节点独立入站**：端口、监听地址、UUID/密码、SNI、路径、密钥、证书都能随时修改；NAT 机可单独设置分享链接的连接地址和外部端口
- **多用户**：同一节点可添加多个用户，每个用户可以走不同的落地
- **落地管理**：粘贴分享链接导入，或手动添加 SOCKS5 / HTTP / Shadowsocks / WireGuard，或自动注册 Cloudflare WARP；支持按节点、按用户、按域名分流，全局默认出口，链式代理，出口 IP 测试
- **分流规则**：一键屏蔽私有地址 / BT / 广告 / 中国大陆；ChatGPT、Netflix、YouTube 等一键分流到指定落地
- **系统兼容**：Alpine（OpenRC + BusyBox）、Debian / Ubuntu、CentOS / RHEL / Rocky / Alma、Fedora、Arch、openSUSE；systemd、OpenRC、无 init 的容器环境均可运行
- **内核管理**：直接从 GitHub Releases 下载并校验 SHA256，可选最新正式版 / 预发布版 / 指定版本；国内机器可配置 GitHub 加速前缀
- **安全修改**：每次改动先用 `xray run -test` 校验，启动失败自动回滚到修改前的配置；自动放行防火墙端口（ufw / firewalld / iptables）
- **其他**：分享链接、二维码、base64 订阅、mihomo（Clash Meta）配置导出，流量统计，BBR，备份与恢复，geo 规则每周自动更新

## 一键安装

需要 root 权限。

**Debian / Ubuntu / CentOS 等**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/l1uz3/xray-manager/main/install.sh)
```

**Alpine**（系统默认没有 bash，脚本会自动安装 bash、curl、jq 等依赖）

```sh
wget -O install.sh https://raw.githubusercontent.com/l1uz3/xray-manager/main/install.sh && sh install.sh
```

**国内机器**（GitHub 访问不畅时）

```bash
bash <(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/l1uz3/xray-manager/main/install.sh)
```

进入菜单后，在 `系统工具 → 脚本设置 → GitHub 下载加速前缀` 填入同样的前缀，之后下载内核、geo 文件、更新脚本都会走加速。

> [!NOTE]
> 加速站点是第三方服务，可以换成任何你信任的 GitHub 代理。

> [!WARNING]
> 不要用 `curl ... | bash` 的方式运行。交互菜单需要从终端读取输入，这种方式会导致菜单无法使用。

安装完成后，用快捷命令 `xr` 随时打开菜单。

## 菜单

```
 1. 安装 / 更新 Xray 内核
 2. 添加节点
 3. 查看节点 / 分享链接
 4. 管理节点 (端口 / 用户 / 参数 / 落地 / 删除)
 5. 落地 / 出站管理
 6. 分流规则
 7. 服务管理 (启停 / 状态 / 日志)
 8. 系统工具 (BBR / 流量统计 / 备份 / 设置)
 9. 卸载
 0. 退出
```

## 节点类型

| # | 类型 | 需要域名 | 说明 |
|---|---|---|---|
| 1 | VLESS + Vision + REALITY | 否 | 推荐，直连首选 |
| 2 | VLESS + XHTTP + REALITY | 否 | 可选开启 VLESS Encryption（后量子加密） |
| 3 | VLESS + XHTTP + TLS | 是，或由 Nginx/CDN 反代 | 可套 CDN |
| 4 | VLESS + Vision + TLS | 是 | 可设置回落 |
| 5 | VLESS + Encryption | 否 | 后量子加密、无需证书，适合中转 ↔ 落地之间使用 |
| 6 | VLESS + WebSocket | 是，或由 Nginx/CDN 反代 | 兼容老客户端 |
| 7 | VMess + WebSocket | 是，或由 Nginx/CDN 反代 | 兼容老客户端 |
| 8 | Trojan | REALITY 不需要 / TLS 需要 | |
| 9 | Shadowsocks | 否 | 2022-blake3 系列与 AEAD 系列 |
| 10 | Hysteria2 | 否（可用自签证书） | UDP/QUIC，可选 Salamander 混淆和伪装网站 |
| 11 | SOCKS5 / HTTP | 否 | 同一端口同时支持两种代理 |
| 12 | 端口转发 | 否 | 本机端口 → 远端地址:端口 |

需要证书的节点支持四种来源：自签证书、ACME 申请（HTTP 验证）、ACME 申请（Cloudflare DNS API，适合 80 端口不可用的 NAT 机）、已有证书文件。ACME 证书由 acme.sh 自动续期。

## 修改节点

在 `管理节点` 中选择节点后可以修改：

- 端口、监听地址、名称
- 出站 / 落地
- 用户（添加、删除、修改凭证、为单个用户指定落地）
- 协议参数：REALITY 目标网站 / shortId / 密钥对 / ML-DSA-65，XHTTP 路径与模式，TLS 证书，VLESS Encryption，SS 加密方式，Hysteria2 混淆与伪装网站，SOCKS 认证与 UDP，端口转发目标，流量嗅探
- 分享链接参数：连接地址（如 CDN 优选 IP）、NAT 外部端口、TLS 指纹、SNI、Host

也可以直接用命令行改端口：

```bash
xr port <节点名> <新端口>
```

## 落地与分流

### 添加落地

`落地 / 出站管理 → 添加落地`，支持：

- 粘贴分享链接：`vless://`、`vmess://`、`trojan://`、`ss://`、`socks://`、`http(s)://`、`hysteria2://`
- 手动填写 SOCKS5、HTTP/HTTPS、Shadowsocks、WireGuard
- 自动注册 Cloudflare WARP（常用于解锁流媒体、AI 服务或获得 IPv6 出站）

添加后可以用"测试落地出口"查看出口 IP 和地区（不影响正在运行的服务）。

### 规则优先级

```
屏蔽规则 > 自定义分流规则 > 用户落地 > 节点落地 > 全局默认出口
```

没有单独设置出站的节点和用户都走全局默认出口（默认直连）。

### 示例：中转 + 落地

1. 落地机：添加 `VLESS + Encryption`（或 Shadowsocks 2022）节点，复制分享链接。
2. 中转机：`落地 / 出站管理 → 添加落地 → 粘贴分享链接`。
3. 中转机：在对外节点的"设置出站 / 落地"中选择刚添加的落地。

只想纯转发时，也可以在中转机上添加 `端口转发` 节点，把本机端口直接转发到落地机。

### 示例：ChatGPT 走落地

`分流规则 → 添加分流规则 → AI 服务`，出口选择对应的落地即可。

## 命令行

| 命令 | 说明 |
|---|---|
| `xr` | 打开交互菜单 |
| `xr install [版本]` | 安装 / 更新 Xray 内核（默认最新正式版） |
| `xr add` | 添加节点 |
| `xr list` | 列出节点 |
| `xr info <节点名>` | 查看节点详情和分享链接 |
| `xr links [节点名]` | 只输出分享链接，便于复制或管道处理 |
| `xr mihomo [节点名]` | 输出 mihomo（Clash Meta）节点配置，REALITY 节点已带 `support-x25519mlkem768: true` |
| `xr port <节点名> <端口>` | 修改节点端口 |
| `xr start / stop / restart / status` | 服务控制 |
| `xr log` | 实时查看日志 |
| `xr test` | 校验配置文件 |
| `xr stats [reset]` | 查看流量统计 |
| `xr update-geo` | 更新 geo 规则文件 |
| `xr bbr` | 开启 BBR |
| `xr backup` | 备份配置 |
| `xr uninstall` | 卸载 |

## 文件位置

| 路径 | 说明 |
|---|---|
| `/usr/local/bin/xray` | Xray 内核 |
| `/usr/local/etc/xray/config.json` | Xray 配置 |
| `/usr/local/etc/xray-script/` | 脚本数据：`meta.json`（客户端参数）、`links.txt`（分享链接）、`certs/`、`backup/` |
| `/usr/local/share/xray/` | geoip.dat / geosite.dat |
| `/var/log/xray/` | 日志 |
| `/usr/local/bin/xr` | 快捷命令 |

## 兼容性说明

- 已在 Xray **v26.3.27（正式版）** 和 **v26.9.9（预发布版）** 上实测全部节点类型的连通性。官方文档已改用 `users`、`method` 等新字段名，但 v26.3.x 不识别这些字段，脚本统一写入两个版本都能识别的字段。
- Xray v26.9 起，freedom 出站默认阻止来自 VLESS / VMess / Trojan / Shadowsocks / Hysteria 入站的流量访问内网地址。如需通过代理访问服务器内网，在分流规则中关闭"屏蔽私有地址"，脚本会同时写入放行规则。
- Xray 已移除 `allowInsecure`。自签证书节点的分享链接会携带证书指纹（`pcs` / `pinSHA256`）：v2rayN ≥ 7.22.5、v2rayNG ≥ 2.0.12 等使用新版 Xray 内核的客户端可以直接使用，其他客户端需要手动开启"跳过证书验证"。
- REALITY 目标域名含 apple / icloud / microsoft 或以 .ru / .ir / .cn 结尾，以及 REALITY 使用非 443 端口时，Xray 会给出"更容易被封锁"的警告，脚本在添加节点时也会提示。
- WebSocket、VMess、Trojan、Shadowsocks 在新版 Xray 中会打印弃用警告，但仍可正常使用；新部署建议优先选择 REALITY 或 XHTTP。
- VLESS Encryption 需要客户端 Xray 内核 ≥ 25.8。
- **预发布版 v26.9 起**，REALITY 服务端会拒绝不带 X25519MLKEM768（后量子混合密钥交换）的连接：旧版客户端或非 chrome 指纹会连不上，服务端日志显示 `REALITY: processed invalid connection ... authentication failed or validation criteria not met`。遇到时把客户端更新到最新版并使用 chrome 指纹，或把服务端换成正式版：`xr install v26.3.27`。
- **mihomo（Clash Meta）用户注意**：mihomo 默认会从握手中去掉 X25519MLKEM768，而分享链接无法携带开启它的参数，所以用 vless:// 链接导入的 REALITY 节点连不上 v26.9 以后的服务端。请用 `xr mihomo`（或菜单 `3 → m`）导出的配置，里面已加上 `support-x25519mlkem768: true` 和 `client-fingerprint: chrome`；已在 mihomo v1.19.31 上实测通过。

## 卸载

主菜单 `9. 卸载`，或执行：

```bash
xr uninstall
```

会删除 Xray 内核与服务、配置、脚本数据（含证书和备份）、日志和快捷命令；BBR 设置可选择保留。

## 许可

[MIT License](LICENSE)
