"""Přenosy do dočasného cíle bez SSH, LVM a uživatelských souborů."""

import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "safedata.sh"


def function_source(name):
    match = re.search(rf"^{name}\(\) \{{\n.*?^\}}", SOURCE.read_text(), re.M | re.S)
    if not match:
        raise AssertionError(f"Missing function: {name}")
    return match.group(0)


class TransferTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="safedata-transfer-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source with spaces"
        self.source.mkdir()
        self.remote = self.root / "remote's $(touch REMOTE_PWNED); `touch BACKTICKED`\nline"
        self.remote.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.events = self.root / "events.jsonl"
        self.rules = self.root / "rules with spaces $(touch RULE_PWNED).rules"
        self.rules.write_text("")
        self.harness = self.root / "harness.sh"
        self.harness.write_text(
            "set -euo pipefail\n"
            "SSH_OPTIONS=(-i \"key's \\$(literal)\" -p 22)\n"
            "REMOTE_SSH_USER=fixture\nREMOTE_SSH_HOST=fixture.invalid\n"
            "TAR_METADATA_ARGS=(--numeric-owner --acls --xattrs '--xattrs-include=*' --selinux --sparse)\n"
            "run_with_ac_monitor() { shift; \"$@\"; }\n"
            + "\n".join(function_source(name) for name in (
                "quote_remote_path", "build_tar_args", "build_rsync_args", "run_tar_with_ac_monitor"
            ))
            + "\ncase $1 in\n"
            " transfer) build_tar_args \"$2\" \"$3\"; "
            "run_tar_with_ac_monitor fixture \"$4\" \"$5\";;\n"
            " rsync) build_rsync_args include \"$2\"; printf '%s\\0' \"${RSYNC_ARGS[@]}\";;\n"
            "esac\n"
        )
        self.write_executable("ssh", r'''import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

command = sys.argv[-1]
event = {"argv": sys.argv[1:], "command": command,
         "partial_sizes": [p.stat().st_size for p in Path(os.environ["REMOTE_DIR"]).glob("*.partial")]}
with open(os.environ["EVENTS"], "a") as output:
    output.write(json.dumps(event) + "\n")
if command.startswith("test ! -e") and os.environ.get("SSH_MODE") == "rename_fail":
    print("fixture rename failed", file=sys.stderr)
    sys.exit(9)
if command.startswith("test ! -e") and os.environ.get("SSH_MODE") == "final_exists":
    Path(shlex.split(command)[3]).write_text("existing complete archive")
if command.startswith("test ! -e") and os.environ.get("SSH_MODE") == "final_symlink":
    Path(shlex.split(command)[3]).symlink_to("missing-archive-target")
if command.startswith("umask") and os.environ.get("SSH_MODE") == "write_fail":
    print("fixture writer failed", file=sys.stderr)
    sys.exit(23)
if command.startswith("umask") and os.environ.get("SSH_MODE") == "partial_exists":
    Path(shlex.split(command)[-1]).write_text("existing incomplete archive")
sys.exit(subprocess.run([os.environ["POSIX_SH"], "-c", command]).returncode)
''')
        self.write_executable("tar", r'''import os
from pathlib import Path
import sys
import time

mode = os.environ.get("TAR_MODE")
if mode in ("fail", "wait"):
    sys.stdout.buffer.write(b"fixture incomplete archive\n")
    sys.stdout.buffer.flush()
    if mode == "wait":
        Path(os.environ["READY"]).touch()
        time.sleep(30)
    print("fixture producer failed", file=sys.stderr)
    sys.exit(2)
os.execv(os.environ["REAL_TAR"], [os.environ["REAL_TAR"], *sys.argv[1:]])
''')
        self.env = os.environ | {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "EVENTS": str(self.events),
            "REMOTE_DIR": str(self.remote),
            "READY": str(self.root / "ready"),
            "REAL_TAR": shutil.which("tar"),
            "POSIX_SH": shutil.which("sh"),
        }

    def write_executable(self, name, contents):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + contents)
        path.chmod(0o755)

    def command(self, mode="all"):
        return ["bash", str(self.harness), "transfer", mode, str(self.rules),
                str(self.source), str(self.remote / "fixture_20261023_123456.tar.gz")]

    def run_transfer(self, mode="all", **environment):
        return subprocess.run(self.command(mode), cwd=self.root, env=self.env | environment,
                              text=True, capture_output=True, timeout=10)

    def read_events(self):
        return [json.loads(line) for line in self.events.read_text().splitlines()]

    def read_archive(self):
        archives = list(self.remote.glob("*.tar.gz"))
        self.assertEqual(len(archives), 1)
        with tarfile.open(archives[0]) as archive:
            return {name.removeprefix("./"): archive.extractfile(name).read()
                    for name in archive.getnames() if archive.getmember(name).isfile()}

    def assert_no_injection(self):
        for marker in ("REMOTE_PWNED", "BACKTICKED", "RULE_PWNED", "RULE_CONTENT_PWNED"):
            self.assertFalse((self.root / marker).exists(), marker)

    def test_all_transfers_then_publishes_complete_archive(self):
        (self.source / "sample.txt").write_text("complete data")
        result = self.run_transfer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_archive(), {"sample.txt": b"complete data"})
        events = self.read_events()
        self.assertEqual(len(events), 2)
        self.assertTrue(events[0]["command"].startswith("umask"))
        self.assertTrue(events[1]["command"].startswith("test ! -e"))
        self.assertGreater(events[1]["partial_sizes"][0], 0)
        self.assertEqual(events[0]["argv"][:-2], ["-i", "key's $(literal)", "-p", "22"])
        self.assertEqual(list(self.remote.glob("*.partial")), [])
        self.assert_no_injection()

    def test_include_rules_are_literal_arguments(self):
        names = ["space name.txt", "$(touch RULE_CONTENT_PWNED); file.txt",
                 "quote' and `touch BACKTICKED`.txt", "--checkpoint-action=exec=touch RULE_CONTENT_PWNED"]
        for name in names:
            (self.source / name).write_text(name)
        (self.source / "excluded").write_text("excluded")
        self.rules.write_text("\n".join(names) + "\n")
        result = self.run_transfer("include")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(self.read_archive()), set(names))
        self.assert_no_injection()

    def test_exclude_rules_keep_shell_metacharacters_and_spaces(self):
        name = "$(touch RULE_CONTENT_PWNED); space name.txt"
        (self.source / name).write_text("excluded")
        (self.source / "kept").write_text("retained")
        self.rules.write_text("/" + name + "\n")
        result = self.run_transfer("exclude")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_archive(), {"kept": b"retained"})
        self.assert_no_injection()

    def test_empty_include_rules_fail_before_ssh(self):
        self.rules.write_text("# comment\n   \n")
        result = self.run_transfer("include")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No items to include", result.stdout)
        self.assertFalse(self.events.exists())

    def test_producer_failure_never_publishes(self):
        result = self.run_transfer(TAR_MODE="fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture producer failed", result.stderr)
        self.assertIn("tar=2, ssh=0", result.stderr)
        self.assertEqual(len(self.read_events()), 1)
        self.assertEqual(list(self.remote.glob("*.tar.gz")), [])
        partials = list(self.remote.glob("*.partial"))
        self.assertEqual(len(partials), 1)
        self.assertIn(b"incomplete", partials[0].read_bytes())

    def test_ssh_writer_failure_never_publishes(self):
        result = self.run_transfer(SSH_MODE="write_fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture writer failed", result.stderr)
        self.assertIn("ssh=23", result.stderr)
        self.assertEqual(len(self.read_events()), 1)
        self.assertEqual(list(self.remote.glob("*.tar.gz")), [])

    def test_rename_failure_leaves_visible_partial(self):
        result = self.run_transfer(SSH_MODE="rename_fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture rename failed", result.stderr)
        self.assertIn("Could not publish completed archive", result.stderr)
        self.assertEqual(list(self.remote.glob("*.tar.gz")), [])
        self.assertEqual(len(list(self.remote.glob("*.partial"))), 1)

    def test_two_runs_have_different_final_names(self):
        for _ in range(2):
            result = self.run_transfer()
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list(self.remote.glob("*.tar.gz"))), 2)

    def test_existing_complete_archive_is_not_replaced(self):
        result = self.run_transfer(SSH_MODE="final_exists")
        self.assertNotEqual(result.returncode, 0)
        archives = list(self.remote.glob("*.tar.gz"))
        self.assertEqual(len(archives), 1)
        self.assertEqual(archives[0].read_text(), "existing complete archive")
        self.assertEqual(len(list(self.remote.glob("*.partial"))), 1)

    def test_existing_dangling_symlink_is_not_replaced(self):
        result = self.run_transfer(SSH_MODE="final_symlink")
        self.assertNotEqual(result.returncode, 0)
        archives = list(self.remote.glob("*.tar.gz"))
        self.assertEqual(len(archives), 1)
        self.assertTrue(archives[0].is_symlink())
        self.assertEqual(len(list(self.remote.glob("*.partial"))), 1)

    def test_existing_partial_is_not_replaced(self):
        result = self.run_transfer(SSH_MODE="partial_exists")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.remote.glob("*.tar.gz")), [])
        partials = list(self.remote.glob("*.partial"))
        self.assertEqual(len(partials), 1)
        self.assertEqual(partials[0].read_text(), "existing incomplete archive")

    def test_interrupted_producer_keeps_partial_without_final_rename(self):
        process = subprocess.Popen(self.command(), cwd=self.root,
                                   env=self.env | {"TAR_MODE": "wait"},
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while not ((self.root / "ready").exists() and self.events.exists()
                       and any(p.stat().st_size for p in self.remote.glob("*.partial"))):
                if time.monotonic() >= deadline:
                    self.fail("producer did not start")
                time.sleep(0.01)
            os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=5)
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(list(self.remote.glob("*.tar.gz")), [])
            self.assertEqual(len(self.read_events()), 1)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate()

    def test_absolute_rsync_include_does_not_loop_at_root(self):
        self.rules.write_text("/home/tomas/document.txt\n")
        result = subprocess.run(["bash", str(self.harness), "rsync", str(self.rules)],
                                env=self.env, capture_output=True, timeout=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"--include=/home/\0", result.stdout)
        self.assertIn(b"--include=/home/tomas/\0", result.stdout)


if __name__ == "__main__":
    unittest.main()
