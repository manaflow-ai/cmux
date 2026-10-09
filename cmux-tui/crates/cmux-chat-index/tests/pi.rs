mod common;

use std::fs;

use cmux_chat_index::{AdapterKind, Resume, TitleSource, read_file};
use common::{by_id, jsonl, scan, write, write_jsonl};
use serde_json::{Value, json};

const ID: &str = "0199aaaa-0000-7000-8000-000000000001";

fn header() -> Value {
    json!({"type":"session","version":3,"id":ID,"timestamp":"2026-10-01T10:00:00.000Z","cwd":"/work/pi"})
}

fn msg(role: &str, text: &str) -> Value {
    json!({"type":"message","id":"x","parentId":null,"message":{"role":role,"content":[{"type":"text","text":text}]}})
}

fn info(name: &str) -> Value {
    json!({"type":"session_info","id":"y","name":name})
}

fn session_path(root: &std::path::Path) -> std::path::PathBuf {
    root.join("--work-pi--").join(format!("2026-10-01T10-00-00-000Z_{ID}.jsonl"))
}

#[test]
fn the_last_session_name_wins_and_messages_are_counted() {
    let dir = tempfile::tempdir().unwrap();
    let path = session_path(dir.path());
    write_jsonl(
        &path,
        &[header(), msg("user", "build it"), info("First"), msg("assistant", "ok"), info("Final")],
    );
    let entry = by_id(&scan(AdapterKind::Pi, dir.path())).remove(ID).unwrap();
    assert_eq!(
        (entry.title.as_deref(), entry.title_source),
        (Some("Final"), Some(TitleSource::Custom))
    );
    assert_eq!(entry.message_count, Some(2));
    assert_eq!(entry.cwd.as_deref(), Some("/work/pi"));
    assert_eq!(entry.created_ms, Some(1_790_848_800_000));
    let argv = vec!["pi".to_owned(), "--session".to_owned(), path.display().to_string()];
    assert_eq!(entry.resume, Resume::Argv { argv, cwd_needed: false });
}

#[test]
fn an_empty_name_clears_it_back_to_the_first_prompt() {
    let dir = tempfile::tempdir().unwrap();
    write_jsonl(
        &session_path(dir.path()),
        &[header(), msg("user", "build it"), info("Named"), info("")],
    );
    let entry = by_id(&scan(AdapterKind::Pi, dir.path())).remove(ID).unwrap();
    assert_eq!(
        (entry.title.as_deref(), entry.title_source),
        (Some("build it"), Some(TitleSource::Prompt))
    );
}

#[test]
fn a_shrunk_file_is_parsed_again_from_the_start() {
    let dir = tempfile::tempdir().unwrap();
    let path = session_path(dir.path());
    write_jsonl(
        &path,
        &[header(), msg("user", "a"), msg("assistant", "b"), msg("user", "c"), info("Big")],
    );
    let first = read_file(AdapterKind::Pi, &path, None).unwrap();
    assert_eq!(first.entry.as_ref().unwrap().message_count, Some(3));
    // A version migration rewrites the file in place, shorter.
    fs::write(&path, jsonl(&[header(), msg("user", "a")])).unwrap();
    let second = read_file(AdapterKind::Pi, &path, Some(&first.state)).unwrap();
    let entry = second.entry.unwrap();
    assert_eq!(entry.message_count, Some(1));
    assert_eq!(entry.title.as_deref(), Some("a"));
}

#[test]
fn a_replaced_file_with_a_new_inode_is_parsed_again() {
    let dir = tempfile::tempdir().unwrap();
    let path = session_path(dir.path());
    write_jsonl(&path, &[header(), msg("user", "a"), msg("assistant", "b")]);
    let first = read_file(AdapterKind::Pi, &path, None).unwrap();
    let replacement = dir.path().join("replacement.tmp");
    write(
        &replacement,
        &jsonl(&[header(), msg("user", "new start"), msg("assistant", "b"), msg("user", "c")]),
    );
    fs::rename(&replacement, &path).unwrap();
    let second = read_file(AdapterKind::Pi, &path, Some(&first.state)).unwrap();
    let entry = second.entry.unwrap();
    assert_eq!(entry.message_count, Some(3));
    assert_eq!(entry.title.as_deref(), Some("new start"));
}

#[test]
fn a_file_without_a_session_header_is_not_a_chat() {
    let dir = tempfile::tempdir().unwrap();
    write_jsonl(&session_path(dir.path()), &[msg("user", "no header")]);
    assert!(scan(AdapterKind::Pi, dir.path()).entries.is_empty());
}

#[test]
fn an_in_place_rewrite_that_grows_is_parsed_again() {
    // A Pi version migration rewrites the file in place (same inode) and the
    // new file is longer: the size check alone reads it as an append.
    let dir = tempfile::tempdir().unwrap();
    let path = session_path(dir.path());
    write_jsonl(&path, &[header(), msg("user", "a"), msg("assistant", "b")]);
    let first = read_file(AdapterKind::Pi, &path, None).unwrap();
    fs::write(
        &path,
        jsonl(&[header(), msg("user", "migrated start"), msg("assistant", "b"), msg("user", "c")]),
    )
    .unwrap();
    let second = read_file(AdapterKind::Pi, &path, Some(&first.state)).unwrap();
    let entry = second.entry.unwrap();
    assert_eq!(entry.message_count, Some(3));
    assert_eq!(entry.title.as_deref(), Some("migrated start"));
}

#[test]
fn v1_headers_flat_custom_dirs_and_agent_dir_strays_are_read() {
    let dir = tempfile::tempdir().unwrap();
    // v1 (before v0.31): no version, no entry ids.
    let v1 = json!({"type":"session","id":"v1-id","timestamp":"2025-11-01T10:00:00.000Z","cwd":"/work/v1",
                    "provider":"anthropic","modelId":"m","thinkingLevel":"off"});
    let v1_msg = json!({"type":"message","timestamp":"2025-11-01T10:00:01.000Z",
                        "message":{"role":"user","content":"v1 prompt"}});
    // A flat custom session dir (PI_CODING_AGENT_SESSION_DIR): files in the root.
    write_jsonl(&dir.path().join("flat/2025-11-01T10-00-00-000Z_v1-id.jsonl"), &[v1, v1_msg]);
    let flat = by_id(&scan(AdapterKind::Pi, &dir.path().join("flat")));
    assert_eq!(flat["v1-id"].title.as_deref(), Some("v1 prompt"));
    assert_eq!(flat["v1-id"].cwd.as_deref(), Some("/work/v1"));

    // v0.30.0 wrote sessions into the agent dir itself.
    let agent = dir.path().join(".pi/agent");
    write_jsonl(
        &agent.join("2026-01-01T00-00-00-000Z_stray.jsonl"),
        &[
            json!({"type":"session","version":2,"id":"stray","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/s"}),
        ],
    );
    write_jsonl(&session_path(&agent.join("sessions")), &[header(), msg("user", "normal")]);
    let chats = by_id(&scan(AdapterKind::Pi, &agent.join("sessions")));
    assert!(chats.contains_key("stray") && chats.contains_key(ID), "{chats:?}");

    // A custom `sessions` dir elsewhere does not list its parent.
    let custom = dir.path().join("elsewhere");
    write_jsonl(
        &custom.join("x.jsonl"),
        &[
            json!({"type":"session","id":"outside","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/o"}),
        ],
    );
    fs::create_dir_all(custom.join("sessions")).unwrap();
    assert!(scan(AdapterKind::Pi, &custom.join("sessions")).entries.is_empty());
}
