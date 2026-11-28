use super::*;
use std::io::Write;

/// The session's turn gate also fences the transition from following an outside transcript
/// to accepting a live harness. A takeover must wait while a watched tail is committing.
#[tokio::test]
async fn takeover_waits_for_the_watched_tail_gate() {
    use crate::config::{Config, StoreMode};

    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let session = hub
        .new_session(crate::hub::NewRequest {
            cwd: Some(std::env::temp_dir()),
            ..Default::default()
        })
        .await
        .unwrap();
    {
        let mut meta = session.meta.lock().unwrap();
        meta.agent_session_id = Some("outside-session".to_owned());
        meta.watching = Some(Watching {
            family: "claude".to_owned(),
            file: std::env::temp_dir().join("watched-outside-session.jsonl"),
            offset: 0,
            codex_items: false,
            open: None,
            ..Default::default()
        });
    }

    // A tail holding this gate is still entitled to commit its watched events. The
    // takeover must wait, then close the watch and publish the handoff in that order.
    let tail_guard = session.turn_lock.lock().await;
    let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
    let taking = tokio::spawn({
        let (hub, session) = (hub.clone(), session.clone());
        async move {
            let _ = ready_tx.send(());
            hub.watch_take_over(&session, IfLive::Open).await
        }
    });
    ready_rx.await.unwrap();
    tokio::task::yield_now().await;
    assert!(!taking.is_finished(), "takeover raced a watched tail into the journal");
    assert!(
        session.meta().watching.is_some(),
        "the view-only owner changed before the tail finished"
    );

    drop(tail_guard);
    taking.await.unwrap().unwrap();
    assert!(session.meta().watching.is_none());

    // A file read can finish before Take Over and be scheduled afterward.
    // Exercise that stale completion deterministically: the old reader
    // must neither create a watched turn nor append any record to the live
    // conversation's journal.
    let before = session.meta().event_count;
    let late_line =
        json!({"type": "user", "message": {"content": "late watched prompt"}}).to_string();
    hub.show_watched(&session, &[late_line], 128).await;
    assert_eq!(session.meta().turn_count, 0, "a watched turn was appended after Take Over");
    assert_eq!(session.meta().event_count, before, "the stale reader wrote after Take Over");
    assert!(
        hub.watch_take_over(&session, IfLive::Open).await.is_err(),
        "Take Over succeeded twice"
    );
    hub.shutdown_all().await;
}

/// A watched batch whose record the journal refused (neither stored nor heard) keeps its read
/// position, so the next check reads it again; it used to move on and lose the turn.
#[tokio::test(flavor = "current_thread")]
async fn a_watched_batch_the_journal_refused_is_read_again() {
    use crate::config::{Config, StoreMode};
    use crate::store::REFUSE_APPENDS;

    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let session = hub
        .new_session(crate::hub::NewRequest {
            cwd: Some(std::env::temp_dir()),
            ..Default::default()
        })
        .await
        .unwrap();
    {
        let mut meta = session.meta.lock().unwrap();
        meta.agent_session_id = Some("outside-session".to_owned());
        meta.watching = Some(Watching {
            family: "claude".to_owned(),
            file: std::env::temp_dir().join("watched-refused-session.jsonl"),
            offset: 0,
            codex_items: false,
            open: None,
            ..Default::default()
        });
    }
    let line = json!({"type": "user", "message": {"content": "watched prompt"}}).to_string();

    REFUSE_APPENDS.with(|r| r.set(true));
    let shown = hub.show_watched(&session, std::slice::from_ref(&line), 128).await;
    REFUSE_APPENDS.with(|r| r.set(false));
    assert!(!shown, "a refused batch reads as shown");
    let watching = session.meta().watching.unwrap();
    assert_eq!(watching.offset, 0, "the read position moved past a refused batch");
    assert!(watching.open.is_none(), "the refused batch's turn was kept open");

    assert!(hub.show_watched(&session, &[line], 128).await);
    assert_eq!(session.meta().watching.unwrap().offset, 128);
    let records = hub.events(&session.id, 0, 100).unwrap();
    assert!(
        records.iter().any(|e| e.kind == "user_message" && e.msg["text"] == "watched prompt"),
        "the batch read again was stored"
    );
    hub.shutdown_all().await;
}

/// A Codex desktop line whose delivery a restarted daemon no longer knows still hides
/// acpmux's tools note, also with text after it, and keeps every other word: the person's own
/// `<cmux-…-context>` example stays.
#[tokio::test(flavor = "current_thread")]
async fn a_watched_prompt_after_a_restart_hides_only_its_tools_note() {
    use crate::config::{Config, StoreMode};

    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let session = hub
        .new_session(crate::hub::NewRequest {
            cwd: Some(std::env::temp_dir()),
            ..Default::default()
        })
        .await
        .unwrap();
    {
        let mut meta = session.meta.lock().unwrap();
        meta.agent_session_id = Some("01a1bf30-0000-7000-8000-00000000beef".to_owned());
        meta.tags
            .insert("bridge".into(), crate::store::Tag { value: "codex".into(), expires_at: None });
        meta.watching = Some(Watching {
            family: "codex".to_owned(),
            file: std::env::temp_dir().join("watched-codex-notes.jsonl"),
            ..Default::default()
        });
    }
    let note = crate::tool_mentions::note(&["computer-use"]).unwrap();
    let own = "open Notes with @computer-use like\n\n<cmux-foo-context>x</cmux-foo-context>";
    let sent = format!("{own}\n\n{note}\n\nReply in one line.");
    let want = format!("{own}\n\nReply in one line.");
    let line = json!({"type": "response_item", "payload": {"type": "message", "role": "user",
        "content": [{"type": "input_text", "text": sent}],
        "internal_chat_message_metadata_passthrough": {"content_item_kinds": ["user.text"]}}})
    .to_string();
    assert!(hub.show_watched(&session, &[line], 64).await);
    let records = hub.events(&session.id, 0, 100).unwrap();
    let user = records.iter().find(|e| e.kind == "user_message").expect("the prompt shows");
    assert_eq!(user.msg["text"], want);
    let started = records.iter().find(|e| e.kind == "turn_started").unwrap();
    assert_eq!(started.msg["prompt"], want);
    hub.shutdown_all().await;
}

/// A watched Claude chat in a hub of its own, for the queue and delivery tests below.
async fn queue_hub(name: &str) -> (Arc<Hub>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let session = hub
        .new_session(crate::hub::NewRequest {
            cwd: Some(std::env::temp_dir()),
            ..Default::default()
        })
        .await
        .unwrap();
    {
        let mut meta = session.meta.lock().unwrap();
        meta.agent_session_id = Some(format!("outside-{name}"));
        meta.watching = Some(Watching {
            family: "claude".to_owned(),
            file: std::env::temp_dir().join(format!("watched-{name}.jsonl")),
            ..Default::default()
        });
    }
    // The terminal's queue is read only while the chat is writable.
    hub.set_terminal_chat_writable(true).await;
    (hub, session)
}

fn prompts_of(hub: &Hub, session: &Session) -> Vec<(String, String)> {
    hub.events(&session.id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "user_message")
        .map(|e| {
            let text = e.msg["text"].as_str().unwrap_or_default().to_owned();
            let client = e.msg["client"].as_str().unwrap_or_default().to_owned();
            (text, client)
        })
        .collect()
}

/// A delivery's line in a batch the journal refused shows when the batch is read again: the
/// claim on it is given back (review P1-F2). It used to stay marked shown and never show.
#[tokio::test(flavor = "current_thread")]
async fn a_delivery_in_a_refused_batch_shows_when_the_batch_is_read_again() {
    use crate::store::REFUSE_APPENDS;
    let (hub, session) = queue_hub("refused-delivery").await;
    super::super::bridge::test_delivery(&session.id, "p-refused", "u-refused", "from the chat");
    let line = json!({"type": "user", "uuid": "u-refused", "origin": {"kind": "peer"},
        "message": {"content": "from the chat"}})
    .to_string();
    REFUSE_APPENDS.with(|r| r.set(true));
    let shown = hub.show_watched(&session, std::slice::from_ref(&line), 128).await;
    REFUSE_APPENDS.with(|r| r.set(false));
    assert!(!shown);
    assert!(hub.show_watched(&session, &[line], 128).await);
    assert_eq!(prompts_of(&hub, &session), [("from the chat".to_owned(), "bridge".to_owned())]);
    hub.shutdown_all().await;
}

/// Past the queued cap a prompt typed mid-turn shows when it runs, never twice and never lost
/// (review P2-F4: the cap used to forget the oldest one shown, which then showed again).
#[tokio::test(flavor = "current_thread")]
async fn prompts_typed_past_the_queued_cap_each_show_once() {
    let (hub, session) = queue_hub("cap").await;
    let n = MAX_QUEUED + 3;
    let mut lines: Vec<String> = (0..n)
        .map(|i| {
            json!({"type": "queue-operation", "operation": "enqueue", "content": format!("typed {i}")})
                .to_string()
        })
        .collect();
    for i in 0..n {
        lines.push(json!({"type": "queue-operation", "operation": "dequeue"}).to_string());
        lines.push(
            json!({"type": "user", "uuid": format!("t{i}"), "message": {"content": format!("typed {i}")}})
                .to_string(),
        );
    }
    assert!(hub.show_watched(&session, &lines, 128).await);
    let shown: Vec<String> = prompts_of(&hub, &session).into_iter().map(|(t, _)| t).collect();
    let want: Vec<String> = (0..n).map(|i| format!("typed {i}")).collect();
    assert_eq!(shown, want, "each once, in order");
    hub.shutdown_all().await;
}

/// A terminal prompt whose text contains, or repeats, a pending chat delivery's still shows as
/// typed, in either order of the two queue lines; the delivery shows once under its own id
/// (review P1-F1, P2-F3). A cancelled delivery ends at once, and its row never shows.
#[tokio::test(flavor = "current_thread")]
async fn terminal_prompts_overlapping_a_delivery_still_show() {
    for typed_first in [false, true] {
        let (hub, session) = queue_hub(&format!("overlap-{typed_first}")).await;
        let delivery = format!("u-test-{typed_first}");
        super::super::bridge::test_delivery(&session.id, "p-test", &delivery, "test");
        let enqueue = |t: &str| {
            json!({"type": "queue-operation", "operation": "enqueue", "content": t}).to_string()
        };
        let absorbed = |t: &str, source: &str, kind: &str| {
            json!({"type": "attachment", "attachment": {"type": "queued_command", "prompt": t,
                "source_uuid": source, "commandMode": "prompt", "origin": {"kind": kind}}})
            .to_string()
        };
        let typed = uuid::Uuid::now_v7().to_string();
        // The delivery's queue line and the same text typed in the terminal read the same: the
        // order is told only by which the turn takes in first, below.
        let lines_head = [enqueue("please test the migration"), enqueue("test"), enqueue("test")];
        let mut lines = lines_head.to_vec();
        let (first, second) = if typed_first {
            (absorbed("test", &typed, "human"), absorbed("test", &delivery, "peer"))
        } else {
            (absorbed("test", &delivery, "peer"), absorbed("test", &typed, "human"))
        };
        lines.push(absorbed("please test the migration", "x", "human"));
        lines.push(first);
        lines.push(second);
        assert!(hub.show_watched(&session, &lines, 128).await);
        let mut shown = prompts_of(&hub, &session);
        shown.sort();
        assert_eq!(
            shown,
            [
                ("please test the migration".to_owned(), "watch".to_owned()),
                ("test".to_owned(), "bridge".to_owned()),
                ("test".to_owned(), "watch".to_owned()),
            ],
            "typed first: {typed_first}"
        );
        hub.shutdown_all().await;
    }
}

/// A prompt typed mid-turn with the same text as a chat send the app has not queued yet is the
/// person's: it shows as typed when it runs, and the send stays pending for its own line (review
/// P1-F1 of 94dffc97: the typed `enqueue` was taken as the send's, and the prompt shown as the
/// send's, under its id).
#[tokio::test(flavor = "current_thread")]
async fn a_typed_prompt_with_a_pending_sends_text_shows_as_typed() {
    let (hub, session) = queue_hub("same-text-typed").await;
    super::super::bridge::test_delivery(&session.id, "p-same", "u-same", "test");
    let lines = vec![
        json!({"type": "queue-operation", "operation": "enqueue", "content": "test"}).to_string(),
        json!({"type": "attachment", "attachment": {"type": "queued_command", "prompt": "test",
            "source_uuid": "typed-cmd", "commandMode": "prompt", "origin": {"kind": "human"}}})
        .to_string(),
    ];
    assert!(hub.show_watched(&session, &lines, 128).await);
    assert_eq!(prompts_of(&hub, &session), [("test".to_owned(), "watch".to_owned())]);
    assert!(
        super::super::bridge::delivered(&session.id, "u-same").is_some(),
        "the send still waits"
    );
    hub.shutdown_all().await;
}

/// A queued prompt taken back in the terminal settles the turn shown for it, and a chat send
/// taken back ends with why instead of waiting half an hour (review P1-F2, P2-F2 of 94dffc97).
#[tokio::test(flavor = "current_thread")]
async fn a_queued_prompt_taken_back_settles_and_a_taken_back_send_ends() {
    let (hub, session) = queue_hub("taken-back").await;
    let rx = {
        super::super::bridge::test_delivery(&session.id, "p-back", "u-back", "from the chat");
        super::super::bridge::delivery_turn(&session.id, "p-back").unwrap()
    };
    let op = |op: &str, t: &str| {
        json!({"type": "queue-operation", "operation": op, "content": t}).to_string()
    };
    let lines = vec![
        op("enqueue", "typed then cancelled"),
        op("remove", "typed then cancelled"),
        op("enqueue", "from the chat"),
        op("remove", "from the chat"),
    ];
    assert!(hub.show_watched(&session, &lines, 128).await);
    assert!(
        session.meta().watching.unwrap().open.is_none(),
        "the cancelled prompt's turn is settled"
    );
    assert!(matches!(&*rx.borrow(), Some(Err(why)) if why.contains("taken back")));
    let shown: Vec<String> = prompts_of(&hub, &session).into_iter().map(|(t, _)| t).collect();
    assert_eq!(shown, ["typed then cancelled"]);
    hub.shutdown_all().await;
}

#[test]
fn only_complete_lines_are_read_and_the_offset_follows_them() {
    let dir = std::env::temp_dir().join(format!("acpmux-watch-lines-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("t.jsonl");
    std::fs::write(&file, "{\"a\":1}\n{\"b\":2}\n{\"c\":").unwrap();
    let (lines, offset) = read_lines(&file, 0).unwrap();
    assert_eq!(lines, ["{\"a\":1}", "{\"b\":2}"]);
    assert_eq!(offset, 16);
    let (lines, again) = read_lines(&file, offset).unwrap();
    assert!(lines.is_empty());
    assert_eq!(again, offset);
    std::fs::OpenOptions::new().append(true).open(&file).unwrap().write_all(b"3}\n").unwrap();
    let (lines, offset) = read_lines(&file, offset).unwrap();
    assert_eq!(lines, ["{\"c\":3}"]);
    assert_eq!(offset, 24);
    // A cut, shorter file is followed from its end: nothing is shown twice.
    std::fs::write(&file, "{\"d\":4}\n").unwrap();
    let (lines, offset) = read_lines(&file, offset).unwrap();
    assert!(lines.is_empty());
    std::fs::OpenOptions::new().append(true).open(&file).unwrap().write_all(b"{}\n").unwrap();
    assert_eq!(read_lines(&file, offset).unwrap().0, ["{}"]);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A first 64 MiB window may begin halfway through a very large JSONL entry.
/// Once that entry ends, the reader must advance and reach the valid following row.
#[test]
fn oversized_first_window_line_advances_to_the_next_record() {
    let dir = std::env::temp_dir().join(format!("acpmux-watch-long-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("oversized.jsonl");
    let content = format!("{{\"large\":\"{}\"}}\n{{\"next\":true}}\n", "x".repeat(160));
    std::fs::write(&file, content.as_bytes()).unwrap();
    let window_start = content.len() as u64 - 64;

    // The old code found no newline in the first 20 bytes, returned window_start,
    // and repeated the same read forever with offset still zero.
    let (lines, after_large) = read_lines_with_limits(&file, 0, 64, 20).unwrap();
    assert!(lines.is_empty());
    assert!(after_large > window_start, "stalled at the overlong line");
    let (mut at, mut received) = (after_large, Vec::new());
    for _ in 0..12 {
        let (lines, next) = read_lines_with_limits(&file, at, 64, 20).unwrap();
        assert!(next > at);
        received.extend(lines);
        at = next;
        if at == content.len() as u64 {
            break;
        }
    }
    assert_eq!(received, ["{\"next\":true}"]);
    assert_eq!(at, content.len() as u64);
    let _ = std::fs::remove_dir_all(&dir);
}

/// The source may still be writing its oversized first JSONL entry. Skip its
/// unfinished chunks across polls, then deliver complete rows after its newline.
#[test]
fn oversized_incomplete_window_line_resumes_when_terminated() {
    let dir = std::env::temp_dir().join(format!("acpmux-watch-partial-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("partial.jsonl");
    let unfinished = format!("{{\"large\":\"{}", "x".repeat(160));
    std::fs::write(&file, unfinished.as_bytes()).unwrap();
    let mut at = 0;
    for _ in 0..12 {
        let (lines, next) = read_lines_with_limits(&file, at, 64, 20).unwrap();
        assert!(lines.is_empty());
        assert!(next > at);
        at = next;
        if at == unfinished.len() as u64 {
            break;
        }
    }
    assert_eq!(at, unfinished.len() as u64);
    // A larger source file continues the same unfinished line; the byte
    // before the saved checkpoint still identifies it as a partial line.
    std::fs::OpenOptions::new()
        .append(true)
        .open(&file)
        .unwrap()
        .write_all(b"\"}\n{\"next\":1}\n")
        .unwrap();
    let (lines, done) = read_lines_with_limits(&file, at, 64, 20).unwrap();
    assert_eq!(lines, ["{\"next\":1}"]);
    assert_eq!(done, unfinished.len() as u64 + b"\"}\n{\"next\":1}\n".len() as u64);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A normal watched file can also append one huge line that spans several
/// chunks. Fragments of it must never appear as independent JSONL records.
#[test]
fn a_line_at_the_previous_checkpoint_skips_all_overlong_fragments() {
    let dir = std::env::temp_dir().join(format!("acpmux-watch-fragments-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("fragments.jsonl");
    let content = format!("{{\"large\":\"{}\"}}\n{{\"next\":2}}\n", "x".repeat(106));
    std::fs::write(&file, content.as_bytes()).unwrap();
    let (mut at, mut received) = (0, Vec::new());
    for _ in 0..12 {
        let (lines, next) = read_lines_with_limits(&file, at, 4096, 20).unwrap();
        assert!(next > at || at == content.len() as u64);
        received.extend(lines);
        at = next;
        if at == content.len() as u64 {
            break;
        }
    }
    assert_eq!(at, content.len() as u64);
    assert_eq!(received, ["{\"next\":2}"]);
    let _ = std::fs::remove_dir_all(&dir);
}
