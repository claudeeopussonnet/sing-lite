# sing-lite

面向 Linux 服务器的轻量代理部署与管理脚本。保留原有中文交互和辅助工具，协议内核使用 [sing-box 官方发行包](https://github.com/SagerNet/sing-box)及 [Surge 原厂 Snell](https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell)。

安装或打开管理菜单（需要 root、Bash 4.1+）：

```bash
curl -fL https://raw.githubusercontent.com/mikuuu3981/sing-lite/main/vless-server.sh -o sing-lite.sh
bash sing-lite.sh
```

完成安装后使用 `sing` 打开菜单，菜单顶部显示内置的 `MIHOYO` ASCII Logo。配置、数据库、证书、订阅和缓存存放于 `/etc/sing-lite/`。脚本管理自己的内核与服务，服务名称使用 `sing-` 前缀。

| 内核 | 服务端协议 |
| --- | --- |
| sing-box | VLESS REALITY、VLESS Vision/TLS、VLESS WS、SS2022、传统 Shadowsocks、SOCKS5、Hysteria2、TUIC、AnyTLS、Naive、SS2022+ShadowTLS、Snell v5、Snell v6 |
| Surge 原厂 | Snell v5、Snell v6 |

Snell v5/v6 安装时均可选择 sing-box 或 Surge 原厂，默认 sing-box。sing-box 版本使用共享服务与分流，原厂版本使用独立服务。两种实现可通过不同端口共存，v6 的客户端 mode 必须与服务端一致。Naive 和 ShadowTLS 组合由 sing-box 内置实现承载。

不包含 Xray、Mihomo、Trojan/VMess 服务端、XHTTP、VLESS Encryption、Snell v4。保留外部 Trojan/VMess 节点的订阅及链式代理兼容。SOCKS5 不提供 TLS 选项。

保留用户启停、到期管理、Telegram 绑定与到期提醒。移除用户流量统计、流量配额停用、流量告警与 Telegram 流量查询。系统网络统计与端口转发的计数不属于用户流量计费。

分流支持 sing-box 规则集、普通 WARP 出口和链式节点。最低延迟选择使用 URLTest；Selector 固定选择首节点。多 IP 入站与出口映射、WARP IPv6 专用双层链式向导暂不可用，相关入口会明确提示。原 Xray 路径回落共用端口功能已移除，VLESS TLS/WS 使用独立端口。

分流分类使用发布方现成规则，不从聚合规则中提取网站域名：

| 标签 | 来源 |
| --- | --- |
| AI | Sukka `non_ip/ai`、`ip/ai` |
| Stream | Sukka `non_ip/stream`、`ip/stream` |
| Stream JP | Sukka `non_ip/stream_jp`、`ip/stream_jp` |
| YouTube、Google | [Yuu518/sing-box-rules](https://github.com/Yuu518/sing-box-rules) 的 `rule_set_site/youtube.json`、`google.json` |
| 广告屏蔽 | Sukka `domainset/reject`、`non_ip/reject`、`ip/reject` |
| 所有流量 | 保留的兜底标签，匹配其余流量 |

Sukka 规则统一从 [ruleset.skk.moe](https://ruleset.skk.moe/) 获取，按 [Sukka 的配置说明](https://blog.skk.moe/post/i-have-my-unique-surge-setup/) 将规则全局排为 **domainset → non_ip → ip → 所有流量**；缺少某一类文件时直接跳过。YouTube 和 Google 的原生文件只有域名规则，排在 non_ip 阶段。自定义域名在域名阶段、自定义 IP 在 IP 阶段匹配；手动调整优先级只影响同一阶段。“所有流量”始终在最后，出口标签、IPv4/IPv6 条件继续保留。默认先匹配 Stream JP 再匹配 Stream，先匹配 YouTube 再匹配 Google；WARP 必要的防回环保护仍优先执行。

规则在配置重建时检查并按 24 小时周期刷新，下载或编译失败不会替换原规则缓存和运行配置。旧 AI、YouTube、Google 预设及支持的旧 GeoSite/GeoIP 引用会在生成时转换至新源；没有对应现成规则的旧分类会明确报错并保留运行配置，请在菜单中删除后选择新的分类。回国限制改用 Sukka 国内域名及 IP 规则；新启用时不再添加 BT/PT 限制，旧 BT/PT 限制仍可关闭。

版本检查实时查询 GitHub，不读取本地版本缓存，也不在查询失败后回退旧缓存。脚本以所选分支（默认 `main`）的当前提交为准，上传代码并提高脚本版本号即可在下一次启动或手动检查时发现，无需先发布 Release。内核更新使用发布方 Release。网络失败或 API 限流会提示重试。

证书、订阅、Nginx、Cloudflare Tunnel、WARP 和端口转发按需安装。`nft.sh` 使用 `/etc/sing-lite/nftables/`、独立的 `sing_port_forward` 表及 `sing-nftm` 命令；系统 nftables 服务仍为共用服务。

本项目从现有 `mikuuu3981/surge` 脚本独立发展；原脚本署名 Zyx0rx。独立 Git 历史与更新源不改变原代码的权利归属。本仓库不分发代理内核二进制，安装时从发布方获取。

开发验证：

```bash
bash -n vless-server.sh
bash -n nft.sh
bash vless-server.sh --help
bash tests/run.sh
# 额外用官方发行包验证配置：
SING_TEST_SINGBOX_BIN=/path/to/sing-box bash tests/run.sh
```

测试使用临时目录及模拟服务，不在开发主机执行真实安装、卸载或防火墙操作。CI 使用校验过下载摘要的官方 sing-box v1.14.4 检查保留协议的配置。
