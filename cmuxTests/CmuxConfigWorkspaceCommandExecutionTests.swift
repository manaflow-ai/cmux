import Combine
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - JSON Decoding


@MainActor
final class CmuxConfigWorkspaceCommandExecutionTests: XCTestCase {

    func testWorkspaceCommandCreatesNewWorkspaceByDefaultWhenNameAlreadyExists() {
        let manager = TabManager()
        let existingWorkspace = manager.tabs[0]
        existingWorkspace.setCustomTitle("Dev")

        let command = CmuxCommandDefinition(
            name: "Dev command",
            workspace: CmuxWorkspaceDefinition(name: "Dev")
        )

        XCTAssertTrue(CmuxConfigExecutor.execute(
            command: command,
            tabManager: manager,
            baseCwd: NSTemporaryDirectory(),
            configSourcePath: nil,
            globalConfigPath: "/tmp/cmux-test-global-config.json"
        ))

        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertTrue(manager.tabs.contains(where: { $0.id == existingWorkspace.id }))
        XCTAssertEqual(manager.tabs.filter { $0.customTitle == "Dev" }.count, 2)
        XCTAssertEqual(manager.selectedWorkspace?.customTitle, "Dev")
    }

    func testWorkspaceCommandHonorsExplicitNewRestartPolicy() {
        let manager = TabManager()
        let existingWorkspace = manager.tabs[0]
        existingWorkspace.setCustomTitle("Dev")

        let command = CmuxCommandDefinition(
            name: "Dev command",
            restart: .new,
            workspace: CmuxWorkspaceDefinition(name: "Dev")
        )

        XCTAssertTrue(CmuxConfigExecutor.execute(
            command: command,
            tabManager: manager,
            baseCwd: NSTemporaryDirectory(),
            configSourcePath: nil,
            globalConfigPath: "/tmp/cmux-test-global-config.json"
        ))

        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertTrue(manager.tabs.contains(where: { $0.id == existingWorkspace.id }))
        XCTAssertEqual(manager.tabs.filter { $0.customTitle == "Dev" }.count, 2)
        XCTAssertEqual(manager.selectedWorkspace?.customTitle, "Dev")
    }

    func testWorkspaceCommandHonorsIgnoreRestartPolicy() {
        let manager = TabManager()
        let existingWorkspace = manager.tabs[0]
        existingWorkspace.setCustomTitle("Dev")

        let command = CmuxCommandDefinition(
            name: "Dev command",
            restart: .ignore,
            workspace: CmuxWorkspaceDefinition(name: "Dev")
        )

        XCTAssertTrue(CmuxConfigExecutor.execute(
            command: command,
            tabManager: manager,
            baseCwd: NSTemporaryDirectory(),
            configSourcePath: nil,
            globalConfigPath: "/tmp/cmux-test-global-config.json"
        ))

        XCTAssertEqual(manager.tabs.map(\.id), [existingWorkspace.id])
        XCTAssertEqual(manager.selectedWorkspace?.id, existingWorkspace.id)
    }

    func testWorkspaceCommandHonorsRecreateRestartPolicy() {
        let manager = TabManager()
        let existingWorkspace = manager.tabs[0]
        existingWorkspace.setCustomTitle("Dev")

        let command = CmuxCommandDefinition(
            name: "Dev command",
            restart: .recreate,
            workspace: CmuxWorkspaceDefinition(name: "Dev")
        )

        XCTAssertTrue(CmuxConfigExecutor.execute(
            command: command,
            tabManager: manager,
            baseCwd: NSTemporaryDirectory(),
            configSourcePath: nil,
            globalConfigPath: "/tmp/cmux-test-global-config.json"
        ))

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == existingWorkspace.id }))
        XCTAssertEqual(manager.selectedWorkspace?.customTitle, "Dev")
    }
}

// MARK: - Split clamping

