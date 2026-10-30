//! A read or a flush of the event logs while a chat streams (`store.rs` `segments`,
//! `log_writer.rs` `settle` and `flush`). A read waits for the records queued when it started,
//! never for a chat's queue to be empty: a chat that streams a token every few milliseconds
//! beside 79 others seldom has an empty queue, and every `_acpmux/events` read of it got no
//! reply in 30 s (fleet job 88f5f7da34f5480fc9817e95, 288 of 288 reads); the app timed out at
//! 2 s and restarted acpmux.

use super::*;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::time::Duration;

const CHAT: &str = "streaming-chat";

/// Each write of the log is held this long, as a busy disk holds it: the chat queues its next
/// record while the one before it is written, so its queue is never empty.
const WRITE: Duration = Duration::from_millis(50);

/// The hang limit, 200 writes. A read or a flush waits for at most two writes of the chat (the
/// one in progress and the one with its last record); one that has not returned by then waits
/// for the stream to end, that is, with no bound.
const HANG: Duration = Duration::from_secs(10);

fn record(seq: u64) -> EventRecord {
    EventRecord {
        seq,
        at: 0,
        dir: "in".into(),
        kind: "agent_message_chunk".into(),
        msg: serde_json::json!({"text": "token"}),
        host_seq: None,
    }
}

fn store(name: &str) -> Arc<LocalStore> {
    let root = std::env::temp_dir().join(format!(
        "acpmux-read-settle-{name}-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    crate::config::private_state_dir(&root).unwrap();
    let log = log_writer::LogWriter::start_with_write_delay(
        root.clone(),
        1 << 20,
        OPEN_LOGS,
        &crate::supervised::embedded(),
        Some(WRITE),
    );
    Arc::new(LocalStore { root, log })
}

/// A chat that streams until `stop`: it appends its next record as soon as the one before the
/// last is written, so one record is always queued while another is written. Signals `started`
/// once a few records are queued.
fn stream(
    store: Arc<LocalStore>,
    stop: Arc<AtomicBool>,
    started: mpsc::Sender<()>,
) -> std::thread::JoinHandle<u64> {
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_current_thread().build().unwrap();
        let mut progress = store.progress(CHAT).unwrap();
        let mut seq = 0;
        while !stop.load(Ordering::SeqCst) {
            seq += 1;
            store.append(CHAT, &record(seq)).unwrap();
            if seq == 3 {
                let _ = started.send(());
            }
            let behind = seq.saturating_sub(1);
            rt.block_on(progress.wait_for(|p| p.written >= behind || p.failed)).unwrap();
        }
        seq
    })
}

/// The seqs on disk in the chat's log, read from its files (no settle). The line the writer is
/// writing now may be cut short: it does not parse and is left out.
fn seqs_on_disk(store: &LocalStore) -> Vec<u64> {
    segments_in(&store.dir(CHAT).join("events"))
        .unwrap()
        .into_iter()
        .flat_map(|(_, path)| {
            std::fs::read_to_string(path)
                .unwrap()
                .lines()
                .filter_map(|line| serde_json::from_str::<EventRecord>(line).ok())
                .map(|record| record.seq)
                .collect::<Vec<_>>()
        })
        .collect()
}

/// Runs `op` on its own thread while the chat streams, after a few of its records are queued;
/// returns what `op` returned and `before`, the last record queued before `op` started, or
/// fails when `op` has not returned within [`HANG`].
fn while_streaming<T: Send + 'static>(
    store: &Arc<LocalStore>,
    what: &str,
    op: impl FnOnce(&LocalStore) -> T + Send + 'static,
) -> (T, u64) {
    let stop = Arc::new(AtomicBool::new(false));
    let (started_tx, started) = mpsc::channel();
    let streamer = stream(store.clone(), stop.clone(), started_tx);
    started.recv().unwrap();
    let before = store.progress(CHAT).unwrap().borrow().queued;
    let (done_tx, done) = mpsc::channel();
    let reader = store.clone();
    std::thread::spawn(move || {
        let _ = done_tx.send(op(&reader));
    });
    let got = done.recv_timeout(HANG);
    stop.store(true, Ordering::SeqCst);
    let streamed = streamer.join().unwrap();
    match got {
        Ok(got) => (got, before),
        Err(mpsc::RecvTimeoutError::Timeout) => panic!(
            "{what} of a streaming chat got no reply in {HANG:?} ({streamed} records streamed): \
             it waits for the chat's queue to be empty, which a streaming chat never is"
        ),
        Err(mpsc::RecvTimeoutError::Disconnected) => panic!("{what} panicked"),
    }
}

#[test]
fn read_settle_an_events_read_of_a_streaming_chat_returns_with_every_record_queued_before_it() {
    let store = store("events");
    let (read, before) = while_streaming(&store, "an events read", |store| {
        store.events(CHAT, 0, usize::MAX).map(|r| r.into_iter().map(|e| e.seq).collect::<Vec<_>>())
    });
    let seqs = read.unwrap();
    assert!(before >= 3, "the read started after the chat streamed: {before}");
    assert!(seqs.len() as u64 >= before, "the read missed records queued before it: {seqs:?}");
    assert_eq!(seqs[..before as usize], (1..=before).collect::<Vec<_>>()[..]);
    let _ = std::fs::remove_dir_all(&store.root);
}

#[test]
fn read_settle_a_flush_while_a_chat_streams_returns_with_every_record_queued_before_it_on_disk() {
    let store = store("flush");
    let (flushed, before) =
        while_streaming(&store, "a flush", |store| store.flush().map(|()| seqs_on_disk(store)));
    let seqs = flushed.unwrap();
    assert!(before >= 3, "the flush started after the chat streamed: {before}");
    assert!(seqs.len() as u64 >= before, "the flush left records queued before it: {seqs:?}");
    assert_eq!(seqs[..before as usize], (1..=before).collect::<Vec<_>>()[..]);
    let _ = std::fs::remove_dir_all(&store.root);
}
