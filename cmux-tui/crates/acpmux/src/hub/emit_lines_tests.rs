//! [`Hub::emit_lines`] copies the log lines `display_logged` leaves as they are and parses only
//! the rest: its bytes are the ones a parse of every record wrote, over every kind of line.

use super::*;
use crate::store::{LocalStore, META_SCHEMA, SessionMeta};

fn hub(sessions: &Path) -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    Hub::new(cfg, Box::new(LocalStore::new(sessions.to_owned(), 8 << 20).unwrap()))
}

fn chat(hub: &Hub, id: &str) -> Arc<Session> {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": id, "name": id, "harness": "fake", "cwd": "/w",
        "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(id.to_owned(), session.clone());
    session
}

/// The lines as `emit_lines` wrote them before it read raw lines: every record parsed,
/// `display_logged`, written.
fn parsed_emit(hub: &Hub, session: &Session, after: u64, through: u64) -> (Vec<u8>, u64, String) {
    let (mut out, mut last, mut digest) = (Vec::new(), after, String::new());
    hub.store
        .scan(&session.id, after, &mut |mut e| {
            if e.seq > through {
                return false;
            }
            if e.seq == through {
                digest = crate::sha256::sha256_hex(&serde_json::to_vec(&e).unwrap());
            }
            last = e.seq;
            hub.display_logged(Some(session), &mut e);
            serde_json::to_writer(&mut out, &e).unwrap();
            out.push(b'\n');
            e.seq < through
        })
        .unwrap();
    (out, last, digest)
}

fn request(display: &str) -> Value {
    json!({"toolCall": {"toolCallId": "t1", "title": "Run ls", "kind": "execute",
        "rawInput": {"command": "ls -la"},
        "_meta": {"acpmux": {"display": display}}},
        "options": [{"optionId": "allow", "name": "Allow", "kind": "allow_once"}]})
}

/// Raw lines appended to the chat's newest log segment, as another writer or a torn write
/// leaves them.
fn append_raw(sessions: &Path, id: &str, lines: &[String]) {
    let events = sessions.join(id).join("events");
    let mut segments: Vec<_> =
        std::fs::read_dir(&events).unwrap().map(|e| e.unwrap().path()).collect();
    segments.sort();
    let mut file = std::fs::OpenOptions::new().append(true).open(segments.last().unwrap()).unwrap();
    for line in lines {
        std::io::Write::write_all(&mut file, line.as_bytes()).unwrap();
    }
}

#[test]
fn raw_lines_are_the_bytes_a_parse_of_every_record_writes() {
    let tmp = tempfile::tempdir().unwrap();
    let hub = hub(tmp.path());
    let session = chat(&hub, "emit");
    let update = |text: &str| {
        json!({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "emit", "update": {"sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": text}}}})
    };
    hub.append(&session, "in", "agent_message_chunk", update("plain words"));
    hub.append(
        &session,
        "in",
        "agent_message_chunk",
        update("ünïcödé \u{1F600} \"q\" \\ \u{1b}[0m\n"),
    );
    hub.append(
        &session,
        "out",
        "session/prompt",
        json!({"jsonrpc": "2.0", "id": 7,
        "method": "session/prompt", "params": {"n": 1.5, "big": 18446744073709551615u64,
        "neg": -3, "e": 1e300, "z": [], "o": {}, "nil": null, "b": true}}),
    );
    hub.append_with_host_seq(&session, "in", "agent_message_chunk", update("hosted"), Some(41));
    // Every record `display_logged` changes.
    for kind in ["permission_request", "permission_reissued", "permission_auto"] {
        hub.append(&session, "mux", kind, json!({"request": request("the agent's own words")}));
    }
    hub.append(
        &session,
        "mux",
        "permission_group",
        json!({"group": {"items": [
        {"request": request("one")}, {"request": request("two")}]}}),
    );
    hub.append(
        &session,
        "in",
        "session/request_permission",
        json!({"jsonrpc": "2.0",
        "id": 9, "method": "session/request_permission", "params": request("theirs")}),
    );
    hub.append(&session, "mux", "status", json!({"status": "idle"}));
    hub.append(&session, "in", "agent_message_chunk", update("before the odd lines"));
    hub.append(&session, "out", "x", json!({"hostSeq": null}));
    let next =
        hub.append(&session, "mux", "permission_request", json!({"request": request("y")})).seq + 1;
    append_raw(
        tmp.path(),
        "emit",
        &[
            // A field no build writes, a record whose fields are out of order or spaced, a null
            // `hostSeq`, a torn line, a blank line.
            format!(
                "{{\"seq\":{next},\"at\":5,\"dir\":\"in\",\"kind\":\"x\",\"msg\":{{}},\"extra\":1}}\n"
            ),
            format!(
                "{{\"at\":5,\"seq\":{},\"kind\":\"x\",\"dir\":\"in\",\"msg\":{{\"a\":2,\"b\":1}}}}\n",
                next + 1
            ),
            format!(
                "{{\"seq\": {}, \"at\":5,\"dir\":\"in\",\"kind\":\"x\",\"msg\":{{}}}}\n",
                next + 2
            ),
            format!(
                "{{\"seq\":{},\"at\":5,\"dir\":\"in\",\"kind\":\"x\",\"msg\":{{}},\"hostSeq\":null}}\n",
                next + 3
            ),
            format!("{{\"seq\":{},\"at\":5,\"dir\":\"in\",\"ki", next + 4),
            "\n".to_owned(),
            "\n".to_owned(),
        ],
    );
    // The log ends with the odd lines (the hub's next seq does not know them).
    let end = next + 3;
    for after in 0..end {
        for through in after + 1..=end {
            let mut out = Vec::new();
            let (last, digest) = hub.emit_lines(&session, after, through, &mut out).unwrap();
            let (want, want_last, want_digest) = parsed_emit(&hub, &session, after, through);
            assert_eq!(
                String::from_utf8_lossy(&out),
                String::from_utf8_lossy(&want),
                "after {after} through {through}"
            );
            assert_eq!(
                (last, &digest),
                (want_last, &want_digest),
                "after {after} through {through}"
            );
        }
    }
}

#[test]
fn display_may_change_reads_every_record_display_logged_changes() {
    let tmp = tempfile::tempdir().unwrap();
    let hub = hub(tmp.path());
    let session = chat(&hub, "may");
    let records = [
        ("mux", "permission_request", json!({"request": request("x")})),
        ("mux", "permission_reissued", json!({"request": request("x")})),
        ("mux", "permission_auto", json!({"request": request("x")})),
        ("mux", "permission_group", json!({"group": {"items": [{"request": request("x")}]}})),
        (
            "in",
            "session/request_permission",
            json!({"method": "session/request_permission",
            "params": request("x")}),
        ),
        (
            "in",
            "agent_message_chunk",
            json!({"method": "session/request_permission",
            "params": request("x")}),
        ),
    ];
    for (dir, kind, msg) in records {
        let rec = crate::store::EventRecord {
            seq: 1,
            at: 1,
            dir: dir.into(),
            kind: kind.into(),
            msg,
            host_seq: None,
        };
        let mut shown = rec.clone();
        hub.display_logged(Some(&session), &mut shown);
        assert_ne!(shown, rec, "{dir} {kind}: display_logged leaves it as it is");
        assert!(
            crate::hub::permissions::display_may_change(dir, kind, &rec.msg.to_string()),
            "{dir} {kind}"
        );
    }
    for (dir, kind) in [("mux", "status"), ("out", "permission_request"), ("in", "x")] {
        assert!(!crate::hub::permissions::display_may_change(dir, kind, "{}"), "{dir} {kind}");
    }
}
