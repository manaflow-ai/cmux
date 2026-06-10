import XCTest
import Testing
import CmuxControlSocket
import CmuxTerminalCopyMode
import CmuxSocketControl
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import CMUXMobileCore
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class TerminalDirectoryOpenTargetAvailabilityTests: XCTestCase {
    private func environment(
        existingPaths: Set<String>,
        homeDirectoryPath: String = "/Users/tester",
        applicationPathsByName: [String: String] = [:]
    ) -> TerminalDirectoryOpenTarget.DetectionEnvironment {
        TerminalDirectoryOpenTarget.DetectionEnvironment(
            homeDirectoryPath: homeDirectoryPath,
            fileExistsAtPath: { existingPaths.contains($0) },
            isExecutableFileAtPath: { existingPaths.contains($0) },
            applicationPathForName: { applicationPathsByName[$0] }
        )
    }

    func testAvailableTargetsDetectSystemApplications() {
        let env = environment(
            existingPaths: [
                "/Applications/Visual Studio Code.app",
                "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code-tunnel",
                "/System/Library/CoreServices/Finder.app",
                "/System/Applications/Utilities/Terminal.app",
                "/Applications/Zed Preview.app",
            ]
        )

        let availableTargets = TerminalDirectoryOpenTarget.availableTargets(in: env)
        XCTAssertTrue(availableTargets.contains(.vscode))
        XCTAssertTrue(availableTargets.contains(.finder))
        XCTAssertTrue(availableTargets.contains(.terminal))
        XCTAssertTrue(availableTargets.contains(.zed))
        XCTAssertFalse(availableTargets.contains(.cursor))
    }

    func testAvailableTargetsFallbackToUserApplications() {
        let env = environment(
            existingPaths: [
                "/Users/tester/Applications/Cursor.app",
                "/Users/tester/Applications/Warp.app",
                "/Users/tester/Applications/Android Studio.app",
            ]
        )

        let availableTargets = TerminalDirectoryOpenTarget.availableTargets(in: env)
        XCTAssertTrue(availableTargets.contains(.cursor))
        XCTAssertTrue(availableTargets.contains(.warp))
        XCTAssertTrue(availableTargets.contains(.androidStudio))
        XCTAssertFalse(availableTargets.contains(.vscode))
    }

    func testVSCodeInlineRequiresCodeTunnelExecutable() {
        let env = environment(existingPaths: ["/Applications/Visual Studio Code.app"])
        XCTAssertTrue(TerminalDirectoryOpenTarget.vscode.isAvailable(in: env))
        XCTAssertFalse(TerminalDirectoryOpenTarget.vscodeInline.isAvailable(in: env))
    }

    func testITerm2DetectsLegacyBundleName() {
        let env = environment(existingPaths: ["/Applications/iTerm.app"])
        XCTAssertTrue(TerminalDirectoryOpenTarget.iterm2.isAvailable(in: env))
    }

    func testTowerDetected() {
        let env = environment(existingPaths: ["/Applications/Tower.app"])
        XCTAssertTrue(TerminalDirectoryOpenTarget.tower.isAvailable(in: env))
    }

    func testAvailableTargetsFallbackToApplicationLookupForVSCodeAliasOutsideApplications() {
        let vscodePath = "/Volumes/Tools/Code.app"
        let env = environment(
            existingPaths: [
                vscodePath,
                "\(vscodePath)/Contents/Resources/app/bin/code-tunnel",
            ],
            applicationPathsByName: [
                "Code": vscodePath,
            ]
        )

        let availableTargets = TerminalDirectoryOpenTarget.availableTargets(in: env)
        XCTAssertTrue(availableTargets.contains(.vscode))
        XCTAssertTrue(availableTargets.contains(.vscodeInline))
    }

    func testTowerDetectedViaApplicationLookupOutsideApplications() {
        let towerPath = "/Volumes/Setapp/Tower.app"
        let env = environment(
            existingPaths: [towerPath],
            applicationPathsByName: [
                "Tower": towerPath,
            ]
        )

        XCTAssertTrue(TerminalDirectoryOpenTarget.tower.isAvailable(in: env))
    }

    func testCommandPaletteShortcutsExcludeGenericIDEEntry() {
        let targets = TerminalDirectoryOpenTarget.commandPaletteShortcutTargets
        XCTAssertFalse(targets.contains(where: { $0.commandPaletteTitle == "Open Current Directory in IDE" }))
        XCTAssertFalse(targets.contains(where: { $0.commandPaletteCommandId == "palette.terminalOpenDirectory" }))
    }
}


