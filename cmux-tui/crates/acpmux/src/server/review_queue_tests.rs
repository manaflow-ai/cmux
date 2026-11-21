use super::*;

#[test]
fn a_comment_goes_with_changes_only_and_is_bounded() {
    let p = |c: Value| json!({"comment": c});
    assert_eq!(review_comment(&json!({}), false).unwrap(), None);
    assert_eq!(review_comment(&p(json!("  ")), false).unwrap(), None);
    assert_eq!(
        review_comment(&p(json!(" Add a test. ")), false).unwrap().as_deref(),
        Some("Add a test.")
    );
    assert!(review_comment(&p(json!("Nice")), true).is_err());
    assert!(review_comment(&p(json!(3)), false).is_err());
    assert!(review_comment(&p(json!("x".repeat(COMMENT_BYTES + 1))), false).is_err());
    assert_eq!(
        changes_prompt("https://github.com/o/r/pull/7", "Add a test."),
        "Changes requested on https://github.com/o/r/pull/7:\n\nAdd a test."
    );
}

#[test]
fn a_peers_own_cut_counts_in_the_total() {
    assert_eq!(peer_cut(&json!({"items": [], "total": 250}), 200), 50);
    assert_eq!(peer_cut(&json!({"items": []}), 200), 0);
    assert_eq!(peer_cut(&json!({"total": 3}), 3), 0);
    assert_eq!(peer_cut(&json!({"total": "many"}), 3), 0);
}

#[test]
fn only_this_daemons_own_clients_ask_the_peers() {
    assert!(asks_peers(Origin::Local, &json!({})));
    assert!(asks_peers(Origin::LocalApp, &json!({})));
    assert!(!asks_peers(Origin::Local, &json!({LOCAL_ONLY: true})));
    assert!(!asks_peers(Origin::Peer, &json!({})));
    assert!(!asks_peers(Origin::Web, &json!({})));
}

#[test]
fn the_queue_is_never_a_web_clients_even_through_a_peer() {
    use super::super::ConnAuth;
    let web = json!({"_meta": {"acpmux": {"via": "web"}}});
    assert!(!queue_served(Origin::Peer, ConnAuth::PeerToken, &web));
    assert!(!queue_served(Origin::Peer, ConnAuth::Device, &web));
    assert!(!queue_served(Origin::Web, ConnAuth::ListenerToken, &json!({})));
    assert!(!queue_served(Origin::Local, ConnAuth::None, &json!({})));
    assert!(queue_served(Origin::Peer, ConnAuth::PeerToken, &json!({})));
    assert!(queue_served(Origin::Local, ConnAuth::LocalSocket, &json!({})));
    assert!(queue_served(Origin::LocalApp, ConnAuth::LocalApp, &json!({})));
}

#[test]
fn the_audit_and_verdicts_are_local_only() {
    assert!(local_only(Origin::Local, "m").is_ok());
    assert!(local_only(Origin::LocalApp, "m").is_ok());
    assert!(local_only(Origin::Peer, "m").is_err());
    assert!(local_only(Origin::Web, "m").is_err());
}
