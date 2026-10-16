import XCTest
import WhisperKit
@testable import LocalFlow

@MainActor
final class PreviewInferenceBudgetTests: XCTestCase {
    private let speech = [Float](repeating: 0.2, count: Int(AudioRecorder.sampleRate))
    private let context = DictationSessionContext(
        cleanupEnabled: true, styleProfile: .general, corrections: [], snippets: []
    )

    func testAuthoritativeRequestsPassQueuedPreviewInFIFOOrderThroughRealTranscriber() async throws {
        let engine = BudgetEngine()
        let transcriber = Transcriber(modelLoader: { _, _ in engine })
        try await transcriber.load(model: "test")
        let active = Task { try await transcriber.transcribe(samples: [1]) }
        await expectEventually { await engine.calls.count == 1 }
        let preview = Task {
            try await transcriber.transcribe(samples: [2], purpose: .preview(TranscriptionLifetime()))
        }
        await expectEventually { await transcriber.waitingInferenceCount == 1 }
        let firstFinal = Task { try await transcriber.transcribe(samples: [3]) }
        await expectEventually { await transcriber.waitingInferenceCount == 2 }
        let secondFinal = Task { try await transcriber.transcribe(samples: [4]) }
        await expectEventually { await transcriber.waitingInferenceCount == 3 }

        await engine.finishFirst()
        _ = try await active.value
        _ = try await firstFinal.value
        _ = try await secondFinal.value
        _ = try await preview.value
        let calls = await engine.calls
        XCTAssertEqual(calls.map { $0.samples[0] }, [1, 3, 4, 2])
        XCTAssertEqual(calls.map(\.isPreview), [false, false, false, true])
    }

    func testReleaseRemovesQueuedPreviewBeforeAuthoritativeInference() async throws {
        try await verifyQueuedPreviewIsRemoved(release: true)
    }

    func testEscapeRemovesQueuedPreviewWithoutUnloadingEngine() async throws {
        try await verifyQueuedPreviewIsRemoved(release: false)
    }

    private func verifyQueuedPreviewIsRemoved(release: Bool) async throws {
        let engine = BudgetEngine()
        let transcriber = Transcriber(modelLoader: { _, _ in engine })
        try await transcriber.load(model: "test")
        let active = Task { try await transcriber.transcribe(samples: [1]) }
        await expectEventually { await engine.calls.count == 1 }
        var outcomes: [DictationSessionOutcome] = []
        var partials: [String] = []
        var cleanupInputs: [String] = []
        var submitted: [DictationTranscriptionSegment] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { submitted.append($0.segment); return try await transcriber.transcribe($0) },
            cleanup: { cleanupInputs.append($0.text); return .init(text: $0.text, succeeded: true) },
            onOutcome: { outcomes.append($0) },
            onPartialTranscript: { _, text in partials.append(text) }
        )
        pipeline.begin(generation: 1, context: context)
        pipeline.processIncrementalSnapshot(generation: 1, samples: speech)
        await expectEventually { await transcriber.waitingInferenceCount == 1 }
        if release {
            pipeline.release(generation: 1, audio: DictationAudioPreparation(samples: speech + speech))
            // The final request replaces the obsolete preview in the queue.
            await expectEventually {
                guard submitted.last == .fullUtterance else { return false }
                return await transcriber.waitingInferenceCount == 1
            }
        } else {
            pipeline.cancel(generation: 1, interruptInference: false)
            // Removal must happen while the earlier inference still owns the gate.
            await expectEventually { await transcriber.waitingInferenceCount == 0 }
        }
        let stillLoaded = await transcriber.isLoaded
        XCTAssertTrue(stillLoaded)
        await engine.finishFirst()
        _ = try await active.value
        if release { await expectEventually { outcomes.count == 1 } }
        // Drain callbacks from the abandoned preview before inspecting effects.
        for _ in 0..<100 { await Task.yield() }
        let calls = await engine.calls
        XCTAssertEqual(calls.count, release ? 2 : 1)
        XCTAssertTrue(calls.allSatisfy { !$0.isPreview })
        if release {
            XCTAssertEqual(calls.last?.samples, speech + speech)
            XCTAssertEqual(outcomes, [.finalTranscript(generation: 1, text: "final words")])
            XCTAssertEqual(cleanupInputs, ["final words"])
        } else {
            XCTAssertTrue(outcomes.isEmpty)
            XCTAssertTrue(cleanupInputs.isEmpty)
        }
        XCTAssertTrue(partials.isEmpty)
        let loadedAfterReturn = await transcriber.isLoaded
        XCTAssertTrue(loadedAfterReturn)
    }

    func testReleaseWaitsForActivePreviewWithoutCancellingAndKeepsFullFinalAudio() async throws {
        let engine = BudgetEngine()
        let transcriber = Transcriber(modelLoader: { _, _ in engine })
        try await transcriber.load(model: "test")
        var outcomes: [DictationSessionOutcome] = []
        var partials: [String] = []
        var cleanupInputs: [String] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { try await transcriber.transcribe($0) },
            cleanup: { cleanupInputs.append($0.text); return .init(text: $0.text, succeeded: true) },
            onOutcome: { outcomes.append($0) },
            onPartialTranscript: { _, text in partials.append(text) }
        )
        let full = [Float](repeating: 0.2, count: speech.count * 45)
        pipeline.begin(generation: 1, context: context)
        pipeline.processIncrementalSnapshot(generation: 1, samples: full)
        await expectEventually { await engine.calls.count == 1 }
        // Busy ticks cannot create another preview for this session.
        pipeline.processIncrementalSnapshot(generation: 1, samples: full + speech)
        pipeline.release(generation: 1, fullSamples: full)
        await expectEventually { await transcriber.waitingInferenceCount == 1 }
        let whileBlocked = await engine.calls
        XCTAssertEqual(whileBlocked.count, 1)
        XCTAssertEqual(whileBlocked.first?.samples.count, speech.count * 15)
        XCTAssertEqual(whileBlocked.first?.isPreview, true)
        XCTAssertTrue(outcomes.isEmpty)
        let loaded = await transcriber.isLoaded
        XCTAssertTrue(loaded, "Release must not cancel active preview inference")

        await engine.finishFirst()
        await expectEventually { outcomes.count == 1 }
        let calls = await engine.calls
        XCTAssertEqual(calls.map(\.isPreview), [true, false])
        XCTAssertEqual(calls.last?.samples, full)
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 1, text: "final words")])
        XCTAssertEqual(cleanupInputs, ["final words"])
        XCTAssertTrue(partials.isEmpty)
    }

    func testEscapeLeavesActivePreviewLoadedAndNextDictationUsesSameEngine() async throws {
        let engine = BudgetEngine()
        var loads = 0
        let transcriber = Transcriber(modelLoader: { _, _ in loads += 1; return engine })
        try await transcriber.load(model: "test")
        var outcomes: [DictationSessionOutcome] = []
        var partials: [String] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { try await transcriber.transcribe($0) },
            cleanup: { .init(text: $0.text, succeeded: true) },
            onOutcome: { outcomes.append($0) },
            onPartialTranscript: { _, text in partials.append(text) }
        )
        pipeline.begin(generation: 1, context: context)
        pipeline.processIncrementalSnapshot(generation: 1, samples: speech)
        await expectEventually { await engine.calls.count == 1 }
        pipeline.cancel(generation: 1, interruptInference: false)
        pipeline.begin(generation: 2, context: context)
        pipeline.release(generation: 2, fullSamples: speech)
        await expectEventually { await transcriber.waitingInferenceCount == 1 }
        let loaded = await transcriber.isLoaded
        XCTAssertTrue(loaded)
        await engine.finishFirst()
        await expectEventually { outcomes.count == 1 }
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 2, text: "final words")])
        XCTAssertTrue(partials.isEmpty)
        try await transcriber.load(model: "test")
        XCTAssertEqual(loads, 1)
    }

    func testExplicitInterruptionStillQuarantinesActivePreview() async throws {
        let engine = BudgetEngine()
        let transcriber = Transcriber(modelLoader: { _, _ in engine })
        try await transcriber.load(model: "test")
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { try await transcriber.transcribe($0) },
            cleanup: { .init(text: $0.text, succeeded: true) },
            onOutcome: { outcomes.append($0) }
        )
        pipeline.begin(generation: 1, context: context)
        pipeline.processIncrementalSnapshot(generation: 1, samples: speech)
        await expectEventually { await engine.calls.count == 1 }
        pipeline.cancel(generation: 1, interruptInference: true)
        await expectEventually { !(await transcriber.isLoaded) }
        await engine.finishFirst()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(outcomes.isEmpty)
    }

    func testPreviewBackoffUsesObservedDurationPerModelAndNeverDelaysFinals() async throws {
        let clock = BudgetClock()
        let slow = BudgetEngine(blockFirst: false, clock: clock, duration: 4)
        let fast = BudgetEngine(blockFirst: false, clock: clock, duration: 0.25)
        let transcriber = Transcriber(
            modelLoader: { model, _ in model == "slow" ? slow : fast },
            now: { clock.now }
        )
        try await transcriber.load(model: "slow")
        _ = try await transcriber.transcribe(samples: speech, purpose: .preview(TranscriptionLifetime()))
        // Slow preview ran from 0 to 4. Its next budget opens at 8.
        await expectPreviewSkipped(transcriber)
        _ = try await transcriber.transcribe(samples: speech)
        try await transcriber.load(model: "fast")
        _ = try await transcriber.transcribe(samples: speech, purpose: .preview(TranscriptionLifetime()))
        await expectPreviewSkipped(transcriber)
        clock.advance(0.25)
        _ = try await transcriber.transcribe(samples: speech, purpose: .preview(TranscriptionLifetime()))
        try await transcriber.load(model: "slow")
        await expectPreviewSkipped(transcriber)
        clock.advance(8 - clock.now)
        _ = try await transcriber.transcribe(samples: speech, purpose: .preview(TranscriptionLifetime()))
        let slowCalls = await slow.calls
        let fastCalls = await fast.calls
        XCTAssertEqual(slowCalls.map(\.isPreview), [true, false, true])
        XCTAssertEqual(fastCalls.map(\.isPreview), [true, true])
    }

    func testObsoletePreviewCannotAcquireIdleGateOrUnloadModel() async throws {
        let engine = BudgetEngine(blockFirst: false)
        let transcriber = Transcriber(modelLoader: { _, _ in engine })
        try await transcriber.load(model: "test")
        let lifetime = TranscriptionLifetime()
        lifetime.invalidate()
        do {
            _ = try await transcriber.transcribe(samples: speech, purpose: .preview(lifetime))
            XCTFail("Obsolete work must never reach the engine")
        } catch is CancellationError {}
        _ = try await transcriber.transcribe(samples: speech)
        let calls = await engine.calls
        XCTAssertEqual(calls.map(\.isPreview), [false])
        let loaded = await transcriber.isLoaded
        XCTAssertTrue(loaded)
    }

    func testWhisperPreviewHasNoTemperatureFallbacksAndFinalOptionsStayUnchanged() throws {
        let final = WhisperEngine.decodingOptions(lowEnergy: false, purpose: .authoritative)
        let preview = WhisperEngine.decodingOptions(lowEnergy: false, purpose: .preview(TranscriptionLifetime()))
        let quiet = WhisperEngine.decodingOptions(lowEnergy: true, purpose: .authoritative)
        XCTAssertEqual(final.temperatureFallbackCount, DecodingOptions().temperatureFallbackCount)
        XCTAssertEqual(preview.temperatureFallbackCount, 0)
        XCTAssertEqual(preview.temperature, 0)
        XCTAssertEqual(quiet.temperatureFallbackCount, 0)
        // No timestamp, prompt, language, chunking, or filtering changes hide in this path.
        var expectedPreview = final
        expectedPreview.temperatureFallbackCount = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(preview), try encoder.encode(expectedPreview))
    }

    private func expectPreviewSkipped(_ transcriber: Transcriber) async {
        do {
            _ = try await transcriber.transcribe(samples: speech, purpose: .preview(TranscriptionLifetime()))
            XCTFail("Preview inside the observed backoff must be skipped")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private func expectEventually(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}

private actor BudgetEngine: SpeechEngine {
    struct Call {
        let samples: [Float]
        let isPreview: Bool
    }
    private(set) var calls: [Call] = []
    private let blockFirst: Bool
    private var pending: CheckedContinuation<Void, Never>?
    private let clock: BudgetClock?
    private let duration: TimeInterval

    init(blockFirst: Bool = true, clock: BudgetClock? = nil, duration: TimeInterval = 0) {
        self.blockFirst = blockFirst
        self.clock = clock
        self.duration = duration
    }

    func setVocabulary(_ terms: String) {}

    func transcribe(samples: [Float], lowEnergy: Bool) async throws -> EngineTranscription {
        try await transcribe(samples: samples, lowEnergy: lowEnergy, purpose: .authoritative)
    }

    func transcribe(samples: [Float], lowEnergy: Bool, purpose: TranscriptionPurpose) async throws -> EngineTranscription {
        let isPreview = purpose.preview != nil
        calls.append(.init(samples: samples, isPreview: isPreview))
        if blockFirst && calls.count == 1 { await withCheckedContinuation { pending = $0 } }
        if isPreview { clock?.advance(duration) }
        let text = isPreview ? "disposable words" : "final words"
        return .init(segments: [.init(text: text, start: 0, end: 1)], rawText: text,
                     decodingFallbacks: 0, resultCount: 1)
    }

    func finishFirst() {
        pending?.resume()
        pending = nil
    }
}

private final class BudgetClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ duration: TimeInterval) { lock.withLock { value += duration } }
}
