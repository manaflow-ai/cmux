//! Durability, torn lines and restart (section 2, section 5.2 "At load").

mod common;

use std::fs;
use std::io::Write;
use std::sync::Arc;

use common::*;
use optchat_host::*;

fn day_file(dir: &std::path::Path, stream: &str) -> std::path::PathBuf {
    let mut files: Vec<_> = fs::read_dir(dir.join(stream))
        .unwrap()
        .map(|e| e.unwrap().path())
        .collect();
    files.sort();
    files.pop().unwrap()
}

#[test]
fn lines_are_on_disk_when_append_returns() {
    let dir = tempfile::tempdir().unwrap();
    let chat = open(dir.path(), 128_000, instant(200));
    assert_eq!(chat.append(Kind::User, "hello\nworld").unwrap(), 0);
    assert_eq!(chat.append(Kind::Talk, "hi").unwrap(), 1);
    let text = fs::read_to_string(day_file(dir.path(), "main")).unwrap();
    let lines: Vec<serde_json::Value> = text
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[0]["i"], 0);
    assert_eq!(lines[0]["kind"], "user");
    assert_eq!(lines[0]["text"], "hello\nworld");
    assert_eq!(lines[0]["size"], "user: hello\nworld".len());
    assert!(lines[0]["date"].as_str().unwrap().contains('T'));
    // Short messages are free nodes, stored as tree lines too.
    assert!(chat.wait_idle(None, WAIT));
    let tree = fs::read_to_string(day_file(dir.path(), "tree")).unwrap();
    let first: serde_json::Value = serde_json::from_str(tree.lines().next().unwrap()).unwrap();
    assert_eq!(
        (first["l"].as_u64(), first["i"].as_u64()),
        (Some(0), Some(0))
    );
    assert_eq!(first["text"], "user: hello\nworld");
    assert_eq!(first["size"], "user: hello\nworld".len());
    assert!(chat.date(0).unwrap().len() >= 19);
    assert_eq!(chat.date(2), None);
}

#[test]
fn torn_lines_are_reported_skipped_and_terminated() {
    let dir = tempfile::tempdir().unwrap();
    {
        let chat = open(dir.path(), 128_000, instant(200));
        for n in 0..3 {
            chat.append(Kind::User, &format!("m{n}")).unwrap();
        }
        assert!(chat.wait_idle(None, WAIT));
    }
    // A crash mid-write: half a line, no newline, in both streams.
    let main = day_file(dir.path(), "main");
    fs::OpenOptions::new()
        .append(true)
        .open(&main)
        .unwrap()
        .write_all(br#"{"i":3,"kind":"us"#)
        .unwrap();
    let tree = day_file(dir.path(), "tree");
    fs::OpenOptions::new()
        .append(true)
        .open(&tree)
        .unwrap()
        .write_all(br#"{"l":0,"i""#)
        .unwrap();

    let (cfg, reports) = config(128_000);
    let chat = OptChat::open_with(dir.path(), cfg, instant(200), Arc::new(SystemClock)).unwrap();
    {
        let reports = reports.lock().unwrap();
        let invalid = reports
            .iter()
            .filter(|r| matches!(r, Report::InvalidLine { .. }))
            .count();
        let newline = reports
            .iter()
            .filter(|r| matches!(r, Report::MissingNewline { .. }))
            .count();
        assert_eq!((invalid, newline), (2, 2), "{reports:?}");
    }
    assert!(fs::read(&main).unwrap().ends_with(b"\n"));
    assert_eq!(chat.status().messages, 3);
    // The next write starts on its own line and takes the next id.
    assert_eq!(chat.append(Kind::Talk, "after").unwrap(), 3);
    assert!(chat.wait_idle(None, WAIT));
    let before = chat.render_view();
    drop(chat);

    let (cfg, reports) = config(128_000);
    let chat = OptChat::open_with(dir.path(), cfg, instant(200), Arc::new(SystemClock)).unwrap();
    // The torn lines are still there (never edited), reported again, but no newline is added twice.
    let reports = reports.lock().unwrap().clone();
    assert!(
        reports
            .iter()
            .all(|r| matches!(r, Report::InvalidLine { .. })),
        "{reports:?}"
    );
    assert_eq!(chat.message(3), Some((Kind::Talk, "after".to_string())));
    assert_eq!(chat.render_view(), before);
}

#[test]
fn restart_reload_equals_live_view() {
    let dir = tempfile::tempdir().unwrap();
    // A small budget forces many merges; the compactor catches up after each message.
    let budget = 6_000;
    let live = {
        let chat = open(dir.path(), budget, instant(300));
        for n in 0..300 {
            let text = if n % 3 == 0 {
                long(n)
            } else {
                format!("short {n}")
            };
            chat.append(if n % 2 == 0 { Kind::User } else { Kind::Echo }, &text)
                .unwrap();
            assert!(chat.wait_idle(None, WAIT));
        }
        let status = chat.status();
        assert!(status.view_size <= budget, "{status:?}");
        assert!(status.view_lines < 300);
        chat.render_view()
    };
    let chat = open(dir.path(), budget, instant(300));
    assert!(chat.wait_idle(None, WAIT));
    assert_eq!(chat.render_view(), live);
    assert_eq!(chat.status().messages, 300);
}

#[test]
fn ids_must_be_contiguous() {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir_all(dir.path().join("main")).unwrap();
    fs::write(
        dir.path().join("main/2026-01-01.jsonl"),
        "{\"i\":0,\"kind\":\"user\",\"text\":\"a\",\"size\":7,\"date\":\"2026-01-01T00:00:00Z\"}\n\
         {\"i\":2,\"kind\":\"user\",\"text\":\"b\",\"size\":7,\"date\":\"2026-01-01T00:00:01Z\"}\n",
    )
    .unwrap();
    let err = OptChat::open_with(
        dir.path(),
        config(128_000).0,
        instant(200),
        Arc::new(SystemClock),
    );
    assert!(matches!(err, Err(Error::Io(_))));
}

#[test]
fn tool_results_are_capped_when_logged() {
    let dir = tempfile::tempdir().unwrap();
    let chat = open(dir.path(), 128_000, instant(200));
    let big = format!("BEGIN{}END", "0123456789".repeat(10_000));
    let id = chat.append(Kind::Echo, &big).unwrap();
    let (kind, text) = chat.message(id).unwrap();
    assert_eq!(kind, Kind::Echo);
    assert_eq!(text, cap_tool_result(&big));
    assert!(text.chars().count() <= 30_000 && text.starts_with("BEGIN") && text.ends_with("END"));
    // Other kinds are never cut: the user's paste is logged whole.
    let id = chat.append(Kind::User, &big).unwrap();
    assert_eq!(chat.message(id).unwrap().1, big);
}

/// Section 10 imports old history; section 2 stores each message's ISO
/// `date`. An imported message keeps the date it was first written, so
/// `date(id)` answers "7 months ago" instead of the import's own time. A
/// date that is not RFC 3339 is refused and nothing is logged.
#[test]
fn an_imported_message_keeps_its_own_date() {
    let dir = tempfile::tempdir().unwrap();
    let chat = open(dir.path(), 128_000, instant(200));
    let date = "2026-03-01T09:30:00.000-08:00";
    assert_eq!(chat.append_dated(Kind::Note, "old note", date).unwrap(), 0);
    assert_eq!(chat.stamp(0).as_deref(), Some(date));
    assert!(
        chat.date(0).unwrap().starts_with("2026-03-0"),
        "{:?}",
        chat.date(0)
    );
    assert!(chat.append_dated(Kind::Note, "bad", "March 1st").is_err());
    assert_eq!(chat.status().messages, 1);
    let text = fs::read_to_string(day_file(dir.path(), "main")).unwrap();
    let line: serde_json::Value = serde_json::from_str(text.lines().next().unwrap()).unwrap();
    assert_eq!(line["date"], date);
}
