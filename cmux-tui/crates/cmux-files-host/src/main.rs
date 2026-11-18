//! `cmux-files-host`: see the crate docs and docs/cmux-files-host.md.

use cmux_files_host::{EXECUTABLE, Invocation};
use std::ffi::OsString;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    match cmux_files_host::parse(&args) {
        Invocation::LaunchServicesOpen => ExitCode::SUCCESS,
        Invocation::Usage => {
            eprintln!("usage: {EXECUTABLE} run|host -- PROGRAM [ARGS...]");
            ExitCode::from(2)
        }
        Invocation::Run(program) | Invocation::Host(program) => exec_program(&program),
    }
}

/// Runs the program in place of this process; returns only when it cannot.
fn exec_program(program: &[OsString]) -> ExitCode {
    use std::os::unix::process::CommandExt;
    let Some((first, rest)) = program.split_first() else { return ExitCode::from(2) };
    let error = std::process::Command::new(first).args(rest).exec();
    eprintln!("{EXECUTABLE}: cannot run {}: {error}", first.to_string_lossy());
    ExitCode::from(127)
}
