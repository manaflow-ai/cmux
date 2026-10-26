//! Standalone `cmux-host`: the `cmux host …` verbs before the `host` noun
//! is mounted in the `cmux` binary (cli-requests/cmux-host-verb.md).

// Threads start through cmux_threads (named, registered, at a declared QoS):
// plans/cmux-next/chrome-parity/p02-threads.md, tasks 213-218.
#![cfg_attr(not(test), deny(clippy::disallowed_methods))]
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    ExitCode::from(cmux_host::cli::run(&args, Vec::new()))
}
