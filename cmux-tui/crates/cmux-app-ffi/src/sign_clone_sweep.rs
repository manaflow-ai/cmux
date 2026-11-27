//! The app's idle pass over the Chromium code-sign clones cmux apps left
//! behind (cmux-sign-clone-sweep; `include/cmux_sign_clone_sweep.h`, Swift
//! module `CCmuxSignCloneSweepFFI`). Glue only: the rules, their tests and
//! `cmux sign-clones sweep` live in that crate.

pub use cmux_sign_clone_sweep::Report as CmuxSignCloneSweepReport;

/// One bounded pass on this Mac; `None` when nothing could be checked.
#[cfg(target_os = "macos")]
fn sweep_host(budget: cmux_sign_clone_sweep::Budget) -> Option<CmuxSignCloneSweepReport> {
    let now = std::time::SystemTime::now();
    let started = cmux_sign_clone_sweep::cutoff(cmux_sign_clone_sweep::host::process_start()?, now);
    cmux_sign_clone_sweep::host::run_pass(started, budget, false).map(|(_, report)| report)
}

#[cfg(not(target_os = "macos"))]
fn sweep_host(_budget: cmux_sign_clone_sweep::Budget) -> Option<CmuxSignCloneSweepReport> {
    Some(CmuxSignCloneSweepReport::default())
}

/// One pass over the stale Chromium code-sign clones of every cmux app on this
/// Mac. Run it at idle, off the main thread, in the launch's last stage; while
/// `out->more`, run another pass later. Removes at most `max_clones` clones and
/// stops once `max_bytes` are reclaimed. Returns false, with `*out` zeroed,
/// when the temp folder or this process's start time cannot be read (nothing
/// is removed then).
///
/// # Safety
/// `out` is null or points to a writable `CmuxSignCloneSweepReport`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sign_clone_sweep(
    max_bytes: u64,
    max_clones: u32,
    out: *mut CmuxSignCloneSweepReport,
) -> bool {
    let result = sweep_host(cmux_sign_clone_sweep::Budget { max_bytes, max_clones });
    // SAFETY: `out` is null or writable per the contract above.
    if let Some(out) = unsafe { out.as_mut() } {
        *out = result.unwrap_or_default();
    }
    result.is_some()
}

#[cfg(test)]
#[path = "sign_clone_sweep_tests.rs"]
mod tests;
