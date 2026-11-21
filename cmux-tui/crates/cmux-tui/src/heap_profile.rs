//! The daemon's heap by allocation site, for measurement (CMUX-571 infinite items:
//! what the daemon holds per workspace). A binary built with the `dhat-heap`
//! feature records every block (dhat), and with [`OUT_ENV`] set it writes them
//! there when the process exits: [`start`] registers an `atexit` hook, which
//! `std::process::exit` runs (it skips the profiler's drop). Without the
//! feature both are no-ops; no shipped build enables it.

/// The variable that names the profile's output file.
#[cfg_attr(not(feature = "dhat-heap"), allow(dead_code))]
pub(crate) const OUT_ENV: &str = "CMUX_TUI_DHAT_OUT";

#[cfg(feature = "dhat-heap")]
#[global_allocator]
static ALLOC: dhat::Alloc = dhat::Alloc;

#[cfg(feature = "dhat-heap")]
static PROFILER: std::sync::Mutex<Option<dhat::Profiler>> = std::sync::Mutex::new(None);

/// Starts the profile when [`OUT_ENV`] names a file: first thing in `main`,
/// before any thread. The variable is removed, so a process this one starts
/// (a terminal host) writes no profile over it.
pub(crate) fn start() {
    #[cfg(feature = "dhat-heap")]
    if let Some(out) = std::env::var_os(OUT_ENV) {
        // SAFETY: called first in `main`, while no other thread runs.
        unsafe { std::env::remove_var(OUT_ENV) };
        let profiler = dhat::Profiler::builder().file_name(out).trim_backtraces(Some(32)).build();
        *PROFILER.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(profiler);
        #[cfg(unix)]
        // SAFETY: `finish_at_exit` is a plain extern "C" fn with no arguments.
        unsafe {
            libc::atexit(finish_at_exit);
        }
    }
}

/// Writes the profile, if one runs.
#[cfg(all(feature = "dhat-heap", unix))]
extern "C" fn finish_at_exit() {
    drop(PROFILER.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take());
}
