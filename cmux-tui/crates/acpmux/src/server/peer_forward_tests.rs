use super::*;

#[tokio::test]
async fn a_moved_chat_wakes_its_parked_destination_through_its_original_id() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-moved-peer");
    let hub = Hub::started_lazily_for_test(dir.path(), 1).await;
    let id = "original-chat";
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "moved", "harness": "fake",
        "cwd": "/work", "status": "closed", "createdAt": 1, "updatedAt": 1,
        "movedTo": {"host": "m0", "sessionId": "m0-chat"}
    });
    hub.insert_test_session(serde_json::from_value(meta).unwrap());
    let params = json!({"sessionId": id});
    let peer = hub.peer_by_name("m0").unwrap();
    assert!(peer.idle_parked());
    assert!(target(&hub, method::SESSION_PROMPT, id).is_none());
    for m in [method::SESSION_PROMPT, method::MUX_ATTACH] {
        let (route, to, _, moved) = demand_target(&hub, m, &params).unwrap();
        assert!(moved && Arc::ptr_eq(&peer, &route));
        assert_eq!(to, "m0-chat");
    }
    assert!(demand_target(&hub, method::MUX_KILL, &params).is_none());
    let at_limit = json!({
        "sessionId": id, "_meta": {"acpmux": {"movedHops": crate::hub::MAX_MOVES_FOLLOWED}}
    });
    assert!(demand_target(&hub, method::SESSION_PROMPT, &at_limit).is_none());

    // The original id's attach uses that route to start the dial. On a failed dial, the
    // ordinary forwarding path still falls back to the local tombstone.
    crate::peer::test_dial::refuse_all();
    let mut settled = peer.settled();
    let attach = super::super::peer_demand_wait::use_peer(&hub, method::MUX_ATTACH, &params);
    tokio::pin!(attach);
    tokio::select! {
        biased;
        _ = settled.changed() => {},
        _ = &mut attach => {},
    }
    assert!(!crate::peer::test_dial::attempts().is_empty());
    assert!(target(&hub, method::MUX_ATTACH, id).is_none());
    hub.seed_peer_back(&peer, vec![]);
    let (route, to, _, moved) = target(&hub, method::MUX_ATTACH, id).unwrap();
    assert!(moved && Arc::ptr_eq(&peer, &route));
    assert_eq!(to, "m0-chat");
    hub.begin_shutdown();
    crate::peer::test_dial::clear();
}

/// A saved prompt's `name` is never a session's: no peer gets the library's requests.
#[test]
fn saved_prompts_stay_on_this_daemon() {
    for m in [
        method::MUX_PROMPTS_LIST,
        method::MUX_PROMPTS_SAVE,
        method::MUX_PROMPTS_DELETE,
        method::MUX_STASH_LIST,
        method::MUX_STASH_PUSH,
        method::MUX_STASH_GET,
        method::MUX_STASH_DROP,
        method::MUX_STASH_MOVE,
    ] {
        assert!(!names_a_session(m), "{m}");
    }
}

#[test]
fn a_forwarded_start_keeps_its_name_and_asks_to_keep_a_taken_one() {
    let mut p = json!({"_meta": {"acpmux": {
        "peer": "far-host", "name": "slam-09", "harness": "codex",
        "ifNameTaken": crate::hub::SUFFIX_TAKEN_NAME,
    }}});
    strip_new_meta(&mut p);
    assert_eq!(p["_meta"]["acpmux"]["name"], "slam-09");
    assert_eq!(p["_meta"]["acpmux"]["ifNameTaken"], "suffix");
    assert!(p["_meta"]["acpmux"].get("peer").is_none());
}

#[test]
fn a_peer_hold_attach_is_refused_before_forwarding() {
    let error = hold_attach_peer_refusal(&json!({"hold": true})).expect("refusal");
    assert_eq!(error.data.unwrap()["reason"], "attach_hold.peer_refused");
    assert!(hold_attach_peer_refusal(&json!({"hold": false})).is_none());
}

/// A registration's NAME is never a destination: it is not forwarded to a peer session of that
/// name, so the caller's messaging token never leaves this daemon.
#[test]
fn a_registration_is_never_forwarded_to_a_peer() {
    assert!(!names_a_session(method::MUX_REGISTER));
}

/// A call on another machine is answered by the machine it reached, never forwarded to a peer
/// chat its `session` (the caller's chat) or `name` (a tool) happens to name: forwarded, it
/// came back with its tool name dropped (`unknown Computer Use tool ""`).
#[test]
fn a_machine_call_is_never_forwarded_as_a_chat_request() {
    for m in [
        method::MUX_COMPUTER_USE_CALL,
        method::MUX_COMPUTER_USE_MACHINES,
        method::MUX_COMPUTER_USE_STATE,
        method::MUX_MACHINE_FILES_CALL,
        method::MUX_MACHINE_PORTS_CALL,
    ] {
        assert!(!names_a_session(m), "{m}");
    }
}

/// A phone's read of a peer chat keeps within the kinds an older peer takes: the sudo card's
/// kinds, which a peer chat never has, are dropped (review F1 of cc3c3cf).
#[test]
fn a_forwarded_read_leaves_the_sudo_card_kinds_here() {
    let kinds = [
        "transcript",
        "queue_updated",
        "queue_order",
        "queue_paused",
        "queue_resumed",
        "claude.system.api_retry",
        "bookmarks",
        "elevation_request",
        "elevation_decision",
    ];
    let mut p = json!({"sessionId": "s", "kinds": kinds});
    drop_local_kinds(&mut p);
    assert_eq!(p["kinds"], json!(&kinds[..7]));
    let mut none = json!({"sessionId": "s"});
    drop_local_kinds(&mut none);
    assert_eq!(none, json!({"sessionId": "s"}));
}

/// An explicit peer removal must release *every* upload waiting for the
/// reconnect. The old waiter listened only to completed connection attempts,
/// so an idle/stopped peer kept these calls for 30 seconds.
#[tokio::test]
async fn removed_peer_wakes_all_waiting_uploads_without_a_connect_attempt() {
    let (notices, _receiver) = tokio::sync::mpsc::channel(1);
    let peer = crate::peer::Peer::new("gone", "ws://127.0.0.1:9", None, None, notices);
    let mut pending = Vec::new();
    for _ in 0..2 {
        let peer = peer.clone();
        pending.push(tokio::spawn(async move {
            await_link(&peer, std::time::Duration::from_secs(30)).await
        }));
    }
    // Peer::run is deliberately absent: removal itself, not a later
    // connection outcome, must wake each waiter.
    tokio::task::yield_now().await;
    peer.stop();
    for task in pending {
        let result = tokio::time::timeout(std::time::Duration::from_secs(1), task)
            .await
            .expect("a stopped peer left its upload waiting for the 30 s timeout")
            .unwrap();
        assert!(!result, "stopped peer was reported ready");
    }
}

/// An upload for a peer whose link is down keeps waiting past one reinforce interval (the
/// old fixed 30 s refused it there while the app still waited), and ends at once, refused,
/// when the peer is removed.
#[tokio::test(start_paused = true)]
async fn an_upload_holds_for_the_link_past_one_reinforce_until_the_peer_goes() {
    let (notices, _receiver) = tokio::sync::mpsc::channel(1);
    let peer = crate::peer::Peer::new("down", "ws://127.0.0.1:9", None, None, notices);
    let held = tokio::spawn({
        let peer = peer.clone();
        async move { hold_upload_for_link(&peer).await }
    });
    tokio::time::sleep(PROMPT_LINK_REINFORCE * 3).await;
    assert!(!held.is_finished(), "the upload gave up while its client still waited");
    peer.stop();
    let ready = tokio::time::timeout(std::time::Duration::from_secs(1), held)
        .await
        .expect("a removed peer left its upload waiting")
        .unwrap();
    assert!(!ready, "a removed peer was reported ready");
}

/// A message for a down peer's session wakes the peer whoever sent it, a peer daemon's
/// forward of another daemon's send included; any other request from a peer daemon asks
/// nothing, and a client's wants the link back without asking its route to wake a machine.
#[test]
fn only_a_message_asks_a_down_peers_route_to_wake_it() {
    let peer = || {
        let (notices, _receiver) = tokio::sync::mpsc::channel(1);
        crate::peer::Peer::new("fs-lane-3", "ssh://fs-lane-3", None, None, notices)
    };
    let none = json!({});
    for origin in [Origin::Peer, Origin::Local, Origin::Web] {
        let p = peer();
        ask_back(&p, method::SESSION_PROMPT, &none, origin);
        assert!(p.waking() && p.is_wanted(), "{origin:?}");
    }
    let p = peer();
    ask_back(&p, method::MUX_ATTACH, &none, Origin::Peer);
    assert!(!p.waking() && !p.is_wanted());
    let p = peer();
    ask_back(&p, method::MUX_ATTACH, &none, Origin::Local);
    assert!(!p.waking() && p.is_wanted());
}

/// A person starting to write to a down peer's chat wakes the peer before they send: typing
/// on, or surface text that is not blank. Typing off, cleared text and a saved draft only
/// want the link back, and a peer daemon's forward of any of them asks nothing. Typing,
/// which `forward_inner` answers itself, wakes through `wake_if_composing` there.
#[test]
fn typing_to_a_down_peers_chat_wakes_it_before_the_send() {
    let peer = || {
        let (notices, _receiver) = tokio::sync::mpsc::channel(1);
        crate::peer::Peer::new("fs-lane-3", "ssh://fs-lane-3", None, None, notices)
    };
    let writing = [
        (method::MUX_TYPING, json!({"sessionId": "s", "on": true})),
        (method::MUX_COMPOSER_SET, json!({"sessionId": "s", "surface": "pane", "text": "h"})),
    ];
    for (m, params) in &writing {
        for origin in [Origin::Local, Origin::Web] {
            let p = peer();
            ask_back(&p, m, params, origin);
            assert!(p.waking() && p.is_wanted(), "{m} from {origin:?}");
        }
        let p = peer();
        ask_back(&p, m, params, Origin::Peer);
        assert!(!p.waking() && !p.is_wanted(), "{m} forwarded by a peer daemon");
    }
    let idle = [
        (method::MUX_TYPING, json!({"sessionId": "s", "on": false})),
        (method::MUX_COMPOSER_SET, json!({"sessionId": "s", "surface": "pane", "text": "  \n"})),
        // The pane saves the chat it leaves as is: a draft write is no one typing.
        (method::MUX_DRAFT_SET, json!({"sessionId": "s", "text": "fix the"})),
        (method::MUX_COMPOSER_SET, json!({"sessionId": "s", "surface": "pane", "text": ""})),
    ];
    for (m, params) in &idle {
        let p = peer();
        ask_back(&p, m, params, Origin::Local);
        assert!(!p.waking() && p.is_wanted(), "{m} with nothing written");
    }
    let p = peer();
    assert!(wake_if_composing(&p, method::MUX_TYPING, &writing[0].1, Origin::Local));
    assert!(p.waking());
    let p = peer();
    assert!(!wake_if_composing(&p, method::MUX_TYPING, &writing[0].1, Origin::Peer));
    assert!(!p.waking() && !p.is_wanted());
}

/// A refused answer for a peer's prompt names that peer, so the app can say where to
/// enroll this Mac; a peer the answer named itself is replaced by this daemon's name.
#[test]
fn a_refused_answer_names_the_peer() {
    let e = name_peer(crate::hub::person::person_required("allowing a permission"), "hb");
    assert_eq!(e.data.as_ref().unwrap()["peer"], "hb");
    assert_eq!(e.data.as_ref().unwrap()["reason"], crate::hub::person::REASON);
    let e = name_peer(RpcError::internal("x").with_data(json!({"peer": "far"})), "hb");
    assert_eq!(e.data.unwrap()["peer"], "hb");
}

/// A peer's group read: the person here whose app holds this Mac's key draws Allow once and
/// Deny when the peer counts a Mac's signed allow; every other reader, or a peer that does
/// not say so, draws no Allow.
#[test]
fn a_peers_group_read_draws_allow_once_only_for_a_mac_that_signs() {
    let read = || {
        json!({"groups": [{"decisions": ["allow_once", "allow_chat", "deny"]}],
               "allowRefused": crate::hub::person::REASON, "macAllowOnce": true})
    };
    let mut r = read();
    mac_group_read(&mut r, true);
    assert!(r.get("allowRefused").is_none(), "{r}");
    assert_eq!(r["groups"][0]["decisions"], json!(["allow_once", "deny"]));
    let mut r = read();
    mac_group_read(&mut r, false);
    assert_eq!(r["allowRefused"], crate::hub::person::REASON);
    assert_eq!(r["groups"][0]["decisions"].as_array().unwrap().len(), 3);
    for old in [json!({"groups": []}), json!({"groups": [], "macAllowOnce": false})] {
        let mut r = old;
        mac_group_read(&mut r, true);
        assert_eq!(r["allowRefused"], crate::hub::person::REASON, "{r}");
    }
}

/// A history read forwarded to a peer names its byte limit: a peer on an older build pages to
/// no limit of its own, and 5000 records of long tool outputs were one 32.8 MB reply that reset
/// the link with its 29 chats (2026-10-21).
#[test]
fn a_forwarded_history_read_names_its_byte_limit() {
    for m in [method::MUX_ATTACH, method::MUX_EVENTS] {
        let mut p = json!({"sessionId": "s", "limit": 5000});
        bound_page(m, &json!({"limit": 5000}), &mut p);
        assert_eq!(p["maxBytes"], crate::hub::page_bytes(&json!({})), "{m}");
        // A limit the client asked for goes as this daemon caps it.
        let mut p = json!({"sessionId": "s"});
        bound_page(m, &json!({"maxBytes": 1u64 << 40}), &mut p);
        assert_eq!(p["maxBytes"], crate::hub::MAX_PAGE_BYTES, "{m}");
    }
    let mut p = json!({"sessionId": "s"});
    bound_page(method::SESSION_PROMPT, &json!({}), &mut p);
    assert!(p.get("maxBytes").is_none());
}
