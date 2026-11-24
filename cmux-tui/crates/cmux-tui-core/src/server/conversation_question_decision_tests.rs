//! conversation_question_decision.rs: the unsigned decision comes only from the live, local,
//! matching prompt, and the command is the trusted local connection's alone.

use serde_json::{Value, json};

use super::super::*;
use super::{
    check_displayed, decide_from, decide_over, error_code, record_question, request_digest,
};
use cmux_conversation::{Question, QuestionAnswer};

fn question(permission: Option<&str>) -> Question {
    serde_json::from_value(json!({
        "harness": "chief", "session": "sess_mux", "permission": permission,
        "items": [{"id": "q0", "prompt": "Ship it?", "multi_select": false,
                   "options": [{"id": "yes", "label": "Yes"}, {"id": "no", "label": "No"}]}]
    }))
    .unwrap()
}

fn answer() -> QuestionAnswer {
    serde_json::from_value(json!({"selections": {"q0": {"option_ids": ["yes"]}}})).unwrap()
}

fn entry(permission: &str) -> Value {
    json!({"permissionId": permission, "personInstance": "0123456789abcdef",
           "decisionNonce": "b".repeat(64), "request": {
        "toolCall": {"_meta": {"acpmux": {"question": {"harness": "chief", "items": [
            {"id": "q0", "prompt": "Ship it?", "multiSelect": false, "allowsOther": true,
             "options": [{"id": "yes", "label": "Yes"}, {"id": "no", "label": "No"}]}]}}}},
        "options": [{"optionId": "answer", "kind": "allow_once", "name": "Answer"}]}})
}

fn code(result: anyhow::Result<Value>) -> String {
    error_code(&result.expect_err("the decision must be refused")).unwrap()
}

#[test]
fn the_decision_is_the_live_prompts_with_its_request() {
    let info = json!({"pending": [entry("perm_other"), entry("perm_1")]});
    let decided = decide_from(&question(Some("perm_1")), &answer(), &info).unwrap();
    assert_eq!(decided["permission"], "perm_1");
    assert_eq!(decided["session"], "sess_mux");
    assert_eq!(decided["option_id"], "answer");
    assert_eq!(decided["instance"], "0123456789abcdef");
    assert_eq!(decided["decision_nonce"], "b".repeat(64));
    assert_eq!(decided["answers"], json!({"Ship it?": "Yes"}));
    assert_eq!(decided["request"], entry("perm_1")["request"]);
    assert_eq!(decided["question"], serde_json::to_value(question(Some("perm_1"))).unwrap());
    assert_eq!(decided["digest"], request_digest(&entry("perm_1")["request"]));
    let text = decided["request_json"].as_str().unwrap();
    assert_eq!(serde_json::from_str::<Value>(text).unwrap(), entry("perm_1")["request"]);
    assert_eq!(decided["digest"], request_digest(&serde_json::from_str(text).unwrap()));
}

#[test]
fn a_closed_peer_or_changed_prompt_gets_no_decision() {
    let q = question(Some("perm_1"));
    assert_eq!(code(decide_from(&q, &answer(), &json!({"pending": []}))), "question.closed");
    assert_eq!(code(decide_from(&q, &answer(), &json!({}))), "question.closed");
    let peer = json!({"peer": "other-mac", "pending": [entry("perm_1")]});
    assert_eq!(code(decide_from(&q, &answer(), &peer)), "question.not_local");
    let mut changed = entry("perm_1");
    changed["request"]["toolCall"]["_meta"]["acpmux"]["question"]["items"][0]["prompt"] =
        json!("Delete it?");
    assert_eq!(code(decide_from(&q, &answer(), &json!({"pending": [changed]}))), "question.stale");
    assert_eq!(
        code(decide_from(&question(None), &answer(), &json!({"pending": [entry("perm_1")]}))),
        "question.no_request"
    );
}

#[test]
fn only_a_trusted_local_connection_asks_and_a_missing_part_is_not_found() {
    let mux = Mux::new_for_test("question-decision", crate::SurfaceOptions::default());
    let writer = || {
        MessageWriter::new(QueuedSink {
            outbound: Arc::new(BoundedOutbound::default()),
            control: None,
        })
    };
    let request = json!({"cmd": "conversation-question-decision", "conversation": "c1",
                         "message_id": "m1", "part_index": 0,
                         "answer": {"selections": {"q0": {"option_ids": ["yes"]}}}});
    let run = |client: u64| {
        let command: Command = serde_json::from_value(request.clone()).unwrap();
        handle_command(&mux, client, command, &writer())
    };
    let local = mux.control_clients.register(ClientTransport::Unix, writer());
    let error = run(local).expect_err("no such message");
    assert_eq!(response_error_code(&error).as_deref(), Some("question.not_found"));
    let remote = mux.control_clients.register(ClientTransport::Remote, writer());
    let error = run(remote).expect_err("a remote peer is refused");
    // The exact-name remote allowlist refuses it before the handler runs.
    assert_eq!(error.to_string(), "remote_denied");
}

#[test]
fn the_digest_sorts_keys_at_every_depth_and_an_approval_card_is_refused() {
    use sha2::{Digest, Sha256};
    let request = json!({"b": {"y": 1, "x": [{"d": 2, "c": "é"}]}, "a": null});
    let expected = format!(
        "{:x}",
        Sha256::digest(r#"{"a":null,"b":{"x":[{"c":"é","d":2}],"y":1}}"#.as_bytes())
    );
    assert_eq!(request_digest(&request), expected);
    let card: Question = serde_json::from_value(json!({
        "harness": "chief", "session": "sess_mux", "permission": "perm_1",
        "items": [{"id": format!("approval:{}", "a".repeat(64)), "prompt": "Run it?",
                   "multi_select": false, "allows_other": false,
                   "options": [{"id": "allow", "label": "Allow"}, {"id": "deny", "label": "Deny"}]}]
    }))
    .unwrap();
    let info = json!({"pending": [entry("perm_1")]});
    assert_eq!(code(decide_from(&card, &answer(), &info)), "question.native_approval");
}

/// The native record read returns the stored approval card unchanged, never a question's, and
/// only while it is pending.
#[test]
fn the_native_record_read_is_the_pending_approval_card_only() {
    let stored = json!({
        "harness": "chief", "session": "sess_mux", "permission": "perm_1", "agent": "Chief",
        "items": [{"id": format!("approval:{}", "a".repeat(64)), "header": "Tool", "prompt": "Run \"ls\" ✓?",
                   "multi_select": false, "allows_other": false,
                   "options": [{"id": "allow", "label": "Allow", "preview": {"text": "{\"a\":1}"}},
                               {"id": "deny", "label": "Deny"}]}]
    });
    let card: Question = serde_json::from_value(stored).unwrap();
    let read = record_question(&card).unwrap();
    assert_eq!(read, json!({"question": serde_json::to_value(&card).unwrap()}));
    let back: Question = serde_json::from_value(read["question"].clone()).unwrap();
    assert_eq!(back, card);
    assert_eq!(code(record_question(&question(Some("perm_1")))), "question.not_approval");
    let mut answered = card;
    answered.state = serde_json::from_value(json!({"kind": "cancelled"})).unwrap();
    assert_eq!(code(record_question(&answered)), "question.closed");
}

/// The request digest is the golden sha256, the bytes acpmux hashes and the app checks.
#[cfg(unix)]
#[test]
fn request_digest_matches_the_golden_fixture_and_acpmux() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../cmux-conversation/tests/fixtures/canonical_json.json"
    ))
    .unwrap();
    for case in fixture["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        assert_eq!(request_digest(&case["value"]), case["sha256"].as_str().unwrap(), "{name}");
        let mut acpmux = String::new();
        acpmux::hub::approvers::canonical_json(&case["value"], &mut acpmux);
        assert_eq!(acpmux, case["canonical"].as_str().unwrap(), "{name}");
    }
}

/// A deadline with a whole budget left.
fn soon() -> Instant {
    Instant::now() + Duration::from_secs(60)
}

/// `_acpmux/info` of a Chief owner subagent `raw` of home `1234abcd`, holding one prompt.
fn owned_info(raw: &str, permission: &str) -> Value {
    json!({"sessionId": raw, "policy": "approve-all", "pending": [entry(permission)],
           "tags": {"mux.parent": "optchat-chief:1234abcd", "optchat.subagent": "worker"}})
}

/// Routing is the Chief's: a socket whose acpmux holds the session but not as this Chief's owner
/// subagent gives no decision, and the next candidate that does gives it.
#[test]
fn a_non_owner_socket_is_skipped_and_the_owner_socket_decides() {
    use std::path::{Path, PathBuf};
    let q = question(Some("perm_1"));
    let sockets = [PathBuf::from("/other"), PathBuf::from("/owner")];
    let mut asked = Vec::new();
    let decided = decide_over(
        &q,
        &answer(),
        "sess_mux",
        &sockets,
        Some("1234abcd"),
        soon(),
        |socket, session, _| {
            asked.push((socket.to_owned(), session.to_owned()));
            if socket == Path::new("/other") {
                let mut info = owned_info("sess_mux", "perm_1");
                info["tags"]["mux.parent"] = json!("optchat-chief:87654321");
                return Ok(info);
            }
            Ok(owned_info("sess_mux", "perm_1"))
        },
    )
    .unwrap();
    assert_eq!(decided["permission"], "perm_1");
    assert_eq!(asked.len(), 2);
    assert!(asked.iter().all(|(_, session)| session == "sess_mux"));
    // Only the non-owner: refused, never decided from it.
    let only_other = [PathBuf::from("/other")];
    let refused =
        decide_over(&q, &answer(), "sess_mux", &only_other, Some("1234abcd"), soon(), |_, _, _| {
            let mut info = owned_info("sess_mux", "perm_1");
            info["tags"]["optchat.subagent"] = json!("");
            Ok(info)
        });
    assert_eq!(code(refused), "question.not_local");
}

/// A socket answering for another session id, or as a peer, is never the owner, with or without a
/// resolved Chief route; with no route (the app socket) the session and peer checks still hold.
#[test]
fn a_socket_must_hold_the_exact_local_session() {
    use std::path::PathBuf;
    let q = question(Some("perm_1"));
    let sockets = [PathBuf::from("/app")];
    let wrong = decide_over(&q, &answer(), "sess_mux", &sockets, None, soon(), |_, _, _| {
        Ok(owned_info("sess_other", "perm_1"))
    });
    assert_eq!(code(wrong), "question.not_local");
    let peer = decide_over(&q, &answer(), "sess_mux", &sockets, None, soon(), |_, _, _| {
        let mut info = owned_info("sess_mux", "perm_1");
        info["peer"] = json!("other-mac");
        Ok(info)
    });
    assert_eq!(code(peer), "question.not_local");
    let unrouted = decide_over(&q, &answer(), "sess_mux", &sockets, None, soon(), |_, _, _| {
        Ok(json!({"sessionId": "sess_mux", "pending": [entry("perm_1")]}))
    });
    assert_eq!(unrouted.unwrap()["permission"], "perm_1");
    let gone = decide_over(&q, &answer(), "sess_mux", &sockets, None, soon(), |_, _, _| {
        Err("question.agent_gone")
    });
    assert_eq!(code(gone), "question.agent_gone");
}

/// The signed identity is the raw local id however the stored question spells its session, the
/// reply's `question` is the stored one untouched, and a session that is no local id is refused.
#[test]
fn the_unsigned_session_is_the_raw_local_id() {
    let info = json!({"pending": [entry("perm_1")]});
    for stored in ["sess_mux", "local/sess_mux"] {
        let mut q = question(Some("perm_1"));
        q.session = stored.to_owned();
        let decided = decide_from(&q, &answer(), &info).unwrap();
        assert_eq!(decided["session"], "sess_mux", "{stored}");
        assert_eq!(decided["question"]["session"], stored, "{stored}");
    }
    for bad in ["peer/sess_mux", "local/local/sess_mux", "local/", "", "..", "a/b"] {
        let mut q = question(Some("perm_1"));
        q.session = bad.to_owned();
        assert_eq!(code(decide_from(&q, &answer(), &info)), "question.not_local", "{bad}");
    }
}

/// One deadline covers every socket: with less than a connect's bound left no socket is tried at
/// all, and the shared deadline is what each read is handed.
#[test]
fn no_socket_is_tried_past_the_shared_budget() {
    use std::path::PathBuf;
    use std::time::{Duration, Instant};
    let q = question(Some("perm_1"));
    let sockets = [PathBuf::from("/a"), PathBuf::from("/b")];
    let spent = Instant::now();
    let refused = decide_over(&q, &answer(), "sess_mux", &sockets, None, spent, |_, _, _| {
        panic!("a socket was tried past the budget")
    });
    assert_eq!(code(refused), "question.agent_busy");
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut seen = Vec::new();
    let refused =
        decide_over(&q, &answer(), "sess_mux", &sockets, None, deadline, |_, _, until| {
            seen.push(until);
            Err("question.agent_gone")
        });
    assert_eq!(code(refused), "question.agent_gone");
    assert_eq!(seen, [deadline, deadline]);
}

/// A real acpmux that never answers holds the exchange to its deadline, not past it.
#[cfg(unix)]
#[test]
fn a_silent_acpmux_is_held_to_the_deadline() {
    use std::os::unix::net::UnixListener;
    use std::time::{Duration, Instant};
    let dir = cmux_unix_socket::short_test_dir("qdecide");
    let socket = dir.path().join("acpmux.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let held = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        std::thread::sleep(Duration::from_secs(3));
        drop(stream);
    });
    let started = Instant::now();
    let error = super::read_info(&socket, "sess_mux", started + Duration::from_millis(300))
        .expect_err("a silent acpmux gives no info");
    assert_eq!(error, "question.agent_busy");
    assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
    held.join().unwrap();
}

/// The person signs for the question Home displayed: the displayed JSON must parse to exactly the
/// stored question, and a signing read without one is refused.
#[test]
fn the_displayed_question_must_be_the_stored_one() {
    let stored = question(Some("perm_1"));
    let shown = serde_json::to_value(&stored).unwrap();
    assert!(check_displayed(&stored, Some(&shown), true).is_ok());
    // Another spelling of the same question (extra or reordered fields) is the same question.
    let mut spelled = shown.clone();
    spelled["unknown_field"] = json!(1);
    assert!(check_displayed(&stored, Some(&spelled), true).is_ok());
    let stale = |displayed: Option<&Value>, required| {
        error_code(&check_displayed(&stored, displayed, required).unwrap_err()).unwrap()
    };
    assert_eq!(stale(None, true), "question.stale");
    assert!(check_displayed(&stored, None, false).is_ok());
    let mut changed = shown.clone();
    changed["items"][0]["prompt"] = json!("Delete it?");
    assert_eq!(stale(Some(&changed), true), "question.stale");
    let mut other_option = shown.clone();
    other_option["items"][0]["options"][0]["label"] = json!("Yep");
    assert_eq!(stale(Some(&other_option), true), "question.stale");
    let mut closed = shown;
    closed["state"] = json!({"kind": "cancelled"});
    assert_eq!(stale(Some(&closed), true), "question.stale");
    assert_eq!(stale(Some(&json!("not a question")), true), "question.stale");
    assert_eq!(stale(Some(&changed), false), "question.stale");
}
