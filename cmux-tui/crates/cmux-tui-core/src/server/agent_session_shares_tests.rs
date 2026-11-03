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

#[test]
fn a_guest_reaches_only_its_verbs_and_its_prompts_wait_for_the_owner() {
    let fake = FakeAcpmux::start("share-guest");
    let mux = mux_with(&fake, "share-guest");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-guest-owner");
    let share = create(&mut owner, surface, json!({}));
    let guest = redeem(&mut owner, &share, "Theo", "a1");
    let (mut client, bound) = bind(&mux, &share, &guest, "share-guest-link");
    assert_eq!(bound["ok"], true, "{bound}");
    let (share_id, guest_id) =
        (share["share_id"].as_str().unwrap(), guest["data"]["guest_id"].as_str().unwrap());
    let author = json!({"id": format!("guest:{share_id}.{guest_id}"), "name":"Theo",
        "approval":"owner"});
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
            ShareTerms { ttl_secs: 60, uses: 1, create_id: None },
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
            ShareTerms { ttl_secs: 3600, uses: 3, create_id: None },
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
    let author = fake.frame()["params"]["_meta"]["acpmux"]["author"].clone();
    assert_eq!(author["account"], "ann@example.com");
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
        json!({"id":"guest:s1.g1", "name":"Theo", "approval":"owner"}),
        "a link guest's author is unchanged"
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
            ShareTerms { ttl_secs: 3600, uses: 1, create_id: None },
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
        },
    );
    assert!(joined.is_ok(), "{joined:?}");
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
    let terms = || ShareTerms { ttl_secs: 3600, uses: 1, create_id: None };
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
