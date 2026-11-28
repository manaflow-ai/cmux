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
