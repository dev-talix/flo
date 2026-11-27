"""Compile actual AppDelegate model-retry and shortcut-recovery methods with inert dependencies."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


STUBS = r'''
import Foundation

enum DiagLog { static func log(_ format: String, _ args: CVarArg...) {} }
enum Settings {
    static let whisperModel = "test"
    static let saveDiagnosticRecordings = false
}
struct DictationTrace {}
struct UserFacingIssue: Equatable {
    enum Action: Equatable { case openAccessibilitySettings }
    let summary: String
    let details: String
    var action: Action? = nil
}
final class Transcriber {
    enum TranscriberError: Error { case notLoaded, recoveryBusy }
    var isLoaded: Bool { get async { false } }
    var loads = 0
    func load(model: String) async throws { loads += 1; throw TranscriberError.recoveryBusy }
}
enum StartupModelSequence {
    static func run(loadWhisper: () async throws -> Void, prewarmCleanup: () async -> Void) async throws {
        try await loadWhisper()
    }
}
final class Delivery {
    struct Configuration { let context: Int; let trace: DictationTrace?; let diagnostics: Int? }
    var drains = 0
    func retryFailedDictations(configuration: () -> Configuration) { drains += 1 }
}
final class SettingsModel { var lastIssue: UserFacingIssue? }
final class Key { struct Label { let label = "Right Option" }; let key = Label() }
final class AppDelegate {
    enum State: Equatable { case idle, recording, processing, loadingModel, failed(UserFacingIssue) }
    let transcriber = Transcriber()
    let dictationDelivery = Delivery()
    let hotkey = Key()
    var settingsModel: SettingsModel? = SettingsModel()
    var retryingDictations = false
    var modelPreparationStartedAt: UInt64?
    var modelLoadGeneration = 1
    var modelRetryDelay: TimeInterval = 0.02
    var modelLoaded = false
    var hotkeyActive = false
    var isRecording = false
    var loadModelCalls = 0
    var state = State.idle {
        didSet { if case .failed(let issue) = state { lastError = issue } }
    }
    var lastError: UserFacingIssue? {
        didSet { settingsModel?.lastIssue = lastError }
    }
    var restingState: State { modelLoaded ? .idle : .loadingModel }
    func loadModel() { loadModelCalls += 1 }
    func beginModelPreparation() { modelPreparationStartedAt = 1 }
    func endModelPreparation() { modelPreparationStartedAt = nil }
    func recomputeReadyState() {
        guard hotkeyActive, modelLoaded else { return }
        if case .failed = state { state = isRecording ? .recording : restingState }
    }
    func captureDictationContext() -> Int { 0 }
    func diagnosticRecording(context: Int, trace: DictationTrace?) -> Int? { nil }
'''

CASES = r'''
    func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func verify(_ scenario: String) {
        switch scenario {
        case "manual-retry-keeps-auto-reload":
            // A failed automatic load is waiting out its backoff.
            scheduleModelRetry(generation: modelLoadGeneration)
            retryFailedDictation()
            spin(0.5)
            precondition(transcriber.loads == 1 && dictationDelivery.drains == 0)
            precondition(loadModelCalls >= 1,
                         "A failed manual reload must not cancel automatic recovery")
        case "shortcut-recovery-keeps-other-issues":
            state = .failed(UserFacingIssue(summary: "Dictation shortcut unavailable", details: "",
                                            action: .openAccessibilitySettings))
            let other = UserFacingIssue(summary: "Couldn't delete history", details: "")
            settingsModel?.lastIssue = other
            hotkeyTapVerified()
            precondition(settingsModel?.lastIssue == other, "Tap recovery must not erase a newer Settings issue")
            precondition(lastError == nil)
            precondition(state == .loadingModel, "The menu must leave the shortcut failure while the model loads")
        case "shortcut-recovery-clears-banner":
            modelLoaded = true
            state = .failed(UserFacingIssue(summary: "Dictation shortcut unavailable", details: "",
                                            action: .openAccessibilitySettings))
            hotkeyTapVerified()
            precondition(settingsModel?.lastIssue == nil && lastError == nil && state == .idle)
        default: fatalError("unknown case")
        }
        print("PASS \(scenario)")
    }
}
AppDelegate().verify(CommandLine.arguments[1])
'''


def method(source, name):
    """Copy a complete method at the repository's four-space class indentation."""
    start = source.index(f"    private func {name}(") if f"    private func {name}(" in source \
        else source.index(f"    @objc private func {name}(")
    end = source.index("\n    }\n", start) + len("\n    }")
    return source[start:end].replace("@objc ", "")


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"),
                     "Requires macOS and the Swift compiler")
class ModelRecoveryBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="flo-model-recovery.")
        cls.addClassCleanup(cls.temporary.cleanup)
        directory = Path(cls.temporary.name)
        root = Path(__file__).resolve().parents[1]
        source = (root / "Sources/LocalFlow/AppDelegate.swift").read_text()
        methods = "\n".join(method(source, name) for name in (
            "retryFailedDictation", "scheduleModelRetry", "hotkeyTapVerified"))
        harness = directory / "main.swift"
        harness.write_text(STUBS + methods + CASES)
        cls.binary = directory / "model-recovery-boundary"
        compiled = subprocess.run(["swiftc", str(harness), "-o", str(cls.binary)],
                                  capture_output=True, text=True, timeout=120)
        if compiled.returncode:
            raise AssertionError(compiled.stderr)

    def run_case(self, scenario):
        result = subprocess.run([str(self.binary), scenario], capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f"PASS {scenario}")

    def test_failed_manual_retry_keeps_automatic_reload_running(self):
        self.run_case("manual-retry-keeps-auto-reload")

    def test_shortcut_recovery_keeps_newer_settings_issue(self):
        self.run_case("shortcut-recovery-keeps-other-issues")

    def test_shortcut_recovery_clears_its_own_banner(self):
        self.run_case("shortcut-recovery-clears-banner")


if __name__ == "__main__":
    unittest.main()
