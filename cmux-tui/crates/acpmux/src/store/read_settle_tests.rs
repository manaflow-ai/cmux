//! A read or a flush of the event logs while a chat streams (`store.rs` `segments`,
//! `log_writer.rs` `settle` and `flush`). A read waits for the records queued when it started,
//! never for a chat's queue to be empty: a chat that streams a token every few milliseconds
//! beside 79 others seldom has an empty queue, and every `_acpmux/events` read of it got no
//! reply in 30 s (fleet job 88f5f7da34f5480fc9817e95, 288 of 288 reads); the app timed out at
//! 2 s and restarted acpmux.
//!
//! No timing decides these tests. The chat streams on the writer thread itself: before each
//! write of the chat, the writer's hook (`LogWriter::start_with_hook`) appends its next record,
//! so no write ever ends with the chat's queue empty. A read that waits for an empty queue never
//! returns; [`HANG`] only turns that hang into a failure.

use super::*;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak, mpsc};
use std::time::Duration;

const CHAT: &str = "streaming-chat";

/// Turns a hang into a failure. A bounded read or flush returns after at most two writes.
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

/// The chat's stream, driven from the writer's hook: while `on`, each write of the chat first
/// appends the chat's next record.
#[derive(Default)]
struct Stream {
    store: OnceLock<Weak<LocalStore>>,
    on: AtomicBool,
    /// The last record appended.
    seq: AtomicU64,
    /// Told once three records are appended.
    started: Mutex<Option<mpsc::Sender<()>>>,
}

impl Stream {
    fn before_write(&self, id: &str) {
        if id != CHAT || !self.on.load(Ordering::SeqCst) {
            return;
        }
        let Some(store) = self.store.get().and_then(Weak::upgrade) else { return };
        let seq = self.seq.fetch_add(1, Ordering::SeqCst) + 1;
        store.append(CHAT, &record(seq)).unwrap();
        if seq == 3
            && let Some(started) = self.started.lock().unwrap().take()
        {
            let _ = started.send(());
        }
    }
}

/// A store whose writer streams the chat (see [`Stream`]), not yet started.
fn store(name: &str) -> (Arc<LocalStore>, Arc<Stream>) {
    let root = std::env::temp_dir().join(format!(
        "acpmux-read-settle-{name}-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    crate::config::private_state_dir(&root).unwrap();
    let stream = Arc::new(Stream::default());
    let hook: log_writer::WriteHook = {
        let stream = stream.clone();
        Arc::new(move |id: &str| stream.before_write(id))
    };
    let log = log_writer::LogWriter::start_with_hook(
        root.clone(),
        1 << 20,
        OPEN_LOGS,
        &crate::supervised::embedded(),
        Some(hook),
    );
    let store = Arc::new(LocalStore { root, log });
    stream.store.set(Arc::downgrade(&store)).ok();
    (store, stream)
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

/// Starts the chat's stream, then runs `op` on its own thread once three records are appended;
/// returns what `op` returned and `before`, the last record appended before `op` started, or
/// fails when `op` has not returned within [`HANG`].
fn while_streaming<T: Send + 'static>(
    store: &Arc<LocalStore>,
    stream: &Stream,
    what: &str,
    op: impl FnOnce(&LocalStore) -> T + Send + 'static,
) -> (T, u64) {
    let (started_tx, started) = mpsc::channel();
    *stream.started.lock().unwrap() = Some(started_tx);
    stream.on.store(true, Ordering::SeqCst);
    stream.seq.store(1, Ordering::SeqCst);
    store.append(CHAT, &record(1)).unwrap();
    started.recv_timeout(HANG).expect("the chat streamed three records");
    let before = store.progress(CHAT).unwrap().borrow().queued;
    let (done_tx, done) = mpsc::channel();
    let reader = store.clone();
    std::thread::spawn(move || {
        let _ = done_tx.send(op(&reader));
    });
    let got = done.recv_timeout(HANG);
    // Stop the stream and let the writer finish it before any panic: a hook still holding the
    // store must never be its last owner (the writer would join its own thread).
    stream.on.store(false, Ordering::SeqCst);
    store.flush().unwrap();
    let streamed = stream.seq.load(Ordering::SeqCst);
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
    let (store, stream) = store("events");
    let (read, before) = while_streaming(&store, &stream, "an events read", |store| {
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
    let (store, stream) = store("flush");
    let (flushed, before) = while_streaming(&store, &stream, "a flush", |store| {
        store.flush().map(|()| seqs_on_disk(store))
    });
    let seqs = flushed.unwrap();
    assert!(before >= 3, "the flush started after the chat streamed: {before}");
    assert!(seqs.len() as u64 >= before, "the flush left records queued before it: {seqs:?}");
    assert_eq!(seqs[..before as usize], (1..=before).collect::<Vec<_>>()[..]);
    let _ = std::fs::remove_dir_all(&store.root);
}
