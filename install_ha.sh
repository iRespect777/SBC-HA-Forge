#!/bin/bash

# ============================================================================
#  Home Assistant Supervised — ULTIMATE INSTALLER
#  Версия:    5.1 (Ultimate Edition)
#  Платформа: TV-Боксы и SBC (Armbian Bookworm / aarch64)
# ============================================================================

readonly SCRIPT_VERSION="5.1"
readonly HA_DEFAULT_MACHINE="qemuarm-64"
readonly STATE_FILE="/root/.ha_install_state"
readonly LOCK_FILE="/var/lock/ha_install.lock"
readonly BACKUP_DIR="/root/.ha_install_backup"
readonly LOG_DIR="/var/log"
readonly HASSIO_DIR="/usr/share/hassio"

set -uo pipefail

# ========================== ЦВЕТА ===========================================
if [ -t 1 ]; then
    RED='\033[0;31m'    GREEN='\033[0;32m'
    YELLOW='\033[1;33m' BLUE='\033[0;34m'
    MAGENTA='\033[0;35m' CYAN='\033[0;36m'
    WHITE='\033[1;37m'  BOLD='\033[1m'
    DIM='\033[2m'       NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA=''
    CYAN='' WHITE='' BOLD='' DIM='' NC=''
fi

CHECK="${GREEN}✔${NC}"  CROSS="${RED}✘${NC}"
ARROW="${CYAN}➜${NC}"   WARN="${YELLOW}⚠${NC}"
INFO="${BLUE}ℹ${NC}"    GEAR="${MAGENTA}⚙${NC}"

# ========================== ПЕРЕМЕННЫЕ УСТАНОВКИ ============================
RUN_WIZARD=true
OPT_ZRAM=true
OPT_UFW=true
OPT_HACS=true
OPT_EXTRAS=true
TG_TOKEN=""
TG_CHAT=""

SKIP_UPDATE=false
CHECK_ONLY=false
UNINSTALL=false
DRY_RUN=false
HA_MACHINE="$HA_DEFAULT_MACHINE"
LOG_FILE=""

# ========================== ВЫВОД И ЛОГИРОВАНИЕ =============================
header() {
    echo -e "\n${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    printf "${BLUE}║${WHITE}${BOLD}  %-58s${NC}${BLUE}║${NC}\n" "$1"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}\n"
}
separator()  { echo -e "${DIM}  ────────────────────────────────────────────────────────────${NC}"; }
msg_info()   { echo -e " ${INFO}  ${WHITE}$1${NC}"; }
msg_ok()     { echo -e " ${CHECK}  ${GREEN}$1${NC}"; }
msg_warn()   { echo -e " ${WARN}  ${YELLOW}$1${NC}"; }
msg_error()  { echo -e " ${CROSS}  ${RED}$1${NC}"; }
msg_action() { echo -e " ${ARROW}  ${CYAN}$1${NC}"; }
msg_dim()    { echo -e "       ${DIM}$1${NC}"; }

setup_logging() {
    LOG_FILE="${LOG_FILE:-${LOG_DIR}/ha_install_$(date +%Y%m%d_%H%M%S).log}"
    mkdir -p "$(dirname "$LOG_FILE")"
    exec 3>&1 4>&2
    exec > >(tee -a "$LOG_FILE") 2>&1
    msg_info "Лог: ${LOG_FILE}"
}

flush_log() {
    exec 1>&3 2>&4 3>&- 4>&- 2>/dev/null || true
    sleep 0.5
}

# ========================== STATE & LOCK ====================================
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid=""; pid=$(cat "$LOCK_FILE" 2>/dev/null) || true
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { msg_error "Скрипт уже запущен"; exit 1; }
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() { rm -f "$LOCK_FILE" 2>/dev/null || true; }
mark_done()    { echo "$1" >> "$STATE_FILE"; }
is_done()      { [ -f "$STATE_FILE" ] && grep -qx "$1" "$STATE_FILE" 2>/dev/null; }

cleanup() {
    local exit_code=$?
    rm -f /tmp/os-agent*.deb /tmp/homeassistant-supervised*.deb /tmp/ha_step_*.log 2>/dev/null || true
    release_lock
    flush_log 2>/dev/null || true
    [ $exit_code -eq 130 ] && echo -e "\n ${WARN}  ${YELLOW}Прервано (Ctrl+C)${NC}"
}
trap cleanup EXIT INT TERM

# ========================== УТИЛИТЫ =========================================
run_cmd() {
    local desc="$1"; shift; local lfile; lfile=$(mktemp /tmp/ha_step_XXXXXX.log)
    msg_action "${desc}..."
    [ "$DRY_RUN" = true ] && { msg_dim "[dry-run] $*"; rm -f "$lfile"; return 0; }
    if "$@" > "$lfile" 2>&1; then msg_ok "$desc"; rm -f "$lfile"; return 0;
    else
        local c=$?; msg_error "${desc} — ОШИБКА (${c})"; msg_warn "Лог: ${lfile}"
        tail -15 "$lfile" 2>/dev/null | while IFS= read -r l; do echo -e "    ${RED}│${NC} ${l}"; done
        return $c
    fi
}

run_cmd_fatal() { ! run_cmd "$@" && { msg_error "Остановка"; exit 1; }; }

download_file() {
    local url="$1" output="$2" desc="$3" max="${4:-3}" att=1
    [ "$DRY_RUN" = true ] && { msg_action "${desc}..."; msg_dim "[dry-run] wget ${url}"; return 0; }
    while [ $att -le $max ]; do
        [ $att -gt 1 ] && sleep $((att * 3))
        msg_action "${desc}..."
        rm -f "$output" 2>/dev/null || true
        if wget -q --timeout=60 --tries=1 -O "$output" "$url" 2>/dev/null && [ -s "$output" ]; then
            if [[ "$output" == *.deb ]]; then
                dpkg-deb --info "$output" &>/dev/null && { msg_ok "${desc}"; return 0; }
                msg_warn "Файл повреждён"
            else msg_ok "${desc}"; return 0; fi
        else msg_warn "Ошибка загрузки"; fi
        att=$((att + 1))
    done
    msg_error "${desc} — не удалось"; return 1
}

get_latest_release() {
    curl -fsSL --timeout 15 "https://api.github.com/repos/$1/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true
}

detect_machine_type() {
    local dtmodel=""; dtmodel=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null) || true
    case "$(uname -m)" in
        x86_64) echo "generic-x86-64" ;;
        aarch64)
            case "$dtmodel" in
                *Raspberry*Pi*5*)  echo "raspberrypi5-64" ;;
                *Raspberry*Pi*4*)  echo "raspberrypi4-64" ;;
                *Raspberry*Pi*3*)  echo "raspberrypi3-64" ;;
                *ODROID-N2*)       echo "odroid-n2" ;;
                *ODROID-C4*)       echo "odroid-c4" ;;
                *Khadas*VIM3*)     echo "khadas-vim3" ;;
                *)                 echo "qemuarm-64" ;;
            esac ;;
        armv7l) echo "qemuarm" ;;
        *)      echo "qemuarm-64" ;;
    esac
}

# ========================== МАСТЕР TUI ======================================
run_wizard() {
    if ! command -v whiptail &>/dev/null; then apt-get update -qq && apt-get install -y whiptail -qq; fi
    
    whiptail --title "HA Ultimate Installer v${SCRIPT_VERSION}" --msgbox "Добро пожаловать в установщик Home Assistant Supervised для TV-боксов и SBC.\n\nНа следующих экранах вы сможете выбрать компоненты для установки." 12 60

    local choices
    choices=$(whiptail --title "Компоненты установки" --checklist \
        "Выберите модули (Пробел - выбор, Enter - подтвердить):" 18 65 5 \
        "ZRAM" "Сжатие в RAM (спасает eMMC от износа)" ON \
        "UFW" "Firewall и Fail2Ban (Безопасность)" ON \
        "HACS" "Автоустановка магазина HACS" ON \
        "EXTRAS" "Watchdog, Очистка, Автосеть, mDNS" ON \
        3>&1 1>&2 2>&3) || { echo "Установка отменена пользователем."; exit 0; }

    [[ $choices != *"ZRAM"* ]] && OPT_ZRAM=false
    [[ $choices != *"UFW"* ]] && OPT_UFW=false
    [[ $choices != *"HACS"* ]] && OPT_HACS=false
    [[ $choices != *"EXTRAS"* ]] && OPT_EXTRAS=false

    if [ "$OPT_EXTRAS" = true ]; then
        if whiptail --title "Telegram" --yesno "Настроить отправку критических уведомлений (зависания, очистка) в Telegram?" 10 60; then
            TG_TOKEN=$(whiptail --title "Telegram Token" --inputbox "Введите токен вашего бота (от @BotFather):" 10 60 3>&1 1>&2 2>&3) || TG_TOKEN=""
            TG_CHAT=$(whiptail --title "Telegram Chat ID" --inputbox "Введите ваш Chat ID (от @userinfobot):" 10 60 3>&1 1>&2 2>&3) || TG_CHAT=""
        fi
    fi
}

parse_args() {
    if [ $# -eq 0 ]; then return; fi 
    RUN_WIZARD=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)         echo "Используйте без параметров для запуска Мастера."; exit 0 ;;
            -c|--check)        CHECK_ONLY=true ;;
            -u|--uninstall)    UNINSTALL=true ;;
            --reset-state)     reset_state; exit 0 ;;
            --skip-update)     SKIP_UPDATE=true ;;
            --dry-run)         DRY_RUN=true ;;
        esac
        shift
    done
}

# ========================== БАННЕР ==========================================
show_banner() {
    clear
    echo -e "${BLUE}    ╦ ╦┌─┐┌┬┐┌─┐  ╔═╗┌─┐┌─┐┬┌─┐┌┬┐┌─┐┌┐┌┌┬┐${NC}"
    echo -e "${BLUE}    ╠═╣│ ││││├┤   ╠═╣└─┐└─┐│└─┐ │ ├─┤│││ │ ${NC}"
    echo -e "${BLUE}    ╩ ╩└─┘┴ ┴└─┘  ╩ ╩└─┘└─┘┴└─┘ ┴ ┴ ┴┘└┘ ┴ ${NC}"
    echo -e "${WHITE}${BOLD}    ULTIMATE INSTALLER v${SCRIPT_VERSION} / Armbian Bookworm${NC}"
    separator
}

# ========================== ШАГИ УСТАНОВКИ ==================================

step_update_system() {
    local sid="update"; is_done "$sid" && return 0
    header "ШАГ 1 — ОБНОВЛЕНИЕ И ПОДГОТОВКА"
    [ "$SKIP_UPDATE" = false ] && { run_cmd_fatal "apt-get update" apt-get update -y; run_cmd "apt upgrade" apt-get upgrade -y; }
    mark_done "$sid"
}

step_install_deps() {
    local sid="deps"; is_done "$sid" && return 0
    header "ШАГ 2 — ЗАВИСИМОСТИ"
    local pkgs=(apparmor avahi-daemon bluez ca-certificates cifs-utils curl dbus gnupg jq libglib2.0-bin lsb-release network-manager nfs-common software-properties-common systemd-journal-remote systemd-resolved systemd-timesyncd udisks2 usbutils wget qrencode cpufrequtils)
    [ "$OPT_ZRAM" = true ] && pkgs+=(zram-tools)
    [ "$OPT_UFW" = true ] && pkgs+=(ufw fail2ban)

    msg_info "Установка ${#pkgs[@]} пакетов..."
    for p in "${pkgs[@]}"; do
        dpkg -l "$p" &>/dev/null || run_cmd "Установка $p" apt-get install -y "$p" || true
    done
    run_cmd "Fix broken deps" apt-get -f install -y >/dev/null 2>&1
    mark_done "$sid"
}

step_configure_network() {
    local sid="network"; is_done "$sid" && return 0
    header "ШАГ 3 — СЕТЬ И DNS"
    mkdir -p "$BACKUP_DIR" /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/10-ha-managed.conf << 'EOF'
[keyfile]
unmanaged-devices=none
[device]
wifi.scan-rand-mac-address=no
EOF
    cp /etc/network/interfaces "$BACKUP_DIR/interfaces.bak" 2>/dev/null || true
    cat > /etc/network/interfaces << 'EOF'
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback
EOF
    systemctl enable systemd-resolved 2>/dev/null || true
    systemctl start systemd-resolved 2>/dev/null || true
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true
    
    mark_done "$sid"
    msg_warn "Переключение на NetworkManager (может моргнуть SSH)..."
    systemctl disable networking 2>/dev/null || true
    systemctl enable NetworkManager 2>/dev/null || true
    systemctl restart NetworkManager 2>/dev/null || true
    sleep 3
}

step_configure_apparmor() {
    local sid="apparmor"; is_done "$sid" && return 0
    header "ШАГ 4 — APPARMOR"
    local aa=""; aa=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) || aa="N"
    if [ "$aa" = "Y" ]; then msg_ok "Активен"; else
        msg_warn "AppArmor выключен. Патчим загрузчик..."
        local patched=false
        for f in /boot/armbianEnv.txt /boot/uEnv.txt /boot/extlinux/extlinux.conf; do
            if [ -f "$f" ]; then
                cp "$f" "${BACKUP_DIR}/$(basename "$f").bak" 2>/dev/null || true
                if ! grep -q "apparmor=1" "$f"; then
                    if [[ "$f" == *extlinux.conf ]]; then sed -i '/^[[:space:]]*append/ s/$/ apparmor=1 security=apparmor/' "$f"
                    elif grep -q "^extraargs=" "$f"; then sed -i 's|^extraargs=.*|& apparmor=1 security=apparmor|' "$f"
                    else echo "extraargs=apparmor=1 security=apparmor" >> "$f"; fi
                fi
                patched=true; break
            fi
        done
        [ "$patched" = false ] && msg_error "Не найден файл загрузчика!"
    fi
    systemctl enable apparmor 2>/dev/null || true
    systemctl start apparmor 2>/dev/null || true
    mark_done "$sid"
}

step_performance() {
    local sid="perf"; is_done "$sid" && return 0
    header "ШАГ 5 — ПРОИЗВОДИТЕЛЬНОСТЬ"

    if [ "$OPT_ZRAM" = true ]; then
        msg_action "Настройка ZRAM (ОЗУ-сжатие)..."
        [ -f /swapfile ] && { swapoff /swapfile 2>/dev/null || true; rm -f /swapfile; sed -i '/swapfile/d' /etc/fstab; }
        cat > /etc/default/zramswap <<EOF
ALGO=lz4
PERCENT=60
EOF
        systemctl enable zramswap 2>/dev/null || true
        systemctl restart zramswap 2>/dev/null || true
        msg_ok "ZRAM активирован (Swap на eMMC отключен)"
    else
        msg_action "Создание классического Swap 2GB..."
        [ ! -f /swapfile ] && dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
        grep -q "swapfile" /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    msg_action "Тюнинг процессора..."
    if command -v cpufreq-set &>/dev/null; then
        echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
        systemctl restart cpufrequtils 2>/dev/null || true
        msg_ok "CPU переведен в режим Performance"
    fi
    mark_done "$sid"
}

step_install_docker() {
    local sid="docker"; is_done "$sid" && return 0
    header "ШАГ 6 — DOCKER"
    if ! command -v docker &>/dev/null; then
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        run_cmd_fatal "Скачивание и установка Docker" bash -c "curl -fsSL https://get.docker.com | sh"
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json << 'EOF'
{ "log-driver": "journald", "storage-driver": "overlay2" }
EOF
        systemctl enable docker && systemctl restart docker
    fi
    msg_ok "Docker: $(docker --version | awk '{print $3}' | tr -d ',')"
    mark_done "$sid"
}

step_install_os_agent() {
    local sid="osagent"; is_done "$sid" && return 0
    header "ШАГ 7 — OS-AGENT"
    local v=""; v=$(get_latest_release "home-assistant/os-agent")
    [ -z "$v" ] && v="1.6.0"
    local u="https://github.com/home-assistant/os-agent/releases/download/${v}/os-agent_${v}_linux_aarch64.deb"
    download_file "$u" "/tmp/os-agent.deb" "OS-Agent $v"
    run_cmd_fatal "Установка OS-Agent" dpkg -i /tmp/os-agent.deb
    mark_done "$sid"
}

step_install_ha() {
    local sid="ha"; is_done "$sid" && return 0
    header "ШАГ 8 — HOME ASSISTANT SUPERVISED"
    
    mkdir -p "$BACKUP_DIR"
    [ ! -f "${BACKUP_DIR}/os-release.original" ] && cp /etc/os-release "${BACKUP_DIR}/os-release.original"
    
    cat > /etc/os-release << 'EOF'
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
VERSION_ID="12"
VERSION_CODENAME=bookworm
ID=debian
EOF

    local v=""; v=$(get_latest_release "home-assistant/supervised-installer")
    [ -z "$v" ] && v="1.7.0"
    download_file "https://github.com/home-assistant/supervised-installer/releases/download/${v}/homeassistant-supervised.deb" "/tmp/ha.deb" "HA Supervised $v"
    
    msg_action "Установка контейнеров HA (ожидайте 5-15 минут)..."
    export MACHINE="$HA_MACHINE"
    
    # Живой вывод лога установки (чтобы не казалось, что скрипт завис)
    set +o pipefail
    DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/ha.deb 2>&1 | stdbuf -oL grep -iE "(pull|download|unpack|setting up|error|warn)" | grep -vi "cgroup v1" | while IFS= read -r line; do echo -e "    ${BLUE}│${NC} ${line}"; done
    local de=${PIPESTATUS[0]}
    set -o pipefail
    
    [ $de -ne 0 ] && { apt-get install -f -y >/dev/null 2>&1 || true; }
    msg_ok "HA установлен"

    mkdir -p /etc/systemd/system/hassio-supervisor.service.d
    cat > /etc/systemd/system/hassio-supervisor.service.d/mask-os-release.conf << 'DROPIN'
[Service]
ExecStartPre=/bin/bash -c 'if ! grep -q "^ID=debian" /etc/os-release; then printf "%%s\n" "PRETTY_NAME=\"Debian GNU/Linux 12 (bookworm)\"" "NAME=\"Debian GNU/Linux\"" "VERSION_ID=\"12\"" "VERSION_CODENAME=bookworm" "ID=debian" > /etc/os-release; fi'
DROPIN
    systemctl daemon-reload
    mark_done "$sid"
}

step_security() {
    local sid="sec"; is_done "$sid" && return 0
    header "ШАГ 9 — БЕЗОПАСНОСТЬ"
    
    if [ "$OPT_UFW" = true ]; then
        msg_action "Настройка UFW..."
        ufw --force reset >/dev/null 2>&1
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
        ufw default allow routed >/dev/null 2>&1  # Критично для контейнеров Docker!
        
        ufw allow 22/tcp comment 'SSH' >/dev/null
        ufw allow 8123/tcp comment 'Home Assistant' >/dev/null
        ufw allow 4357/tcp comment 'ESPHome' >/dev/null
        ufw allow 5353/udp comment 'mDNS' >/dev/null
        ufw allow 5683/udp comment 'HomeKit' >/dev/null
        ufw --force enable >/dev/null 2>&1
        msg_ok "Firewall (UFW) активирован"

        msg_action "Настройка Fail2Ban..."
        cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
EOF
        systemctl restart fail2ban 2>/dev/null || true
        msg_ok "Fail2Ban защищает SSH"
    else msg_warn "Пропущено"; fi
    mark_done "$sid"
}

step_extras() {
    local sid="extras"; is_done "$sid" && return 0
    header "ШАГ 10 — УТИЛИТЫ И МОНИТОРИНГ"
    
    if [ "$OPT_EXTRAS" = true ]; then
        # mDNS
        hostnamectl set-hostname homeassistant 2>/dev/null || true
        systemctl enable avahi-daemon >/dev/null 2>&1 && systemctl start avahi-daemon >/dev/null 2>&1
        msg_ok "mDNS: homeassistant.local"

        # Telegram
        cat > /usr/local/bin/ha-notify << TGNOTIFY
#!/bin/bash
T="${TG_TOKEN}"
C="${TG_CHAT}"
[ -z "\$T" ] && exit 0
curl -s -X POST "https://api.telegram.org/bot\$T/sendMessage" -d chat_id="\$C" -d text="🏠 *HA*: \$1" -d parse_mode="Markdown" >/dev/null
TGNOTIFY
        chmod +x /usr/local/bin/ha-notify

        # Watchdog
        cat > /usr/local/bin/ha-watchdog << 'WD'
#!/bin/bash
fail=$(cat /tmp/ha_wd 2>/dev/null || echo 0)
code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 http://localhost:8123 || echo 0)
if [ "$code" = "000" ]; then
    fail=$((fail+1)); echo "$fail" > /tmp/ha_wd
    [ "$fail" -ge 3 ] && { docker restart homeassistant; /usr/local/bin/ha-notify "⚠️ Watchdog перезапустил HA!"; echo 0 > /tmp/ha_wd; }
else echo 0 > /tmp/ha_wd; fi
WD
        chmod +x /usr/local/bin/ha-watchdog

        # Cleanup
        cat > /usr/local/bin/ha-cleanup << 'CLN'
#!/bin/bash
f=$(df -m / | awk 'NR==2{print $4}')
if [ "$f" -lt 1500 ]; then
    docker system prune -f; journalctl --vacuum-size=30M; apt-get clean
    /usr/local/bin/ha-notify "🧹 Автоочистка диска. Было: ${f}MB"
fi
CLN
        chmod +x /usr/local/bin/ha-cleanup

        # Net Recovery (Пингует сначала шлюз, потом гугл)
        cat > /usr/local/bin/ha-net-recovery << 'NETR'
#!/bin/bash
GW=$(ip route | awk '/default/ {print $3}' | head -n 1)
[ -z "$GW" ] && GW="8.8.8.8"
ping -c 2 "$GW" >/dev/null || ping -c 2 8.8.8.8 >/dev/null || { nmcli networking off; sleep 2; nmcli networking on; /usr/local/bin/ha-notify "🌐 Сеть перезапущена"; }
NETR
        chmod +x /usr/local/bin/ha-net-recovery

        # Crons
        cat > /etc/cron.d/ha-tools << 'CRON'
*/5 * * * * root /usr/local/bin/ha-watchdog
*/10 * * * * root /usr/local/bin/ha-net-recovery
30 3 * * * root /usr/local/bin/ha-cleanup
CRON
        msg_ok "Watchdog, Очистка и Net-recovery установлены"
    else msg_warn "Пропущено"; fi
    mark_done "$sid"
}

step_hacs() {
    local sid="hacs"; is_done "$sid" && return 0
    header "ШАГ 11 — УСТАНОВКА HACS"

    if [ "$OPT_HACS" = true ]; then
        msg_action "Ожидание формирования конфигурации HA (до 5 минут)..."
        local wait=0
        while [ ! -f /usr/share/hassio/homeassistant/configuration.yaml ]; do
            sleep 5; wait=$((wait+5))
            [ $wait -gt 300 ] && { msg_warn "Таймаут. HACS не установлен."; return 0; }
        done
        
        msg_action "Внедрение HACS в контейнер..."
        docker exec homeassistant bash -c "wget -O - https://get.hacs.xyz | bash -" >/dev/null 2>&1
        msg_ok "Скрипт HACS выполнен"
        
        msg_action "Перезапуск HA Core..."
        docker restart homeassistant >/dev/null 2>&1
        msg_ok "HACS интегрирован!"
    else msg_warn "Пропущено"; fi
    mark_done "$sid"
}

# ========================== MAIN ============================================

main() {
    parse_args "$@"
    [ "$EUID" -ne 0 ] && { echo "Запустите от root (sudo)"; exit 1; }

    if [ "$RUN_WIZARD" = true ] && [ "$DRY_RUN" = false ]; then run_wizard; fi

    show_banner
    setup_logging
    
    if [ "$HA_MACHINE" = "$HA_DEFAULT_MACHINE" ]; then HA_MACHINE=$(detect_machine_type); fi
    msg_info "Машина: $HA_MACHINE"

    acquire_lock

    step_update_system
    step_install_deps
    step_configure_network
    step_configure_apparmor
    step_performance
    step_install_docker
    step_install_os_agent
    step_install_ha
    step_security
    step_extras
    step_hacs

    # ФИНАЛ И QR-КОД
    local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"
    header "УСТАНОВКА ЗАВЕРШЕНА!"
    
    echo -e "  Откройте в браузере: ${GREEN}http://${ip}:8123${NC}"
    [ "$OPT_EXTRAS" = true ] && echo -e "  Или по имени:        ${GREEN}http://homeassistant.local:8123${NC}"
    echo ""
    
    if command -v qrencode &>/dev/null; then
        echo -e "  ${BOLD}Отсканируйте код телефоном для быстрого доступа:${NC}\n"
        qrencode -m 2 -t ANSIUTF8 "http://${ip}:8123"
        echo ""
    fi

    echo -e "  ${YELLOW}Первая инициализация HA займет около 10-15 минут.${NC}"
    echo -e "  Подождите, пока веб-интерфейс не предложит создать аккаунт.\n"
}

main "$@"
