//! The daemon's heap by allocation site, for measurement (CMUX-571 infinite items:
//! what the daemon holds per workspace). A binary built with the `dhat-heap`
//! feature records every block (dhat), and with [`OUT_ENV`] set it writes them
//! there when the process exits: [`start`] registers an `atexit` hook, which
//! `std::process::exit` runs (it skips the profiler's drop). Without the
//! feature both are no-ops; no shipped build enables it.
//!
//! Mid-run windows (the parked-growth bench): with [`MARKS_ENV`] set too, a
//! file `<out>.mark` appearing makes the profile end there, written to
//! `<out>.<n>`, and a fresh one start. A window's bytes live at its end are
//! what was allocated in it and still held, by site: an exit profile cannot
//! see them, because exit tears the mux down first.

/// The variable that names the profile's output file.
#[cfg_attr(not(feature = "dhat-heap"), allow(dead_code))]
pub(crate) const OUT_ENV: &str = "CMUX_TUI_DHAT_OUT";

/// Set (to anything) with [`OUT_ENV`]: watch `<out>.mark` for window ends.
#[cfg_attr(not(feature = "dhat-heap"), allow(dead_code))]
pub(crate) const MARKS_ENV: &str = "CMUX_TUI_DHAT_MARKS";

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
        let marks = std::env::var_os(MARKS_ENV).is_some();
        // SAFETY: as above.
        unsafe { std::env::remove_var(MARKS_ENV) };
        let out = std::path::PathBuf::from(out);
        *PROFILER.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(build(&out));
        if marks {
            // Measurement builds only. The thread reads no environment (main's
            // first statements still change it) and waits before its first look.
            let watched = out.clone();
            std::thread::Builder::new()
                .name("dhat-marks".into())
                .spawn(move || watch_marks(&watched))
                .ok();
        }
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

#[cfg(feature = "dhat-heap")]
fn build(out: &std::path::Path) -> dhat::Profiler {
    dhat::Profiler::builder().file_name(out).trim_backtraces(Some(32)).build()
}

/// Ends the running window on each `<out>.mark`: the profile is written to
/// `<out>`, renamed `<out>.<n>`, and a new window starts. The mark is removed
/// last, so its removal tells the bench the window file is whole.
#[cfg(feature = "dhat-heap")]
fn watch_marks(out: &std::path::Path) {
    let mark = out.with_extension("mark");
    let mut n = 0u32;
    std::thread::sleep(std::time::Duration::from_secs(5));
    loop {
        if mark.exists() {
            n += 1;
            let mut slot = PROFILER.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            drop(slot.take());
            let _ = std::fs::rename(out, out.with_extension(format!("{n}")));
            *slot = Some(build(out));
            drop(slot);
            let _ = std::fs::remove_file(&mark);
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
}
