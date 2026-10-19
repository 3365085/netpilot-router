# NetPilot 网络助手

适用于 OpenWrt / ImmortalWrt 的设备网络模式控制器。保留已有 Clash / Mihomo 订阅，按设备选择直连、DNS 去广告、透明代理或去广告与代理，并分别选择规则分流或全局代理。

本项目基于用户提供的 `luci-app-netmode` 1.0.0 源码修复，界面及安装名称统一为 **NetPilot 网络助手**。为兼容旧设备，保留 `/etc/allinone`、`allinone` 服务及 `netmode` nftables 表的内部名称。

## 控制台

界面采用 iOS 设置列表和底部弹窗，跟随系统切换深浅色。首页显示设备模式、当前节点、订阅和去广告规则；长链接、导入表单和运行细节在需要时展开。

点击“代理 → 节点”，可选择自动选择或订阅中的具体节点，并查看、更新延迟。节点较多时支持搜索。切换通过 Mihomo API 执行并读取结果确认，不重启服务。Mihomo 的 `store-selected` 会保留节点选择。

**所选节点由所有代理设备共用。** 设备模式、规则/全局分流仍分别保存。节点切换用于新连接，已建立的连接可继续使用原节点。

设备模式或规则/全局设置发生变化时，会关闭当前设备已经建立的 Mihomo 代理连接，使其按新设置重新连接。不会关闭其他设备的代理连接；直接转发的旧连接和浏览器自身的 DNS 缓存不在此操作范围内。关闭失败时界面会提示重新连接此设备网络。

## 模式

| 设备模式 | DNS | 数据流量 |
| --- | --- | --- |
| 直连 | 原路由器 dnsmasq | 原生直连 |
| 去广告 | 专用过滤 DNS，直连上游 | 原生直连 |
| 代理 | Mihomo DNS，不应用广告域名列表 | 规则分流或全局代理 |
| 去广告与代理 | 过滤 DNS → Mihomo DNS | 先拦截广告，再分流或全局代理 |

固件支持 IPv4 策略路由时使用 TPROXY。缺少该功能时，优先探测 **TC → TUN**：由内核 TC 按设备将公网 IPv4 TCP / UDP 送入 Mihomo 的 gVisor TUN，分别使用规则/全局与是否过滤的四个入口。DNS 仍经过对应设备的过滤链路，局域网、私有地址与组播保留原路径。这条路径不需要修改默认路由或刷固件，已在目标 SP970 的现有固件验证。当前固件缺少策略路由并不等于芯片不能运行 TUN。

只有 TPROXY 和 TC → TUN 均不可用时，才退回 TCP REDIRECT。界面会明确显示 TCP 兼容模式，并拒绝代理设备的公网 UDP。接管方式显示 `TUN · TCP / UDP` 且运行状态已就绪时，表示 TUN 正常工作；远端订阅节点还必须支持 UDP。当前已有订阅的实际代理路径已验证 UDP 往返。

此版本的透明代理接管 IPv4 TCP / UDP。**代理设备的公网 IPv6 继续被阻断，避免直连；没有启用 IPv6 代理。** ICMP 等未接管的公网协议在 TC → TUN 模式下也会被阻断。无法将路由器的能力延伸到不经过它的蜂窝流量。

代理设备采用断线阻断：核心停止、TUN 失效或接管暂未恢复时，公网流量不会自动改成直连。procd 重启核心后，守护进程每 5 秒检查并恢复 TUN 绑定。停止 `allinone` 服务会保留设备防护；要主动使用原网络，在控制台将该设备切为“直连”。该机制控制经过路由器的路径，不提供账号风控方面的保证。

去广告由 Mihomo 域名规则与两个小型 dnsmasq 实例配合完成。仅去广告的 DNS 使用直连上游；组合模式的 DNS 使用 Mihomo。界面展示实际核心 RSS，不承诺固定内存上限。

## 安装

依赖：`mihomo`、`curl`、`nftables`、`ip-full`、`dnsmasq-full`、`jsonfilter`、`ucode`、`ucode-mod-fs`、`ca-bundle`、`sha256sum`。TPROXY 模式还需要内核启用 `CONFIG_IP_ADVANCED_ROUTER` / `CONFIG_IP_MULTIPLE_TABLES`，并具备 `kmod-nft-tproxy` 及 `kmod-nft-socket`。

TC → TUN 需要带 gVisor 支持的 Mihomo、`kmod-tun`、`kmod-sched-core`，以及具备 `u32`、`basic`、`gact`、`mirred`、chain 与 JSON 支持的 `tc`。目标设备现有 `tc-tiny 6.18.0` 和对应内核模块已满足条件，未额外安装软件包。能力探测在临时虚拟接口上执行，不给真实 LAN 安装测试规则。NetPilot 使用 ingress 优先级 49200 与链 42001 / 42002，其他自定义 QoS 请避开这些编号。

先安装 [Mihomo 官方核心](https://github.com/MetaCubeX/mihomo/releases)，放到 `/usr/bin/mihomo` 并赋予执行权限。本项目不将失效镜像或不可执行的下载占位脚本作为核心。

```sh
tar -xzf netpilot-router-1.3.0.tar.gz
sh install.sh
```

安装程序保留已有订阅和设备模式，在 `/root/netpilot-backup-日期时间` 保存旧文件。它会修改 uhttpd 访问控制、增加 firewall include、TUN 返回流量到 LAN 的防火墙区域和每日规则更新任务，关闭可能保留旧设备分流决定的流量卸载，随后启动服务。配置通过检查后才停止旧核心。失败时查看备份和日志；不会自动卸载其他代理软件。

打开 `http://路由器IPv4地址/netpilot.html`。用户名为 `root`，密码为现有路由器密码。旧 `/net.html` 地址会跳转到新界面。订阅和修改接口均使用路由器认证，不允许跨站修改。

电脑若已运行 FlClash 等本地代理，先在路由器控制台为该电脑选择“仅去广告”，避免双重接管。要完全使用路由器代理，先退出电脑端代理，再选择“去广告＋代理”；iPhone 使用路由器方案时无需额外建立手机 VPN。加密 DNS 或本机代理自行解析的域名可能绕过路由器的 DNS 过滤。

## 订阅与广告规则

Clash 订阅直接在路由器与订阅服务之间获取，不经过订阅转换网站。代理自动选择组只包含订阅节点，不把直连放入竞速组。

新安装默认叠加两份域名规则：[秋风广告规则 AWAvenue](https://github.com/TG-Twilight/AWAvenue-Ads-Rule) 补充国内广告，[HaGeZi Light](https://github.com/hagezi/dns-blocklists#-multi-light-basic-protection) 扩大常见广告与追踪域名覆盖。Light 比更高档列表保守，刻意保留部分错误上报服务。两份源均已在目标路由器验证可下载、可编译；已有安装升级时保留原规则列表，可在界面手动添加第二份源。

HaGeZi Light 域名文本地址：

```text
https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/light-onlydomains.txt
```

AWAvenue 的 Mihomo domain YAML 原始地址：

```text
https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-Clash.yaml
```

若路由器无法直连 GitHub Raw，可使用该项目列出的 jsDelivr 线路：

```text
https://gcore.jsdelivr.net/gh/TG-Twilight/AWAvenue-Ads-Rule@main/Filters/AWAvenue-Ads-Rule-Clash.yaml
```

去广告支持 domain YAML、纯域名、hosts 和无条件的 `||domain^` DNS 规则，统一转换为域名规则并同时用于 DNS 和流量拦截。MRS、浏览器美容规则、路径规则和带条件/例外的复杂 AdBlock 列表不属于此功能的输入格式。广告与正文共用域名、应用内加密 DNS、缓存结果等场景无法保证过滤。

规则默认每天 04:23 更新。下载失败时保留缓存；无可用规则或配置验证失败时返回错误，不报告已成功应用。配置通过 Mihomo 和 dnsmasq 检查后才替换运行文件。

规则源的开关是全路由器共用的；首页模式决定当前设备是否使用它们。界面会分别显示“此设备已启用”和“此设备未启用”。规则数量和 DNS 返回 NXDOMAIN 只能证明过滤链路中的相应环节生效，不能代替实际浏览器请求的验证。

在 `https://adblock.turtlecute.org` 的实际对照结果与方法见 [VALIDATION.md](VALIDATION.md)。DNS 过滤可拦截广告 SDK 使用的独立域名，但不能保证去掉所有开屏、插屏或全屏广告；页面元素隐藏和同域路径过滤需要设备端内容过滤支持。

实体 iPhone 的 Safari 曾持续报告约 16%。现场保持路由器配置不变，仅关闭手机蜂窝数据后，4 个广告域名全部连接失败，3 个正常网站仍可访问，证实蜂窝网络回退可绕过路由器过滤。随后用户恢复蜂窝数据、关闭当前 Wi-Fi 的“使用连接助理”，同一台 iPhone 的 Safari 复测报告 **92%**，固定广告域名与正常网站对照也符合预期。用户确认测试时未运行其他代理。实体 Safari 的总分来自用户现场反馈，隔离 Chrome 的完整自动测试记录另见验证文档。

排查时可在同一浏览器打开 `http://路由器IPv4地址/netpilot-diagnostic.html`，也可从首页“运行信息”进入。页面对固定的 4 个广告域名、3 个正常网站以及不存在的随机域名和路由器关闭端口发送新的 HEAD 请求。结果仅保存在路由器 `/tmp/netpilot-diagnostic-设备IPv4地址.json`，重启后消失，并记录路由器接收时间，避免手机时钟偏差干扰配对。`opaque` 仅是浏览器返回的不可读结果，连接失败也可能来自普通网络错误，需与 DNS 和流量记录一起判断；页面不会修改设备模式。

iOS 27 使用路由器过滤时需注意[“连接助理”](https://support.apple.com/zh-cn/127686)。它可在连接 Wi-Fi 时使用蜂窝数据；苹果官方建议对使用广告拦截器的特定网络关闭此功能。可在“设置 → 无线局域网 → 当前 Wi-Fi 右侧的 ⓘ”中关闭“使用连接助理”，随后保持蜂窝数据正常开启。这是手机系统设置，路由器不能代为切换，也无法拦截根本不经过路由器的蜂窝流量。iOS 27 Safari 的过滤模式下会显示简短设置提示。

## 运维

```sh
/etc/init.d/allinone status
/etc/init.d/allinone restart
netpilot-rebuild --apply
logread -e netpilot
nft list table inet netmode
cat /etc/allinone/backend
cat /etc/allinone/adblock.count
netpilot-tun check
```

保留的用户数据位于 `/etc/allinone`：`clash_profiles.conf`、`adg_sources.conf`、`peers.conf`、`proxy_providers/`、`rule_providers/`。不要提交这些文件或路由器备份到 Git。

## 开发与打包

```sh
bash tests/test_domains.sh
sh tests/test_nodes.sh  # 需要 ucode 和 jsonfilter，也可在路由器上运行
sh tests/test_connections.sh  # 需要 ucode，验证按设备关闭旧连接的筛选
node tests/ui.mjs      # Linux + Node.js 22+ + Chrome；CHROME_BIN 可指定浏览器路径
bash build.sh
```

`dist/` 生成可在 APK / OPKG 固件上使用的文件安装包和 SHA-256 清单；它不冒充已注册的 APK/IPK。安装器保留既有用户数据，源码仓库不包含私有配置和核心二进制。

实际路由器测试范围与结果见 [VALIDATION.md](VALIDATION.md)。

实际传输回归使用 `tests/udp_probe.go` 和 `tests/router_transport.sh`。先交叉编译 UDP 探针，将探针和脚本复制到路由器临时目录，再以 root 执行脚本。脚本会创建并清理临时 LAN 设备；`--fault-tests` 会主动终止和停止/启动当前代理核心，影响现有代理连接，请仅在维护测试时使用。

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o /tmp/udp-probe tests/udp_probe.go
# 在路由器上运行，探针路径按实际上传位置填写：
sh router_transport.sh /tmp/udp-probe --fault-tests
```

TC → TUN 的实现依据 [Mihomo TUN listener 配置](https://wiki.metacubex.one/config/inbound/listeners/tun/) 和 [Linux mirred 实现](https://github.com/torvalds/linux/blob/v6.12/net/sched/act_mirred.c)。TC 在 LAN ingress 选中设备并将 IP 包交给 TUN，Mihomo 按原有入口子规则选择直连或共享代理节点。

节点操作依据 [Mihomo API 文档](https://wiki.metacubex.one/api/)，使用固定的 `PROXY` 选择组；接口只返回节点名称、延迟和选择状态，不转发节点凭据。
