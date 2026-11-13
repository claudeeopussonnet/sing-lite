# Repository guidelines

`vless-server.sh` owns the sing-lite installer and Chinese interactive manager. `nft.sh` owns nftables forwarding. Keep the existing Bash 4.1+ style, four-space indentation, quoted expansions, restrictive permissions and download validation.

Only official sing-box, XTLS Xray-core and Surge Snell binaries are supported. Configuration lives in `/etc/sing-lite`; the command is `sing`. Xray routing is independent of sing-box and defaults to direct outbound. Do not add user traffic accounting or quotas.

分流规则必须全局按 `site（含 domainset）→ non_ip → ip → 所有流量` 分块输出，每个块内部按分流优先级排列。禁止逐个分流依次输出其 site、non_ip、ip 后再输出下一个分流。Yuu 的 `rule_set_site`（包括 YouTube、Google、Twitter）属于第一块 site，即使兼容旧配置的标签仍叫 `yuu-non-ip-*`，也不能归入 non_ip 块；`rule_set_ip` 属于第三块 ip。YouTube 规则必须排在 Google 规则之前，避免 Google 规则先匹配 YouTube 流量。新增或调整分流时检查上游是否同时提供 site 和 IP 规则，并保持各块内的优先级及全局分块顺序；顺序变更须通过对应回归测试验证。

Before publishing run `bash -n vless-server.sh`, `bash -n nft.sh`, `bash vless-server.sh --help` and applicable tests in `tests/`. Tests must use temporary directories and mock services; never run installer, uninstaller or firewall operations against the development host. Update README for user-visible changes.

Do not commit credentials, API tokens, private keys or real server configuration. Preserve atomic configuration updates and rollback behavior. Version checks must query the remote source without persistent version caches.
