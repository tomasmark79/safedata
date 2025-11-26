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
~/dev/bash/safedata/safedata.sh all.rules tar lv_usr_local_f43
~/dev/bash/safedata/safedata.sh var_excluded.rules tar lv_var_f43
```

## Systemd Timers and Services

### Service for backing up /home
```ini
[Unit]
Description=Safedata by DotName
After=default.target

[Service]
Type=simple
Environment="LOGDIR=/home/tomas/logs/safedata"
ExecStartPre=/bin/sh -c 'mkdir -p ${LOGDIR}'
ExecStartPre=/bin/sh -c 'find ${LOGDIR} -type f -name "safedata_*.log" -mtime +30 -delete'
ExecStart=/bin/sh -c '/home/tomas/dev/bash/safedata/safedata.sh home_excluded.rules rsync_notimestamp lv_home_f43 >> ${LOGDIR}/safedata_$(date +%%Y-%%m-%%d_%%H-%%M-%%S).log 2>&1'
StandardOutput=null
StandardError=null
```

### Timer for running /home backup twice daily at 9:00 and 21:00
```ini
[Unit]
Description=Safedata Timer

[Timer]
OnCalendar=*-*-* 09:00:00
OnCalendar=*-*-* 21:00:00
Persistent=true

[Install]
WantedBy=timers.target
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
    ~/dev/bash/safedata/safedata.sh usrlocal_excluded.rules tar lv_usr_local_f43
    ~/dev/bash/safedata/safedata.sh var_excluded.rules tar lv_var_f43
}
```