//! Key-press flow marks for `scripts/cmux-next/trace.py` (plans/cmux-next/trace.md, "Key-press flows").
//!
//! Off unless `CMUX_TRACE_FLOWS` names a directory. Each process that marks hops
//! calls [`init`] once at start (the daemon, the terminal host, the holder): it
//! reads the variable and, when it is set, opens `<dir>/flows-<pid>.jsonl`, makes
//! the ring and starts the writer thread. So no hop ever opens a file or starts a
//! thread on a request or PTY path.
//!
//! The hop path does no allocation, takes no lock and makes no system call:
//! - off: one load of a `OnceLock` (never initialised when [`init`] found no
//!   variable);
//! - on: a `clock_gettime_nsec_np` read of the clock (a commpage read on macOS,
//!   no kernel entry), the thread id (`pthread_threadid_np`, read from the thread
//!   itself), and a push into a fixed ring of plain records (atomic slots; the
//!   terminal id is copied as at most 32 bytes). A full ring drops the record and
//!   counts it (`{"dropped":N}` in the file).
//!
//! The writer thread drains the ring every [`DRAIN_INTERVAL`] while tracing is on
//! (a deliberate timer: a diagnostic mode, never on in a normal run), or at once
//! when a hop finds the ring half full (the one wake a hop may send). Each record
//! is one JSON line: hop name, flow id or 0, terminal hex id, pid, thread id and
//! `CLOCK_UPTIME_RAW` in nanoseconds on macOS (the performance counter on Windows,
//! `CLOCK_MONOTONIC` elsewhere): the clock of the app's signposts, so no offset is guessed.
//!
//! A hop with a flow id carries the id the app minted for one key press (the
//! `send` request's `flow`). A hop with flow 0 is on a path no message carries
//! the id over (the PTY write in a terminal host, the echo read, the echo's way
//! back): trace.py places it in the press whose window on the same terminal
//! holds it.
//!
//! std and libc only: the holder (`cmux-holder`) links it too.

use std::cell::UnsafeCell;
use std::io::Write;
use std::mem::MaybeUninit;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::Duration;

/// Records the ring holds before a hop is dropped (and counted). A power of two.
pub const RING_SLOTS: usize = 8192;
/// How often the writer drains the ring while tracing is on.
pub const DRAIN_INTERVAL: Duration = Duration::from_millis(50);
/// A hop that finds this many records waiting wakes the writer at once.
const HIGH_WATER: usize = RING_SLOTS / 2;
/// The longest terminal id a record keeps (a 16-byte id in lowercase hex).
const TERMINAL_BYTES: usize = 32;

#[derive(Clone, Copy)]
struct Record {
    name: &'static str,
    flow: u64,
    terminal: [u8; TERMINAL_BYTES],
    terminal_len: u8,
    tid: u64,
    t_ns: u64,
}

struct Slot {
    sequence: AtomicUsize,
    record: UnsafeCell<MaybeUninit<Record>>,
}

/// A bounded multi-producer, single-consumer ring (Vyukov's bounded queue): a
/// producer claims a slot by moving `tail` with a compare-and-swap, writes the
/// record, then publishes it by its slot's sequence; the writer thread reads
/// slots in order by `head`.
struct Ring {
    slots: Box<[Slot]>,
    tail: AtomicUsize,
    head: AtomicUsize,
}

// SAFETY: a slot's record is written only by the producer that claimed it (the
// compare-and-swap on `tail` hands each position to one producer) before it
// publishes the slot's sequence with Release, and read only by the one writer
// thread after it sees that sequence with Acquire.
unsafe impl Sync for Ring {}

impl Ring {
    fn new() -> Self {
        let slots = (0..RING_SLOTS)
            .map(|index| Slot {
                sequence: AtomicUsize::new(index),
                record: UnsafeCell::new(MaybeUninit::uninit()),
            })
            .collect();
        Ring { slots, tail: AtomicUsize::new(0), head: AtomicUsize::new(0) }
    }

    /// Pushes `record`; false when the ring is full.
    fn push(&self, record: Record) -> bool {
        let mut position = self.tail.load(Ordering::Relaxed);
        loop {
            let Some(slot) = self.slots.get(position & (RING_SLOTS - 1)) else { return false };
            let sequence = slot.sequence.load(Ordering::Acquire);
            let difference = sequence as isize - position as isize;
            if difference == 0 {
                match self.tail.compare_exchange_weak(
                    position,
                    position + 1,
                    Ordering::Relaxed,
                    Ordering::Relaxed,
                ) {
                    Ok(_) => {
                        // SAFETY: this producer owns the slot until it publishes it below.
                        unsafe { (*slot.record.get()).write(record) };
                        slot.sequence.store(position + 1, Ordering::Release);
                        return true;
                    }
                    Err(current) => position = current,
                }
            } else if difference < 0 {
                return false;
            } else {
                position = self.tail.load(Ordering::Relaxed);
            }
        }
    }

    /// Pops the oldest published record (the writer thread only).
    fn pop(&self) -> Option<Record> {
        let position = self.head.load(Ordering::Relaxed);
        let slot = self.slots.get(position & (RING_SLOTS - 1))?;
        if slot.sequence.load(Ordering::Acquire) != position + 1 {
            return None;
        }
        // SAFETY: the producer published this slot (its sequence is position + 1).
        let record = unsafe { (*slot.record.get()).assume_init_read() };
        slot.sequence.store(position + RING_SLOTS, Ordering::Release);
        self.head.store(position + 1, Ordering::Relaxed);
        Some(record)
    }

    fn waiting(&self) -> usize {
        self.tail.load(Ordering::Relaxed).saturating_sub(self.head.load(Ordering::Relaxed))
    }
}

/// What the hops and the writer thread share.
struct Shared {
    ring: Ring,
    dropped: AtomicU64,
    /// A hop asked the writer to drain early (cleared by the writer).
    nudged: AtomicBool,
    /// Records written so far, for [`flush`] (records pushed: `ring.tail`).
    written: Mutex<usize>,
    written_changed: Condvar,
}

struct Sink {
    shared: std::sync::Arc<Shared>,
    writer: std::thread::Thread,
}

static SINK: OnceLock<Option<Sink>> = OnceLock::new();

/// Starts flow marks in this process when `CMUX_TRACE_FLOWS` names a directory:
/// the file, the ring and the writer thread. Call it once at process start,
/// before any request or PTY work; later calls do nothing. Returns whether
/// marks are on.
pub fn init() -> bool {
    SINK.get_or_init(|| {
        let dir = std::env::var_os("CMUX_TRACE_FLOWS").filter(|dir| !dir.is_empty())?;
        let path = std::path::Path::new(&dir).join(format!("flows-{}.jsonl", std::process::id()));
        let file = std::fs::OpenOptions::new().create(true).append(true).open(path).ok()?;
        let shared = std::sync::Arc::new(Shared {
            ring: Ring::new(),
            dropped: AtomicU64::new(0),
            nudged: AtomicBool::new(false),
            written: Mutex::new(0),
            written_changed: Condvar::new(),
        });
        let drained = shared.clone();
        let writer = std::thread::Builder::new()
            .name("flow-trace".into())
            .spawn(move || write_records(file, &drained))
            .ok()?;
        Some(Sink { shared, writer: writer.thread().clone() })
    })
    .is_some()
}

fn sink() -> Option<&'static Sink> {
    SINK.get().and_then(Option::as_ref)
}

/// The writer thread: drains the ring every [`DRAIN_INTERVAL`] (or when nudged),
/// one JSON line per record, one flush per drain.
fn write_records(file: std::fs::File, sink: &Shared) {
    let mut out = std::io::BufWriter::new(file);
    let mut reported = 0;
    let pid = std::process::id();
    loop {
        let mut count = 0;
        while let Some(record) = sink.ring.pop() {
            let terminal =
                record.terminal.get(..usize::from(record.terminal_len)).unwrap_or_default();
            let _ = writeln!(
                out,
                "{{\"hop\":\"{}\",\"flow\":{},\"terminal\":\"{}\",\"pid\":{},\"tid\":{},\"t_ns\":{}}}",
                json_safe(record.name),
                record.flow,
                json_safe(std::str::from_utf8(terminal).unwrap_or("")),
                pid,
                record.tid,
                record.t_ns
            );
            count += 1;
        }
        let dropped = sink.dropped.load(Ordering::Relaxed);
        if dropped != reported {
            let _ = writeln!(out, "{{\"dropped\":{dropped}}}");
            reported = dropped;
        }
        let _ = out.flush();
        if count > 0 {
            let mut written =
                sink.written.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            *written += count;
            sink.written_changed.notify_all();
        }
        sink.nudged.store(false, Ordering::Relaxed);
        if sink.ring.waiting() == 0 {
            std::thread::park_timeout(DRAIN_INTERVAL);
        }
    }
}

/// Hop names and hex ids only ever hold `[0-9a-z._-]`; anything else is
/// dropped rather than escaped, so a line is always valid JSON.
fn json_safe(text: &str) -> String {
    text.chars().filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')).collect()
}

/// Whether flow marks are recorded in this process (after [`init`]).
pub fn enabled() -> bool {
    sink().is_some()
}

/// Records hop `name` of flow `flow` (0: a hop no message carries the id to) on
/// the terminal whose lowercase hex id is `terminal` (at most 32 bytes are kept).
/// No allocation, lock or system call (see the module doc).
pub fn hop(name: &'static str, flow: u64, terminal: &str) {
    let Some(sink) = sink() else { return };
    let bytes = terminal.as_bytes();
    let len = bytes.len().min(TERMINAL_BYTES);
    let mut record = Record {
        name,
        flow,
        terminal: [0; TERMINAL_BYTES],
        terminal_len: len as u8,
        tid: thread_id(),
        t_ns: now_ns(),
    };
    if let (Some(into), Some(from)) = (record.terminal.get_mut(..len), bytes.get(..len)) {
        into.copy_from_slice(from);
    }
    push(sink, record);
}

/// [`hop`] for a terminal named by its 16 raw id bytes (the holder, the terminal
/// host): hex-encoded into the record, no allocation.
pub fn hop_id(name: &'static str, flow: u64, terminal: &[u8; 16]) {
    let Some(sink) = sink() else { return };
    let mut record = Record {
        name,
        flow,
        terminal: [0; TERMINAL_BYTES],
        terminal_len: TERMINAL_BYTES as u8,
        tid: thread_id(),
        t_ns: now_ns(),
    };
    for (pair, byte) in record.terminal.chunks_exact_mut(2).zip(terminal) {
        if let [high, low] = pair {
            *high = hex_digit(byte >> 4);
            *low = hex_digit(byte & 0x0f);
        }
    }
    push(sink, record);
}

const HEX: &[u8; 16] = b"0123456789abcdef";

/// The lowercase hex digit of the low four bits of `nibble`.
fn hex_digit(nibble: u8) -> u8 {
    HEX.get(usize::from(nibble & 0x0f)).copied().unwrap_or(b'0')
}

fn push(sink: &Sink, record: Record) {
    let shared = &sink.shared;
    if !shared.ring.push(record) {
        shared.dropped.fetch_add(1, Ordering::Relaxed);
        return;
    }
    // The one wake a hop may send: the ring is half full before the next timed drain.
    if shared.ring.waiting() >= HIGH_WATER && !shared.nudged.swap(true, Ordering::Relaxed) {
        sink.writer.unpark();
    }
}

/// Waits until every hop recorded before the call is in the file (tests, and a
/// process that ends on purpose). Returns false when marks are off. Never call
/// it on a request path: it waits for the writer.
pub fn flush() -> bool {
    let Some(sink) = sink() else { return false };
    let shared = &sink.shared;
    let target = shared.ring.tail.load(Ordering::Acquire);
    sink.writer.unpark();
    let mut written = shared.written.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    // A dropped record never took a ring position, so `tail` counts only pushed ones.
    while *written < target {
        let (next, _) = shared
            .written_changed
            .wait_timeout(written, DRAIN_INTERVAL)
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        written = next;
        sink.writer.unpark();
    }
    true
}

/// Lowercase hex of a terminal's 16-byte id (the daemon's `TerminalId::to_hex`).
pub fn hex(id: &[u8]) -> String {
    let mut out = String::with_capacity(id.len() * 2);
    for byte in id {
        out.push(char::from(hex_digit(byte >> 4)));
        out.push(char::from(hex_digit(byte & 0x0f)));
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

#[cfg(not(any(target_os = "macos", windows)))]
fn now_ns() -> u64 {
    let mut now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: `now` is a valid out pointer for the call.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut now) };
    (now.tv_sec as u64).saturating_mul(1_000_000_000).saturating_add(now.tv_nsec as u64)
}

/// The performance counter in nanoseconds, with no allocation or lock. On most current Windows
/// machines (an invariant TSC) both reads come from user-mode shared data with no kernel entry;
/// with an HPET or PM-timer counter Windows enters the kernel, as close to the rule as the platform
/// allows. Declared here as on macOS, so the crate stays std and libc only.
#[cfg(windows)]
fn now_ns() -> u64 {
    unsafe extern "system" {
        fn QueryPerformanceCounter(count: *mut i64) -> i32;
        fn QueryPerformanceFrequency(frequency: *mut i64) -> i32;
    }
    let (mut count, mut frequency) = (0i64, 0i64);
    // SAFETY: both are valid out pointers; the calls have no other preconditions and cannot
    // fail on Windows XP and later.
    unsafe {
        QueryPerformanceCounter(&mut count);
        QueryPerformanceFrequency(&mut frequency);
    }
    if frequency <= 0 {
        return 0;
    }
    let ns =
        u128::from(count.unsigned_abs()) * 1_000_000_000 / u128::from(frequency.unsigned_abs());
    u64::try_from(ns).unwrap_or(u64::MAX)
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

    #[test]
    fn the_ring_keeps_order_and_refuses_when_full() {
        let ring = Ring::new();
        let record = |flow| Record {
            name: "x",
            flow,
            terminal: [0; TERMINAL_BYTES],
            terminal_len: 0,
            tid: 0,
            t_ns: 0,
        };
        for flow in 0..RING_SLOTS as u64 {
            assert!(ring.push(record(flow)));
        }
        assert!(!ring.push(record(u64::MAX)), "a full ring took a record");
        assert_eq!(ring.pop().map(|r| r.flow), Some(0));
        assert!(ring.push(record(7)), "a freed slot was not reused");
        let mut last = 0;
        while let Some(r) = ring.pop() {
            last = r.flow;
        }
        assert_eq!(last, 7);
        assert_eq!(ring.waiting(), 0);
    }
}
