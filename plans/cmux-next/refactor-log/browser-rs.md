# browser.rs refactor lane (cmux-tui-core/src/browser.rs)

Move-only split of the browser surface runtime into `browser/` child modules.
Baseline: browser.rs 11,480 lines, 387 fns, 123 inline unit tests.
Incremental `cargo build -p cmux-tui-core` after a one-line edit in
`normalize_url` (32 vCPU Testbox, warm): 19.4 s / 18.5 s before the split.

## Landings

- 2026-10-09 step 1: `mod tests` (6,085 lines, 123 tests) -> browser/tests/{mod.rs (helpers), runtime_routes, worker_and_input_mapping, document_authority, pointer_capture, navigation_barriers, reconfigure_and_attach}.rs; tests 123 -> 123; browser.rs 11,480 -> 5,396; gate 7 min (fmt, clippy -D warnings, cmux-tui-core tests 2,603 pass, windows-gnu check --tests).
- 2026-10-09 step 2: impl BrowserRuntime, new_surface*, capture helpers, endpoint, router -> browser/runtime.rs (535); surface thread, command worker, lifecycle deadlines, emit_* -> browser/worker.rs (656); private items -> pub(super); tests 123 -> 123; browser.rs 5,396 -> 4,234; gate 4 min.
- 2026-10-09 step 3: BrowserSurface methods -> browser/surface_state.rs (466), surface_reconfigure.rs (304), surface_frames.rs (197), surface_pointer.rs (435); private methods -> pub(super); tests 123 -> 123; browser.rs 4,234 -> 2,888; gate 4 min.
- 2026-10-09 step 4: BrowserSurface methods -> browser/surface_transitions.rs, surface_authority.rs, surface_queue.rs; private methods -> pub(super); tests 123 -> 123; browser.rs 2,888 -> 1,933; gate 3 min.
- 2026-10-09 step 5: BrowserSurface methods -> browser/surface_input.rs (512), surface_paint_verification.rs (333), surface_navigation.rs (115); CDP handlers -> cdp_events.rs (98); normalize_url + helpers -> url_input.rs (70, re-exported); tests 123 -> 123; browser.rs 1,933 -> 845 (godfile row dropped). Incremental `cargo build -p cmux-tui-core` after a one-line edit: 15.3 s (url_input.rs) / 15.5-16.0 s (browser.rs) vs 18.5-19.4 s before; same box class, noise not measured.

Phase 2 (owner split, R1a, not started): BrowserSurface still owns every concern through one BrowserState mutex. Candidates: a PointerAuthority owner (pointer frame range, capture, admission), a PaintAuthority owner (navigation epochs, screencast reservations), and a ReconfigureQueue owner. Agree with the browser feature owner first.
