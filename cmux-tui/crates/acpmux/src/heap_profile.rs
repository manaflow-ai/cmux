//! The daemon's heap by allocation site, for the god-fixture profile (`tests/god_daemon.rs`). A
//! binary built with the `dhat-heap` feature records every block (dhat), and with
//! `ACPMUX_DHAT_OUT` set it writes them there when it stops: [`finish`] runs before the daemon's
//! `process::exit`, which would skip the profiler's drop. Without the feature both are no-ops.

/// The variable that names the profile's output file.
pub const OUT_ENV: &str = "ACPMUX_DHAT_OUT";

#[cfg(feature = "dhat-heap")]
static PROFILER: std::sync::Mutex<Option<dhat::Profiler>> = std::sync::Mutex::new(None);

/// Starts the profile when [`OUT_ENV`] names a file: first thing in `main`, before any thread.
/// The variable is removed, so a process this one starts (an agent host) writes no profile over
/// it.
pub fn start() {
    #[cfg(feature = "dhat-heap")]
    if let Some(out) = std::env::var_os(OUT_ENV) {
        // SAFETY: called first in `main`, while no other thread runs.
        unsafe { std::env::remove_var(OUT_ENV) };
        // Deep enough to pass serde's recursion and reach the acpmux frame that asked.
        let profiler = dhat::Profiler::builder().file_name(out).trim_backtraces(Some(48)).build();
        *PROFILER.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(profiler);
    }
}

/// Writes the profile, if one runs: before the process exits.
pub fn finish() {
    #[cfg(feature = "dhat-heap")]
    drop(PROFILER.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take());
}
