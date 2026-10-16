import AVFoundation
import XCTest
@testable import LocalFlow

final class AudioCaptureLifecycleTests: XCTestCase {
    func testDelayedBoundedSnapshotDrainsLongCaptureAndPreservesReleaseTail() {
        let input = SyntheticCaptureInput()
        let recorder = AudioRecorder(makeCaptureSession: input.open)
        let started = expectation(description: "started")
        recorder.start(retainNativeAudio: true) { error in
            XCTAssertNil(error)
            started.fulfill()
        }
        wait(for: [started], timeout: 2)
        let source = input.latestSource!
        let count = Int(AudioRecorder.sampleRate * 300)
        let first = [Float](repeating: 0.1, count: count / 2)
        let second = [Float](repeating: 0.2, count: count / 2)
        let blocked = expectation(description: "conversion blocked")
        let allowConversion = DispatchSemaphore(value: 0)
        source.queue.async {
            blocked.fulfill()
            _ = allowConversion.wait(timeout: .now() + 3)
        }
        wait(for: [blocked], timeout: 2)
        source.send(converted: first, native: [0.3])
        source.send(converted: second, native: [0.4])
        let captured = expectation(description: "bounded snapshot after queued samples")
        let premature = expectation(description: "snapshot waits for queued conversion")
        premature.isInverted = true
        var conversionReleased = false
        var retained: AudioRecorder.Snapshot?
        recorder.snapshot(range: { max(0, $0 - 64)..<$0 }) { snapshot in
            if !conversionReleased { premature.fulfill() }
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(snapshot.sampleOffset, count - 64)
            XCTAssertEqual(snapshot.endIndex, count)
            XCTAssertEqual(snapshot.samples, [Float](repeating: 0.2, count: 64))
            retained = snapshot
            captured.fulfill()
        }
        wait(for: [premature], timeout: 0.05)
        conversionReleased = true
        allowConversion.signal()
        wait(for: [captured], timeout: 3)
        let tail = [Float](repeating: 0.5, count: 97)
        source.send(converted: tail, native: [0.6])
        let ranged = expectation(description: "absolute range includes new tail")
        recorder.snapshot(range: { _ in (count - 16)..<(count + tail.count) }) { snapshot in
            XCTAssertEqual(snapshot.sampleOffset, count - 16)
            XCTAssertEqual(snapshot.samples, [Float](repeating: 0.2, count: 16) + tail)
            XCTAssertEqual(retained?.samples, [Float](repeating: 0.2, count: 64))
            XCTAssertEqual(retained?.endIndex, count)
            ranged.fulfill()
        }
        let stopped = expectation(description: "complete original and tail at release")
        recorder.stop { recording in
            XCTAssertEqual(recording.samples.count, count + tail.count)
            XCTAssertEqual(Array(recording.samples.prefix(first.count)), first)
            XCTAssertEqual(Array(recording.samples[first.count..<count]), second)
            XCTAssertEqual(Array(recording.samples.suffix(tail.count)), tail)
            XCTAssertEqual(recording.nativeAudio?.samples, [0.3, 0.4, 0.6])
            stopped.fulfill()
        }
        wait(for: [ranged, stopped], timeout: 3)
    }

    func testSnapshotsClampRangesAndDetachEvenFullCaptureStorage() {
        let input = SyntheticCaptureInput()
        let recorder = AudioRecorder(makeCaptureSession: input.open)
        let started = expectation(description: "started")
        recorder.start { _ in started.fulfill() }
        wait(for: [started], timeout: 2)
        input.latestSource!.send(converted: [0.1, 0.2], native: [])
        input.latestSource!.send(converted: [0.3, 0.4], native: [])
        var first: AudioRecorder.Snapshot?
        let firstCopy = expectation(description: "first detached copy")
        recorder.snapshot(range: { _ in -10..<100 }) { snapshot in
            XCTAssertEqual(snapshot.sampleOffset, 0)
            XCTAssertEqual(snapshot.samples, [0.1, 0.2, 0.3, 0.4])
            first = snapshot
            firstCopy.fulfill()
        }
        wait(for: [firstCopy], timeout: 2)
        let secondCopy = expectation(description: "second detached copy")
        recorder.snapshot { snapshot in
            first!.samples.withUnsafeBufferPointer { firstBuffer in
                snapshot.samples.withUnsafeBufferPointer { secondBuffer in
                    XCTAssertNotEqual(firstBuffer.baseAddress, secondBuffer.baseAddress)
                }
            }
            secondCopy.fulfill()
        }
        let beyondEnd = expectation(description: "range beyond capture is empty")
        recorder.snapshot(range: { _ in 100..<200 }) { snapshot in
            XCTAssertEqual(snapshot.sampleOffset, 4)
            XCTAssertTrue(snapshot.samples.isEmpty)
            beyondEnd.fulfill()
        }
        let stopped = expectation(description: "stopped")
        recorder.stop { _ in stopped.fulfill() }
        let idle = expectation(description: "snapshot after stop is empty")
        recorder.snapshot { snapshot in
            XCTAssertEqual(snapshot.endIndex, 0)
            XCTAssertTrue(snapshot.samples.isEmpty)
            idle.fulfill()
        }
        wait(for: [secondCopy, beyondEnd, stopped, idle], timeout: 2)
    }

    func testStopDrainsQueuedTailAndHandsOffBothFormatsTogether() {
        let input = SyntheticCaptureInput()
        let recorder = AudioRecorder(makeCaptureSession: input.open)
        let started = expectation(description: "started")
        recorder.start(retainNativeAudio: true) { error in
            XCTAssertNil(error)
            started.fulfill()
        }
        wait(for: [started], timeout: 2)
        let source = input.latestSource!
        let conversionBlocked = expectation(description: "conversion queue blocked")
        let allowConversion = DispatchSemaphore(value: 0)
        source.queue.async {
            conversionBlocked.fulfill()
            _ = allowConversion.wait(timeout: .now() + 3)
        }
        wait(for: [conversionBlocked], timeout: 2)
        source.send(converted: [0.1, 0.2], native: [0.3, 0.4, 0.5])
        source.send(converted: [0.6, 0.7], native: [0.8, 0.9])
        let stopped = expectation(description: "stopped")
        let prematureHandoff = expectation(description: "handoff must wait for queued conversion")
        prematureHandoff.isInverted = true
        var conversionReleased = false
        recorder.stop { recording in
            if !conversionReleased { prematureHandoff.fulfill() }
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(recording.startError)
            XCTAssertEqual(recording.samples, [0.1, 0.2, 0.6, 0.7])
            XCTAssertEqual(recording.nativeAudio?.samples, [0.3, 0.4, 0.5, 0.8, 0.9])
            XCTAssertEqual(recording.nativeAudio?.sampleRate, 48_000)
            XCTAssertEqual(recording.nativeAudio?.isComplete, true)
            stopped.fulfill()
        }
        wait(for: [prematureHandoff], timeout: 0.05)
        conversionReleased = true
        allowConversion.signal()
        wait(for: [stopped], timeout: 2)
    }

    func testStopHandsOffBeforeHardwareTeardownFinishesAndNextStartWaits() {
        let input = SyntheticCaptureInput()
        let teardownEntered = expectation(description: "teardown entered")
        let allowTeardown = DispatchSemaphore(value: 0)
        input.onStop = {
            teardownEntered.fulfill()
            _ = allowTeardown.wait(timeout: .now() + 3)
        }
        let recorder = AudioRecorder(makeCaptureSession: input.open)
        let started = expectation(description: "started")
        recorder.start { _ in started.fulfill() }
        wait(for: [started], timeout: 2)
        let oldSource = input.latestSource!
        oldSource.send(converted: [0.1], native: [])
        oldSource.send(converted: [0.2], native: [])
        let handedOff = expectation(description: "handoff during teardown")
        recorder.stop { recording in
            XCTAssertEqual(recording.samples, [0.1, 0.2])
            XCTAssertNil(recording.nativeAudio)
            handedOff.fulfill()
        }
        let nextStarted = expectation(description: "next recording started")
        recorder.start(retainNativeAudio: true) { error in
            XCTAssertNil(error)
            nextStarted.fulfill()
        }
        wait(for: [teardownEntered, handedOff], timeout: 2)
        XCTAssertEqual(input.openCount, 1)
        input.onStop = nil
        allowTeardown.signal()
        wait(for: [nextStarted], timeout: 2)

        // Late callbacks from the old input cannot wake or contaminate the
        // replacement recording, even though they use the same sample queue.
        oldSource.send(converted: [0.9], native: [0.9])
        oldSource.send(converted: [0.9], native: [0.9])
        input.latestSource!.send(converted: [0.3], native: [0.4])
        input.latestSource!.send(converted: [0.5], native: [0.6])
        let nextStopped = expectation(description: "next stopped")
        recorder.stop { recording in
            XCTAssertEqual(recording.samples, [0.3, 0.5])
            XCTAssertEqual(recording.nativeAudio?.samples, [0.4, 0.6])
            nextStopped.fulfill()
        }
        wait(for: [nextStopped], timeout: 2)
    }

    func testFailedStartBelongsToItsQueuedStopAndDoesNotLeakIntoNextRecording() {
        let input = SyntheticCaptureInput()
        input.failStart = true
        let recorder = AudioRecorder(makeCaptureSession: input.open)
        let failed = expectation(description: "failed start")
        recorder.start(retainNativeAudio: true) { error in
            XCTAssertNotNil(error)
            failed.fulfill()
        }
        let stopped = expectation(description: "failed recording handoff")
        recorder.stop { recording in
            XCTAssertNotNil(recording.startError)
            XCTAssertTrue(recording.samples.isEmpty)
            XCTAssertNil(recording.nativeAudio)
            stopped.fulfill()
        }
        wait(for: [failed, stopped], timeout: 3)
        input.failStart = false
        let started = expectation(description: "next start")
        recorder.start { error in
            XCTAssertNil(error)
            started.fulfill()
        }
        wait(for: [started], timeout: 2)
        let nextStopped = expectation(description: "next handoff")
        recorder.stop { recording in
            XCTAssertNil(recording.startError)
            nextStopped.fulfill()
        }
        wait(for: [nextStopped], timeout: 2)
    }

    func testStartupRuntimeFailureRebuildsWithinBudgetAndIgnoresReplacedInput() {
        let input = SyntheticCaptureInput()
        let clock = CaptureHealthClock()
        let recorder = healthRecorder(input, clock)
        startRecorder(recorder)
        let original = input.latestSource!
        original.send(converted: [0], native: [0])
        drain(recorder)
        original.fail()
        drain(recorder)
        clock.tick()
        XCTAssertTrue(drain(recorder).samples.isEmpty)
        XCTAssertEqual(input.openCount, 2)
        XCTAssertEqual(input.stopCount, 1)
        let replacement = input.latestSource!
        XCTAssertFalse(original === replacement)
        original.fail()
        original.send(converted: [0.9], native: [0.9])
        replacement.send(converted: [0.5], native: [0.6])
        replacement.send(converted: [0.7], native: [0.8])
        XCTAssertEqual(drain(recorder).samples, [0.5, 0.7])
        XCTAssertEqual(input.openCount, 2)
        let recording = stopRecorder(recorder)
        XCTAssertNil(recording.startError)
        XCTAssertEqual(recording.samples, [0.5, 0.7])
        XCTAssertEqual(recording.nativeAudio?.isComplete, false)
    }

    func testTerminalStartupSilenceDiscardsBuffersAndNotifiesExactlyOnce() {
        let input = SyntheticCaptureInput()
        let clock = CaptureHealthClock()
        let recorder = healthRecorder(input, clock, policy: .init(startupSilentChecks: 0))
        recorder.keepWarm = true
        let id = UUID()
        var failures: [AudioRecorder.RuntimeFailure] = []
        startRecorder(recorder, id: id) { failures.append($0) }
        let source = input.latestSource!
        source.send(converted: [0], native: [0.2])
        source.send(converted: [0.1], native: [0.3]) // parked first syllable
        drain(recorder)
        let staleCheck = clock.takeCheck()
        staleCheck()
        XCTAssertTrue(drain(recorder).samples.isEmpty)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.recordingID, id)
        XCTAssertEqual(input.stopCount, 1)
        staleCheck()
        source.fail()
        source.send(converted: [0.8], native: [0.8])
        source.send(converted: [0.9], native: [0.9])
        XCTAssertTrue(drain(recorder).samples.isEmpty)
        XCTAssertEqual(failures.count, 1)
        let released = stopRecorder(recorder)
        XCTAssertNotNil(released.startError)
        XCTAssertTrue(released.samples.isEmpty)
        XCTAssertNil(released.nativeAudio)
        XCTAssertTrue(stopRecorder(recorder).samples.isEmpty)
        XCTAssertEqual(input.stopCount, 1)
    }

    func testRuntimeFailureAfterLiveDiscardsAudioBeforeBlockingTeardownAndReleaseIsSafe() {
        let input = SyntheticCaptureInput()
        let clock = CaptureHealthClock()
        let recorder = healthRecorder(input, clock)
        var failures: [AudioRecorder.RuntimeFailure] = []
        startRecorder(recorder) { failures.append($0) }
        let source = input.latestSource!
        source.send(converted: [0.1], native: [0.2])
        source.send(converted: [0.3], native: [0.4])
        XCTAssertEqual(drain(recorder).samples, [0.1, 0.3])
        let teardownEntered = expectation(description: "terminal teardown entered")
        let resumeTeardown = DispatchSemaphore(value: 0)
        input.onStop = {
            teardownEntered.fulfill()
            _ = resumeTeardown.wait(timeout: .now() + 3)
        }
        source.fail()
        wait(for: [teardownEntered], timeout: 2)
        // Failure invalidates the input before hardware shutdown returns.
        source.send(converted: [0.8], native: [0.8])
        source.send(converted: [0.9], native: [0.9])
        source.queue.sync {}
        XCTAssertTrue(failures.isEmpty, "Notification follows completed teardown")
        input.onStop = nil
        resumeTeardown.signal()
        XCTAssertTrue(drain(recorder).samples.isEmpty)
        source.fail()
        clock.tick()
        let recording = stopRecorder(recorder)
        XCTAssertNotNil(recording.startError)
        XCTAssertTrue(recording.samples.isEmpty)
        XCTAssertNil(recording.nativeAudio)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(input.stopCount, 1)
    }

    func testFailedSetupDiscardsAlreadyDeliveredAudioAndQueuedRuntimeFailure() {
        let input = SyntheticCaptureInput()
        input.onOpen = { source in
            source.send(converted: [0.1], native: [0.2])
            source.send(converted: [0.3], native: [0.4])
            source.queue.sync {}
            source.fail()
            throw AudioRecorder.RecorderError.noInput
        }
        let recorder = AudioRecorder(makeCaptureSession: input.open)
        let failed = expectation(description: "setup failure")
        var runtimeFailures = 0
        recorder.start(retainNativeAudio: true, onRuntimeFailure: { _ in runtimeFailures += 1 }) { error in
            XCTAssertNotNil(error)
            failed.fulfill()
        }
        wait(for: [failed], timeout: 3)
        XCTAssertTrue(drain(recorder).samples.isEmpty)
        let recording = stopRecorder(recorder)
        XCTAssertTrue(recording.samples.isEmpty)
        XCTAssertNil(recording.nativeAudio)
        XCTAssertNotNil(recording.startError)
        XCTAssertEqual(runtimeFailures, 0, "Setup reports only through completion")
        input.onOpen = nil
        startRecorder(recorder)
        XCTAssertNil(stopRecorder(recorder).startError)
    }

    func testStaleHealthCheckAndCallbacksCannotFailNewRecording() {
        let input = SyntheticCaptureInput()
        let clock = CaptureHealthClock()
        let recorder = healthRecorder(input, clock)
        let oldID = UUID()
        var oldFailures: [AudioRecorder.RuntimeFailure] = []
        startRecorder(recorder, id: oldID) { oldFailures.append($0) }
        let oldSource = input.latestSource!
        let staleCheck = clock.takeCheck()
        oldSource.send(converted: [0.1], native: [0.2])
        oldSource.send(converted: [0.3], native: [0.4])
        drain(recorder)
        oldSource.fail()
        drain(recorder)
        XCTAssertEqual(oldFailures.map(\.recordingID), [oldID])
        var newFailures = 0
        startRecorder(recorder) { _ in newFailures += 1 }
        let source = input.latestSource!
        source.send(converted: [0.5], native: [0.6])
        source.send(converted: [0.7], native: [0.8])
        oldSource.fail()
        oldSource.sendConversionFailure()
        oldSource.send(converted: [0.9], native: [0.9])
        staleCheck()
        XCTAssertEqual(drain(recorder).samples, [0.5, 0.7])
        XCTAssertEqual(newFailures, 0)
        XCTAssertEqual(oldFailures.count, 1)
        let recording = stopRecorder(recorder)
        XCTAssertNil(recording.startError)
        XCTAssertEqual(recording.samples, [0.5, 0.7])
        XCTAssertEqual(recording.nativeAudio?.samples, [0.6, 0.8])
    }

    func testMissingBuffersAfterLiveFailAtInjectedDeadline() {
        let input = SyntheticCaptureInput()
        let clock = CaptureHealthClock()
        let recorder = healthRecorder(input, clock)
        var failures: [AudioRecorder.RuntimeFailure] = []
        startRecorder(recorder) { failures.append($0) }
        input.latestSource!.send(converted: [0.1], native: [0.2])
        input.latestSource!.send(converted: [0.3], native: [0.4])
        drain(recorder)
        clock.advance(by: 2)
        clock.tick()
        XCTAssertEqual(drain(recorder).samples, [0.1, 0.3])
        XCTAssertTrue(failures.isEmpty)
        clock.advance(by: 1)
        clock.tick()
        XCTAssertTrue(drain(recorder).samples.isEmpty)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.error as? AudioRecorder.RecorderError, .streamStopped)
        XCTAssertEqual(input.openCount, 1, "Live gaps never join a replacement to partial speech")
        XCTAssertTrue(stopRecorder(recorder).samples.isEmpty)
    }

    func testConversionErrorsAfterLiveFailAtInjectedLimit() {
        let input = SyntheticCaptureInput()
        let clock = CaptureHealthClock()
        let recorder = healthRecorder(input, clock)
        var failures: [AudioRecorder.RuntimeFailure] = []
        startRecorder(recorder) { failures.append($0) }
        let source = input.latestSource!
        source.send(converted: [0.1], native: [0.2])
        source.send(converted: [0.3], native: [0.4])
        drain(recorder)
        source.sendConversionFailure()
        drain(recorder)
        clock.tick()
        drain(recorder)
        XCTAssertTrue(failures.isEmpty)
        source.sendConversionFailure()
        source.sendConversionFailure()
        drain(recorder)
        clock.tick()
        XCTAssertTrue(drain(recorder).samples.isEmpty)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.error as? AudioRecorder.RecorderError, .conversionFailed)
        let recording = stopRecorder(recorder)
        XCTAssertNotNil(recording.startError)
        XCTAssertNil(recording.nativeAudio)
    }

    func testRawBuffersWithoutConvertedProgressFailEvenWithoutErrorStreak() {
        let input = SyntheticCaptureInput()
        let clock = CaptureHealthClock()
        let recorder = healthRecorder(input, clock)
        var failures: [AudioRecorder.RuntimeFailure] = []
        startRecorder(recorder) { failures.append($0) }
        let source = input.latestSource!
        source.send(converted: [0.1], native: [0.2])
        source.send(converted: [0.3], native: [0.4])
        drain(recorder)
        for _ in 0..<3 {
            clock.advance(by: 1)
            source.sendRawOnly()
            drain(recorder)
            clock.tick()
            drain(recorder)
        }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.error as? AudioRecorder.RecorderError, .conversionFailed)
        XCTAssertTrue(stopRecorder(recorder).samples.isEmpty)
    }

    func testSilenceAfterLiveRemainsHealthyAndPreservesFirstSyllableAndOriginals() {
        let input = SyntheticCaptureInput()
        let clock = CaptureHealthClock()
        let recorder = healthRecorder(input, clock)
        var failures = 0
        startRecorder(recorder) { _ in failures += 1 }
        let source = input.latestSource!
        source.send(converted: [0], native: [0])
        source.send(converted: [0.01], native: [0.02])
        source.send(converted: [0.03], native: [0.04])
        drain(recorder)
        for _ in 0..<12 {
            clock.advance(by: 1)
            source.send(converted: [0], native: [0])
            drain(recorder)
            clock.tick()
            drain(recorder)
        }
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(input.openCount, 1)
        let recording = stopRecorder(recorder)
        XCTAssertNil(recording.startError)
        XCTAssertEqual(recording.samples, [0.01, 0.03] + Array(repeating: 0, count: 12))
        XCTAssertEqual(recording.nativeAudio?.samples, [0, 0.02, 0.04] + Array(repeating: 0, count: 12))
        XCTAssertEqual(recording.nativeAudio?.isComplete, true)
    }

    func testReleaseChecksHealthBeforeTimerAndNeverHandsOffIncompleteAudio() {
        let input = SyntheticCaptureInput()
        let clock = CaptureHealthClock()
        let recorder = healthRecorder(input, clock)
        var failures = 0
        startRecorder(recorder) { _ in failures += 1 }
        input.latestSource!.send(converted: [0.1], native: [0.2])
        input.latestSource!.send(converted: [0.3], native: [0.4])
        drain(recorder)
        clock.advance(by: 3)
        let recording = stopRecorder(recorder)
        XCTAssertTrue(recording.samples.isEmpty)
        XCTAssertNil(recording.nativeAudio)
        XCTAssertNotNil(recording.startError)
        XCTAssertEqual(failures, 1)
        clock.tick()
        drain(recorder)
        XCTAssertEqual(failures, 1)
    }

    func testStartupMissingBuffersUsesFiniteRebuildBudget() {
        let input = SyntheticCaptureInput()
        let clock = CaptureHealthClock()
        let recorder = healthRecorder(input, clock, policy: .init(startupRebuilds: 1))
        var failures = 0
        startRecorder(recorder) { _ in failures += 1 }
        clock.tick()
        drain(recorder)
        XCTAssertEqual(input.openCount, 2)
        XCTAssertEqual(failures, 0)
        input.latestSource!.fail()
        input.latestSource!.fail()
        drain(recorder)
        clock.tick()
        drain(recorder)
        XCTAssertEqual(input.openCount, 2)
        XCTAssertEqual(failures, 1)
        XCTAssertNotNil(stopRecorder(recorder).startError)
    }

    func testLateBuffersCannotEraseAHealthFailureBeforeTheNextCheck() {
        for conversionFailure in [false, true] {
            let input = SyntheticCaptureInput()
            let clock = CaptureHealthClock()
            let recorder = healthRecorder(input, clock)
            var failures = 0
            startRecorder(recorder) { _ in failures += 1 }
            let source = input.latestSource!
            source.send(converted: [0.1], native: [0.2])
            source.send(converted: [0.3], native: [0.4])
            drain(recorder)
            if conversionFailure {
                for _ in 0..<3 { source.sendConversionFailure() }
            } else {
                clock.advance(by: 3)
            }
            source.send(converted: [0.5], native: [0.6])
            source.send(converted: [0.7], native: [0.8])
            drain(recorder)
            let recording = stopRecorder(recorder)
            XCTAssertNotNil(recording.startError)
            XCTAssertTrue(recording.samples.isEmpty)
            XCTAssertNil(recording.nativeAudio)
            XCTAssertEqual(failures, 1)
        }
    }

    func testFailedStartupRebuildPerformsTerminalCleanupWithoutRelease() {
        let input = SyntheticCaptureInput()
        let clock = CaptureHealthClock()
        let recorder = healthRecorder(input, clock)
        var failures = 0
        startRecorder(recorder) { _ in failures += 1 }
        input.failStart = true
        clock.tick()
        XCTAssertTrue(drain(recorder).samples.isEmpty)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(input.stopCount, 1)
        XCTAssertNil(stopRecorder(recorder).nativeAudio)
        input.failStart = false
        startRecorder(recorder)
        XCTAssertNil(stopRecorder(recorder).startError)
    }

    func testQueuedSnapshotCannotStartRecognitionWhileTerminalTeardownBlocks() {
        let input = SyntheticCaptureInput()
        let clock = CaptureHealthClock()
        let recorder = healthRecorder(input, clock)
        let id = UUID()
        var failures = 0
        startRecorder(recorder, id: id) { _ in failures += 1 }
        let source = input.latestSource!
        source.send(converted: [0.1], native: [0.2])
        source.send(converted: [0.3], native: [0.4])
        drain(recorder)
        XCTAssertTrue(recorder.isCaptureActive(recordingID: id))
        XCTAssertFalse(recorder.isCaptureActive(recordingID: UUID()))
        let teardownEntered = DispatchSemaphore(value: 0)
        let resumeTeardown = DispatchSemaphore(value: 0)
        input.onStop = {
            teardownEntered.signal()
            _ = resumeTeardown.wait(timeout: .now() + 3)
        }
        let snapshotDelivered = expectation(description: "queued snapshot delivered during teardown")
        var recognitionCalls = 0
        recorder.snapshot { snapshot in
            XCTAssertEqual(snapshot.samples, [0.1, 0.3], "E4 detached copies stay intact")
            if recorder.isCaptureActive(recordingID: id) { recognitionCalls += 1 }
            snapshotDelivered.fulfill()
        }
        source.fail()
        // Keep main blocked until failure owns the recorder, then deliver
        // the snapshot before shutdown can deliver the UI failure callback.
        XCTAssertEqual(teardownEntered.wait(timeout: .now() + 2), .success)
        wait(for: [snapshotDelivered], timeout: 2)
        XCTAssertEqual(recognitionCalls, 0)
        XCTAssertEqual(failures, 0)
        input.onStop = nil
        resumeTeardown.signal()
        XCTAssertTrue(drain(recorder).samples.isEmpty)
        XCTAssertEqual(failures, 1)
        XCTAssertNotNil(stopRecorder(recorder).startError)
    }

    func testReleaseAfterPreLiveRuntimeErrorDiscardsNativePrefixAndReportsFailure() {
        let input = SyntheticCaptureInput()
        let clock = CaptureHealthClock()
        let recorder = healthRecorder(input, clock)
        var failures = 0
        startRecorder(recorder) { _ in failures += 1 }
        input.latestSource!.send(converted: [0.1], native: [0.2])
        XCTAssertTrue(drain(recorder).samples.isEmpty, "First audible buffer is still parked")
        input.latestSource!.fail()
        let recording = stopRecorder(recorder)
        XCTAssertNotNil(recording.startError)
        XCTAssertTrue(recording.samples.isEmpty)
        XCTAssertNil(recording.nativeAudio)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(input.openCount, 1, "Release ends the hold instead of starting recovery")
        clock.tick()
        drain(recorder)
        XCTAssertEqual(failures, 1)
    }

    private func healthRecorder(
        _ input: SyntheticCaptureInput, _ clock: CaptureHealthClock,
        policy: AudioRecorder.HealthPolicy = .init()
    ) -> AudioRecorder {
        var policy = policy
        policy.progressTimeout = 3
        policy.conversionFailureLimit = 3
        return AudioRecorder(makeCaptureSession: input.open, healthPolicy: policy,
                             now: { clock.now }, scheduleHealthCheck: clock.schedule)
    }

    private func startRecorder(
        _ recorder: AudioRecorder, id: UUID = UUID(),
        onFailure: @escaping (AudioRecorder.RuntimeFailure) -> Void = { _ in XCTFail("Unexpected terminal failure") }
    ) {
        let started = expectation(description: "started synthetic recording")
        recorder.start(recordingID: id, retainNativeAudio: true, onRuntimeFailure: { failure in
            DispatchQueue.main.async { onFailure(failure) }
        }) { error in
            XCTAssertNil(error)
            started.fulfill()
        }
        wait(for: [started], timeout: 3)
    }

    @discardableResult
    private func drain(_ recorder: AudioRecorder) -> AudioRecorder.Snapshot {
        let drained = expectation(description: "control and samples drained")
        var result: AudioRecorder.Snapshot?
        recorder.snapshot { result = $0; drained.fulfill() }
        wait(for: [drained], timeout: 3)
        return result!
    }

    private func stopRecorder(_ recorder: AudioRecorder) -> AudioRecorder.Recording {
        let stopped = expectation(description: "released synthetic recording")
        var result: AudioRecorder.Recording?
        recorder.stop { result = $0; stopped.fulfill() }
        wait(for: [stopped], timeout: 3)
        return result!
    }

    func testSnapshotDoesNotDetachNativeAudioOrDiscardLaterSamples() {
        let input = SyntheticCaptureInput()
        let recorder = AudioRecorder(makeCaptureSession: input.open)
        let started = expectation(description: "started")
        recorder.start(retainNativeAudio: true) { _ in started.fulfill() }
        wait(for: [started], timeout: 2)
        let source = input.latestSource!
        source.send(converted: [0.1], native: [0.2])
        source.send(converted: [0.3], native: [0.4])
        let snapshotted = expectation(description: "snapshot")
        recorder.snapshot { snapshot in
            let samples = snapshot.samples
            XCTAssertEqual(samples, [0.1, 0.3])
            snapshotted.fulfill()
        }
        wait(for: [snapshotted], timeout: 2)
        source.send(converted: [0.5], native: [0.6])
        let stopped = expectation(description: "stopped")
        recorder.stop { recording in
            XCTAssertEqual(recording.samples, [0.1, 0.3, 0.5])
            XCTAssertEqual(recording.nativeAudio?.samples, [0.2, 0.4, 0.6])
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 2)
    }
}

/// Supplies buffers at the same queue seam as AVCaptureAudioDataOutput.
/// Recording state, live gating, draining, and handoff all remain in AudioRecorder.
private final class SyntheticCaptureInput {
    final class Source {
        let queue: DispatchQueue
        let onRaw: (AVAudioPCMBuffer?) -> Void
        let onPCM: (AVAudioPCMBuffer?) -> Void
        let onFailure: () -> Void

        init(queue: DispatchQueue, onRaw: @escaping (AVAudioPCMBuffer?) -> Void,
             onPCM: @escaping (AVAudioPCMBuffer?) -> Void,
             onFailure: @escaping () -> Void) {
            self.queue = queue
            self.onRaw = onRaw
            self.onPCM = onPCM
            self.onFailure = onFailure
        }

        func fail() { onFailure() }

        func sendConversionFailure() {
            queue.async {
                self.onRaw(Self.buffer([0.1], rate: 48_000))
                self.onPCM(nil)
            }
        }

        func sendRawOnly() {
            queue.async { self.onRaw(Self.buffer([0.1], rate: 48_000)) }
        }

        func send(converted: [Float], native: [Float]) {
            queue.async {
                self.onRaw(Self.buffer(native, rate: 48_000))
                self.onPCM(Self.buffer(converted, rate: 16_000))
            }
        }

        private static func buffer(_ samples: [Float], rate: Double) -> AVAudioPCMBuffer {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                       channels: 1, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                          frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for (index, sample) in samples.enumerated() {
                buffer.floatChannelData![0][index] = sample
            }
            return buffer
        }
    }

    private let lock = NSLock()
    private var source: Source?
    private var opens = 0
    private var stops = 0
    private var shouldFail = false
    private var stopCallback: (() -> Void)?
    var onOpen: ((Source) throws -> Void)?

    var latestSource: Source? {
        lock.lock(); defer { lock.unlock() }
        return source
    }
    var openCount: Int {
        lock.lock(); defer { lock.unlock() }
        return opens
    }
    var stopCount: Int {
        lock.lock(); defer { lock.unlock() }
        return stops
    }
    var failStart: Bool {
        get { lock.lock(); defer { lock.unlock() }; return shouldFail }
        set { lock.lock(); defer { lock.unlock() }; shouldFail = newValue }
    }
    var onStop: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stopCallback }
        set { lock.lock(); defer { lock.unlock() }; stopCallback = newValue }
    }

    func open(deviceUID: String?, fallbackToDefaultIfUnavailable: Bool,
              targetFormat: AVAudioFormat, sampleQueue: DispatchQueue,
              onRaw: @escaping (AVAudioPCMBuffer?) -> Void,
              onPCM: @escaping (AVAudioPCMBuffer?) -> Void,
              onFailure: @escaping () -> Void) throws -> AudioCaptureSession {
        lock.lock()
        opens += 1
        if shouldFail {
            lock.unlock()
            throw AudioRecorder.RecorderError.noInput
        }
        let source = Source(queue: sampleQueue, onRaw: onRaw, onPCM: onPCM, onFailure: onFailure)
        self.source = source
        lock.unlock()
        try onOpen?(source)
        return AudioCaptureSession(deviceUID: deviceUID, microphoneName: "Synthetic input",
                                   isRunning: { true }, stop: {
            self.lock.lock()
            self.stops += 1
            let callback = self.stopCallback
            self.lock.unlock()
            callback?()
        })
    }
}

/// Manual monotonic time and queued checks keep health regressions independent
/// of hardware, wall-clock sleeps, and scheduler timing.
private final class CaptureHealthClock {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var checks: [() -> Void] = []

    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return time }

    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        time += interval
    }

    func schedule(after delay: TimeInterval, check: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        checks.append(check)
    }

    func takeCheck() -> () -> Void {
        lock.lock(); defer { lock.unlock() }
        precondition(!checks.isEmpty, "Recorder must keep health monitoring armed")
        return checks.removeFirst()
    }

    func tick() { takeCheck()() }
}
