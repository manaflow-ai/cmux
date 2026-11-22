//! Every OpenCode store generation side by side in one data dir: 2.x
//! (`session_v2`), 1.2+ (`session`), 0.6-1.1 global JSON, 0.0.53-0.5
//! per-project JSON, and the Kilo fork.

mod common;

use std::path::Path;

use cmux_chat_index::{AdapterKind, PathRole, Resume, TitleSource, classify_path};
use common::{by_id, ids, scan, write};
use rusqlite::{Connection, params};
use serde_json::{Value, json};

fn v1_tables(conn: &Connection) {
    conn.execute_batch(
        "CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, slug TEXT, directory TEXT,
           title TEXT, version TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER);
         CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
         CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);",
    )
    .unwrap();
}

fn v2_tables(conn: &Connection) {
    conn.execute_batch(
        "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, fork_session_id TEXT,
           slug TEXT, directory TEXT, path TEXT, title TEXT, version TEXT, time_created INTEGER,
           time_updated INTEGER, time_archived INTEGER, time_suspended INTEGER);
         CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER,
           time_created INTEGER, time_updated INTEGER, data TEXT);",
    )
    .unwrap();
}

fn v2_session(conn: &Connection, id: &str, title: Option<&str>, parent: Option<&str>) {
    conn.execute(
        "INSERT INTO session_v2 (id, parent_id, directory, title, time_created, time_updated)
         VALUES (?1, ?2, '/v2/' || ?1, ?3, 1790848800000, 1790856000000)",
        params![id, parent, title],
    )
    .unwrap();
}

fn v2_message(conn: &Connection, session: &str, seq: i64, kind: &str, text: &str) {
    conn.execute(
        "INSERT INTO session_message (id, session_id, type, seq, data) VALUES (?1, ?2, ?3, ?4, ?5)",
        params![
            format!("msg_{session}_{seq}"),
            session,
            kind,
            seq,
            json!({"text": text}).to_string()
        ],
    )
    .unwrap();
}

#[test]
fn opencode_2_sessions_win_over_their_1_x_rows_and_untitled_ones_use_the_first_prompt() {
    let dir = tempfile::tempdir().unwrap();
    let conn = Connection::open(dir.path().join("opencode.db")).unwrap();
    v1_tables(&conn);
    v2_tables(&conn);
    // Migrated: in both tables; 2.x wins.
    conn.execute(
        "INSERT INTO session (id, directory, title, time_created, time_updated)
         VALUES ('ses_both', '/v1', 'Old title', 1, 2)",
        [],
    )
    .unwrap();
    v2_session(&conn, "ses_both", Some("New title"), None);
    // Created after a downgrade to 1.x: only in `session`.
    conn.execute(
        "INSERT INTO session (id, directory, title, time_created, time_updated)
         VALUES ('ses_v1_only', '/v1', 'Downgraded', 1790848800000, 1790849000000)",
        [],
    )
    .unwrap();
    v2_session(&conn, "ses_untitled", None, None);
    v2_message(&conn, "ses_untitled", 2, "user", "second prompt");
    v2_message(&conn, "ses_untitled", 1, "user", "first prompt\nmore");
    v2_message(&conn, "ses_untitled", 3, "assistant", "ok");
    v2_message(&conn, "ses_untitled", 4, "compaction", "summary");
    v2_session(&conn, "ses_child", Some("Child"), Some("ses_both"));

    let scan = scan(AdapterKind::OpenCode, dir.path());
    assert_eq!(ids(&scan), ["ses_both", "ses_v1_only", "ses_untitled"].map(String::from).into());
    let chats = by_id(&scan);
    assert_eq!(chats["ses_both"].title.as_deref(), Some("New title"));
    assert_eq!(chats["ses_both"].cwd.as_deref(), Some("/v2/ses_both"));
    let untitled = &chats["ses_untitled"];
    assert_eq!(
        (untitled.title.as_deref(), untitled.title_source),
        (Some("first prompt"), Some(TitleSource::Prompt))
    );
    assert_eq!(untitled.message_count, Some(3));
    assert_eq!(chats["ses_v1_only"].title.as_deref(), Some("Downgraded"));
}

fn json_file(path: &Path, value: &Value) {
    write(path, &serde_json::to_string_pretty(value).unwrap());
}

#[test]
fn global_json_storage_from_0_6_to_1_1_is_read_with_counts_and_prompts() {
    let dir = tempfile::tempdir().unwrap();
    let storage = dir.path().join("storage");
    json_file(
        &storage.join("session/proj1/ses_named.json"),
        &json!({"id":"ses_named","projectID":"proj1","directory":"/work/named","title":"Named session",
                "version":"1.0.0","time":{"created":1_790_848_800_000_i64,"updated":1_790_852_400_000_i64}}),
    );
    json_file(
        &storage.join("session/proj1/ses_placeholder.json"),
        &json!({"id":"ses_placeholder","projectID":"proj1","directory":"/work/p",
                "title":"New session - 2026-10-01T10:00:00.000Z",
                "time":{"created":1_790_848_800_000_i64,"updated":1_790_849_000_000_i64,"archived":1_790_900_000_000_i64}}),
    );
    json_file(
        &storage.join("session/proj1/ses_child.json"),
        &json!({"id":"ses_child","parentID":"ses_named","title":"Child session - 2026-10-01T10:00:00.000Z",
                "time":{"created":1,"updated":2}}),
    );
    for (msg, role) in [("msg_001", "user"), ("msg_002", "assistant"), ("msg_003", "user")] {
        json_file(
            &storage.join(format!("message/ses_named/{msg}.json")),
            &json!({"id":msg,"sessionID":"ses_named","role":role,"time":{"created":1}}),
        );
    }
    json_file(
        &storage.join("message/ses_placeholder/msg_010.json"),
        &json!({"id":"msg_010","sessionID":"ses_placeholder","role":"user","time":{"created":1}}),
    );
    json_file(
        &storage.join("part/msg_010/prt_001.json"),
        &json!({"id":"prt_001","messageID":"msg_010","type":"text","text":"injected","synthetic":true}),
    );
    json_file(
        &storage.join("part/msg_010/prt_002.json"),
        &json!({"id":"prt_002","messageID":"msg_010","type":"text","text":"write the parser"}),
    );

    let scan = scan(AdapterKind::OpenCode, dir.path());
    assert_eq!(ids(&scan), ["ses_named", "ses_placeholder"].map(String::from).into());
    let chats = by_id(&scan);
    let named = &chats["ses_named"];
    assert_eq!(
        (named.title.as_deref(), named.title_source, named.message_count),
        (Some("Named session"), Some(TitleSource::Ai), Some(3))
    );
    assert_eq!((named.created_ms, named.updated_ms), (Some(1_790_848_800_000), 1_790_852_400_000));
    // No DB: OpenCode 1.1 still resumes JSON sessions.
    let argv = ["opencode", "-s", "ses_named"].map(String::from).to_vec();
    assert_eq!(named.resume, Resume::Argv { argv, cwd_needed: true });
    let placeholder = &chats["ses_placeholder"];
    assert_eq!(
        (placeholder.title.as_deref(), placeholder.title_source),
        (Some("write the parser"), Some(TitleSource::Prompt))
    );
    assert!(placeholder.archived);
    assert_eq!(placeholder.source_path, storage.join("session/proj1/ses_placeholder.json"));
}

#[test]
fn json_sessions_a_db_never_imported_are_listed_read_only_and_db_copies_win() {
    let dir = tempfile::tempdir().unwrap();
    let conn = Connection::open(dir.path().join("opencode.db")).unwrap();
    v1_tables(&conn);
    conn.execute(
        "INSERT INTO session (id, directory, title, time_created, time_updated)
         VALUES ('ses_imported', '/db', 'From the DB', 1, 5)",
        [],
    )
    .unwrap();
    let storage = dir.path().join("storage/session/p");
    for (id, title) in [("ses_imported", "From JSON"), ("ses_orphan", "Never imported")] {
        json_file(
            &storage.join(format!("{id}.json")),
            &json!({"id":id,"directory":"/json","title":title,"time":{"created":1,"updated":9}}),
        );
    }
    let chats = by_id(&scan(AdapterKind::OpenCode, dir.path()));
    assert_eq!(chats["ses_imported"].title.as_deref(), Some("From the DB"));
    assert_eq!(chats["ses_orphan"].title.as_deref(), Some("Never imported"));
    assert_eq!(chats["ses_orphan"].resume, Resume::ReadOnly);
}

#[test]
fn per_project_json_storage_before_0_6_with_inline_and_split_parts() {
    let dir = tempfile::tempdir().unwrap();
    // v0.1-v0.5: <data>/project/<slug>/storage/session/...
    let storage = dir.path().join("project/Users-me-app/storage");
    json_file(
        &storage.join("session/info/ses_v1msg.json"),
        &json!({"id":"ses_v1msg","title":"New session - 2025-06-20T10:00:00.000Z",
                "time":{"created":1_750_413_600_000_i64,"updated":1_750_417_200_000_i64}}),
    );
    // Message format v1 (before v0.2.0): parts inline, AI SDK UI parts.
    json_file(
        &storage.join("session/message/ses_v1msg/msg_001.json"),
        &json!({"id":"msg_001","role":"user","parts":[{"type":"text","text":"inline prompt"}],
                "metadata":{"time":{"created":1},"sessionID":"ses_v1msg"}}),
    );
    json_file(
        &storage.join("session/message/ses_v1msg/msg_002.json"),
        &json!({"id":"msg_002","role":"assistant","parts":[],"path":{"cwd":"/Users/me/app","root":"/Users/me/app"}}),
    );
    json_file(
        &storage.join("session/info/ses_split.json"),
        &json!({"id":"ses_split","title":"Split parts","version":"0.5.29",
                "time":{"created":1_750_413_600_000_i64,"updated":1_750_413_700_000_i64}}),
    );
    // v0.2.35+: parts under session/part/<session>/<message>/.
    json_file(
        &storage.join("session/message/ses_split/msg_100.json"),
        &json!({"id":"msg_100","sessionID":"ses_split","role":"user","time":{"created":1}}),
    );
    json_file(
        &storage.join("session/part/ses_split/msg_100/prt_1.json"),
        &json!({"id":"prt_1","type":"text","text":"split prompt"}),
    );
    // v0.0.53-v0.0.55: storage nested under the absolute repo path.
    let nested = dir.path().join("Users/me/old-app/storage");
    json_file(
        &nested.join("session/info/ses_oldest.json"),
        &json!({"id":"ses_oldest","title":"Oldest layout","time":{"created":1_748_700_000_000_i64,"updated":1_748_700_100_000_i64}}),
    );

    let chats = by_id(&scan(AdapterKind::OpenCode, dir.path()));
    let v1 = &chats["ses_v1msg"];
    assert_eq!(
        (v1.title.as_deref(), v1.title_source, v1.cwd.as_deref()),
        (Some("inline prompt"), Some(TitleSource::Prompt), Some("/Users/me/app"))
    );
    assert_eq!(v1.message_count, Some(2));
    assert_eq!(chats["ses_split"].title.as_deref(), Some("Split parts"));
    assert_eq!(chats["ses_oldest"].title.as_deref(), Some("Oldest layout"));
}

#[test]
fn kilo_reads_its_own_db_and_json_storage() {
    let dir = tempfile::tempdir().unwrap();
    let conn = Connection::open(dir.path().join("kilo.db")).unwrap();
    v1_tables(&conn);
    conn.execute(
        "INSERT INTO session (id, directory, title, time_created, time_updated)
         VALUES ('ses_k1', '/k', 'Kilo chat', 1, 2)",
        [],
    )
    .unwrap();
    // An OpenCode DB in the same dir is not Kilo's.
    let other = Connection::open(dir.path().join("opencode.db")).unwrap();
    v1_tables(&other);
    other
        .execute(
            "INSERT INTO session (id, title, time_created, time_updated) VALUES ('ses_oc', 'x', 1, 2)",
            [],
        )
        .unwrap();
    json_file(
        &dir.path().join("storage/session/p/ses_k0.json"),
        &json!({"id":"ses_k0","directory":"/k","title":"Kilo JSON","time":{"created":1,"updated":2}}),
    );
    let scan = scan(AdapterKind::Kilo, dir.path());
    assert_eq!(ids(&scan), ["ses_k1", "ses_k0"].map(String::from).into());
    assert!(scan.entries.iter().all(|entry| entry.harness == AdapterKind::Kilo));
    let argv = ["kilo", "-s", "ses_k1"].map(String::from).to_vec();
    assert_eq!(by_id(&scan)["ses_k1"].resume, Resume::Argv { argv, cwd_needed: true });
}

#[test]
fn json_session_files_and_dbs_are_store_events() {
    let root = Path::new("/d/opencode");
    let classify = |rel: &str| classify_path(AdapterKind::OpenCode, root, &root.join(rel));
    assert_eq!(classify("opencode.db-wal"), PathRole::Store);
    assert_eq!(classify("opencode-beta.db"), PathRole::Store);
    assert_eq!(classify("storage/session/p/ses_1.json"), PathRole::Store);
    assert_eq!(classify("project/s/storage/session/info/ses_1.json"), PathRole::Store);
    assert_eq!(classify("storage/part/msg_1/prt_1.json"), PathRole::Ignore);
    assert_eq!(classify("snapshot/x"), PathRole::Ignore);
    let kilo = |rel: &str| classify_path(AdapterKind::Kilo, root, &root.join(rel));
    assert_eq!(kilo("kilo.db"), PathRole::Store);
    assert_eq!(kilo("opencode.db"), PathRole::Ignore);
}
