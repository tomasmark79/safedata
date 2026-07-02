#!/usr/bin/env bash
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

normalize_integer() {
    local value="$1"
    value="${value//,/}"
    value="${value//./}"
    echo "$value"
}

normalize_decimal() {
    local value="$1"

    if [[ "$value" == *","* && "$value" == *"."* ]]; then
        if [[ "${value##*,}" == *"."* ]]; then
            echo "${value//,/}"
        else
            value="${value//./}"
            echo "${value//,/.}"
        fi
    elif [[ "$value" == *","* ]]; then
        echo "${value//,/.}"
    else
        echo "$value"
    fi
}

parse_elapsed_seconds() {
    local value="$1"
    local total=0

    value="${value#*elapsed time: }"

    if [[ "$value" =~ ([0-9]+)[[:space:]]*h ]]; then
        total=$((total + BASH_REMATCH[1] * 3600))
    fi
    if [[ "$value" =~ ([0-9]+)[[:space:]]*m ]]; then
        total=$((total + BASH_REMATCH[1] * 60))
    fi
    if [[ "$value" =~ ([0-9]+)[[:space:]]*s ]]; then
        total=$((total + BASH_REMATCH[1]))
    fi

    if [ "$total" -eq 0 ] && [[ "$value" =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
        total="${BASH_REMATCH[1]}"
    fi

    echo "$total"
}

extract_stats() {
    local output_file="$1"
    
    mkdir -p "$(dirname "$output_file")"
    
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
            stats_line=$(grep -E "^sent [0-9.,]+ bytes +received [0-9.,]+ bytes" "$log_file" 2>/dev/null | tail -1)
            if [ -n "$stats_line" ]; then
                sent_raw=$(echo "$stats_line" | sed -E 's/^sent ([0-9.,]+) bytes.*/\1/')
                received_raw=$(echo "$stats_line" | sed -E 's/.*received ([0-9.,]+) bytes.*/\1/')
                speed_raw=$(echo "$stats_line" | sed -E 's/.*received [0-9.,]+ bytes +([0-9.,]+) bytes\/sec.*/\1/')
                sent=$(normalize_integer "$sent_raw")
                received=$(normalize_integer "$received_raw")
                speed=$(normalize_decimal "$speed_raw")
                
                total_line=$(grep -E "^total size is" "$log_file" 2>/dev/null | tail -1)
                total_size_raw=$(echo "$total_line" | sed -E 's/^total size is ([0-9.,]+).*/\1/')
                speedup_raw=$(echo "$total_line" | sed -E 's/.*speedup is ([0-9.,]+).*/\1/')
                total_size=$(normalize_integer "$total_size_raw")
                speedup=$(normalize_decimal "$speedup_raw")
                
                elapsed_line=$(grep -E "elapsed time:" "$log_file" 2>/dev/null | tail -1)
                elapsed=$(parse_elapsed_seconds "$elapsed_line")
                
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
    [ "$(wc -l < "$STATS_FILE")" -le 1 ] && return 0
    
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
    local unit="${5:-}"
    
    echo -e "\n${color}=== $title ===${COLOR_RESET}"
    if [ -n "$unit" ]; then
        tail -n +2 "$STATS_FILE" | cut -d',' -f"$column" | python3 "$UCHART" -y "$height" -n "$title" -S "$unit" -m
    else
        tail -n +2 "$STATS_FILE" | cut -d',' -f"$column" | python3 "$UCHART" -y "$height" -n "$title" -m
    fi
}

show_summary() {
    local total_backups=$(( $(wc -l < "$STATS_FILE") - 1 ))
    echo -e "\n=== Summary Statistics ==="
    echo "Total backups: $total_backups"
    
    if [ $total_backups -gt 0 ]; then
        show_graph "Sent Over Time (MB)" 4 "$COLOR_SENT" 8 "M"
        show_graph "Transfer Speed (MB/sec)" 6 "$COLOR_SPEED" 8 "M"
        show_graph "Elapsed Time (seconds)" 9 "$COLOR_TIME" 8
    fi
}

#=============================================================================
# MENU & USER INTERACTION
#=============================================================================

# Menu options configuration
declare -A MENU_OPTIONS
MENU_OPTIONS[1]="Sent Over Time (MB)"
MENU_OPTIONS[2]="Transfer Speed Over Time (MB/sec)"
MENU_OPTIONS[3]="Elapsed Time Over Time (seconds)"
MENU_OPTIONS[4]="Total Backup Size Over Time (GB)"
MENU_OPTIONS[5]="All graphs"
MENU_OPTIONS[6]="Summary statistics"
MENU_OPTIONS[q]="Quit"

# Display menu
show_menu() {
    echo "Safedata Backup Statistics Viewer"
    echo "=================================="
    echo ""
    echo "1) ${MENU_OPTIONS[1]}"
    echo "2) ${MENU_OPTIONS[2]}"
    echo "3) ${MENU_OPTIONS[3]}"
    echo "4) ${MENU_OPTIONS[4]}"
    echo "5) ${MENU_OPTIONS[5]}"
    echo "6) ${MENU_OPTIONS[6]}"
    echo "q) ${MENU_OPTIONS[q]}"
    echo ""
}

# Get user choice
get_user_choice() {
    local choice="$1"
    
    if [ -n "$choice" ]; then
        echo "$choice"
    else
        read -p "Select option: " choice
        echo "$choice"
    fi
}

# Validate user choice
validate_choice() {
    local choice="$1"
    
    case $choice in
        1|2|3|4|5|6|q)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Process user choice
process_choice() {
    local choice="$1"
    local height="${2:-10}"
    
    case $choice in
        1)
            show_graph "Sent Over Time (MB)" 4 "$COLOR_SENT" $height "M"
            ;;
        2)
            show_graph "Transfer Speed (MB/sec)" 6 "$COLOR_SPEED" $height "M"
            ;;
        3)
            show_graph "Elapsed Time (seconds)" 9 "$COLOR_TIME" $height
            ;;
        4)
            show_graph "Total Backup Size (GB)" 7 "$COLOR_SENT" $height "G"
            ;;
        5)
            show_graph "Sent Over Time (MB)" 4 "$COLOR_SENT" $height "M"
            show_graph "Transfer Speed (MB/sec)" 6 "$COLOR_SPEED" $height "M"
            show_graph "Elapsed Time (seconds)" 9 "$COLOR_TIME" $height
            show_graph "Total Backup Size (GB)" 7 "$COLOR_SENT" $height "G"
            ;;
        6)
            show_summary
            ;;
        q)
            exit 0
            ;;
        *)
            echo "Invalid option: $choice"
            return 1
            ;;
    esac
}

#=============================================================================
# MAIN
#=============================================================================

main() {
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
    
    # Show menu and get choice
    show_menu
    local choice=$(get_user_choice "$1")
    
    # Validate and process choice
    if ! validate_choice "$choice"; then
        echo "Invalid option: $choice"
        exit 1
    fi
    
    # Default graph height
    local height=10
    
    # Process the choice
    process_choice "$choice" "$height"
}

# Run main function
main "$@"
