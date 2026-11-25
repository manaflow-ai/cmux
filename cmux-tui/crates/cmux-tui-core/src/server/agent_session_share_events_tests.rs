//! `agent-session-share-changed`: every change to a chat's shares (create, invite, uninvite, a
//! join, a kick, a revoke, an expiry, the room ending it, the chat closing) reaches the owner's
//! subscribed connections that asked for it, so an open Invite People sheet reads its rows again
//! instead of polling. A read, and a change that changes nothing, say nothing.
use super::*;
use crate::server::agent_session_attach_tests::{
    Client, FakeAcpmux, SESSION, WAIT, agent_tab, mux_with,
};

const CAPABILITY: &str = "agent-session-share-events-v1";
const EVENT: &str = "agent-session-share-changed";
/// How long a watcher listens before it says nothing came.
const QUIET: Duration = Duration::from_millis(300);

/// A subscribed connection of the owner's that echoed `capabilities`.
fn watcher(mux: &Arc<Mux>, label: &str, capabilities: &[&str]) -> Client {
    let mut client = Client::connect(mux, label);
    let info = client
        .request(json!({"cmd":"set-client-info", "name": label, "capabilities": capabilities}));
    assert_eq!(info["ok"], true, "{info}");
    let subscribed = client.request(json!({"cmd":"subscribe"}));
    assert_eq!(subscribed["ok"], true, "{subscribed}");
    client
}

/// The watcher hears the chat's shares changed.
fn heard(watcher: &mut Client, what: &str) {
    let event = watcher.named_event(EVENT, WAIT).unwrap_or_else(|| panic!("{what}: no {EVENT}"));
    assert_eq!(event["session"], SESSION, "{what}: {event}");
}

/// The watcher hears nothing more.
fn quiet(watcher: &mut Client, what: &str) {
    let event = watcher.named_event(EVENT, QUIET);
    assert!(event.is_none(), "{what}: nothing changed, yet {event:?}");
}

fn answered(owner: &mut Client, frame: Value) -> Value {
    let reply = owner.request(frame);
    assert_eq!(reply["ok"], true, "{reply}");
    reply["data"].clone()
}

#[test]
fn every_owner_verb_and_join_tells_the_watching_sheet() {
    let fake = FakeAcpmux::start("share-events-verbs");
    let mux = mux_with(&fake, "share-events-verbs");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut sheet = watcher(&mux, "share-events-sheet", &[CAPABILITY]);
    let mut other = watcher(&mux, "share-events-other", &[]);
    let mut owner = Client::connect(&mux, "share-events-owner");
    let share = answered(
        &mut owner,
        json!({"cmd":"agent-session-share-create", "surface":surface, "uses":2}),
    );
    heard(&mut sheet, "create");
    answered(&mut owner, json!({"cmd":"agent-session-share-list"}));
    quiet(&mut sheet, "a list");
    let invite = json!({"cmd":"agent-session-share-invite", "share_id":share["share_id"],
        "account":"ann@example.com"});
    answered(&mut owner, invite.clone());
    heard(&mut sheet, "invite");
    answered(&mut owner, invite);
    quiet(&mut sheet, "the same invite again");
    let guest = answered(
        &mut owner,
        json!({"cmd":"agent-session-share-redeem", "share_id":share["share_id"],
            "account":"ann@example.com", "name":"Ann Lee", "attempt_id":"a1"}),
    );
    heard(&mut sheet, "a join");
    answered(
        &mut owner,
        json!({"cmd":"agent-session-share-kick", "share_id":share["share_id"],
            "guest_id":guest["guest_id"]}),
    );
    heard(&mut sheet, "kick");
    answered(
        &mut owner,
        json!({"cmd":"agent-session-share-uninvite", "share_id":share["share_id"],
            "account":"ann@example.com"}),
    );
    heard(&mut sheet, "uninvite");
    answered(&mut owner, json!({"cmd":"agent-session-share-revoke", "share_id":share["share_id"]}));
    heard(&mut sheet, "revoke");
    quiet(&mut sheet, "nothing after the revoke");
    quiet(&mut other, "a connection that did not ask");
}

#[test]
fn expiry_the_room_ending_and_a_closed_chat_tell_the_watching_sheet() {
    let fake = FakeAcpmux::start("share-events-ends");
    let mux = mux_with(&fake, "share-events-ends");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut sheet = watcher(&mux, "share-events-ends-sheet", &[CAPABILITY]);
    let mut owner = Client::connect(&mux, "share-events-ends-owner");
    let shares = &mux.control_clients.agent_sessions.link_shares;
    let create = json!({"cmd":"agent-session-share-create", "surface":surface, "ttl_secs":60});
    answered(&mut owner, create.clone());
    heard(&mut sheet, "create");
    shares.advance(Duration::from_secs(61));
    shares.expired(&mux);
    heard(&mut sheet, "expiry");
    let ended = answered(&mut owner, create.clone());
    heard(&mut sheet, "create");
    let directory = mux.session_state_directory();
    shares.ended_by_room(directory.as_deref(), ended["share_id"].as_str().unwrap(), false);
    heard(&mut sheet, "the room ended it");
    answered(&mut owner, create);
    heard(&mut sheet, "create");
    close_chat_shares(&mux, SESSION);
    heard(&mut sheet, "the chat closed");
    quiet(&mut sheet, "nothing more");
}
