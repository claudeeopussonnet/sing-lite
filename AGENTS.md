# Repository guidelines

`vless-server.sh` owns the sing-lite installer and Chinese interactive manager. `nft.sh` owns nftables forwarding. Keep the existing Bash 4.1+ style, four-space indentation, quoted expansions, restrictive permissions and download validation.

Only official sing-box and Surge Snell binaries are supported. Configuration lives in `/etc/sing-lite`; the command is `sing`. Do not add user traffic accounting or quotas.

Before publishing run `bash -n vless-server.sh`, `bash -n nft.sh`, `bash vless-server.sh --help` and applicable tests in `tests/`. Tests must use temporary directories and mock services; never run installer, uninstaller or firewall operations against the development host. Update README for user-visible changes.

Do not commit credentials, API tokens, private keys or real server configuration. Preserve atomic configuration updates and rollback behavior. Version checks must query the remote source without persistent version caches.
