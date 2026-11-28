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
    // A request for it gets the retryable answer a peer that is down gives, not no session.
    let unlisted = hub.peer_unlisted_for("b/x").expect("its list is not in yet");
    assert_eq!(unlisted.data.as_ref().unwrap()["retryable"], true, "{unlisted:?}");
    assert!(hub.peer_down_for("b/x").is_none(), "the link is up");
    peer.rows_ready.store(true, SeqCst);
    assert!(hub.no_session_is_final("b/x"));
    assert!(hub.peer_unlisted_for("b/x").is_none(), "listed: no session is the answer");
    // A name on this machine is always final.
    assert!(hub.no_session_is_final("nobody"));
    // Its link drops with the rows still cached: a send there is to a machine that is down.
    peer.connected.store(false, SeqCst);
    assert!(hub.resolve_remote("b/review/child").is_some(), "the row is still cached");
    assert!(hub.host_unreachable_for("b/review/child"));
    assert!(!hub.host_unreachable_for("nobody"), "a name here is no peer's");
}

/// A send to a Claude Code chat by its id (Leo 2026-11-20: "isn't one I can message through
/// acpmux") names the register step: with the running chat's id and pid when this machine
/// runs it, as a possibility for a peer's.
#[test]
fn a_chat_named_by_its_id_names_the_register_step() {
    assert!(looks_like_session_id("6e0bad7d"));
    assert!(looks_like_session_id("6e0bad7d-9798-49c2-8d14-00d3d5ffeb25"));
    assert!(!looks_like_session_id("interim-coord"), "a name, not an id");
    assert!(!looks_like_session_id("6e0bad7"), "too short to be read as one");
    assert!(!looks_like_session_id("-6e0bad7d"));

    let peer = crate::claude_peers::Peer {
        pid: 4242,
        session_id: "6e0bad7d-9798-49c2-8d14-00d3d5ffeb25".into(),
        cwd: None,
        entrypoint: Some("claude-desktop".into()),
        kind: None,
        name: None,
        version: None,
        socket: None,
    };
    let running = unregistered_chat_text("mac-a", "6e0bad7d", true, Some(&peer));
    assert!(running.text.contains("process 4242"), "{}", running.text);
    assert!(
        running.text.contains("`acpmux register claude-desktop-6e0bad7d`")
            && running.text.ends_with("send to mac-a/claude-desktop-6e0bad7d"),
        "{}",
        running.text
    );
    assert_eq!(running.data["state"], "running");
    assert_eq!(running.data["pid"], 4242);

    let closed = unregistered_chat_text("here", "6e0bad7d", true, None);
    assert_eq!(closed.data["state"], "not_running", "{}", closed.text);
    let far = unregistered_chat_text("mac-a", "6e0bad7d", false, None);
    assert!(far.text.starts_with("if 6e0bad7d is a Claude Code chat"), "{}", far.text);
    assert_eq!(far.data["state"], "unknown");

    // Through the hub, a peer's id-like name says so, and a plain name keeps "did you mean".
    let hub =
        Hub::new(crate::config::Config::default(), Box::new(crate::store::MemoryStore::default()));
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let b = crate::peer::Peer::new("b", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("b".into(), b.clone());
    let (text, data) = hub.no_session_text("b/6e0bad7d");
    assert!(text.starts_with("no session 6e0bad7d on b; if 6e0bad7d is"), "{text}");
    assert_eq!(data["unregisteredChat"]["register"], "claude-code-6e0bad7d");
    let (text, data) = hub.no_session_text("b/interim-coord");
    assert!(!text.contains("acpmux register"), "{text}");
    assert!(data.get("unregisteredChat").is_none());
}

#[test]
fn edit_distance() {
    assert_eq!(distance("kitten", "sitting"), 3);
    assert_eq!(distance("", "abc"), 3);
    assert_eq!(distance("same", "same"), 0);
}
