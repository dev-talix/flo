import XCTest
@testable import LocalFlow

@MainActor
final class DictationCleanupDeadlineTests: XCTestCase {
    private let speech = [Float](repeating: 0.2, count: 16_000)

    func testCleanupDeadlineReturnsRecognizedTextWithoutWaitingForBackend() async {
        let suspended = SuspendedCleanup()
        let started = expectation(description: "cleanup started")
        let delivered = expectation(description: "recognized text delivered")
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "recognized words" },
            cleanup: { await suspended.run($0, started: started) },
            onOutcome: { outcomes.append($0); delivered.fulfill() },
            stalledGenerationTimeout: 2,
            cleanupTimeout: 0.03
        )
        pipeline.begin(generation: 1, context: context())
        pipeline.release(generation: 1, fullSamples: speech)
        await fulfillment(of: [started, delivered], timeout: 0.5)
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 1, text: "recognized words")])
        let finished = await suspended.finish(generation: 1, text: "late polished words")
        XCTAssertTrue(finished)
        await settle()
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 1, text: "recognized words")])
    }

    func testReleaseDeadlineDuringCleanupUsesRecognizedText() async {
        let suspended = SuspendedCleanup()
        let started = expectation(description: "cleanup started")
        let delivered = expectation(description: "release deadline preserves recognition")
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "keep these words" },
            cleanup: { await suspended.run($0, started: started) },
            onOutcome: { outcomes.append($0); delivered.fulfill() },
            stalledGenerationTimeout: 0.03,
            cleanupTimeout: 2
        )
        pipeline.begin(generation: 2, context: context())
        pipeline.release(generation: 2, fullSamples: speech)
        await fulfillment(of: [started, delivered], timeout: 0.5)
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 2, text: "keep these words")])
        _ = await suspended.finish(generation: 2, text: "late result")
        await settle()
        XCTAssertEqual(outcomes.count, 1)
    }

    func testCleanupWithinBudgetKeepsPolishedResult() async {
        let delivered = expectation(description: "polished result")
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "raw words" },
            cleanup: { _ in .init(text: "Polished words.", succeeded: true) },
            onOutcome: { outcomes.append($0); delivered.fulfill() },
            cleanupTimeout: 0.03
        )
        pipeline.begin(generation: 3, context: context())
        pipeline.release(generation: 3, fullSamples: speech)
        await fulfillment(of: [delivered], timeout: 0.5)
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 3, text: "Polished words.")])
    }

    func testFastPathSkipsModelCleanup() async {
        let delivered = expectation(description: "fast result")
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "fast words" },
            cleanup: { request in
                XCTFail("Disabled cleanup must not call a text model")
                return .init(text: request.text, succeeded: false)
            },
            onOutcome: { outcomes.append($0); delivered.fulfill() },
            cleanupTimeout: 0
        )
        pipeline.begin(generation: 4, context: context(cleanupEnabled: false))
        pipeline.release(generation: 4, fullSamples: speech)
        await fulfillment(of: [delivered], timeout: 0.5)
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 4, text: "fast words")])
    }

    func testCancelledCleanupCannotDeliverAtItsDeadlineOrOnLateReturn() async {
        let suspended = SuspendedCleanup()
        let started = expectation(description: "cleanup started")
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "cancelled words" },
            cleanup: { await suspended.run($0, started: started) },
            onOutcome: { outcomes.append($0) },
            cleanupTimeout: 0.03
        )
        pipeline.begin(generation: 5, context: context())
        pipeline.release(generation: 5, fullSamples: speech)
        await fulfillment(of: [started], timeout: 0.5)
        pipeline.cancel(generation: 5)
        try? await Task.sleep(for: .milliseconds(60))
        _ = await suspended.finish(generation: 5, text: "late cancelled result")
        await settle()
        XCTAssertTrue(outcomes.isEmpty)
    }

    func testCleanupFallbackUnblocksCompletedFollowerInSpokenOrder() async {
        let suspended = SuspendedCleanup()
        let started = expectation(description: "first cleanup started")
        let delivered = expectation(description: "both results delivered")
        delivered.expectedFulfillmentCount = 2
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { "words \($0.generation)" },
            cleanup: { request in
                if request.generation == 6 { return await suspended.run(request, started: started) }
                return .init(text: "Polished follower.", succeeded: true)
            },
            onOutcome: { outcomes.append($0); delivered.fulfill() },
            cleanupTimeout: 0.05
        )
        pipeline.begin(generation: 6, context: context())
        pipeline.release(generation: 6, fullSamples: speech)
        await fulfillment(of: [started], timeout: 0.5)
        pipeline.begin(generation: 7, context: context())
        pipeline.release(generation: 7, fullSamples: speech)
        await fulfillment(of: [delivered], timeout: 0.5)
        XCTAssertEqual(outcomes, [
            .finalTranscript(generation: 6, text: "words 6"),
            .finalTranscript(generation: 7, text: "Polished follower.")
        ])
        _ = await suspended.finish(generation: 6, text: "late first result")
        await settle()
        XCTAssertEqual(outcomes.count, 2)
    }

    private func context(cleanupEnabled: Bool = true) -> DictationSessionContext {
        .init(cleanupEnabled: cleanupEnabled, styleProfile: .general, corrections: [], snippets: [])
    }

    private func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }
}

private actor SuspendedCleanup {
    private var pending: [Int: CheckedContinuation<TranscriptCleanupResult, Never>] = [:]

    func run(_ request: DictationCleanupRequest, started: XCTestExpectation) async -> TranscriptCleanupResult {
        await withCheckedContinuation { continuation in
            pending[request.generation] = continuation
            started.fulfill()
        }
    }

    func finish(generation: Int, text: String) -> Bool {
        guard let continuation = pending.removeValue(forKey: generation) else { return false }
        continuation.resume(returning: .init(text: text, succeeded: true))
        return true
    }
}
