"""Exercise actual AppDelegate failure/release methods with inert UI and capture."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


STUBS = r'''
import Foundation

enum Failure: Error { case stopped }
enum TextInjector {
    struct CommandTarget {}
    enum SelectionError: Error { case unavailable }
}
struct UserFacingIssue { let summary: String; let details: String }
struct NativeAudioRecording {}
struct IncrementalCadence { let snapshotSeconds: TimeInterval = 0.4 }
final class DictationTrace {
    @TaskLocal static var current: DictationTrace?
    enum Event { case hotkeyReleased, incrementalSkipped }
    enum Status { case synthetic, busy }
    func record(_ event: Event, at: UInt64? = nil, status: Status?) {}
}
final class Overlay {
    var hides = 0
    func hide() { hides += 1 }
    func beginProcessing() {}
}
final class Key {
    var deactivations = 0
    let callbackUptimeNs: UInt64? = nil
    func deactivate() { deactivations += 1 }
}
final class Delivery {
    var cancelled: Set<Int> = []
    var incrementalCalls = 0
    func incrementalSnapshotRange(generation: Int) -> ((Int) -> Range<Int>)? { { 0..<$0 } }
    func processIncrementalSnapshot(generation: Int, samples: [Float], sampleOffset: Int) { incrementalCalls += 1 }
    func cancel(generation: Int) { cancelled.insert(generation) }
}
final class Recorder {
    struct Recording {
        let samples: [Float]
        let nativeAudio: NativeAudioRecording? = nil
        let startError: Error?
    }
    struct Snapshot { let samples: [Float]; let sampleOffset: Int }
    var captureActive = true
    var captureID = UUID()
    var snapshots: [(Snapshot) -> Void] = []
    func isCaptureActive(recordingID: UUID) -> Bool { captureActive && recordingID == captureID }
    func snapshot(range: @escaping (Int) -> Range<Int>, completion: @escaping (Snapshot) -> Void) { snapshots.append(completion) }
    var completions: [(Recording) -> Void] = []
    func stop(completion: @escaping (Recording) -> Void) { completions.append(completion) }
}
final class AppDelegate {
    enum State { case recording, failed(UserFacingIssue) }
    var recordingGeneration = 1
    var isRecording = true
    var recordingIsCommand = false
    var recordingCommandTarget: Result<TextInjector.CommandTarget, TextInjector.SelectionError>? = .failure(.unavailable)
    var activeDictationTrace: DictationTrace? = DictationTrace()
    var activeDictationGeneration: Int? = 10
    var hudDictationGeneration: (dictation: Int, hud: Int)? = (10, 1)
    var releasedDictation: (generation: Int, hudGeneration: Int)?
    var incrementalTimer: DispatchWorkItem? = DispatchWorkItem {}
    var pendingAudioHandoffs = 0
    var processCalls = 0
    var cues = 0
    var recoveries = 0
    var state = State.recording
    let overlay = Overlay()
    let cancelKey = Key()
    let hotkey = Key()
    let dictationDelivery = Delivery()
    let recorder = Recorder()
    func cancelActiveDictationSession() {
        incrementalTimer?.cancel()
        incrementalTimer = nil
        if let generation = activeDictationGeneration { dictationDelivery.cancel(generation: generation) }
        activeDictationGeneration = nil
    }
    func scheduleIncrementalTick(generation: Int, recordingID: UUID, cadence: IncrementalCadence, after: TimeInterval) {}
    func playCue(_ name: String) { cues += 1 }
    func scheduleFailureRecovery() { recoveries += 1 }
    func process(samples: [Float], releasedAt: Date, hudGeneration: Int,
                 asCommand: Bool, commandTarget: Result<TextInjector.CommandTarget, TextInjector.SelectionError>?,
                 dictationGeneration: Int?, nativeAudio: NativeAudioRecording?) {
        processCalls += 1
    }
'''

CASES = r'''
    func verify(_ scenario: String) {
        switch scenario {
        case "terminal-release":
            handleCaptureFailure(Failure.stopped, generation: 1, dictationGeneration: 10, summary: "stopped")
            handleCaptureFailure(Failure.stopped, generation: 1, dictationGeneration: 10, summary: "duplicate")
            hotkeyReleased()
            precondition(recordingGeneration == 2 && !isRecording && !recordingIsCommand)
            precondition(activeDictationTrace == nil && activeDictationGeneration == nil && recordingCommandTarget == nil)
            precondition(incrementalTimer == nil && hudDictationGeneration == nil && releasedDictation == nil)
            precondition(dictationDelivery.cancelled == [10])
            precondition(overlay.hides == 1 && cancelKey.deactivations == 1 && cues == 1 && recoveries == 1)
            precondition(recorder.completions.isEmpty && processCalls == 0)
        case "release-race":
            hotkeyReleased()
            precondition(pendingAudioHandoffs == 1)
            handleCaptureFailure(Failure.stopped, generation: 1, dictationGeneration: 10, summary: "stopped")
            recorder.completions[0](.init(samples: [], startError: Failure.stopped))
            precondition(pendingAudioHandoffs == 0 && processCalls == 0)
            precondition(dictationDelivery.cancelled == [10])
            precondition(releasedDictation == nil && overlay.hides == 1 && cues == 1 && recoveries == 1)
        case "stale-failure":
            recordingGeneration = 2
            activeDictationGeneration = 20
            hudDictationGeneration = (20, 2)
            handleCaptureFailure(Failure.stopped, generation: 1, dictationGeneration: 10, summary: "old failure")
            precondition(isRecording && recordingGeneration == 2 && activeDictationGeneration == 20 && recordingCommandTarget != nil)
            precondition(overlay.hides == 0 && cues == 0 && recoveries == 0)
            hotkeyReleased()
            recorder.completions[0](.init(samples: [0.1], startError: nil))
            precondition(processCalls == 1 && pendingAudioHandoffs == 0)
            precondition(dictationDelivery.cancelled.isEmpty)
        case "queued-snapshot":
            let id = recorder.captureID
            runIncrementalTick(generation: 10, recordingID: id, cadence: IncrementalCadence())
            precondition(recorder.snapshots.count == 1)
            // Recorder cleanup has started; the UI failure is still queued.
            recorder.captureActive = false
            precondition(isRecording && activeDictationGeneration == 10)
            recorder.snapshots[0](.init(samples: [0.1], sampleOffset: 100))
            precondition(dictationDelivery.incrementalCalls == 0)
        case "command-release":
            recordingIsCommand = true
            activeDictationGeneration = nil
            handleCaptureFailure(Failure.stopped, generation: 1, dictationGeneration: nil, summary: "stopped")
            commandKeyReleased()
            precondition(!recordingIsCommand && !isRecording && recorder.completions.isEmpty)
            precondition(processCalls == 0 && cues == 1 && recoveries == 1)
        default: fatalError("unknown case")
        }
        print("PASS \(scenario)")
    }
}
AppDelegate().verify(CommandLine.arguments[1])
'''


def method(source, name):
    """Copy a complete method at the repository's four-space class indentation."""
    start = source.index(f"    private func {name}(")
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"),
                     "Requires macOS and the Swift compiler")
class CaptureFailureBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="flo-r2-boundary.")
        cls.addClassCleanup(cls.temporary.cleanup)
        directory = Path(cls.temporary.name)
        root = Path(__file__).resolve().parents[1]
        source = (root / "Sources/LocalFlow/AppDelegate.swift").read_text()
        methods = "\n".join(method(source, name) for name in (
            "handleCaptureFailure", "hotkeyReleased", "dismissHud", "commandKeyReleased", "runIncrementalTick"))
        harness = directory / "main.swift"
        harness.write_text(STUBS + methods + CASES)
        cls.binary = directory / "capture-failure-boundary"
        compiled = subprocess.run(["swiftc", str(harness), "-o", str(cls.binary)],
                                  capture_output=True, text=True, timeout=60)
        if compiled.returncode:
            raise AssertionError(compiled.stderr)

    def run_case(self, scenario):
        result = subprocess.run([str(self.binary), scenario], capture_output=True,
                                text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f"PASS {scenario}")

    def test_terminal_failure_then_hotkey_release_has_one_ui_transition(self):
        self.run_case("terminal-release")

    def test_failure_racing_release_cancels_without_recognition(self):
        self.run_case("release-race")

    def test_old_failure_cannot_clear_or_cancel_new_recording(self):
        self.run_case("stale-failure")

    def test_queued_snapshot_cannot_start_recognition_before_ui_failure_arrives(self):
        self.run_case("queued-snapshot")

    def test_failed_command_hold_clears_command_release_flag(self):
        self.run_case("command-release")


if __name__ == "__main__":
    unittest.main()
