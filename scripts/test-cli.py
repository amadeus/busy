#!/usr/bin/env python3
"""Run with build/busy; add --live for isolated menu bar app lifecycle smoke tests."""

import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest


CLI = str(pathlib.Path(sys.argv.pop(1) if len(sys.argv) > 1 else "build/busy").resolve())
LIVE = "--live" in sys.argv
if LIVE:
    sys.argv.remove("--live")


class CLITests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="busy-cli-", dir="/private/tmp")
        self.addCleanup(self.directory.cleanup)
        self.environment = dict(os.environ, BUSY_STATE_DIR=self.directory.name,
                                BUSY_APP_PATH="/nonexistent/Busy.app")

    def run_cli(self, *arguments):
        return subprocess.run([CLI, *arguments], env=self.environment, text=True,
                              capture_output=True, timeout=5)

    def exchange(self, arguments, response=None):
        response = response or {"status": {
            "active": True, "durationSeconds": 7200, "remainingSeconds": 5040,
            "batteryPercent": 67, "onBattery": True, "batteryCutoff": 20,
            "closedLidSupported": False,
        }}
        received = []
        errors = []
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(os.path.join(self.directory.name, "control.sock"))
            server.listen(1)
            server.settimeout(5)

            def serve():
                try:
                    connection, _ = server.accept()
                    with connection:
                        connection.settimeout(5)
                        stream = connection.makefile("rb")
                        received.append(json.loads(stream.readline(16384)))
                        connection.sendall(json.dumps(response).encode() + b"\n")
                except Exception as error:
                    errors.append(error)

            worker = threading.Thread(target=serve, daemon=True)
            worker.start()
            result = self.run_cli(*arguments)
            worker.join(timeout=6)
            self.assertFalse(worker.is_alive())
            self.assertEqual(errors, [])
        return result, received[0]

    def test_help_does_not_need_app(self):
        result = self.run_cli("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("--battery-cutoff", result.stdout)

    def test_stopped_status_and_stop_do_not_launch(self):
        for command in ("status", "stop"):
            with self.subTest(command=command):
                result = self.run_cli(command)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout.strip(), "Busy is not running.")

    def test_stopped_json_status(self):
        result = self.run_cli("status", "--json")
        self.assertEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)["status"]["active"])

    def test_invalid_input_is_rejected_before_launch(self):
        cases = [
            ("--duration", "0s"), ("--duration", "-1h"),
            ("--duration", "1e9h"), ("--duration", "NaNh"),
            ("--duration", "366d"), ("--duration", "0.1s"),
            ("--duration", "1h", "--duration", "2h"),
            ("--battery-cutoff", "0"), ("--battery-cutoff", "101"),
            ("--battery-cutoff", "20.5"), ("--battery-cutoff",),
            ("status", "--duration", "2h"), ("stop", "--battery-cutoff", "30"),
            ("--unknown",), ("unknown",),
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                result = self.run_cli(*arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("BUSY_APP_PATH", result.stderr)

    def test_plain_busy_preserves_session(self):
        result, request = self.exchange([])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(request["action"], "status")
        self.assertNotIn("durationSeconds", request)
        self.assertIn("2 hours", result.stdout)
        self.assertIn("1 hour 24 minutes remaining", result.stdout)
        self.assertIn("67%", result.stdout)

    def test_settings_are_one_update(self):
        result, request = self.exchange(["--duration", "1.5h", "--battery-cutoff", "25"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(request["action"], "update")
        self.assertEqual(request["durationSeconds"], 5400)
        self.assertEqual(request["batteryCutoff"], 25)
        self.assertFalse(request["clearDuration"])
        self.assertIn("id", request)

    def test_remove_duration(self):
        result, request = self.exchange(["--duration", "unlimited"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(request["clearDuration"])
        self.assertNotIn("durationSeconds", request)

    def test_server_error_reaches_caller(self):
        result, _ = self.exchange(["status"], {"error": "Battery is below its cutoff."})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Battery is below its cutoff.", result.stderr)


@unittest.skipUnless(LIVE, "Pass --live to exercise the built menu bar app.")
class LiveSessionTests(unittest.TestCase):
    def setUp(self):
        if os.path.exists("/Library/PrivilegedHelperTools/com.amadeus.Busy.helper"):
            self.skipTest("Live smoke tests require no installed helper, so they cannot change global sleep settings.")
        self.app = pathlib.Path(CLI).parents[2]
        self.assertEqual(self.app.suffix, ".app", "Use build/busy for --live tests.")
        self.directory = tempfile.TemporaryDirectory(prefix="busy-live-", dir="/private/tmp")
        self.environment = dict(os.environ, BUSY_STATE_DIR=self.directory.name,
                                BUSY_APP_PATH=str(self.app))
        pathlib.Path(self.directory.name, "settings.json").write_text('{"batteryCutoff":1}')
        self.addCleanup(self.cleanup)

    def cleanup(self):
        subprocess.run([CLI, "stop"], env=self.environment, capture_output=True, timeout=5)
        self.directory.cleanup()

    def call(self, *arguments):
        result = subprocess.run([CLI, *arguments, "--json"], env=self.environment,
                                capture_output=True, text=True, timeout=40)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)["status"]

    def wait_stopped(self):
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            if not self.call("status")["active"]:
                return
            time.sleep(0.1)
        self.fail("Busy did not exit after the duration expired.")

    def test_duration_preserved_expires_and_fresh_launch_is_unlimited(self):
        initial = self.call("--duration", "3s")
        self.assertTrue(initial["active"])
        self.assertEqual(initial["durationSeconds"], 3)
        time.sleep(0.3)
        repeated = self.call()
        self.assertLess(repeated["remainingSeconds"], initial["remainingSeconds"])
        self.wait_stopped()
        fresh = self.call()
        self.assertTrue(fresh["active"])
        self.assertNotIn("durationSeconds", fresh)
        self.assertEqual(fresh["batteryCutoff"], 1)

    def test_concurrent_cold_launches_apply_both_updates(self):
        commands = [[CLI, "--duration", "10s", "--json"],
                    [CLI, "--battery-cutoff", "2", "--json"]]
        children = [subprocess.Popen(command, env=self.environment, text=True,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    for command in commands]
        for child in children:
            stdout, stderr = child.communicate(timeout=40)
            self.assertEqual(child.returncode, 0, stderr)
            self.assertTrue(json.loads(stdout)["status"]["active"])
        status = self.call("status")
        self.assertEqual(status["durationSeconds"], 10)
        self.assertEqual(status["batteryCutoff"], 2)


if __name__ == "__main__":
    unittest.main()
