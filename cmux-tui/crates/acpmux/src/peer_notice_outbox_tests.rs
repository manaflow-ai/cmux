//! A link hands its notices over without waiting on the hub (`peer_notice_outbox.rs`).

use super::*;
use futures_util::FutureExt as _;
use serde_json::json;

fn scope() -> cmux_scope::Scope {
    cmux_scope::Scope::new("test notices")
}

fn changed(session: &str, kind: &str, seq: u64) -> Item {
    let notice = PeerNotice::SessionChanged {
        session: json!({"sessionId": session}),
        kind: kind.into(),
        seq,
    };
    ("box".into(), 1, notice)
}

fn note(n: u64) -> Item {
    let notice =
        PeerNotice::Notification { method: "test/note".into(), params: json!({"n": n}), link: 1 };
    ("box".into(), 1, notice)
}

/// What a notice is, to compare orders: `c:<session>:<seq>`, `n:<n>`.
fn tag((_, _, notice): &Item) -> String {
    match notice {
        PeerNotice::SessionChanged { session, seq, .. } => {
            format!("c:{}:{seq}", session["sessionId"].as_str().unwrap())
        }
        PeerNotice::Notification { params, .. } => format!("n:{}", params["n"]),
        other => format!("{other:?}"),
    }
}

/// Every send returns without waiting while the hub takes nothing, order holds across the
/// notices that keep their place, and changed rows merge only between them.
#[tokio::test]
async fn a_held_hub_never_holds_the_link_and_order_survives_the_merge() {
    let (hub, mut rx) = mpsc::channel(1);
    let outbox = NoticeOutbox::new(hub, scope());
    let sent = [
        changed("a", "status", 1), // straight into the hub's queue
        changed("a", "status", 2),
        changed("b", "status", 3),
        changed("a", "status", 4), // replaces 2
        note(1),
        changed("a", "status", 5),  // past note 1: kept
        changed("a", "created", 6), // another kind: kept
        changed("a", "purged", 7),
        changed("a", "status", 8), // after a purge: kept
        changed("a", "status", 9), // replaces 8
        note(2),
    ];
    for item in sent {
        outbox.send(item).now_or_never().expect("never waits").expect("the hub is up");
    }
    assert_eq!(outbox.backlog(), 8);
    let mut got = Vec::new();
    for _ in 0..9 {
        got.push(tag(&rx.recv().await.unwrap()));
    }
    let want = ["c:a:1", "c:b:3", "c:a:4", "n:1", "c:a:5", "c:a:6", "c:a:7", "c:a:9", "n:2"];
    assert_eq!(got, want);
}

/// Thousands of changes to a few rows while the hub is held cost a backlog of a few notices.
#[tokio::test]
async fn a_flood_of_changes_to_a_few_rows_stays_a_few_notices() {
    let (hub, mut rx) = mpsc::channel(1);
    let outbox = NoticeOutbox::new(hub, scope());
    for seq in 0..20_000_u64 {
        let session = ["a", "b", "c"][(seq % 3) as usize];
        outbox.send(changed(session, "status", seq)).now_or_never().unwrap().unwrap();
    }
    assert!(outbox.backlog() <= 3, "{}", outbox.backlog());
    assert_eq!(tag(&rx.recv().await.unwrap()), "c:a:0");
    let mut last = Vec::new();
    for _ in 0..3 {
        last.push(tag(&rx.recv().await.unwrap()));
    }
    assert_eq!(last, ["c:c:19997", "c:a:19998", "c:b:19999"], "only each row's latest");
}

/// Only a full backlog of notices that cannot merge makes a link wait, and it goes on as soon as
/// the hub takes one.
#[tokio::test]
async fn a_full_backlog_waits_for_the_hub_then_goes_on() {
    let (hub, mut rx) = mpsc::channel(1);
    let outbox = NoticeOutbox::with_cap(hub, scope(), 4);
    for n in 0..5 {
        outbox.send(note(n)).now_or_never().unwrap().unwrap();
    }
    let mut waiting = Box::pin(outbox.send(note(5)));
    assert!((&mut waiting).now_or_never().is_none(), "a full backlog waits");
    assert_eq!(tag(&rx.recv().await.unwrap()), "n:0");
    waiting.await.unwrap();
    for n in 1..6 {
        assert_eq!(tag(&rx.recv().await.unwrap()), format!("n:{n}"));
    }
}

/// A hub that stopped taking notices is seen by the link, held back or not.
#[tokio::test]
async fn a_hub_that_stopped_is_seen() {
    let (hub, rx) = mpsc::channel(1);
    let outbox = NoticeOutbox::new(hub, scope());
    outbox.send(note(0)).await.unwrap();
    outbox.send(note(1)).await.unwrap();
    drop(rx);
    tokio::task::yield_now().await;
    let mut tries = 0;
    while outbox.send(note(2)).await.is_ok() {
        tries += 1;
        assert!(tries < 100, "the closed hub is seen");
        tokio::task::yield_now().await;
    }
    assert_eq!(outbox.send(note(3)).await, Err(Closed));
}
