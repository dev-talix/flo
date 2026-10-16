import AVFoundation
import XCTest
@testable import LocalFlow

final class RetainedAudioFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testMultipleChunksAndShortFinalWriteRoundTripExactlyAtBothCaptureRates() throws {
        let count = 16_384 * 3 + 137
        let samples: [Float] = (0..<count).map { index in Float(index % 1024 - 512) / 512 }
        let url = directory.appendingPathComponent("audio.wav")
        for rate in [16_000.0, 48_000.0] {
            // The second pass also exercises atomic replacement of an existing file.
            try RetainedAudioFile.write(samples: samples, sampleRate: rate, to: url)
            try assertAudio(url, sampleRate: rate, count: samples.count) { index in samples[index] }
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["audio.wav"])
        }
    }

    func testLongNativeRecordingHasExactFramesAndContent() throws {
        let count = 48_000 * 310 + 7
        let samples: [Float] = (0..<count).map { index in Float(index % 257 - 128) / 128 }
        let url = directory.appendingPathComponent("long.wav")
        try RetainedAudioFile.write(samples: samples, sampleRate: 48_000, to: url)
        try assertAudio(url, sampleRate: 48_000, count: count) { index in samples[index] }
    }

    func testEmptyInputPublishesReadableEmptyWAV() throws {
        let url = directory.appendingPathComponent("empty.wav")
        try RetainedAudioFile.write(samples: [], sampleRate: 16_000, to: url)
        try assertAudio(url, sampleRate: 16_000, count: 0) { _ in XCTFail("Unexpected frame"); return 0 }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["empty.wav"])
    }

    func testInvalidRatesKeepExistingDestinationAndRemoveStagingFiles() throws {
        let url = directory.appendingPathComponent("existing.wav")
        let original = Data("existing fixture".utf8)
        try original.write(to: url)
        for rate in [Double.nan, .infinity, 0, -1] {
            XCTAssertThrowsError(try RetainedAudioFile.write(samples: [0.1], sampleRate: rate, to: url))
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.wav"])
        }
    }

    func testWriteAndPublicationFailuresThrowWithoutPublishingPartialAudio() throws {
        let missing = directory.appendingPathComponent("missing/audio.wav")
        XCTAssertThrowsError(try RetainedAudioFile.write(samples: [0.1], sampleRate: 16_000, to: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        // A valid sibling staging file can be written, but the final name
        // exceeds the filesystem's component limit and cannot be published.
        let destination = directory.appendingPathComponent(String(repeating: "a", count: 300) + ".wav")
        let marker = directory.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: marker)
        XCTAssertThrowsError(try RetainedAudioFile.write(samples: [0.2], sampleRate: 16_000, to: destination))
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["keep"])
    }

    private func assertAudio(
        _ url: URL, sampleRate: Double, count: Int, sampleAt: (Int) -> Float,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let audio = try AVAudioFile(forReading: url)
        XCTAssertEqual(audio.fileFormat.sampleRate, sampleRate, file: file, line: line)
        XCTAssertEqual(audio.fileFormat.channelCount, 1, file: file, line: line)
        XCTAssertEqual(audio.length, AVAudioFramePosition(count), file: file, line: line)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096))
        var offset = 0
        while offset < count {
            try audio.read(into: buffer)
            let read = Int(buffer.frameLength)
            guard read > 0 else { XCTFail("Unexpected end of WAV", file: file, line: line); return }
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0..<read where channel[index] != sampleAt(offset + index) {
                XCTFail("Sample differs at frame \(offset + index)", file: file, line: line)
                return
            }
            offset += read
        }
        XCTAssertEqual(offset, count, file: file, line: line)
    }
}
