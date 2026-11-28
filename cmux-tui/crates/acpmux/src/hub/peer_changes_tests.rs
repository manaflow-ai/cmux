//! A run of changed peer rows under one taking of the rows writer lock (`peers/changes.rs`):
//! the table it leaves is the one applying each alone leaves, and the lock is taken once a run,
//! not once a row (sessions-2000-attached: 2000 takings by 16 shards were a round's serial step).

use super::*;
use crate::hub::remote_table::under_writer;
use crate::peer::{Peer, PeerNotice};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;

const PEERS: usize = 4;
const ROWS: usize = 500;

fn setup() -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    Hub::new(cfg.clone(), crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap())
}

fn row(session: usize, updated: usize) -> Value {
    json!({
        "sessionId": format!("s{session}"),
        "name": format!("lane-{session}"),
        "status": if updated % 3 == 0 { "idle" } else { "running" },
        "createdAt": 1,
        "updatedAt": updated,
        "cwd": "/home/agent/Projects/checkouts/repo/lane--some-branch-name",
        "title": format!("turn {updated}"),
    })
}

fn linked() -> (Arc<Hub>, Vec<Arc<Peer>>) {
    let hub = setup();
    let mut linked = Vec::new();
    for n in 0..PEERS {
        let name = format!("peer-{n}");
        let peer = Peer::new(&name, "ws://127.0.0.1:9", None, None, hub.peer_notices.clone());
        hub.peers.lock().unwrap().insert(name.clone(), peer.clone());
        let list = (0..ROWS).map(|s| row(s, 1)).collect();
        hub.apply_peer_notice(&name, peer.generation, PeerNotice::sessions_from_values(list));
        linked.push(peer);
    }
    (hub, linked)
}

/// A round: every session of every peer changes once, peers interleaved as their notices come.
fn round(peers: &[Arc<Peer>], turn: usize) -> Vec<(String, u64, PeerNotice)> {
    (0..ROWS)
        .flat_map(|s| {
            peers.iter().map(move |p| {
                let session = row(s, turn + s);
                (
                    p.name.clone(),
                    p.generation,
                    PeerNotice::SessionChanged { session, kind: "status".into(), seq: 0 },
                )
            })
        })
        .collect()
}

fn table(hub: &Hub) -> BTreeMap<String, (String, String)> {
    hub.remote_sessions
        .read()
        .iter()
        .map(|(id, r)| (id.clone(), (r.peer.clone(), r.summary.text())))
        .collect()
}

#[test]
fn a_run_of_changed_rows_takes_the_writer_lock_once_and_leaves_what_each_alone_leaves() {
    let (alone, alone_peers) = linked();
    let (runs, run_peers) = linked();
    assert_eq!(table(&alone), table(&runs));
    for turn in [2, 10] {
        under_writer::take();
        let notices = round(&alone_peers, turn);
        let count = notices.len() as u64;
        for (peer, generation, notice) in notices {
            assert!(alone.batchable_change(&peer, &notice).is_some());
            alone.apply_peer_notice(&peer, generation, notice);
        }
        let held_alone = under_writer::take().holds;
        assert!(held_alone >= count, "each alone takes the lock: {held_alone} < {count}");

        let mut notices = round(&run_peers, turn).into_iter().peekable();
        let mut held_runs = 0;
        while notices.peek().is_some() {
            let chunk: Vec<_> = notices.by_ref().take(CHANGES_PER_HOLD).collect();
            let len = chunk.len();
            under_writer::take();
            let applied = runs.apply_session_changes(chunk);
            held_runs += under_writer::take().holds;
            assert_eq!(applied.len(), len);
            for change in applied {
                runs.session_change_announce(change);
            }
        }
        let chunks = count.div_ceil(CHANGES_PER_HOLD as u64);
        assert_eq!(held_runs, chunks, "one writer hold a run of {count} changes");
        assert_eq!(table(&alone), table(&runs), "turn {turn}: a run left another table");
    }
}

#[test]
fn a_purge_or_a_closed_row_is_not_part_of_a_run() {
    let (hub, peers) = linked();
    let peer = &peers[0];
    let purge = PeerNotice::SessionChanged {
        session: json!({"sessionId": "s1"}),
        kind: "purged".into(),
        seq: 0,
    };
    assert!(hub.batchable_change(&peer.name, &purge).is_none());
    let mut closed = row(2, 5);
    closed["status"] = json!("closed");
    hub.apply_peer_notice(
        &peer.name,
        peer.generation,
        PeerNotice::SessionChanged { session: closed, kind: "status".into(), seq: 0 },
    );
    let again = PeerNotice::SessionChanged { session: row(2, 6), kind: "status".into(), seq: 0 };
    assert!(hub.batchable_change(&peer.name, &again).is_none(), "a closed row's change");
    let live = PeerNotice::SessionChanged { session: row(3, 6), kind: "status".into(), seq: 0 };
    assert_eq!(hub.batchable_change(&peer.name, &live), Some("s3"));
}

#[test]
fn a_run_skips_a_peer_instance_that_is_gone() {
    let (hub, peers) = linked();
    let notices = vec![
        (
            peers[0].name.clone(),
            peers[0].generation + 1,
            PeerNotice::SessionChanged { session: row(1, 9), kind: "status".into(), seq: 0 },
        ),
        (
            peers[1].name.clone(),
            peers[1].generation,
            PeerNotice::SessionChanged { session: row(1, 9), kind: "status".into(), seq: 0 },
        ),
    ];
    let applied = hub.apply_session_changes(notices);
    assert_eq!(applied.len(), 1);
    assert_eq!(applied[0].peer(), peers[1].name);
    let rows = hub.remote_sessions.read();
    assert_eq!(rows.find_mux(&peers[0].name, "s1").unwrap().1.summary.updated_ms(), 1);
    assert_eq!(rows.find_mux(&peers[1].name, "s1").unwrap().1.summary.updated_ms(), 9);
}
