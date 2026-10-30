#!/usr/bin/env bash

# SafeData
# Universal full-metadata backup script
# (c) Tomas Mark 2023-2026

# ============================================
# CONFIGURATION
# ============================================
VG_NAME="${SAFEDATA_VG_NAME:-vg_main}"
LVM_SNAP_SIZE="${SAFEDATA_LVM_SNAP_SIZE:-80G}"
LOG_FILE="${SAFEDATA_LOG_FILE:-${HOME}/.local/share/logs/safedata/activity.log}"
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

# Preserve hard links, ACLs, extended attributes, sparse allocation, and numeric
# ownership. The remote receiver stores privileged metadata in user xattrs so
# the SSH account does not need root privileges.
RSYNC_METADATA_ARGS=(
  -aHAXS
  --numeric-ids
  -M--fake-super
)

# GNU tar stores ordinary permissions, ownership, timestamps, symlinks, and
# hard links by default. These options add extended filesystem metadata and
# preserve sparse files efficiently.
TAR_METADATA_ARGS=(--numeric-owner --acls --xattrs '--xattrs-include=*' --selinux --sparse)

# Stav patří pouze tomuto běhu; cizí snapshot se podle existence nemaže.
MNT_DIR=""
SNAP_NAME=""
SNAP_DEV=""
BACKUP_PID=""
SNAP_CREATED=0
SNAP_MOUNTED=0
MNT_DIR_CREATED=0
SNAP_LOCK_FD=""
SNAP_LOCK_ROOT="/run/safedata/locks"
SNAP_REMOVE_RETRIES_LEFT=30
LIFECYCLE_CRITICAL=0
PENDING_SIGNAL=""

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

# NAS může používat POSIX sh; Bashové printf %q není pro něj obecně přenositelné.
quote_remote_path() {
  local value="$1"
  value="${value//\'/\'\"\'\"\'}"
  printf "'%s'" "$value"
}

# Refuse to start unless the configured remote target exists and is writable.
check_remote_target() {
  local quoted_remote_dir
  quoted_remote_dir=$(quote_remote_path "${REMOTE_BASE_DIR}")

  # Cesta je citována pro POSIX shell vzdáleného NASu.
  # shellcheck disable=SC2029
  if ! ssh "${SSH_OPTIONS[@]}" \
       "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
       "test -d ${quoted_remote_dir} && test -w ${quoted_remote_dir}"; then
    echo "ERROR: Full-metadata backup target does not exist or is not writable: ${REMOTE_BASE_DIR}"
    echo "Create the directory and make it writable, then check SAFEDATA_REMOTE_BASE_DIR."
    exit 1
  fi
}

# Exercise rsync's remote --fake-super support before transferring real data.
# A successful probe confirms that the remote filesystem accepts the special
# user.rsync.* xattrs used to encode privileged metadata.
check_remote_fake_super_support() {
  if [[ "${BACKUP_METHOD}" != "rsync" && \
        "${BACKUP_METHOD}" != "rsync_notimestamp" && \
        "${BACKUP_METHOD}" != "folder_rsync" ]]; then
    return 0
  fi

  local probe_dir
  local probe_name
  local remote_probe
  local quoted_remote_probe

  probe_dir=$(mktemp -d)
  probe_name=".safedata_fake_super_probe_$(hostname)_$$"
  remote_probe="${REMOTE_BASE_DIR}/${probe_name}"
  quoted_remote_probe=$(quote_remote_path "${remote_probe}")

  printf 'SafeData fake-super probe\n' > "${probe_dir}/probe"
  chmod 000 "${probe_dir}/probe"

  if ! rsync -aX --numeric-ids -M--fake-super \
       -e "${SSH_COMMAND}" \
       "${probe_dir}/" \
       "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}:${remote_probe}/"; then
    chmod 600 "${probe_dir}/probe"
    rm -f "${probe_dir}/probe"
    rmdir "${probe_dir}"
    # Cesta je citována pro POSIX shell vzdáleného NASu.
    # shellcheck disable=SC2029
    ssh "${SSH_OPTIONS[@]}" "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
      "rm -f ${quoted_remote_probe}/probe; rmdir ${quoted_remote_probe}" 2>/dev/null || true
    echo "ERROR: Remote target does not support rsync --fake-super metadata."
    echo "Use a filesystem with writable user extended attributes."
    exit 1
  fi

  chmod 600 "${probe_dir}/probe"
  rm -f "${probe_dir}/probe"
  rmdir "${probe_dir}"
  # Cesta je citována pro POSIX shell vzdáleného NASu.
  # shellcheck disable=SC2029
  ssh "${SSH_OPTIONS[@]}" "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
    "rm -f ${quoted_remote_probe}/probe && rmdir ${quoted_remote_probe}"
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
  rsync              - Full-metadata rsync with timestamp
  rsync_notimestamp  - Full-metadata rsync into a stable directory
  tar                - Full-metadata tar archive with timestamp
  folder_rsync       - Full-metadata rsync without LVM snapshot
  folder_tar         - Full-metadata tar without LVM snapshot

METADATA:
  rsync preserves hard links, ACLs, xattrs, sparse files, and numeric IDs.
  Privileged remote metadata is stored with rsync --fake-super.
  tar preserves numeric IDs, ACLs, xattrs, SELinux metadata, and sparse files.

REMOTE TARGET:
  SAFEDATA_REMOTE_BASE_DIR must point to an existing, writable directory.

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

case "${BACKUP_METHOD}" in
  rsync|rsync_notimestamp|tar|folder_rsync|folder_tar)
    ;;
  *)
    echo "ERROR: Unsupported backup method: ${BACKUP_METHOD}"
    usage
    ;;
esac

# Check required dependencies based on backup method
BASE_DEPS=(ssh)
LVM_DEPS=(lvcreate lvremove mount umount mountpoint flock)
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
check_remote_target
check_remote_fake_super_support

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

finish_critical_section() {
  LIFECYCLE_CRITICAL=0
  if [ -n "${PENDING_SIGNAL}" ]; then
    local signal="${PENDING_SIGNAL}"
    PENDING_SIGNAL=""
    handle_signal "${signal}"
  fi
}

prepare_snapshot() {
  local volume="$1"
  local timestamp="$2"
  local status

  # Názvy VG/LV nesmějí změnit cestu k zámku.
  if [[ ! "${VG_NAME}" =~ ^[a-zA-Z0-9_+.][a-zA-Z0-9_+.-]*$ ]] \
    || [[ ! "${volume}" =~ ^[a-zA-Z0-9_+.][a-zA-Z0-9_+.-]*$ ]] \
    || [[ "${VG_NAME}" == "." || "${VG_NAME}" == ".." || "${volume}" == "." || "${volume}" == ".." ]]; then
    log "ERROR: Invalid volume group or logical volume name"
    return 1
  fi

  if [ -n "${SNAP_LOCK_FD}" ] || [ "${SNAP_CREATED}" -ne 0 ] || [ "${MNT_DIR_CREATED}" -ne 0 ]; then
    log "ERROR: Previous snapshot cleanup is incomplete"
    return 1
  fi

  if ! (umask 077; mkdir -p "${SNAP_LOCK_ROOT}/${VG_NAME}"); then
    return 1
  fi
  LIFECYCLE_CRITICAL=1
  if exec {SNAP_LOCK_FD}>"${SNAP_LOCK_ROOT}/${VG_NAME}/${volume}.lock"; then
    status=0
  else
    status=$?
  fi
  finish_critical_section
  if [ "${status}" -ne 0 ]; then
    return "${status}"
  fi
  if ! flock -n "${SNAP_LOCK_FD}"; then
    log "ERROR: Another backup already owns ${VG_NAME}/${volume}"
    exec {SNAP_LOCK_FD}>&-
    SNAP_LOCK_FD=""
    return 1
  fi

  # Krátký název nezávisí na délce LV; případnou kolizi lvcreate bezpečně odmítne.
  SNAP_NAME="safedata_${timestamp}_$$_${RANDOM}_${RANDOM}"
  SNAP_DEV="/dev/${VG_NAME}/${SNAP_NAME}"
  SNAP_REMOVE_RETRIES_LEFT=30
  ORIG_DEV="/dev/${VG_NAME}/${volume}"

  LIFECYCLE_CRITICAL=1
  if MNT_DIR=$(mktemp -d /mnt/safedata.XXXXXXXXXX); then
    MNT_DIR_CREATED=1
    status=0
  else
    status=$?
  fi
  finish_critical_section
  if [ "${status}" -ne 0 ]; then
    return "${status}"
  fi

  log "Creating snapshot for ${volume}"
  # Signál se zpracuje až po zaznamenání výsledku, aby mezi lvcreate a evidencí
  # vlastnictví nevzniklo okno, v němž by dokončený snapshot zůstal bez úklidu.
  LIFECYCLE_CRITICAL=1
  if lvcreate -L "${LVM_SNAP_SIZE}" -s -n "${SNAP_NAME}" "${ORIG_DEV}"; then
    SNAP_CREATED=1
    status=0
  else
    status=$?
  fi
  finish_critical_section
  if [ "${status}" -ne 0 ]; then
    log "ERROR: Failed to create snapshot for ${volume}"
    return "${status}"
  fi

  log "Mounting snapshot ${SNAP_NAME}"
  LIFECYCLE_CRITICAL=1
  if mount "${SNAP_DEV}" "${MNT_DIR}"; then
    SNAP_MOUNTED=1
    status=0
  else
    status=$?
  fi
  finish_critical_section
  if [ "${status}" -ne 0 ]; then
    log "ERROR: Failed to mount snapshot ${SNAP_NAME}"
    return "${status}"
  fi
}

diagnose_snapshot_holders() {
  local command output line device major minor proc dev target
  # Diagnostika nesmí zakrýt původní chybu ani odpojovat cizí mounty.
  for command in lvs dmsetup findmnt; do
    case "${command}" in
      lvs) output=$(lvs -o lv_name,origin,lv_attr,lv_size,data_percent "${SNAP_DEV}" 2>&1) || true ;;
      dmsetup) output=$(dmsetup info -c "${SNAP_DEV}" 2>&1) || true ;;
      findmnt) output=$(findmnt -rn -S "${SNAP_DEV}" -o TARGET,SOURCE,FSTYPE 2>&1) || true ;;
    esac
    while IFS= read -r line; do
      log "Snapshot diagnostic (${command}): ${line}"
    done <<< "${output}"
  done

  device=$(stat -Lc '%t:%T' "${SNAP_DEV}" 2>/dev/null) || return 0
  major=${device%:*}
  minor=${device#*:}
  printf -v device '%d:%d' "$((16#${major}))" "$((16#${minor}))"
  # Snapshot může být stále připojený v jiném mount namespace.
  for proc in /proc/[0-9]*/mountinfo; do
    [ -r "${proc}" ] || continue
    while read -r _ _ dev _ target _; do
      if [ "${dev}" = "${device}" ]; then
        log "Snapshot holder: ${proc}, mount=${target}"
        break
      fi
    done < "${proc}" 2>/dev/null || true
  done
}

remove_owned_snapshot() {
  local output
  while :; do
    if output=$(LC_ALL=C lvremove -y "${SNAP_DEV}" 2>&1); then
      printf '%s\n' "${output}"
      return 0
    fi
    printf '%s\n' "${output}" >&2
    # umount může skončit dřív, než poslední držitel skutečně uvolní zařízení.
    # Rozpočet je společný i pro následný EXIT trap; jiné chyby neopakujeme.
    if [[ "${output}" != *"contains a filesystem in use"* ]] \
      || [ "${SNAP_REMOVE_RETRIES_LEFT}" -eq 0 ]; then
      diagnose_snapshot_holders
      return 1
    fi
    SNAP_REMOVE_RETRIES_LEFT=$((SNAP_REMOVE_RETRIES_LEFT - 1))
    log "Snapshot ${SNAP_NAME} is still in use; retrying removal in 1s (${SNAP_REMOVE_RETRIES_LEFT} retries left)"
    sleep 1
  done
}

cleanup_owned_resources() {
  # Při chybě zůstanou příznaky i zámek zachované pro další pokus a diagnostiku.
  # I neúspěšný mount helper mohl svazek připojit. Kontrolujeme jen adresář,
  # který tento běh sám vytvořil a dosud vlastní.
  if [ "${MNT_DIR_CREATED}" -eq 1 ] && mountpoint -q "${MNT_DIR}"; then
    SNAP_MOUNTED=1
  fi
  if [ "${SNAP_MOUNTED}" -eq 1 ]; then
    log "Unmounting snapshot ${SNAP_NAME}"
    if ! umount "${MNT_DIR}"; then
      log "ERROR: Failed to unmount snapshot ${SNAP_NAME}; keeping snapshot and lock"
      return 1
    fi
    SNAP_MOUNTED=0
  fi

  if [ "${SNAP_CREATED}" -eq 1 ]; then
    log "Removing snapshot ${SNAP_NAME}"
    if ! remove_owned_snapshot; then
      log "ERROR: Failed to remove snapshot ${SNAP_NAME}; keeping lock"
      return 1
    fi
    SNAP_CREATED=0
  fi

  if [ "${MNT_DIR_CREATED}" -eq 1 ]; then
    if ! rmdir "${MNT_DIR}"; then
      log "ERROR: Failed to remove owned mount directory ${MNT_DIR}"
      return 1
    fi
    MNT_DIR_CREATED=0
    MNT_DIR=""
  fi

  if [ -n "${SNAP_LOCK_FD}" ]; then
    exec {SNAP_LOCK_FD}>&-
    SNAP_LOCK_FD=""
  fi
  SNAP_NAME=""
  SNAP_DEV=""
}

cleanup() {
  local status
  LIFECYCLE_CRITICAL=1
  if cleanup_owned_resources; then
    status=0
  else
    status=$?
  fi
  finish_critical_section
  return "${status}"
}

terminate_backup() {
  if [ -z "${BACKUP_PID}" ]; then
    return 0
  fi

  # Skupinu ukončíme i tehdy, když její vedoucí proces už skončil, ale jeho
  # potomci stále čtou snapshot nebo přenášejí data.
  local attempt
  kill -TERM -- "-${BACKUP_PID}" 2>/dev/null || true
  for attempt in {1..20}; do
    if ! kill -0 -- "-${BACKUP_PID}" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  kill -KILL -- "-${BACKUP_PID}" 2>/dev/null || true
  wait "${BACKUP_PID}" 2>/dev/null || true
  BACKUP_PID=""
}

finalize() {
  local status="$1"
  trap - EXIT
  trap '' HUP INT TERM
  terminate_backup
  if ! cleanup; then
    if [ "${status}" -eq 0 ]; then
      status=1
    fi
    log "ERROR: Snapshot cleanup incomplete; inspect ${SNAP_DEV:-mount directory} ${MNT_DIR}"
  fi
  exit "${status}"
}

handle_signal() {
  local signal="$1"
  local exit_code
  if [ "${LIFECYCLE_CRITICAL}" -eq 1 ]; then
    PENDING_SIGNAL="${signal}"
    return 0
  fi
  case "${signal}" in
    HUP) exit_code=129 ;;
    INT) exit_code=130 ;;
    *) exit_code=143 ;;
  esac
  log "Interrupted by ${signal}; stopping backup"
  exit "${exit_code}"
}

trap 'finalize "$?"' EXIT
trap 'handle_signal HUP' HUP
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

run_with_ac_monitor() {
  local description="$1"
  shift
  local backup_pid
  local status

  LIFECYCLE_CRITICAL=1
  setsid "$@" &
  BACKUP_PID=$!
  backup_pid="${BACKUP_PID}"
  finish_critical_section

  while kill -0 "${backup_pid}" 2>/dev/null; do
    if ! is_on_ac_power; then
      log "ERROR: AC power disconnected during ${description}; stopping backup"
      terminate_backup
      return 75
    fi

    sleep "${AC_CHECK_INTERVAL}"
  done

  if wait "${backup_pid}"; then
    status=0
  else
    status=$?
  fi
  terminate_backup
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
        while [[ "$parent" != "." && "$parent" != "/" ]]; do
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

# Pravidla jsou jednotlivé argumenty; jejich obsah nikdy nevyhodnocuje shell.
TAR_ARGS=()
build_tar_args() {
  local mode="$1"
  local rules_file="$2"
  local line
  TAR_ARGS=()
  
  if [ "$mode" == "all" ]; then
    TAR_ARGS=(-- .)
    return 0
  elif [ "$mode" == "exclude" ]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      line=$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [[ -z "$line" ]] && continue
      
      if [[ "$line" =~ ^/ ]]; then
        # Úvodní lomítko ukotví vzor ke kořeni archivu, jinak platí všude.
        TAR_ARGS+=("--exclude=./${line#/}")
      else
        TAR_ARGS+=("--exclude=${line}")
      fi
    done < "$rules_file"
    TAR_ARGS+=(-- .)
  else
    local -a include_items=()
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      line=$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s|^/||')
      [[ -z "$line" ]] && continue
      include_items+=("./${line}")
    done < "$rules_file"
    
    if [ "${#include_items[@]}" -eq 0 ]; then
      echo "ERROR: No items to include in tar backup"
      return 1
    fi
    TAR_ARGS=(-- "${include_items[@]}")
  fi
}

run_tar_with_ac_monitor() {
  local label="$1"
  local source_dir="$2"
  # Unikátní jméno chrání i hotové archivy dvou záloh spuštěných v téže sekundě.
  local archive_path="${3%.tar.gz}_${BASHPID}_${RANDOM}_${RANDOM}_${RANDOM}_${RANDOM}.tar.gz"
  local partial_path="${archive_path}.partial"
  local quoted_partial quoted_archive write_command finish_command
  quoted_partial=$(quote_remote_path "$partial_path")
  quoted_archive=$(quote_remote_path "$archive_path")
  # Noclobber odmítne i nepravděpodobnou kolizi jména místo přepsání dat.
  write_command="umask 077; set -C; cat > ${quoted_partial}"
  finish_command="test ! -e ${quoted_archive} && test ! -L ${quoted_archive} && mv ${quoted_partial} ${quoted_archive}"

  # Kód je konstantní. Cesty, pravidla i SSH volby se předávají pouze přes argv.
  # Přejmenování běží až po úspěšném taru i dokončeném přenosu přes SSH.
  run_with_ac_monitor "$label" bash -c '
    set +e
    set -uo pipefail
    source_dir=$1
    target=$2
    write_command=$3
    finish_command=$4
    ssh_option_count=$5
    shift 5
    ssh_options=("${@:1:ssh_option_count}")
    shift "$ssh_option_count"
    tar --create --gzip -C "$source_dir" "$@" |
      ssh "${ssh_options[@]}" "$target" "$write_command"
    transfer_status=("${PIPESTATUS[@]}")
    if (( transfer_status[0] != 0 || transfer_status[1] != 0 )); then
      printf "ERROR: Tar transfer failed (tar=%s, ssh=%s); archive remains .partial\n" \
        "${transfer_status[0]}" "${transfer_status[1]}" >&2
      exit 1
    fi
    if ssh "${ssh_options[@]}" "$target" "$finish_command"; then
      exit 0
    fi
    printf "ERROR: Could not publish completed archive; archive remains .partial\n" >&2
    exit 1
  ' bash "$source_dir" "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
    "$write_command" "$finish_command" "${#SSH_OPTIONS[@]}" \
    "${SSH_OPTIONS[@]}" "${TAR_METADATA_ARGS[@]}" "${TAR_ARGS[@]}"
}

log "================ Starting SafeData Full-Metadata Backup ================"

# Start time measurement
START_TIME=$(date +%s)

# Main backup loop
for VOL in "${VOLUMES[@]}"; do
  TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

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
      
      build_tar_args "${RULES_MODE}" "${RULES_PATH}"
      printf 'TAR_ARGS:'; printf ' %q' "${TAR_ARGS[@]}"; printf '\n'
      
      # Handle root directory specially
      DIR_NAME=$(basename "${SRC_DIR}")
      if [ "${DIR_NAME}" == "/" ] || [ "${SRC_DIR}" == "/" ]; then
        DIR_NAME="root"
      fi
      
      if run_tar_with_ac_monitor "tar backup for folder ${SRC_DIR}" "${SRC_DIR}" "${REMOTE_BASE_DIR}/$(hostname)_${DIR_NAME}_${TIMESTAMP}.tar.gz"; then
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
      
      if run_with_ac_monitor "rsync backup for folder ${SRC_DIR}" rsync "${RSYNC_METADATA_ARGS[@]}" "${RSYNC_ARGS[@]}" -e "${SSH_COMMAND}" -v "${SRC_DIR}/" "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}:${REMOTE_BASE_DIR}/${DIR_NAME}/"; then
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
  if ! prepare_snapshot "${VOL}" "${TIMESTAMP}"; then
    exit 1
  fi

  if [ "${BACKUP_METHOD}" == "tar" ]; then
    log "Starting tar backup for ${VOL}"
    
    build_tar_args "${RULES_MODE}" "${RULES_PATH}"
    printf 'TAR_ARGS:'; printf ' %q' "${TAR_ARGS[@]}"; printf '\n'
    
    if run_tar_with_ac_monitor "tar backup for ${VOL}" "${MNT_DIR}" "${REMOTE_BASE_DIR}/$(hostname)_${VOL}_${TIMESTAMP}.tar.gz"; then
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
    
    if run_with_ac_monitor "rsync_notimestamp for ${VOL}" rsync "${RSYNC_METADATA_ARGS[@]}" "${RSYNC_ARGS[@]}" -e "${SSH_COMMAND}" -v "${MNT_DIR}/" "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}:${REMOTE_BASE_DIR}/${VOL}/"; then
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
    
    if run_with_ac_monitor "rsync backup for ${VOL}" rsync "${RSYNC_METADATA_ARGS[@]}" "${RSYNC_ARGS[@]}" -e "${SSH_COMMAND}" -v "${MNT_DIR}/" "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}:${REMOTE_BASE_DIR}/${VOL}_${TIMESTAMP}/"; then
      log "Rsync backup completed successfully for ${VOL}"
    else
      log "ERROR: Rsync backup failed for ${VOL}"
      cleanup
      exit 1
    fi
  fi

  if ! cleanup; then
    log "ERROR: Backup transfer for ${VOL} finished, but snapshot cleanup failed"
    exit 1
  fi
  log "Backup for ${VOL} completed successfully"
done

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

log "All full-metadata backups completed successfully (elapsed time: ${TIME_MSG})"
echo "All full-metadata backups completed successfully (elapsed time: ${TIME_MSG})"
