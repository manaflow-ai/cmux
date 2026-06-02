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
/// ``GhosttyApp/resolveCallbackContext(from:)``, which rejects any pointer that
/// does not belong to a live malloc allocation before reinterpreting it as a
/// Swift object. These tests exercise that runtime seam directly — no app
/// launch, no private ghostty callback — by feeding it the exact garbage
/// pointer shape observed in the crash report. Without the fix the garbage
/// cases crash the test process (the ARC retain dereferences invalid memory);
/// with the fix they resolve to `nil`.
@Suite struct GhosttySurfaceCallbackContextTests {
    /// A non-null pointer that does not belong to any malloc zone (the shape of
    /// the freed/garbage context pointer seen in the crash reports) must resolve
    /// to `nil` rather than being reinterpreted as a live Swift object.
    @Test func garbageUserdataResolvesToNil() {
        let garbage = UnsafeMutableRawPointer(bitPattern: 0x1500_0000_0014)
        #expect(garbage != nil)
        #expect(GhosttyApp.resolveCallbackContext(from: garbage) == nil)
    }

    /// A second arbitrary out-of-zone address, to guard against the first value
    /// happening to land inside a live zone on some allocator configuration.
    @Test func secondGarbageUserdataResolvesToNil() {
        let garbage = UnsafeMutableRawPointer(bitPattern: 0x0FB9_5B38)
        #expect(garbage != nil)
        #expect(GhosttyApp.resolveCallbackContext(from: garbage) == nil)
    }

    /// A null `userdata` pointer resolves to `nil` (unchanged contract).
    @Test func nilUserdataResolvesToNil() {
        #expect(GhosttyApp.resolveCallbackContext(from: nil) == nil)
    }
}
