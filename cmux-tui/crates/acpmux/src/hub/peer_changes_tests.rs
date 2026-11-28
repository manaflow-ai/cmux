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

fn changed(session: Value, kind: &str, seq: u64) -> PeerNotice {
    PeerNotice::SessionChanged { session, kind: kind.into(), seq }
}

/// A turn's changes of one session as they come in a round: whole rows, the last the turn's end.
fn turn(peer: &Arc<Peer>, session: usize, from: u64) -> Vec<(String, u64, PeerNotice)> {
    ["status", "turn_started", "user_message", "turn_result", "turn_end", "status"]
        .iter()
        .enumerate()
        .map(|(i, kind)| {
            let at = from + i as u64;
            (peer.name.clone(), peer.generation, changed(row(session, at as usize), kind, at))
        })
        .collect()
}

#[test]
fn a_sessions_changes_in_one_run_are_one_row_built_and_each_still_announced() {
    let (alone, alone_peers) = linked();
    let (runs, run_peers) = linked();
    // Two sessions' turns interleaved, as a round's notices queue behind each other.
    let interleave = |peers: &[Arc<Peer>]| {
        let (a, b) = (turn(&peers[0], 1, 10), turn(&peers[1], 2, 20));
        a.into_iter().zip(b).flat_map(|(x, y)| [x, y]).collect::<Vec<_>>()
    };
    for (peer, generation, notice) in interleave(&alone_peers) {
        alone.apply_peer_notice(&peer, generation, notice);
    }
    let mut heard = runs.events.subscribe();
    let applied = runs.apply_session_changes(interleave(&run_peers));
    assert_eq!(applied.len(), 2, "one row built and put in the table per session");
    for change in applied {
        runs.session_change_announce(change);
    }
    assert_eq!(table(&alone), table(&runs), "folding left another table");
    let mut told: BTreeMap<String, Vec<(String, u64, u64)>> = BTreeMap::new();
    while let Ok(ev) = heard.try_recv() {
        let Some(remote) = ev.remote.as_ref() else { continue };
        told.entry(remote.peer.clone()).or_default().push((
            ev.record.kind.clone(),
            ev.record.seq,
            remote.summary.updated_ms(),
        ));
    }
    for (peer, from) in [(&run_peers[0].name, 10), (&run_peers[1].name, 20)] {
        let kinds = &told[peer];
        let expected: Vec<_> = turn(&run_peers[0], 0, from)
            .into_iter()
            .map(|(_, _, n)| match n {
                PeerNotice::SessionChanged { kind, seq, .. } => (kind, seq, from + 5),
                _ => unreachable!(),
            })
            .collect();
        assert_eq!(kinds, &expected, "every kind, in order, with the row it led to");
    }
}

#[test]
fn an_asks_change_never_folds_into_a_later_one() {
    let (hub, peers) = linked();
    let p = &peers[0];
    let notices = vec![
        (p.name.clone(), p.generation, changed(row(4, 30), "status", 30)),
        (p.name.clone(), p.generation, changed(row(4, 31), "permission_request", 31)),
        (p.name.clone(), p.generation, changed(row(4, 32), "status", 32)),
        (p.name.clone(), p.generation, changed(row(4, 33), "turn_end", 33)),
    ];
    let mut heard = hub.events.subscribe();
    let applied = hub.apply_session_changes(notices);
    assert_eq!(applied.len(), 3, "the ask's row is its own: before it, it, after it");
    for change in applied {
        hub.session_change_announce(change);
    }
    let mut told = Vec::new();
    while let Ok(ev) = heard.try_recv() {
        if let Some(remote) = ev.remote.as_ref() {
            told.push((ev.record.kind.clone(), remote.summary.updated_ms()));
        }
    }
    assert_eq!(
        told,
        [
            ("status".to_owned(), 30),
            ("permission_request".to_owned(), 31),
            ("status".to_owned(), 33),
            ("turn_end".to_owned(), 33),
        ]
    );
    let rows = hub.remote_sessions.read();
    assert_eq!(rows.find_mux(&p.name, "s4").unwrap().1.summary.updated_ms(), 33);
}
