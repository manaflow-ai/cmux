//! `HomeInboxMapping` and `HomeInboxSource` decisions as ops: the owners' rows over the Messages
//! list, several owners as one list, and the list edits with the ops they send.

use cmux_home_rules::call;
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("mapping.{name}"), &request).unwrap_or_else(|e| panic!("{name}: {e:?}"))
}

fn row(id: &str, at: &str) -> Value {
    json!({"id": id, "kind": "group", "name": id, "unread": 0, "activity_at": at, "pinned": false, "marked_unread": false})
}

fn pinned(id: &str, position: Option<u64>) -> Value {
    let mut row = row(id, "2026-11-25T00:00:00Z");
    row["pinned"] = json!(true);
    if let Some(position) = position {
        row["pin_position"] = json!(position);
    }
    row
}

fn ids(rows: &Value) -> Vec<String> {
    rows.as_array().unwrap().iter().map(|r| r["id"].as_str().unwrap().to_string()).collect()
}

#[test]
fn time_keys_have_three_fraction_digits() {
    for (time, key) in [
        ("2026-11-25T20:16:07Z", "2026-11-25T20:16:07.000"),
        ("2026-11-25T20:16:07.5Z", "2026-11-25T20:16:07.500"),
        ("2026-11-25T20:16:07.123456Z", "2026-11-25T20:16:07.123"),
    ] {
        assert_eq!(op("timeKey", json!({"time": time}))["key"], key, "{time}");
    }
}

#[test]
fn one_owner_keeps_its_order_and_several_merge_by_pin_then_time() {
    let one = op(
        "inboxOrdered",
        json!({"lists": [[row("b", "2026-11-25T00:00:00Z"), row("a", "2026-11-26T00:00:00Z")], []]}),
    );
    assert_eq!(ids(&one["rows"]), ["b", "a"]);
    let many = op(
        "inboxOrdered",
        json!({"lists": [
            [row("old", "2026-11-25T00:00:07Z"), pinned("p2", Some(2)), pinned("none", None)],
            [row("new", "2026-11-25T00:00:07.5Z"), pinned("p1", Some(1))],
        ]}),
    );
    assert_eq!(ids(&many["rows"]), ["p1", "p2", "none", "new", "old"]);
}

#[test]
fn owned_rows_patch_the_list_and_others_keep_this_macs_pins() {
    let mut owned = row("c1", "2026-11-25T00:00:00Z");
    owned["kind"] = json!("channel");
    owned["unread"] = json!(3);
    owned["marked_unread"] = json!(true);
    owned["preview"] = json!("hello");
    let reply = op(
        "inboxRows",
        json!({
            "owned": [owned],
            "listed": [
                {"id": "c1", "kind": "group", "timestamp": 100.0},
                {"id": "chief", "kind": "chief", "timestamp": 50.0},
                {"id": "newer", "kind": "group", "timestamp": 200.0},
                {"id": "older", "kind": "group", "timestamp": 10.0},
            ],
            "unreadMarks": ["older"],
        }),
    );
    let rows = reply["rows"].as_array().unwrap();
    assert_eq!(ids(&reply["rows"]), ["chief", "newer", "c1", "older"]);
    let patch = &rows[2]["patch"];
    assert_eq!(patch["kind"], "group");
    assert_eq!(patch["unread"], 3);
    assert_eq!(patch["preview"], "hello");
    assert!(rows[0].get("patch").is_none());
    assert_eq!(reply["pinned"], json!(["chief"]));
    assert_eq!(reply["unreadMarks"], json!(["c1", "older"]));
}

#[test]
fn row_events_refresh_their_own_owner() {
    let note = |event: Value, cloud: bool| {
        op("inboxNote", json!({"event": event, "isCloud": cloud}))["refresh"].clone()
    };
    assert_eq!(note(json!({"kind": "conversationChanged"}), false), true);
    assert_eq!(note(json!({"kind": "conversationChanged"}), true), false);
    assert_eq!(note(json!({"kind": "unknown", "name": "chief-changed"}), false), true);
    assert_eq!(note(json!({"kind": "cloudConversations", "event": "inboxReset"}), true), true);
    assert_eq!(
        note(json!({"kind": "cloudConversations", "event": "messageAppended"}), true),
        false
    );
    assert_eq!(note(json!({"kind": "terminalOutput"}), false), false);
}

#[test]
fn a_reply_waits_for_pending_writes_and_an_unavailable_cloud_keeps_its_rows() {
    let held = json!({"me": "p_me", "rows": [row("a", "2026-11-25T00:00:00Z")]});
    let waiting = op(
        "inboxAccept",
        json!({"current": held, "next": {"me": "p_me", "rows": []}, "pendingWrites": 1}),
    );
    assert_eq!(waiting, json!({"kept": false, "changed": false}));
    let unavailable = op(
        "inboxAccept",
        json!({"current": held, "next": {"me": "p_me", "rows": [], "cloud": "unavailable"}, "pendingWrites": 0}),
    );
    assert_eq!(ids(&unavailable["reply"]["rows"]), ["a"]);
    assert_eq!(unavailable["changed"], true);
    let same = op("inboxAccept", json!({"current": held, "next": held, "pendingWrites": 0}));
    assert_eq!(same["changed"], false);
    let seeded = op("inboxSeed", json!({"answered": false, "last": held}));
    assert_eq!(seeded["reply"], held);
    assert!(op("inboxSeed", json!({"answered": true, "last": held}))["reply"].is_null());
}

#[test]
fn pinning_moves_the_row_to_the_end_of_the_pins_and_sends_its_op() {
    let reply = json!({"me": "p_me", "rows": [pinned("p", Some(1)), row("a", "2026-11-25T00:00:00Z"), row("b", "2026-11-25T00:00:00Z")]});
    let edited = op(
        "inboxEdit",
        json!({"reply": reply, "isCloud": false, "now": 99, "edit": {"setPinned": {"on": true, "id": "b"}}}),
    );
    assert_eq!(ids(&edited["reply"]["rows"]), ["p", "b", "a"]);
    assert_eq!(
        edited["writes"],
        json!([{"conversation": "b", "op": {"kind": "inbox.pin", "pinned": true, "position": 99}}])
    );
    assert_eq!(edited["command"], "conversation-inbox-op");
    let again = op(
        "inboxEdit",
        json!({"reply": edited["reply"], "isCloud": false, "now": 100, "edit": {"setPinned": {"on": true, "id": "b"}}}),
    );
    assert_eq!(again["writes"], json!([]));
    let off = op(
        "inboxEdit",
        json!({"reply": edited["reply"], "isCloud": false, "now": 100, "edit": {"setPinned": {"on": false, "id": "b"}}}),
    );
    assert_eq!(off["writes"][0]["op"], json!({"kind": "inbox.pin", "pinned": false}));
}

#[test]
fn adopting_places_rows_at_consecutive_positions() {
    let reply = json!({"me": "p_me", "rows": [row("a", "2026-11-25T00:00:00Z"), row("b", "2026-11-25T00:00:00Z")]});
    let edited = op(
        "inboxEdit",
        json!({"reply": reply, "isCloud": true, "now": 10, "edit": {"adopt": {"ids": ["b", "a"]}}}),
    );
    assert_eq!(ids(&edited["reply"]["rows"]), ["b", "a"]);
    let positions: Vec<&Value> =
        edited["writes"].as_array().unwrap().iter().map(|w| &w["op"]["position"]).collect();
    assert_eq!(positions, [&json!(10), &json!(11)]);
    assert_eq!(edited["command"], "cloud-inbox-op");
}

#[test]
fn marks_and_mutes_send_only_a_change_and_mute_is_cloud_only() {
    let reply = json!({"me": "p_me", "rows": [row("a", "2026-11-25T00:00:00Z")]});
    let edit = |edit: Value, cloud: bool| {
        op("inboxEdit", json!({"reply": reply, "isCloud": cloud, "now": 0, "edit": edit}))
    };
    assert_eq!(
        edit(json!({"setMarkedUnread": {"on": true, "id": "a"}}), false)["writes"][0]["op"],
        json!({"kind": "inbox.mark_unread", "unread": true})
    );
    assert_eq!(
        edit(json!({"setMarkedUnread": {"on": false, "id": "a"}}), false)["writes"],
        json!([])
    );
    assert_eq!(
        edit(json!({"setMuted": {"on": true, "id": "a"}}), true)["writes"][0]["op"],
        json!({"kind": "inbox.mute", "muted": true})
    );
    assert_eq!(edit(json!({"setMuted": {"on": true, "id": "a"}}), false)["writes"], json!([]));
    assert_eq!(edit(json!({"canMute": {"id": "a"}}), true)["canMute"], true);
    assert_eq!(edit(json!({"canMute": {"id": "a"}}), false)["canMute"], false);
    assert_eq!(edit(json!({"canMute": {"id": "zz"}}), true)["canMute"], false);
}
