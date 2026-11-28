use super::*;

fn hub() -> (Arc<Hub>, cmux_unix_socket::TestDir) {
    let dir = cmux_unix_socket::short_test_dir("acpmux-rc");
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir.path()).unwrap();
    (Hub::new(cfg, store), dir)
}

/// A session created on a peer resolves by its name before the peer lists it, bare and as
/// `PEER/NAME`; a row the peer lists itself is not replaced by the record.
#[tokio::test]
async fn a_session_created_on_a_peer_resolves_by_name_before_the_peer_lists_it() {
    let (hub, _dir) = hub();
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new("lane3", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("lane3".into(), peer);
    assert!(hub.resolve_remote("lane-router").is_none());
    hub.note_created_remote("lane3", "0199aaaa-0000-7000-8000-000000000001", Some("lane-router"));
    for key in ["lane-router", "lane3/lane-router"] {
        let (p, id, _) = hub.resolve_remote(key).unwrap_or_else(|| panic!("{key}"));
        assert_eq!(
            (p.name.as_str(), id.as_str()),
            ("lane3", "0199aaaa-0000-7000-8000-000000000001")
        );
    }
    // Noted again (a retried create) it stays one row.
    hub.note_created_remote("lane3", "0199aaaa-0000-7000-8000-000000000001", Some("lane-router"));
    assert_eq!(hub.remote_matches("lane-router"), 1);
}

/// A session started through the hub on a host with no peer link is found by the record.
#[test]
fn a_hub_started_session_resolves_from_the_record_until_the_book_lists_it() {
    let (hub, _dir) = hub();
    assert!(hub.mesh_book_handle("lane-router").is_none());
    hub.note_created_remote("vm-3", "id-1", Some("lane-router"));
    let want = Some(("vm-3".to_owned(), "id-1".to_owned()));
    assert_eq!(hub.mesh_book_handle("lane-router"), want);
    assert_eq!(hub.mesh_book_handle("vm-3/lane-router"), want);
    assert!(hub.mesh_book_handle("other").is_none());
}
