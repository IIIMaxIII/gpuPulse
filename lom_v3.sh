#!/bin/bash

# --- Configuration ---
# Hosts to ping for internet connectivity check
CHECK_HOSTS=("8.8.8.8" "1.1.1.1" "9.9.9.9" "ya.ru")

# File to store original GPU settings (clocks, offsets, power limit)
ORIGINAL_FILE="/var/tmp/gpu_nvtool_original"

# File to store counters and current state (high/low)
COUNTER_FILE="/var/tmp/gpu_nvtool_counters"

# Path to nvtool utility for NVIDIA GPU tuning
NVTOOL="/hive/sbin/nvtool"

# Telegram bot configuration
TELEGRAM_BOT_TOKEN="your_bot_token_here"
TELEGRAM_CHAT_ID="your_chat_id_here"
TELEGRAM_API_URL="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

# Default low-performance values when internet is down
LOW_CORE=300           # GPU core clock (MHz)
LOW_MEM=405            # GPU memory clock (MHz)
LOW_CORE_OFFSET=0      # Core clock offset
LOW_MEM_OFFSET=0       # Memory clock offset
LOW_PL=100             # Power limit in watts

# Number of consecutive checks required to trigger a state change
THRESHOLD=5

# Number of detected GPUs
GPUS=$(nvidia-smi -L | wc -l)

# Hostname for identification in messages
HOSTNAME=$(hostname)

# --- Helper Functions ---

# Send Telegram message
send_telegram() {
    local message="$1"
    curl -s -X POST "$TELEGRAM_API_URL" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="$message" \
        -d parse_mode="Markdown" > /dev/null
}

# Load counters and current state from file
load_counters() {
    if [ ! -f "$COUNTER_FILE" ]; then
        echo -e "high:0\nlow:0\nstate:high" > "$COUNTER_FILE"
    fi
    HIGH_COUNTER=$(grep '^high:' "$COUNTER_FILE" | cut -d: -f2)
    LOW_COUNTER=$(grep '^low:' "$COUNTER_FILE" | cut -d: -f2)
    CURRENT_STATE=$(grep '^state:' "$COUNTER_FILE" | cut -d: -f2)
}

# Save current counters and state to file
save_counters() {
    {
        echo "high:$HIGH_COUNTER"
        echo "low:$LOW_COUNTER"
        echo "state:$CURRENT_STATE"
    } > "$COUNTER_FILE"
}

# Check internet connectivity by pinging known reliable hosts
check_internet() {
    for host in "${CHECK_HOSTS[@]}"; do
        ping -c2 -W1 "$host" &>/dev/null && return 0
    done
    return 1
}

# Save current GPU settings as "original" (used when switching back to high)
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

# Apply GPU settings: either "high" (original) or "low" (safe mode)
# Skips if already in requested state
apply_settings() {
    local mode=$1

    # Avoid redundant application if already in target state
    if [ "$CURRENT_STATE" = "$mode" ]; then
        return 0
    fi

    for ((i = 0; i < GPUS; i++)); do
        if [ "$mode" = "high" ]; then
            # Restore original settings from file
            read CORE MEM CORE_OFFSET MEM_OFFSET PL < <(sed -n "$((i+1))p" "$ORIGINAL_FILE")
            MODE_DESCRIPTION="HIGH performance"
        else
            # Apply low-power safe settings
            CORE=$LOW_CORE
            MEM=$LOW_MEM
            CORE_OFFSET=$LOW_CORE_OFFSET
            MEM_OFFSET=$LOW_MEM_OFFSET
            PL=$LOW_PL
            MODE_DESCRIPTION="LOW power"
        fi

        # Apply settings via nvtool
        ${NVTOOL} --index $i \
            --setcore "$CORE" \
            --setmem "$MEM" \
            --setcoreoffset "$CORE_OFFSET" \
            --setmemoffset "$MEM_OFFSET" \
            --setpl "$PL"
    done

    # Send Telegram notification about mode change
    local message="🖥️ *${HOSTNAME}*: GPU mode changed to *${MODE_DESCRIPTION}*"
    send_telegram "$message"
}

# --- Main Logic ---
load_counters

# Save original settings if not already saved
if [ ! -s "$ORIGINAL_FILE" ]; then
    save_original_settings
    # Notify about initial setup
    send_telegram "🖥️ *${HOSTNAME}*: GPU monitoring initialized with ${GPUS} GPU(s)"
fi

# Check internet connectivity
if check_internet; then
    # Internet is UP: reset low counter, increment high counter
    LOW_COUNTER=0
    ((HIGH_COUNTER++))

    # If threshold is reached and we're not already in high mode
    if (( HIGH_COUNTER >= THRESHOLD )) && [ "$CURRENT_STATE" != "high" ]; then
        echo "Internet restored: switching to HIGH performance mode, start miner"
        apply_settings high
        miner start
        CURRENT_STATE="high"
    fi
else
    # Internet is DOWN: reset high counter, increment low counter
    HIGH_COUNTER=0
    ((LOW_COUNTER++))

    # If threshold is reached and we're not already in low mode
    if (( LOW_COUNTER >= THRESHOLD )) && [ "$CURRENT_STATE" != "low" ]; then
        echo "Internet lost: switching to LOW power mode, stop miner"
        apply_settings low
        miner stop
        CURRENT_STATE="low"
    fi
fi

# Always save final state and counters at the end
save_counters
