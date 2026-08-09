import AppKit
import CmuxTerminal
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
    @Test("failure event streams finish when their probe is released")
    func failureProbeFinishesOnRelease() async {
        var probe: PastePreparationFailureProbe? = PastePreparationFailureProbe()
        var events = probe?.events().makeAsyncIterator()

        probe = nil

        #expect(await events?.next() == nil)
    }

    @MainActor
    @Test("lazy pasteboard providers materialize through isolated preparation")
    func lazyPasteboardProviderMaterializes() async throws {
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

        let preparationService = makeLivePreparationService()
        let preparedContent = await TerminalImageTransferPlanner.prepare(
            pasteboard: pasteboard,
            mode: .paste,
            using: preparationService
        )
        guard case .fileURLs(let fileURLs) = preparedContent,
              let materializedURL = fileURLs.first else {
            Issue.record("Expected the lazy image payload to be materialized")
            return
        }
        defer {
            preparationService.cleanupTransferredTemporaryFiles(
                .fileURLs(fileURLs)
            )
        }

        let materializedData = try Data(contentsOf: materializedURL)
        // AppKit marks the provider callback NS_SWIFT_NONISOLATED and does not
        // promise a callback executor. The process boundary is the invariant:
        // either synthetic payload proves provider resolution happened outside
        // cmux's main thread before the worker returned the materialized file.
        #expect(
            materializedData == mainThreadData
                || materializedData == backgroundThreadData
        )
    }

    @MainActor
    @Test("rollback snapshots cross the isolated worker boundary")
    func rollbackSnapshotUsesIsolatedWorker() async throws {
        let pasteboard = NSPasteboard(
            name: .init("cmux-tests-rollback-snapshot-\(UUID().uuidString)")
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

        let request = TerminalPasteboardContentsCaptureRequest(
            pasteboardName: pasteboard.name.rawValue,
            changeCount: pasteboard.changeCount,
            maximumByteCount: 4 * 1_048_576
        )
        let snapshot = try #require(
            try await TerminalPastePreparationWorkerClient
                .snapshottingWithCurrentBinary()
                .captureSnapshot(request)
        )
        let pngData = try #require(
            snapshot.contents
                .flatMap(\.representations)
                .first(where: {
                    $0.typeIdentifier
                        == NSPasteboard.PasteboardType.png.rawValue
                })?
                .data
        )

        #expect(snapshot.changeCount == request.changeCount)
        #expect(pngData == mainThreadData || pngData == backgroundThreadData)
        withExtendedLifetime(provider) {}
    }

    @MainActor
    @Test("existing file URLs bypass worker-file adoption")
    func existingFileURLSurvivesWorkerTransport() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-tests-existing-file-\(UUID().uuidString).txt"
            )
        try Data("existing".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = NSPasteboard(
            name: .init("cmux-tests-existing-file-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        #expect(pasteboard.writeObjects([fileURL as NSURL]))

        let preparedContent = await TerminalImageTransferPlanner.prepare(
            pasteboard: pasteboard,
            mode: .paste,
            using: makeLivePreparationService()
        )

        #expect(
            preparedContent == .fileURLs([fileURL.standardizedFileURL])
        )
    }

    @MainActor
    @Test("prepared result cleanup uses the injected pasteboard owner")
    func preparedResultCleanupUsesInjectedPasteboardOwner() throws {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-tests-cleanup-owner-\(UUID().uuidString)",
                isDirectory: true
            )
        let ownerDirectory = scratchDirectory.appendingPathComponent(
            "owner",
            isDirectory: true
        )
        let foreignDirectory = scratchDirectory.appendingPathComponent(
            "foreign",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: ownerDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: foreignDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        let fileURL = ownerDirectory.appendingPathComponent("prepared.png")
        try Data([0x1]).write(to: fileURL)
        let owner = TerminalPasteboardService(
            temporaryDirectory: ownerDirectory
        )
        let foreign = TerminalPasteboardService(
            temporaryDirectory: foreignDirectory
        )
        owner.debugRegisterOwnedTemporaryImageFile(fileURL)
        let result = TerminalPastePreparationResult.composer(
            .attachments([
                TextBoxPreparedAttachment(
                    fileURL: fileURL,
                    thumbnailPNGData: nil
                ),
            ])
        )

        result.cleanupTransferredTemporaryFiles(using: foreign)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        result.cleanupTransferredTemporaryFiles(using: owner)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    @Test("large plain text crosses the bounded worker envelope")
    func largePlainTextCrossesWorkerEnvelope() async {
        let pasteboard = NSPasteboard(
            name: .init("cmux-tests-large-text-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let largeText = String(
            repeating: "x",
            count: TerminalPastePreparationWorkerClient.maximumResponseSize
                + 1_024
        )
        pasteboard.setString(largeText, forType: .string)

        let preparedContent = await TerminalImageTransferPlanner.prepare(
            pasteboard: pasteboard,
            mode: .paste,
            using: makeLivePreparationService()
        )

        guard case .insertText(let preparedText) = preparedContent else {
            Issue.record("Expected large plain text to survive worker transport")
            return
        }
        #expect(preparedText == largeText)
    }

    @MainActor
    @Test("oversized plain text is rejected by the worker boundary")
    func oversizedPlainTextIsRejected() async {
        let pasteboard = NSPasteboard(
            name: .init("cmux-tests-oversized-text-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let oversizedText = String(
            repeating: "x",
            count: TerminalPastePreparationWorkerTextPayload.maximumByteCount
                + 1
        )
        pasteboard.setString(oversizedText, forType: .string)

        let preparedContent = await TerminalImageTransferPlanner.prepare(
            pasteboard: pasteboard,
            mode: .paste,
            using: makeLivePreparationService()
        )

        #expect(preparedContent == .reject)
    }

    @MainActor
    @Test("accepted paste preparations execute in FIFO order without drops")
    func pastePreparationPreservesFIFOOrder() async {
        let operation = ControlledPastePreparationOperation()
        let deadlines = ControlledPastePreparationDeadlines()
        let service = TerminalImageTransferPreparationService(
            deadline: .seconds(30),
            deadlineSleep: { _ in try await deadlines.sleep() },
            admissionSignal: { operation.signalAdmission($0) },
            operation: { try await operation.run($0) },
            cleanup: { _ in }
        )
        var admitted = operation.admittedEvents().makeAsyncIterator()
        var started = operation.startedEvents().makeAsyncIterator()
        let (firstPasteboard, firstRequest) = makeReadRequest(label: "first")
        let (secondPasteboard, secondRequest) = makeReadRequest(label: "second")
        let (thirdPasteboard, thirdRequest) = makeReadRequest(label: "third")
        defer {
            for pasteboard in [firstPasteboard, secondPasteboard, thirdPasteboard] {
                pasteboard.clearContents()
                pasteboard.releaseGlobally()
            }
        }

        let firstTask = Task {
            await service.prepare(request: firstRequest, mode: .paste)
        }
        #expect(await admitted.next() == firstRequest.pasteboardName)
        await deadlines.waitForArrivalCount(1)
        let firstStarted = await started.next()
        #expect(firstStarted == firstRequest.pasteboardName)

        let secondTask = Task {
            await service.prepare(request: secondRequest, mode: .paste)
        }
        #expect(await admitted.next() == secondRequest.pasteboardName)
        await deadlines.waitForArrivalCount(2)
        let thirdTask = Task {
            await service.prepare(request: thirdRequest, mode: .paste)
        }
        #expect(await admitted.next() == thirdRequest.pasteboardName)
        await deadlines.waitForArrivalCount(3)

        await operation.release(firstRequest.pasteboardName)
        let firstResult = await firstTask.value
        #expect(firstResult == .insertText(firstRequest.pasteboardName))

        let secondStarted = await started.next()
        #expect(secondStarted == secondRequest.pasteboardName)
        await operation.release(secondRequest.pasteboardName)
        let secondResult = await secondTask.value
        #expect(secondResult == .insertText(secondRequest.pasteboardName))

        let thirdStarted = await started.next()
        #expect(thirdStarted == thirdRequest.pasteboardName)
        #expect(await operation.snapshot().maximumActiveCount == 1)
        #expect(
            await operation.snapshot().startedNames
                == [
                    firstRequest.pasteboardName,
                    secondRequest.pasteboardName,
                    thirdRequest.pasteboardName,
                ]
        )

        await operation.release(thirdRequest.pasteboardName)
        let thirdResult = await thirdTask.value
        #expect(thirdResult == .insertText(thirdRequest.pasteboardName))
    }

    @MainActor
    @Test("a timed-out worker is reaped before the next paste runs")
    func timedOutWorkerAllowsReplacement() async {
        let operation = ControlledPastePreparationOperation()
        let deadlines = ControlledPastePreparationDeadlines()
        let failures = PastePreparationFailureProbe()
        let service = TerminalImageTransferPreparationService(
            deadline: .seconds(30),
            deadlineSleep: { _ in try await deadlines.sleep() },
            admissionSignal: { operation.signalAdmission($0) },
            operation: { try await operation.run($0) },
            cleanup: { _ in },
            failureSignal: { failures.record($0) }
        )
        var admitted = operation.admittedEvents().makeAsyncIterator()
        var started = operation.startedEvents().makeAsyncIterator()
        var reportedFailures = failures.events().makeAsyncIterator()
        let (firstPasteboard, firstRequest) = makeReadRequest(
            label: "deadline-first"
        )
        let (secondPasteboard, secondRequest) = makeReadRequest(
            label: "deadline-second"
        )
        defer {
            for pasteboard in [firstPasteboard, secondPasteboard] {
                pasteboard.clearContents()
                pasteboard.releaseGlobally()
            }
        }

        let firstTask = Task {
            await service.prepare(request: firstRequest, mode: .paste)
        }
        #expect(await admitted.next() == firstRequest.pasteboardName)
        await deadlines.waitForArrivalCount(1)
        let startedName = await started.next()
        #expect(startedName == firstRequest.pasteboardName)

        let secondTask = Task {
            await service.prepare(request: secondRequest, mode: .paste)
        }
        #expect(await admitted.next() == secondRequest.pasteboardName)
        await deadlines.waitForArrivalCount(2)

        let firedFirstDeadline = await deadlines.fireNext()
        #expect(firedFirstDeadline)
        let timedOutResult = await firstTask.value
        #expect(timedOutResult == .reject)
        let reportedFailure = await reportedFailures.next()
        #expect(reportedFailure == .deadlineExceeded)

        let replacementStarted = await started.next()
        #expect(replacementStarted == secondRequest.pasteboardName)
        #expect(await operation.snapshot().maximumActiveCount == 1)
        await operation.release(secondRequest.pasteboardName)
        let secondResult = await secondTask.value
        #expect(secondResult == .insertText(secondRequest.pasteboardName))
    }

    @MainActor
    @Test("queued preparation deadline begins at admission")
    func queuedPreparationDeadlineBeginsAtAdmission() async {
        let operation = ControlledPastePreparationOperation()
        let deadlines = ControlledPastePreparationDeadlines()
        let failures = PastePreparationFailureProbe()
        let service = TerminalImageTransferPreparationService(
            deadline: .seconds(30),
            deadlineSleep: { _ in try await deadlines.sleep() },
            admissionSignal: { operation.signalAdmission($0) },
            operation: { try await operation.run($0) },
            cleanup: { _ in },
            failureSignal: { failures.record($0) }
        )
        var admitted = operation.admittedEvents().makeAsyncIterator()
        var started = operation.startedEvents().makeAsyncIterator()
        var reportedFailures = failures.events().makeAsyncIterator()
        let (firstPasteboard, firstRequest) = makeReadRequest(
            label: "admission-deadline-first"
        )
        let (queuedPasteboard, queuedRequest) = makeReadRequest(
            label: "admission-deadline-queued"
        )
        defer {
            for pasteboard in [firstPasteboard, queuedPasteboard] {
                pasteboard.clearContents()
                pasteboard.releaseGlobally()
            }
        }

        let firstTask = Task {
            await service.prepare(request: firstRequest, mode: .paste)
        }
        #expect(await admitted.next() == firstRequest.pasteboardName)
        await deadlines.waitForArrivalCount(1)
        #expect(await started.next() == firstRequest.pasteboardName)

        let queuedTask = Task {
            await service.prepare(request: queuedRequest, mode: .paste)
        }
        #expect(await admitted.next() == queuedRequest.pasteboardName)
        await deadlines.waitForArrivalCount(2)

        #expect(await deadlines.fireLast())
        #expect(await queuedTask.value == .reject)
        #expect(await reportedFailures.next() == .deadlineExceeded)
        #expect(
            await operation.snapshot().startedNames
                == [firstRequest.pasteboardName]
        )
        await operation.release(firstRequest.pasteboardName)
        #expect(
            await firstTask.value
                == .insertText(firstRequest.pasteboardName)
        )
    }
}
