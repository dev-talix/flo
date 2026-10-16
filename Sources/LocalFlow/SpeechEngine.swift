import Foundation

enum TranscriptionPurpose: Sendable {
    case authoritative
    case preview(TranscriptionLifetime)

    var preview: TranscriptionLifetime? {
        if case .preview(let lifetime) = self { return lifetime }
        return nil
    }
}

/// Signals that a request is no longer wanted across the pipeline and engine actors.
/// Each request registers one observer at a time, first at the gate, then during inference.
final class TranscriptionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var obsolete = false
    private var onInvalidation: (@Sendable () -> Void)?

    func invalidate() {
        let notify = lock.withLock {
            obsolete = true
            let notify = onInvalidation
            onInvalidation = nil
            return notify
        }
        notify?()
    }

    var isInvalidated: Bool { lock.withLock { obsolete } }

    func checkCurrent() throws {
        if isInvalidated { throw CancellationError() }
    }

    func observeInvalidation(_ notify: @escaping @Sendable () -> Void) {
        let alreadyObsolete = lock.withLock {
            if obsolete { return true }
            onInvalidation = notify
            return false
        }
        if alreadyObsolete { notify() }
    }

    func stopObserving() {
        lock.withLock { onInvalidation = nil }
    }
}

/// One timed span of recognized text. Times are seconds from the start of
/// the samples handed to the engine.
struct EngineSegment: Equatable, Sendable {
    let text: String
    let start: Float
    let end: Float
}

struct EngineTranscription: Sendable {
    let segments: [EngineSegment]
    /// The engine's own joined hypothesis, for `rawCharacters` and the
    /// `whisperRaw` diagnostic stage.
    let rawText: String
    /// Whisper temperature fallbacks; 0 for engines without them.
    let decodingFallbacks: Int
    /// Whisper returns one result per VAD window; other engines return 1.
    let resultCount: Int
}

/// A loaded speech recognition model. `Transcriber` owns serialization,
/// quarantine and post-processing; an engine only turns 16 kHz mono samples
/// into timed text.
protocol SpeechEngine: AnyObject, Sendable {
    func transcribe(samples: [Float], lowEnergy: Bool) async throws -> EngineTranscription
    func transcribe(samples: [Float], lowEnergy: Bool, purpose: TranscriptionPurpose) async throws -> EngineTranscription
    /// Names and jargon to bias decoding toward. Engines without a decoder
    /// prompt ignore it.
    func setVocabulary(_ terms: String) async
    /// Engine-specific fields for the `inferenceStarted` trace event.
    func inferenceStartFields(lowEnergy: Bool) async -> [DictationTrace.Field: Double]
    func inferenceStartFields(lowEnergy: Bool, purpose: TranscriptionPurpose) async -> [DictationTrace.Field: Double]
}

extension SpeechEngine {
    // Engines without a cheaper preview decoder keep their existing behavior.
    func transcribe(samples: [Float], lowEnergy: Bool, purpose: TranscriptionPurpose) async throws -> EngineTranscription {
        try await transcribe(samples: samples, lowEnergy: lowEnergy)
    }

    func inferenceStartFields(lowEnergy: Bool) async -> [DictationTrace.Field: Double] { [:] }
    func inferenceStartFields(lowEnergy: Bool, purpose: TranscriptionPurpose) async -> [DictationTrace.Field: Double] {
        await inferenceStartFields(lowEnergy: lowEnergy)
    }
}
