#!/bin/bash
# 
# Safedata Backup Statistics Viewer
# 
# Extracts statistics from backup logs and displays graphs using uchart
# 
# Usage:
#   ./show_stats.sh           - Interactive menu
#   ./show_stats.sh 1         - Show sent bytes graph
#   ./show_stats.sh 6         - Show summary statistics
#
# Environment variables:
#   LOGS_DIR     - Directory with log files (default: ~/.local/share/safedata/logs)
#   STATS_FILE   - CSV file for statistics (default: $LOGS_DIR/stats.csv)
#   UCHART       - Path to uchart.py (default: same directory as this script)
#
# Credits:
#   uchart (MIT License) by Danlino: https://github.com/Danlino/uchart
#

LOGS_DIR="${LOGS_DIR:-$HOME/.local/share/safedata/logs}"
STATS_FILE="${STATS_FILE:-$LOGS_DIR/stats.csv}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UCHART="${UCHART:-$SCRIPT_DIR/uchart/uchart.py}"

# Colors
COLOR_SENT="\033[0;32m"
COLOR_SPEED="\033[0;34m"
COLOR_TIME="\033[0;33m"
COLOR_RESET="\033[0m"

# Check if uchart is available
if [ ! -f "$UCHART" ]; then
    echo "Error: uchart.py not found at: $UCHART"
    echo "Download it from: https://github.com/Danlino/uchart"
    exit 1
fi

#=============================================================================
# STATISTICS EXTRACTION
#=============================================================================

extract_stats() {
    local output_file="$1"
    
    # Initialize CSV with header
    echo "timestamp,date,time,sent_bytes,received_bytes,speed_bytes_sec,total_size,speedup,elapsed_sec,log_file" > "$output_file"
    
    # Process all safedata*.log files
    for log_file in "$LOGS_DIR"/safedata*.log; do
        [ -f "$log_file" ] || continue
        
        # Extract timestamp from filename
        filename=$(basename "$log_file")
        if [[ $filename =~ safedata(_shared)?_([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2}-[0-9]{2}-[0-9]{2})\.log ]]; then
            date="${BASH_REMATCH[2]}"
            time="${BASH_REMATCH[3]//-/:}"
            timestamp="${date} ${time}"
            
            # Extract rsync statistics
            stats_line=$(grep -E "^sent [0-9.]+ bytes.*received [0-9.]+ bytes" "$log_file" 2>/dev/null)
            if [ -n "$stats_line" ]; then
                sent=$(echo "$stats_line" | grep -oP 'sent \K[0-9.]+' | tr -d '.')
                received=$(echo "$stats_line" | grep -oP 'received \K[0-9.]+' | tr -d '.')
                speed_raw=$(echo "$stats_line" | grep -oP '[0-9.]+,[0-9]+ bytes/sec')
                speed=$(echo "$speed_raw" | tr -d '.' | tr ',' '.' | grep -oP '^[0-9.]+')
                
                total_line=$(grep -E "^total size is" "$log_file" 2>/dev/null)
                total_size=$(echo "$total_line" | grep -oP 'total size is \K[0-9.]+' | tr -d '.')
                speedup_raw=$(echo "$total_line" | grep -oP 'speedup is \K[0-9.]+,[0-9]+')
                speedup=$(echo "$speedup_raw" | tr -d '.' | tr ',' '.')
                
                elapsed_line=$(grep -E "elapsed time:" "$log_file" 2>/dev/null)
                elapsed=$(echo "$elapsed_line" | grep -oP 'elapsed time: \K[0-9]+')
                
                echo "$timestamp,$date,$time,$sent,$received,$speed,$total_size,$speedup,$elapsed,$filename" >> "$output_file"
            fi
        fi
    done
    
    local records=$(( $(wc -l < "$output_file") - 1 ))
    echo "Extracted $records backup records"
}

# Check if stats need updating
needs_update() {
    [ ! -f "$STATS_FILE" ] && return 0
    
    local newest_log=$(find "$LOGS_DIR" -name "safedata*.log" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    [ -z "$newest_log" ] && return 1
    [ "$newest_log" -nt "$STATS_FILE" ] && return 0
    
    return 1
}

#=============================================================================
# VISUALIZATION
#=============================================================================

#=============================================================================
# VISUALIZATION
#=============================================================================

show_graph() {
    local title="$1"
    local column="$2"
    local color="$3"
    local height="${4:-12}"
    
    echo -e "\n${color}=== $title ===${COLOR_RESET}"
    tail -n +2 "$STATS_FILE" | cut -d',' -f"$column" | python3 "$UCHART" -y "$height" -n "$title"
}

show_summary() {
    echo -e "\n=== Summary Statistics ==="
    local total_backups=$(( $(wc -l < "$STATS_FILE") - 1 ))
    echo "Total backups: $total_backups"
    
    if [ $total_backups -gt 0 ]; then
        echo ""
        echo "Sent bytes:"
        tail -n +2 "$STATS_FILE" | cut -d',' -f4 | awk '{
            sum+=$1; 
            if(NR==1){min=max=$1} 
            if($1<min){min=$1} 
            if($1>max){max=$1}
        } END {
            printf "  Min: %'\''d bytes (%.2f MB)\n", min, min/1024/1024
            printf "  Max: %'\''d bytes (%.2f MB)\n", max, max/1024/1024
            printf "  Avg: %'\''d bytes (%.2f MB)\n", sum/NR, sum/NR/1024/1024
        }'
        
        echo ""
        echo "Transfer speed:"
        tail -n +2 "$STATS_FILE" | cut -d',' -f6 | awk '{
            sum+=$1;
            if(NR==1){min=max=$1}
            if($1<min){min=$1}
            if($1>max){max=$1}
        } END {
            printf "  Min: %'\''d bytes/sec (%.2f MB/s)\n", min, min/1024/1024
            printf "  Max: %'\''d bytes/sec (%.2f MB/s)\n", max, max/1024/1024
            printf "  Avg: %'\''d bytes/sec (%.2f MB/s)\n", sum/NR, sum/NR/1024/1024
        }'
        
        echo ""
        echo "Elapsed time:"
        tail -n +2 "$STATS_FILE" | cut -d',' -f9 | awk '{
            sum+=$1;
            if(NR==1){min=max=$1}
            if($1<min){min=$1}
            if($1>max){max=$1}
        } END {
            printf "  Min: %d seconds\n", min
            printf "  Max: %d seconds\n", max
            printf "  Avg: %.1f seconds\n", sum/NR
        }'
    fi
}

#=============================================================================
# MAIN
#=============================================================================

# Update statistics if needed
if needs_update; then
    echo "Updating statistics from logs..."
    extract_stats "$STATS_FILE"
    echo ""
fi

# Check if we have data
if [ ! -f "$STATS_FILE" ] || [ $(wc -l < "$STATS_FILE") -le 1 ]; then
    echo "No backup statistics found in $LOGS_DIR"
    exit 1
fi

# Show menu
echo "Safedata Backup Statistics Viewer"
echo "=================================="
echo ""
echo "1) Sent bytes over time"
echo "2) Transfer speed over time"
echo "3) Elapsed time over time"
echo "4) Total backup size over time"
echo "5) All graphs"
echo "6) Summary statistics"
echo "q) Quit"
echo ""

if [ "$1" != "" ]; then
    choice="$1"
else
    read -p "Select option: " choice
fi

case $choice in
    1)
        show_graph "Sent Bytes Over Time" 4 "$COLOR_SENT"
        ;;
    2)
        show_graph "Transfer Speed (bytes/sec)" 6 "$COLOR_SPEED"
        ;;
    3)
        show_graph "Elapsed Time (seconds)" 9 "$COLOR_TIME"
        ;;
    4)
        show_graph "Total Backup Size" 7 "$COLOR_SENT"
        ;;
    5)
        show_graph "Sent Bytes Over Time" 4 "$COLOR_SENT"
        show_graph "Transfer Speed (bytes/sec)" 6 "$COLOR_SPEED"
        show_graph "Elapsed Time (seconds)" 9 "$COLOR_TIME"
        ;;
    6)
        show_summary
        ;;
    q)
        exit 0
        ;;
    *)
        echo "Invalid option"
        exit 1
        ;;
esac
