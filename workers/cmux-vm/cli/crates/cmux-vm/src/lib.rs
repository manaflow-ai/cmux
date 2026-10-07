//! The `cmux-vm` command-line client.

pub mod exit;

use std::io::Write;

/// Runs the CLI with `args` (including the program name), reading
/// configuration through `env`, and returns the process exit code.
pub async fn run<I, T>(
    _args: I,
    _env: &dyn Fn(&str) -> Option<String>,
    _stdout: &mut dyn Write,
    stderr: &mut dyn Write,
) -> i32
where
    I: IntoIterator<Item = T>,
    T: Into<std::ffi::OsString> + Clone,
{
    let _ = writeln!(stderr, "cmux-vm: not implemented");
    exit::UNEXPECTED
}
