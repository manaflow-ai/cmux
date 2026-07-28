import AppKit
import CmuxCommandPalette
import CmuxControlSocket
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CommandPaletteCLIPathActionTests {
    @Test func automationInstallReturnsCompletedAndCreatesTheSymlink() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let result = AppDelegate().installCmuxCLIInPath(
            resultPresentation: .silent,
            installer: fixture.installer
        )

        #expect(result == .completed)
        #expect(
            try fixture.fileManager.destinationOfSymbolicLink(atPath: fixture.destinationURL.path)
                == fixture.sourceURL.path
        )
    }

    @Test func automationUninstallReturnsCompletedAndRemovesTheSymlink() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try fixture.fileManager.createDirectory(
            at: fixture.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fixture.fileManager.createSymbolicLink(
            at: fixture.destinationURL,
            withDestinationURL: fixture.sourceURL
        )

        let result = AppDelegate().uninstallCmuxCLIInPath(
            resultPresentation: .silent,
            installer: fixture.installer
        )

        #expect(result == .completed)
        #expect(
            (try? fixture.fileManager.attributesOfItem(atPath: fixture.destinationURL.path)) == nil
        )
    }

    @Test func automationInstallFailureReturnsTypedFailureWithoutPresentingAResultAlert() {
        let installer = CmuxCLIPathInstaller(
            bundledCLIURLProvider: { nil },
            expectedBundledCLIPath: "/missing/cmux"
        )

        let result = AppDelegate().installCmuxCLIInPath(
            resultPresentation: .silent,
            installer: installer
        )

        guard case .failed(let code, let message) = result else {
            Issue.record("Expected a typed install failure")
            return
        }
        #expect(code == "cli_install_failed")
        #expect(message == String(localized: "cli.installFailed", defaultValue: "Couldn't Install cmux CLI"))
    }

    @Test func automationUninstallFailureReturnsTypedFailureWithoutPresentingAResultAlert() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-palette-uninstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let destinationURL = rootURL.appendingPathComponent("cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false)
        let installer = CmuxCLIPathInstaller(destinationURL: destinationURL)

        let result = AppDelegate().uninstallCmuxCLIInPath(
            resultPresentation: .silent,
            installer: installer
        )

        guard case .failed(let code, let message) = result else {
            Issue.record("Expected a typed uninstall failure")
            return
        }
        #expect(code == "cli_uninstall_failed")
        #expect(message == String(localized: "cli.uninstallFailed", defaultValue: "Couldn't Uninstall cmux CLI"))
    }

    private func makeFixture() throws -> CLIPathFixture {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-cli-palette-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let sourceURL = rootURL.appendingPathComponent("bundled-cmux")
        try Data("#!/bin/sh\n".utf8).write(to: sourceURL)
        let destinationURL = rootURL.appendingPathComponent("bin/cmux")
        let installer = CmuxCLIPathInstaller(
            fileManager: fileManager,
            destinationURL: destinationURL,
            bundledCLIURLProvider: { sourceURL },
            expectedBundledCLIPath: sourceURL.path
        )
        return CLIPathFixture(
            fileManager: fileManager,
            rootURL: rootURL,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            installer: installer
        )
    }
}
