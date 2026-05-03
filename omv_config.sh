# MQTT Broker Settings
mqtt_addr="your_hassos_address"
mqtt_user="your_ha_mqtt_username"
mqtt_pass="your_ha_mqtt_password"
mqtt_port="1883"

# Device Information
manufacturer="Intel"
model_name="J4125 PVE Server"
node_name=$(hostname)
omv_version=$(dpkg-query -W -f='${Version}' openmediavault)

# --- Disk & SMART Monitoring ---
# List of physical disks to monitor
disks=()

# SMART Attributes to monitor (ID based)
# 9: Power On Hours, 12: Power Cycle Count, 194/190: Temperature,
# 5: Reallocated Sectors, 197: Pending Sector Count
smart_ids=()

# Interval in seconds to run the heavy SMART check (e.g. 3600 = 1 hour)
smart_interval=1800

# --- Storage & Mountpoints ---
# List of mountpoints to monitor for usage % and GB[cite: 1]
mountpoints=("/" "/srv/dev-disk-by-uuid-ecb5a2ba-d053-4175-adea-52aa5c9b4e42" "/srv/dev-disk-by-uuid-944418e8-64b4-4a4f-8b16-ef212b8262bb")

# Map path to display name
declare -A mnt_aliases
mnt_aliases["/"]="root"
mnt_aliases["/srv/dev-disk-by-uuid-ecb5a2ba-d053-4175-adea-52aa5c9b4e42"]="Data"
mnt_aliases["/srv/dev-disk-by-uuid-944418e8-64b4-4a4f-8b16-ef212b8262bb"]="Backup"

# --- Network Monitoring ---
# Define the interfaces you want to track for bitrate calculation[cite: 1]
# Usually 'vmbr0' (bridge) and the physical NIC (e.g. 'eno1' or 'enp2s0')
# NOTE: MAC address of first interface is used as hw_addr
interfaces=("ens18")

# Unique ID based on the first interface
hw_addr=$(cat /sys/class/net/${interfaces[0]}/address | tr -d ':')

# Home Assistant Discovery
discovery_prefix="homeassistant"
