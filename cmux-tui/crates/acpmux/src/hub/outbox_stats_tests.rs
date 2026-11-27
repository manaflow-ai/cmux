use super::*;

#[test]
fn buckets_are_log2_of_milliseconds() {
    assert_eq!(bucket(0), 0);
    assert_eq!(bucket(1), 1);
    assert_eq!(bucket(2), 2);
    assert_eq!(bucket(3), 2);
    assert_eq!(bucket(87), 7);
    assert_eq!(bucket(1_400_000), 21);
    assert_eq!(bucket(u64::MAX), BUCKETS - 1);
}

#[test]
fn a_delivery_counts_once_with_its_latency_and_retries() {
    let mut c = Counters::starting(1);
    c.note_queued();
    // Attempt 1 starts: no retry.
    c.note_change((State::Queued, 0), State::Delivering, 1, 100, None, 110);
    // Attempts 2 and 3: two retries.
    c.note_change((State::Delivering, 1), State::Queued, 1, 100, None, 120);
    c.note_change((State::Queued, 1), State::Delivering, 3, 100, None, 130);
    c.note_change((State::Delivering, 3), State::Delivered, 3, 100, None, 187);
    // A later change that keeps it delivered does not count it again.
    c.note_change((State::Delivered, 3), State::Delivered, 3, 100, None, 200);
    assert_eq!((c.queued, c.delivered, c.retries), (1, 1, 2));
    assert_eq!(c.latency_ms_log2[bucket(87)], 1);
    assert_eq!(c.latency_quantile_ms(0.95), Some(128));
}

#[test]
fn failures_count_by_a_bounded_class() {
    let mut c = Counters::starting(1);
    for e in [
        "the mesh hub refused it: the hub answered 404 mesh.unknown_recipient",
        "the hub answered 503 mesh.unavailable",
        super::super::outbox::OPEN_LAPSED,
        "something nobody expected",
    ] {
        c.note_change((State::Delivering, 1), State::Failed, 1, 0, Some(e), 5);
    }
    c.note_change((State::Delivering, 1), State::Held, 1, 0, None, 5);
    assert_eq!(c.failed_total(), 4);
    for k in c.failed.keys() {
        assert!(CLASSES.contains(&k.as_str()), "{k}");
    }
    assert_eq!(c.failed["unknown_recipient"], 1);
    assert_eq!(c.failed["hub_unavailable"], 1);
    assert_eq!(c.failed["open_lapsed"], 1);
    assert_eq!(c.failed["other"], 1);
    assert_eq!(c.held, 1);
}

#[test]
fn relay_leases_count_the_ones_leased_again() {
    let mut c = Counters::starting(1);
    c.note_relay_lease(1);
    c.note_relay_lease(2);
    c.note_relay_lease(25);
    assert_eq!((c.relay_leases, c.relay_releases), (3, 2));
}

#[test]
fn counters_survive_a_restart_and_a_torn_file_starts_again() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("outbox.json");
    assert_eq!(read(&path, 7), Counters::starting(7));
    let mut c = Counters::starting(3);
    c.note_queued();
    c.note_change((State::Delivering, 1), State::Delivered, 1, 0, None, 9);
    write(&path, &serde_json::to_vec(&c).unwrap()).unwrap();
    assert_eq!(read(&path, 99), c);
    write(&path, b"{\"sinceMs\": 3, \"queu").unwrap();
    assert_eq!(read(&path, 42), Counters::starting(42));
}

#[test]
fn ls_shows_one_compact_line() {
    let mut c = Counters::starting(1);
    assert_eq!(ls_line(&c.status(0, None)), None);
    c.note_queued();
    c.note_queued();
    c.note_change((State::Delivering, 1), State::Delivered, 1, 0, None, 40);
    assert_eq!(
        ls_line(&c.status(1, Some(65_000))).as_deref(),
        Some(
            "sends: 2 queued, 1 delivered, 0 failed, 0 held, 0 retries, p50 ≤64 ms, \
                 p95 ≤64 ms, oldest waiting 65 s"
        )
    );
}
