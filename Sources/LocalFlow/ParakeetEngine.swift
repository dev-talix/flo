import CoreML
import FluidAudio
import Foundation

// Only this file imports FluidAudio, and it must never import WhisperKit:
// both export `WordTiming` and `Tokenizer`.

/// NVIDIA Parakeet TDT 0.6B v3 on CoreML through FluidAudio. It has no decoder
/// prompt, so custom vocabulary is applied after decoding: `VocabularyBooster`
/// checks the audio for each term and replaces the words Parakeet misheard.
final class ParakeetEngine: SpeechEngine {
    /// Short clips are padded with trailing silence to this length. FluidAudio
    /// rejects anything under 0.3 s and can return no tokens for very short
    /// speech.
    static let minimumSeconds = 1.5
    /// Clips over 15 s are decoded in windows. `nil` lets FluidAudio pick per
    /// model version, which is `false` for v3. Replay A/B on a 19 s and a 90 s
    /// clip (FluidAudio 0.17.5): neither setting dropped or repeated words at
    /// window seams, and they differed only in punctuation. Keep the
    /// library default.
    static let melChunkContext: Bool? = nil
    /// FluidAudio token times are emission times, not acoustic boundaries.
    /// Replaying pauses of 1 to 2.5 s, the gap between the words on either
    /// side came out 0.6 to 0.75 s shorter than the real silence. Added back
    /// before comparing against the paragraph pause.
    static let tokenGapShortfall = 0.7

    static let modelsDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LocalFlow/models/FluidAudio", isDirectory: true)

    /// FluidAudio takes the repo folder itself and downloads into its parent.
    private static var repoDirectory: URL {
        modelsDirectory.appendingPathComponent(
            AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent, isDirectory: true
        )
    }

    private let asr: AsrManager
    private let decoderLayers: Int
    private let booster = VocabularyBooster()

    private init(asr: AsrManager, decoderLayers: Int) {
        self.asr = asr
        self.decoderLayers = decoderLayers
    }

    /// Downloads (about 480 MB, once) and loads the model. A cold first load
    /// also compiles the CoreML models for this Mac. FluidAudio repairs a
    /// corrupt cache itself by deleting and re-downloading it, so there is no
    /// separate fallback path here.
    static func load(trace: DictationTrace) async throws -> ParakeetEngine {
        let directory = repoDirectory
        let cached = AsrModels.modelsExist(at: directory, version: .v3, encoderPrecision: .int8)
        trace.record(.modelCacheChecked, fields: [.cachePresent: cached ? 1 : 0])
        trace.record(.modelAttemptStarted)
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            let modelDirectory = try await AsrModels.download(to: directory, version: .v3, encoderPrecision: .int8)
            trace.record(.modelInitializationStarted)
            let engine: ParakeetEngine
            do {
                let models = try await AsrModels.load(from: modelDirectory, version: .v3, encoderPrecision: .int8)
                let asr = AsrManager(config: ASRConfig(melChunkContext: melChunkContext))
                try await asr.loadModels(models)
                engine = ParakeetEngine(asr: asr, decoderLayers: await asr.decoderLayerCount)
                trace.record(.modelInitializationFinished, status: .success)
            } catch {
                trace.record(.modelInitializationFinished, status: error is CancellationError ? .cancelled : .failed)
                throw error
            }
            trace.record(.modelAttemptFinished, status: .success)
            return engine
        } catch {
            trace.record(.modelAttemptFinished, status: error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }

    func setVocabulary(_ terms: String) async {
        await booster.setTerms(Self.vocabularyTerms(from: terms))
    }

    func transcribe(samples: [Float], lowEnergy: Bool) async throws -> EngineTranscription {
        try await transcribe(samples: samples, lowEnergy: lowEnergy, purpose: .authoritative)
    }

    func transcribe(samples: [Float], lowEnergy: Bool, purpose: TranscriptionPurpose) async throws -> EngineTranscription {
        let input = Self.padded(samples)
        // A fresh state per call: a cancelled call must not leak decoder
        // state into the next one.
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await asr.transcribe(input, decoderState: &state)
        let tokens = result.tokenTimings?.map {
            Token(text: $0.token, start: $0.startTime, end: $0.endTime)
        }
        var segments = Self.segments(text: result.text, tokens: tokens, duration: Float(result.duration))
        // Previews rerun every second and only feed the HUD.
        if purpose.preview == nil, let timings = result.tokenTimings,
           let boosted = await booster.rescore(text: result.text, tokenTimings: timings, audioSamples: input) {
            segments = Self.replacingText(of: segments, with: boosted)
        }
        return EngineTranscription(
            segments: segments,
            rawText: result.text,
            decodingFallbacks: 0,
            resultCount: 1
        )
    }

    // MARK: - Pure helpers (no FluidAudio types, unit-tested)

    struct Token: Equatable {
        let text: String
        let start: Double
        let end: Double
    }

    /// The vocabulary setting is free text. Terms are separated by commas or
    /// line breaks, and repeats are dropped whatever their case.
    static func vocabularyTerms(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Spreads `text` over `segments` after vocabulary replacements changed
    /// some words, keeping each paragraph break after the same word. A
    /// replacement can change the word count ("auth zero" to "Auth0"), so
    /// breaks are carried through a word diff, not counted.
    static func replacingText(of segments: [EngineSegment], with text: String) -> [EngineSegment] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard segments.count > 1 else {
            return segments.map { EngineSegment(text: words.joined(separator: " "), start: $0.start, end: $0.end) }
        }
        let original = segments.map { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
        let difference = words.difference(from: original.flatMap { $0 })
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [EngineSegment] = []
        var originalIndex = 0
        var index = 0
        for (position, (segment, segmentWords)) in zip(segments, original).enumerated() {
            let start = index
            for _ in segmentWords {
                if removed.contains(originalIndex) {
                    // Each replaced word takes one new word, and the last of
                    // a replaced run takes whatever is left of the new run.
                    if index < words.count, inserted.contains(index) { index += 1 }
                    if !removed.contains(originalIndex + 1) {
                        while index < words.count, inserted.contains(index) { index += 1 }
                    }
                } else {
                    while index < words.count, inserted.contains(index) { index += 1 }
                    index += 1
                }
                originalIndex += 1
            }
            if position == segments.count - 1 { index = words.count }
            let piece = words[min(start, words.count)..<min(index, words.count)].joined(separator: " ")
            if !piece.isEmpty { result.append(EngineSegment(text: piece, start: segment.start, end: segment.end)) }
        }
        return result
    }

    /// Pads with trailing zeros up to `minimumSeconds`. Longer input is
    /// returned unchanged. Leading silence is already trimmed upstream.
    static func padded(
        _ samples: [Float],
        sampleRate: Int = 16_000,
        minimumSeconds: Double = minimumSeconds
    ) -> [Float] {
        let minimum = Int((Double(sampleRate) * minimumSeconds).rounded(.up))
        guard samples.count < minimum else { return samples }
        return samples + [Float](repeating: 0, count: minimum - samples.count)
    }

    /// Splits the transcript where a long pause follows the end of a
    /// sentence, so `Transcriber.joinSegments` can apply its paragraph rule.
    /// FluidAudio 0.17.5 marks word starts with a leading space (it rewrites
    /// the SentencePiece "▁"; both are accepted). It emits sentence
    /// punctuation at the end of a pause, right before the next word, so
    /// punctuation-only tokens don't count as speech when measuring the gap
    /// or a segment's end.
    /// Each split shifts the later segments by `tokenGapShortfall`, so
    /// joinSegments sees the estimated pause and every span keeps
    /// start <= end.
    /// If the tokens don't rebuild `text` exactly, returns one segment:
    /// output is never worse than the engine's own text.
    static func segments(
        text: String,
        tokens: [Token]?,
        duration: Float,
        pauseSeconds: Float = Transcriber.paragraphPauseSeconds
    ) -> [EngineSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let whole = [EngineSegment(text: trimmed, start: 0, end: duration)]
        guard let tokens, let first = tokens.first else { return whole }

        var segments: [EngineSegment] = []
        var current = ""
        var start = first.start
        var end = first.end
        var offset = 0.0
        for token in tokens {
            let piece = token.text.replacingOccurrences(of: "\u{2581}", with: " ")
            let core = piece.trimmingCharacters(in: .whitespaces)
            if !core.isEmpty, core.allSatisfy(\.isPunctuation) {
                current += piece
                continue
            }
            let sentence = current.trimmingCharacters(in: .whitespaces)
            let pause = token.start - end + tokenGapShortfall
            if !sentence.isEmpty, pause >= Double(pauseSeconds), Transcriber.endsSentence(sentence) {
                segments.append(EngineSegment(text: sentence, start: Float(start + offset), end: Float(end + offset)))
                current = ""
                offset += tokenGapShortfall
                start = token.start
            }
            current += piece
            end = token.end
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty {
            segments.append(EngineSegment(text: last, start: Float(start + offset), end: Float(end + offset)))
        }

        let rebuilt = segments.map(\.text).joined(separator: " ")
        return collapsed(rebuilt) == collapsed(trimmed) ? segments : whole
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Custom vocabulary for Parakeet. A small CTC model scores each term against
/// the audio, and a term replaces the transcribed words only where it is the
/// better acoustic match. Terms that fail to load leave dictation unchanged.
private actor VocabularyBooster {
    /// Next to the Parakeet model, so both app channels share one download
    /// (about 98 MB, fetched the first time a vocabulary is set).
    private static let directory = ParakeetEngine.modelsDirectory.appendingPathComponent(
        CtcModels.defaultCacheDirectory().lastPathComponent, isDirectory: true
    )

    /// FluidAudio's defaults favor finding every term. On 436 saved
    /// dictations with a 10-term list (0.18.3) they rewrote 359, mostly through
    /// the acoustic rescue pass, which swaps in a term that shares no spelling
    /// with the words it replaces ("Commit" became a product name). With
    /// rescue off, a term must also look like what was transcribed and still
    /// win on the audio. These values changed 40 of the 436, each to the
    /// listed name. A 0.6 floor instead cut "Talix.app" down to "Talix", and
    /// the default bias of 4.5 turned "auth zero" into "Auth0 zero".
    /// With rescue off, transcripts that resemble no term skip the CTC model.
    private static let config = VocabularyRescorer.Config(spotterRescueEnabled: false)
    private static let thresholds = VocabularyBoostingSession.Thresholds(cbw: 2, minSimilarity: 0.7)

    private var terms: [String] = []
    private var revision = 0
    private var session: VocabularyBoostingSession?
    private var models: Task<CtcModels, Error>?

    /// Returns once the terms are in effect when the model is already on
    /// disk. A first download continues in the background so it never holds
    /// up dictation.
    func setTerms(_ terms: [String]) async {
        guard terms != self.terms else { return }
        self.terms = terms
        revision += 1
        session = nil
        guard !terms.isEmpty else { return }
        let cached = CtcModels.modelsExist(at: Self.directory)
        let build = Task { [revision] in await self.build(terms, revision: revision) }
        if cached { await build.value }
    }

    private func build(_ terms: [String], revision: Int) async {
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            if models == nil {
                models = Task { try await CtcModels.downloadAndLoad(to: Self.directory) }
            }
            let session = try await VocabularyBoostingSession(
                vocabulary: CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) }),
                ctcModels: try await models!.value,
                config: Self.config,
                thresholds: Self.thresholds
            )
            guard revision == self.revision else { return }
            self.session = session
            DiagLog.log("vocabulary boosting ready (%d terms, %dms)", terms.count,
                        Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000))
        } catch {
            // A later vocabulary change or model reload tries again.
            models = nil
            DiagLog.log("vocabulary boosting unavailable: %@", String(describing: type(of: error)))
        }
    }

    /// The transcript with vocabulary terms applied, or nil when nothing changed.
    func rescore(text: String, tokenTimings: [TokenTiming], audioSamples: [Float]) async -> String? {
        guard let session, session.hasCTCRescoringCandidates(text: text, tokenTimings: tokenTimings),
              let output = await session.rescore(text: text, tokenTimings: tokenTimings, audioSamples: audioSamples),
              output.wasModified else { return nil }
        return output.text
    }
}
