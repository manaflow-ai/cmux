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
//! The process gets a HOME of its own before the first input, as the
//! daemon's socket tests do, so no request reads or writes the person's
//! files. A blocking call on a request thread is recorded, not a crash; run
//! with `CMUX_DAEMON_BLOCKING=panic` to make it one.

#![no_main]

use std::sync::OnceLock;

use arbitrary::Unstructured;
use cmux_tui_core::fuzz_entry::requests::{
    Choices, RequestCatalog, record_request_thread_blocking, run,
};
use libfuzzer_sys::fuzz_target;

/// Requests per input.
const MAX_STEPS: usize = 24;

static CATALOG: OnceLock<RequestCatalog> = OnceLock::new();

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

/// Points HOME and the XDG and cmux config locations at a private folder.
/// Runs in `LLVMFuzzerInitialize`, before any thread of this target starts.
fn isolate_home() {
    let home = std::env::temp_dir().join(format!("cmux-mux-requests-{}", std::process::id()));
    std::fs::create_dir_all(&home).unwrap_or_else(|error| panic!("{}: {error}", home.display()));
    let vars = [
        ("HOME", home.clone()),
        ("XDG_CONFIG_HOME", home.join(".config")),
        ("XDG_DATA_HOME", home.join(".local/share")),
        ("XDG_STATE_HOME", home.join(".local/state")),
        ("XDG_CACHE_HOME", home.join(".cache")),
        ("CMUX_NEXT_CONFIG_FILE", home.join(".config/cmux/cmux-next.json")),
    ];
    for (name, value) in vars {
        // SAFETY: libFuzzer calls the init block once on its main thread
        // before the first input; no thread of this process reads the
        // environment yet.
        unsafe { std::env::set_var(name, value) };
    }
}

fuzz_target!(
    init: {
        isolate_home();
        record_request_thread_blocking();
        let catalog = RequestCatalog::daemon().unwrap_or_else(|finding| panic!("{finding}"));
        let _ = CATALOG.set(catalog);
    },
    |data: &[u8]| {
        let Some(catalog) = CATALOG.get() else { return };
        let mut input = Input(Unstructured::new(data));
        if let Err(finding) = run(catalog, &mut input, MAX_STEPS) {
            panic!("{finding}");
        }
    }
);
