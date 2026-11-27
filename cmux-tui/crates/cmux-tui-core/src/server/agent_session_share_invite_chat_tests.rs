//! `agent-session-share-invite-chat`: an account invited to the chat on a surface, on the chat's
//! invite share, made in the same step when the chat has none. A refused invite leaves no share.
use super::room::Timing;
use super::room::tests::{FakeRoom, OWNER_TOKEN};
use super::*;
use crate::server::agent_session_attach_tests::{
    Client, FakeAcpmux, SESSION, agent_tab, assert_code, mux_with, terminal_pane,
};

fn invite_chat(owner: &mut Client, surface: u64, account: &str, extra: Value) -> Value {
    let mut frame = json!({"cmd":"agent-session-share-invite-chat", "surface":surface,
        "account":account});
    for (key, value) in extra.as_object().unwrap() {
        frame[key] = value.clone();
    }
    owner.request(frame)
}

fn invited(owner: &mut Client, surface: u64, account: &str, extra: Value) -> Value {
    let reply = invite_chat(owner, surface, account, extra);
    assert_eq!(reply["ok"], true, "{reply}");
    reply["data"].clone()
}

fn list(owner: &mut Client) -> Vec<Value> {
    let reply = owner.request(json!({"cmd":"agent-session-share-list"}));
    assert_eq!(reply["ok"], true, "{reply}");
    reply["data"]["shares"].as_array().unwrap().clone()
}

fn accounts(share: &Value) -> Vec<(String, String)> {
    let invitees = share["invitees"].as_array().unwrap();
    let pair =
        |i: &Value| (i["account"].as_str().unwrap().into(), i["role"].as_str().unwrap().into());
    invitees.iter().map(pair).collect()
}

#[test]
fn an_invite_to_a_chat_makes_its_invite_share_once_then_invites_there() {
    let fake = FakeAcpmux::start("invite-chat");
    let mux = mux_with(&fake, "invite-chat");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "invite-chat-owner");
    // A guest link of the chat is not where invites go: its 24 hours and one use are the link's.
    let link = owner.request(json!({"cmd":"agent-session-share-create", "surface":surface}));
    assert_eq!(link["ok"], true, "{link}");
    let ask = json!({"role":"view", "session":SESSION});
    let first = invited(&mut owner, surface, " Ann@Example.com ", ask);
    assert_eq!(first["created_share"], true, "{first}");
    assert_eq!(
        (first["account"].clone(), first["role"].clone()),
        (json!("ann@example.com"), json!("view"))
    );
    assert_eq!(first["state"], "invited");
    assert!(first.get("invite_url").is_some_and(Value::is_null), "no room, no link: {first}");
    assert!(first.get("secret").is_none(), "an invite share's link secret is never answered");
    let share_id = first["share_id"].clone();
    assert_ne!(share_id, link["data"]["share_id"]);
    let shares = list(&mut owner);
    assert_eq!(shares.len(), 2);
    let made = shares.iter().find(|s| s["share_id"] == share_id).unwrap();
    assert_eq!(made["state"], "active");
    assert_eq!(made["session"], SESSION);
    assert_eq!(made["expires_at"], first["expires_at"]);
    // An invite share lasts the longest a share may unless the caller says.
    assert!((604_790..=604_800).contains(&made["expires_in_secs"].as_u64().unwrap()), "{made}");
    assert_eq!(accounts(made), [("ann@example.com".into(), "view".into())]);
    // The next account goes on that share; the same account and role again changes nothing.
    let second = invited(&mut owner, surface, "@theo", json!({}));
    assert_eq!(
        (second["share_id"].clone(), second["created_share"].clone()),
        (share_id.clone(), json!(false))
    );
    assert_eq!(second["role"], "talk", "talk unless named view");
    let again = invited(&mut owner, surface, "ann@example.com", json!({"role":"view"}));
    assert_eq!(
        (again["share_id"].clone(), again["created_share"].clone()),
        (share_id.clone(), json!(false))
    );
    let shares = list(&mut owner);
    assert_eq!(shares.len(), 2, "no second invite share");
    let made = shares.iter().find(|s| s["share_id"] == share_id).unwrap();
    assert_eq!(accounts(made).len(), 2);
    // The invited account joins by the share like any invitee.
    let joined = owner.request(json!({"cmd":"agent-session-share-redeem", "share_id":share_id,
        "account":"@theo", "name":"Theo", "attempt_id":"a1"}));
    assert_eq!(joined["ok"], true, "{joined}");
    // An ended invite share is not reused: the next invite makes a new one.
    let revoke = owner.request(json!({"cmd":"agent-session-share-revoke", "share_id":share_id}));
    assert_eq!(revoke["ok"], true, "{revoke}");
    let fresh = invited(&mut owner, surface, "bo@example.com", json!({"ttl_secs":3600}));
    assert_eq!(fresh["created_share"], true);
    assert_ne!(fresh["share_id"], share_id);
    let shares = list(&mut owner);
    let made = shares.iter().find(|s| s["share_id"] == fresh["share_id"]).unwrap();
    assert!((3590..=3600).contains(&made["expires_in_secs"].as_u64().unwrap()), "{made}");
}

#[test]
fn a_refused_invite_to_a_chat_leaves_no_share() {
    let fake = FakeAcpmux::start("invite-chat-refused");
    let mux = mux_with(&fake, "invite-chat-refused");
    let surface = agent_tab(&mux, Some(SESSION));
    let (terminal, _) = terminal_pane(&mux);
    let mut owner = Client::connect(&mux, "invite-chat-refused-owner");
    for account in ["", "ann", "@", "ann@localhost", "a b@example.com"] {
        assert_code(&invite_chat(&mut owner, surface, account, json!({})), "share.bad_request");
    }
    for bad in [
        json!({"role":"admin"}),
        json!({"ttl_secs":59}),
        json!({"ttl_secs":604_801}),
        json!({"create_id":""}),
        json!({"uses":2}),
    ] {
        assert_code(&invite_chat(&mut owner, surface, "ann@example.com", bad), "share.bad_request");
    }
    assert_code(
        &invite_chat(&mut owner, terminal, "ann@example.com", json!({})),
        "share.not_a_chat",
    );
    let moved = invite_chat(&mut owner, surface, "ann@example.com", json!({"session":"acp_other"}));
    assert_code(&moved, "share.chat_moved");
    assert!(list(&mut owner).is_empty(), "no refusal made a share");
    // Another role for an account already invited is refused, and nothing else changes.
    let made = invited(&mut owner, surface, "ann@example.com", json!({"role":"view"}));
    let other = invite_chat(&mut owner, surface, "ann@example.com", json!({"role":"talk"}));
    assert_code(&other, "share.invited");
    let shares = list(&mut owner);
    assert_eq!(shares.len(), 1);
    assert_eq!(shares[0]["share_id"], made["share_id"]);
    assert_eq!(accounts(&shares[0]), [("ann@example.com".into(), "view".into())]);
}

#[test]
fn an_invite_to_a_chat_with_no_room_for_a_share_makes_none() {
    let fake = FakeAcpmux::start("invite-chat-full");
    let mux = mux_with(&fake, "invite-chat-full");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "invite-chat-full-owner");
    for _ in 0..MAX_SHARES {
        let link = owner.request(json!({"cmd":"agent-session-share-create", "surface":surface}));
        assert_eq!(link["ok"], true, "{link}");
    }
    assert_code(&invite_chat(&mut owner, surface, "ann@example.com", json!({})), "share.limit");
    let shares = list(&mut owner);
    assert_eq!(shares.len(), MAX_SHARES);
    assert!(shares.iter().all(|s| s["invitees"].as_array().unwrap().is_empty()), "nobody invited");
}

/// A daemon with one agent chat, bridged to `room`.
fn bridged(label: &str, room: &FakeRoom) -> (FakeAcpmux, Arc<Mux>, u64, Client) {
    let fake = FakeAcpmux::start(label);
    let mux = mux_with(&fake, label);
    let shares = &mux.control_clients.agent_sessions.link_shares;
    assert!(shares.bridge.configure(Some(&room.url), Timing::default()));
    let surface = agent_tab(&mux, Some(SESSION));
    let owner = Client::connect(&mux, label);
    (fake, mux, surface, owner)
}

#[test]
fn an_invite_to_a_chat_needs_the_owner_token_only_to_make_its_share() {
    let room = FakeRoom::start(&[]);
    let (_fake, _mux, surface, mut owner) = bridged("invite-chat-room", &room);
    let unsigned = invite_chat(&mut owner, surface, "ann@example.com", json!({}));
    assert_code(&unsigned, "share.needs_sign_in");
    assert!(list(&mut owner).is_empty(), "no share without the owner's sign-in");
    let made = invited(&mut owner, surface, "ann@example.com", json!({"owner_token":OWNER_TOKEN}));
    assert_eq!(made["created_share"], true);
    let id = made["share_id"].as_str().unwrap();
    assert_eq!(made["invite_url"], format!("{}/i/{id}", room.url), "{made}");
    let (path, bearer, _) = room.request("PUT");
    assert_eq!((path, bearer), (format!("/v1/chat-shares/{id}"), OWNER_TOKEN.to_owned()));
    // The share is there: the next invite needs no token, and answers the same link.
    let next = invited(&mut owner, surface, "@theo", json!({}));
    assert_eq!(
        (next["share_id"].clone(), next["created_share"].clone()),
        (json!(id), json!(false))
    );
    assert_eq!(next["invite_url"], made["invite_url"]);
    assert_eq!(list(&mut owner).len(), 1);
}

#[test]
fn a_new_invite_share_the_room_refuses_ends_with_its_invite() {
    let room = FakeRoom::start(&[409]);
    let (_fake, _mux, surface, mut owner) = bridged("invite-chat-room-refused", &room);
    let token = json!({"owner_token":OWNER_TOKEN});
    let refused = invite_chat(&mut owner, surface, "ann@example.com", token.clone());
    assert_code(&refused, "share.room_refused");
    let shares = list(&mut owner);
    assert_eq!(shares.len(), 1);
    assert_eq!(shares[0]["state"], "revoked", "no share is left open with nobody able to use it");
    // The next invite makes a share the room opens; the refused one is not reused.
    let made = invited(&mut owner, surface, "ann@example.com", token);
    assert_eq!(made["created_share"], true);
    assert_ne!(made["share_id"], shares[0]["share_id"]);
    assert_eq!(list(&mut owner).iter().filter(|s| s["state"] == "active").count(), 1);
}
