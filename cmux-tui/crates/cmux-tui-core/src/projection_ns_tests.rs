//! The daemon hosts one namespace authority per chat, and its JSON API runs the lease protocol.

use serde_json::json;

use super::*;

#[test]
fn one_authority_per_chat_and_versions_do_not_leak_between_chats() {
    let chat = "ns-test-per-chat-a";
    let other = "ns-test-per-chat-b";
    let open = |chat: &str| {
        answer_at(&json!({"cmd": "ns.open", "chat": chat, "member": "work-vm", "path": "f"}), 0)
    };
    assert_eq!(open(chat)["data"]["version"]["seq"], 0);
    let acquired = answer_at(
        &json!({"cmd": "ns.acquire", "chat": chat, "owners": ["agent"], "member": "agent-vm",
                "actor": "agent", "path": "f"}),
        1,
    );
    assert_eq!(acquired["data"]["acquire"], "granted", "{acquired}");
    let token = acquired["data"]["token"].clone();
    let closed = answer_at(
        &json!({"cmd": "ns.close", "chat": chat, "token": token,
                "meta": {"size": 3, "mtime_ns": 1, "mode": 420, "chunks": ["c1"]}}),
        2,
    );
    assert_eq!(closed["data"]["version"]["seq"], 1, "{closed}");
    assert_eq!(closed["data"]["invalidate"], json!(["work-vm"]));
    let invalidations =
        answer_at(&json!({"cmd": "ns.invalidations", "chat": chat, "member": "work-vm"}), 3);
    assert_eq!(invalidations["data"]["paths"], json!(["f"]));
    assert_eq!(open(other)["data"]["version"]["seq"], 0);
    take(chat);
    take(other);
}

#[test]
fn contended_write_surfaces_a_conflict_event_and_resolves() {
    let chat = "ns-test-conflict";
    let acquire = |member: &str, actor: &str, at: u64| {
        answer_at(
            &json!({"cmd": "ns.acquire", "chat": chat, "member": member, "actor": actor,
                    "path": "notes.md"}),
            at,
        )
    };
    assert_eq!(acquire("vm-a", "collab-a", 0)["data"]["acquire"], "granted");
    assert_eq!(acquire("vm-b", "collab-b", 0)["data"]["acquire"], "wait");
    let private = acquire("vm-b", "collab-b", 5_000);
    assert_eq!(private["data"]["acquire"], "private", "{private}");
    let closed = answer_at(
        &json!({"cmd": "ns.close", "chat": chat, "token": private["data"]["token"]}),
        5_001,
    );
    assert_eq!(closed["data"]["path"], "notes.md.cmux-sync-conflict");
    let events = answer_at(&json!({"cmd": "ns.conflicts", "chat": chat}), 5_002);
    let event = &events["data"]["events"][0];
    assert_eq!(event["kind"], "sync_conflict");
    assert_eq!(event["path"], "notes.md");
    let resolved = answer_at(
        &json!({"cmd": "ns.resolve", "chat": chat, "id": event["id"], "choice": "open_both"}),
        5_003,
    );
    assert_eq!(resolved["ok"], true, "{resolved}");
    let events = answer_at(&json!({"cmd": "ns.conflicts", "chat": chat}), 5_004);
    assert_eq!(events["data"]["events"], json!([]));
    take(chat);
}

#[test]
fn moved_authority_keeps_its_leases() {
    let chat = "ns-test-move";
    let acquired = answer_at(
        &json!({"cmd": "ns.acquire", "chat": chat, "member": "vm-a", "actor": "collab",
                "path": "f"}),
        0,
    );
    let authority = take(chat).expect("hosted");
    restore(authority);
    let closed =
        answer(&json!({"cmd": "ns.close", "chat": chat, "token": acquired["data"]["token"]}));
    assert_eq!(closed["data"]["path"], "f", "{closed}");
    assert_eq!(closed["data"]["conflict"], serde_json::Value::Null);
    take(chat);
}

#[test]
fn bad_requests_are_refused_with_a_code() {
    let refused = answer_at(&json!({"cmd": "ns.open", "chat": "ns-test-bad"}), 0);
    assert_eq!(refused["error_code"], "ns.params_invalid");
    let unknown = answer_at(&json!({"cmd": "ns.close", "chat": "ns-test-bad", "token": 999}), 0);
    assert_eq!(unknown["error_code"], "ns.unknown_token");
    let cmd = answer_at(&json!({"cmd": "ns.nope", "chat": "ns-test-bad"}), 0);
    assert_eq!(cmd["error_code"], "ns.unknown_cmd");
    take("ns-test-bad");
}
