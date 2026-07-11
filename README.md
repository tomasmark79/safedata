# SafeData - Universal Backup Script

> 🌱 **Help Keep This Going**
> Your support makes a real difference. If you value my work and want to help me continue creating, please consider making a donation.  
> 💙 **Donate here:** [https://paypal.me/TomasMark](https://paypal.me/TomasMark)
> Every contribution is truly appreciated ✨

Universal backup script with **include**, **exclude**, and **all** modes support.

## 🎯 Concept

**One script, three modes:**

1. **INCLUDE mode** - backup **only** listed items
2. **EXCLUDE mode** - backup **everything except** listed items
3. **ALL mode** - backup **absolutely everything** (no filters)

## 📋 Usage

```bash
./safedata.sh <RULES_FILE> <BACKUP_METHOD> <VOLUME1> [VOLUME2 ...]
```

### Parameters:

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
- `rsync_notimestamp` - Rsync without timestamp (overwrites previous)
- `tar` - Tar archive with timestamp
- `folder_rsync` - Rsync without LVM snapshot
- `folder_tar` - Tar without LVM snapshot

#### 3. VOLUME
- LVM volume name (e.g., `lv_home`, `lv_var`)
- Directory path (e.g., `/boot`) for folder_* methods

## 🚀 Examples

### Include only selected files
```bash
sudo ./safedata.sh included.rules rsync_notimestamp lv_home
```

### Exclude selected files
```bash
sudo ./safedata.sh excluded.rules tar lv_home
```

### Backup everything
```bash
sudo ./safedata.sh all.rules tar lv_root
```

## 📝 Rules File Configuration

### all.rules (All mode)
```bash
# File can be empty or contain only comments
# In ALL mode, all rules are ignored and everything is backed up
```

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
- Supports wildcards: `*.txt`, `vmlinuz*`
- Parent directories are automatically included

### excluded.rules (Exclude mode)
```bash
# These items will NOT be backed up
.cache
*.tmp
lost+found
```

**Rules:**
- Relative paths
- No leading/trailing slashes
- Supports wildcards
- Everything else will be backed up

## ⚙️ Configuration

Configure SafeData with environment variables. Keep host-specific values in your shell, systemd unit, NixOS module, or another private deployment layer.

```bash
export SAFEDATA_SSH_KEY_PATH="/path/to/backup_key"
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

Required variables are `SAFEDATA_SSH_KEY_PATH`, `SAFEDATA_REMOTE_SSH_USER`, `SAFEDATA_REMOTE_SSH_HOST`, and `SAFEDATA_REMOTE_BASE_DIR`.

## 🔄 How LVM Snapshot Works

1. Script creates LVM volume snapshot
2. Mounts snapshot to `/mnt/snap_*`
3. Backs up data from snapshot (consistent point-in-time)
4. Unmounts and removes snapshot

**Advantage:** System can run normally while snapshot captures the state at a specific moment.

## ⚠️ Important Notes

### Symlinks
Script preserves symlinks **as symlinks** (not their content) with original absolute paths. For proper restoration, restore both source directory and symlink targets.

### Bind Mounts
LVM snapshot **does not capture** bind mounts! Bind mounts are at filesystem level.

**Solution:** Backup bind mounts separately from their original location:
```bash
# If you have: mount --bind /mnt/data/photos /home/user/Photos
# Backup the original:
sudo ./safedata.sh included.rules folder_rsync /mnt/data/photos
```

## 📊 Mode Comparison

| Situation | Mode | Reason |
|---------|-------|-------|
| Only Documents + Photos | **include** | Clearly define what you want |
| Entire /home except cache | **exclude** | Simpler than listing everything |
| Everything | **all** | No filters, complete backup |
| First system backup | **all** | Safest, nothing is lost |
| Regular /home backup | **include** | Save space, backup only important |
| System partition (/var, /root) | **all** or **exclude** | Better to have everything |

## 🔍 Logging

Logs are saved to:
```bash
$HOME/.local/share/safedata/logs/activity.log
```

And to systemd journal:
```bash
journalctl -t safedata
```

## 📊 Statistics and Monitoring

Safedata includes a tool for extracting and visualizing backup statistics from logs.

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
1. Automatically extract statistics from all logs (if needed)
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

From each backup log, the script extracts:
- **Sent/received bytes** - Amount of data transferred
- **Transfer speed** (bytes/sec) - How fast data was sent
- **Backup duration** (seconds) - Total elapsed time  
- **Total backup size** - Complete size of backed up data
- **Speedup factor** - rsync efficiency metric

All data is automatically extracted from log files and stored in CSV format at:
```
~/.local/share/safedata/logs/stats.csv
```

The script automatically updates statistics when new backup logs are found.

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

## 💡 Tips

### Testing rules before backup
```bash
# Test exclude (what WILL be backed up):
rsync -avn --exclude-from=rules/excluded.rules /source/ /dest/

# Quick overview of changes:
rsync -avn --exclude-from=rules/excluded.rules /local/ user@host:/remote/

# Check backup size:
du -sh /home/user/Documents
```
