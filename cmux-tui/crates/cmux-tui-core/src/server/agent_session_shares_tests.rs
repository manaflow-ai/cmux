//! Link shares: the owner's verbs, redeem, the guest binding, expiry and a restart.
use super::*;
use crate::server::agent_session_attach_tests::{
    Client, FakeAcpmux, SESSION, WAIT, agent_tab, assert_code, mux_with, terminal_pane,
};
use crate::server::{
    BoundedOutbound, ClientTransport, ConnectionSurfaceScheduler, QueuedSink,
    handle_connection_frame,
};

fn create(owner: &mut Client, surface: u64, extra: Value) -> Value {
    let mut frame = json!({"cmd":"agent-session-share-create", "surface":surface});
    for (key, value) in extra.as_object().unwrap() {
        frame[key] = value.clone();
    }
    let reply = owner.request(frame);
    assert_eq!(reply["ok"], true, "{reply}");
    reply["data"].clone()
}

fn redeem(owner: &mut Client, share: &Value, name: &str, attempt: &str) -> Value {
    owner.request(json!({"cmd":"agent-session-share-redeem", "share_id":share["share_id"],
        "secret":share["secret"], "name":name, "attempt_id":attempt}))
}

fn list(owner: &mut Client) -> Value {
    let reply = owner.request(json!({"cmd":"agent-session-share-list"}));
    assert_eq!(reply["ok"], true, "{reply}");
    reply["data"]["shares"].clone()
}

fn bind(mux: &Arc<Mux>, share: &Value, guest: &Value, label: &str) -> (Client, Value) {
    let mut client = Client::connect(mux, label);
    let reply = client.request(json!({"cmd":"agent-session-proxy-bind",
        "link_guest": {"share_id": share["share_id"], "guest_id": guest["data"]["guest_id"]}}));
    (client, reply)
}

/// Waits (bounded) until no guest connection stays bound: the daemon closed them.
fn wait_unbound(mux: &Mux, count: usize) {
    let deadline = std::time::Instant::now() + WAIT;
    while mux.control_clients.agent_sessions.proxy_authors.lock().unwrap().len() != count {
        assert!(std::time::Instant::now() < deadline, "the guest connection is closed");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn the_owner_creates_lists_kicks_and_revokes() {
    let fake = FakeAcpmux::start("share-verbs");
    let mux = mux_with(&fake, "share-verbs");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-verbs-owner");
    let share = create(&mut owner, surface, json!({}));
    assert_eq!((share["session"].clone(), share["uses_left"].clone()), (json!(SESSION), json!(1)));
    assert!(share["url"].is_null());
    assert_eq!(share["share_id"].as_str().unwrap().len(), 22, "128 bits, base64url");
    assert_eq!(share["secret"].as_str().unwrap().len(), 22);
    let (terminal, _) = terminal_pane(&mux);
    let refused = owner.request(json!({"cmd":"agent-session-share-create", "surface":terminal}));
    assert_code(&refused, "share.not_a_chat");
    for bad in [
        json!({"ttl_secs":59}),
        json!({"ttl_secs":604_801}),
        json!({"uses":0}),
        json!({"uses":9}),
        json!({"pane":1}),
    ] {
        let mut frame = json!({"cmd":"agent-session-share-create", "surface":surface});
        frame.as_object_mut().unwrap().extend(bad.as_object().unwrap().clone());
        assert_code(&owner.request(frame), "share.bad_request");
    }
    let shares = list(&mut owner);
    assert_eq!(shares.as_array().unwrap().len(), 1);
    assert_eq!(shares[0]["state"], "active");
    assert!((86_390..=86_400).contains(&shares[0]["expires_in_secs"].as_u64().unwrap()));
    let text = shares.to_string();
    assert!(!text.contains(share["secret"].as_str().unwrap()) && !text.contains("sha256"));
    let guest = redeem(&mut owner, &share, "Theo", "attempt-1");
    assert_eq!(guest["data"]["guest_id"].as_str().unwrap().len(), 11, "64 bits, base64url");
    let kick = json!({"cmd":"agent-session-share-kick", "share_id":share["share_id"],
        "guest_id":guest["data"]["guest_id"]});
    assert_eq!(owner.request(kick)["ok"], true);
    assert_eq!(list(&mut owner)[0]["guests"][0]["state"], "kicked");
    // The kicked guest's redeem, replayed with its attempt and the secret, stays refused.
    assert_code(&redeem(&mut owner, &share, "Theo", "attempt-1"), "share.kicked");
    assert_code(&bind(&mux, &share, &guest, "share-verbs-kicked").1, "agent_session.share_ended");
    let revoke = json!({"cmd":"agent-session-share-revoke", "share_id":share["share_id"]});
    assert_eq!(owner.request(revoke)["ok"], true);
    assert_eq!(list(&mut owner)[0]["state"], "revoked");
    assert_code(&redeem(&mut owner, &share, "Ann", "attempt-2"), "share.revoked");
    let unknown = json!({"cmd":"agent-session-share-revoke", "share_id":"nope"});
    assert_code(&owner.request(unknown), "share.unknown");
    let no_guest = json!({"cmd":"agent-session-share-kick", "share_id":share["share_id"]});
    assert_code(&owner.request(no_guest), "share.bad_request");
    // The session the caller named pins the chat: a surface that shows another one now is refused,
    // and the one it shows is accepted.
    let moved = owner.request(json!({"cmd":"agent-session-share-create", "surface":surface,
        "session":"acp_other"}));
    assert_code(&moved, "share.chat_moved");
    let pinned = create(&mut owner, surface, json!({"session": SESSION, "create_id": "req-1"}));
    assert_eq!(pinned["session"], json!(SESSION));
    // The create's own id is in the list, so a client whose create went unanswered ends that share.
    let listed = list(&mut owner);
    let mine: Vec<&Value> =
        listed.as_array().unwrap().iter().filter(|s| s["create_id"] == "req-1").collect();
    assert_eq!(mine.len(), 1);
    assert_eq!(mine[0]["share_id"], pinned["share_id"]);
    for bad in [json!(""), json!("x".repeat(65))] {
        let refused = owner.request(json!({"cmd":"agent-session-share-create", "surface":surface,
            "create_id": bad}));
        assert_code(&refused, "share.bad_request");
    }
}

#[test]
fn a_link_works_once_and_a_retried_redeem_gets_the_same_guest() {
    let fake = FakeAcpmux::start("share-once");
    let mux = mux_with(&fake, "share-once");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-once-owner");
    let share = create(&mut owner, surface, json!({}));
    // A wrong secret spends nothing; then two redeems at once: exactly one wins.
    let wrong = owner
        .request(json!({"cmd":"agent-session-share-redeem", "share_id":share["share_id"],
        "secret":"AAAAAAAAAAAAAAAAAAAAAA", "name":"Eve", "attempt_id":"x"}));
    assert_code(&wrong, "share.secret");
    let barrier = Arc::new(std::sync::Barrier::new(2));
    let racers: Vec<_> = ["a1", "a2"]
        .into_iter()
        .map(|attempt| {
            let (mux, barrier, share) = (mux.clone(), barrier.clone(), share.clone());
            std::thread::spawn(move || {
                barrier.wait();
                let redeem = Redeem {
                    share_id: share["share_id"].as_str().unwrap().into(),
                    secret: share["secret"].as_str().unwrap().into(),
                    name: "Theo".into(),
                    attempt_id: attempt.into(),
                    account: None,
                    avatar_url: None,
                };
                (attempt, mux.control_clients.agent_sessions.link_shares.redeem(None, redeem))
            })
        })
        .collect();
    let results: Vec<_> = racers.into_iter().map(|racer| racer.join().unwrap()).collect();
    let won: Vec<_> = results.iter().filter(|(_, r)| r.is_ok()).collect();
    assert_eq!(won.len(), 1, "{results:?}");
    assert!(results.iter().any(|(_, r)| *r == Err("share.used")), "{results:?}");
    let (attempt, first) = won[0];
    // The winner's retry (its reply was lost) gets the same guest without a use; a new one cannot.
    let again = redeem(&mut owner, &share, "Theo", attempt);
    assert_eq!(again["data"]["guest_id"], first.as_ref().unwrap()["guest_id"], "{again}");
    assert_code(&redeem(&mut owner, &share, "Theo", "a3"), "share.used");
    assert_eq!(list(&mut owner)[0]["uses_left"], 0);
    let many = create(&mut owner, surface, json!({"uses":8}));
    for name in ["", "  ", "a\nb", "\u{202E}x", "a\u{200B}b", &"x".repeat(65)] {
        assert_code(&redeem(&mut owner, &many, name, "n"), "share.name");
    }
    assert_eq!(redeem(&mut owner, &many, &"é".repeat(64), "n")["ok"], true);
}

/// An account invited with `talk` (signed in at the room) may send: its prompts reach acpmux
/// held for the owner, and nothing outside its verbs does.
#[test]
fn a_guest_reaches_only_its_verbs_and_its_prompts_wait_for_the_owner() {
    let fake = FakeAcpmux::start("share-guest");
    let mux = mux_with(&fake, "share-guest");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-guest-owner");
    let share = create(&mut owner, surface, json!({}));
    assert_eq!(invite(&mut owner, &share, "theo@example.com", Some("talk"))["ok"], true);
    let guest = owner.request(json!({"cmd":"agent-session-share-redeem",
        "share_id":share["share_id"], "account":"theo@example.com", "name":"Theo",
        "attempt_id":"a1"}));
    assert_eq!(guest["data"]["role"], "talk", "{guest}");
    let (mut client, bound) = bind(&mux, &share, &guest, "share-guest-link");
    assert_eq!(bound["ok"], true, "{bound}");
    let (share_id, guest_id) =
        (share["share_id"].as_str().unwrap(), guest["data"]["guest_id"].as_str().unwrap());
    let author = json!({"id": format!("guest:{share_id}.{guest_id}"), "name":"Theo",
        "approval":"owner", "role":"talk"});
    // Whatever surface the frame names, it reaches the shared chat's.
    let attach = client.request(json!({"cmd":"agent-session-attach", "surface":9999}));
    assert_eq!(attach["ok"], true, "{attach}");
    let frame = fake.frame();
    assert_eq!(frame["params"]["_meta"]["acpmux"]["author"], author);
    assert_eq!(frame["params"]["kinds"], json!(["transcript"]));
    let prompt = json!({"cmd":"agent-session-prompt", "surface":surface, "client_id":"c1",
        "text":"hello"});
    assert_eq!(client.request(prompt.clone())["ok"], true);
    let sent = fake.frame();
    let hash = digest(&[share_id, guest_id, "c1"]);
    let id = format!("g-{}", &base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(hash)[..22]);
    assert_eq!(sent["params"]["_meta"]["acpmux"]["promptId"], id);
    assert_eq!(sent["params"]["_meta"]["acpmux"]["author"], author);
    let content = json!([{"type":"text", "text":" "}, {"type":"text", "text":"still Theo"}]);
    assert_eq!(
        client.request(json!({"cmd":"agent-session-prompt", "surface":surface,
        "client_id":"c2", "content":content}))["ok"],
        true
    );
    let sent = fake.frame();
    assert_eq!(sent["params"]["sessionId"], SESSION);
    assert_eq!(sent["params"]["prompt"], content);
    assert_eq!(sent["params"]["_meta"]["acpmux"]["author"], author);
    assert_eq!(
        sent["params"]["_meta"]["acpmux"]["promptId"],
        guest_prompt_id(share_id, guest_id, "c2")
    );
    let mut unnamed = prompt;
    unnamed.as_object_mut().unwrap().remove("client_id");
    assert_code(&client.request(unnamed), "agent_session.bad_request");
    for (cmd, field) in [("agent-session-typing", "on"), ("agent-session-view", "visible")] {
        let reply = client.request(json!({"cmd":cmd, "surface":surface, field:true}));
        assert_eq!(reply["ok"], true, "{reply}");
        assert_eq!(fake.frame()["params"]["_meta"]["acpmux"]["author"], author, "{cmd}");
    }
    for frame in [
        json!({"cmd":"agent-session-cancel", "surface":surface}),
        json!({"cmd":"agent-session-permission", "surface":surface, "permission_id":"p",
            "option_id":"allow"}),
        json!({"cmd":"agent-session-children", "surface":surface}),
        json!({"cmd":"agent-session-media", "surface":surface, "path":"/tmp/a.png"}),
        json!({"cmd":"agent-session-context", "surface":surface, "op":"get"}),
        json!({"cmd":"agent-session-context", "surface":surface, "op":"set", "scope":"user", "text":"edit"}),
        json!({"cmd":"agent-session-start", "cwd":"/tmp"}),
        json!({"cmd":"agent-session-trust", "cwd":"/tmp"}),
        json!({"cmd":"agent-session-of", "surface":surface}),
        json!({"cmd":"agent-session-share-create", "surface":surface}),
        json!({"cmd":"agent-session-share-list"}),
        json!({"cmd":"list-workspaces"}),
        json!({"cmd":"identify"}),
    ] {
        assert_code(&client.request(frame), "agent_session.scope_not_granted");
    }
    let forged = json!({"cmd":"agent-session-events", "surface":surface,
        "_host_author":{"id":"tailnet:someone"}});
    assert_code(&client.request(forged), "agent_session.not_trusted");
    let pinned_elsewhere = json!({"cmd":"agent-session-events", "_host_session":"acp_other"});
    assert_code(&client.request(pinned_elsewhere), "agent_session.not_trusted");
    assert_eq!(client.request(json!({"cmd":"agent-session-events", "surface":1}))["ok"], true);
    assert_eq!(fake.frame()["method"], "_acpmux/events", "only the allowed verbs reached acpmux");
    fake.no_frame();
}

#[test]
fn kick_and_revoke_close_the_guests_connections_at_once() {
    let fake = FakeAcpmux::start("share-close");
    let mux = mux_with(&fake, "share-close");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-close-owner");
    let share = create(&mut owner, surface, json!({"uses":2}));
    let first = redeem(&mut owner, &share, "Ann", "a1");
    let second = redeem(&mut owner, &share, "Bob", "a2");
    let (mut ann, _) = bind(&mux, &share, &first, "share-close-ann");
    let (mut bob, _) = bind(&mux, &share, &second, "share-close-bob");
    for client in [&mut ann, &mut bob] {
        let attach = client.request(json!({"cmd":"agent-session-attach", "surface":surface}));
        assert_eq!(attach["ok"], true, "{attach}");
    }
    owner.request(json!({"cmd":"agent-session-share-kick", "share_id":share["share_id"],
        "guest_id":first["data"]["guest_id"]}));
    wait_unbound(&mux, 1);
    assert_eq!(bob.request(json!({"cmd":"agent-session-events", "surface":surface}))["ok"], true);
    owner.request(json!({"cmd":"agent-session-share-revoke", "share_id":share["share_id"]}));
    wait_unbound(&mux, 0);
    assert_eq!(owner.request(json!({"cmd":"list-workspaces"}))["ok"], true, "the owner stays");
}

#[test]
fn a_share_expires_on_its_timer_and_on_every_use() {
    let fake = FakeAcpmux::start("share-expiry");
    let mux = mux_with(&fake, "share-expiry");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-expiry-owner");
    let share = create(&mut owner, surface, json!({"ttl_secs":60, "uses":2}));
    let shares = &mux.control_clients.agent_sessions.link_shares;
    let armed = shares.armed.lock().unwrap().as_ref().map(|(_, at)| *at);
    assert_eq!(armed, share["expires_at"].as_u64(), "one timer, at the expiry");
    let guest = redeem(&mut owner, &share, "Ann", "a1");
    let (_ann, bound) = bind(&mux, &share, &guest, "share-expiry-ann");
    assert_eq!(bound["ok"], true);
    shares.advance(Duration::from_secs(59));
    assert_eq!(redeem(&mut owner, &share, "Ann", "a1")["ok"], true, "a retry before the expiry");
    shares.advance(Duration::from_secs(2));
    // What the timer runs at the expiry: the guest's connection closes, nothing stays armed.
    shares.expired(&mux);
    wait_unbound(&mux, 0);
    assert!(shares.armed.lock().unwrap().is_none());
    assert_code(&redeem(&mut owner, &share, "Bob", "a2"), "share.expired");
    assert_code(&bind(&mux, &share, &guest, "share-expiry-late").1, "agent_session.share_ended");
    assert_eq!(list(&mut owner)[0]["state"], "expired");
}

#[test]
fn a_provisioning_share_arms_its_expiry_timer() {
    let fake = FakeAcpmux::start("share-provisioning-expiry");
    let mux = mux_with(&fake, "share-provisioning-expiry");
    let shares = &mux.control_clients.agent_sessions.link_shares;
    let expires = shares
        .insert(
            None,
            SESSION.into(),
            1,
            ShareTerms { ttl_secs: 60, uses: 1, create_id: None, role: None, signed_in_role: None },
            true,
        )
        .unwrap()["expires_at"]
        .as_u64()
        .unwrap();
    shares.serve(&mux);
    shares.settle(&mux);
    assert_eq!(shares.armed.lock().unwrap().as_ref().map(|(_, at)| *at), Some(expires));

    shares.advance(Duration::from_secs(61));
    shares.expired(&mux);
    let state = shares.with(None, |all, _| Ok((all[0].state, false))).unwrap();
    assert_eq!(state, ShareState::Expired);
    assert!(shares.armed.lock().unwrap().is_none());
}

#[test]
fn a_share_its_uses_kicks_and_revoke_survive_a_restart() {
    let directory = std::env::temp_dir().join(format!("cmux-shares-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let dir = Some(directory.as_path());
    let first = LinkShares::default();
    let share = first
        .insert(
            dir,
            "acp_x".into(),
            3,
            ShareTerms {
                ttl_secs: 3600,
                uses: 3,
                create_id: None,
                role: None,
                signed_in_role: None,
            },
            false,
        )
        .unwrap();
    let share_id = share["share_id"].as_str().unwrap().to_owned();
    let redeem = |shares: &LinkShares, attempt: &str| {
        shares.redeem(
            dir,
            Redeem {
                share_id: share_id.clone(),
                secret: share["secret"].as_str().unwrap().into(),
                name: "Ann".into(),
                attempt_id: attempt.into(),
                account: None,
                avatar_url: None,
            },
        )
    };
    let ann = redeem(&first, "a1").unwrap();
    let kick =
        Named { share_id: share_id.clone(), guest_id: ann["guest_id"].as_str().map(Into::into) };
    first.end(dir, &kick).unwrap();
    let mode = std::fs::metadata(directory.join(FILE)).unwrap().permissions();
    assert_eq!(std::os::unix::fs::PermissionsExt::mode(&mode) & 0o777, 0o600);
    let read = |shares: &LinkShares| shares.with(dir, |all, _| Ok((all.clone(), false))).unwrap();
    let second = LinkShares::default();
    assert_eq!(read(&second), read(&first), "the restart reads what was written");
    assert_eq!(read(&second)[0].uses_left, 2);
    assert_eq!(redeem(&second, "a1"), Err("share.kicked"), "a kick holds after a restart");
    let guest_id = ann["guest_id"].as_str().unwrap();
    assert_eq!(second.guest(dir, &share_id, guest_id), Err("share.kicked"));
    second.end(dir, &Named { share_id: share_id.clone(), guest_id: None }).unwrap();
    assert_eq!(redeem(&LinkShares::default(), "a2"), Err("share.revoked"));
    let _ = std::fs::remove_dir_all(&directory);
}

/// Share verbs and a guest bind come from the owner's own local connection only: never a remote
/// relay, a WebSocket or a teammate's bound link.
#[test]
fn share_verbs_and_guest_binds_need_the_owners_local_connection() {
    let fake = FakeAcpmux::start("share-trust");
    let mux = mux_with(&fake, "share-trust");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-trust-owner");
    let share = create(&mut owner, surface, json!({"uses":2}));
    let guest = redeem(&mut owner, &share, "Ann", "a1");
    let link = json!({"share_id":share["share_id"], "guest_id":guest["data"]["guest_id"]});
    for transport in [ClientTransport::Remote, ClientTransport::WebSocket] {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let client = mux.control_clients.register(transport, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        for frame in [
            json!({"id":1, "cmd":"agent-session-proxy-bind", "link_guest":link}),
            json!({"id":2, "cmd":"agent-session-share-create", "surface":surface}),
            json!({"id":3, "cmd":"agent-session-share-redeem", "share_id":share["share_id"],
                "secret":share["secret"], "name":"Eve", "attempt_id":"e"}),
        ] {
            handle_connection_frame(
                &mux,
                client,
                transport,
                &frame.to_string(),
                &writer,
                &scheduler,
            );
        }
        while let Some(line) = outbound.try_pop() {
            let reply: Value = serde_json::from_str(&line).unwrap_or_default();
            assert_ne!(reply["ok"], true, "{line}");
        }
    }
    assert_eq!(mux.control_clients.agent_sessions.proxy_authors.lock().unwrap().len(), 0);
    let mut teammate = Client::connect(&mux, "share-trust-teammate");
    let author = json!({"id":"tailnet:p@example.com", "login":"p@example.com", "node":"n"});
    assert_eq!(
        teammate.request(json!({"cmd":"agent-session-proxy-bind", "author":author}))["ok"],
        true
    );
    let create = json!({"cmd":"agent-session-share-create", "surface":surface});
    assert_code(&teammate.request(create), "agent_session.not_trusted");
    // A bind names a teammate or a guest, never both.
    let mut both = Client::connect(&mux, "share-trust-both");
    let frame = json!({"cmd":"agent-session-proxy-bind", "author":author, "link_guest":link});
    assert_code(&both.request(frame), "agent_session.bad_request");
    assert_eq!(list(&mut owner)[0]["uses_left"], 1, "nothing else was redeemed");
}

/// An expiry a verb notices before the timer runs (here a list) closes the guest's connection in
/// the same step, and a guest's live stream stops at its first record after the expiry.
#[test]
fn an_expiry_any_path_notices_ends_the_guests_connection_and_stream() {
    let mut fake = FakeAcpmux::start("share-noticed");
    let mux = mux_with(&fake, "share-noticed");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-noticed-owner");
    let share = create(&mut owner, surface, json!({"ttl_secs":60, "uses":2}));
    let first = redeem(&mut owner, &share, "Ann", "a1");
    let second = redeem(&mut owner, &share, "Bob", "a2");
    let (mut ann, _) = bind(&mux, &share, &first, "share-noticed-ann");
    let (_bob, bound) = bind(&mux, &share, &second, "share-noticed-bob");
    assert_eq!(bound["ok"], true);
    // Ann watches (the fake acpmux pushes to the first link only); Bob is bound, not attached.
    let attach = ann.request(json!({"cmd":"agent-session-attach", "surface":surface}));
    assert_eq!(attach["ok"], true, "{attach}");
    let shares = &mux.control_clients.agent_sessions.link_shares;
    shares.advance(Duration::from_secs(61));
    // No verb yet: the next record does not reach Ann, whose stream ends.
    fake.notify(
        "_acpmux/event",
        json!({"sessionId": SESSION, "seq": 9, "at": 1, "dir": "mux", "kind": "user_message"}),
    );
    let closed = ann.named_event("agent-session-closed", WAIT).expect("the stream ends");
    assert_eq!(closed["reason"], "share_ended");
    assert!(ann.named_event("agent-session-record", Duration::from_millis(200)).is_none());
    assert_eq!(mux.control_clients.agent_sessions.proxy_authors.lock().unwrap().len(), 2);
    // The owner's list notices the expiry first: both connections close, the timer is gone.
    assert_eq!(list(&mut owner)[0]["state"], "expired");
    wait_unbound(&mux, 0);
    assert!(shares.armed.lock().unwrap().is_none());
}

/// Creates and revokes racing on several connections leave the one timer at the earliest live
/// expiry (or none), never one a concurrent revoke cancelled after a create installed it.
#[test]
fn concurrent_creates_and_revokes_keep_the_timer_on_the_next_expiry() {
    let fake = FakeAcpmux::start("share-race");
    let mux = mux_with(&fake, "share-race");
    let surface = agent_tab(&mux, Some(SESSION));
    let workers: Vec<_> = (0..4u64)
        .map(|worker| {
            let mux = mux.clone();
            std::thread::spawn(move || {
                let mut owner = Client::connect(&mux, &format!("share-race-{worker}"));
                // One kept per worker, then churn: a create and its revoke.
                create(&mut owner, surface, json!({"ttl_secs": 600 + worker * 60}));
                for round in 0..3u64 {
                    let ttl = 60 + worker * 10 + round;
                    let churn = create(&mut owner, surface, json!({"ttl_secs": ttl}));
                    let revoke =
                        json!({"cmd":"agent-session-share-revoke", "share_id":churn["share_id"]});
                    assert_eq!(owner.request(revoke)["ok"], true);
                }
            })
        })
        .collect();
    for worker in workers {
        worker.join().unwrap();
    }
    let shares = &mux.control_clients.agent_sessions.link_shares;
    let next = shares
        .with(None, |all, _| {
            let live = all.iter().filter(|s| s.state == ShareState::Active);
            Ok((live.map(|s| s.expires_at).min(), false))
        })
        .unwrap();
    assert!(next.is_some());
    assert_eq!(shares.armed.lock().unwrap().as_ref().map(|(_, at)| *at), next);
}

/// A revoke that runs between a guest bind's check and its registration (its sweep finds no bound
/// connection yet) still leaves the connection unbound: the bind answers `share_ended`.
#[test]
fn a_share_that_ends_while_a_guest_binds_never_leaves_it_bound() {
    let fake = FakeAcpmux::start("share-bind-race");
    let mux = mux_with(&fake, "share-bind-race");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-bind-race-owner");
    let share = create(&mut owner, surface, json!({}));
    let guest = redeem(&mut owner, &share, "Ann", "a1");
    let shares = &mux.control_clients.agent_sessions.link_shares;
    let (revoker, share_id) = (mux.clone(), share["share_id"].as_str().unwrap().to_owned());
    *shares.bind_hook.lock().unwrap() = Some(Box::new(move || {
        let shares = &revoker.control_clients.agent_sessions.link_shares;
        let directory = revoker.session_state_directory();
        shares.end(directory.as_deref(), &Named { share_id, guest_id: None }).unwrap();
        shares.settle(&revoker);
    }));
    let (_client, reply) = bind(&mux, &share, &guest, "share-bind-race-guest");
    assert_code(&reply, "agent_session.share_ended");
    assert!(shares.bind_hook.lock().unwrap().is_none(), "the revoke ran inside the bind");
    assert_eq!(mux.control_clients.agent_sessions.proxy_authors.lock().unwrap().len(), 0);
}

/// After a restart renumbers the surfaces, a guest's attach resolves to the surface that shows
/// the chat now, and its detach ends that attachment, not a lookup of the stored surface.
#[test]
fn a_guest_detach_ends_its_attachment_on_a_renumbered_surface() {
    let fake = FakeAcpmux::start("share-detach");
    let mux = mux_with(&fake, "share-detach");
    let stored = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-detach-owner");
    let share = create(&mut owner, stored, json!({}));
    let guest = redeem(&mut owner, &share, "Ann", "a1");
    // As after a restart: the stored surface shows another chat, a new one shows the shared chat.
    crate::server::agent_session_attach_tests::run(
        &mux,
        json!({"cmd":"bind-conversation-tab-session","surface":stored,
            "session":"acp_session_2","expected_session":SESSION}),
    );
    let shown = agent_tab(&mux, Some(SESSION));
    assert_ne!(shown, stored);
    let (mut client, _) = bind(&mux, &share, &guest, "share-detach-guest");
    let attach = client.request(json!({"cmd":"agent-session-attach", "surface":stored}));
    assert_eq!(attach["ok"], true, "{attach}");
    let sessions = &mux.control_clients.agent_sessions;
    let deadline = std::time::Instant::now() + WAIT;
    while sessions.attachment_count() != 1 {
        assert!(std::time::Instant::now() < deadline, "the attachment is registered");
        std::thread::sleep(Duration::from_millis(5));
    }
    let detach = client.request(json!({"cmd":"agent-session-detach", "surface":stored}));
    assert_eq!(detach["ok"], true, "{detach}");
    assert_eq!(sessions.attachment_count(), 0, "the detach ended the attachment it named");
}

fn invite(owner: &mut Client, share: &Value, account: &str, role: Option<&str>) -> Value {
    let mut frame = json!({"cmd":"agent-session-share-invite", "share_id":share["share_id"],
        "account":account});
    if let Some(role) = role {
        frame["role"] = json!(role);
    }
    owner.request(frame)
}

fn redeem_as(owner: &mut Client, share: &Value, account: &str, attempt: &str) -> Value {
    owner.request(json!({"cmd":"agent-session-share-redeem", "share_id":share["share_id"],
        "account":account, "name":"Ann Lee", "attempt_id":attempt}))
}

#[test]
fn an_invited_account_joins_without_the_secret_and_no_other_account_does() {
    let fake = FakeAcpmux::start("share-invite");
    let mux = mux_with(&fake, "share-invite");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-invite-owner");
    let share = create(&mut owner, surface, json!({}));
    let invited = invite(&mut owner, &share, " Ann@Example.com ", None);
    assert_eq!(invited["ok"], true, "{invited}");
    assert_eq!(
        invited["data"]["account"], "ann@example.com",
        "accounts are trimmed and lowercased"
    );
    assert_eq!(invited["data"]["role"], "talk", "an invitee can talk unless made view-only");
    for bad in ["", "two words", &"x".repeat(321)] {
        assert_code(&invite(&mut owner, &share, bad, None), "share.bad_request");
    }
    assert_code(&invite(&mut owner, &share, "bo@example.com", Some("admin")), "share.bad_request");
    // Another account, and an empty one, never join an invite; neither spends the link's use.
    assert_code(&redeem_as(&mut owner, &share, "eve@example.com", "e1"), "share.not_invited");
    let guest = redeem_as(&mut owner, &share, "ANN@example.com", "a1");
    assert_eq!(guest["ok"], true, "{guest}");
    let again = redeem_as(&mut owner, &share, "ann@example.com", "a1");
    assert_eq!(again["data"]["guest_id"], guest["data"]["guest_id"], "a retry is the same guest");
    // The same attempt from another account is not that guest.
    assert_code(&redeem_as(&mut owner, &share, "eve@example.com", "a1"), "share.not_invited");
    assert_eq!(list(&mut owner)[0]["uses_left"], 1, "an invite spends no link use");
    let shown = list(&mut owner);
    assert_eq!(shown[0]["invitees"][0]["account"], "ann@example.com");
    assert_eq!(shown[0]["guests"][0]["account"], "ann@example.com");
    assert_eq!(shown[0]["guests"][0]["role"], "talk");
    // The bound invitee's author names its account and role.
    let (mut client, bound) = bind(&mux, &share, &guest, "share-invite-ann");
    assert_eq!(bound["ok"], true, "{bound}");
    let attach = client.request(json!({"cmd":"agent-session-attach", "surface":surface}));
    assert_eq!(attach["ok"], true, "{attach}");
    let frame = fake.frame();
    let author = frame["params"]["_meta"]["acpmux"]["author"].clone();
    // The account (often an email) stays the owner's to see (`-list`): the author other
    // participants see through acpmux names the guest by its name only.
    assert!(author.get("account").is_none(), "{author}");
    assert!(!frame.to_string().contains("ann@example.com"), "{frame}");
    assert_eq!(author["name"], "Ann Lee");
    assert_eq!(author["role"], "talk");
    assert_eq!(author["approval"], "owner", "an invitee's prompts are held for the owner too");
}

#[test]
fn a_view_only_invitee_watches_but_never_prompts_or_types() {
    let fake = FakeAcpmux::start("share-invite-view");
    let mux = mux_with(&fake, "share-invite-view");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-invite-view-owner");
    let share = create(&mut owner, surface, json!({}));
    assert_eq!(invite(&mut owner, &share, "ann@example.com", Some("view"))["ok"], true);
    // Asking again with the same role is a no-op; another role is refused (uninvite first).
    assert_eq!(invite(&mut owner, &share, "ann@example.com", Some("view"))["ok"], true);
    assert_code(&invite(&mut owner, &share, "ann@example.com", Some("talk")), "share.invited");
    let guest = redeem_as(&mut owner, &share, "ann@example.com", "a1");
    let (mut client, _) = bind(&mux, &share, &guest, "share-invite-view-ann");
    for frame in [
        json!({"cmd":"agent-session-attach", "surface":surface}),
        json!({"cmd":"agent-session-events", "surface":surface}),
        json!({"cmd":"agent-session-view", "surface":surface, "visible":true}),
    ] {
        let reply = client.request(frame.clone());
        assert_eq!(reply["ok"], true, "{frame}: {reply}");
        let sent = fake.frame();
        if frame["cmd"] != "agent-session-events" {
            assert_eq!(sent["params"]["_meta"]["acpmux"]["author"]["role"], "view", "{frame}");
        }
    }
    for frame in [
        json!({"cmd":"agent-session-prompt", "surface":surface, "client_id":"c1", "text":"hi"}),
        json!({"cmd":"agent-session-typing", "surface":surface, "on":true}),
        json!({"cmd":"agent-session-cancel", "surface":surface}),
    ] {
        assert_code(&client.request(frame), "agent_session.scope_not_granted");
    }
    fake.no_frame();
}

#[test]
fn uninvite_ends_the_accounts_connections_and_its_later_joins() {
    let fake = FakeAcpmux::start("share-uninvite");
    let mux = mux_with(&fake, "share-uninvite");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-uninvite-owner");
    let share = create(&mut owner, surface, json!({}));
    invite(&mut owner, &share, "ann@example.com", None);
    invite(&mut owner, &share, "bo@example.com", None);
    let ann = redeem_as(&mut owner, &share, "ann@example.com", "a1");
    let ann_phone = redeem_as(&mut owner, &share, "ann@example.com", "a2");
    let bo = redeem_as(&mut owner, &share, "bo@example.com", "b1");
    let (_c1, _) = bind(&mux, &share, &ann, "share-uninvite-ann");
    let (_c2, _) = bind(&mux, &share, &ann_phone, "share-uninvite-ann-phone");
    let (mut c3, _) = bind(&mux, &share, &bo, "share-uninvite-bo");
    let gone = owner.request(json!({"cmd":"agent-session-share-uninvite",
        "share_id":share["share_id"], "account":"Ann@example.com"}));
    assert_eq!(gone["ok"], true, "{gone}");
    wait_unbound(&mux, 1);
    let still = c3.request(json!({"cmd":"agent-session-attach", "surface":surface}));
    assert_eq!(still["ok"], true, "another invitee stays: {still}");
    assert_code(&redeem_as(&mut owner, &share, "ann@example.com", "a1"), "share.kicked");
    assert_code(&redeem_as(&mut owner, &share, "ann@example.com", "a3"), "share.not_invited");
    // The link's secret does not let a removed account back in either.
    let by_link = owner.request(json!({"cmd":"agent-session-share-redeem",
        "share_id":share["share_id"], "secret":share["secret"], "account":"ann@example.com",
        "name":"Ann Lee", "attempt_id":"a5"}));
    assert_code(&by_link, "share.kicked");
    let shown = list(&mut owner);
    assert_eq!(shown[0]["invitees"][0]["state"], "removed");
    let unknown = owner.request(json!({"cmd":"agent-session-share-uninvite",
        "share_id":share["share_id"], "account":"zed@example.com"}));
    assert_code(&unknown, "share.unknown");
    // Invited again: a new join works, the old guests stay removed.
    assert_eq!(invite(&mut owner, &share, "ann@example.com", Some("view"))["ok"], true);
    assert_eq!(redeem_as(&mut owner, &share, "ann@example.com", "a4")["ok"], true);
}

#[test]
fn invitees_survive_a_restart_and_an_old_file_without_them_loads() {
    let old = json!([{"share_id":"s1", "session":SESSION, "surface":1, "created_at":0,
        "expires_at":u64::MAX, "uses_left":1, "state":"active", "secret_sha256":"00",
        "guests":[{"guest_id":"g1", "name":"Theo", "joined_at":0, "state":"active",
            "attempt_id_sha256":"00"}]}]);
    let shares: Vec<LinkShare> = serde_json::from_value(old).unwrap();
    assert!(shares[0].invitees.is_empty());
    assert_eq!(shares[0].guests[0].account, None);
    let author = author_of(&shares[0], &shares[0].guests[0]);
    assert_eq!(
        author,
        json!({"id":"guest:s1.g1", "name":"Theo", "approval":"owner", "role":"view"}),
        "a link guest from an old file watches only"
    );
    let directory = std::env::temp_dir().join(format!("cmux-invites-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let dir = Some(directory.as_path());
    let registry = LinkShares::default();
    let created = registry
        .insert(
            dir,
            SESSION.into(),
            1,
            ShareTerms {
                ttl_secs: 3600,
                uses: 1,
                create_id: None,
                role: None,
                signed_in_role: None,
            },
            false,
        )
        .unwrap();
    let share_id = created["share_id"].as_str().unwrap().to_owned();
    registry
        .invite(
            dir,
            &Invite {
                share_id: share_id.clone(),
                account: "ann@example.com".into(),
                role: Some(Role::View),
            },
        )
        .unwrap();
    let reloaded = LinkShares::default();
    let joined = reloaded.redeem(
        dir,
        Redeem {
            share_id,
            secret: String::new(),
            name: "Ann".into(),
            attempt_id: "a1".into(),
            account: Some("ann@example.com".into()),
            avatar_url: None,
        },
    );
    assert!(joined.is_ok(), "{joined:?}");
    let _ = std::fs::remove_dir_all(&directory);
}

/// An invite and `-list` answer the link the owner hands out to invitees: the room's origin, then
/// `/i/<share_id>` (no secret in it). A share with no room has none.
#[test]
fn an_invite_and_the_list_carry_the_invite_link() {
    let directory = std::env::temp_dir().join(format!("cmux-invite-url-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let dir = Some(directory.as_path());
    let registry = LinkShares::default();
    let terms =
        ShareTerms { ttl_secs: 3600, uses: 1, create_id: None, role: None, signed_in_role: None };
    let created = registry.insert(dir, SESSION.into(), 1, terms, false).unwrap();
    let share_id = created["share_id"].as_str().unwrap().to_owned();
    let invite =
        |account: &str| Invite { share_id: share_id.clone(), account: account.into(), role: None };
    let shown = |registry: &LinkShares| {
        registry.with(dir, |all, now| Ok((find(all, &share_id)?.shown(now), false))).unwrap()
    };
    let roomless = registry.invite(dir, &invite("ann@example.com")).unwrap();
    assert!(roomless.get("invite_url").is_some_and(Value::is_null), "{roomless}");
    assert!(shown(&registry)["invite_url"].is_null());
    registry
        .with(dir, |all, _| {
            find(all, &share_id)?.room =
                Some(json!({"url": "https://room.example", "host_token": "t"}));
            Ok(((), true))
        })
        .unwrap();
    let link = format!("https://room.example/i/{share_id}");
    let invited = registry.invite(dir, &invite("bo@example.com")).unwrap();
    assert_eq!(invited["invite_url"], link, "{invited}");
    let again = registry.invite(dir, &invite("bo@example.com")).unwrap();
    assert_eq!(again["invite_url"], link, "an invite asked again answers the link too");
    assert_eq!(shown(&registry)["invite_url"], link);
    let _ = std::fs::remove_dir_all(&directory);
}

/// However many accounts and devices join, every change the daemon acknowledges is one a restart
/// reads back: a change that would pass the state file's bound is refused (`share.limit`) instead
/// of written, so a restart never finds an unreadable file and starts empty.
#[test]
fn every_acknowledged_change_reloads_however_many_invitees_join() {
    let directory = std::env::temp_dir().join(format!("cmux-invites-fill-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let dir = Some(directory.as_path());
    let shares = LinkShares::default();
    let terms = || ShareTerms {
        ttl_secs: 3600,
        uses: 1,
        create_id: None,
        role: None,
        signed_in_role: None,
    };
    let mut refused = false;
    'fill: for index in 0..MAX_SHARES {
        let created = match shares.insert(dir, format!("acp_{index}"), 1, terms(), false) {
            Ok(created) => created,
            Err(code) => {
                assert_eq!(code, "share.limit");
                refused = true;
                break;
            }
        };
        let share_id = created["share_id"].as_str().unwrap().to_owned();
        // Bridged to a room that never answers: every kick stays queued.
        shares
            .with(dir, |all, _| {
                find(all, &share_id)?.room = Some(json!({"url": "https://room.invalid"}));
                Ok(((), true))
            })
            .unwrap();
        for a in 0..MAX_INVITEES {
            let account = format!("{a}-{}@example.com", "x".repeat(280));
            let invite =
                Invite { share_id: share_id.clone(), account: account.clone(), role: None };
            if let Err(code) = shares.invite(dir, &invite) {
                assert_eq!(code, "share.limit");
                refused = true;
                break 'fill;
            }
            for g in 0..MAX_GUESTS_PER_ACCOUNT {
                let redeem = Redeem {
                    share_id: share_id.clone(),
                    secret: String::new(),
                    name: "n".repeat(64),
                    attempt_id: format!("{a}-{g}-{}", "y".repeat(100)),
                    account: Some(account.clone()),
                    avatar_url: None,
                };
                if let Err(code) = shares.redeem(dir, redeem) {
                    assert_eq!(code, "share.limit");
                    refused = true;
                    break 'fill;
                }
            }
        }
    }
    assert!(refused, "the per-share limits alone keep the file within its bound");
    // Every account removed while the room is away: every kick is queued, and still written.
    let all = shares.with(dir, |all, _| Ok((all.clone(), false))).unwrap();
    for share in &all {
        for invitee in &share.invitees {
            let p = Uninvite { share_id: share.share_id.clone(), account: invitee.account.clone() };
            shares.uninvite(dir, &p).unwrap();
        }
        assert!(share.guests.is_empty() || !share.invitees.is_empty());
    }
    let queued = shares.with(dir, |all, _| {
        Ok((all.iter().map(|s| s.pending_room_ops.len()).sum::<usize>(), false))
    });
    assert!(queued.unwrap() > 0, "the kicks wait for the room");
    let size = std::fs::metadata(directory.join(FILE)).unwrap().len();
    assert!(size <= 64 * 1024, "the file passed the state file's 64 KiB bound: {size}");
    let read = |s: &LinkShares| s.with(dir, |all, _| Ok((all.clone(), false))).unwrap();
    let reloaded = read(&LinkShares::default());
    assert!(!reloaded.is_empty());
    assert_eq!(reloaded, read(&shares), "a restart reads every acknowledged change");
    let _ = std::fs::remove_dir_all(&directory);
}

fn scratch(name: &str) -> std::path::PathBuf {
    let directory = std::env::temp_dir().join(format!("cmux-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).unwrap();
    directory
}

fn terms() -> ShareTerms {
    ShareTerms { ttl_secs: 3600, uses: 1, create_id: None, role: None, signed_in_role: None }
}

/// A create whose new share does not fit goes on once the ended shares it may drop are gone, even
/// when the records already there fit (cmux#33746, 7).
#[test]
fn a_create_drops_ended_shares_when_only_the_new_one_does_not_fit() {
    let directory = scratch("shares-prune");
    let dir = Some(directory.as_path());
    let shares = LinkShares::default();
    let ids: Vec<String> = (0..12)
        .map(|i| {
            let created = shares.insert(dir, format!("acp_{i}"), 1, terms(), false).unwrap();
            created["share_id"].as_str().unwrap().to_owned()
        })
        .collect();
    // Invitees until not even the shortest account fits: what is left is less than a share.
    let mut refused = false;
    for length in [280, 150, 75, 40, 20, 10, 1] {
        for (s, share_id) in ids.iter().enumerate() {
            for a in 0..MAX_INVITEES {
                let account = format!("{s}-{a}-{length}-{}@example.com", "x".repeat(length));
                let invite = Invite { share_id: share_id.clone(), account, role: None };
                match shares.invite(dir, &invite) {
                    Ok(_) => {}
                    Err("share.limit") => {
                        refused = true;
                        break;
                    }
                    Err(code) => panic!("{code}"),
                }
            }
        }
    }
    assert!(refused, "the invitees fill the file");
    // Every share ends with nothing left for a room to hear.
    for share_id in &ids {
        shares.end(dir, &Named { share_id: share_id.clone(), guest_id: None }).unwrap();
    }
    let created = shares.insert(dir, "acp_new".into(), 1, terms(), false);
    assert!(created.is_ok(), "the ended shares make room: {created:?}");
    let all = shares.with(dir, |all, _| Ok((all.clone(), false))).unwrap();
    assert_eq!(all.len(), 1, "only the new share is left");
    let _ = std::fs::remove_dir_all(&directory);
}

/// Whatever ends a full registry (rooms answering, kicks, removals, revokes), with every room
/// operation still queued, the file stays within the state file's 64 KiB read bound.
#[test]
fn ending_everything_in_a_full_registry_stays_within_the_bound() {
    let directory = scratch("shares-bound");
    let dir = Some(directory.as_path());
    let shares = LinkShares::default();
    let ids: Vec<String> = (0..MAX_SHARES)
        .map(|i| {
            let created = shares.insert(dir, format!("acp_{i}"), 1, terms(), true).unwrap();
            created["share_id"].as_str().unwrap().to_owned()
        })
        .collect();
    let mut refused = false;
    'fill: for a in 0..MAX_INVITEES {
        for share_id in &ids {
            let account = format!("{a}-{}@example.com", "x".repeat(280));
            let invite =
                Invite { share_id: share_id.clone(), account: account.clone(), role: None };
            if let Err(code) = shares.invite(dir, &invite) {
                assert_eq!(code, "share.limit");
                refused = true;
                break 'fill;
            }
            let redeem = Redeem {
                share_id: share_id.clone(),
                secret: String::new(),
                name: "n".repeat(64),
                attempt_id: format!("{a}-{}", "y".repeat(100)),
                account: Some(account),
                avatar_url: None,
            };
            if let Err(code) = shares.redeem(dir, redeem) {
                assert_eq!(code, "share.provisioning");
            }
        }
    }
    assert!(refused, "the invites fill the file");
    // Each room answers with the largest record it may (`adopt`): the share opens.
    shares
        .with(dir, |all, _| {
            for share in all.iter_mut() {
                let url = format!("https://{}", "a".repeat(292));
                share.room = Some(json!({"url": url, "host_token": "t".repeat(256)}));
                share.state = ShareState::Active;
            }
            Ok(((), true))
        })
        .unwrap();
    for share_id in &ids {
        let account = format!("0-{}@example.com", "x".repeat(280));
        let redeem = Redeem {
            share_id: share_id.clone(),
            secret: String::new(),
            name: "n".repeat(64),
            attempt_id: format!("late-{}", "y".repeat(100)),
            account: Some(account),
            avatar_url: None,
        };
        let _ = shares.redeem(dir, redeem);
    }
    let all = shares.with(dir, |all, _| Ok((all.clone(), false))).unwrap();
    for share in &all {
        if let Some(guest) = share.guests.first() {
            let kick =
                Named { share_id: share.share_id.clone(), guest_id: Some(guest.guest_id.clone()) };
            shares.end(dir, &kick).unwrap();
        }
        for invitee in &share.invitees {
            let p = Uninvite { share_id: share.share_id.clone(), account: invitee.account.clone() };
            shares.uninvite(dir, &p).unwrap();
        }
        shares.end(dir, &Named { share_id: share.share_id.clone(), guest_id: None }).unwrap();
    }
    let size = std::fs::metadata(directory.join(FILE)).unwrap().len();
    assert!(size <= 64 * 1024, "the file passed the state file's 64 KiB bound: {size}");
    let read = |s: &LinkShares| s.with(dir, |all, _| Ok((all.clone(), false))).unwrap();
    assert_eq!(read(&LinkShares::default()), read(&shares), "a restart reads every end");
    let _ = std::fs::remove_dir_all(&directory);
}

/// A shares file the daemon cannot read back is kept aside (`.unreadable`), never overwritten by
/// the next write; while it cannot be moved, nothing is written over it.
#[test]
fn an_unreadable_shares_file_is_kept_aside_and_never_overwritten() {
    let directory = scratch("shares-unreadable");
    let dir = Some(directory.as_path());
    let oversized = format!("[{}]", " ".repeat(70 * 1024)).into_bytes();
    std::fs::write(directory.join(FILE), &oversized).unwrap();
    let shares = LinkShares::default();
    shares.insert(dir, SESSION.into(), 1, terms(), false).unwrap();
    let aside = directory.join(format!("{FILE}.unreadable"));
    assert_eq!(std::fs::read(&aside).unwrap(), oversized, "the unreadable file is kept");
    let read = |s: &LinkShares| s.with(dir, |all, _| Ok((all.clone(), false))).unwrap();
    assert_eq!(read(&LinkShares::default()).len(), 1, "the new file reads back");

    // Unreadable again: the copy kept before stays, the new one goes beside it.
    std::fs::write(directory.join(FILE), b"not json either").unwrap();
    LinkShares::default().insert(dir, SESSION.into(), 1, terms(), false).unwrap();
    assert_eq!(std::fs::read(&aside).unwrap(), oversized, "the earlier copy is not replaced");
    let kept: Vec<Vec<u8>> = std::fs::read_dir(&directory)
        .unwrap()
        .map(|entry| entry.unwrap())
        .filter(|entry| {
            entry.file_name().to_string_lossy().starts_with(&format!("{FILE}.unreadable-"))
        })
        .map(|entry| std::fs::read(entry.path()).unwrap())
        .collect();
    assert_eq!(kept, vec![b"not json either".to_vec()]);

    // The file cannot be moved aside: no write replaces it.
    let blocked = scratch("shares-unreadable-blocked");
    let dir = Some(blocked.as_path());
    std::fs::write(blocked.join(FILE), b"not json").unwrap();
    let aside = blocked.join(format!("{FILE}.unreadable"));
    let shares = LinkShares::default();
    shares.refuse_set_aside.store(true, Ordering::Relaxed);
    assert_eq!(shares.insert(dir, SESSION.into(), 1, terms(), false), Err("share.unsaved"));
    assert_eq!(std::fs::read(blocked.join(FILE)).unwrap(), b"not json");
    shares.refuse_set_aside.store(false, Ordering::Relaxed);
    shares.insert(dir, SESSION.into(), 1, terms(), false).unwrap();
    assert_eq!(std::fs::read(&aside).unwrap(), b"not json", "moved aside once it could be");
    assert_eq!(read(&LinkShares::default()).len(), 1);
    let _ = std::fs::remove_dir_all(&directory);
    let _ = std::fs::remove_dir_all(&blocked);
}

/// A move aside never replaces a copy already kept: when `.unreadable` and the `-<unix ms>` name
/// the clock gives are both taken (two moves in one millisecond, or a clock that went back), the
/// new copy goes to a free name beside them and every earlier copy survives (cmux#33921).
#[test]
fn a_move_aside_never_replaces_a_kept_copy_on_a_suffix_collision() {
    let directory = scratch("shares-unreadable-collision");
    let dir = Some(directory.as_path());
    let first = directory.join(format!("{FILE}.unreadable"));
    std::fs::write(&first, b"first").unwrap();
    // Take every `-<ms>` name the move can pick in the next few seconds.
    let now = wall_ms();
    let taken: Vec<_> =
        (now..now + 3_000).map(|ms| directory.join(format!("{FILE}.unreadable-{ms}"))).collect();
    for path in &taken {
        std::fs::write(path, b"earlier").unwrap();
    }
    std::fs::write(directory.join(FILE), b"not json").unwrap();
    LinkShares::default().insert(dir, SESSION.into(), 1, terms(), false).unwrap();
    assert!(wall_ms() < now + 3_000, "the move ran inside the taken window");
    assert_eq!(std::fs::read(&first).unwrap(), b"first", "`.unreadable` is not replaced");
    for path in &taken {
        assert_eq!(std::fs::read(path).unwrap(), b"earlier", "{} was replaced", path.display());
    }
    let moved: Vec<_> = std::fs::read_dir(&directory)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| std::fs::read(path).is_ok_and(|bytes| bytes == b"not json"))
        .collect();
    assert_eq!(moved.len(), 1, "the new unreadable copy is kept once: {moved:?}");
    let read = |s: &LinkShares| s.with(dir, |all, _| Ok((all.clone(), false))).unwrap();
    assert_eq!(read(&LinkShares::default()).len(), 1, "the new file reads back");
    let _ = std::fs::remove_dir_all(&directory);
}

/// A redeem with the link's secret and an account that is not invited joins as a link guest (it
/// spends a use), instead of being refused as not invited (cmux#33746, 2), and keeps its account
/// (`via: link`): on a link with no role it may send (ask-2a1105b933).
#[test]
fn a_redeem_with_the_secret_and_an_uninvited_account_joins_by_the_link() {
    let fake = FakeAcpmux::start("share-secret-account");
    let mux = mux_with(&fake, "share-secret-account");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-secret-account-owner");
    let share = create(&mut owner, surface, json!({"uses": 2}));
    let both = |owner: &mut Client, secret: &Value, account: &str, attempt: &str| {
        owner.request(json!({"cmd":"agent-session-share-redeem", "share_id":share["share_id"],
            "secret":secret, "account":account, "name":"Eve", "attempt_id":attempt}))
    };
    let wrong = json!("AAAAAAAAAAAAAAAAAAAAAA");
    assert_code(&both(&mut owner, &wrong, "eve@example.com", "e0"), "share.not_invited");
    let joined = both(&mut owner, &share["secret"], "eve@example.com", "e1");
    assert_eq!(joined["ok"], true, "{joined}");
    let again = both(&mut owner, &share["secret"], "eve@example.com", "e1");
    assert_eq!(again["data"]["guest_id"], joined["data"]["guest_id"], "a retry is the same guest");
    let shown = list(&mut owner);
    assert_eq!(shown[0]["uses_left"], 1, "a link guest spends a use");
    assert_eq!(joined["data"]["role"], "talk", "{joined}");
    let eve = &shown[0]["guests"][0];
    assert_eq!(
        (&eve["account"], &eve["via"], &eve["role"]),
        (&json!("eve@example.com"), &json!("link"), &json!("talk")),
        "a signed-in link guest keeps its account: {eve}"
    );
    // The same attempt without the secret is not that guest.
    let bare = owner
        .request(json!({"cmd":"agent-session-share-redeem", "share_id":share["share_id"],
        "account":"eve@example.com", "name":"Eve", "attempt_id":"e1"}));
    assert_code(&bare, "share.secret");
    // An invited account takes the invite, secret or not: no use spent.
    assert_eq!(invite(&mut owner, &share, "ann@example.com", None)["ok"], true);
    assert_eq!(both(&mut owner, &share["secret"], "ann@example.com", "a1")["ok"], true);
    let shown = list(&mut owner);
    assert_eq!(shown[0]["uses_left"], 1);
    assert_eq!(shown[0]["guests"][1]["account"], "ann@example.com");
}

/// An ended share says how it ended to any account, invited or not (cmux#33746, 6).
#[test]
fn an_ended_share_answers_how_it_ended_to_any_account() {
    let fake = FakeAcpmux::start("share-ended-account");
    let mux = mux_with(&fake, "share-ended-account");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-ended-account-owner");
    let revoked = create(&mut owner, surface, json!({}));
    owner.request(json!({"cmd":"agent-session-share-revoke", "share_id":revoked["share_id"]}));
    assert_code(&redeem_as(&mut owner, &revoked, "eve@example.com", "e1"), "share.revoked");
    let expired = create(&mut owner, surface, json!({"ttl_secs": 60}));
    mux.control_clients.agent_sessions.link_shares.advance(Duration::from_secs(61));
    assert_code(&redeem_as(&mut owner, &expired, "eve@example.com", "e2"), "share.expired");
    let closed = create(&mut owner, surface, json!({}));
    close_chat_shares(&mux, SESSION);
    assert_code(&redeem_as(&mut owner, &closed, "eve@example.com", "e3"), "share.closed");
}

/// A guest who joins by a link alone (no signed-in account) watches only, on a `view` link and on
/// a link made with no role or `talk` alike: its redeem answers `role: "view"` (the room's page
/// draws no composer), its author carries it, and its prompt, typing and cancel never reach
/// acpmux. The share's own role shows in create and `-list`.
#[test]
fn a_view_link_guest_watches_but_its_prompt_is_refused() {
    let fake = FakeAcpmux::start("share-link-view");
    let mux = mux_with(&fake, "share-link-view");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-link-view-owner");
    let talk = create(&mut owner, surface, json!({"uses":2}));
    assert_eq!(talk["role"], Value::Null, "no role by default");
    let share = create(&mut owner, surface, json!({"role":"view", "uses":2}));
    assert_eq!(share["role"], "view");
    let shown = list(&mut owner);
    let shown_role = |id: &Value| {
        shown.as_array().unwrap().iter().find(|s| s["share_id"] == *id).map(|s| s["role"].clone())
    };
    assert_eq!(shown_role(&talk["share_id"]), Some(Value::Null));
    assert_eq!(shown_role(&share["share_id"]), Some(json!("view")));
    assert_code(
        &owner.request(json!({"cmd":"agent-session-share-create", "surface":surface,
            "role":"owner"})),
        "share.bad_request",
    );
    let talk_link = create(&mut owner, surface, json!({"role":"talk", "uses":2}));
    for (index, (link, name)) in
        [(&share, "Ann"), (&talk, "Bob"), (&talk_link, "Cy")].into_iter().enumerate()
    {
        let guest = redeem(&mut owner, link, name, &format!("a{index}"));
        assert_eq!(guest["data"]["role"], "view", "a link guest watches only: {guest}");
        let (mut client, bound) = bind(&mux, link, &guest, &format!("share-link-view-{index}"));
        assert_eq!(bound["ok"], true, "{bound}");
        for frame in [
            json!({"cmd":"agent-session-attach", "surface":surface}),
            json!({"cmd":"agent-session-view", "surface":surface, "visible":true}),
        ] {
            let reply = client.request(frame.clone());
            assert_eq!(reply["ok"], true, "{frame}: {reply}");
            let author = &fake.frame()["params"]["_meta"]["acpmux"]["author"];
            assert_eq!(author["role"], "view", "{name} {frame}");
        }
        for frame in [
            json!({"cmd":"agent-session-prompt", "surface":surface, "client_id":"c1", "text":"hi"}),
            json!({"cmd":"agent-session-typing", "surface":surface, "on":true}),
            json!({"cmd":"agent-session-cancel", "surface":surface}),
        ] {
            assert_code(&client.request(frame), "agent_session.scope_not_granted");
        }
        fake.no_frame();
        // An account the room signed in, holding the link's secret but not invited, joins by
        // the link and may send on any of these links, a `view` link included.
        let secret_account = owner.request(json!({"cmd":"agent-session-share-redeem",
            "share_id":link["share_id"], "secret":link["secret"], "account":"eve@example.com",
            "name":"Eve", "attempt_id":format!("e{index}")}));
        assert_eq!(secret_account["data"]["role"], "talk", "{name}: {secret_account}");
    }
}

/// On a link made with no role, the anonymous link guest's prompt is refused while an account
/// invited with `talk` still sends, its prompt held for the owner.
#[test]
fn a_default_link_guest_is_refused_and_an_invited_talker_is_held() {
    let fake = FakeAcpmux::start("share-link-default");
    let mux = mux_with(&fake, "share-link-default");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-link-default-owner");
    let share = create(&mut owner, surface, json!({"uses":2}));
    let anon = redeem(&mut owner, &share, "Anon", "a1");
    let (mut link, _) = bind(&mux, &share, &anon, "share-link-default-anon");
    let prompt =
        json!({"cmd":"agent-session-prompt", "surface":surface, "client_id":"c1", "text":"hi"});
    assert_code(&link.request(prompt.clone()), "agent_session.scope_not_granted");
    fake.no_frame();
    assert_eq!(invite(&mut owner, &share, "tom@example.com", Some("talk"))["ok"], true);
    let tom = redeem_as(&mut owner, &share, "tom@example.com", "t1");
    let (mut talker, bound) = bind(&mux, &share, &tom, "share-link-default-tom");
    assert_eq!(bound["ok"], true, "{bound}");
    let attach = talker.request(json!({"cmd":"agent-session-attach", "surface":surface}));
    assert_eq!(attach["ok"], true, "{attach}");
    assert_eq!(fake.frame()["params"]["_meta"]["acpmux"]["author"]["role"], "talk");
    let sent = talker.request(prompt);
    assert_eq!(sent["ok"], true, "{sent}");
    let sent = fake.frame();
    assert_eq!(sent["method"], "session/prompt");
    let author = &sent["params"]["_meta"]["acpmux"]["author"];
    assert_eq!(
        (author["role"].clone(), author["approval"].clone()),
        (json!("talk"), json!("owner"))
    );
}

/// A link made with a role, `view` or `talk`, may admit up to 1000 guests (the Share dialog's
/// "Anyone with the link"); a link with no role keeps its 8.
#[test]
fn a_link_with_a_role_takes_up_to_1000_uses_and_one_without_8() {
    let fake = FakeAcpmux::start("share-link-uses");
    let mux = mux_with(&fake, "share-link-uses");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-link-uses-owner");
    let view = create(&mut owner, surface, json!({"role":"view", "uses":1000}));
    assert_eq!(view["uses_left"], 1000);
    assert_eq!(view["role"], "view");
    let refused = |owner: &mut Client, extra: Value| {
        let mut frame = json!({"cmd":"agent-session-share-create", "surface":surface});
        for (key, value) in extra.as_object().unwrap() {
            frame[key] = value.clone();
        }
        assert_code(&owner.request(frame), "share.bad_request");
    };
    refused(&mut owner, json!({"role":"view", "uses":1001}));
    refused(&mut owner, json!({"role":"view", "uses":0}));
    assert_eq!(create(&mut owner, surface, json!({"uses":8}))["uses_left"], 8);
    refused(&mut owner, json!({"uses":9}));
    refused(&mut owner, json!({"uses":1000}));
    let talk = create(&mut owner, surface, json!({"role":"talk", "uses":1000}));
    assert_eq!((talk["uses_left"].clone(), talk["role"].clone()), (json!(1000), json!("talk")));
    refused(&mut owner, json!({"role":"talk", "uses":1001}));
}

/// Revoking a view-role link share ends its live guest in the same step: the bound, attached
/// connection closes (its stream ends), the guest cannot bind again, and the link redeems no more.
#[test]
fn revoke_closes_live_view_guest() {
    let fake = FakeAcpmux::start("share-revoke-view");
    let mux = mux_with(&fake, "share-revoke-view");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-revoke-view-owner");
    let share = create(&mut owner, surface, json!({"role":"view", "uses":2}));
    let guest = redeem(&mut owner, &share, "Ann", "a1");
    let (mut ann, bound) = bind(&mux, &share, &guest, "share-revoke-view-ann");
    assert_eq!(bound["ok"], true, "{bound}");
    let attach = ann.request(json!({"cmd":"agent-session-attach", "surface":surface}));
    assert_eq!(attach["ok"], true, "{attach}");
    assert_eq!(fake.frame()["params"]["_meta"]["acpmux"]["author"]["role"], "view");
    assert_eq!(mux.control_clients.agent_sessions.proxy_authors.lock().unwrap().len(), 1);
    let revoke = owner.request(json!({"cmd":"agent-session-share-revoke",
        "share_id":share["share_id"]}));
    assert_eq!(revoke["ok"], true, "{revoke}");
    wait_unbound(&mux, 0);
    assert!(ann.ends_within(WAIT), "the guest's connection and stream end");
    let (_again, rebound) = bind(&mux, &share, &guest, "share-revoke-view-again");
    assert_eq!(rebound["ok"], false, "{rebound}");
    assert_code(&redeem(&mut owner, &share, "Bob", "b1"), "share.revoked");
    assert_eq!(owner.request(json!({"cmd":"list-workspaces"}))["ok"], true, "the owner stays");
}

/// A link share's role is written with it and read back after a restart; a file from before the
/// role (no `role` field on the share or its guests) still has its link guests watch only.
#[test]
fn a_link_shares_role_survives_a_restart_and_old_files_have_none() {
    let directory = scratch("link-role");
    let dir = Some(directory.as_path());
    let first = LinkShares::default();
    let terms = ShareTerms { role: Some(Role::View), ..terms() };
    let share = first.insert(dir, "acp_x".into(), 3, terms, false).unwrap();
    let share_id = share["share_id"].as_str().unwrap().to_owned();
    let ann = first
        .redeem(
            dir,
            Redeem {
                share_id: share_id.clone(),
                secret: share["secret"].as_str().unwrap().into(),
                name: "Ann".into(),
                attempt_id: "a1".into(),
                account: None,
                avatar_url: None,
            },
        )
        .unwrap();
    let guest_id = ann["guest_id"].as_str().unwrap();
    let second = LinkShares::default();
    let (_, _, author) = second.guest(dir, &share_id, guest_id).unwrap();
    assert_eq!(author["role"], "view");
    assert!(view_only(&author));
    let text = std::fs::read_to_string(directory.join(FILE)).unwrap();
    let mut old: Value = serde_json::from_str(&text).unwrap();
    for share in old.as_array_mut().unwrap() {
        share.as_object_mut().unwrap().remove("role");
        for guest in share["guests"].as_array_mut().unwrap() {
            guest.as_object_mut().unwrap().remove("role");
        }
    }
    std::fs::write(directory.join(FILE), old.to_string()).unwrap();
    let third = LinkShares::default();
    let (_, _, author) = third.guest(dir, &share_id, guest_id).unwrap();
    assert_eq!(author["role"], "view", "{author}");
    assert!(view_only(&author));
    assert!(view_only(&json!({"id":"guest:s.g", "name":"x", "approval":"owner"})), "no role");
    let _ = std::fs::remove_dir_all(&directory);
}

/// A busy view link's guests that left are forgotten when the file needs room (cmux#37803, F4):
/// 900 joins that came and went still let another chat make a share, the uses count down
/// exactly to the 1000th, and a kicked guest stays recorded and cannot come back.
#[test]
fn a_view_link_redeemed_900_times_leaves_room_for_another_chats_share() {
    let directory = scratch("shares-forget-gone");
    let dir = Some(directory.as_path());
    let shares = LinkShares::default();
    let view = ShareTerms {
        ttl_secs: MAX_TTL_SECS,
        uses: MAX_LINK_USES,
        create_id: None,
        role: Some(Role::View),
        signed_in_role: None,
    };
    let share = shares.insert(dir, "acp_view".into(), 1, view, false).unwrap();
    let share_id = share["share_id"].as_str().unwrap().to_owned();
    let secret = share["secret"].as_str().unwrap().to_owned();
    let join = |attempt: String| {
        let redeem = Redeem {
            share_id: share_id.clone(),
            secret: secret.clone(),
            name: "n".repeat(64),
            attempt_id: attempt,
            account: None,
            avatar_url: None,
        };
        shares.redeem(dir, redeem)
    };
    let kicked = join("kicked".into()).unwrap();
    let kicked_id = kicked["guest_id"].as_str().unwrap().to_owned();
    let kick = Named { share_id: share_id.clone(), guest_id: Some(kicked_id.clone()) };
    shares.end(dir, &kick).unwrap();
    for i in 1..900 {
        // Guests come and go: none of these is connected, and time passes.
        if i % 50 == 0 {
            shares.advance(Duration::from_millis(KEEP_MS));
        }
        let joined = join(format!("{i}-{}", "y".repeat(100)));
        assert!(joined.is_ok(), "join {i}: {joined:?}");
    }
    let all = shares.with(dir, |all, _| Ok((all.clone(), false))).unwrap();
    assert_eq!(all[0].uses_left, MAX_LINK_USES - 900, "every join spent one use");
    assert!(all[0].guests.len() < 900, "the guests that left are forgotten");
    let still = all[0].guests.iter().find(|g| g.guest_id == kicked_id);
    assert_eq!(still.map(|g| g.state), Some(GuestState::Kicked), "the kicked guest stays");
    assert_eq!(join("kicked".into()), Err("share.kicked"), "its retry is still refused");
    assert_eq!(shares.guest(dir, &share_id, &kicked_id).err(), Some("share.kicked"));
    // Another chat's share fits.
    let other = shares.insert(dir, "acp_other".into(), 1, terms(), false);
    assert!(other.is_ok(), "{other:?}");
    // The rest of the uses, then none.
    for i in 900..1000 {
        assert!(join(format!("late-{i}")).is_ok(), "join {i}");
    }
    assert_eq!(join("one-too-many".into()), Err("share.used"));
    let read = |s: &LinkShares| s.with(dir, |all, _| Ok((all.clone(), false))).unwrap();
    assert_eq!(read(&LinkShares::default()), read(&shares), "a restart reads it back");
    let _ = std::fs::remove_dir_all(&directory);
}

/// Only link guests bound to no connection are forgotten: a connected one, one that just joined
/// and a kicked one stay.
#[test]
fn a_connected_link_guest_is_never_forgotten() {
    let fake = FakeAcpmux::start("share-forget-connected");
    let mux = mux_with(&fake, "share-forget-connected");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-forget-connected-owner");
    let share = create(&mut owner, surface, json!({"role":"view", "uses":10}));
    let ann = redeem(&mut owner, &share, "Ann", "a1");
    let bob = redeem(&mut owner, &share, "Bob", "b1");
    let eve = redeem(&mut owner, &share, "Eve", "e1");
    let kick = json!({"cmd":"agent-session-share-kick", "share_id":share["share_id"],
        "guest_id":eve["data"]["guest_id"]});
    assert_eq!(owner.request(kick)["ok"], true);
    let (_ann, bound) = bind(&mux, &share, &ann, "share-forget-connected-ann");
    assert_eq!(bound["ok"], true, "{bound}");
    let shares = &mux.control_clients.agent_sessions.link_shares;
    shares.advance(Duration::from_millis(KEEP_MS));
    let cara = redeem(&mut owner, &share, "Cara", "c1");
    let directory = mux.session_state_directory();
    let present = shares.present();
    shares
        .with(directory.as_deref(), |all, now| {
            forget_gone(all, now, &present);
            Ok(((), true))
        })
        .unwrap();
    shares.settle(&mux);
    let guests: Vec<Value> = list(&mut owner)[0]["guests"].as_array().unwrap().clone();
    let names: Vec<&str> = guests.iter().map(|g| g["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["Ann", "Eve", "Cara"], "Bob left and is forgotten");
    let (_bob, rebound) = bind(&mux, &share, &bob, "share-forget-connected-bob");
    assert_eq!(rebound["ok"], false, "{rebound}");
    let (_cara, bound) = bind(&mux, &share, &cara, "share-forget-connected-cara");
    assert_eq!(bound["ok"], true, "{bound}");
    assert_eq!(list(&mut owner)[0]["uses_left"], 6, "forgetting spends and returns no use");
}

/// Joins `share` by its link until `done` holds of the registry (the file filled and the guests
/// that left were forgotten); bounded by the link's uses.
fn join_until(mux: &Mux, share: &Value, done: impl Fn(&[LinkShare]) -> bool) {
    let shares = &mux.control_clients.agent_sessions.link_shares;
    let directory = mux.session_state_directory();
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    loop {
        let i = NEXT.fetch_add(1, Ordering::Relaxed);
        let all = shares.with(directory.as_deref(), |all, _| Ok((all.clone(), false))).unwrap();
        if done(&all) {
            return;
        }
        let redeem = Redeem {
            share_id: share["share_id"].as_str().unwrap().into(),
            secret: share["secret"].as_str().unwrap().into(),
            name: "n".repeat(64),
            attempt_id: format!("fill-{i}-{}", "y".repeat(100)),
            account: None,
            avatar_url: None,
        };
        shares.redeem(directory.as_deref(), redeem).unwrap();
        shares.settle(mux);
    }
}

fn has_guest(all: &[LinkShare], guest: &Value) -> bool {
    all.iter().flat_map(|s| &s.guests).any(|g| g.guest_id == guest["data"]["guest_id"])
}

/// Forgetting and binding never cross: a guest forgotten while its bind runs is refused, and a
/// guest bound before the file fills stays bound and recorded however many guests are forgotten.
#[test]
fn a_bind_and_forgetting_its_guest_never_cross() {
    let fake = FakeAcpmux::start("share-forget-bind");
    let mux = mux_with(&fake, "share-forget-bind");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-forget-bind-owner");
    let share = create(&mut owner, surface, json!({"role":"view", "uses":1000}));
    let ann = redeem(&mut owner, &share, "Ann", "a1");
    let bob = redeem(&mut owner, &share, "Bob", "b1");
    let shares = &mux.control_clients.agent_sessions.link_shares;
    shares.advance(Duration::from_millis(KEEP_MS));
    let (_bob_link, bound) = bind(&mux, &share, &bob, "share-forget-bind-bob");
    assert_eq!(bound["ok"], true, "{bound}");
    // Between Ann's bind check and its registration, the file fills and the guests that left go.
    let (hook_mux, hook_share, hook_ann) = (mux.clone(), share.clone(), ann.clone());
    *shares.bind_hook.lock().unwrap() = Some(Box::new(move || {
        join_until(&hook_mux, &hook_share, |all| !has_guest(all, &hook_ann));
    }));
    let (_ann_link, refused) = bind(&mux, &share, &ann, "share-forget-bind-ann");
    assert_code(&refused, "agent_session.share_ended");
    let directory = mux.session_state_directory();
    let all = shares.with(directory.as_deref(), |all, _| Ok((all.clone(), false))).unwrap();
    assert!(has_guest(&all, &bob), "the bound guest stays recorded");
    assert_eq!(mux.control_clients.agent_sessions.proxy_authors.lock().unwrap().len(), 1);
    assert!(shares.guest_live(&bound_author(&share, &bob)), "and live");
}

fn bound_author(share: &Value, guest: &Value) -> Value {
    json!({"id": format!("{GUEST_PREFIX}{}.{}", share["share_id"].as_str().unwrap(),
        guest["data"]["guest_id"].as_str().unwrap())})
}

/// A guest whose connection ended (the room's host socket dropped, the daemon restarted) is kept
/// for a while, so its relay comes back as itself; one gone longer is forgotten.
#[test]
fn a_guest_whose_relay_just_dropped_resumes_as_itself() {
    let fake = FakeAcpmux::start("share-forget-relay");
    let mux = mux_with(&fake, "share-forget-relay");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-forget-relay-owner");
    let share = create(&mut owner, surface, json!({"role":"view", "uses":1000}));
    let ann = redeem(&mut owner, &share, "Ann", "a1");
    let (link, bound) = bind(&mux, &share, &ann, "share-forget-relay-ann");
    assert_eq!(bound["ok"], true, "{bound}");
    let shares = &mux.control_clients.agent_sessions.link_shares;
    // Guests that came and went long ago, then the relay's connection drops and the file fills
    // while it reconnects.
    let count = |all: &[LinkShare]| all.iter().map(|s| s.guests.len()).sum::<usize>();
    join_until(&mux, &share, |all| count(all) >= 50);
    shares.advance(Duration::from_millis(2 * KEEP_MS));
    drop(link);
    wait_unbound(&mux, 0);
    let filled = std::cell::Cell::new(0usize);
    join_until(&mux, &share, |all| {
        let guests = count(all);
        let dropped = guests < filled.get();
        filled.set(guests);
        dropped
    });
    let directory = mux.session_state_directory();
    let all = shares.with(directory.as_deref(), |all, _| Ok((all.clone(), false))).unwrap();
    assert!(has_guest(&all, &ann), "the guest whose relay just dropped stays");
    let (link, again) = bind(&mux, &share, &ann, "share-forget-relay-ann-again");
    assert_eq!(again["ok"], true, "its relay comes back as itself: {again}");
    // Gone for longer than the grace, it is forgotten at the next fill.
    drop(link);
    wait_unbound(&mux, 0);
    shares.advance(Duration::from_millis(KEEP_MS));
    join_until(&mux, &share, |all| !has_guest(all, &ann));
    let (_link, refused) = bind(&mux, &share, &ann, "share-forget-relay-ann-late");
    assert_code(&refused, "agent_session.share_ended");
}

fn redeem_signed_in(owner: &mut Client, share: &Value, account: &str, attempt: &str) -> Value {
    owner.request(json!({"cmd":"agent-session-share-redeem", "share_id":share["share_id"],
        "secret":share["secret"], "account":account, "name":"Sam Park", "attempt_id":attempt,
        "avatar_url":"https://lh3.example.com/a/sam.png"}))
}

/// A guest the room signed in who holds the link's secret, not invited, may send on any link (the
/// Share dialog's `view` link included): it joins with `talk`, its author carries its name and
/// picture, and its prompt still goes to acpmux held for the owner. On a link made with
/// `signed_in_role: view` it watches; a guest nobody signed in watches on any link (cmux#37766).
/// ask-2a1105b933, items 2 and 3.
#[test]
fn a_signed_in_link_guest_talks_unless_the_link_is_for_viewers() {
    let fake = FakeAcpmux::start("share-signed-in-link");
    let mux = mux_with(&fake, "share-signed-in-link");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-signed-in-link-owner");
    // The Share dialog's "Anyone with the link" share, as on base.
    let share = create(&mut owner, surface, json!({"role":"view", "uses":3}));
    assert_eq!(share["signed_in_role"], Value::Null);
    let sam = redeem_signed_in(&mut owner, &share, "Sam@Example.com", "s1");
    assert_eq!(sam["ok"], true, "{sam}");
    assert_eq!(sam["data"]["role"], "talk", "{sam}");
    let again = redeem_signed_in(&mut owner, &share, "sam@example.com", "s1");
    assert_eq!(again["data"]["guest_id"], sam["data"]["guest_id"], "a retry is the same guest");
    let shown = list(&mut owner);
    assert_eq!(shown[0]["uses_left"], 2, "a signed-in link guest spends one use, once");
    let guest = &shown[0]["guests"][0];
    assert_eq!(
        (&guest["account"], &guest["via"], &guest["role"], &guest["avatar_url"]),
        (
            &json!("sam@example.com"),
            &json!("link"),
            &json!("talk"),
            &json!("https://lh3.example.com/a/sam.png")
        ),
        "{guest}"
    );
    let (mut client, bound) = bind(&mux, &share, &sam, "share-signed-in-link-sam");
    assert_eq!(bound["ok"], true, "{bound}");
    let attach = client.request(json!({"cmd":"agent-session-attach", "surface":surface}));
    assert_eq!(attach["ok"], true, "{attach}");
    fake.frame();
    let sent = client.request(json!({"cmd":"agent-session-prompt", "surface":surface,
        "client_id":"c1", "text":"hello from Sam"}));
    assert_eq!(sent["ok"], true, "{sent}");
    let frame = fake.frame();
    assert_eq!(frame["method"], "session/prompt");
    let author = &frame["params"]["_meta"]["acpmux"]["author"];
    assert_eq!(
        author,
        &json!({"id": format!("guest:{}.{}", share["share_id"].as_str().unwrap(),
                    sam["data"]["guest_id"].as_str().unwrap()),
                "name": "Sam Park", "approval": "owner", "role": "talk",
                "avatar": "https://lh3.example.com/a/sam.png"}),
        "its prompt names its sender and is held for the owner"
    );
    assert!(!frame.to_string().contains("sam@example.com"), "the account stays the owner's");

    // A link for viewers only: the signed-in guest watches.
    let view =
        create(&mut owner, surface, json!({"role":"view", "signed_in_role":"view", "uses":3}));
    assert_eq!(view["signed_in_role"], "view");
    let listed = list(&mut owner);
    let listed = listed.as_array().unwrap().iter().find(|s| s["share_id"] == view["share_id"]);
    assert_eq!(listed.unwrap()["signed_in_role"], "view");
    assert_code(
        &owner.request(json!({"cmd":"agent-session-share-create", "surface":surface,
            "signed_in_role":"owner"})),
        "share.bad_request",
    );
    let watcher = redeem_signed_in(&mut owner, &view, "sam@example.com", "v1");
    assert_eq!(watcher["data"]["role"], "view", "{watcher}");
    let (mut watching, _) = bind(&mux, &view, &watcher, "share-signed-in-link-view");
    assert_code(
        &watching.request(json!({"cmd":"agent-session-prompt", "surface":surface,
            "client_id":"c1", "text":"hi"})),
        "agent_session.scope_not_granted",
    );
    // Nobody signed in: view, and a picture without an account is dropped.
    let anon = owner.request(json!({"cmd":"agent-session-share-redeem",
        "share_id":share["share_id"], "secret":share["secret"], "name":"Anon",
        "attempt_id":"n1", "avatar_url":"https://lh3.example.com/a/x.png"}));
    assert_eq!(anon["data"]["role"], "view", "{anon}");
    let shown = list(&mut owner);
    let talk_share = shown.as_array().unwrap().iter().find(|s| s["share_id"] == share["share_id"]);
    let anon_shown = &talk_share.unwrap()["guests"][1];
    assert!(anon_shown.get("account").is_none() && anon_shown.get("avatar_url").is_none());
    // A picture that is not an https URL of printable ASCII is dropped; the guest still joins.
    for (attempt, bad) in [("b1", "http://x.example/a.png"), ("b2", "https://x/a b.png")] {
        let joined = owner.request(json!({"cmd":"agent-session-share-redeem",
            "share_id":view["share_id"], "secret":view["secret"], "account":"bo@example.com",
            "name":"Bo", "attempt_id":attempt, "avatar_url":bad}));
        assert_eq!(joined["ok"], true, "{joined}");
    }
    let shown = list(&mut owner);
    let view_shown = shown.as_array().unwrap().iter().find(|s| s["share_id"] == view["share_id"]);
    for guest in view_shown.unwrap()["guests"].as_array().unwrap() {
        if guest["account"] == "bo@example.com" {
            assert!(guest.get("avatar_url").is_none(), "{guest}");
        }
    }
}

/// A signed-in link guest is forgotten once gone, as an anonymous one is (its uses stay spent);
/// an invitee's guest is not (it has its own bound).
#[test]
fn a_signed_in_link_guest_is_forgotten_once_gone_and_an_invitee_is_not() {
    let directory = scratch("shares-forget-signed-in");
    let dir = Some(directory.as_path());
    let shares = LinkShares::default();
    let share = shares.insert(dir, "acp_x".into(), 1, ShareTerms { uses: 3, ..terms() }, false);
    let share = share.unwrap();
    let share_id = share["share_id"].as_str().unwrap().to_owned();
    shares
        .invite(
            dir,
            &Invite { share_id: share_id.clone(), account: "ann@example.com".into(), role: None },
        )
        .unwrap();
    let join = |account: &str, attempt: &str| {
        shares.redeem(
            dir,
            Redeem {
                share_id: share_id.clone(),
                secret: share["secret"].as_str().unwrap().into(),
                name: "Guest".into(),
                attempt_id: attempt.into(),
                account: Some(account.into()),
                avatar_url: Some("https://lh3.example.com/a.png".into()),
            },
        )
    };
    assert_eq!(join("ann@example.com", "a1").unwrap()["role"], "talk");
    assert_eq!(join("sam@example.com", "s1").unwrap()["role"], "talk");
    shares.advance(Duration::from_millis(KEEP_MS));
    shares
        .with(dir, |all, now| {
            forget_gone(all, now, &Present::default());
            Ok(((), true))
        })
        .unwrap();
    let all = shares.with(dir, |all, _| Ok((all.clone(), false))).unwrap();
    let accounts: Vec<_> = all[0].guests.iter().map(|g| g.account.clone().unwrap()).collect();
    assert_eq!(accounts, ["ann@example.com"], "the signed-in link guest that left is forgotten");
    assert_eq!(all[0].uses_left, 2, "forgetting returns no use");
    let read = |s: &LinkShares| s.with(dir, |all, _| Ok((all.clone(), false))).unwrap();
    assert_eq!(read(&LinkShares::default()), read(&shares), "a restart reads it back");
    let _ = std::fs::remove_dir_all(&directory);
}

/// The picture is the one part of a guest the registry drops to make it fit: a signed-in guest
/// who would fit only without it joins without it.
#[test]
fn a_guest_whose_picture_would_not_fit_joins_without_it() {
    let directory = scratch("shares-avatar-fit");
    let dir = Some(directory.as_path());
    let shares = LinkShares::default();
    let talk = ShareTerms {
        ttl_secs: MAX_TTL_SECS,
        uses: MAX_LINK_USES,
        create_id: None,
        role: Some(Role::Talk),
        signed_in_role: None,
    };
    let share = shares.insert(dir, "acp_fit".into(), 1, talk, false).unwrap();
    let share_id = share["share_id"].as_str().unwrap().to_owned();
    let secret = share["secret"].as_str().unwrap().to_owned();
    let picture = format!("https://x.example/{}", "p".repeat(MAX_AVATAR_BYTES - 18));
    assert_eq!(picture.len(), MAX_AVATAR_BYTES);
    let join = |account: Option<String>, attempt: String, avatar_url: Option<String>| {
        shares.redeem(
            dir,
            Redeem {
                share_id: share_id.clone(),
                secret: secret.clone(),
                name: "Sam".into(),
                attempt_id: attempt,
                account,
                avatar_url,
            },
        )
    };
    // The signed-in guest as the redeem would record it, to learn when it no longer fits.
    let signed_in = |avatar_url: Option<String>| Guest {
        guest_id: "g".repeat(11),
        name: "Sam".into(),
        joined_at: shares.now(),
        state: GuestState::Active,
        attempt_id_sha256: "0".repeat(64),
        account: Some("sam@example.com".into()),
        role: Some(Role::Talk),
        via: Some(Via::Link),
        avatar_url,
    };
    // Small anonymous joins (far smaller than the picture) until the signed-in guest fits only
    // without its picture.
    for i in 0.. {
        let all = shares.with(dir, |all, _| Ok((all.clone(), false))).unwrap();
        let mut with = all.clone();
        with[0].guests.push(signed_in(Some(picture.clone())));
        if !fits(&with) {
            let mut without = all;
            without[0].guests.push(signed_in(None));
            assert!(fits(&without), "it fits without its picture");
            break;
        }
        assert!(join(None, format!("a{i}"), None).is_ok(), "join {i}");
    }
    let joined = join(Some("sam@example.com".into()), "sam".into(), Some(picture));
    let joined = joined.expect("the guest joins");
    assert_eq!(joined["role"], "talk");
    let all = shares.with(dir, |all, _| Ok((all.clone(), false))).unwrap();
    let sam = all[0].guests.iter().find(|g| g.guest_id == joined["guest_id"]).unwrap();
    assert_eq!(sam.avatar_url, None, "the picture was dropped to fit");
    let _ = std::fs::remove_dir_all(&directory);
}

/// An attempt is one way of joining: an account that joined by the link (talk) and is then
/// invited as a viewer gets its invite's guest and role on its next redeem, even when the browser
/// reuses the attempt; the link guest ends (review of #38102, F1).
#[test]
fn an_invite_never_reuses_the_accounts_link_guest() {
    let fake = FakeAcpmux::start("share-link-then-invite");
    let mux = mux_with(&fake, "share-link-then-invite");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-link-then-invite-owner");
    let share = create(&mut owner, surface, json!({"role":"view", "uses":3}));
    let by_link = redeem_signed_in(&mut owner, &share, "sam@example.com", "s1");
    assert_eq!(by_link["data"]["role"], "talk", "{by_link}");
    let (_link_client, bound) = bind(&mux, &share, &by_link, "share-link-then-invite-link");
    assert_eq!(bound["ok"], true, "{bound}");
    assert_eq!(invite(&mut owner, &share, "sam@example.com", Some("view"))["ok"], true);
    let invited = redeem_as(&mut owner, &share, "sam@example.com", "s1");
    assert_eq!(invited["ok"], true, "{invited}");
    assert_eq!(invited["data"]["role"], "view", "the invite's role, not the link guest's");
    assert_ne!(invited["data"]["guest_id"], by_link["data"]["guest_id"], "a new guest");
    wait_unbound(&mux, 0);
    let (_again, rebound) = bind(&mux, &share, &by_link, "share-link-then-invite-again");
    assert_eq!(rebound["ok"], false, "the link guest ended: {rebound}");
    // Its retries, with the secret or without, get the invite's guest.
    for retry in [
        redeem_signed_in(&mut owner, &share, "sam@example.com", "s1"),
        redeem_as(&mut owner, &share, "sam@example.com", "s1"),
    ] {
        assert_eq!(retry["data"]["guest_id"], invited["data"]["guest_id"], "{retry}");
        assert_eq!(retry["data"]["role"], "view", "{retry}");
    }
    assert_eq!(list(&mut owner)[0]["uses_left"], 2, "only the link join spent a use");
}

/// Inviting an account ends its guests that joined by the link, connected or not, whatever
/// attempt it redeems with next: a viewer invite leaves it no way to send (review of #38102).
#[test]
fn an_invite_ends_the_accounts_link_guests_at_once() {
    let fake = FakeAcpmux::start("share-invite-ends-link");
    let mux = mux_with(&fake, "share-invite-ends-link");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-invite-ends-link-owner");
    let share = create(&mut owner, surface, json!({"role":"view", "uses":3}));
    let by_link = redeem_signed_in(&mut owner, &share, "sam@example.com", "s1");
    assert_eq!(by_link["data"]["role"], "talk", "{by_link}");
    let (mut talker, bound) = bind(&mux, &share, &by_link, "share-invite-ends-link-sam");
    assert_eq!(bound["ok"], true, "{bound}");
    assert_eq!(invite(&mut owner, &share, "sam@example.com", Some("view"))["ok"], true);
    wait_unbound(&mux, 0);
    assert!(talker.ends_within(WAIT), "the link guest's connection ends with the invite");
    let (_again, rebound) = bind(&mux, &share, &by_link, "share-invite-ends-link-again");
    assert_eq!(rebound["ok"], false, "its guest id binds no more: {rebound}");
    let fresh = redeem_signed_in(&mut owner, &share, "sam@example.com", "s2");
    assert_eq!(fresh["data"]["role"], "view", "a new attempt joins by the invite: {fresh}");
}

/// A redeem an older daemon recorded (a link join with the secret and an account, kept without
/// the account) retried after an upgrade gets that guest again, with no use spent.
#[test]
fn a_link_join_recorded_before_the_upgrade_is_found_again() {
    let directory = scratch("shares-pre-upgrade-retry");
    let dir = Some(directory.as_path());
    let shares = LinkShares::default();
    let share = shares.insert(dir, "acp_x".into(), 1, ShareTerms { uses: 2, ..terms() }, false);
    let share = share.unwrap();
    let share_id = share["share_id"].as_str().unwrap().to_owned();
    let join = |account: Option<&str>| Redeem {
        share_id: share_id.clone(),
        secret: share["secret"].as_str().unwrap().into(),
        name: "Sam".into(),
        attempt_id: "s1".into(),
        account: account.map(str::to_owned),
        avatar_url: None,
    };
    // As the older daemon kept it: the account dropped.
    let old = shares.redeem(dir, join(None)).unwrap();
    let again = shares.redeem(dir, join(Some("sam@example.com"))).unwrap();
    assert_eq!(again["guest_id"], old["guest_id"], "{again}");
    let all = shares.with(dir, |all, _| Ok((all.clone(), false))).unwrap();
    assert_eq!(all[0].uses_left, 1, "the retry spent no use");
    let _ = std::fs::remove_dir_all(&directory);
}
