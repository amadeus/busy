#!/usr/bin/env python3
"""Exercise installer guards and upgrade order in a fake filesystem, without root."""

import json
import os
import pathlib
import plistlib
import subprocess
import tempfile
import unittest


SOURCE = pathlib.Path(__file__).resolve().parent
MOCKS = r'''
require_system_target() {
    [[ "${3:-}" == / ]] || fail 'Busy must be installed on the current startup volume.'
}
function /usr/bin/stat() {
    if [[ "$2" == %u ]]; then
        if [[ "$3" == /dev/console ]]; then printf '%s\n' "${BUSY_TEST_CONSOLE_UID:-501}"; else echo 0; fi
    else command /usr/bin/stat "$@"; fi
}
function /usr/bin/pgrep() { return "${BUSY_TEST_PGREP:-1}"; }
function /usr/bin/codesign() { return "${BUSY_TEST_CODESIGN:-0}"; }
function /usr/sbin/chown() { :; }
function /usr/bin/install() {
    [[ "$1" == -d && "$6" == -m ]] || fail 'Unexpected install mock invocation.'
    /bin/mkdir -m "$7" "$8"
}
function /bin/sleep() { :; }
function /bin/launchctl() {
    printf '%s\n' "launchctl $*" >> "$BUSY_TEST_LOG"
    case "$1" in
        print) [[ -f "$BUSY_TEST_ROOT/service-loaded" ]] ;;
        bootout) /bin/rm "$BUSY_TEST_ROOT/service-loaded" ;;
        bootstrap) /usr/bin/touch "$BUSY_TEST_ROOT/service-loaded" ;;
        enable) : ;;
        *) fail 'Unexpected launchctl mock invocation.' ;;
    esac
}
'''


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="busy-installer-", dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.environment = dict(os.environ, BUSY_TEST_ROOT=str(self.root),
                                BUSY_TEST_LOG=str(self.root / "actions.log"))
        self.state = self.root / "Library/Application Support/BusyHelper"
        self.helper = self.root / "Library/PrivilegedHelperTools/com.amadeus.Busy.helper"
        self.plist = self.root / "Library/LaunchDaemons/com.amadeus.Busy.helper.plist"
        for name in ("Applications", "usr/local/bin", "Library/Application Support",
                     "Library/PrivilegedHelperTools", "Library/LaunchDaemons"):
            (self.root / name).mkdir(parents=True, exist_ok=True)
        for kind in ("app", "helper"):
            scripts = self.root / "scripts" / kind
            scripts.mkdir(parents=True)
            for source in (SOURCE / kind).iterdir():
                (scripts / source.name).write_text(self.rewrite(source.read_text()))
            (scripts / "common.sh").write_text(self.rewrite((SOURCE / "common.sh").read_text()) + MOCKS)

    def rewrite(self, text):
        for prefix in ("/Library", "/Applications", "/usr/local"):
            text = text.replace(prefix, str(self.root) + prefix)
        return text

    def run_script(self, kind, name="preinstall", target="/"):
        return subprocess.run(["/bin/bash", str(self.root / "scripts" / kind / name), "Busy.pkg", "/", target],
                              env=self.environment, text=True, capture_output=True, timeout=10)

    def make_existing_helper(self, uid=502, journal=True):
        self.state.mkdir(mode=0o700)
        config = self.state / "config.json"
        config.write_text(json.dumps({"authorizedUID": uid}))
        config.chmod(0o600)
        if journal:
            record = self.state / "journal.json"
            record.write_text('{"previousSleepDisabled":0}')
            record.chmod(0o600)
        self.helper.write_text('''#!/bin/bash
printf '%s\\n' "old helper $*" >> "$BUSY_TEST_LOG"
if [[ "${BUSY_TEST_RECOVERY_FAIL:-0}" == 1 ]]; then exit 1; fi
rm -f "$BUSY_TEST_ROOT/Library/Application Support/BusyHelper/journal.json"
''')
        self.helper.chmod(0o755)
        self.plist.write_text("placeholder launchd plist")
        self.plist.chmod(0o644)
        (self.root / "service-loaded").touch()

    def test_app_install_and_unrelated_cli_guard(self):
        self.assertEqual(self.run_script("app").returncode, 0)
        (self.root / "usr/local/bin/busy").write_text("another tool")
        result = self.run_script("app")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unrelated command", result.stderr)

    def test_unrelated_app_guard(self):
        info = self.root / "Applications/Busy.app/Contents/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "another.app"}))
        self.assertIn("another app", self.run_script("app").stderr)

    def test_running_app_and_other_volume_rejected(self):
        self.environment["BUSY_TEST_PGREP"] = "0"
        self.assertIn("Quit Busy", self.run_script("app").stderr)
        self.assertIn("Quit Busy", self.run_script("helper").stderr)
        self.assertIn("startup volume", self.run_script("helper", target="/Volumes/Other").stderr)

    def test_fresh_helper_pins_console_user(self):
        result = self.run_script("helper")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.state / "config.json").read_text()), {"authorizedUID": 501})
        self.assertFalse((self.root / "actions.log").exists())

    def test_missing_console_user_rejected_before_payload(self):
        self.environment["BUSY_TEST_CONSOLE_UID"] = "0"
        result = self.run_script("helper")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.state.exists())

    def test_upgrade_restores_old_helper_and_preserves_authorized_user(self):
        self.make_existing_helper()
        result = self.run_script("helper")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.state / "config.json").read_text()), {"authorizedUID": 502})
        actions = (self.root / "actions.log").read_text()
        self.assertLess(actions.index("bootout"), actions.index("old helper --restore-only"))
        self.assertNotIn("bootstrap", actions)
        result = self.run_script("helper", "postinstall")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bootstrap", (self.root / "actions.log").read_text())

    def test_recovery_failure_preserves_files(self):
        self.make_existing_helper()
        self.environment["BUSY_TEST_RECOVERY_FAIL"] = "1"
        result = self.run_script("helper")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.helper.exists())
        self.assertTrue((self.state / "config.json").exists())
        self.assertTrue((self.state / "journal.json").exists())
        self.assertNotIn("bootstrap", (self.root / "actions.log").read_text())

    def test_writable_old_helper_not_executed(self):
        self.make_existing_helper()
        self.helper.chmod(0o777)
        result = self.run_script("helper")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsafe permissions", result.stderr)
        self.assertFalse((self.root / "actions.log").exists())
        self.assertTrue((self.state / "journal.json").exists())

    def test_orphaned_journal_preserved(self):
        self.make_existing_helper()
        self.helper.unlink()
        result = self.run_script("helper")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.state / "journal.json").exists())


if __name__ == "__main__":
    unittest.main()
