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

easyxray 是一个用 Bash 编写的 Xray-core 服务器管理工具。一条命令完成证书申请、Xray 安装、伪装站点、防火墙和 BBR，之后通过中文菜单或命令管理用户、协议、订阅、WARP 分流和屏蔽规则，并支持备份迁移到新服务器。

## 目录

- [特点](#特点)
- [支持的协议](#支持的协议)
- [安装前准备](#安装前准备)
- [安装](#安装)
  - [交互式安装](#交互式安装)
  - [非交互式安装](#非交互式安装)
  - [手动安装](#手动安装)
  - [从备份恢复](#从备份恢复)
- [客户端设置](#客户端设置)
  - [推荐客户端](#推荐客户端)
- [菜单使用说明](#菜单使用说明)
- [命令参考](#命令参考)
- [工作原理](#工作原理)
- [文件位置](#文件位置)
- [常见问题](#常见问题)
- [更新](#更新)
- [卸载](#卸载)
- [许可证](#许可证)

## 特点

- **修改安全**：所有修改先经过 `xray run -test` 和 `nginx -t` 校验，通过后才替换；替换后服务启动失败或端口没有监听，自动恢复到上一份配置。保留最近 5 份快照，可以随时回滚。
- **安装与更新安全**：不运行第三方安装脚本或二进制。easyxray 自身从本仓库的 GitHub Release 下载并校验 SHA256；证书使用系统软件源中的 `certbot`；Xray 从官方 GitHub Release 下载，并用官方 `.dgst` 文件校验 SHA256；geo 数据与 Xray 官方发布包同源，校验 SHA256 并确认当前规则可用后才替换；WARP 直接调用 Cloudflare 的注册接口。
- **运行安全**：Xray 以专用的 `easyxray` 用户运行，只授予监听低端口和创建 WARP 网卡两项权限。状态文件和证书私钥只有 root 和服务用户可读。系统的 MPTCP 默认关闭，Xray 不低于安全版本 v26.10.31（见 [XTLS/Xray-core#7291](https://github.com/XTLS/Xray-core/pull/7291)）。
- **防主动探测**：所有 TCP 端口对外都表现为同一个 Nginx 网站，使用同一张证书，同样支持 HTTP/2。Reality 未通过认证的连接转给本机 Nginx；XHTTP-TLS 由 Nginx 处理 TLS 后转发给 Xray；VLESS-TLS-Vision 按协商结果回落到 Nginx。
- **少暴露端口**：推荐安装只启用两个协议。除 Reality-Vision 固定使用 443 外，其他协议的端口在指定范围内随机选择。
- **独立的密钥**：Reality 密钥、shortId、XHTTP 路径和 Hysteria2 混淆密码都在安装时随机生成，怀疑泄露时可以随时重新生成。
- **多用户**：用户以邮箱区分，每个用户有独立的订阅地址。
- **WARP 分流**：一键开启 WARP，默认将 `geosite:cn`、`geoip:cn` 分流到 WARP。添加规则时直接写 `anthropic`、`openai` 等名称即可，会自动在 geosite 列表中查找。geo 数据每周自动更新。
- **屏蔽 BT**：默认屏蔽 BT 下载，避免 VPS 收到版权投诉。
- **备份与迁移**：一条命令导出备份，在新服务器上恢复后沿用原来的用户和密钥，客户端不用重新导入。
- **中文菜单**：所有操作都用数字选择，删除前需要确认。

## 支持的协议

| 编号 | 协议 | 传输 | 默认端口 | 推荐安装 | 适用场景 |
|---|---|---|---|:---:|---|
| 1 | VLESS + Reality + Vision | TCP | 443 | ✓ | 日常使用，速度快、CPU 占用低 |
| 2 | Hysteria2 + Salamander 混淆 | UDP | 随机 | ✓ | 丢包较多或 UDP 表现更好的线路 |
| 3 | VLESS + XHTTP + TLS | TCP | 随机 | | 备用 |
| 4 | VLESS + Reality + XHTTP | TCP | 随机 | | 备用 |
| 5 | VLESS + TLS + Vision | TCP | 随机 | | 备用 |

随机端口默认在 `8000-8100` 范围内选择空闲端口，选定后固定不变。XHTTP-TLS 的端口由 Nginx 监听，XHTTP 路径转发给 Xray，其他路径返回伪装站点。

## 安装前准备

1. **一台 VPS**：Debian 12+ 或 Ubuntu 22.04+，x86_64 或 arm64，可以使用 root，有独立的公网 IPv4。暂不支持：
   - **NAT VPS**（多台共用一个公网 IPv4，只分配部分转发端口）：申请证书需要 80 端口，Reality-Vision 需要 443 端口。
   - **纯 IPv6 VPS**：GitHub 不支持 IPv6，无法下载 easyxray 和 Xray。
2. **一个域名**：A 记录解析到这台 VPS 的公网 IP。
3. **在云服务商的安全组中放行端口**：

   | 协议 | 端口 | 用途 |
   |---|---|---|
   | TCP | 80 | 申请和续期证书 |
   | TCP | 443 | Reality-Vision |
   | TCP 和 UDP | 8000-8100 | 其他协议（安装完成后可以只保留实际使用的端口） |

   系统自带的防火墙（ufw / firewalld / iptables）由 easyxray 自动配置。

4. **服务器上没有安装其他代理管理脚本或面板**，以免端口和证书冲突。

## 安装

以 root 身份下载并运行安装脚本 `install.sh`：

```bash
sudo -i
wget -N https://raw.githubusercontent.com/driftray/easyxray/main/install.sh && bash install.sh
```

已经是 root 时不需要 `sudo -i`。没有 wget 时用 curl：

```bash
curl -fsSLO https://raw.githubusercontent.com/driftray/easyxray/main/install.sh && bash install.sh
```

以后每次都可以用同一条命令：没有安装时进行安装，已经安装时进入管理菜单，有新版本时会提示。安装完成后也可以直接使用 `easyxray` 或快捷命令 `ezx`，下文以 `ezx` 为例。

安装脚本先检查环境，有问题时列出后停止；全部通过后从 GitHub Release 下载程序包，校验 SHA256 后开始安装：

```
检查环境
  ✓ root 权限
  ✓ 系统 Debian 12+ / Ubuntu 22.04+
  ✓ CPU 架构 x86_64 / arm64
  ✓ systemd
  ✓ 没有发现其他代理脚本或面板
  ✓ TCP 443 空闲（Reality-Vision）
  ✓ TCP 80 可用（申请证书）
  ✓ IPv4 网络
  ✓ 磁盘剩余空间 ≥ 300 MB
  ✓ 下载工具 curl
  ✓ 可以访问 github.com

下载 easyxray
  ✓ SHA256 校验通过
  ✓ 已解压到 /opt/easyxray
```

安装过程依次完成：安装软件包 → 下载并校验 Xray → 申请证书 → 开启 BBR → 配置日志轮转 → 生成配置并启动服务。完成后显示各协议的端口、需要在安全组放行的端口，以及第一个用户的订阅地址和二维码。

证书由 Let's Encrypt 签发，安装即表示同意其[服务条款](https://letsencrypt.org/repository/)。安装中途失败时，按提示处理后重新运行同一条命令即可继续，已生成的密钥、端口和用户会保留。

### 交互式安装

不带参数运行 `bash install.sh`，环境检查和下载完成后进入安装菜单：

```
╭────────────────────────────────────────────────────────
│
│   ┌─┐┌─┐┌─┐┬ ┬─┐ ┬┬─┐┌─┐┬ ┬
│   ├┤ ├─┤└─┐└┬┘┌┴┬┘├┬┘├─┤└┬┘   v0.5.0
│   └─┘┴ ┴└─┘ ┴ ┴ └─┴└─┴ ┴ ┴
│   简单、安全的 Xray 服务器管理工具
│   改动前自动校验 · 失败自动回滚 · 一个文件管理全部配置
│
├────────────────────────────────────────────────────────
│ 还没有安装，请选择安装方式：
├────────────────────────────────────────────────────────
│ 1  推荐安装
│    Reality-Vision + Hysteria2，暴露的端口最少
│ 2  完全安装
│    全部 5 个协议
│ 0  退出
╰────────────────────────────────────────────────────────
```

选择 1 或 2，按提示输入域名和第一个用户的邮箱（直接回车自动生成）即可。

### 非交互式安装

在 `install.sh` 后面加上安装参数，全程不提问，适合自动化部署：

```bash
# 推荐安装：Reality-Vision + Hysteria2
bash install.sh --domain box.example.com

# 完全安装：全部 5 个协议，并指定第一个用户的邮箱
bash install.sh --domain box.example.com --full --email alice@example.com

# 不保存脚本，下载后直接运行
curl -fsSL https://raw.githubusercontent.com/driftray/easyxray/main/install.sh | bash -s -- --domain box.example.com --full
```

| 参数 | 说明 |
|---|---|
| `--domain 域名` | 必填，已解析到本机的域名 |
| `--full` | 安装全部 5 个协议 |
| `--protocols a,b` | 指定要安装的协议，例如 `--protocols reality-vision,xhttp-tls`，必须包含 `reality-vision` |
| `--port-range 起-止` | 随机端口的范围，默认 `8000-8100` |
| `--email 邮箱` | 第一个用户的邮箱，不填时自动生成 `随机前缀@xray.fake` |
| `--version 版本` | 安装指定版本，例如 `--version v0.2.0`，不填时安装最新版本 |
| `--restore 备份文件` | 从备份恢复，见[从备份恢复](#从备份恢复) |

已经安装时带参数运行只会提示已安装，不会重复安装。

### 手动安装

想自己完成每一步，可以不使用安装脚本：

```bash
sudo -i
apt-get update && apt-get install -y curl ca-certificates
mkdir -p /opt/easyxray && cd /opt/easyxray
curl -fLO https://github.com/driftray/easyxray/releases/latest/download/easyxray.tar.gz
curl -fLO https://github.com/driftray/easyxray/releases/latest/download/easyxray.tar.gz.sha256
sha256sum -c easyxray.tar.gz.sha256 && tar -xzf easyxray.tar.gz && rm -f easyxray.tar.gz*
/opt/easyxray/easyxray
```

### 从备份恢复

换服务器时，先在旧服务器上导出备份（菜单「8 备份与回滚 → 2 导出备份」，或 `ezx backup`），把备份文件复制到新服务器，再把域名解析到新服务器的 IP，然后运行：

```bash
bash install.sh --restore /root/easyxray-backup-20261027-120000.tar.gz
```

也可以不带参数运行 `bash install.sh`，在安装菜单中选择「3 从备份恢复」。恢复后沿用原来的用户、密钥、端口和分流规则，证书在新服务器上重新申请，客户端不需要重新导入订阅。

备份文件包含全部用户和密钥，请妥善保管。

## 客户端设置

查看订阅地址：

```bash
sudo ezx sub
```

将订阅地址导入客户端。节点名称格式为「用户名_协议名」，例如 `alice_Reality-Vision`。

### 推荐客户端

| 客户端 | 平台 | 获取 | 设置 |
|---|---|---|---|
| Shadowrocket | iOS、iPadOS、macOS（Apple 芯片） | [App Store](https://apps.apple.com/us/app/shadowrocket/id932747118)（付费，需非中国大陆区账号） | 在「设置 → TCP」中选择支持 X25519MLKEM768 的较新 TLS 指纹，例如 `chrome140`、`safari26_3` |
| v2rayN | Windows、macOS、Linux | [GitHub](https://github.com/2dust/v2rayN/releases) | 使用默认设置 |

Clash（mihomo）和 sing-box 内核的客户端（如 Clash Verge、FlClash、Hiddify、Karing）目前还不支持 Xray 26.9.8 起 Reality 要求的 X25519MLKEM768，暂时无法连接 Reality-Vision 和 Reality-XHTTP，可以改用 Hysteria2、XHTTP-TLS 或 VLESS-TLS-Vision。

使用 Hysteria2 节点时，在客户端中按自己宽带的实际速度填写上行 / 下行带宽，下行建议填实测下载速度的 80%~90%。

## 菜单使用说明

运行 `sudo ezx` 进入主菜单：

```
╭────────────────────────────────────────────────────────
│
│   ┌─┐┌─┐┌─┐┬ ┬─┐ ┬┬─┐┌─┐┬ ┬
│   ├┤ ├─┤└─┐└┬┘┌┴┬┘├┬┘├─┤└┬┘   v0.5.0
│   └─┘┴ ┴└─┘ ┴ ┴ └─┴└─┴ ┴ ┴
│   简单、安全的 Xray 服务器管理工具
│   改动前自动校验 · 失败自动回滚 · 一个文件管理全部配置
│
├────────────────────────────────────────────────────────
│ 域名   box.example.com
│ 状态   ● Xray v26.10.31 运行中    用户 1    ● WARP 已开启
├────────────────────────────────────────────────────────
│ ● Reality-Vision      TCP 443
│ ● Hysteria2           UDP 8042
│ ○ XHTTP-TLS           未开启
│ ○ Reality-XHTTP       未开启
│ ○ VLESS-TLS-Vision    未开启
├────────────────────────────────────────────────────────
│ 1  查看订阅            2  用户管理
│ 3  协议管理            4  分流与屏蔽管理
│ 5  诊断                6  版本更新
│ 7  调试日志            8  备份与回滚
│ 9  卸载                0  退出
╰────────────────────────────────────────────────────────
```

在所有子菜单中，输入 0 或直接回车返回上一级。

### 1. 查看订阅

显示每个用户的订阅地址、二维码和各协议的分享链接。订阅地址格式为 `https://你的域名/s/随机令牌`，每个用户的令牌不同。

### 2. 用户管理

```
│ 用户管理
├────────────────────────────────────────────────────────
│ 1  alice@example.com
│ 2  k7f3q9x2@xray.fake
├────────────────────────────────────────────────────────
│ 1  添加用户            2  删除用户
│ 3  查看某个用户的订阅  0  返回
```

| 选项 | 说明 |
|---|---|
| 1 添加用户 | 输入邮箱，直接回车则自动生成 `随机前缀@xray.fake`，添加后显示该用户的订阅 |
| 2 删除用户 | 输入用户编号并确认，该用户从所有协议中删除，订阅地址同时失效。至少保留一个用户 |
| 3 查看某个用户的订阅 | 输入用户编号，只显示该用户的订阅 |

### 3. 协议管理

```
│ 协议管理
├────────────────────────────────────────────────────────
│ 1  ● Reality-Vision      TCP 443
│ 2  ● Hysteria2           UDP 8042
│ 3  ○ XHTTP-TLS           未开启
│ 4  ○ Reality-XHTTP       未开启
│ 5  ○ VLESS-TLS-Vision    未开启
│ 6  重新生成所有协议的密钥
│ 0  返回
```

输入 1-5 开启或关闭对应协议，输入 6 重新生成密钥。

- 首次开启时自动分配端口并生成密钥；关闭后再开启，沿用原来的端口和密钥。
- Reality-Vision 不能关闭。
- 开启新协议后，在云服务商的安全组中放行它的端口，然后在客户端中更新订阅。
- 重新生成密钥会更换 Reality 密钥和 shortId、XHTTP 路径、Hysteria2 混淆密码，旧的分享链接全部失效。端口、用户和订阅地址不变，客户端更新订阅即可。怀疑分享链接泄露时使用。

### 4. 分流与屏蔽管理

```
│ 分流与屏蔽管理
├────────────────────────────────────────────────────────
│ ● WARP 已开启
│    1  geosite:anthropic
│    2  geosite:cn
│    3  geoip:cn
├────────────────────────────────────────────────────────
│ 1  关闭 WARP           2  添加 WARP 规则
│ 3  删除 WARP 规则      4  直连 / 屏蔽规则
│ 5  QUIC 屏蔽：关       6  BT 屏蔽：开
│ 0  返回
```

| 选项 | 说明 |
|---|---|
| 1 开启 / 关闭 WARP | 开启时注册一个免费的 WARP 设备（不需要 Cloudflare 账号），并默认将 `geosite:cn`、`geoip:cn` 分流到 WARP。关闭时删除 WARP 出口和所有 WARP 规则，需要确认 |
| 2 添加 WARP 规则 | 输入规则，多个用逗号分隔，写法见下表 |
| 3 删除 WARP 规则 | 输入列表中的编号，可以一次删除多条，例如 `1,3` |
| 4 直连 / 屏蔽规则 | 添加或删除走直连、或直接屏蔽的规则，写法相同 |
| 5 QUIC 屏蔽 | 屏蔽 UDP 443，让浏览器改用 TCP 访问网站 |
| 6 BT 屏蔽 | 默认开启，屏蔽 BT 下载。只能识别未加密的 BT 流量 |

规则写法：

| 写法 | 含义 |
|---|---|
| `anthropic`、`openai`、`netflix` | geosite 分类，自动在 geosite 列表中查找，不存在时提示 |
| `example.com` | 该域名及其所有子域名 |
| `1.2.3.0/24` | IP 段 |
| `geoip:cn`、`full:www.example.com` | 带前缀的写法，原样使用 |

### 5. 诊断

一次检查以下项目，每项显示「正常 / 注意 / 有问题」：

- Xray、Nginx 的运行状态和版本
- 各协议端口是否由 Xray 监听
- BBR、MPTCP、系统防火墙
- 证书剩余天数、日志级别和日志占用空间
- WARP 和 QUIC 屏蔽状态
- Xray 配置与状态文件是否一致

### 6. 版本更新

显示 easyxray、Xray 和 geo 数据的版本。

| 选项 | 说明 |
|---|---|
| 1 更新 easyxray | 更新到最新发布版本，见[更新](#更新) |
| 2 更新 Xray | 更新到 Xray 最新正式版（不包括预发布版本）。新装时也安装最新正式版 |
| 3 Xray 换到指定版本 | 输入版本号，不能低于安全版本 v26.10.31 |
| 4 更新 geo 数据 | 从 [XTLS/Xray-rules-dat](https://github.com/XTLS/Xray-rules-dat)（与 Xray 官方发布包相同的来源）下载 geoip / geosite 数据，校验 SHA256 并确认当前规则可用后替换 |
| 5 geo 自动更新 | 默认开启，每周日凌晨自动更新一次 |

切换 Xray 前备份当前的 Xray；新版本无法加载当前配置时，自动换回原来的版本。

### 7. 调试日志

输入开启的分钟数（直接回车为 30 分钟），临时将日志级别调到 debug 并开启访问日志，到时自动恢复。

```bash
tail -f /etc/easyxray/log/error.log /etc/easyxray/log/access.log
```

### 8. 备份与回滚

| 选项 | 说明 |
|---|---|
| 1 恢复上一份配置 | 将状态文件和全部配置恢复到上一次修改之前。最多保留 5 份快照，可以连续恢复 |
| 2 导出备份 | 保存到 `/root/easyxray-backup-日期.tar.gz`，用于[从备份恢复](#从备份恢复) |

### 9. 卸载

| 选项 | 说明 |
|---|---|
| 1 保留配置卸载 | 停止服务，保留用户、端口、密钥和证书，之后重新安装即可恢复 |
| 2 完全卸载 | 删除全部配置、程序和证书 |

详见[卸载](#卸载)。

## 命令参考

所有菜单操作都有对应的命令。除 `help` 外，命令需要 root 权限。

```bash
ezx                                   # 进入菜单
ezx help                              # 查看帮助

# 协议
ezx protocol list
ezx protocol enable xhttp-tls          # 开启，自动分配端口
ezx protocol enable xhttp-tls --port 8088
ezx protocol disable xhttp-tls

# 用户与订阅
ezx user list
ezx user add alice@example.com
ezx user add                          # 自动生成邮箱
ezx user del alice@example.com
ezx sub                               # 所有用户的订阅
ezx sub alice@example.com

# 分流
ezx warp setup                        # 开启 WARP
ezx warp remove
ezx route list
ezx route add warp-ipv4 anthropic,openai,example.com
ezx route add direct example.org
ezx route add block ads.example.com
ezx route del warp-ipv4 openai        # 删除指定规则
ezx route del warp-ipv4               # 删除该出口的全部规则
ezx route quic block                  # 开启 QUIC 屏蔽
ezx route quic allow                  # 关闭 QUIC 屏蔽
ezx route bt allow                    # 关闭 BT 屏蔽（block 为开启）

# 维护
ezx doctor                            # 诊断
ezx apply                             # 根据状态文件重新生成配置
ezx rollback                          # 恢复上一份配置
ezx backup                            # 导出备份
ezx rekey                             # 重新生成所有协议的密钥
ezx geo update                        # 更新 geo 数据
ezx geo auto off                      # 关闭 geo 数据自动更新（on 为开启）
ezx update                            # 更新 easyxray 到最新发布版本
ezx update v0.2.0                     # 更新或换回指定版本
ezx xray version
ezx xray use                          # 更新到 Xray 最新正式版（也可以写版本号）
ezx log debug 30                      # 开启调试日志 30 分钟
ezx log normal
ezx log show
ezx uninstall                         # 询问卸载方式
ezx uninstall --keep-config           # 保留配置卸载
ezx uninstall --purge                 # 完全卸载
```

- 协议名称：`reality-vision`、`hysteria2`、`xhttp-tls`、`reality-xhttp`、`vless-tls-vision`
- 出口名称：`direct`（直连）、`block`（屏蔽）、`warp-ipv4`（WARP）

## 工作原理

```
修改 state.json → 生成到临时目录 → xray run -test / nginx -t → 保存快照 → 替换并重启 → 健康检查
                                          │                                         │
                                       校验失败                                 启动失败
                                          ▼                                         ▼
                                    不做任何修改                             恢复上一份快照
```

- **状态文件** `/etc/easyxray/state.json` 是唯一的数据来源，记录域名、用户、各协议的端口和密钥、分流规则和 WARP 设置。
- **每次修改都整体重新生成** Xray 配置、Nginx 配置和订阅文件，相同的状态始终生成相同的配置。
- 请通过菜单或命令修改设置，不要手动编辑 `/etc/easyxray/xray/` 下的文件，否则下次修改时会被覆盖。

## 文件位置

| 路径 | 内容 |
|---|---|
| `/opt/easyxray/` | easyxray 和 Xray 程序，geo 数据在 `bin/` 下 |
| `/etc/easyxray/state.json` | 状态文件 |
| `/etc/easyxray/xray/` | 生成的 Xray 配置 |
| `/etc/easyxray/tls/` | 证书，续期后自动更新 |
| `/etc/easyxray/subscribe/` | 订阅文件 |
| `/etc/easyxray/www/site/` | 伪装站，可以替换为自己的网站文件 |
| `/etc/easyxray/log/` | Xray 日志，每周轮转 |
| `/etc/easyxray/snapshots/` | 最近 5 份配置快照 |
| `/etc/nginx/conf.d/easyxray.conf` | 生成的 Nginx 配置 |
| `/etc/systemd/system/easyxray.service` | Xray 服务 |
| `/etc/systemd/system/easyxray-geo.timer` | geo 数据每周自动更新 |
| `/root/easyxray-backup-*.tar.gz` | 导出的备份文件 |

## 常见问题

**证书申请失败**

确认域名已解析到这台服务器，并且云服务商的安全组放行了 TCP 80。处理后重新运行同一条安装命令即可继续。

**客户端无法连接**

1. 运行 `sudo ezx doctor`，确认所有项目都是「正常」。
2. 确认云服务商的安全组放行了各协议的端口，Hysteria2 使用 UDP。
3. 在客户端中更新订阅。

**速度慢**

运行 `sudo ezx doctor` 确认 BBR 已开启。线路丢包较多时，可以尝试 Hysteria2，并在客户端中填写带宽。

## 更新

```bash
sudo ezx update
```

也可以在菜单中选择「6 版本更新 → 1 更新 easyxray」。更新过程：

1. 从 GitHub Release 下载最新版本的 `easyxray.tar.gz`，校验 SHA256，校验不通过时不做任何修改。
2. 替换 `/opt/easyxray` 下的程序文件，`bin/` 中的 Xray 保留不动。
3. 用新版本重新生成配置。新配置没有通过校验时，自动换回原来的程序和配置。
4. Xray 低于安全版本 v26.10.31 时自动更新到最新正式版，并关闭系统的 MPTCP。

状态文件、用户、端口和密钥都不受影响，客户端不需要重新导入订阅。

Linux 内核的安全漏洞只能通过系统更新修复，建议定期运行 `apt update && apt upgrade`，安装了新内核后重启服务器。

## 卸载

```bash
sudo ezx uninstall
```

运行后选择卸载方式，也可以直接用 `--keep-config` 或 `--purge` 指定。

**保留配置卸载**（`--keep-config`）

停止并删除 Xray 服务，删除 Nginx 配置、防火墙规则、日志轮转配置和证书续期钩子。以下内容保留：

- 状态文件和全部数据 `/etc/easyxray`，包括用户、端口、密钥和分流规则
- 程序目录 `/opt/easyxray` 和 `ezx` 命令
- Let's Encrypt 证书

之后运行 `sudo ezx`，选择「1 恢复安装」，或运行 `sudo ezx install`，不需要再填域名。原来的用户、端口、密钥和开启的协议保持不变，客户端不需要重新导入订阅。

**完全卸载**（`--purge`）

在保留配置卸载的基础上，再删除：

- 状态文件和全部数据 `/etc/easyxray`
- 程序目录 `/opt/easyxray` 和 `easyxray`、`ezx` 命令
- 本域名的 Let's Encrypt 证书
- 运行 Xray 的 `easyxray` 系统用户

用户、密钥删除后无法恢复，重新安装后客户端需要重新导入订阅。Nginx、certbot 等系统软件包和 BBR 设置会保留。

要换一个域名重新安装，需要先完全卸载。

## 许可证

[GPL-3.0](LICENSE)

## 致谢

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)
- [mack-a/v2ray-agent](https://github.com/mack-a/v2ray-agent)：部分设计思路参考自该项目
