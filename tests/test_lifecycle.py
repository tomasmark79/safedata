"""Životní cyklus skutečných funkcí s falešným LVM a vlastními pomocnými procesy."""

import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "safedata.sh"
TEXT = SOURCE.read_text()
STATE = TEXT[TEXT.index('# Stav patří pouze tomuto běhu;'):TEXT.index('check_dependencies() {')]
FUNCTIONS = TEXT[TEXT.index('finish_critical_section() {'):TEXT.index('# Detect mode based on filename pattern')]
MOCKS = r'''
VG_NAME=vg_test
LVM_SNAP_SIZE=1G
AC_CHECK_INTERVAL=0.05
SNAP_LOCK_ROOT="$TEST_ROOT/locks"
CREATE_STATUS=0
MOUNT_STATUS=0
UMOUNT_STATUS=0
REMOVE_STATUS=0
MOUNTPOINT_STATUS=1
log() { printf 'log:%s\n' "$1" >> "$TEST_ROOT/events"; }
lvcreate() { printf 'create:%s\n' "$*" >> "$TEST_ROOT/events"; return "$CREATE_STATUS"; }
mount() { printf 'mount:%s\n' "$*" >> "$TEST_ROOT/events"; return "$MOUNT_STATUS"; }
mountpoint() { return "$MOUNTPOINT_STATUS"; }
umount() { printf 'unmount:%s\n' "$*" >> "$TEST_ROOT/events"; return "$UMOUNT_STATUS"; }
lvremove() { printf 'remove:%s\n' "$*" >> "$TEST_ROOT/events"; return "$REMOVE_STATUS"; }
mktemp() { command mktemp -d "$TEST_ROOT/mount.XXXXXXXXXX"; }
is_on_ac_power() { return 0; }
'''


def is_live(pid):
    try:
        return Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1].split()[0] != "Z"
    except FileNotFoundError:
        return False


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="safedata-lifecycle-")
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def script(self, body, name="case.sh"):
        path = self.root / name
        path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + STATE + FUNCTIONS + MOCKS + body)
        return path

    def run_case(self, body, expected=0):
        result = subprocess.run(
            ["bash", str(self.script(body))],
            env={**os.environ, "TEST_ROOT": str(self.root)},
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, expected, result.stderr + result.stdout)
        return result

    def events(self):
        path = self.root / "events"
        return path.read_text().splitlines() if path.exists() else []

    def operations(self):
        return [line.split(":", 1)[0] for line in self.events() if not line.startswith("log:")]

    def wait_file(self, path, process):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if path.exists() and path.read_text().strip():
                return path.read_text().strip()
            if process.poll() is not None:
                self.fail(f"Pomocný proces skončil předčasně: {process.communicate()}")
            time.sleep(0.02)
        self.fail(f"Pomocný proces nevytvořil {path.name}")

    def start_case(self, body, name="case.sh"):
        process = subprocess.Popen(
            ["bash", str(self.script(body, name))],
            env={**os.environ, "TEST_ROOT": str(self.root)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.addCleanup(lambda: process.poll() is None and process.kill())
        return process

    def test_failed_create_never_removes_colliding_foreign_snapshot(self):
        self.run_case('''
CREATE_STATUS=5
if prepare_snapshot lv_home same_second; then exit 90; else [ "$?" = 5 ]; fi
[ "$SNAP_CREATED" = 0 ]
cleanup
[ -z "$SNAP_LOCK_FD" ]
''')
        self.assertEqual(self.operations(), ["create"])
        self.assertFalse(list(self.root.glob("mount.*")))

    def test_failed_mount_removes_only_created_snapshot(self):
        self.run_case('''
MOUNT_STATUS=9
if prepare_snapshot lv_home now; then exit 90; else [ "$?" = 9 ]; fi
cleanup
''')
        self.assertEqual(self.operations(), ["create", "mount", "remove"])

    def test_failed_mount_with_partial_mount_is_unmounted_before_removal(self):
        self.run_case('''
MOUNT_STATUS=9
MOUNTPOINT_STATUS=0
if prepare_snapshot lv_home now; then exit 90; else [ "$?" = 9 ]; fi
cleanup
''')
        self.assertEqual(self.operations(), ["create", "mount", "unmount", "remove"])

    def test_success_cleanup_order_and_idempotence(self):
        self.run_case('''
prepare_snapshot lv_home now
cleanup
[ "$SNAP_CREATED:$SNAP_MOUNTED:$MNT_DIR_CREATED" = 0:0:0 ]
[ -z "$SNAP_LOCK_FD" ]
cleanup
''')
        self.assertEqual(self.operations(), ["create", "mount", "unmount", "remove"])
        self.assertFalse(list(self.root.glob("mount.*")))

    def test_unmount_failure_keeps_snapshot_directory_and_lock(self):
        self.run_case('''
prepare_snapshot lv_home now
UMOUNT_STATUS=1
if cleanup; then exit 90; fi
[ "$SNAP_CREATED:$SNAP_MOUNTED:$MNT_DIR_CREATED" = 1:1:1 ]
[ -n "$SNAP_LOCK_FD" ]
[ -d "$MNT_DIR" ]
printf 'checkpoint\n' >> "$TEST_ROOT/events"
UMOUNT_STATUS=0
cleanup
''')
        before_retry = self.events()[:self.events().index("checkpoint")]
        self.assertFalse(any(line.startswith("remove:") for line in before_retry))
        self.assertEqual(self.operations(), ["create", "mount", "unmount", "checkpoint", "unmount", "remove"])

    def test_remove_failure_keeps_ownership_and_retry_skips_unmount(self):
        self.run_case('''
prepare_snapshot lv_home now
REMOVE_STATUS=1
if cleanup; then exit 90; fi
[ "$SNAP_CREATED:$SNAP_MOUNTED:$MNT_DIR_CREATED" = 1:0:1 ]
[ -n "$SNAP_LOCK_FD" ]
REMOVE_STATUS=0
cleanup
''')
        self.assertEqual(self.operations(), ["create", "mount", "unmount", "remove", "remove"])

    def test_failed_directory_creation_does_not_touch_lvm(self):
        self.run_case('''
mktemp() { return 8; }
if prepare_snapshot lv_home now; then exit 90; else [ "$?" = 8 ]; fi
cleanup
[ -z "$SNAP_LOCK_FD" ]
''')
        self.assertEqual(self.operations(), [])

    def test_invalid_volume_name_cannot_escape_lock_directory(self):
        self.run_case('''
if prepare_snapshot ../foreign now; then exit 90; fi
''')
        self.assertEqual(self.operations(), [])
        self.assertFalse((self.root / "locks").exists())

    def test_same_timestamp_still_produces_distinct_names(self):
        self.run_case('''
prepare_snapshot lv_home same_second
first="$SNAP_NAME"
cleanup
prepare_snapshot lv_home same_second
[ "$SNAP_NAME" != "$first" ]
cleanup
''')

    def test_same_volume_is_locked_before_snapshot_operations(self):
        first = self.start_case('''
prepare_snapshot lv_home now
printf 'ready\n' > "$TEST_ROOT/ready"
while :; do sleep 0.05; done
''', "owner.sh")
        self.wait_file(self.root / "ready", first)
        contender = self.root / "contender.sh"
        contender.write_text("set -euo pipefail\n" + STATE + FUNCTIONS + MOCKS + '''
if prepare_snapshot lv_home now; then exit 90; fi
''')
        result = subprocess.run(["bash", str(contender)], env={**os.environ, "TEST_ROOT": str(self.root)}, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.operations().count("create"), 1)
        first.send_signal(signal.SIGTERM)
        first.communicate(timeout=5)
        self.assertEqual(first.returncode, 143)

    def test_signal_after_lvcreate_records_ownership_before_cleanup(self):
        self.run_case('''
lvcreate() {
  printf 'create:own\n' >> "$TEST_ROOT/events"
  kill -HUP "$$"
  return 0
}
prepare_snapshot lv_home now
exit 90
''', expected=129)
        self.assertEqual(self.operations(), ["create", "remove"])

    def test_signal_after_mount_still_unmounts_owned_snapshot(self):
        self.run_case('''
mount() {
  printf 'mount:own\n' >> "$TEST_ROOT/events"
  kill -TERM "$$"
  return 0
}
prepare_snapshot lv_home now
exit 90
''', expected=143)
        self.assertEqual(self.operations(), ["create", "mount", "unmount", "remove"])

    def test_signal_during_cleanup_does_not_repeat_successful_unmount(self):
        self.run_case('''
umount() {
  printf 'unmount:own\n' >> "$TEST_ROOT/events"
  kill -HUP "$$"
  return 0
}
prepare_snapshot lv_home now
cleanup
exit 90
''', expected=129)
        self.assertEqual(self.operations(), ["create", "mount", "unmount", "remove"])

    def test_cleanup_failure_turns_success_into_failure(self):
        self.run_case('''
prepare_snapshot lv_home now
UMOUNT_STATUS=1
exit 0
''', expected=1)
        self.assertNotIn("remove", self.operations())

    def test_cleanup_failure_preserves_original_error(self):
        self.run_case('''
prepare_snapshot lv_home now
UMOUNT_STATUS=1
exit 37
''', expected=37)

    def test_nonzero_child_status_is_preserved_with_errexit(self):
        self.run_case('run_with_ac_monitor failure bash -c "exit 23"\n', expected=23)

    def test_unexpected_exit_also_stops_transfer_before_unmount(self):
        self.run_case('''
prepare_snapshot lv_home now
umount() {
  local child
  child=$(cat "$TEST_ROOT/child.pid")
  if kill -0 "$child" 2>/dev/null; then
    printf 'unsafe-unmount\n' >> "$TEST_ROOT/events"
    return 1
  fi
  printf 'unmount:own\n' >> "$TEST_ROOT/events"
}
setsid bash -c 'printf "%s\\n" "$$" > "$1"; while :; do sleep 0.05; done' bash "$TEST_ROOT/child.pid" &
BACKUP_PID=$!
while [ ! -s "$TEST_ROOT/child.pid" ]; do sleep 0.02; done
exit 37
''', expected=37)
        child = int((self.root / "child.pid").read_text())
        self.assertFalse(is_live(child))
        self.assertNotIn("unsafe-unmount", self.events())

    def test_signals_stop_backup_before_unmount(self):
        for sig, expected in [(signal.SIGHUP, 129), (signal.SIGINT, 130), (signal.SIGTERM, 143)]:
            with self.subTest(signal=sig):
                pid_file = self.root / f"child-{sig}.pid"
                body = '''
prepare_snapshot lv_home now
umount() {
  local child
  child=$(cat "$TEST_ROOT/child-SIGNAL.pid")
  if kill -0 "$child" 2>/dev/null; then
    printf 'unsafe-unmount\n' >> "$TEST_ROOT/events"
    return 1
  fi
  printf 'unmount:own\n' >> "$TEST_ROOT/events"
}
run_with_ac_monitor signal bash -c 'printf "%s\\n" "$$" > "$1"; trap "exit 0" TERM; while :; do sleep 0.05; done' bash "$TEST_ROOT/child-SIGNAL.pid"
'''.replace("SIGNAL", str(sig))
                process = self.start_case(body, f"signal-{sig}.sh")
                child = int(self.wait_file(pid_file, process))
                process.send_signal(sig)
                stdout, stderr = process.communicate(timeout=8)
                self.assertEqual(process.returncode, expected, stderr + stdout)
                self.assertFalse(is_live(child))
                self.assertNotIn("unsafe-unmount", self.events())

    def test_termination_reaches_children_after_group_leader_exits(self):
        self.run_case('''
setsid bash -c 'sleep 30 & printf "%s\\n" "$!" > "$1"' bash "$TEST_ROOT/orphan.pid" &
BACKUP_PID=$!
wait "$BACKUP_PID"
terminate_backup
''')
        child = int((self.root / "orphan.pid").read_text())
        self.assertFalse(is_live(child))


if __name__ == "__main__":
    unittest.main()
