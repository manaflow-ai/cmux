import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for issue #5977: the session-index row "Open Working
/// Directory" action must route its `cwd` through the shared
/// ``WorkspaceFinderDirectoryOpener`` (existence check + reveal + beep on a
/// stale/moved directory) instead of `NSWorkspace.shared.open`, which silently
/// does nothing when the directory was deleted or moved.
///
/// `SessionRowDirectoryOpener` is the single shared seam used by both the full
/// row and the popover row; injecting a capturing closure asserts the routed URL
/// without touching NSWorkspace. (Pre-fix, the action called
/// `NSWorkspace.shared.open` directly and ignored the opener, so this fails.)
@Suite struct SessionRowDirectoryOpenerTests {
    @Test @MainActor func routesWorkingDirectoryThroughFinderOpener() async {
        let cwd = "/private/tmp/cmux-openwd-\(UUID().uuidString)"
        var routed: [URL] = []
        await SessionRowDirectoryOpener.openWorkingDirectory(cwd: cwd) { routed.append($0) }
        #expect(routed == [URL(fileURLWithPath: cwd)])
    }
}
