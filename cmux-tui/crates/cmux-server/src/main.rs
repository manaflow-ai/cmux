//! Standalone `cmux-server`: the `cmux server …` verbs without the rest of
//! `cmux`. Also accepts a leading `server` word, so Postgres's
//! `archive_command` works with either binary.

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    cmux_server::cli::run(&args)
}
