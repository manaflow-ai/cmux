use super::*;

fn names(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| (*s).to_owned()).collect()
}

#[test]
fn the_closest_names_come_first_and_at_most_three() {
    let all = names(&["review-lane", "lane-2", "feed-lane", "lane", "zzz"]);
    assert_eq!(closest(&all, "lane"), ["lane", "lane-2", "feed-lane"]);
    // Nothing contains it: the nearest by edit distance, still three.
    let near = closest(&all, "feed-lan");
    assert_eq!((near[0].as_str(), near.len()), ("feed-lane", 3), "{near:?}");
    assert!(closest(&[], "lane").is_empty());
}

/// A peer's names are suggested whole under that peer (a nested `review/child` stays
/// so), and "no such session" on a peer is final only once its list was applied.
#[test]
fn a_peers_names_keep_their_path_and_count_once_listed() {
    use std::sync::atomic::Ordering::SeqCst;
    let hub =
        Hub::new(crate::config::Config::default(), Box::new(crate::store::MemoryStore::default()));
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new("b", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("b".into(), peer.clone());
    let rows = vec![
        serde_json::json!({"sessionId": "s1", "name": "review/child", "status": "ready"}),
        serde_json::json!({"sessionId": "s2", "name": "gone-lane", "status": "closed"}),
    ];
    hub.apply_peer_notice(
        "b",
        peer.generation,
        crate::peer::PeerNotice::sessions_from_values(rows),
    );
    let (text, data) = hub.no_session_text("b/review/chil");
    assert_eq!(text, "no session review/chil on b; did you mean: review/child", "{data}");
    assert_eq!(data["candidates"], serde_json::json!(["review/child"]));
    // Not connected, nothing listed: not final.
    assert!(!hub.no_session_is_final("b/x"));
    peer.connected.store(true, SeqCst);
    assert!(!hub.no_session_is_final("b/x"), "connected, list not applied yet");
    peer.rows_ready.store(true, SeqCst);
    assert!(hub.no_session_is_final("b/x"));
    // A name on this machine is always final.
    assert!(hub.no_session_is_final("nobody"));
    // Its link drops with the rows still cached: a send there is to a machine that is down.
    peer.connected.store(false, SeqCst);
    assert!(hub.resolve_remote("b/review/child").is_some(), "the row is still cached");
    assert!(hub.host_unreachable_for("b/review/child"));
    assert!(!hub.host_unreachable_for("nobody"), "a name here is no peer's");
}

#[test]
fn edit_distance() {
    assert_eq!(distance("kitten", "sitting"), 3);
    assert_eq!(distance("", "abc"), 3);
    assert_eq!(distance("same", "same"), 0);
}
