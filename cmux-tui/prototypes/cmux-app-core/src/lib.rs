//! CMUX-570's combined Rust link, shared by the two packaging experiments.
//!
//! The dynamic library is loaded by the app and a thin CLI executable. The
//! static archive is linked into the app executable for the multicall arm.
//! Neither is selected by a shipping build. Both must retain every C export
//! from the existing app FFI, checked against its published headers before
//! packaging; comparing archive sizes alone does not measure installed bytes.

pub use cmux_app_ffi::*;

/// Run the CLI with this process's arguments and return its exit status.
///
/// The launcher calls this once on the main thread, before starting any GUI
/// or worker threads. As with the standalone CLI, some commands exit the
/// process directly. A Rust panic must never unwind into the native launcher.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_cli_main() -> i32 {
    match std::panic::catch_unwind(cmux_tui::main) {
        Ok(code) => (0..=u8::MAX)
            .find(|value| std::process::ExitCode::from(*value) == code)
            .map_or(1, i32::from),
        Err(_) => 101,
    }
}
