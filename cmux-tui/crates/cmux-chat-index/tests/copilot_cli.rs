mod common;

use cmux_chat_index::{AdapterKind, PathRole, Resume, TitleSource, classify_path, read_file};
use common::{append_jsonl, by_id, ids, scan, set_mtime_ms, write, write_jsonl};
use serde_json::{Value, json};

const V3: &str = "7f3c0000-0000-4000-8000-000000000003";
const V2: &str = "7f3c0000-0000-4000-8000-000000000002";
const V1: &str = "7f3c0000-0000-4000-8000-000000000001";

fn start(id: &str, cwd: &str) -> Value {
    json!({"id":"e1","timestamp":"2026-10-01T10:00:00.000Z","parentId":null,"type":"session.start",
           "data":{"sessionId":id,"version":1,"producer":"copilot-agent","copilotVersion":"1.0.63",
                   "startTime":"2026-10-01T10:00:00.000Z","context":{"cwd":cwd}}})
}

fn user(text: &str) -> Value {
    json!({"id":"u","timestamp":"2026-10-01T10:01:00.000Z","parentId":"e1","type":"user.message","data":{"content":text}})
}

fn assistant() -> Value {
    json!({"id":"a","timestamp":"2026-10-01T10:02:00.000Z","parentId":"u","type":"assistant.message","data":{"messageId":"m","content":"ok"}})
}

#[test]
fn v3_folder_sessions_use_workspace_yaml_and_events() {
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().join("session-state").join(V3);
    let events = folder.join("events.jsonl");
    write_jsonl(&events, &[start(V3, "/work/cop"), user("fix the bug\nnow"), assistant()]);
    write(
        &folder.join("workspace.yaml"),
        "id: 7f3c0000-0000-4000-8000-000000000003\ncwd: /work/cop\nname: \"Fix the parser\"\nuser_named: true\nsummary_count: 0\ncreated_at: 2026-10-01T10:00:00Z\nupdated_at: 2026-10-01T10:05:00Z\n",
    );
    write(&folder.join("plan.md"), "# plan");
    set_mtime_ms(&events, 1_790_849_000_000);

    let scan = scan(AdapterKind::CopilotCli, dir.path());
    assert_eq!(ids(&scan), [V3.to_owned()].into());
    let entry = &by_id(&scan)[V3];
    assert_eq!(
        (entry.title.as_deref(), entry.title_source),
        (Some("Fix the parser"), Some(TitleSource::Custom))
    );
    assert_eq!(entry.cwd.as_deref(), Some("/work/cop"));
    assert_eq!(entry.created_ms, Some(1_790_848_800_000));
    assert_eq!(entry.updated_ms, 1_790_849_100_000, "workspace updated_at is newer than mtime");
    assert_eq!(entry.message_count, Some(2));
    assert_eq!(
        entry.resume,
        Resume::Argv {
            argv: vec!["copilot".into(), "--resume".into(), V3.into()],
            cwd_needed: true
        }
    );
}

#[test]
fn a_title_event_wins_and_appends_are_counted_incrementally() {
    let dir = tempfile::tempdir().unwrap();
    let events = dir.path().join("session-state").join(V3).join("events.jsonl");
    write_jsonl(&events, &[start(V3, "/work/cop"), user("first ask")]);
    let first = read_file(AdapterKind::CopilotCli, &events, None).unwrap();
    let entry = first.entry.as_ref().unwrap();
    assert_eq!(
        (entry.title.as_deref(), entry.title_source),
        (Some("first ask"), Some(TitleSource::Prompt))
    );
    assert_eq!(entry.message_count, Some(1));
    append_jsonl(
        &events,
        &[
            assistant(),
            json!({"id":"t","timestamp":"2026-10-01T10:03:00.000Z","parentId":"a","type":"session.title_changed","data":{"title":"Parser work"}}),
            user("again"),
        ],
    );
    let second = read_file(AdapterKind::CopilotCli, &events, Some(&first.state)).unwrap();
    let entry = second.entry.unwrap();
    assert_eq!(entry.message_count, Some(3));
    assert_eq!(
        (entry.title.as_deref(), entry.title_source),
        (Some("Parser work"), Some(TitleSource::Ai))
    );
    assert_eq!(second.state.offset, std::fs::metadata(&events).unwrap().len());
}

#[test]
fn v2_flat_event_files_are_chats() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session-state").join(format!("{V2}.jsonl"));
    write_jsonl(&path, &[start(V2, "/work/flat"), user("flat prompt"), assistant()]);
    let entry = by_id(&scan(AdapterKind::CopilotCli, dir.path())).remove(V2).unwrap();
    assert_eq!(
        (entry.title.as_deref(), entry.title_source),
        (Some("flat prompt"), Some(TitleSource::Prompt))
    );
    assert_eq!(entry.cwd.as_deref(), Some("/work/flat"));
    assert_eq!(entry.message_count, Some(2));
}

#[test]
fn v1_history_session_files_are_chats() {
    let dir = tempfile::tempdir().unwrap();
    let path =
        dir.path().join("history-session-state").join(format!("session_{V1}_1790848800000.json"));
    write(
        &path,
        &json!({"sessionId":V1,"startTime":"2026-10-01T10:00:00.000Z","chatMessages":[
            {"role":"system","content":"sys"},
            {"role":"user","content":"old copilot task"},
            {"role":"assistant","content":"done"}],"timeline":[]})
        .to_string(),
    );
    set_mtime_ms(&path, 1_790_852_400_000);
    let entry = by_id(&scan(AdapterKind::CopilotCli, dir.path())).remove(V1).unwrap();
    assert_eq!(
        (entry.title.as_deref(), entry.title_source),
        (Some("old copilot task"), Some(TitleSource::Prompt))
    );
    assert_eq!(entry.message_count, Some(2));
    assert_eq!((entry.created_ms, entry.updated_ms), (Some(1_790_848_800_000), 1_790_852_400_000));
    assert_eq!(entry.cwd, None);
}

#[test]
fn paths_are_classified() {
    let root = std::path::Path::new("/c");
    let role = |rel: &str| classify_path(AdapterKind::CopilotCli, root, &root.join(rel));
    assert_eq!(role(&format!("session-state/{V3}/events.jsonl")), PathRole::Session);
    assert_eq!(role(&format!("session-state/{V3}/workspace.yaml")), PathRole::Store);
    assert_eq!(role(&format!("session-state/{V2}.jsonl")), PathRole::Session);
    assert_eq!(role("history-session-state/session_a_1.json"), PathRole::Session);
    assert_eq!(role(&format!("session-state/{V3}/checkpoints/001-a.md")), PathRole::Ignore);
}
