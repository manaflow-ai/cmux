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

/// Only a token file that is gone, or names another token, makes a holder
/// unadoptable; an unreadable one keeps it (a CI Mac, 2026-11-27: holders of
/// deleted CI state roots kept 510 shells and every pty for a week).
#[test]
fn a_token_file_that_is_gone_or_replaced_makes_the_holder_unadoptable() {
    let dir = std::env::temp_dir().join(format!("cmux-holder-token-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("holder.token");
    let token = [0x5a; 32];
    let hex: String = token.iter().map(|byte| format!("{byte:02x}")).collect();
    std::fs::write(&path, format!("{hex}\n")).unwrap();
    assert!(token_file_adopts(&path, &token));
    std::fs::write(&path, "ab".repeat(32)).unwrap();
    assert!(!token_file_adopts(&path, &token), "another session's token");
    std::fs::write(&path, "half-written").unwrap();
    assert!(token_file_adopts(&path, &token), "a token file being written");
    std::fs::remove_file(&path).unwrap();
    assert!(!token_file_adopts(&path, &token), "the state root was deleted");
    let _ = std::fs::remove_dir_all(&dir);
}
