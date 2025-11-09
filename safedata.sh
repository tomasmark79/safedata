#!/usr/bin/env bash
# SafeData - Universal backup script
# - with include/exclude support
# - with suitable for LVM snapshot and folder backups
# - with rsync and tar methods
#
# (c) Tomáš Mark 2023-2025
# with help of the open source community and contributors
#

# ============================================
# USER CONFIGURATION
# ============================================
VG_NAME="vg_main"                              # LVM volume group name
SNAP_SIZE="80G"                                # LVM snapshot size
LOG_FILE="/var/log/safedata.log"               # Log file path
SSH_PORT=7922                                  # SSH port for remote backup
SSH_USER="tomas"                               # SSH username
SSH_HOST="192.168.79.11"                       # Remote backup server
REMOTE_BASE_DIR="/volume1/homebackup/safedata" # Remote backup directory
# ============================================

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root. Re-running with sudo..."
  exec sudo "$0" "$@"
fi

# Get the directory of the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set -euo pipefail

# Usage
usage() {
  cat << EOF
Usage: $0 <RULES_FILE> <BACKUP_METHOD> <VOLUME1> [VOLUME2 ...]

RULES_FILE:
  Can be any rules file with these naming conventions:
  
  *_include.rules or *_included.rules or included.rules
    - Only listed items will be backed up (everything else ignored)
    
  *_exclude.rules or *_excluded.rules or excluded.rules
    - Listed items will NOT be backed up (everything else included)
    
  *_all.rules or all.rules
    - Backup EVERYTHING (no filters applied)

BACKUP_METHOD:
  rsync              - Rsync with timestamp (creates new backup each time)
  rsync_notimestamp  - Rsync without timestamp (overwrites previous backup)
  tar                - Tar archive with timestamp
  folder_rsync       - Rsync without LVM snapshot (for regular directories)
  folder_tar         - Tar without LVM snapshot (for regular directories)

VOLUME:
  - LVM volume name (e.g., lv_home, lv_var) for snapshot-based backups
  - Directory path (e.g., /boot) for folder_* methods

Examples:
  # Include mode - backup only Pictures, .ssh, Documents from lv_home
  $0 included.rules rsync_notimestamp lv_home
  $0 home_include.rules rsync_notimestamp lv_home
  
  # Exclude mode - backup everything except cache/temp from lv_home
  $0 excluded.rules rsync_notimestamp lv_home
  $0 temp_exclude.rules tar lv_home
  
  # All mode - backup absolutely everything from lv_var
  $0 all.rules tar lv_var
  $0 complete_all.rules rsync lv_var
  
  # Backup /boot without snapshot
  $0 boot_include.rules folder_tar /boot

EOF
  exit 1
}

# Check parameters
if [ $# -lt 3 ]; then
  usage
fi

RULES_FILE="$1"
BACKUP_METHOD="$2"
shift 2
VOLUMES=("$@")

# Determine rules mode and file path
# Support both absolute and relative paths
if [[ "$RULES_FILE" == /* ]]; then
  # Absolute path
  RULES_PATH="$RULES_FILE"
elif [[ "$RULES_FILE" == */* ]]; then
  # Relative path with directory (e.g., rules/all.rules)
  RULES_PATH="${SCRIPT_DIR}/${RULES_FILE}"
else
  # Just filename - look in rules/ subdirectory
  RULES_PATH="${SCRIPT_DIR}/rules/${RULES_FILE}"
fi

# Check if file exists
if [ ! -f "$RULES_PATH" ]; then
  echo "ERROR: Rules file not found: $RULES_PATH"
  exit 1
fi

log() {
  local MESSAGE="$1"
  echo "$(date +"%Y-%m-%d %H:%M:%S") : ${MESSAGE}" | tee -a "${LOG_FILE}" | logger -t safedata
}

cleanup() {
  # Only cleanup if variables are set (to avoid issues when called by trap at script end)
  if [ -n "${MNT_DIR}" ] && mountpoint -q "${MNT_DIR}" 2>/dev/null; then
    log "Unmounting snapshot ${SNAP_NAME}"
    umount "${MNT_DIR}" || log "Failed to unmount snapshot ${SNAP_NAME}"
  fi

  if [ -n "${SNAP_DEV}" ] && lvdisplay "${SNAP_DEV}" &>/dev/null; then
    log "Removing snapshot ${SNAP_NAME}"
    lvremove -y "${SNAP_DEV}" || log "Failed to remove snapshot ${SNAP_NAME}"
  fi

  if [ -n "${MNT_DIR}" ]; then
    rmdir "${MNT_DIR}" 2>/dev/null || true
  fi
}

trap cleanup EXIT

# Detect mode based on filename pattern (must be after log function is defined)
RULES_BASENAME=$(basename "$RULES_FILE")
if [[ "$RULES_BASENAME" == *_include.rules ]] || [[ "$RULES_BASENAME" == *_included.rules ]] || [[ "$RULES_BASENAME" == "included.rules" ]]; then
  RULES_MODE="include"
  log "Detected INCLUDE mode from filename: $RULES_BASENAME"
elif [[ "$RULES_BASENAME" == *_exclude.rules ]] || [[ "$RULES_BASENAME" == *_excluded.rules ]] || [[ "$RULES_BASENAME" == "excluded.rules" ]]; then
  RULES_MODE="exclude"
  log "Detected EXCLUDE mode from filename: $RULES_BASENAME"
elif [[ "$RULES_BASENAME" == *_all.rules ]] || [[ "$RULES_BASENAME" == "all.rules" ]]; then
  RULES_MODE="all"
  log "Detected ALL mode from filename: $RULES_BASENAME"
else
  echo "ERROR: Cannot detect rules mode from filename: $RULES_BASENAME"
  echo "Filename must end with: _include.rules, _included.rules, _exclude.rules, _excluded.rules, or _all.rules"
  usage
fi

# Function to build rsync arguments based on rules mode
build_rsync_args() {
  local mode="$1"
  local rules_file="$2"
  local args=""
  
  if [ "$mode" == "all" ]; then
    # ALL mode - no filters
    args=""
  elif [ "$mode" == "exclude" ]; then
    # EXCLUDE mode - simple, just exclude listed items
    args="--exclude-from=${rules_file}"
  else
    # INCLUDE mode - complex, need parent directories
    declare -A parent_dirs
    local -a include_patterns=()
    
    # Collect patterns and parent directories
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      
      # Extract parent directories
      if [[ "$line" == */* ]]; then
        local parent=$(dirname "$line")
        while [[ "$parent" != "." ]]; do
          parent_dirs["$parent/"]=1
          parent=$(dirname "$parent")
        done
      fi
      
      include_patterns+=("$line")
    done < "$rules_file"
    
    # Build arguments: parents first
    for parent in "${!parent_dirs[@]}"; do
      args="${args} --include=${parent}"
    done
    
    # Then actual patterns
    for pattern in "${include_patterns[@]}"; do
      if [[ ! "$pattern" =~ \* ]]; then
        args="${args} --include=${pattern}"
        args="${args} --include=${pattern}/**"
      else
        args="${args} --include=${pattern}"
      fi
    done
    
    # Exclude everything else
    args="${args} --exclude=*"
  fi
  
  echo "$args"
}

# Function to build tar arguments based on rules mode
build_tar_args() {
  local mode="$1"
  local rules_file="$2"
  local args=""
  
  if [ "$mode" == "all" ]; then
    # ALL mode - backup everything (use .)
    echo "."
    return 0
  elif [ "$mode" == "exclude" ]; then
    # EXCLUDE mode - excludes without ./ prefix, then .
    local excludes=$(awk '{gsub(/^\/+/, ""); if ($0 !~ /^[[:space:]]*#/ && $0 != "") print "--exclude=" $0}' "$rules_file" | xargs)
    if [ -n "$excludes" ]; then
      echo "$excludes ."
    else
      echo "."
    fi
  else
    # INCLUDE mode
    local include_items=""
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s|^/||')
      include_items="${include_items} ./${line}"
    done < "$rules_file"
    
    if [ -z "$include_items" ]; then
      echo "ERROR: No items to include in tar backup"
      return 1
    fi
    
    echo "$include_items"
  fi
}

# Start time measurement
START_TIME=$(date +%s)

# Main backup loop
for VOL in "${VOLUMES[@]}"; do
  TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
  SNAP_NAME="snap_${VOL}_${TIMESTAMP}"
  SNAP_DEV="/dev/${VG_NAME}/${SNAP_NAME}"
  ORIG_DEV="/dev/${VG_NAME}/${VOL}"
  MNT_DIR="/mnt/${SNAP_NAME}"

  log "Starting backup for ${VOL} (mode: ${RULES_MODE}, method: ${BACKUP_METHOD})"

  # ============================================
  # FOLDER BACKUPS (no LVM snapshot)
  # ============================================
  if [[ "${BACKUP_METHOD}" == folder* ]]; then
    SRC_DIR="${VOL}"
    if [ ! -d "${SRC_DIR}" ]; then
      log "ERROR: Source directory ${SRC_DIR} does not exist"
      exit 1
    fi

    if [ "${BACKUP_METHOD}" == "folder_tar" ]; then
      log "Starting tar backup for folder ${SRC_DIR}"
      
      if [ "$RULES_MODE" == "include" ]; then
        TAR_ARGS=$(build_tar_args "include" "${RULES_PATH}")
      else
        TAR_ARGS=$(build_tar_args "exclude" "${RULES_PATH}")
      fi
      
      echo "TAR_ARGS: ${TAR_ARGS}"
      
      if tar cvpz -C "${SRC_DIR}" ${TAR_ARGS} | ssh -i ~/.ssh/id_rsa_backupagent -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} "cat > ${REMOTE_BASE_DIR}/$(basename "${SRC_DIR}")_${TIMESTAMP}.tar.gz"; then
        log "Tar backup completed successfully for folder ${SRC_DIR}"
      else
        log "ERROR: Tar backup failed for folder ${SRC_DIR}"
        exit 1
      fi
      
    else # folder_rsync
      log "Starting rsync backup for folder ${SRC_DIR}"
      
      RSYNC_ARGS=$(build_rsync_args "${RULES_MODE}" "${RULES_PATH}")
      echo "RSYNC_ARGS: ${RSYNC_ARGS}"
      
      if rsync -azl ${RSYNC_ARGS} -e "ssh -p ${SSH_PORT}" -v "${SRC_DIR}/" "${SSH_USER}@${SSH_HOST}:${REMOTE_BASE_DIR}/$(basename "${SRC_DIR}")/"; then
        log "Rsync backup completed successfully for folder ${SRC_DIR}"
      else
        log "ERROR: Rsync backup failed for folder ${SRC_DIR}"
        exit 1
      fi
    fi
    continue
  fi

  # ============================================
  # LVM SNAPSHOT BACKUPS
  # ============================================
  log "Creating snapshot for ${VOL}"
  if ! lvcreate -L "${SNAP_SIZE}" -s -n "${SNAP_NAME}" "${ORIG_DEV}"; then
    log "ERROR: Failed to create snapshot for ${VOL}"
    exit 1
  fi

  log "Mounting snapshot ${SNAP_NAME}"
  mkdir -p "${MNT_DIR}"
  if ! mount "${SNAP_DEV}" "${MNT_DIR}"; then
    log "ERROR: Failed to mount snapshot ${SNAP_NAME}"
    exit 1
  fi

  if [ "${BACKUP_METHOD}" == "tar" ]; then
    log "Starting tar backup for ${VOL}"
    
    if [ "$RULES_MODE" == "include" ]; then
      TAR_ARGS=$(build_tar_args "include" "${RULES_PATH}")
    else
      TAR_ARGS=$(build_tar_args "exclude" "${RULES_PATH}")
    fi
    
    echo "TAR_ARGS: ${TAR_ARGS}"
    
    if tar cvpz -C "${MNT_DIR}" ${TAR_ARGS} | ssh -i ~/.ssh/id_rsa_backupagent -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} "cat > ${REMOTE_BASE_DIR}/${VOL}_${TIMESTAMP}.tar.gz"; then
      log "Tar backup completed successfully for ${VOL}"
    else
      log "ERROR: Tar backup failed for ${VOL}"
      cleanup
      exit 1
    fi
    
  elif [ "${BACKUP_METHOD}" == "rsync_notimestamp" ]; then
    log "Starting rsync_notimestamp for ${VOL}"
    
    RSYNC_ARGS=$(build_rsync_args "${RULES_MODE}" "${RULES_PATH}")
    echo "RSYNC_ARGS: ${RSYNC_ARGS}"
    
    if rsync -azl ${RSYNC_ARGS} -e "ssh -p ${SSH_PORT}" -v "${MNT_DIR}/" "${SSH_USER}@${SSH_HOST}:${REMOTE_BASE_DIR}/${VOL}/"; then
      log "Rsync_notimestamp backup completed successfully for ${VOL}"
    else
      log "ERROR: Rsync_notimestamp backup failed for ${VOL}"
      cleanup
      exit 1
    fi
    
  elif [ "${BACKUP_METHOD}" == "rsync" ]; then
    log "Starting rsync for ${VOL}"
    
    RSYNC_ARGS=$(build_rsync_args "${RULES_MODE}" "${RULES_PATH}")
    echo "RSYNC_ARGS: ${RSYNC_ARGS}"
    
    if rsync -azl ${RSYNC_ARGS} -e "ssh -p ${SSH_PORT}" -v "${MNT_DIR}/" "${SSH_USER}@${SSH_HOST}:${REMOTE_BASE_DIR}/${VOL}_${TIMESTAMP}/"; then
      log "Rsync backup completed successfully for ${VOL}"
    else
      log "ERROR: Rsync backup failed for ${VOL}"
      cleanup
      exit 1
    fi
  fi

  log "Backup for ${VOL} completed successfully"
  cleanup
done

# Disable trap since all cleanups are done
trap - EXIT

# Calculate and display elapsed time
END_TIME=$(date +%s)
ELAPSED_TIME=$((END_TIME - START_TIME))
HOURS=$((ELAPSED_TIME / 3600))
MINUTES=$(((ELAPSED_TIME % 3600) / 60))
SECONDS=$((ELAPSED_TIME % 60))

if [ $HOURS -gt 0 ]; then
  TIME_MSG=$(printf "%dh %dm %ds" $HOURS $MINUTES $SECONDS)
elif [ $MINUTES -gt 0 ]; then
  TIME_MSG=$(printf "%dm %ds" $MINUTES $SECONDS)
else
  TIME_MSG=$(printf "%ds" $SECONDS)
fi

log "All backups completed successfully (elapsed time: ${TIME_MSG})"
echo "All backups completed successfully (elapsed time: ${TIME_MSG})"
