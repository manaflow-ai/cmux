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
