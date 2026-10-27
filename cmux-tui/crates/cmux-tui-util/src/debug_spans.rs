//! Debug timing marks on the terminal create path (R81; zero-wait IX0).
//!
//! Two sinks, each off unless asked for:
//!
//! - The marks file, when `CMUX_TUI_DEBUG_SPANS` names one. A create starts a
//!   [`Trace`] at the time its request arrived; code on the path calls
//!   [`mark`] with a name, which records the time since arrival on the trace
//!   installed on the current thread (and does nothing when no trace is
//!   installed, as on every thread outside a create). The trace moves with
//!   the create between threads ([`take`], [`install`]) and is appended to the
//!   file as one JSON line when the reply is queued ([`finish`]):
//!   `{"label":"new-tab","total_us":N,"start_uptime_ns":T,"tid":N,"marks":[["name",us],...]}`,
//!   with `"terminal":"<hex>"` once the trace names its terminal
//!   ([`label_terminal`], [`follow`]). `start_uptime_ns` is the arrival on the
//!   trace clock ([`cmux_trace::clock::now_ns`], `CLOCK_UPTIME_RAW` on macOS),
//!   so a line joins the app's signposts and the trace rings with no guessed
//!   offset; `tid` is the thread that wrote the line, as the rings' thread
//!   tables name it. The gap before a mark is the cost of the step the mark
//!   names.
//! - The process's trace ring (`cmux-trace`), while its `daemon` category is
//!   on. A trace is an async slice named by its label, begun when it starts
//!   and ended when it is dropped (by [`finish`] or on any other path, so no
//!   return path leaves it open), as Chrome's
//!   `TRACE_EVENT_NESTABLE_ASYNC_BEGIN0`/`END0`
//!   (`base/trace_event/common/trace_event_common.h`). Each [`mark`] is a
//!   thread-scoped instant on the writing thread (`TRACE_EVENT_INSTANT0` with
//!   `TRACE_EVENT_SCOPE_THREAD`): flags 0, arg0 the microseconds since the
//!   request arrived, arg1 0. The ring format has no async-scoped instant
//!   (Chrome's `TRACE_EVENT_NESTABLE_ASYNC_INSTANT0`), so a mark belongs to
//!   its slice by time and thread. Ring names come only from `&'static str`
//!   names; a computed [`mark_with`] name goes to the marks file only.
//!
//! A create that [`follow`]s its terminal also owes it [`FOLLOW_MARKS`],
//! recorded once each by [`terminal_mark`] from the output paths, from the
//! same request arrival, as one line each labelled `<label>.follow` in the
//! marks file.

use std::borrow::Cow;
use std::cell::RefCell;
use std::io::Write;
use std::ptr::null_mut;
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::Instant;

use cmux_trace::{FLAG_ID, InternedName, Phase, category};

/// Marks of one create, measured from the arrival of its request.
pub struct Trace {
    label: &'static str,
    start: Instant,
    /// The arrival on the trace clock.
    start_uptime_ns: u64,
    /// The id of its async slice in the ring (arg1 of its begin, end and marks).
    id: u64,
    /// Its begin went to the ring, so it owes the ring an end.
    in_ring: bool,
    /// It is appended to the marks file.
    in_file: bool,
    marks: Vec<(Cow<'static, str>, u64)>,
    /// The terminal the trace is about (the caller-minted id of a create,
    /// the host's own id in a host process).
    terminal: Option<String>,
}

/// What a followed terminal owes after its create's trace: the first output
/// the daemon reads from its host, the first output with text a person sees
/// (a printable byte outside escape sequences: login(1)'s "Last login", or
/// the prompt), its first prompt mark (OSC 133;A), and the first output it
/// sends an attachment.
pub const FOLLOW_MARKS: [&str; 4] = [
    "host.first_output",
    "first_printable_output",
    "first_prompt_mark",
    "attach.first_output_sent",
];

/// Followed terminals kept at most; a terminal that never prints is dropped
/// oldest first.
const FOLLOW_LIMIT: usize = 64;

/// How long a terminal stays followed: one never attached (a headless
/// create, a tab closed first) must not keep every output path checking.
const FOLLOW_WINDOW: std::time::Duration = std::time::Duration::from_secs(10);

/// A terminal still owed some of [`FOLLOW_MARKS`].
struct Followed {
    label: &'static str,
    terminal: String,
    start: Instant,
    start_uptime_ns: u64,
    left: Vec<&'static str>,
}

static FOLLOWED: Mutex<Vec<Followed>> = Mutex::new(Vec::new());

/// Some terminal is owed a mark: the only check output paths pay otherwise.
static FOLLOWING: AtomicBool = AtomicBool::new(false);

thread_local! {
    static CURRENT: RefCell<Option<Trace>> = const { RefCell::new(None) };
}

fn sink() -> Option<&'static Mutex<std::fs::File>> {
    static SINK: OnceLock<Option<Mutex<std::fs::File>>> = OnceLock::new();
    SINK.get_or_init(|| {
        let path = std::env::var_os("CMUX_TUI_DEBUG_SPANS").filter(|path| !path.is_empty())?;
        std::fs::OpenOptions::new().create(true).append(true).open(path).ok().map(Mutex::new)
    })
    .as_ref()
}

/// The ring category of every record written here.
const RING_CATEGORY: u64 = category::DAEMON;

/// [`RING_CATEGORY`]'s bit index: the category byte of the names it interns.
const RING_CATEGORY_BIT: u8 = RING_CATEGORY.trailing_zeros() as u8;

/// Whether the trace ring records [`RING_CATEGORY`] now: one relaxed load.
fn ring_on() -> bool {
    cmux_trace::enabled(RING_CATEGORY)
}

/// Whether marks are recorded in this process, in the marks file or the ring.
pub(crate) fn enabled() -> bool {
    ring_on() || sink().is_some()
}

/// The next async slice id: unique in the process, as ids in one ring must be.
static NEXT_ID: AtomicU64 = AtomicU64::new(1);

/// Some [`Trace`] started in this process, so a thread may hold one. It never
/// goes back to false: a trace stays installed after the ring stops
/// recording, and [`take`] must still move it.
static STARTED: AtomicBool = AtomicBool::new(false);

impl Trace {
    /// A trace for a request that arrived at `start`, or `None` when marks
    /// are off.
    pub fn start(label: &'static str, start: Instant) -> Option<Self> {
        let in_file = sink().is_some();
        let in_ring = ring_on();
        if !in_file && !in_ring {
            return None;
        }
        let since_start = u64::try_from(start.elapsed().as_nanos()).unwrap_or(u64::MAX);
        let start_uptime_ns = cmux_trace::clock::now_ns().saturating_sub(since_start);
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        STARTED.store(true, Ordering::Relaxed);
        if in_ring {
            ring_write(label, Phase::AsyncBegin, FLAG_ID, 0, id);
        }
        Some(Self {
            label,
            start,
            start_uptime_ns,
            id,
            in_ring,
            in_file,
            marks: Vec::new(),
            terminal: None,
        })
    }

    fn elapsed_us(&self) -> u64 {
        self.start.elapsed().as_micros() as u64
    }
}

impl Drop for Trace {
    /// Ends the ring slice on every path: [`finish`], or a trace dropped
    /// unfinished (an early return, a thread exiting with it installed).
    fn drop(&mut self) {
        if self.in_ring {
            ring_write(self.label, Phase::AsyncEnd, FLAG_ID, 0, self.id);
        }
    }
}

/// Make `trace` the current thread's trace.
pub fn install(trace: Option<Trace>) {
    if let Some(trace) = trace {
        CURRENT.with(|current| *current.borrow_mut() = Some(trace));
    }
}

/// Remove and return the current thread's trace.
pub fn take() -> Option<Trace> {
    if !STARTED.load(Ordering::Relaxed) {
        return None;
    }
    CURRENT.with(|current| current.borrow_mut().take())
}

/// Record `name` on the current thread's trace, if any: an instant in the
/// ring and a mark in the marks file.
pub fn mark(name: &'static str) {
    if !enabled() {
        return;
    }
    CURRENT.with(|current| {
        if let Ok(mut current) = current.try_borrow_mut()
            && let Some(trace) = current.as_mut()
        {
            let elapsed = trace.elapsed_us();
            if trace.in_ring {
                ring_write(name, Phase::Instant, 0, elapsed, 0);
            }
            if trace.in_file {
                trace.marks.push((Cow::Borrowed(name), elapsed));
            }
        }
    });
}

/// Record a computed name in the marks file; `name` runs only when a trace
/// appended to the file is installed. The ring takes no computed names.
pub fn mark_with(name: impl FnOnce() -> Cow<'static, str>) {
    if sink().is_none() {
        return;
    }
    CURRENT.with(|current| {
        if let Ok(mut current) = current.try_borrow_mut()
            && let Some(trace) = current.as_mut()
            && trace.in_file
        {
            let elapsed = trace.elapsed_us();
            trace.marks.push((name(), elapsed));
        }
    });
}

/// Distinct ring names kept: labels and [`mark`] names, a few dozen today.
const RING_NAME_SLOTS: usize = 256;

/// One interned ring name; leaked when published, so it lives as long as the
/// process, as the `static` an `InternedName` serves must.
struct RingName {
    text: &'static str,
    name: InternedName,
}

/// The ring names interned so far, by open addressing on the text's hash:
/// a lookup takes no lock and a name allocates once, at its first use.
static RING_NAMES: [AtomicPtr<RingName>; RING_NAME_SLOTS] =
    [const { AtomicPtr::new(null_mut()) }; RING_NAME_SLOTS];

/// What every name past [`RING_NAME_SLOTS`] distinct texts records as.
static RING_NAME_OVERFLOW: InternedName =
    InternedName::new("debug_spans.name_overflow", RING_CATEGORY_BIT);

/// The ring name of `text`, interned at its first use.
fn ring_name(text: &'static str) -> &'static InternedName {
    // FNV-1a.
    let hash = text.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    });
    let first = (hash % RING_NAME_SLOTS as u64) as usize;
    let mut fresh: Option<Box<RingName>> = None;
    for probe in 0..RING_NAME_SLOTS {
        let slot = &RING_NAMES[(first + probe) % RING_NAME_SLOTS];
        let mut entry = slot.load(Ordering::Acquire);
        if entry.is_null() {
            let new = Box::into_raw(fresh.take().unwrap_or_else(|| {
                Box::new(RingName { text, name: InternedName::new(text, RING_CATEGORY_BIT) })
            }));
            match slot.compare_exchange(null_mut(), new, Ordering::AcqRel, Ordering::Acquire) {
                Ok(_) => entry = new,
                Err(winner) => {
                    // SAFETY: `new` came from `Box::into_raw` above and was never published.
                    fresh = Some(unsafe { Box::from_raw(new) });
                    entry = winner;
                }
            }
        }
        // SAFETY: a published entry is never freed or written again.
        let entry: &'static RingName = unsafe { &*entry };
        if entry.text == text {
            return &entry.name;
        }
    }
    &RING_NAME_OVERFLOW
}

/// Write `text` with `phase`, `flags` and its args to the ring, if it records.
fn ring_write(text: &'static str, phase: Phase, flags: u8, arg0: u64, arg1: u64) {
    if ring_on() {
        cmux_trace::write_interned(RING_CATEGORY, ring_name(text), phase, flags, arg0, arg1);
    }
}

/// The calling thread's id, as the rings' thread tables name it.
fn current_tid() -> u64 {
    cmux_trace::ThreadIdentity::current().tid
}

/// Name the terminal of the current thread's trace, if any; `terminal` runs
/// only when a trace appended to the marks file is installed.
pub fn label_terminal(terminal: impl FnOnce() -> String) {
    if sink().is_none() {
        return;
    }
    CURRENT.with(|current| {
        if let Ok(mut current) = current.try_borrow_mut()
            && let Some(trace) = current.as_mut()
            && trace.in_file
        {
            trace.terminal = Some(terminal());
        }
    });
}

/// Name `terminal` on the current thread's trace and owe it
/// [`FOLLOW_MARKS`], measured from the same request arrival.
pub fn follow(terminal: &str) {
    if sink().is_none() {
        return;
    }
    let followed = CURRENT.with(|current| {
        let mut current = current.try_borrow_mut().ok()?;
        let trace = current.as_mut().filter(|trace| trace.in_file)?;
        trace.terminal = Some(terminal.to_owned());
        Some(Followed {
            label: trace.label,
            terminal: terminal.to_owned(),
            start: trace.start,
            start_uptime_ns: trace.start_uptime_ns,
            left: FOLLOW_MARKS.to_vec(),
        })
    });
    let Some(followed) = followed else { return };
    let mut owed = FOLLOWED.lock().unwrap_or_else(PoisonError::into_inner);
    owed.retain(|entry| entry.terminal != followed.terminal);
    if owed.len() >= FOLLOW_LIMIT {
        owed.remove(0);
    }
    owed.push(followed);
    FOLLOWING.store(true, Ordering::Release);
}

/// Whether some terminal is owed a mark ([`follow`]).
pub fn following() -> bool {
    FOLLOWING.load(Ordering::Acquire)
}

/// Whether `terminal` is still owed `name`.
pub fn owes(terminal: &str, name: &'static str) -> bool {
    following()
        && FOLLOWED
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .any(|entry| entry.terminal == terminal && entry.left.contains(&name))
}

/// Record `name` for `terminal` the first time, if it is followed.
pub fn terminal_mark(terminal: &str, name: &'static str) {
    if !following() {
        return;
    }
    let (label, start_uptime_ns, elapsed) = {
        let mut owed = FOLLOWED.lock().unwrap_or_else(PoisonError::into_inner);
        owed.retain(|entry| entry.start.elapsed() < FOLLOW_WINDOW);
        if owed.is_empty() {
            FOLLOWING.store(false, Ordering::Release);
        }
        let Some(index) =
            owed.iter().position(|entry| entry.terminal == terminal && entry.left.contains(&name))
        else {
            return;
        };
        let entry = &mut owed[index];
        entry.left.retain(|left| *left != name);
        let found = (entry.label, entry.start_uptime_ns, entry.start.elapsed().as_micros() as u64);
        if entry.left.is_empty() {
            owed.remove(index);
        }
        if owed.is_empty() {
            FOLLOWING.store(false, Ordering::Release);
        }
        found
    };
    write_line(&serde_json::json!({
        "label": format!("{label}.follow"),
        "terminal": terminal,
        "total_us": elapsed,
        "start_uptime_ns": start_uptime_ns,
        "tid": current_tid(),
        "marks": [[name, elapsed]],
    }));
}

/// OSC 133;A, the shell's prompt start (`ShellMark::PromptStart`).
const PROMPT_START: &[u8] = b"\x1b]133;A";

/// The first output, first printable output and first prompt mark of
/// `terminal`, when its create follows it: called with each chunk of
/// output the daemon reads for it, from its terminal host or from the
/// holder. A mark split across two chunks is missed.
pub fn output_marks(terminal: &str, output: &[u8]) {
    if !following() {
        return;
    }
    terminal_mark(terminal, "host.first_output");
    if owes(terminal, "first_printable_output") && has_printable_text(output) {
        terminal_mark(terminal, "first_printable_output");
    }
    if owes(terminal, "first_prompt_mark")
        && output.windows(PROMPT_START.len()).any(|window| window == PROMPT_START)
    {
        terminal_mark(terminal, "first_prompt_mark");
    }
}

/// Whether `output` has a printable byte outside escape sequences (CSI, OSC,
/// DCS/SOS/PM/APC strings, and escapes with intermediates such as `ESC ( B`).
/// Printable is ASCII graphic or a UTF-8 lead byte; C1 controls are not. A
/// sequence split across two chunks may be misread; this only times a debug
/// mark.
fn has_printable_text(output: &[u8]) -> bool {
    let mut bytes = output.iter().copied().peekable();
    while let Some(byte) = bytes.next() {
        match byte {
            0x1b => match bytes.next() {
                Some(b'[') => {
                    for byte in bytes.by_ref() {
                        if (0x40..=0x7e).contains(&byte) {
                            break;
                        }
                    }
                }
                Some(b']' | b'P' | b'X' | b'^' | b'_') => {
                    while let Some(byte) = bytes.next() {
                        if byte == 0x07 || (byte == 0x1b && bytes.next_if_eq(&b'\\').is_some()) {
                            break;
                        }
                    }
                }
                // Intermediates, then one final byte.
                Some(0x20..=0x2f) => {
                    for byte in bytes.by_ref() {
                        if !(0x20..=0x2f).contains(&byte) {
                            break;
                        }
                    }
                }
                _ => {}
            },
            0x21..=0x7e | 0xc2..=0xf4 => return true,
            _ => {}
        }
    }
    false
}

/// Append `trace` to the marks file, if it goes there; dropping it ends its
/// ring slice.
pub fn finish(trace: Option<Trace>) {
    let Some(mut trace) = trace else { return };
    if !trace.in_file {
        return;
    }
    let marks = trace
        .marks
        .iter()
        .map(|(name, elapsed)| serde_json::json!([name, elapsed]))
        .collect::<Vec<_>>();
    let mut line = serde_json::json!({
        "label": trace.label,
        "total_us": trace.elapsed_us(),
        "start_uptime_ns": trace.start_uptime_ns,
        "tid": current_tid(),
        "marks": marks,
    });
    if let (Some(terminal), Some(object)) = (trace.terminal.take(), line.as_object_mut()) {
        object.insert("terminal".to_owned(), terminal.into());
    }
    write_line(&line);
}

fn write_line(line: &serde_json::Value) {
    let Some(sink) = sink() else { return };
    if let Ok(mut file) = sink.lock() {
        let _ = writeln!(file, "{line}");
    }
}

/// Mark the start of every commit on a registry connection: the gap after
/// `sqlite.commit` is the commit's write and sync. Installed whatever the
/// sinks are now, since the ring may start recording after the connection
/// opens; [`mark`] checks them on each commit.
pub fn traced(connection: rusqlite::Connection) -> rusqlite::Connection {
    let _ = connection.commit_hook(Some(|| {
        mark("sqlite.commit");
        false
    }));
    connection
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_text_interns_to_one_name() {
        let first = ring_name("debug_spans.test.same");
        let again = ring_name(String::from("debug_spans.test.same").leak());
        let other = ring_name("debug_spans.test.other");
        assert!(std::ptr::eq(first, again));
        assert!(!std::ptr::eq(first, other));
    }

    #[test]
    fn names_intern_once_from_many_threads() {
        let handles: Vec<_> = (0..8)
            .map(|index| {
                cmux_threads::spawn(
                    format!("debug-spans-test-{index}"),
                    cmux_threads::ThreadQos::Utility,
                    || ring_name("debug_spans.test.race") as *const InternedName as usize,
                )
                .unwrap()
            })
            .collect();
        let names: Vec<usize> = handles.into_iter().map(|handle| handle.join().unwrap()).collect();
        assert!(names.windows(2).all(|pair| pair[0] == pair[1]), "{names:?}");
    }

    #[test]
    fn printable_text_skips_escape_sequences() {
        assert!(!has_printable_text(b"\x1b]133;A\x07\x1b[0m\x1b(B"));
        assert!(has_printable_text(b"\x1b]133;A\x07$ "));
    }
}
