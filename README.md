# sing-lite

## 安装

```bash
curl -fL https://raw.githubusercontent.com/claudeeopussonnet/sing-lite/main/vless-server.sh -o sing-lite.sh
bash sing-lite.sh
```

安装后运行 `sing` 打开管理菜单，查看运行状态、彩色编号节点和端口。

## 支持协议

| 内核 | 协议 |
| --- | --- |
| sing-box | VLESS REALITY、SS2022、Shadowsocks、SOCKS5、Hysteria2、TUIC v5、AnyTLS、Naive、SS2022 + ShadowTLS v3、Snell v5/v6 |
| Xray 官方 | VLESS REALITY + Vision、VLESS Encryption、VLESS XHTTP + REALITY（可选 Encryption） |
| Surge 原厂 | Snell v5/v6 |

安装 VLESS 时可选择模式和内核。Xray 使用独立的 `sing-xray` 服务与 `/etc/sing-lite/xray.json`，支持多端口、用户管理、分享链接和订阅；暂使用直连出口，不同步 sing-box 的分流、WARP、链式代理或用户路由。内核版本管理支持实时查询和安装 Xray 稳定版、测试版，下载校验或服务启动失败会回滚核心与配置。

Xray 用户增删、启停与配置更新使用同一事务；验证或重启失败会恢复用户状态、配置和分享文件，到期禁用失败后仍可重试。已停止的服务在修改用户时保持停止。

Surge 自 iOS 6.0.0 / Mac 6.12.0 起支持 VLESS。普通 REALITY + Vision 节点（sing-box / Xray）会提供 `vless://` 分享链接、可粘贴到 `[Proxy]` 的 Surge 配置行及 Surge 订阅，使用 `username`、`flow`、`sni`、`reality-public-key` 和 `reality-short-id` 字段。按 [Surge 官方文档](https://manual.nssurge.com/policies/vless.html)，XHTTP 和 VLESS Encryption 暂不受支持；这两类节点仅生成通用分享链接，并从 Surge 订阅中排除。

## 规则策略

| 分类 | 规则来源 |
| --- | --- |
| AI、Stream、Stream JP | [Sukka](https://ruleset.skk.moe/) 的 `non_ip`、`ip` 规则 |
| 广告屏蔽 | Sukka 的 `domainset/reject`、`non_ip/reject`、`ip/reject` |
| 国内流量 | Sukka 的 `non_ip/domestic`、`ip/china_ip` |
| YouTube、Google | [Yuu518/sing-box-rules](https://github.com/Yuu518/sing-box-rules/tree/rule_set/rule_set_site) 的 site 域名规则 |
| Twitter | Yuu 的 `rule_set_site/twitter.json` 和 `rule_set_ip/twitter.json`，分别放在 `site`、`ip` 阶段 |
| 自定义、所有流量 | 自定义域名/IP/规则集及兜底规则 |

全局匹配顺序为 `site（含 domainset）→ non_ip → ip → 所有流量`，各块内部保持分流优先级。YouTube、Google、Twitter 的 `rule_set_site` 均放在第一块；为兼容已有配置，其规则集标签保留 `yuu-non-ip-*` 名称。默认 Stream JP 优先于 Stream，YouTube 优先于 Google。支持直连、WARP 和链式代理出口；URLTest 选择最低延迟节点，Selector 固定选择首节点。
