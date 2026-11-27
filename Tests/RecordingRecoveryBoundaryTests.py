"""Compile actual AppDelegate abort, Escape, and handoff methods with inert UI and capture."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


STUBS = r'''
import Foundation

enum Failure: Error { case stopped }
enum TextInjector { struct CommandTarget {} }
struct UserFacingIssue: Equatable { let summary: String; let details: String }
struct NativeAudioRecording {}
struct TranscriptionLifetime {}
enum InjectionOutcome { case skip }
enum DiagLog { static func log(_ format: String, _ args: CVarArg...) {} }
final class DictationTrace {
    @TaskLocal static var current: DictationTrace?
    enum Event { case hotkeyReleased }
    enum Status { case synthetic }
    func record(_ event: Event, at: UInt64? = nil, status: Status?) {}
}
final class Overlay {
    var hides = 0
    func hide() { hides += 1 }
    func beginProcessing() {}
}
final class Key {
    var deactivations = 0
    var cancelledHolds = 0
    let callbackUptimeNs: UInt64? = nil
    func deactivate() { deactivations += 1 }
    func cancelHold() { cancelledHolds += 1 }
}
final class Delivery {
    var cancelled: [Int] = []
    var interruptions: [Bool] = []
    var retained: [[Float]] = []
    @discardableResult
    func retainForRetry(_ samples: [Float]) -> Bool { retained.append(samples); return true }
    func cancel(generation: Int, interruptInference: Bool = true) {
        cancelled.append(generation)
        interruptions.append(interruptInference)
    }
}
final class Recorder {
    struct Recording {
        let samples: [Float]
        let nativeAudio: NativeAudioRecording? = nil
        let startError: Error?
    }
    var completions: [(Recording) -> Void] = []
    var warmReleases = 0
    func stop(completion: @escaping (Recording) -> Void) { completions.append(completion) }
    func releaseWarmSession() { warmReleases += 1 }
}
final class AppDelegate {
    enum State: Equatable {
        case idle, recording, processing, failed(UserFacingIssue)
    }
    static let audioHandoffTimeout: TimeInterval = 0.05
    var recordingGeneration = 1
    var isRecording = true
    var recordingIsCommand = false
    var recordingCommandTarget: TextInjector.CommandTarget? = nil
    var activeDictationTrace: DictationTrace? = DictationTrace()
    var activeDictationGeneration: Int? = 10
    var hudDictationGeneration: (dictation: Int, hud: Int)? = (10, 1)
    var releasedDictation: (generation: Int, hudGeneration: Int)?
    var incrementalTimer: DispatchWorkItem? = DispatchWorkItem {}
    var audioHandoffs: Set<Int> = []
    var pendingAudioHandoffs: Int { audioHandoffs.count }
    var expiredAudioHandoffs: Set<Int> = []
    var processCalls = 0
    var cues: [String] = []
    var recoveries = 0
    var processingCount = 0
    var state = State.recording
    var restingState: State { processingCount > 0 ? .processing : .idle }
    var commandHudGenerations: [Int: Int] = [:]
    var commandSpeechLifetimes: [Int: TranscriptionLifetime] = [:]
    var commandTasks: [Int: Task<Void, Never>] = [:]
    let overlay = Overlay()
    let cancelKey = Key()
    let hotkey = Key()
    let commandHotkey = Key()
    let dictationDelivery = Delivery()
    let recorder = Recorder()
    func completeCommand(_ sequence: Int, with outcome: InjectionOutcome) {}
    func playCue(_ name: String) { cues.append(name) }
    func scheduleFailureRecovery() { recoveries += 1 }
    func process(samples: [Float], releasedAt: Date, hudGeneration: Int,
                 asCommand: Bool, commandTarget: TextInjector.CommandTarget?,
                 dictationGeneration: Int?, nativeAudio: NativeAudioRecording?) {
        processCalls += 1
    }
'''

CASES = r'''
    func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func verify(_ scenario: String) {
        switch scenario {
        case "sleep-keeps-inference":
            abortRecording(reason: "sleep")
            precondition(!isRecording && recorder.warmReleases == 1)
            precondition(dictationDelivery.cancelled == [10])
            precondition(dictationDelivery.interruptions == [false],
                         "Sleep must give running inference Transcriber's grace, like Escape")
        case "escape-after-release":
            hotkeyReleased()
            precondition(state == .recording, "fixture: release leaves the state for the handoff")
            cancelFromKeyboard()
            precondition(dictationDelivery.cancelled == [10])
            precondition(state == .idle, "Escape after release must not leave the menu on Recording")
        case "handoff-deadline":
            hotkeyReleased()
            precondition(pendingAudioHandoffs == 1)
            spin(Self.audioHandoffTimeout * 6)
            precondition(pendingAudioHandoffs == 0, "A stuck handoff must not block Quit forever")
            precondition(dictationDelivery.cancelled == [10] && dictationDelivery.interruptions == [false])
            precondition(releasedDictation == nil && overlay.hides == 1)
            guard case .failed = state else { preconditionFailure("A stuck handoff must report a failure") }
            // The late completion must not process audio or decrement again.
            recorder.completions[0](.init(samples: [0.1], startError: nil))
            precondition(processCalls == 0 && pendingAudioHandoffs == 0)
            precondition(dictationDelivery.retained == [[0.1]], "Late audio must stay available for retry")
        case "escape-then-deadline":
            hotkeyReleased()
            cancelFromKeyboard()
            spin(Self.audioHandoffTimeout * 6)
            precondition(state == .idle && cues.isEmpty, "An explicit cancel is not a microphone failure")
            recorder.completions[0](.init(samples: [0.1], startError: nil))
            precondition(dictationDelivery.retained.isEmpty && processCalls == 0,
                         "Audio from a cancelled hold must not reach Retry Dictation")
            precondition(pendingAudioHandoffs == 0)
        case "older-timeout-newer-hold":
            hotkeyReleased()
            // A second hold starts and is released while the first handoff is stuck.
            recordingGeneration = 2
            isRecording = true
            activeDictationGeneration = 20
            hotkeyReleased()
            processingCount = 1
            state = .processing
            recorder.completions[1](.init(samples: [0.2], startError: nil))
            spin(Self.audioHandoffTimeout * 6)
            precondition(dictationDelivery.cancelled == [10], "The expired hold is still cancelled")
            precondition(state == .processing && cues.isEmpty,
                         "An older hold's timeout must not overwrite the newer hold's status")
            precondition(processCalls == 1 && pendingAudioHandoffs == 0)
        case "escape-then-runtime-failure":
            hotkeyReleased()
            cancelFromKeyboard()
            // The recorder's failure callback was already queued for this hold.
            handleCaptureFailure(Failure.stopped, generation: 1, dictationGeneration: 10,
                                 summary: "Microphone stopped", capturedSamples: [0.1, 0.2])
            precondition(dictationDelivery.retained.isEmpty && cues.isEmpty && state == .idle,
                         "A hold the user cancelled must not resurface through a queued failure")
        case "command-timeout":
            recordingIsCommand = true
            activeDictationGeneration = nil
            hotkeyReleased()
            spin(Self.audioHandoffTimeout * 6)
            guard case .failed(let issue) = state else { preconditionFailure("A stuck command handoff reports a failure") }
            precondition(!issue.details.contains("Retry Dictation"),
                         "Voice edits never enter Retry Dictation, so the message must not promise it")
        case "handoff-in-time":
            hotkeyReleased()
            recorder.completions[0](.init(samples: [0.1], startError: nil))
            precondition(processCalls == 1 && pendingAudioHandoffs == 0)
            spin(Self.audioHandoffTimeout * 6)
            precondition(dictationDelivery.cancelled.isEmpty && overlay.hides == 0 && recoveries == 0)
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
class RecordingRecoveryBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="flo-recording-recovery.")
        cls.addClassCleanup(cls.temporary.cleanup)
        directory = Path(cls.temporary.name)
        root = Path(__file__).resolve().parents[1]
        source = (root / "Sources/LocalFlow/AppDelegate.swift").read_text()
        methods = "\n".join(method(source, name) for name in (
            "abortRecording", "discardActiveRecording", "cancelActiveDictationSession",
            "hotkeyReleased", "audioHandoffTimedOut", "dismissHud", "cancelFromKeyboard",
            "handleCaptureFailure"))
        harness = directory / "main.swift"
        harness.write_text(STUBS + methods + CASES)
        cls.binary = directory / "recording-recovery-boundary"
        compiled = subprocess.run(["swiftc", str(harness), "-o", str(cls.binary)],
                                  capture_output=True, text=True, timeout=120)
        if compiled.returncode:
            raise AssertionError(compiled.stderr)

    def run_case(self, scenario):
        result = subprocess.run([str(self.binary), scenario], capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f"PASS {scenario}")

    def test_sleep_mid_hold_keeps_running_inference_warm(self):
        self.run_case("sleep-keeps-inference")

    def test_escape_after_release_returns_menu_to_resting_state(self):
        self.run_case("escape-after-release")

    def test_stuck_audio_handoff_times_out_and_unblocks_quit(self):
        self.run_case("handoff-deadline")

    def test_escape_before_handoff_discards_late_audio_without_failure(self):
        self.run_case("escape-then-deadline")

    def test_older_handoff_timeout_leaves_newer_hold_status_alone(self):
        self.run_case("older-timeout-newer-hold")

    def test_queued_capture_failure_after_escape_is_ignored(self):
        self.run_case("escape-then-runtime-failure")

    def test_command_timeout_does_not_promise_dictation_retry(self):
        self.run_case("command-timeout")

    def test_timely_audio_handoff_is_not_cancelled_by_deadline(self):
        self.run_case("handoff-in-time")


if __name__ == "__main__":
    unittest.main()
