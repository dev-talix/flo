import AVFoundation
import Foundation
import XCTest
import WhisperKit
@testable import LocalFlow

final class DictationDiagnosticStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testAudioRoundTripsExactFloatSamplesWithPrivatePermissions() throws {
        let root = try temporaryDirectory()
        let store = DictationDiagnosticStore(folder: root)
        let metadata = metadata()
        let recording = store.begin(metadata)
        let samples: [Float] = [0, -1, 1, 0.12345679, -0.000001, 0.75, -0.875]
        recording.saveAudio(samples)
        recording.record(.init(stage: "capture", sampleCount: samples.count))
        store.flush()

        let directory = root.appendingPathComponent(metadata.traceID.uuidString)
        let audioURL = directory.appendingPathComponent("original.wav")
        let file = try AVAudioFile(forReading: audioURL)
        XCTAssertEqual(file.fileFormat.sampleRate, AudioRecorder.sampleRate)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, AVAudioFramePosition(samples.count))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), samples)
        XCTAssertEqual(try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path), samples)

        for url in [root, directory] {
            XCTAssertEqual(try permissions(url), 0o700, url.lastPathComponent)
        }
        for name in ["original.wav", "metadata.json", "environment.txt", "events.jsonl"] {
            XCTAssertEqual(try permissions(directory.appendingPathComponent(name)), 0o600, name)
        }
    }

    func testMetadataAndTranscriptStagesPreserveEmptyTextAndSegmentTimes() throws {
        let root = try temporaryDirectory()
        let store = DictationDiagnosticStore(folder: root)
        let metadata = metadata()
        let recording = store.begin(metadata)
        recording.record(.init(
            stage: "whisperRaw", text: "final five words\nkept", model: "test-whisper",
            segments: [.init(text: "final five words", start: 35.125, end: 40.25)]
        ))
        recording.record(.init(stage: "whisperPostprocessed", text: "", status: "filtered"))
        recording.record(.init(stage: "transcriptionResult", text: "tail", segment: .releaseTail))
        recording.record(.init(stage: "cleanupOutput", text: "Cleaned tail."))
        store.flush()

        let directory = root.appendingPathComponent(metadata.traceID.uuidString)
        let savedMetadata = try object(at: directory.appendingPathComponent("metadata.json"))
        let environment = try String(contentsOf: directory.appendingPathComponent("environment.txt"))
        XCTAssertTrue(environment.contains("timing_environment "))
        XCTAssertTrue(environment.contains("osVersion"))
        XCTAssertEqual(savedMetadata["schemaVersion"] as? Int, 1)
        XCTAssertEqual(savedMetadata["traceID"] as? String, metadata.traceID.uuidString)
        XCTAssertEqual(savedMetadata["whisperModel"] as? String, "test-whisper")
        XCTAssertEqual(savedMetadata["microphone"] as? String, "synthetic-input")
        XCTAssertEqual(savedMetadata["vocabulary"] as? String, "LocalFlow, Talix")
        XCTAssertEqual(savedMetadata["cleanupEnabled"] as? Bool, true)
        XCTAssertEqual(savedMetadata["cleanupModel"] as? String, "test-cleaner")
        XCTAssertEqual(savedMetadata["styleProfile"] as? String, "general")
        XCTAssertEqual(savedMetadata["corrections"] as? [[String]], [["taliks", "Talix"]])
        XCTAssertEqual(savedMetadata["snippets"] as? [[String]], [["sign off", "Thank you.\nTest"]])
        for key in ["startedAt", "version", "revision", "builtAt"] {
            XCTAssertNotNil(savedMetadata[key] as? String, key)
        }

        let data = try Data(contentsOf: directory.appendingPathComponent("events.jsonl"))
        XCTAssertEqual(data.last, 0x0a)
        let events = try data.split(separator: 0x0a).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        XCTAssertEqual(events.compactMap { $0["stage"] as? String }, [
            "whisperRaw", "whisperPostprocessed", "transcriptionResult", "cleanupOutput",
        ])
        XCTAssertEqual(events[0]["text"] as? String, "final five words\nkept")
        XCTAssertEqual(events[0]["model"] as? String, "test-whisper")
        let segment = try XCTUnwrap((events[0]["segments"] as? [[String: Any]])?.first)
        XCTAssertEqual(segment["text"] as? String, "final five words")
        XCTAssertEqual(segment["start"] as? Double, 35.125)
        XCTAssertEqual(segment["end"] as? Double, 40.25)
        XCTAssertEqual(events[1]["text"] as? String, "")
        XCTAssertEqual(events[1]["status"] as? String, "filtered")
        XCTAssertEqual(events[3]["text"] as? String, "Cleaned tail.")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try data.split(separator: 0x0a).map {
            try decoder.decode(DictationDiagnosticStore.Event.self, from: Data($0))
        }
        XCTAssertEqual(decoded[2].segment, .releaseTail)
        XCTAssertTrue(events.allSatisfy { $0["at"] is String })
    }

    func testDeletionPreventsLateRecordingWritesFromRecreatingArchive() throws {
        let root = try temporaryDirectory()
        let store = DictationDiagnosticStore(folder: root)
        let recording = store.begin(metadata())
        recording.saveAudio([0.25, -0.25])
        store.flush()
        let deleted = expectation(description: "Diagnostics deleted on main thread")

        store.deleteAll { succeeded in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(succeeded)
            deleted.fulfill()
        }
        recording.record(.init(stage: "cleanupOutput", text: "late result"))
        recording.saveAudio([0.5], named: "late.wav")
        store.flush()
        wait(for: [deleted], timeout: 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testPruneRemovesExpiredArchivesAndKeepsRecentArchives() throws {
        let root = try temporaryDirectory()
        let old = try archive(in: root, age: 3600, bytes: 16)
        let recent = try archive(in: root, age: 60, bytes: 16)
        let store = DictationDiagnosticStore(folder: root, maxAge: 600)

        store.prune()
        store.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    func testByteLimitPrunesOldestArchivesFirst() throws {
        let root = try temporaryDirectory()
        let oldest = try archive(in: root, age: 300, bytes: 20)
        let middle = try archive(in: root, age: 200, bytes: 20)
        let newest = try archive(in: root, age: 100, bytes: 20)
        let store = DictationDiagnosticStore(folder: root, maxBytes: 40)

        store.prune()
        store.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: middle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
    }

    func testPruneAndDeleteLeaveUnmanagedFilesAndSymbolicLinksAlone() throws {
        let temporary = try temporaryDirectory()
        let root = temporary.appendingPathComponent("archives")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let unmanagedFolder = root.appendingPathComponent("personal-notes")
        try FileManager.default.createDirectory(at: unmanagedFolder, withIntermediateDirectories: false)
        let unmanagedFile = root.appendingPathComponent(UUID().uuidString)
        try Data("keep".utf8).write(to: unmanagedFile)
        let external = temporary.appendingPathComponent("outside-archive")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let externalFile = external.appendingPathComponent("keep.txt")
        try Data("untouched".utf8).write(to: externalFile)
        let symbolicLink = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: external)
        let managed = try archive(in: root, age: 3600, bytes: 20)
        let store = DictationDiagnosticStore(folder: root, maxAge: 1, maxBytes: 0)

        store.prune()
        store.flush()
        let deleted = expectation(description: "Managed archives deleted")
        store.deleteAll { succeeded in
            XCTAssertTrue(succeeded)
            deleted.fulfill()
        }
        wait(for: [deleted], timeout: 2)

        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmanagedFolder.path))
        XCTAssertEqual(try String(contentsOf: unmanagedFile), "keep")
        XCTAssertEqual(try String(contentsOf: externalFile), "untouched")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symbolicLink.path), external.path)
    }

    func testInvalidRootReportsWriteFailureWithoutReplacingExistingFile() throws {
        let temporary = try temporaryDirectory()
        let root = temporary.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: root)
        let store = DictationDiagnosticStore(folder: root)
        let failed = expectation(
            forNotification: DictationDiagnosticStore.writeFailedNotification,
            object: nil
        ) { _ in
            XCTAssertTrue(Thread.isMainThread)
            return true
        }

        _ = store.begin(metadata())
        store.flush()
        wait(for: [failed], timeout: 2)

        XCTAssertEqual(try String(contentsOf: root), "keep")
    }

    func testGrowingEventsAndAudioPruneImmediatelyAndReplacementDoesNotDoubleCount() throws {
        let root = try temporaryDirectory()
        let old = try archive(in: root, age: 300, bytes: 4_000)
        let newer = try archive(in: root, age: 200, bytes: 4_000)
        let store = DictationDiagnosticStore(folder: root, maxBytes: 10_000)
        let metadata = metadata()
        let recording = store.begin(metadata)
        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        recording.record(.init(stage: "fixture", text: String(repeating: "a", count: 3_000)))
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path))
        XCTAssertLessThanOrEqual(try storedBytes(root), 10_000)

        recording.saveAudio([Float](repeating: 0.125, count: 100))
        store.flush()
        let bytes = try storedBytes(root)
        for _ in 0..<5 { recording.saveAudio([Float](repeating: 0.125, count: 100)) }
        store.flush()
        XCTAssertEqual(try storedBytes(root), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(metadata.traceID.uuidString).path))

        for _ in 0..<5 {
            recording.record(.init(stage: "fixture", text: String(repeating: "b", count: 3_000)))
            store.flush()
            XCTAssertLessThanOrEqual(try storedBytes(root), 10_000)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        XCTAssertFalse(store.hasWriteFailure)
    }

    func testExpiryIsCheckedOnEveryWriteWithoutMaintenance() throws {
        let root = try temporaryDirectory()
        var now = Date()
        let store = DictationDiagnosticStore(folder: root, maxAge: 600, now: { now })
        let recording = store.begin(metadata())
        recording.record(.init(stage: "before expiry"))
        store.flush()
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        now = now.addingTimeInterval(601)
        recording.record(.init(stage: "after expiry"))
        store.flush()
        recording.saveAudio([0.5])
        store.flush()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        XCTAssertFalse(store.hasWriteFailure)
    }

    func testRestartAndMaintenanceReconcileExternalGrowthAndDeletion() throws {
        let root = try temporaryDirectory()
        let first = DictationDiagnosticStore(folder: root)
        let old = first.begin(metadata())
        old.record(.init(stage: "before restart", text: String(repeating: "a", count: 2_000)))
        first.flush()
        let oldURL = root.appendingPathComponent(old.id.uuidString)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-100)], ofItemAtPath: oldURL.path)
        let restarted = DictationDiagnosticStore(folder: root, maxBytes: 5_000)
        let next = restarted.begin(metadata())
        restarted.flush()
        next.record(.init(stage: "after restart", text: String(repeating: "b", count: 2_000)))
        restarted.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertLessThanOrEqual(try storedBytes(root), 5_000)

        let external = try archive(in: root, age: 50, bytes: 6_000)
        restarted.prune()
        restarted.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
        let nextURL = root.appendingPathComponent(next.id.uuidString)
        try FileManager.default.removeItem(at: nextURL)
        restarted.prune()
        let last = restarted.begin(metadata())
        last.record(.init(stage: "after external deletion"))
        restarted.flush()
        XCTAssertFalse(restarted.hasWriteFailure)
        XCTAssertLessThanOrEqual(try storedBytes(root), 5_000)
    }

    func testExternalGrowthOfChangedFileCountsWithoutFullReconciliation() throws {
        let root = try temporaryDirectory()
        let store = DictationDiagnosticStore(folder: root, maxBytes: 5_000)
        let recording = store.begin(metadata())
        recording.record(.init(stage: "first"))
        store.flush()
        let directory = root.appendingPathComponent(recording.id.uuidString)
        let events = directory.appendingPathComponent("events.jsonl")
        let handle = try FileHandle(forWritingTo: events)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x20, count: 5_000))
        try handle.close()
        recording.record(.init(stage: "growing file"))
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(store.hasWriteFailure)
    }

    func testChangedFileSizeIsMeasuredAndFailedWriteReconcilesBeforeRetry() throws {
        let root = try temporaryDirectory()
        let store = DictationDiagnosticStore(folder: root, maxBytes: 5_000)
        let recording = store.begin(metadata())
        recording.record(.init(stage: "first"))
        store.flush()
        let directory = root.appendingPathComponent(recording.id.uuidString)
        let events = directory.appendingPathComponent("events.jsonl")
        try FileManager.default.removeItem(at: events)
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: false)
        recording.record(.init(stage: "cannot append to directory"))
        store.flush()
        XCTAssertTrue(store.hasWriteFailure)
        try FileManager.default.removeItem(at: events)
        try Data(repeating: 0x20, count: 4_900).write(to: events)
        recording.record(.init(stage: "actual size exceeds quota"))
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        recording.record(.init(stage: "late"))
        store.flush()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testConcurrentWritesKeepCompleteLinesAndPerProducerOrderThenDelete() throws {
        let root = try temporaryDirectory()
        let store = DictationDiagnosticStore(folder: root)
        let recording = store.begin(metadata())
        DispatchQueue.concurrentPerform(iterations: 8) { producer in
            for index in 0..<30 {
                recording.record(.init(stage: "\(producer)", sampleCount: index))
            }
        }
        store.flush()
        let data = try Data(contentsOf: root.appendingPathComponent(recording.id.uuidString).appendingPathComponent("events.jsonl"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try data.split(separator: 10).map { try decoder.decode(DictationDiagnosticStore.Event.self, from: Data($0)) }
        XCTAssertEqual(events.count, 240)
        for producer in 0..<8 {
            XCTAssertEqual(events.filter { $0.stage == "\(producer)" }.compactMap(\.sampleCount), Array(0..<30))
        }
        let deleted = expectation(description: "deletion ordered after producers")
        store.deleteAll { XCTAssertTrue($0); deleted.fulfill() }
        DispatchQueue.concurrentPerform(iterations: 8) { _ in recording.record(.init(stage: "late")) }
        store.flush()
        wait(for: [deleted], timeout: 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let fresh = store.begin(metadata())
        fresh.record(.init(stage: "new recording"))
        store.flush()
        XCTAssertFalse(store.hasWriteFailure)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
    }

    private func storedBytes(_ root: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).reduce(0) { total, directory in
            try total + FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).reduce(0) {
                try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-DiagnosticStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        temporaryDirectories.append(directory)
        return directory
    }

    private func metadata() -> DictationDiagnosticStore.Metadata {
        .init(
            traceID: UUID(),
            context: .init(
                cleanupEnabled: true,
                styleProfile: .general,
                corrections: [(wrong: "taliks", right: "Talix")],
                snippets: [(trigger: "sign off", expansion: "Thank you.\nTest")],
                ollamaModel: "test-cleaner"
            ),
            whisperModel: "test-whisper",
            microphone: "synthetic-input",
            vocabulary: "LocalFlow, Talix"
        )
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func object(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func archive(in root: URL, age: TimeInterval, bytes: Int) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data(repeating: 0x61, count: bytes).write(to: directory.appendingPathComponent("payload"))
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: directory.path
        )
        return directory
    }
}
