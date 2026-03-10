#!/bin/bash

# ============================================================================
#  Home Assistant Supervised — ULTIMATE INSTALLER
#  Версия:    7.9 (Final — FHS / Optimized / Trixie / os-release fix)
#  Платформа: TV-Боксы и SBC (Armbian Bookworm/Trixie / aarch64 / x86_64)
# ============================================================================

if [ -z "$BASH_VERSION" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "Требуется bash ≥ 4.0 (текущий: ${BASH_VERSION:-не bash})"; exit 1
fi

readonly SCRIPT_VERSION="7.9"
readonly HA_DEFAULT_MACHINE="qemuarm-64"

readonly HA_INSTALLER_DIR="/var/lib/ha-installer"
readonly STATE_FILE="${HA_INSTALLER_DIR}/state"
readonly BACKUP_DIR="${HA_INSTALLER_DIR}/backup"
readonly HA_CONFIG_FILE="${HA_INSTALLER_DIR}/config"
readonly HA_BACKUP_DIR="/var/backups/homeassistant"
readonly LOCK_FILE="/var/lock/ha_install.lock"
readonly LOG_DIR="/var/log"
readonly HASSIO_DIR="/usr/share/hassio"
readonly GRACE_MARKER="/tmp/.ha_just_installed"
readonly FAKED_OS_RELEASE="${BACKUP_DIR}/os-release.faked"

readonly HA_SUPPORTED_CODENAMES="bookworm bullseye trixie"

set -uo pipefail

# ========================== ЦВЕТА ===========================================
if [ -t 1 ]; then
    RED='\033[0;31m'     GREEN='\033[0;32m'
    YELLOW='\033[1;33m'  BLUE='\033[0;34m'
    MAGENTA='\033[0;35m' CYAN='\033[0;36m'
    WHITE='\033[1;37m'   BOLD='\033[1m'
    DIM='\033[2m'        NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA=''
    CYAN='' WHITE='' BOLD='' DIM='' NC=''
fi

CHECK="${GREEN}✔${NC}"  CROSS="${RED}✘${NC}"
ARROW="${CYAN}➜${NC}"   WARN="${YELLOW}⚠${NC}"
INFO="${BLUE}ℹ${NC}"

# ========================== ПЕРЕМЕННЫЕ ======================================
RUN_WIZARD=true

OPT_ZRAM=true;        OPT_EMMC_TUNING=true; OPT_USB_POWER=true
OPT_UFW=true;         OPT_SSH_HARDENING=true; OPT_AUTOUPDATE=true
OPT_WATCHDOG=true;    OPT_THERMAL=true;      OPT_BACKUP=true
OPT_HACS=true;        OPT_HOSTNAME=true;     OPT_STATIC_IP=false
OPT_TELEGRAM=false

STATIC_IP=""; STATIC_GW=""; STATIC_DNS=""
TG_TOKEN=""; TG_CHAT=""

SKIP_UPDATE=false; CHECK_ONLY=false; UNINSTALL=false
DRY_RUN=false;     SILENT=false;     SHOW_STATUS=false
DO_UPDATE=false;   HA_MACHINE="$HA_DEFAULT_MACHINE"; MACHINE_EXPLICIT=false
OVERRIDE_OS_AGENT_VER=""; OVERRIDE_HA_VER=""
LOG_FILE=""; LOGGING_ACTIVE=false; TEE_PID=""
OS_RELEASE_FAKED=false; DAEMON_RELOAD_NEEDED=false
PREFETCH_PID=""; HA_TMP="/tmp/ha-install"; INSTALL_START=""

SYSTEM_INFO_LOADED=false
CACHED_CODENAME=""; CACHED_VERSION_ID=""
CACHED_ARCH=""; CACHED_MACHINE_ARCH=""
CACHED_PRETTY_NAME=""; CACHED_OS_ID=""
declare -A RELEASE_CACHE

RESOLVED_OA_VER=""; RESOLVED_HA_VER=""

# ========================== МИГРАЦИЯ ========================================
migrate_legacy_paths() {
    [ -f "/root/.ha_install_state" ] && [ ! -f "$STATE_FILE" ] && { mkdir -p "$HA_INSTALLER_DIR"; mv "/root/.ha_install_state" "$STATE_FILE" 2>/dev/null || true; }
    [ -d "/root/.ha_install_backup" ] && [ ! -d "$BACKUP_DIR" ] && { mkdir -p "$BACKUP_DIR"; cp -a /root/.ha_install_backup/* "$BACKUP_DIR/" 2>/dev/null || true; }
    if [ -d "/root/ha-backups" ] && [ ! -d "$HA_BACKUP_DIR" ]; then
        mkdir -p "$HA_BACKUP_DIR"; mv /root/ha-backups/* "$HA_BACKUP_DIR/" 2>/dev/null || true; rmdir /root/ha-backups 2>/dev/null || true; fi
    local dropin="/etc/systemd/system/hassio-supervisor.service.d/fix-os-release.conf"
    [ -f "$dropin" ] && grep -q "/root/" "$dropin" 2>/dev/null && { sed -i "s|/root/.ha_install_backup|${BACKUP_DIR}|g" "$dropin" 2>/dev/null; systemctl daemon-reload 2>/dev/null || true; }
}

# ========================== ОПРЕДЕЛЕНИЕ СИСТЕМЫ ============================
detect_arch() {
    case "$(uname -m)" in
        x86_64) echo "x86_64";; aarch64) echo "aarch64";; armv7l) echo "armv7";; i686) echo "i386";; *) echo "unknown";; esac
}

detect_system_info() {
    [ "$SYSTEM_INFO_LOADED" = true ] && return 0
    CACHED_CODENAME=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}") || CACHED_CODENAME=""
    CACHED_VERSION_ID=$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}") || CACHED_VERSION_ID=""
    CACHED_PRETTY_NAME=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-}") || CACHED_PRETTY_NAME=""
    CACHED_OS_ID=$(. /etc/os-release 2>/dev/null && echo "${ID:-}") || CACHED_OS_ID=""
    CACHED_ARCH=$(detect_arch)
    CACHED_MACHINE_ARCH=$(uname -m)
    SYSTEM_INFO_LOADED=true
}

is_trixie() { detect_system_info; [ "$CACHED_CODENAME" = "trixie" ] || [ "$CACHED_VERSION_ID" = "13" ]; }
is_armbian() { [ -f /etc/armbian-release ] || dpkg -l armbian-bsp-cli-* &>/dev/null 2>&1; }

# ========================== ВЫВОД ===========================================
header() {
    local t="$1" b="══════════════════════════════════════════════════════════════" p=$((60-${#t}))
    [ $p -lt 0 ] && p=0
    echo -e "\n${BLUE}╔${b}╗${NC}\n${BLUE}║${WHITE}${BOLD}  ${t}$(printf '%*s' $p '')${NC}${BLUE}║${NC}\n${BLUE}╚${b}╝${NC}\n"
}
separator()  { [ "$SILENT" = true ] && return; echo -e "${DIM}  ────────────────────────────────────────────────────────────${NC}"; }
msg_info()   { [ "$SILENT" = true ] && return; echo -e " ${INFO}  ${WHITE}$1${NC}"; }
msg_ok()     { [ "$SILENT" = true ] && return; echo -e " ${CHECK}  ${GREEN}$1${NC}"; }
msg_warn()   { echo -e " ${WARN}  ${YELLOW}$1${NC}"; }
msg_error()  { echo -e " ${CROSS}  ${RED}$1${NC}"; }
msg_action() { [ "$SILENT" = true ] && return; echo -e " ${ARROW}  ${CYAN}$1${NC}"; }
msg_dim()    { [ "$SILENT" = true ] && return; echo -e "       ${DIM}$1${NC}"; }

setup_logging() {
    LOG_FILE="${LOG_FILE:-${LOG_DIR}/ha_install_$(date +%Y%m%d_%H%M%S).log}"
    mkdir -p "$(dirname "$LOG_FILE")"; exec 3>&1 4>&2; exec > >(tee -a "$LOG_FILE") 2>&1
    TEE_PID=$!; LOGGING_ACTIVE=true; msg_info "Лог: ${LOG_FILE}"
}
flush_log() {
    [ "$LOGGING_ACTIVE" = true ] && { exec 1>&3 2>&4 3>&- 4>&- 2>/dev/null || true; LOGGING_ACTIVE=false
        [ -n "$TEE_PID" ] && wait "$TEE_PID" 2>/dev/null || true; sleep 0.3; }
}

# ========================== СПИННЕР =========================================
spinner_pid=""
spinner_start() {
    local d="$1"; [ "$SILENT" = true ] && return
    ( local s='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 e=0; while true; do i=$(((i+1)%${#s}))
        printf "\r ${CYAN}%s${NC}  ${WHITE}%s${NC} ${DIM}(%ds)${NC}  " "${s:$i:1}" "$d" "$e" > /dev/tty 2>/dev/null || break
        sleep 1; e=$((e+1)); done ) &
    spinner_pid=$!; disown "$spinner_pid" 2>/dev/null || true
}
spinner_stop() {
    [ -n "$spinner_pid" ] && kill -0 "$spinner_pid" 2>/dev/null && {
        kill "$spinner_pid" 2>/dev/null; wait "$spinner_pid" 2>/dev/null
        printf "\r%80s\r" "" > /dev/tty 2>/dev/null || true; }; spinner_pid=""
}

# ========================== TMPFS / DIRS ====================================
setup_tmpdir() { mkdir -p "$HA_TMP"; df -T "$HA_TMP" 2>/dev/null | grep -q tmpfs || mount -t tmpfs -o size=512M tmpfs "$HA_TMP" 2>/dev/null || true; }
cleanup_tmpdir() { umount "$HA_TMP" 2>/dev/null || true; rm -rf "$HA_TMP" 2>/dev/null || true; }
setup_dirs() { mkdir -p "$HA_INSTALLER_DIR" "$BACKUP_DIR" "$HA_BACKUP_DIR"; chmod 750 "$HA_INSTALLER_DIR" "$BACKUP_DIR" "$HA_BACKUP_DIR"; }

# ========================== CONFIG ==========================================
save_config() {
    cat > "$HA_CONFIG_FILE" << EOF
INSTALLED_VERSION="${SCRIPT_VERSION}"
INSTALLED_DATE="$(date -Iseconds)"
HA_MACHINE="${HA_MACHINE}"
OA_VERSION="${RESOLVED_OA_VER}"
HA_VERSION="${RESOLVED_HA_VER}"
OS_RELEASE_FAKED=${OS_RELEASE_FAKED}
BACKUP_DIR="${HA_BACKUP_DIR}"
OPT_ZRAM=${OPT_ZRAM}; OPT_UFW=${OPT_UFW}; OPT_WATCHDOG=${OPT_WATCHDOG}
OPT_THERMAL=${OPT_THERMAL}; OPT_BACKUP=${OPT_BACKUP}; OPT_HACS=${OPT_HACS}
EOF
}
load_config() { [ -f "$HA_CONFIG_FILE" ] && . "$HA_CONFIG_FILE"; }

# ========================== STATE & LOCK ====================================
acquire_lock() { exec 200>"$LOCK_FILE"; flock -n 200 || { msg_error "Скрипт уже запущен"; exit 1; }; echo $$ > "$LOCK_FILE"; }
release_lock() { flock -u 200 2>/dev/null || true; rm -f "$LOCK_FILE" 2>/dev/null || true; }
mark_done() { local s="$1" t; t=$(date +%s); grep -v "^${s}|" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true; echo "${s}|${t}|${SCRIPT_VERSION}" >> "${STATE_FILE}.tmp"; mv "${STATE_FILE}.tmp" "$STATE_FILE"; }
is_done() { local s="$1"; [ ! -f "$STATE_FILE" ] && return 1; local l; l=$(grep "^${s}|" "$STATE_FILE" 2>/dev/null) || return 1; local v; v=$(echo "$l"|cut -d'|' -f3); [ "$v" != "$SCRIPT_VERSION" ] && { msg_dim "${s}: v${v}→v${SCRIPT_VERSION}"; return 1; }; return 0; }
reset_state() { rm -f "$STATE_FILE" "$GRACE_MARKER" 2>/dev/null || true; msg_ok "Состояние сброшено."; }
schedule_daemon_reload() { DAEMON_RELOAD_NEEDED=true; }
flush_daemon_reload() { [ "$DAEMON_RELOAD_NEEDED" = true ] && { systemctl daemon-reload 2>/dev/null || true; DAEMON_RELOAD_NEEDED=false; }; }
run_step() { local f="$1"; shift; local t0; t0=$(date +%s); "$f" "$@"; local rc=$? e=$(( $(date +%s) - t0 )); [ $e -gt 5 ] && msg_dim "⏱ ${e}с"; return $rc; }

# ========================== CLEANUP ========================================
cleanup() {
    local ec=$?; spinner_stop 2>/dev/null || true; [ -n "$PREFETCH_PID" ] && kill "$PREFETCH_PID" 2>/dev/null || true
    cleanup_tmpdir 2>/dev/null || true; release_lock; flush_log 2>/dev/null || true
    [ $ec -eq 130 ] && echo -e "\n ${WARN}  ${YELLOW}Прервано${NC}"
}
trap cleanup EXIT INT TERM

# ========================== УТИЛИТЫ =========================================
is_pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }
pkg_available()    { apt-cache show "$1" >/dev/null 2>&1; }

run_cmd() {
    local d="$1"; shift; local lf; lf=$(mktemp "${HA_TMP}/ha_XXXXXX.log" 2>/dev/null || mktemp /tmp/ha_XXXXXX.log)
    msg_action "${d}..."
    [ "$DRY_RUN" = true ] && { msg_dim "[dry-run] $*"; rm -f "$lf"; return 0; }
    if "$@" > "$lf" 2>&1; then msg_ok "$d"; rm -f "$lf"; return 0
    else local c=$?; msg_error "${d} (код ${c})"; tail -15 "$lf" 2>/dev/null | while IFS= read -r l; do echo -e "    ${RED}│${NC} ${l}"; done; return $c; fi
}
run_cmd_fatal() { run_cmd "$@" || { msg_error "Критическая ошибка."; exit 1; }; }

download_file() {
    local url="$1" out="$2" desc="$3" max="${4:-3}" att=1
    [ "$DRY_RUN" = true ] && { msg_action "${desc}..."; msg_dim "[dry-run] wget ${url}"; return 0; }
    while [ $att -le $max ]; do
        [ $att -gt 1 ] && sleep $((att*3)); msg_action "${desc} (${att}/${max})..."
        rm -f "$out" 2>/dev/null || true
        if wget -q --timeout=60 --tries=1 -O "$out" "$url" 2>/dev/null && [ -s "$out" ]; then
            [[ "$out" == *.deb ]] && { dpkg-deb --info "$out" &>/dev/null && { msg_ok "$desc"; return 0; }; msg_warn ".deb повреждён"; } \
                || { msg_ok "$desc"; return 0; }
        else msg_warn "Ошибка загрузки"; fi; att=$((att+1)); done
    msg_error "${desc} — не удалось"; return 1
}

get_latest_release() {
    local repo="$1"; [ -n "${RELEASE_CACHE[$repo]+x}" ] && { echo "${RELEASE_CACHE[$repo]}"; return 0; }
    local v=""
    if command -v curl &>/dev/null && command -v jq &>/dev/null; then
        v=$(curl -fsSL --timeout 15 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null | tr -d '[:space:]') || true; fi
    if [ -z "$v" ] && command -v curl &>/dev/null; then
        local u; u=$(curl -sL --timeout 15 -o /dev/null -w '%{url_effective}' "https://github.com/${repo}/releases/latest" 2>/dev/null) || true
        [ -n "$u" ] && v=$(echo "$u" | sed 's|.*/tag/||' | tr -d '[:space:]'); fi
    if [ -z "$v" ] && command -v curl &>/dev/null; then
        v=$(curl -sI --timeout 15 "https://github.com/${repo}/releases/latest" 2>/dev/null | grep -i '^location:' | head -1 | sed 's|.*/tag/||' | tr -d '[:space:]') || true; fi
    if [ -z "$v" ] && command -v wget &>/dev/null; then
        v=$(wget -q --timeout=15 --max-redirect=0 -S "https://github.com/${repo}/releases/latest" 2>&1 | grep -i 'Location:' | head -1 | sed 's|.*/tag/||' | tr -d '[:space:]') || true; fi
    RELEASE_CACHE[$repo]="$v"; echo "$v"
}

detect_machine_type() {
    local m=""; m=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null) || true
    case "$(uname -m)" in
        x86_64) echo "generic-x86-64";; aarch64) case "$m" in
            *Raspberry*Pi*5*) echo "raspberrypi5-64";; *Raspberry*Pi*4*) echo "raspberrypi4-64";;
            *Raspberry*Pi*3*) echo "raspberrypi3-64";; *ODROID-N2*) echo "odroid-n2";;
            *ODROID-C4*) echo "odroid-c4";; *Khadas*VIM3*) echo "khadas-vim3";; *) echo "qemuarm-64";; esac;;
        armv7l) echo "qemuarm";; *) echo "qemuarm-64";; esac
}

get_cpu_temp() { [ -f /sys/class/thermal/thermal_zone0/temp ] && echo "$(($(cat /sys/class/thermal/thermal_zone0/temp)/1000))" || echo ""; }

check_internet() {
    ping -c1 -W2 github.com &>/dev/null & local p1=$!; ping -c1 -W2 8.8.8.8 &>/dev/null & local p2=$!; ping -c1 -W2 1.1.1.1 &>/dev/null & local p3=$!
    local dns=false net=false; wait "$p1" 2>/dev/null && dns=true && net=true; wait "$p2" 2>/dev/null && net=true; wait "$p3" 2>/dev/null && net=true
    $dns && { msg_ok "Интернет: OK"; return 0; }; $net && { msg_warn "DNS нестабилен"; return 0; }; msg_error "Нет интернета"; return 1
}

wait_ha_ready() {
    local to="${1:-300}" el=0
    while [ $el -lt $to ]; do
        [ -f "${HASSIO_DIR}/homeassistant/configuration.yaml" ] && {
            local c; c=$(curl -s -o /dev/null -w "%{http_code}" -m 3 http://localhost:8123 2>/dev/null || echo 000)
            [ "$c" = "200" ] || [ "$c" = "401" ] && return 0; }
        sleep 5; el=$((el+5)); [ $((el%30)) -eq 0 ] && msg_dim "Ожидание HA... ${el}с"
    done; return 1
}

validate_ip() { local ip="$1" IFS='.'; read -ra o <<< "$ip"; [ ${#o[@]} -ne 4 ] && return 1; for x in "${o[@]}"; do [[ "$x" =~ ^[0-9]+$ ]] || return 1; [ "$x" -gt 255 ] && return 1; done; return 0; }
get_current_prefix() { ip -o -4 addr show 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f2; }

# ========================== OS-RELEASE ======================================

# HA Supervised проверяет PRETTY_NAME на наличие "Debian" + номер/codename.
# Armbian имеет PRETTY_NAME="Armbian ... bookworm/trixie" — без "Debian" → откажет.
# Чистый Debian имеет PRETTY_NAME="Debian GNU/Linux 12 (bookworm)" → пройдёт.

os_release_needs_faking() {
    detect_system_info

    # 1) PRETTY_NAME должен содержать "Debian"
    if ! echo "$CACHED_PRETTY_NAME" | grep -qi "Debian"; then
        return 0  # фейк НУЖЕН (Armbian, Ubuntu, и т.д.)
    fi

    # 2) codename должен быть в списке поддерживаемых HA
    if ! echo "$HA_SUPPORTED_CODENAMES" | grep -qw "$CACHED_CODENAME"; then
        return 0  # фейк НУЖЕН (sid, testing, и т.д.)
    fi

    return 1  # фейк НЕ нужен (чистый Debian bookworm/trixie/bullseye)
}

backup_os_release() {
    mkdir -p "$BACKUP_DIR"
    [ ! -f "${BACKUP_DIR}/os-release.original" ] && cp /etc/os-release "${BACKUP_DIR}/os-release.original"
}

fake_os_release() {
    backup_os_release
    detect_system_info

    # Определяем ближайший поддерживаемый Debian к реальной системе
    local target_codename="bookworm"
    local target_version="12"

    if [ "$CACHED_CODENAME" = "trixie" ] || [ "$CACHED_VERSION_ID" = "13" ]; then
        target_codename="trixie"; target_version="13"
    elif [ "$CACHED_CODENAME" = "bullseye" ] || [ "$CACHED_VERSION_ID" = "11" ]; then
        target_codename="bullseye"; target_version="11"
    elif [ "$CACHED_CODENAME" = "sid" ] || [ "$CACHED_CODENAME" = "testing" ]; then
        # sid/testing → ближайший stable = trixie
        target_codename="trixie"; target_version="13"
    fi
    # По умолчанию (Ubuntu и всё остальное) → bookworm

    cat > /etc/os-release << EOF
PRETTY_NAME="Debian GNU/Linux ${target_version} (${target_codename})"
NAME="Debian GNU/Linux"
VERSION_ID="${target_version}"
VERSION="${target_version} (${target_codename})"
VERSION_CODENAME=${target_codename}
ID=debian
HOME_URL="https://www.debian.org/"
SUPPORT_URL="https://www.debian.org/support"
BUG_REPORT_URL="https://bugs.debian.org/"
EOF
    cp /etc/os-release "$FAKED_OS_RELEASE"
    OS_RELEASE_FAKED=true
    msg_ok "os-release → Debian ${target_version} (${target_codename}) [фейк для HA]"
}

restore_os_release() {
    [ -f "${BACKUP_DIR}/os-release.original" ] && { cp "${BACKUP_DIR}/os-release.original" /etc/os-release; msg_ok "os-release восстановлен"; }
}

# ========================== PREFETCH DOCKER ================================
prefetch_docker_images() {
    [ "$DRY_RUN" = true ] && return 0; command -v docker &>/dev/null || return 0
    detect_system_info; local at=""
    case "$CACHED_MACHINE_ARCH" in x86_64) at="amd64";; aarch64) at="aarch64";; armv7l) at="armv7";; *) return 0;; esac
    msg_dim "Предзагрузка Docker-образов..."
    ( for img in supervisor dns cli audio multicast observer; do
          docker pull "ghcr.io/home-assistant/${at}-hassio-${img}:latest" 2>/dev/null || true; done ) &
    PREFETCH_PID=$!; disown "$PREFETCH_PID" 2>/dev/null || true
}
wait_prefetch() {
    [ -n "$PREFETCH_PID" ] && kill -0 "$PREFETCH_PID" 2>/dev/null && { msg_dim "Ожидание предзагрузки..."; wait "$PREFETCH_PID" 2>/dev/null || true; }
    PREFETCH_PID=""
}

# ========================== ROLLBACK ========================================
rollback_network() {
    msg_warn "Откат сети..."
    [ -f "${BACKUP_DIR}/interfaces.bak" ] && cp "${BACKUP_DIR}/interfaces.bak" /etc/network/interfaces 2>/dev/null
    [ -f "${BACKUP_DIR}/resolv.conf.bak" ] && cp "${BACKUP_DIR}/resolv.conf.bak" /etc/resolv.conf 2>/dev/null
    systemctl restart NetworkManager 2>/dev/null || true; systemctl start networking 2>/dev/null || true
}

# ========================== TUI =============================================
run_wizard() {
    command -v whiptail &>/dev/null || { apt-get update -qq 2>/dev/null; apt-get install -y whiptail -qq 2>/dev/null; }
    detect_system_info; local si="${CACHED_PRETTY_NAME:-${CACHED_CODENAME}} (${CACHED_MACHINE_ARCH})"
    is_armbian && si+=" [Armbian]"
    whiptail --title "HA Installer v${SCRIPT_VERSION}" --msgbox "Установщик Home Assistant Supervised\n\n${si}\n\nОбязательное ядро ставится всегда.\nВыберите модули на следующем экране." 14 64
    local cip cgw; cip=$(hostname -I 2>/dev/null | awk '{print $1}') || cip="н/д"; cgw=$(ip route 2>/dev/null | awk '/default/{print $3}' | head -1) || cgw="н/д"
    local ch; ch=$(whiptail --title "Компоненты" --checklist "Пробел/Enter" 30 72 16 \
        "ZRAM"      "▸ Swap в RAM"          ON  "EMMC"      "▸ Тюнинг eMMC/SD"      ON \
        "USBPOWER"  "▸ USB power fix"       ON  "─────1"    "── Безопасность ──"     OFF \
        "UFW"       "▸ UFW+Fail2Ban"        ON  "SSHHARD"   "▸ SSH hardening"        ON \
        "AUTOUPD"   "▸ Автообновления"      ON  "─────2"    "── Мониторинг ──"       OFF \
        "WATCHDOG"  "▸ Watchdog+Cleanup"    ON  "THERMAL"   "▸ Температура"          ON \
        "BACKUP"    "▸ Бэкап"               ON  "HACS"      "▸ HACS"                 ON \
        "─────3"    "── Сеть ──"            OFF "HOSTNAME"  "▸ homeassistant"        ON \
        "STATICIP"  "▸ Стат. IP (${cip})"   OFF "TELEGRAM"  "▸ Telegram"             OFF \
        3>&1 1>&2 2>&3) || { echo "Отменено."; exit 0; }
    OPT_ZRAM=false; OPT_EMMC_TUNING=false; OPT_USB_POWER=false; OPT_UFW=false
    OPT_SSH_HARDENING=false; OPT_AUTOUPDATE=false; OPT_WATCHDOG=false; OPT_THERMAL=false
    OPT_BACKUP=false; OPT_HACS=false; OPT_HOSTNAME=false; OPT_STATIC_IP=false; OPT_TELEGRAM=false
    [[ $ch == *ZRAM* ]] && OPT_ZRAM=true;     [[ $ch == *EMMC* ]] && OPT_EMMC_TUNING=true
    [[ $ch == *USBPOWER* ]] && OPT_USB_POWER=true; [[ $ch == *UFW* ]] && OPT_UFW=true
    [[ $ch == *SSHHARD* ]] && OPT_SSH_HARDENING=true; [[ $ch == *AUTOUPD* ]] && OPT_AUTOUPDATE=true
    [[ $ch == *WATCHDOG* ]] && OPT_WATCHDOG=true; [[ $ch == *THERMAL* ]] && OPT_THERMAL=true
    [[ $ch == *BACKUP* ]] && OPT_BACKUP=true; [[ $ch == *HACS* ]] && OPT_HACS=true
    [[ $ch == *HOSTNAME* ]] && OPT_HOSTNAME=true; [[ $ch == *STATICIP* ]] && OPT_STATIC_IP=true
    [[ $ch == *TELEGRAM* ]] && OPT_TELEGRAM=true
    if [ "$OPT_STATIC_IP" = true ]; then
        while true; do STATIC_IP=$(whiptail --title "IP" --inputbox "IP:" 10 50 "$cip" 3>&1 1>&2 2>&3) || { OPT_STATIC_IP=false; break; }
            validate_ip "$STATIC_IP" && break; whiptail --title "Ошибка" --msgbox "Неверный IP: ${STATIC_IP}" 8 40; done
        [ "$OPT_STATIC_IP" = true ] && {
            STATIC_GW=$(whiptail --title "Шлюз" --inputbox "Шлюз:" 10 50 "$cgw" 3>&1 1>&2 2>&3) || STATIC_GW="$cgw"
            STATIC_DNS=$(whiptail --title "DNS" --inputbox "DNS:" 10 50 "8.8.8.8,1.1.1.1" 3>&1 1>&2 2>&3) || STATIC_DNS="8.8.8.8,1.1.1.1"; }; fi
    if [ "$OPT_TELEGRAM" = true ]; then
        TG_TOKEN=$(whiptail --title "Telegram" --inputbox "Токен:" 10 60 3>&1 1>&2 2>&3) || TG_TOKEN=""
        TG_CHAT=$(whiptail --title "Telegram" --inputbox "Chat ID:" 10 60 3>&1 1>&2 2>&3) || TG_CHAT=""
        { [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; } && OPT_TELEGRAM=false; fi
    local s="Установить:\n\n  ✔ HA Supervised + Docker + OS-Agent\n"
    [ "$OPT_ZRAM" = true ] && s+="  ✔ ZRAM\n"; [ "$OPT_EMMC_TUNING" = true ] && s+="  ✔ Тюнинг eMMC\n"
    [ "$OPT_USB_POWER" = true ] && s+="  ✔ USB Fix\n"; [ "$OPT_UFW" = true ] && s+="  ✔ UFW+F2B\n"
    [ "$OPT_SSH_HARDENING" = true ] && s+="  ✔ SSH\n"; [ "$OPT_AUTOUPDATE" = true ] && s+="  ✔ Автообн.\n"
    [ "$OPT_WATCHDOG" = true ] && s+="  ✔ Watchdog\n"; [ "$OPT_THERMAL" = true ] && s+="  ✔ Терм.\n"
    [ "$OPT_BACKUP" = true ] && s+="  ✔ Бэкап\n"; [ "$OPT_HACS" = true ] && s+="  ✔ HACS\n"
    [ "$OPT_HOSTNAME" = true ] && s+="  ✔ Hostname\n"; [ "$OPT_STATIC_IP" = true ] && s+="  ✔ IP:${STATIC_IP}\n"
    [ "$OPT_TELEGRAM" = true ] && s+="  ✔ Telegram\n"; s+="\nНачать?"
    whiptail --title "OK?" --yesno "$s" 26 56 || { echo "Отменено."; exit 0; }
}

# ========================== PRE-FLIGHT ======================================
step_preflight() {
    local sid="preflight"; is_done "$sid" && return 0; header "ПРЕДВАРИТЕЛЬНАЯ ПРОВЕРКА"
    detect_system_info; local err=0 wrn=0
    [ "$CACHED_ARCH" = "unknown" ] && { msg_error "Архитектура: ${CACHED_MACHINE_ARCH}"; err=$((err+1)); } || msg_ok "Архитектура: ${CACHED_MACHINE_ARCH} (${CACHED_ARCH})"
    msg_info "Дистрибутив: ${CACHED_PRETTY_NAME:-${CACHED_CODENAME:-?}}"
    msg_info "os-release ID=${CACHED_OS_ID}, codename=${CACHED_CODENAME}"
    is_armbian && msg_info "Armbian: $(grep VERSION= /etc/armbian-release 2>/dev/null | cut -d= -f2 || echo да)"
    is_trixie && msg_info "Debian 13 Trixie"
    # Предупреждение о необходимости фейка
    if os_release_needs_faking; then
        msg_warn "PRETTY_NAME не содержит 'Debian' → os-release будет подменён для HA"
    else msg_ok "os-release совместим с HA Supervised"; fi
    if is_armbian; then
        is_pkg_installed armbian-zram-config && [ "$OPT_ZRAM" = true ] && { msg_warn "armbian-zram-config конфликт"; wrn=$((wrn+1)); }
        is_pkg_installed armbian-ramlog && msg_info "armbian-ramlog активен"
        systemctl is-active --quiet armbian-hardware-optimization 2>/dev/null && msg_info "armbian-hw → CPU"; fi
    local fm; fm=$(df -m / | awk 'NR==2{print $4}')
    [ "$fm" -lt 4000 ] && { msg_error "Диск: ${fm}MB"; err=$((err+1)); } || { [ "$fm" -lt 6000 ] && { msg_warn "Диск: ${fm}MB"; wrn=$((wrn+1)); } || msg_ok "Диск: ${fm}MB"; }
    local rm; rm=$(free -m | awk '/Mem:/{print $2}')
    [ "$rm" -lt 900 ] && { msg_error "RAM: ${rm}MB"; err=$((err+1)); } || { [ "$rm" -lt 1800 ] && { msg_warn "RAM: ${rm}MB"; wrn=$((wrn+1)); } || msg_ok "RAM: ${rm}MB"; }
    local kv; kv=$(uname -r | cut -d. -f1)
    [ "$kv" -lt 4 ] && { msg_error "Ядро $(uname -r)"; err=$((err+1)); } || { [ "$kv" -lt 5 ] && { msg_warn "Ядро $(uname -r)"; wrn=$((wrn+1)); } || msg_ok "Ядро: $(uname -r)"; }
    [ -f /sys/fs/cgroup/cgroup.controllers ] && msg_ok "cgroups: v2" || { [ -d /sys/fs/cgroup/unified ] && msg_ok "cgroups: hybrid" || { msg_warn "cgroups: v1"; wrn=$((wrn+1)); }; }
    check_internet || err=$((err+1))
    ss -tlnp 2>/dev/null | grep -q ':8123 ' && { msg_warn "Порт 8123 занят"; wrn=$((wrn+1)); } || msg_ok "Порт 8123 свободен"
    for svc in apache2 nginx lighttpd; do systemctl is-active --quiet "$svc" 2>/dev/null && { msg_warn "${svc}"; wrn=$((wrn+1)); }; done
    local t; t=$(get_cpu_temp); [ -n "$t" ] && { [ "$t" -ge 75 ] && { msg_warn "CPU: ${t}°C!"; wrn=$((wrn+1)); } || msg_ok "CPU: ${t}°C"; }
    is_trixie && command -v iptables &>/dev/null && {
        iptables --version 2>/dev/null | grep -q "nf_tables" && msg_info "iptables-nft"
        iptables --version 2>/dev/null | grep -q "legacy" && { msg_warn "iptables-legacy"; wrn=$((wrn+1)); }; }
    separator
    [ $err -gt 0 ] && { msg_error "Критических: ${err}"; return 1; }
    [ $wrn -gt 0 ] && msg_warn "Предупреждений: ${wrn}" || msg_ok "Все проверки пройдены"
    mark_done "$sid"
}

# ========================== CHECK ==========================================
do_check() {
    header "ДИАГНОСТИКА"; detect_system_info
    local ip t; ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="?"; t=$(get_cpu_temp)
    echo -e "  ${BOLD}Система${NC}"; msg_info "Hostname:    $(hostname 2>/dev/null)"; msg_info "IP:          ${ip}"
    msg_info "PRETTY_NAME: ${CACHED_PRETTY_NAME}"; msg_info "ID:          ${CACHED_OS_ID}, codename: ${CACHED_CODENAME}"
    is_armbian && msg_info "Armbian:     да"; msg_info "Ядро:        $(uname -r)"
    [ -n "$t" ] && msg_info "CPU:         ${t}°C"; separator
    echo -e "  ${BOLD}Компоненты${NC}"
    command -v docker &>/dev/null && msg_ok "Docker: $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')" || msg_error "Docker: нет"
    command -v gdbus &>/dev/null && gdbus introspect --system --dest io.hass.os --object-path /io/hass/os &>/dev/null 2>&1 && msg_ok "OS-Agent" || msg_warn "OS-Agent: нет"
    local hs; hs=$(systemctl is-active hassio-supervisor 2>/dev/null) || hs="нет"
    [ "$hs" = "active" ] && msg_ok "Supervisor: ${hs}" || msg_error "Supervisor: ${hs}"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$' && msg_ok "HA Core: $(docker inspect -f '{{.State.Status}}' homeassistant 2>/dev/null)" || msg_error "HA Core: нет"
    [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" = "Y" ] && msg_ok "AppArmor" || msg_warn "AppArmor: выкл"
    [ -f "$FAKED_OS_RELEASE" ] && msg_info "os-release: фейк → $(grep PRETTY_NAME "$FAKED_OS_RELEASE" | cut -d'"' -f2)" || msg_info "os-release: оригинал"
    separator; echo -e "  ${BOLD}Ресурсы${NC}"
    msg_info "RAM:  $(free -h | awk '/Mem:/{printf "%s/%s",$3,$2}')"; msg_info "Swap: $(free -h | awk '/Swap:/{printf "%s/%s",$3,$2}')"
    msg_info "Disk: $(df -h / | awk 'NR==2{printf "%s/%s (%s)",$3,$2,$5}')"; separator
    echo -e "  ${BOLD}Контейнеры${NC}"
    command -v docker &>/dev/null && docker ps --format '  {{.Names}}|{{.Status}}' 2>/dev/null | while IFS='|' read -r n s; do echo "$s"|grep -q Up && echo -e "  ${CHECK} ${n} ${DIM}${s}${NC}" || echo -e "  ${CROSS} ${n} ${RED}${s}${NC}"; done
    separator; load_config; [ -n "${INSTALLED_VERSION:-}" ] && msg_info "Установщик: v${INSTALLED_VERSION} (${INSTALLED_DATE:-?})"
    [ -f "$STATE_FILE" ] && { while IFS='|' read -r sid ts ver; do local ds=""; [ -n "$ts" ] && ds=" ($(date -d "@$ts" '+%m-%d %H:%M' 2>/dev/null||echo "$ts"))"; msg_ok "${sid}${ds} [v${ver:-?}]"; done < "$STATE_FILE"; }
    separator; local vo vh; vo=$(get_latest_release "home-assistant/os-agent"); vh=$(get_latest_release "home-assistant/supervised-installer")
    [ -n "$vo" ] && msg_info "OS-Agent: ${vo}" || msg_warn "OS-Agent: ?"; [ -n "$vh" ] && msg_info "HA Sup:   ${vh}" || msg_warn "HA Sup: ?"
    echo ""
}

do_status() { while true; do clear; show_banner
    local ip t; ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="?"; t=$(get_cpu_temp)
    echo -e "  ${BOLD}IP:${NC} $ip  ${BOLD}CPU:${NC} ${t:-?}°C  ${BOLD}Up:${NC} $(uptime -p 2>/dev/null||echo ?)"
    echo -e "  ${BOLD}RAM:${NC} $(free -h|awk '/Mem:/{printf "%s/%s",$3,$2}')  ${BOLD}Swap:${NC} $(free -h|awk '/Swap:/{printf "%s/%s",$3,$2}')"; separator
    docker ps --format '  {{.Names}}|{{.Status}}' 2>/dev/null | while IFS='|' read -r n s; do echo "$s"|grep -q Up && echo -e "  ${CHECK} ${n} ${DIM}${s}${NC}" || echo -e "  ${CROSS} ${n} ${RED}${s}${NC}"; done
    local hc; hc=$(curl -s -o /dev/null -w "%{http_code}" -m 3 http://localhost:8123 2>/dev/null||echo 000); separator
    [ "$hc" != "000" ] && echo -e "  ${CHECK} HA: ${GREEN}${hc}${NC}" || echo -e "  ${CROSS} HA: ${RED}нет${NC}"
    echo -e "  ${DIM}5с. Ctrl+C${NC}"; sleep 5; done
}

do_uninstall() {
    header "УДАЛЕНИЕ HA SUPERVISED"; local ok=false
    command -v whiptail &>/dev/null && whiptail --title "Удаление" --yesno "Удалить HA Supervised?" 10 50 && ok=true \
        || { echo -en " ${WARN} ${YELLOW}Удалить? (yes/no): ${NC}"; read -r r; [ "$r" = yes ] && ok=true; }
    [ "$ok" != true ] && { msg_info "Отменено."; exit 0; }
    systemctl stop hassio-supervisor hassio-apparmor 2>/dev/null || true
    docker ps -a --filter "label=io.hass.type" --format '{{.Names}}' 2>/dev/null | while IFS= read -r c; do docker rm -f "$c" 2>/dev/null; done
    for c in homeassistant hassio_supervisor hassio_cli hassio_audio hassio_dns hassio_multicast hassio_observer; do docker rm -f "$c" 2>/dev/null || true; done
    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -iE "homeassistant|hassio|home-assistant" | while IFS= read -r i; do docker rmi -f "$i" 2>/dev/null; done
    for svc in hassio-supervisor hassio-apparmor; do systemctl disable "$svc" 2>/dev/null; rm -f "/etc/systemd/system/${svc}.service"; done
    rm -rf /etc/systemd/system/hassio-supervisor.service.d; systemctl daemon-reload 2>/dev/null
    dpkg --purge homeassistant-supervised os-agent 2>/dev/null || true
    rm -f /usr/local/bin/ha-{notify,watchdog,cleanup,net-recovery,backup,restore,health,thermal} /etc/cron.d/ha-tools /etc/udev/rules.d/99-ha-usb-power.rules /etc/ssh/sshd_config.d/99-ha-hardening.conf /etc/sysctl.d/99-ha-swap.conf /etc/systemd/journald.conf.d/ha-tuning.conf 2>/dev/null
    [ -f /etc/ufw/after.rules ] && { sed -i '/# BEGIN HA-INSTALLER DOCKER-USER/,/# END HA-INSTALLER DOCKER-USER/d' /etc/ufw/after.rules 2>/dev/null; ufw reload 2>/dev/null || true; }
    [ -d "$HASSIO_DIR" ] && { echo -en " ${WARN} ${YELLOW}Данные HA? (yes/no): ${NC}"; read -r r; [ "$r" = yes ] && rm -rf "$HASSIO_DIR"; }
    [ -d "$HA_BACKUP_DIR" ] && { echo -en " ${WARN} ${YELLOW}Бэкапы? (yes/no): ${NC}"; read -r r; [ "$r" = yes ] && rm -rf "$HA_BACKUP_DIR"; }
    restore_os_release; rm -f "$FAKED_OS_RELEASE" 2>/dev/null; rm -rf "$HA_INSTALLER_DIR" /root/.ha_install_state /root/.ha_install_backup 2>/dev/null
    docker system prune -f 2>/dev/null; rm -f "$GRACE_MARKER" 2>/dev/null; header "УДАЛЕНО"
}

do_update() {
    header "ОБНОВЛЕНИЕ"; load_config; detect_system_info
    local co="${OA_VERSION:-}" ch="${HA_VERSION:-}" lo lh
    lo=$(get_latest_release "home-assistant/os-agent"); lh=$(get_latest_release "home-assistant/supervised-installer")
    msg_info "OS-Agent: ${co:-?} → ${lo:-?}"; msg_info "HA: ${ch:-?} → ${lh:-?}"
    [ "$co" = "$lo" ] && [ "$ch" = "$lh" ] && { msg_ok "Всё актуально"; return 0; }
    setup_tmpdir
    if [ "$co" != "$lo" ] && [ -n "$lo" ]; then
        download_file "https://github.com/home-assistant/os-agent/releases/download/${lo}/os-agent_${lo}_linux_${CACHED_ARCH}.deb" "${HA_TMP}/os-agent.deb" "OS-Agent ${lo}"
        run_cmd "OS-Agent" dpkg -i "${HA_TMP}/os-agent.deb"; RESOLVED_OA_VER="$lo"; fi
    RESOLVED_HA_VER="${lh:-$ch}"; RESOLVED_OA_VER="${RESOLVED_OA_VER:-$lo}"; save_config; msg_ok "Обновлено"
}

# ========================== АРГУМЕНТЫ =======================================
show_help() { cat << HELP
${BOLD}HA Installer v${SCRIPT_VERSION}${NC}
  sudo ./install.sh              Мастер
  -c, --check    -s, --status    -u, --uninstall    --update
  --skip-update  --dry-run       --silent           --reset-state
  --machine TYPE --os-agent-ver X --ha-ver X
  Пути: ${HA_INSTALLER_DIR}  ${HA_BACKUP_DIR}
HELP
}
parse_args() { [ $# -eq 0 ] && return; RUN_WIZARD=false
    while [[ $# -gt 0 ]]; do case "$1" in
        -h|--help) show_help; exit 0;; -c|--check) CHECK_ONLY=true;; -s|--status) SHOW_STATUS=true;;
        -u|--uninstall) UNINSTALL=true;; --update) DO_UPDATE=true;; --reset-state) reset_state; exit 0;;
        --skip-update) SKIP_UPDATE=true;; --dry-run) DRY_RUN=true;; --silent) SILENT=true; RUN_WIZARD=false;;
        --machine) shift; [ $# -eq 0 ] && { msg_error "--machine ?"; exit 1; }; HA_MACHINE="$1"; MACHINE_EXPLICIT=true;;
        --machine=*) HA_MACHINE="${1#*=}"; MACHINE_EXPLICIT=true;;
        --os-agent-ver) shift; OVERRIDE_OS_AGENT_VER="$1";; --os-agent-ver=*) OVERRIDE_OS_AGENT_VER="${1#*=}";;
        --ha-ver) shift; OVERRIDE_HA_VER="$1";; --ha-ver=*) OVERRIDE_HA_VER="${1#*=}";;
        *) msg_error "?: $1"; show_help; exit 1;; esac; shift; done
}
show_banner() { [ "$CHECK_ONLY" != true ] && [ "$UNINSTALL" != true ] && [ "$SHOW_STATUS" != true ] && clear
    [ "$SILENT" != true ] && { echo -e "${BLUE}    ╦ ╦┌─┐┌┬┐┌─┐  ╔═╗┌─┐┌─┐┬┌─┐┌┬┐┌─┐┌┐┌┌┬┐${NC}"
        echo -e "${BLUE}    ╠═╣│ ││││├┤   ╠═╣└─┐└─┐│└─┐ │ ├─┤│││ │ ${NC}"
        echo -e "${BLUE}    ╩ ╩└─┘┴ ┴└─┘  ╩ ╩└─┘└─┘┴└─┘ ┴ ┴ ┴┘└┘ ┴ ${NC}"
        echo -e "${WHITE}${BOLD}    ULTIMATE INSTALLER v${SCRIPT_VERSION}${NC}"; separator; }
}

# ========================== ШАГИ ============================================
step_update_system() { local sid="update"; is_done "$sid" && return 0; header "ШАГ 1 — ОБНОВЛЕНИЕ"
    [ "$SKIP_UPDATE" = false ] && { run_cmd_fatal "apt update" apt-get update -y; run_cmd "apt upgrade" apt-get upgrade -y -o Dpkg::Options::="--force-confold"; } || msg_warn "Пропущено"; mark_done "$sid"; }

step_install_deps() { local sid="deps"; is_done "$sid" && return 0; header "ШАГ 2 — ЗАВИСИМОСТИ"
    detect_system_info
    local pkgs=(apparmor avahi-daemon bluez ca-certificates cifs-utils curl dbus gnupg jq libglib2.0-bin network-manager nfs-common systemd-timesyncd udisks2 usbutils wget qrencode)
    for p in lsb-release systemd-resolved systemd-journal-remote; do pkg_available "$p" && pkgs+=("$p"); done
    if [ "$OPT_ZRAM" = true ]; then
        if is_armbian && is_pkg_installed armbian-zram-config; then true
        elif pkg_available zram-tools; then pkgs+=(zram-tools)
        elif pkg_available systemd-zram-generator; then pkgs+=(systemd-zram-generator); fi; fi
    [ "$OPT_UFW" = true ] && pkgs+=(ufw fail2ban); [ "$OPT_AUTOUPDATE" = true ] && pkgs+=(unattended-upgrades)
    [ "$OPT_BACKUP" = true ] && pkg_available pigz && pkgs+=(pigz)
    is_armbian && systemctl is-active --quiet armbian-hardware-optimization 2>/dev/null || {
        for p in linux-cpupower cpufrequtils; do pkg_available "$p" && pkgs+=("$p"); done; }
    local ti=(); for p in "${pkgs[@]}"; do is_pkg_installed "$p" || ti+=("$p"); done
    [ ${#ti[@]} -eq 0 ] && msg_ok "Все установлены" || {
        run_cmd "Установка (${#ti[@]})" apt-get install -y "${ti[@]}" || {
            local f=(); for p in "${ti[@]}"; do run_cmd "$p" apt-get install -y "$p" || f+=("$p"); done
            [ ${#f[@]} -gt 0 ] && msg_warn "Нет: ${f[*]}"; }; }
    run_cmd "apt fix" apt-get -f install -y
    [ "$OPT_EMMC_TUNING" = true ] && apt-get clean 2>/dev/null || true; mark_done "$sid"; }

step_configure_network() { local sid="network"; is_done "$sid" && return 0; header "ШАГ 3 — СЕТЬ"
    mkdir -p "$BACKUP_DIR" /etc/NetworkManager/conf.d
    local cip; cip=$(hostname -I 2>/dev/null | awk '{print $1}'); [ -n "$cip" ] && msg_info "IP: ${cip}"
    printf '[keyfile]\nunmanaged-devices=none\n[device]\nwifi.scan-rand-mac-address=no\n' > /etc/NetworkManager/conf.d/10-ha-managed.conf
    printf '[main]\ndns=systemd-resolved\n' > /etc/NetworkManager/conf.d/10-dns-resolved.conf
    [ -f /etc/network/interfaces ] && { cp /etc/network/interfaces "$BACKUP_DIR/interfaces.bak" 2>/dev/null; }
    printf 'source /etc/network/interfaces.d/*\nauto lo\niface lo inet loopback\n' > /etc/network/interfaces
    systemctl is-active --quiet systemd-resolved 2>/dev/null || { systemctl enable systemd-resolved 2>/dev/null; systemctl start systemd-resolved 2>/dev/null; }
    local rt; rt=$(readlink -f /etc/resolv.conf 2>/dev/null)
    [[ "$rt" != */run/systemd/resolve/* ]] && { cp /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.bak" 2>/dev/null; ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null; }
    who 2>/dev/null | grep -q pts && msg_warn "SSH-сессия"
    systemctl list-unit-files networking.service &>/dev/null 2>&1 && systemctl is-active --quiet networking 2>/dev/null && systemctl disable networking 2>/dev/null
    systemctl enable NetworkManager 2>/dev/null; systemctl restart NetworkManager 2>/dev/null
    if [ "$OPT_STATIC_IP" = true ] && [ -n "$STATIC_IP" ]; then sleep 3
        local ac; ac=$(nmcli -t -f NAME con show --active 2>/dev/null | head -1)
        [ -n "$ac" ] && { local pf; pf=$(get_current_prefix); [ -z "$pf" ] && pf="24"
            nmcli con mod "$ac" ipv4.addresses "${STATIC_IP}/${pf}" ipv4.gateway "$STATIC_GW" ipv4.dns "$STATIC_DNS" ipv4.method manual 2>/dev/null
            nmcli con up "$ac" 2>/dev/null; msg_ok "IP: ${STATIC_IP}/${pf}"; }; fi
    local r=0 ni=""; while [ $r -lt 6 ]; do sleep 5; ni=$(hostname -I 2>/dev/null | awk '{print $1}')
        [ -n "$ni" ] && { msg_ok "Сеть: ${ni}"; break; }; r=$((r+1)); done
    [ $r -ge 6 ] && { rollback_network; sleep 5; ni=$(hostname -I 2>/dev/null | awk '{print $1}')
        [ -n "$ni" ] && msg_ok "Восст.: ${ni}" || { msg_error "Нет сети!"; return 1; }; }
    mark_done "$sid"; }

step_configure_apparmor() { local sid="apparmor"; is_done "$sid" && return 0; header "ШАГ 4 — APPARMOR"
    local aa; aa=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) || aa="N"
    if [ "$aa" = "Y" ]; then msg_ok "AppArmor активен"
    else local patched=false
        for f in /boot/armbianEnv.txt /boot/uEnv.txt /boot/extlinux/extlinux.conf; do [ -f "$f" ] || continue
            cp "$f" "${BACKUP_DIR}/$(basename "$f").bak" 2>/dev/null; grep -q "apparmor=1" "$f" && { patched=true; continue; }
            [[ "$f" == *extlinux.conf ]] && sed -i '/^[[:space:]]*append/ s/$/ apparmor=1 security=apparmor/' "$f" \
                || { grep -q "^extraargs=" "$f" && sed -i 's|^extraargs=.*|& apparmor=1 security=apparmor|' "$f" || echo "extraargs=apparmor=1 security=apparmor" >> "$f"; }
            msg_ok "$(basename "$f")"; patched=true; done
        [ "$patched" = false ] && msg_error "Загрузчик?" || msg_warn "AppArmor→reboot"; fi
    systemctl enable apparmor 2>/dev/null; systemctl start apparmor 2>/dev/null; mark_done "$sid"; }

step_performance() { local sid="perf"; is_done "$sid" && return 0; header "ШАГ 5 — ПРОИЗВОДИТЕЛЬНОСТЬ"
    if [ "$OPT_ZRAM" = true ]; then [ -f /swapfile ] && { swapoff /swapfile 2>/dev/null; rm -f /swapfile; sed -i '/swapfile/d' /etc/fstab; }
        if is_armbian && is_pkg_installed armbian-zram-config; then msg_ok "ZRAM: Armbian"
        elif is_pkg_installed zram-tools; then printf 'ALGO=lz4\nPERCENT=60\n' > /etc/default/zramswap; systemctl enable zramswap 2>/dev/null; systemctl restart zramswap 2>/dev/null; msg_ok "ZRAM"
        elif is_pkg_installed systemd-zram-generator; then mkdir -p /etc/systemd/zram-generator.conf.d; printf '[zram0]\nzram-size = ram * 0.6\ncompression-algorithm = lz4\n' > /etc/systemd/zram-generator.conf.d/ha.conf; schedule_daemon_reload; flush_daemon_reload; systemctl start /dev/zram0 2>/dev/null; msg_ok "ZRAM"
        elif modprobe zram 2>/dev/null && [ -b /dev/zram0 ]; then local rb; rb=$(awk '/MemTotal/{print $2}' /proc/meminfo); echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null; echo $((rb*1024*60/100)) > /sys/block/zram0/disksize 2>/dev/null; mkswap /dev/zram0 >/dev/null 2>&1 && swapon -p 100 /dev/zram0 2>/dev/null; msg_ok "ZRAM"
        else msg_warn "ZRAM n/a"; fi
    else swapon --show 2>/dev/null | grep -q . || { dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none 2>/dev/null && { chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile; }; grep -q swapfile /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab; }; fi
    if is_armbian && systemctl is-active --quiet armbian-hardware-optimization 2>/dev/null; then msg_dim "CPU: Armbian"
    elif command -v cpupower &>/dev/null; then cpupower frequency-set -g performance 2>/dev/null; msg_ok "CPU: performance"
    elif command -v cpufreq-set &>/dev/null; then echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils; msg_ok "CPU: performance"
    else local gs=false; for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -f "$g" ] && { echo performance>"$g" 2>/dev/null; gs=true; }; done; $gs && msg_ok "CPU: performance (sysfs)"; fi
    if [ "$OPT_EMMC_TUNING" = true ]; then echo "vm.swappiness=10" > /etc/sysctl.d/99-ha-swap.conf; sysctl -p /etc/sysctl.d/99-ha-swap.conf >/dev/null 2>&1
        grep -q noatime /etc/fstab 2>/dev/null || { cp /etc/fstab "${BACKUP_DIR}/fstab.bak" 2>/dev/null; sed -i '/^\//s/defaults/defaults,noatime,commit=600/' /etc/fstab 2>/dev/null; }
        mkdir -p /etc/systemd/journald.conf.d; is_armbian && is_pkg_installed armbian-ramlog || { printf '[Journal]\nSystemMaxUse=50M\nSystemMaxFileSize=10M\nMaxRetentionSec=7day\nCompress=yes\nStorage=persistent\nSystemKeepFree=100M\n' > /etc/systemd/journald.conf.d/ha-tuning.conf; systemctl restart systemd-journald 2>/dev/null; }
        local rd="" rs=""; rs=$(findmnt -n -o SOURCE / 2>/dev/null); [ -n "$rs" ] && [ -b "$rs" ] && rd=$(lsblk -no PKNAME "$rs" 2>/dev/null | head -1)
        [ -n "$rd" ] && [ "$(cat "/sys/block/${rd}/queue/rotational" 2>/dev/null)" = "0" ] && { [[ "$rd" == nvme* ]] && echo none>"/sys/block/${rd}/queue/scheduler" 2>/dev/null; [[ "$rd" == mmcblk* || "$rd" == sd* ]] && echo mq-deadline>"/sys/block/${rd}/queue/scheduler" 2>/dev/null; }; fi
    [ "$OPT_USB_POWER" = true ] && { for d in /sys/bus/usb/devices/*/power/autosuspend; do [ -f "$d" ] && echo -1>"$d" 2>/dev/null; done
        echo 'ACTION=="add", SUBSYSTEM=="usb", ATTR{power/autosuspend}="-1"' > /etc/udev/rules.d/99-ha-usb-power.rules; udevadm control --reload-rules 2>/dev/null; msg_ok "USB fix"; }
    mark_done "$sid"; }

step_install_docker() { local sid="docker"; is_done "$sid" && return 0; header "ШАГ 6 — DOCKER"
    command -v docker &>/dev/null && msg_ok "Docker: $(docker --version 2>/dev/null | awk '{print $3}'|tr -d ',')" || {
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        spinner_start "Docker"; curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || { spinner_stop; msg_error "Docker!"; exit 1; }; spinner_stop; hash -r 2>/dev/null; msg_ok "Docker"; }
    mkdir -p /etc/docker; [ ! -f /etc/docker/daemon.json ] && echo '{"log-driver":"journald","storage-driver":"overlay2"}' > /etc/docker/daemon.json
    systemctl enable docker 2>/dev/null; systemctl restart docker 2>/dev/null
    local dw=0; while ! docker info &>/dev/null; do sleep 2; dw=$((dw+2)); [ $dw -ge 30 ] && { msg_error "Docker!"; exit 1; }; done
    prefetch_docker_images; mark_done "$sid"; }

step_resolve_versions() { local sid="versions"
    if is_done "$sid"; then load_config; RESOLVED_OA_VER="${OA_VERSION:-}"; RESOLVED_HA_VER="${HA_VERSION:-}"
        [ -n "$OVERRIDE_OS_AGENT_VER" ] && RESOLVED_OA_VER="$OVERRIDE_OS_AGENT_VER"
        [ -n "$OVERRIDE_HA_VER" ] && RESOLVED_HA_VER="$OVERRIDE_HA_VER"
        [ -n "$RESOLVED_OA_VER" ] && [ -n "$RESOLVED_HA_VER" ] && { msg_ok "Версии: OA=${RESOLVED_OA_VER} HA=${RESOLVED_HA_VER}"; return 0; }; fi
    header "ШАГ 7 — ВЕРСИИ"
    [ -n "$OVERRIDE_OS_AGENT_VER" ] && RESOLVED_OA_VER="$OVERRIDE_OS_AGENT_VER" || { msg_action "OS-Agent..."; RESOLVED_OA_VER=$(get_latest_release "home-assistant/os-agent"); }
    [ -z "$RESOLVED_OA_VER" ] && { msg_error "OS-Agent: версия?"; exit 1; }
    [ -n "$OVERRIDE_HA_VER" ] && RESOLVED_HA_VER="$OVERRIDE_HA_VER" || { msg_action "HA..."; RESOLVED_HA_VER=$(get_latest_release "home-assistant/supervised-installer"); }
    [ -z "$RESOLVED_HA_VER" ] && { msg_error "HA: версия?"; exit 1; }
    msg_ok "OA:${RESOLVED_OA_VER} HA:${RESOLVED_HA_VER}"; mark_done "$sid"; }

step_download_packages() { local sid="download"; is_done "$sid" && return 0; header "ШАГ 8 — ЗАГРУЗКА"
    detect_system_info; local tf; tf=$(df -m "$HA_TMP" 2>/dev/null | awk 'NR==2{print $4}')
    [ "${tf:-0}" -lt 200 ] && { HA_TMP="/tmp/ha-install"; mkdir -p "$HA_TMP"; }
    download_file "https://github.com/home-assistant/os-agent/releases/download/${RESOLVED_OA_VER}/os-agent_${RESOLVED_OA_VER}_linux_${CACHED_ARCH}.deb" "${HA_TMP}/os-agent.deb" "OS-Agent" & local d1=$!
    download_file "https://github.com/home-assistant/supervised-installer/releases/download/${RESOLVED_HA_VER}/homeassistant-supervised.deb" "${HA_TMP}/ha.deb" "HA" & local d2=$!
    local fail=false; wait "$d1" || fail=true; wait "$d2" || fail=true; [ "$fail" = true ] && { msg_error "Загрузка!"; exit 1; }
    msg_ok "Загружены"; mark_done "$sid"; }

step_install_os_agent() { local sid="osagent"; is_done "$sid" && return 0; header "ШАГ 9 — OS-AGENT"
    run_cmd_fatal "OS-Agent" dpkg -i "${HA_TMP}/os-agent.deb"
    command -v gdbus &>/dev/null && gdbus introspect --system --dest io.hass.os --object-path /io/hass/os &>/dev/null 2>&1 && msg_ok "D-Bus OK" || msg_warn "D-Bus позже"; mark_done "$sid"; }

step_install_ha() { local sid="ha"; is_done "$sid" && return 0; header "ШАГ 10 — HOME ASSISTANT SUPERVISED"
    mkdir -p "$BACKUP_DIR"
    if os_release_needs_faking; then
        msg_warn "PRETTY_NAME='${CACHED_PRETTY_NAME}' — не содержит 'Debian'"
        fake_os_release
    else msg_ok "os-release: ${CACHED_PRETTY_NAME} (OK для HA)"; backup_os_release; fi
    wait_prefetch; msg_action "Установка (5-15 мин)..."; msg_dim "Машина: ${HA_MACHINE}"; export MACHINE="$HA_MACHINE"
    set +o pipefail; DEBIAN_FRONTEND=noninteractive dpkg -i "${HA_TMP}/ha.deb" 2>&1 \
        | grep --line-buffered -iE "(pull|download|unpack|setting up|error|warn)" | grep -vi "cgroup v1" \
        | while IFS= read -r l; do echo -e "    ${BLUE}│${NC} ${l}"; done
    local de=${PIPESTATUS[0]}; set -o pipefail
    [ $de -ne 0 ] && { msg_warn "dpkg ${de}"; apt-get install -f -y >/dev/null 2>&1 || true; }
    if [ "$OS_RELEASE_FAKED" = true ]; then
        mkdir -p /etc/systemd/system/hassio-supervisor.service.d
        cat > /etc/systemd/system/hassio-supervisor.service.d/fix-os-release.conf << DROPIN
[Service]
ExecStartPre=/bin/bash -c 'F="${BACKUP_DIR}/os-release.faked"; [ -f "\$F" ] && cp "\$F" /etc/os-release'
ExecStopPost=/bin/bash -c 'O="${BACKUP_DIR}/os-release.original"; [ -f "\$O" ] && cp "\$O" /etc/os-release'
DROPIN
        schedule_daemon_reload; flush_daemon_reload; restore_os_release
        msg_info "Drop-in: фейк при старте, восстановление при стопе"; fi
    msg_action "Ожидание supervisor..."
    local sw=0; while ! systemctl is-active --quiet hassio-supervisor 2>/dev/null; do sleep 5; sw=$((sw+5)); [ $sw -ge 120 ] && { msg_warn "Таймаут"; break; }; [ $((sw%15)) -eq 0 ] && msg_dim "${sw}с..."; done
    [ $sw -lt 120 ] && msg_ok "hassio-supervisor OK"
    touch "$GRACE_MARKER"; save_config; msg_ok "HA Supervised установлен"; mark_done "$sid"; }

step_security() { local sid="sec"; is_done "$sid" && return 0; header "ШАГ 11 — БЕЗОПАСНОСТЬ"; local any=false
    if [ "$OPT_UFW" = true ]; then any=true
        ufw status 2>/dev/null | grep -q "Status: active" || { ufw --force reset >/dev/null 2>&1; ufw default deny incoming >/dev/null 2>&1; ufw default allow outgoing >/dev/null 2>&1; ufw default allow routed >/dev/null 2>&1; }
        for r in "22/tcp SSH" "8123/tcp HA" "4357/tcp ESPHome" "5353/udp mDNS" "5683/udp HomeKit"; do ufw allow ${r%% *} comment "${r#* }" >/dev/null 2>&1; done
        ufw --force enable >/dev/null 2>&1; msg_ok "UFW"
        if ! grep -q "# BEGIN HA-INSTALLER DOCKER-USER" /etc/ufw/after.rules 2>/dev/null; then
            local iok=true; command -v iptables &>/dev/null && iptables --version 2>/dev/null | grep -q legacy && iok=false
            $iok && { cat >> /etc/ufw/after.rules << 'U'

# BEGIN HA-INSTALLER DOCKER-USER RULES
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
-A DOCKER-USER -s 10.0.0.0/8 -j RETURN
-A DOCKER-USER -s 172.16.0.0/12 -j RETURN
-A DOCKER-USER -s 192.168.0.0/16 -j RETURN
-A DOCKER-USER -j DROP
COMMIT
# END HA-INSTALLER DOCKER-USER RULES
U
                ufw reload >/dev/null 2>&1; msg_ok "DOCKER-USER"; } || msg_warn "DOCKER-USER skip (legacy)"; fi
        if is_trixie || [ ! -f /var/log/auth.log ]; then
            printf '[sshd]\nenabled=true\nport=ssh\nfilter=sshd\nbackend=systemd\nmaxretry=5\nbantime=3600\nfindtime=600\n' > /etc/fail2ban/jail.local
        else printf '[sshd]\nenabled=true\nport=ssh\nfilter=sshd\nlogpath=/var/log/auth.log\nbackend=auto\nmaxretry=5\nbantime=3600\nfindtime=600\n' > /etc/fail2ban/jail.local; fi
        systemctl enable fail2ban 2>/dev/null; systemctl restart fail2ban 2>/dev/null; msg_ok "Fail2Ban"; fi
    if [ "$OPT_SSH_HARDENING" = true ]; then any=true; mkdir -p /etc/ssh/sshd_config.d; cp /etc/ssh/sshd_config "${BACKUP_DIR}/sshd_config.bak" 2>/dev/null
        printf 'PermitRootLogin prohibit-password\nMaxAuthTries 3\nClientAliveInterval 300\nClientAliveCountMax 2\nX11Forwarding no\n' > /etc/ssh/sshd_config.d/99-ha-hardening.conf
        systemctl list-unit-files ssh.service &>/dev/null 2>&1 && systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; msg_ok "SSH"; fi
    if [ "$OPT_AUTOUPDATE" = true ]; then any=true
        cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'U'
Unattended-Upgrade::Allowed-Origins { "${distro_id}:${distro_codename}-security"; };
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
U
        printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::AutocleanInterval "7";\n' > /etc/apt/apt.conf.d/20auto-upgrades; msg_ok "Автообн."
        is_trixie && ! grep -rq "trixie-security\|trixie/updates" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null && msg_warn "trixie-security?"; fi
    $any || msg_warn "Пропущено"; mark_done "$sid"; }

step_extras() { local sid="extras"; is_done "$sid" && return 0; header "ШАГ 12 — УТИЛИТЫ"
    [ "$OPT_HOSTNAME" = true ] && { hostnamectl set-hostname homeassistant 2>/dev/null; msg_ok "Hostname"; }
    systemctl enable avahi-daemon >/dev/null 2>&1; systemctl start avahi-daemon >/dev/null 2>&1; msg_ok "mDNS"
    cat > /usr/local/bin/ha-notify << TGEOF
#!/bin/bash
T="${TG_TOKEN}"; C="${TG_CHAT}"; [ -z "\$T" ]||[ -z "\$C" ] && exit 0
curl -s -X POST "https://api.telegram.org/bot\$T/sendMessage" --data-urlencode "chat_id=\$C" --data-urlencode "text=🏠 *HA (\$(hostname)):* \${1:-}" --data-urlencode "parse_mode=Markdown" >/dev/null 2>&1
TGEOF
    chmod +x /usr/local/bin/ha-notify
    if [ "$OPT_WATCHDOG" = true ]; then
        cat > /usr/local/bin/ha-watchdog << 'S'
#!/bin/bash
GF="/tmp/.ha_just_installed"; [ -f "$GF" ] && { [ $(($(date +%s)-$(stat -c %Y "$GF" 2>/dev/null||echo 0))) -lt 1200 ] && exit 0; rm -f "$GF"; }
FF="/tmp/ha_wd_fails"; f=$(cat "$FF" 2>/dev/null||echo 0); c=$(curl -s -o /dev/null -w "%{http_code}" -m 10 http://localhost:8123 2>/dev/null||echo 000)
[ "$c" = "000" ] && { f=$((f+1)); echo "$f">"$FF"; [ "$f" -ge 3 ] && { docker restart homeassistant 2>/dev/null; /usr/local/bin/ha-notify "⚠️ WD ($f)"; echo 0>"$FF"; }; } || echo 0>"$FF"
S
        cat > /usr/local/bin/ha-cleanup << 'S'
#!/bin/bash
fm=$(df -m /|awk 'NR==2{print $4}'); [ "$fm" -lt 1500 ] && { docker system prune -f 2>/dev/null; journalctl --vacuum-size=30M 2>/dev/null; apt-get clean 2>/dev/null; /usr/local/bin/ha-notify "🧹 ${fm}→$(df -m /|awk 'NR==2{print $4}')MB"; }
S
        cat > /usr/local/bin/ha-net-recovery << 'S'
#!/bin/bash
GW=$(ip route 2>/dev/null|awk '/default/{print $3}'|head -1); [ -z "$GW" ] && GW=8.8.8.8
ping -c2 -W3 "$GW" >/dev/null 2>&1 && exit 0; ping -c2 -W3 8.8.8.8 >/dev/null 2>&1 && exit 0
nmcli networking off 2>/dev/null; sleep 3; nmcli networking on 2>/dev/null; sleep 5
ping -c2 -W3 8.8.8.8 >/dev/null 2>&1 && /usr/local/bin/ha-notify "🌐 OK" || /usr/local/bin/ha-notify "🔴 Нет сети"
S
        chmod +x /usr/local/bin/ha-{watchdog,cleanup,net-recovery}; msg_ok "Watchdog"; fi
    [ "$OPT_THERMAL" = true ] && { cat > /usr/local/bin/ha-thermal << 'S'
#!/bin/bash
[ ! -f /sys/class/thermal/thermal_zone0/temp ] && exit 0; t=$(($(cat /sys/class/thermal/thermal_zone0/temp)/1000))
[ "$t" -ge 80 ] && /usr/local/bin/ha-notify "🔥 ${t}°C!" || { [ "$t" -ge 70 ] && /usr/local/bin/ha-notify "🌡️ ${t}°C"; }
S
    chmod +x /usr/local/bin/ha-thermal; msg_ok "Терм."; }
    cat > /usr/local/bin/ha-health << 'S'
#!/bin/bash
echo "===== HA Health ($(date)) ====="
printf "  %-12s %s\n" Host: "$(hostname)" IP: "$(hostname -I|awk '{print $1}')" Up: "$(uptime -p 2>/dev/null)" Kernel: "$(uname -r)" OS: "$(. /etc/os-release 2>/dev/null&&echo "$PRETTY_NAME")"
[ -f /sys/class/thermal/thermal_zone0/temp ] && printf "  %-12s %d°C\n" CPU: "$(($(cat /sys/class/thermal/thermal_zone0/temp)/1000))"
free -h|awk '/Mem:/{printf "  %-12s %s/%s\n","RAM:",$3,$2}/Swap:/{printf "  %-12s %s/%s\n","Swap:",$3,$2}'
df -h /|awk 'NR==2{printf "  %-12s %s/%s (%s)\n","Disk:",$3,$2,$5}'
echo "── Containers ──"; docker ps --format "  {{.Names}}: {{.Status}}" 2>/dev/null||echo "  n/a"
printf "  %-12s %s\n" "HA:" "$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://localhost:8123 2>/dev/null||echo 000)"
echo "========================="
S
    chmod +x /usr/local/bin/ha-health; msg_ok "ha-health"
    if [ "$OPT_BACKUP" = true ]; then mkdir -p "$HA_BACKUP_DIR"
        cat > /usr/local/bin/ha-backup << BEOF
#!/bin/bash
BD="${HA_BACKUP_DIR}"; HD="${HASSIO_DIR}"; KD=30; TS=\$(date +%Y%m%d_%H%M%S); mkdir -p "\$BD"
[ ! -d "\${HD}/homeassistant" ] && exit 1
EX="--exclude=*.db --exclude=*.db-shm --exclude=*.db-wal --exclude=home-assistant_v2.db* --exclude=tts --exclude=deps --exclude=__pycache__"
command -v pigz &>/dev/null && tar -I pigz -cf "\${BD}/ha_config_\${TS}.tar.gz" \$EX -C "\$HD" homeassistant 2>/dev/null \
    || tar czf "\${BD}/ha_config_\${TS}.tar.gz" \$EX -C "\$HD" homeassistant 2>/dev/null
find "\$BD" -name "ha_config_*.tar.gz" -mtime +\$KD -delete 2>/dev/null
/usr/local/bin/ha-notify "💾 \$(du -sh "\${BD}/ha_config_\${TS}.tar.gz" 2>/dev/null|awk '{print \$1}')"
BEOF
        cat > /usr/local/bin/ha-restore << REOF
#!/bin/bash
[ -z "\$BASH_VERSION" ] && { echo "bash!"; exit 1; }
BD="${HA_BACKUP_DIR}"; HD="${HASSIO_DIR}"
mapfile -t F < <(ls -1t "\$BD"/ha_config_*.tar.gz 2>/dev/null); [ \${#F[@]} -eq 0 ] && { echo "Нет бэкапов"; exit 1; }
for i in "\${!F[@]}"; do printf "  %d) %s (%s)\n" "\$((i+1))" "\$(basename "\${F[\$i]}")" "\$(du -sh "\${F[\$i]}"|awk '{print \$1}')"; done
read -p "# " n; [[ ! "\$n" =~ ^[0-9]+\$ ]]||[ "\$n" -lt 1 ]||[ "\$n" -gt \${#F[@]} ] && exit 1
read -p "OK? (yes/no) " c; [ "\$c" != yes ] && exit 0
docker stop homeassistant 2>/dev/null; tar xzf "\${F[\$((n-1))]}" -C "\$HD"; docker start homeassistant 2>/dev/null; echo "Done!"
REOF
        chmod +x /usr/local/bin/ha-{backup,restore}; msg_ok "Бэкап"; fi
    { echo "# HA v${SCRIPT_VERSION}"
      [ "$OPT_WATCHDOG" = true ] && printf '*/5 * * * * root /usr/local/bin/ha-watchdog >/dev/null 2>&1\n*/10 * * * * root /usr/local/bin/ha-net-recovery >/dev/null 2>&1\n30 3 * * * root /usr/local/bin/ha-cleanup >/dev/null 2>&1\n'
      [ "$OPT_THERMAL" = true ] && echo '*/5 * * * * root /usr/local/bin/ha-thermal >/dev/null 2>&1'
      [ "$OPT_BACKUP" = true ] && echo '0 4 * * 0 root /usr/local/bin/ha-backup >/dev/null 2>&1'
    } > /etc/cron.d/ha-tools; chmod 644 /etc/cron.d/ha-tools; msg_ok "Cron"; mark_done "$sid"; }

step_hacs() { local sid="hacs"; is_done "$sid" && return 0; header "ШАГ 13 — HACS"
    [ "$OPT_HACS" != true ] && { msg_warn "Пропущен"; mark_done "$sid"; return 0; }
    wait_ha_ready 300 || { msg_warn "Таймаут"; mark_done "$sid"; return 0; }
    local cw=0; while ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$'; do sleep 5; cw=$((cw+5)); [ $cw -gt 60 ] && { mark_done "$sid"; return 0; }; done
    docker exec homeassistant bash -c "wget -q -O- https://get.hacs.xyz|bash -" &>/dev/null & local hp=$! hw=0
    while kill -0 "$hp" 2>/dev/null; do sleep 5; hw=$((hw+5)); [ $hw -ge 120 ] && { kill "$hp" 2>/dev/null; mark_done "$sid"; return 0; }; done
    wait "$hp" 2>/dev/null && { docker restart homeassistant >/dev/null 2>&1; msg_ok "HACS!"; } || msg_warn "HACS: ошибка"
    mark_done "$sid"; }

show_final() {
    local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"
    local el=$(( $(date +%s) - INSTALL_START )) em=$((el/60)) es=$((el%60))
    header "УСТАНОВКА ЗАВЕРШЕНА! (${em}м ${es}с)"
    echo -e "  ${GREEN}➜  http://${ip}:8123${NC}"
    [ "$OPT_HOSTNAME" = true ] && echo -e "  ${GREEN}➜  http://homeassistant.local:8123${NC}"; echo ""
    command -v qrencode &>/dev/null && [ "$SILENT" != true ] && { qrencode -m 2 -t ANSIUTF8 "http://${ip}:8123"; echo ""; }
    separator; echo -e "  ${BOLD}Компоненты:${NC}"
    echo -e "  ${CHECK}  HA Supervised (${HA_MACHINE}) + Docker + OS-Agent"
    [ "$OPT_ZRAM" = true ] && echo -e "  ${CHECK}  ZRAM"; [ "$OPT_EMMC_TUNING" = true ] && echo -e "  ${CHECK}  eMMC/SD"
    [ "$OPT_UFW" = true ] && echo -e "  ${CHECK}  UFW+F2B"; [ "$OPT_SSH_HARDENING" = true ] && echo -e "  ${CHECK}  SSH"
    [ "$OPT_WATCHDOG" = true ] && echo -e "  ${CHECK}  Watchdog"; [ "$OPT_BACKUP" = true ] && echo -e "  ${CHECK}  Бэкап"
    [ "$OPT_HACS" = true ] && echo -e "  ${CHECK}  HACS"
    detect_system_info; echo -e "  ${CHECK}  ${CACHED_PRETTY_NAME}"
    is_armbian && echo -e "  ${CHECK}  Armbian"
    [ "$OS_RELEASE_FAKED" = true ] && echo -e "  ${WARN}  os-release: фейк при старте supervisor"
    separator; msg_dim "Конфиг: ${HA_INSTALLER_DIR}"; msg_dim "Бэкапы: ${HA_BACKUP_DIR}"; msg_dim "Лог:    ${LOG_FILE}"
    echo -e "\n  ${BOLD}Команды:${NC}  ha-health  ha-backup  ha-restore"
    [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" != "Y" ] && msg_warn "AppArmor → sudo reboot"
    echo -e "\n  ${YELLOW}Инициализация HA: 10-15 мин.${NC}\n"
    [ "$OPT_TELEGRAM" = true ] && /usr/local/bin/ha-notify "✅ HA: http://${ip}:8123" 2>/dev/null || true
}

main() {
    for a in "$@"; do [ "$a" = "-h" ] || [ "$a" = "--help" ] && { show_help; exit 0; }; done
    [ "$EUID" -ne 0 ] && { echo -e "${RED}sudo!${NC}"; exit 1; }
    parse_args "$@"; setup_dirs; migrate_legacy_paths
    [ "$CHECK_ONLY" = true ] && { show_banner; do_check; exit 0; }
    [ "$SHOW_STATUS" = true ] && { do_status; exit 0; }
    [ "$UNINSTALL" = true ] && { show_banner; acquire_lock; do_uninstall; exit 0; }
    [ "$DO_UPDATE" = true ] && { show_banner; acquire_lock; do_update; exit 0; }
    [ "$RUN_WIZARD" = true ] && [ "$DRY_RUN" = false ] && run_wizard
    show_banner; setup_logging; setup_tmpdir; INSTALL_START=$(date +%s)
    detect_system_info; is_trixie && msg_info "Debian 13 Trixie"; is_armbian && msg_info "Armbian"
    [ "$MACHINE_EXPLICIT" = false ] && HA_MACHINE=$(detect_machine_type)
    msg_info "Платформа: ${HA_MACHINE} (${CACHED_MACHINE_ARCH})"
    msg_info "os-release: ${CACHED_PRETTY_NAME} [ID=${CACHED_OS_ID}]"
    acquire_lock
    run_step step_preflight || { msg_error "Проверки!"; exit 1; }
    run_step step_update_system;     run_step step_install_deps
    run_step step_configure_network || { msg_error "Сеть!"; exit 1; }
    run_step step_configure_apparmor; run_step step_performance
    run_step step_install_docker;     run_step step_resolve_versions
    run_step step_download_packages;  run_step step_install_os_agent
    run_step step_install_ha;         run_step step_security
    run_step step_extras;             run_step step_hacs
    show_final
}
main "$@"
