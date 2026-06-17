# 📖 Full Documentation: SBC-HA-FORGE

**SBC-HA-FORGE** is a complex orchestrator designed to fully automate the installation of Home Assistant Supervised on Single Board Computers (SBCs) and TV-Boxes. The script takes over the entire preparation of the host system, bypasses hardware limitations, and configures security and backups.

---

## 📑 Table of Contents
1. [System Requirements](#-system-requirements)
2. [Installation & Quick Start](#-installation--quick-start)
3. [Installation Profiles](#-installation-profiles)
4. [Architecture & Internals (Under the Hood)](#-architecture--internals-under-the-hood)
5. [Command Line & Flags](#-command-line--flags)
6. [Modules Menu (Post-Install Features)](#-modules-menu-post-install-features)
7. [System Utilities](#-system-utilities)
8. [Troubleshooting (FAQ)](#-troubleshooting-faq)

---

## 📋 System Requirements

Home Assistant Supervised has strict requirements for the host system. The script checks these during the preflight stage.

*   **Architecture:** `x86_64` (Intel/AMD) or `aarch64` (ARM 64-bit). *(Installation on 32-bit armv7l is strictly blocked as HA no longer releases packages for it).*
*   **Operating System:** Debian 12 (Bookworm) or Debian 13 (Trixie). [Armbian](https://www.armbian.com/) is highly recommended.
*   **Linux Kernel:** **cgroups v2** is mandatory. Installation on kernels with cgroups v1 will abort with an error.
*   **RAM:** Minimum 1 GB (2 GB+ recommended).
*   **Storage:** Minimum 4 GB free space (10 GB+ recommended).
*   **Privileges:** Must be run as `root` (via `sudo`).

---

## 🚀 Installation & Quick Start

Run this single command in your device's terminal:

```bash
wget -qO install.sh https://raw.githubusercontent.com/iRespect777/HAS-tvbox/main/install.sh
sudo bash install.sh
```

After installation, the script copies itself to `/usr/local/bin/ha-install` and can be called from any directory.

### SSH Drop Protection
If your SSH session drops during installation (e.g., when switching to NetworkManager or during the AppArmor reboot), the script will continue running in the background via a systemd service.
To view the process:
1. Log back in via SSH.
2. Upon login, you will see a warning banner.
3. Enter the command to watch the live log:
   ```bash
   tail -f /var/log/ha_install_reboot.log
   ```

---

## 🎚 Installation Profiles

The interactive wizard offers 5 preset profiles and a manual selection:

| Profile | Description | Default Components |
| :--- | :--- | :--- |
| **minimal** | Only HA + Docker + OS-Agent. | Basic set, no optimizations. |
| **standard** | The sweet spot for most users. | UFW, Watchdog, Backups, HACS, ZRAM, SSH hardening. |
| **full** | Everything included. | Everything in `standard` + Tailscale, Cloudflare, Prometheus, remote backups. |
| **server** | For dedicated servers. | Static IP, monitoring, no Cloudflare. |
| **dev** | For developers. | HA + HACS, no system tweaks. |
| **custom** | Manual selection. | User manually checks required components. |

---

## ⚙️ Architecture & Internals (Under the Hood)

The script consists of 14 sequential steps (Steps), each of which can be resumed in case of a failure.

### 1. OS Restriction Bypass (`os-release`)
HA Supervised requires `ID=debian`. On Armbian/Ubuntu, the script:
- Backs up the original `/etc/os-release`.
- Creates a fake `os-release` with `ID=debian` during the `.deb` package installation.
- Creates a systemd drop-in for `hassio-supervisor.service` that swaps the file *only* while the Supervisor container is starting, leaving the host OS untouched.

### 2. Bootloader Patching (AppArmor)
AppArmor must be enabled in the kernel parameters. The script can find and patch:
- `armbianEnv.txt` / `uEnv.txt` (searches for `extraargs`, `optargs`, `APPEND`, or `rootflags`).
- `extlinux.conf` (searches for the `APPEND` line).
- `cmdline.txt` (Raspberry Pi, appends to the single line).
Arguments are appended **strictly to the continuation of the required line**, without line breaks, to avoid breaking the U-Boot bootloader.

### 3. Auto-Resume After Reboot
If a reboot is required to enable AppArmor:
- The script copies itself to `/usr/local/bin/ha-install`.
- It creates a systemd service `ha-install-continue.service`.
- It reboots the system.
- After booting, the service launches the script with the `--from-step=apparmor` flag.
- **Cycle Protection:** An attempt counter. If AppArmor doesn't enable after 3 reboots (due to a broken bootloader), the script skips it and continues the installation (HA will run in Unsupported mode).

### 4. Safe Network Configuration
Installing NetworkManager "on the fly" often breaks SSH. The script uses a trick:
- Before installing NM, it creates a `/usr/sbin/policy-rc.d` script that forbids APT from automatically starting services.
- NM is installed but not started.
- The script safely disables `ifupdown`, configures NM, and only then starts the network.
- In case of a critical network failure, `rollback_network` is called to restore old configs.

### 5. Smart Container Waiting
The `step_install_ha` doesn't just install the package; it waits for:
- The `hassio-supervisor` service to start.
- The sequential startup of 5 system containers (dns, cli, audio, multicast, observer) and `homeassistant` itself.
- If the Supervisor hangs during this process, the script restarts it.

---

## 💻 Command Line & Flags

The script supports automated (silent) installation via flags.

### Modes:
*   `--check` — System diagnostics (checks ports, Docker, AppArmor).
*   `--status` — Live terminal monitoring (RAM, CPU, containers).
*   `--update` — Updates OS-Agent and HA Supervised to the latest GitHub releases.
*   `--uninstall` — Uninstalls HA (Standard or Full mode).
*   `--rescue` — Rescue mode. Attempts to fix FS, network, Docker, and Supervisor.
*   `--benchmark` — Hardware test (CPU, RAM, Disk) with profile recommendation.
*   `--self-update` — Updates the `ha-install` script itself.
*   `--export-config` — Exports current settings to a script file.

### Installation Options:
*   `--profile <NAME>` — Specify profile (minimal, standard, full, server, dev).
*   `--silent` — Silent mode (no wizard).
*   `--auto-reboot` — Allows the script to reboot the system without prompting (for cron/systemd).
*   `--timezone <ZONE>` — E.g., `Europe/London`.
*   `--data-dir <PATH>` — Moves HA and Docker data to an external drive.
*   `--wifi <SSID> <PASSWORD>` — Wi-Fi configuration.
*   `--tailscale` / `--ts-authkey <KEY>` — Installs Tailscale with auto-authorization.
*   `--cloudflared` / `--cf-token <TOKEN>` — Configures Cloudflare Tunnel.

**Example of a silent Full profile install with auto-reboot:**
```bash
sudo ha-install --profile full --silent --auto-reboot
```

---

## 🧩 Modules Menu (Post-Install Features)

If you installed HA with the `minimal` profile and later decide to add features, do not reinstall the system. Run `sudo ha-install` and select `Install modules`.

Available modules:
- **ZRAM Swap** — RAM compression.
- **eMMC Tuning** — Reduces storage wear (noatime, journald limits).
- **Watchdog** — Restarts HA on hangups with exponential backoff.
- **Backups** — Local config backups + snapshots via HA CLI.
- **Remote Backup** — Sends backups via SSH (rsync) or to the cloud (rclone: Google Drive, Dropbox).
- **Notifications** — Setup Telegram, ntfy.sh, Discord, Slack.
- **HACS** — Custom integrations store.
- **Tailscale / Cloudflare** — VPN and public HTTPS access.
- **Security** — UFW + Docker isolation + SSH hardening.

---

## 🛠 System Utilities

The script generates several useful commands in `/usr/local/bin/`:

- `ha-health` — Prints a summary: IP, temperature, RAM, container status, and HA Web (8123) response code.
- `ha-backup` — Smart backup. If HA CLI is present, it makes a full snapshot. If not, it makes a fast tar of configs.
- `ha-restore` — Interactive restoration from a snapshot or tar archive.
- `ha-notify "text"` — Sends a notification (used by the script, but can be run manually).
- `ha-watchdog` — Pings and HTTP checks. Restarts the container if necessary.

---

## 🆘 Troubleshooting (FAQ)

**1. The APT log says: "Batch installation failed, trying one by one..."**
*Cause:* APT encountered a conflict (often due to NetworkManager or broken image dependencies).
*Solution:* The script automatically falls back to a one-by-one install and prints the last 5 lines of the APT log. If that fails too, check `/etc/apt/sources.list` for dead repositories.

**2. HA shows "Unsupported" status.**
*Cause:* The Supervisor expects HAOS. Since you are on Debian/Armbian, it flags the system as unsupported.
*Solution:* Ignore it. It does not affect automations or add-ons. If AppArmor is disabled, the script will also warn you about this.

**3. The machine went into a boot loop at the AppArmor step.**
*Cause:* The U-Boot bootloader ignores kernel arguments (extremely rare).
*Solution:* The script has protection — after 3 reboots, it will stop trying and continue without AppArmor. If it loops infinitely, reformat the boot partition and reinstall the bootloader.

**4. After a reboot, I can't tell if the script is running.**
*Solution:* Log in via SSH. If the script is working, you will see a red banner: "HA INSTALLER CONTINUES IN THE BACKGROUND". Run `tail -f /var/log/ha_install_reboot.log`.

**5. Docker doesn't see my USB dongle (Zigbee/Z-Wave).**
*Cause:* The machine type is set to `qemuarm-64`. For this type, the Supervisor restricts USB passthrough.
*Solution:* Reinstall HA explicitly specifying the machine type: `sudo ha-install --machine raspberrypi4-64` (if you have an RPi) or ensure the correct type is specified in the `config` file.
