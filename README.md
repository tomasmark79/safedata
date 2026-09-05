# SafeData - Full-Metadata Backup Script

[![PayPal](https://img.shields.io/badge/PayPal-Donate-blue?logo=paypal)](https://paypal.me/TomasMark)

Universal backup script for LVM volumes and regular directories. It supports
`rsync` and `tar` backups with **include**, **exclude**, or **all** filtering
rules while preserving extended filesystem metadata.

## Concept

**One script, three rule modes:**

1. **INCLUDE mode** - backup **only** listed items
2. **EXCLUDE mode** - backup **everything except** listed items
3. **ALL mode** - backup everything visible on the selected filesystem (no filters)

## Usage

```bash
./safedata.sh <RULES_FILE> <BACKUP_METHOD> <VOLUME1> [VOLUME2 ...]
```

The script requires root privileges and automatically restarts itself with
`sudo` while preserving all `SAFEDATA_*` environment variables. Run it as your
regular user as shown below instead of prefixing the command with `sudo`.

### Parameters

#### 1. RULES_FILE
Mode is detected from filename pattern. Rules files are stored in `./rules/` directory.

**INCLUDE mode:**
- `*_include.rules` or `*_included.rules` or `included.rules`

**EXCLUDE mode:**
- `*_exclude.rules` or `*_excluded.rules` or `excluded.rules`

**ALL mode:**
- `*_all.rules` or `all.rules`

#### 2. BACKUP_METHOD
- `rsync` - Rsync with timestamp (new backup each time)
- `rsync_notimestamp` - Rsync into a stable directory without timestamped versions
- `tar` - Tar archive with timestamp
- `folder_rsync` - Non-timestamped rsync without LVM snapshot
- `folder_tar` - Tar without LVM snapshot

`rsync_notimestamp` and `folder_rsync` update an existing destination but do not
delete remote files that have disappeared from the source.

#### 3. VOLUME
- LVM volume name (e.g., `lv_home`, `lv_var`)
- Directory path (e.g., `/boot`) for folder_* methods

## Examples

SafeData creates backups but does not provide a separate restore command. Restore
data directly with `rsync` or `tar`, depending on the backup method used. Always
use the metadata options shown below: rsync privileged metadata is encoded using
`--fake-super` and would otherwise not be restored. The commands use the
environment variables from the [Configuration](#configuration) section.

> Restore into an empty temporary directory first. Verify its contents before
> copying data to the original filesystem.

### Include only selected files

**Backup:**

```bash
# Back up only paths listed in included.rules
./safedata.sh included.rules rsync_notimestamp lv_home
```

**Restore:**

```bash
# Create a temporary restore directory
sudo mkdir -p /mnt/restore/lv_home

# Restore the non-timestamped rsync backup
sudo rsync -aHAXS --numeric-ids -M--fake-super \
  -e "ssh -i ${SAFEDATA_SSH_KEY_PATH} -o UserKnownHostsFile=${SAFEDATA_SSH_KNOWN_HOSTS_PATH} -p ${SAFEDATA_SSH_PORT:-22}" \
  "${SAFEDATA_REMOTE_SSH_USER}@${SAFEDATA_REMOTE_SSH_HOST}:${SAFEDATA_REMOTE_BASE_DIR}/lv_home/" \
  /mnt/restore/lv_home/
```

### Exclude selected files

**Backup:**

```bash
# Back up everything except paths listed in excluded.rules
./safedata.sh excluded.rules tar lv_home
```

**Restore:**

Replace `<hostname>` and `<timestamp>` with the values in the archive name.

```bash
# Create a temporary restore directory
sudo mkdir -p /mnt/restore/lv_home

# Download and extract the selected tar archive
ssh -i "${SAFEDATA_SSH_KEY_PATH}" \
  -o "UserKnownHostsFile=${SAFEDATA_SSH_KNOWN_HOSTS_PATH}" \
  -p "${SAFEDATA_SSH_PORT:-22}" \
  "${SAFEDATA_REMOTE_SSH_USER}@${SAFEDATA_REMOTE_SSH_HOST}" \
  "cat '${SAFEDATA_REMOTE_BASE_DIR}/<hostname>_lv_home_<timestamp>.tar.gz'" \
  | sudo tar --extract --gzip --same-owner --same-permissions --numeric-owner \
      --acls --xattrs --xattrs-include='*' --selinux --sparse \
      -C /mnt/restore/lv_home/
```

### Backup everything

**Backup:**

```bash
# Back up the complete lv_root volume without filters
./safedata.sh all.rules tar lv_root
```

**Restore:**

Replace `<hostname>` and `<timestamp>` with the values in the archive name.

```bash
# Create a temporary restore directory
sudo mkdir -p /mnt/restore/lv_root

# Download and extract the complete tar archive
ssh -i "${SAFEDATA_SSH_KEY_PATH}" \
  -o "UserKnownHostsFile=${SAFEDATA_SSH_KNOWN_HOSTS_PATH}" \
  -p "${SAFEDATA_SSH_PORT:-22}" \
  "${SAFEDATA_REMOTE_SSH_USER}@${SAFEDATA_REMOTE_SSH_HOST}" \
  "cat '${SAFEDATA_REMOTE_BASE_DIR}/<hostname>_lv_root_<timestamp>.tar.gz'" \
  | sudo tar --extract --gzip --same-owner --same-permissions --numeric-owner \
      --acls --xattrs --xattrs-include='*' --selinux --sparse \
      -C /mnt/restore/lv_root/
```

### Timestamped rsync backup

Backups created with the `rsync` method have a timestamp in their directory
name. Replace `<timestamp>` with the required backup version.

**Backup:**

```bash
# Create a new timestamped backup of the complete lv_home volume
./safedata.sh all.rules rsync lv_home
```

**Restore:**

```bash
# List the available lv_home backup versions
ssh -i "${SAFEDATA_SSH_KEY_PATH}" \
  -o "UserKnownHostsFile=${SAFEDATA_SSH_KNOWN_HOSTS_PATH}" \
  -p "${SAFEDATA_SSH_PORT:-22}" \
  "${SAFEDATA_REMOTE_SSH_USER}@${SAFEDATA_REMOTE_SSH_HOST}" \
  "ls -1d '${SAFEDATA_REMOTE_BASE_DIR}'/lv_home_*"

# Create a temporary restore directory
sudo mkdir -p /mnt/restore/lv_home

# Restore the selected timestamped backup
sudo rsync -aHAXS --numeric-ids -M--fake-super \
  -e "ssh -i ${SAFEDATA_SSH_KEY_PATH} -o UserKnownHostsFile=${SAFEDATA_SSH_KNOWN_HOSTS_PATH} -p ${SAFEDATA_SSH_PORT:-22}" \
  "${SAFEDATA_REMOTE_SSH_USER}@${SAFEDATA_REMOTE_SSH_HOST}:${SAFEDATA_REMOTE_BASE_DIR}/lv_home_<timestamp>/" \
  /mnt/restore/lv_home/
```

## Rules File Configuration

### all.rules (All mode)

```bash
# File can be empty or contain only comments
# In ALL mode, all rules are ignored
```

This mode backs up everything visible on the selected source filesystem. Other
mounted filesystems and bind-mounted content must be backed up separately.

### included.rules (Include mode)

```bash
# Only these items will be backed up
Documents/report.pdf
Pictures/family.jpg
.ssh/config
```

**Rules:**

- Relative paths from volume root
- No leading/trailing slashes
- Explicit paths work with both `rsync` and `tar`
- Parent directories of explicit paths are automatically included for `rsync`
- Wildcard includes are method-dependent: with `rsync`, include a parent path
  such as `Documents/*.pdf`; use explicit paths for predictable `tar` backups

### excluded.rules (Exclude mode)

```bash
# These items will NOT be backed up
.cache
*.tmp
lost+found
```

**Rules:**

- Relative paths
- A leading slash anchors a pattern to the root of the backup source
- Without a leading slash, a pattern may match at any directory level
- Do not use trailing slashes
- Wildcard syntax and matching follow the selected backup tool (`rsync` or `tar`)
- Everything else will be backed up

## Configuration

Configure SafeData with environment variables. Keep host-specific values in your shell, systemd unit, NixOS module, or another private deployment layer.

```bash
export SAFEDATA_SSH_KEY_PATH="/path/to/backup_key"
export SAFEDATA_SSH_KNOWN_HOSTS_PATH="/path/to/known_hosts"
export SAFEDATA_REMOTE_SSH_USER="backup-user"
export SAFEDATA_REMOTE_SSH_HOST="backup.example.com"
export SAFEDATA_REMOTE_BASE_DIR="/remote/backup/safedata"

# Optional defaults:
export SAFEDATA_VG_NAME="vg_main"
export SAFEDATA_LVM_SNAP_SIZE="80G"
export SAFEDATA_LOG_FILE="$HOME/.local/share/safedata/logs/activity.log"
export SAFEDATA_SSH_PORT="22"
export SAFEDATA_SSH_CONNECT_TIMEOUT="10"
export SAFEDATA_SSH_RETRY_COUNT="6"
export SAFEDATA_SSH_RETRY_DELAY="15"
export SAFEDATA_AC_CHECK_INTERVAL="10"
```

Required variables are `SAFEDATA_SSH_KEY_PATH`,
`SAFEDATA_SSH_KNOWN_HOSTS_PATH`, `SAFEDATA_REMOTE_SSH_USER`,
`SAFEDATA_REMOTE_SSH_HOST`, and `SAFEDATA_REMOTE_BASE_DIR`.

The directory specified by `SAFEDATA_REMOTE_BASE_DIR` must already exist on the
remote server. The SSH user must be able to write files and user extended
attributes there.

Before every rsync run, SafeData creates and removes a small hidden probe in the
configured target. The backup starts only if the probe confirms that remote
`--fake-super` metadata can be stored successfully.

## How LVM Snapshot Works

1. Script creates LVM volume snapshot
2. Mounts snapshot to `/mnt/snap_*`
3. Backs up data from snapshot (consistent point-in-time)
4. Unmounts and removes snapshot

**Advantage:** System can run normally while snapshot captures the state at a specific moment.

## Important Notes

### Preserved Metadata

Rsync backups use `-aHAXS --numeric-ids` to preserve standard Unix metadata,
hard links, ACLs, extended attributes, numeric ownership, and sparse allocation.
Because the remote SSH user is not expected to be root, `--fake-super` stores
privileged metadata in `user.rsync.*` extended attributes. The remote filesystem
must support user xattrs, and restoration must use `-M--fake-super` as shown in
the examples.

Tar backups store numeric ownership, ACLs, extended attributes, SELinux labels,
sparse files, and the metadata GNU tar preserves by default, including modes,
timestamps, symlinks, and hard links.

This is a filesystem-level backup, not a forensic disk image. Filesystem-specific
flags, inode numbers, creation time, and change time are not guaranteed to be
preserved.

### Symlinks
Script preserves symlinks **as symlinks** (not their content) with original absolute paths. For proper restoration, restore both source directory and symlink targets.

### Bind Mounts
LVM snapshot **does not capture** bind mounts! Bind mounts are at filesystem level.

**Solution:** Back up bind mounts separately from their original location:
```bash
# If you have: mount --bind /mnt/data/photos /home/user/Photos
# Back up the original location
./safedata.sh included.rules folder_rsync /mnt/data/photos
```

### AC Power Requirement

On a system that exposes an AC adapter, SafeData starts only while external
power is connected. It also stops a running backup if external power is
disconnected. `SAFEDATA_AC_CHECK_INTERVAL` controls how often the power state is
checked. Desktops and virtual machines without a detectable AC adapter are not
blocked.

## Mode Comparison

| Situation | Mode | Reason |
|---------|-------|-------|
| Only Documents + Photos | **include** | Clearly define what you want |
| Entire /home except cache | **exclude** | Simpler than listing everything |
| Everything on one filesystem | **all** | No filtering rules are applied |
| First system backup | **all** | Broadest coverage of the selected filesystem |
| Regular /home backup | **include** | Save space, backup only important |
| System partition (/var, /root) | **all** or **exclude** | Better to have everything |

## Logging

SafeData appends operational messages to:

```bash
$HOME/.local/share/safedata/logs/activity.log
```

The same operational messages are also sent to the systemd journal:

```bash
journalctl -t safedata
```

The `activity.log` file does not contain the complete `rsync` output required by
the statistics viewer. To collect statistics, capture each `rsync` backup run in
a separate timestamped log:

```bash
# Make pipeline failures propagate to the shell
set -o pipefail

# Create the directory used by the statistics viewer
mkdir -p "$HOME/.local/share/safedata/logs"

# Capture one complete rsync backup run in a compatible log file
backup_log="$HOME/.local/share/safedata/logs/safedata_$(date +%F_%H-%M-%S).log"
./safedata.sh all.rules rsync lv_home 2>&1 | tee "$backup_log"
```

Compatible log names use the format `safedata_YYYY-MM-DD_HH-MM-SS.log` or
`safedata_shared_YYYY-MM-DD_HH-MM-SS.log`.

## Statistics and Monitoring

SafeData includes a tool for extracting and visualizing statistics from captured
`rsync` logs. Tar backups do not produce the transfer fields expected by the
statistics viewer and are therefore not included.

### Quick Start

**First-time setup** - Clone repository with submodules:
```bash
git clone --recursive https://github.com/tomasmark79/safedata.git
```

Or if you already cloned without `--recursive`:
```bash
git submodule update --init --recursive
```

View statistics and graphs:
```bash
./show_stats.sh
```

With the Nix package:
```bash
safedata-stats
# or from the repository:
nix run .#stats
```

This will:

1. Automatically extract statistics from all compatible logs (if needed)
2. Show an interactive menu with graphs and statistics

### Menu Options

1. **Sent Over Time (MB)** - Graph of transferred data per backup in megabytes
2. **Transfer Speed Over Time (MB/sec)** - Network/disk transfer speed trends  
3. **Elapsed Time Over Time (seconds)** - Backup duration trends
4. **Total Backup Size Over Time (GB)** - Total size of backed up data in gigabytes
5. **All graphs** - Display all 4 graphs at once
6. **Summary statistics** - Overview with key graphs

### Command-Line Usage

You can also run specific graphs directly:
```bash
./show_stats.sh 1    # Show sent bytes graph
./show_stats.sh 5    # Show all graphs
./show_stats.sh 6    # Show summary statistics
```

### Example Output

```
=== Sent Over Time (MB) ===
Sent Over Time (MB)
    21958 │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠁⠀⠀
     9762 │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠂⠀⠀
        6 │⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⢄⣀⣀⣀⣀⣀⣀⡀⣀
          └──────────────────────────────────────────

=== Transfer Speed (MB/sec) ===
Transfer Speed (MB/sec)
      9.2 │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠁⠀⠀
      4.2 │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
      0.1 │⠌⣀⢄⣀⣀⣀⣀⡠⣀⡀⠤⢄⠤⠤⡠⠤⠤⠤⠤⠤⠤⠤⠤⠔⠠⣀⣀⣀⣀⢂⡀
          └──────────────────────────────────────────
```

### Statistics Tracked

From each compatible `rsync` log, the script extracts:

- **Sent/received bytes** - Amount of data transferred
- **Transfer speed** (bytes/sec) - How fast data was sent
- **Backup duration** (seconds) - Total elapsed time  
- **Total backup size** - Complete size of backed up data
- **Speedup factor** - rsync efficiency metric

Extracted data is stored in CSV format at:

```
~/.local/share/safedata/logs/stats.csv
```

The script automatically updates the CSV file when it finds a newer compatible
log.

### Requirements

- Python 3 (for uchart visualization)
- `show_stats.sh` - Main script (includes extraction + visualization)
- `uchart` submodule - Chart renderer ([MIT License](https://github.com/Danlino/uchart))

**Note:** The `uchart` tool is included as a git submodule. Make sure to clone the repository with `--recursive` flag or run `git submodule update --init --recursive` to download it.

### Credits

This tool uses **uchart** by Danlino for terminal-based chart rendering.
- Project: https://github.com/Danlino/uchart
- License: MIT License
- uchart is a standalone Python script with zero dependencies that creates beautiful charts using Unicode Braille characters.

## Tips

### Testing rules before backup
```bash
# Test exclude (what WILL be backed up):
rsync -avn --exclude-from=rules/excluded.rules /source/ /dest/

# Quick overview of changes:
rsync -avn --exclude-from=rules/excluded.rules /local/ user@host:/remote/

# Check backup size:
du -sh /home/user/Documents
```
