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

/// A lane host, 2026-11-28: its chat folder refused every start while `machine pick`
/// saw room for 6 and kept sending starts there.
#[test]
fn a_refused_start_keeps_the_host_out_of_the_pick_until_a_start_works_or_the_cooldown_ends() {
    use crate::rpc::RpcError;
    let refused = RpcError::invalid_params(
        "the Cloud chat folder could not be made: /home/cmux/chats is not a directory",
    )
    .with_data(json!({"reason": "session_new.invalid_params"}));
    let why = refused_start(&refused).unwrap();
    assert!(why.starts_with("session_new.invalid_params: the Cloud chat folder"), "{why}");
    let mut f = Failures::default();
    f.record_refused("Lane-Host", &why, 1_000);
    let said = f.failure("lane-host", 61_000).unwrap();
    assert!(said.starts_with("start refused: session_new.invalid_params"), "{said}");
    assert!(said.contains("60s ago; tried again in 9 min"), "{said}");
    assert_eq!(Failures::parse(&f.to_bytes()), f, "the kind survives the file");
    // The bounded mark ends by itself.
    assert_eq!(f.failure("lane-host", 1_000 + COOLDOWN_MS), None);
    // A start there that worked forgets it at once.
    assert!(f.has("lane-host") && f.clear("lane-host"));
    assert_eq!(f.failure("lane-host", 2_000), None);
}

#[test]
fn only_the_hosts_own_refusals_count() {
    use crate::rpc::RpcError;
    let with = |reason: &str| RpcError::invalid_params("no").with_data(json!({"reason": reason}));
    for host_fault in [
        crate::server::remote_guard::CHAT_FOLDER_REASON,
        "session_new.internal",
        "session_new.not_found",
        "agent.exited",
        "peer_start_timeout",
    ] {
        assert!(refused_start(&with(host_fault)).is_some(), "{host_fault}");
    }
    assert!(refused_start(&RpcError::internal("boom")).is_some(), "no reason at all");
    for callers in [
        "remote.cwd_not_checkout",
        "remote.full_access_required",
        "policy.denied",
        "trust.pending",
        "peer.forward_refused",
        "peer_unreachable",
        crate::rpc::NO_PEER,
        "session_new.not_allowed",
        "message.too_large",
    ] {
        assert_eq!(refused_start(&with(callers)), None, "{callers}");
    }
    let full = RpcError::invalid_params("no").with_data(json!({"fullAccessRefusedBy": "h"}));
    assert_eq!(refused_start(&full), None);
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
