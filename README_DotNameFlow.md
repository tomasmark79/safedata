# DotName Backup Workflow

## Manual Backup Execution Using Command for Specific Volume

```bash
# /boot
~/dev/bash/safedata/safedata.sh all.rules folder_tar /boot

# /home/shared
~/dev/bash/safedata/safedata.sh home_shared_excluded.rules rsync_notimestamp lv_home_shared

# fedora43 /home
~/dev/bash/safedata/safedata.sh home_excluded.rules rsync_notimestamp lv_home_f43

# fedora43 /, /usr/local, /var
~/dev/bash/safedata/safedata.sh root_excluded.rules tar lv_root_f43
~/dev/bash/safedata/safedata.sh var_excluded.rules tar lv_var_f43
```

## Backup Functions Defined in .bashrc

```bash
backuphomes() {
    ~/dev/bash/safedata/safedata.sh home_excluded.rules rsync_notimestamp lv_home_f43
    ~/dev/bash/safedata/safedata.sh home_shared_excluded.rules rsync_notimestamp lv_home_shared
}

backupsystems() {
    ~/dev/bash/safedata/safedata.sh all.rules folder_tar /boot
    ~/dev/bash/safedata/safedata.sh root_excluded.rules tar lv_root_f43
    ~/dev/bash/safedata/safedata.sh var_excluded.rules tar lv_var_f43
}
```

## Service Management Commands

