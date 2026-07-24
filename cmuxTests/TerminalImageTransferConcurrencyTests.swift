import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal image transfer concurrency")
struct TerminalImageTransferConcurrencyTests {
    @MainActor
    @Test("lazy pasteboard providers resolve outside the main thread")
    func lazyPasteboardProviderResolvesOffMainThread() async throws {
        #expect(Thread.isMainThread)

        let pasteboard = NSPasteboard(
            name: .init("cmux-tests-image-transfer-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }

        let mainThreadData = Data("resolved-on-main".utf8)
        let backgroundThreadData = Data("resolved-off-main".utf8)
        let provider = PasteboardThreadSignalingDataProvider(
            mainThreadData: mainThreadData,
            backgroundThreadData: backgroundThreadData
        )
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png])
        #expect(pasteboard.writeObjects([item]))

        let preparedContent = await TerminalImageTransferPlanner.prepare(
            pasteboard: pasteboard,
            mode: .paste
        )
        guard case .fileURLs(let fileURLs) = preparedContent,
              let materializedURL = fileURLs.first else {
            Issue.record("Expected the lazy image payload to be materialized")
            return
        }
        defer {
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
        }

        #expect(try Data(contentsOf: materializedURL) == backgroundThreadData)
    }

    @MainActor
    @Test("paste preparation runs one blocker and keeps only the latest waiter")
    func pastePreparationIsBoundedAndLatestWins() async {
        let operation = BlockingPastePreparationOperation()
        let deadlines = ControlledPastePreparationDeadlines()
        let service = TerminalImageTransferPreparationService(
            deadline: .seconds(30),
            deadlineSleep: { _ in try await deadlines.sleep() },
            operation: { operation.run($0) },
            cleanup: { _ in }
        )
        var started = operation.startedEvents().makeAsyncIterator()
        let firstRequest = makeReadRequest(label: "first")
        let secondRequest = makeReadRequest(label: "second")
        let thirdRequest = makeReadRequest(label: "third")

        let firstTask = Task {
            await service.prepare(request: firstRequest, mode: .paste)
        }
        await deadlines.waitForArrivalCount(1)
        let firstStarted = await started.next()
        #expect(firstStarted == firstRequest.pasteboardName)

        let secondTask = Task {
            await service.prepare(request: secondRequest, mode: .paste)
        }
        await deadlines.waitForArrivalCount(2)
        let thirdTask = Task {
            await service.prepare(request: thirdRequest, mode: .paste)
        }
        await deadlines.waitForArrivalCount(3)

        let supersededResult = await secondTask.value
        #expect(supersededResult == .reject)
        operation.release(firstRequest.pasteboardName)
        let firstResult = await firstTask.value
        #expect(firstResult == .insertText(firstRequest.pasteboardName))

        let thirdStarted = await started.next()
        #expect(thirdStarted == thirdRequest.pasteboardName)
        #expect(operation.snapshot().maximumActiveCount == 1)
        #expect(
            operation.snapshot().startedNames
                == [firstRequest.pasteboardName, thirdRequest.pasteboardName]
        )

        operation.release(thirdRequest.pasteboardName)
        let thirdResult = await thirdTask.value
        #expect(thirdResult == .insertText(thirdRequest.pasteboardName))
    }

    @MainActor
    @Test("paste preparation deadline returns before blocked work finishes")
    func pastePreparationDeadlineRejectsAndCleansLateResult() async {
        let operation = BlockingPastePreparationOperation()
        let deadlines = ControlledPastePreparationDeadlines()
        let cleanup = PastePreparationCleanupProbe()
        let service = TerminalImageTransferPreparationService(
            deadline: .seconds(30),
            deadlineSleep: { _ in try await deadlines.sleep() },
            operation: { operation.run($0) },
            cleanup: { cleanup.record($0) }
        )
        var started = operation.startedEvents().makeAsyncIterator()
        var cleaned = cleanup.events().makeAsyncIterator()
        let request = makeReadRequest(label: "deadline")

        let task = Task {
            await service.prepare(request: request, mode: .paste)
        }
        await deadlines.waitForArrivalCount(1)
        let startedName = await started.next()
        #expect(startedName == request.pasteboardName)

        await deadlines.fireAll()
        let timedOutResult = await task.value
        #expect(timedOutResult == .reject)

        operation.release(request.pasteboardName)
        let discardedResult = await cleaned.next()
        guard case .terminal(.insertText(let value))? = discardedResult else {
            Issue.record("Expected the timed-out result to be cleaned")
            return
        }
        #expect(value == request.pasteboardName)
    }

    @MainActor
    private func makeReadRequest(label: String) -> TerminalPasteboardReadRequest {
        let pasteboard = NSPasteboard(
            name: .init("cmux-tests-paste-lane-\(label)-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        return TerminalPasteboardReadRequest(pasteboard: pasteboard)
    }
}
