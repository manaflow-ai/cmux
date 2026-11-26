//! Parity tests for the cloud Home source's rules (`CloudHomeSource*.swift`).

use cmux_home_rules::ops::call;
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("cloud.{name}"), &request).expect(name)
}

fn keep(kind: &str, account: Value, cloud: Value) -> bool {
    op(
        "source_for_account",
        json!({ "event": { "kind": kind, "account": account }, "cloudId": cloud }),
    )["keep"]
        .as_bool()
        .unwrap()
}

#[test]
fn data_events_need_this_account() {
    for kind in ["changed", "resynced", "inboxChanged", "live", "runChanged", "typing"] {
        assert!(keep(kind, json!("abc"), json!("user_abc")), "{kind}");
        assert!(keep(kind, json!("user_abc"), json!("user_abc")), "{kind}");
        assert!(!keep(kind, json!("other"), json!("user_abc")), "{kind}");
        assert!(!keep(kind, Value::Null, json!("user_abc")), "{kind}");
        assert!(!keep(kind, json!("abc"), Value::Null), "{kind}");
    }
}

#[test]
fn state_events_without_an_account_are_kept() {
    for kind in ["inboxReset", "subscriptionState"] {
        assert!(keep(kind, Value::Null, json!("user_abc")));
        assert!(keep(kind, Value::Null, Value::Null));
        assert!(keep(kind, json!("abc"), json!("user_abc")));
        assert!(!keep(kind, json!("zzz"), json!("user_abc")));
    }
    for kind in ["sessionNeeded", "hostReplicaNeeded"] {
        assert!(keep(kind, json!("zzz"), json!("user_abc")));
        assert!(keep(kind, Value::Null, Value::Null));
    }
}

#[test]
fn revision_reads_strings_and_whole_numbers() {
    let rev = |v: Value| op("source_revision", json!({ "value": v }))["revision"].clone();
    assert_eq!(rev(json!("42")), json!(42));
    assert_eq!(rev(json!(7)), json!(7));
    assert_eq!(rev(json!(7.0)), json!(7));
    assert_eq!(rev(json!(7.5)), Value::Null);
    assert_eq!(rev(json!(-1)), Value::Null);
    assert_eq!(rev(json!("x")), Value::Null);
    assert_eq!(rev(json!(true)), Value::Null);
    assert_eq!(rev(Value::Null), Value::Null);
    assert_eq!(op("source_revision", json!({}))["revision"], Value::Null);
}

fn entry(id: &str) -> Value {
    json!({ "conversation": id, "rev": 1 })
}

#[test]
fn pages_keep_the_first_copy_and_stop_on_a_stuck_cursor() {
    let page = op(
        "source_inbox_page",
        json!({
            "entries": [entry("a"), entry("b")],
            "cursor": "c1",
            "page": { "entries": [entry("b"), entry("c")], "nextCursor": "c2" },
        }),
    );
    let ids: Vec<&str> = page["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["conversation"].as_str().unwrap())
        .collect();
    assert_eq!(ids, ["a", "b", "c"]);
    assert_eq!(page["nextCursor"], json!("c2"));
    assert_eq!(page["pages"], json!(2));

    let stuck = op(
        "source_inbox_page",
        json!({ "cursor": "c1", "page": { "entries": [], "nextCursor": "c1" } }),
    );
    assert_eq!(stuck["nextCursor"], Value::Null);

    let last = op("source_inbox_page", json!({ "cursor": "c1", "page": { "entries": [] } }));
    assert_eq!(last["nextCursor"], Value::Null);
}

#[test]
fn pages_stop_at_fifty() {
    let at = |pages: u32| {
        op(
            "source_inbox_page",
            json!({ "cursor": "x", "pages": pages, "page": { "entries": [], "nextCursor": "y" } }),
        )["nextCursor"]
            .clone()
    };
    assert_eq!(at(48), json!("y"));
    assert_eq!(at(49), Value::Null);
}

#[test]
fn merge_drops_unlisted_and_marks_gone() {
    let reply = op(
        "source_inbox_merge",
        json!({
            "list": [
                { "conversation": "a", "last_seq": 3 },
                { "conversation": "b", "removed": true },
                { "conversation": "c", "archived": true },
            ],
            "entries": { "a": entry("a"), "old": entry("old"), "new": entry("new"), "subbed": entry("subbed") },
            "created": ["new", "a"],
            "removed": ["a"],
            "targets": ["subbed"],
            "heads": { "a": 3, "old": 1, "subbed": 1 },
        }),
    );
    assert_eq!(reply["entries"].as_object().unwrap().keys().collect::<Vec<_>>(), ["a"]);
    assert_eq!(reply["created"], json!(["new"]));
    assert_eq!(reply["gone"], json!(["old", "subbed"]));
    assert_eq!(reply["removed"], json!(["old", "subbed"]));
    assert_eq!(reply["unlisted"], json!(["subbed"]));
    // a's head is as new as its entry.
    assert_eq!(reply["missing"], json!([]));
}

#[test]
fn merge_lets_newer_inbox_events_win() {
    let reply = op(
        "source_inbox_merge",
        json!({
            "list": [entry("a"), entry("b")],
            "revision": "10",
            "entries": { "a": { "conversation": "a", "rev": 9 } },
            "touched": { "a": 11, "b": 12, "c": 5 },
        }),
    );
    // a: the event's entry; b: removed by an event after the read.
    assert_eq!(reply["entries"], json!({ "a": { "conversation": "a", "rev": 9 } }));
    assert_eq!(reply["touched"], json!({ "a": 11, "b": 12 }));

    // Without a readable revision nothing is pruned.
    let reply = op(
        "source_inbox_merge",
        json!({ "list": [entry("a")], "revision": "x", "touched": { "a": 1 } }),
    );
    assert_eq!(reply["touched"], json!({ "a": 1 }));
    assert_eq!(reply["entries"]["a"], entry("a"));
}

#[test]
fn merge_reopens_closed_only_when_newly_listed() {
    let reply = op(
        "source_inbox_merge",
        json!({
            "list": [entry("a"), entry("b")],
            "entries": { "b": entry("b") },
            "closed": ["a", "b", "z"],
        }),
    );
    assert_eq!(reply["closed"], json!(["b", "z"]));
}

#[test]
fn missing_heads_are_sorted_and_skip_subscribed() {
    let reply = op(
        "source_inbox_merge",
        json!({
            "list": [
                { "conversation": "z", "last_seq": 1 },
                { "conversation": "m", "last_seq": 5 },
                { "conversation": "a", "last_seq": 2 },
                { "conversation": "s", "last_seq": 9 },
            ],
            "targets": ["s"],
            "heads": { "m": 4, "a": 2 },
        }),
    );
    assert_eq!(reply["missing"], json!(["m", "z"]));
}

#[test]
fn hydration_queues_once_and_caps_workers() {
    let first = op("source_hydrate", json!({ "ids": ["a", "b", "a"] }));
    assert_eq!(first["start"], json!(2));
    assert_eq!(first["state"]["queue"], json!(["a", "b"]));
    let second =
        op("source_hydrate", json!({ "state": first["state"], "ids": ["b", "c", "d", "e", "f"] }));
    assert_eq!(second["start"], json!(2));
    assert_eq!(second["state"]["workers"], json!(4));
    assert_eq!(second["state"]["queue"], json!(["a", "b", "c", "d", "e", "f"]));
    let third = op("source_hydrate", json!({ "state": second["state"], "ids": ["g"] }));
    assert_eq!(third["start"], json!(0));
}

#[test]
fn keys_release_on_commit_or_final_refusal_but_not_a_send() {
    let release = |op_name: &str, rejection: Value| {
        op("source_releases_key", json!({ "op": op_name, "rejection": rejection }))["release"]
            .as_bool()
            .unwrap()
    };
    assert!(release("editMessage", Value::Null));
    assert!(release("sendMessage", Value::Null));
    assert!(release("editMessage", json!({ "kind": "invalid", "reason": "x" })));
    assert!(release("editMessage", json!({ "kind": "notAuthorized" })));
    assert!(!release("sendMessage", json!({ "kind": "invalid", "reason": "x" })));
    assert!(!release("editMessage", json!({ "kind": "ownerUnreachable" })));
    assert!(!release("editMessage", json!({ "kind": "rateLimited", "retryAfter": 2.0 })));
    assert!(!release("editMessage", json!({ "kind": "indeterminate" })));
}

#[test]
fn derived_keys_match_the_ops() {
    let one = op("source_derived_keys", json!({ "key": "k", "participants": 1, "invites": 2 }));
    assert_eq!(one["participants"], json!(["k"]));
    assert_eq!(one["invites"], json!(["k:invite:0", "k:invite:1"]));
    assert_eq!(one["message"], json!("k:message"));
    let many = op("source_derived_keys", json!({ "key": "k", "participants": 2 }));
    assert_eq!(many["participants"], json!(["k:add:0", "k:add:1"]));
    assert_eq!(many["invites"], json!([]));
}

#[test]
fn masked_addresses() {
    let mask = |c: Value| op("source_masked", json!({ "contact": c }))["masked"].clone();
    assert_eq!(mask(json!({ "email": "alice@example.com" })), json!("a***@example.com"));
    assert_eq!(mask(json!({ "email": "@x.io" })), json!("***@x.io"));
    assert_eq!(mask(json!({ "email": "nope" })), json!("***"));
    assert_eq!(mask(json!({ "phone": "+14155550123" })), json!("+1 *** *** 0123"));
    assert_eq!(mask(json!({ "phone": "+441234567890" })), json!("+44 *** *** 7890"));
    assert_eq!(mask(json!({ "phone": "4155550123" })), json!("***"));
    assert_eq!(mask(json!({ "phone": "+4155550123" })), json!("***"));
    assert_eq!(mask(json!({ "phone": "+1415555012a" })), json!("***"));
}

#[test]
fn internal_ids() {
    let internal =
        |t: &str| op("source_internal_id", json!({ "text": t }))["internal"].as_bool().unwrap();
    assert!(internal("addr_ABREQ2"));
    assert!(internal("user_a-b_c"));
    assert!(internal("vm_1"));
    assert!(!internal("user_"));
    assert!(!internal("Alice"));
    assert!(!internal("bob_smith"));
    assert!(!internal("user_é"));
    assert!(!internal("user_a b"));
}

#[test]
fn message_request_rows() {
    let row = |r: Value| op("source_message_request", json!({ "request": r }))["request"].clone();
    let shown = row(json!({
        "conversation": "conv_1", "inviter": "Alice", "isGroup": true, "title": "conv_1",
        "preview": "hi", "createdAt": "2026-11-26T00:00:00Z", "trusted": false,
    }));
    assert_eq!(shown["inviter"], json!("Alice"));
    assert_eq!(shown["title"], Value::Null);
    assert_eq!(shown["isGroup"], json!(true));
    assert_eq!(
        row(json!({ "conversation": "conv_1", "inviter": "Bob", "title": "Trip" }))["title"],
        json!("Trip")
    );
    assert_eq!(row(json!({ "conversation": "", "inviter": "Alice" })), Value::Null);
    assert_eq!(row(json!({ "conversation": "conv_1", "inviter": "" })), Value::Null);
    assert_eq!(row(json!({ "conversation": "conv_1", "inviter": "user_abc" })), Value::Null);
}

#[test]
fn answers_map_to_ops() {
    assert_eq!(
        op("source_answer", json!({ "answer": "accept" })),
        json!({ "op": { "kind": "acceptRequest" }, "reloadInbox": true })
    );
    assert_eq!(op("source_answer", json!({ "answer": "decline" }))["op"]["block"], json!(false));
    assert_eq!(op("source_answer", json!({ "answer": "block" }))["op"]["block"], json!(true));
    assert!(call("cloud.source_answer", &json!({ "answer": "maybe" })).is_err());
}
