#!/usr/bin/env bash
# ============================================================================
# sing-box-vps :: 小李的singbox VPS ai双栈智能管理脚本 0.1.0   (LINONO)
# Repository : https://github.com/lino-no/singbox
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

SCRIPT_UPDATE_URL="${SCRIPT_UPDATE_URL:-https://raw.githubusercontent.com/lino-no/singbox/main/sb.sh}"

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
