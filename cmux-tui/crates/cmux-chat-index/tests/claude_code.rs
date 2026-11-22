mod common;

use std::collections::HashMap;

use cmux_chat_index::{AdapterConfig, AdapterKind, Resume, TitleSource, read_file, scan_root};
use common::{append_jsonl, by_id, ids, scan, set_mtime_ms, write_jsonl};
use serde_json::json;

const A: &str = "11111111-1111-4111-8111-111111111111";
const B: &str = "22222222-2222-4222-8222-222222222222";
const C: &str = "33333333-3333-4333-8333-333333333333";
const D: &str = "44444444-4444-4444-8444-444444444444";

fn user(text: &str) -> serde_json::Value {
    json!({"type":"user","isSidechain":false,"cwd":"/work/app","sessionId":A,
           "timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"user","content":text}})
}

fn assistant() -> serde_json::Value {
    json!({"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}})
}

#[test]
fn title_order_is_custom_then_ai_then_last_prompt_then_first_prompt() {
    let dir = tempfile::tempdir().unwrap();
    let project = dir.path().join("-work-app");
    write_jsonl(
        &project.join(format!("{A}.jsonl")),
        &[
            user("first prompt"),
            json!({"type":"custom-title","customTitle":"Old name","sessionId":A}),
            json!({"type":"ai-title","aiTitle":"AI name","sessionId":A}),
            json!({"type":"last-prompt","lastPrompt":"last prompt","sessionId":A}),
            json!({"type":"custom-title","customTitle":"Renamed","sessionId":A}),
        ],
    );
    write_jsonl(
        &project.join(format!("{B}.jsonl")),
        &[
            user("first prompt"),
            json!({"type":"ai-title","aiTitle":"AI name","sessionId":B}),
            json!({"type":"last-prompt","lastPrompt":"last prompt","sessionId":B}),
        ],
    );
    write_jsonl(
        &project.join(format!("{C}.jsonl")),
        &[
            user("first prompt"),
            json!({"type":"last-prompt","lastPrompt":"last prompt\nsecond line","sessionId":C}),
        ],
    );
    write_jsonl(
        &project.join(format!("{D}.jsonl")),
        &[
            json!({"type":"user","isMeta":true,"message":{"role":"user","content":"meta text"}}),
            json!({"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}),
            json!({"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}),
            json!({"type":"user","isCompactSummary":true,"message":{"role":"user","content":"compact summary"}}),
            user("  \n  hello world  \nmore"),
        ],
    );
    let chats = by_id(&scan(AdapterKind::ClaudeCode, dir.path()));
    let title = |id: &str| (chats[id].title.clone(), chats[id].title_source);
    assert_eq!(title(A), (Some("Renamed".into()), Some(TitleSource::Custom)));
    assert_eq!(title(B), (Some("AI name".into()), Some(TitleSource::Ai)));
    assert_eq!(title(C), (Some("last prompt".into()), Some(TitleSource::Prompt)));
    assert_eq!(title(D), (Some("hello world".into()), Some(TitleSource::Prompt)));
}

#[test]
fn a_summary_alone_never_becomes_the_title() {
    let dir = tempfile::tempdir().unwrap();
    write_jsonl(
        &dir.path().join("-p").join(format!("{A}.jsonl")),
        &[
            json!({"type":"summary","leafUuid":"x","summary":"Summary of another session"}),
            assistant(),
        ],
    );
    let chats = by_id(&scan(AdapterKind::ClaudeCode, dir.path()));
    assert_eq!(chats[A].title, None);
}

#[test]
fn sidechain_files_and_subagents_are_not_chats() {
    let dir = tempfile::tempdir().unwrap();
    let project = dir.path().join("-p");
    write_jsonl(&project.join(format!("{A}.jsonl")), &[user("main chat")]);
    write_jsonl(
        &project.join(format!("{B}.jsonl")),
        &[json!({"type":"user","isSidechain":true,"message":{"role":"user","content":"side"}})],
    );
    write_jsonl(&project.join("agent-abc.jsonl"), &[user("old layout subagent")]);
    write_jsonl(&project.join(A).join("subagents").join("agent-def.jsonl"), &[user("subagent")]);
    assert_eq!(ids(&scan(AdapterKind::ClaudeCode, dir.path())), [A.to_owned()].into());
}

#[test]
fn a_custom_title_in_the_tail_of_a_large_file_is_found() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("-p").join(format!("{A}.jsonl"));
    let mut records = vec![user("start here")];
    let filler = "x".repeat(1000);
    records.extend(
        (0..400)
            .map(|_| json!({"type":"assistant","message":{"role":"assistant","content":filler}})),
    );
    records.push(json!({"type":"custom-title","customTitle":"Late name","sessionId":A}));
    write_jsonl(&path, &records);
    assert!(std::fs::metadata(&path).unwrap().len() > 300 * 1024);
    let chats = by_id(&scan(AdapterKind::ClaudeCode, dir.path()));
    assert_eq!(chats[A].title.as_deref(), Some("Late name"));
    assert_eq!(chats[A].cwd.as_deref(), Some("/work/app"));
    assert_eq!(chats[A].message_count, Some(401));
}

#[test]
fn metadata_comes_from_records_and_mtime() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("-p").join(format!("{A}.jsonl"));
    write_jsonl(
        &path,
        &[
            json!({"type":"summary","summary":"s","leafUuid":"x"}),
            user("one"),
            assistant(),
            json!({"type":"user","timestamp":"2026-10-02T10:00:00Z","cwd":"/elsewhere","message":{"role":"user","content":"two"}}),
            assistant(),
        ],
    );
    set_mtime_ms(&path, 1_800_000_000_000);
    let entry = by_id(&scan(AdapterKind::ClaudeCode, dir.path())).remove(A).unwrap();
    assert_eq!(entry.harness, AdapterKind::ClaudeCode);
    assert_eq!(entry.cwd.as_deref(), Some("/work/app"));
    assert_eq!(entry.created_ms, Some(1_790_848_800_000));
    assert_eq!(entry.updated_ms, 1_800_000_000_000);
    assert_eq!(entry.message_count, Some(4));
    assert_eq!(entry.resume, Resume::Adopt);
    assert_eq!(entry.source_path, path);
}

#[test]
fn appended_lines_are_counted_from_the_last_offset() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("-p").join(format!("{A}.jsonl"));
    write_jsonl(&path, &[user("one"), assistant()]);
    let first = read_file(AdapterKind::ClaudeCode, &path, None).unwrap();
    assert_eq!(first.entry.as_ref().unwrap().message_count, Some(2));
    append_jsonl(
        &path,
        &[user("two"), assistant(), json!({"type":"custom-title","customTitle":"Now named"})],
    );
    let second = read_file(AdapterKind::ClaudeCode, &path, Some(&first.state)).unwrap();
    let entry = second.entry.unwrap();
    assert_eq!(entry.message_count, Some(4));
    assert_eq!(entry.title.as_deref(), Some("Now named"));
    assert_eq!(second.state.offset, std::fs::metadata(&path).unwrap().len());
}

#[test]
fn a_root_scan_keeps_the_newest_files_up_to_the_limit() {
    let dir = tempfile::tempdir().unwrap();
    for (id, ms) in [(A, 1_000), (B, 3_000), (C, 2_000)] {
        let path = dir.path().join("-p").join(format!("{id}.jsonl"));
        write_jsonl(&path, &[user("x")]);
        set_mtime_ms(&path, ms);
    }
    let config =
        AdapterConfig { max_files: 2, ..AdapterConfig::new(AdapterKind::ClaudeCode, dir.path()) };
    let scan = scan_root(&config, &HashMap::new()).unwrap();
    assert_eq!(ids(&scan), [B.to_owned(), C.to_owned()].into());
    assert_eq!(scan.files.len(), 2);
}

#[test]
fn a_missing_root_is_empty() {
    let dir = tempfile::tempdir().unwrap();
    assert!(scan(AdapterKind::ClaudeCode, &dir.path().join("absent")).entries.is_empty());
}
