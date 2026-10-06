//! Durability and restart (section 2, section 5.2 "At load") on the SQLite
//! store.

mod common;

use std::sync::Arc;

use common::*;
use optchat_host::db::ReadOnly;
use optchat_host::*;

#[test]
fn a_message_is_in_the_database_when_append_returns() {
    let dir = tempfile::tempdir().unwrap();
    let chat = open(dir.path(), 128_000, instant(200));
    assert_eq!(chat.append(Kind::User, "hello\nworld").unwrap(), 0);
    assert_eq!(chat.append(Kind::Talk, "hi").unwrap(), 1);
    // Another connection sees both as soon as append returned.
    let reader = ReadOnly::open(&dir.path().join(DB_FILE)).unwrap();
    assert_eq!(reader.counts().unwrap().messages, 2);
    assert_eq!(
        reader.message(0).unwrap(),
        Some(("user".into(), "hello\nworld".into()))
    );
    assert!(chat.date(0).unwrap().len() >= 19);
    assert_eq!(chat.date(2), None);
    // Short messages are free nodes, stored with the message's own line.
    assert!(chat.wait_idle(None, WAIT));
    assert_eq!(
        chat.node(NodeId::new(0, 0)).as_deref(),
        Some("user: hello\nworld")
    );
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

#[test]
fn a_batch_and_its_state_commit_together_and_keys_are_logged_once() {
    let dir = tempfile::tempdir().unwrap();
    let chat = open(dir.path(), 128_000, instant(200));
    let batch = [
        NewMessage {
            key: Some("conv#1".into()),
            ..NewMessage::new(Kind::User, "first")
        },
        NewMessage::new(Kind::User, "second"),
    ];
    let done = chat
        .append_with(&batch, |done| {
            vec![("host/cursor".into(), Some(done.ids[1].to_string()))]
        })
        .unwrap();
    assert_eq!((done.ids, done.fresh), (vec![0, 1], vec![true, true]));
    assert_eq!(chat.state("host/cursor").unwrap().as_deref(), Some("1"));
    // The same conversation message again: its id, nothing logged.
    let again = chat
        .append_with(
            &[NewMessage {
                key: Some("conv#1".into()),
                ..NewMessage::new(Kind::User, "first")
            }],
            |_| Vec::new(),
        )
        .unwrap();
    assert_eq!((again.ids, again.fresh), (vec![0], vec![false]));
    assert_eq!(chat.status().messages, 2);
    chat.put_state(&[("host/cursor".into(), None)]).unwrap();
    assert_eq!(chat.state("host/cursor").unwrap(), None);
}

#[test]
fn the_config_puts_the_database_where_it_says() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("home/memory.sqlite3");
    let config = Config {
        db: Some(db.clone()),
        ..config(128_000).0
    };
    let chat = OptChat::open_with(
        dir.path().join("chat"),
        config,
        instant(200),
        Arc::new(SystemClock),
    )
    .unwrap();
    chat.append(Kind::User, "x").unwrap();
    assert_eq!(chat.db_path(), db);
    assert!(db.exists() && !dir.path().join("chat").join(DB_FILE).exists());
}
