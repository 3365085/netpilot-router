# NetPilot 网络助手

适用于 OpenWrt / ImmortalWrt 的设备网络模式控制器。保留已有 Clash / Mihomo 订阅，按设备选择直连、DNS 去广告、透明代理或去广告与代理，并分别选择规则分流或全局代理。

本项目基于用户提供的 `luci-app-netmode` 1.0.0 源码修复，界面及安装名称统一为 **NetPilot 网络助手**。为兼容旧设备，保留 `/etc/allinone`、`allinone` 服务及 `netmode` nftables 表的内部名称。

## 控制台

界面采用 iOS 设置列表和底部弹窗，跟随系统切换深浅色。首页显示设备模式、当前节点、订阅和去广告规则；长链接、导入表单和运行细节在需要时展开。

点击“代理 → 节点”，可选择自动选择或订阅中的具体节点，并查看、更新延迟。节点较多时支持搜索。切换通过 Mihomo API 执行并读取结果确认，不重启服务。Mihomo 的 `store-selected` 会保留节点选择。

**所选节点由所有代理设备共用。** 设备模式、规则/全局分流仍分别保存。节点切换用于新连接，已建立的连接可继续使用原节点。

## 模式

| 设备模式 | DNS | 数据流量 |
| --- | --- | --- |
| 直连 | 原路由器 dnsmasq | 原生直连 |
| 去广告 | 专用过滤 DNS，直连上游 | 原生直连 |
| 代理 | Mihomo DNS，不应用广告域名列表 | 规则分流或全局代理 |
| 去广告与代理 | 过滤 DNS → Mihomo DNS | 先拦截广告，再分流或全局代理 |

固件支持 IPv4 策略路由时使用 TPROXY，支持 TCP / UDP。若 `ip -4 rule show` 失败，自动使用 TCP REDIRECT 兼容模式。兼容模式会拒绝代理设备的外网 UDP，QUIC 通常回退为 TCP；依赖 UDP 的游戏和应用需要支持策略路由的固件。此版本不会刷写固件或伪装成支持 UDP 透明代理。

去广告由 Mihomo 域名规则与两个小型 dnsmasq 实例配合完成。仅去广告的 DNS 使用直连上游；组合模式的 DNS 使用 Mihomo。界面展示实际核心 RSS，不承诺固定内存上限。

## 安装

依赖：`mihomo`、`curl`、`nftables`、`ip-full`、`dnsmasq-full`、`jsonfilter`、`ucode`、`ucode-mod-fs`、`ca-bundle`。完整 TPROXY 模式还需要内核启用 `CONFIG_IP_ADVANCED_ROUTER` / `CONFIG_IP_MULTIPLE_TABLES`，并具备 `kmod-nft-tproxy` 及 `kmod-nft-socket`。

先安装 [Mihomo 官方核心](https://github.com/MetaCubeX/mihomo/releases)，放到 `/usr/bin/mihomo` 并赋予执行权限。本项目不将失效镜像或不可执行的下载占位脚本作为核心。

```sh
tar -xzf netpilot-router-1.2.0.tar.gz
sh install.sh
```

安装程序保留已有订阅和设备模式，在 `/root/netpilot-backup-日期时间` 保存旧文件。它会修改 uhttpd 访问控制、增加 firewall include 和每日规则更新任务，随后启动服务。失败时查看备份和日志；不会自动卸载其他代理软件。

打开 `http://路由器IPv4地址/netpilot.html`。用户名为 `root`，密码为现有路由器密码。旧 `/net.html` 地址会跳转到新界面。订阅和修改接口均使用路由器认证，不允许跨站修改。

电脑若已运行 FlClash 等本地代理，先在路由器控制台为该电脑选择“仅去广告”，避免双重接管和兼容模式的 UDP 限制影响已有客户端。要完全使用路由器代理，先退出电脑端代理，再选择“去广告＋代理”。加密 DNS 或本机代理自行解析的域名可能绕过路由器的 DNS 过滤。

## 订阅与广告规则

Clash 订阅直接在路由器与订阅服务之间获取，不经过订阅转换网站。代理自动选择组只包含订阅节点，不把直连放入竞速组。

默认去广告源为 [秋风广告规则 AWAvenue](https://github.com/TG-Twilight/AWAvenue-Ads-Rule) 的 Mihomo domain YAML，安装器默认使用已在目标路由器验证可达的 gcore CDN 线路。原始地址：

```text
https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-Clash.yaml
```

若路由器无法直连 GitHub Raw，可使用该项目列出的 jsDelivr 线路：

```text
https://gcore.jsdelivr.net/gh/TG-Twilight/AWAvenue-Ads-Rule@main/Filters/AWAvenue-Ads-Rule-Clash.yaml
```

去广告支持 domain YAML、纯域名、hosts 和无条件的 `||domain^` DNS 规则，统一转换为域名规则并同时用于 DNS 和流量拦截。MRS、浏览器美容规则、路径规则和带条件/例外的复杂 AdBlock 列表不属于此功能的输入格式。广告与正文共用域名、应用内加密 DNS、缓存结果等场景无法保证过滤。

规则默认每天 04:23 更新。下载失败时保留缓存；无可用规则或配置验证失败时返回错误，不报告已成功应用。配置通过 Mihomo 和 dnsmasq 检查后才替换运行文件。

## 运维

```sh
/etc/init.d/allinone status
/etc/init.d/allinone restart
netpilot-rebuild --apply
logread -e netpilot
nft list table inet netmode
cat /etc/allinone/backend
cat /etc/allinone/adblock.count
```

保留的用户数据位于 `/etc/allinone`：`clash_profiles.conf`、`adg_sources.conf`、`peers.conf`、`proxy_providers/`、`rule_providers/`。不要提交这些文件或路由器备份到 Git。

## 开发与打包

```sh
bash tests/test_domains.sh
sh tests/test_nodes.sh  # 需要 ucode 和 jsonfilter，也可在路由器上运行
node tests/ui.mjs      # Linux + Node.js 22+ + Chrome；CHROME_BIN 可指定浏览器路径
bash build.sh
```

`dist/` 生成可在 APK / OPKG 固件上使用的文件安装包和 SHA-256 清单；它不冒充已注册的 APK/IPK。安装器保留既有用户数据，源码仓库不包含私有配置和核心二进制。

实际路由器测试范围与结果见 [VALIDATION.md](VALIDATION.md)。

节点操作依据 [Mihomo API 文档](https://wiki.metacubex.one/api/)，使用固定的 `PROXY` 选择组；接口只返回节点名称、延迟和选择状态，不转发节点凭据。
