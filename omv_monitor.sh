#!/bin/bash
export LC_NUMERIC=C

# --- CONFIGURATION LOADING ---
# Get the directory where the script is located
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# Load configuration from the same directory as the script
if [ -f "$SCRIPT_DIR/omv_config.sh" ]; then
    . "$SCRIPT_DIR/omv_config.sh"
else
    echo "Error: omv_config.sh not found in $SCRIPT_DIR. Please create it first."
    exit 1
fi

# File to track if discovery was already sent
PUBLISHED_FILE="/tmp/omv_mqtt.published"

# File to track when SMART was already checked
SMART_CACHE="/tmp/omv_smart.lastrun"

# Paths for caching stats to avoid 'sleep'
CPU_CACHE="/tmp/omv_cpu.cache"
NET_CACHE="/tmp/omv_net.cache"

# Suffix for diagnostic topics
diag_opt=',"ent_cat":"diagnostic"'


## Function to publish MQTT messages with Home Assistant Auto-Discovery
## $1: group (e.g. 'System'), $2: name (e.g. 'CPU_Temp'), $3: state, $4: options (JSON string)
mqtt_publish() {
    local raw_group="$1"  # Can now be "Disk sda"
    local raw_name="$2"   # Can now be "Power On Hours"
    local state="$3"
    local options="$4"

    # 1. Technical IDs: Replace spaces with underscores for MQTT topics and Unique IDs
    local group_id="${raw_group// /_}"
    local entity_id="${raw_name// /_}"

    # 2. Friendly Names: Keep spaces for Home Assistant UI display
    local friendly_name="$raw_name"
    local friendly_group="$raw_group"

    local device_id="omv_${node_name}_${hw_addr}"
    local unique_id="${device_id}_${group_id}_${entity_id}"

    # Define MQTT Topics using underscored IDs
    local config_topic="${discovery_prefix}/sensor/${device_id}/${group_id}_${entity_id}/config"
    local state_topic="omv/${node_name}_${hw_addr}/${group_id}/${entity_id}/state"

    # Send Discovery Payload if not already sent
    if [[ ! -f "$PUBLISHED_FILE" ]] || ! grep -q "$unique_id" "$PUBLISHED_FILE" 2>/dev/null; then
        local json_data="{"
        json_data+="\"name\":\"${friendly_group} ${friendly_name}\","
        json_data+="\"stat_t\":\"${state_topic}\","
        json_data+="\"uniq_id\":\"${unique_id}\","
        json_data+="${options},"
        json_data+="\"dev\":{\"ids\":[\"${device_id}\"],\"name\":\"${node_name}\",\"mdl\":\"${model_name}\",\"mf\":\"${manufacturer}\",\"sn\":\"${hw_addr}\",\"sw\":\"${omv_version}\"}"
        json_data+="}"

        mosquitto_pub -h "$mqtt_addr" -p "$mqtt_port" -u "$mqtt_user" -P "$mqtt_pass" -t "$config_topic" -m "$json_data" -r
        echo "$unique_id" >> "$PUBLISHED_FILE"
        sleep 1
    fi

    # Always publish the actual state
    mosquitto_pub -h "$mqtt_addr" -p "$mqtt_port" -u "$mqtt_user" -P "$mqtt_pass" -t "$state_topic" -m "$state"
}

# --- 1. CPU USAGE (Cached, no sleep) ---
# Read current stats from /proc/stat
read -r _ c_user c_nice c_system c_idle c_iowait c_irq c_softirq _ < /proc/stat
curr_total=$((c_user + c_nice + c_system + c_idle + c_iowait + c_irq + c_softirq))
curr_idle=$((c_idle + c_iowait))

if [[ -f "$CPU_CACHE" ]]; then
    read -r prev_total prev_idle < "$CPU_CACHE"
    diff_total=$((curr_total - prev_total))
    diff_idle=$((curr_idle - prev_idle))

    if (( diff_total > 0 )); then
        cpu_usage_perc=$(( 100 * (diff_total - diff_idle) / diff_total ))
        mqtt_publish "CPU" "usage" "$cpu_usage_perc" '"ic":"mdi:cpu-64-bit","unit_of_meas":"%","stat_cla":"measurement"'
    fi
fi
echo "$curr_total $curr_idle" > "$CPU_CACHE"


# --- 2. CPU LOAD (1m, 5m, 15m) ---
# Load is useful to see system saturation. 1.0 on a 4-core J4125 means 25% average load.
read -r load_1m load_5m load_15m _ < /proc/loadavg
mqtt_publish "CPU" "load 1m" "$load_1m" '"ic":"mdi:cpu-64-bit","stat_cla":"measurement"'
mqtt_publish "CPU" "load 5m" "$load_5m" '"ic":"mdi:cpu-64-bit","stat_cla":"measurement"'
mqtt_publish "CPU" "load 15m" "$load_15m" '"ic":"mdi:cpu-64-bit","stat_cla":"measurement"'

# --- 3. RAM MONITORING (Optimized parsing) ---
# Read meminfo into variables using a while loop to avoid multiple greps
while read -r line; do
    case "$line" in
        MemTotal:*) mem_total_kb=${line//[^0-9]/} ;;
        MemAvailable:*) mem_avail_kb=${line//[^0-9]/} ;;
    esac
done < /proc/meminfo

# Calculate values using a single awk call for precision
read mem_perc mem_used_gb mem_free_gb mem_total_gb <<< $(awk -v tot=$mem_total_kb -v av=$mem_avail_kb \
    'BEGIN {printf "%.0f %.2f %.2f %.2f", (tot-av)*100/tot, (tot-av)/1048576, av/1048576, tot/1048576}')

mqtt_publish "RAM" "usage" "$mem_perc" '"ic":"mdi:memory","unit_of_meas":"%","stat_cla":"measurement"'
mqtt_publish "RAM" "used" "$mem_used_gb" '"ic":"mdi:memory","unit_of_meas":"GB","stat_cla":"measurement"'
mqtt_publish "RAM" "free" "$mem_free_gb" '"ic":"mdi:memory","unit_of_meas":"GB","stat_cla":"measurement"'
mqtt_publish "RAM" "total" "$mem_total_gb" '"ic":"mdi:memory","unit_of_meas":"GB","stat_cla":"measurement"'$diag_opt

# --- 4. NETWORK BITRATE (Cached Delta) ---
curr_time=$(date +%s)
net_dev_raw=$(< /proc/net/dev)
declare -A prev_net
new_cache_content=""

# Load all previous net stats into an associative array
if [[ -f "$NET_CACHE" ]]; then
    while read -r if_name p_time p_rx p_tx || [[ -n "$if_name" ]]; do
        # SKIP empty lines or malformed entries to prevent "Falscher Feldindex"
        [[ -z "$if_name" ]] && continue

        prev_net["$if_name"]="$p_time $p_rx $p_tx"
    done < "$NET_CACHE"
fi

for iface in "${interfaces[@]}"; do
    # Efficiently extract Rx (col 2) and Tx (col 10) for the interface
    read -r c_rx c_tx <<< $(echo "$net_dev_raw" | awk -v iface="$iface" '$1 ~ "^"iface":" {print $2, $10}')

    if [[ -n "$c_rx" && -n "$c_tx" ]]; then
        if [[ -n "${prev_net[$iface]}" ]]; then
            read -r p_time p_rx p_tx <<< "${prev_net[$iface]}"
            time_diff=$((curr_time - p_time))

            if (( time_diff > 0 )); then
                read rx_mbit tx_mbit <<< $(awk -v crx=$c_rx -v prx=$p_rx -v ctx=$c_tx -v ptx=$p_tx -v td=$time_diff \
                    'BEGIN {printf "%.2f %.2f", (crx-prx)*8/td, (ctx-ptx)*8/td}')

                mqtt_publish "Net $iface" "receive" "$rx_mbit" '"ic":"mdi:download-network","unit_of_meas":"bit/s","stat_cla":"measurement"'
                mqtt_publish "Net $iface" "transmit" "$tx_mbit" '"ic":"mdi:upload-network","unit_of_meas":"bit/s","stat_cla":"measurement"'
            fi
        fi
        # Collect new data for cache
        new_cache_content+="$iface $curr_time $c_rx $c_tx\n"
    fi
done
echo -ne "$new_cache_content" > "$NET_CACHE"

# --- 5. DISK SMART & TEMPERATURE ---
# Check if SMART interval has passed
LAST_SMART_RUN=$(cat "$SMART_CACHE" 2>/dev/null || echo 0)
DO_SMART=false
(( curr_time - LAST_SMART_RUN > smart_interval )) && DO_SMART=true && echo "$curr_time" > "$SMART_CACHE"

for dev in "${disks[@]}"; do
    # Find parent device (e.g., sda1 -> sda)
    real_path=$(readlink -f "$dev")
    parent_dev=$(lsblk -no pkname "$real_path" | head -n1)
    [[ -z "$parent_dev" ]] && parent_dev=$(lsblk -no kname "$real_path" | head -n1)

    # Check if disk is SSD or HDD
    [[ $(cat "/sys/block/$parent_dev/queue/rotational") == "0" ]] && disk_type="SSD" || disk_type="HDD"

    if [ "$DO_SMART" = true ]; then
        # Fetch SMART data (requires sudo)
        smart_raw=$(sudo smartctl -A -H -n standby "/dev/$parent_dev" 2>/dev/null)

        if [[ "$smart_raw" == *"PASSED"* ]]; then
            health_val="OK"
        elif [[ "$smart_raw" == *"FAILED"* ]]; then
            health_val="ALARM"
        else
            health_val="Unknown"
        fi

        mqtt_publish "$disk_type $parent_dev" "health" "$health_val" '"ic":"mdi:heart-pulse"'$diag_opt

        # Loop through your defined IDs
        for id in "${smart_ids[@]}"; do
            # Use awk to find the line starting with the ID and extract name (col 2) and raw value (col 10)
            line=$(echo "$smart_raw" | awk -v id="$id" '$1 == id {print $2, $10}')
            if [[ -n "$line" ]]; then
                read attr_name raw_val <<< "$line"
                friendly_attr="${attr_name//_/ }"
                # Define icons/units based on ID
                case "$id" in
                    9)   opts='"ic":"mdi:timer-outline","unit_of_meas":"h","stat_cla":"measurement"' ;;
                    12)  opts='"ic":"mdi:power-cycle","unit_of_meas":"count","stat_cla":"measurement"' ;;
                    177) opts='"ic":"mdi:lifecycle","unit_of_meas":"%","stat_cla":"measurement"' ;; # SSD Life
                    199) opts='"ic":"mdi:cable-data","unit_of_meas":"count","stat_cla":"measurement"'$diag_opt ;; # CRC Errors
                    241) raw_val=$(awk -v r=$raw_val 'BEGIN {printf "%.2f", (r*512)/1099511627776}')
                         opts='"ic":"mdi:database-arrow-up","unit_of_meas":"TB","stat_cla":"measurement"'$diag_opt ;;
                    190|194) opts='"ic":"mdi:thermometer","dev_cla":"temperature","unit_of_meas":"°C","stat_cla":"measurement"'$diag_opt ;;
                    *)   opts='"ic":"mdi:alert-circle-outline","stat_cla":"measurement"'$diag_opt ;;
                esac

                # Publish with dynamic name
                mqtt_publish "$disk_type $parent_dev" "$friendly_attr" "$raw_val" "$opts"
            fi
        done
    fi

    # Read Disk Temp via drivetemp sysfs (more efficient than smartctl)
    for hwmon in /sys/class/hwmon/hwmon*; do
        if [[ -f "$hwmon/name" ]] && grep -q "drivetemp" "$hwmon/name"; then
            if [[ -d "$hwmon/device/block/${parent_dev}" ]]; then
                read temp_raw < "$hwmon/temp1_input"
                mqtt_publish "$disk_type $parent_dev" "temperature" "$((temp_raw / 1000))" '"ic":"mdi:thermometer","dev_cla":"temperature","unit_of_meas":"°C","stat_cla":"measurement"'
                break
            fi
        fi
    done
done

# --- 6. STORAGE USAGE ---
if ! declare -p mnt_aliases &>/dev/null; then
    declare -A mnt_aliases=()
fi

for mnt in "${mountpoints[@]}"; do
    if [[ -n "${mnt_aliases[$mnt]}" ]]; then
        mnt_name="${mnt_aliases[$mnt]}"
    else
        dev_short=$(findmnt -no SOURCE "$mnt" 2>/dev/null | grep -oE 'sd[a-z][0-9]*|nvme[0-9]n[0-9]p[0-9]*' | head -n1)
        if [[ -n "$dev_short" ]]; then
            mnt_name=$(echo "$dev_short" | sed 's/[0-9]*$//')
        else
            mnt_name="${mnt#/}"
            mnt_name="${mnt_name//\//_}"
            [[ -z "$mnt_name" ]] && mnt_name="root"
        fi
    fi

    read m_perc m_used m_free m_total <<< $(df -k "$mnt" | awk 'NR==2 {gsub(/%/,"",$5); printf "%s %.2f %.2f %.2f", $5, $3/1048576, $4/1048576, $2/1048576}')

    mqtt_publish "Storage $mnt_name" "usage" "$m_perc" '"ic":"mdi:harddisk","unit_of_meas":"%","stat_cla":"measurement"'
    mqtt_publish "Storage $mnt_name" "used" "$m_used" '"ic":"mdi:database-export","unit_of_meas":"GB","stat_cla":"measurement"'
    mqtt_publish "Storage $mnt_name" "free" "$m_free" '"ic":"mdi:database-import","unit_of_meas":"GB","stat_cla":"measurement"'
    mqtt_publish "Storage $mnt_name" "total" "$m_total" '"ic":"mdi:database","unit_of_meas":"GB","stat_cla":"measurement"'$diag_opt
done

# --- 7. SYSTEM SENSORS & UPTIME ---
#read cpu_temp sys_temp fan1_rpm fan2_rpm vbat <<< $(sensors | awk '
#    /Package id 0:|Core 0:/ { split($0, a, /[+°]/); cpu=a[2] }
#    /SYSTIN/               { split($0, a, /[+°]/); sys=a[2] }
#    /fan1/                 { f1=$2 }
#    /fan2/                 { f2=$2 }
#    /Vbat/                 { vb=$2 }
#    END {
#        printf "%.1f %.1f %d %d %.2f",
#        (cpu?cpu:0), (sys?sys:0), (f1?f1:0), (f2?f2:0), (vb?vb:0)
#    }
#')

# Publish to MQTT
#mqtt_publish "System" "CPU temp" "${cpu_temp:-0}" '"ic":"mdi:thermometer","dev_cla":"temperature","unit_of_meas":"°C","stat_cla":"measurement"'
#mqtt_publish "System" "board temp" "${sys_temp:-0}" '"ic":"mdi:thermometer","dev_cla":"temperature","unit_of_meas":"°C","stat_cla":"measurement"'
#mqtt_publish "System" "fan1 speed" "${fan1_rpm:-0}" '"ic":"mdi:fan","unit_of_meas":"RPM","stat_cla":"measurement"'
#mqtt_publish "System" "fan2 speed" "${fan2_rpm:-0}" '"ic":"mdi:fan","unit_of_meas":"RPM","stat_cla":"measurement"'
#mqtt_publish "System" "battery voltage" "${vbat:-0}" '"ic":"mdi:battery-check","unit_of_meas":"V","dev_cla":"voltage","stat_cla":"measurement","sug_dis_pre":2'$diag_opt

# Uptime as a clean string
uptime_str=$(uptime -p | cut -d' ' -f2-)
mqtt_publish "System" "uptime" "$uptime_str" '"ic":"mdi:clock-outline"'$diag_opt

# --- 8. VIRTUALIZATION DETAILS ---
#vm_count=$(/usr/sbin/qm list | grep -c "running")
#ct_count=$(/usr/sbin/pct list | grep -c "running")
#mqtt_publish "System" "VMs running count" "$vm_count" '"ic":"mdi:server-network","stat_cla":"measurement"'
#mqtt_publish "System" "CTs running count" "$ct_count" '"ic":"mdi:server-network-outline","stat_cla":"measurement"'

#vm_list=$(/usr/sbin/qm list | awk 'NR>1 && $3 == "running" {printf "%s%s", (count++ ? ", " : ""), $2}')
#ct_list=$(/usr/sbin/pct list | awk 'NR>1 && $2 == "running" {printf "%s%s", (count++ ? ", " : ""), $3}')
#mqtt_publish "System" "VMs running list" "${vm_list:-None}" '"ic":"mdi:server-network"'
#mqtt_publish "System" "CTs running list" "${ct_list:-None}" '"ic":"mdi:server-network-outline"'
