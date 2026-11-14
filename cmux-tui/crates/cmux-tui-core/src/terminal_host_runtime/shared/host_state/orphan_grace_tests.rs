use super::*;

#[test]
fn a_normal_install_ends_an_abandoned_host_after_a_week() {
    assert_eq!(orphan_grace_in_force(None, false), ABANDONED_HOST_GRACE);
    assert_eq!(ABANDONED_HOST_GRACE, Duration::from_secs(7 * 24 * 60 * 60));
}

#[cfg(unix)]
#[test]
fn hosts_and_holders_end_abandoned_terminals_after_the_same_grace() {
    assert_eq!(ABANDONED_HOST_GRACE, cmux_holder::ABANDONED_GRACE);
}

#[test]
fn a_build_grace_and_a_removed_record_directory_only_shorten_it() {
    assert_eq!(orphan_grace_in_force(Some(DEV_HOST_ORPHAN_GRACE), false), DEV_HOST_ORPHAN_GRACE);
    let month = Duration::from_secs(30 * 24 * 60 * 60);
    assert_eq!(orphan_grace_in_force(Some(month), false), ABANDONED_HOST_GRACE);
    assert_eq!(orphan_grace_in_force(None, true), RECORD_ROOT_REMOVED_ORPHAN_GRACE);
    assert_eq!(orphan_grace_in_force(Some(Duration::from_secs(1)), true), Duration::from_secs(1));
}
