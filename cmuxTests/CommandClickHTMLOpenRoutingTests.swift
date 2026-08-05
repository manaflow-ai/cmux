import AppKit
import CmuxBrowser
import CmuxFoundation
import Foundation
import Testing
import WebKit
import struct CmuxSettings.AppCatalogSection

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CommandClickHTMLOpenRoutingTests {
    @Test
    func filesystemProbeUsesDeadlineAndPreservesCandidateOrder() async throws {
        let runner = RecordingWordPathProbeCommandRunner(
            resolvedPaths: ["/tmp/second.html": "/private/tmp/second.html"],
            readableRegularPaths: ["/private/tmp/second.html"]
        )
        let probe = WordPathFilesystemProbe(
            commands: runner,
            timeout: 0.25
        )
        let paths = ["/tmp/first.html", "/tmp/second.html"]

        let resolution = await probe.firstExistingPath(in: paths)
        #expect(resolution?.index == 1)
        #expect(resolution?.candidatePath == "/tmp/second.html")
        #expect(resolution?.resolvedPath == "/private/tmp/second.html")
        #expect(resolution?.isReadableRegularFile == true)
        let invocations = await runner.allInvocations()
        #expect(invocations.map(\.executable) == [
            "/bin/realpath",
            "/bin/realpath",
            "/bin/test",
            "/bin/test",
        ])
        #expect(
            invocations
                .filter { $0.executable == "/bin/realpath" }
                .compactMap(\.arguments.first) == paths
        )
        #expect(invocations.allSatisfy { $0.directory == "/" })
        #expect(invocations.allSatisfy { ($0.timeout ?? 0) > 0 && ($0.timeout ?? 1) <= 0.25 })
    }

    @Test
    func filesystemProbeValidatesTheCanonicalTargetAfterResolvingIt() async throws {
        let runner = RecordingWordPathProbeCommandRunner(
            resolvedPaths: ["/tmp/index.html": "/private/tmp/index.html"],
            readableRegularPaths: ["/private/tmp/index.html"]
        )
        let probe = WordPathFilesystemProbe(commands: runner)

        _ = await probe.firstExistingPath(in: ["/tmp/index.html"])

        let invocations = await runner.allInvocations()
        let canonicalization = try #require(invocations.first)
        let regularFileValidation = try #require(invocations.dropFirst().first)
        let readabilityValidation = try #require(invocations.dropFirst(2).first)
        #expect(canonicalization.executable == "/bin/realpath")
        #expect(canonicalization.arguments == ["/tmp/index.html"])
        #expect(regularFileValidation.executable == "/bin/test")
        #expect(regularFileValidation.arguments == ["-f", "/private/tmp/index.html"])
        #expect(readabilityValidation.executable == "/bin/test")
        #expect(readabilityValidation.arguments == ["-r", "/private/tmp/index.html"])
    }

    @Test
    func filesystemProbeFailsClosedWhenDeadlineExpires() async {
        let runner = RecordingWordPathProbeCommandRunner(result: CommandResult(
            stdout: "0\n",
            stderr: "",
            exitStatus: nil,
            timedOut: true,
            executionError: nil
        ))
        let probe = WordPathFilesystemProbe(commands: runner, timeout: 0.25)

        #expect(await probe.firstExistingPath(in: ["/tmp/index.html"]) == nil)
    }

    @Test
    func filesystemProbeKeepsClickedExtensionSeparateFromCanonicalTarget() async throws {
        let runner = RecordingWordPathProbeCommandRunner(
            resolvedPaths: ["/tmp/preview.html": "/private/tmp/generated-file"],
            readableRegularPaths: ["/private/tmp/generated-file"]
        )
        let probe = WordPathFilesystemProbe(commands: runner)

        let resolution = try #require(
            await probe.firstExistingPath(in: ["/tmp/preview.html"])
        )

        #expect(resolution.candidatePath == "/tmp/preview.html")
        #expect(resolution.resolvedPath == "/private/tmp/generated-file")
        #expect(resolution.isReadableRegularFile)
    }

    @Test
    func filesystemProbeExecutesItsScriptForFilesAndDirectories() async throws {
        let fileManager = FileManager.default
        let fixtureDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-word-path-probe-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixtureDirectory) }

        let fileURL = fixtureDirectory.appendingPathComponent("preview.html", isDirectory: false)
        try "<title>Probe</title>".write(to: fileURL, atomically: true, encoding: .utf8)

        let probe = WordPathFilesystemProbe(timeout: 1)
        let fileResolution = try #require(
            await probe.firstExistingPath(in: [fileURL.path])
        )
        #expect(fileResolution.candidatePath == fileURL.path)
        #expect(
            try filesystemIdentity(atPath: fileResolution.resolvedPath)
                == filesystemIdentity(atPath: fileURL.path)
        )
        #expect(fileResolution.isReadableRegularFile)

        let directoryResolution = try #require(
            await probe.firstExistingPath(in: [fixtureDirectory.path])
        )
        #expect(directoryResolution.candidatePath == fixtureDirectory.path)
        #expect(
            try filesystemIdentity(atPath: directoryResolution.resolvedPath)
                == filesystemIdentity(atPath: fixtureDirectory.path)
        )
        #expect(!directoryResolution.isReadableRegularFile)
    }

    @Test
    func workspacesOwnIndependentFilesystemResolutionCoordinators() throws {
        _ = NSApplication.shared

        let first = Workspace()
        let second = Workspace()
        let browserWorkspace = Workspace(initialSurface: .browser)
        defer {
            first.teardownAllPanels()
            second.teardownAllPanels()
            browserWorkspace.teardownAllPanels()
        }

        #expect(first.filesystemResolutionCoordinator !== second.filesystemResolutionCoordinator)
        #expect(first.dockSplit.filesystemResolutionCoordinator === first.filesystemResolutionCoordinator)

        let firstTerminal = try #require(
            first.panels.values.compactMap { $0 as? TerminalPanel }.first
        )
        #expect(
            firstTerminal.hostedView.surfaceView.wordPathFilesystemResolutionCoordinator
                === first.filesystemResolutionCoordinator
        )

        let browser = try #require(
            browserWorkspace.panels.values.compactMap { $0 as? BrowserPanel }.first
        )
        #expect(
            browser.filesystemResolutionCoordinator
                === browserWorkspace.filesystemResolutionCoordinator
        )
    }

    @Test
    func hoverFilesystemProbePoolRunsOneAndRetainsOnlyLatestPendingJob() async {
        let pool = WordPathFilesystemResolutionCoordinator()
        let firstStarted = AsyncStream<Void>.makeStream()
        let releaseFirst = AsyncStream<Void>.makeStream()
        let secondDiscarded = AsyncStream<Void>.makeStream()
        let thirdFinished = AsyncStream<Void>.makeStream()
        let secondPrepared = AtomicBooleanGate(false)
        let secondRan = AtomicBooleanGate(false)

        pool.submit(
            id: UUID(),
            isUserInitiated: false,
            work: {
                firstStarted.continuation.yield()
                var releaseIterator = releaseFirst.stream.makeAsyncIterator()
                _ = await releaseIterator.next()
                return { @MainActor in }
            },
            discarded: {}
        )
        var firstStartedIterator = firstStarted.stream.makeAsyncIterator()
        _ = await firstStartedIterator.next()

        pool.submit(
            id: UUID(),
            isUserInitiated: false,
            prepare: {
                secondPrepared.storeRelease(true)
                return {
                    secondRan.storeRelease(true)
                    return { @MainActor in }
                }
            },
            discarded: { secondDiscarded.continuation.yield() }
        )
        pool.submit(
            id: UUID(),
            isUserInitiated: false,
            work: {
                thirdFinished.continuation.yield()
                return { @MainActor in }
            },
            discarded: {}
        )

        var secondDiscardedIterator = secondDiscarded.stream.makeAsyncIterator()
        _ = await secondDiscardedIterator.next()
        releaseFirst.continuation.yield()
        var thirdFinishedIterator = thirdFinished.stream.makeAsyncIterator()
        _ = await thirdFinishedIterator.next()
        #expect(!secondPrepared.loadAcquire())
        #expect(!secondRan.loadAcquire())

        firstStarted.continuation.finish()
        releaseFirst.continuation.finish()
        secondDiscarded.continuation.finish()
        thirdFinished.continuation.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func filesystemProbePoolPreservesDistinctPendingClicks() async {
        let pool = WordPathFilesystemResolutionCoordinator()
        let hoverStarted = AsyncStream<Void>.makeStream()
        let releaseHover = AsyncStream<Void>.makeStream()
        let clicksFinished = AsyncStream<Int>.makeStream()

        pool.submit(
            id: UUID(),
            isUserInitiated: false,
            work: {
                hoverStarted.continuation.yield()
                var releaseIterator = releaseHover.stream.makeAsyncIterator()
                _ = await releaseIterator.next()
                return { @MainActor in }
            },
            discarded: {}
        )
        var hoverStartedIterator = hoverStarted.stream.makeAsyncIterator()
        _ = await hoverStartedIterator.next()

        for click in 1...2 {
            pool.submit(
                id: UUID(),
                isUserInitiated: true,
                work: {
                    return { @MainActor in clicksFinished.continuation.yield(click) }
                },
                discarded: {}
            )
        }
        releaseHover.continuation.yield()

        var clickIterator = clicksFinished.stream.makeAsyncIterator()
        let firstClick = await clickIterator.next()
        let secondClick = await clickIterator.next()
        let completedClicks = [firstClick, secondClick].compactMap { $0 }
        #expect(completedClicks == [1, 2])

        hoverStarted.continuation.finish()
        releaseHover.continuation.finish()
        clicksFinished.continuation.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func filesystemProbePoolRunsBrowserWorkIndependentlyOfQueuedClicks() async {
        let pool = WordPathFilesystemResolutionCoordinator()
        let firstClickStarted = AsyncStream<Void>.makeStream()
        let releaseFirstClick = AsyncStream<Void>.makeStream()
        let events = AsyncStream<String>.makeStream()

        pool.submit(
            id: UUID(),
            isUserInitiated: true,
            work: {
                firstClickStarted.continuation.yield()
                var releaseIterator = releaseFirstClick.stream.makeAsyncIterator()
                _ = await releaseIterator.next()
                return { @MainActor in events.continuation.yield("click-1") }
            },
            discarded: {}
        )
        var firstClickStartedIterator = firstClickStarted.stream.makeAsyncIterator()
        _ = await firstClickStartedIterator.next()

        pool.submit(
            id: UUID(),
            isUserInitiated: true,
            work: {
                return { @MainActor in events.continuation.yield("click-2") }
            },
            discarded: {}
        )
        pool.submitCoalesced(
            id: UUID(),
            coalescingKey: UUID(),
            work: {
                return { @MainActor in events.continuation.yield("browser") }
            },
            discarded: {},
            rejected: {}
        )

        var eventIterator = events.stream.makeAsyncIterator()
        #expect(await eventIterator.next() == "browser")

        releaseFirstClick.continuation.yield()
        #expect(await eventIterator.next() == "click-1")
        #expect(await eventIterator.next() == "click-2")

        firstClickStarted.continuation.finish()
        releaseFirstClick.continuation.finish()
        events.continuation.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func filesystemProbePoolPreservesDistinctCoalescedOwnersBeyondClickLimit() async {
        let pool = WordPathFilesystemResolutionCoordinator()
        let blockerStarted = AsyncStream<Void>.makeStream()
        let releaseBlocker = AsyncStream<Void>.makeStream()
        let jobsFinished = AsyncStream<Int>.makeStream()

        pool.submit(
            id: UUID(),
            isUserInitiated: false,
            work: {
                blockerStarted.continuation.yield()
                var releaseIterator = releaseBlocker.stream.makeAsyncIterator()
                _ = await releaseIterator.next()
                return { @MainActor in }
            },
            discarded: {}
        )
        var blockerIterator = blockerStarted.stream.makeAsyncIterator()
        _ = await blockerIterator.next()

        for job in 1...40 {
            pool.submitCoalesced(
                id: UUID(),
                coalescingKey: UUID(),
                work: {
                    return { @MainActor in jobsFinished.continuation.yield(job) }
                },
                discarded: {},
                rejected: {}
            )
        }

        var finishedIterator = jobsFinished.stream.makeAsyncIterator()
        var completedJobs: [Int] = []
        for _ in 1...40 {
            if let job = await finishedIterator.next() {
                completedJobs.append(job)
            }
        }
        #expect(completedJobs.sorted() == Array(1...40))

        releaseBlocker.continuation.yield()

        blockerStarted.continuation.finish()
        releaseBlocker.continuation.finish()
        jobsFinished.continuation.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func filesystemProbePoolKeepsOnlyLatestPendingJobForOneCoalescedOwner() async {
        let pool = WordPathFilesystemResolutionCoordinator(
            maximumConcurrentCoalescedJobs: 1
        )
        let blockerStarted = AsyncStream<Void>.makeStream()
        let releaseBlocker = AsyncStream<Void>.makeStream()
        let firstDiscarded = AsyncStream<Void>.makeStream()
        let latestFinished = AsyncStream<Void>.makeStream()
        let firstRan = AtomicBooleanGate(false)
        let owner = UUID()

        pool.submitCoalesced(
            id: UUID(),
            coalescingKey: UUID(),
            work: {
                blockerStarted.continuation.yield()
                var releaseIterator = releaseBlocker.stream.makeAsyncIterator()
                _ = await releaseIterator.next()
                return { @MainActor in }
            },
            discarded: {},
            rejected: {}
        )
        var blockerIterator = blockerStarted.stream.makeAsyncIterator()
        _ = await blockerIterator.next()

        pool.submitCoalesced(
            id: UUID(),
            coalescingKey: owner,
            work: {
                firstRan.storeRelease(true)
                return { @MainActor in }
            },
            discarded: { firstDiscarded.continuation.yield() },
            rejected: {}
        )
        pool.submitCoalesced(
            id: UUID(),
            coalescingKey: owner,
            work: {
                return { @MainActor in latestFinished.continuation.yield() }
            },
            discarded: {},
            rejected: {}
        )

        var discardedIterator = firstDiscarded.stream.makeAsyncIterator()
        _ = await discardedIterator.next()
        releaseBlocker.continuation.yield()
        var latestIterator = latestFinished.stream.makeAsyncIterator()
        _ = await latestIterator.next()
        #expect(!firstRan.loadAcquire())

        blockerStarted.continuation.finish()
        releaseBlocker.continuation.finish()
        firstDiscarded.continuation.finish()
        latestFinished.continuation.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func filesystemProbePoolRejectsANewOwnerWhenItsBoundedQueueIsFull() async {
        let pool = WordPathFilesystemResolutionCoordinator(
            maximumConcurrentCoalescedJobs: 1,
            maximumPendingCoalescedOwners: 1
        )
        let blockerStarted = AsyncStream<Void>.makeStream()
        let releaseBlocker = AsyncStream<Void>.makeStream()
        let pendingFinished = AsyncStream<Void>.makeStream()
        let rejected = AsyncStream<Void>.makeStream()
        let rejectedWorkRan = AtomicBooleanGate(false)

        pool.submitCoalesced(
            id: UUID(),
            coalescingKey: UUID(),
            work: {
                blockerStarted.continuation.yield()
                var releaseIterator = releaseBlocker.stream.makeAsyncIterator()
                _ = await releaseIterator.next()
                return { @MainActor in }
            },
            discarded: {},
            rejected: {}
        )
        var blockerIterator = blockerStarted.stream.makeAsyncIterator()
        _ = await blockerIterator.next()

        pool.submitCoalesced(
            id: UUID(),
            coalescingKey: UUID(),
            work: {
                return { @MainActor in pendingFinished.continuation.yield() }
            },
            discarded: {},
            rejected: {}
        )
        pool.submitCoalesced(
            id: UUID(),
            coalescingKey: UUID(),
            work: {
                rejectedWorkRan.storeRelease(true)
                return { @MainActor in }
            },
            discarded: {},
            rejected: { rejected.continuation.yield() }
        )

        var rejectedIterator = rejected.stream.makeAsyncIterator()
        _ = await rejectedIterator.next()
        #expect(!rejectedWorkRan.loadAcquire())

        releaseBlocker.continuation.yield()
        var pendingFinishedIterator = pendingFinished.stream.makeAsyncIterator()
        _ = await pendingFinishedIterator.next()

        blockerStarted.continuation.finish()
        releaseBlocker.continuation.finish()
        pendingFinished.continuation.finish()
        rejected.continuation.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func filesystemProbePoolRateLimitsConsecutiveHovers() async {
        let pool = WordPathFilesystemResolutionCoordinator(
            minimumHoverInterval: .milliseconds(80)
        )
        let firstFinished = AsyncStream<Void>.makeStream()
        let secondFinished = AsyncStream<Void>.makeStream()

        pool.submit(
            id: UUID(),
            isUserInitiated: false,
            work: { return { @MainActor in firstFinished.continuation.yield() } },
            discarded: {}
        )
        var firstIterator = firstFinished.stream.makeAsyncIterator()
        _ = await firstIterator.next()

        let submittedAt = ContinuousClock.now
        pool.submit(
            id: UUID(),
            isUserInitiated: false,
            work: { return { @MainActor in secondFinished.continuation.yield() } },
            discarded: {}
        )
        var secondIterator = secondFinished.stream.makeAsyncIterator()
        _ = await secondIterator.next()

        #expect(submittedAt.duration(to: .now) >= .milliseconds(50))
        firstFinished.continuation.finish()
        secondFinished.continuation.finish()
    }

    @Test
    func hoverCacheIdentityIncludesSurfaceGenerationAndDirectory() {
        let surfaceID = UUID()
        let base = WordPathHoverCacheKey(
            surfaceID: surfaceID,
            surfaceGeneration: 1,
            row: 2,
            column: 3,
            rows: 24,
            columns: 80,
            boundsSize: CGSize(width: 800, height: 480),
            cellSize: CGSize(width: 10, height: 20),
            workingDirectory: "/tmp/one"
        )

        #expect(base != WordPathHoverCacheKey(
            surfaceID: surfaceID,
            surfaceGeneration: 2,
            row: 2,
            column: 3,
            rows: 24,
            columns: 80,
            boundsSize: CGSize(width: 800, height: 480),
            cellSize: CGSize(width: 10, height: 20),
            workingDirectory: "/tmp/one"
        ))
        #expect(base != WordPathHoverCacheKey(
            surfaceID: surfaceID,
            surfaceGeneration: 1,
            row: 2,
            column: 3,
            rows: 24,
            columns: 80,
            boundsSize: CGSize(width: 800, height: 480),
            cellSize: CGSize(width: 10, height: 20),
            workingDirectory: "/tmp/two"
        ))
    }

    @Test
    func negativeHoverCacheExpiresWithoutReprobingEveryRenderedFrame() {
        let request = WordPathHoverResolutionRequest(
            identity: WordPathHoverResolutionIdentity(
                key: WordPathHoverCacheKey(
                    surfaceID: UUID(),
                    surfaceGeneration: 1,
                    row: 2,
                    column: 3,
                    rows: 24,
                    columns: 80,
                    boundsSize: CGSize(width: 800, height: 480),
                    cellSize: CGSize(width: 10, height: 20),
                    workingDirectory: "/tmp"
                ),
                quicklook: nil
            ),
            snapshot: WordPathResolutionSnapshot(
                workingDirectory: "/tmp",
                point: nil,
                quicklook: nil,
                viewport: nil
            ),
            renderedFrameGeneration: 1
        )
        let entry = WordPathHoverCacheEntry(
            request: request,
            resolution: nil,
            storedAt: 10
        )

        #expect(entry.hasFreshNegativeResult(at: 10.999, maximumAge: 1))
        #expect(!entry.hasFreshNegativeResult(at: 11, maximumAge: 1))
        #expect(!entry.hasFreshNegativeResult(at: 9, maximumAge: 1))
        #expect(entry.updatingRequest(
            request.updatingRenderedFrameGeneration(2)
        ).storedAt == 10)
    }

    @Test
    func htmlPathOpensInBrowserInsteadOfFilePreview() throws {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let supportedFilesKey = AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        let previousSupportedFiles = defaults.object(forKey: supportedFilesKey)
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defer {
            restore(previousSupportedFiles, forKey: supportedFilesKey, in: defaults)
            restore(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey, in: defaults)
        }
        defaults.set(true, forKey: supportedFilesKey)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let htmlURL = fixtureDirectory.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>cmux test</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let sourcePanelId = try #require(workspace.focusedPanelId)

        #expect(openResolvedHTMLInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: htmlURL.path
        ))

        let browser = try #require(workspace.panels.values.compactMap { $0 as? BrowserPanel }.first)
        #expect(browser.currentURL?.standardizedFileURL == htmlURL.standardizedFileURL)
        #expect(!workspace.panels.values.contains { panel in
            guard let preview = panel as? FilePreviewPanel else { return false }
            return URL(fileURLWithPath: preview.filePath).standardizedFileURL == htmlURL.standardizedFileURL
        })
    }

    @Test
    func htmlBrowserRoutingDoesNotDependOnSupportedFilesPreference() throws {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let supportedFilesKey = AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        let previousSupportedFiles = defaults.object(forKey: supportedFilesKey)
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defer {
            restore(previousSupportedFiles, forKey: supportedFilesKey, in: defaults)
            restore(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey, in: defaults)
        }
        defaults.set(false, forKey: supportedFilesKey)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)

        let htmlURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-html-route-independent-\(UUID().uuidString).html")
        try "<html></html>".write(to: htmlURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: htmlURL) }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let sourcePanelId = try #require(workspace.focusedPanelId)

        #expect(openResolvedHTMLInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: htmlURL.path,
            defaults: defaults
        ))
        #expect(workspace.panels.values.compactMap { $0 as? BrowserPanel }.count == 1)
        #expect(workspace.panels.values.compactMap { $0 as? FilePreviewPanel }.isEmpty)
    }

    @Test
    func fileOnlyBrowserLoadRejectsAnUnvalidatedDirectory() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-only-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let webView = WKWebView()
        let navigation = browserLoadRequest(
            URLRequest(url: directoryURL),
            in: webView,
            localFileReadAccessPolicy: .fileOnly
        )

        #expect(navigation == nil)
        webView.stopLoading()
    }

    @Test
    func validatedFileNavigationAllowanceIsExactMainFrameAndOneShot() throws {
        let expectedURL = try #require(URL(string: "file:///tmp/expected.html"))
        let otherURL = try #require(URL(string: "file:///tmp/other.html"))
        var allowance = BrowserValidatedFileNavigationAllowance()

        let authorizedForSubframeCheck = allowance.authorize(expectedURL)
        let rejectedSubframe = allowance.consumeIfMatches(
            expectedURL,
            targetFrameIsMainFrame: false
        )
        let rejectedAfterSubframeAttempt = allowance.consumeIfMatches(
            expectedURL,
            targetFrameIsMainFrame: true
        )
        #expect(authorizedForSubframeCheck)
        #expect(!rejectedSubframe)
        #expect(!rejectedAfterSubframeAttempt)

        let authorizedForMismatchCheck = allowance.authorize(expectedURL)
        let rejectedMismatch = allowance.consumeIfMatches(
            otherURL,
            targetFrameIsMainFrame: true
        )
        let rejectedAfterMismatch = allowance.consumeIfMatches(
            expectedURL,
            targetFrameIsMainFrame: true
        )
        #expect(authorizedForMismatchCheck)
        #expect(!rejectedMismatch)
        #expect(!rejectedAfterMismatch)

        let authorizedForConsumption = allowance.authorize(expectedURL)
        let consumedExactMainFrame = allowance.consumeIfMatches(
            expectedURL,
            targetFrameIsMainFrame: true
        )
        let rejectedSecondConsumption = allowance.consumeIfMatches(
            expectedURL,
            targetFrameIsMainFrame: true
        )
        #expect(authorizedForConsumption)
        #expect(consumedExactMainFrame)
        #expect(!rejectedSecondConsumption)
    }

    @Test(.timeLimit(.minutes(1)))
    func fileOnlyBrowserRejectsScriptInitiatedInPageFileNavigation() async throws {
        _ = NSApplication.shared

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-only-in-page-\(UUID().uuidString)", isDirectory: true)
        let firstURL = fixtureDirectory.appendingPathComponent("first.html")
        let secondURL = fixtureDirectory.appendingPathComponent("second.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>first file</title><a id='next' href='\(secondURL.absoluteString)'>Next</a>".write(
            to: firstURL,
            atomically: true,
            encoding: .utf8
        )
        try "<!doctype html><title>validated in-page file</title>".write(
            to: secondURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let browser = BrowserPanel(
            workspaceId: UUID(),
            initialURL: firstURL,
            localFileReadAccessPolicy: .fileOnly
        )
        defer { browser.close() }

        #expect(await waitForDocumentTitle("first file", in: browser))
        _ = try await browser.webView.evaluateJavaScript("document.getElementById('next').click()")

        try await Task.sleep(for: .milliseconds(500))
        #expect(await waitForDocumentTitle("first file", in: browser))
        #expect(browser.webView.url?.standardizedFileURL == firstURL.standardizedFileURL)
    }

    @Test(.timeLimit(.minutes(1)))
    func fileOnlyBrowserReloadRevalidatesTheCurrentFile() async throws {
        _ = NSApplication.shared

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-only-reload-\(UUID().uuidString)", isDirectory: true)
        let fileURL = fixtureDirectory.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>before reload</title>".write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let browser = BrowserPanel(
            workspaceId: UUID(),
            initialURL: fileURL,
            localFileReadAccessPolicy: .fileOnly
        )
        defer { browser.close() }

        #expect(await waitForDocumentTitle("before reload", in: browser))
        try "<!doctype html><title>after reload</title>".write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )

        browser.reload()

        #expect(await waitForDocumentTitle("after reload", in: browser))
    }

    @Test(.timeLimit(.minutes(1)))
    func fileOnlyBrowserBackAndForwardRevalidateNativeHistoryTargets() async throws {
        _ = NSApplication.shared

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-only-history-\(UUID().uuidString)", isDirectory: true)
        let firstURL = fixtureDirectory.appendingPathComponent("first.html")
        let secondURL = fixtureDirectory.appendingPathComponent("second.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>history first</title>".write(
            to: firstURL,
            atomically: true,
            encoding: .utf8
        )
        try "<!doctype html><title>history second</title>".write(
            to: secondURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let browser = BrowserPanel(
            workspaceId: UUID(),
            initialURL: firstURL,
            localFileReadAccessPolicy: .fileOnly
        )
        defer { browser.close() }

        #expect(await waitForDocumentTitle("history first", in: browser))
        browser.navigate(to: secondURL)
        #expect(await waitForDocumentTitle("history second", in: browser))
        #expect(await waitForHistoryAvailability(in: browser, back: true, forward: false))

        browser.goBack()
        #expect(await waitForDocumentTitle("history first", in: browser))
        #expect(await waitForHistoryAvailability(in: browser, back: false, forward: true))

        browser.goForward()
        #expect(await waitForDocumentTitle("history second", in: browser))
    }

    @Test(.timeLimit(.minutes(1)))
    func fileOnlyPopupRejectsUnvalidatedFileNavigation() async throws {
        _ = NSApplication.shared

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-only-popup-\(UUID().uuidString)", isDirectory: true)
        let unrelatedAccessURL = fixtureDirectory.appendingPathComponent("opener.html")
        let popupURL = fixtureDirectory.appendingPathComponent("popup.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>opener</title>".write(
            to: unrelatedAccessURL,
            atomically: true,
            encoding: .utf8
        )
        try "<!doctype html><title>validated popup file</title>".write(
            to: popupURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let controller = BrowserPopupWindowController(
            configuration: WKWebViewConfiguration(),
            windowFeatures: WKWindowFeatures(),
            browserContext: BrowserPopupBrowserContext(
                websiteDataStore: .nonPersistent(),
                localFileReadAccessPolicy: .fileOnly,
                filesystemResolutionCoordinator: WordPathFilesystemResolutionCoordinator()
            ),
            openerPanel: nil
        )
        defer { controller.closePopup() }

        _ = controller.webView.loadFileURL(
            popupURL,
            allowingReadAccessTo: unrelatedAccessURL
        )

        try await Task.sleep(for: .milliseconds(500))
        #expect(controller.webView.url?.standardizedFileURL != popupURL.standardizedFileURL)
        let title = try? await controller.webView.evaluateJavaScript("document.title")
        #expect(title as? String != "validated popup file")
    }

    @Test(.timeLimit(.minutes(1)))
    func failedFileOnlyDiscardRestoreLeavesStableRecoveryState() async throws {
        _ = NSApplication.shared

        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-only-discard-\(UUID().uuidString).html")
        let browser = BrowserPanel(
            workspaceId: UUID(),
            initialURL: nil,
            renderInitialNavigation: false,
            localFileReadAccessPolicy: .fileOnly
        )
        defer { browser.close() }

        browser.restoreSessionSnapshot(SessionBrowserPanelSnapshot(
            urlString: missingURL.absoluteString,
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1.0,
            developerToolsVisible: false,
            backHistoryURLStrings: [],
            forwardHistoryURLStrings: []
        ))
        #expect(browser.restoreDiscardedWebViewIfNeeded(reason: "test.reveal"))
        #expect(await waitForNavigationRecovery(in: browser))

        let payload = browser.webViewLifecycleTopPayload()
        #expect(payload["restore_pending"] as? Bool == false)
        #expect((payload["discard_blockers"] as? [String])?.contains("already_discarded") == false)
        #expect(!browser.restoreDiscardedWebViewIfNeeded(reason: "test.visibility_touch"))
        #expect(browser.hasRecoverableNavigationFailure)
    }

    @Test
    func fileOnlyPolicyRejectsRemoteFileAuthorities() throws {
        let remoteFileURL = try #require(URL(string: "file://server.example/tmp/report.html"))
        let resolvedLocalURL = URL(fileURLWithPath: "/tmp/report.html")

        #expect(BrowserLocalFileReadAccessPolicy.fileOnly.navigationURL(
            for: remoteFileURL,
            resolvedFileURL: resolvedLocalURL
        ) == nil)
        #expect(BrowserLocalFileReadAccessPolicy.fileOnly.readAccessURL(for: remoteFileURL) == nil)
    }

    @Test
    func resolvedSupportedFileRouteDoesNotRevalidateTheCandidate() throws {
        _ = NSApplication.shared

        let suiteName = "resolved-supported-file-route-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            true,
            forKey: AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        )

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-resolved-route-\(UUID().uuidString).txt")
        try "validated before dispatch".write(to: fileURL, atomically: true, encoding: .utf8)
        let validatedURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.removeItem(at: fileURL)

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let sourcePanelId = try #require(workspace.focusedPanelId)

        #expect(CommandClickFileOpenRouter.openInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: fileURL.path,
            resolvedFileURL: validatedURL,
            defaults: defaults
        ))
        #expect(workspace.panels.values.contains { $0 is FilePreviewPanel })
    }

    @Test
    func missingFileOnlyBrowserExposesAWorkingRetryState() async throws {
        _ = NSApplication.shared

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-only-retry-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let browser = BrowserPanel(
            workspaceId: UUID(),
            initialURL: fileURL,
            localFileReadAccessPolicy: .fileOnly
        )
        defer { browser.close() }

        #expect(await waitForNavigationRecovery(in: browser))
        #expect(browser.hasRecoverableNavigationFailure)
        #expect(browser.currentURL == fileURL)

        try "<!doctype html><title>retry succeeded</title>".write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
        #expect(browser.recoverFailedNavigation(reason: "test"))
        #expect(await waitForDocumentTitle("retry succeeded", in: browser))
        #expect(!browser.hasRecoverableNavigationFailure)
    }

    @Test(.timeLimit(.minutes(1)))
    func validatedHTMLCreationDoesNotWaitForTheFilesystemProbeQueue() async throws {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)
        defer {
            restore(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey, in: defaults)
        }

        let htmlURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-validated-html-\(UUID().uuidString).html")
        try "<!doctype html><title>validated without another probe</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: htmlURL) }

        let blockerStarted = AsyncStream<Void>.makeStream()
        let releaseBlocker = AsyncStream<Void>.makeStream()
        let blockerFinished = AsyncStream<Void>.makeStream()
        let filesystemResolutionCoordinator = WordPathFilesystemResolutionCoordinator()
        filesystemResolutionCoordinator.submit(
            id: UUID(),
            isUserInitiated: true,
            work: {
                blockerStarted.continuation.yield()
                var releaseIterator = releaseBlocker.stream.makeAsyncIterator()
                _ = await releaseIterator.next()
                return { @MainActor in blockerFinished.continuation.yield() }
            },
            discarded: {}
        )
        var blockerStartedIterator = blockerStarted.stream.makeAsyncIterator()
        _ = await blockerStartedIterator.next()

        let workspace = Workspace(
            filesystemResolutionCoordinator: filesystemResolutionCoordinator
        )
        defer { workspace.teardownAllPanels() }
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let opened = openResolvedHTMLInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: htmlURL.path
        )
        let browser = workspace.panels.values.compactMap { $0 as? BrowserPanel }.first
        var loaded = false
        if let browser {
            loaded = await waitForDocumentTitle("validated without another probe", in: browser)
        }

        releaseBlocker.continuation.yield()
        var blockerFinishedIterator = blockerFinished.stream.makeAsyncIterator()
        _ = await blockerFinishedIterator.next()
        blockerStarted.continuation.finish()
        releaseBlocker.continuation.finish()
        blockerFinished.continuation.finish()

        #expect(opened)
        #expect(browser != nil)
        #expect(loaded)
    }

    @Test
    func repeatedHTMLPathOpenFocusesOneBrowser() throws {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let supportedFilesKey = AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        let previousSupportedFiles = defaults.object(forKey: supportedFilesKey)
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defer {
            restore(previousSupportedFiles, forKey: supportedFilesKey, in: defaults)
            restore(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey, in: defaults)
        }
        defaults.set(true, forKey: supportedFilesKey)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let htmlURL = fixtureDirectory.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>single browser</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let sourcePanelId = try #require(workspace.focusedPanelId)

        for _ in 0..<2 {
            #expect(openResolvedHTMLInCmux(
                workspace: workspace,
                sourcePanelId: sourcePanelId,
                filePath: htmlURL.path
            ))
        }

        let browsers = workspace.panels.values.compactMap { $0 as? BrowserPanel }
        #expect(browsers.count == 1)
        #expect(workspace.focusedPanelId == browsers.first?.id)
    }

    @Test
    func repeatedHTMLPathThroughFilesystemAliasReusesOneBrowser() async throws {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let supportedFilesKey = AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        let previousSupportedFiles = defaults.object(forKey: supportedFilesKey)
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defer {
            restore(previousSupportedFiles, forKey: supportedFilesKey, in: defaults)
            restore(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey, in: defaults)
        }
        defaults.set(true, forKey: supportedFilesKey)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)

        let fixtureDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-html-alias-\(UUID().uuidString)", isDirectory: true)
        let htmlURL = fixtureDirectory.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>filesystem alias</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let sourcePanelId = try #require(workspace.focusedPanelId)

        #expect(openResolvedHTMLInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: htmlURL.path
        ))
        let browser = try #require(workspace.panels.values.compactMap { $0 as? BrowserPanel }.first)
        #expect(await waitForDocumentTitle("filesystem alias", in: browser))

        #expect(openResolvedHTMLInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: htmlURL.path
        ))
        #expect(workspace.panels.values.compactMap { $0 as? BrowserPanel }.count == 1)
    }

    @Test
    func decoratedHTMLURLStillReusesOneBrowser() throws {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let supportedFilesKey = AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        let previousSupportedFiles = defaults.object(forKey: supportedFilesKey)
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defer {
            restore(previousSupportedFiles, forKey: supportedFilesKey, in: defaults)
            restore(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey, in: defaults)
        }
        defaults.set(true, forKey: supportedFilesKey)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let htmlURL = fixtureDirectory.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>decorated browser URL</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let sourcePanelId = try #require(workspace.focusedPanelId)

        #expect(openResolvedHTMLInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: htmlURL.path
        ))
        let browser = try #require(workspace.panels.values.compactMap { $0 as? BrowserPanel }.first)
        var components = try #require(URLComponents(url: htmlURL, resolvingAgainstBaseURL: false))
        components.query = "preview=1"
        components.fragment = "section"
        let decoratedURL = try #require(components.url)
        browser.isMainFrameProvisionalNavigationActive = true
        browser.navigationDelegate?.recordAttemptedRequest(URLRequest(url: decoratedURL))

        #expect(openResolvedHTMLInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: htmlURL.path
        ))

        #expect(workspace.panels.values.compactMap { $0 as? BrowserPanel }.count == 1)
        #expect(workspace.focusedPanelId == browser.id)
    }

    @Test
    func repeatedHTMLPathOpenReloadsChangedContent() async throws {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let supportedFilesKey = AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        let previousSupportedFiles = defaults.object(forKey: supportedFilesKey)
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defer {
            restore(previousSupportedFiles, forKey: supportedFilesKey, in: defaults)
            restore(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey, in: defaults)
        }
        defaults.set(true, forKey: supportedFilesKey)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let htmlURL = fixtureDirectory.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>before regeneration</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let sourcePanelId = try #require(workspace.focusedPanelId)

        #expect(openResolvedHTMLInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: htmlURL.path
        ))
        let browser = try #require(workspace.panels.values.compactMap { $0 as? BrowserPanel }.first)
        #expect(await waitForDocumentTitle("before regeneration", in: browser))

        try "<!doctype html><title>after regeneration</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        #expect(openResolvedHTMLInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: htmlURL.path
        ))

        #expect(workspace.panels.values.compactMap { $0 as? BrowserPanel }.count == 1)
        #expect(await waitForDocumentTitle("after regeneration", in: browser))
    }

    @Test
    func commandClickedHTMLUsesFileOnlyReadAccess() throws {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let supportedFilesKey = AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        let previousSupportedFiles = defaults.object(forKey: supportedFilesKey)
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defer {
            restore(previousSupportedFiles, forKey: supportedFilesKey, in: defaults)
            restore(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey, in: defaults)
        }
        defaults.set(true, forKey: supportedFilesKey)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let htmlURL = fixtureDirectory.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>restricted read access</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let sourcePanelId = try #require(workspace.focusedPanelId)

        #expect(openResolvedHTMLInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: htmlURL.path
        ))

        let browser = try #require(workspace.panels.values.compactMap { $0 as? BrowserPanel }.first)
        let readAccessPolicy = Mirror(reflecting: browser).children
            .first(where: { $0.label == "localFileReadAccessPolicy" })
            .map { String(describing: $0.value) }
        #expect(readAccessPolicy == "fileOnly")
        #expect(browser.bypassesRemoteWorkspaceProxyForTabDuplication)
        #expect(
            browser.webView.configuration.websiteDataStore ===
                BrowserProfileStore.shared.websiteDataStore(for: browser.profileID)
        )
    }

    @Test
    func restrictedHTMLNewTabPreservesFileOnlyReadAccess() async throws {
        _ = NSApplication.shared

        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        let manager = TabManager()
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousShared
        }

        let workspace = try #require(manager.selectedWorkspace)
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: sourcePanelId))
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let htmlURL = fixtureDirectory.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>restricted child tab</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let browser = try #require(workspace.newBrowserSurface(
            inPane: paneId,
            url: htmlURL,
            focus: true,
            localFileReadAccessPolicy: .fileOnly
        ))
        browser.openLinkInNewTab(url: htmlURL)
        #expect(await waitForBrowserCount(2, in: workspace))

        let browsers = workspace.panels.values.compactMap { $0 as? BrowserPanel }
        #expect(browsers.count == 2)
        #expect(browsers.allSatisfy { $0.localFileReadAccessPolicy == .fileOnly })
        #expect(browsers.allSatisfy { $0.bypassesRemoteWorkspaceProxyForTabDuplication })
        #expect(browsers.allSatisfy {
            $0.webView.configuration.websiteDataStore ===
                BrowserProfileStore.shared.websiteDataStore(for: $0.profileID)
        })
    }

    @Test
    func restrictedHTMLNewTabShowsRecoveryWhenTheTargetIsMissing() async throws {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)

        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        let manager = TabManager()
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            restore(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey, in: defaults)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousShared
        }

        let workspace = try #require(manager.selectedWorkspace)
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: sourcePanelId))
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let openerURL = fixtureDirectory.appendingPathComponent("opener.html")
        let missingURL = fixtureDirectory.appendingPathComponent("missing.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>restricted opener</title>".write(
            to: openerURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let browser = try #require(workspace.newBrowserSurface(
            inPane: paneId,
            url: openerURL,
            focus: true,
            localFileReadAccessPolicy: .fileOnly
        ))
        browser.openLinkInNewTab(url: missingURL)

        #expect(await waitForBrowserCount(2, in: workspace))
        let child = try #require(
            workspace.panels.values
                .compactMap { $0 as? BrowserPanel }
                .first(where: { $0.id != browser.id })
        )
        #expect(await waitForNavigationRecovery(in: child))
        #expect(child.currentURL == missingURL)
    }

    @Test
    func restrictedHTMLNewTabResolvesSymlinkTarget() async throws {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)

        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        let manager = TabManager()
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            restore(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey, in: defaults)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousShared
        }

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let linkDirectory = fixtureDirectory.appendingPathComponent("link", isDirectory: true)
        let targetDirectory = fixtureDirectory.appendingPathComponent("target", isDirectory: true)
        let openerURL = linkDirectory.appendingPathComponent("opener.html")
        let symlinkURL = linkDirectory.appendingPathComponent("child.html")
        let targetURL = targetDirectory.appendingPathComponent("child.html")
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>restricted opener</title>".write(
            to: openerURL,
            atomically: true,
            encoding: .utf8
        )
        try "<!doctype html><title>restricted child target</title>".write(
            to: targetURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let workspace = try #require(manager.selectedWorkspace)
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: sourcePanelId))
        let browser = try #require(workspace.newBrowserSurface(
            inPane: paneId,
            url: openerURL,
            focus: true,
            localFileReadAccessPolicy: .fileOnly
        ))

        browser.openLinkInNewTab(url: symlinkURL)
        #expect(await waitForBrowserCount(2, in: workspace))

        let child = try #require(
            workspace.panels.values
                .compactMap { $0 as? BrowserPanel }
                .first(where: { $0.id != browser.id })
        )
        #expect(child.localFileReadAccessPolicy == .fileOnly)
        #expect(child.currentURL?.standardizedFileURL == targetURL.standardizedFileURL)
    }

    @Test
    func unrestrictedHTMLNewTabPreservesSymlinkDocumentURL() throws {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)

        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        let manager = TabManager()
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            restore(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey, in: defaults)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousShared
        }

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let linkDirectory = fixtureDirectory.appendingPathComponent("link", isDirectory: true)
        let targetDirectory = fixtureDirectory.appendingPathComponent("target", isDirectory: true)
        let openerURL = linkDirectory.appendingPathComponent("opener.html")
        let symlinkURL = linkDirectory.appendingPathComponent("child.html")
        let targetURL = targetDirectory.appendingPathComponent("child.html")
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>unrestricted opener</title>".write(
            to: openerURL,
            atomically: true,
            encoding: .utf8
        )
        try "<!doctype html><title>unrestricted child target</title>".write(
            to: targetURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let workspace = try #require(manager.selectedWorkspace)
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: sourcePanelId))
        let browser = try #require(workspace.newBrowserSurface(
            inPane: paneId,
            url: openerURL,
            focus: true,
            localFileReadAccessPolicy: .containingDirectory
        ))

        browser.openLinkInNewTab(url: symlinkURL)

        let child = try #require(
            workspace.panels.values
                .compactMap { $0 as? BrowserPanel }
                .first(where: { $0.id != browser.id })
        )
        #expect(child.localFileReadAccessPolicy == .containingDirectory)
        #expect(child.currentURL?.standardizedFileURL == symlinkURL.standardizedFileURL)
    }

    @Test
    func restrictedHTMLPopupContextPreservesFileOnlyReadAccess() throws {
        _ = NSApplication.shared

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: sourcePanelId))
        let browser = try #require(workspace.newBrowserSurface(
            inPane: paneId,
            focus: true,
            localFileReadAccessPolicy: .fileOnly
        ))

        let popupPolicy = Mirror(reflecting: browser.popupBrowserContext).children
            .first(where: { $0.label == "localFileReadAccessPolicy" })
            .map { String(describing: $0.value) }
        #expect(popupPolicy == "fileOnly")
    }

    @Test
    func restrictedHTMLSavedLayoutsPreserveFileOnlyReadAccessAndReuse() async throws {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)
        defer {
            restore(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey, in: defaults)
        }

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let htmlURL = fixtureDirectory.appendingPathComponent("saved-layout.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>saved restricted browser</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let source = Workspace()
        defer { source.teardownAllPanels() }
        let sourcePanelId = try #require(source.focusedPanelId)
        let sourcePaneId = try #require(source.paneId(forPanelId: sourcePanelId))
        _ = try #require(source.newBrowserSurface(
            inPane: sourcePaneId,
            url: htmlURL,
            focus: true,
            localFileReadAccessPolicy: .fileOnly
        ))

        let capturedLayouts = [
            try #require(source.captureLayoutDefinition().workspace.layout),
            try #require(source.captureConfigActionSnapshot().definition.layout),
        ]
        for layout in capturedLayouts {
            let restored = Workspace()
            restored.applyCustomLayout(layout, baseCwd: fixtureDirectory.path)
            defer { restored.teardownAllPanels() }

            let browser = try #require(
                restored.panels.values.compactMap { $0 as? BrowserPanel }.first
            )
            #expect(browser.localFileReadAccessPolicy == .fileOnly)
            #expect(browser.bypassesRemoteWorkspaceProxyForTabDuplication)
            #expect(
                browser.webView.configuration.websiteDataStore ===
                    BrowserProfileStore.shared.websiteDataStore(for: browser.profileID)
            )
            #expect(await waitForDocumentTitle("saved restricted browser", in: browser))

            let terminalPanelId = try #require(
                restored.panels.values.compactMap { $0 as? TerminalPanel }.first?.id
            )
            #expect(openResolvedHTMLInCmux(
                workspace: restored,
                sourcePanelId: terminalPanelId,
                filePath: htmlURL.path
            ))
            #expect(restored.panels.values.compactMap { $0 as? BrowserPanel }.count == 1)
            #expect(restored.focusedPanelId == browser.id)
        }
    }

    #if DEBUG
    @Test
    func reopeningClosedRestrictedHTMLPreservesFileOnlyReadAccess() throws {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let supportedFilesKey = AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        let previousSupportedFiles = defaults.object(forKey: supportedFilesKey)
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        let manager = TabManager()
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        ClosedItemHistoryStore.shared.removeAll()
        defer {
            ClosedItemHistoryStore.shared.removeAll()
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousShared
            restore(previousSupportedFiles, forKey: supportedFilesKey, in: defaults)
            restore(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey, in: defaults)
        }
        defaults.set(true, forKey: supportedFilesKey)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let htmlURL = fixtureDirectory.appendingPathComponent("diagram.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>restored diagram</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let workspace = try #require(manager.selectedWorkspace)
        let sourcePanelId = try #require(workspace.focusedPanelId)
        #expect(openResolvedHTMLInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: htmlURL.path
        ))
        let browser = try #require(
            workspace.panels.values.compactMap { $0 as? BrowserPanel }.first
        )
        workspace.markCloseHistoryEligible(panelId: browser.id)
        #expect(workspace.closePanel(browser.id, force: true))
        #expect(workspace.panels.values.compactMap { $0 as? BrowserPanel }.isEmpty)

        #expect(manager.reopenMostRecentlyClosedBrowserPanel())

        let restoredBrowser = try #require(
            workspace.panels.values.compactMap { $0 as? BrowserPanel }.first
        )
        #expect(restoredBrowser.currentURL?.standardizedFileURL == htmlURL.standardizedFileURL)
        #expect(restoredBrowser.localFileReadAccessPolicy == .fileOnly)
        #expect(restoredBrowser.bypassesRemoteWorkspaceProxyForTabDuplication)
    }
    #endif

    @Test
    func provisionalNavigationPreventsStaleHTMLBrowserReuse() throws {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let supportedFilesKey = AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        let previousSupportedFiles = defaults.object(forKey: supportedFilesKey)
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defer {
            restore(previousSupportedFiles, forKey: supportedFilesKey, in: defaults)
            restore(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey, in: defaults)
        }
        defaults.set(true, forKey: supportedFilesKey)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let htmlURL = fixtureDirectory.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>provisional navigation</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let sourcePanelId = try #require(workspace.focusedPanelId)

        #expect(openResolvedHTMLInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: htmlURL.path
        ))
        let firstBrowser = try #require(workspace.panels.values.compactMap { $0 as? BrowserPanel }.first)
        firstBrowser.isMainFrameProvisionalNavigationActive = true
        firstBrowser.navigationDelegate?.recordAttemptedRequest(URLRequest(
            url: fixtureDirectory.appendingPathComponent("different.html")
        ))

        #expect(openResolvedHTMLInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: htmlURL.path
        ))

        #expect(workspace.panels.values.compactMap { $0 as? BrowserPanel }.count == 2)
    }

    @Test
    func htmlSymlinkOpensResolvedTargetInBrowser() async throws {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let supportedFilesKey = AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        let previousSupportedFiles = defaults.object(forKey: supportedFilesKey)
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defer {
            restore(previousSupportedFiles, forKey: supportedFilesKey, in: defaults)
            restore(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey, in: defaults)
        }
        defaults.set(true, forKey: supportedFilesKey)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let linkDirectory = fixtureDirectory.appendingPathComponent("link", isDirectory: true)
        let targetDirectory = fixtureDirectory.appendingPathComponent("target", isDirectory: true)
        let targetURL = targetDirectory.appendingPathComponent("page.html")
        let symlinkURL = linkDirectory.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>symlink target</title>".write(
            to: targetURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let sourcePanelId = try #require(workspace.focusedPanelId)
        var externallyOpened: [URL] = []
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { workspaceId, panelId in
                workspaceId == workspace.id && panelId == sourcePanelId ? workspace : nil
            },
            externalOpen: { url in
                externallyOpened.append(url)
                return true
            },
            deferOperation: { operation in operation() }
        )

        #expect(coordinator.open(TerminalLinkOpenRequest(
            rawValue: symlinkURL.path,
            sourceWorkspaceId: workspace.id,
            sourcePanelId: sourcePanelId,
            workingDirectory: nil
        )))

        #expect(await waitForBrowserCount(1, in: workspace))
        let browser = try #require(workspace.panels.values.compactMap { $0 as? BrowserPanel }.first)
        let browserURL = try #require(browser.currentURL)
        #expect(
            try filesystemIdentity(atPath: browserURL.path)
                == filesystemIdentity(atPath: targetURL.path)
        )
        #expect(externallyOpened.isEmpty)
    }

    private func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func filesystemIdentity(atPath path: String) throws -> [UInt64] {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let device = try #require((attributes[.systemNumber] as? NSNumber)?.uint64Value)
        let inode = try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        return [device, inode]
    }

    private func openResolvedHTMLInCmux(
        workspace: Workspace,
        sourcePanelId: UUID,
        filePath: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let fileURL = URL(fileURLWithPath: filePath)
        return CommandClickFileOpenRouter.openInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: filePath,
            resolvedFileURL: fileURL.standardizedFileURL.resolvingSymlinksInPath(),
            defaults: defaults
        )
    }

    private func waitForDocumentTitle(_ expectedTitle: String, in browser: BrowserPanel) async -> Bool {
        await waitForDocumentTitle(expectedTitle, in: browser.webView)
    }

    private func waitForDocumentTitle(_ expectedTitle: String, in webView: WKWebView) async -> Bool {
        for _ in 0..<100 {
            if let result = try? await webView.evaluateJavaScript("document.title"),
               result as? String == expectedTitle {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func waitForNavigationRecovery(in browser: BrowserPanel) async -> Bool {
        for _ in 0..<100 {
            if browser.hasRecoverableNavigationFailure {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func waitForHistoryAvailability(
        in browser: BrowserPanel,
        back: Bool,
        forward: Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if browser.canGoBack == back, browser.canGoForward == forward {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func waitForBrowserCount(_ expectedCount: Int, in workspace: Workspace) async -> Bool {
        for _ in 0..<100 {
            if workspace.panels.values.compactMap({ $0 as? BrowserPanel }).count == expectedCount {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private actor RecordingWordPathProbeCommandRunner: CommandRunning {
    struct Invocation: Sendable {
        let directory: String
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval?
    }

    private let forcedResult: CommandResult?
    private let resolvedPaths: [String: String]
    private let readableRegularPaths: Set<String>
    private var invocations: [Invocation] = []

    init(result: CommandResult) {
        forcedResult = result
        resolvedPaths = [:]
        readableRegularPaths = []
    }

    init(
        resolvedPaths: [String: String],
        readableRegularPaths: Set<String>
    ) {
        forcedResult = nil
        self.resolvedPaths = resolvedPaths
        self.readableRegularPaths = readableRegularPaths
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        invocations.append(Invocation(
            directory: directory,
            executable: executable,
            arguments: arguments,
            timeout: timeout
        ))
        if let forcedResult {
            return forcedResult
        }

        if executable == "/bin/realpath",
           let candidate = arguments.first,
           let resolvedPath = resolvedPaths[candidate] {
            return result(stdout: "\(resolvedPath)\n", exitStatus: 0)
        }
        if executable == "/bin/test",
           arguments.count == 2,
           readableRegularPaths.contains(arguments[1]),
           arguments[0] == "-f" || arguments[0] == "-r" {
            return result(stdout: "", exitStatus: 0)
        }
        return result(stdout: "", exitStatus: 1)
    }

    func allInvocations() -> [Invocation] {
        invocations
    }

    private func result(stdout: String, exitStatus: Int32) -> CommandResult {
        CommandResult(
            stdout: stdout,
            stderr: "",
            exitStatus: exitStatus,
            timedOut: false,
            executionError: nil
        )
    }
}
