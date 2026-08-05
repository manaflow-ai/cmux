mod cli;
mod config;
mod control_plane;
mod oauth;
mod process;
mod tui;

use std::ffi::OsString;
use std::time::Instant;

pub fn run(args: impl IntoIterator<Item = OsString>) -> i32 {
    let args: Vec<OsString> = args.into_iter().collect();
    let command = args
        .get(1)
        .and_then(|value| value.to_str())
        .unwrap_or("status")
        .to_owned();
    let started = Instant::now();
    let result = match cli::run(args) {
        Ok(code) => code,
        Err(error) => {
            eprintln!("cr: {error}");
            1
        }
    };
    eprintln!("cr timing: {command} {} ms", started.elapsed().as_millis());
    result
}
