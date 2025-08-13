#!/bin/bash

# --- Configuration ---
CHECK_HOSTS=("8.8.8.8" "1.1.1.1" "9.9.9.9" "ya.ru") # Hosts to check for internet connectivity
ORIGINAL_FILE="/run/gpu_nvtool_original"       # File to store original GPU settings
COUNTER_FILE="/run/gpu_nvtool_counters"        # File to store counters and state
NVTOOL="/hive/sbin/nvtool"                         # Path to nvtool utility

TELEGRAM_BOT_TOKEN="your_bot_token_here"
TELEGRAM_CHAT_ID="your_chat_id_here"
TELEGRAM_API_URL="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

# Low-power safe mode values
LOW_CORE=300
LOW_MEM=405
LOW_CORE_OFFSET=0
LOW_MEM_OFFSET=0
LOW_PL=100

THRESHOLD=3                                        # Number of checks before switching state
GPUS=$(nvidia-smi -L | wc -l)                      # Number of detected GPUs
HOSTNAME=$(hostname)                               # Hostname for Telegram notifications

# Delay before saving settings on first run (seconds)
INITIAL_DELAY=120

# --- Helper Functions ---
send_telegram() {
    local message="$1"
    curl -s -X POST "$TELEGRAM_API_URL" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="$message" \
        -d parse_mode="Markdown" > /dev/null
}

load_counters() {
    if [ ! -f "$COUNTER_FILE" ]; then
        echo -e "high:0\nlow:0\nstate:high" > "$COUNTER_FILE"
    fi
    HIGH_COUNTER=$(grep '^high:' "$COUNTER_FILE" | cut -d: -f2)
    LOW_COUNTER=$(grep '^low:' "$COUNTER_FILE" | cut -d: -f2)
    CURRENT_STATE=$(grep '^state:' "$COUNTER_FILE" | cut -d: -f2)
}

save_counters() {
    {
        echo "high:$HIGH_COUNTER"
        echo "low:$LOW_COUNTER"
        echo "state:$CURRENT_STATE"
    } > "$COUNTER_FILE"
}

check_internet() {
    for host in "${CHECK_HOSTS[@]}"; do
        ping -c2 -W1 "$host" &>/dev/null && return 0
    done
    return 1
}

save_original_settings() {
    > "$ORIGINAL_FILE"
    for ((i = 0; i < GPUS; i++)); do
        core=$(${NVTOOL} --index $i -a | awk '/GPU CLOCKS CURRENT:/ {print int($4)}')
        mem=$(${NVTOOL} --index $i -a | awk '/MEM CLOCKS CURRENT:/ {print int($4)}')
        core_offset=$(${NVTOOL} -i $i --coreoffset | awk '/GPU CLOCKS OFFSET:/ {print int($4)}')
        mem_offset=$(${NVTOOL} -i $i --memoffset | awk '/MEM CLOCKS OFFSET:/ {print int($4)}')
        pl=$(${NVTOOL} --index $i -a | awk '/POWER LIMIT CURRENT:/ {print int($4)}')
        echo "$core $mem $core_offset $mem_offset $pl" >> "$ORIGINAL_FILE"
    done
}

apply_settings() {
    local mode=$1
    if [ "$CURRENT_STATE" = "$mode" ]; then
        return 0
    fi
    for ((i = 0; i < GPUS; i++)); do
        if [ "$mode" = "high" ]; then
            read CORE MEM CORE_OFFSET MEM_OFFSET PL < <(sed -n "$((i+1))p" "$ORIGINAL_FILE")
            MODE_DESCRIPTION="HIGH performance"
        else
            CORE=$LOW_CORE
            MEM=$LOW_MEM
            CORE_OFFSET=$LOW_CORE_OFFSET
            MEM_OFFSET=$LOW_MEM_OFFSET
            PL=$LOW_PL
            MODE_DESCRIPTION="LOW power"
        fi
        ${NVTOOL} --index $i \
            --setcore "$CORE" \
            --setmem "$MEM" \
            --setcoreoffset "$CORE_OFFSET" \
            --setmemoffset "$MEM_OFFSET" \
            --setpl "$PL"
    done
    local message="🖥️ *${HOSTNAME}*: GPU mode changed to *${MODE_DESCRIPTION}*"
    send_telegram "$message"
}

# --- Main Logic ---
load_counters

# On first run, wait before saving original settings
if [ ! -s "$ORIGINAL_FILE" ]; then
    echo "First run — waiting ${INITIAL_DELAY} seconds before saving settings..."
    sleep $INITIAL_DELAY
    save_original_settings
    send_telegram "🖥️ *${HOSTNAME}*: GPU monitoring initialized with ${GPUS} GPU(s)"
fi

# Internet check and mode switching
if check_internet; then
    LOW_COUNTER=0
    ((HIGH_COUNTER++))
    if (( HIGH_COUNTER >= THRESHOLD )) && [ "$CURRENT_STATE" != "high" ]; then
        echo "Internet restored: switching to HIGH performance mode, starting miner"
        apply_settings high
        miner start
        CURRENT_STATE="high"
    fi
else
    HIGH_COUNTER=0
    ((LOW_COUNTER++))
    if (( LOW_COUNTER >= THRESHOLD )) && [ "$CURRENT_STATE" != "low" ]; then
        echo "Internet lost: switching to LOW power mode, stopping miner"
        apply_settings low
        miner stop
        CURRENT_STATE="low"
    fi
fi

save_counters
