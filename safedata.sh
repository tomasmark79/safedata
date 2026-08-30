#!/usr/bin/env bash

# SafeData
# Universal backup script
# (c) Tomas Mark 2023-2025

# ============================================
# CONFIGURATION
# ============================================
VG_NAME="${SAFEDATA_VG_NAME:-vg_main}"
LVM_SNAP_SIZE="${SAFEDATA_LVM_SNAP_SIZE:-80G}"
LOG_FILE="${SAFEDATA_LOG_FILE:-${HOME}/.local/share/safedata/logs/activity.log}"
SSH_KEY_PATH="${SAFEDATA_SSH_KEY_PATH:?Set SAFEDATA_SSH_KEY_PATH}"
SSH_KNOWN_HOSTS_PATH="${SAFEDATA_SSH_KNOWN_HOSTS_PATH:?Set SAFEDATA_SSH_KNOWN_HOSTS_PATH}"
SSH_PORT="${SAFEDATA_SSH_PORT:-22}"
REMOTE_SSH_USER="${SAFEDATA_REMOTE_SSH_USER:?Set SAFEDATA_REMOTE_SSH_USER}"
REMOTE_SSH_HOST="${SAFEDATA_REMOTE_SSH_HOST:?Set SAFEDATA_REMOTE_SSH_HOST}"
REMOTE_BASE_DIR="${SAFEDATA_REMOTE_BASE_DIR:?Set SAFEDATA_REMOTE_BASE_DIR}"
SSH_CONNECT_TIMEOUT="${SAFEDATA_SSH_CONNECT_TIMEOUT:-10}"
SSH_RETRY_COUNT="${SAFEDATA_SSH_RETRY_COUNT:-6}"
SSH_RETRY_DELAY="${SAFEDATA_SSH_RETRY_DELAY:-15}"
AC_CHECK_INTERVAL="${SAFEDATA_AC_CHECK_INTERVAL:-10}"
# ============================================

export SAFEDATA_LOG_FILE="${LOG_FILE}"

# Create log directory and file as user before switching to root
LOG_DIR="$(dirname "${LOG_FILE}")"
if [ ! -d "$LOG_DIR" ]; then
  mkdir -p "$LOG_DIR"
fi
if [ ! -f "$LOG_FILE" ]; then
  touch "$LOG_FILE"
fi

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root. Re-running with sudo..."
  exec sudo --preserve-env=SAFEDATA_VG_NAME,SAFEDATA_LVM_SNAP_SIZE,SAFEDATA_LOG_FILE,SAFEDATA_SSH_KEY_PATH,SAFEDATA_SSH_KNOWN_HOSTS_PATH,SAFEDATA_SSH_PORT,SAFEDATA_REMOTE_SSH_USER,SAFEDATA_REMOTE_SSH_HOST,SAFEDATA_REMOTE_BASE_DIR,SAFEDATA_SSH_CONNECT_TIMEOUT,SAFEDATA_SSH_RETRY_COUNT,SAFEDATA_SSH_RETRY_DELAY,SAFEDATA_AC_CHECK_INTERVAL bash "$0" "$@"
fi

# Get the directory of the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set -euo pipefail

SSH_OPTIONS=(
  -i "${SSH_KEY_PATH}"
  -p "${SSH_PORT}"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS_PATH}"
  -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
)
printf -v SSH_COMMAND '%q ' ssh "${SSH_OPTIONS[@]}"

# Initialize variables for cleanup trap
MNT_DIR=""
SNAP_NAME=""
SNAP_DEV=""
BACKUP_PID=""

check_dependencies() {
  local -a required_cmds=("$@")
  local missing_deps=()

  for cmd in "${required_cmds[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing_deps+=("$cmd")
    fi
  done

  if [ ${#missing_deps[@]} -gt 0 ]; then
    echo "ERROR: Missing required commands: ${missing_deps[*]}"
    echo "Please install the missing dependencies and try again."
    exit 1
  fi
}

is_on_ac_power() {
  local found_mains=0
  local supply_type
  local online

  for supply in /sys/class/power_supply/*; do
    [ -e "${supply}" ] || continue
    [ -r "${supply}/type" ] || continue
    supply_type=$(<"${supply}/type")

    if [ "${supply_type}" != "Mains" ]; then
      continue
    fi

    found_mains=1
    if [ -r "${supply}/online" ]; then
      online=$(<"${supply}/online")
      if [ "${online}" = "1" ]; then
        return 0
      fi
    fi
  done

  # Desktops and VMs may not expose an AC adapter; do not block backups there.
  [ "${found_mains}" -eq 0 ]
}

abort_if_on_battery() {
  if ! is_on_ac_power; then
    echo "ERROR: SafeData backup requires AC power; notebook is running on battery."
    exit 75
  fi
}

# Verify SSH connectivity before starting backup
check_ssh_connection() {
  local attempt

  echo "Verifying SSH connection to ${REMOTE_SSH_HOST}..."
  for ((attempt = 1; attempt <= SSH_RETRY_COUNT; attempt++)); do
    if ssh "${SSH_OPTIONS[@]}" \
         "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" "echo 'SSH connection OK'" &>/dev/null; then
      echo "SSH connection verified."
      return 0
    fi

    if [ "$attempt" -lt "$SSH_RETRY_COUNT" ]; then
      echo "SSH attempt ${attempt}/${SSH_RETRY_COUNT} failed, retrying in ${SSH_RETRY_DELAY}s..."
      sleep "${SSH_RETRY_DELAY}"
    fi
  done

  echo "ERROR: Cannot establish SSH connection to ${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}:${SSH_PORT} after ${SSH_RETRY_COUNT} attempts"
  echo "Please check:"
  echo "  - SSH key exists: ${SSH_KEY_PATH}"
  echo "  - Remote host is reachable"
  echo "  - SSH port ${SSH_PORT} is open"
  echo "  - SSH key is authorized on remote host"
  exit 1
}

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
  # Include mode - backup only selected files from lv_home
  $0 included.rules rsync_notimestamp lv_home
  
  # Exclude mode - backup everything except selected files from lv_home
  $0 excluded.rules rsync_notimestamp lv_home
  
  # All mode - backup everything from lv_var
  $0 all.rules tar lv_var

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

# Check required dependencies based on backup method
BASE_DEPS=(ssh)
LVM_DEPS=(lvcreate lvremove lvdisplay mount umount)
BASE_DEPS+=(setsid)

if [[ "${BACKUP_METHOD}" == "rsync" || "${BACKUP_METHOD}" == "rsync_notimestamp" || "${BACKUP_METHOD}" == "folder_rsync" ]]; then
  BASE_DEPS+=(rsync)
fi

if [[ "${BACKUP_METHOD}" == "tar" || "${BACKUP_METHOD}" == "folder_tar" ]]; then
  BASE_DEPS+=(tar)
fi

if [[ "${BACKUP_METHOD}" != folder* ]]; then
  BASE_DEPS+=("${LVM_DEPS[@]}")
fi

check_dependencies "${BASE_DEPS[@]}"
abort_if_on_battery
check_ssh_connection

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

terminate_backup() {
  if [ -z "${BACKUP_PID}" ]; then
    return 0
  fi

  if kill -0 "${BACKUP_PID}" 2>/dev/null; then
    kill -TERM "-${BACKUP_PID}" 2>/dev/null || true
    sleep 2
    kill -KILL "-${BACKUP_PID}" 2>/dev/null || true
    wait "${BACKUP_PID}" 2>/dev/null || true
  fi

  BACKUP_PID=""
}

handle_signal() {
  local signal="$1"
  local exit_code=143

  if [ "${signal}" = "INT" ]; then
    exit_code=130
  fi

  trap - INT TERM
  log "Interrupted by ${signal}; stopping backup"
  terminate_backup
  exit "${exit_code}"
}

trap cleanup EXIT
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

run_with_ac_monitor() {
  local description="$1"
  shift
  local backup_pid
  local status

  setsid "$@" &
  backup_pid=$!
  BACKUP_PID="${backup_pid}"

  while kill -0 "${backup_pid}" 2>/dev/null; do
    if ! is_on_ac_power; then
      log "ERROR: AC power disconnected during ${description}; stopping backup"
      terminate_backup
      return 75
    fi

    sleep "${AC_CHECK_INTERVAL}"
  done

  wait "${backup_pid}"
  status=$?
  BACKUP_PID=""
  return "${status}"
}

run_shell_with_ac_monitor() {
  local description="$1"
  local command="$2"
  local err_log
  local status

  err_log=$(mktemp)

  run_with_ac_monitor "${description}" bash -o pipefail -c "${command}" 2> >(tee "${err_log}" >&2)
  status=$?

  if [ "${status}" -eq 0 ]; then
    rm -f "${err_log}"
    return 0
  fi

  log "ERROR: ${description} exited with status ${status}"

  if [ -s "${err_log}" ]; then
    log "Last stderr lines from ${description}:"
    tail -n 20 "${err_log}" | while IFS= read -r line; do
      log "  ${line}"
    done
  fi

  rm -f "${err_log}"
  return "${status}"
}

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
RSYNC_ARGS=()
build_rsync_args() {
  local mode="$1"
  local rules_file="$2"
  RSYNC_ARGS=()
  
  if [ "$mode" == "all" ]; then
    # ALL mode - no filters
    return 0
  elif [ "$mode" == "exclude" ]; then
    # EXCLUDE mode - simple, just exclude listed items
    RSYNC_ARGS+=("--exclude-from=${rules_file}")
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
        local parent
        parent=$(dirname "$line")
        while [[ "$parent" != "." ]]; do
          parent_dirs["$parent/"]=1
          parent=$(dirname "$parent")
        done
      fi
      
      include_patterns+=("$line")
    done < "$rules_file"
    
    # Build arguments: parents first
    for parent in "${!parent_dirs[@]}"; do
      RSYNC_ARGS+=("--include=${parent}")
    done
    
    # Then actual patterns
    for pattern in "${include_patterns[@]}"; do
      if [[ ! "$pattern" =~ \* ]]; then
        RSYNC_ARGS+=("--include=${pattern}")
        RSYNC_ARGS+=("--include=${pattern}/**")
      else
        RSYNC_ARGS+=("--include=${pattern}")
      fi
    done
    
    # Exclude everything else
    RSYNC_ARGS+=("--exclude=*")
  fi
}

# Function to build tar arguments based on rules mode
build_tar_args() {
  local mode="$1"
  local rules_file="$2"
  
  if [ "$mode" == "all" ]; then
    # ALL mode - backup everything (use .)
    echo "."
    return 0
  elif [ "$mode" == "exclude" ]; then
    # EXCLUDE mode - preserve leading slash to anchor patterns
    # /dev means only in root (use ./dev for tar), dev means anywhere
    local excludes=""
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      
      if [[ "$line" =~ ^/ ]]; then
        # Leading slash - anchor to root (prefix with ./ for tar)
        line="${line#/}"
        excludes="${excludes} --exclude=./${line}"
      else
        # No leading slash - match anywhere
        excludes="${excludes} --exclude=${line}"
      fi
    done < "$rules_file"
    
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

log "==================== Starting SafeData Backup ===================="

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
      
      # Handle root directory specially
      DIR_NAME=$(basename "${SRC_DIR}")
      if [ "${DIR_NAME}" == "/" ] || [ "${SRC_DIR}" == "/" ]; then
        DIR_NAME="root"
      fi
      
      if run_shell_with_ac_monitor "tar backup for folder ${SRC_DIR}" "tar cpz -C \"${SRC_DIR}\" ${TAR_ARGS} | ${SSH_COMMAND}\"${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}\" \"cat > ${REMOTE_BASE_DIR}/$(hostname)_${DIR_NAME}_${TIMESTAMP}.tar.gz\""; then
        log "Tar backup completed successfully for folder ${SRC_DIR}"
      else
        log "ERROR: Tar backup failed for folder ${SRC_DIR}"
        exit 1
      fi
      
    else # folder_rsync
      log "Starting rsync backup for folder ${SRC_DIR}"
      
      build_rsync_args "${RULES_MODE}" "${RULES_PATH}"
      printf 'RSYNC_ARGS:'; printf ' %q' "${RSYNC_ARGS[@]}"; printf '\n'
      
      # Handle root directory specially
      DIR_NAME=$(basename "${SRC_DIR}")
      if [ "${DIR_NAME}" == "/" ] || [ "${SRC_DIR}" == "/" ]; then
        DIR_NAME="root"
      fi
      
      if run_with_ac_monitor "rsync backup for folder ${SRC_DIR}" rsync -al "${RSYNC_ARGS[@]}" -e "${SSH_COMMAND}" -v "${SRC_DIR}/" "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}:${REMOTE_BASE_DIR}/${DIR_NAME}/"; then
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
  if ! lvcreate -L "${LVM_SNAP_SIZE}" -s -n "${SNAP_NAME}" "${ORIG_DEV}"; then
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
    
    if run_shell_with_ac_monitor "tar backup for ${VOL}" "tar cpz -C \"${MNT_DIR}\" ${TAR_ARGS} | ${SSH_COMMAND}\"${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}\" \"cat > ${REMOTE_BASE_DIR}/$(hostname)_${VOL}_${TIMESTAMP}.tar.gz\""; then
      log "Tar backup completed successfully for ${VOL}"
    else
      log "ERROR: Tar backup failed for ${VOL}"
      cleanup
      exit 1
    fi
    
  elif [ "${BACKUP_METHOD}" == "rsync_notimestamp" ]; then
    log "Starting rsync_notimestamp for ${VOL}"
    
    build_rsync_args "${RULES_MODE}" "${RULES_PATH}"
    printf 'RSYNC_ARGS:'; printf ' %q' "${RSYNC_ARGS[@]}"; printf '\n'
    
    if run_with_ac_monitor "rsync_notimestamp for ${VOL}" rsync -al "${RSYNC_ARGS[@]}" -e "${SSH_COMMAND}" -v "${MNT_DIR}/" "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}:${REMOTE_BASE_DIR}/${VOL}/"; then
      log "Rsync_notimestamp backup completed successfully for ${VOL}"
    else
      log "ERROR: Rsync_notimestamp backup failed for ${VOL}"
      cleanup
      exit 1
    fi
    
  elif [ "${BACKUP_METHOD}" == "rsync" ]; then
    log "Starting rsync for ${VOL}"
    
    build_rsync_args "${RULES_MODE}" "${RULES_PATH}"
    printf 'RSYNC_ARGS:'; printf ' %q' "${RSYNC_ARGS[@]}"; printf '\n'
    
    if run_with_ac_monitor "rsync backup for ${VOL}" rsync -al "${RSYNC_ARGS[@]}" -e "${SSH_COMMAND}" -v "${MNT_DIR}/" "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}:${REMOTE_BASE_DIR}/${VOL}_${TIMESTAMP}/"; then
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

# Disable traps since all cleanups are done
trap - EXIT INT TERM

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
