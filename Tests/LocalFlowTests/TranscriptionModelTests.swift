import XCTest
@testable import LocalFlow

final class TranscriptionModelTests: XCTestCase {
    func testIDsAreUnique() {
        let ids = TranscriptionModel.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testDefaultIsSelectable() {
        XCTAssertTrue(TranscriptionModel.all.contains { $0.id == TranscriptionModel.defaultID })
        XCTAssertEqual(Settings.defaultWhisperModel, TranscriptionModel.defaultID)
    }

    func testEngineForParakeetID() {
        XCTAssertEqual(TranscriptionModel.engine(forID: TranscriptionModel.parakeetV3ID), .parakeet)
    }

    func testParakeetIsSelectableUnderItsOwnGroup() {
        let parakeet = TranscriptionModel.all.first { $0.id == TranscriptionModel.parakeetV3ID }
        XCTAssertEqual(parakeet?.engine, .parakeet)
        XCTAssertEqual(TranscriptionModel.groups, ["Whisper", "Parakeet"])
    }

    func testEngineForWhisperID() {
        XCTAssertEqual(TranscriptionModel.engine(forID: "openai_whisper-small.en"), .whisper)
    }

    func testUnknownIDIsTreatedAsWhisperRegistryName() {
        XCTAssertEqual(TranscriptionModel.engine(forID: "test"), .whisper)
        XCTAssertEqual(TranscriptionModel.engine(forID: "openai_whisper-medium"), .whisper)
    }

    func testSettingsListMatchesModels() {
        XCTAssertEqual(Settings.whisperModels.map(\.name), TranscriptionModel.all.map(\.id))
        XCTAssertEqual(Settings.whisperModels.map(\.label), TranscriptionModel.all.map(\.label))
    }

    func testIncrementalCadenceFollowsEngine() {
        XCTAssertEqual(IncrementalCadence.forModel(TranscriptionModel.defaultID), .whisper)
        XCTAssertEqual(IncrementalCadence.forModel(TranscriptionModel.parakeetV3ID), .parakeet)
        XCTAssertEqual(IncrementalCadence.forModel("not-a-model"), .whisper)
        XCTAssertEqual(IncrementalCadence.whisper.startSeconds, 8)
        XCTAssertEqual(IncrementalCadence.whisper.tickSeconds, 4)
        XCTAssertEqual(IncrementalCadence.parakeet, IncrementalCadence(
            startSeconds: 4, tickSeconds: 2, previewTickSeconds: 1, previewStartSeconds: 1
        ))
    }

    func testBothEnginesPreviewBeforeTheirFirstCommittedChunk() {
        for cadence in [IncrementalCadence.whisper, .parakeet] {
            XCTAssertNotNil(cadence.previewTickSeconds)
            XCTAssertLessThanOrEqual(cadence.firstSnapshotSeconds, 1)
            XCTAssertLessThanOrEqual(cadence.snapshotSeconds, 1)
            XCTAssertLessThan(cadence.firstSnapshotSeconds, cadence.startSeconds)
        }
    }

    func testDisablingLiveTranscriptKeepsChunkCadenceWithoutPreviewWork() {
        for model in [TranscriptionModel.defaultID, TranscriptionModel.parakeetV3ID] {
            let enabled = IncrementalCadence.forModel(model)
            let disabled = IncrementalCadence.forModel(model, liveTranscript: false)
            XCTAssertNil(disabled.previewTickSeconds)
            XCTAssertEqual(disabled.startSeconds, enabled.startSeconds)
            XCTAssertEqual(disabled.tickSeconds, enabled.tickSeconds)
            XCTAssertEqual(disabled.firstSnapshotSeconds, enabled.startSeconds)
            XCTAssertEqual(disabled.snapshotSeconds, enabled.tickSeconds)
        }
    }
}
