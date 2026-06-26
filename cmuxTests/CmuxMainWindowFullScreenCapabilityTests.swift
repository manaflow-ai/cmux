import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("CmuxMainWindow native fullscreen capability")
struct CmuxMainWindowFullScreenCapabilityTests {
    // cmux creates its main window programmatically and never loaded fullscreen
    // capability from a nib, so it historically relied on AppKit *implicitly*
    // granting `.fullScreenPrimary` to a resizable, titled window. That implicit
    // grant is not reliable across macOS versions / display arrangements: on
    // macOS 26 (Tahoe) a freshly-created CmuxMainWindow reports an empty
    // collection behavior (`rawValue == 0`) and AppKit does NOT treat it as
    // fullscreen-capable — so `toggleFullScreen(_:)`, ⌃⌘F, and the green
    // traffic-light button all fail to enter a native fullscreen Space (the
    // green button only zooms). See issue #5933.
    //
    // A CmuxMainWindow must therefore *declare* `.fullScreenPrimary` itself so
    // native fullscreen is reachable regardless of the OS's implicit default.
    @Test func mainWindowDeclaresFullScreenPrimaryCapability() {
        let window = CmuxMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.close()
        }

        #expect(
            window.collectionBehavior.contains(.fullScreenPrimary),
            "Main window must declare .fullScreenPrimary so native fullscreen is reachable"
        )
        #expect(
            !window.collectionBehavior.contains(.fullScreenNone),
            "Main window must never carry .fullScreenNone, which suppresses native fullscreen"
        )
    }

    // The capability decision is a pure, screen-agnostic transform so it runs
    // deterministically on CI regardless of the test host's display setup.

    @Test func canonicalBehaviorAddsFullScreenPrimaryToEmptyBehavior() {
        let result = CmuxMainWindow.canonicalCollectionBehavior([])
        #expect(result.contains(.fullScreenPrimary))
        #expect(!result.contains(.fullScreenNone))
    }

    @Test func canonicalBehaviorDropsStaleFullScreenNone() {
        let result = CmuxMainWindow.canonicalCollectionBehavior([.fullScreenNone])
        #expect(result.contains(.fullScreenPrimary))
        #expect(!result.contains(.fullScreenNone))
    }

    @Test func canonicalBehaviorPreservesUnrelatedBehaviorBits() {
        // The window factory may layer `.fullScreenDisallowsTiling` on top when
        // spawning out of an existing fullscreen Space; canonicalization must
        // not clobber that (or any other unrelated bit).
        let base: NSWindow.CollectionBehavior = [.fullScreenDisallowsTiling, .moveToActiveSpace]
        let result = CmuxMainWindow.canonicalCollectionBehavior(base)
        #expect(result.contains(.fullScreenPrimary))
        #expect(result.contains(.fullScreenDisallowsTiling))
        #expect(result.contains(.moveToActiveSpace))
    }

    @Test func canonicalBehaviorIsIdempotent() {
        let once = CmuxMainWindow.canonicalCollectionBehavior([])
        let twice = CmuxMainWindow.canonicalCollectionBehavior(once)
        #expect(once == twice)
    }
}
