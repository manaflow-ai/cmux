//! Round trips against the JSON `plans/cmux-next/auto-mode/DESIGN.md` writes.

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use super::*;

/// `text` reads as `T`, and `T` writes the same JSON back.
fn round_trip<T: Serialize + DeserializeOwned>(text: &str) -> T {
    let written: Value = serde_json::from_str(text).expect("the literal is JSON");
    let read: T = serde_json::from_str(text).expect("the literal reads");
    assert_eq!(serde_json::to_value(&read).expect("it writes"), written);
    read
}

/// The design's `session`, with one holder and one state where it lists the choices.
fn session_text(holder: &str, state: &str) -> String {
    let text = r#"{ "id": "…", "title": "…", "harness": "claude", "team": "…", "owner": "…",
  "auto": true, "keepInCloud": false,
  "holder": "device:… | vm:… | parked", "epoch": 1,
  "state": "local | cloud | resuming | parked | coming_back", "blocked": null,
  "needsRun": false, "standby": ["device:…"],
  "lastSeq": 0, "snapshot": 0, "inbox": 0, "inboxAcked": 0,
  "repo": { "remote": "…", "branch": "…" },
  "version": 1, "createdAt": 0, "updatedAt": 0, "leaseExpiresAt": 0 }"#;
    text.replace("device:… | vm:… | parked", holder)
        .replace("local | cloud | resuming | parked | coming_back", state)
}

#[test]
fn the_session_view_round_trips() {
    for (holder, parsed) in
        [("device:…", Holder::device("…")), ("vm:…", Holder::vm("…")), ("parked", Holder::Parked)]
    {
        for state in State::ALL {
            let session: SessionView = round_trip(&session_text(holder, state.as_str()));
            assert_eq!(session.holder, parsed);
            assert_eq!(session.state, state);
            assert_eq!(session.epoch, 1);
            assert_eq!(session.standby, vec![Holder::device("…")]);
            assert_eq!(session.blocked, None);
            assert_eq!(session.repo, Some(Repo { remote: "…".into(), branch: "…".into() }));
        }
    }
}

#[test]
fn a_session_view_reads_without_the_fields_a_store_may_leave_out() {
    let session: SessionView = serde_json::from_value(json!({
        "id": "s1", "auto": true, "holder": "parked", "epoch": 3, "state": "parked",
        "blocked": "no_machine", "version": 9, "aFieldFromANewerStore": [1, 2]
    }))
    .expect("a short view reads");
    assert_eq!(session.blocked, Some(Blocked::NoMachine));
    assert_eq!(session.repo, None);
    assert!(session.standby.is_empty());
    assert!(!session.inbox_pending());
}

#[test]
fn a_holder_is_a_device_a_machine_or_parked() {
    for (text, holder) in [
        ("device:mac-1", Holder::device("mac-1")),
        ("vm:vm_0123456789abcdefghij", Holder::vm("vm_0123456789abcdefghij")),
        ("parked", Holder::Parked),
    ] {
        assert_eq!(text.parse::<Holder>(), Ok(holder.clone()));
        assert_eq!(holder.to_string(), text);
        assert_eq!(serde_json::to_value(&holder).expect("writes"), json!(text));
        assert_eq!(serde_json::from_value::<Holder>(json!(text)).expect("reads"), holder);
    }
    for bad in ["", "device:", "vm:", "device", "laptop:1", "Parked", "vm: x", "parked:1"] {
        assert!(bad.parse::<Holder>().is_err(), "{bad:?}");
        assert!(serde_json::from_value::<Holder>(json!(bad)).is_err(), "{bad:?}");
    }
}

#[test]
fn the_manifest_round_trips() {
    let manifest: Manifest = round_trip(
        r#"{ "v": 1, "at": 0, "lastSeq": 0,
  "harness": "claude", "harnessSessionId": "…",
  "cwd": { "kind": "git", "remote": "https://…", "branch": "…", "base": "<sha the remote has>",
           "bundle": ["<chunk sha256>"], "patch": ["<chunk sha256>"] },
  "queue": [ { "id": "…", "text": "…" } ], "draft": "…",
  "openTurn": { "turnId": "…", "promptId": "…", "tool": { "name": "Bash", "args": "…" } } }"#,
    );
    assert!(matches!(manifest.cwd, Cwd::Git { .. }));
    assert_eq!(manifest.chunks().count(), 2);
    let tool = manifest.open_turn.and_then(|turn| turn.tool).expect("the tool in flight");
    assert_eq!(tool.name, "Bash");
}

#[test]
fn a_folder_manifest_carries_a_tar() {
    let manifest: Manifest = round_trip(
        r#"{ "v": 1, "at": 5, "lastSeq": 12, "harness": "codex", "harnessSessionId": "h",
  "cwd": { "kind": "folder", "tar": ["a", "b", "c"] }, "queue": [], "draft": "" }"#,
    );
    assert_eq!(manifest.cwd, Cwd::Folder { tar: vec!["a".into(), "b".into(), "c".into()] });
    assert_eq!(manifest.chunks().collect::<Vec<_>>(), ["a", "b", "c"]);
    assert_eq!(manifest.open_turn, None);
}

#[test]
fn the_lease_round_trips() {
    let request: LeaseRequest = round_trip(
        r#"{ "holder": "device:mac-1", "epoch": 4, "needsRun": true, "standby": true }"#,
    );
    assert_eq!(request.standby, Some(true));
    // `standby?` is left out when the holder renews.
    let holder = LeaseRequest { standby: None, ..request };
    assert_eq!(
        serde_json::to_value(&holder).expect("writes"),
        json!({ "holder": "device:mac-1", "epoch": 4, "needsRun": true })
    );
    for role in Role::ALL {
        let text = format!(
            r#"{{ "session": {}, "role": "{}", "leaseMs": 45000 }}"#,
            session_text("vm:m", "cloud"),
            role.as_str()
        );
        let answer: LeaseAnswer = round_trip(&text);
        assert_eq!(answer.role, role);
        assert_eq!(answer.lease_ms, crate::consts::LEASE_MS);
    }
}

#[test]
fn the_holder_writes_round_trip() {
    let fence: Fence = round_trip(r#"{ "holder": "vm:m", "epoch": 2 }"#);
    assert_eq!(fence, Fence::new(Holder::vm("m"), 2));
    let append: EventsAppend = round_trip(
        r#"{ "holder": "device:d", "epoch": 1,
             "events": [ { "seq": 1, "record": { "type": "user_message", "text": "hi" } },
                         { "seq": 2, "record": { "type": "turn_started" } } ] }"#,
    );
    assert_eq!(append.events.len(), 2);
    assert_eq!(round_trip::<EventsAppended>(r#"{ "lastSeq": 2 }"#).last_seq, 2);
    let page: EventsPage =
        round_trip(r#"{ "events": [ { "seq": 3, "record": "x" } ], "lastSeq": 3 }"#);
    assert_eq!(page.last_seq, 3);
    assert_eq!(round_trip::<SnapshotPosted>(r#"{ "snapshot": 7 }"#).snapshot, 7);
    let ack: InboxAck = round_trip(r#"{ "holder": "device:d", "epoch": 1, "through": 3 }"#);
    assert_eq!(ack.through, 3);
}

#[test]
fn the_snapshot_routes_round_trip() {
    let manifest = r#"{ "v": 1, "at": 1, "lastSeq": 2, "harness": "claude",
        "harnessSessionId": "h", "cwd": { "kind": "folder", "tar": [] }, "queue": [],
        "draft": "" }"#;
    let post: SnapshotPost =
        round_trip(&format!(r#"{{ "holder": "device:d", "epoch": 1, "manifest": {manifest} }}"#));
    assert_eq!(post.manifest.last_seq, 2);
    let answer: SnapshotAnswer =
        round_trip(&format!(r#"{{ "snapshot": 4, "manifest": {manifest} }}"#));
    assert_eq!(answer.snapshot, 4);
}

#[test]
fn the_inbox_round_trips() {
    let post: InboxPost = round_trip(r#"{ "id": "m1", "text": "keep going" }"#);
    assert_eq!(post.id, "m1");
    for state in Delivery::ALL {
        let text = format!(
            r#"{{ "state": "{}", "session": {} }}"#,
            state.as_str(),
            session_text("parked", "parked")
        );
        assert_eq!(round_trip::<InboxPosted>(&text).state, state);
    }
    let page: InboxPage =
        round_trip(r#"{ "messages": [ { "n": 1, "id": "m1", "text": "keep going", "at": 9 } ] }"#);
    assert_eq!(page.messages.first().map(|message| message.n), Some(1));
}

#[test]
fn the_owner_routes_round_trip() {
    let machine: MachineSetting = round_trip(r#"{ "team": "t", "machine": "vm_1" }"#);
    assert_eq!(machine.machine, "vm_1");
    let put: PutRequest = round_trip(
        r#"{ "auto": true, "title": "Fix the build", "harness": "claude", "device": "mac-1",
             "keepInCloud": false, "repo": { "remote": "https://example.com/r.git", "branch": "main" } }"#,
    );
    assert_eq!(put.keep_in_cloud, Some(false));
    let short: PutRequest = round_trip(
        r#"{ "auto": false, "title": "Fix the build", "harness": "claude", "device": "mac-1" }"#,
    );
    assert_eq!(short.repo, None);
    let create: CreateRequest = round_trip(
        r#"{ "title": "From the phone", "harness": "codex",
             "repo": { "remote": "https://example.com/r.git", "branch": "main" },
             "firstMessage": { "id": "m1", "text": "start" } }"#,
    );
    assert_eq!(create.first_message.text, "start");
    let untitled: CreateRequest = round_trip(
        r#"{ "harness": "codex", "repo": { "remote": "r", "branch": "b" },
             "firstMessage": { "id": "m1", "text": "start" } }"#,
    );
    assert_eq!(untitled.title, None);
    assert!(round_trip::<KeepRequest>(r#"{ "keepInCloud": true }"#).keep_in_cloud);
    let list: SessionList = round_trip(&format!(
        r#"{{ "sessions": [{}], "nextCursor": "c2" }}"#,
        session_text("parked", "parked")
    ));
    assert_eq!(list.next_cursor.as_deref(), Some("c2"));
    let answer: SessionAnswer =
        round_trip(&format!(r#"{{ "session": {} }}"#, session_text("vm:m", "resuming")));
    assert_eq!(answer.session.state, State::Resuming);
}

#[test]
fn the_assignments_round_trip() {
    for kind in AssignmentKind::ALL {
        let text = format!(
            r#"{{ "assignments": [ {{ "kind": "{}", "session": {} }} ] }}"#,
            kind.as_str(),
            session_text("vm:m", "resuming")
        );
        let read: Assignments = round_trip(&text);
        assert_eq!(read.assignments.first().map(|assignment| assignment.kind), Some(kind));
    }
}

#[test]
fn every_auto_code_reads_from_the_error_envelope() {
    let codes = [
        "auto.stale_epoch",
        "auto.not_holder",
        "auto.no_machine",
        "auto.held_in_cloud",
        "auto.seq_gap",
        "auto.snapshot_incomplete",
        "auto.no_snapshot",
        "auto.chunk_mismatch",
        "auto.too_large",
        "auto.closed",
    ];
    assert_eq!(codes.len(), ErrorCode::ALL.len());
    for (text, code) in codes.into_iter().zip(ErrorCode::ALL) {
        let envelope: ErrorEnvelope =
            round_trip(&format!(r#"{{ "error": {{ "code": "{text}", "message": "why" }} }}"#));
        assert_eq!(envelope.code(), Some(code));
        assert_eq!(code.as_str(), text);
        assert_eq!(serde_json::to_value(code).expect("writes"), json!(text));
        assert_eq!(ErrorCode::parse(text), Some(code));
    }
    let other: ErrorEnvelope = round_trip(
        r#"{ "error": { "code": "validation.invalid", "message": "epoch: a number" } }"#,
    );
    assert_eq!(other.code(), None);
}

#[test]
fn a_gap_and_an_incomplete_snapshot_say_what_the_store_has() {
    let gap: ErrorEnvelope = round_trip(
        r#"{ "error": { "code": "auto.seq_gap", "message": "seq 9 after 4" }, "lastSeq": 4 }"#,
    );
    assert_eq!(gap.last_seq, Some(4));
    let incomplete: ErrorEnvelope = round_trip(
        r#"{ "error": { "code": "auto.snapshot_incomplete", "message": "2 chunks missing" },
             "missing": ["aa", "bb"] }"#,
    );
    assert_eq!(incomplete.missing, ["aa", "bb"]);
}

#[test]
fn a_refusal_about_a_chat_carries_the_chat() {
    let text = format!(
        r#"{{ "error": {{ "code": "auto.stale_epoch", "message": "epoch 1 is over" }},
              "session": {} }}"#,
        session_text("vm:m1", "cloud")
    );
    let refused: ErrorEnvelope = round_trip(&text);
    let session = refused.session.expect("the chat");
    assert_eq!((session.holder, session.epoch), (Holder::vm("m1"), 1));
    assert_eq!(session.team.as_deref(), Some("…"));
}

#[test]
fn a_chat_with_no_team_reads() {
    let session: SessionView = serde_json::from_value(json!({
        "id": "s1", "team": null, "auto": true, "holder": "device:mac", "epoch": 1,
        "state": "local", "version": 1
    }))
    .expect("a null team reads");
    assert_eq!(session.team, None);
}
