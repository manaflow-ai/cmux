//! The palette ranker's quality eval (plans/cmux-next/palette-ranking.md section 3), its corpus
//! speed bench and the Chat Minimap settings-row cases: `tests/eval.rs`, `tests/settings_rows.rs`,
//! `examples/eval.rs` and `examples/corpus_bench.rs`. They live outside `cmux-palette-ranker`
//! because every file of that crate is an app FFI input (scripts/cmux-next/check-app-ffi-pin.sh):
//! changing a test there would need a new FFI release.

/// ci-oops 0d proof: a deliberate compile error in an optional member; never merged.
pub fn ci_oops_proof() -> u32 {
    "not a number"
}
