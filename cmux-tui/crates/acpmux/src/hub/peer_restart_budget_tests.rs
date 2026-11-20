//! What a mirrored peer's restart and a mirrored row's change cost here: `session_changed`
//! notices to watchers and peer-cache bytes. Every row carries `sessionReceipt.generation`, the
//! owning daemon's start time, so a restarted peer lists every row with a new one. Compared as
//! text, every row differed, closed ones too: a Mac mirroring 10,366 rows rewrote whole peers
//! (1,377 rows / 5.5 MB, 581 rows / 3.1 MB, ...) eight times in 15 minutes, and its journal
//! lines carried each row's `tools` and `timeBreakdown` (15-90 KB a row) (2026-11-18).
//!
//! Run with `cargo test -p acpmux --lib -- hub::peer_restart_budget_tests --nocapture` for the
//! numbers.

use super::*;
use crate::peer::PeerNotice;

const ROWS: usize = 1_000;

fn hub_at(dir: &Path) -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

fn add_idle_peer(hub: &Hub, name: &str) -> Arc<crate::peer::Peer> {
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new(name, "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert(name.to_owned(), peer.clone());
    peer
}

/// Session `i` as a peer that started at `started` lists it; most are closed, as on a real
/// peer, and every tenth carries its turns' timing.
fn row(i: usize, started: u64) -> Value {
    let id = format!("s{i}");
    let mut row = json!({
        "sessionId": id, "name": format!("lane-{i}"), "agentSessionId": format!("a{i}"),
        "status": if i.is_multiple_of(4) { "idle" } else { "closed" }, "turnCount": 3, "updatedAt": 5,
        "createdAt": 1, "title": format!("chat {i}"),
        "sessionReceipt": {
            "hostId": "local", "muxSessionId": id, "agentSessionId": format!("a{i}"),
            "generation": started,
        },
    });
    if i.is_multiple_of(10) {
        row["timeBreakdown"] = json!({"turns": vec![json!({"ms": 1234, "tool": "Bash"}); 100]});
    }
    row
}

fn wrote(hub: &Hub) -> u64 {
    hub.cache_test_bytes.load(std::sync::atomic::Ordering::SeqCst)
}

/// The peer-row notices watchers were sent since `events` subscribed.
fn notices(events: &mut tokio::sync::broadcast::Receiver<HubEvent>) -> usize {
    let mut n = 0;
    while let Ok(event) = events.try_recv() {
        if event.remote.is_some() {
            n += 1;
        }
    }
    n
}

/// A peer that restarts with every session as it was: no watcher is told of any row and the
/// peer cache writes nothing. Its rows still name the run that lists them now.
#[test]
fn a_peer_restart_with_unchanged_sessions_announces_and_writes_nothing() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-prb");
    let hub = hub_at(dir.path());
    let peer = add_idle_peer(&hub, "mac");
    let list = |started: u64| (0..ROWS).map(|i| row(i, started)).collect::<Vec<_>>();
    hub.apply_peer_notice("mac", peer.generation, PeerNotice::sessions_from_values(list(100)));
    hub.save_peer_cache("mac", peer.generation, true);

    let mut events = hub.events.subscribe();
    let start = wrote(&hub);
    // The peer restarts (a planned restart), then lists the same sessions as its next run.
    hub.apply_peer_notice("mac", peer.generation, PeerNotice::Restarting);
    hub.apply_peer_notice("mac", peer.generation, PeerNotice::sessions_from_values(list(200)));
    hub.save_peer_cache("mac", peer.generation, true);
    let (told, bytes) = (notices(&mut events), wrote(&hub) - start);
    eprintln!("peer restart, {ROWS} unchanged rows: {told} session_changed, {bytes} B written");
    assert_eq!(told, 0, "a restart with unchanged sessions announced {told} rows");
    assert_eq!(bytes, 0, "a restart with unchanged sessions wrote {bytes} bytes");
    let rows = hub.remote_sessions();
    assert_eq!(rows.len(), ROWS);
    assert!(rows.iter().all(|r| r["sessionReceipt"]["generation"] == 200), "the new run's");

    // A real change after it is still announced and saved.
    let mut changed = row(1, 200);
    changed["status"] = json!("idle");
    let mut list = list(200);
    list[1] = changed;
    hub.apply_peer_notice("mac", peer.generation, PeerNotice::sessions_from_values(list));
    hub.save_peer_cache("mac", peer.generation, true);
    assert_eq!(notices(&mut events), 1);
    assert!(wrote(&hub) > start);
}

/// A change of a row that carries tools and timing writes a journal line no bigger than the
/// row as a census lists it: no tools, no timing.
#[test]
fn a_journal_line_is_no_bigger_than_its_census_row() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-prb");
    let hub = hub_at(dir.path());
    let peer = add_idle_peer(&hub, "mac");
    hub.apply_peer_notice(
        "mac",
        peer.generation,
        PeerNotice::sessions_from_values((0..10).map(|i| row(i, 100)).collect()),
    );
    hub.save_peer_cache("mac", peer.generation, true);

    let mut session = row(0, 100);
    session["status"] = json!("running");
    session["tools"] =
        json!(vec![json!({"id": "mcp:github", "description": "x".repeat(200)}); 100]);
    session["toolsMutable"] = json!(true);
    let census = {
        let mut census = session.clone();
        let map = census.as_object_mut().unwrap();
        for key in ["tools", "toolsMutable", "timeBreakdown"] {
            map.remove(key);
        }
        serde_json::to_vec(&Hub::remote_summary("mac", census)).unwrap().len() as u64
    };
    let start = wrote(&hub);
    hub.apply_peer_notice(
        "mac",
        peer.generation,
        PeerNotice::SessionChanged { session, kind: "status".into(), seq: 1 },
    );
    hub.save_peer_cache("mac", peer.generation, true);
    let line = wrote(&hub) - start;
    eprintln!("one change of a row with tools and timing: {line} B written; census row {census} B");
    // The line's own keys (`base`, `link`, the row's key) on top of the row.
    assert!(line <= census + 256, "a journal line of {line} B for a census row of {census} B");
    // Memory still has the tools the peer sent.
    let rows = hub.remote_sessions.read();
    assert!(rows.of_peer("mac").any(|(_, r)| r.summary.has_tools()));
}
