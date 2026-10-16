"""Compile actual command caller methods with inert UI, speech, and text models.

The real lifetime and gate connect caller invalidation to queued removal. Real
Transcriber grace expiry and warm reuse are covered by DictationSessionStallTests.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


STUBS = r'''
import Foundation

final class WeakLifetime {
    weak var value: TranscriptionLifetime?
    init(_ value: TranscriptionLifetime?) { self.value = value }
}
@MainActor final class Transcriber {
    enum TranscriberError: Error { case noSpeech }
    let gate = TranscriptionGate()
    var received: [WeakLifetime] = []
    var pending: [Int: CheckedContinuation<String, Error>] = [:]
    var started = 0
    var completed = 0
    var abandonments = 0
    var interruptions = 0
    func transcribe(samples: [Float], lowEnergy: Bool,
                    lifetime: TranscriptionLifetime? = nil) async throws -> String {
        received.append(WeakLifetime(lifetime))
        try await gate.acquire(lifetime: lifetime)
        let id = started
        started += 1
        lifetime?.observeInvalidation {
            Task { @MainActor in self.abandonments += 1 }
        }
        do {
            // Deliberately return late text even after invalidation or task
            // cancellation, so the actual caller must reject stale results.
            let result: String = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { pending[id] = $0 }
            } onCancel: {
                Task { @MainActor in self.interruptions += 1 }
            }
            lifetime?.stopObserving()
            await gate.release()
            completed += 1
            return result
        } catch {
            lifetime?.stopObserving()
            await gate.release()
            completed += 1
            throw error
        }
    }
    func finish(_ id: Int = 0, text: String = "rewrite these words") {
        pending.removeValue(forKey: id)!.resume(returning: text)
    }
    func fail(_ error: Error) { pending.removeValue(forKey: 0)!.resume(throwing: error) }
}
enum InjectionCoordinator { enum Outcome { case skip, inject(String) } }
@MainActor final class Delivery {
    var next = 0
    var pending: Set<Int> = []
    var delivered: [String] = []
    var skipped: [Int] = []
    func beginCommand() -> Int { defer { next += 1 }; pending.insert(next); return next }
    func isCommandPending(_ seq: Int) -> Bool { pending.contains(seq) }
    func completeCommand(_ seq: Int, with outcome: InjectionCoordinator.Outcome) {
        guard pending.remove(seq) != nil else { return }
        switch outcome {
        case .skip: skipped.append(seq)
        case .inject(let text): delivered.append(text)
        }
    }
    func cancel(generation: Int, interruptInference: Bool) {}
    func release(generation: Int, samples: [Float], nativeAudio: NativeAudioRecording?,
                 releasedAt: Date, hudGeneration: Int?) {}
}
@MainActor enum TextInjector {
    static var copies = 0
    static var delayed = false
    static var callback: ((Result<String?, Error>) -> Void)?
    static func copySelection(_ completion: @escaping (Result<String?, Error>) -> Void) {
        copies += 1
        if delayed { callback = completion } else { completion(.success("selected text")) }
    }
}
@MainActor enum CommandMode {
    static var calls = 0
    static var cancellations = 0
    static var continuation: CheckedContinuation<String, Never>?
    static func run(instruction: String, selection: String?) async throws -> String {
        calls += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor in cancellations += 1 }
        }
    }
    static func finish() { continuation!.resume(returning: "edited text"); continuation = nil }
}
struct NativeAudioRecording {}
struct DictationAudioPreparation {
    let samples: [Float]
    var isAdmitted: Bool { !samples.isEmpty }
    var lowEnergy: Bool { false }
}
enum TranscriptCorrections {
    static func apply(_ text: String, corrections: [String: String]) -> String { text }
}
enum DiagLog { static func log(_ format: String, _ values: CVarArg...) {} }
struct UserFacingIssue { let summary: String; let details: String }
final class DictationTrace { @TaskLocal static var current: DictationTrace? }
final class Overlay { var hides = 0; func hide() { hides += 1 } }
final class Key { func cancelHold() {}; func deactivate() {} }
final class Recorder { var stops = 0; func stop(_ callback: (Int) -> Void) { stops += 1 } }

@MainActor final class AppDelegate {
    enum State { case idle, failed(UserFacingIssue) }
    var state = State.idle
    var restingState = State.idle
    var isRecording = false
    var recordingIsCommand = false
    var recordingGeneration = 1
    var releasedDictation: (generation: Int, hudGeneration: Int)?
    var activeDictationTrace: DictationTrace?
    let recorder = Recorder()
    let hotkey = Key()
    let commandHotkey = Key()
    let cancelKey = Key()
    let overlay = Overlay()
    let transcriber = Transcriber()
    let dictationDelivery = Delivery()
    var commandHudGenerations: [Int: Int] = [:]
    var hudDictationGeneration: (dictation: Int, hud: Int)?
    var heardNothing = 0
    var recoveries = 0
    func captureDictationContext() -> (corrections: [String: String], unused: Bool) { ([:], false) }
    func cancelActiveDictationSession(interruptInference: Bool) {}
    func reportHeardNothing() { heardNothing += 1 }
    func playCue(_ name: String) {}
    func scheduleFailureRecovery() { recoveries += 1 }
    func mirrorOllamaReachability() {}
'''

CASES = r'''
    func start() { process(samples: [0.1], releasedAt: Date(), hudGeneration: 1, asCommand: true) }
    func verify(_ scenario: String) async {
        defer { precondition(speechOwnerCount == 0, "command must release its speech ownership") }
        if scenario == "discard-held" {
            isRecording = true
            recordingIsCommand = true
            cancelFromKeyboard()
            precondition(!isRecording && !recordingIsCommand && recorder.stops == 1)
            precondition(commandTasks.isEmpty && dictationDelivery.pending.isEmpty)
            precondition(transcriber.received.isEmpty)
            return
        }
        if scenario == "queued-escape" { try! await transcriber.gate.acquire() }
        start()
        if scenario == "escape-before-start" {
            let task = commandTasks[0]!
            cancelFromKeyboard()
            await task.value
            precondition(!task.isCancelled && transcriber.started == 0)
            precondition(dictationDelivery.pending.isEmpty && commandTasks.isEmpty)
            precondition(TextInjector.copies == 0 && CommandMode.calls == 0)
            return
        }
        await until { !self.transcriber.received.isEmpty }
        if scenario == "queued-escape" {
            await until { await self.transcriber.gate.waitingCount == 1 }
            let task = commandTasks[0]!
            let lifetime = transcriber.received[0].value
            precondition(lifetime != nil)
            cancelFromKeyboard()
            precondition(lifetime?.isInvalidated == true)
            await until { await self.transcriber.gate.waitingCount == 0 }
            await task.value
            precondition(!task.isCancelled && transcriber.started == 0)
            precondition(transcriber.abandonments == 0 && transcriber.interruptions == 0)
            precondition(dictationDelivery.pending.isEmpty && commandTasks.isEmpty)
            precondition(TextInjector.copies == 0 && CommandMode.calls == 0)
            await transcriber.gate.release()
            return
        }
        await until { self.transcriber.started == 1 }
        let task = commandTasks[0]!
        let weakLifetime = transcriber.received[0]
        precondition(weakLifetime.value != nil, "actual command caller must pass a speech lifetime")
        precondition(weakLifetime.value?.isInvalidated == false)
        switch scenario {
        case "escape-suspended", "skip-suspended":
            if scenario == "escape-suspended" { cancelFromKeyboard() }
            else { completeCommand(0, with: .skip) }
            precondition(commandTasks.isEmpty && commandHudGenerations.isEmpty)
            // No caller task handle remains. Suspended speech still owns its
            // invalidated lifetime and has notified the abandonment observer.
            precondition(weakLifetime.value?.isInvalidated == true && !task.isCancelled)
            await until { self.transcriber.abandonments == 1 }
            precondition(transcriber.interruptions == 0 && transcriber.pending.count == 1)
            transcriber.finish()
            await task.value
            precondition(TextInjector.copies == 0 && CommandMode.calls == 0)
            precondition(dictationDelivery.delivered.isEmpty && recoveries == 0)
        case "timeout-speech":
            // DictationDelivery removes pending identity before its timeout callback.
            dictationDelivery.pending.remove(0)
            cancelCommand(0)
            precondition(weakLifetime.value?.isInvalidated == true && task.isCancelled)
            await until { self.transcriber.interruptions == 1 }
            transcriber.finish()
            await task.value
            precondition(commandTasks.isEmpty && commandHudGenerations.isEmpty && recoveries == 1)
            precondition(TextInjector.copies == 0 && CommandMode.calls == 0)
        case "normal-warm", "escape-llm", "timeout-llm", "escape-selection":
            let lifetime = weakLifetime.value!
            TextInjector.delayed = scenario == "escape-selection"
            transcriber.finish()
            await task.value
            precondition(lifetime.isInvalidated && transcriber.abandonments == 0)
            precondition(transcriber.interruptions == 0 && TextInjector.copies == 1)
            if scenario == "escape-selection" {
                cancelFromKeyboard()
                TextInjector.callback!(.success("late selection"))
                precondition(CommandMode.calls == 0 && dictationDelivery.delivered.isEmpty)
            } else {
                await until { CommandMode.calls == 1 }
                let llmTask = commandTasks[0]!
                if scenario == "normal-warm" {
                    CommandMode.finish()
                    await llmTask.value
                    precondition(dictationDelivery.delivered == ["edited text"])
                    precondition(!llmTask.isCancelled && commandTasks.isEmpty)
                    // Another command reaches the same gate without any speech interruption.
                    start()
                    await until { self.transcriber.started == 2 }
                    let next = commandTasks[1]!
                    transcriber.finish(1, text: "")
                    await next.value
                    precondition(transcriber.abandonments == 0 && transcriber.interruptions == 0)
                } else {
                    if scenario == "escape-llm" { cancelFromKeyboard() }
                    else { dictationDelivery.pending.remove(0); cancelCommand(0) }
                    await until { CommandMode.cancellations == 1 }
                    precondition(llmTask.isCancelled && transcriber.abandonments == 0)
                    CommandMode.finish()
                    await llmTask.value
                    precondition(dictationDelivery.delivered.isEmpty && transcriber.interruptions == 0)
                }
            }
        case "empty", "no-speech", "speech-error":
            let lifetime = weakLifetime.value!
            if scenario == "empty" { transcriber.finish(text: "") }
            else if scenario == "no-speech" { transcriber.fail(Transcriber.TranscriberError.noSpeech) }
            else { transcriber.fail(NSError(domain: "inert", code: 1)) }
            await task.value
            precondition(lifetime.isInvalidated && transcriber.abandonments == 0)
            precondition(commandTasks.isEmpty && commandHudGenerations.isEmpty)
            precondition(dictationDelivery.pending.isEmpty && TextInjector.copies == 0)
            precondition(heardNothing == (scenario == "speech-error" ? 0 : 1))
            precondition(recoveries == (scenario == "speech-error" ? 1 : 0))
        default: fatalError("unknown scenario")
        }
    }
}
@MainActor func until(_ condition: () async -> Bool) async {
    for _ in 0..<2000 {
        if await condition() { return }
        try! await Task.sleep(for: .milliseconds(1))
    }
    fatalError("condition timed out")
}
@main struct Runner {
    @MainActor static func main() async {
        let scenario = CommandLine.arguments[1]
        await AppDelegate().verify(scenario)
        print("PASS \(scenario)")
    }
}
'''


def method(source, name):
    start = source.index(f"    private func {name}(")
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"),
                     "Requires macOS and the Swift compiler")
class CommandAbandonmentBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="flo-r1-command-boundary.")
        cls.addClassCleanup(cls.temporary.cleanup)
        directory = Path(cls.temporary.name)
        root = Path(__file__).resolve().parents[1]
        source = (root / "Sources/LocalFlow/AppDelegate.swift").read_text()
        methods = "\n".join(method(source, name) for name in (
            "process", "runCommand", "cancelFromKeyboard", "completeCommand",
            "cancelCommand", "discardActiveRecording", "dismissHud"))
        # Use actual stored declarations as well as methods, including on the
        # unfixed parent for a behavioral red run with its speech-phase set.
        properties = "\n".join(line for line in source.splitlines() if any(
            line.startswith(f"    private var {name}:") for name in (
                "commandTasks", "transcribingCommands", "commandSpeechLifetimes")))
        owners = "commandSpeechLifetimes" if "commandSpeechLifetimes:" in properties else "transcribingCommands"
        properties += f"\n    var speechOwnerCount: Int {{ {owners}.count }}\n"
        speech = (root / "Sources/LocalFlow/SpeechEngine.swift").read_text()
        lifetime = speech[speech.index("enum TranscriptionPurpose:"):speech.index("/// One timed span")]
        transcriber = (root / "Sources/LocalFlow/Transcriber.swift").read_text()
        gate = transcriber[transcriber.index("actor TranscriptionGate {"):transcriber.index("/// Owns the loaded")]
        harness = directory / "main.swift"
        harness.write_text("import Foundation\n" + lifetime + gate + STUBS + properties + "\n" + methods + CASES)
        cls.binary = directory / "command-abandonment-boundary"
        compiled = subprocess.run(["swiftc", "-parse-as-library", str(harness), "-o", str(cls.binary)],
                                  capture_output=True, text=True, timeout=60)
        if compiled.returncode:
            raise AssertionError(compiled.stderr)

    def run_case(self, scenario):
        result = subprocess.run([str(self.binary), scenario], capture_output=True,
                                text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f"PASS {scenario}")
        print(result.stdout.strip(), flush=True)

    def test_escape_retains_invalidated_suspended_speech_without_task_cancellation(self):
        self.run_case("escape-suspended")

    def test_skip_invalidates_suspended_speech_and_drops_late_completion(self):
        self.run_case("skip-suspended")

    def test_escape_removes_command_from_real_gate_without_touching_holder(self):
        self.run_case("queued-escape")

    def test_escape_before_task_starts_prevents_speech_inference(self):
        self.run_case("escape-before-start")

    def test_timeout_invalidates_speech_and_explicitly_cancels_task(self):
        self.run_case("timeout-speech")

    def test_normal_completion_detaches_observer_and_reuses_gate(self):
        self.run_case("normal-warm")

    def test_escape_cancels_only_text_model_and_rejects_late_edit(self):
        self.run_case("escape-llm")

    def test_timeout_cancels_only_text_model_and_rejects_late_edit(self):
        self.run_case("timeout-llm")

    def test_escape_rejects_late_selection_without_running_text_model(self):
        self.run_case("escape-selection")

    def test_empty_completion_clears_lifetime_without_abandonment(self):
        self.run_case("empty")

    def test_no_speech_clears_lifetime_without_abandonment(self):
        self.run_case("no-speech")

    def test_speech_failure_clears_lifetime_without_abandonment(self):
        self.run_case("speech-error")

    def test_discard_held_command_starts_no_speech_request(self):
        self.run_case("discard-held")


if __name__ == "__main__":
    unittest.main()
