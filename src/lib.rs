mod cli;
mod config;
mod control_plane;
mod handoff;
mod loading;
mod oauth;
mod process;
mod status;
mod telemetry;
mod tui;

use std::ffi::OsString;
pub fn run(args: impl IntoIterator<Item = OsString>) -> i32 {
    let args: Vec<OsString> = args.into_iter().collect();
    let telemetry = telemetry::CommandTelemetry::start(&args);
    let result = cli::run(args);
    let exit_code = match &result {
        Ok(code) => *code,
        Err(error) => {
            eprintln!("coderouter: {error}");
            1
        }
    };
    telemetry.finish(&result, exit_code);
    exit_code
}
