//! The peer cache's disk cost (`peer_cache_disk.rs`): bytes written per change for a peer that
//! lists ten sessions and for one that lists five thousand (about 5 KB each, some 84 KB, as a
//! real busy peer did), side by side, plus what a restart reads back.
//!
//! Run with `cargo test -p acpmux --lib -- hub::peer_cache_disk_tests --nocapture` for the table.

use super::*;
use crate::peer::PeerNotice;

const CHANGES: usize = 200;
const ROW_PAD: usize = 5_000;
const BIG_PAD: usize = 84_000;

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

/// Session `i`: about 5 KB, and every hundredth (in a large list) about 84 KB, like the largest
/// `timeBreakdown` a real peer listed.
fn row(i: usize, rows: usize) -> Value {
    let pad = if rows > 100 && i % 100 == 99 { BIG_PAD } else { ROW_PAD };
    json!({"sessionId": format!("s{i}"), "name": format!("lane-{i}"), "status": "idle",
        "turnCount": 1, "updatedAt": 5, "timeBreakdown": "x".repeat(pad)})
}

fn wrote(hub: &Hub) -> u64 {
    hub.cache_test_bytes.load(std::sync::atomic::Ordering::SeqCst)
}

#[derive(Debug)]
struct Cost {
    rows: usize,
    /// What the old path wrote at every save: the whole file.
    whole_file: u64,
    /// Bytes per one-row change, compactions included, over `CHANGES` changes.
    per_change: f64,
    /// A parked drop (only the link's retry deadline changed).
    parked_drop: u64,
    /// A drop past its grace (every row marked stale) and the same list again.
    flap: u64,
}

fn measure(rows: usize) -> Cost {
    let dir = cmux_unix_socket::short_test_dir("acpmux-pcd");
    let hub = hub_at(dir.path());
    let name = "busy";
    let peer = add_idle_peer(&hub, name);
    let list: Vec<Value> = (0..rows).map(|i| row(i, rows)).collect();
    hub.apply_peer_notice(name, peer.generation, PeerNotice::Sessions(list.clone()));
    hub.save_peer_cache(name, peer.generation, true);
    let peers = dir.path().join("peers");
    let whole_file = std::fs::metadata(peers.join(format!("{name}.json"))).unwrap().len();

    let start = wrote(&hub);
    for n in 0..CHANGES {
        let mut changed = row((n * 7) % rows.min(99), rows);
        changed["updatedAt"] = json!(100 + n);
        changed["status"] = json!(if n % 2 == 0 { "running" } else { "idle" });
        hub.apply_peer_notice(
            name,
            peer.generation,
            PeerNotice::SessionChanged { session: changed, kind: "status".into(), seq: n as u64 },
        );
        hub.save_peer_cache(name, peer.generation, true);
    }
    let per_change = (wrote(&hub) - start) as f64 / CHANGES as f64;
    // The journal never outgrows its bound.
    let journal = std::fs::metadata(peers.join(format!("{name}.journal"))).map_or(0, |m| m.len());
    let snapshot = std::fs::metadata(peers.join(format!("{name}.json"))).unwrap().len();
    assert!(journal <= super::peer_cache_disk::COMPACT_MIN_BYTES.max(2 * snapshot), "{journal}");

    let start = wrote(&hub);
    let link = peer.link();
    peer.seed_cached_link(link.last_seen, link.down_since, Some(now_ms() + 3_600_000));
    hub.save_after_drop(name, peer.generation, false);
    let parked_drop = wrote(&hub) - start;

    // The rows as they are now, so the flap below lists exactly what is on disk.
    let current: Vec<Value> = {
        let rows = hub.remote_sessions.read();
        rows.of_peer(name).map(|(_, r)| r.summary.clone()).collect()
    };
    let start = wrote(&hub);
    peer.seed_last_seen(Some(now_ms() - 40_000));
    hub.mark_peer_unreachable(name, peer.generation);
    assert!(hub.remote_sessions().iter().all(|r| r["stale"] == true));
    hub.apply_peer_notice(name, peer.generation, PeerNotice::Sessions(current));
    hub.save_peer_cache(name, peer.generation, true);
    let flap = wrote(&hub) - start;

    // A restart reads back what memory holds.
    let saved = super::peer_cache_disk::saved_json(&peers, name);
    let sessions = saved["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), rows);
    let last = (CHANGES - 1) * 7 % rows.min(99);
    let found = sessions.iter().find(|s| s["sessionId"] == format!("s{last}")).unwrap();
    assert_eq!(found["updatedAt"], json!(100 + CHANGES - 1));
    assert_eq!(saved["nextRetryAt"], json!(peer.link().next_retry_at));
    Cost { rows, whole_file, per_change, parked_drop, flap }
}

/// Leo, 2026-11-10: a god-sized peer costs about what a small one does.
#[test]
fn a_change_costs_the_same_for_ten_rows_and_five_thousand() {
    let small = measure(10);
    let god = measure(5_000);
    for c in [&small, &god] {
        eprintln!(
            "peer cache rows={:>5}  before: {:>9} B per save (whole file)  after: {:>8.0} B per change \
             (amortized), parked drop {:>4} B, flap {:>5} B",
            c.rows, c.whole_file, c.per_change, c.parked_drop, c.flap
        );
    }
    assert!(god.per_change <= 1.2 * small.per_change, "{small:?} vs {god:?}");
    assert!(god.parked_drop as f64 <= 1.2 * small.parked_drop as f64, "{small:?} vs {god:?}");
    assert!(god.parked_drop < 512, "a parked drop wrote rows: {god:?}");
    assert!(god.flap < 1_024, "a flap rewrote unchanged rows: {god:?}");
    assert!(god.whole_file > 20_000_000, "the god fixture is god-sized: {god:?}");
}

fn listed(id: &str, status: &str) -> Value {
    json!({"sessionId": id, "name": format!("lane-{id}"), "status": status, "updatedAt": 5})
}

/// A changed row and a purged one survive a restart through the journal; the snapshot is not
/// rewritten for them.
#[test]
fn a_restart_reads_the_journal_with_its_tombstones() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-pcd");
    let hub = hub_at(dir.path());
    let peer = add_idle_peer(&hub, "builder");
    let rows = vec![listed("a", "idle"), listed("b", "idle"), listed("c", "idle")];
    hub.apply_peer_notice("builder", peer.generation, PeerNotice::Sessions(rows));
    hub.save_peer_cache("builder", peer.generation, true);
    let peers = dir.path().join("peers");
    let snapshot = std::fs::read(peers.join("builder.json")).unwrap();

    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::SessionChanged {
            session: listed("a", "running"),
            kind: "status".into(),
            seq: 1,
        },
    );
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::SessionChanged {
            session: json!({"sessionId": "b"}),
            kind: "purged".into(),
            seq: 2,
        },
    );
    hub.save_peer_cache("builder", peer.generation, true);
    assert_eq!(std::fs::read(peers.join("builder.json")).unwrap(), snapshot, "snapshot rewritten");
    assert!(std::fs::metadata(peers.join("builder.journal")).unwrap().len() > 0);

    hub.seal();
    let again = hub_at(dir.path());
    let restored = add_idle_peer(&again, "builder");
    again.load_peer_cache(&restored);
    let mut ids: Vec<String> = again
        .remote_sessions()
        .iter()
        .map(|r| r["sessionId"].as_str().unwrap().to_owned())
        .collect();
    ids.sort();
    assert_eq!(ids, ["a", "c"], "the purged row stays purged");
    let saved = super::peer_cache_disk::saved_json(&peers, "builder");
    let a = saved["sessions"].as_array().unwrap().iter().find(|s| s["sessionId"] == "a").unwrap();
    assert_eq!(a["status"], "running");

    // Its first save folds the journal into a new snapshot.
    again.save_peer_cache("builder", restored.generation, true);
    assert!(!peers.join("builder.journal").exists());
    assert_eq!(
        super::peer_cache_disk::saved_json(&peers, "builder")["sessions"].as_array().unwrap().len(),
        2
    );
}

/// A torn last line is skipped; a snapshot an older daemon rewrote (no journal id) ignores the
/// journal left beside it.
#[test]
fn a_torn_line_and_an_older_daemons_snapshot_are_read_safely() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-pcd");
    let hub = hub_at(dir.path());
    let peer = add_idle_peer(&hub, "builder");
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::Sessions(vec![listed("a", "idle")]),
    );
    hub.save_peer_cache("builder", peer.generation, true);
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::SessionChanged {
            session: listed("a", "running"),
            kind: "status".into(),
            seq: 1,
        },
    );
    hub.save_peer_cache("builder", peer.generation, true);
    let peers = dir.path().join("peers");
    {
        use std::io::Write;
        let mut f =
            std::fs::OpenOptions::new().append(true).open(peers.join("builder.journal")).unwrap();
        f.write_all(br#"{"base":1,"link":{"lastSe"#).unwrap();
    }
    let saved = super::peer_cache_disk::saved_json(&peers, "builder");
    assert_eq!(saved["sessions"][0]["status"], "running", "{saved}");

    // An older daemon rewrites the snapshot in its own format.
    let old =
        json!({"lastSeen": 7, "sessions": [Hub::remote_summary("builder", listed("a", "ready"))]});
    std::fs::write(peers.join("builder.json"), old.to_string()).unwrap();
    let saved = super::peer_cache_disk::saved_json(&peers, "builder");
    assert_eq!(saved["sessions"][0]["status"], "ready", "an old journal was applied: {saved}");

    // And this daemon's next save, finding the files changed under it, writes a snapshot.
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::SessionChanged { session: listed("a", "idle"), kind: "status".into(), seq: 2 },
    );
    hub.save_peer_cache("builder", peer.generation, true);
    assert!(!peers.join("builder.journal").exists());
    let saved = super::peer_cache_disk::saved_json(&peers, "builder");
    assert_eq!(saved["sessions"][0]["status"], "idle", "{saved}");
}

/// A snapshot replaced by one of the same length is still found, and the next save writes a
/// snapshot rather than a journal line naming the old one.
#[test]
fn a_same_length_snapshot_replacement_is_found() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-pcd");
    let hub = hub_at(dir.path());
    let peer = add_idle_peer(&hub, "builder");
    let rows = vec![listed("a", "idle"), listed("b", "idle")];
    hub.apply_peer_notice("builder", peer.generation, PeerNotice::Sessions(rows));
    hub.save_peer_cache("builder", peer.generation, true);
    let peers = dir.path().join("peers");
    let snap = peers.join("builder.json");
    let before = std::fs::read_to_string(&snap).unwrap();
    // Another writer: same bytes count, no journal id (as an older daemon's would be).
    let replaced = before.replace("\"journal\":", "\"jxurnal\":");
    assert_eq!(replaced.len(), before.len());
    std::thread::sleep(std::time::Duration::from_millis(20));
    std::fs::write(&snap, &replaced).unwrap();
    hub.apply_peer_notice(
        "builder",
        peer.generation,
        PeerNotice::SessionChanged {
            session: listed("a", "running"),
            kind: "status".into(),
            seq: 1,
        },
    );
    hub.save_peer_cache("builder", peer.generation, true);
    assert!(!peers.join("builder.journal").exists(), "a line was appended to a foreign snapshot");
    let saved = super::peer_cache_disk::saved_json(&peers, "builder");
    let a = saved["sessions"].as_array().unwrap().iter().find(|s| s["sessionId"] == "a").unwrap();
    assert_eq!(a["status"], "running");
}
