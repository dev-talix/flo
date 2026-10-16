"""Exercise installer guards without touching installed apps."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("app_lifecycle", ROOT / "scripts/app-lifecycle.py")
lifecycle = importlib.util.module_from_spec(SPEC)
exec(compile((ROOT / "scripts/app-lifecycle.py").read_text(), str(SPEC.origin), "exec"), lifecycle.__dict__)


class LocalAppIdleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = (ROOT / "scripts/local-app.sh").read_text()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.logs = Path(self.temporary.name)

    @staticmethod
    def app(name="Flo", pid=123, local=False):
        return {"name": name, "pid": pid, "bundleID": "app.talix.localflow" + (".local" if local else "")}

    @staticmethod
    def event(name, status=None):
        value = {"source": "dictation", "traceID": "fixture", "name": name}
        if status:
            value["status"] = status
        return "time timing " + json.dumps(value)

    def write_log(self, app, events, prefix=""):
        text = prefix + f"time === LocalFlow session start (pid {app['pid']}) ===\n" + "\n".join(events)
        (self.logs / lifecycle.LOG_NAMES[app["bundleID"]]).write_text(text)

    def check(self, events, prefix="", app=None):
        app = app or self.app()
        self.write_log(app, events, prefix)
        lifecycle.require_idle(app, self.logs)

    def test_recording_and_processing_prevent_restart(self):
        for events in ([self.event("hotkeyPressed")],
                       [self.event("hotkeyPressed"), self.event("hotkeyReleased"), self.event("resultReady", "success")]):
            with self.subTest(events=events), self.assertRaisesRegex(RuntimeError, "active dictation"):
                self.check(events)

    def test_paste_waits_for_clipboard_resolution(self):
        events = [self.event("hotkeyPressed"), self.event("pasteDispatched", "success")]
        with self.assertRaises(RuntimeError):
            self.check(events)
        self.check(events + [self.event("clipboardWindowResolved", "changedClipboard")])

    def test_empty_failed_and_silent_results_allow_restart(self):
        for status in ("empty", "failed", "insufficientVoice", "cancelled"):
            with self.subTest(status=status):
                self.check([self.event("hotkeyPressed"), self.event("resultReady", status)])
        self.check([self.event("hotkeyPressed"), self.event("pasteDispatched", "failed")])

    def test_cancelled_skipped_and_typed_results_allow_restart(self):
        for name in ("cancellationRequested", "injectionSkipped", "typingDispatched"):
            with self.subTest(name=name):
                self.check([self.event("hotkeyPressed"), self.event(name)])

    def test_stale_previous_launch_does_not_block_restart(self):
        old = "time === LocalFlow session start (pid 99) ===\n" + self.event("hotkeyPressed") + "\n"
        self.check([], prefix=old)

    def test_missing_current_pid_or_corrupt_log_refuses_quit(self):
        app = self.app()
        with self.assertRaises(RuntimeError):
            lifecycle.require_idle(app, self.logs)
        for content in ("session start (pid 999)", "session start (pid 123)\ntime timing {broken",
                        'session start (pid 123)\ntime timing {"source":"dictation","traceID":"fixture"}'):
            (self.logs / lifecycle.LOG_NAMES[app["bundleID"]]).write_text(content)
            with self.subTest(content=content), self.assertRaises(RuntimeError):
                lifecycle.require_idle(app, self.logs)

    def test_stopped_app_does_not_require_a_log(self):
        with patch.object(lifecycle, "running_apps", return_value=[]), patch.object(lifecycle, "request_quit") as quit_app:
            lifecycle.stop_apps(self.logs, timeout=0)
        quit_app.assert_not_called()

    def test_current_legacy_and_relative_launches_use_bundle_identity(self):
        for name in ("Flo", "Walkie", "LocalFlow", "Flo Local", "Walkie Local", "LocalFlow Local"):
            for argv in (f"/Applications/{name}.app/Contents/MacOS/LocalFlow", f"./{name}.app/Contents/MacOS/LocalFlow"):
                app = self.app(name, local=name.endswith(" Local"))
                # argv is deliberately absent from the native app identity.
                with self.subTest(name=name, argv=argv), self.assertRaisesRegex(RuntimeError, "active dictation"):
                    self.check([self.event("hotkeyPressed")], app=app)

    def test_native_lookup_and_quit_recheck_pid_and_bundle_id(self):
        app = self.app()
        process = SimpleNamespace(stdout=json.dumps([app]))
        with patch.object(lifecycle.subprocess, "run", return_value=process) as run:
            self.assertEqual(lifecycle.running_apps(), [app])
            lifecycle.request_quit(app)
        self.assertEqual(run.call_args_list[0].args[0][-1:], ["list"])
        self.assertEqual(run.call_args_list[1].args[0][-3:], ["quit", "123", app["bundleID"]])
        script = lifecycle.APPLICATION_SCRIPT
        self.assertIn("sharedWorkspace.runningApplications", script)
        self.assertIn("pid === Number(argv[1]) && bundleID === argv[2]", script)
        self.assertIn("app.terminate;", script)
        self.assertNotIn("forceTerminate", script)

    def test_native_script_filters_bundles_and_quits_only_matching_identity(self):
        fixture = r"""
        const values = [
            {pid: 123, bundleID: 'app.talix.localflow', name: 'Walkie'},
            {pid: 456, bundleID: 'app.talix.localflow.local', name: 'Flo Local'},
            {pid: 999, bundleID: 'example.unrelated', name: 'Flo'}
        ];
        const quits = [];
        const fixtures = values.map(function(value) {
            const app = {processIdentifier: value.pid, bundleIdentifier: $(value.bundleID),
                         localizedName: $(value.name)};
            Object.defineProperty(app, 'terminate', {get: function() {quits.push(value.pid); return true;}});
            return app;
        });
        const apps = {count: fixtures.length, objectAtIndex: function(i) {return fixtures[i];}};
        """
        source = lifecycle.APPLICATION_SCRIPT.replace(
            "const apps = $.NSWorkspace.sharedWorkspace.runningApplications;", fixture,
        ).replace("return JSON.stringify(result);", "return JSON.stringify({apps: result, quits: quits});")
        for pid, bundle_id, expected in ((123, "app.talix.localflow", [123]),
                                         (456, "app.talix.localflow.local", [456]),
                                         (123, "app.talix.localflow.local", []),
                                         (999, "example.unrelated", [])):
            with self.subTest(pid=pid, bundle_id=bundle_id):
                result = subprocess.run(
                    ["/usr/bin/osascript", "-l", "JavaScript", "-e", source, "quit", str(pid), bundle_id],
                    capture_output=True, text=True, check=True, timeout=10,
                )
                value = json.loads(result.stdout)
                self.assertEqual([app["pid"] for app in value["apps"]], [123, 456])
                self.assertEqual(value["quits"], expected)

    def test_all_channels_are_checked_before_any_quit(self):
        apps = [self.app(), self.app("Flo Local", 456, True)]
        self.write_log(apps[0], [])
        self.write_log(apps[1], [self.event("hotkeyPressed")])
        with patch.object(lifecycle, "running_apps", return_value=apps), patch.object(lifecycle, "request_quit") as quit_app:
            with self.assertRaisesRegex(RuntimeError, "Flo Local has an active dictation"):
                lifecycle.stop_apps(self.logs, timeout=0)
        quit_app.assert_not_called()

    def test_normal_quit_waits_for_both_channels_to_exit(self):
        apps = [self.app(), self.app("Flo Local", 456, True)]
        for app in apps:
            self.write_log(app, [])
        with patch.object(lifecycle, "running_apps", side_effect=[apps, [apps[1]], []]), \
             patch.object(lifecycle, "request_quit") as quit_app, patch.object(lifecycle.time, "sleep"):
            lifecycle.stop_apps(self.logs)
        self.assertEqual([call.args[0] for call in quit_app.call_args_list], apps)

    def test_quit_refusal_or_respawn_prevents_replacement(self):
        app = self.app()
        self.write_log(app, [])
        for remaining in ([app], [self.app(pid=999)]):
            with self.subTest(remaining=remaining), \
                 patch.object(lifecycle, "running_apps", side_effect=[[app], remaining]), \
                 patch.object(lifecycle, "request_quit") as quit_app:
                with self.assertRaisesRegex(RuntimeError, "still running"):
                    lifecycle.stop_apps(self.logs, timeout=0)
                quit_app.assert_called_once_with(app)

    def test_enumeration_failure_prevents_quit(self):
        with patch.object(lifecycle, "running_apps", side_effect=subprocess.CalledProcessError(1, "osascript")), \
             patch.object(lifecycle, "request_quit") as quit_app:
            with self.assertRaises(subprocess.CalledProcessError):
                lifecycle.stop_apps(self.logs, timeout=0)
        quit_app.assert_not_called()

    def test_channel_switch_prefers_current_name_and_accepts_legacy_installs(self):
        source = self.script.split('LOCAL_APP=', 1)[1].split('# Older installed builds', 1)[0]
        source = 'LOCAL_APP=' + source
        cases = [
            ("local", ["Flo Local", "Walkie Local", "LocalFlow Local"], "Flo Local"),
            ("local", ["Walkie Local", "LocalFlow Local"], "Walkie Local"),
            ("local", ["LocalFlow Local"], "LocalFlow Local"),
            ("production", ["Flo", "Walkie", "LocalFlow"], "Flo"),
            ("production", ["Walkie", "LocalFlow"], "Walkie"),
            ("production", ["LocalFlow"], "LocalFlow"),
        ]
        for action, installed, expected in cases:
            with self.subTest(action=action, installed=installed), tempfile.TemporaryDirectory() as directory:
                for name in installed:
                    (Path(directory) / f"{name}.app").mkdir()
                fixture = source.replace('/Applications/', directory + '/')
                result = subprocess.run(
                    ["bash", "-c", f"set -eu\nACTION={action}\n" + fixture + '\nprintf "%s" "$TARGET_APP"'],
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, str(Path(directory) / f"{expected}.app"))

    def test_both_installers_guard_replacement_without_forced_quit(self):
        for name, replacement in (("local-app.sh", 'STAGING="'), ("make-app.sh", "    rm -rf /Applications/Flo.app")):
            source = (ROOT / "scripts" / name).read_text()
            with self.subTest(name=name):
                self.assertLess(source.index("python3 scripts/app-lifecycle.py"), source.index(replacement))
                for forbidden in ("pkill", "pgrep", "launchctl bootout", "forceTerminate"):
                    self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
