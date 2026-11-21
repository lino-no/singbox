#!/usr/bin/env bash
# ============================================================================
# sing-box-vps :: 小李的singbox VPS ai双栈智能管理脚本 0.1.0   (LINONO)
# Repository : https://github.com/lisiyong0707/singbox
#
# 功能总览:
#   VLESS Reality / Reality gRPC / ShadowTLS v3+SS2022 / Shadowsocks 2022 /
#   Trojan TLS / VLESS TLS / Hysteria2 / TUIC v5 / AnyTLS / NaiveProxy / Snell /
#   Cloudflare Tunnel / Cloudflare WARP 出站 / 订阅系统 (sing-box / Clash Meta /
#   Shadowrocket) / 节点二维码 / 证书管理 (Certbot 自动续期) / 系统诊断 / 测速 /
#   配置备份回滚
#
# 设计原则:
#   - set -Eeuo pipefail 严格模式, 全程 trap 统一错误处理
#   - 所有配置写入 (config.json / state.json / 订阅文件) 一律 mktemp + 校验 + install 原子替换
#   - 所有 jq 变更一律先在候选文件上验证 (sing-box check / jq 语法), 失败绝不覆盖生产文件,
#     并自动保留最近一次可用配置备份用于一键回滚
#   - 绝不使用 eval; 所有用户输入统一走 ask_*/valid_* 校验管道
#
# 终端能力依赖与降级 (v0.1.0 起的交互层; 不满足时自动降级, 不影响部署功能):
#   能力                 依赖                              不支持时
#   ------------------   -------------------------------   --------------------------------
#   颜色                 stdout 是终端, 且未设 NO_COLOR     不输出任何颜色转义码
#   Unicode 图标/线条    LANG/LC_ALL 含 UTF-8               ✓✗●▸═ 换成 [OK] [X] * > =; 转圈换 | / - \
#   真彩色徽标           COLORTERM=truecolor|24bit          256 色量化 -> 16 色 -> 仅 ASCII 字样
#   四分块字符 ▘▝▖▗▚▞   终端字体包含 Block Elements        TERM=linux/vt* 自动退回半块字符;
#                                                          也可设 SB_LOGO_HALF=1 强制
#   一键复制 (OSC 52)    终端允许 OSC 52 写剪贴板           静默无效; 始终可用 p 显示完整链接
#                        (tmux 需 set-clipboard on / allow-passthrough, 已自动做 tmux/screen 封装)
#   图片协议 (可选)      iTerm2 / WezTerm / kitty + SB_LOGO_PNG  使用色块版徽标
#   二维码               终端宽度 >= 60 列且 qrencode 可用   跳过渲染, 提示 PNG 路径
#   白底主题             SB_THEME=light                     黄色加深、浅灰变深灰
# ============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="0.1.0"
readonly SB_MIN_VERSION="1.12.0"

readonly CONFIG_DIR="/etc/sing-box"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly STATE_DIR="/var/lib/sing-box-vps"
readonly STATE_FILE="${STATE_DIR}/connections.json"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly SUB_DIR="${STATE_DIR}/subscriptions"
readonly QR_CACHE_DIR="${STATE_DIR}/qrcache"
readonly LOG_FILE="${STATE_DIR}/sing-box-vps.log"

readonly CF_CONFIG_DIR="/etc/cloudflared"
readonly CF_CONFIG_FILE="${CF_CONFIG_DIR}/config.yml"
readonly CF_CRED_DIR="${CF_CONFIG_DIR}/creds"

readonly CERT_HOOK="/etc/letsencrypt/renewal-hooks/deploy/restart-sing-box"
readonly MANAGER_PATH="/usr/local/sbin/sing-box-vps"
readonly SHORTCUT_PATH="/usr/local/bin/sb"
readonly SUB_HTTPD_UNIT="/etc/systemd/system/sing-box-vps-sub.service"
readonly LOCK_FILE="/run/sing-box-vps.lock"
readonly LOGROTATE_FILE="/etc/logrotate.d/sing-box-vps"

SCRIPT_UPDATE_URL="${SCRIPT_UPDATE_URL:-https://raw.githubusercontent.com/lisiyong0707/singbox/main/sb.sh}"

readonly REALITY_PRESET_DOMAINS=(
  "gateway.icloud.com"
  "mask.icloud.com"
  "www.cloudflare.com"
  "www.microsoft.com"
  "www.google.com"
  "www.apple.com"
  "dl.google.com"
  "swdist.apple.com"
)

# ---------------------------------------------------------------------------
# 颜色与日志
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 终端能力探测 / 颜色 / 图标 (自适应降级, 详见文件头部说明)
# ---------------------------------------------------------------------------
RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; BOLD=''; DIM=''; NC=''
UI_TTY=0; UI_COLOR=0; UI_UTF8=0; UI_TRUECOLOR=0; UI_256=0; UI_LIGHT=0
G_OK='[OK]'; G_X='[X]'; G_WARN='!'; G_SKIP='-'; G_DOT='*'; G_OFF='o'; G_ARR='>'
G_H='-'; G_HH='='; G_STAR='*'; G_ELL='...'; G_INFO='[i]'; G_BAR='|'; G_END='`'
G_SPIN=('|' '/' '-' '\')
UI_LC=('' '' '' '' '' '')

ui_init() {
  UI_TTY=0; [[ -t 1 ]] && UI_TTY=1
  UI_COLOR=$UI_TTY
  if [[ -n ${NO_COLOR:-} || ${TERM:-dumb} == dumb ]]; then UI_COLOR=0; fi
  local loc=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
  loc=${loc,,}
  UI_UTF8=0
  if [[ $loc == *utf-8* || $loc == *utf8* ]]; then UI_UTF8=1; fi
  UI_TRUECOLOR=0
  local ct=${COLORTERM:-}
  # sudo 会丢掉 COLORTERM: 从调用者 (sudo 进程) 的原始环境里补读
  if [[ -z $ct && -n ${SUDO_USER:-} && -r /proc/$PPID/environ ]]; then
    ct=$(tr '\0' '\n' </proc/$PPID/environ 2>/dev/null | sed -n 's/^COLORTERM=//p' | head -n1 || true)
  fi
  case $ct in truecolor|24bit) UI_TRUECOLOR=1 ;; esac
  if [[ ${SB_TRUECOLOR:-} == 1 || ${TERM:-} == *-direct || ${TERM_PROGRAM:-} == iTerm.app || ${TERM_PROGRAM:-} == WezTerm || -n ${WT_SESSION:-} ]]; then UI_TRUECOLOR=1; fi
  UI_256=0
  if [[ ${TERM:-} == *256color* ]]; then UI_256=1; fi
  UI_LIGHT=0
  if [[ ${SB_THEME:-} == light ]]; then UI_LIGHT=1; fi

  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; BOLD=''; DIM=''; NC=''
  UI_LC=('' '' '' '' '' '')
  if (( UI_COLOR )); then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'; MAGENTA=$'\033[0;35m'; BOLD=$'\033[1m'; NC=$'\033[0m'
    if (( UI_LIGHT )); then
      YELLOW=$'\033[0;33m'                       # 白底: 黄色加深
      if (( UI_256 )); then DIM=$'\033[38;5;240m'; else DIM=$'\033[0;90m'; fi   # 浅灰 -> 深灰
    else
      YELLOW=$'\033[1;33m'
      if (( UI_256 )); then DIM=$'\033[38;5;245m'; else DIM=$'\033[0;90m'; fi
    fi
    # LINONO 六个字母: 绿 青 蓝 紫 黄 红 (白底用加深版)
    local -a rgb c256 c16=(32 36 34 35 33 31) i
    if (( UI_LIGHT )); then
      rgb=("46;139;73" "11;122;144" "47;102;201" "142;68;173" "154;116;0" "179;38;30")
      c256=(29 30 26 97 100 124)
    else
      rgb=("78;195;107" "79;195;217" "91;156;245" "198;120;221" "230;195;74" "229;83;75")
      c256=(71 74 75 176 179 167)
    fi
    for i in 0 1 2 3 4 5; do
      if (( UI_TRUECOLOR )); then UI_LC[i]=$'\033[38;2;'"${rgb[i]}"'m'
      elif (( UI_256 )); then UI_LC[i]=$'\033[38;5;'"${c256[i]}"'m'
      else UI_LC[i]=$'\033[0;'"${c16[i]}"'m'; fi
    done
  fi
  if (( UI_UTF8 )); then
    G_OK='✓'; G_X='✗'; G_WARN='!'; G_SKIP='–'; G_DOT='●'; G_OFF='○'; G_ARR='▸'
    G_H='─'; G_HH='═'; G_STAR='★'; G_ELL='…'; G_INFO='›'; G_BAR='│'; G_END='└'
    G_SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  else
    G_OK='[OK]'; G_X='[X]'; G_WARN='!'; G_SKIP='-'; G_DOT='*'; G_OFF='o'; G_ARR='>'
    G_H='-'; G_HH='='; G_STAR='*'; G_ELL='...'; G_INFO='[i]'; G_BAR='|'; G_END='`'
    G_SPIN=('|' '/' '-' '\')
  fi
  return 0
}
ui_init

_log_raw() {
  # 日志文件不含颜色转义, 便于后续 grep/诊断
  [[ -d $STATE_DIR ]] || install -d -m 700 "$STATE_DIR" 2>/dev/null || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

info() { printf '%s%s%s %s\n' "$BLUE" "$G_INFO" "$NC" "$*"; _log_raw "[INFO] $*"; }
ok()   { printf '%s%s%s %s\n' "$GREEN" "$G_OK" "$NC" "$*"; _log_raw "[OK] $*"; }
warn() { printf '%s%s%s %s\n' "$YELLOW" "$G_WARN" "$NC" "$*" >&2; _log_raw "[WARN] $*"; }
die()  { printf '%s%s%s %s\n' "$RED" "$G_X" "$NC" "$*" >&2; _log_raw "[FATAL] $*"; exit 1; }
title(){ printf '\n%s%s%s %s %s%s%s\n' "${BOLD}${CYAN}" "$G_H" "$G_H" "$*" "$G_H" "$G_H" "$NC"; }

on_error() {
  local exit_code=$? line=$1
  local func="${FUNCNAME[1]:-主流程}"
  # read 因 Ctrl+D / EOF 失败: 视为用户取消输入, 不当作脚本错误
  if [[ ${BASH_COMMAND:-} == read\ * ]]; then
    printf '\n' >&2
    warn "输入已取消。" || true
    exit 130
  fi
  printf '%s%s%s 运行失败: 函数 [%s] 第 %s 行退出 (状态码 %s)\n' "$RED" "$G_X" "$NC" "$func" "$line" "$exit_code" >&2
  printf '%s%s%s 出错命令: %s\n' "$RED" "$G_X" "$NC" "${BASH_COMMAND:-未知}" >&2
  if (( ${#FUNCNAME[@]} > 2 )); then
    local i trace=""
    for ((i=1; i<${#FUNCNAME[@]}-1; i++)); do
      trace+="${FUNCNAME[$i]}"
      if (( i < ${#FUNCNAME[@]}-2 )); then trace+=" <- "; fi
    done
    printf '%s%s%s 调用链: %s\n' "$RED" "$G_X" "$NC" "$trace" >&2
  fi
  printf '%s%s%s 日志文件: %s\n' "$RED" "$G_X" "$NC" "$LOG_FILE" >&2
  _log_raw "[FATAL] func=${func} line=${line} exit=${exit_code} cmd=${BASH_COMMAND:-unknown}"
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR
# ---- 中断提示: 部署进行中被打断时, 告诉用户去跑 reconcile ----
PENDING_TAG=""

on_interrupt() {
  local sig=$1 code=130
  trap - INT TERM HUP
  case $sig in
    TERM) code=143 ;;
    HUP)  code=129 ;;
  esac
  if [[ -n $PENDING_TAG ]]; then
    warn "收到 ${sig}: 节点 [${PENDING_TAG}] 可能已写入并生效, 但连接记录/防火墙可能未完成。请运行: sb reconcile" || true
  else
    warn "已中断 (${sig})。" || true
  fi
  exit "$code"
}
trap 'on_interrupt INT'  INT
trap 'on_interrupt TERM' TERM
trap 'on_interrupt HUP'  HUP

# ---------------------------------------------------------------------------
# 基础前置检查
# ---------------------------------------------------------------------------
require_root()    { [[ ${EUID} -eq 0 ]] || die "请使用 sudo bash $0 运行。"; }
require_systemd() { command -v systemctl >/dev/null 2>&1 || die "此脚本需要 systemd 环境支持。"; }
require_apt()      { command -v apt-get  >/dev/null 2>&1 || die "当前版本仅支持 Debian/Ubuntu (APT) 系统。"; }
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "缺少必要命令: ${c} (请先运行安装/修复环境)。"
  done
}

ensure_dirs() {
  install -d -m 700 "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR" "$SUB_DIR" "$QR_CACHE_DIR"
  fix_config_perms
  if [[ ! -f $STATE_FILE ]]; then
    printf '{"connections":[]}\n' > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
  fi
  [[ -f $LOG_FILE ]] || { : > "$LOG_FILE"; chmod 600 "$LOG_FILE"; }
  ensure_logrotate
}

ensure_logrotate() {
  # 脚本自身的操作日志 (非 sing-box 服务日志, 那部分已由 systemd-journald 管理) 需要
  # 自行轮转, 否则长期运行会无限增长
  [[ -f $LOGROTATE_FILE ]] && return 0
  command -v logrotate >/dev/null 2>&1 || return 0
  tee "$LOGROTATE_FILE" >/dev/null <<EOF
${LOG_FILE} {
  weekly
  rotate 8
  compress
  missingok
  notifempty
  size 5M
}
EOF
}

# ---------------------------------------------------------------------------
# 交互输入与严格校验 (杜绝命令注入 / 非法值)
# ---------------------------------------------------------------------------
confirm() {
  local prompt=$1 default=${2:-N} answer
  read -e -r -p "$prompt [$([[ $default == Y ]] && printf 'Y/n' || printf 'y/N')]: " answer || true
  answer=${answer:-$default}
  [[ $answer =~ ^[Yy]$ ]]
}

ask_required() {
  local prompt=$1 default=${2:-} value
  while true; do
    read -e -r -i "$default" -p "$prompt: " value || die "输入已取消。"
    if [[ -n $value ]]; then printf '%s' "$value"; return 0; fi
    warn "此项不能为空。"
  done
}

# 仅允许安全字符集, 阻断任何可能用于命令注入 / 路径穿越的输入
valid_safe_token() {
  [[ $1 =~ ^[A-Za-z0-9_.:-]{1,128}$ ]]
}

valid_port() {
  [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

ask_port() {
  local prompt=$1 default=$2 value
  while true; do
    read -e -r -i "$default" -p "$prompt: " value || die "输入已取消。"
    value=${value:-$default}
    if valid_port "$value"; then printf '%s' "$((10#$value))"; return 0; fi
    warn "端口必须是 1 到 65535 之间的整数。"
  done
}

valid_hostname() {
  [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

ask_hostname() {
  local prompt=$1 default=${2:-} value
  while true; do
    read -e -r -i "$default" -p "$prompt: " value || die "输入已取消。"
    if valid_hostname "$value"; then printf '%s' "$value"; return 0; fi
    warn "域名格式不正确, 请重新输入。"
  done
}

valid_ipv4() {
  local ip=$1 a b c d o
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  IFS=. read -r a b c d <<<"$ip"
  for o in "$a" "$b" "$c" "$d"; do (( 10#$o <= 255 )) || return 1; done
  return 0
}

valid_ipv6() {
  [[ $1 =~ ^[0-9a-fA-F:]+$ && $1 == *:* ]]
}

# ---------------------------------------------------------------------------
# 原子写入引擎: 任意"候选文件"写好之后, 通过本函数校验并原子替换目标文件,
# 校验失败绝不落地, 不污染生产文件
# ---------------------------------------------------------------------------
fix_config_perms() {
  getent group sing-box >/dev/null 2>&1 || return 0
  chgrp sing-box "$CONFIG_DIR" 2>/dev/null || true
  chmod 750 "$CONFIG_DIR"
  if [[ -f $CONFIG_FILE ]]; then
    chgrp sing-box "$CONFIG_FILE" 2>/dev/null || true
    chmod 640 "$CONFIG_FILE"
  fi
  return 0
}

atomic_install() {
  # atomic_install <candidate_tmp_file> <dest_path> <mode>
  local candidate=$1 dest=$2 mode=${3:-600}
  [[ -s $candidate ]] || die "内部错误: 候选文件为空, 拒绝写入 ${dest}。"
  install -m "$mode" "$candidate" "$dest"
    if [[ $dest == "$CONFIG_FILE" ]]; then fix_config_perms; fi
}

json_validate() {
  # 仅校验合法 JSON 语法
  local file=$1
  jq -e . "$file" >/dev/null 2>&1
}

atomic_json_update() {
  # atomic_json_update <target_file> <jq_filter> [jq_args...]
  # 将 jq_filter 应用到 target_file, 结果写入临时文件并校验 JSON 合法性,
  # 校验通过才原子替换; 失败则保留原文件不变并返回非零
  local target=$1 filter=$2; shift 2
  local candidate
  candidate=$(mktemp "${target}.XXXXXX")
  if ! jq "$filter" "$@" "$target" > "$candidate" 2>>"$LOG_FILE"; then
    rm -f "$candidate"
    warn "jq 变更执行失败, 已保留原文件不变: ${target}"
    return 1
  fi
  if ! json_validate "$candidate"; then
    rm -f "$candidate"
    warn "jq 变更结果 JSON 校验失败, 已回滚: ${target}"
    return 1
  fi
  atomic_install "$candidate" "$target" 600
  rm -f "$candidate" 2>/dev/null || true
  return 0
}
# 与 atomic_json_update 类似, 但专供 CONFIG_FILE 的自愈/迁移函数使用:
# 在 JSON 语法校验之外额外跑一次 sing-box check, 两者都通过才落地。
# 避免"JSON 合法但 sing-box 不认"的配置被自愈逻辑悄悄写进生产文件,
# 导致下一次真正部署节点时才报错、却让人误以为是新节点的问题。
atomic_config_update_checked() {
  local filter=$1; shift
  local candidate
  candidate=$(mktemp "${CONFIG_FILE}.XXXXXX")
  if ! jq "$filter" "$@" "$CONFIG_FILE" > "$candidate" 2>>"$LOG_FILE"; then
    rm -f "$candidate"
    warn "jq 变更执行失败, 已保留原文件不变: ${CONFIG_FILE}"
    return 1
  fi
  if ! json_validate "$candidate"; then
    rm -f "$candidate"
    warn "jq 变更结果 JSON 校验失败, 已回滚: ${CONFIG_FILE}"
    return 1
  fi
  if ! sing-box check -c "$candidate" >>"$LOG_FILE" 2>&1; then
    rm -f "$candidate"
    warn "自动迁移生成的配置未通过 sing-box check 校验, 已保留原配置不变, 详见 ${LOG_FILE}。"
    return 1
  fi
  atomic_install "$candidate" "$CONFIG_FILE" 600
  rm -f "$candidate" 2>/dev/null || true
  return 0
}
# ---------------------------------------------------------------------------
# 网络栈探测: IPv4 Only / IPv6 Only / Dual Stack
# 优先通过路由表判断 (ip -4/-6 route), 再辅以出网连通性探测作为兜底/确认
# ---------------------------------------------------------------------------
has_ipv4_route() { ip -4 route show default 2>/dev/null | grep -q '.'; }
has_ipv6_route() { ip -6 route show default 2>/dev/null | grep -q '.'; }

check_ipv4_egress() {
  has_ipv4_route || return 1
  curl -4fsS --connect-timeout 2 --max-time 3 https://api.ipify.org >/dev/null 2>&1 && return 0
  curl -4fsS --connect-timeout 2 --max-time 3 https://www.cloudflare.com >/dev/null 2>&1 && return 0
  ping -4 -c 1 -W 2 1.1.1.1 >/dev/null 2>&1
}

check_ipv6_egress() {
  has_ipv6_route || return 1
  curl -6fsS --connect-timeout 2 --max-time 3 https://api64.ipify.org >/dev/null 2>&1 && return 0
  curl -6fsS --connect-timeout 2 --max-time 3 https://www.cloudflare.com >/dev/null 2>&1 && return 0
  ping -6 -c 1 -W 2 2606:4700:4700::1111 >/dev/null 2>&1
}

# 返回: v4only | v6only | dual | none
detect_network_stack() {
  local v4=0 v6=0
  check_ipv4_egress && v4=1
  check_ipv6_egress && v6=1
  if (( v4 == 1 && v6 == 1 )); then printf 'dual'
  elif (( v4 == 1 )); then printf 'v4only'
  elif (( v6 == 1 )); then printf 'v6only'
  else printf 'none'
  fi
}

detect_public_ip() {
  local ip endpoint
  for endpoint in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -4fsS --connect-timeout 3 --max-time 5 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
    valid_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }
  done
  hostname -I 2>/dev/null | awk '{print $1}'
}

detect_public_ipv6() {
  local ip endpoint
  for endpoint in https://api64.ipify.org https://ifconfig.co/ip; do
    ip=$(curl -6fsS --connect-timeout 3 --max-time 5 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
    valid_ipv6 "$ip" && { printf '%s' "$ip"; return 0; }
  done
  return 0
}

readonly IP_CACHE_FILE="${STATE_DIR}/ip_cache"

# 缓存公网 IPv4/IPv6, 300 秒内复用, 避免菜单每次重绘都发起网络请求
get_cached_public_ips() {
  net_snapshot
  printf '%s|%s' "$NET_V4" "$NET_V6"
}

format_host_uri() {
  local host=$1
  if [[ $host == *:* && $host != \[*\] ]]; then
    printf '[%s]' "$host"
  else
    printf '%s' "$host"
  fi
}

get_server_flag() {
  local country
  # 增加更多备用接口，最后兜底返回地球emoji
  country=$(curl -4fsS --connect-timeout 3 --max-time 5 "https://ipapi.co/country/" 2>/dev/null | tr -d '[:space:]') \
  || country=$(curl -4fsS --connect-timeout 3 --max-time 5 "https://api.country.is/" 2>/dev/null | jq -r '.country // empty' 2>/dev/null) \
  || country=$(curl -4fsS --connect-timeout 3 --max-time 5 "https://ipinfo.io/country" 2>/dev/null | tr -d '[:space:]') \
  || country=$(curl -4fsS --connect-timeout 3 --max-time 5 "https://ip.sb/geoip" 2>/dev/null | jq -r '.country_code // empty' 2>/dev/null) \
  || country=""

  if [[ $country =~ ^[A-Za-z]{2}$ ]]; then
    python3 -c "c='$country'.upper();print(''.join(chr(0x1F1E6+ord(x)-65) for x in c))"
  else
    printf "🌐"
  fi
}

# sing-box outbound 层的 IP 版本策略字段几经变迁:
#   - 1.11 之前: 出站字段 domain_strategy (prefer_ipv4/prefer_ipv6/ipv4_only/ipv6_only)
#   - 1.12 起: domain_strategy 标记为废弃, 替换为 domain_resolver (引用 dns.servers 中的
#     一个 server tag, 并可选带 strategy), network_strategy 是完全不同的字段
#     (仅用于 Android/Apple 图形客户端的多网络接口选路, 与 IPv4/IPv6 偏好无关)
#   - 1.14 起: domain_strategy 若未设置环境变量 ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS
#     会直接校验失败
# 因此本脚本统一采用 domain_resolver + 一个内置 DNS server 的现代方案, 不再探测/使用
# network_strategy 或 domain_strategy 字段。
readonly SB_DNS_RESOLVER_TAG="dns-direct"

ensure_dns_resolver() {
  if jq -e --arg tag "$SB_DNS_RESOLVER_TAG" \
      '(.dns.servers // []) | any(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
    return 0
  fi
  atomic_json_update "$CONFIG_FILE" '
    .dns = ((.dns // {}) | .servers = ((.servers // []) + [{type:"udp", tag:$tag, server:"1.1.1.1"}]))
  ' --arg tag "$SB_DNS_RESOLVER_TAG" || true
}

ensure_route_default_resolver() {
  if jq -e --arg tag "$SB_DNS_RESOLVER_TAG" \
      '.route.default_domain_resolver == $tag' "$CONFIG_FILE" >/dev/null 2>&1; then
    return 0
  fi
  atomic_json_update "$CONFIG_FILE" '
    .route = ((.route // {}) | .rules = (.rules // []) | .final = (.final // "direct")
              | .default_domain_resolver = $tag)
  ' --arg tag "$SB_DNS_RESOLVER_TAG" || true
}

ensure_direct_outbounds() {
  local candidate
  if jq -e --arg tag "$SB_DNS_RESOLVER_TAG" '
      (.outbounds // []) as $o |
      ($o | any(.tag=="direct")) and
      ($o | any(.tag=="direct-v4" and .domain_resolver.server==$tag)) and
      ($o | any(.tag=="direct-v6" and .domain_resolver.server==$tag)) and
      ($o | any(.tag=="direct-dual" and .domain_resolver.server==$tag))
    ' "$CONFIG_FILE" >/dev/null 2>&1; then
    return 0
  fi
  candidate=$(mktemp)
  jq --arg tag "$SB_DNS_RESOLVER_TAG" '
    .outbounds = (.outbounds // []) |
    (if (.outbounds | any(.tag=="direct")) then . else .outbounds += [{type:"direct", tag:"direct"}] end) |
    (if (.outbounds | any(.tag=="direct-v4")) then . else
      .outbounds += [{type:"direct", tag:"direct-v4", domain_resolver:{server:$tag, strategy:"ipv4_only"}}] end) |
    (if (.outbounds | any(.tag=="direct-v6")) then . else
      .outbounds += [{type:"direct", tag:"direct-v6", domain_resolver:{server:$tag, strategy:"ipv6_only"}}] end) |
    (if (.outbounds | any(.tag=="direct-dual")) then . else
      .outbounds += [{type:"direct", tag:"direct-dual", domain_resolver:{server:$tag, strategy:"prefer_ipv6"}}] end)
  ' "$CONFIG_FILE" > "$candidate"
  if json_validate "$candidate"; then
    atomic_install "$candidate" "$CONFIG_FILE" 600
  else
    warn "自动补齐基础出站失败, 请运行 'sb diag' 或检查 ${CONFIG_FILE} 是否损坏。"
  fi
  rm -f "$candidate"
}

# create_base_config() 只在 config.json 完全不存在时才会写入 route.default_domain_resolver,
# 对于早于该字段被引入之前就已生成的旧配置文件 (或手动编辑过的配置) 不会自动补上,
# 导致 sing-box 1.12+ 在校验时报 "missing route.default_domain_resolver ... deprecated" 并 FATAL。
# 这里单独做一次幂等自愈: 已存在则跳过, 缺失则补上, 不影响其余 route 字段。
ensure_route_default_resolver() {
  if jq -e --arg tag "$SB_DNS_RESOLVER_TAG" \
      '.route.default_domain_resolver == $tag' "$CONFIG_FILE" >/dev/null 2>&1; then
    return 0
  fi
  atomic_config_update_checked '
    .route = ((.route // {}) | .rules = (.rules // []) | .final = (.final // "direct")
              | .default_domain_resolver = $tag)
  ' --arg tag "$SB_DNS_RESOLVER_TAG" || true
}

# 同理: direct / direct-v4 / direct-v6 / direct-dual 四个基础出站也可能在老配置里缺失
# (例如从更早版本的脚本升级过来), mode_outbound_tag() 生成的 inbound 路由规则会引用
# 这些 tag, 缺失时 sing-box check 会直接报 "outbound not found"。这里按 tag 逐个补齐,
# 已存在的 tag 不会被覆盖或重复添加。
ensure_direct_outbounds() {
  local candidate
  if jq -e --arg tag "$SB_DNS_RESOLVER_TAG" '
      (.outbounds // []) as $o |
      ($o | any(.tag=="direct")) and
      ($o | any(.tag=="direct-v4" and .domain_resolver.server==$tag)) and
      ($o | any(.tag=="direct-v6" and .domain_resolver.server==$tag)) and
      ($o | any(.tag=="direct-dual" and .domain_resolver.server==$tag))
    ' "$CONFIG_FILE" >/dev/null 2>&1; then
    return 0
  fi
  candidate=$(mktemp)
  jq --arg tag "$SB_DNS_RESOLVER_TAG" '
    .outbounds = (.outbounds // []) |
    (if (.outbounds | any(.tag=="direct")) then . else .outbounds += [{type:"direct", tag:"direct"}] end) |
    (if (.outbounds | any(.tag=="direct-v4")) then . else
      .outbounds += [{type:"direct", tag:"direct-v4", domain_resolver:{server:$tag, strategy:"ipv4_only"}}] end) |
    (if (.outbounds | any(.tag=="direct-v6")) then . else
      .outbounds += [{type:"direct", tag:"direct-v6", domain_resolver:{server:$tag, strategy:"ipv6_only"}}] end) |
    (if (.outbounds | any(.tag=="direct-dual")) then . else
      .outbounds += [{type:"direct", tag:"direct-dual", domain_resolver:{server:$tag, strategy:"prefer_ipv6"}}] end)
  ' "$CONFIG_FILE" > "$candidate"
  if json_validate "$candidate" && sing-box check -c "$candidate" >>"$LOG_FILE" 2>&1; then
    atomic_install "$candidate" "$CONFIG_FILE" 600
  else
    warn "自动补齐基础出站失败 (JSON 或 sing-box check 未通过), 请运行 'sb diag' 或检查 ${CONFIG_FILE} 是否损坏, 详见 ${LOG_FILE}。"
  fi
  rm -f "$candidate"
}

ask_node_network_mode() {
  local stack choice
  stack=$(detect_network_stack)
  printf "\n当前服务器网络栈: %s\n" "$stack" >&2
  printf "选择节点接入与出站网络模式:\n" >&2
  printf "  1) Dual 双栈节点 (监听 ::, 出站优先 IPv6 并自动回退 IPv4)\n" >&2
  printf "  2) IPv4 专用节点 (监听 0.0.0.0, 出站强制仅使用 IPv4)\n" >&2
  printf "  3) IPv6 严格节点 (监听 ::, 出站强制仅使用 IPv6, 不回退 IPv4)\n" >&2
  read -e -r -i 1 -p "请选择: " choice || die "输入已取消。"
  choice=${choice:-1}
  case "$choice" in
    2)
      check_ipv4_egress || die "系统检测到 IPv4 外网不可用, 无法部署 IPv4 专用节点。"
      printf 'v4' ;;
    3)
      check_ipv6_egress || die "系统检测到 IPv6 外网不可用, 无法部署 IPv6 节点。"
      printf 'v6' ;;
    *)
      printf 'dual' ;;
  esac
}

ask_node_server() {
  local mode=$1 default val
  case "$mode" in
    v4)
      default=$(detect_public_ip)
      read -e -r -i "$default" -p "客户端连接 IPv4 地址: " val || die "输入已取消。"
      valid_ipv4 "$val" || valid_hostname "$val" || die "必须填写有效的 IPv4 地址或域名。"
      ;;
    v6)
      default=$(detect_public_ipv6)
      read -e -r -i "$default" -p "客户端连接 IPv6 地址: " val || die "输入已取消。"
      valid_ipv6 "$val" || valid_hostname "$val" || die "必须填写有效的 IPv6 地址或域名。"
      ;;
    *)
      default=$(detect_public_ip)
      [[ -z $default ]] && default=$(detect_public_ipv6)
      read -e -r -i "$default" -p "客户端连接双栈地址 (推荐填已解析 A 和 AAAA 的域名): " val || die "输入已取消。"
      [[ -n $val ]] || die "必须填写有效的连接域名或 IP。"
      ;;
  esac
  printf '%s' "$val"
}

# 网络模式 -> (监听地址, 出站 tag) 映射, 消除各部署函数中的重复 case 块
mode_listen_addr() {
  case "$1" in
    v4) printf '0.0.0.0' ;;
    v6) printf '::' ;;
    *)  printf '::' ;;
  esac
}
mode_outbound_tag() {
  case "$1" in
    v4) printf 'direct-v4' ;;
    v6) printf 'direct-v6' ;;
    *)  printf 'direct-dual' ;;
  esac
}

# ---------------------------------------------------------------------------
# 安装与基础路由配置
# ---------------------------------------------------------------------------
_install_prerequisites_raw() {
  require_apt
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl jq openssl iproute2 gnupg qrencode dnsutils python3 >/dev/null
}
install_prerequisites() {
  ui_run "安装依赖包 (apt)" _install_prerequisites_raw
}

install_sing_box() {
  require_root; require_systemd; install_prerequisites
  info "配置 sing-box 官方 APT 软件源"
  install -d -m 755 /etc/apt/keyrings
  ui_run "获取 sing-box 软件源密钥" curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
  chmod a+r /etc/apt/keyrings/sagernet.asc
  tee /etc/apt/sources.list.d/sagernet.sources >/dev/null <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
  ui_run "安装 sing-box (apt)" _apt_update_install sing-box
  ensure_base_routing
  systemctl enable sing-box >/dev/null 2>&1 || true
  install_manager
  ok "已安装 $(sing-box version | head -n 1)"
}

install_manager() {
  local source_path=${BASH_SOURCE[0]:-}
  if [[ -n $source_path && -r $source_path && $source_path != "/dev/stdin" && $source_path != /proc/self/fd/* ]]; then
    install -D -m 700 "$source_path" "$MANAGER_PATH"
  else
    # 通过 curl ... | sudo bash 这类管道方式运行时, 脚本无法读取自身文件路径,
    # 改为从远程仓库下载一份完整脚本安装为快捷命令。
    info "检测到脚本通过管道方式运行 (例如 curl | bash), 正在从远程仓库下载完整脚本以安装 sb 快捷命令..."
    local tmp
    tmp=$(mktemp)
    if curl -fL --proto '=https' --tlsv1.2 "$SCRIPT_UPDATE_URL" -o "$tmp" 2>/dev/null && bash -n "$tmp" 2>/dev/null; then
      install -D -m 700 "$tmp" "$MANAGER_PATH"
    else
      rm -f "$tmp"
      warn "无法下载远程脚本副本, 跳过创建快捷命令。请先将脚本保存为文件后以 'sudo bash sing-box-vps.sh install' 方式运行, 即可自动创建 sb 命令。"
      return 0
    fi
    rm -f "$tmp"
  fi
  tee "$SHORTCUT_PATH" >/dev/null <<EOF
#!/usr/bin/env bash
exec ${MANAGER_PATH} "\$@"
EOF
  chmod 755 "$SHORTCUT_PATH"
  ok "已创建快捷命令: sb"
}

version_ge() {
  # version_ge <have> <need> : 语义化版本比较, 返回 0 表示 have >= need
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

check_sing_box_min_version() {
  command -v sing-box >/dev/null 2>&1 || return 1
  local ver
  ver=$(sing-box version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  [[ -n $ver ]] || return 1
  if ! version_ge "$ver" "$SB_MIN_VERSION"; then
    warn "检测到 sing-box 版本 ${ver} 低于建议最低版本 ${SB_MIN_VERSION}, 部分特性 (如 Reality/Hysteria2/TUIC) 可能不受支持, 建议运行 'sb upgrade'。"
    return 1
  fi
  return 0
}

ensure_installed() {
  command -v sing-box >/dev/null 2>&1 || install_sing_box
  command -v jq >/dev/null 2>&1 || install_prerequisites
  check_sing_box_min_version || true
  ensure_base_routing
}

create_base_config() {
  [[ -f $CONFIG_FILE ]] && return 0
  ensure_dirs
  info "初始化包含 IPv4/IPv6 出站策略的基础配置"
  local candidate
  candidate=$(mktemp)
    jq -n '{
    log: { level: "info", timestamp: true },
    dns: {
      servers: [
        { type: "udp", tag: "dns-direct", server: "1.1.1.1" }
      ]
    },
    inbounds: [],
    outbounds: [
      { type: "direct", tag: "direct" },
      { type: "direct", tag: "direct-v4",
        domain_resolver: { server: "dns-direct", strategy: "ipv4_only" } },
      { type: "direct", tag: "direct-v6",
        domain_resolver: { server: "dns-direct", strategy: "ipv6_only" } },
      { type: "direct", tag: "direct-dual",
        domain_resolver: { server: "dns-direct", strategy: "prefer_ipv6" } }
    ],
    route: { rules: [], final: "direct", default_domain_resolver: "dns-direct" }
  }' > "$candidate"
  json_validate "$candidate" || die "内部错误: 基础配置生成失败。"
  atomic_install "$candidate" "$CONFIG_FILE" 600
  rm -f "$candidate"
}

ensure_base_routing() {
  ensure_dirs
  create_base_config
  ensure_dns_resolver
  ensure_route_default_resolver
  ensure_direct_outbounds
}
# ---------------------------------------------------------------------------
# 配置备份
# ---------------------------------------------------------------------------
backup_config() {
  [[ -f $CONFIG_FILE ]] || return 0
  local stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  install -m 600 "$CONFIG_FILE" "${BACKUP_DIR}/config-${stamp}.json"
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.json' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | awk 'NR>15 {print $2}' | xargs -r rm -f
}

# apply_candidate <candidate_file>
# 校验通过 -> 备份现有生产配置 -> 原子替换 -> 重启服务
# 校验/重启失败 -> 自动回滚到替换前的备份, 绝不让生产服务停留在坏配置上
apply_candidate() {
  local candidate=$1
  json_validate "$candidate" || die "候选配置 JSON 语法非法, 已拒绝写入。"
  if ! sing-box check -c "$candidate" 2>&1 | tee -a "$LOG_FILE"; then
    die "候选配置未通过 sing-box check 校验, 已拒绝写入, 详见 ${LOG_FILE}。"
  fi
  backup_config
  local prev_backup
  prev_backup=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.json' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -n1 | cut -d' ' -f2-)

  atomic_install "$candidate" "$CONFIG_FILE" 600
  

  systemctl enable --now sing-box >/dev/null 2>&1 || true
  if ! systemctl restart sing-box; then
    warn "sing-box 重启失败, 正在自动回滚到上一份可用配置..."
    if [[ -n $prev_backup && -f $prev_backup ]]; then
      atomic_install "$prev_backup" "$CONFIG_FILE" 600
      systemctl restart sing-box || warn "回滚后仍未能启动 sing-box, 请运行 'sb logs' 排查。"
      die "部署失败, 已回滚至变更前配置。"
    else
      die "部署失败且无可用备份用于回滚, 请手动检查 ${CONFIG_FILE}。"
    fi
  fi
  if ! systemctl is-active --quiet sing-box; then
    warn "sing-box 服务未处于运行状态, 正在自动回滚..."
    if [[ -n $prev_backup && -f $prev_backup ]]; then
      atomic_install "$prev_backup" "$CONFIG_FILE" 600
      systemctl restart sing-box || true
      die "部署失败, 已回滚至变更前配置。"
    else
      die "部署失败且无可用备份用于回滚, 请手动检查 ${CONFIG_FILE}。"
    fi
  fi
}

port_is_used_in_config() {
  local port=$1
  jq -e --argjson port "$port" '.inbounds[]? | select(.listen_port == $port)' "$CONFIG_FILE" >/dev/null 2>&1
}

ensure_port_available() {
  local port=$1
  if port_is_used_in_config "$port"; then
    die "端口 $port 已在 sing-box 配置中被占用。"
  fi
  if command -v ss >/dev/null 2>&1 && ss -tulnH "sport = :$port" 2>/dev/null | grep -q .; then
    die "端口 $port 已被宿主机其他进程占用, 请更换端口。"
  fi
}

check_and_handle_existing_tag() {
  local tag=$1
  if jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
    warn "检测到节点标识 [${tag}] 已存在!"
    if confirm "该节点已存在, 是否覆盖?" N; then
      local candidate
      candidate=$(mktemp)
      jq --arg tag "$tag" '
        ([.inbounds[]? | select(.tag == $tag) | .detour // empty]) as $detours |
        .inbounds |= map(select(.tag != $tag and ((.tag | IN($detours[])) | not))) |
        if .route.rules then .route.rules |= map(select((.inbound // []) | index($tag) | not)) else . end
      ' "$CONFIG_FILE" > "$candidate"
      apply_candidate "$candidate"
      rm -f "$candidate"
      atomic_json_update "$STATE_FILE" '.connections |= map(select(.tag != $tag))' --arg tag "$tag"
      ok "已自动清理旧节点 [${tag}] 及其关联入站, 开始重新写入..."
      return 0
    fi
    warn "操作已取消。"
    return 1
  fi
  return 0
}

apply_inbound_with_route() {
  local inbound_json=$1 tag=$2 outbound_tag=$3 candidate
  candidate=$(mktemp)
  jq --argjson inbound "$inbound_json" --arg tag "$tag" --arg outbound "$outbound_tag" '
    .inbounds += [$inbound] |
    .route.rules += [{"inbound": [$tag], "action": "route", "outbound": $outbound}]
  ' "$CONFIG_FILE" > "$candidate"
  PENDING_TAG=$tag
  apply_candidate "$candidate"
  rm -f "$candidate"
}

# ---------------------------------------------------------------------------
# 防火墙
# ---------------------------------------------------------------------------
persist_iptables_rules() {
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
    return 0
  fi
  if [[ -d /etc/iptables ]]; then
    command -v iptables-save  >/dev/null 2>&1 && iptables-save  > /etc/iptables/rules.v4 2>/dev/null
    command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
    return 0
  fi
  # 尝试安装 iptables-persistent 以便规则重启后仍然生效; 静默失败不影响本次放行
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent >/dev/null 2>&1 || true
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
  fi
}

readonly NFT_TABLE="sing_box_vps"

ensure_nft_table() {
  command -v nft >/dev/null 2>&1 || return 1
  nft list table inet "$NFT_TABLE" >/dev/null 2>&1 && return 0
  nft add table inet "$NFT_TABLE" 2>/dev/null || return 1
  nft add chain inet "$NFT_TABLE" input '{ type filter hook input priority 0; policy accept; }' 2>/dev/null || return 1
  return 0
}

persist_nft_rules() {
  command -v nft >/dev/null 2>&1 || return 0
  if [[ -d /etc/nftables.d ]]; then
    nft list table inet "$NFT_TABLE" > "/etc/nftables.d/${NFT_TABLE}.nft" 2>/dev/null || true
  elif [[ -f /etc/nftables.conf ]]; then
    info "检测到 nftables, 规则已生效但未持久化; 如需重启后仍生效, 请自行将 'nft list table inet ${NFT_TABLE}' 的输出加入 /etc/nftables.conf。"
  fi
}

open_firewall_port() {
  local port=$1 protocol=${2:-tcp} handled=0
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "${port}/${protocol}" >/dev/null 2>&1
    ok "已通过 UFW 放行 ${port}/${protocol}"
    return 0
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${port}/${protocol}" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    ok "已通过 firewalld 放行 ${port}/${protocol}"
    return 0
  fi  # 未检测到 UFW/firewalld 时, 不少云厂商精简镜像仍带有独立生效的 iptables/ip6tables
  # 默认规则 (仅监听端口不代表内核放行), 这里直接对 IPv4 与 IPv6 分别插入放行规则,
  # 这正是很多 "端口监听正常但连不通" 场景的根因, 必须两条链都处理。
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p "$protocol" --dport "$port" -j ACCEPT
    handled=1
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -C INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null \
      || ip6tables -I INPUT -p "$protocol" --dport "$port" -j ACCEPT
    handled=1
  fi
  if (( handled == 1 )); then
    persist_iptables_rules
    ok "已在 iptables/ip6tables 放行 ${port}/${protocol} (若使用云厂商安全组, 仍需在控制台分别放行 IPv4 与 IPv6 规则)。"
    return 0
  fi
  # 纯 nftables 系统 (无 iptables-nft 兼容层, command -v iptables 探测不到) 的兜底路径
  if command -v nft >/dev/null 2>&1 && ensure_nft_table; then
    nft add rule inet "$NFT_TABLE" input "${protocol}" dport "${port}" accept 2>/dev/null
    persist_nft_rules
    ok "已通过 nftables 放行 ${port}/${protocol} (若使用云厂商安全组, 仍需在控制台分别放行 IPv4 与 IPv6 规则)。"
    return 0
  fi
  warn "未检测到 UFW/firewalld/iptables/nftables 中任何一种可用的防火墙管理工具; 请在云厂商安全组放行 ${port}/${protocol} (注意 IPv4 与 IPv6 需分别放行)。"
}

close_firewall_port() {
  # 节点删除时对称撤销放行规则: UFW/firewalld/iptables/nftables 四种情况都要处理,
  # 否则删除节点后端口仍然对外开放。
  local port=$1 protocol=${2:-tcp}
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw delete allow "${port}/${protocol}" >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --remove-port="${port}/${protocol}" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  if command -v iptables >/dev/null 2>&1; then
    while iptables -C INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null; do
      iptables -D INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null || break
    done
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    while ip6tables -C INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null; do
      ip6tables -D INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null || break
    done
  fi
  if command -v nft >/dev/null 2>&1 && nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
    local handle
    while handle=$(nft -a list chain inet "$NFT_TABLE" input 2>/dev/null \
        | awk -v p="$port" -v pr="$protocol" '$0 ~ pr" dport "p" accept" {print $NF; exit}'); do
      [[ -n $handle ]] || break
      nft delete rule inet "$NFT_TABLE" input handle "$handle" 2>/dev/null || break
    done
    persist_nft_rules
  fi
  persist_iptables_rules
}

# ---------------------------------------------------------------------------
# 密钥 / UUID / 随机路径生成
# ---------------------------------------------------------------------------
random_ss_key()  { sing-box generate rand --base64 16 2>/dev/null || openssl rand -base64 16 | tr -d '\n'; }
random_token()   { openssl rand -hex 24; }
random_path()    { printf '/%s' "$(openssl rand -hex 12)"; }
new_uuid()       { sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid; }

generate_reality_keypair() {
  local keypair private_key public_key
  keypair=$(sing-box generate reality-keypair)
  private_key=$(awk -F': ' '/PrivateKey/ {print $2}' <<<"$keypair")
  public_key=$(awk -F': ' '/PublicKey/ {print $2}' <<<"$keypair")
  [[ -n $private_key && -n $public_key ]] || die "无法生成 Reality 密钥对。"
  printf '%s|%s' "$private_key" "$public_key"
}
# 询问节点显示名称, 返回 URL 编码后的结果 (可直接拼进 URI 的 # 后面)
ask_node_name() {
  local default=$1 name
  while true; do
    read -e -r -i "$default" -p "节点名称: " name || die "输入已取消。"
    name=${name:-$default}
    if (( ${#name} <= 64 )); then
      printf '%s' "$name" | jq -sRr '@uri'
      return 0
    fi
    warn "节点名称过长 (最多 64 字符), 请重新输入。"
  done
}
# Reality 握手域名: 内置推荐列表 + 自定义, 并做连通性/TLS1.3 粗校验
ask_reality_handshake_domain() {
  local i choice domain
  printf "\n选择 Reality 握手伪装域名 (需支持 TLS 1.3, 建议选用大型 CDN/云厂商域名):\n" >&2
  for i in "${!REALITY_PRESET_DOMAINS[@]}"; do
    printf "  %d) %s\n" "$((i+1))" "${REALITY_PRESET_DOMAINS[$i]}" >&2
  done
  printf "  0) 自定义输入\n" >&2
  read -e -r -i 1 -p "请选择: " choice || die "输入已取消。"
  choice=${choice:-1}
  if [[ $choice == 0 ]]; then
    domain=$(ask_required "请输入握手域名")
  elif [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#REALITY_PRESET_DOMAINS[@]} )); then
    domain=${REALITY_PRESET_DOMAINS[$((choice-1))]}
  else
    domain=${REALITY_PRESET_DOMAINS[0]}
  fi
  valid_hostname "$domain" || die "握手域名格式不正确。"
  if command -v openssl >/dev/null 2>&1; then
    if ! timeout 4 openssl s_client -connect "${domain}:443" -tls1_3 -servername "$domain" </dev/null >/dev/null 2>&1; then
      warn "无法确认 ${domain} 支持 TLS 1.3 握手 (可能是网络限制), 请自行确保可用性。"
    fi
  fi
  printf '%s' "$domain"
}

# ---------------------------------------------------------------------------
# TLS 证书管理 (Certbot)
# ---------------------------------------------------------------------------
tls_json() {
  local domain=$1 cert=$2 key=$3
  jq -n --arg domain "$domain" --arg cert "$cert" --arg key "$key" \
    '{enabled:true,server_name:$domain,alpn:["h2","http/1.1"],min_version:"1.2",certificate_path:$cert,key_path:$key}'
}

check_port_80() {
  if command -v ss >/dev/null 2>&1 && ss -tulnH "sport = :80" 2>/dev/null | grep -q .; then
    warn "检测到 80 端口已被其他服务占用!"
    ss -tlpn "sport = :80" 2>/dev/null || true
    confirm "是否继续? (如果占用者为 Web 服务, Certbot 申请可能失败)" N || die "已取消申请, 请释放 80 端口或使用已有证书。"
  fi
}

grant_cert_access() {
  id sing-box >/dev/null 2>&1 || return 0
  command -v setfacl >/dev/null 2>&1 || apt-get install -y -qq acl
  setfacl -R -m u:sing-box:rX /etc/letsencrypt/live /etc/letsencrypt/archive 2>/dev/null || true
  return 0
}

install_certbot_hook() {
  install -d -m 755 "$(dirname "$CERT_HOOK")"
    tee "$CERT_HOOK" >/dev/null <<'EOF'
#!/usr/bin/env bash
if command -v setfacl >/dev/null 2>&1 && id sing-box >/dev/null 2>&1; then
  setfacl -R -m u:sing-box:rX /etc/letsencrypt/live /etc/letsencrypt/archive || true
fi
systemctl try-restart sing-box.service
EOF
  chmod 755 "$CERT_HOOK"
}

obtain_tls_paths() {
  local domain=$1 cert key choice
  cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
  key="/etc/letsencrypt/live/${domain}/privkey.pem"
  if [[ -r $cert && -r $key ]]; then
    printf '%s|%s' "$cert" "$key"
    return 0
  fi
  printf "\nTLS 证书获取方式:\n  1) 使用 Certbot 自动签发 Let's Encrypt (需域名解析到本机且 80 端口开放)\n  2) 使用已有 PEM 证书路径\n" >&2
  read -e -r -i 1 -p '选择: ' choice
  choice=${choice:-1}
  case $choice in
    1)
      check_port_80
      ui_run "安装 certbot (apt)" _apt_update_install certbot
      open_firewall_port 80 tcp >&2
      ui_run "签发 ${domain} 证书 (certbot)" certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$domain"
      install_certbot_hook
      grant_cert_access >&2
      enable_certbot_autorenew >&2
      [[ -r $cert && -r $key ]] || die "证书文件生成失败。"
      ;;
    2)
      cert=$(ask_required "证书链 fullchain PEM 绝对路径")
      key=$(ask_required "私钥 privkey PEM 绝对路径")
      [[ -r $cert && -r $key ]] || die "证书或私钥文件不可读。"
      ;;
    *) die "无效的选择。" ;;
  esac
  printf '%s|%s' "$cert" "$key"
}

enable_certbot_autorenew() {
  command -v certbot >/dev/null 2>&1 || return 0
  if systemctl list-timers --all 2>/dev/null | grep -q certbot; then
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  else
    # 部分发行版无内建 timer, 补一个每日随机时间的 cron
    local cronfile="/etc/cron.d/sing-box-vps-certbot"
    tee "$cronfile" >/dev/null <<'EOF'
SHELL=/bin/bash
17 3 * * * root certbot renew --quiet --deploy-hook "systemctl try-restart sing-box.service"
EOF
    chmod 644 "$cronfile"
  fi
  ok "已启用 Certbot 自动续期。"
}

show_certificate_expiry() {
  ensure_installed
  local cert_path end_date
  local -a certs=()
  mapfile -t certs < <(jq -r '.inbounds[]? | .tls.certificate_path? // empty' "$CONFIG_FILE" | sort -u)
  if (( ${#certs[@]} == 0 )); then
    warn "当前配置中没有使用本地证书文件的 TLS 入站。"
    return 0
  fi
  printf '\n证书到期时间统计:\n'
  for cert_path in "${certs[@]}"; do
    if [[ -r $cert_path ]]; then
      end_date=$(openssl x509 -enddate -noout -in "$cert_path" | cut -d= -f2-)
      printf -- '- %s\n  到期时间: %s\n' "$cert_path" "$end_date"
    else
      warn "证书文件不可读: $cert_path"
    fi
  done
}

renew_certificate_now() {
  require_cmd certbot
  local domain
  domain=$(ask_required "要立即续期/重新申请的域名")
  valid_hostname "$domain" || die "域名格式不正确。"
  check_port_80
  open_firewall_port 80 tcp
  certbot certonly --standalone --non-interactive --agree-tos --force-renewal \
    --register-unsafely-without-email -d "$domain"
  install_certbot_hook
  grant_cert_access
  systemctl try-restart sing-box || true
  ok "证书已重新签发: ${domain}"
}

cert_management_menu() {
  local choice
  while true; do
    title "证书管理"
    printf '  1) 查看证书到期时间\n'
    printf '  2) 立即续期 / 重新申请证书\n'
    printf '  3) 启用/检查 Certbot 自动续期\n'
    printf '  0) 返回主菜单\n'
    read -e -r -p '请选择: ' choice
    case $choice in
      1) show_certificate_expiry ;;
      2) renew_certificate_now ;;
      3) enable_certbot_autorenew ;;
      0) return 0 ;;
      *) warn "无效的编号选择。" ;;
    esac
  done
}
# ---------------------------------------------------------------------------
# 连接记录存取
# ---------------------------------------------------------------------------
save_connection() {
  local type=$1 tag=$2 host=$3 port=$4 uri=$5
  atomic_json_update "$STATE_FILE" \
    '.connections += [{type:$type, tag:$tag, host:$host, port:($port|tonumber), uri:$uri, created_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}]' \
    --arg type "$type" --arg tag "$tag" --arg host "$host" --arg port "$port" --arg uri "$uri" \
    || die "保存连接记录失败。"
}

# ---------------------------------------------------------------------------
# 二维码输出
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# 通用: 依据网络模式准备端口/监听/出站/tag 的前置流程
# deploy_prepare <label> <default_port> <tag_prefix> -> 通过全局变量返回
#   D_MODE D_LISTEN D_OUTBOUND D_PORT D_TAG D_HOST D_FORMATTED_HOST
# ---------------------------------------------------------------------------
declare -g D_MODE D_LISTEN D_OUTBOUND D_PORT D_TAG D_HOST D_FORMATTED_HOST

deploy_prepare_common() {
  local port_label=$1 default_port=$2 tag_prefix=$3 fixed_mode=${4:-}
  ensure_installed
  if [[ -n $fixed_mode ]]; then
    D_MODE=$fixed_mode
    case "$D_MODE" in
      v4) check_ipv4_egress || die "系统检测到 IPv4 外网不可用, 无法部署 IPv4 专用节点。" ;;
      v6) check_ipv6_egress || die "系统检测到 IPv6 外网不可用, 无法部署 IPv6 节点。" ;;
    esac
  else
    D_MODE=$(ask_node_network_mode)
  fi
  D_LISTEN=$(mode_listen_addr "$D_MODE")
  D_OUTBOUND=$(mode_outbound_tag "$D_MODE")
  D_PORT=$(ask_port "$port_label" "$default_port")
  D_TAG="${tag_prefix}-${D_MODE}-${D_PORT}"
  check_and_handle_existing_tag "$D_TAG" || return 1
  ensure_port_available "$D_PORT"
  D_HOST=$(ask_node_server "$D_MODE")
  D_FORMATTED_HOST=$(format_host_uri "$D_HOST")
  return 0
}

# 需要 TLS 域名(而非仅 Reality 握手伪装)的协议共用的域名+证书前置流程
deploy_prepare_tls_domain() {
  local default_port=$1 tag_prefix=$2
  D_MODE=$(ask_node_network_mode)
  D_LISTEN=$(mode_listen_addr "$D_MODE")
  D_OUTBOUND=$(mode_outbound_tag "$D_MODE")
  D_HOST=$(ask_hostname "TLS 绑定域名")
  D_FORMATTED_HOST=$(format_host_uri "$D_HOST")
  D_PORT=$(ask_port "监听端口" "$default_port")
  D_TAG="${tag_prefix}-${D_MODE}-${D_PORT}"
  check_and_handle_existing_tag "$D_TAG" || return 1
  ensure_port_available "$D_PORT"
  return 0
}

# ===========================================================================
# 协议部署函数
# ===========================================================================

deploy_vless_reality_unified() {
  local mode=${1:-}
  ensure_installed
  deploy_prepare_common "VLESS Reality 监听端口" 443 "reality" "$mode" || return 0

  local handshake keypair private_key public_key short_id uuid reality tls inbound uri flag
  handshake=$(ask_reality_handshake_domain)
  keypair=$(generate_reality_keypair)
  private_key=${keypair%%|*}; public_key=${keypair#*|}
  short_id=$(openssl rand -hex 4)
  uuid=$(new_uuid)

  reality=$(jq -n --arg handshake "$handshake" --arg private_key "$private_key" --arg short_id "$short_id" \
    '{enabled:true,handshake:{server:$handshake,server_port:443},private_key:$private_key,short_id:[$short_id]}')
  tls=$(jq -n --arg handshake "$handshake" --argjson reality "$reality" '{enabled:true,server_name:$handshake,reality:$reality}')
  inbound=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg uuid "$uuid" --argjson tls "$tls" \
    '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",uuid:$uuid,flow:"xtls-rprx-vision"}],tls:$tls}')
  local node_name; node_name=$(ask_node_name "Reality-${D_MODE}")
  flag=$(get_server_flag)
  apply_inbound_with_route "$inbound" "$D_TAG" "$D_OUTBOUND"  
  uri="vless://${uuid}@${D_FORMATTED_HOST}:${D_PORT}?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=${handshake}&fp=chrome&pbk=${public_key}&sid=${short_id}#${flag}%20${node_name}"
  save_connection "vless-reality-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" tcp
  ok "VLESS Reality (${D_MODE}) 已成功部署 (绑定出口: ${D_OUTBOUND})"
  print_result_block "VLESS Reality" "$uri" "$D_TAG"
}

deploy_vless_reality_grpc() {
  ensure_installed
  deploy_prepare_common "VLESS Reality gRPC 监听端口" 8443 "reality-grpc" || return 0

  local handshake keypair private_key public_key short_id uuid service_name reality tls inbound uri flag
  handshake=$(ask_reality_handshake_domain)
  service_name="grpc-$(openssl rand -hex 4)"
  keypair=$(generate_reality_keypair)
  private_key=${keypair%%|*}; public_key=${keypair#*|}
  short_id=$(openssl rand -hex 4)
  uuid=$(new_uuid)

  reality=$(jq -n --arg handshake "$handshake" --arg private_key "$private_key" --arg short_id "$short_id" \
    '{enabled:true,handshake:{server:$handshake,server_port:443},private_key:$private_key,short_id:[$short_id]}')
  tls=$(jq -n --arg handshake "$handshake" --argjson reality "$reality" '{enabled:true,server_name:$handshake,reality:$reality}')
  inbound=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg uuid "$uuid" --arg svc "$service_name" --argjson tls "$tls" \
    '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",uuid:$uuid}],tls:$tls,transport:{type:"grpc",service_name:$svc}}')
  local node_name; node_name=$(ask_node_name "Reality-gRPC-${D_MODE}")
  flag=$(get_server_flag)
  apply_inbound_with_route "$inbound" "$D_TAG" "$D_OUTBOUND"
  uri="vless://${uuid}@${D_FORMATTED_HOST}:${D_PORT}?encryption=none&security=reality&type=grpc&serviceName=${service_name}&mode=gun&sni=${handshake}&fp=chrome&pbk=${public_key}&sid=${short_id}#${flag}%20${node_name}"
  save_connection "vless-reality-grpc-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" tcp
  ok "VLESS Reality gRPC (${D_MODE}) 已部署"
  print_result_block "VLESS Reality gRPC" "$uri" "$D_TAG"
}

deploy_shadowtls_ss2022() {
  ensure_installed
  deploy_prepare_common "ShadowTLS 公网监听端口" 443 "st3" || return 0

  local handshake st_password ss_key tag_ss inbound_st inbound_ss candidate encoded_ss uri flag
  handshake=$(ask_reality_handshake_domain)
  tag_ss="ss-inner-${D_PORT}"
  st_password=$(random_token)
  ss_key=$(random_ss_key)

  inbound_st=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg pwd "$st_password" --arg hs "$handshake" --arg detour "$tag_ss" \
    '{type:"shadowtls",tag:$tag,listen:$listen,listen_port:$port,version:3,users:[{password:$pwd}],handshake:{server:$hs,server_port:443},strict_mode:true,detour:$detour}')
  inbound_ss=$(jq -n --arg tag "$tag_ss" --arg key "$ss_key" \
    '{type:"shadowsocks",tag:$tag,method:"2022-blake3-aes-128-gcm",password:$key}')

  candidate=$(mktemp)
  jq --argjson inb_st "$inbound_st" --argjson inb_ss "$inbound_ss" --arg tag "$D_TAG" --arg outbound "$D_OUTBOUND" '
    .inbounds += [$inb_st, $inb_ss] |
    .route.rules += [{"inbound": [$tag], "action": "route", "outbound": $outbound}]
  ' "$CONFIG_FILE" > "$candidate"
  local node_name; node_name=$(ask_node_name "ShadowTLS-SS2022-${D_MODE}")
  flag=$(get_server_flag)
  PENDING_TAG="$D_TAG"
  apply_candidate "$candidate"  
  rm -f "$candidate"
  encoded_ss=$(printf '%s' "2022-blake3-aes-128-gcm:${ss_key}" | base64 -w 0)
  uri="ss://${encoded_ss}@${D_FORMATTED_HOST}:${D_PORT}?plugin=shadow-tls%3Bhost%3D${handshake}%3Bpassword%3D${st_password}%3Bversion%3D3#${flag}%20${node_name}"
  save_connection "shadowtls-v3-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" tcp
  ok "ShadowTLS v3 + SS2022 (${D_MODE}) 已部署"
  print_result_block "ShadowTLS v3 + SS2022" "$uri" "$D_TAG"
}

deploy_shadowsocks() {
  ensure_installed
  deploy_prepare_common "Shadowsocks 2022 监听端口" 8443 "ss2022" || return 0

  local key inbound encoded uri flag
  key=$(random_ss_key)
  inbound=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg key "$key" \
    '{type:"shadowsocks",tag:$tag,listen:$listen,listen_port:$port,method:"2022-blake3-aes-128-gcm",password:$key,multiplex:{enabled:true}}')
  local node_name; node_name=$(ask_node_name "SS2022-${D_MODE}")
  flag=$(get_server_flag)
  apply_inbound_with_route "$inbound" "$D_TAG" "$D_OUTBOUND"
  encoded=$(printf '%s' "2022-blake3-aes-128-gcm:${key}" | base64 -w 0)  
  uri="ss://${encoded}@${D_FORMATTED_HOST}:${D_PORT}#${flag}%20${node_name}"
  save_connection "shadowsocks-2022-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" tcp
  open_firewall_port "$D_PORT" udp
  ok "Shadowsocks 2022 (${D_MODE}) 已部署"
  print_result_block "Shadowsocks 2022" "$uri" "$D_TAG"
}

deploy_trojan() {
  ensure_installed
  deploy_prepare_tls_domain 443 "trojan" || return 0

  local paths cert key password tls inbound uri flag
  paths=$(obtain_tls_paths "$D_HOST")
  cert=${paths%%|*}; key=${paths#*|}
  password=$(random_token)

  tls=$(tls_json "$D_HOST" "$cert" "$key")
  inbound=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg password "$password" --argjson tls "$tls" \
    '{type:"trojan",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",password:$password}],tls:$tls}')
  local node_name; node_name=$(ask_node_name "Trojan-${D_MODE}")
  flag=$(get_server_flag)
  apply_inbound_with_route "$inbound" "$D_TAG" "$D_OUTBOUND"
  uri="trojan://${password}@${D_FORMATTED_HOST}:${D_PORT}?security=tls&sni=${D_HOST}&type=tcp#${flag}%20${node_name}"
  save_connection "trojan-tls-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" tcp
  ok "Trojan TLS (${D_MODE}) 已部署"
  print_result_block "Trojan TLS" "$uri" "$D_TAG"
}

deploy_vless() {
  ensure_installed
  deploy_prepare_tls_domain 8443 "vless" || return 0

  local paths cert key uuid tls inbound uri flag
  paths=$(obtain_tls_paths "$D_HOST")
  cert=${paths%%|*}; key=${paths#*|}
  uuid=$(new_uuid)

  tls=$(tls_json "$D_HOST" "$cert" "$key")
  inbound=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg uuid "$uuid" --argjson tls "$tls" \
    '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",uuid:$uuid}],tls:$tls}')
  local node_name; node_name=$(ask_node_name "VLESS-${D_MODE}")
  flag=$(get_server_flag)
  apply_inbound_with_route "$inbound" "$D_TAG" "$D_OUTBOUND"
  uri="vless://${uuid}@${D_FORMATTED_HOST}:${D_PORT}?encryption=none&security=tls&type=tcp&sni=${D_HOST}#${flag}%20${node_name}"
  save_connection "vless-tls-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" tcp
  ok "VLESS TLS (${D_MODE}) 已部署"
  print_result_block "VLESS TLS" "$uri" "$D_TAG"
}

deploy_hysteria2() {
  ensure_installed
  deploy_prepare_tls_domain 8443 "hy2" || return 0

  local paths cert key password obfs_password tls inbound uri flag
  paths=$(obtain_tls_paths "$D_HOST")
  cert=${paths%%|*}; key=${paths#*|}
  password=$(random_token)
  obfs_password=$(random_token)

  tls=$(tls_json "$D_HOST" "$cert" "$key")
  inbound=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg password "$password" --arg obfs "$obfs_password" --argjson tls "$tls" \
    '{type:"hysteria2",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",password:$password}],obfs:{type:"salamander",password:$obfs},tls:$tls}')
  local node_name; node_name=$(ask_node_name "Hysteria2-${D_MODE}")
  flag=$(get_server_flag)
  apply_inbound_with_route "$inbound" "$D_TAG" "$D_OUTBOUND"
  uri="hysteria2://${password}@${D_FORMATTED_HOST}:${D_PORT}?sni=${D_HOST}&obfs=salamander&obfs-password=${obfs_password}#${flag}%20${node_name}"
  save_connection "hysteria2-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" udp
  ok "Hysteria2 (${D_MODE}) 已部署"
  print_result_block "Hysteria2" "$uri" "$D_TAG"
}

deploy_tuic() {
  ensure_installed
  deploy_prepare_tls_domain 8443 "tuic" || return 0

  local paths cert key uuid password tls inbound uri flag
  paths=$(obtain_tls_paths "$D_HOST")
  cert=${paths%%|*}; key=${paths#*|}
  uuid=$(new_uuid)
  password=$(random_token)

  tls=$(tls_json "$D_HOST" "$cert" "$key")
  inbound=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg uuid "$uuid" --arg password "$password" --argjson tls "$tls" \
    '{type:"tuic",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",uuid:$uuid,password:$password}],congestion_control:"bbr",zero_rtt_handshake:false,tls:$tls}')
  local node_name; node_name=$(ask_node_name "TUIC-${D_MODE}")
  flag=$(get_server_flag)
  apply_inbound_with_route "$inbound" "$D_TAG" "$D_OUTBOUND"
  uri="tuic://${uuid}:${password}@${D_FORMATTED_HOST}:${D_PORT}?congestion_control=bbr&sni=${D_HOST}#${flag}%20${node_name}"
  save_connection "tuic-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" udp
  ok "TUIC (${D_MODE}) 已部署"
  print_result_block "TUIC" "$uri" "$D_TAG"
}

deploy_anytls() {
  ensure_installed
  deploy_prepare_tls_domain 8443 "anytls" || return 0

  local paths cert key password tls inbound uri flag node_name
  paths=$(obtain_tls_paths "$D_HOST")
  cert=${paths%%|*}; key=${paths#*|}
  password=$(random_token)
  node_name=$(ask_node_name "AnyTLS-${D_MODE}")

  tls=$(tls_json "$D_HOST" "$cert" "$key" | jq -c 'del(.alpn)')
  inbound=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg password "$password" --argjson tls "$tls" \
    '{type:"anytls",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",password:$password}],tls:$tls}')
  apply_inbound_with_route "$inbound" "$D_TAG" "$D_OUTBOUND"

  flag=$(get_server_flag)
  uri="anytls://${password}@${D_FORMATTED_HOST}:${D_PORT}?sni=${D_HOST}#${flag}%20${node_name}"
  save_connection "anytls-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" tcp
  ok "AnyTLS (${D_MODE}) 已部署"
  print_result_block "AnyTLS" "$uri" "$D_TAG"
}

# Newer sing-box features require a hard version gate.
require_sb_feature_version() {
  local need=$1 feature=$2 have
  have=$(sing-box version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  [[ -n $have ]] || die "无法获取 sing-box 版本号, 请先运行 'sb check'。"
  version_ge "$have" "$need" || die "${feature}需要 sing-box >= ${need}, 当前为 ${have}; 请运行 'sb upgrade'。"
}

ask_snell_version() {
  local choice
  printf '\n选择 Snell 协议版本:\n  1) v6 (推荐)\n  2) v5 (兼容旧客户端)\n' >&2
  read -e -r -i 1 -p '请选择: ' choice
  choice=${choice:-1}
  [[ $choice == 2 ]] && printf '5' || printf '6'
}

deploy_naive() {
  ensure_installed
  deploy_prepare_tls_domain 443 "naive" || return 0
  local paths cert key username password tls inbound uri flag node_name
  paths=$(obtain_tls_paths "$D_HOST"); cert=${paths%%|*}; key=${paths#*|}
  username=user; password=$(random_token); node_name=$(ask_node_name "Naive-${D_MODE}")
  tls=$(tls_json "$D_HOST" "$cert" "$key")
  inbound=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg username "$username" --arg password "$password" --argjson tls "$tls" '{type:"naive",tag:$tag,listen:$listen,listen_port:$port,users:[{username:$username,password:$password}],tls:$tls}')
  apply_inbound_with_route "$inbound" "$D_TAG" "$D_OUTBOUND"
  flag=$(get_server_flag); uri="naive+https://${username}:${password}@${D_FORMATTED_HOST}:${D_PORT}?padding=true#${flag}%20${node_name}"
  save_connection "naive-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" tcp; open_firewall_port "$D_PORT" udp
  ok "NaiveProxy (${D_MODE}) 已部署"; print_result_block "NaiveProxy" "$uri" "$D_TAG"
}

deploy_snell() {
  ensure_installed
  require_sb_feature_version "1.14.0" "Snell 协议"
  deploy_prepare_common "Snell 监听端口" 8388 "snell" || return 0
  local version psk inbound uri uri_query flag node_name
  version=$(ask_snell_version); psk=$(random_token); node_name=$(ask_node_name "Snell-${D_MODE}")
  if [[ $version == 6 ]]; then
    inbound=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg psk "$psk" '{type:"snell",tag:$tag,listen:$listen,listen_port:$port,version:6,psk:$psk,mode:"default"}')
  else
    inbound=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg psk "$psk" '{type:"snell",tag:$tag,listen:$listen,listen_port:$port,version:5,psk:$psk,obfs_mode:"none"}')
  fi
  apply_inbound_with_route "$inbound" "$D_TAG" "$D_OUTBOUND"
  flag=$(get_server_flag); uri_query="psk=${psk}&version=${version}"
  uri="snell://${D_FORMATTED_HOST}:${D_PORT}?${uri_query}#${flag}%20${node_name}"
  save_connection "snell-v${version}-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" tcp
  ok "Snell v${version} (${D_MODE}) 已部署"; print_result_block "Snell v${version}" "$uri" "$D_TAG"
}

# ===========================================================================
# Cloudflare Tunnel (config.yml + ingress, 而非仅 quick "service install")
# ===========================================================================
readonly CF_TUNNEL_STATE="${STATE_DIR}/cf_tunnel.json"

cf_state_init() {
  ensure_dirs
  [[ -f $CF_TUNNEL_STATE ]] || printf '{"tunnels":[]}\n' > "$CF_TUNNEL_STATE"
}

install_cloudflared() {
  info "安装 cloudflared（自动检测最佳方式）"

  # 方式一：尝试直接下载二进制（最可靠，跳过 APT 源问题）
  local arch bin_url tmp_bin
  arch=$(uname -m)
  case "$arch" in
    x86_64)  bin_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
    aarch64) bin_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
    armv7l)  bin_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
    *)       bin_url="" ;;
  esac

  if [[ -n "$bin_url" ]]; then
    tmp_bin=$(mktemp)
    if UI_SOFT=1 ui_run "下载 cloudflared" curl -fsSL --retry 3 --connect-timeout 15 "$bin_url" -o "$tmp_bin"; then
      install -m 755 "$tmp_bin" /usr/local/bin/cloudflared
      rm -f "$tmp_bin"
      info "cloudflared 二进制安装成功: $(cloudflared --version)"
      install -d -m 700 "$CF_CONFIG_DIR" "$CF_CRED_DIR"
      return 0
    fi
    rm -f "$tmp_bin"
    warn "二进制下载失败，尝试 APT 源方式..."
  fi

  # 方式二：APT 源（修复 GPG 密钥格式问题）
  require_apt
  info "配置 Cloudflare 官方 cloudflared APT 源"
  install -d -m 755 /usr/share/keyrings

  # Cloudflare 已将官方签名密钥从旧的 cloudflare-main.gpg 迁移到
  # cloudflare-public-v2.gpg (旧密钥文件对应的 key id 已不再对仓库生效,
  # 继续使用旧文件会导致 apt-get update 报 NO_PUBKEY), 这里改用现行密钥文件名,
  # 并保留格式探测逻辑作为兜底 (官方该文件目前是已经 dearmor 过的二进制格式,
  # 不应再对其执行 gpg --dearmor, 否则会得到损坏的 keyring)。
  local tmp_gpg
  tmp_gpg=$(mktemp)
  if curl -fsSL --retry 3 --connect-timeout 15 \
      https://pkg.cloudflare.com/cloudflare-public-v2.gpg -o "$tmp_gpg"; then
    # 判断是否已是二进制格式，若是 ASCII armor 则转换
    if file "$tmp_gpg" 2>/dev/null | grep -qi "PGP public key block\|ASCII"; then
      gpg --dearmor < "$tmp_gpg" > /usr/share/keyrings/cloudflare-public-v2.gpg
    else
      install -m 644 "$tmp_gpg" /usr/share/keyrings/cloudflare-public-v2.gpg
    fi
    rm -f "$tmp_gpg"
  else
    rm -f "$tmp_gpg"
    die "无法下载 Cloudflare GPG 密钥，请检查网络连接"
  fi
  # 清理可能残留的旧密钥文件, 避免和新文件混淆
  rm -f /usr/share/keyrings/cloudflare-main.gpg

  tee /etc/apt/sources.list.d/cloudflared.list >/dev/null <<'EOF'
deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main
EOF

  ui_run "安装 cloudflared (apt)" _apt_update_install cloudflared
  install -d -m 700 "$CF_CONFIG_DIR" "$CF_CRED_DIR"
}

ensure_cloudflared_installed() {
  command -v cloudflared >/dev/null 2>&1 || install_cloudflared
  install -d -m 700 "$CF_CONFIG_DIR" "$CF_CRED_DIR"
}

# 使用 config.yml + ingress 规则的正式部署方式 (而非裸 quick tunnel)
deploy_cloudflare_tunnel() {
  ensure_installed
  ensure_cloudflared_installed
  cf_state_init

  local domain port path path_encoded uuid tag inbound candidate uri flag
  local tunnel_id tunnel_name cred_file tunnel_token use_token

  domain=$(ask_hostname "Cloudflare 托管域名 (例如 cf.example.com)")
  port=$(ask_port "本地 VLESS WebSocket 端口 (仅监听 127.0.0.1)" 10000)
  tag="vless-ws-cf-${port}"
  check_and_handle_existing_tag "$tag" || return 0
  ensure_port_available "$port"
  path=$(random_path)
  uuid=$(new_uuid)

  printf "\nTunnel 接入方式:\n" >&2
  printf "  1) 已在 Zero Trust 后台创建 Tunnel 并拿到 Token (推荐, 快速接入)\n" >&2
  printf "  2) 使用 cloudflared tunnel create 在本机新建 Tunnel (需已 cloudflared login)\n" >&2
  read -e -r -i 1 -p "请选择: " use_token
  use_token=${use_token:-1}

    if [[ $use_token == 1 ]]; then
    printf '\n%s\n' "---------------- Token 模式操作指引 ----------------"
    printf ' 1. 打开 Cloudflare Zero Trust → Networks → Tunnels\n'
    printf ' 2. 创建 Tunnel (Cloudflared 类型), 复制安装命令里 "install" 后面那串 Token\n'
    printf ' 3. 该 Tunnel 的 Public Hostname 稍后按本脚本提示添加 (不要提前乱填)\n'
    printf '%s\n\n' "----------------------------------------------------"
    read -e -r -s -p "Cloudflare Tunnel Token (输入不回显): " tunnel_token
    printf '\n'
    [[ -n $tunnel_token ]] || die "Tunnel Token 不能为空。"
    cloudflared service uninstall >/dev/null 2>&1 || true   # 已装过会报错, 先清掉
    info "注册并启动 cloudflared 系统服务 (token 模式)..."
    cloudflared service install "$tunnel_token"
    tunnel_name="token-${port}"

    printf '\n%s\n' "======== 现在请到 Cloudflare 后台添加 Public Hostname ========"
    printf '  Subdomain / Domain : %s\n' "$domain"
    printf '  Path               : (留空)\n'
    printf '  Service Type       : HTTP\n'
    printf '  URL                : 127.0.0.1:%s\n' "$port"
    printf '  注意: 类型必须选 HTTP (不是 HTTPS), WebSocket 默认已开启, 无需额外设置\n'
    printf '%s\n\n' "==============================================================="
    read -e -r -p "添加完成后按回车继续..." _ || true
  else
    require_cmd cloudflared
    [[ -f /root/.cloudflared/cert.pem || -f "${HOME}/.cloudflared/cert.pem" ]] || {
      warn "未检测到 cloudflared 登录凭证。"
      info "请在浏览器完成授权: 即将执行 'cloudflared tunnel login'"
      cloudflared tunnel login
    }
    tunnel_name="sbvps-$(openssl rand -hex 3)"
    cloudflared tunnel create "$tunnel_name" | tee /tmp/cf_tunnel_create.out
    tunnel_id=$(awk -F'[()]' '/Created tunnel/ {print $0}' /tmp/cf_tunnel_create.out | grep -oE '[0-9a-f-]{36}' | head -n1)
    [[ -n $tunnel_id ]] || tunnel_id=$(cloudflared tunnel list -o json 2>/dev/null | jq -r --arg n "$tunnel_name" '.[] | select(.name==$n) | .id' | head -n1)
    [[ -n $tunnel_id ]] || die "无法解析新建 Tunnel 的 ID。"
    cred_file=$(find /root/.cloudflared "${HOME}/.cloudflared" -maxdepth 1 -name "${tunnel_id}.json" 2>/dev/null | head -n1)
    [[ -n $cred_file ]] || die "未找到 Tunnel 凭证文件 ${tunnel_id}.json。"
    install -m 600 "$cred_file" "${CF_CRED_DIR}/${tunnel_id}.json"

    cloudflared tunnel route dns "$tunnel_name" "$domain" || warn "自动创建 DNS 记录失败, 请手动在 Cloudflare 后台添加 CNAME。"

    local candidate_yml
    candidate_yml=$(mktemp)
    cat > "$candidate_yml" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${CF_CRED_DIR}/${tunnel_id}.json
ingress:
  - hostname: ${domain}
    service: http://127.0.0.1:${port}
  - service: http_status:404
EOF
    atomic_install "$candidate_yml" "$CF_CONFIG_FILE" 600
    rm -f "$candidate_yml"

    tee /etc/systemd/system/cloudflared.service >/dev/null <<EOF
[Unit]
Description=cloudflared (sing-box-vps managed)
After=network.target

[Service]
Type=notify
ExecStart=/usr/bin/cloudflared --config ${CF_CONFIG_FILE} tunnel run ${tunnel_id}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi

  systemctl enable --now cloudflared
  sleep 2
  systemctl is-active --quiet cloudflared || die "cloudflared 服务启动失败, 请检查 journalctl -u cloudflared。"

  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg path "$path" \
    '{type:"vless",tag:$tag,listen:"127.0.0.1",listen_port:$port,users:[{name:"default",uuid:$uuid}],transport:{type:"ws",path:$path}}')
  candidate=$(mktemp)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$candidate"
  PENDING_TAG="$tag"
  apply_candidate "$candidate"
  rm -f "$candidate"

  atomic_json_update "$CF_TUNNEL_STATE" \
    '.tunnels += [{name:$name, domain:$domain, port:($port|tonumber), tag:$tag, created_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ")), install_method:$method}]' \
    --arg name "$tunnel_name" --arg domain "$domain" --arg port "$port" --arg tag "$tag" \
    --arg method "$(_cloudflared_install_method)" || true

  path_encoded=$(jq -nr --arg path "$path" '$path | @uri')
  local node_name; node_name=$(ask_node_name "CF-Tunnel")
  flag=$(get_server_flag)
  uri="vless://${uuid}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&path=${path_encoded}&sni=${domain}#${flag}%20${node_name}"
  save_connection "vless-ws-cloudflare-tunnel" "$tag" "$domain" 443 "$uri"
  PENDING_TAG=""
    info "等待隧道生效并做连通性自检..."
  sleep 3
  local code
  code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "https://${domain}${path}" || true)
  case $code in
    400|426|101) ok "隧道链路正常 (HTTP ${code}: 服务端已响应, 只是拒绝了非 WebSocket 请求, 属正常现象)。" ;;
    502|530|000) warn "HTTP ${code}: 隧道未接通。检查: ① 后台 Public Hostname 是否指向 127.0.0.1:${port}; ② 'sb cftunnel' 里看 cloudflared 状态与日志。" ;;
    404)         warn "HTTP 404: 请求到了 Cloudflare 但没命中本机服务。检查后台 Service 的 URL 端口是否是 ${port}。" ;;
    *)           info "自检返回 HTTP ${code}, 请用客户端实测。" ;;
  esac
  ok "Cloudflare Tunnel 与本地 VLESS WS 部署完成"
  info "客户端提示: 地址=${domain} 端口=443 TLS 开启 传输=ws 路径=${path}"
  print_result_block "Cloudflare Tunnel + VLESS WS" "$uri" "$tag"
}

cf_tunnel_status() {
  if ! command -v cloudflared >/dev/null 2>&1; then
    warn "cloudflared 尚未安装。"
    return 0
  fi
  cloudflared --version
  systemctl --no-pager --full status cloudflared || true
    if [[ -f $CF_CONFIG_FILE ]]; then
    printf '\n当前 ingress 配置:\n'
    cat "$CF_CONFIG_FILE"
  fi
}

cf_tunnel_logs() { journalctl -u cloudflared -n 150 --no-pager -o cat; }

cf_tunnel_restart() {
  systemctl restart cloudflared && ok "cloudflared 已重启。" || warn "cloudflared 重启失败, 请查看日志。"
}

cf_tunnel_stop() {
  systemctl stop cloudflared && ok "cloudflared 已停止。" || warn "cloudflared 停止失败。"
}

cf_tunnel_uninstall() {
  confirm "确认卸载 cloudflared 并移除其配置" N || return 0
  local method
  method=$(_cloudflared_install_method)

  # 停止并移除 token 模式下由 'cloudflared service install' 生成的系统服务
  # (与本脚本自建的 /etc/systemd/system/cloudflared.service 二选一存在, 两者都尝试清理)
  systemctl disable --now cloudflared 2>/dev/null || true
  command -v cloudflared >/dev/null 2>&1 && cloudflared service uninstall 2>/dev/null || true
  rm -f /etc/systemd/system/cloudflared.service
  systemctl daemon-reload 2>/dev/null || true

  case "$method" in
    apt)
      apt-get remove -y -qq cloudflared 2>/dev/null || true
      rm -f /etc/apt/sources.list.d/cloudflared.list /usr/share/keyrings/cloudflare-public-v2.gpg
      ;;
    binary)
      rm -f /usr/local/bin/cloudflared
      ;;
  esac

  rm -rf "$CF_CONFIG_DIR"
  rm -f /root/.cloudflared/cert.pem "${HOME}/.cloudflared/cert.pem" 2>/dev/null || true
  rm -rf /root/.cloudflared "${HOME}/.cloudflared" 2>/dev/null || true
  rm -f "$CF_TUNNEL_STATE"
  ok "cloudflared 已卸载 (安装方式: ${method}), 相关配置/凭证/systemd 单元已清理。"
}

cf_tunnel_rebind_token() {
  read -e -r -s -p "新的 Cloudflare Tunnel Token (输入不回显): " tunnel_token
  printf '\n'
  [[ -n $tunnel_token ]] || die "Token 不能为空。"
  systemctl stop cloudflared 2>/dev/null || true
  cloudflared service uninstall 2>/dev/null || true
  cloudflared service install "$tunnel_token"
  systemctl enable --now cloudflared
  ok "已重新绑定 Tunnel Token 并重启服务。"
}

cf_tunnel_menu() {
  local choice
  while true; do
    title "Cloudflare Tunnel 管理"
    printf '  1) 新建 Cloudflare Tunnel + VLESS WS 节点\n'
    printf '  2) 查看状态\n'
    printf '  3) 查看日志\n'
    printf '  4) 重启\n'
    printf '  5) 停止\n'
    printf '  6) 重新绑定 Token\n'
    printf '  7) 卸载\n'
    printf '  8) 检查 / 升级 cloudflared 版本\n'
    printf '  0) 返回主菜单\n'
    read -e -r -p '请选择: ' choice
    case $choice in
      1) deploy_cloudflare_tunnel ;;
      2) cf_tunnel_status ;;
      3) cf_tunnel_logs ;;
      4) cf_tunnel_restart ;;
      5) cf_tunnel_stop ;;
      6) cf_tunnel_rebind_token ;;
      7) cf_tunnel_uninstall ;;
      8) upgrade_cloudflared ;;
      0) return 0 ;;
      *) warn "无效的编号选择。" ;;
    esac
  done
}
# ===========================================================================
# Cloudflare WARP 出站集成
# 实现方式: 官方 cloudflare-warp 客户端 (warp-cli), 以 proxy 模式在本机
# 127.0.0.1:40000 暴露 SOCKS5, 再作为 sing-box 的 socks 出站接入路由,
# 避免直接接管整机路由表, 对宿主机其余服务零侵入。
#
# 重要限制 (如实说明, 不提供做不到的选项):
#   warp-cli 官方客户端本身不提供"仅用 IPv4 出口"或"仅用 IPv6 出口"这种
#   按协议族强制锁定的开关 (WARP 隧道内部是单一 WireGuard 会话, 出口地址
#   由 Cloudflare 边缘分配, 客户端侧无法指定协议族)。因此这里不再提供
#   "双栈 / IPv4 / IPv6" 这种实际上什么都不做的假选择, 只保留一个真实存在
#   的可调项: 是否偏好用 IPv6 建立到 Cloudflare 边缘的隧道连接本身
#   (tunnel protocol / 连接方式), 这与"出口协议族"是两回事, 已在菜单文案
#   中明确区分。
# ===========================================================================
readonly WARP_SOCKS_PORT=40000
readonly WARP_OUTBOUND_TAG="warp-out"

install_warp_client() {
  require_apt
  info "配置 Cloudflare WARP 官方 APT 源"
  install -d -m 755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  local codename
  codename=$(lsb_release -cs 2>/dev/null || echo "jammy")
  tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null <<EOF
deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main
EOF
  apt-get update -qq
  apt-get install -y -qq cloudflare-warp
}

warp_ensure_registered() {
  systemctl enable --now warp-svc >/dev/null 2>&1 || true
  sleep 2
  if ! warp-cli --accept-tos status >/dev/null 2>&1; then
    warp-cli --accept-tos registration new >/dev/null 2>&1 || true
  fi
}

warp_connect() {
  # WARP 本身只有"是否连接"的开关, 没有按协议族区分的模式,
  # 这里固定用 proxy 模式在本机暴露 SOCKS5, 不再提供虚假的 v4/v6/dual 选择
  warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
  warp-cli --accept-tos proxy port "$WARP_SOCKS_PORT" >/dev/null 2>&1 || true
  warp-cli --accept-tos connect >/dev/null 2>&1 || true
}

install_warp() {
  ensure_installed
  command -v warp-cli >/dev/null 2>&1 || install_warp_client
  warp_ensure_registered
  warp_connect
  sleep 2

  if ! warp-cli --accept-tos status 2>/dev/null | grep -qi "Connected"; then
    warn "WARP 客户端未能确认 Connected 状态, 请稍后使用 'sb' 菜单中的 WARP 状态查看。"
  fi

  local candidate
  candidate=$(mktemp)
  jq --arg tag "$WARP_OUTBOUND_TAG" --argjson port "$WARP_SOCKS_PORT" '
    if (.outbounds | map(select(.tag == $tag)) | length) == 0 then
      .outbounds += [{type:"socks", tag:$tag, server:"127.0.0.1", server_port:$port, version:"5"}]
    else . end
  ' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"
  rm -f "$candidate"

  ok "WARP 已安装并以 SOCKS5 (127.0.0.1:${WARP_SOCKS_PORT}) 接入 sing-box 出站 [${WARP_OUTBOUND_TAG}]。"
  info "可在部署节点或编辑路由规则时, 将出站指向 '${WARP_OUTBOUND_TAG}' 以让该节点流量经由 WARP。"
  info "提示: WARP 官方客户端不支持按 IPv4/IPv6 协议族强制锁定出口, 因此本脚本不提供该选项。"
}

warp_status() {
  if ! command -v warp-cli >/dev/null 2>&1; then
    warn "WARP 客户端尚未安装。"
    return 0
  fi
  warp-cli --accept-tos status || true
  printf '\nsing-box 内 WARP 出站配置:\n'
  jq -r --arg tag "$WARP_OUTBOUND_TAG" '.outbounds[]? | select(.tag==$tag)' "$CONFIG_FILE" 2>/dev/null || true
}

uninstall_warp() {
  confirm "确认卸载 WARP 客户端并移除其 sing-box 出站" N || return 0
  systemctl disable --now warp-svc 2>/dev/null || true
  apt-get remove -y -qq cloudflare-warp 2>/dev/null || true
  atomic_json_update "$CONFIG_FILE" '.outbounds |= map(select(.tag != $tag))' --arg tag "$WARP_OUTBOUND_TAG" || true
  systemctl restart sing-box 2>/dev/null || true
  ok "WARP 已卸载。"
}

# ===========================================================================
# cloudflared 自身版本管理 (与 sing-box 核心版本管理相互独立)
# 判断当前 cloudflared 是通过 APT 源安装还是脚本自行下载的二进制安装,
# 这两种方式的升级路径完全不同, 混用会导致状态不一致, 因此每次升级前
# 都重新探测一次, 不做缓存。
# ---------------------------------------------------------------------------
readonly CLOUDFLARED_BIN_URL_BASE="https://github.com/cloudflare/cloudflared/releases/latest/download"

_cloudflared_install_method() {
  # 输出: apt | binary | none
  if ! command -v cloudflared >/dev/null 2>&1; then
    printf 'none'
    return 0
  fi
  if dpkg -S "$(command -v cloudflared)" >/dev/null 2>&1; then
    printf 'apt'
  else
    printf 'binary'
  fi
}

_cloudflared_current_version() {
  command -v cloudflared >/dev/null 2>&1 || { printf ''; return 0; }
  cloudflared --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

_cloudflared_latest_version() {
  # 通过 GitHub Releases API 探测最新版本号, 探测失败不阻断流程 (可能网络
  # 问题或被限流), 调用方需自行处理空字符串的情况
  curl -fsS --connect-timeout 5 --max-time 8 \
    "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" 2>/dev/null \
    | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//'
}

upgrade_cloudflared() {
  if ! command -v cloudflared >/dev/null 2>&1; then
    warn "cloudflared 尚未安装, 请先在 Cloudflare Tunnel 菜单里新建一个 Tunnel 节点完成安装。"
    return 0
  fi

  local method cur latest was_active
  method=$(_cloudflared_install_method)
  cur=$(_cloudflared_current_version)
  latest=$(_cloudflared_latest_version)

  printf '\n当前 cloudflared 版本: %s (安装方式: %s)\n' "${cur:-未知}" "$method"
  if [[ -n $latest ]]; then
    printf 'GitHub 最新版本: %s\n' "$latest"
    if [[ -n $cur ]] && version_ge "$cur" "$latest"; then
      ok "已是最新版本, 无需升级。"
      return 0
    fi
  else
    warn "无法从 GitHub 获取最新版本号 (可能是网络限制), 将继续按当前安装方式尝试升级。"
  fi

  was_active=0
  systemctl is-active --quiet cloudflared 2>/dev/null && was_active=1

  case "$method" in
    apt)
      info "通过 APT 升级 cloudflared..."
      if ! apt-get update -qq 2>>"$LOG_FILE"; then
        warn "apt-get update 部分软件源同步失败 (详见 ${LOG_FILE}), 若是第三方源导致, 通常不影响 cloudflared 官方源本身, 继续尝试升级..."
      fi
      apt-get install -y -qq --only-upgrade cloudflared
      ;;
    binary)
      info "通过二进制方式升级 cloudflared..."
      local arch bin_url tmp_bin
      arch=$(uname -m)
      case "$arch" in
        x86_64)  bin_url="${CLOUDFLARED_BIN_URL_BASE}/cloudflared-linux-amd64" ;;
        aarch64) bin_url="${CLOUDFLARED_BIN_URL_BASE}/cloudflared-linux-arm64" ;;
        armv7l)  bin_url="${CLOUDFLARED_BIN_URL_BASE}/cloudflared-linux-arm" ;;
        *) die "未知的 CPU 架构 (${arch}), 无法确定二进制下载地址。" ;;
      esac
      tmp_bin=$(mktemp)
      if ! curl -fsSL --retry 3 --connect-timeout 15 "$bin_url" -o "$tmp_bin"; then
        rm -f "$tmp_bin"
        die "下载最新 cloudflared 二进制失败, 请检查网络连接。"
      fi
      [[ -s $tmp_bin ]] || { rm -f "$tmp_bin"; die "下载的二进制文件为空, 已拒绝安装。"; }
      install -m 755 "$tmp_bin" /usr/local/bin/cloudflared
      rm -f "$tmp_bin"
      ;;
    *)
      die "内部错误: 无法识别 cloudflared 安装方式。"
      ;;
  esac

  if (( was_active == 1 )); then
    systemctl restart cloudflared || warn "cloudflared 重启失败, 请运行 'sb cftunnel' 查看状态与日志。"
  fi

  ok "cloudflared 升级完成: $(cloudflared --version 2>/dev/null | head -n1)"
}

warp_menu() {
  local choice
  while true; do
    title "Cloudflare WARP 管理"
    printf '  1) 安装并连接 WARP\n'
    printf '  2) 查看状态\n'
    printf '  3) 卸载 WARP\n'
    printf '  0) 返回主菜单\n'
    read -e -r -p '请选择: ' choice
    case $choice in
      1) install_warp ;;
      2) warp_status ;;
      3) uninstall_warp ;;
      0) return 0 ;;
      *) warn "无效的编号选择。" ;;
    esac
  done
}

# ===========================================================================
# 测速: 延迟 + 下载 + 上传 (Cloudflare / Google / Microsoft)
# ===========================================================================
_speedtest_one() {
  local name=$1 dl_url=$2 ul_url=$3 latency_host=$4
  local latency dl_bps dl_mbps ul_bps ul_mbps

  printf '\n--- %s ---\n' "$name"
  latency=$(curl -o /dev/null -s --connect-timeout 3 --max-time 5 \
    -w '%{time_connect}' "https://${latency_host}/" 2>/dev/null || echo "N/A")
  if [[ $latency != "N/A" ]]; then
    printf '延迟: %s ms\n' "$(awk -v t="$latency" 'BEGIN{printf "%.1f", t*1000}')"
  else
    printf '延迟: 测量失败\n'
  fi

  # 下载测速: 100MB 在 10s 超时下要求 >=80Mbps 才能跑完整段, 低速线路会被
  # --max-time 中途掐断 (curl 退出码非0), 此时不能简单地把结果记为 0——
  # curl 在超时退出前仍会通过 -w 输出已完成部分的瞬时速率, 这里改为放宽
  # 超时时间, 并且只要 -w 输出了合法数字就采用该值 (即便传输被中途终止),
  # 只有连输出都没拿到时才归零, 避免慢速线路被误判为"下载速度为0"。
  dl_bps=$(ui_run_cap "下载测速 ${name}" curl -o /dev/null -s --max-time 20 -w '%{speed_download}' "$dl_url")
  [[ $dl_bps =~ ^[0-9]+([.][0-9]+)?$ ]] || dl_bps=0
  dl_mbps=$(awk -v b="$dl_bps" 'BEGIN{printf "%.2f", (b*8)/1000000}')
  if (( $(awk -v b="$dl_bps" 'BEGIN{print (b==0)}') )); then
    printf '下载速度: 测量失败或线路过慢 (20s 内未获得有效速率样本)\n'
  else
    printf '下载速度: %s Mbps\n' "$dl_mbps"
  fi

  if [[ -n $ul_url ]]; then
    local tmpfile
    tmpfile=$(mktemp)
    dd if=/dev/urandom of="$tmpfile" bs=1M count=8 >/dev/null 2>&1
    ul_bps=$(ui_run_cap "上传测速 ${name}" curl -o /dev/null -s --max-time 20 -w '%{speed_upload}' -X POST --data-binary "@${tmpfile}" "$ul_url")
    [[ $ul_bps =~ ^[0-9]+([.][0-9]+)?$ ]] || ul_bps=0
    ul_mbps=$(awk -v b="$ul_bps" 'BEGIN{printf "%.2f", (b*8)/1000000}')
    if (( $(awk -v b="$ul_bps" 'BEGIN{print (b==0)}') )); then
      printf '上传速度: 测量失败或线路过慢 (20s 内未获得有效速率样本)\n'
    else
      printf '上传速度: %s Mbps\n' "$ul_mbps"
    fi
    rm -f "$tmpfile"
  fi
}

run_speedtest() {
  require_cmd curl awk
  info "开始测速..."
  echo "--- Cloudflare (延迟 + 下载 + 上传, 官方测速接口) ---"
  _speedtest_one "Cloudflare" "https://speed.cloudflare.com/__down?bytes=104857600" \
    "https://speed.cloudflare.com/__up" "speed.cloudflare.com"
  echo
  echo "--- Google (仅延迟, Google 无官方公开测速接口, 不编造下载地址) ---"
  _latency_only "Google" "www.google.com"
  echo
  echo "--- Microsoft (仅延迟, Microsoft 无官方公开测速接口, 不编造下载地址) ---"
  _latency_only "Microsoft" "www.microsoft.com"
  printf '\n'
  ok "测速完成。"
}

_latency_only() {
  local name=$1 host=$2 latency
  latency=$(curl -o /dev/null -s --connect-timeout 3 --max-time 5 \
    -w '%{time_connect}' "https://${host}/" 2>/dev/null || echo "N/A")
  if [[ $latency != "N/A" ]]; then
    printf '%s 延迟: %s ms\n' "$name" "$(awk -v t="$latency" 'BEGIN{printf "%.1f", t*1000}')"
  else
    printf '%s 延迟: 测量失败 (可能被防火墙/网络策略阻断)\n' "$name"
  fi
}

# ===========================================================================
# 系统诊断
# ===========================================================================








# ===========================================================================
# 订阅系统
# 生成三类订阅文件到 SUB_DIR:
#   sub-singbox.json   sing-box 客户端可直接导入的 outbounds 片段
#   sub-clash.yaml      Clash Meta / Mihomo 通用 YAML
#   sub-universal.txt   Base64 编码的 vless/ss/trojan/hy2/tuic URI 列表
#                         (Shadowrocket / v2rayN / NekoBox 等通用订阅格式)
# 可选启动一个仅监听 127.0.0.1 的 python3 http.server 供 nginx/反代转发,
# 或直接用本机文件路径自行分发, 不强制暴露公网端口。
# ===========================================================================
readonly SUB_PORT_DEFAULT=28080
readonly SUB_TOKEN_FILE="${STATE_DIR}/sub_token"
readonly SUB_AUTH_SERVER="${STATE_DIR}/sub-server.py"

sub_collect_uris() {
  jq -r '.connections[]?.uri' "$STATE_FILE" 2>/dev/null
}

# 给 sing-box JSON / Clash 用: 排除这两种格式在当前实现里表达不了的 ShadowTLS 节点
sub_collect_uris_plain() {
  sub_collect_uris | grep -v 'plugin=shadow-tls' || true
}

sub_build_universal() {
  ensure_dirs
  local out="${SUB_DIR}/sub-universal.txt" tmp
  tmp=$(mktemp)
  sub_collect_uris > "$tmp"
  if [[ ! -s $tmp ]]; then
    rm -f "$tmp"
    warn "尚无任何节点记录, 无法生成订阅。"
    return 1
  fi
  base64 -w 0 "$tmp" > "${out}.tmp"
  mv -f "${out}.tmp" "$out"
  chmod 600 "$out"
  rm -f "$tmp"
  printf '%s' "$out"
}

sub_build_singbox_json() {
  ensure_dirs
  local out="${SUB_DIR}/sub-singbox.json" tmp
  tmp=$(mktemp)
  # 直接复用生产 config.json 的 outbounds 中非 direct/block/warp 的节点定义是不现实的
  # (inbound 与 outbound 结构不同), 这里改为逐条把已保存 URI 转成 sing-box outbound JSON。
  jq -n '{outbounds: []}' > "$tmp"
  while IFS= read -r uri; do
    [[ -z $uri ]] && continue
    local ob
    ob=$(uri_to_singbox_outbound "$uri" || true)
    [[ -n $ob ]] || continue
  jq --argjson ob "$ob" '.outbounds += [$ob]' "$tmp" > "${tmp}.n" && mv "${tmp}.n" "$tmp"
  done < <(sub_collect_uris_plain)
  json_validate "$tmp" || { rm -f "$tmp"; die "生成 sing-box 订阅 JSON 失败。"; }
  atomic_install "$tmp" "$out" 600
  rm -f "$tmp"
  printf '%s' "$out"
}

# 极简 URI -> sing-box outbound 解析器, 覆盖本脚本自身生成的 vless/ss/trojan/hy2/tuic URI
uri_to_singbox_outbound() {
  local uri=$1 scheme rest tag
  scheme=${uri%%://*}
  rest=${uri#*://}
  tag=$(printf '%s' "$uri" | sed -n 's/.*#\(.*\)$/\1/p')
  tag=$(python3 -c "import urllib.parse,sys; print(urllib.parse.unquote(sys.argv[1]))" "${tag:-node}" 2>/dev/null || printf '%s' "${tag:-node}")
  case "$scheme" in
    snell)
      local hostport query host port psk version
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}; host=${hostport%:*}; port=${hostport##*:}
      psk=$(printf '%s' "$query" | grep -oE 'psk=[^&]*' | cut -d= -f2); version=$(printf '%s' "$query" | grep -oE 'version=[^&]*' | cut -d= -f2); [[ $version == 5 ]] && version=4
      jq -n --arg tag "$tag" --arg host "$host" --argjson port "${port:-8388}" --arg psk "$psk" --argjson version "${version:-6}" '{type:"snell",tag:$tag,server:$host,server_port:$port,version:$version,psk:$psk} + (if $version == 6 then {mode:"default"} else {obfs_mode:"none"} end)' 2>/dev/null
      ;;
    "naive+https")
      local userinfo hostport username password host port
      userinfo=${rest%%@*}; rest=${rest#*@}; hostport=${rest%%\?*}; host=${hostport%:*}; port=${hostport##*:}; username=${userinfo%%:*}; password=${userinfo#*:}
      jq -n --arg tag "$tag" --arg host "$host" --argjson port "${port:-443}" --arg username "$username" --arg password "$password" '{type:"naive",tag:$tag,server:$host,server_port:$port,username:$username,password:$password,network:"tcp",tls:{enabled:true,server_name:$host}}' 2>/dev/null
      ;;
    vless)
      local userinfo hostport query uuid host port sni pbk sid flow security stype svc path
      userinfo=${rest%%@*}; rest=${rest#*@}
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}
      uuid=$userinfo
      host=${hostport%:*}; port=${hostport##*:}
      security=$(printf '%s' "$query" | grep -oE 'security=[^&]*' | cut -d= -f2)
      sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
      pbk=$(printf '%s' "$query" | grep -oE 'pbk=[^&]*' | cut -d= -f2)
      sid=$(printf '%s' "$query" | grep -oE 'sid=[^&]*' | cut -d= -f2)
      flow=$(printf '%s' "$query" | grep -oE 'flow=[^&]*' | cut -d= -f2)
      stype=$(printf '%s' "$query" | grep -oE 'type=[^&]*' | cut -d= -f2)
      svc=$(printf '%s' "$query" | grep -oE 'serviceName=[^&]*' | cut -d= -f2)
      path=$(printf '%s' "$query" | grep -oE 'path=[^&]*' | cut -d= -f2)
      path=$(python3 -c "import urllib.parse,sys; print(urllib.parse.unquote(sys.argv[1]))" "${path:-/}" 2>/dev/null || printf '%s' "${path:-/}")
      jq -n --arg tag "$tag" --arg host "$host" --argjson port "${port:-443}" --arg uuid "$uuid" \
        --arg security "$security" --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg flow "$flow" \
        --arg stype "$stype" --arg svc "$svc" --arg path "$path" '
        {type:"vless", tag:$tag, server:$host, server_port:$port, uuid:$uuid} +
        (if $flow != "" then {flow:$flow} else {} end) +
        (if $security == "reality" then
          {tls:{enabled:true, server_name:$sni, utls:{enabled:true, fingerprint:"chrome"},
                reality:{enabled:true, public_key:$pbk, short_id:$sid}}}
         elif $security == "tls" then
          {tls:{enabled:true, server_name:$sni}}
         else {} end) +
        (if $stype == "grpc" then {transport:{type:"grpc", service_name:$svc}}
         elif $stype == "ws" then {transport:{type:"ws", path:$path}}
         else {} end)
      ' 2>/dev/null
      ;;
    trojan)
      local password hostport query host port sni
      password=${rest%%@*}; rest=${rest#*@}
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}
      host=${hostport%:*}; port=${hostport##*:}
      sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
      jq -n --arg tag "$tag" --arg host "$host" --argjson port "${port:-443}" --arg password "$password" --arg sni "$sni" \
        '{type:"trojan", tag:$tag, server:$host, server_port:$port, password:$password, tls:{enabled:true, server_name:$sni}}' 2>/dev/null
      ;;
    ss)
      local b64 hostport host port method pass decoded
      b64=${rest%%@*}; rest=${rest#*@}
      hostport=${rest%%\?*}; hostport=${hostport%%#*}
      host=${hostport%:*}; port=${hostport##*:}
      valid_port "$port" || return 1
      decoded=$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)
      method=${decoded%%:*}; pass=${decoded#*:}
      [[ -n $method && -n $pass ]] || return 1
      jq -n --arg tag "$tag" --arg host "$host" --argjson port "$port" --arg method "$method" --arg pass "$pass" \
        '{type:"shadowsocks", tag:$tag, server:$host, server_port:$port, method:$method, password:$pass}' 2>/dev/null
      ;;
    hysteria2)
      local password hostport query host port sni obfs
      password=${rest%%@*}; rest=${rest#*@}
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}
      host=${hostport%:*}; port=${hostport##*:}
      sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
      obfs=$(printf '%s' "$query" | grep -oE 'obfs-password=[^&]*' | cut -d= -f2)
      jq -n --arg tag "$tag" --arg host "$host" --argjson port "${port:-443}" --arg password "$password" --arg sni "$sni" --arg obfs "$obfs" \
        '{type:"hysteria2", tag:$tag, server:$host, server_port:$port, password:$password,
          obfs:{type:"salamander", password:$obfs}, tls:{enabled:true, server_name:$sni}}' 2>/dev/null
      ;;
    tuic)
      local cred hostport query host port sni uuid password
      cred=${rest%%@*}; rest=${rest#*@}
      uuid=${cred%%:*}; password=${cred#*:}
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}
      host=${hostport%:*}; port=${hostport##*:}
      sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
      jq -n --arg tag "$tag" --arg host "$host" --argjson port "${port:-443}" --arg uuid "$uuid" --arg password "$password" --arg sni "$sni" \
        '{type:"tuic", tag:$tag, server:$host, server_port:$port, uuid:$uuid, password:$password,
          congestion_control:"bbr", tls:{enabled:true, server_name:$sni}}' 2>/dev/null
      ;;
    snell)
      local hostport query host port psk version
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}; host=${hostport%:*}; port=${hostport##*:}
      psk=$(printf '%s' "$query" | grep -oE 'psk=[^&]*' | cut -d= -f2); version=$(printf '%s' "$query" | grep -oE 'version=[^&]*' | cut -d= -f2); [[ $version == 5 ]] && version=4
      jq -n --arg tag "$tag" --arg host "$host" --argjson port "${port:-8388}" --arg psk "$psk" --argjson version "${version:-6}" '{type:"snell",tag:$tag,server:$host,server_port:$port,version:$version,psk:$psk} + (if $version == 6 then {mode:"default"} else {obfs_mode:"none"} end)' 2>/dev/null
      ;;
    "naive+https")
      local userinfo hostport username password host port
      userinfo=${rest%%@*}; rest=${rest#*@}; hostport=${rest%%\?*}; host=${hostport%:*}; port=${hostport##*:}; username=${userinfo%%:*}; password=${userinfo#*:}
      jq -n --arg tag "$tag" --arg host "$host" --argjson port "${port:-443}" --arg username "$username" --arg password "$password" '{type:"naive",tag:$tag,server:$host,server_port:$port,username:$username,password:$password,network:"tcp",tls:{enabled:true,server_name:$host}}' 2>/dev/null
      ;;
    anytls)
      local password hostport query host port sni
      password=${rest%%@*}; rest=${rest#*@}
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}
      host=${hostport%:*}; port=${hostport##*:}
      sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
      jq -n --arg tag "$tag" --arg host "$host" --argjson port "${port:-443}" --arg password "$password" --arg sni "$sni" \
        '{type:"anytls", tag:$tag, server:$host, server_port:$port, password:$password, tls:{enabled:true, server_name:$sni}}' 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

sub_build_clash_yaml() {
  ensure_dirs
  local out="${SUB_DIR}/sub-clash.yaml" tmp
  if [[ -z $(sub_collect_uris_plain) ]]; then
    warn "没有 Clash 可表达的节点 (ShadowTLS 节点已跳过), 未生成 Clash 订阅。"
    return 1
  fi
  tmp=$(mktemp)
  {
    printf 'proxies:\n'
    while IFS= read -r uri; do
      [[ -z $uri ]] && continue
            clash_proxy_yaml_from_uri "$uri" || true
    done < <(sub_collect_uris_plain)
    printf 'proxy-groups:\n'
    printf '  - name: PROXY\n'
    printf '    type: select\n'
    printf '    proxies:\n'
    while IFS= read -r uri; do
      [[ -z $uri ]] && continue
      local name
      name=$(printf '%s' "$uri" | sed -n 's/.*#\(.*\)$/\1/p')
      name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.unquote(sys.argv[1]))" "${name:-node}" 2>/dev/null || printf '%s' "${name:-node}")
    printf '      - "%s"\n' "$name"
    done < <(sub_collect_uris_plain)
    printf 'rules:\n  - MATCH,PROXY\n'
  } > "$tmp"
  atomic_install "$tmp" "$out" 600
  rm -f "$tmp"
  printf '%s' "$out"
}

clash_proxy_yaml_from_uri() {
  local uri=$1 scheme rest name
  scheme=${uri%%://*}; rest=${uri#*://}
  name=$(printf '%s' "$uri" | sed -n 's/.*#\(.*\)$/\1/p')
  name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.unquote(sys.argv[1]))" "${name:-node}" 2>/dev/null || printf '%s' "${name:-node}")
  case "$scheme" in
    snell)
      local hostport query host port psk version
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}; host=${hostport%:*}; port=${hostport##*:}
      psk=$(printf '%s' "$query" | grep -oE 'psk=[^&]*' | cut -d= -f2); version=$(printf '%s' "$query" | grep -oE 'version=[^&]*' | cut -d= -f2)
      printf '  - name: "%s"\n    type: snell\n    server: %s\n    port: %s\n    psk: "%s"\n    version: %s\n' "$name" "$host" "$port" "$psk" "${version:-6}"
      ;;
    "naive+https")
      local userinfo hostport host port username password
      userinfo=${rest%%@*}; rest=${rest#*@}; hostport=${rest%%\?*}; hostport=${hostport%%#*}; host=${hostport%:*}; port=${hostport##*:}; username=${userinfo%%:*}; password=${userinfo#*:}
      printf '  - name: "%s"\n    type: naive\n    server: %s\n    port: %s\n    username: "%s"\n    password: "%s"\n' "$name" "$host" "$port" "$username" "$password"
      ;;
    vless)
      local userinfo hostport query uuid host port sni pbk sid flow security stype svc path host_hdr
      userinfo=${rest%%@*}; rest=${rest#*@}
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}
      uuid=$userinfo; host=${hostport%:*}; port=${hostport##*:}
      security=$(printf '%s' "$query" | grep -oE 'security=[^&]*' | cut -d= -f2)
      sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
      pbk=$(printf '%s' "$query" | grep -oE 'pbk=[^&]*' | cut -d= -f2)
      sid=$(printf '%s' "$query" | grep -oE 'sid=[^&]*' | cut -d= -f2)
      flow=$(printf '%s' "$query" | grep -oE 'flow=[^&]*' | cut -d= -f2)
      stype=$(printf '%s' "$query" | grep -oE 'type=[^&]*' | cut -d= -f2)
      svc=$(printf '%s' "$query" | grep -oE 'serviceName=[^&]*' | cut -d= -f2)
      path=$(printf '%s' "$query" | grep -oE 'path=[^&]*' | cut -d= -f2)
      path=$(python3 -c "import urllib.parse,sys; print(urllib.parse.unquote(sys.argv[1]))" "${path:-/}" 2>/dev/null || printf '%s' "${path:-/}")
      host_hdr=$(printf '%s' "$query" | grep -oE 'host=[^&]*' | cut -d= -f2)
      printf '  - name: "%s"\n    type: vless\n    server: %s\n    port: %s\n    uuid: %s\n    network: %s\n' \
        "$name" "$host" "$port" "$uuid" "${stype:-tcp}"
      [[ -n $flow ]] && printf '    flow: %s\n' "$flow"
      if [[ $security == reality ]]; then
        printf '    tls: true\n    servername: %s\n    client-fingerprint: chrome\n    reality-opts:\n      public-key: %s\n      short-id: "%s"\n' \
          "$sni" "$pbk" "$sid"
      elif [[ $security == tls ]]; then
        printf '    tls: true\n    servername: %s\n' "$sni"
      fi
      [[ $stype == grpc ]] && printf '    grpc-opts:\n      grpc-service-name: %s\n' "$svc"
      [[ $stype == ws ]] && printf '    ws-opts:\n      path: "%s"\n      headers:\n        Host: %s\n' "$path" "${host_hdr:-$sni}"
      ;;
    trojan)
      local password hostport query host port sni
      password=${rest%%@*}; rest=${rest#*@}
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}
      host=${hostport%:*}; port=${hostport##*:}
      sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
      printf '  - name: "%s"\n    type: trojan\n    server: %s\n    port: %s\n    password: %s\n    sni: %s\n' \
        "$name" "$host" "$port" "$password" "$sni"
      ;;
    ss)
      local b64 hostport host port decoded method pass
      b64=${rest%%@*}; rest=${rest#*@}
      hostport=${rest%%\?*}; hostport=${hostport%%#*}
      host=${hostport%:*}; port=${hostport##*:}
      decoded=$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)
      method=${decoded%%:*}; pass=${decoded#*:}
      printf '  - name: "%s"\n    type: ss\n    server: %s\n    port: %s\n    cipher: %s\n    password: "%s"\n' \
        "$name" "$host" "$port" "$method" "$pass"
      ;;
    hysteria2)
      local password hostport query host port sni obfs
      password=${rest%%@*}; rest=${rest#*@}
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}
      host=${hostport%:*}; port=${hostport##*:}
      sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
      obfs=$(printf '%s' "$query" | grep -oE 'obfs-password=[^&]*' | cut -d= -f2)
      printf '  - name: "%s"\n    type: hysteria2\n    server: %s\n    port: %s\n    password: "%s"\n    sni: %s\n    obfs: salamander\n    obfs-password: "%s"\n' \
        "$name" "$host" "$port" "$password" "$sni" "$obfs"
      ;;
    tuic)
      local cred hostport query host port sni uuid password
      cred=${rest%%@*}; rest=${rest#*@}
      uuid=${cred%%:*}; password=${cred#*:}
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}
      host=${hostport%:*}; port=${hostport##*:}
      sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
      printf '  - name: "%s"\n    type: tuic\n    server: %s\n    port: %s\n    uuid: %s\n    password: "%s"\n    sni: %s\n    congestion-controller: bbr\n' \
        "$name" "$host" "$port" "$uuid" "$password" "$sni"
      ;;
          snell)
            local hostport query host port psk version
            hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}; host=${hostport%:*}; port=${hostport##*:}
            psk=$(printf '%s' "$query" | grep -oE 'psk=[^&]*' | cut -d= -f2); version=$(printf '%s' "$query" | grep -oE 'version=[^&]*' | cut -d= -f2)
            printf '  - name: "%s"\n    type: snell\n    server: %s\n    port: %s\n    psk: "%s"\n    version: %s\n' "$name" "$host" "$port" "$psk" "${version:-6}"
            ;;
          "naive+https")
            local userinfo hostport host port username password
            userinfo=${rest%%@*}; rest=${rest#*@}; hostport=${rest%%\?*}; hostport=${hostport%%#*}; host=${hostport%:*}; port=${hostport##*:}; username=${userinfo%%:*}; password=${userinfo#*:}
            printf '  - name: "%s"\n    type: naive\n    server: %s\n    port: %s\n    username: "%s"\n    password: "%s"\n' "$name" "$host" "$port" "$username" "$password"
            ;;
          anytls)
      local password hostport query host port sni
      password=${rest%%@*}; rest=${rest#*@}
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}
      host=${hostport%:*}; port=${hostport##*:}
      sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
      printf '  - name: "%s"\n    type: anytls\n    server: %s\n    port: %s\n    password: "%s"\n    sni: %s\n    client-fingerprint: chrome\n' \
        "$name" "$host" "$port" "$password" "$sni"
      ;;
  esac
}

sub_build_all() {
  ensure_dirs
  local f1 f2 f3
  f1=$(sub_build_universal) || return 1
  f2=$(sub_build_singbox_json)
  f3=$(sub_build_clash_yaml)
  ok "订阅文件已生成:"
  printf '  通用 (Shadowrocket/v2rayN/NekoBox): %s\n' "$f1"
  printf '  sing-box JSON: %s\n' "$f2"
  printf '  Clash Meta / Mihomo YAML: %s\n' "$f3"
}

sub_serve_start() {
  ensure_dirs
  local port token
  port=$(ask_port "本地订阅 HTTP 服务端口 (仅监听 127.0.0.1, 自行用 Nginx/Caddy 反代加 TLS)" "$SUB_PORT_DEFAULT")
  write_sub_auth_server
  token=$(ensure_sub_token)
  tee "$SUB_HTTPD_UNIT" >/dev/null <<EOF
[Unit]
Description=sing-box-vps subscription file server (127.0.0.1 only, token auth)
After=network.target

[Service]
Type=simple
WorkingDirectory=${SUB_DIR}
ExecStart=/usr/bin/python3 ${SUB_AUTH_SERVER} ${port} ${SUB_DIR} ${SUB_TOKEN_FILE}
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now sing-box-vps-sub
  ok "订阅服务已启动 (已启用 token 校验)"
  printf '自适应订阅链接 (推荐, 根据客户端自动识别格式): http://127.0.0.1:%s/sub?token=%s\n' "$port" "$token"
  printf '对外域名示例: https://你的域名/sub?token=%s\n' "$token"
  printf '如需强制指定格式, 把 /sub 换成: /sub-clash.yaml (Clash/Mihomo) | /sub-singbox.json (sing-box) | /sub-universal.txt (v2rayN/Shadowrocket/NekoBox 等)\n'
}

ensure_sub_token() {
  ensure_dirs
  if [[ ! -f $SUB_TOKEN_FILE ]]; then
    openssl rand -hex 16 > "$SUB_TOKEN_FILE"
    chmod 600 "$SUB_TOKEN_FILE"
  fi
  cat "$SUB_TOKEN_FILE"
}

regenerate_sub_token() {
  ensure_dirs
  openssl rand -hex 16 > "$SUB_TOKEN_FILE"
  chmod 600 "$SUB_TOKEN_FILE"
  systemctl restart sing-box-vps-sub 2>/dev/null || true
  ok "订阅访问 token 已重置为: $(cat "$SUB_TOKEN_FILE")"
  warn "旧链接已失效, 请用新 token 更新客户端订阅地址。"
}

write_sub_auth_server() {
  tee "$SUB_AUTH_SERVER" >/dev/null <<'PYEOF'
#!/usr/bin/env python3
import http.server, socketserver, sys, re, os
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1])
DIRECTORY = sys.argv[2]
TOKEN_FILE = sys.argv[3]

with open(TOKEN_FILE) as f:
    TOKEN = f.read().strip()

CLASH_UA_RE = re.compile(r'(clash|mihomo|stash|verge|flclash)', re.I)
SINGBOX_UA_RE = re.compile(r'(sing-?box|sfa|sfi|sfm)', re.I)
AUTO_PATHS = ("/", "/sub", "/subscribe")

class AuthHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        token = qs.get("token", [""])[0]
        if token != TOKEN:
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b"Forbidden")
            return

        if parsed.path in AUTO_PATHS:
            ua = self.headers.get("User-Agent", "")
            if CLASH_UA_RE.search(ua):
                fname, ctype = "sub-clash.yaml", "text/yaml; charset=utf-8"
            elif SINGBOX_UA_RE.search(ua):
                fname, ctype = "sub-singbox.json", "application/json; charset=utf-8"
            else:
                fname, ctype = "sub-universal.txt", "text/plain; charset=utf-8"
            self._serve_file(fname, ctype)
            return

        self.path = parsed.path
        super().do_GET()

    def _serve_file(self, fname, ctype):
        fpath = os.path.join(DIRECTORY, fname)
        try:
            with open(fpath, "rb") as f:
                body = f.read()
        except OSError:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"Not generated yet, run: sb sub -> 1")
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def list_directory(self, path):
        self.send_error(403, "Directory listing disabled")
        return None

    def log_message(self, fmt, *args):
        pass

with socketserver.TCPServer(("127.0.0.1", PORT), AuthHandler) as httpd:
    httpd.serve_forever()
PYEOF
  chmod 755 "$SUB_AUTH_SERVER"
}

sub_serve_stop() {
  systemctl disable --now sing-box-vps-sub 2>/dev/null || true
  ok "订阅本地服务已停止。"
}

subscription_menu() {
  local choice
  while true; do
    title "订阅系统"
    printf '  1) 生成 / 刷新全部订阅文件\n'
    printf '  2) 查看订阅文件路径\n'
    printf '  3) 启动本地订阅 HTTP 服务 (127.0.0.1)\n'
    printf '  4) 停止本地订阅 HTTP 服务\n'
    printf '  5) 删除全部订阅文件\n'
    printf '  6) 查看 / 重置订阅访问 token\n'
    printf '  0) 返回主菜单\n'
    read -e -r -p '请选择: ' choice
    case $choice in
      1) sub_build_all ;;
      2) find "$SUB_DIR" -maxdepth 1 -type f 2>/dev/null | sed 's/^/  - /' ;;
      3) sub_serve_start ;;
      4) sub_serve_stop ;;
      5) confirm "确认删除全部订阅文件" N && rm -f "${SUB_DIR:?}"/* && ok "已清空订阅文件。" ;;
      6)
        if [[ -f $SUB_TOKEN_FILE ]]; then
          printf '当前 token: %s\n' "$(cat "$SUB_TOKEN_FILE")"
          confirm "是否重置 token (旧链接将立即失效)" N && regenerate_sub_token
        else
          ensure_sub_token >/dev/null
          ok "已生成新 token: $(cat "$SUB_TOKEN_FILE")"
        fi
        ;;
      0) return 0 ;;
      *) warn "无效的编号选择。" ;;
    esac
  done
}
# ===========================================================================
# 节点管理 / 运维
# ===========================================================================
show_connections() {
  ensure_dirs
  if [[ $(jq '.connections | length' "$STATE_FILE") -eq 0 ]]; then
    warn "尚未由本脚本创建任何连接记录。"
    return 0
  fi
  printf '\n已保存的客户端连接串:\n\n'
  jq -r '.connections[] | "[\(.type)] \(.tag) -> \(.host):\(.port)\n\(.uri)\n"' "$STATE_FILE"
}

show_connection_qrcode() {
  ensure_dirs
  local tags tag uri
  if [[ $(jq '.connections | length' "$STATE_FILE") -eq 0 ]]; then
    warn "尚未由本脚本创建任何连接记录。"
    return 0
  fi
  mapfile -t tags < <(jq -r '.connections[].tag' "$STATE_FILE")
  printf '\n可用节点:\n'
  local i
  for i in "${!tags[@]}"; do printf '  %d) %s\n' "$((i+1))" "${tags[$i]}"; done
  read -e -r -p "选择要显示二维码的节点编号: " idx
  [[ $idx =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#tags[@]} )) || die "无效编号。"
  tag=${tags[$((idx-1))]}
  uri=$(jq -r --arg tag "$tag" '.connections[] | select(.tag==$tag) | .uri' "$STATE_FILE")
  print_result_block "$tag" "$uri" "$tag"
}

list_inbounds() {
  ensure_base_routing
  jq -r '.inbounds | to_entries[] | "\(.key + 1). \(.value.tag) [\(.value.type)] :\(.value.listen_port // "Detour")"' "$CONFIG_FILE"
}

remove_inbound() {
  ensure_installed
  if [[ $(jq '.inbounds | length' "$CONFIG_FILE") -eq 0 ]]; then
    warn "当前没有任何入站节点。"
    return 0
  fi
  local tag=${1:-}
  if [[ -z $tag ]]; then
    printf '\n当前已配置的入站:\n'
    list_inbounds
    tag=$(ask_required "请输入要删除的节点 tag")
  fi
  valid_safe_token "$tag" || die "非法 tag 格式。"
  jq -e --arg tag "$tag" '.inbounds[] | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 || die "未找到对应的节点 tag。"
  confirm "确认删除 ${tag} 并清除关联的分流规则" N || return 0

  local listen_port
  listen_port=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .listen_port // empty' "$CONFIG_FILE")

  local candidate
  candidate=$(mktemp)
  jq --arg tag "$tag" '
    ([.inbounds[]? | select(.tag == $tag) | .detour // empty]) as $detours |
    .inbounds |= map(select(.tag != $tag and ((.tag | IN($detours[])) | not))) |
    if .route.rules then .route.rules |= map(select((.inbound // []) | index($tag) | not)) else . end
  ' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"
  rm -f "$candidate"

  if [[ -n $listen_port ]]; then
    close_firewall_port "$listen_port" tcp
    close_firewall_port "$listen_port" udp
  fi

  atomic_json_update "$STATE_FILE" '.connections |= map(select(.tag != $tag))' --arg tag "$tag" || true
  ok "已成功删除 ${tag} 并同步更新路由。"
}

# 按 inbound.type (config.json 里的字段) 返回需要放行的传输层协议,
# 与 _type_protocols (按 connections.json 的 type 字段) 是同一套映射,
# 但 reconcile 阶段可能连 connections.json 记录都还没有, 所以单独按
# config 里的 .type 做一次判断
_inbound_protocols() {
  _proto_fw_protocols "$1"
}
_proto_fw_protocols() {
  case "$1" in
    hysteria2*|tuic*) printf 'udp\n' ;;
    shadowsocks*|naive*) printf 'tcp\nudp\n' ;;
    *) printf 'tcp\n' ;;
  esac
}

# 探测某个端口/协议当前是否已经在防火墙层放行, 兼容 ufw/firewalld/iptables/nftables
# 四种后端, 与 open_firewall_port() 判断"用哪个后端"的逻辑保持一致
_fw_port_allowed() {
  local port=$1 protocol=$2
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw status 2>/dev/null | grep -qE "^${port}/${protocol}[[:space:]].*ALLOW"
    return $?
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | grep -qx "${port}/${protocol}"
    return $?
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null
    return $?
  fi
  if command -v nft >/dev/null 2>&1 && nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
    nft list chain inet "$NFT_TABLE" input 2>/dev/null | grep -qE "${protocol} dport ${port} accept"
    return $?
  fi
  return 1
}

# 检查并修复孤儿节点: 
#   1) config.json 里的 inbound tag <-> connections.json 里的 tag 对账
#   2) 每个监听中的入站, 检查其端口/协议是否真的在防火墙层放行
# 全程只报告, 发现问题后逐项 confirm 才会真正改动, 不做静默清理
reconcile_nodes() {
  ensure_installed
  title "检查并修复孤儿节点 (reconcile)"

  local -a inbound_tags=() conn_tags=()
  mapfile -t inbound_tags < <(jq -r '.inbounds[]?.tag' "$CONFIG_FILE" 2>/dev/null)
  mapfile -t conn_tags < <(jq -r '.connections[]?.tag' "$STATE_FILE" 2>/dev/null)

  local -a orphan_inbounds=() orphan_conns=()
  local t c found

  # config 里有 inbound, 但 connections.json 里找不到对应记录
  # (典型场景: 部署过程中被 SIGINT/SIGTERM 打断, PENDING_TAG 提示过的那种情况)
  for t in "${inbound_tags[@]}"; do
    found=0
    for c in "${conn_tags[@]}"; do [[ $t == "$c" ]] && { found=1; break; }; done
    (( found == 0 )) && orphan_inbounds+=("$t")
  done

  # connections.json 里有记录, 但 config 里已经没有对应 inbound 了
  # (典型场景: 手动删过 inbound 但连接记录没跟着清理, 或本函数上一次没清理完)
  for t in "${conn_tags[@]}"; do
    found=0
    for c in "${inbound_tags[@]}"; do [[ $t == "$c" ]] && { found=1; break; }; done
    (( found == 0 )) && orphan_conns+=("$t")
  done

  if (( ${#orphan_inbounds[@]} == 0 && ${#orphan_conns[@]} == 0 )); then
    ok "未发现孤儿节点, config.json 与 connections.json 对账一致。"
  fi

  # --- 处理孤儿 inbound (config 有, 连接记录没有) ---
  for t in "${orphan_inbounds[@]}"; do
    warn "孤儿入站: [${t}] 存在于 config.json, 但没有对应的连接记录。"
    if confirm "是否删除该入站节点及其分流规则 (等同于 remove_inbound)" N; then
      local listen_port
      listen_port=$(jq -r --arg tag "$t" '.inbounds[] | select(.tag == $tag) | .listen_port // empty' "$CONFIG_FILE")
      local candidate
      candidate=$(mktemp)
      jq --arg tag "$t" '
        .inbounds |= map(select(.tag != $tag)) |
        if .route.rules then .route.rules |= map(select((.inbound // []) | index($tag) | not)) else . end
      ' "$CONFIG_FILE" > "$candidate"
      apply_candidate "$candidate"
      rm -f "$candidate"
      if [[ -n $listen_port ]]; then
        close_firewall_port "$listen_port" tcp
        close_firewall_port "$listen_port" udp
      fi
      ok "已删除孤儿入站 [${t}]。"
    else
      warn "已跳过 [${t}], 保留原样。"
    fi
  done

  # --- 处理孤儿连接记录 (connections.json 有, inbound 没有) ---
  for t in "${orphan_conns[@]}"; do
    warn "孤儿连接记录: [${t}] 存在于 connections.json, 但没有对应的 inbound。"
    if confirm "是否清理该条连接记录" N; then
      atomic_json_update "$STATE_FILE" '.connections |= map(select(.tag != $tag))' --arg tag "$t" \
        && ok "已清理连接记录 [${t}]。"
    else
      warn "已跳过 [${t}], 保留原样。"
    fi
  done

  # --- 防火墙对账: 每个非 127.0.0.1 监听的 inbound, 检查端口是否真的放行 ---
  local -a fw_rows=()
  mapfile -t fw_rows < <(jq -r '.inbounds[]? | select(.listen_port != null and .listen != "127.0.0.1") | "\(.tag)\t\(.type)\t\(.listen_port)"' "$CONFIG_FILE" 2>/dev/null)

  local row tag type port proto missing=0
  for row in "${fw_rows[@]}"; do
    IFS=$'\t' read -r tag type port <<<"$row"
    for proto in $(_inbound_protocols "$type"); do
      if ! _fw_port_allowed "$port" "$proto"; then
        missing=1
        warn "防火墙缺口: 节点 [${tag}] 端口 ${port}/${proto} 未在防火墙层放行。"
        if confirm "是否现在放行 ${port}/${proto}" Y; then
          open_firewall_port "$port" "$proto"
        else
          warn "已跳过 ${port}/${proto}, 该端口可能无法从外部访问。"
        fi
      fi
    done
  done
  (( missing == 0 )) && ok "防火墙对账正常, 所有监听端口均已放行。"

  printf '\n'
  ok "reconcile 检查完成。"
}

_conn_field() {  # _conn_field <tag> <字段名>
  jq -r --arg t "$1" --arg f "$2" '.connections[]|select(.tag==$t)|.[$f]|tostring' "$STATE_FILE"
}

_conn_save() {   # _conn_save <tag> <新uri> <新host>
  atomic_json_update "$STATE_FILE" \
    '(.connections[]|select(.tag==$t)) |= (.uri=$u | .host=$h)' \
    --arg t "$1" --arg u "$2" --arg h "$3"
}

pick_connection_tag() {
  local -a tags=(); local i idx
  # 从节点列表 (e3 等) 进入时已选定节点, 不再重复询问
  if [[ -n ${SEL_TAG:-} ]]; then printf '%s' "$SEL_TAG"; return 0; fi
  mapfile -t tags < <(jq -r '.connections[].tag' "$STATE_FILE")
  (( ${#tags[@]} > 0 )) || { warn "尚无节点记录。"; return 1; }
  for i in "${!tags[@]}"; do printf '  %d) %s\n' "$((i+1))" "${tags[$i]}" >&2; done
  read -e -r -p "选择节点编号: " idx || return 1
  [[ $idx =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#tags[@]} )) || { warn "无效编号。"; return 1; }
  printf '%s' "${tags[$((idx-1))]}"
}

rename_node() {
  ensure_dirs
  local tag new_enc old_uri new_uri
  tag=$(pick_connection_tag) || return 0
  new_enc=$(ask_node_name "$tag")
  old_uri=$(jq -r --arg t "$tag" '.connections[]|select(.tag==$t)|.uri' "$STATE_FILE")
  new_uri="${old_uri%%#*}#${new_enc}"
  atomic_json_update "$STATE_FILE" \
    '(.connections[]|select(.tag==$t)|.uri) = $u' --arg t "$tag" --arg u "$new_uri" \
    && ok "已重命名, 请重新导入客户端 / 刷新订阅。"
}

# 按协议类型返回需要放行的传输层协议
_type_protocols() {
  _proto_fw_protocols "$1"
}

change_node_port() {
  ensure_installed
  local tag type old_port new_port candidate old_uri new_uri p
  tag=$(pick_connection_tag) || return 0
  type=$(jq -r --arg t "$tag" '.connections[]|select(.tag==$t)|.type' "$STATE_FILE")
  [[ $type == vless-ws-cloudflare-tunnel ]] && { warn "Tunnel 节点的端口需同时改 Cloudflare 后台, 请删除后重建。"; return 0; }
  old_port=$(jq -r --arg t "$tag" '.connections[]|select(.tag==$t)|.port' "$STATE_FILE")
  new_port=$(ask_port "新的监听端口" "$old_port")
  [[ $new_port != "$old_port" ]] || return 0
  ensure_port_available "$new_port"

  candidate=$(mktemp)
  jq --arg t "$tag" --argjson p "$new_port" \
    '(.inbounds[]|select(.tag==$t)|.listen_port) = $p' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"; rm -f "$candidate"

  old_uri=$(jq -r --arg t "$tag" '.connections[]|select(.tag==$t)|.uri' "$STATE_FILE")
  new_uri=$(printf '%s' "$old_uri" | sed -E "s/:${old_port}([?#])/:${new_port}\1/")
  atomic_json_update "$STATE_FILE" \
    '(.connections[]|select(.tag==$t)) |= (.port=($np|tonumber) | .uri=$u)' \
    --arg t "$tag" --arg np "$new_port" --arg u "$new_uri"

  for p in $(_type_protocols "$type"); do
    close_firewall_port "$old_port" "$p"
    open_firewall_port "$new_port" "$p"
  done
  ok "端口已由 ${old_port} 改为 ${new_port}, 新连接串:"
  print_result_block "$tag" "$new_uri" "$tag"
}

# 只改客户端连接地址 (IP/域名), 不动服务端配置, 适合换 IP、加 CDN 域名
change_node_host() {
  ensure_dirs
  local tag type old_uri new_host new_fmt new_uri
  tag=$(pick_connection_tag) || return 0
  type=$(_conn_field "$tag" type)
  if [[ $type == vless-ws-cloudflare-tunnel ]]; then
    warn "Tunnel 节点的域名绑定在 Cloudflare 后台, 请删除后重建。"; return 0
  fi
  old_uri=$(_conn_field "$tag" uri)
  read -e -r -p "新的客户端连接地址 (IP 或域名): " new_host
  if ! { valid_ipv4 "$new_host" || valid_ipv6 "$new_host" || valid_hostname "$new_host"; }; then
    warn "地址格式不正确。"; return 0
  fi
  new_fmt=$(format_host_uri "$new_host")
  new_uri=$(printf '%s' "$old_uri" | sed -E "s~^([A-Za-z0-9]+://[^@]*@)(\[[^]]*\]|[^:/?#]+)~\1${new_fmt}~")
  _conn_save "$tag" "$new_uri" "$new_host"
  ok "连接地址已更新, 请重新导入客户端 / 刷新订阅。"
  print_result_block "$tag" "$new_uri" "$tag"
}

# 改 Reality / ShadowTLS 的握手伪装域名
change_reality_domain() {
  ensure_installed
  local tag type old_dom new_dom old_uri new_uri candidate filter
  tag=$(pick_connection_tag) || return 0
  type=$(_conn_field "$tag" type)
  case $type in
    vless-reality*)
      filter='(.inbounds[]|select(.tag==$t)|.tls) |= (.server_name=$d | .reality.handshake.server=$d)'
      old_dom=$(jq -r --arg t "$tag" '.inbounds[]|select(.tag==$t)|.tls.server_name' "$CONFIG_FILE") ;;
    shadowtls*)
      filter='(.inbounds[]|select(.tag==$t)|.handshake.server) = $d'
      old_dom=$(jq -r --arg t "$tag" '.inbounds[]|select(.tag==$t)|.tls.server_name // empty' "$CONFIG_FILE") ;;
    *) warn "该节点不是 Reality / ShadowTLS 类型。"; return 0 ;;
  esac
  [[ -n $old_dom ]] || { warn "读取原握手域名失败。"; return 0; }
  new_dom=$(ask_reality_handshake_domain)
  [[ $new_dom != "$old_dom" ]] || return 0

  candidate=$(mktemp)
  jq --arg t "$tag" --arg d "$new_dom" "$filter" "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"; rm -f "$candidate"

  old_uri=$(_conn_field "$tag" uri)
  new_uri=${old_uri//"$old_dom"/"$new_dom"}
  _conn_save "$tag" "$new_uri" "$(_conn_field "$tag" host)"
  ok "握手域名已由 ${old_dom} 改为 ${new_dom}。"
  print_result_block "$tag" "$new_uri" "$tag"
}

# 改 TLS 类节点的域名 (会为新域名申请/选择证书)
change_tls_domain() {
  ensure_installed
  local tag type old_dom new_dom paths cert key candidate old_uri new_uri
  tag=$(pick_connection_tag) || return 0
  type=$(_conn_field "$tag" type)
  case $type in
      trojan*|vless-tls*|hysteria2*|tuic*|anytls*|naive*) ;;
    *) warn "该节点不是 TLS 证书类节点。"; return 0 ;;
  esac
  old_dom=$(jq -r --arg t "$tag" '.inbounds[]|select(.tag==$t)|.tls.server_name // empty' "$CONFIG_FILE")
  [[ -n $old_dom ]] || { warn "读取原 TLS 域名失败。"; return 0; }
  new_dom=$(ask_hostname "新的 TLS 域名 (需已解析到本机)")
  [[ $new_dom != "$old_dom" ]] || return 0
  paths=$(obtain_tls_paths "$new_dom")
  cert=${paths%%|*}; key=${paths#*|}

  candidate=$(mktemp)
  jq --arg t "$tag" --arg d "$new_dom" --arg c "$cert" --arg k "$key" \
    '(.inbounds[]|select(.tag==$t)|.tls) |= (.server_name=$d | .certificate_path=$c | .key_path=$k)' \
    "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"; rm -f "$candidate"

  old_uri=$(_conn_field "$tag" uri)
  new_uri=${old_uri//"$old_dom"/"$new_dom"}
  _conn_save "$tag" "$new_uri" "$new_dom"
  ok "TLS 域名已由 ${old_dom} 改为 ${new_dom}。旧证书文件未删除。"
  print_result_block "$tag" "$new_uri" "$tag"
}

validate_and_restart() {
  ensure_installed
  sing-box check -c "$CONFIG_FILE"
  systemctl enable --now sing-box
  systemctl restart sing-box
  ok "配置校验通过, sing-box 服务已重启。"
}


show_logs() { journalctl -u sing-box -n 150 --no-pager -o cat; }


update_manager() {
  local candidate
  candidate=$(mktemp)
  info "从远程仓库拉取脚本更新: $SCRIPT_UPDATE_URL"
  curl -fL --proto '=https' --tlsv1.2 "$SCRIPT_UPDATE_URL" -o "$candidate"
  bash -n "$candidate" || { rm -f "$candidate"; die "下载的脚本语法校验失败, 已拒绝安装。"; }
  install -D -m 700 "$candidate" "$MANAGER_PATH"
  rm -f "$candidate"
  tee "$SHORTCUT_PATH" >/dev/null <<EOF
#!/usr/bin/env bash
exec ${MANAGER_PATH} "\$@"
EOF
  chmod 755 "$SHORTCUT_PATH"
  ok "管理脚本更新完毕, 直接输入 sb 即可使用新版本。"
}

upgrade_sing_box() {
  ensure_installed
  info "更新 sing-box 软件包..."
  # apt-get update 只要任意一个已配置的第三方源 (例如曾经装过的 cloudflared
  # APT 源) GPG 密钥过期/失效, 整个命令就会以非零退出, 在 set -e 下会连累
  # sing-box 官方源 (sagernet) 本身没问题也升级不了。这里不因此中断,
  # 仅告警提示, 成功同步的源 (通常包含 sagernet) 其索引已经落盘可用。
  if ! apt-get update -qq 2>>"$LOG_FILE"; then
    warn "apt-get update 部分软件源同步失败 (详见 ${LOG_FILE}), 可能是第三方源 (如 cloudflared) GPG 密钥过期导致, 与 sing-box 官方源无关; 继续尝试升级..."
  fi
  apt-get install -y -qq --only-upgrade sing-box
  validate_and_restart
  ok "更新完成: $(sing-box version | head -n 1)"
}

enable_bbr() {
  require_root
  local virt
  virt=$(systemd-detect-virt 2>/dev/null || true)
  if [[ $virt =~ (lxc|openvz|container) ]]; then
    warn "检测到当前环境处于容器虚拟化 ($virt), 内核层可能不允许自行修改 TCP 拥塞控制。"
  fi
  local sysctl_file="/etc/sysctl.d/99-sing-box-bbr.conf"
  tee "$sysctl_file" >/dev/null <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1 || warn "sysctl 应用返回警告, 可能需要宿主机内核支持。"
  ok "已写入 BBR 配置; 当前生效算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知)"
}

restore_backup() {
  ensure_installed
  local file candidate
  file=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.json' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -n 1 | cut -d' ' -f2-)
  [[ -n $file ]] || die "未发现任何可用的备份文件。"
  warn "将回退到最近的备份: $file"
  confirm "确认恢复该备份" N || return 0
  candidate=$(mktemp)
  install -m 600 "$file" "$candidate"
  apply_candidate "$candidate"
  rm -f "$candidate"
  ok "配置已回滚并成功重启服务。"
}

uninstall_sing_box() {
  require_root
  warn "这将会停止并卸载 sing-box 程序; 现有配置文件和节点连接串将保留在系统内。"
  confirm "确认卸载 sing-box" N || return 0
  systemctl disable --now sing-box 2>/dev/null || true
  apt-get remove -y -qq sing-box
  ok "sing-box 已卸载完毕; 数据保留目录: ${CONFIG_DIR}, ${STATE_DIR}"
}

# ===========================================================================
# 彻底清除: 停服务 + 卸载软件包 + 删除配置/数据/证书/防火墙规则/APT源,
# 比 uninstall_sing_box() 激进得多 (那个只卸载 sing-box 软件包本身, 配置和
# 节点数据是故意保留的)。这里是"这台机器上再也不需要这个脚本管理的任何东西"
# 场景下用的, 不可逆, 全程二次确认。
# ===========================================================================
purge_all() {
  require_root
  warn "即将彻底清除 sing-box-vps 管理的全部内容:"
  printf '  - sing-box / cloudflared / cloudflare-warp / certbot 软件包\n'
  printf '  - %s (配置)\n' "$CONFIG_DIR"
  printf '  - %s (节点记录/订阅/备份/日志)\n' "$STATE_DIR"
  printf '  - %s (Cloudflare Tunnel 配置)\n' "$CF_CONFIG_DIR"
  printf '  - systemd unit / logrotate / cron / certbot 续期钩子\n'
  printf '  - 本脚本自建的 APT 源与密钥\n'
  printf '  - 本脚本开过的防火墙放行规则 (iptables/ip6tables/nftables)\n'
  warn "此操作不可逆, 且不会创建任何备份。"
  local confirm_text
  read -e -r -p "请输入大写 DELETE 以确认继续: " confirm_text
  [[ $confirm_text == DELETE ]] || { warn "输入不匹配, 已取消。"; return 0; }

  info "停止并禁用相关服务..."
  systemctl disable --now sing-box sing-box-vps-sub cloudflared warp-svc 2>/dev/null || true

  info "卸载软件包 (sing-box / cloudflared / cloudflare-warp)..."
  apt-get remove --purge -y sing-box cloudflared cloudflare-warp 2>/dev/null || true

  if command -v certbot >/dev/null 2>&1; then
    if confirm "是否一并卸载 certbot 并删除全部证书 (如果这台机器上 certbot 还给其他站点用, 选否)" N; then
      apt-get remove --purge -y certbot 2>/dev/null || true
      rm -rf /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal
      rm -f /etc/letsencrypt/renewal-hooks/deploy/restart-sing-box
      rm -f /etc/cron.d/sing-box-vps-certbot
      systemctl disable --now certbot.timer 2>/dev/null || true
    else
      rm -f /etc/letsencrypt/renewal-hooks/deploy/restart-sing-box
      info "已跳过 certbot/证书清理, 仅移除了本脚本的续期钩子。"
    fi
  fi
  apt-get autoremove -y 2>/dev/null || true

  info "删除脚本自身与快捷命令..."
  rm -f "$MANAGER_PATH" "$SHORTCUT_PATH"

  info "删除配置/数据/日志目录..."
  rm -rf "$CONFIG_DIR" "$STATE_DIR" "$CF_CONFIG_DIR"
  rm -rf /root/.cloudflared "${HOME}/.cloudflared" 2>/dev/null || true
  rm -f "$LOCK_FILE"

  info "删除 systemd unit..."
  rm -f /etc/systemd/system/cloudflared.service "$SUB_HTTPD_UNIT"
  systemctl daemon-reload

  info "删除 logrotate 配置..."
  rm -f "$LOGROTATE_FILE"

  info "删除脚本自建的 APT 源与密钥..."
  rm -f /etc/apt/sources.list.d/sagernet.sources
  rm -f /etc/apt/sources.list.d/cloudflared.list
  rm -f /etc/apt/sources.list.d/cloudflare-client.list
  rm -f /etc/apt/keyrings/sagernet.asc
  rm -f /usr/share/keyrings/cloudflare-public-v2.gpg
  rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  apt-get update -qq 2>/dev/null || true

  if confirm "是否清空本脚本开过的防火墙规则 (会 flush iptables INPUT 链, 如果机器上还有其他服务依赖 iptables 规则, 选否改成手动清理)" N; then
    iptables -F INPUT 2>/dev/null || true
    ip6tables -F INPUT 2>/dev/null || true
    nft delete table inet "$NFT_TABLE" 2>/dev/null || true
    persist_iptables_rules
    ok "防火墙规则已清空。"
  else
    warn "已跳过防火墙清理, 请自行用 'iptables -L INPUT -n --line-numbers' 检查并手动删除本脚本开过的规则。"
  fi

  ok "彻底清除完成。云厂商安全组规则 (如有) 本脚本管不到, 仍需自行去控制台清理。"
}
# ===========================================================================
# 终端交互层 (v0.1.0)
#   显示宽度 / 截断 / 进度包装 / 剪贴板 / 徽标 / 二维码 / 结果块
# ===========================================================================
UI_WV=0
# 计算显示宽度 (全角/宽字符/emoji 记 2 列), 结果写入 UI_WV, 避免子进程开销
ui_wv() {
  local s=$1 i ch cp w=0 n=${#1} hi=0
  if (( ! UI_UTF8 )); then
    # 非 UTF-8 locale 下 bash 按字节计数: 高位字节每 3 个约折合 1 个全角字符 (2 列)
    for ((i=0; i<n; i++)); do
      ch=${s:i:1}; printf -v cp '%d' "'$ch" 2>/dev/null || cp=0
      if (( cp >= 128 || cp < 0 )); then hi=$((hi+1)); else w=$((w+1)); fi
    done
    UI_WV=$(( w + hi * 2 / 3 )); return 0
  fi
  for ((i=0; i<n; i++)); do
    ch=${s:i:1}
    printf -v cp '%d' "'$ch" 2>/dev/null || cp=0
    if (( (cp >= 0x2e80 && cp <= 0xa4cf) || (cp >= 0xac00 && cp <= 0xd7a3) || (cp >= 0xf900 && cp <= 0xfaff) \
       || (cp >= 0xfe30 && cp <= 0xfe6f) || (cp >= 0xff00 && cp <= 0xff60) || (cp >= 0xffe0 && cp <= 0xffe6) \
       || (cp >= 0x1100 && cp <= 0x115f) || (cp >= 0x1f300 && cp <= 0x1faff) )); then
      w=$((w+2))
    else
      w=$((w+1))
    fi
  done
  UI_WV=$w
}
ui_w() { ui_wv "$1"; printf '%s' "$UI_WV"; }

# ui_pad <文本> <目标宽度>: 按显示宽度右侧补空格
ui_pad() {
  local pad
  ui_wv "$1"
  pad=$(( $2 - UI_WV ))
  if (( pad < 0 )); then pad=0; fi
  printf '%s%*s' "$1" "$pad" ''
}

# ui_trunc <文本> <最大宽度>: 超宽时截断并加省略号
ui_trunc() {
  local s=$1 max=$2 i ch out="" w=0 cw
  ui_wv "$s"
  if (( UI_WV <= max )); then printf '%s' "$s"; return 0; fi
  for ((i=0; i<${#s}; i++)); do
    ch=${s:i:1}
    ui_wv "$ch"; cw=$UI_WV
    if (( w + cw > max - 1 )); then break; fi
    out+=$ch; w=$((w+cw))
  done
  printf '%s%s' "$out" "$G_ELL"
}

# 终端宽度: 每次重绘重新读取, 窗口大小变化后自动适配
ui_cols() {
  local c=""
  if [[ -t 1 || -t 2 ]]; then c=$(stty size 2>/dev/null </dev/tty | awk '{print $2}' || true); fi
  if ! [[ $c =~ ^[0-9]+$ ]] || (( c < 1 )); then c=${COLUMNS:-80}; fi
  if ! [[ $c =~ ^[0-9]+$ ]] || (( c < 1 )); then c=80; fi
  printf '%s' "$c"
}

ui_hr() {
  local w line cols
  cols=$(ui_cols); w=$cols
  if (( w > 62 )); then w=62; fi
  printf -v line '%*s' "$w" ''
  printf '%s%s%s\n' "$DIM" "${line// /$G_HH}" "$NC"
}

ui_pause() {
  local msg=${1-"── 按回车返回菜单 ──"}
  [[ -t 0 && -t 1 ]] || return 0
  read -e -r -p "$msg" _ || true
  return 0
}

# ---------------------------------------------------------------------------
# 长操作进度: 屏幕只留一行 "⠹ 步骤名 ... 耗时", 完成改 ✓, 详细输出进日志,
# 失败自动展开日志最后 10 行并给出日志路径。进度写 stderr, 因此可在 $(...) 内使用。
#   UI_SOFT=1  失败只显示 ! (不展开日志, 由调用者决定)
#   UI_SOFT=2  无论返回码都显示 ✓ (如测速被超时截断仍属正常)
# ---------------------------------------------------------------------------
UI_IN_RUN=""
UI_BG_PID=""
ui_now_us() {
  local t=${EPOCHREALTIME:-}
  if [[ -n $t ]]; then t=${t/[.,]/}; printf '%s' "$t"; else printf '%s' "$(( $(date +%s) * 1000000 ))"; fi
}

ui_run() {
  local name=$1; shift
  local soft=${UI_SOFT:-0} cap=${UI_CAPTURE:-}
  if [[ -n $UI_IN_RUN ]]; then     # 嵌套调用: 直接执行, 输出并入外层日志
    if [[ -n $cap ]]; then "$@" >"$cap" || true; else "$@"; fi
    return 0
  fi
  local tmp rc=0 t0 t1 el pid i=0 istty=0
  [[ -t 2 ]] && istty=1
  tmp=$(mktemp)
  t0=$(ui_now_us)
  if [[ -n $cap ]]; then
    ( UI_IN_RUN=1; trap - ERR; "$@" ) >"$cap" 2>"$tmp" </dev/null &
  else
    ( UI_IN_RUN=1; trap - ERR; "$@" ) >"$tmp" 2>&1 </dev/null &
  fi
  pid=$!; UI_BG_PID=$pid
  if (( istty )); then
    while kill -0 "$pid" 2>/dev/null; do
      t1=$(ui_now_us); el=$(( t1 - t0 ))
      printf '\r\033[K %s%s%s %s %s %s%d.%ds%s' "$CYAN" "${G_SPIN[i % ${#G_SPIN[@]}]}" "$NC" "$name" "$G_ELL" \
        "$DIM" $((el/1000000)) $(((el%1000000)/100000)) "$NC" >&2
      i=$((i+1))
      sleep 0.1
    done
    printf '\r\033[K' >&2
  else
    printf ' %s %s\n' "$G_ELL" "$name" >&2
  fi
  wait "$pid" || rc=$?
  UI_BG_PID=""
  t1=$(ui_now_us); el=$(( t1 - t0 ))
  if (( rc == 0 || soft == 2 )); then
    printf ' %s%s%s %s  %s%d.%ds%s\n' "$GREEN" "$G_OK" "$NC" "$name" "$DIM" $((el/1000000)) $(((el%1000000)/100000)) "$NC" >&2
  elif (( soft == 1 )); then
    printf ' %s%s%s %s  %s(未完成, 状态码 %s)%s\n' "$YELLOW" "$G_WARN" "$NC" "$name" "$DIM" "$rc" "$NC" >&2
  else
    printf ' %s%s%s %s  %s%d.%ds%s\n' "$RED" "$G_X" "$NC" "$name" "$DIM" $((el/1000000)) $(((el%1000000)/100000)) "$NC" >&2
    tail -n 10 "$tmp" 2>/dev/null | while IFS= read -r line; do printf '   %s%s%s %s\n' "$DIM" "$G_BAR" "$NC" "$line" >&2; done
    printf '   %s%s%s 完整日志: %s\n' "$DIM" "$G_END" "$NC" "$LOG_FILE" >&2
  fi
  { printf '%s [STEP rc=%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$rc" "$name"; cat "$tmp"; } >> "$LOG_FILE" 2>/dev/null || true
  rm -f "$tmp"
  return "$rc"
}

# 捕获命令 stdout 并原样输出 (进度走 stderr), 始终返回 0
ui_run_cap() {
  local name=$1; shift
  local f
  f=$(mktemp)
  UI_CAPTURE=$f UI_SOFT=2 ui_run "$name" "$@" || true
  cat "$f"
  rm -f "$f"
}

_apt_update_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq "$@"
}

# ---------------------------------------------------------------------------
# 剪贴板 (OSC 52, tmux/screen 自动封装; 不支持时静默无效, 始终保留 p 显示完整链接)
# ---------------------------------------------------------------------------
ui_copy() {
  local text=$1 b64 seq
  if [[ ! -t 1 ]]; then warn "非终端环境, 无法写入剪贴板; 请用 p 显示完整链接。"; return 0; fi
  b64=$(printf '%s' "$text" | base64 | tr -d '\n')
  if [[ -n ${TMUX:-} ]]; then
    seq=$'\033Ptmux;\033\033]52;c;'"$b64"$'\a\033\\'
  elif [[ ${TERM:-} == screen* ]]; then
    seq=$'\033P\033]52;c;'"$b64"$'\a\033\\'
  else
    seq=$'\033]52;c;'"$b64"$'\a'
  fi
  printf '%s' "$seq"
  ok "已发送到终端剪贴板 (OSC 52); 若粘贴为空说明终端不支持, 请用 p 显示完整链接。"
  return 0
}

# 连接串过长时中间截断
ui_show_uri() {
  local uri=$1 cols n
  cols=$(ui_cols)
  ui_wv "$uri"
  if (( UI_WV > cols - 2 )); then
    n=$(( cols - 16 ))
    if (( n < 12 )); then n=12; fi
    printf '%s%s%s%s%s\n' "${uri:0:n}" "$G_ELL" "${uri: -8}" "$DIM" " [已截断]${NC}"
  else
    printf '%s\n' "$uri"
  fi
}

# ---------------------------------------------------------------------------
# 二维码: <60 列或二维码比终端宽时跳过渲染, 只提示 PNG 路径
# ---------------------------------------------------------------------------
show_qrcode() {
  local uri=$1 tag=${2:-node} cols png qrw
  if ! command -v qrencode >/dev/null 2>&1; then
    UI_SOFT=1 ui_run "安装 qrencode" _apt_update_install qrencode || true
  fi
  if ! command -v qrencode >/dev/null 2>&1; then
    warn "qrencode 未安装, 已跳过二维码渲染。"
    return 0
  fi
  png="${QR_CACHE_DIR}/${tag}.png"
  qrencode -t PNG -o "$png" -m 1 <<<"$uri" 2>/dev/null || true
  cols=$(ui_cols)
  if (( cols < 60 )); then
    warn "终端过窄 (<60 列), 已跳过二维码渲染。"
    printf '  PNG: %s\n' "$png"
    return 0
  fi
  qrw=$(qrencode -t ASCII -m 1 <<<"$uri" 2>/dev/null | awk 'NR==1{print int(length($0)/2)}' || true)
  if [[ $qrw =~ ^[0-9]+$ ]] && (( qrw > cols )); then
    warn "二维码宽 ${qrw} 列, 超过终端宽度 ${cols}, 已跳过渲染。"
    printf '  PNG: %s\n' "$png"
    return 0
  fi
  printf '\n'
  if (( UI_COLOR && UI_UTF8 )); then qrencode -t ANSIUTF8 -m 1 <<<"$uri"
  elif (( UI_UTF8 )); then qrencode -t UTF8 -m 1 <<<"$uri"
  else qrencode -t ASCII -m 1 <<<"$uri"; fi
  printf '  %sPNG: %s%s\n' "$DIM" "$png" "$NC"
  return 0
}

print_result_block() {
  local title=$1 uri=$2 tag=$3 type port proto list="" fam a
  PENDING_TAG=""
  printf '\n%s%s%s 客户端连接串:\n' "$BOLD" "$title" "$NC"
  ui_show_uri "$uri"
  type=$(_conn_field "$tag" type 2>/dev/null || true)
  port=$(_conn_field "$tag" port 2>/dev/null || true)
  if [[ -n $type && $type != vless-ws-cloudflare-tunnel && $port =~ ^[0-9]+$ ]]; then
    for proto in $(_proto_fw_protocols "$type"); do list+="${list:+, }${port}/${proto}"; done
    case $type in
      *-v4) fam="仅 IPv4 一条" ;;
      *-v6) fam="仅 IPv6 一条" ;;
      *)    fam="IPv4 与 IPv6 各一条" ;;
    esac
    printf '%s%s%s 云厂商安全组还需手动放行 %s%s%s（%s）\n' "$YELLOW" "$G_WARN" "$NC" "$BOLD" "$list" "$NC" "$fam"
  fi
  printf '\n'
  UI_SOFT=1 ui_run "刷新订阅文件" sub_build_all || warn "订阅文件自动刷新失败, 可稍后运行 'sb sub' 手动刷新。"
  if [[ ! ( -t 0 && -t 1 ) ]]; then printf '%s\n' "$uri"; return 0; fi
  printf '%sc%s 复制  %sp%s 完整链接  %sq%s 二维码  %s回车 返回%s\n' "$CYAN" "$NC" "$CYAN" "$NC" "$CYAN" "$NC" "$DIM" "$NC"
  while true; do
    read -e -r -p "> " a || break
    case ${a//[[:space:]]/} in
      c|C) ui_copy "$uri" ;;
      p|P) printf '\n%s\n\n' "$uri" ;;
      q|Q) show_qrcode "$uri" "$tag" ;;
      '')  break ;;
      *)   warn "未知操作 “${a}”, 可用: c / p / q / 回车" ;;
    esac
  done
  return 0
}

# ---------------------------------------------------------------------------
# 网络快照: 公网 IP + IPv4/IPv6 可用性探测, 一起缓存 300 秒, 菜单重绘不联网
# 缓存文件 5 行: 时间戳 / v4 / v6 / v4可用(0|1) / v6可用(0|1) (旧版 3 行缓存自动重测)
# ---------------------------------------------------------------------------
NET_V4=""; NET_V6=""; NET_V4OK=0; NET_V6OK=0
net_snapshot() {
  local now t="" v4="" v6="" o4="" o6="" tmp
  now=$(date +%s)
  if [[ -f $IP_CACHE_FILE ]]; then
    { read -r t; read -r v4; read -r v6; read -r o4; read -r o6; } <"$IP_CACHE_FILE" || true
    if [[ $t =~ ^[0-9]+$ ]] && (( now - t < 300 )) && [[ $o4 == [01] && $o6 == [01] ]]; then
      NET_V4=$v4; NET_V6=$v6; NET_V4OK=$o4; NET_V6OK=$o6
      return 0
    fi
  fi
  NET_V4=""; NET_V6=""; NET_V4OK=0; NET_V6OK=0
  if check_ipv4_egress; then NET_V4OK=1; NET_V4=$(detect_public_ip || true); fi
  if check_ipv6_egress; then NET_V6OK=1; NET_V6=$(detect_public_ipv6 || true); fi
  tmp=$(mktemp)
  printf '%s\n%s\n%s\n%s\n%s\n' "$now" "$NET_V4" "$NET_V6" "$NET_V4OK" "$NET_V6OK" >"$tmp" 2>/dev/null || true
  mv -f "$tmp" "$IP_CACHE_FILE" 2>/dev/null || rm -f "$tmp"
  return 0
}

# 服务器国旗缓存 1 天 (避免每次快速部署都联网)
get_cached_flag() {
  local f="${STATE_DIR}/flag_cache" now t="" flag=""
  now=$(date +%s)
  if [[ -f $f ]]; then
    { read -r t; read -r flag; } <"$f" || true
    if [[ $t =~ ^[0-9]+$ ]] && (( now - t < 86400 )) && [[ -n $flag ]]; then printf '%s' "$flag"; return 0; fi
  fi
  flag=$(ui_run_cap "识别服务器地区" get_server_flag)
  [[ -n $flag ]] || flag="🌐"
  printf '%s\n%s\n' "$now" "$flag" >"$f" 2>/dev/null || true
  printf '%s' "$flag"
}


# ---------------------------------------------------------------------------
# 品牌: LINONO 字样 (三档) + 徽标 (固定调色板 + 四分块字符预渲染)
#   徽标数据: 15 色调色板 (取自原图, 不混色) + 四分块字符; 每格 2 个 base64 字符
#   (前景色 4 位 / 背景色 4 位 / 掩码 4 位), 行间以 ':' 分隔, 约 1 KB。
#   半块字符后备版由同一份数据在运行时折算, 不另存常量。运行时不依赖任何图像工具。
# ---------------------------------------------------------------------------
readonly LOGO_QB='_M_M_M_M_M_M_M_M_M_M_M_M_M_M_M_M_MbYb-8n7R_M_M_M_M_M_M_M_M_M_M:_M_M_M_M_M_M_M_M_M_M_M_M_MbYbYb_b_8n4K7R_M_M_MfYfYfYfYfY_M_M_M:_M_M_M_M_M_M_M_M_M_MbUb-b_b_8n4I4K473RjUjQfPfPfPfPfPfXf_f_d3jY:_M_M_M_M_M_M_M_M_M_Mb-b_8n4K7_7_0q3T_M_M_M_M_M_M_M_M_MjWj_j_j_:_M_M_M_M_M_M_M_M_MbW8n4K7_7_470u3_3N_M_M_M_M_M_M_M_MrYhGj_jP_M:_M_M_MfYfYf_fP_M_M7W4K7_470u3_3_3R_M_M_M_M_M_M_MDYD-qrrTrN_M_M:_Mf-f_f_fP_M_M_M7W4K470u3_3_0j0hbN_M_M_M_MXUDQDPDPDN_M_M_M_M_M:f_d3dz_M_M_M_M7U7-470u3_0n4e4BbR_MXYXYXYXYXYXYXYDYDYDYDYDYDYDY:hzr_r_rY_M_M_M0s0u3_0n4e7jTYDYD-D_D_DBX_X_WnX_PIPIOsD3D3D3Db_M:_MBJWsDzX_XYUd3z3zUeUPjIj_hBr_qtC7ysysGbH_L_L_LcLcOXP_PPPN_M_M:_M_MXOXPfIfIfIf_dndjdjkYhjtev_v_xWz_z_z_z_yIGbHPHP_M_M_M_M_M_M:_M_M_M_M_M_M_M_MnOnPnPlPtuv_v_v_v_udzTzPzP_M_M_M_M_M_M_M_M_M_M'
readonly LOGO_QS='_M_M_M_M_M_M_M_M_M_MbUbY8r_M_M_M_M_M_M_M:_M_M_M_M_M_M_MbYb-8n4I477N_M_MfPfPf_fYjQ:_M_M_M_M_M_Mb-b_4K7_0q3N_M_M_M_M_MjWj_jT:_M_M_MfYfPfN4I7_0s0u3T_M_M_M_MDUDYrTjP_M:fUf_fP_M_M7W470u0n4ebN_M_M_MDPDP_M_M_M_M:oYr_rQ_M3U0u3_0l7j4xDYDIX_X_X_PID3DbD7DP:DOXXWuXZUd0PfIgXhTpPC3z_yBGZGYKHLdPP_M_M:_M_M_MfOfPfPnPlTtuv_udxPzPzPzP_M_M_M_M_M'
readonly -a BANNER_BIG=(
  '██╗     @██╗@███╗   ██╗@ ██████╗ @███╗   ██╗@ ██████╗'
  '██║     @██║@████╗  ██║@██╔═══██╗@████╗  ██║@██╔═══██╗'
  '██║     @██║@██╔██╗ ██║@██║   ██║@██╔██╗ ██║@██║   ██║'
  '██║     @██║@██║╚██╗██║@██║   ██║@██║╚██╗██║@██║   ██║'
  '███████╗@██║@██║ ╚████║@╚██████╔╝@██║ ╚████║@╚██████╔╝'
  '╚══════╝@╚═╝@╚═╝  ╚═══╝@ ╚═════╝ @╚═╝  ╚═══╝@ ╚═════╝'
)
readonly -a BANNER_COMP=(
  '█   @▀█▀ @█▄ █ @█▀█ @█▄ █ @█▀█'
  '█▄▄ @▄█▄ @█ ▀█ @█▄█ @█ ▀█ @█▄█'
)
readonly -a BANNER_ASCII=(
  ' _     ___ _   _  ___  _   _  ___ '
  '| |   |_ _| \ | |/ _ \| \ | |/ _ \'
  '| |    | ||  \| | | | |  \| | | | |'
  '| |___ | || |\  | |_| | |\  | |_| |'
  '|_____|___|_| \_|\___/|_| \_|\___/'
)
readonly -a LOGO_RGB=("0;52;233" "0;116;253" "3;175;253" "252;29;16" "253;85;13" "4;155;56" "253;157;5" "3;177;60" "5;197;59" "253;213;7" "29;213;52" "73;222;48" "129;232;35" "234;236;190" "253;245;25")
readonly -a LOGO_C256=(26 33 39 196 202 29 214 35 41 220 41 77 112 193 226)
readonly -a LOGO_C16=(34 34 36 31 91 32 33 32 32 33 32 92 33 37 33)
readonly -a LOGO_QCH=(" " "▘" "▝" "▀" "▖" "▌" "▞" "▛" "▗" "▚" "▐" "▜" "▄" "▙" "▟" "█")
readonly LOGO_A64="0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_"

# 把一行 '@' 分段的字样按字母着色输出 (无颜色时 UI_LC 为空串, 自然降级)
ui_brand_line() {
  local line=$1 i out="" seg
  local -a segs=()
  IFS='@' read -ra segs <<<"$line"
  for i in "${!segs[@]}"; do
    seg=${segs[i]}
    if (( i < 6 )); then out+="${UI_LC[i]}${BOLD}${seg}${NC}"; else out+=$seg; fi
  done
  printf '%s' "$out"
}

ui_brand() {   # 一行 LINONO (标题栏用)
  local i l=(L I N O N O)
  for i in 0 1 2 3 4 5; do printf '%s%s%s' "${UI_LC[i]}${BOLD}" "${l[i]}" "$NC"; done
}

# 按宽度选择字样: >=60 大号, >=30 紧凑两行, 更窄单行; 非 UTF-8 用纯 ASCII 版
ui_banner() {
  local cols=$1 line
  if (( ! UI_UTF8 )); then
    if (( cols >= 40 )); then
      for line in "${BANNER_ASCII[@]}"; do printf ' %s\n' "$line"; done
    elif (( cols >= 22 )); then printf ' |linono * singbox vps\n'
    else printf ' ln> linono\n'; fi
    return 0
  fi
  if (( cols >= 60 )); then
    for line in "${BANNER_BIG[@]}"; do printf ' %s\n' "$(ui_brand_line "$line")"; done
  elif (( cols >= 30 )); then
    for line in "${BANNER_COMP[@]}"; do printf ' %s\n' "$(ui_brand_line "$line")"; done
  elif (( cols >= 22 )); then
    printf ' %s▌%slinono · singbox vps\n' "${UI_LC[2]}" "$NC"
  else
    printf ' ln› linono\n'
  fi
  return 0
}

# 把徽标解码到 UI_LOGO_ROWS (每行已含转义码) 与 UI_LOGO_W; 不满足降级条件返回 1
UI_LOGO_ROWS=(); UI_LOGO_W=0
ui_logo_build() {
  local size=$1 mode=quad data row i n t hi lo v fg bg m seq out top bot ul ur ll lr ch
  local -a rows=()
  UI_LOGO_ROWS=(); UI_LOGO_W=0
  (( UI_COLOR && UI_UTF8 )) || return 1
  # 四分块字符在个别旧终端 (Linux 控制台 / vt 系列) 有细缝: 退回半块字符版
  if [[ ${SB_LOGO_HALF:-0} == 1 || ${TERM:-} == linux || ${TERM:-} == vt* ]]; then mode=half; fi
  if [[ $size == big ]]; then data=$LOGO_QB; else data=$LOGO_QS; fi
  IFS=':' read -ra rows <<<"$data"
  for row in "${rows[@]}"; do
    out=""; n=${#row}
    for ((i=0; i<n; i+=2)); do
      t=${LOGO_A64%%"${row:i:1}"*}; hi=${#t}
      t=${LOGO_A64%%"${row:i+1:1}"*}; lo=${#t}
      v=$(( hi*64 + lo )); fg=$(( (v>>8)&15 )); bg=$(( (v>>4)&15 )); m=$(( v&15 ))
      if (( fg == 15 || m == 0 )); then out+=" "; continue; fi
      if [[ $mode == quad ]]; then
        ui_logo_code fg "$fg"; seq=$'\033['"$UI_LCODE"
        if (( bg != 15 )); then ui_logo_code bg "$bg"; seq+=";$UI_LCODE"; fi
        out+="${seq}m${LOGO_QCH[m]}"$'\033[0m'
      else
        # 由四分块数据折算半块: 上半取左上/右上, 下半取左下/右下 (优先取有色的一侧)
        ul=$(( (m&1) ? fg : bg )); ur=$(( (m&2) ? fg : bg )); ll=$(( (m&4) ? fg : bg )); lr=$(( (m&8) ? fg : bg ))
        top=$ul; if (( top == 15 )); then top=$ur; fi
        bot=$ll; if (( bot == 15 )); then bot=$lr; fi
        if (( top == 15 && bot == 15 )); then out+=" "; continue; fi
        if (( top == 15 )); then ch="▄"; ui_logo_code fg "$bot"; seq=$'\033['"$UI_LCODE"
        elif (( bot == 15 )); then ch="▀"; ui_logo_code fg "$top"; seq=$'\033['"$UI_LCODE"
        elif (( top == bot )); then ch="█"; ui_logo_code fg "$top"; seq=$'\033['"$UI_LCODE"
        else ch="▀"; ui_logo_code fg "$top"; seq=$'\033['"$UI_LCODE"; ui_logo_code bg "$bot"; seq+=";$UI_LCODE"; fi
        out+="${seq}m${ch}"$'\033[0m'
      fi
    done
    UI_LOGO_W=$(( n/2 ))
    UI_LOGO_ROWS+=("$out")
  done
  return 0
}

# ui_logo_code <fg|bg> <调色板序号 0-6> -> UI_LCODE (真彩 / 256 色量化 / 16 色)
UI_LCODE=""
ui_logo_code() {
  local kind=$1 k=$2 base
  if (( UI_TRUECOLOR )); then
    if [[ $kind == fg ]]; then UI_LCODE="38;2;${LOGO_RGB[k]}"; else UI_LCODE="48;2;${LOGO_RGB[k]}"; fi
  elif (( UI_256 )); then
    if [[ $kind == fg ]]; then UI_LCODE="38;5;${LOGO_C256[k]}"; else UI_LCODE="48;5;${LOGO_C256[k]}"; fi
  else
    base=${LOGO_C16[k]}
    if [[ $kind == fg ]]; then UI_LCODE=$base; else UI_LCODE=$(( base + 10 )); fi
  fi
}

# 可选: 终端支持图片协议且用户提供了 PNG (SB_LOGO_PNG=/path/logo.png) 时显示原图
ui_logo_image() {
  local png=${SB_LOGO_PNG:-} b64 chunk first=1
  [[ -n $png && -r $png && -t 1 ]] || return 1
  b64=$(base64 -w0 "$png" 2>/dev/null) || return 1
  if [[ ${TERM_PROGRAM:-} == iTerm.app || ${TERM_PROGRAM:-} == WezTerm ]]; then
    printf '\033]1337;File=inline=1;width=24;preserveAspectRatio=1:%s\a\n' "$b64"
    return 0
  fi
  if [[ -n ${KITTY_WINDOW_ID:-} || ${TERM:-} == xterm-kitty ]]; then
    while [[ -n $b64 ]]; do
      chunk=${b64:0:4096}; b64=${b64:4096}
      local more=0; [[ -n $b64 ]] && more=1
      if (( first )); then printf '\033_Ga=T,f=100,c=24,m=%d;%s\033\\' "$more" "$chunk"; first=0
      else printf '\033_Gm=%d;%s\033\\' "$more" "$chunk"; fi
    done
    printf '\n'
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# 状态收集 (一次 systemctl is-active + 一次 jq) 与标题栏
# ---------------------------------------------------------------------------
UI_ST_INST=0; UI_ST_RUN=0; UI_ST_VER=""; UI_ST_NODES=0; UI_VER_CACHE=""
ui_status_collect() {
  UI_ST_INST=0; UI_ST_RUN=0; UI_ST_NODES=0
  if command -v sing-box >/dev/null 2>&1; then
    UI_ST_INST=1
    if systemctl is-active --quiet sing-box 2>/dev/null; then UI_ST_RUN=1; fi
    if [[ -z $UI_VER_CACHE ]]; then
      UI_VER_CACHE=$(sing-box version 2>/dev/null | awk 'NR==1{print $3}' || true)
    fi
    UI_ST_VER=$UI_VER_CACHE
  fi
  if [[ -f $STATE_FILE ]]; then
    UI_ST_NODES=$(jq '.connections | length' "$STATE_FILE" 2>/dev/null || true)
    [[ $UI_ST_NODES =~ ^[0-9]+$ ]] || UI_ST_NODES=0
  fi
  net_snapshot
}

# 状态文字: 设置 UI_ST_DOT / UI_ST_COL / UI_ST_TXT
ui_status_text() {
  if (( ! UI_ST_INST )); then UI_ST_DOT=$G_OFF; UI_ST_COL=$YELLOW; UI_ST_TXT="未安装"
  elif (( UI_ST_RUN )); then UI_ST_DOT=$G_DOT; UI_ST_COL=$GREEN; UI_ST_TXT="运行中 ${UI_ST_VER}"
  else UI_ST_DOT=$G_OFF; UI_ST_COL=$RED; UI_ST_TXT="未运行"; fi
}

ui_addr_text() {   # 设置 UI_A4 / UI_A6 (纯文本)
  if (( NET_V4OK )); then UI_A4="v4 ${NET_V4:-可用}"; else UI_A4="v4 ${G_SKIP}"; fi
  if (( NET_V6OK )); then UI_A6="v6 ${NET_V6:-可用}"; else UI_A6="v6 ${G_SKIP}"; fi
}

ui_status_line() {
  local cols plain head addr a6
  cols=$(ui_cols)
  ui_status_collect
  ui_status_text; ui_addr_text
  plain="LINONO ${G_H} ${UI_ST_DOT} ${UI_ST_TXT}  节点 ${UI_ST_NODES}  ${UI_A4}  ${UI_A6}"
  ui_wv "$plain"
  head="$(ui_brand) ${DIM}${G_H}${NC} ${UI_ST_COL}${UI_ST_DOT}${NC} ${UI_ST_TXT}  节点 ${BOLD}${UI_ST_NODES}${NC}"
  if (( UI_WV <= cols )); then
    printf '%s  %sv4%s%s  %sv6%s%s\n' "$head" "$DIM" "$NC" "${UI_A4#v4}" "$DIM" "$NC" "${UI_A6#v6}"
  else
    a6=$(ui_trunc "${UI_A6#v6 }" $(( cols - 22 > 8 ? cols - 22 : 8 )))
    printf '%s\n  %sv4%s%s  %sv6%s %s\n' "$head" "$DIM" "$NC" "${UI_A4#v4}" "$DIM" "$NC" "$a6"
  fi
  return 0
}

# 启动画面 (进入交互菜单的第一次显示): 左徽标, 右紧凑字样 + 版本 + 状态 + 地址
ui_splash() {
  local cols size sub i n j pad rw
  local -a right=() comp=() base=()
  cols=$(ui_cols)
  ui_status_collect; ui_status_text; ui_addr_text
  size=""; if (( cols >= 64 )); then size=big; elif (( cols >= 40 )); then size=small; fi
  sub="singbox VPS 双栈智能管理 v${SCRIPT_VERSION}"
  if (( cols < 50 )); then sub="singbox VPS v${SCRIPT_VERSION}"; fi
  if [[ -n $size ]] && { ui_logo_image || ui_logo_build "$size"; }; then
    if (( ${#UI_LOGO_ROWS[@]} == 0 )); then   # 已显示原图: 文字放在图下方
      ui_banner "$cols"
      printf ' %s%s%s\n' "$BOLD" "$sub" "$NC"
      printf ' %s%s%s %s\n' "$UI_ST_COL" "$UI_ST_DOT" "$NC" "$UI_ST_TXT  节点 ${UI_ST_NODES}"
      printf ' %s\n %s\n\n' "$UI_A4" "$UI_A6"
      return 0
    fi
    rw=$(( cols - UI_LOGO_W - 2 ))
    if (( rw >= 26 )); then
      comp[0]=$(ui_brand_line "${BANNER_COMP[0]}"); comp[1]=$(ui_brand_line "${BANNER_COMP[1]}")
    else   # 右侧放不下紧凑字样: 退为一行 LINONO
      comp[0]=$(ui_brand); comp[1]=""
    fi
    n=${#UI_LOGO_ROWS[@]}
    local st="${UI_ST_COL}${UI_ST_DOT}${NC} ${UI_ST_TXT}  节点 ${BOLD}${UI_ST_NODES}${NC}"
    if (( n >= 9 )); then
      base=("" "${comp[0]}" "${comp[1]}" "" "${BOLD}${sub}${NC}" "" "$st" "${DIM}v4${NC}${UI_A4#v4}" "${DIM}v6${NC}${UI_A6#v6}")
    else
      base=("${comp[0]}" "${comp[1]}" "${BOLD}${sub}${NC}" "$st" "${DIM}v4${NC}${UI_A4#v4}" "${DIM}v6${NC}${UI_A6#v6}")
    fi
    pad=$(( (n - ${#base[@]}) / 2 )); if (( pad < 0 )); then pad=0; fi
    printf '\n'
    for ((i=0; i<n; i++)); do
      j=$(( i - pad ))
      if (( j >= 0 && j < ${#base[@]} )); then right[i]=${base[j]}; else right[i]=""; fi
      printf '%s  %s\n' "${UI_LOGO_ROWS[i]}" "${right[i]}"
    done
    printf '\n'
    return 0
  fi
  # 无徽标 (非 UTF-8 / 非终端 / NO_COLOR / 过窄): 只显示字样
  printf '\n'
  ui_banner "$cols"
  printf ' %s%s%s\n' "$BOLD" "$sub" "$NC"
  printf ' %s%s%s %s  节点 %s\n' "$UI_ST_COL" "$UI_ST_DOT" "$NC" "$UI_ST_TXT" "$UI_ST_NODES"
  printf ' %s  %s\n\n' "$UI_A4" "$UI_A6"
  return 0
}


# ===========================================================================
# 数据驱动菜单: 渲染 / 分发 / 帮助文本 全部由这一张表生成
#   字段: 类型|分组|编号|小节|标题|说明|函数(可带参数)|CLI 命令名|标志
#   类型: G=一级菜单项  I=二级菜单项   编号 '-' = 不出现在菜单, 仅保留 CLI
#   标志: M=在主 shell 内运行 (自带循环的子菜单)  P=成功后停住等回车 (只读输出)
#         N=CLI 下不持有互斥锁 (只读命令)   S=醒目标记 (★)
#   约定: 字段内不得出现 '|'; CLI 为 '-' 表示没有对应命令行子命令
# ===========================================================================
readonly -a SB_MENU=(
  "G|1|1||新建节点|快速部署 / 14 种协议|ui_group_menu 1|-|M"
  "G|2|2||节点列表|查看 / 二维码 / 编辑 / 删除|node_list_menu|nodes|M"
  "G|3|3||订阅与分发|Base64 / Clash / sing-box|subscription_menu|sub|"
  "G|4|4||出站与穿透|WARP / Cloudflare Tunnel|ui_group_menu 4|-|M"
  "G|5|5||诊断与测速|体检 / 对账 / 日志 / 测速|ui_group_menu 5|-|M"
  "G|6|6||系统维护|证书 / BBR / 备份 / 升级|ui_group_menu 6|-|M"
  "I|1|1||快速部署 VLESS Reality|全部默认值, 回车即完成|deploy_quick_reality|quick|S"
  "I|1|2|Reality|Reality 自定义||deploy_vless_reality_unified|-|"
  "I|1|3|Reality|Reality gRPC||deploy_vless_reality_grpc|reality-grpc|"
  "I|1|4|Reality|ShadowTLS v3 + SS2022||deploy_shadowtls_ss2022|shadowtls|"
  "I|1|5|无需域名|Shadowsocks 2022 [UDP]||deploy_shadowsocks|ss|"
  "I|1|6|无需域名|Snell [需 sing-box ≥ 1.14]||deploy_snell|snell|"
  "I|1|7|需要域名 + 证书|Trojan||deploy_trojan|trojan|"
  "I|1|8|需要域名 + 证书|VLESS TLS||deploy_vless|vless|"
  "I|1|9|需要域名 + 证书|Hysteria2 [UDP]||deploy_hysteria2|hy2|"
  "I|1|10|需要域名 + 证书|TUIC v5 [UDP]||deploy_tuic|tuic|"
  "I|1|11|需要域名 + 证书|AnyTLS||deploy_anytls|anytls|"
  "I|1|12|需要域名 + 证书|NaiveProxy||deploy_naive|naive|"
  "I|1|13|穿透|Cloudflare Tunnel + VLESS WS||deploy_cloudflare_tunnel|-|"
  "I|4|1||Cloudflare WARP|出站 WARP 管理|warp_menu|warp|"
  "I|4|2||Cloudflare Tunnel 管理|新建 / 状态 / 日志 / 重启 / 卸载|cf_tunnel_menu|cftunnel|"
  "I|4|3||升级 cloudflared|检查 / 升级版本|upgrade_cloudflared|cf-upgrade|"
  "I|5|1||服务状态与网络栈|systemd 状态 / 监听 / 公网 IP|show_status|status|PN"
  "I|5|2||运行日志|sing-box 最近 150 行|show_logs|logs|PN"
  "I|5|3||校验配置并重启|sing-box check + restart|validate_and_restart|check|"
  "I|5|4||系统健康检查|服务 / WARP / 出站规则|health_check|health|PN"
  "I|5|5||系统诊断|端口 / DNS / BBR / 防火墙 / 配置|run_diagnostics|diag|PN"
  "I|5|6||检查并修复孤儿节点|对账 config 与连接记录 (reconcile)|reconcile_nodes|reconcile|"
  "I|5|7||服务器测速|延迟 / 下载 / 上传|run_speedtest|speedtest|P"
  "I|6|1||证书管理|到期查看 / 立即续期|cert_management_menu|certs|"
  "I|6|2||启用 BBR|拥塞控制|enable_bbr|bbr|"
  "I|6|3||恢复配置备份|回滚到最近一次备份|restore_backup|rollback|"
  "I|6|4||安装 / 修复 sing-box 环境|官方 APT 源|install_sing_box|install|"
  "I|6|5||更新 sing-box 核心|apt 升级|upgrade_sing_box|upgrade|"
  "I|6|6||更新本脚本|从 GitHub 拉取|update_manager|self-update|"
  "I|6|7||卸载 sing-box|保留配置与数据|uninstall_sing_box|uninstall|"
  "I|6|8||彻底清除|软件包+配置+证书+防火墙, 不可逆|purge_all|purge|"
  "I|0|-||部署 VLESS Reality (双栈)||deploy_vless_reality_unified dual|reality-dual|"
  "I|0|-||部署 VLESS Reality (仅 IPv4)||deploy_vless_reality_unified v4|reality-v4|"
  "I|0|-||部署 VLESS Reality (仅 IPv6)||deploy_vless_reality_unified v6|reality-v6|"
  "I|0|-||查看客户端连接串||show_connections|links|PN"
  "I|0|-||查看节点二维码||show_connection_qrcode|qrcode|"
  "I|0|-||删除入站节点||remove_inbound|remove|"
  "I|0|-||编辑节点 (改名/端口/地址/域名)||node_edit_menu|edit|"
)

R_FUNC=""; R_FLAGS=""; MENU_INT=0; INT_COUNT=0; SEL_TAG=""; MENU_LVL=sub

# 提示符处按 Ctrl+C: 注意 `read -e` 收到被 trap 的 SIGINT 后不会自行返回, 必须在 trap 内
# `return` 才能跳出当前菜单函数。主菜单需连按两次才退出; 子菜单/子提示直接回上一级。
UI_INT_TRAP='if ui_int_hit; then return 0; fi'
ui_int_hit() {
  MENU_INT=1
  if [[ $MENU_LVL == main ]]; then
    INT_COUNT=$((INT_COUNT+1))
    if (( INT_COUNT >= 2 )); then printf '\n'; exit 0; fi
    printf '\n'; warn "再按一次 Ctrl+C 或输入 0 退出"; printf '选择 [0-6]: '
    return 1
  fi
  printf '\n'
  return 0
}

# 按 CLI 命令名查表 -> R_FUNC / R_FLAGS
ui_cli_row() {
  local row kind grp num sect title desc func cli flags
  for row in "${SB_MENU[@]}"; do
    IFS='|' read -r kind grp num sect title desc func cli flags <<<"$row"
    if [[ $cli == "$1" ]]; then R_FUNC=$func; R_FLAGS=$flags; return 0; fi
  done
  return 1
}

# 按 分组 + 菜单编号 查表 (kind 为 I) -> R_FUNC / R_FLAGS
ui_find_item() {
  local row kind grp num sect title desc func cli flags
  for row in "${SB_MENU[@]}"; do
    IFS='|' read -r kind grp num sect title desc func cli flags <<<"$row"
    if [[ $kind == I && $grp == "$1" && $num == "$2" ]]; then R_FUNC=$func; R_FLAGS=$flags; return 0; fi
  done
  return 1
}
ui_find_group() {
  local row kind grp num sect title desc func cli flags
  for row in "${SB_MENU[@]}"; do
    IFS='|' read -r kind grp num sect title desc func cli flags <<<"$row"
    if [[ $kind == G && $num == "$1" ]]; then R_FUNC=$func; R_FLAGS=$flags; return 0; fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# 动作隔离: 每个菜单动作在子 shell 中运行, die/失败只终止该动作, 不退出菜单。
# 关键点: 不能写成 `( ... ) || ...` 或放进 if —— 那会让子 shell 内的 set -e / ERR 失效。
# 做法: 父 shell 临时 set +e 并摘掉 ERR trap, 子 shell 内重新 set -Ee + ERR trap。
# ---------------------------------------------------------------------------
action_interrupt() {
  trap - INT
  if [[ -n ${UI_BG_PID:-} ]]; then kill "$UI_BG_PID" 2>/dev/null || true; fi
  printf '\r\033[K\n' >&2
  if [[ -n $PENDING_TAG ]]; then
    warn "节点 [${PENDING_TAG}] 可能已写入并生效, 但连接记录/防火墙可能未完成。请运行: sb reconcile" || true
  fi
  exit 130
}

run_action() {
  local flags=$1 rc=0
  shift
  MENU_INT=0
  set +e
  trap - ERR
  trap 'MENU_INT=1' INT        # 动作运行期间父 shell 不响应 Ctrl+C (由子 shell 自行处理)
  (
    set -Ee
    trap 'on_error $LINENO' ERR
    trap 'action_interrupt' INT
    "$@"
  )
  rc=$?
  set -e
  trap 'on_error $LINENO' ERR
  trap "$UI_INT_TRAP" INT
  UI_VER_CACHE=""
  if (( rc == 0 )); then
    if [[ $flags == *P* ]]; then ui_pause "── 按回车返回菜单 ──"; fi
  elif (( rc == 130 )); then
    warn "本次操作已取消, 返回菜单。"
  else
    warn "本次操作未完成，按回车返回菜单（不会退出脚本）"
    ui_pause ""
  fi
  return 0
}

# 执行一行菜单: M 标志在主 shell 内运行, 其余走 run_action
ui_exec_row() {
  local func=$1 flags=$2
  local -a cmd=()
  IFS=' ' read -ra cmd <<<"$func"
  if [[ $flags == *M* ]]; then "${cmd[@]}"; else run_action "$flags" "${cmd[@]}"; fi
  return 0
}

# ---------------------------------------------------------------------------
# 渲染
# ---------------------------------------------------------------------------
ui_main_draw() {
  local skip=${1:-0} cols row kind grp num sect title desc func cli flags
  cols=$(ui_cols)
  printf '\n'
  if (( skip == 0 )); then ui_status_line; fi   # 首屏启动画面已含状态, 不重复
  ui_hr
  for row in "${SB_MENU[@]}"; do
    IFS='|' read -r kind grp num sect title desc func cli flags <<<"$row"
    [[ $kind == G ]] || continue
    printf ' %s%2s%s  %s%s%s' "$CYAN" "$num" "$NC" "$BOLD" "$(ui_pad "$title" 12)" "$NC"
    if (( cols >= 60 )); then printf '%s%s%s' "$DIM" "$desc" "$NC"; fi
    printf ' %s%s%s\n' "$DIM" "$G_ARR" "$NC"
  done
  printf ' %s 0  退出%s\n' "$DIM" "$NC"
  return 0
}

ui_group_draw() {
  local grp=$1 cols row kind g num sect title desc func cli flags last="" linew=0 cw
  local line="" cell cellc gtitle="" star
  cols=$(ui_cols)
  ui_find_group "$grp" || true
  for row in "${SB_MENU[@]}"; do
    IFS='|' read -r kind g num sect title desc func cli flags <<<"$row"
    if [[ $kind == G && $num == "$grp" ]]; then gtitle=$title; fi
  done
  printf '\n%s%s%s %s %s%s%s\n' "${BOLD}${CYAN}" "$G_H" "$G_H" "$gtitle" "$G_H" "$G_H" "$NC"
  for row in "${SB_MENU[@]}"; do
    IFS='|' read -r kind g num sect title desc func cli flags <<<"$row"
    [[ $kind == I && $g == "$grp" && $num != - ]] || continue
    if [[ $sect != "$last" ]]; then
      if [[ -n $line ]]; then printf '%s\n' "$line"; line=""; linew=0; fi
      if [[ -n $sect ]]; then printf ' %s%s %s %s%s\n' "$DIM" "$G_H" "$sect" "$G_H" "$NC"; fi
      last=$sect
    fi
    star="  "; if [[ $flags == *S* ]]; then star="${YELLOW}${G_STAR}${NC} "; fi
    if [[ -n $desc ]]; then
      if [[ -n $line ]]; then printf '%s\n' "$line"; line=""; linew=0; fi
      printf ' %s%s%2s%s  %s' "$star" "$CYAN" "$num" "$NC" "$BOLD"
      if (( cols >= 60 )); then printf '%s%s  %s%s%s' "$(ui_pad "$title" 26)" "$NC" "$DIM" "$desc" "$NC"; else printf '%s%s' "$title" "$NC"; fi
      printf '\n'
    else
      cell=$(printf '%2s  %s' "$num" "$title")
      cellc=$(printf '%s%2s%s  %s' "$CYAN" "$num" "$NC" "$title")
      ui_wv "$cell"; cw=$(( UI_WV + 3 ))
      if (( linew > 0 && linew + cw > cols - 3 )); then printf '%s\n' "$line"; line=""; linew=0; fi
      if [[ -z $line ]]; then line="  ${cellc}"; linew=$(( cw + 1 )); else line+="   ${cellc}"; linew=$(( linew + cw )); fi
    fi
  done
  if [[ -n $line ]]; then printf '%s\n' "$line"; fi
  printf ' %s 0  返回%s\n' "$DIM" "$NC"
  return 0
}

# 二级菜单 (分类子菜单, 在主 shell 内循环; 每个动作经 run_action 隔离)
ui_group_menu() {
  local grp=$1 choice rc
  while true; do
    ui_group_draw "$grp"
    rc=0; MENU_INT=0
    read -e -r -p "选择: " choice || rc=$?
    if (( rc != 0 )); then printf '\n'; return 0; fi        # Ctrl+D / Ctrl+C: 回上一级
    choice=${choice//[[:space:]]/}
    if [[ -z $choice ]]; then continue; fi
    if [[ $choice == 0 ]]; then return 0; fi
    if ui_find_item "$grp" "$choice"; then
      ui_exec_row "$R_FUNC" "$R_FLAGS"
    else
      warn "无效选择: ${choice}"
    fi
  done
}

menu() {
  local choice rc first=1
  MENU_INT=0; INT_COUNT=0
  trap "$UI_INT_TRAP" INT
  ui_splash
  while true; do
    ui_main_draw "$first"; first=0
    rc=0; MENU_INT=0; MENU_LVL=main
    read -e -r -p "选择 [0-6]: " choice || rc=$?
    MENU_LVL=sub
    if (( rc != 0 )); then printf '\n'; exit 0; fi      # Ctrl+D: 正常退出, 不触发 ERR trap
    INT_COUNT=0
    choice=${choice//[[:space:]]/}
    if [[ -z $choice ]]; then continue; fi              # 直接回车: 静默重绘
    if [[ $choice == 0 ]]; then exit 0; fi
    if ui_find_group "$choice"; then
      ui_exec_row "$R_FUNC" "$R_FLAGS"
    else
      warn "无效选择: ${choice}"
    fi
  done
}

usage() {
  local row kind grp num sect title desc func cli flags
  printf '用法: sb [命令]\n\n'
  printf '  %-14s %s\n' "menu" "交互菜单 (默认)"
  for row in "${SB_MENU[@]}"; do
    IFS='|' read -r kind grp num sect title desc func cli flags <<<"$row"
    [[ -n $cli && $cli != - ]] || continue
    if [[ -n $desc ]]; then printf '  %-14s %s — %s\n' "$cli" "$title" "$desc"; else printf '  %-14s %s\n' "$cli" "$title"; fi
  done
  printf '  %-14s %s\n' "help" "显示本帮助"
  printf '\n环境变量: NO_COLOR=1 关闭颜色  SB_THEME=light 白底主题  SB_LOGO_HALF=1 徽标改用半块字符\n'
  return 0
}

main() {
  local cmd=${1:-menu}
  case $cmd in
    -h|--help|help) if [[ -t 1 ]]; then ui_banner "$(ui_cols)"; fi; usage; return 0 ;;
    -V|--version|version) printf 'sb %s\n' "$SCRIPT_VERSION"; return 0 ;;
  esac
  require_root
  ensure_dirs
  R_FUNC=""; R_FLAGS=""
  if [[ $cmd != menu ]]; then
    ui_cli_row "$cmd" || { usage; exit 1; }
  fi
  # 互斥锁: 菜单与写操作持有; 只读命令 (status/links/logs/health/diag, 表中 N 标志) 跳过,
  # 这样菜单开着时仍可另开终端查看。进程退出时文件描述符关闭, 锁自动释放。
  if [[ $R_FLAGS != *N* ]]; then
    exec {LOCK_FD}>"$LOCK_FILE"
    if ! flock -n "$LOCK_FD"; then
      die "检测到另一个 sb 操作正在进行中 (锁文件: ${LOCK_FILE}), 请等待其结束后重试。"
    fi
  fi
  if [[ $cmd == menu ]]; then
    menu
  else
    local -a cmdline=()
    IFS=' ' read -ra cmdline <<<"$R_FUNC"
    "${cmdline[@]}"
  fi
}


# ===========================================================================
# 节点列表 (动作字母 + 编号) / 编辑菜单
# ===========================================================================
NL_N=0; NL_TYPE=(); NL_TAG=(); NL_PORT=(); NL_URI=()
LISTEN_SET=""; LISTEN_OK=0
declare -A INB_PORT=()

ui_node_load() {
  local type tag port uri
  NL_TYPE=(); NL_TAG=(); NL_PORT=(); NL_URI=()
  while IFS=$'\t' read -r type tag port uri; do
    [[ -n $tag ]] || continue
    NL_TYPE+=("$type"); NL_TAG+=("$tag"); NL_PORT+=("$port"); NL_URI+=("$uri")
  done < <(jq -r '.connections[]? | [.type, .tag, (.port|tostring), .uri] | @tsv' "$STATE_FILE" 2>/dev/null)
  NL_N=${#NL_TAG[@]}
  return 0
}

# 监听快照: 一次 ss, 记成 " tcp:443 udp:443 " 形式
ui_listen_snapshot() {
  LISTEN_SET=""; LISTEN_OK=0
  if command -v ss >/dev/null 2>&1; then
    LISTEN_OK=1
    LISTEN_SET=$(ss -H -tuln 2>/dev/null | awk '{n=split($5,a,":"); printf " %s:%s", $1, a[n]}' || true)
    LISTEN_SET+=" "
  fi
  return 0
}

ui_inbound_ports() {
  local tag port
  INB_PORT=()
  while IFS=$'\t' read -r tag port; do
    [[ -n $tag ]] || continue
    INB_PORT[$tag]=$port
  done < <(jq -r '.inbounds[]? | [.tag, (.listen_port // "" | tostring)] | @tsv' "$CONFIG_FILE" 2>/dev/null)
  return 0
}

# 本机是否存在受本脚本管理的防火墙后端 (无后端时只需云厂商安全组, 显示 –)
ui_fw_backend_present() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then return 0; fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then return 0; fi
  if command -v iptables >/dev/null 2>&1; then return 0; fi
  if command -v nft >/dev/null 2>&1 && nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then return 0; fi
  return 1
}

proto_label() {
  case $1 in
    vless-reality-grpc*) printf 'Reality gRPC' ;;
    vless-reality*)      printf 'Reality' ;;
    shadowtls*)          printf 'ShadowTLS' ;;
    shadowsocks*)        printf 'SS2022' ;;
    trojan*)             printf 'Trojan' ;;
    vless-tls*)          printf 'VLESS TLS' ;;
    vless-ws-cloudflare-tunnel*) printf 'CF Tunnel' ;;
    hysteria2*)          printf 'Hysteria2' ;;
    tuic*)               printf 'TUIC v5' ;;
    anytls*)             printf 'AnyTLS' ;;
    naive*)              printf 'Naive' ;;
    snell*)              printf 'Snell' ;;
    *)                   printf '%s' "${1%%-*}" ;;
  esac
}

# 取连接串 # 之后的显示名 (百分号解码, 并去掉控制字符防止终端转义注入)
ui_uri_name() {
  local frag=${1##*#}
  [[ $1 == *'#'* ]] || { printf ''; return 0; }
  frag=$(printf '%b' "${frag//%/\\x}")
  printf '%s' "${frag//[[:cntrl:]]/}"
}

ui_node_table() {
  local cols narrow=0 i type tag port label protos tp fw ls st fwc lsc name p active room
  local fwpresent=0 anyfw=0 inb_ok hints=()
  cols=$(ui_cols); if (( cols < 60 )); then narrow=1; fi
  ui_listen_snapshot; ui_inbound_ports
  if ui_fw_backend_present; then fwpresent=1; fi
  active=0; if systemctl is-active --quiet sing-box 2>/dev/null; then active=1; fi
  printf '
'
  if (( narrow )); then
    printf '%s%s%s%s%s%s听%s\n' "$BOLD" "$(ui_pad ' #' 4)" "$(ui_pad '状态' 5)" "$(ui_pad '协议' 13)" "$(ui_pad '端口' 13)" "$(ui_pad '墙' 5)" "$NC"
  else
    printf '%s%s%s%s%s%s%s名称%s\n' "$BOLD" "$(ui_pad ' #' 4)" "$(ui_pad '状态' 6)" "$(ui_pad '协议' 13)" "$(ui_pad '端口/传输' 13)" "$(ui_pad '防火墙' 8)" "$(ui_pad '监听' 6)" "$NC"
  fi
  ui_hr
  for ((i=0; i<NL_N; i++)); do
    type=${NL_TYPE[i]}; tag=${NL_TAG[i]}; port=${NL_PORT[i]}
    label=$(proto_label "$type")
    tp=""; fw=1; ls=1
    if [[ $type == vless-ws-cloudflare-tunnel ]]; then
      tp="${INB_PORT[$tag]:-$port}/tcp"
      fw=2
      if (( LISTEN_OK )); then [[ $LISTEN_SET == *" tcp:${INB_PORT[$tag]:-$port} "* ]] || ls=0; else ls=2; fi
    else
      protos=$(_proto_fw_protocols "$type")
      for p in $protos; do
        tp+="${tp:+/}${p}"
        if (( fwpresent )); then _fw_port_allowed "$port" "$p" || fw=0; else fw=2; fi
        if (( LISTEN_OK )); then [[ $LISTEN_SET == *" ${p}:${port} "* ]] || ls=0; else ls=2; fi
      done
      tp="${port}/${tp}"
    fi
    inb_ok=0; [[ -n ${INB_PORT[$tag]+x} ]] && inb_ok=1
    if (( active && inb_ok )); then st="${GREEN}$(ui_pad "$G_DOT" $(( narrow ? 5 : 6 )))${NC}"; else st="${RED}$(ui_pad "$G_OFF" $(( narrow ? 5 : 6 )))${NC}"; fi
    case $fw in 1) fwc="${GREEN}$(ui_pad "$G_OK" $(( narrow ? 5 : 8 )))${NC}" ;; 0) fwc="${RED}$(ui_pad "$G_X" $(( narrow ? 5 : 8 )))${NC}" ;; *) fwc="${DIM}$(ui_pad "$G_SKIP" $(( narrow ? 5 : 8 )))${NC}" ;; esac
    case $ls in 1) lsc="${GREEN}${G_OK}${NC}" ;; 0) lsc="${RED}${G_X}${NC}" ;; *) lsc="${DIM}${G_SKIP}${NC}" ;; esac
    if (( narrow )); then
      printf ' %s%-2d%s %s%-12s %-12s %s%s\n' "$CYAN" $((i+1)) "$NC" "$st" "$(ui_trunc "$label" 12)" "$(ui_trunc "$tp" 12)" "$fwc" "$lsc"
    else
      room=$(( cols - 52 )); if (( room < 8 )); then room=8; fi
      name=$(ui_trunc "$(ui_uri_name "${NL_URI[i]}")" "$room")
      printf ' %s%-2d%s %s%-12s %-12s %s%s%s%s\n' "$CYAN" $((i+1)) "$NC" "$st" "$label" "$tp" "$fwc" "$lsc" "$(ui_pad '' 5)" "$name"
    fi
    if (( fw == 0 )); then hints+=("$(printf '%s%s%s %d 防火墙未放行 %s  %s→%s %sf%d%s 修复防火墙' "$YELLOW" "$G_WARN" "$NC" $((i+1)) "$tp" "$DIM" "$NC" "$CYAN" $((i+1)) "$NC")"); fi
    if (( ls == 0 )); then hints+=("$(printf '%s%s%s %d 未监听 %s  %s→%s %sl%d%s 查看日志' "$YELLOW" "$G_WARN" "$NC" $((i+1)) "$tp" "$DIM" "$NC" "$CYAN" $((i+1)) "$NC")"); fi
  done
  if (( ! fwpresent )); then printf '%s%s 未检测到本机防火墙, 仅需在云厂商安全组放行端口。%s\n' "$DIM" "$G_INFO" "$NC"; fi
  if (( ${#hints[@]} > 0 )); then printf '\n'; printf '%s\n' "${hints[@]}"; fi
  return 0
}

ui_node_qr() {
  local idx=$1
  printf '\n%s%s%s\n' "$BOLD" "${NL_TAG[idx]}" "$NC"
  ui_show_uri "${NL_URI[idx]}"
  show_qrcode "${NL_URI[idx]}" "${NL_TAG[idx]}"
}

fix_node_firewall() {
  local idx=$1 type port proto
  type=${NL_TYPE[idx]}; port=${NL_PORT[idx]}
  if [[ $type == vless-ws-cloudflare-tunnel ]]; then info "Tunnel 节点监听本机回环, 无需放行防火墙。"; return 0; fi
  for proto in $(_proto_fw_protocols "$type"); do open_firewall_port "$port" "$proto"; done
  ok "已处理 ${NL_TAG[idx]} 的防火墙放行。"
}

show_node_logs() {
  local tag=$1 out
  out=$(journalctl -u sing-box -n 400 --no-pager -o cat 2>/dev/null | grep -F -- "$tag" | tail -n 60 || true)
  if [[ -n $out ]]; then
    printf '%s\n' "$out"
  else
    warn "最近日志中没有 [${tag}] 的记录, 以下为 sing-box 最近 40 行:"
    journalctl -u sing-box -n 40 --no-pager -o cat || true
  fi
}

node_list_menu() {
  local act verb num idx tag rc
  while true; do
    ensure_dirs
    ui_node_load
    if (( NL_N == 0 )); then
      warn "尚无节点记录, 请先在「新建节点」里部署。"
      ui_pause "── 按回车返回菜单 ──"
      return 0
    fi
    ui_node_table
    printf '\n%sq%s 二维码  %sc%s 复制链接  %se%s 编辑  %sd%s 删除  %sf%s 修复防火墙  %sl%s 日志  %s0%s 返回\n' \
      "$CYAN" "$NC" "$CYAN" "$NC" "$CYAN" "$NC" "$CYAN" "$NC" "$CYAN" "$NC" "$CYAN" "$NC" "$CYAN" "$NC"
    rc=0; MENU_INT=0
    read -e -r -p "操作 (如 e3): " act || rc=$?
    if (( rc != 0 )); then printf '\n'; return 0; fi
    act=${act//[[:space:]]/}
    if [[ -z $act ]]; then continue; fi
    if [[ $act == 0 ]]; then return 0; fi
    if [[ $act =~ ^([qcedfl])([0-9]+)$ ]]; then
      verb=${BASH_REMATCH[1]}; num=$((10#${BASH_REMATCH[2]}))
    else
      warn "无法识别的操作 “${act}”, 格式: 动作字母+编号, 如 e3 / q1 / d2"
      continue
    fi
    if (( num < 1 || num > NL_N )); then warn "不存在的编号 ${num} (当前 1-${NL_N})。"; continue; fi
    idx=$((num-1)); tag=${NL_TAG[idx]}
    case $verb in
      q) run_action P ui_node_qr "$idx" ;;
      c) ui_copy "${NL_URI[idx]}" ;;
      e) SEL_TAG=$tag; node_edit_menu; SEL_TAG="" ;;
      d) run_action "" remove_inbound "$tag" ;;
      f) run_action P fix_node_firewall "$idx" ;;
      l) run_action P show_node_logs "$tag" ;;
    esac
  done
}


# 编辑菜单: 从节点列表进入 (SEL_TAG 已选定) 只做一次修改并回到列表; CLI 'sb edit' 保持原有循环菜单
node_edit_menu() {
  local choice type label4 fn4 rc=0
  if [[ -n ${SEL_TAG:-} ]]; then
    type=$(_conn_field "$SEL_TAG" type 2>/dev/null || true)
    case $type in
      vless-reality*|shadowtls*) label4="修改握手域名"; fn4=change_reality_domain ;;
      *)                         label4="修改 TLS 域名"; fn4=change_tls_domain ;;
    esac
    title "编辑 ${SEL_TAG}"
    printf '  %s1%s 重命名   %s2%s 修改端口   %s3%s 修改连接地址   %s4%s %s   %s0%s 返回\n' \
      "$CYAN" "$NC" "$CYAN" "$NC" "$CYAN" "$NC" "$CYAN" "$NC" "$label4" "$CYAN" "$NC"
    read -e -r -p "请选择: " choice || rc=$?
    if (( rc != 0 )); then printf '\n'; return 0; fi
    case ${choice//[[:space:]]/} in
      1) run_action "" rename_node ;;
      2) run_action "" change_node_port ;;
      3) run_action "" change_node_host ;;
      4) run_action "" "$fn4" ;;
      *) ;;
    esac
    return 0
  fi
  while true; do
    title "编辑节点"
    printf '  1) 重命名节点\n  2) 修改监听端口\n  3) 修改客户端连接地址\n  4) 修改握手域名 (Reality/ShadowTLS)\n  5) 修改 TLS 域名 (Trojan/VLESS TLS/Hy2/TUIC/AnyTLS)\n  0) 返回\n'
    read -e -r -p '请选择: ' choice || return 0
    case $choice in
      1) rename_node ;;
      2) change_node_port ;;
      3) change_node_host ;;
      4) change_reality_domain ;;
      5) change_tls_domain ;;
      0) return 0 ;;
      *) warn "无效的编号选择。" ;;
    esac
  done
}

# ===========================================================================
# 快速部署 VLESS Reality: 全部默认值, 回车即完成
# ===========================================================================
port_free_quiet() {
  local port=$1
  if port_is_used_in_config "$port"; then return 1; fi
  if command -v ss >/dev/null 2>&1 && ss -tulnH "sport = :$port" 2>/dev/null | grep -q .; then return 1; fi
  return 0
}

# 首选 443, 被占用则顺延到常见端口
pick_free_port() {
  local p n
  for p in 443 8443 2053 2083 2087 2096 10443 20443; do
    if port_free_quiet "$p"; then printf '%s' "$p"; return 0; fi
  done
  for n in 1 2 3 4 5 6 7 8 9 10; do
    p=$(( RANDOM % 20000 + 20000 ))
    if port_free_quiet "$p"; then printf '%s' "$p"; return 0; fi
  done
  die "找不到可用端口, 请手动指定。"
}

_tls13_probe() {
  command -v openssl >/dev/null 2>&1 || return 0
  timeout 4 openssl s_client -connect "${1}:443" -tls1_3 -servername "$1" </dev/null >/dev/null 2>&1
}

_quick_default_host() {   # <mode>
  case $1 in
    v4) printf '%s' "${NET_V4:-}" ;;
    v6) printf '%s' "${NET_V6:-}" ;;
    *)  if [[ -n $NET_V4 ]]; then printf '%s' "$NET_V4"; else printf '%s' "$NET_V6"; fi ;;
  esac
}

deploy_quick_reality() {
  local mode=dual port want=443 handshake host name tag flag ans tls13="" t0 t1
  local listen outbound keypair private_key public_key short_id uuid reality tlsj inbound uri encname
  title "快速部署 · VLESS Reality"
  net_snapshot
  host=$(_quick_default_host "$mode")
  if [[ -z $host ]]; then host=$(hostname -I 2>/dev/null | awk '{print $1}' || true); fi
  port=$(pick_free_port)
  handshake=${REALITY_PRESET_DOMAINS[0]}
  name="Reality-${mode}"
  if UI_SOFT=1 ui_run "检测 ${handshake} 的 TLS 1.3" _tls13_probe "$handshake"; then tls13="${GREEN}TLS 1.3 ${G_OK}${NC}"; else tls13="${YELLOW}${G_WARN} 未能确认 TLS 1.3${NC}"; fi

  while true; do
    printf '\n%s%s%s\n' "$BOLD" "部署摘要" "$NC"
    case $mode in dual) printf '  %s Dual 双栈 (v4 + v6)\n' "$(ui_pad 模式 9)" ;; v4) printf '  %s 仅 IPv4\n' "$(ui_pad 模式 9)" ;; *) printf '  %s 仅 IPv6 (严格)\n' "$(ui_pad 模式 9)" ;; esac
    if [[ $port != "$want" ]]; then
      printf '  %s %s%s%s  %s%s %s 已被占用, 自动顺延%s\n' "$(ui_pad 端口 9)" "$BOLD" "$port" "$NC" "$YELLOW" "$G_WARN" "$want" "$NC"
    else
      printf '  %s %s%s%s\n' "$(ui_pad 端口 9)" "$BOLD" "$port" "$NC"
    fi
    printf '  %s %s  %s\n' "$(ui_pad 握手域名 9)" "$handshake" "$tls13"
    printf '  %s %s\n' "$(ui_pad 连接地址 9)" "${host:-<未检测到, 请按 e 填写>}"
    printf '  %s %s\n' "$(ui_pad 节点名 9)" "$name"
    read -e -r -p "回车 确认 / e 逐项修改 / 0 取消: " ans || die "输入已取消。"
    case ${ans//[[:space:]]/} in
      '') if [[ -z $host ]]; then warn "连接地址为空, 请先按 e 填写。"; continue; fi; break ;;
      0)  warn "已取消。"; return 0 ;;
      e|E)
        mode=$(ask_node_network_mode)
        host=$(ask_node_server "$mode")
        port=$(ask_port "监听端口" "$port")
        handshake=$(ask_reality_handshake_domain)
        if UI_SOFT=1 ui_run "检测 ${handshake} 的 TLS 1.3" _tls13_probe "$handshake"; then tls13="${GREEN}TLS 1.3 ${G_OK}${NC}"; else tls13="${YELLOW}${G_WARN} 未能确认 TLS 1.3${NC}"; fi
        while true; do
          read -e -r -i "$name" -p "节点名称: " name || die "输入已取消。"
          if [[ -n $name ]] && (( ${#name} <= 64 )); then break; fi
          warn "节点名称不能为空且不超过 64 字符。"
        done
        want=$port
        ;;
      *) warn "未知输入 “${ans}”。" ;;
    esac
  done

  tag="reality-${mode}-${port}"
  check_and_handle_existing_tag "$tag" || return 0
  ensure_port_available "$port"
  listen=$(mode_listen_addr "$mode"); outbound=$(mode_outbound_tag "$mode")
  case $mode in
    v4) check_ipv4_egress || die "系统检测到 IPv4 外网不可用, 无法部署 IPv4 专用节点。" ;;
    v6) check_ipv6_egress || die "系统检测到 IPv6 外网不可用, 无法部署 IPv6 节点。" ;;
  esac

  printf '\n'
  ui_run "安装 / 检查 sing-box 环境" ensure_installed || die "环境准备失败, 未写入任何节点配置。"

  t0=$(ui_now_us)
  keypair=$(generate_reality_keypair)
  private_key=${keypair%%|*}; public_key=${keypair#*|}
  short_id=$(openssl rand -hex 4)
  uuid=$(new_uuid)
  reality=$(jq -n --arg handshake "$handshake" --arg private_key "$private_key" --arg short_id "$short_id" \
    '{enabled:true,handshake:{server:$handshake,server_port:443},private_key:$private_key,short_id:[$short_id]}')
  tlsj=$(jq -n --arg handshake "$handshake" --argjson reality "$reality" '{enabled:true,server_name:$handshake,reality:$reality}')
  inbound=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg uuid "$uuid" --argjson tls "$tlsj" \
    '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",uuid:$uuid,flow:"xtls-rprx-vision"}],tls:$tls}')
  t1=$(ui_now_us)
  printf ' %s%s%s 生成密钥与配置  %s%d.%ds%s\n' "$GREEN" "$G_OK" "$NC" "$DIM" $(((t1-t0)/1000000)) $((((t1-t0)%1000000)/100000)) "$NC"

  flag=$(get_cached_flag)
  PENDING_TAG=$tag
  ui_run "校验并应用配置 (自动备份 / 失败回滚)" apply_inbound_with_route "$inbound" "$tag" "$outbound" \
    || die "配置未能生效, 已按原逻辑回滚。详见上方日志。"
  encname=$(printf '%s' "$name" | jq -sRr '@uri')
  uri="vless://${uuid}@$(format_host_uri "$host"):${port}?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=${handshake}&fp=chrome&pbk=${public_key}&sid=${short_id}#${flag}%20${encname}"
  t0=$(ui_now_us)
  save_connection "vless-reality-${mode}" "$tag" "$host" "$port" "$uri"
  t1=$(ui_now_us)
  printf ' %s%s%s 登记连接记录  %s%d.%ds%s\n' "$GREEN" "$G_OK" "$NC" "$DIM" $(((t1-t0)/1000000)) $((((t1-t0)%1000000)/100000)) "$NC"
  ui_run "放行防火墙 ${port}/tcp" open_firewall_port "$port" tcp || warn "防火墙放行未成功, 可在节点列表用 f 命令修复。"
  ok "VLESS Reality (${mode}) 已部署 (绑定出口: ${outbound})"
  print_result_block "VLESS Reality" "$uri" "$tag"
}


# ===========================================================================
# 诊断报告: ✓ 通过 / ! 警告 / ✗ 异常 / – 跳过, 末尾汇总 + 建议
# ===========================================================================
DG_PASS=0; DG_WARN=0; DG_FAIL=0; DG_SKIP=0; DG_HINTS=()

dg() {   # dg <ok|warn|fail|skip> <文本> [详情]
  local lvl=$1 text=$2 detail=${3:-} icon color
  case $lvl in
    ok)   icon=$G_OK;   color=$GREEN;  DG_PASS=$((DG_PASS+1)) ;;
    warn) icon=$G_WARN; color=$YELLOW; DG_WARN=$((DG_WARN+1)) ;;
    fail) icon=$G_X;    color=$RED;    DG_FAIL=$((DG_FAIL+1)) ;;
    *)    icon=$G_SKIP; color=$DIM;    DG_SKIP=$((DG_SKIP+1)) ;;
  esac
  printf ' %s%s%s %s' "$color" "$icon" "$NC" "$(ui_pad "$text" 30)"
  if [[ -n $detail ]]; then printf ' %s%s%s' "$DIM" "$detail" "$NC"; fi
  printf '\n'
  return 0
}

dg_hint() {
  local h
  for h in "${DG_HINTS[@]}"; do
    if [[ $h == "$1" ]]; then return 0; fi
  done
  DG_HINTS+=("$1")
  return 0
}

diag_check_singbox() {
  local ver
  if ! command -v sing-box >/dev/null 2>&1; then
    dg fail "sing-box 未安装" "sb install"; dg_hint "运行 ${BOLD}sb install${NC} 安装 sing-box"; return 0
  fi
  ver=$(sing-box version 2>/dev/null | awk 'NR==1{print $3}' || true)
  if systemctl is-active --quiet sing-box 2>/dev/null; then dg ok "sing-box 服务运行中" "$ver"
  else dg fail "sing-box 服务未运行" "$ver"; dg_hint "运行 ${BOLD}sb logs${NC} 查看启动失败原因"; fi
  if [[ -f $CONFIG_FILE ]] && sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1; then dg ok "配置语法检查" "sing-box check 通过"
  else dg fail "配置语法检查" "sing-box check 未通过"; dg_hint "运行 ${BOLD}sb rollback${NC} 恢复最近一次可用配置"; fi
  return 0
}

diag_check_consistency() {
  local -a itags=() ctags=()
  local t c found miss=0 total=0
  [[ -f $CONFIG_FILE && -f $STATE_FILE ]] || { dg skip "配置与连接记录对账" "缺少文件"; return 0; }
  mapfile -t itags < <(jq -r '.inbounds[]? | select(.listen_port != null) | .tag' "$CONFIG_FILE" 2>/dev/null)
  mapfile -t ctags < <(jq -r '.connections[]?.tag' "$STATE_FILE" 2>/dev/null)
  total=${#itags[@]}
  for t in "${itags[@]}"; do
    found=0
    for c in "${ctags[@]}"; do if [[ $t == "$c" ]]; then found=1; break; fi; done
    if (( found == 0 )); then miss=$((miss+1)); fi
  done
  for c in "${ctags[@]}"; do
    found=0
    for t in "${itags[@]}"; do if [[ $t == "$c" ]]; then found=1; break; fi; done
    if (( found == 0 )); then miss=$((miss+1)); fi
  done
  if (( miss == 0 )); then dg ok "配置与连接记录对账" "${total}/${total} 一致"
  else dg warn "配置与连接记录对账" "${miss} 处不一致"; dg_hint "运行 ${BOLD}sb reconcile${NC} 对账并修复"; fi
  return 0
}

diag_check_ports() {
  local row tag type port listen proto bad=0 n=0
  if ! command -v ss >/dev/null 2>&1; then dg skip "端口监听" "缺少 ss"; return 0; fi
  ui_listen_snapshot
  [[ -f $CONFIG_FILE ]] || return 0
  while IFS=$'\t' read -r tag type port; do
    [[ -n $tag ]] || continue
    n=$((n+1))
    for proto in $(_proto_fw_protocols "$type"); do
      if [[ $LISTEN_SET != *" ${proto}:${port} "* ]]; then
        bad=$((bad+1)); dg fail "端口 ${port}/${proto} 未监听" "节点 ${tag}"
        dg_hint "运行 ${BOLD}sb logs${NC} 查看 ${tag} 未监听的原因"
      fi
    done
  done < <(jq -r '.inbounds[]? | select(.listen_port != null) | [.tag, .type, (.listen_port|tostring)] | @tsv' "$CONFIG_FILE" 2>/dev/null)
  if (( n == 0 )); then dg skip "端口监听" "尚无入站"
  elif (( bad == 0 )); then dg ok "端口监听" "${n}/${n} 正常"; fi
  return 0
}

diag_check_firewall() {
  local tag type port listen proto bad=0 n=0
  if ! ui_fw_backend_present; then dg skip "本机防火墙" "未检测到, 仅需云厂商安全组"; return 0; fi
  [[ -f $CONFIG_FILE ]] || return 0
  while IFS=$'\t' read -r tag type port; do
    [[ -n $tag ]] || continue
    n=$((n+1))
    for proto in $(_proto_fw_protocols "$type"); do
      if ! _fw_port_allowed "$port" "$proto"; then
        bad=$((bad+1)); dg warn "防火墙未放行 ${port}/${proto}" "节点 ${tag}"
        dg_hint "运行 ${BOLD}sb reconcile${NC} 补放行, 或在节点列表用 f 编号"
      fi
    done
  done < <(jq -r '.inbounds[]? | select(.listen_port != null and (.listen // "") != "127.0.0.1") | [.tag, .type, (.listen_port|tostring)] | @tsv' "$CONFIG_FILE" 2>/dev/null)
  if (( n == 0 )); then dg skip "防火墙放行" "尚无对外入站"
  elif (( bad == 0 )); then dg ok "防火墙放行" "${n}/${n} 已放行"; fi
  return 0
}

diag_check_dns() {
  if command -v dig >/dev/null 2>&1; then
    if [[ -n $(dig +short +time=3 +tries=1 example.com A 2>/dev/null | head -1 || true) ]]; then dg ok "DNS 解析" "example.com"; else dg warn "DNS 解析失败" "example.com"; fi
  elif getent hosts example.com >/dev/null 2>&1; then dg ok "DNS 解析" "example.com"
  else dg warn "DNS 解析失败" "example.com"; fi
  return 0
}

diag_check_network() {
  if check_ipv4_egress; then dg ok "IPv4 出网" "可用"; else dg warn "IPv4 出网" "不可用"; fi
  if check_ipv6_egress; then dg ok "IPv6 出网" "可用"; else dg skip "IPv6 出网" "不可用 (非 IPv6 VPS 属正常)"; fi
  return 0
}

diag_check_bbr() {
  local cc qd
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知)
  qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo 未知)
  if [[ $cc == bbr ]]; then dg ok "BBR 拥塞控制" "${cc} / ${qd}"
  else dg warn "BBR 拥塞控制" "当前 ${cc}"; dg_hint "运行 ${BOLD}sb bbr${NC} 启用 BBR"; fi
  return 0
}

diag_check_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    if systemctl is-active --quiet cloudflared 2>/dev/null; then dg ok "Cloudflare Tunnel" "运行中"; else dg warn "Cloudflare Tunnel 未运行" "已安装"; fi
  else
    dg skip "Cloudflare Tunnel 未配置" "跳过"
  fi
  return 0
}

diag_check_resources() {
  local pct ipct avail ntp
  pct=$(df --output=pcent / 2>/dev/null | tail -n1 | tr -dc '0-9' || true)
  ipct=$(df --output=ipcent / 2>/dev/null | tail -n1 | tr -dc '0-9' || true)
  if [[ -n $pct ]]; then
    if (( pct >= 90 )); then dg fail "磁盘 /" "已用 ${pct}% , 请清理"; elif (( pct >= 80 )); then dg warn "磁盘 /" "已用 ${pct}%"; else dg ok "磁盘 /" "已用 ${pct}%"; fi
  fi
  if [[ -n $ipct ]]; then
    if (( ipct >= 90 )); then dg fail "inode /" "已用 ${ipct}%"; else dg ok "inode /" "已用 ${ipct}%"; fi
  fi
  avail=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}' || true)
  if [[ $avail =~ ^[0-9]+$ ]]; then
    if (( avail < 100 )); then dg warn "可用内存" "${avail} MB"; else dg ok "可用内存" "${avail} MB"; fi
  fi
  ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
  case $ntp in
    yes) dg ok "时间同步 (NTP)" ;;
    no)  dg warn "时间未同步" "可能影响证书与 Reality 握手"; dg_hint "运行 ${BOLD}timedatectl set-ntp true${NC} 启用时间同步" ;;
    *)   dg skip "时间同步 (NTP)" "无法判断" ;;
  esac
  return 0
}

run_diagnostics() {
  local h
  DG_PASS=0; DG_WARN=0; DG_FAIL=0; DG_SKIP=0; DG_HINTS=()
  title "诊断报告"
  ui_hr
  diag_check_singbox
  diag_check_consistency
  diag_check_ports
  diag_check_firewall
  diag_check_network
  diag_check_dns
  diag_check_bbr
  diag_check_cloudflared
  diag_check_resources
  ui_hr
  printf '结果：%s%d 通过%s  %s%d 警告%s  %s%d 异常%s' "$GREEN" "$DG_PASS" "$NC" "$YELLOW" "$DG_WARN" "$NC" "$RED" "$DG_FAIL" "$NC"
  if (( DG_SKIP > 0 )); then printf '  %s(%d 跳过)%s' "$DIM" "$DG_SKIP" "$NC"; fi
  printf '\n'
  if (( ${#DG_HINTS[@]} > 0 )); then
    for h in "${DG_HINTS[@]}"; do printf '建议：%s\n' "$h"; done
  else
    printf '建议：%s暂无需要处理的项目%s\n' "$DIM" "$NC"
  fi
  return 0
}

# 只读版前置检查: 状态/健康类只读命令不再隐式安装 sing-box 或改写配置
ensure_installed_ro() {
  if ! command -v sing-box >/dev/null 2>&1; then
    warn "sing-box 尚未安装, 请先运行: sb install"
    return 1
  fi
  return 0
}

health_check() {
  DG_PASS=0; DG_WARN=0; DG_FAIL=0; DG_SKIP=0; DG_HINTS=()
  ensure_installed_ro || return 0
  title "系统健康检查"
  if sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1; then dg ok "sing-box 语法检测" "通过"; else dg fail "sing-box 语法检测" "失败"; fi
  if systemctl is-active --quiet sing-box 2>/dev/null; then dg ok "sing-box 服务状态" "运行中"; else dg fail "sing-box 服务状态" "未运行"; fi
  if command -v cloudflared >/dev/null 2>&1; then
    if systemctl is-active --quiet cloudflared 2>/dev/null; then dg ok "cloudflared 状态" "运行中"; else dg fail "cloudflared 状态" "未运行"; fi
  fi
  if command -v warp-cli >/dev/null 2>&1; then
    if warp-cli --accept-tos status 2>/dev/null | grep -qi Connected; then dg ok "WARP 状态" "已连接"; else dg fail "WARP 状态" "未连接"; fi
  fi
  printf '\n出站规则列表:\n'
  jq -r '.outbounds[]? | "- \(.tag) [\(.type)] domain_resolver 策略: \(.domain_resolver.strategy // "默认")"' "$CONFIG_FILE"
  if (( DG_FAIL == 0 )); then ok "各项健康检查正常"; else warn "健康检查发现异常, 请运行 'sb logs' 或 'sb diag' 排查。"; fi
  return 0
}

show_status() {
  local stack v4_status="不可用" v6_status="不可用" public_ipv4 public_ipv6
  ensure_installed_ro || return 0
  stack=$(detect_network_stack)
  case "$stack" in
    dual)   v4_status="可用"; v6_status="可用" ;;
    v4only) v4_status="可用" ;;
    v6only) v6_status="可用" ;;
  esac
  public_ipv4=$(detect_public_ip || true)
  public_ipv6=$(detect_public_ipv6 || true)
  printf '\nsing-box 版本: '; sing-box version | head -n 1
  printf '出站 IP 版本策略: domain_resolver (dns tag: %s)\n' "$SB_DNS_RESOLVER_TAG"
  printf '网络栈判定: %s\n' "$stack"
  printf '外网栈连通性: IPv4 [%s] | IPv6 [%s]\n' "$v4_status" "$v6_status"
  printf '公网 IPv4: %s\n' "${public_ipv4:-未检测到}"
  printf '公网 IPv6: %s\n' "${public_ipv6:-未检测到}"
  printf '\n服务运行状态:\n'
  systemctl --no-pager --full status sing-box || true
  printf '\n当前入站与监听:\n'
  jq -r '.inbounds[]? | "- \(.tag) [\(.type)] 监听 \(.listen // "Detour"):\(.listen_port // "-")"' "$CONFIG_FILE"
}

# 测试 / 以 source 方式引用时设置 SB_SOURCE_ONLY=1 只加载函数而不执行 main
if [[ -z ${SB_SOURCE_ONLY:-} ]]; then main "$@"; fi
