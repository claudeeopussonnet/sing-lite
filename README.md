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
| Surge 原厂 | Snell v5/v6 |

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
