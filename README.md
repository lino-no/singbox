# singbox VPS 双栈智能管理脚本

[![GitHub repository](https://img.shields.io/badge/GitHub-lino--no%2Fsingbox-181717?logo=github)](https://github.com/lino-no/singbox)

一个面向 Debian / Ubuntu VPS 的 sing-box 安装与运维脚本。通过 SSH 交互菜单或 `sb` 命令管理代理入站、节点记录、订阅文件、Cloudflare 出站与隧道、证书及日常诊断。
一键脚本
```
bash <(curl -fsSL https://raw.githubusercontent.com/lino-no/singbox/main/sb.sh)

```
```
curl -fsSL https://raw.githubusercontent.com/lino-no/singbox/main/sb.sh -o sb.sh
sudo bash sb.sh install

```

> 项目地址：[github.com/lino-no/singbox](https://github.com/lino-no/singbox)  
> 主脚本：`sb.sh`
## 功能

### 代理入站

脚本可部署以下 sing-box 入站，并把节点连接信息保存到本机：

- VLESS + Reality：双栈、IPv4、IPv6，以及 gRPC 传输模式
- ShadowTLS v3 + Shadowsocks 2022
- Shadowsocks 2022
- Trojan + TLS
- VLESS + TLS
- Hysteria2
- TUIC v5
- AnyTLS
- NaiveProxy
- Snell v5 / v6

新建节点时，脚本会根据所选协议生成配置、校验并应用配置、保存连接 URI，并尝试配置本机防火墙规则。TLS 协议可通过 Certbot 管理证书；Reality 使用握手域名及密钥参数生成客户端连接信息。

Snell 部署要求 sing-box `1.14.0` 或更高版本。生成 sing-box JSON 订阅时，Snell v5 URI 会按当前转换逻辑映射为客户端出站 `version: 4`。

### Cloudflare 与网络

- **Cloudflare Tunnel**：管理 `cloudflared` Tunnel 服务及其配置。
- **Cloudflare WARP**：使用 WARP 客户端的本机 SOCKS 代理作为 sing-box 出站；此模式用于 sing-box 流量，不会接管 VPS 全局路由。
- **双栈检测**：检测 IPv4 / IPv6 路由和公网地址，供入站及出站策略使用。
- **测速**：执行网络延迟、下载和上传测试。

### 节点、订阅与运维

- 查看已部署连接串、二维码和节点状态；复制、编辑、删除节点或修复防火墙规则。
- 生成 sing-box JSON、Clash Meta / Mihomo YAML 及 Base64 通用 URI 订阅文件。
- 可启动带 token 校验的本地订阅 HTTP 服务；服务仅绑定 `127.0.0.1`，可由用户自己的 Nginx / Caddy 反向代理对外提供 HTTPS。
- 提供服务状态、健康检查、系统诊断、日志、配置校验、节点对账、配置备份恢复、证书管理、BBR、核心升级和脚本更新入口。

## 系统要求

- Debian 或 Ubuntu，使用 APT 包管理器。
- systemd 环境。
- Bash 4.3 或更高版本，并以 `root` / `sudo` 运行。
- VPS 能访问系统软件源、sing-box 软件源及所需的外部服务。
- IPv4 或 IPv6 至少一种可用；双栈功能需要服务器和客户端网络都具备相应连通性。

脚本不面向 CentOS / RHEL、Alpine、非 systemd 系统或容器内的受限环境。云厂商控制台中的安全组规则仍需单独配置。

## 安装与启动

```bash
git clone https://github.com/lino-no/singbox.git
cd singbox
sudo bash sb.sh install
sudo sb
```

`install` 会安装基础依赖、配置 sing-box 官方 APT 软件源、安装 sing-box，并建立 `/usr/local/bin/sb` 快捷命令。之后可用 `sudo sb` 打开菜单。

查看命令列表：

```bash
sb --help
```

也可以直接通过脚本运行菜单：

```bash
sudo bash sb.sh
```

## 交互菜单

主菜单分为六个部分：

1. **新建节点**：快速 Reality 部署、各协议入站及 Cloudflare Tunnel。
2. **节点列表**：连接串、二维码、复制、编辑、删除和防火墙修复。
3. **订阅与分发**：生成订阅文件、查看路径、管理本地订阅服务及访问 token。
4. **出站与穿透**：Cloudflare WARP 与 Cloudflare Tunnel。
5. **诊断与测速**：健康检查、系统诊断、节点对账、服务日志、网络测速及服务状态。
6. **系统维护**：证书、BBR、配置备份恢复、安装修复、核心升级、脚本更新、卸载或彻底清除。

快速 Reality 流程会先显示端口、地址、握手域名和节点名摘要，可确认部署或逐项修改。

## 常用命令

```text
sb menu           打开交互菜单
sb install        安装或修复 sing-box 环境
sb reality-dual   部署双栈 VLESS Reality
sb reality-v4     部署 IPv4 VLESS Reality
sb reality-v6     部署 IPv6 VLESS Reality
sb reality-grpc   部署 Reality gRPC
sb naive          部署 NaiveProxy
sb snell          部署 Snell v5/v6
sb links          查看已保存连接串
sb qrcode         查看节点二维码
sb sub            打开订阅管理
sb status         查看服务状态
sb health         执行健康检查
sb diag           执行系统诊断
sb reconcile      对账并检查孤儿节点
sb logs           查看 sing-box 日志
sb upgrade        升级 sing-box
sb rollback       恢复配置备份
sb uninstall      卸载 sing-box，保留配置和数据
sb purge          彻底清除脚本管理的软件、配置和相关数据
```

完整命令及描述以 `sb --help` 输出为准。

## 订阅文件

选择菜单 **订阅与分发 → 生成 / 刷新全部订阅文件** 后，文件位于：

```text
/var/lib/sing-box-vps/subscriptions/sub-singbox.json
/var/lib/sing-box-vps/subscriptions/sub-clash.yaml
/var/lib/sing-box-vps/subscriptions/sub-universal.txt
```

`sub-universal.txt` 是 Base64 编码的 URI 列表。sing-box JSON 和 Clash / Mihomo 输出由脚本把已保存的 URI 转换为相应出站格式；当前转换器无法表达的协议（例如 ShadowTLS 插件 URI）会从这两类输出中排除，但仍会保留在通用 URI 列表中。实际客户端支持范围以客户端本身为准。

本地订阅服务只监听回环地址并要求 token。若要从公网访问，应由反向代理提供 HTTPS，并妥善保护带 token 的订阅地址；不要直接把本地 HTTP 服务暴露到公网。

## 文件与配置位置

| 内容 | 路径 |
|---|---|
| sing-box 主配置 | `/etc/sing-box/config.json` |
| 节点连接记录 | `/var/lib/sing-box-vps/connections.json` |
| 配置备份 | `/var/lib/sing-box-vps/backups/` |
| 订阅文件 | `/var/lib/sing-box-vps/subscriptions/` |
| 脚本操作日志 | `/var/lib/sing-box-vps/sing-box-vps.log` |
| 管理脚本 | `/usr/local/sbin/sing-box-vps` |
| 快捷命令 | `/usr/local/bin/sb` |

配置与连接记录由脚本分别维护：`config.json` 是 sing-box 服务配置，`connections.json` 用于展示连接信息和管理节点。手动改动配置后，可用 `sb check` 校验并重启服务；若配置异常，可从备份恢复。

## 安全与使用提示

- 部署、更新、证书及防火墙操作需要 root 权限。
- 新增或修改配置前会先生成候选配置并校验，通过后再应用；应用失败时会尝试恢复先前配置。
- `sb purge` 会删除脚本管理的软件、配置、证书或数据，执行前会再次确认；云厂商安全组规则不会由脚本清除。
- 使用 TLS 入站前，请确保域名解析指向 VPS，并满足证书申请所需的网络条件。遇到端口冲突时，可在部署提示中更换端口。
- 防火墙自动配置不能替代云平台安全组设置。按协议开放 TCP 或 UDP 端口，并确认客户端网络可达。
- SSH 剪贴板复制依赖终端支持 OSC 52；若终端不支持，可选择显示完整连接串。窄终端下二维码可能不绘制字符图，但脚本仍会保存二维码 PNG。
- 发布前需把 `sb.sh` 顶部的仓库标记和 `SCRIPT_UPDATE_URL` 一并改为本仓库地址 `https://github.com/lino-no/singbox` 与 `https://raw.githubusercontent.com/lino-no/singbox/main/sb.sh`；当前脚本仍保留旧仓库地址，未同步前 `sb self-update` 可能从旧地址获取文件。

## 故障排查

```bash
sb status       # sing-box 版本、网络栈、服务及入站概况
sb health       # sing-box 配置和服务健康检查
sb diag         # 端口、DNS、防火墙、隧道等诊断
sb logs         # 最近的 sing-box 服务日志
sb check        # 校验配置并重启服务
sb reconcile    # 对账配置中的入站与节点记录
```

如果服务未启动，先运行 `sb check`，然后查看 `sb logs`。若诊断显示监听或防火墙异常，同时检查 VPS 本机防火墙和云厂商安全组。

## 项目说明

- GitHub：[lino-no/singbox](https://github.com/lino-no/singbox)
- 主程序：Bash 脚本 `sb.sh`
- 管理核心：sing-box
- 目标平台：Debian / Ubuntu VPS

提交问题时，请附上操作系统版本、`sb --help` 输出、相关命令、脱敏后的诊断信息和错误日志。不要公开节点 URI、密码、PSK、私钥、订阅 token 或 Cloudflare 凭据。

