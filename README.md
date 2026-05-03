# MQTT System Monitor for Proxmox and OMV

This repository provides lightweight Bash scripts to monitor **Proxmox VE** nodes or **OpenMediaVault (OMV)** servers and send the data to **Home Assistant** via MQTT.

The scripts utilize **Home Assistant MQTT Auto-Discovery**, meaning sensors will automatically appear as a new device in your Home Assistant dashboard without manual YAML configuration.

---
## Features

*   📊 **CPU & RAM:** Tracks usage percentage, load averages (1m, 5m, 15m), and detailed memory statistics (Used, Free, Total).
*   🌡️ **Temperature Monitoring:** Monitors CPU package, motherboard temperatures, and individual disk temperatures.
*   💾 **Disk & SMART:**
    *   Detailed SMART attributes (e.g., Power On Hours, SSD Life/Wearout, Reallocated Sectors).
    *   Storage usage monitoring for custom mountpoints.
*   🌐 **Network:** Calculates real-time bitrate (receive/transmit) for specified interfaces like `eth0` or `vmbr0`.
*   🚀 **Proxmox Specifics:** Tracks the number of running VMs and Containers, including a list of their names.
*   ⏱️ **System Status:** Reports uptime, fan speeds, and CMOS battery voltage.

---
## Prerequisites

Ensure the following packages are installed on your host:
```bash
apt update && apt install -y mosquitto-clients smartmontools lm-sensors dnsutils
```

Note: Some features like SMART data require `sudo` privileges for the user executing the script.

---
## Installation & Setup

1. Download the Files

Place the scripts for your specific system in a directory (e.g., `/root/scripts/`).

2. Configure Your Environment

The monitoring scripts rely on specific configuration files to load your MQTT credentials and device settings.
- For Proxmox: Edit proxmox_config.sh to include your MQTT broker details and disk list.
- For OMV: Edit omv_config.sh similarly.

3. Test the Script

Make the monitor scripts executable and run them manually once to trigger the Home Assistant discovery:
```bash
chmod +x proxmox_monitor.sh omv_monitor.sh
./proxmox_monitor.sh  # or ./omv_monitor.sh
```

---
## Automation (Cronjob)

To keep your data updated, add a cronjob to run the script every minute:
```bash
crontab -e
```

Add the following line:
```bash
#* * * * * /bin/bash /root/scripts/omv_monitor.sh > /dev/null 2>&1
* * * * * /bin/bash /root/scripts/proxmox_monitor.sh > /dev/null 2>&1
```

Adjust the path and filename according to your setup: `proxmox_monitor.sh` or `omv_monitor.sh`.

---
## File Structure

- `proxmox_config.sh` / `omv_config.sh`: User-defined settings (MQTT, Disks, Interfaces).
- `proxmox_monitor.sh` / `omv_monitor.sh`: The logic engine that gathers data and publishes to MQTT.

---
## How it Works

- No-Sleep Calculation: Bitrates and CPU usage are calculated using cached delta values to avoid script delays.
- Disk Health: To prevent unnecessary disk wake-ups, heavy SMART checks are performed at a configurable interval (default: 30 minutes).
- Auto-Discovery: Discovery payloads are sent to the homeassistant/ topic, allowing for instant integration.

---
## Security Warning

Your configuration files (proxmox_config.sh and omv_config.sh) contain sensitive MQTT passwords. Ensure these files are not committed to a public repository if they contain real credentials. It is recommended to use a .gitignore file.
