# MQTT Broker Settings
mqtt_addr="your_hassos_address"
mqtt_user="your_ha_mqtt_username"
mqtt_pass="your_ha_mqtt_password"
mqtt_port="1883"

# Device Information
manufacturer="Intel"
model_name="J4125 PVE Server"
node_name=$(hostname)
pve_version=$(pveversion)

# --- Disk & SMART Monitoring ---
# List of physical disks to monitor
disks=("/dev/sda" "/dev/disk/by-uuid/944418e8-64b4-4a4f-8b16-ef212b8262bb" "/dev/disk/by-uuid/ecb5a2ba-d053-4175-adea-52aa5c9b4e42")

# SMART Attributes to monitor (ID based)
# 9: Power On Hours, 12: Power Cycle Count, 194/190: Temperature,
# 5: Reallocated Sectors, 197: Pending Sector Count
smart_ids=(4 5 9 10 12 177 192 193 196 197 198 199 241)

# Interval in seconds to run the heavy SMART check (e.g. 3600 = 1 hour)
smart_interval=1800

# --- Storage & Mountpoints ---
# List of mountpoints to monitor for usage % and GB[cite: 1]
mountpoints=("/" "/home")

# Map path to display name
declare -A mnt_aliases
mnt_aliases["/"]="root"
mnt_aliases["/home"]="home"

# --- Network Monitoring ---
# Define the interfaces you want to track for bitrate calculation[cite: 1]
# Usually 'vmbr0' (bridge) and the physical NIC (e.g. 'eno1' or 'enp2s0')
# NOTE: MAC address of first interface is used as hw_addr
interfaces=("eno1" "vmbr0")

# Unique ID based on the first interface
hw_addr=$(cat /sys/class/net/${interfaces[0]}/address | tr -d ':')

# Home Assistant Discovery
discovery_prefix="homeassistant"
