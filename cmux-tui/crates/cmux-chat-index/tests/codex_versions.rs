//! Every Codex rollout generation: the TypeScript CLI's JSON object, the
//! first Rust JSONL without a line wrapper (flat and dated dirs), and the
//! RolloutLine wrapper with `session_meta`.

mod common;

use cmux_chat_index::{AdapterKind, PathRole, Resume, TitleSource, classify_path};
use common::{by_id, ids, scan, write, write_jsonl};
use serde_json::json;

const TS_ID: &str = "4c3b0000-0000-4000-8000-000000000001";
const FLAT_ID: &str = "5d4c0000-0000-4000-8000-000000000002";
const DATED_ID: &str = "6e5d0000-0000-4000-8000-000000000003";

#[test]
fn the_typescript_cli_json_rollout_is_read_only() {
    let dir = tempfile::tempdir().unwrap();
    write(
        &dir.path().join(format!("sessions/rollout-2025-04-20-{TS_ID}.json")),
        &serde_json::to_string_pretty(&json!({
            "session": {"timestamp": "2025-04-20T12:30:00.000Z", "id": TS_ID, "instructions": ""},
            "items": [
                {"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]},
                {"type":"message","role":"user","content":[{"type":"input_text","text":"port the cli"}]},
                {"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]},
                {"type":"message","role":"user","content":[{"type":"input_text","text":"thanks"}]}
            ]
        }))
        .unwrap(),
    );
    let entry = by_id(&scan(AdapterKind::Codex, dir.path())).remove(TS_ID).unwrap();
    assert_eq!(
        (entry.title.as_deref(), entry.title_source),
        (Some("port the cli"), Some(TitleSource::Prompt))
    );
    assert_eq!(entry.message_count, Some(2));
    assert_eq!(entry.created_ms, Some(1_745_107_200_000), "the UTC date of the file name");
    assert_eq!(entry.updated_ms, 1_745_152_200_000, "session.timestamp is the last save");
    assert_eq!(entry.resume, Resume::ReadOnly);
}

fn env_message(cwd: &str) -> serde_json::Value {
    json!({"type":"message","role":"user","content":[{"type":"input_text",
           "text":format!("<environment_context>\n  <cwd>{cwd}</cwd>\n  <approval_policy>on-request</approval_policy>\n</environment_context>")}]})
}

#[test]
fn unwrapped_rust_rollouts_take_id_folder_and_prompts_from_bare_items() {
    let dir = tempfile::tempdir().unwrap();
    // rust-v0.0.2505101753: flat dir, date-only name, line 1 without `type`.
    write_jsonl(
        &dir.path().join(format!("sessions/rollout-2025-05-08-{FLAT_ID}.jsonl")),
        &[
            json!({"id":FLAT_ID,"timestamp":"2025-05-08T09:00:00.000Z","instructions":null}),
            env_message("/work/flat"),
            json!({"type":"message","role":"user","content":[{"type":"input_text","text":"first real prompt"}]}),
            json!({"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}),
            json!({"record_type":"state","previous_response_id":"r1"}),
            json!({"type":"message","role":"user","content":[{"type":"input_text","text":"second"}]}),
        ],
    );
    // rust-v0.8.0: dated dirs, still no wrapper; `git` in the meta line.
    write_jsonl(
        &dir.path()
            .join(format!("sessions/2025/07/10/rollout-2025-07-10T08-00-00-{DATED_ID}.jsonl")),
        &[
            json!({"id":DATED_ID,"timestamp":"2025-07-10T08:00:00.000Z","instructions":null,"git":{"branch":"main"}}),
            env_message("/work/dated"),
            json!({"type":"message","role":"user","content":[{"type":"input_text","text":"## My request for Codex:\nfix the flaky test"}]}),
        ],
    );
    let scan = scan(AdapterKind::Codex, dir.path());
    assert_eq!(ids(&scan), [FLAT_ID, DATED_ID].map(String::from).into());
    let chats = by_id(&scan);
    let flat = &chats[FLAT_ID];
    assert_eq!(flat.cwd.as_deref(), Some("/work/flat"));
    assert_eq!(flat.title.as_deref(), Some("first real prompt"));
    assert_eq!(flat.message_count, Some(2));
    assert_eq!(flat.created_ms, Some(1_746_662_400_000));
    let dated = &chats[DATED_ID];
    assert_eq!(dated.cwd.as_deref(), Some("/work/dated"));
    assert_eq!(dated.title.as_deref(), Some("fix the flaky test"));
}

#[test]
fn wrapped_rollouts_skip_subagent_threads_and_strip_the_ide_preamble() {
    let dir = tempfile::tempdir().unwrap();
    let day = dir.path().join("sessions/2026/10/01");
    let meta = |id: &str, source: serde_json::Value| {
        json!({"timestamp":"2026-10-01T10:00:00.000Z","type":"session_meta",
               "payload":{"id":id,"timestamp":"2026-10-01T10:00:00.000Z","cwd":"/w","originator":"codex_vscode","source":source}})
    };
    let prompt = |text: &str| json!({"timestamp":"2026-10-01T10:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":text}});
    write_jsonl(
        &day.join("rollout-2026-10-01T10-00-00-t-main.jsonl"),
        &[
            meta("t-main", json!("vscode")),
            prompt("# Context\n## My request for Codex:\nadd retries"),
        ],
    );
    write_jsonl(
        &day.join("rollout-2026-10-01T10-00-00-t-review.jsonl"),
        &[meta("t-review", json!({"subagent":"review"})), prompt("review")],
    );
    write_jsonl(
        &day.join("rollout-2026-10-01T10-00-00-t-spawn.jsonl"),
        &[
            json!({"type":"session_meta","payload":{"id":"t-spawn","thread_source":"subagent","source":"cli"}}),
            prompt("spawned"),
        ],
    );
    let scan = scan(AdapterKind::Codex, dir.path());
    assert_eq!(ids(&scan), ["t-main".to_owned()].into());
    assert_eq!(by_id(&scan)["t-main"].title.as_deref(), Some("add retries"));
}

#[test]
fn every_rollout_name_is_a_session_event() {
    let root = std::path::Path::new("/h/.codex");
    let classify = |rel: &str| classify_path(AdapterKind::Codex, root, &root.join(rel));
    assert_eq!(classify("sessions/rollout-2025-04-20-x.json"), PathRole::Session);
    assert_eq!(
        classify("sessions/2026/10/01/rollout-2026-10-01T10-00-00-x.jsonl.zst"),
        PathRole::Session
    );
    assert_eq!(
        classify("archived_sessions/rollout-2026-10-01T10-00-00-x.jsonl"),
        PathRole::Session
    );
    assert_eq!(classify("state_5.sqlite-wal"), PathRole::Store);
    assert_eq!(classify("history.jsonl"), PathRole::Ignore);
}
