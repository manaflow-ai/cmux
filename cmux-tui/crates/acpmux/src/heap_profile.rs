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

/// `_acpmux/heap_profile`: writes the profile now, while the daemon still runs, and answers the
/// heap's bytes and blocks then and at its peak. A bench asks it after its last sample: a daemon
/// stopped by a signal can be killed before it reaches [`finish`]. Recording ends with the write;
/// a second ask answers `written: false`. In a build without `dhat-heap`, `available: false`.
pub fn dump() -> serde_json::Value {
    #[cfg(feature = "dhat-heap")]
    {
        let mut slot = PROFILER.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(profiler) = slot.take() else {
            return serde_json::json!({"available": true, "written": false});
        };
        let stats = dhat::HeapStats::get();
        drop(profiler);
        serde_json::json!({
            "available": true,
            "written": true,
            "currBytes": stats.curr_bytes,
            "currBlocks": stats.curr_blocks,
            "maxBytes": stats.max_bytes,
            "maxBlocks": stats.max_blocks,
            "totalBytes": stats.total_bytes,
        })
    }
    #[cfg(not(feature = "dhat-heap"))]
    {
        let mut out = serde_json::Map::new();
        out.insert("available".into(), false.into());
        out.insert("written".into(), false.into());
        if let Some(malloc) = glibc_malloc() {
            out.insert("malloc".into(), malloc);
        }
        serde_json::Value::Object(out)
    }
}

/// The system allocator's own count (glibc `mallinfo2`), in a `system-alloc` build: the bytes the
/// program holds (`inUse`) against the bytes free but kept (`free`), which is the line between a
/// heap that is live data and one that is the allocator's retention. Then `malloc_trim(0)` gives
/// the kept bytes back, and `trimmed` is what it could return.
#[cfg(not(feature = "dhat-heap"))]
fn glibc_malloc() -> Option<serde_json::Value> {
    #[cfg(all(feature = "system-alloc", target_os = "linux", target_env = "gnu"))]
    {
        // SAFETY: mallinfo2 and malloc_trim read and trim glibc's arenas under their own locks.
        let before = unsafe { libc::mallinfo2() };
        let returned = unsafe { libc::malloc_trim(0) };
        let after = unsafe { libc::mallinfo2() };
        let row = |m: &libc::mallinfo2| {
            serde_json::json!({
                "inUse": m.uordblks + m.hblkhd,
                "free": m.fordblks,
                "arena": m.arena,
                "mmapped": m.hblkhd,
                "topPad": m.keepcost,
            })
        };
        return Some(
            serde_json::json!({"before": row(&before), "trimmed": returned, "after": row(&after)}),
        );
    }
    #[allow(unreachable_code)]
    None
}
