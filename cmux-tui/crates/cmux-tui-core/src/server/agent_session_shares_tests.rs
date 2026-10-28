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
        json!({"session":"acp_other"}),
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
fn a_share_its_uses_kicks_and_revoke_survive_a_restart() {
    let directory = std::env::temp_dir().join(format!("cmux-shares-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let dir = Some(directory.as_path());
    let first = LinkShares::default();
    let share = first.insert(dir, "acp_x".into(), 3, 3600, 3).unwrap();
    let share_id = share["share_id"].as_str().unwrap().to_owned();
    let redeem = |shares: &LinkShares, attempt: &str| {
        shares.redeem(
            dir,
            Redeem {
                share_id: share_id.clone(),
                secret: share["secret"].as_str().unwrap().into(),
                name: "Ann".into(),
                attempt_id: attempt.into(),
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
