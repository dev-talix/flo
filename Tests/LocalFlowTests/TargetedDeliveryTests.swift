import AppKit
import XCTest
@testable import LocalFlow

@MainActor
final class TargetedDeliveryTests: XCTestCase {
    func testDelayedReaderProtectsFirstDictationPast400msAndPreservesFIFO() async throws {
        let harness = DeliveryHarness(test: self)
        let first = harness.delivery.begin(harness.configuration)
        let second = harness.delivery.begin(harness.configuration)
        let third = harness.delivery.begin(harness.configuration)
        harness.delivery.release(generation: first, samples: harness.speech)
        harness.delivery.release(generation: second, samples: harness.speech)
        harness.delivery.release(generation: third, samples: harness.speech)
        await waitUntil { harness.history.count == 3 }
        XCTAssertEqual(harness.sent, ["dictation 0"])
        let originalReceipt = try XCTUnwrap(harness.board.receipt)

        // A real elapsed wait catches a return to the old fixed 400 ms timer.
        try await Task.sleep(nanoseconds: 550_000_000)
        harness.time += 0.55
        XCTAssertEqual(harness.sent, ["dictation 0"])
        XCTAssertTrue(harness.board.receipt === originalReceipt)
        XCTAssertEqual(harness.board.string(forType: .string), "dictation 0")
        XCTAssertEqual(harness.sent.count, 1, "Provider must return before another paste begins")
        await waitUntil { harness.sent.count == 2 }
        XCTAssertEqual(harness.sent, ["dictation 0", "dictation 1"])
        XCTAssertTrue(harness.delivery.isBusy, "Restoration remains a separate completion")
        XCTAssertEqual(harness.results, [.dispatched], "Superseding a read receipt resolves its restoration")
        XCTAssertEqual(harness.board.string(forType: .string), "dictation 1")
        await waitUntil { harness.sent.count == 3 }
        XCTAssertEqual(harness.board.string(forType: .string), "dictation 2")
        await settle()
        TextInjector.restoreNow()
        XCTAssertFalse(harness.delivery.isBusy)
        XCTAssertEqual(harness.sent, harness.history)
        XCTAssertEqual(harness.board.string(forType: .string), "user clipboard")
    }

    func testUnreadTimeoutRestoresThenUnblocksNextOnce() async throws {
        let harness = DeliveryHarness(test: self)
        harness.enqueueCommands(["first", "second"])
        XCTAssertEqual(harness.sent, ["first"])
        harness.time += 10
        let oldTimeout = try XCTUnwrap(harness.scheduled.first)
        oldTimeout.perform()
        XCTAssertEqual(harness.sent, ["first", "second"])
        oldTimeout.perform()
        XCTAssertEqual(harness.sent, ["first", "second"])
        XCTAssertEqual(harness.results, [.dispatched])
        XCTAssertTrue(TextInjector.isAwaitingPasteboardRead)
        TextInjector.restoreNow()
        XCTAssertFalse(harness.delivery.isBusy)
        XCTAssertEqual(harness.board.string(forType: .string), "user clipboard")
    }

    func testChangedClipboardFinishesUnreadReceiptAndPreservesNewSnapshot() async {
        let harness = DeliveryHarness(test: self)
        harness.enqueueCommands(["first", "second"])
        harness.board.setString("user copied meanwhile", forType: .string)
        await waitUntil { harness.sent.count == 2 }
        XCTAssertEqual(harness.results, [.clipboardChanged])
        XCTAssertEqual(harness.board.string(forType: .string), "second")
        await settle()
        TextInjector.restoreNow()
        XCTAssertEqual(harness.sent, ["first", "second"])
        XCTAssertEqual(harness.board.string(forType: .string), "user copied meanwhile")
        XCTAssertFalse(harness.delivery.isBusy)
    }

    func testCancelledQueuedCommandAndDuplicateReadCannotHangOrAdvanceTwice() async {
        let harness = DeliveryHarness(test: self)
        let first = harness.delivery.beginCommand()
        let cancelled = harness.delivery.beginCommand()
        let third = harness.delivery.beginCommand()
        let fourth = harness.delivery.beginCommand()
        harness.delivery.completeCommand(first, with: .inject("first"))
        harness.delivery.completeCommand(third, with: .inject("third"))
        harness.delivery.completeCommand(fourth, with: .inject("fourth"))
        harness.delivery.completeCommand(cancelled, with: .skip)
        harness.delivery.completeCommand(cancelled, with: .inject("stale"))
        XCTAssertEqual(harness.board.string(forType: .string), "first")
        XCTAssertEqual(harness.board.string(forType: .string), "first")
        await waitUntil { harness.sent.count == 2 }
        await settle()
        XCTAssertEqual(harness.sent, ["first", "third"])
        TextInjector.restoreNow()
        XCTAssertEqual(harness.sent, ["first", "third", "fourth"])
        TextInjector.restoreNow()
        XCTAssertFalse(harness.delivery.isBusy)
    }

    func testImmediateDispatchFailureUnblocksFollowingPaste() {
        let harness = DeliveryHarness(test: self)
        harness.failNextPaste = true
        harness.enqueueCommands(["failed", "next"])
        XCTAssertEqual(harness.sent, ["next"])
        XCTAssertEqual(harness.results, [.dispatchFailed])
        TextInjector.restoreNow()
        XCTAssertEqual(harness.board.string(forType: .string), "user clipboard")
        XCTAssertFalse(harness.delivery.isBusy)
    }

    func testTypingSuccessAndFailureWaitForPostedChunksThenUnblock() {
        for succeeds in [true, false] {
            let harness = DeliveryHarness(test: self)
            harness.secureInput = true
            harness.enqueueCommands(["typed", "next"])
            XCTAssertTrue(harness.sent.isEmpty)
            XCTAssertEqual(harness.typed, ["typed"])
            XCTAssertEqual(harness.board.string(forType: .string), "user clipboard")
            harness.secureInput = false
            harness.finishTyping?(succeeds)
            XCTAssertEqual(harness.results, [succeeds ? .dispatched : .dispatchFailed])
            XCTAssertEqual(harness.sent, ["next"])
            TextInjector.restoreNow()
            XCTAssertFalse(harness.delivery.isBusy)
        }
    }

    func testEmptyResultUnblocksWithoutClipboardOrEvents() {
        var readyCount = 0
        var results: [TextInjector.InjectionResult] = []
        let board = MemoryClipboard()
        TextInjector.inject("", pasteboard: board, postPaste: { XCTFail("No events"); return false },
                            onReadyForNext: { readyCount += 1 }, completion: { results.append($0) })
        XCTAssertEqual(readyCount, 1)
        XCTAssertEqual(results, [.dispatchFailed])
        XCTAssertEqual(board.changeCount, 0)
    }

    func testTargetIdentityRejectsDifferentProcessElementWindowTextAndRange() throws {
        let focus = CommandFocus()
        let target = try focus.capture().get()
        XCTAssertTrue(focus.validate(target))
        let mutations: [(CommandFocus) -> Void] = [
            { $0.application = AXUIElementCreateApplication(102) },
            { $0.element = AXUIElementCreateApplication(103) },
            { $0.window = AXUIElementCreateApplication(104) },
            { $0.selection = "other words" },
            { $0.range.location += 1 },
            { $0.range.length -= 1 },
            { $0.readable = false },
            { $0.secure = true }
        ]
        for mutate in mutations {
            let changed = CommandFocus()
            mutate(changed)
            XCTAssertFalse(changed.validate(target))
        }
    }

    func testUnreadPasteRefusesAXCaptureWithoutCallingReaders() {
        let harness = DeliveryHarness(test: self)
        harness.enqueueCommands(["pending"])
        let result = TextInjector.captureCommandTarget(isSecureInputEnabled: { false }, focusedApplication: {
            XCTFail("Must not call AX while target awaits paste")
            return nil
        }, readAttribute: { _, _ in XCTFail("Must not read AX"); return (.failure, nil) })
        guard case .failure(.unavailable) = result else { return XCTFail("Expected safe refusal") }
    }

    func testUnavailableOrInconsistentSelectionRangeRefusesCommandCapture() {
        let focus = CommandFocus()
        focus.readable = false
        guard case .failure(.unavailable) = focus.capture() else { return XCTFail("Expected failure") }
        focus.readable = true
        focus.selection = nil
        guard case .failure(.unavailable) = focus.capture() else { return XCTFail("Nonempty range needs readable text") }
    }

    func testFocusChangeDuringRecognitionKeepsCapturedInputAndRejectsDelivery() async throws {
        let focus = CommandFocus()
        let target = try focus.capture().get()
        let harness = DeliveryHarness(test: self, focus: focus)
        let command = harness.delivery.beginCommand()
        // Recognition has not returned. A window in the same app takes focus.
        await Task.yield()
        focus.window = AXUIElementCreateApplication(108)
        XCTAssertEqual(target.selection, "original words")
        harness.delivery.completeCommand(command, with: .inject("rewritten original words", target: target))
        XCTAssertEqual(harness.history, ["rewritten original words"])
        XCTAssertEqual(harness.results, [.targetChanged])
        XCTAssertTrue(harness.sent.isEmpty)
        XCTAssertEqual(harness.board.string(forType: .string), "user clipboard")
        XCTAssertFalse(harness.delivery.isBusy)
    }

    func testSelectionChangeDuringRewriteRejectsAndLeavesOutputCopyable() async throws {
        let focus = CommandFocus()
        let target = try focus.capture().get()
        let harness = DeliveryHarness(test: self, focus: focus)
        let command = harness.delivery.beginCommand()
        XCTAssertEqual(target.selection, "original words")
        await Task.yield()
        focus.selection = "new selection"
        harness.delivery.completeCommand(command, with: .inject("rewrite result", target: target))
        XCTAssertEqual(harness.history, ["rewrite result"])
        XCTAssertEqual(harness.results, [.targetChanged])
        XCTAssertTrue(harness.sent.isEmpty)
        XCTAssertFalse(harness.delivery.isBusy)
    }

    func testTargetChangeWhileReadingClipboardSnapshotRejectsBeforeAnyWrite() throws {
        let focus = CommandFocus()
        let target = try focus.capture().get()
        let harness = DeliveryHarness(test: self, focus: focus)
        let changeCount = harness.board.changeCount
        harness.board.onSnapshot = { focus.range.location += 1 }
        let command = harness.delivery.beginCommand()
        harness.delivery.completeCommand(command, with: .inject("result", target: target))
        XCTAssertEqual(harness.history, ["result"])
        XCTAssertEqual(harness.results, [.targetChanged])
        XCTAssertTrue(harness.sent.isEmpty)
        XCTAssertEqual(harness.board.changeCount, changeCount)
        XCTAssertFalse(harness.delivery.isBusy)
    }

    func testTargetIsRevalidatedWhenQueuedCommandFinallyReachesInjector() async throws {
        let focus = CommandFocus()
        let target = try focus.capture().get()
        let harness = DeliveryHarness(test: self, focus: focus)
        harness.enqueueCommands(["preceding dictation"])
        let command = harness.delivery.beginCommand()
        harness.delivery.completeCommand(command, with: .inject("rewrite", target: target))
        focus.range.location += 3
        XCTAssertEqual(harness.board.string(forType: .string), "preceding dictation")
        await settle()
        XCTAssertEqual(harness.sent, ["preceding dictation"])
        XCTAssertEqual(harness.results.last, .targetChanged)
        TextInjector.restoreNow()
        XCTAssertFalse(harness.delivery.isBusy)
    }

    func testUnchangedSelectionDispatchesReplacementAndNoSelectionGuardsCursor() throws {
        for selection: String? in ["original words", nil] {
            let focus = CommandFocus()
            focus.selection = selection
            focus.range.length = selection == nil ? 0 : 14
            let target = try focus.capture().get()
            let harness = DeliveryHarness(test: self, focus: focus)
            let command = harness.delivery.beginCommand()
            harness.delivery.completeCommand(command, with: .inject("result", target: target))
            XCTAssertEqual(harness.sent, ["result"])
            TextInjector.restoreNow()
            XCTAssertFalse(harness.delivery.isBusy)
            focus.range.location += 1
            let moved = harness.delivery.beginCommand()
            harness.delivery.completeCommand(moved, with: .inject("must not insert", target: target))
            XCTAssertEqual(harness.sent, ["result"])
            XCTAssertEqual(harness.results.last, .targetChanged)
            XCTAssertEqual(harness.history, ["result", "must not insert"])
        }
    }

    func testOrdinaryDictationRetainsFocusedAppPolicyWithoutCommandGuard() async {
        let focus = CommandFocus()
        focus.readable = false
        let harness = DeliveryHarness(test: self, focus: focus)
        let generation = harness.delivery.begin(harness.configuration)
        harness.delivery.release(generation: generation, samples: harness.speech)
        await waitUntil { harness.sent.count == 1 }
        XCTAssertEqual(harness.sent, ["dictation 0"])
        TextInjector.restoreNow()
        XCTAssertFalse(harness.delivery.isBusy)
    }

    private func settle() async { for _ in 0..<50 { await Task.yield() } }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for fake delivery")
    }
}

@MainActor
private final class CommandFocus {
    var application = AXUIElementCreateApplication(100)
    var element = AXUIElementCreateApplication(101)
    var window = AXUIElementCreateApplication(105)
    var selection: String? = "original words"
    var range = CFRange(location: 7, length: 14)
    var readable = true
    var secure = false

    func read(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFTypeRef?) {
        guard readable else { return (.cannotComplete, nil) }
        switch attribute as String {
        case kAXFocusedUIElementAttribute: return (.success, self.element)
        case kAXFocusedWindowAttribute: return (.success, window)
        case kAXSelectedTextAttribute: return (.success, (selection ?? "") as CFString)
        case kAXSelectedTextRangeAttribute: return (.success, AXValueCreate(.cfRange, &range))
        default: return (.attributeUnsupported, nil)
        }
    }

    func capture() -> Result<TextInjector.CommandTarget, TextInjector.SelectionError> {
        TextInjector.captureCommandTarget(isSecureInputEnabled: { self.secure },
                                          focusedApplication: { self.application }, readAttribute: read)
    }

    func validate(_ target: TextInjector.CommandTarget) -> Bool {
        TextInjector.validateCommandTarget(target, isSecureInputEnabled: { self.secure },
                                           focusedApplication: { self.application }, readAttribute: read)
    }
}

@MainActor
private final class DeliveryHarness {
    let board = MemoryClipboard()
    let focus: CommandFocus
    var sent: [String] = []
    var typed: [String] = []
    var history: [String] = []
    var results: [TextInjector.InjectionResult] = []
    var scheduled: [DispatchWorkItem] = []
    var time: TimeInterval = 100
    var failNextPaste = false
    var secureInput = false
    var finishTyping: ((Bool) -> Void)?
    let speech = [Float](repeating: 0.2, count: 16_000)
    let configuration = DictationDelivery.Configuration(context: .init(
        cleanupEnabled: false, styleProfile: .general, corrections: [], snippets: []
    ))

    lazy var delivery = DictationDelivery(
        transcribe: { "dictation \($0.generation)" },
        cleanup: { .init(text: $0.text, succeeded: true) },
        inject: { [unowned self] text, target, ready, complete in
            TextInjector.inject(text, pasteboard: board, target: target,
                                validateTarget: focus.validate,
                                isSecureInputEnabled: { self.secureInput }, postPaste: {
                if self.failNextPaste { self.failNextPaste = false; return false }
                self.sent.append(text)
                return true
            }, now: { self.time }, schedule: { _, work in self.scheduled.append(work) }, typeText: { text, finish in
                self.typed.append(text)
                self.finishTyping = finish
            }, onReadyForNext: ready, completion: { result in
                self.results.append(result)
                complete()
            })
        }, recordTranscript: { [unowned self] in history.append($0) }, onOutcome: { _, _ in },
        onCancelled: { _ in }, onCommandCancelled: { _ in }, onProcessingCountChange: { _ in }
    )

    init(test: XCTestCase, focus: CommandFocus? = nil) {
        self.focus = focus ?? CommandFocus()
        board.setString("user clipboard", forType: .string)
        test.addTeardownBlock { @MainActor [self] in
            TextInjector.restoreNow()
            withExtendedLifetime(self) {}
        }
    }

    func enqueueCommands(_ texts: [String]) {
        for text in texts {
            let sequence = delivery.beginCommand()
            delivery.completeCommand(sequence, with: .inject(text))
        }
    }
}
