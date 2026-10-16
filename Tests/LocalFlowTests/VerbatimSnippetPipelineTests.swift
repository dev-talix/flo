import XCTest
@testable import LocalFlow

@MainActor
final class VerbatimSnippetPipelineTests: XCTestCase {
    private let code = "  ```swift\n\tlet url = \"https://example.com/a?b=1\"\n// beta new line $1 \\n\n```\n "
    private let speech = [Float](repeating: 0.2, count: 16_000)

    func testAutomaticNumberedListKeepsItsStructureAcrossASnippet() async {
        let delivered = expectation(description: "automatic list around snippet")
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "First, insert code. Second, get eggs." },
            cleanup: { .init(text: $0.text, succeeded: true) },
            onOutcome: { outcomes.append($0); delivered.fulfill() }
        )
        pipeline.begin(generation: 20, context: .init(
            cleanupEnabled: false, styleProfile: .general, corrections: [],
            snippets: [("insert code", "code")]
        ))
        pipeline.release(generation: 20, fullSamples: speech)
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 20, text: "1. code\n2. Get eggs.")])
    }

    func testOrdinalListsProtectSavedBytesInFastPolishedAndLiteralModes() async {
        let saved = "  ```swift\n" + String(repeating: "\t// First, new line. Second, beta next item.\n", count: 20) + "```\n "
        for polished in [false, true] {
            for literal in [false, true] {
                let delivered = expectation(description: "ordinal composition")
                var inputs: [String] = []
                var outcomes: [DictationSessionOutcome] = []
                let pipeline = DictationSessionPipeline(
                    transcribe: { _ in "First, insert code. Second, talex. Third, insert code!" },
                    cleanup: { request in
                        XCTAssertTrue(polished)
                        inputs.append(request.text)
                        return .init(text: request.text, succeeded: true)
                    },
                    onOutcome: { outcomes.append($0); delivered.fulfill() }
                )
                pipeline.begin(generation: 21, context: .init(
                    cleanupEnabled: polished, styleProfile: .general,
                    corrections: [("talex", "Talix"), ("beta", "wrong"), ("insert code", "wrong")],
                    snippets: [("insert code", saved), ("beta", "wrong")], literalFormatting: literal
                ))
                pipeline.release(generation: 21, fullSamples: speech)
                await fulfillment(of: [delivered], timeout: 1)
                let expected = literal
                    ? "First, " + saved + " Second, Talix. Third, " + saved
                    : "1. " + saved + "\n2. Talix.\n3. " + saved
                XCTAssertEqual(outcomes, [.finalTranscript(generation: 21, text: expected)])
                XCTAssertEqual(inputs, !polished ? [] : literal ? ["First,", "Second, Talix. Third,"] : ["1.", "2. Talix.\n3."])
            }
        }
    }

    func testPolishedIdentityKeepsTheConfirmedOrdinalListAndOnlyCleansProse() async {
        let delivered = expectation(description: "polished ordinal list")
        var inputs: [String] = []
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "First, insert code. Second, get eggs." },
            cleanup: { request in
                inputs.append(request.text)
                return .init(text: request.text, succeeded: true)
            },
            onOutcome: { outcomes.append($0); delivered.fulfill() }
        )
        pipeline.begin(generation: 22, context: .init(
            cleanupEnabled: true, styleProfile: .general, corrections: [], snippets: [("insert code", "code")]
        ))
        pipeline.release(generation: 22, fullSamples: speech)
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(inputs, ["1.", "2. Get eggs."])
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 22, text: "1. code\n2. Get eggs.")])
    }

    func testDefaultThreeSecondDeadlineRestoresEntireOrdinalListAfterPartialCleanup() async {
        let started = expectation(description: "second prose span stalled")
        let delivered = expectation(description: "default cleanup deadline")
        var continuation: CheckedContinuation<TranscriptCleanupResult, Never>?
        var inputs: [String] = []
        var outcomes: [DictationSessionOutcome] = []
        var cleanupStarted: Date?
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "First, insert code. Second, get eggs. Third, insert code. Finally, done." },
            cleanup: { request in
                inputs.append(request.text)
                if inputs.count == 1 {
                    cleanupStarted = Date()
                    return .init(text: "REWRITTEN", succeeded: true)
                }
                return await withCheckedContinuation { continuation = $0; started.fulfill() }
            },
            onOutcome: { outcomes.append($0); delivered.fulfill() }
        )
        pipeline.begin(generation: 23, context: .init(
            cleanupEnabled: true, styleProfile: .general, corrections: [], snippets: [("insert code", code)]
        ))
        pipeline.release(generation: 23, fullSamples: speech)
        await fulfillment(of: [started], timeout: 1)
        await fulfillment(of: [delivered], timeout: 5)
        if let cleanupStarted { XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(cleanupStarted), 2.8) }
        let expected = "1. " + code + "\n2. Get eggs.\n3. " + code + "\n4. Done."
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 23, text: expected)])
        continuation?.resume(returning: .init(text: "LATE REWRITE", succeeded: true))
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(inputs, ["1.", "2. Get eggs.\n3."])
        XCTAssertEqual(outcomes.count, 1)
    }

    func testPolishedOnlyCleansProseAndReassemblesRepeatedSnippetsInOrder() async {
        let delivered = expectation(description: "composed output")
        var inputs: [String] = []
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "talex insert code. and insert code! done" },
            cleanup: { request in
                inputs.append(request.text)
                return .init(text: request.text.uppercased(), succeeded: true)
            },
            onOutcome: { outcomes.append($0); delivered.fulfill() }
        )
        pipeline.begin(generation: 1, context: context(cleanupEnabled: true))
        pipeline.release(generation: 1, fullSamples: speech)
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(inputs, ["Talix", "and", "done"])
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 1, text: "TALIX " + code + " AND " + code + " DONE")])
    }

    func testFastProtectsTriggerFromCorrectionsAndFormattingAndExpansionFromAllTransforms() async {
        let delivered = expectation(description: "fast snippet")
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "bullet point insert code" },
            cleanup: { request in
                XCTFail("Fast must skip cleanup")
                return .init(text: request.text, succeeded: false)
            },
            onOutcome: { outcomes.append($0); delivered.fulfill() }
        )
        pipeline.begin(generation: 2, context: .init(
            cleanupEnabled: false, styleProfile: .general,
            corrections: [("insert code", "wrong"), ("beta", "wrong")],
            snippets: [("bullet point insert code", code)]
        ))
        pipeline.release(generation: 2, fullSamples: speech)
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 2, text: code)])
    }

    func testCleanupAndReleaseDeadlinesRestoreEntireCompositionAndIgnoreLateResults() async {
        for releaseDeadline in [false, true] {
            let delivered = expectation(description: "fallback")
            let started = expectation(description: "cleanup started")
            var continuation: CheckedContinuation<TranscriptCleanupResult, Never>?
            var outcomes: [DictationSessionOutcome] = []
            let pipeline = DictationSessionPipeline(
                transcribe: { _ in "talex insert code. done" },
                cleanup: { _ in
                    await withCheckedContinuation {
                        continuation = $0
                        started.fulfill()
                    }
                },
                onOutcome: { outcomes.append($0); delivered.fulfill() },
                stalledGenerationTimeout: releaseDeadline ? 0.03 : 2,
                cleanupTimeout: releaseDeadline ? 2 : 0.03
            )
            pipeline.begin(generation: 3, context: context(cleanupEnabled: true))
            pipeline.release(generation: 3, fullSamples: speech)
            await fulfillment(of: [started, delivered], timeout: 1)
            XCTAssertEqual(outcomes, [.finalTranscript(generation: 3, text: "Talix " + code + " done")])
            continuation?.resume(returning: .init(text: "rewritten late", succeeded: true))
            for _ in 0..<50 { await Task.yield() }
            XCTAssertEqual(outcomes.count, 1)
        }
    }

    func testLiteralPolicyIsSnapshottedAndUsedWithFastAndPolished() async {
        for polished in [false, true] {
            let delivered = expectation(description: "literal words")
            var literalFormatting = true
            var cleanupCalls = 0
            var outcomes: [DictationSessionOutcome] = []
            let words = "talex says bullet point new line thumbs up emoji. First, code. Second, prose."
            let expected = "Talix says bullet point new line thumbs up emoji. First, code. Second, prose."
            let pipeline = DictationSessionPipeline(
                transcribe: { _ in words },
                cleanup: { request in
                    cleanupCalls += 1
                    XCTAssertTrue(request.context.literalFormatting)
                    XCTAssertEqual(request.text, expected)
                    return .init(text: request.text, succeeded: true)
                },
                onOutcome: { outcomes.append($0); delivered.fulfill() }
            )
            pipeline.begin(generation: 4, context: .init(
                cleanupEnabled: polished, styleProfile: .general,
                corrections: [("talex", "Talix")], snippets: [], literalFormatting: literalFormatting
            ))
            literalFormatting = false
            pipeline.release(generation: 4, fullSamples: speech)
            await fulfillment(of: [delivered], timeout: 1)
            XCTAssertEqual(outcomes, [.finalTranscript(generation: 4, text: expected)])
            XCTAssertEqual(cleanupCalls, polished ? 1 : 0)
            XCTAssertFalse(literalFormatting)
        }
    }

    func testDefaultCommandsKeepListStateAndBreaksAcrossVerbatimSnippets() async {
        let delivered = expectation(description: "commands around snippet")
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "numbered list insert code next item apples new line pears" },
            cleanup: { request in
                XCTFail("Fast must skip cleanup")
                return .init(text: request.text, succeeded: false)
            },
            onOutcome: { outcomes.append($0); delivered.fulfill() }
        )
        pipeline.begin(generation: 5, context: .init(
            cleanupEnabled: false, styleProfile: .general, corrections: [],
            snippets: [("insert code", "lowercase new line")]
        ))
        pipeline.release(generation: 5, fullSamples: speech)
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 5, text: "1. lowercase new line\n2. Apples\nPears")])
    }

    func testSnippetOnlyPolishedNeverSendsSavedTextToCleaner() async {
        let delivered = expectation(description: "snippet only")
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "insert code" },
            cleanup: { request in
                XCTFail("No prose exists to clean")
                return .init(text: "rewritten", succeeded: true)
            },
            onOutcome: { outcomes.append($0); delivered.fulfill() }
        )
        pipeline.begin(generation: 6, context: context(cleanupEnabled: true))
        pipeline.release(generation: 6, fullSamples: speech)
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 6, text: code)])
    }

    func testTimeoutAfterPartialCleanupRestoresAllProseAndStopsLaterSpans() async {
        let started = expectation(description: "second span stalled")
        let delivered = expectation(description: "whole fallback")
        var continuation: CheckedContinuation<TranscriptCleanupResult, Never>?
        var inputs: [String] = []
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "before insert code middle insert code after" },
            cleanup: { request in
                inputs.append(request.text)
                if inputs.count == 1 { return .init(text: "POLISHED", succeeded: true) }
                return await withCheckedContinuation { continuation = $0; started.fulfill() }
            },
            onOutcome: { outcomes.append($0); delivered.fulfill() },
            cleanupTimeout: 0.05
        )
        pipeline.begin(generation: 7, context: context(cleanupEnabled: true))
        pipeline.release(generation: 7, fullSamples: speech)
        await fulfillment(of: [started, delivered], timeout: 1)
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 7, text: "before " + code + " middle " + code + " after")])
        continuation?.resume(returning: .init(text: "LATE", succeeded: true))
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(inputs, ["before", "middle"])
        XCTAssertEqual(outcomes.count, 1)
    }

    func testLiteralPolicyAlsoAppliesToDeadlineFallback() async {
        let started = expectation(description: "literal cleanup stalled")
        let delivered = expectation(description: "literal fallback")
        var continuation: CheckedContinuation<TranscriptCleanupResult, Never>?
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "bullet point insert code" },
            cleanup: { request in
                XCTAssertTrue(request.context.literalFormatting)
                XCTAssertEqual(request.text, "bullet point")
                return await withCheckedContinuation { continuation = $0; started.fulfill() }
            },
            onOutcome: { outcomes.append($0); delivered.fulfill() },
            cleanupTimeout: 0.03
        )
        pipeline.begin(generation: 8, context: .init(
            cleanupEnabled: true, styleProfile: .general, corrections: [],
            snippets: [("insert code", code)], literalFormatting: true
        ))
        pipeline.release(generation: 8, fullSamples: speech)
        await fulfillment(of: [started, delivered], timeout: 1)
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 8, text: "bullet point " + code)])
        continuation?.resume(returning: .init(text: "late", succeeded: true))
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(outcomes.count, 1)
    }

    func testCorrectionsCannotCreateAdditionalSnippetMatches() async {
        let delivered = expectation(description: "only original trigger expands")
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "alias insert code" },
            cleanup: { request in .init(text: request.text, succeeded: true) },
            onOutcome: { outcomes.append($0); delivered.fulfill() }
        )
        pipeline.begin(generation: 9, context: .init(
            cleanupEnabled: true, styleProfile: .general,
            corrections: [("alias", "insert code")], snippets: [("insert code", code)]
        ))
        pipeline.release(generation: 9, fullSamples: speech)
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 9, text: "insert code " + code)])
    }

    func testFailedCleanupPreservesProseSpacingAndVerbatimExpansion() async {
        let delivered = expectation(description: "backend fallback")
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "before insert code after" },
            cleanup: { request in .init(text: request.text, succeeded: false) },
            onOutcome: { outcomes.append($0); delivered.fulfill() }
        )
        pipeline.begin(generation: 10, context: context(cleanupEnabled: true))
        pipeline.release(generation: 10, fullSamples: speech)
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 10, text: "before " + code + " after")])
    }

    private func context(cleanupEnabled: Bool) -> DictationSessionContext {
        .init(cleanupEnabled: cleanupEnabled, styleProfile: .general,
              corrections: [("talex", "Talix"), ("beta", "wrong")],
              snippets: [("insert code", code), ("beta", "wrong")])
    }
}
