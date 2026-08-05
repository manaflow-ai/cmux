mod cli;
mod config;
mod control_plane;
mod oauth;
mod process;
mod status;
mod tui;

use std::ffi::OsString;
pub fn run(args: impl IntoIterator<Item = OsString>) -> i32 {
    let args: Vec<OsString> = args.into_iter().collect();
    match cli::run(args) {
        Ok(code) => code,
        Err(error) => {
            eprintln!("cr: {error}");
            1
        }
    }
}
