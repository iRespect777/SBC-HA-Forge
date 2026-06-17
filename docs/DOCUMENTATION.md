---

# 🇷🇺 Полная техническая документация (Русская версия)

## Оглавление
1. [Архитектура и система состояния (State Machine)](#1-архитектура-и-система-состояния)
2. [Требования и подготовка среды](#2-требования-и-подготовка-среды)
3. [Матрица профилей установки](#3-матрица-профилей-установки)
4. [Параметры командной строки (CLI)](#4-параметры-командной-строки-cli)
5. [Глубокий анализ: Сеть и NetworkManager](#5-глубокий-анализ-сеть-и-networkmanager)
6. [Глубокий анализ: Подмена `os-release`](#6-глубокий-анализ-подмена-os-release)
7. [Глубокий анализ: AppArmor и загрузчик](#7-глубокий-анализ-apparmor-и-загрузчик)
8. [Менеджер бэкапов: Логика работы](#8-менеджер-бэкапов-логика-работы)
9. [Модули, Утилиты и Cron](#9-модули-утилиты-и-cron)
10. [Система уведомлений (Webhooks)](#10-система-уведомлений-webhooks)
11. [Удаление и откаты (Rollbacks)](#11-удаление-и-откаты-rollbacks)

---

### 1. Архитектура и система состояния
Скрипт не является линейным bash-файлом. Это **идемпотентный конечный автомат** (State Machine).

- **Файл состояния:** `/var/lib/ha-installer/state`.
- **Формат:** `[имя_шага]|[unix_timestamp]|[версия_скрипта]` (например, `docker|1715600000|20.9.996`).
- **Логика:** Перед выполнением шага (например, `step_install_docker`) вызывается функция `is_done "docker"`. Если шаг уже отмечен как выполненный в файле состояния, скрипт его пропускает. 
- **Обновление скрипта:** Если версия скрипта в файле состояния не совпадает с текущей версией, шаг считается устаревшим и будет выполнен заново (для применения новых настроек).
- **Блокировки (Locks):** Используется `flock` на файле `/var/lock/ha_install.lock` (fd 200). Это предотвращает параллельный запуск двух экземпляров скрипта.
- **Откаты (Rollbacks):** В скрипте реализован массив `ROLLBACK_ACTIONS`. Перед опасной операцией (например, установка Docker) скрипт пушит в массив команду удаления (`apt-get remove -y docker-ce`). Если на любом из следующих шагов происходит критическая ошибка (или нажат Ctrl+C), срабатывает триггер `cleanup`, который выполняет команды отката в обратном порядке.

### 2. Требования и подготовка среды
- **ОС:** Armbian (Bookworm/Trixie) или чистый Debian 11/12/13.
- **Архитектура:** `aarch64` или `x86_64` (ARMv7 вызовет ошибку на этапе `preflight`, так как HA Supervised требует 64 бита).
- **Тест железа (`do_benchmark`):** Скрипт проверяет скорость диска через `dd if=/dev/zero`, объем RAM и ядра CPU. При RAM < 1GB установка прервется. При RAM < 1.5GB будет рекомендован профиль `minimal` и Swap-файл.

### 3. Матрица профилей установки
В скрипте жестко зашиты 5 профилей. Ниже представлена матрица включенных компонентов (`true`/`false`) для каждого из них:

| Компонента | minimal | standard | full | server | dev |
|------------|---------|----------|------|--------|-----|
| ZRAM Swap | ✅ | ✅ | ✅ | ✅ | ❌ |
| eMMC Tuning | ❌ | ✅ | ✅ | ✅ | ❌ |
| UFW (Firewall) | ❌ | ✅ | ✅ | ✅ | ❌ |
| SSH Hardening | ❌ | ✅ | ✅ | ✅ | ❌ |
| Watchdog | ❌ | ✅ | ✅ | ✅ | ❌ |
| Auto-Updates | ❌ | ✅ | ✅ | ✅ | ❌ |
| Backups | ❌ | ✅ | ✅ | ✅ | ❌ |
| HACS | ❌ | ✅ | ✅ | ✅ | ✅ |
| Monitoring | ❌ | ❌ | ✅ | ✅ | ❌ |
| Tailscale | ❌ | ❌ | ✅ | ✅ | ❌ |
| Cloudflare | ❌ | ❌ | ✅ | ❌ | ❌ |
| Static IP | ❌ | ❌ | ❌ | ✅ | ❌ |

### 4. Параметры командной строки (CLI)
Для автоматизации (Headless) доступны следующие флаги:
- `--profile <ИМЯ>`: Указание профиля.
- `--machine <ТИП>`: Принудительная установка типа машины HA (по умолчанию авто-детекция: `generic-x86-64`, `raspberrypi4-64`, `qemuarm-64` и т.д.).
- `--data-dir <ПУТЬ>`: Перенос `/usr/share/hassio` и `/var/lib/docker` на внешний диск. Скрипт проверит ФС (ext4/btrfs) и свободное место (>10GB).
- `--swap <РАЗМЕР|zram|none>`: Настройка Swap. Если указано число — создаст файл через `dd` и пропишет в `/etc/fstab`.
- `--from-step <ШАГ>`: Ручное продолжение установки с определенного шага (используется internally после ребута).
- `--import-config <ФАЙЛ>`: Импорт ранее сохраненного конфига (профиль, токены, IP) для идентичного развертывания на других устройствах.
- `--dry-run`: Режим симуляции. Команды `apt`, `dpkg`, `docker` не выполняются, а только выводятся на экран.

### 5. Глубокий анализ: Сеть и NetworkManager
Переключение сети на TV-боксах — самая частая причина "окирпичивания". Скрипт решает это так:
1. **Бэкап:** Сохраняются `/etc/network/interfaces` и `/etc/resolv.conf`.
2. **Блокировка автозапуска:** Перед `apt-get install network-manager` создается временный файл `/usr/sbin/policy-rc.d`, который запрещает dpkg автоматически запускать любые сервисы (exit 101). Это предотвращает захват сети NM до его настройки.
3. **Настройка NM:** Создаются конфиги в `/etc/NetworkManager/conf.d/`, отключающие конфликт с `ifupdown`.
4. **Переключение:** Сервис `networking` отключается, NM запускается. Скрипт ждет получения IP 30 секунд.
5. **Откат (Rollback):** Если IP не получен, скрипт:
   - Останавливает NM.
   - Восстанавливает `interfaces.bak`.
   - Включает `ifupdown` и делает `ifup <iface>`.
   - Если и это не помогает, дергает `dhclient` напрямую.
6. **Static IP:** Применяется через `nmcli con mod` к активному UUID подключения. Изменение применяется "на лету" без обрыва текущей SSH-сессии.

### 6. Глубокий анализ: Подмена `os-release`
HA Supervised требует `ID=debian` в `/etc/os-release`. Armbian имеет `ID=armbian`.
1. Скрипт определяет целевой кодовое имя (bookworm/trixie).
2. Сохраняет оригинальный файл в `/var/lib/ha-installer/backup/os-release.original`.
3. Создает поддельный `os-release` с `ID=debian` и нужным `VERSION_CODENAME`.
4. **Systemd Drop-in:** Создается файл `/etc/systemd/system/hassio-supervisor.service.d/fix-os-release.conf`.
   - `ExecStartPre`: Перед запуском Supervisor копирует фейковый `os-release` в `/etc/`.
   - `ExecStopPost`: После остановки Supervisor восстанавливает оригинальный `os-release`.
   *Итог: Система думает, что она Armbian, а HA Supervisor видит чистый Debian.*

### 7. Глубокий анализ: AppArmor и загрузчик
HA требует AppArmor в ядре. На многих боксах он отключен.
1. Читается `/sys/module/apparmor/parameters/enabled`. Если `N`, начинается патчинг.
2. Скрипт ищет конфиги загрузчика: `armbianEnv.txt` (Armbian), `extlinux.conf` (GRUB/U-Boot), `cmdline.txt` (Raspberry Pi).
3. В зависимости от формата, дописывает `apparmor=1 security=apparmor`:
   - В `extlinux`: в конец строки `APPEND`.
   - В `armbianEnv`: в переменную `extraargs=` (или `optargs=`, `APPEND=`).
4. **Авто-продолжение:** Если выбран `--auto-reboot`, скрипт создает systemd-oneshot сервис `ha-install-continue.service`. Этот сервис запускается при старте системы, удаляет сам себя и запускает скрипт с флагом `--from-step=apparmor`.
   Защита от зацикливания: файл `/var/lib/ha-installer/reboot_attempts` ограничивает количество автоперезагрузок тремя.

### 8. Менеджер бэкапов: Логика работы
Скрипт `/usr/local/bin/ha-backup` работает в двух режимах:
1. **Полный снапшот (если доступен HA CLI):**
   - Вызывает `ha backups new --name AutoBackup_...`.
   - Парсит JSON через `jq`, оставляет последние 5 снапшотов, старые удаляет через `ha backups remove`.
2. **Быстрый TAR-бэкап (fallback):**
   - Определяет путь к `/config` внутри контейнера через `docker inspect`.
   - Создает архив через `tar` (с `pigz` для многопоточного сжатия, если установлен).
   - Исключает: `*.db`, `*.db-shm`, `tts/`, `deps/`, `__pycache__/`.
3. **Удаленный бэкап:**
   - Скрипт `/usr/local/bin/ha-backup-remote` берет последний созданный бэкап.
   - Если цель `ssh://`, использует `rsync -avz --partial`.
   - Если цель `rclone://`, проверяет наличие профиля в `rclone listremotes` и выполняет `rclone copy`.

### 9. Модули, Утилиты и Cron
Установленные в `/usr/local/bin/` скрипты автоматически интегрируются в систему. В `/etc/cron.d/ha-tools` генерируются следующие задачи:
- `*/5 * * * *` — `ha-watchdog` (пинг 8123, рестарт контейнера при падении с экспоненциальной задержкой: 5м, 10м, 20м... до 60м).
- `*/10 * * * *` — `ha-net-recovery` (пинг шлюза, рестарт NetworkManager).
- `*/5 * * * *` — `ha-thermal` (проверка температуры, алерт при >80C).
- `0 4 * * 0` — `ha-backup` (каждое воскресенье в 04:00).
- `30 4 * * 0` — `ha-backup-remote` (в 04:30 воскресенья).
- `* * * * *` — `ha-metrics` (каждую минуту обновляет метрики Prometheus).
- `0 9 * * 1` — `ha-weekly-report` (отчет по понедельникам).
- `30 3 * * *` — `ha-cleanup` (очистка Docker образов и логов systemd).

### 10. Система уведомлений (Webhooks)
Скрипт `_send_webhook` умеет адаптировать формат запроса под конкретный сервис:
- **ntfy.sh:** Отправляет Plain Text в Body, добавляет заголовки `Title`, `Priority`, `Tags`.
- **Discord/Slack:** Формирует JSON `{"content": "..."}` (Discord) или `{"text": "..."}` (Slack). Экранирует спецсимволы через `sed` (`s/\\/\\\\/g; s/"/\\"/g`).
- **Gotify:** Отправляет JSON с полями `title`, `message`, `priority`.
- **Unknown URL:** Сначала пробует Plain Text. Если сервер отвечает не `2xx`, повторяет запрос в JSON формате `{"text":"..."}`.
- **Rate Limiting:** Уведомления не отправляются чаще, чем раз в 30 секунд (файл `/tmp/.ha_notify_rate`).

### 11. Удаление и откаты (Rollbacks)
Команда `sudo ha-install --uninstall` предлагает два пути:
1. **Standard:** 
   - `dpkg --purge homeassistant-supervised os-agent`
   - Удаляет контейнеры HA (`docker rm -f`) и образы (`docker rmi -f`).
   - Удаляет сгенерированные скрипты из `/usr/local/bin/` и правила UFW/Fail2Ban.
   - Восстанавливает оригинальный `os-release`.
   - Docker и NetworkManager остаются нетронутыми.
2. **Full:**
   - Выполняет все шаги Standard.
   - Полностью удаляет Docker CE (`apt-get purge docker-ce`), папки `/var/lib/docker` и `/usr/share/hassio`.
   - Восстанавливает `ifupdown` и оригинальный `/etc/network/interfaces`.
   - Чистит параметры AppArmor из загрузчика.
   - Возвращает оригинальное имя хоста.
   - Выводит список установленных зависимостей (curl, jq, ufw и т.д.), чтобы пользователь мог удалить их вручную через `apt autoremove`.

---
---

# 🇬🇧 Full Technical Documentation (English Version)

## Table of Contents
1. [Architecture and State Machine](#1-architecture-and-state-machine)
2. [Requirements and Environment Preparation](#2-requirements-and-environment-preparation)
3. [Installation Profiles Matrix](#3-installation-profiles-matrix)
4. [Command Line Interface (CLI) Arguments](#4-command-line-interface-cli-arguments)
5. [Deep Dive: Network and NetworkManager](#5-deep-dive-network-and-networkmanager)
6. [Deep Dive: `os-release` Faking](#6-deep-dive-os-release-faking)
7. [Deep Dive: AppArmor and Bootloader](#7-deep-dive-apparmor-and-bootloader)
8. [Backup Manager: Logic and Execution](#8-backup-manager-logic-and-execution)
9. [Modules, Utilities, and Cron](#9-modules-utilities-and-cron)
10. [Notification System (Webhooks)](#10-notification-system-webhooks)
11. [Uninstallation and Rollbacks](#11-uninstallation-and-rollbacks)

---

### 1. Architecture and State Machine
The script is not a linear bash file. It is an **idempotent State Machine**.
- **State File:** `/var/lib/ha-installer/state`.
- **Format:** `[step_name]|[unix_timestamp]|[script_version]` (e.g., `docker|1715600000|20.9.996`).
- **Logic:** Before executing a step (e.g., `step_install_docker`), the `is_done "docker"` function is called. If the step is already marked as done in the state file, the script skips it.
- **Script Updates:** If the script version in the state file doesn't match the current version, the step is considered outdated and will be executed again (to apply new configurations).
- **Locks:** Uses `flock` on `/var/lock/ha_install.lock` (fd 200). This prevents two instances of the script from running simultaneously.
- **Rollbacks:** The script implements a `ROLLBACK_ACTIONS` array. Before a dangerous operation (e.g., installing Docker), the script pushes the removal command (`apt-get remove -y docker-ce`) into the array. If a critical error occurs on any subsequent step (or Ctrl+C is pressed), the `cleanup` trap is triggered, executing rollback commands in reverse order.

### 2. Requirements and Environment Preparation
- **OS:** Armbian (Bookworm/Trixie) or pure Debian 11/12/13.
- **Architecture:** `aarch64` or `x86_64` (ARMv7 will fail at the `preflight` stage as HA Supervised requires 64-bit).
- **Hardware Benchmark (`do_benchmark`):** The script checks disk speed via `dd if=/dev/zero`, RAM size, and CPU cores. If RAM < 1GB, installation aborts. If RAM < 1.5GB, the `minimal` profile and a Swap file are recommended.

### 3. Installation Profiles Matrix
There are 5 hardcoded profiles. Below is the matrix of enabled components (`true`/`false`) for each:

| Component | minimal | standard | full | server | dev |
|-----------|---------|----------|------|--------|-----|
| ZRAM Swap | ✅ | ✅ | ✅ | ✅ | ❌ |
| eMMC Tuning | ❌ | ✅ | ✅ | ✅ | ❌ |
| UFW (Firewall) | ❌ | ✅ | ✅ | ✅ | ❌ |
| SSH Hardening | ❌ | ✅ | ✅ | ✅ | ❌ |
| Watchdog | ❌ | ✅ | ✅ | ✅ | ❌ |
| Auto-Updates | ❌ | ✅ | ✅ | ✅ | ❌ |
| Backups | ❌ | ✅ | ✅ | ✅ | ❌ |
| HACS | ❌ | ✅ | ✅ | ✅ | ✅ |
| Monitoring | ❌ | ❌ | ✅ | ✅ | ❌ |
| Tailscale | ❌ | ❌ | ✅ | ✅ | ❌ |
| Cloudflare | ❌ | ❌ | ✅ | ❌ | ❌ |
| Static IP | ❌ | ❌ | ❌ | ✅ | ❌ |

### 4. Command Line Interface (CLI) Arguments
For headless automation, the following flags are available:
- `--profile <NAME>`: Specify profile.
- `--machine <TYPE>`: Force HA machine type (default is auto-detected: `generic-x86-64`, `raspberrypi4-64`, `qemuarm-64`, etc.).
- `--data-dir <PATH>`: Moves `/usr/share/hassio` and `/var/lib/docker` to an external drive. The script verifies the FS (ext4/btrfs) and free space (>10GB).
- `--swap <SIZE|zram|none>`: Configure Swap. If a number is provided, it creates a file via `dd` and adds it to `/etc/fstab`.
- `--from-step <STEP>`: Manually resume installation from a specific step (used internally after reboots).
- `--import-config <FILE>`: Import a previously saved config (profile, tokens, IP) for identical deployment on other devices.
- `--dry-run`: Simulation mode. Commands like `apt`, `dpkg`, `docker` are printed to the screen but not executed.

### 5. Deep Dive: Network and NetworkManager
Switching network managers on TV-boxes is the most common cause of "bricking". The script handles this as follows:
1. **Backup:** Saves `/etc/network/interfaces` and `/etc/resolv.conf`.
2. **Autostart Block:** Before `apt-get install network-manager`, a temporary file `/usr/sbin/policy-rc.d` is created, forbidding dpkg from automatically starting any services (exit 101). This prevents NM from taking over the network before it's configured.
3. **NM Configuration:** Config files are created in `/etc/NetworkManager/conf.d/` to disable conflicts with `ifupdown`.
4. **Switchover:** The `networking` service is stopped, NM is started. The script waits 30 seconds for an IP address.
5. **Rollback:** If no IP is obtained, the script:
   - Stops NM.
   - Restores `interfaces.bak`.
   - Enables `ifupdown` and runs `ifup <iface>`.
   - If that fails, it invokes `dhclient` directly.
6. **Static IP:** Applied via `nmcli con mod` to the active connection UUID. Changes are applied "on the fly" without dropping the current SSH session.

### 6. Deep Dive: `os-release` Faking
HA Supervised requires `ID=debian` in `/etc/os-release`. Armbian has `ID=armbian`.
1. The script determines the target codename (bookworm/trixie).
2. Saves the original file to `/var/lib/ha-installer/backup/os-release.original`.
3. Creates a fake `os-release` with `ID=debian` and the correct `VERSION_CODENAME`.
4. **Systemd Drop-in:** Creates `/etc/systemd/system/hassio-supervisor.service.d/fix-os-release.conf`.
   - `ExecStartPre`: Before starting Supervisor, copies the fake `os-release` to `/etc/`.
   - `ExecStopPost`: After stopping Supervisor, restores the original `os-release`.
   *Result: The system knows it's Armbian, but HA Supervisor sees pure Debian.*

### 7. Deep Dive: AppArmor and Bootloader
HA requires AppArmor in the kernel. On many boxes, it's disabled.
1. Reads `/sys/module/apparmor/parameters/enabled`. If `N`, patching begins.
2. The script searches for bootloader configs: `armbianEnv.txt` (Armbian), `extlinux.conf` (GRUB/U-Boot), `cmdline.txt` (Raspberry Pi).
3. Depending on the format, it appends `apparmor=1 security=apparmor`:
   - In `extlinux`: to the end of the `APPEND` line.
   - In `armbianEnv`: to the `extraargs=` variable (or `optargs=`, `APPEND=`).
4. **Auto-continuation:** If `--auto-reboot` is selected, the script creates a systemd-oneshot service `ha-install-continue.service`. This service starts on boot, deletes itself, and launches the script with the `--from-step=apparmor` flag.
   Loop protection: The file `/var/lib/ha-installer/reboot_attempts` limits auto-reboots to three attempts.

### 8. Backup Manager: Logic and Execution
The `/usr/local/bin/ha-backup` script operates in two modes:
1. **Full Snapshot (if HA CLI is available):**
   - Calls `ha backups new --name AutoBackup_...`.
   - Parses JSON via `jq`, keeps the last 5 snapshots, and deletes older ones via `ha backups remove`.
2. **Fast TAR Backup (fallback):**
   - Determines the path to `/config` inside the container using `docker inspect`.
   - Creates an archive via `tar` (using `pigz` for multithreaded compression if installed).
   - Excludes: `*.db`, `*.db-shm`, `tts/`, `deps/`, `__pycache__/`.
3. **Remote Backup:**
   - The `/usr/local/bin/ha-backup-remote` script takes the latest created backup.
   - If the target is `ssh://`, it uses `rsync -avz --partial`.
   - If the target is `rclone://`, it checks for the profile in `rclone listremotes` and executes `rclone copy`.

### 9. Modules, Utilities, and Cron
Scripts installed in `/usr/local/bin/` integrate automatically. The following tasks are generated in `/etc/cron.d/ha-tools`:
- `*/5 * * * *` — `ha-watchdog` (pings 8123, restarts container on failure with exponential backoff: 5m, 10m, 20m... up to 60m).
- `*/10 * * * *` — `ha-net-recovery` (pings gateway, restarts NetworkManager).
- `*/5 * * * *` — `ha-thermal` (checks temp, alerts if >80C).
- `0 4 * * 0` — `ha-backup` (every Sunday at 04:00).
- `30 4 * * 0` — `ha-backup-remote` (Sunday at 04:30).
- `* * * * *` — `ha-metrics` (updates Prometheus metrics every minute).
- `0 9 * * 1` — `ha-weekly-report` (report on Mondays).
- `30 3 * * *` — `ha-cleanup` (cleans Docker images and systemd journals).

### 10. Notification System (Webhooks)
The `_send_webhook` script adapts the request format for specific services:
- **ntfy.sh:** Sends Plain Text in Body, adds `Title`, `Priority`, `Tags` headers.
- **Discord/Slack:** Forms JSON `{"content": "..."}` (Discord) or `{"text": "..."}` (Slack). Escapes special characters via `sed` (`s/\\/\\\\/g; s/"/\\"/g`).
- **Gotify:** Sends JSON with `title`, `message`, `priority` fields.
- **Unknown URL:** Tries Plain Text first. If the server responds with non-`2xx`, retries the request in JSON format `{"text":"..."}`.
- **Rate Limiting:** Notifications are not sent more than once every 30 seconds (file `/tmp/.ha_notify_rate`).

### 11. Uninstallation and Rollbacks
The `sudo ha-install --uninstall` command offers two paths:
1. **Standard:**
   - `dpkg --purge homeassistant-supervised os-agent`
   - Removes HA containers (`docker rm -f`) and images (`docker rmi -f`).
   - Removes generated scripts from `/usr/local/bin/` and UFW/Fail2Ban rules.
   - Restores the original `os-release`.
   - Docker and NetworkManager remain untouched.
2. **Full:**
   - Executes all Standard steps.
   - Completely purges Docker CE (`apt-get purge docker-ce`), folders `/var/lib/docker` and `/usr/share/hassio`.
   - Restores `ifupdown` and the original `/etc/network/interfaces`.
   - Cleans AppArmor parameters from the bootloader.
   - Reverts the original hostname.
   - Outputs a list of installed dependencies (curl, jq, ufw, etc.) so the user can manually remove them via `apt autoremove`.
