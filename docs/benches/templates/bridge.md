# Swift↔Rust bridge: bytes and calls per frame, budgeted

**Proves:** a call across the FFI carries what the callee needs, not a whole document, and is made once per change,
not once per row per frame. A synchronous bridge call from the main actor costs its encode + decode + the Rust work.

**The minimal check:**
1. Wrap the bridge entry point in a counter (calls, bytes in, bytes out) the test can read; a test-only shim, not
   production logging.
2. Drive the realistic case (1,104 rows x 5 Chiefs, 160 KB settings) through one flush.
3. Assert: calls <= rows changed (not rows shown), bytes per call under a budget (e.g. 4 KB), total under a frame
   budget. Then repeat at 10x rows: calls and bytes per call stay flat.
4. Rust side: a `#[test]` on the crate's pure function with the same fixture, so the cost is pinned without Swift.

```swift
@MainActor @Test func homeRulesBridgeIsPerChange() {
    let probe = BridgeProbe.install()                  // counts calls and payload bytes at the FFI boundary
    let model = SidebarModel(fixture: .workspaces(1_104, chiefs: 5, settingsBytes: 160_000))
    model.flush()
    #expect(probe.calls <= model.changedRows, "\(probe.calls) bridge calls for \(model.changedRows) changed rows")
    #expect(probe.maxBytesPerCall < 4_096, "a call carried \(probe.maxBytesPerCall) bytes (the settings root?)")
}
```

```rust
#[test]
fn rule_eval_cost_is_flat_in_settings_size() {
    let small = eval_cost(&fixture(1_104, 16 * 1024));
    let big = eval_cost(&fixture(1_104, 160 * 1024));
    assert!(big.as_nanos() <= small.as_nanos() * 2, "{small:?} -> {big:?}: per-row work reads the settings root");
}
```

Copy from: `ChiefFaceFlushBenchTests` (coverage-map.md, Swift↔Rust bridge rows). New logic belongs on the Rust side.
