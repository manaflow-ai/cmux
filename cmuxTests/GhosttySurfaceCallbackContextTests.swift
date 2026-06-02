import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the intermittent `EXC_BAD_ACCESS` in
/// `GhosttyApp.handleAction(target:action:)` where a queued ghostty mailbox
/// action (e.g. `scrollbar`) drained a surface whose `userdata` slot still
/// pointed at an already-released `GhosttySurfaceCallbackContext`.
///
/// The faulting path was
/// `ghostty_surface_userdata(...)` → `callbackContext(from:)`
/// → `Unmanaged.fromOpaque(...).takeUnretainedValue()` (the returned reference
/// is ARC-retained) → `swift_retain(<garbage>)` → crash. The garbage pointer
/// was the context itself (e.g. `0x15000000014`), a freed/torn allocation.
///
/// The fix routes every `userdata → context` conversion through
/// ``GhosttyApp/resolveCallbackContext(from:)``, which consults a
/// lifetime-bound registry: ``GhosttySurfaceCallbackContext`` records its own
/// address on `init` and removes it on `deinit`, so membership tracks true
/// object lifetime. (A `malloc_size`-based heuristic was tried first and
/// failed: libmalloc keeps freed small blocks on the zone free list, so a
/// freed-but-not-reused context still appeared live.) These tests exercise that
/// runtime seam directly — no app launch, no private ghostty callback.
@Suite struct GhosttySurfaceCallbackContextTests {
    /// A non-null pointer that is not a registered live context (the shape of the
    /// freed/garbage context pointer seen in the crash reports) must resolve to
    /// `nil` rather than being reinterpreted as a live Swift object.
    ///
    /// Two distinct out-of-zone addresses are exercised so a single value
    /// happening to land inside a live zone on some allocator configuration does
    /// not mask a regression.
    @Test(arguments: [0x1500_0000_0014, 0x0FB9_5B38])
    func garbageUserdataResolvesToNil(_ bits: Int) {
        let garbage = UnsafeMutableRawPointer(bitPattern: bits)
        #expect(garbage != nil)
        #expect(GhosttyApp.resolveCallbackContext(from: garbage) == nil)
    }

    /// A null `userdata` pointer resolves to `nil` (unchanged contract).
    @Test func nilUserdataResolvesToNil() {
        #expect(GhosttyApp.resolveCallbackContext(from: nil) == nil)
    }

    /// A genuinely live malloc block that was never registered as a context is
    /// rejected — liveness means "is a tracked context", not merely "points at
    /// allocated memory" (the distinction the malloc heuristic got wrong).
    @Test func unregisteredAllocationIsNotLive() {
        let block = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
        defer { block.deallocate() }
        #expect(!GhosttySurfaceCallbackContext.isLive(block))
        #expect(GhosttyApp.resolveCallbackContext(from: block) == nil)
    }

    /// End-to-end lifecycle: a real context registers itself on `init` (so its
    /// address resolves back to the same instance), and once the last strong
    /// reference is dropped `deinit` unregisters it (so the now-dangling address
    /// resolves to `nil` instead of ARC-retaining freed memory). This is the
    /// exact transition the crash exploited.
    @MainActor
    @Test func contextLifecycleRegistersThenUnregisters() {
        let terminalSurface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
            configTemplate: nil
        )
        defer { terminalSurface.teardownSurface() }
        let surfaceView = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        // Capture the raw address while the context is alive, asserting it
        // resolves back to the very same instance.
        let pointer: UnsafeMutableRawPointer = {
            let context = GhosttySurfaceCallbackContext(
                surfaceView: surfaceView,
                terminalSurface: terminalSurface
            )
            let raw = Unmanaged.passUnretained(context).toOpaque()
            #expect(GhosttySurfaceCallbackContext.isLive(raw))
            #expect(GhosttyApp.resolveCallbackContext(from: raw) === context)
            return raw
        }()

        // The closure's only strong reference is gone, so `deinit` has run and
        // unregistered the pointer. Resolving it must now be safe and `nil`.
        #expect(!GhosttySurfaceCallbackContext.isLive(pointer))
        #expect(GhosttyApp.resolveCallbackContext(from: pointer) == nil)
    }
}
