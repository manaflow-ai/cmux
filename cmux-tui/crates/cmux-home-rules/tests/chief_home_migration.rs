//! `chief_home` adoption and migration: the cases of the Swift `ChiefAdoptionTests`,
//! `ChiefMigrationTests` and `ChiefMigrationPlanTests`.

use cmux_home_rules::call;
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("chief_home.{name}"), &request)
        .unwrap_or_else(|err| panic!("chief_home.{name}: {err}"))
}

#[test]
fn adoption_backs_up_the_nightly_home_once() {
    let nightly = "com.cmuxterm.app.nightly";
    let plan = op(
        "adoption_plan",
        json!({ "root": "/Users/me/.cmux/chief/default", "buildID": nightly, "names": ["state", "memory"], "now": 1_764_072_000 }),
    );
    assert_eq!(plan["step"], "adopt");
    assert_eq!(plan["recordPath"], "/Users/me/.cmux/chief/default/adopted.json");
    assert_eq!(plan["lockPath"], "/Users/me/.cmux/chief/default/state/host.lock");
    assert_eq!(plan["backupNeeded"], true);
    assert_eq!(plan["backups"], "/Users/me/.cmux/chief/.backups");
    assert_eq!(plan["target"], "/Users/me/.cmux/chief/.backups/default-20251125T120000Z");
    let again = |extra: Value| {
        let mut request = json!({ "root": "/r/default", "buildID": nightly, "names": ["state"] });
        request.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        op("adoption_plan", request)
    };
    assert_eq!(again(json!({}))["backupNeeded"], false);
    assert_eq!(again(json!({ "recordExists": true }))["step"], "nothingToDo");
    assert_eq!(again(json!({ "isolated": true }))["step"], "nothingToDo");
    assert_eq!(again(json!({ "buildID": "com.cmuxterm.app" }))["step"], "nothingToDo");

    let record = op(
        "adoption_record",
        json!({ "by": "com.cmuxterm.app.nightly", "now": 1_764_072_000, "backup": "/b/x" }),
    )["json"]
        .clone();
    assert_eq!(
        record,
        "{\n  \"at\" : \"2025-11-25T12:00:00Z\",\n  \"backup\" : \"\\/b\\/x\",\n  \"by\" : \"com.cmuxterm.app.nightly\",\n  \"raw\" : [\n\n  ]\n}"
    );
    let raw = op("adoption_record", json!({ "by": "b", "raw": ["m.sqlite3"] }))["json"].clone();
    assert!(raw.as_str().unwrap().contains("\"backup\" : null"));
    assert!(raw.as_str().unwrap().contains("\"raw\" : [\n    \"m.sqlite3\"\n  ]"));
    let sidecar = |name: &str| {
        op("adoption_is_sidecar", json!({ "name": name, "databases": ["m.sqlite3"] }))["sidecar"]
            .clone()
    };
    assert_eq!(sidecar("m.sqlite3-wal"), true);
    assert_eq!(sidecar("m.sqlite3-journal"), true);
    assert_eq!(sidecar("m.sqlite3"), false);
    assert_eq!(sidecar("n.sqlite3-shm"), false);
    assert_eq!(
        op(
            "adoption_raw_files",
            json!({ "name": "m.db", "names": ["m.db-shm", "m.db", "x", "m.db-wal"] })
        )["files"],
        json!(["m.db", "m.db-wal", "m.db-shm"])
    );
}

#[test]
fn migration_finds_old_chiefs_and_decides() {
    assert_eq!(
        op("migration_session_component", json!({ "session": "" }))["component"],
        "session-cbf29ce484222325"
    );
    let component =
        op("migration_session_component", json!({ "session": "a b/c" }))["component"].clone();
    assert!(component.as_str().unwrap().starts_with("a_b_c-"));
    assert_eq!(component.as_str().unwrap().len(), "a_b_c-".len() + 16);
    assert_eq!(op("migration_run_step", json!({ "isolated": true }))["step"], "nothingToDo");
    assert_eq!(op("migration_run_step", json!({ "recordExists": true }))["step"], "nothingToDo");
    assert_eq!(op("migration_run_step", json!({ "blocking": ["t"] }))["step"], "blocked");
    assert_eq!(op("migration_run_step", json!({}))["step"], "go");
    assert_eq!(
        op("migration_has_memory", json!({ "mainNames": ["2026-11-01.jsonl"] }))["hasMemory"],
        true
    );
    assert_eq!(op("migration_has_memory", json!({ "mainNames": ["x.md"] }))["hasMemory"], false);
    assert_eq!(op("migration_has_memory", json!({ "databaseExists": true }))["hasMemory"], true);
    for (name, skip) in
        [("lock", true), ("takeover.flock", true), ("a.tmp.1", true), ("memory.sqlite3", false)]
    {
        assert_eq!(op("migration_copy_skips", json!({ "name": name }))["skip"], skip, "{name}");
    }
    let host: Value = serde_json::from_str(
        op("migration_host_state", json!({ "conversation": "c1", "loggedSeq": 7 }))["json"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        host,
        json!({ "children": {}, "conversation": "c1", "logged_seq": 7, "orphans": [], "outbox": [], "turn": null })
    );
    let record = op(
        "migration_record",
        json!({ "status": "done", "now": 0, "olds": [{"tag": "t", "muxHome": "/h/t", "store": "/s/t"}] }),
    )["json"].clone();
    assert_eq!(
        record,
        "{\n  \"at\" : \"1970-01-01T00:00:00Z\",\n  \"sources\" : [\n    {\n      \"mux_home\" : \"\\/h\\/t\",\n      \"store\" : \"\\/s\\/t\",\n      \"tag\" : \"t\"\n    }\n  ],\n  \"status\" : \"done\"\n}"
    );
}

fn message(id: &str, seq: u64, author: &str, client: &str, at: &str) -> Value {
    json!({ "id": id, "seq": seq, "author": author, "clientMsgID": client, "createdAt": at, "parts": [{"type": "text", "text": id}] })
}

#[test]
fn the_plan_dedupes_and_moves_late_messages_after_the_memory() {
    let base = json!({
        "name": "a", "conversationID": "ca", "hostConversation": "ca", "loggedSeq": 1,
        "log": [{"i": 0, "kind": "user", "text": "h1", "date": "d"}],
        "messages": [
            message("h1", 1, "user_me", "k1", "2026-11-01T00:00:10Z"),
            message("r1", 2, "agent_mux", "turn:1", "2026-11-01T00:00:20Z"),
        ]
    });
    let other = json!({
        "name": "b", "conversationID": "cb",
        "messages": [
            message("h2", 1, "user_me", "k2", "2026-11-01T00:00:15.500Z"),
            message("h1", 2, "user_me", "k9", "2026-11-01T00:00:30Z"),
            message("h3", 3, "user_me", "k1", "2026-11-01T00:00:40Z"),
        ]
    });
    let plan = op("migration_plan", json!({ "sources": [base, other] }));
    let ids: Vec<&str> = plan["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["message"]["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, ["h1", "r1", "h2"]);
    assert_eq!(plan["duplicates"], 2);
    assert_eq!(plan["memory"], json!({ "kind": "copy", "source": 0 }));
    assert_eq!(plan["moved"], 1);
    assert_eq!(plan["unlogged"][0]["message"]["id"], "h2");
    assert_eq!(
        plan["imports"][2],
        json!({ "id": "h2", "clientMsgID": "k2", "author": "user_me", "parts": [{"type": "text", "text": "h2"}], "createdAt": "2026-11-01T00:00:15.500Z" })
    );

    let mut both = base.clone();
    both["name"] = json!("c");
    both["messages"] = json!([]);
    assert_eq!(
        op("migration_plan", json!({ "sources": [base, both] }))["memory"]["kind"],
        "interleave"
    );
    assert_eq!(op("migration_plan", json!({ "sources": [] }))["memory"]["kind"], "none");
}

#[test]
fn log_lines_dates_and_reads() {
    let line = op(
        "migration_log_line",
        json!({ "i": 0, "kind": "user", "text": "hi/x", "date": "d" }),
    )["line"]
        .clone();
    assert_eq!(line, "{\"date\":\"d\",\"i\":0,\"kind\":\"user\",\"size\":10,\"text\":\"hi/x\"}\n");
    assert_eq!(
        op(
            "migration_local_date",
            json!({ "text": "2026-11-25T23:30:00.123Z", "utcOffsetSeconds": 3600 })
        )["date"],
        "2026-11-26T00:30:00.123+01:00"
    );
    assert_eq!(
        op("migration_local_date", json!({ "text": "2026-11-25T12:00:00Z" }))["date"],
        "2026-11-25T12:00:00.000Z"
    );
    assert_eq!(op("migration_time", json!({ "text": "1970-01-01T00:01:00Z" }))["seconds"], 60.0);
    assert_eq!(
        op("migration_time", json!({ "text": "1970-01-01T01:00:00.5+01:00" }))["seconds"],
        0.5
    );
    assert_eq!(op("migration_time", json!({ "text": "nope" }))["seconds"], 0.0);

    let stored =
        r#"{"id":"m","seq":3,"author":"user_me","client_msg_id":"k","created_at":"t","parts":[]}"#;
    assert_eq!(op("migration_message", json!({ "text": stored }))["message"]["seq"], 3);
    assert_eq!(
        op("migration_message", json!({ "text": "{\"id\":\"m\"}" }))["message"],
        Value::Null
    );
    let entries = op(
        "migration_read_log",
        json!({ "files": [
            "{\"i\":2,\"kind\":\"user\",\"text\":\"b\",\"date\":\"d\"}\n\n",
            "{\"i\":1,\"kind\":\"agent\",\"text\":\"a\",\"date\":\"d\"}\nnot json\n"
        ] }),
    )["entries"]
        .clone();
    assert_eq!(
        entries.as_array().unwrap().iter().map(|e| e["i"].as_i64().unwrap()).collect::<Vec<_>>(),
        [1, 2]
    );

    assert_eq!(
        op(
            "migration_cursor",
            json!({ "state": {"host/conversation": "\"c1\"", "host/logged_seq": "9"} })
        ),
        json!({ "hostConversation": "c1", "loggedSeq": 9 })
    );
    assert_eq!(
        op("migration_cursor", json!({ "hostJson": "{\"conversation\":\"c2\",\"logged_seq\":4}" })),
        json!({ "hostConversation": "c2", "loggedSeq": 4 })
    );
    assert_eq!(op("migration_cursor", json!({}))["loggedSeq"], 0);
    let chief = op(
        "migration_pick_chief",
        json!({ "conversations": [
            {"id": "b", "participantsJson": "[\"user_me\",\"agent_mux\"]", "createdAt": "2"},
            {"id": "a", "participantsJson": "[\"agent_mux\"]", "createdAt": "2"},
            {"id": "z", "participantsJson": "[\"agent_muxer\"]", "createdAt": "1"}
        ] }),
    )["chief"]
        .clone();
    assert_eq!(chief["id"], "a");
}
