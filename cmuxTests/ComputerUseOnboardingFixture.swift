import Darwin
@testable import CmuxComputerUse
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Entirely synthetic paths, preferences, and capabilities for setup lifecycle tests.
@MainActor
struct ComputerUseOnboardingFixture {
    let suite = "ComputerUseOnboarding-\(UUID().uuidString)"
    let defaults: UserDefaults
    let root: URL
    let paths: ComputerUseRuntimePaths
    var completionKey: String { "cmux.computerUse.onboarding.completion.\(paths.scope)" }

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        root = URL(fileURLWithPath: "/tmp/cu-\(UUID().uuidString.prefix(8))", isDirectory: true)
        paths = ComputerUseRuntimePaths(
            homeDirectoryURL: root.appendingPathComponent("home"),
            socketRootDirectoryURL: root,
            userIdentifier: getuid(),
            environment: ["CMUX_TAG": "fixture"],
            authenticationToken: "synthetic-agent-capability",
            hostAuthenticationToken: "synthetic-host-capability"
        )
        try FileManager.default.createDirectory(at: paths.runtimeDirectoryURL, withIntermediateDirectories: true)
    }

    func store(scope: String? = nil) -> ComputerUseOnboardingStore {
        ComputerUseOnboardingStore(defaults: defaults, scope: scope ?? paths.scope)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
