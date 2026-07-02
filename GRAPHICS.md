# SafeData - Backup Modes Visualization

## 🎯 Quick Reference

```
╔═════════════════════════════════════════════════════════╗
║  WHEN TO USE EACH MODE                                  ║
╠═════════════════════════════════════════════════════════╣
║                                                         ║
║  INCLUDE Mode                                           ║
║  ════════════                                           ║
║   You know exactly what you need                        ║  
║   Backing up personal documents only                    ║
║   Want to save backup space                             ║
║   Regular incremental backups                           ║
║                                                         ║
║  Example: Documents, Photos, SSH keys                   ║
║                                                         ║
║─────────────────────────────────────────────────────────║
║                                                         ║
║  EXCLUDE Mode                                           ║
║  ════════════                                           ║
║   Easier to list what NOT to backup                     ║
║   Want most of the data                                 ║
║   Exclude only cache/temp files                         ║
║   System directories (skip logs/cache)                  ║
║                                                         ║
║  Example: Everything except .cache, .thumbnails, *.tmp  ║
║                                                         ║
║─────────────────────────────────────────────────────────║
║                                                         ║
║  ALL Mode                                               ║
║  ════════                                               ║
║   First system backup                                   ║
║   Complete disaster recovery image                      ║
║   Archive entire volume                                 ║
║   Don't want to miss anything                           ║
║                                                         ║
║  Example: Full system backup, complete archive          ║
║                                                         ║
╚═════════════════════════════════════════════════════════╝
```

## 📊 Three Backup Modes

```
┌─────────────────────────────────────────────────────────────┐
│                         SAFEDATA.SH                         │
│                    Universal Backup Script                  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
              ┌───────────────────────────┐
              │   Detect Mode from File   │
              │      *_include.rules      │
              │      *_exclude.rules      │
              │         *_all.rules       │
              └───────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
  ┌─────────┐          ┌─────────┐          ┌─────────┐
  │ INCLUDE │          │ EXCLUDE │          │   ALL   │
  │  MODE   │          │  MODE   │          │  MODE   │
  └─────────┘          └─────────┘          └─────────┘
```

---

## 🔄 LVM Snapshot Workflow

```
┌─────────────────────────────────────────────────────────────────┐
│  STEP 1: Create Snapshot                                        │
│                                                                 │
│  ┌──────────────┐                 ┌──────────────┐              │
│  │   Original   │   lvcreate      │   Snapshot   │              │
│  │    Volume    │  ─────────────▶│  (Read-Only  │              │
│  │   lv_home    │    -L 80G       │   Copy)      │              │
│  └──────────────┘                 └──────────────┘              │
│        │                                  │                     │
│        │ System continues                 │ Frozen in time      │
│        │ to run normally                  │ (point-in-time)     │
│        ▼                                  ▼                     │
│  ┌──────────────┐                 ┌──────────────┐              │
│  │ Users keep   │                 │ Perfect for  │              │
│  │ working with │                 │ consistent   │              │
│  │ live data    │                 │ backup!      │              │
│  └──────────────┘                 └──────────────┘              │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  STEP 2: Mount & Backup                                         │
│                                                                 │
│         ┌──────────────┐                                        │
│         │   Snapshot   │                                        │
│         │   Volume     │                                        │
│         └──────┬───────┘                                        │
│                │                                                │
│                │ mount /dev/vg_main/snap_lv_home_20251109       │
│                │       /mnt/snap_lv_home_20251109               │
│                ▼                                                │
│         ┌─────────────────────┐                                 │
│         │  /mnt/snap_...      │                                 │
│         │  ├─ Documents       │                                 │
│         │  ├─ Pictures        │                                 │
│         │  └─ ...             │                                 │
│         └──────┬──────────────┘                                 │
│                │                                                │
│                │ rsync / tar                                    │
│                ▼                                                │
│    ┌────────────────────────┐                                   │
│    │   Remote Server        │                                   │
│    │   backup.example.com   │                                   │
│    │   /remote/backup       │                                   │
│    └────────────────────────┘                                   │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  STEP 3: Cleanup                                                │
│                                                                 │
│         ┌──────────────┐                                        │
│         │   Snapshot   │  umount                                │
│         │   Volume     │  ──────────▶  Unmounted               │
│         └──────────────┘                                        │
│                │                                                │
│                │ lvremove -y                                    │
│                ▼                                                │
│            DELETED                                              │
│         (Space freed)                                           │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🔀 Backup Methods Comparison

```
┌────────────────────────────────────────────────────────────────────┐
│                    BACKUP METHOD DECISION TREE                     │
└────────────────────────────────────────────────────────────────────┘

                         Need Snapshot?
                              │
                ┌─────────────┴─────────────┐
                │                           │
               YES                         NO
         (LVM Volume)              (Regular Directory)
                │                           │
                ▼                           ▼
        ┌───────────────┐          ┌────────────────┐
        │ Create LVM    │          │ Direct Access  │
        │ Snapshot      │          │ to Directory   │
        └───────┬───────┘          └────────┬───────┘
                │                           │
                └─────────────┬─────────────┘
                              │
                    What format needed?
                              │
                ┌─────────────┴─────────────┐
                │                           │
            ARCHIVE                    SYNC/MIRROR
         (Single File)                (Directory Structure)
                │                           │
                ▼                           ▼
        ┌──────────────┐          ┌─────────────────┐
        │     TAR      │          │      RSYNC      │
        │ .tar.gz file │          │  Live directory │
        └──────────────┘          └─────────────────┘
                │                          │
                ▼                          ▼
         Need timestamp?           Need timestamp?
         ┌────┴────┐               ┌─────┴─────┐
         │         │               │           │
        YES       N/A             YES          NO
         │         │               │           │
         ▼         ▼               ▼           ▼
    ┌────────┐  ┌────────┐   ┌─────────┐ ┌──────────────┐
    │  tar   │  │folder_ │   │  rsync  │ │rsync_        │
    │        │  │tar     │   │         │ │notimestamp   │
    └────────┘  └────────┘   └─────────┘ └──────────────┘
      New         New          New          Overwrites
      each        each         each         previous
      time        time         time         backup


┌─────────────────────────────────────────────────────────────────┐
│  METHOD OVERVIEW                                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  rsync              : LVM Snapshot + Rsync + Timestamp          │
│                      ▶ /remote/lv_home_20251109_143022/        │
│                                                                 │
│  rsync_notimestamp  : LVM Snapshot + Rsync (no timestamp)       │
│                      ▶ /remote/lv_home/ (updated in place)     │
│                                                                 │
│  tar                : LVM Snapshot + Tar + Timestamp            │
│                      ▶ /remote/lv_home_20251109_143022.tar.gz  │
│                                                                 │
│  folder_rsync       : Direct Rsync (no snapshot)                │
│                      ▶ /remote/boot/ (updated in place)        │
│                                                                 │
│  folder_tar         : Direct Tar (no snapshot)                  │
│                      ▶ /remote/boot_20251109_143022.tar.gz     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```
