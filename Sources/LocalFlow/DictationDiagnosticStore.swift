import AVFoundation
import Foundation

/// Optional content archives, separate from the content-free timing log.
/// All disk work runs on one queue. Deletion never recreates an in-flight archive.
final class DictationDiagnosticStore: @unchecked Sendable {
    static let writeFailedNotification = Notification.Name("LocalFlowDiagnosticRecordingWriteFailed")
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(AppIdentity.current.storageDirectory)/DiagnosticRecordings", isDirectory: true)
    static let shared = DictationDiagnosticStore(folder: folder)

    struct Metadata: Codable {
        let schemaVersion: Int
        let traceID: UUID
        let startedAt: Date
        let version: String
        let revision: String
        let builtAt: String
        /// Historical name: holds any speech model id, Whisper or not.
        let whisperModel: String
        let microphone: String
        let vocabulary: String
        let cleanupEnabled: Bool
        let cleanupModel: String
        let styleProfile: String
        let corrections: [[String]]
        let snippets: [[String]]

        init(traceID: UUID, context: DictationSessionContext, whisperModel: String,
             microphone: String, vocabulary: String) {
            schemaVersion = 1
            self.traceID = traceID
            startedAt = Date()
            version = AppBuildInfo.current.versionLabel
            revision = AppBuildInfo.current.revisionLabel
            builtAt = AppBuildInfo.current.builtAt
            self.whisperModel = whisperModel
            self.microphone = microphone
            self.vocabulary = vocabulary
            cleanupEnabled = context.cleanupEnabled
            cleanupModel = context.ollamaModel
            styleProfile = context.styleProfile.rawValue
            corrections = context.corrections.map { [$0.wrong, $0.right] }
            snippets = context.snippets.map { [$0.trigger, $0.expansion] }
        }
    }

    struct Event: Codable {
        struct Segment: Codable {
            let text: String
            let start: Float
            let end: Float
        }

        var at = Date()
        let stage: String
        var text: String? = nil
        var status: String? = nil
        var model: String? = nil
        var segment: DictationTranscriptionSegment? = nil
        var audioFile: String? = nil
        var sampleCount: Int? = nil
        var segments: [Segment]? = nil
    }

    final class Recording: @unchecked Sendable {
        @TaskLocal static var current: Recording?
        let id: UUID
        private let store: DictationDiagnosticStore

        fileprivate init(id: UUID, store: DictationDiagnosticStore) {
            self.id = id
            self.store = store
        }

        func record(_ event: Event) { store.append(event, id: id) }

        func recordTiming(_ event: DictationTrace.Event) {
            store.append(event, id: id, filename: "timing.jsonl")
        }

        func saveAudio(_ samples: [Float], named name: String = "original.wav") {
            store.saveAudio(samples, named: name, id: id)
        }
    }

    private let root: URL
    private let maxAge: TimeInterval
    private let maxBytes: Int
    private let now: () -> Date
    private let queue = DispatchQueue(label: "app.talix.localflow.diagnostic-recordings", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var writeFailed = false
    // Queue-owned accounting. Reconcile at archive creation, explicit/hourly maintenance,
    // and after any failed I/O. Ordinary appends only stat the file they changed.
    private struct Entry {
        let date: Date
        var files: [String: Int]
        var bytes: Int { files.values.reduce(0, +) }
    }
    private var entries: [URL: Entry] = [:]
    private var oldestFirst: [URL] = []
    private var totalBytes = 0
    private var accountingValid = false

    var hasWriteFailure: Bool { queue.sync { writeFailed } }

    init(folder: URL, maxAge: TimeInterval = 7 * 24 * 60 * 60, maxBytes: Int = 1_000_000_000,
         now: @escaping () -> Date = Date.init) {
        root = folder
        self.maxAge = maxAge
        self.maxBytes = maxBytes
        self.now = now
    }

    func begin(_ metadata: Metadata) -> Recording {
        queue.async {
            self.performWrite {
                try self.pruneNow()
                let fm = FileManager.default
                try fm.createDirectory(at: self.root, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
                let directory = self.directory(metadata.traceID)
                try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try self.write(encoder.encode(metadata), to: directory.appendingPathComponent("metadata.json"))
                try self.write(Data((DiagLog.environmentLine() + "\n").utf8),
                               to: directory.appendingPathComponent("environment.txt"))
                try self.refreshEntry(directory)
                try self.enforceRetention()
            }
        }
        return Recording(id: metadata.traceID, store: self)
    }

    func startMaintenance() {
        queue.async {
            guard self.timer == nil else { return }
            self.performWrite { try self.pruneNow() }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 3600, repeating: 3600)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.performWrite { try self.pruneNow() }
            }
            self.timer = timer
            timer.resume()
        }
    }

    func deleteAll(completion: @escaping (Bool) -> Void) {
        queue.async {
            let success: Bool
            do {
                for directory in try self.managedDirectories() {
                    try FileManager.default.removeItem(at: directory)
                }
                self.entries = [:]
                self.oldestFirst = []
                self.totalBytes = 0
                self.accountingValid = true
                success = true
            } catch {
                self.accountingValid = false
                success = false
            }
            DispatchQueue.main.async { completion(success) }
        }
    }

    /// Used on orderly shutdown and by tests, never on the capture thread.
    func flush() { queue.sync {} }

    func prune() { queue.async { self.performWrite { try self.pruneNow() } } }

    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func append<T: Encodable>(_ event: T, id: UUID, filename: String = "events.jsonl") {
        queue.async {
            guard FileManager.default.fileExists(atPath: self.directory(id).path) else { return }
            self.performWrite {
                try self.ensureAccounting()
                guard FileManager.default.fileExists(atPath: self.directory(id).path) else { return }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                var data = try encoder.encode(event)
                data.append(0x0a)
                let url = self.directory(id).appendingPathComponent(filename)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try self.write(data, to: url)
                } else {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                }
                try self.accountFile(url, id: id)
                try self.enforceRetention()
            }
        }
    }

    private func saveAudio(_ samples: [Float], named name: String, id: UUID) {
        // Filenames are internal constants or generated UUIDs, never transcript content.
        guard name == URL(fileURLWithPath: name).lastPathComponent else { return }
        queue.async {
            guard FileManager.default.fileExists(atPath: self.directory(id).path) else { return }
            self.performWrite {
                try self.ensureAccounting()
                guard FileManager.default.fileExists(atPath: self.directory(id).path) else { return }
                let url = self.directory(id).appendingPathComponent(name)
                try RetainedAudioFile.write(samples: samples, sampleRate: AudioRecorder.sampleRate, to: url)
                // RetainedAudioFile closes the WAV before measuring it.
                try self.accountFile(url, id: id)
            }
            self.performWrite { try self.enforceRetention() }
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func managedDirectories() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).filter {
                guard UUID(uuidString: $0.lastPathComponent) != nil else { return false }
                let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory == true && values.isSymbolicLink != true
            }
    }

    private func ensureAccounting() throws {
        if !accountingValid { try reconcile() }
    }

    private func refreshEntry(_ url: URL) throws {
        let date = try url.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
        let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var sizes: [String: Int] = [:]
        for file in files {
            sizes[file.lastPathComponent] = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        totalBytes -= entries[url]?.bytes ?? 0
        entries[url] = Entry(date: date, files: sizes)
        totalBytes += entries[url]!.bytes
        oldestFirst.removeAll { $0 == url }
        let index = oldestFirst.firstIndex { entries[$0]!.date > date } ?? oldestFirst.endIndex
        oldestFirst.insert(url, at: index)
    }

    private func accountFile(_ url: URL, id: UUID) throws {
        // A file may have been replaced or grown outside this process. Use its
        // actual size, including the WAV header, rather than the requested bytes.
        let folder = directory(id)
        guard var entry = entries[folder] else {
            try refreshEntry(directory(id))
            return
        }
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        totalBytes += bytes - (entry.files[url.lastPathComponent] ?? 0)
        entry.files[url.lastPathComponent] = bytes
        entries[folder] = entry
    }

    private func reconcile() throws {
        accountingValid = false
        entries = [:]
        oldestFirst = []
        totalBytes = 0
        let cutoff = now().addingTimeInterval(-maxAge)
        for url in try managedDirectories() {
            let date = try url.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
            if date < cutoff {
                // Expired folders need no content enumeration, even if unreadable.
                try FileManager.default.removeItem(at: url)
            } else {
                try refreshEntry(url)
            }
        }
        accountingValid = true
    }

    private func pruneNow() throws {
        try reconcile()
        try enforceRetention()
    }

    private func enforceRetention() throws {
        try ensureAccounting()
        let cutoff = now().addingTimeInterval(-maxAge)
        while let url = oldestFirst.first, let entry = entries[url],
              entry.date < cutoff || totalBytes > maxBytes {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            totalBytes -= entry.bytes
            entries[url] = nil
            oldestFirst.removeFirst()
        }
    }

    private func performWrite(_ operation: () throws -> Void) {
        do { try operation() }
        catch {
            accountingValid = false
            writeFailed = true
            // Error descriptions can contain private paths. Keep the timing log content-free.
            DiagLog.log("diagnostic recording save or retention failed; archive may be incomplete")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.writeFailedNotification, object: nil)
            }
        }
    }
}
