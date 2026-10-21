import XCTest
@testable import LocalFlow

/// Behavioral contract for the async path between captured audio and a
/// transcript that AppDelegate may paste. These tests intentionally target the
/// coordinator, not AppDelegate's old boolean planning helper.
///
/// The production type is expected to own concurrent recording generations,
/// incremental transcription, release fallback, whole-utterance cleanup, and
/// ordered outcome delivery. AppKit remains responsible for the actual paste.
@MainActor
final class DictationSessionPipelineTests: XCTestCase {
    private let speech = [Float](repeating: 0.2, count: Int(AudioRecorder.sampleRate))

    func testRangedAnalysisKeepsTheWholePauseWhenSilenceContinuesAcrossSnapshots() async throws {
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "First." },
            cleanup: { request in .init(text: request.text, succeeded: true) }, onOutcome: { _ in }
        )
        let rate = Int(AudioRecorder.sampleRate)
        let first = [Float](repeating: 0.2, count: rate * 8) + [Float](repeating: 0, count: rate * 4)
        let context = DictationSessionContext(cleanupEnabled: false, styleProfile: .general,
                                             corrections: [], snippets: [],
                                             incrementalCadence: .init(startSeconds: 8, tickSeconds: 4))
        pipeline.begin(generation: 100, context: context)
        pipeline.processIncrementalSnapshot(generation: 100, samples: first)
        await settleAsyncWork()
        let committed = try XCTUnwrap(pipeline.incrementalSampleEnd(generation: 100))
        XCTAssertGreaterThan(committed, rate * 8)
        let extended = first + [Float](repeating: 0, count: rate * 4)
        let range = try XCTUnwrap(pipeline.incrementalSnapshotRange(generation: 100))(extended.count)
        XCTAssertGreaterThan(range.lowerBound, 0)
        let ranged = Array(extended[range])
        let fullCut = try XCTUnwrap(AudioRecorder.incrementalCutPoint(in: extended, after: committed))
        let localCut = try XCTUnwrap(AudioRecorder.incrementalCutPoint(in: ranged, after: committed - range.lowerBound))
        XCTAssertEqual(localCut + range.lowerBound, fullCut)
        XCTAssertEqual(AudioRecorder.incrementalPauseSeconds(in: ranged, around: localCut),
                       AudioRecorder.incrementalPauseSeconds(in: extended, around: fullCut))
        XCTAssertEqual(AudioRecorder.incrementalPauseSeconds(in: ranged, around: localCut), 8)
        pipeline.cancel(generation: 100)
    }

    func testLongCaptureRequestsOnlyPreviewWindowBetweenChunkTicks() async throws {
        let transcriber = ControlledTranscriber()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: RecordingCleaner(mode: .unchanged),
                                    outcomes: OutcomeRecorder())
        let rate = Int(AudioRecorder.sampleRate)
        pipeline.begin(generation: 101, context: context())
        let firstRange = try XCTUnwrap(pipeline.incrementalSnapshotRange(generation: 101))
        XCTAssertEqual(firstRange(rate * 30), 0..<(rate * 30))
        pipeline.processIncrementalSnapshot(generation: 101, samples: [Float](repeating: 0.2, count: rate * 30))
        expectTrue(await waitForCall(.preview, generation: 101, in: transcriber))
        expectTrue(await transcriber.succeed("recent", segment: .preview, generation: 101))
        await settleAsyncWork()
        let nextRange = try XCTUnwrap(pipeline.incrementalSnapshotRange(generation: 101))
        XCTAssertEqual(nextRange(rate * 31), (rate * 16)..<(rate * 31))
        XCTAssertEqual(nextRange(rate * 35), 0..<(rate * 35))
        pipeline.processIncrementalSnapshot(generation: 101, samples: [Float](repeating: 0.3, count: rate * 15),
                                            sampleOffset: rate * 16)
        expectTrue(await waitForCall(.preview, generation: 101, in: transcriber, minimumCount: 2))
        expectEqual(await transcriber.sampleCounts(.preview, generation: 101), [rate * 15, rate])
        pipeline.cancel(generation: 101)
        expectTrue(await transcriber.succeed("ignored", segment: .preview, generation: 101))
        XCTAssertNil(pipeline.incrementalSnapshotRange(generation: 101))
    }

    func testRangedChunksPreserveAbsoluteHalfFrameBoundariesPausesAndReleaseTail() async throws {
        let transcriber = ControlledTranscriber()
        let outcomes = OutcomeRecorder()
        let events = TraceEvents()
        let trace = DictationTrace(sink: { events.append($0) })
        let pipeline = makePipeline(transcriber: transcriber, cleaner: RecordingCleaner(mode: .unchanged), outcomes: outcomes)
        let rate = Int(AudioRecorder.sampleRate)
        var full = [Float](repeating: 0.2, count: rate * 5 / 2)
        full.append(contentsOf: [Float](repeating: 0, count: 21 * 320))
        full.append(contentsOf: [Float](repeating: 0.3, count: rate * 3))
        full.append(contentsOf: [Float](repeating: 0, count: rate * 2))
        full.append(contentsOf: [Float](repeating: 0.4, count: rate * 2))
        let firstEnd = rate * 4 + 21 * 320
        let firstSnapshot = Array(full[..<firstEnd])
        let firstCut = try XCTUnwrap(AudioRecorder.incrementalCutPoint(in: firstSnapshot, after: 0))
        XCTAssertEqual(firstCut % 320, 160)
        let cadence = IncrementalCadence(startSeconds: 4, tickSeconds: 2)
        let context = DictationSessionContext(cleanupEnabled: false, styleProfile: .general,
                                             corrections: [], snippets: [], incrementalCadence: cadence)
        pipeline.begin(generation: 102, context: context, trace: trace)
        pipeline.processIncrementalSnapshot(generation: 102, samples: firstSnapshot)
        expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: 102, in: transcriber))
        XCTAssertEqual(pipeline.incrementalSampleEnd(generation: 102), firstCut)
        XCTAssertNil(pipeline.incrementalSnapshotRange(generation: 102))
        expectTrue(await transcriber.succeed("First.", segment: .incrementalChunk(index: 0), generation: 102))
        await settleAsyncWork()

        let selectRange = try XCTUnwrap(pipeline.incrementalSnapshotRange(generation: 102))
        let range = selectRange(full.count)
        XCTAssertLessThanOrEqual(range.lowerBound, rate * 5 / 2)
        XCTAssertGreaterThan(range.lowerBound, 0)
        XCTAssertEqual(range.lowerBound % 320, 0)
        let secondCut = try XCTUnwrap(AudioRecorder.incrementalCutPoint(in: full, after: firstCut))
        pipeline.processIncrementalSnapshot(generation: 102, samples: Array(full[range]), sampleOffset: range.lowerBound)
        expectTrue(await waitForCall(.incrementalChunk(index: 1), generation: 102, in: transcriber))
        XCTAssertEqual(pipeline.incrementalSampleEnd(generation: 102), secondCut)
        expectEqual(await transcriber.samples(.incrementalChunk(index: 1), generation: 102),
                    [DictationAudioPreparation(samples: Array(full[firstCut..<secondCut])).samples])
        // Release while the ranged chunk is in flight. Submitted and completed
        // offsets differ until it returns; the release tail uses the submitted cut.
        pipeline.release(generation: 102, fullSamples: full)
        let released = try XCTUnwrap(events.events.first { $0.name == .audioReleased })
        XCTAssertEqual(released.fields["submittedEnd"], Double(secondCut))
        XCTAssertEqual(released.fields["completedEnd"], Double(firstCut))
        expectTrue(await transcriber.succeed("Second.", segment: .incrementalChunk(index: 1), generation: 102))
        expectTrue(await waitForCall(.releaseTail, generation: 102, in: transcriber))
        expectEqual(await transcriber.samples(.releaseTail, generation: 102),
                    [DictationAudioPreparation(samples: Array(full[secondCut...])).samples])
        expectTrue(await transcriber.succeed("Last.", segment: .releaseTail, generation: 102))
        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(outcomes.values, [.finalTranscript(generation: 102, text: "First. Second.\n\nLast.")])
    }

    func testDelayedPreviewRangeCannotSubmitTruncatedChunkOrSurviveRelease() async {
        let transcriber = ControlledTranscriber()
        let outcomes = OutcomeRecorder()
        var partials: [String] = []
        let pipeline = makePipeline(transcriber: transcriber, cleaner: RecordingCleaner(mode: .unchanged),
                                    outcomes: outcomes) { _, text in partials.append(text) }
        let rate = Int(AudioRecorder.sampleRate)
        pipeline.begin(generation: 103, context: context(cleanupEnabled: false))
        let window = [Float](repeating: 0.2, count: rate * 10)
            + [Float](repeating: 0, count: rate)
            + [Float](repeating: 0.3, count: rate * 4)
        pipeline.processIncrementalSnapshot(generation: 103, samples: window, sampleOffset: rate * 16)
        expectTrue(await waitForCall(.preview, generation: 103, in: transcriber))
        XCTAssertEqual(pipeline.incrementalSampleEnd(generation: 103), 0)
        expectFalse(await transcriber.hasCall(.incrementalChunk(index: 0), generation: 103))
        let full = [Float](repeating: 0.1, count: rate * 16) + window + speech
        pipeline.release(generation: 103, fullSamples: full)
        // A queued snapshot arriving after release cannot restart live work.
        pipeline.processIncrementalSnapshot(generation: 103, samples: window, sampleOffset: rate * 16)
        expectTrue(await waitForCall(.fullUtterance, generation: 103, in: transcriber))
        expectEqual(await transcriber.samples(.fullUtterance, generation: 103), [full])
        expectTrue(await transcriber.succeed("Complete.", segment: .fullUtterance, generation: 103))
        expectTrue(await waitForOutcomes(1, in: outcomes))
        expectTrue(await transcriber.succeed("stale preview", segment: .preview, generation: 103))
        await settleAsyncWork()
        XCTAssertTrue(partials.isEmpty)
        XCTAssertEqual(outcomes.values, [.finalTranscript(generation: 103, text: "Complete.")])
        XCTAssertNil(pipeline.incrementalSnapshotRange(generation: 103))
    }

    func testReleaseWaitsForActiveChunkBeforeTranscribingTailAndEmitting() async {
        let transcriber = ControlledTranscriber()
        let cleaner = RecordingCleaner(mode: .unchanged)
        let outcomes = OutcomeRecorder()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: cleaner, outcomes: outcomes)

        pipeline.begin(generation: 1, context: context())
        pipeline.processIncrementalChunk(
            generation: 1,
            samples: speech,
            pauseSecondsAfterChunk: 0.4
        )
        expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: 1, in: transcriber))

        pipeline.release(
            generation: 1,
            fullSamples: speech + speech,
            tailSamples: speech
        )
        await settleAsyncWork()

        expectFalse(await transcriber.hasCall(.releaseTail, generation: 1))
        XCTAssertTrue(outcomes.values.isEmpty)

        expectTrue(await transcriber.succeed(
            "first thought",
            segment: .incrementalChunk(index: 0),
            generation: 1
        ))
        expectTrue(await waitForCall(.releaseTail, generation: 1, in: transcriber))
        expectTrue(await transcriber.succeed(
            "second thought",
            segment: .releaseTail,
            generation: 1
        ))

        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(outcomes.values, [
            .finalTranscript(generation: 1, text: "first thought second thought")
        ])
    }

    func testCompletedDictationsEmitInSpokenOrderWhenSecondFinishesFirst() async {
        let transcriber = ControlledTranscriber()
        let cleaner = RecordingCleaner(mode: .unchanged)
        let outcomes = OutcomeRecorder()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: cleaner, outcomes: outcomes)

        pipeline.begin(generation: 10, context: context())
        pipeline.release(generation: 10, fullSamples: speech, tailSamples: speech)
        pipeline.begin(generation: 11, context: context())
        pipeline.release(generation: 11, fullSamples: speech, tailSamples: speech)

        expectTrue(await waitForCall(.fullUtterance, generation: 10, in: transcriber))
        expectTrue(await waitForCall(.fullUtterance, generation: 11, in: transcriber))

        expectTrue(await transcriber.succeed(
            "spoken second",
            segment: .fullUtterance,
            generation: 11
        ))
        await settleAsyncWork()
        XCTAssertTrue(outcomes.values.isEmpty)

        expectTrue(await transcriber.succeed(
            "spoken first",
            segment: .fullUtterance,
            generation: 10
        ))
        expectTrue(await waitForOutcomes(2, in: outcomes))
        XCTAssertEqual(outcomes.values, [
            .finalTranscript(generation: 10, text: "spoken first"),
            .finalTranscript(generation: 11, text: "spoken second")
        ])
    }

    func testPreparedReleaseDerivesQuietTailFromOriginalWhileFirstChunkIsInFlight() async {
        let transcriber = ControlledTranscriber()
        let outcomes = OutcomeRecorder()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: RecordingCleaner(mode: .unchanged),
                                    outcomes: outcomes)
        let silence = [Float](repeating: 0, count: speech.count)
        let quietTail = [Float](repeating: 0.0025, count: speech.count / 2)
        let original = silence + speech + quietTail
        let prepared = DictationAudioPreparation(samples: original)
        XCTAssertLessThan(prepared.samples.count, original.count)
        pipeline.begin(generation: 2, context: context(cleanupEnabled: false))
        pipeline.processIncrementalChunk(generation: 2, samples: silence + speech, pauseSecondsAfterChunk: 0,
                                         sourceEndIndex: silence.count + speech.count)
        expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: 2, in: transcriber))
        pipeline.release(generation: 2, audio: prepared)
        await settleAsyncWork()
        expectFalse(await transcriber.hasCall(.releaseTail, generation: 2))
        expectFalse(await transcriber.hasCall(.fullUtterance, generation: 2))
        XCTAssertTrue(outcomes.values.isEmpty)

        expectTrue(await transcriber.succeed("first words", segment: .incrementalChunk(index: 0), generation: 2))
        expectTrue(await waitForCall(.releaseTail, generation: 2, in: transcriber))
        expectEqual(await transcriber.sampleCounts(.releaseTail, generation: 2), [quietTail.count])
        expectTrue(await transcriber.succeed("quiet ending", segment: .releaseTail, generation: 2))
        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(outcomes.values, [.finalTranscript(generation: 2, text: "first words quiet ending")])
        expectFalse(await transcriber.hasCall(.fullUtterance, generation: 2))
    }

    func testPreparedReleaseFallsBackToFullAudioWhenFirstInFlightChunkFails() async {
        let transcriber = ControlledTranscriber()
        let outcomes = OutcomeRecorder()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: RecordingCleaner(mode: .unchanged),
                                    outcomes: outcomes)
        let silence = [Float](repeating: 0, count: speech.count)
        let prepared = DictationAudioPreparation(samples: silence + speech + speech + silence)
        pipeline.begin(generation: 3, context: context(cleanupEnabled: false))
        pipeline.processIncrementalChunk(generation: 3, samples: silence + speech, pauseSecondsAfterChunk: 0,
                                         sourceEndIndex: silence.count + speech.count)
        expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: 3, in: transcriber))
        pipeline.release(generation: 3, audio: prepared)
        expectTrue(await transcriber.fail(TestError.decodeFailed, segment: .incrementalChunk(index: 0), generation: 3))
        expectTrue(await waitForCall(.fullUtterance, generation: 3, in: transcriber))
        expectEqual(await transcriber.sampleCounts(.fullUtterance, generation: 3), [prepared.samples.count])
        expectFalse(await transcriber.hasCall(.releaseTail, generation: 3))
        expectTrue(await transcriber.succeed("", segment: .fullUtterance, generation: 3))
        expectTrue(await waitForOutcomes(1, in: outcomes))
        expectEqual(await transcriber.callCount(.fullUtterance, generation: 3), 1)
        XCTAssertEqual(outcomes.values, [.emptyTranscript(generation: 3)])
    }

    func testCancelledGenerationDropsLateCallbackAndDoesNotBlockNextOutcome() async {
        let transcriber = ControlledTranscriber()
        let cleaner = RecordingCleaner(mode: .unchanged)
        let outcomes = OutcomeRecorder()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: cleaner, outcomes: outcomes)

        pipeline.begin(generation: 20, context: context())
        pipeline.release(generation: 20, fullSamples: speech, tailSamples: speech)
        expectTrue(await waitForCall(.fullUtterance, generation: 20, in: transcriber))

        pipeline.cancel(generation: 20)
        pipeline.begin(generation: 21, context: context())
        pipeline.release(generation: 21, fullSamples: speech, tailSamples: speech)
        expectTrue(await waitForCall(.fullUtterance, generation: 21, in: transcriber))
        expectTrue(await transcriber.succeed(
            "current result",
            segment: .fullUtterance,
            generation: 21
        ))
        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(outcomes.values, [
            .finalTranscript(generation: 21, text: "current result")
        ])

        expectTrue(await transcriber.succeed(
            "stale result",
            segment: .fullUtterance,
            generation: 20
        ))
        await settleAsyncWork()
        XCTAssertEqual(outcomes.values, [
            .finalTranscript(generation: 21, text: "current result")
        ])
    }

    func testEmptyVoicedTailFallsBackToFullUtterance() async {
        let transcriber = ControlledTranscriber()
        let cleaner = RecordingCleaner(mode: .unchanged)
        let outcomes = OutcomeRecorder()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: cleaner, outcomes: outcomes)

        pipeline.begin(generation: 30, context: context())
        pipeline.processIncrementalChunk(
            generation: 30,
            samples: speech,
            pauseSecondsAfterChunk: 0.2
        )
        expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: 30, in: transcriber))
        pipeline.release(
            generation: 30,
            fullSamples: speech + speech,
            tailSamples: speech
        )
        expectTrue(await transcriber.succeed(
            "partial result",
            segment: .incrementalChunk(index: 0),
            generation: 30
        ))
        expectTrue(await waitForCall(.releaseTail, generation: 30, in: transcriber))
        expectTrue(await transcriber.succeed(
            "",
            segment: .releaseTail,
            generation: 30
        ))

        expectTrue(await waitForCall(.fullUtterance, generation: 30, in: transcriber))
        expectTrue(await transcriber.succeed(
            "complete recovered result",
            segment: .fullUtterance,
            generation: 30
        ))

        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(outcomes.values, [
            .finalTranscript(generation: 30, text: "complete recovered result")
        ])
    }

    func testFailedTailFallsBackToFullUtterance() async {
        let transcriber = ControlledTranscriber()
        let cleaner = RecordingCleaner(mode: .unchanged)
        let outcomes = OutcomeRecorder()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: cleaner, outcomes: outcomes)

        pipeline.begin(generation: 31, context: context())
        pipeline.processIncrementalChunk(
            generation: 31,
            samples: speech,
            pauseSecondsAfterChunk: 0.2
        )
        expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: 31, in: transcriber))
        pipeline.release(
            generation: 31,
            fullSamples: speech + speech,
            tailSamples: speech
        )
        expectTrue(await transcriber.succeed(
            "partial result",
            segment: .incrementalChunk(index: 0),
            generation: 31
        ))
        expectTrue(await waitForCall(.releaseTail, generation: 31, in: transcriber))
        expectTrue(await transcriber.fail(
            TestError.decodeFailed,
            segment: .releaseTail,
            generation: 31
        ))

        expectTrue(await waitForCall(.fullUtterance, generation: 31, in: transcriber))
        expectTrue(await transcriber.succeed(
            "complete recovered result",
            segment: .fullUtterance,
            generation: 31
        ))

        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(outcomes.values, [
            .finalTranscript(generation: 31, text: "complete recovered result")
        ])
    }

    func testSuccessfulUnchangedCleanupEmitsWithoutRetry() async {
        let transcriber = ControlledTranscriber()
        let cleaner = RecordingCleaner(mode: .unchanged)
        let outcomes = OutcomeRecorder()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: cleaner, outcomes: outcomes)

        pipeline.begin(generation: 40, context: context())
        pipeline.release(generation: 40, fullSamples: speech, tailSamples: speech)
        expectTrue(await waitForCall(.fullUtterance, generation: 40, in: transcriber))
        expectTrue(await transcriber.succeed(
            "Already clean.",
            segment: .fullUtterance,
            generation: 40
        ))

        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(outcomes.values, [
            .finalTranscript(generation: 40, text: "Already clean.")
        ])
        expectEqual(await cleaner.requestTexts(), ["Already clean."])
        expectEqual(await transcriber.callCount(.fullUtterance, generation: 40), 1)
    }

    func testCleanupReceivesWholeUtteranceSoCorrectionCanCrossChunkBoundary() async {
        let transcriber = ControlledTranscriber()
        let cleaner = RecordingCleaner(mode: .replaceWith("Meet on Wednesday at two."))
        let outcomes = OutcomeRecorder()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: cleaner, outcomes: outcomes)

        pipeline.begin(generation: 50, context: context())
        pipeline.processIncrementalChunk(
            generation: 50,
            samples: speech,
            pauseSecondsAfterChunk: 0.2
        )
        expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: 50, in: transcriber))
        pipeline.release(
            generation: 50,
            fullSamples: speech + speech,
            tailSamples: speech
        )
        expectTrue(await transcriber.succeed(
            "Meet on Tuesday at two,",
            segment: .incrementalChunk(index: 0),
            generation: 50
        ))
        expectTrue(await waitForCall(.releaseTail, generation: 50, in: transcriber))
        expectTrue(await transcriber.succeed(
            "actually Wednesday.",
            segment: .releaseTail,
            generation: 50
        ))

        expectTrue(await waitForOutcomes(1, in: outcomes))
        expectEqual(await cleaner.requestTexts(), [
            "Meet on Tuesday at two, actually Wednesday."
        ])
        XCTAssertEqual(outcomes.values, [
            .finalTranscript(generation: 50, text: "Meet on Wednesday at two.")
        ])
    }

    func testEmptyFullUtteranceRetriesOnceAndCleansOnlyRecoveredText() async {
        var requests: [DictationTranscriptionRequest] = []
        var cleanupTexts: [String] = []
        let outcomes = OutcomeRecorder()
        let pipeline = DictationSessionPipeline(
            transcribe: { request in
                requests.append(request)
                return requests.count == 1 ? "" : "Recovered speech."
            },
            cleanup: { request in
                cleanupTexts.append(request.text)
                return TranscriptCleanupResult(text: request.text, succeeded: true)
            },
            onOutcome: { outcomes.append($0) }
        )
        pipeline.begin(generation: 60, context: context())
        pipeline.release(generation: 60, fullSamples: speech)

        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(requests.map(\.segment), [.fullUtterance, .fullUtterance])
        XCTAssertTrue(requests.allSatisfy { $0.samples == speech })
        XCTAssertEqual(cleanupTexts, ["Recovered speech."])
        XCTAssertEqual(outcomes.values, [.finalTranscript(generation: 60, text: "Recovered speech.")])
    }

    func testRepeatedEmptyFullUtteranceStopsAndUnblocksLaterDictation() async {
        var calls = 0
        let outcomes = OutcomeRecorder()
        let pipeline = DictationSessionPipeline(
            transcribe: { request in
                if request.generation == 61 { calls += 1; return "" }
                return "Later speech."
            },
            cleanup: { request in
                XCTFail("Empty audio must not reach cleanup")
                return TranscriptCleanupResult(text: request.text, succeeded: true)
            },
            onOutcome: { outcomes.append($0) }
        )
        pipeline.begin(generation: 61, context: context(cleanupEnabled: false))
        pipeline.release(generation: 61, fullSamples: speech)
        pipeline.begin(generation: 62, context: context(cleanupEnabled: false))
        pipeline.release(generation: 62, fullSamples: speech)

        expectTrue(await waitForOutcomes(2, in: outcomes))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(outcomes.values, [
            .emptyTranscript(generation: 61),
            .finalTranscript(generation: 62, text: "Later speech.")
        ])
    }

    func testFailedAutomaticRetryEmitsFailureWithoutFurtherAttempts() async {
        var calls = 0
        let outcomes = OutcomeRecorder()
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in
                calls += 1
                if calls == 1 { return "" }
                throw TestError.decodeFailed
            },
            cleanup: { request in
                XCTFail("Failed recognition must not reach cleanup")
                return TranscriptCleanupResult(text: request.text, succeeded: true)
            },
            onOutcome: { outcomes.append($0) }
        )
        pipeline.begin(generation: 67, context: context())
        pipeline.release(generation: 67, fullSamples: speech)

        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(calls, 2)
        guard case .failed(generation: 67, message: _) = outcomes.values.first else {
            return XCTFail("Expected the retry error to remain recoverable")
        }
    }

    func testSilentFullUtteranceSkipsInferenceAndRetry() async {
        var calls = 0
        let outcomes = OutcomeRecorder()
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in calls += 1; return "" },
            cleanup: { request in
                XCTFail("Silent audio must not reach cleanup")
                return TranscriptCleanupResult(text: request.text, succeeded: true)
            },
            onOutcome: { outcomes.append($0) }
        )
        pipeline.begin(generation: 63, context: context())
        pipeline.release(generation: 63, fullSamples: [Float](repeating: 0, count: speech.count))

        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(outcomes.values, [.insufficientVoice(generation: 63)])
    }

    func testEmptyChunkRecoveryDoesNotRetryFullUtteranceAgain() async {
        var segments: [DictationTranscriptionSegment] = []
        let outcomes = OutcomeRecorder()
        let pipeline = DictationSessionPipeline(
            transcribe: { request in segments.append(request.segment); return "" },
            cleanup: { request in
                XCTFail("Empty results must not reach cleanup")
                return TranscriptCleanupResult(text: request.text, succeeded: true)
            },
            onOutcome: { outcomes.append($0) }
        )
        pipeline.begin(generation: 64, context: context())
        pipeline.processIncrementalChunk(generation: 64, samples: speech, pauseSecondsAfterChunk: 0)
        pipeline.release(generation: 64, fullSamples: speech + speech)

        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(segments, [.incrementalChunk(index: 0), .fullUtterance])
        XCTAssertEqual(outcomes.values, [.emptyTranscript(generation: 64)])
    }

    func testCancelledEmptyResultRetryCannotDeliverLateText() async {
        let transcriber = ControlledTranscriber()
        let cleaner = RecordingCleaner(mode: .unchanged)
        let outcomes = OutcomeRecorder()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: cleaner, outcomes: outcomes)
        pipeline.begin(generation: 65, context: context())
        pipeline.release(generation: 65, fullSamples: speech)
        expectTrue(await waitForCall(.fullUtterance, generation: 65, in: transcriber))
        expectTrue(await transcriber.succeed("", segment: .fullUtterance, generation: 65))
        let retryStarted = await waitForCall(.fullUtterance, generation: 65, in: transcriber, minimumCount: 2)
        XCTAssertTrue(retryStarted)
        guard retryStarted else { return }

        pipeline.cancel(generation: 65)
        pipeline.begin(generation: 66, context: context())
        pipeline.release(generation: 66, fullSamples: speech)
        expectTrue(await waitForCall(.fullUtterance, generation: 66, in: transcriber))
        expectTrue(await transcriber.succeed("Current speech.", segment: .fullUtterance, generation: 66))
        expectTrue(await waitForOutcomes(1, in: outcomes))
        expectTrue(await transcriber.succeed("Stale speech.", segment: .fullUtterance, generation: 65))
        await settleAsyncWork()
        XCTAssertEqual(outcomes.values, [.finalTranscript(generation: 66, text: "Current speech.")])
        expectEqual(await cleaner.requestTexts(), ["Current speech."])
    }

    func testPartialTranscriptFiresPerChunkAndAfterTailButNotAfterCancel() async {
        let transcriber = ControlledTranscriber()
        let cleaner = RecordingCleaner(mode: .replaceWith("Cleaned."))
        let outcomes = OutcomeRecorder()
        var partials: [PartialTranscript] = []
        let pipeline = makePipeline(transcriber: transcriber, cleaner: cleaner, outcomes: outcomes) {
            partials.append(PartialTranscript(generation: $0, text: $1))
        }

        pipeline.begin(generation: 70, context: context())
        pipeline.processIncrementalChunk(generation: 70, samples: speech, pauseSecondsAfterChunk: 0.4)
        expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: 70, in: transcriber))
        expectTrue(await transcriber.succeed("first", segment: .incrementalChunk(index: 0), generation: 70))
        await settleAsyncWork()
        pipeline.processIncrementalChunk(generation: 70, samples: speech, pauseSecondsAfterChunk: 0.4)
        expectTrue(await waitForCall(.incrementalChunk(index: 1), generation: 70, in: transcriber))
        expectTrue(await transcriber.succeed("second", segment: .incrementalChunk(index: 1), generation: 70))
        await settleAsyncWork()
        XCTAssertEqual(partials, [
            PartialTranscript(generation: 70, text: "first"),
            PartialTranscript(generation: 70, text: "first second"),
        ])

        pipeline.release(generation: 70, fullSamples: speech + speech + speech, tailSamples: speech)
        expectTrue(await waitForCall(.releaseTail, generation: 70, in: transcriber))
        expectTrue(await transcriber.succeed("third", segment: .releaseTail, generation: 70))
        expectTrue(await waitForOutcomes(1, in: outcomes))
        // The strip shows raw engine text. Cleanup output never reaches it.
        XCTAssertEqual(partials.last, PartialTranscript(generation: 70, text: "first second third"))
        XCTAssertEqual(partials.count, 3)

        pipeline.begin(generation: 71, context: context())
        pipeline.processIncrementalChunk(generation: 71, samples: speech, pauseSecondsAfterChunk: 0.4)
        expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: 71, in: transcriber))
        pipeline.cancel(generation: 71)
        expectTrue(await transcriber.succeed("stale", segment: .incrementalChunk(index: 0), generation: 71))
        await settleAsyncWork()
        XCTAssertFalse(partials.contains { $0.generation == 71 })
    }

    func testFiveSecondSnapshotIsTooShortForWhisperButAcceptedForParakeet() {
        // 2.5 s speech, 1 s pause, 1.5 s speech: a valid cut exists, so only
        // the cadence start decides whether the snapshot becomes a chunk.
        let rate = Int(AudioRecorder.sampleRate)
        let snapshot = [Float](repeating: 0.2, count: rate * 5 / 2)
            + [Float](repeating: 0, count: rate)
            + [Float](repeating: 0.2, count: rate * 3 / 2)
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "chunk" },
            cleanup: { request in .init(text: request.text, succeeded: true) },
            onOutcome: { _ in }
        )

        func events(for cadence: IncrementalCadence, generation: Int) -> [DictationTrace.Event] {
            let events = TraceEvents()
            let trace = DictationTrace(sink: { events.append($0) })
            let context = DictationSessionContext(
                cleanupEnabled: false, styleProfile: .general, corrections: [], snippets: [],
                incrementalCadence: cadence
            )
            pipeline.begin(generation: generation, context: context, trace: trace)
            pipeline.processIncrementalSnapshot(generation: generation, samples: snapshot)
            pipeline.cancel(generation: generation)
            return events.events
        }

        let whisper = events(for: .whisper, generation: 80)
        XCTAssertTrue(whisper.contains { $0.name == .incrementalSkipped && $0.status == .tooShort })
        XCTAssertFalse(whisper.contains { $0.name == .chunkSubmitted })

        let parakeet = events(for: .parakeet, generation: 81)
        XCTAssertFalse(parakeet.contains { $0.name == .incrementalSkipped })
        XCTAssertTrue(parakeet.contains { $0.name == .chunkSubmitted })
    }

    func testParakeetPreviewShowsUncommittedTextOnceAndSkipsUnchangedAudio() async {
        let transcriber = ControlledTranscriber()
        let outcomes = OutcomeRecorder()
        var partials: [PartialTranscript] = []
        let pipeline = makePipeline(transcriber: transcriber, cleaner: RecordingCleaner(mode: .unchanged),
                                    outcomes: outcomes) { partials.append(PartialTranscript(generation: $0, text: $1)) }

        pipeline.begin(generation: 90, context: parakeetContext())
        pipeline.processIncrementalSnapshot(generation: 90, samples: speech + speech)
        expectTrue(await waitForCall(.preview, generation: 90, in: transcriber))
        // One preview at a time, even when more audio arrives.
        pipeline.processIncrementalSnapshot(generation: 90, samples: speech + speech)
        pipeline.processIncrementalSnapshot(generation: 90, samples: speech + speech + speech)
        await settleAsyncWork()
        expectEqual(await transcriber.callCount(.preview, generation: 90), 1)

        expectTrue(await transcriber.succeed("hello there", segment: .preview, generation: 90))
        await settleAsyncWork()
        XCTAssertEqual(partials, [PartialTranscript(generation: 90, text: "hello there")])

        // The same audio again is not transcribed twice.
        pipeline.processIncrementalSnapshot(generation: 90, samples: speech + speech)
        await settleAsyncWork()
        expectEqual(await transcriber.callCount(.preview, generation: 90), 1)
        pipeline.cancel(generation: 90)
    }

    func testPreviewJoinsCommittedTextAndCoversOnlyUncommittedAudio() async {
        let transcriber = ControlledTranscriber()
        let outcomes = OutcomeRecorder()
        var partials: [PartialTranscript] = []
        let pipeline = makePipeline(transcriber: transcriber, cleaner: RecordingCleaner(mode: .unchanged),
                                    outcomes: outcomes) { partials.append(PartialTranscript(generation: $0, text: $1)) }

        pipeline.begin(generation: 91, context: parakeetContext())
        pipeline.processIncrementalChunk(generation: 91, samples: speech, pauseSecondsAfterChunk: 0.4,
                                         sourceEndIndex: speech.count)
        expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: 91, in: transcriber))
        expectTrue(await transcriber.succeed("first", segment: .incrementalChunk(index: 0), generation: 91))
        await settleAsyncWork()

        pipeline.processIncrementalSnapshot(generation: 91, samples: speech + speech + speech)
        expectTrue(await waitForCall(.preview, generation: 91, in: transcriber))
        expectEqual(await transcriber.sampleCounts(.preview, generation: 91), [speech.count * 2])
        expectTrue(await transcriber.succeed("second", segment: .preview, generation: 91))
        await settleAsyncWork()
        XCTAssertEqual(partials.map(\.text), ["first", "first second"])
        pipeline.cancel(generation: 91)
    }

    func testPreviewIsDroppedWhenAChunkCommitsPastItsStart() async {
        let transcriber = ControlledTranscriber()
        let outcomes = OutcomeRecorder()
        var partials: [PartialTranscript] = []
        let pipeline = makePipeline(transcriber: transcriber, cleaner: RecordingCleaner(mode: .unchanged),
                                    outcomes: outcomes) { partials.append(PartialTranscript(generation: $0, text: $1)) }
        let rate = Int(AudioRecorder.sampleRate)
        let snapshot = [Float](repeating: 0.2, count: rate * 5 / 2)
            + [Float](repeating: 0, count: rate)
            + [Float](repeating: 0.2, count: rate * 3 / 2)

        pipeline.begin(generation: 92, context: parakeetContext())
        pipeline.processIncrementalSnapshot(generation: 92, samples: Array(snapshot.prefix(rate * 2)))
        expectTrue(await waitForCall(.preview, generation: 92, in: transcriber))
        // A preview in flight does not hold back the chunk at the pause.
        pipeline.processIncrementalSnapshot(generation: 92, samples: snapshot)
        expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: 92, in: transcriber))
        expectTrue(await transcriber.succeed("committed", segment: .incrementalChunk(index: 0), generation: 92))
        await settleAsyncWork()
        expectTrue(await transcriber.succeed("stale preview", segment: .preview, generation: 92))
        await settleAsyncWork()
        // The preview covered audio that is now committed, so it is dropped.
        // No preview has reached the HUD, so the committed words still appear.
        XCTAssertEqual(partials.map(\.text), ["committed"])

        pipeline.processIncrementalSnapshot(generation: 92, samples: snapshot + speech)
        expectTrue(await waitForCall(.preview, generation: 92, in: transcriber, minimumCount: 2))
        expectTrue(await transcriber.succeed("fresh", segment: .preview, generation: 92))
        await settleAsyncWork()
        XCTAssertEqual(partials.map(\.text), ["committed", "committed fresh"])
        pipeline.cancel(generation: 92)
    }

    func testFailedPreviewLeavesTheDictationOnItsNormalPath() async {
        let transcriber = ControlledTranscriber()
        let outcomes = OutcomeRecorder()
        var partials: [PartialTranscript] = []
        let pipeline = makePipeline(transcriber: transcriber, cleaner: RecordingCleaner(mode: .unchanged),
                                    outcomes: outcomes) { partials.append(PartialTranscript(generation: $0, text: $1)) }

        // Parakeet always decodes the whole utterance on release, so the
        // chunk-and-tail path this protects is Whisper's.
        pipeline.begin(generation: 93, context: DictationSessionContext(
            cleanupEnabled: false, styleProfile: .general, corrections: [], snippets: [],
            incrementalCadence: .whisper
        ))
        pipeline.processIncrementalSnapshot(generation: 93, samples: speech + speech)
        expectTrue(await waitForCall(.preview, generation: 93, in: transcriber))
        expectTrue(await transcriber.fail(TestError.decodeFailed, segment: .preview, generation: 93))
        await settleAsyncWork()

        // A failed chunk would stop further chunks and force a full retry.
        pipeline.processIncrementalChunk(generation: 93, samples: speech, pauseSecondsAfterChunk: 0.4,
                                         sourceEndIndex: speech.count)
        expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: 93, in: transcriber))
        expectTrue(await transcriber.succeed("first", segment: .incrementalChunk(index: 0), generation: 93))
        pipeline.release(generation: 93, fullSamples: speech + speech)
        expectTrue(await waitForCall(.releaseTail, generation: 93, in: transcriber))
        expectTrue(await transcriber.succeed("second", segment: .releaseTail, generation: 93))
        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(outcomes.values, [.finalTranscript(generation: 93, text: "first second")])
        XCTAssertEqual(partials.map(\.text), ["first", "first second"])
        expectFalse(await transcriber.hasCall(.fullUtterance, generation: 93))
    }

    func testReleaseSubmitsFinalRecognitionAndDropsLatePreview() async {
        let transcriber = ControlledTranscriber()
        let outcomes = OutcomeRecorder()
        var partials: [PartialTranscript] = []
        let pipeline = makePipeline(transcriber: transcriber, cleaner: RecordingCleaner(mode: .unchanged),
                                    outcomes: outcomes) { partials.append(PartialTranscript(generation: $0, text: $1)) }

        pipeline.begin(generation: 94, context: parakeetContext())
        pipeline.processIncrementalSnapshot(generation: 94, samples: speech + speech)
        expectTrue(await waitForCall(.preview, generation: 94, in: transcriber))
        pipeline.release(generation: 94, fullSamples: speech + speech + speech)
        expectTrue(await waitForCall(.fullUtterance, generation: 94, in: transcriber))
        expectTrue(await transcriber.succeed("whole thing", segment: .fullUtterance, generation: 94))
        expectTrue(await waitForOutcomes(1, in: outcomes))
        expectTrue(await transcriber.succeed("late preview", segment: .preview, generation: 94))
        await settleAsyncWork()
        XCTAssertEqual(outcomes.values, [.finalTranscript(generation: 94, text: "whole thing")])
        XCTAssertEqual(partials, [])
    }

    func testParakeetReleaseDecodesWholeUtteranceInsteadOfJoiningChunks() async {
        let transcriber = ControlledTranscriber()
        let outcomes = OutcomeRecorder()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: RecordingCleaner(mode: .unchanged),
                                    outcomes: outcomes)

        pipeline.begin(generation: 95, context: parakeetContext())
        pipeline.processIncrementalChunk(generation: 95, samples: speech, pauseSecondsAfterChunk: 0.4)
        pipeline.processIncrementalChunk(generation: 95, samples: speech, pauseSecondsAfterChunk: 0.4)
        expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: 95, in: transcriber))
        pipeline.release(generation: 95, fullSamples: speech + speech + speech, tailSamples: speech)
        // The in-flight chunk finishes first. Its text and the queued chunk are not used.
        expectTrue(await transcriber.succeed("Ending early.", segment: .incrementalChunk(index: 0), generation: 95))
        expectTrue(await waitForCall(.fullUtterance, generation: 95, in: transcriber))
        expectEqual(await transcriber.sampleCounts(.fullUtterance, generation: 95), [speech.count * 3])
        expectTrue(await transcriber.succeed(
            "Ending early before I finish.", segment: .fullUtterance, generation: 95
        ))

        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(outcomes.values, [.finalTranscript(generation: 95, text: "Ending early before I finish.")])
        expectFalse(await transcriber.hasCall(.incrementalChunk(index: 1), generation: 95))
        expectFalse(await transcriber.hasCall(.releaseTail, generation: 95))
    }

    func testWhisperPreviewsContinuousSpeechEarlyAndRepeatedlyWithoutCommitting() async {
        let transcriber = ControlledTranscriber()
        let outcomes = OutcomeRecorder()
        var partials: [PartialTranscript] = []
        let pipeline = makePipeline(transcriber: transcriber, cleaner: RecordingCleaner(mode: .unchanged),
                                    outcomes: outcomes) { partials.append(PartialTranscript(generation: $0, text: $1)) }

        pipeline.begin(generation: 95, context: context())
        // Capture can be a little behind the first timer tick.
        pipeline.processIncrementalSnapshot(generation: 95, samples: Array(speech.dropLast(400)))
        await settleAsyncWork()
        expectEqual(await transcriber.callCount(.preview, generation: 95), 0)
        pipeline.processIncrementalSnapshot(generation: 95, samples: speech + speech)
        expectTrue(await waitForCall(.preview, generation: 95, in: transcriber))
        for seconds in 3...10 {
            pipeline.processIncrementalSnapshot(
                generation: 95, samples: Array(repeating: 0.2, count: speech.count * seconds)
            )
        }
        await settleAsyncWork()
        expectEqual(await transcriber.callCount(.preview, generation: 95), 1)
        expectTrue(await transcriber.succeed("early words", segment: .preview, generation: 95))
        await settleAsyncWork()
        let latestAudio = [Float](repeating: 0.2, count: speech.count * 11)
        pipeline.processIncrementalSnapshot(generation: 95, samples: latestAudio)
        expectTrue(await waitForCall(.preview, generation: 95, in: transcriber, minimumCount: 2))
        expectTrue(await transcriber.succeed("early words keep coming", segment: .preview, generation: 95))
        await settleAsyncWork()
        XCTAssertEqual(partials.map(\.text), ["early words", "early words keep coming"])
        XCTAssertEqual(pipeline.incrementalSampleEnd(generation: 95), 0)

        pipeline.release(generation: 95, fullSamples: latestAudio)
        expectTrue(await waitForCall(.fullUtterance, generation: 95, in: transcriber))
        expectEqual(await transcriber.sampleCounts(.fullUtterance, generation: 95), [latestAudio.count])
        expectTrue(await transcriber.succeed("final recognition", segment: .fullUtterance, generation: 95))
        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(outcomes.values, [.finalTranscript(generation: 95, text: "final recognition")])
    }

    func testLongContinuousPreviewIsBoundedWhileFinalRecognitionKeepsAllAudio() async {
        let transcriber = ControlledTranscriber()
        let outcomes = OutcomeRecorder()
        var partials: [PartialTranscript] = []
        let pipeline = makePipeline(transcriber: transcriber, cleaner: RecordingCleaner(mode: .unchanged),
                                    outcomes: outcomes) { partials.append(PartialTranscript(generation: $0, text: $1)) }
        let samples = [Float](repeating: 0.2, count: speech.count * 45)
        pipeline.begin(generation: 96, context: context())
        pipeline.processIncrementalSnapshot(generation: 96, samples: samples)
        expectTrue(await waitForCall(.preview, generation: 96, in: transcriber))
        let counts = await transcriber.sampleCounts(.preview, generation: 96)
        XCTAssertEqual(counts.count, 1)
        XCTAssertLessThanOrEqual(counts.first ?? Int.max, speech.count * 15)
        expectTrue(await transcriber.succeed("recent words", segment: .preview, generation: 96))
        await settleAsyncWork()
        XCTAssertEqual(partials.map(\.text), ["recent words"])

        pipeline.release(generation: 96, fullSamples: samples)
        expectTrue(await waitForCall(.fullUtterance, generation: 96, in: transcriber))
        expectEqual(await transcriber.sampleCounts(.fullUtterance, generation: 96), [samples.count])
        expectTrue(await transcriber.succeed("all words", segment: .fullUtterance, generation: 96))
        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(outcomes.values, [.finalTranscript(generation: 96, text: "all words")])
    }

    func testBoundedPreviewPreservesDisplayedWordsWhenItsWindowAdvances() async {
        for hasCommittedPrefix in [false, true] {
            let generation = hasCommittedPrefix ? 102 : 101
            let transcriber = ControlledTranscriber()
            let outcomes = OutcomeRecorder()
            var partials: [PartialTranscript] = []
            let pipeline = makePipeline(transcriber: transcriber, cleaner: RecordingCleaner(mode: .unchanged),
                                        outcomes: outcomes) { partials.append(PartialTranscript(generation: $0, text: $1)) }
            pipeline.begin(generation: generation, context: context())
            if hasCommittedPrefix {
                pipeline.processIncrementalChunk(generation: generation, samples: speech,
                                                 pauseSecondsAfterChunk: 0, sourceEndIndex: speech.count)
                expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: generation, in: transcriber))
                expectTrue(await transcriber.succeed("committed", segment: .incrementalChunk(index: 0), generation: generation))
                await settleAsyncWork()
            }
            let seconds = hasCommittedPrefix ? 16 : 15
            let prefix = hasCommittedPrefix ? "committed " : ""
            for (index, text) in ["earlier words", "new words", "new words again"].enumerated() {
                let samples = [Float](repeating: 0.2, count: speech.count * (seconds + index))
                let range = pipeline.incrementalSnapshotRange(generation: generation)?(samples.count) ?? 0..<0
                pipeline.processIncrementalSnapshot(generation: generation, samples: Array(samples[range]),
                                                    sampleOffset: range.lowerBound)
                expectTrue(await waitForCall(.preview, generation: generation, in: transcriber, minimumCount: index + 1))
                expectTrue(await transcriber.succeed(text, segment: .preview, generation: generation))
                await settleAsyncWork()
            }
            XCTAssertEqual(partials.suffix(3).map(\.text), [
                prefix + "earlier words", prefix + "earlier words new words",
                prefix + "earlier words new words again"
            ])
            expectEqual(await transcriber.sampleCounts(.preview, generation: generation),
                        [15 * speech.count, speech.count, 2 * speech.count])
            XCTAssertTrue(outcomes.values.isEmpty)
            pipeline.cancel(generation: generation)
        }
    }

    func testChunkDoesNotReplacePreviewThatAlreadyCoversNewerWords() async {
        let transcriber = ControlledTranscriber()
        let outcomes = OutcomeRecorder()
        var partials: [PartialTranscript] = []
        let pipeline = makePipeline(transcriber: transcriber, cleaner: RecordingCleaner(mode: .unchanged),
                                    outcomes: outcomes) { partials.append(PartialTranscript(generation: $0, text: $1)) }
        pipeline.begin(generation: 99, context: context())
        pipeline.processIncrementalSnapshot(generation: 99, samples: speech + speech + speech)
        expectTrue(await waitForCall(.preview, generation: 99, in: transcriber))
        expectTrue(await transcriber.succeed("first newer words", segment: .preview, generation: 99))
        await settleAsyncWork()
        pipeline.processIncrementalChunk(generation: 99, samples: speech, pauseSecondsAfterChunk: 0,
                                         sourceEndIndex: speech.count)
        expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: 99, in: transcriber))
        expectTrue(await transcriber.succeed("first", segment: .incrementalChunk(index: 0), generation: 99))
        await settleAsyncWork()
        XCTAssertEqual(partials.map(\.text), ["first newer words"])
        pipeline.cancel(generation: 99)
    }

    func testCancelledWhisperPreviewCannotUpdateTheNextDictation() async {
        let transcriber = ControlledTranscriber()
        let outcomes = OutcomeRecorder()
        var partials: [PartialTranscript] = []
        let pipeline = makePipeline(transcriber: transcriber, cleaner: RecordingCleaner(mode: .unchanged),
                                    outcomes: outcomes) { partials.append(PartialTranscript(generation: $0, text: $1)) }
        pipeline.begin(generation: 97, context: context())
        pipeline.processIncrementalSnapshot(generation: 97, samples: speech + speech)
        expectTrue(await waitForCall(.preview, generation: 97, in: transcriber))
        pipeline.cancel(generation: 97, interruptInference: false)
        pipeline.begin(generation: 98, context: context())
        expectTrue(await transcriber.succeed("stale", segment: .preview, generation: 97))
        await settleAsyncWork()
        XCTAssertTrue(partials.isEmpty)
        XCTAssertTrue(outcomes.values.isEmpty)
        pipeline.cancel(generation: 98)
    }

    private func parakeetContext() -> DictationSessionContext {
        DictationSessionContext(
            cleanupEnabled: false, styleProfile: .general, corrections: [], snippets: [],
            incrementalCadence: .parakeet
        )
    }

    private func makePipeline(
        transcriber: ControlledTranscriber,
        cleaner: RecordingCleaner,
        outcomes: OutcomeRecorder,
        onPartialTranscript: ((Int, String) -> Void)? = nil
    ) -> DictationSessionPipeline {
        DictationSessionPipeline(
            transcribe: { request in
                try await transcriber.transcribe(request)
            },
            cleanup: { request in
                await cleaner.clean(request)
            },
            onOutcome: { outcome in
                outcomes.append(outcome)
            },
            onPartialTranscript: onPartialTranscript
        )
    }

    private func context(cleanupEnabled: Bool = true) -> DictationSessionContext {
        DictationSessionContext(
            cleanupEnabled: cleanupEnabled,
            styleProfile: .general,
            corrections: [],
            snippets: []
        )
    }

    private func waitForCall(
        _ segment: DictationTranscriptionSegment,
        generation: Int,
        in transcriber: ControlledTranscriber,
        minimumCount: Int = 1
    ) async -> Bool {
        for _ in 0..<10_000 {
            if await transcriber.callCount(segment, generation: generation) >= minimumCount { return true }
            await Task.yield()
        }
        return false
    }

    private func waitForOutcomes(_ count: Int, in recorder: OutcomeRecorder) async -> Bool {
        for _ in 0..<10_000 {
            if recorder.values.count == count { return true }
            await Task.yield()
        }
        return false
    }

    private func settleAsyncWork() async {
        for _ in 0..<100 { await Task.yield() }
    }

    private func expectTrue(
        _ value: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(value, file: file, line: line)
    }

    private func expectFalse(
        _ value: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(value, file: file, line: line)
    }

    private func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

private enum TestError: Error {
    case decodeFailed
}

private struct PartialTranscript: Equatable {
    let generation: Int
    let text: String
}

private actor ControlledTranscriber {
    private struct PendingCall {
        let request: DictationTranscriptionRequest
        let continuation: CheckedContinuation<String, Error>
    }

    private var calls: [DictationTranscriptionRequest] = []
    private var pending: [PendingCall] = []

    func transcribe(_ request: DictationTranscriptionRequest) async throws -> String {
        calls.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(PendingCall(request: request, continuation: continuation))
        }
    }

    func hasCall(_ segment: DictationTranscriptionSegment, generation: Int) -> Bool {
        calls.contains { $0.generation == generation && $0.segment == segment }
    }

    func sampleCounts(_ segment: DictationTranscriptionSegment, generation: Int) -> [Int] {
        calls.filter { $0.generation == generation && $0.segment == segment }.map(\.samples.count)
    }

    func samples(_ segment: DictationTranscriptionSegment, generation: Int) -> [[Float]] {
        calls.filter { $0.generation == generation && $0.segment == segment }.map(\.samples)
    }

    func callCount(_ segment: DictationTranscriptionSegment, generation: Int) -> Int {
        calls.filter { $0.generation == generation && $0.segment == segment }.count
    }

    func succeed(
        _ text: String,
        segment: DictationTranscriptionSegment,
        generation: Int
    ) -> Bool {
        resolve(segment: segment, generation: generation, with: .success(text))
    }

    func fail(
        _ error: Error,
        segment: DictationTranscriptionSegment,
        generation: Int
    ) -> Bool {
        resolve(segment: segment, generation: generation, with: .failure(error))
    }

    private func resolve(
        segment: DictationTranscriptionSegment,
        generation: Int,
        with result: Result<String, Error>
    ) -> Bool {
        guard let index = pending.firstIndex(where: {
            $0.request.generation == generation && $0.request.segment == segment
        }) else { return false }
        let call = pending.remove(at: index)
        call.continuation.resume(with: result)
        return true
    }
}

private actor RecordingCleaner {
    enum Mode {
        case unchanged
        case replaceWith(String)
    }

    private let mode: Mode
    private var requests: [DictationCleanupRequest] = []

    init(mode: Mode) {
        self.mode = mode
    }

    func clean(_ request: DictationCleanupRequest) -> TranscriptCleanupResult {
        requests.append(request)
        switch mode {
        case .unchanged:
            return TranscriptCleanupResult(text: request.text, succeeded: true)
        case .replaceWith(let text):
            return TranscriptCleanupResult(text: text, succeeded: true)
        }
    }

    func requestTexts() -> [String] {
        requests.map(\.text)
    }
}

@MainActor
private final class OutcomeRecorder {
    private(set) var values: [DictationSessionOutcome] = []

    func append(_ outcome: DictationSessionOutcome) {
        values.append(outcome)
    }
}
