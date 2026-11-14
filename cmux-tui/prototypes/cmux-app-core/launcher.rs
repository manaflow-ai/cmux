//! The shared-library arm keeps a real executable in Resources/bin, so
//! current_exe() and sibling-helper lookup retain the standalone CLI layout.

#[link(name = "cmux_core")]
unsafe extern "C" {
    fn cmux_cli_main() -> i32;
}

fn main() -> std::process::ExitCode {
    // SAFETY: this is the program's entry point, called once on its main
    // thread. The linked core exports this C ABI and catches Rust panics.
    let code = unsafe { cmux_cli_main() };
    std::process::ExitCode::from(u8::try_from(code).unwrap_or(1))
}
