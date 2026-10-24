//! Key-press flow marks for `scripts/cmux-next/trace.py` (plans/cmux-next/trace.md, "Key-press flows").
//!
//! Off unless `CMUX_TRACE_FLOWS` names a directory: then every [`hop`] costs one
//! load of a `OnceLock`, and nothing else. When it is on, each hop is one
//! record (the hop's name, the flow id or 0, the terminal's hex id, the
//! thread's system id, and `CLOCK_UPTIME_RAW` in nanoseconds on macOS,
//! `CLOCK_MONOTONIC` elsewhere: the clock of the app's signposts, so no
//! offset is guessed). The record goes to a bounded queue with `try_send`: a
//! hop never waits and never does I/O on the caller's thread. One writer
//! thread, blocked on the queue (no timer), appends each record as a JSON
//! line to `<dir>/flows-<pid>.jsonl`. A full queue drops the record and
//! counts it; the writer reports the count as a `{"dropped":N}` line.
//!
//! A hop with a flow id carries the id the app minted for one key press (the
//! `send` request's `flow`). A hop with flow 0 is on a path no message
//! carries the id over (the PTY write in a terminal host, the echo read
//! from the PTY, the echo's way back): trace.py places it in the flow whose
//! hops on the same terminal bound it before and after, and reports a flow
//! with no such hop, or with two, as incomplete.
//!
//! std and libc only: the holder (`cmux-holder`) links it too.

use std::io::Write;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{SyncSender, TrySendError};

/// Records the queue holds before a hop is dropped (and counted).
pub const QUEUE_LIMIT: usize = 8192;

struct Record {
    name: &'static str,
    flow: u64,
    terminal: String,
    tid: u64,
    t_ns: u64,
}

enum Message {
    Record(Record),
    /// Answered once every earlier record is written and flushed ([`flush`]).
    Flush(SyncSender<()>),
}

struct Sink {
    queue: SyncSender<Message>,
    dropped: AtomicU64,
}

fn sink() -> Option<&'static Sink> {
    static SINK: OnceLock<Option<Sink>> = OnceLock::new();
    SINK.get_or_init(|| {
        let dir = std::env::var_os("CMUX_TRACE_FLOWS").filter(|dir| !dir.is_empty())?;
        let path = std::path::Path::new(&dir).join(format!("flows-{}.jsonl", std::process::id()));
        let file = std::fs::OpenOptions::new().create(true).append(true).open(path).ok()?;
        let (queue, records) = std::sync::mpsc::sync_channel::<Message>(QUEUE_LIMIT);
        std::thread::Builder::new()
            .name("flow-trace".into())
            .spawn(move || write_records(file, records))
            .ok()?;
        Some(Sink { queue, dropped: AtomicU64::new(0) })
    })
    .as_ref()
}

/// The writer thread: one JSON line per record, flushed when the queue is
/// empty, so a batch costs one write.
fn write_records(file: std::fs::File, messages: std::sync::mpsc::Receiver<Message>) {
    let mut out = std::io::BufWriter::new(file);
    let mut reported = 0;
    while let Ok(first) = messages.recv() {
        let mut next = Some(first);
        let mut waiters = Vec::new();
        while let Some(message) = next {
            match message {
                Message::Record(record) => {
                    let _ = writeln!(
                        out,
                        "{{\"hop\":\"{}\",\"flow\":{},\"terminal\":\"{}\",\"pid\":{},\"tid\":{},\"t_ns\":{}}}",
                        json_safe(record.name),
                        record.flow,
                        json_safe(&record.terminal),
                        std::process::id(),
                        record.tid,
                        record.t_ns
                    );
                }
                Message::Flush(waiter) => waiters.push(waiter),
            }
            next = messages.try_recv().ok();
        }
        if let Some(sink) = sink() {
            let dropped = sink.dropped.load(Ordering::Relaxed);
            if dropped != reported {
                let _ = writeln!(out, "{{\"dropped\":{dropped}}}");
                reported = dropped;
            }
        }
        let _ = out.flush();
        for waiter in waiters {
            let _ = waiter.try_send(());
        }
    }
}

/// Hex ids and hop names only ever hold `[0-9a-z._-]`; anything else is
/// dropped rather than escaped, so a line is always valid JSON.
fn json_safe(text: &str) -> String {
    text.chars().filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')).collect()
}

/// Whether flow marks are recorded in this process.
pub fn enabled() -> bool {
    sink().is_some()
}

/// Records hop `name` of flow `flow` (0: a hop no message carries the id to)
/// on `terminal` (its hex id). `terminal` runs only when marks are on.
pub fn hop(name: &'static str, flow: u64, terminal: impl FnOnce() -> String) {
    let Some(sink) = sink() else { return };
    let record = Record { name, flow, terminal: terminal(), tid: thread_id(), t_ns: now_ns() };
    if let Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) =
        sink.queue.try_send(Message::Record(record))
    {
        sink.dropped.fetch_add(1, Ordering::Relaxed);
    }
}

/// Waits until every hop recorded before the call is in the file (tests, and
/// a process that ends on purpose). Returns false when marks are off or the
/// writer is gone. Never call it on a request path: it waits for the writer.
pub fn flush() -> bool {
    let Some(sink) = sink() else { return false };
    let (done, wait) = std::sync::mpsc::sync_channel(1);
    if sink.queue.send(Message::Flush(done)).is_err() {
        return false;
    }
    wait.recv().is_ok()
}

/// Lowercase hex of a terminal's 16-byte id (the daemon's `TerminalId::to_hex`).
pub fn hex(id: &[u8]) -> String {
    let mut out = String::with_capacity(id.len() * 2);
    for byte in id {
        for nibble in [byte >> 4, byte & 0x0f] {
            out.push(char::from_digit(u32::from(nibble), 16).unwrap_or('0'));
        }
    }
    out
}

#[cfg(target_os = "macos")]
fn now_ns() -> u64 {
    // Declared here as in cmux-tui-platform (process_resources.rs): one clock id, no libc version question.
    const CLOCK_UPTIME_RAW: u32 = 8;
    unsafe extern "C" {
        fn clock_gettime_nsec_np(clock: u32) -> u64;
    }
    // SAFETY: CLOCK_UPTIME_RAW is a valid clock id; the call has no other
    // preconditions and returns 0 on failure.
    unsafe { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

#[cfg(not(target_os = "macos"))]
fn now_ns() -> u64 {
    let mut now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: `now` is a valid out pointer for the call.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut now) };
    (now.tv_sec as u64).saturating_mul(1_000_000_000).saturating_add(now.tv_nsec as u64)
}

/// The system-wide id of the calling thread (the id Instruments and
/// `log stream` show).
#[cfg(target_os = "macos")]
fn thread_id() -> u64 {
    let mut id = 0u64;
    // SAFETY: a null thread means the calling thread; `id` is a valid out pointer.
    unsafe { libc::pthread_threadid_np(0, &mut id) };
    id
}

#[cfg(target_os = "linux")]
fn thread_id() -> u64 {
    // SAFETY: gettid has no preconditions.
    unsafe { libc::gettid() as u64 }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn thread_id() -> u64 {
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_matches_the_daemon_terminal_id() {
        assert_eq!(hex(&[0x00, 0x0f, 0xa5, 0xff]), "000fa5ff");
    }

    #[test]
    fn json_safe_keeps_ids_and_drops_the_rest() {
        assert_eq!(json_safe("ab12.x_y-z"), "ab12.x_y-z");
        assert_eq!(json_safe("a\"b\\c\nd"), "abcd");
    }

    #[test]
    fn the_clock_moves_forward() {
        let first = now_ns();
        let second = now_ns();
        assert!(first > 0 && second >= first);
    }
}
