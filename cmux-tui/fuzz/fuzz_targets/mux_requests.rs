//! The stateful daemon request fuzzer (plans/cmux-next/chrome-parity/
//! p10-stability.md, task 176), Chromium's MojoLPM for the daemon: each
//! input is a sequence of requests, in any order, with live, stale and bogus
//! ids, from every method of spec/sdk-schema.json (a new method is fuzzed
//! with no change here). Each runs through a trusted local connection's own
//! dispatch on an in-memory daemon with no PTYs
//! (cmux_tui_core::server::test_harness). A crash, an answer that is not a
//! typed result or error, an answer sent twice, a broken layout invariant or
//! a durable topology that differs from memory is a finding.
//!
//! A blocking call on a request thread is recorded, not a crash; run with
//! `CMUX_DAEMON_BLOCKING=panic` to make it one.

#![no_main]

use std::sync::LazyLock;

use arbitrary::Unstructured;
use cmux_tui_core::fuzz_entry::requests::{
    Choices, RequestCatalog, record_request_thread_blocking, run,
};
use libfuzzer_sys::fuzz_target;

/// Requests per input.
const MAX_STEPS: usize = 24;

static CATALOG: LazyLock<RequestCatalog> = LazyLock::new(|| {
    record_request_thread_blocking();
    RequestCatalog::daemon().unwrap_or_else(|finding| panic!("{finding}"))
});

/// The generator's decisions, read from the input.
struct Input<'a>(Unstructured<'a>);

impl Choices for Input<'_> {
    fn below(&mut self, n: usize) -> usize {
        self.0.choose_index(n).unwrap_or(0)
    }

    fn exhausted(&self) -> bool {
        self.0.is_empty()
    }
}

fuzz_target!(|data: &[u8]| {
    let mut input = Input(Unstructured::new(data));
    if let Err(finding) = run(&CATALOG, &mut input, MAX_STEPS) {
        panic!("{finding}");
    }
});
