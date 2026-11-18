# sing-lite

## 安装

```bash
curl -fL https://raw.githubusercontent.com/claudeeopussonnet/sing-lite/main/vless-server.sh -o sing-lite.sh
bash sing-lite.sh
```

安装后运行 `vless` 打开管理菜单，查看运行状态、彩色编号节点和端口。更新后会将本脚本创建的旧 `sing` 快捷入口切换为 `vless`。菜单使用 `[1]`、`[10]`、`[A]` 方括号选项，文字对齐，直接输入原序号或字母即可。分享页按节点分块展示名称、内核、地址、分享链接、Surge 配置和二维码；用户分享与订阅页采用相同排版，链接和配置独立成行，方便直接复制。

在 `vless` 菜单选择「检查脚本更新」，可选择稳定版或测试版。通过临时入口运行、原脚本已移除或其目录无法创建暂存文件时，更新会使用已安装的管理脚本（默认路径为 `/usr/local/bin/sing-lite.sh`）。成功后会显示更新目标并保留对应的 `.bak` 备份，可用 `vless` 重新打开。脚本更新无需配置目录，继承的 `TMPDIR` 无法创建下载文件时会改用 `/tmp`。

## 支持协议

| 内核 | 协议 |
| --- | --- |
| sing-box | VLESS REALITY、SS2022、Shadowsocks、SOCKS5、Hysteria2、TUIC v5、AnyTLS、Naive、SS2022 + ShadowTLS v3、Snell v5/v6 |
| Xray 官方 | VLESS REALITY + Vision、VLESS Encryption、VLESS XHTTP + REALITY（可选 Encryption） |
| Surge 原厂 | Snell v5/v6 |

安装 VLESS 时可选择模式和内核；REALITY 默认使用 Xray，也可选择 sing-box，已有实例保持原内核。Xray 使用独立的 `sing-xray` 服务与 `/etc/sing-lite/xray.json`，支持多端口、用户管理、分享链接、订阅和独立分类分流，无需安装 sing-box。两个内核分别保存分流规则、选择出口和调整顺序，未配置 Xray 分流或流量未匹配时默认直连。内核版本管理支持实时查询和安装 Xray 稳定版、测试版，下载校验或服务启动失败会回滚核心、配置与规则资源指向。

Xray 用户增删、启停与配置更新使用同一事务；验证或重启失败会恢复用户状态、配置和分享文件，到期禁用失败后仍可重试。已停止的服务在修改用户时保持停止。

安装、新增或替换 VLESS ENC 端口时，可选择启用 Vision 流控，提示 `[y/N]`，默认关闭。同一端口的用户共享该设置，旧配置保持关闭；重新配置端口时可重新选择。Vision 可减少符合条件的内层 TLS 1.3 流量的重复加解密开销，ENC 本身不依赖它；开启后仍为 RAW TCP + ENC，不启用外层 TLS。服务端与客户端的 `flow=xtls-rprx-vision` 必须匹配，脚本会同步生成分享链接、二维码、用户分享和 Surge 配置及订阅，客户端应重新导入更新后的配置。

Surge 自 iOS 6.0.0 / Mac 6.12.0 起支持 VLESS。脚本提供普通 REALITY、VLESS Encryption、XHTTP + REALITY（包括叠加 Encryption）的通用分享链接、可粘贴到 `[Proxy]` 的 Surge 配置行和 Surge 订阅。按 [Surge 官方文档](https://manual.nssurge.com/policies/vless.html) 输出 `username`、`flow`、`sni`、`reality-public-key`、`reality-short-id`、`encryption` 和 `xhttp-*` 字段；XHTTP 支持四种模式，外部同类链接保留路径、Host 和模式。外部 WS / HTTPUpgrade / gRPC、普通 TLS、高级 XHTTP `extra` 和 `downloadSettings` 暂不转换为 Surge，跳过时会说明原因。Clash 订阅中的 VLESS 仍仅导出未叠加 Encryption 的 RAW REALITY。

分享链接、二维码、用户分享和订阅统一使用地区 emoji 与大写简称，例如 `🇯🇵 REALITY-443`、`🇯🇵 ENC-8443`、`🇯🇵 XHTTP-2053`、`🇯🇵 SNELL6-443`。多用户附加大写用户名，重名时补实现标识或编号；名称中的大小写转换不影响实际账户名、密码、密钥和路径。地区按连接服务器地址查询，外部域名先解析 IPv4，再解析 IPv6；无法确定地区时使用 `🌐`。外部节点导出时重新命名，原始导入内容保留；SOCKS5 分享使用支持备注的 `socks5://` URI。

## 规则策略

进入 `vless` 的「分流管理」时选择内核；只安装一个内核就直接进入，同时安装两个时可通过「切换内核」切换。sing-box 和 Xray 使用相同的简洁布局，标题显示当前内核，规则列表、配置检查和查看配置均对应当前内核，不再混合展示两套规则。分类统一显示为 AI、YouTube、X 等名称，链式出口直接显示节点名，默认不再显示 `[ALL]`；sing-box 中明确设置的 IP 版本限制或优先级仍会显示。

两个内核都通过「配置分流规则 → 设置规则」选择分类和出口，也可删除、调整顺序；选择链式出口时按编号选择节点，无需输入节点名称，输入 `0` 返回。Xray 还提供手动更新规则集，sing-box 的直连出口和访问限制放在「更多设置」。设置、删除或排序完成后自动保存并生效，无需额外应用；检查或重启失败时恢复原配置，已停止的服务保持停止。「检查配置」只读校验所选内核的现有配置，不启动服务；实际流量是否按预期分流仍需从客户端验证。

在两个内核的「设置规则」中都可以输入 `c` 添加自定义域名。例如输入 `example.com,example.org` 并选择出口，这条规则会匹配两个域名及其子域名。每个内核独立保存规则、出口选择和优先级，可添加多条、删除或调整顺序。sing-box 的自定义规则还支持 IP 和 Sukka 规则集。

WARP 和链式节点池由两个内核共享，管理页会标明「共享出口」；分流规则和优先级仍分别保存。Xray 界面不提供 sing-box 的负载均衡组或其他专属设置。

Xray 五类预设统一使用 [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat/releases) 发布的成品 `geosite.dat` 和 `geoip.dat`：

| 分类（默认优先级） | 域名规则 | IP 规则 |
| --- | --- | --- |
| AI | `geosite:category-ai-!cn` | 无 |
| YouTube | `geosite:youtube` | 无 |
| X | `geosite:twitter` | `geoip:twitter` |
| Google | `geosite:google` | 默认不使用 |
| 国内流量 | `geosite:cn` | `geoip:cn` |

Xray 全局先输出域名规则（site 块），包括自定义域名和预设域名，再输出 X 和国内的独立 IP 规则（ip 块），non_ip 块为空；各块内部遵循所选优先级。新增自定义域名默认放在首位，可通过「调整顺序」移动。AI、YouTube 必须排在 Google 之前，无效排序会给出中文说明。五类预设同时覆盖 IPv4、IPv6。启用 HTTP、TLS、QUIC 域名嗅探，`routeOnly` 保留原始连接目标；`IPOnDemand` 在域名未命中且进入 IP 匹配阶段时解析域名，内置 DNS 使用系统解析器。

每类出口可选择直连、拦截、WARP 或链式节点。国内流量也由用户选择出口，只有选择拦截才阻断。WARP 复用现有账户：官方客户端使用本机 SOCKS5，WGCF 使用 Xray 原生 WireGuard 出站和用户态网络栈。共享节点池中的 SOCKS5、HTTP、Shadowsocks、VMess、VLESS、Trojan 可转换为原生 Xray 出站；认证、TLS、REALITY、流控和传输参数必须完整表达，否则拒绝选择或应用并说明原因。此功能沿用现有导入格式，不接入 Xray 负载均衡组或用户级路由。节点改名、覆盖、删除及 WARP 账户或模式变更会维护引用；涉及两个内核时，任何配置检查或重启失败均恢复原数据库、配置、资源指向和运行状态，原先停止的服务保持停止。

首次应用 Xray 预设分流时，从同一发布版本下载两份 DAT 及 SHA-256 文件，在私有暂存目录完成校验并使用官方 Xray 检查全部五类标签，通过 `/etc/sing-lite/xray-rules` 原子切换资源目录。仅配置自定义域名时无需下载 DAT。应用预设配置时，规则超过 24 小时会尝试刷新；也可在 Xray 分流界面手动更新，不新增后台任务。自动刷新失败时会提示并继续使用通过校验的旧规则；首次下载失败、旧规则无效或手动更新失败会拒绝应用。远程版本查询不使用持久缓存。

sing-box 继续使用以下规则源，其规则和顺序不迁移到 Xray：

| 分类 | 规则来源 |
| --- | --- |
| AI、Stream、Stream JP | [Sukka](https://ruleset.skk.moe/) 的 `non_ip`、`ip` 规则 |
| 广告屏蔽 | Sukka 的 `domainset/reject`、`non_ip/reject`、`ip/reject` |
| 国内流量 | Sukka 的 `non_ip/domestic`、`ip/china_ip` |
| YouTube、Google | [Yuu518/sing-box-rules](https://github.com/Yuu518/sing-box-rules/tree/rule_set/rule_set_site) 的 site 域名规则 |
| Twitter | Yuu 的 `rule_set_site/twitter.json` 和 `rule_set_ip/twitter.json`，分别放在 `site`、`ip` 阶段 |
| 自定义、所有流量 | 自定义域名/IP/规则集及兜底规则 |

全局匹配顺序为 `site（含 domainset）→ non_ip → ip → 所有流量`，各块内部保持分流优先级。YouTube、Google、Twitter 的 `rule_set_site` 均放在第一块；为兼容已有配置，其规则集标签保留 `yuu-non-ip-*` 名称。默认 Stream JP 优先于 Stream，YouTube 优先于 Google。支持直连、WARP 和链式代理出口；URLTest 选择最低延迟节点，Selector 固定选择首节点。
