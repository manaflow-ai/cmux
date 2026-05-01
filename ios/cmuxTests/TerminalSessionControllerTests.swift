import XCTest
@testable import cmux_DEV

@MainActor
final class TerminalSessionControllerTests: XCTestCase {
    func testResumeRetriesSurfaceCreationAfterInitialFailure() async {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .rawSSH
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini"
        )
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: [host.id: "secret"])
        let transport = ConnectedStubTerminalTransport()
        let transportFactory = StubTerminalTransportFactory(transport: transport)
        let surfaceFactory = FailThenSucceedSurfaceFactory()

        let controller = TerminalSessionController(
            workspace: workspace,
            host: host,
            credentialsStore: credentialsStore,
            transportFactory: transportFactory,
            surfaceFactory: surfaceFactory.makeSurface(delegate:)
        )

        let failedExpectation = expectation(description: "surface creation failed")
        controller.onUpdate = { update in
            guard case .phase(.failed, let error) = update,
                  error == StubSurfaceFactoryError.transient.localizedDescription else {
                return
            }
            failedExpectation.fulfill()
        }

        controller.connectIfNeeded()
        await fulfillment(of: [failedExpectation], timeout: 1.0)

        XCTAssertEqual(controller.phase, .failed)
        XCTAssertEqual(controller.errorMessage, StubSurfaceFactoryError.transient.localizedDescription)
        XCTAssertEqual(surfaceFactory.attemptCount, 1)

        let connectedExpectation = expectation(description: "controller connected")
        controller.onUpdate = { update in
            guard case .phase(.connected, nil) = update else { return }
            connectedExpectation.fulfill()
        }

        controller.resumeIfNeeded()
        await fulfillment(of: [connectedExpectation], timeout: 1.0)

        XCTAssertEqual(surfaceFactory.attemptCount, 2)
        XCTAssertEqual(transport.connectCallCount, 1)
        XCTAssertEqual(
            transport.connectedGridSizes,
            [TerminalGridSize(columns: 88, rows: 28, pixelWidth: 880, pixelHeight: 560)]
        )
        XCTAssertEqual(controller.phase, .connected)
        XCTAssertNil(controller.errorMessage)
    }

    func testSurfaceCloseRequestRebuildsSurfaceAndReconnects() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .rawSSH
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini"
        )
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: [host.id: "secret"])
        let firstTransport = ConnectedStubTerminalTransport()
        let secondTransport = ConnectedStubTerminalTransport()
        let transportFactory = TrackingSequencedTerminalTransportFactory(
            transports: [firstTransport, secondTransport]
        )
        let firstSurface = StubTerminalSurface(
            gridSize: TerminalGridSize(columns: 88, rows: 28, pixelWidth: 880, pixelHeight: 560)
        )
        let secondSurface = StubTerminalSurface(
            gridSize: TerminalGridSize(columns: 96, rows: 30, pixelWidth: 960, pixelHeight: 600)
        )
        let surfaceFactory = SequencedStubTerminalSurfaceFactory(
            surfaces: [firstSurface, secondSurface]
        )

        let initialConnectedExpectation = expectation(description: "controller connected initially")
        let recoveredConnectedExpectation = expectation(description: "controller reconnected after surface close")
        var connectedEventCount = 0

        let controller = TerminalSessionController(
            workspace: workspace,
            host: host,
            credentialsStore: credentialsStore,
            transportFactory: transportFactory,
            surfaceFactory: surfaceFactory.makeSurface(delegate:)
        )
        controller.onUpdate = { update in
            guard case .phase(.connected, nil) = update else { return }
            connectedEventCount += 1
            switch connectedEventCount {
            case 1:
                initialConnectedExpectation.fulfill()
            case 2:
                recoveredConnectedExpectation.fulfill()
            default:
                break
            }
        }

        controller.connectIfNeeded()
        await fulfillment(of: [initialConnectedExpectation], timeout: 1.0)

        NotificationCenter.default.post(
            name: .ghosttySurfaceDidRequestClose,
            object: firstSurface,
            userInfo: ["process_alive": false]
        )

        await fulfillment(of: [recoveredConnectedExpectation], timeout: 1.0)

        XCTAssertEqual(firstTransport.connectCallCount, 1)
        XCTAssertEqual(firstTransport.disconnectCallCount, 1)
        XCTAssertEqual(secondTransport.connectCallCount, 1)
        XCTAssertEqual(secondTransport.connectedGridSizes, [secondSurface.currentGridSize])
        XCTAssertEqual(surfaceFactory.attemptCount, 2)
        XCTAssertEqual(controller.phase, .connected)
        XCTAssertNil(controller.errorMessage)
    }

    func testSurfaceCloseRequestReportsFailureWhenReplacementSurfaceCreationFails() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .rawSSH
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini"
        )
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: [host.id: "secret"])
        let initialConnectedExpectation = expectation(description: "controller connected initially")
        let rebuildFailureExpectation = expectation(description: "controller reported failed rebuild")
        let transport = ConnectedStubTerminalTransport(
            onConnect: {
                initialConnectedExpectation.fulfill()
            }
        )
        let firstSurface = StubTerminalSurface(
            gridSize: TerminalGridSize(columns: 88, rows: 28, pixelWidth: 880, pixelHeight: 560)
        )
        let surfaceFactory = FailOnSecondSurfaceFactory(firstSurface: firstSurface)

        let controller = TerminalSessionController(
            workspace: workspace,
            host: host,
            credentialsStore: credentialsStore,
            transportFactory: StubTerminalTransportFactory(transport: transport),
            surfaceFactory: surfaceFactory.makeSurface(delegate:)
        )
        controller.onUpdate = { update in
            guard case .phase(.failed, let error) = update,
                  error == StubSurfaceFactoryError.transient.localizedDescription else {
                return
            }
            rebuildFailureExpectation.fulfill()
        }

        controller.connectIfNeeded()
        await fulfillment(of: [initialConnectedExpectation], timeout: 1.0)

        NotificationCenter.default.post(
            name: .ghosttySurfaceDidRequestClose,
            object: firstSurface,
            userInfo: ["process_alive": false]
        )

        await fulfillment(of: [rebuildFailureExpectation], timeout: 1.0)

        XCTAssertEqual(surfaceFactory.attemptCount, 2)
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertEqual(controller.errorMessage, StubSurfaceFactoryError.transient.localizedDescription)
    }

    func testSurfaceBellRequestEmitsBellUpdate() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .rawSSH
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini"
        )
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: [host.id: "secret"])
        let surface = StubTerminalSurface()
        let transport = ConnectedStubTerminalTransport()

        let bellExpectation = expectation(description: "controller emitted bell update")

        let controller = TerminalSessionController(
            workspace: workspace,
            host: host,
            credentialsStore: credentialsStore,
            transportFactory: StubTerminalTransportFactory(transport: transport),
            surfaceFactory: { _ in surface }
        )
        controller.onUpdate = { update in
            guard case .bell = update else { return }
            bellExpectation.fulfill()
        }

        controller.connectIfNeeded()

        NotificationCenter.default.post(
            name: .ghosttySurfaceDidRingBell,
            object: surface
        )

        await fulfillment(of: [bellExpectation], timeout: 1.0)
    }

    func testViewSizeIsAppliedBeforeInitialReplayOutput() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "sess-shared"
        )
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: [host.id: "secret"])
        let surface = StubTerminalSurface()
        let outputExpectation = expectation(description: "initial replay output processed")
        surface.onOutput = {
            outputExpectation.fulfill()
        }
        let transport = OrderedEventsStubTerminalTransport(events: [
            .viewSize(cols: 99, rows: 34),
            .output(Data("lawrence in / λ ".utf8)),
        ])

        let controller = TerminalSessionController(
            workspace: workspace,
            host: host,
            credentialsStore: credentialsStore,
            transportFactory: StubTerminalTransportFactory(transport: transport),
            surfaceFactory: { _ in surface }
        )

        controller.connectIfNeeded()
        await fulfillment(of: [outputExpectation], timeout: 1.0)

        XCTAssertEqual(surface.eventLog, [
            "viewSize:99x34",
            "output:lawrence in / λ ",
        ])
    }

    func testSuspendPreservingStateDisconnectsTransportAndReconnectsWithFreshSurfaceReplay() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon,
            teamID: "team-1",
            serverID: "cmux-macmini"
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini"
        )
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: [host.id: "secret"])
        let firstTransport = ParkingResumeSnapshotStubTerminalTransport(
            resumeState: .init(sessionID: "sess-1", attachmentID: "att-1", readOffset: 42)
        )
        let secondTransport = ConnectedStubTerminalTransport()
        let transportFactory = TrackingSequencedTerminalTransportFactory(
            transports: [firstTransport, secondTransport]
        )
        let firstSurface = StubTerminalSurface(
            gridSize: TerminalGridSize(columns: 88, rows: 28, pixelWidth: 880, pixelHeight: 560)
        )
        let secondSurface = StubTerminalSurface(
            gridSize: TerminalGridSize(columns: 96, rows: 30, pixelWidth: 960, pixelHeight: 600)
        )
        let surfaceFactory = SequencedStubTerminalSurfaceFactory(
            surfaces: [firstSurface, secondSurface]
        )

        let initialConnectedExpectation = expectation(description: "controller connected initially")
        let resumedConnectedExpectation = expectation(description: "controller connected after suspend")
        let savedResumeStateExpectation = expectation(description: "resume state saved on suspend")
        let clearedResumeStateExpectation = expectation(description: "resume state cleared after surface teardown")
        var connectedEventCount = 0
        var savedResumeStates: [TerminalRemoteDaemonResumeState?] = []

        let controller = TerminalSessionController(
            workspace: workspace,
            host: host,
            credentialsStore: credentialsStore,
            transportFactory: transportFactory,
            surfaceFactory: surfaceFactory.makeSurface(delegate:)
        )
        controller.onUpdate = { update in
            switch update {
            case .phase(.connected, nil):
                connectedEventCount += 1
                switch connectedEventCount {
                case 1:
                    initialConnectedExpectation.fulfill()
                case 2:
                    resumedConnectedExpectation.fulfill()
                default:
                    break
                }
            case .remoteDaemonResumeState(let state):
                savedResumeStates.append(state)
                if state?.sessionID == "sess-1" {
                    savedResumeStateExpectation.fulfill()
                } else if state == nil, savedResumeStates.contains(where: { $0?.sessionID == "sess-1" }) {
                    clearedResumeStateExpectation.fulfill()
                }
            default:
                break
            }
        }

        controller.connectIfNeeded()
        await fulfillment(of: [initialConnectedExpectation], timeout: 1.0)

        controller.suspendPreservingState()
        await fulfillment(of: [savedResumeStateExpectation, clearedResumeStateExpectation], timeout: 1.0)
        await Task.yield()

        controller.resumeIfNeeded()
        await fulfillment(of: [resumedConnectedExpectation], timeout: 1.0)

        XCTAssertEqual(firstTransport.parkCallCount, 1)
        XCTAssertEqual(firstTransport.disconnectCallCount, 0)
        XCTAssertEqual(secondTransport.connectCallCount, 1)
        XCTAssertEqual(secondTransport.connectedGridSizes, [secondSurface.currentGridSize])
        XCTAssertEqual(surfaceFactory.attemptCount, 2)
        XCTAssertEqual(
            transportFactory.resumeStates.map { $0?.sessionID },
            [nil, nil]
        )
        XCTAssertTrue(savedResumeStates.contains(where: { $0?.attachmentID == "att-1" }))
        XCTAssertNil(savedResumeStates.last!)
        XCTAssertEqual(controller.phase, .connected)
        XCTAssertNil(controller.errorMessage)
    }

    func testDisconnectReleasesHostedSurfaceImmediately() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .rawSSH
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini"
        )
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: [host.id: "secret"])
        let connectedExpectation = expectation(description: "controller connected")
        let transport = ConnectedStubTerminalTransport(
            onConnect: {
                connectedExpectation.fulfill()
            }
        )
        let surfaceFactory = TrackingStubTerminalSurfaceFactory()

        let controller = TerminalSessionController(
            workspace: workspace,
            host: host,
            credentialsStore: credentialsStore,
            transportFactory: StubTerminalTransportFactory(transport: transport),
            surfaceFactory: surfaceFactory.makeSurface(delegate:)
        )

        controller.connectIfNeeded()
        await fulfillment(of: [connectedExpectation], timeout: 1.0)

        XCTAssertNotNil(surfaceFactory.lastSurface)

        controller.disconnect()

        XCTAssertNil(surfaceFactory.lastSurface)
    }

    func testResumeIfNeededWaitsForPendingDisconnectBeforeReconnecting() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon,
            teamID: "team-1",
            serverID: "cmux-macmini"
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini"
        )
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: [host.id: "secret"])
        let disconnectGate = AsyncGate()
        let disconnectStartedExpectation = expectation(description: "disconnect started")
        let initialTransport = BlockingDisconnectStubTerminalTransport(
            resumeState: .init(sessionID: "sess-1", attachmentID: "att-1", readOffset: 42),
            gate: disconnectGate,
            onDisconnectStarted: {
                disconnectStartedExpectation.fulfill()
            }
        )
        let resumedTransport = ConnectedStubTerminalTransport()
        let transportFactory = TrackingSequencedTerminalTransportFactory(
            transports: [initialTransport, resumedTransport]
        )
        let firstSurface = StubTerminalSurface(
            gridSize: TerminalGridSize(columns: 88, rows: 28, pixelWidth: 880, pixelHeight: 560)
        )
        let secondSurface = StubTerminalSurface(
            gridSize: TerminalGridSize(columns: 96, rows: 30, pixelWidth: 960, pixelHeight: 600)
        )
        let surfaceFactory = SequencedStubTerminalSurfaceFactory(
            surfaces: [firstSurface, secondSurface]
        )

        let initialConnectedExpectation = expectation(description: "controller connected initially")
        let resumedConnectedExpectation = expectation(description: "controller connected after disconnect completes")
        var connectedEventCount = 0

        let controller = TerminalSessionController(
            workspace: workspace,
            host: host,
            credentialsStore: credentialsStore,
            transportFactory: transportFactory,
            surfaceFactory: surfaceFactory.makeSurface(delegate:)
        )
        controller.onUpdate = { update in
            guard case .phase(.connected, nil) = update else { return }
            connectedEventCount += 1
            switch connectedEventCount {
            case 1:
                initialConnectedExpectation.fulfill()
            case 2:
                resumedConnectedExpectation.fulfill()
            default:
                break
            }
        }

        controller.connectIfNeeded()
        await fulfillment(of: [initialConnectedExpectation], timeout: 1.0)

        controller.suspendPreservingState()
        controller.resumeIfNeeded()

        await fulfillment(of: [disconnectStartedExpectation], timeout: 1.0)
        await Task.yield()

        XCTAssertEqual(initialTransport.disconnectCallCount, 1)
        XCTAssertEqual(resumedTransport.connectCallCount, 0)

        await disconnectGate.open()
        await fulfillment(of: [resumedConnectedExpectation], timeout: 1.0)

        XCTAssertEqual(resumedTransport.connectCallCount, 1)
        XCTAssertEqual(resumedTransport.connectedGridSizes, [secondSurface.currentGridSize])
        XCTAssertEqual(surfaceFactory.attemptCount, 2)
    }

    func testReconnectNowCancelsPendingConnectBeforeStartingReplacementTransport() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon,
            teamID: "team-1",
            serverID: "cmux-macmini"
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini"
        )
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: [host.id: "secret"])
        let connectGate = AsyncGate()
        let initialConnectStartedExpectation = expectation(description: "initial connect started")
        let initialDisconnectExpectation = expectation(description: "initial disconnect requested")
        let replacementConnectedExpectation = expectation(description: "replacement transport connected")
        let initialTransport = BlockingConnectStubTerminalTransport(
            gate: connectGate,
            onConnectStarted: {
                initialConnectStartedExpectation.fulfill()
            },
            onDisconnect: {
                initialDisconnectExpectation.fulfill()
            }
        )
        let replacementTransport = ConnectedStubTerminalTransport(
            onConnect: {
                replacementConnectedExpectation.fulfill()
            }
        )
        let transportFactory = TrackingSequencedTerminalTransportFactory(
            transports: [initialTransport, replacementTransport]
        )
        let firstSurface = StubTerminalSurface(
            gridSize: TerminalGridSize(columns: 88, rows: 28, pixelWidth: 880, pixelHeight: 560)
        )
        let secondSurface = StubTerminalSurface(
            gridSize: TerminalGridSize(columns: 96, rows: 30, pixelWidth: 960, pixelHeight: 600)
        )
        let surfaceFactory = SequencedStubTerminalSurfaceFactory(
            surfaces: [firstSurface, secondSurface]
        )

        let controller = TerminalSessionController(
            workspace: workspace,
            host: host,
            credentialsStore: credentialsStore,
            transportFactory: transportFactory,
            surfaceFactory: surfaceFactory.makeSurface(delegate:)
        )

        controller.connectIfNeeded()
        await fulfillment(of: [initialConnectStartedExpectation], timeout: 1.0)

        controller.reconnectNow()
        await fulfillment(of: [initialDisconnectExpectation, replacementConnectedExpectation], timeout: 1.0)

        XCTAssertEqual(initialTransport.disconnectCallCount, 1)
        XCTAssertEqual(replacementTransport.connectCallCount, 1)

        await connectGate.open()
        await Task.yield()

        XCTAssertEqual(replacementTransport.connectCallCount, 1)
        XCTAssertEqual(replacementTransport.connectedGridSizes, [firstSurface.currentGridSize])
        XCTAssertEqual(surfaceFactory.attemptCount, 1)
    }

    func testReconnectNowPreservesDaemonResumeStateForReplacementTransport() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon,
            teamID: "team-1",
            serverID: "cmux-macmini"
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini"
        )
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: [host.id: "secret"])
        let firstTransport = ParkingResumeSnapshotStubTerminalTransport(
            resumeState: .init(sessionID: "sess-1", attachmentID: "att-1", readOffset: 42)
        )
        let replacementTransport = ConnectedStubTerminalTransport()
        let transportFactory = TrackingSequencedTerminalTransportFactory(
            transports: [firstTransport, replacementTransport]
        )
        let surface = StubTerminalSurface(
            gridSize: TerminalGridSize(columns: 88, rows: 28, pixelWidth: 880, pixelHeight: 560)
        )
        let surfaceFactory = SequencedStubTerminalSurfaceFactory(surfaces: [surface])
        let initialConnectedExpectation = expectation(description: "controller connected initially")
        let replacementConnectedExpectation = expectation(description: "replacement transport connected")
        var connectedEventCount = 0

        let controller = TerminalSessionController(
            workspace: workspace,
            host: host,
            credentialsStore: credentialsStore,
            transportFactory: transportFactory,
            surfaceFactory: surfaceFactory.makeSurface(delegate:)
        )
        controller.onUpdate = { update in
            guard case .phase(.connected, nil) = update else { return }
            connectedEventCount += 1
            switch connectedEventCount {
            case 1:
                initialConnectedExpectation.fulfill()
            case 2:
                replacementConnectedExpectation.fulfill()
            default:
                break
            }
        }

        controller.connectIfNeeded()
        await fulfillment(of: [initialConnectedExpectation], timeout: 1.0)

        controller.reconnectNow()
        await fulfillment(of: [replacementConnectedExpectation], timeout: 1.0)

        XCTAssertEqual(firstTransport.parkCallCount, 1)
        XCTAssertEqual(firstTransport.disconnectCallCount, 0)
        XCTAssertEqual(replacementTransport.connectCallCount, 1)
        XCTAssertEqual(
            transportFactory.resumeStates,
            [
                nil,
                .init(sessionID: "sess-1", attachmentID: "att-1", readOffset: 0),
            ]
        )
    }

    func testConnectUsesFullReplayOffsetWhenCreatingFreshSurface() async throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon,
            teamID: "team-1",
            serverID: "cmux-macmini"
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini",
            remoteDaemonResumeState: .init(sessionID: "sess-1", attachmentID: "att-1", readOffset: 42)
        )
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: [host.id: "secret"])
        let transport = ConnectedStubTerminalTransport()
        let transportFactory = TrackingSequencedTerminalTransportFactory(transports: [transport])
        let connectedExpectation = expectation(description: "controller connected")

        let controller = TerminalSessionController(
            workspace: workspace,
            host: host,
            credentialsStore: credentialsStore,
            transportFactory: transportFactory,
            surfaceFactory: { _ in StubTerminalSurface() }
        )
        controller.onUpdate = { update in
            if case .phase(.connected, nil) = update {
                connectedExpectation.fulfill()
            }
        }

        controller.connectIfNeeded()
        await fulfillment(of: [connectedExpectation], timeout: 1.0)

        XCTAssertEqual(
            transportFactory.resumeStates,
            [.init(sessionID: "sess-1", attachmentID: "att-1", readOffset: 0)]
        )
    }

    func testConnectUsesFullReplayOffsetWhenSurfaceWasCreatedBeforeHostConfigured() async throws {
        let hostID = TerminalHost.ID()
        let initialHost = TerminalHost(
            id: hostID,
            name: "Mac Mini",
            hostname: "",
            username: "",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon
        )
        let configuredHost = TerminalHost(
            id: hostID,
            name: "Mac Mini",
            hostname: "127.0.0.1",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon,
            wsPort: 52185,
            wsSecret: "secret"
        )
        let workspace = TerminalWorkspace(
            hostID: hostID,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini",
            remoteDaemonResumeState: .init(sessionID: "sess-1", attachmentID: "att-1", readOffset: 42)
        )
        let credentialsStore = InMemoryTerminalCredentialsStore()
        let transport = ConnectedStubTerminalTransport()
        let transportFactory = TrackingSequencedTerminalTransportFactory(transports: [transport])
        let connectedExpectation = expectation(description: "controller connected")

        let controller = TerminalSessionController(
            workspace: workspace,
            host: initialHost,
            credentialsStore: credentialsStore,
            transportFactory: transportFactory,
            surfaceFactory: { _ in StubTerminalSurface() }
        )
        controller.onUpdate = { update in
            if case .phase(.connected, nil) = update {
                connectedExpectation.fulfill()
            }
        }

        controller.connectIfNeeded()
        XCTAssertEqual(transportFactory.resumeStates, [])

        controller.refreshHost(configuredHost)
        await fulfillment(of: [connectedExpectation], timeout: 1.0)

        XCTAssertEqual(
            transportFactory.resumeStates,
            [.init(sessionID: "sess-1", attachmentID: "att-1", readOffset: 0)]
        )
    }

    func testConnectFailureDoesNotAutoReconnectOnDirectTLSRejection() async throws {
        setenv("CMUX_UITEST_TERMINAL_RECONNECT_DELAY", "0.05", 1)
        defer { unsetenv("CMUX_UITEST_TERMINAL_RECONNECT_DELAY") }

        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini"
        )
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: [host.id: "secret"])
        let transport = ThrowingStubTerminalTransport(
            connectError: TerminalDirectDaemonClientError.tlsRejected("certificate pin mismatch")
        )
        let transportFactory = StubTerminalTransportFactory(transport: transport)

        let controller = TerminalSessionController(
            workspace: workspace,
            host: host,
            credentialsStore: credentialsStore,
            transportFactory: transportFactory,
            surfaceFactory: { _ in StubTerminalSurface() }
        )

        let failedExpectation = expectation(description: "controller failed without reconnect")
        failedExpectation.assertForOverFulfill = false
        controller.onUpdate = { update in
            guard case .phase(.failed, let error) = update,
                  error == "Direct daemon TLS verification failed: certificate pin mismatch" else {
                return
            }
            failedExpectation.fulfill()
        }

        controller.connectIfNeeded()
        await fulfillment(of: [failedExpectation], timeout: 1.0)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(transport.connectCallCount, 1)
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertEqual(
            controller.errorMessage,
            "Direct daemon TLS verification failed: certificate pin mismatch"
        )
    }

    func testSharedSessionUnavailableStaysConnectingAndRetries() async throws {
        setenv("CMUX_UITEST_TERMINAL_RECONNECT_DELAY", "0.05", 1)
        defer { unsetenv("CMUX_UITEST_TERMINAL_RECONNECT_DELAY") }

        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "sess-restored"
        )
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: [host.id: "secret"])
        let transport = ThrowingStubTerminalTransport(
            connectError: TerminalRemoteDaemonSessionTransportError.sharedSessionUnavailable("sess-restored")
        )
        let transportFactory = StubTerminalTransportFactory(transport: transport)

        let controller = TerminalSessionController(
            workspace: workspace,
            host: host,
            credentialsStore: credentialsStore,
            transportFactory: transportFactory,
            surfaceFactory: { _ in StubTerminalSurface() }
        )

        let connectingExpectation = expectation(description: "controller waits for daemon-owned session")
        connectingExpectation.assertForOverFulfill = false
        let retryExpectation = expectation(description: "controller retries daemon-owned session attach")
        retryExpectation.assertForOverFulfill = false
        controller.onUpdate = { update in
            guard case .phase(.connecting, let error) = update,
                  error == "Waiting for Mac to finish starting this workspace…" else {
                return
            }
            connectingExpectation.fulfill()
            if transport.connectCallCount > 1 {
                retryExpectation.fulfill()
            }
        }

        controller.connectIfNeeded()
        await fulfillment(of: [connectingExpectation, retryExpectation], timeout: 2.0)

        XCTAssertGreaterThan(transport.connectCallCount, 1)
        XCTAssertEqual(controller.phase, .connecting)
        XCTAssertEqual(controller.errorMessage, "Waiting for Mac to finish starting this workspace…")
    }

    func testConnectFailureDoesNotAutoReconnectOnDirectAuthRejection() async throws {
        setenv("CMUX_UITEST_TERMINAL_RECONNECT_DELAY", "0.05", 1)
        defer { unsetenv("CMUX_UITEST_TERMINAL_RECONNECT_DELAY") }

        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini"
        )
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: [host.id: "secret"])
        let transport = ThrowingStubTerminalTransport(
            connectError: TerminalDirectDaemonClientError.handshakeRejected(
                code: "unauthorized",
                message: "ticket rejected"
            )
        )
        let transportFactory = StubTerminalTransportFactory(transport: transport)

        let controller = TerminalSessionController(
            workspace: workspace,
            host: host,
            credentialsStore: credentialsStore,
            transportFactory: transportFactory,
            surfaceFactory: { _ in StubTerminalSurface() }
        )

        let failedExpectation = expectation(description: "controller failed without reconnect")
        failedExpectation.assertForOverFulfill = false
        controller.onUpdate = { update in
            guard case .phase(.failed, let error) = update,
                  error == "Direct daemon rejected this session." else {
                return
            }
            failedExpectation.fulfill()
        }

        controller.connectIfNeeded()
        await fulfillment(of: [failedExpectation], timeout: 1.0)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(transport.connectCallCount, 1)
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertEqual(controller.errorMessage, "Direct daemon rejected this session.")
    }

    func testConnectFailureDoesNotAutoReconnectOnSSHPublicKeyAuthUnavailable() async throws {
        setenv("CMUX_UITEST_TERMINAL_RECONNECT_DELAY", "0.05", 1)
        defer { unsetenv("CMUX_UITEST_TERMINAL_RECONNECT_DELAY") }

        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .rawSSH,
            sshAuthenticationMethod: .privateKey
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini"
        )
        let credentialsStore = InMemoryTerminalCredentialsStore(
            privateKeys: [host.id: TerminalSSHPrivateKeyFixtures.opensshEd25519PrivateKey]
        )
        let transport = ThrowingStubTerminalTransport(
            connectError: TerminalSSHError.publicKeyAuthenticationUnavailable
        )
        let transportFactory = StubTerminalTransportFactory(transport: transport)

        let controller = TerminalSessionController(
            workspace: workspace,
            host: host,
            credentialsStore: credentialsStore,
            transportFactory: transportFactory,
            surfaceFactory: { _ in StubTerminalSurface() }
        )

        let failedExpectation = expectation(description: "controller failed without reconnect")
        failedExpectation.assertForOverFulfill = false
        controller.onUpdate = { update in
            guard case .phase(.failed, let error) = update,
                  error == "Public key authentication is unavailable on this server." else {
                return
            }
            failedExpectation.fulfill()
        }

        controller.connectIfNeeded()
        await fulfillment(of: [failedExpectation], timeout: 1.0)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(transport.connectCallCount, 1)
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertEqual(
            controller.errorMessage,
            "Public key authentication is unavailable on this server."
        )
    }

    func testConnectFailurePublishesPendingHostKeyAndNeedsConfigurationOnUnknownSSHHostKey() async throws {
        setenv("CMUX_UITEST_TERMINAL_RECONNECT_DELAY", "0.05", 1)
        defer { unsetenv("CMUX_UITEST_TERMINAL_RECONNECT_DELAY") }

        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .rawSSH
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini"
        )
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: [host.id: "secret"])
        let transport = ThrowingStubTerminalTransport(
            connectError: TerminalSSHError.untrustedHostKey("ssh-ed25519 AAAAPENDING")
        )
        let transportFactory = StubTerminalTransportFactory(transport: transport)

        let controller = TerminalSessionController(
            workspace: workspace,
            host: host,
            credentialsStore: credentialsStore,
            transportFactory: transportFactory,
            surfaceFactory: { _ in StubTerminalSurface() }
        )

        let pendingHostKeyExpectation = expectation(description: "controller published pending host key")
        let needsConfigurationExpectation = expectation(description: "controller requires host key trust")
        controller.onUpdate = { update in
            switch update {
            case .pendingHostKey(let hostKey):
                XCTAssertEqual(hostKey, "ssh-ed25519 AAAAPENDING")
                pendingHostKeyExpectation.fulfill()
            case .phase(.needsConfiguration, let error):
                XCTAssertEqual(error, "Review and trust this server host key before connecting.")
                needsConfigurationExpectation.fulfill()
            default:
                break
            }
        }

        controller.connectIfNeeded()
        await fulfillment(of: [pendingHostKeyExpectation, needsConfigurationExpectation], timeout: 1.0)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(transport.connectCallCount, 1)
        XCTAssertEqual(controller.phase, .needsConfiguration)
        XCTAssertEqual(
            controller.errorMessage,
            "Review and trust this server host key before connecting."
        )
    }

    func testConnectFailurePublishesPendingHostKeyAndNeedsConfigurationOnChangedSSHHostKey() async throws {
        setenv("CMUX_UITEST_TERMINAL_RECONNECT_DELAY", "0.05", 1)
        defer { unsetenv("CMUX_UITEST_TERMINAL_RECONNECT_DELAY") }

        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            trustedHostKey: "ssh-ed25519 AAAAOLD",
            transportPreference: .rawSSH
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "Mac Mini",
            tmuxSessionName: "cmux-mac-mini"
        )
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: [host.id: "secret"])
        let transport = ThrowingStubTerminalTransport(
            connectError: TerminalSSHError.hostKeyChanged("ssh-ed25519 AAAANEW")
        )
        let transportFactory = StubTerminalTransportFactory(transport: transport)

        let controller = TerminalSessionController(
            workspace: workspace,
            host: host,
            credentialsStore: credentialsStore,
            transportFactory: transportFactory,
            surfaceFactory: { _ in StubTerminalSurface() }
        )

        let pendingHostKeyExpectation = expectation(description: "controller published replacement host key")
        let needsConfigurationExpectation = expectation(description: "controller requires host key review")
        controller.onUpdate = { update in
            switch update {
            case .pendingHostKey(let hostKey):
                XCTAssertEqual(hostKey, "ssh-ed25519 AAAANEW")
                pendingHostKeyExpectation.fulfill()
            case .phase(.needsConfiguration, let error):
                XCTAssertEqual(error, "The server host key changed. Review and trust the new key before connecting.")
                needsConfigurationExpectation.fulfill()
            default:
                break
            }
        }

        controller.connectIfNeeded()
        await fulfillment(of: [pendingHostKeyExpectation, needsConfigurationExpectation], timeout: 1.0)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(transport.connectCallCount, 1)
        XCTAssertEqual(controller.phase, .needsConfiguration)
        XCTAssertEqual(
            controller.errorMessage,
            "The server host key changed. Review and trust the new key before connecting."
        )
    }
}

final class StubTerminalTransportFactory: TerminalTransportFactory {
    private let transport: any TerminalTransport

    init(transport: any TerminalTransport) {
        self.transport = transport
    }

    func makeTransport(
        host: TerminalHost,
        credentials: TerminalSSHCredentials,
        sessionName: String,
        resumeState: TerminalRemoteDaemonResumeState?
    ) -> TerminalTransport {
        transport
    }
}

final class TrackingSequencedTerminalTransportFactory: TerminalTransportFactory {
    private var transports: [any TerminalTransport]
    private var index = 0
    private(set) var resumeStates: [TerminalRemoteDaemonResumeState?] = []

    init(transports: [any TerminalTransport]) {
        self.transports = transports
    }

    func makeTransport(
        host: TerminalHost,
        credentials: TerminalSSHCredentials,
        sessionName: String,
        resumeState: TerminalRemoteDaemonResumeState?
    ) -> TerminalTransport {
        resumeStates.append(resumeState)
        let selectedIndex = min(index, transports.count - 1)
        index += 1
        return transports[selectedIndex]
    }
}

final class ConnectedStubTerminalTransport: TerminalTransport {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?
    private let onConnect: @Sendable () -> Void
    private let onDisconnect: @Sendable () -> Void
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var connectedGridSizes: [TerminalGridSize] = []

    init(
        onConnect: @escaping @Sendable () -> Void = {},
        onDisconnect: @escaping @Sendable () -> Void = {}
    ) {
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect
    }

    func connect(initialSize: TerminalGridSize) async throws {
        connectCallCount += 1
        connectedGridSizes.append(initialSize)
        onConnect()
        eventHandler?(.connected)
    }

    func send(_ data: Data) async throws {}

    func resize(_ size: TerminalGridSize) async {}

    func disconnect() async {
        disconnectCallCount += 1
        onDisconnect()
    }
}

final class OrderedEventsStubTerminalTransport: TerminalTransport {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?
    private let events: [TerminalTransportEvent]

    init(events: [TerminalTransportEvent]) {
        self.events = events
    }

    func connect(initialSize: TerminalGridSize) async throws {
        eventHandler?(.connected)
        for event in events {
            eventHandler?(event)
        }
    }

    func send(_ data: Data) async throws {}

    func resize(_ size: TerminalGridSize) async {}

    func disconnect() async {}
}

final class ThrowingStubTerminalTransport: TerminalTransport {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?

    private let connectError: Error
    private(set) var connectCallCount = 0

    init(connectError: Error) {
        self.connectError = connectError
    }

    func connect(initialSize: TerminalGridSize) async throws {
        connectCallCount += 1
        throw connectError
    }

    func send(_ data: Data) async throws {}

    func resize(_ size: TerminalGridSize) async {}

    func disconnect() async {}
}

class ResumeSnapshotStubTerminalTransport: TerminalTransport, TerminalRemoteDaemonResumeStateSnapshotting {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?

    private let resumeState: TerminalRemoteDaemonResumeState
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0

    init(resumeState: TerminalRemoteDaemonResumeState) {
        self.resumeState = resumeState
    }

    func connect(initialSize: TerminalGridSize) async throws {
        connectCallCount += 1
        eventHandler?(.connected)
    }

    func send(_ data: Data) async throws {}

    func resize(_ size: TerminalGridSize) async {}

    func disconnect() async {
        disconnectCallCount += 1
    }

    func remoteDaemonResumeStateSnapshot() -> TerminalRemoteDaemonResumeState? {
        resumeState
    }
}

final class ParkingResumeSnapshotStubTerminalTransport:
    ResumeSnapshotStubTerminalTransport,
    TerminalSessionParking
{
    private(set) var parkCallCount = 0

    func suspendPreservingSession() async {
        parkCallCount += 1
    }
}

actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

final class BlockingDisconnectStubTerminalTransport: TerminalTransport, TerminalRemoteDaemonResumeStateSnapshotting {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?

    private let resumeState: TerminalRemoteDaemonResumeState
    private let gate: AsyncGate
    private let onDisconnectStarted: @Sendable () -> Void
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0

    init(
        resumeState: TerminalRemoteDaemonResumeState,
        gate: AsyncGate,
        onDisconnectStarted: @escaping @Sendable () -> Void = {}
    ) {
        self.resumeState = resumeState
        self.gate = gate
        self.onDisconnectStarted = onDisconnectStarted
    }

    func connect(initialSize: TerminalGridSize) async throws {
        connectCallCount += 1
        eventHandler?(.connected)
    }

    func send(_ data: Data) async throws {}

    func resize(_ size: TerminalGridSize) async {}

    func disconnect() async {
        disconnectCallCount += 1
        onDisconnectStarted()
        await gate.wait()
    }

    func remoteDaemonResumeStateSnapshot() -> TerminalRemoteDaemonResumeState? {
        resumeState
    }
}

final class BlockingConnectStubTerminalTransport: TerminalTransport {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?

    private let gate: AsyncGate
    private let onConnectStarted: @Sendable () -> Void
    private let onDisconnect: @Sendable () -> Void
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0

    init(
        gate: AsyncGate,
        onConnectStarted: @escaping @Sendable () -> Void = {},
        onDisconnect: @escaping @Sendable () -> Void = {}
    ) {
        self.gate = gate
        self.onConnectStarted = onConnectStarted
        self.onDisconnect = onDisconnect
    }

    func connect(initialSize: TerminalGridSize) async throws {
        connectCallCount += 1
        onConnectStarted()
        await gate.wait()
        eventHandler?(.connected)
    }

    func send(_ data: Data) async throws {}

    func resize(_ size: TerminalGridSize) async {}

    func disconnect() async {
        disconnectCallCount += 1
        onDisconnect()
    }
}

@MainActor
final class FailThenSucceedSurfaceFactory {
    private(set) var attemptCount = 0

    func makeSurface(delegate: GhosttySurfaceViewDelegate) throws -> any TerminalSurfaceHosting {
        attemptCount += 1
        if attemptCount == 1 {
            throw StubSurfaceFactoryError.transient
        }
        return StubTerminalSurface()
    }
}

final class StubTerminalSurface: TerminalSurfaceHosting {
    let currentGridSize: TerminalGridSize
    private(set) var eventLog: [String] = []
    var onOutput: (() -> Void)?

    init(gridSize: TerminalGridSize = TerminalGridSize(columns: 88, rows: 28, pixelWidth: 880, pixelHeight: 560)) {
        self.currentGridSize = gridSize
    }

    func processOutput(_ data: Data) {
        eventLog.append("output:\(String(decoding: data, as: UTF8.self))")
        onOutput?()
    }

    func applyViewSize(cols: Int, rows: Int) {
        eventLog.append("viewSize:\(cols)x\(rows)")
    }
}

@MainActor
final class TrackingStubTerminalSurfaceFactory {
    weak var lastSurface: StubTerminalSurface?

    func makeSurface(delegate: GhosttySurfaceViewDelegate) throws -> any TerminalSurfaceHosting {
        let surface = StubTerminalSurface()
        lastSurface = surface
        return surface
    }
}

@MainActor
final class SequencedStubTerminalSurfaceFactory {
    private let surfaces: [StubTerminalSurface]
    private(set) var attemptCount = 0

    init(surfaces: [StubTerminalSurface]) {
        self.surfaces = surfaces
    }

    func makeSurface(delegate: GhosttySurfaceViewDelegate) throws -> any TerminalSurfaceHosting {
        let selectedIndex = min(attemptCount, surfaces.count - 1)
        attemptCount += 1
        return surfaces[selectedIndex]
    }
}

@MainActor
final class FailOnSecondSurfaceFactory {
    private let firstSurface: StubTerminalSurface
    private(set) var attemptCount = 0

    init(firstSurface: StubTerminalSurface) {
        self.firstSurface = firstSurface
    }

    func makeSurface(delegate: GhosttySurfaceViewDelegate) throws -> any TerminalSurfaceHosting {
        attemptCount += 1
        if attemptCount == 1 {
            return firstSurface
        }
        throw StubSurfaceFactoryError.transient
    }
}

private enum StubSurfaceFactoryError: LocalizedError {
    case transient

    var errorDescription: String? {
        switch self {
        case .transient:
            return "Ghostty surface boot failed."
        }
    }
}
