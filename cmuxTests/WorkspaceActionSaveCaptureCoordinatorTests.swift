import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceActionSaveCaptureCoordinatorTests {
    @Test
    func heldCommandCaptureUsesOneClickTimeWorkspaceSnapshot() async throws {
        let workspace = Workspace(workingDirectory: "/tmp/click-time-layout")
        workspace.customTitle = "Click Time Layout"
        let initialPanelID = try #require(workspace.focusedPanelId)
        let ttyDevice = try #require(CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: "/dev/null"))
        workspace.surfaceTTYNames[initialPanelID] = "/dev/null"

        let clickCapture = workspace.captureConfigActionState()
        let commandGate = WorkspaceActionSaveLiveCommandsGate()
        let coordinator = WorkspaceActionSaveCaptureCoordinator()
        var deliveries: [(snapshot: WorkspaceConfigActionSnapshot, initialName: String)] = []

        let pending = coordinator.begin(
            capture: clickCapture,
            loadLiveCommands: { ttyDevices in
                await commandGate.load(for: ttyDevices)
            },
            onReady: { snapshot, initialName in
                deliveries.append((snapshot, initialName))
            }
        )
        await commandGate.waitForCallCount(1)

        workspace.customTitle = "Mutated Layout"
        workspace.currentDirectory = "/tmp/mutated-layout"
        workspace.surfaceTTYNames[initialPanelID] = "/dev/zero"
        _ = workspace.newTerminalSplit(from: initialPanelID, orientation: .horizontal, focus: false)

        await commandGate.releaseNext([ttyDevice: "claude --model claude-fable-5"])
        await pending.value

        let delivery = try #require(deliveries.first)
        #expect(deliveries.count == 1)
        #expect(delivery.initialName == "Click Time Layout")
        #expect(delivery.snapshot.definition.name == "Click Time Layout")
        #expect(delivery.snapshot.definition.cwd == "/tmp/click-time-layout")
        guard case .pane(let pane)? = delivery.snapshot.definition.layout else {
            Issue.record("Expected the click-time single-pane layout")
            return
        }
        #expect(pane.surfaces.count == 1)
        #expect(pane.surfaces[0].command == "claude --model claude-fable-5")
        #expect(await commandGate.requests() == [Set([ttyDevice])])
    }

    @Test
    func repeatedActivationRejectsHeldOlderResultAndDeliversLatestOnce() async throws {
        let workspace = Workspace(workingDirectory: "/tmp/repeated-save-layout")
        let panelID = try #require(workspace.focusedPanelId)
        let ttyDevice = try #require(CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: "/dev/null"))
        workspace.surfaceTTYNames[panelID] = "/dev/null"
        let coordinator = WorkspaceActionSaveCaptureCoordinator()
        let firstGate = WorkspaceActionSaveLiveCommandsGate()
        let secondGate = WorkspaceActionSaveLiveCommandsGate()
        var deliveredNames: [String] = []

        workspace.customTitle = "First Activation"
        let firstTask = coordinator.begin(
            capture: workspace.captureConfigActionState(),
            loadLiveCommands: { ttyDevices in
                await firstGate.load(for: ttyDevices)
            },
            onReady: { _, initialName in
                deliveredNames.append(initialName)
            }
        )
        await firstGate.waitForCallCount(1)

        workspace.customTitle = "Second Activation"
        let secondTask = coordinator.begin(
            capture: workspace.captureConfigActionState(),
            loadLiveCommands: { ttyDevices in
                await secondGate.load(for: ttyDevices)
            },
            onReady: { _, initialName in
                deliveredNames.append(initialName)
            }
        )
        await secondGate.waitForCallCount(1)
        #expect(firstTask.isCancelled)

        await firstGate.releaseNext([ttyDevice: "claude --model stale"])
        await firstTask.value
        #expect(deliveredNames.isEmpty)

        await secondGate.releaseNext([ttyDevice: "codex --model current"])
        await secondTask.value
        #expect(deliveredNames == ["Second Activation"])
    }
}

private actor WorkspaceActionSaveLiveCommandsGate {
    private var capturedRequests: [Set<Int64>] = []
    private var releases: [CheckedContinuation<[Int64: String], Never>] = []
    private var callCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func load(for ttyDevices: Set<Int64>) async -> [Int64: String] {
        capturedRequests.append(ttyDevices)
        resumeSatisfiedCallCountWaiters()
        return await withCheckedContinuation { continuation in
            releases.append(continuation)
        }
    }

    func waitForCallCount(_ count: Int) async {
        guard capturedRequests.count < count else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((count, continuation))
        }
    }

    func releaseNext(_ result: [Int64: String]) {
        guard !releases.isEmpty else { return }
        releases.removeFirst().resume(returning: result)
    }

    func requests() -> [Set<Int64>] {
        capturedRequests
    }

    private func resumeSatisfiedCallCountWaiters() {
        let satisfied = callCountWaiters.filter { capturedRequests.count >= $0.count }
        callCountWaiters.removeAll { capturedRequests.count >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}
