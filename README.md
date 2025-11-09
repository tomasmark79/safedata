# SafeData - Universal Backup Script

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

### Selective backup - documents only
```bash
sudo ./safedata.sh documents_include.rules rsync_notimestamp lv_home
```

### Backup everything except cache
```bash
sudo ./safedata.sh cache_exclude.rules tar lv_home
```

### Full system backup
```bash
sudo ./safedata.sh all.rules tar lv_root
```

### Boot partition backup (no LVM)
```bash
sudo ./safedata.sh all.rules folder_tar /boot
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
tomas/Documents
tomas/Pictures
tomas/.ssh
tomas/.config
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
.thumbnails
.local/share/Trash
*.tmp
lost+found
```

**Rules:**
- Relative paths
- No leading/trailing slashes
- Supports wildcards
- Everything else will be backed up

## ⚙️ Configuration

Edit variables at the beginning of `safedata.sh`:

```bash
VG_NAME="vg_main"                              # Volume group name
SNAP_SIZE="80G"                                # Snapshot size
LOG_FILE="/var/log/safedata.log"              # Log file path
SSH_PORT=7922                                  # SSH port for remote backup
SSH_USER="tomas"                               # SSH username
SSH_HOST="192.168.79.11"                       # Remote backup server
REMOTE_BASE_DIR="/volume1/homebackup/safedata" # Remote backup directory
```

## 🔄 How LVM Snapshot Works

1. Script creates LVM volume snapshot
2. Mounts snapshot to `/mnt/snap_*`
3. Backs up data from snapshot (consistent point-in-time)
4. Unmounts and removes snapshot

**Advantage:** System can run normally while snapshot captures the state at a specific moment.

## ⚠️ Important Notes

### Symlinks
Script preserves symlinks **as symlinks** (not their content) with original absolute paths. For proper restoration, restore both source directory and symlink targets (e.g., `/home` and `/home/shared`).

### Bind Mounts
LVM snapshot **does not capture** bind mounts! Bind mounts are at filesystem level.

**Solution:** Backup bind mounts separately from their original location:
```bash
# If you have: mount --bind /mnt/data/photos /home/tomas/Photos
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
/var/log/safedata.log
```

And to systemd journal:
```bash
journalctl -t safedata
```

## 💡 Tips

### Testing rules before backup
```bash
# Test exclude (what WILL be backed up):
rsync -avn --exclude-from=rules/excluded.rules /source/ /dest/

# Quick overview of changes:
rsync -avn --exclude-from=rules/excluded.rules /local/ user@host:/remote/

# Check backup size:
du -sh /home/tomas/Documents
```