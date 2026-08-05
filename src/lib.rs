mod backend;
mod cli;
mod process;
mod tui;

use std::ffi::OsString;

pub fn run(args: impl IntoIterator<Item = OsString>) -> i32 {
    match cli::run(args) {
        Ok(code) => code,
        Err(error) => {
            eprintln!("cr: {error}");
            1
        }
    }
}
