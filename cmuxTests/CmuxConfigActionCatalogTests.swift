import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CmuxConfigActionCatalogTests {
    private let codec = CmuxConfigActionCatalogFrameCodec.shared

    @Test @MainActor
    func loadAllDetectsChangedBytesWhenSizeAndModificationDateMatch() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("cmux.json")
        let first = #"{"actions":{"first":{"type":"command","command":"echo first"}}}"#
        let other = #"{"actions":{"other":{"type":"command","command":"echo other"}}}"#
        #expect(first.utf8.count == other.utf8.count)
        try first.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(globalConfigPath: configURL.path)
        store.loadAll()
        #expect(store.resolvedAction(id: "first") != nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        let modificationDate = try #require(attributes[.modificationDate] as? Date)

        try other.write(to: configURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: configURL.path
        )
        #expect(store.resolvedAction(id: "first") != nil)
        #expect(store.resolvedAction(id: "other") == nil)

        store.loadAll()
        #expect(store.resolvedAction(id: "first") == nil)
        #expect(store.resolvedAction(id: "other") != nil)
    }

    @Test @MainActor
    func unchangedFingerprintDoesNotEvaluateCatalogBuilder() {
        let store = CmuxConfigStore()
        let catalog = store.unconfiguredActionCatalog()
        let first = store.storeActionCatalogSnapshot(
            catalog,
            forKey: "project",
            sourceFingerprint: "same",
            notifyActiveChange: false
        )
        var constructionCount = 0
        func reconstructedCatalog() -> CmuxConfigActionCatalog {
            constructionCount += 1
            return catalog
        }

        let unchanged = store.storeActionCatalogSnapshot(
            reconstructedCatalog(),
            forKey: "project",
            sourceFingerprint: "same",
            notifyActiveChange: false
        )
        #expect(unchanged.id == first.id)
        #expect(constructionCount == 0)

        let changed = store.storeActionCatalogSnapshot(
            reconstructedCatalog(),
            forKey: "project",
            sourceFingerprint: "changed",
            notifyActiveChange: false
        )
        #expect(changed.id != first.id)
        #expect(constructionCount == 1)
    }

    @Test
    func actionCatalogSizeLimitIssueUsesLocalizedFormat() async throws {
        let maximumBytes = CmuxConfigActionCatalogProcessReader.defaultMaximumConfigBytes
        #expect(CmuxConfigStore.actionCatalogTooLargeMessage(
            maximumBytes: maximumBytes,
            locale: Locale(identifier: "en")
        ) == "cmux.json exceeds the 1048576-byte action catalog limit")
        #expect(CmuxConfigStore.actionCatalogTooLargeMessage(
            maximumBytes: maximumBytes,
            locale: Locale(identifier: "ja")
        ) == "cmux.json はアクションカタログの上限（1048576 バイト）を超えています")

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalURL = root.appendingPathComponent("global.json")
        let frameURL = root.appendingPathComponent("too-large.frame")
        let frame = try #require(codec.encode(
            .init(
                localPath: nil,
                local: nil,
                global: .init(status: .tooLarge, data: Data())
            ),
            maximumConfigBytes: maximumBytes
        ))
        try frame.write(to: frameURL)
        let reader = CmuxConfigActionCatalogProcessReader { _ in
            .init(
                executablePath: "/bin/cat",
                arguments: ["/bin/cat", frameURL.path],
                environment: ["PATH": "/usr/bin:/bin"]
            )
        }
        let source = try #require(await CmuxConfigStore.loadActionCatalogSource(
            startingFrom: nil,
            globalConfigPath: globalURL.path,
            workspaceColorPalette: [:],
            rawReader: reader
        ))
        #expect(source.global.issue?.message == CmuxConfigStore.actionCatalogTooLargeMessage(
            maximumBytes: maximumBytes
        ))
    }

    @Test @MainActor
    func perDirectoryCatalogsStayImmutableAndRevalidateSharedInputs() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let projectA = root.appendingPathComponent("project-a", isDirectory: true)
        let projectB = root.appendingPathComponent("project-b", isDirectory: true)
        let configA = projectA.appendingPathComponent(".cmux/cmux.json")
        let configB = projectB.appendingPathComponent(".cmux/cmux.json")
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: configA.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: configB.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let globalConfig = globalDirectory.appendingPathComponent("cmux.json")
        try actionJSON(id: "global.action", command: "echo global")
            .write(to: globalConfig, atomically: true, encoding: .utf8)
        try workspaceActionJSON(name: "Project A", title: "Terminal A")
            .write(to: configA, atomically: true, encoding: .utf8)
        try workspaceActionJSON(name: "Project B", title: "Terminal B")
            .write(to: configB, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: globalConfig.path,
            localConfigPath: configA.path,
            startFileWatchers: false
        )
        store.loadAll()
        let ambientLocalPath = store.localConfigPath
        let ambientRevision = store.configRevision
        let ambientActions = store.loadedActions
        let ambientCommands = store.loadedCommands.map { "\($0.name)|\($0.command ?? "")" }
        let ambientSourcePaths = store.commandSourcePaths
        let ambientIssues = store.configurationIssues

        let catalogA = await store.refreshActionCatalog(startingFrom: projectA.path)
        let catalogB = await store.refreshActionCatalog(startingFrom: projectB.path)
        #expect(catalogA.resolvedAction(id: "project.action")?.workspaceCommandName == "Project A")
        #expect(catalogB.resolvedAction(id: "project.action")?.workspaceCommandName == "Project B")
        #expect(catalogA.resolvedAction(id: "project.action")?.actionSourcePath == configA.path)
        #expect(catalogB.resolvedAction(id: "project.action")?.actionSourcePath == configB.path)
        #expect(catalogA.resolvedAction(id: "cmux.newTerminal")?.title == "Terminal A")
        #expect(catalogB.resolvedAction(id: "cmux.newTerminal")?.title == "Terminal B")
        #expect(catalogA.resolvedAction(id: "global.action") != nil)
        #expect(catalogB.resolvedAction(id: "global.action") != nil)
        #expect(catalogA.loadedCommands.map(\.name) == ["Project A"])
        #expect(catalogB.loadedCommands.map(\.name) == ["Project B"])
        #expect(store.localConfigPath == ambientLocalPath)
        #expect(store.configRevision == ambientRevision)
        #expect(store.loadedActions == ambientActions)
        #expect(store.loadedCommands.map { "\($0.name)|\($0.command ?? "")" } == ambientCommands)
        #expect(store.commandSourcePaths == ambientSourcePaths)
        #expect(store.configurationIssues == ambientIssues)

        let snapshotBefore = try #require(store.cachedActionCatalogSnapshot(
            startingFrom: projectB.path,
            revalidate: false
        ))
        let unchangedFresh = try #require(await store.freshActionCatalogSnapshot(
            startingFrom: projectB.path,
            deadline: Date(timeIntervalSinceNow: 5)
        ))
        #expect(unchangedFresh.id == snapshotBefore.id)
        #expect(unchangedFresh.sourceFingerprint == snapshotBefore.sourceFingerprint)

        try workspaceActionJSON(name: "Project C", title: "Terminal C")
            .write(to: configB, atomically: true, encoding: .utf8)
        let fresh = try #require(await store.freshActionCatalogSnapshot(
            startingFrom: projectB.path,
            deadline: Date(timeIntervalSinceNow: 5)
        ))
        #expect(fresh.id != snapshotBefore.id)
        #expect(fresh.catalog.resolvedAction(id: "project.action")?.workspaceCommandName == "Project C")
        let expired = await store.freshActionCatalogSnapshot(
            startingFrom: projectB.path,
            deadline: .distantPast
        )
        #expect(expired == nil)
        let distantFuture = await store.freshActionCatalogSnapshot(
            startingFrom: projectB.path,
            deadline: .distantFuture
        )
        #expect(distantFuture != nil)

        try actionJSON(id: "global.action", command: "echo changed")
            .write(to: globalConfig, atomically: true, encoding: .utf8)
        _ = await store.refreshActionCatalog(startingFrom: nil)
        store.loadAll()
        #expect(store.cachedActionCatalogSnapshot(
            startingFrom: projectB.path,
            revalidate: false
        ) == nil)
        let afterGlobalEdit = await store.refreshActionCatalog(startingFrom: projectB.path)
        #expect(afterGlobalEdit.resolvedAction(id: "global.action")?.terminalCommand == "echo changed")

        try FileManager.default.removeItem(at: configB)
        let afterDelete = await store.refreshActionCatalog(startingFrom: projectB.path)
        #expect(afterDelete.resolvedAction(id: "project.action") == nil)
        #expect(afterDelete.resolvedAction(id: "global.action") != nil)
    }

    @Test
    func frameCodecRejectsMalformedAndInconsistentFrames() throws {
        let response = CmuxConfigActionCatalogRawReadResponse(
            localPath: "/tmp/project/.cmux/cmux.json",
            local: .init(status: .data, data: Data("local".utf8)),
            global: .init(status: .missing, data: Data())
        )
        let frame = try #require(codec.encode(response, maximumConfigBytes: 1024))
        #expect(codec.decode(frame, maximumConfigBytes: 1024) != nil)
        #expect(codec.decode(Data(frame.dropLast()), maximumConfigBytes: 1024) == nil)
        var trailing = frame
        trailing.append(0)
        #expect(codec.decode(trailing, maximumConfigBytes: 1024) == nil)
        #expect(codec.encode(
            .init(
                localPath: nil,
                local: .init(status: .data, data: Data("unexpected".utf8)),
                global: .init(status: .missing, data: Data())
            ),
            maximumConfigBytes: 1024
        ) == nil)

        var nonDataPayload = CmuxConfigActionCatalogFrameCodec.magic
        appendField(status: 0, payload: Data(), to: &nonDataPayload)
        appendField(status: 0, payload: Data([1]), to: &nonDataPayload)
        appendField(status: 0, payload: Data(), to: &nonDataPayload)
        #expect(codec.decode(nonDataPayload, maximumConfigBytes: 1024) == nil)
    }

    @Test
    func processReaderRejectsUntrustedLocalPath() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let frameURL = root.appendingPathComponent("frame")
        try #require(codec.encode(
            .init(
                localPath: "/tmp/untrusted/cmux.json",
                local: .init(status: .missing, data: Data()),
                global: .init(status: .missing, data: Data())
            ),
            maximumConfigBytes: 1024
        )).write(to: frameURL)
        let reader = CmuxConfigActionCatalogProcessReader { _ in
            .init(
                executablePath: "/bin/cat",
                arguments: ["/bin/cat", frameURL.path],
                environment: ["PATH": "/usr/bin:/bin"]
            )
        }
        let response = await reader.read(request: .init(
            directory: root.path,
            globalConfigPath: root.appendingPathComponent("global.json").path,
            maximumConfigBytes: 1024
        ))
        #expect(response == nil)
    }

    @Test
    func cancellationKillsAndReapsTermIgnoringChild() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidURL = root.appendingPathComponent("child pid ;$().txt")
        let reader = CmuxConfigActionCatalogProcessReader(
            timeout: 10,
            terminationGrace: 0.05
        ) { _ in
            .init(
                executablePath: "/bin/sh",
                arguments: [
                    "/bin/sh",
                    "-c",
                    "trap '' TERM; printf '%s' \"$$\" > \"$1\"; while :; do :; done",
                    "cmux-action-reader",
                    pidURL.path,
                ],
                environment: ["PATH": "/usr/bin:/bin"]
            )
        }
        let task = Task {
            await reader.read(request: .init(
                directory: nil,
                globalConfigPath: root.appendingPathComponent("global.json").path,
                maximumConfigBytes: 1024
            ))
        }
        defer { task.cancel() }
        #expect(await waitUntil { FileManager.default.fileExists(atPath: pidURL.path) })
        let pidString = try #require(String(data: Data(contentsOf: pidURL), encoding: .utf8))
        let childPID = try #require(pid_t(pidString))

        task.cancel()
        let response = await task.value
        #expect(response == nil)
        errno = 0
        #expect(Darwin.kill(childPID, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test
    func timeoutsReleaseGeneralSlotsAndPreserveGlobalLane() async throws {
        let fixture = try ProcessReaderFixture(codec: codec)
        defer { fixture.remove() }
        let pidAURL = fixture.root.appendingPathComponent("hung-a.pid")
        let pidBURL = fixture.root.appendingPathComponent("hung-b.pid")
        let healthyStartURL = fixture.root.appendingPathComponent("healthy-started")
        let schedulingEvents = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        let timeoutReleases = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        let terminationGraceReleases = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        var schedulingEventIterator = schedulingEvents.stream.makeAsyncIterator()
        defer {
            schedulingEvents.continuation.finish()
            timeoutReleases.continuation.finish()
            terminationGraceReleases.continuation.finish()
        }
        defer {
            for url in [pidAURL, pidBURL] {
                if let data = try? Data(contentsOf: url),
                   let string = String(data: data, encoding: .utf8),
                   let pid = pid_t(string) {
                    _ = Darwin.kill(-pid, SIGKILL)
                }
            }
        }
        let launchProvider: CmuxConfigActionCatalogProcessReader.LaunchProvider = { request in
            if let directory = request.directory,
               directory.contains("/hung-") {
                let pidURL = directory == fixture.hungA.path ? pidAURL : pidBURL
                return .init(
                    executablePath: "/bin/sh",
                    arguments: [
                        "/bin/sh",
                        "-c",
                        "trap '' TERM; printf '%s' \"$$\" > \"$1\"; while :; do :; done",
                        "cmux-lane-isolation",
                        pidURL.path,
                    ],
                    environment: ["PATH": "/usr/bin:/bin"]
                )
            }
            if request.directory == fixture.healthyDirectory.path {
                schedulingEvents.continuation.yield("launched")
                return .init(
                    executablePath: "/bin/sh",
                    arguments: [
                        "/bin/sh",
                        "-c",
                        "printf 'started' > \"$1\"; exec /bin/cat \"$2\"",
                        "cmux-healthy-start",
                        healthyStartURL.path,
                        fixture.healthyFrameURL.path,
                    ],
                    environment: ["PATH": "/usr/bin:/bin"]
                )
            }
            return .init(
                executablePath: "/bin/cat",
                arguments: ["/bin/cat", fixture.globalFrameURL.path],
                environment: ["PATH": "/usr/bin:/bin"]
            )
        }
        let timeout: TimeInterval = 10
        let terminationGrace: TimeInterval = 20
        let timing = CmuxConfigActionCatalogProcessReader.Timing { duration in
            if duration == .seconds(timeout) {
                for await _ in timeoutReleases.stream { return }
                try Task.checkCancellation()
                return
            }
            if duration == .seconds(terminationGrace) {
                for await _ in terminationGraceReleases.stream { return }
                try Task.checkCancellation()
                return
            }
            try await ContinuousClock().sleep(for: duration)
        }
        let hungReader = CmuxConfigActionCatalogProcessReader(
            timeout: timeout,
            terminationGrace: terminationGrace,
            timing: timing,
            launchProvider: launchProvider
        )
        let regularReader = CmuxConfigActionCatalogProcessReader(
            launchProvider: launchProvider
        )
        let coordinator = CmuxConfigActionCatalogReadCoordinator(
            maximumGlobalReadCount: 1,
            maximumGeneralReadCount: 2,
            maximumPendingReadCount: 4,
            pendingReadObserver: { key in
                if key == "healthy" {
                    schedulingEvents.continuation.yield("pending")
                }
            },
            readCompletionObserver: { key in
                if key == "hung-a" || key == "hung-b" {
                    schedulingEvents.continuation.yield("finished")
                }
            }
        )
        let load: @Sendable (String?) async -> CmuxConfigActionCatalogSource? = { directory in
            let isHung = directory == fixture.hungA.path || directory == fixture.hungB.path
            return await CmuxConfigStore.loadActionCatalogSource(
                startingFrom: directory,
                globalConfigPath: fixture.globalPath,
                workspaceColorPalette: [:],
                rawReader: isHung ? hungReader : regularReader
            )
        }
        let hungA = Task.detached {
            await coordinator.run(key: "hung-a", lane: .general, requestID: UUID()) {
                await load(fixture.hungA.path)
            }
        }
        let hungB = Task.detached {
            await coordinator.run(key: "hung-b", lane: .general, requestID: UUID()) {
                await load(fixture.hungB.path)
            }
        }
        #expect(await waitUntil {
            FileManager.default.fileExists(atPath: pidAURL.path)
                && FileManager.default.fileExists(atPath: pidBURL.path)
        })
        let childPIDs = try [pidAURL, pidBURL].map { url in
            let string = try #require(String(data: Data(contentsOf: url), encoding: .utf8))
            return try #require(pid_t(string))
        }

        let global = await coordinator.run(key: "global", lane: .global, requestID: UUID()) {
            await load(nil)
        }
        #expect(global != nil)
        #expect(childPIDs.allSatisfy { Darwin.kill($0, 0) == 0 })

        let healthyTask = Task.detached {
            await coordinator.run(key: "healthy", lane: .general, requestID: UUID()) {
                await load(fixture.healthyDirectory.path)
            }
        }
        defer { healthyTask.cancel() }
        let pendingEvent = await schedulingEventIterator.next()
        #expect(pendingEvent == "pending")
        #expect(!FileManager.default.fileExists(atPath: healthyStartURL.path))

        timeoutReleases.continuation.yield(())
        terminationGraceReleases.continuation.yield(())
        let finishedEvent = await schedulingEventIterator.next()
        #expect(finishedEvent == "finished")
        #expect(childPIDs.filter { Darwin.kill($0, 0) == 0 }.count == 1)
        let launchedEvent = await schedulingEventIterator.next()
        #expect(launchedEvent == "launched")
        #expect(await waitUntil {
            FileManager.default.fileExists(atPath: healthyStartURL.path)
        })
        let healthy = await healthyTask.value
        #expect(healthy != nil)

        timeoutReleases.continuation.yield(())
        terminationGraceReleases.continuation.yield(())
        let hungAResult = await hungA.value
        let hungBResult = await hungB.value
        #expect(hungAResult == nil)
        #expect(hungBResult == nil)
        for childPID in childPIDs {
            errno = 0
            #expect(Darwin.kill(childPID, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    @Test
    func floodOutputIsBoundedAndTermIgnoringWriterIsReaped() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidURL = root.appendingPathComponent("flood.pid")
        defer {
            if let data = try? Data(contentsOf: pidURL),
               let string = String(data: data, encoding: .utf8),
               let pid = pid_t(string) {
                _ = Darwin.kill(-pid, SIGKILL)
            }
        }
        let reader = CmuxConfigActionCatalogProcessReader(
            timeout: 5,
            terminationGrace: 0.05
        ) { _ in
            .init(
                executablePath: "/bin/sh",
                arguments: [
                    "/bin/sh",
                    "-c",
                    "trap '' TERM PIPE; printf '%s' \"$$\" > \"$1\"; while :; do printf '0123456789abcdef'; done",
                    "cmux-flood",
                    pidURL.path,
                ],
                environment: ["PATH": "/usr/bin:/bin"]
            )
        }
        let start = ContinuousClock().now
        let response = await reader.read(request: .init(
            directory: nil,
            globalConfigPath: root.appendingPathComponent("global.json").path,
            maximumConfigBytes: 64
        ))
        #expect(response == nil)
        #expect(start.duration(to: .now) < .seconds(2))
        let pidString = try #require(String(data: Data(contentsOf: pidURL), encoding: .utf8))
        let childPID = try #require(pid_t(pidString))
        errno = 0
        #expect(Darwin.kill(childPID, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test
    func quarantineHandoffCapsChildrenRecoversSlotAndReleasesOnLateReap() async throws {
        let fixture = try ProcessReaderFixture(codec: codec)
        defer { fixture.remove() }
        let quarantine = CmuxConfigActionCatalogProcessQuarantine(
            generalCapacity: 2,
            globalCapacity: 1
        )
        let pidURL = fixture.root.appendingPathComponent("quarantined.pid")
        defer {
            if let data = try? Data(contentsOf: pidURL),
               let string = String(data: data, encoding: .utf8),
               let pid = pid_t(string) {
                _ = Darwin.kill(-pid, SIGKILL)
            }
        }
        let operations = CmuxConfigActionCatalogProcessReader.ProcessOperations {
            pid, signal, group in
            if signal == SIGCONT {
                _ = Darwin.kill(group ? -pid : pid, signal)
            }
        }
        let reader = CmuxConfigActionCatalogProcessReader(
            timeout: 0.05,
            terminationGrace: 0.02,
            postKillHandoffDelay: 0.02,
            processOperations: operations,
            quarantine: quarantine
        ) { request in
            if request.directory == fixture.healthyDirectory.path {
                return .init(
                    executablePath: "/bin/cat",
                    arguments: ["/bin/cat", fixture.healthyFrameURL.path],
                    environment: ["PATH": "/usr/bin:/bin"]
                )
            }
            return .init(
                executablePath: "/bin/sh",
                arguments: [
                    "/bin/sh",
                    "-c",
                    "trap '' TERM; printf '%s' \"$$\" > \"$1\"; while :; do :; done",
                    "cmux-quarantine",
                    pidURL.path,
                ],
                environment: ["PATH": "/usr/bin:/bin"]
            )
        }
        let coordinator = CmuxConfigActionCatalogReadCoordinator(
            maximumGlobalReadCount: 1,
            maximumGeneralReadCount: 1,
            maximumPendingReadCount: 2
        )
        let hungTask = Task.detached {
            await coordinator.run(key: "hung", lane: .general, requestID: UUID()) {
                await CmuxConfigStore.loadActionCatalogSource(
                    startingFrom: fixture.hungA.path,
                    globalConfigPath: fixture.globalPath,
                    workspaceColorPalette: [:],
                    rawReader: reader
                )
            }
        }
        #expect(await waitUntil { FileManager.default.fileExists(atPath: pidURL.path) })
        let healthyTask = Task.detached {
            await coordinator.run(key: "healthy", lane: .general, requestID: UUID()) {
                await CmuxConfigStore.loadActionCatalogSource(
                    startingFrom: fixture.healthyDirectory.path,
                    globalConfigPath: fixture.globalPath,
                    workspaceColorPalette: [:],
                    rawReader: reader
                )
            }
        }
        #expect(await hungTask.value == nil)
        #expect(await healthyTask.value != nil)
        let state = await quarantine.state()
        #expect(state.quarantinedCount == 1)
        #expect(state.blockedKeys.count == 1)

        let sameKeyStart = ContinuousClock().now
        let sameKey = await reader.read(request: .init(
            directory: fixture.hungA.path,
            globalConfigPath: fixture.globalPath,
            maximumConfigBytes: 1 << 20
        ))
        #expect(sameKey == nil)
        #expect(sameKeyStart.duration(to: .now) < .milliseconds(50))

        let childPID = try #require(pid_t(String(
            data: Data(contentsOf: pidURL),
            encoding: .utf8
        ) ?? ""))
        _ = Darwin.kill(-childPID, SIGKILL)
        #expect(await waitUntil {
            await quarantine.state().quarantinedCount == 0
        })
        let recoveredLease = await quarantine.reserve(
            key: state.blockedKeys.first ?? "",
            lane: .general
        )
        #expect(recoveredLease != nil)
        if let recoveredLease { await quarantine.release(recoveredLease) }
    }

    @Test
    func reapBeforeAcceptedQuarantineDeliveryReleasesLeaseExactlyOnce() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidURL = root.appendingPathComponent("admission-race.pid")
        defer {
            if let data = try? Data(contentsOf: pidURL),
               let string = String(data: data, encoding: .utf8),
               let pid = pid_t(string) {
                _ = Darwin.kill(-pid, SIGKILL)
            }
        }

        let quarantine = CmuxConfigActionCatalogProcessQuarantine(
            generalCapacity: 1,
            globalCapacity: 1,
            recordsReleaseAttempts: true
        )
        let quarantineKey = "accepted-before-reap"
        let reservedLease = await quarantine.reserve(key: quarantineKey, lane: .general)
        let lease = try #require(reservedLease)
        let deliveryGate = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let admissionCompleted = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var admissionCompletionIterator = admissionCompleted.stream.makeAsyncIterator()
        let operations = CmuxConfigActionCatalogProcessReader.ProcessOperations {
            pid, signal, group in
            if signal == SIGCONT { _ = Darwin.kill(group ? -pid : pid, signal) }
        }
        let session = CmuxConfigActionCatalogProcessSession(
            launch: .init(
                executablePath: "/bin/sh",
                arguments: [
                    "/bin/sh",
                    "-c",
                    "trap '' TERM; printf '%s' \"$$\" > \"$1\"; while :; do :; done",
                    "cmux-admission-race",
                    pidURL.path,
                ],
                environment: ["PATH": "/usr/bin:/bin"]
            ),
            timeout: 0.05,
            terminationGrace: 0.02,
            postKillHandoffDelay: 0.02,
            maximumOutputBytes: 1024,
            timing: .continuous,
            processOperations: operations,
            quarantine: quarantine,
            quarantineLease: lease,
            quarantineAdmissionDelivery: {
                for await _ in deliveryGate.stream { return }
            },
            quarantineAdmissionCompletion: {
                admissionCompleted.continuation.yield(())
            }
        )
        let runTask = Task {
            let result = await session.run()
            if case .completed = result {
                await quarantine.release(lease)
            }
            return result
        }
        defer {
            deliveryGate.continuation.yield(())
            deliveryGate.continuation.finish()
            admissionCompleted.continuation.finish()
            runTask.cancel()
        }

        #expect(await waitUntil { FileManager.default.fileExists(atPath: pidURL.path) })
        #expect(await waitUntil {
            await quarantine.state().generalQuarantinedCount == 1
        })
        let pidString = try #require(String(data: Data(contentsOf: pidURL), encoding: .utf8))
        let childPID = try #require(pid_t(pidString))
        _ = Darwin.kill(-childPID, SIGKILL)
        #expect(await waitUntil {
            await quarantine.releaseAttemptCount(for: lease) == 1
        })

        deliveryGate.continuation.yield(())
        #expect(await admissionCompletionIterator.next() != nil)
        switch await runTask.value {
        case .completed(let output):
            #expect(output == nil)
        case .quarantined:
            Issue.record("reaped session was handed off after admission")
        }
        #expect(await quarantine.releaseAttemptCount(for: lease) == 1)
        #expect(await quarantine.state().reservedCount == 0)
        let recoveredLease = await quarantine.reserve(key: quarantineKey, lane: .general)
        #expect(recoveredLease != nil)
        if let recoveredLease { await quarantine.release(recoveredLease) }
    }

    @Test
    func quarantinedGeneralProcessesCannotConsumeGlobalCapacity() async throws {
        let fixture = try ProcessReaderFixture(codec: codec)
        defer { fixture.remove() }
        let quarantine = CmuxConfigActionCatalogProcessQuarantine(
            generalCapacity: 2,
            globalCapacity: 1
        )
        let pidA = fixture.root.appendingPathComponent("general-a.pid")
        let pidB = fixture.root.appendingPathComponent("general-b.pid")
        let pidThird = fixture.root.appendingPathComponent("general-third.pid")
        defer {
            for url in [pidA, pidB, pidThird] {
                if let data = try? Data(contentsOf: url),
                   let string = String(data: data, encoding: .utf8),
                   let pid = pid_t(string) {
                    _ = Darwin.kill(-pid, SIGKILL)
                }
            }
        }
        let operations = CmuxConfigActionCatalogProcessReader.ProcessOperations {
            pid, signal, group in
            if signal == SIGCONT { _ = Darwin.kill(group ? -pid : pid, signal) }
        }
        let reader = CmuxConfigActionCatalogProcessReader(
            timeout: 0.05,
            terminationGrace: 0.02,
            postKillHandoffDelay: 0.02,
            processOperations: operations,
            quarantine: quarantine
        ) { request in
            guard let directory = request.directory else {
                return .init(
                    executablePath: "/bin/cat",
                    arguments: ["/bin/cat", fixture.globalFrameURL.path],
                    environment: ["PATH": "/usr/bin:/bin"]
                )
            }
            let pidURL: URL
            if directory == fixture.hungA.path {
                pidURL = pidA
            } else if directory == fixture.hungB.path {
                pidURL = pidB
            } else {
                pidURL = pidThird
            }
            return .init(
                executablePath: "/bin/sh",
                arguments: [
                    "/bin/sh",
                    "-c",
                    "trap '' TERM; printf '%s' \"$$\" > \"$1\"; while :; do :; done",
                    "cmux-quarantine-lane",
                    pidURL.path,
                ],
                environment: ["PATH": "/usr/bin:/bin"]
            )
        }
        let generalA = Task {
            await reader.read(request: .init(
                directory: fixture.hungA.path,
                globalConfigPath: fixture.globalPath,
                maximumConfigBytes: 1024
            ))
        }
        let generalB = Task {
            await reader.read(request: .init(
                directory: fixture.hungB.path,
                globalConfigPath: fixture.globalPath,
                maximumConfigBytes: 1024
            ))
        }
        defer {
            generalA.cancel()
            generalB.cancel()
        }
        #expect(await waitUntil {
            FileManager.default.fileExists(atPath: pidA.path)
                && FileManager.default.fileExists(atPath: pidB.path)
        })
        #expect(await generalA.value == nil)
        #expect(await generalB.value == nil)
        #expect(await quarantine.state().generalQuarantinedCount == 2)

        let rejectedGeneral = await reader.read(request: .init(
            directory: fixture.root.appendingPathComponent("third-general").path,
            globalConfigPath: fixture.globalPath,
            maximumConfigBytes: 1024
        ))
        #expect(rejectedGeneral == nil)
        #expect(!FileManager.default.fileExists(atPath: pidThird.path))
        let global = await reader.read(request: .init(
            directory: nil,
            globalConfigPath: fixture.globalPath,
            maximumConfigBytes: 1024
        ))
        #expect(global?.global.status == .data)
        #expect(await quarantine.state().globalQuarantinedCount == 0)

        for url in [pidA, pidB] {
            let data = try Data(contentsOf: url)
            let string = try #require(String(data: data, encoding: .utf8))
            let pid = try #require(pid_t(string))
            _ = Darwin.kill(-pid, SIGKILL)
        }
        #expect(await waitUntil { await quarantine.state().quarantinedCount == 0 })
    }

    @Test
    func quarantineCapacityFailsClosed() async {
        let quarantine = CmuxConfigActionCatalogProcessQuarantine(
            generalCapacity: 1,
            globalCapacity: 1
        )
        let first = await quarantine.reserve(key: "first", lane: .general)
        #expect(first != nil)
        #expect(await quarantine.reserve(key: "second", lane: .general) == nil)
        let global = await quarantine.reserve(key: "global", lane: .global)
        #expect(global != nil)
        if let first { await quarantine.release(first) }
        if let global { await quarantine.release(global) }
        #expect(await quarantine.reserve(key: "second", lane: .general) != nil)
    }

    @Test
    func cacheKeyRequiresAbsolutePathAndExpandsHome() {
        let globalKey = CmuxConfigStore.actionCatalogCacheKey(startingFrom: nil)
        #expect(CmuxConfigStore.actionCatalogCacheKey(startingFrom: "relative/project") == globalKey)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        #expect(CmuxConfigStore.actionCatalogCacheKey(startingFrom: "~") == home.path)
        #expect(
            CmuxConfigStore.actionCatalogCacheKey(startingFrom: "~/project/../repo")
                == home.appendingPathComponent("repo", isDirectory: true).standardizedFileURL.path
        )
    }

    @Test
    func actionIDsAcceptNoncollisionAndRejectControlCharacters() throws {
        let accepted = Data(#"{"actions":{"palette.customDeploy":{"type":"command","command":"echo deploy"}}}"#.utf8)
        let config = try JSONDecoder().decode(CmuxConfigFile.self, from: accepted)
        #expect(config.actions["palette.customDeploy"] != nil)

        let rejected = Data(#"{"actions":{"custom.\u001bunsafe":{"type":"command","command":"echo unsafe"}}}"#.utf8)
        do {
            _ = try JSONDecoder().decode(CmuxConfigFile.self, from: rejected)
            Issue.record("Expected control characters in action IDs to be rejected")
        } catch {
            #expect(String(describing: error).contains("control or format characters"))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-action-catalog-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func appendField(status: UInt8, payload: Data, to frame: inout Data) {
        frame.append(status)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
    }

    private func actionJSON(id: String, command: String) -> String {
        #"{"actions":{"\#(id)":{"type":"command","command":"\#(command)"}}}"#
    }

    private func workspaceActionJSON(name: String, title: String) -> String {
        """
        {
          "actions": {
            "project.action": { "type": "workspaceCommand", "commandName": "\(name)" },
            "cmux.newTerminal": { "title": "\(title)" }
          },
          "commands": [{ "name": "\(name)", "workspace": { "name": "\(name)" } }]
        }
        """
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await clock.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}
