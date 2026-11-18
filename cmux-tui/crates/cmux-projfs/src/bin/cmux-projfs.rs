//! The mount helper as a small binary of its own (`cmux-projfs mount …`), the same as
//! `cmux-tui projfs …`; see [`cmux_projfs::helper`].

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // The helper's codes are 0 to 3; anything that does not fit a byte is a failure.
    let code = cmux_projfs::helper::run(&args);
    ExitCode::from(u8::try_from(code).unwrap_or(1))
}
