use super::*;

/// A holder orphaned for a week of wall time, most of it asleep, still
/// counts the week (cmuxterm-hq#8377).
#[test]
fn an_orphan_wait_counts_the_time_the_mac_slept() {
    let since = OrphanSince::at(Instant::now());
    let awake_hour = since.awake + Duration::from_secs(60 * 60);
    let wall_week = since.wall + crate::ABANDONED_GRACE;
    assert!(since.elapsed_at(awake_hour, wall_week) >= crate::ABANDONED_GRACE);
}

/// A wall clock set back counts nothing; the awake time still counts.
#[test]
fn a_wall_clock_set_back_keeps_the_awake_time() {
    let since = OrphanSince::at(Instant::now());
    let awake_day = since.awake + Duration::from_secs(24 * 60 * 60);
    let wall_back = since.wall - Duration::from_secs(30 * 24 * 60 * 60);
    assert_eq!(since.elapsed_at(awake_day, wall_back), Duration::from_secs(24 * 60 * 60));
}
