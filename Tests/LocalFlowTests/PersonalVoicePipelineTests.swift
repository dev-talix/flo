import AVFoundation
import XCTest
@testable import LocalFlow

@MainActor
final class PersonalVoicePipelineTests: XCTestCase {
    func testDeliveryRetainsOriginalFallbackOnceAcrossManualRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalVoiceStore(folder: root)
        let context = DictationSessionContext(cleanupEnabled: false, styleProfile: .general, corrections: [], snippets: [])
        let recording = store.begin(.init(traceID: UUID(), context: context, whisperModel: "test",
                                          microphone: "synthetic-input", vocabulary: ""))
        let silence = [Float](repeating: 0, count: 16_000)
        let original = silence + [Float](repeating: 0.005, count: 16_000) + silence
        let prepared = DictationAudioPreparation(samples: original)
        let failed = expectation(description: "failed release retained")
        let retried = expectation(description: "manual retry completed")
        var requests = 0
        let delivery = DictationDelivery(transcribe: { request in
            XCTAssertEqual(request.samples, prepared.samples)
            XCTAssertTrue(request.lowEnergy)
            requests += 1
            if requests == 1 { throw CocoaError(.fileReadUnknown) }
            return "retried words"
        }, cleanup: { .init(text: $0.text, succeeded: true) }, inject: { _, completion in completion() },
        recordTranscript: { _ in }, onOutcome: { outcome, _ in
            switch outcome {
            case .failed: failed.fulfill()
            case .finalTranscript: retried.fulfill()
            default: XCTFail("Unexpected outcome")
            }
        }, onCancelled: { _ in XCTFail("Unexpected cancellation") }, onCommandCancelled: { _ in },
        onProcessingCountChange: { _ in }, injectionInterval: 0)
        let generation = delivery.begin(.init(context: context, personalVoice: recording))
        delivery.release(generation: generation, samples: original)
        await fulfillment(of: [failed], timeout: 2)
        delivery.retryFailedDictations { .init(context: context, personalVoice: recording) }
        await fulfillment(of: [retried], timeout: 2)

        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.clips.count, 1)
        let clip = try XCTUnwrap(snapshot.clips.first)
        XCTAssertEqual(clip.sampleRate, AudioRecorder.sampleRate)
        XCTAssertTrue(clip.failureReason?.contains("status: failed") == true)
        XCTAssertTrue(clip.rawTranscript.isEmpty, "Manual retry must not update the personal clip")
        XCTAssertNil(clip.finalTranscript)
        let file = try AVAudioFile(forReading: store.audioURL(for: clip.id))
        XCTAssertEqual(file.length, AVAudioFramePosition(original.count))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(file.length)))
        var retained: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            retained.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        XCTAssertEqual(retained, original)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(delivery.retryCount, 0)
    }

    func testNativeOriginalAndRawTranscriptSurviveWithDiagnosticsDisabled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalVoiceStore(folder: root)
        let context = DictationSessionContext(cleanupEnabled: true, styleProfile: .general, corrections: [], snippets: [])
        let recording = store.begin(.init(traceID: UUID(), context: context, whisperModel: "test", microphone: "test", vocabulary: ""))
        let completed = expectation(description: "dictation delivered")
        let pipeline = DictationSessionPipeline(transcribe: { _ in "Um, here are the words." },
            cleanup: { _ in .init(text: "Here are the words.", succeeded: true) },
            onOutcome: { outcome in
                XCTAssertEqual(outcome, .finalTranscript(generation: 1, text: "Here are the words."))
                completed.fulfill()
            })
        pipeline.begin(generation: 1, context: context, trace: nil, diagnostics: nil, personalVoice: recording)
        let native = NativeAudioRecording(samples: Array(repeating: 0.25, count: 48_000), sampleRate: 48_000, isComplete: true)
        let speech = Array(repeating: Float(0.2), count: 16_000)
        pipeline.recordCapturedAudio(generation: 1, samples: speech, nativeAudio: native)
        pipeline.release(generation: 1, fullSamples: speech)
        await fulfillment(of: [completed], timeout: 5)
        let snapshot = try await store.snapshot()
        let clip = try XCTUnwrap(snapshot.clips.first)
        XCTAssertEqual(clip.sampleRate, 48_000)
        XCTAssertEqual(clip.rawTranscript, "Um, here are the words.")
        XCTAssertEqual(clip.finalTranscript, "Here are the words.")
        XCTAssertFalse(clip.approved)
        let audio = try AVAudioFile(forReading: store.audioURL(for: clip.id))
        XCTAssertEqual(audio.length, 48_000)
        XCTAssertEqual(snapshot.clips.count, 1)
    }
}
