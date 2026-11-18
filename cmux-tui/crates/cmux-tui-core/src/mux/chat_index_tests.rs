//! `chat.list`'s rows and `chat.changed` (extensibility-DESIGN.md step 3): the
//! fields, pinned and unread from acpmux, and one change event per change.

use std::time::Duration;

use serde_json::{Value, json};

use super::*;

/// One acpmux session summary, as `_acpmux/watch` pages and pushes carry it.
fn summary(id: &str, state: &str) -> Value {
    json!({
        "sessionId": id,
        "name": format!("{id}-name"),
        "title": null,
        "harness": "claude",
        "status": "idle",
        "cwd": "/src/cmux",
        "unread": false,
        "unreadTurns": 0,
        "tags": {},
        "parent": null,
        "updatedAt": 1_000,
        "createdAt": 500,
        "pullRequests": [],
        "lane": {"state": state, "title": format!("{id} title"), "step": null, "error": null,
                 "since": 900, "stalledSince": null},
    })
}

fn with(mut value: Value, patch: Value) -> Value {
    for (name, field) in patch.as_object().unwrap() {
        value[name] = field.clone();
    }
    value
}

fn push(session: Value) -> Value {
    json!({"sessionId": session["sessionId"], "peer": session["peer"], "kind": "changed", "session": session})
}

#[test]
fn a_row_has_every_listed_field_with_pinned_and_unread_from_acpmux() {
    let failed = with(
        summary("s1", "failed"),
        json!({
            "unread": true, "unreadTurns": 2, "tags": {"pinned": "true"}, "peer": "mini",
            "pullRequests": ["https://github.com/o/r/pull/7"],
            "lane": {"state": "failed", "title": "Fix upload", "step": "Running tests",
                     "error": "Credit balance too low", "since": 900, "stalledSince": null},
        }),
    );
    let listed = row(&failed).expect("a listed chat");
    assert_eq!(
        listed,
        json!({
            "id": "s1", "title": "Fix upload", "harness": "claude", "state": "failed",
            "unread": true, "unread_turns": 2, "pinned": true, "ci_failing": null,
            "machine": "mini", "cwd": "/src/cmux", "project": "cmux", "parent": null,
            "step": "Running tests", "error": "Credit balance too low",
            "since_ms": "900", "updated_ms": "1000", "created_ms": "500",
            "pull_requests": ["https://github.com/o/r/pull/7"],
        })
    );
    // No lane title: the chat's title, then its name.
    let plain = with(summary("s2", "idle"), json!({"lane": {"state": "idle", "since": null}}));
    let plain = row(&plain).unwrap();
    assert_eq!(plain["title"], "s2-name");
    assert_eq!(plain["pinned"], false);
    assert_eq!(plain["machine"], Value::Null);
    assert_eq!(plain["since_ms"], Value::Null);
    // An unpinned tag value and the other states.
    let unpinned = with(summary("s3", "input"), json!({"tags": {"pinned": ""}}));
    assert_eq!(row(&unpinned).unwrap()["pinned"], false);
    for state in ["working", "input", "idle", "failed", "lost"] {
        assert_eq!(row(&summary("s", state)).unwrap()["state"], state);
    }
}

#[test]
fn closed_archived_and_laneless_chats_are_off_the_list() {
    assert!(row(&with(summary("s", "idle"), json!({"status": "closed"}))).is_none());
    assert!(row(&with(summary("s", "idle"), json!({"tags": {"archived": "1700"}}))).is_none());
    assert!(row(&with(summary("s", "idle"), json!({"lane": null}))).is_none());
}

#[test]
fn only_a_change_of_a_listed_field_is_a_change() {
    let mut chats = Chats::default();
    assert!(chats.page(&[summary("a", "working"), summary("b", "idle")]), "a new chat");
    assert!(!chats.page(&[summary("a", "working")]), "the same row again");
    // Output alone moves updated_ms: kept fresh, no change.
    assert!(!chats.push(&push(with(summary("a", "working"), json!({"updatedAt": 5_000})))));
    assert_eq!(chats.rows[&key(None, "a")]["updated_ms"], "5000");
    // Unread, a pin and a state are changes.
    assert!(chats.push(&push(with(summary("b", "idle"), json!({"unread": true})))));
    assert!(chats.push(&push(with(
        summary("b", "idle"),
        json!({"unread": true, "tags": {"pinned": "true"}})
    ))));
    assert!(chats.push(&push(with(summary("a", "input"), json!({"updatedAt": 5_000})))));
    // A purge removes the row; purging again changes nothing.
    let purged = json!({"sessionId": "a", "peer": null, "kind": "purged"});
    assert!(chats.push(&purged));
    assert!(!chats.push(&purged));
    assert_eq!(chats.rows.len(), 1);
}

#[test]
fn a_whole_list_drops_the_rows_it_did_not_name_but_keeps_what_a_push_reached() {
    let mut chats = Chats::default();
    chats.page(&[summary("gone", "idle"), summary("kept", "idle"), summary("pushed", "idle")]);
    chats.begin();
    // A push during the list wins over an older page of the same chat.
    assert!(chats.push(&push(summary("pushed", "working"))));
    assert!(!chats.page(&[summary("kept", "idle"), summary("pushed", "idle")]));
    assert!(chats.end(), "the chat the list left out is gone");
    let ids = chats.rows.values().map(|row| row["id"].clone()).collect::<Vec<_>>();
    assert_eq!(ids, [json!("kept"), json!("pushed")]);
    assert_eq!(chats.rows[&key(None, "pushed")]["state"], "working");
    // A peer's chat with this machine's id is its own row.
    assert!(chats.page(&[with(summary("kept", "input"), json!({"peer": "mini"}))]));
    assert_eq!(chats.rows.len(), 3);
    assert_eq!(chats.find("kept"), Some(key(None, "kept")), "this machine's first");
}

/// A follow (rows changed since the cursor) drops only what it says is `gone`, never a row it
/// did not name, and not one a push on this connection reached since.
#[test]
fn a_follow_drops_only_what_it_says_is_gone() {
    let mut chats = Chats::default();
    chats.page(&[summary("a", "idle"), summary("b", "idle"), summary("c", "idle")]);
    chats.connect();
    assert!(chats.push(&push(summary("c", "working"))));
    assert!(chats.page(&[summary("a", "working")]), "a follow's row");
    let gone = [json!({"sessionId": "b", "peer": null}), json!({"sessionId": "c", "peer": null})];
    assert!(chats.gone(&gone));
    assert!(!chats.end(), "a follow is no whole list");
    let ids = chats.rows.values().map(|row| row["id"].clone()).collect::<Vec<_>>();
    assert_eq!(ids, [json!("a"), json!("c")], "b is gone; c was pushed since");
}

/// The red test of step 3: one `ChatsChanged` per change, none for a page or push that
/// changes nothing, and `chat.list` answers what acpmux said.
#[test]
fn chat_changed_fires_once_per_change() {
    let mux = Mux::new_for_test("chat-index-changed", crate::SurfaceOptions::default());
    let events = mux.subscribe_matching(|event| matches!(event, MuxEvent::ChatsChanged { .. }));
    let next = || match events.recv_timeout(Duration::from_millis(200)) {
        Ok(MuxEvent::ChatsChanged { revision }) => Some(revision),
        _ => None,
    };

    mux.change_chats(|chats| chats.page(&[summary("a", "working"), summary("b", "idle")]));
    assert_eq!(next(), Some(1), "one event for the whole page");
    assert_eq!(next(), None);

    mux.change_chats(|chats| chats.page(&[summary("a", "working")]));
    mux.change_chats(|chats| {
        chats.push(&push(with(summary("a", "working"), json!({"updatedAt": 9}))))
    });
    assert_eq!(next(), None, "nothing listed changed");

    mux.change_chats(|chats| {
        chats.push(&push(with(summary("b", "idle"), json!({"unread": true}))))
    });
    assert_eq!(next(), Some(2));
    assert_eq!(next(), None);

    let rows = mux.chat_rows();
    assert_eq!(rows.len(), 2);
    let b = rows.iter().find(|row| row["id"] == "b").unwrap();
    assert_eq!(b["unread"], true);
    assert_eq!(b["workspace"], Value::Null, "no tab shows it");

    // A mark applied ahead of acpmux's push is one change; the push that confirms it is none.
    let (pinned, revision) = mux
        .update_chat("b", |row| {
            row.insert("pinned".into(), Value::Bool(true));
        })
        .expect("b is listed");
    assert_eq!((pinned["pinned"].clone(), revision), (json!(true), 3));
    assert_eq!(next(), Some(3));
    mux.change_chats(|chats| {
        chats.push(&push(with(
            summary("b", "idle"),
            json!({"unread": true, "tags": {"pinned": "true"}}),
        )))
    });
    assert_eq!(next(), None, "acpmux's confirming push changes nothing more");
    assert!(mux.update_chat("missing", |_| {}).is_none());
    assert!(!mux.chat_listed("missing"));
}
