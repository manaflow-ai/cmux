@testable import CmuxComputerUse
import AppKit
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension ComputerUseUXTests {
    @Test(.timeLimit(.minutes(1))) @MainActor
    func permissionRefreshSurvivesHelperSocketReplacement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-cua-permissions-\(UUID().uuidString)",
                isDirectory: true
            )
        let home = root.appendingPathComponent("home", isDirectory: true)
        // Keep the fixture socket under Darwin's short, stable `/tmp` alias.
        // Remote builders can expose a user temp path long enough that even a
        // one-character runtime scope cannot fit in a UNIX-domain socket path.
        let sockets = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "cmux-cu-permissions-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sockets)
        }
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sockets,
            withIntermediateDirectories: true
        )
        let paths = ComputerUseRuntimePaths(
            homeDirectoryURL: home,
            socketRootDirectoryURL: sockets,
            userIdentifier: getuid(),
            environment: ["CMUX_TAG": "permission-replacement"],
            authenticationToken: "permission-test-token"
        )
        let runtime = ComputerUseRuntimeService(
            bundle: Bundle(for: NSApplication.self),
            paths: paths
        )
        await runtime.setEnabled(true)

        // The AppKit bundle has no helper to install, so this fixture owns its socket directory.
        try FileManager.default.createDirectory(
            at: paths.runtimeDirectoryURL,
            withIntermediateDirectories: true
        )
        let unavailable = try UnixSocketResponder(
            path: paths.daemonSocketURL.path,
            response: #"{"ok":false}"#
        )
        let refreshTask = Task { @MainActor in
            await runtime.refreshHelperStatus()
        }
        while unavailable.receivedRequests.isEmpty {
            await Task.yield()
        }
        unavailable.stop()

        let replacement = try UnixSocketResponder(
            path: paths.daemonSocketURL.path,
            response: #"{"ok":true,"result":{"structuredContent":{"accessibility":true,"screen_recording":true}}}"#
        )
        let status = await refreshTask.value
        replacement.stop()

        #expect(runtime.permissionStatusIsKnown)
        #expect(status.accessibility)
        #expect(status.screenRecording)

        await runtime.setEnabled(false)
    }

}
