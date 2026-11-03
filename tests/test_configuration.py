"""Neplatný rozpočet musí skončit ještě před vytvořením logů či zálohy."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "safedata.sh"


class ConfigurationTests(unittest.TestCase):
    def test_valid_cleanup_timeout_and_default(self):
        text = SOURCE.read_text()
        validation = text[text.index('SNAPSHOT_CLEANUP_TIMEOUT='):text.index('VG_NAME=')]
        for value, expected in [(None, "300"), ("1", "1"), ("00300", "300"), ("86400", "86400")]:
            with self.subTest(value=value):
                env = os.environ.copy()
                env.pop("SAFEDATA_SNAPSHOT_CLEANUP_TIMEOUT", None)
                if value is not None:
                    env["SAFEDATA_SNAPSHOT_CLEANUP_TIMEOUT"] = value
                result = subprocess.run(["bash", "-c", validation + '\nprintf "%s" "$SNAPSHOT_CLEANUP_TIMEOUT"'],
                                        env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)

    def test_invalid_cleanup_timeout_has_no_side_effects(self):
        for value in ["", "-1", "0", "1.5", "abc", "86401", "999999999999999999999"]:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as root:
                log = Path(root) / "logs/activity.log"
                env = os.environ | {
                    "SAFEDATA_SNAPSHOT_CLEANUP_TIMEOUT": value,
                    "SAFEDATA_LOG_FILE": str(log),
                    "SAFEDATA_SSH_KEY_PATH": "fixture",
                    "SAFEDATA_SSH_KNOWN_HOSTS_PATH": "fixture",
                    "SAFEDATA_REMOTE_SSH_USER": "fixture",
                    "SAFEDATA_REMOTE_SSH_HOST": "fixture.invalid",
                    "SAFEDATA_REMOTE_BASE_DIR": "fixture",
                }
                result = subprocess.run(["bash", str(SOURCE)], env=env, text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("SAFEDATA_SNAPSHOT_CLEANUP_TIMEOUT", result.stderr)
                self.assertFalse(log.parent.exists())
