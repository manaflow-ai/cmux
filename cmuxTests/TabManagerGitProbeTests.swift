import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Regression coverage for https://github.com/manaflow-ai/cmux/issues/4529.
//
// On macOS 14 and 15, Foundation's `URL(fileURLWithPath: "/").deletingLastPathComponent()`
// returns `URL("/..")` instead of `URL("/")`, and iterating that operation
// never converges — the path grows `/..`, `/../..`, `/../../..`, etc. Apple
// silently fixed the behavior in macOS 26.
//
// `TabManager.resolveGitRepository(containing:)` walked ancestor directories
// looking for a `.git` entry and stopped only when `parentURL.path ==
// currentURL.path`. With the broken Foundation behavior the stop condition
// never fired, the `while true` body spun on a `Task.detached(priority:
// .utility)` thread, and every iteration allocated a longer NSString path
// plus several autoreleased FileManager and URL temporaries. With no
// `autoreleasepool` around the loop the surrounding pool never drained and
// the process accumulated tens of GB of retained strings.
//
// These tests inject a parent walker that emulates the macOS 14/15 behavior
// so the regression is deterministic on the macOS 26 CI runner that ships
// with the repo. `testGitProbeAscentTerminatesUnderMacOS14StyleParentWalker`
// is the canary that fails before the standardization fix and passes after.
final class TabManagerGitProbeAncestorWalkTests: XCTestCase {
    // Mimics macOS 14/15's broken `URL.deletingLastPathComponent()`:
    // at `/`, returns `/..`; after that, appends another `/..` each call.
    // Anywhere else, defers to Foundation's normal behavior.
    private func macOS14StyleParentWalker(_ url: URL) -> URL {
        let p = url.path
        if p == "/" {
            return URL(fileURLWithPath: "/..")
        }
        if p.hasPrefix("/..") {
            return URL(fileURLWithPath: p + "/..")
        }
        return url.deletingLastPathComponent()
    }

    func testGitProbeAscentTerminatesUnderMacOS14StyleParentWalker() {
        // Walk up from a deep path using the buggy macOS 14/15 walker. The
        // fix in `gitProbeNextAncestor` is to standardize the parent URL so
        // `/..` collapses back to `/` and the path-equal stop condition
        // fires. Without that, this loop hits the test cap.
        var current: URL? = URL(fileURLWithPath: "/Users/test/cmux")
        var iterations = 0
        let cap = 50
        while let url = current, iterations < cap {
            current = TabManager.gitProbeNextAncestor(url, parentResolver: macOS14StyleParentWalker)
            iterations += 1
        }
        XCTAssertNil(current, "ascent must converge to nil at the filesystem root")
        XCTAssertLessThan(iterations, 10, "convergence must be O(depth), not unbounded")
    }

    func testGitProbeAscentTerminatesFromDotsURLUnderMacOS14StyleWalker() {
        // Direct exposure of the bug shape: starting at `/..`, the buggy
        // walker returns `/../..`. The fix must still converge.
        var current: URL? = URL(fileURLWithPath: "/..")
        var iterations = 0
        let cap = 50
        while let url = current, iterations < cap {
            current = TabManager.gitProbeNextAncestor(url, parentResolver: macOS14StyleParentWalker)
            iterations += 1
        }
        XCTAssertNil(current, "ascent from `/..` must converge to nil")
        XCTAssertLessThan(iterations, 5)
    }

    func testGitProbeAscentTerminatesUnderRealFoundation() {
        // Sanity: with real Foundation, the loop must also terminate on the
        // current macOS. Defends against future regressions that break the
        // native path too.
        var current: URL? = URL(fileURLWithPath: "/Users")
        var iterations = 0
        let cap = 50
        while let url = current, iterations < cap {
            current = TabManager.gitProbeNextAncestor(url)
            iterations += 1
        }
        XCTAssertNil(current)
        XCTAssertLessThan(iterations, 10)
    }

    func testResolveGitRepositoryReturnsNilAtRootInBoundedTime() throws {
        let started = Date()
        let result = TabManager.resolveGitRepository(containing: "/")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNil(result, "filesystem root is not a git repository")
        XCTAssertLessThan(elapsed, 1.0, "must terminate quickly even when no .git is found")
    }

    func testGitProbeAscentCapIsGenerous() {
        // The cap exists as defense-in-depth against a future Foundation
        // regression of this bug class. It must be high enough that
        // legitimate deeply-nested checkouts still succeed, but finite so a
        // broken `deletingLastPathComponent` can never burn unbounded RSS.
        XCTAssertGreaterThanOrEqual(TabManager.gitProbeMaxAncestorAscent, 1024)
        XCTAssertLessThanOrEqual(TabManager.gitProbeMaxAncestorAscent, 1 << 20)
    }
}
