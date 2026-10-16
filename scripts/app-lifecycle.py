"""Check dictation state and request normal Quit before replacing an app."""
import json
from pathlib import Path
import subprocess
import sys
import time


LOG_NAMES = {
    "app.talix.localflow": "LocalFlow-diag.log",
    "app.talix.localflow.local": "LocalFlow-Local-diag.log",
}

# NSWorkspace identifies bundles even when argv uses a relative executable path.
# terminate requests normal Quit; it does not bypass applicationShouldTerminate.
APPLICATION_SCRIPT = r"""
ObjC.import('AppKit');
function run(argv) {
    const apps = $.NSWorkspace.sharedWorkspace.runningApplications;
    const result = [];
    for (let i = 0; i < apps.count; i++) {
        const app = apps.objectAtIndex(i);
        const bundleID = ObjC.unwrap(app.bundleIdentifier);
        if (bundleID !== 'app.talix.localflow' &&
            bundleID !== 'app.talix.localflow.local') continue;
        const pid = Number(app.processIdentifier);
        if (argv[0] === 'quit' && pid === Number(argv[1]) && bundleID === argv[2]) {
            app.terminate;
        }
        result.push({pid: pid, bundleID: bundleID, name: ObjC.unwrap(app.localizedName)});
    }
    return JSON.stringify(result);
}
"""


def application_command(*arguments):
    result = subprocess.run(
        ["/usr/bin/osascript", "-l", "JavaScript", "-e", APPLICATION_SCRIPT, *arguments],
        capture_output=True, text=True, timeout=10, check=True,
    )
    return json.loads(result.stdout)


def running_apps():
    return application_command("list")


def request_quit(app):
    # Recheck both PID and bundle ID inside the same native enumeration.
    application_command("quit", str(app["pid"]), app["bundleID"])


def require_idle(app, logs_directory):
    name = app["name"] or app["bundleID"]
    path = logs_directory / LOG_NAMES[app["bundleID"]]
    try:
        lines = path.read_text().splitlines()
    except OSError as error:
        raise RuntimeError(f"cannot verify {name} is idle; quit it before installing") from error
    marker = f"session start (pid {app['pid']})"
    starts = [i for i, line in enumerate(lines) if marker in line]
    if not starts:
        raise RuntimeError(f"cannot verify {name} is idle; quit it before installing")
    traces = {}
    for line in lines[starts[-1]:]:
        if " timing " not in line:
            continue
        try:
            event = json.loads(line.split(" timing ", 1)[1])
            if event.get("source") == "dictation":
                if not isinstance(event.get("traceID"), str) or not isinstance(event.get("name"), str):
                    raise ValueError("invalid dictation event")
                traces.setdefault(event["traceID"], []).append(event)
        except (ValueError, KeyError, AttributeError, TypeError) as error:
            raise RuntimeError(f"cannot verify {name} is idle; quit it before installing") from error
    for events in traces.values():
        names = {event["name"] for event in events}
        resolved = bool(names & {
            "cancellationRequested", "injectionSkipped", "clipboardWindowResolved", "typingDispatched",
        })
        resolved |= any(event["name"] == "resultReady" and event.get("status") in (
            "empty", "failed", "insufficientVoice", "cancelled",
        ) for event in events)
        resolved |= any(event["name"] == "pasteDispatched" and event.get("status") == "failed"
                        for event in events)
        if "hotkeyPressed" in names and not resolved:
            raise RuntimeError(f"{name} has an active dictation; finish it and retry installing")


def stop_apps(logs_directory, timeout=5):
    apps = running_apps()
    # Check every copy before sending any Quit request.
    for app in apps:
        require_idle(app, logs_directory)
    for app in apps:
        request_quit(app)
    deadline = time.monotonic() + timeout
    while running_apps():
        if time.monotonic() >= deadline:
            raise RuntimeError("Flo is still running; finish dictating and quit it before installing")
        time.sleep(min(0.2, max(0, deadline - time.monotonic())))


if __name__ == "__main__":
    try:
        stop_apps(Path.home() / "Library/Logs")
    except (RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
