#!/bin/bash

set -eo pipefail

: ${IPMI_HOST:="169.254.3.254"}
: ${IPMI_USER:=}
: ${IPMI_PASS:=}
: ${INTERVAL:="25"}
: ${DECELERATION_DELAY_COUNT:=3}
: ${KEEP_TEMP:=5}
: ${PATH:=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/snap/bin}
export PATH

readonly version=v1.0.0

declare -gA GPU_LEVEL_CODE=(
          ["1"]="0x10"   ["2"]="0x28"
          ["3"]="0x41"   ["4"]="0x64"
      )

declare -gA GPU_LEVEL_TEMP=(
    ["1"]="40"
    ["2"]="50"
    ["3"]="60"
    ["4"]="65"
)

declare -gA CPU_LEVEL_CODE=(
          ["1"]="0x19"   ["2"]="0x28"
          ["3"]="0x46"   ["4"]="0x64"
      )

function log(){
	echo "$(date +"[%Y/%m/%d %H:%M:%S]") $1"
}

function req_check() {
  local failed
  while [[ $# -gt 0 ]]; do
    if command -v "$1" &>/dev/null;then
      shift
      continue
    fi
    failed="x"
    echo "the required command '$1' is not exist" >&2
    shift
  done
  [ -z "${failed}" ] || exit 1
}


req_check ipmitool sensors nvidia-smi

if [ -z "${IPMI_USER}" ] || [ -z "${IPMI_PASS}" ] || [ -z "${IPMI_HOST}" ];then
    echo "Valid IPMI information must be specified" >&2
    exit 1
fi


until ping -c 2 "${IPMI_HOST}"
do
    log "waiting ipmi host network ready"
    sleep 2
done

log "Boot fan control: $version"
# 将风扇控制模式设置为手动（Full Speed Mode）
log "Set fan control to manual mode"
ipmitool -I lanplus -H "$IPMI_HOST" -U "$IPMI_USER" -P "$IPMI_PASS" raw 0x30 0x45 0x01 0x01

log "wait 20s..."
sleep 20

# 设置初始风扇速度 设置为最低
# GPU 最低有效值 560/2500 22%
log "Set GPU fun init speed 560/2500 22%"
ipmitool -I lanplus -H "$IPMI_HOST" -U "$IPMI_USER" -P "$IPMI_PASS" raw 0x30 0x70 0x66 0x01 0x00 0x10
# CPU 最低有效值 980/2100 46%
log "Set CPU fun init speed 980/2100 26%"
ipmitool -I lanplus -H "$IPMI_HOST" -U "$IPMI_USER" -P "$IPMI_PASS" raw 0x30 0x70 0x66 0x01 0x01 0x19


sleep 4

# 获取温度函数
function get_cpu_temp() {
    # 获取1个 CPU 的温度
    sensors | grep "Tctl" | awk '{print $2}' | sed 's/+//g' | sed 's/°C//g' | awk -F. '{print $1}'
}


function get_gpu_temp() {
    nvidia-smi --query-gpu=temperature.gpu --format=noheader | sort | tail -n 1
}

function set_gpu_fan(){
    local temp=$1
    local percentage=$2
    local level=$3
    log "GPU temperature $temp, Set GPU fan speed to $percentage"

    ipmitool -I lanplus -H "$IPMI_HOST" -U "$IPMI_USER" -P "$IPMI_PASS" raw 0x30 0x70 0x66 0x01 0x00 ${GPU_LEVEL_CODE[$level]}
    CUR_GPU_FAN_SPEED_LEVEL=$level
    GPU_DECELERATION_DELAY_COUNT=0
}

function set_cpu_fan(){
    local temp=$1
    local percentage=$2
    local level=$3
    log "CPU temperature $temp, Set CPU fan speed to $percentage"
    ipmitool -I lanplus -H "$IPMI_HOST" -U "$IPMI_USER" -P "$IPMI_PASS" raw 0x30 0x70 0x66 0x01 0x01 ${CPU_LEVEL_CODE[$level]}
    CUR_CPU_FAN_SPEED_LEVEL=$level
    CPU_DECELERATION_DELAY_COUNT=0
}

function monitor_gpu() {
    # 初始风扇速度级别：1 = 低, 2 = 中, 3 = 高, 4 = 全速
    CUR_GPU_FAN_SPEED_LEVEL=1
    GPU_DECELERATION_DELAY_COUNT=0
    log "GPU Fan Control Started"
    while true; do
        gpu_temp=$(get_gpu_temp)
        if [ -z "$gpu_temp" ] || [ "$gpu_temp" -eq 0 ]; then
            log "Failed to fetch GPU temperature"
            sleep 10
            continue
        fi
        if [ "$gpu_temp" -ge ${GPU_LEVEL_TEMP[4]} ]; then
            if [ "$CUR_GPU_FAN_SPEED_LEVEL" -ne 4 ]; then
                set_gpu_fan "$gpu_temp" "100%" "4"
            fi
        elif [ "$gpu_temp" -ge ${GPU_LEVEL_TEMP[3]} ]; then
            if [ "$CUR_GPU_FAN_SPEED_LEVEL" -ne 3 ]; then
                if ((CUR_GPU_FAN_SPEED_LEVEL > 3));then
                    if [ "$gpu_temp" -gt $((GPU_LEVEL_TEMP[4] - KEEP_TEMP)) ] && [ "$gpu_temp" -lt ${GPU_LEVEL_TEMP[4]} ];then
                        log "GPU temperature $gpu_temp, keep level ${CUR_GPU_FAN_SPEED_LEVEL}"
                        GPU_DECELERATION_DELAY_COUNT=0
                    elif ((GPU_DECELERATION_DELAY_COUNT < DECELERATION_DELAY_COUNT));then
                        GPU_DECELERATION_DELAY_COUNT=$((GPU_DECELERATION_DELAY_COUNT + 1))
                        log "GPU temperature ${gpu_temp}, Delayed reduction of GPU fan speed to L3, ${GPU_DECELERATION_DELAY_COUNT}rd time"
                    else
                        set_gpu_fan "$gpu_temp" "78%" "3"
                    fi
                else
                    set_gpu_fan "$gpu_temp" "78%" "3"
                fi
            fi
        elif [ "$gpu_temp" -ge ${GPU_LEVEL_TEMP[2]} ]; then
            if [ "$CUR_GPU_FAN_SPEED_LEVEL" -ne 2 ]; then
                if ((CUR_GPU_FAN_SPEED_LEVEL > 2));then
                    if [ "$gpu_temp" -gt $((GPU_LEVEL_TEMP[3] - KEEP_TEMP)) ] && [ "$gpu_temp" -lt ${GPU_LEVEL_TEMP[3]} ] ;then
                        log "GPU temperature $gpu_temp, keep level ${CUR_GPU_FAN_SPEED_LEVEL}"
                        GPU_DECELERATION_DELAY_COUNT=0
                    elif ((GPU_DECELERATION_DELAY_COUNT < DECELERATION_DELAY_COUNT));then
                        GPU_DECELERATION_DELAY_COUNT=$((GPU_DECELERATION_DELAY_COUNT + 1))
                        log "GPU temperature ${gpu_temp}, Delayed reduction of GPU fan speed to L2, ${GPU_DECELERATION_DELAY_COUNT}rd time"
                    else
                        set_gpu_fan "$gpu_temp" "50%" "2"
                    fi
                else
                    set_gpu_fan "$gpu_temp" "50%" "2"
                fi
            fi
        else
		    # 低于 50 度的风扇设置
            if [ "$CUR_GPU_FAN_SPEED_LEVEL" -ne 1 ]; then
                if ((CUR_GPU_FAN_SPEED_LEVEL > 1));then
                    if [ "$gpu_temp" -gt $((GPU_LEVEL_TEMP[2] - KEEP_TEMP)) ] && [ "$gpu_temp" -lt ${GPU_LEVEL_TEMP[2]} ] ;then
                        log "GPU temperature $gpu_temp, keep level ${CUR_GPU_FAN_SPEED_LEVEL}"
                        GPU_DECELERATION_DELAY_COUNT=0
                    elif ((GPU_DECELERATION_DELAY_COUNT < DECELERATION_DELAY_COUNT));then
                        GPU_DECELERATION_DELAY_COUNT=$((GPU_DECELERATION_DELAY_COUNT + 1))
                        log "GPU temperature ${gpu_temp}, Delayed reduction of GPU fan speed to L1, ${GPU_DECELERATION_DELAY_COUNT}rd time"
                    else
                        set_gpu_fan "$gpu_temp" "22%" "1"
                    fi
                else
                    set_gpu_fan "$gpu_temp" "22%" "1"
                fi
            fi
        fi
        sleep "${INTERVAL}"
    done
	log "GPU fan control exit"
}

function monitor_cpu() {
    CUR_CPU_FAN_SPEED_LEVEL=1
    CPU_DECELERATION_DELAY_COUNT=0
	log "CPU Fan Control Started"
    while true; do
        TEMP=$(get_cpu_temp)
        if [ -z "$TEMP" ] || [ "$TEMP" -eq 0 ]; then
            log "Failed to fetch CPU temperature"
            sleep 10
            continue
        fi
        if [ "$TEMP" -ge 65 ]; then
            if [ "$CUR_CPU_FAN_SPEED_LEVEL" -ne 4 ]; then
                set_cpu_fan "$TEMP" "100%" "4"
            fi
        elif [ "$TEMP" -ge 55 ]; then
            if [ "$CUR_CPU_FAN_SPEED_LEVEL" -ne 3 ]; then
                if ((CUR_CPU_FAN_SPEED_LEVEL > 3));then
                    if [ "$TEMP" -gt 60 ] && [ "$TEMP" -lt 65 ] ;then
                        log "CPU temperature $TEMP, keep level ${CUR_CPU_FAN_SPEED_LEVEL}"
                        CPU_DECELERATION_DELAY_COUNT=0
                    elif ((CPU_DECELERATION_DELAY_COUNT < DECELERATION_DELAY_COUNT));then
                        CPU_DECELERATION_DELAY_COUNT=$((CPU_DECELERATION_DELAY_COUNT + 1))
                        log "GPU temperature ${TEMP}, Delayed reduction of CPU fan speed to L3, ${CPU_DECELERATION_DELAY_COUNT}rd time"
                    else
                        set_cpu_fan "$TEMP" "80%" "3"
                    fi
                else
                    set_cpu_fan "$TEMP" "80%" "3"
                fi
            fi

        elif [ "$TEMP" -ge 45 ]; then
            if [ "$CUR_CPU_FAN_SPEED_LEVEL" -ne 2 ]; then
                if ((CUR_CPU_FAN_SPEED_LEVEL > 2));then
                    if [ "$TEMP" -gt 50 ] && [ "$TEMP" -lt 55 ] ;then
                        log "CPU temperature $TEMP, keep level ${CUR_CPU_FAN_SPEED_LEVEL}"
                        CPU_DECELERATION_DELAY_COUNT=0
                    elif ((CPU_DECELERATION_DELAY_COUNT < DECELERATION_DELAY_COUNT));then
                        CPU_DECELERATION_DELAY_COUNT=$((CPU_DECELERATION_DELAY_COUNT + 1))
                        log "GPU temperature ${TEMP}, Delayed reduction of CPU fan speed to L2, ${CPU_DECELERATION_DELAY_COUNT}rd time"
                    else
                        set_cpu_fan "$TEMP" "60%" "2"
                    fi
                else
                    set_cpu_fan "$TEMP" "60%" "2"
                fi
            fi
        else
            if [ "$CUR_CPU_FAN_SPEED_LEVEL" -ne 1 ]; then
                if ((CUR_CPU_FAN_SPEED_LEVEL > 1));then
                    if [ "$TEMP" -gt 38 ] && [ "$TEMP" -lt 45 ] ;then
                        log "CPU temperature $TEMP, keep level ${CUR_CPU_FAN_SPEED_LEVEL}"
                        CPU_DECELERATION_DELAY_COUNT=0
                    elif ((CPU_DECELERATION_DELAY_COUNT < DECELERATION_DELAY_COUNT));then
                        CPU_DECELERATION_DELAY_COUNT=$((CPU_DECELERATION_DELAY_COUNT + 1))
                        log "GPU temperature ${TEMP}, Delayed reduction of CPU fan speed to L1, ${CPU_DECELERATION_DELAY_COUNT}rd time"
                    else
                        set_cpu_fan "$TEMP" "46%" "1"
                    fi
                else
                    set_cpu_fan "$TEMP" "46%" "1"
                fi
            fi
        fi
        sleep "${INTERVAL}"
    done
	log "CPU fan control exit"
}

trap "echo termination" EXIT

monitor_cpu &
monitor_gpu &

sleep 1
log "Fan Control Started"
wait
