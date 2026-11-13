use super::*;

fn list(n: u64) -> PeerNotice {
    PeerNotice::Sessions(vec![json!({"sessionId": "s0", "updatedAt": n})])
}

fn changed(n: u64) -> PeerNotice {
    PeerNotice::SessionChanged {
        session: json!({"sessionId": "s0", "updatedAt": n}),
        kind: "status".into(),
        seq: n,
    }
}

fn at(n: &PeerNotice) -> (char, u64) {
    match n {
        PeerNotice::Sessions(rows) => ('L', rows[0]["updatedAt"].as_u64().unwrap()),
        PeerNotice::SessionChanged { seq, .. } => ('C', *seq),
        PeerNotice::Connected => ('+', 0),
        other => panic!("{other:?}"),
    }
}

/// A newer list from a peer takes its older one's slot; the queue yields only the newest, at
/// its own place: after what was sent before it, before what was sent after it.
#[tokio::test]
async fn a_newer_list_supersedes_the_older_and_keeps_its_place() {
    let (tx, mut rx) = channel(64);
    for notice in
        [list(1), changed(1), PeerNotice::Connected, list(2), changed(2), list(3), changed(3)]
    {
        tx.send(("p".into(), 7, notice)).await.unwrap();
    }
    // Another peer's list is its own.
    tx.send(("q".into(), 1, list(9))).await.unwrap();
    let status = tx.lists_status();
    assert_eq!(status["pendingLists"], 2, "{status}");
    assert_eq!(status["superseded"], 2, "{status}");
    drop(tx);
    let mut seen = Vec::new();
    while let Some((peer, _, notice)) = rx.recv().await {
        seen.push((peer, at(&notice)));
    }
    let p = |c, n| ("p".to_owned(), (c, n));
    assert_eq!(
        seen,
        vec![p('C', 1), p('+', 0), p('C', 2), p('L', 3), p('C', 3), ("q".to_owned(), ('L', 9)),]
    );
}

/// The same name under another generation (a replaced peer) keeps its own slot.
#[tokio::test]
async fn a_replaced_peer_s_list_is_not_superseded_by_the_old_one() {
    let (tx, mut rx) = channel(8);
    tx.send(("p".into(), 1, list(1))).await.unwrap();
    tx.send(("p".into(), 2, list(2))).await.unwrap();
    drop(tx);
    let mut got = Vec::new();
    while let Some((_, generation, notice)) = rx.recv().await {
        got.push((generation, at(&notice).1));
    }
    assert_eq!(got, vec![(1, 1), (2, 2)]);
}

/// A plain channel passes every notice through as sent.
#[tokio::test]
async fn a_plain_sender_passes_lists_through() {
    let (tx, mut rx) = mpsc::channel(8);
    let tx = NoticeSender::from(tx);
    tx.send(("p".into(), 1, list(1))).await.unwrap();
    tx.send(("p".into(), 1, list(2))).await.unwrap();
    assert!(tx.lists_status().is_null());
    assert_eq!(at(&rx.recv().await.unwrap().2), ('L', 1));
    assert_eq!(at(&rx.recv().await.unwrap().2), ('L', 2));
}
