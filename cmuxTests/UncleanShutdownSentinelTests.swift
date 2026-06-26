import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for unclean-shutdown detection: a sentinel written on launch
/// and cleared on clean exit must let the next launch distinguish a crash from
/// a clean quit, and every filesystem failure path must degrade to "clean".
@Suite struct UncleanShutdownSentinelTests {

    /// Isolated fake home so tests never touch the real `~/.local/state/cmux`.
    private func makeTempHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sentinel-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func markRunningMakesPriorRunLookUnclean() {
        let home = makeTempHome()
        let env: [String: String] = [:]
        UncleanShutdownSentinel.markRunning(homeDirectory: home, environment: env)
        // A fresh process (no prior markCleanExit) sees the sentinel.
        #expect(UncleanShutdownSentinel.priorRunWasUnclean(homeDirectory: home, environment: env))
    }

    @Test func cleanExitClearsTheSentinel() {
        let home = makeTempHome()
        let env: [String: String] = [:]
        UncleanShutdownSentinel.markRunning(homeDirectory: home, environment: env)
        UncleanShutdownSentinel.markCleanExit(homeDirectory: home, environment: env)
        #expect(!UncleanShutdownSentinel.priorRunWasUnclean(homeDirectory: home, environment: env))
    }

    @Test func lifecycleMarkersAreScopedByBundleIdentifier() {
        let home = makeTempHome()
        let stable = ["CMUX_BUNDLE_ID": "com.cmuxterm.app"]
        let tagged = ["CMUX_BUNDLE_ID": "com.cmuxterm.app.debug.crash-fix"]

        UncleanShutdownSentinel.markRunning(homeDirectory: home, environment: stable)

        #expect(UncleanShutdownSentinel.priorRunWasUnclean(homeDirectory: home, environment: stable))
        #expect(!UncleanShutdownSentinel.priorRunWasUnclean(homeDirectory: home, environment: tagged))
        #expect(
            UncleanShutdownSentinel.sentinelURL(homeDirectory: home, environment: stable).path
                != UncleanShutdownSentinel.sentinelURL(homeDirectory: home, environment: tagged).path
        )

        UncleanShutdownSentinel.markCleanExit(homeDirectory: home, environment: tagged)
        #expect(UncleanShutdownSentinel.priorRunWasUnclean(homeDirectory: home, environment: stable))

        UncleanShutdownSentinel.markCleanExit(homeDirectory: home, environment: stable)
        #expect(!UncleanShutdownSentinel.priorRunWasUnclean(homeDirectory: home, environment: stable))
    }

    @Test func absentStateDirectoryReadsAsClean() {
        let home = makeTempHome()
        // Nothing written, and the lifecycle dir does not exist.
        #expect(!UncleanShutdownSentinel.priorRunWasUnclean(homeDirectory: home, environment: [:]))
    }

    @Test func markCleanExitWithoutSentinelIsNoOp() {
        let home = makeTempHome()
        let env: [String: String] = [:]
        // Should not throw or create anything; still clean afterwards.
        UncleanShutdownSentinel.markCleanExit(homeDirectory: home, environment: env)
        #expect(!UncleanShutdownSentinel.priorRunWasUnclean(homeDirectory: home, environment: env))
    }

    @Test func markRunningIsIdempotent() {
        let home = makeTempHome()
        let env: [String: String] = [:]
        UncleanShutdownSentinel.markRunning(homeDirectory: home, environment: env)
        UncleanShutdownSentinel.markRunning(homeDirectory: home, environment: env)
        #expect(UncleanShutdownSentinel.priorRunWasUnclean(homeDirectory: home, environment: env))
        UncleanShutdownSentinel.markCleanExit(homeDirectory: home, environment: env)
        #expect(!UncleanShutdownSentinel.priorRunWasUnclean(homeDirectory: home, environment: env))
    }

    @Test func xdgStateHomeIsHonored() {
        let home = makeTempHome()
        let xdg = makeTempHome()
        let env = ["XDG_STATE_HOME": xdg.path]
        UncleanShutdownSentinel.markRunning(homeDirectory: home, environment: env)
        // Sentinel lives under XDG path, not the default home path.
        #expect(UncleanShutdownSentinel.priorRunWasUnclean(homeDirectory: home, environment: env))
        let xdgSentinel = UncleanShutdownSentinel.sentinelURL(homeDirectory: home, environment: env)
        #expect(xdgSentinel.path.hasPrefix(xdg.path))
        #expect(FileManager.default.fileExists(atPath: xdgSentinel.path))
        // The default (~/.local/state) location was not used.
        #expect(!UncleanShutdownSentinel.priorRunWasUnclean(homeDirectory: home, environment: [:]))
    }

    @Test func sentinelIsAFileNotADirectory() {
        let home = makeTempHome()
        let env: [String: String] = [:]
        UncleanShutdownSentinel.markRunning(homeDirectory: home, environment: env)
        let url = UncleanShutdownSentinel.sentinelURL(homeDirectory: home, environment: env)
        var isDir: ObjCBool = true
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        #expect(!isDir.boolValue)
    }
}
