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

    func testStopSerializesDetachmentWithCallbackArrivingDuringSessionValidation() {
        let input = SyntheticCaptureInput()
        let recorder = AudioRecorder(makeCaptureSession: input.open)
        startRecorder(recorder)
        let source = input.latestSource!
        source.send(converted: [0.1], native: [0.2])
        source.send(converted: [0.3], native: [0.4])
        drain(recorder)

        let rawArrived = DispatchSemaphore(value: 0)
        let allowConversion = DispatchSemaphore(value: 0)
        let paused = expectation(description: "callback paused between raw and converted tail")
        // On the broken implementation this getter runs after the empty drain
        // barrier. Start a new callback there, before controlQueue detaches.
        input.onIsRunning = {
            source.send(converted: [0.5], native: [0.6], betweenFormats: {
                rawArrived.signal()
                paused.fulfill()
                XCTAssertEqual(allowConversion.wait(timeout: .now() + 3), .success)
            })
            XCTAssertEqual(rawArrived.wait(timeout: .now() + 2), .success)
        }
        let stopped = expectation(description: "paired handoff")
        let premature = expectation(description: "stop waits for conversion counterpart")
        premature.isInverted = true
        var conversionReleased = false
        recorder.stop { recording in
            if !conversionReleased { premature.fulfill() }
            XCTAssertNil(recording.startError)
            XCTAssertEqual(recording.samples, [0.1, 0.3, 0.5])
            XCTAssertEqual(recording.nativeAudio?.samples, [0.2, 0.4, 0.6])
            XCTAssertEqual(recording.nativeAudio?.isComplete, true)
            stopped.fulfill()
        }
        wait(for: [paused, premature], timeout: 0.1)
        input.onIsRunning = nil
        conversionReleased = true
        allowConversion.signal()
        wait(for: [stopped], timeout: 3)
        XCTAssertTrue(drain(recorder).samples.isEmpty)
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
        let failureNotified = expectation(description: "failure notified before teardown returns")
        startRecorder(recorder) { failures.append($0); failureNotified.fulfill() }
        let source = input.latestSource!
        source.send(converted: [0.1], native: [0.2])
        source.send(converted: [0.3], native: [0.4])
        XCTAssertEqual(drain(recorder).samples, [0.1, 0.3])
        let teardownEntered = expectation(description: "terminal teardown entered")
        let resumeTeardown = DispatchSemaphore(value: 0)
        defer { input.onStop = nil; resumeTeardown.signal() }
        input.onStop = {
            input.onStop = nil
            teardownEntered.fulfill()
            _ = resumeTeardown.wait(timeout: .now() + 3)
        }
        source.fail()
        wait(for: [teardownEntered, failureNotified], timeout: 2)
        // Failure invalidates the input before hardware shutdown returns.
        source.send(converted: [0.8], native: [0.8])
        source.send(converted: [0.9], native: [0.9])
        source.queue.sync {}
        XCTAssertEqual(failures.count, 1, "Notification precedes hardware teardown completion")
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
        // Terminal teardown must run outside sampleQueue, even when stop
        // discovers the failure during its serialized validation.
        let source = input.latestSource!
        input.onStop = { source.queue.sync {} }
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
        let failureNotified = expectation(description: "failure notified while teardown blocks")
        startRecorder(recorder, id: id) { _ in failures += 1; failureNotified.fulfill() }
        let source = input.latestSource!
        source.send(converted: [0.1], native: [0.2])
        source.send(converted: [0.3], native: [0.4])
        drain(recorder)
        XCTAssertTrue(recorder.isCaptureActive(recordingID: id))
        XCTAssertFalse(recorder.isCaptureActive(recordingID: UUID()))
        let teardownEntered = DispatchSemaphore(value: 0)
        let resumeTeardown = DispatchSemaphore(value: 0)
        defer { input.onStop = nil; resumeTeardown.signal() }
        input.onStop = {
            input.onStop = nil
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
        // Keep main blocked until failure invalidates the recorder. The detached
        // snapshot was queued first and must reject recognition on its own.
        XCTAssertEqual(teardownEntered.wait(timeout: .now() + 2), .success)
        wait(for: [snapshotDelivered, failureNotified], timeout: 2)
        XCTAssertEqual(recognitionCalls, 0)
        XCTAssertEqual(failures, 1, "UI failure must not wait for hardware teardown")
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

    @MainActor
    func testCaptureFailureDuringPreviewKeepsEngineWarmAndNextRecordingUsable() async throws {
        try await verifyCaptureFailureDuringInference(preview: true)
    }

    @MainActor
    func testCaptureFailureDuringChunkKeepsEngineWarmAndNextRecordingUsable() async throws {
        try await verifyCaptureFailureDuringInference(preview: false)
    }

    @MainActor
    func testCaptureFailureCancelsPreviewBeforeBlockedTeardownReturns() async throws {
        try await verifyCaptureFailureDuringInference(preview: true, holdTeardown: true)
    }

    @MainActor
    func testCaptureFailureCancelsChunkBeforeBlockedTeardownReturns() async throws {
        try await verifyCaptureFailureDuringInference(preview: false, holdTeardown: true)
    }

    @MainActor
    private func verifyCaptureFailureDuringInference(preview: Bool, holdTeardown: Bool = false) async throws {
        let engine = CaptureRecoveryEngine()
        var loads = 0
        let transcriber = Transcriber(modelLoader: { _, _ in loads += 1; return engine },
                                      abandonedInferenceGrace: 30)
        try await transcriber.load(model: "test")
        var injected: [String] = []
        var history: [String] = []
        var partials: [String] = []
        var outcomes: [DictationSessionOutcome] = []
        var requests: [DictationTranscriptionSegment] = []
        var finished: [Int] = []
        var cleanupCalls = 0
        let stalePartial = holdTeardown ? expectation(description: "failed inference must not update the HUD") : nil
        stalePartial?.isInverted = true
        let delivery = DictationDelivery(
            transcribe: { request in
                requests.append(request.segment)
                defer { finished.append(request.generation) }
                return try await transcriber.transcribe(request)
            },
            cleanup: { cleanupCalls += 1; return .init(text: $0.text, succeeded: true) },
            inject: { text, _, ready, complete in injected.append(text); ready(); complete() },
            recordTranscript: { history.append($0) },
            onOutcome: { outcome, _ in outcomes.append(outcome) },
            onPartialTranscript: { _, text in partials.append(text); stalePartial?.fulfill() },
            onCancelled: { _ in }, onCommandCancelled: { _ in },
            onProcessingCountChange: { _ in }
        )
        let context = DictationSessionContext(
            cleanupEnabled: holdTeardown, styleProfile: .general, corrections: [], snippets: [],
            incrementalCadence: preview ? .whisper : .init(startSeconds: 4, tickSeconds: 2)
        )
        let failedGeneration = delivery.begin(.init(context: context))
        let input = SyntheticCaptureInput()
        let recorder = AudioRecorder(makeCaptureSession: input.open)
        let teardownEntered = holdTeardown ? expectation(description: "failed capture entered hardware teardown") : nil
        let allowTeardown = DispatchSemaphore(value: 0)
        let teardownReturned = DispatchSemaphore(value: 0)
        if let teardownEntered {
            input.onStop = {
                input.onStop = nil // Only the failed hold blocks, never the next hold.
                teardownEntered.fulfill()
                XCTAssertEqual(allowTeardown.wait(timeout: .now() + 10), .success)
                teardownReturned.signal()
            }
        }
        defer {
            input.onStop = nil
            allowTeardown.signal()
            Task { await engine.finishAbandoned() }
        }
        let failureNotified = expectation(description: "main callback owns capture failure")
        var failures = 0
        await startRecoveryRecorder(recorder) { _ in
            XCTAssertTrue(Thread.isMainThread)
            failures += 1
            // The Python boundary checks this policy on the actual AppDelegate
            // handler, helper, and failed-release path. Here it reaches real ASR.
            delivery.cancel(generation: failedGeneration, interruptInference: false)
            failureNotified.fulfill()
        }
        let source = input.latestSource!
        let rate = Int(AudioRecorder.sampleRate)
        let speech = [Float](repeating: 0.2, count: rate)
        let initial = preview ? speech + speech
            : Array(repeating: Float(0.2), count: rate * 3)
                + Array(repeating: Float(0), count: rate)
                + Array(repeating: Float(0.2), count: rate * 4)
        source.send(converted: Array(initial.prefix(rate)), native: Array(repeating: 0.2, count: rate * 3))
        source.send(converted: Array(initial.dropFirst(rate)), native: Array(repeating: 0.2, count: (initial.count - rate) * 3))
        let initialSnapshot = try await recoverySnapshot(recorder)
        delivery.processIncrementalSnapshot(generation: failedGeneration, samples: initialSnapshot.samples)
        await captureEventually { await engine.calls == 1 }
        XCTAssertEqual(requests, [preview ? .preview : .incrementalChunk(index: 0)])

        source.fail()
        if let teardownEntered, let stalePartial {
            await fulfillment(of: [teardownEntered], timeout: 2)
            await fulfillment(of: [failureNotified], timeout: 1)
            XCTAssertEqual(failures, 1, "Failure ownership must reach main before hardware stop returns")
            XCTAssertNil(delivery.incrementalSnapshotRange(generation: failedGeneration),
                         "Failure must remove pipeline ownership before inference completes")
            XCTAssertEqual(teardownReturned.wait(timeout: .now()), .timedOut)
            await engine.finishAbandoned()
            await captureEventually { finished.contains(failedGeneration) }
            await fulfillment(of: [stalePartial], timeout: 0.05)
            XCTAssertEqual(teardownReturned.wait(timeout: .now()), .timedOut,
                           "Inference must finish while hardware teardown is still held")
            XCTAssertTrue(partials.isEmpty)
            XCTAssertTrue(outcomes.isEmpty)
            XCTAssertTrue(history.isEmpty)
            XCTAssertTrue(injected.isEmpty)
            XCTAssertEqual(cleanupCalls, 0)
            XCTAssertEqual(delivery.retryCount, 0)
            XCTAssertFalse(delivery.isBusy)
            allowTeardown.signal()
        } else {
            await fulfillment(of: [failureNotified], timeout: 2)
        }
        let loadedDuringGrace = await transcriber.isLoaded
        XCTAssertTrue(loadedDuringGrace, "Capture failure must not quarantine healthy ASR")
        let failedRecording = try await releaseRecoveryRecorder(recorder)
        XCTAssertNotNil(failedRecording.startError)
        XCTAssertTrue(failedRecording.samples.isEmpty)
        XCTAssertNil(failedRecording.nativeAudio)
        // Even a late release of the failed hold cannot revive its pipeline.
        delivery.release(generation: failedGeneration, samples: initial)
        XCTAssertTrue(injected.isEmpty)
        XCTAssertEqual(delivery.retryCount, 0, "Incomplete capture must not become retry audio")

        let next = delivery.begin(.init(context: context))
        await startRecoveryRecorder(recorder)
        input.latestSource!.send(converted: speech, native: [0.3])
        input.latestSource!.send(converted: speech, native: [0.4])
        let healthy = try await releaseRecoveryRecorder(recorder)
        XCTAssertNil(healthy.startError)
        XCTAssertEqual(healthy.samples, speech + speech)
        XCTAssertEqual(healthy.nativeAudio?.samples, [0.3, 0.4])
        XCTAssertEqual(healthy.nativeAudio?.isComplete, true)
        delivery.release(generation: next, samples: healthy.samples, nativeAudio: healthy.nativeAudio)
        if !holdTeardown {
            await captureEventually { await transcriber.waitingInferenceCount == 1 }
            await engine.finishAbandoned()
        }
        await captureEventually { finished.contains(failedGeneration) && outcomes.count == 1 }
        XCTAssertEqual(outcomes, [.finalTranscript(generation: next, text: "next healthy words")])
        XCTAssertEqual(injected, ["next healthy words"])
        XCTAssertEqual(history, injected)
        XCTAssertTrue(partials.isEmpty, "Abandoned preview/chunk must not update the HUD")
        XCTAssertFalse(delivery.isBusy)
        XCTAssertEqual(delivery.retryCount, 0)
        let loadedAfterCompletion = await transcriber.isLoaded
        XCTAssertTrue(loadedAfterCompletion)
        XCTAssertEqual(loads, 1, "The next recording must succeed without reloading")
        XCTAssertEqual(failures, 1, "Failed capture has one terminal transition")
        XCTAssertEqual(cleanupCalls, holdTeardown ? 1 : 0, "Only healthy audio may reach cleanup")
    }

    @MainActor
    private func startRecoveryRecorder(_ recorder: AudioRecorder,
                                       onFailure: @escaping (AudioRecorder.RuntimeFailure) -> Void = { _ in XCTFail("Unexpected capture failure") }) async {
        let started = expectation(description: "recovery capture started")
        recorder.start(retainNativeAudio: true, onRuntimeFailure: { failure in
            DispatchQueue.main.async { onFailure(failure) }
        }) { error in
            XCTAssertNil(error)
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 3)
    }

    @MainActor
    private func recoverySnapshot(_ recorder: AudioRecorder) async throws -> AudioRecorder.Snapshot {
        let drained = expectation(description: "recovery samples drained")
        var result: AudioRecorder.Snapshot?
        recorder.snapshot { result = $0; drained.fulfill() }
        await fulfillment(of: [drained], timeout: 3)
        return try XCTUnwrap(result)
    }

    @MainActor
    private func releaseRecoveryRecorder(_ recorder: AudioRecorder) async throws -> AudioRecorder.Recording {
        let stopped = expectation(description: "recovery capture released")
        var result: AudioRecorder.Recording?
        recorder.stop { result = $0; stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
        return try XCTUnwrap(result)
    }

    @MainActor
    private func captureEventually(_ condition: () async -> Bool,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Capture recovery condition did not become true", file: file, line: line)
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

    func testWarmIdleSkipsMetersAndWarmStartRetainsFirstQuietSyllable() {
        let input = SyntheticCaptureInput()
        let recorder = AudioRecorder(makeCaptureSession: input.open, now: { 100 })
        recorder.keepWarm = true
        var levels = 0
        var spectra = 0
        var liveCount = 0
        recorder.onLevel = { _ in levels += 1 }
        recorder.onSpectrum = { _ in spectra += 1 }
        let started = expectation(description: "cold start")
        recorder.start { _ in started.fulfill() }
        wait(for: [started], timeout: 2)
        let source = input.latestSource!
        source.send(converted: [0.1], native: [])
        source.send(converted: [0.2], native: [])
        let stopped = expectation(description: "warm stop")
        recorder.stop { recording in
            XCTAssertEqual(recording.samples, [0.1, 0.2])
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 2)
        let previousLevels = levels
        let previousSpectra = spectra
        for _ in 0..<20 { source.send(converted: [0.9], native: [0.9]) }
        let idle = expectation(description: "idle buffers drained")
        recorder.snapshot { samples in
            XCTAssertTrue(samples.samples.isEmpty)
            XCTAssertEqual(levels, previousLevels)
            XCTAssertEqual(spectra, previousSpectra)
            idle.fulfill()
        }
        wait(for: [idle], timeout: 2)
        let warmStarted = expectation(description: "warm start")
        recorder.start(retainNativeAudio: true, onCaptureLive: { liveCount += 1 }) { error in
            XCTAssertNil(error)
            warmStarted.fulfill()
        }
        wait(for: [warmStarted], timeout: 2)
        XCTAssertTrue(input.latestSource === source)
        XCTAssertEqual(input.openCount, 1)
        // Quiet speech is above digital silence and must survive the two-buffer streak.
        source.send(converted: [0.0002, 0.0003], native: [0.2])
        source.send(converted: [0.0004], native: [0.3])
        let warmStopped = expectation(description: "warm audio handoff")
        recorder.stop { recording in
            XCTAssertEqual(recording.samples, [0.0002, 0.0003, 0.0004])
            XCTAssertEqual(recording.nativeAudio?.samples, [0.2, 0.3])
            XCTAssertEqual(liveCount, 1)
            XCTAssertEqual(spectra, previousSpectra + 1)
            warmStopped.fulfill()
        }
        wait(for: [warmStopped], timeout: 2)
        recorder.releaseWarmSession()
    }

    func testSpectrumDemandAndRendererCadenceDoNotDropCapturedAudio() {
        let input = SyntheticCaptureInput()
        var now: TimeInterval = 100
        var demand = false
        let recorder = AudioRecorder(makeCaptureSession: input.open, now: { now })
        var spectra: [[Float]] = []
        var levels = 0
        recorder.onSpectrum = { spectra.append($0) }
        recorder.needsSpectrum = { demand }
        recorder.onLevel = { _ in levels += 1 }
        let started = expectation(description: "started")
        recorder.start { _ in started.fulfill() }
        wait(for: [started], timeout: 2)
        let source = input.latestSource!
        func sendAndDrain(_ count: Int) {
            for _ in 0..<count { source.send(converted: [0.1], native: []) }
            let drained = expectation(description: "buffers drained")
            recorder.snapshot { _ in drained.fulfill() }
            wait(for: [drained], timeout: 2)
        }
        sendAndDrain(10)
        XCTAssertTrue(spectra.isEmpty)
        demand = true
        sendAndDrain(10)
        XCTAssertEqual(spectra.count, 1)
        now += 1.0 / 60
        sendAndDrain(10)
        XCTAssertEqual(spectra.count, 1)
        now += 1.0 / 30
        sendAndDrain(10)
        XCTAssertEqual(spectra.count, 2)
        XCTAssertTrue(spectra.allSatisfy { $0.count == 12 && $0.allSatisfy(\.isFinite) })
        demand = false
        now += 1
        sendAndDrain(10)
        XCTAssertEqual(spectra.count, 2)
        XCTAssertEqual(levels, 50)
        let stopped = expectation(description: "all audio retained")
        recorder.stop { recording in
            XCTAssertEqual(recording.samples, [Float](repeating: 0.1, count: 50))
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 2)
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

        func send(converted: [Float], native: [Float], betweenFormats: @escaping () -> Void = {}) {
            queue.async {
                self.onRaw(Self.buffer(native, rate: 48_000))
                betweenFormats()
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
    var onIsRunning: (() -> Void)?

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
        return AudioCaptureSession(deviceUID: deviceUID ?? AudioDevices.defaultInputDeviceUID() ?? AVCaptureDevice.default(for: .audio)?.uniqueID,
                                   microphoneName: "Synthetic input",
                                   isRunning: { self.onIsRunning?(); return true }, stop: {
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

/// Ignores cancellation while the first inference is suspended, like a native
/// model call. Later calls complete immediately without loading another engine.
private actor CaptureRecoveryEngine: SpeechEngine {
    private(set) var calls = 0
    private var pending: CheckedContinuation<EngineTranscription, Never>?

    func transcribe(samples: [Float], lowEnergy: Bool) async throws -> EngineTranscription {
        calls += 1
        if calls == 1 {
            return await withCheckedContinuation { pending = $0 }
        }
        return result("next healthy words")
    }

    func setVocabulary(_ terms: String) async {}

    func finishAbandoned() {
        pending?.resume(returning: result("stale failed capture words"))
        pending = nil
    }

    private func result(_ text: String) -> EngineTranscription {
        .init(segments: [.init(text: text, start: 0, end: 1)], rawText: text,
              decodingFallbacks: 0, resultCount: 1)
    }
}
