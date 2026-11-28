use super::*;

#[test]
fn a_stale_reading_or_a_failed_read_after_it_is_unreachable() {
    let now = 10 * STALE_MS;
    assert_eq!(row_unreachable(&json!({"healthAt": now - 60_000}), now), None);
    let stale = row_unreachable(&json!({"healthAt": now - STALE_MS - 1}), now).unwrap();
    assert!(stale.contains("5 min old"), "{stale}");
    let failed =
        row_unreachable(&json!({"healthAt": now - 90_000, "healthFailedAt": now - 30_000}), now)
            .unwrap();
    assert!(failed.contains("failed 30s ago"), "{failed}");
    // A read that failed before the reading it has is old news.
    assert_eq!(
        row_unreachable(&json!({"healthAt": now - 1_000, "healthFailedAt": now - 30_000}), now),
        None
    );
    // No reading and no failure: unknown, not unreachable (`weigh` says so).
    assert_eq!(row_unreachable(&json!({}), now), None);
    assert!(row_unreachable(&json!({"healthFailedAt": now - 1_000}), now).is_some());
}

#[test]
fn a_failed_transfer_keeps_a_host_off_for_the_cooldown() {
    let mut f = Failures::default();
    f.record("Lane-A", "scp: Connection closed", 1_000);
    let why = f.failure("lane-a", 31_000).unwrap();
    assert!(why.contains("scp: Connection closed 30s ago"), "{why}");
    assert!(why.contains("tried again in 10 min"), "{why}");
    assert_eq!(f.failure("lane-a", 1_000 + COOLDOWN_MS), None);
    assert_eq!(f.failure("lane-b", 2_000), None);
    // Round trip through the file's bytes.
    assert_eq!(Failures::parse(&f.to_bytes()), f);
    assert!(f.clear("lane-a"));
    assert_eq!(f.failure("lane-a", 2_000), None);
    assert_eq!(Failures::parse(b"not json"), Failures::default());
}

#[test]
fn concurrent_launchers_keep_each_hosts_failure() {
    const HOSTS: usize = 16;
    let dir = tempfile::tempdir().unwrap();
    let dir = dir.path();
    let start = std::sync::Barrier::new(HOSTS);
    std::thread::scope(|threads| {
        for i in 0..HOSTS {
            let start = &start;
            threads.spawn(move || {
                start.wait();
                Failures::update(dir, |f| f.record(&format!("lane-{i}"), "copy failed", 1))
                    .unwrap();
            });
        }
    });
    let stored = Failures::parse(&std::fs::read(dir.join(FILE)).unwrap());
    for i in 0..HOSTS {
        assert!(stored.failure(&format!("lane-{i}"), 2).is_some());
    }
}

#[test]
fn the_file_keeps_at_most_max_hosts_and_drops_expired_ones() {
    let mut f = Failures::default();
    for i in 0..(MAX_HOSTS as u64 + 5) {
        f.record(&format!("h{i}"), "x", 1_000 + i);
    }
    assert_eq!(f.0.len(), MAX_HOSTS);
    assert!(f.failure("h0", 2_000).is_none(), "the oldest went first");
    f.record("late", "x", 10 * COOLDOWN_MS);
    assert_eq!(f.0.len(), 1, "expired entries pruned");
}
