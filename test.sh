```bash
#!/bin/bash
# ==========================================
# gpuPulse - GPU Power Mode Manager
# ==========================================

# --- Load configuration ---
CONFIG_FILE="/hive/bin/gpuPulse.cfg"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE not found!" >&2
    exit 1
fi
source "$CONFIG_FILE"

# --- Check nvtool ---
if [ ! -x "$NVTOOL" ]; then
    echo "Error: nvtool not found or not executable: $NVTOOL" >&2
    exit 1
fi

# --- Detect GPUs ---
GPUS=$(nvidia-smi -L 2>/dev/null | wc -l)
if (( GPUS == 0 )); then
    echo "Error: No NVIDIA GPUs detected." >&2
    exit 1
fi

HOSTNAME=$(hostname)
TELEGRAM_API_URL="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

# --- Logging ---
exec >>"$LOG_FILE" 2>&1
log() {
    echo "[$(date '+%F %T')] $1"
}

# --- Telegram ---
send_telegram() {
    local message="$1"
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return 0
    curl -fsS -X POST "$TELEGRAM_API_URL" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="$message" \
        -d parse_mode="Markdown" >/dev/null || \
        log "Telegram notification failed."
}

# --- Counters ---
load_counters() {
    if [ ! -f "$COUNTER_FILE" ]; then
        cat >"$COUNTER_FILE" <<EOF
high:0
low:0
state:high
EOF
    fi
    HIGH_COUNTER=$(grep '^high:' "$COUNTER_FILE" | cut -d: -f2)
    LOW_COUNTER=$(grep '^low:' "$COUNTER_FILE" | cut -d: -f2)
    CURRENT_STATE=$(grep '^state:' "$COUNTER_FILE" | cut -d: -f2)
    : "${HIGH_COUNTER:=0}"
    : "${LOW_COUNTER:=0}"
    : "${CURRENT_STATE:=high}"
}

save_counters() {
    cat >"$COUNTER_FILE" <<EOF
high:$HIGH_COUNTER
low:$LOW_COUNTER
state:$CURRENT_STATE
EOF
}

# --- Internet check ---
check_internet() {
    for host in "${CHECK_HOSTS[@]}"; do
        ping -c2 -W1 "$host" &>/dev/null && return 0
    done
    return 1
}

# --- Save original settings ---
save_original_settings() {
    local tmp="${ORIGINAL_FILE}.tmp"
    >"$tmp"
    for ((i=0;i<GPUS;i++)); do
        core=$(${NVTOOL} --index "$i" -a | awk '/GPU CLOCKS CURRENT:/ {print int($4)}')
        mem=$(${NVTOOL} --index "$i" -a | awk '/MEM CLOCKS CURRENT:/ {print int($4)}')
        core_offset=$(${NVTOOL} -i "$i" --coreoffset | awk '/GPU CLOCKS OFFSET:/ {print int($4)}')
        mem_offset=$(${NVTOOL} -i "$i" --memoffset | awk '/MEM CLOCKS OFFSET:/ {print int($4)}')
        pl=$(${NVTOOL} --index "$i" -a | awk '/POWER LIMIT CURRENT:/ {print int($4)}')
        if [[ -z "$core" || -z "$mem" || -z "$pl" ]]; then
            log "Failed reading GPU $i parameters."
            rm -f "$tmp"
            return 1
        fi
        echo "$core $mem $core_offset $mem_offset $pl" >>"$tmp"
    done
    mv "$tmp" "$ORIGINAL_FILE"
}

# --- Apply settings ---
apply_settings() {
    local mode="$1"
    if [[ "$CURRENT_STATE" == "$mode" ]]; then
        return 0
    fi
    for ((i=0;i<GPUS;i++)); do
        if [[ "$mode" == "high" ]]; then
            if ! read CORE MEM CORE_OFFSET MEM_OFFSET PL < <(sed -n "$((i+1))p" "$ORIGINAL_FILE"); then
                log "Failed reading original settings for GPU $i."
                return 1
            fi
            if [[ -z "$CORE" || -z "$MEM" || -z "$PL" ]]; then
                log "Invalid original settings for GPU $i."
                return 1
            fi
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
        ${NVTOOL} --index "$i" \
            --setcore "$CORE" \
            --setmem "$MEM" \
            --setcoreoffset "$CORE_OFFSET" \
            --setmemoffset "$MEM_OFFSET" \
            --setpl "$PL" >/dev/null 2>&1 || {
            log "Failed applying settings to GPU $i."
            return 1
        }
    done
    CURRENT_STATE="$mode"
    message="${ICON} *${HOSTNAME}*: GPU mode changed to *${MODE_DESCRIPTION}*"
    log "$message"
    send_telegram "$message"
    return 0
}

# --- Main ---
main() {
    load_counters

    # --- Initial setup ---
    if [ ! -f "$ORIGINAL_FILE" ]; then
        log "Initialization started."
        echo "# INIT_IN_PROGRESS" > "$ORIGINAL_FILE"
        log "Waiting $INITIAL_DELAY seconds before saving original settings..."
        sleep "$INITIAL_DELAY"
        if save_original_settings; then
            saved=$(wc -l < "$ORIGINAL_FILE")
            if (( saved != GPUS )); then
                log "Initialization failed: saved $saved GPUs, expected $GPUS."
                rm -f "$ORIGINAL_FILE"
                exit 1
            fi
            log "Initialization complete. Detected $GPUS GPU(s)."
            send_telegram "🛠 *${HOSTNAME}*: GPU monitoring initialized with ${GPUS} GPU."
        else
            log "Initialization failed."
            rm -f "$ORIGINAL_FILE"
            exit 1
        fi
    fi

    # --- Internet available ---
    if check_internet; then
        LOW_COUNTER=0
        ((HIGH_COUNTER++))
        if (( HIGH_COUNTER >= THRESHOLD )) && [[ "$CURRENT_STATE" != "high" ]]; then
            if apply_settings high; then
                miner start >/dev/null 2>&1
                log "Internet restored. Switched to HIGH performance mode."
            fi
        fi

    # --- Internet unavailable ---
    else
        HIGH_COUNTER=0
        ((LOW_COUNTER++))
        if (( LOW_COUNTER >= THRESHOLD )) && [[ "$CURRENT_STATE" != "low" ]]; then
            if apply_settings low; then
                miner stop >/dev/null 2>&1
                log "Internet lost. Switched to LOW power mode."
            fi
        fi
    fi

    save_counters
}

main
```
