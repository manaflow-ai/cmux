use super::*;

#[test]
fn a_normal_install_ends_an_abandoned_host_after_ten_minutes() {
    assert_eq!(orphan_grace_in_force(None, false), ABANDONED_HOST_GRACE);
    assert_eq!(ABANDONED_HOST_GRACE, Duration::from_secs(10 * 60));
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

/// A Mac's awake clock stops while it sleeps: a host orphaned for a week of
/// wall time, most of it asleep, still counts the week (cmuxterm-hq#8377).
#[test]
fn an_orphan_wait_counts_the_time_the_mac_slept() {
    let since = OrphanSince::now();
    let awake_hour = since.awake + Duration::from_secs(60 * 60);
    let wall_week = since.wall + ABANDONED_HOST_GRACE;
    assert!(since.elapsed_at(awake_hour, wall_week) >= ABANDONED_HOST_GRACE);
}

/// A wall clock set back counts nothing; the awake time still counts.
#[test]
fn a_wall_clock_set_back_keeps_the_awake_time() {
    let since = OrphanSince::now();
    let awake_day = since.awake + Duration::from_secs(24 * 60 * 60);
    let wall_back = since.wall - Duration::from_secs(30 * 24 * 60 * 60);
    assert_eq!(since.elapsed_at(awake_day, wall_back), Duration::from_secs(24 * 60 * 60));
}
