mod common;

use std::fs;

use cmux_chat_index::{AdapterKind, PathRole, Resume, TitleSource, classify_path, read_file};
use common::{append_jsonl, by_id, ids, jsonl, scan, set_mtime_ms, write, write_jsonl};
use serde_json::{Value, json};

const A: &str = "d0000000-0000-4000-8000-00000000000a";
const B: &str = "d0000000-0000-4000-8000-00000000000b";
const SUB: &str = "d0000000-0000-4000-8000-00000000000c";

fn start(id: &str, title: &str, manual: bool) -> Value {
    json!({"type":"session_start","id":id,"title":title,"isSessionTitleManuallySet":manual,
           "owner":"me","version":2,"cwd":"/work/droid"})
}

fn msg(role: &str, text: &str, at: &str) -> Value {
    json!({"type":"message","id":"m","timestamp":at,
           "message":{"role":role,"content":[{"type":"text","text":text}]}})
}

#[test]
fn session_start_names_the_chat_and_messages_are_counted() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("-work-droid").join(format!("{A}.jsonl"));
    write_jsonl(
        &path,
        &[
            start(A, "Fix login", true),
            msg("user", "please fix login", "2026-10-01T10:00:00.000Z"),
            msg("assistant", "ok", "2026-10-01T10:01:00.000Z"),
            json!({"type":"todo_state","todos":[]}),
        ],
    );
    write(&dir.path().join("-work-droid").join(format!("{A}.settings.json")), "{}");
    set_mtime_ms(&path, 1_790_852_400_000);
    let scan = scan(AdapterKind::Droid, dir.path());
    assert_eq!(ids(&scan), [A.to_owned()].into());
    let entry = &by_id(&scan)[A];
    assert_eq!(
        (entry.title.as_deref(), entry.title_source),
        (Some("Fix login"), Some(TitleSource::Custom))
    );
    assert_eq!(entry.cwd.as_deref(), Some("/work/droid"));
    assert_eq!(entry.created_ms, Some(1_790_848_800_000));
    assert_eq!(entry.updated_ms, 1_790_852_400_000);
    assert_eq!(entry.message_count, Some(2));
    assert_eq!(
        entry.resume,
        Resume::Argv { argv: vec!["droid".into(), "--resume".into(), A.into()], cwd_needed: true }
    );
}

#[test]
fn legacy_flat_files_without_a_title_use_the_first_prompt() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(format!("{B}.jsonl"));
    write_jsonl(
        &path,
        &[start(B, "", false), msg("user", "flat legacy ask", "2026-10-01T10:00:00Z")],
    );
    let entry = by_id(&scan(AdapterKind::Droid, dir.path())).remove(B).unwrap();
    assert_eq!(
        (entry.title.as_deref(), entry.title_source),
        (Some("flat legacy ask"), Some(TitleSource::Prompt))
    );
}

#[test]
fn subagent_sessions_and_headerless_files_are_not_chats() {
    let dir = tempfile::tempdir().unwrap();
    let mut sub = start(SUB, "Sub run", false);
    sub["callingSessionId"] = json!(A);
    write_jsonl(&dir.path().join("-w").join(format!("{SUB}.jsonl")), &[sub]);
    write_jsonl(
        &dir.path().join("-w").join("x.jsonl"),
        &[msg("user", "no header", "2026-10-01T10:00:00Z")],
    );
    assert!(scan(AdapterKind::Droid, dir.path()).entries.is_empty());
}

#[test]
fn appends_count_incrementally_and_a_rename_rewrite_is_read_again() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("-w").join(format!("{A}.jsonl"));
    write_jsonl(&path, &[start(A, "Auto title", false), msg("user", "hi", "2026-10-01T10:00:00Z")]);
    let first = read_file(AdapterKind::Droid, &path, None).unwrap();
    assert_eq!(first.entry.as_ref().unwrap().title_source, Some(TitleSource::Ai));
    append_jsonl(&path, &[msg("assistant", "yo", "2026-10-01T10:01:00Z")]);
    let second = read_file(AdapterKind::Droid, &path, Some(&first.state)).unwrap();
    assert_eq!(second.entry.as_ref().unwrap().message_count, Some(2));
    // A rename rewrites line 1 in place.
    fs::write(
        &path,
        jsonl(&[
            start(A, "Renamed by me", true),
            msg("user", "hi", "2026-10-01T10:00:00Z"),
            msg("assistant", "yo", "2026-10-01T10:01:00Z"),
        ]),
    )
    .unwrap();
    let third = read_file(AdapterKind::Droid, &path, Some(&second.state)).unwrap();
    let entry = third.entry.unwrap();
    assert_eq!(
        (entry.title.as_deref(), entry.title_source, entry.message_count),
        (Some("Renamed by me"), Some(TitleSource::Custom), Some(2))
    );
}

#[test]
fn paths_are_classified() {
    let root = std::path::Path::new("/f");
    let role = |rel: &str| classify_path(AdapterKind::Droid, root, &root.join(rel));
    assert_eq!(role("-w/a.jsonl"), PathRole::Session);
    assert_eq!(role("a.jsonl"), PathRole::Session);
    assert_eq!(role("-w/a.settings.json"), PathRole::Ignore);
}
