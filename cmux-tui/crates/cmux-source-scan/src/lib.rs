//! Checks of cmux's Rust sources that read the syntax tree with `syn`.
//!
//! Each check here replaced a script that tokenized Rust by hand and kept missing what a grammar
//! sees at once: a `<T as Trait>::Assoc` path split into tokens, a static on the line a
//! `thread_local!` opens, a brace inside a string literal ending a function, an attribute order.
//! A check asks its questions of the tree (items, attributes, macro token trees, spans) and keeps
//! only its own judgement as heuristics.
//!
//! - [`test_hooks`]: no process-wide test hooks in acpmux (cmux#41350), enforced by acpmux's tests.
//! - [`timing_ratio`]: no wall-clock ratio or upper percentile assert in a default-run test
//!   (cmuxterm-hq docs/handbook/timing-on-a-busy-host.md, fix 7), run by hand over a checkout;
//!   [`nextest`] says which tests nextest runs beside others.
//!
//! `cmux-source-scan test-hooks|timing-ratio ...` runs either over a checkout.

pub mod nextest;
pub mod source;
pub mod test_hooks;
pub mod timing_ratio;
