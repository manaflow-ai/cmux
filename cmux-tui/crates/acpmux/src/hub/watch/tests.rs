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
