//! Debug timing marks on the terminal create path (R81; zero-wait IX0).
//!
//! Off unless `CMUX_TUI_DEBUG_SPANS` names a file. A create starts a
//! [`Trace`] at the time its request arrived; code on the path calls
//! [`mark`] with a name, which records the time since arrival on the trace
//! installed on the current thread (and does nothing when no trace is
//! installed, as on every thread outside a create). The trace moves with
//! the create between threads ([`take`], [`install`]) and is appended to the
//! file as one JSON line when the reply is queued ([`finish`]):
//! `{"label":"new-tab","total_us":N,"marks":[["name",us],...]}`, with
//! `"terminal":"<hex>"` once the trace names its terminal ([`label_terminal`],
//! [`follow`]). The gap before a mark is the cost of the step the mark names.
//!
//! A create that [`follow`]s its terminal also owes it [`FOLLOW_MARKS`],
//! recorded once each by [`terminal_mark`] from the output paths, from the
//! same request arrival, as one line each labelled `<label>.follow`.

use std::borrow::Cow;
use std::cell::RefCell;
use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::Instant;

/// Marks of one create, measured from the arrival of its request.
pub struct Trace {
    label: &'static str,
    start: Instant,
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

/// Whether marks are recorded in this process.
pub(crate) fn enabled() -> bool {
    sink().is_some()
}

impl Trace {
    /// A trace for a request that arrived at `start`, or `None` when marks
    /// are off.
    pub fn start(label: &'static str, start: Instant) -> Option<Self> {
        enabled().then(|| Self { label, start, marks: Vec::new(), terminal: None })
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
    if !enabled() {
        return None;
    }
    CURRENT.with(|current| current.borrow_mut().take())
}

/// Record `name` on the current thread's trace, if any.
pub fn mark(name: &'static str) {
    mark_with(|| Cow::Borrowed(name));
}

/// Record a computed name; `name` runs only when a trace is installed.
pub fn mark_with(name: impl FnOnce() -> Cow<'static, str>) {
    if !enabled() {
        return;
    }
    CURRENT.with(|current| {
        if let Ok(mut current) = current.try_borrow_mut()
            && let Some(trace) = current.as_mut()
        {
            let elapsed = trace.start.elapsed().as_micros() as u64;
            trace.marks.push((name(), elapsed));
        }
    });
}

/// Name the terminal of the current thread's trace, if any; `terminal` runs
/// only when a trace is installed.
pub fn label_terminal(terminal: impl FnOnce() -> String) {
    if !enabled() {
        return;
    }
    CURRENT.with(|current| {
        if let Ok(mut current) = current.try_borrow_mut()
            && let Some(trace) = current.as_mut()
        {
            trace.terminal = Some(terminal());
        }
    });
}

/// Name `terminal` on the current thread's trace and owe it
/// [`FOLLOW_MARKS`], measured from the same request arrival.
pub fn follow(terminal: &str) {
    if !enabled() {
        return;
    }
    let followed = CURRENT.with(|current| {
        let mut current = current.try_borrow_mut().ok()?;
        let trace = current.as_mut()?;
        trace.terminal = Some(terminal.to_owned());
        Some(Followed {
            label: trace.label,
            terminal: terminal.to_owned(),
            start: trace.start,
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
    let (label, elapsed) = {
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
        let found = (entry.label, entry.start.elapsed().as_micros() as u64);
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

/// Append `trace` to the marks file.
pub fn finish(trace: Option<Trace>) {
    let Some(trace) = trace else { return };
    let marks = trace
        .marks
        .iter()
        .map(|(name, elapsed)| serde_json::json!([name, elapsed]))
        .collect::<Vec<_>>();
    let mut line = serde_json::json!({
        "label": trace.label,
        "total_us": trace.start.elapsed().as_micros() as u64,
        "marks": marks,
    });
    if let (Some(terminal), Some(object)) = (trace.terminal, line.as_object_mut()) {
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
/// `sqlite.commit` is the commit's write and sync.
pub fn traced(connection: rusqlite::Connection) -> rusqlite::Connection {
    if enabled() {
        let _ = connection.commit_hook(Some(|| {
            mark("sqlite.commit");
            false
        }));
    }
    connection
}
