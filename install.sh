#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155,SC1091,SC1111
# =====================================================================
#  xray-manager —— Xray 一键安装 / 管理脚本
#
#  · 协议: VLESS (REALITY / XHTTP / Vision / TLS / Encryption / WS)、VMess、
#          Trojan、Shadowsocks、Hysteria2、SOCKS5/HTTP、端口转发
#  · 每个节点独立入站, 端口 / 监听地址 / 用户 / SNI / 路径等随时可改
#  · 落地(出站)管理: 分享链接导入 / SOCKS5 / HTTP / SS / WireGuard / WARP,
#    按节点、按用户、按域名分流, 全局默认落地, 链式代理, 出口测试
#  · 兼容 Alpine (OpenRC + BusyBox)、Debian/Ubuntu、RHEL 系、Fedora、Arch、
#    openSUSE; systemd / OpenRC / 无 init (容器) 环境均可运行
#  · 配置字段按 Xray 最新文档编写, 同时兼容 v26.3.x 正式版与 v26.9.x 预发布版
#
#  用法: bash install.sh            (全新 Alpine 可直接: sh install.sh)
#        安装后快捷命令: xr         (命令行用法: xr help)
#
#  项目地址: https://github.com/l1uz3/xray-manager
#  MIT License · Copyright (c) 2026 流泽
# =====================================================================

# ---------------------------------------------------------------------
# 引导段 —— 必须保持 POSIX sh 语法 (Alpine 的 BusyBox ash 会先执行到这里)
# ---------------------------------------------------------------------
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            echo "[引导] 检测到 Alpine / BusyBox 环境, 正在安装 bash ..."
            apk add --no-cache bash >/dev/null 2>&1 || {
                echo "bash 安装失败, 请先手动执行: apk add bash"
                exit 1
            }
        else
            echo "本脚本需要 bash, 请先安装 bash 后重试"
            exit 1
        fi
    fi
    if [ -f "$0" ] && [ -r "$0" ]; then
        exec bash "$0" "$@"
    fi
    echo "bash 已就绪, 但当前脚本是通过管道运行的, 无法自动切换, 请改用:"
    echo "  wget -O install.sh https://raw.githubusercontent.com/l1uz3/xray-manager/main/install.sh && sh install.sh"
    exit 1
fi

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "需要 bash 4.0 及以上版本 (当前: $BASH_VERSION)"
    exit 1
fi

# ---------------------------------------------------------------------
# 常量 (均可用环境变量覆盖)
# ---------------------------------------------------------------------
SCRIPT_VERSION="1.0.0"
SCRIPT_URL="${XRAY_SCRIPT_URL:-https://raw.githubusercontent.com/l1uz3/xray-manager/main/install.sh}"
SHORTCUT="${XRAY_SHORTCUT:-/usr/local/bin/xr}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_ASSET_DIR="${XRAY_ASSET_DIR:-/usr/local/share/xray}"
CONFIG_FILE="${XRAY_CONFIG_FILE:-/usr/local/etc/xray/config.json}"
CONFIG_DIR="${CONFIG_FILE%/*}"
DATA_DIR="${XRAY_SCRIPT_DATA:-/usr/local/etc/xray-script}"
META_FILE="$DATA_DIR/meta.json"
LINK_FILE="${XRAY_URL_FILE:-$DATA_DIR/links.txt}"
CERT_DIR="$DATA_DIR/certs"
BACKUP_DIR="$DATA_DIR/backup"
LOG_DIR="${XRAY_LOG_DIR:-/var/log/xray}"
SYSTEMD_UNIT="/etc/systemd/system/xray.service"
OPENRC_INIT="/etc/init.d/xray"
PID_FILE="/run/xray.pid"
BBR_SYSCTL="/etc/sysctl.d/99-xray-bbr.conf"
ACME_SH="${HOME:-/root}/.acme.sh/acme.sh"
SVC_MARK="# managed-by: xray-script"
GEO_CRON_TAG="# xray-script-geo"
XS_NO_RESTART="${XS_NO_RESTART:-0}"        # 测试用: 1 = 只写配置, 不重启服务
XS_SKIP_CHECK="${XS_SKIP_CHECK:-0}"        # 测试用: 1 = 跳过 REALITY 目标联网检测

BANNER=$(cat <<'EOF'
__  ______
\ \/ /  _ \    Xray Manager
 \  /| |_) |   多协议 · 多节点 · 落地分流
 /  \|  _ <    github.com/l1uz3/xray-manager
/_/\_\_| \_\
EOF
)

if [[ -t 2 ]]; then
    red=$'\e[91m' green=$'\e[92m' yellow=$'\e[93m' magenta=$'\e[95m'
    cyan=$'\e[96m' gray=$'\e[90m' bold=$'\e[1m' none=$'\e[0m'
else
    red='' green='' yellow='' magenta='' cyan='' gray='' bold='' none=''
fi

# 全局状态
declare -A Q=()
OS_ID="" OS_NAME="" PKG="" INIT="none" PKG_UPDATED=0
WORK_DIR="" TEST_PID="" CFG_WORK=""
NEW_TAG="" NEW_PORT="" NEW_LISTEN="" NEW_L4="" NEW_IB="" NEW_META="{}"
PICKED_OUT="" PICKED_NODE="" PICKED_USER="" LANDING_NEW_TAG="" RENAMED_TAG=""
CERT_FILE="" KEY_FILE="" CERT_DOMAIN="" CERT_SELF=0
REALITY_SNI="" REALITY_TARGET="" REALITY_PRIV="" REALITY_PUB=""
ENC_DEC="" ENC_ENC="" MLDSA_SEED="" MLDSA_VERIFY=""
declare -a NODE_TAGS=() USER_LIST=() LANDING_TAGS=()

# ---------------------------------------------------------------------
# 输出 / 交互 (提示信息统一走 stderr, 便于 $(...) 取值)
# ---------------------------------------------------------------------
say() { printf '%s\n' "$*" >&2; }
info() { printf '%s\n' "${yellow}$*${none}" >&2; }
ok() { printf '%s\n' "${green}$*${none}" >&2; }
err() { printf '%s\n' "${red}$*${none}" >&2; }
warn() { printf '\n%s\n\n' "${yellow}$*${none}" >&2; }
error() { printf '\n%s\n\n' "${red}输入错误!${none}" >&2; }
die() {
    err "$*"
    exit 1
}
hr() { say "${gray}------------------------------------------------------------${none}"; }
title() {
    say ""
    say "${cyan}${bold}========== $* ==========${none}"
}

cleanup() {
    [[ -n $TEST_PID ]] && kill "$TEST_PID" 2>/dev/null
    [[ -n $WORK_DIR && -d $WORK_DIR ]] && rm -rf "$WORK_DIR"
}
init_workdir() {
    [[ -n $WORK_DIR && -d $WORK_DIR ]] && return 0
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xray-script.XXXXXX") || die "无法创建临时目录"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}
tmpf() { mktemp "$WORK_DIR/t.XXXXXX"; }

ask() { # 提示 [默认值]
    local prompt=$1 def=${2-} v
    [[ -n $def ]] && prompt+=" (默认 ${cyan}${def}${none})"
    if ! read -r -p "${prompt}: " v; then
        printf '\n' >&2
        err "输入已结束, 退出"
        kill -TERM $$ 2>/dev/null # 通知主进程退出; 各层 $(...) 通过 "|| exit 1" 逐级退出
        exit 1
    fi
    [[ -z $v ]] && v=$def
    printf '%s' "$v"
}
ask_required() { # 不允许为空, 会去掉所有空白
    local v
    while :; do
        v=$(ask "$1" "${2-}") || exit 1
        v=${v//[[:space:]]/}
        [[ -n $v ]] && {
            printf '%s' "$v"
            return 0
        }
        error
    done
}
ask_choice() { # 提示 默认 最小 最大
    local v
    while :; do
        v=$(ask "$1 [$3-$4]" "$2") || exit 1
        if [[ $v =~ ^[0-9]+$ ]] && ((10#$v >= $3 && 10#$v <= $4)); then
            printf '%s' "$((10#$v))"
            return 0
        fi
        error
    done
}
ask_yn() { # 提示 默认(y/n); 返回 0 表示"是"
    local v
    while :; do
        v=$(ask "$1 [y/n]" "${2:-n}") || exit 1
        case ${v,,} in
            y | yes) return 0 ;;
            n | no) return 1 ;;
        esac
        error
    done
}
confirm_word() { # 提示 单词
    local v
    v=$(ask "$1 (输入 $2 确认)" "") || exit 1
    [[ $v == "$2" ]]
}

# ---------------------------------------------------------------------
# 校验 / 随机 / 编码
# ---------------------------------------------------------------------
is_port() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
is_uuid() { [[ ${1,,} =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }
is_ipv4() {
    [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local i
    for i in 1 2 3 4; do ((10#${BASH_REMATCH[i]} <= 255)) || return 1; done
}
is_ipv6() { [[ $1 == *:* && $1 =~ ^[0-9A-Fa-f:.]+$ ]]; }
is_ip() { is_ipv4 "$1" || is_ipv6 "$1"; }
is_domain() { [[ $1 =~ ^([A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]{0,62}$ ]]; }
is_name() { # 标签 / 用户名 / 密码允许的字符
    [[ -n $1 && ${#1} -le 64 ]] || return 1
    case $1 in
        *[[:space:]]* | *\"* | *\'* | *\\* | *'#'* | *%* | */* | *,* | *'`'* | *'$'* | *'?'* | *'&'*) return 1 ;;
    esac
    return 0
}
rand_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
rand_str() {
    local n=${1:-16} s=""
    while ((${#s} < n)); do s+=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9'); done
    printf '%s' "${s:0:n}"
}
rand_lower() { rand_str "${1:-10}" | tr 'A-Z' 'a-z'; }
rand_path() { printf '/%s' "$(rand_lower "${1:-10}")"; }
rand_num() { printf '%s' $(($1 + (((RANDOM << 15) | RANDOM) % ($2 - $1 + 1)))); }
gen_uuid() {
    local u=""
    [[ -x $XRAY_BIN ]] && u=$("$XRAY_BIN" uuid 2>/dev/null)
    is_uuid "$u" || u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
    printf '%s' "$u"
}
b64enc() { printf '%s' "$1" | base64 | tr -d '\n'; }
b64url() { b64enc "$1" | tr '/+' '_-' | tr -d '='; }
b64dec() {
    local s
    s=$(printf '%s' "$1" | tr -d ' \r\n' | tr '_-' '/+')
    case $((${#s} % 4)) in
        2) s+="==" ;;
        3) s+="=" ;;
    esac
    printf '%s' "$s" | base64 -d 2>/dev/null
}
urlenc() {
    if [[ $1 =~ ^[A-Za-z0-9._~-]*$ ]]; then
        printf '%s' "$1"
        return
    fi
    jq -rn --arg s "$1" '$s | @uri'
}
urldec() {
    local s=${1//%/\\x}
    printf '%b' "$s"
}
fmt_host() { if [[ $1 == *:* && $1 != \[* ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi; }
human_bytes() {
    awk -v b="${1:-0}" 'BEGIN { split("B KB MB GB TB PB", u, " "); i = 1
        while (b >= 1024 && i < 6) { b = b / 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i]; else printf "%.2f %s", b, u[i] }'
}

# ---------------------------------------------------------------------
# 系统探测 / 依赖安装
# ---------------------------------------------------------------------
detect_system() {
    if [[ -r /etc/os-release ]]; then
        OS_ID=$(. /etc/os-release && printf '%s' "${ID:-linux}")
        OS_NAME=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}")
    else
        OS_ID=linux OS_NAME=Linux
    fi
    PKG=""
    local p
    for p in apk apt-get dnf yum pacman zypper; do
        if command -v "$p" >/dev/null 2>&1; then
            PKG=$p
            break
        fi
    done
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        INIT=systemd
    elif [[ -x /sbin/openrc-run ]] || command -v openrc-run >/dev/null 2>&1; then
        INIT=openrc
    else
        INIT=none
    fi
}

pkg_install() {
    (($#)) || return 0
    info "安装依赖: $*"
    case $PKG in
        apk) apk add --no-cache "$@" ;;
        apt-get)
            if ((PKG_UPDATED == 0)); then
                apt-get update -qq >/dev/null 2>&1 || apt-get update
                PKG_UPDATED=1
            fi
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@"
            ;;
        dnf) dnf install -y "$@" ;;
        yum) yum install -y "$@" || { yum install -y epel-release && yum install -y "$@"; } ;;
        pacman) pacman -Sy --noconfirm --needed "$@" ;;
        zypper) zypper -n install "$@" ;;
        *)
            err "未识别的包管理器, 请手动安装: $*"
            return 1
            ;;
    esac
}
pkg_of() { # 命令名 → 包名
    case $1 in
        qrencode) if [[ $PKG == apk ]]; then echo libqrencode-tools; else echo qrencode; fi ;;
        crontab)
            case $PKG in
                apk) echo busybox ;;
                apt-get) echo cron ;;
                *) echo cronie ;;
            esac
            ;;
        *) echo "$1" ;;
    esac
}
ensure_cmds() { # 命令名...
    local c
    local -a miss=()
    for c in "$@"; do command -v "$c" >/dev/null 2>&1 || miss+=("$(pkg_of "$c")"); done
    ((${#miss[@]})) || return 0
    [[ $PKG == apt-get || $PKG == apk ]] && miss+=(ca-certificates)
    pkg_install "${miss[@]}" >&2
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || {
            err "依赖 $c 安装失败, 请手动安装后重试"
            return 1
        }
    done
}
xray_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo 64 ;;
        i386 | i686) echo 32 ;;
        aarch64 | arm64 | armv8*) echo arm64-v8a ;;
        armv7*) if grep -qw vfp /proc/cpuinfo 2>/dev/null; then echo arm32-v7a; else echo arm32-v5; fi ;;
        armv6*) if grep -qw vfp /proc/cpuinfo 2>/dev/null; then echo arm32-v6; else echo arm32-v5; fi ;;
        armv5*) echo arm32-v5 ;;
        mips64le) echo mips64le ;;
        mips64) echo mips64 ;;
        mipsle) echo mips32le ;;
        mips) echo mips32 ;;
        ppc64le) echo ppc64le ;;
        ppc64) echo ppc64 ;;
        riscv64) echo riscv64 ;;
        s390x) echo s390x ;;
        loongarch64) echo loong64 ;;
        *) return 1 ;;
    esac
}
download() { # 地址 输出文件   (GitHub 地址会自动加上"加速前缀")
    local url=$1 out=$2 proxy
    proxy=$(meta_get '.settings.gh_proxy // ""')
    if [[ -n $proxy && ($url == https://github.com/* || $url == https://raw.githubusercontent.com/*) ]]; then
        url="${proxy%/}/$url"
    fi
    if [[ ${DL_QUIET:-0} == 1 ]]; then
        curl -fsSL --retry 2 --connect-timeout 15 -m 900 -o "$out" "$url"
    else
        curl -fL --retry 2 --connect-timeout 15 -m 900 --progress-bar -o "$out" "$url"
    fi
}
get_ip() { # 4|6
    local v=$1 ip=""
    ip=$(curl -"$v" -fsS -m 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/ { print $2; exit }')
    [[ -z $ip ]] && ip=$(curl -"$v" -fsS -m 5 https://api64.ipify.org 2>/dev/null)
    [[ -z $ip ]] && ip=$(curl -"$v" -fsS -m 5 "https://ipv$v.icanhazip.com" 2>/dev/null)
    ip=${ip//[[:space:]]/}
    if [[ $v == 4 ]]; then is_ipv4 "$ip" || ip=""; else is_ipv6 "$ip" || ip=""; fi
    printf '%s' "$ip"
}
server_addr() { # 分享链接使用的默认地址
    local a
    a=$(meta_get '.settings.address // ""')
    if [[ -z $a ]]; then
        a=$(get_ip 4)
        [[ -z $a ]] && a=$(get_ip 6)
        [[ -n $a ]] && meta_set '.settings.address = $v' --arg v "$a"
    fi
    printf '%s' "${a:-YOUR_SERVER_IP}"
}

# ---------------------------------------------------------------------
# 端口 / 防火墙
# ---------------------------------------------------------------------
port_in_use_sys() { # 端口 tcp|udp   (直接读 /proc, 不依赖 ss/netstat)
    local hex f
    hex=$(printf ':%04X' "$1")
    for f in "/proc/net/$2" "/proc/net/${2}6"; do
        [[ -r $f ]] || continue
        if [[ $2 == tcp ]]; then
            awk -v p="$hex" 'NR > 1 && $4 == "0A" && substr($2, length($2) - 4) == p { f = 1 } END { exit f ? 0 : 1 }' "$f" && return 0
        else
            awk -v p="$hex" 'NR > 1 && substr($2, length($2) - 4) == p { f = 1 } END { exit f ? 0 : 1 }' "$f" && return 0
        fi
    done
    return 1
}
l4_list() {
    case $1 in
        both | tcp,udp | udp,tcp) echo "tcp udp" ;;
        *) echo "${1:-tcp}" ;;
    esac
}
port_busy() { # 端口 l4
    local p
    for p in $(l4_list "$2"); do port_in_use_sys "$1" "$p" && return 0; done
    return 1
}
free_port() { # l4 [首选端口]
    local l4=$1 p=${2:-} i
    if [[ -n $p ]] && ! port_busy "$p" "$l4" && [[ -z $(port_owner "$p" "$l4") ]]; then
        printf '%s' "$p"
        return
    fi
    for ((i = 0; i < 100; i++)); do
        p=$(rand_num 10000 60000)
        if ! port_busy "$p" "$l4" && [[ -z $(port_owner "$p" "$l4") ]]; then break; fi
    done
    printf '%s' "$p"
}
fw_apply() { # open|close 端口 l4    (自动识别 ufw / firewalld / iptables)
    local act=$1 port=$2 l4=$3 p done=""
    [[ $(meta_get '.settings.firewall // "on"') == off ]] && return 0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'status: active'; then
        for p in $(l4_list "$l4"); do
            if [[ $act == open ]]; then ufw allow "$port/$p" >/dev/null 2>&1; else ufw delete allow "$port/$p" >/dev/null 2>&1; fi
        done
        done=ufw
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        for p in $(l4_list "$l4"); do
            if [[ $act == open ]]; then
                firewall-cmd --permanent --add-port="$port/$p" >/dev/null 2>&1
            else
                firewall-cmd --permanent --remove-port="$port/$p" >/dev/null 2>&1
            fi
        done
        firewall-cmd --reload >/dev/null 2>&1
        done=firewalld
    elif command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)|-j (DROP|REJECT)'; then
        for p in $(l4_list "$l4"); do
            fw_ipt "$act" iptables "$p" "$port"
            command -v ip6tables >/dev/null 2>&1 && fw_ipt "$act" ip6tables "$p" "$port"
        done
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1
        elif [[ $INIT == openrc && -x /etc/init.d/iptables ]]; then
            rc-service iptables save >/dev/null 2>&1
            rc-service ip6tables save >/dev/null 2>&1
        elif [[ -f /etc/sysconfig/iptables ]] && command -v service >/dev/null 2>&1; then
            service iptables save >/dev/null 2>&1
        fi
        done=iptables
    fi
    [[ -n $done && $act == open ]] && say "  ${gray}防火墙($done): 已放行端口 $port ($l4)${none}"
    return 0
}
fw_ipt() { # open|close 命令 协议 端口
    if [[ $1 == open ]]; then
        "$2" -C INPUT -p "$3" --dport "$4" -j ACCEPT 2>/dev/null || "$2" -I INPUT -p "$3" --dport "$4" -j ACCEPT 2>/dev/null
    else
        "$2" -D INPUT -p "$3" --dport "$4" -j ACCEPT 2>/dev/null
    fi
    return 0
}

# ---------------------------------------------------------------------
# 服务管理 (systemd / OpenRC / 无 init)
# ---------------------------------------------------------------------
openrc_softlevel() { [[ -e /run/openrc/softlevel ]] || { mkdir -p /run/openrc && touch /run/openrc/softlevel; } 2>/dev/null; }
write_service() {
    mkdir -p "$LOG_DIR"
    case $INIT in
        systemd)
            cat >"$SYSTEMD_UNIT" <<EOF
$SVC_MARK
[Unit]
Description=Xray Service
Documentation=https://xtls.github.io
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$XRAY_BIN run -config $CONFIG_FILE
Restart=on-failure
RestartSec=3
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
            # 官方安装脚本留下的 drop-in 会覆盖 ExecStart, 由本脚本接管后移除
            rm -f /etc/systemd/system/xray.service.d/10-donot_touch_single_conf.conf \
                /etc/systemd/system/xray.service.d/10-donot_touch_multi_conf.conf 2>/dev/null
            systemctl daemon-reload >/dev/null 2>&1
            systemctl enable xray >/dev/null 2>&1
            ;;
        openrc)
            local sup='supervisor="supervise-daemon"'
            command -v supervise-daemon >/dev/null 2>&1 || [[ -x /sbin/supervise-daemon ]] || sup='command_background="yes"'
            cat >"$OPENRC_INIT" <<EOF
#!/sbin/openrc-run
$SVC_MARK
name="xray"
description="Xray Service"
command="$XRAY_BIN"
command_args="run -config $CONFIG_FILE"
pidfile="/run/\${RC_SVCNAME}.pid"
$sup
respawn_delay=3
respawn_max=0
rc_ulimit="-n 1000000"
output_log="$LOG_DIR/stdout.log"
error_log="$LOG_DIR/stdout.log"

depend() {
    after net firewall
    use dns logger
}

start_pre() {
    checkpath -d -m 0755 "$LOG_DIR"
    if ! "$XRAY_BIN" run -test -config "$CONFIG_FILE" >/dev/null 2>&1; then
        eerror "Xray 配置校验失败: $CONFIG_FILE"
        return 1
    fi
}
EOF
            chmod 755 "$OPENRC_INIT"
            openrc_softlevel
            rc-update add xray default >/dev/null 2>&1
            ;;
    esac
    return 0
}
service_ensure() { # 服务文件不存在或不是本脚本生成的 (如官方脚本以 nobody 运行) 时重写
    case $INIT in
        systemd) grep -qF "$SVC_MARK" "$SYSTEMD_UNIT" 2>/dev/null || write_service ;;
        openrc) grep -qF "$SVC_MARK" "$OPENRC_INIT" 2>/dev/null || write_service ;;
    esac
    return 0
}
svc() { # start|stop|restart|status|enable|disable
    case $INIT in
        systemd)
            case $1 in
                enable | disable) systemctl "$1" xray >/dev/null 2>&1 ;;
                status) systemctl status xray --no-pager -l 2>&1 | head -n 15 >&2 ;;
                *) systemctl "$1" xray ;;
            esac
            ;;
        openrc)
            openrc_softlevel
            case $1 in
                enable) rc-update add xray default >/dev/null 2>&1 ;;
                disable) rc-update del xray default >/dev/null 2>&1 ;;
                *) rc-service xray "$1" >&2 ;;
            esac
            ;;
        *) svc_manual "$1" ;;
    esac
}
svc_manual() { # 无 init 系统 (如 Docker 容器) 时用 nohup 管理
    local pid
    case $1 in
        start)
            svc_manual_running && return 0
            mkdir -p "$LOG_DIR"
            nohup "$XRAY_BIN" run -config "$CONFIG_FILE" >>"$LOG_DIR/stdout.log" 2>&1 &
            echo $! >"$PID_FILE"
            ;;
        stop)
            if [[ -f $PID_FILE ]]; then
                pid=$(cat "$PID_FILE" 2>/dev/null)
                if [[ -n $pid ]]; then
                    kill "$pid" 2>/dev/null
                    sleep 0.5
                    kill -9 "$pid" 2>/dev/null
                fi
            fi
            rm -f "$PID_FILE"
            ;;
        restart)
            svc_manual stop
            svc_manual start
            ;;
        status) if svc_manual_running; then say "Xray 运行中 (PID $(cat "$PID_FILE"))"; else say "Xray 未运行"; fi ;;
    esac
    return 0
}
svc_manual_running() { [[ -f $PID_FILE ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; }
xray_alive() {
    local c
    for c in /proc/[0-9]*/comm; do
        [[ $(cat "$c" 2>/dev/null) == xray ]] && return 0
    done 2>/dev/null
    return 1
}
svc_running() {
    case $INIT in
        systemd) systemctl is-active --quiet xray ;;
        openrc) rc-service xray status >/dev/null 2>&1 && xray_alive ;;
        *) svc_manual_running ;;
    esac
}
svc_restart_check() {
    svc restart >/dev/null 2>&1
    sleep 2
    svc_running && xray_alive
}
svc_restart_cmd() {
    case $INIT in
        systemd) echo "systemctl restart xray" ;;
        openrc) echo "rc-service xray restart" ;;
        *) echo "$SHORTCUT restart" ;;
    esac
}
show_start_error() {
    say "${gray}---------------- 最近日志 ----------------${none}"
    if [[ $INIT == systemd ]]; then
        journalctl -u xray -n 12 --no-pager 2>/dev/null >&2
    else
        tail -n 12 "$LOG_DIR/stdout.log" 2>/dev/null >&2
    fi
    tail -n 8 "$LOG_DIR/error.log" 2>/dev/null >&2
}
xray_ver() { [[ -x $XRAY_BIN ]] && "$XRAY_BIN" version 2>/dev/null | awk 'NR == 1 { print $2 }'; }
xray_status_text() {
    if [[ ! -x $XRAY_BIN ]]; then
        echo "${red}未安装${none}"
    elif svc_running; then
        echo "${green}v$(xray_ver) 运行中${none}"
    else
        echo "${yellow}v$(xray_ver) 未运行${none}"
    fi
}

# ---------------------------------------------------------------------
# Xray 内核 / geo 文件 / 脚本自身
# ---------------------------------------------------------------------
latest_version() { # stable|pre   (不依赖 GitHub API, 避免被限流)
    local v="" proxy
    if [[ $1 == pre ]]; then
        v=$(curl -fsS -m 10 "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=1" 2>/dev/null | jq -r '.[0].tag_name // empty' 2>/dev/null)
        [[ -z $v ]] && v=$(curl -fsSL -m 15 "https://github.com/XTLS/Xray-core/releases.atom" 2>/dev/null |
            grep -o 'releases/tag/v[0-9][0-9.]*' | head -n 1 | sed 's#releases/tag/##')
    else
        v=$(curl -fsS -m 10 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
        [[ -z $v ]] && v=$(curl -sS -m 15 -o /dev/null -w '%{redirect_url}' "https://github.com/XTLS/Xray-core/releases/latest" 2>/dev/null |
            grep -o 'v[0-9][0-9.]*$')
    fi
    if [[ -z $v ]]; then
        proxy=$(meta_get '.settings.gh_proxy // ""')
        [[ -n $proxy ]] && v=$(curl -fsSL -m 20 "${proxy%/}/https://github.com/XTLS/Xray-core/releases.atom" 2>/dev/null |
            grep -o 'releases/tag/v[0-9][0-9.]*' | head -n 1 | sed 's#releases/tag/##')
    fi
    printf '%s' "$v"
}
install_xray() { # [版本号]
    ensure_cmds curl jq unzip || return 1
    local ver=${1:-} arch dir got want n
    arch=$(xray_arch) || {
        err "不支持的 CPU 架构: $(uname -m)"
        return 1
    }
    if [[ -z $ver ]]; then
        info "正在获取最新正式版版本号..."
        ver=$(latest_version stable)
        [[ -z $ver ]] && ver=$(ask_required "获取失败 (国内机器可在 系统工具→脚本设置 中配置 GitHub 加速), 请手动输入版本号, 如 v26.3.27")
    fi
    [[ $ver == v* ]] || ver="v$ver"
    dir=$(mktemp -d "$WORK_DIR/dl.XXXXXX")
    info "下载 Xray $ver (linux-$arch) ..."
    if ! download "https://github.com/XTLS/Xray-core/releases/download/$ver/Xray-linux-$arch.zip" "$dir/xray.zip"; then
        err "下载失败, 请检查网络或版本号 (国内机器可在 系统工具→脚本设置 中配置 GitHub 加速)"
        return 1
    fi
    if DL_QUIET=1 download "https://github.com/XTLS/Xray-core/releases/download/$ver/Xray-linux-$arch.zip.dgst" "$dir/xray.dgst"; then
        want=$(awk -F'= *' '/^SHA2-256/ { print tolower($2); exit }' "$dir/xray.dgst")
        got=$(sha256sum "$dir/xray.zip" | awk '{ print $1 }')
        if [[ -n $want && $want != "$got" ]]; then
            err "SHA256 校验失败, 文件可能损坏或被篡改"
            return 1
        fi
        [[ -n $want ]] && ok "SHA256 校验通过"
    else
        warn "未能获取校验文件, 跳过 SHA256 校验"
    fi
    unzip -oq "$dir/xray.zip" -d "$dir/x" || {
        err "解压失败"
        return 1
    }
    [[ -f $dir/x/xray ]] || {
        err "压缩包中未找到 xray"
        return 1
    }
    chmod 755 "$dir/x/xray"
    "$dir/x/xray" version >/dev/null 2>&1 || {
        err "新内核无法在本机运行 (架构不匹配?)"
        return 1
    }
    mkdir -p "${XRAY_BIN%/*}" "$XRAY_ASSET_DIR" "$CONFIG_DIR" "$LOG_DIR" "$DATA_DIR"
    if ! { cp -f "$dir/x/xray" "$XRAY_BIN.new" && chmod 755 "$XRAY_BIN.new" && mv -f "$XRAY_BIN.new" "$XRAY_BIN"; }; then
        err "安装 xray 失败"
        return 1
    fi
    if [[ ! -s $XRAY_ASSET_DIR/geosite.dat || $(meta_get '.settings.geo_source // "official"') == official ]]; then
        cp -f "$dir/x/geoip.dat" "$dir/x/geosite.dat" "$XRAY_ASSET_DIR/" 2>/dev/null
    fi
    rm -rf "$dir"
    ok "Xray $(xray_ver) 已安装: $XRAY_BIN"
    write_service
    if [[ ! -s $CONFIG_FILE ]]; then
        default_config >"$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    fi
    n=$(jq '(.inbounds // []) | length' "$CONFIG_FILE" 2>/dev/null)
    if [[ ${n:-0} -gt 0 && $XS_NO_RESTART != 1 ]]; then
        if svc_restart_check; then ok "Xray 已重启"; else
            err "Xray 启动失败"
            show_start_error
        fi
    fi
    return 0
}
install_menu() {
    local cur stable pre c
    cur=$(xray_ver)
    info "正在查询版本信息..."
    stable=$(latest_version stable)
    pre=$(latest_version pre)
    title "安装 / 更新 Xray 内核"
    say " 当前版本: ${cur:-未安装}"
    say " ${cyan}1.${none} 最新正式版   ${green}${stable:-获取失败}${none}"
    say " ${cyan}2.${none} 最新预发布版 ${yellow}${pre:-获取失败}${none}  (Xray 近期新版本多以预发布形式发布)"
    say "    ${gray}注意: 26.9 起的预发布版, REALITY 会拒绝不带 X25519MLKEM768 的旧客户端 (客户端需更新到最新版, 指纹用 chrome)${none}"
    say " ${cyan}3.${none} 指定版本"
    say " ${cyan}0.${none} 返回"
    c=$(ask_choice "请选择" 1 0 3) || exit 1
    case $c in
        1) install_xray "$stable" || return 1 ;;
        2) install_xray "$pre" || return 1 ;;
        3) install_xray "$(ask_required "版本号 (如 v26.3.27)")" || return 1 ;;
        *) return 0 ;;
    esac
    local n
    n=$(jq '(.inbounds // []) | length' "$CONFIG_FILE" 2>/dev/null)
    if [[ ${n:-0} -eq 0 ]] && ask_yn "当前还没有节点, 是否立即添加一个 VLESS + Vision + REALITY 节点?" y; then
        add_node_kind 1
    fi
}
update_geo() { # [loyalsoldier|official]
    local src=${1:-$(meta_get '.settings.geo_source // "loyalsoldier"')} dir f want got base ver arch
    dir=$(mktemp -d "$WORK_DIR/geo.XXXXXX")
    if [[ $src == official ]]; then
        ver=$(xray_ver)
        arch=$(xray_arch)
        [[ -n $ver ]] || {
            err "未安装 Xray"
            return 1
        }
        info "从 Xray v$ver 发布包中提取官方 geo 文件 ..."
        if ! download "https://github.com/XTLS/Xray-core/releases/download/v$ver/Xray-linux-$arch.zip" "$dir/x.zip" ||
            ! unzip -oq "$dir/x.zip" geoip.dat geosite.dat -d "$dir"; then
            err "下载失败"
            return 1
        fi
    else
        base="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
        for f in geoip.dat geosite.dat; do
            info "下载 $f ..."
            download "$base/$f" "$dir/$f" || {
                err "$f 下载失败"
                return 1
            }
            if DL_QUIET=1 download "$base/$f.sha256sum" "$dir/$f.sha"; then
                want=$(awk '{ print $1; exit }' "$dir/$f.sha")
                got=$(sha256sum "$dir/$f" | awk '{ print $1 }')
                [[ $want == "$got" ]] || {
                    err "$f 校验失败"
                    return 1
                }
            fi
        done
    fi
    mkdir -p "$XRAY_ASSET_DIR"
    cp -f "$dir/geoip.dat" "$dir/geosite.dat" "$XRAY_ASSET_DIR/" || return 1
    rm -rf "$dir"
    meta_set '.settings.geo_source = $s' --arg s "$src"
    ok "geo 文件已更新 ($src)"
    if svc_running; then svc restart >/dev/null 2>&1; fi
    return 0
}
ensure_crond() {
    case $INIT in
        openrc)
            rc-update add crond default >/dev/null 2>&1
            rc-service crond start >/dev/null 2>&1
            ;;
        systemd) systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || systemctl enable --now cronie >/dev/null 2>&1 ;;
    esac
    return 0
}
geo_cron_enabled() { crontab -l 2>/dev/null | grep -qF "$GEO_CRON_TAG"; }
geo_menu() {
    title "geo 规则文件"
    say " ${cyan}1.${none} 立即更新 (Loyalsoldier 增强版, 规则更全)"
    say " ${cyan}2.${none} 立即更新 (官方, 随 Xray 发布包)"
    say " ${cyan}3.${none} 每周自动更新 [$(geo_cron_enabled && echo "${green}开${none}" || echo 关)]"
    say " ${cyan}0.${none} 返回"
    case $(ask_choice "请选择" 1 0 3) in
        1) update_geo loyalsoldier ;;
        2) update_geo official ;;
        3)
            ensure_cmds crontab || return 1
            if geo_cron_enabled; then
                crontab -l 2>/dev/null | grep -vF "$GEO_CRON_TAG" | crontab -
                ok "已关闭 geo 文件自动更新"
            else
                [[ -x $SHORTCUT ]] || {
                    err "快捷命令 $SHORTCUT 不存在 (请下载脚本后以文件方式运行一次)"
                    return 1
                }
                (
                    crontab -l 2>/dev/null | grep -vF "$GEO_CRON_TAG"
                    echo "30 4 * * 1 $SHORTCUT update-geo >/dev/null 2>&1 $GEO_CRON_TAG"
                ) | crontab -
                ensure_crond
                ok "已开启: 每周一 04:30 自动更新 geo 文件"
            fi
            ;;
    esac
}
install_shortcut() { # 以文件方式运行时复制自身; 通过 bash <(curl ...) 运行时从仓库下载一份
    local src f
    src=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null)
    if [[ -f $src && -r $src ]]; then
        [[ $src == "$(readlink -f "$SHORTCUT" 2>/dev/null)" ]] && return 0
        grep -q 'managed-by: xray-script' "$src" 2>/dev/null || return 0
        if ! cmp -s "$src" "$SHORTCUT" 2>/dev/null; then
            mkdir -p "${SHORTCUT%/*}"
            cp -f "$src" "$SHORTCUT" 2>/dev/null && chmod 755 "$SHORTCUT"
        fi
    elif [[ -n $SCRIPT_URL ]]; then # 每次通过一键命令运行, 都把快捷命令更新到仓库最新版
        f=$(tmpf) || return 0
        if DL_QUIET=1 download "$SCRIPT_URL" "$f" 2>/dev/null && bash -n "$f" 2>/dev/null &&
            grep -q 'managed-by: xray-script' "$f" && ! cmp -s "$f" "$SHORTCUT" 2>/dev/null; then
            mkdir -p "${SHORTCUT%/*}"
            cp -f "$f" "$SHORTCUT" && chmod 755 "$SHORTCUT"
        fi
    fi
    return 0
}
update_script() {
    [[ -n $SCRIPT_URL ]] || {
        warn "未设置脚本地址: 请在脚本顶部 SCRIPT_URL 填写 raw 地址, 或设置环境变量 XRAY_SCRIPT_URL"
        return 1
    }
    local f
    f=$(tmpf)
    DL_QUIET=1 download "$SCRIPT_URL" "$f" || {
        err "下载失败"
        return 1
    }
    if ! bash -n "$f" 2>/dev/null || ! grep -q 'managed-by: xray-script' "$f"; then
        err "下载的内容不是有效的脚本"
        return 1
    fi
    cp -f "$f" "$SHORTCUT" && chmod 755 "$SHORTCUT" && ok "脚本已更新, 请重新运行 ${SHORTCUT##*/}"
}
safe_rm() { # 只删除路径中带 xray 的目录/文件, 防止误删
    case ${1%/} in
        */xray | */xray-script | */xray/* | */xray-script/* | */xray.*) rm -rf "$1" ;;
        *) warn "跳过删除 $1 (路径不像是 Xray 专用目录)" ;;
    esac
}
uninstall_all() {
    title "卸载"
    say "将删除: Xray 内核与服务、配置 $CONFIG_DIR、脚本数据 $DATA_DIR (含证书与备份)、日志 $LOG_DIR、快捷命令 $SHORTCUT"
    confirm_word "确认卸载" YES || {
        info "已取消"
        return 1
    }
    local rm_bbr=0 p l
    [[ -f $BBR_SYSCTL ]] && ask_yn "同时移除脚本写入的 BBR 设置?" n && rm_bbr=1
    if [[ -s $CONFIG_FILE ]]; then
        while IFS=$'\x1f' read -r p l; do
            [[ $p =~ ^[0-9]+$ ]] && fw_apply close "$p" "$l"
        done < <(jq -r "$JQ_LIB"' .inbounds[]? | [(.port | tostring), l4s] | join("\u001f")' "$CONFIG_FILE" 2>/dev/null)
    fi
    svc stop >/dev/null 2>&1
    svc disable >/dev/null 2>&1
    svc_manual stop
    case $INIT in
        systemd)
            rm -f "$SYSTEMD_UNIT"
            rm -rf /etc/systemd/system/xray.service.d
            systemctl daemon-reload >/dev/null 2>&1
            ;;
        openrc) rm -f "$OPENRC_INIT" ;;
    esac
    if geo_cron_enabled; then crontab -l 2>/dev/null | grep -vF "$GEO_CRON_TAG" | crontab -; fi
    rm -f "$XRAY_BIN"
    safe_rm "$XRAY_ASSET_DIR"
    if [[ ${CONFIG_DIR##*/} == xray ]]; then safe_rm "$CONFIG_DIR"; else rm -f "$CONFIG_FILE"; fi
    safe_rm "$DATA_DIR"
    safe_rm "$LOG_DIR"
    if ((rm_bbr)); then
        rm -f "$BBR_SYSCTL"
        [[ -f /etc/sysctl.conf ]] && sed -i '/net.ipv4.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr/d; /net.core.default_qdisc[[:space:]]*=[[:space:]]*fq/d' /etc/sysctl.conf
    fi
    rm -f "$SHORTCUT"
    ok "卸载完成"
    exit 0
}

# ---------------------------------------------------------------------
# jq 公共函数库
#   · 路由规则用 ruleTag 标识归属: xs-block-* / xs-custom-* / xs-user-* / xs-node-* / xs-default
#     排序优先级: 手动规则 > 屏蔽 > 自定义分流 > 用户落地 > 节点落地 > 全局默认
#   · 写配置时统一使用 v26.3.x 与 v26.9.x 都认识的字段名 (clients / network / accounts / address)
# ---------------------------------------------------------------------
read -r -d '' JQ_LIB <<'JQEOF'
def nz: . != null and . != "";
def hasv($x): any(.[]?; . == $x);
def netname: ((.streamSettings.network // .streamSettings.method // "raw") | tostring) as $n
  | if $n == "tcp" or $n == "raw" then "raw"
    elif $n == "splithttp" or $n == "xhttp" then "xhttp"
    elif $n == "websocket" or $n == "ws" then "ws"
    elif $n == "kcp" or $n == "mkcp" then "mkcp"
    else $n end;
def secname: (.streamSettings.security // "none");
def is_vision: ((.settings.clients[0]?.flow // .settings.flow // "") | startswith("xtls-rprx-vision"));
def netlabel: ({"raw": "", "xhttp": "XHTTP", "ws": "WS", "grpc": "gRPC", "httpupgrade": "HTTPUpgrade", "mkcp": "mKCP", "hysteria": ""}[netname]) // netname;
def seclabel: ({"reality": "REALITY", "tls": "TLS"}[secname]) // "";
def plus: map(select(. != "")) | join("+");
def nlabel:
  .protocol as $p
  | if $p == "vless" then
      ["VLESS", (if is_vision then "Vision" else "" end), netlabel, seclabel,
       (if (.settings.decryption // "none") != "none" then "ENC" else "" end)] | plus
    elif $p == "vmess" then ["VMess", netlabel, seclabel] | plus
    elif $p == "trojan" then ["Trojan", netlabel, seclabel] | plus
    elif $p == "shadowsocks" then "SS(" + (.settings.method // "?") + ")"
    elif $p == "hysteria" then "Hysteria2" + (if ([.streamSettings.finalmask.udp[]? | select(.type == "salamander")] | length) > 0 then "+obfs" else "" end)
    elif $p == "socks" or $p == "mixed" then "SOCKS5/HTTP"
    elif $p == "http" then "HTTP"
    elif $p == "tunnel" or $p == "dokodemo-door" then
      "端口转发→" + ((.settings.address // .settings.rewriteAddress // "?") | tostring) + ":" + ((.settings.port // .settings.rewritePort // 0) | tostring)
    else $p end;
def tolist: if type == "array" then . elif type == "string" then split(",") | map(gsub(" "; "")) else [] end;
def l4:
  .protocol as $p
  | if $p == "hysteria" then ["udp"]
    elif $p == "shadowsocks" then ((.settings.network // "tcp") | tolist)
    elif $p == "socks" or $p == "mixed" then (if .settings.udp == true then ["tcp", "udp"] else ["tcp"] end)
    elif $p == "tunnel" or $p == "dokodemo-door" then ((.settings.network // .settings.allowedNetwork // "tcp") | tolist)
    elif netname == "mkcp" then ["udp"]
    else ["tcp"] end;
def l4s: l4 | if hasv("tcp") and hasv("udp") then "both" elif hasv("udp") then "udp" else "tcp" end;
def port_hit($p): ($p | tonumber) as $n
  | any((.port | tostring) | split(",")[] | gsub(" "; "");
        if test("^[0-9]+$") then tonumber == $n
        elif test("^[0-9]+-[0-9]+$") then (split("-") | map(tonumber)) as $r | ($r[0] <= $n and $n <= $r[1])
        else false end);
def xs_prio: (.ruleTag // "") as $t
  | if ($t | startswith("xs-block")) then 1
    elif ($t | startswith("xs-custom")) then 2
    elif ($t | startswith("xs-user-")) then 3
    elif ($t | startswith("xs-node-")) then 4
    elif $t == "xs-default" then 5
    else 0 end;
def sort_rules: .routing.rules |= (to_entries | sort_by([(.value | xs_prio), .key]) | map(.value));
def is_builtin: . as $t | ["direct", "block", "direct-v4", "direct-v6", "api"] | hasv($t);
def node_out($t): first(.routing.rules[]? | select(.ruleTag == ("xs-node-" + $t)) | .outboundTag) // "";
def user_out($e): first(.routing.rules[]? | select(.ruleTag == ("xs-user-" + $e)) | .outboundTag) // "";
def default_out: first(.routing.rules[]? | select(.ruleTag == "xs-default") | .outboundTag) // "direct";
def notin($arr): . as $x | ($arr | map(select(. == $x)) | length) == 0;
def uniqname($base; $used): first(($base), ($base + "-" + (range(2; 1000) | tostring)) | select(notin($used)));
def alltags: [(.inbounds[]?.tag), (.outbounds[]?.tag)] | map(select(. != null and . != ""));
def allemails: [.inbounds[]?.settings.clients[]?.email] | map(select(. != null and . != ""));
def cred_key: if .protocol == "trojan" then "password" elif .protocol == "hysteria" then "auth" else "id" end;
def odesc:
  (.settings.vnext[0].address // .settings.servers[0].address // .settings.address // .settings.peers[0].endpoint // "") as $a
  | ((.settings.vnext[0].port // .settings.servers[0].port // .settings.port // "") | tostring) as $po
  | ([.protocol,
      (if ((.streamSettings.network // "raw") | . != "raw" and . != "tcp") then .streamSettings.network else "" end),
      (if (.streamSettings.security // "none") != "none" then .streamSettings.security else "" end)] | plus)
    + " " + ($a | tostring) + (if $po != "" and $po != "null" then ":" + $po else "" end)
    + (if .streamSettings.sockopt.dialerProxy then " (经由 " + .streamSettings.sockopt.dialerProxy + ")" else "" end);
def set_node_out($t; $o):
  .routing.rules |= map(select(.ruleTag != ("xs-node-" + $t)))
  | (if $o == "" then . else .routing.rules += [{ruleTag: ("xs-node-" + $t), inboundTag: [$t], outboundTag: $o}] end)
  | sort_rules;
def set_user_out($e; $o):
  .routing.rules |= map(select(.ruleTag != ("xs-user-" + $e)))
  | (if $o == "" then . else .routing.rules += [{ruleTag: ("xs-user-" + $e), user: [$e], outboundTag: $o}] end)
  | sort_rules;
JQEOF

# 规范化 (兼容手动修改过的配置):
#  无 tag 的入站自动命名、为用户补 email、确保 direct 为首个出站且不改变原有默认路由、
#  补齐 block / direct-v4 / direct-v6
read -r -d '' JQ_NORMALIZE <<'JQEOF'
def ensure_out($t; $o): if (.outbounds | map(.tag // "") | hasv($t)) then . else .outbounds += [$o] end;
def add_default_rule:
  if ([.routing.rules[] | select(.ruleTag == "xs-default")] | length) > 0 then .
  else (if (.outbounds[0].tag // "") == "" then .outbounds[0].tag = uniqname("out-default"; alltags) else . end)
       | .routing.rules += [{ruleTag: "xs-default", network: "tcp,udp", outboundTag: .outbounds[0].tag}]
  end;
(if type == "object" then . else {} end)
| .log = (if (.log | type) == "object" then .log else {loglevel: "warning", access: "none", error: ($logdir + "/error.log")} end)
| .inbounds = (if (.inbounds | type) == "array" then .inbounds else [] end)
| .outbounds = (if (.outbounds | type) == "array" then .outbounds else [] end)
| .routing = (if (.routing | type) == "object" then .routing else {domainStrategy: "IPIfNonMatch"} end)
| .routing.rules = (if (.routing.rules | type) == "array" then .routing.rules else [] end)
| reduce range(0; .inbounds | length) as $i (.;
    if (.inbounds[$i].tag // "") == "" then
      .inbounds[$i].tag = uniqname("in-" + ((.inbounds[$i].port // $i) | tostring); alltags)
    else . end)
| reduce range(0; .inbounds | length) as $i (.;
    if (.inbounds[$i].settings.clients | type) == "array" then
      reduce range(0; .inbounds[$i].settings.clients | length) as $j (.;
        if (.inbounds[$i].settings.clients[$j].email // "") == "" then
          .inbounds[$i].settings.clients[$j].email =
            uniqname(.inbounds[$i].tag + (if $j == 0 then "" else "-" + (($j + 1) | tostring) end); allemails)
        else . end)
    else . end)
| if (.outbounds | map(.tag // "") | hasv("direct")) then
    (if (.outbounds[0].tag // "") != "direct" then
       (if (.outbounds[0].protocol // "") != "freedom" then add_default_rule else . end)
       | .outbounds = ([.outbounds[] | select(.tag == "direct")][0:1] + [.outbounds[] | select((.tag // "") != "direct")])
     else . end)
  elif (.outbounds | length) > 0 and (.outbounds[0].protocol // "") == "freedom" and (.outbounds[0].tag // "") == "" then
    .outbounds[0].tag = "direct"
  else
    (if (.outbounds | length) > 0 and (.outbounds[0].protocol // "") != "freedom" then add_default_rule else . end)
    | .outbounds = [{tag: "direct", protocol: "freedom"}] + .outbounds
  end
| ensure_out("block"; {tag: "block", protocol: "blackhole"})
| ensure_out("direct-v4"; {tag: "direct-v4", protocol: "freedom", streamSettings: {sockopt: {domainStrategy: "ForceIPv4"}}})
| ensure_out("direct-v6"; {tag: "direct-v6", protocol: "freedom", streamSettings: {sockopt: {domainStrategy: "ForceIPv6"}}})
| sort_rules
JQEOF

default_config() {
    jq -n --arg logdir "$LOG_DIR" '{
        log: {loglevel: "warning", access: "none", error: ($logdir + "/error.log")},
        inbounds: [],
        outbounds: [{tag: "direct", protocol: "freedom"}, {tag: "block", protocol: "blackhole"}],
        routing: {domainStrategy: "IPIfNonMatch", rules: [
            {ruleTag: "xs-block-private", ip: ["geoip:private"], outboundTag: "block"},
            {ruleTag: "xs-block-private-d", domain: ["geosite:private"], outboundTag: "block"}
        ]}
    }'
}

# ---------------------------------------------------------------------
# 元数据 (客户端侧参数: 连接地址 / NAT 外部端口 / 指纹 / VLESS 加密客户端串 / 证书指纹 ...)
# ---------------------------------------------------------------------
meta_init() {
    mkdir -p "$DATA_DIR" 2>/dev/null || return 0
    if ! jq -e 'type == "object"' "$META_FILE" >/dev/null 2>&1; then
        printf '%s\n' '{"settings":{},"nodes":{},"landings":{}}' >"$META_FILE"
        chmod 600 "$META_FILE"
    fi
    return 0
}
meta_get() { # 过滤器 [jq 选项...]
    local f=$1
    shift
    [[ -s $META_FILE ]] || return 0
    jq -r "$@" "$f" "$META_FILE" 2>/dev/null
}
meta_set() { # 过滤器 [jq 选项...]
    local f=$1 tmp
    shift
    [[ -s $META_FILE ]] || meta_init
    tmp=$(mktemp "$DATA_DIR/.meta.XXXXXX") || return 1
    if jq "$@" "$f" "$META_FILE" >"$tmp" 2>/dev/null; then
        mv -f "$tmp" "$META_FILE"
    else
        rm -f "$tmp"
        return 1
    fi
}

# ---------------------------------------------------------------------
# 配置读写: cfg_load 生成规范化的工作副本 → cfg_jq 修改 → cfg_commit 校验/写入/重启/失败回滚
# ---------------------------------------------------------------------
cfg_src() { if [[ -n $CFG_WORK && -s $CFG_WORK ]]; then printf '%s' "$CFG_WORK"; else printf '%s' "$CONFIG_FILE"; fi; }
strip_json_comments() { # 去掉 // 与 /* */ 注释, 字符串内的内容 (如 https://) 原样保留
    awk '
        {
            out = ""; str = 0; esc = 0; n = length($0)
            for (i = 1; i <= n; i++) {
                c = substr($0, i, 1); d = substr($0, i + 1, 1)
                if (blk) { if (c == "*" && d == "/") { blk = 0; i++ } continue }
                if (str) { out = out c; if (esc) esc = 0; else if (c == "\\") esc = 1; else if (c == "\"") str = 0; continue }
                if (c == "\"") { str = 1; out = out c; continue }
                if (c == "/" && d == "/") break
                if (c == "/" && d == "*") { blk = 1; i++; continue }
                out = out c
            }
            print out
        }' "$1"
}
cfg_load() {
    CFG_WORK=$(mktemp "$WORK_DIR/cfg.XXXXXX") || return 1
    if [[ -s $CONFIG_FILE ]]; then
        if jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
            cat "$CONFIG_FILE" >"$CFG_WORK"
        else
            strip_json_comments "$CONFIG_FILE" >"$CFG_WORK"
            jq -e . "$CFG_WORK" >/dev/null 2>&1 || {
                err "配置文件 $CONFIG_FILE 不是合法的 JSON, 请先修复, 或在 系统工具 中从备份恢复"
                CFG_WORK=""
                return 1
            }
        fi
    else
        default_config >"$CFG_WORK"
    fi
    cfg_jq "$JQ_LIB $JQ_NORMALIZE" --arg logdir "$LOG_DIR"
}
cfg_jq() { # 过滤器 [jq 选项...]  原地修改工作副本
    local f=$1 tmp
    shift
    tmp=$(mktemp "$WORK_DIR/cfg.XXXXXX") || return 1
    if jq "$@" "$f" "$CFG_WORK" >"$tmp"; then
        mv -f "$tmp" "$CFG_WORK"
    else
        rm -f "$tmp"
        err "配置处理失败"
        return 1
    fi
}
cfg_jqL() {
    local f=$1
    shift
    cfg_jq "$JQ_LIB $f" "$@"
}
cfg_get() {
    local f=$1
    shift
    jq -r "$@" "$f" "$(cfg_src)" 2>/dev/null
}
cfg_getL() {
    local f=$1
    shift
    cfg_get "$JQ_LIB $f" "$@"
}
xray_test() { # 配置文件   (Xray 按扩展名识别格式, 非 .json 文件先复制一份)
    local f=$1 out rc
    mkdir -p "$LOG_DIR" 2>/dev/null # -test 也会打开日志文件, 目录不存在会直接失败
    local d
    while IFS= read -r d; do [[ -n $d && $d == /* ]] && mkdir -p "${d%/*}" 2>/dev/null; done < <(jq -r '.log.access?, .log.error? | strings | select(. != "none")' "$f" 2>/dev/null)
    if [[ $f != *.json ]]; then
        f=$(mktemp "$WORK_DIR/test.XXXXXX") && mv -f "$f" "$f.json" && f="$f.json" && cp -f "$1" "$f" || return 1
    fi
    out=$("$XRAY_BIN" run -test -config "$f" 2>&1)
    rc=$?
    [[ $f != "$1" ]] && rm -f "$f"
    ((rc == 0)) && return 0
    printf '%s\n' "$out" | grep -vE '^(Xray [0-9]|A unified platform)' | tail -n 15 >&2
    return 1
}
cfg_commit() {
    [[ -x $XRAY_BIN ]] || {
        err "未安装 Xray 内核, 无法校验配置"
        return 1
    }
    if ! xray_test "$CFG_WORK"; then
        err "新配置未通过 Xray 校验, 已取消写入"
        return 1
    fi
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" "$LOG_DIR"
    [[ -s $CONFIG_FILE ]] && cp -f "$CONFIG_FILE" "$BACKUP_DIR/config.prev.json"
    if ! { cat "$CFG_WORK" >"$CONFIG_FILE.tmp" && chmod 600 "$CONFIG_FILE.tmp" && mv -f "$CONFIG_FILE.tmp" "$CONFIG_FILE"; }; then
        err "写入配置失败"
        return 1
    fi
    if [[ $XS_NO_RESTART == 1 ]]; then
        links_refresh
        return 0
    fi
    if svc_restart_check; then
        ok "配置已生效, Xray 运行中"
    else
        err "Xray 启动失败"
        show_start_error
        if [[ -s $BACKUP_DIR/config.prev.json ]]; then
            cp -f "$BACKUP_DIR/config.prev.json" "$CONFIG_FILE"
            svc restart >/dev/null 2>&1
            warn "已自动回滚到修改前的配置"
        fi
        return 1
    fi
    links_refresh
    return 0
}

# ---------------------------------------------------------------------
# 节点: 列表 / 选择 / 通用输入
# ---------------------------------------------------------------------
out_name() {
    case $1 in
        "") echo "默认" ;;
        direct) echo "直连" ;;
        direct-v4) echo "直连(IPv4)" ;;
        direct-v6) echo "直连(IPv6)" ;;
        block) echo "阻断" ;;
        *) echo "落地:$1" ;;
    esac
}
list_nodes() { # 打印节点列表并填充 NODE_TAGS
    local rows row idx tag label listen port l4 users out def
    NODE_TAGS=()
    mapfile -t rows < <(cfg_getL '. as $r | .inbounds | to_entries[] | .value as $ib
        | [((.key + 1) | tostring), $ib.tag, ($ib | nlabel), (($ib.listen // "0.0.0.0") | tostring), ($ib.port | tostring),
           ($ib | l4s), ((($ib.settings.clients // $ib.settings.accounts // [0]) | length) | tostring),
           ($r | node_out($ib.tag))] | join("\u001f")')
    if ((${#rows[@]} == 0)); then
        warn "当前还没有节点"
        return 1
    fi
    def=$(out_name "$(cfg_getL default_out)")
    for row in "${rows[@]}"; do
        IFS=$'\x1f' read -r idx tag label listen port l4 users out <<<"$row"
        NODE_TAGS+=("$tag")
        if [[ -z $out ]]; then out="默认($def)"; else out=$(out_name "$out"); fi
        say " ${cyan}${idx}.${none} ${bold}${tag}${none}  ${label}  ${gray}${listen}:${none}${green}${port}${none}/${l4}  ${gray}用户:${users}${none}  出站:${magenta}${out}${none}"
    done
}
pick_node() { # 提示 → PICKED_NODE
    list_nodes || return 1
    local c
    c=$(ask_choice "${1:-选择节点} (0 返回)" 0 0 "${#NODE_TAGS[@]}") || exit 1
    ((c == 0)) && return 1
    PICKED_NODE=${NODE_TAGS[c - 1]}
}
port_owner() { # 端口 l4 [排除的节点] → 已占用该端口的节点名
    local f
    f=$(cfg_src)
    [[ -s $f ]] || return 0
    jq -r --arg p "$1" --arg l4 "$2" --arg self "${3:-}" "$JQ_LIB"'
        ($l4 | if . == "both" then ["tcp", "udp"] else [.] end) as $want
        | first(.inbounds[]? | select(.tag != $self) | select(port_hit($p))
            | select(l4 as $h | any($want[]; . as $w | $h | hasv($w))) | .tag) // empty' "$f" 2>/dev/null
}
tag_exists() { [[ -n $(cfg_get 'first((.inbounds[]?, .outbounds[]?) | select(.tag == $t) | .tag) // empty' --arg t "$1") ]]; }
pick_tag() { # 默认值 [提示] [允许保留的原名]
    local t
    while :; do
        t=$(ask "${2:-节点名称 (标签)}" "$1") || exit 1
        [[ -n ${3:-} && $t == "$3" ]] && {
            printf '%s' "$t"
            return 0
        }
        if ! is_name "$t"; then
            err "名称不能为空, 且不能含空格及 \" ' \\ # % / , \$ ? & 等字符"
            continue
        fi
        case $t in direct | block | direct-v4 | direct-v6 | api)
            err "[$t] 是保留名称"
            continue
            ;;
        esac
        if tag_exists "$t"; then
            err "名称 [$t] 已被使用"
            continue
        fi
        printf '%s' "$t"
        return 0
    done
}
next_email() { cfg_getL 'uniqname($b; allemails)' --arg b "$1"; }
pick_email() { # 默认值
    local e
    while :; do
        e=$(ask "用户名" "$1") || exit 1
        if ! is_name "$e"; then
            err "用户名不能含空格及特殊字符"
            continue
        fi
        if [[ -n $(cfg_getL 'allemails | map(select(. == $e)) | .[0] // empty' --arg e "$e") ]]; then
            err "用户名已存在"
            continue
        fi
        printf '%s' "$e"
        return 0
    done
}
pick_port() { # l4 默认值 [节点自身名称]
    local l4=$1 def=$2 self=${3:-} p owner cur=""
    [[ -n $self ]] && cur=$(cfg_get '.inbounds[] | select(.tag == $t) | .port | tostring' --arg t "$self")
    while :; do
        p=$(ask "端口 [1-65535]" "$def") || exit 1
        is_port "$p" || {
            error
            continue
        }
        p=$((10#$p))
        owner=$(port_owner "$p" "$l4" "$self")
        if [[ -n $owner ]]; then
            err "端口 $p 已被节点 [$owner] 使用"
            continue
        fi
        if [[ $p != "$cur" ]] && port_busy "$p" "$l4"; then
            err "端口 $p ($l4) 已被本机其他程序占用"
            ask_yn "仍然使用该端口?" n || continue
        fi
        printf '%s' "$p"
        return 0
    done
}
pick_listen() { # 默认值
    local v
    while :; do
        v=$(ask "监听地址 (0.0.0.0 = 全部 IPv4/IPv6, 127.0.0.1 = 仅本机)" "${1:-0.0.0.0}") || exit 1
        if [[ $v == "::" ]] || is_ip "$v"; then
            printf '%s' "$v"
            return 0
        fi
        error
    done
}
pick_uuid() { # 默认值
    local v
    while :; do
        v=$(ask "UUID (也可填任意字符串, 自动映射为 UUID)" "$1") || exit 1
        v=${v//[[:space:]]/}
        if is_uuid "$v"; then
            printf '%s' "${v,,}"
            return 0
        fi
        if [[ -n $v && ${#v} -le 30 ]] && is_name "$v"; then
            v=$("$XRAY_BIN" uuid -i "$v" 2>/dev/null)
            if is_uuid "$v"; then
                info "已映射为 UUID: $v"
                printf '%s' "$v"
                return 0
            fi
        fi
        error
    done
}
pick_password() { # 默认值 [提示]
    local v
    while :; do
        v=$(ask "${2:-密码}" "$1") || exit 1
        if is_name "$v"; then
            printf '%s' "$v"
            return 0
        fi
        err "不能为空, 且不能含空格及 \" ' \\ # % / , \$ ? & 等字符"
    done
}
pick_path() { # 提示 [默认值]
    local p
    p=$(ask "${1:-路径}" "${2:-$(rand_path)}") || exit 1
    p=${p//[[:space:]]/}
    [[ $p == /* ]] || p="/$p"
    printf '%s' "$p"
}
pick_outbound() { # 提示 允许"默认"(1/0) → PICKED_OUT ("" = 跟随默认)
    local prompt=$1 allow_def=${2:-1} line c i
    local -a opts=() descs=() rows=()
    if [[ $allow_def == 1 ]]; then
        opts+=("")
        descs+=("默认 (跟随全局默认出口: $(out_name "$(cfg_getL default_out)"))")
    fi
    opts+=(direct direct-v4 direct-v6 block)
    descs+=("直连" "直连 (强制 IPv4 出站)" "直连 (强制 IPv6 出站)" "阻断")
    mapfile -t rows < <(cfg_getL '.outbounds[] | select(.tag != null and (.tag | is_builtin | not)) | [.tag, odesc] | join("\u001f")')
    for line in "${rows[@]}"; do
        opts+=("${line%%$'\x1f'*}")
        descs+=("落地 ${bold}${line%%$'\x1f'*}${none}  ${gray}${line#*$'\x1f'}${none}")
    done
    opts+=("__new__")
    descs+=("新建落地 ...")
    say "$prompt:"
    for i in "${!opts[@]}"; do say "  ${cyan}$((i + 1)).${none} ${descs[i]}"; done
    c=$(ask_choice "请选择" 1 1 "${#opts[@]}") || exit 1
    PICKED_OUT=${opts[c - 1]}
    if [[ $PICKED_OUT == __new__ ]]; then
        landing_add_flow || return 1
        PICKED_OUT=$LANDING_NEW_TAG
    fi
    return 0
}
ensure_ready() {
    if [[ ! -x $XRAY_BIN ]]; then
        warn "尚未安装 Xray 内核"
        ask_yn "现在安装最新正式版 Xray?" y || return 1
        install_xray || return 1
    fi
    service_ensure
    meta_init
    return 0
}

# ---------------------------------------------------------------------
# REALITY / VLESS Encryption / ML-DSA 辅助
# ---------------------------------------------------------------------
x25519_pub() { "$XRAY_BIN" x25519 -i "$1" 2>/dev/null | awk -F': ' '/^(Password|Public)/ { print $2; exit }'; }
x25519_gen() { # → REALITY_PRIV REALITY_PUB
    local out
    out=$("$XRAY_BIN" x25519 2>/dev/null)
    REALITY_PRIV=$(awk -F': ' '/^Private/ { print $2; exit }' <<<"$out")
    REALITY_PUB=$(awk -F': ' '/^(Password|Public)/ { print $2; exit }' <<<"$out")
    [[ -n $REALITY_PRIV && -n $REALITY_PUB ]] && return 0
    err "无法解析 xray x25519 的输出:"
    say "$out"
    return 1
}
reality_check() { # host:port   用 xray tls ping 检查目标是否支持 TLS 1.3
    local out ver pq
    command -v timeout >/dev/null 2>&1 || return 0
    info "正在检测目标 $1 ..."
    out=$(timeout 12 "$XRAY_BIN" tls ping "$1" 2>&1)
    ver=$(awk '/with SNI/ { f = 1 } f && /TLS Version/ { sub(/.*: */, ""); print; exit }' <<<"$out")
    pq=$(awk '/with SNI/ { f = 1 } f && /Post-Quantum/ { sub(/.*: */, ""); print; exit }' <<<"$out")
    if [[ $ver == *1.3* ]]; then
        ok "目标支持 TLS 1.3${pq:+, 后量子密钥交换: $pq}"
        return 0
    fi
    warn "未能确认目标支持 TLS 1.3 (${ver:-握手失败}), REALITY 要求目标支持 TLS 1.3"
    ask_yn "仍然使用该目标?" n
}
pick_reality_target() { # → REALITY_SNI REALITY_TARGET
    local -a c=(addons.mozilla.org www.tesla.com dl.google.com www.nvidia.com www.samsung.com www.lovelive-anime.jp)
    local i n=${#c[@]} ch v=""
    say "REALITY 目标网站 (借用它的 TLS 握手; 建议选与服务器同地区、支持 TLS1.3+H2、未套 CDN 的大站):"
    for i in "${!c[@]}"; do say "  ${cyan}$((i + 1)).${none} ${c[i]}"; done
    say "  ${cyan}$((n + 1)).${none} 自定义"
    ch=$(ask_choice "请选择" 1 1 $((n + 1))) || exit 1
    ((ch <= n)) && v=${c[ch - 1]}
    while :; do
        [[ -z $v ]] && v=$(ask_required "目标域名, 可带端口 (如 www.example.com 或 www.example.com:8443)")
        v=${v#https://}
        v=${v%%/*}
        if [[ $v == *:* ]]; then REALITY_SNI=${v%:*} REALITY_TARGET=$v; else REALITY_SNI=$v REALITY_TARGET="$v:443"; fi
        if is_ip "$REALITY_SNI"; then
            err "REALITY 目标请填写域名 (用 IP 时客户端不会发送 SNI, 无法通过验证)"
            v=""
            continue
        fi
        if [[ ${REALITY_SNI,,} =~ (apple|icloud|microsoft) || ${REALITY_SNI,,} =~ \.(ru|ir|cn)$ ]]; then
            warn "Xray 官方提示: 目标域名含 apple / icloud / microsoft 或以 .ru/.ir/.cn 结尾时, 服务器 IP 更容易被封锁"
            ask_yn "仍然使用 $REALITY_SNI?" n || {
                v=""
                continue
            }
        fi
        if [[ $XS_SKIP_CHECK == 1 ]] || reality_check "$REALITY_TARGET"; then return 0; fi
        v=""
    done
}
vlessenc_gen() { # x25519|mlkem → ENC_DEC (服务端) ENC_ENC (客户端)
    local out n=1
    [[ $1 == mlkem ]] && n=2
    out=$("$XRAY_BIN" vlessenc 2>/dev/null)
    ENC_DEC=$(awk -F'"' -v n="$n" '/"decryption"/ { c++; if (c == n) { print $4; exit } }' <<<"$out")
    ENC_ENC=$(awk -F'"' -v n="$n" '/"encryption"/ { c++; if (c == n) { print $4; exit } }' <<<"$out")
    [[ -n $ENC_DEC && -n $ENC_ENC ]] && return 0
    err "生成 VLESS Encryption 参数失败 (需要 Xray ≥ 25.8)"
    return 1
}
pick_vlessenc() {
    say "VLESS Encryption 认证方式:"
    say "  ${cyan}1.${none} X25519     (推荐, 分享链接短; 握手本身已是后量子安全)"
    say "  ${cyan}2.${none} ML-KEM-768 (完全后量子, 分享链接很长)"
    if [[ $(ask_choice "请选择" 1 1 2) == 2 ]]; then vlessenc_gen mlkem; else vlessenc_gen x25519; fi
}
vlessenc_client() { # 服务端 decryption → 客户端 encryption
    local key cli
    local -a p
    IFS=. read -r -a p <<<"$1"
    ((${#p[@]} >= 4)) || return 1
    key=${p[${#p[@]} - 1]}
    if ((${#key} <= 44)); then
        cli=$(x25519_pub "$key")
    else
        cli=$("$XRAY_BIN" mlkem768 -i "$key" 2>/dev/null | awk -F': ' '/^Client/ { print $2; exit }')
    fi
    [[ -n $cli ]] && printf '%s.%s.0rtt.%s' "${p[0]}" "${p[1]}" "$cli"
}
mldsa65_gen() { # → MLDSA_SEED MLDSA_VERIFY
    local out
    out=$("$XRAY_BIN" mldsa65 2>/dev/null)
    MLDSA_SEED=$(awk -F': ' '/^Seed/ { print $2; exit }' <<<"$out")
    MLDSA_VERIFY=$(awk -F': ' '/^Verify/ { print $2; exit }' <<<"$out")
    [[ -n $MLDSA_SEED && -n $MLDSA_VERIFY ]]
}
mldsa65_verify() { "$XRAY_BIN" mldsa65 -i "$1" 2>/dev/null | awk -F': ' '/^Verify/ { print $2; exit }'; }

# ---------------------------------------------------------------------
# TLS 证书 (自签 / ACME HTTP / ACME Cloudflare DNS / 已有文件)
# ---------------------------------------------------------------------
cert_sha256() { "$XRAY_BIN" tls hash --cert "$1" 2>/dev/null | awk '/SHA256/ { print $NF; exit }'; }
gen_self_cert() { # 域名 节点名
    local base="$CERT_DIR/self-$2"
    mkdir -p "$CERT_DIR"
    if ! "$XRAY_BIN" tls cert --domain="$1" --name="$1" --org="$1" --expire=87600h --file="$base" >/dev/null 2>&1 ||
        [[ ! -s $base.crt || ! -s $base.key ]]; then
        err "生成自签证书失败"
        return 1
    fi
    chmod 600 "$base.key"
    CERT_FILE="$base.crt" KEY_FILE="$base.key" CERT_SELF=1
    ok "已生成自签证书 (10 年): $CERT_FILE"
}
pick_cert() { # 默认方式(1-4) 默认域名 节点名 → CERT_FILE KEY_FILE CERT_DOMAIN CERT_SELF
    local def=${1:-1} dom=${2:-} tag=${3:-node} c
    say "TLS 证书:"
    say "  ${cyan}1.${none} 自签证书 (无需域名; 链接会带证书指纹, 部分客户端需开启“跳过证书验证”)"
    say "  ${cyan}2.${none} ACME 申请 · HTTP 验证 (域名已解析到本机, 需要 80 端口空闲)"
    say "  ${cyan}3.${none} ACME 申请 · Cloudflare DNS API (无需 80 端口, 适合 NAT 机)"
    say "  ${cyan}4.${none} 使用已有证书文件"
    c=$(ask_choice "请选择" "$def" 1 4) || exit 1
    CERT_SELF=0
    case $c in
        1)
            CERT_DOMAIN=$(ask_required "证书域名 (即 SNI, 可随意填写)" "${dom:-www.bing.com}") || exit 1
            gen_self_cert "$CERT_DOMAIN" "$tag"
            ;;
        2 | 3)
            CERT_DOMAIN=$(ask_required "域名 (需已解析到本机 IP)" "$dom") || exit 1
            if ((c == 2)); then acme_issue "$CERT_DOMAIN" http; else acme_issue "$CERT_DOMAIN" cf; fi
            ;;
        4)
            CERT_DOMAIN=$(ask_required "证书对应的域名" "$dom") || exit 1
            CERT_FILE=$(ask_required "证书文件路径 (fullchain)") || exit 1
            KEY_FILE=$(ask_required "私钥文件路径") || exit 1
            [[ -r $CERT_FILE && -r $KEY_FILE ]] || {
                err "证书或私钥文件不存在/不可读"
                return 1
            }
            ;;
    esac
}
acme_install() {
    [[ -x $ACME_SH ]] && return 0
    ensure_cmds curl openssl crontab tar || return 1
    ensure_crond
    local email dir
    email=$(ask "ACME 账户邮箱 (用于到期提醒, 可随意填写)" "xray$(rand_lower 6)@gmail.com") || exit 1
    dir=$(mktemp -d "$WORK_DIR/acme.XXXXXX")
    info "下载 acme.sh ..."
    download "https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.tar.gz" "$dir/acme.tar.gz" || {
        err "acme.sh 下载失败"
        return 1
    }
    tar -xzf "$dir/acme.tar.gz" -C "$dir" || return 1
    (cd "$dir"/acme.sh-* && ./acme.sh --install --home "${ACME_SH%/*}" -m "$email") >/dev/null 2>&1
    [[ -x $ACME_SH ]] || {
        err "acme.sh 安装失败"
        return 1
    }
    "$ACME_SH" --set-default-ca --server letsencrypt >/dev/null 2>&1
    ok "acme.sh 已安装"
}
acme_issue() { # 域名 http|cf → CERT_FILE KEY_FILE
    local d=$1 mode=$2 rc token zone
    is_domain "$d" || {
        err "域名格式不正确: $d"
        return 1
    }
    acme_install || return 1
    mkdir -p "$CERT_DIR"
    if [[ $mode == http ]]; then
        ensure_cmds socat || return 1
        if port_busy 80 tcp; then
            err "80 端口已被占用, 无法使用 HTTP 验证 (可改用 Cloudflare DNS 方式)"
            return 1
        fi
        fw_apply open 80 tcp
        info "正在申请证书 (HTTP 验证) ..."
        "$ACME_SH" --issue -d "$d" --standalone --keylength ec-256 --server letsencrypt >&2
        rc=$?
    else
        token=$(ask_required "Cloudflare API Token (需要 Zone.DNS 编辑权限)") || exit 1
        zone=$(ask "Cloudflare Zone ID (可留空)" "") || exit 1
        info "正在申请证书 (DNS 验证) ..."
        CF_Token=$token CF_Zone_ID=$zone "$ACME_SH" --issue -d "$d" --dns dns_cf --keylength ec-256 --server letsencrypt >&2
        rc=$?
    fi
    if ((rc != 0 && rc != 2)); then # 2 = 证书未到期, 无需重新申请
        err "证书申请失败 (请检查: 域名解析 / 80 端口 / API Token)"
        return 1
    fi
    if ! "$ACME_SH" --install-cert -d "$d" --ecc --fullchain-file "$CERT_DIR/$d.crt" --key-file "$CERT_DIR/$d.key" \
        --reloadcmd "$(svc_restart_cmd)" >/dev/null 2>&1; then
        err "证书安装失败"
        return 1
    fi
    chmod 600 "$CERT_DIR/$d.key"
    CERT_FILE="$CERT_DIR/$d.crt" KEY_FILE="$CERT_DIR/$d.key" CERT_SELF=0
    ok "证书已就绪: $CERT_FILE (acme.sh 会自动续期)"
}

# ---------------------------------------------------------------------
# 入站 JSON 构造
# ---------------------------------------------------------------------
ib_json() { # 名称 监听 端口 协议 settings [streamSettings] [嗅探 1/0]
    local stream=${6:-null}
    [[ -z $stream ]] && stream=null
    jq -nc --arg tag "$1" --arg listen "$2" --argjson port "$3" --arg proto "$4" \
        --argjson settings "$5" --argjson stream "$stream" --arg sniff "${7:-1}" '
        {tag: $tag, listen: $listen, port: $port, protocol: $proto, settings: $settings}
        + (if $stream != null then {streamSettings: $stream} else {} end)
        + (if $sniff == "1" then {sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: false}} else {} end)'
}
reality_stream() { # 传输 SNI target 私钥 shortId [附加json]
    local extra=${6:-}
    [[ -z $extra ]] && extra='{}'
    jq -nc --arg net "$1" --arg sni "$2" --arg target "$3" --arg pk "$4" --arg sid "$5" --argjson x "$extra" '
        {network: $net, security: "reality",
         realitySettings: {show: false, target: $target, xver: 0, serverNames: [$sni], privateKey: $pk, shortIds: [$sid]}} + $x'
}
tls_stream() { # 传输 证书 私钥 [附加json] [alpn json]
    local extra=${4:-} alpn=${5:-}
    [[ -z $extra ]] && extra='{}'
    [[ -z $alpn ]] && alpn=null
    jq -nc --arg net "$1" --arg crt "$2" --arg key "$3" --argjson x "$extra" --argjson alpn "$alpn" '
        {network: $net, security: "tls",
         tlsSettings: ({certificates: [{certificateFile: $crt, keyFile: $key}]} + (if $alpn != null then {alpn: $alpn} else {} end))} + $x'
}
plain_stream() { # 传输 [附加json]
    local extra=${2:-}
    [[ -z $extra ]] && extra='{}'
    jq -nc --arg net "$1" --argjson x "$extra" '{network: $net, security: "none"} + $x'
}
vless_client() { jq -nc --arg id "$1" --arg e "$2" --arg f "${3:-}" '{id: $id, email: $e} + (if $f != "" then {flow: $f} else {} end)'; }
tls_meta() { # meta json → 加入证书相关的客户端参数
    local m=$1
    m=$(jq -c --arg s "$CERT_DOMAIN" '. + {sni: $s}' <<<"$m")
    if ((CERT_SELF)); then
        m=$(jq -c --arg p "$(cert_sha256 "$CERT_FILE")" '. + {pcs: $p}' <<<"$m")
    else
        m=$(jq -c --arg a "$CERT_DOMAIN" '. + {addr: $a}' <<<"$m")
    fi
    printf '%s' "$m"
}
revproxy_meta() { # meta json → 加入反代 / CDN 的对外参数
    local dom lport
    dom=$(ask_required "对外域名 (Nginx / Caddy / CDN 使用的域名)") || exit 1
    lport=$(ask "对外 HTTPS 端口" 443) || exit 1
    is_port "$lport" || lport=443
    jq -c --arg d "$dom" --arg p "$lport" '. + {addr: $d, sni: $d, host: $d, lport: $p, lsec: "tls"}' <<<"$1"
}
revproxy_hint() { # 传输 端口 路径
    say "${gray}反代参考 (Nginx):${none}"
    if [[ $1 == xhttp ]]; then
        say "${gray}  location $3 { grpc_pass grpc://127.0.0.1:$2; grpc_set_header Host \$host; }${none}"
    else
        say "${gray}  location $3 { proxy_pass http://127.0.0.1:$2; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \"upgrade\"; proxy_set_header Host \$host; }${none}"
    fi
}

# ---------------------------------------------------------------------
# 添加节点
# ---------------------------------------------------------------------
node_common() { # 名称前缀 l4 [首选端口] [默认监听]
    NEW_L4=$2
    NEW_PORT=$(pick_port "$2" "$(free_port "$2" "${3:-}")") || exit 1
    NEW_LISTEN=$(pick_listen "${4:-0.0.0.0}") || exit 1
    NEW_TAG=$(pick_tag "$1-$NEW_PORT") || exit 1
    NEW_META='{}'
}
node_finalize() {
    local out=""
    [[ -n $NEW_META ]] || NEW_META='{}'
    if ask_yn "是否为该节点指定落地 / 出站? (默认直连)" n; then
        pick_outbound "该节点的出站" 1 || return 1
        out=$PICKED_OUT
    fi
    cfg_jq '.inbounds += [$ib]' --argjson ib "$NEW_IB" || return 1
    if [[ -n $out ]]; then cfg_jqL 'set_node_out($t; $o)' --arg t "$NEW_TAG" --arg o "$out" || return 1; fi
    meta_set '.nodes[$t] = $m' --arg t "$NEW_TAG" --argjson m "$NEW_META"
    if ! cfg_commit; then
        meta_set 'del(.nodes[$t])' --arg t "$NEW_TAG"
        return 1
    fi
    fw_apply open "$NEW_PORT" "$NEW_L4"
    ok "节点 [$NEW_TAG] 添加成功"
    show_node "$NEW_TAG"
}
add_node_wizard() {
    title "添加节点"
    say " ${cyan}1.${none} VLESS + Vision + REALITY      ${green}(推荐, 无需域名)${none}"
    say " ${cyan}2.${none} VLESS + XHTTP + REALITY       (无需域名, 可选后量子加密)"
    say " ${cyan}3.${none} VLESS + XHTTP + TLS/CDN       (需域名证书, 或由 Nginx/CDN 反代)"
    say " ${cyan}4.${none} VLESS + Vision + TLS          (需域名证书)"
    say " ${cyan}5.${none} VLESS + Encryption            (后量子加密, 无需证书, 适合中转↔落地)"
    say " ${cyan}6.${none} VLESS + WebSocket             (兼容老客户端 / CDN)"
    say " ${cyan}7.${none} VMess + WebSocket             (兼容老客户端 / CDN)"
    say " ${cyan}8.${none} Trojan (REALITY / TLS)"
    say " ${cyan}9.${none} Shadowsocks (2022 / AEAD)     (常用于中转 / 落地)"
    say "${cyan}10.${none} Hysteria2                     (UDP/QUIC, 自签证书即可)"
    say "${cyan}11.${none} SOCKS5 / HTTP 代理            (常作为落地供其他机器使用)"
    say "${cyan}12.${none} 端口转发 (Tunnel)             (中转: 本机端口 → 远端地址)"
    say " ${cyan}0.${none} 返回"
    local k
    k=$(ask_choice "请选择" 1 0 12) || exit 1
    ((k == 0)) && return 0
    add_node_kind "$k"
}
add_node_kind() {
    ensure_ready || return 1
    cfg_load || return 1
    case $1 in
        1) add_vless_reality raw ;;
        2) add_vless_reality xhttp ;;
        3) add_vless_xhttp_tls ;;
        4) add_vless_vision_tls ;;
        5) add_vless_enc ;;
        6) add_ws vless ;;
        7) add_ws vmess ;;
        8) add_trojan ;;
        9) add_ss ;;
        10) add_hy2 ;;
        11) add_socks ;;
        12) add_tunnel ;;
    esac
}
add_vless_reality() { # raw|xhttp
    local net=$1 prefix uuid flow="" dec="none" path extra='{}' meta='{"fp":"chrome"}' client settings stream
    if [[ $net == raw ]]; then prefix=reality; else prefix=xhttp-reality; fi
    node_common "$prefix" tcp 443 || return 1
    [[ $NEW_PORT != 443 ]] && info "提示: REALITY 使用 443 以外的端口会增加被识别的概率 (Xray 官方提示)"
    pick_reality_target || return 1
    x25519_gen || return 1
    uuid=$(pick_uuid "$(gen_uuid)") || exit 1
    if [[ $net == raw ]]; then
        flow=xtls-rprx-vision
    else
        path=$(pick_path "XHTTP 路径") || exit 1
        extra=$(jq -nc --arg p "$path" '{xhttpSettings: {path: $p, mode: "auto"}}')
        if ask_yn "启用 VLESS Encryption? (后量子加密 + Vision 流控; 客户端需 Xray 内核 ≥ 25.8)" n; then
            pick_vlessenc || return 1
            dec=$ENC_DEC flow=xtls-rprx-vision
            meta=$(jq -c --arg e "$ENC_ENC" '. + {enc: $e}' <<<"$meta")
        fi
    fi
    client=$(vless_client "$uuid" "$NEW_TAG" "$flow")
    settings=$(jq -nc --argjson c "$client" --arg d "$dec" '{clients: [$c], decryption: $d}')
    stream=$(reality_stream "$net" "$REALITY_SNI" "$REALITY_TARGET" "$REALITY_PRIV" "$(rand_hex 8)" "$extra")
    NEW_IB=$(ib_json "$NEW_TAG" "$NEW_LISTEN" "$NEW_PORT" vless "$settings" "$stream" 1)
    NEW_META=$meta
    node_finalize
}
add_vless_xhttp_tls() {
    local mode uuid path dec="none" flow="" meta='{"fp":"chrome"}' extra client settings stream
    say "部署方式:"
    say "  ${cyan}1.${none} Xray 直接提供 TLS (需要证书, 可直接套 CDN)"
    say "  ${cyan}2.${none} 由 Nginx / Caddy / CDN 反代到本机 (Xray 不做 TLS, 默认只监听 127.0.0.1)"
    mode=$(ask_choice "请选择" 1 1 2) || exit 1
    if ((mode == 1)); then
        node_common xhttp-tls tcp 443 || return 1
        pick_cert 2 "" "$NEW_TAG" || return 1
        meta=$(tls_meta "$meta")
        meta=$(jq -c --arg h "$CERT_DOMAIN" '. + {host: $h}' <<<"$meta")
        local a
        a=$(ask "客户端连接地址 (套 CDN 时可填优选 IP / 域名)" "$(jq -r '.addr // empty' <<<"$meta")") || exit 1
        meta=$(jq -c --arg a "$a" '. + {addr: $a}' <<<"$meta")
    else
        node_common xhttp tcp "" 127.0.0.1 || return 1
        meta=$(revproxy_meta "$meta")
    fi
    uuid=$(pick_uuid "$(gen_uuid)") || exit 1
    path=$(pick_path "XHTTP 路径") || exit 1
    [[ $mode == 2 && $NEW_LISTEN != 127.0.0.1 && $NEW_LISTEN != ::1 ]] && warn "Xray 未做 TLS 且监听公网, 强烈建议启用 VLESS Encryption"
    if ask_yn "启用 VLESS Encryption? (后量子加密 + Vision 流控; 客户端需 Xray 内核 ≥ 25.8)" n; then
        pick_vlessenc || return 1
        dec=$ENC_DEC flow=xtls-rprx-vision
        meta=$(jq -c --arg e "$ENC_ENC" '. + {enc: $e}' <<<"$meta")
    fi
    extra=$(jq -nc --arg p "$path" '{xhttpSettings: {path: $p, mode: "auto"}}')
    client=$(vless_client "$uuid" "$NEW_TAG" "$flow")
    settings=$(jq -nc --argjson c "$client" --arg d "$dec" '{clients: [$c], decryption: $d}')
    if ((mode == 1)); then stream=$(tls_stream xhttp "$CERT_FILE" "$KEY_FILE" "$extra"); else stream=$(plain_stream xhttp "$extra"); fi
    NEW_IB=$(ib_json "$NEW_TAG" "$NEW_LISTEN" "$NEW_PORT" vless "$settings" "$stream" 1)
    NEW_META=$meta
    ((mode == 2)) && revproxy_hint xhttp "$NEW_PORT" "$path"
    node_finalize
}
add_vless_vision_tls() {
    local uuid fb client settings stream meta='{"fp":"chrome"}'
    node_common vision-tls tcp 443 || return 1
    pick_cert 2 "" "$NEW_TAG" || return 1
    meta=$(tls_meta "$meta")
    uuid=$(pick_uuid "$(gen_uuid)") || exit 1
    fb=$(ask "回落目标 (非 VLESS 请求转发到此, 如 80 或 127.0.0.1:8080; 留空不设置)" "") || exit 1
    client=$(vless_client "$uuid" "$NEW_TAG" xtls-rprx-vision)
    settings=$(jq -nc --argjson c "$client" --arg fb "$fb" '{clients: [$c], decryption: "none"}
        + (if $fb == "" then {} elif ($fb | test("^[0-9]+$")) then {fallbacks: [{dest: ($fb | tonumber)}]} else {fallbacks: [{dest: $fb}]} end)')
    stream=$(tls_stream raw "$CERT_FILE" "$KEY_FILE")
    NEW_IB=$(ib_json "$NEW_TAG" "$NEW_LISTEN" "$NEW_PORT" vless "$settings" "$stream" 1)
    NEW_META=$meta
    node_finalize
}
add_vless_enc() {
    local uuid client settings
    node_common vless-enc tcp "" || return 1
    uuid=$(pick_uuid "$(gen_uuid)") || exit 1
    pick_vlessenc || return 1
    client=$(vless_client "$uuid" "$NEW_TAG" xtls-rprx-vision)
    settings=$(jq -nc --argjson c "$client" --arg d "$ENC_DEC" '{clients: [$c], decryption: $d}')
    NEW_IB=$(ib_json "$NEW_TAG" "$NEW_LISTEN" "$NEW_PORT" vless "$settings" "$(plain_stream raw)" 1)
    NEW_META=$(jq -nc --arg e "$ENC_ENC" '{enc: $e}')
    info "提示: 该节点无 TLS 外观, 适合中转机 ↔ 落地机之间使用, 不建议直接用于直连翻墙"
    node_finalize
}
add_ws() { # vless|vmess
    local proto=$1 mode uuid path extra client settings stream meta='{"fp":"chrome"}'
    say "部署方式:"
    say "  ${cyan}1.${none} Xray 直接提供 TLS (需要证书, 可直接套 CDN)"
    say "  ${cyan}2.${none} 由 Nginx / Caddy / CDN 反代到本机 (默认只监听 127.0.0.1)"
    mode=$(ask_choice "请选择" 1 1 2) || exit 1
    if ((mode == 1)); then
        node_common "$proto-ws-tls" tcp 443 || return 1
        pick_cert 2 "" "$NEW_TAG" || return 1
        meta=$(tls_meta "$meta")
        meta=$(jq -c --arg h "$CERT_DOMAIN" '. + {host: $h}' <<<"$meta")
    else
        node_common "$proto-ws" tcp "" 127.0.0.1 || return 1
        meta=$(revproxy_meta "$meta")
    fi
    uuid=$(pick_uuid "$(gen_uuid)") || exit 1
    path=$(pick_path "WebSocket 路径") || exit 1
    extra=$(jq -nc --arg p "$path" '{wsSettings: {path: $p}}')
    if ((mode == 1)); then stream=$(tls_stream ws "$CERT_FILE" "$KEY_FILE" "$extra" '["http/1.1"]'); else stream=$(plain_stream ws "$extra"); fi
    client=$(jq -nc --arg id "$uuid" --arg e "$NEW_TAG" '{id: $id, email: $e}')
    if [[ $proto == vless ]]; then
        settings=$(jq -nc --argjson c "$client" '{clients: [$c], decryption: "none"}')
    else
        settings=$(jq -nc --argjson c "$client" '{clients: [$c]}')
    fi
    NEW_IB=$(ib_json "$NEW_TAG" "$NEW_LISTEN" "$NEW_PORT" "$proto" "$settings" "$stream" 1)
    NEW_META=$meta
    info "提示: WebSocket 已被 Xray 标记为弃用 (仍可正常使用), 新部署建议优先选择 XHTTP"
    ((mode == 2)) && revproxy_hint ws "$NEW_PORT" "$path"
    node_finalize
}
add_trojan() {
    local sec pw client settings stream meta='{"fp":"chrome"}'
    say "传输安全:  ${cyan}1.${none} REALITY (推荐, 无需域名)   ${cyan}2.${none} TLS (需证书)"
    sec=$(ask_choice "请选择" 1 1 2) || exit 1
    if ((sec == 1)); then
        node_common trojan-reality tcp 443 || return 1
        [[ $NEW_PORT != 443 ]] && info "提示: REALITY 使用 443 以外的端口会增加被识别的概率 (Xray 官方提示)"
        pick_reality_target || return 1
        x25519_gen || return 1
    else
        node_common trojan-tls tcp 443 || return 1
        pick_cert 2 "" "$NEW_TAG" || return 1
        meta=$(tls_meta "$meta")
    fi
    pw=$(pick_password "$(rand_str 16)") || exit 1
    client=$(jq -nc --arg p "$pw" --arg e "$NEW_TAG" '{password: $p, email: $e}')
    settings=$(jq -nc --argjson c "$client" '{clients: [$c]}')
    if ((sec == 1)); then
        stream=$(reality_stream raw "$REALITY_SNI" "$REALITY_TARGET" "$REALITY_PRIV" "$(rand_hex 8)")
    else
        stream=$(tls_stream raw "$CERT_FILE" "$KEY_FILE")
    fi
    NEW_IB=$(ib_json "$NEW_TAG" "$NEW_LISTEN" "$NEW_PORT" trojan "$settings" "$stream" 1)
    NEW_META=$meta
    node_finalize
}
SS_METHODS=(2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305 aes-128-gcm aes-256-gcm chacha20-ietf-poly1305 xchacha20-ietf-poly1305)
ss_keylen() {
    case $1 in
        2022-blake3-aes-128-gcm) echo 16 ;;
        2022-blake3-*) echo 32 ;;
        *) echo 0 ;;
    esac
}
pick_ss_method() { # 默认序号
    local i
    say "加密方式:"
    for i in "${!SS_METHODS[@]}"; do say "  ${cyan}$((i + 1)).${none} ${SS_METHODS[i]}"; done
    i=$(ask_choice "请选择" "${1:-1}" 1 "${#SS_METHODS[@]}") || exit 1
    printf '%s' "${SS_METHODS[i - 1]}"
}
pick_ss_password() { # 加密方式
    local len v dl
    len=$(ss_keylen "$1")
    while :; do
        if ((len > 0)); then
            v=$(ask "密码 (${len} 字节密钥的 base64)" "$(head -c "$len" /dev/urandom | base64 | tr -d '\n')") || exit 1
            v=${v//[[:space:]]/}
            dl=$(printf '%s' "$v" | base64 -d 2>/dev/null | wc -c)
            if ((dl == len)); then
                printf '%s' "$v"
                return 0
            fi
            err "2022 系列加密的密码必须是 ${len} 字节密钥的 base64 编码"
        else
            v=$(ask "密码" "$(rand_str 16)") || exit 1
            v=${v//[[:space:]]/}
            [[ -n $v ]] && {
                printf '%s' "$v"
                return 0
            }
            error
        fi
    done
}
add_ss() {
    local method pw settings
    node_common ss both "" || return 1
    method=$(pick_ss_method 1) || exit 1
    pw=$(pick_ss_password "$method") || exit 1
    settings=$(jq -nc --arg m "$method" --arg p "$pw" '{method: $m, password: $p, network: "tcp,udp"}')
    NEW_IB=$(ib_json "$NEW_TAG" "$NEW_LISTEN" "$NEW_PORT" shadowsocks "$settings" "" 1)
    node_finalize
}
add_hy2() {
    local pw obfs="" masq extra stream settings meta
    node_common hy2 udp 443 || return 1
    pw=$(pick_password "$(rand_str 16)" "认证密码") || exit 1
    pick_cert 1 "www.bing.com" "$NEW_TAG" || return 1
    if ask_yn "启用 Salamander 混淆? (对抗 QUIC 识别; 客户端需填写相同混淆密码)" n; then
        obfs=$(pick_password "$(rand_str 16)" "混淆密码") || exit 1
    fi
    masq=$(ask "伪装网站 (非认证请求反代到此 URL, 如 https://www.bing.com; 留空返回 404)" "") || exit 1
    extra=$(jq -nc --arg o "$obfs" --arg m "$masq" '
        {hysteriaSettings: ({version: 2} + (if $m != "" then {masquerade: {type: "proxy", url: $m, rewriteHost: true}} else {} end))}
        + (if $o != "" then {finalmask: {udp: [{type: "salamander", settings: {password: $o}}]}} else {} end)')
    stream=$(tls_stream hysteria "$CERT_FILE" "$KEY_FILE" "$extra" '["h3"]')
    settings=$(jq -nc --arg p "$pw" --arg e "$NEW_TAG" '{version: 2, clients: [{auth: $p, email: $e}]}')
    meta=$(tls_meta '{}')
    ((CERT_SELF)) && meta=$(jq -c '. + {insecure: "1"}' <<<"$meta")
    NEW_IB=$(ib_json "$NEW_TAG" "$NEW_LISTEN" "$NEW_PORT" hysteria "$settings" "$stream" 1)
    NEW_META=$meta
    node_finalize
}
add_socks() {
    local user="" pass="" udp=true l4=both settings
    ask_yn "开启 UDP 转发?" y || {
        udp=false
        l4=tcp
    }
    node_common socks "$l4" "" || return 1
    if ask_yn "启用用户名密码认证? (监听公网时强烈建议)" y; then
        user=$(pick_password "$(rand_lower 8)" "用户名") || exit 1
        pass=$(pick_password "$(rand_str 16)" "密码") || exit 1
    elif [[ $NEW_LISTEN != 127.0.0.1 && $NEW_LISTEN != ::1 ]]; then
        warn "未启用认证且监听公网, 任何人都能使用该代理!"
    fi
    settings=$(jq -nc --arg u "$user" --arg p "$pass" --argjson udp "$udp" '
        (if $u != "" then {auth: "password", accounts: [{user: $u, pass: $p}]} else {auth: "noauth"} end) + {udp: $udp}')
    NEW_IB=$(ib_json "$NEW_TAG" "$NEW_LISTEN" "$NEW_PORT" socks "$settings" "" 1)
    node_finalize
}
add_tunnel() {
    local addr tport net l4 settings
    addr=$(ask_required "转发目标地址 (IP 或域名, 如落地机 IP)") || exit 1
    tport=$(ask_required "转发目标端口") || exit 1
    is_port "$tport" || {
        err "端口无效"
        return 1
    }
    tport=$((10#$tport))
    say "转发协议:  ${cyan}1.${none} TCP+UDP   ${cyan}2.${none} 仅 TCP   ${cyan}3.${none} 仅 UDP"
    case $(ask_choice "请选择" 1 1 3) in
        1) net="tcp,udp" l4=both ;;
        2) net=tcp l4=tcp ;;
        3) net=udp l4=udp ;;
    esac
    node_common fwd "$l4" "$tport" || return 1
    settings=$(jq -nc --arg a "$addr" --argjson p "$tport" --arg n "$net" '{address: $a, port: $p, network: $n}')
    NEW_IB=$(ib_json "$NEW_TAG" "$NEW_LISTEN" "$NEW_PORT" tunnel "$settings" "" 0)
    info "提示: 端口转发原样转发数据, 已关闭流量嗅探 (避免转发 REALITY/TLS 时被嗅探到的域名带偏)"
    node_finalize
}

# ---------------------------------------------------------------------
# 分享链接
# ---------------------------------------------------------------------
mk_query() { # 键 值 键 值 ...  (跳过空值)
    local out="" k v
    while (($# >= 2)); do
        k=$1 v=$2
        shift 2
        [[ -z $v ]] && continue
        out+="${out:+&}$k=$(urlenc "$v")"
    done
    printf '%s' "$out"
}
node_links() { # 节点名 [link|mihomo] → 每行: 备注\x1f链接(或 mihomo 代理 JSON)
    local tag=$1 fmt=${2:-link} ib meta F M mt
    ib=$(cfg_get '.inbounds[] | select(.tag == $t)' -c --arg t "$tag")
    [[ -n $ib ]] || return 1
    meta=$(meta_get '.nodes[$t] // {}' -c --arg t "$tag")
    [[ -n $meta ]] || meta='{}'
    local proto net sec port dec rpk rsni rsid rseed tsni path hhost mode svc obfspw ssm ssp suser spass
    F=$(jq -r "$JQ_LIB"'[.protocol, netname, secname, (.port | tostring), (.settings.decryption // "none"),
          (.streamSettings.realitySettings.privateKey // ""),
          ((.streamSettings.realitySettings.serverNames // [])[0] // ""),
          ([(.streamSettings.realitySettings.shortIds // [])[] | select(. != "")][0] // ""),
          (.streamSettings.realitySettings.mldsa65Seed // ""),
          (.streamSettings.tlsSettings.serverName // ""),
          (.streamSettings.wsSettings.path // .streamSettings.xhttpSettings.path // .streamSettings.splithttpSettings.path
             // .streamSettings.httpupgradeSettings.path // ""),
          (.streamSettings.wsSettings.host // .streamSettings.xhttpSettings.host // .streamSettings.httpupgradeSettings.host // ""),
          (.streamSettings.xhttpSettings.mode // ""), (.streamSettings.grpcSettings.serviceName // ""),
          ([.streamSettings.finalmask.udp[]? | select(.type == "salamander") | .settings.password][0] // ""),
          (.settings.method // ""), (.settings.password // ""),
          (.settings.accounts[0].user // ""), (.settings.accounts[0].pass // "")]
        | map(tostring) | join("\u001f")' <<<"$ib")
    IFS=$'\x1f' read -r proto net sec port dec rpk rsni rsid rseed tsni path hhost mode svc obfspw ssm ssp suser spass <<<"$F"
    local maddr mlport mfp msni mhost mspx menc mpcs mpqv malpn mlsec minsec
    M=$(jq -r '[.addr, .lport, .fp, .sni, .host, .spx, .enc, .pcs, .pqv, .alpn, .lsec, .insecure]
        | map(if . == null then "" else tostring end) | join("\u001f")' <<<"$meta")
    IFS=$'\x1f' read -r maddr mlport mfp msni mhost mspx menc mpcs mpqv malpn mlsec minsec <<<"$M"

    local addr hostf lport lsec typ fp sni="" pbk="" sid="" spx="" pqv="" alpn="" pcs="" enc=none hh q link
    addr=${maddr:-$(server_addr)}
    hostf=$(fmt_host "$addr")
    lport=${port%%[,-]*}
    [[ -n $mlport && $mlport != 0 ]] && lport=$mlport
    lsec=${mlsec:-$sec}
    fp=${mfp:-chrome}
    if [[ $net == raw ]]; then typ=tcp; else typ=$net; fi
    hh=${mhost:-$hhost}
    case $lsec in
        reality)
            sni=${msni:-$rsni}
            pbk=$(x25519_pub "$rpk")
            sid=$rsid spx=$mspx pqv=$mpqv
            [[ -z $pqv && -n $rseed ]] && pqv=$(mldsa65_verify "$rseed")
            ;;
        tls) sni=${msni:-$tsni} alpn=$malpn pcs=$mpcs ;;
        *) fp="" ;;
    esac
    [[ -n $dec && $dec != none ]] && enc=${menc:-$(vlessenc_client "$dec")}

    local -a clients=()
    mapfile -t clients < <(jq -r '(.settings.clients // [])[] | [(.email // ""), (.id // .password // .auth // ""), (.flow // "")] | join("\u001f")' <<<"$ib")
    local n=${#clients[@]} c email cred flow remark hmode=""
    [[ $typ == xhttp ]] && hmode=${mode:-auto}
    case $proto in
        vless | trojan | vmess | hysteria)
            for c in "${clients[@]}"; do
                IFS=$'\x1f' read -r email cred flow <<<"$c"
                if ((n > 1)); then remark=$email; else remark=$tag; fi
                if [[ $fmt == mihomo ]]; then
                    if [[ $proto == hysteria ]]; then mt=hysteria2; else mt=$proto; fi
                    printf '%s\x1f%s\n' "$remark" "$(mh_json "$mt" "$remark" "$cred")"
                    continue
                fi
                case $proto in
                    vless)
                        q=$(mk_query encryption "$enc" flow "$flow" security "$lsec" sni "$sni" fp "$fp" pbk "$pbk" sid "$sid" \
                            spx "$spx" pqv "$pqv" alpn "$alpn" pcs "$pcs" type "$typ" headerType "$([[ $typ == tcp ]] && echo none)" \
                            path "$path" host "$hh" mode "$hmode" serviceName "$svc")
                        link="vless://$(urlenc "$cred")@$hostf:$lport?$q#$(urlenc "$remark")"
                        ;;
                    trojan)
                        q=$(mk_query security "$lsec" sni "$sni" fp "$fp" pbk "$pbk" sid "$sid" spx "$spx" pqv "$pqv" alpn "$alpn" \
                            pcs "$pcs" type "$typ" headerType "$([[ $typ == tcp ]] && echo none)" path "$path" host "$hh" \
                            mode "$hmode" serviceName "$svc")
                        link="trojan://$(urlenc "$cred")@$hostf:$lport?$q#$(urlenc "$remark")"
                        ;;
                    vmess)
                        link="vmess://$(b64enc "$(jq -nc --arg ps "$remark" --arg add "$addr" --arg port "$lport" --arg id "$cred" \
                            --arg net "$typ" --arg host "$hh" --arg path "$path" --arg tls "$([[ $lsec == tls ]] && echo tls)" \
                            --arg sni "$sni" --arg alpn "$alpn" --arg fp "$fp" \
                            '{v: "2", ps: $ps, add: $add, port: $port, id: $id, aid: "0", scy: "auto", net: $net, type: "none",
                              host: $host, path: $path, tls: $tls, sni: $sni, alpn: $alpn, fp: $fp}')")"
                        ;;
                    hysteria)
                        q=$(mk_query sni "${msni:-$tsni}" alpn h3 insecure "$([[ $minsec == 1 ]] && echo 1)" pinSHA256 "$mpcs" \
                            obfs "$([[ -n $obfspw ]] && echo salamander)" obfs-password "$obfspw")
                        link="hysteria2://$(urlenc "$cred")@$hostf:$lport/?$q#$(urlenc "$remark")"
                        ;;
                esac
                printf '%s\x1f%s\n' "$remark" "$link"
            done
            ;;
        shadowsocks)
            [[ -n $ssm && -n $ssp ]] || return 0
            if [[ $fmt == mihomo ]]; then
                printf '%s\x1f%s\n' "$tag" "$(mh_json ss "$tag" "")"
                return 0
            fi
            if [[ $ssm == 2022-* ]]; then
                link="ss://$ssm:$(urlenc "$ssp")@$hostf:$lport#$(urlenc "$tag")"
            else
                link="ss://$(b64url "$ssm:$ssp")@$hostf:$lport#$(urlenc "$tag")"
            fi
            printf '%s\x1f%s\n' "$tag" "$link"
            ;;
        socks | mixed)
            if [[ $fmt == mihomo ]]; then
                printf '%s\x1f%s\n' "$tag" "$(mh_json socks5 "$tag" "")"
                return 0
            fi
            if [[ -n $suser ]]; then
                link="socks://$(b64enc "$suser:$spass")@$hostf:$lport#$(urlenc "$tag")"
            else
                link="socks://$hostf:$lport#$(urlenc "$tag")"
            fi
            printf '%s\x1f%s\n' "$tag" "$link"
            ;;
    esac
    return 0
}
read -r -d '' JQ_MIHOMO <<'JQEOF'
def nz: . != null and . != "";
def netopts:
  if $net == "ws" then {network: "ws", "ws-opts": ({path: (if $path | nz then $path else "/" end)} + (if $host | nz then {headers: {Host: $host}} else {} end))}
  elif $net == "httpupgrade" then {network: "ws", "ws-opts": ({path: (if $path | nz then $path else "/" end), "v2ray-http-upgrade": true} + (if $host | nz then {headers: {Host: $host}} else {} end))}
  elif $net == "grpc" then {network: "grpc", "grpc-opts": {"grpc-service-name": $svc}}
  elif $net == "xhttp" then {network: "xhttp", "xhttp-opts": ({path: (if $path | nz then $path else "/" end)} + (if $host | nz then {host: $host} else {} end) + (if $mode | nz then {mode: $mode} else {} end))}
  else {network: "tcp"} end;
def tlsopts($snikey):
  if $sec == "tls" or $sec == "reality" then
    (if $sni | nz then {($snikey): $sni} else {} end)
    + (if ($fp | nz) and $type != "hysteria2" then {"client-fingerprint": $fp} else {} end)
    + (if $sec == "reality" then {"reality-opts": ({"public-key": $pbk, "support-x25519mlkem768": true} + (if $sid | nz then {"short-id": $sid} else {} end))} else {} end)
    + (if $pin | nz then {fingerprint: $pin} else {} end)
  else {} end;
{name: $name, type: $type, server: $addr, port: ($port | tonumber)}
+ (if $type == "vless" then
     {uuid: $cred, udp: true} + (if $flow | nz then {flow: $flow} else {} end)
     + (if ($enc | nz) and $enc != "none" then {encryption: $enc} else {} end)
     + (if $sec == "tls" or $sec == "reality" then {tls: true} else {} end) + tlsopts("servername") + netopts
   elif $type == "vmess" then
     {uuid: $cred, alterId: 0, cipher: "auto", udp: true} + (if $sec == "tls" then {tls: true} else {} end) + tlsopts("servername") + netopts
   elif $type == "trojan" then {password: $cred, udp: true} + tlsopts("sni") + netopts
   elif $type == "hysteria2" then
     {password: $cred, alpn: ["h3"]} + tlsopts("sni") + (if $obfs | nz then {obfs: "salamander", "obfs-password": $obfs} else {} end)
   elif $type == "ss" then {cipher: $method, password: $sspw, udp: true}
   elif $type == "socks5" then {udp: true} + (if $user | nz then {username: $user, password: $upass} else {} end)
   else {} end)
JQEOF
mh_json() { # 类型 名称 凭证   (读取 node_links 的局部变量)
    jq -nc --arg type "$1" --arg name "$2" --arg cred "$3" --arg addr "$addr" --arg port "$lport" --arg flow "${flow:-}" \
        --arg enc "$enc" --arg sec "$lsec" --arg sni "$sni" --arg fp "$fp" --arg pbk "$pbk" --arg sid "$sid" --arg pin "$pcs" \
        --arg net "$typ" --arg path "$path" --arg host "$hh" --arg mode "$hmode" --arg svc "$svc" --arg obfs "$obfspw" \
        --arg method "$ssm" --arg sspw "$ssp" --arg user "$suser" --arg upass "$spass" "$JQ_MIHOMO"
}
mihomo_print() { # [节点名]  输出 mihomo (Clash Meta) 的 proxies 片段
    local tag
    [[ -s $CONFIG_FILE ]] || return 0
    printf '# mihomo (Clash Meta) 节点配置, 复制到配置文件的 proxies: 下\n'
    printf '# REALITY 节点已加 support-x25519mlkem768: true (分享链接无法携带该参数, 缺少时新版 Xray 会拒绝连接)\n'
    printf 'proxies:\n'
    if [[ -n ${1:-} ]]; then
        node_links "$1" mihomo | cut -d $'\x1f' -f 2 | sed 's/^/  - /'
        return
    fi
    while IFS= read -r tag; do
        [[ -n $tag ]] && node_links "$tag" mihomo | cut -d $'\x1f' -f 2 | sed 's/^/  - /'
    done < <(cfg_get '.inbounds[]?.tag')
}
links_refresh() { # 重新生成链接文件
    local tmp tag label lines l
    [[ -s $CONFIG_FILE ]] || return 0
    mkdir -p "${LINK_FILE%/*}" 2>/dev/null
    tmp=$(tmpf)
    {
        printf '# Xray 节点分享链接 (脚本自动生成, 修改节点后自动刷新)\n# 生成时间: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        while IFS=$'\x1f' read -r tag label; do
            [[ -n $tag ]] || continue
            lines=$(node_links "$tag")
            [[ -n $lines ]] || continue
            printf '[%s] %s\n' "$tag" "$label"
            while IFS= read -r l; do printf '%s\n' "${l#*$'\x1f'}"; done <<<"$lines"
            printf '\n'
        done < <(jq -r "$JQ_LIB"' .inbounds[]? | [.tag, nlabel] | join("\u001f")' "$CONFIG_FILE" 2>/dev/null)
    } >"$tmp"
    mv -f "$tmp" "$LINK_FILE" && chmod 600 "$LINK_FILE"
}
links_print() { # [节点名]  只输出链接本身 (stdout), 便于复制或管道
    local tag
    [[ -s $CONFIG_FILE ]] || return 0
    if [[ -n ${1:-} ]]; then
        node_links "$1" | cut -d $'\x1f' -f 2
        return
    fi
    while IFS= read -r tag; do
        [[ -n $tag ]] && node_links "$tag" | cut -d $'\x1f' -f 2
    done < <(cfg_get '.inbounds[]?.tag')
}
node_qr() { # 节点名
    command -v qrencode >/dev/null 2>&1 || ensure_cmds qrencode || return 1
    local name link
    while IFS=$'\x1f' read -r name link; do
        say "${yellow}$name${none}"
        qrencode -t ANSIUTF8 -m 1 "$link" >&2
    done < <(node_links "$1")
}
node_extra_info() { # 节点名   打印便于手动填写的关键参数
    local tag=$1 ib proto sec pcs
    ib=$(cfg_get '.inbounds[] | select(.tag == $t)' -c --arg t "$tag")
    proto=$(jq -r '.protocol' <<<"$ib")
    sec=$(jq -r '.streamSettings.security // "none"' <<<"$ib")
    if [[ $sec == reality ]]; then
        say " REALITY: SNI=$(jq -r '.streamSettings.realitySettings.serverNames[0] // ""' <<<"$ib")  target=$(jq -r '.streamSettings.realitySettings.target // .streamSettings.realitySettings.dest // ""' <<<"$ib")"
        say " 公钥(pbk)=$(x25519_pub "$(jq -r '.streamSettings.realitySettings.privateKey' <<<"$ib")")  shortIds=$(jq -r '.streamSettings.realitySettings.shortIds | join(",")' <<<"$ib")"
    fi
    case $proto in
        shadowsocks) say " 加密: $(jq -r '.settings.method' <<<"$ib")  密码: $(jq -r '.settings.password' <<<"$ib")" ;;
        socks | mixed) say " 认证: $(jq -r 'if .settings.auth == "password" then (.settings.accounts[0].user + " / " + .settings.accounts[0].pass) else "无" end' <<<"$ib")   (同一端口同时支持 SOCKS5 与 HTTP 代理)" ;;
        tunnel | dokodemo-door) say " 转发: 本机 :$(jq -r '.port' <<<"$ib") → $(jq -r '((.settings.address // .settings.rewriteAddress) | tostring) + ":" + ((.settings.port // .settings.rewritePort) | tostring)' <<<"$ib")" ;;
    esac
    pcs=$(meta_get '.nodes[$t].pcs // ""' --arg t "$tag")
    [[ -n $pcs ]] && say " 证书指纹(SHA256): ${pcs}
   ${gray}(自签证书: v2rayN ≥ 7.22.5 / v2rayNG ≥ 2.0.12 等新版 Xray 内核客户端读取链接里的 pcs/pinSHA256; 其他客户端请开启“跳过证书验证”)${none}"
    return 0
}
show_node() { # 节点名
    local tag=$1 row label listen port l4 out def links name link
    row=$(cfg_getL '.inbounds[] | select(.tag == $t) | [nlabel, ((.listen // "0.0.0.0") | tostring), (.port | tostring), l4s] | join("\u001f")' --arg t "$tag")
    [[ -n $row ]] || {
        err "节点 [$tag] 不存在"
        return 1
    }
    IFS=$'\x1f' read -r label listen port l4 <<<"$row"
    out=$(cfg_getL 'node_out($t)' --arg t "$tag")
    def=$(cfg_getL 'default_out')
    title "节点 [$tag]"
    say " 协议: ${green}$label${none}"
    say " 监听: $listen:$port ($l4)"
    if [[ -n $out ]]; then say " 出站: $(out_name "$out")"; else say " 出站: 默认 ($(out_name "$def"))"; fi
    node_extra_info "$tag"
    links=$(node_links "$tag")
    if [[ -z $links ]]; then
        say " ${gray}(该类型节点没有分享链接)${none}"
        return 0
    fi
    hr
    while IFS=$'\x1f' read -r name link; do
        say " ${yellow}$name${none}"
        printf '%s\n' "$link"
    done <<<"$links"
    hr
    say " ${gray}全部链接保存在: $LINK_FILE${none}"
    if [[ $label == *REALITY* ]]; then
        say " ${yellow}mihomo / Clash Meta 客户端: 请用 ${SHORTCUT##*/} mihomo 导出的配置 (链接导入会缺少 support-x25519mlkem768, 连新版 Xray 会失败)${none}"
    fi
}
view_nodes_menu() {
    cfg_load || return 1
    title "节点列表"
    list_nodes || return 0
    say ""
    say " 输入序号查看详情和分享链接;  ${cyan}a${none} 输出全部链接及订阅(base64);  ${cyan}m${none} 输出 mihomo (Clash Meta) 配置;  ${cyan}0${none} 返回"
    local c
    c=$(ask "请选择" 0)
    case $c in
        0) return 0 ;;
        m | M) mihomo_print ;;
        a | A)
            links_print
            say ""
            info "订阅内容 (base64, 可粘贴到支持订阅文本的客户端):"
            links_print | base64 | tr -d '\n'
            printf '\n'
            ;;
        *)
            if [[ $c =~ ^[0-9]+$ ]] && ((c >= 1 && c <= ${#NODE_TAGS[@]})); then
                show_node "${NODE_TAGS[c - 1]}"
                ask_yn "显示二维码?" n && node_qr "${NODE_TAGS[c - 1]}"
            else
                error
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------
# 管理节点
# ---------------------------------------------------------------------
manage_nodes_menu() {
    local c
    while :; do
        cfg_load || return 1
        title "管理节点"
        list_nodes || return 0
        c=$(ask_choice "选择要管理的节点 (0 返回)" 0 0 "${#NODE_TAGS[@]}") || exit 1
        ((c == 0)) && return 0
        node_menu "${NODE_TAGS[c - 1]}"
    done
}
node_menu() { # 节点名
    local tag=$1 proto c
    while :; do
        cfg_load || return 1
        proto=$(cfg_get '.inbounds[] | select(.tag == $t) | .protocol' --arg t "$tag")
        [[ -n $proto ]] || return 0
        title "管理节点 [$tag]  $(cfg_getL '.inbounds[] | select(.tag == $t) | nlabel + "  端口 " + (.port | tostring)' --arg t "$tag")"
        say " ${cyan}1.${none} 修改端口            ${cyan}2.${none} 修改监听地址        ${cyan}3.${none} 修改名称"
        say " ${cyan}4.${none} 设置出站 / 落地     ${cyan}5.${none} 用户管理 (多用户)   ${cyan}6.${none} 协议参数"
        say " ${cyan}7.${none} 分享链接参数 (连接地址 / NAT 外部端口 / 指纹 / SNI)"
        say " ${cyan}8.${none} 查看分享链接 / 二维码"
        say " ${cyan}9.${none} ${red}删除此节点${none}"
        say " ${cyan}0.${none} 返回"
        c=$(ask_choice "请选择" 0 0 9) || exit 1
        case $c in
            0) return 0 ;;
            1) node_set_port "$tag" ;;
            2) node_set_listen "$tag" ;;
            3) node_rename "$tag" && tag=$RENAMED_TAG ;;
            4) node_set_out "$tag" ;;
            5)
                case $proto in
                    vless | vmess | trojan | hysteria) users_menu "$tag" ;;
                    *) warn "该类型节点不支持多用户" ;;
                esac
                ;;
            6) node_params_menu "$tag" ;;
            7) node_link_params "$tag" ;;
            8)
                show_node "$tag"
                ask_yn "显示二维码?" n && node_qr "$tag"
                ;;
            9) node_delete "$tag" && return 0 ;;
        esac
    done
}
node_update() { # 节点名 jq表达式(作用于该入站对象) [jq 选项...]  → 修改并提交
    local tag=$1 f=$2
    shift 2
    cfg_jqL "(.inbounds[] | select(.tag == \$__t)) |= ($f)" --arg __t "$tag" "$@" && cfg_commit
}
node_set_port() { # 节点名 [新端口]
    local tag=$1 new=${2:-} old l4 owner lp
    cfg_load || return 1
    old=$(cfg_get '.inbounds[] | select(.tag == $t) | .port | tostring' --arg t "$tag")
    [[ -n $old ]] || {
        err "节点 [$tag] 不存在"
        return 1
    }
    l4=$(cfg_getL '.inbounds[] | select(.tag == $t) | l4s' --arg t "$tag")
    if [[ -z $new ]]; then
        say "当前端口: $old ($l4)"
        new=$(pick_port "$l4" "$old" "$tag") || exit 1
    else
        is_port "$new" || {
            err "端口无效: $new"
            return 1
        }
        new=$((10#$new))
        owner=$(port_owner "$new" "$l4" "$tag")
        [[ -n $owner ]] && {
            err "端口 $new 已被节点 [$owner] 使用"
            return 1
        }
        if [[ $new != "$old" ]] && port_busy "$new" "$l4"; then
            err "端口 $new 已被本机其他程序占用"
            return 1
        fi
    fi
    [[ $new == "$old" ]] && {
        info "端口未变化"
        return 0
    }
    node_update "$tag" '.port = ($p | tonumber)' --arg p "$new" || return 1
    fw_apply open "$new" "$l4"
    [[ $old =~ ^[0-9]+$ && -z $(port_owner "$old" "$l4") ]] && fw_apply close "$old" "$l4"
    ok "节点 [$tag] 端口已修改: $old → $new"
    lp=$(meta_get '.nodes[$t].lport // ""' --arg t "$tag")
    [[ -n $lp && $lp != 0 ]] && warn "该节点设置了分享链接外部端口 $lp (NAT 映射/反代), 如有变化请在“分享链接参数”中同步修改"
    return 0
}
node_set_listen() {
    local tag=$1 cur new
    cfg_load || return 1
    cur=$(cfg_get '.inbounds[] | select(.tag == $t) | .listen // "0.0.0.0"' --arg t "$tag")
    new=$(pick_listen "$cur") || exit 1
    [[ $new == "$cur" ]] && return 0
    node_update "$tag" '.listen = $l' --arg l "$new" && ok "监听地址已改为 $new"
}
node_rename() {
    local tag=$1 new
    RENAMED_TAG=$tag
    cfg_load || return 1
    new=$(pick_tag "$tag" "新名称" "$tag") || exit 1
    [[ $new == "$tag" ]] && return 0
    cfg_jq '(.inbounds[] | select(.tag == $o) | .tag) = $n
        | .routing.rules |= map(
            (if .ruleTag == ("xs-node-" + $o) then .ruleTag = ("xs-node-" + $n) else . end)
            | (if (.inboundTag | type) == "array" then .inboundTag |= map(if . == $o then $n else . end) else . end))' \
        --arg o "$tag" --arg n "$new" || return 1
    meta_set '.nodes[$n] = (.nodes[$o] // {}) | del(.nodes[$o])' --arg o "$tag" --arg n "$new"
    if ! cfg_commit; then
        meta_set '.nodes[$o] = (.nodes[$n] // {}) | del(.nodes[$n])' --arg o "$tag" --arg n "$new"
        return 1
    fi
    RENAMED_TAG=$new
    ok "已重命名: $tag → $new"
}
node_set_out() {
    local tag=$1
    cfg_load || return 1
    pick_outbound "节点 [$tag] 的出站" 1 || return 1
    cfg_jqL 'set_node_out($t; $o)' --arg t "$tag" --arg o "$PICKED_OUT" || return 1
    cfg_commit && ok "节点 [$tag] 出站: $(out_name "$PICKED_OUT")"
}
node_delete() {
    local tag=$1 port l4 crt
    cfg_load || return 1
    IFS=$'\x1f' read -r port l4 < <(cfg_getL '.inbounds[] | select(.tag == $t) | [(.port | tostring), l4s] | join("\u001f")' --arg t "$tag")
    ask_yn "确定删除节点 [$tag]?" n || return 1
    crt=$(cfg_get '.inbounds[] | select(.tag == $t) | .streamSettings.tlsSettings.certificates[0].certificateFile // ""' --arg t "$tag")
    cfg_jqL '([.inbounds[] | select(.tag == $t) | .settings.clients[]?.email] | map(select(. != null))) as $em
        | .inbounds |= map(select(.tag != $t))
        | .routing.rules |= map(select(.ruleTag != ("xs-node-" + $t)))
        | .routing.rules |= map(select((((.ruleTag // "") | startswith("xs-user-")) and ((.user // []) | any(.[]; . as $u | $em | hasv($u)))) | not))
        | .routing.rules |= map(if ((.ruleTag // "") | startswith("xs-custom")) and ((.inboundTag | type) == "array")
                                then (.inboundTag -= [$t] | select((.inboundTag | length) > 0)) else . end)' --arg t "$tag" || return 1
    cfg_commit || return 1
    meta_set 'del(.nodes[$t])' --arg t "$tag"
    if [[ $crt == "$CERT_DIR"/self-* && -z $(cfg_get '.. | .certificateFile? // empty | select(. == $c)' --arg c "$crt") ]]; then
        rm -f "$crt" "${crt%.crt}.key"
    fi
    [[ $port =~ ^[0-9]+$ && -z $(port_owner "$port" "$l4") ]] && fw_apply close "$port" "$l4"
    ok "节点 [$tag] 已删除"
}

# ---- 用户管理 ----------------------------------------------------------
list_users() { # 节点名 → 打印并填充 USER_LIST
    local rows row i=0 email cred out
    USER_LIST=()
    mapfile -t rows < <(cfg_getL '. as $r | .inbounds[] | select(.tag == $t) | .settings.clients[]? | .email as $em
        | [$em, ((.id // .password // .auth // "") | tostring), ($r | user_out($em))] | join("\u001f")' --arg t "$1")
    for row in "${rows[@]}"; do
        IFS=$'\x1f' read -r email cred out <<<"$row"
        i=$((i + 1))
        USER_LIST+=("$email")
        say " ${cyan}$i.${none} ${bold}$email${none}  ${gray}$cred${none}  出站: $(if [[ -n $out ]]; then out_name "$out"; else echo "跟随节点"; fi)"
    done
}
pick_user() { # 在 list_users 之后调用 → PICKED_USER
    local c
    ((${#USER_LIST[@]})) || return 1
    c=$(ask_choice "选择用户 (0 取消)" 0 0 "${#USER_LIST[@]}") || exit 1
    ((c == 0)) && return 1
    PICKED_USER=${USER_LIST[c - 1]}
}
users_menu() {
    local tag=$1 key c
    while :; do
        cfg_load || return 1
        key=$(cfg_getL '.inbounds[] | select(.tag == $t) | cred_key' --arg t "$tag")
        title "用户管理 [$tag]  (每个用户可单独指定落地)"
        list_users "$tag"
        say " ${cyan}1.${none} 添加用户   ${cyan}2.${none} 删除用户   ${cyan}3.${none} 修改凭证   ${cyan}4.${none} 设置用户落地   ${cyan}5.${none} 查看链接   ${cyan}0.${none} 返回"
        c=$(ask_choice "请选择" 0 0 5) || exit 1
        case $c in
            0) return 0 ;;
            1) user_add "$tag" "$key" ;;
            2) pick_user && user_del "$tag" "$PICKED_USER" ;;
            3) pick_user && user_cred "$tag" "$key" "$PICKED_USER" ;;
            4) pick_user && user_set_out "$PICKED_USER" ;;
            5) show_node "$tag" ;;
        esac
    done
}
new_cred() { # 凭证类型 → 交互输入
    if [[ $1 == id ]]; then pick_uuid "$(gen_uuid)"; else pick_password "$(rand_str 16)"; fi
}
user_add() { # 节点名 凭证类型
    local tag=$1 key=$2 name cred flow
    name=$(pick_email "$(next_email "$tag")") || exit 1
    cred=$(new_cred "$key") || exit 1
    flow=$(cfg_get '.inbounds[] | select(.tag == $t) | .settings.clients[0].flow // ""' --arg t "$tag")
    cfg_jq '(.inbounds[] | select(.tag == $t) | .settings.clients) += [({email: $e, ($k): $c} + (if $f != "" then {flow: $f} else {} end))]' \
        --arg t "$tag" --arg e "$name" --arg k "$key" --arg c "$cred" --arg f "$flow" || return 1
    if ask_yn "为该用户单独指定落地? (默认跟随节点)" n; then
        pick_outbound "用户 [$name] 的出站" 1 || return 1
        if [[ -n $PICKED_OUT ]]; then cfg_jqL 'set_user_out($e; $o)' --arg e "$name" --arg o "$PICKED_OUT" || return 1; fi
    fi
    cfg_commit && ok "已添加用户 [$name]"
}
user_del() { # 节点名 用户
    local n
    n=$(cfg_get '.inbounds[] | select(.tag == $t) | .settings.clients | length' --arg t "$1")
    ((${n:-0} <= 1)) && {
        err "至少要保留一个用户"
        return 1
    }
    ask_yn "确定删除用户 [$2]?" n || return 1
    cfg_jqL '(.inbounds[] | select(.tag == $t) | .settings.clients) |= map(select(.email != $e)) | set_user_out($e; "")' \
        --arg t "$1" --arg e "$2" || return 1
    cfg_commit && ok "已删除用户 [$2]"
}
user_cred() { # 节点名 凭证类型 用户
    local cred
    cred=$(new_cred "$2") || exit 1
    cfg_jq '(.inbounds[] | select(.tag == $t) | .settings.clients[] | select(.email == $e) | .[$k]) = $c' \
        --arg t "$1" --arg e "$3" --arg k "$2" --arg c "$cred" || return 1
    cfg_commit && ok "用户 [$3] 凭证已更新, 请重新导入分享链接"
}
user_set_out() { # 用户
    pick_outbound "用户 [$1] 的出站" 1 || return 1
    cfg_jqL 'set_user_out($e; $o)' --arg e "$1" --arg o "$PICKED_OUT" || return 1
    cfg_commit && ok "用户 [$1] 出站: $(if [[ -n $PICKED_OUT ]]; then out_name "$PICKED_OUT"; else echo 跟随节点; fi)"
}

# ---- 协议参数 ----------------------------------------------------------
node_params_menu() {
    local tag=$1 proto net sec c i
    local -a acts names
    while :; do
        cfg_load || return 1
        IFS=$'\x1f' read -r proto net sec < <(cfg_getL '.inbounds[] | select(.tag == $t) | [.protocol, netname, secname] | join("\u001f")' --arg t "$tag")
        [[ -n $proto ]] || return 0
        acts=() names=()
        if [[ $sec == reality ]]; then
            acts+=(r_target r_sid r_keys r_mldsa)
            names+=("REALITY 目标网站 (SNI / target)" "REALITY shortIds" "重新生成 REALITY 密钥对" "ML-DSA-65 后量子签名 (开 / 关)")
        fi
        [[ $sec == tls ]] && {
            acts+=(t_cert)
            names+=("更换 TLS 证书")
        }
        case $net in
            xhttp)
                acts+=(x_path x_mode x_host)
                names+=("XHTTP 路径" "XHTTP 模式 (auto / packet-up / stream-up / stream-one)" "XHTTP host (服务端校验, 一般留空)")
                ;;
            ws | httpupgrade)
                acts+=(w_path w_host)
                names+=("路径" "host")
                ;;
        esac
        [[ $proto == vless ]] && {
            acts+=(v_enc)
            names+=("VLESS Encryption (开 / 关 / 重新生成)")
        }
        case $proto in
            shadowsocks)
                acts+=(s_method)
                names+=("加密方式与密码")
                ;;
            hysteria)
                acts+=(h_obfs h_masq)
                names+=("Salamander 混淆 (开 / 关 / 改密码)" "伪装网站")
                ;;
            socks | mixed)
                acts+=(k_auth k_udp)
                names+=("认证 (用户名 / 密码)" "UDP 开关")
                ;;
            tunnel | dokodemo-door)
                acts+=(f_target)
                names+=("转发目标")
                ;;
        esac
        if [[ $proto != tunnel && $proto != dokodemo-door ]]; then
            acts+=(sniff)
            names+=("流量嗅探 (开 / 关, 域名分流和屏蔽 BT 依赖它)")
        fi
        title "协议参数 [$tag]"
        for i in "${!names[@]}"; do say " ${cyan}$((i + 1)).${none} ${names[i]}"; done
        say " ${cyan}0.${none} 返回"
        c=$(ask_choice "请选择" 0 0 "${#acts[@]}") || exit 1
        ((c == 0)) && return 0
        "p_${acts[c - 1]}" "$tag"
    done
}
ibget() { cfg_get ".inbounds[] | select(.tag == \$t) | $2" --arg t "$1"; }
p_r_target() {
    say "当前: SNI=$(ibget "$1" '.streamSettings.realitySettings.serverNames | join(",")')  target=$(ibget "$1" '.streamSettings.realitySettings.target // .streamSettings.realitySettings.dest')"
    pick_reality_target || return 1
    node_update "$1" '.streamSettings.realitySettings |= (del(.dest) | .target = $g | .serverNames = [$s])' \
        --arg g "$REALITY_TARGET" --arg s "$REALITY_SNI" && ok "已更新, 请重新导入分享链接"
}
p_r_sid() {
    local cur v s ok_all=1
    cur=$(ibget "$1" '.streamSettings.realitySettings.shortIds | join(",")')
    v=$(ask "shortIds (逗号分隔, 每个为 0-16 位偶数长度的十六进制, 可含空值; 输入 new 随机生成)" "$cur") || exit 1
    [[ $v == new ]] && v=$(rand_hex 8)
    v=${v,,}
    v=${v//[[:space:]]/}
    for s in ${v//,/ }; do [[ $s =~ ^[0-9a-f]{0,16}$ && $((${#s} % 2)) -eq 0 ]] || ok_all=0; done
    ((ok_all)) || {
        err "shortId 格式错误"
        return 1
    }
    node_update "$1" '.streamSettings.realitySettings.shortIds = ($v | split(","))' --arg v "$v" && ok "已更新 (链接使用第一个非空 shortId)"
}
p_r_keys() {
    ask_yn "重新生成密钥对后, 所有客户端都需要重新导入链接, 继续?" n || return 0
    x25519_gen || return 1
    node_update "$1" '.streamSettings.realitySettings.privateKey = $k' --arg k "$REALITY_PRIV" && ok "新公钥 (pbk): $REALITY_PUB"
}
p_r_mldsa() {
    if [[ -n $(ibget "$1" '.streamSettings.realitySettings.mldsa65Seed // empty') ]]; then
        node_update "$1" '.streamSettings.realitySettings |= del(.mldsa65Seed)' && meta_set 'del(.nodes[$t].pqv)' --arg t "$1" && ok "已关闭 ML-DSA-65"
    else
        warn "注意: 开启后 target 返回的证书链长度必须大于 3500 字节 (可用 xray tls ping 目标域名 查看), 否则会产生特征"
        ask_yn "继续开启?" n || return 0
        mldsa65_gen || {
            err "生成失败 (需要 Xray ≥ 25.5)"
            return 1
        }
        meta_set '.nodes[$t].pqv = $v' --arg t "$1" --arg v "$MLDSA_VERIFY"
        node_update "$1" '.streamSettings.realitySettings.mldsa65Seed = $s' --arg s "$MLDSA_SEED" && ok "已开启, 链接中已加入 pqv 参数"
    fi
}
p_t_cert() {
    local meta
    pick_cert 2 "$(meta_get '.nodes[$t].sni // ""' --arg t "$1")" "$1" || return 1
    meta=$(tls_meta "$(meta_get '.nodes[$t] // {} | del(.pcs)' -c --arg t "$1")")
    meta_set '.nodes[$t] = $m' --arg t "$1" --argjson m "$meta"
    node_update "$1" '.streamSettings.tlsSettings.certificates = [{certificateFile: $c, keyFile: $k}]' --arg c "$CERT_FILE" --arg k "$KEY_FILE" && ok "证书已更换"
}
p_x_path() {
    local p
    p=$(pick_path "XHTTP 路径" "$(ibget "$1" '.streamSettings.xhttpSettings.path // "/"')") || exit 1
    node_update "$1" '.streamSettings.xhttpSettings.path = $p' --arg p "$p" && ok "已更新"
}
p_x_mode() {
    local -a m=(auto packet-up stream-up stream-one)
    local i
    for i in "${!m[@]}"; do say "  ${cyan}$((i + 1)).${none} ${m[i]}"; done
    i=$(ask_choice "服务端接受的模式 (auto = 全部接受)" 1 1 4) || exit 1
    node_update "$1" '.streamSettings.xhttpSettings.mode = $m' --arg m "${m[i - 1]}" && ok "已更新"
}
p_x_host() {
    local h
    h=$(ask "服务端校验的 host (输入 - 清除)" "$(ibget "$1" '.streamSettings.xhttpSettings.host // ""')") || exit 1
    [[ $h == - ]] && h=""
    node_update "$1" 'if $h == "" then .streamSettings.xhttpSettings |= del(.host) else .streamSettings.xhttpSettings.host = $h end' --arg h "$h" && ok "已更新"
}
p_w_path() {
    local p key
    key=$(ibget "$1" 'if .streamSettings.wsSettings then "wsSettings" else "httpupgradeSettings" end')
    p=$(pick_path "路径" "$(ibget "$1" ".streamSettings.$key.path // \"/\"")") || exit 1
    node_update "$1" ".streamSettings.$key.path = \$p" --arg p "$p" && ok "已更新"
}
p_w_host() {
    local h key
    key=$(ibget "$1" 'if .streamSettings.wsSettings then "wsSettings" else "httpupgradeSettings" end')
    h=$(ask "服务端校验的 host (输入 - 清除)" "$(ibget "$1" ".streamSettings.$key.host // \"\"")") || exit 1
    [[ $h == - ]] && h=""
    node_update "$1" "if \$h == \"\" then .streamSettings.$key |= del(.host) else .streamSettings.$key.host = \$h end" --arg h "$h" && ok "已更新"
}
p_v_enc() {
    local dec net sec
    dec=$(ibget "$1" '.settings.decryption // "none"')
    net=$(cfg_getL '.inbounds[] | select(.tag == $t) | netname' --arg t "$1")
    sec=$(ibget "$1" '.streamSettings.security // "none"')
    if [[ $dec != none ]]; then
        say " ${cyan}1.${none} 重新生成   ${cyan}2.${none} 关闭   ${cyan}0.${none} 返回"
        case $(ask_choice "请选择" 0 0 2) in
            1) ;;
            2)
                if [[ $sec == none ]]; then
                    err "该节点没有 TLS/REALITY, 不能关闭 Encryption (否则流量明文传输)"
                    return 1
                fi
                meta_set 'del(.nodes[$t].enc)' --arg t "$1"
                if [[ $net == raw ]]; then
                    node_update "$1" '.settings.decryption = "none"'
                else # XHTTP 等传输只有在开启 Encryption 时才能使用 Vision 流控
                    node_update "$1" '.settings.decryption = "none" | .settings.clients |= map(del(.flow))'
                fi && ok "已关闭 VLESS Encryption"
                return
                ;;
            *) return 0 ;;
        esac
    fi
    pick_vlessenc || return 1
    meta_set '.nodes[$t].enc = $e' --arg t "$1" --arg e "$ENC_ENC"
    node_update "$1" '.settings.decryption = $d | .settings.clients |= map(.flow = "xtls-rprx-vision")' --arg d "$ENC_DEC" &&
        ok "VLESS Encryption 已启用 (Vision 流控已同步开启), 请重新导入分享链接"
}
p_s_method() {
    local m p
    m=$(pick_ss_method 1) || exit 1
    p=$(pick_ss_password "$m") || exit 1
    node_update "$1" '.settings.method = $m | .settings.password = $p' --arg m "$m" --arg p "$p" && ok "已更新, 请重新导入分享链接"
}
p_h_obfs() {
    local cur p
    cur=$(ibget "$1" '[.streamSettings.finalmask.udp[]? | select(.type == "salamander") | .settings.password][0] // empty')
    if [[ -n $cur ]]; then
        say " 当前混淆密码: $cur"
        say " ${cyan}1.${none} 修改混淆密码   ${cyan}2.${none} 关闭混淆   ${cyan}0.${none} 返回"
        case $(ask_choice "请选择" 0 0 2) in
            1) ;;
            2)
                node_update "$1" '.streamSettings |= (.finalmask.udp |= map(select(.type != "salamander")) | if (.finalmask.udp | length) == 0 then del(.finalmask.udp) else . end | if .finalmask == {} then del(.finalmask) else . end)' &&
                    ok "已关闭混淆"
                return
                ;;
            *) return 0 ;;
        esac
    fi
    p=$(pick_password "$(rand_str 16)" "混淆密码") || exit 1
    node_update "$1" '.streamSettings.finalmask.udp = ([(.streamSettings.finalmask.udp // [])[] | select(.type != "salamander")] + [{type: "salamander", settings: {password: $p}}])' --arg p "$p" &&
        ok "已设置混淆, 请重新导入分享链接"
}
p_h_masq() {
    local u
    u=$(ask "伪装网站 URL (如 https://www.bing.com; 输入 - 关闭, 返回 404)" "$(ibget "$1" '.streamSettings.hysteriaSettings.masquerade.url // ""')") || exit 1
    [[ $u == - ]] && u=""
    node_update "$1" 'if $u == "" then .streamSettings.hysteriaSettings |= del(.masquerade) else .streamSettings.hysteriaSettings.masquerade = {type: "proxy", url: $u, rewriteHost: true} end' --arg u "$u" && ok "已更新"
}
p_k_auth() {
    local u p
    if ask_yn "启用用户名密码认证?" y; then
        u=$(pick_password "$(ibget "$1" '.settings.accounts[0].user // empty')" "用户名") || exit 1
        p=$(pick_password "$(rand_str 16)" "密码") || exit 1
        node_update "$1" '.settings.auth = "password" | .settings.accounts = [{user: $u, pass: $p}]' --arg u "$u" --arg p "$p" && ok "已更新"
    else
        node_update "$1" '.settings.auth = "noauth" | del(.settings.accounts)' && warn "已关闭认证"
    fi
}
p_k_udp() {
    local cur port
    cur=$(ibget "$1" '.settings.udp // false')
    port=$(ibget "$1" '.port')
    if [[ $cur == true ]]; then
        node_update "$1" '.settings.udp = false' && ok "已关闭 UDP"
    else
        [[ -n $(port_owner "$port" udp "$1") ]] && {
            err "端口 $port 的 UDP 已被其他节点使用"
            return 1
        }
        node_update "$1" '.settings.udp = true' && fw_apply open "$port" udp && ok "已开启 UDP"
    fi
}
p_f_target() {
    local a p n
    a=$(ask_required "转发目标地址" "$(ibget "$1" '.settings.address // .settings.rewriteAddress // ""')") || exit 1
    p=$(ask_required "转发目标端口" "$(ibget "$1" '(.settings.port // .settings.rewritePort // "") | tostring')") || exit 1
    is_port "$p" || {
        err "端口无效"
        return 1
    }
    say "转发协议:  ${cyan}1.${none} TCP+UDP   ${cyan}2.${none} 仅 TCP   ${cyan}3.${none} 仅 UDP"
    case $(ask_choice "请选择" 1 1 3) in
        1) n="tcp,udp" ;;
        2) n=tcp ;;
        3) n=udp ;;
    esac
    node_update "$1" '.settings |= (del(.rewriteAddress, .rewritePort, .allowedNetwork) | .address = $a | .port = ($p | tonumber) | .network = $n)' \
        --arg a "$a" --arg p "$((10#$p))" --arg n "$n" && ok "已更新"
}
p_sniff() {
    if [[ $(ibget "$1" '.sniffing.enabled // false') == true ]]; then
        node_update "$1" '.sniffing.enabled = false' && warn "已关闭嗅探: 该节点的域名分流 / BT 屏蔽将不再生效"
    else
        node_update "$1" '.sniffing = {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: false}' && ok "已开启嗅探"
    fi
}

# ---- 分享链接参数 (仅影响客户端链接) ------------------------------------
node_link_params() {
    local tag=$1 c v addr lport fp sni host gaddr
    local -a fps=(chrome firefox safari ios android edge 360 qq random randomized)
    while :; do
        addr=$(meta_get '.nodes[$t].addr // ""' --arg t "$tag")
        lport=$(meta_get '.nodes[$t].lport // ""' --arg t "$tag")
        fp=$(meta_get '.nodes[$t].fp // ""' --arg t "$tag")
        sni=$(meta_get '.nodes[$t].sni // ""' --arg t "$tag")
        host=$(meta_get '.nodes[$t].host // ""' --arg t "$tag")
        gaddr=$(meta_get '.settings.address // "自动检测"')
        title "分享链接参数 [$tag]  (只影响生成的链接, 不改服务端)"
        say " ${cyan}1.${none} 连接地址 (IP / 域名 / CDN 优选 IP)   [${addr:-跟随全局: $gaddr}]"
        say " ${cyan}2.${none} 外部端口 (NAT 端口映射 / 反代端口)   [${lport:-同监听端口}]"
        say " ${cyan}3.${none} TLS 指纹 (fp)                      [${fp:-chrome}]"
        say " ${cyan}4.${none} SNI                                [${sni:-自动}]"
        say " ${cyan}5.${none} Host (WS / XHTTP)                  [${host:-自动}]"
        say " ${cyan}0.${none} 返回"
        c=$(ask_choice "请选择" 0 0 5) || exit 1
        case $c in
            0) return 0 ;;
            1)
                v=$(ask "连接地址 (输入 - 恢复跟随全局)" "$addr") || exit 1
                [[ $v == - ]] && v=""
                [[ -z $v ]] || is_ip "${v#[}" || is_ip "${v%]}" || is_domain "$v" || is_ip "$v" || {
                    error
                    continue
                }
                meta_set '.nodes[$t].addr = $v' --arg t "$tag" --arg v "$v"
                ;;
            2)
                v=$(ask "外部端口 (0 = 同监听端口)" "${lport:-0}") || exit 1
                [[ $v == 0 || $v == - ]] && v=""
                [[ -z $v ]] || is_port "$v" || {
                    error
                    continue
                }
                meta_set '.nodes[$t].lport = $v' --arg t "$tag" --arg v "$v"
                ;;
            3)
                local i
                say "  ${gray}服务端为 Xray 26.9+ 时请用 chrome, 其他指纹可能不带 X25519MLKEM768 而被 REALITY 拒绝${none}"
                for i in "${!fps[@]}"; do say "  ${cyan}$((i + 1)).${none} ${fps[i]}"; done
                i=$(ask_choice "选择指纹" 1 1 "${#fps[@]}") || exit 1
                meta_set '.nodes[$t].fp = $v' --arg t "$tag" --arg v "${fps[i - 1]}"
                ;;
            4)
                v=$(ask "SNI (输入 - 恢复自动)" "$sni") || exit 1
                [[ $v == - ]] && v=""
                if [[ -n $v && $(ibget "$tag" '.streamSettings.security // ""') == reality &&
                    -z $(cfg_get '.inbounds[] | select(.tag == $t) | .streamSettings.realitySettings.serverNames[]? | select(. == $v)' --arg t "$tag" --arg v "$v") ]]; then
                    err "REALITY 节点的 SNI 必须是服务端 serverNames 之一 ($(ibget "$tag" '.streamSettings.realitySettings.serverNames | join(",")')), 否则会验证失败"
                    say " 要更换目标网站请用: 协议参数 → REALITY 目标网站"
                    continue
                fi
                meta_set '.nodes[$t].sni = $v' --arg t "$tag" --arg v "$v"
                ;;
            5)
                v=$(ask "Host (输入 - 恢复自动)" "$host") || exit 1
                [[ $v == - ]] && v=""
                meta_set '.nodes[$t].host = $v' --arg t "$tag" --arg v "$v"
                ;;
        esac
        links_refresh
        ok "已更新"
    done
}

# ---------------------------------------------------------------------
# 落地 / 出站
# ---------------------------------------------------------------------
reset_p() {
    P_PROTO="" P_ADDR="" P_PORT="" P_ID="" P_PASS="" P_USER="" P_METHOD="" P_FLOW="" P_ENC="" P_SCY=""
    P_NET=raw P_SEC=none P_SNI="" P_FP="" P_ALPN="" P_PBK="" P_SID="" P_SPX="" P_PQV="" P_PCS="" P_VCN=""
    P_PATH="" P_HOST="" P_MODE="" P_SVC="" P_EXTRA="" P_HTYPE="" P_OBFS="" P_OBFSPW="" P_HOP="" P_INSECURE=0 P_NAME="" P_ERR=""
}
reset_p
split_hostport() { # host:port / [v6]:port
    local hp=${1%/}
    if [[ $hp == \[* ]]; then
        P_ADDR=${hp%%\]*}
        P_ADDR=${P_ADDR#\[}
        if [[ $hp == *\]:* ]]; then P_PORT=${hp##*\]:}; else P_PORT=""; fi
    elif [[ $hp == *:* ]]; then
        P_ADDR=${hp%:*} P_PORT=${hp##*:}
    else
        P_ADDR=$hp P_PORT=""
    fi
}
parse_query() {
    local kv k v
    local -a parts=()
    Q=()
    IFS='&' read -r -a parts <<<"$1"
    for kv in "${parts[@]}"; do
        [[ -n $kv ]] || continue
        k=${kv%%=*} v=""
        [[ $kv == *=* ]] && v=${kv#*=}
        k=$(urldec "$k")
        Q[${k,,}]=$(urldec "$v")
    done
}
q_stream() { # 从 Q[] 解析传输层参数
    local t=${Q[type]:-tcp}
    case ${t,,} in
        tcp | raw) P_NET=raw ;;
        ws | websocket) P_NET=ws ;;
        grpc | gun) P_NET=grpc ;;
        xhttp | splithttp) P_NET=xhttp ;;
        httpupgrade) P_NET=httpupgrade ;;
        h2 | http | quic)
            P_ERR="传输方式 $t 已被新版 Xray 移除"
            return 1
            ;;
        *)
            P_ERR="不支持的传输方式: $t"
            return 1
            ;;
    esac
    P_SEC=${Q[security]:-none}
    P_SEC=${P_SEC,,}
    [[ $P_SEC == xtls ]] && {
        P_ERR="旧版 XTLS 已被移除"
        return 1
    }
    [[ $P_SEC == "" ]] && P_SEC=none
    P_SNI=${Q[sni]:-${Q[peer]:-}} P_FP=${Q[fp]:-} P_ALPN=${Q[alpn]:-}
    P_PBK=${Q[pbk]:-} P_SID=${Q[sid]:-} P_SPX=${Q[spx]:-} P_PQV=${Q[pqv]:-}
    P_PCS=${Q[pcs]:-} P_VCN=${Q[vcn]:-}
    P_PATH=${Q[path]:-} P_HOST=${Q[host]:-} P_MODE=${Q[mode]:-} P_SVC=${Q[servicename]:-} P_EXTRA=${Q[extra]:-}
    P_HTYPE=${Q[headertype]:-}
    case ${Q[allowinsecure]:-${Q[insecure]:-0}} in 1 | true) P_INSECURE=1 ;; esac
    [[ $P_NET == grpc && -z $P_SVC ]] && P_SVC=$P_PATH
    return 0
}
parse_std() { # vless|trojan 其余部分
    local scheme=$1 rest=$2 before query="" ui hp
    before=$rest
    if [[ $rest == *\?* ]]; then
        before=${rest%%\?*}
        query=${rest#*\?}
    fi
    [[ $before == *@* ]] || {
        P_ERR="链接格式错误 (缺少 @)"
        return 1
    }
    ui=${before%@*} hp=${before##*@}
    split_hostport "$hp"
    parse_query "$query"
    if [[ $scheme == vless ]]; then
        P_PROTO=vless P_ID=$(urldec "$ui") P_ENC=${Q[encryption]:-none} P_FLOW=${Q[flow]:-}
    else
        P_PROTO=trojan P_PASS=$(urldec "$ui")
    fi
    q_stream
}
parse_vmess() {
    local js row add port id scy aid net typ host path tls sni alpn fp ps
    js=$(b64dec "$1")
    if [[ -z $js ]] || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$js"; then
        P_ERR="vmess 链接解析失败"
        return 1
    fi
    row=$(jq -r '[.add, .port, .id, .scy, .aid, .net, .type, .host, .path, .tls, .sni, .alpn, .fp, .ps]
        | map(if . == null then "" else tostring end) | join("\u001f")' <<<"$js")
    IFS=$'\x1f' read -r add port id scy aid net typ host path tls sni alpn fp ps <<<"$row"
    if [[ -n $aid && $aid != 0 ]]; then
        P_ERR="不支持 alterId 不为 0 的旧版 VMess"
        return 1
    fi
    P_PROTO=vmess P_ADDR=$add P_PORT=$port P_ID=$id P_SCY=${scy:-auto}
    [[ -z $P_NAME ]] && P_NAME=$ps
    Q=()
    Q[type]=${net:-tcp} Q[sni]=$sni Q[alpn]=$alpn Q[fp]=$fp Q[host]=$host Q[path]=$path
    if [[ $tls == tls ]]; then Q[security]=tls; else Q[security]=none; fi
    case ${net:-tcp} in
        grpc) Q[servicename]=$path Q[mode]=$typ ;;
        tcp | raw) Q[headertype]=$typ ;;
        xhttp | splithttp) [[ -n $typ && $typ != none ]] && Q[mode]=$typ ;;
    esac
    q_stream
}
parse_ss() {
    local rest=$1 query="" ui hp dec
    if [[ $rest == *\?* ]]; then
        query=${rest#*\?}
        rest=${rest%%\?*}
    fi
    rest=${rest%/}
    if [[ $rest == *@* ]]; then
        ui=${rest%@*} hp=${rest##*@}
        if [[ $ui == *:* ]]; then dec=$(urldec "$ui"); else dec=$(b64dec "$ui"); fi
    else # 旧格式: ss://BASE64(method:pass@host:port)
        dec=$(b64dec "$rest")
        [[ $dec == *@* ]] || {
            P_ERR="ss 链接解析失败"
            return 1
        }
        hp=${dec##*@} dec=${dec%@*}
    fi
    [[ $dec == *:* ]] || {
        P_ERR="ss 链接解析失败"
        return 1
    }
    P_PROTO=shadowsocks P_METHOD=${dec%%:*} P_PASS=${dec#*:}
    split_hostport "$hp"
    parse_query "$query"
    [[ -n ${Q[plugin]:-} ]] && {
        P_ERR="Xray 不支持 SS 插件 (plugin=${Q[plugin]})"
        return 1
    }
    return 0
}
parse_socks_http() { # scheme 其余部分
    local scheme=$1 rest=${2%%\?*} ui="" hp dec
    rest=${rest%/}
    if [[ $rest == *@* ]]; then ui=${rest%@*} hp=${rest##*@}; else hp=$rest; fi
    if [[ -n $ui ]]; then
        if [[ $ui == *:* ]]; then
            dec=$(urldec "$ui")
        else
            dec=$(b64dec "$ui")
            [[ $dec == *:* ]] || dec=$(urldec "$ui")
        fi
        P_USER=${dec%%:*}
        if [[ $dec == *:* ]]; then P_PASS=${dec#*:}; else P_PASS=""; fi
    fi
    split_hostport "$hp"
    case $scheme in
        socks*) P_PROTO=socks ;;
        http) P_PROTO=http ;;
        https) P_PROTO=http P_SEC=tls P_SNI=$P_ADDR ;;
    esac
    return 0
}
parse_hy2() {
    local rest=$1 query="" ui="" hp
    if [[ $rest == *\?* ]]; then
        query=${rest#*\?}
        rest=${rest%%\?*}
    fi
    rest=${rest%/}
    if [[ $rest == *@* ]]; then ui=${rest%@*} hp=${rest##*@}; else hp=$rest; fi
    P_PASS=$(urldec "$ui")
    split_hostport "$hp"
    parse_query "$query"
    if [[ -n $P_PORT && ! $P_PORT =~ ^[0-9]+$ ]]; then # 端口跳跃: 443,20000-30000
        P_HOP=$P_PORT
        P_PORT=$(grep -oE '[0-9]+' <<<"$P_PORT" | head -n 1)
    fi
    [[ -n ${Q[mport]:-} ]] && P_HOP=${Q[mport]}
    P_PROTO=hysteria P_SEC=tls P_NET=hysteria
    P_SNI=${Q[sni]:-} P_ALPN=${Q[alpn]:-}
    P_OBFS=${Q[obfs]:-} P_OBFSPW=${Q[obfs-password]:-}
    P_PCS=${Q[pinsha256]:-${Q[pcs]:-}}
    P_PCS=${P_PCS//:/}
    P_PCS=${P_PCS,,}
    case ${Q[insecure]:-0} in 1 | true) P_INSECURE=1 ;; esac
    return 0
}
parse_link() { # 分享链接 → P_* 变量
    local link=${1//[[:space:]]/} scheme rest
    reset_p
    [[ $link == *://* ]] || {
        P_ERR="不是有效的分享链接"
        return 1
    }
    scheme=${link%%://*}
    scheme=${scheme,,}
    rest=${link#*://}
    if [[ $rest == *'#'* ]]; then
        P_NAME=$(urldec "${rest#*#}")
        rest=${rest%%#*}
    fi
    case $scheme in
        vmess) parse_vmess "$rest" ;;
        vless | trojan) parse_std "$scheme" "$rest" ;;
        ss) parse_ss "$rest" ;;
        socks | socks5 | socks5h | http | https) parse_socks_http "$scheme" "$rest" ;;
        hysteria2 | hy2) parse_hy2 "$rest" ;;
        *)
            P_ERR="不支持的链接类型: $scheme"
            false
            ;;
    esac || return 1
    [[ -n $P_ADDR ]] || {
        P_ERR="链接中缺少服务器地址"
        return 1
    }
    is_port "$P_PORT" || {
        P_ERR="链接中的端口无效: ${P_PORT:-空}"
        return 1
    }
    P_PORT=$((10#$P_PORT))
    return 0
}
fetch_cert_sha256() { # 主机 端口 SNI
    command -v openssl >/dev/null 2>&1 || ensure_cmds openssl >/dev/null 2>&1 || return 1
    timeout 10 openssl s_client -connect "$(fmt_host "$1"):$2" -servername "$3" </dev/null 2>/dev/null |
        openssl x509 -noout -fingerprint -sha256 2>/dev/null | awk -F= '{ gsub(":", "", $2); print tolower($2) }'
}
fix_insecure() { # 链接要求跳过证书验证时, 改用证书指纹 (新版 Xray 已移除 allowInsecure)
    [[ $P_SEC == tls && $P_INSECURE == 1 && -z $P_PCS ]] || return 0
    warn "该链接要求跳过证书验证 (allowInsecure/insecure), 新版 Xray 已移除该选项, 需改用证书指纹 (pinnedPeerCertSha256)"
    if [[ $P_PROTO != hysteria ]]; then
        info "尝试自动获取对端证书指纹 ..."
        P_PCS=$(fetch_cert_sha256 "$P_ADDR" "$P_PORT" "${P_SNI:-$P_ADDR}")
        if [[ -n $P_PCS ]]; then
            say " 证书 SHA256: $P_PCS"
            ask_yn "确认使用该指纹?" y || P_PCS=""
        fi
    fi
    [[ -z $P_PCS ]] && P_PCS=$(ask "请输入对端证书 SHA256 指纹 (在落地机执行: xray tls hash --cert 证书路径), 留空取消" "")
    P_PCS=${P_PCS//:/}
    P_PCS=${P_PCS,,}
    [[ -n $P_PCS ]] || {
        P_ERR="缺少证书指纹, 已取消"
        return 1
    }
}

read -r -d '' JQ_BUILD_OUT <<'JQEOF'
def nz: . != null and . != "";
def csv: split(",") | map(gsub(" "; "")) | map(select(. != ""));
def tls_obj:
  ({} + (if $sni | nz then {serverName: $sni} else {} end)
      + (if $fp | nz then {fingerprint: $fp} else {} end)
      + (if $alpn | nz then {alpn: ($alpn | csv)} else {} end)
      + (if $pcs | nz then {pinnedPeerCertSha256: $pcs} else {} end)
      + (if $vcn | nz then {verifyPeerCertByName: $vcn} else {} end));
def reality_obj:
  ({serverName: $sni, fingerprint: (if $fp | nz then $fp else "chrome" end), password: $pbk}
      + (if $sid | nz then {shortId: $sid} else {} end)
      + (if $spx | nz then {spiderX: $spx} else {} end)
      + (if $pqv | nz then {mldsa65Verify: $pqv} else {} end));
def hostobj: if $host | nz then {host: $host} else {} end;
def pathv: if $path | nz then $path else "/" end;
def stream:
  {network: $net}
  + (if $sec == "tls" then {security: "tls", tlsSettings: tls_obj}
     elif $sec == "reality" then {security: "reality", realitySettings: reality_obj}
     else {} end)
  + (if $net == "ws" then {wsSettings: ({path: pathv} + hostobj)}
     elif $net == "httpupgrade" then {httpupgradeSettings: ({path: pathv} + hostobj)}
     elif $net == "xhttp" then
       {xhttpSettings: ({path: pathv, mode: (if $mode | nz then $mode else "auto" end)} + hostobj
         + (if $extra | nz then {extra: (try ($extra | fromjson) catch {})} else {} end))}
     elif $net == "grpc" then
       {grpcSettings: ({serviceName: $svc} + (if $mode == "multi" then {multiMode: true} else {} end)
         + (if $host | nz then {authority: $host} else {} end))}
     elif $net == "raw" and $htype == "http" then
       {rawSettings: {header: {type: "http", request: {path: [pathv], headers: (if $host | nz then {Host: ($host | csv)} else {} end)}}}}
     else {} end);
def portn: ($port | tonumber);
{tag: $tag}
+ (if $proto == "vless" then
     {protocol: "vless", settings: {vnext: [{address: $addr, port: portn,
        users: [({id: $id, encryption: (if $enc | nz then $enc else "none" end)} + (if $flow | nz then {flow: $flow} else {} end))]}]},
      streamSettings: stream}
   elif $proto == "vmess" then
     {protocol: "vmess", settings: {vnext: [{address: $addr, port: portn, users: [{id: $id, security: (if $scy | nz then $scy else "auto" end)}]}]},
      streamSettings: stream}
   elif $proto == "trojan" then
     {protocol: "trojan", settings: {servers: [{address: $addr, port: portn, password: $pass}]}, streamSettings: stream}
   elif $proto == "shadowsocks" then
     {protocol: "shadowsocks", settings: {servers: [{address: $addr, port: portn, method: $method, password: $pass}]}}
   elif $proto == "socks" or $proto == "http" then
     {protocol: $proto, settings: {servers: [{address: $addr, port: portn} + (if $user | nz then {users: [{user: $user, pass: $pass}]} else {} end)]}}
     + (if $sec == "tls" then {streamSettings: {security: "tls", tlsSettings: tls_obj}} else {} end)
   elif $proto == "hysteria" then
     {protocol: "hysteria", settings: {version: 2, address: $addr, port: portn},
      streamSettings: ({network: "hysteria", security: "tls",
          tlsSettings: (tls_obj + {serverName: (if $sni | nz then $sni else $addr end), alpn: (if $alpn | nz then ($alpn | csv) else ["h3"] end)}),
          hysteriaSettings: {version: 2, auth: $pass}}
        + (if ($obfs == "salamander") or ($hop | nz) then
             {finalmask: ({}
               + (if $obfs == "salamander" then {udp: [{type: "salamander", settings: {password: $obfspw}}]} else {} end)
               + (if $hop | nz then {quicParams: {udpHop: {ports: $hop, interval: "30"}}} else {} end))}
           else {} end))}
   else error("unsupported protocol: " + $proto) end)
JQEOF

build_outbound() { # 名称  (读取 P_* 变量)
    jq -nc --arg tag "$1" --arg proto "$P_PROTO" --arg addr "$P_ADDR" --arg port "$P_PORT" \
        --arg id "$P_ID" --arg pass "$P_PASS" --arg user "$P_USER" --arg method "$P_METHOD" \
        --arg flow "$P_FLOW" --arg enc "$P_ENC" --arg scy "$P_SCY" \
        --arg net "$P_NET" --arg sec "$P_SEC" --arg sni "$P_SNI" --arg fp "$P_FP" --arg alpn "$P_ALPN" \
        --arg pbk "$P_PBK" --arg sid "$P_SID" --arg spx "$P_SPX" --arg pqv "$P_PQV" --arg pcs "$P_PCS" --arg vcn "$P_VCN" \
        --arg path "$P_PATH" --arg host "$P_HOST" --arg mode "$P_MODE" --arg svc "$P_SVC" --arg extra "$P_EXTRA" \
        --arg htype "$P_HTYPE" --arg obfs "$P_OBFS" --arg obfspw "$P_OBFSPW" --arg hop "$P_HOP" "$JQ_BUILD_OUT"
}
outbound_selftest() { # 出站 json
    local f
    f=$(tmpf)
    jq -n --argjson o "$1" '{log: {loglevel: "none"}, outbounds: [$o, {tag: "direct", protocol: "freedom"}]}' >"$f" || return 1
    xray_test "$f" && return 0
    err "该出站配置未通过 Xray 校验"
    return 1
}
manual_socks_http() { # socks|http
    reset_p
    P_PROTO=$1
    P_ADDR=$(ask_required "服务器地址 (IP 或域名)") || exit 1
    P_PORT=$(ask_required "端口") || exit 1
    is_port "$P_PORT" || {
        err "端口无效"
        return 1
    }
    P_USER=$(ask "用户名 (无认证请留空)" "") || exit 1
    [[ -n $P_USER ]] && P_PASS=$(ask "密码" "")
    if [[ $1 == http ]] && ask_yn "该代理使用 HTTPS (TLS)?" n; then
        P_SEC=tls
        P_SNI=$(ask "SNI" "$P_ADDR") || exit 1
    fi
    return 0
}
manual_ss() {
    reset_p
    P_PROTO=shadowsocks
    P_ADDR=$(ask_required "服务器地址 (IP 或域名)") || exit 1
    P_PORT=$(ask_required "端口") || exit 1
    is_port "$P_PORT" || {
        err "端口无效"
        return 1
    }
    P_METHOD=$(pick_ss_method 1) || exit 1
    P_PASS=$(ask_required "密码") || exit 1
}
manual_wireguard() { # → stdout 出站 json
    local sk addr pk ep res mtu
    sk=$(ask_required "本机私钥 (PrivateKey / secretKey)") || exit 1
    addr=$(ask_required "本机地址, 逗号分隔 (如 172.16.0.2/32,fd01::2/128)") || exit 1
    pk=$(ask_required "对端公钥 (PublicKey)") || exit 1
    ep=$(ask_required "对端 Endpoint (host:port)") || exit 1
    res=$(ask "reserved (如 12,34,56, 没有请留空)" "") || exit 1
    mtu=$(ask "MTU" 1280) || exit 1
    [[ $mtu =~ ^[0-9]+$ ]] || mtu=1280
    jq -nc --arg sk "$sk" --arg addr "$addr" --arg pk "$pk" --arg ep "$ep" --arg res "$res" --argjson mtu "$mtu" '
        {protocol: "wireguard", settings: ({secretKey: $sk, address: ($addr | split(",") | map(gsub(" "; ""))),
          peers: [{publicKey: $pk, endpoint: $ep, allowedIPs: ["0.0.0.0/0", "::/0"]}], mtu: $mtu, noKernelTun: true}
          + (if ($res | test("^[0-9]+,[0-9]+,[0-9]+$")) then {reserved: ($res | split(",") | map(tonumber))} else {} end))}'
}
warp_register() { # → stdout 出站 json
    local out priv pub resp api v4 v6 peer cid res ep
    out=$("$XRAY_BIN" wg 2>/dev/null)
    priv=$(awk -F': ' '/^Private/ { print $2; exit }' <<<"$out")
    pub=$(awk -F': ' '/^(Public|Password)/ { print $2; exit }' <<<"$out")
    [[ -n $priv && -n $pub ]] || {
        err "生成 WireGuard 密钥失败"
        return 1
    }
    info "正在向 Cloudflare 注册 WARP 账户 ..."
    for api in v0a2158 v0a1922; do
        resp=$(curl -fsS -m 15 -X POST "https://api.cloudflareclient.com/$api/reg" \
            -H 'User-Agent: okhttp/3.12.1' -H 'CF-Client-Version: a-6.10-2158' -H 'Content-Type: application/json' \
            -d "{\"key\":\"$pub\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"model\":\"PC\",\"serial_number\":\"\",\"locale\":\"en_US\"}" 2>/dev/null)
        jq -e '.config.peers[0].public_key' >/dev/null 2>&1 <<<"$resp" && break
        resp=""
    done
    [[ -n $resp ]] || {
        err "WARP 注册失败 (本机 IP 可能被 Cloudflare 限制), 可改用\"WireGuard 手动填写\""
        return 1
    }
    v4=$(jq -r '.config.interface.addresses.v4 // empty' <<<"$resp")
    v6=$(jq -r '.config.interface.addresses.v6 // empty' <<<"$resp")
    peer=$(jq -r '.config.peers[0].public_key' <<<"$resp")
    cid=$(jq -r '.config.client_id // empty' <<<"$resp")
    res=$(b64dec "$cid" | od -An -tu1 | awk '{ printf "%s,%s,%s", $1, $2, $3; exit }')
    if [[ -n $(get_ip 4) ]]; then ep="engage.cloudflareclient.com:2408"; else ep="[2606:4700:d0::a29f:c001]:2408"; fi
    ok "WARP 账户注册成功"
    jq -nc --arg sk "$priv" --arg v4 "$v4" --arg v6 "$v6" --arg pk "$peer" --arg ep "$ep" --arg res "$res" '
        {protocol: "wireguard", settings: ({secretKey: $sk,
          address: ([$v4, $v6] | map(select(. != "")) | map(if test(":") then . + "/128" else . + "/32" end)),
          peers: [{publicKey: $pk, endpoint: $ep, allowedIPs: ["0.0.0.0/0", "::/0"]}], mtu: 1280, noKernelTun: true}
          + (if ($res | test("^[0-9]+,[0-9]+,[0-9]+$")) then {reserved: ($res | split(",") | map(tonumber))} else {} end))}'
}
landing_add_flow() { # 在工作副本中新增落地 → LANDING_NEW_TAG (由调用者提交)
    local c json="" name link
    title "添加落地 / 出站"
    say " ${cyan}1.${none} 粘贴分享链接 (vless / vmess / trojan / ss / socks / http / hysteria2)"
    say " ${cyan}2.${none} SOCKS5 代理"
    say " ${cyan}3.${none} HTTP / HTTPS 代理"
    say " ${cyan}4.${none} Shadowsocks"
    say " ${cyan}5.${none} WireGuard (手动填写)"
    say " ${cyan}6.${none} Cloudflare WARP (自动注册, 常用于解锁流媒体 / AI 或 IPv6 出站)"
    say " ${cyan}0.${none} 取消"
    c=$(ask_choice "请选择" 1 0 6) || exit 1
    ((c == 0)) && return 1
    reset_p
    case $c in
        1)
            link=$(ask_required "分享链接") || exit 1
            if ! parse_link "$link"; then
                err "${P_ERR:-链接解析失败}"
                return 1
            fi
            fix_insecure || {
                err "$P_ERR"
                return 1
            }
            [[ -n $P_NAME ]] && say " 链接备注: $P_NAME"
            ;;
        2) manual_socks_http socks || return 1 ;;
        3) manual_socks_http http || return 1 ;;
        4) manual_ss || return 1 ;;
        5) json=$(manual_wireguard) || return 1 ;;
        6) json=$(warp_register) || return 1 ;;
    esac
    name=$(pick_tag "$(cfg_getL 'uniqname($b; alltags)' --arg b "$([[ $c == 6 ]] && echo warp || echo landing)")" "落地名称 (标签)")
    if [[ -z $json ]]; then
        json=$(build_outbound "$name") || {
            err "生成出站配置失败"
            return 1
        }
    else
        json=$(jq -c --arg t "$name" '{tag: $t} + .' <<<"$json")
    fi
    outbound_selftest "$json" || return 1
    cfg_jq '.outbounds += [$o]' --argjson o "$json" || return 1
    meta_set '.landings[$t] = {remark: $r}' --arg t "$name" --arg r "$P_NAME"
    LANDING_NEW_TAG=$name
    ok "落地 [$name] 已加入: $(jq -r "$JQ_LIB odesc" <<<"$json")"
    return 0
}
landing_list() { # 打印落地列表并填充 LANDING_TAGS
    local rows row i=0 tag desc used
    LANDING_TAGS=()
    mapfile -t rows < <(cfg_getL '. as $r | .outbounds[] | select(.tag != null and (.tag | is_builtin | not)) | .tag as $t
        | [$t, odesc, ([($r | .routing.rules[]?) | select(.outboundTag == $t) | (.ruleTag // "手动规则")
             | if startswith("xs-node-") then "节点 " + ltrimstr("xs-node-")
               elif startswith("xs-user-") then "用户 " + ltrimstr("xs-user-")
               elif . == "xs-default" then "全局默认"
               elif startswith("xs-custom") then "分流规则"
               else . end] | unique | join(", "))] | join("\u001f")')
    if ((${#rows[@]} == 0)); then
        say " ${gray}(还没有落地; 未设置落地时所有流量从本机直连出去)${none}"
        return 1
    fi
    for row in "${rows[@]}"; do
        IFS=$'\x1f' read -r tag desc used <<<"$row"
        i=$((i + 1))
        LANDING_TAGS+=("$tag")
        say " ${cyan}$i.${none} ${bold}$tag${none}  $desc  ${gray}${used:+使用者: $used}${none}"
    done
}
landing_menu() {
    local c
    while :; do
        cfg_load || return 1
        title "落地 / 出站管理"
        say " 全局默认出口: ${magenta}$(out_name "$(cfg_getL default_out)")${none}"
        landing_list
        hr
        say " ${cyan}1.${none} 添加落地            ${cyan}2.${none} 删除落地            ${cyan}3.${none} 测试落地出口 IP"
        say " ${cyan}4.${none} 为节点设置落地      ${cyan}5.${none} 为用户设置落地      ${cyan}6.${none} 设置全局默认出口"
        say " ${cyan}7.${none} 链式代理 (落地 A 经由落地 B 连接)"
        say " ${cyan}0.${none} 返回"
        c=$(ask_choice "请选择" 0 0 7) || exit 1
        case $c in
            0) return 0 ;;
            1) landing_add_flow && cfg_commit ;;
            2) landing_delete ;;
            3) landing_test_menu ;;
            4) pick_node "选择节点" && node_set_out "$PICKED_NODE" ;;
            5)
                if pick_node "选择节点"; then
                    list_users "$PICKED_NODE"
                    if ((${#USER_LIST[@]} == 0)); then warn "该节点没有可单独设置的用户"; else pick_user && user_set_out "$PICKED_USER"; fi
                fi
                ;;
            6) set_default_out ;;
            7) landing_chain ;;
        esac
    done
}
landing_delete() {
    local c tag refs
    landing_list || return 0
    c=$(ask_choice "选择要删除的落地 (0 取消)" 0 0 "${#LANDING_TAGS[@]}") || exit 1
    ((c == 0)) && return 0
    tag=${LANDING_TAGS[c - 1]}
    refs=$(cfg_get '[.routing.rules[]? | select(.outboundTag == $t)] | length' --arg t "$tag")
    ((${refs:-0} > 0)) && warn "有 ${refs} 条路由规则使用该落地, 删除后这些规则会一并移除 (相关节点/用户恢复为默认出口)"
    ask_yn "确定删除落地 [$tag]?" n || return 0
    cfg_jq '.outbounds |= map(select(.tag != $t))
        | .outbounds |= map(if .streamSettings.sockopt.dialerProxy == $t then del(.streamSettings.sockopt.dialerProxy) else . end)
        | .routing.rules |= map(select(.outboundTag != $t))' --arg t "$tag" || return 1
    cfg_commit || return 1
    meta_set 'del(.landings[$t])' --arg t "$tag"
    ok "落地 [$tag] 已删除"
}
landing_test_menu() {
    local c
    landing_list
    say " ${cyan}0.${none} 本机直连 (对比用)"
    c=$(ask_choice "选择要测试的出口" 0 0 "${#LANDING_TAGS[@]}") || exit 1
    if ((c == 0)); then landing_test direct; else landing_test "${LANDING_TAGS[c - 1]}"; fi
}
landing_test() { # 出站名   用临时 xray 实例测试, 不影响正在运行的服务
    local tag=$1 f port i res ip loc t
    port=$(free_port tcp)
    f=$(tmpf) && mv -f "$f" "$f.json" && f="$f.json"
    jq --arg t "$tag" --argjson p "$port" '{log: {loglevel: "warning"},
        inbounds: [{tag: "xs-test-in", listen: "127.0.0.1", port: $p, protocol: "socks", settings: {udp: false}}],
        outbounds: ([.outbounds[] | select(.tag == $t)] + [.outbounds[] | select(.tag != $t)]),
        routing: {rules: []}}' "$(cfg_src)" >"$f" || return 1
    info "正在通过 [$tag] 测试出口 (最长约 15 秒) ..."
    "$XRAY_BIN" run -config "$f" >"$f.log" 2>&1 &
    TEST_PID=$!
    for ((i = 0; i < 25; i++)); do
        port_in_use_sys "$port" tcp && break
        sleep 0.2
    done
    res=$(curl -s -m 12 -x "socks5h://127.0.0.1:$port" -w '\n%{time_total}' https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    kill "$TEST_PID" 2>/dev/null
    wait "$TEST_PID" 2>/dev/null
    TEST_PID=""
    ip=$(awk -F= '/^ip=/ { print $2 }' <<<"$res")
    loc=$(awk -F= '/^loc=/ { print $2 }' <<<"$res")
    t=$(tail -n 1 <<<"$res")
    if [[ -n $ip ]]; then
        ok "出口 IP: $ip   地区: ${loc:-?}   耗时: ${t}s"
    else
        err "测试失败, 该出口当前不可用"
        tail -n 5 "$f.log" >&2
    fi
}
set_default_out() {
    cfg_load || return 1
    say "当前全局默认出口: $(out_name "$(cfg_getL default_out)")  (没有单独设置出站的节点 / 用户都走这里)"
    pick_outbound "新的全局默认出口" 0 || return 1
    cfg_jqL '.routing.rules |= map(select(.ruleTag != "xs-default"))
        | (if $o == "direct" then . else .routing.rules += [{ruleTag: "xs-default", network: "tcp,udp", outboundTag: $o}] end)
        | sort_rules' --arg o "$PICKED_OUT" || return 1
    cfg_commit && ok "全局默认出口: $(out_name "$PICKED_OUT")"
}
landing_chain() {
    local c a b t cur n=0
    local -a opts=("")
    landing_list || return 0
    c=$(ask_choice "选择要设置前置出口的落地 (0 取消)" 0 0 "${#LANDING_TAGS[@]}") || exit 1
    ((c == 0)) && return 0
    a=${LANDING_TAGS[c - 1]}
    say "[$a] 的前置出口 (先连到前置出口, 再由它去连接 [$a]):"
    say "  ${cyan}1.${none} 无 (直接连接, 取消链式)"
    for t in "${LANDING_TAGS[@]}"; do
        [[ $t == "$a" ]] && continue
        opts+=("$t")
        say "  ${cyan}${#opts[@]}.${none} $t"
    done
    c=$(ask_choice "请选择" 1 1 "${#opts[@]}") || exit 1
    b=${opts[c - 1]}
    if [[ -n $b ]]; then
        cur=$b
        while [[ -n $cur && $n -lt 20 ]]; do # 防止形成环
            [[ $cur == "$a" ]] && {
                err "会形成循环链路, 已取消"
                return 1
            }
            cur=$(cfg_get '.outbounds[] | select(.tag == $t) | .streamSettings.sockopt.dialerProxy // ""' --arg t "$cur")
            n=$((n + 1))
        done
        cfg_jq '(.outbounds[] | select(.tag == $a) | .streamSettings.sockopt.dialerProxy) = $b' --arg a "$a" --arg b "$b" || return 1
    else
        cfg_jq '(.outbounds[] | select(.tag == $a)) |= del(.streamSettings.sockopt.dialerProxy)' --arg a "$a" || return 1
    fi
    cfg_commit && ok "已设置: [$a] ${b:+经由 [$b] }连接"
}

# ---------------------------------------------------------------------
# 分流规则
# ---------------------------------------------------------------------
rule_state() { # 键 → 开/关
    local n
    n=$(cfg_get '[.routing.rules[]? | select((.ruleTag // "") | startswith($p))] | length' --arg p "xs-block-$1")
    if ((${n:-0} > 0)); then echo "${green}开${none}"; else echo "关"; fi
}
rule_toggle() { # private|bt|ads|cn
    local key=$1 n json
    n=$(cfg_get '[.routing.rules[]? | select((.ruleTag // "") | startswith($p))] | length' --arg p "xs-block-$key")
    if ((${n:-0} > 0)); then
        cfg_jq '.routing.rules |= map(select((.ruleTag // "") | startswith($p) | not))' --arg p "xs-block-$key" || return 1
        # Xray ≥ 26.9 的 freedom 默认也会拦截 VLESS/VMess/Trojan/SS/Hy2 入站访问私有地址, 关闭屏蔽时需显式放行
        if [[ $key == private ]]; then
            cfg_jq '(.outbounds[] | select(.protocol == "freedom" and ((.tag // "") | test("^direct(-v4|-v6)?$"))))
                |= (.settings.finalRules = ([$r] + [(.settings.finalRules // [])[] | select(. != $r)]))' --argjson r "$PRIV_ALLOW" || return 1
        fi
    else
        case $key in
            private) json='[{"ruleTag":"xs-block-private","ip":["geoip:private"],"outboundTag":"block"},{"ruleTag":"xs-block-private-d","domain":["geosite:private"],"outboundTag":"block"}]' ;;
            bt) json='[{"ruleTag":"xs-block-bt","protocol":["bittorrent"],"outboundTag":"block"}]' ;;
            ads) json='[{"ruleTag":"xs-block-ads","domain":["geosite:category-ads-all"],"outboundTag":"block"}]' ;;
            cn) json='[{"ruleTag":"xs-block-cn","domain":["geosite:cn"],"outboundTag":"block"},{"ruleTag":"xs-block-cn-ip","ip":["geoip:cn"],"outboundTag":"block"}]' ;;
        esac
        cfg_jqL '.routing.rules += $r | sort_rules' --argjson r "$json" || return 1
        if [[ $key == private ]]; then
            cfg_jq '(.outbounds[] | select(.protocol == "freedom" and .settings.finalRules != null))
                |= (.settings.finalRules |= map(select(. != $r)) | if (.settings.finalRules | length) == 0 then del(.settings.finalRules) else . end)' \
                --argjson r "$PRIV_ALLOW" || return 1
        fi
    fi
    cfg_commit
}
PRIV_ALLOW='{"action":"allow","ip":["geoip:private"]}'
custom_rule_add() {
    local c items="" dom="" ip="" it n nodes='null' sel i
    local -a arr
    title "添加分流规则"
    say " ${cyan}1.${none} AI 服务 (OpenAI / ChatGPT 等)   geosite:openai"
    say " ${cyan}2.${none} Netflix                        geosite:netflix"
    say " ${cyan}3.${none} Disney+                        geosite:disney"
    say " ${cyan}4.${none} YouTube / Google               geosite:youtube, geosite:google"
    say " ${cyan}5.${none} TikTok                         geosite:tiktok"
    say " ${cyan}6.${none} Telegram                       geosite:telegram, geoip:telegram"
    say " ${cyan}7.${none} 中国大陆                        geosite:cn, geoip:cn"
    say " ${cyan}8.${none} 自定义 (域名 / geosite / IP / geoip)"
    c=$(ask_choice "请选择" 1 1 8) || exit 1
    case $c in
        1) items="geosite:openai" ;;
        2) items="geosite:netflix" ;;
        3) items="geosite:disney" ;;
        4) items="geosite:youtube,geosite:google" ;;
        5) items="geosite:tiktok" ;;
        6) items="geosite:telegram,geoip:telegram" ;;
        7) items="geosite:cn,geoip:cn" ;;
        8) items=$(ask_required "匹配项, 逗号分隔 (如 geosite:xxx, domain:example.com, full:a.com, keyword:abc, 1.2.3.0/24, geoip:us)") ;;
    esac
    IFS=, read -r -a arr <<<"$items"
    for it in "${arr[@]}"; do
        it=${it//[[:space:]]/}
        [[ -z $it ]] && continue
        if [[ $it == geoip:* || $it == ext-ip:* ]] || is_ip "${it%/*}"; then ip+="${ip:+,}$it"; else dom+="${dom:+,}$it"; fi
    done
    [[ -n $dom$ip ]] || {
        err "没有有效的匹配项"
        return 1
    }
    if ask_yn "只对部分节点生效? (默认对所有节点生效)" n; then
        list_nodes || return 1
        sel=$(ask_required "节点序号, 逗号分隔 (如 1,3)") || exit 1
        nodes=$(for i in ${sel//,/ }; do
            [[ $i =~ ^[0-9]+$ ]] && ((i >= 1 && i <= ${#NODE_TAGS[@]})) && printf '%s\n' "${NODE_TAGS[i - 1]}"
        done | jq -R . | jq -sc .)
        [[ $nodes == '[]' ]] && {
            err "没有选择有效的节点"
            return 1
        }
    fi
    pick_outbound "匹配到的流量走哪个出口" 0 || return 1
    n=$(cfg_get '[.routing.rules[]? | (.ruleTag // "") | select(startswith("xs-custom-")) | ltrimstr("xs-custom-") | split("-")[0] | tonumber?] | max // 0')
    n=$((${n:-0} + 1))
    cfg_jqL '($dom | split(",") | map(select(. != ""))) as $d | ($ip | split(",") | map(select(. != ""))) as $i
        | .routing.rules += ((if ($d | length) > 0 then [{ruleTag: ("xs-custom-" + $n), domain: $d}] else [] end)
            + (if ($i | length) > 0 then [{ruleTag: ("xs-custom-" + $n + "-ip"), ip: $i}] else [] end)
            | map(. + {outboundTag: $o} + (if $nodes != null then {inboundTag: $nodes} else {} end)))
        | sort_rules' --arg dom "$dom" --arg ip "$ip" --arg n "$n" --arg o "$PICKED_OUT" --argjson nodes "$nodes" || return 1
    cfg_commit && ok "分流规则已添加: ${dom}${dom:+${ip:+,}}${ip} → $(out_name "$PICKED_OUT")"
}
custom_rule_del() {
    local rows row i=0 tag match out nodes c
    local -a tags=()
    mapfile -t rows < <(cfg_get '.routing.rules[]? | select((.ruleTag // "") | startswith("xs-custom-"))
        | [.ruleTag, (((.domain // []) + (.ip // [])) | join(",")), (.outboundTag // ""), ((.inboundTag // ["全部节点"]) | join(","))] | join("\u001f")')
    if ((${#rows[@]} == 0)); then
        info "暂无自定义分流规则"
        return 0
    fi
    for row in "${rows[@]}"; do
        IFS=$'\x1f' read -r tag match out nodes <<<"$row"
        i=$((i + 1))
        tags+=("$tag")
        say " ${cyan}$i.${none} ${match:0:60} → $(out_name "$out")  ${gray}[$nodes]${none}"
    done
    c=$(ask_choice "选择要删除的规则 (0 返回)" 0 0 "$i") || exit 1
    ((c == 0)) && return 0
    cfg_jq '.routing.rules |= map(select(.ruleTag != $t))' --arg t "${tags[c - 1]}" || return 1
    cfg_commit && ok "已删除"
}
set_direct_ip_pref() {
    local -a o=(AsIs UseIPv4v6 UseIPv6v4 ForceIPv4 ForceIPv6)
    local -a d=("系统默认" "优先 IPv4 (解析失败时回退系统)" "优先 IPv6 (解析失败时回退系统)" "强制 IPv4" "强制 IPv6")
    local i
    for i in "${!o[@]}"; do say "  ${cyan}$((i + 1)).${none} ${o[i]}  ${gray}${d[i]}${none}"; done
    i=$(ask_choice "直连出口的 IP 优先级" 1 1 "${#o[@]}") || exit 1
    cfg_jq '(.outbounds[] | select(.tag == "direct")) |= (del(.settings.domainStrategy)
        | if $s == "AsIs" then del(.streamSettings.sockopt.domainStrategy) else .streamSettings.sockopt.domainStrategy = $s end)' \
        --arg s "${o[i - 1]}" || return 1
    cfg_commit && ok "已设置为 ${o[i - 1]}"
}
set_domain_strategy() {
    local -a o=(AsIs IPIfNonMatch IPOnDemand)
    local -a d=("不解析域名, 最快 (IP 类规则只对 IP 目标生效)" "无规则命中时解析域名再匹配 IP 规则 (推荐)" "遇到 IP 规则即解析域名")
    local i
    for i in "${!o[@]}"; do say "  ${cyan}$((i + 1)).${none} ${o[i]}  ${gray}${d[i]}${none}"; done
    i=$(ask_choice "路由域名解析策略" 2 1 3) || exit 1
    cfg_jq '.routing.domainStrategy = $s' --arg s "${o[i - 1]}" || return 1
    cfg_commit && ok "已设置为 ${o[i - 1]}"
}
set_dns() {
    local c servers q
    say "  ${cyan}1.${none} 系统默认 (不配置 dns)"
    say "  ${cyan}2.${none} 1.1.1.1 + 8.8.8.8 (含 IPv6)"
    say "  ${cyan}3.${none} DoH: Cloudflare + Google"
    say "  ${cyan}4.${none} 自定义"
    c=$(ask_choice "请选择" 1 1 4) || exit 1
    case $c in
        1)
            cfg_jq 'del(.dns)' || return 1
            cfg_commit && ok "已恢复系统 DNS"
            return
            ;;
        2) servers='["1.1.1.1","8.8.8.8","2606:4700:4700::1111","2001:4860:4860::8888"]' ;;
        3) servers='["https://1.1.1.1/dns-query","https://dns.google/dns-query"]' ;;
        4) servers=$(ask_required "DNS 服务器, 逗号分隔 (支持 IP / https:// DoH / localhost)" | jq -R -c 'split(",") | map(select(. != ""))') ;;
    esac
    say "查询策略:  ${cyan}1.${none} UseIP (v4+v6)   ${cyan}2.${none} UseIPv4   ${cyan}3.${none} UseIPv6"
    case $(ask_choice "请选择" 1 1 3) in
        1) q=UseIP ;;
        2) q=UseIPv4 ;;
        3) q=UseIPv6 ;;
    esac
    cfg_jq '.dns = {servers: $s, queryStrategy: $q}' --argjson s "$servers" --arg q "$q" || return 1
    cfg_commit && ok "DNS 已设置"
}
routing_menu() {
    local c ds ipp dns
    while :; do
        cfg_load || return 1
        ds=$(cfg_get '.routing.domainStrategy // "AsIs"')
        ipp=$(cfg_get '[.outbounds[] | select(.tag == "direct") | (.streamSettings.sockopt.domainStrategy // .settings.domainStrategy // "AsIs")][0]')
        dns=$(cfg_get 'if .dns.servers then (.dns.servers | map(if type == "object" then .address else . end) | join(",")) else "系统默认" end')
        title "分流规则"
        say " ${cyan}1.${none} 屏蔽私有 / 局域网地址   [$(rule_state private)]  ${gray}(关闭后客户端可访问服务器内网)${none}"
        say " ${cyan}2.${none} 屏蔽 BT 下载            [$(rule_state bt)]"
        say " ${cyan}3.${none} 屏蔽广告域名            [$(rule_state ads)]"
        say " ${cyan}4.${none} 屏蔽中国大陆网站 / IP   [$(rule_state cn)]"
        say " ${cyan}5.${none} 添加分流规则 (如 ChatGPT / Netflix 走指定落地)"
        say " ${cyan}6.${none} 查看 / 删除分流规则"
        say " ${cyan}7.${none} 直连出口 IP 优先级      [$ipp]"
        say " ${cyan}8.${none} 路由域名解析策略        [$ds]"
        say " ${cyan}9.${none} DNS 服务器              [$dns]"
        say " ${cyan}0.${none} 返回"
        say " ${gray}规则优先级: 屏蔽 > 分流规则 > 用户落地 > 节点落地 > 全局默认出口${none}"
        c=$(ask_choice "请选择" 0 0 9) || exit 1
        case $c in
            0) return 0 ;;
            1) rule_toggle private ;;
            2) rule_toggle bt ;;
            3) rule_toggle ads ;;
            4) rule_toggle cn ;;
            5) custom_rule_add ;;
            6) custom_rule_del ;;
            7) set_direct_ip_pref ;;
            8) set_domain_strategy ;;
            9) set_dns ;;
        esac
    done
}

# ---------------------------------------------------------------------
# 系统工具
# ---------------------------------------------------------------------
bbr_state() { if [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]]; then echo "${green}已开启${none}"; else echo "未开启"; fi; }
enable_bbr() {
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]]; then
        ok "BBR 已经是开启状态"
        return 0
    fi
    modprobe tcp_bbr >/dev/null 2>&1
    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        err "当前内核不支持 BBR (OpenVZ / LXC 容器, 或内核版本低于 4.9)"
        return 1
    fi
    mkdir -p "${BBR_SYSCTL%/*}"
    printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' >"$BBR_SYSCTL"
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]]; then ok "BBR 已开启"; else err "开启失败 (容器环境可能无权修改内核参数)"; fi
}
stats_on() { jq -e '(.api.listen // "") != "" and .stats != null' "$CONFIG_FILE" >/dev/null 2>&1; }
stats_enable() {
    local p
    cfg_load || return 1
    p=$(free_port tcp 10085)
    cfg_jq '.api = {tag: "api", listen: ("127.0.0.1:" + $p), services: ["StatsService"]}
        | .stats = {}
        | .policy.levels["0"].statsUserUplink = true | .policy.levels["0"].statsUserDownlink = true
        | .policy.system = ((.policy.system // {}) + {statsInboundUplink: true, statsInboundDownlink: true,
                                                        statsOutboundUplink: true, statsOutboundDownlink: true})' --arg p "$p" || return 1
    cfg_commit && ok "流量统计已开启 (数据保存在内存中, Xray 重启后清零)"
}
stats_disable() {
    cfg_load || return 1
    cfg_jq 'del(.api, .stats)
        | if .policy.levels["0"] then .policy.levels["0"] |= del(.statsUserUplink, .statsUserDownlink) else . end
        | if .policy.system then .policy.system |= del(.statsInboundUplink, .statsInboundDownlink, .statsOutboundUplink, .statsOutboundDownlink) else . end' || return 1
    cfg_commit && ok "流量统计已关闭"
}
stats_show() { # [reset]
    local srv out rows row kind name dir v
    srv=$(jq -r '.api.listen // empty' "$CONFIG_FILE" 2>/dev/null)
    [[ -n $srv ]] || {
        warn "流量统计未开启"
        return 1
    }
    if [[ ${1:-} == reset ]]; then out=$("$XRAY_BIN" api statsquery --server="$srv" -reset 2>/dev/null); else out=$("$XRAY_BIN" api statsquery --server="$srv" 2>/dev/null); fi
    [[ -n $out ]] || {
        err "查询失败 (Xray 是否在运行?)"
        return 1
    }
    title "流量统计 (自 Xray 上次启动$([[ ${1:-} == reset ]] && echo ", 已清零"))"
    mapfile -t rows < <(jq -r '[.stat[]? | (.name | split(">>>")) as $n | select($n[0] == "user" or $n[0] == "inbound" or $n[0] == "outbound")
        | {k: $n[0], n: $n[1], d: $n[3], v: (.value // 0 | tonumber)}]
        | group_by([.k, .n]) | map({k: .[0].k, n: .[0].n,
            up: (map(select(.d == "uplink") | .v) | add // 0), down: (map(select(.d == "downlink") | .v) | add // 0)})
        | sort_by(.k)[] | [.k, .n, (.up | tostring), (.down | tostring)] | join("\u001f")' <<<"$out")
    if ((${#rows[@]} == 0)); then
        say " ${gray}(暂无数据)${none}"
        return 0
    fi
    for row in "${rows[@]}"; do
        IFS=$'\x1f' read -r kind name dir v <<<"$row"
        [[ $kind == inbound && $name == api ]] && continue
        case $kind in user) kind="用户" ;; inbound) kind="节点" ;; outbound) kind="出站" ;; esac
        say " $kind ${bold}$name${none}  ↑ $(human_bytes "$dir")  ↓ $(human_bytes "$v")"
    done
}
stats_menu() {
    if ! stats_on; then
        ask_yn "流量统计未开启, 现在开启? (按节点 / 用户 / 出站统计流量)" y && stats_enable
        return
    fi
    say " ${cyan}1.${none} 查看流量   ${cyan}2.${none} 查看并清零   ${cyan}3.${none} 关闭流量统计   ${cyan}0.${none} 返回"
    case $(ask_choice "请选择" 1 0 3) in
        1) stats_show ;;
        2) stats_show reset ;;
        3) stats_disable ;;
    esac
}
log_follow() {
    trap ':' INT
    tail -n 30 -f "$@"
    trap 'exit 130' INT
}
log_menu() {
    local lv acc c
    lv=$(jq -r '.log.loglevel // "warning"' "$CONFIG_FILE" 2>/dev/null)
    acc=$(jq -r '.log.access // "none"' "$CONFIG_FILE" 2>/dev/null)
    title "日志"
    say " ${cyan}1.${none} 查看错误日志 (最近 50 行)"
    say " ${cyan}2.${none} 实时跟踪日志 (Ctrl+C 退出跟踪)"
    say " ${cyan}3.${none} 日志级别     [$lv]"
    say " ${cyan}4.${none} 访问日志     [$([[ $acc == none || -z $acc ]] && echo 关 || echo "开: $acc")]"
    say " ${cyan}0.${none} 返回"
    c=$(ask_choice "请选择" 1 0 4) || exit 1
    case $c in
        1)
            tail -n 50 "$LOG_DIR/error.log" 2>/dev/null >&2 || info "暂无日志"
            [[ $INIT != systemd ]] && tail -n 20 "$LOG_DIR/stdout.log" 2>/dev/null >&2
            ;;
        2)
            if [[ $acc != none && -n $acc ]]; then log_follow "$LOG_DIR/error.log" "$acc"; else log_follow "$LOG_DIR/error.log"; fi
            ;;
        3)
            local -a lvs=(debug info warning error none)
            local i
            for i in "${!lvs[@]}"; do say "  ${cyan}$((i + 1)).${none} ${lvs[i]}"; done
            i=$(ask_choice "日志级别" 3 1 5) || exit 1
            cfg_load && cfg_jq '.log.loglevel = $l' --arg l "${lvs[i - 1]}" && cfg_commit
            ;;
        4)
            cfg_load || return 1
            if [[ $acc == none || -z $acc ]]; then
                cfg_jq '.log.access = $f' --arg f "$LOG_DIR/access.log" && cfg_commit && info "已开启访问日志: $LOG_DIR/access.log (注意磁盘占用, 排查完建议关闭)"
            else
                cfg_jq '.log.access = "none"' && cfg_commit && ok "已关闭访问日志"
            fi
            ;;
    esac
}
backup_create() {
    local f d
    mkdir -p "$BACKUP_DIR"
    f="$BACKUP_DIR/xray-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    d=$(mktemp -d "$WORK_DIR/bk.XXXXXX")
    cp -f "$CONFIG_FILE" "$d/config.json" 2>/dev/null
    cp -f "$META_FILE" "$d/meta.json" 2>/dev/null
    [[ -d $CERT_DIR ]] && cp -rf "$CERT_DIR" "$d/certs"
    if tar -czf "$f" -C "$d" .; then ok "已备份到: $f"; else err "备份失败"; fi
}
backup_restore() {
    local -a files=()
    local i c d
    mapfile -t files < <(ls -1t "$BACKUP_DIR"/xray-backup-*.tar.gz 2>/dev/null)
    ((${#files[@]})) || {
        info "没有找到备份 ($BACKUP_DIR)"
        return 0
    }
    for i in "${!files[@]}"; do say "  ${cyan}$((i + 1)).${none} ${files[i]##*/}"; done
    c=$(ask_choice "选择要恢复的备份 (0 取消)" 0 0 "${#files[@]}") || exit 1
    ((c == 0)) && return 0
    d=$(mktemp -d "$WORK_DIR/rs.XXXXXX")
    tar -xzf "${files[c - 1]}" -C "$d" && [[ -s $d/config.json ]] || {
        err "备份文件损坏"
        return 1
    }
    [[ -d $d/certs ]] && mkdir -p "$CERT_DIR" && cp -rf "$d/certs/." "$CERT_DIR/"
    [[ -s $d/meta.json ]] && cp -f "$d/meta.json" "$META_FILE"
    CFG_WORK="$d/config.json"
    cfg_commit && ok "已从备份恢复"
}
edit_config() {
    local ed="${EDITOR:-}" e f
    if [[ -z $ed ]]; then for e in nano vim vi; do command -v "$e" >/dev/null 2>&1 && {
        ed=$e
        break
    }; done; fi
    [[ -n $ed ]] || {
        err "未找到文本编辑器 (nano / vim / vi)"
        return 1
    }
    f=$(tmpf)
    cp -f "$CONFIG_FILE" "$f" 2>/dev/null || default_config >"$f"
    "$ed" "$f"
    if cmp -s "$f" "$CONFIG_FILE"; then
        info "未做修改"
        return 0
    fi
    jq -e . "$f" >/dev/null 2>&1 || {
        err "JSON 格式错误, 已放弃本次修改"
        return 1
    }
    CFG_WORK=$f
    cfg_commit
}
rollback_prev() {
    [[ -s $BACKUP_DIR/config.prev.json ]] || {
        warn "没有可回滚的配置"
        return 1
    }
    ask_yn "回滚到上一次修改前的配置?" n || return 0
    CFG_WORK=$(tmpf)
    cp -f "$BACKUP_DIR/config.prev.json" "$CFG_WORK"
    cfg_commit && ok "已回滚"
}
settings_menu() {
    local c v addr proxy fw
    while :; do
        addr=$(meta_get '.settings.address // ""')
        proxy=$(meta_get '.settings.gh_proxy // ""')
        fw=$(meta_get '.settings.firewall // "on"')
        title "脚本设置"
        say " ${cyan}1.${none} 分享链接默认地址     [${addr:-自动检测}]"
        say " ${cyan}2.${none} GitHub 下载加速前缀  [${proxy:-未设置}]  ${gray}(国内机器可填, 如 https://ghfast.top/)${none}"
        say " ${cyan}3.${none} 自动放行防火墙端口   [$([[ $fw == off ]] && echo 关 || echo "${green}开${none}")]"
        say " ${cyan}0.${none} 返回"
        c=$(ask_choice "请选择" 0 0 3) || exit 1
        case $c in
            0) return 0 ;;
            1)
                v=$(ask "地址 (IP 或域名; 输入 auto 重新自动检测)" "$addr") || exit 1
                if [[ $v == auto ]]; then
                    meta_set 'del(.settings.address)'
                    v=$(server_addr)
                elif ! is_ip "$v" && ! is_domain "$v"; then
                    error
                    continue
                fi
                meta_set '.settings.address = $v' --arg v "$v"
                links_refresh
                ok "已设置: $v"
                ;;
            2)
                v=$(ask "加速前缀 (输入 - 清除)" "$proxy") || exit 1
                [[ $v == - ]] && v=""
                if [[ -n $v && $v != http://* && $v != https://* ]]; then
                    error
                    continue
                fi
                meta_set '.settings.gh_proxy = $v' --arg v "$v"
                ok "已设置"
                ;;
            3)
                if [[ $fw == off ]]; then meta_set '.settings.firewall = "on"'; else meta_set '.settings.firewall = "off"'; fi
                ok "已切换"
                ;;
        esac
    done
}
tools_menu() {
    local c
    while :; do
        title "系统工具"
        say " ${cyan}1.${none} 开启 BBR 拥塞控制          [$(bbr_state)]"
        say " ${cyan}2.${none} 流量统计                   [$(stats_on && echo "${green}开${none}" || echo 关)]"
        say " ${cyan}3.${none} geo 规则文件 (更新 / 自动更新)"
        say " ${cyan}4.${none} 日志 (查看 / 级别 / 访问日志)"
        say " ${cyan}5.${none} 备份配置"
        say " ${cyan}6.${none} 从备份恢复"
        say " ${cyan}7.${none} 手动编辑配置文件 (保存后自动校验)"
        say " ${cyan}8.${none} 回滚到上一次修改前的配置"
        say " ${cyan}9.${none} 脚本设置 (链接地址 / GitHub 加速 / 防火墙)"
        say "${cyan}10.${none} 更新本脚本"
        say " ${cyan}0.${none} 返回"
        c=$(ask_choice "请选择" 0 0 10) || exit 1
        case $c in
            0) return 0 ;;
            1) enable_bbr ;;
            2) stats_menu ;;
            3) geo_menu ;;
            4) log_menu ;;
            5) backup_create ;;
            6) backup_restore ;;
            7) edit_config ;;
            8) rollback_prev ;;
            9) settings_menu ;;
            10) update_script ;;
        esac
    done
}
service_menu() {
    local c
    while :; do
        title "服务管理"
        say " Xray: $(xray_status_text)   服务管理方式: $INIT"
        say " ${cyan}1.${none} 启动   ${cyan}2.${none} 停止   ${cyan}3.${none} 重启   ${cyan}4.${none} 状态   ${cyan}5.${none} 日志   ${cyan}6.${none} 校验配置   ${cyan}0.${none} 返回"
        c=$(ask_choice "请选择" 0 0 6) || exit 1
        case $c in
            0) return 0 ;;
            1)
                service_ensure
                svc start >/dev/null 2>&1
                sleep 1
                if svc_running; then ok "已启动"; else
                    err "启动失败"
                    show_start_error
                fi
                ;;
            2) svc stop >/dev/null 2>&1 && ok "已停止" ;;
            3) if svc_restart_check; then ok "已重启"; else
                err "重启失败"
                show_start_error
            fi ;;
            4) svc status ;;
            5) log_menu ;;
            6) xray_test "$CONFIG_FILE" && ok "配置校验通过" ;;
        esac
    done
}

# ---------------------------------------------------------------------
# 主菜单 / 命令行
# ---------------------------------------------------------------------
main_menu() {
    local c n def
    while :; do
        n=0
        [[ -s $CONFIG_FILE ]] && n=$(jq '(.inbounds // []) | length' "$CONFIG_FILE" 2>/dev/null)
        say ""
        say "${cyan}${BANNER}${none}"
        say " ${gray}脚本 v$SCRIPT_VERSION | $OS_NAME | $INIT$([[ -x $SHORTCUT ]] && echo " | 快捷命令: ${SHORTCUT##*/}")${none}"
        say " Xray: $(xray_status_text)   节点: ${n:-0}"
        hr
        say " ${cyan}1.${none} 安装 / 更新 Xray 内核"
        say " ${cyan}2.${none} 添加节点"
        say " ${cyan}3.${none} 查看节点 / 分享链接"
        say " ${cyan}4.${none} 管理节点 (端口 / 用户 / 参数 / 落地 / 删除)"
        say " ${cyan}5.${none} 落地 / 出站管理"
        say " ${cyan}6.${none} 分流规则"
        say " ${cyan}7.${none} 服务管理 (启停 / 状态 / 日志)"
        say " ${cyan}8.${none} 系统工具 (BBR / 流量统计 / 备份 / 设置)"
        say " ${cyan}9.${none} 卸载"
        say " ${cyan}0.${none} 退出"
        hr
        if [[ ! -x $XRAY_BIN ]]; then def=1; elif ((${n:-0} == 0)); then def=2; else def=3; fi
        c=$(ask_choice "请选择" "$def" 0 9) || exit 1
        case $c in
            0) exit 0 ;;
            1) install_menu ;;
            2) add_node_wizard ;;
            3) view_nodes_menu ;;
            4) ensure_ready && manage_nodes_menu ;;
            5) ensure_ready && landing_menu ;;
            6) ensure_ready && routing_menu ;;
            7) service_menu ;;
            8) tools_menu ;;
            9) uninstall_all ;;
        esac
    done
}
usage() {
    cat >&2 <<EOF
Xray 管理脚本 v$SCRIPT_VERSION
用法: ${SHORTCUT##*/} [命令]
  (无参数)                 交互菜单
  install [版本]           安装 / 更新 Xray 内核 (默认最新正式版)
  add                      添加节点
  list                     列出节点
  info <节点名>            查看节点详情与链接
  links [节点名]           只输出分享链接 (纯文本, 方便复制 / 管道)
  mihomo [节点名]          输出 mihomo (Clash Meta) 节点配置
  port <节点名> <端口>     修改节点端口
  start | stop | restart | status
  log                      实时查看日志
  test                     校验配置文件
  stats [reset]            查看流量统计
  update-geo               更新 geo 规则文件
  bbr                      开启 BBR
  backup                   备份配置
  uninstall                卸载
EOF
}
cli() {
    local cmd=$1
    shift
    case $cmd in
        install | update) install_xray "${1:-}" ;;
        add) add_node_wizard ;;
        list | ls) cfg_load && list_nodes ;;
        info | show)
            [[ -n ${1:-} ]] || die "用法: info <节点名>"
            cfg_load && show_node "$1"
            ;;
        links | link) links_print "${1:-}" ;;
        mihomo | clash) mihomo_print "${1:-}" ;;
        port)
            [[ -n ${1:-} && -n ${2:-} ]] || die "用法: port <节点名> <端口>"
            ensure_ready && node_set_port "$1" "$2"
            ;;
        start | stop | restart | status) svc "$cmd" ;;
        log | logs) log_follow "$LOG_DIR/error.log" ;;
        test) xray_test "$CONFIG_FILE" && ok "配置校验通过" ;;
        stats) stats_show "${1:-}" ;;
        update-geo | geo) update_geo ;;
        bbr) enable_bbr ;;
        backup) backup_create ;;
        uninstall) uninstall_all ;;
        version | -v | --version) say "脚本 v$SCRIPT_VERSION  Xray $(xray_ver)" ;;
        help | -h | --help) usage ;;
        *)
            usage
            return 1
            ;;
    esac
}
main() {
    init_workdir
    [[ $EUID -eq 0 ]] || die "请使用 root 用户运行 (可先执行 sudo -i)"
    if (($# == 0)) && [[ ! -t 0 && ${XS_ALLOW_PIPE:-0} != 1 ]]; then
        die "标准输入不是终端 (可能用了 curl ... | bash), 菜单无法读取输入。请改用: bash <(curl -fsSL $SCRIPT_URL)"
    fi
    detect_system
    ensure_cmds curl jq || die "依赖安装失败"
    meta_init
    install_shortcut
    if (($#)); then
        cli "$@"
        exit $?
    fi
    main_menu
}

if [[ ${XRAY_SCRIPT_SOURCE_ONLY:-0} == 1 ]]; then
    init_workdir
    detect_system
    return 0 2>/dev/null || exit 0
fi
main "$@"
