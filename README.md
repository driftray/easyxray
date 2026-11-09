<div align="center">

<pre>
┌─┐┌─┐┌─┐┬ ┬─┐ ┬┬─┐┌─┐┬ ┬
├┤ ├─┤└─┐└┬┘┌┴┬┘├┬┘├─┤└┬┘
└─┘┴ ┴└─┘ ┴ ┴ └─┴└─┴ ┴ ┴
</pre>

**简单、安全的 Xray 服务器管理工具**

改动前自动校验 · 失败自动回滚 · 一个文件管理全部配置

</div>

---

easyxray 是一个用 Bash 编写的 Xray 服务器管理工具：一条命令安装，支持 Reality、Hysteria2、XHTTP 等 5 种协议，用中文菜单管理用户、订阅和 WARP 分流，支持一键更新和备份迁移。

完整说明见 **[使用说明](docs/guide.md)**。

## 特点

- **修改安全**：所有修改先校验，失败不生效；启动失败自动回滚，保留最近 5 份快照。
- **安装与更新安全**：不运行第三方脚本，程序和 Xray 都校验 SHA256。
- **防主动探测**：所有 TCP 端口对外都是同一个 Nginx 网站，Hysteria2 也返回同一个伪装站。
- **多用户与订阅**：每个用户有独立的订阅地址，支持通用订阅和 mihomo 订阅。
- **WARP 分流**：一键开启，直接写 `anthropic`、`openai` 等名称即可添加规则。
- **备份与迁移**：换服务器后沿用原来的用户和密钥，客户端不用重新导入。
- **中文菜单**：所有操作都用数字选择，也都有对应的命令。

## 支持的协议

| 协议 | 传输 | 默认端口 | 推荐安装 |
|---|---|---|:---:|
| VLESS + Reality + Vision | TCP | 443 | ✓ |
| Hysteria2 | UDP | 16384-16402 内随机 | ✓ |
| VLESS + XHTTP + TLS | TCP | 随机 | |
| VLESS + Reality + XHTTP | TCP | 随机 | |
| VLESS + TLS + Vision | TCP | 随机 | |

## 安装前准备

- 一台 VPS：Debian 12+ 或 Ubuntu 22.04+，x86_64 或 arm64，有独立公网 IPv4，暂不支持 NAT 和纯 IPv6。
- 一个解析到这台 VPS 的域名；没有域名时可以用[无域名安装](docs/guide.md#无域名安装)，但不推荐。
- 在云服务商的安全组放行 TCP 80、443 和 UDP 16384-16402；完全安装还需要 TCP 8000-8100。

## 快速开始

```bash
sudo -i
wget -N https://raw.githubusercontent.com/driftray/easyxray/main/install.sh && bash install.sh
```

按菜单选择「推荐安装」，输入域名即可。安装后用 `sudo ezx` 进入管理菜单，常用命令：

```bash
sudo ezx sub      # 查看订阅地址
sudo ezx doctor   # 诊断
sudo ezx update   # 更新
```

## 客户端

| 客户端 | 平台 | 说明 |
|---|---|---|
| [Shadowrocket](https://apps.apple.com/us/app/shadowrocket/id932747118) | iOS、iPadOS、macOS | 在「设置 → TCP」选择较新的 TLS 指纹，例如 `chrome140` |
| [v2rayN](https://github.com/2dust/v2rayN/releases) | Windows、macOS、Linux | 使用默认设置 |
| [FlClash](https://github.com/chen08209/FlClash/releases) | Windows、macOS、Linux、Android | 导入 mihomo 订阅地址 |

sing-box 内核的客户端目前连不上 Reality，详见[客户端设置](docs/guide.md#客户端设置)。

## 文档

- [安装](docs/guide.md#安装)：非交互式安装、无域名安装、从备份恢复
- [客户端设置](docs/guide.md#客户端设置)：Hysteria2 带宽等设置
- [菜单使用说明](docs/guide.md#菜单使用说明)
- [命令参考](docs/guide.md#命令参考)
- [工作原理](docs/guide.md#工作原理) 和 [文件位置](docs/guide.md#文件位置)
- [常见问题](docs/guide.md#常见问题)
- [更新](docs/guide.md#更新) 和 [卸载](docs/guide.md#卸载)

## 许可证

[GPL-3.0](LICENSE)

## 致谢

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)
- [mack-a/v2ray-agent](https://github.com/mack-a/v2ray-agent)：部分设计思路参考自该项目
