#!/bin/bash

CHECK_HOSTS=("8.8.8.8" "1.1.1.1" "9.9.9.9")   # Узлы для проверки интернета
STATE_FILE="/tmp/gpu_nvtool_state.txt"         # HIGH или LOW
ORIGINAL_FILE="/tmp/gpu_nvtool_original.txt"
COUNTER_FILE="/tmp/gpu_nvtool_counter.txt"

# Эконом-значения
LOW_CORE=300
LOW_MEM=405
LOW_CORE_OFFSET=0
LOW_MEM_OFFSET=0
LOW_PL=100

# Кол-во карт
GPUS=$(nvidia-smi -L | wc -l)

# Сохраняем оригинальные настройки всех GPU
save_original_settings() {
    > "$ORIGINAL_FILE"
    for ((i=0; i<$GPUS; i++)); do
        core=$(nvtool --index $i -a | awk '/GPU CLOCKS CURRENT:/ {print int($4)}')
        mem=$(nvtool --index $i -a | awk '/MEM CLOCKS CURRENT:/ {print int($4)}')
        pl=$(nvtool --index $i -a | awk '/POWER LIMIT CURRENT:/ {print int($4)}')
        core_offset=$(nvtool -i $i --coreoffset | awk '/GPU CLOCKS OFFSET:/ {print int($4)}')
        mem_offset=$(nvtool -i $i --memoffset | awk '/MEM CLOCKS OFFSET:/ {print int($4)}')

        echo "$core $mem $core_offset $mem_offset $pl" >> "$ORIGINAL_FILE"
    done
}

# Восстанавливаем параметры (если не применены)
restore_settings() {
    echo "$(date) - Восстанавливаем параметры GPU"
    local i=0
    while read CORE MEM CORE_OFFSET MEM_OFFSET PL; do
        # Проверяем текущие параметры чтобы не применять повторно
        cur_core=$(nvtool --index $i -a | awk '/GPU CLOCKS CURRENT:/ {print int($4)}')
        cur_mem=$(nvtool --index $i -a | awk '/MEM CLOCKS CURRENT:/ {print int($4)}')
        cur_core_offset=$(nvtool -i $i --coreoffset | awk '/GPU CLOCKS OFFSET:/ {print int($4)}')
        cur_mem_offset=$(nvtool -i $i --memoffset | awk '/MEM CLOCKS OFFSET:/ {print int($4)}')
        cur_pl=$(nvtool --index $i -a | awk '/POWER LIMIT CURRENT:/ {print int($4)}')

        if [ "$cur_core" != "$CORE" ] || [ "$cur_mem" != "$MEM" ] || \
           [ "$cur_core_offset" != "$CORE_OFFSET" ] || [ "$cur_mem_offset" != "$MEM_OFFSET" ] || \
           [ "$cur_pl" != "$PL" ]; then
            nvtool --index $i \
                   --setcore $CORE \
                   --setmem $MEM \
                   --setcoreoffset $CORE_OFFSET \
                   --setmemoffset $MEM_OFFSET \
                   --setpl $PL
        fi
        ((i++))
    done < "$ORIGINAL_FILE"
    echo "HIGH" > "$STATE_FILE"
    echo 0 > "$COUNTER_FILE"
}

# Снижаем частоты (если не применены)
reduce_settings() {
    echo "$(date) - Снижаем параметры GPU"
    for ((i=0; i<$GPUS; i++)); do
        cur_core=$(nvtool --index $i -a | awk '/GPU CLOCKS CURRENT:/ {print int($4)}')
        cur_mem=$(nvtool --index $i -a | awk '/MEM CLOCKS CURRENT:/ {print int($4)}')
        cur_core_offset=$(nvtool -i $i --coreoffset | awk '/GPU CLOCKS OFFSET:/ {print int($4)}')
        cur_mem_offset=$(nvtool -i $i --memoffset | awk '/MEM CLOCKS OFFSET:/ {print int($4)}')
        cur_pl=$(nvtool --index $i -a | awk '/POWER LIMIT CURRENT:/ {print int($4)}')

        if [ "$cur_core" != "$LOW_CORE" ] || [ "$cur_mem" != "$LOW_MEM" ] || \
           [ "$cur_core_offset" != "$LOW_CORE_OFFSET" ] || [ "$cur_mem_offset" != "$LOW_MEM_OFFSET" ] || \
           [ "$cur_pl" != "$LOW_PL" ]; then
            nvtool --index $i \
                   --setcore $LOW_CORE \
                   --setmem $LOW_MEM \
                   --setcoreoffset $LOW_CORE_OFFSET \
                   --setmemoffset $LOW_MEM_OFFSET \
                   --setpl $LOW_PL
        fi
    done
    echo "LOW" > "$STATE_FILE"
    echo 0 > "$COUNTER_FILE"
}

# Проверка доступности хотя бы одного хоста
check_internet() {
    for host in "${CHECK_HOSTS[@]}"; do
        if ping -c1 -W2 "$host" &>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Основная логика с учётом счётчика
#if [ ! -f "$ORIGINAL_FILE" ]; then
#    save_original_settings
#fi

# Читаем текущий счётчик, или ставим 0
COUNTER=0
if [ -f "$COUNTER_FILE" ]; then
    COUNTER=$(cat "$COUNTER_FILE")
fi

if check_internet; then
    # Интернет доступен
    if [ "$(cat $STATE_FILE 2>/dev/null)" != "HIGH" ]; then
        ((COUNTER++))
        if (( COUNTER >= 5 )); then
            restore_settings
            COUNTER=0
            miner start
        fi
    else
        COUNTER=0
    fi
else
    # Интернет недоступен
    if [ "$(cat $STATE_FILE 2>/dev/null)" != "LOW" ]; then
        ((COUNTER++))
        if (( COUNTER >= 5 )); then
            save_original_settings
            reduce_settings
            COUNTER=0
            miner stop
        fi
    else
        COUNTER=0
    fi
fi

echo $COUNTER > "$COUNTER_FILE"
