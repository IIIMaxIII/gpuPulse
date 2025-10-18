#!/bin/bash

# --- Load configuration ---
CONFIG_FILE="/hive/bin/gpuPulse.cfg"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE not found!" >&2
    exit 1
fi
source "$CONFIG_FILE"

# --- Derived variables ---
TELEGRAM_API_URL="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
GPUS=$(nvidia-smi -L | wc -l)
HOSTNAME=$(hostname)

# --- Initialize logging ---
exec >> "$LOG_FILE" 2>&1
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# --- Helper functions ---
send_telegram() {
    local message="$1"
    if ! curl -s -X POST "$TELEGRAM_API_URL" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="$message" \
        -d parse_mode="Markdown" > /dev/null; then
        log "Warning: Failed to send Telegram message"
    fi
}

load_counters() {
    if [ ! -f "$COUNTER_FILE" ]; then
        echo -e "high:0
low:0
state:high" > "$COUNTER_FILE"
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
            ICON="⚡"
        else
            CORE=$LOW_CORE
            MEM=$LOW_MEM
            CORE_OFFSET=$LOW_CORE_OFFSET
            MEM_OFFSET=$LOW_MEM_OFFSET
            PL=$LOW_PL
            MODE_DESCRIPTION="LOW power"
            ICON="💤"
        fi
        
        ${NVTOOL} --index $i \
            --setcore "$CORE" \
            --setmem "$MEM" \
            --setcoreoffset "$CORE_OFFSET" \
            --setmemoffset "$MEM_OFFSET" \
            --setpl "$PL" >/dev/null 2>&1
    done
    
    CURRENT_STATE="$mode"
    local message="${ICON} *${HOSTNAME}*: GPU mode changed to *${MODE_DESCRIPTION}*"
    log "$message"
    send_telegram "$message"
}

# --- Main execution ---
main() {
    load_counters

    # Initial setup if needed
    if [ ! -f "$ORIGINAL_FILE" ]; then
        echo "# INIT_IN_PROGRESS" > "$ORIGINAL_FILE"
        sleep $INITIAL_DELAY && log "Initializing - waiting $INITIAL_DELAY seconds before saving original settings..."
        save_original_settings && log "Initialization complete. Detected $GPUS GPU"
        send_telegram "🛠 *${HOSTNAME}*: GPU monitoring initialized with ${GPUS} GPU"
    fi

    # Check internet and switch modes
    if check_internet; then
        LOW_COUNTER=0
        ((HIGH_COUNTER++))
        
        if (( HIGH_COUNTER >= THRESHOLD )) && [ "$CURRENT_STATE" != "high" ]; then
            apply_settings high
            gov -r
            /hive/bin/miner start >/dev/null 2>&1
            log "Internet connection restored - switching to HIGH performance mode"
        fi
    else
        HIGH_COUNTER=0
        ((LOW_COUNTER++))
        
        if (( LOW_COUNTER >= THRESHOLD )) && [ "$CURRENT_STATE" != "low" ]; then
            apply_settings low
            gov -e
            /hive/bin/miner stop >/dev/null 2>&1
            log "Internet connection lost - switching to LOW power mode"
        fi
    fi

    save_counters
}

main
