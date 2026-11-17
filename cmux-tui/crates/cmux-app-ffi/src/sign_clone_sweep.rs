//! The app's idle pass over the Chromium code-sign clones cmux apps left
//! behind (cmux-sign-clone-sweep; `include/cmux_sign_clone_sweep.h`, Swift
//! module `CCmuxSignCloneSweepFFI`). Glue only: the rules, their tests and
//! `cmux sign-clones sweep` live in that crate.

pub use cmux_sign_clone_sweep::Report as CmuxSignCloneSweepReport;

/// One bounded pass on this Mac; `None` when nothing could be checked.
#[cfg(target_os = "macos")]
fn sweep_host(budget: cmux_sign_clone_sweep::Budget) -> Option<CmuxSignCloneSweepReport> {
    let started = cmux_sign_clone_sweep::host::process_start()?;
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
mod tests {
    use super::*;

    #[test]
    fn sign_clone_report_layout_matches_the_header() {
        use std::mem::{offset_of, size_of};
        type R = CmuxSignCloneSweepReport;
        assert_eq!(size_of::<R>(), 40);
        assert_eq!(
            [
                offset_of!(R, reclaimed_bytes),
                offset_of!(R, free_space_delta_bytes),
                offset_of!(R, removed),
                offset_of!(R, removed_superseded),
                offset_of!(R, kept_in_use),
                offset_of!(R, kept_foreign),
                offset_of!(R, more),
            ],
            [0, 8, 16, 20, 24, 28, 32]
        );
    }

    #[test]
    fn sign_clone_sweep_ffi_tolerates_a_null_report() {
        // SAFETY: a null report is allowed by the contract.
        assert!(unsafe { cmux_sign_clone_sweep(0, 0, std::ptr::null_mut()) });
    }
}
