//! Standalone `cmux-host`: the `cmux host …` verbs before the `host` noun
//! is mounted in the `cmux` binary (cli-requests/cmux-host-verb.md).

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    cmux_host::cli::run(&args, Vec::new())
}
