import Foundation

/// Safe chunks keep their engine-specific cadence and pause boundaries.
/// HUD previews start after 1 s and refresh independently of those boundaries.
///
/// Previews transcribe the uncommitted audio for the HUD only and are never
/// committed. Busy previews skip ticks rather than queue more inference.
///
/// Parakeet has no text prompt, so it ends every chunk with a period and
/// capitalizes the next one. Its chunks feed only the HUD, and release decodes
/// the whole utterance once (about 150 ms for 50 s of audio).
struct IncrementalCadence: Equatable {
    let startSeconds: TimeInterval
    let tickSeconds: TimeInterval
    var previewTickSeconds: TimeInterval? = nil
    var previewStartSeconds: TimeInterval = 0
    var decodesWholeUtteranceOnRelease = false

    static let whisper = IncrementalCadence(
        startSeconds: 8, tickSeconds: 4, previewTickSeconds: 1, previewStartSeconds: 1
    )
    static let parakeet = IncrementalCadence(
        startSeconds: 4, tickSeconds: 2, previewTickSeconds: 1, previewStartSeconds: 1,
        decodesWholeUtteranceOnRelease: true
    )

    /// When capture takes its first snapshot, and how often after that.
    var firstSnapshotSeconds: TimeInterval {
        previewTickSeconds == nil ? startSeconds : min(previewStartSeconds, startSeconds)
    }

    var snapshotSeconds: TimeInterval {
        previewTickSeconds.map { min($0, tickSeconds) } ?? tickSeconds
    }

    static func forModel(_ id: String, liveTranscript: Bool = true) -> IncrementalCadence {
        var cadence: IncrementalCadence = switch TranscriptionModel.engine(forID: id) {
        case .whisper: .whisper
        case .parakeet: .parakeet
        }
        if !liveTranscript { cadence.previewTickSeconds = nil }
        return cadence
    }
}

struct DictationSessionContext {
    let cleanupEnabled: Bool
    let styleProfile: AppStyleProfile
    let corrections: [(wrong: String, right: String)]
    let snippets: [(trigger: String, expansion: String)]
    let literalFormatting: Bool
    let ollamaModel: String
    let incrementalCadence: IncrementalCadence

    init(
        cleanupEnabled: Bool,
        styleProfile: AppStyleProfile,
        corrections: [(wrong: String, right: String)],
        snippets: [(trigger: String, expansion: String)],
        literalFormatting: Bool = false,
        ollamaModel: String = "",
        incrementalCadence: IncrementalCadence = .whisper
    ) {
        self.cleanupEnabled = cleanupEnabled
        self.styleProfile = styleProfile
        self.corrections = corrections
        self.snippets = snippets
        self.literalFormatting = literalFormatting
        self.ollamaModel = ollamaModel
        self.incrementalCadence = incrementalCadence
    }
}

enum DictationTranscriptionSegment: Equatable, Codable, Sendable {
    case incrementalChunk(index: Int)
    case releaseTail
    case fullUtterance
    case preview
}

/// Shared admission and decoder preparation for live dictation, commands, and replay.
struct DictationAudioPreparation {
    let originalSamples: [Float]
    let samples: [Float]
    let voicedSeconds: Double
    let voicedDBFS: Float
    let rawVoicedSeconds: Double

    init(samples: [Float]) {
        originalSamples = samples
        rawVoicedSeconds = AudioRecorder.voicedMetrics(of: samples).voicedSeconds
        self.samples = AudioRecorder.trimmingSilence(samples)
        let voice = AudioRecorder.voicedMetrics(of: self.samples)
        voicedSeconds = voice.voicedSeconds
        voicedDBFS = voice.voicedDBFS
    }

    var isAdmitted: Bool { voicedSeconds >= 0.3 }
    // Recovery historically uses the original analysis windows. Trimming can
    // shift their alignment, so admission and recovery keep distinct metrics.
    var canRetryEmptyResult: Bool { rawVoicedSeconds >= 0.3 }
    var lowEnergy: Bool { voicedDBFS < -40 }
    var duration: TimeInterval { Double(samples.count) / AudioRecorder.sampleRate }
}

struct DictationTranscriptionRequest {
    let generation: Int
    let segment: DictationTranscriptionSegment
    let samples: [Float]
    let lowEnergy: Bool
    var purpose: TranscriptionPurpose = .authoritative
    var lifetime: TranscriptionLifetime? = nil
}

struct DictationCleanupRequest {
    let generation: Int
    let text: String
    let context: DictationSessionContext
}

enum DictationSessionOutcome: Equatable {
    case finalTranscript(generation: Int, text: String)
    case insufficientVoice(generation: Int)
    case emptyTranscript(generation: Int)
    case failed(generation: Int, message: String)
}

/// Owns the asynchronous lifetime of dictations after recording begins.
/// AppKit supplies audio snapshots and handles the eventual paste, while this
/// coordinator keeps chunking, fallback, cleanup, cancellation, and delivery
/// order consistent across overlapping generations.
@MainActor
final class DictationSessionPipeline {
    typealias Transcribe = (DictationTranscriptionRequest) async throws -> String
    typealias Cleanup = (DictationCleanupRequest) async -> TranscriptCleanupResult
    typealias OutcomeHandler = (DictationSessionOutcome) -> Void

    private static let previewWindowSamples = Int(15 * AudioRecorder.sampleRate)

    private struct IncrementalChunk {
        let index: Int
        let audio: DictationAudioPreparation
        let pauseSecondsBefore: Double
        let sourceEndIndex: Int?
    }

    private struct ReleaseAudio {
        let full: DictationAudioPreparation
        let tail: DictationAudioPreparation
    }

    private struct DisplayedPreview {
        let range: Range<Int>
        let prefix: String
        let text: String
    }

    private final class Session {
        let generation: Int
        let context: DictationSessionContext
        let trace: DictationTrace?
        let diagnostics: DictationDiagnosticStore.Recording?
        let personalVoice: PersonalVoiceStore.Recording?
        var capturedAudioSaved = false
        var pendingChunks: [IncrementalChunk] = []
        var activeTask: Task<Void, Never>?
        /// Escape gives active inference a bounded grace period at Transcriber.
        /// Explicit interruption and the release deadline cancel it immediately.
        var previewTask: Task<Void, Never>?
        var previewLifetime: TranscriptionLifetime?
        var inferenceLifetimes: [UUID: TranscriptionLifetime] = [:]
        var lastPreviewRange: Range<Int>?
        var displayedPreview: DisplayedPreview?
        var nextChunkSnapshotSamples = 0
        /// Text cleanup never touches the speech engine, so it is always
        /// safe to cancel.
        var activeTaskIsCleanup = false
        var releaseAudio: ReleaseAudio?
        var committedText = ""
        var chunkCount = 0
        var nextChunkIndex = 0
        var nextPauseSeconds = 0.0
        var incrementalSampleEnd = 0
        var completedSampleEnd = 0
        var incrementalFailed = false
        var cancelled = false
        var releaseTimeout: DispatchWorkItem?
        var cleanupDeadline: DispatchWorkItem?
        var cleanupFallbackText: String?

        var incrementalAnalysisStart: Int {
            // Keep the previous cut's quiet run as context if a pause continues
            // across snapshots. Round down to the original 20 ms frame grid.
            let pauseSamples = Int(ceil(nextPauseSeconds * AudioRecorder.sampleRate))
            return AudioRecorder.incrementalAnalysisStart(after: max(0, incrementalSampleEnd - pauseSamples))
        }

        init(generation: Int, context: DictationSessionContext, trace: DictationTrace?, diagnostics: DictationDiagnosticStore.Recording?, personalVoice: PersonalVoiceStore.Recording?) {
            self.generation = generation
            self.context = context
            self.trace = trace
            self.diagnostics = diagnostics
            self.personalVoice = personalVoice
        }
    }

    private let transcribe: Transcribe
    private let cleanup: Cleanup
    private let onOutcome: OutcomeHandler
    private let onPartialTranscript: ((Int, String) -> Void)?
    private let stalledGenerationTimeout: TimeInterval
    private let cleanupTimeout: TimeInterval
    private var sessions: [Int: Session] = [:]
    private var generationOrder: [Int] = []
    private var completed: [Int: (outcome: DictationSessionOutcome, trace: DictationTrace?)] = [:]
    private var cancelled: Set<Int> = []

    init(
        transcribe: @escaping Transcribe,
        cleanup: @escaping Cleanup,
        onOutcome: @escaping OutcomeHandler,
        onPartialTranscript: ((Int, String) -> Void)? = nil,
        stalledGenerationTimeout: TimeInterval = 90,
        cleanupTimeout: TimeInterval = 3
    ) {
        self.transcribe = transcribe
        self.cleanup = cleanup
        self.onOutcome = onOutcome
        self.onPartialTranscript = onPartialTranscript
        self.stalledGenerationTimeout = stalledGenerationTimeout
        self.cleanupTimeout = cleanupTimeout
    }

    func begin(generation: Int, context: DictationSessionContext, trace: DictationTrace? = DictationTrace.current,
               diagnostics: DictationDiagnosticStore.Recording? = nil, personalVoice: PersonalVoiceStore.Recording? = nil) {
        if sessions[generation] != nil || generationOrder.contains(generation) {
            cancel(generation: generation)
        }
        sessions[generation] = Session(generation: generation, context: context, trace: trace, diagnostics: diagnostics, personalVoice: personalVoice)
        trace?.retain(in: diagnostics)
        trace?.record(.sessionStarted, fields: [.cleanupEnabled: context.cleanupEnabled ? 1 : 0], model: context.ollamaModel)
        generationOrder.append(generation)
    }

    func canAcceptIncrementalChunk(generation: Int) -> Bool {
        guard let session = sessions[generation] else { return false }
        return !session.cancelled
            && !session.incrementalFailed
            && session.releaseAudio == nil
            && session.activeTask == nil
            && session.pendingChunks.isEmpty
    }

    func incrementalSampleEnd(generation: Int) -> Int? {
        sessions[generation]?.incrementalSampleEnd
    }

    /// Capture and replay select from the actual drained count, without sharing
    /// session state with the recorder queues. Chunk ticks need all unsubmitted
    /// audio; other ticks need only the existing 15-second preview window.
    func incrementalSnapshotRange(generation: Int) -> ((Int) -> Range<Int>)? {
        guard let session = sessions[generation] else { return nil }
        let chunkReady = canAcceptIncrementalChunk(generation: generation)
        guard chunkReady || canStartPreview(session) else { return nil }
        let chunkStart = session.incrementalAnalysisStart
        let chunkThreshold = max(session.nextChunkSnapshotSamples,
                                 Int(session.context.incrementalCadence.startSeconds * AudioRecorder.sampleRate))
        let completedEnd = session.completedSampleEnd
        return { count in
            let start = chunkReady && count >= chunkThreshold
                ? chunkStart : max(completedEnd, count - Self.previewWindowSamples)
            return min(start, count)..<count
        }
    }

    /// Shared by live capture and file replay so benchmarks use the same
    /// thresholds and chunk acceptance rules as dictation.
    func processIncrementalSnapshot(generation: Int, samples: [Float], sampleOffset: Int = 0) {
        guard let session = sessions[generation] else { return }
        // Previews bring snapshots faster than the chunk tick, but chunk
        // attempts keep the chunk tick.
        if sampleOffset + samples.count >= session.nextChunkSnapshotSamples {
            processChunkSnapshot(session, samples: samples, sampleOffset: sampleOffset)
        }
        startPreviewIfNeeded(session, samples: samples, sampleOffset: sampleOffset)
    }

    private func processChunkSnapshot(_ session: Session, samples: [Float], sampleOffset: Int) {
        let generation = session.generation
        let cadence = session.context.incrementalCadence
        let trace = session.trace
        let end = sampleOffset + samples.count
        trace?.record(.incrementalAttempt, fields: [.samples: Double(end)])
        guard end >= Int(cadence.startSeconds * AudioRecorder.sampleRate) else {
            trace?.record(.incrementalSkipped, status: .tooShort)
            return
        }
        let start = session.incrementalSampleEnd
        // A delayed preview-only snapshot can lack the beginning of the next
        // chunk. It must never submit a truncated chunk or move its cadence.
        guard sampleOffset <= session.incrementalAnalysisStart,
              start <= end else { return }
        // Half a snapshot interval of slack absorbs timer and audio buffer jitter.
        session.nextChunkSnapshotSamples = end
            + Int((cadence.tickSeconds - cadence.snapshotSeconds / 2) * AudioRecorder.sampleRate)
        guard canAcceptIncrementalChunk(generation: generation) else {
            trace?.record(.incrementalSkipped, status: .busy)
            return
        }
        guard let cut = AudioRecorder.incrementalCutPoint(in: samples, after: start - sampleOffset) else {
            trace?.record(.incrementalSkipped, status: .noBoundary)
            return
        }
        let chunk = DictationAudioPreparation(samples: Array(samples[(start - sampleOffset)..<cut]))
        guard chunk.isAdmitted else {
            trace?.record(.incrementalSkipped, status: .insufficientVoice)
            return
        }
        processIncrementalChunk(
            generation: generation, audio: chunk,
            pauseSecondsAfterChunk: AudioRecorder.incrementalPauseSeconds(in: samples, around: cut),
            sourceEndIndex: sampleOffset + cut
        )
    }

    private func canStartPreview(_ session: Session) -> Bool {
        session.context.incrementalCadence.previewTickSeconds != nil
            && !session.cancelled
            && session.releaseAudio == nil
            && session.previewTask == nil
            // A chunk in flight would commit past the preview's start and
            // make its result stale.
            && session.activeTask == nil
            && session.pendingChunks.isEmpty
    }

    /// Transcribes the audio after the last committed chunk for the HUD.
    /// The result is shown only if no chunk committed meanwhile, and it never
    /// reaches the committed text, the final transcript, or failure handling.
    private func startPreviewIfNeeded(_ session: Session, samples: [Float], sampleOffset: Int) {
        let cadence = session.context.incrementalCadence
        let end = sampleOffset + samples.count
        guard canStartPreview(session),
              end >= Int(cadence.previewStartSeconds * AudioRecorder.sampleRate),
              session.completedSampleEnd < end else { return }
        let committedEnd = session.completedSampleEnd
        // A long hold without a pause must not re-decode minutes of audio
        // every second or leave release waiting behind that preview.
        let displayed = session.displayedPreview
        var start = max(committedEnd, displayed?.range.lowerBound ?? committedEnd)
        var prefix = start == committedEnd ? session.committedText : displayed?.prefix ?? ""
        if end - start > Self.previewWindowSamples {
            // Freeze the displayed hypothesis before starting another bounded
            // window. This prefix is for the HUD only, never final delivery.
            start = max(committedEnd, displayed?.range.upperBound ?? 0,
                        end - Self.previewWindowSamples)
            prefix = (displayed?.range.upperBound ?? 0) > committedEnd
                ? displayed?.text ?? session.committedText : session.committedText
        }
        guard start >= sampleOffset else { return }
        let range = start..<end
        guard range != session.lastPreviewRange else { return }
        let audio = DictationAudioPreparation(samples: Array(samples[(start - sampleOffset)..<samples.count]))
        guard audio.isAdmitted else { return }
        session.lastPreviewRange = range
        let lifetime = TranscriptionLifetime()
        session.previewLifetime = lifetime
        let request = DictationTranscriptionRequest(
            generation: session.generation,
            segment: .preview,
            samples: audio.samples,
            lowEnergy: audio.lowEnergy,
            purpose: .preview(lifetime)
        )
        session.previewTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            // Failures are already in the trace and must not change the dictation.
            let text = try? await runTranscription(request, session: session)
            session.previewTask = nil
            session.previewLifetime = nil
            guard let text, !text.isEmpty, isCurrent(session),
                  session.releaseAudio == nil,
                  session.completedSampleEnd == committedEnd else { return }
            let preview = Transcriber.joinTranscriptParts(
                prefix, text, pauseSeconds: start == committedEnd ? session.nextPauseSeconds : 0
            )
            session.displayedPreview = DisplayedPreview(range: range, prefix: prefix, text: preview)
            onPartialTranscript?(session.generation, preview)
        }
    }

    func processIncrementalChunk(
        generation: Int,
        samples: [Float],
        pauseSecondsAfterChunk: Double,
        sourceEndIndex: Int? = nil
    ) {
        processIncrementalChunk(
            generation: generation, audio: DictationAudioPreparation(samples: samples),
            pauseSecondsAfterChunk: pauseSecondsAfterChunk, sourceEndIndex: sourceEndIndex
        )
    }

    private func processIncrementalChunk(
        generation: Int,
        audio: DictationAudioPreparation,
        pauseSecondsAfterChunk: Double,
        sourceEndIndex: Int?
    ) {
        guard let session = sessions[generation],
              !session.cancelled,
              !session.incrementalFailed,
              session.releaseAudio == nil else { return }

        let chunk = IncrementalChunk(
            index: session.nextChunkIndex,
            audio: audio,
            pauseSecondsBefore: session.nextPauseSeconds,
            sourceEndIndex: sourceEndIndex
        )
        session.nextChunkIndex += 1
        session.nextPauseSeconds = pauseSecondsAfterChunk
        if let sourceEndIndex {
            session.incrementalSampleEnd = sourceEndIndex
        }
        session.pendingChunks.append(chunk)
        session.trace?.record(.chunkSubmitted, fields: [
            .chunkIndex: Double(chunk.index), .samples: Double(audio.samples.count),
            .submittedEnd: Double(session.incrementalSampleEnd)
        ])
        advance(session)
    }

    func recordCapturedAudio(generation: Int, samples: [Float], nativeAudio: NativeAudioRecording? = nil) {
        guard let session = sessions[generation], !session.capturedAudioSaved else { return }
        session.capturedAudioSaved = true
        session.diagnostics?.saveAudio(samples)
        session.personalVoice?.capture(native: nativeAudio, fallback: samples)
        session.diagnostics?.record(.init(stage: "capture", sampleCount: samples.count))
    }

    func release(
        generation: Int,
        fullSamples: [Float],
        tailSamples: [Float]? = nil
    ) {
        guard let session = sessions[generation],
              !session.cancelled,
              session.releaseAudio == nil else { return }
        recordCapturedAudio(generation: generation, samples: fullSamples)
        release(generation: generation, audio: DictationAudioPreparation(samples: fullSamples),
                tailSamples: tailSamples)
    }

    func release(
        generation: Int,
        audio full: DictationAudioPreparation,
        tailSamples: [Float]? = nil
    ) {
        guard let session = sessions[generation],
              !session.cancelled,
              session.releaseAudio == nil else { return }

        session.previewLifetime?.invalidate()

        let fullSamples = full.originalSamples
        recordCapturedAudio(generation: generation, samples: fullSamples)
        guard full.isAdmitted else {
            session.activeTask?.cancel()
            session.activeTask = nil
            session.pendingChunks.removeAll()
            complete(session, with: .insufficientVoice(generation: generation))
            return
        }
        let derivedTail: [Float]
        if let tailSamples {
            derivedTail = tailSamples
        } else if session.incrementalSampleEnd == 0 {
            derivedTail = fullSamples
        } else if session.incrementalSampleEnd <= fullSamples.count {
            derivedTail = Array(fullSamples[session.incrementalSampleEnd...])
        } else {
            derivedTail = []
            session.incrementalFailed = true
        }
        // Submitted chunks include queued and in-flight work, even before the
        // first chunk completes. Only those sessions can need a separate tail.
        let reusesFull = session.nextChunkIndex == 0 || session.incrementalFailed
            || (tailSamples == nil && session.incrementalSampleEnd == 0)
        session.releaseAudio = ReleaseAudio(
            full: full, tail: reusesFull ? full : DictationAudioPreparation(samples: derivedTail)
        )
        session.trace?.record(.audioReleased, fields: [
            .samples: Double(fullSamples.count), .tailSamples: Double(derivedTail.count),
            .submittedEnd: Double(session.incrementalSampleEnd),
            .completedEnd: Double(session.completedSampleEnd)
        ])
        advance(session)
        scheduleReleaseTimeout(for: session)
    }

    /// Escape invalidates queued work and gives active inference a grace period
    /// owned by Transcriber. Explicit interruption still cancels immediately.
    /// Session identity rejects all late results. Text cleanup is always cancelled.
    func cancel(generation: Int, interruptInference: Bool = true) {
        let trace = sessions[generation]?.trace ?? completed[generation]?.trace
        trace?.record(.cancellationRequested)
        if let session = sessions.removeValue(forKey: generation) {
            session.previewLifetime?.invalidate()
            for lifetime in session.inferenceLifetimes.values { lifetime.invalidate() }
            session.releaseTimeout?.cancel()
            session.cleanupDeadline?.cancel()
            session.diagnostics?.record(.init(stage: "outcome", status: "cancelled"))
            session.personalVoice?.finish(status: "cancelled")
            session.cancelled = true
            session.pendingChunks.removeAll()
            if interruptInference { session.previewTask?.cancel() }
            session.previewTask = nil
            if interruptInference || session.activeTaskIsCleanup {
                session.activeTask?.cancel()
            }
            session.activeTask = nil
        }
        guard generationOrder.contains(generation) else { return }
        completed.removeValue(forKey: generation)
        cancelled.insert(generation)
        drainCompletedOutcomes()
    }

    private func advance(_ session: Session) {
        guard !session.cancelled, session.activeTask == nil else { return }

        if let release = session.releaseAudio,
           session.context.incrementalCadence.decodesWholeUtteranceOnRelease {
            // Queued chunks would only update the HUD after release.
            session.pendingChunks.removeAll()
            transcribeFullUtterance(session, audio: release.full)
            return
        }

        if session.incrementalFailed {
            guard let release = session.releaseAudio else { return }
            transcribeFullUtterance(session, audio: release.full, isRetry: true)
            return
        }

        if !session.pendingChunks.isEmpty {
            transcribeNextChunk(session)
            return
        }

        guard let release = session.releaseAudio else { return }
        if session.chunkCount == 0 {
            transcribeFullUtterance(session, audio: release.full)
        } else {
            transcribeTail(session, release: release)
        }
    }

    private func transcribeNextChunk(_ session: Session) {
        let chunk = session.pendingChunks.removeFirst()
        let request = DictationTranscriptionRequest(
            generation: session.generation,
            segment: .incrementalChunk(index: chunk.index),
            samples: chunk.audio.samples,
            lowEnergy: chunk.audio.lowEnergy
        )
        session.activeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let text = request.samples.isEmpty
                    ? "" : try await runTranscription(request, session: session)
                guard isCurrent(session) else { return }
                session.activeTask = nil
                guard !text.isEmpty else {
                    session.incrementalFailed = true
                    session.pendingChunks.removeAll()
                    advance(session)
                    return
                }
                session.committedText = Transcriber.joinTranscriptParts(
                    session.committedText,
                    text,
                    pauseSeconds: chunk.pauseSecondsBefore
                )
                session.completedSampleEnd = chunk.sourceEndIndex ?? session.completedSampleEnd
                // Keep a preview that covers newer words. A successful chunk
                // must still appear if no preview has supplied those words.
                if (session.displayedPreview?.range.upperBound ?? 0) <= session.completedSampleEnd {
                    onPartialTranscript?(session.generation, session.committedText)
                }
                session.chunkCount += 1
                session.trace?.record(.chunkCompleted, fields: [
                    .chunkIndex: Double(chunk.index), .completedEnd: Double(session.completedSampleEnd)
                ])
                advance(session)
            } catch {
                guard isCurrent(session) else { return }
                session.activeTask = nil
                session.incrementalFailed = true
                session.pendingChunks.removeAll()
                advance(session)
            }
        }
    }

    private func transcribeTail(_ session: Session, release: ReleaseAudio) {
        let request = DictationTranscriptionRequest(
            generation: session.generation,
            segment: .releaseTail,
            samples: release.tail.samples,
            lowEnergy: release.tail.lowEnergy
        )
        session.activeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            do {
                // Quiet nonzero tails can contain final words below the admission
                // threshold. Only skip digital silence, including an empty tail.
                let tailText = request.samples.allSatisfy({ $0 == 0 })
                    ? "" : try await runTranscription(request, session: session)
                guard isCurrent(session) else { return }
                session.activeTask = nil
                let voicedTail = release.tail.rawVoicedSeconds > 0
                guard !tailText.isEmpty || !voicedTail else {
                    session.incrementalFailed = true
                    advance(session)
                    return
                }
                let wholeText = Transcriber.joinTranscriptParts(
                    session.committedText,
                    tailText,
                    pauseSeconds: session.nextPauseSeconds
                )
                onPartialTranscript?(session.generation, wholeText)
                finalize(session, transcript: wholeText)
            } catch {
                guard isCurrent(session) else { return }
                session.activeTask = nil
                session.incrementalFailed = true
                advance(session)
            }
        }
    }

    private func transcribeFullUtterance(_ session: Session, audio: DictationAudioPreparation, isRetry: Bool = false) {
        if isRetry {
            session.trace?.record(.fullRetry, fields: [.samples: Double(audio.samples.count)])
        }
        let request = DictationTranscriptionRequest(
            generation: session.generation,
            segment: .fullUtterance,
            samples: audio.samples,
            lowEnergy: audio.lowEnergy
        )
        session.activeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let text = try await runTranscription(request, session: session)
                guard isCurrent(session) else { return }
                session.activeTask = nil
                if text.isEmpty {
                    // Chunk fallback already spends the session's one recovery attempt.
                    if !isRetry, audio.canRetryEmptyResult {
                        transcribeFullUtterance(session, audio: audio, isRetry: true)
                    } else {
                        complete(session, with: .emptyTranscript(generation: session.generation))
                    }
                } else {
                    finalize(session, transcript: text)
                }
            } catch Transcriber.TranscriberError.noSpeech {
                guard isCurrent(session) else { return }
                session.activeTask = nil
                complete(session, with: .insufficientVoice(generation: session.generation))
            } catch {
                guard isCurrent(session) else { return }
                session.activeTask = nil
                complete(
                    session,
                    with: .failed(generation: session.generation, message: error.localizedDescription)
                )
            }
        }
    }

    private func finalize(_ session: Session, transcript: String) {
        session.diagnostics?.record(.init(stage: "assembledTranscript", text: transcript))
        session.personalVoice?.setRawTranscript(transcript)
        // Find triggers before corrections or formatting can change their words.
        // Only prose enters those transforms or a model. Snippet bytes stay local.
        let correctedParts = Snippets.parts(in: transcript, snippets: session.context.snippets).map { part in
            switch part {
            case .verbatim: return part
            case .transcript(let text):
                let corrected = TranscriptCorrections.apply(text, corrections: session.context.corrections)
                return .transcript(corrected)
            }
        }
        let parts = session.context.literalFormatting ? correctedParts : VoiceFormatter.apply(correctedParts)
        let composed = parts.map(\.text).joined()
        session.diagnostics?.record(.init(stage: "cleanupInput", text: composed))
        guard !composed.isEmpty else {
            complete(session, with: .emptyTranscript(generation: session.generation))
            return
        }
        guard session.context.cleanupEnabled else {
            session.trace?.record(.cleanupSkipped)
            complete(
                session,
                with: .finalTranscript(generation: session.generation, text: composed)
            )
            return
        }

        session.activeTaskIsCleanup = true
        session.cleanupFallbackText = composed
        let deadline = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, self.isCurrent(session),
                  let fallback = session.cleanupFallbackText else { return }
            session.activeTask?.cancel()
            self.completeCleanup(session, result: .init(text: fallback, succeeded: false))
        }
        session.cleanupDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + cleanupTimeout, execute: deadline)
        session.activeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            session.trace?.record(.cleanupStarted)
            let result = await DictationTrace.$current.withValue(session.trace) {
                await DictationDiagnosticStore.Recording.$current.withValue(session.diagnostics) {
                    // One deadline covers all prose spans. A timeout restores
                    // the entire deterministic composition, never a partial edit.
                    var output = ""
                    var succeeded = true
                    let hasSnippets = parts.contains { if case .verbatim = $0 { return true }; return false }
                    for part in parts {
                        guard self.isCurrent(session), !Task.isCancelled else {
                            return TranscriptCleanupResult(text: composed, succeeded: false)
                        }
                        switch part {
                        case .verbatim: output += part.text
                        case .transcript(let text):
                            // Preserve spacing at snippet boundaries even when a
                            // cleaner trims its input or rewrites all of the prose.
                            let body = hasSnippets ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
                            guard !body.isEmpty else { output += text; continue }
                            let result = await self.cleanup(.init(
                                generation: session.generation, text: body, context: session.context
                            ))
                            succeeded = succeeded && result.succeeded
                            if hasSnippets {
                                let leading = text.prefix(while: { $0.isWhitespace })
                                let trailing = text.reversed().prefix(while: { $0.isWhitespace }).reversed()
                                output += leading + result.text.trimmingCharacters(in: .whitespacesAndNewlines) + String(trailing)
                            } else {
                                output += result.text
                            }
                        }
                    }
                    return TranscriptCleanupResult(text: output, succeeded: succeeded)
                }
            }
            guard isCurrent(session) else { return }
            completeCleanup(session, result: result)
        }
    }

    private func completeCleanup(_ session: Session, result: TranscriptCleanupResult) {
        guard isCurrent(session), session.cleanupFallbackText != nil else { return }
        session.cleanupDeadline?.cancel()
        session.cleanupDeadline = nil
        session.cleanupFallbackText = nil
        session.activeTask = nil
        session.activeTaskIsCleanup = false
        session.diagnostics?.record(.init(stage: "cleanupOutput", text: result.text,
                                          status: result.succeeded ? "success" : "fallback"))
        session.trace?.record(.cleanupFinished, status: result.succeeded ? .success : .fallback)
        complete(session, with: .finalTranscript(generation: session.generation, text: result.text))
    }

    private func complete(_ session: Session, with outcome: DictationSessionOutcome) {
        guard isCurrent(session) else { return }
        session.previewLifetime?.invalidate()
        for lifetime in session.inferenceLifetimes.values { lifetime.invalidate() }
        session.releaseTimeout?.cancel()
        session.releaseTimeout = nil
        session.cleanupDeadline?.cancel()
        session.cleanupDeadline = nil
        let status: DictationTrace.Status
        switch outcome {
        case .finalTranscript: status = .success
        case .insufficientVoice: status = .insufficientVoice
        case .emptyTranscript: status = .empty
        case .failed: status = .failed
        }
        switch outcome {
        case .finalTranscript(_, let text):
            session.diagnostics?.record(.init(stage: "finalTranscript", text: text, status: status.rawValue))
            session.personalVoice?.setFinalTranscript(text)
        case .failed(_, let message):
            session.diagnostics?.record(.init(stage: "outcome", text: message, status: status.rawValue))
        case .insufficientVoice:
            session.diagnostics?.record(.init(stage: "outcome", status: "cancelled"))
        case .emptyTranscript:
            session.diagnostics?.record(.init(stage: "outcome", status: status.rawValue))
        }
        session.personalVoice?.finish(status: status == .insufficientVoice ? "cancelled" : status.rawValue)
        session.trace?.record(.resultReady, status: status)
        if status == .insufficientVoice {
            session.trace?.record(.cancellationRequested)
        }
        sessions.removeValue(forKey: session.generation)
        if status == .insufficientVoice {
            // A rejected recording never waits for earlier recognition work.
            cancelled.insert(session.generation)
            drainCompletedOutcomes()
            DictationTrace.$current.withValue(session.trace) { onOutcome(outcome) }
        } else {
            completed[session.generation] = (outcome, session.trace)
            drainCompletedOutcomes()
        }
    }

    private func isCurrent(_ session: Session) -> Bool {
        !session.cancelled && sessions[session.generation] === session
    }

    private func drainCompletedOutcomes() {
        while let generation = generationOrder.first {
            if cancelled.remove(generation) != nil {
                generationOrder.removeFirst()
                continue
            }
            guard let outcome = completed.removeValue(forKey: generation) else { return }
            generationOrder.removeFirst()
            outcome.trace?.record(.resultDelivered)
            DictationTrace.$current.withValue(outcome.trace) { onOutcome(outcome.outcome) }
        }
    }

    private func runTranscription(_ request: DictationTranscriptionRequest, session: Session) async throws -> String {
        try Task.checkCancellation()
        guard isCurrent(session) else { throw CancellationError() }
        let id = UUID()
        let lifetime = TranscriptionLifetime()
        session.inferenceLifetimes[id] = lifetime
        defer { session.inferenceLifetimes.removeValue(forKey: id) }
        var request = request
        request.lifetime = lifetime
        // A preview runs every second. Keeping its audio and text would bloat
        // the opt-in diagnostic archive, so only the trace sees it.
        let diagnostics = request.segment == .preview ? nil : session.diagnostics
        diagnostics?.record(.init(stage: "transcriptionRequest", segment: request.segment, sampleCount: request.samples.count))
        session.trace?.record(.transcriptionRequested, fields: [.samples: Double(request.samples.count)], segment: request.segment)
        do {
            let text = try await DictationTrace.$current.withValue(session.trace) {
                try await DictationDiagnosticStore.Recording.$current.withValue(diagnostics) {
                    try await transcribe(request)
                }
            }
            let abandoned = Task.isCancelled || !isCurrent(session)
            session.trace?.record(.transcriptionFinished, status: abandoned ? .cancelled : (text.isEmpty ? .empty : .success))
            if !abandoned {
                diagnostics?.record(.init(stage: "transcriptionResult", text: text,
                                          status: text.isEmpty ? "empty" : "success", segment: request.segment))
            }
            return text
        } catch Transcriber.TranscriberError.noSpeech {
            let abandoned = Task.isCancelled || !isCurrent(session)
            session.trace?.record(.transcriptionFinished, status: abandoned ? .cancelled : .insufficientVoice)
            if !abandoned {
                diagnostics?.record(.init(stage: "transcriptionResult", text: "",
                                          status: "insufficientVoice", segment: request.segment))
            }
            throw Transcriber.TranscriberError.noSpeech
        } catch {
            let abandoned = Task.isCancelled || !isCurrent(session)
            session.trace?.record(.transcriptionFinished, status: abandoned || error is CancellationError ? .cancelled : .failed)
            if !abandoned {
                diagnostics?.record(.init(stage: "transcriptionResult", text: error.localizedDescription,
                                          status: "failed", segment: request.segment))
            }
            throw error
        }
    }

    private func scheduleReleaseTimeout(for session: Session) {
        guard isCurrent(session), session.releaseTimeout == nil else { return }
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, self.isCurrent(session) else { return }
            session.releaseTimeout = nil
            if let fallback = session.cleanupFallbackText {
                session.activeTask?.cancel()
                self.completeCleanup(session, result: .init(text: fallback, succeeded: false))
                return
            }
            session.trace?.record(.cancellationRequested)
            session.previewTask?.cancel()
            session.previewTask = nil
            session.activeTask?.cancel()
            session.activeTask = nil
            session.pendingChunks.removeAll()
            self.complete(session, with: .failed(
                generation: session.generation,
                message: "Transcription timed out after recording ended."
            ))
        }
        session.releaseTimeout = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + stalledGenerationTimeout,
            execute: work
        )
    }
}
