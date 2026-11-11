use super::*;
use serde_json::json;

/// Reviews of #24797 at d703168 and 828f855: a reload applied the lending it read to
/// whatever peer had the name by then, and a reload whose file read came before a
/// `peer_add` brought back what that add took away.
#[tokio::test]
async fn a_reload_lends_only_to_the_machine_and_the_add_it_read() {
    use crate::config::PeerConfig;
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let url = "ws://127.0.0.1:9/m";
    let lent = |url: &str| PeerConfig {
        link_host: None,
        wireguard: None,
        url: url.into(),
        token: None,
        peer_token: None,
        vm_boundary: true,
        github_broker: true,
    };
    let file = |pc: PeerConfig| std::collections::BTreeMap::from([("m".to_owned(), pc)]);
    let peer = || hub.peers.lock().unwrap().get("m").cloned().unwrap();
    let reload = |next: std::collections::BTreeMap<String, PeerConfig>, read: u64| {
        let hub = &hub;
        async move {
            let mut current = hub.config.write().await;
            hub.reload_saved_peers(&mut current, &next, read);
        }
    };
    hub.add_peer_lending("m", url, None, None, Some(false), false).await.unwrap();

    // The file names `m` at another url: neither the saved peer nor the running one lends.
    let read = hub.peer_read_gen().await;
    reload(file(lent("ws://127.0.0.1:9/other")), read).await;
    assert!(!peer().github_broker() && !peer().vm_boundary(), "read for another machine");

    // The reload read the file, then `peer_add` took lending away (same url): it holds.
    let read = hub.peer_read_gen().await;
    hub.add_peer_lending("m", url, None, None, Some(false), false).await.unwrap();
    reload(file(lent(url)), read).await;
    assert!(!peer().github_broker(), "a later add takes it away for good");
    assert!(!hub.config.read().await.peers["m"].github_broker);

    // A reload with nothing between its read and its apply turns it on.
    let read = hub.peer_read_gen().await;
    reload(file(lent(url)), read).await;
    assert!(peer().github_broker() && peer().vm_boundary(), "read for this machine");
    assert!(hub.config.read().await.peers["m"].github_broker);
    peer().stop();
}

/// A wait that runs out before the connect attempt settles says so, with the peer as it is
/// then, rather than answering as if it had settled.
#[tokio::test]
async fn a_wait_that_runs_out_says_it_did_not_settle() {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.add_peer_lending("m", "ws://127.0.0.1:9/m", None, None, Some(false), false).await.unwrap();
    // An attempt that never settles.
    let (_never, mut settled) = tokio::sync::watch::channel(0);
    let budget = std::time::Duration::from_millis(50);
    let waited = hub.wait_for_peer("m", &mut settled, budget).await;
    assert_eq!(waited["settled"], false, "{waited}");
    // One whose peer is gone (its sender dropped) did not settle either.
    let (gone, mut dropped) = tokio::sync::watch::channel(0);
    drop(gone);
    let quick = hub.wait_for_peer("m", &mut dropped, budget).await;
    assert_eq!(quick["settled"], false, "{quick}");
    assert_eq!(quick["stopped"], true, "a stopped peer read as a wait that ran out: {quick}");
    assert!(waited.get("stopped").is_none(), "{waited}");
    assert!(waited["waitedMs"].as_u64().unwrap() >= 50, "{waited}");
    assert_eq!(waited["peer"]["name"], "m", "{waited}");
    assert!(waited["peer"]["state"].is_string(), "{waited}");
    hub.peers.lock().unwrap().get("m").cloned().unwrap().stop();
}

/// Review of #24797 at b93f3a3: a reload read the add count outside the config lock (so
/// mid-add, before its save), and a reconnect started a peer from a config read it had let
/// go. Both now wait for a change in progress and see what it saved.
#[tokio::test]
async fn a_reload_or_reconnect_waits_for_a_peer_change_in_progress() {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let url = "ws://127.0.0.1:9/m";
    hub.add_peer_lending("m", url, None, None, Some(true), false).await.unwrap();
    let wait = std::time::Duration::from_millis(200);

    // A change in progress: counted, not yet saved (what `peer_add` does under the lock).
    let mut held = hub.config.write().await;
    hub.peer_config_gen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let read = tokio::time::timeout(wait, hub.peer_read_gen()).await;
    assert!(read.is_err(), "the count is not read mid-change");
    let reconnect = tokio::time::timeout(wait, hub.reconnect_peer("m", false)).await;
    assert!(reconnect.is_err(), "no peer starts from a config mid-change");
    held.peers.get_mut("m").unwrap().github_broker = false;
    drop(held);

    hub.reconnect_peer("m", false).await.unwrap();
    let peer = hub.peers.lock().unwrap().get("m").cloned().unwrap();
    assert!(!peer.github_broker(), "the reconnect started what the change saved");
    peer.stop();
}

/// Review of #24797 at 30e24d1: a removal stopped the live peer before it took the config
/// lock, so a reconnect holding that lock started it again, still lending GitHub, after the
/// removal said it was gone. The removal now waits for the reconnect, and its stop is last.
#[tokio::test]
async fn a_removed_peer_is_never_started_again_by_a_reconnect_in_progress() {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.add_peer_lending("m", "ws://127.0.0.1:9/m", None, None, Some(true), false).await.unwrap();

    // A reconnect in progress: it read the config and holds it through its start.
    let held = hub.config.read().await;
    let removing = {
        let hub = hub.clone();
        tokio::spawn(async move { hub.remove_peer("m").await })
    };
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    assert!(!removing.is_finished(), "the removal waits for the reconnect");
    assert!(hub.peers.lock().unwrap().contains_key("m"), "and stops nothing before it");
    let restarted = hub.start_peer("m", &held.peers["m"]);
    drop((held, restarted));

    removing.await.unwrap().unwrap();
    assert!(!hub.peers.lock().unwrap().contains_key("m"), "no peer outlives its removal");
    assert!(!hub.config.read().await.peers.contains_key("m"));
}

#[test]
fn remote_summary_qualifies_the_mux_id_without_changing_legacy_name() {
    let summary = Hub::remote_summary(
        "builder",
        json!({
            "sessionId": "mux-1",
            "agentSessionId": "agent-1",
            "name": "review",
            "sessionReceipt": {
                "hostId": "local",
                "muxSessionId": "mux-1",
                "agentSessionId": "agent-1",
                "generation": 23,
            },
        }),
    );
    assert_eq!(summary["name"], "builder/review");
    assert_eq!(summary["qualifiedSessionId"], "builder/mux-1");
    assert_eq!(summary["sessionReceipt"]["hostId"], "builder");
    assert_eq!(summary["sessionReceipt"]["generation"], 23);
}

#[test]
fn compact_remote_change_keeps_the_cached_tool_inventory() {
    let previous = json!({
        "sessionId": "mux-1",
        "tools": [{"id": "mcp:github"}],
        "toolsMutable": true,
    });
    let compact = json!({"sessionId": "mux-1", "status": "running"});
    let retained = Hub::retain_summary_tools(compact, Some(&previous));
    assert_eq!(retained["tools"], previous["tools"]);
    assert_eq!(retained["toolsMutable"], true);
}

/// hq#2509: a peer from before the lane's step and title sends a lane without them;
/// this daemon decides the lane again so the peer's lanes show a masked step.
#[test]
fn a_lane_from_an_older_peer_is_decided_again_with_its_masked_step() {
    let token = format!("gh{}_{}", "p", "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234");
    let summary = Hub::remote_summary(
        "builder",
        json!({
            "sessionId": "mux-1",
            "name": "review",
            "status": "running",
            "indicator": "working",
            "turnCount": 1,
            "updatedAt": 9,
            "turn": {"prompt": format!("push {token}"), "startedAt": 5},
            "lane": {"state": "working", "since": 5, "error": null},
        }),
    );
    assert_eq!(summary["lane"]["step"], "push [GitHub Personal Access Token]", "{summary}");
}

#[test]
fn an_older_peers_agent_lane_requires_open_even_with_a_title() {
    let summary = Hub::remote_summary(
        "builder",
        json!({
            "sessionId": "child", "status": "running", "parent": "coordinator",
            "indicator": "working", "lane": {"state": "working", "title": "Review"}
        }),
    );
    assert_eq!(summary["lane"]["requiresOpen"], true);
}

#[test]
fn streamed_remote_rows_release_the_lock_and_keep_the_captured_versions() {
    let hub =
        Hub::new(crate::config::Config::default(), Box::new(crate::store::MemoryStore::default()));
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new("builder", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("builder".into(), peer.clone());
    let rows = (0..3).map(|i| json!({"sessionId": format!("r{i}"), "status": "closed", "updatedAt": i, "tools": [{"id": "kept"}]})).collect();
    hub.apply_peer_notice("builder", peer.generation, crate::peer::PeerNotice::Sessions(rows));
    let expected = hub.all_session_summaries();
    let mut actual = Vec::new();
    hub.visit_session_summaries(true, |row| {
        // A writer can remove rows during serialization without changing this snapshot.
        let mut rows =
            hub.remote_sessions.try_write().expect("visitor must not hold the rows writer lock");
        let captured: Vec<_> = rows.iter().map(|(id, row)| (id.clone(), row.clone())).collect();
        for (id, captured) in captured {
            let writes = rows.writes;
            let removed = rows.take(&id).unwrap();
            assert!(Arc::ptr_eq(&removed, &captured), "discard must not deep-clone a row");
            assert_eq!(rows.writes, writes + 1);
            assert!(rows.get(&id).is_none());
        }
        actual.push(row);
    });
    super::super::session_pages::sort_session_summaries(&mut actual);
    assert_eq!(actual, expected);
    assert_eq!(actual.len(), 3);
    assert!(hub.remote_sessions.read().is_empty());
}

/// A wait reads the row the full list puts first for each id: a peer's newer chat
/// over a local one with the same bare id, and the newer of two peers' rows.
#[test]
fn summaries_of_some_ids_are_the_rows_the_full_list_puts_first() {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    for (id, at) in [("x", 10u64), ("solo", 30)] {
        let meta = json!({"schema": "acpmux.session.v1", "id": id, "name": id, "harness": "claude",
                          "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": at});
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    }
    let hub = Hub::new(cfg, store);
    let row = |id: &str, status: &str, at: u64| json!({"sessionId": id, "name": format!("lane-{id}"), "status": status, "turnCount": 1, "updatedAt": at});
    for (peer, rows) in [
        ("builder", vec![row("x", "running", 20), row("y", "waiting", 7)]),
        ("other", vec![row("x", "idle", 5), row("y", "idle", 9)]),
    ] {
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let p = crate::peer::Peer::new(peer, "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert(peer.to_owned(), p.clone());
        hub.apply_peer_notice(peer, p.generation, crate::peer::PeerNotice::Sessions(rows));
    }
    let ids: Vec<String> = ["x", "y", "solo", "none", "x"].map(str::to_owned).to_vec();
    let all = hub.all_session_summaries();
    let mut streamed = Vec::new();
    hub.visit_session_summaries(true, |row| streamed.push(row));
    super::super::session_pages::sort_session_summaries(&mut streamed);
    assert_eq!(streamed, all, "local and normalized remote summaries agree");
    let some = hub.session_summaries_of(&ids);
    for id in &ids {
        let first = all.iter().find(|s| s["sessionId"] == id.as_str());
        assert_eq!(some.get(id), first, "{id}: {some:?}");
    }
    assert_eq!(some["x"]["peer"], "builder", "the newer peer row, not the local chat");
    assert_eq!(some["x"]["status"], "running");
    assert_eq!(some["y"]["peer"], "other", "the newer of two peer rows");
    assert!(some["solo"].get("peer").is_none(), "{:?}", some["solo"]);
    assert_eq!(some.len(), 3, "{some:?}");
}

#[test]
fn a_purge_between_session_projection_and_swap_stays_gone() {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new("builder", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("builder".into(), peer.clone());
    let row = |status: &str| {
        json!({"sessionId": "x", "name": "lane-x", "status": status,
            "createdAt": 1, "updatedAt": 2})
    };
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        crate::peer::PeerNotice::Sessions(vec![row("idle")]),
    );

    let hook = PeerNoticeProjectionHook::new();
    *hub.peer_notice_projection_hook.lock().unwrap() = Some(hook.clone());
    let applying = {
        let hub = hub.clone();
        let generation = peer.generation;
        std::thread::spawn(move || {
            hub.apply_peer_notice(
                "builder",
                generation,
                crate::peer::PeerNotice::Sessions(vec![row("running")]),
            );
        })
    };
    hook.wait_reached();
    hub.forget_remote(("builder", peer.generation), "x", Some(1));
    hook.release();
    applying.join().unwrap();
    assert!(hub.remote_sessions().is_empty(), "the purged row was reinserted");
}

#[test]
fn a_peer_purge_fences_rows_from_an_inflight_full_list_retry() {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new("builder", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("builder".into(), peer.clone());
    let row = json!({"sessionId": "x", "name": "lane-x", "status": "idle",
        "createdAt": 1, "updatedAt": 2});
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        crate::peer::PeerNotice::Sessions(vec![row.clone()]),
    );

    let hook = PeerNoticeProjectionHook::new();
    *hub.peer_notice_projection_hook.lock().unwrap() = Some(hook.clone());
    let applying = {
        let hub = hub.clone();
        let generation = peer.generation;
        std::thread::spawn(move || {
            hub.apply_peer_notice(
                "builder",
                generation,
                crate::peer::PeerNotice::Sessions(vec![row]),
            );
        })
    };
    hook.wait_reached();
    hub.purge_peer_rows("builder");
    hook.release();
    applying.join().unwrap();
    assert!(hub.remote_sessions().is_empty(), "the purged row was reinserted after retry");
}

#[tokio::test]
async fn an_old_grace_timer_cannot_mark_replacement_rows_unreachable() {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let old = crate::peer::Peer::new("builder", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("builder".into(), old.clone());
    hub.apply_peer_notice(
        "builder",
        old.generation,
        crate::peer::PeerNotice::Sessions(vec![json!({
            "sessionId": "x", "name": "lane-x", "status": "idle", "createdAt": 1,
            "updatedAt": 2
        })]),
    );
    let fence = old.remote_rows_epoch.load(std::sync::atomic::Ordering::Acquire);
    let pc = crate::config::PeerConfig {
        link_host: None,
        wireguard: None,
        url: "ws://127.0.0.1:9".into(),
        token: None,
        peer_token: None,
        vm_boundary: false,
        github_broker: false,
    };
    let (_generation, _settled) = hub.spawn_peer("builder", &pc, false);

    hub.mark_peer_unreachable_at_fence(&old, "builder", old.generation, fence);
    let rows = hub.remote_sessions();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["status"], "idle", "old timer marked replacement rows stale");
    hub.peer("builder").unwrap().stop();
}

#[tokio::test]
async fn a_removed_peer_cannot_be_reinserted_by_a_paused_notice() {
    let make_hub = || {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let peer = crate::peer::Peer::new("builder", "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert("builder".into(), peer.clone());
        (hub, peer)
    };
    let row = |status: &str| {
        json!({"sessionId": "x", "name": "lane-x", "status": status,
            "createdAt": 1, "updatedAt": 2})
    };

    // A full list that has projected before remove_peer must not restore its rows.
    let (hub, peer) = make_hub();
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        crate::peer::PeerNotice::Sessions(vec![row("idle")]),
    );
    let hook = PeerNoticeProjectionHook::new();
    *hub.peer_notice_projection_hook.lock().unwrap() = Some(hook.clone());
    let applying = {
        let hub = hub.clone();
        let generation = peer.generation;
        let listed = row("running");
        std::thread::spawn(move || {
            hub.apply_peer_notice(
                "builder",
                generation,
                crate::peer::PeerNotice::Sessions(vec![listed]),
            );
        })
    };
    hook.wait_reached();
    hub.remove_peer("builder").await.unwrap();
    hook.release();
    applying.join().unwrap();
    assert!(hub.remote_sessions().is_empty(), "full-list notice resurrected removed rows");

    // A session_changed notice has the same removal race, including a leased peer's drop.
    let (hub, peer) = make_hub();
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        crate::peer::PeerNotice::Sessions(vec![row("idle")]),
    );
    let hook = PeerNoticeProjectionHook::new();
    *hub.peer_notice_projection_hook.lock().unwrap() = Some(hook.clone());
    let applying = {
        let hub = hub.clone();
        let generation = peer.generation;
        let changed = row("running");
        std::thread::spawn(move || {
            hub.apply_peer_notice(
                "builder",
                generation,
                crate::peer::PeerNotice::SessionChanged {
                    session: changed,
                    kind: "status".into(),
                    seq: 2,
                },
            );
        })
    };
    hook.wait_reached();
    hub.remove_peer("builder").await.unwrap();
    hook.release();
    applying.join().unwrap();
    assert!(hub.remote_sessions().is_empty(), "session_changed resurrected removed rows");

    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg.clone(), store);
    let (lease, _settled) =
        hub.lease_peer("builder", "ws://127.0.0.1:9", "token".into(), None, false, &cfg).unwrap();
    let peer = hub.peer("builder").unwrap();
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        crate::peer::PeerNotice::Sessions(vec![row("idle")]),
    );
    let hook = PeerNoticeProjectionHook::new();
    *hub.peer_notice_projection_hook.lock().unwrap() = Some(hook.clone());
    let applying = {
        let hub = hub.clone();
        let generation = peer.generation;
        let changed = row("running");
        std::thread::spawn(move || {
            hub.apply_peer_notice(
                "builder",
                generation,
                crate::peer::PeerNotice::SessionChanged {
                    session: changed,
                    kind: "status".into(),
                    seq: 3,
                },
            );
        })
    };
    hook.wait_reached();
    hub.end_peer_lease(&lease);
    hook.release();
    applying.join().unwrap();
    assert!(hub.remote_sessions().is_empty(), "lease end resurrected rows");
}

#[test]
fn a_forget_remote_and_full_list_notice_complete_without_lock_order_deadlock() {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new("builder", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("builder".into(), peer.clone());
    let row = json!({
        "sessionId": "x", "name": "lane-x", "status": "idle", "createdAt": 1,
        "updatedAt": 2
    });
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        crate::peer::PeerNotice::Sessions(vec![row.clone()]),
    );
    let hook = PeerNoticeProjectionHook::new();
    *hub.peer_notice_projection_hook.lock().unwrap() = Some(hook.clone());
    let applying = {
        let hub = hub.clone();
        let generation = peer.generation;
        std::thread::spawn(move || {
            hub.apply_peer_notice(
                "builder",
                generation,
                crate::peer::PeerNotice::Sessions(vec![row]),
            );
        })
    };
    hook.wait_reached();
    let forgetting = {
        let hub = hub.clone();
        let generation = peer.generation;
        std::thread::spawn(move || hub.forget_remote(("builder", generation), "x", Some(1)))
    };
    forgetting.join().unwrap();
    hook.release();
    applying.join().unwrap();
    assert!(hub.remote_sessions().is_empty(), "the forgotten row was reinserted");
}

/// A chat the link attached again without history after a reconnect (`REATTACHED_NOTICE`): its
/// clients here are told they lagged, with its id, so each reads on from its own last record.
/// No other chat of the peer is, and no other peer's chat.
#[test]
fn a_chat_attached_again_without_history_tells_only_its_clients_they_lagged() {
    let hub =
        Hub::new(crate::config::Config::default(), Box::new(crate::store::MemoryStore::default()));
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new("vm", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("vm".into(), peer.clone());
    let rows = ["r1", "r2"].map(|id| json!({"sessionId": id, "status": "idle", "updatedAt": 1}));
    hub.apply_peer_notice("vm", peer.generation, crate::peer::PeerNotice::Sessions(rows.into()));
    let mut events = hub.subscribe();
    hub.apply_peer_notice(
        "vm",
        peer.generation,
        crate::peer::PeerNotice::Notification {
            method: crate::peer::REATTACHED_NOTICE.into(),
            params: json!({"sessionId": "r1"}),
            link: 1,
        },
    );
    let mut lagged = Vec::new();
    while let Ok(ev) = events.try_recv() {
        if ev.record.kind == PEER_LAGGED {
            lagged.push((ev.session_id.clone(), ev.record.msg.clone(), ev.remote.map(|r| r.peer)));
        }
    }
    assert_eq!(
        lagged,
        [(
            "r1".to_owned(),
            json!({"sessionIds": ["r1"], "reason": "peer_reattached"}),
            Some("vm".to_owned())
        )]
    );
    peer.stop();
}

/// A peer's reattach notice reaches only that peer's chat: no local closed row goes stale on it,
/// so the next list rebuilds none of them (Leo 2026-11-04: "never ... acceptable ... linear time
/// growth degradation"). Each reattach rebuilt every closed row on the next list. At 5 and 300
/// closed rows alike.
#[test]
fn a_peers_reattach_leaves_every_local_closed_row_cached() {
    for closed in [5_usize, 300] {
        let store = Box::new(crate::store::MemoryStore::default());
        let hub = Hub::new(crate::config::Config::default(), store);
        for n in 0..closed {
            let meta: crate::store::SessionMeta = serde_json::from_value(json!({
                "schema": crate::store::META_SCHEMA, "id": format!("c-{n}"),
                "name": format!("c-{n}"), "harness": "claude", "family": "claude", "cwd": "/w",
                "status": "closed", "createdAt": 1, "updatedAt": n + 1,
            }))
            .unwrap();
            hub.insert_test_session(meta);
        }
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let peer = crate::peer::Peer::new("vm", "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert("vm".into(), peer.clone());
        let rows = [json!({"sessionId": "r1", "status": "idle", "updatedAt": 1})];
        let sessions = crate::peer::PeerNotice::Sessions(rows.into());
        hub.apply_peer_notice("vm", peer.generation, sessions);
        hub.visit_session_summaries(false, |_| {});
        use std::sync::atomic::Ordering::SeqCst;
        let invalidations = || hub.events.summary_generation.load(SeqCst);
        let builds = || hub.closed_summary_builds.load(SeqCst);
        let (before, built) = (invalidations(), builds());
        for _ in 0..3 {
            hub.apply_peer_notice(
                "vm",
                peer.generation,
                crate::peer::PeerNotice::Notification {
                    method: crate::peer::REATTACHED_NOTICE.into(),
                    params: json!({"sessionId": "r1"}),
                    link: 1,
                },
            );
            hub.visit_session_summaries(false, |_| {});
        }
        assert_eq!(invalidations() - before, 0, "closed-row invalidations at {closed}");
        assert_eq!(builds() - built, 0, "closed rows rebuilt at {closed}");
        peer.stop();
    }
}
