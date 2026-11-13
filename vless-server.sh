#!/bin/bash
#
# 本脚本会保存代理凭据、API Token 和私钥。统一使用私有文件权限，
# 避免后续通过重定向或 mv 新建的配置意外变成 0644。
umask 077

# 关联数组、大小写转换和动态文件描述符要求 Bash 4.1+。
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 1) )); then
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        echo "用法: $0 [选项]"
        echo "选项: --update-dev, --tg-bot-poll, --check-expire, --setup-expire-cron, --help"
        echo "运行功能需要 Bash 4.1 或更高版本。"
        if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
            return 0
        fi
        exit 0
    fi
    echo "错误: 本脚本需要 Bash 4.1 或更高版本（当前: ${BASH_VERSION:-unknown}）" >&2
    if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
        return 1
    fi
    exit 1
fi
#═══════════════════════════════════════════════════════════════════════════════
#  sing-lite v1.0.6 [服务端]
#  官方 sing-box 与 Surge 原厂 Snell v5/v6。
#  配置目录 /etc/sing-lite，快捷命令 sing。
#  适配: Alpine/Debian/Ubuntu/CentOS
#
#
#  作者: Zyx0rx
#  项目地址: https://github.com/claudeeopussonnet/sing-lite
#  作者地址:https://docs.vaiox.de/
#═══════════════════════════════════════════════════════════════════════════════

readonly VERSION="1.0.6"
readonly AUTHOR="Zyx0rx"
readonly REPO_URL="https://github.com/claudeeopussonnet/sing-lite"
readonly SCRIPT_REPO="claudeeopussonnet/sing-lite"
readonly SCRIPT_SOURCE_REPO="claudeeopussonnet/sing-lite"
readonly SCRIPT_STABLE_REF="main"
readonly SCRIPT_TEST_REF="dev"
SCRIPT_SOURCE_REF="${SING_SCRIPT_SOURCE_REF:-$SCRIPT_STABLE_REF}"
if [[ ! "$SCRIPT_SOURCE_REF" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "错误: SING_SCRIPT_SOURCE_REF 格式无效" >&2
    exit 1
fi
readonly SCRIPT_SOURCE_REF
readonly SCRIPT_SOURCE_PATH="vless-server.sh"
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    CFG="${SING_TEST_CFG:-${VLESS_TEST_CFG:-/etc/sing-lite}}"
    SYSTEMD_DIR="${SING_TEST_SYSTEMD_DIR:-${VLESS_TEST_SYSTEMD_DIR:-/etc/systemd/system}}"
    OPENRC_DIR="${SING_TEST_OPENRC_DIR:-${VLESS_TEST_OPENRC_DIR:-/etc/init.d}}"
else
    CFG="/etc/sing-lite"
    SYSTEMD_DIR="/etc/systemd/system"
    OPENRC_DIR="/etc/init.d"
fi
readonly CFG SYSTEMD_DIR OPENRC_DIR
# 只在源文件测试时允许注入路径；执行脚本使用自身内核目录。
export PATH="$CFG/bin:$PATH"
readonly ACME_DEFAULT_EMAIL="acme@vaio.com"

# curl 超时常量
readonly CURL_TIMEOUT_FAST=5
readonly CURL_TIMEOUT_NORMAL=10
readonly CURL_TIMEOUT_DOWNLOAD=60
readonly LATENCY_TEST_URL="https://www.gstatic.com/generate_204"
readonly LATENCY_PARALLEL="${LATENCY_PARALLEL:-4}"
readonly LATENCY_PROBES="${LATENCY_PROBES:-3}"
readonly LATENCY_MAX_ATTEMPTS="${LATENCY_MAX_ATTEMPTS:-0}"
readonly SUBSCRIPTION_MAX_BYTES=10485760

# IP 缓存变量
_CACHED_IPV4=""
_CACHED_IPV6=""

# 兼容精简 Alpine：BusyBox 镜像可能没有 pgrep，但通常提供 pidof。
# 最后一层直接检查 /proc，避免服务已经启动却被误判为“进程未运行”。
_pgrep() {
    local proc="$1"
    [[ -n "$proc" ]] || return 1

    if command -v pgrep >/dev/null 2>&1; then
        if [[ "$DISTRO" == "alpine" ]]; then
            # Alpine busybox pgrep 可能不支持 -x。
            pgrep "$proc" >/dev/null 2>&1 && return 0
            pgrep -f "$proc" >/dev/null 2>&1 && return 0
        else
            pgrep -x "$proc" >/dev/null 2>&1 && return 0
        fi
    fi

    if command -v pidof >/dev/null 2>&1; then
        pidof "$proc" >/dev/null 2>&1 && return 0
    fi

    local proc_dir comm cmdline
    for proc_dir in /proc/[0-9]*; do
        [[ -r "$proc_dir/comm" ]] || continue
        IFS= read -r comm < "$proc_dir/comm" 2>/dev/null || continue
        [[ "$comm" == "$proc" ]] && return 0

        # Linux comm 最多保存 15 个字符；长进程名再检查 argv[0]。
        if [[ ${#proc} -gt 15 && -r "$proc_dir/cmdline" ]]; then
            cmdline=$(tr '\0' ' ' < "$proc_dir/cmdline" 2>/dev/null)
            [[ "${cmdline%% *}" == */"$proc" || "${cmdline%% *}" == "$proc" ]] && return 0
        fi
    done
    return 1
}

#═══════════════════════════════════════════════════════════════════════════════
#  全局状态数据库 (JSON)
#═══════════════════════════════════════════════════════════════════════════════
readonly DB_FILE="$CFG/db.json"
readonly DB_LOCK_FILE="$CFG/.db.lock"
DB_LOCK_FD=""
DB_LOCK_DIR_HELD=false

_db_lock_acquire() {
    mkdir -p "$CFG" || return 1
    if command -v flock >/dev/null 2>&1; then
        exec {DB_LOCK_FD}>"$DB_LOCK_FILE" || return 1
        flock -x "$DB_LOCK_FD" || {
            exec {DB_LOCK_FD}>&-
            DB_LOCK_FD=""
            return 1
        }
    else
        local lock_dir="${DB_LOCK_FILE}.d" owner attempt
        for ((attempt=0; attempt<200; attempt++)); do
            if mkdir "$lock_dir" 2>/dev/null; then
                printf '%s\n' "$$" >"$lock_dir/pid"
                DB_LOCK_DIR_HELD=true
                return 0
            fi
            owner=$(cat "$lock_dir/pid" 2>/dev/null || true)
            if [[ -n "$owner" && "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
                rm -f "$lock_dir/pid" 2>/dev/null
                rmdir "$lock_dir" 2>/dev/null || true
                continue
            fi
            sleep 0.05
        done
        _err "等待数据库锁超时"
        return 1
    fi
}

_db_lock_release() {
    if [[ -n "${DB_LOCK_FD:-}" ]]; then
        flock -u "$DB_LOCK_FD" 2>/dev/null || true
        exec {DB_LOCK_FD}>&-
        DB_LOCK_FD=""
    fi
    if [[ "${DB_LOCK_DIR_HELD:-false}" == "true" ]]; then
        rm -f "${DB_LOCK_FILE}.d/pid" 2>/dev/null
        rmdir "${DB_LOCK_FILE}.d" 2>/dev/null || true
        DB_LOCK_DIR_HELD=false
    fi
}

# 初始化数据库
init_db() {
    mkdir -p "$CFG" || return 1
    # 允许 Nginx 按随机订阅路径穿越目录，但禁止普通用户列出目录内容。
    chmod 711 "$CFG" 2>/dev/null || true
    _db_lock_acquire || return 1
    local now tmp
    if [[ -f "$DB_FILE" ]]; then
        chmod 600 "$DB_FILE" 2>/dev/null || true
        if jq -e '(.snell | type) == "object" and (.singbox | type) == "object"' \
          "$DB_FILE" >/dev/null 2>&1; then
            _db_lock_release
            return 0
        fi
        tmp=$(mktemp "${DB_FILE}.upgrade.XXXXXX") || { _db_lock_release; return 1; }
        if jq '.snell = (if (.snell | type) == "object" then .snell else {} end) |
               .singbox = (if (.singbox | type) == "object" then .singbox else {} end)' \
          "$DB_FILE" >"$tmp" 2>/dev/null && chmod 600 "$tmp" && mv "$tmp" "$DB_FILE"; then
            _db_lock_release
            return 0
        fi
        rm -f "$tmp"
        _db_lock_release
        return 1
    fi
    # Alpine busybox date 不支持 -Iseconds，使用兼容格式
    now=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    tmp=$(mktemp "${DB_FILE}.init.XXXXXX") || { _db_lock_release; return 1; }
    if jq -n --arg v "4.0.0" --arg t "$now" \
      '{version:$v,snell:{},singbox:{},meta:{created:$t,updated:$t}}' >"$tmp" 2>/dev/null; then
        if chmod 600 "$tmp" && mv "$tmp" "$DB_FILE"; then
            _db_lock_release
            return 0
        fi
        rm -f "$tmp"
        _db_lock_release
        return 1
    fi
    # jq 失败时使用简单方式创建
    if printf '%s\n' '{"version":"4.0.0","snell":{},"singbox":{},"meta":{}}' >"$tmp" &&
       chmod 600 "$tmp" && mv "$tmp" "$DB_FILE"; then
        _db_lock_release
        return 0
    fi
    rm -f "$tmp"
    _db_lock_release
    return 1
}

# 更新数据库时间戳
_db_touch() {
    [[ -f "$DB_FILE" ]] || init_db || return 1
    _db_lock_acquire || return 1
    local now tmp
    # Alpine busybox date 不支持 -Iseconds，使用兼容格式
    now=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    tmp=$(mktemp "${DB_FILE}.touch.XXXXXX") || { _db_lock_release; return 1; }
    if jq --arg t "$now" '.meta.updated=$t' "$DB_FILE" >"$tmp"; then
        if chmod 600 "$tmp" && mv "$tmp" "$DB_FILE"; then
            _db_lock_release
            return 0
        fi
        rm -f "$tmp"
        _db_lock_release
        return 1
    else
        rm -f "$tmp"
        _db_lock_release
        return 1
    fi
}

_db_apply() { # _db_apply [jq args...] 'filter'
    [[ -f "$DB_FILE" ]] || init_db || return 1
    _db_lock_acquire || return 1
    local tmp final now
    tmp=$(mktemp "${DB_FILE}.apply.XXXXXX") || { _db_lock_release; return 1; }
    final=$(mktemp "${DB_FILE}.final.XXXXXX") || { rm -f "$tmp"; _db_lock_release; return 1; }
    now=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    if jq "$@" "$DB_FILE" >"$tmp" 2>/dev/null &&
       jq --arg t "$now" '.meta.updated=$t' "$tmp" >"$final" 2>/dev/null &&
       chmod 600 "$final" && mv "$final" "$DB_FILE"; then
        rm -f "$tmp"
        _db_lock_release
        return 0
    fi
    rm -f "$tmp" "$final"
    _db_lock_release
    return 1
}


# 添加协议到数据库
db_add() { # db_add core proto json
    local core="$1" proto="$2" json="$3"

    # 验证 JSON 格式
    if ! echo "$json" | jq empty 2>/dev/null; then
        _err "db_add: 无效的 JSON 格式 - $proto"
        return 1
    fi

    _db_apply --arg p "$proto" --argjson c "$json" ".${core}[\$p]=\$c"
}


# 获取协议配置（支持多端口实例）
# 返回: JSON配置（数组或单个对象）
db_get() {
    local core="$1" protocol="$2"
    [[ ! -f "$DB_FILE" ]] && return 1

    local config=$(jq --arg c "$core" --arg p "$protocol" \
        '.[$c][$p] // empty' "$DB_FILE" 2>/dev/null)

    [[ -z "$config" || "$config" == "null" ]] && return 1

    # 直接返回配置（保持 JSON 格式）
    echo "$config"
}

# 以紧凑的一行一个对象的形式迭代协议记录，兼容旧的单对象和新的多端口数组。
# 参数: $1=core, $2=protocol
# 输出: 每行一个 JSON 对象
db_protocol_configs() {
    local core="$1" protocol="$2"
    [[ -f "$DB_FILE" ]] || return 1

    jq -c --arg c "$core" --arg p "$protocol" '
        .[$c][$p] // empty |
        if type == "array" then .[] elif type == "object" then . else empty end
    ' "$DB_FILE" 2>/dev/null
}

# 从数据库获取协议的某个字段
db_get_field() {
    [[ ! -f "$DB_FILE" ]] && return 1
    jq -r --arg p "$2" --arg f "$3" ".${1}[\$p][\$f] // empty" "$DB_FILE" 2>/dev/null
}

# 返回: 端口列表，每行一个端口号
db_list_ports() {
    local core="$1" protocol="$2"
    [[ ! -f "$DB_FILE" ]] && return 1

    local config=$(jq --arg c "$core" --arg p "$protocol" \
        '.[$c][$p] // empty' "$DB_FILE" 2>/dev/null)

    [[ -z "$config" || "$config" == "null" ]] && return 1

    # 检查是否为数组
    if echo "$config" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "$config" | jq -r '.[].port'
    else
        # 兼容旧格式（单个对象）
        echo "$config" | jq -r '.port // empty'
    fi
}

# 获取指定端口的配置
# 参数: $1=core, $2=protocol, $3=port
# 返回: JSON配置对象
db_get_port_config() {
    local core="$1" protocol="$2" port="$3"
    [[ ! -f "$DB_FILE" ]] && return 1

    local config=$(jq --arg c "$core" --arg p "$protocol" \
        '.[$c][$p] // empty' "$DB_FILE" 2>/dev/null)

    [[ -z "$config" || "$config" == "null" ]] && return 1

    if echo "$config" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "$config" | jq --arg port "$port" '.[] | select(.port == ($port | tonumber))'
    else
        # 兼容旧格式
        local existing_port=$(echo "$config" | jq -r '.port')
        [[ "$existing_port" == "$port" ]] && echo "$config"
    fi
}

# 添加端口实例到协议
# 参数: $1=core, $2=protocol, $3=port_config_json
db_add_port() {
    local core="$1" protocol="$2" port_config="$3"
    [[ ! -f "$DB_FILE" ]] && return 1

    # 提取要添加的端口号
    local new_port=$(echo "$port_config" | jq -r '.port')

    # 检查端口是否已存在
    local existing_ports=$(db_list_ports "$core" "$protocol")
    if echo "$existing_ports" | grep -q "^${new_port}$"; then
        echo -e "${YELLOW}警告: 端口 $new_port 已存在于协议 $protocol 中，跳过添加${NC}" >&2
        return 0
    fi

    _db_apply --arg c "$core" --arg p "$protocol" --argjson cfg "$port_config" '
        .[$c][$p] = (
            if .[$c][$p] then
                if (.[$c][$p] | type) == "array" then
                    .[$c][$p] + [$cfg]
                else
                    [.[$c][$p], $cfg]
                end
            else
                [$cfg]
            end
        )
    '
}

# 删除指定端口实例
# 参数: $1=core, $2=protocol, $3=port
db_remove_port() {
    local core="$1" protocol="$2" port="$3"
    [[ ! -f "$DB_FILE" ]] && return 1

    _db_apply --arg c "$core" --arg p "$protocol" --arg port "$port" '
        .[$c][$p] = (
            if (.[$c][$p] | type) == "array" then
                .[$c][$p] | map(select(.port != ($port | tonumber)))
            else
                if .[$c][$p].port == ($port | tonumber) then
                    null
                else
                    .[$c][$p]
                end
            end
        ) | if .[$c][$p] == [] or .[$c][$p] == null then
            del(.[$c][$p])
        else
            .
        end
    '
}

# 更新指定端口的配置
# 参数: $1=core, $2=protocol, $3=port, $4=new_config_json
db_update_port() {
    local core="$1" protocol="$2" port="$3" new_config="$4"
    [[ ! -f "$DB_FILE" ]] && return 1

    _db_apply --arg c "$core" --arg p "$protocol" --arg port "$port" --argjson cfg "$new_config" '
        .[$c][$p] = (
            if (.[$c][$p] | type) == "array" then
                .[$c][$p] | map(if .port == ($port | tonumber) then $cfg else . end)
            else
                if .[$c][$p].port == ($port | tonumber) then
                    $cfg
                else
                    .[$c][$p]
                end
            end
        )
    '
}

# 删除协议
db_del() { # db_del core proto
    _db_apply --arg p "$2" "del(.${1}[\$p])"
}


# 检查协议是否存在
db_exists() {
    [[ ! -f "$DB_FILE" ]] && return 1
    local val=$(jq -r --arg p "$2" ".${1}[\$p] // empty" "$DB_FILE" 2>/dev/null)
    [[ -n "$val" && "$val" != "null" ]]
}

# 获取某个核心下所有协议名
db_list_protocols() {
    [[ ! -f "$DB_FILE" ]] && return 1
    jq -r ".${1} | keys[]" "$DB_FILE" 2>/dev/null
}

# 获取所有已安装协议
db_get_all_protocols() {
    [[ -f "$DB_FILE" ]] || return 1
    jq -r --arg protocols "$SINGBOX_PROTOCOLS" --arg standalone "$STANDALONE_PROTOCOLS" '
        ((.singbox // {}) | keys[] as $p | select($protocols | split(" ") | index($p)) | $p),
        ((.snell // {}) | keys[] as $p | select($standalone | split(" ") | index($p)) | $p)
    ' "$DB_FILE" | sort -u
}

#═══════════════════════════════════════════════════════════════════════════════
#  多IP入出站配置 (IP Routing)
#═══════════════════════════════════════════════════════════════════════════════

# 获取系统所有公网IPv4地址
get_all_public_ipv4() {
    ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1 | sort -u
}

# 获取系统所有公网IPv6地址
get_all_public_ipv6() {
    ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2}' | cut -d'/' -f1 | grep -v '^fe80' | sort -u
}

# 获取系统所有公网IP (IPv4 + IPv6)
get_all_public_ips() {
    {
        get_all_public_ipv4
        get_all_public_ipv6
    } | sort -u
}

# 获取IP路由配置
db_get_ip_routing() {
    [[ ! -f "$DB_FILE" ]] && return 1
    jq -r '.ip_routing // empty' "$DB_FILE" 2>/dev/null
}

# 获取IP路由规则列表
db_get_ip_routing_rules() {
    [[ ! -f "$DB_FILE" ]] && return 1
    jq -r '.ip_routing.rules // []' "$DB_FILE" 2>/dev/null
}

# 检查IP路由是否启用
db_ip_routing_enabled() {
    [[ ! -f "$DB_FILE" ]] && return 1
    local enabled=$(jq -r '.ip_routing.enabled // false' "$DB_FILE" 2>/dev/null)
    [[ "$enabled" == "true" ]]
}

# 添加IP路由规则
# 用法: db_add_ip_routing_rule "入站IP" "出站IP"
db_add_ip_routing_rule() {
    local inbound_ip="$1"
    local outbound_ip="$2"
    [[ -z "$inbound_ip" || -z "$outbound_ip" ]] && return 1
    [[ ! -f "$DB_FILE" ]] && init_db

    _db_apply --arg in_ip "$inbound_ip" --arg out_ip "$outbound_ip" '
        .ip_routing.enabled = true |
        .ip_routing.rules = ((.ip_routing.rules // []) |
            [.[] | select(.inbound_ip != $in_ip)] +
            [{"inbound_ip": $in_ip, "outbound_ip": $out_ip}])
    '
}

# 删除IP路由规则
# 用法: db_del_ip_routing_rule "入站IP"
db_del_ip_routing_rule() {
    local inbound_ip="$1"
    [[ -z "$inbound_ip" ]] && return 1
    [[ ! -f "$DB_FILE" ]] && return 1

    _db_apply --arg in_ip "$inbound_ip" '
        .ip_routing.rules = [(.ip_routing.rules // [])[] | select(.inbound_ip != $in_ip)]
    '
}

# 清空所有IP路由规则
db_clear_ip_routing_rules() {
    [[ ! -f "$DB_FILE" ]] && return 1
    _db_apply '.ip_routing.rules = []'
}

# 设置IP路由启用/禁用
db_set_ip_routing_enabled() {
    local enabled="$1"
    [[ ! -f "$DB_FILE" ]] && init_db
    _db_apply --argjson e "$enabled" '.ip_routing.enabled = $e'
}

# 获取指定入站IP的出站IP
db_get_ip_routing_outbound() {
    local inbound_ip="$1"
    [[ ! -f "$DB_FILE" ]] && return 1
    jq -r --arg in_ip "$inbound_ip" '
        (.ip_routing.rules // [])[] | select(.inbound_ip == $in_ip) | .outbound_ip
    ' "$DB_FILE" 2>/dev/null
}

#═══════════════════════════════════════════════════════════════════════════════
#  辅助函数 (用户管理需要)

#═══════════════════════════════════════════════════════════════════════════════

# 生成 UUID
gen_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        local value
        value=$(openssl rand -hex 16) || return 1
        printf '%s-%s-4%s-a%s-%s\n' "${value:0:8}" "${value:8:4}" "${value:13:3}" "${value:17:3}" "${value:20:12}"
    fi
}

# 生成随机密码
gen_password() {
    local length="${1:-16}"
    head -c 32 /dev/urandom 2>/dev/null | base64 | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

# 可安全用于 URI、Snell/Caddy 配置和 JSON 字段的凭据字符集。
_is_safe_credential() {
    local value="$1"
    [[ -n "$value" && "$value" =~ ^[a-zA-Z0-9._~!@%+=,-]+$ ]]
}

# 询问密码（支持自定义或自动生成）
# 用法: ask_password [长度] [提示文本]
ask_password() {
    local length="${1:-16}"
    local prompt="${2:-密码}"
    local password=""

    while true; do
        read -rsp "请输入${prompt} (直接回车自动生成): " password
        echo "" >&2
        if [[ -z "$password" ]]; then
            password=$(gen_password "$length")
            break
        fi
        # 排除空白、引号、反斜杠及 shell/config 分隔符。
        if _is_safe_credential "$password"; then
            break
        fi
        _err "${prompt}只能包含字母、数字及 . _ ~ ! @ % + = , -"
    done

    echo "$password"
}

# 获取协议的中文显示名
get_protocol_name() {
    case "$1" in
        vless-singbox) echo 'VLESS Vision REALITY' ;;
        snell-v5) echo 'Snell v5 (sing-box)' ;;
        snell-v5-official) echo 'Snell v5 (Surge 原厂)' ;;
        snell-v6) echo 'Snell v6 (Surge 原厂)' ;;
        snell-v6-singbox) echo 'Snell v6 (sing-box)' ;;
        ss2022-shadowtls) echo 'SS2022 + ShadowTLS v3' ;;
        ss2022) echo SS2022 ;;
        ss-legacy) echo Shadowsocks ;;
        socks) echo SOCKS5 ;;
        hy2) echo Hysteria2 ;;
        tuic) echo TUIC ;;
        anytls) echo AnyTLS ;;
        naive) echo Naive ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# 独立协议由独立二进制运行，使用配置文件中的固定密钥
# 用法: is_standalone_protocol "snell" -> 返回 0 表示是独立协议
is_standalone_protocol() {
    local proto="$1"
    [[ " $STANDALONE_PROTOCOLS " == *" $proto "* ]]
}

#═══════════════════════════════════════════════════════════════════════════════
#  多用户配置生成辅助函数
#═══════════════════════════════════════════════════════════════════════════════

# 输出: JSON 数组 [{id: "uuid1", email: "user@vless", flow: "..."}, ...]


#═══════════════════════════════════════════════════════════════════════════════
#  用户管理函数
#═══════════════════════════════════════════════════════════════════════════════

# 数据库结构说明:
# {
#     "vless": {
#       "port": 443,
#       "sni": "example.com",
#       "users": [
#       ]
#     }
#   }
# }
# enabled: 是否启用

# 添加用户到协议 (支持多端口数组格式)
# 多端口时：用户会添加到第一个端口实例的 users 数组（共享凭证）
db_add_user() {
    local core="$1" proto="$2" name="$3" uuid="$4" expire_date="${5:-}"
    [[ ! -f "$DB_FILE" ]] && return 1

    # 检查协议是否存在
    if ! db_exists "$core" "$proto"; then
        _err "协议 $proto 不存在"
        return 1
    fi

    # 检查是否为独立协议（不支持多用户）
    if is_standalone_protocol "$proto" || is_singbox_snell_protocol "$proto"; then
        _err "协议 $proto 使用固定 PSK，不支持添加用户"
        return 1
    fi



    # 检查用户名是否已存在 (支持多端口)
    local exists=$(jq -r --arg c "$core" --arg p "$proto" --arg n "$name" '
        .[$c][$p] as $cfg |
        if $cfg == null then 0
        elif ($cfg | type) == "array" then
            [$cfg[].users // [] | .[] | select(.name == $n)] | length
        else
            ($cfg.users // [] | map(select(.name == $n))) | length
        end
    ' "$DB_FILE" 2>/dev/null)
    if [[ "$exists" -gt 0 ]]; then
        _err "用户 $name 已存在"
        return 1
    fi

    local created=$(date '+%Y-%m-%d')

    # 添加用户 (支持多端口数组，包含 expire_date)
    _db_apply --arg c "$core" --arg p "$proto" --arg n "$name" --arg u "$uuid" \
       --arg cr "$created" --arg exp "$expire_date" '
        .[$c][$p] as $cfg |
        if ($cfg | type) == "array" then
            # 多端口: 添加到第一个端口实例
            .[$c][$p][0].users = ((.[$c][$p][0].users // []) + [{name:$n,uuid:$u,enabled:true,created:$cr,expire_date:$exp}])
        else
            # 单端口: 正常添加
            .[$c][$p].users = ((.[$c][$p].users // []) + [{name:$n,uuid:$u,enabled:true,created:$cr,expire_date:$exp}])
        end
    ' || return 1

    # 如果设置了到期日期，自动安装过期检查 cron
    [[ -n "$expire_date" ]] && ensure_expire_check_cron 2>/dev/null

    # 自动重建配置
    [[ "$core" == "singbox" ]] && rebuild_and_reload_singbox "silent"
}


# 删除用户 (支持多端口数组格式)
db_del_user() {
    local core="$1" proto="$2" name="$3"
    [[ ! -f "$DB_FILE" ]] && return 1

    _db_apply --arg c "$core" --arg p "$proto" --arg n "$name" '
        .[$c][$p] as $cfg |
        if ($cfg | type) == "array" then
            # 多端口: 从所有端口实例中删除该用户
            .[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] | select(.name != $n)])]
        else
            # 单端口
            .[$c][$p].users = [.[$c][$p].users // [] | .[] | select(.name != $n)]
        end
    ' || return 1

    # 自动重建配置
    [[ "$core" == "singbox" ]] && rebuild_and_reload_singbox "silent"
}

# 获取用户信息 (支持多端口数组格式)
db_get_user() {
    local core="$1" proto="$2" name="$3"
    [[ ! -f "$DB_FILE" ]] && return 1

    jq -r --arg c "$core" --arg p "$proto" --arg n "$name" '
        .[$c][$p] as $cfg |
        if $cfg == null then
            empty
        elif ($cfg | type) == "array" then
            # 多端口: 合并所有端口的 users 数组查找
            [$cfg[].users // [] | .[] | select(.name == $n)] | .[0] // empty
        else
            # 单端口
            ($cfg.users // [] | map(select(.name == $n)) | .[0]) // empty
        end
    ' "$DB_FILE" 2>/dev/null
}

# 获取用户的某个字段 (支持多端口数组格式)
db_get_user_field() {
    local core="$1" proto="$2" name="$3" field="$4"
    [[ ! -f "$DB_FILE" ]] && return 1

    jq -r --arg c "$core" --arg p "$proto" --arg n "$name" --arg f "$field" '
        .[$c][$p] as $cfg |
        if $cfg == null then
            empty
        elif ($cfg | type) == "array" then
            [$cfg[].users // [] | .[] | select(.name == $n)] | .[0][$f] | if . == null then empty else . end
        else
            ($cfg.users // [] | map(select(.name == $n)) | .[0][$f]) | if . == null then empty else . end
        end
    ' "$DB_FILE" 2>/dev/null
}

# 设置用户 Telegram 绑定信息（支持单端口和多端口配置）
db_set_user_tg_binding() {
    local core="$1" proto="$2" name="$3" chat_id="$4" tg_username="$5" bound_at="$6"
    [[ ! -f "$DB_FILE" ]] && return 1

    _db_apply --arg c "$core" --arg p "$proto" --arg n "$name" \
        --arg chat "$chat_id" --arg username "$tg_username" --arg at "$bound_at" '
        .[$c][$p] as $cfg |
        if ($cfg | type) == "array" then
            .[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] |
                if .name == $n then
                    .telegram_chat_id = $chat |
                    .telegram_username = $username |
                    .telegram_bound_at = $at |
                    del(.telegram_bind_token_hash, .telegram_bind_expires_at)
                else . end
            ])]
        else
            .[$c][$p].users = [.[$c][$p].users // [] | .[] |
                if .name == $n then
                    .telegram_chat_id = $chat |
                    .telegram_username = $username |
                    .telegram_bound_at = $at |
                    del(.telegram_bind_token_hash, .telegram_bind_expires_at)
                else . end
            ]
        end
    '
}

db_set_user_tg_bind_token() {
    local core="$1" proto="$2" name="$3" token_hash="$4" expires_at="$5"
    [[ ! -f "$DB_FILE" ]] && return 1

    _db_apply --arg c "$core" --arg p "$proto" --arg n "$name" \
        --arg hash "$token_hash" --argjson expires "$expires_at" '
        .[$c][$p] as $cfg |
        if ($cfg | type) == "array" then
            .[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] |
                if .name == $n then
                    .telegram_bind_token_hash = $hash |
                    .telegram_bind_expires_at = $expires
                else . end
            ])]
        else
            .[$c][$p].users = [.[$c][$p].users // [] | .[] |
                if .name == $n then
                    .telegram_bind_token_hash = $hash |
                    .telegram_bind_expires_at = $expires
                else . end
            ]
        end
    '
}

db_clear_user_tg_binding() {
    local core="$1" proto="$2" name="$3"
    [[ ! -f "$DB_FILE" ]] && return 1

    _db_apply --arg c "$core" --arg p "$proto" --arg n "$name" '
        .[$c][$p] as $cfg |
        if ($cfg | type) == "array" then
            .[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] |
                if .name == $n then
                    del(.telegram_chat_id, .telegram_username, .telegram_bound_at,
                        .telegram_bind_token_hash, .telegram_bind_expires_at)
                else . end
            ])]
        else
            .[$c][$p].users = [.[$c][$p].users // [] | .[] |
                if .name == $n then
                    del(.telegram_chat_id, .telegram_username, .telegram_bound_at,
                        .telegram_bind_token_hash, .telegram_bind_expires_at)
                else . end
            ]
        end
    '
}

# 输出 core|proto|name；绑定码只保存 SHA-256，且必须仍在有效期内。
db_find_user_by_tg_bind_hash() {
    local token_hash="$1" now_epoch="$2"
    [[ ! -f "$DB_FILE" ]] && return 1
    jq -r --arg hash "$token_hash" --argjson now "$now_epoch" '
        ["singbox"][] as $core |
        (.[$core] // {} | to_entries[]) as $proto_entry |
        $proto_entry.key as $proto |
        (if ($proto_entry.value | type) == "array" then $proto_entry.value[] else $proto_entry.value end) |
        (.users // [])[] |
        select((.telegram_bind_token_hash // "") == $hash) |
        select(((((.telegram_bind_expires_at // 0) | tonumber?) // 0)) >= $now) |
        "\($core)|\($proto)|\(.name)"
    ' "$DB_FILE" 2>/dev/null | head -n1
}

# 输出 core|proto|name；每个私聊 Chat ID 只允许绑定一个脚本用户。
db_find_user_by_tg_chat() {
    local chat_id="$1"
    [[ ! -f "$DB_FILE" ]] && return 1
    jq -r --arg chat "$chat_id" '
        ["singbox"][] as $core |
        (.[$core] // {} | to_entries[]) as $proto_entry |
        $proto_entry.key as $proto |
        (if ($proto_entry.value | type) == "array" then $proto_entry.value[] else $proto_entry.value end) |
        (.users // [])[] |
        select((.telegram_chat_id // "") == $chat) |
        "\($core)|\($proto)|\(.name)"
    ' "$DB_FILE" 2>/dev/null | head -n1
}

# 输出 core|proto|name|chat_id|telegram_username|bound_at
db_list_tg_user_bindings() {
    [[ ! -f "$DB_FILE" ]] && return 1
    jq -r '
        ["singbox"][] as $core |
        (.[$core] // {} | to_entries[]) as $proto_entry |
        $proto_entry.key as $proto |
        (if ($proto_entry.value | type) == "array" then $proto_entry.value[] else $proto_entry.value end) |
        (.users // [])[] |
        select((.telegram_chat_id // "") != "") |
        "\($core)|\($proto)|\(.name)|\(.telegram_chat_id)|\(.telegram_username // "")|\(.telegram_bound_at // "")"
    ' "$DB_FILE" 2>/dev/null
}

# 列出协议的所有用户 (支持多端口数组格式)
# 多端口时合并所有端口的用户列表，无 users 数组时返回 "default"
db_list_users() {
    local core="$1" proto="$2"
    [[ ! -f "$DB_FILE" ]] && return 1

    jq -r --arg c "$core" --arg p "$proto" '
        .[$c][$p] as $cfg |
        if $cfg == null then
            empty
        elif ($cfg | type) == "array" then
            # 多端口: 合并所有端口的 users，无 users 时输出 "default"（与 用户名 格式一致）
            ($cfg | map(
                if (.users | length) > 0 then
                    .users[].name
                elif (.uuid != null or .password != null) then
                    "default"
                else
                    empty
                end
            ) | unique | .[]) // empty
        else
            # 单端口
            if ($cfg.users | length) > 0 then
                $cfg.users[].name
            elif ($cfg.uuid != null or $cfg.password != null) then
                "default"
            else
                empty
            end
        end
    ' "$DB_FILE" 2>/dev/null
}

# 获取协议的用户数量
# 支持三种配置格式：
#   1. 有 users 数组: 返回 users 数组长度
#   2. 单端口旧格式 (无 users 但有 uuid/password): 返回 1
#   3. 多端口数组 (无 users 但每个端口有 uuid/password): 返回端口实例数量
db_count_users() {
    local core="$1" proto="$2"
    [[ ! -f "$DB_FILE" ]] && return 1

    # 使用 jq 一次性计算，处理所有情况
    local count=$(jq -r --arg c "$core" --arg p "$proto" '
        .[$c][$p] as $cfg |
        if $cfg == null then
            0
        elif ($cfg | type) == "array" then
            # 多端口数组: 统计所有端口的 users，或统计有 uuid/password 的端口数
            ($cfg | map(.users // [] | length) | add) as $users_total |
            if $users_total > 0 then
                $users_total
            else
                # 没有 users 数组，统计有默认凭证的端口数
                [$cfg[] | select(.uuid != null or .password != null)] | length
            end
        else
            # 单端口对象
            ($cfg.users // [] | length) as $users_len |
            if $users_len > 0 then
                $users_len
            elif ($cfg.uuid != null or $cfg.password != null) then
                1
            else
                0
            end
        end
    ' "$DB_FILE" 2>/dev/null)

    echo "${count:-0}"
}


# 设置用户配额 (支持多端口数组格式)


# 启用/禁用用户 (支持多端口数组格式)
db_set_user_enabled() {
    local core="$1" proto="$2" name="$3" enabled="$4"
    [[ ! -f "$DB_FILE" ]] && return 1

    _db_apply --arg c "$core" --arg p "$proto" --arg n "$name" --argjson e "$enabled" '
        .[$c][$p] as $cfg |
        if ($cfg | type) == "array" then
            .[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] | if .name == $n then .enabled = $e else . end])]
        else
            .[$c][$p].users = [.[$c][$p].users // [] | .[] | if .name == $n then .enabled = $e else . end]
        end
    ' || return 1

    # 自动重建配置
    case "$core" in
        singbox) rebuild_and_reload_singbox "silent" ;;
        *) return 0 ;;
    esac
}



# 获取用户告警状态 (用于防止重复通知)
db_get_user_alert_state() {
    local core="$1" proto="$2" name="$3" field="$4"
    [[ "$field" == last_expire_warn_day ]] || return 1
    [[ ! -f "$DB_FILE" ]] && return 1

    jq -r --arg c "$core" --arg p "$proto" --arg n "$name" --arg f "$field" '
        .[$c][$p] as $cfg |
        if $cfg == null then ""
        elif ($cfg | type) == "array" then
            [$cfg[].users // [] | .[] | select(.name == $n)] | .[0][$f] // ""
        else
            ($cfg.users // [] | map(select(.name == $n)) | .[0][$f]) // ""
        end
    ' "$DB_FILE" 2>/dev/null
}

# 设置用户告警状态 (支持多端口数组格式)
db_set_user_alert_state() {
    local core="$1" proto="$2" name="$3" field="$4" value="$5"
    [[ "$field" == last_expire_warn_day ]] || return 1
    [[ ! -f "$DB_FILE" ]] && return 1

    # 根据值类型选择合适的 jq 参数
    if [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
        _db_apply --arg c "$core" --arg p "$proto" --arg n "$name" --arg f "$field" --argjson v "$value" '
            .[$c][$p] as $cfg |
            if ($cfg | type) == "array" then
                .[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] | if .name == $n then .[$f] = $v else . end])]
            else
                .[$c][$p].users = [.[$c][$p].users // [] | .[] | if .name == $n then .[$f] = $v else . end]
            end
        '
    else
        _db_apply --arg c "$core" --arg p "$proto" --arg n "$name" --arg f "$field" --arg v "$value" '
            .[$c][$p] as $cfg |
            if ($cfg | type) == "array" then
                .[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] | if .name == $n then .[$f] = $v else . end])]
            else
                .[$c][$p].users = [.[$c][$p].users // [] | .[] | if .name == $n then .[$f] = $v else . end]
            end
        '
    fi
}
# 设置用户路由 (支持多端口数组格式)
# routing 值说明:
#   "" 或 null - 使用全局规则
#   "direct" - 直连出站
#   "warp" - WARP 出站
#   "chain:节点名" - 链式代理指定节点
#   "balancer:组名" - 负载均衡组
db_set_user_routing() {
    local core="$1" proto="$2" name="$3" routing="$4"
    [[ ! -f "$DB_FILE" ]] && return 1

    _db_apply --arg c "$core" --arg p "$proto" --arg n "$name" --arg r "$routing" '
        .[$c][$p] as $cfg |
        if ($cfg | type) == "array" then
            .[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] | if .name == $n then .routing = $r else . end])]
        else
            .[$c][$p].users = [.[$c][$p].users // [] | .[] | if .name == $n then .routing = $r else . end]
        end
    ' || return 1

    # 自动重建配置
    [[ "$core" == "singbox" ]] && rebuild_and_reload_singbox "silent"
}

# 获取用户路由 (支持多端口数组格式)
# 返回: routing 值，空表示使用全局规则
db_get_user_routing() {
    local core="$1" proto="$2" name="$3"
    [[ ! -f "$DB_FILE" ]] && return 1

    jq -r --arg c "$core" --arg p "$proto" --arg n "$name" '
        .[$c][$p] as $cfg |
        if $cfg == null then ""
        elif ($cfg | type) == "array" then
            [$cfg[].users // [] | .[] | select(.name == $n)] | .[0].routing // ""
        else
            ($cfg.users // [] | map(select(.name == $n)) | .[0].routing) // ""
        end
    ' "$DB_FILE" 2>/dev/null
}

# 格式化显示用户路由
# 用法: _format_user_routing "direct" -> "直连"
_format_user_routing() {
    local routing="$1"
    case "$routing" in
        ""|null) echo "全局规则" ;;
        direct) echo "直连" ;;
        warp) echo "WARP" ;;
        chain:*) echo "链路→${routing#chain:}" ;;
        balancer:*) echo "负载→${routing#balancer:}" ;;
        *) echo "$routing" ;;
    esac
}

#═══════════════════════════════════════════════════════════════════════════════
#  用户到期日期管理函数
#═══════════════════════════════════════════════════════════════════════════════

# 设置用户到期日期 (支持多端口数组格式)
# 空字符串或 "never" 表示永不过期
db_set_user_expire_date() {
    local core="$1" proto="$2" name="$3" expire_date="$4"
    [[ ! -f "$DB_FILE" ]] && return 1

    # 处理特殊值
    [[ "$expire_date" == "never" ]] && expire_date=""

    _db_apply --arg c "$core" --arg p "$proto" --arg n "$name" --arg e "$expire_date" '
        .[$c][$p] as $cfg |
        if ($cfg | type) == "array" then
            .[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] | if .name == $n then .expire_date = $e else . end])]
        else
            .[$c][$p].users = [.[$c][$p].users // [] | .[] | if .name == $n then .expire_date = $e else . end]
        end
    ' || return 1

    # 如果设置了到期日期，自动安装过期检查 cron
    [[ -n "$expire_date" ]] && ensure_expire_check_cron 2>/dev/null
}

# 获取用户到期日期
# 返回: YYYY-MM-DD 格式的日期，空表示永不过期
db_get_user_expire_date() {
    local core="$1" proto="$2" name="$3"
    [[ ! -f "$DB_FILE" ]] && return 1

    jq -r --arg c "$core" --arg p "$proto" --arg n "$name" '
        .[$c][$p] as $cfg |
        if $cfg == null then ""
        elif ($cfg | type) == "array" then
            [$cfg[].users // [] | .[] | select(.name == $n)] | .[0].expire_date // ""
        else
            ($cfg.users // [] | map(select(.name == $n)) | .[0].expire_date) // ""
        end
    ' "$DB_FILE" 2>/dev/null
}

# 检查用户是否已过期
# 返回: 0=已过期, 1=未过期或永不过期
db_is_user_expired() {
    local core="$1" proto="$2" name="$3"
    local expire_date=$(db_get_user_expire_date "$core" "$proto" "$name")

    # 空日期表示永不过期
    [[ -z "$expire_date" ]] && return 1

    # 比较日期 (YYYY-MM-DD 格式可直接字符串比较)
    local today=$(date '+%Y-%m-%d')
    [[ "$today" > "$expire_date" ]]
}

# 获取用户剩余天数
# 返回: 剩余天数 (负数表示已过期，空表示永不过期)
db_get_user_days_left() {
    local core="$1" proto="$2" name="$3"
    local expire_date=$(db_get_user_expire_date "$core" "$proto" "$name")

    [[ -z "$expire_date" ]] && echo "" && return

    local today_sec=$(date -d "$(date '+%Y-%m-%d')" '+%s' 2>/dev/null || date -j -f '%Y-%m-%d' "$(date '+%Y-%m-%d')" '+%s' 2>/dev/null)
    local expire_sec=$(date -d "$expire_date" '+%s' 2>/dev/null || date -j -f '%Y-%m-%d' "$expire_date" '+%s' 2>/dev/null)

    if [[ -n "$today_sec" && -n "$expire_sec" ]]; then
        echo $(( (expire_sec - today_sec) / 86400 ))
    else
        echo ""
    fi
}

# 获取即将过期的用户列表 (用于提醒)
# 用法: db_get_expiring_users [天数阈值，默认3]
# 输出: core|proto|name|expire_date|days_left (每行一个用户)
db_get_expiring_users() {
    local threshold="${1:-3}"
    local today=$(date '+%Y-%m-%d')

    [[ ! -f "$DB_FILE" ]] && return 1

    # 遍历所有协议的所有用户
    for core in singbox; do
        local protocols=$(db_list_protocols "$core" 2>/dev/null)
        [[ -z "$protocols" ]] && continue

        while read -r proto; do
            [[ -z "$proto" ]] && continue
            local users=$(db_list_users "$core" "$proto" 2>/dev/null)
            [[ -z "$users" ]] && continue

            while read -r name; do
                [[ -z "$name" ]] && continue
                local days_left=$(db_get_user_days_left "$core" "$proto" "$name")
                [[ -z "$days_left" ]] && continue

                # 检查是否在阈值范围内 (0 <= days_left <= threshold)
                if [[ "$days_left" -ge 0 && "$days_left" -le "$threshold" ]]; then
                    local expire_date=$(db_get_user_expire_date "$core" "$proto" "$name")
                    echo "${core}|${proto}|${name}|${expire_date}|${days_left}"
                fi
            done <<< "$users"
        done <<< "$protocols"
    done
}

# 获取所有已过期的用户列表
# 用法: db_get_expired_users
# 输出: core|proto|name|expire_date|days_left (每行一个用户)
db_get_expired_users() {
    local today=$(date '+%Y-%m-%d')

    [[ ! -f "$DB_FILE" ]] && return 1

    for core in singbox; do
        local protocols=$(db_list_protocols "$core" 2>/dev/null)
        [[ -z "$protocols" ]] && continue

        while read -r proto; do
            [[ -z "$proto" ]] && continue
            local users=$(db_list_users "$core" "$proto" 2>/dev/null)
            [[ -z "$users" ]] && continue

            while read -r name; do
                [[ -z "$name" ]] && continue
                local days_left=$(db_get_user_days_left "$core" "$proto" "$name")
                [[ -z "$days_left" ]] && continue

                # 已过期: days_left < 0
                if [[ "$days_left" -lt 0 ]]; then
                    local expire_date=$(db_get_user_expire_date "$core" "$proto" "$name")
                    local enabled=$(db_get_user_field "$core" "$proto" "$name" "enabled")
                    # 只返回仍然启用的过期用户（需要禁用）
                    [[ "$enabled" == "true" ]] && echo "${core}|${proto}|${name}|${expire_date}|${days_left}"
                fi
            done <<< "$users"
        done <<< "$protocols"
    done
}

#═══════════════════════════════════════════════════════════════════════════════
#  Telegram 通知功能
#═══════════════════════════════════════════════════════════════════════════════

# 获取 Telegram 配置
db_get_tg_config() {
    local field="$1"
    [[ ! -f "$DB_FILE" ]] && return 1
    jq -r --arg f "$field" '.telegram[$f] // ""' "$DB_FILE" 2>/dev/null
}

# 设置 Telegram 配置
db_set_tg_config() {
    local field="$1" value="$2"
    [[ ! -f "$DB_FILE" ]] && init_db
    _db_apply --arg f "$field" --arg v "$value" '.telegram[$f] = $v'
}

# 发送 Telegram 消息
send_tg_message() {
    local message="$1"
    # 当前管理界面使用 telegram.json；优先复用现有管理员通知配置。
    # 数据库中的 .telegram 仅作为旧版本兼容回退。
    if [[ -n "${TG_CONFIG_FILE:-}" && -f "$TG_CONFIG_FILE" && -n "$(tg_get_config "bot_token")" ]]; then
        tg_send_message "$message"
        return $?
    fi
    local bot_token=$(db_get_tg_config "bot_token")
    local chat_id=$(db_get_tg_config "chat_id")

    [[ -z "$bot_token" || -z "$chat_id" ]] && return 1

    curl -s -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "text=${message}" \
        -d "parse_mode=Markdown" \
        --connect-timeout 10 >/dev/null 2>&1
}

# 发送用户即将过期提醒
send_tg_expire_warning() {
    local name="$1" proto="$2" expire_date="$3" days_left="$4" core="${5:-}"
    local proto_name=$(get_protocol_name "$proto")
    local server_display=$(get_tg_server_display)

    local message="⚠️ *用户即将过期*
${server_display}
👤 用户: \`$name\`
📋 协议: $proto_name
📅 到期: $expire_date
⏰ 剩余: *${days_left}天*"

    send_tg_message "$message"
    if [[ -n "$core" ]]; then
        tg_send_bound_user_message "$core" "$proto" "$name" "⚠️ 账号即将到期
用户：${name}
协议：$(get_protocol_name "$proto")
到期时间：${expire_date}
剩余：${days_left} 天"
    fi
}

# 发送用户已过期通知
send_tg_expired_notice() {
    local name="$1" proto="$2" expire_date="$3" core="${4:-}"
    local proto_name=$(get_protocol_name "$proto")
    local server_display=$(get_tg_server_display)

    local message="🚫 *用户已过期禁用*
${server_display}
👤 用户: \`$name\`
📋 协议: $proto_name
📅 到期: $expire_date"

    send_tg_message "$message"
    if [[ -n "$core" ]]; then
        tg_send_bound_user_message "$core" "$proto" "$name" "🚫 账号已到期
用户：${name}
协议：$(get_protocol_name "$proto")
到期时间：${expire_date}
账号已自动禁用"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
#  过期检查和处理
#═══════════════════════════════════════════════════════════════════════════════

# 执行过期用户检查和禁用
check_and_disable_expired_users() {
    local notify="${1:-}"
    local count=0

    local expired_users=$(db_get_expired_users)
    [[ -z "$expired_users" ]] && echo "$count" && return 0

    while IFS='|' read -r core proto name expire_date days_left; do
        [[ -z "$name" ]] && continue
        if ! db_set_user_enabled "$core" "$proto" "$name" false; then
            _err "用户 $name ($proto) 禁用或配置重载失败" >&2
            continue
        fi
        ((count++))
        [[ "$notify" == "--notify" ]] && send_tg_expired_notice "$name" "$proto" "$expire_date" "$core"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 禁用: $name ($proto)" >> "$CFG/expire.log"
    done <<< "$expired_users"

    echo "$count"
}

# 发送即将过期提醒
send_expire_warnings() {
    local threshold="${1:-3}"
    local count=0

    local expiring_users=$(db_get_expiring_users "$threshold")
    [[ -z "$expiring_users" ]] && echo "$count" && return 0

    while IFS='|' read -r core proto name expire_date days_left; do
        [[ -z "$name" ]] && continue
        local last_warn=$(db_get_user_alert_state "$core" "$proto" "$name" "last_expire_warn_day")
        [[ "$last_warn" == "$days_left" ]] && continue
        send_tg_expire_warning "$name" "$proto" "$expire_date" "$days_left" "$core"
        db_set_user_alert_state "$core" "$proto" "$name" "last_expire_warn_day" "$days_left"
        ((count++))
    done <<< "$expiring_users"

    echo "$count"
}

# 安装过期检查 cron job (每天 3:00)
install_expire_check_cron() {
    local script_path="$0"
    local cron_cmd="$(build_cron_command "0 3 * * *" "$script_path" "--check-expire --notify" "$CFG/expire.log") # check-expire"

    if crontab -l 2>/dev/null | grep -q "check-expire"; then
        _info "过期检查 cron 已存在"
        return 0
    fi

    [[ -n "$(get_bash_interpreter)" ]] || { _err "未找到 bash，无法安装过期检查 cron"; return 1; }
    install_cron_entry "check-expire" "$cron_cmd" && { _ok "已安装过期检查 cron (每天 3:00)"; echo -e "  ${D}日志: $CFG/expire.log${NC}"; } || _err "安装失败"
}

# 确保过期检查 cron 已安装（设置到期日期时自动调用）
# 返回: 0=已存在, 1=新安装成功, 2=安装失败
ensure_expire_check_cron() {
    local script_path="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    local cron_cmd="$(build_cron_command "0 3 * * *" "$script_path" "--check-expire --notify" "$CFG/expire.log") # check-expire"

    # 如果已存在则跳过
    if crontab -l 2>/dev/null | grep -q "check-expire"; then
        echo -e "  ${D}(过期检查定时任务已启用)${NC}"
        return 0
    fi

    # 尝试安装
    if [[ -z "$(get_bash_interpreter)" ]]; then
        echo -e "  ${Y}提示: 未找到 bash，无法安装过期检查定时任务${NC}"
        return 2
    fi

    if install_cron_entry "check-expire" "$cron_cmd"; then
        echo -e "  ${G}✓ 已自动安装过期检查定时任务 (每天 3:00)${NC}"
        echo -e "  ${D}日志: $CFG/expire.log${NC}"
        return 1
    else
        echo -e "  ${Y}提示: 过期检查定时任务未安装，可运行: ./vless-server.sh --setup-expire-cron${NC}"
        return 2
    fi
}

# 卸载过期检查 cron
uninstall_expire_check_cron() {
    remove_cron_entry "check-expire"
    _ok "已移除过期检查 cron"
}

# 多端口时合并所有端口的用户，无 users 的端口输出默认用户


# 迁移旧数据库到新格式 (兼容性)
# 将单用户配置迁移为多用户格式
db_migrate_to_multiuser() {
    [[ -f "$DB_FILE" ]] || return 0
    _db_apply '
        def migrate:
            if has("users") or ((.uuid // .password // .username // "") == "") then .
            else .users=[{name:"default",uuid:(.uuid // .password // .username),enabled:true}] end;
        .singbox |= with_entries(
            if .key == "snell-v5" or .key == "snell-v6-singbox" or .key == "ss2022-shadowtls" then . else
                .value |= (if type == "array" then map(migrate) else migrate end)
            end)
    '
}

# 用户变更后重建配置并重载服务
# 参数: silent - 如果设置则不输出成功信息


# 用户变更后重建 Sing-box 配置并重载服务
# 用法: rebuild_and_reload_singbox [silent]
# 参数: silent - 如果设置则不输出成功信息
rebuild_and_reload_singbox() {
    local silent="${1:-}"

    # 重新生成 Sing-box 配置
    if generate_singbox_config; then
        # 检查 Sing-box 服务是否在运行
        if svc status sing-singbox 2>/dev/null; then
            # 重载服务
            if svc restart sing-singbox 2>/dev/null; then
                [[ -z "$silent" ]] && _ok "Sing-box 配置已更新并重载"
                return 0
            else
                [[ -z "$silent" ]] && _warn "配置已更新，服务重载失败"
                return 1
            fi
        else
            [[ -z "$silent" ]] && _ok "Sing-box 配置已更新"
            return 0
        fi
    else
        [[ -z "$silent" ]] && _err "Sing-box 配置重建失败"
        return 1
    fi
}


#═══════════════════════════════════════════════════════════════════════════════
#  TG 通知配置
#═══════════════════════════════════════════════════════════════════════════════

readonly TG_CONFIG_FILE="$CFG/telegram.json"
readonly TG_CONFIG_LOCK_DIR="$CFG/.telegram.lock"

_tg_config_lock_acquire() {
    local attempt owner
    for ((attempt=0; attempt<200; attempt++)); do
        if mkdir "$TG_CONFIG_LOCK_DIR" 2>/dev/null; then
            printf '%s\n' "$$" > "$TG_CONFIG_LOCK_DIR/pid"
            return 0
        fi
        owner=$(cat "$TG_CONFIG_LOCK_DIR/pid" 2>/dev/null || true)
        if [[ -n "$owner" && "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
            rm -f "$TG_CONFIG_LOCK_DIR/pid" 2>/dev/null
            rmdir "$TG_CONFIG_LOCK_DIR" 2>/dev/null || true
            continue
        fi
        sleep 0.05
    done
    return 1
}

_tg_config_lock_release() {
    rm -f "$TG_CONFIG_LOCK_DIR/pid" 2>/dev/null
    rmdir "$TG_CONFIG_LOCK_DIR" 2>/dev/null || true
}

# 初始化 TG 配置
init_tg_config() {
    local defaults='{"enabled":false,"bot_token":"","chat_id":"","server_name":"","user_bot_enabled":false,"user_bot_last_update_id":0}'
    mkdir -p "$CFG" 2>/dev/null || return 1
    _tg_config_lock_acquire || return 1
    if [[ ! -f "$TG_CONFIG_FILE" ]]; then
        printf '%s\n' "$defaults" > "$TG_CONFIG_FILE" || { _tg_config_lock_release; return 1; }
        chmod 600 "$TG_CONFIG_FILE" 2>/dev/null || true
        _tg_config_lock_release
        return 0
    fi

    # 为旧配置补齐用户机器人字段，不改变现有管理员通知设置。
    local tmp
    tmp=$(mktemp "${TG_CONFIG_FILE}.migrate.XXXXXX") || { _tg_config_lock_release; return 1; }
    if jq --argjson defaults "$defaults" '$defaults * .' "$TG_CONFIG_FILE" > "$tmp" 2>/dev/null; then
        chmod 600 "$tmp" 2>/dev/null || true
        if mv "$tmp" "$TG_CONFIG_FILE"; then
            _tg_config_lock_release
            return 0
        fi
        rm -f "$tmp"
        _tg_config_lock_release
        return 1
    else
        rm -f "$tmp"
        _tg_config_lock_release
        return 1
    fi
}

# 获取 TG 模板里的服务器显示文本
get_tg_server_display() {
    local server_name=$(tg_get_config "server_name")
    local server_ip=$(get_ipv4)
    [[ -z "$server_ip" ]] && server_ip=$(get_ipv6)
    [[ -z "$server_ip" ]] && server_ip=$(hostname 2>/dev/null || echo "unknown")

    if [[ -n "$server_name" ]]; then
        printf '🔗 服务器: `%s`\n🌐 IP: `%s`' "$server_name" "$server_ip"
    else
        printf '🖥 服务器: `%s`' "$server_ip"
    fi
}

# 获取 TG 配置
tg_get_config() {
    local field="$1"
    [[ ! -f "$TG_CONFIG_FILE" ]] && init_tg_config
    jq -r ".$field // empty" "$TG_CONFIG_FILE" 2>/dev/null
}

# 设置 TG 配置
tg_set_config() {
    local field="$1" value="$2"
    [[ ! -f "$TG_CONFIG_FILE" ]] && init_tg_config
    _tg_config_lock_acquire || return 1

    local tmp
    tmp=$(mktemp "${TG_CONFIG_FILE}.tmp.XXXXXX") || { _tg_config_lock_release; return 1; }
    if [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
        jq --arg f "$field" --argjson v "$value" '.[$f] = $v' "$TG_CONFIG_FILE" > "$tmp" || { rm -f "$tmp"; _tg_config_lock_release; return 1; }
    else
        jq --arg f "$field" --arg v "$value" '.[$f] = $v' "$TG_CONFIG_FILE" > "$tmp" || { rm -f "$tmp"; _tg_config_lock_release; return 1; }
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    if mv "$tmp" "$TG_CONFIG_FILE"; then
        _tg_config_lock_release
        return 0
    fi
    rm -f "$tmp"
    _tg_config_lock_release
    return 1
}

# 发送 TG 消息
tg_send_message() {
    local message="$1"
    local bot_token=$(tg_get_config "bot_token")
    local chat_id=$(tg_get_config "chat_id")
    local enabled=$(tg_get_config "enabled")

    [[ "$enabled" != "true" ]] && return 0
    [[ -z "$bot_token" || -z "$chat_id" ]] && return 1

    curl -s -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "text=${message}" \
        -d "parse_mode=Markdown" \
        --connect-timeout 10 \
        >/dev/null 2>&1
}

# 调用 Telegram Bot API。用户机器人与管理员通知共用 Bot Token，开关相互独立。
tg_bot_api_request() {
    local method="$1"
    shift
    local bot_token
    bot_token=$(tg_get_config "bot_token")
    [[ -n "$bot_token" ]] || return 1
    curl -fsS -X POST "https://api.telegram.org/bot${bot_token}/${method}" \
        --connect-timeout 10 --max-time 25 "$@"
}

# 用户查询回复使用纯文本，避免用户名等用户字段触发 Markdown 解析。
tg_send_chat_message() {
    local chat_id="$1" message="$2" response
    [[ "$chat_id" =~ ^[0-9]+$ ]] || return 1
    response=$(tg_bot_api_request "sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${message}") || return 1
    jq -e '.ok == true' >/dev/null 2>&1 <<< "$response"
}

tg_send_bound_user_message() {
    local core="$1" proto="$2" user="$3" message="$4" chat_id
    [[ "$(tg_get_config "user_bot_enabled")" == "true" ]] || return 0
    chat_id=$(db_get_user_field "$core" "$proto" "$user" "telegram_chat_id")
    [[ -n "$chat_id" ]] || return 0
    tg_send_chat_message "$chat_id" "$message"
}

tg_hash_bind_token() {
    local token="$1"
    printf '%s' "$token" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
}

tg_generate_bind_token() {
    openssl rand -hex 6 2>/dev/null | tr '[:lower:]' '[:upper:]'
}

tg_user_bot_help_text() {
    cat <<'EOF'
可用命令：
/bind 绑定码  绑定您的代理账号
/status       查询账号状态和到期时间
/unbind       解除当前 Telegram 绑定
/help         显示帮助

绑定码由服务器管理员生成，24 小时内有效且只能在私聊中使用。
EOF
}

tg_get_user_report_by_chat() {
    local mapping core proto name enabled expire status=已启用
    mapping=$(db_find_user_by_tg_chat "$1")
    [[ -n "$mapping" ]] || return 1
    IFS='|' read -r core proto name <<< "$mapping"
    enabled=$(db_get_user_field "$core" "$proto" "$name" enabled)
    expire=$(db_get_user_expire_date "$core" "$proto" "$name")
    [[ "$enabled" == false ]] && status=已禁用
    db_is_user_expired "$core" "$proto" "$name" && status=已过期
    printf '用户：%s\n协议：%s\n账号状态：%s\n到期时间：%s\n' "$name" "$(get_protocol_name "$proto")" "$status" "${expire:-永不过期}"
}

tg_user_bot_bind_chat() {
    local chat_id="$1" tg_username="$2" token="$3"
    token=$(printf '%s' "$token" | tr '[:lower:]' '[:upper:]')
    if [[ ! "$token" =~ ^[A-F0-9]{12}$ ]]; then
        tg_send_chat_message "$chat_id" "绑定码格式无效，请向管理员获取新的 12 位绑定码。"
        return
    fi

    local current_mapping token_hash mapping core proto name
    current_mapping=$(db_find_user_by_tg_chat "$chat_id")
    if [[ -n "$current_mapping" ]]; then
        tg_send_chat_message "$chat_id" "此 Telegram 已绑定账号。如需更换，请先发送 /unbind。"
        return
    fi

    token_hash=$(tg_hash_bind_token "$token")
    [[ -n "$token_hash" ]] || {
        tg_send_chat_message "$chat_id" "服务器无法校验绑定码，请联系管理员。"
        return
    }
    mapping=$(db_find_user_by_tg_bind_hash "$token_hash" "$(date '+%s')")
    if [[ -z "$mapping" ]]; then
        tg_send_chat_message "$chat_id" "绑定码无效或已过期，请向管理员重新获取。"
        return
    fi
    IFS='|' read -r core proto name <<< "$mapping"

    if db_set_user_tg_binding "$core" "$proto" "$name" "$chat_id" "$tg_username" "$(date '+%Y-%m-%d %H:%M:%S')"; then
        local success_message
        printf -v success_message '绑定成功：%s（%s）。\n发送 /status 查询账号状态。' "$name" "$(get_protocol_name "$proto")"
        tg_send_chat_message "$chat_id" "$success_message"
    else
        tg_send_chat_message "$chat_id" "绑定失败，请联系管理员检查用户数据库。"
    fi
}

tg_user_bot_handle_update() {
    local update_json="$1" chat_id chat_type tg_username text command args mapping core proto name
    chat_id=$(jq -r '.message.chat.id // empty' <<< "$update_json")
    chat_type=$(jq -r '.message.chat.type // empty' <<< "$update_json")
    tg_username=$(jq -r '.message.from.username // empty' <<< "$update_json")
    text=$(jq -r '.message.text // empty' <<< "$update_json")
    [[ -n "$chat_id" && -n "$text" ]] || return 0

    if [[ "$chat_type" != "private" ]]; then
        return 0
    fi

    command="${text%% *}"
    command="${command%%@*}"
    if [[ "$text" == *" "* ]]; then
        args="${text#* }"
        args="${args%% *}"
    else
        args=""
    fi

    case "$command" in
        /bind)
            if [[ -z "$args" ]]; then
                tg_send_chat_message "$chat_id" "用法：/bind 绑定码"
            else
                tg_user_bot_bind_chat "$chat_id" "$tg_username" "$args"
            fi
            ;;
        /status)
            local report
            if report=$(tg_get_user_report_by_chat "$chat_id"); then
                tg_send_chat_message "$chat_id" "$report"
            else
                tg_send_chat_message "$chat_id" "尚未绑定代理账号。请发送 /bind 绑定码。"
            fi
            ;;
        /unbind)
            mapping=$(db_find_user_by_tg_chat "$chat_id")
            if [[ -z "$mapping" ]]; then
                tg_send_chat_message "$chat_id" "当前 Telegram 尚未绑定账号。"
            else
                IFS='|' read -r core proto name <<< "$mapping"
                if db_clear_user_tg_binding "$core" "$proto" "$name"; then
                    tg_send_chat_message "$chat_id" "已解除账号 ${name} 的 Telegram 绑定。"
                else
                    tg_send_chat_message "$chat_id" "解绑失败，请联系管理员。"
                fi
            fi
            ;;
        /start|/help)
            tg_send_chat_message "$chat_id" "$(tg_user_bot_help_text)"
            ;;
        /*)
            local unknown_message
            printf -v unknown_message '未知命令。\n\n%s' "$(tg_user_bot_help_text)"
            tg_send_chat_message "$chat_id" "$unknown_message"
            ;;
    esac
}

tg_poll_user_bot() {
    init_tg_config || return 1
    [[ "$(tg_get_config "user_bot_enabled")" == "true" ]] || return 0

    local lock_dir="$CFG/tg-user-bot.lock" owner
    if ! mkdir "$lock_dir" 2>/dev/null; then
        owner=$(cat "$lock_dir/pid" 2>/dev/null || true)
        if [[ -n "$owner" && "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
            rm -f "$lock_dir/pid" 2>/dev/null
            rmdir "$lock_dir" 2>/dev/null || true
            mkdir "$lock_dir" 2>/dev/null || return 0
        else
            return 0
        fi
    fi
    printf '%s\n' "$$" > "$lock_dir/pid"

    local offset response update update_id
    offset=$(tg_get_config "user_bot_update_offset")
    [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
    response=$(tg_bot_api_request "getUpdates" \
        --data-urlencode "offset=${offset}" \
        --data-urlencode "limit=100" \
        --data-urlencode 'allowed_updates=["message"]') || {
        rm -f "$lock_dir/pid" 2>/dev/null
        rmdir "$lock_dir" 2>/dev/null || true
        return 1
    }
    if ! jq -e '.ok == true and (.result | type == "array")' >/dev/null 2>&1 <<< "$response"; then
        rm -f "$lock_dir/pid" 2>/dev/null
        rmdir "$lock_dir" 2>/dev/null || true
        return 1
    fi

    local updates=()
    mapfile -t updates < <(jq -c '.result[]' <<< "$response")
    for update in "${updates[@]}"; do
        update_id=$(jq -r '.update_id // empty' <<< "$update")
        [[ "$update_id" =~ ^[0-9]+$ ]] || continue
        tg_user_bot_handle_update "$update"
        tg_set_config "user_bot_update_offset" "$((update_id + 1))"
    done

    rm -f "$lock_dir/pid" 2>/dev/null
    rmdir "$lock_dir" 2>/dev/null || true
    return 0
}


# 发送超限通知


# 检查是否需要发送每日报告


#═══════════════════════════════════════════════════════════════════════════════
#═══════════════════════════════════════════════════════════════════════════════



# 确保 Sing-box 协议的默认用户落入 users[]，便于统计 / 限额 / 到期统一处理


# 生成 Sing-box 用户的内部统计键，避免不同协议同名用户（如 default）互相撞统计


# 获取 Sing-box 协议的“展示用户名 -> stats 用户键”映射
# 输出格式: name|stat_key


# 返回: 总字节数


# 记录同步结果，便于界面和 cron 日志判断任务是否真正执行。


# 输出格式: proto|user|uplink|downlink|total


get_bash_interpreter() {
    local bash_path=""
    for candidate in "$(command -v bash 2>/dev/null)" /bin/bash /usr/bin/bash /usr/local/bin/bash; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        bash_path="$candidate"
        break
    done
    echo "$bash_path"
}

build_cron_command() {
    local schedule="$1" script_path="$2" subcommand="$3" log_file="$4"
    local bash_path env_path
    bash_path=$(get_bash_interpreter)
    env_path=$(command -v env 2>/dev/null || true)
    [[ -x "$env_path" ]] || env_path="/usr/bin/env"
    [[ -z "$bash_path" ]] && return 1
    printf '%s %q PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin %q %q %s >> %q 2>&1' \
        "$schedule" "$env_path" "$bash_path" "$script_path" "$subcommand" "$log_file"
}


tg_user_bot_cron_entry_exists() {
    command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q 'tg-user-bot'
}

cron_service_is_active() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet cron 2>/dev/null && return 0
        systemctl is-active --quiet crond 2>/dev/null && return 0
    fi
    if command -v rc-service >/dev/null 2>&1; then
        rc-service cronie status >/dev/null 2>&1 && return 0
        rc-service crond status >/dev/null 2>&1 && return 0
    fi
    _pgrep crond && return 0
    _pgrep cron && return 0
    return 1
}

ensure_cron_service_running() {
    cron_service_is_active && return 0

    if command -v rc-service >/dev/null 2>&1; then
        rc-update add cronie default >/dev/null 2>&1 || rc-update add crond default >/dev/null 2>&1 || true
        rc-service cronie start >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 || true
    fi
    if ! cron_service_is_active && command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true
    fi
    if ! cron_service_is_active && command -v service >/dev/null 2>&1; then
        service cron start >/dev/null 2>&1 || service crond start >/dev/null 2>&1 || true
    fi
    if ! cron_service_is_active && command -v crond >/dev/null 2>&1; then
        crond >/dev/null 2>&1 || true
    fi

    cron_service_is_active
}

install_cron_entry() {
    local tag="$1" cron_cmd="$2"
    command -v crontab >/dev/null 2>&1 || { _err "crontab 不存在，无法写入定时任务"; return 1; }
    [[ -n "$cron_cmd" ]] || { _err "定时任务命令为空"; return 1; }

    local current
    current=$(crontab -l 2>/dev/null || true)
    if printf '%s\n' "$current" | grep -q "$tag"; then
        current=$(printf '%s\n' "$current" | grep -v "$tag")
    fi
    printf '%s\n%s\n' "$current" "$cron_cmd" | awk 'NF' | crontab -
}

remove_cron_entry() {
    local tag="$1"
    command -v crontab >/dev/null 2>&1 || return 0
    local current
    current=$(crontab -l 2>/dev/null || true)
    printf '%s
' "$current" | grep -v "$tag" | crontab -
}


setup_tg_user_bot_cron() {
    local silent="${1:-false}"
    local script_path="/usr/local/bin/sing-lite.sh"
    [[ -x "$script_path" ]] || script_path=$(readlink -f "$0")
    local bash_path log_file cron_cmd
    bash_path=$(get_bash_interpreter)
    [[ -x "$script_path" ]] || { _err "脚本不存在或不可执行: $script_path"; return 1; }
    [[ -n "$bash_path" ]] || { _err "未找到 bash，无法启动用户机器人"; return 1; }
    log_file="$CFG/tg-user-bot.log"
    cron_cmd="$(build_cron_command "* * * * *" "$script_path" "--tg-bot-poll" "$log_file") # tg-user-bot"

    if install_cron_entry "tg-user-bot" "$cron_cmd"; then
        if ! ensure_cron_service_running; then
            [[ "$silent" == "true" ]] || _err "机器人规则已写入，但 cron 服务未运行"
            return 1
        fi
        if [[ "$silent" != "true" ]]; then
            _ok "用户机器人轮询已启用（最长约 1 分钟响应）"
            echo -e "  ${D}日志: $log_file${NC}"
        fi
        return 0
    fi
    _err "用户机器人定时任务写入失败"
    return 1
}

remove_tg_user_bot_cron() {
    remove_cron_entry "tg-user-bot"
}

# 升级旧预览版后自动重写 cron 命令（补齐 PATH）并修复守护进程。
repair_scheduled_jobs() {
    remove_cron_entry "sync-traffic"
    if tg_user_bot_cron_entry_exists; then setup_tg_user_bot_cron; fi
    if crontab -l 2>/dev/null | grep -q 'check-expire'; then
        uninstall_expire_check_cron
        install_expire_check_cron
    fi
}














#═══════════════════════════════════════════════════════════════════════════════
#  通用配置保存函数
#═══════════════════════════════════════════════════════════════════════════════

# REALITY 未鉴权回落限速
#
# XTLS 官方文档指出：鉴权失败的连接会直接转发到 target；当 target 位于
# Cloudflare 等公共 CDN 后，扫描者可能借此消耗本机出口流量。使用官方的
# limitFallbackUpload/Download 令牌桶字段进行缓解。参数必须随机化，否则
# 固定限速本身会形成可探测特征。


# 输出 reality_fallback_limits JSON。传入稳定 seed 可使同一实例重建配置时
# 保持参数不变；新实例使用私钥/ShortID 等高熵材料作为 seed。


# 为升级前已存在的 REALITY 配置补充一次限速参数。参数写回数据库，避免
# 每次生成主配置时改变流量特征；已有合法客户端无需更新分享链接。

# 简化版：直接用关联数组构建 JSON
# 用法: build_config "uuid" "$uuid" "port" "$port" "sni" "$sni"
build_config() {
    local args=()
    local keys=()

    while [[ $# -ge 2 ]]; do
        local key="$1" val="$2"
        shift 2
        keys+=("$key")
        # 数字检测
        if [[ "$val" =~ ^[0-9]+$ ]]; then
            args+=(--argjson "$key" "$val")
        else
            args+=(--arg "$key" "$val")
        fi
    done

    # 自动添加客户端连接地址；无公网时保存内网地址，避免后续生成空节点。
    local ipv4 ipv6
    IFS='|' read -r ipv4 ipv6 <<< "$(get_connection_addresses)"
    args+=(--arg "ipv4" "$ipv4" --arg "ipv6" "$ipv6")
    keys+=("ipv4" "ipv6")

    # 构建 jq 表达式
    local expr="{"
    local first=true
    for k in "${keys[@]}"; do
        [[ "$first" == "true" ]] && first=false || expr+=","
        expr+="\"$k\":\$$k"
    done
    expr+="}"

    jq -n "${args[@]}" "$expr"
}

# 保存 JOIN 信息到文件
# 用法: _save_join_info "协议名" "数据格式" "链接函数" [函数参数...] [--extra 额外行...]
# 数据格式中 %s 会被替换为 IP，%b 会被替换为 [IP] (IPv6 带括号)
# 示例: _save_join_info "vless" "REALITY|%s|$port|$uuid" gen_vless_link "%s" "$port" "$uuid"
_save_join_info() {
    local protocol="$1" data_fmt="$2" link_func="$3"; shift 3
    local join_file="$CFG/${protocol}.join"
    local link_prefix; link_prefix=$(tr '[:lower:]-' '[:upper:]_' <<<"$protocol")
    if [[ ! "$link_func" =~ ^gen_[a-zA-Z0-9_]+_link$ ]] || ! declare -F "$link_func" >/dev/null 2>&1; then
        _err "无效的链接生成函数: $link_func"
        return 1
    fi

    local link_args=() extra_lines=() parsing_extra=false arg
    for arg in "$@"; do
        if [[ "$arg" == "--extra" && "$parsing_extra" == "false" ]]; then
            parsing_extra=true
        elif [[ "$parsing_extra" == "true" ]]; then
            extra_lines+=("$arg")
        else
            link_args+=("$arg")
        fi
    done
    : >"$join_file"

    local ipv4 ipv6
    IFS='|' read -r ipv4 ipv6 <<< "$(get_connection_addresses)"
    local label ip ipfmt data code link
    for label in V4 V6; do
        ip=$([[ "$label" == V4 ]] && printf '%s' "$ipv4" || printf '%s' "$ipv6")
        [[ -z "$ip" ]] && continue
        ipfmt=$ip; [[ "$label" == V6 ]] && ipfmt="[$ip]"

        data=${data_fmt//%s/$ipfmt}; data=${data//%b/$ipfmt}
        code=$(printf '%s' "$data" | base64 -w 0 2>/dev/null || printf '%s' "$data" | base64)

        local resolved_args=() resolved
        for arg in "${link_args[@]}"; do
            resolved=${arg//%s/$ipfmt}
            resolved=${resolved//%b/$ipfmt}
            resolved_args+=("$resolved")
        done
        link=$("$link_func" "${resolved_args[@]}") || {
            _err "生成 $protocol 分享链接失败"
            return 1
        }

        printf '# IPv%s\nJOIN_%s=%s\n%s_%s=%s\n' "${label#V}" "$label" "$code" "$link_prefix" "$label" "$link" >>"$join_file"
    done

    local line
    for line in "${extra_lines[@]}"; do
        printf '%s\n' "$line" >>"$join_file"
    done
}

# Snell v5 的 JOIN 与其他共享协议使用相同的多端口重建路径。
regenerate_singbox_snell_v5_join_info() {
    regenerate_singbox_protocol_join_info snell-v5
}

# 检查证书是否为 CA 签发的真实证书
_is_real_cert() {
    [[ ! -f "$CFG/certs/server.crt" ]] && return 1
    local issuer=$(openssl x509 -in "$CFG/certs/server.crt" -noout -issuer 2>/dev/null)
    [[ "$issuer" == *"Let's Encrypt"* ]] || [[ "$issuer" == *"R3"* ]] || \
    [[ "$issuer" == *"R10"* ]] || [[ "$issuer" == *"R11"* ]] || \
    [[ "$issuer" == *"E1"* ]] || [[ "$issuer" == *"ZeroSSL"* ]] || [[ "$issuer" == *"Buypass"* ]]
}

# 确保 Nginx HTTPS 监听存在 (真实域名模式，供 Reality dest 回落)
# 用法: _ensure_nginx_https_for_reality "domain.com"
_ensure_nginx_https_for_reality() {
    local domain="$1"
    local nginx_https_port=8443
    local nginx_conf=""

    # 确定 nginx 配置文件路径 (Alpine http.d 优先)
    if [[ -d "/etc/nginx/http.d" ]]; then
        nginx_conf="/etc/nginx/http.d/sing-reality-https.conf"
    elif [[ -d "/etc/nginx/sites-available" ]]; then
        nginx_conf="/etc/nginx/sites-available/sing-reality-https"
    elif [[ -d "/etc/nginx/conf.d" ]]; then
        nginx_conf="/etc/nginx/conf.d/sing-reality-https.conf"
    else
        return 1
    fi

    # 检查 8443 端口是否已被 nginx 监听
    if ss -tln 2>/dev/null | grep -q ":${nginx_https_port} "; then
        # 端口已被占用，检查是否是我们的配置
        [[ -f "$nginx_conf" ]] && return 0
    fi

    # 确保 nginx 已安装
    if ! command -v nginx &>/dev/null; then
        return 1
    fi

    # 生成 HTTPS 配置 (供 Reality dest 回落)
    cat > "$nginx_conf" << EOF
# Reality 回落后端 (真实域名模式) - 供 Reality dest 使用
# 此配置由脚本自动生成，请勿手动修改
server {
    listen 127.0.0.1:${nginx_https_port} ssl http2;
    server_name ${domain};

    ssl_certificate $CFG/certs/server.crt;
    ssl_certificate_key $CFG/certs/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    server_tokens off;
}
EOF

    # 如果是 sites-available 模式，创建软链接
    if [[ "$nginx_conf" == *"sites-available"* ]]; then
        ln -sf "$nginx_conf" "/etc/nginx/sites-enabled/sing-reality-https" 2>/dev/null
    fi

    # 重载 nginx
    nginx -t &>/dev/null && nginx -s reload &>/dev/null
    return 0
}

# 检测系统是否支持 IPv6
_has_ipv6() {
    [[ -e /proc/net/if_inet6 ]]
}

# 检测 IPv6 socket 是否允许双栈（IPv4-mapped）
_can_dual_stack_listen() {
    [[ ! -f /proc/sys/net/ipv6/bindv6only ]] && return 0
    local val
    val=$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo "1")
    [[ "$val" == "0" ]]
}

# 获取监听地址：有 IPv6 且支持双栈才用 ::，否则用 0.0.0.0
_listen_addr() {
    if _has_ipv6 && _can_dual_stack_listen; then
        echo "::"
    else
        echo "0.0.0.0"
    fi
}

# 格式化 host:port（IPv6 需要方括号）
_fmt_hostport() {
    local host="$1" port="$2"
    if [[ "$host" == *:* ]]; then
        printf '[%s]:%s' "$host" "$port"
    else
        printf '%s:%s' "$host" "$port"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
#  用户配置区 - 可根据需要修改以下设置
#═══════════════════════════════════════════════════════════════════════════════
# JOIN 码显示开关 (on=显示, off=隐藏)
SHOW_JOIN_CODE="off"
#═══════════════════════════════════════════════════════════════════════════════

# 颜色
R='\e[31m'; G='\e[32m'; Y='\e[33m'; C='\e[36m'; M='\e[35m'; W='\e[97m'; D='\e[2m'; NC='\e[0m'
set -o pipefail

# 日志文件
LOG_FILE="/var/log/sing-lite.log"

# 写入纯文本日志；终端颜色由调用者处理。
_log() {
    local level="$1"
    shift
    local msg="$*"
    # 同时清除实际 ANSI SGR 和颜色变量中的字面转义，不解释其他反斜杠。
    local color_pattern='(\\e|\\033|\\x1[bB])'
    color_pattern="("$'\033'"|${color_pattern})"'\[[0-9;]*m'
    while [[ "$msg" =~ $color_pattern ]]; do
        msg=${msg//"${BASH_REMATCH[0]}"/}
    done
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # 写入日志文件（无颜色）
    printf '[%s] [%s] %s\n' "$timestamp" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null
}

# 初始化日志文件
init_log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    touch "$LOG_FILE" 2>/dev/null
    chmod 600 "$LOG_FILE" 2>/dev/null || true
    # 日志轮转：超过 5MB 时截断保留最后 1000 行
    if [[ -f "$LOG_FILE" ]]; then
        local size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ $size -gt 5242880 ]]; then
            local rotated
            rotated=$(mktemp "${LOG_FILE}.rotate.XXXXXX") || return 1
            if tail -n 1000 "$LOG_FILE" >"$rotated" 2>/dev/null; then
                chmod 600 "$rotated"
                mv "$rotated" "$LOG_FILE"
            else
                rm -f "$rotated"
            fi
        fi
    fi
    _log "INFO" "========== 脚本启动 v${VERSION} =========="
}

# timeout 兼容函数（某些精简系统可能没有 timeout 命令）
if ! command -v timeout &>/dev/null; then
    timeout() {
        local duration="$1"
        shift
        # 使用后台进程实现简单的超时
        "$@" &
        local pid=$!
        ( sleep "$duration" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null ) &
        local killer=$!
        wait "$pid" 2>/dev/null
        local ret=$?
        kill "$killer" 2>/dev/null
        wait "$killer" 2>/dev/null
        return $ret
    }
fi

# 系统检测
if [[ -f /etc/alpine-release ]]; then
    DISTRO="alpine"
elif [[ -f /etc/redhat-release ]]; then
    DISTRO="centos"
elif [[ -f /etc/lsb-release ]] && grep -q "Ubuntu" /etc/lsb-release; then
    DISTRO="ubuntu"
elif [[ -f /etc/os-release ]] && grep -q "Ubuntu" /etc/os-release; then
    DISTRO="ubuntu"
else
    DISTRO="debian"
fi

# RHEL 系兼容：无 yum 时使用 dnf
if ! command -v yum &>/dev/null && command -v dnf &>/dev/null; then
    yum() { dnf "$@"; }
fi

#═══════════════════════════════════════════════════════════════════════════════
# 多协议管理系统
#═══════════════════════════════════════════════════════════════════════════════

# 协议分类定义 (重构: Sing-box 接管独立协议)
# Sing-box 管理的协议 (原独立协议，现统一由 Sing-box 处理)
SINGBOX_PROTOCOLS="vless-singbox ss2022 ss-legacy socks hy2 tuic anytls naive ss2022-shadowtls snell-v5 snell-v6-singbox"
readonly SINGBOX_SNELL_MIN_VERSION="1.14.0"
# Sing-box Snell v4/v5 协议键保持稳定，供管理和客户端订阅识别。
SINGBOX_SNELL_V45_PROTOCOLS="snell-v5"
# 仍需独立进程的协议
STANDALONE_PROTOCOLS="snell-v5-official snell-v6"

protocol_core() {
    local protocol="$1"
    [[ -n "$protocol" ]] || return 1
    if [[ " $SINGBOX_PROTOCOLS " == *" $protocol "* ]]; then
        echo singbox
    elif [[ " $STANDALONE_PROTOCOLS " == *" $protocol "* ]]; then
        echo standalone
    else
        _err "未知协议: $protocol"
        return 1
    fi
}

# 获取协议记录实际所在的数据库命名空间。
# 官方 Snell 使用 snell 命名空间；共享核心使用 singbox。
protocol_db_core() {
    local protocol="$1" core
    core=$(protocol_core "$protocol") || return 1

    if [[ "$core" == "standalone" ]]; then
        echo snell
    else
        echo "$core"
    fi
}

# 当前协议记录统一按所属核心读取。
protocol_active_db_core() { protocol_db_core "$1"; }

protocol_subscription_db_core() { protocol_active_db_core "$1"; }
protocol_uninstall_db_core() { protocol_active_db_core "$1"; }

#═══════════════════════════════════════════════════════════════════════════════
#  表驱动元数据 (协议/服务/进程/启动命令)
#  说明：将 “协议差异” 集中到这里，主体流程尽量通用化
#═══════════════════════════════════════════════════════════════════════════════
declare -A PROTO_SVC PROTO_EXEC PROTO_BIN PROTO_KIND
for _p in $SINGBOX_PROTOCOLS; do
    PROTO_SVC[$_p]="sing-singbox"
    PROTO_EXEC[$_p]="$CFG/bin/sing-box run -c $CFG/singbox.json"
    PROTO_BIN[$_p]="sing-box"
    PROTO_KIND[$_p]="singbox"
done
for _p in $STANDALONE_PROTOCOLS; do
    PROTO_SVC[$_p]="vless-${_p}"
    PROTO_KIND[$_p]="snell"
done
PROTO_BIN[snell-v5-official]="snell-server-v5"
PROTO_EXEC[snell-v5-official]="$CFG/bin/snell-server-v5 -c $CFG/snell-v5-official.conf"
PROTO_BIN[snell-v6]="snell-server-v6"
PROTO_EXEC[snell-v6]="$CFG/bin/snell-server-v6 -c $CFG/snell-v6.conf"

# OpenRC status 回退：服务名 -> 进程名
declare -A SVC_PROC=(
    [sing-singbox]="sing-box"
    [sing-snell-v5-official]="snell-server-v5"
    [sing-snell-v6]="snell-server-v6"
    [nginx]="nginx"
)

# 注册协议配置到数据库
# 参数: $1=protocol, $2=config_json
register_protocol() {
    local protocol="$1"
    local config_json="$2"

    # 使用协议所属核心的数据库命名空间。
    local core
    core=$(protocol_db_core "$protocol") || return 1

    # 获取端口
    local port
    port=$(echo "$config_json" | jq -r '.port')

    # 根据安装模式处理
    if [[ "$INSTALL_MODE" == "replace" && -n "$REPLACE_PORT" ]]; then
        # 覆盖模式：更新指定端口的配置
        echo -e "  ${CYAN}覆盖端口 $REPLACE_PORT 的配置...${NC}"
        db_update_port "$core" "$protocol" "$REPLACE_PORT" "$config_json"
    elif [[ "$INSTALL_MODE" == "add" ]]; then
        # 添加模式：添加新端口实例
        echo -e "  ${CYAN}添加新端口 $port 实例...${NC}"
        db_add_port "$core" "$protocol" "$config_json"
    elif is_protocol_installed "$protocol"; then
        # 协议已存在但未指定模式：默认添加新端口
        echo -e "  ${CYAN}添加新端口 $port 实例...${NC}"
        db_add_port "$core" "$protocol" "$config_json"
    else
        # 首次安装：使用单对象格式
        db_add "$core" "$protocol" "$config_json"
    fi

    # 重置安装模式变量
    unset INSTALL_MODE REPLACE_PORT
}

unregister_protocol() {
    local protocol="$1" core
    core=$(protocol_db_core "$protocol") || return 1
    db_del "$core" "$protocol" 2>/dev/null

}

get_installed_protocols() {
    local protocol core
    [[ -f "$DB_FILE" ]] || return 0
    for protocol in $SINGBOX_PROTOCOLS $STANDALONE_PROTOCOLS; do
        core=$(protocol_db_core "$protocol") || return 1 || return 1
        db_exists "$core" "$protocol" && printf '%s\n' "$protocol"
    done
    return 0
}

is_protocol_installed() {
    local protocol="$1" core
    core=$(protocol_db_core "$protocol") || return 1
    db_exists "$core" "$protocol"
}

filter_installed() { # filter_installed "proto1 proto2 ..."
    local installed; installed=$(get_installed_protocols) || return 0
    local p
    for p in $1; do
        grep -qx "$p" <<<"$installed" && echo "$p"
    done
}

# 仅枚举 Sing-box 命名空间内已安装的协议。
get_singbox_protocols() {
    local protocol
    for protocol in $SINGBOX_PROTOCOLS; do
        db_exists singbox "$protocol" && printf '%s\n' "$protocol"
    done
    return 0
}

get_standalone_protocols() { filter_installed "$STANDALONE_PROTOCOLS"; }

# 生成用户级路由规则
# 遍历所有用户，为有自定义routing的用户生成Xray routing rules
# 返回: JSON数组格式的路由规则

# 获取用户路由需要的额外outbounds (确保WARP/链式代理等出口存在)
# 返回: 需要添加的outbound tags列表

# 生成 Xray 多 inbounds 配置

# 处理单个端口实例的 inbound 生成
# 参数: $1=protocol, $2=config_json

# 使用 jq 动态构建 inbound (重构版 - 只从数据库读取)

#═══════════════════════════════════════════════════════════════════════════════
# 基础工具函数
#═══════════════════════════════════════════════════════════════════════════════
_line()  { echo -e "${D}─────────────────────────────────────────────${NC}" >&2; }
_dline() { echo -e "${C}═════════════════════════════════════════════${NC}" >&2; }
_info()  { echo -e "  ${C}▸${NC} $1" >&2; }
_ok()    { echo -e "  ${G}✓${NC} $1" >&2; _log "OK" "$1"; }
_err()   { echo -e "  ${R}✗${NC} $1" >&2; _log "ERROR" "$1"; }
_warn()  { echo -e "  ${Y}!${NC} $1" >&2; _log "WARN" "$1"; }
_item()  { echo -e "  ${G}$1${NC}) $2" >&2; }
_pause() { echo "" >&2; read -rp "  按回车继续..."; }

# URL 解码函数 (处理 %XX 编码的中文等字符)
urldecode() {
    local encoded="$1"
    # 使用 printf 解码 %XX 格式
    printf '%b' "${encoded//%/\\x}"
}

# 解析 URL 查询参数 (key=value&...)
_get_query_param() {
    local params="$1"
    local key="$2"
    local value=""
    local IFS='&'
    local pair=""

    for pair in $params; do
        if [[ "$pair" == "$key="* ]]; then
            value="${pair#*=}"
            break
        fi
    done

    echo "$value"
}

_logo() {
    printf '%b' "$C" >&2
    cat >&2 <<'LOGO'
  __  __ ___ _   _  _____   _____
 |  \/  |_ _| | | |/ _ \ \ / / _ \
 | |\/| || || |_| | | | \ V / | | |
 | |  | || ||  _  | |_| || || |_| |
 |_|  |_|___|_| |_|\___/ |_| \___/
LOGO
    printf '%b' "$NC" >&2
}

_header() {
    clear; echo "" >&2
    _dline
    _logo
    echo -e "      ${W}sing-lite${NC} ${C}v${VERSION}${NC} ${Y}[服务端]${NC}" >&2
    echo -e "      ${D}作者: ${AUTHOR}  快捷命令: sing${NC}" >&2
    echo -e "      ${D}${REPO_URL}${NC}" >&2
    _dline
}

get_protocol() {
    # 多协议模式下返回主协议或第一个协议
    local installed=$(get_installed_protocols)
    if [[ -n "$installed" ]]; then
        # 优先返回 Xray 主协议
        for proto in vless-singbox socks ss2022; do
            if echo "$installed" | grep -q "^$proto$"; then
                echo "$proto"
                return
            fi
        done
        # 返回第一个已安装的协议
        echo "$installed" | head -1
    elif [[ -f "$CFG/protocol" ]]; then
        cat "$CFG/protocol"
    else
        echo "vless-singbox"
    fi
}



check_root()      { [[ $EUID -ne 0 ]] && { _err "请使用 root 权限运行"; exit 1; }; }
check_cmd()       { command -v "$1" &>/dev/null; }
check_installed() { [[ -d "$CFG" && ( -f "$CFG/config.json" || -f "$CFG/db.json" ) ]]; }
get_role()        { [[ -f "$CFG/role" ]] && cat "$CFG/role" || echo ""; }
is_paused()       { [[ -f "$CFG/paused" ]]; }

# 配置 DNS64 (纯 IPv6 环境)
configure_dns64() {
    # 检测 IPv4 网络是否可用
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        return 0  # IPv4 正常，无需配置
    fi

    _warn "检测到纯 IPv6 环境，准备配置 DNS64..."

    # 备份原有配置
    if [[ -f /etc/resolv.conf ]] && [[ ! -f /etc/resolv.conf.bak ]]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak
    fi

    # 写入 DNS64 服务器
    cat > /etc/resolv.conf << 'EOF'
nameserver 2a00:1098:2b::1
nameserver 2001:4860:4860::6464
nameserver 2a00:1098:2c::1
EOF

    _ok "DNS64 配置完成 (Kasper Sky + Google DNS64 + Trex)"
}

# 检查 CA 证书是否存在
_has_ca_bundle() {
    local ca_file=""
    for ca_file in "/etc/ssl/certs/ca-certificates.crt" "/etc/ssl/cert.pem" "/etc/pki/tls/certs/ca-bundle.crt"; do
        [[ -s "$ca_file" ]] && return 0
    done
    return 1
}

# 检测并安装基础依赖
_install_optional_qrencode() {
    command -v qrencode >/dev/null 2>&1 && return 0

    _info "尝试安装可选依赖 qrencode（用于显示二维码）..."
    case "$DISTRO" in
        alpine)
            # qrencode 位于 Alpine community 仓库；未启用时不能阻断主程序安装。
            if apk add --no-cache libqrencode-tools >/dev/null 2>&1 || \
               apk add --no-cache 'cmd:qrencode' >/dev/null 2>&1; then
                _ok "可选依赖 qrencode 已安装"
            else
                _warn "当前 Alpine 软件源无法安装 libqrencode-tools，已跳过二维码工具"
                _warn "这只影响终端二维码显示，不影响协议安装和服务运行"
                _warn "启用 community 仓库后可执行: apk add --no-cache libqrencode-tools"
            fi
            ;;
        centos)
            if yum install -y qrencode >/dev/null 2>&1; then
                _ok "可选依赖 qrencode 已安装"
            else
                _warn "qrencode 安装失败，已跳过；不影响协议安装和服务运行"
            fi
            ;;
        debian|ubuntu)
            if DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode >/dev/null 2>&1; then
                _ok "可选依赖 qrencode 已安装"
            else
                _warn "qrencode 安装失败，已跳过；不影响协议安装和服务运行"
            fi
            ;;
    esac

    return 0
}

check_dependencies() {
    # 先配置 DNS64 (如果是纯 IPv6 环境)
    configure_dns64

    local missing_deps=()
    local need_install=false

    # 必需的基础命令
    local required_cmds="curl jq openssl"

    for cmd in $required_cmds; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
            need_install=true
        fi
    done

    # 检查 crontab（用户到期检查与 Telegram 轮询）
    if ! command -v crontab &>/dev/null; then
        missing_deps+=("cron")
        need_install=true
    fi

    if ! _has_ca_bundle; then
        missing_deps+=("ca-certificates")
        need_install=true
    fi

    if [[ "$need_install" == "true" ]]; then
        _info "安装缺失的依赖: ${missing_deps[*]}..."

        case "$DISTRO" in
            alpine)
                apk update >/dev/null 2>&1
                local alpine_base_pkgs="curl jq openssl coreutils ca-certificates gawk"
                apk add --no-cache $alpine_base_pkgs >/dev/null 2>&1 || {
                    _err "Alpine 基础依赖安装失败"
                    _warn "请手动执行: apk add --no-cache $alpine_base_pkgs"
                    return 1
                }

                # Alpine 的 cron 实现可能是 dcron 或 cronie，二者互斥
                if ! command -v crontab &>/dev/null; then
                    if apk add --no-cache cronie >/dev/null 2>&1; then
                        :
                    elif apk add --no-cache dcron >/dev/null 2>&1; then
                        :
                    else
                        _err "Alpine cron 依赖安装失败"
                        _warn "请手动执行: apk add --no-cache cronie 或 apk add --no-cache dcron"
                        return 1
                    fi
                fi

                # Alpine 可能是 busybox crond，也可能是 cronie 服务，两个都兼容一下
                rc-service cronie start >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 || true
                rc-update add cronie default >/dev/null 2>&1 || rc-update add crond default >/dev/null 2>&1 || true
                ;;
            centos)
                yum install -y curl jq openssl ca-certificates cronie >/dev/null 2>&1
                # 启动 crond 服务
                systemctl enable crond >/dev/null 2>&1
                systemctl start crond >/dev/null 2>&1
                ;;
            debian|ubuntu)
                apt-get update >/dev/null 2>&1
                DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq openssl ca-certificates cron >/dev/null 2>&1
                # Debian/Ubuntu 的 cron 通常自动启动,但确保服务运行
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl enable cron >/dev/null 2>&1
                    systemctl start cron >/dev/null 2>&1
                fi
                ;;
        esac

        # 再次检查
        for cmd in $required_cmds; do
            if ! command -v "$cmd" &>/dev/null; then
                _err "依赖安装失败: $cmd"
                _warn "请手动安装: $cmd"
                return 1
            fi
        done
        if ! command -v crontab &>/dev/null; then
            _err "依赖安装失败: crontab"
            _warn "请手动安装 cron 服务"
            return 1
        fi
        if ! _has_ca_bundle; then
            _err "依赖安装失败: ca-certificates"
            _warn "请手动安装: ca-certificates"
            return 1
        fi
        _ok "依赖安装完成"
    fi

    # qrencode 只用于终端显示二维码，不应因软件源缺包阻断协议安装。
    _install_optional_qrencode
    return 0
}

# 核心更新依赖检查（避免版本获取失败）
_check_core_update_deps() {
    local missing=()
    local cmd
    for cmd in curl jq; do
        if ! check_cmd "$cmd"; then
            missing+=("$cmd")
        fi
    done
    if ! _has_ca_bundle; then
        missing+=("ca-certificates")
    fi
    if [[ ${#missing[@]} -ne 0 ]]; then
        _err "缺少依赖: ${missing[*]}"
        _warn "请先安装缺失依赖或手动补齐后重试"
        return 1
    fi
    return 0
}

# 确保系统支持双栈监听（IPv4 + IPv6）
ensure_dual_stack_listen() {
    # 仅在 Linux 系统上执行
    [[ ! -f /proc/sys/net/ipv6/bindv6only ]] && return 0

    local current=$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo "1")

    # 如果已经是双栈（0），直接返回
    [[ "$current" == "0" ]] && return 0

    # bindv6only=1 表示 IPv6 socket 只监听 IPv6，需要改成 0 才能双栈
    _warn "检测到系统 IPv6 socket 为 v6-only 模式，这会导致 IPv4 客户端无法连接"
    _info "正在配置双栈监听支持..."

    # 临时生效
    sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1

    # 持久化配置
    local sysctl_conf="/etc/sysctl.d/99-vless-dualstack.conf"
    echo "net.ipv6.bindv6only=0" > "$sysctl_conf"

    # 重新加载
    sysctl -p "$sysctl_conf" >/dev/null 2>&1

    # 验证
    local new_value=$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo "1")
    if [[ "$new_value" == "0" ]]; then
        _ok "双栈监听已启用（IPv4 和 IPv6 可同时连接）"
    else
        _warn "双栈配置未生效，将使用 IPv4 监听以保证可用性"
        _warn "如需双栈，请手动执行: sysctl -w net.ipv6.bindv6only=0"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 核心功能：强力清理 & 时间同步
#═══════════════════════════════════════════════════════════════════════════════


# 清理 Hysteria2/TUIC 端口跳跃 NAT 规则
cleanup_hy2_nat_rules() {
    # 清理 Hysteria2 端口跳跃规则
    if db_exists "singbox" "hy2"; then
        local port=$(db_get_field "singbox" "hy2" "port")
        local hs=$(db_get_field "singbox" "hy2" "hop_start"); hs="${hs:-20000}"
        local he=$(db_get_field "singbox" "hy2" "hop_end"); he="${he:-50000}"
        [[ -n "$port" ]] && {
            iptables -t nat -D PREROUTING -p udp --dport ${hs}:${he} -m comment --comment vless-hy2-hop -j REDIRECT --to-ports ${port} 2>/dev/null
            iptables -t nat -D OUTPUT -p udp --dport ${hs}:${he} -m comment --comment vless-hy2-hop -j REDIRECT --to-ports ${port} 2>/dev/null
            ip6tables -t nat -D PREROUTING -p udp --dport ${hs}:${he} -m comment --comment vless-hy2-hop -j REDIRECT --to-ports ${port} 2>/dev/null
            ip6tables -t nat -D OUTPUT -p udp --dport ${hs}:${he} -m comment --comment vless-hy2-hop -j REDIRECT --to-ports ${port} 2>/dev/null
            # 兼容清理由旧版本创建、尚未带 comment 的规则。
            iptables -t nat -D PREROUTING -p udp --dport ${hs}:${he} -j REDIRECT --to-ports ${port} 2>/dev/null
            iptables -t nat -D OUTPUT -p udp --dport ${hs}:${he} -j REDIRECT --to-ports ${port} 2>/dev/null
            ip6tables -t nat -D PREROUTING -p udp --dport ${hs}:${he} -j REDIRECT --to-ports ${port} 2>/dev/null
            ip6tables -t nat -D OUTPUT -p udp --dport ${hs}:${he} -j REDIRECT --to-ports ${port} 2>/dev/null
        }
    fi
    # 清理 TUIC 端口跳跃规则
    if db_exists "singbox" "tuic"; then
        local port=$(db_get_field "singbox" "tuic" "port")
        local hs=$(db_get_field "singbox" "tuic" "hop_start"); hs="${hs:-20000}"
        local he=$(db_get_field "singbox" "tuic" "hop_end"); he="${he:-50000}"
        [[ -n "$port" ]] && {
            iptables -t nat -D PREROUTING -p udp --dport ${hs}:${he} -m comment --comment vless-tuic-hop -j REDIRECT --to-ports ${port} 2>/dev/null
            iptables -t nat -D OUTPUT -p udp --dport ${hs}:${he} -m comment --comment vless-tuic-hop -j REDIRECT --to-ports ${port} 2>/dev/null
            ip6tables -t nat -D PREROUTING -p udp --dport ${hs}:${he} -m comment --comment vless-tuic-hop -j REDIRECT --to-ports ${port} 2>/dev/null
            ip6tables -t nat -D OUTPUT -p udp --dport ${hs}:${he} -m comment --comment vless-tuic-hop -j REDIRECT --to-ports ${port} 2>/dev/null
            iptables -t nat -D PREROUTING -p udp --dport ${hs}:${he} -j REDIRECT --to-ports ${port} 2>/dev/null
            iptables -t nat -D OUTPUT -p udp --dport ${hs}:${he} -j REDIRECT --to-ports ${port} 2>/dev/null
            ip6tables -t nat -D PREROUTING -p udp --dport ${hs}:${he} -j REDIRECT --to-ports ${port} 2>/dev/null
            ip6tables -t nat -D OUTPUT -p udp --dport ${hs}:${he} -j REDIRECT --to-ports ${port} 2>/dev/null
        }
    fi
    # 不再扫描并删除系统中的其他 REDIRECT 规则。上面仅按数据库记录的
    # 端口范围删除本脚本创建的 HY2/TUIC 规则。
}

sync_time() {
    _info "同步系统时间..."

    # 仅接受经 TLS 验证的 Date 响应，避免未加密 HTTP 被篡改后修改系统时钟。
    local http_time
    http_time=$(timeout 5 curl -fsSI --connect-timeout 3 --max-time 5 \
        --proto '=https' --proto-redir '=https' -- https://www.cloudflare.com/ 2>/dev/null |
        awk 'BEGIN{IGNORECASE=1} /^date:/{sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit}')
    if [[ -n "$http_time" ]]; then
        if date -s "$http_time" &>/dev/null; then
            _ok "时间同步完成 (HTTPS)"
            return 0
        fi
    fi

    # 方法2: 使用ntpdate (如果可用)
    if command -v ntpdate &>/dev/null; then
        if timeout 5 ntpdate -s pool.ntp.org &>/dev/null; then
            _ok "时间同步完成 (NTP)"
            return 0
        fi
    fi

    # 方法3: 使用timedatectl (systemd系统)
    if command -v timedatectl &>/dev/null; then
        if timeout 5 timedatectl set-ntp true &>/dev/null; then
            _ok "时间同步完成 (systemd)"
            return 0
        fi
    fi

    # 如果所有方法都失败，跳过时间同步
    _warn "时间同步失败，继续安装..."
    return 0
}

#═══════════════════════════════════════════════════════════════════════════════
# 网络工具
#═══════════════════════════════════════════════════════════════════════════════
get_ipv4() {
    [[ -n "$_CACHED_IPV4" ]] && { echo "$_CACHED_IPV4"; return; }
    local result=$(curl -4 -sf --connect-timeout 5 https://ip.sb 2>/dev/null || curl -4 -sf --connect-timeout 5 https://ifconfig.me 2>/dev/null)
    [[ -n "$result" ]] && _CACHED_IPV4="$result"
    echo "$result"
}
get_ipv6() {
    [[ -n "$_CACHED_IPV6" ]] && { echo "$_CACHED_IPV6"; return; }
    local result=$(curl -6 -sf --connect-timeout 5 https://ip.sb 2>/dev/null || curl -6 -sf --connect-timeout 5 https://ifconfig.me 2>/dev/null)
    [[ -n "$result" ]] && _CACHED_IPV6="$result"
    echo "$result"
}

# 获取本机接口地址。公网 IP 探测失败时仅用于提示和局域网配置，不能替代
# 公网地址参与域名解析校验。
get_local_ipv4() {
    local result=""
    if command -v ip >/dev/null 2>&1; then
        result=$(ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); if ($4 != "127.0.0.1") {print $4; exit}}')
    fi
    if [[ -z "$result" ]] && command -v hostname >/dev/null 2>&1; then
        result=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $0 != "127.0.0.1" {print; exit}')
    fi
    echo "$result"
}

get_local_ipv6() {
    local result=""
    if command -v ip >/dev/null 2>&1; then
        result=$(ip -o -6 addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); if ($4 !~ /^fe80:/) {print $4; exit}}')
    fi
    if [[ -z "$result" ]] && command -v hostname >/dev/null 2>&1; then
        result=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/:/ && $0 !~ /^fe80:/ {print; exit}')
    fi
    echo "$result"
}

# 获取用于客户端配置和分享链接的地址。只要存在任一公网地址，就保持原有
# 公网优先逻辑；仅在公网 IPv4/IPv6 都不可用时才回落到本机接口地址。
# 输出格式: ipv4|ipv6
get_connection_addresses() {
    local ipv4 ipv6
    ipv4=$(get_ipv4)
    ipv6=$(get_ipv6)
    if [[ -z "$ipv4" && -z "$ipv6" ]]; then
        ipv4=$(get_local_ipv4)
        ipv6=$(get_local_ipv6)
    fi
    printf '%s|%s\n' "$ipv4" "$ipv6"
}

# 公网地址不是安装代理核心的必要条件。无公网服务器仍可通过内网、NAT
# 端口映射或隧道使用，因此这里只提示网络环境，永不阻断安装。
show_install_network_environment() {
    local public_ipv4 public_ipv6 local_ipv4 local_ipv6
    public_ipv4=$(get_ipv4)
    public_ipv6=$(get_ipv6)

    echo -e "  公网 IPv4: ${public_ipv4:-${R}无${NC}}"
    echo -e "  公网 IPv6: ${public_ipv6:-${R}无${NC}}"
    if [[ -n "$public_ipv4" || -n "$public_ipv6" ]]; then
        return 0
    fi

    local_ipv4=$(get_local_ipv4)
    local_ipv6=$(get_local_ipv6)
    _warn "未检测到公网 IP，将继续安装"
    echo -e "  内网 IPv4: ${local_ipv4:-${D}无${NC}}"
    echo -e "  内网 IPv6: ${local_ipv6:-${D}无${NC}}"
    echo -e "  ${D}安装完成后，请使用内网地址、NAT 端口映射地址、域名或隧道地址配置客户端。${NC}"
    return 0
}

# 获取 IP 地理位置代码 (如 HK, JP, US, SG)
get_ip_country() {
    local ip="${1:-}"
    local country=""

    # 使用 HTTPS 查询，避免国家代码在传输途中被篡改。
    if [[ -n "$ip" ]]; then
        country=$(curl -sf --connect-timeout 3 "https://ipinfo.io/${ip}/country" 2>/dev/null)
    else
        country=$(curl -sf --connect-timeout 3 "https://ipinfo.io/country" 2>/dev/null)
    fi

    # 清理结果（去除空白字符）
    country=$(echo "$country" | tr -d '[:space:]')

    # 默认返回 XX
    echo "${country:-XX}"
}

# 通过DNS检查域名的IP解析 (兼容性增强)
check_domain_dns() {
    local domain=$1
    local dns_ip=""
    local ip_type=4
    local public_ip=""

    # 优先使用 dig
    if command -v dig &>/dev/null; then
        dns_ip=$(dig @1.1.1.1 +time=2 +short "$domain" 2>/dev/null | grep -E "^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$" | head -1)

        # 如果Cloudflare DNS失败，尝试Google DNS
        if [[ -z "$dns_ip" ]]; then
            dns_ip=$(dig @8.8.8.8 +time=2 +short "$domain" 2>/dev/null | grep -E "^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$" | head -1)
        fi
    fi

    # 回退到 nslookup
    if [[ -z "$dns_ip" ]] && command -v nslookup &>/dev/null; then
        dns_ip=$(nslookup "$domain" 1.1.1.1 2>/dev/null | awk '/^Address: / { print $2 }' | grep -v "1.1.1.1" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$" | head -1)
    fi

    # 回退到 getent
    if [[ -z "$dns_ip" ]] && command -v getent &>/dev/null; then
        dns_ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | head -1)
    fi

    # 如果IPv4解析失败，尝试IPv6
    if [[ -z "$dns_ip" ]] || echo "$dns_ip" | grep -q "timed out"; then
        _warn "无法通过DNS获取域名 IPv4 地址"
        _info "尝试检查域名 IPv6 地址..."

        if command -v dig &>/dev/null; then
            dns_ip=$(dig @2606:4700:4700::1111 +time=2 aaaa +short "$domain" 2>/dev/null | head -1)
        elif command -v getent &>/dev/null; then
            dns_ip=$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | head -1)
        fi
        ip_type=6

        if [[ -z "$dns_ip" ]] || echo "$dns_ip" | grep -q "network unreachable"; then
            _err "无法通过DNS获取域名IPv6地址"
            return 1
        fi
    fi

    # 获取服务器公网IP
    if [[ $ip_type -eq 4 ]]; then
        public_ip=$(get_ipv4)
    else
        public_ip=$(get_ipv6)
    fi

    # 比较DNS解析IP与服务器IP
    if [[ "$public_ip" != "$dns_ip" ]]; then
        _err "域名解析IP与当前服务器IP不一致"
        _warn "请检查域名解析是否生效以及正确"
        echo -e "  ${G}当前VPS IP：${NC}$public_ip"
        echo -e "  ${G}DNS解析 IP：${NC}$dns_ip"
        return 1
    else
        _ok "域名IP校验通过"
        return 0
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 端口管理
#═══════════════════════════════════════════════════════════════════════════════

# 检查脚本内部记录的端口占用 (从数据库读取)
# 返回 0 表示被占用，1 表示未被占用
is_internal_port_occupied() {
    local check_port="$1" core proto ports
    # 单对象和多端口数组都要检查，包括未启动的实例。
    for core in singbox snell; do
        for proto in $(db_list_protocols "$core"); do
            ports=$(db_list_ports "$core" "$proto") || return 1
            if grep -qxF "$check_port" <<<"$ports"; then
                printf '%s\n' "$proto"
                return 0
            fi
        done
    done

    return 1
}

# 优化后的端口生成函数 - 增加端口冲突检测和最大尝试次数
gen_port() {
    local port
    local max_attempts=100  # 最大尝试次数，防止无限循环
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        port=$(shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50000 + 10000)))
        # 检查端口是否被占用 (TCP 和 UDP)
        if ! ss -tuln 2>/dev/null | grep -q ":$port " && ! netstat -tuln 2>/dev/null | grep -q ":$port "; then
            echo "$port"
            return 0
        fi
        ((attempt++))
    done

    # 达到最大尝试次数，返回一个随机端口并警告
    _warn "无法找到空闲端口（尝试 $max_attempts 次），使用随机端口" >&2
    echo "$port"
    return 1
}

# 智能端口推荐
# 参数: $1=协议类型
recommend_port() {
    local protocol="$1" port attempt
    if [[ "${INSTALL_MODE:-}" == replace && -n "${REPLACE_PORT:-}" ]]; then
        printf '%s\n' "$REPLACE_PORT"
        return 0
    fi
    case "$protocol" in
        anytls|naive)
            for port in 443 8443 2096; do
                if ! ss -tuln 2>/dev/null | grep -q ":$port " && ! is_internal_port_occupied "$port" >/dev/null; then
                    printf '%s\n' "$port"; return 0
                fi
            done ;;
    esac
    for ((attempt=0; attempt<100; attempt++)); do
        port=$(gen_port) || return 1
        if ! is_internal_port_occupied "$port" >/dev/null; then
            printf '%s\n' "$port"; return 0
        fi
    done
    _err '未找到可用端口'
    return 1
}

# 交互式端口选择
ask_port() {
    local protocol="$1" recommended value occupied
    recommended=$(recommend_port "$protocol") || return 1
    while true; do
        read -rp "  监听端口 [$recommended]: " value || return 1
        value="${value:-$recommended}"
        if ! _is_valid_port "$value"; then _err '端口必须为 1–65535'; continue; fi
        if [[ "${INSTALL_MODE:-}" != replace || "$value" != "${REPLACE_PORT:-}" ]]; then
            if occupied=$(is_internal_port_occupied "$value"); then
                _err "端口已被 $occupied 使用"; continue
            fi
            if ss -tuln 2>/dev/null | grep -q ":$value "; then
                _err '端口已被系统服务使用'; continue
            fi
        fi
        PORT="$value"
        printf '%s\n' "$value"
        return 0
    done
}

# 处理协议已安装时的多端口选择
# 参数: $1=protocol, $2=core(singbox/snell)
# 返回: 0=继续安装, 1=取消
handle_existing_protocol() {
    local protocol="$1" core
    core=$(protocol_db_core "$protocol")

    # 获取已有端口列表
    local ports=$(db_list_ports "$core" "$protocol")

    if [[ -z "$ports" ]]; then
        return 0  # 没有已安装实例，继续
    fi

    echo ""
    echo -e "${CYAN}检测到协议 ${YELLOW}$protocol${CYAN} 已安装以下端口实例：${NC}"
    echo "$ports" | while read -r port; do
        echo -e "    ${G}●${NC} 端口 ${G}$port${NC}"
    done
    echo ""

    echo -e "${YELLOW}请选择操作：${NC}"
    echo -e "  ${G}1${NC}) 添加新端口实例"
    echo -e "  ${G}2${NC}) 覆盖现有端口"
    echo "  0) 返回"
    echo ""

    local choice
    read -p "$(echo -e "  ${GREEN}请输入选项 [0-2]:${NC} ")" choice

    case "$choice" in
        1)
            INSTALL_MODE="add"
            return 0
            ;;
        2)
            INSTALL_MODE="replace"
            # 选择要覆盖的端口
            echo ""
            echo -e "${YELLOW}请选择要覆盖的端口：${NC}"
            local port_array=($ports)
            local i=1
            for port in "${port_array[@]}"; do
                echo -e "  ${G}$i${NC}) 端口 ${G}$port${NC}"
                ((i++))
            done
            echo "  0) 返回"
            echo ""

            local port_choice
            read -p "$(echo -e "  ${GREEN}请输入选项 [0-$((i-1))]:${NC} ")" port_choice

            if [[ "$port_choice" == "0" ]]; then
                echo -e "${YELLOW}已取消，返回上级菜单${NC}"
                return 1
            elif [[ "$port_choice" =~ ^[0-9]+$ ]] && [ "$port_choice" -ge 1 ] && [ "$port_choice" -le "$((i-1))" ]; then
                REPLACE_PORT="${port_array[$((port_choice-1))]}"
                return 0
            else
                echo -e "${RED}无效选项${NC}"
                return 1
            fi
            ;;
        0)
            echo -e "${YELLOW}已取消，返回上级菜单${NC}"
            return 1
            ;;
        *)
            echo -e "${RED}无效选项${NC}"
            return 1
            ;;
    esac
}

# 检查端口是否被其他协议占用
# 参数: $1=port, $2=current_protocol, $3=current_core
# 返回: 0=未占用, 1=已占用
check_port_conflict() {
    local check_port="$1" current_protocol="$2" current_core="$3"
    local core proto ports

    for core in singbox snell; do
        for proto in $(db_list_protocols "$core"); do
            [[ "$proto" == "$current_protocol" && "$current_core" == "$core" ]] && continue

            ports=$(db_list_ports "$core" "$proto")
            if echo "$ports" | grep -q "^${check_port}$"; then
                echo -e "${RED}错误: 端口 $check_port 已被协议 $proto 占用${NC}"
                return 1
            fi
        done
    done

    return 0
}

#═══════════════════════════════════════════════════════════════════════════════
# 密钥与凭证生成
#═══════════════════════════════════════════════════════════════════════════════

# 生成 ShortID (兼容无 xxd 的系统)
gen_sid() {
    if command -v xxd &>/dev/null; then
        head -c 4 /dev/urandom 2>/dev/null | xxd -p
    elif command -v od &>/dev/null; then
        head -c 4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n'
    else
        printf '%08x' $RANDOM
    fi
}

# 证书诊断函数
diagnose_certificate() {
    local domain="$1"

    echo ""
    _info "证书诊断报告："

    # 检查证书文件
    if [[ -f "$CFG/certs/server.crt" && -f "$CFG/certs/server.key" ]]; then
        _ok "证书文件存在"

        # 检查证书有效期
        local expiry=$(openssl x509 -in "$CFG/certs/server.crt" -noout -enddate 2>/dev/null | cut -d= -f2)
        if [[ -n "$expiry" ]]; then
            _ok "证书有效期: $expiry"
        fi
    else
        _err "证书文件不存在"
    fi

    # DNS解析检查
    local resolved_ip=$(dig +short "$domain" 2>/dev/null | head -1)
    local server_ip=$(get_ipv4)
    if [[ "$resolved_ip" == "$server_ip" ]]; then
        _ok "DNS解析正确: $domain -> $resolved_ip"
    else
        _warn "DNS解析问题: $domain -> $resolved_ip (期望: $server_ip)"
    fi

    echo ""
}

# 创建伪装网页
create_fake_website() {
    local domain="$1"
    local protocol="$2"
    local custom_nginx_port="$3"  # 新增：自定义 Nginx 端口
    local web_dir="/var/www/html"

    # 根据系统确定 nginx 配置目录
    local nginx_conf_dir=""
    local nginx_conf_file=""
    if [[ -d "/etc/nginx/sites-available" ]]; then
        nginx_conf_dir="/etc/nginx/sites-available"
        nginx_conf_file="$nginx_conf_dir/sing-fake"
    elif [[ -d "/etc/nginx/http.d" ]]; then
        # Alpine: 必须使用 http.d 目录，conf.d 不在 http{} 块内
        nginx_conf_dir="/etc/nginx/http.d"
        nginx_conf_file="$nginx_conf_dir/sing-fake.conf"
    elif [[ -d "/etc/nginx/conf.d" ]]; then
        nginx_conf_dir="/etc/nginx/conf.d"
        nginx_conf_file="$nginx_conf_dir/sing-fake.conf"
    else
        nginx_conf_dir="/etc/nginx/conf.d"
        nginx_conf_file="$nginx_conf_dir/sing-fake.conf"
        mkdir -p "$nginx_conf_dir"
    fi

    # 删除旧配置，确保使用最新配置
    rm -f "$nginx_conf_file" /etc/nginx/sites-enabled/sing-fake 2>/dev/null
    # 同时删除可能冲突的 sing-sub.conf (包括 http.d 目录)
    rm -f /etc/nginx/conf.d/sing-sub.conf /etc/nginx/http.d/sing-sub.conf 2>/dev/null

    # 创建网页目录
    mkdir -p "$web_dir"

    # 仅在目标文件不存在时创建，避免覆盖用户已有网站。
    if [[ ! -e "$web_dir/index.html" ]]; then
        cat > "$web_dir/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 20px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 40px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #333; text-align: center; }
        p { color: #666; line-height: 1.6; }
        .footer { text-align: center; margin-top: 40px; color: #999; font-size: 14px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome to Our Website</h1>
        <p>This is a simple website hosted on our server. We provide various web services and solutions for our clients.</p>
        <p>Our team is dedicated to delivering high-quality web hosting and development services. Feel free to contact us for more information about our services.</p>
        <div class="footer">
            <p>&copy; 2024 Web Services. All rights reserved.</p>
        </div>
    </div>
</body>
</html>
EOF
        : >"$CFG/.managed_web_index"
    fi

    # 检查是否有SSL证书，决定使用Nginx
    if [[ -n "$domain" ]] && [[ -f "/etc/sing-lite/certs/server.crt" ]]; then
        # 安装Nginx（如果未安装）
        if ! command -v nginx >/dev/null 2>&1; then
            _info "安装Nginx..."
            case "$DISTRO" in
                alpine) apk add --no-cache nginx >/dev/null 2>&1 ;;
                centos) yum install -y nginx >/dev/null 2>&1 ;;
                debian|ubuntu) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx >/dev/null 2>&1 ;;
            esac
        fi

        # 启用Nginx服务
        svc enable nginx 2>/dev/null

        # 根据协议选择Nginx监听端口和模式
        local nginx_port="80"
        local nginx_listen="127.0.0.1:$nginx_port"
        local nginx_comment="提供订阅服务"
        local is_real_domain=false

        if [[ "$protocol" == "vless" || "$protocol" == "vless-singbox" ]]; then
            # Reality协议：Nginx独立运行，提供HTTP订阅服务
            nginx_port="${custom_nginx_port:-8080}"
            nginx_listen="[::]:$nginx_port"
            nginx_comment="独立提供订阅服务 (HTTP)，不与Reality冲突"

            # 检测是否使用真实证书 (真实域名模式)
            if [[ "$domain" == "$(cat "$CFG/cert_domain" 2>/dev/null)" ]] && _is_real_cert; then
                is_real_domain=true
                # 真实域名模式：回落和外部访问用同一个 HTTPS 端口
                nginx_port="${custom_nginx_port:-8443}"
            fi
        fi

        # 配置Nginx
        # Reality真实域名模式：单端口 HTTPS (同时作为回落和外部访问)
        if [[ "$is_real_domain" == "true" ]]; then
            # Reality真实域名模式：
            # - 127.0.0.1:nginx_port 供 Reality dest 回落（只显示伪装网页，无订阅）
            # - 0.0.0.0:nginx_port 供外部直接访问（伪装网页 + 订阅服务）
            cat > "$nginx_conf_file" << EOF
# Reality 回落后端 (真实域名模式) - 只显示伪装网页
server {
    listen 127.0.0.1:$nginx_port ssl http2;
    server_name $domain;

    ssl_certificate $CFG/certs/server.crt;
    ssl_certificate_key $CFG/certs/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root $web_dir;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # 订阅路径返回404，防止通过Reality端口访问订阅
    location /sub/ {
        return 404;
    }

    server_tokens off;
}

# 订阅服务 (外部直接访问) - 伪装网页 + 订阅
server {
    listen $nginx_port ssl http2;
    listen [::]:$nginx_port ssl http2;
    server_name $domain;

    ssl_certificate $CFG/certs/server.crt;
    ssl_certificate_key $CFG/certs/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root $web_dir;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # 订阅文件目录 - v2ray 映射到 base64
    location ~ ^/sub/([a-f0-9-]+)/v2ray\$ {
        alias $CFG/subscription/\$1/base64;
        default_type text/plain;
        add_header Content-Type "text/plain; charset=utf-8";
    }

    # 订阅文件目录 - clash
    location ~ ^/sub/([a-f0-9-]+)/clash\$ {
        alias $CFG/subscription/\$1/clash.yaml;
        default_type text/yaml;
    }

    # 订阅文件目录 - surge
    location ~ ^/sub/([a-f0-9-]+)/surge\$ {
        alias $CFG/subscription/\$1/surge.conf;
        default_type text/plain;
    }

    # 订阅文件目录 - 通用
    location /sub/ {
        alias $CFG/subscription/;
        autoindex off;
        default_type text/plain;
    }

    server_tokens off;
}
EOF
        else
            # Reality无域名模式：单端口 HTTP 配置
            cat > "$nginx_conf_file" << EOF
server {
    listen $nginx_listen;  # $nginx_comment
    server_name $domain;

    root $web_dir;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # 订阅文件目录 - v2ray 映射到 base64
    location ~ ^/sub/([a-f0-9-]+)/v2ray\$ {
        alias $CFG/subscription/\$1/base64;
        default_type text/plain;
        add_header Content-Type "text/plain; charset=utf-8";
    }

    # 订阅文件目录 - clash
    location ~ ^/sub/([a-f0-9-]+)/clash\$ {
        alias $CFG/subscription/\$1/clash.yaml;
        default_type text/yaml;
    }

    # 订阅文件目录 - surge
    location ~ ^/sub/([a-f0-9-]+)/surge\$ {
        alias $CFG/subscription/\$1/surge.conf;
        default_type text/plain;
    }

    # 订阅文件目录 - 通用
    location /sub/ {
        alias $CFG/subscription/;
        autoindex off;
        default_type text/plain;
    }

    server_tokens off;
}
EOF
        fi

        # 如果使用 sites-available 模式，创建软链接
        if [[ "$nginx_conf_dir" == "/etc/nginx/sites-available" ]]; then
            mkdir -p /etc/nginx/sites-enabled
            rm -f /etc/nginx/sites-enabled/default
            ln -sf "$nginx_conf_file" /etc/nginx/sites-enabled/sing-fake
        fi

        # 测试Nginx配置
        _info "配置Nginx并启动Web服务..."
        if nginx -t 2>/dev/null; then
            # 强制重启 Nginx 确保新配置生效（直接用 systemctl，更可靠）
            if [[ "$DISTRO" == "alpine" ]]; then
                rc-service nginx stop 2>/dev/null
                sleep 1
                rc-service nginx start 2>/dev/null
            else
                systemctl stop nginx 2>/dev/null
                sleep 1
                systemctl start nginx 2>/dev/null
            fi
            sleep 1

            # 验证端口是否监听（兼容不同系统）
            local port_listening=false
            if ss -tlnp 2>/dev/null | grep -qE ":${nginx_port}\s|:${nginx_port}$"; then
                port_listening=true
            elif netstat -tlnp 2>/dev/null | grep -q ":${nginx_port} "; then
                port_listening=true
            fi

            # 检查服务状态
            local nginx_running=false
            if [[ "$DISTRO" == "alpine" ]]; then
                rc-service nginx status &>/dev/null && nginx_running=true
            else
                systemctl is-active nginx &>/dev/null && nginx_running=true
            fi

            if [[ "$nginx_running" == "true" && "$port_listening" == "true" ]]; then
                _ok "伪装网页已创建并启动"
                _ok "Web服务器运行正常，订阅链接可用"
                # Reality 真实域名模式时，显示 Reality 端口
                if [[ "$is_real_domain" == "true" ]]; then
                    local reality_port=$(db_get_field "singbox" "vless-singbox" "port")
                    if [[ "$protocol" == vless-singbox || -z "$reality_port" ]]; then
                        reality_port=$(db_get_field "singbox" "vless-singbox" "port")
                    fi
                    if [[ -n "$reality_port" ]]; then
                        _ok "伪装网页: https://$domain:$reality_port"
                    fi
                else
                    _ok "伪装网页: http://$domain:$nginx_port"
                fi
                echo -e "  ${D}提示: 自定义伪装网页请将 HTML 文件放入 $web_dir${NC}"
            elif [[ "$nginx_running" == "true" ]]; then
                _ok "伪装网页已创建"
                _warn "端口 $nginx_port 未监听，请检查 Nginx 配置"
            else
                _ok "伪装网页已创建"
                _warn "Nginx 服务未运行，请手动启动: systemctl start nginx"
            fi
        else
            _warn "Nginx配置测试失败"
            echo "配置错误详情："
            nginx -t
            rm -f "$nginx_conf_file" /etc/nginx/sites-enabled/sing-fake 2>/dev/null
        fi

        # 保存订阅配置信息
        local sub_uuid=$(get_sub_uuid)
        local use_https="false"
        # Reality真实域名模式用 HTTPS
        if [[ "$is_real_domain" == "true" ]]; then
            use_https="true"
        fi

        if ! _write_sub_info "$sub_uuid" "$nginx_port" "$domain" "$use_https"; then
            _err "订阅配置参数无效，拒绝写入"
            return 1
        fi
        _log "INFO" "订阅配置已保存: UUID=${sub_uuid:0:8}..., 端口=$nginx_port, 域名=$domain"
    fi

}

# 全局 SNI 域名列表（大陆可访问的企业子域名，用于 Reality 伪装）
readonly COMMON_SNI_LIST=(
    "ads.apple.com"
    "advertising.apple.com"
    "apps.apple.com"
    "asia.apple.com"
    "books.apple.com"
    "community.apple.com"
    "crl.apple.com"
    "developer.apple.com"
    "files.apple.com"
    "guide.apple.com"
    "iphone.apple.com"
    "link.apple.com"
    "maps.apple.com"
    "ml.apple.com"
    "music.apple.com"
    "one.apple.com"
    "store.apple.com"
    "support.apple.com"
    "time.apple.com"
    "tv.apple.com"
    "videos.apple.com"
)

gen_sni() {
    # 从全局列表中随机选择一个 SNI
    local idx=$(od -An -tu4 -N4 /dev/urandom 2>/dev/null | tr -d ' ')
    [[ -z "$idx" ]] && idx=$RANDOM
    echo "${COMMON_SNI_LIST[$((idx % ${#COMMON_SNI_LIST[@]}))]}"
}


urlencode() {
    local s="$1" i c o=""
    for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [-_.~a-zA-Z0-9]) o+="$c" ;;
            *) printf -v c '%%%02x' "'$c"; o+="$c" ;;
        esac
    done
    echo "$o"
}

# 提取 IP 地址后缀（IPv4 取最后一段，IPv6 直接返回 "v6"）
get_ip_suffix() {
    local ip="$1"
    # 移除方括号
    ip="${ip#[}"
    ip="${ip%]}"

    if [[ "$ip" == *:* ]]; then
        # IPv6: 直接返回 "v6"
        echo "v6"
    else
        # IPv4: 取最后一个点后面的数字
        echo "${ip##*.}"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 分享链接生成
#═══════════════════════════════════════════════════════════════════════════════

gen_vless_link() {
    local ip="$1" port="$2" uuid="$3" pbk="$4" sid="$5" sni="$6" country="${7:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}VLESS+Reality${ip_suffix:+-${ip_suffix}}"
    printf '%s\n' "vless://${uuid}@${ip}:${port}?encryption=none&security=reality&type=tcp&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&flow=xtls-rprx-vision#${name}"
}





# 生成二维码 (使用 qrencode 生成终端二维码)
gen_qr() {
    local text="$1"
    local margin="${2:-2}"

    # 使用 qrencode 生成终端二维码 (标准黑白二维码)
    if command -v qrencode &>/dev/null; then
        printf '%s' "$text" | qrencode -t UTF8 -m "$margin" 2>/dev/null && return 0
        echo "[二维码生成失败，请复制上方链接]"
        return 1
    fi

    # 未安装 qrencode，提示用户安装
    echo "[需安装 qrencode 才能显示二维码]"
    return 1
}

# 检查是否能生成终端二维码
_can_gen_qr() {
    command -v qrencode &>/dev/null
}

# 二维码仅辅助展示，缺少工具或编码失败不能中断分享菜单。
_show_link_qr() {
    printf '  二维码:\n'
    gen_qr "$1" || :
}



# 生成各协议分享链接
gen_hy2_link() {
    local ip="$1" port="$2" password="$3" sni="$4" country="${5:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}Hysteria2${ip_suffix:+-${ip_suffix}}"
    # 链接始终使用实际端口，端口跳跃需要客户端手动配置
    printf '%s\n' "hysteria2://${password}@${ip}:${port}?sni=${sni}&insecure=1#${name}"
}



gen_ss2022_link() {
    local ip="$1" port="$2" method="$3" password="$4" country="${5:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}SS2022${ip_suffix:+-${ip_suffix}}"
    local userinfo=$(printf '%s:%s' "$method" "$password" | base64 -w 0 2>/dev/null || printf '%s:%s' "$method" "$password" | base64)
    printf '%s\n' "ss://${userinfo}@${ip}:${port}#${name}"
}

gen_ss_legacy_link() {
    local ip="$1" port="$2" method="$3" password="$4" country="${5:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}SS${ip_suffix:+-${ip_suffix}}"
    local userinfo=$(printf '%s:%s' "$method" "$password" | base64 -w 0 2>/dev/null || printf '%s:%s' "$method" "$password" | base64)
    printf '%s\n' "ss://${userinfo}@${ip}:${port}#${name}"
}

gen_snell_link() {
    local ip="$1" port="$2" psk="$3" version="${4:-4}" country="${5:-}"
    local mode="${6:-}" implementation="${7:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}Snell-v${version}${ip_suffix:+-${ip_suffix}}"
    # Mihomo 可同时承载多个 v4/v5 入站，分享名称必须包含端口。
    if [[ "$version" != 6 ]]; then
        name+="-${port}"
    elif [[ -n "$implementation" ]]; then
        name+="-${implementation}-${port}"
    fi
    # Snell 没有标准URI格式，使用自定义格式
    local query="version=${version}"
    if [[ "$version" == "6" ]]; then
        mode="${mode:-default}"
        query+="&mode=${mode}"
    fi
    printf '%s\n' "snell://${psk}@${ip}:${port}?${query}#${name}"
}

# 生成 Surge Snell 节点行。name 由调用者包含端口后缀，保证多入站节点唯一。
# Snell v6 的 mode 属于协议握手参数，必须与服务端配置完全一致。
gen_snell_surge_line() {
    local name="$1" ip="$2" port="$3" psk="$4" version="${5:-4}"
    local mode="${6:-default}" tfo="${7:-true}" stls_password="${8:-}" sni="${9:-}"
    local mode_arg="" stls_args=""
    [[ "$version" == "6" ]] && mode_arg=", mode=${mode}"
    if [[ -n "$stls_password" && -n "$sni" ]]; then
        stls_args=", shadow-tls-password=${stls_password}, shadow-tls-sni=${sni}, shadow-tls-version=3"
    fi
    printf '%s\n' "${name} = snell, ${ip}, ${port}, psk=${psk}, version=${version}${mode_arg}, reuse=true, tfo=${tfo}${stls_args}"
}

gen_tuic_link() {
    local ip="$1" port="$2" uuid="$3" password="$4" sni="$5" country="${6:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}TUIC${ip_suffix:+-${ip_suffix}}"
    printf '%s\n' "tuic://${uuid}:${password}@${ip}:${port}?congestion_control=bbr&alpn=h3&sni=${sni}&udp_relay_mode=native&allow_insecure=1#${name}"
}

gen_anytls_link() {
    local ip="$1" port="$2" password="$3" sni="$4" country="${5:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}AnyTLS${ip_suffix:+-${ip_suffix}}"
    printf '%s\n' "anytls://${password}@${ip}:${port}?sni=${sni}&allowInsecure=1#${name}"
}

gen_naive_link() {
    local host="$1" port="$2" username="$3" password="$4" country="${5:-}"
    local name="${country:+${country}-}Naive"
    # Shadowrocket HTTP/2 格式，使用域名
    printf '%s\n' "http2://${username}:${password}@${host}:${port}#${name}"
}

gen_shadowtls_link() {
    local ip="$1" port="$2" password="$3" method="$4" sni="$5" stls_password="$6" country="${7:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}ShadowTLS${ip_suffix:+-${ip_suffix}}"
    # ShadowTLS链接格式：ss://method:password@server:port#name + ShadowTLS参数
    local ss_link=$(echo -n "${method}:${password}" | base64 -w 0)
    printf '%s\n' "ss://${ss_link}@${ip}:${port}?plugin=shadow-tls;host=${sni};password=${stls_password}#${name}"
}

# gen_snell_v5_link 已合并到 gen_snell_link，通过 version 参数区分
gen_snell_v5_link() { gen_snell_link "$1" "$2" "$3" "${4:-5}" "${5:-}"; }

gen_socks_link() {
    local ip="$1" port="$2" username="$3" password="$4" country="${5:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}SOCKS5${ip_suffix:+-${ip_suffix}}"
    if [[ -n "$username" && -n "$password" ]]; then
        printf '%s\n' "https://t.me/socks?server=${ip}&port=${port}&user=${username}&pass=${password}"
    else
        printf '%s\n' "socks5://${ip}:${port}#${name}"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 连接测试
#═══════════════════════════════════════════════════════════════════════════════

test_connection() {
    # 服务端：检查所有已安装协议的端口 (从数据库读取)
    local installed=$(get_installed_protocols)
    for proto in $installed; do
        local port=""
        # 从 sing-box 协议记录读取
        if db_exists "singbox" "$proto"; then
            port=$(db_get_field "singbox" "$proto" "port")
        elif db_exists "singbox" "$proto"; then
            port=$(db_get_field "singbox" "$proto" "port")
        fi

        if [[ -n "$port" ]]; then
            if ss -tlnp 2>/dev/null | grep -q ":$port " || ss -ulnp 2>/dev/null | grep -q ":$port "; then
                _ok "$(get_protocol_name $proto) 端口 $port 已监听"
            else
                _err "$(get_protocol_name $proto) 端口 $port 未监听"
            fi
        fi
    done
}

test_latency() {
    local ip="$1" port="$2" proto="${3:-tcp}" start end
    _is_valid_domain_or_ip "$ip" || { echo "无效地址"; return 1; }
    _is_valid_port "$port" || { echo "无效端口"; return 1; }
    start=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))

    if [[ "$proto" == "hy2" || "$proto" == "tuic" ]]; then
        if ping -c 1 -W 2 "$ip" &>/dev/null; then
            end=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
            echo "$((end-start))ms"
        else
            echo "UDP"
        fi
    else
        # 优先使用 nc (netcat)，更通用且跨平台兼容性更好
        if command -v nc &>/dev/null; then
            if timeout 3 nc -z -w 2 "$ip" "$port" 2>/dev/null; then
                end=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
                echo "$((end-start))ms"
            else
                echo "超时"
            fi
        # 回退到 bash /dev/tcp（某些系统可能不支持）
        elif timeout 3 bash -c 'echo >/dev/tcp/$1/$2' _ "$ip" "$port" 2>/dev/null; then
            end=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
            echo "$((end-start))ms"
        else
            echo "超时"
        fi
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 软件安装
#═══════════════════════════════════════════════════════════════════════════════

# 安装系统依赖
install_deps() {
    _info "检查系统依赖..."
    if [[ "$DISTRO" == "alpine" ]]; then
        _info "更新软件包索引..."
        if ! timeout 60 apk update 2>&1 | grep -E '^(fetch|OK)' | sed 's/^/  /'; then
            if ! apk update &>/dev/null; then
                _err "更新软件包索引失败（可能超时）"
                return 1
            fi
        fi

        local deps="curl jq unzip iproute2 iptables ip6tables gcompat libc6-compat openssl socat bind-tools xz"
        _info "安装依赖: $deps"
        if ! timeout 180 apk add --no-cache $deps 2>&1 | grep -E '^(\(|OK|Installing|Executing)' | sed 's/^/  /'; then
            # 检查实际安装结果
            local missing=""
            for dep in $deps; do
                apk info -e "$dep" &>/dev/null || missing="$missing $dep"
            done
            if [[ -n "$missing" ]]; then
                _err "依赖安装失败:$missing"
                return 1
            fi
        fi
        _ok "依赖安装完成"
    elif [[ "$DISTRO" == "centos" ]]; then
        _info "安装 EPEL 源..."
        if ! timeout 120 yum install -y epel-release 2>&1 | grep -E '^(Installing|Verifying|Complete)' | sed 's/^/  /'; then
            if ! rpm -q epel-release &>/dev/null; then
                _err "EPEL 源安装失败（可能超时）"
                return 1
            fi
        fi

        local deps="curl jq unzip iproute iptables vim-common openssl socat bind-utils xz"
        _info "安装依赖: $deps"
        if ! timeout 300 yum install -y $deps 2>&1 | grep -E '^(Installing|Verifying|Complete|Downloading)' | sed 's/^/  /'; then
            # 检查实际安装结果
            local missing=""
            for dep in $deps; do
                rpm -q "$dep" &>/dev/null || missing="$missing $dep"
            done
            if [[ -n "$missing" ]]; then
                _err "依赖安装失败:$missing"
                return 1
            fi
        fi
        _ok "依赖安装完成"
    elif [[ "$DISTRO" == "debian" || "$DISTRO" == "ubuntu" ]]; then
        _info "更新软件包索引..."
        # 移除 -qq 让用户能看到进度，避免交互卡住
        if ! DEBIAN_FRONTEND=noninteractive apt-get update 2>&1 | grep -E '^(Hit|Get|Fetched|Reading)' | head -10 | sed 's/^/  /'; then
            # 即使 grep 没匹配到也继续，只要 apt-get 成功即可
            :
        fi

        local deps="curl jq unzip iproute2 xxd openssl socat dnsutils xz-utils iptables"
        _info "安装依赖: $deps"
        # 使用 DEBIAN_FRONTEND 避免交互，显示简化进度，移除 timeout 避免死锁
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y $deps 2>&1 | grep -E '^(Setting up|Unpacking|Processing|Get:|Fetched)' | sed 's/^/  /'; then
            # 检查实际安装结果
            if ! dpkg -l $deps >/dev/null 2>&1; then
                _err "依赖安装失败"
                return 1
            fi
        fi
        _ok "依赖安装完成"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 证书管理
#═══════════════════════════════════════════════════════════════════════════════

# 安装 acme.sh
install_acme_tool() {
    # 检查多个可能的安装位置
    local acme_paths=(
        "$HOME/.acme.sh/acme.sh"
        "/root/.acme.sh/acme.sh"
        "/usr/local/bin/acme.sh"
    )

    for acme_path in "${acme_paths[@]}"; do
        if [[ -f "$acme_path" ]]; then
            _ok "acme.sh 已安装 ($acme_path)"
            return 0
        fi
    done

    _info "安装 acme.sh 证书申请工具..."

    # 方法1: 使用 git clone 到私有临时目录，并校验仓库 blob。
    if command -v git &>/dev/null; then
        _info "尝试使用 git 安装..."
        local acme_tmp
        acme_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sing-acme-install.XXXXXX") || return 1
        if git clone --depth 1 https://github.com/acmesh-official/acme.sh.git "$acme_tmp/repo" 2>/dev/null &&
           _verify_github_blob "acmesh-official/acme.sh" "master" "acme.sh" "$acme_tmp/repo/acme.sh"; then
            (cd "$acme_tmp/repo" && ./acme.sh --install -m "$ACME_DEFAULT_EMAIL" 2>/dev/null)
            rm -rf "$acme_tmp"
            if [[ -f "$HOME/.acme.sh/acme.sh" ]]; then
                _ok "acme.sh 安装成功 (git)"
                return 0
            fi
        else
            rm -rf "$acme_tmp"
        fi
    fi

    # 方法2: 直接下载脚本；至少先做 Bash 语法校验再安装。
    _info "尝试直接下载..."
    mkdir -p "$HOME/.acme.sh"
    if curl -sL -o "$HOME/.acme.sh/acme.sh" "https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh" 2>/dev/null; then
        if ! _verify_github_blob "acmesh-official/acme.sh" "master" "acme.sh" "$HOME/.acme.sh/acme.sh" ||
           ! bash -n "$HOME/.acme.sh/acme.sh"; then
            rm -f "$HOME/.acme.sh/acme.sh"
            _err "下载的 acme.sh 语法校验失败"
            return 1
        fi
        chmod 700 "$HOME/.acme.sh/acme.sh"
        if [[ -f "$HOME/.acme.sh/acme.sh" ]]; then
            _ok "acme.sh 安装成功 (直接下载)"
            return 0
        fi
    fi

    _err "acme.sh 安装失败，请检查网络连接"
    _warn "请从 acmesh-official/acme.sh 官方仓库核验后手动安装"
    return 1
}

# 确保 ACME 账户邮箱有效（避免 example.com 被拒）
ensure_acme_account_email() {
    local acme_sh="$1"
    local account_conf="$HOME/.acme.sh/account.conf"
    local current_email=""

    if [[ -f "$account_conf" ]]; then
        current_email=$(grep -E "^ACCOUNT_EMAIL=" "$account_conf" | head -1 | sed -E "s/^ACCOUNT_EMAIL=['\"]?([^'\"]*)['\"]?$/\1/")
    fi

    if [[ -z "$current_email" || "$current_email" == *"example.com"* ]]; then
        echo ""
        _info "设置 ACME 账户邮箱为默认值: $ACME_DEFAULT_EMAIL"
        if [[ -f "$account_conf" ]]; then
            if grep -q "^ACCOUNT_EMAIL=" "$account_conf"; then
                sed -i "s/^ACCOUNT_EMAIL=.*/ACCOUNT_EMAIL='$ACME_DEFAULT_EMAIL'/" "$account_conf"
            else
                echo "ACCOUNT_EMAIL='$ACME_DEFAULT_EMAIL'" >> "$account_conf"
            fi
        else
            mkdir -p "$HOME/.acme.sh"
            echo "ACCOUNT_EMAIL='$ACME_DEFAULT_EMAIL'" > "$account_conf"
        fi

        if ! ACCOUNT_EMAIL="$ACME_DEFAULT_EMAIL" "$acme_sh" --register-account -m "$ACME_DEFAULT_EMAIL" >/dev/null 2>&1; then
            _err "ACME 账户注册失败，请检查网络或稍后重试"
            return 1
        fi
        _ok "ACME 账户邮箱已更新: $ACME_DEFAULT_EMAIL"
    fi

    return 0
}

# DNS-01 验证申请证书
# 参数: $1=域名 $2=证书目录 $3=协议
_issue_cert_dns() {
    local domain="$1"
    local cert_dir="$2"
    local protocol="$3"

    echo ""
    _line >&2
    echo -e "  ${C}DNS-01 验证模式${NC}"
    _line >&2
    echo ""
    echo -e "  ${Y}支持的 DNS 服务商：${NC}"
    echo -e "  1) Cloudflare"
    echo -e "  2) Aliyun (阿里云)"
    echo -e "  3) DNSPod (腾讯云)"
    echo -e "  4) 手动 DNS 验证"
    echo ""
    read -rp "  请选择 DNS 服务商 [1-4]: " dns_choice

    local dns_api=""

    case "$dns_choice" in
        1)
            echo ""
            echo -e "  ${D}获取 Cloudflare API Token:${NC}"
            echo -e "  ${D}https://dash.cloudflare.com/profile/api-tokens${NC}"
            echo -e "  ${D}创建 Token 时选择 'Edit zone DNS' 模板${NC}"
            echo ""
            read -rsp "  请输入 CF_Token: " cf_token
            echo ""
            [[ -z "$cf_token" ]] && { _err "Token 不能为空"; return 1; }
            dns_api="dns_cf"
            export CF_Token="$cf_token"
            ;;
        2)
            echo ""
            echo -e "  ${D}获取阿里云 AccessKey:${NC}"
            echo -e "  ${D}https://ram.console.aliyun.com/manage/ak${NC}"
            echo ""
            read -rsp "  请输入 Ali_Key: " ali_key
            echo ""
            read -rsp "  请输入 Ali_Secret: " ali_secret
            echo ""
            [[ -z "$ali_key" || -z "$ali_secret" ]] && { _err "Key/Secret 不能为空"; return 1; }
            dns_api="dns_ali"
            export Ali_Key="$ali_key"
            export Ali_Secret="$ali_secret"
            ;;
        3)
            echo ""
            echo -e "  ${D}获取 DNSPod Token:${NC}"
            echo -e "  ${D}https://console.dnspod.cn/account/token/token${NC}"
            echo ""
            read -rsp "  请输入 DP_Id: " dp_id
            echo ""
            read -rsp "  请输入 DP_Key: " dp_key
            echo ""
            [[ -z "$dp_id" || -z "$dp_key" ]] && { _err "ID/Key 不能为空"; return 1; }
            dns_api="dns_dp"
            export DP_Id="$dp_id"
            export DP_Key="$dp_key"
            ;;
        4)
            # 手动 DNS 验证
            _issue_cert_dns_manual "$domain" "$cert_dir" "$protocol"
            return $?
            ;;
        *)
            _err "无效选择"
            return 1
            ;;
    esac

    # 安装 acme.sh
    install_acme_tool || return 1
    local acme_sh="$HOME/.acme.sh/acme.sh"
    ensure_acme_account_email "$acme_sh" || return 1

    _info "正在通过 DNS 验证申请证书..."
    echo ""

    local acme_dns_log
    acme_dns_log=$(mktemp "${TMPDIR:-/tmp}/vless-acme-dns.XXXXXX") || return 1

    local reload_cmd="chmod 600 $cert_dir/server.key; chmod 644 $cert_dir/server.crt"

    if "$acme_sh" --issue -d "$domain" --dns "$dns_api" --force 2>&1 | tee "$acme_dns_log" | grep -E "^\[|Verify finished|Cert success|error|Error" | sed 's/^/  /'; then
        echo ""
        _ok "证书申请成功，安装证书..."

        "$acme_sh" --install-cert -d "$domain" \
            --key-file       "$cert_dir/server.key"  \
            --fullchain-file "$cert_dir/server.crt" \
            --reloadcmd      "$reload_cmd" >/dev/null 2>&1

        # 保存域名
        echo "$domain" > "$CFG/cert_domain"

        rm -f "$acme_dns_log"

        # 读取自定义 nginx 端口
        local custom_port=""
        [[ -f "$CFG/.nginx_port_tmp" ]] && custom_port=$(cat "$CFG/.nginx_port_tmp")
        create_fake_website "$domain" "$protocol" "$custom_port"

        _ok "证书已配置到 $cert_dir"
        diagnose_certificate "$domain"
        return 0
    else
        echo ""
        _err "DNS 验证失败！"
        grep -E "(error|Error)" "$acme_dns_log" 2>/dev/null | head -3
        rm -f "$acme_dns_log"
        return 1
    fi
}

# 手动 DNS 验证
_issue_cert_dns_manual() {
    local domain="$1"
    local cert_dir="$2"
    local protocol="$3"

    install_acme_tool || return 1
    local acme_sh="$HOME/.acme.sh/acme.sh"
    ensure_acme_account_email "$acme_sh" || return 1

    echo ""
    _info "开始手动 DNS 验证..."
    echo ""

    # 获取 DNS 记录
    local txt_record=$("$acme_sh" --issue -d "$domain" --dns --yes-I-know-dns-manual-mode-enough-go-ahead-please --force 2>&1 | sed -n "s/.*TXT value: '\([^']*\)'.*/\1/p")

    if [[ -z "$txt_record" ]]; then
        # 尝试另一种方式获取
        local acme_manual_log
        acme_manual_log=$(mktemp "${TMPDIR:-/tmp}/vless-acme-manual.XXXXXX") || return 1
        "$acme_sh" --issue -d "$domain" --dns --yes-I-know-dns-manual-mode-enough-go-ahead-please --force 2>&1 | tee "$acme_manual_log"
        txt_record=$(sed -n "s/.*TXT value: '\([^']*\)'.*/\1/p" "$acme_manual_log" 2>/dev/null)
        rm -f "$acme_manual_log"
    fi

    if [[ -z "$txt_record" ]]; then
        _err "无法获取 DNS TXT 记录值"
        return 1
    fi

    echo ""
    _line
    echo -e "  ${Y}请添加以下 DNS TXT 记录：${NC}"
    _line
    echo ""
    echo -e "  主机记录: ${G}_acme-challenge${NC}"
    echo -e "  记录类型: ${G}TXT${NC}"
    echo -e "  记录值:   ${G}$txt_record${NC}"
    echo ""
    _line
    echo ""
    echo -e "  ${D}添加完成后，等待 DNS 生效（通常 1-5 分钟）${NC}"
    echo ""
    read -rp "  DNS 记录添加完成后按回车继续..." _

    _info "验证 DNS 记录..."

    # 完成验证
    if "$acme_sh" --renew -d "$domain" --yes-I-know-dns-manual-mode-enough-go-ahead-please --force 2>&1 | grep -q "Cert success"; then
        echo ""
        _ok "证书申请成功，安装证书..."

        "$acme_sh" --install-cert -d "$domain" \
            --key-file       "$cert_dir/server.key"  \
            --fullchain-file "$cert_dir/server.crt" >/dev/null 2>&1

        echo "$domain" > "$CFG/cert_domain"

        local custom_port=""
        [[ -f "$CFG/.nginx_port_tmp" ]] && custom_port=$(cat "$CFG/.nginx_port_tmp")
        create_fake_website "$domain" "$protocol" "$custom_port"

        _ok "证书已配置到 $cert_dir"
        echo ""
        _warn "注意: 手动 DNS 模式无法自动续期，证书到期前需要手动更新"
        return 0
    else
        _err "DNS 验证失败，请检查 TXT 记录是否正确"
        return 1
    fi
}

# 申请 ACME 证书
# 参数: $1=域名
get_acme_cert() {
    local domain=$1
    local protocol="${2:-unknown}"
    local cert_dir="$CFG/certs"
    mkdir -p "$cert_dir"

    # 检查是否已有相同域名的证书
    if [[ -f "$CFG/cert_domain" ]]; then
        local existing_domain=$(cat "$CFG/cert_domain")
        if [[ "$existing_domain" == "$domain" && -f "$cert_dir/server.crt" && -f "$cert_dir/server.key" ]]; then
            _ok "检测到相同域名的现有证书，跳过申请"
            # 检查证书是否仍然有效
            if openssl x509 -in "$cert_dir/server.crt" -noout -checkend 2592000 >/dev/null 2>&1; then
                _ok "现有证书仍然有效（30天以上）"

                # 读取自定义 nginx 端口（如果有）
                local custom_port=""
                [[ -f "$CFG/.nginx_port_tmp" ]] && custom_port=$(cat "$CFG/.nginx_port_tmp")

                # 确保Web服务器也启动（复用证书时也需要）
                create_fake_website "$domain" "$protocol" "$custom_port"

                diagnose_certificate "$domain"
                return 0
            else
                _warn "现有证书即将过期，重新申请..."
            fi
        fi
    fi

    # 先检查域名解析 (快速验证)
    _info "检查域名解析..."
    if ! check_domain_dns "$domain"; then
        _err "域名解析检查失败，无法申请 Let's Encrypt 证书"
        echo ""
        echo -e "  ${Y}选项：${NC}"
        echo -e "  1) 使用自签证书 (安全性较低，易被识别)"
        echo -e "  2) 重新输入域名"
        echo -e "  3) 退出安装"
        echo ""
        read -rp "  请选择 [1-3]: " choice

        case "$choice" in
            1)
                _warn "将使用自签证书"
                return 1  # 返回失败，让调用方使用自签证书
                ;;
            2)
                return 2  # 返回特殊值，表示需要重新输入域名
                ;;
            3|"")
                _info "已退出安装"
                exit 0
                ;;
            *)
                _err "无效选择，退出安装"
                exit 0
                ;;
        esac
    fi

    # 域名解析通过，询问是否申请证书
    echo ""
    _ok "域名解析验证通过！"
    echo ""
    echo -e "  ${Y}接下来将申请 Let's Encrypt 证书：${NC}"
    echo -e "  • 域名: ${G}$domain${NC}"
    echo -e "  • 证书有效期: 90天 (自动续期)"
    echo ""
    echo -e "  ${Y}请选择验证方式：${NC}"
    echo -e "  1) HTTP 验证 (需要80端口，推荐)"
    echo -e "  2) DNS 验证 (无需80端口，适合NAT/无公网IP)"
    echo -e "  3) 取消"
    echo ""
    read -rp "  请选择 [1-3]: " verify_method

    case "$verify_method" in
        2)
            # DNS 验证模式
            _issue_cert_dns "$domain" "$cert_dir" "$protocol"
            return $?
            ;;
        3)
            _info "已取消证书申请"
            return 2
            ;;
        1|"")
            # HTTP 验证模式（默认）
            ;;
        *)
            _err "无效选择"
            return 1
            ;;
    esac

    # 用户确认后再安装 acme.sh
    _info "安装证书申请工具..."
    install_acme_tool || return 1

    local acme_sh="$HOME/.acme.sh/acme.sh"
    ensure_acme_account_email "$acme_sh" || return 1

    # 临时停止可能占用 80 端口的服务（兼容 Alpine/systemd）
    local nginx_was_running=false
    if svc status nginx 2>/dev/null; then
        nginx_was_running=true
        _info "临时停止 Nginx..."
        svc stop nginx
    fi

    _info "正在为 $domain 申请证书 (Let's Encrypt)..."
    echo ""

    # 获取服务器IP用于错误提示
    local server_ip=$(get_ipv4)
    [[ -z "$server_ip" ]] && server_ip=$(get_ipv6)

    # 构建 reloadcmd（兼容 systemd 和 OpenRC）
    local reload_cmd="chmod 600 $cert_dir/server.key; chmod 644 $cert_dir/server.crt; chown root:root $cert_dir/server.key $cert_dir/server.crt; if command -v systemctl >/dev/null 2>&1; then systemctl restart sing-singbox 2>/dev/null || true; elif command -v rc-service >/dev/null 2>&1; then rc-service sing-singbox restart 2>/dev/null || true; fi"

    # 使用 standalone 模式申请证书，显示实时进度
    local acme_log
    acme_log=$(mktemp "${TMPDIR:-/tmp}/vless-acme-output.XXXXXX") || return 1

    # 直接执行 acme.sh，不使用 timeout（避免某些系统兼容性问题）
    if "$acme_sh" --issue -d "$domain" --standalone --httpport 80 --force 2>&1 | tee "$acme_log" | grep -E "^\[|Verify finished|Cert success|error|Error" | sed 's/^/  /'; then
        echo ""
        _ok "证书申请成功，安装证书..."

        # 安装证书到指定目录，并设置权限和自动重启服务
        "$acme_sh" --install-cert -d "$domain" \
            --key-file       "$cert_dir/server.key"  \
            --fullchain-file "$cert_dir/server.crt" \
            --reloadcmd      "$reload_cmd" >/dev/null 2>&1

        rm -f "$acme_log"

        # 恢复 Nginx
        if [[ "$nginx_was_running" == "true" ]]; then
            svc start nginx
        fi

        _ok "证书已配置到 $cert_dir"
        _ok "证书自动续期已启用 (60天后)"

        # 读取自定义 nginx 端口（如果有）
        local custom_port=""
        [[ -f "$CFG/.nginx_port_tmp" ]] && custom_port=$(cat "$CFG/.nginx_port_tmp")

        # 创建简单的伪装网页
        create_fake_website "$domain" "$protocol" "$custom_port"

        # 验证证书文件
        if [[ -f "$cert_dir/server.crt" && -f "$cert_dir/server.key" ]]; then
            _ok "证书文件验证通过"
            # 运行证书诊断
            diagnose_certificate "$domain"
        else
            _err "证书文件不存在"
            return 1
        fi

        return 0
    else
        echo ""
        # 恢复 Nginx
        if [[ "$nginx_was_running" == "true" ]]; then
            svc start nginx
        fi

        _err "证书申请失败！"
        echo ""
        _err "详细错误信息："
        cat "$acme_log" 2>/dev/null | grep -E "(error|Error|ERROR|fail|Fail|FAIL)" | head -5 | while read -r line; do
            _err "  $line"
        done
        rm -f "$acme_log"
        echo ""
        _err "常见问题检查："
        _err "  1. 域名是否正确解析到本机 IP: $server_ip"
        _err "  2. 80 端口是否在防火墙中开放"
        _err "  3. 域名是否已被其他证书占用"
        _err "  4. 是否有其他程序占用80端口"
        echo ""

        # 给用户选择而不是自动回退
        echo -e "  ${W}请选择操作：${NC}"
        echo -e "  ${G}1${NC}) 重试证书申请"
        echo -e "  ${G}2${NC}) 使用 DNS 验证模式 (需要 DNS API)"
        echo -e "  ${G}3${NC}) 使用自签名证书 (不推荐)"
        echo -e "  ${G}0${NC}) 取消安装"
        echo ""
        read -rp "  请选择 [0]: " cert_choice
        cert_choice="${cert_choice:-0}"

        case "$cert_choice" in
            1)
                # 重试
                get_acme_cert "$domain" "$protocol"
                return $?
                ;;
            2)
                # DNS 验证模式
                _info "切换到 DNS 验证模式..."
                get_acme_cert_dns "$domain" "$protocol"
                return $?
                ;;
            3)
                # 自签名证书
                _warn "使用自签名证书模式..."
                return 1
                ;;
            *)
                # 取消
                _warn "已取消安装"
                return 2
                ;;
        esac
    fi
}

# SNI配置交互式询问
# 参数: $1=默认SNI (可选), $2=已申请的域名 (可选)
ask_sni_config() {
    local default_sni="${1:-$(gen_sni)}"
    local cert_domain="${2:-}"

    # 如果有证书域名，检查是否是真实证书
    if [[ -n "$cert_domain" && -f "$CFG/certs/server.crt" ]]; then
        local is_real_cert=false
        local issuer=$(openssl x509 -in "$CFG/certs/server.crt" -noout -issuer 2>/dev/null)
        if [[ "$issuer" == *"Let's Encrypt"* ]] || [[ "$issuer" == *"R3"* ]] || [[ "$issuer" == *"R10"* ]] || [[ "$issuer" == *"R11"* ]] || [[ "$issuer" == *"E1"* ]] || [[ "$issuer" == *"ZeroSSL"* ]] || [[ "$issuer" == *"Buypass"* ]]; then
            is_real_cert=true
        fi

        # 真实证书：直接使用证书域名，不询问
        if [[ "$is_real_cert" == "true" ]]; then
            _ok "使用证书域名: $cert_domain" >&2
            echo "$cert_domain"
            return 0
        fi
    fi

    echo "" >&2
    _line >&2
    echo -e "  ${W}SNI 配置${NC}" >&2

    # 生成一个真正的随机 SNI（用于"更隐蔽"选项）
    local random_sni=$(gen_sni)

    # 如果有证书域名（自签名证书），询问是否使用
    # 注意：自签名证书的域名没有实际意义，推荐使用随机 SNI
    if [[ -n "$cert_domain" ]]; then
        echo -e "  ${G}1${NC}) 使用随机SNI (${G}$random_sni${NC}) - 推荐" >&2
        echo -e "  ${G}2${NC}) 自定义SNI" >&2
        echo "" >&2

        local sni_choice=""
        while true; do
            read -rp "  请选择 [1-2，默认 1]: " sni_choice

            if [[ -z "$sni_choice" ]]; then
                sni_choice="1"
            fi

            if [[ "$sni_choice" == "1" ]]; then
                echo "$random_sni"
                return 0
            elif [[ "$sni_choice" == "2" ]]; then
                break
            else
                _err "无效选择: $sni_choice" >&2
                _warn "请输入 1 或 2" >&2
            fi
        done
    else
        # 没有证书域名时（如Reality协议），提供随机SNI和自定义选项
        echo -e "  ${G}1${NC}) 使用随机SNI (${G}$default_sni${NC}) - 推荐" >&2
        echo -e "  ${G}2${NC}) 自定义SNI" >&2
        echo "" >&2

        local sni_choice=""
        while true; do
            read -rp "  请选择 [1-2，默认 1]: " sni_choice

            if [[ -z "$sni_choice" ]]; then
                sni_choice="1"
            fi

            if [[ "$sni_choice" == "1" ]]; then
                echo "$default_sni"
                return 0
            elif [[ "$sni_choice" == "2" ]]; then
                break
            else
                _err "无效选择: $sni_choice" >&2
                _warn "请输入 1 或 2" >&2
            fi
        done
    fi

    # 自定义SNI输入
    while true; do
        echo "" >&2
        echo -e "  ${C}请输入自定义SNI域名 (回车使用随机SNI):${NC}" >&2
        read -rp "  SNI: " custom_sni

        if [[ -z "$custom_sni" ]]; then
            # 重新生成一个随机SNI
            local new_random_sni=$(gen_sni)
            echo -e "  ${G}使用随机SNI: $new_random_sni${NC}" >&2
            echo "$new_random_sni"
            return 0
        else
            # 基本域名格式验证
            if [[ "$custom_sni" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
                echo "$custom_sni"
                return 0
            else
                _err "无效SNI格式: $custom_sni" >&2
                _warn "SNI格式示例: www.example.com" >&2
            fi
        fi
    done
}

# 证书配置交互式询问
# 参数: $1=默认SNI (可选)
ask_cert_config() {
    local default_sni="${1:-bing.com}"
    local protocol="${2:-unknown}"

    # 检查是否已有 ACME 证书，如果有则直接复用
    if [[ -f "$CFG/cert_domain" && -f "$CFG/certs/server.crt" ]]; then
        local existing_domain=$(cat "$CFG/cert_domain")
        local issuer=$(openssl x509 -in "$CFG/certs/server.crt" -noout -issuer 2>/dev/null)
        if [[ "$issuer" == *"Let's Encrypt"* ]] || [[ "$issuer" == *"R3"* ]] || [[ "$issuer" == *"R10"* ]] || [[ "$issuer" == *"R11"* ]]; then
            _ok "检测到现有 ACME 证书: $existing_domain，自动复用" >&2
            echo "$existing_domain"
            return 0
        fi
    fi

    # 所有提示信息输出到 stderr，避免污染返回值
    echo "" >&2
    _line >&2
    echo -e "  ${W}证书配置模式${NC}" >&2
    echo -e "  ${G}1${NC}) 使用真实域名 (推荐 - 自动申请 Let's Encrypt 证书)" >&2
    echo -e "  ${Y}2${NC}) 无域名 (使用自签证书 - 安全性较低，易被识别)" >&2
    echo "" >&2

    local cert_mode=""
    local domain=""
    local use_acme=false

    # 验证证书模式选择
    while true; do
        read -rp "  请选择 [1-2，默认 2]: " cert_mode

        # 如果用户直接回车，使用默认选项 2
        if [[ -z "$cert_mode" ]]; then
            cert_mode="2"
        fi

        # 验证输入是否为有效选项
        if [[ "$cert_mode" == "1" || "$cert_mode" == "2" ]]; then
            break
        else
            _err "无效选择: $cert_mode" >&2
            _warn "请输入 1 或 2" >&2
        fi
    done

    if [[ "$cert_mode" == "1" ]]; then
        # 域名输入循环，支持重新输入
        while true; do
            echo "" >&2
            echo -e "  ${C}提示: 域名必须已解析到本机 IP${NC}" >&2
            read -rp "  请输入你的域名: " domain

            if [[ -z "$domain" ]]; then
                _warn "域名不能为空，使用自签证书" >&2
                gen_self_cert "$default_sni" >&2
                domain=""
                break
            else
                # 基本域名格式验证
                if ! [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
                    _err "无效域名格式: $domain" >&2
                    _warn "域名格式示例: example.com 或 sub.example.com" >&2
                    continue
                fi
                local cert_result
                get_acme_cert "$domain" "$protocol" >&2
                cert_result=$?

                if [[ $cert_result -eq 0 ]]; then
                    # ACME 成功
                    use_acme=true
                    echo "$domain" > "$CFG/cert_domain"
                    break
                elif [[ $cert_result -eq 2 ]]; then
                    # 需要重新输入域名，继续循环
                    continue
                else
                    # ACME 失败，使用自签证书，返回空字符串
                    gen_self_cert "$default_sni" >&2
                    domain=""
                    break
                fi
            fi
        done
    else
        # 无域名模式：使用自签证书，返回空字符串表示没有真实域名
        gen_self_cert "$default_sni" >&2
        domain=""
    fi

    # 只返回域名到 stdout（空字符串表示使用了自签证书）
    echo "$domain"
}

fix_selinux_context() {
    # 仅在 CentOS/RHEL 且 SELinux 启用时执行
    if [[ "$DISTRO" != "centos" ]]; then
        return 0
    fi

    # 检查 SELinux 是否启用
    if ! command -v getenforce &>/dev/null || [[ "$(getenforce 2>/dev/null)" == "Disabled" ]]; then
        return 0
    fi

    _info "配置 SELinux 上下文..."

    # 允许自定义端口
    if command -v semanage &>/dev/null; then
        local port="$1"
        if [[ -n "$port" ]]; then
            semanage port -a -t http_port_t -p tcp "$port" 2>/dev/null || true
            semanage port -a -t http_port_t -p udp "$port" 2>/dev/null || true
        fi
    fi

    # 恢复文件上下文
    if command -v restorecon &>/dev/null; then
        restorecon -Rv "$CFG" 2>/dev/null || true
    fi

    # 允许网络连接
    if command -v setsebool &>/dev/null; then
        setsebool -P httpd_can_network_connect 1 2>/dev/null || true
    fi
}

# GitHub API 请求配置
readonly GITHUB_API_PER_PAGE=10
readonly SNELL_V6_REPO="passeway/Snell"
readonly SNELL_V6_INSTALLED_VERSION_FILE="$CFG/.snell-v6-installed-version"

# 获取文件修改时间戳（跨平台兼容）
_get_file_mtime() {
    local file="$1"
    [[ ! -f "$file" ]] && return 1

    # 尝试 Linux 格式
    if stat -c %Y "$file" 2>/dev/null; then
        return 0
    fi

    # 尝试 macOS/BSD 格式
    if stat -f %m "$file" 2>/dev/null; then
        return 0
    fi

    # 都失败则返回错误
    return 1
}

# 下载脚本到临时文件（回显临时文件路径）
_verify_github_blob() {
    local repo="$1" ref="$2" path="$3" file="$4" expected actual size
    expected=$(curl -fsSL --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/${repo}/contents/${path}?ref=${ref}" |
        jq -r '.sha // empty' 2>/dev/null) || return 1
    [[ "$expected" =~ ^[0-9a-f]{40}$ ]] || return 1
    size=$(wc -c <"$file" | tr -d '[:space:]')
    if command -v sha1sum >/dev/null 2>&1; then
        actual=$({ printf 'blob %s\0' "$size"; cat "$file"; } | sha1sum | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$({ printf 'blob %s\0' "$size"; cat "$file"; } | shasum -a 1 | awk '{print $1}')
    else
        actual=$({ printf 'blob %s\0' "$size"; cat "$file"; } | openssl dgst -sha1 2>/dev/null | awk '{print $NF}')
    fi
    [[ "$actual" == "$expected" ]]
}

_script_update_ref() {
    case "$1" in
        stable) printf '%s\n' "$SCRIPT_STABLE_REF" ;;
        dev) printf '%s\n' "$SCRIPT_TEST_REF" ;;
        *) return 1 ;;
    esac
}

_verify_script_blob() {
    local file="$1" ref="${2:-$SCRIPT_SOURCE_REF}"
    _verify_github_blob "$SCRIPT_SOURCE_REPO" "$ref" "$SCRIPT_SOURCE_PATH" "$file" &&
        bash -n "$file"
}

_fetch_script_tmp() {
    local connect_timeout="${1:-10}" max_time="${2:-30}" ref="${3:-$SCRIPT_SOURCE_REF}"
    local commit tmp_file
    [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
    # 分支解析到当前提交，再按同一提交下载和校验，避免 raw 分支缓存。
    commit=$(curl -fsSL -H 'Cache-Control: no-cache' --connect-timeout "$connect_timeout" \
        --max-time "$max_time" "https://api.github.com/repos/${SCRIPT_SOURCE_REPO}/commits/${ref}" |
        jq -er '.sha | select(test("^[0-9a-f]{40}$"))') || return 1
    tmp_file=$(mktemp) || return 1
    if ! curl -fsSL --connect-timeout "$connect_timeout" --max-time "$max_time" \
        -o "$tmp_file" "https://raw.githubusercontent.com/${SCRIPT_SOURCE_REPO}/${commit}/${SCRIPT_SOURCE_PATH}" ||
       ! _verify_script_blob "$tmp_file" "$commit"; then
        rm -f "$tmp_file"
        _err "脚本下载或 GitHub blob 校验失败"
        return 1
    fi
    printf '%s\n' "$tmp_file"
}

# 提取脚本版本号
_extract_script_version() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    grep -m1 '^readonly VERSION=' "$file" 2>/dev/null | cut -d'"' -f2
}

# 下载脚本到指定路径
_download_script_to() {
    local target="$1"
    local tmp_file
    tmp_file=$(_fetch_script_tmp 10) || return 1
    if mv "$tmp_file" "$target" 2>/dev/null; then
        return 0
    fi
    if cp -f "$tmp_file" "$target" 2>/dev/null; then
        rm -f "$tmp_file"
        return 0
    fi
    rm -f "$tmp_file"
    return 1
}

# 获取最新标签版本号（无缓存）
_get_latest_tag_version() {
    local repo="$1"
    local result version

    result=$(curl -sL --connect-timeout 5 --max-time 10 \
    "https://api.github.com/repos/${repo}/tags?per_page=1" 2>/dev/null)

    [[ -z "$result" ]] && return 1

    version=$(echo "$result" | jq -r '.[0].name // empty' 2>/dev/null | sed 's/^v//')

    [[ -z "$version" ]] && return 1

    echo "$version"
}

_get_latest_script_version_from_raw() {
    local ref="${1:-$SCRIPT_SOURCE_REF}" version tmp_file
    tmp_file=$(_fetch_script_tmp 5 10 "$ref") || return 1
    version=$(_extract_script_version "$tmp_file")
    rm -f "$tmp_file"
    [[ -z "$version" ]] && return 1
    echo "$version"
}

# 获取所选分支当前脚本版本，不依赖 Release、tag 或本地版本缓存。
_get_latest_script_version() {
    _get_latest_script_version_from_raw "${3:-$SCRIPT_SOURCE_REF}"
}

# 语义化版本比较（v1 > v2 返回 0）
_version_gt() {
    local v1="$1" v2="$2"
    [[ "$v1" == "$v2" ]] && return 1
    local IFS=.
    local i v1_arr=($v1) v2_arr=($v2)
    for ((i=0; i<${#v1_arr[@]} || i<${#v2_arr[@]}; i++)); do
        local n1=${v1_arr[i]:-0} n2=${v2_arr[i]:-0}
        ((n1 > n2)) && return 0
        ((n1 < n2)) && return 1
    done
    return 1
}


# 实时查询；结果只属于本次运行，不落地缓存。
_check_script_update() {
    SCRIPT_REMOTE_VERSION=""
    if ! SCRIPT_REMOTE_VERSION=$(_get_latest_script_version false true "$SCRIPT_SOURCE_REF"); then
        _warn "无法实时检查脚本版本，请检查网络后重试"
        return 1
    fi
}

_has_script_update() {
    [[ -n "${SCRIPT_REMOTE_VERSION:-}" ]] && _version_gt "$SCRIPT_REMOTE_VERSION" "$VERSION"
}

_get_script_update_info() {
    _has_script_update && printf '%s\n' "$SCRIPT_REMOTE_VERSION"
}

_get_latest_version() {
    local result version
    result=$(curl -fsSL -H 'Cache-Control: no-cache' --connect-timeout 5 --max-time 15 \
        "https://api.github.com/repos/$1/releases/latest") || return 1
    version=$(jq -er '.tag_name | select(type == "string" and length > 0)' <<<"$result") || return 1
    printf '%s\n' "${version#v}"
}

_get_latest_prerelease_version() {
    local result version
    result=$(curl -fsSL -H 'Cache-Control: no-cache' --connect-timeout 5 --max-time 15 \
        "https://api.github.com/repos/$1/releases?per_page=$GITHUB_API_PER_PAGE") || return 1
    version=$(jq -er '[.[] | select(.draft == false and .prerelease == true)][0].tag_name |
        select(type == "string" and length > 0)' <<<"$result") || return 1
    printf '%s\n' "${version#v}"
}

_is_snell_v6_version() {
    [[ "$1" =~ ^6\.[0-9]+\.[0-9]+([A-Za-z][A-Za-z0-9._-]*)?$ ]]
}


_get_snell_v6_channel_version() {
    local channel="$1" result version
    [[ "$channel" == stable || "$channel" == prerelease ]] || return 1
    result=$(curl -fsSL -H 'Cache-Control: no-cache' --connect-timeout 5 --max-time 15 \
        "https://api.github.com/repos/${SNELL_V6_REPO}/releases?per_page=${GITHUB_API_PER_PAGE}") || return 1
    version=$(jq -er --arg channel "$channel" '
        [.[] | select(.draft == false and (.tag_name | test("^v?6\\.")) and
            (.prerelease == ($channel == "prerelease")))][0].tag_name |
        select(type == "string" and length > 0)' <<<"$result") || return 1
    version="${version#v}"
    _is_snell_v6_version "$version" || return 1
    printf '%s\n' "$version"
}

_get_snell_v6_stable_version() { _get_snell_v6_channel_version stable; }
_get_snell_v6_prerelease_version() { _get_snell_v6_channel_version prerelease; }
_get_snell_v6_latest_version() { _get_snell_v6_channel_version stable; }

_get_release_versions() {
    local repo="$1" limit="${2:-10}" mode="${3:-stable}" result
    [[ "$limit" =~ ^[0-9]+$ ]] || return 1
    result=$(curl -fsSL -H 'Cache-Control: no-cache' --connect-timeout 5 --max-time 20 \
        "https://api.github.com/repos/$repo/releases?per_page=$GITHUB_API_PER_PAGE") || return 1
    jq -er --arg mode "$mode" --argjson limit "$limit" '
        [.[] | select(.draft == false) |
         select(if $mode == "stable" then .prerelease == false
                elif ($mode == "prerelease" or $mode == "test" or $mode == "beta") then .prerelease == true
                else true end)] | .[0:$limit][] | .tag_name | ltrimstr("v")' <<<"$result"
}

# 获取版本变更日志
_get_release_changelog() {
    local repo="$1" version="$2"
    local tag="v$version"
    local result
    result=$(curl -sL "https://api.github.com/repos/$repo/releases/tags/$tag" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    echo "$result" | jq -r '.body // empty' 2>/dev/null
}

# 展示变更日志 (简化版)
_show_changelog_summary() {
    local repo="$1" version="$2" max_lines="${3:-10}"
    local changelog
    changelog=$(_get_release_changelog "$repo" "$version")
    if [[ -z "$changelog" ]]; then
        echo "  (无变更日志)" >&2
        return
    fi

    echo -e "\n  ${C}变更摘要 (v${version})${NC}" >&2
    _line
    echo "$changelog" | head -n "$max_lines" | while IFS= read -r line; do
        # 简化 Markdown 格式
        line=$(echo "$line" | sed 's/^### /  ▸ /; s/^## /▸ /; s/^\* /  • /; s/^- /  • /')
        echo "$line" >&2
    done
    _line
}

# 架构映射 (减少重复代码)
# 用法: local mapped=$(_map_arch "amd64:arm64:armv7")
_map_arch() {
    local mapping="$1" arch=$(uname -m)
    local x86 arm64 arm7
    IFS=':' read -r x86 arm64 arm7 <<< "$mapping"
    case $arch in
        x86_64)  echo "$x86" ;;
        aarch64) echo "$arm64" ;;
        armv7l)  echo "$arm7" ;;
        *) return 1 ;;
    esac
}

_sha256_file() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        openssl dgst -sha256 "$file" 2>/dev/null | awk '{print $NF}'
    fi
}

# Snell 官方下载站只发布固定 ZIP，没有提供对应的 .sha256 旁车文件。
# 对脚本支持的固定版本按版本和架构内置校验值，避免把旁车 404 误判为
# ZIP 下载失败，同时继续拒绝任何内容不匹配的安装包。
_snell_release_sha256() {
    local version="$1" arch="$2" pinned="" asset_name="" digest=""
    case "${version}:${arch}" in
        6.0.0b4:amd64)  pinned="d66891cffc9f1b24a7b959ffbd2c4a246013f4f9e612733027b5ad106ce5f87f" ;;
        6.0.0b4:aarch64) pinned="2c957ee6bb37ce4b1df2b6a23e652b75546d10bc4f0443a2928e5834ae0429af" ;;
        6.0.0rc:amd64)  pinned="21c4aa6b4a208236f33e9923603acd8a26534a02104aed40496ddf77949dfb4b" ;;
        6.0.0rc:aarch64) pinned="2b47d111d648648cf6845886433a7a93404ffe8d68a8e447058de6f7eca0d1a7" ;;
        6.0.0rc2:amd64)  pinned="8a9c4463ca87cfa5eaa37c6af0d37ab93ea275aa12391985bb2a375ca3abd7f2" ;;
        6.0.0rc2:aarch64) pinned="a0b2915cbc77dc3baf8fa069e741c20808d8a10c3a8a93e709a0a580645c3bd7" ;;
        6.0.0:amd64)  pinned="8a9c4463ca87cfa5eaa37c6af0d37ab93ea275aa12391985bb2a375ca3abd7f2" ;;
        6.0.0:aarch64) pinned="a0b2915cbc77dc3baf8fa069e741c20808d8a10c3a8a93e709a0a580645c3bd7" ;;
    esac

    if [[ -n "$pinned" ]]; then
        echo "$pinned"
        return 0
    fi

    # Snell v6 后续版本优先使用官方 GitHub Release 的资产摘要，避免每次发布都
    # 因缺少内置哈希而无法安装。下载站文件必须与同名 GitHub 资产完全一致。
    [[ "$version" =~ ^6\.[0-9]+\.[0-9]+([A-Za-z][A-Za-z0-9._-]*)?$ ]] || return 1
    [[ "$arch" == "amd64" || "$arch" == "aarch64" ]] || return 1
    asset_name="snell-server-v${version}-linux-${arch}.zip"
    digest=$(curl -fsSL --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/${SNELL_V6_REPO}/releases/tags/v${version}" 2>/dev/null |
        jq -r --arg name "$asset_name" '.assets[]? | select(.name == $name) | .digest // empty' 2>/dev/null |
        head -n 1)
    digest="${digest#sha256:}"
    [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    echo "$digest" | tr '[:upper:]' '[:lower:]'
}

# GitHub 的旧 Release 资产可能没有 digest 字段，发布页也未必提供 checksum
# 文件。仅为已经核对过的固定资产提供内置校验值；未知资产仍必须由
# GitHub digest/checksum 验证，否则拒绝安装。
_pinned_github_asset_sha256() {
    local repo="$1" version="$2" asset_name="$3"
    case "${repo}:${version}:${asset_name}" in
        ihciah/shadow-tls:0.2.25:shadow-tls-x86_64-unknown-linux-musl)
            echo "a173f5f2d57f45211b68e10ceeddc15b1791077b914fa89747bc705fddc71532"
            ;;
        ihciah/shadow-tls:0.2.25:shadow-tls-aarch64-unknown-linux-musl)
            echo "3295476b37f549a68906519d3eaecb74bf3b6eaf9094cebb16ee84f0151373c6"
            ;;
        ihciah/shadow-tls:0.2.25:shadow-tls-armv7-unknown-linux-musleabihf)
            echo "e6f918a072557c50fd0ea950af9a156a9b102af72c1d010ff85d08d13006c54f"
            ;;
        *) return 1 ;;
    esac
}

# 使用 GitHub Release API 提供的 digest；旧发布缺少 digest 时尝试其 checksum 资产。
_verify_github_release_asset() {
    local repo="$1" version="$2" asset_url="$3" file="$4"
    local asset_name="${asset_url%%\?*}"
    asset_name="${asset_name##*/}"
    local release_json digest expected actual checksum_url checksum_file

    # 固定资产不依赖 GitHub API 是否返回 digest，也避免 API 限流导致误报。
    expected=$(_pinned_github_asset_sha256 "$repo" "$version" "$asset_name" 2>/dev/null || true)

    if [[ -z "$expected" ]]; then
        release_json=$(curl -fsSL --connect-timeout 10 --max-time 30 \
            "https://api.github.com/repos/${repo}/releases/tags/v${version}" 2>/dev/null) ||
        release_json=$(curl -fsSL --connect-timeout 10 --max-time 30 \
            "https://api.github.com/repos/${repo}/releases/tags/${version}" 2>/dev/null) || return 1

        digest=$(printf '%s' "$release_json" | jq -r --arg n "$asset_name" \
            '[.assets[]? | select(.name == $n) | .digest // empty][0] // empty' 2>/dev/null)
        if [[ "$digest" == sha256:* ]]; then
            expected="${digest#sha256:}"
        else
            checksum_url=$(printf '%s' "$release_json" | jq -r '
                [.assets[]? | select(.name | test("sha256|checksums?"; "i")) | .browser_download_url][0] // empty
            ' 2>/dev/null)
            [[ -n "$checksum_url" ]] || return 1
            checksum_file=$(mktemp "${TMPDIR:-/tmp}/vless-checksum.XXXXXX") || return 1
            if ! curl -fsSL --connect-timeout 10 --max-time 30 -o "$checksum_file" "$checksum_url"; then
                rm -f "$checksum_file"
                return 1
            fi
            expected=$(awk -v name="$asset_name" '
                index($0, name) {
                    for (i=1; i<=NF; i++) if ($i ~ /^[0-9a-fA-F]{64}$/) { print tolower($i); exit }
                }
            ' "$checksum_file")
            rm -f "$checksum_file"
        fi
    fi

    actual=$(_sha256_file "$file")
    actual=$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')
    expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
    [[ -n "$expected" && -n "$actual" && "$actual" == "$expected" ]]
}

_verify_direct_download() {
    local file="$1" url="$2" expected="${3:-}" checksum_file actual
    if [[ -z "$expected" ]]; then
        checksum_file=$(mktemp "${TMPDIR:-/tmp}/vless-direct-checksum.XXXXXX") || return 1
        if curl -fsSL --connect-timeout 10 --max-time 30 -o "$checksum_file" "${url}.sha256" 2>/dev/null; then
            expected=$(grep -Eo '[0-9a-fA-F]{64}' "$checksum_file" | head -1)
        fi
        rm -f "$checksum_file"
    fi
    if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
        [[ "${ALLOW_UNVERIFIED_DOWNLOADS:-0}" == "1" ]] && return 0
        return 1
    fi
    actual=$(_sha256_file "$file")
    actual=$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')
    expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
    [[ -n "$actual" && "$actual" == "$expected" ]]
}

# 拒绝绝对路径和 .. 路径，避免压缩包在临时目录之外写文件。
_archive_paths_safe() {
    local file="$1" kind="$2" entries entry
    case "$kind" in
        zip) entries=$(unzip -Z1 "$file" 2>/dev/null) || return 1 ;;
        tar.gz) entries=$(tar -tzf "$file" 2>/dev/null) || return 1 ;;
        tar.xz) entries=$(tar -tJf "$file" 2>/dev/null) || return 1 ;;
        *) return 1 ;;
    esac
    while IFS= read -r entry; do
        case "$entry" in
            /*|../*|*/../*|*/..) return 1 ;;
        esac
    done <<<"$entries"
}

# 通用二进制下载安装函数
_install_binary() {
    local name="$1" repo="$2" url_pattern="$3" install_kind="$4"
    local channel="${5:-stable}" force="${6:-false}" version="${7:-}" target tmp url binary
    [[ "$name" == sing-box && "$repo" == SagerNet/sing-box && "$install_kind" == singbox ]] || return 1
    target=$(_core_binary_path sing-box) || return 1
    mkdir -p "$CFG/bin" || return 1
    [[ -x "$target" && "$force" != true ]] && return 0
    [[ -n "$version" ]] || version=$(_get_singbox_target_version "$channel") || return 1
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.-]+)?$ ]] || return 1
    if [[ -n "$(get_singbox_snell_protocols)" ]] && ! _singbox_supports_snell_version "$version"; then
        _err "Snell v5/v6 需要 Sing-box ${SINGBOX_SNELL_MIN_VERSION}+"
        return 1
    fi
    tmp=$(mktemp -d) || return 1
    url="${url_pattern//\$version/$version}"
    url="${url//\$\{sarch\}/$sarch}"
    if ! curl -fsSL --connect-timeout 20 --max-time 180 --retry 2 -o "$tmp/pkg" -- "$url" ||
       ! _verify_github_release_asset "$repo" "$version" "$url" "$tmp/pkg" ||
       ! _archive_paths_safe "$tmp/pkg" tar.gz || ! tar -xzf "$tmp/pkg" -C "$tmp"; then
        rm -rf "$tmp"
        _err "Sing-box 下载或 SHA-256 校验失败"
        return 1
    fi
    binary=$(find "$tmp" -name sing-box -type f -print -quit)
    if [[ -z "$binary" ]] || ! _install_checked_singbox_binary "$binary"; then
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"
    _ok "Sing-box v$version 已安装"
}

_replace_singbox_binary() {
    local source="$1" target="$2" staged
    mkdir -p "$(dirname "$target")" || return 1
    staged=$(mktemp "${target}.new.XXXXXX") || return 1
    if ! install -m 755 "$source" "$staged" || ! mv -f "$staged" "$target"; then
        rm -f "$staged"
        return 1
    fi
}

_install_checked_singbox_binary() {
    local binary="$1" candidate="" backup="" target
    local SINGBOX_CONFIG_BINARY="$binary"
    target=$(_core_binary_path sing-box) || return 1
    mkdir -p "$CFG/bin" || return 1
    mkdir -p "$CFG" || return 1
    chmod 755 "$binary" || return 1
    if [[ -n "$(get_singbox_protocols)" ]]; then
        candidate=$(mktemp "$CFG/.singbox-upgrade.XXXXXX") || return 1
        if ! generate_singbox_config "$candidate"; then rm -f "$candidate"; return 1; fi
    fi
    if [[ -f "$target" ]]; then
        backup=$(mktemp "$CFG/.singbox-binary.XXXXXX") || { rm -f "$candidate"; return 1; }
        cp -p "$target" "$backup" || { rm -f "$candidate" "$backup"; return 1; }
    fi
    if ! _replace_singbox_binary "$binary" "$target"; then
        rm -f "$candidate" "$backup"
        return 1
    fi
    if [[ -n "$candidate" ]] && ! mv "$candidate" "$CFG/singbox.json"; then
        if [[ -n "$backup" ]]; then
            _replace_singbox_binary "$backup" "$target" || { _err "核心恢复失败，备份: $backup"; return 1; }
        else
            rm -f "$target"
        fi
        rm -f "$candidate" "$backup"
        return 1
    fi
    rm -f "$backup"
}

install_singbox() {
    local channel="${1:-stable}" force="${2:-false}" version="${3:-}" sarch
    sarch=$(_map_arch "amd64:arm64:armv7") || return 1
    _install_binary sing-box SagerNet/sing-box \
        'https://github.com/SagerNet/sing-box/releases/download/v$version/sing-box-$version-linux-${sarch}.tar.gz' \
        singbox "$channel" "$force" "$version"
}

_singbox_supports_snell_version() {
    local version="${1#v}"
    [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)([-.][A-Za-z0-9.-]+)?$ ]] || return 1
    (( 10#${BASH_REMATCH[1]} > 1 || (10#${BASH_REMATCH[1]} == 1 && 10#${BASH_REMATCH[2]} > 14) )) && return 0
    (( 10#${BASH_REMATCH[1]} == 1 && 10#${BASH_REMATCH[2]} == 14 )) || return 1
    (( 10#${BASH_REMATCH[3]} > 0 )) || [[ -z "${BASH_REMATCH[4]}" ]]
}

ensure_singbox_snell_support() {
    local version
    version=$(_get_core_version sing-box)
    _singbox_supports_snell_version "$version" && return 0
    version=$(_get_singbox_target_version stable) || return 1
    _singbox_supports_snell_version "$version" || { _err "稳定版暂不支持 Snell v5/v6"; return 1; }
    _update_singbox_core_to_version stable "$version"
}

_save_snell_v6_installed_version() {
    local version="$1" tmp
    _is_snell_v6_version "$version" || return 1
    mkdir -p "$CFG" || return 1
    tmp=$(mktemp "$CFG/.snell-v6-version.XXXXXX") || return 1
    if printf '%s\n' "$version" >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$SNELL_V6_INSTALLED_VERSION_FILE"; then return 0; fi
    rm -f "$tmp"
    return 1
}

_snell_v6_base_version() { printf '%s\n' "$1" | sed -E 's/[A-Za-z][A-Za-z0-9._-]*$//'; }

_get_snell_v6_version() { _get_core_version snell-server-v6; }

_get_core_version() {
    local core="$1" binary output version saved major
    case "$core" in
        singbox|sing-box) core=sing-box ;;
        snell-server-v5|snell-v5-official|snellv5) core=snell-server-v5; major=5 ;;
        snell-server-v6|snell-v6|snellv6) core=snell-server-v6; major=6 ;;
        *) return 1 ;;
    esac
    binary=$(_core_binary_path "$core") || return 1
    [[ -x "$binary" ]] || { printf '未安装\n'; return; }
    if [[ "$core" == sing-box ]]; then
        output=$("$binary" version 2>/dev/null) || true
        version=$(awk 'NR == 1 {print $3}' <<<"$output")
    else
        output=$("$binary" --v 2>&1 || "$binary" --version 2>&1 || true)
        version=$(grep -oE "${major}\.[0-9]+\.[0-9]+([A-Za-z][A-Za-z0-9._-]*)?" <<<"$output" | head -n 1)
        saved=$(head -n 1 "$CFG/.snell-v${major}-installed-version" 2>/dev/null || true)
        if [[ "$saved" =~ ^${major}\.[0-9]+\.[0-9]+([A-Za-z][A-Za-z0-9._-]*)?$ &&
              ( "$version" == "$saved" || "$version" == "$(_snell_v6_base_version "$saved")" ) ]]; then version="$saved"; fi
    fi
    printf '%s\n' "${version:-未知}"
}

_get_core_version_with_status() { _get_core_version "$1"; }

_core_binary_path() {
    case "$1" in
        sing-box|snell-server-v5|snell-server-v6) printf '%s/bin/%s\n' "$CFG" "$1" ;;
        *) return 1 ;;
    esac
}

_get_singbox_target_version() {
    local version
    case "$1" in
        stable) version=$(_get_latest_version SagerNet/sing-box) || return 1 ;;
        prerelease|test|beta) version=$(_get_latest_prerelease_version SagerNet/sing-box) || return 1 ;;
        *) return 1 ;;
    esac
    version="${version#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.-]+)?$ ]] || { _err "查询失败"; return 1; }
    printf '%s\n' "$version"
}

_get_snell_v5_channel_version() {
    local channel="${1:-stable}" result version
    [[ "$channel" == stable || "$channel" == prerelease ]] || return 1
    result=$(curl -fsSL --connect-timeout 5 --max-time 20 \
        "https://api.github.com/repos/${SNELL_V6_REPO}/releases?per_page=${GITHUB_API_PER_PAGE}") || return 1
    version=$(jq -er --arg channel "$channel" '
        [.[] | select(.draft == false and (.tag_name | test("^v?5\\.")) and
        (.prerelease == ($channel == "prerelease")))][0].tag_name | select(type == "string")' <<<"$result") || return 1
    version="${version#v}"
    [[ "$version" =~ ^5\.[0-9]+\.[0-9]+([A-Za-z][A-Za-z0-9._-]*)?$ ]] || return 1
    printf '%s\n' "$version"
}

_core_target_version() {
    case "$1" in
        sing-box) _get_singbox_target_version "$2" ;;
        snell-server-v5) _get_snell_v5_channel_version "$2" ;;
        snell-server-v6) _get_snell_v6_channel_version "$2" ;;
        *) return 1 ;;
    esac
}

_show_core_versions() {
    local filter="${1:-all}" binary current stable test label
    for binary in sing-box snell-server-v5 snell-server-v6; do
        case "$binary" in
            sing-box) label=Sing-box; [[ "$filter" == all || "$filter" == singbox ]] || continue ;;
            snell-server-v5) label='官方 Snell v5'; [[ "$filter" == all || "$filter" == snellv5 ]] || continue ;;
            snell-server-v6) label='官方 Snell v6'; [[ "$filter" == all || "$filter" == snellv6 ]] || continue ;;
        esac
        current=$(_get_core_version "$binary")
        [[ "$current" != 未安装 ]] || continue
        stable=$(_core_target_version "$binary" stable 2>/dev/null) || stable=查询失败
        test=$(_core_target_version "$binary" prerelease 2>/dev/null) || test=查询失败
        printf '  %s 当前: %s  稳定: %s  测试: %s\n' "$label" "$current" "${stable:-查询失败}" "${test:-查询失败}"
    done
}

_wait_for_owned_service() {
    local service="$1" i pid
    for ((i=0; i<10; i++)); do
        sleep 1
        if [[ "$DISTRO" == alpine ]]; then
            pid=$(_runtime_config_service_pid "$service") || continue
            [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null && return 0
        elif systemctl is-active --quiet "$service"; then return 0; fi
    done
    return 1
}

_update_singbox_core_to_version() {
    local channel="$1" version="$2" install_func="${3:-install_singbox}"
    local snapshot binary had_binary=false was_running=false success=false installed=false
    if [[ -n "$(get_singbox_snell_protocols)" ]] && ! _singbox_supports_snell_version "$version"; then
        _err "Snell v5/v6 需要 Sing-box ${SINGBOX_SNELL_MIN_VERSION}+"; return 1
    fi
    mkdir -p "$CFG" || return 1
    binary=$(_core_binary_path sing-box) || return 1
    snapshot=$(mktemp -d "$CFG/.singbox-core.XXXXXX") || return 1
    if [[ -f "$binary" ]]; then
        cp -p "$binary" "$snapshot/binary" || { rmdir "$snapshot"; return 1; }
        had_binary=true
    fi
    if [[ -f "$CFG/singbox.json" ]] && ! cp -p "$CFG/singbox.json" "$snapshot/config"; then rm -rf "$snapshot"; return 1; fi
    svc status sing-singbox >/dev/null 2>&1 && was_running=true
    if "$install_func" "$channel" true "$version"; then
        installed=true
        if [[ "$was_running" != true ]] || { svc restart sing-singbox && _wait_for_singbox_ready; }; then success=true; fi
    fi
    if [[ "$success" == true ]]; then rm -rf "$snapshot"; _ok "Sing-box 已更新至 v$version"; return 0; fi
    if [[ "$installed" == false ]] &&
       { [[ "$had_binary" == true ]] && cmp -s "$snapshot/binary" "$binary" || [[ "$had_binary" == false && ! -e "$binary" ]]; } &&
       { [[ -f "$snapshot/config" ]] && cmp -s "$snapshot/config" "$CFG/singbox.json" || [[ ! -f "$snapshot/config" && ! -e "$CFG/singbox.json" ]]; }; then
        rm -rf "$snapshot"; _err "更新失败，原核心与配置未变化"; return 1
    fi
    if [[ "$was_running" == true ]] && ! svc stop sing-singbox; then _err "停止失败，快照保留: $snapshot"; return 1; fi
    if [[ "$had_binary" == true ]]; then
        _replace_singbox_binary "$snapshot/binary" "$binary" || { _err "回滚失败，快照保留: $snapshot"; return 1; }
    else rm -f "$binary" || return 1; fi
    if [[ -f "$snapshot/config" ]]; then
        cp -p "$snapshot/config" "$CFG/singbox.json" || { _err "配置恢复失败: $snapshot"; return 1; }
    else rm -f "$CFG/singbox.json" || return 1; fi
    if [[ "$was_running" == true ]] && ! { svc start sing-singbox && _wait_for_singbox_ready; }; then
        _err "服务恢复失败，快照保留: $snapshot"; return 1
    fi
    rm -rf "$snapshot"
    _err "更新失败，已恢复原核心与配置"
    return 1
}

_update_official_snell_core() {
    local major="$1" version="$2" binary service snapshot was_running=false target metadata
    case "$major" in
        5) binary=snell-server-v5; service=sing-snell-v5-official ;;
        6) binary=snell-server-v6; service=sing-snell-v6 ;;
        *) return 1 ;;
    esac
    target=$(_core_binary_path "$binary") || return 1
    mkdir -p "$CFG/bin" || return 1
    [[ -x "$target" ]] || { _err "核心尚未安装"; return 1; }
    metadata="$CFG/.snell-v${major}-installed-version"
    snapshot=$(mktemp -d "$CFG/.snell-core.XXXXXX") || return 1
    cp -p "$target" "$snapshot/binary" || { rm -rf "$snapshot"; return 1; }
    if [[ -f "$metadata" ]] && ! cp -p "$metadata" "$snapshot/version"; then rm -rf "$snapshot"; return 1; fi
    svc status "$service" >/dev/null 2>&1 && was_running=true
    if "install_snell_v${major}" "$version"; then
        if [[ "$was_running" != true ]] || { svc restart "$service" && _wait_for_owned_service "$service"; }; then
            rm -rf "$snapshot"; _ok "Snell v$major 已更新至 $version"; return 0
        fi
    fi
    if [[ "$was_running" == true ]] && ! svc stop "$service"; then _err "停止失败，快照保留: $snapshot"; return 1; fi
    _replace_singbox_binary "$snapshot/binary" "$target" || { _err "回滚失败，快照保留: $snapshot"; return 1; }
    if [[ -f "$snapshot/version" ]]; then cp -p "$snapshot/version" "$metadata" || return 1; else rm -f "$metadata" || return 1; fi
    if [[ "$was_running" == true ]] && ! { svc start "$service" && _wait_for_owned_service "$service"; }; then
        _err "服务恢复失败，快照保留: $snapshot"; return 1
    fi
    rm -rf "$snapshot"
    _err "更新失败，已回滚"
    return 1
}

update_singbox_core() {
    local version
    version=$(_get_singbox_target_version "${1:-stable}") || return 1
    _update_singbox_core_to_version "${1:-stable}" "$version"
}
update_snell_v5_core() {
    local version="${1:-}"
    [[ -n "$version" ]] || version=$(_get_snell_v5_channel_version stable) || return 1
    _update_official_snell_core 5 "$version"
}
update_snell_v6_core() {
    local version="${1:-}"
    [[ -n "$version" ]] || version=$(_get_snell_v6_channel_version stable) || return 1
    _update_official_snell_core 6 "$version"
}

_update_core_with_channel_select() {
    local name="$1" repo="$2" binary="$3" service="$4" installer="$5" choice channel version current
    current=$(_get_core_version "$binary") || return 1
    [[ "$current" != 未安装 ]] || { _err "核心尚未安装"; return 1; }
    _item 1 '当前稳定版'
    _item 2 '当前测试版'
    _item 0 '返回'
    read -rp '  请选择: ' choice || return 1
    case "$choice" in 1) channel=stable ;; 2) channel=prerelease ;; 0) return 0 ;; *) return 1 ;; esac
    version=$(_core_target_version "$binary" "$channel") || { _err "查询失败"; return 1; }
    [[ -n "$version" ]] || { _err "查询失败"; return 1; }
    _info "更新 $name: $current → $version"
    case "$binary" in
        sing-box) _update_singbox_core_to_version "$channel" "$version" ;;
        snell-server-v5) _update_official_snell_core 5 "$version" ;;
        snell-server-v6) _update_official_snell_core 6 "$version" ;;
        *) return 1 ;;
    esac
}

update_core_menu() {
    local choice binary i current
    local -a installed=()
    while true; do
        _header
        printf '  核心版本管理\n'
        _show_core_versions
        installed=(); i=1
        for binary in sing-box snell-server-v5 snell-server-v6; do
            current=$(_get_core_version "$binary")
            [[ "$current" != 未安装 ]] || continue
            installed+=("$binary")
            _item "$i" "更新 $binary"
            i=$((i+1))
        done
        _item 0 返回
        read -rp '  请选择: ' choice || return
        [[ "$choice" != 0 ]] || return
        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && ((choice <= ${#installed[@]})); then
            binary="${installed[choice-1]}"
            _update_core_with_channel_select "$binary" '' "$binary" '' ''
        else _err '无效选择'; fi
        _pause
    done
}

_singbox_ruleset_path() {
    local tag="$1"
    echo "$CFG/ruleset/${tag}.srs"
}

_singbox_ruleset_source_path() {
    local tag="$1"
    echo "$CFG/ruleset-src/${tag}.json"
}

# Public Sukka catalog: only published phases are eligible for downloading.
_singbox_sukka_catalog() {
    cat <<'CATALOG'
domainset apple_cdn cdn download game-download icloud_private_relay reject reject_extra reject_phishing speedtest
non-ip ai apple_cdn apple_cn apple_intelligence apple_services cdn cloudmounter direct domestic domestic_cdn download gitlab global lan microsoft microsoft_cdn my_direct my_git my_plus my_proxy my_reject my_tw my_us neteasemusic reject-drop reject-no-drop reject-url-regex reject sogouinput stream stream_biliintl stream_eu stream_hk stream_jp stream_kr stream_tw stream_us telegram
ip ai apple_services cdn china_ip china_ip_ipv6 domestic download lan neteasemusic reject stream stream_biliintl stream_eu stream_hk stream_jp stream_kr stream_tw stream_us telegram telegram_asn teleproto
CATALOG
}

# Exact repository, branch and path allowlist for Yuu site and IP files.
_singbox_ruleset_source_url() {
    case "$1" in
        yuu-non-ip-youtube) echo https://raw.githubusercontent.com/Yuu518/sing-box-rules/rule_set/rule_set_site/youtube.json ;;
        yuu-non-ip-google) echo https://raw.githubusercontent.com/Yuu518/sing-box-rules/rule_set/rule_set_site/google.json ;;
        yuu-non-ip-twitter) echo https://raw.githubusercontent.com/Yuu518/sing-box-rules/rule_set/rule_set_site/twitter.json ;;
        yuu-ip-twitter) echo https://raw.githubusercontent.com/Yuu518/sing-box-rules/rule_set/rule_set_ip/twitter.json ;;
        *) local source
           source=$(_singbox_sukka_tag_source "$1") || return 1
           printf 'https://ruleset.skk.moe/sing-box/%s.json\n' "$source" ;;
    esac
}

_singbox_sukka_normalize_tag() {
    case "$1" in
        skk-ai-non-ip) echo skk-non-ip-ai ;;
        skk-ai-ip) echo skk-ip-ai ;;
        *) printf '%s\n' "$1" ;;
    esac
}

_singbox_sukka_tag_source() {
    local tag phase name line
    tag=$(_singbox_sukka_normalize_tag "$1")
    case "$tag" in
        *)
            while read -r phase line; do
                [[ "$tag" == "skk-$phase-"* ]] || continue
                name="${tag#skk-$phase-}"
                case " $line " in *" $name "*) printf '%s/%s\n' "${phase//-/_}" "$name"; return 0 ;; esac
            done < <(_singbox_sukka_catalog)
            _err "不支持的 Sukka 规则集: $tag" >&2; return 1 ;;
    esac
}

_singbox_sukka_tags_for_token() {
    local token="$1" name phase names tag
    case "$token" in
        rule-set:*|ruleset:*)
            tag=$(_singbox_sukka_normalize_tag "${token#*:}")
            _singbox_ruleset_source_url "$tag" >/dev/null || return 1
            echo "$tag"; return ;;
        skk-*|yuu-*) _singbox_sukka_tags_for_token "rule-set:$token"; return ;;
        geosite:*)
            name="${token#*:}"
            case "$name" in
                cn) name=domestic ;;
                tracker|public-tracker|private-tracker|category-public-tracker|category-pt) _err "Sukka 没有等价的独立 BT/PT 规则: $token" >&2; return 1 ;;
                category-ads-all|ads) name=reject ;;
                youtube|google|twitter) echo "yuu-non-ip-$name"; return ;;
                telegram|ai) ;;
                *) _err "无 Sukka 映射的旧规则: $token" >&2; return 1 ;;
            esac
            while read -r phase names; do
                [[ "$phase" != ip ]] || continue
                case " $names " in *" $name "*) echo "skk-$phase-$name" ;; esac
            done < <(_singbox_sukka_catalog) ;;
        geoip:*)
            case "${token#*:}" in
                cn) printf '%s\n' skk-ip-china_ip skk-ip-china_ip_ipv6 ;;
                telegram|ai) echo "skk-ip-${token#*:}" ;;
                twitter) echo yuu-ip-twitter ;;
                *) _err "无 Sukka 映射的旧规则: $token" >&2; return 1 ;;
            esac ;;
        *) _err "不支持的规则标记: $token" >&2; return 1 ;;
    esac
}

_singbox_sukka_preset_tokens() {
    local name="$1"
    case "$name" in
        singbox-ai) echo 'rule-set:skk-non-ip-ai,rule-set:skk-ip-ai' ;;
        stream) echo 'rule-set:skk-non-ip-stream,rule-set:skk-ip-stream' ;;
        stream-jp) echo 'rule-set:skk-non-ip-stream_jp,rule-set:skk-ip-stream_jp' ;;
        youtube|google) echo "rule-set:yuu-non-ip-$name" ;;
        twitter) echo 'rule-set:yuu-non-ip-twitter,rule-set:yuu-ip-twitter' ;;
        *) [[ -n "${ROUTING_PRESETS[$name]:-}" ]] || return 1
           printf '%s\n' "${ROUTING_PRESETS[$name]}" ;;
    esac
}

_singbox_sukka_ai_cache_valid() {
    local path
    path=$(_singbox_ruleset_path "$1")
    [[ -s "$path" ]] && "${SINGBOX_CONFIG_BINARY:-sing-box}" rule-set decompile "$path" -o /dev/null >/dev/null 2>&1
}

# Atomic downloads from the exact Sukka/Yuu allowlists; retain valid caches.
_build_singbox_sukka_ruleset() (
    local tag="$1" sources source_path output_path tmp_source tmp_output status
    sources=$(_singbox_ruleset_source_url "$tag") || return 1
    source_path=$(_singbox_ruleset_source_path "$tag")
    output_path=$(_singbox_ruleset_path "$tag")
    mkdir -p "$CFG/ruleset" "$CFG/ruleset-src" || return 1
    tmp_source=$(mktemp "$CFG/ruleset-src/.${tag}.XXXXXX") || return 1
    tmp_output=''
    trap 'rm -f "$tmp_source" "$tmp_output"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    tmp_output=$(mktemp "$CFG/ruleset/.${tag}.XXXXXX") || return 1
    python3 - "$tmp_source" "$(_singbox_sukka_normalize_tag "$tag")" "$sources" <<'PY'
import json, subprocess, sys
from pathlib import Path
try:
    url = sys.argv[3]
    print('  ▸ 下载规则源: ' + url, file=sys.stderr)
    result = subprocess.run(['curl', '-fsSL', '--connect-timeout', '10', '--max-time', '45', url], capture_output=True, timeout=50, check=True)
    doc = json.loads(result.stdout)
    if not isinstance(doc, dict) or not isinstance(doc.get('version'), int) or not isinstance(doc.get('rules'), list) or not doc['rules']:
        raise ValueError('无效或空的规则集')
    # Fail explicitly if the selected native Yuu files change matching phase.
    if sys.argv[2].startswith('yuu-'):
        expected = {'ip_cidr'} if sys.argv[2].startswith('yuu-ip-') else {'domain', 'domain_suffix', 'domain_keyword', 'domain_regex'}
        if any(not isinstance(r, dict) or not r or set(r) - expected for r in doc['rules']):
            raise ValueError('Yuu 规则的匹配阶段发生变化')
    Path(sys.argv[1]).write_text(json.dumps(doc, ensure_ascii=False))
except (ValueError, OSError, subprocess.SubprocessError) as exc:
    print('  ✗ 规则生成失败: ' + str(exc), file=sys.stderr)
    sys.exit(1)
PY
    status=$?
    if [[ "$status" == 0 ]] &&
        "${SINGBOX_CONFIG_BINARY:-sing-box}" rule-set compile "$tmp_source" -o "$tmp_output" >/dev/null 2>&1 && [[ -s "$tmp_output" ]]; then
        chmod 600 "$tmp_source" "$tmp_output" || return 1
        mv -f "$tmp_source" "$source_path" && mv -f "$tmp_output" "$output_path"
        return $?
    fi
    if _singbox_sukka_ai_cache_valid "$tag" && [[ -s "$source_path" ]]; then
        _warn "更新规则集失败，继续使用有效缓存: $tag" >&2
        return 0
    fi
    return 1
)

_build_singbox_sukka_ai_ruleset() { _build_singbox_sukka_ruleset "$1"; }
_build_singbox_geo_ruleset() {
    local token tags tag
    case "$1" in
        geosite-*) token="geosite:${1#geosite-}" ;;
        geoip-*) token="geoip:${1#geoip-}" ;;
        *) return 1 ;;
    esac
    tags=$(_singbox_sukka_tags_for_token "$token") || return 1
    while IFS= read -r tag; do
        _build_singbox_sukka_ruleset "$tag" || return 1
    done <<<"$tags"
}
_build_singbox_geosite_ruleset() { _build_singbox_geo_ruleset "$1"; }
_build_singbox_geoip_ruleset() { _build_singbox_geo_ruleset "$1"; }
_build_singbox_ruleset() {
    case "$1" in
        geosite-*|geoip-*) _build_singbox_geo_ruleset "$1" ;;
        *) _build_singbox_sukka_ruleset "$1" ;;
    esac
}

_list_missing_singbox_rulesets_from_routing_rules() {
    local tag
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        _singbox_ruleset_source_url "$tag" >/dev/null || return 1
        [[ -s "$(_singbox_ruleset_path "$tag")" ]] || echo "$tag"
    done < <(jq -r '.. | objects | .rule_set? // empty | .[]' <<<"${1:-[]}" | sort -u)
}

_ensure_singbox_rulesets_from_routing_rules() {
    local tag source_path path
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        _singbox_ruleset_source_url "$tag" >/dev/null || return 1
        path=$(_singbox_ruleset_path "$tag")
        source_path=$(_singbox_ruleset_source_path "$tag")
        if ! _singbox_sukka_ai_cache_valid "$tag" || ! python3 - "$source_path" "$path" <<'PY'
import os, sys, time
try:
    fresh = all(time.time() - os.path.getmtime(p) < 86400 for p in sys.argv[1:])
except OSError:
    fresh = False
sys.exit(0 if fresh else 1)
PY
        then
            _build_singbox_ruleset "$tag" || { _err "生成规则集失败: $tag"; return 1; }
        fi
    done < <(jq -r '.. | objects | .rule_set? // empty | .[]' <<<"${1:-[]}" | sort -u)
}

_build_singbox_ruleset_defs() {
    local tag path defs='[]'
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        _singbox_ruleset_source_url "$tag" >/dev/null || return 1
        path=$(_singbox_ruleset_path "$tag")
        defs=$(jq --arg tag "$tag" --arg path "$path" '. + [{type:"local",tag:$tag,format:"binary",path:$path}]' <<<"$defs") || return 1
    done < <(jq -r '.. | objects | .rule_set? // empty | .[]' <<<"${1:-[]}" | sort -u)
    echo "$defs"
}

# 校验共享 Snell 入站的版本、凭据与模式。
_validate_singbox_snell_record() {
    local protocol="${2:-snell-v5}"
    if [[ "$protocol" == snell-v6-singbox ]]; then
        jq -e 'type == "object" and .version == 6 and
            (.port | type == "number" and . == floor and . >= 1 and . <= 65535) and
            (.psk | type == "string" and length >= 12 and length <= 255 and
                (explode | all(.[]; . != 0 and . != 10 and . != 13))) and
            ((.mode // "default") | . == "default" or . == "unshaped" or . == "unsafe-raw")
        ' <<<"$1" >/dev/null
        return $?
    fi
    [[ "$protocol" == snell-v5 ]] || return 1
    jq -e 'type == "object" and .version == 5 and
        (.port | type == "number" and . == floor and . >= 1 and . <= 65535) and
        (.psk | type == "string" and length > 0 and (explode | all(.[]; . != 0 and . != 10 and . != 13)))
    ' <<<"$1" >/dev/null
}


get_singbox_snell_protocols() {
    local protocol
    for protocol in snell-v5 snell-v6-singbox; do
        db_exists singbox "$protocol" && printf '%s\n' "$protocol"
    done
    return 0
}

is_singbox_snell_protocol() {
    [[ "$1" == snell-v5 || "$1" == snell-v6-singbox ]]
}

# 生成 Sing-box 统一配置；可写入候选文件，校验成功前不覆盖运行配置。
_lite_singbox_inbounds() {
    local proto="$1" cfg="$2" listen="$3" cert="$CFG/certs/server.crt" key="$CFG/certs/server.key"
    case "$proto" in
        hy2|tuic)
            if [[ -f "$CFG/certs/$proto/server.crt" ]]; then
                cert="$CFG/certs/$proto/server.crt"; key="$CFG/certs/$proto/server.key"
            fi ;;
        vless-singbox|ss2022|ss-legacy|ss2022-shadowtls|socks|anytls|naive|snell-v5|snell-v6-singbox) ;;
        *) _err "不支持的 Sing-box 服务端协议: $proto"; return 1 ;;
    esac
    jq -e 'type == "object" and (.port | type == "number" and . == floor and . >= 1 and . <= 65535)' <<<"$cfg" >/dev/null || return 1
    if is_singbox_snell_protocol "$proto"; then
        _validate_singbox_snell_record "$cfg" "$proto" || return 1
    elif [[ "$proto" == socks ]]; then
        jq -e '.tls != true and .tls != "true"' <<<"$cfg" >/dev/null || {
            _err "SOCKS5 仅支持明文"; return 1;
        }
    fi
    jq -c --arg p "$proto" --arg listen "$listen" --arg cert "$cert" --arg key "$key" '
        . as $c |
        ($p + "-in-" + (.port | tostring)) as $tag |
        {tag:$tag,listen:(.listen_addr | select(. != "") // $listen),listen_port:.port} as $base |
        {enabled:true,server_name:(.sni // .domain // ""),certificate_path:$cert,key_path:$key} as $tls |
        (if has("users") then (.users // []) else
            [{name:"default",uuid:(.uuid // .password),password:.password,username:.username}] end |
            map(select(.enabled != false))) as $users |
        if $p == "vless-singbox" then
            $base + {type:"vless", users:[$users[] | {name:($p+"-"+.name),uuid:.uuid,flow:"xtls-rprx-vision"}],
                tls:{enabled:true,server_name:$c.sni,reality:{enabled:true,
                handshake:{server:($c.reality_server // $c.sni),server_port:($c.reality_port // 443)},
                private_key:$c.private_key,short_id:[$c.short_id]}}}
        elif $p == "hy2" or $p == "anytls" then
            $base + {type:(if $p == "hy2" then "hysteria2" else "anytls" end),tls:$tls,
                users:[$users[] | {name:($p+"-"+.name),password:(.uuid // .password)}]} +
                (if $p == "hy2" then {ignore_client_bandwidth:true} else {} end)
        elif $p == "tuic" then
            $base + {type:"tuic",tls:($tls + {alpn:["h3"]}),congestion_control:"bbr",
                users:[$users[] | {name:($p+"-"+.name),uuid:.uuid,password:(.password // $c.password)}]}
        elif $p == "socks" then
            if $c.auth_mode != "noauth" and ($users | length) == 0 then error("no enabled SOCKS users") else . end |
            $base + {type:"socks",users:(if $c.auth_mode == "noauth" then [] else
                [$users[] | {username:(.username // .name),password:(.password // .uuid)}] end)}
        elif $p == "naive" then
            $base + {type:"naive",tls:$tls,users:[$users[] | {username:(.username // .name),password:(.password // .uuid)}]}
        elif $p == "snell-v5" then $base + {type:"snell",tag:("snell-snell-v5-"+($c.port|tostring)),version:5,psk:$c.psk}
        elif $p == "snell-v6-singbox" then
            $base + {type:"snell",tag:("snell-snell-v6-singbox-"+($c.port|tostring)),version:6,psk:$c.psk,mode:($c.mode // "default")}
        elif $p == "ss2022" or $p == "ss-legacy" or $p == "ss2022-shadowtls" then
            (if $c | has("users") then
                if ($users | length) == 0 then error("no enabled Shadowsocks users")
                elif $c.method == "2022-blake3-aes-128-gcm" or $c.method == "2022-blake3-aes-256-gcm" then
                    {users:[$users[] | {name:($p+"-"+.name),password:(.uuid // .password)}],password:$c.password}
                elif ($users | length) == 1 then {password:($users[0].uuid // $users[0].password)}
                else error("cipher supports only one active user") end
            else {password:$c.password} end) as $auth |
            $base + {type:"shadowsocks",method:$c.method} + $auth |
            if $p == "ss2022-shadowtls" then
                (. + {listen:"127.0.0.1",listen_port:0}) as $ss |
                [$ss,($base + {type:"shadowtls",tag:($tag+"-tls"),version:3,
                    users:[{password:$c.stls_password}],handshake:{server:$c.sni,server_port:443},detour:$tag})]
            else . end
        else error("unsupported protocol") end |
        if type == "array" then . else [.] end
    ' <<<"$cfg"
}


generate_singbox_config() {
    local output_file="${1:-$CFG/singbox.json}"
    local db_file="${2:-$DB_FILE}"
    local config_binary
    config_binary=$(_lite_singbox_binary) || return 1
    local SINGBOX_CONFIG_BINARY="$config_binary"
    local singbox_protocols
    singbox_protocols=$(jq -r '(.singbox // {}) | keys[]' "$db_file") || return 1
    [[ -z "$singbox_protocols" ]] && return 1

    mkdir -p "$CFG"

    # 读取直连出口 IP 版本设置（默认 AsIs）
    local direct_ip_version="as_is"
    [[ -f "$CFG/direct_ip_version" ]] && direct_ip_version=$(cat "$CFG/direct_ip_version")

    # 监听地址：IPv6 双栈不可用时退回 IPv4
    local listen_addr=$(_listen_addr)

    # 根据设置生成 direct 出口配置
    local direct_outbound=""
    case "$direct_ip_version" in
        ipv4|ipv4_only)
            direct_outbound=$(jq -n '{
                type: "direct",
                tag: "direct",
                domain_strategy: "ipv4_only"
            }')
            ;;
        ipv6|ipv6_only)
            direct_outbound=$(jq -n '{
                type: "direct",
                tag: "direct",
                domain_strategy: "ipv6_only"
            }')
            ;;
        prefer_ipv4)
            direct_outbound=$(jq -n '{
                type: "direct",
                tag: "direct",
                domain_strategy: "prefer_ipv4"
            }')
            ;;
        prefer_ipv6)
            direct_outbound=$(jq -n '{
                type: "direct",
                tag: "direct",
                domain_strategy: "prefer_ipv6"
            }')
            ;;
        as_is|asis|*)
            direct_outbound=$(jq -n '{
                type: "direct",
                tag: "direct"
            }')
            ;;
    esac

    # 收集所有需要的出口
    local outbounds=$(jq -n --argjson direct "$direct_outbound" '[$direct, {type: "block", tag: "block"}]')
    local routing_rules=""
    local singbox_ruleset_defs="[]"
    local has_routing=false
    local warp_has_endpoint=false
    local warp_endpoint_data=""

    # 获取此内核适用的分流规则
    local rules=$(db_get_routing_rules singbox "$db_file")

    if [[ -n "$rules" && "$rules" != "[]" ]]; then
        # 收集所有用到的出口 (支持多出口)

        while IFS= read -r rule_json; do
            [[ -z "$rule_json" ]] && continue
            local outbound=$(echo "$rule_json" | jq -r '.outbound')
            local ip_version=$(echo "$rule_json" | jq -r '.ip_version // "prefer_ipv4"')

            if [[ "$outbound" == "direct" ]]; then
                case "$ip_version" in
                    ipv4_only)
                        if ! echo "$outbounds" | jq -e --arg tag "direct-ipv4" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                            local direct_ipv4_out=$(jq -n '{
                                type: "direct",
                                tag: "direct-ipv4",
                                domain_strategy: "ipv4_only"
                            }')
                            outbounds=$(echo "$outbounds" | jq --argjson out "$direct_ipv4_out" '. + [$out]')
                        fi
                        ;;
                    ipv6_only)
                        if ! echo "$outbounds" | jq -e --arg tag "direct-ipv6" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                            local direct_ipv6_out=$(jq -n '{
                                type: "direct",
                                tag: "direct-ipv6",
                                domain_strategy: "ipv6_only"
                            }')
                            outbounds=$(echo "$outbounds" | jq --argjson out "$direct_ipv6_out" '. + [$out]')
                        fi
                        ;;
                    prefer_ipv6)
                        if ! echo "$outbounds" | jq -e --arg tag "direct-prefer-ipv6" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                            local direct_prefer_ipv6_out=$(jq -n '{
                                type: "direct",
                                tag: "direct-prefer-ipv6",
                                domain_strategy: "prefer_ipv6"
                            }')
                            outbounds=$(echo "$outbounds" | jq --argjson out "$direct_prefer_ipv6_out" '. + [$out]')
                        fi
                        ;;
                    as_is|asis)
                        if ! echo "$outbounds" | jq -e --arg tag "direct-asis" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                            local direct_asis_out=$(jq -n '{
                                type: "direct",
                                tag: "direct-asis"
                            }')
                            outbounds=$(echo "$outbounds" | jq --argjson out "$direct_asis_out" '. + [$out]')
                        fi
                        ;;
                    prefer_ipv4|*)
                        if ! echo "$outbounds" | jq -e --arg tag "direct-prefer-ipv4" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                            local direct_prefer_ipv4_out=$(jq -n '{
                                type: "direct",
                                tag: "direct-prefer-ipv4",
                                domain_strategy: "prefer_ipv4"
                            }')
                            outbounds=$(echo "$outbounds" | jq --argjson out "$direct_prefer_ipv4_out" '. + [$out]')
                        fi
                        ;;
                esac
            elif [[ "$outbound" == "warp" ]]; then
                local warp_tag=""
                case "$ip_version" in
                    ipv4_only)
                        warp_tag="warp-ipv4"
                        ;;
                    ipv6_only)
                        warp_tag="warp-ipv6"
                        ;;
                    prefer_ipv6)
                        warp_tag="warp-prefer-ipv6"
                        ;;
                    prefer_ipv4|*)
                        warp_tag="warp-prefer-ipv4"
                        ;;
                esac
                if [[ "$warp_has_endpoint" == "true" ]]; then
                    continue
                fi
                if ! echo "$outbounds" | jq -e --arg tag "$warp_tag" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                    local warp_out=$(gen_singbox_warp_outbound "$db_file")
                    if [[ -n "$warp_out" ]]; then
                        if echo "$warp_out" | jq -e '.endpoint' >/dev/null 2>&1; then
                            local warp_endpoint=$(echo "$warp_out" | jq '.endpoint')
                            if [[ "$warp_has_endpoint" != "true" ]]; then
                                warp_has_endpoint=true
                                warp_endpoint_data="$warp_endpoint"
                            fi
                        else
                            local warp_out_with_tag=$(echo "$warp_out" | jq --arg tag "$warp_tag" '.tag = $tag')
                            outbounds=$(echo "$outbounds" | jq --argjson out "$warp_out_with_tag" '. + [$out]')
                        fi
                    fi
                fi
            elif [[ "$outbound" == chain:* ]]; then
                local node_name="${outbound#chain:}"
                local tag_suffix=""
                case "$ip_version" in
                    ipv4_only) tag_suffix="-ipv4" ;;
                    ipv6_only) tag_suffix="-ipv6" ;;
                    prefer_ipv6) tag_suffix="-prefer-ipv6" ;;
                    prefer_ipv4|*) tag_suffix="-prefer-ipv4" ;;
                esac
                local tag="chain-${node_name}${tag_suffix}"
                # 链式代理支持每种策略一个独立出口
                if ! echo "$outbounds" | jq -e --arg tag "$tag" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                    local chain_out=$(gen_singbox_chain_outbound "$node_name" "$tag" "$ip_version" "$db_file")
                    [[ -n "$chain_out" ]] && outbounds=$(echo "$outbounds" | jq --argjson out "$chain_out" '. + [$out]')
                fi
            fi
        done < <(echo "$rules" | jq -c '.[]')

        # 独立检查 WARP 配置，确保有 WARP 就生成 outbound（不依赖分流规则）
        local warp_mode=$(jq -r '.routing.warp_mode // "wgcf"' "$db_file")
        if [[ -n "$warp_mode" && "$warp_mode" != "disabled" && "$warp_has_endpoint" != "true" ]]; then
            # 检查是否已经有 warp outbound（可能在遍历规则时已生成）
            if ! echo "$outbounds" | jq -e '.[] | select(.tag == "warp" or .tag | startswith("warp-"))' >/dev/null 2>&1; then
                # 没有 warp outbound，生成一个默认的
                local warp_out=$(gen_singbox_warp_outbound "$db_file")
                if [[ -n "$warp_out" ]]; then
                    if echo "$warp_out" | jq -e '.endpoint' >/dev/null 2>&1; then
                        local warp_endpoint=$(echo "$warp_out" | jq '.endpoint')
                        if [[ "$warp_has_endpoint" != "true" ]]; then
                            warp_has_endpoint=true
                            warp_endpoint_data="$warp_endpoint"
                        fi
                    else
                        # 使用默认 tag "warp"
                        local warp_out_default=$(echo "$warp_out" | jq '.tag = "warp"')
                        outbounds=$(echo "$outbounds" | jq --argjson out "$warp_out_default" '. + [$out]')
                    fi
                fi
            fi
        fi

        # 生成负载均衡器 (sing-box 使用 urltest/selector outbound)
        local balancer_groups=$(jq '.balancer_groups // []' "$db_file")
        if [[ -n "$balancer_groups" && "$balancer_groups" != "[]" ]]; then
            while IFS= read -r group_json; do
                local group_name=$(echo "$group_json" | jq -r '.name')
                local strategy=$(echo "$group_json" | jq -r '.strategy')

                # 构建节点 outbound 数组
                local node_outbounds="[]"
                local balancer_ip_version="prefer_ipv4"
                local tag_suffix=""
                case "$balancer_ip_version" in
                    ipv4_only) tag_suffix="-ipv4" ;;
                    ipv6_only) tag_suffix="-ipv6" ;;
                    prefer_ipv6) tag_suffix="-prefer-ipv6" ;;
                    prefer_ipv4|*) tag_suffix="-prefer-ipv4" ;;
                esac

                while IFS= read -r node_name; do
                    [[ -z "$node_name" ]] && continue
                    local node_tag="chain-${node_name}${tag_suffix}"
                    node_outbounds=$(echo "$node_outbounds" | jq --arg tag "$node_tag" '. + [$tag]')

                    # 确保节点 outbound 存在
                    if ! echo "$outbounds" | jq -e --arg tag "$node_tag" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                        local chain_out=$(gen_singbox_chain_outbound "$node_name" "$node_tag" "$balancer_ip_version" "$db_file")
                        [[ -n "$chain_out" ]] && outbounds=$(echo "$outbounds" | jq --argjson out "$chain_out" '. + [$out]')
                    fi
                done < <(echo "$group_json" | jq -r '.nodes[]?')

                # 根据策略生成不同类型的 sing-box outbound
                local balancer_out=""
                case "$strategy" in
                    leastPing)
                        # sing-box 使用 urltest 实现最低延迟选择
                        balancer_out=$(jq -n \
                            --arg tag "balancer-${group_name}" \
                            --argjson outbounds "$node_outbounds" \
                            '{
                                type: "urltest",
                                tag: $tag,
                                outbounds: $outbounds,
                                url: "https://www.gstatic.com/generate_204",
                                interval: "10s",
                                tolerance: 50,
                                idle_timeout: "30m"
                            }')
                        ;;
                    random|roundRobin|*)
                        # selector 固定选择首节点；最低延迟使用 urltest
                        balancer_out=$(jq -n \
                            --arg tag "balancer-${group_name}" \
                            --argjson outbounds "$node_outbounds" \
                            '{
                                type: "selector",
                                tag: $tag,
                                outbounds: $outbounds,
                                default: ($outbounds[0] // "direct")
                            }')
                        ;;
                esac

                # 添加负载均衡器 outbound
                [[ -n "$balancer_out" ]] && outbounds=$(echo "$outbounds" | jq --argjson out "$balancer_out" '. + [$out]')
            done < <(echo "$balancer_groups" | jq -c '.[]')
        fi

        routing_rules=$(gen_singbox_routing_rules "$db_file") || return 1
        if [[ -n "$routing_rules" && "$routing_rules" != "[]" ]]; then
            if [[ "$warp_has_endpoint" == "true" ]]; then
                routing_rules=$(echo "$routing_rules" | jq 'map(if ((.outbound // "") | startswith("warp")) then .outbound = "warp" else . end)')
            fi
            _ensure_singbox_rulesets_from_routing_rules "$routing_rules" || return 1
            singbox_ruleset_defs=$(_build_singbox_ruleset_defs "$routing_rules")
            has_routing=true
        fi

        # 检测是否使用了 WARP，如果是，添加保护性直连规则
        if [[ "$warp_has_endpoint" == "true" ]] || echo "$outbounds" | jq -e '.[] | select(.tag | startswith("warp"))' >/dev/null 2>&1; then
            local warp_mode=$(jq -r '.routing.warp_mode // "wgcf"' "$db_file")

            # 只有 WireGuard 模式需要保护性规则
            if [[ "$warp_mode" == "wgcf" ]]; then
                # 生成保护性规则：WARP 服务器和私有 IP 必须直连
                local warp_protection_rules='[
                    {
                        "outbound": "direct",
                        "domain": ["engage.cloudflareclient.com"]
                    },
                    {
                        "outbound": "direct",
                        "ip_cidr": [
                            "10.0.0.0/8",
                            "172.16.0.0/12",
                            "192.168.0.0/16",
                            "127.0.0.0/8",
                            "169.254.0.0/16",
                            "224.0.0.0/4",
                            "240.0.0.0/4",
                            "fc00::/7",
                            "fe80::/10"
                        ]
                    }
                ]'

                # 将保护性规则放在最前面
                if [[ -n "$routing_rules" && "$routing_rules" != "[]" ]]; then
                    routing_rules=$(echo "$warp_protection_rules" | jq --argjson user_rules "$routing_rules" '. + $user_rules')
                else
                    routing_rules="$warp_protection_rules"
                fi
                has_routing=true
            elif [[ "$warp_mode" == "official" ]]; then
                # SOCKS5 模式：UDP 必须直连（warp-cli SOCKS5 不支持 UDP），私有 IP 直连
                local warp_protection_rules='[
                    {
                        "network": "udp",
                        "outbound": "direct"
                    },
                    {
                        "outbound": "direct",
                        "ip_cidr": [
                            "10.0.0.0/8",
                            "172.16.0.0/12",
                            "192.168.0.0/16",
                            "127.0.0.0/8"
                        ]
                    }
                ]'

                if [[ -n "$routing_rules" && "$routing_rules" != "[]" ]]; then
                    routing_rules=$(echo "$warp_protection_rules" | jq --argjson user_rules "$routing_rules" '. + $user_rules')
                else
                    routing_rules="$warp_protection_rules"
                fi
                has_routing=true
            fi
        fi
    fi

    # 构建基础配置
    local base_config=""
    if [[ "$has_routing" == "true" ]]; then
        base_config=$(jq -n --argjson outbounds "$outbounds" '{
            log: {level: "warn", timestamp: true},
            inbounds: [],
            outbounds: $outbounds,
            route: {rules: [], final: "direct"}
        }')

        # 添加 WireGuard endpoint（如果存在）
        if [[ "$warp_has_endpoint" == "true" ]]; then
            base_config=$(echo "$base_config" | jq --argjson ep "$warp_endpoint_data" '.endpoints = [$ep]')
        fi

        # 添加路由规则
        if [[ -n "$routing_rules" && "$routing_rules" != "[]" ]]; then
            base_config=$(echo "$base_config" | jq --argjson rules "$routing_rules" '.route.rules = $rules')
        fi
        if [[ -n "$singbox_ruleset_defs" && "$singbox_ruleset_defs" != "[]" ]]; then
            base_config=$(echo "$base_config" | jq --argjson sets "$singbox_ruleset_defs" '.route.rule_set = $sets')
        fi
    else
        base_config=$(jq -n --argjson direct "$direct_outbound" '{
            log: {level: "warn", timestamp: true},
            inbounds: [],
            outbounds: [$direct]
        }')

        # 添加 WireGuard endpoint（如果存在）
        if [[ "$warp_has_endpoint" == "true" ]]; then
            base_config=$(echo "$base_config" | jq --argjson ep "$warp_endpoint_data" '.endpoints = [$ep]')
        fi
    fi

    local inbounds="[]" success_count=0 protocol_records proto cfg inbound
    protocol_records=$(jq -r '(.singbox // {}) | to_entries[] | .key as $p |
        .value | (if type == "array" then .[] else . end) | $p + "|" + tojson' "$db_file") || return 1
    while IFS='|' read -r proto cfg; do
        [[ -n "$cfg" ]] || continue
        inbound=$(_lite_singbox_inbounds "$proto" "$cfg" "$listen_addr") || return 1
        inbounds=$(jq --argjson ib "$inbound" '. + $ib' <<<"$inbounds") || return 1
        success_count=$((success_count + 1))
    done <<<"$protocol_records"
    [[ "$success_count" -gt 0 ]] || { _err "没有有效的 Sing-box 协议配置"; return 1; }

    # 生成用户级路由规则 (auth_user) 和所需的 outbounds
    local user_routing_rules="[]"
    local user_outbounds="[]"
    local chain_outbounds_added=""  # 跟踪已添加的链式代理 outbound

    for proto in $singbox_protocols; do
        is_singbox_snell_protocol "$proto" && continue
        local db_users=$(jq -r --arg p "$proto" '
            .singbox[$p] as $cfg |
            if $cfg == null then empty
            elif ($cfg | type) == "array" then
                [$cfg[].users // [] | .[]] | unique_by(.name) | .[]
            else
                $cfg.users // [] | .[]
            end | select(.enabled != false) | @json
        ' "$db_file" 2>/dev/null)

        while IFS= read -r user_json; do
            [[ -z "$user_json" ]] && continue
            local uname=$(echo "$user_json" | jq -r '.name // empty')
            local urouting=$(echo "$user_json" | jq -r '.routing // empty')

            [[ -z "$uname" || -z "$urouting" || "$urouting" == "default" ]] && continue

            # 根据路由类型生成规则
            local outbound_name=""
            case "$urouting" in
                warp|warp-wireguard|warp-official)
                    outbound_name="warp"
                    ;;
                direct)
                    outbound_name="direct"
                    ;;
                chain:*)
                    # 链式代理支持
                    local node_name="${urouting#chain:}"
                    outbound_name="chain-${node_name}"

                    # 检查该链式代理 outbound 是否已添加
                    if [[ " $chain_outbounds_added " != *" $outbound_name "* ]]; then
                        # 生成链式代理 outbound
                        local chain_out=$(gen_singbox_chain_outbound "$node_name" "$outbound_name" "prefer_ipv4" "$db_file")
                        if [[ -n "$chain_out" && "$chain_out" != "null" ]]; then
                            user_outbounds=$(echo "$user_outbounds" | jq --argjson out "$chain_out" '. + [$out]')
                            chain_outbounds_added="$chain_outbounds_added $outbound_name"
                        else
                            # 链式代理节点不存在，跳过
                            continue
                        fi
                    fi
                    ;;
                *)
                    # 其他路由类型暂不支持
                    continue
                    ;;
            esac

            # 添加路由规则（Sing-box 实际匹配的是内部统计键用户名）
            local stat_user="${proto}-${uname}"
            user_routing_rules=$(echo "$user_routing_rules" | jq \
                --arg user "$stat_user" \
                --arg outbound "$outbound_name" \
                '. + [{auth_user: [$user], outbound: $outbound}]')
        done <<< "$db_users"
    done

    # 将用户路由所需的 outbounds 添加到 base_config
    if [[ "$user_outbounds" != "[]" ]]; then
        base_config=$(echo "$base_config" | jq --argjson outs "$user_outbounds" '.outbounds = ($outs + (.outbounds // []))')
    fi

    # 将用户路由规则添加到 base_config
    if [[ "$user_routing_rules" != "[]" ]]; then
        if echo "$base_config" | jq -e '.route' >/dev/null 2>&1; then
            base_config=$(echo "$base_config" | jq --argjson ur "$user_routing_rules" '.route.rules = ($ur + .route.rules)')
        else
            base_config=$(echo "$base_config" | jq --argjson ur "$user_routing_rules" '. + {route: {rules: $ur, final: "direct"}}')
        fi
    fi

    # 1.14+ 不再默认接受旧 domain_strategy；只在新核心上输出现代 DNS 格式，
    # 避免安装 Snell 后共享服务中的原有直连/链式出口因弃用字段无法启动。
    local core_version
    core_version=$("${SINGBOX_CONFIG_BINARY:-sing-box}" version 2>/dev/null | awk 'NR == 1 {print $3}')
    if _singbox_supports_snell_version "$core_version"; then
        base_config=$(jq '
            .dns = {servers:[{type:"local",tag:"system-dns"}]} |
            .route.default_domain_resolver = "system-dns" |
            .outbounds |= map(
                if .domain_strategy then
                    .domain_resolver = {server:"system-dns",strategy:.domain_strategy} |
                    del(.domain_strategy)
                else . end
            )
        ' <<<"$base_config") || return 1
    fi

    # 服务端先嗅探 HTTP Host、TLS SNI 和 QUIC 域名，再执行分流；不改写目标地址。
    base_config=$(jq '
        .route.rules = ([{action:"sniff"}] + (.route.rules // []))
    ' <<<"$base_config") || return 1

    local tmp
    tmp=$(mktemp "${output_file}.tmp.XXXXXX") || return 1
    if ! jq --argjson ibs "$inbounds" '.inbounds = $ibs' <<<"$base_config" >"$tmp" ||
       ! jq -e '([.inbounds[].listen_port | select(. > 0)] | length) == ([.inbounds[].listen_port | select(. > 0)] | unique | length)' "$tmp" >/dev/null ||
       ! validate_singbox_config "$tmp" || ! chmod 600 "$tmp" || ! mv "$tmp" "$output_file"; then
        rm -f "$tmp"
        _err "Sing-box 配置校验失败，保留原配置"
        return 1
    fi

    _ok "Sing-box 配置生成成功 ($success_count 个协议)"
    return 0
}

validate_singbox_config() {
    # sing-box check 不会验证所有出口引用；缺失出口不能在运行时才被发现。
    jq -e '
        ([.outbounds[]?.tag, .endpoints[]?.tag]) as $tags |
        ([.inbounds[]?.tag]) as $inbound_tags |
        ($inbound_tags | length) == ($inbound_tags | unique | length) and
        all((.inbounds[]?.detour // empty); . as $tag | $inbound_tags | index($tag) != null) and
        ($tags | length) == ($tags | unique | length) and
        all((.route // {} | .. | objects | .outbound? // empty); . as $tag | $tags | index($tag) != null) and
        all((.route.final // empty); . as $tag | $tags | index($tag) != null) and
        all((.outbounds[]? | (.outbounds[]?, .default? // empty, .detour? // empty));
            . as $tag | $tags | index($tag) != null)
    ' "$1" >/dev/null 2>&1 || return 1
    local binary version
    binary=$(_lite_singbox_binary) || return 1
    version=$("$binary" version 2>/dev/null | awk 'NR == 1 {print $3}')
    if _singbox_supports_snell_version "$version"; then
        "$binary" check -c "$1"
    else
        # 未安装 Snell 的旧核心保持原服务的兼容环境，不因新增校验而拒绝旧配置。
        ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true "$binary" check -c "$1"
    fi
}

# 分流更新先生成完整候选配置，重启失败时恢复旧配置和原运行状态。
_regenerate_singbox_routing_config() {
    local snapshot was_running=false had_config=false
    snapshot=$(mktemp -d "$CFG/.singbox-routing.XXXXXX") || return 1
    if [[ -f "$CFG/singbox.json" ]]; then
        cp -p "$CFG/singbox.json" "$snapshot/previous.json" || { rmdir "$snapshot"; return 1; }
        had_config=true
    fi
    svc status sing-singbox >/dev/null 2>&1 && was_running=true
    if ! generate_singbox_config "$snapshot/candidate.json" ||
       ! mv "$snapshot/candidate.json" "$CFG/singbox.json"; then
        rm -rf "$snapshot"
        return 1
    fi
    if [[ "$was_running" == true ]]; then
        if svc restart sing-singbox && _wait_for_singbox_ready; then
            rm -rf "$snapshot"
            return 0
        fi
        if [[ "$had_config" == true ]]; then
            cp -p "$snapshot/previous.json" "$CFG/singbox.json" || { _err "Sing-box 恢复失败，快照保留: $snapshot"; return 1; }
            if ! { svc restart sing-singbox && _wait_for_singbox_ready; }; then
                _err "Sing-box 恢复失败，快照保留: $snapshot"
                return 1
            fi
        else
            rm -f "$CFG/singbox.json"
            svc stop sing-singbox || return 1
        fi
        rm -rf "$snapshot"
        return 1
    fi
    rm -rf "$snapshot"
}

_wait_for_singbox_ready() {
    local attempt listeners transport port ready
    listeners=$(jq -r '.inbounds[] | select((.listen_port // 0) > 0) |
        (if .type == "hysteria2" or .type == "tuic" then "udp" else "tcp" end) + "|" + (.listen_port | tostring)
    ' "$CFG/singbox.json") || return 1
    [[ -n "$listeners" ]] || return 1
    for ((attempt=0; attempt<30; attempt++)); do
        ready=true
        if svc status sing-singbox >/dev/null 2>&1; then
            while IFS='|' read -r transport port; do
                local flag=-lnt
                [[ "$transport" == udp ]] && flag=-lnu
                if ! ss -H "$flag" "sport = :$port" 2>/dev/null | grep -q .; then
                    ready=false
                    break
                fi
            done <<<"$listeners"
            [[ "$ready" == true ]] && return 0
        fi
        sleep 0.3
    done
    return 1
}

# 创建 Sing-box 服务
create_singbox_service() {
    local service_name="sing-singbox"
    local exec_cmd="$CFG/bin/sing-box run -c $CFG/singbox.json"

    # 检查是否有 hy2 协议且启用了端口跳跃
    local has_hy2_hop=false
    if db_exists "singbox" "hy2"; then
        local hop_enable=$(db_get_field "singbox" "hy2" "hop_enable")
        [[ "$hop_enable" == "1" ]] && has_hy2_hop=true
    fi

    local has_tuic_hop=false
    if db_exists "singbox" "tuic"; then
        local hop_enable=$(db_get_field "singbox" "tuic" "hop_enable")
        [[ "$hop_enable" == "1" ]] && has_tuic_hop=true
    fi

    if [[ "$DISTRO" == "alpine" ]]; then
        # Alpine: 在 start_pre 中执行端口跳跃脚本
        cat > "$OPENRC_DIR/$service_name" << EOF || return 1
#!/sbin/openrc-run
name="Sing-box Proxy Server"
command="$CFG/bin/sing-box"
command_args="run -c $CFG/singbox.json"
command_env="ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true"
command_background="yes"
pidfile="/run/${service_name}.pid"
output_log="/var/log/${service_name}.log"
error_log="/var/log/${service_name}.log"
depend() { need net; }
start_pre() {
    [ ! -x "$CFG/hy2-nat.sh" ] || "$CFG/hy2-nat.sh" || true
    [ ! -x "$CFG/tuic-nat.sh" ] || "$CFG/tuic-nat.sh" || true
    $CFG/bin/sing-box check -c "$CFG/singbox.json"
}
EOF
        chmod +x "$OPENRC_DIR/$service_name" || return 1
    else
        # systemd: 添加 ExecStartPre 执行端口跳跃脚本
        local pre_cmd=""
        [[ -f "$CFG/hy2-nat.sh" ]] && pre_cmd="ExecStartPre=-/bin/bash $CFG/hy2-nat.sh"
        [[ -f "$CFG/tuic-nat.sh" ]] && pre_cmd="${pre_cmd}"$'\n'"ExecStartPre=-/bin/bash $CFG/tuic-nat.sh"

        cat > "$SYSTEMD_DIR/${service_name}.service" << EOF || return 1
[Unit]
Description=Sing-box Proxy Server
After=network.target

[Service]
Type=simple
Environment=ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true
${pre_cmd}
ExecStartPre=$CFG/bin/sing-box check -c $CFG/singbox.json
ExecStart=$exec_cmd
Restart=always
RestartSec=3
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi
}

# 新装共享核心也需要 watchdog unit，不能依赖其他独立协议顺带创建。
create_watchdog_service() {
    if [[ "$DISTRO" == alpine ]]; then
        cat >"$OPENRC_DIR/sing-watchdog" <<EOF || return 1
#!/sbin/openrc-run
name="VLESS Watchdog"
command="/bin/bash"
command_args="$CFG/watchdog.sh"
command_background="yes"
pidfile="/run/sing-watchdog.pid"
depend() { need net; }
EOF
        chmod +x "$OPENRC_DIR/sing-watchdog"
    else
        cat >"$SYSTEMD_DIR/sing-watchdog.service" <<EOF || return 1
[Unit]
Description=VLESS Watchdog
After=network.target sing-singbox.service

[Service]
Type=simple
ExecStart=/bin/bash $CFG/watchdog.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi
}

# Alpine 3.21 Snell 运行环境兼容处理
# Snell 官方 Linux 二进制可能使用 glibc ABI，并可能经过 UPX 压缩。
# Alpine 使用 musl，因此必须先安装兼容层、再尝试解压，最后才能执行验证。
ensure_snell_alpine_runtime() {
    [[ "$DISTRO" == "alpine" ]] || return 0

    _info "准备 Alpine Snell 兼容运行环境..."

    # gcompat 提供常用 glibc ABI；libstdc++/libgcc 补充部分动态链接依赖。
    # upx、file 仅用于解压和故障诊断，仓库中不可用时不阻断安装。
    if ! apk add --no-cache gcompat libc6-compat libstdc++ libgcc >/dev/null 2>&1; then
        _err "Alpine glibc 兼容层安装失败"
        _warn "请检查 /etc/apk/repositories 后执行: apk add gcompat libc6-compat libstdc++ libgcc"
        return 1
    fi

    apk add --no-cache upx file >/dev/null 2>&1 || true
    return 0
}

prepare_snell_binary() { # prepare_snell_binary <binary>
    local binary="$1"
    [[ -f "$binary" ]] || return 1
    chmod 755 "$binary" 2>/dev/null || return 1

    if [[ "$DISTRO" == "alpine" ]]; then
        ensure_snell_alpine_runtime || return 1

        # 必须在首次运行前解压；否则 UPX 的 glibc stub 在 musl 下可能直接报 not found。
        if command -v upx >/dev/null 2>&1; then
            upx -d "$binary" >/dev/null 2>&1 || true
        fi
    fi
    return 0
}

snell_binary_works() { # snell_binary_works <binary>
    local binary="$1" output=""
    [[ -x "$binary" ]] || return 1

    # 不同 Snell 版本的版本参数不同；任一可执行即视为运行环境正常。
    "$binary" --v >/dev/null 2>&1 && return 0
    "$binary" --version >/dev/null 2>&1 && return 0
    "$binary" -v >/dev/null 2>&1 && return 0

    # 某些旧版本不支持版本参数，但可以被动态加载；用 ldd 判断是否缺少解释器/库。
    if command -v ldd >/dev/null 2>&1; then
        output=$(ldd "$binary" 2>&1 || true)
        echo "$output" | grep -qiE 'not found|No such file|Error loading' && return 1
        [[ -n "$output" ]] && return 0
    fi
    return 1
}

_snell_alpine_diagnostics() { # _snell_alpine_diagnostics <binary>
    local binary="$1"
    [[ "$DISTRO" == "alpine" ]] || return 0
    _warn "Snell 二进制在 Alpine 上仍无法运行，诊断信息如下："
    command -v file >/dev/null 2>&1 && echo "  文件类型: $(file -b "$binary" 2>/dev/null)"
    command -v ldd >/dev/null 2>&1 && { echo "  动态依赖:"; ldd "$binary" 2>&1 | sed 's/^/    /'; }
    _warn "建议确认 Alpine 版本、CPU 架构以及 community 仓库可用。"
}

# 安装/更新 Snell v6（稳定版优先，无稳定版时使用官方预发布版）
# 不传版本且二进制可用时复用现有安装；显式传入版本时强制覆盖，用于核心更新。
_install_official_snell() {
    local major="$1" requested="${2:-}" version="${2:-}" bin arch tmp url expected="" digest metadata staged
    [[ "$major" == 5 || "$major" == 6 ]] || return 1
    bin=$(_core_binary_path "snell-server-v${major}") || return 1
    mkdir -p "$CFG/bin" || return 1
    if [[ -z "$requested" && -x "$bin" ]] && snell_binary_works "$bin"; then return 0; fi
    case "$major" in
        5) [[ -n "$version" ]] || version=$(_get_snell_v5_channel_version stable) || return 1; expected="${SNELL_V5_SHA256:-}" ;;
        6) [[ -n "$version" ]] || version=$(_get_snell_v6_channel_version stable) || return 1; expected="${SNELL_V6_SHA256:-}" ;;
        *) return 1 ;;
    esac
    [[ "$version" =~ ^${major}\.[0-9]+\.[0-9]+([A-Za-z][A-Za-z0-9._-]*)?$ ]] || { _err "无效 Snell 版本: $version"; return 1; }
    if [[ "$major" == 5 ]]; then arch=$(_map_arch 'amd64:aarch64:armv7l'); else arch=$(_map_arch 'amd64:aarch64:'); fi
    [[ -n "$arch" ]] || { _err '不支持的 Snell 架构'; return 1; }
    url="https://dl.nssurge.com/snell/snell-server-v${version}-linux-${arch}.zip"
    if [[ -z "$expected" ]]; then
        case "$version:$arch" in
            5.0.1:amd64) expected=9bea1c2b9e35b73b31634856c04d18c393072b9e5dcde6a32781d8b8f908c539 ;;
            5.0.1:aarch64) expected=2f178bf5ac468ce1a130454efa40a0603fbbe4e47ecc4880a989f4abc7f824cf ;;
            5.0.1:armv7l) expected=14489f3e857569c8835dd3598b7ea6bca5371d4290ac7cf0f6c8dfb3381c1fb2 ;;
            6.*) expected=$(_snell_release_sha256 "$version" "$arch" 2>/dev/null || true) ;;
        esac
    fi
    if [[ -z "$expected" ]]; then
        digest=$(curl -fsSL --connect-timeout 5 --max-time 20 \
            "https://api.github.com/repos/${SNELL_V6_REPO}/releases/tags/v${version}" |
            jq -r --arg name "snell-server-v${version}-linux-${arch}.zip" '.assets[]? | select(.name == $name) | .digest // empty' | head -n 1)
        expected="${digest#sha256:}"
    fi
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || { _err '无法获取 Snell SHA-256'; return 1; }
    tmp=$(mktemp -d) || return 1
    if ! curl -fsSL --connect-timeout 20 --max-time 180 --retry 2 -o "$tmp/snell.zip" -- "$url" ||
       [[ "$(_sha256_file "$tmp/snell.zip" | tr '[:upper:]' '[:lower:]')" != "${expected,,}" ]] ||
       ! _archive_paths_safe "$tmp/snell.zip" zip || ! unzip -oq "$tmp/snell.zip" -d "$tmp"; then
        rm -rf "$tmp"; _err 'Snell 下载或 SHA-256 校验失败'; return 1
    fi
    staged="$tmp/snell-server"
    if ! prepare_snell_binary "$staged" || ! snell_binary_works "$staged"; then
        _snell_alpine_diagnostics "$staged"
        rm -rf "$tmp"; _err 'Snell 无法在当前系统运行'; return 1
    fi
    # 与目标同目录暂存并 rename，避免覆盖运行中的 inode。
    if ! _replace_singbox_binary "$staged" "$bin"; then rm -rf "$tmp"; return 1; fi
    rm -rf "$tmp"
    metadata="$CFG/.snell-v${major}-installed-version"
    mkdir -p "$CFG" || return 1
    staged=$(mktemp "$CFG/.snell-version.XXXXXX") || return 1
    if ! { printf '%s\n' "$version" >"$staged" && chmod 600 "$staged" && mv "$staged" "$metadata"; }; then
        rm -f "$staged"; return 1
    fi
    _ok "官方 Snell v$version 已安装"
}

install_snell_v5() { _install_official_snell 5 "${1:-}"; }
install_snell_v6() { _install_official_snell 6 "${1:-}"; }
gen_self_cert() {
    local domain="${1:-localhost}"
    mkdir -p "$CFG/certs"

    # 检查是否应该保护现有证书
    if [[ -f "$CFG/certs/server.crt" ]]; then
        # 检查是否为 CA 签发的证书（真实证书不覆盖）
        local issuer=$(openssl x509 -in "$CFG/certs/server.crt" -noout -issuer 2>/dev/null)
        if [[ "$issuer" =~ (Let\'s\ Encrypt|R3|R10|R11|E1|E5|ZeroSSL|Buypass|DigiCert|Comodo|GlobalSign) ]]; then
            _ok "检测到 CA 证书，跳过"
            return 0
        fi
        # 检查现有自签证书的 CN 是否匹配
        local current_cn=$(openssl x509 -in "$CFG/certs/server.crt" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,]*\).*/\1/p')
        if [[ "$current_cn" == "$domain" ]]; then
            _ok "自签证书 CN 匹配，跳过"
            return 0
        fi
    fi

    rm -f "$CFG/certs/server.crt" "$CFG/certs/server.key"
    _info "生成自签名证书..."
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$CFG/certs/server.key" -out "$CFG/certs/server.crt" \
        -subj "/CN=$domain" -days 36500 2>/dev/null
    chmod 600 "$CFG/certs/server.key"
}


#═══════════════════════════════════════════════════════════════════════════════
# 配置生成
#═══════════════════════════════════════════════════════════════════════════════

# VLESS+Reality 服务端配置

# Sing-box REALITY 使用自身的 X25519 密钥生成器，不依赖 Xray。
gen_singbox_reality_keys() {
    local keys private_key public_key binary
    binary=$(_lite_singbox_binary) || return 1
    keys=$("$binary" generate reality-keypair 2>/dev/null) || return 1
    private_key=$(printf '%s\n' "$keys" | awk -F': *' '/^PrivateKey:/ {print $2; exit}')
    public_key=$(printf '%s\n' "$keys" | awk -F': *' '/^PublicKey:/ {print $2; exit}')
    [[ -n "$private_key" && -n "$public_key" ]] || return 1
    jq -n --arg private "$private_key" --arg public "$public_key" \
        '{private_key:$private,public_key:$public}'
}

gen_vless_singbox_server_config() {
    local uuid="$1" port="$2" privkey="$3" pubkey="$4" sid="$5" sni="$6"
    local config
    mkdir -p "$CFG"
    config=$(_lite_build_config uuid "$uuid" port "$port" private_key "$privkey" \
        public_key "$pubkey" sni "$sni" security_mode "reality" |
        jq --arg sid "$sid" '.short_id=$sid') || return 1
    _apply_singbox_vless_config "$config"
}

# VLESS+Encryption (纯 TCP，无 Reality) 服务端配置

# VLESS+Reality+XHTTP 服务端配置

# Hysteria2 服务端配置
gen_hy2_server_config() {
    local password="$1" port="$2" sni="${3:-bing.com}"
    local hop_enable="${4:-0}" hop_start="${5:-20000}" hop_end="${6:-50000}"
    mkdir -p "$CFG"

    # 生成自签证书（Sing-box 使用）
    local hy2_cert_dir="$CFG/certs/hy2"
    mkdir -p "$hy2_cert_dir"

    local cert_file="$hy2_cert_dir/server.crt"
    local key_file="$hy2_cert_dir/server.key"

    # 检查是否有真实域名的 ACME 证书可复用
    if [[ -f "$CFG/cert_domain" && -f "$CFG/certs/server.crt" ]]; then
        local cert_domain=$(cat "$CFG/cert_domain")
        local issuer=$(openssl x509 -in "$CFG/certs/server.crt" -noout -issuer 2>/dev/null)
        if [[ "$issuer" == *"Let's Encrypt"* ]] || [[ "$issuer" == *"R3"* ]] || [[ "$issuer" == *"R10"* ]] || [[ "$issuer" == *"R11"* ]]; then
            if [[ "$sni" == "$cert_domain" ]]; then
                _ok "复用现有 ACME 证书 (域名: $sni)"
            fi
        fi
    fi

    # 生成独立自签证书（无论是否有 ACME 证书都生成，Sing-box 配置会智能选择）
    local need_regen=false
    [[ ! -f "$cert_file" ]] && need_regen=true
    if [[ "$need_regen" == "false" ]]; then
        local cert_cn=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/.*CN *= *//')
        [[ "$cert_cn" != "$sni" ]] && need_regen=true
    fi

    if [[ "$need_regen" == "true" ]]; then
        _info "为 Hysteria2 生成自签证书 (SNI: $sni)..."
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout "$key_file" -out "$cert_file" -subj "/CN=$sni" -days 36500 2>/dev/null
        chmod 600 "$key_file"
        _ok "Hysteria2 自签证书生成完成"
    fi

    # 写入数据库（Sing-box 从数据库读取配置生成 singbox.json）
    _lite_apply_protocol "hy2" "$(_lite_build_config \
        password "$password" port "$port" sni "$sni" \
        hop_enable "$hop_enable" hop_start "$hop_start" hop_end "$hop_end")" || return 1
    # 保存 join 信息
    local extra_lines=()
    [[ "$hop_enable" == "1" ]] && extra_lines=("" "# 端口跳跃已启用" "# 客户端请手动将端口改为: ${hop_start}-${hop_end}")

    echo "server" > "$CFG/role"
}

# Shadowsocks 2022 服务端配置
gen_ss2022_server_config() {
    local password="$1" port="$2" method="${3:-2022-blake3-aes-128-gcm}"
    mkdir -p "$CFG"

    _lite_apply_protocol "ss2022" "$(_lite_build_config password "$password" port "$port" method "$method")" || return 1
    echo "server" > "$CFG/role"
}

# Shadowsocks 传统版服务端配置
gen_ss_legacy_server_config() {
    local password="$1" port="$2" method="${3:-aes-256-gcm}"
    mkdir -p "$CFG"

    _lite_apply_protocol "ss-legacy" "$(_lite_build_config password "$password" port "$port" method "$method")" || return 1
    echo "server" > "$CFG/role"
}

# Snell v4 服务端配置（由 Sing-box 共享服务承载）

# TUIC v5 服务端配置
gen_tuic_server_config() {
    local uuid="$1" password="$2" port="$3" sni="${4:-bing.com}"
    local hop_enable="${5:-0}" hop_start="${6:-20000}" hop_end="${7:-50000}"
    mkdir -p "$CFG"

    # 生成自签证书（Sing-box 使用）
    local tuic_cert_dir="$CFG/certs/tuic"
    mkdir -p "$tuic_cert_dir"
    local cert_file="$tuic_cert_dir/server.crt"
    local key_file="$tuic_cert_dir/server.key"

    local server_ip=$(get_ipv4)
    [[ -z "$server_ip" ]] && server_ip=$(get_ipv6)
    [[ -z "$server_ip" ]] && server_ip="$sni"

    # TUIC 需要证书：检查 SNI 是否为用户自己的域名
    # - 如果是用户域名（不在常见 SNI 列表）→ 尝试复用已有真实证书
    # - 如果是常见域名（如 microsoft.com）→ 后续生成自签证书
    local is_common_sni=false
    for common_sni in "${COMMON_SNI_LIST[@]}"; do
        if [[ "$sni" == "$common_sni" ]]; then
            is_common_sni=true
            break
        fi
    done

    if [[ "$is_common_sni" == "false" ]]; then
        # 用户自己的域名：检查是否有真实证书可复用
        if [[ -f "$CFG/certs/server.crt" && -f "$CFG/certs/server.key" ]]; then
            local cert_cn=$(openssl x509 -in "$CFG/certs/server.crt" -noout -subject 2>/dev/null | sed 's/.*CN *= *//')
            if [[ "$cert_cn" == "$sni" ]]; then
                _ok "复用现有真实证书 (域名: $sni)"
            fi
        fi
    fi

    # 生成独立自签证书（无论是否有 ACME 证书都生成，Sing-box 配置会智能选择）
    if [[ ! -f "$cert_file" ]]; then
        _info "为 TUIC 生成独立自签证书 (SNI: $sni)..."
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout "$key_file" -out "$cert_file" \
            -subj "/CN=$sni" -days 36500 \
            -addext "subjectAltName=DNS:$sni" \
            -addext "basicConstraints=critical,CA:FALSE" \
            -addext "extendedKeyUsage=serverAuth" 2>/dev/null
        chmod 600 "$key_file"
        _ok "TUIC 自签证书生成完成"
    fi

    # 写入数据库（Sing-box 从数据库读取配置生成 singbox.json）
    _lite_apply_protocol "tuic" "$(_lite_build_config \
        uuid "$uuid" password "$password" port "$port" sni "$sni" \
        hop_enable "$hop_enable" hop_start "$hop_start" hop_end "$hop_end")" || return 1
    # 保存 join 信息
    local extra_lines=()
    [[ "$hop_enable" == "1" ]] && extra_lines=("" "# 端口跳跃已启用" "# 客户端请手动将端口改为: ${hop_start}-${hop_end}")

    echo "server" > "$CFG/role"
}

# AnyTLS TLS 证书交互配置
# 设置全局变量：ANYTLS_CERT_MODE / ANYTLS_CERT_SNI
configure_anytls_certificate() {
    ANYTLS_CERT_MODE=""
    ANYTLS_CERT_SNI=""
    mkdir -p "$CFG/certs"

    while true; do
        echo ""
        _line
        echo -e "  ${W}AnyTLS TLS 证书配置${NC}"
        _line
        echo -e "  ${G}1)${NC} 使用已有证书 (${CFG}/certs/server.crt)"
        echo -e "  ${G}2)${NC} 使用域名申请 Let's Encrypt 证书"
        echo -e "  ${G}3)${NC} 使用自签证书"
        echo ""
        read -rp "  请选择 [1-3，默认 3.自签证书]: " cert_choice
        cert_choice="${cert_choice:-3}"

        case "$cert_choice" in
            1)
                if [[ ! -s "$CFG/certs/server.crt" || ! -s "$CFG/certs/server.key" ]]; then
                    _warn "未找到已有证书或私钥，请重新选择"
                    continue
                fi
                if ! openssl x509 -in "$CFG/certs/server.crt" -noout >/dev/null 2>&1; then
                    _warn "已有证书格式无效，请重新选择"
                    continue
                fi

                local detected_sni=""
                detected_sni=$(openssl x509 -in "$CFG/certs/server.crt" -noout -ext subjectAltName 2>/dev/null \
                    | grep -oE 'DNS:[^, ]+' | head -n1 | cut -d: -f2-)
                [[ -z "$detected_sni" ]] && detected_sni=$(openssl x509 -in "$CFG/certs/server.crt" -noout -subject 2>/dev/null \
                    | sed -n 's/.*CN *= *\([^,]*\).*/\1/p')

                while true; do
                    read -rp "  请输入证书对应的 SNI${detected_sni:+ [回车默认 ${detected_sni}]}: " input_sni
                    input_sni="${input_sni:-$detected_sni}"
                    _is_valid_dns_name "$input_sni" && break
                    _warn "SNI 域名格式无效，请重新输入"
                done

                ANYTLS_CERT_MODE="existing"
                ANYTLS_CERT_SNI="$input_sni"
                _ok "将使用已有证书，SNI: $ANYTLS_CERT_SNI"
                return 0
                ;;
            2)
                echo -e "  ${Y}提示：域名必须已解析到本机公网 IP，且 80/443 端口满足证书签发要求${NC}"
                local domain=""
                while true; do
                    read -rp "  请输入申请证书的域名: " domain
                    _is_valid_dns_name "$domain" && break
                    _warn "域名格式无效"
                done

                CERT_DOMAIN="$domain"
                NGINX_PORT="18443"
                echo "$NGINX_PORT" > "$CFG/.nginx_port_tmp" 2>/dev/null
                if get_acme_cert "$domain" "anytls"; then
                    echo "$domain" > "$CFG/cert_domain"
                    rm -f "$CFG/.nginx_port_tmp"
                    ANYTLS_CERT_MODE="acme"
                    ANYTLS_CERT_SNI="$domain"
                    _ok "真实证书申请成功，SNI: $domain"
                    return 0
                fi
                rm -f "$CFG/.nginx_port_tmp"
                _warn "证书申请失败，请重新选择证书方式"
                ;;
            3)
                local default_sni="$(gen_sni)"
                local self_sni=""
                read -rp "  请输入自签证书 SNI [回车默认 ${default_sni}]: " self_sni
                self_sni="${self_sni:-$default_sni}"
                if ! _is_valid_dns_name "$self_sni"; then
                    _warn "SNI 域名格式无效"
                    continue
                fi

                # 强制重新生成匹配当前 SNI、包含 SAN 的自签证书
                rm -f "$CFG/certs/server.crt" "$CFG/certs/server.key"
                _info "生成带 SAN 的 AnyTLS 自签证书..."
                if ! openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
                    -keyout "$CFG/certs/server.key" -out "$CFG/certs/server.crt" \
                    -subj "/CN=$self_sni" -days 36500 \
                    -addext "subjectAltName=DNS:$self_sni" \
                    -addext "basicConstraints=critical,CA:FALSE" \
                    -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1; then
                    _err "自签证书生成失败"
                    continue
                fi
                chmod 600 "$CFG/certs/server.key"
                echo "$self_sni" > "$CFG/cert_domain"
                ANYTLS_CERT_MODE="self"
                ANYTLS_CERT_SNI="$self_sni"
                _ok "自签证书生成完成，SNI: $self_sni"
                return 0
                ;;
            *)
                _warn "无效选项，请输入 1、2 或 3"
                ;;
        esac
    done
}

# AnyTLS 服务端配置（迁移到 Sing-box 核心）
gen_anytls_server_config() {
    local password="$1" port="$2" sni="${3:-bing.com}" cert_mode="${4:-self}"
    mkdir -p "$CFG"

    # 证书必须在安装交互步骤中准备完成，不再静默生成或覆盖
    if [[ ! -s "$CFG/certs/server.crt" || ! -s "$CFG/certs/server.key" ]]; then
        _err "AnyTLS TLS 证书或私钥不存在"
        return 1
    fi

    _lite_apply_protocol "anytls" "$(_lite_build_config password "$password" port "$port" sni "$sni" cert_mode "$cert_mode")" || return 1
    echo "server" > "$CFG/role"
}

# NaïveProxy 服务端配置
_lite_apply_protocol() {
    local protocol="$1" record="$2"
    _apply_singbox_vless_config "$record" "${INSTALL_MODE:-add}" "${REPLACE_PORT:-}" "$protocol"
}

_lite_singbox_binary() {
    if [[ -n "${SINGBOX_CONFIG_BINARY:-}" ]]; then
        printf '%s\n' "$SINGBOX_CONFIG_BINARY"
    elif declare -F sing-box >/dev/null 2>&1; then
        printf '%s\n' sing-box
    elif [[ -x "$CFG/bin/sing-box" ]]; then
        printf '%s\n' "$CFG/bin/sing-box"
    else
        printf '%s\n' sing-box
    fi
}

_lite_build_config() {
    local key value ipv4 ipv6 result='{}'
    while [[ $# -ge 2 ]]; do
        key="$1"; value="$2"; shift 2
        case "$key" in
            port|version|hop_start|hop_end)
                [[ "$value" =~ ^[0-9]+$ ]] || return 1
                result=$(jq --arg key "$key" --arg value "$value" '. + {($key):($value | tonumber)}' <<<"$result") || return 1 ;;
            *) result=$(jq --arg key "$key" --arg value "$value" '. + {($key):$value}' <<<"$result") || return 1 ;;
        esac
    done
    IFS='|' read -r ipv4 ipv6 <<<"$(get_connection_addresses)"
    jq --arg ipv4 "$ipv4" --arg ipv6 "$ipv6" '. + {ipv4:$ipv4,ipv6:$ipv6}' <<<"$result"
}

# Rebuild every enabled account and every port into a candidate JOIN file.
regenerate_singbox_protocol_join_info() {
    local protocol="$1" records record output tmp aggregate join ipv4 ipv6 ip host label
    local port uuid password username sni method psk public sid data link prefix mode country
    output="$CFG/$protocol.join"
    tmp=$(mktemp "$CFG/.protocol-join.XXXXXX") || return 1
    records=$(jq -c --arg p "$protocol" '
        .singbox[$p] | (if type == "array" then .[] elif type == "object" then . else empty end) |
        . as $c | if has("users") and ($p != "snell-v5" and $p != "snell-v6-singbox") then
            .users[] | select(.enabled != false) | $c + {uuid:.uuid,name:.name,
                username:(.username // .name),password:(if $p == "tuic" then (.password // $c.password)
                elif ($p == "ss2022" or $p == "ss2022-shadowtls") and
                    ($c.method == "2022-blake3-aes-128-gcm" or $c.method == "2022-blake3-aes-256-gcm")
                then ($c.password + ":" + (.uuid // .password)) else (.password // .uuid) end)}
        else . end' "$DB_FILE") || { rm -f "$tmp"; return 1; }
    IFS='|' read -r ipv4 ipv6 <<<"$(get_connection_addresses)"
    while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        port=$(jq -r '.port' <<<"$record"); uuid=$(jq -r '.uuid // empty' <<<"$record")
        password=$(jq -r '.password // empty' <<<"$record"); username=$(jq -r '.username // empty' <<<"$record")
        sni=$(jq -r '.sni // .domain // .host // empty' <<<"$record")
        method=$(jq -r '.method // empty' <<<"$record"); psk=$(jq -r '.psk // empty' <<<"$record")
        public=$(jq -r '.public_key // empty' <<<"$record"); sid=$(jq -r '.short_id // empty' <<<"$record")
        prefix=$(tr '[:lower:]-' '[:upper:]_' <<<"$protocol")
        for label in V4 V6; do
            ip="$ipv4"; [[ "$label" != V6 ]] || ip="$ipv6"
            [[ -n "$ip" ]] || continue
            host="$ip"; [[ "$label" != V6 ]] || host="[$ip]"
            case "$protocol" in
                vless-singbox) data="REALITY|$host|$port|$uuid|$public|$sid|$sni"; link=$(gen_vless_link "$host" "$port" "$uuid" "$public" "$sid" "$sni") ;;
                hy2) data="HY2|$host|$port|$password|$sni"; link=$(gen_hy2_link "$host" "$port" "$password" "$sni") ;;
                tuic) data="TUIC|$host|$port|$uuid|$password|$sni"; link=$(gen_tuic_link "$host" "$port" "$uuid" "$password" "$sni") ;;
                anytls) data="ANYTLS|$host|$port|$password|$sni"; link=$(gen_anytls_link "$host" "$port" "$password" "$sni") ;;
                naive) data="NAIVE|$sni|$port|$username|$password"; link=$(gen_naive_link "$sni" "$port" "$username" "$password") ;;
                socks) data="SOCKS|$host|$port|$username|$password"; link="socks5://$username:$password@$host:$port" ;;
                ss2022|ss2022-shadowtls) data="SS2022|$host|$port|$method|$password"; link=$(gen_ss2022_link "$host" "$port" "$method" "$password") ;;
                ss-legacy) data="SS|$host|$port|$method|$password"; link=$(gen_ss_legacy_link "$host" "$port" "$method" "$password") ;;
                snell-v5) data="SNELL-V5|$host|$port|$psk|5"; link=$(gen_snell_link "$host" "$port" "$psk" 5) ;;
                snell-v6-singbox)
                    mode=$(jq -r '.mode // "default"' <<<"$record")
                    country=$(get_ip_country "$ip")
                    data="SNELL-V6|$host|$port|$psk|6|$mode"
                    link=$(gen_snell_link "$host" "$port" "$psk" 6 "$country" "$mode" singbox) ;;
                *) rm -f "$tmp"; return 1 ;;
            esac || { rm -f "$tmp"; return 1; }
            if [[ "$protocol" == ss2022-shadowtls ]]; then
                data="SS2022-SHADOWTLS|$host|$port|$method|$password|$(jq -r '.stls_password' <<<"$record")|$sni"
            fi
            printf '# %s PORT=%s\nJOIN_%s=%s\n%s_%s=%s\n' "$protocol" "$port" "$label" "$(printf '%s' "$data" | base64 -w 0)" "$prefix" "$label" "$link" >>"$tmp" || { rm -f "$tmp"; return 1; }
        done
    done <<<"$records"
    chmod 600 "$tmp" && mv "$tmp" "$output" || { rm -f "$tmp"; return 1; }
    [[ -n "$records" ]] || rm -f "$output" || return 1
    aggregate=$(mktemp "$CFG/.join-all.XXXXXX") || return 1
    for join in "$CFG"/*.join; do
        [[ -f "$join" ]] || continue
        cat "$join" >>"$aggregate" || { rm -f "$aggregate"; return 1; }
    done
    chmod 600 "$aggregate" && mv "$aggregate" "$CFG/join.txt" || { rm -f "$aggregate"; return 1; }
}


# 官方 Snell 每个版本只有一个独立监听实例；更新时完整替换该版本记录。
_validate_official_snell_candidate() {
    local protocol="$1" record="$2" candidate="$3" port psk mode dns dns_pref version
    port=$(jq -r '.port' <<<"$record") || return 1
    psk=$(jq -r '.psk' <<<"$record") || return 1
    version=$(jq -r '.version' <<<"$record") || return 1
    _is_valid_port "$port" && _is_safe_credential "$psk" &&
        [[ ${#psk} -ge 16 && ${#psk} -le 255 ]] || return 1
    case "$protocol:$version" in
        snell-v5-official:5) ;;
        snell-v6:6)
            mode=$(jq -r '.mode // "default"' <<<"$record")
            dns=$(jq -r '.dns // ""' <<<"$record")
            dns_pref=$(jq -r '.dns_ip_preference // "default"' <<<"$record")
            case "$mode" in default|unshaped|unsafe-raw) ;; *) return 1 ;; esac
            case "$dns_pref" in default|prefer-ipv4|prefer-ipv6|ipv4-only|ipv6-only) ;; *) return 1 ;; esac
            _is_valid_dns_server_list "$dns" || return 1
            ;;
        *) return 1 ;;
    esac
    # 官方核心没有离线 check 命令；严格验证记录和完整 INI，启动后再检查服务。
    cmp -s "$candidate" <(
        printf '[snell-server]\nlisten = %s\npsk = %s\n' "$(_fmt_hostport "$(_listen_addr)" "$port")" "$psk"
        if [[ "$protocol" == snell-v6 ]]; then
            printf 'mode = %s\n' "$mode"
            [[ -z "$dns" ]] || printf 'dns = %s\n' "$dns"
            printf 'dns-ip-preference = %s\n' "$dns_pref"
        fi
    )
}

_apply_official_snell_record() {
    local protocol="$1" record="$2" candidate="$3" result=0
    [[ "$protocol" == snell-v5-official || "$protocol" == snell-v6 ]] || return 1
    [[ -f "$DB_FILE" ]] || init_db || { rm -f "$candidate"; return 1; }
    _db_lock_acquire || { rm -f "$candidate"; return 1; }
    _apply_official_snell_record_locked "$protocol" "$record" "$candidate" || result=1
    _db_lock_release
    rm -f "$candidate"
    return "$result"
}

_apply_official_snell_record_locked() {
    local protocol="$1" record="$2" candidate="$3" snapshot file index=0 success=false
    local port psk mode version dns dns_pref tfo join aggregate aggregate_ok=true
    local service="${PROTO_SVC[$protocol]}" runtime_changed=false activation_attempted=false operation=start
    _validate_official_snell_candidate "$protocol" "$record" "$candidate" || return 1
    local -a files=("$DB_FILE" "$CFG/$protocol.conf" "$CFG/$protocol.join" "$CFG/join.txt" "$CFG/role"
        "$SYSTEMD_DIR/$service.service" "$OPENRC_DIR/$service"
        "$SYSTEMD_DIR/sing-watchdog.service" "$OPENRC_DIR/sing-watchdog")
    snapshot=$(mktemp -d "$CFG/.official-snell.XXXXXX") || return 1
    for file in "${files[@]}"; do
        if [[ -f "$file" ]] && ! cp -p "$file" "$snapshot/$index"; then
            rm -rf "$snapshot"; return 1
        fi
        index=$((index + 1))
    done
    svc status "$service" >/dev/null 2>&1 && touch "$snapshot/running"
    svc enabled "$service" >/dev/null 2>&1 && touch "$snapshot/enabled"
    port=$(jq -r '.port' <<<"$record"); psk=$(jq -r '.psk' <<<"$record")
    version=$(jq -r '.version' <<<"$record"); mode=$(jq -r '.mode // "default"' <<<"$record")
    dns=$(jq -r '.dns // ""' <<<"$record"); dns_pref=$(jq -r '.dns_ip_preference // "default"' <<<"$record")
    tfo=$(jq -r '.tfo // "true"' <<<"$record")
    if jq --arg p "$protocol" --argjson record "$record" '
        def records: if type == "array" then .[] elif type == "object" then . else empty end;
        if ([to_entries[] | select(.key == "singbox" or .key == "snell") |
            .key as $core | .value | to_entries[] | select($core != "snell" or .key != $p) |
            .value | records | select(.port == $record.port)] | length) > 0
        then error("duplicate port") else .snell[$p] = $record end
    ' "$DB_FILE" >"$snapshot/next-db.json" &&
       chmod 600 "$snapshot/next-db.json" "$candidate" &&
       mv "$snapshot/next-db.json" "$DB_FILE" && mv "$candidate" "$CFG/$protocol.conf"; then
        if [[ "$protocol" == snell-v6 ]]; then
            _save_join_info "$protocol" "SNELL-V6|%s|$port|$psk|6|$mode" \
                gen_snell_link "%s" "$port" "$psk" 6 "" "$mode" official \
                --extra "MODE=$mode" "DNS=${dns:-system}" "DNS_IP_PREFERENCE=$dns_pref" "TFO=$tfo" && success=true
        else
            _save_join_info "$protocol" "SNELL-V5|%s|$port|$psk|5" \
                gen_snell_link "%s" "$port" "$psk" 5 "" default official && success=true
        fi
        if [[ "$success" == true ]]; then
            success=false
            aggregate="$snapshot/join.txt"
            : >"$aggregate"
            for join in "$CFG"/*.join; do
                [[ -f "$join" ]] || continue
                cat "$join" >>"$aggregate" || { aggregate_ok=false; break; }
            done
            if [[ "$aggregate_ok" == true ]] && chmod 600 "$aggregate" && mv "$aggregate" "$CFG/join.txt" && printf '%s\n' server >"$CFG/role"; then
                success=true
            fi
        fi
    fi
    if [[ "$success" == true ]]; then
        success=false
        runtime_changed=true
        [[ ! -f "$snapshot/running" ]] || operation=restart
        if create_service "$protocol" && svc enable "$service"; then
            activation_attempted=true
            if svc "$operation" "$service" && _wait_for_owned_service "$service"; then
                success=true
            fi
        fi
    fi
    if [[ "$success" == true ]]; then
        unset INSTALL_MODE REPLACE_PORT
        rm -rf "$snapshot"
        return 0
    fi
    if [[ "$runtime_changed" == true ]]; then
        if [[ "$activation_attempted" == true ]] || svc status "$service" >/dev/null 2>&1; then
            svc stop "$service" || {
                if svc status "$service" >/dev/null 2>&1; then
                    _err "官方 Snell 停止失败，快照保留: $snapshot"; return 1
                fi
            }
        fi
        if [[ ! -f "$snapshot/enabled" ]] && svc enabled "$service" >/dev/null 2>&1; then
            svc disable "$service" || { _err "官方 Snell 自启恢复失败，快照保留: $snapshot"; return 1; }
        fi
    fi
    index=0
    for file in "${files[@]}"; do
        if [[ -f "$snapshot/$index" ]]; then
            cp -p "$snapshot/$index" "$file" || { _err "官方 Snell 恢复失败，快照保留: $snapshot"; return 1; }
        else
            rm -f "$file" || { _err "官方 Snell 恢复失败，快照保留: $snapshot"; return 1; }
        fi
        index=$((index + 1))
    done
    if [[ "$runtime_changed" == true ]]; then
        [[ "$DISTRO" == alpine ]] || systemctl daemon-reload || {
            _err "官方 Snell 服务恢复失败，快照保留: $snapshot"; return 1;
        }
        if [[ -f "$snapshot/enabled" ]]; then
            svc enable "$service" || { _err "官方 Snell 自启恢复失败，快照保留: $snapshot"; return 1; }
        fi
        if [[ -f "$snapshot/running" ]]; then
            svc start "$service" && _wait_for_owned_service "$service" || {
                _err "官方 Snell 运行状态恢复失败，快照保留: $snapshot"; return 1;
            }
        fi
    fi
    rm -rf "$snapshot"
    _err "官方 Snell 配置变更失败，已恢复原配置"
    return 1
}

gen_snell_v5_official_server_config() {
    local psk="$1" port="$2" record candidate
    mkdir -p "$CFG" || return 1
    _is_safe_credential "$psk" && [[ ${#psk} -ge 16 && ${#psk} -le 255 ]] || {
        _err "Snell PSK 必须为 16-255 位安全凭据字符"; return 1;
    }
    _is_valid_port "$port" || return 1
    candidate=$(mktemp "$CFG/.snell-v5-official.XXXXXX") || return 1
    {
        printf '[snell-server]\nlisten = %s\npsk = %s\n' "$(_fmt_hostport "$(_listen_addr)" "$port")" "$psk"
    } >"$candidate" || { rm -f "$candidate"; return 1; }
    record=$(_lite_build_config port "$port" version 5 | jq --arg psk "$psk" '.psk=$psk') || { rm -f "$candidate"; return 1; }
    _apply_official_snell_record snell-v5-official "$record" "$candidate"
}


gen_naive_server_config() {
    local username="$1" password="$2" port="$3" domain="$4" record
    [[ -s "$CFG/certs/server.crt" && -s "$CFG/certs/server.key" ]] || {
        _err "Naive 需要先申请域名 TLS 证书"; return 1;
    }
    record=$(_lite_build_config username "$username" password "$password" port "$port" domain "$domain") || return 1
    _lite_apply_protocol naive "$record"
}


# SS2022 + ShadowTLS 服务端配置
gen_ss2022_shadowtls_server_config() {
    local password="$1" port="$2" method="${3:-2022-blake3-aes-256-gcm}" sni="${4:-www.microsoft.com}" stls_password="$5" record
    record=$(_lite_build_config password "$password" port "$port" method "$method" sni "$sni" stls_password "$stls_password") || return 1
    _lite_apply_protocol ss2022-shadowtls "$record"
}

# SOCKS5 服务端配置
gen_socks_server_config() {
    local username="$1" password="$2" port="$3" use_tls="${4:-false}" sni="${5:-}"
    local auth_mode="${6:-password}" listen_addr="${7:-}"
    mkdir -p "$CFG"

    [[ "$use_tls" != true ]] || { _err "SOCKS5 仅支持明文"; return 1; }
    # 构建配置 JSON
    local config_json=""
    if [[ "$use_tls" == "true" ]]; then
        config_json=$(_lite_build_config username "$username" password "$password" port "$port" tls "true" sni "$sni" auth_mode "$auth_mode" listen_addr "$listen_addr")
    else
        config_json=$(_lite_build_config username "$username" password "$password" port "$port" auth_mode "$auth_mode" listen_addr "$listen_addr")
    fi
    _lite_apply_protocol "socks" "$config_json" || return 1
    echo "server" > "$CFG/role"
}

# Snell v5 服务端配置（由 Sing-box 共享服务承载）
gen_snell_v5_server_config() {
    local psk="$1" port="$2" version="${3:-5}" record
    mkdir -p "$CFG"
    record=$(_lite_build_config port "$port" version "$version" | jq --arg psk "$psk" '.psk=$psk') || return 1
    _apply_singbox_snell_change "${INSTALL_MODE:-add}" "${REPLACE_PORT:-all}" "$record" snell-v5 || return 1
    unset INSTALL_MODE REPLACE_PORT

    echo "server" > "$CFG/role"
}

# Snell v6 服务端配置（由 Sing-box 共享服务承载）
gen_singbox_snell_v6_server_config() {
    local psk="$1" port="$2" version="${3:-6}" mode="${4:-default}" record
    _is_valid_port "$port" || return 1
    _is_safe_credential "$psk" && [[ "$version" == 6 && ${#psk} -ge 12 && ${#psk} -le 255 ]] || {
        _err "无效的 Snell v6 版本或 PSK（长度应为 12–255）"; return 1;
    }
    case "$mode" in
        default|unshaped|unsafe-raw) ;;
        *) _err "无效的 Snell v6 混淆模式: $mode"; return 1 ;;
    esac
    mkdir -p "$CFG" || return 1
    record=$(_lite_build_config psk "$psk" port "$port" version "$version" mode "$mode") || return 1
    _validate_singbox_snell_record "$record" snell-v6-singbox || return 1
    _lite_apply_protocol snell-v6-singbox "$record"
}

# Snell v6 服务端配置
# v6.0.0 支持 listen、mode、dns、dns-ip-preference 和 egress-interface。
gen_snell_v6_server_config() {
    local psk="$1" port="$2" version="${3:-6}"
    local dns_pref="${4:-default}" dns_servers="${5:-}" mode="${6:-default}"
    local tfo="${7:-true}"
    mkdir -p "$CFG"

    _is_valid_port "$port" || return 1
    _is_safe_credential "$psk" && [[ "$version" == 6 && ${#psk} -ge 16 && ${#psk} -le 255 ]] || {
        _err "无效的 Snell v6 版本或 PSK"; return 1;
    }

    case "$dns_pref" in
        default|prefer-ipv4|prefer-ipv6|ipv4-only|ipv6-only) ;;
        *) _err "无效的 Snell v6 DNS IP 偏好: $dns_pref"; return 1 ;;
    esac
    case "$mode" in
        default|unshaped|unsafe-raw) ;;
        *) _err "无效的 Snell v6 混淆模式: $mode"; return 1 ;;
    esac
    [[ "$tfo" == "true" || "$tfo" == "false" ]] || {
        _err "无效的 Snell v6 TCP Fast Open 选项: $tfo"
        return 1
    }
    _is_valid_dns_server_list "$dns_servers" || {
        _err "无效的 Snell v6 DNS 服务器列表: $dns_servers"
        return 1
    }

    local listen_addr=$(_listen_addr) candidate record
    candidate=$(mktemp "$CFG/.snell-v6.XXXXXX") || return 1

    {
        printf '[snell-server]\n'
        printf 'listen = %s\n' "$(_fmt_hostport "$listen_addr" "$port")"
        printf 'psk = %s\n' "$psk"
        printf 'mode = %s\n' "$mode"
        [[ -n "$dns_servers" ]] && printf 'dns = %s\n' "$dns_servers"
        printf 'dns-ip-preference = %s\n' "$dns_pref"
    } > "$candidate" || { rm -f "$candidate"; return 1; }

    record=$(_lite_build_config \
        psk "$psk" port "$port" version "$version" \
        dns "$dns_servers" dns_ip_preference "$dns_pref" mode "$mode" tfo "$tfo") || { rm -f "$candidate"; return 1; }
    _apply_official_snell_record snell-v6 "$record" "$candidate"
}

# Sing-box Snell v5 使用共享协议 JOIN 重建路径。
regenerate_singbox_snell_join_info() {
    regenerate_singbox_protocol_join_info snell-v5
}

# 从所有 Sing-box VLESS 端口和启用用户重建 JOIN。
regenerate_singbox_vless_join_info() {
    regenerate_singbox_protocol_join_info vless-singbox
}

# VLESS 安装和卸载先校验共享配置；失败时恢复数据库、凭据和服务状态。
_apply_singbox_vless_config() {
    local protocol="${4:-vless-singbox}"
    local record="$1" action="${2:-${INSTALL_MODE:-add}}" old_port="${3:-${REPLACE_PORT:-}}" result=0
    [[ -f "$DB_FILE" ]] || init_db || return 1
    _db_lock_acquire || return 1
    _apply_singbox_vless_config_locked "$record" "$action" "$old_port" "$protocol" || result=1
    _db_lock_release
    return "$result"
}

_apply_singbox_vless_config_locked() {
    local record="$1" snapshot file index=0 runtime_changed=false success=false
    local action="$2" old_port="$3" protocol="${4:-vless-singbox}"
    [[ " $SINGBOX_PROTOCOLS " == *" $protocol "* ]] || return 1
    case "$action" in
        add|replace|remove) ;;
        *) return 1 ;;
    esac
    [[ "$action" == add || "$old_port" =~ ^[0-9]+$ || ( "$action" == remove && "$old_port" == all ) ]] || return 1
    local -a files=("$DB_FILE" "$CFG/singbox.json" "$CFG/$protocol.join"
        "$CFG/join.txt" "$CFG/role" "$SYSTEMD_DIR/sing-singbox.service" "$OPENRC_DIR/sing-singbox")
    snapshot=$(mktemp -d "$CFG/.singbox-vless.XXXXXX") || return 1
    for file in "${files[@]}"; do
        if [[ -f "$file" ]] && ! cp -p "$file" "$snapshot/$index"; then
            rm -rf "$snapshot"
            return 1
        fi
        index=$((index + 1))
    done
    svc status sing-singbox >/dev/null 2>&1 && touch "$snapshot/running"
    svc enabled sing-singbox >/dev/null 2>&1 && touch "$snapshot/enabled"
    local operation=start
    if jq --arg protocol "$protocol" --arg action "$action" --arg old "$old_port" --argjson record "$record" '
        def records: if type == "array" then .[] elif type == "object" then . else empty end;
        (.singbox[$protocol] // [] | [records]) as $current |
        if ($action != "add" and $old != "all" and
            ([$current[] | select((.port | tostring) == $old)] | length) != 1) or
           ($action == "remove" and ($current | length) == 0)
        then error("target missing")
        elif $action != "remove" and
             ([to_entries[] | select(.key == "singbox" or .key == "snell") |
               .key as $core | .value | to_entries[] | .key as $proto | .value | records |
               select(.port == $record.port) |
               select(($action == "replace" and $core == "singbox" and $proto == $protocol and (.port | tostring) == $old) | not)] | length) > 0
        then error("duplicate port")
        else
            (if $action == "add" then $current + [$record]
             elif $action == "replace" then [$current[] | if (.port | tostring) == $old then $record else . end]
             elif $old == "all" then []
             else [$current[] | select((.port | tostring) != $old)] end) as $next |
            if ($next | length) == 0 then del(.singbox[$protocol])
            else .singbox[$protocol] = $next end
        end
    ' "$DB_FILE" >"$snapshot/next-db.json" &&
       chmod 600 "$snapshot/next-db.json" && mv "$snapshot/next-db.json" "$DB_FILE"; then
        if [[ "$action" == remove && -z "$(get_singbox_protocols)" ]]; then
            if regenerate_singbox_protocol_join_info "$protocol"; then
                runtime_changed=true
                if svc stop sing-singbox &&
                   { [[ ! -f "$snapshot/enabled" ]] || svc disable sing-singbox; } &&
                   rm -f "$CFG/singbox.json" "$SYSTEMD_DIR/sing-singbox.service" "$OPENRC_DIR/sing-singbox" &&
                   { [[ "$DISTRO" == alpine ]] || systemctl daemon-reload; }; then
                    success=true
                fi
            fi
        elif generate_singbox_config "$snapshot/candidate.json" &&
             regenerate_singbox_protocol_join_info "$protocol" &&
             mv "$snapshot/candidate.json" "$CFG/singbox.json"; then
            runtime_changed=true
            [[ ! -f "$snapshot/running" ]] || operation=restart
            if create_singbox_service &&
               { [[ "$action" == remove ]] || svc enable sing-singbox; } &&
               { [[ "$action" == remove && ! -f "$snapshot/running" ]] ||
                 { svc "$operation" sing-singbox && _wait_for_singbox_ready; }; } &&
               { [[ "$action" == remove ]] || printf '%s\n' server >"$CFG/role"; }; then
                success=true
            fi
        fi
    fi
    if [[ "$success" == true ]]; then
        [[ "$action" == remove ]] || unset INSTALL_MODE REPLACE_PORT
        rm -rf "$snapshot"
        return 0
    fi
    if [[ "$runtime_changed" == true ]]; then
        # 最后一个入站卸载失败时，服务定义可能已删除；先判断是否仍需停止。
        if [[ -f "$SYSTEMD_DIR/sing-singbox.service" || -f "$OPENRC_DIR/sing-singbox" ]] ||
           svc status sing-singbox >/dev/null 2>&1; then
            svc stop sing-singbox || { _err "Sing-box 停止失败，恢复快照保留: $snapshot"; return 1; }
        fi
        if [[ ! -f "$snapshot/enabled" &&
              ( -f "$SYSTEMD_DIR/sing-singbox.service" || -f "$OPENRC_DIR/sing-singbox" ) ]] &&
           svc enabled sing-singbox >/dev/null 2>&1 &&
           ! svc disable sing-singbox; then
            _err "服务自启状态恢复失败，快照保留: $snapshot"
            return 1
        fi
    fi
    index=0
    for file in "${files[@]}"; do
        if [[ -f "$snapshot/$index" ]]; then
            cp -p "$snapshot/$index" "$file" || { _err "恢复失败，快照保留: $snapshot"; return 1; }
        else
            rm -f "$file" || { _err "恢复失败，快照保留: $snapshot"; return 1; }
        fi
        index=$((index + 1))
    done
    if [[ "$runtime_changed" == true ]]; then
        if [[ "$DISTRO" != alpine ]]; then
            systemctl daemon-reload || { _err "服务恢复失败，快照保留: $snapshot"; return 1; }
        fi
        if [[ -f "$snapshot/enabled" ]]; then
            svc enable sing-singbox || { _err "服务恢复失败，快照保留: $snapshot"; return 1; }
        fi
        if [[ -f "$snapshot/running" ]]; then
            if ! svc start sing-singbox || ! _wait_for_singbox_ready; then
                _err "服务恢复失败，快照保留: $snapshot"
                return 1
            fi
        fi
    fi
    rm -rf "$snapshot"
    _err "Sing-box 协议变更失败，已恢复原配置"
    return 1
}

# 仅快照共享 Sing-box 所拥有的资源；官方服务和官方配置不在事务范围内。

_apply_singbox_snell_change() {
    _apply_singbox_vless_config "$3" "$1" "$2" "${4:-snell-v5}"
}

_apply_singbox_snell_change_locked() {
    _apply_singbox_vless_config_locked "$3" "$1" "$2" "${4:-snell-v5}"
}


#═══════════════════════════════════════════════════════════════════════════════
# 服务端辅助脚本生成
#═══════════════════════════════════════════════════════════════════════════════
create_server_scripts() {
    # Watchdog 脚本 - 服务端监控进程（带重启次数限制）
    cat > "$CFG/watchdog.sh" << 'EOFSCRIPT'
#!/bin/bash
umask 077
CFG="/etc/sing-lite"
export PATH="$CFG/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LOG_FILE="/var/log/sing-watchdog.log"
MAX_RESTARTS=5           # 冷却期内最大重启次数
COOLDOWN_PERIOD=300      # 冷却期（秒）
declare -A restart_counts
declare -A first_restart_time

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    # 日志轮转：超过 2MB 时截断
    local size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ $size -gt 2097152 ]]; then
        local rotated
        rotated=$(mktemp "${LOG_FILE}.rotate.XXXXXX") || return
        if tail -n 500 "$LOG_FILE" >"$rotated"; then
            chmod 600 "$rotated"
            mv "$rotated" "$LOG_FILE"
        else
            rm -f "$rotated"
        fi
    fi
}

restart_service() {
    local svc="$1"
    local now=$(date +%s)
    local first_time=${first_restart_time[$svc]:-0}
    local count=${restart_counts[$svc]:-0}

    # 检查是否在冷却期内
    if [[ $((now - first_time)) -gt $COOLDOWN_PERIOD ]]; then
        # 冷却期已过，重置计数
        restart_counts[$svc]=1
        first_restart_time[$svc]=$now
    else
        # 仍在冷却期内
        ((count++))
        restart_counts[$svc]=$count

        if [[ $count -gt $MAX_RESTARTS ]]; then
            log "ERROR: $svc 在 ${COOLDOWN_PERIOD}s 内重启次数超过 $MAX_RESTARTS 次，暂停监控该服务"
            return 1
        fi
    fi

    log "INFO: 正在重启 $svc (第 ${restart_counts[$svc]} 次)"

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl restart "$svc" 2>&1; then
            log "OK: $svc 重启成功"
            return 0
        else
            log "ERROR: $svc 重启失败"
            return 1
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        if rc-service "$svc" restart 2>&1; then
            log "OK: $svc 重启成功"
            return 0
        else
            log "ERROR: $svc 重启失败"
            return 1
        fi
    else
        log "ERROR: 无法找到服务管理命令"
        return 1
    fi
}

# 获取所有需要监控的服务 (支持多协议) - 从数据库读取
get_all_services() {
    local DB_FILE="$CFG/db.json"
    [[ -f "$DB_FILE" && ! -f "$CFG/paused" ]] || return 0
    jq -e '(.singbox // {}) | length > 0' "$DB_FILE" >/dev/null 2>&1 && printf '%s\n' sing-singbox:sing-box
    jq -e '.snell["snell-v5-official"] != null' "$DB_FILE" >/dev/null 2>&1 && printf '%s\n' sing-snell-v5-official:snell-server-v5
    jq -e '.snell["snell-v6"] != null' "$DB_FILE" >/dev/null 2>&1 && printf '%s\n' sing-snell-v6:snell-server-v6
}

log "INFO: Watchdog 启动"

while true; do
    for svc_info in $(get_all_services); do
        IFS=':' read -r svc_name proc_name <<< "$svc_info"
        # 多种方式检测进程 (使用兼容函数)
        if { command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet "$svc_name"; } ||
           { ! command -v systemctl >/dev/null 2>&1 && ! rc-service "$svc_name" status >/dev/null 2>&1; }; then
            if [[ "$svc_name" == "sing-singbox" ]] && ! sing-box check -c "$CFG/singbox.json" >/dev/null 2>&1; then
                log "ERROR: Sing-box 配置校验失败，跳过重启 $svc_name"
                continue
            fi
            log "CRITICAL: $proc_name 进程不存在，尝试重启 $svc_name..."
            restart_service "$svc_name"
            sleep 5
        fi
    done
    sleep 60
done
EOFSCRIPT

    # Hysteria2 端口跳跃规则脚本 (服务端) - 从数据库读取
    if is_protocol_installed "hy2"; then
        cat > "$CFG/hy2-nat.sh" << 'EOFSCRIPT'
#!/bin/bash
CFG=/etc/sing-lite
DB_FILE="$CFG/db.json"

[[ ! -f "$DB_FILE" ]] && exit 0

# 检查 iptables 是否存在
if ! command -v iptables &>/dev/null; then
    echo "[hy2-nat] iptables 未安装，端口跳跃不可用" >&2
    exit 1
fi

# 从数据库读取配置
port=$(jq -r '.singbox.hy2.port // empty' "$DB_FILE" 2>/dev/null)
hop_enable=$(jq -r '.singbox.hy2.hop_enable // empty' "$DB_FILE" 2>/dev/null)
hop_start=$(jq -r '.singbox.hy2.hop_start // empty' "$DB_FILE" 2>/dev/null)
hop_end=$(jq -r '.singbox.hy2.hop_end // empty' "$DB_FILE" 2>/dev/null)

[[ -z "$port" ]] && exit 0

hop_start="${hop_start:-20000}"
hop_end="${hop_end:-50000}"

if ! [[ "$port" =~ ^[0-9]+$ && "$hop_start" =~ ^[0-9]+$ && "$hop_end" =~ ^[0-9]+$ ]]; then
  exit 0
fi
port=$((10#$port)); hop_start=$((10#$hop_start)); hop_end=$((10#$hop_end))
if (( port < 1 || port > 65535 || hop_start < 1 || hop_end > 65535 || hop_start >= hop_end )); then
  exit 0
fi

# 清理旧规则 (IPv4)
iptables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-hy2-hop -j REDIRECT --to-ports $port 2>/dev/null
iptables -t nat -D OUTPUT -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-hy2-hop -j REDIRECT --to-ports $port 2>/dev/null
# 清理旧规则 (IPv6)
ip6tables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-hy2-hop -j REDIRECT --to-ports $port 2>/dev/null
ip6tables -t nat -D OUTPUT -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-hy2-hop -j REDIRECT --to-ports $port 2>/dev/null
ip6tables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null
ip6tables -t nat -D OUTPUT -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null

[[ "${hop_enable:-0}" != "1" ]] && exit 0

# 添加规则 (IPv4)
iptables -t nat -C PREROUTING -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-hy2-hop -j REDIRECT --to-ports $port 2>/dev/null \
  || iptables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-hy2-hop -j REDIRECT --to-ports $port
iptables -t nat -C OUTPUT -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-hy2-hop -j REDIRECT --to-ports $port 2>/dev/null \
  || iptables -t nat -A OUTPUT -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-hy2-hop -j REDIRECT --to-ports $port

# 添加规则 (IPv6)
ip6tables -t nat -C PREROUTING -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-hy2-hop -j REDIRECT --to-ports $port 2>/dev/null \
  || ip6tables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-hy2-hop -j REDIRECT --to-ports $port
ip6tables -t nat -C OUTPUT -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-hy2-hop -j REDIRECT --to-ports $port 2>/dev/null \
  || ip6tables -t nat -A OUTPUT -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-hy2-hop -j REDIRECT --to-ports $port
EOFSCRIPT
    fi

    # TUIC 端口跳跃规则脚本 (服务端) - 从数据库读取
    if is_protocol_installed "tuic"; then
        cat > "$CFG/tuic-nat.sh" << 'EOFSCRIPT'
#!/bin/bash
CFG=/etc/sing-lite
DB_FILE="$CFG/db.json"

[[ ! -f "$DB_FILE" ]] && exit 0

# 检查 iptables 是否存在
if ! command -v iptables &>/dev/null; then
    echo "[tuic-nat] iptables 未安装，端口跳跃不可用" >&2
    exit 1
fi

# 从数据库读取配置
port=$(jq -r '.singbox.tuic.port // empty' "$DB_FILE" 2>/dev/null)
hop_enable=$(jq -r '.singbox.tuic.hop_enable // empty' "$DB_FILE" 2>/dev/null)
hop_start=$(jq -r '.singbox.tuic.hop_start // empty' "$DB_FILE" 2>/dev/null)
hop_end=$(jq -r '.singbox.tuic.hop_end // empty' "$DB_FILE" 2>/dev/null)

[[ -z "$port" ]] && exit 0

hop_start="${hop_start:-20000}"
hop_end="${hop_end:-50000}"

if ! [[ "$port" =~ ^[0-9]+$ && "$hop_start" =~ ^[0-9]+$ && "$hop_end" =~ ^[0-9]+$ ]]; then
  exit 0
fi
port=$((10#$port)); hop_start=$((10#$hop_start)); hop_end=$((10#$hop_end))
if (( port < 1 || port > 65535 || hop_start < 1 || hop_end > 65535 || hop_start >= hop_end )); then
  exit 0
fi

# 清理旧规则 (IPv4)
iptables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-tuic-hop -j REDIRECT --to-ports $port 2>/dev/null
iptables -t nat -D OUTPUT -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-tuic-hop -j REDIRECT --to-ports $port 2>/dev/null
# 清理旧规则 (IPv6)
ip6tables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-tuic-hop -j REDIRECT --to-ports $port 2>/dev/null
ip6tables -t nat -D OUTPUT -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-tuic-hop -j REDIRECT --to-ports $port 2>/dev/null
ip6tables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null
ip6tables -t nat -D OUTPUT -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null

[[ "${hop_enable:-0}" != "1" ]] && exit 0

# 添加规则 (IPv4)
iptables -t nat -C PREROUTING -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-tuic-hop -j REDIRECT --to-ports $port 2>/dev/null \
  || iptables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-tuic-hop -j REDIRECT --to-ports $port
iptables -t nat -C OUTPUT -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-tuic-hop -j REDIRECT --to-ports $port 2>/dev/null \
  || iptables -t nat -A OUTPUT -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-tuic-hop -j REDIRECT --to-ports $port

# 添加规则 (IPv6)
ip6tables -t nat -C PREROUTING -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-tuic-hop -j REDIRECT --to-ports $port 2>/dev/null \
  || ip6tables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-tuic-hop -j REDIRECT --to-ports $port
ip6tables -t nat -C OUTPUT -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-tuic-hop -j REDIRECT --to-ports $port 2>/dev/null \
  || ip6tables -t nat -A OUTPUT -p udp --dport ${hop_start}:${hop_end} -m comment --comment vless-tuic-hop -j REDIRECT --to-ports $port
EOFSCRIPT
    fi

    chmod +x "$CFG"/*.sh 2>/dev/null
}

#═══════════════════════════════════════════════════════════════════════════════
# 服务管理
#═══════════════════════════════════════════════════════════════════════════════
create_service() {
    local protocol="${1:-$(get_protocol)}" service binary config
    protocol_core "$protocol" >/dev/null || return 1
    if [[ "${PROTO_KIND[$protocol]}" == singbox ]]; then create_singbox_service; return; fi
    db_exists snell "$protocol" || { _err 'Snell 配置不存在'; return 1; }
    service="${PROTO_SVC[$protocol]}"
    binary=$(_core_binary_path "${PROTO_BIN[$protocol]}") || return 1
    config="$CFG/${protocol}.conf"
    if [[ "$DISTRO" == alpine ]]; then
        cat >"$OPENRC_DIR/$service" <<EOF || return 1
#!/sbin/openrc-run
name="Official Snell ($protocol)"
command="$binary"
command_args="-c $config"
command_background="yes"
pidfile="/run/$service.pid"
output_log="/var/log/$service.log"
error_log="/var/log/$service.log"
depend() { need net localmount; after firewall; }
EOF
        chmod 755 "$OPENRC_DIR/$service" || return 1
    else
        cat >"$SYSTEMD_DIR/$service.service" <<EOF || return 1
[Unit]
Description=Official Snell ($protocol)
After=network.target
[Service]
Type=simple
ExecStart=$binary -c $config
Restart=always
RestartSec=3
LimitNOFILE=51200
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload || return 1
    fi
    create_watchdog_service
}
svc() { # svc action service_name
    local action="$1" name="$2"
    _svc_try() {
        local err
        err=$(mktemp "${TMPDIR:-/tmp}/vless-svc.XXXXXX") || return 1
        "$@" 2>"$err" || {
            [[ -s "$err" ]] && { _err "服务${action}失败:"; cat "$err"; }
            rm -f "$err"
            return 1
        }
        rm -f "$err"
    }

    if [[ "$DISTRO" == "alpine" ]]; then
        case "$action" in
            start|restart) _svc_try rc-service "$name" "$action" ;;
            stop)    rc-service "$name" stop &>/dev/null ;;
            enable)  rc-update add "$name" default &>/dev/null ;;
            disable) rc-update del "$name" default &>/dev/null ;;
            enabled) rc-update show default 2>/dev/null | grep -Eq "^[[:space:]]*${name}[[:space:]]" ;;
            reload)  rc-service "$name" reload &>/dev/null || rc-service "$name" restart &>/dev/null ;;
            status)
                rc-service "$name" status &>/dev/null && return 0
                local pidfile="/run/${name}.pid"
                [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null && return 0
                return 1
                ;;
        esac
    else
        case "$action" in
            start|restart)
                _svc_try systemctl "$action" "$name" || { _err "详细状态信息:"; systemctl status "$name" --no-pager -l || true; return 1; }
                ;;
            stop|enable|disable) systemctl "$action" "$name" &>/dev/null ;;
            enabled) systemctl is-enabled --quiet "$name" &>/dev/null ;;
            reload) systemctl reload "$name" &>/dev/null || systemctl restart "$name" &>/dev/null ;;
            status)
                local state; state=$(systemctl is-active "$name" 2>/dev/null)
                [[ "$state" == active || "$state" == activating ]]
                ;;
        esac
    fi
}

# 只查询服务自己的 PID；不要用进程名匹配其他实例。
_runtime_config_service_pid() {
    local name="$1" pid
    if [[ "${DISTRO:-}" == alpine ]]; then
        if [[ -f "/run/${name}.pid" ]]; then
            IFS= read -r pid < "/run/${name}.pid" || return 1
        elif rc-service "$name" status >/dev/null 2>&1; then
            return 1
        else
            pid=0
        fi
    else
        pid=$(systemctl show "$name" --property=MainPID --value 2>/dev/null) || return 1
    fi
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$pid"
}

# 单独封装以便测试使用临时 /proc，不接触真实服务。
_runtime_config_proc_root() { printf '/proc\n'; }

_runtime_config_cat() {
    local file="$1"
    printf '\n===== 配置文件：%s =====\n' "$file"
    if [[ ! -f "$file" || ! -r "$file" ]]; then
        printf '无法读取配置文件：%s\n' "$file"
        return 1
    fi
    cat -- "$file" || return 1
    printf '\n===== 文件结束 =====\n'
}

# 只读磁盘原文件，不调用日志、配置生成或服务启动函数。
show_runtime_config() {
    local core="$1" name binary default_file pid proc_root exe expected arg value kind i
    local cwd file entry found result=0
    local -a argv=() paths=() kinds=()
    case "$core" in
        singbox) name=sing-singbox; binary=$CFG/bin/sing-box; default_file="$CFG/singbox.json" ;;
        snell-v5-official) name=sing-snell-v5-official; binary=$(_core_binary_path snell-server-v5); default_file="$CFG/snell-v5-official.conf" ;;
        snell-v6) name=sing-snell-v6; binary=$(_core_binary_path snell-server-v6); default_file="$CFG/snell-v6.conf" ;;
        *) printf '未知核心：%s\n' "$core"; return 1 ;;
    esac
    printf '磁盘文件可能与进程已载入内存的配置不同。\n'
    if ! pid=$(_runtime_config_service_pid "$name"); then
        printf '无法确定 %s 服务 PID，未读取配置。\n' "$name"
        return 1
    fi
    proc_root=$(_runtime_config_proc_root)
    if [[ "$pid" == 0 || ! -d "$proc_root/$pid" ]]; then
        printf '%s 未运行；以下为本脚本默认配置文件（未运行）。\n' "$name"
        _runtime_config_cat "$default_file"
        return $?
    fi
    exe=$(readlink "$proc_root/$pid/exe") || {
        printf '无法读取进程 %s 的可执行文件，未读取配置。\n' "$pid"; return 1;
    }
    expected=$(readlink -f "$binary" 2>/dev/null) || expected="$binary"
    # 升级后 Linux 会给旧进程的 exe 加上此后缀。
    if [[ "${exe% (deleted)}" != "$expected" ]]; then
        printf '服务 PID %s 不是本脚本管理的 %s，未读取配置。\n' "$pid" "$binary"
        return 1
    fi
    if [[ ! -r "$proc_root/$pid/cmdline" ]]; then
        printf '无法读取进程 %s 的启动参数。\n' "$pid"; return 1
    fi
    while IFS= read -r -d '' arg; do argv+=("$arg"); done < "$proc_root/$pid/cmdline"
    [[ ${#argv[@]} -gt 0 ]] || { printf '进程启动参数为空。\n'; return 1; }
    for ((i=1; i<${#argv[@]}; i++)); do
        arg="${argv[i]}"
        case "$arg" in
            -c|-config|--config|-f|-C|--config-directory|-confdir)
                kind=file
                case "$arg" in -C|--config-directory|-confdir) kind=directory ;; esac
                if ((i+1 >= ${#argv[@]})) || [[ -z "${argv[i+1]}" ]]; then
                    printf '配置参数缺少路径：%s\n' "$arg"; return 1
                fi
                i=$((i+1)); value="${argv[i]}"
                ;;
            -c=*|-config=*|--config=*|-f=*|-C=*|--config-directory=*|-confdir=*)
                value="${arg#*=}"; kind=file
                case "${arg%%=*}" in -C|--config-directory|-confdir) kind=directory ;; esac
                [[ -n "$value" ]] || { printf '配置参数缺少路径：%s\n' "$arg"; return 1; }
                ;;
            *) continue ;;
        esac
        paths+=("$value"); kinds+=("$kind")
    done
    if [[ ${#paths[@]} -eq 0 ]]; then
        printf '进程 %s 未指定配置文件或配置目录，无法确定配置来源。\n' "$pid"
        return 1
    fi
    printf '%s 正在运行，PID：%s\n' "$name" "$pid"
    for ((i=0; i<${#paths[@]}; i++)); do
        file="${paths[i]}"
        if [[ "$file" != /* ]]; then
            cwd=$(readlink "$proc_root/$pid/cwd") || {
                printf '无法确定相对配置路径的工作目录：%s\n' "$file"; result=1; continue;
            }
            file="$cwd/$file"
        fi
        if [[ "${kinds[i]}" == file ]]; then
            _runtime_config_cat "$file" || result=1
            continue
        fi
        printf '\n配置目录：%s（列出直接包含的全部文件；核心可能忽略部分文件）\n' "$file"
        if [[ ! -d "$file" || ! -r "$file" || ! -x "$file" ]]; then
            printf '无法读取配置目录：%s\n' "$file"; result=1; continue
        fi
        found=false
        for entry in "$file"/* "$file"/.[!.]* "$file"/..?*; do
            [[ -e "$entry" || -L "$entry" ]] || continue
            found=true
            if [[ -d "$entry" ]]; then
                printf '子目录未展开：%s\n' "$entry"
            else
                _runtime_config_cat "$entry" || result=1
            fi
        done
        [[ "$found" == true ]] || printf '配置目录为空。\n'
    done
    return "$result"
}

view_runtime_config_menu() {
    local choice
    while true; do
        _header
        printf '  查看运行配置文件\n'
        _line
        _item "1" "Sing-box 完整配置"
        _item "2" "官方 Snell v5 配置"
        _item "3" "官方 Snell v6 配置"
        _item "0" "返回"
        read -rp "  请选择: " choice || return
        case "$choice" in
            1) show_runtime_config singbox; _pause ;;
            2) show_runtime_config snell-v5-official; _pause ;;
            3) show_runtime_config snell-v6; _pause ;;
            0) return ;;
            *) _err "无效选择"; _pause ;;
        esac
    done
}

# 通用服务启动/重启辅助函数
# 用法: _start_core_service "服务名" "进程名" "协议列表" "配置生成函数"
_start_core_service() {
    local service_name="$1"
    local process_name="$2"
    local protocols="$3"
    local gen_config_func="$4"

    local is_running=false
    svc status "$service_name" >/dev/null 2>&1 && is_running=true

    local action_word="启动"
    [[ "$is_running" == "true" ]] && action_word="更新"

    _info "${action_word} ${process_name} 配置..."

    # 运行中的共享核心复用候选配置和失败回滚，校验完成前不停止代理。
    if [[ "$service_name" == sing-singbox && "$is_running" == true ]]; then
        if ! _regenerate_singbox_routing_config; then
            _err "${process_name} 配置更新或重启失败，请检查上方错误信息"
            return 1
        fi
        svc enable "$service_name" 2>/dev/null
        _ok "${process_name} 服务已更新 (协议: ${protocols//$'\n'/ })"
        return 0
    fi

    if ! $gen_config_func; then
        _err "${process_name} 配置生成失败"
        return 1
    fi

    svc enable "$service_name" 2>/dev/null

    local svc_action="start"
    [[ "$is_running" == "true" ]] && svc_action="restart"

    if ! svc $svc_action "$service_name"; then
        _err "${process_name} 服务${action_word}失败"
        return 1
    fi

    if [[ "$service_name" == sing-singbox ]]; then
        if ! _wait_for_singbox_ready; then
            _err "${process_name} 服务未就绪，请检查服务状态和监听端口"
            return 1
        fi
        _ok "${process_name} 服务已${action_word} (协议: ${protocols//$'\n'/ })"
        return 0
    fi

    # 等待服务启动。OpenRC 的 PID 文件/服务状态比精简 Alpine 中可能缺失的
    # pgrep 更可靠；同时保留进程检测以兼容非标准服务管理环境。
    local wait_count=0
    local max_wait=$([[ "$is_running" == "true" ]] && echo 5 || echo 10)
    while [[ $wait_count -lt $max_wait ]]; do
        if svc status "$service_name" >/dev/null 2>&1 || _pgrep "$process_name"; then
            local proto_list=$(echo $protocols | tr '\n' ' ')
            _ok "${process_name} 服务已${action_word} (协议: $proto_list)"
            return 0
        fi
        sleep 1
        ((wait_count++))
    done

    _err "${process_name} 进程未运行"
    return 1
}

start_services() {
    local protocols protocol service action failures=0
    init_db || return 1
    rm -f "$CFG/paused" || return 1
    create_server_scripts || return 1
    protocols=$(get_singbox_protocols)
    if [[ -n "$protocols" ]]; then
        if ! install_singbox || ! create_singbox_service ||
           ! _start_core_service sing-singbox sing-box "$protocols" generate_singbox_config; then
            failures=$((failures+1))
        fi
    fi
    for protocol in $(get_standalone_protocols); do
        service="${PROTO_SVC[$protocol]}"
        case "$protocol" in
            snell-v5-official) install_snell_v5 || { failures=$((failures+1)); continue; } ;;
            snell-v6) install_snell_v6 || { failures=$((failures+1)); continue; } ;;
        esac
        create_service "$protocol" || { failures=$((failures+1)); continue; }
        action=start
        svc status "$service" >/dev/null 2>&1 && action=restart
        if ! svc enable "$service" || ! svc "$action" "$service" || ! _wait_for_owned_service "$service"; then
            failures=$((failures+1))
        fi
    done
    if ! create_watchdog_service || ! svc enable sing-watchdog || ! svc start sing-watchdog; then failures=$((failures+1)); fi
    ((failures == 0)) || { _err "$failures 个服务启动失败"; return 1; }
}
ensure_singbox_runtime_consistency() {
    local singbox_protocols=$(get_singbox_protocols)
    [[ -z "$singbox_protocols" ]] && return 0
    is_paused && return 0
    check_cmd sing-box || return 0

    local need_rebuild=false
    [[ ! -f "$CFG/singbox.json" ]] && need_rebuild=true

    if [[ "$need_rebuild" == "false" ]] && ! validate_singbox_config "$CFG/singbox.json" >/dev/null 2>&1; then
        need_rebuild=true
    fi

    if [[ "$need_rebuild" == "true" ]]; then
        _info "检测到 Sing-box 配置缺失或无效，正在自动重建..."
        generate_singbox_config || return 1
        create_server_scripts
        create_singbox_service || return 1
        svc enable sing-singbox >/dev/null 2>&1 || return 1
        svc restart sing-singbox || svc start sing-singbox || return 1
        _wait_for_singbox_ready || return 1
        _ok "Sing-box 配置已自动修复"
    fi
}

owned_services() {
    printf '%s\n' sing-watchdog sing-singbox sing-snell-v5-official sing-snell-v6
}

stop_services() {
    local service failures=0
    for service in $(owned_services); do
        if svc status "$service" >/dev/null 2>&1; then
            svc stop "$service" || failures=$((failures+1))
        fi
    done
    cleanup_hy2_nat_rules
    ((failures == 0))
}
_auto_update_system_script() {
    local system_script="/usr/local/bin/sing-lite.sh"
    local current_script="$0"

    # 获取当前脚本的绝对路径
    local real_path=""
    if [[ "$current_script" == /* ]]; then
        real_path="$current_script"
    elif [[ "$current_script" != "bash" && "$current_script" != "-bash" && -f "$current_script" ]]; then
        real_path="$(cd "$(dirname "$current_script")" 2>/dev/null && pwd)/$(basename "$current_script")"
    fi

    # 如果当前脚本不是系统脚本，检查是否需要更新
    if [[ -n "$real_path" && -f "$real_path" && "$real_path" != "$system_script" ]]; then
        local need_update=false

        if [[ ! -f "$system_script" ]]; then
            need_update=true
        else
            # 用 md5 校验文件内容是否不同
            local cur_md5 sys_md5
            cur_md5=$(md5sum "$real_path" 2>/dev/null | cut -d' ' -f1)
            sys_md5=$(md5sum "$system_script" 2>/dev/null | cut -d' ' -f1)
            [[ "$cur_md5" != "$sys_md5" ]] && need_update=true
        fi

        if [[ "$need_update" == "true" ]]; then
            if ! install -m 755 "$real_path" "$system_script" 2>/dev/null; then
                _warn "系统脚本同步失败，保留现有快捷命令"
                return 1
            fi
            ln -sf "$system_script" /usr/local/bin/sing 2>/dev/null || return 1
            ln -sf "$system_script" /usr/bin/sing 2>/dev/null || return 1
            hash -r 2>/dev/null
            _ok "系统脚本已同步更新 (v$VERSION)"
        fi
    fi
}

create_shortcut() {
    local system_script="/usr/local/bin/sing-lite.sh"
    local current_script="$0"

    # 获取当前脚本的绝对路径（解析软链接）
    local real_path
    if [[ "$current_script" == /* ]]; then
        # 解析软链接获取真实路径
        real_path=$(readlink -f "$current_script" 2>/dev/null || echo "$current_script")
    elif [[ "$current_script" == "bash" || "$current_script" == "-bash" ]]; then
        # 从标准输入运行时没有可复制的本地脚本路径。
        real_path=""
    else
        real_path="$(cd "$(dirname "$current_script")" 2>/dev/null && pwd)/$(basename "$current_script")"
        # 解析软链接
        real_path=$(readlink -f "$real_path" 2>/dev/null || echo "$real_path")
    fi

    # 如果系统目录没有脚本，需要创建
    if [[ ! -f "$system_script" ]]; then
        if [[ -n "$real_path" && -f "$real_path" ]]; then
            # 从当前脚本复制（不删除原文件）
            install -m 755 "$real_path" "$system_script" || {
                _err "无法安装系统脚本"
                return 1
            }
        else
            # 内存运行模式，从网络下载
            if ! _download_script_to "$system_script"; then
                _warn "无法下载脚本到系统目录"
                return 1
            fi
        fi
    elif [[ -n "$real_path" && -f "$real_path" && "$real_path" != "$system_script" ]]; then
        # 系统目录已有脚本，用当前脚本更新（不删除原文件）
        install -m 755 "$real_path" "$system_script" || {
            _err "无法更新系统脚本"
            return 1
        }
    fi

    chmod 755 "$system_script" 2>/dev/null || return 1

    # 创建软链接
    ln -sf "$system_script" /usr/local/bin/sing 2>/dev/null || return 1
    ln -sf "$system_script" /usr/bin/sing 2>/dev/null || return 1
    hash -r 2>/dev/null

    _ok "快捷命令已创建: sing"
}

remove_shortcut() {
    rm -f /usr/local/bin/sing /usr/local/bin/sing-lite.sh /usr/bin/sing 2>/dev/null
    _ok "快捷命令已移除"
}


#═══════════════════════════════════════════════════════════════════════════════
# 分流管理 (WARP + 路由规则) - 双模式支持
# 模式 1: WGCF (Xray 内置 WireGuard) - UDP 协议，性能好但可能被封锁
# 模式 2: 官方客户端 (SOCKS5 代理) - TCP 协议，绕过 UDP 封锁
#═══════════════════════════════════════════════════════════════════════════════

# WARP 配置存储路径
WARP_CONF_FILE="$CFG/warp.json"
WARP_OFFICIAL_PORT=40000  # 官方客户端 SOCKS5 端口

# 保存 WARP 模式到数据库 (wgcf 或 official)
db_set_warp_mode() {
    local mode="$1"
    [[ ! -f "$DB_FILE" ]] && init_db
    _db_apply --arg m "$mode" '.routing.warp_mode = $m' || return 1
    : >"$CFG/.managed_warp"
}

# 获取 WARP 模式
db_get_warp_mode() {
    [[ ! -f "$DB_FILE" ]] && echo "wgcf" && return
    local mode=$(jq -r '.routing.warp_mode // "wgcf"' "$DB_FILE" 2>/dev/null)
    echo "$mode"
}

# WARP 状态检测 (支持双模式)
warp_status() {
    local mode=$(db_get_warp_mode)

    if [[ "$mode" == "official" ]]; then
        # 检查官方客户端状态
        if check_cmd warp-cli; then
            local status_output=$(warp-cli status 2>/dev/null)
            if echo "$status_output" | grep -qiE "Connected|Status:.*Connected"; then
                echo "connected"
                return
            elif echo "$status_output" | grep -qiE "Registration|Account|Disconnected|Status:"; then
                echo "registered"
                return
            fi
        fi
        echo "not_configured"
    else
        # 检查 WGCF 配置
        if [[ -f "$WARP_CONF_FILE" ]]; then
            local private_key=$(jq -r '.private_key // empty' "$WARP_CONF_FILE" 2>/dev/null)
            if [[ -n "$private_key" ]]; then
                echo "configured"
                return
            fi
        fi
        echo "not_configured"
    fi
}

# 下载 wgcf 工具
download_wgcf() {
    # 检查 file 命令是否存在，不存在则尝试安装
    if ! command -v file &>/dev/null; then
        echo -ne "  ${C}▸${NC} 检测到缺少 file 命令，正在安装..."
        if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
            apt-get update -qq && apt-get install -y file >/dev/null 2>&1
        elif [[ "$DISTRO" == "centos" ]]; then
            yum install -y file >/dev/null 2>&1
        elif [[ "$DISTRO" == "alpine" ]]; then
            apk add --no-cache file >/dev/null 2>&1
        fi

        if command -v file &>/dev/null; then
            echo -e " ${G}✓${NC}"
        else
            echo -e " ${Y}⚠${NC}"
            echo -e "  ${Y}提示${NC}: file 命令安装失败，将使用简化验证（仅检查文件大小）"
        fi
    fi

    # 检查是否已存在有效的 wgcf
    if [[ -x /usr/local/bin/wgcf ]]; then
        if command -v file &>/dev/null && file "/usr/local/bin/wgcf" 2>/dev/null | grep -q "ELF"; then
            return 0
        elif ! command -v file &>/dev/null && [[ -s /usr/local/bin/wgcf ]] && [[ $(stat -f%z /usr/local/bin/wgcf 2>/dev/null || stat -c%s /usr/local/bin/wgcf 2>/dev/null) -gt 100000 ]]; then
            # 降级验证：文件大于 100KB 且可执行
            return 0
        fi
    fi

    local arch=$(uname -m)
    local wgcf_arch="amd64"
    [[ "$arch" == "aarch64" ]] && wgcf_arch="arm64"
    [[ "$arch" == "armv7l" ]] && wgcf_arch="armv7"

    # 自动获取最新版本
    echo -ne "  ${C}▸${NC} 获取 wgcf 最新版本..."
    local wgcf_ver=$(curl -sL --connect-timeout 10 "https://api.github.com/repos/ViRb3/wgcf/releases/latest" | jq -r '.tag_name' 2>/dev/null | tr -d 'v')
    [[ -z "$wgcf_ver" || "$wgcf_ver" == "null" ]] && wgcf_ver="2.2.29"
    echo -e " v${wgcf_ver}"

    # 镜像源列表（优先使用支持 IPv6 的镜像，IPv4 直连放后面备选）
    local wgcf_urls=(
        "https://gh-proxy.com/https://github.com/ViRb3/wgcf/releases/download/v${wgcf_ver}/wgcf_${wgcf_ver}_linux_${wgcf_arch}"
        "https://ghps.cc/https://github.com/ViRb3/wgcf/releases/download/v${wgcf_ver}/wgcf_${wgcf_ver}_linux_${wgcf_arch}"
        "https://gh.ddlc.top/https://github.com/ViRb3/wgcf/releases/download/v${wgcf_ver}/wgcf_${wgcf_ver}_linux_${wgcf_arch}"
        "https://github.com/ViRb3/wgcf/releases/download/v${wgcf_ver}/wgcf_${wgcf_ver}_linux_${wgcf_arch}"
        "https://ghproxy.net/https://github.com/ViRb3/wgcf/releases/download/v${wgcf_ver}/wgcf_${wgcf_ver}_linux_${wgcf_arch}"
    )

    # 确保目录存在并可写
    if [[ ! -d "/usr/local/bin" ]]; then
        echo -e "  ${Y}提示${NC}: /usr/local/bin 目录不存在，正在创建..."
        mkdir -p "/usr/local/bin" 2>/dev/null || {
            _err "无法创建 /usr/local/bin 目录（权限不足？）"
            return 1
        }
    fi

    if [[ ! -w "/usr/local/bin" ]]; then
        _err "/usr/local/bin 目录不可写，请检查权限或使用 sudo"
        return 1
    fi

    local wgcf_staged
    wgcf_staged=$(mktemp "/usr/local/bin/.wgcf.XXXXXX") || {
        _err "无法在 /usr/local/bin 创建临时文件"
        return 1
    }

    local try_num=1
    local last_error=""
    for url in "${wgcf_urls[@]}"; do
        echo -e "  ${C}▸${NC} 下载 wgcf (尝试 $try_num/${#wgcf_urls[@]})"
        echo -e "    ${D}地址: $url${NC}"

        # 捕获详细错误
        last_error=$(curl -fsSL -o "$wgcf_staged" -A "Mozilla/5.0" --max-redirs 5 --connect-timeout 15 --max-time 90 -- "$url" 2>&1)
        local curl_ret=$?

        # 详细的验证流程
        if [[ $curl_ret -eq 0 ]]; then
            if [[ ! -f "$wgcf_staged" ]]; then
                echo -e "    ${R}✗ 文件未生成${NC}"
            elif [[ ! -s "$wgcf_staged" ]]; then
                echo -e "    ${R}✗ 文件为空${NC}"
            elif ! _verify_github_release_asset "ViRb3/wgcf" "$wgcf_ver" \
                "https://github.com/ViRb3/wgcf/releases/download/v${wgcf_ver}/wgcf_${wgcf_ver}_linux_${wgcf_arch}" \
                "$wgcf_staged"; then
                echo -e "    ${R}✗ SHA-256 完整性校验失败${NC}"
            elif command -v file &>/dev/null; then
                # 有 file 命令：完整验证
                if ! file "$wgcf_staged" 2>/dev/null | grep -q "ELF"; then
                    echo -e "    ${R}✗ 文件格式错误（非 ELF 可执行文件）${NC}"
                    echo -e "    ${D}文件类型: $(file "$wgcf_staged" 2>/dev/null)${NC}"
                else
                    chmod 755 "$wgcf_staged" &&
                        mv -f -- "$wgcf_staged" "/usr/local/bin/wgcf" || {
                            rm -f "$wgcf_staged"
                            _err "wgcf 安装失败"
                            return 1
                        }
                    echo -e "    ${G}✓ 下载成功${NC}"
                    return 0
                fi
            else
                # 无 file 命令：降级验证（检查文件大小）
                local filesize=$(stat -f%z "$wgcf_staged" 2>/dev/null || stat -c%s "$wgcf_staged" 2>/dev/null)
                if [[ $filesize -gt 100000 ]]; then
                    chmod 755 "$wgcf_staged" &&
                        mv -f -- "$wgcf_staged" "/usr/local/bin/wgcf" || {
                            rm -f "$wgcf_staged"
                            _err "wgcf 安装失败"
                            return 1
                        }
                    echo -e "    ${G}✓ 下载成功${NC} ${D}(文件大小: $((filesize/1024))KB)${NC}"
                    return 0
                else
                    echo -e "    ${R}✗ 文件大小异常 (${filesize} 字节)${NC}"
                fi
            fi
        else
            echo -e "    ${R}✗ 下载失败 (curl 返回码: $curl_ret)${NC}"
        fi

        [[ -n "$last_error" ]] && echo -e "    ${D}错误: $last_error${NC}"
        : > "$wgcf_staged"
        ((try_num++))
        sleep 1
    done

    rm -f "$wgcf_staged"
    _err "wgcf 下载失败"
    echo -e "  ${Y}提示${NC}: 所有镜像源均不可用，可能是网络问题"
    echo -e "  ${Y}手动下载${NC}: https://github.com/ViRb3/wgcf/releases"
    echo -e "  ${Y}下载后${NC}: 将文件上传到 /usr/local/bin/wgcf 并执行 chmod +x"
    return 1
}

# 注册 WARP 账号并获取 WireGuard 配置
register_warp() {
    _info "注册 Cloudflare WARP 账号..."

    if ! download_wgcf; then
        _err "wgcf 下载失败，无法注册 WARP"
        return 1
    fi

    local warp_tmp old_pwd
    warp_tmp=$(mktemp -d "${TMPDIR:-/tmp}/vless-wgcf.XXXXXX") || return 1
    old_pwd="$PWD"
    cd "$warp_tmp" || { rm -rf "$warp_tmp"; return 1; }

    # 注册 WARP 账户
    echo -ne "  ${C}▸${NC} 注册 WARP 账户..."
    local register_output
    register_output=$(/usr/local/bin/wgcf register --accept-tos 2>&1)
    local register_ret=$?

    if [[ $register_ret -ne 0 ]] || [[ ! -f "$warp_tmp/wgcf-account.toml" ]]; then
        echo -e " ${R}✗${NC}"
        _err "WARP 账户注册失败"
        [[ -n "$register_output" ]] && echo -e "  ${D}$register_output${NC}"
        cd "$old_pwd" || true
        rm -rf "$warp_tmp"
        return 1
    fi
    echo -e " ${G}✓${NC}"

    # 生成 WireGuard 配置
    echo -ne "  ${C}▸${NC} 生成 WireGuard 配置..."
    local generate_output
    generate_output=$(/usr/local/bin/wgcf generate 2>&1)
    local generate_ret=$?

    if [[ $generate_ret -ne 0 ]] || [[ ! -f "$warp_tmp/wgcf-profile.conf" ]]; then
        echo -e " ${R}✗${NC}"
        _err "配置生成失败"
        [[ -n "$generate_output" ]] && echo -e "  ${D}$generate_output${NC}"
        cd "$old_pwd" || true
        rm -rf "$warp_tmp"
        return 1
    fi
    echo -e " ${G}✓${NC}"

    # 解析配置并保存到 JSON
    echo -ne "  ${C}▸${NC} 保存配置..."
    parse_and_save_warp_config "$warp_tmp/wgcf-profile.conf"
    cd "$old_pwd" || true
    rm -rf "$warp_tmp"
    echo -e " ${G}✓${NC}"

    # 显示配置信息
    echo ""
    _line
    echo -e "  ${G}WGCF 配置成功${NC}"
    _line
    local endpoint=$(jq -r '.endpoint' "$WARP_CONF_FILE" 2>/dev/null)
    local address_v4=$(jq -r '.address_v4' "$WARP_CONF_FILE" 2>/dev/null)
    local address_v6=$(jq -r '.address_v6' "$WARP_CONF_FILE" 2>/dev/null)
    echo -e "  WARP 端点: ${C}${endpoint}${NC}"
    echo -e "  内网 IPv4: ${G}${address_v4}${NC}"
    echo -e "  内网 IPv6: ${D}${address_v6}${NC}"
    _line

    return 0
}

# WARP IPv6 端点优选
# 测试多个 Cloudflare WARP IPv6 端点，选择延迟最低的
_select_best_warp_ipv6_endpoint() {
    local port="${1:-2408}"
    local endpoints=(
        "2606:4700:d0::a29f:c001"
        "2606:4700:d0::a29f:c002"
        "2606:4700:d1::a29f:c001"
        "2606:4700:d1::a29f:c002"
    )

    local best_endpoint="${endpoints[0]}"
    local best_latency=9999

    echo -ne "  ${C}▸${NC} 优选 IPv6 端点..." >&2

    for ep in "${endpoints[@]}"; do
        # ping6 测试延迟，取平均值
        local latency=$(ping6 -c 2 -W 1 "$ep" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | awk '{sum+=$1} END {if(NR>0) printf "%.0f", sum/NR; else print 9999}')
        [[ -z "$latency" ]] && latency=9999

        if [[ "$latency" -lt "$best_latency" ]]; then
            best_latency="$latency"
            best_endpoint="$ep"
        fi
    done

    if [[ "$best_latency" -lt 9999 ]]; then
        echo -e " ${G}${best_endpoint}${NC} (${best_latency}ms)" >&2
    else
        echo -e " ${Y}${best_endpoint}${NC} (默认)" >&2
    fi

    echo "[${best_endpoint}]:${port}"
}

# 规范化 base64 字符串，自动添加正确的填充符
normalize_base64() {
    local input="$1"
    local len=${#input}
    local mod=$((len % 4))

    # 如果长度不是 4 的倍数，添加 = 填充
    if [[ $mod -eq 2 ]]; then
        echo "${input}=="
    elif [[ $mod -eq 3 ]]; then
        echo "${input}="
    else
        echo "$input"
    fi
}

# 解析 wgcf 生成的配置并保存为 JSON
parse_and_save_warp_config() {
    local conf_file="$1"

    local private_key=$(grep "PrivateKey" "$conf_file" | cut -d'=' -f2 | xargs)
    private_key=$(normalize_base64 "$private_key")
    local public_key=$(grep "PublicKey" "$conf_file" | cut -d'=' -f2 | xargs)
    public_key=$(normalize_base64 "$public_key")
    local endpoint=$(grep "Endpoint" "$conf_file" | cut -d'=' -f2 | xargs)

    # 自动检测：纯 IPv6 服务器使用优选的 IPv6 端点
    local has_ipv4=$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null)
    if [[ -z "$has_ipv4" ]]; then
        # 无 IPv4，自动优选 WARP IPv6 端点
        local ep_port=$(echo "$endpoint" | grep -oE ':[0-9]+$' | tr -d ':')
        [[ -z "$ep_port" ]] && ep_port="2408"
        endpoint=$(_select_best_warp_ipv6_endpoint "$ep_port")
    fi

    # 解析 Address 行，可能有多行或逗号分隔
    local addresses=$(grep "Address" "$conf_file" | cut -d'=' -f2 | tr -d ' ' | tr '\n' ',' | sed 's/,$//')

    # 分离 IPv4 和 IPv6
    local address_v4=""
    local address_v6=""

    IFS=',' read -ra ADDR_ARRAY <<< "$addresses"
    for addr in "${ADDR_ARRAY[@]}"; do
        if [[ "$addr" == *":"* ]]; then
            # IPv6 地址
            address_v6="$addr"
        else
            # IPv4 地址
            address_v4="$addr"
        fi
    done

    mkdir -p "$CFG"
    jq -n \
        --arg pk "$private_key" \
        --arg pub "$public_key" \
        --arg v4 "$address_v4" \
        --arg v6 "$address_v6" \
        --arg ep "$endpoint" \
    '{
        private_key: $pk,
        public_key: $pub,
        address_v4: $v4,
        address_v6: $v6,
        endpoint: $ep,
        reserved: [0, 0, 0]
    }' > "$WARP_CONF_FILE"
}



# 测试 WARP 连接 (支持双模式)
test_warp_connection() {
    local warp_mode=$(db_get_warp_mode)
    _info "测试 WARP 连接..."

    if [[ "$warp_mode" == "official" ]]; then
        # 测试官方客户端
        if ! check_cmd warp-cli; then
            _warn "WARP 官方客户端未安装"
            return 1
        fi

        local status=$(warp-cli status 2>/dev/null)
        if echo "$status" | grep -qi "Connected"; then
            _ok "WARP 官方客户端已连接"
            echo -e "  模式: ${G}TCP/SOCKS5${NC} (端口 $WARP_OFFICIAL_PORT)"

            # 通过 SOCKS5 代理测试出口 IP (多源重试)
            echo -ne "  获取出口 IP..."
            local warp_ip=""
            local ip_apis=("https://api.ipify.org" "https://ifconfig.me" "https://ip.sb")
            for api in "${ip_apis[@]}"; do
                warp_ip=$(curl -s --connect-timeout 8 --max-time 12 --socks5 127.0.0.1:$WARP_OFFICIAL_PORT "$api" 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
                [[ -n "$warp_ip" ]] && break
            done
            if [[ -n "$warp_ip" ]]; then
                echo -e " ${G}${warp_ip}${NC}"
            else
                echo -e " ${Y}获取超时${NC}"
            fi
        else
            _warn "WARP 官方客户端未连接"
            echo -e "  ${D}状态: ${status}${NC}"
            return 1
        fi
    else
        # 测试 WGCF 配置
        if [[ ! -f "$WARP_CONF_FILE" ]]; then
            _warn "WARP (WGCF) 未配置"
            return 1
        fi

        echo -e "  模式: ${C}UDP/WireGuard${NC} (Sing-box 内置)"

        local endpoint=$(jq -r '.endpoint // "N/A"' "$WARP_CONF_FILE" 2>/dev/null)
        local address=$(jq -r '.address_v4 // "N/A"' "$WARP_CONF_FILE" 2>/dev/null)
        echo -e "  WARP 端点: ${G}${endpoint}${NC}"
        echo -e "  WARP 内网: ${D}${address}${NC}"

        _ok "WARP (WGCF) 配置已就绪"
    fi

    # 检查是否有分流规则
    local rules=$(db_get_routing_rules)
    if [[ -z "$rules" || "$rules" == "[]" ]]; then
        _warn "未配置分流规则，WARP 不会生效"
        echo -e "  ${D}请先配置分流规则${NC}"
        return 1
    fi

    # 获取直连 IP
    local direct_ip=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    echo -e "  直连出口 IP: ${C}${direct_ip:-获取失败}${NC}"

    echo ""
    echo -e "  ${Y}验证方法:${NC} 手机连接代理后访问 https://ip.sb"
    echo -e "  ${D}如果显示的 IP 不是 ${direct_ip}，说明 WARP 生效${NC}"

    return 0
}

# 重新获取 WARP IP (WGCF 模式)
refresh_warp_wgcf() {
    _info "重新获取 WARP (WGCF) 配置..."

    # 删除旧配置
    rm -f "$WARP_CONF_FILE"
    rm -f /usr/local/bin/wgcf
    rm -f ~/.wgcf-account.toml 2>/dev/null

    # 重新注册
    if register_warp; then
        db_set_warp_mode "wgcf"
        _regenerate_proxy_configs
        _ok "WARP (WGCF) 配置已更新"
        return 0
    fi
    return 1
}

# ==============================================================================
# WARP 官方客户端支持 (解决 UDP 封锁问题)
# ==============================================================================

# 安装 Cloudflare WARP 官方客户端
install_warp_official() {
    echo ""
    echo -e "  ${C}安装 WARP 官方客户端${NC}"
    _line

    # Alpine 不支持官方客户端 (依赖 glibc)
    if [[ "$DISTRO" == "alpine" ]]; then
        _err "Alpine 系统不支持 WARP 官方客户端 (依赖 glibc)"
        _info "请使用 WGCF 模式"
        return 1
    fi

    # 检查是否已安装
    if check_cmd warp-cli; then
        echo -e "  ${C}▸${NC} WARP 客户端已安装 ${G}✓${NC}"
        return 0
    fi

    # 检查架构
    local arch=$(uname -m)
    if [[ "$arch" != "x86_64" && "$arch" != "aarch64" ]]; then
        _err "WARP 官方客户端仅支持 x86_64 和 arm64 架构"
        return 1
    fi

    echo -ne "  ${C}▸${NC} 添加 Cloudflare 软件源..."

    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        # 安装依赖
        if ! apt-get update -qq >/dev/null 2>&1 ||
           ! apt-get install -y -qq curl gnupg lsb-release >/dev/null 2>&1; then
            _err "安装 WARP 软件源依赖失败"
            return 1
        fi

        # 添加 GPG 密钥
        local warp_key_tmp
        warp_key_tmp=$(mktemp "${TMPDIR:-/tmp}/vless-warp-key.XXXXXX") || return 1
        if ! curl -fsSL --connect-timeout 10 --max-time 30 \
            -o "$warp_key_tmp" -- https://pkg.cloudflareclient.com/pubkey.gpg ||
           ! gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
            "$warp_key_tmp" 2>/dev/null; then
            rm -f "$warp_key_tmp"
            _err "下载或导入 Cloudflare 软件源密钥失败"
            return 1
        fi
        rm -f "$warp_key_tmp"

        # 获取发行版代号
        local codename=""
        if check_cmd lsb_release; then
            codename=$(lsb_release -cs 2>/dev/null)
        else
            codename=$(grep VERSION_CODENAME /etc/os-release 2>/dev/null | cut -d'=' -f2)
        fi

        # 某些新版本可能没有对应的源，回退到较新的稳定版
        case "$codename" in
            bookworm|trixie|sid) codename="bookworm" ;;
            noble|oracular) codename="jammy" ;;
        esac

        [[ -z "$codename" ]] && codename="jammy"

        printf 'deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' \
            "$codename" > /etc/apt/sources.list.d/cloudflare-client.list || return 1
        echo -e " ${G}✓${NC}"

        echo -ne "  ${C}▸${NC} 安装 cloudflare-warp..."
        apt-get update -qq >/dev/null 2>&1
        if apt-get install -y cloudflare-warp >/dev/null 2>&1; then
            echo -e " ${G}✓${NC}"
        else
            echo -e " ${R}✗${NC}"
            _warn "尝试使用备用源..."
            printf '%s\n' \
                'deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ focal main' \
                > /etc/apt/sources.list.d/cloudflare-client.list || return 1
            apt-get update -qq >/dev/null 2>&1
            if ! apt-get install -y cloudflare-warp >/dev/null 2>&1; then
                _err "安装失败"
                return 1
            fi
        fi

    elif [[ "$DISTRO" == "centos" ]]; then
        local warp_repo_tmp
        warp_repo_tmp=$(mktemp "${TMPDIR:-/tmp}/vless-warp-repo.XXXXXX") || return 1
        if ! curl -fsSL --connect-timeout 10 --max-time 30 -o "$warp_repo_tmp" -- \
            https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo ||
           ! grep -q '^\[cloudflare-warp\]' "$warp_repo_tmp" ||
           ! install -m 644 "$warp_repo_tmp" /etc/yum.repos.d/cloudflare-warp.repo; then
            rm -f "$warp_repo_tmp"
            _err "下载或安装 Cloudflare 软件源配置失败"
            return 1
        fi
        rm -f "$warp_repo_tmp"
        echo -e " ${G}✓${NC}"

        echo -ne "  ${C}▸${NC} 安装 cloudflare-warp..."
        if yum install -y cloudflare-warp >/dev/null 2>&1; then
            echo -e " ${G}✓${NC}"
        else
            echo -e " ${R}✗${NC}"
            _err "安装失败"
            return 1
        fi
    else
        echo -e " ${R}✗${NC}"
        _err "不支持的系统: $DISTRO"
        return 1
    fi

    # 验证安装
    if ! check_cmd warp-cli; then
        _err "WARP 官方客户端安装失败"
        return 1
    fi

    # 启动 warp-svc 服务
    echo -ne "  ${C}▸${NC} 启动 WARP 服务..."
    systemctl enable warp-svc >/dev/null 2>&1
    systemctl start warp-svc >/dev/null 2>&1

    local svc_retry=0
    while [[ $svc_retry -lt 5 ]]; do
        sleep 1
        if systemctl is-active warp-svc &>/dev/null; then
            echo -e " ${G}✓${NC}"
            echo ""
            _ok "WARP 官方客户端安装成功"
            return 0
        fi
        ((svc_retry++))
    done

    echo -e " ${Y}!${NC}"
    _warn "WARP 服务启动较慢，继续配置..."
    return 0
}

# 配置 WARP 官方客户端 (SOCKS5 代理模式)
configure_warp_official() {
    _info "配置 WARP 官方客户端..."

    # 检查 warp-cli 是否存在
    if ! check_cmd warp-cli; then
        _err "warp-cli 未安装"
        return 1
    fi

    # 确保 warp-svc 服务运行
    echo -ne "  ${C}▸${NC} 启动 WARP 服务..."
    if ! systemctl is-active warp-svc &>/dev/null; then
        systemctl start warp-svc 2>/dev/null
        local svc_retry=0
        while [[ $svc_retry -lt 10 ]]; do
            sleep 1
            if systemctl is-active warp-svc &>/dev/null; then
                break
            fi
            ((svc_retry++))
        done
    fi
    if systemctl is-active warp-svc &>/dev/null; then
        echo -e " ${G}✓${NC}"
    else
        echo -e " ${R}✗${NC}"
        _err "WARP 服务启动失败"
        return 1
    fi

    # 检查是否已注册 (新版 warp-cli 状态关键词: Status, Connected, Disconnected)
    local status=$(warp-cli status 2>/dev/null)
    local is_registered=false

    # 检测多种可能的已注册状态（排除 Registration Missing）
    if echo "$status" | grep -qiE "Registration|Account|Status:|Connected|Disconnected" && \
        ! echo "$status" | grep -qi "Registration Missing"; then
        is_registered=true
    fi

    register_warp_account() {
        echo -ne "  ${C}▸${NC} 注册 WARP 账户..."
        local reg_output=""
        local reg_success=false

        # 等待服务完全启动
        sleep 2

        # 尝试新版命令 (warp-cli 2024+)
        for i in 1 2 3; do
            # 方法1: --accept-tos 放在前面（全局选项）
            reg_output=$(warp-cli --accept-tos registration new 2>&1)
            if [[ $? -eq 0 ]] || echo "$reg_output" | grep -qi "already\|success\|registered"; then
                reg_success=true
                break
            fi

            # 方法2: 用 yes 管道模拟输入
            reg_output=$(yes | warp-cli registration new 2>&1)
            if [[ $? -eq 0 ]] || echo "$reg_output" | grep -qi "already\|success\|registered"; then
                reg_success=true
                break
            fi

            # 方法3: 使用 script 命令模拟 TTY
            if command -v script &>/dev/null; then
                reg_output=$(script -q -c "warp-cli registration new" /dev/null 2>&1 <<< "y")
                if [[ $? -eq 0 ]] || echo "$reg_output" | grep -qi "already\|success\|registered"; then
                    reg_success=true
                    break
                fi
            fi
            sleep 2
        done

        # 如果新版命令失败，检查是否已经注册
        if [[ "$reg_success" != "true" ]]; then
            reg_output=$(warp-cli registration show 2>&1)
            if [[ $? -eq 0 ]] && ! echo "$reg_output" | grep -qi "error\|not found\|missing"; then
                reg_success=true
            fi
        fi

        # 再次检查状态确认注册成功
        sleep 1
        status=$(warp-cli status 2>/dev/null)
        if [[ "$reg_success" == "true" ]] || echo "$status" | grep -qiE "Registration|Account|Status:|Connected|Disconnected"; then
            echo -e " ${G}✓${NC}"
            echo -ne "  ${C}▸${NC} 等待配置生效..."
            sleep 5
            echo -e " ${G}✓${NC}"
            return 0
        fi

        echo -e " ${R}✗${NC}"
        _err "WARP 账户注册失败"
        [[ -n "$reg_output" ]] && echo -e "  ${D}$reg_output${NC}"
        return 1
    }

    if [[ "$is_registered" != "true" ]]; then
        if ! register_warp_account; then
            return 1
        fi
    else
        echo -e "  ${C}▸${NC} WARP 账户已注册 ${G}✓${NC}"
    fi

    # 先断开现有连接，释放端口
    # warp-cli disconnect 2>/dev/null
    # sleep 1

    # 设置为代理模式
    echo -ne "  ${C}▸${NC} 设置代理模式..."
    warp-cli mode proxy 2>/dev/null || warp-cli set-mode proxy 2>/dev/null
    echo -e " ${G}✓${NC}"

    # 重置端口为默认值
    WARP_OFFICIAL_PORT=40000

    # 设置代理端口
    echo -ne "  ${C}▸${NC} 设置代理端口 $WARP_OFFICIAL_PORT..."
    warp-cli proxy port "$WARP_OFFICIAL_PORT" 2>/dev/null || warp-cli set-proxy-port "$WARP_OFFICIAL_PORT" 2>/dev/null
    echo -e " ${G}✓${NC}"

    # 【关键】设置完成后验证注册状态（防止设置过程中守护进程重启导致注册丢失）
    echo -ne "  ${C}▸${NC} 验证注册状态..."
    sleep 2
    local verify_status=$(warp-cli status 2>/dev/null)

    if echo "$verify_status" | grep -qi "Registration Missing"; then
        echo -e " ${R}✗${NC}"
        _warn "检测到注册信息丢失，正在重新注册..."

        # 重启服务并重新注册
        systemctl restart warp-svc 2>/dev/null
        sleep 3

        if ! register_warp_account; then
            _err "重新注册失败"
            return 1
        fi

        # 重新设置代理模式和端口
        echo -ne "  ${C}▸${NC} 重新设置代理配置..."
        warp-cli mode proxy 2>/dev/null
        warp-cli proxy port "$WARP_OFFICIAL_PORT" 2>/dev/null || warp-cli set-proxy-port "$WARP_OFFICIAL_PORT" 2>/dev/null
        sleep 2

        # 最终验证
        verify_status=$(warp-cli status 2>/dev/null)
        if echo "$verify_status" | grep -qi "Registration Missing"; then
            echo -e " ${R}✗${NC}"
            _err "注册失败：守护进程无法保持注册状态"
            echo -e "  ${D}状态输出:${NC}"
            echo "$verify_status" | sed 's/^/    /'
            return 1
        fi
        echo -e " ${G}✓${NC}"
    else
        echo -e " ${G}✓${NC}"
    fi

    # 连接 WARP
    echo -ne "  ${C}▸${NC} 连接 WARP..."
    warp-cli connect 2>/dev/null

    # 等待连接成功 (带进度显示，增加到 60 秒)
    local retry=0
    local connected=false
    while [[ $retry -lt 30 ]]; do
        sleep 2
        local status_output=$(warp-cli status 2>/dev/null)
        # 改进检测：支持多种状态格式
        if echo "$status_output" | grep -qiE "(Connected|Status.*Connected)"; then
            connected=true
            break
        fi
        echo -n "."
        ((retry++))
    done

    if $connected; then
        echo -e " ${G}✓${NC}"
    else
        echo -e " ${R}✗${NC}"

        # 超时后二次确认最终状态
        local final_status=$(warp-cli status 2>/dev/null)
        if echo "$final_status" | grep -qiE "(Connected|Status.*Connected)"; then
            echo -e "  ${Y}注意${NC}: 连接过程较慢，但最终已成功连接"
            connected=true
        else
            _err "WARP 连接超时"
            echo -e "  当前状态:"
            echo "$final_status" | sed 's/^/  /'
            return 1
        fi
    fi

    # 只有真正连接失败才返回错误
    if ! $connected; then
        return 1
    fi

    # 保存模式到数据库
    db_set_warp_mode "official"

    # 获取 WARP 出口 IP (带重试和多源)
    _get_warp_official_ip
    return $?
}

# 获取 WARP 官方客户端出口 IP (带重试机制)
# 获取 WARP 官方客户端出口 IP
# 参数: $1 = "interactive" (带用户交互) 或 "simple" (静默模式)
_get_warp_official_ip() {
    local mode="${1:-interactive}"
    local ip_apis=("https://api.ipify.org" "https://ifconfig.me" "https://ip.sb" "https://api.ip.sb/ip")

    while true; do
        echo -e "  ${C}▸${NC} 获取 WARP 出口 IP..."
        local warp_ip="" attempt=1

        while [[ $attempt -le 3 && -z "$warp_ip" ]]; do
            echo -ne "    尝试 $attempt/3..."
            for api in "${ip_apis[@]}"; do
                warp_ip=$(curl -s --connect-timeout 8 --max-time 12 --socks5 127.0.0.1:$WARP_OFFICIAL_PORT "$api" 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
                [[ -n "$warp_ip" ]] && break
            done
            [[ -n "$warp_ip" ]] && echo -e " ${G}成功${NC}" && break
            echo -e " ${Y}超时${NC}"
            ((attempt++))
            [[ $attempt -le 3 ]] && sleep 2
        done

        if [[ -n "$warp_ip" ]]; then
            if [[ "$mode" == "simple" ]]; then
                _ok "WARP 已重新连接"
                echo -e "  WARP 出口 IP: ${G}${warp_ip}${NC}"
            else
                echo ""
                _line
                echo -e "  ${G}WARP 官方客户端配置成功${NC}"
                _line
                echo -e "  SOCKS5 代理: ${C}127.0.0.1:${WARP_OFFICIAL_PORT}${NC}"
                echo -e "  WARP 出口 IP: ${G}${warp_ip}${NC}"
                _line
            fi
            return 0
        fi

        # 获取失败
        if [[ "$mode" == "simple" ]]; then
            _ok "WARP 已重新连接"
            echo -e "  ${D}出口 IP 获取超时，请稍后手动验证${NC}"
            return 0
        fi

        # interactive 模式：询问用户
        echo ""
        _warn "无法获取 WARP 出口 IP"
        echo ""
        _item "1" "重试获取"
        _item "2" "跳过 (连接已建立，可能是 API 问题)"
        _item "3" "放弃配置"
        _line
        read -rp "  请选择: " ip_choice
        ip_choice=$(echo "$ip_choice" | tr -d ' \t')

        case "$ip_choice" in
            1) continue ;;
            2)
                echo ""
                _line
                echo -e "  ${G}WARP 官方客户端已连接${NC}"
                _line
                echo -e "  SOCKS5 代理: ${C}127.0.0.1:${WARP_OFFICIAL_PORT}${NC}"
                echo -e "  ${D}出口 IP 未获取，请稍后手动验证${NC}"
                _line
                return 0
                ;;
            *)
                _err "配置已取消"
                warp-cli disconnect 2>/dev/null
                db_set_warp_mode "wgcf"
                return 1
                ;;
        esac
    done
}

# 重新连接 WARP 官方客户端
reconnect_warp_official() {
    _info "重新连接 WARP 官方客户端..."

    if ! check_cmd warp-cli; then
        _err "warp-cli 未安装"
        return 1
    fi

    warp-cli disconnect 2>/dev/null
    sleep 2
    warp-cli connect 2>/dev/null

    # 等待连接 (带进度显示，延长到 60 秒)
    echo -ne "  ${C}▸${NC} 等待连接..."
    local retry=0 connected=false
    while [[ $retry -lt 30 ]]; do
        sleep 2
        local status_output=$(warp-cli status 2>/dev/null)
        # 改进检测：支持多种状态格式
        if echo "$status_output" | grep -qiE "(Connected|Status.*Connected)"; then
            connected=true
            break
        fi
        echo -ne "."
        ((retry++))
    done

    if $connected; then
        echo -e " ${G}✓${NC}"
    else
        echo -e " ${R}✗${NC}"

        # 超时后二次确认最终状态
        local final_status=$(warp-cli status 2>/dev/null)
        if echo "$final_status" | grep -qiE "(Connected|Status.*Connected)"; then
            echo -e "  ${Y}注意${NC}: 连接过程较慢，但最终已成功连接"
            connected=true
        else
            _err "重新连接失败"
            echo "$final_status" | sed 's/^/  /'
            return 1
        fi
    fi

    # 只有真正连接成功才继续
    if ! $connected; then
        return 1
    fi

    echo -e " ${G}✓${NC}"
    _get_warp_official_ip "simple"
    return 0
}

# 卸载 WARP 官方客户端
uninstall_warp_official() {
    _info "卸载 WARP 官方客户端..."

    # 断开连接
    warp-cli disconnect 2>/dev/null

    # 停止服务
    systemctl stop warp-svc 2>/dev/null
    systemctl disable warp-svc 2>/dev/null

    # 卸载软件包
    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        apt-get remove -y cloudflare-warp 2>/dev/null
        apt-get autoremove -y 2>/dev/null
        rm -f /etc/apt/sources.list.d/cloudflare-client.list
        rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    elif [[ "$DISTRO" == "centos" ]]; then
        yum remove -y cloudflare-warp 2>/dev/null
        rm -f /etc/yum.repos.d/cloudflare-warp.repo
    fi

    _ok "WARP 官方客户端已卸载"
}

# 卸载 WARP (支持双模式)
uninstall_warp() {
    local warp_mode=$(db_get_warp_mode)
    _info "卸载 WARP..."

    if [[ "$warp_mode" == "official" ]]; then
        uninstall_warp_official
    else
        # 卸载 WGCF
        rm -f "$WARP_CONF_FILE"
        rm -f /usr/local/bin/wgcf
        rm -f ~/.wgcf-account.toml 2>/dev/null
        _ok "WARP (WGCF) 已卸载"
    fi

    # 清除模式设置和分流配置
    db_set_warp_mode "wgcf"
    db_clear_routing_rules

    # 重新生成配置 (移除 WARP outbound)
    _regenerate_proxy_configs
    _ok "WARP 已完全卸载"
}

#═══════════════════════════════════════════════════════════════════════════════
# 多出口分流规则系统
#═══════════════════════════════════════════════════════════════════════════════

# 预设仅引用发布方现成规则，不从聚合规则中提取网站域名。
declare -A ROUTING_PRESETS=(
    [singbox-ai]="rule-set:skk-non-ip-ai,rule-set:skk-ip-ai"
    [stream]="rule-set:skk-non-ip-stream,rule-set:skk-ip-stream"
    [stream-jp]="rule-set:skk-non-ip-stream_jp,rule-set:skk-ip-stream_jp"
    [youtube]="rule-set:yuu-non-ip-youtube"
    [google]="rule-set:yuu-non-ip-google"
    [twitter]="rule-set:yuu-non-ip-twitter,rule-set:yuu-ip-twitter"
    [ads]="rule-set:skk-domainset-reject,rule-set:skk-non-ip-reject,rule-set:skk-ip-reject"
)

# 预设规则显示名称
declare -A ROUTING_PRESET_NAMES=(
    [singbox-ai]="AI (Sukka)"
    [stream]="Stream (Sukka)"
    [stream-jp]="Stream JP (Sukka)"
    [youtube]="YouTube"
    [google]="Google"
    [twitter]="Twitter"
    [ads]="广告屏蔽 (Sukka)"
    [all]="所有流量"
)

# 数据库：添加分流规则
# 规则优先级：custom > 预设规则 > all（全局）
# custom 规则会插入到数组开头，确保优先匹配
# 规则优先级：直连规则 > custom > 预设规则 > all（全局）
db_add_routing_rule() {
    local rule_type="$1"    # openai, netflix, custom, all
    local outbound="$2"     # 出口标识: direct, warp, chain:节点名
    local domains="$3"      # 自定义域名 (仅 custom 类型)

    if [[ "$rule_type" != custom && "$rule_type" != all && -z "${ROUTING_PRESETS[$rule_type]:-}" ]]; then
        _err "未提供该分类的现成规则: $rule_type"
        return 1
    fi

    [[ ! -f "$DB_FILE" ]] && init_db

    # 获取 IP 版本选项 (第4个参数)
    local ip_version="${4:-prefer_ipv4}"

    # 生成规则 ID
    local rule_id="${rule_type}_$(date +%s)"
    if [[ "$rule_type" != "custom" ]]; then
        if [[ "$rule_type" == "all" ]]; then
            rule_id="all_${ip_version}"
        else
            rule_id="$rule_type"
        fi
    fi

    # 获取域名
    local rule_domains="$domains"
    [[ "$rule_type" != "custom" && "$rule_type" != "all" ]] && rule_domains="${ROUTING_PRESETS[$rule_type]:-}"

    # 规则优先级排序：
    # 1. 直连规则 (outbound=direct) - 最高优先级
    # 2. custom 规则 - 次高优先级
    # 3. 预设规则 (openai, netflix 等)
    # 4. all 规则 - 最低优先级

    if [[ "$rule_type" == "custom" ]]; then
        if [[ "$outbound" == "direct" ]]; then
            # 直连的 custom 规则插入到最开头
            _db_apply --arg id "$rule_id" --arg type "$rule_type" --arg out "$outbound" --arg domains "$rule_domains" --arg ip_ver "$ip_version" \
                '.routing_rules = ([{id: $id, type: $type, outbound: $out, domains: $domains, ip_version: $ip_ver}] + (.routing_rules // []))'
        else
            # 非直连的 custom 规则插入到直连规则之后
            _db_apply --arg id "$rule_id" --arg type "$rule_type" --arg out "$outbound" --arg domains "$rule_domains" --arg ip_ver "$ip_version" \
                '.routing_rules = (
                    ((.routing_rules // []) | map(select(.outbound == "direct"))) +
                    [{id: $id, type: $type, outbound: $out, domains: $domains, ip_version: $ip_ver}] +
                    ((.routing_rules // []) | map(select(.outbound != "direct")))
                )'
        fi
    elif [[ "$rule_type" == "all" ]]; then
        # all 规则追加到末尾，优先级最低
        _db_apply --arg id "$rule_id" --arg type "$rule_type" --arg out "$outbound" --arg domains "$rule_domains" --arg ip_ver "$ip_version" \
            '.routing_rules = (
                ((.routing_rules // []) | map(select(.type != $type or ((.ip_version // "prefer_ipv4") != $ip_ver))))
            ) + [{id: $id, type: $type, outbound: $out, domains: $domains, ip_version: $ip_ver}]'
    else
        # 预设规则：删除同类型旧规则
        if [[ "$outbound" == "direct" ]]; then
            # 直连的预设规则插入到最开头
            _db_apply --arg id "$rule_id" --arg type "$rule_type" --arg out "$outbound" --arg domains "$rule_domains" --arg ip_ver "$ip_version" \
                '.routing_rules = (
                    [{id: $id, type: $type, outbound: $out, domains: $domains, ip_version: $ip_ver}] +
                    ((.routing_rules // []) | map(select(.type != $type)))
                )'
        else
            # 非直连的预设规则：插入到直连和 custom 规则之后
            _db_apply --arg id "$rule_id" --arg type "$rule_type" --arg out "$outbound" --arg domains "$rule_domains" --arg ip_ver "$ip_version" \
                '.routing_rules = (
                    ((.routing_rules // []) | map(select(.outbound == "direct"))) +
                    ((.routing_rules // []) | map(select(.type == "custom" and .outbound != "direct"))) +
                    [{id: $id, type: $type, outbound: $out, domains: $domains, ip_version: $ip_ver}] +
                    ((.routing_rules // []) | map(select(.type != "custom" and .type != $type and .outbound != "direct")))
                )'
        fi
    fi
}

# 数据库：删除分流规则 (支持按 id 或 type 删除)
# 用法: db_del_routing_rule "rule_id" 或 db_del_routing_rule "type" "by_type"
db_del_routing_rule() {
    local identifier="$1"
    local mode="${2:-by_id}"  # 默认按 id 删除
    [[ ! -f "$DB_FILE" ]] && return

    if [[ "$mode" == "by_type" ]]; then
        # 按 type 删除 (删除所有同类型规则)
        _db_apply --arg type "$identifier" '.routing_rules = [.routing_rules[]? | select(.type != $type)]'
    else
        # 按 id 删除 (只删除单个规则)
        _db_apply --arg id "$identifier" '.routing_rules = [.routing_rules[]? | select(.id != $id)]'
    fi
}

# 返回原数组下标和规则，避免旧自定义规则 ID 重复时移动错规则。
_db_routing_rule_entries() {
    local core="${1:-all}" db_file="${2:-$DB_FILE}"
    [[ "$db_file" != /dev/stdin && ! -f "$db_file" ]] && printf '%s\n' '[]' && return
    jq --arg core "$core" '[((.routing_rules // []) | to_entries[])] |
        if $core == "singbox" then
        sort_by(
            (if .value.type == "all" then 1 else 0 end),
            (.value.routing_priority[$core] // 2147483647),
            (if .value.type == "custom" then 0
             elif .value.type == "ads" then 1
             elif .value.type == "singbox-ai" then 2
             elif .value.type == "youtube" then 3
             elif .value.type == "stream-jp" then 4
             elif .value.type == "stream" then 5
             elif .value.type == "google" then 6 else 7 end),
            (if .value.type != "all" then 0
             elif .value.ip_version == "ipv6_only" then 1
             elif .value.ip_version == "ipv4_only" then 2 else 3 end),
            .key)
        else . end' "$db_file" 2>/dev/null
}

# 按内核返回实际分流顺序；全部规则视图保留共享列表的顺序。
db_get_routing_rules() {
    local entries
    entries=$(_db_routing_rule_entries "${1:-all}" "${2:-$DB_FILE}") || return 1
    jq 'map(.value)' <<<"$entries"
}

# 序号与目标位置均从 1 开始；仅改变所选内核的优先级。
db_move_routing_rule() {
    local core="$1" from="$2" to="${3:-1}" displayed="${4:-}" snapshot entries order count
    [[ "$core" == singbox ]] || return 1
    [[ "$from" =~ ^[1-9][0-9]{0,8}$ && "$to" =~ ^[1-9][0-9]{0,8}$ ]] || return 1
    snapshot=$(cat "$DB_FILE") || return 1
    entries=$(_db_routing_rule_entries "$core" /dev/stdin <<<"$snapshot") || return 1
    if [[ -n "$displayed" ]]; then
        jq -e --argjson displayed "$displayed" 'map(.value) == $displayed' <<<"$entries" >/dev/null || return 1
    fi
    count=$(jq 'length' <<<"$entries") || return 1
    (( from <= count && to <= count )) || return 1
    [[ "$from" != "$to" ]] || return 0
    order=$(jq --argjson from "$((from-1))" --argjson to "$((to-1))" '
        map(.key) | .[$from] as $selected | del(.[$from]) |
        .[:$to] + [$selected] + .[$to:]
    ' <<<"$entries") || return 1
    # 加锁后再次校验列表，避免并发增删规则导致数组下标指向其他规则。
    local expected
    expected=$(jq '.routing_rules // []' <<<"$snapshot") || return 1
    _db_apply --arg core "$core" --argjson order "$order" --argjson expected "$expected" '
        if (.routing_rules // []) != $expected then error("routing rules changed; retry") else
            reduce range(0; $order | length) as $i (.;
                .routing_rules[$order[$i]].routing_priority[$core] = $i)
        end'
}

# 数据库：检查规则是否存在
db_has_routing_rule() {
    local rule_type="$1"
    [[ ! -f "$DB_FILE" ]] && return 1
    local count=$(jq --arg type "$rule_type" '[.routing_rules[]? | select(.type == $type)] | length' "$DB_FILE" 2>/dev/null)
    [[ "$count" -gt 0 ]]
}

# 数据库：检查规则是否存在（按类型 + IP 版本）
db_has_routing_rule_by_type_and_ip_version() {
    local rule_type="$1"
    local ip_version="$2"
    [[ ! -f "$DB_FILE" ]] && return 1
    local count=$(jq --arg type "$rule_type" --arg ip_ver "$ip_version" \
        '[.routing_rules[]? | select(.type == $type and (.ip_version // "prefer_ipv4") == $ip_ver)] | length' \
        "$DB_FILE" 2>/dev/null)
    [[ "$count" -gt 0 ]]
}
# 数据库：清空所有分流规则
db_clear_routing_rules() {
    [[ ! -f "$DB_FILE" ]] && return
    _db_apply '.routing_rules = []'
}

#═══════════════════════════════════════════════════════════════════════════════
# 负载均衡组管理
#═══════════════════════════════════════════════════════════════════════════════

# 数据库：添加负载均衡组
# 用法: db_add_balancer_group "组名" "策略" "节点1" "节点2" ...
# 策略: selector(手动选择), leastPing(最低延迟)
# 最低延迟使用 sing-box urltest。
db_add_balancer_group() {
    local name="$1" strategy="$2"
    shift 2
    local nodes=("$@")

    [[ ! -f "$DB_FILE" ]] && init_db

    # 构建节点数组
    local nodes_json=$(printf '%s\n' "${nodes[@]}" | jq -R . | jq -s .)

    # 构建组对象
    local group_json=$(jq -n \
        --arg name "$name" \
        --arg strategy "$strategy" \
        --argjson nodes "$nodes_json" \
        '{name: $name, strategy: $strategy, nodes: $nodes}')

    # 写入数据库
    _db_apply --argjson group "$group_json" \
        '.balancer_groups = (.balancer_groups // []) + [$group]'
}

# 数据库：获取所有负载均衡组
db_get_balancer_groups() {
    [[ ! -f "$DB_FILE" ]] && echo "[]" && return
    jq -r '.balancer_groups // []' "$DB_FILE" 2>/dev/null
}

# 数据库：获取指定负载均衡组
db_get_balancer_group() {
    local name="$1"
    [[ ! -f "$DB_FILE" ]] && return 1
    jq -r --arg name "$name" '.balancer_groups[]? | select(.name == $name)' "$DB_FILE" 2>/dev/null
}

# 数据库：删除负载均衡组
db_delete_balancer_group() {
    local name="$1"
    [[ ! -f "$DB_FILE" ]] && return
    _db_apply --arg name "$name" \
        '.balancer_groups = [.balancer_groups[]? | select(.name != $name)]'
}

# 数据库：检查负载均衡组是否存在
db_balancer_group_exists() {
    local name="$1"
    [[ ! -f "$DB_FILE" ]] && return 1
    local exists=$(jq --arg name "$name" \
        '[.balancer_groups[]? | select(.name == $name)] | length' "$DB_FILE" 2>/dev/null)
    [[ "$exists" -gt 0 ]]
}

# 数据库：更新负载均衡组节点
db_update_balancer_nodes() {
    local name="$1"
    shift
    local nodes=("$@")

    [[ ! -f "$DB_FILE" ]] && return 1

    local nodes_json=$(printf '%s\n' "${nodes[@]}" | jq -R . | jq -s .)
    _db_apply --arg name "$name" --argjson nodes "$nodes_json" \
        '.balancer_groups = [.balancer_groups[]? | if .name == $name then .nodes = $nodes else . end]'
}

# 获取可用的出口列表
_get_available_outbounds() {
    local outbounds=()

    # WARP 出口
    local warp_st=$(warp_status 2>/dev/null)
    if [[ "$warp_st" == "configured" || "$warp_st" == "connected" ]]; then
        outbounds+=("warp|WARP")
    fi

    # 链式代理节点
    local nodes=$(db_get_chain_nodes 2>/dev/null)
    if [[ -n "$nodes" && "$nodes" != "[]" ]]; then
        while IFS= read -r node_name; do
            [[ -n "$node_name" ]] && outbounds+=("chain:${node_name}|${node_name}")
        done < <(echo "$nodes" | jq -r '.[].name' 2>/dev/null)
    fi

    # 负载均衡组
    local balancer_groups=$(db_get_balancer_groups 2>/dev/null)
    if [[ -n "$balancer_groups" && "$balancer_groups" != "[]" ]]; then
        while IFS= read -r group_name; do
            [[ -n "$group_name" ]] && outbounds+=("balancer:${group_name}|负载均衡:${group_name}")
        done < <(echo "$balancer_groups" | jq -r '.[].name' 2>/dev/null)
    fi

    # 输出格式: "id|显示名" 每行一个
    printf '%s\n' "${outbounds[@]}"
}

# 延迟展示辅助函数
_latency_color() {
    local latency="$1"
    local color="${G}"
    if [[ "$latency" == "超时" ]]; then
        color="${R}"
    elif [[ "$latency" =~ ^[0-9]+$ ]]; then
        if [[ "$latency" -gt 1000 ]]; then
            color="${R}"
        elif [[ "$latency" -gt 300 ]]; then
            color="${Y}"
        fi
    fi
    echo "$color"
}

_format_latency_badge() {
    local latency="$1"
    local color
    color=$(_latency_color "$latency")
    if [[ "$latency" == "超时" ]]; then
        printf "%b\n" "[${color}超时${NC}]"
    elif [[ "$latency" =~ ^[0-9]+$ ]]; then
        printf "%b\n" "[${color}${latency}ms${NC}]"
    else
        echo ""
    fi
}

# 配置地址展示 (支持 IPv6)
_format_server_port() {
    local server="$1"
    local port="$2"
    local display="$server"

    if [[ -z "$display" || "$display" == "-" ]]; then
        echo "-"
        return
    fi

    display="${display#[}"
    display="${display%]}"
    [[ "$display" =~ : ]] && display="[$display]"

    if [[ -z "$port" || "$port" == "-" ]]; then
        echo "${display}"
    else
        echo "${display}:${port}"
    fi
}

# 显示排序后的延迟结果
# 用法: _display_sorted_latencies "结果文件路径" [标记关联数组名]
_display_sorted_latencies() {
    local results="$1"
    local marks_array_name="${2:-}"
    [[ ! -f "$results" ]] && return

    sort -t'|' -k1 -n "$results" | while IFS='|' read -r _ latency name type server port; do
        local latency_badge=$(_format_latency_badge "$latency")
        local display_addr=$(_format_server_port "$server" "$port")
        local mark_suffix=""

        # 如果提供了标记数组名，尝试获取对应的标记
        if [[ -n "$marks_array_name" ]]; then
            local mark_value=""
            case "$marks_array_name" in
                routing_marks) mark_value="${routing_marks[$name]:-}" ;;
                *) _warn "忽略未知的延迟标记数组: $marks_array_name" ;;
            esac
            [[ -n "$mark_value" ]] && mark_suffix=" ${Y}← ${mark_value}${NC}"
        fi

        if [[ -n "$latency_badge" ]]; then
            echo -e "  ${latency_badge} $name ${D}($type)${NC} ${D}${display_addr}${NC}${mark_suffix}"
        fi
    done
}

# 选择出口的交互函数
# 参数: $1=提示文本, $2=是否检测延迟(check_latency/no_check, 默认 check_latency)
_select_outbound() {
    local prompt="${1:-选择出口}"
    local check_mode="${2:-check_latency}"
    local outbounds=()
    local display_names=()

    # 直连出口（优先级最高）
    outbounds+=("direct")
    display_names+=("DIRECT")

    # 获取节点完整信息
    local nodes=$(db_get_chain_nodes 2>/dev/null)
    local node_count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)

    # WARP 出口
    local warp_st=$(warp_status 2>/dev/null)
    if [[ "$warp_st" == "configured" || "$warp_st" == "connected" ]]; then
        outbounds+=("warp")
        display_names+=("WARP")
    fi

    # 链式代理节点 - 获取完整信息(优化:一次 jq 调用提取所有字段)
    if [[ "$node_count" -gt 0 ]]; then
        while IFS=$'\t' read -r name type server port; do
            [[ -z "$name" ]] && continue
            outbounds+=("chain:${name}")
            display_names+=("${name}"$'\t'"${type}"$'\t'"${server}"$'\t'"${port}")
        done < <(echo "$nodes" | jq -r '.[] | [.name // "", .type // "", .server // "", .port // ""] | @tsv')
    fi

    # 负载均衡组(优化:一次 jq 调用提取所有字段)
    local balancer_groups=$(db_get_balancer_groups 2>/dev/null)
    if [[ -n "$balancer_groups" && "$balancer_groups" != "[]" ]]; then
        while IFS=$'\t' read -r group_name strategy node_count; do
            [[ -z "$group_name" ]] && continue
            outbounds+=("balancer:${group_name}")
            display_names+=("${group_name}"$'\t'"balancer"$'\t'"${strategy}"$'\t'"${node_count}节点")
        done < <(echo "$balancer_groups" | jq -r '.[] | [.name // "", .strategy // "", (.nodes | length)] | @tsv')
    fi

    # 检测延迟（跳过直连、WARP 和负载均衡组）
    local need_latency_check=false
    if [[ "$check_mode" == "check_latency" ]]; then
        for info in "${display_names[@]}"; do
            if [[ "$info" != "DIRECT" && "$info" != "WARP" ]]; then
                need_latency_check=true
                break
            fi
        done
    fi

    if [[ "$need_latency_check" == "true" ]]; then
        echo -e "  ${C}▸${NC} 检测 $((${#outbounds[@]}-1)) 个节点延迟中..." >&2
    fi

    local latency_results=()
    local idx=0
    for i in "${!display_names[@]}"; do
        local info="${display_names[$i]}"
        local type=$(echo "$info" | cut -d$'\t' -f2)
        if [[ "$info" == "DIRECT" || "$info" == "WARP" || "$type" == "balancer" ]]; then
            latency_results+=("-|$info|-")
        else
            if [[ "$check_mode" == "check_latency" ]]; then
                local node_name=$(echo "$info" | cut -d$'\t' -f1)
                local result=$(check_node_latency "$node_name" 2>/dev/null)
                latency_results+=("$result")
            else
                # 不检测延迟,使用占位符
                latency_results+=("-|$info|-")
            fi
        fi
        ((idx++))
        if [[ "$need_latency_check" == "true" ]]; then
            echo -ne "\r  ${C}▸${NC} 检测中... ($idx/${#outbounds[@]})  " >&2
        fi
    done
    if [[ "$need_latency_check" == "true" ]]; then
        echo -e "\r  ${G}✓${NC} 延迟检测完成                " >&2
    fi
    if [[ "$check_mode" != "check_latency" ]]; then
        echo "" >&2
    fi

    # 构建排序数据: latency_num|idx|latency_display|name|type|server|port
    local sort_data=()
    for i in "${!outbounds[@]}"; do
        local info="${display_names[$i]}"
        local result="${latency_results[$i]}"

        if [[ "$info" == "DIRECT" ]]; then
            # 直连放在最前面，排序值为 -1
            sort_data+=("-1|$i|DIRECT|直连 (本机出口)|direct|-|-")
        elif [[ "$info" == "WARP" ]]; then
            sort_data+=("0|$i|WARP|WARP|warp|-|-")
        else
            # display_names 用 tab 分隔: name\ttype\tserver\tport
            local name=$(echo "$info" | cut -d$'\t' -f1)
            local type=$(echo "$info" | cut -d$'\t' -f2)
            local server=$(echo "$info" | cut -d$'\t' -f3)
            local port=$(echo "$info" | cut -d$'\t' -f4)

            if [[ "$type" == "balancer" ]]; then
                # 负载均衡组排在 WARP 后面，排序值为 1
                sort_data+=("1|$i|-|${name}|balancer|${server}|${port}")
            else
                local latency="${result%%|*}"
                local latency_num=99999
                [[ "$latency" =~ ^[0-9]+$ ]] && latency_num="$latency"
                sort_data+=("${latency_num}|$i|${latency}|${name}|${type}|${server}|${port}")
            fi
        fi
    done

    # 按延迟排序并显示
    local sorted_indices=()
    local display_idx=1
    while IFS='|' read -r latency_num orig_idx latency name type server port; do
        sorted_indices+=("$orig_idx")

        local latency_badge=$(_format_latency_badge "$latency")
        local display_addr=$(_format_server_port "$server" "$port")

        if [[ "$name" == "直连 (本机出口)" ]]; then
            echo -e "  ${G}${display_idx}${NC}) ${C}直连${NC} ${D}(本机 IP 出口)${NC}" >&2
        elif [[ "$name" == "WARP" ]]; then
            echo -e "  ${G}${display_idx}${NC}) WARP" >&2
        elif [[ "$type" == "balancer" ]]; then
            # server 字段存储的是策略，port 字段存储的是节点数量
            echo -e "  ${G}${display_idx}${NC}) ${name} ${D}(负载均衡: ${server}, ${port})${NC}" >&2
        elif [[ -n "$latency_badge" ]]; then
            echo -e "  ${G}${display_idx}${NC}) ${latency_badge} ${name} ${D}(${type})${NC} ${D}${display_addr}${NC}" >&2
        else
            echo -e "  ${G}${display_idx}${NC}) ${name} ${D}(${type})${NC}" >&2
        fi
        ((display_idx++))
    done < <(printf '%s\n' "${sort_data[@]}" | sort -t'|' -k1 -n)

    # 返回选项
    echo -e "  ${G}0${NC}) 返回" >&2

    _line >&2
    read -rp "  $prompt [1]: " choice
    choice=${choice:-1}

    # 输入 0 返回
    if [[ "$choice" == "0" ]]; then
        return 1
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 && "$choice" -le ${#sorted_indices[@]} ]]; then
        local orig_idx="${sorted_indices[$((choice-1))]}"
        echo "${outbounds[$orig_idx]}"
        return 0
    fi

    return 1
}

# 获取出口的显示名称
_get_outbound_display_name() {
    local outbound="$1"
    case "$outbound" in
        direct) echo "直连" ;;
        warp) echo "WARP" ;;
        chain:*) echo "${outbound#chain:}" ;;
        *) echo "$outbound" ;;
    esac
}

# 生成多IP路由的outbound配置 (使用sendThrough指定出站IP)


# 生成多IP路由的routing规则 (根据入站IP路由到对应出站)
# 参数: $1 = inbounds JSON 数组（可选，如果提供则从中提取匹配的 tag）


# 生成多IP路由的inbound配置 (复制现有协议inbound，监听不同IP)
# 注意：这个函数需要在已有协议inbound的基础上，为每个入站IP创建独立的inbound
# 由于实现较复杂，暂时采用简化方案：用户手动指定每个协议的监听IP



# 生成 Sing-box 分流路由配置 (支持多出口)
# Removed preset retained as an explicit error for older callers.
_load_yuu_instagram_domains() {
    _err "Instagram 独立规则已移除；请使用受支持的分流预设" >&2
    return 1
}

gen_singbox_routing_rules() {
    local db_file="${1:-$DB_FILE}" rules result='[]' rule rule_type outbound domains ip_version
    local preset token tags rs phase version tag item
    rules=$(db_get_routing_rules singbox "$db_file") || return 1
    [[ -n "$rules" && "$rules" != '[]' ]] || return 0
    while IFS= read -r rule; do
        rule_type=$(jq -r '.type' <<<"$rule")
        outbound=$(jq -r '.outbound' <<<"$rule")
        domains=$(jq -r '.domains // ""' <<<"$rule")
        ip_version=$(jq -r '.ip_version // "prefer_ipv4"' <<<"$rule")
        # Resolve presets anew: old DB snapshots must never retain old sources.
        if [[ "$rule_type" != custom && "$rule_type" != all ]]; then
            preset=$(_singbox_sukka_preset_tokens "$rule_type") || {
                _err "未定义 Sukka 预设: $rule_type" >&2; return 1;
            }
            domains="$preset"
        fi
        version=0
        case "$ip_version" in ipv4_only) version=4 ;; ipv6_only) version=6 ;; esac
        # 转换出口标识为 tag
        local tag="$outbound"
        if [[ "$outbound" == "direct" ]]; then
            case "$ip_version" in
                ipv4_only) tag="direct-ipv4" ;;
                ipv6_only) tag="direct-ipv6" ;;
                prefer_ipv6) tag="direct-prefer-ipv6" ;;
                as_is|asis) tag="direct-asis" ;;
                *) tag="direct-prefer-ipv4" ;;
            esac
        elif [[ "$outbound" == "warp" ]]; then
            case "$ip_version" in
                ipv4_only) tag="warp-ipv4" ;;
                ipv6_only) tag="warp-ipv6" ;;
                prefer_ipv6) tag="warp-prefer-ipv6" ;;
                *) tag="warp-prefer-ipv4" ;;
            esac
        elif [[ "$outbound" == "block" ]]; then
            tag="block"
        elif [[ "$outbound" == chain:* ]]; then
            local node_name="${outbound#chain:}"
            case "$ip_version" in
                ipv4_only) tag="chain-${node_name}-ipv4" ;;
                ipv6_only) tag="chain-${node_name}-ipv6" ;;
                prefer_ipv6) tag="chain-${node_name}-prefer-ipv6" ;;
                *) tag="chain-${node_name}-prefer-ipv4" ;;
            esac
        elif [[ "$outbound" == balancer:* ]]; then
            tag="balancer-${outbound#balancer:}"
        fi

        local base
        base=$(jq -nc --arg tag "$tag" --argjson version "$version" \
            '{outbound:$tag} + (if $version == 0 then {} else {ip_version:$version} end)') || return 1
        # Preserve explicit inbound scope.
        if jq -e 'has("inbound")' <<<"$rule" >/dev/null; then
            base=$(jq --argjson inbound "$(jq '.inbound' <<<"$rule")" '. + {inbound:$inbound}' <<<"$base") || return 1
        fi
        if [[ "$rule_type" == all ]]; then
            result=$(jq --argjson base "$base" '. + [$base + {_phase:3}]' <<<"$result") || return 1
            continue
        fi
        local -a tokens=()
        IFS=',' read -r -a tokens <<<"$domains"
        for token in "${tokens[@]}"; do
            token="${token#"${token%%[![:space:]]*}"}"
            token="${token%"${token##*[![:space:]]}"}"
            [[ -n "$token" ]] || continue
            case "$token" in
                rule-set:*|ruleset:*|skk-*|yuu-*|geosite:*|geoip:*)
                    tags=$(_singbox_sukka_tags_for_token "$token") || return 1
                    while IFS= read -r rs; do
                        [[ -n "$rs" ]] || continue
                        # Yuu keeps legacy tag names, but site files belong to the first phase.
                        case "$rs" in skk-domainset-*|yuu-non-ip-*) phase=0 ;; skk-non-ip-*) phase=1 ;; skk-ip-*|yuu-ip-*) phase=2 ;; *) return 1 ;; esac
                        result=$(jq --argjson base "$base" --arg rs "$rs" --argjson phase "$phase" \
                            '. + [$base + {rule_set:[$rs],_phase:$phase}]' <<<"$result") || return 1
                    done <<<"$tags" ;;
                *)
                    # User domain rules precede non-IP rules; literal IPs follow them.
                    local field=domain_suffix
                    phase=0
                    if [[ "$token" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ || "$token" == *:* ]]; then
                        field=ip_cidr; phase=2
                        [[ "$version" != 4 || "$token" != *:* ]] || continue
                        [[ "$version" != 6 || "$token" != *.* ]] || continue
                    fi
                    result=$(jq --argjson base "$base" --arg field "$field" --arg value "$token" --argjson phase "$phase" \
                        '. + [$base + {($field):[$value],_phase:$phase}]' <<<"$result") || return 1 ;;
            esac
        done
    done < <(jq -c '.[]' <<<"$rules")
    # Explicit original index makes ordering stable within each global phase.
    jq 'to_entries | sort_by([.value._phase,.key]) | map(.value | del(._phase)) |
        reduce .[] as $rule ([]; if index($rule) == null then . + [$rule] else . end)' <<<"$result"
}

# 生成 Sing-box WARP outbound 配置 (支持 WireGuard 和 SOCKS5 双模式)
gen_singbox_warp_outbound() {
    local db_file="${1:-$DB_FILE}"
    local warp_mode=$(jq -r '.routing.warp_mode // "wgcf"' "$db_file")

    [[ -z "$warp_mode" || "$warp_mode" == "disabled" ]] && return

    # === 模式 A: 官方客户端 (SOCKS5) ===
    if [[ "$warp_mode" == "official" ]]; then
        # 检查官方客户端是否运行
        if ! check_cmd warp-cli; then
            return
        fi
        if [[ ! "$WARP_OFFICIAL_PORT" =~ ^[0-9]+$ ]] || [[ "$WARP_OFFICIAL_PORT" -lt 1 || "$WARP_OFFICIAL_PORT" -gt 65535 ]]; then
            return
        fi

        # 生成 SOCKS5 出站
        jq -n --argjson port "$WARP_OFFICIAL_PORT" '{
            tag: "warp",
            type: "socks",
            server: "127.0.0.1",
            server_port: $port,
            version: "5"
        }'
        return
    fi

    # === 模式 B: WGCF (WireGuard) ===
    [[ "$warp_mode" != "wgcf" ]] && return
    [[ ! -f "$WARP_CONF_FILE" ]] && return

    local private_key=$(jq -r '.private_key' "$WARP_CONF_FILE")
    local public_key=$(jq -r '.public_key' "$WARP_CONF_FILE")
    # 必须保留完整 CIDR 掩码，避免下游解析失败
    local address_v4=$(jq -r '.address_v4' "$WARP_CONF_FILE")
    local address_v6=$(jq -r '.address_v6' "$WARP_CONF_FILE")
    local endpoint=$(jq -r '.endpoint' "$WARP_CONF_FILE")

    # 正确解析 endpoint（支持 IPv6 格式 [host]:port）
    local ep_host ep_port
    if [[ "$endpoint" == \[*\]:* ]]; then
        # IPv6 格式: [2606:4700:d0::a29f:c001]:2408
        ep_host=$(echo "$endpoint" | sed 's/^\[\(.*\)\]:.*/\1/')
        ep_port=$(echo "$endpoint" | sed 's/.*\]://')
    else
        # IPv4 格式: 162.159.192.1:2408
        ep_host=$(echo "$endpoint" | cut -d':' -f1)
        ep_port=$(echo "$endpoint" | cut -d':' -f2)
    fi

    jq -n \
        --arg pk "$private_key" \
        --arg pub "$public_key" \
        --arg v4 "$address_v4" \
        --arg v6 "$address_v6" \
        --arg host "$ep_host" \
        --argjson port "$ep_port" \
    '{
        endpoint: {
            type: "wireguard",
            tag: "warp",
            system: false,
            name: "wg-warp",
            mtu: 1280,
            address: [$v4, $v6],
            private_key: $pk,
            peers: [{
                address: $host,
                port: $port,
                public_key: $pub,
                allowed_ips: ["0.0.0.0/0", "::/0"]
            }]
        }
    }'
}

# 显示当前分流状态 (多规则版本)
show_routing_status() {
    local warp_st=$(warp_status)

    echo ""
    echo -e "  ${C}出口状态${NC}"
    _line

    # 直连出口 IP 版本（默认 AsIs）
    local direct_ip_version="as_is"
    [[ -f "$CFG/direct_ip_version" ]] && direct_ip_version=$(cat "$CFG/direct_ip_version")
    local direct_display=""
    case "$direct_ip_version" in
        ipv4|ipv4_only) direct_display="仅 IPv4" ;;
        ipv6|ipv6_only) direct_display="仅 IPv6" ;;
        prefer_ipv4) direct_display="优先 IPv4" ;;
        prefer_ipv6) direct_display="优先 IPv6" ;;
        as_is|asis) direct_display="AsIs" ;;
        # 兜底展示异常值，避免界面空白
        *) direct_display="${Y}未知 ($direct_ip_version)${NC}" ;;
    esac
    echo -e "  直连: ${G}$direct_display${NC}"

    # WARP 状态
    case "$warp_st" in
        connected)
            echo -e "  WARP: ${G}● 已连接${NC} (官方客户端/TCP)"
            ;;
        registered)
            echo -e "  WARP: ${Y}● 已注册${NC} (未连接)"
            ;;
        configured)
            echo -e "  WARP: ${G}● 已配置${NC} (WGCF/UDP)"
            ;;
        *)
            echo -e "  WARP: ${D}○ 未配置${NC}"
            ;;
    esac

    # 链式代理节点数量
    local nodes=$(db_get_chain_nodes 2>/dev/null)
    local node_count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$node_count" -gt 0 ]]; then
        echo -e "  代理: ${G}● ${node_count} 个节点${NC}"
    else
        echo -e "  代理: ${D}○ 无节点${NC}"
    fi

    _line
    echo -e "  ${C}分流规则（汇总）${NC}"
    echo -e "  ${D}各内核的匹配顺序可在“调整规则顺序”中查看${NC}"
    _line

    # 显示分流规则 (优化：一次性提取所有字段，避免多次调用 jq)
    local rules=$(db_get_routing_rules)

    if [[ -n "$rules" && "$rules" != "[]" ]]; then
        local rule_count=0
        # 一次性提取 type, outbound, domains, ip_version，用 | 分隔
        while IFS='|' read -r rule_type outbound domains ip_version; do
            [[ -z "$rule_type" ]] && continue
            local outbound_name=$(_get_outbound_display_name "$outbound")

            local rule_name="${ROUTING_PRESET_NAMES[$rule_type]:-$rule_type}"
            if [[ "$rule_type" == "custom" ]]; then
                # 自定义规则显示域名
                if [[ -n "$domains" && "$domains" != "null" ]]; then
                    local display_domains="$domains"
                    if [[ ${#domains} -gt 20 ]]; then
                        display_domains="${domains:0:17}..."
                    fi
                    rule_name="自定义 (${display_domains})"
                else
                    rule_name="自定义"
                fi
            fi
            [[ "$rule_type" == "all" ]] && rule_name="所有流量"
            [[ "$rule_type" == "ads" ]] && rule_name="广告屏蔽"

            # IP 版本标记
            local ip_mark=""
            case "$ip_version" in
                ipv4_only) ip_mark=" ${C}[仅IPv4]${NC}" ;;
                ipv6_only) ip_mark=" ${C}[仅IPv6]${NC}" ;;
                prefer_ipv4) ip_mark=" ${C}[优先IPv4]${NC}" ;;
                prefer_ipv6) ip_mark=" ${C}[优先IPv6]${NC}" ;;
                as_is|asis) ip_mark=" ${C}[ALL]${NC}" ;;
            esac

            if [[ "$rule_type" == "all" ]]; then
                echo -e "  ${Y}●${NC} ${rule_name} → ${C}${outbound_name}${NC}${ip_mark}"
            elif [[ "$rule_type" == "ads" ]]; then
                echo -e "  ${R}●${NC} ${rule_name} → ${D}拦截${NC}"
            else
                echo -e "  ${G}●${NC} ${rule_name} → ${C}${outbound_name}${NC}${ip_mark}"
            fi

            ((rule_count++))
        done < <(echo "$rules" | jq -r '.[] | "\(.type)|\(.outbound)|\(.domains // "")|\(.ip_version // "prefer_ipv4")"')

        [[ $rule_count -eq 0 ]] && echo -e "  ${D}未配置分流规则${NC}"
    else
        echo -e "  ${D}未配置分流规则${NC}"
    fi
    _line
}

# 测试分流是否生效
test_routing() {
    local rules=$(db_get_routing_rules)

    # 检查是否有规则
    if [[ -z "$rules" || "$rules" == "[]" ]]; then
        _info "未配置分流规则"
        return 0
    fi

    echo ""
    _info "测试分流效果..."
    _line

    # 获取本机直连 IP
    local direct_ip=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    [[ -z "$direct_ip" ]] && direct_ip=$(curl -s --connect-timeout 5 https://ifconfig.me 2>/dev/null)
    echo -e "  直连出口 IP: ${C}${direct_ip:-获取失败}${NC}"

    # 测试 WARP 出口
    local warp_st=$(warp_status)
    if [[ "$warp_st" == "connected" ]]; then
        local warp_ip=$(curl -s --connect-timeout 10 --socks5 127.0.0.1:$WARP_OFFICIAL_PORT https://api.ipify.org 2>/dev/null)
        [[ -n "$warp_ip" ]] && echo -e "  WARP 出口 IP: ${G}${warp_ip}${NC}"
    elif [[ "$warp_st" == "configured" ]]; then
        echo -e "  WARP: ${G}已配置${NC} (WGCF/UDP)"
    fi

    _line

    # 显示规则测试信息
    echo -e "  ${Y}已配置的分流规则:${NC}"
    while IFS= read -r rule; do
        [[ -z "$rule" ]] && continue
        local rule_type=$(echo "$rule" | jq -r '.type')
        local outbound=$(echo "$rule" | jq -r '.outbound')
        local domains=$(echo "$rule" | jq -r '.domains // ""')

        local rule_name="${ROUTING_PRESET_NAMES[$rule_type]:-$rule_type}"
        [[ "$rule_type" == "custom" ]] && rule_name="自定义"
        [[ "$rule_type" == "all" ]] && rule_name="所有流量"
        local outbound_name=$(_get_outbound_display_name "$outbound")

        # 获取测试域名
        if [[ "$rule_type" == "all" ]]; then
            echo -e "  ${G}●${NC} ${rule_name} → ${outbound_name}"
        else
            local test_domain=""
            [[ -n "$domains" && "$domains" != "null" ]] && test_domain=$(echo "$domains" | cut -d',' -f1)
            echo -e "  ${G}●${NC} ${rule_name} → ${outbound_name} (${test_domain:-N/A})"
        fi
    done < <(echo "$rules" | jq -c '.[]')

    echo ""
    echo -e "  ${G}✓${NC} 分流规则已配置"
    _line
    echo -e "  ${Y}验证方法:${NC}"
    echo -e "  • 手机访问 ${C}https://ip.sb${NC} 查看出口 IP"
    echo ""
    echo -e "  ${Y}调试命令 (Sing-box):${NC}"
    echo -e "  • 检查配置语法: ${C}sing-box check -c $CFG/singbox.json${NC}"
    if [[ "$DISTRO" == "alpine" ]]; then
        # Alpine OpenRC 日志命令
        echo -e "  • 开启调试日志: ${C}sed -i 's/\"loglevel\":\"warning\"/\"loglevel\":\"debug\"/' /etc/sing-lite/config.json && rc-service sing-singbox restart${NC}"
        echo -e "  • 查看实时日志: ${C}tail -f $CFG/singbox.log${NC}"
        echo -e "  • 关闭调试日志: ${C}sed -i 's/\"loglevel\":\"debug\"/\"loglevel\":\"warning\"/' /etc/sing-lite/config.json && rc-service sing-singbox restart${NC}"
    else
        # systemd 日志命令
        echo -e "  • 开启调试日志: ${C}sed -i 's/\"loglevel\":\"warning\"/\"loglevel\":\"debug\"/' /etc/sing-lite/config.json && systemctl restart sing-singbox${NC}"
        echo -e "  • 查看实时日志: ${C}journalctl -u sing-singbox -f${NC}"
        echo -e "  • 关闭调试日志: ${C}sed -i 's/\"loglevel\":\"debug\"/\"loglevel\":\"warning\"/' /etc/sing-lite/config.json && systemctl restart sing-singbox${NC}"
    fi

    # 检查是否有 sing-box 协议
    if db_exists "singbox" "hy2" || db_exists "singbox" "tuic" || db_exists "singbox" "vless-singbox"; then
        echo ""
        echo -e "  ${Y}调试命令 (Sing-box):${NC}"
        echo -e "  • 检查配置语法: ${C}sing-box check -c /etc/sing-lite/singbox.json${NC}"
        if [[ "$DISTRO" == "alpine" ]]; then
            # Alpine OpenRC 日志命令
            echo -e "  • 开启调试日志: ${C}sed -i 's/\"level\":\"warn\"/\"level\":\"debug\"/' /etc/sing-lite/singbox.json && rc-service sing-singbox restart${NC}"
            echo -e "  • 查看实时日志: ${C}tail -f /var/log/sing/singbox.log${NC}"
            echo -e "  • 关闭调试日志: ${C}sed -i 's/\"level\":\"debug\"/\"level\":\"warn\"/' /etc/sing-lite/singbox.json && rc-service sing-singbox restart${NC}"
        else
            # systemd 日志命令
            echo -e "  • 开启调试日志: ${C}sed -i 's/\"level\":\"warn\"/\"level\":\"debug\"/' /etc/sing-lite/singbox.json && systemctl restart sing-singbox${NC}"
            echo -e "  • 查看实时日志: ${C}journalctl -u sing-singbox -f${NC}"
            echo -e "  • 关闭调试日志: ${C}sed -i 's/\"level\":\"debug\"/\"level\":\"warn\"/' /etc/sing-lite/singbox.json && systemctl restart sing-singbox${NC}"
        fi
    fi

    return 0
}

# 访问限制预设（Sukka 规则集；保留旧规则标识用于识别和清理）
ACCESS_RESTRICT_CN_DOMAINS="rule-set:skk-non-ip-domestic,rule-set:skk-ip-domestic,rule-set:skk-ip-china_ip,rule-set:skk-ip-china_ip_ipv6"

access_restriction_enabled() {
    [[ ! -f "$DB_FILE" ]] && return 1
    local count
    count=$(jq '[.routing_rules[]? | select(
        .id == "restrict-cn-geosite" or
        .id == "restrict-cn-geoip" or
        .id == "restrict-btpt-tracker" or
        .id == "restrict-btpt-trackers" or
        .id == "restrict-btpt-pt" or
        .id == "restrict-cn" or .type == "restrict-cn" or
        .id == "restrict-btpt" or .type == "restrict-btpt" or
        ((.outbound // "") == "block" and (
            (.domains // "") == "geosite:tracker,geosite:public-tracker,geosite:private-tracker" or
            (.domains // "") == "geosite:category-pt" or
            (.domains // "") == "geosite:cn" or
            (.domains // "") == "geoip:cn" or
            (.domains // "") == "geosite:tracker" or
            (.domains // "") == "geosite:public-tracker" or
            (.domains // "") == "geosite:private-tracker"
        ))
    )] | length' "$DB_FILE" 2>/dev/null)
    [[ "${count:-0}" -gt 0 ]]
}

_enable_access_rule() {
    local type="$1" domains="$2"
    _db_apply --arg type "$type" --arg domains "$domains" '
        .routing_rules = ([.routing_rules[]? | select(.type != $type and .id != $type)] +
            [{id: $type, type: "custom", outbound: "block", domains: $domains, ip_version: "as_is"}])'
}

cleanup_legacy_access_restriction_rules() {
    [[ ! -f "$DB_FILE" ]] && return 0
    _db_apply '.routing_rules = [.routing_rules[]? | select((
        .id == "restrict-cn-geosite" or
        .id == "restrict-cn-geoip" or
        .id == "restrict-btpt-tracker" or
        .id == "restrict-btpt-trackers" or
        .id == "restrict-btpt-pt" or
        .id == "restrict-cn" or .type == "restrict-cn" or
        .id == "restrict-btpt" or .type == "restrict-btpt" or
        ((.outbound // "") == "block" and (
            (.domains // "") == "geosite:tracker,geosite:public-tracker,geosite:private-tracker" or
            (.domains // "") == "geosite:category-pt" or
            (.domains // "") == "geosite:cn" or
            (.domains // "") == "geoip:cn" or
            (.domains // "") == "geosite:tracker" or
            (.domains // "") == "geosite:public-tracker" or
            (.domains // "") == "geosite:private-tracker"
        ))
    ) | not)]'
}

disable_access_restriction() {
    local previous_rules
    previous_rules=$(db_get_routing_rules) || return 1
    if ! cleanup_legacy_access_restriction_rules || ! _regenerate_proxy_configs; then
        _db_apply --argjson rules "$previous_rules" '.routing_rules = $rules' || { _err "访问限制关闭失败，数据库恢复失败"; return 1; }
        _err "访问限制关闭失败，已恢复原规则"
        _pause
        return 1
    fi
    _ok "访问限制已关闭"
    _pause
}

show_access_restriction_status() {
    _header
    echo -e "  ${W}访问限制状态${NC}"
    _line
    local rules=$(db_get_routing_rules)
    local cn_enabled="否" bt_enabled="否"
    echo "$rules" | jq -e '.[] | select(
        .id == "restrict-cn-geosite" or
        .id == "restrict-cn-geoip" or
        .id == "restrict-cn" or .type == "restrict-cn" or
        ((.outbound // "") == "block" and ((.domains // "") == "geosite:cn" or (.domains // "") == "geoip:cn"))
    )' >/dev/null 2>&1 && cn_enabled="是"
    echo "$rules" | jq -e '.[] | select(
        .id == "restrict-btpt-tracker" or
        .id == "restrict-btpt-trackers" or
        .id == "restrict-btpt-pt" or
        .id == "restrict-btpt" or .type == "restrict-btpt" or
        ((.outbound // "") == "block" and (
            (.domains // "") == "geosite:tracker" or
            (.domains // "") == "geosite:public-tracker" or
            (.domains // "") == "geosite:private-tracker" or
            (.domains // "") == "geosite:tracker,geosite:public-tracker,geosite:private-tracker" or
            (.domains // "") == "geosite:category-pt"
        ))
    )' >/dev/null 2>&1 && bt_enabled="是"
    echo -e "  禁止回国: ${G}${cn_enabled}${NC}"
    echo -e "  旧版 BT/PT 限制: ${G}${bt_enabled}${NC}"
    echo -e "  ${D}BT/PT 暂无专用规则源，不支持新增启用；旧规则可通过关闭访问限制移除${NC}"
    echo ""
    echo -e "  ${D}当前预设规则:${NC}"
    echo "$rules" | jq -r '.[] | select(
        .id == "restrict-cn-geosite" or
        .id == "restrict-cn-geoip" or
        .id == "restrict-btpt-tracker" or
        .id == "restrict-btpt-trackers" or
        .id == "restrict-btpt-pt" or
        .id == "restrict-cn" or .type == "restrict-cn" or
        .id == "restrict-btpt" or .type == "restrict-btpt" or
        ((.outbound // "") == "block" and (
            (.domains // "") == "geosite:cn" or
            (.domains // "") == "geoip:cn" or
            (.domains // "") == "geosite:tracker" or
            (.domains // "") == "geosite:public-tracker" or
            (.domains // "") == "geosite:private-tracker" or
            (.domains // "") == "geosite:tracker,geosite:public-tracker,geosite:private-tracker" or
            (.domains // "") == "geosite:category-pt"
        ))
    ) | "  • " + (.id // .type // "legacy") + " -> " + (.outbound // "") + " (" + (.domains // "") + ")"' 2>/dev/null || true
    _line
    read -rp "  按回车返回... " _
}

enable_access_restriction() {
    _header
    echo -e "  ${W}启用回国限制${NC}"
    _line
    echo -e "  ${D}将写入以下预设拦截规则:${NC}"
    echo -e "  • ${ACCESS_RESTRICT_CN_DOMAINS} -> block"
    echo -e "  ${D}BT/PT 暂无专用规则源，不支持新增启用${NC}"
    echo -e "  ${D}全局按 site（含 domainset）→ non_ip → ip 匹配，所有流量始终最后；手动优先级仅作用于阶段内部${NC}"
    echo ""
    read -rp "  确认启用? [Y/n]: " confirm
    [[ "$confirm" =~ ^[nN]$ ]] && return 0
    local previous_rules
    previous_rules=$(db_get_routing_rules) || return 1
    if ! cleanup_legacy_access_restriction_rules ||
       ! _enable_access_rule "restrict-cn" "$ACCESS_RESTRICT_CN_DOMAINS"; then
        _db_apply --argjson rules "$previous_rules" '.routing_rules = $rules' || { _err "访问限制写入失败，数据库恢复失败"; return 1; }
        _err "访问限制写入失败，已恢复原规则"
        return 1
    fi

    if [[ -n "$(get_singbox_protocols 2>/dev/null)" ]]; then
        echo ""
        _info "正在重建代理配置..."
        _info "若本机首次为 Sing-box 启用访问限制，可能会额外下载并编译规则集"
    fi

    if ! _regenerate_proxy_configs; then
        _db_apply --argjson rules "$previous_rules" '.routing_rules = $rules' || { _err "配置更新失败，数据库恢复失败"; return 1; }
        _err "访问限制启用失败，已恢复原规则"
        _pause
        return 1
    fi
    _ok "回国限制已启用"
    sleep 1
    return 0
}

manage_access_restrictions() {
    while true; do
        _header
        echo -e "  ${W}访问限制${NC}"
        _line
        local access_action="启用回国限制"
        access_restriction_enabled && access_action="关闭访问限制（含旧版 BT/PT）"
        echo -e "  ${D}BT/PT 暂无专用规则源，不支持新增启用${NC}"
        _item "1" "$access_action"
        _item "2" "查看当前限制状态"
        _item "0" "返回"
        _line
        read -rp "  请选择: " choice
        case "$choice" in
            1)
                if access_restriction_enabled; then
                    disable_access_restriction
                else
                    enable_access_restriction
                fi
                ;;
            2) show_access_restriction_status ;;
            0) return ;;
            *) _err "无效选择"; sleep 1 ;;
        esac
    done
}

# 配置分流规则
configure_routing_rules() {
    local choice
    while true; do
        _header
        show_routing_status
        _item 1 "添加规则"
        _item 2 "删除规则"
        _item 3 "调整规则顺序"
        _item 4 "应用配置"
        _item 0 "返回"
        read -rp "  请选择: " choice || return
        case "$choice" in
            1) _add_routing_rule ;;
            2) _del_routing_rule ;;
            3) _reorder_routing_rules ;;
            4) _regenerate_proxy_configs && _ok "Sing-box 分流配置已应用" ;;
            0) return ;;
            *) _err "无效选择" ;;
        esac
    done
}

# 添加分流规则
_add_routing_rule() {
    _header
    echo -e "  ${W}添加分流规则${NC}"
    _line
    echo -e "  ${D}全局匹配顺序: site（含 domainset）→ non_ip → ip → 所有流量${NC}"
    echo -e "  ${D}手动优先级仅作用于各阶段内部；所有流量始终最后${NC}"
    _line

    echo -e "  ${Y}选择规则类型:${NC}"
    echo ""
    _item "1" "AI (Sukka)"
    _item "2" "Stream (Sukka)"
    _item "3" "Stream JP (Sukka)"
    _item "4" "YouTube (Yuu)"
    _item "5" "Google (Yuu)"
    _item "6" "Twitter (Yuu)"
    _item "c" "自定义域名"
    _item "b" "广告屏蔽 (Sukka)"
    _item "a" "所有流量"
    _item "0" "返回"
    _line

    read -rp "  请选择: " rule_choice

    local rule_type="" custom_domains=""
    case "$rule_choice" in
        1) rule_type="singbox-ai" ;;
        2) rule_type="stream" ;;
        3) rule_type="stream-jp" ;;
        4) rule_type="youtube" ;;
        5) rule_type="google" ;;
        6) rule_type="twitter" ;;
        c|C)
            rule_type="custom"
            echo ""
            echo -e "  ${Y}输入要分流的匹配规则 (逗号分隔):${NC}"
            echo -e "  ${D}支持普通域名/IP 与 Sukka 规则集，可混合输入:${NC}"
            echo -e "  ${D}  1) 普通域名/IP: google.com,youtube.com 或 1.2.3.4,192.168.0.0/16${NC}"
            echo -e "  ${D}  2) domainset: rule-set:skk-domainset-cdn${NC}"
            echo -e "  ${D}  3) non_ip: rule-set:skk-non-ip-ai${NC}"
            echo -e "  ${D}  4) ip: rule-set:skk-ip-telegram${NC}"
            read -rp "  匹配规则: " custom_domains
            custom_domains=$(echo "$custom_domains" | tr -d ' \t')
            if [[ -z "$custom_domains" ]]; then
                _warn "输入不能为空"
                _pause
                return
            fi
            # 验证格式：域名包含点，IP 包含数字和点或冒号
            if [[ ! "$custom_domains" =~ [\.\:] ]]; then
                _warn "格式无效，请输入有效的域名或IP"
                _pause
                return
            fi
            ;;
        b|B) rule_type="ads" ;;
        a|A) rule_type="all" ;;
        0|"") return ;;
        *) _warn "无效选项"; _pause; return ;;
    esac

    # 广告屏蔽规则直接使用 block 出口，不需要选择
    if [[ "$rule_type" == "ads" ]]; then
        local ads_previous_rules
        ads_previous_rules=$(db_get_routing_rules) || return 1
        _info "更新代理配置..."
        if ! db_add_routing_rule "$rule_type" "block" || ! _regenerate_proxy_configs; then
            _db_apply --argjson rules "$ads_previous_rules" '.routing_rules = $rules' || { _err "数据库恢复失败"; return 1; }
            _err "添加失败，已恢复原规则"
            _pause
            return 1
        fi
        _ok "已添加规则: 广告屏蔽 → 拦截"
        _ok "配置已更新"
        _pause
        return
    fi

    # 选择出口
    echo ""
    echo -e "  ${Y}选择出口:${NC}"
    local outbound=$(_select_outbound "选择出口" "no_check")
    [[ -z "$outbound" ]] && return

    # 选择匹配的 IP 版本（用于 IPv4/IPv6 分流）
    local ip_version="as_is"  # 默认值
    echo ""
    echo -e "  ${Y}匹配的 IP 版本:${NC}"
    echo -e "  ${G}1)${NC} 仅 IPv4（只匹配 IPv4 流量）"
    echo -e "  ${G}2)${NC} 仅 IPv6（只匹配 IPv6 流量）"
    echo -e "  ${G}3)${NC} ALL（不限制，匹配全部）"
    read -rp "  请选择 [1-3，默认 3]: " ip_version_choice

    case "$ip_version_choice" in
        1) ip_version="ipv4_only" ;;
        2) ip_version="ipv6_only" ;;
        3|"") ip_version="as_is" ;;
    esac

    # 检查规则是否已存在 (custom 类型允许多条，不检查)
    if [[ "$rule_type" != "custom" ]]; then
        if [[ "$rule_type" == "all" ]]; then
            if db_has_routing_rule_by_type_and_ip_version "$rule_type" "$ip_version"; then
                local ip_text=""
                case "$ip_version" in
                    ipv4_only) ip_text="仅IPv4" ;;
                    ipv6_only) ip_text="仅IPv6" ;;
                    prefer_ipv4) ip_text="优先IPv4" ;;
                    prefer_ipv6) ip_text="优先IPv6" ;;
                    as_is|asis) ip_text="ALL" ;;
                esac
                _warn "所有流量 规则(${ip_text})已存在"
                read -rp "  是否覆盖? [y/N]: " overwrite
                [[ ! "$overwrite" =~ ^[Yy]$ ]] && return
            fi
        else
            if db_has_routing_rule "$rule_type"; then
                _warn "${ROUTING_PRESET_NAMES[$rule_type]:-$rule_type} 规则已存在"
                read -rp "  是否覆盖? [y/N]: " overwrite
                [[ ! "$overwrite" =~ ^[Yy]$ ]] && return
            fi
        fi
    fi

    # 所有新增/覆盖操作在配置应用失败时通过数据库锁恢复原规则。
    local previous_rules saved=false applied=false
    previous_rules=$(db_get_routing_rules) || return 1

    # 保存规则
    if [[ "$rule_type" == "custom" ]]; then
        db_add_routing_rule "$rule_type" "$outbound" "$custom_domains" "$ip_version" && saved=true
    else
        db_add_routing_rule "$rule_type" "$outbound" "" "$ip_version" && saved=true
    fi
    if [[ "$saved" != true ]]; then
        _db_apply --argjson rules "$previous_rules" '.routing_rules = $rules' || { _err "数据库恢复失败"; return 1; }
        _err "规则保存失败，已恢复原规则"
        _pause
        return 1
    fi

    local rule_name="${ROUTING_PRESET_NAMES[$rule_type]:-$rule_type}"
    [[ "$rule_type" == "custom" ]] && rule_name="自定义"
    [[ "$rule_type" == "all" ]] && rule_name="所有流量"
    local outbound_name=$(_get_outbound_display_name "$outbound")

    # 显示 IP 版本标记
    local ip_version_mark=""
    case "$ip_version" in
        ipv4_only) ip_version_mark=" ${C}[仅IPv4]${NC}" ;;
        ipv6_only) ip_version_mark=" ${C}[仅IPv6]${NC}" ;;
        prefer_ipv4) ip_version_mark=" ${C}[优先IPv4]${NC}" ;;
        prefer_ipv6) ip_version_mark=" ${C}[优先IPv6]${NC}" ;;
        as_is|asis) ip_version_mark=" ${C}[ALL]${NC}" ;;
    esac

    # 专属规则只应用到对应内核。
    _info "更新代理配置..."
    if [[ "$rule_type" == singbox-ai ]]; then
        _reload_ai_routing_core "$rule_type" && applied=true
    else
        _regenerate_proxy_configs && applied=true
    fi
    if [[ "$applied" != true ]]; then
        _db_apply --argjson rules "$previous_rules" '.routing_rules = $rules' || { _err "数据库恢复失败"; return 1; }
        _err "配置更新失败，已恢复原规则"
        _pause
        return 1
    fi
    _ok "已添加规则: ${rule_name} → ${outbound_name}${ip_version_mark}"
    _ok "配置已更新"
    _pause
}

# 删除分流规则
_del_routing_rule() {
    _header
    echo -e "  ${W}删除分流规则${NC}"
    _line

    local rules=$(db_get_routing_rules)
    if [[ -z "$rules" || "$rules" == "[]" ]]; then
        _warn "没有分流规则"
        _pause
        return
    fi

    # 显示规则列表
    local idx=1
    local rule_ids=()
    while IFS= read -r rule; do
        [[ -z "$rule" ]] && continue
        local rule_id=$(echo "$rule" | jq -r '.id')
        local rule_type=$(echo "$rule" | jq -r '.type')
        local outbound=$(echo "$rule" | jq -r '.outbound')
        local domains=$(echo "$rule" | jq -r '.domains // ""')
        local ip_version=$(echo "$rule" | jq -r '.ip_version // "prefer_ipv4"')
        local rule_name="${ROUTING_PRESET_NAMES[$rule_type]:-$rule_type}"

        # 自定义规则显示域名
        if [[ "$rule_type" == "custom" ]]; then
            # 截取域名显示，过长则省略
            local display_domains="$domains"
            if [[ ${#domains} -gt 30 ]]; then
                display_domains="${domains:0:27}..."
            fi
            rule_name="自定义 (${display_domains})"
        fi
        [[ "$rule_type" == "all" ]] && rule_name="所有流量"
        local outbound_name=$(_get_outbound_display_name "$outbound")

        # IP 版本标记（广告屏蔽规则无需显示）
        local ip_mark=""
        if [[ "$rule_type" != "ads" ]]; then
            case "$ip_version" in
                ipv4_only) ip_mark=" ${C}[仅IPv4]${NC}" ;;
                ipv6_only) ip_mark=" ${C}[仅IPv6]${NC}" ;;
                prefer_ipv4) ip_mark=" ${C}[优先IPv4]${NC}" ;;
                prefer_ipv6) ip_mark=" ${C}[优先IPv6]${NC}" ;;
                as_is|asis) ip_mark=" ${C}[ALL]${NC}" ;;
            esac
        fi

        echo -e "  ${G}${idx})${NC} ${rule_name} → ${outbound_name}${ip_mark}"
        rule_ids+=("$rule_id")
        ((idx++))
    done < <(echo "$rules" | jq -c '.[]')

    echo ""
    read -rp "  输入序号删除 (0 返回): " del_choice

    if [[ "$del_choice" =~ ^[0-9]+$ ]] && [[ "$del_choice" -ge 1 && "$del_choice" -le ${#rule_ids[@]} ]]; then
        local del_id="${rule_ids[$((del_choice-1))]}" del_type
        del_type=$(printf '%s\n' "$rules" | jq -r --arg id "$del_id" '.[] | select(.id == $id) | .type')
        local ai_snapshot=""
        if [[ "$del_type" == singbox-ai ]]; then
            ai_snapshot=$(mktemp "$CFG/.ai-routing.XXXXXX") || return 1
            cp -p "$DB_FILE" "$ai_snapshot" || { rm -f "$ai_snapshot"; return 1; }
        fi
        db_del_routing_rule "$del_id"
        if [[ "$del_type" == singbox-ai ]]; then
            if ! _reload_ai_routing_core "$del_type"; then
                cp -p "$ai_snapshot" "$DB_FILE" || { _err "数据库恢复失败，备份保留: $ai_snapshot"; return 1; }
                rm -f "$ai_snapshot"
                _pause
                return 1
            fi
            rm -f "$ai_snapshot"
        elif [[ "$del_type" == singbox-instagram ]]; then
            local snell_protocols
            snell_protocols=$(get_singbox_snell_protocols) || :
            if [[ -n "$snell_protocols" ]]; then
                _regenerate_singbox_routing_config || { _pause; return 1; }
            fi
        else
            _regenerate_proxy_configs || { _pause; return 1; }
        fi
        _ok "已删除规则"
    fi
    _pause
}

# 调整顺序只重载对应内核；失败时数据库和运行配置一起恢复。
_apply_routing_rule_order() {
    local core="$1" from="$2" to="${3:-1}" displayed="${4:-}" config rule_type snapshot
    local had_config=false was_running=false restart_core=false
    case "$core" in
        singbox) config="$CFG/singbox.json"; rule_type=singbox-ai ;;
        *) return 1 ;;
    esac
    snapshot=$(mktemp -d "$CFG/.routing-order.XXXXXX") || return 1
    cp -p "$DB_FILE" "$snapshot/db.json" || { rm -rf "$snapshot"; return 1; }
    if [[ -f "$config" ]]; then
        cp -p "$config" "$snapshot/config.json" || { rm -rf "$snapshot"; return 1; }
        had_config=true
    fi
    if [[ "$core" == singbox ]] && svc status sing-singbox >/dev/null 2>&1; then
        was_running=true
    fi
    if ! db_move_routing_rule "$core" "$from" "$to" "$displayed"; then
        rm -rf "$snapshot"
        _err "调整失败，请重新读取规则后再试"
        return 1
    fi
    if _reload_ai_routing_core "$rule_type"; then
        rm -rf "$snapshot"
        return 0
    fi

    # Sing-box 重载器自带服务回滚；Sing-box 需恢复写入过的新配置及服务。
    if [[ "$was_running" == true ]] &&
       { ! cmp -s "$snapshot/config.json" "$config" || ! svc status sing-singbox >/dev/null 2>&1; }; then
        restart_core=true
    fi
    if ! cp -p "$snapshot/db.json" "$DB_FILE"; then
        _err "数据库恢复失败，备份保留: $snapshot"
        return 1
    fi
    if [[ "$had_config" == true ]]; then
        cp -p "$snapshot/config.json" "$config" || { _err "配置恢复失败，备份保留: $snapshot"; return 1; }
    else
        rm -f "$config" || return 1
    fi
    if [[ "$restart_core" == true ]] && ! svc restart sing-singbox; then
        _err "Sing-box 服务恢复失败，备份保留: $snapshot"
        return 1
    fi
    rm -rf "$snapshot"
    _err "调整失败，已恢复原规则顺序和配置"
    return 1
}

_reorder_routing_rules() {
    local core_choice core core_name protocols rules count rule idx choice target
    local rule_type rule_name domains outbound ip_version ip_mark
    _header
    echo -e "  ${W}调整规则顺序${NC}"
    _line
    core=singbox; core_name=Sing-box; protocols=$(get_singbox_protocols)
    [[ -n "$protocols" ]] || { _warn "请先安装 $core_name 协议"; _pause; return 1; }

    while true; do
        rules=$(db_get_routing_rules "$core") || return 1
        count=$(jq 'length' <<<"$rules") || return 1
        _header
        echo -e "  ${W}${core_name} 分流规则顺序${NC}"
        _line
        _info "全局按 site（含 domainset）→ non_ip → ip 匹配，所有流量始终最后"
        _info "手动顺序仅调整各阶段内部的优先级，阶段内首条命中生效"
        idx=1
        while IFS= read -r rule; do
            rule_type=$(jq -r '.type' <<<"$rule")
            rule_name="${ROUTING_PRESET_NAMES[$rule_type]:-$rule_type}"
            domains=$(jq -r '.domains // ""' <<<"$rule")
            [[ "$rule_type" != custom ]] || rule_name="自定义 (${domains:0:60})"
            [[ "$rule_type" != all ]] || rule_name="所有流量"
            outbound=$(jq -r '.outbound' <<<"$rule")
            outbound=$(_get_outbound_display_name "$outbound")
            ip_version=$(jq -r '.ip_version // "prefer_ipv4"' <<<"$rule")
            case "$ip_version" in
                ipv4_only) ip_mark=仅IPv4 ;;
                ipv6_only) ip_mark=仅IPv6 ;;
                prefer_ipv4) ip_mark=优先IPv4 ;;
                prefer_ipv6) ip_mark=优先IPv6 ;;
                *) ip_mark=ALL ;;
            esac
            printf '  %s) %s → %s [%s]\n' "$idx" "$rule_name" "$outbound" "$ip_mark"
            idx=$((idx+1))
        done < <(jq -c '.[]' <<<"$rules")
        if (( count < 2 )); then
            _info "当前内核不足两条分流规则，无需调整顺序"
            _pause
            return 0
        fi
        _line
        read -rp "  选择要移动的规则 (0 返回): " choice || return 0
        [[ "$choice" != 0 && -n "$choice" ]] || return 0
        if [[ ! "$choice" =~ ^[1-9][0-9]{0,8}$ ]] || (( choice > count )); then
            _err "无效规则序号"; _pause; continue
        fi
        read -rp "  移动到第几位 [1-$count，默认 1 置顶，0 返回]: " target || return 0
        target=${target:-1}
        [[ "$target" != 0 ]] || continue
        if [[ ! "$target" =~ ^[1-9][0-9]{0,8}$ ]] || (( target > count )); then
            _err "无效目标位置"; _pause; continue
        fi
        if [[ "$choice" == "$target" ]]; then
            _info "规则已在该位置"; _pause; continue
        fi
        _info "更新 $core_name 分流顺序..."
        _apply_routing_rule_order "$core" "$choice" "$target" "$rules" || { _pause; return 1; }
        _ok "已将第 $choice 条规则移动到第 $target 位，仅更新 $core_name"
        _pause
    done
}

# AI 预设仅重载其所属核心。
_reload_ai_routing_core() {
    [[ "$1" == singbox-ai ]] || { _err "仅支持 Sing-box 分流"; return 1; }
    [[ -n "$(get_singbox_protocols)" ]] || return 0
    _regenerate_singbox_routing_config
}

# 重新生成代理配置的辅助函数
_regenerate_proxy_configs() {
    [[ -n "$(get_singbox_protocols)" ]] || { _err "请先安装 Sing-box 协议"; return 1; }
    _regenerate_singbox_routing_config
}

# WARP 管理菜单 (二选一模式)
manage_warp() {
    _header
    echo -e "  ${W}WARP 管理${NC}"

    local status=$(warp_status)
    local current_mode=$(db_get_warp_mode)

    _line
    case "$status" in
        connected)
            echo -e "  状态: ${G}● 已连接${NC}"
            echo -e "  模式: ${C}官方客户端 (TCP/SOCKS5)${NC}"
            echo -e "  代理: ${G}127.0.0.1:${WARP_OFFICIAL_PORT}${NC}"
            echo -e "  ${D}抗 UDP 封锁，稳定性好${NC}"
            ;;
        registered)
            echo -e "  状态: ${Y}● 已注册${NC} (未连接)"
            echo -e "  模式: ${C}官方客户端${NC}"
            ;;
        configured)
            echo -e "  状态: ${G}● 已配置${NC}"
            echo -e "  模式: ${C}WGCF (UDP/WireGuard)${NC}"
            if [[ -f "$WARP_CONF_FILE" ]]; then
                local endpoint=$(jq -r '.endpoint // "N/A"' "$WARP_CONF_FILE" 2>/dev/null)
                echo -e "  端点: ${D}${endpoint}${NC}"
            fi
            echo -e "  ${D}性能好，但可能被 UDP 封锁${NC}"
            ;;
        *)
            echo -e "  状态: ${D}○ 未配置${NC}"
            echo ""
            echo -e "  ${D}WARP 提供 Cloudflare 的干净 IP 出口${NC}"
            echo -e "  ${D}用于解锁 ChatGPT/Netflix 等服务${NC}"
            echo ""
            echo -e "  ${Y}两种模式:${NC}"
            echo -e "  ${D}• WGCF: UDP/WireGuard，性能好${NC}"
            echo -e "  ${D}• 官方客户端: TCP/SOCKS5，绕过 UDP 封锁${NC}"
            ;;
    esac
    _line

    if [[ "$status" == "not_configured" ]]; then
        _item "1" "配置 WGCF 模式 (UDP/WireGuard)"
        _item "2" "配置官方客户端 (TCP/SOCKS5)"
    else
        if [[ "$current_mode" == "official" ]]; then
            _item "1" "切换到 WGCF 模式"
            _item "2" "重新连接官方客户端"
            _item "3" "测试 WARP 连接"
            _item "4" "卸载官方客户端"
        else
            _item "1" "切换到官方客户端模式"
            _item "2" "重新获取 WGCF 配置"
            _item "3" "测试 WARP 连接"
            _item "4" "卸载 WGCF"
        fi
    fi
    _item "0" "返回"
    _line

    read -rp "  请选择: " choice
    choice=$(echo "$choice" | tr -d ' \t')

    if [[ "$status" == "not_configured" ]]; then
        case "$choice" in
            1)
                # 配置 WGCF
                if register_warp; then
                    db_set_warp_mode "wgcf"
                    _regenerate_proxy_configs
                    _ok "WGCF 模式配置完成"
                fi
                _pause
                ;;
            2)
                # 配置官方客户端
                if [[ "$DISTRO" == "alpine" ]]; then
                    _err "Alpine 系统不支持官方客户端"
                    _info "请使用 WGCF 模式"
                    _pause
                    return
                fi
                if install_warp_official; then
                    if configure_warp_official; then
                        _regenerate_proxy_configs
                        _ok "官方客户端模式配置完成"
                    fi
                fi
                _pause
                ;;
            0) return ;;
            *) _warn "无效选项" ;;
        esac
    else
        case "$choice" in
            1)
                # 切换模式
                if [[ "$current_mode" == "official" ]]; then
                    # 切换到 WGCF
                    _info "切换到 WGCF 模式..."
                    warp-cli disconnect 2>/dev/null
                    # 停止 warp-svc 服务，避免与 WGCF 冲突
                    systemctl stop warp-svc 2>/dev/null
                    systemctl disable warp-svc 2>/dev/null
                    if register_warp; then
                        db_set_warp_mode "wgcf"
                        _regenerate_proxy_configs
                        _ok "已切换到 WGCF 模式"
                    fi
                else
                    # 切换到官方客户端
                    if [[ "$DISTRO" == "alpine" ]]; then
                        _err "Alpine 系统不支持官方客户端"
                        _pause
                        return
                    fi
                    _info "切换到官方客户端模式..."
                    if install_warp_official; then
                        if configure_warp_official; then
                            _regenerate_proxy_configs
                            _ok "已切换到官方客户端模式"
                        fi
                    fi
                fi
                _pause
                ;;
            2)
                # 重新配置/连接
                if [[ "$current_mode" == "official" ]]; then
                    reconnect_warp_official
                else
                    refresh_warp_wgcf
                fi
                _pause
                ;;
            3)
                test_warp_connection
                _pause
                ;;
            4)
                echo ""
                read -rp "  确认卸载 WARP? [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy] ]]; then
                    uninstall_warp
                fi
                _pause
                ;;
            0) return ;;
            *) _warn "无效选项" ;;
        esac
    fi
}

# 配置直连出口 IP 版本
configure_direct_outbound() {
    _header
    echo -e "  ${W}直连出口设置${NC}"
    _line
    echo -e "  ${D}设置直连流量使用的 IP 版本${NC}"
    echo -e "  ${D}适用于双栈服务器选择出口 IP${NC}"
    echo ""

    # 读取当前设置，默认 AsIs
    local current="as_is"
    [[ -f "$CFG/direct_ip_version" ]] && current=$(cat "$CFG/direct_ip_version")

    echo -e "  当前设置: ${G}$current${NC}"
    echo ""
    _item "1" "仅 IPv4（IPv6 受限或不稳定环境）"
    _item "2" "仅 IPv6（双栈环境，强制 IPv6）"
    _item "3" "优先 IPv4（双栈环境，优先 IPv4）"
    _item "4" "优先 IPv6（双栈环境，优先 IPv6）"
    _item "5" "AsIs（默认值，不做处理）"
    _item "0" "返回"
    _line

    read -rp "  请选择: " choice

    local new_setting=""
    case "$choice" in
        1) new_setting="ipv4_only" ;;
        2) new_setting="ipv6_only" ;;
        3) new_setting="prefer_ipv4" ;;
        4) new_setting="prefer_ipv6" ;;
        5) new_setting="as_is" ;;
        0|"") return ;;
        *) _warn "无效选项"; return ;;
    esac

    echo "$new_setting" > "$CFG/direct_ip_version"
    _ok "直连出口已设置为: $new_setting"

    # 三个内核统一重建，包含 Mihomo 的默认直连出口。
    _regenerate_proxy_configs || return 1
}

# WARP → 落地 双层链式代理一键配置
setup_warp_ipv6_chain() {
    _warn "WARP IPv6 链式代理暂未支持 Sing-box，配置未更改"
    return 1
}

# 分流管理主菜单
manage_routing() {
    while true; do
        _header
        echo -e "  ${W}分流管理${NC}"
        show_routing_status

        _item "1" "WARP 管理"
        _item "2" "链式代理"
        _item "3" "配置分流规则"
        _item "4" "直连出口设置"
        _item "5" "多IP入出站配置"
        _item "6" "访问限制"
        _item "7" "测试分流效果"
        _item "8" "查看当前配置"
        _item "0" "返回"
        _line

        read -rp "  请选择: " choice

        case "$choice" in
            1) manage_warp ;;
            2) manage_chain_proxy ;;
            3) configure_routing_rules ;;
            4) configure_direct_outbound ;;
            5) manage_ip_routing ;;
            6) manage_access_restrictions ;;
            7)
                _header
                echo -e "  ${W}测试分流效果${NC}"
                test_routing
                _pause
                ;;
            8)
                _header
                echo -e "  ${W}当前分流配置${NC}"
                _line
                local rules=$(db_get_routing_rules)
                if [[ -n "$rules" && "$rules" != "[]" ]]; then
                    echo "$rules" | jq .
                else
                    echo -e "  ${D}未配置分流规则${NC}"
                fi
                _line
                read -rp "  按回车返回..." _
                ;;
            0) return ;;
            *) _err "无效选择"; _pause ;;
        esac
    done
}


#═══════════════════════════════════════════════════════════════════════════════
# 链式代理转发
#═══════════════════════════════════════════════════════════════════════════════

# 节点类型支持判断


_node_supports_singbox() {
    local type="$1"
    case "$type" in
        socks|http|shadowsocks|vmess|vless|trojan|hysteria2|tuic|naive) return 0 ;;
    esac
    return 1
}

_pick_latency_core() {
    _node_supports_singbox "$1" && check_cmd sing-box || return 1
    echo singbox
}

_wait_local_port() {
    local port="$1"
    local retries=20
    _is_valid_port "$port" || return 1
    while [[ "$retries" -gt 0 ]]; do
        if check_cmd nc; then
            if nc -z 127.0.0.1 "$port" &>/dev/null; then
                return 0
            fi
        elif timeout 1 bash -c 'echo >/dev/tcp/127.0.0.1/$1' _ "$port" &>/dev/null; then
            return 0
        fi
        sleep 0.1
        ((retries--))
    done
    return 1
}

_core_latency_test() {
    local core="$1" node_json="$2" ip_mode="${3:-prefer_ipv4}"
    local tmp_dir cfg_file proxy_port outbound pid latency=""

    tmp_dir=$(mktemp -d) || return 1
    cfg_file="${tmp_dir}/core.json"
    proxy_port=$(gen_port)

    [[ "$core" == singbox ]] || return 1
        outbound=$(gen_singbox_chain_outbound "$node_json" "proxy" "$ip_mode")
        if [[ -z "$outbound" ]]; then
            rm -rf "$tmp_dir"
            return 1
        fi
        cat > "$cfg_file" <<EOF
{
  "log": {"level": "error"},
  "inbounds": [
    {"type": "socks", "tag": "in", "listen": "127.0.0.1", "listen_port": $proxy_port}
  ],
  "outbounds": [
    $outbound
  ],
  "route": {"final": "proxy"}
}
EOF
        sing-box run -c "$cfg_file" >/dev/null 2>&1 &
        pid=$!

    if [[ -z "$pid" ]]; then
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! _wait_local_port "$proxy_port"; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        rm -rf "$tmp_dir"
        return 1
    fi

    local -a samples=()
    local probe_total=""
    local probe_count="$LATENCY_PROBES"
    local max_attempts="$LATENCY_MAX_ATTEMPTS"
    [[ -z "$probe_count" || "$probe_count" -lt 1 ]] && probe_count=1
    if [[ -z "$max_attempts" || "$max_attempts" -lt "$probe_count" ]]; then
        max_attempts=$((probe_count * 2))
    fi

    local attempts=0
    while [[ "${#samples[@]}" -lt "$probe_count" && "$attempts" -lt "$max_attempts" ]]; do
        ((attempts++))
        if probe_total=$(curl -s -o /dev/null -w "%{time_total}" \
            --connect-timeout "$CURL_TIMEOUT_FAST" \
            --max-time "$CURL_TIMEOUT_NORMAL" \
            --socks5-hostname "127.0.0.1:${proxy_port}" \
            "$LATENCY_TEST_URL"); then
            local ms=$(awk -v t="$probe_total" 'BEGIN {if (t ~ /^[0-9.]+$/) printf "%.0f", t*1000}')
            [[ -n "$ms" ]] && samples+=("$ms")
        fi
    done

    if [[ "${#samples[@]}" -gt 0 ]]; then
        local mid=$(( (${#samples[@]} + 1) / 2 ))
        latency=$(printf '%s\n' "${samples[@]}" | sort -n | awk -v m="$mid" 'NR==m {print; exit}')
    fi

    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -rf "$tmp_dir"

    [[ -n "$latency" ]] && { echo "$latency"; return 0; }
    return 1
}

# 批量节点测速（并发执行）
# 用法: _batch_latency_nodes "结果文件" ["并发数"]
# stdin: 每行节点 JSON
_batch_latency_nodes() {
    local results_file="$1"
    local parallel="${2:-$LATENCY_PARALLEL}"
    local tmp_dir

    [[ -z "$results_file" ]] && return 1
    [[ -z "$parallel" || "$parallel" -lt 1 ]] && parallel=1

    tmp_dir=$(mktemp -d) || return 1

    local idx=0
    local -a pids=()
    while IFS= read -r node_json; do
        [[ -z "$node_json" ]] && continue
        local out_file="${tmp_dir}/${idx}"
        (
            if ! echo "$node_json" | jq empty 2>/dev/null; then
                exit 0
            fi
            local name=$(echo "$node_json" | jq -r '.name // "未知"')
            local type=$(echo "$node_json" | jq -r '.type // "?"')
            local server=$(echo "$node_json" | jq -r '.server // ""')
            local port=$(echo "$node_json" | jq -r '.port // ""')
            port=$(echo "$port" | tr -d '"' | tr -d ' ')
            [[ -z "$port" ]] && port="-"
            [[ -z "$server" ]] && server="-"
            local result=$(check_node_latency "$node_json")
            local latency="${result%%|*}"
            local latency_num=99999
            [[ "$latency" =~ ^[0-9]+$ ]] && latency_num="$latency"
            printf '%s|%s|%s|%s|%s|%s\n' "$latency_num" "$latency" "$name" "$type" "$server" "$port" > "$out_file"
        ) &
        pids+=("$!")
        if [[ "${#pids[@]}" -ge "$parallel" ]]; then
            wait "${pids[0]}" 2>/dev/null
            pids=("${pids[@]:1}")
        fi
        ((idx++))
    done

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null
    done

    if ls "$tmp_dir" >/dev/null 2>&1; then
        cat "$tmp_dir"/* >> "$results_file"
    fi
    rm -rf "$tmp_dir"
}

# 检测节点延迟和解析 IP
# 用法: check_node_latency "节点名" 或 "节点JSON"
# 返回: "延迟ms|解析IP" 或 "超时|-"
check_node_latency() {
    local node_ref="$1"
    local node=""
    local resolved_ip="" latency="" is_ipv6=false

    [[ -z "$node_ref" ]] && { echo "超时|-"; return; }
    if [[ "$node_ref" =~ ^\{ ]]; then
        node="$node_ref"
    else
        node=$(db_get_chain_node "$node_ref")
    fi

    if [[ -z "$node" || "$node" == "null" ]] || ! echo "$node" | jq empty 2>/dev/null; then
        echo "超时|-"
        return
    fi

    local type=$(echo "$node" | jq -r '
        (.type // "") |
        if . == "socks5" then "socks"
        elif . == "hy2" then "hysteria2"
        else . end
    ')
    local server=$(echo "$node" | jq -r '.server // ""')
    local port=$(echo "$node" | jq -r '.port // ""')
    port=$(echo "$port" | tr -d '"' | tr -d ' ')

    if [[ -z "$type" || -z "$server" || ! "$port" =~ ^[0-9]+$ ]]; then
        echo "超时|-"
        return
    fi

    # 移除 server 可能带有的方括号 (IPv6 格式)
    server="${server#[}"
    server="${server%]}"

    # 判断地址类型
    if [[ "$server" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        resolved_ip="$server"
    elif [[ "$server" =~ : ]]; then
        resolved_ip="$server"
        is_ipv6=true
    else
        resolved_ip=$(dig +short "$server" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
        if [[ -z "$resolved_ip" ]]; then
            resolved_ip=$(dig +short "$server" AAAA 2>/dev/null | grep -E ':' | head -1)
            [[ -n "$resolved_ip" ]] && is_ipv6=true
        fi
        [[ -z "$resolved_ip" ]] && resolved_ip=$(host "$server" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    [[ -z "$resolved_ip" ]] && resolved_ip="-"

    local core=""
    core=$(_pick_latency_core "$type") || { echo "超时|$resolved_ip"; return; }

    local ip_mode="prefer_ipv4"
    [[ "$is_ipv6" == "true" ]] && ip_mode="prefer_ipv6"

    if latency=$(_core_latency_test "$core" "$node" "$ip_mode"); then
        echo "${latency}|${resolved_ip}"
    else
        echo "超时|${resolved_ip}"
    fi
}

# 数据库：链式代理节点操作
db_get_chain_nodes() { jq -r '.chain_proxy.nodes // []' "$DB_FILE" 2>/dev/null; }
db_get_chain_node() { jq -r --arg name "$1" '.chain_proxy.nodes[] | select(.name == $name)' "$DB_FILE" 2>/dev/null; }
db_get_chain_active() { jq -r '.chain_proxy.active // empty' "$DB_FILE" 2>/dev/null; }
db_set_chain_active() {
    _db_apply --arg name "$1" '.chain_proxy.active = $name'
}
db_add_chain_node() {
    local node_json="$1"
    # 验证 JSON 格式
    if ! echo "$node_json" | jq empty 2>/dev/null; then
        return 1
    fi
    _db_apply --argjson node "$node_json" '.chain_proxy.nodes = ((.chain_proxy.nodes // []) + [$node])'
}
db_del_chain_node() {
    local name="$1"
    _db_apply --arg name "$name" '
        .chain_proxy.nodes = [(.chain_proxy.nodes // [])[] | select(.name != $name)]
        | if .chain_proxy.active == $name then del(.chain_proxy.active) else . end
    '
}

# 检查链式代理节点是否存在 (返回 0=存在, 1=不存在)
db_chain_node_exists() {
    local name="$1"
    local result=$(jq -r --arg name "$name" '.chain_proxy.nodes[]? | select(.name == $name) | .name' "$DB_FILE" 2>/dev/null)
    [[ -n "$result" && "$result" != "null" ]]
}

# 重命名链式代理节点
# 返回: 0=成功, 1=目标名已存在或源不存在, 2=写入失败
db_rename_chain_node() {
    local old_name="$1" new_name="$2"
    [[ -z "$old_name" || -z "$new_name" || "$old_name" == "$new_name" ]] && return 1
    db_chain_node_exists "$old_name" || return 1
    if db_chain_node_exists "$new_name"; then
        return 1
    fi

    if _db_apply --arg old "$old_name" --arg new "$new_name" '
        .chain_proxy.nodes = [(.chain_proxy.nodes // [])[] | if .name == $old then .name = $new else . end]
        | if .chain_proxy.active == $old then .chain_proxy.active = $new else . end
        | if .routing_rules then
            .routing_rules = [.routing_rules[] | if .outbound == ("chain:" + $old) then .outbound = ("chain:" + $new) else . end]
          else . end
        | if .balancer_groups then
            .balancer_groups = [.balancer_groups[] | if .nodes then .nodes = [.nodes[] | if . == $old then $new else . end] else . end]
          else . end
    '; then
        return 0
    fi

    return 2
}

# 解析 host:port 格式（支持 IPv6）
# 用法: _parse_hostport "hostport_string"
# 输出: host|port
_parse_hostport() {
    local hostport="$1"
    local host="" port=""

    # 处理 IPv6 地址 [xxxx]:port
    if [[ "$hostport" =~ ^\[([^\]]+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    elif [[ "$hostport" =~ ^\[([^\]]+)\]$ ]]; then
        host="${BASH_REMATCH[1]}"
        port=""
    elif [[ "$hostport" == "["* ]]; then
        # 备用方案：字符串处理
        local tmp="${hostport#\[}"
        if [[ "$tmp" == *"]:"* ]]; then
            host="${tmp%%\]:*}"
            port="${hostport##*\]:}"
        else
            host="${tmp%\]}"
            port=""
        fi
    else
        # IPv4 或域名
        host="${hostport%%:*}"
        port="${hostport##*:}"
        # 如果没有端口，port 会等于 host
        [[ "$host" == "$port" ]] && port=""
    fi

    echo "${host}|${port}"
}

# 解析代理链接 (支持 ss/vmess/vless/trojan/socks/naive)
_lite_validate_external_node() {
    local node="$1" transport encryption type
    type=$(jq -r '.type // ""' <<< "$node") || return 1
    transport=$(jq -r '.transport // .network // "tcp"' <<< "$node") || return 1
    case "$transport" in
        tcp|ws|grpc|http|httpupgrade) ;;
        *) _err "Sing-box 不支持外部传输: $transport" >&2; return 1 ;;
    esac
    if [[ "$type" == vless ]]; then
        encryption=$(jq -r '.encryption // "none"' <<< "$node")
        [[ -z "$encryption" || "$encryption" == none ]] || {
            _err "Sing-box 不支持 VLESS encryption=$encryption" >&2; return 1;
        }
    fi
}

parse_proxy_link() {
    local link="$1"
    local result=""

    case "$link" in
        socks://*|socks5://*)
            # SOCKS5 格式: socks://[user:pass@]host:port#name 或 socks5://...
            local content="${link#socks://}"
            content="${content#socks5://}"
            local name="" host="" port="" username="" password="" hostport=""

            # 提取名称
            [[ "$content" == *"#"* ]] && { name=$(urldecode "$(echo "$content" | sed 's/.*#//')"); content="${content%%#*}"; }

            # 移除查询参数
            content="${content%%\?*}"

            # 检查是否有认证信息
            if [[ "$content" == *"@"* ]]; then
                local userinfo="${content%%@*}"
                hostport="${content#*@}"
                username="${userinfo%%:*}"
                password="${userinfo#*:}"
                # URL 解码
                username=$(urldecode "$username")
                password=$(urldecode "$password")
            else
                hostport="$content"
            fi

            # 解析 host:port
            local parsed=$(_parse_hostport "$hostport")
            host="${parsed%%|*}"
            port="${parsed##*|}"

            # 确保 port 是纯数字
            port=$(echo "$port" | tr -d '"' | tr -d ' ')
            [[ ! "$port" =~ ^[0-9]+$ ]] && return 1

            [[ -z "$name" ]] && name="SOCKS5-${host}:${port}"
            if [[ -n "$host" && -n "$port" ]]; then
                if [[ -n "$username" ]]; then
                    result=$(jq -nc \
                        --arg name "$name" --arg host "$host" --argjson port "$port" \
                        --arg username "$username" --arg password "$password" \
                        '{name:$name,type:"socks",server:$host,port:$port,username:$username,password:$password}')
                else
                    result=$(jq -nc \
                        --arg name "$name" --arg host "$host" --argjson port "$port" \
                        '{name:$name,type:"socks",server:$host,port:$port}')
                fi
            fi
            ;;
        naive+https://*|naiveproxy://*)
            # NaiveProxy 格式: naive+https://user:pass@host:port#name
            local content="${link#naive+https://}"
            content="${content#naiveproxy://}"
            local name="" host="" port="" username="" password="" hostport=""

            # 提取名称
            [[ "$content" == *"#"* ]] && { name=$(urldecode "$(echo "$content" | sed 's/.*#//')"); content="${content%%#*}"; }

            # 移除查询参数
            content="${content%%\?*}"

            # 解析认证信息
            if [[ "$content" == *"@"* ]]; then
                local userinfo="${content%%@*}"
                hostport="${content#*@}"
                username="${userinfo%%:*}"
                password="${userinfo#*:}"
                # URL 解码
                username=$(urldecode "$username")
                password=$(urldecode "$password")
            else
                return 1  # NaiveProxy 必须有认证信息
            fi

            # 解析 host:port
            local parsed=$(_parse_hostport "$hostport")
            host="${parsed%%|*}"
            port="${parsed##*|}"

            # 确保 port 是纯数字
            port=$(echo "$port" | tr -d '"' | tr -d ' ')
            [[ ! "$port" =~ ^[0-9]+$ ]] && return 1

            [[ -z "$name" ]] && name="Naive-${host}:${port}"
            [[ -n "$host" && -n "$port" && -n "$username" && -n "$password" ]] && result=$(jq -nc \
                --arg name "$name" --arg host "$host" --argjson port "$port" \
                --arg username "$username" --arg password "$password" \
                '{name:$name,type:"naive",server:$host,port:$port,username:$username,password:$password}')
            ;;
        ss://*)
            # SS 格式:
            # 1. ss://base64(method:password)@host:port?params#name (SIP002 格式)
            # 2. ss://base64(method:password@host:port)#name (旧格式)
            local encoded="${link#ss://}"
            local name="" host="" port="" method="" password=""

            # 提取名称 (URL 解码)
            [[ "$encoded" == *"#"* ]] && { name=$(urldecode "$(echo "$encoded" | sed 's/.*#//')"); encoded="${encoded%%#*}"; }

            # 移除查询参数 (如 ?type=tcp&plugin=xxx)
            local params=""
            [[ "$encoded" == *"?"* ]] && { params="${encoded#*\?}"; encoded="${encoded%%\?*}"; }

            # SIP002 格式: base64(method:password)@host:port
            if [[ "$encoded" == *"@"* ]]; then
                local userinfo="${encoded%%@*}"
                local hostport="${encoded#*@}"

                # 解码 userinfo (method:password)
                local decoded=$(echo "$userinfo" | base64 -d 2>/dev/null)
                if [[ -n "$decoded" && "$decoded" == *":"* ]]; then
                    method="${decoded%%:*}"
                    password="${decoded#*:}"
                else
                    # 如果 base64 解码失败，可能是 URL 编码的明文格式
                    method=$(urldecode "${userinfo%%:*}")
                    password=$(urldecode "${userinfo#*:}")
                fi

                # 解析 host:port（支持 IPv6）
                local parsed=$(_parse_hostport "$hostport")
                host="${parsed%%|*}"
                port="${parsed##*|}"
            else
                # 旧格式: 整体 base64 编码 (method:password@host:port)
                local decoded=$(echo "$encoded" | base64 -d 2>/dev/null)
                if [[ -n "$decoded" && "$decoded" == *"@"* ]]; then
                    method=$(echo "$decoded" | cut -d: -f1)
                    password=$(echo "$decoded" | cut -d: -f2 | cut -d@ -f1)
                    local hostport_part="${decoded#*@}"
                    # 支持 IPv6: [::1]:port 或 host:port
                    if [[ "$hostport_part" == "["* ]]; then
                        host=$(echo "$hostport_part" | sed 's/^\[\([^]]*\)\].*/\1/')
                        port=$(echo "$hostport_part" | sed 's/.*\]://')
                    else
                        host=$(echo "$hostport_part" | cut -d: -f1)
                        port=$(echo "$hostport_part" | rev | cut -d: -f1 | rev)
                    fi
                fi
            fi

            # 确保 port 是纯数字
            port=$(echo "$port" | tr -d '"' | tr -d ' ')
            [[ ! "$port" =~ ^[0-9]+$ ]] && return 1

            [[ -z "$name" ]] && name="SS-${host##*.}"
            [[ -n "$host" && -n "$port" && -n "$method" && -n "$password" ]] && result=$(jq -nc \
                --arg name "$name" --arg type "shadowsocks" --arg host "$host" \
                --argjson port "$port" --arg method "$method" --arg password "$password" \
                '{name:$name,type:$type,server:$host,port:$port,method:$method,password:$password}')
            ;;
        vmess://*)
            # VMess 格式: vmess://base64(json)
            local decoded=$(echo "${link#vmess://}" | base64 -d 2>/dev/null)
            [[ -z "$decoded" ]] && return 1

            local name=$(echo "$decoded" | jq -r '.ps // .name // "VMess"')
            local host=$(echo "$decoded" | jq -r '.add // .server')
            local port=$(echo "$decoded" | jq -r '.port')
            local uuid=$(echo "$decoded" | jq -r '.id // .uuid')
            local aid=$(echo "$decoded" | jq -r '.aid // 0')
            local net=$(echo "$decoded" | jq -r '.net // "tcp"')
            local tls=$(echo "$decoded" | jq -r '.tls // ""')
            local ws_path=$(echo "$decoded" | jq -r '.path // "/"')
            local ws_host=$(echo "$decoded" | jq -r '.host // ""')

            # 确保 port 和 aid 是纯数字
            port=$(echo "$port" | tr -d '"' | tr -d ' ')
            [[ ! "$port" =~ ^[0-9]+$ ]] && return 1
            aid=$(echo "$aid" | tr -d '"' | tr -d ' ')
            [[ ! "$aid" =~ ^[0-9]+$ ]] && aid=0

            [[ -n "$host" && -n "$port" && -n "$uuid" ]] && result=$(jq -nc \
                --arg name "$name" --arg host "$host" --argjson port "$port" \
                --arg uuid "$uuid" --argjson aid "$aid" --arg net "$net" \
                --arg tls "$tls" --arg path "$ws_path" --arg wshost "$ws_host" \
                '{name:$name,type:"vmess",server:$host,port:$port,uuid:$uuid,alterId:$aid,network:$net,tls:$tls,wsPath:$path,wsHost:$wshost}')
            ;;
        vless://*)
            # VLESS 格式: vless://uuid@host:port?params#name
            local content="${link#vless://}"
            local name="" uuid="" host="" port=""

            [[ "$content" == *"#"* ]] && { name=$(urldecode "$(echo "$content" | sed 's/.*#//')"); content="${content%%#*}"; }
            uuid="${content%%@*}"
            local hostpart="${content#*@}"
            hostpart="${hostpart%%\?*}"

            # 解析 host:port（支持 IPv6）
            local parsed=$(_parse_hostport "$hostpart")
            host="${parsed%%|*}"
            port="${parsed##*|}"

            # 确保 port 是纯数字
            port=$(echo "$port" | tr -d '"' | tr -d ' ')
            [[ ! "$port" =~ ^[0-9]+$ ]] && return 1

            # 解析参数
            local params=""
            [[ "$content" == *"?"* ]] && params="${content#*\?}"
            local security=$(_get_query_param "$params" "security")
            [[ -z "$security" ]] && security="none"
            local sni=$(_get_query_param "$params" "sni")
            local fp=$(_get_query_param "$params" "fp")
            [[ -z "$fp" ]] && fp="chrome"
            local net=$(_get_query_param "$params" "type")
            [[ -z "$net" ]] && net="tcp"
            local pbk=$(_get_query_param "$params" "pbk")
            local sid=$(_get_query_param "$params" "sid")
            local flow=$(_get_query_param "$params" "flow")
            local encryption=$(_get_query_param "$params" "encryption")
            [[ -z "$encryption" ]] && encryption="none"
            # 提取 ws 协议的 path 和 host 参数
            local ws_path=$(_get_query_param "$params" "path")
            [[ -z "$ws_path" ]] && ws_path="/"
            ws_path=$(urldecode "$ws_path")  # URL 解码 path
            local ws_host=$(_get_query_param "$params" "host")

            [[ -z "$name" ]] && name="VLESS-${host##*.}"
            [[ -n "$host" && -n "$port" && -n "$uuid" ]] && result=$(jq -nc \
                --arg name "$name" --arg host "$host" --argjson port "$port" \
                --arg uuid "$uuid" --arg security "$security" --arg sni "$sni" \
                --arg fp "$fp" --arg net "$net" --arg pbk "$pbk" --arg sid "$sid" --arg flow "$flow" --arg enc "$encryption" \
                --arg wsPath "$ws_path" --arg wsHost "$ws_host" \
                '{name:$name,type:"vless",server:$host,port:$port,uuid:$uuid,security:$security,sni:$sni,fingerprint:$fp,network:$net,publicKey:$pbk,shortId:$sid,flow:$flow,encryption:$enc,wsPath:$wsPath,wsHost:$wsHost}')
            ;;
        trojan://*)
            # Trojan 格式: trojan://password@host:port?params#name
            local content="${link#trojan://}"
            local name="" password="" host="" port=""

            [[ "$content" == *"#"* ]] && { name=$(urldecode "$(echo "$content" | sed 's/.*#//')"); content="${content%%#*}"; }
            password="${content%%@*}"
            local hostpart="${content#*@}"
            hostpart="${hostpart%%\?*}"

            # 解析 host:port（支持 IPv6）
            local parsed=$(_parse_hostport "$hostpart")
            host="${parsed%%|*}"
            port="${parsed##*|}"

            # 确保 port 是纯数字
            port=$(echo "$port" | tr -d '"' | tr -d ' ')
            [[ ! "$port" =~ ^[0-9]+$ ]] && return 1

            local params=""
            [[ "$content" == *"?"* ]] && params="${content#*\?}"
            local sni=$(_get_query_param "$params" "sni")
            [[ -z "$sni" ]] && sni="$host"

            local net=$(_get_query_param "$params" type)
            local ws_path=$(_get_query_param "$params" path)
            local ws_host=$(_get_query_param "$params" host)
            local service_name=$(_get_query_param "$params" serviceName)
            [[ -z "$name" ]] && name="Trojan-${host##*.}"
            [[ -n "$host" && -n "$port" && -n "$password" ]] && result=$(jq -nc \
                --arg name "$name" --arg host "$host" --argjson port "$port" \
                --arg password "$password" --arg sni "$sni" --arg net "${net:-tcp}" \
                --arg path "$(urldecode "$ws_path")" --arg hostheader "$(urldecode "$ws_host")" --arg service "$service_name" \
                '{name:$name,type:"trojan",server:$host,port:$port,password:$password,sni:$sni,network:$net,path:$path,host:$hostheader,serviceName:$service}' )
            ;;
        hy2://*|hysteria2://*)
            # Hysteria2 格式: hy2://password@host:port?params#name
            local content="${link#hy2://}"
            content="${content#hysteria2://}"
            local name="" password="" host="" port=""

            [[ "$content" == *"#"* ]] && { name=$(urldecode "$(echo "$content" | sed 's/.*#//')"); content="${content%%#*}"; }
            password="${content%%@*}"
            local hostpart="${content#*@}"
            hostpart="${hostpart%%\?*}"

            # 解析 host:port（支持 IPv6）
            local parsed=$(_parse_hostport "$hostpart")
            host="${parsed%%|*}"
            port="${parsed##*|}"

            # 确保 port 是纯数字
            port=$(echo "$port" | tr -d '"' | tr -d ' ')
            [[ ! "$port" =~ ^[0-9]+$ ]] && return 1

            local params=""
            [[ "$content" == *"?"* ]] && params="${content#*\?}"
            local sni=$(_get_query_param "$params" "sni")
            [[ -z "$sni" ]] && sni="$host"
            local insecure=$(_get_query_param "$params" "insecure")
            [[ -z "$insecure" ]] && insecure="0"

            [[ -z "$name" ]] && name="HY2-${host##*.}"
            [[ -n "$host" && -n "$port" && -n "$password" ]] && result=$(jq -nc \
                --arg name "$name" --arg host "$host" --argjson port "$port" \
                --arg password "$password" --arg sni "$sni" --arg insecure "$insecure" \
                '{name:$name,type:"hysteria2",server:$host,port:$port,password:$password,sni:$sni,insecure:$insecure}')
            ;;
    esac

    [[ -n "$result" ]] || return 1
    _lite_validate_external_node "$result" || return 1
    echo "$result"
}

# 解析订阅链接
parse_subscription() {
    local url="$1"
    local content nodes=()
    local allowed_protocols="=https"

    if ! _is_valid_subscription_url "$url"; then
        _err "订阅地址无效：仅允许 HTTPS；如确需 HTTP，请显式设置 ALLOW_INSECURE_HTTP_SUBSCRIPTIONS=1"
        return 1
    fi
    [[ "${ALLOW_INSECURE_HTTP_SUBSCRIPTIONS:-0}" == "1" ]] && allowed_protocols="=http,https"

    _info "获取订阅内容..."
    if ! content=$(curl -sL --connect-timeout 10 --max-time 30 \
        --max-filesize "$SUBSCRIPTION_MAX_BYTES" \
        --proto "$allowed_protocols" --proto-redir "$allowed_protocols" \
        -- "$url" 2>/dev/null); then
        _err "获取订阅失败、超时或内容超过 10 MiB"
        return 1
    fi
    [[ -z "$content" ]] && { _err "获取订阅失败"; return 1; }

    # 尝试 base64 解码
    local decoded=$(echo "$content" | base64 -d 2>/dev/null)
    [[ -n "$decoded" ]] && content="$decoded"

    # 按行解析
    local count=0
    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '\r')
        [[ -z "$line" || "$line" == "#"* ]] && continue

        local node=$(parse_proxy_link "$line")
        if [[ -n "$node" ]]; then
            echo "$node"
            ((count++))
        fi
    done <<< "$content"

    [[ $count -eq 0 ]] && { _err "未解析到有效节点"; return 1; }
    _ok "解析到 $count 个节点"
}

# 第三个参数 ip_mode: ipv4_only, ipv6_only, prefer_ipv4 (默认), prefer_ipv6
# 第四个参数 dialer_proxy: 可选，指定通过哪个 outbound 连接 (用于双层链式代理)


# 生成 Sing-box 链式代理 outbound (支持指定节点名/节点JSON和自定义 tag)
# 用法: gen_singbox_chain_outbound [节点名|节点JSON] [tag] [ip_mode]
# 第三个参数 ip_mode: ipv4_only, ipv6_only, prefer_ipv4 (默认), prefer_ipv6
gen_singbox_chain_outbound() {
    local node_ref="${1:-$(db_get_chain_active)}"
    local tag="${2:-chain}"
    local ip_mode="${3:-prefer_ipv4}"  # 第三个参数，默认 prefer_ipv4
    local db_file="${4:-$DB_FILE}"
    [[ -z "$node_ref" ]] && return

    local node=""
    if [[ "$node_ref" =~ ^\{ ]]; then
        node="$node_ref"
    else
        node=$(jq -c --arg name "$node_ref" '.chain_proxy.nodes[]? | select(.name == $name)' "$db_file")
    fi
    [[ -z "$node" || "$node" == "null" ]] && return

    _lite_validate_external_node "$node" || return 1
    local type=$(echo "$node" | jq -r '.type')
    local server=$(echo "$node" | jq -r '.server')
    local port=$(echo "$node" | jq -r '.port')

    # 根据 ip_mode 设置 Sing-box 的 domain_strategy
    local domain_strategy="prefer_ipv4"
    case "$ip_mode" in
        ipv6_only) domain_strategy=ipv6_only ;;
        ipv4_only) domain_strategy=ipv4_only ;;
        prefer_ipv6)
            domain_strategy="prefer_ipv6"
            ;;
        prefer_ipv4|*)
            domain_strategy="prefer_ipv4"
            ;;
    esac

    case "$type" in
        socks)
            local username=$(echo "$node" | jq -r '.username // ""')
            local password=$(echo "$node" | jq -r '.password // ""')
            if [[ -n "$username" && -n "$password" ]]; then
                jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                    --arg user "$username" --arg pass "$password" --arg ds "$domain_strategy" \
                    '{tag:$tag,type:"socks",server:$server,server_port:$port,username:$user,password:$pass,domain_strategy:$ds}'
            else
                jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg ds "$domain_strategy" \
                    '{tag:$tag,type:"socks",server:$server,server_port:$port,domain_strategy:$ds}'
            fi
            ;;
        http)
            local username=$(echo "$node" | jq -r '.username // ""')
            local password=$(echo "$node" | jq -r '.password // ""')
            if [[ -n "$username" && -n "$password" ]]; then
                jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                    --arg user "$username" --arg pass "$password" --arg ds "$domain_strategy" \
                    '{tag:$tag,type:"http",server:$server,server_port:$port,username:$user,password:$pass,domain_strategy:$ds}'
            else
                jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg ds "$domain_strategy" \
                    '{tag:$tag,type:"http",server:$server,server_port:$port,domain_strategy:$ds}'
            fi
            ;;
        shadowsocks)
            local method=$(echo "$node" | jq -r '.method')
            local password=$(echo "$node" | jq -r '.password')
            jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg method "$method" --arg password "$password" --arg ds "$domain_strategy" \
                '{tag:$tag,type:"shadowsocks",server:$server,server_port:$port,method:$method,password:$password,domain_strategy:$ds}'
            ;;
        vmess)
            jq --arg tag "$tag" --arg ds "$domain_strategy" '
                . as $n | {tag:$tag,type:"vmess",server:.server,server_port:.port,uuid:.uuid,
                security:(.cipher // "auto"),alter_id:(.alterId // 0 | tonumber),domain_strategy:$ds} +
                (if $n.tls == "tls" or $n.tls == true then
                    {tls:{enabled:true,server_name:($n.sni // $n.server)}} else {} end) +
                (if ($n.transport // $n.network // "tcp") == "ws" then
                    {transport:{type:"ws",path:($n.path // $n.wsPath // "/"),headers:{Host:($n.host // $n.wsHost // "")}}}
                 elif ($n.transport // $n.network // "tcp") == "grpc" then
                    {transport:{type:"grpc",service_name:($n.serviceName // $n.path // "")}}
                 elif ($n.transport // $n.network // "tcp") != "tcp" then
                    {transport:{type:($n.transport // $n.network),path:($n.path // "/")}}
                 else {} end)' <<< "$node"
            ;;
        vless)
            local uuid=$(echo "$node" | jq -r '.uuid')
            local security=$(echo "$node" | jq -r '.security // "none"')
            local sni=$(echo "$node" | jq -r '.sni // ""')
            local fp=$(echo "$node" | jq -r '.fingerprint // "chrome"')
            local pbk=$(echo "$node" | jq -r '.publicKey // ""')
            local sid=$(echo "$node" | jq -r '.shortId // ""')
            local flow=$(echo "$node" | jq -r '.flow // ""')
            local net=$(echo "$node" | jq -r '.transport // .network // "tcp"')
            local ws_path=$(echo "$node" | jq -r '.path // .wsPath // "/"')
            local ws_host=$(echo "$node" | jq -r '.host // .wsHost // ""')

            local base=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg uuid "$uuid" --arg ds "$domain_strategy" \
                '{tag:$tag,type:"vless",server:$server,server_port:$port,uuid:$uuid,domain_strategy:$ds}')

            # 添加 flow 字段（如 xtls-rprx-vision）
            if [[ -n "$flow" && "$flow" != "null" && "$flow" != "" ]]; then
                base=$(echo "$base" | jq --arg flow "$flow" '.flow = $flow')
            fi

            # 处理 WebSocket 传输
            if [[ "$net" == "ws" ]]; then
                base=$(echo "$base" | jq --arg path "$ws_path" --arg host "$ws_host" \
                    '.transport={type:"ws",path:$path,headers:{Host:$host}}')
                if [[ "$security" == "tls" ]]; then
                    base=$(echo "$base" | jq --arg sni "$sni" '.tls={enabled:true,server_name:$sni}')
                fi
            elif [[ "$security" == "reality" ]]; then
                base=$(echo "$base" | jq --arg sni "$sni" --arg fp "$fp" --arg pbk "$pbk" --arg sid "$sid" \
                    '.tls={enabled:true,server_name:$sni,reality:{enabled:true,public_key:$pbk,short_id:$sid},utls:{enabled:true,fingerprint:$fp}}')
            elif [[ "$security" == "tls" ]]; then
                base=$(echo "$base" | jq --arg sni "$sni" '.tls={enabled:true,server_name:$sni}')
            fi
            case "$net" in
                grpc) base=$(jq --arg path "$ws_path" '.transport={type:"grpc",service_name:$path}' <<< "$base") ;;
                http) base=$(jq --arg path "$ws_path" --arg host "$ws_host" '.transport={type:"http",path:$path,host:[$host]}' <<< "$base") ;;
                httpupgrade) base=$(jq --arg path "$ws_path" --arg host "$ws_host" '.transport={type:"httpupgrade",path:$path,host:$host}' <<< "$base") ;;
            esac
            echo "$base"
            ;;
        trojan)
            jq --arg tag "$tag" --arg ds "$domain_strategy" '
                . as $n | {tag:$tag,type:"trojan",server:.server,server_port:.port,password:.password,
                tls:{enabled:true,server_name:(if (.sni // "") == "" then .server else .sni end)},domain_strategy:$ds} +
                (if ($n.transport // $n.network // "tcp") == "ws" then
                    {transport:{type:"ws",path:($n.path // $n.wsPath // "/"),headers:{Host:($n.host // $n.wsHost // "")}}}
                 elif ($n.transport // $n.network // "tcp") == "grpc" then
                    {transport:{type:"grpc",service_name:($n.serviceName // $n.path // "")}}
                 elif ($n.transport // $n.network // "tcp") != "tcp" then
                    {transport:{type:($n.transport // $n.network),path:($n.path // "/")}}
                 else {} end)' <<< "$node"
            ;;
        hysteria2)
            local password=$(echo "$node" | jq -r '.password')
            local sni=$(echo "$node" | jq -r '.sni // ""')
            local insecure=$(echo "$node" | jq -r '.insecure // "0"')
            [[ -z "$sni" ]] && sni="$server"

            local base=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg password "$password" --arg sni "$sni" --arg ds "$domain_strategy" \
                '{tag:$tag,type:"hysteria2",server:$server,server_port:$port,password:$password,tls:{enabled:true,server_name:$sni},domain_strategy:$ds}')
            [[ "$insecure" == "1" ]] && base=$(echo "$base" | jq '.tls.insecure=true')
            echo "$base"
            ;;
        naive)
            # NaiveProxy (HTTP/2 代理)
            local username=$(echo "$node" | jq -r '.username')
            local password=$(echo "$node" | jq -r '.password')

            jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                --arg user "$username" --arg pass "$password" --arg ds "$domain_strategy" \
                '{tag:$tag,type:"naive",server:$server,server_port:$port,username:$user,password:$pass,tls:{enabled:true,server_name:$server},domain_strategy:$ds}'
            ;;
    esac
}

# 添加节点交互 (带解析预览和自定义名称)
_add_chain_node_interactive() {
    _header
    echo -e "  ${W}添加代理节点${NC}"
    _line
    echo -e "  ${D}支持: ss/vmess/vless/trojan/hysteria2/socks5/naive${NC}"
    echo ""

    echo -e "  ${Y}粘贴代理链接:${NC}"
    read -rp "  链接: " link
    [[ -z "$link" ]] && return

    # 解析链接
    echo ""
    echo -e "  ${C}▸${NC} 解析链接中..."
    local node=$(parse_proxy_link "$link")

    if [[ -z "$node" ]]; then
        _err "链接解析失败，请检查格式"
        _pause
        return
    fi

    # 提取节点信息
    local orig_name=$(echo "$node" | jq -r '.name // "未知"')
    local type=$(echo "$node" | jq -r '.type // "未知"')
    local server=$(echo "$node" | jq -r '.server // "未知"')
    local port=$(echo "$node" | jq -r '.port // "未知"')

    # 显示解析预览
    echo ""
    _line
    echo -e "  ${G}✓${NC} 解析成功"
    _line
    echo -e "  节点名称: ${C}$orig_name${NC}"
    echo -e "  协议类型: ${C}$type${NC}"
    echo -e "  服务器:   ${C}$server${NC}"
    echo -e "  端口:     ${C}$port${NC}"
    _line

    # 询问是否自定义名称
    echo ""
    echo -e "  ${D}直接回车使用原名称，或输入新名称${NC}"
    read -rp "  自定义名称 [$orig_name]: " custom_name

    local final_name="${custom_name:-$orig_name}"

    # 检查是否已存在同名节点
    if db_chain_node_exists "$final_name"; then
        echo ""
        _warn "节点 '$final_name' 已存在"
        read -rp "  是否覆盖? [y/N]: " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            _info "已取消"
            _pause
            return
        fi
        db_del_chain_node "$final_name"
    fi

    # 更新节点名称
    if [[ "$final_name" != "$orig_name" ]]; then
        node=$(echo "$node" | jq --arg name "$final_name" '.name = $name')
    fi

    # 保存节点
    if db_add_chain_node "$node"; then
        echo ""
        _ok "节点已添加: $final_name"

        # 询问是否立即配置分流
        echo ""
        read -rp "  是否立即将此节点用于分流? [y/N]: " use_now
        if [[ "$use_now" =~ ^[Yy]$ ]]; then
            _add_routing_rule
            return
        fi
    else
        _err "添加节点失败"
    fi

    _pause
}

# 导入订阅交互 (带预览确认)
_import_subscription_interactive() {
    _header
    echo -e "  ${W}导入订阅${NC}"
    _line

    echo -e "  ${Y}输入订阅链接:${NC}"
    read -rp "  URL: " sub_url
    [[ -z "$sub_url" ]] && return

    echo ""
    echo -e "  ${C}▸${NC} 获取订阅内容..."

    # 解析订阅
    local parsed_nodes=$(parse_subscription "$sub_url")

    if [[ -z "$parsed_nodes" ]]; then
        _err "订阅解析失败，请检查链接"
        _pause
        return
    fi

    # 统计节点数量和类型
    local total_count=0
    declare -A types

    while IFS= read -r node; do
        [[ -z "$node" ]] && continue
        if ! echo "$node" | jq empty 2>/dev/null; then
            continue
        fi
        ((total_count++))
        local t=$(echo "$node" | jq -r '.type // "unknown"' 2>/dev/null)
        [[ -z "$t" || "$t" == "null" ]] && t="unknown"
        ((types[$t]++))
    done <<< "$parsed_nodes"

    if [[ $total_count -eq 0 ]]; then
        _err "订阅中没有有效节点"
        _pause
        return
    fi

    # 显示协议统计
    echo ""
    _line
    echo -e "  ${G}✓${NC} 解析成功，共 ${C}$total_count${NC} 个节点"
    _line
    echo -e "  ${W}协议统计:${NC}"
    for t in "${!types[@]}"; do
        echo -e "    • $t: ${types[$t]} 个"
    done

    # 预览阶段：检测延迟并显示 (复用测试延迟的逻辑)
    echo ""
    echo -e "  ${C}▸${NC} 检测节点延迟中... (并发 ${LATENCY_PARALLEL})"

    local tmp_results=$(mktemp)
    local tmp_nodes=$(mktemp)
    local i=0

    while IFS= read -r node; do
        [[ -z "$node" ]] && continue
        if ! echo "$node" | jq empty 2>/dev/null; then
            continue
        fi
        ((i++))

        # 保存原始节点 JSON 用于后续导入与批量测速
        echo "$node" >> "$tmp_nodes"

        printf "\r  ${C}▸${NC} 检测中... (%d/%d)  " "$i" "$total_count" >&2
    done <<< "$parsed_nodes"

    echo "" >&2
    _batch_latency_nodes "$tmp_results" "$LATENCY_PARALLEL" < "$tmp_nodes"

    echo ""
    echo -e "  ${W}节点列表 (按延迟排序):${NC}"
    _line

    _display_sorted_latencies "$tmp_results"

    _line

    # 确认导入
    echo ""
    read -rp "  确认导入这 $total_count 个节点? [Y/n]: " confirm

    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        _info "已取消导入"
        rm -f "$tmp_results" "$tmp_nodes"
        _pause
        return
    fi

    # 执行导入
    echo ""
    echo -e "  ${C}▸${NC} 正在导入..."

    local added=0
    local skipped=0
    local failed=0

    while IFS= read -r node; do
        [[ -z "$node" ]] && continue
        if ! echo "$node" | jq empty 2>/dev/null; then
            ((failed++))
            continue
        fi

        local name=$(echo "$node" | jq -r '.name' 2>/dev/null)

        # 检查是否已存在
        if db_chain_node_exists "$name"; then
            ((skipped++))
            continue
        fi

        if db_add_chain_node "$node"; then
            ((added++))
        else
            ((failed++))
        fi
    done < "$tmp_nodes"

    rm -f "$tmp_results" "$tmp_nodes"

    echo ""
    _ok "导入完成"
    echo -e "  新增: ${G}$added${NC} 个"
    [[ $skipped -gt 0 ]] && echo -e "  跳过 (已存在): ${Y}$skipped${NC} 个"
    [[ $failed -gt 0 ]] && echo -e "  失败: ${R}$failed${NC} 个"

    _pause
}

# 链式代理管理菜单
# 一键导入 Alice SOCKS5 节点 (8个出口)
_import_alice_nodes() {
    _header
    echo -e "  ${W}导入 Alice SOCKS5 节点${NC}"
    _line
    echo -e "  ${D}Alice 提供 8 个 SOCKS5 出口 (端口 10001-10008)${NC}"
    echo -e "  ${D}统一命名为 Alice-TW-SOCKS5-01 ~ 08${NC}"
    echo ""

    # 先删除所有旧的 Alice-TW-SOCKS5 节点
    local old_nodes=$(db_get_chain_nodes 2>/dev/null)
    local deleted=0
    if [[ -n "$old_nodes" && "$old_nodes" != "[]" ]]; then
        while IFS= read -r node_name; do
            if [[ "$node_name" =~ ^Alice-TW-SOCKS5- ]]; then
                db_del_chain_node "$node_name"
                ((deleted++))
            fi
        done < <(echo "$old_nodes" | jq -r '.[].name')
    fi

    if [[ $deleted -gt 0 ]]; then
        echo -e "  ${C}▸${NC} 清理了 $deleted 个旧节点"
        # 同时清理相关的分流规则
        _db_apply '.routing_rules = [.routing_rules[]? | select(.outbound | (startswith("chain:Alice-TW-SOCKS5-") | not))]'
    fi

    local server="2a14:67c0:116::1"
    local username="alice"
    local password="alicefofo123..OVO"
    local base_port=10001
    local imported=0

    echo -e "  ${C}▸${NC} 开始导入 8 个节点..."
    echo ""

    for i in {1..8}; do
        local port=$((base_port + i - 1))

        # 生成节点名称: Alice-TW-SOCKS5-01, Alice-TW-SOCKS5-02, ...
        local name=$(printf "Alice-TW-SOCKS5-%02d" "$i")

        # 构建节点 JSON
        local node=$(jq -n \
            --arg name "$name" \
            --arg server "$server" \
            --argjson port "$port" \
            --arg username "$username" \
            --arg password "$password" \
            '{name:$name,type:"socks",server:$server,port:$port,username:$username,password:$password}')

        if db_add_chain_node "$node"; then
            echo -e "  ${G}✓${NC} $name ${D}(端口 $port)${NC}"
            ((imported++))
        else
            echo -e "  ${R}✗${NC} $name ${D}(端口 $port, 添加失败)${NC}"
        fi
    done

    echo ""
    _line
    if [[ $imported -eq 8 ]]; then
        _ok "成功导入全部 8 个节点"
    elif [[ $imported -gt 0 ]]; then
        _warn "导入了 $imported 个节点 (预期 8 个)"
    else
        _warn "没有成功导入任何节点"
    fi

    # 如果成功导入节点,询问是否创建负载均衡组
    if [[ $imported -gt 0 ]]; then
        echo ""
        _line
        echo -e "  ${W}负载均衡配置${NC}"
        echo ""

        # 检查是否已存在 Alice 负载均衡组
        local group_name="Alice-TW-SOCKS5-LB"
        local existing_group=$(db_get_balancer_group "$group_name" 2>/dev/null)

        if [[ -n "$existing_group" && "$existing_group" != "null" ]]; then
            echo -e "  ${Y}⚠${NC}  已存在负载均衡组: ${C}$group_name${NC}"
            local strategy=$(echo "$existing_group" | jq -r '.strategy')
            local node_count=$(echo "$existing_group" | jq -r '.nodes | length')
            echo -e "  策略: ${D}$strategy${NC}, 节点数: ${D}$node_count${NC}"
            echo ""
            echo -e "  ${W}选择操作:${NC}"
            echo -e "    ${C}1.${NC} 保持现有配置 ${D}(不修改)${NC}"
            echo -e "    ${C}2.${NC} 删除负载均衡组 ${D}(清除配置)${NC}"
            echo -e "    ${C}3.${NC} 重新创建负载均衡组 ${D}(覆盖现有)${NC}"
            echo ""

            local choice
            read -p "  请选择 [1-3, 默认 1]: " choice
            choice=${choice:-1}

            case "$choice" in
                2)
                    db_delete_balancer_group "$group_name"
                    _ok "已删除负载均衡组: $group_name"
                    echo ""
                    echo -e "  ${Y}提示:${NC} 请到 ${C}分流规则${NC} 中手动配置节点"
                    ;;
                3)
                    db_delete_balancer_group "$group_name"
                    _create_alice_balancer_inline "$imported"
                    ;;
                *)
                    _info "保持现有配置"
                    ;;
            esac
        else
            echo -e "  是否创建负载均衡组? ${D}(方便自动分配流量)${NC}"
            echo ""
            echo -e "    ${C}Y${NC} - 创建负载均衡组 ${D}(推荐)${NC}"
            echo -e "    ${C}N${NC} - 稍后手动配置"
            echo ""

            local create_lb
            read -p "  请选择 [Y/n]: " create_lb

            if [[ ! "$create_lb" =~ ^[Nn]$ ]]; then
                _create_alice_balancer_inline "$imported"
            else
                _info "跳过负载均衡配置"
                echo ""
                echo -e "  ${Y}提示:${NC} 请到 ${C}链式代理管理 → 创建负载均衡组${NC} 中配置"
            fi
        fi
    fi

    _pause
}

# 内联创建 Alice 负载均衡组 (供导入流程调用)
_create_alice_balancer_inline() {
    local node_count=${1:-8}

    echo ""
    echo -e "  ${W}配置负载均衡策略:${NC}"
    echo -e "    ${C}1.${NC} leastPing   ${D}(最低延迟 - 推荐)${NC}"
    echo -e "    ${C}2.${NC} selector    ${D}(固定首节点)${NC}"
    echo ""
    echo -e "  ${Y}说明:${NC} leastPing会自动选择延迟最低的节点"
    echo ""

    local strategy_choice
    read -p "  请选择策略 [1-3, 默认 1]: " strategy_choice
    strategy_choice=${strategy_choice:-1}

    local strategy
    case "$strategy_choice" in
        2) strategy="selector" ;;
        3) strategy="selector" ;;
        *) strategy="leastPing" ;;
    esac

    # 获取所有 Alice 节点
    local alice_nodes=()
    local all_nodes=$(db_get_chain_nodes)
    while IFS= read -r node_name; do
        [[ "$node_name" =~ ^Alice-TW-SOCKS5- ]] && alice_nodes+=("$node_name")
    done < <(echo "$all_nodes" | jq -r '.[].name')

    # 创建负载均衡组
    local group_name="Alice-TW-SOCKS5-LB"
    db_add_balancer_group "$group_name" "$strategy" "${alice_nodes[@]}"

    echo ""
    _ok "负载均衡组创建成功"
    echo ""
    echo -e "  组名: ${C}$group_name${NC}"
    echo -e "  策略: ${C}$strategy${NC}"
    echo -e "  节点数: ${G}${#alice_nodes[@]}${NC}"
    echo ""
    echo -e "  ${Y}下一步:${NC} 到 ${C}分流规则${NC} 中添加规则"
    echo -e "  出口选择: ${C}负载均衡:${group_name}${NC}"
}

# 一键导入 Akile SOCKS5 节点 (12个出口)
_import_akile_nodes() {
    _header
    echo -e "  ${W}导入 Akile SOCKS5 节点${NC}"
    _line
    echo -e "  ${D}Akile 提供 12 个 SOCKS5 出口 (多地区)${NC}"
    echo -e "  ${D}包括: HK/JP/KR/TW/SG/US/UK/DE 等地区${NC}"
    echo ""

    # 先删除所有旧的 Akile 节点
    local old_nodes=$(db_get_chain_nodes 2>/dev/null)
    local deleted=0
    if [[ -n "$old_nodes" && "$old_nodes" != "[]" ]]; then
        while IFS= read -r node_name; do
            if [[ "$node_name" =~ ^Akile- ]]; then
                db_del_chain_node "$node_name"
                ((deleted++))
            fi
        done < <(echo "$old_nodes" | jq -r '.[].name')
    fi

    if [[ $deleted -gt 0 ]]; then
        echo -e "  ${C}▸${NC} 清理了 $deleted 个旧节点"
        # 同时清理相关的分流规则
        _db_apply '.routing_rules = [.routing_rules[]? | select(.outbound | (startswith("chain:Akile-") | not))]'
    fi

    local username="akilecloud"
    local password="akilecloud"
    local imported=0

    # 定义所有 Akile 节点: 名称|服务器|端口
    local nodes_data=(
        "Akile-HK-RANDOMIPV6|45.8.186.151|58888"
        "Akile-JP-RANDOMIPV6|203.10.99.23|58888"
        "Akile-KR-RANDOMIPV6|141.11.131.253|58888"
        "Akile-TW-RANDOMIPV6|45.207.158.22|58888"
        "Akile-SG-RANDOMIPV6|104.192.92.63|58888"
        "Akile-US-RANDOMIPV6|154.83.90.2|58888"
        "Akile-UK-RANDOMIPV6|212.135.39.2|58888"
        "Akile-DE-RANDOMIPV6|45.196.222.2|58888"
        "Akile-JP-SOFTBANK|141.11.131.205|58888"
        "Akile-JP-KDDI|141.11.131.205|59999"
        "Akile-TW-HINET|45.207.158.220|58888"
        "Akile-HK-HKBN|45.207.156.2|58888"
    )

    echo -e "  ${C}▸${NC} 开始导入 ${#nodes_data[@]} 个节点..."
    echo ""

    for node_info in "${nodes_data[@]}"; do
        IFS='|' read -r name server port <<< "$node_info"

        # 构建节点 JSON
        local node=$(jq -n \
            --arg name "$name" \
            --arg server "$server" \
            --argjson port "$port" \
            --arg username "$username" \
            --arg password "$password" \
            '{name:$name,type:"socks",server:$server,port:$port,username:$username,password:$password}')

        if db_add_chain_node "$node"; then
            echo -e "  ${G}✓${NC} $name ${D}($server:$port)${NC}"
            ((imported++))
        else
            echo -e "  ${R}✗${NC} $name ${D}($server:$port, 添加失败)${NC}"
        fi
    done

    echo ""
    _line
    if [[ $imported -eq ${#nodes_data[@]} ]]; then
        _ok "成功导入全部 ${#nodes_data[@]} 个节点"
    elif [[ $imported -gt 0 ]]; then
        _warn "导入了 $imported 个节点 (预期 ${#nodes_data[@]} 个)"
    else
        _warn "没有成功导入任何节点"
    fi

    # 如果成功导入节点,询问是否创建负载均衡组
    if [[ $imported -gt 0 ]]; then
        echo ""
        _line
        echo -e "  ${W}负载均衡配置${NC}"
        echo ""

        # 检查是否已存在 Akile 负载均衡组
        local group_name="Akile-SOCKS5-LB"
        local existing_group=$(db_get_balancer_group "$group_name" 2>/dev/null)

        if [[ -n "$existing_group" && "$existing_group" != "null" ]]; then
            echo -e "  ${Y}⚠${NC}  已存在负载均衡组: ${C}$group_name${NC}"
            local strategy=$(echo "$existing_group" | jq -r '.strategy')
            local node_count=$(echo "$existing_group" | jq -r '.nodes | length')
            echo -e "  策略: ${D}$strategy${NC}, 节点数: ${D}$node_count${NC}"
            echo ""
            echo -e "  ${W}选择操作:${NC}"
            echo -e "    ${C}1.${NC} 保持现有配置 ${D}(不修改)${NC}"
            echo -e "    ${C}2.${NC} 删除负载均衡组 ${D}(清除配置)${NC}"
            echo -e "    ${C}3.${NC} 重新创建负载均衡组 ${D}(覆盖现有)${NC}"
            echo ""

            local choice
            read -p "  请选择 [1-3, 默认 1]: " choice
            choice=${choice:-1}

            case "$choice" in
                2)
                    db_delete_balancer_group "$group_name"
                    _ok "已删除负载均衡组: $group_name"
                    echo ""
                    echo -e "  ${Y}提示:${NC} 请到 ${C}分流规则${NC} 中手动配置节点"
                    ;;
                3)
                    db_delete_balancer_group "$group_name"
                    _create_akile_balancer_inline "$imported"
                    ;;
                *)
                    _info "保持现有配置"
                    ;;
            esac
        else
            echo -e "  是否创建负载均衡组? ${D}(方便自动分配流量)${NC}"
            echo ""
            echo -e "    ${C}Y${NC} - 创建负载均衡组 ${D}(推荐)${NC}"
            echo -e "    ${C}N${NC} - 稍后手动配置"
            echo ""

            local create_lb
            read -p "  请选择 [Y/n]: " create_lb

            if [[ ! "$create_lb" =~ ^[Nn]$ ]]; then
                _create_akile_balancer_inline "$imported"
            else
                _info "跳过负载均衡配置"
                echo ""
                echo -e "  ${Y}提示:${NC} 请到 ${C}链式代理管理 → 创建负载均衡组${NC} 中配置"
            fi
        fi
    fi

    _pause
}

# 内联创建 Akile 负载均衡组 (供导入流程调用)
_create_akile_balancer_inline() {
    local node_count=${1:-12}

    echo ""
    echo -e "  ${W}配置负载均衡策略:${NC}"
    echo -e "    ${C}1.${NC} leastPing   ${D}(最低延迟 - 推荐)${NC}"
    echo -e "    ${C}2.${NC} selector    ${D}(固定首节点)${NC}"
    echo ""
    echo -e "  ${Y}说明:${NC} leastPing会自动选择延迟最低的节点"
    echo ""

    local strategy_choice
    read -p "  请选择策略 [1-3, 默认 1]: " strategy_choice
    strategy_choice=${strategy_choice:-1}

    local strategy
    case "$strategy_choice" in
        2) strategy="selector" ;;
        3) strategy="selector" ;;
        *) strategy="leastPing" ;;
    esac

    # 获取所有 Akile 节点
    local akile_nodes=()
    local all_nodes=$(db_get_chain_nodes)
    while IFS= read -r node_name; do
        [[ "$node_name" =~ ^Akile- ]] && akile_nodes+=("$node_name")
    done < <(echo "$all_nodes" | jq -r '.[].name')

    # 创建负载均衡组
    local group_name="Akile-SOCKS5-LB"
    db_add_balancer_group "$group_name" "$strategy" "${akile_nodes[@]}"

    echo ""
    _ok "负载均衡组创建成功"
    echo ""
    echo -e "  组名: ${C}$group_name${NC}"
    echo -e "  策略: ${C}$strategy${NC}"
    echo -e "  节点数: ${G}${#akile_nodes[@]}${NC}"
    echo ""
    echo -e "  ${Y}下一步:${NC} 到 ${C}分流规则${NC} 中添加规则"
    echo -e "  出口选择: ${C}负载均衡:${group_name}${NC}"
}

# 创建负载均衡组

create_load_balance_group() {
    _header
    echo -e "  ${W}创建负载均衡组${NC}"
    _line

    # 获取所有节点
    local nodes=$(db_get_chain_nodes)
    local node_count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)

    if [[ "$node_count" -eq 0 ]]; then
        echo -e "  ${R}✗${NC} 没有可用节点"
        echo -e "  ${Y}提示:${NC} 请先导入订阅或添加节点"
        _pause
        return
    fi

    echo -e "  ${G}找到 $node_count 个节点${NC}"
    echo ""
    echo -e "  ${Y}负载均衡策略:${NC}"
    echo -e "  ${G}1.${NC} leastPing   ${D}(最低延迟 - 推荐)${NC}"
    echo -e "  ${G}2.${NC} selector    ${D}(固定首节点)${NC}"
    echo -e "  ${G}0.${NC} 返回"
    _line

    read -rp "  请选择策略: " strategy_choice

    local strategy=""
    local strategy_name=""
    case "$strategy_choice" in
        1)
            strategy="leastPing"
            strategy_name="最低延迟"
            ;;
        2)
            strategy="selector"
            strategy_name="固定首节点"
            ;;
        3)
            strategy="selector"
            strategy_name="固定首节点"
            ;;
        0)
            return
            ;;
        *)
            _err "无效选择"
            _pause
            return
            ;;
    esac

    echo ""
    echo -e "  ${Y}选择节点:${NC}"
    echo -e "  ${G}1.${NC} 使用所有节点 (推荐)"
    echo -e "  ${G}2.${NC} 手动选择节点"
    echo -e "  ${G}0.${NC} 返回"
    _line

    read -rp "  请选择: " node_choice

    local selected_nodes="[]"
    case "$node_choice" in
        1)
            # 使用所有节点
            selected_nodes=$(echo "$nodes" | jq '[.[].name]')
            ;;
        2)
            # 手动选择节点
            echo ""
            echo -e "  ${Y}可用节点列表:${NC}"
            local i=1
            echo "$nodes" | jq -r '.[] | .name' | while read -r name; do
                echo -e "  ${D}[$i]${NC} $name"
                ((i++))
            done

            echo ""
            echo -e "  ${Y}输入节点编号 (多个用空格分隔，如: 1 3 5):${NC}"
            read -rp "  > " indices

            if [[ -z "$indices" ]]; then
                _err "未选择节点"
                _pause
                return
            fi

            # 解析选择的节点
            selected_nodes="[]"
            for idx in $indices; do
                if [[ "$idx" =~ ^[0-9]+$ ]]; then
                    local node_name=$(echo "$nodes" | jq -r ".[$((idx-1))].name // empty")
                    if [[ -n "$node_name" ]]; then
                        selected_nodes=$(echo "$selected_nodes" | jq --arg n "$node_name" '. + [$n]')
                    fi
                fi
            done
            ;;
        0)
            return
            ;;
        *)
            _err "无效选择"
            _pause
            return
            ;;
    esac

    local selected_count=$(echo "$selected_nodes" | jq 'length')
    if [[ "$selected_count" -eq 0 ]]; then
        _err "未选择有效节点"
        _pause
        return
    fi

    echo ""
    echo -e "  ${G}✓${NC} 已选择 ${G}$selected_count${NC} 个节点"
    echo ""

    # 输入组名
    read -rp "  输入负载均衡组名称 (默认: ${strategy_name}组): " group_name
    [[ -z "$group_name" ]] && group_name="${strategy_name}组"

    # 创建负载均衡组配置
    local lb_config=$(jq -n \
        --arg name "$group_name" \
        --arg strategy "$strategy" \
        --argjson nodes "$selected_nodes" \
        '{
            name: $name,
            strategy: $strategy,
            nodes: $nodes,
            url: "http://www.gstatic.com/generate_204",
            interval: 300,
            tolerance: 50
        }')

    # 保存到数据库
    if _db_apply --argjson cfg "$lb_config" \
        '.balancer_groups = ((.balancer_groups // []) + [$cfg])'; then
        echo ""
        echo -e "  ${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${G}✓ 负载均衡组创建成功!${NC}"
        echo -e "  ${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  组名: ${C}$group_name${NC}"
        echo -e "  策略: ${C}$strategy_name${NC}"
        echo -e "  节点数: ${C}$selected_count${NC}"
        echo -e "  ${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${Y}下一步:${NC}"
        echo -e "  1. 在 ${G}配置分流规则${NC} 中使用该负载均衡组"
        echo -e "  2. 负载均衡组会自动管理节点切换"
    else
        _err "创建失败"
    fi

    _pause
}

manage_chain_proxy() {
    while true; do
        _header
        echo -e "  ${W}链式代理管理${NC}"
        _line

        # 显示当前状态
        local nodes=$(db_get_chain_nodes)
        local node_count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)

        # 获取分流规则使用的节点
        local routing_rules=$(db_get_routing_rules)
        local routing_count=0
        local routing_nodes=""
        if [[ -n "$routing_rules" && "$routing_rules" != "[]" ]]; then
            while IFS= read -r line; do
                local r_type=$(echo "$line" | cut -d'|' -f1)
                local r_outbound=$(echo "$line" | cut -d'|' -f2)
                if [[ "$r_outbound" == chain:* ]]; then
                    local node_name="${r_outbound#chain:}"
                    routing_nodes+="    ${C}•${NC} ${node_name} ${D}← ${r_type}${NC}\n"
                    ((routing_count++))
                fi
            done < <(echo "$routing_rules" | jq -r '.[] | "\(.type)|\(.outbound)"')
        fi

        if [[ $routing_count -gt 0 ]]; then
            echo -e "  状态: ${G}● 分流已配置${NC} (${routing_count} 条规则)"
            echo -e "  使用节点:"
            echo -e "$routing_nodes"
        else
            echo -e "  状态: ${D}○ 未配置分流${NC}"
        fi
        echo -e "  节点总数: ${C}$node_count${NC}"
        _line

        _item "1" "添加节点 (分享链接)"
        _item "2" "导入订阅"
        _item "3" "一键导入 Alice SOCKS5 (8节点)"
        _item "4" "一键导入 Akile SOCKS5 (12节点)"
        echo -e "  ${D}───────────────────────────────────────────${NC}"
        _item "5" "多IP入出站配置"
        _item "6" "WARP 双层链式"
        _item "7" "创建负载均衡组"
        _item "8" "查看负载均衡组"
        echo -e "  ${D}───────────────────────────────────────────${NC}"
        _item "9" "测试所有节点延迟"
        _item "10" "删除节点"
        _item "11" "删除负载均衡组"
        _item "0" "返回"
        _line

        read -rp "  请选择: " choice

        case "$choice" in
            1)
                _add_chain_node_interactive
                ;;
            2)
                _import_subscription_interactive
                ;;
            3)
                _import_alice_nodes
                ;;
            4)
                _import_akile_nodes
                ;;
            5)
                manage_ip_routing
                ;;
            6)
                setup_warp_ipv6_chain
                ;;
            7)
                create_load_balance_group
                ;;
            8)
                # 查看负载均衡组
                _header
                echo -e "  ${W}查看负载均衡组${NC}"
                _line

                local balancer_groups=$(db_get_balancer_groups)
                local group_count=$(echo "$balancer_groups" | jq 'length' 2>/dev/null || echo 0)

                if [[ "$group_count" -eq 0 ]]; then
                    echo -e "  ${D}暂无负载均衡组${NC}"
                    _pause
                    continue
                fi

                echo "$balancer_groups" | jq -c '.[]' | while read -r group; do
                    local name=$(echo "$group" | jq -r '.name')
                    local strategy=$(echo "$group" | jq -r '.strategy')
                    local nodes=$(echo "$group" | jq -r '.nodes')
                    local node_count=$(echo "$nodes" | jq 'length')

                    local strategy_name=""
                    case "$strategy" in
                        leastPing) strategy_name="最低延迟" ;;
                        selector|random) strategy_name="手动选择" ;;
                        roundRobin) strategy_name="手动选择" ;;
                        *) strategy_name="$strategy" ;;
                    esac

                    echo -e "  ${G}━━━ $name ━━━${NC}"
                    echo -e "  策略: ${C}$strategy_name${NC}  节点数: ${C}$node_count${NC}"
                    echo -e "  包含节点:"
                    echo "$nodes" | jq -r '.[]' | while read -r node_name; do
                        echo -e "    ${D}•${NC} $node_name"
                    done
                    echo ""
                done
                _line
                _pause
                ;;
            9)
                # 测试所有节点延迟
                _header
                echo -e "  ${W}测试节点延迟 ${D}(仅供参考)${NC}"
                _line

                local nodes=$(db_get_chain_nodes)
                local count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)

                if [[ "$count" -eq 0 ]]; then
                    echo -e "  ${D}暂无节点${NC}"
                    _pause
                    continue
                fi

                # 获取分流规则使用的节点
                local routing_rules=$(db_get_routing_rules)
                declare -A routing_marks
                if [[ -n "$routing_rules" && "$routing_rules" != "[]" ]]; then
                    while IFS= read -r line; do
                        local r_type=$(echo "$line" | cut -d'|' -f1)
                        local r_outbound=$(echo "$line" | cut -d'|' -f2)
                        if [[ "$r_outbound" == chain:* ]]; then
                            local node_name="${r_outbound#chain:}"
                            routing_marks["$node_name"]="$r_type"
                        fi
                    done < <(echo "$routing_rules" | jq -r '.[] | "\(.type)|\(.outbound)"')
                fi

                echo -e "  ${C}▸${NC} 检测 $count 个节点延迟中... (并发 ${LATENCY_PARALLEL})"

                local tmp_results=$(mktemp)
                local tmp_nodes=$(mktemp)
                echo "$nodes" | jq -c '.[]' > "$tmp_nodes"
                _batch_latency_nodes "$tmp_results" "$LATENCY_PARALLEL" < "$tmp_nodes"

                _ok "延迟检测完成 ($count 个节点)"
                echo ""
                echo -e "  ${W}延迟排序 (从低到高):${NC}"
                _line

                _display_sorted_latencies "$tmp_results" "routing_marks"

                rm -f "$tmp_results" "$tmp_nodes"
                _line
                _pause
                ;;
            10)
                _header
                echo -e "  ${W}删除节点${NC}"
                _line

                local nodes=$(db_get_chain_nodes)
                local count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)

                if [[ "$count" -eq 0 ]]; then
                    echo -e "  ${D}暂无节点${NC}"
                    _pause
                    continue
                fi

                local i=1
                echo "$nodes" | jq -r '.[] | .name' | while read -r name; do
                    echo -e "  ${C}$i)${NC} $name"
                    ((i++))
                done

                _line
                echo -e "  ${D}输入 all 删除全部, 0 返回${NC}"
                read -rp "  选择编号: " idx

                if [[ "$idx" == "0" ]]; then
                    continue
                elif [[ "$idx" == "all" ]]; then
                    _db_apply '
                        del(.chain_proxy)
                        | .routing_rules = [.routing_rules[]? | select(.outbound | startswith("chain:") | not)]
                    '
                    _ok "已删除所有节点"
                    _ok "已清理相关分流规则"
                    _regenerate_proxy_configs
                elif [[ -n "$idx" && "$idx" =~ ^[0-9]+$ ]]; then
                    local name=$(echo "$nodes" | jq -r ".[$((idx-1))].name // empty")
                    if [[ -n "$name" ]]; then
                        db_del_chain_node "$name"
                        # 清理引用该节点的分流规则
                        _db_apply --arg out "chain:$name" '.routing_rules = [.routing_rules[]? | select(.outbound != $out)]'
                        _ok "已删除: $name"
                        _regenerate_proxy_configs
                    fi
                fi
                _pause
                ;;
            11)
                # 删除负载均衡组
                _header
                echo -e "  ${W}删除负载均衡组${NC}"
                _line

                local balancer_groups=$(db_get_balancer_groups)
                local group_count=$(echo "$balancer_groups" | jq 'length' 2>/dev/null || echo 0)

                if [[ "$group_count" -eq 0 ]]; then
                    echo -e "  ${D}暂无负载均衡组${NC}"
                    _pause
                    continue
                fi

                local idx=1
                echo "$balancer_groups" | jq -c '.[]' | while read -r group; do
                    local name=$(echo "$group" | jq -r '.name')
                    local strategy=$(echo "$group" | jq -r '.strategy')
                    local nodes=$(echo "$group" | jq -r '.nodes | length')

                    local strategy_name=""
                    case "$strategy" in
                        leastPing) strategy_name="最低延迟" ;;
                        selector|random) strategy_name="手动选择" ;;
                        roundRobin) strategy_name="手动选择" ;;
                        *) strategy_name="$strategy" ;;
                    esac

                    echo -e "  ${C}$idx)${NC} ${G}$name${NC} ${D}($strategy_name, $nodes 节点)${NC}"
                    ((idx++))
                done

                _line
                echo -e "  ${D}输入 all 删除全部, 0 返回${NC}"
                read -rp "  选择编号: " del_idx

                if [[ "$del_idx" == "0" ]]; then
                    continue
                elif [[ "$del_idx" == "all" ]]; then
                    _db_apply 'del(.balancer_groups)'
                    _ok "已删除所有负载均衡组"
                    _regenerate_proxy_configs
                elif [[ -n "$del_idx" && "$del_idx" =~ ^[0-9]+$ ]]; then
                    local group_name=$(echo "$balancer_groups" | jq -r ".[$((del_idx-1))].name // empty")
                    if [[ -n "$group_name" ]]; then
                        _db_apply --arg name "$group_name" '.balancer_groups = [.balancer_groups[]? | select(.name != $name)]'
                        _ok "已删除: $group_name"
                        _regenerate_proxy_configs
                    else
                        _err "无效的编号"
                    fi
                fi
                _pause
                ;;
            0) return ;;
        esac
    done
}


# 多IP入出站配置管理菜单
manage_ip_routing() {
    _warn "多 IP 入出站暂未支持 Sing-box，配置未更改"
    return 1
}

#═══════════════════════════════════════════════════════════════════════════════
# BBR 网络优化

#═══════════════════════════════════════════════════════════════════════════════

# 检查 BBR 状态
check_bbr_status() {
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    [[ "$cc" == "bbr" && "$qdisc" == "fq" ]]
}

# 一键开启 BBR 优化
enable_bbr() {
    _header
    echo -e "  ${W}BBR 网络优化${NC}"
    _line

    # 检查内核版本
    local kernel_ver=$(uname -r | cut -d'-' -f1)
    local kernel_major=$(echo "$kernel_ver" | cut -d'.' -f1)
    local kernel_minor=$(echo "$kernel_ver" | cut -d'.' -f2)

    if [[ $kernel_major -lt 4 ]] || [[ $kernel_major -eq 4 && $kernel_minor -lt 9 ]]; then
        _err "内核版本 $(uname -r) 不支持 BBR (需要 4.9+)"
        _pause
        return 1
    fi

    # 系统信息检测
    local mem_mb=$(free -m | awk '/^Mem:/{print $2}')
    local cpu_cores=$(nproc)
    local virt_type="unknown"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt_type=$(systemd-detect-virt 2>/dev/null || echo "none")
    elif grep -q -i "hypervisor" /proc/cpuinfo 2>/dev/null; then
        virt_type="KVM/VMware"
    fi

    echo -e "  ${C}系统信息${NC}"
    echo -e "  内核版本: ${G}$(uname -r)${NC} ✓"
    echo -e "  内存大小: ${G}${mem_mb}MB${NC}"
    echo -e "  CPU核心数: ${G}${cpu_cores}${NC}"
    echo -e "  虚拟化类型: ${G}${virt_type}${NC}"
    _line

    # 检查当前状态
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    echo -e "  ${C}当前状态${NC}"
    echo -e "  拥塞控制: ${Y}$current_cc${NC}"
    echo -e "  队列调度: ${Y}$current_qdisc${NC}"

    # 显示当前 BBR 配置详情（如果已配置）
    local conf_file="/etc/sysctl.d/99-bbr-proxy.conf"
    if [[ -f "$conf_file" ]]; then
        echo ""
        echo -e "  ${C}已配置参数${NC}"
        local rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
        local wmem=$(sysctl -n net.core.wmem_max 2>/dev/null)
        local somaxconn=$(sysctl -n net.core.somaxconn 2>/dev/null)
        local file_max=$(sysctl -n fs.file-max 2>/dev/null)
        echo -e "  读缓冲区: ${G}$((rmem/1024/1024))MB${NC}"
        echo -e "  写缓冲区: ${G}$((wmem/1024/1024))MB${NC}"
        echo -e "  最大连接队列: ${G}$somaxconn${NC}"
        echo -e "  最大文件句柄: ${G}$file_max${NC}"
    fi

    _line

    if check_bbr_status; then
        _ok "BBR 已启用"
        echo ""
        _item "1" "重新优化 (更新参数)"
        _item "2" "卸载 BBR 优化"
        _item "0" "返回"
        _line
        read -rp "  请选择: " choice
        case "$choice" in
            1) ;;  # 继续执行优化
            2)
                _info "卸载 BBR 优化配置..."
                rm -f "$conf_file"
                sysctl --system >/dev/null 2>&1
                _ok "BBR 优化配置已移除，系统恢复默认设置"
                _pause
                return 0
                ;;
            *) return 0 ;;
        esac
    else
        read -rp "  确认开启 BBR 优化? [Y/n]: " confirm
        [[ "$confirm" =~ ^[nN]$ ]] && return
    fi

    _info "加载 BBR 模块..."
    modprobe tcp_bbr 2>/dev/null || true

    # 检查 BBR 是否可用
    if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
        _err "BBR 模块不可用，请检查内核配置"
        _pause
        return 1
    fi

    # 根据内存动态计算参数 (6档位)
    local vm_tier rmem_max wmem_max tcp_rmem tcp_wmem somaxconn netdev_backlog file_max conntrack_max
    if [[ $mem_mb -le 512 ]]; then
        vm_tier="经典级(≤512MB)"
        rmem_max=8388608; wmem_max=8388608
        tcp_rmem="4096 65536 8388608"; tcp_wmem="4096 65536 8388608"
        somaxconn=32768; netdev_backlog=16384; file_max=262144; conntrack_max=131072
    elif [[ $mem_mb -le 1024 ]]; then
        vm_tier="轻量级(512MB-1GB)"
        rmem_max=16777216; wmem_max=16777216
        tcp_rmem="4096 65536 16777216"; tcp_wmem="4096 65536 16777216"
        somaxconn=49152; netdev_backlog=24576; file_max=524288; conntrack_max=262144
    elif [[ $mem_mb -le 2048 ]]; then
        vm_tier="标准级(1GB-2GB)"
        rmem_max=33554432; wmem_max=33554432
        tcp_rmem="4096 87380 33554432"; tcp_wmem="4096 65536 33554432"
        somaxconn=65535; netdev_backlog=32768; file_max=1048576; conntrack_max=524288
    elif [[ $mem_mb -le 4096 ]]; then
        vm_tier="高性能级(2GB-4GB)"
        rmem_max=67108864; wmem_max=67108864
        tcp_rmem="4096 131072 67108864"; tcp_wmem="4096 87380 67108864"
        somaxconn=65535; netdev_backlog=65535; file_max=2097152; conntrack_max=1048576
    elif [[ $mem_mb -le 8192 ]]; then
        vm_tier="企业级(4GB-8GB)"
        rmem_max=134217728; wmem_max=134217728
        tcp_rmem="8192 131072 134217728"; tcp_wmem="8192 87380 134217728"
        somaxconn=65535; netdev_backlog=65535; file_max=4194304; conntrack_max=2097152
    else
        vm_tier="旗舰级(>8GB)"
        rmem_max=134217728; wmem_max=134217728
        tcp_rmem="8192 131072 134217728"; tcp_wmem="8192 87380 134217728"
        somaxconn=65535; netdev_backlog=65535; file_max=8388608; conntrack_max=2097152
    fi

    echo ""
    _info "应用 ${vm_tier} 优化配置..."

    cat > "$conf_file" << EOF
# ══════════════════════════════════════════════════════════════
# TCP/IP & BBR 优化配置 (由 vless 脚本自动生成)
# 生成时间: $(date)
# 针对硬件: ${mem_mb}MB 内存, ${cpu_cores}核CPU (${vm_tier})
# ══════════════════════════════════════════════════════════════

# BBR 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Socket 缓冲区
net.core.rmem_max = $rmem_max
net.core.wmem_max = $wmem_max
net.ipv4.tcp_rmem = $tcp_rmem
net.ipv4.tcp_wmem = $tcp_wmem

# 连接队列
net.core.somaxconn = $somaxconn
net.core.netdev_max_backlog = $netdev_backlog
net.ipv4.tcp_max_syn_backlog = $somaxconn

# TCP 优化
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 0
net.ipv4.tcp_max_tw_buckets = 180000
net.ipv4.tcp_slow_start_after_idle = 0

# 文件句柄
fs.file-max = $file_max

# 内存优化
vm.swappiness = 10
EOF

    # 如果支持 tcp_fastopen，添加配置
    if [[ -f /proc/sys/net/ipv4/tcp_fastopen ]]; then
        echo "" >> "$conf_file"
        echo "# TCP Fast Open" >> "$conf_file"
        echo "net.ipv4.tcp_fastopen = 3" >> "$conf_file"
    fi

    # 如果有 conntrack 模块，添加连接跟踪配置
    if [[ -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        echo "" >> "$conf_file"
        echo "# 连接跟踪" >> "$conf_file"
        echo "net.netfilter.nf_conntrack_max = $conntrack_max" >> "$conf_file"
    fi

    _info "应用配置..."
    # 使用 -p 逐个应用配置文件，忽略不支持的参数
    local sysctl_output
    sysctl_output=$(sysctl -p "$conf_file" 2>&1) || true

    # 检查是否有严重错误（排除 "unknown key" 警告）
    if echo "$sysctl_output" | grep -q "Invalid argument\|Permission denied"; then
        _err "配置应用失败"
        echo -e "  ${D}$sysctl_output${NC}"
        _pause
        return 1
    fi

    # 显示警告信息（如果有）
    if echo "$sysctl_output" | grep -q "unknown key"; then
        echo -e "  ${Y}部分参数不支持（已忽略）${NC}"
    fi

    _ok "配置已生效"

    # 验证结果
    _line
    local new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local new_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    echo -e "  ${C}优化结果${NC}"
    echo -e "  配置档位: ${G}$vm_tier${NC}"
    echo -e "  拥塞控制: ${G}$new_cc${NC}"
    echo -e "  队列调度: ${G}$new_qdisc${NC}"
    echo -e "  读缓冲区: ${G}$((rmem_max/1024/1024))MB${NC}"
    echo -e "  写缓冲区: ${G}$((wmem_max/1024/1024))MB${NC}"
    echo -e "  最大连接队列: ${G}$somaxconn${NC}"
    echo -e "  最大文件句柄: ${G}$file_max${NC}"
    _line

    if [[ "$new_cc" == "bbr" && "$new_qdisc" == "fq" ]]; then
        _ok "BBR 优化已成功启用!"
    else
        _warn "BBR 可能未完全生效，请检查系统日志"
    fi

    _pause
}

#═══════════════════════════════════════════════════════════════════════════════
# 多协议管理菜单
#═══════════════════════════════════════════════════════════════════════════════

# 显示所有已安装协议的信息（带选择查看详情功能）
show_all_protocols_info() {
    local protocol core ports choice idx
    local -a protocols
    while true; do
        _header
        protocols=(); idx=1
        while IFS= read -r protocol; do
            [[ -n "$protocol" ]] || continue
            core=$(protocol_db_core "$protocol")
            ports=$(db_list_ports "$core" "$protocol" | paste -sd ',' -)
            _item "$idx" "$(get_protocol_name "$protocol") - ${ports}"
            protocols+=("$protocol"); idx=$((idx+1))
        done < <(db_get_all_protocols)
        _item a "一键展示所有分享链接"
        _item 0 "返回"
        read -rp "  请选择: " choice || return
        case "$choice" in
            0) return ;;
            a|A) show_all_share_links; _pause ;;
            *) if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && ((choice <= ${#protocols[@]})); then
                   show_single_protocol_info "${protocols[choice-1]}"
               else _err "无效选择"; fi ;;
        esac
    done
}

# 一键展示所有分享链接
show_all_share_links() {
    local protocol
    while IFS= read -r protocol; do
        [[ -n "$protocol" ]] || continue
        show_single_protocol_info "$protocol" false || return 1
    done < <(db_get_all_protocols)
}

# 显示单个协议的详细配置信息（包含链接和二维码）
# 参数: $1=协议名, $2=是否清屏(可选，默认true), $3=指定端口(可选)
show_single_protocol_info() {
    local protocol="$1" clear_screen="${2:-true}" selected_port="${3:-}" core records cfg port link links surge_lines
    core=$(protocol_db_core "$protocol") || return 1
    records=$(db_protocol_configs "$core" "$protocol") || return 1
    [[ "$clear_screen" != true ]] || _header
    printf '  %s\n' "$(get_protocol_name "$protocol")"
    while IFS= read -r cfg; do
        [[ -n "$cfg" ]] || continue
        port=$(jq -r .port <<< "$cfg")
        [[ -z "$selected_port" || "$selected_port" == "$port" ]] || continue
        printf '  端口: %s\n' "$port"
        links=$(
            get_installed_protocols() { printf '%s\n' "$protocol"; }
            get_all_external_links() { :; }
            db_protocol_configs() { printf '%s\n' "$cfg"; }
            gen_v2ray_sub | base64 -d
        ) || return 1
        while IFS= read -r link; do
            [[ -n "$link" ]] || continue
            printf '  分享链接:\n%s\n' "$link"
            [[ "$protocol" != snell-* ]] || printf '  Snell 为自定义 URI；Surge 请使用下方配置或订阅链接。\n'
            _show_link_qr "$link"
        done <<< "$links"
        surge_lines=$(
            get_installed_protocols() { printf '%s\n' "$protocol"; }
            get_all_external_links() { :; }
            db_protocol_configs() { printf '%s\n' "$cfg"; }
            gen_surge_sub | awk '/^\[Proxy\]$/ {printing=1; next} /^\[/ {printing=0} printing && NF'
        ) || return 1
        if [[ -n "$surge_lines" ]]; then
            printf '  Surge 节点配置（粘贴到 [Proxy]）：\n%s\n' "$surge_lines"
        fi
    done <<< "$records"
    [[ "$clear_screen" != true ]] || _pause
    return 0
}

# 管理协议服务
manage_protocol_services() {
    local choice
    local installed=$(get_installed_protocols)
    [[ -z "$installed" ]] && { _warn "未安装任何协议"; return; }

    while true; do
        _header
        echo -e "  ${W}协议服务管理${NC}"
        _line
        show_protocols_overview  # 使用简洁概览

        _item "1" "重启所有服务"
        _item "2" "停止所有服务"
        _item "3" "启动所有服务"
        _item "4" "查看服务状态"
        _item "5" "查看运行配置文件（Sing-box / 官方 Snell）"
        _item "0" "返回"
        _line

        read -rp "  请选择: " choice || return
        case $choice in
            1)
                _info "重启所有服务..."
                # start_services 会先生成/校验配置，再重启已运行的核心。
                start_services && _ok "所有服务已重启"
                _pause
                ;;
            2)
                _info "停止所有服务..."
                stop_services; touch "$CFG/paused"; _ok "所有服务已停止"
                _pause
                ;;
            3)
                _info "启动所有服务..."
                start_services && _ok "所有服务已启动"
                _pause
                ;;
            4) show_services_status; _pause ;;
            5) view_runtime_config_menu ;;
            0) return ;;
            *) _err "无效选择"; _pause ;;
        esac
    done
}

# 简洁的协议概览（用于服务管理页面）
show_protocols_overview() {
    local protocol core ports index=0 accent
    for protocol in $(get_installed_protocols); do
        core=$(protocol_db_core "$protocol") || continue
        ports=$(db_protocol_configs "$core" "$protocol" | jq -r '.port // empty' | paste -sd ',' -)
        index=$((index+1))
        accent='\e[1;96m'
        ((index % 2 != 0)) || accent='\e[1;95m'
        printf '  %b[%02d]%b  %b%s%b  %b│ 端口%b %b%s%b\n' \
            "$accent" "$index" "$NC" '\e[1;97m' "$(get_protocol_name "$protocol")" "$NC" \
            "$D" "$NC" '\e[1;93m' "${ports:-—}" "$NC"
    done
}

show_services_status() {
    local protocol service status seen=' '
    for protocol in $(get_installed_protocols); do
        service="${PROTO_SVC[$protocol]:-}"
        [[ -n "$service" && "$seen" != *" $service "* ]] || continue
        seen+="$service "
        status=已停止
        svc status "$service" >/dev/null 2>&1 && status=运行中
        printf '  • %s: %s\n' "$service" "$status"
    done
}
select_port_to_uninstall() {
    local protocol="$1"

    # 选择列表与后续事务使用同一个活动物理命名空间。
    local core
    core=$(protocol_active_db_core "$protocol")

    # 获取归一化端口列表，兼容旧单对象和多端口数组。
    local ports=$(db_protocol_configs "$core" "$protocol" | jq -r '.port // empty')

    if [[ -z "$ports" ]]; then
        echo -e "${RED}错误: 未找到协议 $protocol 的端口实例${NC}"
        return 1
    fi

    # 转换为数组
    local port_array=($ports)
    local port_count=${#port_array[@]}

    # 只有一个端口，直接选择
    if [[ $port_count -eq 1 ]]; then
        SELECTED_PORT="${port_array[0]}"
        SELECTED_PROTOCOL_CORE="$core"
        echo -e "${CYAN}检测到协议 $protocol 只有一个端口实例: $SELECTED_PORT${NC}"
        return 0
    fi

    # 多个端口，让用户选择
    echo ""
    echo -e "${CYAN}协议 ${YELLOW}$protocol${CYAN} 有以下端口实例：${NC}"
    echo ""

    local i=1
    for port in "${port_array[@]}"; do
        echo -e "  ${G}$i${NC}) 端口 ${G}$port${NC}"
        ((i++))
    done
    echo -e "  ${G}$i${NC}) 卸载所有端口"
    echo "  0) 返回"
    echo ""

    local choice
    read -p "$(echo -e "  ${GREEN}请选择要卸载的端口 [0-$i]:${NC} ")" choice

    if [[ "$choice" == "0" ]]; then
        echo -e "${YELLOW}已取消，返回上级菜单${NC}"
        return 1
    elif [[ "$choice" == "$i" ]]; then
        SELECTED_PORT="all"
        SELECTED_PROTOCOL_CORE="$core"
        return 0
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$i" ]; then
        SELECTED_PORT="${port_array[$((choice-1))]}"
        SELECTED_PROTOCOL_CORE="$core"
        return 0
    else
        echo -e "${RED}无效选项${NC}"
        return 1
    fi
}

# 卸载指定协议
uninstall_specific_protocol() {
    local installed protocol choice core kind service selected
    local -a protocols=()
    installed=$(get_installed_protocols)
    [[ -n "$installed" ]] || { _warn '未安装任何协议'; return; }
    while IFS= read -r protocol; do protocols+=("$protocol"); _item "${#protocols[@]}" "$(get_protocol_name "$protocol")"; done <<<"$installed"
    _item 0 返回
    read -rp '  选择要卸载的协议: ' choice || return
    [[ "$choice" != 0 ]] || return
    [[ "$choice" =~ ^[1-9][0-9]*$ ]] && ((choice <= ${#protocols[@]})) || return 1
    selected="${protocols[choice-1]}"
    core=$(protocol_db_core "$selected") || return 1
    kind=$(protocol_core "$selected") || return 1
    service="${PROTO_SVC[$selected]}"
    if [[ "$kind" == standalone ]]; then
        SELECTED_PORT=all
    else
        select_port_to_uninstall "$selected" || return 1
    fi
    read -rp '  确认卸载? [y/N]: ' choice || return
    [[ "$choice" =~ ^[yY]$ ]] || return
    if is_singbox_snell_protocol "$selected"; then
        _apply_singbox_snell_change remove "$SELECTED_PORT" '{}' "$selected" || return 1
    elif [[ "$kind" == singbox ]]; then
        _apply_singbox_vless_config '{}' remove "$SELECTED_PORT" "$selected" || return 1
    else
        svc stop "$service" || return 1
        svc disable "$service" || return 1
        db_del snell "$selected" || return 1
        rm -f "$CFG/$selected.conf" "$OPENRC_DIR/$service" "$SYSTEMD_DIR/$service.service"
        [[ "$DISTRO" == alpine ]] || systemctl daemon-reload
    fi
    if ! is_protocol_installed "$selected"; then
        rm -f "$CFG/$selected.join"
        case "$selected" in
            hy2|tuic) cleanup_hy2_nat_rules; rm -f "$CFG/$selected-nat.sh" ;;
        esac
    fi
    if [[ -f "$CFG/sub.info" || -d "$CFG/subscription" ]]; then generate_sub_files || return 1; fi
    _ok "$selected 已卸载"
    _pause
}
show_server_info() {
    [[ "$(get_role)" != "server" ]] && return

    # 多协议模式：显示所有协议的配置
    local installed=$(get_installed_protocols)
    local protocol_count=$(echo "$installed" | wc -w)

    if [[ $protocol_count -eq 1 ]]; then
        # 单协议：直接显示详细信息
        show_single_protocol_info "$installed"
    else
        # 多协议：显示协议列表供选择
        show_all_protocols_info
    fi
}

do_uninstall() {
    local confirm service dir name file
    check_installed || { _warn '未安装'; return; }
    read -rp '  确认卸载? [y/N]: ' confirm || return
    [[ "$confirm" =~ ^[yY]$ ]] || return
    # 辅助服务与代理核心同属 lite，必须先停止再删除其配置。
    for service in sing-cloudflared sing-realm; do
        if svc status "$service" >/dev/null 2>&1; then
            svc stop "$service" || { _err "$service 停止失败，未删除配置"; return 1; }
        fi
    done
    stop_services || { _err '服务停止失败，未删除配置'; return 1; }
    # 服务清单固定且仅包含本项目拥有的资源。
    for service in $(owned_services) sing-cloudflared sing-realm; do
        svc disable "$service" 2>/dev/null || true
        rm -f "$OPENRC_DIR/$service" "$SYSTEMD_DIR/$service.service" "/run/$service.pid"
    done
    [[ "$DISTRO" == alpine ]] || systemctl daemon-reload
    for dir in /etc/nginx/conf.d /etc/nginx/http.d /etc/nginx/sites-enabled /etc/nginx/sites-available; do
        for name in sing-sub sing-fake sing-reality-https; do
            rm -f "$dir/$name.conf" "$dir/$name"
        done
    done
    if check_cmd nginx && nginx -t >/dev/null 2>&1; then svc reload nginx >/dev/null 2>&1 || true; fi
    # 配置根目录为独立命名空间，保留已申请证书。
    for file in "$CFG"/* "$CFG"/.[!.]* "$CFG"/..?*; do
        [[ -e "$file" || -L "$file" ]] || continue
        case "${file##*/}" in certs|cert_domain|bin|nftables|tools) continue ;; esac
        rm -rf -- "$file"
    done
    remove_shortcut
    uninstall_expire_check_cron
    remove_tg_user_bot_cron
    realm_cleanup_runtime
    _ok "代理卸载完成；已保留核心、证书和独立 nftables 转发配置"
}
select_vless_mode() {
    VLESS_SECURITY_MODE=reality
    SELECTED_PROTOCOL=vless-singbox
}

# 两个 REALITY 实现使用独立协议键，在检查已有端口前完成选择。
select_vless_reality_implementation() {
    SELECTED_PROTOCOL=vless-singbox
}

# 协议选择菜单
select_protocol() {
    local choice
    _line
    _item 1 "VLESS REALITY (Sing-box)"
    _item 2 "Shadowsocks 2022 / 传统版"
    _item 3 "SOCKS5 明文"
    _item 4 "Hysteria2"
    _item 5 "TUIC v5"
    _item 6 "AnyTLS"
    _item 7 "Naive (Sing-box)"
    _item 8 "SS2022 + ShadowTLS v3"
    _item 9 "Snell v5"
    _item 10 "Snell v6"
    _item 0 "返回"
    while true; do
        read -rp "  选择协议 [0-10]: " choice || return 1
        case "$choice" in
            0) SELECTED_PROTOCOL=""; return 1 ;;
            1) select_vless_mode; return ;;
            2) select_ss_version; return $? ;;
            3) SELECTED_PROTOCOL=socks ;;
            4) SELECTED_PROTOCOL=hy2 ;;
            5) SELECTED_PROTOCOL=tuic ;;
            6) SELECTED_PROTOCOL=anytls ;;
            7) SELECTED_PROTOCOL=naive ;;
            8) SELECTED_PROTOCOL=ss2022-shadowtls ;;
            9) select_snell_v5_implementation; return $? ;;
            10) select_snell_v6_implementation; return $? ;;
            *) _err "无效选择"; continue ;;
        esac
        return 0
    done
}

# Snell v6 的实现选择先于已有实例检查，两种实现使用不同协议键。
select_snell_v6_implementation() {
    local choice
    _item 1 "Sing-box Snell v6 (统一分流)"
    _item 2 "Surge 官方 Snell v6 (独立服务)"
    _item 0 "返回"
    while true; do
        read -rp "  请选择 [1]: " choice || return 1
        case "${choice:-1}" in
            1) SELECTED_PROTOCOL=snell-v6-singbox; return 0 ;;
            2) SELECTED_PROTOCOL=snell-v6; return 0 ;;
            0) SELECTED_PROTOCOL=""; return 1 ;;
            *) _err "无效选择" ;;
        esac
    done
}

select_snell_v5_implementation() {
    local choice
    _item 1 "Sing-box Snell v5 (统一分流)"
    _item 2 "Surge 官方 Snell v5 (独立服务)"
    _item 0 "返回"
    while true; do
        read -rp "  请选择 [1]: " choice || return 1
        case "${choice:-1}" in
            1) SELECTED_PROTOCOL=snell-v5; return 0 ;;
            2) SELECTED_PROTOCOL=snell-v5-official; return 0 ;;
            0) return 1 ;;
            *) _err "无效选择" ;;
        esac
    done
}

# Shadowsocks 版本选择子菜单
select_ss_version() {
    echo ""
    _line
    echo -e "  ${W}选择 Shadowsocks 版本${NC}"
    _line
    _item "1" "SS2022 ${D}(新版加密, 需时间同步)${NC}"
    _item "2" "SS 传统版 ${D}(兼容性好, 无时间校验)${NC}"
    _item "0" "返回"
    echo ""

    while true; do
        read -rp "  选择版本 [0-2]: " ss_choice
        case $ss_choice in
            1) SELECTED_PROTOCOL="ss2022"; return 0 ;;
            2) SELECTED_PROTOCOL="ss-legacy"; return 0 ;;
            0) SELECTED_PROTOCOL=""; return 1 ;;
            *) _err "无效选择" ;;
        esac
    done
}

do_install_server() {
    _header
    select_protocol || return 1
    local protocol="$SELECTED_PROTOCOL" core port record password username uuid keys sid sni method psk
    core=$(protocol_core "$protocol")
    unset INSTALL_MODE REPLACE_PORT
    check_dependencies && install_deps || return 1
    ensure_dual_stack_listen
    mkdir -p "$CFG" || return 1
    if [[ "$core" == singbox ]]; then
        install_singbox || return 1
        [[ "$protocol" != snell-v6-singbox ]] || ensure_singbox_snell_support || return 1
        handle_existing_protocol "$protocol" singbox || return 1
    else
        case "$protocol" in
            snell-v5-official) install_snell_v5 || return 1 ;;
            snell-v6) install_snell_v6 || return 1 ;;
            *) _err "不支持的独立协议"; return 1 ;;
        esac
    fi
    port=$(ask_port "$protocol") || return 1
    [[ -n "$port" ]] || return 1
    case "$protocol" in
        vless-singbox)
            uuid=$(gen_uuid); sid=$(gen_sid)
            keys=$(gen_singbox_reality_keys) || return 1
            sni=$(ask_sni_config "$(gen_sni)") || return 1
            gen_vless_singbox_server_config "$uuid" "$port" "$(jq -r '.private_key' <<<"$keys")" "$(jq -r '.public_key' <<<"$keys")" "$sid" "$sni" || return 1
            ;;
        ss2022|ss2022-shadowtls)
            sync_time
            method=2022-blake3-aes-128-gcm
            _item 1 "2022-blake3-aes-128-gcm"
            _item 2 "2022-blake3-aes-256-gcm"
            local cipher_choice
            read -rp "  加密方式 [1]: " cipher_choice || return 1
            [[ "${cipher_choice:-1}" != 2 ]] || method=2022-blake3-aes-256-gcm
            local key_bytes=16
            [[ "$method" != *256* ]] || key_bytes=32
            password=$(openssl rand -base64 "$key_bytes") || return 1
            if [[ "$protocol" == ss2022-shadowtls ]]; then
                sni=$(ask_sni_config www.microsoft.com) || return 1
                local stls_password
                stls_password=$(ask_password 16 "ShadowTLS 密码") || return 1
                gen_ss2022_shadowtls_server_config "$password" "$port" "$method" "$sni" "$stls_password" || return 1
            else
                gen_ss2022_server_config "$password" "$port" "$method" || return 1
            fi
            ;;
        ss-legacy)
            method=aes-256-gcm
            read -rp "  加密方式 [aes-256-gcm]: " method || return 1
            method="${method:-aes-256-gcm}"
            case "$method" in aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305) ;; *) _err "不支持的加密方式"; return 1 ;; esac
            password=$(ask_password 24 "Shadowsocks 密码") || return 1
            gen_ss_legacy_server_config "$password" "$port" "$method" || return 1
            ;;
        socks)
            username=$(ask_password 8 "SOCKS5 用户名") || return 1
            password=$(ask_password 16 "SOCKS5 密码") || return 1
            gen_socks_server_config "$username" "$password" "$port" false || return 1
            ;;
        hy2|tuic)
            password=$(ask_password 16 "协议密码") || return 1
            sni=$(ask_sni_config www.bing.com) || return 1
            if [[ "$protocol" == hy2 ]]; then
                gen_hy2_server_config "$password" "$port" "$sni" || return 1
            else
                uuid=$(gen_uuid)
                gen_tuic_server_config "$uuid" "$password" "$port" "$sni" || return 1
            fi
            ;;
        anytls|naive)
            configure_anytls_certificate || return 1
            sni="$ANYTLS_CERT_SNI"
            password=$(ask_password 16 "协议密码") || return 1
            if [[ "$protocol" == anytls ]]; then
                gen_anytls_server_config "$password" "$port" "$sni" "$ANYTLS_CERT_MODE" || return 1
            else
                [[ "$ANYTLS_CERT_MODE" != self ]] || { _err "Naive 需要可信域名证书"; return 1; }
                username=$(ask_password 8 "Naive 用户名") || return 1
                gen_naive_server_config "$username" "$password" "$port" "$sni" || return 1
            fi
            ;;
        snell-v5|snell-v5-official|snell-v6|snell-v6-singbox)
            psk=$(ask_password 24 "Snell PSK") || return 1
            if [[ "$protocol" == snell-v6-singbox ]]; then
                while [[ ${#psk} -lt 12 || ${#psk} -gt 255 ]]; do
                    _err "Snell v6 PSK 长度应为 12–255"
                    psk=$(ask_password 24 "Snell PSK") || return 1
                done
            fi
            case "$protocol" in
                snell-v5) gen_snell_v5_server_config "$psk" "$port" || return 1 ;;
                snell-v5-official) gen_snell_v5_official_server_config "$psk" "$port" || return 1 ;;
                snell-v6-singbox)
                    local singbox_mode
                    while true; do
                        read -rp "  混淆模式 [default/unshaped/unsafe-raw，默认 default]: " singbox_mode || return 1
                        singbox_mode="${singbox_mode:-default}"
                        case "$singbox_mode" in
                            default|unshaped|unsafe-raw) break ;;
                            *) _err "无效的 Snell v6 混淆模式: $singbox_mode" ;;
                        esac
                    done
                    gen_singbox_snell_v6_server_config "$psk" "$port" 6 "$singbox_mode" || return 1
                    ;;
                snell-v6)
                    local mode dns_pref dns_servers
                    read -rp "  混淆模式 [default/unshaped/unsafe-raw，默认 default]: " mode || return 1
                    read -rp "  DNS 偏好 [default/prefer-ipv4/prefer-ipv6/ipv4-only/ipv6-only]: " dns_pref || return 1
                    read -rp "  DNS 服务器 (留空使用系统): " dns_servers || return 1
                    gen_snell_v6_server_config "$psk" "$port" 6 "${dns_pref:-default}" "$dns_servers" "${mode:-default}" true || return 1
                    ;;
            esac
            ;;
        *) return 1 ;;
    esac
    create_server_scripts || return 1
    create_watchdog_service && svc enable sing-watchdog && svc start sing-watchdog || return 1
    create_shortcut || return 1
    [[ ! -f "$CFG/sub.info" ]] || generate_sub_files || return 1
    _ok "安装完成，快捷命令: sing"
    [[ "$protocol" != hy2 && "$protocol" != tuic ]] || _warn "请放行 UDP 端口 $port"
    show_single_protocol_info "$protocol" false "$port"
    _pause
}


show_status() {
    local installed protocol service running=0 total=0 status status_color
    _INSTALLED_CACHE=''
    [[ -f "$DB_FILE" ]] || { printf '  %b状态%b  %b○ 未安装%b\n' "$D" "$NC" "$D" "$NC"; return; }
    installed=$(get_installed_protocols)
    [[ -n "$installed" ]] || { printf '  %b状态%b  %b○ 未安装%b\n' "$D" "$NC" "$D" "$NC"; return; }
    _INSTALLED_CACHE="$installed"
    for protocol in $installed; do
        total=$((total+1))
        service="${PROTO_SVC[$protocol]}"
        svc status "$service" >/dev/null 2>&1 && running=$((running+1))
    done
    if is_paused; then status='○ 已暂停'; status_color='\e[1;93m'
    elif ((running == total)); then status='● 运行中'; status_color='\e[1;92m'
    elif ((running > 0)); then status="◐ 部分运行 ($running/$total)"; status_color='\e[1;93m'
    else status='○ 已停止'; status_color='\e[1;91m'; fi
    printf '  %b状态%b  %b%s%b\n\n' "$D" "$NC" "$status_color" "$status" "$NC"
    show_protocols_overview
    if access_restriction_enabled; then printf '  %b访问限制%b  %b已启用%b\n' "$D" "$NC" "$C" "$NC"; fi
}
install_nginx() {
    if check_cmd nginx; then
        _ok "Nginx 已安装"
        return 0
    fi

    _info "安装 Nginx..."
    case "$DISTRO" in
        alpine) apk add --no-cache nginx ;;
        centos) yum install -y nginx ;;
        *) apt-get install -y -qq nginx ;;
    esac

    if check_cmd nginx; then
        _ok "Nginx 安装完成"
        return 0
    else
        _err "Nginx 安装失败"
        return 1
    fi
}

EXTERNAL_LINKS_FILE="$CFG/external_links.txt"
EXTERNAL_SUBS_FILE="$CFG/external_subs.txt"
EXTERNAL_CACHE_DIR="$CFG/external_nodes_cache"

# 解析 vless:// 链接
parse_vless_link() {
    local link="$1"
    parse_proxy_link "$link" >/dev/null || return 1
    # vless://uuid@server:port?params#name
    local content="${link#vless://}"
    local name="${content##*#}"
    name=$(printf '%b' "${name//%/\\x}")  # URL 解码
    # 转义 JSON 特殊字符
    name="${name//\\/\\\\}"
    name="${name//\"/\\\"}"
    content="${content%%#*}"

    local uuid="${content%%@*}"
    content="${content#*@}"

    local server_port="${content%%\?*}"
    # 解析 host:port（支持 IPv6）
    local parsed=$(_parse_hostport "$server_port")
    local server="${parsed%%|*}"
    local port="${parsed##*|}"

    local params="${content#*\?}"

    # 解析参数
    local security="" type="" sni="" pbk="" sid="" flow="" path="" host="" fp="" encryption=""
    IFS='&' read -ra PARAMS <<< "$params"
    for param in "${PARAMS[@]}"; do
        local key="${param%%=*}"
        local value="${param#*=}"
        value=$(printf '%b' "${value//%/\\x}")  # URL 解码
        case "$key" in
            security) security="$value" ;;
            type) type="$value" ;;
            sni) sni="$value" ;;
            pbk) pbk="$value" ;;
            sid) sid="$value" ;;
            flow) flow="$value" ;;
            path) path="$value" ;;
            host) host="$value" ;;
            fp) fp="$value" ;;
            encryption) encryption="$value" ;;
            headerType) ;; # 忽略
        esac
    done

    # 确保 port 是纯数字，无效则报错
    port=$(echo "$port" | tr -d '"' | tr -d ' ')
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "错误: 无法解析端口号 '$port'" >&2
        return 1
    fi

    # 输出 JSON 格式 (使用 jq 确保正确转义，port 使用 argjson 存储为数字)
    # 注意：字段名使用完整名称以便 gen_singbox_chain_outbound 正确读取
    jq -nc \
        --arg type "vless" \
        --arg name "$name" \
        --arg server "$server" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg security "$security" \
        --arg transport "${type:-tcp}" \
        --arg sni "$sni" \
        --arg publicKey "$pbk" \
        --arg shortId "$sid" \
        --arg flow "$flow" \
        --arg path "$path" \
        --arg host "$host" \
        --arg fingerprint "${fp:-chrome}" \
        --arg encryption "$encryption" \
        '{type:$type,name:$name,server:$server,port:$port,uuid:$uuid,security:$security,transport:$transport,sni:$sni,publicKey:$publicKey,shortId:$shortId,flow:$flow,path:$path,host:$host,fingerprint:$fingerprint,encryption:$encryption}'
}

# 解析 vmess:// 链接
parse_vmess_link() {
    local link="$1"
    parse_proxy_link "$link" >/dev/null || return 1
    # vmess://base64(json)
    local content="${link#vmess://}"
    local json=$(echo "$content" | base64 -d 2>/dev/null)
    [[ -z "$json" ]] && return 1

    local name=$(echo "$json" | jq -r '.ps // .name // "VMess"')
    local server=$(echo "$json" | jq -r '.add // .server')
    local port=$(echo "$json" | jq -r '.port')
    local uuid=$(echo "$json" | jq -r '.id // .uuid')
    local aid=$(echo "$json" | jq -r '.aid // "0"')
    local net=$(echo "$json" | jq -r '.net // "tcp"')
    local type=$(echo "$json" | jq -r '.type // "none"')
    local host=$(echo "$json" | jq -r '.host // ""')
    local path=$(echo "$json" | jq -r '.path // ""')
    local tls=$(echo "$json" | jq -r '.tls // ""')
    local sni=$(echo "$json" | jq -r '.sni // ""')

    # 确保 port 和 aid 是数字
    port=$(echo "$port" | tr -d '"' | tr -d ' ')
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "错误: 无法解析端口号 '$port'" >&2
        return 1
    fi
    aid=$(echo "$aid" | tr -d '"' | tr -d ' ')
    [[ ! "$aid" =~ ^[0-9]+$ ]] && aid="0"

    # 使用 jq 生成 JSON，确保 port 和 aid 是数字
    jq -nc \
        --arg type "vmess" \
        --arg name "$name" \
        --arg server "$server" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --argjson aid "$aid" \
        --arg network "$net" \
        --arg host "$host" \
        --arg path "$path" \
        --arg tls "$tls" \
        --arg sni "$sni" \
        '{type:$type,name:$name,server:$server,port:$port,uuid:$uuid,aid:$aid,network:$network,host:$host,path:$path,tls:$tls,sni:$sni}'
}

# 解析 trojan:// 链接
parse_trojan_link() {
    local link="$1"
    parse_proxy_link "$link" >/dev/null || return 1
    # trojan://password@server:port?params#name
    local content="${link#trojan://}"
    local name="${content##*#}"
    name=$(printf '%b' "${name//%/\\x}")  # URL 解码
    content="${content%%#*}"

    local password="${content%%@*}"
    content="${content#*@}"

    local server_port="${content%%\?*}"
    # 解析 host:port（支持 IPv6）
    local parsed=$(_parse_hostport "$server_port")
    local server="${parsed%%|*}"
    local port="${parsed##*|}"

    local params="${content#*\?}"
    local sni="" type="tcp"
    IFS='&' read -ra PARAMS <<< "$params"
    for param in "${PARAMS[@]}"; do
        local key="${param%%=*}"
        local value="${param#*=}"
        case "$key" in
            sni) sni="$value" ;;
            type) type="$value" ;;
        esac
    done

    # 确保 port 是数字
    port=$(echo "$port" | tr -d '"' | tr -d ' ')
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "错误: 无法解析端口号 '$port'" >&2
        return 1
    fi

    # 使用 jq 生成 JSON
    jq -nc \
        --arg type "trojan" \
        --arg name "$name" \
        --arg server "$server" \
        --argjson port "$port" \
        --arg password "$password" \
        --arg sni "$sni" \
        --arg transport "$type" \
        '{type:$type,name:$name,server:$server,port:$port,password:$password,sni:$sni,transport:$transport}'
}

# 解析 ss:// 链接
parse_ss_link() {
    local link="$1"
    # ss://base64(method:password)@server:port#name
    # 或 ss://base64(method:password@server:port)#name
    local content="${link#ss://}"
    local name="${content##*#}"
    name=$(printf '%b' "${name//%/\\x}")
    content="${content%%#*}"

    local server="" port="" method="" password=""

    if [[ "$content" == *"@"* ]]; then
        # 格式: base64@server:port
        local encoded="${content%%@*}"
        local decoded=$(echo "$encoded" | base64 -d 2>/dev/null)
        if [[ "$decoded" == *":"* ]]; then
            method="${decoded%%:*}"
            password="${decoded#*:}"
        fi
        local server_port="${content#*@}"
        # 解析 host:port（支持 IPv6）
        local parsed=$(_parse_hostport "$server_port")
        server="${parsed%%|*}"
        port="${parsed##*|}"
    else
        # 格式: base64(全部)
        local decoded=$(echo "$content" | base64 -d 2>/dev/null)
        if [[ "$decoded" == *"@"* ]]; then
            local method_pass="${decoded%%@*}"
            method="${method_pass%%:*}"
            password="${method_pass#*:}"
            local server_port="${decoded#*@}"
            # 解析 host:port（支持 IPv6）
            local parsed=$(_parse_hostport "$server_port")
            server="${parsed%%|*}"
            port="${parsed##*|}"
        fi
    fi

    # 确保 port 是数字
    port=$(echo "$port" | tr -d '"' | tr -d ' ')
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "错误: 无法解析端口号 '$port'" >&2
        return 1
    fi

    # 使用 jq 生成 JSON
    jq -nc \
        --arg type "ss" \
        --arg name "$name" \
        --arg server "$server" \
        --argjson port "$port" \
        --arg method "$method" \
        --arg password "$password" \
        '{type:$type,name:$name,server:$server,port:$port,method:$method,password:$password}'
}

# 解析 hysteria2:// 链接
parse_hy2_link() {
    local link="$1"
    # hysteria2://password@server:port?params#name
    local content="${link#hysteria2://}"
    content="${content#hy2://}"
    local name="${content##*#}"
    name=$(printf '%b' "${name//%/\\x}")  # URL 解码
    content="${content%%#*}"

    local password="${content%%@*}"
    content="${content#*@}"

    local server_port="${content%%\?*}"
    # 解析 host:port（支持 IPv6）
    local parsed=$(_parse_hostport "$server_port")
    local server="${parsed%%|*}"
    local port="${parsed##*|}"

    local params="${content#*\?}"
    local sni="" insecure="1"
    IFS='&' read -ra PARAMS <<< "$params"
    for param in "${PARAMS[@]}"; do
        local key="${param%%=*}"
        local value="${param#*=}"
        case "$key" in
            sni) sni="$value" ;;
            insecure) insecure="$value" ;;
        esac
    done

    # 确保 port 是数字
    port=$(echo "$port" | tr -d '"' | tr -d ' ')
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "错误: 无法解析端口号 '$port'" >&2
        return 1
    fi

    # 使用 jq 生成 JSON
    jq -nc \
        --arg type "hysteria2" \
        --arg name "$name" \
        --arg server "$server" \
        --argjson port "$port" \
        --arg password "$password" \
        --arg sni "$sni" \
        '{type:$type,name:$name,server:$server,port:$port,password:$password,sni:$sni}'
}

# 解析 anytls:// 链接
parse_anytls_link() {
    local link="$1"
    # anytls://password@server:port?sni=xxx#name
    local content="${link#anytls://}"
    local name="${content##*#}"
    name=$(printf '%b' "${name//%/\\x}")
    content="${content%%#*}"

    local password="${content%%@*}"
    content="${content#*@}"

    local server_port="${content%%\?*}"
    # 解析 host:port（支持 IPv6）
    local parsed=$(_parse_hostport "$server_port")
    local server="${parsed%%|*}"
    local port="${parsed##*|}"

    local params="${content#*\?}"
    local sni=""
    IFS='&' read -ra PARAMS <<< "$params"
    for param in "${PARAMS[@]}"; do
        local key="${param%%=*}"
        local value="${param#*=}"
        case "$key" in
            sni) sni="$value" ;;
        esac
    done

    # 确保 port 是数字
    port=$(echo "$port" | tr -d '"' | tr -d ' ')
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "错误: 无法解析端口号 '$port'" >&2
        return 1
    fi

    # 使用 jq 生成 JSON
    jq -nc \
        --arg type "anytls" \
        --arg name "$name" \
        --arg server "$server" \
        --argjson port "$port" \
        --arg password "$password" \
        --arg sni "$sni" \
        '{type:$type,name:$name,server:$server,port:$port,password:$password,sni:$sni}'
}

# 解析任意分享链接
parse_share_link() {
    local link="$1"
    case "$link" in
        vless://*) parse_vless_link "$link" ;;
        vmess://*) parse_vmess_link "$link" ;;
        trojan://*) parse_trojan_link "$link" ;;
        ss://*) parse_ss_link "$link" ;;
        hysteria2://*|hy2://*) parse_hy2_link "$link" ;;
        anytls://*) parse_anytls_link "$link" ;;
        *) echo "" ;;
    esac
}

# 从分享链接提取节点名称
get_link_name() {
    local link="$1"
    local name="${link##*#}"
    name=$(printf '%b' "${name//%/\\x}")
    [[ -z "$name" || "$name" == "$link" ]] && name="未命名节点"
    echo "$name"
}

# 拉取订阅内容
fetch_subscription() {
    local url="$1"
    local allowed_protocols="=https"
    if ! _is_valid_subscription_url "$url"; then
        _err "订阅地址无效：仅允许 HTTPS；如确需 HTTP，请显式设置 ALLOW_INSECURE_HTTP_SUBSCRIPTIONS=1"
        return 1
    fi
    [[ "${ALLOW_INSECURE_HTTP_SUBSCRIPTIONS:-0}" == "1" ]] && allowed_protocols="=http,https"
    local content
    if ! content=$(curl -sL --connect-timeout 10 --max-time 30 \
        --max-filesize "$SUBSCRIPTION_MAX_BYTES" \
        --proto "$allowed_protocols" --proto-redir "$allowed_protocols" \
        -- "$url" 2>/dev/null); then
        return 1
    fi
    [[ -z "$content" ]] && return 1

    # 尝试 Base64 解码
    local decoded=$(echo "$content" | base64 -d 2>/dev/null)
    if [[ -n "$decoded" && "$decoded" == *"://"* ]]; then
        echo "$decoded"
        return 0
    fi

    # 检查是否是 Clash YAML
    if [[ "$content" == *"proxies:"* ]]; then
        # 解析 Clash YAML 节点，转换为分享链接
        local links=""
        local in_proxies=false
        local current_proxy=""
        local name="" type="" server="" port="" uuid="" password="" method=""
        local network="" tls="" sni="" path="" host="" flow="" pbk="" sid=""

        while IFS= read -r line || [[ -n "$line" ]]; do
            # 检测 proxies 段
            if [[ "$line" =~ ^proxies: ]]; then
                in_proxies=true
                continue
            fi

            # 检测离开 proxies 段
            if [[ "$in_proxies" == "true" && "$line" =~ ^[a-z-]+: && ! "$line" =~ ^[[:space:]] ]]; then
                in_proxies=false
            fi

            [[ "$in_proxies" != "true" ]] && continue

            # 新节点开始
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name: ]]; then
                # 保存上一个节点
                if [[ -n "$name" && -n "$type" && -n "$server" && -n "$port" ]]; then
                    case "$type" in
                        vless)
                            local link="vless://${uuid}@${server}:${port}?encryption=none"
                            [[ -n "$flow" ]] && link+="&flow=$flow"
                            [[ "$tls" == "true" ]] && link+="&security=reality&type=${network:-tcp}&sni=$sni&fp=chrome&pbk=$pbk&sid=$sid" || link+="&security=none&type=${network:-tcp}"
                            [[ "$network" == "ws" ]] && link+="&type=ws&path=$(urlencode "$path")&host=$host"
                            link+="#$(urlencode "$name")"
                            links+="$link"$'\n'
                            ;;
                        vmess)
                            local vmess_json="{\"v\":\"2\",\"ps\":\"$name\",\"add\":\"$server\",\"port\":\"$port\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"${network:-tcp}\",\"type\":\"none\",\"host\":\"$host\",\"path\":\"$path\",\"tls\":\"$([[ "$tls" == "true" ]] && echo "tls" || echo "")\",\"sni\":\"$sni\"}"
                            links+="vmess://$(echo -n "$vmess_json" | base64 -w 0)"$'\n'
                            ;;
                        trojan)
                            links+="trojan://${password}@${server}:${port}?sni=$sni#$(urlencode "$name")"$'\n'
                            ;;
                        ss)
                            local ss_encoded=$(echo -n "${method}:${password}" | base64 -w 0)
                            links+="ss://${ss_encoded}@${server}:${port}#$(urlencode "$name")"$'\n'
                            ;;
                        hysteria2)
                            links+="hysteria2://${password}@${server}:${port}?sni=$sni#$(urlencode "$name")"$'\n'
                            ;;
                        tuic)
                            links+="tuic://${uuid}:${password}@${server}:${port}?sni=$sni#$(urlencode "$name")"$'\n'
                            ;;
                    esac
                fi
                # 重置变量
                name="" type="" server="" port="" uuid="" password="" method=""
                network="" tls="" sni="" path="" host="" flow="" pbk="" sid=""
                name=$(echo "$line" | sed 's/.*name:[[:space:]]*"\?\([^"]*\)"\?.*/\1/')
                continue
            fi

            # 解析属性 (去掉引号)
            _strip_quotes() { local v="$1"; v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"; echo "$v"; }
            [[ "$line" =~ ^[[:space:]]*type:[[:space:]]*(.*) ]] && type=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*server:[[:space:]]*(.*) ]] && server=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*port:[[:space:]]*(.*) ]] && port=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*uuid:[[:space:]]*(.*) ]] && uuid=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*password:[[:space:]]*(.*) ]] && password=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*cipher:[[:space:]]*(.*) ]] && method=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*network:[[:space:]]*(.*) ]] && network=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*tls:[[:space:]]*(.*) ]] && tls=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*sni:[[:space:]]*(.*) ]] && sni=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*servername:[[:space:]]*(.*) ]] && sni=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*flow:[[:space:]]*(.*) ]] && flow=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*path:[[:space:]]*(.*) ]] && path=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*Host:[[:space:]]*(.*) ]] && host=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*public-key:[[:space:]]*(.*) ]] && pbk=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*short-id:[[:space:]]*(.*) ]] && sid=$(_strip_quotes "${BASH_REMATCH[1]}")
        done <<< "$content"

        # 处理最后一个节点
        if [[ -n "$name" && -n "$type" && -n "$server" && -n "$port" ]]; then
            case "$type" in
                vless)
                    local link="vless://${uuid}@${server}:${port}?encryption=none"
                    [[ -n "$flow" ]] && link+="&flow=$flow"
                    [[ "$tls" == "true" ]] && link+="&security=reality&type=${network:-tcp}&sni=$sni&fp=chrome&pbk=$pbk&sid=$sid" || link+="&security=none&type=${network:-tcp}"
                    link+="#$(urlencode "$name")"
                    links+="$link"$'\n'
                    ;;
                vmess)
                    local vmess_json="{\"v\":\"2\",\"ps\":\"$name\",\"add\":\"$server\",\"port\":\"$port\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"${network:-tcp}\",\"type\":\"none\",\"host\":\"$host\",\"path\":\"$path\",\"tls\":\"$([[ "$tls" == "true" ]] && echo "tls" || echo "")\",\"sni\":\"$sni\"}"
                    links+="vmess://$(echo -n "$vmess_json" | base64 -w 0)"$'\n'
                    ;;
                trojan)
                    links+="trojan://${password}@${server}:${port}?sni=$sni#$(urlencode "$name")"$'\n'
                    ;;
                ss)
                    local ss_encoded=$(echo -n "${method}:${password}" | base64 -w 0)
                    links+="ss://${ss_encoded}@${server}:${port}#$(urlencode "$name")"$'\n'
                    ;;
                hysteria2)
                    links+="hysteria2://${password}@${server}:${port}?sni=$sni#$(urlencode "$name")"$'\n'
                    ;;
                tuic)
                    links+="tuic://${uuid}:${password}@${server}:${port}?sni=$sni#$(urlencode "$name")"$'\n'
                    ;;
            esac
        fi

        [[ -n "$links" ]] && echo "$links" && return 0
        return 1
    fi

    # 原样返回（可能已经是链接列表）
    if [[ "$content" == *"://"* ]]; then
        echo "$content"
        return 0
    fi

    return 1
}

# 刷新所有订阅
refresh_external_subs() {
    [[ ! -f "$EXTERNAL_SUBS_FILE" ]] && return 0

    mkdir -p "$EXTERNAL_CACHE_DIR"
    local count=0
    local idx=0

    while IFS= read -r url || [[ -n "$url" ]]; do
        [[ -z "$url" || "$url" == \#* ]] && continue
        ((idx++))

        _info "拉取订阅 $idx: $url"
        local content=$(fetch_subscription "$url")

        if [[ -n "$content" ]]; then
            echo "$content" > "$EXTERNAL_CACHE_DIR/sub_$idx.txt"
            local node_count=$(echo "$content" | grep -c '://' || echo 0)
            _ok "获取 $node_count 个节点"
            ((count+=node_count))
        else
            _warn "拉取失败: $url"
        fi
    done < "$EXTERNAL_SUBS_FILE"

    _ok "共刷新 $count 个外部节点"

    # 自动更新订阅文件
    [[ -f "$CFG/sub.info" ]] && generate_sub_files
}

# 获取所有外部节点链接
get_all_external_links() {
    local links=""

    # 直接添加的分享链接
    if [[ -f "$EXTERNAL_LINKS_FILE" ]]; then
        while IFS= read -r link || [[ -n "$link" ]]; do
            [[ -z "$link" || "$link" == \#* ]] && continue
            links+="$link"$'\n'
        done < "$EXTERNAL_LINKS_FILE"
    fi

    # 订阅缓存的节点
    if [[ -d "$EXTERNAL_CACHE_DIR" ]]; then
        for cache_file in "$EXTERNAL_CACHE_DIR"/*.txt; do
            [[ ! -f "$cache_file" ]] && continue
            while IFS= read -r link || [[ -n "$link" ]]; do
                [[ -z "$link" || "$link" == \#* ]] && continue
                [[ "$link" != *"://"* ]] && continue
                links+="$link"$'\n'
            done < "$cache_file"
        done
    fi

    echo -n "$links"
}

# 将外部节点转换为 Clash 格式
external_link_to_clash() {
    local link="$1"
    local json=$(parse_share_link "$link")
    [[ -z "$json" ]] && return

    local type=$(echo "$json" | jq -r '.type')
    local name=$(echo "$json" | jq -r '.name')
    local server=$(echo "$json" | jq -r '.server')
    local port=$(echo "$json" | jq -r '.port')

    # 给外部节点名称加上服务器标识，避免与本地节点重复
    local server_suffix=$(get_ip_suffix "$server")
    [[ -n "$server_suffix" && "$name" != *"-${server_suffix}"* && "$name" != *"-${server_suffix}" ]] && name="${name}-${server_suffix}"

    case "$type" in
        vless)
            local uuid=$(echo "$json" | jq -r '.uuid')
            local security=$(echo "$json" | jq -r '.security')
            local transport=$(echo "$json" | jq -r '.transport')
            local sni=$(echo "$json" | jq -r '.sni')
            local pbk=$(echo "$json" | jq -r '.pbk')
            local sid=$(echo "$json" | jq -r '.sid')
            local flow=$(echo "$json" | jq -r '.flow')
            local path=$(echo "$json" | jq -r '.path')

            if [[ "$security" == "reality" ]]; then
                cat << EOF
  - name: "$name"
    type: vless
    server: "$server"
    port: $port
    uuid: $uuid
    network: ${transport:-tcp}
    tls: true
    udp: true
    flow: $flow
    servername: $sni
    reality-opts:
      public-key: $pbk
      short-id: $sid
    client-fingerprint: chrome
EOF
            elif [[ "$transport" == "ws" ]]; then
                cat << EOF
  - name: "$name"
    type: vless
    server: "$server"
    port: $port
    uuid: $uuid
    network: ws
    tls: true
    udp: true
    skip-cert-verify: true
    servername: $sni
    ws-opts:
      path: $path
      headers:
        Host: $sni
EOF
            else
                cat << EOF
  - name: "$name"
    type: vless
    server: "$server"
    port: $port
    uuid: $uuid
    network: tcp
    tls: true
    udp: true
    skip-cert-verify: true
    servername: $sni
EOF
            fi
            ;;
        vmess)
            local uuid=$(echo "$json" | jq -r '.uuid')
            local network=$(echo "$json" | jq -r '.network')
            local tls=$(echo "$json" | jq -r '.tls')
            local sni=$(echo "$json" | jq -r '.sni')
            local path=$(echo "$json" | jq -r '.path')
            local host=$(echo "$json" | jq -r '.host')

            cat << EOF
  - name: "$name"
    type: vmess
    server: "$server"
    port: $port
    uuid: $uuid
    alterId: 0
    cipher: auto
    network: ${network:-tcp}
    tls: $([[ "$tls" == "tls" ]] && echo "true" || echo "false")
    skip-cert-verify: true
    servername: ${sni:-$host}
EOF
            if [[ "$network" == "ws" ]]; then
                cat << EOF
    ws-opts:
      path: ${path:-/}
      headers:
        Host: ${host:-$sni}
EOF
            fi
            ;;
        trojan)
            local password=$(echo "$json" | jq -r '.password')
            local sni=$(echo "$json" | jq -r '.sni')
            cat << EOF
  - name: "$name"
    type: trojan
    server: "$server"
    port: $port
    password: $password
    sni: $sni
    skip-cert-verify: true
    udp: true
EOF
            ;;
        ss)
            local method=$(echo "$json" | jq -r '.method')
            local password=$(echo "$json" | jq -r '.password')
            cat << EOF
  - name: "$name"
    type: ss
    server: "$server"
    port: $port
    cipher: $method
    password: $password
    udp: true
EOF
            ;;
        hysteria2)
            local password=$(echo "$json" | jq -r '.password')
            local sni=$(echo "$json" | jq -r '.sni')
            cat << EOF
  - name: "$name"
    type: hysteria2
    server: "$server"
    port: $port
    password: $password
    sni: $sni
    skip-cert-verify: true
EOF
            ;;
        anytls)
            local password=$(echo "$json" | jq -r '.password')
            local sni=$(echo "$json" | jq -r '.sni')
            cat << EOF
  - name: "$name"
    type: anytls
    server: "$server"
    port: $port
    password: $password
    sni: $sni
    skip-cert-verify: true
EOF
            ;;
    esac
}

# 将外部节点转换为 Surge 格式
external_link_to_surge() {
    local link="$1"
    local json=$(parse_share_link "$link")
    [[ -z "$json" ]] && return

    local type=$(echo "$json" | jq -r '.type')
    local name=$(echo "$json" | jq -r '.name')
    local server=$(echo "$json" | jq -r '.server')
    local port=$(echo "$json" | jq -r '.port')

    # 给外部节点名称加上服务器标识，避免与本地节点重复
    local server_suffix=$(get_ip_suffix "$server")
    [[ -n "$server_suffix" && "$name" != *"-${server_suffix}"* && "$name" != *"-${server_suffix}" ]] && name="${name}-${server_suffix}"

    case "$type" in
        vmess)
            local uuid=$(echo "$json" | jq -r '.uuid')
            local network=$(echo "$json" | jq -r '.network')
            local tls=$(echo "$json" | jq -r '.tls')
            local sni=$(echo "$json" | jq -r '.sni')
            local path=$(echo "$json" | jq -r '.path')
            if [[ "$network" == "ws" ]]; then
                echo "$name = vmess, $server, $port, $uuid, tls=$([[ "$tls" == "tls" ]] && echo "true" || echo "false"), ws=true, ws-path=${path:-/}, sni=$sni, skip-cert-verify=true"
            else
                echo "$name = vmess, $server, $port, $uuid, tls=$([[ "$tls" == "tls" ]] && echo "true" || echo "false"), skip-cert-verify=true"
            fi
            ;;
        trojan)
            local password=$(echo "$json" | jq -r '.password')
            local sni=$(echo "$json" | jq -r '.sni')
            echo "$name = trojan, $server, $port, password=$password, sni=$sni, skip-cert-verify=true"
            ;;
        ss)
            local method=$(echo "$json" | jq -r '.method')
            local password=$(echo "$json" | jq -r '.password')
            echo "$name = ss, $server, $port, encrypt-method=$method, password=$password"
            ;;
        hysteria2)
            local password=$(echo "$json" | jq -r '.password')
            local sni=$(echo "$json" | jq -r '.sni')
            echo "$name = hysteria2, $server, $port, password=$password, sni=$sni, skip-cert-verify=true"
            ;;
        anytls)
            local password=$(echo "$json" | jq -r '.password')
            local sni=$(echo "$json" | jq -r '.sni')
            echo "$name = anytls, $server, $port, password=$password, sni=$sni, skip-cert-verify=true"
            ;;
    esac
}

# 设置/替换分享链接名称
set_link_name() {
    local link="$1" new_name="$2"
    local base="${link%%#*}"
    [[ -z "$new_name" ]] && { echo "$base"; return 0; }
    python3 - "$base" "$new_name" <<'PYEOF'
import sys, urllib.parse
base, name = sys.argv[1], sys.argv[2]
print(base + '#' + urllib.parse.quote(name, safe=''))
PYEOF
}

# 添加分享链接
add_external_link() {
    echo ""
    _line
    echo -e "  ${W}添加分享链接${NC}"
    echo -e "  ${D}支持: vless://, vmess://, trojan://, ss://, hysteria2://, anytls://${NC}"
    _line
    echo ""
    read -rp "  请输入分享链接: " link

    [[ -z "$link" ]] && return

    # 验证链接格式
    if [[ "$link" != *"://"* ]]; then
        _err "无效的链接格式"
        return 1
    fi

    local name=$(get_link_name "$link")
    echo -e "  ${D}直接回车保留原名称，或输入新名称${NC}"
    read -rp "  节点名称 [$name]: " custom_name
    [[ -n "$custom_name" ]] && link="$(set_link_name "$link" "$custom_name")" && name="$custom_name"

    # 检查是否已存在
    if [[ -f "$EXTERNAL_LINKS_FILE" ]] && grep -qF "$link" "$EXTERNAL_LINKS_FILE"; then
        _warn "该链接已存在"
        return 1
    fi

    # 保存
    mkdir -p "$(dirname "$EXTERNAL_LINKS_FILE")"
    echo "$link" >> "$EXTERNAL_LINKS_FILE"

    _ok "已添加节点: $name"

    # 自动更新订阅文件
    if [[ -f "$CFG/sub.info" ]]; then
        generate_sub_files
    fi
}

# 添加订阅链接
add_external_sub() {
    echo ""
    _line
    echo -e "  ${W}添加订阅链接${NC}"
    echo -e "  ${D}支持 V2Ray/Base64 订阅、Clash YAML 订阅${NC}"
    _line
    echo ""
    read -rp "  请输入订阅链接: " url

    [[ -z "$url" ]] && return

    # 与实际拉取逻辑使用同一校验，默认只接受 HTTPS。
    if ! _is_valid_subscription_url "$url"; then
        _err "无效的订阅 URL（默认仅允许 HTTPS）"
        return 1
    fi

    # 检查是否已存在
    if [[ -f "$EXTERNAL_SUBS_FILE" ]] && grep -qF "$url" "$EXTERNAL_SUBS_FILE"; then
        _warn "该订阅已存在"
        return 1
    fi

    # 测试拉取
    _info "测试订阅链接..."
    local content=$(fetch_subscription "$url")

    if [[ -z "$content" ]]; then
        _err "无法获取订阅内容"
        return 1
    fi

    local node_count=$(echo "$content" | grep -c '://' || echo 0)

    # 保存
    mkdir -p "$(dirname "$EXTERNAL_SUBS_FILE")"
    echo "$url" >> "$EXTERNAL_SUBS_FILE"

    # 缓存节点
    mkdir -p "$EXTERNAL_CACHE_DIR"
    local idx=$(wc -l < "$EXTERNAL_SUBS_FILE" 2>/dev/null || echo 1)
    echo "$content" > "$EXTERNAL_CACHE_DIR/sub_$idx.txt"

    _ok "已添加订阅，包含 $node_count 个节点"

    # 自动更新订阅文件
    if [[ -f "$CFG/sub.info" ]]; then
        generate_sub_files
    fi
}

# 查看外部节点
show_external_nodes() {
    echo ""
    _line
    echo -e "  ${W}外部节点列表${NC}"
    _line

    local count=0

    # 显示分享链接
    if [[ -f "$EXTERNAL_LINKS_FILE" ]]; then
        echo -e "\n  ${Y}[分享链接]${NC}"
        local idx=0
        while IFS= read -r link || [[ -n "$link" ]]; do
            [[ -z "$link" || "$link" == \#* ]] && continue
            ((idx++))
            ((count++))
            local name=$(get_link_name "$link")
            local proto="${link%%://*}"
            echo -e "  ${G}$idx)${NC} [$proto] $name"
        done < "$EXTERNAL_LINKS_FILE"
        [[ $idx -eq 0 ]] && echo -e "  ${D}(无)${NC}"
    fi

    # 显示订阅
    if [[ -f "$EXTERNAL_SUBS_FILE" ]]; then
        echo -e "\n  ${Y}[订阅链接]${NC}"
        local idx=0
        while IFS= read -r url || [[ -n "$url" ]]; do
            [[ -z "$url" || "$url" == \#* ]] && continue
            ((idx++))
            local cache_file="$EXTERNAL_CACHE_DIR/sub_$idx.txt"
            local node_count=0
            [[ -f "$cache_file" ]] && node_count=$(grep -c '://' "$cache_file" 2>/dev/null || echo 0)
            ((count+=node_count))
            echo -e "  ${G}$idx)${NC} $url ${D}($node_count 个节点)${NC}"
        done < "$EXTERNAL_SUBS_FILE"
        [[ $idx -eq 0 ]] && echo -e "  ${D}(无)${NC}"
    fi

    echo ""
    _line
    echo -e "  ${C}共 $count 个外部节点${NC}"
    _line
}

# 重命名外部节点
rename_external_node() {
    [[ -f "$EXTERNAL_LINKS_FILE" ]] || { _warn "没有可重命名的分享链接节点"; return; }

    echo ""
    _line
    echo -e "  ${W}重命名外部节点${NC}"
    _line

    mapfile -t links < <(grep -v '^\s*#' "$EXTERNAL_LINKS_FILE" 2>/dev/null | sed '/^\s*$/d')
    [[ ${#links[@]} -gt 0 ]] || { _warn "没有可重命名的分享链接节点"; return; }

    local i=0
    for link in "${links[@]}"; do
        ((i++))
        echo -e "  ${G}$i)${NC} [${link%%://*}] $(get_link_name "$link")"
    done

    echo ""
    local rename_idx old_link old_name new_name new_link
    read -rp "  输入序号重命名 (0 取消): " rename_idx
    [[ "$rename_idx" == "0" || -z "$rename_idx" ]] && return
    [[ "$rename_idx" =~ ^[0-9]+$ ]] || { _err "无效序号"; return; }
    (( rename_idx >= 1 && rename_idx <= ${#links[@]} )) || { _err "无效序号"; return; }

    old_link="${links[$((rename_idx-1))]}"
    old_name=$(get_link_name "$old_link")
    read -rp "  新名称 [$old_name]: " new_name
    new_name="${new_name:-$old_name}"
    [[ "$new_name" == "$old_name" ]] && { _info "名称未变更"; return; }

    new_link=$(set_link_name "$old_link" "$new_name")
    python3 - "$EXTERNAL_LINKS_FILE" "$old_link" "$new_link" <<'PYEOF'
from pathlib import Path
import sys
path=Path(sys.argv[1])
old=sys.argv[2]
new=sys.argv[3]
lines=path.read_text().splitlines()
replaced=False
out=[]
for line in lines:
    if not replaced and line == old:
        out.append(new)
        replaced=True
    else:
        out.append(line)
path.write_text(chr(10).join(out) + (chr(10) if out else ""))
print('ok' if replaced else 'missing')
PYEOF
    [[ $? -eq 0 ]] || { _err "重命名失败"; return; }

    _ok "已重命名: $old_name -> $new_name"
    [[ -f "$CFG/sub.info" ]] && generate_sub_files
}

# 删除外部节点
delete_external_node() {
    echo ""
    _line
    echo -e "  ${W}删除外部节点${NC}"
    _line
    echo -e "  ${G}1)${NC} 删除分享链接"
    echo -e "  ${G}2)${NC} 删除订阅链接"
    echo -e "  ${G}3)${NC} 清空所有外部节点"
    echo -e "  ${G}0)${NC} 返回"
    _line

    read -rp "  请选择: " choice

    case "$choice" in
        1)
            [[ ! -f "$EXTERNAL_LINKS_FILE" ]] && { _warn "没有分享链接"; return; }
            echo ""
            local idx=0
            while IFS= read -r link || [[ -n "$link" ]]; do
                [[ -z "$link" || "$link" == \#* ]] && continue
                ((idx++))
                local name=$(get_link_name "$link")
                echo -e "  ${G}$idx)${NC} $name"
            done < "$EXTERNAL_LINKS_FILE"
            echo ""
            read -rp "  输入序号删除 (0 取消): " del_idx
            [[ "$del_idx" == "0" || -z "$del_idx" ]] && return

            sed -i "${del_idx}d" "$EXTERNAL_LINKS_FILE" 2>/dev/null && _ok "已删除" || _err "删除失败"
            # 自动更新订阅文件
            [[ -f "$CFG/sub.info" ]] && generate_sub_files
            ;;
        2)
            [[ ! -f "$EXTERNAL_SUBS_FILE" ]] && { _warn "没有订阅链接"; return; }
            echo ""
            local idx=0
            while IFS= read -r url || [[ -n "$url" ]]; do
                [[ -z "$url" || "$url" == \#* ]] && continue
                ((idx++))
                echo -e "  ${G}$idx)${NC} $url"
            done < "$EXTERNAL_SUBS_FILE"
            echo ""
            read -rp "  输入序号删除 (0 取消): " del_idx
            [[ "$del_idx" == "0" || -z "$del_idx" ]] && return

            sed -i "${del_idx}d" "$EXTERNAL_SUBS_FILE" 2>/dev/null
            rm -f "$EXTERNAL_CACHE_DIR/sub_$del_idx.txt" 2>/dev/null
            _ok "已删除"
            # 自动更新订阅文件
            [[ -f "$CFG/sub.info" ]] && generate_sub_files
            ;;
        3)
            read -rp "  确认清空所有外部节点? [y/N]: " confirm
            [[ "$confirm" =~ ^[yY]$ ]] || return
            rm -f "$EXTERNAL_LINKS_FILE" "$EXTERNAL_SUBS_FILE"
            rm -rf "$EXTERNAL_CACHE_DIR"
            _ok "已清空所有外部节点"
            # 自动更新订阅文件
            [[ -f "$CFG/sub.info" ]] && generate_sub_files
            ;;
    esac
}

# 外部节点管理菜单
manage_external_nodes() {
    while true; do
        _header
        echo -e "  ${W}外部节点管理${NC}"
        _line
        _item "1" "添加分享链接"
        _item "2" "添加订阅链接"
        _item "3" "查看外部节点"
        _item "4" "重命名外部节点"
        _item "5" "删除外部节点"
        _item "6" "刷新订阅"
        _line
        _item "0" "返回"
        _line

        read -rp "  请选择: " choice

        case "$choice" in
            1) add_external_link ;;
            2) add_external_sub ;;
            3) show_external_nodes ;;
            4) rename_external_node ;;
            5) delete_external_node ;;
            6) refresh_external_subs ;;
            0|"") return ;;
            *) _err "无效选择" ;;
        esac

        echo ""
        read -rp "按回车继续..."
    done
}

# 获取或生成订阅 UUID
get_sub_uuid() {
    local uuid_file="$CFG/sub_uuid"
    if [[ -f "$uuid_file" ]]; then
        cat "$uuid_file"
    else
        local new_uuid=$(gen_uuid)
        echo "$new_uuid" > "$uuid_file"
        chmod 600 "$uuid_file"
        echo "$new_uuid"
    fi
}

# 重置订阅 UUID（生成新的）
reset_sub_uuid() {
    local uuid_file="$CFG/sub_uuid"
    local new_uuid=$(gen_uuid)
    echo "$new_uuid" > "$uuid_file"
    chmod 600 "$uuid_file"
    echo "$new_uuid"
}

_is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 ))
}

_is_valid_ipv4_literal() {
    local value="$1" octet
    local parts=()
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS='.' read -r -a parts <<<"$value"
    [[ ${#parts[@]} -eq 4 ]] || return 1
    for octet in "${parts[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] && (( 10#$octet <= 255 )) || return 1
    done
}

_is_valid_ipv6_literal() {
    local value="$1" segment left right without_first
    local left_parts=() right_parts=() parts=()
    [[ "$value" == *:* && "$value" != *:::* && "$value" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    if [[ "$value" == *::* ]]; then
        without_first="${value/::/}"
        [[ "$without_first" != *::* ]] || return 1
        left="${value%%::*}"
        right="${value#*::}"
        [[ -z "$left" ]] || IFS=':' read -r -a left_parts <<<"$left"
        [[ -z "$right" ]] || IFS=':' read -r -a right_parts <<<"$right"
        (( ${#left_parts[@]} + ${#right_parts[@]} < 8 )) || return 1
        parts=("${left_parts[@]}" "${right_parts[@]}")
    else
        [[ "$value" != :* && "$value" != *: ]] || return 1
        IFS=':' read -r -a parts <<<"$value"
        [[ ${#parts[@]} -eq 8 ]] || return 1
    fi
    for segment in "${parts[@]}"; do
        [[ "$segment" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
    done
}

_is_valid_dns_server_list() {
    local list="$1" server
    local servers=()
    [[ -z "$list" ]] && return 0
    [[ "$list" != *, && "$list" != ,* && "$list" != *,,* ]] || return 1
    IFS=',' read -r -a servers <<<"$list"
    [[ ${#servers[@]} -ge 1 ]] || return 1
    for server in "${servers[@]}"; do
        [[ "$server" != *[[:space:]]* ]] || return 1
        _is_valid_ipv4_literal "$server" || _is_valid_ipv6_literal "$server" || return 1
    done
}

_is_valid_dns_name() {
    local value="$1"
    [[ "$value" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

_is_valid_domain_or_ip() {
    local value="$1" octet
    [[ -z "$value" ]] && return 0
    if [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local parts=()
        IFS='.' read -r -a parts <<<"$value"
        [[ ${#parts[@]} -eq 4 ]] || return 1
        for octet in "${parts[@]}"; do
            [[ "$octet" =~ ^[0-9]+$ ]] && (( 10#$octet <= 255 )) || return 1
        done
        return 0
    fi
    if [[ "$value" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    fi
    [[ "$value" == *:* && "$value" != *:::* && "$value" =~ ^[0-9a-fA-F:]+$ ]]
}

_is_valid_subscription_url() {
    local url="$1"
    [[ "$url" =~ ^https://[^[:space:]]+$ ]] && return 0
    [[ "${ALLOW_INSECURE_HTTP_SUBSCRIPTIONS:-0}" == "1" &&
       "$url" =~ ^http://[^[:space:]]+$ ]]
}

_write_sub_info() {
    local uuid_value="$1" port_value="$2" domain_value="$3" https_value="$4"
    [[ "$uuid_value" =~ ^[0-9a-fA-F-]{16,64}$ ]] || return 1
    _is_valid_port "$port_value" || return 1
    _is_valid_domain_or_ip "$domain_value" || return 1
    [[ "$https_value" == "true" || "$https_value" == "false" ]] || return 1
    {
        printf 'sub_uuid=%s\n' "$uuid_value"
        printf 'sub_port=%s\n' "$port_value"
        printf 'sub_domain=%s\n' "$domain_value"
        printf 'sub_https=%s\n' "$https_value"
    } >"$CFG/sub.info"
    chmod 600 "$CFG/sub.info"
}

# 仅解析白名单字段，不执行 sub.info 中的 shell 代码。
_load_sub_info() {
    local file="${1:-$CFG/sub.info}" line key value
    [[ -f "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        key=${line%%=*}
        value=${line#*=}
        case "$key" in
            sub_uuid)
                [[ "$value" =~ ^[0-9a-fA-F-]{16,64}$ ]] || return 1
                printf -v sub_uuid '%s' "$value"
                ;;
            sub_port)
                _is_valid_port "$value" || return 1
                printf -v sub_port '%s' "$value"
                ;;
            sub_domain)
                _is_valid_domain_or_ip "$value" || return 1
                printf -v sub_domain '%s' "$value"
                ;;
            sub_https)
                [[ "$value" == "true" || "$value" == "false" ]] || return 1
                printf -v sub_https '%s' "$value"
                ;;
            ""|\#*) ;;
            *) return 1 ;;
        esac
    done <"$file"
    [[ -n "${sub_uuid:-}" && -n "${sub_port:-}" && -n "${sub_https:-}" ]]
}

# 生成 V2Ray/通用 Base64 订阅内容
db_subscription_configs() {
    local core="$1" proto="$2"
    db_protocol_configs "$core" "$proto" | jq -c --arg proto "$proto" '
        . as $cfg |
        if has("users") then
            (.users // [])[] | select(.enabled != false) | . as $user |
            $cfg + {
                uuid: ($user.uuid // $cfg.uuid),
                password: ($user.password //
                    (if (["hy2", "anytls", "naive", "socks", "ss2022", "ss-legacy"] | index($proto)) != null
                     then ($user.uuid // $cfg.password) else $cfg.password end)),
                username: ($user.username //
                    (if $proto == "socks" or $proto == "naive" then $user.name else $cfg.username end)),
                user_name: $user.name
            } | del(.users)
        else . end
    '
}

gen_v2ray_sub() {
    local installed=$(get_installed_protocols)
    local links=""
    local ipv4 ipv6
    IFS='|' read -r ipv4 ipv6 <<< "$(get_connection_addresses)"

    # 获取地区代码
    local country_code=$(get_ip_country "$ipv4")
    [[ -z "$country_code" ]] && country_code=$(get_ip_country "$ipv6")

    # 确定使用的 IP 地址：优先 IPv4，纯 IPv6 环境使用 IPv6（带方括号）
    local server_ip="$ipv4"
    if [[ -z "$server_ip" && -n "$ipv6" ]]; then
        server_ip="[$ipv6]"
    fi

    for protocol in $installed; do
        local core cfg_stream
        core=$(protocol_subscription_db_core "$protocol")
        cfg_stream=$(db_subscription_configs "$core" "$protocol") || continue
        [[ -z "$cfg_stream" ]] && continue

        while IFS= read -r cfg; do
            [[ -z "$cfg" ]] && continue

            # 提取字段
            local uuid=$(echo "$cfg" | jq -r '.uuid // empty')
            local port=$(echo "$cfg" | jq -r '.port // empty')
            local sni=$(echo "$cfg" | jq -r '.sni // empty')
            local short_id=$(echo "$cfg" | jq -r '.short_id // empty')
            local public_key=$(echo "$cfg" | jq -r '.public_key // empty')
            local password=$(echo "$cfg" | jq -r '.password // empty')
            local username=$(echo "$cfg" | jq -r '.username // empty')
            local method=$(echo "$cfg" | jq -r '.method // empty')
            local psk=$(echo "$cfg" | jq -r '.psk // empty')

            # 分享链接使用实例端口。
            local actual_port="$port"

            local link=""
            case "$protocol" in
                vless-singbox)
                    local security_mode=$(echo "$cfg" | jq -r '.security_mode // "reality"')
                    if [[ "$security_mode" == "encryption" ]]; then
                        _err "Sing-box 不支持 VLESS encryption 模式" >&2; return 1
                    else
                        [[ -n "$server_ip" ]] && link=$(gen_vless_link "$server_ip" "$actual_port" "$uuid" "$public_key" "$short_id" "$sni" "$country_code")
                    fi
                    ;;
                naive)
                    local domain=$(jq -r '.domain // .sni // ""' <<< "$cfg")
                    link=$(gen_naive_link "$domain" "$actual_port" "$username" "$password" "$country_code")
                    ;;
                snell-v6)
                    link=$(gen_snell_link "$server_ip" "$actual_port" "$psk" 6 "$country_code" "$(jq -r '.mode // "default"' <<< "$cfg")" official)
                    ;;
                snell-v6-singbox)
                    link=$(gen_snell_link "$server_ip" "$actual_port" "$psk" 6 "$country_code" "$(jq -r '.mode // "default"' <<< "$cfg")" singbox)
                    ;;
                ss2022)
                    [[ -n "$server_ip" ]] && link=$(gen_ss2022_link "$server_ip" "$actual_port" "$method" "$password" "$country_code")
                    ;;
                ss-legacy)
                    [[ -n "$server_ip" ]] && link=$(gen_ss_legacy_link "$server_ip" "$actual_port" "$method" "$password" "$country_code")
                    ;;
                hy2)
                    [[ -n "$server_ip" ]] && link=$(gen_hy2_link "$server_ip" "$actual_port" "$password" "$sni" "$country_code")
                    ;;
                tuic)
                    [[ -n "$server_ip" ]] && link=$(gen_tuic_link "$server_ip" "$actual_port" "$uuid" "$password" "$sni" "$country_code")
                    ;;
                anytls)
                    [[ -n "$server_ip" ]] && link=$(gen_anytls_link "$server_ip" "$actual_port" "$password" "$sni" "$country_code")
                    ;;
                snell-v5|snell-v5-official)
                    [[ -n "$server_ip" ]] && link=$(gen_snell_v5_link "$server_ip" "$actual_port" "$psk" "5" "$country_code")
                    ;;
                socks)
                    [[ -n "$server_ip" ]] && link=$(gen_socks_link "$server_ip" "$actual_port" "$username" "$password" "$country_code")
                    ;;
            esac

            [[ -n "$link" ]] && links+="$link"$'\n'
        done <<< "$cfg_stream"
    done

    # 合并外部节点
    local external_links=$(get_all_external_links)
    [[ -n "$external_links" ]] && links+="$external_links"

    # Base64 编码
    printf '%s' "$links" | base64 -w 0 2>/dev/null || printf '%s' "$links" | base64
}

# 生成 Clash 订阅内容
gen_clash_sub() {
    local installed=$(get_installed_protocols)
    local ipv4 ipv6
    IFS='|' read -r ipv4 ipv6 <<< "$(get_connection_addresses)"
    local proxies=""
    local proxy_names=""

    # 获取地区代码和IP后缀
    local country_code=$(get_ip_country "$ipv4")
    [[ -z "$country_code" ]] && country_code=$(get_ip_country "$ipv6")

    # 确定使用的 IP 地址：优先 IPv4，纯 IPv6 环境使用 IPv6
    local server_ip="$ipv4"
    local ip_suffix="${ipv4##*.}"
    if [[ -z "$server_ip" && -n "$ipv6" ]]; then
        server_ip="$ipv6"
        ip_suffix=$(get_ip_suffix "$ipv6")
    fi

    for protocol in $installed; do
        local core cfg_stream
        core=$(protocol_subscription_db_core "$protocol")
        cfg_stream=$(db_subscription_configs "$core" "$protocol") || continue
        [[ -z "$cfg_stream" ]] && continue

        while IFS= read -r cfg; do
            [[ -z "$cfg" ]] && continue

            # 提取字段
            local uuid=$(echo "$cfg" | jq -r '.uuid // empty')
            local port=$(echo "$cfg" | jq -r '.port // empty')
            local sni=$(echo "$cfg" | jq -r '.sni // empty')
            local short_id=$(echo "$cfg" | jq -r '.short_id // empty')
            local public_key=$(echo "$cfg" | jq -r '.public_key // empty')
            local password=$(echo "$cfg" | jq -r '.password // empty')
            local username=$(echo "$cfg" | jq -r '.username // empty')
            local method=$(echo "$cfg" | jq -r '.method // empty')
            local psk=$(echo "$cfg" | jq -r '.psk // empty')

            # 分享配置使用实例端口。
            local actual_port="$port"

            local name="${country_code}-$(get_protocol_name $protocol)-${ip_suffix}"
            local user_name=$(jq -r '.user_name // ""' <<< "$cfg")
            [[ -z "$user_name" ]] || name="${name}-${port}-${user_name}"
            local proxy=""

            case "$protocol" in
            vless-singbox)
                [[ -n "$server_ip" ]] && proxy="  - name: \"$name\"
    type: vless
    server: \"$server_ip\"
    port: $actual_port
    uuid: $uuid
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $sni
    reality-opts:
      public-key: $public_key
      short-id: $short_id
    client-fingerprint: chrome"
                ;;
            ss2022)
                [[ -n "$server_ip" ]] && proxy="  - name: \"$name\"
    type: ss
    server: \"$server_ip\"
    port: $port
    cipher: $method
    password: $password
    udp: true"
                ;;
            ss-legacy)
                [[ -n "$server_ip" ]] && proxy="  - name: \"$name\"
    type: ss
    server: \"$server_ip\"
    port: $port
    cipher: $method
    password: $password
    udp: true"
                ;;
            hy2)
                [[ -n "$server_ip" ]] && proxy="  - name: \"$name\"
    type: hysteria2
    server: \"$server_ip\"
    port: $port
    password: $password
    sni: $sni
    skip-cert-verify: true"
                ;;
            tuic)
                [[ -n "$server_ip" ]] && proxy="  - name: \"$name\"
    type: tuic
    server: \"$server_ip\"
    port: $port
    uuid: $uuid
    password: $password
    alpn: [h3]
    udp-relay-mode: native
    congestion-controller: bbr
    sni: $sni
    skip-cert-verify: true"
                ;;
            anytls)
                [[ -n "$server_ip" ]] && proxy="  - name: \"$name\"
    type: anytls
    server: \"$server_ip\"
    port: $port
    password: $password
    sni: $sni
    skip-cert-verify: true"
                ;;
            esac

            if [[ -n "$proxy" ]]; then
                proxies+="$proxy"$'\n'
                proxy_names+="      - \"$name\""$'\n'
            fi
        done <<< "$cfg_stream"
    done

    # 合并外部节点
    local external_links=$(get_all_external_links)
    while IFS= read -r link || [[ -n "$link" ]]; do
        [[ -z "$link" || "$link" != *"://"* ]] && continue
        local ext_proxy=$(external_link_to_clash "$link")
        if [[ -n "$ext_proxy" ]]; then
            proxies+="$ext_proxy"$'\n'
            # 从生成的 proxy 中提取名称
            local ext_name=$(echo "$ext_proxy" | grep -m1 'name:' | sed 's/.*name:[[:space:]]*"\([^"]*\)".*/\1/')
            proxy_names+="      - \"$ext_name\""$'\n'
        fi
    done <<< "$external_links"

    # 生成完整 Clash 配置
    cat << EOF
mixed-port: 7897
allow-lan: false
mode: rule
log-level: info

proxies:
$proxies
proxy-groups:
  - name: "Proxy"
    type: select
    proxies:
$proxy_names
rules:
  - GEOIP,CN,DIRECT
  - MATCH,Proxy
EOF
}

# 生成 Surge 订阅内容
gen_surge_sub() {
    local installed=$(get_installed_protocols)
    local ipv4 ipv6
    IFS='|' read -r ipv4 ipv6 <<< "$(get_connection_addresses)"
    local proxies=""
    local proxy_names=""

    # 获取地区代码
    local country_code=$(get_ip_country "$ipv4")
    [[ -z "$country_code" ]] && country_code=$(get_ip_country "$ipv6")

    # 确定使用的 IP 地址：优先 IPv4，纯 IPv6 环境使用 IPv6
    local server_ip="$ipv4"
    local ip_suffix="${ipv4##*.}"
    if [[ -z "$server_ip" && -n "$ipv6" ]]; then
        server_ip="[$ipv6]"
        ip_suffix=$(get_ip_suffix "$ipv6")
    fi

    for protocol in $installed; do
        # 使用统一记录流读取单端口和多端口配置。
        local core cfg_stream
        core=$(protocol_subscription_db_core "$protocol")
        cfg_stream=$(db_subscription_configs "$core" "$protocol") || continue
        [[ -z "$cfg_stream" ]] && continue

        while IFS= read -r cfg; do
            [[ -z "$cfg" ]] && continue

            # 提取字段
            local uuid=$(echo "$cfg" | jq -r '.uuid // empty')
            local port=$(echo "$cfg" | jq -r '.port // empty')
            local sni=$(echo "$cfg" | jq -r '.sni // empty')
            local password=$(echo "$cfg" | jq -r '.password // empty')
            local method=$(echo "$cfg" | jq -r '.method // empty')
            local psk=$(echo "$cfg" | jq -r '.psk // empty')
            local version=$(echo "$cfg" | jq -r '.version // empty')
            local snell_mode=$(echo "$cfg" | jq -r '.mode // "default"')
            local snell_tfo=$(echo "$cfg" | jq -r 'if .tfo == null then "true" else .tfo | tostring end')
            local stls_password=$(echo "$cfg" | jq -r '.stls_password // empty')
            local name="${country_code}-$(get_protocol_name $protocol)-${ip_suffix}"
            case "$protocol" in
                snell-v5|snell-v5-official) name="${country_code}-Snell-v5-${port}" ;;
                snell-v6) name="${country_code}-Snell-v6-official-${port}" ;;
                snell-v6-singbox) name="${country_code}-Snell-v6-singbox-${port}" ;;
            esac
            local user_name=$(jq -r '.user_name // ""' <<< "$cfg")
            [[ -z "$user_name" ]] || name="${name}-${port}-${user_name}"
            local proxy=""

            case "$protocol" in
                ss2022-shadowtls)
                    proxy="$name = ss, $server_ip, $port, encrypt-method=$method, password=$password, shadow-tls-password=$stls_password, shadow-tls-sni=$sni, shadow-tls-version=3"
                    ;;
                socks)
                    proxy="$name = socks5, $server_ip, $port, username=$(jq -r '.username // ""' <<< "$cfg"), password=$password"
                    ;;
                ss2022)
                    [[ -n "$server_ip" ]] && proxy="$name = ss, $server_ip, $port, encrypt-method=$method, password=$password"
                    ;;
                ss-legacy)
                    [[ -n "$server_ip" ]] && proxy="$name = ss, $server_ip, $port, encrypt-method=$method, password=$password"
                    ;;
                hy2)
                    [[ -n "$server_ip" ]] && proxy="$name = hysteria2, $server_ip, $port, password=$password, sni=$sni, skip-cert-verify=true"
                    ;;
                tuic)
                    [[ -n "$server_ip" ]] && proxy="$name = tuic, $server_ip, $port, uuid=$uuid, password=$password, sni=$sni, skip-cert-verify=true, alpn=h3"
                    ;;
                anytls)
                    [[ -n "$server_ip" ]] && proxy="$name = anytls, $server_ip, $port, password=$password, sni=$sni, skip-cert-verify=true"
                    ;;
                snell-v5|snell-v5-official)
                    [[ -n "$server_ip" ]] && proxy=$(gen_snell_surge_line "$name" "$server_ip" "$port" "$psk" "${version:-5}" "${snell_mode:-default}" "${snell_tfo:-true}" "$stls_password" "$sni")
                    ;;
                snell-v6|snell-v6-singbox)
                    # Snell v6 服务端与 Surge 客户端的 mode 必须完全一致。
                    [[ -n "$server_ip" ]] && proxy=$(gen_snell_surge_line "$name" "$server_ip" "$port" "$psk" "${version:-6}" "${snell_mode:-default}" "${snell_tfo:-true}")
                    ;;
            esac

            if [[ -n "$proxy" ]]; then
                proxies+="$proxy"$'\n'
                [[ -n "$proxy_names" ]] && proxy_names+=", "
                proxy_names+="$name"
            fi
        done <<< "$cfg_stream"
    done

    # 合并外部节点 (仅支持 vmess/trojan/ss/hysteria2)
    local external_links=$(get_all_external_links)
    while IFS= read -r link || [[ -n "$link" ]]; do
        [[ -z "$link" || "$link" != *"://"* ]] && continue
        local ext_proxy=$(external_link_to_surge "$link")
        if [[ -n "$ext_proxy" ]]; then
            proxies+="$ext_proxy"$'\n'
            # 从生成的 proxy 中提取名称
            local ext_name=$(echo "$ext_proxy" | cut -d'=' -f1 | xargs)
            [[ -n "$proxy_names" ]] && proxy_names+=", "
            proxy_names+="$ext_name"
        fi
    done <<< "$external_links"

    cat << EOF
[General]
loglevel = notify

[Proxy]
$proxies
[Proxy Group]
Proxy = select, $proxy_names

[Rule]
GEOIP,CN,DIRECT
FINAL,Proxy
EOF
}

# 生成订阅文件
generate_sub_files() {
    local sub_uuid=$(get_sub_uuid)
    local sub_dir="$CFG/subscription/$sub_uuid"
    mkdir -p "$sub_dir"
    chmod 711 "$CFG" "$CFG/subscription" "$sub_dir"

    _info "生成订阅文件..."

    # V2Ray/通用订阅
    gen_v2ray_sub > "$sub_dir/base64"

    # Clash 订阅
    gen_clash_sub > "$sub_dir/clash.yaml"

    # Surge 订阅
    gen_surge_sub > "$sub_dir/surge.conf"

    chmod 644 "$sub_dir"/*
    _ok "订阅文件已生成"
}

# 配置 Nginx 订阅服务
setup_nginx_sub() {
    local sub_uuid=$(get_sub_uuid)
    local sub_port="${1:-8443}" domain="${2:-}" use_https="${3:-true}"

    generate_sub_files
    local sub_dir="$CFG/subscription/$sub_uuid"
    local fake_conf="/etc/nginx/conf.d/sing-fake.conf"
    [[ -d "/etc/nginx/http.d" ]] && fake_conf="/etc/nginx/http.d/sing-fake.conf"

    # 检查现有配置：已存在且路由正确则直接复用
    if [[ -f "$fake_conf" ]] &&
       grep -q "listen.*$sub_port" "$fake_conf" 2>/dev/null &&
       grep -q "location.*sub.*alias.*subscription" "$fake_conf" 2>/dev/null; then
        _ok "Nginx 已配置订阅服务: 端口 $sub_port"
        return 0
    fi

    local cert_file="$CFG/certs/server.crt" key_file="$CFG/certs/server.key"
    # 根据系统选择正确的 nginx 配置目录
    local nginx_conf_dir="/etc/nginx/conf.d"
    [[ -d "/etc/nginx/http.d" ]] && nginx_conf_dir="/etc/nginx/http.d"
    local nginx_conf="$nginx_conf_dir/sing-sub.conf"
    rm -f "$nginx_conf" 2>/dev/null
    mkdir -p "$nginx_conf_dir"

    if [[ "$use_https" == "true" && ( ! -f "$cert_file" || ! -f "$key_file" ) ]]; then
        _warn "证书不存在，生成自签名证书..."
        gen_self_cert "${domain:-localhost}"
    fi
    if [[ "$use_https" == "true" && ( ! -f "$cert_file" || ! -f "$key_file" ) ]]; then
        _warn "证书仍不存在，切换到 HTTP 模式..."
        use_https="false"
    fi

    local ssl_listen="" ssl_block=""
    if [[ "$use_https" == "true" ]]; then
        ssl_listen=" ssl http2"
        ssl_block=$(cat <<EOF
    ssl_certificate $cert_file;
    ssl_certificate_key $key_file;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
EOF
)
    fi

    cat > "$nginx_conf" << EOF
server {
    listen $sub_port$ssl_listen;
    listen [::]:$sub_port$ssl_listen;
    server_name ${domain:-_};
$ssl_block
    # 订阅路径 (alias 直指文件，避免 try_files 误判)
    location /sub/$sub_uuid/ {
        alias $sub_dir/;
        default_type text/plain;
        add_header Content-Type 'text/plain; charset=utf-8';
    }

    location /sub/$sub_uuid/clash {
        alias $sub_dir/clash.yaml;
        default_type text/yaml;
        add_header Content-Disposition 'attachment; filename="clash.yaml"';
    }

    location /sub/$sub_uuid/surge {
        alias $sub_dir/surge.conf;
        default_type text/plain;
        add_header Content-Disposition 'attachment; filename="surge.conf"';
    }

    location /sub/$sub_uuid/v2ray {
        alias $sub_dir/base64;
        default_type text/plain;
    }

    # 伪装网页
    root /var/www/html;
    index index.html;

    location / { try_files \$uri \$uri/ =404; }

    # 隐藏 Nginx 版本
    server_tokens off;
}
EOF

    if nginx -t 2>/dev/null; then
        if [[ "$DISTRO" == "alpine" ]]; then
            rc-service nginx restart 2>/dev/null || nginx -s reload
        else
            systemctl reload nginx 2>/dev/null || nginx -s reload
        fi
        _ok "Nginx 配置完成"
        return 0
    fi

    _err "Nginx 配置错误"
    rm -f "$nginx_conf"
    return 1
}


# 显示订阅链接
show_sub_links() {
    [[ ! -f "$CFG/sub.info" ]] && { _warn "订阅服务未配置"; return; }

    # 清除变量避免污染
    local sub_uuid="" sub_port="" sub_domain="" sub_https=""
    _load_sub_info "$CFG/sub.info" || { _err "订阅配置格式无效"; return 1; }
    local ipv4 ipv6
    IFS='|' read -r ipv4 ipv6 <<< "$(get_connection_addresses)"
    local protocol="http"
    [[ "$sub_https" == "true" ]] && protocol="https"

    local sub_host="$sub_domain"
    if [[ -z "$sub_host" && -n "$ipv4" ]]; then
        sub_host="$ipv4"
    elif [[ -z "$sub_host" && -n "$ipv6" ]]; then
        sub_host="[$ipv6]"
    fi
    [[ -z "$sub_host" ]] && sub_host="请填写服务器地址"
    local base_url="${protocol}://${sub_host}:${sub_port}/sub/${sub_uuid}"

    _line
    echo -e "  ${W}订阅链接${NC}"
    _line
    echo -e "  ${Y}Clash/Clash Verge (推荐):${NC}"
    echo -e "  ${G}${base_url}/clash${NC}"
    _show_link_qr "${base_url}/clash"
    echo ""
    echo -e "  ${Y}Surge:${NC}"
    echo -e "  ${G}${base_url}/surge${NC}"
    _show_link_qr "${base_url}/surge"
    echo ""
    echo -e "  ${Y}V2Ray/Loon/通用:${NC}"
    echo -e "  ${G}${base_url}/v2ray${NC}"
    _show_link_qr "${base_url}/v2ray"
    _line
    echo -e "  ${D}订阅路径包含随机UUID，请妥善保管${NC}"

    # HTTPS 自签名证书提示
    if [[ "$sub_https" == "true" && -z "$sub_domain" ]]; then
        echo -e "  ${Y}提示: 使用自签名证书，部分客户端可能无法解析订阅${NC}"
        echo -e "  ${D}建议使用 HTTP 或绑定真实域名申请证书${NC}"
    fi
}

# 订阅服务管理菜单
manage_subscription() {
    while true; do
        _header
        echo -e "  ${W}订阅服务管理${NC}"
        _line

        if [[ -f "$CFG/sub.info" ]]; then
            # 清除变量避免污染
            local sub_uuid="" sub_port="" sub_domain="" sub_https=""
            _load_sub_info "$CFG/sub.info" || { _warn "订阅配置格式无效"; return 1; }
            echo -e "  状态: ${G}已配置${NC}"
            echo -e "  端口: ${G}$sub_port${NC}"
            [[ -n "$sub_domain" ]] && echo -e "  域名: ${G}$sub_domain${NC}"
            echo -e "  HTTPS: ${G}$sub_https${NC}"
            echo ""
            _item "1" "查看订阅链接"
            _item "2" "更新订阅内容"
            _item "3" "外部节点管理"
            _item "4" "重新配置"
            _item "5" "停用订阅服务"
        else
            echo -e "  状态: ${D}未配置${NC}"
            echo ""
            _item "1" "启用订阅服务"
            _item "2" "外部节点管理"
        fi
        _item "0" "返回"
        _line

        read -rp "  请选择: " choice

        if [[ -f "$CFG/sub.info" ]]; then
            case $choice in
                1) show_sub_links; _pause ;;
                2) generate_sub_files; _ok "订阅内容已更新"; _pause ;;
                3) manage_external_nodes ;;
                4) setup_subscription_interactive ;;
                5)
                    # 获取订阅端口和域名信息
                    local sub_port="" sub_domain=""
                    if [[ -f "$CFG/sub.info" ]]; then
                        _load_sub_info "$CFG/sub.info" || { _warn "订阅配置格式无效"; return 1; }
                    fi

                    # 删除配置文件
                    rm -f /etc/nginx/conf.d/sing-sub.conf /etc/nginx/http.d/sing-sub.conf "$CFG/sub.info"
                    rm -rf "$CFG/subscription"

                    # 清理 hosts 记录
                    if [[ -n "$sub_domain" ]]; then
                        sed -i "/127.0.0.1 $sub_domain/d" /etc/hosts 2>/dev/null
                        _info "已清理 /etc/hosts 中的域名记录"
                    fi

                    # 检查是否还有其他 nginx 配置，如果没有则停止 nginx
                    local other_configs=$(ls /etc/nginx/conf.d/*.conf /etc/nginx/http.d/*.conf 2>/dev/null | wc -l)
                    if [[ "$other_configs" -eq 0 ]]; then
                        _info "没有其他 Nginx 配置，停止 Nginx 服务..."
                        if [[ "$DISTRO" == "alpine" ]]; then
                            rc-service nginx stop 2>/dev/null
                        else
                            systemctl stop nginx 2>/dev/null
                        fi
                        _ok "Nginx 服务已停止"
                    else
                        _info "检测到其他 Nginx 配置，仅重载配置..."
                        nginx -s reload 2>/dev/null
                    fi

                    _ok "订阅服务已停用"
                    _pause
                    ;;
                0) return ;;
            esac
        else
            case $choice in
                1) setup_subscription_interactive ;;
                2) manage_external_nodes ;;
                0) return ;;
            esac
        fi
    done
}

# 交互式配置订阅
setup_subscription_interactive() {
    _header
    echo -e "  ${W}配置订阅服务${NC}"
    _line

    # 询问是否重新生成 UUID
    if [[ -f "$CFG/sub_uuid" ]]; then
        echo -e "  ${Y}检测到已有订阅 UUID${NC}"
        read -rp "  是否重新生成 UUID? [y/N]: " regen_uuid
        if [[ "$regen_uuid" =~ ^[yY]$ ]]; then
            local old_uuid=$(cat "$CFG/sub_uuid")
            reset_sub_uuid
            local new_uuid=$(cat "$CFG/sub_uuid")
            _ok "UUID 已更新: ${old_uuid:0:8}... → ${new_uuid:0:8}..."
            # 清理旧的订阅目录
            rm -rf "$CFG/subscription/$old_uuid" 2>/dev/null
        fi
        echo ""
    fi

    # 安装 Nginx
    if ! check_cmd nginx; then
        _info "需要安装 Nginx..."
        install_nginx || { _err "Nginx 安装失败"; _pause; return; }
    fi

    # 端口（带冲突检测）
    local default_port=18443
    local sub_port=""

    while true; do
        read -rp "  订阅端口 [$default_port]: " sub_port
        sub_port="${sub_port:-$default_port}"

        if ! _is_valid_port "$sub_port"; then
            _err "端口必须是 1-65535 的整数"
            continue
        fi

        # 检查是否被已安装协议占用
        local conflict_proto=$(is_internal_port_occupied "$sub_port")
        if [[ -n "$conflict_proto" ]]; then
            _err "端口 $sub_port 已被 [$conflict_proto] 协议占用"
            _warn "请选择其他端口"
            continue
        fi

        # 检查系统端口占用
        if ss -tuln 2>/dev/null | grep -q ":$sub_port " || netstat -tuln 2>/dev/null | grep -q ":$sub_port "; then
            _warn "端口 $sub_port 已被系统占用"
            read -rp "  是否强制使用? [y/N]: " force
            [[ "$force" =~ ^[yY]$ ]] && break
            continue
        fi

        break
    done

    # 域名
    echo -e "  ${D}留空使用服务器IP${NC}"
    while true; do
        read -rp "  域名 (可选): " sub_domain
        _is_valid_domain_or_ip "$sub_domain" && break
        _err "域名或 IP 格式无效"
    done

    # HTTPS
    local use_https="true"
    read -rp "  启用 HTTPS? [Y/n]: " https_choice
    [[ "$https_choice" =~ ^[nN]$ ]] && use_https="false"

    # 生成订阅文件
    generate_sub_files

    # 获取订阅 UUID
    local sub_uuid=$(get_sub_uuid)
    local sub_dir="$CFG/subscription/$sub_uuid"
    local connection_ipv4 connection_ipv6
    IFS='|' read -r connection_ipv4 connection_ipv6 <<< "$(get_connection_addresses)"
    local server_name="$sub_domain"
    [[ -z "$server_name" ]] && server_name="${connection_ipv4:-$connection_ipv6}"
    [[ -z "$server_name" ]] && server_name="localhost"

    # 配置 Nginx - 根据系统选择正确的配置目录
    local nginx_conf_dir="/etc/nginx/conf.d"
    [[ -d "/etc/nginx/http.d" ]] && nginx_conf_dir="/etc/nginx/http.d"
    local nginx_conf="$nginx_conf_dir/sing-sub.conf"
    mkdir -p "$nginx_conf_dir"

    # 删除可能冲突的旧配置 (包括 http.d 目录)
    rm -f /etc/nginx/conf.d/sing-fake.conf /etc/nginx/http.d/sing-fake.conf 2>/dev/null
    rm -f /etc/nginx/sites-enabled/sing-fake 2>/dev/null

    if [[ "$use_https" == "true" ]]; then
        # HTTPS 模式：需要证书
        local cert_file="$CFG/certs/server.crt"
        local key_file="$CFG/certs/server.key"

        # 检查证书是否存在，不存在则生成自签名证书
        if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
            _info "生成自签名证书..."
            mkdir -p "$CFG/certs"
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                -keyout "$key_file" -out "$cert_file" \
                -subj "/CN=$server_name" 2>/dev/null
        fi

        cat > "$nginx_conf" << EOF
server {
    listen $sub_port ssl http2;
    listen [::]:$sub_port ssl http2;
    server_name $server_name;

    ssl_certificate $cert_file;
    ssl_certificate_key $key_file;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root /var/www/html;
    index index.html;

    # 订阅路径
    location ~ ^/sub/([a-f0-9-]+)/v2ray\$ {
        alias $CFG/subscription/\$1/base64;
        default_type text/plain;
        add_header Content-Type "text/plain; charset=utf-8";
    }

    location ~ ^/sub/([a-f0-9-]+)/clash\$ {
        alias $CFG/subscription/\$1/clash.yaml;
        default_type text/yaml;
    }

    location ~ ^/sub/([a-f0-9-]+)/surge\$ {
        alias $CFG/subscription/\$1/surge.conf;
        default_type text/plain;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }

    server_tokens off;
}
EOF
    else
        # HTTP 模式
        cat > "$nginx_conf" << EOF
server {
    listen $sub_port;
    listen [::]:$sub_port;
    server_name $server_name;

    root /var/www/html;
    index index.html;

    # 订阅路径
    location ~ ^/sub/([a-f0-9-]+)/v2ray\$ {
        alias $CFG/subscription/\$1/base64;
        default_type text/plain;
        add_header Content-Type "text/plain; charset=utf-8";
    }

    location ~ ^/sub/([a-f0-9-]+)/clash\$ {
        alias $CFG/subscription/\$1/clash.yaml;
        default_type text/yaml;
    }

    location ~ ^/sub/([a-f0-9-]+)/surge\$ {
        alias $CFG/subscription/\$1/surge.conf;
        default_type text/plain;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }

    server_tokens off;
}
EOF
    fi

    # 确保伪装网页存在
    mkdir -p /var/www/html
    if [[ ! -f "/var/www/html/index.html" ]]; then
        cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 20px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 40px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #333; text-align: center; }
        p { color: #666; line-height: 1.6; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome to Our Website</h1>
        <p>This is a simple website hosted on our server.</p>
    </div>
</body>
</html>
HTMLEOF
        : >"$CFG/.managed_web_index"
    fi

    # 保存订阅配置
    if ! _write_sub_info "$sub_uuid" "$sub_port" "$sub_domain" "$use_https"; then
        _err "订阅配置参数无效，拒绝写入"
        rm -f "$nginx_conf"
        return 1
    fi

    # 添加域名到 hosts（解决部分 VPS 环境下的本地回环问题）
    if [[ -n "$sub_domain" ]]; then
        if ! grep -q "127.0.0.1 $sub_domain" /etc/hosts 2>/dev/null; then
            echo "127.0.0.1 $sub_domain" >> /etc/hosts
            _info "已添加域名到 /etc/hosts（优化本地访问）"
        fi
    fi

    # 测试并重载 Nginx
    if nginx -t 2>/dev/null; then
        if [[ "$DISTRO" == "alpine" ]]; then
            rc-update add nginx default 2>/dev/null
            rc-service nginx restart 2>/dev/null
        else
            systemctl enable nginx 2>/dev/null
            systemctl restart nginx 2>/dev/null
        fi
        _ok "订阅服务已配置"
    else
        _err "Nginx 配置错误"
        nginx -t
        rm -f "$nginx_conf"
        _pause
        return
    fi

    echo ""
    show_sub_links
    _pause
}

#═══════════════════════════════════════════════════════════════════════════════
# 日志查看
#═══════════════════════════════════════════════════════════════════════════════

show_logs() {
    _header
    echo -e "  ${W}运行日志${NC}"
    _line

    echo -e "  ${G}1${NC}) 查看脚本日志 (最近 50 行)"
    echo -e "  ${G}2${NC}) 查看 Watchdog 日志 (最近 50 行)"
    echo -e "  ${G}3${NC}) 查看服务日志 (按协议选择)"
    echo -e "  ${G}4${NC}) 实时跟踪脚本日志"
    echo -e "  ${G}0${NC}) 返回"
    _line

    read -rp "  请选择: " log_choice

    case $log_choice in
        1)
            _line
            echo -e "  ${C}脚本日志 ($LOG_FILE):${NC}"
            _line
            if [[ -f "$LOG_FILE" ]]; then
                tail -n 50 "$LOG_FILE"
            else
                _warn "日志文件不存在"
            fi
            _pause
            ;;
        2)
            _line
            echo -e "  ${C}Watchdog 日志:${NC}"
            _line
            if [[ -f "/var/log/sing-watchdog.log" ]]; then
                tail -n 50 /var/log/sing-watchdog.log
            else
                _warn "Watchdog 日志文件不存在"
            fi
            _pause
            ;;
        3)
            show_service_logs
            ;;
        4)
            _line
            echo -e "  ${C}实时跟踪日志 (Ctrl+C 退出):${NC}"
            _line
            if [[ -f "$LOG_FILE" ]]; then
                tail -f "$LOG_FILE"
            else
                _warn "日志文件不存在"
            fi
            ;;
        0|"")
            return
            ;;
        *)
            _err "无效选择"
            ;;
    esac
}

# 按协议查看服务日志
show_service_logs() {
    local protocol service choice i=0 seen=' '
    local -a services=()
    for protocol in $(get_installed_protocols); do
        service="${PROTO_SVC[$protocol]:-}"
        [[ -n "$service" && "$seen" != *" $service "* ]] || continue
        seen+="$service "; services+=("$service"); i=$((i+1))
        _item "$i" "$service"
    done
    ((i > 0)) || { _warn '未安装任何协议'; return; }
    _item 0 返回
    read -rp '  请选择: ' choice || return
    [[ "$choice" != 0 ]] || return
    [[ "$choice" =~ ^[1-9][0-9]*$ ]] && ((choice <= i)) || return 1
    service="${services[choice-1]}"
    if [[ "$DISTRO" == alpine ]]; then
        if [[ -r "/var/log/$service.log" ]]; then tail -n 50 "/var/log/$service.log"
        elif [[ -r /var/log/messages ]]; then grep -F "$service" /var/log/messages | tail -n 50
        else _warn '系统日志不可用'; fi
    else journalctl -u "$service" --no-pager -n 50; fi
    _pause
}
_select_protocol_for_users() {
    local protocols=$(db_get_all_protocols)
    [[ -z "$protocols" ]] && { _err "没有已安装的协议"; return 1; }

    echo ""
    _line
    echo -e "  ${W}选择协议${NC}"
    _line

    local i=1
    local proto_array=()
    while IFS= read -r proto; do
        [[ -z "$proto" ]] && continue
        { is_standalone_protocol "$proto" || is_singbox_snell_protocol "$proto"; } && continue
        local core="singbox"
        db_exists "singbox" "$proto" && core="singbox"
        local user_count=$(db_count_users "$core" "$proto")
        local proto_name=$(get_protocol_name "$proto")
        _item "$i" "$proto_name ${D}($user_count 用户)${NC}"
        proto_array+=("$core:$proto")
        ((i++))
    done <<< "$protocols"

    _item "0" "返回"
    _line

    [[ ${#proto_array[@]} -gt 0 ]] || { _err "没有支持用户管理的协议 (Snell v6 使用每端口固定 PSK)"; return 1; }
    local max=$((i-1))
    while true; do
        read -rp "  请选择 [0-$max]: " choice
        [[ "$choice" == "0" ]] && return 1
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$max" ]]; then
            SELECTED_CORE="${proto_array[$((choice-1))]%%:*}"
            SELECTED_PROTO="${proto_array[$((choice-1))]#*:}"
            return 0
        fi
        _err "无效选择"
    done
}

# 显示用户列表
_show_users_list() {
    local core="$1" proto="$2" name enabled expire
    printf '  %-20s %-10s %s\n' 用户名 状态 到期日期
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        enabled=$(db_get_user_field "$core" "$proto" "$name" enabled)
        expire=$(db_get_user_expire_date "$core" "$proto" "$name")
        [[ "$enabled" == false ]] && enabled=已禁用 || enabled=已启用
        printf '  %-20s %-10s %s\n' "$name" "$enabled" "${expire:-永不过期}"
    done < <(db_list_users "$core" "$proto")
}

# 生成用户的分享链接（根据协议类型）
_gen_user_share_link() {
    local core="$1" proto="$2" uuid="$3" user_name="$4"

    # 获取协议配置
    local cfg=$(db_get "$core" "$proto")
    [[ -z "$cfg" || "$cfg" == "null" ]] && return

    # 检查是否为多端口数组格式
    local is_array=false
    if echo "$cfg" | jq -e 'type == "array"' >/dev/null 2>&1; then
        is_array=true
        # 多端口：从第一个端口实例获取配置
        cfg=$(echo "$cfg" | jq '.[0]')
    fi

    # 提取配置字段
    local port=$(echo "$cfg" | jq -r '.port // empty')
    local sni=$(echo "$cfg" | jq -r '.sni // empty')
    local short_id=$(echo "$cfg" | jq -r '.short_id // empty')
    local public_key=$(echo "$cfg" | jq -r '.public_key // empty')
    local method=$(echo "$cfg" | jq -r '.method // empty')
    local domain=$(echo "$cfg" | jq -r '.domain // empty')

    # 获取 IP 地址
    local ipv4 ipv6
    IFS='|' read -r ipv4 ipv6 <<< "$(get_connection_addresses)"
    local country_code=$(get_ip_country "$ipv4")
    [[ -z "$country_code" ]] && country_code=$(get_ip_country "$ipv6")

    # 用户分享链接使用实例端口。
    local display_port="$port"

    local remark="${country_code}-${user_name}"

    if [[ -z "$ipv4" && -n "$ipv6" ]]; then
        ipv4="[$ipv6]"
    fi

    # 生成 IPv4 链接
    if [[ -n "$ipv4" ]]; then
        local link=""
        case "$proto" in
            vless-singbox)
                local security_mode=$(echo "$cfg" | jq -r '.security_mode // "reality"')
                if [[ "$security_mode" == "encryption" ]]; then
                        _err "Sing-box 不支持 VLESS encryption 模式" >&2; return 1
                else
                    link=$(gen_vless_link "$ipv4" "$display_port" "$uuid" "$public_key" "$short_id" "$sni" "$remark")
                fi
                ;;
            ss2022) link=$(gen_ss2022_link "$ipv4" "$display_port" "$method" "$uuid" "$remark") ;;
            hy2) link=$(gen_hy2_link "$ipv4" "$display_port" "$uuid" "$sni" "$remark") ;;
            tuic)
                local password=$(echo "$cfg" | jq -r '.password // empty')
                link=$(gen_tuic_link "$ipv4" "$display_port" "$uuid" "$password" "$sni" "$remark")
                ;;
            socks) link=$(gen_socks_link "$ipv4" "$display_port" "$user_name" "$uuid" "$remark") ;;
        esac
        [[ -n "$link" ]] && echo "$link"
    fi
}

# 显示用户分享链接菜单
db_user_share_records() {
    local core="$1" proto="$2"
    jq -r --arg core "$core" --arg proto "$proto" '
        .[$core][$proto] | (if type == "array" then .[] else . end) | . as $cfg |
        if (.users // [] | length) > 0 then
            .users[] | [.name, (.uuid // .password // ""), (.enabled != false), $cfg.port, (.routing // "")] | join("|")
        else ["default", (.uuid // .password // .username // ""), true, .port, ""] | join("|") end
    ' "$DB_FILE"
}

_show_user_share_links() {
    local core="$1" proto="$2"
    local proto_name=$(get_protocol_name "$proto")

    while true; do
        _header
        echo -e "  ${W}$proto_name 用户分享链接${NC}"
        _dline

        local stats=$(db_user_share_records "$core" "$proto")
        if [[ -z "$stats" ]]; then
            echo -e "  ${D}暂无用户${NC}"
            _line
            _pause
            return
        fi

        # 显示用户列表
        local users=()
        local uuids=()
        local idx=1

        while IFS='|' read -r name uuid enabled port routing; do
            [[ -z "$name" ]] && continue
            users+=("$name")
            uuids+=("$uuid")
            echo -e "  ${G}$idx${NC}) $name"
            ((idx++))
        done <<< "$stats"

        _line
        echo -e "  ${D}输入序号查看详细配置/链接${NC}"
        _item "a" "一键展示所有用户分享链接"
        _item "0" "返回"
        _line

        read -rp "  请选择 [0-$((idx-1))/a]: " choice

        if [[ "$choice" == "0" ]]; then
            return
        elif [[ "$choice" == "a" || "$choice" == "A" ]]; then
            # 展示所有用户分享链接
            echo ""
            _dline
            echo -e "  ${W}$proto_name 所有用户分享链接${NC}"
            _dline

            for i in "${!users[@]}"; do
                local user="${users[$i]}"
                local uuid="${uuids[$i]}"
                echo -e "  ${Y}$user:${NC}"
                local link=$(_gen_user_share_link "$core" "$proto" "$uuid" "$user")
                [[ -n "$link" ]] && echo -e "  ${C}$link${NC}"
                echo ""
            done

            _line
            _pause
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#users[@]}" ]]; then
            # 显示单个用户链接
            local user="${users[$((choice-1))]}"
            local uuid="${uuids[$((choice-1))]}"

            echo ""
            _dline
            echo -e "  ${W}$user 分享链接${NC}"
            _dline

            local link=$(_gen_user_share_link "$core" "$proto" "$uuid" "$user")
            if [[ -n "$link" ]]; then
                echo -e "  ${C}$link${NC}"
                echo ""

                # 生成二维码（如果可用）
                if command -v qrencode &>/dev/null; then
                    echo -e "  ${D}二维码:${NC}"
                    qrencode -t ANSIUTF8 "$link" 2>/dev/null
                fi
            else
                echo -e "  ${D}无法生成链接${NC}"
            fi

            _line
            _pause
        else
            _err "无效选择"
        fi
    done
}

# 用户路由选择函数
# 用法: _select_user_routing [当前路由值]
# 设置全局变量 SELECTED_ROUTING 为选择的路由值
_select_user_routing() {
    local current_routing="${1:-}"
    SELECTED_ROUTING=""

    echo ""
    _line
    echo -e "  ${W}选择用户路由${NC}"
    echo -e "  ${D}用户级路由优先于全局分流规则${NC}"
    _line

    local idx=1
    local options=()

    # 选项1: 使用全局规则
    echo -e "  ${G}1${NC}) 使用全局规则 (默认)"
    options+=("")
    ((idx++))

    # 选项2: 直连
    echo -e "  ${G}$idx${NC}) 直连"
    options+=("direct")
    ((idx++))

    # 选项3: WARP (仅当已安装时显示)
    if warp_status &>/dev/null || [[ -f "/usr/local/bin/warp-go" ]] || command -v warp-cli &>/dev/null; then
        echo -e "  ${G}$idx${NC}) WARP 代理"
        options+=("warp")
        ((idx++))
    fi

    # 选项N: 链式代理节点
    if [[ -f "$DB_FILE" ]]; then
        local chain_nodes=$(jq -r '.chain_proxy.nodes[]?.name // empty' "$DB_FILE" 2>/dev/null)
        if [[ -n "$chain_nodes" ]]; then
            echo -e "  ${D}──链式代理节点──${NC}"
            while IFS= read -r node; do
                [[ -z "$node" ]] && continue
                echo -e "  ${G}$idx${NC}) 链路→$node"
                options+=("chain:$node")
                ((idx++))
            done <<< "$chain_nodes"
        fi
    fi

    # 选项M: 负载均衡组
    if [[ -f "$DB_FILE" ]]; then
        local balancers=$(jq -r '.balancer_groups[]?.name // empty' "$DB_FILE" 2>/dev/null)
        if [[ -n "$balancers" ]]; then
            echo -e "  ${D}──负载均衡组──${NC}"
            while IFS= read -r group; do
                [[ -z "$group" ]] && continue
                echo -e "  ${G}$idx${NC}) 负载→$group"
                options+=("balancer:$group")
                ((idx++))
            done <<< "$balancers"
        fi
    fi

    echo -e "  ${G}0${NC}) 取消"
    _line

    local max=$((idx-1))
    while true; do
        read -rp "  请选择 [0-$max]: " choice
        [[ "$choice" == "0" ]] && return 1

        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$max" ]]; then
            SELECTED_ROUTING="${options[$((choice-1))]}"

            # 如果选择 WARP 但未安装，提示安装
            if [[ "$SELECTED_ROUTING" == "warp" ]]; then
                if ! warp_status &>/dev/null && [[ ! -f "/usr/local/bin/warp-go" ]] && ! command -v warp-cli &>/dev/null; then
                    _warn "WARP 未安装"
                    read -rp "  是否现在安装 WARP? [Y/n]: " install_warp
                    if [[ ! "$install_warp" =~ ^[nN]$ ]]; then
                        install_warp_go
                        if ! warp_status &>/dev/null; then
                            _err "WARP 安装失败，请稍后重试"
                            return 1
                        fi
                    else
                        _err "已取消"
                        return 1
                    fi
                fi
            fi

            return 0
        fi
        _err "无效选择"
    done
}

# 修改用户路由
_set_user_routing() {
    local core="$1" proto="$2"
    local proto_name=$(get_protocol_name "$proto")

    local users=$(db_list_users "$core" "$proto")
    [[ -z "$users" ]] && { _err "没有用户"; return; }

    echo ""
    _line
    echo -e "  ${W}修改用户路由 - $proto_name${NC}"
    _line

    local i=1
    local user_array=()
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        local current_routing=$(db_get_user_routing "$core" "$proto" "$user")
        local routing_fmt=$(_format_user_routing "$current_routing")
        _item "$i" "$user ${D}(当前: $routing_fmt)${NC}"
        user_array+=("$user")
        ((i++))
    done <<< "$users"

    _item "0" "返回"
    _line

    local max=$((i-1))
    while true; do
        read -rp "  选择用户 [0-$max]: " choice
        [[ "$choice" == "0" ]] && return
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$max" ]]; then
            local name="${user_array[$((choice-1))]}"
            local current=$(db_get_user_routing "$core" "$proto" "$name")

            if _select_user_routing "$current"; then
                if db_set_user_routing "$core" "$proto" "$name" "$SELECTED_ROUTING"; then
                    local new_fmt=$(_format_user_routing "$SELECTED_ROUTING")
                    _ok "用户 $name 路由已设置为: $new_fmt"
                else
                    _err "设置失败"
                fi
            fi
            return
        fi
        _err "无效选择"
    done
}

# 添加用户
_add_user() {
    local core="$1" proto="$2"
    local proto_name=$(get_protocol_name "$proto")

    # 检查是否为独立协议（不支持多用户）
    if is_standalone_protocol "$proto" || is_singbox_snell_protocol "$proto"; then
        echo ""
        _err "$proto_name 为独立协议，不支持多用户管理"
        _info "该协议使用配置文件中的固定密钥，无需添加用户"
        return 1
    fi

    echo ""
    _line
    echo -e "  ${W}添加用户 - $proto_name${NC}"
    _line

    # 输入用户名
    local name
    while true; do
        read -rp "  用户名: " name
        [[ -z "$name" ]] && { _err "用户名不能为空"; continue; }
        [[ "$name" =~ [^a-zA-Z0-9_-] ]] && { _err "用户名只能包含字母、数字、下划线和横线"; continue; }

        # 检查是否已存在（精确匹配）
        local exists=$(db_get_user "$core" "$proto" "$name")
        [[ -n "$exists" ]] && { _err "用户 $name 已存在"; continue; }

        # 检查大小写冲突（用户名 不区分大小写）
        local name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
        local conflict=false
        local existing_users=$(db_list_users "$core" "$proto")
        if [[ -n "$existing_users" ]]; then
            while IFS= read -r existing_name; do
                [[ -z "$existing_name" ]] && continue
                local existing_lower=$(echo "$existing_name" | tr '[:upper:]' '[:lower:]')
                if [[ "$name_lower" == "$existing_lower" && "$name" != "$existing_name" ]]; then
                    _err "用户名 $name 与已存在的用户 $existing_name 冲突"
                    conflict=true
                    break
                fi
            done <<< "$existing_users"
        fi
        [[ "$conflict" == true ]] && continue

        break
    done

    # 生成 UUID/密码
    local uuid
    case "$proto" in
        vless-singbox|tuic)
            uuid=$(gen_uuid)
            ;;
        ss2022)
            # SS2022 需要根据加密方式生成密钥
            local method=$(db_get_field "$core" "$proto" "method")
            local key_len=16
            [[ "$method" == *"256"* ]] && key_len=32
            uuid=$(head -c $key_len /dev/urandom 2>/dev/null | base64 -w 0)
            ;;
        *)
            uuid=$(ask_password 16 "用户密码")
            ;;
    esac

    # 输入到期日期
    echo ""
    echo -e "  ${D}到期日期: 输入天数(如30) 或日期(如2026-03-01)，留空表示永不过期${NC}"
    local expire_date=""
    local expire_display="永不过期"
    read -rp "  到期 [永不过期]: " expire_input
    if [[ -n "$expire_input" ]]; then
        if [[ "$expire_input" =~ ^[0-9]+$ ]]; then
            # 输入的是天数
            expire_date=$(date -d "+${expire_input} days" '+%Y-%m-%d' 2>/dev/null)
            if [[ -z "$expire_date" ]]; then
                # macOS 兼容
                expire_date=$(date -v+${expire_input}d '+%Y-%m-%d' 2>/dev/null)
            fi
            expire_display="$expire_date (${expire_input}天后)"
        elif [[ "$expire_input" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            # 输入的是日期
            expire_date="$expire_input"
            expire_display="$expire_date"
        else
            _warn "无效日期格式，将设置为永不过期"
        fi
    fi

    # 选择路由 (可选)
    local user_routing=""
    echo ""
    read -rp "  是否为此用户配置专属路由? [y/N]: " config_routing
    if [[ "$config_routing" =~ ^[yY]$ ]]; then
        if _select_user_routing; then
            user_routing="$SELECTED_ROUTING"
        fi
    fi

    # 确认
    local routing_display=$(_format_user_routing "$user_routing")
    echo ""
    _line
    echo -e "  用户名: ${G}$name${NC}"
    echo -e "  凭证: ${G}${uuid:0:16}...${NC}"
    echo -e "  到期: ${G}$expire_display${NC}"
    echo -e "  路由: ${G}$routing_display${NC}"
    _line

    read -rp "  确认添加? [Y/n]: " confirm
    [[ "$confirm" =~ ^[nN]$ ]] && return

    # 添加到数据库 (包含 expire_date)
    if db_add_user "$core" "$proto" "$name" "$uuid" "$expire_date"; then
        _ok "用户 $name 添加成功"

        # 如果有自定义路由，设置路由
        if [[ -n "$user_routing" ]]; then
            db_set_user_routing "$core" "$proto" "$name" "$user_routing"
            _ok "路由配置: $routing_display"
        fi

        # 重新生成配置
        _info "更新配置..."
        _regenerate_config "$core" "$proto" || return 1

        _ok "配置已更新"
    else
        _err "添加失败"
    fi
}

# 删除用户
_delete_user() {
    local core="$1" proto="$2"
    local proto_name=$(get_protocol_name "$proto")

    local users=$(db_list_users "$core" "$proto")
    [[ -z "$users" ]] && { _err "没有用户可删除"; return; }

    echo ""
    _line
    echo -e "  ${W}删除用户 - $proto_name${NC}"
    _line

    local i=1
    local user_array=()
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        _item "$i" "$user"
        user_array+=("$user")
        ((i++))
    done <<< "$users"

    _item "0" "返回"
    _line

    local max=$((i-1))
    while true; do
        read -rp "  选择要删除的用户 [0-$max]: " choice
        [[ "$choice" == "0" ]] && return
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$max" ]]; then
            local name="${user_array[$((choice-1))]}"

            # 禁止删除 default 用户
            if [[ "$name" == "default" ]]; then
                _err "default 用户不能删除"
                _info "default 是协议的默认用户，删除会导致协议无法正常工作"
                return
            fi

            # 确认删除
            read -rp "  确认删除用户 $name? [y/N]: " confirm
            [[ ! "$confirm" =~ ^[yY]$ ]] && return

            if db_del_user "$core" "$proto" "$name"; then
                _ok "用户 $name 已删除"

                # 重新生成配置
                _info "更新配置..."
                _regenerate_config "$core" "$proto"

                _ok "配置已更新"
            else
                _err "删除失败"
            fi
            return
        fi
        _err "无效选择"
    done
}

# 设置用户配额


# 重置用户流量


# 启用/禁用用户
_toggle_user() {
    local core="$1" proto="$2"
    local proto_name=$(get_protocol_name "$proto")

    local users=$(db_list_users "$core" "$proto")
    [[ -z "$users" ]] && { _err "没有用户"; return; }

    echo ""
    _line
    echo -e "  ${W}启用/禁用用户 - $proto_name${NC}"
    _line

    local i=1
    local user_array=()
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        local enabled=$(db_get_user_field "$core" "$proto" "$user" "enabled")
        local status="${G}● 启用${NC}"
        [[ "$enabled" != "true" ]] && status="${R}○ 禁用${NC}"
        _item "$i" "$user $status"
        user_array+=("$user")
        ((i++))
    done <<< "$users"

    _item "0" "返回"
    _line

    local max=$((i-1))
    while true; do
        read -rp "  选择用户 [0-$max]: " choice
        [[ "$choice" == "0" ]] && return
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$max" ]]; then
            local name="${user_array[$((choice-1))]}"
            local enabled=$(db_get_user_field "$core" "$proto" "$name" "enabled")

            local new_state="true"
            local action="启用"
            if [[ "$enabled" == "true" ]]; then
                new_state="false"
                action="禁用"
            fi

            if db_set_user_enabled "$core" "$proto" "$name" "$new_state"; then
                _ok "用户 $name 已${action}"
                _ok "配置已更新"
            else
                _err "操作失败"
            fi
            return
        fi
        _err "无效选择"
    done
}

# 设置用户到期日期
_set_user_expire_date() {
    local core="$1" proto="$2"
    local proto_name=$(get_protocol_name "$proto")

    local users=$(db_list_users "$core" "$proto")
    [[ -z "$users" ]] && { _err "没有用户"; return; }

    echo ""
    _line
    echo -e "  ${W}设置到期日期 - $proto_name${NC}"
    _line

    local i=1
    local user_array=()
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        local expire_date=$(db_get_user_expire_date "$core" "$proto" "$user")
        local expire_info="永久"
        if [[ -n "$expire_date" ]]; then
            local days_left=$(db_get_user_days_left "$core" "$proto" "$user")
            if [[ "$days_left" -lt 0 ]]; then
                expire_info="${R}已过期 ($expire_date)${NC}"
            else
                expire_info="$expire_date (剩余 ${days_left} 天)"
            fi
        fi
        _item "$i" "$user ${D}($expire_info)${NC}"
        user_array+=("$user")
        ((i++))
    done <<< "$users"

    _item "0" "返回"
    _line

    local max=$((i-1))
    while true; do
        read -rp "  选择用户 [0-$max]: " choice
        [[ "$choice" == "0" ]] && return
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$max" ]]; then
            local name="${user_array[$((choice-1))]}"

            echo ""
            echo -e "  ${D}输入天数(如30) 或日期(2026-03-01)，输入 0 取消到期限制${NC}"
            local expire_input
            read -rp "  新到期: " expire_input

            local new_expire=""
            if [[ "$expire_input" == "0" ]]; then
                new_expire=""
            elif [[ "$expire_input" =~ ^[0-9]+$ ]]; then
                new_expire=$(date -d "+${expire_input} days" '+%Y-%m-%d' 2>/dev/null)
                [[ -z "$new_expire" ]] && new_expire=$(date -v+${expire_input}d '+%Y-%m-%d' 2>/dev/null)
            elif [[ "$expire_input" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                new_expire="$expire_input"
            else
                _err "无效格式"
                return
            fi

            if db_set_user_expire_date "$core" "$proto" "$name" "$new_expire"; then
                if [[ -z "$new_expire" ]]; then
                    _ok "用户 $name 已设为永不过期"
                else
                    _ok "用户 $name 到期日期已设为 $new_expire"
                fi

                # 如果用户之前被禁用且设置了有效期，询问是否启用
                local enabled=$(db_get_user_field "$core" "$proto" "$name" "enabled")
                if [[ "$enabled" != "true" && -n "$new_expire" ]]; then
                    read -rp "  用户当前已禁用，是否启用? [y/N]: " enable_now
                    if [[ "$enable_now" =~ ^[yY]$ ]]; then
                        if db_set_user_enabled "$core" "$proto" "$name" true; then
                            _ok "用户已启用"
                        else
                            _err "用户启用或配置重载失败"
                        fi
                    fi
                fi
            else
                _err "设置失败"
            fi
            return
        fi
        _err "无效选择"
    done
}

# 重新生成配置 (添加/删除用户后调用)
_regenerate_config() {
    local core="$1"
    [[ "$core" == singbox ]] || { _err "该协议不支持用户配置"; return 1; }
    rebuild_and_reload_singbox || return 1
    [[ ! -f "$CFG/sub.info" ]] || generate_sub_files || return 1
    return 0
}

# 选择可绑定 Telegram 的受管用户；只有数据库 users 数组中的账号可绑定。
_select_tg_bind_user() {
    _select_protocol_for_users || return 1
    local core="$SELECTED_CORE" proto="$SELECTED_PROTO" users user
    users=$(db_list_users "$core" "$proto")
    [[ -n "$users" ]] || { _err "该协议没有可绑定用户"; return 1; }

    echo ""
    _line
    echo -e "  ${W}选择绑定用户 - $(get_protocol_name "$proto")${NC}"
    _line
    local i=1 user_array=()
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        [[ -n "$(db_get_user "$core" "$proto" "$user")" ]] || continue
        local chat_id
        chat_id=$(db_get_user_field "$core" "$proto" "$user" "telegram_chat_id")
        if [[ -n "$chat_id" ]]; then
            _item "$i" "$user ${D}(已绑定: $chat_id)${NC}"
        else
            _item "$i" "$user ${D}(未绑定)${NC}"
        fi
        user_array+=("$user")
        ((i++))
    done <<< "$users"
    if [[ ${#user_array[@]} -eq 0 ]]; then
        _err "该协议没有受管用户；请先在用户管理中添加用户"
        return 1
    fi
    _item "0" "返回"
    _line

    local choice max=${#user_array[@]}
    read -rp "  选择用户 [0-$max]: " choice
    [[ "$choice" == "0" ]] && return 1
    [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "$max" ]] || {
        _err "无效选择"
        return 1
    }
    TG_SELECTED_CORE="$core"
    TG_SELECTED_PROTO="$proto"
    TG_SELECTED_USER="${user_array[$((choice-1))]}"
    return 0
}

_tg_generate_user_bind_code() {
    _select_tg_bind_user || return
    local token token_hash expires_at
    token=$(tg_generate_bind_token)
    [[ "$token" =~ ^[A-F0-9]{12}$ ]] || { _err "生成绑定码失败"; return; }
    token_hash=$(tg_hash_bind_token "$token")
    [[ -n "$token_hash" ]] || { _err "计算绑定码摘要失败"; return; }
    expires_at=$(( $(date '+%s') + 86400 ))

    if db_set_user_tg_bind_token "$TG_SELECTED_CORE" "$TG_SELECTED_PROTO" "$TG_SELECTED_USER" "$token_hash" "$expires_at"; then
        echo ""
        _line
        _ok "已为用户 $TG_SELECTED_USER 生成一次性绑定码"
        echo -e "  绑定命令: ${G}/bind ${token}${NC}"
        echo -e "  ${D}有效期 24 小时；重新生成会使旧绑定码失效${NC}"
        _line
    else
        _err "保存绑定码失败"
    fi
}

_tg_show_user_bindings() {
    local bindings
    bindings=$(db_list_tg_user_bindings)
    echo ""
    _line
    echo -e "  ${W}Telegram 用户绑定${NC}"
    _line
    if [[ -z "$bindings" ]]; then
        echo -e "  ${D}暂无绑定${NC}"
        return
    fi
    local core proto name chat_id username bound_at index=1
    while IFS='|' read -r core proto name chat_id username bound_at; do
        [[ -z "$name" ]] && continue
        printf "  ${G}%d)${NC} %s / %s / %s\n" "$index" "$(get_protocol_name "$proto")" "$name" "$chat_id"
        [[ -n "$username" ]] && echo -e "     ${D}@${username}，绑定时间: ${bound_at:-未知}${NC}"
        ((index++))
    done <<< "$bindings"
}

_tg_unbind_user() {
    local bindings
    bindings=$(db_list_tg_user_bindings)
    [[ -n "$bindings" ]] || { _warn "暂无已绑定用户"; return; }
    local entries=() core proto name chat_id username bound_at index=1
    echo ""
    _line
    echo -e "  ${W}解除 Telegram 用户绑定${NC}"
    _line
    while IFS='|' read -r core proto name chat_id username bound_at; do
        [[ -z "$name" ]] && continue
        _item "$index" "$(get_protocol_name "$proto") / $name ${D}($chat_id)${NC}"
        entries+=("$core|$proto|$name")
        ((index++))
    done <<< "$bindings"
    _item "0" "返回"
    _line

    local choice max=${#entries[@]} selected
    read -rp "  选择用户 [0-$max]: " choice
    [[ "$choice" == "0" ]] && return
    [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "$max" ]] || {
        _err "无效选择"
        return
    }
    selected="${entries[$((choice-1))]}"
    IFS='|' read -r core proto name <<< "$selected"
    if db_clear_user_tg_binding "$core" "$proto" "$name"; then
        _ok "已解除用户 $name 的 Telegram 绑定"
    else
        _err "解绑失败"
    fi
}

_configure_tg_user_bot() {
    init_tg_config
    while true; do
        local enabled bot_token bot_status cron_status binding_count
        enabled=$(tg_get_config "user_bot_enabled")
        bot_token=$(tg_get_config "bot_token")
        bot_status="${R}○ 未启用${NC}"
        [[ "$enabled" == "true" ]] && bot_status="${G}● 已启用${NC}"
        cron_status="${R}○ 未运行${NC}"
        if tg_user_bot_cron_entry_exists; then
            if cron_service_is_active; then
                cron_status="${G}● 每分钟轮询${NC}"
            else
                cron_status="${Y}● 规则存在，但 cron 未运行${NC}"
            fi
        fi
        binding_count=$(db_list_tg_user_bindings | awk 'NF{n++} END{print n+0}')

        _header
        echo -e "  ${W}TG 用户查询机器人${NC}"
        _dline
        echo -e "  用户机器人: $bot_status"
        echo -e "  轮询任务: $cron_status"
        echo -e "  已绑定用户: ${G}$binding_count${NC}"
        echo -e "  Bot Token: ${bot_token:+${G}复用管理员配置${NC}}${bot_token:-${D}未配置${NC}}"
        [[ "$enabled" != "true" ]] && echo -e "  ${D}提示: 启用后使用 getUpdates 轮询，并移除该 Bot 的现有 webhook${NC}"
        _line
        if [[ "$enabled" == "true" ]]; then
            _item "1" "禁用用户机器人"
        else
            _item "1" "启用用户机器人"
        fi
        _item "2" "为用户生成绑定码"
        _item "3" "查看绑定关系"
        _item "4" "解除用户绑定"
        _item "5" "立即处理机器人消息"
        _item "6" "查看机器人命令"
        _item "0" "返回"
        _line

        local choice response bot_username
        read -rp "  请选择: " choice
        case "$choice" in
            1)
                if [[ "$enabled" == "true" ]]; then
                    tg_set_config "user_bot_enabled" "false"
                    remove_tg_user_bot_cron
                    _ok "用户机器人已禁用；现有绑定关系已保留"
                else
                    if [[ -z "$bot_token" ]]; then
                        _err "请先在上级 TG 通知配置中设置 Bot Token"
                    else
                        _info "验证 Telegram Bot Token..."
                        response=$(tg_bot_api_request "getMe")
                        if ! jq -e '.ok == true' >/dev/null 2>&1 <<< "$response"; then
                            _err "Bot Token 验证失败"
                        else
                            bot_username=$(jq -r '.result.username // empty' <<< "$response")
                            # getUpdates 与 webhook 不能同时使用；启用时切换到轮询模式。
                            tg_bot_api_request "deleteWebhook" --data-urlencode "drop_pending_updates=false" >/dev/null 2>&1 || true
                            tg_bot_api_request "setMyCommands" --data-urlencode 'commands=[{"command":"status","description":"查询账号状态"},{"command":"bind","description":"绑定代理账号"},{"command":"unbind","description":"解除绑定"},{"command":"help","description":"查看帮助"}]' >/dev/null 2>&1 || true
                            tg_set_config "user_bot_enabled" "true"
                            if setup_tg_user_bot_cron; then
                                _ok "用户机器人已启用${bot_username:+: @${bot_username}}"
                            else
                                tg_set_config "user_bot_enabled" "false"
                            fi
                        fi
                    fi
                fi
                _pause
                ;;
            2) _tg_generate_user_bind_code; _pause ;;
            3) _tg_show_user_bindings; _pause ;;
            4) _tg_unbind_user; _pause ;;
            5)
                if [[ "$enabled" != "true" ]]; then
                    _err "请先启用用户机器人"
                elif tg_poll_user_bot; then
                    _ok "机器人消息处理完成"
                else
                    _err "机器人消息处理失败，请检查 $CFG/tg-user-bot.log"
                fi
                _pause
                ;;
            6) echo ""; tg_user_bot_help_text; _pause ;;
            0) return ;;
            *) _err "无效选择" ;;
        esac
    done
}

# 配置 TG 通知
_configure_tg_notify() {
    init_tg_config
    local choice value enabled
    while true; do
        _header
        _item 1 "设置 Bot Token"
        _item 2 "设置 Chat ID"
        _item 3 "测试发送"
        _item 4 "启用/禁用到期通知"
        _item 7 "设置服务器名"
        _item 8 "用户绑定与账号查询机器人"
        _item 0 "返回"
        read -rp "  请选择: " choice || return
        case "$choice" in
            1) read -rsp "  Bot Token: " value; echo; [[ -z "$value" ]] || tg_set_config bot_token "$value" ;;
            2) read -rp "  Chat ID: " value; [[ -z "$value" ]] || tg_set_config chat_id "$value" ;;
            3) tg_send_chat_message "$(tg_get_config chat_id)" "到期通知测试" || _err "发送失败" ;;
            4) enabled=$(tg_get_config enabled)
               if [[ "$enabled" == true ]]; then tg_set_config enabled false
               else tg_set_config enabled true; ensure_expire_check_cron; fi ;;
            7) read -rp "  服务器名: " value; tg_set_config server_name "$value" ;;
            8) _configure_tg_user_bot ;;
            0) return ;;
            *) _err "无效选择" ;;
        esac
    done
}

# 检测当前运行的核心类型











# 用户管理主菜单
manage_users() {
    while true; do
        _header
        echo -e "  ${W}用户管理${NC}"
        _dline

        # 显示所有协议的用户统计
        local protocols=$(db_get_all_protocols)
        if [[ -n "$protocols" ]]; then
            echo -e "  ${D}已安装协议:${NC}"
            while IFS= read -r proto; do
                [[ -z "$proto" ]] && continue
                local core="singbox"
                db_exists "singbox" "$proto" && core="singbox"
                local user_count=$(db_count_users "$core" "$proto")
                local proto_name=$(get_protocol_name "$proto")
                echo -e "  • $proto_name: ${G}$user_count${NC} 用户"
            done <<< "$protocols"
        fi

        _line
        _item "1" "查看用户列表"
        _item "2" "添加用户"
        _item "3" "删除用户"
        _item "6" "启用/禁用用户"
        _item "e" "设置到期日期"
        _item "r" "修改用户路由"
        _item "s" "查看用户分享链接"
        _line
        _line
        _item "t" "TG 通知配置"
        _item "0" "返回"
        _line

        read -rp "  请选择: " choice
        case $choice in
            1)
                if _select_protocol_for_users; then
                    _show_users_list "$SELECTED_CORE" "$SELECTED_PROTO"
                    _pause
                fi
                ;;
            2)
                if _select_protocol_for_users; then
                    _add_user "$SELECTED_CORE" "$SELECTED_PROTO"
                    _pause
                fi
                ;;
            3)
                if _select_protocol_for_users; then
                    _delete_user "$SELECTED_CORE" "$SELECTED_PROTO"
                    _pause
                fi
                ;;
            6)
                if _select_protocol_for_users; then
                    _toggle_user "$SELECTED_CORE" "$SELECTED_PROTO"
                    _pause
                fi
                ;;
            e|E)
                if _select_protocol_for_users; then
                    _set_user_expire_date "$SELECTED_CORE" "$SELECTED_PROTO"
                    _pause
                fi
                ;;
            r|R)
                if _select_protocol_for_users; then
                    _set_user_routing "$SELECTED_CORE" "$SELECTED_PROTO"
                    _pause
                fi
                ;;
            s|S)
                if _select_protocol_for_users; then
                    _show_user_share_links "$SELECTED_CORE" "$SELECTED_PROTO"
                fi
                ;;
            t|T)
                _configure_tg_notify
                ;;
            0) return ;;
            *) _err "无效选择" ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════════════
# 端口转发 (Realm) + iPerf3
#═══════════════════════════════════════════════════════════════════════════════
REALM_DIR="$CFG/realm"
format_bytes() {
    local bytes="${1:-0}"
    [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
    awk -v bytes="$bytes" 'BEGIN {
        if (bytes >= 1099511627776) printf "%.2f TB", bytes/1099511627776;
        else if (bytes >= 1073741824) printf "%.2f GB", bytes/1073741824;
        else if (bytes >= 1048576) printf "%.2f MB", bytes/1048576;
        else if (bytes >= 1024) printf "%.2f KB", bytes/1024;
        else printf "%d B", bytes;
    }'
}
REALM_RULES_FILE="$REALM_DIR/rules.json"
REALM_CONFIG_FILE="$REALM_DIR/config.toml"
REALM_BIN="$CFG/bin/realm"
REALM_SVC="sing-realm"

ensure_realm_dir() {
    mkdir -p "$REALM_DIR"
    [[ -f "$REALM_RULES_FILE" ]] || echo '[]' > "$REALM_RULES_FILE"
}

install_realm_binary() {
    mkdir -p "$CFG/bin" || return 1
    if [[ -x "$REALM_BIN" ]]; then
        _ok "Realm 已安装: $("$REALM_BIN" --version 2>/dev/null | head -n1)"
        return 0
    fi
    _info "安装 Realm..."
    local arch url tmp release_json release_tag release_version
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch='x86_64-unknown-linux-gnu' ;;
        aarch64|arm64) arch='aarch64-unknown-linux-gnu' ;;
        armv7l|armv6l) arch='armv7-unknown-linux-gnueabihf' ;;
        *) _err "暂不支持的架构: $arch"; return 1 ;;
    esac
    release_json=$(curl -fsSL --connect-timeout 10 --max-time 30 https://api.github.com/repos/zhboner/realm/releases/latest) || {
        _err "获取 Realm 发布信息失败"
        return 1
    }
    release_tag=$(printf '%s' "$release_json" | jq -r '.tag_name // empty')
    release_version="${release_tag#v}"
    url=$(printf '%s' "$release_json" | jq -r --arg a "$arch" '.assets[] | select(.name | test($a + ".tar.gz$")) | .browser_download_url' | head -n1)
    [[ -z "$url" ]] && { _err "获取 Realm 下载地址失败"; return 1; }
    tmp=$(mktemp -d) || return 1
    curl -fsSL -o "$tmp/realm.tar.gz" -- "$url" || { rm -rf "$tmp"; return 1; }
    if ! _verify_github_release_asset "zhboner/realm" "$release_version" "$url" "$tmp/realm.tar.gz"; then
        rm -rf "$tmp"
        _err "Realm SHA-256 校验失败，已拒绝安装"
        return 1
    fi
    _archive_paths_safe "$tmp/realm.tar.gz" tar.gz &&
        tar -xzf "$tmp/realm.tar.gz" -C "$tmp" || {
            rm -rf "$tmp"
            _err "Realm 压缩包路径校验或解压失败"
            return 1
        }
    local bin=""
    [[ -f "$tmp/realm" ]] && bin="$tmp/realm"
    [[ -f "$tmp/realm-slim" ]] && bin="$tmp/realm-slim"
    [[ -z "$bin" ]] && { _err "Realm 解压后未找到二进制"; rm -rf "$tmp"; return 1; }
    if ! install -m 755 "$bin" "$REALM_BIN"; then
        rm -rf "$tmp"
        _err "Realm 二进制安装失败"
        return 1
    fi
    rm -rf "$tmp"
    if ! "$REALM_BIN" --version >/dev/null 2>&1; then
        _err "Realm 安装后运行验证失败"
        return 1
    fi
    _ok "Realm 安装完成: $("$REALM_BIN" --version 2>/dev/null | head -n1)"
}

create_realm_service() {
    if [[ "$DISTRO" == "alpine" ]]; then
        cat > "/etc/init.d/$REALM_SVC" <<'EOF'
#!/sbin/openrc-run
name="sing-realm"
command="/etc/sing-lite/bin/realm"
command_args="-c /etc/sing-lite/realm/config.toml"
command_background=true
pidfile="/run/sing-realm.pid"
depend() { need net; }
EOF
        chmod +x "/etc/init.d/$REALM_SVC"
    else
        cat > "/etc/systemd/system/${REALM_SVC}.service" <<EOF
[Unit]
Description=VLESS Realm Forward Service
After=network.target

[Service]
Type=simple
ExecStart=${REALM_BIN} -c ${REALM_CONFIG_FILE}
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi
}

realm_generate_config() {
    ensure_realm_dir
    python3 - <<'PY2'
import json
from pathlib import Path
rules_path=Path('/etc/sing-lite/realm/rules.json')
conf_path=Path('/etc/sing-lite/realm/config.toml')
rules=json.loads(rules_path.read_text()) if rules_path.exists() else []
lines=['[log]','level = "warn"','','[network]','no_tcp = false','use_udp = true','']
for r in rules:
    if not r.get('enabled', True):
        continue
    transport=r.get('transport','tcp')
    lines.append('[[endpoints]]')
    lines.append(f'listen = "{r["listen_host"]}:{r["listen_port"]}"')
    lines.append(f'remote = "{r["remote_host"]}:{r["remote_port"]}"')
    if transport == 'udp':
        lines.append('no_tcp = true')
        lines.append('use_udp = true')
    elif transport == 'tcp+udp':
        lines.append('use_udp = true')
    else:
        lines.append('no_tcp = false')
    if r.get('remark'):
        lines.append(f'# {r["remark"]}')
    lines.append('')
conf_path.write_text('\n'.join(lines)+'\n')
PY2
}

realm_sync_traffic_counters() {
    ensure_realm_dir
    local chain="SING_REALM_COUNTERS"
    command -v iptables >/dev/null 2>&1 || return 0

    iptables -N "$chain" 2>/dev/null || true
    iptables -C INPUT -j "$chain" 2>/dev/null || iptables -I INPUT 1 -j "$chain" 2>/dev/null || true
    iptables -F "$chain" 2>/dev/null || true

    python3 - "$REALM_RULES_FILE" <<'PY2' | while IFS='|' read -r transport listen_host listen_port; do
import json, sys
from pathlib import Path
p=Path(sys.argv[1])
rules=json.loads(p.read_text()) if p.exists() else []
for r in rules:
    if not r.get('enabled', True):
        continue
    print(f"{r.get('transport','tcp')}|{r.get('listen_host','0.0.0.0')}|{r.get('listen_port','')}")
PY2
        [[ -z "$listen_port" ]] && continue
        case "$transport" in
            tcp)
                iptables -A "$chain" -p tcp --dport "$listen_port" -m comment --comment "realm:$listen_port:tcp" -j ACCEPT 2>/dev/null || true
                ;;
            udp)
                iptables -A "$chain" -p udp --dport "$listen_port" -m comment --comment "realm:$listen_port:udp" -j ACCEPT 2>/dev/null || true
                ;;
            tcp+udp)
                iptables -A "$chain" -p tcp --dport "$listen_port" -m comment --comment "realm:$listen_port:tcp" -j ACCEPT 2>/dev/null || true
                iptables -A "$chain" -p udp --dport "$listen_port" -m comment --comment "realm:$listen_port:udp" -j ACCEPT 2>/dev/null || true
                ;;
        esac
    done
}

realm_get_traffic_bytes() {
    local port="$1" proto="$2" chain="SING_REALM_COUNTERS"
    command -v iptables >/dev/null 2>&1 || { echo 0; return 0; }
    iptables -nvx -L "$chain" 2>/dev/null | awk -v p="$port" -v proto="$proto" '
        $0 ~ ("dpt:" p) {
            for (i=1; i<=NF; i++) {
                if ($i == proto) { sum += $2; break }
            }
        }
        END { print sum+0 }
    '
}

realm_ping_host() {
    local host="$1"
    [[ -z "$host" ]] && { echo "N/A"; return 0; }
    if echo "$host" | grep -q ':'; then
        ping -6 -c 1 -W 2 "$host" 2>/dev/null | awk -F'time=' 'NR==2{print $2}' | awk '{print $1" ms"}' | head -n1
    else
        ping -4 -c 1 -W 2 "$host" 2>/dev/null | awk -F'time=' 'NR==2{print $2}' | awk '{print $1" ms"}' | head -n1
    fi
}

realm_show_rules_status() {
    ensure_realm_dir
    python3 - "$REALM_RULES_FILE" <<'PY2'
import json, sys
from pathlib import Path
p=Path(sys.argv[1])
rules=json.loads(p.read_text()) if p.exists() else []
print(json.dumps(rules, ensure_ascii=False))
PY2
}

realm_cleanup_runtime() {
    command -v iptables >/dev/null 2>&1 && {
        iptables -D INPUT -j SING_REALM_COUNTERS 2>/dev/null || true
        iptables -F SING_REALM_COUNTERS 2>/dev/null || true
        iptables -X SING_REALM_COUNTERS 2>/dev/null || true
    }
    if svc status "$REALM_SVC" 2>/dev/null; then
        svc stop "$REALM_SVC" 2>/dev/null || true
    else
        systemctl stop "$REALM_SVC" 2>/dev/null || true
    fi
    svc disable "$REALM_SVC" 2>/dev/null || systemctl disable "$REALM_SVC" 2>/dev/null || true
}

realm_restart_service() {
    ensure_realm_dir
    local rule_count
    rule_count=$(jq 'length' "$REALM_RULES_FILE" 2>/dev/null || echo 0)
    if [[ "$rule_count" == "0" ]]; then
        rm -f "$REALM_CONFIG_FILE" 2>/dev/null || true
        realm_cleanup_runtime
        return 0
    fi
    realm_generate_config || return 1
    create_realm_service || return 1
    realm_sync_traffic_counters || true
    svc enable "$REALM_SVC" 2>/dev/null || true
    if svc status "$REALM_SVC" 2>/dev/null; then
        svc restart "$REALM_SVC" || return 1
    else
        svc start "$REALM_SVC" || return 1
    fi
}

realm_add_rule() {
    install_realm_binary || return 1
    ensure_realm_dir
    echo ""
    _line
    echo -e "  ${W}转发后端选择${NC}"
    _line
    _item "1" "Realm"
    _item "0" "返回"
    echo ""
    local backend_choice
    read -rp "  请选择 [1]: " backend_choice
    backend_choice="${backend_choice:-1}"
    [[ "$backend_choice" == "0" ]] && return 0
    [[ "$backend_choice" != "1" ]] && { _err "无效选择"; return 1; }

    local remark transport_choice transport listen_host listen_port remote_host remote_port
    read -rp "  规则备注: " remark
    echo ""
    _line
    echo -e "  ${W}协议类型${NC}"
    _line
    _item "1" "TCP"
    _item "2" "UDP"
    _item "3" "TCP + UDP"
    echo ""
    read -rp "  请选择 [1]: " transport_choice
    transport_choice="${transport_choice:-1}"
    case "$transport_choice" in
        1) transport='tcp' ;;
        2) transport='udp' ;;
        3) transport='tcp+udp' ;;
        *) _err "无效选择"; return 1 ;;
    esac
    read -rp "  监听地址 [0.0.0.0]: " listen_host
    listen_host="${listen_host:-0.0.0.0}"
    read -rp "  监听端口: " listen_port
    read -rp "  目标地址: " remote_host
    read -rp "  目标端口: " remote_port
    [[ -z "$listen_port" || -z "$remote_host" || -z "$remote_port" ]] && { _err "参数不能为空"; return 1; }
    _is_valid_domain_or_ip "$listen_host" || { _err "监听地址格式无效"; return 1; }
    _is_valid_domain_or_ip "$remote_host" || { _err "目标地址格式无效"; return 1; }
    _is_valid_port "$listen_port" || { _err "监听端口必须是 1-65535 的整数"; return 1; }
    _is_valid_port "$remote_port" || { _err "目标端口必须是 1-65535 的整数"; return 1; }
    echo ""
    echo -e "  ${C}备注:${NC} ${G}${remark:-未命名}${NC}"
    echo -e "  ${C}协议:${NC} ${G}${transport}${NC}"
    echo -e "  ${C}监听:${NC} ${G}${listen_host}:${listen_port}${NC}"
    echo -e "  ${C}目标:${NC} ${G}${remote_host}:${remote_port}${NC}"
    echo ""
    read -rp "  确认创建? [Y/n]: " confirm
    [[ "$confirm" =~ ^[nN]$ ]] && return 0
    if ! python3 - "$REALM_RULES_FILE" "$remark" "$transport" "$listen_host" "$listen_port" "$remote_host" "$remote_port" <<'PY2'
import json, sys
from pathlib import Path
p=Path(sys.argv[1])
rules=json.loads(p.read_text()) if p.exists() else []
rules.append({
  'backend':'realm',
  'remark':sys.argv[2],
  'transport':sys.argv[3],
  'listen_host':sys.argv[4],
  'listen_port':int(sys.argv[5]),
  'remote_host':sys.argv[6],
  'remote_port':int(sys.argv[7]),
  'enabled':True
})
p.write_text(json.dumps(rules, ensure_ascii=False, indent=2))
PY2
    then
        _err "转发规则写入失败"
        return 1
    fi
    realm_restart_service || { _err "Realm 服务启动失败"; return 1; }
    _ok "转发规则已创建并生效"
}

realm_list_rules() {
    ensure_realm_dir
    local count
    count=$(jq 'length' "$REALM_RULES_FILE" 2>/dev/null || echo 0)
    echo ""
    _line
    echo -e "  ${W}转发规则${NC}"
    _line
    [[ "$count" == "0" ]] && { echo -e "  ${D}暂无规则${NC}"; _line; return 0; }
    python3 - "$REALM_RULES_FILE" <<'PY2'
import json, sys
from pathlib import Path
p=Path(sys.argv[1])
rules=json.loads(p.read_text()) if p.exists() else []
for i, r in enumerate(rules, 1):
    print(f"{i}) {r.get('remark') or '未命名'}")
    print(f"   后端: {r.get('backend','realm')}")
    print(f"   协议: {r.get('transport','tcp')}")
    print(f"   监听: {r.get('listen_host','0.0.0.0')}:{r.get('listen_port','')}")
    print(f"   目标: {r.get('remote_host','')}:{r.get('remote_port','')}")
    print(f"   状态: {'已启用' if r.get('enabled', True) else '已禁用'}")
    print()
PY2
    _line
}

realm_delete_rule() {
    ensure_realm_dir
    local count
    count=$(jq 'length' "$REALM_RULES_FILE" 2>/dev/null || echo 0)
    [[ "$count" == "0" ]] && { _warn "暂无规则可删除"; return 0; }
    realm_list_rules
    local idx
    read -rp "  选择要删除的规则编号 [1-${count}]，0返回: " idx
    [[ "$idx" == "0" ]] && return 0
    [[ ! "$idx" =~ ^[0-9]+$ ]] && { _err "无效选择"; return 1; }
    ((idx>=1 && idx<=count)) || { _err "超出范围"; return 1; }
    read -rp "  确认删除? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && return 0
    python3 - "$REALM_RULES_FILE" "$idx" <<'PY2'
import json, sys
from pathlib import Path
p=Path(sys.argv[1])
rules=json.loads(p.read_text()) if p.exists() else []
del rules[int(sys.argv[2])-1]
p.write_text(json.dumps(rules, ensure_ascii=False, indent=2))
PY2
    realm_restart_service || true
    _ok "规则已删除"
}

realm_status_logs_menu() {
    while true; do
        _header
        echo -e "  ${W}转发状态 / 日志${NC}"
        _line
        if check_cmd realm; then
            echo -e "  ${G}Realm 已安装${NC}: $(realm --version 2>/dev/null | head -n1)"
        else
            echo -e "  ${R}Realm 未安装${NC}"
        fi
        if svc status "$REALM_SVC" 2>/dev/null || systemctl is-active --quiet "$REALM_SVC" 2>/dev/null || pgrep -x realm >/dev/null 2>&1; then
            echo -e "  ${G}服务状态: 运行中${NC}"
        else
            echo -e "  ${R}服务状态: 未运行${NC}"
        fi
        [[ -f "$REALM_RULES_FILE" ]] && echo -e "  ${D}规则文件: ${REALM_RULES_FILE}${NC}" || echo -e "  ${R}规则文件缺失: ${REALM_RULES_FILE}${NC}"
        [[ -f "$REALM_CONFIG_FILE" ]] && echo -e "  ${D}配置文件: ${REALM_CONFIG_FILE}${NC}" || echo -e "  ${R}配置文件缺失: ${REALM_CONFIG_FILE}${NC}"
        _line
        _item "1" "查看服务状态"
        _item "2" "查看最近日志"
        _item "3" "重启转发服务"
        _item "0" "返回"
        _line
        read -rp "  请选择: " choice
        case "$choice" in
            1)
                _header
                echo -e "  ${W}转发状态${NC}"
                _line
                local service_state="未运行"
                if svc status "$REALM_SVC" >/dev/null 2>&1 || systemctl is-active --quiet "$REALM_SVC" 2>/dev/null; then
                    service_state="运行中"
                elif pgrep -x realm >/dev/null 2>&1; then
                    service_state="运行中"
                fi
                echo -e "  ${C}服务状态:${NC} ${G}${service_state}${NC}"
                echo ""
                local count idx remark transport listen_host listen_port remote_host remote_port enabled ping_value tcp_bytes udp_bytes total_bytes tcp_state udp_state
                count=$(jq 'length' "$REALM_RULES_FILE" 2>/dev/null || echo 0)
                if [[ "$count" == "0" ]]; then
                    echo -e "  ${D}当前没有转发规则${NC}"
                else
                    for idx in $(seq 0 $((count-1))); do
                        remark=$(jq -r '.['"$idx"'].remark // "未命名"' "$REALM_RULES_FILE")
                        transport=$(jq -r '.['"$idx"'].transport // "tcp"' "$REALM_RULES_FILE")
                        listen_host=$(jq -r '.['"$idx"'].listen_host // "0.0.0.0"' "$REALM_RULES_FILE")
                        listen_port=$(jq -r ".[$idx].listen_port" "$REALM_RULES_FILE")
                        remote_host=$(jq -r ".[$idx].remote_host" "$REALM_RULES_FILE")
                        remote_port=$(jq -r ".[$idx].remote_port" "$REALM_RULES_FILE")
                        enabled=$(jq -r ".[$idx].enabled // true" "$REALM_RULES_FILE")
                        ping_value=$(realm_ping_host "$remote_host")
                        [[ -z "$ping_value" ]] && ping_value="超时/N/A"
                        tcp_bytes=$(realm_get_traffic_bytes "$listen_port" tcp)
                        udp_bytes=$(realm_get_traffic_bytes "$listen_port" udp)
                        total_bytes=$((tcp_bytes + udp_bytes))
                        tcp_state=$(ss -lnt 2>/dev/null | awk -v p=":$listen_port" '$4 ~ p"$" {found=1} END{print found?"运行中":"-"}')
                        udp_state=$(ss -lnu 2>/dev/null | awk -v p=":$listen_port" '$4 ~ p"$" {found=1} END{print found?"运行中":"-"}')
                        echo -e "  ${G}● ${remark}${NC}"
                        echo -e "    规则      : ${G}${listen_host}:${listen_port}${NC} → ${G}${remote_host}:${remote_port}${NC}"
                        echo -e "    状态      : $( [[ "$enabled" == "true" ]] && echo 运行中 || echo 已禁用 )"
                        echo -e "    总流量    : $(format_bytes "$total_bytes")"
                        echo -e "    TCP / UDP : $(format_bytes "$tcp_bytes") / $(format_bytes "$udp_bytes")"
                        echo -e "    Ping      : ${ping_value}"
                        echo -e "    监听端口  : ${listen_port}"
                        echo -e "    监听状态  : TCP ${tcp_state} / UDP ${udp_state}"
                        echo -e "    协议      : ${transport}"
                        echo ""
                    done
                fi
                _line
                _pause
                ;;
            2)
                _header
                echo -e "  ${W}Realm 最近日志${NC}"
                _line
                if [[ "$DISTRO" == "alpine" ]]; then
                    rc-service "$REALM_SVC" status 2>/dev/null || true
                else
                    journalctl -u "$REALM_SVC" -n 50 --no-pager 2>/dev/null || true
                fi
                _pause
                ;;
            3)
                _header
                echo -e "  ${W}重启转发服务${NC}"
                _line
                if realm_restart_service; then
                    _ok "重启完成"
                else
                    _err "重启失败"
                fi
                _pause
                ;;
            0) return ;;
            *) _err "无效选择"; _pause ;;
        esac
    done
}

iperf3_status_menu() {
    _header
    echo -e "  ${W}iPerf3 状态${NC}"
    _line
    local iperf_pid=""
    [[ -f "$CFG/iperf3.pid" ]] && iperf_pid=$(cat "$CFG/iperf3.pid" 2>/dev/null)
    if [[ "$iperf_pid" =~ ^[0-9]+$ ]] && kill -0 "$iperf_pid" 2>/dev/null; then
        echo -e "  ${C}服务状态:${NC} ${G}运行中${NC}"
        echo ""
        ss -tulnp 2>/dev/null | grep iperf3 | sed 's/^/  /'
    else
        echo -e "  ${C}服务状态:${NC} ${D}未运行${NC}"
    fi
    _line
}

stop_iperf3_server_menu() {
    _header
    echo -e "  ${W}停止 iPerf3 服务端${NC}"
    _line
    local iperf_pid=""
    [[ -f "$CFG/iperf3.pid" ]] && iperf_pid=$(cat "$CFG/iperf3.pid" 2>/dev/null)
    if [[ "$iperf_pid" =~ ^[0-9]+$ ]] && kill -0 "$iperf_pid" 2>/dev/null; then
        kill "$iperf_pid" 2>/dev/null || true
        sleep 1
        rm -f "$CFG/iperf3.pid"
        _ok "iPerf3 服务端已停止"
    else
        _warn "当前没有运行中的 iPerf3 服务端"
    fi
}

start_iperf3_server_menu() {
    check_cmd iperf3 || {
        _info "安装 iPerf3..."
        case "$DISTRO" in
            alpine) apk add --no-cache iperf3 >/dev/null 2>&1 ;;
            centos) yum install -y iperf3 >/dev/null 2>&1 ;;
            debian|ubuntu) apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iperf3 >/dev/null 2>&1 ;;
        esac
    }
    check_cmd iperf3 || { _err "iPerf3 安装失败"; return 1; }
    local listen_host listen_port
    read -rp "  监听地址 [0.0.0.0]: " listen_host
    listen_host="${listen_host:-0.0.0.0}"
    read -rp "  监听端口 [5201]: " listen_port
    listen_port="${listen_port:-5201}"
    _is_valid_domain_or_ip "$listen_host" || { _err "监听地址格式无效"; return 1; }
    _is_valid_port "$listen_port" || { _err "监听端口必须是 1-65535 的整数"; return 1; }
    if pgrep -x iperf3 >/dev/null 2>&1 && [[ ! -f "$CFG/iperf3.pid" ]]; then
        _err "检测到非本脚本管理的 iPerf3 进程，拒绝终止或覆盖"
        return 1
    fi
    if [[ -f "$CFG/iperf3.pid" ]]; then
        local old_iperf_pid
        old_iperf_pid=$(cat "$CFG/iperf3.pid" 2>/dev/null)
        [[ "$old_iperf_pid" =~ ^[0-9]+$ ]] && kill "$old_iperf_pid" 2>/dev/null || true
        rm -f "$CFG/iperf3.pid"
    fi
    if [[ "$listen_host" == "0.0.0.0" ]]; then
        iperf3 -s -D -p "$listen_port" --pidfile "$CFG/iperf3.pid"
    else
        nohup iperf3 -s -B "$listen_host" -p "$listen_port" >"$CFG/iperf3-server.log" 2>&1 < /dev/null &
        printf '%s\n' "$!" >"$CFG/iperf3.pid"
    fi
    sleep 1
    local server_ip
    server_ip=$(get_ipv4)
    [[ -z "$server_ip" ]] && server_ip=$(get_ipv6)
    _ok "iPerf3 服务端已启动: ${listen_host}:${listen_port}"
    echo -e "  ${Y}后台运行中${NC}，不会在按回车后自动停止。"
    echo ""
    echo -e "  ${Y}客户端 TCP 上行测试:${NC}"
    echo -e "  ${G}iperf3 -c ${server_ip} -p ${listen_port} -t 10${NC}"
    echo -e "  ${Y}客户端 TCP 下行测试:${NC}"
    echo -e "  ${G}iperf3 -c ${server_ip} -p ${listen_port} -R -t 10${NC}"
    echo -e "  ${Y}客户端 UDP 上行测试:${NC}"
    echo -e "  ${G}iperf3 -c ${server_ip} -p ${listen_port} -u -b 200M -t 10${NC}"
}

manage_port_forwarding() {
    while true; do
        _header
        echo -e "  ${W}端口转发${NC}"
        _line
        _item "1" "新建转发规则"
        _item "2" "查看转发规则"
        _item "3" "删除转发规则"
        _item "4" "转发状态 / 日志"
        _item "5" "启动 iPerf3 服务端"
        _item "6" "查看 iPerf3 状态"
        _item "7" "停止 iPerf3 服务端"
        _item "0" "返回"
        _line
        read -rp "  请选择: " choice
        case "$choice" in
            1) realm_add_rule; _pause ;;
            2) realm_list_rules; _pause ;;
            3) realm_delete_rule; _pause ;;
            4) realm_status_logs_menu ;;
            5) start_iperf3_server_menu; _pause ;;
            6) iperf3_status_menu; _pause ;;
            7) stop_iperf3_server_menu; _pause ;;
            0) return ;;
            *) _err "无效选择" ;;
        esac
    done
}

run_nftables_port_forwarding() {
    _header
    echo -e "  ${W}nftables 端口转发${NC}"
    _line

    local script_url="https://raw.githubusercontent.com/${SCRIPT_SOURCE_REPO}/${SCRIPT_SOURCE_REF}/nft.sh"
    local script_path="$CFG/tools/nft.sh"
    mkdir -p "$CFG/tools" || return 1
    local staged=""
    staged=$(mktemp "${TMPDIR:-/tmp}/nft-forward.XXXXXX") || {
        _err "无法创建 nftables 脚本临时文件"
        return 1
    }

    _info "下载 nftables 端口转发脚本..."
    if ! curl -fL --connect-timeout 10 --max-time 120 --retry 2 \
        "$script_url" -o "$staged"; then
        rm -f "$staged"
        _err "nft.sh 下载失败"
        return 1
    fi
    if [[ ! -s "$staged" ]]; then
        rm -f "$staged"
        _err "下载的 nft.sh 为空，已拒绝执行"
        return 1
    fi
    if ! _verify_github_blob "$SCRIPT_SOURCE_REPO" "$SCRIPT_SOURCE_REF" "nft.sh" "$staged"; then
        rm -f "$staged"
        _err "nft.sh 与 GitHub 仓库内容校验不一致，已拒绝执行"
        return 1
    fi
    if ! mv -f "$staged" "$script_path" || ! chmod +x "$script_path"; then
        rm -f "$staged"
        _err "nft.sh 保存或授权失败"
        return 1
    fi

    _ok "nft.sh 下载并校验完成"
    "$script_path"
}

manage_port_forwarding_backends() {
    while true; do
        _header
        echo -e "  ${W}端口转发${NC}"
        _line
        _item "1" "Realm 转发"
        _item "2" "nftables 转发"
        _item "0" "返回"
        _line
        read -rp "  请选择: " choice
        case "$choice" in
            1) manage_port_forwarding ;;
            2) run_nftables_port_forwarding; _pause ;;
            0) return ;;
            *) _err "无效选择" ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════════════
# 脚本更新与主入口
#═══════════════════════════════════════════════════════════════════════════════

select_script_update_channel() {
    _header
    echo -e "  ${W}脚本更新渠道${NC}"
    _line
    _item "1" "稳定版 ${D}(main，默认)${NC}"
    _item "2" "测试版 ${Y}(dev)${NC}"
    _item "0" "返回"
    _line

    local choice
    while true; do
        read -rp "  请选择更新渠道 [1]: " choice || return 1
        choice="${choice:-1}"
        case "$choice" in
            1) SELECTED_SCRIPT_UPDATE_CHANNEL="stable"; return 0 ;;
            2) SELECTED_SCRIPT_UPDATE_CHANNEL="dev"; return 0 ;;
            0) return 1 ;;
            *) _err "无效选择" ;;
        esac
    done
}

_current_script_path() {
    readlink -f "$0" 2>/dev/null
}

_system_script_path() {
    printf '%s\n' /usr/local/bin/sing-lite.sh
}

_script_update_is_available() {
    local channel="$1" current_file="$2" remote_file="$3" remote_ver="$4"
    case "$channel" in
        stable) _version_gt "$remote_ver" "$VERSION" ;;
        dev) ! cmp -s "$current_file" "$remote_file" ;;
        *) return 1 ;;
    esac
}

# 在目标文件所在目录创建已校验的更新副本，确保最终 mv 不跨文件系统。
_stage_script_update() {
    local source_file="$1" target_file="$2" mode="${3:-755}" staged
    staged=$(mktemp "${target_file}.update.XXXXXX" 2>/dev/null) || return 1
    if [[ "$mode" == preserve ]]; then
        cp -p "$source_file" "$staged" 2>/dev/null || { rm -f "$staged"; return 1; }
    elif [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
        install -m "$mode" "$source_file" "$staged" 2>/dev/null || { rm -f "$staged"; return 1; }
    else
        rm -f "$staged"
        return 1
    fi
    if ! bash -n "$staged"; then
        rm -f "$staged"
        return 1
    fi
    printf '%s\n' "$staged"
}

# 返回 0 表示已更新，2 表示无需更新或用户取消，1 表示更新失败。
_update_script_from_channel() {
    local channel="$1" ref channel_label prompt
    local tmp_file="" remote_ver="" downloaded_ver="" script_path system_script system_target
    local script_stage="" system_stage="" rollback_stage="" resolved_system="" sync_system=false
    ref=$(_script_update_ref "$channel") || { _err "未知脚本更新渠道: $channel"; return 1; }
    [[ "$channel" == dev ]] && channel_label="测试版 (dev)" || channel_label="稳定版 (main)"

    _header
    echo -e "  ${W}脚本更新 - ${channel_label}${NC}"
    _line
    echo -e "  当前版本: ${G}v${VERSION}${NC}"
    _info "检查${channel_label}..."

    script_path=$(_current_script_path)
    if [[ -z "$script_path" || ! -f "$script_path" ]]; then
        _err "无法确定当前脚本路径"
        return 1
    fi

    if [[ "$channel" == stable ]]; then
        remote_ver=$(_get_latest_script_version_from_raw "$ref")
        if [[ -z "$remote_ver" ]]; then
            _err "无法获取远程版本信息"
            return 1
        fi
        echo -e "  最新版本: ${C}v${remote_ver}${NC}"
        if ! _script_update_is_available "$channel" "$script_path" "$script_path" "$remote_ver"; then
            _ok "已是最新稳定版"
            return 2
        fi
        prompt="发现新稳定版本，是否更新? [Y/n]: "
    else
        tmp_file=$(_fetch_script_tmp 10 "" "$ref")
        if [[ -z "$tmp_file" || ! -f "$tmp_file" ]]; then
            _err "下载测试版失败，请检查网络连接或 dev 分支"
            return 1
        fi
        remote_ver=$(_extract_script_version "$tmp_file")
        if [[ -z "$remote_ver" || ! "$remote_ver" =~ ^[0-9A-Za-z._-]+$ ]]; then
            rm -f "$tmp_file"
            _err "测试版脚本缺少有效版本标识，已拒绝更新"
            return 1
        fi
        echo -e "  测试渠道: ${Y}dev${NC}"
        echo -e "  远程版本: ${C}v${remote_ver}${NC}"
        if ! _script_update_is_available "$channel" "$script_path" "$tmp_file" "$remote_ver"; then
            rm -f "$tmp_file"
            _ok "当前脚本内容已与 dev 分支一致"
            return 2
        fi
        _warn "测试版可能包含尚未稳定的功能，请确认已了解风险"
        prompt="发现 dev 分支新内容，是否更新? [Y/n]: "
    fi

    _line
    local confirm=""
    if ! read -rp "  $prompt" confirm; then
        [[ -n "$tmp_file" ]] && rm -f "$tmp_file"
        _warn "未读取到更新确认，已取消"
        return 2
    fi
    if [[ "$confirm" =~ ^[nN]$ ]]; then
        [[ -n "$tmp_file" ]] && rm -f "$tmp_file"
        return 2
    fi

    _info "更新中..."
    if [[ -z "$tmp_file" ]]; then
        tmp_file=$(_fetch_script_tmp 10 "" "$ref")
    fi
    if [[ -z "$tmp_file" || ! -f "$tmp_file" ]]; then
        _err "下载失败，请检查网络连接"
        return 1
    fi
    downloaded_ver=$(_extract_script_version "$tmp_file")
    if [[ -z "$downloaded_ver" || ! "$downloaded_ver" =~ ^[0-9A-Za-z._-]+$ ]]; then
        rm -f "$tmp_file"
        _err "下载脚本缺少有效版本标识，已拒绝更新"
        return 1
    fi
    if [[ "$channel" == stable ]] && ! _version_gt "$downloaded_ver" "$VERSION"; then
        rm -f "$tmp_file"
        _ok "下载内容不是更高版本，已取消替换"
        return 2
    fi
    remote_ver="$downloaded_ver"
    SCRIPT_REMOTE_VERSION="$remote_ver"

    system_script=$(_system_script_path)
    system_target="$system_script"
    if [[ -e "$system_script" || -L "$system_script" ]]; then
        resolved_system=$(readlink -f "$system_script" 2>/dev/null || true)
        [[ -n "$resolved_system" ]] && system_target="$resolved_system"
        if [[ "$system_target" != "$script_path" && -f "$system_target" ]]; then
            sync_system=true
        fi
    fi

    script_stage=$(_stage_script_update "$tmp_file" "$script_path") || {
        rm -f "$tmp_file"
        _err "无法在当前脚本目录暂存更新"
        return 1
    }
    if [[ "$sync_system" == true ]]; then
        system_stage=$(_stage_script_update "$tmp_file" "$system_target") || {
            rm -f "$tmp_file" "$script_stage"
            _err "无法在系统脚本目录暂存更新"
            return 1
        }
    fi
    if ! cp -p "$script_path" "${script_path}.bak" 2>/dev/null; then
        rm -f "$tmp_file" "$script_stage" "$system_stage"
        _err "无法备份当前脚本，已取消更新"
        return 1
    fi
    rm -f "$tmp_file"

    if ! mv -f "$script_stage" "$script_path"; then
        rm -f "$script_stage" "$system_stage"
        _err "当前脚本替换失败"
        return 1
    fi
    if [[ "$sync_system" == true ]] && ! mv -f "$system_stage" "$system_target"; then
        rm -f "$system_stage"
        rollback_stage=$(_stage_script_update "${script_path}.bak" "$script_path" preserve 2>/dev/null || true)
        if [[ -n "$rollback_stage" ]] && mv -f "$rollback_stage" "$script_path"; then
            _err "系统目录脚本同步失败，当前脚本已回滚"
        else
            rm -f "$rollback_stage"
            _err "系统目录脚本同步与自动回滚均失败，原脚本备份位于 ${script_path}.bak"
        fi
        return 1
    fi
    [[ "$sync_system" == true ]] && _info "已同步更新系统目录脚本"

    _ok "更新成功! v${VERSION} -> v${remote_ver} (${channel_label})"
    echo ""
    echo -e "  ${C}请重新运行脚本以使用新版本${NC}"
    echo -e "  ${D}备份文件: ${script_path}.bak${NC}"
    _line
    return 0
}

do_update() {
    local channel="${1:-}" rc
    if [[ -z "$channel" ]]; then
        select_script_update_channel || return 0
        channel="$SELECTED_SCRIPT_UPDATE_CHANNEL"
    fi

    if _update_script_from_channel "$channel"; then
        exit 0
    else
        rc=$?
    fi
    [[ $rc -eq 2 ]] && return 0
    return "$rc"
}

main_menu() {
    check_root
    init_log  # 初始化日志
    init_db   # 初始化 JSON 数据库
    db_migrate_to_multiuser  # 迁移旧的单用户配置到多用户格式
    ensure_singbox_runtime_consistency 2>/dev/null || true

    # 自动更新系统脚本 (确保 sing 命令始终是最新版本)
    _auto_update_system_script

    # 兼容旧定时规则：补齐 cron PATH，并确认守护进程确实运行。
    repair_scheduled_jobs



    _check_script_update || _warn "脚本更新检查失败，请稍后重试"

    while true; do
        _header
        echo -e "  ${W}服务端管理${NC}"

        # 获取系统版本信息
        local os_version="$DISTRO"
        if [[ -f /etc/os-release ]]; then
            local version_id=$(grep "^VERSION_ID=" /etc/os-release | cut -d'=' -f2 | tr -d '"')
            [[ -n "$version_id" ]] && os_version="$DISTRO $version_id"
        elif [[ -f /etc/lsb-release ]]; then
            local version_id=$(grep "^DISTRIB_RELEASE=" /etc/lsb-release | cut -d'=' -f2)
            [[ -n "$version_id" ]] && os_version="$DISTRO $version_id"
        fi

        # 获取内核版本
        local kernel_version=$(uname -r)


        # 获取核心版本及状态（使用公共方法）
        local singbox_ver_with_status
        singbox_ver_with_status=$(_get_core_version "sing-box")
        local script_update_ver=""
        if _has_script_update; then
            script_update_ver=$(_get_script_update_info)
        fi

        # 显示版本信息（已包含状态标识）
        echo -e "  ${D}系统: ${os_version} | ${kernel_version}${NC}"
        echo -e "  ${D}核心: Sing-box ${singbox_ver_with_status}${NC}"
        if [[ -n "$script_update_ver" ]]; then
            echo -e "  ${Y}提示: 脚本有新版本 v${script_update_ver}，可在菜单选择「检查脚本更新」${NC}"
        fi
        echo ""
        show_status
        echo ""
        _line

        # 复用 show_status 缓存的结果，避免重复查询数据库
        local installed="$_INSTALLED_CACHE"
        if [[ -n "$installed" ]]; then
            # 多协议服务端菜单
            _item "1" "安装新协议 (多协议共存)"
            _item "2" "核心版本管理 (Sing-box/Snell v5/v6)"
            _item "3" "卸载指定协议"
            _item "4" "用户管理 (多用户/到期/通知)"
            echo -e "  ${D}───────────────────────────────────────────${NC}"
            _item "5" "查看协议配置"
            _item "6" "订阅服务管理"
            _item "7" "管理协议服务"
            _item "8" "分流管理"
            _item "9" "端口转发"
            echo -e "  ${D}───────────────────────────────────────────${NC}"
            _item "10" "BBR 网络优化"
            _item "11" "查看运行日志"
            echo -e "  ${D}───────────────────────────────────────────${NC}"
            local script_update_item="检查脚本更新"
            [[ -n "$script_update_ver" ]] && script_update_item="检查脚本更新 ${Y}[有更新 v${script_update_ver}]${NC}"
            _item "12" "$script_update_item"
            _item "13" "完全卸载"
        else
            _item "1" "安装协议"
            echo -e "  ${D}───────────────────────────────────────────${NC}"
            _item "2" "端口转发"
            _item "3" "BBR 网络优化"
            echo -e "  ${D}───────────────────────────────────────────${NC}"
            local script_update_item="检查脚本更新"
            [[ -n "$script_update_ver" ]] && script_update_item="检查脚本更新 ${Y}[有更新 v${script_update_ver}]${NC}"
            _item "4" "$script_update_item"
        fi
        _item "0" "退出"
        _line

        read -rp "  请选择: " choice || exit 0

        local skip_pause=false
        if [[ -n "$installed" ]]; then
            case $choice in
                1) do_install_server; skip_pause=true ;;
                2) update_core_menu; skip_pause=true ;;
                3) uninstall_specific_protocol; skip_pause=true ;;
                4) manage_users; skip_pause=true ;;
                5) show_all_protocols_info; skip_pause=true ;;
                6) manage_subscription; skip_pause=true ;;
                7) manage_protocol_services; skip_pause=true ;;
                8) manage_routing; skip_pause=true ;;
                9) manage_port_forwarding_backends; skip_pause=true ;;
                10) enable_bbr; skip_pause=true ;;
                11) show_logs; skip_pause=true ;;
                12) do_update ;;
                13) do_uninstall ;;
                0) exit 0 ;;
                *) _err "无效选择"; skip_pause=true ;;
            esac
        else
            case $choice in
                1) do_install_server; skip_pause=true ;;
                2) manage_port_forwarding_backends; skip_pause=true ;;
                3) enable_bbr; skip_pause=true ;;
                4) do_update ;;
                0) exit 0 ;;
                *) _err "无效选择"; skip_pause=true ;;
            esac
        fi
        [[ "$skip_pause" == "false" ]] && _pause
    done
}

# 命令行参数处理
dispatch_cli() {
    case "${1:-}" in
    --tg-bot-poll)
        # 处理 Telegram 用户机器人消息（由 cron 每分钟调用）
        check_root
        init_db
        init_tg_config
        tg_poll_user_bot
        exit $?
        ;;
    --check-expire)
        # 检查并禁用过期用户，发送提醒
        check_root
        init_db
        echo "检查用户到期状态..."
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 开始过期检查..." >> "$CFG/expire.log"
        # 发送即将过期提醒 (3天内)
        warnings=$(send_expire_warnings 3)
        echo "  发送 $warnings 条过期提醒" >> "$CFG/expire.log"
        # 禁用过期用户
        if [[ "${2:-}" == "--notify" ]]; then
            disabled=$(check_and_disable_expired_users --notify)
        else
            disabled=$(check_and_disable_expired_users)
        fi
        echo "  禁用 $disabled 个过期用户" >> "$CFG/expire.log"
        # 输出结果到终端
        echo "  即将过期提醒: $warnings 条"
        echo "  禁用过期用户: $disabled 个"
        echo "完成。日志: $CFG/expire.log"
        exit 0
        ;;
    --setup-expire-cron)
        # 安装过期检查定时任务
        check_root
        init_db
        install_expire_check_cron
        exit 0
        ;;
    --update-dev)
        # 从 dev 分支检查并安装测试版脚本。
        check_root
        init_log
        do_update dev
        exit $?
        ;;
    --help|-h)
        echo "用法: $0 [选项]"
        echo ""
        echo "选项:"
        echo "  --update-dev         从 dev 分支检查并升级测试版脚本"
        echo "  --tg-bot-poll        处理 Telegram 用户机器人消息 (用于定时任务)"
        echo "  --check-expire       检查并禁用过期用户 (用于定时任务)"
        echo "  --setup-expire-cron  安装过期检查定时任务"
        echo "  --help, -h           显示帮助信息"
        echo ""
        echo "无参数时启动交互式菜单"
        exit 0
        ;;
    "")
        # 无参数，启动主菜单
        main_menu
        ;;
    *)
        echo "未知参数: $1"
        echo "使用 --help 查看帮助"
        exit 1
        ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    dispatch_cli "$@"
fi
