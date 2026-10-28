//! Link shares: the owner's verbs, redeem, expiry and a restart.
use super::*;
use crate::server::agent_session_attach_tests::{
    Client, FakeAcpmux, SESSION, agent_tab, assert_code, mux_with, terminal_pane,
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
fn a_share_expires_on_every_use() {
    let fake = FakeAcpmux::start("share-expiry");
    let mux = mux_with(&fake, "share-expiry");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-expiry-owner");
    let share = create(&mut owner, surface, json!({"ttl_secs":60, "uses":2}));
    let shares = &mux.control_clients.agent_sessions.link_shares;
    let guest = redeem(&mut owner, &share, "Ann", "a1");
    assert_eq!(guest["ok"], true);
    shares.advance(std::time::Duration::from_secs(59));
    assert_eq!(redeem(&mut owner, &share, "Ann", "a1")["ok"], true, "a retry before the expiry");
    shares.advance(std::time::Duration::from_secs(2));
    assert_code(&redeem(&mut owner, &share, "Ann", "a1"), "share.expired");
    assert_code(&redeem(&mut owner, &share, "Bob", "a2"), "share.expired");
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
    second.end(dir, &Named { share_id: share_id.clone(), guest_id: None }).unwrap();
    assert_eq!(redeem(&LinkShares::default(), "a2"), Err("share.revoked"));
    let _ = std::fs::remove_dir_all(&directory);
}

/// Share verbs come from the owner's own local connection only: never a remote relay, a WebSocket
/// or a teammate's bound link.
#[test]
fn share_verbs_need_the_owners_local_connection() {
    let fake = FakeAcpmux::start("share-trust");
    let mux = mux_with(&fake, "share-trust");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "share-trust-owner");
    let share = create(&mut owner, surface, json!({"uses":2}));
    assert_eq!(redeem(&mut owner, &share, "Ann", "a1")["ok"], true);
    for transport in [ClientTransport::Remote, ClientTransport::WebSocket] {
        // A remote relay or a WebSocket client: no answer is a success.
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let client = mux.control_clients.register(transport, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        for frame in [
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
    let mut teammate = Client::connect(&mux, "share-trust-teammate");
    let author = json!({"id":"tailnet:p@example.com", "login":"p@example.com", "node":"n"});
    assert_eq!(
        teammate.request(json!({"cmd":"agent-session-proxy-bind", "author":author}))["ok"],
        true
    );
    let create = json!({"cmd":"agent-session-share-create", "surface":surface});
    assert_code(&teammate.request(create), "agent_session.not_trusted");
    assert_eq!(list(&mut owner)[0]["uses_left"], 1, "nothing else was redeemed");
}
