import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the restore-intent marker: it round-trips, is single-use
/// (so a later real crash still classifies correctly), and fails safe.
@Suite struct RelaunchIntentTests {

    private func makeTempHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-relaunch-intent-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func markThenConsumeReportsIntended() {
        let home = makeTempHome()
        RelaunchIntent.markRestoreIntended(reason: "sparkle-update", homeDirectory: home, environment: [:])
        #expect(RelaunchIntent.consumeRestoreIntent(homeDirectory: home, environment: [:]))
    }

    @Test func consumeIsSingleUse() {
        let home = makeTempHome()
        RelaunchIntent.markRestoreIntended(homeDirectory: home, environment: [:])
        #expect(RelaunchIntent.consumeRestoreIntent(homeDirectory: home, environment: [:]))
        // Second consume sees nothing — a later crash classifies as unclean.
        #expect(!RelaunchIntent.consumeRestoreIntent(homeDirectory: home, environment: [:]))
    }

    @Test func markerIsScopedByBundleIdentifier() {
        let home = makeTempHome()
        let stable = ["CMUX_BUNDLE_ID": "com.cmuxterm.app"]
        let tagged = ["CMUX_BUNDLE_ID": "com.cmuxterm.app.debug.update-fix"]

        RelaunchIntent.markRestoreIntended(homeDirectory: home, environment: stable)

        #expect(!RelaunchIntent.consumeRestoreIntent(homeDirectory: home, environment: tagged))
        #expect(RelaunchIntent.consumeRestoreIntent(homeDirectory: home, environment: stable))
        #expect(!RelaunchIntent.consumeRestoreIntent(homeDirectory: home, environment: stable))
    }

    @Test func absentMarkerReportsNotIntended() {
        let home = makeTempHome()
        #expect(!RelaunchIntent.consumeRestoreIntent(homeDirectory: home, environment: [:]))
    }

    @Test func directoryAtMarkerPathReportsNotIntended() throws {
        let home = makeTempHome()
        let marker = RelaunchIntent.markerURL(homeDirectory: home, environment: [:])
        try FileManager.default.createDirectory(
            at: marker,
            withIntermediateDirectories: true
        )

        #expect(!RelaunchIntent.consumeRestoreIntent(homeDirectory: home, environment: [:]))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func markerHonorsXDGStateHome() {
        let home = makeTempHome()
        let xdg = makeTempHome()
        let env = ["XDG_STATE_HOME": xdg.path]
        RelaunchIntent.markRestoreIntended(homeDirectory: home, environment: env)
        let url = RelaunchIntent.markerURL(homeDirectory: home, environment: env)
        #expect(url.path.hasPrefix(xdg.path))
        #expect(RelaunchIntent.consumeRestoreIntent(homeDirectory: home, environment: env))
        // Default location unaffected.
        #expect(!RelaunchIntent.consumeRestoreIntent(homeDirectory: home, environment: [:]))
    }
}
