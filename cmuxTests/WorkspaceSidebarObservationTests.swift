import Foundation
import XCTest

import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceSidebarObservationTests: XCTestCase {
    func testSidebarObservationPublisherEmitsForLateStatusSubscriber() {
        let workspace = Workspace()
        workspace.statusEntries["test_probe"] = SidebarStatusEntry(
            key: "test_probe",
            value: "VISIBLE?",
            icon: "star.fill",
            color: "#FF0000",
            priority: 200
        )

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        XCTAssertGreaterThan(
            publishCount,
            0,
            "A sidebar row that subscribes after status metadata already exists must still refresh from the current workspace state."
        )
    }

    func testSidebarImmediateObservationPublisherEmitsForLateTitleSubscriber() {
        let workspace = Workspace()
        workspace.title = "Restored Workspace"

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        XCTAssertGreaterThan(
            publishCount,
            0,
            "A sidebar row that subscribes after immediate workspace fields already exist must still refresh from the current workspace state."
        )
    }

    func testSidebarObservationPublisherIgnoresRemoteHeartbeatOnlyChanges() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.remoteHeartbeatCount = 1
        workspace.remoteLastHeartbeatAt = Date()

        XCTAssertEqual(
            publishCount,
            0,
            "Expected non-visible remote heartbeat updates to avoid invalidating sidebar rows"
        )
    }

    func testSidebarSummaryObservationPublisherIgnoresStructuredDetailChanges() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarSummaryObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.currentDirectory = "/tmp/cmux-summary-ignored"
        workspace.panelDirectories[UUID()] = "/tmp/cmux-panel"
        workspace.gitBranch = SidebarGitBranchState(branch: "feature/sidebar", isDirty: false)

        XCTAssertEqual(
            publishCount,
            0,
            "Expected structured detail changes to avoid invalidating the summary sidebar snapshot"
        )
    }

    func testSidebarStructuredDetailObservationPublisherIgnoresSummaryChanges() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarStructuredDetailObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.statusEntries["test_probe"] = SidebarStatusEntry(
            key: "test_probe",
            value: "VISIBLE?",
            icon: "star.fill",
            color: "#FF0000",
            priority: 200
        )
        workspace.logEntries = [
            SidebarLogEntry(message: "summary-only", level: .info, source: nil, timestamp: Date())
        ]
        workspace.listeningPorts = [4321]

        XCTAssertEqual(
            publishCount,
            0,
            "Expected summary-only changes to avoid invalidating structured sidebar details"
        )
    }

    func testSidebarStructuredDetailObservationPublisherEmitsForPanelDirectoryChanges() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarStructuredDetailObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.panelDirectories[UUID()] = "/tmp/cmux-panel"

        XCTAssertGreaterThan(
            publishCount,
            0,
            "Expected panel directory changes to invalidate structured sidebar details"
        )
    }
}
