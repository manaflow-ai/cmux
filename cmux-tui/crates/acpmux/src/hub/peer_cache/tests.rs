use super::*;
use crate::peer::PeerNotice;

fn hub_at(dir: &std::path::Path) -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

fn test_hub() -> (Arc<Hub>, cmux_unix_socket::TestDir) {
    let dir = cmux_unix_socket::short_test_dir("acpmux-pc");
    (hub_at(dir.path()), dir)
}

#[tokio::test]
async fn an_empty_peer_outage_survives_a_daemon_restart() {
    let (hub, dir) = test_hub();
    let peer =
        crate::peer::Peer::new("absent", "invalid://peer", None, None, hub.peer_notices.clone());
    let down_since = now_ms() - 86_400_001;
    peer.seed_outage(Some(down_since));
    hub.peers.lock().unwrap().insert("absent".into(), peer.clone());
    let mut settled = peer.settled();
    let running = tokio::spawn(peer.clone().run());
    tokio::time::timeout(std::time::Duration::from_secs(5), settled.changed())
        .await
        .unwrap()
        .unwrap();
    peer.stop();
    running.await.unwrap();

    // The first daemon's shutdown seal: the journal's lock passes to the next one.
    hub.seal();
    let again = hub_at(dir.path());
    let restored = add_idle_peer(&again, "absent");
    again.load_peer_cache(&restored);
    assert_eq!(restored.link().down_since, Some(down_since));
    assert_eq!(restored.link().last_seen, None, "never reached is preserved");
    assert!(
        restored.link().next_retry_at.is_some_and(|at| at > now_ms()),
        "the remaining parked interval survives reboot"
    );
    assert!(again.remote_sessions().is_empty());
    let mut backoff = crate::peer_link::Backoff::default();
    assert_eq!(
        restored.link().retry_delay(&mut backoff, now_ms(), 0.0),
        std::time::Duration::from_secs(3_600)
    );
}

#[test]
fn older_peer_caches_have_no_proven_outage_age() {
    let saved: Saved = serde_json::from_value(json!({"lastSeen": 1, "sessions": []})).unwrap();
    assert_eq!(saved.down_since, None);
    assert_eq!(saved.next_retry_at, None);
}

/// A peer that is registered but never runs: its link stays down.
fn add_idle_peer(hub: &Hub, name: &str) -> Arc<crate::peer::Peer> {
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new(name, "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert(name.to_owned(), peer.clone());
    peer
}

fn remote(id: &str, name: &str) -> Value {
    json!({"sessionId": id, "name": name, "status": "idle", "turnCount": 1, "updatedAt": 5})
}

#[test]
fn a_down_peer_keeps_its_sessions_listed_as_stale_and_restarts_list_them_again() {
    let (hub, dir) = test_hub();
    let peer = add_idle_peer(&hub, "huge-blue");
    hub.apply_peer_notice(
        "huge-blue",
        peer.generation,
        PeerNotice::sessions_from_values(vec![remote("m1", "lane")]),
    );
    let fresh = hub.remote_sessions();
    assert_eq!(fresh.len(), 1);
    assert_eq!(fresh[0]["stale"], false, "{fresh:?}");
    assert_eq!(fresh[0]["peer"], "huge-blue");

    peer.seed_last_seen(Some(now_ms() - 40_000));
    hub.apply_peer_notice(
        "huge-blue",
        peer.generation,
        PeerNotice::Disconnected("connect timed out".into()),
    );
    let stale = hub.remote_sessions();
    assert_eq!(stale.len(), 1, "kept, not dropped");
    assert_eq!(stale[0]["status"], "unreachable", "what older clients read");
    assert_eq!(stale[0]["stale"], true);
    assert!(stale[0]["lastSeen"].is_u64(), "{stale:?}");
    assert_eq!(stale[0]["peerState"], "reconnecting");
    assert_eq!(hub.peers()[0]["sessions"], 1);
    assert_eq!(hub.peers()[0]["state"], "reconnecting");
    assert!(dir.path().join("peers/huge-blue.json").is_file());

    // This daemon restarts while the peer is still down (its shutdown seal passes the
    // journal's lock to the next one).
    hub.seal();
    let again = hub_at(dir.path());
    let peer = add_idle_peer(&again, "huge-blue");
    again.load_peer_cache(&peer);
    let listed = again.remote_sessions();
    assert_eq!(listed.len(), 1, "{listed:?}");
    assert_eq!(listed[0]["name"], "huge-blue/lane");
    assert_eq!(listed[0]["stale"], true);
    assert_eq!(peer.state(), crate::peer_link::PeerState::Reconnecting);

    // Its first handshake replaces the saved rows with fresh ones.
    again.apply_peer_notice(
        "huge-blue",
        peer.generation,
        PeerNotice::sessions_from_values(vec![remote("m1", "lane")]),
    );
    let back = again.remote_sessions();
    assert_eq!(back[0]["stale"], false, "{back:?}");
    assert_eq!(back[0]["status"], "idle");

    again.forget_peer_cache("huge-blue");
    assert!(!dir.path().join("peers/huge-blue.json").exists());
    assert!(!dir.path().join("peers/huge-blue.journal").exists());
}

/// A peer's list is input from another machine: a row that is not an object (a buggy or
/// hostile peer) is skipped, and the daemon keeps the peer's good rows. Before, the row
/// reached `views::decide`, whose `summary["indicator"] = ..` panics on a non-object, and
/// the peer-notice loop runs under `supervise::once`: the daemon stopped, then stopped
/// again each time the peer reconnected with the same list.
#[test]
fn a_peer_row_that_is_not_an_object_is_skipped_not_a_panic() {
    let (hub, _dir) = test_hub();
    let peer = add_idle_peer(&hub, "huge-blue");
    for row in [json!("x"), json!(7), json!([1]), json!(true), Value::Null] {
        let kept = Hub::remote_summary("huge-blue", row.clone());
        assert_eq!(kept, row, "a row that is not an object is not changed");
    }
    hub.apply_peer_notice(
        "huge-blue",
        peer.generation,
        PeerNotice::sessions_from_values(vec![
            json!("x"),
            json!(7),
            json!([1]),
            remote("m1", "lane"),
        ]),
    );
    let listed = hub.remote_sessions();
    assert_eq!(listed.len(), 1, "{listed:?}");
    assert_eq!(listed[0]["name"], "huge-blue/lane");
}

/// A cache an older build saved can hold a peer's own display line on a pending ask: the
/// row a restart lists carries none (`drop_display_lines`), the tool's own input kept.
#[test]
fn a_saved_rows_display_line_is_dropped_when_loaded() {
    let (hub, dir) = test_hub();
    let mut row = Hub::remote_summary("huge-blue", remote("m1", "lane"));
    row["pending"] = json!([{"permissionId": "p1", "request": {"toolCall": {
            "rawInput": {"_meta": {"acpmux": {"display": {"headline": "the tool's own input"}}}},
            "_meta": {"acpmux": {"display": {"headline": "Leo wants to say hi"}}}}}}]);
    std::fs::create_dir_all(dir.path().join("peers")).unwrap();
    let saved = json!({"lastSeen": now_ms() - 40_000, "sessions": [row]});
    std::fs::write(dir.path().join("peers/huge-blue.json"), saved.to_string()).unwrap();
    let peer = add_idle_peer(&hub, "huge-blue");
    hub.load_peer_cache(&peer);
    let listed = Value::from(hub.remote_sessions());
    assert_eq!(listed[0]["name"], "huge-blue/lane", "{listed}");
    assert!(!listed.to_string().contains("Leo wants to say hi"), "{listed}");
    assert!(listed.to_string().contains("the tool's own input"), "{listed}");
}

#[tokio::test]
async fn a_request_for_a_down_peers_session_is_peer_unreachable_not_no_session() {
    let (hub, _dir) = test_hub();
    let peer = add_idle_peer(&hub, "huge-blue");
    *peer.last_error.lock().unwrap() = Some("connect timed out".into());
    peer.seed_last_seen(Some(now_ms() - 40_000));
    hub.apply_peer_notice(
        "huge-blue",
        peer.generation,
        PeerNotice::sessions_from_values(vec![remote("m1", "lane")]),
    );
    hub.apply_peer_notice(
        "huge-blue",
        peer.generation,
        PeerNotice::Disconnected("connect timed out".into()),
    );

    let (found, id, _) = hub.resolve_remote("huge-blue/lane").expect("still listed");
    let e = found.request(method::SESSION_PROMPT, json!({"sessionId": id})).await.unwrap_err();
    assert!(
        e.message.starts_with("peer_unreachable: huge-blue (reconnecting, last seen 4"),
        "{}",
        e.message
    );
    assert!(e.message.contains(": connect timed out); the request was not sent"), "{}", e.message);
    assert_eq!(e.data.as_ref().unwrap()["reason"], "peer_unreachable");

    // A name the peer never listed here: still the peer, not no_session.
    let e = hub.peer_down_for("huge-blue/other").expect("peer is down");
    assert!(e.message.starts_with("peer_unreachable: huge-blue"), "{}", e.message);
    assert!(hub.peer_down_for("nopeer/lane").is_none());
    assert!(hub.peer_down_for("lane").is_none());
}

#[test]
fn a_stale_row_is_unreachable_with_no_stuck_details() {
    let mut row = json!({"sessionId": "m1", "status": "ready", "state": "stuck",
            "stuckReason": "capacity", "stuckSince": 7, "stuckError": "HTTP 503"});
    assert!(mark_stale(&mut row, Some(9)));
    assert_eq!(row["state"], "unreachable", "{row}");
    for key in ["stuckReason", "stuckSince", "stuckError"] {
        assert!(row[key].is_null(), "{key}: {row}");
    }
}

#[test]
fn a_burst_of_session_lists_is_coalesced_to_throttled_cache_writes() {
    let (hub, _dir) = test_hub();
    let peer = add_idle_peer(&hub, "builder");
    hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
    hub.cache_test_writes.store(0, std::sync::atomic::Ordering::SeqCst);
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::sessions_from_values(vec![remote("m1", "lane")]),
    );
    for at in 0..32 {
        let mut row = remote("m1", "lane");
        row["updatedAt"] = json!(at + 10);
        hub.apply_peer_notice(
            "builder",
            peer.generation,
            PeerNotice::sessions_from_values(vec![row]),
        );
    }
    let writes = hub.cache_test_writes.load(std::sync::atomic::Ordering::SeqCst);
    assert!(writes < 32, "writes={writes}");
}

#[test]
fn a_burst_has_at_most_one_pending_cache_writer_per_peer() {
    let (hub, _dir) = test_hub();
    let peer = add_idle_peer(&hub, "builder");
    hub.cache_test_writes.store(0, std::sync::atomic::Ordering::SeqCst);
    hub.cache_test_write_started.store(false, std::sync::atomic::Ordering::SeqCst);
    hub.cache_test_write_delay_ms.store(200, std::sync::atomic::Ordering::SeqCst);
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::sessions_from_values(vec![remote("m1", "lane")]),
    );
    for _ in 0..100_000 {
        if hub.cache_test_write_started.load(std::sync::atomic::Ordering::SeqCst) {
            break;
        }
        std::thread::yield_now();
    }
    for at in 0..32 {
        let mut row = remote("m1", "lane");
        row["updatedAt"] = json!(at + 10);
        hub.apply_peer_notice(
            "builder",
            peer.generation,
            PeerNotice::sessions_from_values(vec![row]),
        );
    }
    assert_eq!(hub.cache_test_writes.load(std::sync::atomic::Ordering::SeqCst), 1);
    hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
    for _ in 0..100_000 {
        if !peer.cache_write_pending.load(std::sync::atomic::Ordering::SeqCst) {
            break;
        }
        std::thread::yield_now();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_immediate_stop_flushes_a_notice_before_its_worker_starts() {
    let (hub, dir) = test_hub();
    let peer = add_idle_peer(&hub, "builder");
    hub.cache_test_write_delay_ms.store(200, std::sync::atomic::Ordering::SeqCst);
    let mut changed = remote("m1", "lane");
    changed["status"] = json!("running");
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::sessions_from_values(vec![changed]),
    );
    assert!(peer.cache_is_dirty());
    // This is the notice loop's shutdown flush: it only visits dirty peers, then waits for
    // the ordered writer before returning from shutdown.
    if peer.cache_is_dirty() {
        hub.save_peer_cache("builder", peer.generation, true);
    }
    hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
    let saved = disk::saved_json(&dir.path().join("peers"), "builder");
    assert_eq!(saved["sessions"][0]["status"], "running");
}

#[test]
fn a_notice_during_a_write_remains_dirty_for_the_stop_flush() {
    let (hub, dir) = test_hub();
    let peer = add_idle_peer(&hub, "builder");
    hub.cache_test_write_started.store(false, std::sync::atomic::Ordering::SeqCst);
    hub.cache_test_write_delay_ms.store(200, std::sync::atomic::Ordering::SeqCst);
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::sessions_from_values(vec![remote("old", "lane")]),
    );
    for _ in 0..100_000 {
        if hub.cache_test_write_started.load(std::sync::atomic::Ordering::SeqCst) {
            break;
        }
        std::thread::yield_now();
    }
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::sessions_from_values(vec![remote("new", "lane")]),
    );
    hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
    for _ in 0..100_000 {
        if !peer.cache_write_pending.load(std::sync::atomic::Ordering::SeqCst) {
            break;
        }
        std::thread::yield_now();
    }
    assert!(peer.cache_is_dirty());
    if peer.cache_is_dirty() {
        hub.save_peer_cache("builder", peer.generation, true);
    }
    let saved = disk::saved_json(&dir.path().join("peers"), "builder");
    assert_eq!(saved["sessions"][0]["sessionId"], "new");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_notice_between_write_and_flush_publish_remains_dirty() {
    let (hub, dir) = test_hub();
    let peer = add_idle_peer(&hub, "builder");
    let (entered_tx, entered_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    *hub.cache_test_flush_pause.lock().unwrap() = Some((entered_tx, release_rx));
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::sessions_from_values(vec![remote("old", "lane")]),
    );
    entered_rx
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("cache worker never reached the flush publication");
    let projection = super::peers::PeerNoticeProjectionHook::new();
    *hub.peer_notice_projection_hook.lock().unwrap() = Some(projection.clone());
    let (done_tx, done_rx) = std::sync::mpsc::channel();
    let notice = {
        let hub = hub.clone();
        let generation = peer.generation;
        std::thread::spawn(move || {
            hub.apply_peer_notice(
                "builder",
                generation,
                PeerNotice::sessions_from_values(vec![remote("new", "lane")]),
            );
            done_tx.send(()).unwrap();
        })
    };
    assert!(
        projection.wait_reached_timeout(std::time::Duration::from_secs(2)),
        "session notice never reached its projection fence"
    );
    release_tx.send(()).unwrap();
    projection.release();
    done_rx
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("interleaved session notice did not finish");
    notice.join().unwrap();
    for _ in 0..100_000 {
        if !peer.cache_write_pending.load(std::sync::atomic::Ordering::Acquire) {
            break;
        }
        std::thread::yield_now();
    }
    assert!(peer.cache_is_dirty(), "the interleaved notice lost its dirty marker");
    hub.save_peer_cache("builder", peer.generation, true);
    let saved = disk::saved_json(&dir.path().join("peers"), "builder");
    assert_eq!(saved["sessions"][0]["sessionId"], "new");
}

#[test]
fn disconnect_forces_the_latest_dirty_rows_to_disk() {
    let (hub, dir) = test_hub();
    let peer = add_idle_peer(&hub, "builder");
    hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
    hub.cache_test_writes.store(0, std::sync::atomic::Ordering::SeqCst);
    hub.cache_test_write_started.store(false, std::sync::atomic::Ordering::SeqCst);
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::sessions_from_values(vec![remote("m1", "lane")]),
    );
    for _ in 0..100_000 {
        if hub.cache_test_write_started.load(std::sync::atomic::Ordering::Acquire)
            && !peer.cache_write_pending.load(std::sync::atomic::Ordering::Acquire)
        {
            break;
        }
        std::thread::yield_now();
    }
    assert!(hub.cache_test_write_started.load(std::sync::atomic::Ordering::Acquire));
    assert!(!peer.cache_write_pending.load(std::sync::atomic::Ordering::Acquire));
    let mut changed = remote("m1", "lane");
    changed["status"] = json!("running");
    changed["turnCount"] = json!(7);
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::sessions_from_values(vec![changed]),
    );
    hub.apply_peer_notice("builder", peer.generation, PeerNotice::Disconnected("down".into()));
    // The throttled change reached disk. Its stale marking need not: a load marks every row
    // stale itself (`peer_cache_disk::still_on_disk`).
    let saved = disk::saved_json(&dir.path().join("peers"), "builder");
    assert_eq!(saved["sessions"][0]["turnCount"], 7, "{saved}");
    assert!(hub.cache_test_writes.load(std::sync::atomic::Ordering::SeqCst) >= 2);
    let listed = hub.remote_sessions();
    hub.seal();
    let again = hub_at(dir.path());
    let restored = add_idle_peer(&again, "builder");
    again.load_peer_cache(&restored);
    let back = again.remote_sessions();
    assert_eq!(back[0]["status"], "unreachable", "{back:?}");
    assert_eq!(back[0]["turnCount"], 7, "{back:?}");
    assert_eq!(back[0]["stale"], listed[0]["stale"]);
}

#[test]
fn a_stale_generation_cannot_replace_the_current_peer_rows() {
    let (hub, _dir) = test_hub();
    let old = add_idle_peer(&hub, "builder");
    hub.apply_peer_notice(
        "builder",
        old.generation,
        PeerNotice::sessions_from_values(vec![remote("old", "old-lane")]),
    );
    let replacement = add_idle_peer(&hub, "builder");
    let stale = remote("stale", "stale-lane");
    hub.apply_peer_notice("builder", old.generation, PeerNotice::sessions_from_values(vec![stale]));
    let rows = hub.remote_sessions();
    assert_eq!(replacement.generation, hub.peer("builder").unwrap().generation);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["sessionId"], "old");
}

#[test]
fn a_newer_snapshot_wins_when_an_older_write_is_still_serializing() {
    let (hub, dir) = test_hub();
    let peer = add_idle_peer(&hub, "builder");
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::sessions_from_values(vec![remote("old", "lane")]),
    );
    hub.cache_test_writes.store(0, std::sync::atomic::Ordering::SeqCst);
    hub.cache_test_write_started.store(false, std::sync::atomic::Ordering::SeqCst);
    hub.cache_test_write_delay_ms.store(100, std::sync::atomic::Ordering::SeqCst);
    let saving = {
        let hub = hub.clone();
        let generation = peer.generation;
        std::thread::spawn(move || hub.save_peer_cache("builder", generation, true))
    };
    for _ in 0..100_000 {
        if hub.cache_test_write_started.load(std::sync::atomic::Ordering::SeqCst) {
            break;
        }
        std::thread::yield_now();
    }
    let mut newer = remote("new", "lane");
    newer["updatedAt"] = json!(99);
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::sessions_from_values(vec![newer]),
    );
    hub.save_peer_cache("builder", peer.generation, true);
    saving.join().unwrap();
    hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
    let saved = disk::saved_json(&dir.path().join("peers"), "builder");
    assert_eq!(saved["sessions"][0]["sessionId"], "new");
}

#[test]
fn a_purge_after_an_inflight_snapshot_stays_purged_on_disk() {
    let (hub, dir) = test_hub();
    let peer = add_idle_peer(&hub, "builder");
    hub.cache_test_write_started.store(false, std::sync::atomic::Ordering::SeqCst);
    hub.cache_test_write_delay_ms.store(200, std::sync::atomic::Ordering::SeqCst);
    let mut listed = remote("m1", "lane");
    listed["createdAt"] = json!(5);
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::sessions_from_values(vec![listed]),
    );
    for _ in 0..100_000 {
        if hub.cache_test_write_started.load(std::sync::atomic::Ordering::Acquire) {
            break;
        }
        std::thread::yield_now();
    }
    assert!(hub.cache_test_write_started.load(std::sync::atomic::Ordering::Acquire));

    let purging = {
        let hub = hub.clone();
        let generation = peer.generation;
        std::thread::spawn(move || hub.forget_remote(("builder", generation), "m1", Some(5)))
    };
    purging.join().unwrap();
    hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
    // The store keeps an exclusive journal lock for the hub lifetime. Release it before
    // constructing the restart fixture that reloads the cache.
    drop(hub);

    let again = hub_at(dir.path());
    let restored = add_idle_peer(&again, "builder");
    again.load_peer_cache(&restored);
    assert!(again.remote_sessions().is_empty(), "purged row was restored from cache");
}

#[test]
fn a_failed_forced_save_remains_dirty_for_retry() {
    let (hub, dir) = test_hub();
    let peer = add_idle_peer(&hub, "builder");
    let peers_dir = dir.path().join("peers");
    std::fs::create_dir_all(&peers_dir).unwrap();
    std::fs::remove_dir(&peers_dir).unwrap();
    std::fs::write(&peers_dir, b"blocked").unwrap();

    hub.save_peer_cache("builder", peer.generation, true);
    assert!(peer.cache_is_dirty(), "a failed forced save was marked flushed");

    std::fs::remove_file(&peers_dir).unwrap();
    hub.save_peer_cache("builder", peer.generation, true);
    assert!(!peer.cache_is_dirty(), "a successful retry stayed dirty");
}

#[test]
fn one_peer_cache_write_does_not_block_another_peer() {
    let (hub, _dir) = test_hub();
    let slow = add_idle_peer(&hub, "slow");
    let fast = add_idle_peer(&hub, "fast");
    for (name, peer) in [("slow", &slow), ("fast", &fast)] {
        hub.apply_peer_notice(
            name,
            peer.generation,
            PeerNotice::sessions_from_values(vec![remote("m1", name)]),
        );
    }
    hub.cache_test_write_started.store(false, std::sync::atomic::Ordering::SeqCst);
    hub.cache_test_write_delay_ms.store(200, std::sync::atomic::Ordering::SeqCst);
    *hub.cache_test_delay_peer.lock().unwrap() = Some("slow".into());
    let saving = {
        let hub = hub.clone();
        let generation = slow.generation;
        std::thread::spawn(move || hub.save_peer_cache("slow", generation, true))
    };
    for _ in 0..100_000 {
        if hub.cache_test_write_started.load(std::sync::atomic::Ordering::SeqCst) {
            break;
        }
        std::thread::yield_now();
    }
    let started = std::time::Instant::now();
    hub.save_peer_cache("fast", fast.generation, true);
    let elapsed = started.elapsed();
    saving.join().unwrap();
    hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
    *hub.cache_test_delay_peer.lock().unwrap() = None;
    assert!(elapsed < std::time::Duration::from_millis(150), "fast save waited {elapsed:?}");
}

#[test]
fn a_peer_notice_does_not_wait_for_another_peers_cache_write() {
    let (hub, _dir) = test_hub();
    let slow = add_idle_peer(&hub, "slow");
    let fast = add_idle_peer(&hub, "fast");
    hub.apply_peer_notice(
        "slow",
        slow.generation,
        PeerNotice::sessions_from_values(vec![remote("m1", "slow")]),
    );
    hub.apply_peer_notice(
        "fast",
        fast.generation,
        PeerNotice::sessions_from_values(vec![remote("m1", "fast")]),
    );
    hub.cache_test_write_started.store(false, std::sync::atomic::Ordering::SeqCst);
    hub.cache_test_write_delay_ms.store(200, std::sync::atomic::Ordering::SeqCst);
    *hub.cache_test_delay_peer.lock().unwrap() = Some("slow".into());
    let mut changed = remote("m1", "slow");
    changed["updatedAt"] = json!(99);
    hub.apply_peer_notice("slow", slow.generation, PeerNotice::sessions_from_values(vec![changed]));
    for _ in 0..100_000 {
        if hub.cache_test_write_started.load(std::sync::atomic::Ordering::SeqCst) {
            break;
        }
        std::thread::yield_now();
    }
    let started = std::time::Instant::now();
    hub.apply_peer_notice(
        "fast",
        fast.generation,
        PeerNotice::sessions_from_values(vec![remote("m1", "fast")]),
    );
    assert!(started.elapsed() < std::time::Duration::from_millis(150));
    hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
    *hub.cache_test_delay_peer.lock().unwrap() = None;
}

#[test]
fn a_cache_worker_and_full_list_notice_complete_without_lock_order_deadlock() {
    let (hub, _dir) = test_hub();
    let peer = add_idle_peer(&hub, "builder");
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::sessions_from_values(vec![remote("m1", "builder")]),
    );
    hub.cache_test_write_started.store(false, std::sync::atomic::Ordering::SeqCst);
    hub.cache_test_write_delay_ms.store(100, std::sync::atomic::Ordering::SeqCst);
    let saving = {
        let hub = hub.clone();
        let generation = peer.generation;
        std::thread::spawn(move || hub.save_peer_cache("builder", generation, true))
    };
    for _ in 0..100_000 {
        if hub.cache_test_write_started.load(std::sync::atomic::Ordering::Acquire) {
            break;
        }
        std::thread::yield_now();
    }
    let (done_tx, done_rx) = std::sync::mpsc::channel();
    let applying = {
        let hub = hub.clone();
        let generation = peer.generation;
        std::thread::spawn(move || {
            hub.apply_peer_notice(
                "builder",
                generation,
                PeerNotice::sessions_from_values(vec![remote("m1", "builder")]),
            );
            done_tx.send(()).unwrap();
        })
    };
    done_rx
        .recv_timeout(std::time::Duration::from_secs(1))
        .expect("cache worker and full-list notice deadlocked on hub locks");
    applying.join().unwrap();
    saving.join().unwrap();
    hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
}

#[test]
fn a_session_changed_receipt_notice_finishes_without_relocking_peers() {
    let (hub, _dir) = test_hub();
    let peer = add_idle_peer(&hub, "builder");
    let mut session = remote("m1", "lane");
    session["sessionReceipt"] =
        crate::session_identity::SessionReceipt::new("builder", "m1", None, 1).to_value();
    let (done_tx, done_rx) = std::sync::mpsc::channel();
    let applying = {
        let hub = hub.clone();
        let generation = peer.generation;
        std::thread::spawn(move || {
            hub.apply_peer_notice(
                "builder",
                generation,
                PeerNotice::SessionChanged { session, kind: "status".into(), seq: 1 },
            );
            done_tx.send(()).unwrap();
        })
    };
    done_rx
        .recv_timeout(std::time::Duration::from_secs(1))
        .expect("session_changed receipt notice re-locked the peers mutex");
    applying.join().unwrap();
}

#[test]
fn held_ask_release_after_sessions_does_not_reenter_a_notice_lock() {
    let (hub, _dir) = test_hub();
    let peer = add_idle_peer(&hub, "builder");
    hub.held_peer_asks.hold(
        "builder",
        peer.generation,
        "m1",
        PeerNotice::SessionChanged { session: remote("m1", "lane"), kind: "status".into(), seq: 1 },
    );
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::sessions_from_values(vec![remote("m1", "lane")]),
    );
    assert_eq!(hub.remote_sessions().len(), 1);
    hub.held_peer_asks.hold(
        "builder",
        peer.generation,
        "m2",
        PeerNotice::SessionChanged {
            session: remote("m2", "lane-2"),
            kind: "status".into(),
            seq: 2,
        },
    );
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::SessionChanged {
            session: remote("m2", "lane-2"),
            kind: "status".into(),
            seq: 3,
        },
    );
    assert_eq!(hub.remote_sessions().len(), 2);
}

#[test]
fn removing_a_peer_cannot_be_followed_by_its_in_flight_cache_write() {
    let (hub, dir) = test_hub();
    let peer = add_idle_peer(&hub, "builder");
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::sessions_from_values(vec![remote("m1", "lane")]),
    );
    hub.cache_test_write_started.store(false, std::sync::atomic::Ordering::SeqCst);
    hub.cache_test_write_delay_ms.store(100, std::sync::atomic::Ordering::SeqCst);
    let saving = {
        let hub = hub.clone();
        let generation = peer.generation;
        std::thread::spawn(move || hub.save_peer_cache("builder", generation, true))
    };
    for _ in 0..100_000 {
        if hub.cache_test_write_started.load(std::sync::atomic::Ordering::SeqCst) {
            break;
        }
        std::thread::yield_now();
    }
    let runtime = tokio::runtime::Runtime::new().unwrap();
    runtime.block_on(hub.remove_peer("builder")).unwrap();
    saving.join().unwrap();
    hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
    assert!(!dir.path().join("peers/builder.json").exists());
    assert!(!dir.path().join("peers/builder.journal").exists());
}

/// The status of the first session saved for `peer`, as on disk now.
fn saved_status(dir: &std::path::Path, peer: &str) -> Value {
    disk::saved_json(&dir.join("peers"), peer)["sessions"][0]["status"].clone()
}

/// A row change inside the save interval is put off, and the notice loop writes it when
/// the interval ends (the old 30 s tick wrote it up to 2 intervals later). Once nothing is
/// dirty, nothing more is written: the loop sets no timer then (the idle daemon test
/// `acpmux_daemon_idle_has_no_periodic_wakeups` shows it takes no wake).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_put_off_cache_save_is_written_when_its_interval_ends_and_nothing_while_clean() {
    let every = std::time::Duration::from_millis(400);
    let (hub, dir) = test_hub();
    hub.cache_test_save_every_ms.store(400, std::sync::atomic::Ordering::SeqCst);
    let peer = add_idle_peer(&hub, "builder");
    let settled = || {
        !peer.cache_is_dirty()
            && !peer.cache_write_pending.load(std::sync::atomic::Ordering::SeqCst)
    };
    let until = |what: &'static str, done: &dyn Fn() -> bool, within: std::time::Duration| {
        let deadline = std::time::Instant::now() + within;
        while !done() {
            assert!(std::time::Instant::now() < deadline, "never: {what}");
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    };
    // The first list is saved at once.
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::sessions_from_values(vec![remote("m1", "lane")]),
    );
    until("the first list is saved", &settled, std::time::Duration::from_secs(10));
    assert_eq!(saved_status(dir.path(), "builder"), "idle");
    // A change right after it is put off.
    let mut changed = remote("m1", "lane");
    changed["status"] = json!("running");
    let changed_at = std::time::Instant::now();
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::sessions_from_values(vec![changed]),
    );
    assert!(peer.cache_is_dirty(), "the change was not put off");
    until(
        "the put-off change is saved",
        &|| saved_status(dir.path(), "builder") == "running",
        std::time::Duration::from_secs(10),
    );
    let took = changed_at.elapsed();
    // Its interval, and a margin for a loaded host; the old tick could take two.
    assert!(took < every * 2, "the put-off save took {took:?} (interval {every:?})");
    until("the save settles", &settled, std::time::Duration::from_secs(10));
    // Clean: no save over many intervals.
    let writes = hub.cache_test_writes.load(std::sync::atomic::Ordering::SeqCst);
    std::thread::sleep(every * 5);
    assert_eq!(
        hub.cache_test_writes.load(std::sync::atomic::Ordering::SeqCst),
        writes,
        "a clean cache was written again"
    );
}

/// A save that fails (here the cache folder is a file) leaves the cache dirty, and the
/// notice loop tries it again one interval later, as the 30 s tick did, until it is written.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_failed_cache_save_is_tried_again_after_its_interval() {
    let (hub, dir) = test_hub();
    hub.cache_test_save_every_ms.store(400, std::sync::atomic::Ordering::SeqCst);
    let peers = dir.path().join("peers");
    let _ = std::fs::remove_dir_all(&peers);
    std::fs::write(&peers, b"not a folder").unwrap();
    let peer = add_idle_peer(&hub, "builder");
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::sessions_from_values(vec![remote("m1", "lane")]),
    );
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while hub.cache_test_writes.load(std::sync::atomic::Ordering::SeqCst) == 0 {
        assert!(std::time::Instant::now() < deadline, "the first save was never tried");
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    while peer.cache_write_pending.load(std::sync::atomic::Ordering::SeqCst) {
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert!(peer.cache_is_dirty(), "a failed save marked the cache clean");
    std::fs::remove_file(&peers).unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while saved_status(dir.path(), "builder") != "idle" {
        assert!(std::time::Instant::now() < deadline, "the failed save was never tried again");
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}
