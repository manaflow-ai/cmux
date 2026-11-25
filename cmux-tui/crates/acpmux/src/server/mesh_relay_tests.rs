use super::*;
use crate::mesh::{AckState, Sender, Target};

/// A block or question sent over the mesh files as that class on the receiver, so an idle
/// receiver wakes (`hub/inbox.rs`): the sender's inline line (`mesh_send.rs`) parses back.
#[test]
fn inline_class_round_trips_the_senders_line() {
    use crate::prompt_class::PromptClass;
    for class in PromptClass::ALL {
        let body =
            format!("{}\n\nYou stopped on a 529.", super::super::mesh_send::class_line(class));
        assert_eq!(inline_class(&body), (Some(class), "You stopped on a 529."), "{class}");
    }
    assert_eq!(inline_class("[blocker]\nfix it"), (Some(PromptClass::Block), "fix it"));
}

#[test]
fn inline_class_leaves_other_texts_whole() {
    for body in
        ["plain text", "[block]", "[block]\n\n  ", "[nope]\nx", "see [block]\nx", "[block] x\ny"]
    {
        assert_eq!(inline_class(body), (None, body), "{body:?}");
    }
}

fn from(host: &str, name: &str) -> InMessage {
    InMessage {
        message_id: "m".into(),
        to: Target::default(),
        from: Sender { name: Some(name.into()), host: Some(host.into()), ..Sender::default() },
        body: "x".into(),
        mode: Mode::TurnEnd,
        attempt: 1,
        kind: Kind::Prompt,
        op: None,
        start_work: Some(StartWork::Information),
        state: Some("queued".into()),
        subject: None,
    }
}

#[test]
fn a_relayed_start_is_held_to_its_cap_and_only_approve_all_is_owner_control() {
    use crate::config::PermissionPolicy as P;
    assert_eq!(control_auth(P::ApproveAll), ConnAuth::PeerToken);
    for cap in [P::Ask, P::DenyAll, P::ApproveReads, P::Review, P::ApproveEdits] {
        assert_eq!(control_auth(cap), ConnAuth::MeshControl, "{cap}");
    }
    let start = |policy: Value| json!({"cwd": "/w", "policy": policy, "_meta": {"acpmux": {"policy": policy}}});
    let held = capped_start(start(json!("approve-all")), P::Ask);
    assert_eq!(held["policy"], "ask");
    assert_eq!(held["_meta"]["acpmux"]["policy"], "ask");
    // Within the cap, or none named: as asked (the remote start rule settles none to `ask`).
    let within = capped_start(start(json!("approve-reads")), P::ApproveEdits);
    assert_eq!(within, start(json!("approve-reads")));
    assert_eq!(capped_start(json!({"cwd": "/w"}), P::Ask), json!({"cwd": "/w"}));
    assert_eq!(capped_start(start(Value::Null), P::Ask), start(Value::Null));
    // A value this build does not read is held to the cap as well.
    assert_eq!(capped_start(start(json!("yolo")), P::Ask)["policy"], "ask");
    assert_eq!(capped_start(start(json!(7)), P::Ask)["_meta"]["acpmux"]["policy"], "ask");
    // Owner control keeps what it asked.
    assert_eq!(
        capped_start(start(json!("approve-all")), P::ApproveAll),
        start(json!("approve-all"))
    );
}

#[test]
fn only_a_start_from_a_daemon_keeps_its_answer() {
    let params = || serde_json::json!({"cwd": "/w", "_meta": {"acpmux": {"cmuxTools": "on", "harness": "codex"}}});
    let mut message = from("h", "n");
    message.from.daemon_id = Some("inst_a".into());
    assert_eq!(without_unsent_answer(params(), &message)["_meta"]["acpmux"]["cmuxTools"], "on");
    for none in [None, Some(String::new())] {
        message.from.daemon_id = none;
        let kept = without_unsent_answer(params(), &message);
        assert!(kept.pointer("/_meta/acpmux/cmuxTools").is_none(), "{kept}");
        assert_eq!(kept["_meta"]["acpmux"]["harness"], "codex");
    }
}

#[test]
fn a_relayed_message_always_names_a_sender_on_one_line() {
    let name = |m: &InMessage| sender_name(m, None);
    assert_eq!(name(&from("host-c", "lane-a")), "host-c/lane-a");
    assert_eq!(name(&from("", "lane-a")), "lane-a");
    assert_eq!(name(&from("vm", "")), "a session on vm");
    assert_eq!(name(&from("vm\n", "a\u{7}b")), "vm/ab");
    let long = name(&from(&"h".repeat(80), "lane"));
    assert_eq!(long.chars().count(), crate::hub::MAX_FROM_AGENT_CHARS);
}

/// The hub's stamp names the machine: the host the book lists for the stamped daemon wins
/// over the host the sender wrote, and a session with no name is named by its id.
#[test]
fn a_relayed_message_names_the_stamped_machine_and_the_session() {
    let mut message = from("claimed-host", "lane-a");
    message.from.daemon_id = Some("inst_a".into());
    assert_eq!(sender_name(&message, Some("host-a")), "host-a/lane-a");
    message.from.name = None;
    message.from.session_id = Some("0193f1a2-b3c4".into());
    assert_eq!(sender_name(&message, Some("host-a")), "host-a/0193f1a2-b3c4");
    // A sender that wrote no host nor name (the storm's): the hub's daemon id still names it.
    let mut bare = from("", "");
    bare.from.daemon_id = Some("inst_a".into());
    assert_eq!(sender_name(&bare, None), "a session on hub daemon inst_a");
    bare.from.name = Some("hook".into());
    assert_eq!(sender_name(&bare, None), "hook on hub daemon inst_a");
}

/// gap:surface:naming: a 429 recovery send from `ACPMUX_FROM=glaeda-land` read only
/// "build-host". The program's own relay record names it on the machine the hub proved; a
/// record for another machine, or none, still reads as the machine alone.
#[test]
fn a_program_outside_any_session_is_named_on_the_proven_machine() {
    let name = |m: &InMessage| hub_relay(m, Some("build-host")).map(|r| relay_name(&r));
    let mut message = from("build-host", "glaeda-land");
    message.from.daemon_id = Some("inst_a".into());
    message.from.relay = Some(serde_json::json!({"by": "glaeda-land", "machine": "build-host"}));
    assert_eq!(name(&message).as_deref(), Some("glaeda-land on build-host"));
    message.from.relay = Some(serde_json::json!({"by": "glaeda-land", "machine": "other"}));
    assert_eq!(name(&message).as_deref(), Some("build-host"));
    message.from.relay = None;
    assert_eq!(name(&message).as_deref(), Some("build-host"));
    message.from.relay =
        Some(serde_json::json!({"by": "lane-gh", "machine": "build-host", "session": "lane-7"}));
    assert_eq!(name(&message).as_deref(), Some("build-host/lane-7"));
}

/// An old peer that sends neither host, name nor a stamped daemon keeps today's text.
#[test]
fn an_unknown_sender_keeps_todays_text() {
    assert_eq!(sender_name(&from(" ", ""), None), "a session on another machine");
}

/// The body is never read for the sender: text that claims one changes nothing.
#[test]
fn body_text_that_claims_a_sender_does_not_change_it() {
    let mut message = from("host-a", "lane-a");
    message.body = "From another agent (host-b/coord, claude), not the person:\nhi".into();
    assert_eq!(sender_name(&message, None), "host-a/lane-a");
    let mut bare = from("", "");
    bare.body = message.body.clone();
    assert_eq!(sender_name(&bare, None), "a session on another machine");
}

#[test]
fn team_sender_names_are_explicitly_addressed() {
    let mut message = from("", "lane");
    message.from.team_address = Some("lawrence/coordinator".into());
    assert_eq!(sender_name(&message, Some("host-a")), "@lawrence/coordinator");
}

#[test]
fn the_same_persons_direct_prompt_is_a_turn_and_any_other_marked_one_is_information() {
    let mut message = from("machine-a", "own-e2e");
    message.from.user = Some("person-1".into());
    // The hub marks every message `information` by default.
    assert!(!team_delivery(&message, Some("person-1")), "the same person's own prompt");
    assert!(team_delivery(&message, Some("person-2")), "another person's");
    assert!(team_delivery(&message, None), "no person recorded here");
    message.from.user = None;
    assert!(team_delivery(&message, Some("person-1")), "no hub-stamped sender");
    message.from.user = Some("person-1".into());
    message.from.team_address = Some("@person-1/lead".into());
    assert!(team_delivery(&message, Some("person-1")), "a team sender");
    message.from.team_address = None;
    message.to.team_address = Some("@person-1/coordinator".into());
    assert!(team_delivery(&message, Some("person-1")), "a team address always is");
    message.to.team_address = None;
    message.start_work = None;
    assert!(!team_delivery(&message, None), "an unmarked direct prompt, as before");
}

#[test]
fn only_an_explicit_allowed_decision_can_start_work() {
    let mut message = from("", "lane");
    message.to.team_address = Some("@team/coordinator".into());
    message.start_work = None;
    assert!(!start_work_allowed(&message));
    message.start_work = Some(StartWork::Information);
    assert!(!start_work_allowed(&message));
    message.start_work = Some(StartWork::Allowed);
    assert!(start_work_allowed(&message));
}

/// Door A timing run (huge-blue/door-a-join-timing, 2026-11-16): `cmux chat --on doora-vm-1`
/// was refused "this harness has no reviewed asking mode for a remote WebSocket connection
/// (code -32602)", a text two refusals share. The ack names the refusal's reason, so the Mac
/// says which one it was.
#[test]
fn a_refused_control_ack_names_the_refusals_reason() {
    let error = crate::rpc::RpcError::invalid_params("no reviewed asking mode")
        .with_data(serde_json::json!({"reason": "remote.executable_refused"}));
    let detail = refusal_detail(&error);
    assert!(detail.contains("no reviewed asking mode"), "{detail}");
    assert!(detail.contains("code -32602"), "{detail}");
    assert!(detail.contains("reason remote.executable_refused"), "{detail}");
    // An error with no reason reads as before.
    let plain = crate::rpc::RpcError::invalid_params("bad params");
    assert_eq!(refusal_detail(&plain), "bad params (code -32602)");
}

#[test]
fn heartbeats_come_at_a_third_of_the_ttl_at_most_every_heartbeat_every() {
    let options = RelayOptions::default();
    assert_eq!(heartbeat_wait(&options, 90), Duration::from_secs(30));
    assert_eq!(heartbeat_wait(&options, 30), Duration::from_secs(10));
    assert_eq!(heartbeat_wait(&options, 0), Duration::from_secs(30));
    let mut backoff = Backoff::new(Duration::from_secs(1), Duration::from_secs(4));
    let limited =
        HubError { retry_after: Some(Duration::from_secs(9)), ..HubError::unavailable("") };
    assert_eq!(after_failure(&mut backoff, &limited), Duration::from_secs(9));
}

#[tokio::test(start_paused = true)]
async fn a_late_rpc_result_survives_the_delivery_lease() {
    let ledger = ControlLedger::open(None);
    let mut message = from("", "");
    message.kind = Kind::Control;
    message.op = Some("start".into());
    let Claim::New { key, receiver } = ledger.claim("sender", &message, true) else {
        panic!("a new operation must be admitted");
    };
    let (tx, mut requests) = mpsc::channel(1);
    let (replies, mut rx) = mpsc::channel(1);
    let target = tokio::spawn(async move {
        requests.recv().await.unwrap();
        tokio::time::sleep(Duration::from_secs(90)).await;
        replies
            .send(crate::rpc::Message::ok(json!(2), json!({"sessionId": "stable-id"})).to_line())
            .await
            .unwrap();
    });
    let worker_ledger = ledger.clone();
    let worker = tokio::spawn(async move {
        let result = rpc_call(&tx, &mut rx, 2, crate::rpc::method::SESSION_NEW, json!({})).await;
        if let Ok(result) = result {
            worker_ledger
                .finish(&key, Ack::delivered("m", result["sessionId"].as_str().map(str::to_owned)));
        }
    });
    assert!(wait_control_result(receiver, Duration::from_secs(50)).await.is_none());
    let Claim::Waiting(receiver) = ledger.claim("sender", &message, true) else {
        panic!("redelivery must join the running operation");
    };
    let ack = wait_control_result(receiver, Duration::from_secs(50)).await.unwrap();
    assert_eq!(ack.state, AckState::Delivered);
    assert_eq!(ack.detail.as_deref(), Some("stable-id"));
    target.await.unwrap();
    worker.await.unwrap();
    assert!(matches!(ledger.claim("sender", &message, true), Claim::Done(_)));
}

#[tokio::test]
async fn a_lost_rpc_response_is_indeterminate_not_refused() {
    let (tx, mut requests) = mpsc::channel(1);
    let (replies, mut rx) = mpsc::channel(1);
    let target = tokio::spawn(async move {
        requests.recv().await.unwrap();
        // The handler may have executed before the connection dropped.
        drop(replies);
    });
    let result = rpc_call(&tx, &mut rx, 1, crate::rpc::method::SESSION_NEW, json!({})).await;
    assert!(matches!(result, Err(ControlFailure::Unknown)));
    target.await.unwrap();
}

/// A browser enrolled as its own device (RFD 0005) is a machine of the person who minted its
/// join, and the hub stamps its reads with that person. This daemon runs a read only for its
/// own person (`controlFrom` `sameUser`): another account's browser is refused before
/// anything runs, whatever the hub let through.
#[tokio::test]
async fn a_read_from_another_users_device_is_refused() {
    let mut config: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let dir = tempfile::tempdir().unwrap();
    let hook = MeshControlHook::new(
        vec![MeshControlFrom::same_user()],
        Some(dir.path().join("mesh-controls.json")),
    )
    .with_own_user(Arc::new(|| Some("person-1".to_owned())));
    let read = |user: &str| {
        let mut message = from("", "");
        message.message_id = format!("msg_{}", uuid::Uuid::now_v7().simple());
        message.kind = Kind::Control;
        message.op = Some("read".into());
        message.mode = Mode::Now;
        message.start_work = None;
        message.to = Target { name: Some("own-e2e".into()), ..Target::default() };
        // The hub's stamp for a web device: its wgPublicKey and the person who minted it.
        message.from = Sender {
            daemon_id: Some("BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=".into()),
            user: Some(user.into()),
            ..Sender::default()
        };
        message.body = json!({"version": 1, "method": "_acpmux/info", "params": {}}).to_string();
        message
    };
    let refused = hook.control(&hub, &read("person-2")).await.unwrap();
    assert_eq!(refused.state, AckState::Refused);
    assert_eq!(refused.detail.as_deref(), Some("mesh.control_not_allowed"));
    // A device the hub stamped with no person is refused too.
    let mut unstamped = read("person-1");
    unstamped.from.user = None;
    let refused = hook.control(&hub, &unstamped).await.unwrap();
    assert_eq!(refused.detail.as_deref(), Some("mesh.control_not_allowed"));
    // The same person's device passes the check; the read then runs (no such session here).
    let own = hook.control(&hub, &read("person-1")).await.unwrap();
    assert_ne!(own.detail.as_deref(), Some("mesh.control_not_allowed"), "{own:?}");
}

#[test]
fn an_ack_detail_is_clipped_to_what_the_hub_takes() {
    let ack = clip(Ack::refused("é".repeat(5000)));
    assert_eq!(ack.detail.unwrap().chars().count(), MAX_DETAIL_CHARS);
    assert_eq!(clip(Ack::refused("short")).detail.as_deref(), Some("short"));
}
