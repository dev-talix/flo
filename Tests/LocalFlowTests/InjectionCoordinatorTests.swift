import XCTest
@testable import LocalFlow

@MainActor
final class InjectionCoordinatorTests: XCTestCase {
    func testMixedModeStallCancelsHeadAndDeliversLaterResultOnce() async {
        var pasted: [String] = []
        var cancelled: [(sequence: Int, kind: InjectionCoordinator.OperationKind)] = []
        var pendingSamples: [Int: RetainedSamples] = [:]
        var processingCounts: [Int] = []
        let laterPasted = expectation(description: "later dictation pasted")

        let coordinator = InjectionCoordinator(
            stallTimeout: 0,
            onInject: { text, _, ready in
                defer { ready() }
                pasted.append(text)
                laterPasted.fulfill()
            },
            onCancel: { sequence, kind in
                cancelled.append((sequence, kind))
                pendingSamples.removeValue(forKey: sequence)
            },
            onProcessingCountChange: { count in
                processingCounts.append(count)
            }
        )

        let stalledCommand = coordinator.begin(kind: .command)
        var samples: RetainedSamples? = RetainedSamples()
        weak var retainedSamples = samples
        pendingSamples[stalledCommand] = samples
        samples = nil

        let laterDictation = coordinator.begin(kind: .dictation)
        coordinator.complete(
            laterDictation,
            with: .inject("later dictation")
        )

        await fulfillment(of: [laterPasted], timeout: 0.5)

        XCTAssertEqual(cancelled.count, 1)
        XCTAssertEqual(cancelled.first?.sequence, stalledCommand)
        XCTAssertEqual(cancelled.first?.kind, .command)
        XCTAssertNil(retainedSamples)
        XCTAssertEqual(coordinator.pendingCount, 0)
        XCTAssertEqual(processingCounts, [1, 2, 1, 0])
        XCTAssertEqual(pasted, ["later dictation"])

        coordinator.complete(
            stalledCommand,
            with: .inject("late command")
        )
        await settleAsyncWork()

        XCTAssertEqual(pasted, ["later dictation"])
        XCTAssertEqual(coordinator.pendingCount, 0)
    }

    func testLaterCompletionDoesNotRestartArmedHeadStallDeadline() async throws {
        var events: [String] = []
        var processingCounts: [Int] = []
        let drained = expectation(description: "original deadline drains queued results")
        drained.expectedFulfillmentCount = 3

        var scheduled: [(TimeInterval, DispatchWorkItem)] = []
        let coordinator = InjectionCoordinator(
            stallTimeout: 0.4,
            scheduleStall: { scheduled.append(($0, $1)) },
            onInject: { text, _, ready in
                defer { ready() }
                events.append("paste:\(text)")
                drained.fulfill()
            },
            onCancel: { sequence, kind in
                events.append("cancel:\(sequence):\(kind)")
                drained.fulfill()
            },
            onProcessingCountChange: { count in
                processingCounts.append(count)
            }
        )

        let stalledCommand = coordinator.begin(kind: .command)
        let firstDictation = coordinator.begin(kind: .dictation)
        let secondDictation = coordinator.begin(kind: .dictation)
        coordinator.complete(firstDictation, with: .inject("first"))

        coordinator.complete(secondDictation, with: .inject("second"))

        // Completing another follower must preserve the first scheduled timeout.
        XCTAssertEqual(scheduled.count, 1)
        let timeout = try XCTUnwrap(scheduled.first)
        XCTAssertEqual(timeout.0, 0.4)
        XCTAssertFalse(timeout.1.isCancelled)
        timeout.1.perform()
        await fulfillment(of: [drained], timeout: 2)

        XCTAssertEqual(events, [
            "cancel:\(stalledCommand):command",
            "paste:first",
            "paste:second"
        ])
        XCTAssertFalse(coordinator.isPending(stalledCommand))
        XCTAssertEqual(coordinator.pendingCount, 0)
        XCTAssertEqual(processingCounts, [1, 2, 3, 2, 1, 0])

        coordinator.complete(stalledCommand, with: .inject("late command"))
        await settleAsyncWork()

        XCTAssertEqual(events, [
            "cancel:\(stalledCommand):command",
            "paste:first",
            "paste:second"
        ])
        XCTAssertEqual(coordinator.pendingCount, 0)
    }

    func testAloneAndQueuedCommandsHaveDeadlinesWithoutCompletedFollower() async {
        var timers: [DispatchWorkItem] = []
        var cancelled: [Int] = []
        var counts: [Int] = []
        let coordinator = InjectionCoordinator(
            stallTimeout: 90,
            scheduleStall: { _, work in timers.append(work) },
            onInject: { _, _, ready in XCTFail("Timed out command must not paste"); ready() },
            onCancel: { sequence, _ in cancelled.append(sequence) },
            onProcessingCountChange: { counts.append($0) }
        )
        let first = coordinator.begin(kind: .command)
        let second = coordinator.begin(kind: .command)
        XCTAssertEqual(timers.count, 2)
        timers[1].perform()
        XCTAssertEqual(cancelled, [second])
        coordinator.complete(second, with: .inject("late second"))
        timers[0].perform()
        XCTAssertEqual(cancelled, [second, first])
        XCTAssertEqual(coordinator.pendingCount, 0)
        XCTAssertEqual(counts.last, 0)
        coordinator.complete(first, with: .inject("late first"))
    }

    func testReadinessCallbackIsOneShotAndKeepsFollowersInOrder() {
        var delivered: [String] = []
        var ready: [() -> Void] = []
        let coordinator = InjectionCoordinator(
            stallTimeout: 90,
            onInject: { text, _, callback in delivered.append(text); ready.append(callback) },
            onCancel: { _, _ in XCTFail("Unexpected cancellation") },
            onProcessingCountChange: { _ in }
        )
        let first = coordinator.begin(kind: .dictation)
        let second = coordinator.begin(kind: .command)
        let third = coordinator.begin(kind: .dictation)
        coordinator.complete(third, with: .inject("third"))
        coordinator.complete(second, with: .inject("second"))
        coordinator.complete(first, with: .inject("first"))
        XCTAssertEqual(delivered, ["first"])
        ready[0]()
        XCTAssertEqual(delivered, ["first", "second"])
        ready[0]()
        XCTAssertEqual(delivered, ["first", "second"])
        ready[1]()
        XCTAssertEqual(delivered, ["first", "second", "third"])
        ready[1]()
        ready[2]()
        XCTAssertEqual(coordinator.pendingCount, 0)
    }

    private func settleAsyncWork() async {
        for _ in 0..<100 { await Task.yield() }
    }
}

private final class RetainedSamples {
    let values = [Float](repeating: 0.2, count: 1_024)
}
