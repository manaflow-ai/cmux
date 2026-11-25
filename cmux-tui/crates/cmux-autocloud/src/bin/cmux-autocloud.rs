//! The standalone `cmux-autocloud` binary; `cmux autocloud` runs the same code.

fn main() -> std::process::ExitCode {
    let code = cmux_autocloud::run(std::env::args_os().collect());
    std::process::ExitCode::from(u8::try_from(code).unwrap_or(1))
}
