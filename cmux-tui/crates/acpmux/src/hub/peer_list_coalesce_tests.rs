//! Whole lists that come faster than the hub applies them (every link of many peers cut
//! together, each reconnect listing every row) wait one per peer, not one per reconnect: the
//! queue of 4096 notices held thousands of lists, gigabytes (`peer_notice_queue.rs`). The rows
//! end as the newest list and the changes sent after it, and no change sent before it regresses
//! a row.

use super::*;
use crate::peer::{Peer, PeerNotice};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

const PEERS: usize = 8;
const ROWS: usize = 200;
const LISTS: u64 = 40;

fn setup() -> Arc<Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    Hub::new(cfg.clone(), crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap())
}

fn row(session: usize, at: u64) -> Value {
    json!({
        "sessionId": format!("s{session}"),
        "name": format!("lane-{session}"),
        "status": "running",
        "createdAt": 1,
        "updatedAt": at,
        "cwd": "/home/agent/Projects/checkouts/repo/lane--some-branch-name",
        "title": "A title long enough to look like a real one",
    })
}

fn changed(session: usize, at: u64) -> PeerNotice {
    PeerNotice::SessionChanged { session: row(session, at), kind: "status".into(), seq: at }
}

#[tokio::test]
async fn lists_faster_than_applied_wait_one_per_peer_and_the_newest_wins() {
    let hub = setup();
    let mut peers = Vec::new();
    for n in 0..PEERS {
        let name = format!("peer-{n}");
        let peer = Peer::new(&name, "ws://127.0.0.1:9", None, None, hub.peer_notices.clone());
        hub.peers.lock().unwrap().insert(name.clone(), peer.clone());
        peers.push(peer);
    }
    let one_list: usize = {
        let rows: Vec<Value> = (0..ROWS).map(|s| row(s, LISTS)).collect();
        let (tx, _rx) = crate::peer_notice_queue::channel(1);
        tx.send(("x".into(), 0, PeerNotice::Sessions(rows))).await.unwrap();
        tx.lists_status()["pendingBytes"].as_u64().unwrap() as usize
    };
    // Unconstrained: no send yields to the notice loop, so nothing is applied while it floods.
    tokio::task::unconstrained(async {
        for at in 1..=LISTS {
            for peer in &peers {
                let send = |n| hub.peer_notices.send((peer.name.clone(), peer.generation, n));
                // A reconnect: its list, then the changes held while it was paged.
                send(PeerNotice::Sessions((0..ROWS).map(|s| row(s, at)).collect())).await.unwrap();
                send(changed(0, at)).await.unwrap();
                send(PeerNotice::Connected).await.unwrap();
                // A change sent on the old link before the next list: the next list reflects it.
                send(changed(1, at)).await.unwrap();
                send(PeerNotice::Disconnected("flap".into())).await.unwrap();
            }
            let status = hub.peer_notices.lists_status();
            assert!(status["pendingLists"].as_u64().unwrap() <= PEERS as u64, "{status}");
            assert!(
                status["pendingBytes"].as_u64().unwrap() as usize <= PEERS * one_list,
                "{status}: more than one list per peer waits"
            );
        }
        // The last link: its list, and a change newer than it.
        for peer in &peers {
            let send = |n| hub.peer_notices.send((peer.name.clone(), peer.generation, n));
            send(PeerNotice::Sessions((0..ROWS).map(|s| row(s, LISTS + 1)).collect()))
                .await
                .unwrap();
            send(changed(2, LISTS + 2)).await.unwrap();
            send(PeerNotice::Connected).await.unwrap();
        }
    })
    .await;
    let status = hub.peer_notices.lists_status();
    assert_eq!(status["superseded"], json!(LISTS * PEERS as u64), "{status}");
    // Applied once the loop drains the queue.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let drained = hub.peer_notices.lists_status()["pendingLists"] == 0;
        let newest = hub
            .remote_sessions
            .read()
            .values()
            .filter(|r| r.summary["updatedAt"] == json!(LISTS + 2))
            .count();
        if drained && newest == PEERS {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "not applied: {status}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let rows = hub.remote_sessions.read();
    for peer in &peers {
        let mine: Vec<_> = rows.values().filter(|r| r.peer == peer.name).collect();
        assert_eq!(mine.len(), ROWS, "{}", peer.name);
        for r in mine {
            let want = if r.summary["sessionId"] == "s2" { LISTS + 2 } else { LISTS + 1 };
            assert_eq!(r.summary["updatedAt"], json!(want), "{}: {}", peer.name, r.summary);
        }
    }
}
