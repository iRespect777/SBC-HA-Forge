#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2086
# ============================================================================
# Home Assistant Supervised — ULTIMATE INSTALLER
# Version: 9.1.1 (GitHub release)
# Platform: TV-Boxes & SBC (Armbian Bookworm/Trixie / aarch64 / x86_64)
# License: MIT
# Repository: https://github.com/mediahome/ha-installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mediahome/ha-installer/main/install.sh -o /tmp/install.sh
#   sudo bash /tmp/install.sh
#
# ============================================================================
if [ -z "$BASH_VERSION" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "Requires bash >= 4.0"; exit 1
fi

readonly SCRIPT_VERSION="9.1.1"
readonly HA_DEFAULT_MACHINE="qemuarm-64"
readonly INSTALLER_REPO="mediahome/ha-installer"
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
readonly METRICS_DIR="/var/lib/prometheus/node-exporter"
readonly HA_SUPPORTED_CODENAMES="bookworm bullseye trixie"
readonly HISTORY_FILE="${HA_INSTALLER_DIR}/history"
readonly REBOOT_CONTINUE_SVC="ha-install-continue"
readonly REBOOT_ATTEMPT_FILE="${HA_INSTALLER_DIR}/reboot_attempts"
readonly HA_INFO_FILE="${HA_INSTALLER_DIR}/ha-info.txt"
readonly SAFE_SCRIPT_PATH="/usr/local/bin/ha-install"

set -uo pipefail

# --- Colors (safe for all terminals) ---
if [ -t 1 ]; then
  RED='\033[0;31m'    GREEN='\033[0;32m'
  YELLOW='\033[1;33m' BLUE='\033[0;34m'
  CYAN='\033[0;36m'   WHITE='\033[1;37m'
  BOLD='\033[1m'      DIM='\033[2m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN=''
  WHITE='' BOLD='' DIM='' NC=''
fi

CHECK="${GREEN}+${NC}"  CROSS="${RED}x${NC}"
ARROW="${CYAN}>${NC}"   WARN="${YELLOW}!${NC}"
INFO="${BLUE}i${NC}"

# --- Global state ---
RUN_WIZARD=true
OPT_ZRAM=true;         OPT_EMMC_TUNING=true;   OPT_USB_POWER=true
OPT_UFW=true;          OPT_SSH_HARDENING=true;  OPT_AUTOUPDATE=true
OPT_WATCHDOG=true;     OPT_THERMAL=true;        OPT_BACKUP=true
OPT_HACS=true;         OPT_HOSTNAME=true;       OPT_STATIC_IP=false
OPT_TELEGRAM=false;    OPT_REVERSE_PROXY=false;  OPT_MONITORING=false
OPT_REMOTE_BACKUP=false; OPT_BOOT_RECOVERY=true; OPT_USB_DETECT=true

STATIC_IP=""; STATIC_GW=""; STATIC_DNS=""
TG_TOKEN=""; TG_CHAT=""
PROXY_DOMAIN=""; REMOTE_BACKUP_TARGET=""
SKIP_UPDATE=false; CHECK_ONLY=false; UNINSTALL=false
DRY_RUN=false; SILENT=false; SHOW_STATUS=false
DO_UPDATE=false; DO_SELF_TEST=false; DO_SELF_UPDATE=false
DO_EXPORT_CONFIG=false; DO_SHOW_HISTORY=false; DO_BENCHMARK=false
INTERACTIVE_STEPS=false
HA_MACHINE="$HA_DEFAULT_MACHINE"; MACHINE_EXPLICIT=false
OVERRIDE_OS_AGENT_VER=""; OVERRIDE_HA_VER=""
LOG_FILE=""; LOGGING_ACTIVE=false; TEE_PID=""
OS_RELEASE_FAKED=false; DAEMON_RELOAD_NEEDED=false
PREFETCH_PID=""; HA_TMP="/tmp/ha-install"; INSTALL_START=""
PROFILE=""; FROM_STEP=""; IMPORT_CONFIG=""
ORIGINAL_ARGS=""
CURRENT_STEP_NUM=0

# v9.0+ options
OPT_TIMEZONE=""; OPT_DATA_DIR=""; OPT_WIFI_SSID=""; OPT_WIFI_PASS=""
OPT_WEBHOOK_URL=""; OPT_SWAP_SIZE=""; OPT_DOCKER_MIRROR=""
OPT_RESTORE_BACKUP=""; OPT_AUTO_REBOOT=false; OPT_LOCALE=""

SYSTEM_INFO_LOADED=false
CACHED_CODENAME=""; CACHED_VERSION_ID=""
CACHED_ARCH=""; CACHED_MACHINE_ARCH=""
CACHED_PRETTY_NAME=""; CACHED_OS_ID=""
declare -A RELEASE_CACHE
RESOLVED_OA_VER=""; RESOLVED_HA_VER=""
declare -a ROLLBACK_ACTIONS=()
declare -A STEP_TIMES=()

declare -A STEP_DEPS=(
  [preflight]="" [update]="preflight" [deps]="update" [network]="deps"
  [apparmor]="deps" [perf]="deps" [docker]="deps" [versions]="docker"
  [download]="versions" [osagent]="download" [ha]="osagent network apparmor"
  [sec]="ha" [extras]="ha" [hacs]="extras" [postrestore]="hacs"
)

readonly ALL_STEPS=(preflight update deps network apparmor perf docker versions download osagent ha sec extras hacs postrestore)
readonly TOTAL_STEPS=${#ALL_STEPS[@]}

declare -A PROFILES=(
  [minimal]="OPT_ZRAM=true OPT_EMMC_TUNING=false OPT_USB_POWER=false OPT_UFW=false OPT_SSH_HARDENING=false OPT_AUTOUPDATE=false OPT_WATCHDOG=false OPT_THERMAL=false OPT_BACKUP=false OPT_HACS=false OPT_HOSTNAME=true OPT_MONITORING=false OPT_REVERSE_PROXY=false OPT_REMOTE_BACKUP=false OPT_BOOT_RECOVERY=false OPT_USB_DETECT=false"
  [standard]="OPT_ZRAM=true OPT_EMMC_TUNING=true OPT_USB_POWER=true OPT_UFW=true OPT_SSH_HARDENING=true OPT_AUTOUPDATE=true OPT_WATCHDOG=true OPT_THERMAL=true OPT_BACKUP=true OPT_HACS=true OPT_HOSTNAME=true OPT_MONITORING=false OPT_REVERSE_PROXY=false OPT_REMOTE_BACKUP=false OPT_BOOT_RECOVERY=true OPT_USB_DETECT=true"
  [full]="OPT_ZRAM=true OPT_EMMC_TUNING=true OPT_USB_POWER=true OPT_UFW=true OPT_SSH_HARDENING=true OPT_AUTOUPDATE=true OPT_WATCHDOG=true OPT_THERMAL=true OPT_BACKUP=true OPT_HACS=true OPT_HOSTNAME=true OPT_MONITORING=true OPT_REVERSE_PROXY=false OPT_REMOTE_BACKUP=false OPT_BOOT_RECOVERY=true OPT_USB_DETECT=true"
  [server]="OPT_ZRAM=true OPT_EMMC_TUNING=true OPT_USB_POWER=true OPT_UFW=true OPT_SSH_HARDENING=true OPT_AUTOUPDATE=true OPT_WATCHDOG=true OPT_THERMAL=true OPT_BACKUP=true OPT_HACS=true OPT_HOSTNAME=true OPT_STATIC_IP=true OPT_MONITORING=true OPT_REVERSE_PROXY=false OPT_REMOTE_BACKUP=false OPT_BOOT_RECOVERY=true OPT_USB_DETECT=true"
  [dev]="OPT_ZRAM=false OPT_EMMC_TUNING=false OPT_USB_POWER=false OPT_UFW=false OPT_SSH_HARDENING=false OPT_AUTOUPDATE=false OPT_WATCHDOG=false OPT_THERMAL=false OPT_BACKUP=false OPT_HACS=true OPT_HOSTNAME=false OPT_MONITORING=false OPT_REVERSE_PROXY=false OPT_REMOTE_BACKUP=false OPT_BOOT_RECOVERY=false OPT_USB_DETECT=false"
)

# ============================================================================
# OUTPUT
# ============================================================================
header() {
  local t="$1"
  local b="================================================================"
  local p=$(( 60 - ${#t} )); [ "$p" -lt 0 ] && p=0
  echo -e "\n${BLUE}+${b}+${NC}"
  echo -e "${BLUE}|${WHITE}${BOLD} ${t}$(printf '%*s' "$p" '')${NC}${BLUE}|${NC}"
  echo -e "${BLUE}+${b}+${NC}\n"
}

separator() { [ "$SILENT" = true ] && return; echo -e "${DIM} ----------------------------------------------------------------${NC}"; }
msg_info()   { [ "$SILENT" = true ] && return; echo -e "   ${INFO}  ${WHITE}$1${NC}"; }
msg_ok()     { [ "$SILENT" = true ] && return; echo -e "   ${CHECK} ${GREEN}$1${NC}"; }
msg_warn()   { echo -e "   ${WARN}  ${YELLOW}$1${NC}"; }
msg_error()  { echo -e "   ${CROSS} ${RED}$1${NC}"; }
msg_action() { [ "$SILENT" = true ] && return; echo -e "   ${ARROW}  ${CYAN}$1${NC}"; }
msg_dim()    { [ "$SILENT" = true ] && return; echo -e "      ${DIM}$1${NC}"; }

progress_bar() {
  [ "$SILENT" = true ] && return
  local current="$1" total="$2" desc="${3:-}"
  [ "$total" -le 0 ] 2>/dev/null && return
  local width=35 pct=$((current * 100 / total))
  local filled=$((current * width / total)) empty=$((width - filled))
  local bar="" i
  for ((i=0; i<filled; i++)); do bar="${bar}#"; done
  for ((i=0; i<empty; i++)); do bar="${bar}."; done
  printf "\r  [%s] %3d%% %s  " "$bar" "$pct" "$desc" > /dev/tty 2>/dev/null || true
}

progress_clear() { printf "\r%80s\r" "" > /dev/tty 2>/dev/null || true; }

# ============================================================================
# LOGGING (simple tee, no nested process substitution)
# ============================================================================
setup_logging() {
  LOG_FILE="${LOG_FILE:-${LOG_DIR}/ha_install_$(date +%Y%m%d_%H%M%S).log}"
  mkdir -p "$(dirname "$LOG_FILE")"
  exec 3>&1 4>&2
  exec > >(tee -a "$LOG_FILE") 2>&1
  TEE_PID=""
  LOGGING_ACTIVE=true
  msg_info "Log: ${LOG_FILE}"
}

flush_log() {
  if [ "$LOGGING_ACTIVE" = true ]; then
    exec 1>&3 2>&4 3>&- 4>&- 2>/dev/null || true
    LOGGING_ACTIVE=false
    [ -n "$TEE_PID" ] && wait "$TEE_PID" 2>/dev/null || true
    sleep 0.3
  fi
}

spinner_pid=""
spinner_start() {
  local d="$1"; [ "$SILENT" = true ] && return
  ( i=0 e=0; while true; do
    local c; case $((i%4)) in 0) c="|";; 1) c="/";; 2) c="-";; 3) c="\\";; esac
    printf "\r  %s %s (%ds)  " "$c" "$d" "$e" > /dev/tty 2>/dev/null || break
    sleep 1; i=$((i+1)); e=$((e+1))
  done ) &
  spinner_pid=$!; disown "$spinner_pid" 2>/dev/null || true
}

spinner_stop() {
  if [ -n "$spinner_pid" ] && kill -0 "$spinner_pid" 2>/dev/null; then
    kill "$spinner_pid" 2>/dev/null; wait "$spinner_pid" 2>/dev/null
    printf "\r%80s\r" "" > /dev/tty 2>/dev/null || true
  fi
  spinner_pid=""
}

# ============================================================================
# DIRS, APT, TMPFS
# ============================================================================
setup_tmpdir() {
  mkdir -p "$HA_TMP"
  df -T "$HA_TMP" 2>/dev/null | grep -q tmpfs || \
    mount -t tmpfs -o size=512M tmpfs "$HA_TMP" 2>/dev/null || true
}

cleanup_tmpdir() {
  umount "$HA_TMP" 2>/dev/null || true
  rm -rf "$HA_TMP" 2>/dev/null || true
}

setup_dirs() {
  mkdir -p "$HA_INSTALLER_DIR" "$BACKUP_DIR" "$HA_BACKUP_DIR"
  chmod 750 "$HA_INSTALLER_DIR" "$BACKUP_DIR" "$HA_BACKUP_DIR"
}

apt_wait_lock() {
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 || \
        fuser /var/lib/apt/lists/lock &>/dev/null 2>&1; do
    [ $waited -ge 120 ] && { msg_error "dpkg/apt locked >120s"; return 1; }
    msg_dim "Waiting for dpkg/apt lock... ${waited}s"
    sleep 5; waited=$((waited+5))
  done
  return 0
}

apt_safe() {
  apt_wait_lock || return 1
  if command -v timeout &>/dev/null; then
    timeout 600 apt-get "$@"
  else
    apt-get "$@"
  fi
}

# ============================================================================
# TEXT FALLBACK UI (all prompts to stderr, only return values to stdout)
# ============================================================================
text_menu() {
  local title="$1" prompt="$2"; shift 2
  echo -e "\n   ${BOLD}${title}${NC}" >&2
  echo -e "   ${prompt}\n" >&2
  local i=1; local -a items=()
  while [ $# -ge 2 ]; do
    echo -e "   ${CYAN}${i})${NC} $1 - ${DIM}$2${NC}" >&2
    items+=("$1"); shift 2; i=$((i+1))
  done
  echo "" >&2
  echo -en "   Choice [1-${#items[@]}]: " >&2
  local n; read -r n
  if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#items[@]} ]; then
    echo "${items[$((n-1))]}"
    return 0
  fi
  return 1
}

text_yesno() {
  local prompt="$1" default="${2:-y}"
  echo -en "   ${prompt} (y/n) [${default}]: " >&2
  local ans; read -r ans
  [ -z "$ans" ] && ans="$default"
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

text_input() {
  local prompt="$1" default="${2:-}"
  echo -en "   ${prompt}" >&2
  [ -n "$default" ] && echo -en " [${default}]" >&2
  echo -en ": " >&2
  local val; read -r val
  [ -z "$val" ] && val="$default"
  echo "$val"
}

text_password() {
  local prompt="$1"
  echo -en "   ${prompt}: " >&2
  local val; read -rs val
  echo "" >&2
  echo "$val"
}

# ============================================================================
# CONFIG (safe key=value parser — all v9.1 fields)
# ============================================================================
save_config() {
  cat > "$HA_CONFIG_FILE" << EOF
INSTALLED_VERSION="${SCRIPT_VERSION}"
INSTALLED_DATE="$(date -Iseconds)"
HA_MACHINE="${HA_MACHINE}"
OA_VERSION="${RESOLVED_OA_VER}"
HA_VERSION="${RESOLVED_HA_VER}"
OS_RELEASE_FAKED=${OS_RELEASE_FAKED}
BACKUP_DIR="${HA_BACKUP_DIR}"
OPT_ZRAM=${OPT_ZRAM}
OPT_UFW=${OPT_UFW}
OPT_WATCHDOG=${OPT_WATCHDOG}
OPT_THERMAL=${OPT_THERMAL}
OPT_BACKUP=${OPT_BACKUP}
OPT_HACS=${OPT_HACS}
OPT_MONITORING=${OPT_MONITORING}
OPT_DATA_DIR="${OPT_DATA_DIR}"
OPT_TIMEZONE="${OPT_TIMEZONE}"
OPT_WEBHOOK_URL="${OPT_WEBHOOK_URL}"
OPT_SWAP_SIZE="${OPT_SWAP_SIZE}"
OPT_DOCKER_MIRROR="${OPT_DOCKER_MIRROR}"
OPT_AUTO_REBOOT=${OPT_AUTO_REBOOT}
OPT_LOCALE="${OPT_LOCALE}"
PROFILE="${PROFILE}"
EOF
  chmod 600 "$HA_CONFIG_FILE"
}

load_config() {
  [ -f "$HA_CONFIG_FILE" ] || return 0
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ ^([A-Z_][A-Z_0-9]*)=(.*) ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      val="${val#\"}"; val="${val%\"}"
      case "$key" in
        INSTALLED_VERSION|INSTALLED_DATE|HA_MACHINE|OA_VERSION|HA_VERSION|\
        OS_RELEASE_FAKED|BACKUP_DIR|OPT_ZRAM|OPT_UFW|OPT_WATCHDOG|\
        OPT_THERMAL|OPT_BACKUP|OPT_HACS|OPT_MONITORING|PROFILE|\
        OPT_DATA_DIR|OPT_TIMEZONE|OPT_WEBHOOK_URL|OPT_SWAP_SIZE|\
        OPT_DOCKER_MIRROR|OPT_AUTO_REBOOT|OPT_LOCALE)
          printf -v "$key" '%s' "$val"
          ;;
      esac
    fi
  done < "$HA_CONFIG_FILE"
}

# ============================================================================
# HISTORY
# ============================================================================
log_run_history() {
  mkdir -p "$HA_INSTALLER_DIR"
  echo "$(date -Iseconds)|v${SCRIPT_VERSION}|$(whoami)|$*|${PROFILE:-none}" >> "$HISTORY_FILE"
  tail -50 "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" 2>/dev/null && \
    mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
}

show_history() {
  [ ! -f "$HISTORY_FILE" ] && { msg_info "No history"; return; }
  header "RUN HISTORY"
  while IFS='|' read -r ts ver user args prof; do
    echo -e "   ${DIM}${ts}${NC} ${ver} ${user} ${CYAN}${args}${NC} [${prof}]"
  done < "$HISTORY_FILE"
}

# ============================================================================
# EXPORT / IMPORT CONFIG
# ============================================================================
export_config() {
  load_config
  local ef="${HA_BACKUP_DIR}/ha_config_$(date +%Y%m%d).sh"
  mkdir -p "$HA_BACKUP_DIR"
  {
    echo "# HA Installer config export $(date)"
    for opt in OPT_ZRAM OPT_EMMC_TUNING OPT_USB_POWER OPT_UFW OPT_SSH_HARDENING \
      OPT_AUTOUPDATE OPT_WATCHDOG OPT_THERMAL OPT_BACKUP OPT_HACS OPT_HOSTNAME \
      OPT_MONITORING OPT_BOOT_RECOVERY OPT_USB_DETECT OPT_STATIC_IP OPT_TELEGRAM \
      OPT_REVERSE_PROXY OPT_REMOTE_BACKUP; do
      echo "${opt}=${!opt}"
    done
    echo "PROFILE=\"${PROFILE}\""
    echo "HA_MACHINE=\"${HA_MACHINE}\""
    [ -n "$OPT_TIMEZONE" ] && echo "OPT_TIMEZONE=\"${OPT_TIMEZONE}\""
    [ -n "$OPT_DATA_DIR" ] && echo "OPT_DATA_DIR=\"${OPT_DATA_DIR}\""
    [ -n "$OPT_WEBHOOK_URL" ] && echo "OPT_WEBHOOK_URL=\"${OPT_WEBHOOK_URL}\""
    [ -n "$OPT_LOCALE" ] && echo "OPT_LOCALE=\"${OPT_LOCALE}\""
  } > "$ef"
  chmod 600 "$ef"
  msg_ok "Config: ${ef}"
}

import_config() {
  local file="$1"
  [ ! -f "$file" ] && { msg_error "Not found: ${file}"; exit 1; }
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ ^(OPT_[A-Z_]+|PROFILE|HA_MACHINE)=(.*) ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      val="${val#\"}"; val="${val%\"}"
      # Only allow safe values
      [[ "$val" =~ ^[a-zA-Z0-9._:/-]+$ ]] || { msg_warn "Skip invalid: ${key}"; continue; }
      printf -v "$key" '%s' "$val"
    fi
  done < "$file"
  RUN_WIZARD=false
  msg_ok "Imported: ${file}"
}

# ============================================================================
# NOTIFICATIONS (Telegram + any webhook, with test function)
# ============================================================================
send_notification() {
  local msg="$1"
  # Telegram
  if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] && [ "$TG_TOKEN" != "__HA_TG_TOKEN__" ]; then
    local rf="/tmp/.ha_notify_rate"
    local now; now=$(date +%s)
    local last; last=$(cat "$rf" 2>/dev/null || echo 0)
    if [ $((now - last)) -ge 30 ]; then
      echo "$now" > "$rf"
      curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT}" \
        --data-urlencode "text=HA ($(hostname)): ${msg}" >/dev/null 2>&1
    fi
  fi
  # Webhook
  if [ -n "$OPT_WEBHOOK_URL" ]; then
    curl -s -X POST "$OPT_WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"text\":\"HA ($(hostname)): ${msg}\",\"message\":\"HA ($(hostname)): ${msg}\"}" \
      >/dev/null 2>&1 || \
    curl -s -X POST "$OPT_WEBHOOK_URL" \
      -d "HA ($(hostname)): ${msg}" >/dev/null 2>&1 || true
  fi
}

test_notifications() {
  local ok=true
  if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
    msg_action "Testing Telegram..."
    local rc
    rc=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TG_CHAT}" \
      --data-urlencode "text=HA Installer: test" 2>/dev/null)
    [ "$rc" = "200" ] && msg_ok "Telegram OK" || { msg_warn "Telegram failed (${rc})"; ok=false; }
  fi
  if [ -n "$OPT_WEBHOOK_URL" ]; then
    msg_action "Testing webhook..."
    local rc
    rc=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$OPT_WEBHOOK_URL" \
      -d "HA Installer: test" 2>/dev/null)
    if [ "$rc" -ge 200 ] 2>/dev/null && [ "$rc" -lt 300 ] 2>/dev/null; then
      msg_ok "Webhook OK"
    else
      msg_warn "Webhook failed (${rc})"; ok=false
    fi
  fi
  $ok
}

# ============================================================================
# STATE, LOCK, ROLLBACK
# ============================================================================
acquire_lock() {
  exec 200>"$LOCK_FILE"
  flock -n 200 || { msg_error "Already running"; exit 1; }
  echo $$ > "$LOCK_FILE"
}

release_lock() {
  flock -u 200 2>/dev/null || true
  rm -f "$LOCK_FILE" 2>/dev/null || true
}

mark_done() {
  local s="$1" t; t=$(date +%s)
  (
    flock -x 201
    { grep -v "^${s}|" "$STATE_FILE" 2>/dev/null || true
      echo "${s}|${t}|${SCRIPT_VERSION}"
    } > "${STATE_FILE}.new" && mv "${STATE_FILE}.new" "$STATE_FILE"
  ) 201>"${STATE_FILE}.lock"
}

is_done() {
  local s="$1"
  [ ! -f "$STATE_FILE" ] && return 1
  local l; l=$(grep "^${s}|" "$STATE_FILE" 2>/dev/null | tail -1) || return 1
  local v; v=$(echo "$l" | cut -d'|' -f3)
  [ "$v" != "$SCRIPT_VERSION" ] && { msg_dim "${s}: v${v}->v${SCRIPT_VERSION}"; return 1; }
  return 0
}

reset_state() {
  rm -f "$STATE_FILE" "$GRACE_MARKER" "${STATE_FILE}.lock" "$REBOOT_ATTEMPT_FILE" 2>/dev/null || true
  msg_ok "State reset."
}

schedule_daemon_reload() { DAEMON_RELOAD_NEEDED=true; }

flush_daemon_reload() {
  if [ "$DAEMON_RELOAD_NEEDED" = true ]; then
    systemctl daemon-reload 2>/dev/null || true
    DAEMON_RELOAD_NEEDED=false
  fi
}

check_step_deps() {
  local step="$1"
  local deps="${STEP_DEPS[$step]:-}"
  [ -z "$deps" ] && return 0
  local dep
  for dep in $deps; do
    is_done "$dep" 2>/dev/null || {
      msg_error "'${step}' requires '${dep}'"
      return 1
    }
  done
  return 0
}

show_progress() {
  [ "$SILENT" = true ] && return
  local done_count=0
  separator
  for s in "${ALL_STEPS[@]}"; do
    if is_done "$s" 2>/dev/null; then
      done_count=$((done_count+1))
      local ts
      ts=$(grep "^${s}|" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d'|' -f2)
      echo -e "   ${CHECK} ${s} ${DIM}[$(date -d "@$ts" '+%H:%M' 2>/dev/null || echo '?')]${NC}"
    else
      echo -e "   ${DIM}o ${s}${NC}"
    fi
  done
  echo -e "\n   ${BOLD}Progress: ${done_count}/${TOTAL_STEPS}${NC}"
  separator
}

push_rollback() { ROLLBACK_ACTIONS+=("$1"); }

execute_rollback() {
  [ ${#ROLLBACK_ACTIONS[@]} -eq 0 ] && return
  msg_warn "Rolling back..."
  local i
  for ((i=${#ROLLBACK_ACTIONS[@]}-1; i>=0; i--)); do
    msg_dim "<- ${ROLLBACK_ACTIONS[$i]}"
    eval "${ROLLBACK_ACTIONS[$i]}" 2>/dev/null || true
  done
  msg_ok "Rollback done"
}

ask_continue_on_error() {
  local sn="$1" em="$2"
  msg_error "${sn}: ${em}"
  [ "$SILENT" = true ] && return 0
  if [ -t 0 ]; then
    echo -en "   ${WARN}  ${YELLOW}Continue? (y/n): ${NC}"
    local ans; read -r -t 30 ans || ans="y"
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || [ "$ans" = "" ]
  else
    return 0
  fi
}

require_disk_space() {
  local req="$1" desc="$2"
  local avail; avail=$(df -m / | awk 'NR==2{print $4}')
  if [ "$avail" -lt "$req" ]; then
    msg_warn "${desc}: need ${req}MB, have ${avail}MB"
    msg_action "Cleanup..."
    apt-get clean 2>/dev/null || true
    journalctl --vacuum-size=50M 2>/dev/null || true
    command -v docker &>/dev/null && docker system prune -f 2>/dev/null || true
    avail=$(df -m / | awk 'NR==2{print $4}')
    [ "$avail" -lt "$req" ] && { msg_error "Not enough: ${avail}MB < ${req}MB"; return 1; }
    msg_ok "Freed: ${avail}MB"
  fi
  return 0
}

# ============================================================================
# SSH NOHUP, TIME ESTIMATE, REBOOT CONTINUE (with attempt counter + /tmp safety)
# ============================================================================
auto_nohup_if_ssh() {
  if who 2>/dev/null | grep -q pts && [ -z "${HA_NOHUP:-}" ]; then
    msg_warn "SSH session detected."
    if [ -t 0 ]; then
      echo -en "   ${ARROW}  Run via nohup (survives disconnect)? (y/n): " >&2
      local ans; read -r ans
      if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        export HA_NOHUP=1
        local nlog="${LOG_DIR}/ha_install_nohup_$(date +%Y%m%d_%H%M%S).log"
        msg_info "Follow: tail -f ${nlog}"
        nohup bash "$0" $ORIGINAL_ARGS >> "$nlog" 2>&1 &
        msg_ok "PID: $!"
        exit 0
      fi
    fi
  fi
}

estimate_install_time() {
  detect_system_info
  local ram_mb cpu_cores est_min
  ram_mb=$(free -m | awk '/Mem:/{print $2}')
  cpu_cores=$(nproc 2>/dev/null || echo 1)
  est_min=15
  [ "$ram_mb" -lt 2048 ] && est_min=$((est_min + 10))
  [ "$cpu_cores" -lt 4 ] && est_min=$((est_min + 5))
  [ "$OPT_HACS" = true ] && est_min=$((est_min + 3))
  msg_info "Estimated: ~${est_min} min"
}

# Ensure script is in safe location for reboot-continue
ensure_safe_script_path() {
  local current_path
  current_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
  if [[ "$current_path" == /tmp/* ]] || [[ "$current_path" == /var/tmp/* ]]; then
    cp "$current_path" "$SAFE_SCRIPT_PATH" 2>/dev/null
    chmod +x "$SAFE_SCRIPT_PATH"
    msg_dim "Script copied to ${SAFE_SCRIPT_PATH}"
  elif [ ! -f "$SAFE_SCRIPT_PATH" ]; then
    cp "$current_path" "$SAFE_SCRIPT_PATH" 2>/dev/null
    chmod +x "$SAFE_SCRIPT_PATH"
  fi
}

setup_reboot_continue() {
  ensure_safe_script_path
  local svc_file="/etc/systemd/system/${REBOOT_CONTINUE_SVC}.service"
  local attempts=0
  [ -f "$REBOOT_ATTEMPT_FILE" ] && attempts=$(cat "$REBOOT_ATTEMPT_FILE" 2>/dev/null || echo 0)
  if [ "$attempts" -ge 3 ]; then
    msg_error "Max reboot attempts (3) reached"
    rm -f "$REBOOT_ATTEMPT_FILE"
    return 1
  fi
  echo $((attempts + 1)) > "$REBOOT_ATTEMPT_FILE"

  cat > "$svc_file" << SVCEOF
[Unit]
Description=HA Installer continue after reboot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${SAFE_SCRIPT_PATH} ${ORIGINAL_ARGS} --from-step=perf
ExecStartPost=/bin/rm -f ${svc_file}
RemainAfterExit=no
StandardOutput=append:${LOG_DIR}/ha_install_reboot.log
StandardError=append:${LOG_DIR}/ha_install_reboot.log

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload 2>/dev/null || true
  systemctl enable "${REBOOT_CONTINUE_SVC}" 2>/dev/null || true
  msg_ok "Will continue after reboot (attempt $((attempts+1))/3)"
}

remove_reboot_continue() {
  systemctl disable "${REBOOT_CONTINUE_SVC}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${REBOOT_CONTINUE_SVC}.service" "$REBOOT_ATTEMPT_FILE" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
}

# ============================================================================
# RUN_STEP (with step counter and timing)
# ============================================================================
run_step() {
  local f="$1"; shift
  CURRENT_STEP_NUM=$((CURRENT_STEP_NUM + 1))
  local t0; t0=$(date +%s)

  local step_id=""
  case "$f" in
    step_preflight)          step_id="preflight";;
    step_update_system)      step_id="update";;
    step_install_deps)       step_id="deps";;
    step_configure_network)  step_id="network";;
    step_configure_apparmor) step_id="apparmor";;
    step_performance)        step_id="perf";;
    step_install_docker)     step_id="docker";;
    step_resolve_versions)   step_id="versions";;
    step_download_packages)  step_id="download";;
    step_install_os_agent)   step_id="osagent";;
    step_install_ha)         step_id="ha";;
    step_security)           step_id="sec";;
    step_extras)             step_id="extras";;
    step_hacs)               step_id="hacs";;
    step_post_restore)       step_id="postrestore";;
  esac

  [ -n "$step_id" ] && check_step_deps "$step_id"

  if [ "$INTERACTIVE_STEPS" = true ] && [ -t 0 ]; then
    echo -en "   ${ARROW} [${CURRENT_STEP_NUM}/${TOTAL_STEPS}] ${step_id:-$f}? (y/n/q): " >&2
    local ans; read -r ans
    case "$ans" in
      n|N) msg_dim "Skipped"; return 0;;
      q|Q) msg_warn "Aborted"; exit 0;;
    esac
  fi

  "$f" "$@"
  local rc=$?
  local e=$(( $(date +%s) - t0 ))

  # Store timing for final report
  [ -n "$step_id" ] && STEP_TIMES[$step_id]=$e
  [ $e -gt 5 ] && msg_dim "T ${e}s"
  return $rc
}

# ============================================================================
# CLEANUP (removes reboot service only if auto-reboot not in progress)
# ============================================================================
cleanup() {
  local ec=$?
  spinner_stop 2>/dev/null || true
  [ -n "$PREFETCH_PID" ] && kill "$PREFETCH_PID" 2>/dev/null || true
  cleanup_tmpdir 2>/dev/null || true
  release_lock
  flush_log 2>/dev/null || true
  if [ $ec -ne 0 ] && [ $ec -ne 130 ]; then
    [ ${#ROLLBACK_ACTIONS[@]} -gt 0 ] && execute_rollback
    # Only remove reboot service if we're not about to reboot
    [ "$OPT_AUTO_REBOOT" != true ] && remove_reboot_continue
  fi
  [ $ec -eq 130 ] && echo -e "\n ${WARN} ${YELLOW}Interrupted${NC}"
  # Beep on success
  [ $ec -eq 0 ] && [ -n "$INSTALL_START" ] && echo -e "\a" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ============================================================================
# MIGRATION
# ============================================================================
migrate_legacy_paths() {
  [ -f "/root/.ha_install_state" ] && [ ! -f "$STATE_FILE" ] && {
    mkdir -p "$HA_INSTALLER_DIR"
    mv "/root/.ha_install_state" "$STATE_FILE" 2>/dev/null || true
  }
  [ -d "/root/.ha_install_backup" ] && [ ! -d "$BACKUP_DIR" ] && {
    mkdir -p "$BACKUP_DIR"
    cp -a /root/.ha_install_backup/* "$BACKUP_DIR/" 2>/dev/null || true
  }
  if [ -d "/root/ha-backups" ] && [ ! -d "$HA_BACKUP_DIR" ]; then
    mkdir -p "$HA_BACKUP_DIR"
    mv /root/ha-backups/* "$HA_BACKUP_DIR/" 2>/dev/null || true
    rmdir /root/ha-backups 2>/dev/null || true
  fi
  local dropin="/etc/systemd/system/hassio-supervisor.service.d/fix-os-release.conf"
  [ -f "$dropin" ] && grep -q "/root/" "$dropin" 2>/dev/null && {
    sed -i "s|/root/.ha_install_backup|${BACKUP_DIR}|g" "$dropin" 2>/dev/null
    systemctl daemon-reload 2>/dev/null || true
  }
}

# ============================================================================
# SYSTEM DETECTION
# ============================================================================
detect_arch() {
  case "$(uname -m)" in
    x86_64)  echo "x86_64";;
    aarch64) echo "aarch64";;
    armv7l)  echo "armv7";;
    i686)    echo "i386";;
    *)       echo "unknown";;
  esac
}

detect_system_info() {
  [ "$SYSTEM_INFO_LOADED" = true ] && return 0
  if [ -f /etc/os-release ]; then
    local _vc="" _vi="" _pn="" _id=""
    eval "$(. /etc/os-release 2>/dev/null; printf '_vc=%q _vi=%q _pn=%q _id=%q' \
      "${VERSION_CODENAME:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-}" "${ID:-}")"
    CACHED_CODENAME="$_vc"
    CACHED_VERSION_ID="$_vi"
    CACHED_PRETTY_NAME="$_pn"
    CACHED_OS_ID="$_id"
  fi
  CACHED_ARCH=$(detect_arch)
  CACHED_MACHINE_ARCH=$(uname -m)
  SYSTEM_INFO_LOADED=true
}

is_trixie() {
  detect_system_info
  [ "$CACHED_CODENAME" = "trixie" ] || [ "$CACHED_VERSION_ID" = "13" ]
}

is_armbian() {
  [ -f /etc/armbian-release ] || dpkg -l 'armbian-bsp-cli-*' &>/dev/null
}

# ============================================================================
# PACKAGE & DOWNLOAD UTILITIES
# ============================================================================
is_pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

pkg_available() {
  apt-cache show "$1" >/dev/null 2>&1
}

run_cmd() {
  local d="$1"; shift
  local lf
  lf=$(mktemp "${HA_TMP}/ha_XXXXXX.log" 2>/dev/null || mktemp /tmp/ha_XXXXXX.log)
  msg_action "${d}..."
  [ "$DRY_RUN" = true ] && { msg_dim "[dry-run] $*"; rm -f "$lf"; return 0; }
  if "$@" > "$lf" 2>&1; then
    msg_ok "$d"; rm -f "$lf"; return 0
  else
    local c=$?
    msg_error "${d} (code ${c})"
    tail -15 "$lf" 2>/dev/null | while IFS= read -r l; do
      echo -e "   ${RED}|${NC} ${l}"
    done
    rm -f "$lf"; return $c
  fi
}

run_cmd_fatal() {
  run_cmd "$@" || { msg_error "Fatal."; exit 1; }
}

download_file() {
  local url="$1" out="$2" desc="$3" max="${4:-3}" att=1
  [ "$DRY_RUN" = true ] && { msg_action "${desc}..."; msg_dim "[dry-run] wget ${url}"; return 0; }
  while [ $att -le $max ]; do
    [ $att -gt 1 ] && sleep $((att*3))
    msg_action "${desc} (${att}/${max})..."
    rm -f "$out" 2>/dev/null || true
    if wget -q --timeout=60 --tries=1 -O "$out" "$url" 2>/dev/null && [ -s "$out" ]; then
      if [[ "$out" == *.deb ]]; then
        dpkg-deb --info "$out" &>/dev/null && { msg_ok "$desc"; return 0; } || msg_warn ".deb corrupt"
      else
        msg_ok "$desc"; return 0
      fi
    else
      msg_warn "Download error"
    fi
    att=$((att+1))
  done
  msg_error "${desc} failed"; return 1
}

verify_checksum() {
  local deb="$1" repo="$2" ver="$3"
  [ "$DRY_RUN" = true ] && return 0
  local url="https://github.com/${repo}/releases/download/${ver}/SHA256SUMS"
  local tmpsha
  tmpsha=$(mktemp /tmp/ha_sha_XXXXXX 2>/dev/null)
  if wget -q --timeout=10 -O "$tmpsha" "$url" 2>/dev/null && [ -s "$tmpsha" ]; then
    local exp act bn
    bn=$(basename "$deb")
    exp=$(grep "$bn" "$tmpsha" 2>/dev/null | awk '{print $1}')
    if [ -n "$exp" ]; then
      act=$(sha256sum "$deb" | awk '{print $1}')
      rm -f "$tmpsha"
      [ "$exp" = "$act" ] && { msg_ok "SHA256 OK"; return 0; } || { msg_error "SHA256 FAIL"; return 1; }
    fi
  fi
  rm -f "$tmpsha" 2>/dev/null
  msg_dim "SHA256 unavailable"; return 0
}

get_latest_release() {
  local repo="$1"
  [ -n "${RELEASE_CACHE[$repo]+x}" ] && { echo "${RELEASE_CACHE[$repo]}"; return 0; }
  local v=""
  if command -v curl &>/dev/null && command -v jq &>/dev/null; then
    v=$(curl -fsSL --timeout 15 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
      | jq -r '.tag_name // empty' 2>/dev/null | tr -d '[:space:]') || true
  fi
  if [ -z "$v" ] && command -v curl &>/dev/null; then
    local u
    u=$(curl -sL --timeout 15 -o /dev/null -w '%{url_effective}' \
      "https://github.com/${repo}/releases/latest" 2>/dev/null) || true
    [ -n "$u" ] && v=$(echo "$u" | sed 's|.*/tag/||' | tr -d '[:space:]')
  fi
  if [ -z "$v" ] && command -v wget &>/dev/null; then
    v=$(wget -q --timeout=15 --max-redirect=0 -S \
      "https://github.com/${repo}/releases/latest" 2>&1 \
      | grep -i 'Location:' | head -1 | sed 's|.*/tag/||' | tr -d '[:space:]') || true
  fi
  RELEASE_CACHE[$repo]="$v"
  echo "$v"
}

detect_machine_type() {
  local m=""
  m=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null) || true
  case "$(uname -m)" in
    x86_64) echo "generic-x86-64";;
    aarch64)
      case "$m" in
        *Raspberry*Pi*5*) echo "raspberrypi5-64";;
        *Raspberry*Pi*4*) echo "raspberrypi4-64";;
        *Raspberry*Pi*3*) echo "raspberrypi3-64";;
        *ODROID-N2*)      echo "odroid-n2";;
        *ODROID-C4*)      echo "odroid-c4";;
        *Khadas*VIM3*)    echo "khadas-vim3";;
        *)                echo "qemuarm-64";;
      esac;;
    armv7l) echo "qemuarm";;
    *)      echo "qemuarm-64";;
  esac
}

get_cpu_temp() {
  [ -f /sys/class/thermal/thermal_zone0/temp ] && \
    echo "$(($(cat /sys/class/thermal/thermal_zone0/temp)/1000))" || echo ""
}

check_internet() {
  ping -c1 -W2 github.com &>/dev/null & local p1=$!
  ping -c1 -W2 8.8.8.8 &>/dev/null & local p2=$!
  ping -c1 -W2 1.1.1.1 &>/dev/null & local p3=$!
  local dns=false net=false
  wait "$p1" 2>/dev/null && dns=true && net=true
  wait "$p2" 2>/dev/null && net=true
  wait "$p3" 2>/dev/null && net=true
  $dns && { msg_ok "Internet OK"; return 0; }
  $net && { msg_warn "DNS unstable"; fix_dns_if_needed; return 0; }
  msg_error "No internet"; return 1
}

fix_dns_if_needed() {
  if ! host github.com &>/dev/null 2>&1 && ping -c1 -W2 8.8.8.8 &>/dev/null; then
    msg_warn "DNS broken, fixing..."
    if [ -L /etc/resolv.conf ]; then
      msg_dim "resolv.conf is symlink, skip overwrite"
    else
      [ -f /etc/resolv.conf ] && cp /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.dns-fix" 2>/dev/null
      printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
      host github.com &>/dev/null 2>&1 && msg_ok "DNS fixed" || msg_warn "DNS still broken"
    fi
  fi
}

wait_ha_ready() {
  local to="${1:-300}" el=0
  while [ $el -lt $to ]; do
    if [ -f "${HASSIO_DIR}/homeassistant/configuration.yaml" ]; then
      local c
      c=$(curl -s -o /dev/null -w "%{http_code}" -m 3 http://localhost:8123 2>/dev/null || echo 000)
      [ "$c" = "200" ] || [ "$c" = "401" ] && return 0
    fi
    sleep 5; el=$((el+5))
    [ $((el%30)) -eq 0 ] && msg_dim "Waiting HA... ${el}s"
  done
  return 1
}

# ============================================================================
# VALIDATION
# ============================================================================
validate_ip() {
  local ip="$1" IFS='.'
  read -ra o <<< "$ip"
  [ ${#o[@]} -ne 4 ] && return 1
  for x in "${o[@]}"; do
    [[ "$x" =~ ^[0-9]+$ ]] || return 1
    [ "$x" -gt 255 ] && return 1
    [[ "$x" =~ ^0[0-9] ]] && return 1
  done
  [ "${o[0]}" = "0" ] && return 1
  [ "$ip" = "255.255.255.255" ] && return 1
  return 0
}

validate_gw() {
  [ -z "$1" ] && return 1
  validate_ip "$1"
}

validate_dns_list() {
  local dns_str="$1" IFS=','
  [ -z "$dns_str" ] && return 1
  read -ra dns_arr <<< "$dns_str"
  [ ${#dns_arr[@]} -eq 0 ] && return 1
  for d in "${dns_arr[@]}"; do
    d=$(echo "$d" | tr -d '[:space:]')
    validate_ip "$d" || return 1
  done
  return 0
}

get_current_prefix() {
  ip -o -4 addr show 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f2
}

# ============================================================================
# OS-RELEASE FAKING
# ============================================================================
os_release_needs_faking() {
  detect_system_info
  # Not Debian -> needs faking
  echo "$CACHED_PRETTY_NAME" | grep -qi "Debian" || return 0
  # Debian but unsupported codename -> needs faking
  echo "$HA_SUPPORTED_CODENAMES" | grep -qw "$CACHED_CODENAME" || return 0
  # Debian + supported -> no faking
  return 1
}

backup_os_release() {
  mkdir -p "$BACKUP_DIR"
  if [ ! -f "${BACKUP_DIR}/os-release.original" ]; then
    if [ -L /etc/os-release ]; then
      readlink /etc/os-release > "${BACKUP_DIR}/os-release.symlink"
      cp "$(readlink -f /etc/os-release)" "${BACKUP_DIR}/os-release.original"
    else
      cp /etc/os-release "${BACKUP_DIR}/os-release.original"
    fi
  fi
}

fake_os_release() {
  backup_os_release; detect_system_info
  local tc="bookworm" tv="12"
  if [ "$CACHED_CODENAME" = "trixie" ] || [ "$CACHED_VERSION_ID" = "13" ]; then
    tc="trixie"; tv="13"
  elif [ "$CACHED_CODENAME" = "bullseye" ] || [ "$CACHED_VERSION_ID" = "11" ]; then
    tc="bullseye"; tv="11"
  elif [ "$CACHED_CODENAME" = "sid" ] || [ "$CACHED_CODENAME" = "testing" ]; then
    tc="trixie"; tv="13"
  fi
  cat > /etc/os-release << EOF
PRETTY_NAME="Debian GNU/Linux ${tv} (${tc})"
NAME="Debian GNU/Linux"
VERSION_ID="${tv}"
VERSION="${tv} (${tc})"
VERSION_CODENAME=${tc}
ID=debian
HOME_URL="https://www.debian.org/"
SUPPORT_URL="https://www.debian.org/support"
BUG_REPORT_URL="https://bugs.debian.org/"
EOF
  cp /etc/os-release "$FAKED_OS_RELEASE"
  OS_RELEASE_FAKED=true
  msg_ok "os-release -> Debian ${tv} (${tc})"
}

restore_os_release() {
  if [ -f "${BACKUP_DIR}/os-release.symlink" ]; then
    local lt
    lt=$(cat "${BACKUP_DIR}/os-release.symlink")
    cp "${BACKUP_DIR}/os-release.original" "$lt" 2>/dev/null
    ln -sf "$lt" /etc/os-release 2>/dev/null
    msg_ok "os-release restored (symlink)"
  elif [ -f "${BACKUP_DIR}/os-release.original" ]; then
    cp "${BACKUP_DIR}/os-release.original" /etc/os-release
    msg_ok "os-release restored"
  fi
}

# ============================================================================
# DOCKER PREFETCH, NETWORK ROLLBACK, USB DETECTION, FS CHECKS
# ============================================================================
prefetch_docker_images() {
  [ "$DRY_RUN" = true ] && return 0
  command -v docker &>/dev/null || return 0
  detect_system_info
  local at=""
  case "$CACHED_MACHINE_ARCH" in
    x86_64) at="amd64";; aarch64) at="aarch64";; armv7l) at="armv7";; *) return 0;;
  esac
  msg_dim "Prefetching Docker images..."
  ( for img in supervisor dns cli audio multicast observer; do
    docker pull "ghcr.io/home-assistant/${at}-hassio-${img}:latest" 2>/dev/null || true
  done ) &
  PREFETCH_PID=$!; disown "$PREFETCH_PID" 2>/dev/null || true
}

wait_prefetch() {
  [ -n "$PREFETCH_PID" ] && kill -0 "$PREFETCH_PID" 2>/dev/null && {
    msg_dim "Waiting for prefetch..."
    wait "$PREFETCH_PID" 2>/dev/null || true
  }
  PREFETCH_PID=""
}

rollback_network() {
  msg_warn "Network rollback..."
  [ -f "${BACKUP_DIR}/interfaces.bak" ] && cp "${BACKUP_DIR}/interfaces.bak" /etc/network/interfaces 2>/dev/null
  [ -f "${BACKUP_DIR}/resolv.conf.bak" ] && cp "${BACKUP_DIR}/resolv.conf.bak" /etc/resolv.conf 2>/dev/null
  systemctl restart NetworkManager 2>/dev/null || true
  systemctl start networking 2>/dev/null || true
}

detect_usb_dongles() {
  [ "$OPT_USB_DETECT" != true ] && return
  msg_action "USB scan..."
  local found=false
  for dev in /dev/ttyUSB* /dev/ttyACM* /dev/serial/by-id/*; do
    [ -e "$dev" ] || continue
    local info
    info=$(udevadm info --query=all --name="$dev" 2>/dev/null) || continue
    case "$info" in
      *"Texas Instruments"*|*"Silicon Labs"*|*"dresden"*|*"ITEAD"*)
        msg_ok "Zigbee: ${dev}"; found=true;;
      *"Sigma Designs"*|*"Aeotec"*)
        msg_ok "Z-Wave: ${dev}"; found=true;;
    esac
  done
  hciconfig 2>/dev/null | grep -q "UP RUNNING" && { msg_ok "Bluetooth: active"; found=true; }
  $found || msg_dim "No USB dongles"
}

check_broken_state() {
  if [ -f /var/lib/dpkg/updates/0001 ] || dpkg --audit 2>/dev/null | grep -qE '[a-z]'; then
    msg_warn "Broken dpkg detected"
    msg_action "Repairing..."
    dpkg --configure -a 2>/dev/null || true
    apt-get install -f -y 2>/dev/null || true
    msg_ok "dpkg repaired"
  fi
  if command -v docker &>/dev/null && ! docker info &>/dev/null; then
    msg_warn "Docker unresponsive"
    systemctl restart docker 2>/dev/null || true
    sleep 5
    docker info &>/dev/null && msg_ok "Docker recovered" || msg_warn "Docker still broken"
  fi
}

check_filesystem() {
  touch /tmp/.ha_fs_test 2>/dev/null && rm -f /tmp/.ha_fs_test || {
    msg_error "Filesystem read-only!"
    return 1
  }
  dmesg 2>/dev/null | tail -100 | grep -qi "ext4.*error\|I/O error\|read-only" && {
    msg_warn "FS errors in dmesg"
    return 0
  }
  msg_ok "Filesystem OK"
}

verify_installed_scripts() {
  msg_action "Checking utilities..."
  local ok=0 miss=0 fix=0
  local -A expected=(
    [ha-notify]=true
    [ha-health]=true
    [ha-watchdog]="$OPT_WATCHDOG"
    [ha-cleanup]="$OPT_WATCHDOG"
    [ha-net-recovery]="$OPT_WATCHDOG"
    [ha-backup]="$OPT_BACKUP"
    [ha-restore]="$OPT_BACKUP"
    [ha-thermal]="$OPT_THERMAL"
    [ha-boot-check]="$OPT_BOOT_RECOVERY"
    [ha-metrics]="$OPT_MONITORING"
  )
  for s in "${!expected[@]}"; do
    [ "${expected[$s]}" != true ] && continue
    local p="/usr/local/bin/$s"
    if [ -f "$p" ]; then
      if [ ! -x "$p" ]; then chmod +x "$p"; fix=$((fix+1)); fi
      ok=$((ok+1))
    else
      miss=$((miss+1))
    fi
  done
  [ $fix -gt 0 ] && msg_warn "Fixed permissions: ${fix}"
  msg_ok "Utilities: ${ok} ok, ${miss} missing"
}

# ============================================================================
# v9.x FEATURES: DATA-DIR, TIMEZONE, LOCALE, WIFI, SWAP, DOCKER MIRROR, BENCHMARK
# ============================================================================
setup_data_dir() {
  [ -z "$OPT_DATA_DIR" ] && return 0
  local t="$OPT_DATA_DIR"

  if [ ! -d "$t" ]; then
    msg_error "Data dir missing: ${t}"
    return 1
  fi

  if ! touch "${t}/.ha_test" 2>/dev/null; then
    msg_error "Not writable: ${t}"
    return 1
  fi
  rm -f "${t}/.ha_test"

  # Validate filesystem type
  local fstype
  fstype=$(df -T "$t" 2>/dev/null | awk 'NR==2{print $2}')
  case "$fstype" in
    ext4|btrfs|xfs|ext3) msg_ok "Data dir FS: ${fstype}" ;;
    vfat|ntfs|exfat|fat32) msg_error "Unsupported FS: ${fstype} (need ext4/btrfs/xfs)"; return 1 ;;
    *) msg_warn "Data dir FS: ${fstype} (may work)" ;;
  esac

  local free_mb
  free_mb=$(df -m "$t" | awk 'NR==2{print $4}')
  [ "$free_mb" -lt 10000 ] && msg_warn "Only ${free_mb}MB free on ${t} (10GB+ recommended)"

  msg_action "Setting up external data: ${t}..."

  # Move Docker data
  if [ -d /var/lib/docker ] && [ ! -L /var/lib/docker ]; then
    systemctl stop docker 2>/dev/null || true
    mkdir -p "${t}/docker"
    if [ ! -d "${t}/docker/overlay2" ]; then
      rsync -aHAX /var/lib/docker/ "${t}/docker/" 2>/dev/null || \
        cp -a /var/lib/docker/* "${t}/docker/" 2>/dev/null
    fi
    mv /var/lib/docker /var/lib/docker.bak 2>/dev/null || true
    ln -sf "${t}/docker" /var/lib/docker
    systemctl start docker 2>/dev/null || true
    msg_ok "Docker data -> ${t}/docker"
  fi

  # Prepare hassio dir
  mkdir -p "${t}/hassio"
  if [ -d "$HASSIO_DIR" ] && [ ! -L "$HASSIO_DIR" ]; then
    rsync -aHAX "${HASSIO_DIR}/" "${t}/hassio/" 2>/dev/null || \
      cp -a "${HASSIO_DIR}"/* "${t}/hassio/" 2>/dev/null
    mv "$HASSIO_DIR" "${HASSIO_DIR}.bak" 2>/dev/null || true
    ln -sf "${t}/hassio" "$HASSIO_DIR"
    msg_ok "HA data -> ${t}/hassio"
  elif [ ! -d "$HASSIO_DIR" ]; then
    ln -sf "${t}/hassio" "$HASSIO_DIR"
    msg_ok "HA data linked: ${t}/hassio"
  fi
}

setup_timezone() {
  [ -z "$OPT_TIMEZONE" ] && return 0
  if [ -f "/usr/share/zoneinfo/${OPT_TIMEZONE}" ]; then
    timedatectl set-timezone "$OPT_TIMEZONE" 2>/dev/null || \
      ln -sf "/usr/share/zoneinfo/${OPT_TIMEZONE}" /etc/localtime
    msg_ok "Timezone: ${OPT_TIMEZONE}"
  else
    msg_warn "Unknown timezone: ${OPT_TIMEZONE}"
  fi
}

setup_locale() {
  [ -z "$OPT_LOCALE" ] && return 0
  msg_action "Locale: ${OPT_LOCALE}..."
  if command -v locale-gen &>/dev/null; then
    sed -i "s/^# *${OPT_LOCALE}/${OPT_LOCALE}/" /etc/locale.gen 2>/dev/null
    locale-gen 2>/dev/null || true
    update-locale LANG="${OPT_LOCALE}" 2>/dev/null || true
    msg_ok "Locale: ${OPT_LOCALE}"
  else
    msg_warn "locale-gen not available"
  fi
}

setup_wifi() {
  [ -z "$OPT_WIFI_SSID" ] && return 0
  command -v nmcli &>/dev/null || { msg_warn "nmcli unavailable for WiFi"; return 0; }
  msg_action "WiFi: ${OPT_WIFI_SSID}..."
  nmcli dev wifi connect "$OPT_WIFI_SSID" password "$OPT_WIFI_PASS" 2>/dev/null && \
    msg_ok "WiFi connected" || msg_warn "WiFi failed"
}

setup_swap() {
  [ -z "$OPT_SWAP_SIZE" ] && return 0
  case "$OPT_SWAP_SIZE" in
    none|0)
      swapoff -a 2>/dev/null
      sed -i '/swap/d' /etc/fstab 2>/dev/null
      msg_ok "Swap disabled"
      ;;
    zram)
      msg_dim "ZRAM configured in performance step"
      ;;
    *)
      if [[ "$OPT_SWAP_SIZE" =~ ^[0-9]+$ ]]; then
        swapoff /swapfile 2>/dev/null; rm -f /swapfile 2>/dev/null
        dd if=/dev/zero of=/swapfile bs=1M count="$OPT_SWAP_SIZE" status=none 2>/dev/null
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
        swapon /swapfile 2>/dev/null
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        msg_ok "Swap: ${OPT_SWAP_SIZE}MB"
      else
        msg_warn "Invalid swap size: ${OPT_SWAP_SIZE}"
      fi
      ;;
  esac
}

setup_docker_mirror() {
  [ -z "$OPT_DOCKER_MIRROR" ] && return 0
  mkdir -p /etc/docker
  if [ -f /etc/docker/daemon.json ] && command -v jq &>/dev/null; then
    jq --arg m "$OPT_DOCKER_MIRROR" '. + {"registry-mirrors": [$m]}' \
      /etc/docker/daemon.json > /tmp/dj.tmp 2>/dev/null && \
      mv /tmp/dj.tmp /etc/docker/daemon.json
  else
    echo "{\"log-driver\":\"journald\",\"storage-driver\":\"overlay2\",\"registry-mirrors\":[\"${OPT_DOCKER_MIRROR}\"]}" \
      > /etc/docker/daemon.json
  fi
  msg_ok "Docker mirror: ${OPT_DOCKER_MIRROR}"
}

do_benchmark() {
  header "BENCHMARK"
  detect_system_info
  local ram_mb cpu_cores
  ram_mb=$(free -m | awk '/Mem:/{print $2}')
  cpu_cores=$(nproc 2>/dev/null || echo 1)
  echo -e "   ${BOLD}CPU:${NC}  $(lscpu 2>/dev/null | awk -F: '/Model name/{print $2}' | xargs) (${cpu_cores} cores)"
  echo -e "   ${BOLD}RAM:${NC}  ${ram_mb}MB"
  echo -e "   ${BOLD}Arch:${NC} ${CACHED_MACHINE_ARCH}"
  echo -e "   ${BOLD}OS:${NC}   ${CACHED_PRETTY_NAME}"
  separator
  msg_action "Disk I/O test (50MB)..."
  local dio
  dio=$(dd if=/dev/zero of=/tmp/.ha_bench bs=1M count=50 oflag=dsync 2>&1 | tail -1 | awk -F, '{print $NF}' | xargs)
  rm -f /tmp/.ha_bench
  echo -e "   ${BOLD}Disk:${NC} ${dio}"
  separator
  local verdict="Suitable for Home Assistant"
  [ "$ram_mb" -lt 900 ] && verdict="NOT suitable (need 1GB+ RAM)"
  [ "$ram_mb" -lt 2048 ] && [ "$verdict" = "Suitable for Home Assistant" ] && verdict="Suitable (tight on RAM)"
  echo -e "\n   ${BOLD}Verdict:${NC} ${verdict}\n"
}

# Generate info file after installation
generate_info_file() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"
  cat > "$HA_INFO_FILE" << INFOEOF
============================================
 Home Assistant - Installation Info
 Generated: $(date)
 Installer: v${SCRIPT_VERSION}
============================================

ACCESS:
  http://${ip}:8123
  http://homeassistant.local:8123

PROFILE: ${PROFILE:-custom}
MACHINE: ${HA_MACHINE}
TIMEZONE: ${OPT_TIMEZONE:-system default}

PATHS:
  HA Config:  ${HASSIO_DIR}/homeassistant/
  HA Data:    ${HASSIO_DIR}/
  Backups:    ${HA_BACKUP_DIR}/
  Installer:  ${HA_INSTALLER_DIR}/
  Logs:       ${LOG_DIR}/ha_install_*.log
  Info:       ${HA_INFO_FILE}

COMMANDS:
  ha-health          System health report
  ha-backup          Create backup
  ha-restore         Restore from backup
  ha-notify "msg"    Send notification

MAINTENANCE:
  sudo ha-install --check       Diagnostics
  sudo ha-install --status      Live monitoring
  sudo ha-install --update      Update HA
  sudo ha-install --self-test   Self-test
  sudo ha-install --benchmark   Benchmark

SERVICES:
  systemctl status hassio-supervisor
  systemctl status hassio-apparmor
  docker ps

INFOEOF
  [ -n "$OPT_DATA_DIR" ] && echo "EXTERNAL STORAGE: ${OPT_DATA_DIR}" >> "$HA_INFO_FILE"
  [ "$OPT_UFW" = true ] && echo "FIREWALL: ufw status" >> "$HA_INFO_FILE"
  chmod 644 "$HA_INFO_FILE"
  msg_ok "Info: ${HA_INFO_FILE}"
}

# ============================================================================
# PROFILES & WIZARD
# ============================================================================
apply_profile() {
  local p="$1"
  [ -z "${PROFILES[$p]+x}" ] && { msg_error "Unknown profile '$p'. Available: ${!PROFILES[*]}"; exit 1; }
  eval "${PROFILES[$p]}"
  PROFILE="$p"
  RUN_WIZARD=false
  msg_ok "Profile: ${p}"
}

run_wizard() {
  local HAS_WHIPTAIL=false
  if command -v whiptail &>/dev/null; then
    HAS_WHIPTAIL=true
  else
    apt-get update -qq 2>/dev/null && apt-get install -y whiptail -qq 2>/dev/null && HAS_WHIPTAIL=true
  fi

  detect_system_info
  local si="${CACHED_PRETTY_NAME:-${CACHED_CODENAME}} (${CACHED_MACHINE_ARCH})"
  is_armbian && si+=" [Armbian]"
  local ram_mb; ram_mb=$(free -m | awk '/Mem:/{print $2}')
  local disk_mb; disk_mb=$(df -m / | awk 'NR==2{print $4}')

  # --- Welcome ---
  if [ "$HAS_WHIPTAIL" = true ]; then
    whiptail --title "HA Installer v${SCRIPT_VERSION}" --msgbox \
      "Home Assistant Supervised Installer\n\n${si}\nRAM: ${ram_mb}MB | Disk: ${disk_mb}MB free" 12 64
  else
    header "HA Installer v${SCRIPT_VERSION}"
    msg_info "${si}"
    msg_info "RAM: ${ram_mb}MB | Disk: ${disk_mb}MB free"
    echo ""
  fi

  # --- Quick vs Advanced ---
  local wizard_mode="advanced"
  if [ "$HAS_WHIPTAIL" = true ]; then
    wizard_mode=$(whiptail --title "Setup Mode" --menu "Choose:" 12 60 3 \
      "quick"    "Quick (profile + timezone)" \
      "advanced" "Advanced (all options)" \
      "expert"   "Expert (components + all extras)" \
      3>&1 1>&2 2>&3) || { echo "Cancelled."; exit 0; }
  else
    wizard_mode=$(text_menu "Setup Mode" "Choose:" \
      "quick" "Profile + timezone" \
      "advanced" "All options" \
      "expert" "Components + extras") || wizard_mode="advanced"
  fi

  # --- Benchmark (advanced/expert only) ---
  if [ "$wizard_mode" != "quick" ]; then
    local run_bench=false
    if [ "$HAS_WHIPTAIL" = true ]; then
      whiptail --title "Benchmark" --yesno "Run hardware benchmark? (~30s)" 8 50 --defaultno && run_bench=true
    else
      text_yesno "Run benchmark?" "n" && run_bench=true
    fi
    if [ "$run_bench" = true ]; then
      do_benchmark
      [ -t 0 ] && { echo -en "\n   Press Enter..." >&2; read -r; }
    fi
  fi

  # --- Profile (skip if already set via --profile) ---
  if [ -z "$PROFILE" ]; then
    local prof=""
    if [ "$HAS_WHIPTAIL" = true ]; then
      prof=$(whiptail --title "Profile" --menu "Select:" 18 65 6 \
        "minimal"  "HA + Docker only" \
        "standard" "Recommended" \
        "full"     "Full + monitoring" \
        "server"   "Server + static IP" \
        "dev"      "Developer" \
        "custom"   "Manual selection" \
        3>&1 1>&2 2>&3) || { echo "Cancelled."; exit 0; }
    else
      prof=$(text_menu "Profile" "Select:" \
        "minimal" "HA + Docker only" \
        "standard" "Recommended" \
        "full" "Full + monitoring" \
        "server" "Server + static IP" \
        "dev" "Developer" \
        "custom" "Manual") || { echo "Cancelled."; exit 0; }
    fi

    if [ "$prof" != "custom" ]; then
      apply_profile "$prof"
    else
      # --- Component selection (expert/custom only) ---
      if [ "$HAS_WHIPTAIL" = true ]; then
        local ch
        ch=$(whiptail --title "Components" --checklist "Space to toggle" 30 72 18 \
          "ZRAM" "ZRAM swap" ON "EMMC" "eMMC tuning" ON "USBPOWER" "USB power" ON \
          "UFW" "Firewall" ON "SSHHARD" "SSH hardening" ON "AUTOUPD" "Auto-updates" ON \
          "WATCHDOG" "Watchdog" ON "THERMAL" "Thermal" ON "BACKUP" "Backup" ON \
          "HACS" "HACS" ON "HOSTNAME" "Set hostname" ON "MONITOR" "Prometheus" OFF \
          "USBDETECT" "USB scan" ON "BOOTRECOV" "Boot recovery" ON \
          "STATICIP" "Static IP" OFF "TELEGRAM" "Telegram" OFF \
          "REVPROXY" "Reverse Proxy" OFF "RBACKUP" "Remote backup" OFF \
          3>&1 1>&2 2>&3) || { echo "Cancelled."; exit 0; }

        OPT_ZRAM=false; OPT_EMMC_TUNING=false; OPT_USB_POWER=false; OPT_UFW=false
        OPT_SSH_HARDENING=false; OPT_AUTOUPDATE=false; OPT_WATCHDOG=false; OPT_THERMAL=false
        OPT_BACKUP=false; OPT_HACS=false; OPT_HOSTNAME=false; OPT_STATIC_IP=false
        OPT_TELEGRAM=false; OPT_MONITORING=false; OPT_REVERSE_PROXY=false
        OPT_REMOTE_BACKUP=false; OPT_BOOT_RECOVERY=false; OPT_USB_DETECT=false

        [[ $ch == *ZRAM* ]]      && OPT_ZRAM=true
        [[ $ch == *EMMC* ]]      && OPT_EMMC_TUNING=true
        [[ $ch == *USBPOWER* ]]  && OPT_USB_POWER=true
        [[ $ch == *UFW* ]]       && OPT_UFW=true
        [[ $ch == *SSHHARD* ]]   && OPT_SSH_HARDENING=true
        [[ $ch == *AUTOUPD* ]]   && OPT_AUTOUPDATE=true
        [[ $ch == *WATCHDOG* ]]  && OPT_WATCHDOG=true
        [[ $ch == *THERMAL* ]]   && OPT_THERMAL=true
        [[ $ch == *BACKUP* ]]    && OPT_BACKUP=true
        [[ $ch == *HACS* ]]      && OPT_HACS=true
        [[ $ch == *HOSTNAME* ]]  && OPT_HOSTNAME=true
        [[ $ch == *STATICIP* ]]  && OPT_STATIC_IP=true
        [[ $ch == *TELEGRAM* ]]  && OPT_TELEGRAM=true
        [[ $ch == *MONITOR* ]]   && OPT_MONITORING=true
        [[ $ch == *REVPROXY* ]]  && OPT_REVERSE_PROXY=true
        [[ $ch == *RBACKUP* ]]   && OPT_REMOTE_BACKUP=true
        [[ $ch == *BOOTRECOV* ]] && OPT_BOOT_RECOVERY=true
        [[ $ch == *USBDETECT* ]] && OPT_USB_DETECT=true
      else
        echo -e "\n   ${BOLD}Components (y/n):${NC}" >&2
        text_yesno "ZRAM swap" "y"     && OPT_ZRAM=true     || OPT_ZRAM=false
        text_yesno "eMMC tuning" "y"   && OPT_EMMC_TUNING=true || OPT_EMMC_TUNING=false
        text_yesno "Firewall" "y"      && OPT_UFW=true      || OPT_UFW=false
        text_yesno "SSH hardening" "y" && OPT_SSH_HARDENING=true || OPT_SSH_HARDENING=false
        text_yesno "Watchdog" "y"      && OPT_WATCHDOG=true  || OPT_WATCHDOG=false
        text_yesno "Backup" "y"        && OPT_BACKUP=true    || OPT_BACKUP=false
        text_yesno "HACS" "y"          && OPT_HACS=true      || OPT_HACS=false
        text_yesno "Set hostname" "y"  && OPT_HOSTNAME=true  || OPT_HOSTNAME=false
        text_yesno "Monitoring" "n"    && OPT_MONITORING=true || OPT_MONITORING=false
        text_yesno "Static IP" "n"     && OPT_STATIC_IP=true || OPT_STATIC_IP=false
        text_yesno "Telegram" "n"      && OPT_TELEGRAM=true  || OPT_TELEGRAM=false
      fi
      PROFILE="custom"
    fi
  fi

  # --- Quick mode: timezone + confirm ---
  if [ "$wizard_mode" = "quick" ]; then
    if [ -z "$OPT_TIMEZONE" ]; then
      local curtz; curtz=$(timedatectl 2>/dev/null | awk '/Time zone/{print $3}') || curtz="UTC"
      if [ "$HAS_WHIPTAIL" = true ]; then
        OPT_TIMEZONE=$(whiptail --title "Timezone" --inputbox "Timezone:" 10 50 "$curtz" 3>&1 1>&2 2>&3) || OPT_TIMEZONE="$curtz"
      else
        OPT_TIMEZONE=$(text_input "Timezone" "$curtz")
      fi
    fi
    local qs="Quick Install:\n  Profile: ${PROFILE}\n  Timezone: ${OPT_TIMEZONE}\n\nProceed?"
    if [ "$HAS_WHIPTAIL" = true ]; then
      whiptail --title "Confirm" --yesno "$qs" 12 50 || { echo "Cancelled."; exit 0; }
    else
      echo -e "\n$qs" >&2; text_yesno "Proceed?" "y" || { echo "Cancelled."; exit 0; }
    fi
    return 0
  fi

  # === ADVANCED/EXPERT OPTIONS (skip each if already set via CLI) ===

  # Timezone
  if [ -z "$OPT_TIMEZONE" ]; then
    local curtz; curtz=$(timedatectl 2>/dev/null | awk '/Time zone/{print $3}') || curtz="UTC"
    if [ "$HAS_WHIPTAIL" = true ]; then
      OPT_TIMEZONE=$(whiptail --title "Timezone" --inputbox "e.g. Europe/Moscow\nCurrent: ${curtz}" 12 60 "$curtz" 3>&1 1>&2 2>&3) || OPT_TIMEZONE="$curtz"
    else
      OPT_TIMEZONE=$(text_input "Timezone (current: ${curtz})" "$curtz")
    fi
  fi

  # Locale (expert only)
  if [ -z "$OPT_LOCALE" ] && [ "$wizard_mode" = "expert" ]; then
    local curloc; curloc=$(locale 2>/dev/null | awk -F= '/^LANG=/{print $2}') || curloc="C.UTF-8"
    local set_locale=false
    if [ "$HAS_WHIPTAIL" = true ]; then
      whiptail --title "Locale" --yesno "Change locale?\nCurrent: ${curloc}" 10 50 --defaultno && set_locale=true
    else
      text_yesno "Change locale? (current: ${curloc})" "n" && set_locale=true
    fi
    if [ "$set_locale" = true ]; then
      if [ "$HAS_WHIPTAIL" = true ]; then
        OPT_LOCALE=$(whiptail --title "Locale" --inputbox "e.g. ru_RU.UTF-8:" 10 50 "$curloc" 3>&1 1>&2 2>&3) || OPT_LOCALE=""
      else
        OPT_LOCALE=$(text_input "Locale" "$curloc")
      fi
    fi
  fi

  # Swap
  if [ -z "$OPT_SWAP_SIZE" ]; then
    local swap_rec="zram"
    [ "$ram_mb" -lt 1500 ] && swap_rec="2048"
    [ "$ram_mb" -gt 4000 ] && swap_rec="none"
    if [ "$HAS_WHIPTAIL" = true ]; then
      OPT_SWAP_SIZE=$(whiptail --title "Swap" --menu "RAM: ${ram_mb}MB. Recommended: ${swap_rec}" 16 60 5 \
        "zram" "ZRAM in RAM (2-4GB)" "1024" "1GB file" "2048" "2GB file (low RAM)" \
        "4096" "4GB file" "none" "No swap (4GB+)" \
        3>&1 1>&2 2>&3) || OPT_SWAP_SIZE="$swap_rec"
    else
      OPT_SWAP_SIZE=$(text_menu "Swap (RAM: ${ram_mb}MB, rec: ${swap_rec})" "Choose:" \
        "zram" "ZRAM" "1024" "1GB" "2048" "2GB" "none" "None") || OPT_SWAP_SIZE="$swap_rec"
    fi
  fi

  # Data dir
  if [ -z "$OPT_DATA_DIR" ]; then
    local disk_warn=""
    [ "$disk_mb" -lt 20000 ] && disk_warn=" (WARNING: only ${disk_mb}MB free!)"
    local use_ext=false
    if [ "$HAS_WHIPTAIL" = true ]; then
      whiptail --title "External Storage" --yesno "Use external disk?${disk_warn}\n\nMoves Docker+HA to external drive." 12 60 --defaultno && use_ext=true
    else
      text_yesno "Use external disk?${disk_warn}" "n" && use_ext=true
    fi
    if [ "$use_ext" = true ]; then
      local mounts_info
      mounts_info=$(lsblk -o NAME,SIZE,MOUNTPOINT,FSTYPE 2>/dev/null | grep -E "sd|nvme" | head -10)
      if [ "$HAS_WHIPTAIL" = true ]; then
        OPT_DATA_DIR=$(whiptail --title "Data Dir" --inputbox "Mount path:\n\n${mounts_info}" 18 70 "/mnt/data" 3>&1 1>&2 2>&3) || OPT_DATA_DIR=""
      else
        [ -n "$mounts_info" ] && { echo -e "\n   Detected disks:" >&2; echo "$mounts_info" | while IFS= read -r l; do echo "   $l" >&2; done; }
        OPT_DATA_DIR=$(text_input "Data dir path" "/mnt/data")
      fi
    fi
  fi

  # WiFi
  if [ -z "$OPT_WIFI_SSID" ]; then
    local has_wifi=false
    { iw dev 2>/dev/null | grep -q Interface || ip link 2>/dev/null | grep -q wlan; } && has_wifi=true
    if [ "$has_wifi" = true ]; then
      local setup_wifi_now=false
      if [ "$HAS_WHIPTAIL" = true ]; then
        whiptail --title "WiFi" --yesno "WiFi adapter found. Configure?" 8 50 --defaultno && setup_wifi_now=true
      else
        text_yesno "WiFi found. Configure?" "n" && setup_wifi_now=true
      fi
      if [ "$setup_wifi_now" = true ]; then
        local wifi_list
        wifi_list=$(nmcli -t -f SSID dev wifi list 2>/dev/null | sort -u | head -10 | tr '\n' ', ') || wifi_list=""
        if [ "$HAS_WHIPTAIL" = true ]; then
          OPT_WIFI_SSID=$(whiptail --title "WiFi SSID" --inputbox "SSID:\n\nNearby: ${wifi_list}" 14 60 3>&1 1>&2 2>&3) || OPT_WIFI_SSID=""
          [ -n "$OPT_WIFI_SSID" ] && {
            OPT_WIFI_PASS=$(whiptail --title "WiFi Password" --passwordbox "Password:" 10 50 3>&1 1>&2 2>&3) || OPT_WIFI_SSID=""
          }
        else
          [ -n "$wifi_list" ] && echo -e "   Nearby: ${wifi_list}" >&2
          OPT_WIFI_SSID=$(text_input "SSID" "")
          [ -n "$OPT_WIFI_SSID" ] && OPT_WIFI_PASS=$(text_password "WiFi password")
        fi
      fi
    fi
  fi

  # Docker mirror (expert only)
  if [ -z "$OPT_DOCKER_MIRROR" ] && [ "$wizard_mode" = "expert" ]; then
    local use_mirror=false
    if [ "$HAS_WHIPTAIL" = true ]; then
      whiptail --title "Docker Mirror" --yesno "Use Docker mirror?\n(Only if Docker Hub blocked)" 10 60 --defaultno && use_mirror=true
    else
      text_yesno "Docker mirror? (only if blocked)" "n" && use_mirror=true
    fi
    if [ "$use_mirror" = true ]; then
      if [ "$HAS_WHIPTAIL" = true ]; then
        OPT_DOCKER_MIRROR=$(whiptail --title "Mirror URL" --inputbox "URL:" 10 65 3>&1 1>&2 2>&3) || OPT_DOCKER_MIRROR=""
      else
        OPT_DOCKER_MIRROR=$(text_input "Docker mirror URL" "")
      fi
    fi
  fi

  # Notifications
  if [ "$OPT_TELEGRAM" != true ] && [ -z "$OPT_WEBHOOK_URL" ]; then
    local notif=""
    if [ "$HAS_WHIPTAIL" = true ]; then
      notif=$(whiptail --title "Notifications" --menu "Alert method:" 16 60 5 \
        "none" "No notifications" "telegram" "Telegram" "ntfy" "ntfy.sh (free)" \
        "discord" "Discord" "custom" "Custom webhook" \
        3>&1 1>&2 2>&3) || notif="none"
    else
      notif=$(text_menu "Notifications" "Alert method:" \
        "none" "No alerts" "telegram" "Telegram" "ntfy" "ntfy.sh" \
        "discord" "Discord" "custom" "Custom URL") || notif="none"
    fi
    case "$notif" in
      telegram)
        OPT_TELEGRAM=true
        if [ "$HAS_WHIPTAIL" = true ]; then
          TG_TOKEN=$(whiptail --title "Telegram" --inputbox "Bot token:" 10 60 3>&1 1>&2 2>&3) || TG_TOKEN=""
          TG_CHAT=$(whiptail --title "Telegram" --inputbox "Chat ID:" 10 60 3>&1 1>&2 2>&3) || TG_CHAT=""
        else
          TG_TOKEN=$(text_input "Bot token" "")
          TG_CHAT=$(text_input "Chat ID" "")
        fi
        { [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; } && OPT_TELEGRAM=false
        ;;
      ntfy)
        local topic
        if [ "$HAS_WHIPTAIL" = true ]; then
          topic=$(whiptail --title "ntfy.sh" --inputbox "Topic:" 10 50 "ha-$(hostname 2>/dev/null || echo box)" 3>&1 1>&2 2>&3) || topic=""
        else
          topic=$(text_input "ntfy.sh topic" "ha-$(hostname 2>/dev/null || echo box)")
        fi
        [ -n "$topic" ] && OPT_WEBHOOK_URL="https://ntfy.sh/${topic}"
        ;;
      discord|custom)
        if [ "$HAS_WHIPTAIL" = true ]; then
          OPT_WEBHOOK_URL=$(whiptail --title "Webhook URL" --inputbox "URL:" 10 70 3>&1 1>&2 2>&3) || OPT_WEBHOOK_URL=""
        else
          OPT_WEBHOOK_URL=$(text_input "Webhook URL" "")
        fi
        ;;
    esac
  fi

  # Restore backup
  if [ -z "$OPT_RESTORE_BACKUP" ]; then
    local do_restore=false
    if [ "$HAS_WHIPTAIL" = true ]; then
      whiptail --title "Restore" --yesno "Restore backup after install?" 8 50 --defaultno && do_restore=true
    else
      text_yesno "Restore backup after install?" "n" && do_restore=true
    fi
    if [ "$do_restore" = true ]; then
      local found=""
      for d in /mnt /media /tmp /var/backups; do
        local fb
        fb=$(find "$d" -maxdepth 3 -name "ha_config_*.tar.gz" -type f 2>/dev/null | head -3)
        [ -n "$fb" ] && found="${found}${fb}"$'\n'
      done
      if [ "$HAS_WHIPTAIL" = true ]; then
        local hint=""
        [ -n "$found" ] && hint="\nFound:\n${found}"
        OPT_RESTORE_BACKUP=$(whiptail --title "Backup File" --inputbox "Path to .tar.gz:${hint}" 16 70 3>&1 1>&2 2>&3) || OPT_RESTORE_BACKUP=""
      else
        [ -n "$found" ] && { echo -e "   Found backups:" >&2; echo "$found" | while IFS= read -r l; do [ -n "$l" ] && echo "   $l" >&2; done; }
        OPT_RESTORE_BACKUP=$(text_input "Backup path (.tar.gz)" "")
      fi
      [ -n "$OPT_RESTORE_BACKUP" ] && [ ! -f "$OPT_RESTORE_BACKUP" ] && {
        msg_warn "File not found: ${OPT_RESTORE_BACKUP}"
        OPT_RESTORE_BACKUP=""
      }
    fi
  fi

  # Static IP details
  if [ "$OPT_STATIC_IP" = true ] && [ -z "$STATIC_IP" ]; then
    local cip2; cip2=$(hostname -I 2>/dev/null | awk '{print $1}') || cip2=""
    local cgw2; cgw2=$(ip route 2>/dev/null | awk '/default/{print $3}' | head -1) || cgw2=""
    while true; do
      if [ "$HAS_WHIPTAIL" = true ]; then
        STATIC_IP=$(whiptail --title "Static IP" --inputbox "IP:" 10 50 "$cip2" 3>&1 1>&2 2>&3) || { OPT_STATIC_IP=false; break; }
      else
        STATIC_IP=$(text_input "Static IP" "$cip2"); [ -z "$STATIC_IP" ] && { OPT_STATIC_IP=false; break; }
      fi
      validate_ip "$STATIC_IP" && break; msg_warn "Invalid IP"
    done
    if [ "$OPT_STATIC_IP" = true ]; then
      while true; do
        if [ "$HAS_WHIPTAIL" = true ]; then
          STATIC_GW=$(whiptail --title "Gateway" --inputbox "GW:" 10 50 "$cgw2" 3>&1 1>&2 2>&3) || { STATIC_GW="$cgw2"; break; }
        else
          STATIC_GW=$(text_input "Gateway" "$cgw2")
        fi
        validate_gw "$STATIC_GW" && break; msg_warn "Invalid GW"
      done
      while true; do
        if [ "$HAS_WHIPTAIL" = true ]; then
          STATIC_DNS=$(whiptail --title "DNS" --inputbox "DNS:" 10 50 "8.8.8.8,1.1.1.1" 3>&1 1>&2 2>&3) || { STATIC_DNS="8.8.8.8,1.1.1.1"; break; }
        else
          STATIC_DNS=$(text_input "DNS (comma sep)" "8.8.8.8,1.1.1.1")
        fi
        validate_dns_list "$STATIC_DNS" && break; msg_warn "Invalid DNS"
      done
    fi
  fi

  # Reverse proxy
  [ "$OPT_REVERSE_PROXY" = true ] && [ -z "$PROXY_DOMAIN" ] && {
    if [ "$HAS_WHIPTAIL" = true ]; then
      PROXY_DOMAIN=$(whiptail --title "Proxy" --inputbox "Domain:" 10 60 3>&1 1>&2 2>&3) || OPT_REVERSE_PROXY=false
    else
      PROXY_DOMAIN=$(text_input "Proxy domain" ""); [ -z "$PROXY_DOMAIN" ] && OPT_REVERSE_PROXY=false
    fi
  }

  # Remote backup
  [ "$OPT_REMOTE_BACKUP" = true ] && [ -z "$REMOTE_BACKUP_TARGET" ] && {
    if [ "$HAS_WHIPTAIL" = true ]; then
      REMOTE_BACKUP_TARGET=$(whiptail --title "Remote Backup" --inputbox "ssh://...:" 10 70 3>&1 1>&2 2>&3) || OPT_REMOTE_BACKUP=false
    else
      REMOTE_BACKUP_TARGET=$(text_input "Remote backup (ssh://...)" ""); [ -z "$REMOTE_BACKUP_TARGET" ] && OPT_REMOTE_BACKUP=false
    fi
  }

  # Auto-reboot
  if [ "$OPT_AUTO_REBOOT" != true ]; then
    if [ "$HAS_WHIPTAIL" = true ]; then
      whiptail --title "Auto-Reboot" --yesno "Allow auto-reboot if needed?\n(AppArmor may require it)" 10 55 && OPT_AUTO_REBOOT=true
    else
      text_yesno "Allow auto-reboot if needed?" "y" && OPT_AUTO_REBOOT=true
    fi
  fi

  # === CONFIRMATION ===
  local s="Install Home Assistant Supervised\n\n"
  s+="  Profile:  ${PROFILE}\n"
  s+="  Timezone: ${OPT_TIMEZONE:-auto}\n"
  s+="  Swap:     ${OPT_SWAP_SIZE:-zram}\n"
  [ -n "$OPT_DATA_DIR" ]         && s+="  Data dir: ${OPT_DATA_DIR}\n"
  [ -n "$OPT_WIFI_SSID" ]        && s+="  WiFi:     ${OPT_WIFI_SSID}\n"
  [ -n "$OPT_DOCKER_MIRROR" ]    && s+="  Mirror:   yes\n"
  [ -n "$OPT_RESTORE_BACKUP" ]   && s+="  Restore:  $(basename "$OPT_RESTORE_BACKUP")\n"
  [ -n "$OPT_LOCALE" ]           && s+="  Locale:   ${OPT_LOCALE}\n"
  [ "$OPT_AUTO_REBOOT" = true ]  && s+="  Reboot:   auto\n"
  [ "$OPT_TELEGRAM" = true ]     && s+="  Telegram: yes\n"
  [ -n "$OPT_WEBHOOK_URL" ]      && s+="  Webhook:  yes\n"
  [ "$OPT_STATIC_IP" = true ]    && s+="  IP:       ${STATIC_IP}\n"
  s+="\nProceed?"

  if [ "$HAS_WHIPTAIL" = true ]; then
    whiptail --title "Confirm" --yesno "$s" 28 60 || { echo "Cancelled."; exit 0; }
  else
    echo -e "\n$s" >&2
    text_yesno "Proceed?" "y" || { echo "Cancelled."; exit 0; }
  fi
}

# ============================================================================
# MAIN MENU (no-args interactive)
# ============================================================================
show_main_menu() {
  [ ! -t 0 ] && return 1
  local choice
  if command -v whiptail &>/dev/null; then
    choice=$(whiptail --title "HA Installer v${SCRIPT_VERSION}" --menu "Action:" 22 60 14 \
      "install"   "Install HA Supervised" \
      "check"     "Diagnostics" \
      "status"    "Live monitoring" \
      "update"    "Update HA + OS-Agent" \
      "backup"    "Create backup" \
      "restore"   "Restore backup" \
      "health"    "Health report" \
      "benchmark" "Hardware benchmark" \
      "export"    "Export config" \
      "history"   "Run history" \
      "uninstall" "Uninstall HA" \
      "selftest"  "Self-test" \
      "help"      "Help" \
      3>&1 1>&2 2>&3) || exit 0
  else
    choice=$(text_menu "HA Installer v${SCRIPT_VERSION}" "Action:" \
      "install"   "Install HA" \
      "check"     "Diagnostics" \
      "status"    "Live monitor" \
      "update"    "Update HA" \
      "backup"    "Create backup" \
      "restore"   "Restore backup" \
      "health"    "Health report" \
      "benchmark" "Benchmark" \
      "export"    "Export config" \
      "history"   "History" \
      "uninstall" "Uninstall" \
      "selftest"  "Self-test" \
      "help"      "Help") || exit 0
  fi

  case "$choice" in
    install)   RUN_WIZARD=true;;
    check)     CHECK_ONLY=true; RUN_WIZARD=false;;
    status)    SHOW_STATUS=true; RUN_WIZARD=false;;
    update)    DO_UPDATE=true; RUN_WIZARD=false;;
    backup)
      if [ -x /usr/local/bin/ha-backup ]; then /usr/local/bin/ha-backup; exit $?
      else msg_error "ha-backup not installed"; exit 1; fi;;
    restore)
      if [ -x /usr/local/bin/ha-restore ]; then /usr/local/bin/ha-restore; exit $?
      else msg_error "ha-restore not installed"; exit 1; fi;;
    health)
      if [ -x /usr/local/bin/ha-health ]; then /usr/local/bin/ha-health; exit $?
      else msg_error "ha-health not installed"; exit 1; fi;;
    benchmark) DO_BENCHMARK=true; RUN_WIZARD=false;;
    export)    DO_EXPORT_CONFIG=true; RUN_WIZARD=false;;
    history)   DO_SHOW_HISTORY=true; RUN_WIZARD=false;;
    uninstall) UNINSTALL=true; RUN_WIZARD=false;;
    selftest)  DO_SELF_TEST=true; RUN_WIZARD=false;;
    help)      show_help; exit 0;;
  esac
}

# ============================================================================
# STEP: PREFLIGHT
# ============================================================================
step_preflight() {
  local sid="preflight"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] PREFLIGHT CHECK"
  detect_system_info; local err=0 wrn=0

  [ "$CACHED_ARCH" = "unknown" ] && { msg_error "Arch: ${CACHED_MACHINE_ARCH}"; err=$((err+1)); } \
    || msg_ok "Arch: ${CACHED_MACHINE_ARCH} (${CACHED_ARCH})"
  msg_info "OS: ${CACHED_PRETTY_NAME:-${CACHED_CODENAME:-?}}"
  is_armbian && msg_info "Armbian detected"
  is_trixie && msg_info "Debian 13 Trixie"
  os_release_needs_faking && msg_warn "os-release will be faked" || msg_ok "os-release OK"

  check_filesystem || err=$((err+1))
  check_broken_state

  is_armbian && is_pkg_installed armbian-zram-config && [ "$OPT_ZRAM" = true ] && \
    { msg_warn "armbian-zram-config conflict"; wrn=$((wrn+1)); }

  require_disk_space 4000 "Installation" || err=$((err+1))

  local rm_val; rm_val=$(free -m | awk '/Mem:/{print $2}')
  [ "$rm_val" -lt 900 ] && { msg_error "RAM: ${rm_val}MB (need 1GB+)"; err=$((err+1)); } || msg_ok "RAM: ${rm_val}MB"

  local kv; kv=$(uname -r | cut -d. -f1)
  [ "$kv" -lt 4 ] && { msg_error "Kernel $(uname -r)"; err=$((err+1)); } || msg_ok "Kernel: $(uname -r)"

  if [ -f /sys/fs/cgroup/cgroup.controllers ]; then msg_ok "cgroups: v2"
  elif [ -d /sys/fs/cgroup/unified ]; then msg_ok "cgroups: hybrid"
  else msg_warn "cgroups: v1"; wrn=$((wrn+1)); fi

  check_internet || err=$((err+1))

  ss -tlnp 2>/dev/null | grep -q ':8123 ' && { msg_warn "Port 8123 busy"; wrn=$((wrn+1)); } || msg_ok "Port 8123 free"

  local t; t=$(get_cpu_temp)
  [ -n "$t" ] && { [ "$t" -ge 75 ] && { msg_warn "CPU: ${t}C!"; wrn=$((wrn+1)); } || msg_ok "CPU: ${t}C"; }

  # Validate data-dir
  if [ -n "$OPT_DATA_DIR" ]; then
    if [ ! -d "$OPT_DATA_DIR" ]; then
      msg_error "Data dir missing: ${OPT_DATA_DIR}"; err=$((err+1))
    else
      local fstype; fstype=$(df -T "$OPT_DATA_DIR" 2>/dev/null | awk 'NR==2{print $2}')
      case "$fstype" in
        vfat|ntfs|exfat|fat32) msg_error "Bad FS for data: ${fstype}"; err=$((err+1)) ;;
        ext4|btrfs|xfs) msg_ok "Data dir FS: ${fstype}" ;;
        *) msg_warn "Data dir FS: ${fstype}" ;;
      esac
      local dfree; dfree=$(df -m "$OPT_DATA_DIR" | awk 'NR==2{print $4}')
      [ "$dfree" -lt 10000 ] && { msg_warn "Data dir: only ${dfree}MB free"; wrn=$((wrn+1)); }
    fi
  fi

  # Check Docker version if already installed
  if command -v docker &>/dev/null; then
    local dver; dver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "")
    if [ -n "$dver" ]; then
      local dmaj; dmaj=$(echo "$dver" | cut -d. -f1)
      [ "$dmaj" -lt 20 ] && { msg_warn "Docker ${dver} old (20+ recommended)"; wrn=$((wrn+1)); } || msg_ok "Docker: ${dver}"
    fi
  fi

  # Test notifications
  if [ -n "$TG_TOKEN" ] || [ -n "$OPT_WEBHOOK_URL" ]; then
    test_notifications || wrn=$((wrn+1))
  fi

  # Validate restore file
  [ -n "$OPT_RESTORE_BACKUP" ] && [ ! -f "$OPT_RESTORE_BACKUP" ] && { msg_error "Backup not found: ${OPT_RESTORE_BACKUP}"; err=$((err+1)); }

  estimate_install_time
  separator
  [ $err -gt 0 ] && { msg_error "Critical errors: ${err}"; return 1; }
  [ $wrn -gt 0 ] && msg_warn "Warnings: ${wrn}" || msg_ok "All checks passed"
  mark_done "$sid"
}

# ============================================================================
# STEP: UPDATE
# ============================================================================
step_update_system() {
  local sid="update"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] SYSTEM UPDATE"
  setup_timezone
  setup_locale
  setup_wifi
  if [ "$SKIP_UPDATE" = false ]; then
    run_cmd_fatal "apt update" apt_safe update -y
    run_cmd "apt upgrade" apt_safe upgrade -y -o Dpkg::Options::="--force-confold"
  else
    msg_warn "Skipped (--skip-update)"
  fi
  mark_done "$sid"
}

# ============================================================================
# STEP: DEPENDENCIES
# ============================================================================
step_install_deps() {
  local sid="deps"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] DEPENDENCIES"
  detect_system_info

  local pkgs=(apparmor avahi-daemon bluez ca-certificates cifs-utils curl dbus gnupg jq
    libglib2.0-bin network-manager nfs-common systemd-timesyncd udisks2 usbutils wget qrencode)

  for p in lsb-release systemd-resolved systemd-journal-remote; do
    pkg_available "$p" && pkgs+=("$p")
  done

  if [ "$OPT_ZRAM" = true ]; then
    if is_armbian && is_pkg_installed armbian-zram-config; then true
    elif pkg_available zram-tools; then pkgs+=(zram-tools)
    elif pkg_available systemd-zram-generator; then pkgs+=(systemd-zram-generator)
    fi
  fi

  [ "$OPT_UFW" = true ]           && pkgs+=(ufw fail2ban)
  [ "$OPT_AUTOUPDATE" = true ]    && pkgs+=(unattended-upgrades)
  [ "$OPT_BACKUP" = true ]        && pkg_available pigz && pkgs+=(pigz)
  [ "$OPT_REVERSE_PROXY" = true ] && pkgs+=(nginx certbot python3-certbot-nginx)

  is_armbian && systemctl is-active --quiet armbian-hardware-optimization 2>/dev/null || {
    for p in linux-cpupower cpufrequtils; do pkg_available "$p" && pkgs+=("$p"); done
  }

  local ti=()
  for p in "${pkgs[@]}"; do is_pkg_installed "$p" || ti+=("$p"); done

  if [ ${#ti[@]} -eq 0 ]; then
    msg_ok "All installed"
  else
    apt_wait_lock || { msg_error "apt locked"; return 1; }
    local total=${#ti[@]} f=()
    msg_action "Installing ${total} packages..."
    if apt_safe install -y "${ti[@]}" &>/dev/null; then
      msg_ok "Installed: ${total}"
    else
      msg_warn "Batch failed, one by one..."
      local i=0
      for p in "${ti[@]}"; do
        i=$((i+1)); progress_bar $i $total "$p"
        apt_safe install -y "$p" &>/dev/null || f+=("$p")
      done
      progress_clear
      [ ${#f[@]} -gt 0 ] && msg_warn "Failed: ${f[*]}" || msg_ok "Installed: ${total}"
    fi
  fi

  run_cmd "apt fix" apt_safe -f install -y
  [ "$OPT_EMMC_TUNING" = true ] && apt-get clean 2>/dev/null || true
  setup_swap
  mark_done "$sid"
}

# ============================================================================
# STEP: NETWORK
# ============================================================================
step_configure_network() {
  local sid="network"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] NETWORK"

  mkdir -p "$BACKUP_DIR" /etc/NetworkManager/conf.d
  push_rollback 'rollback_network'

  local cip; cip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$cip" ] && msg_info "Current IP: ${cip}"

  printf '[keyfile]\nunmanaged-devices=none\n[device]\nwifi.scan-rand-mac-address=no\n' \
    > /etc/NetworkManager/conf.d/10-ha-managed.conf
  printf '[main]\ndns=systemd-resolved\n' \
    > /etc/NetworkManager/conf.d/10-dns-resolved.conf

  [ -f /etc/network/interfaces ] && cp /etc/network/interfaces "$BACKUP_DIR/interfaces.bak" 2>/dev/null
  printf 'source /etc/network/interfaces.d/*\nauto lo\niface lo inet loopback\n' > /etc/network/interfaces

  systemctl is-active --quiet systemd-resolved 2>/dev/null || {
    systemctl enable systemd-resolved 2>/dev/null || true
    systemctl start systemd-resolved 2>/dev/null || true
  }

  local rt; rt=$(readlink -f /etc/resolv.conf 2>/dev/null)
  [[ "$rt" != */run/systemd/resolve/* ]] && {
    cp /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.bak" 2>/dev/null
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null
  }

  if who 2>/dev/null | grep -q pts; then
    msg_warn "SSH session! Network switch in 15s..."
    sleep 15
  fi

  systemctl list-unit-files networking.service &>/dev/null && \
    systemctl is-active --quiet networking 2>/dev/null && \
    systemctl disable networking 2>/dev/null || true
  systemctl enable NetworkManager 2>/dev/null || true
  systemctl restart NetworkManager 2>/dev/null || true

  if [ "$OPT_STATIC_IP" = true ] && [ -n "$STATIC_IP" ]; then
    sleep 3
    local ac; ac=$(nmcli -t -f NAME con show --active 2>/dev/null | head -1)
    [ -n "$ac" ] && {
      local pf; pf=$(get_current_prefix); [ -z "$pf" ] && pf="24"
      nmcli con mod "$ac" ipv4.addresses "${STATIC_IP}/${pf}" \
        ipv4.gateway "$STATIC_GW" ipv4.dns "$STATIC_DNS" ipv4.method manual 2>/dev/null
      nmcli con up "$ac" 2>/dev/null
      msg_ok "Static IP: ${STATIC_IP}/${pf}"
    }
  fi

  local r=0 ni=""
  while [ $r -lt 6 ]; do
    sleep 5
    ni=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -n "$ni" ] && { msg_ok "Network: ${ni}"; break; }
    r=$((r+1))
  done

  if [ $r -ge 6 ]; then
    rollback_network; sleep 5
    ni=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -n "$ni" ] && msg_ok "Recovered: ${ni}" || { msg_error "No network!"; return 1; }
  fi

  mark_done "$sid"
}

# ============================================================================
# STEP: APPARMOR
# ============================================================================
step_configure_apparmor() {
  local sid="apparmor"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] APPARMOR"

  local aa; aa=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) || aa="N"

  if [ "$aa" = "Y" ]; then
    msg_ok "AppArmor active"
  else
    local patched=false
    for f in /boot/armbianEnv.txt /boot/uEnv.txt /boot/extlinux/extlinux.conf; do
      [ -f "$f" ] || continue
      cp "$f" "${BACKUP_DIR}/$(basename "$f").bak" 2>/dev/null
      grep -q "apparmor=1" "$f" && { patched=true; continue; }
      if [[ "$f" == *extlinux.conf ]]; then
        sed -i '/^[[:space:]]*append/ s/$/ apparmor=1 security=apparmor/' "$f"
      else
        grep -q "^extraargs=" "$f" && \
          sed -i 's|^extraargs=.*|& apparmor=1 security=apparmor|' "$f" || \
          echo "extraargs=apparmor=1 security=apparmor" >> "$f"
      fi
      msg_ok "$(basename "$f")"
      patched=true
    done

    if [ "$patched" = true ]; then
      msg_warn "AppArmor needs reboot"
      if [ "$OPT_AUTO_REBOOT" = true ]; then
        msg_action "Auto-reboot in 10s..."
        if setup_reboot_continue; then
          sleep 10
          reboot
          exit 0
        else
          msg_warn "Reboot setup failed, continuing without reboot"
        fi
      fi
    else
      msg_error "No bootloader config found"
    fi
  fi

  systemctl enable apparmor 2>/dev/null || true
  systemctl start apparmor 2>/dev/null || true
  mark_done "$sid"
}

# ============================================================================
# STEP: PERFORMANCE
# ============================================================================
step_performance() {
  local sid="perf"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] PERFORMANCE"

  # ZRAM
  if [ "$OPT_ZRAM" = true ]; then
    [ -f /swapfile ] && [ "$OPT_SWAP_SIZE" != "none" ] && {
      swapoff /swapfile 2>/dev/null; rm -f /swapfile; sed -i '/swapfile/d' /etc/fstab
    }

    if is_armbian && is_pkg_installed armbian-zram-config; then
      msg_ok "ZRAM: Armbian managed"
    elif is_pkg_installed zram-tools; then
      printf 'ALGO=lz4\nPERCENT=60\n' > /etc/default/zramswap
      systemctl enable zramswap 2>/dev/null || true
      systemctl restart zramswap 2>/dev/null || true
      msg_ok "ZRAM"
    elif is_pkg_installed systemd-zram-generator; then
      mkdir -p /etc/systemd/zram-generator.conf.d
      printf '[zram0]\nzram-size = ram * 0.6\ncompression-algorithm = lz4\n' \
        > /etc/systemd/zram-generator.conf.d/ha.conf
      schedule_daemon_reload; flush_daemon_reload
      msg_ok "ZRAM"
    elif modprobe zram 2>/dev/null && [ -b /dev/zram0 ]; then
      local rb; rb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
      echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
      echo $((rb*1024*60/100)) > /sys/block/zram0/disksize 2>/dev/null || true
      mkswap /dev/zram0 >/dev/null 2>&1 && swapon -p 100 /dev/zram0 2>/dev/null
      msg_ok "ZRAM (manual)"
    else
      msg_warn "ZRAM not available"
    fi
  fi

  # CPU governor
  if is_armbian && systemctl is-active --quiet armbian-hardware-optimization 2>/dev/null; then
    msg_dim "CPU: Armbian managed"
  elif command -v cpupower &>/dev/null; then
    cpupower frequency-set -g schedutil 2>/dev/null || cpupower frequency-set -g ondemand 2>/dev/null || true
    msg_ok "CPU: schedutil"
  elif command -v cpufreq-set &>/dev/null; then
    echo 'GOVERNOR="schedutil"' > /etc/default/cpufrequtils
    msg_ok "CPU: schedutil"
  else
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      [ -f "$g" ] && { echo schedutil > "$g" 2>/dev/null || echo ondemand > "$g" 2>/dev/null; }
    done
  fi

  # eMMC tuning
  if [ "$OPT_EMMC_TUNING" = true ]; then
    echo "vm.swappiness=10" > /etc/sysctl.d/99-ha-swap.conf
    sysctl -p /etc/sysctl.d/99-ha-swap.conf >/dev/null 2>&1 || true

    grep -q noatime /etc/fstab 2>/dev/null || {
      cp /etc/fstab "${BACKUP_DIR}/fstab.bak" 2>/dev/null
      sed -i '/^\//s/defaults/defaults,noatime,commit=600/' /etc/fstab 2>/dev/null || true
    }

    mkdir -p /etc/systemd/journald.conf.d
    is_armbian && is_pkg_installed armbian-ramlog || {
      printf '[Journal]\nSystemMaxUse=50M\nSystemMaxFileSize=10M\nMaxRetentionSec=7day\nCompress=yes\nStorage=persistent\nSystemKeepFree=100M\n' \
        > /etc/systemd/journald.conf.d/ha-tuning.conf
      systemctl restart systemd-journald 2>/dev/null || true
    }

    local rd="" rs=""
    rs=$(findmnt -n -o SOURCE / 2>/dev/null)
    [ -n "$rs" ] && [ -b "$rs" ] && rd=$(lsblk -no PKNAME "$rs" 2>/dev/null | head -1)
    if [ -n "$rd" ] && [ "$(cat "/sys/block/${rd}/queue/rotational" 2>/dev/null)" = "0" ]; then
      [[ "$rd" == nvme* ]] && echo none > "/sys/block/${rd}/queue/scheduler" 2>/dev/null || true
      [[ "$rd" == mmcblk* || "$rd" == sd* ]] && echo mq-deadline > "/sys/block/${rd}/queue/scheduler" 2>/dev/null || true
    fi
    msg_ok "eMMC tuning"
  fi

  # USB power
  [ "$OPT_USB_POWER" = true ] && {
    for d in /sys/bus/usb/devices/*/power/autosuspend; do
      [ -f "$d" ] && echo -1 > "$d" 2>/dev/null
    done
    echo 'ACTION=="add", SUBSYSTEM=="usb", ATTR{power/autosuspend}="-1"' \
      > /etc/udev/rules.d/99-ha-usb-power.rules
    udevadm control --reload-rules 2>/dev/null || true
    msg_ok "USB power fix"
  }

  mark_done "$sid"
}

# ============================================================================
# STEP: DOCKER
# ============================================================================
step_install_docker() {
  local sid="docker"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] DOCKER"

  require_disk_space 2000 "Docker" || { msg_error "No space for Docker"; exit 1; }
  push_rollback 'apt-get remove -y docker-ce docker-ce-cli containerd.io 2>/dev/null; rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc'
  setup_docker_mirror

  if command -v docker &>/dev/null; then
    msg_ok "Docker: $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
    local drv; drv=$(docker info --format '{{.Driver}}' 2>/dev/null || echo "unknown")
    msg_info "Storage driver: ${drv}"
    [ "$drv" != "overlay2" ] && msg_warn "overlay2 recommended (got: ${drv})"
  else
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    detect_system_info
    local codename="${CACHED_CODENAME}"
    [[ "$codename" == "trixie" ]] && codename="bookworm"

    local docker_ok=false
    if command -v curl &>/dev/null; then
      spinner_start "Docker (official repo)"
      install -m 0755 -d /etc/apt/keyrings 2>/dev/null
      if curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc 2>/dev/null; then
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable" \
          > /etc/apt/sources.list.d/docker.list
        apt-get update -qq 2>/dev/null
        apt_safe install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin &>/dev/null && docker_ok=true
      fi
      spinner_stop
    fi

    if [ "$docker_ok" = false ]; then
      msg_warn "Official repo failed -> get.docker.com"
      spinner_start "Docker (get.docker.com)"
      curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || { spinner_stop; msg_error "Docker install failed!"; exit 1; }
      spinner_stop
    fi

    hash -r 2>/dev/null
    msg_ok "Docker installed"
    local drv; drv=$(docker info --format '{{.Driver}}' 2>/dev/null || echo "unknown")
    msg_info "Storage driver: ${drv}"
  fi

  mkdir -p /etc/docker
  [ ! -f /etc/docker/daemon.json ] && \
    echo '{"log-driver":"journald","storage-driver":"overlay2"}' > /etc/docker/daemon.json

  systemctl enable docker 2>/dev/null || true
  systemctl restart docker 2>/dev/null || true

  local dw=0
  while ! docker info &>/dev/null; do
    sleep 2; dw=$((dw+2))
    [ $dw -ge 30 ] && { msg_error "Docker failed to start!"; exit 1; }
  done

  setup_data_dir
  prefetch_docker_images
  mark_done "$sid"
}

# ============================================================================
# STEP: VERSIONS
# ============================================================================
step_resolve_versions() {
  local sid="versions"
  if is_done "$sid"; then
    load_config
    RESOLVED_OA_VER="${OA_VERSION:-}"
    RESOLVED_HA_VER="${HA_VERSION:-}"
    [ -n "$OVERRIDE_OS_AGENT_VER" ] && RESOLVED_OA_VER="$OVERRIDE_OS_AGENT_VER"
    [ -n "$OVERRIDE_HA_VER" ] && RESOLVED_HA_VER="$OVERRIDE_HA_VER"
    if [ -n "$RESOLVED_OA_VER" ] && [ -n "$RESOLVED_HA_VER" ]; then
      msg_ok "Versions: OA=${RESOLVED_OA_VER} HA=${RESOLVED_HA_VER}"
      return 0
    fi
  fi

  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] VERSIONS"

  if [ -n "$OVERRIDE_OS_AGENT_VER" ]; then
    RESOLVED_OA_VER="$OVERRIDE_OS_AGENT_VER"
  else
    msg_action "Resolving OS-Agent..."
    RESOLVED_OA_VER=$(get_latest_release "home-assistant/os-agent")
  fi
  [ -z "$RESOLVED_OA_VER" ] && { msg_error "OS-Agent version not found"; exit 1; }

  if [ -n "$OVERRIDE_HA_VER" ]; then
    RESOLVED_HA_VER="$OVERRIDE_HA_VER"
  else
    msg_action "Resolving HA..."
    RESOLVED_HA_VER=$(get_latest_release "home-assistant/supervised-installer")
  fi
  [ -z "$RESOLVED_HA_VER" ] && { msg_error "HA version not found"; exit 1; }

  msg_ok "OA: ${RESOLVED_OA_VER}  HA: ${RESOLVED_HA_VER}"
  mark_done "$sid"
}

# ============================================================================
# STEP: DOWNLOAD
# ============================================================================
step_download_packages() {
  local sid="download"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] DOWNLOAD"

  detect_system_info
  require_disk_space 500 "Download" || { msg_error "No space"; exit 1; }

  local tf; tf=$(df -m "$HA_TMP" 2>/dev/null | awk 'NR==2{print $4}')
  if [ "${tf:-0}" -lt 200 ]; then
    umount "$HA_TMP" 2>/dev/null || true
    HA_TMP="/var/tmp/ha-install"
    mkdir -p "$HA_TMP"
  fi

  download_file \
    "https://github.com/home-assistant/os-agent/releases/download/${RESOLVED_OA_VER}/os-agent_${RESOLVED_OA_VER}_linux_${CACHED_ARCH}.deb" \
    "${HA_TMP}/os-agent.deb" "OS-Agent" || { msg_error "OS-Agent download failed!"; exit 1; }
  verify_checksum "${HA_TMP}/os-agent.deb" "home-assistant/os-agent" "$RESOLVED_OA_VER"

  download_file \
    "https://github.com/home-assistant/supervised-installer/releases/download/${RESOLVED_HA_VER}/homeassistant-supervised.deb" \
    "${HA_TMP}/ha.deb" "HA Supervised" || { msg_error "HA download failed!"; exit 1; }
  verify_checksum "${HA_TMP}/ha.deb" "home-assistant/supervised-installer" "$RESOLVED_HA_VER"

  msg_ok "Downloaded + verified"
  mark_done "$sid"
}

# ============================================================================
# STEP: OS-AGENT
# ============================================================================
step_install_os_agent() {
  local sid="osagent"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] OS-AGENT"

  push_rollback 'dpkg --purge os-agent 2>/dev/null'
  run_cmd_fatal "OS-Agent" dpkg -i "${HA_TMP}/os-agent.deb"

  if command -v gdbus &>/dev/null; then
    gdbus introspect --system --dest io.hass.os --object-path /io/hass/os &>/dev/null \
      && msg_ok "D-Bus OK" || msg_warn "D-Bus available after reboot"
  fi

  mark_done "$sid"
}

# ============================================================================
# STEP: HA SUPERVISED
# ============================================================================
step_install_ha() {
  local sid="ha"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] HOME ASSISTANT SUPERVISED"

  require_disk_space 1500 "HA" || { msg_error "No space for HA"; exit 1; }
  mkdir -p "$BACKUP_DIR"
  push_rollback 'dpkg --purge homeassistant-supervised 2>/dev/null'

  if os_release_needs_faking; then
    msg_warn "Faking os-release"
    fake_os_release
  else
    msg_ok "os-release OK"
    backup_os_release
  fi

  wait_prefetch
  msg_action "Installing HA (5-15 min)..."
  msg_dim "Machine: ${HA_MACHINE}"
  export MACHINE="$HA_MACHINE"

  set +o pipefail
  DEBIAN_FRONTEND=noninteractive dpkg -i "${HA_TMP}/ha.deb" 2>&1 \
    | grep --line-buffered -iE "(pull|download|unpack|setting up|error|warn)" \
    | grep -vi "cgroup v1" \
    | while IFS= read -r l; do echo -e "   ${BLUE}|${NC} ${l}"; done
  local -a _ps=("${PIPESTATUS[@]}")
  local de=${_ps[0]}
  set -o pipefail

  [ $de -ne 0 ] && { msg_warn "dpkg exit ${de}"; apt-get install -f -y >/dev/null 2>&1 || true; }

  if [ "$OS_RELEASE_FAKED" = true ]; then
    mkdir -p /etc/systemd/system/hassio-supervisor.service.d
    cat > /etc/systemd/system/hassio-supervisor.service.d/fix-os-release.conf << DROPIN
[Service]
ExecStartPre=/bin/bash -c 'F="${BACKUP_DIR}/os-release.faked"; [ -f "\$F" ] && cp "\$F" /etc/os-release'
ExecStopPost=/bin/bash -c 'O="${BACKUP_DIR}/os-release.original"; [ -f "\$O" ] && cp "\$O" /etc/os-release'
DROPIN
    schedule_daemon_reload
    flush_daemon_reload
    restore_os_release
    msg_info "Drop-in: fake on start, restore on stop"
  fi

  msg_action "Waiting for supervisor..."
  local sw=0
  while ! systemctl is-active --quiet hassio-supervisor 2>/dev/null; do
    sleep 5; sw=$((sw+5))
    [ $sw -ge 120 ] && { msg_warn "Timeout waiting for supervisor"; break; }
    [ $((sw%15)) -eq 0 ] && msg_dim "${sw}s..."
  done
  [ $sw -lt 120 ] && msg_ok "hassio-supervisor active"

  touch "$GRACE_MARKER"
  save_config
  msg_ok "HA Supervised installed"
  mark_done "$sid"
}

# ============================================================================
# STEP: SECURITY
# ============================================================================
step_security() {
  local sid="sec"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] SECURITY"
  local any=false

  if [ "$OPT_UFW" = true ]; then
    any=true
    ufw status 2>/dev/null | grep -q "Status: active" || {
      ufw --force reset >/dev/null 2>&1
      ufw default deny incoming >/dev/null 2>&1
      ufw default allow outgoing >/dev/null 2>&1
      ufw default allow routed >/dev/null 2>&1
    }

    for r in "22/tcp SSH" "8123/tcp HA" "4357/tcp ESPHome" "5353/udp mDNS" "5683/udp HomeKit"; do
      local port="${r%% *}"
      ufw status 2>/dev/null | grep -q "$port" || ufw allow "$port" comment "${r#* }" >/dev/null 2>&1
    done
    [ "$OPT_REVERSE_PROXY" = true ] && {
      ufw status 2>/dev/null | grep -q "443/tcp" || ufw allow 443/tcp comment "HTTPS" >/dev/null 2>&1
    }
    ufw --force enable >/dev/null 2>&1
    msg_ok "UFW"

    if ! grep -q "# BEGIN HA-INSTALLER DOCKER-USER" /etc/ufw/after.rules 2>/dev/null; then
      local iok=true
      command -v iptables &>/dev/null && iptables --version 2>/dev/null | grep -q legacy && iok=false
      if $iok; then
        cat >> /etc/ufw/after.rules << 'U'
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
        ufw reload >/dev/null 2>&1
        msg_ok "DOCKER-USER rules"
      else
        msg_warn "DOCKER-USER skip (iptables-legacy)"
      fi
    fi

    if is_trixie || [ ! -f /var/log/auth.log ]; then
      printf '[sshd]\nenabled=true\nport=ssh\nfilter=sshd\nbackend=systemd\nmaxretry=5\nbantime=3600\nfindtime=600\n' \
        > /etc/fail2ban/jail.local
    else
      printf '[sshd]\nenabled=true\nport=ssh\nfilter=sshd\nlogpath=/var/log/auth.log\nbackend=auto\nmaxretry=5\nbantime=3600\nfindtime=600\n' \
        > /etc/fail2ban/jail.local
    fi
    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    msg_ok "Fail2Ban"
  fi

  if [ "$OPT_SSH_HARDENING" = true ]; then
    any=true
    mkdir -p /etc/ssh/sshd_config.d
    cp /etc/ssh/sshd_config "${BACKUP_DIR}/sshd_config.bak" 2>/dev/null
    printf 'PermitRootLogin prohibit-password\nMaxAuthTries 3\nClientAliveInterval 300\nClientAliveCountMax 2\nX11Forwarding no\n' \
      > /etc/ssh/sshd_config.d/99-ha-hardening.conf
    systemctl list-unit-files ssh.service &>/dev/null && systemctl reload ssh 2>/dev/null || \
      systemctl reload sshd 2>/dev/null || true
    msg_ok "SSH hardened"
  fi

  if [ "$OPT_AUTOUPDATE" = true ]; then
    any=true
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'U'
Unattended-Upgrade::Allowed-Origins { "${distro_id}:${distro_codename}-security"; };
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
U
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::AutocleanInterval "7";\n' \
      > /etc/apt/apt.conf.d/20auto-upgrades
    msg_ok "Auto-updates"
  fi

  $any || msg_warn "Skipped"
  mark_done "$sid"
}

# ============================================================================
# STEP: EXTRAS (utilities, cron, backup, monitoring, etc.)
# ============================================================================
step_extras() {
  local sid="extras"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] UTILITIES"

  [ "$OPT_HOSTNAME" = true ] && {
    hostnamectl set-hostname homeassistant 2>/dev/null || true
    msg_ok "Hostname: homeassistant"
  }

  systemctl enable avahi-daemon >/dev/null 2>&1 || true
  systemctl start avahi-daemon >/dev/null 2>&1 || true
  msg_ok "mDNS (avahi)"

  # --- ha-notify (restricted to root only) ---
  cat > /usr/local/bin/ha-notify << NTEOF
#!/bin/bash
MSG="\${1:-}"; [ -z "\$MSG" ] && exit 0
RF="/tmp/.ha_notify_rate"; NOW=\$(date +%s); LAST=\$(cat "\$RF" 2>/dev/null || echo 0)
[ \$((NOW - LAST)) -lt 30 ] && exit 0; echo "\$NOW" > "\$RF"
TG_TOKEN="${TG_TOKEN}"; TG_CHAT="${TG_CHAT}"; WEBHOOK="${OPT_WEBHOOK_URL}"
if [ -n "\$TG_TOKEN" ] && [ -n "\$TG_CHAT" ]; then
  curl -s -X POST "https://api.telegram.org/bot\$TG_TOKEN/sendMessage" \
    --data-urlencode "chat_id=\$TG_CHAT" --data-urlencode "text=HA (\$(hostname)): \$MSG" >/dev/null 2>&1
fi
if [ -n "\$WEBHOOK" ]; then
  curl -s -X POST "\$WEBHOOK" -H "Content-Type: application/json" \
    -d "{\"text\":\"HA (\$(hostname)): \$MSG\"}" >/dev/null 2>&1 || \
  curl -s -X POST "\$WEBHOOK" -d "HA (\$(hostname)): \$MSG" >/dev/null 2>&1 || true
fi
NTEOF
  chmod 700 /usr/local/bin/ha-notify

  # --- Watchdog with exponential backoff ---
  if [ "$OPT_WATCHDOG" = true ]; then
    cat > /usr/local/bin/ha-watchdog << 'S'
#!/bin/bash
GF="/tmp/.ha_just_installed"
[ -f "$GF" ] && { [ $(($(date +%s)-$(stat -c %Y "$GF" 2>/dev/null||echo 0))) -lt 1200 ] && exit 0; rm -f "$GF"; }
SF="/tmp/ha_wd_state"
IFS='|' read -r fails last_restart backoff < "$SF" 2>/dev/null || { fails=0; last_restart=0; backoff=5; }
c=$(curl -s -o /dev/null -w "%{http_code}" -m 10 http://localhost:8123 2>/dev/null||echo 000)
if [ "$c" = "000" ]; then
  fails=$((fails+1)); now=$(date +%s)
  mins_since=$([ "$last_restart" -gt 0 ] && echo $(((now-last_restart)/60)) || echo 999)
  if [ "$fails" -ge 3 ] && [ "$mins_since" -ge "$backoff" ]; then
    docker restart homeassistant 2>/dev/null
    /usr/local/bin/ha-notify "WD restart #${fails} (backoff ${backoff}m)"
    last_restart=$now; backoff=$((backoff*2)); [ "$backoff" -gt 60 ] && backoff=60; fails=0
  fi
else
  fails=0; backoff=5
fi
echo "${fails}|${last_restart}|${backoff}" > "$SF"
S

    cat > /usr/local/bin/ha-cleanup << 'S'
#!/bin/bash
fm=$(df -m / | awk 'NR==2{print $4}')
[ "$fm" -lt 1500 ] && {
  docker system prune -f 2>/dev/null
  journalctl --vacuum-size=30M 2>/dev/null
  apt-get clean 2>/dev/null
  /usr/local/bin/ha-notify "Cleanup: ${fm}MB -> $(df -m / | awk 'NR==2{print $4}')MB"
}
S

    cat > /usr/local/bin/ha-net-recovery << 'S'
#!/bin/bash
GW=$(ip route 2>/dev/null | awk '/default/{print $3}' | head -1)
[ -z "$GW" ] && GW=8.8.8.8
ping -c2 -W3 "$GW" >/dev/null 2>&1 && exit 0
ping -c2 -W3 8.8.8.8 >/dev/null 2>&1 && exit 0
nmcli networking off 2>/dev/null; sleep 3; nmcli networking on 2>/dev/null; sleep 5
ping -c2 -W3 8.8.8.8 >/dev/null 2>&1 \
  && /usr/local/bin/ha-notify "Network recovered" \
  || /usr/local/bin/ha-notify "Network FAILED"
S

    chmod +x /usr/local/bin/ha-watchdog /usr/local/bin/ha-cleanup /usr/local/bin/ha-net-recovery
    msg_ok "Watchdog (exp. backoff)"
  fi

  # --- Thermal ---
  if [ "$OPT_THERMAL" = true ]; then
    cat > /usr/local/bin/ha-thermal << 'S'
#!/bin/bash
[ ! -f /sys/class/thermal/thermal_zone0/temp ] && exit 0
t=$(($(cat /sys/class/thermal/thermal_zone0/temp)/1000))
[ "$t" -ge 80 ] && /usr/local/bin/ha-notify "TEMP CRITICAL: ${t}C!"
[ "$t" -ge 70 ] && [ "$t" -lt 80 ] && /usr/local/bin/ha-notify "TEMP WARNING: ${t}C"
S
    chmod +x /usr/local/bin/ha-thermal
    msg_ok "Thermal monitor"
  fi

  # --- ha-health (with docker disk usage) ---
  cat > /usr/local/bin/ha-health << 'S'
#!/bin/bash
echo "===== HA Health ($(date)) ====="
printf " %-12s %s\n" \
  Host: "$(hostname)" \
  IP: "$(hostname -I 2>/dev/null | awk '{print $1}')" \
  Up: "$(uptime -p 2>/dev/null)" \
  Kernel: "$(uname -r)"
[ -f /sys/class/thermal/thermal_zone0/temp ] && \
  printf " %-12s %dC\n" CPU: "$(($(cat /sys/class/thermal/thermal_zone0/temp)/1000))"
free -h | awk '/Mem:/{printf " %-12s %s/%s\n","RAM:",$3,$2} /Swap:/{printf " %-12s %s/%s\n","Swap:",$3,$2}'
df -h / | awk 'NR==2{printf " %-12s %s/%s (%s)\n","Disk:",$3,$2,$5}'
echo "-- Containers --"
docker ps --format " {{.Names}}: {{.Status}}" 2>/dev/null || echo " n/a"
echo "-- Docker Disk --"
docker system df 2>/dev/null || echo " n/a"
printf " %-12s %s\n" "HA:" "$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://localhost:8123 2>/dev/null || echo 000)"
echo "========================="
S
  chmod +x /usr/local/bin/ha-health
  msg_ok "ha-health"

  # --- Weekly report (proper newlines via $'\n') ---
  cat > /usr/local/bin/ha-weekly-report << 'S'
#!/bin/bash
ha_code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://localhost:8123 2>/dev/null || echo 000)
cpu_temp="n/a"
[ -f /sys/class/thermal/thermal_zone0/temp ] && cpu_temp="$(($(cat /sys/class/thermal/thermal_zone0/temp)/1000))C"
ram_info=$(free -h | awk '/Mem:/{printf "%s/%s",$3,$2}')
disk_info=$(df -h / | awk 'NR==2{printf "%s/%s (%s)",$3,$2,$5}')
uptime_info=$(uptime -p 2>/dev/null || echo "unknown")
containers=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l)

R="Weekly Report"
R="${R}"$'\n'"HA: ${ha_code}"
R="${R}"$'\n'"CPU: ${cpu_temp}"
R="${R}"$'\n'"RAM: ${ram_info}"
R="${R}"$'\n'"Disk: ${disk_info}"
R="${R}"$'\n'"Up: ${uptime_info}"
R="${R}"$'\n'"Containers: ${containers}"
/usr/local/bin/ha-notify "$R"
S
  chmod +x /usr/local/bin/ha-weekly-report
  msg_ok "Weekly report"

  # --- Backup ---
  if [ "$OPT_BACKUP" = true ]; then
    mkdir -p "$HA_BACKUP_DIR"
    cat > /usr/local/bin/ha-backup << BEOF
#!/bin/bash
set -f
BD="${HA_BACKUP_DIR}"; HD="${HASSIO_DIR}"; KD=30
TS=\$(date +%Y%m%d_%H%M%S); mkdir -p "\$BD"
[ ! -d "\${HD}/homeassistant" ] && exit 1
EX="--exclude=*.db --exclude=*.db-shm --exclude=*.db-wal --exclude=home-assistant_v2.db* --exclude=tts --exclude=deps --exclude=__pycache__"
command -v pigz &>/dev/null \
  && tar -I pigz -cf "\${BD}/ha_config_\${TS}.tar.gz" \$EX -C "\$HD" homeassistant 2>/dev/null \
  || tar czf "\${BD}/ha_config_\${TS}.tar.gz" \$EX -C "\$HD" homeassistant 2>/dev/null
find "\$BD" -name "ha_config_*.tar.gz" -mtime +\$KD -delete 2>/dev/null
/usr/local/bin/ha-notify "Backup: \$(du -sh "\${BD}/ha_config_\${TS}.tar.gz" 2>/dev/null | awk '{print \$1}')"
BEOF

    cat > /usr/local/bin/ha-restore << REOF
#!/bin/bash
[ -z "\$BASH_VERSION" ] && { echo "bash required!"; exit 1; }
BD="${HA_BACKUP_DIR}"; HD="${HASSIO_DIR}"
mapfile -t F < <(ls -1t "\$BD"/ha_config_*.tar.gz 2>/dev/null)
[ \${#F[@]} -eq 0 ] && { echo "No backups found"; exit 1; }
for i in "\${!F[@]}"; do
  printf " %d) %s (%s)\n" "\$((i+1))" "\$(basename "\${F[\$i]}")" "\$(du -sh "\${F[\$i]}" | awk '{print \$1}')"
done
read -p "Select #: " n
[[ ! "\$n" =~ ^[0-9]+\$ ]] || [ "\$n" -lt 1 ] || [ "\$n" -gt \${#F[@]} ] && exit 1
read -p "Confirm? (yes/no): " c; [ "\$c" != yes ] && exit 0
echo "Verifying..."; tar tzf "\${F[\$((n-1))]}" >/dev/null 2>&1 || { echo "Archive corrupt!"; exit 1; }
echo "Backup current..."; docker stop homeassistant 2>/dev/null
ts=\$(date +%Y%m%d_%H%M%S)
tar czf "\${BD}/ha_pre_restore_\${ts}.tar.gz" -C "\$HD" homeassistant 2>/dev/null
echo "Restoring..."; tar xzf "\${F[\$((n-1))]}" -C "\$HD"
docker start homeassistant 2>/dev/null; echo "Done!"
REOF
    chmod +x /usr/local/bin/ha-backup /usr/local/bin/ha-restore
    msg_ok "Backup system"
  fi

  # --- Remote backup ---
  if [ "$OPT_REMOTE_BACKUP" = true ] && [ -n "$REMOTE_BACKUP_TARGET" ]; then
    cat > /usr/local/bin/ha-backup-remote << RBEOF
#!/bin/bash
BD="${HA_BACKUP_DIR}"; REMOTE="${REMOTE_BACKUP_TARGET}"
LATEST=\$(ls -1t "\$BD"/ha_config_*.tar.gz 2>/dev/null | head -1)
[ -z "\$LATEST" ] && exit 1
case "\$REMOTE" in
  ssh://*) scp -o StrictHostKeyChecking=no "\$LATEST" "\${REMOTE#ssh://}" 2>/dev/null \
    && /usr/local/bin/ha-notify "Backup -> SSH OK" ;;
  *) /usr/local/bin/ha-notify "Unknown backup protocol" ;;
esac
RBEOF
    chmod +x /usr/local/bin/ha-backup-remote
    msg_ok "Remote backup"
  fi

  # --- Prometheus metrics ---
  if [ "$OPT_MONITORING" = true ]; then
    mkdir -p "$METRICS_DIR"
    cat > /usr/local/bin/ha-metrics << 'S'
#!/bin/bash
OUT="/var/lib/prometheus/node-exporter/ha.prom"
mkdir -p "$(dirname "$OUT")"
{
  echo "# HELP ha_up Home Assistant availability"
  echo "# TYPE ha_up gauge"
  c=$(curl -s -o /dev/null -w "%{http_code}" -m 5 http://localhost:8123 2>/dev/null || echo 000)
  { [ "$c" = "200" ] || [ "$c" = "401" ]; } && echo "ha_up 1" || echo "ha_up 0"

  echo "# HELP ha_containers Running HA containers"
  echo "# TYPE ha_containers gauge"
  echo "ha_containers $(docker ps --filter 'label=io.hass.type' --format '{{.ID}}' 2>/dev/null | wc -l)"

  if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    echo "# HELP ha_cpu_temp CPU temperature"
    echo "# TYPE ha_cpu_temp gauge"
    echo "ha_cpu_temp $(($(cat /sys/class/thermal/thermal_zone0/temp)/1000))"
  fi

  echo "# HELP ha_disk_free_bytes Root free bytes"
  echo "# TYPE ha_disk_free_bytes gauge"
  echo "ha_disk_free_bytes $(df -B1 / | awk 'NR==2{print $4}')"
} > "${OUT}.tmp" && mv "${OUT}.tmp" "$OUT"
S
    chmod +x /usr/local/bin/ha-metrics
    msg_ok "Prometheus metrics"
  fi

  # --- Boot recovery ---
  if [ "$OPT_BOOT_RECOVERY" = true ]; then
    cat > /usr/local/bin/ha-boot-check << 'S'
#!/bin/bash
sleep 30
dmesg | grep -qi "ext4.*error\|filesystem.*error" && \
  /usr/local/bin/ha-notify "FS errors detected after boot!"
docker info &>/dev/null || { systemctl restart docker; sleep 10; }
systemctl is-active --quiet hassio-supervisor || {
  systemctl restart hassio-supervisor
  /usr/local/bin/ha-notify "Supervisor restarted after boot"
}
S
    chmod +x /usr/local/bin/ha-boot-check

    cat > /etc/systemd/system/ha-boot-check.service << 'UNIT'
[Unit]
Description=HA Post-Boot Health Check
After=docker.service hassio-supervisor.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ha-boot-check
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    systemctl enable ha-boot-check 2>/dev/null || true
    msg_ok "Boot recovery"
  fi

  # --- Reverse proxy ---
  if [ "$OPT_REVERSE_PROXY" = true ] && [ -n "$PROXY_DOMAIN" ]; then
    cat > /etc/nginx/sites-available/homeassistant << NGINX
server {
    server_name ${PROXY_DOMAIN};
    location / {
        proxy_pass http://127.0.0.1:8123;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINX
    ln -sf /etc/nginx/sites-available/homeassistant /etc/nginx/sites-enabled/ 2>/dev/null
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    nginx -t 2>/dev/null && systemctl restart nginx 2>/dev/null && msg_ok "Nginx -> ${PROXY_DOMAIN}"
    certbot --nginx -d "$PROXY_DOMAIN" --non-interactive --agree-tos \
      --register-unsafely-without-email --redirect 2>/dev/null \
      && msg_ok "SSL: ${PROXY_DOMAIN}" \
      || msg_warn "SSL failed (run later: certbot --nginx -d ${PROXY_DOMAIN})"
  fi

  detect_usb_dongles

  # --- Cron (includes weekly report) ---
  {
    echo "# HA Installer v${SCRIPT_VERSION}"
    [ "$OPT_WATCHDOG" = true ] && printf '*/5 * * * * root /usr/local/bin/ha-watchdog >/dev/null 2>&1\n*/10 * * * * root /usr/local/bin/ha-net-recovery >/dev/null 2>&1\n30 3 * * * root /usr/local/bin/ha-cleanup >/dev/null 2>&1\n'
    [ "$OPT_THERMAL" = true ]      && echo '*/5 * * * * root /usr/local/bin/ha-thermal >/dev/null 2>&1'
    [ "$OPT_BACKUP" = true ]       && echo '0 4 * * 0 root /usr/local/bin/ha-backup >/dev/null 2>&1'
    [ "$OPT_REMOTE_BACKUP" = true ] && echo '30 4 * * 0 root /usr/local/bin/ha-backup-remote >/dev/null 2>&1'
    [ "$OPT_MONITORING" = true ]   && echo '* * * * * root /usr/local/bin/ha-metrics >/dev/null 2>&1'
    echo '0 9 * * 1 root /usr/local/bin/ha-weekly-report >/dev/null 2>&1'
  } > /etc/cron.d/ha-tools
  chmod 644 /etc/cron.d/ha-tools
  msg_ok "Cron jobs"

  mark_done "$sid"
}

# ============================================================================
# STEP: HACS
# ============================================================================
step_hacs() {
  local sid="hacs"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] HACS"

  if [ "$OPT_HACS" != true ]; then
    msg_warn "Skipped"
    mark_done "$sid"
    return 0
  fi

  msg_dim "HACS: runs external code from https://get.hacs.xyz"
  wait_ha_ready 300 || { msg_warn "Timeout"; mark_done "$sid"; return 0; }

  local cw=0
  while ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$'; do
    sleep 5; cw=$((cw+5))
    [ $cw -gt 60 ] && { mark_done "$sid"; return 0; }
  done

  docker exec homeassistant bash -c "wget -q -O- https://get.hacs.xyz | bash -" &>/dev/null &
  local hp=$! hw=0
  while kill -0 "$hp" 2>/dev/null; do
    sleep 5; hw=$((hw+5))
    [ $hw -ge 120 ] && { kill "$hp" 2>/dev/null; mark_done "$sid"; return 0; }
  done

  wait "$hp" 2>/dev/null && {
    docker restart homeassistant >/dev/null 2>&1
    msg_ok "HACS installed!"
  } || msg_warn "HACS error (can install later)"

  mark_done "$sid"
}

# ============================================================================
# STEP: POST-RESTORE
# ============================================================================
step_post_restore() {
  local sid="postrestore"; is_done "$sid" && return 0

  if [ -z "$OPT_RESTORE_BACKUP" ]; then
    mark_done "$sid"
    return 0
  fi

  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] RESTORE BACKUP"

  if [ ! -f "$OPT_RESTORE_BACKUP" ]; then
    msg_error "Backup not found: ${OPT_RESTORE_BACKUP}"
    mark_done "$sid"
    return 1
  fi

  msg_action "Verifying backup..."
  tar tzf "$OPT_RESTORE_BACKUP" >/dev/null 2>&1 || {
    msg_error "Backup archive corrupt!"
    mark_done "$sid"
    return 1
  }

  msg_action "Waiting for HA to be ready..."
  wait_ha_ready 600 || { msg_warn "HA not ready, skipping restore"; mark_done "$sid"; return 0; }

  local cw=0
  while ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$'; do
    sleep 5; cw=$((cw+5))
    [ $cw -gt 120 ] && break
  done

  msg_action "Stopping HA for restore..."
  docker stop homeassistant 2>/dev/null || true
  sleep 3

  msg_action "Restoring: $(basename "$OPT_RESTORE_BACKUP")..."
  if tar xzf "$OPT_RESTORE_BACKUP" -C "$HASSIO_DIR" 2>/dev/null; then
    msg_ok "Backup restored"
    docker start homeassistant 2>/dev/null
    send_notification "Restored: $(basename "$OPT_RESTORE_BACKUP")"
  else
    msg_error "Restore failed"
    docker start homeassistant 2>/dev/null
  fi

  mark_done "$sid"
}

# ============================================================================
# OPERATIONS: CHECK, STATUS, UNINSTALL, UPDATE, SELF-TEST
# ============================================================================
do_check() {
  header "DIAGNOSTICS"; detect_system_info
  local ip t; ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="?"; t=$(get_cpu_temp)
  echo -e "   ${BOLD}System${NC}"
  msg_info "Host: $(hostname 2>/dev/null)  IP: ${ip}  OS: ${CACHED_PRETTY_NAME}"
  [ -n "$t" ] && msg_info "CPU: ${t}C"
  [ -n "$OPT_TIMEZONE" ] && msg_info "TZ: ${OPT_TIMEZONE}"
  [ -n "$OPT_DATA_DIR" ] && msg_info "Data: ${OPT_DATA_DIR}"
  separator

  echo -e "   ${BOLD}Components${NC}"
  command -v docker &>/dev/null && \
    msg_ok "Docker: $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')" || msg_error "Docker: missing"
  local hs; hs=$(systemctl is-active hassio-supervisor 2>/dev/null) || hs="missing"
  [ "$hs" = "active" ] && msg_ok "Supervisor: ${hs}" || msg_error "Supervisor: ${hs}"
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$' \
    && msg_ok "HA Core: $(docker inspect -f '{{.State.Status}}' homeassistant 2>/dev/null)" \
    || msg_error "HA Core: missing"
  [ -f "$FAKED_OS_RELEASE" ] && msg_info "os-release: faked" || msg_info "os-release: original"

  separator; verify_installed_scripts; show_progress; echo ""
}

do_status() {
  while true; do
    clear; show_banner
    local ip t; ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="?"; t=$(get_cpu_temp)
    echo -e "   ${BOLD}IP:${NC} $ip  ${BOLD}CPU:${NC} ${t:-?}C  ${BOLD}Up:${NC} $(uptime -p 2>/dev/null || echo ?)"
    echo -e "   ${BOLD}RAM:${NC} $(free -h | awk '/Mem:/{printf "%s/%s",$3,$2}')  ${BOLD}Swap:${NC} $(free -h | awk '/Swap:/{printf "%s/%s",$3,$2}')"
    separator
    docker ps --format ' {{.Names}}|{{.Status}}' 2>/dev/null | while IFS='|' read -r n s; do
      echo "$s" | grep -q Up \
        && echo -e "   ${CHECK} ${n} ${DIM}${s}${NC}" \
        || echo -e "   ${CROSS} ${n} ${RED}${s}${NC}"
    done
    local hc; hc=$(curl -s -o /dev/null -w "%{http_code}" -m 3 http://localhost:8123 2>/dev/null || echo 000)
    separator
    [ "$hc" != "000" ] && echo -e "   ${CHECK} HA: ${GREEN}${hc}${NC}" || echo -e "   ${CROSS} HA: ${RED}down${NC}"
    echo -e "   ${DIM}5s refresh. Ctrl+C to exit${NC}"
    sleep 5
  done
}

do_uninstall() {
  header "UNINSTALL"
  local ok=false
  if command -v whiptail &>/dev/null; then
    whiptail --title "Uninstall" --yesno "Remove HA Supervised?" 8 40 && ok=true
  else
    echo -en "   ${WARN} Remove HA? (yes/no): " >&2
    local r; read -r r; [ "$r" = yes ] && ok=true
  fi
  [ "$ok" != true ] && { msg_info "Cancelled."; exit 0; }

  systemctl stop hassio-supervisor hassio-apparmor 2>/dev/null || true
  docker ps -a --filter "label=io.hass.type" --format '{{.Names}}' 2>/dev/null | while IFS= read -r c; do docker rm -f "$c" 2>/dev/null; done
  for c in homeassistant hassio_supervisor hassio_cli hassio_audio hassio_dns hassio_multicast hassio_observer; do
    docker rm -f "$c" 2>/dev/null || true
  done
  docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -iE "homeassistant|hassio|home-assistant" | while IFS= read -r i; do docker rmi -f "$i" 2>/dev/null; done
  for svc in hassio-supervisor hassio-apparmor ha-boot-check "${REBOOT_CONTINUE_SVC}"; do
    systemctl disable "$svc" 2>/dev/null; rm -f "/etc/systemd/system/${svc}.service"
  done
  rm -rf /etc/systemd/system/hassio-supervisor.service.d
  systemctl daemon-reload 2>/dev/null || true
  dpkg --purge homeassistant-supervised os-agent 2>/dev/null || true
  rm -f /usr/local/bin/ha-notify /usr/local/bin/ha-watchdog /usr/local/bin/ha-cleanup \
    /usr/local/bin/ha-net-recovery /usr/local/bin/ha-backup /usr/local/bin/ha-restore \
    /usr/local/bin/ha-health /usr/local/bin/ha-thermal /usr/local/bin/ha-metrics \
    /usr/local/bin/ha-boot-check /usr/local/bin/ha-backup-remote /usr/local/bin/ha-weekly-report \
    /etc/cron.d/ha-tools /etc/udev/rules.d/99-ha-usb-power.rules \
    /etc/ssh/sshd_config.d/99-ha-hardening.conf /etc/sysctl.d/99-ha-swap.conf \
    /etc/systemd/journald.conf.d/ha-tuning.conf "$HA_INFO_FILE" "$SAFE_SCRIPT_PATH" 2>/dev/null
  [ -f /etc/ufw/after.rules ] && {
    sed -i '/# BEGIN HA-INSTALLER DOCKER-USER/,/# END HA-INSTALLER DOCKER-USER/d' /etc/ufw/after.rules 2>/dev/null
    ufw reload 2>/dev/null || true
  }
  [ -f /etc/nginx/sites-enabled/homeassistant ] && {
    rm -f /etc/nginx/sites-enabled/homeassistant /etc/nginx/sites-available/homeassistant
    systemctl reload nginx 2>/dev/null || true
  }
  [ -d "$HASSIO_DIR" ] && {
    echo -en "   ${WARN} Delete HA data? (yes/no): " >&2; local r; read -r r; [ "$r" = yes ] && rm -rf "$HASSIO_DIR"
  }
  [ -d "$HA_BACKUP_DIR" ] && {
    echo -en "   ${WARN} Delete backups? (yes/no): " >&2; local r; read -r r; [ "$r" = yes ] && rm -rf "$HA_BACKUP_DIR"
  }
  restore_os_release
  rm -f "$FAKED_OS_RELEASE" 2>/dev/null
  rm -rf "$HA_INSTALLER_DIR" /root/.ha_install_state /root/.ha_install_backup 2>/dev/null
  docker system prune -f 2>/dev/null || true
  rm -f "$GRACE_MARKER" 2>/dev/null
  header "UNINSTALLED"
}

do_update() {
  header "UPDATE"; load_config; detect_system_info
  if [ -x /usr/local/bin/ha-backup ] && [ -d "${HASSIO_DIR}/homeassistant" ]; then
    msg_action "Auto-backup before update..."
    /usr/local/bin/ha-backup 2>/dev/null && msg_ok "Backup OK" || msg_warn "Backup failed"
  fi
  local co="${OA_VERSION:-}" ch="${HA_VERSION:-}" lo lh
  lo=$(get_latest_release "home-assistant/os-agent")
  lh=$(get_latest_release "home-assistant/supervised-installer")
  msg_info "OA: ${co:-?} -> ${lo:-?}"
  msg_info "HA: ${ch:-?} -> ${lh:-?}"
  [ "$co" = "$lo" ] && [ "$ch" = "$lh" ] && { msg_ok "Everything up to date"; return 0; }
  setup_tmpdir
  if [ "$co" != "$lo" ] && [ -n "$lo" ]; then
    download_file "https://github.com/home-assistant/os-agent/releases/download/${lo}/os-agent_${lo}_linux_${CACHED_ARCH}.deb" "${HA_TMP}/os-agent.deb" "OA ${lo}"
    verify_checksum "${HA_TMP}/os-agent.deb" "home-assistant/os-agent" "$lo"
    run_cmd "OS-Agent" dpkg -i "${HA_TMP}/os-agent.deb"
    RESOLVED_OA_VER="$lo"
  fi
  if [ "$ch" != "$lh" ] && [ -n "$lh" ]; then
    download_file "https://github.com/home-assistant/supervised-installer/releases/download/${lh}/homeassistant-supervised.deb" "${HA_TMP}/ha.deb" "HA ${lh}"
    verify_checksum "${HA_TMP}/ha.deb" "home-assistant/supervised-installer" "$lh"
    [ "$OS_RELEASE_FAKED" = true ] && [ -f "$FAKED_OS_RELEASE" ] && cp "$FAKED_OS_RELEASE" /etc/os-release
    DEBIAN_FRONTEND=noninteractive dpkg -i "${HA_TMP}/ha.deb" >/dev/null 2>&1 || apt-get install -f -y >/dev/null 2>&1
    [ "$OS_RELEASE_FAKED" = true ] && restore_os_release
    RESOLVED_HA_VER="$lh"
  fi
  RESOLVED_HA_VER="${RESOLVED_HA_VER:-${lh:-$ch}}"
  RESOLVED_OA_VER="${RESOLVED_OA_VER:-$lo}"
  save_config; msg_ok "Updated"
  send_notification "Updated OA:${RESOLVED_OA_VER} HA:${RESOLVED_HA_VER}"
}

do_self_update() {
  header "SCRIPT UPDATE"
  local latest; latest=$(get_latest_release "$INSTALLER_REPO")
  [ -z "$latest" ] && { msg_warn "Cannot check"; return; }
  [ "$SCRIPT_VERSION" = "$latest" ] && { msg_ok "Current: ${SCRIPT_VERSION}"; return; }
  msg_info "Available: ${SCRIPT_VERSION} -> ${latest}"
  if [ -t 0 ]; then
    echo -en "   ${ARROW} Update? (y/n): " >&2; local ans; read -r ans; [ "$ans" != "y" ] && return
  fi
  local nf="${0}.new"
  wget -q -O "$nf" "https://raw.githubusercontent.com/${INSTALLER_REPO}/main/install.sh" 2>/dev/null || { msg_error "Download failed"; return; }
  bash -n "$nf" 2>/dev/null || { msg_error "Syntax error in new script"; rm -f "$nf"; return; }
  grep -q "SCRIPT_VERSION=" "$nf" || { msg_error "Invalid file"; rm -f "$nf"; return; }
  local sz; sz=$(wc -c < "$nf")
  [ "$sz" -lt 10000 ] && { msg_error "File too small (${sz}b)"; rm -f "$nf"; return; }
  mv "$nf" "$0"; chmod +x "$0"
  msg_ok "Updated to ${latest}. Re-run the script."
}

do_self_test() {
  header "SELF-TEST"
  local pass=0 fail=0
  _t() {
    local d="$1" e="$2"; shift 2; local r=0
    "$@" 2>/dev/null || r=1
    if [ "$r" -eq "$e" ]; then msg_ok "$d"; pass=$((pass+1))
    else msg_error "$d (expected=$e got=$r)"; fail=$((fail+1)); fi
  }

  _t "ip 192.168.1.1"    0 validate_ip "192.168.1.1"
  _t "ip 0.0.0.0"        1 validate_ip "0.0.0.0"
  _t "ip 256.1.1.1"      1 validate_ip "256.1.1.1"
  _t "ip 01.02.03.04"    1 validate_ip "01.02.03.04"
  _t "ip 255.255.255.255" 1 validate_ip "255.255.255.255"
  _t "ip 10.0.0.1"       0 validate_ip "10.0.0.1"
  _t "gw ok"             0 validate_gw "192.168.1.1"
  _t "gw empty"          1 validate_gw ""
  _t "dns ok"            0 validate_dns_list "8.8.8.8,1.1.1.1"
  _t "dns bad"           1 validate_dns_list "abc"
  _t "dns empty"         1 validate_dns_list ""

  local a; a=$(detect_arch)
  [ -n "$a" ] && { msg_ok "arch: ${a}"; pass=$((pass+1)); } || { msg_error "arch"; fail=$((fail+1)); }

  # Test state system
  local tsf="/tmp/ha_test_$$"
  local orig="$STATE_FILE"; STATE_FILE="$tsf"; rm -f "$tsf"
  mark_done "test_step"
  is_done "test_step" && { msg_ok "state ok"; pass=$((pass+1)); } || { msg_error "state fail"; fail=$((fail+1)); }
  rm -f "$tsf" "${tsf}.lock"; STATE_FILE="$orig"

  # Test profile
  local saved="$OPT_ZRAM"
  apply_profile "minimal" 2>/dev/null
  [ "$OPT_ZRAM" = true ] && { msg_ok "profile ok"; pass=$((pass+1)); } || { msg_error "profile fail"; fail=$((fail+1)); }
  OPT_ZRAM="$saved"

  # Test text UI functions
  local tm_result
  tm_result=$(echo "1" | text_menu "Test" "Pick:" "alpha" "First" "beta" "Second" 2>/dev/null)
  [ "$tm_result" = "alpha" ] && { msg_ok "text_menu ok"; pass=$((pass+1)); } || { msg_error "text_menu fail (got: ${tm_result})"; fail=$((fail+1)); }

  separator
  echo -e "   ${BOLD}Result: ${pass} passed / ${fail} failed${NC}"
  [ $fail -gt 0 ] && return 1 || return 0
}

# ============================================================================
# ARGS
# ============================================================================
show_help() {
  cat << HELP
HA Installer v${SCRIPT_VERSION}

  sudo ./install.sh                     Interactive wizard/menu

  MODES:
    -c, --check                         System diagnostics
    -s, --status                        Live monitoring
    -u, --uninstall                     Uninstall HA
    --update                            Update HA + OS-Agent
    --self-update                       Update this script
    --self-test                         Run self-test
    --benchmark                         Hardware benchmark
    --export-config                     Export config
    --history                           Show run history

  INSTALL OPTIONS:
    --profile NAME                      minimal|standard|full|server|dev
    --timezone ZONE                     e.g. Europe/Moscow
    --locale LOCALE                     e.g. ru_RU.UTF-8
    --data-dir PATH                     External storage for data
    --restore-backup FILE               Restore backup after install
    --wifi SSID PASSWORD                Configure WiFi
    --webhook URL                       Notification webhook
    --swap SIZE|zram|none               Swap configuration
    --docker-mirror URL                 Docker registry mirror
    --auto-reboot                       Auto-reboot if needed
    --from-step STEP                    Resume from step
    --import-config FILE                Import config file
    --skip-update                       Skip apt update/upgrade
    --dry-run                           Show what would be done
    --silent                            Minimal output
    --interactive-steps                 Confirm each step
    --reset-state                       Reset installation state
    --machine TYPE                      HA machine type
    --os-agent-ver X                    Pin OS-Agent version
    --ha-ver X                          Pin HA version

  FILES:
    ${HA_INSTALLER_DIR}/                Config & state
    ${HA_BACKUP_DIR}/                   Backups
    ${HA_INFO_FILE}                     Installation info

HELP
}

parse_args() {
  [ $# -eq 0 ] && return
  local explicit_mode=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)            show_help; exit 0;;
      -c|--check)           CHECK_ONLY=true; explicit_mode=true;;
      -s|--status)          SHOW_STATUS=true; explicit_mode=true;;
      -u|--uninstall)       UNINSTALL=true; explicit_mode=true;;
      --update)             DO_UPDATE=true; explicit_mode=true;;
      --self-update)        DO_SELF_UPDATE=true; explicit_mode=true;;
      --self-test)          DO_SELF_TEST=true; explicit_mode=true;;
      --benchmark)          DO_BENCHMARK=true; explicit_mode=true;;
      --export-config)      DO_EXPORT_CONFIG=true; explicit_mode=true;;
      --history)            DO_SHOW_HISTORY=true; explicit_mode=true;;
      --reset-state)        reset_state; exit 0;;
      --skip-update)        SKIP_UPDATE=true;;
      --dry-run)            DRY_RUN=true;;
      --silent)             SILENT=true; RUN_WIZARD=false;;
      --interactive-steps)  INTERACTIVE_STEPS=true;;
      --auto-reboot)        OPT_AUTO_REBOOT=true;;
      --profile)            shift; [ $# -eq 0 ] && { msg_error "--profile ?"; exit 1; }; PROFILE="$1";;
      --profile=*)          PROFILE="${1#*=}";;
      --from-step)          shift; [ $# -eq 0 ] && { msg_error "--from-step ?"; exit 1; }; FROM_STEP="$1";;
      --from-step=*)        FROM_STEP="${1#*=}";;
      --import-config)      shift; [ $# -eq 0 ] && { msg_error "--import-config ?"; exit 1; }; IMPORT_CONFIG="$1";;
      --import-config=*)    IMPORT_CONFIG="${1#*=}";;
      --timezone)           shift; [ $# -eq 0 ] && { msg_error "--timezone ?"; exit 1; }; OPT_TIMEZONE="$1";;
      --timezone=*)         OPT_TIMEZONE="${1#*=}";;
      --locale)             shift; [ $# -eq 0 ] && { msg_error "--locale ?"; exit 1; }; OPT_LOCALE="$1";;
      --locale=*)           OPT_LOCALE="${1#*=}";;
      --data-dir)           shift; [ $# -eq 0 ] && { msg_error "--data-dir ?"; exit 1; }; OPT_DATA_DIR="$1";;
      --data-dir=*)         OPT_DATA_DIR="${1#*=}";;
      --restore-backup)     shift; [ $# -eq 0 ] && { msg_error "--restore-backup ?"; exit 1; }; OPT_RESTORE_BACKUP="$1";;
      --restore-backup=*)   OPT_RESTORE_BACKUP="${1#*=}";;
      --wifi)               shift; [ $# -lt 2 ] && { msg_error "--wifi SSID PASS"; exit 1; }; OPT_WIFI_SSID="$1"; shift; OPT_WIFI_PASS="$1";;
      --webhook)            shift; [ $# -eq 0 ] && { msg_error "--webhook ?"; exit 1; }; OPT_WEBHOOK_URL="$1";;
      --webhook=*)          OPT_WEBHOOK_URL="${1#*=}";;
      --swap)               shift; [ $# -eq 0 ] && { msg_error "--swap ?"; exit 1; }; OPT_SWAP_SIZE="$1";;
      --swap=*)             OPT_SWAP_SIZE="${1#*=}";;
      --docker-mirror)      shift; [ $# -eq 0 ] && { msg_error "--docker-mirror ?"; exit 1; }; OPT_DOCKER_MIRROR="$1";;
      --docker-mirror=*)    OPT_DOCKER_MIRROR="${1#*=}";;
      --machine)            shift; [ $# -eq 0 ] && { msg_error "--machine ?"; exit 1; }; HA_MACHINE="$1"; MACHINE_EXPLICIT=true;;
      --machine=*)          HA_MACHINE="${1#*=}"; MACHINE_EXPLICIT=true;;
      --os-agent-ver)       shift; [ $# -eq 0 ] && { msg_error "--os-agent-ver ?"; exit 1; }; OVERRIDE_OS_AGENT_VER="$1";;
      --os-agent-ver=*)     OVERRIDE_OS_AGENT_VER="${1#*=}";;
      --ha-ver)             shift; [ $# -eq 0 ] && { msg_error "--ha-ver ?"; exit 1; }; OVERRIDE_HA_VER="$1";;
      --ha-ver=*)           OVERRIDE_HA_VER="${1#*=}";;
      *)                    msg_error "Unknown option: $1"; show_help; exit 1;;
    esac
    shift
  done
  [ "$explicit_mode" = true ] && RUN_WIZARD=false
}

# ============================================================================
# BANNER
# ============================================================================
show_banner() {
  if [ "$CHECK_ONLY" != true ] && [ "$UNINSTALL" != true ] && [ "$SHOW_STATUS" != true ]; then
    [ "$LOGGING_ACTIVE" != true ] && clear
  fi
  [ "$SILENT" != true ] && {
    echo -e "${BLUE}  _   _                         _            _     _              _   ${NC}"
    echo -e "${BLUE} | | | | ___  _ __ ___   ___   / \\   ___ ___(_)___| |_ __ _ _ __ | |_ ${NC}"
    echo -e "${BLUE} | |_| |/ _ \\| '_ \` _ \\ / _ \\ / _ \\ / __/ __| / __| __/ _\` | '_ \\| __|${NC}"
    echo -e "${BLUE} |  _  | (_) | | | | | |  __// ___ \\\\__ \\__ \\ \\__ \\ || (_| | | | | |_ ${NC}"
    echo -e "${BLUE} |_| |_|\\___/|_| |_| |_|\\___/_/   \\_\\___/___/_|___/\\__\\__,_|_| |_|\\__|${NC}"
    echo -e "${WHITE}${BOLD}     ULTIMATE INSTALLER v${SCRIPT_VERSION}${NC}"
    separator
  }
}

# ============================================================================
# FINAL REPORT (with step timing and WiFi QR)
# ============================================================================
show_final() {
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"
  local now; now=$(date +%s)
  local el=$(( now - ${INSTALL_START:-$now} ))
  local em=$((el/60)) es=$((el%60))

  header "COMPLETE! (${em}m ${es}s)"

  echo -e "   ${GREEN}=> http://${ip}:8123${NC}"
  [ "$OPT_HOSTNAME" = true ] && echo -e "   ${GREEN}=> http://homeassistant.local:8123${NC}"
  [ "$OPT_REVERSE_PROXY" = true ] && [ -n "$PROXY_DOMAIN" ] && echo -e "   ${GREEN}=> https://${PROXY_DOMAIN}${NC}"

  # WiFi QR
  if [ -n "$OPT_WIFI_SSID" ] && command -v qrencode &>/dev/null && [ "$SILENT" != true ]; then
    echo ""
    echo -e "   ${BOLD}WiFi QR:${NC}"
    qrencode -m 2 -t ANSIUTF8 "WIFI:T:WPA;S:${OPT_WIFI_SSID};P:${OPT_WIFI_PASS};;"
  fi

  # HA QR
  if command -v qrencode &>/dev/null && [ "$SILENT" != true ]; then
    echo ""
    echo -e "   ${BOLD}HA QR:${NC}"
    qrencode -m 2 -t ANSIUTF8 "http://${ip}:8123"
    echo ""
  fi

  separator
  echo -e "   ${BOLD}Components:${NC} (profile: ${PROFILE:-custom})"
  echo -e "   ${CHECK} HA Supervised (${HA_MACHINE}) + Docker + OS-Agent"
  [ -n "$OPT_TIMEZONE" ]          && echo -e "   ${CHECK} TZ: ${OPT_TIMEZONE}"
  [ -n "$OPT_DATA_DIR" ]          && echo -e "   ${CHECK} Data: ${OPT_DATA_DIR}"
  [ "$OPT_ZRAM" = true ]          && echo -e "   ${CHECK} ZRAM"
  [ "$OPT_UFW" = true ]           && echo -e "   ${CHECK} UFW + Fail2Ban"
  [ "$OPT_WATCHDOG" = true ]      && echo -e "   ${CHECK} Watchdog"
  [ "$OPT_BACKUP" = true ]        && echo -e "   ${CHECK} Backup"
  [ "$OPT_HACS" = true ]          && echo -e "   ${CHECK} HACS"
  [ "$OPT_MONITORING" = true ]    && echo -e "   ${CHECK} Monitoring"
  [ "$OPT_BOOT_RECOVERY" = true ] && echo -e "   ${CHECK} Boot recovery"
  [ "$OPT_REVERSE_PROXY" = true ] && echo -e "   ${CHECK} Proxy: ${PROXY_DOMAIN}"
  [ -n "$OPT_RESTORE_BACKUP" ]    && echo -e "   ${CHECK} Restored: $(basename "$OPT_RESTORE_BACKUP")"
  [ "$OS_RELEASE_FAKED" = true ]   && echo -e "   ${WARN} os-release faked on supervisor start"

  # Step timing breakdown
  separator
  echo -e "   ${BOLD}Step timing:${NC}"
  for s in "${ALL_STEPS[@]}"; do
    local st="${STEP_TIMES[$s]:-0}"
    [ "$st" -gt 0 ] && printf "   %-15s %ds\n" "${s}" "$st"
  done

  separator
  msg_dim "Config:  ${HA_INSTALLER_DIR}"
  msg_dim "Backups: ${HA_BACKUP_DIR}"
  msg_dim "Log:     ${LOG_FILE}"
  msg_dim "Info:    ${HA_INFO_FILE}"

  echo -e "\n   ${BOLD}Commands:${NC} ha-health  ha-backup  ha-restore"

  [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" != "Y" ] && \
    msg_warn "AppArmor requires reboot: sudo reboot"

  echo -e "\n   ${YELLOW}HA initialization takes 10-15 minutes.${NC}\n"

  generate_info_file
  send_notification "HA installed: http://${ip}:8123"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
  # Quick help check
  for a in "$@"; do
    [ "$a" = "-h" ] || [ "$a" = "--help" ] && { show_help; exit 0; }
  done

  [ "$EUID" -ne 0 ] && { echo "Root required! Use: sudo $0"; exit 1; }

  ORIGINAL_ARGS="$*"
  parse_args "$@"
  setup_dirs
  migrate_legacy_paths
  log_run_history "$*"

  # Clean up reboot-continue service if it exists
  remove_reboot_continue

  # Import config if specified
  [ -n "$IMPORT_CONFIG" ] && import_config "$IMPORT_CONFIG"

  # Handle explicit modes (no wizard needed)
  [ "$CHECK_ONLY" = true ]      && { show_banner; do_check; exit 0; }
  [ "$SHOW_STATUS" = true ]     && { do_status; exit 0; }
  [ "$UNINSTALL" = true ]       && { show_banner; acquire_lock; do_uninstall; exit 0; }
  [ "$DO_UPDATE" = true ]       && { show_banner; acquire_lock; do_update; exit 0; }
  [ "$DO_SELF_UPDATE" = true ]  && { show_banner; do_self_update; exit 0; }
  [ "$DO_SELF_TEST" = true ]    && { show_banner; do_self_test; exit $?; }
  [ "$DO_BENCHMARK" = true ]    && { show_banner; do_benchmark; exit 0; }
  [ "$DO_EXPORT_CONFIG" = true ] && { show_banner; export_config; exit 0; }
  [ "$DO_SHOW_HISTORY" = true ] && { show_banner; show_history; exit 0; }

  # Apply profile if given via CLI
  [ -n "$PROFILE" ] && apply_profile "$PROFILE"

  # Interactive: show menu if no args, then wizard
  if [ $# -eq 0 ] && [ "$RUN_WIZARD" = true ]; then
    show_main_menu 2>/dev/null || true
  fi
  [ "$RUN_WIZARD" = true ] && [ "$DRY_RUN" = false ] && run_wizard

  # Nohup offer BEFORE logging starts
  auto_nohup_if_ssh

  # Start installation
  show_banner
  setup_logging
  setup_tmpdir
  INSTALL_START=$(date +%s)

  detect_system_info
  is_trixie && msg_info "Debian 13 Trixie"
  is_armbian && msg_info "Armbian detected"
  [ "$MACHINE_EXPLICIT" = false ] && HA_MACHINE=$(detect_machine_type)
  msg_info "Platform: ${HA_MACHINE} (${CACHED_MACHINE_ARCH})"
  msg_info "os-release: ${CACHED_PRETTY_NAME} [ID=${CACHED_OS_ID}]"
  [ -n "$PROFILE" ]       && msg_info "Profile: ${PROFILE}"
  [ -n "$OPT_TIMEZONE" ]  && msg_info "Timezone: ${OPT_TIMEZONE}"
  [ -n "$OPT_DATA_DIR" ]  && msg_info "Data dir: ${OPT_DATA_DIR}"

  # Handle --from-step
  if [ -n "$FROM_STEP" ]; then
    local valid=false
    for s in "${ALL_STEPS[@]}"; do [ "$s" = "$FROM_STEP" ] && valid=true; done
    if [ "$valid" = false ]; then
      msg_error "Unknown step: ${FROM_STEP}"
      msg_info "Available: ${ALL_STEPS[*]}"
      exit 1
    fi
    msg_info "Resuming from: ${FROM_STEP}"
    local skip=true
    for s in "${ALL_STEPS[@]}"; do
      [ "$s" = "$FROM_STEP" ] && { skip=false; break; }
      if [ "$skip" = true ] && ! is_done "$s" 2>/dev/null; then
        mark_done "$s"
      fi
    done
  fi

  [ -f "$STATE_FILE" ] && show_progress

  # Protect from SSH disconnect during install
  trap '' HUP
  acquire_lock

  # === EXECUTE ALL STEPS ===
  run_step step_preflight          || { msg_error "Preflight failed!"; exit 1; }
  run_step step_update_system      || { ask_continue_on_error "update" "Update error" || exit 1; }
  run_step step_install_deps       || { ask_continue_on_error "deps" "Dependencies error" || exit 1; }
  run_step step_configure_network  || { msg_error "Network failed!"; exit 1; }
  run_step step_configure_apparmor || { ask_continue_on_error "apparmor" "AppArmor error" || exit 1; }
  run_step step_performance        || { ask_continue_on_error "perf" "Performance error" || exit 1; }
  run_step step_install_docker     || { msg_error "Docker failed!"; exit 1; }
  run_step step_resolve_versions   || { msg_error "Version resolution failed!"; exit 1; }
  run_step step_download_packages  || { msg_error "Download failed!"; exit 1; }
  run_step step_install_os_agent   || { msg_error "OS-Agent failed!"; exit 1; }
  run_step step_install_ha         || { msg_error "HA install failed!"; exit 1; }
  run_step step_security           || { ask_continue_on_error "security" "Security error" || exit 1; }
  run_step step_extras             || { ask_continue_on_error "extras" "Extras error" || exit 1; }
  run_step step_hacs               || { ask_continue_on_error "hacs" "HACS error" || exit 1; }
  run_step step_post_restore       || { ask_continue_on_error "restore" "Restore error" || exit 1; }

  show_final
}

main "$@"
