//! acpmux's side of opt-in usage recording (`cmux-usage`): agent sessions started, chats shown and
//! hidden, and turns with the token counts their harness reported. Shape only: session and
//! machine ids go in raw and are hashed with the install's salt before they are written; there is
//! no field for prompt text, a title, a folder or a URL.
//!
//! A hook builds its event only while recording is on. Whether it is on is the usage folder's
//! on-switch, read at most every [`RECHECK`]: in between, a hook costs one `Instant` read, so an
//! install that never switched it on pays nothing more. An event goes on a bounded queue to one
//! writer thread, started at the first event, so no hub lock and no async task waits on a write;
//! a full queue drops the event. The thread ends when the hub (the queue's sender) goes.

use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::time::{Duration, Instant};

use cmux_usage::{Event, Id, Recorder, Source, Token, UsageDir, now_ms};
use serde_json::Value;

/// How long a read of the on-switch is trusted: switching recording on or off reaches acpmux
/// within this.
const RECHECK: Duration = Duration::from_secs(5);
/// Events waiting for the writer; past it they are dropped.
const QUEUE: usize = 1024;
/// Most events one write takes.
const BATCH: usize = 256;
/// [`UsageRecord::checked_at`] before the first read.
const NEVER: u64 = u64::MAX;

/// The hub's usage recorder (`Hub::usage`).
pub(crate) struct UsageRecord {
    /// None: this hub never records (no usage folder, a test hub, a memory store).
    dir: Option<UsageDir>,
    born: Instant,
    /// Milliseconds after `born` of the last on-switch read, or [`NEVER`].
    checked_at: AtomicU64,
    enabled: AtomicBool,
    queue: usize,
    /// The queue and its writer, made at the first event; None when the thread could not start.
    writer: OnceLock<Option<Writer>>,
    /// Tests: queue events without a writer draining them.
    #[cfg(test)]
    no_writer: bool,
}

struct Writer {
    tx: SyncSender<Event>,
    #[cfg_attr(not(test), allow(dead_code))]
    thread: Option<std::thread::JoinHandle<()>>,
    /// Tests without a writer: the receiving end, held so the queue stays open.
    #[cfg(test)]
    _rx: Option<Receiver<Event>>,
}

impl UsageRecord {
    /// The recorder of a hub over `CMUX_USAGE_DIR` or the default folder; one that records
    /// nothing when `records` is false.
    pub(crate) fn start(records: bool) -> Self {
        Self::new(UsageDir::default_location().filter(|_| records && !cfg!(test)), QUEUE)
    }

    fn new(dir: Option<UsageDir>, queue: usize) -> Self {
        Self {
            dir,
            born: Instant::now(),
            checked_at: AtomicU64::new(NEVER),
            enabled: AtomicBool::new(false),
            queue,
            writer: OnceLock::new(),
            #[cfg(test)]
            no_writer: false,
        }
    }

    /// Queues the event `build` makes, built only while recording is on. False when it is off
    /// or the queue is full (the event is dropped).
    pub(crate) fn record(&self, build: impl FnOnce() -> Event) -> bool {
        if !self.enabled() {
            return false;
        }
        let Some(writer) = self.writer.get_or_init(|| self.start_writer()) else { return false };
        match writer.tx.try_send(build()) {
            Ok(()) => true,
            Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) => false,
        }
    }

    /// Whether recording is on, as last read; read again once [`RECHECK`] has passed.
    fn enabled(&self) -> bool {
        let Some(dir) = &self.dir else { return false };
        let now = u64::try_from(self.born.elapsed().as_millis()).unwrap_or(NEVER - 1);
        let at = self.checked_at.load(Ordering::Relaxed);
        if at != NEVER && now.saturating_sub(at) < RECHECK.as_millis() as u64 {
            return self.enabled.load(Ordering::Relaxed);
        }
        self.checked_at.store(now, Ordering::Relaxed);
        let on = dir.is_enabled();
        self.enabled.store(on, Ordering::Relaxed);
        on
    }

    fn start_writer(&self) -> Option<Writer> {
        let dir = self.dir.clone()?;
        let (tx, rx) = mpsc::sync_channel(self.queue);
        #[cfg(test)]
        if self.no_writer {
            return Some(Writer { tx, thread: None, _rx: Some(rx) });
        }
        let thread = std::thread::Builder::new()
            .name("acpmux-usage".into())
            .spawn(move || write_until_closed(Recorder::new(dir, Source::Acpmux, "acpmux"), rx));
        match thread {
            Ok(thread) => Some(Writer {
                tx,
                thread: Some(thread),
                #[cfg(test)]
                _rx: None,
            }),
            Err(e) => {
                tracing::debug!("usage recording: no writer thread: {e}");
                None
            }
        }
    }

    /// Tests: closes the queue and waits for the writer to write what it holds.
    #[cfg(test)]
    fn close(self) {
        if let Some(Some(Writer { tx, thread, .. })) = self.writer.into_inner() {
            drop(tx);
            if let Some(thread) = thread {
                let _ = thread.join();
            }
        }
    }
}

/// The writer thread: writes what the queue holds, up to [`BATCH`] at a time, until every
/// sender is gone.
fn write_until_closed(mut recorder: Recorder, rx: Receiver<Event>) {
    while let Ok(first) = rx.recv() {
        let mut batch = vec![first];
        batch.extend(std::iter::from_fn(|| rx.try_recv().ok()).take(BATCH - 1));
        if let Err(e) = recorder.record_now(batch) {
            tracing::debug!("usage recording: write failed: {e}");
        }
    }
}

/// The [`Event::Turn`] of a turn whose `turn_result` is `result` (its `model` and token fields,
/// `hub/turn_usage.rs`), started at `started_at` (Unix ms).
pub(crate) fn turn_event(
    session: &str,
    harness: &str,
    result: &Value,
    started_at: Option<u64>,
    tool_calls: u32,
    subagents: u32,
) -> Event {
    let tokens = |key: &str| result.get(key).and_then(Value::as_u64).unwrap_or(0);
    Event::Turn {
        session: Id::new(session),
        harness: Token::new(harness),
        // A provider-qualified id (`openai/gpt-5`) keeps its model part: a `/` makes a token `other`.
        model: result.get("model").and_then(Value::as_str).map(|m| Token::new(m.rsplit('/').next().unwrap_or(m))),
        ms: started_at.map_or(0, |at| now_ms().saturating_sub(at)),
        input_tokens: tokens("inputTokens"),
        output_tokens: tokens("outputTokens"),
        cache_read_tokens: tokens("cacheReadTokens"),
        cache_write_tokens: tokens("cacheWriteTokens"),
        tool_calls,
        subagents,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn temp_dir(name: &str) -> UsageDir {
        let dir = std::env::temp_dir().join(format!(
            "acpmux-usage-{name}-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        UsageDir::new(dir)
    }

    #[test]
    fn nothing_is_written_while_the_switch_is_off() {
        let dir = temp_dir("off");
        let rec = UsageRecord::new(Some(dir.clone()), QUEUE);
        assert!(!rec.record(|| Event::View { session: Id::new("s1"), on: true }));
        assert!(rec.writer.get().is_none(), "no writer thread while off");
        rec.close();
        assert!(!dir.path().exists());
        assert!(dir.files().is_empty());
    }

    #[test]
    fn a_turn_round_trips_with_its_tokens() {
        let dir = temp_dir("turn");
        dir.set_enabled(true).expect("on");
        let rec = UsageRecord::new(Some(dir.clone()), QUEUE);
        let result = json!({"status": "completed", "model": "claude-opus-5-5", "inputTokens": 120,
            "outputTokens": 30, "cacheReadTokens": 900, "cacheWriteTokens": 40});
        let started = now_ms().saturating_sub(1500);
        assert!(rec.record(|| turn_event("SESSION-RAW", "claude", &result, Some(started), 3, 1)));
        rec.close();
        let records = dir.read(0);
        assert_eq!(records.len(), 1);
        let Event::Turn {
            session,
            harness,
            model,
            ms,
            input_tokens,
            output_tokens,
            cache_read_tokens,
            cache_write_tokens,
            tool_calls,
            subagents,
        } = &records[0].ev
        else {
            panic!("turn")
        };
        assert_ne!(session.as_str(), "SESSION-RAW");
        assert_eq!(harness.as_str(), "claude");
        assert_eq!(model.as_ref().map(Token::as_str), Some("claude-opus-5-5"));
        assert!(*ms >= 1500);
        assert_eq!(
            (*input_tokens, *output_tokens, *cache_read_tokens, *cache_write_tokens),
            (120, 30, 900, 40)
        );
        assert_eq!((*tool_calls, *subagents), (3, 1));
        assert_eq!(records[0].src, Source::Acpmux);
        let _ = std::fs::remove_dir_all(dir.path());
    }

    #[test]
    fn a_full_queue_drops_instead_of_waiting() {
        let dir = temp_dir("full");
        dir.set_enabled(true).expect("on");
        let mut rec = UsageRecord::new(Some(dir.clone()), 1);
        rec.no_writer = true;
        let view = || Event::View { session: Id::new("s1"), on: true };
        let started = Instant::now();
        assert!(rec.record(view));
        assert!(!rec.record(view));
        assert!(!rec.record(view));
        assert!(started.elapsed() < Duration::from_secs(1));
        rec.close();
        let _ = std::fs::remove_dir_all(dir.path());
    }
}
