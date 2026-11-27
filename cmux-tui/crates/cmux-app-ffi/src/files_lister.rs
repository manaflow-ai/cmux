//! The client of cmux-tui's `__files-lister` child for the macOS app
//! (`include/cmux_files_lister.h`, Swift module `CCmuxFilesListerFFI`): one
//! JSON request per line on the child's stdin, one reply per line on its
//! stdout (cmux-tui `files_lister.rs`).
//!
//! A DEV build runs that child under its "cmux Files (dev)" helper, so macOS
//! charges the Files pane's reads of Desktop, Documents and Downloads to the
//! helper (docs/cmux-files-host.md, "The Files pane"). The app's
//! `ProcessDirectoryLister` resolves the child's argv and turns entries into
//! `FileEntry` values; this module starts the child, sends requests, matches
//! replies to them and decides when to stop trying.
//!
//! The child starts at the first request and serves until the lister is freed
//! (its stdin closes). A child that fails to start, exits, or answers a line
//! with `error` makes that request's callback get no reply (the app reads in
//! process); after `MAX_CONSECUTIVE_FAILURES` failures without an answer in
//! between, every request is refused. Writes go through a writer thread and
//! replies are read on a reader thread: no call blocks its caller on the
//! child.

use cmux_process::{Child, Command, Stdio};
use serde::Deserialize;
use serde::de::IgnoredAny;
use std::collections::HashMap;
use std::ffi::{CStr, c_char, c_void};
use std::io::{BufRead, BufReader, Write};
use std::process::ChildStdout;
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};

/// Bumped on any change to a type or a function.
pub const CMUX_FILES_LISTER_ABI_VERSION: u32 = 1;

/// Failures in a row (no answer in between) after which every request is
/// refused and the app reads in process.
pub(crate) const MAX_CONSECUTIVE_FAILURES: u32 = 3;
/// The longest reply line read: a listing of a few hundred thousand items. A
/// longer one is dropped, and its request waits for the child to exit.
pub(crate) const MAX_REPLY_BYTES: usize = 256 << 20;

/// Called once per request `cmux_files_lister_request` accepted: `reply` is
/// the child's reply line (a JSON object with `entries`, `entry` or `errno`,
/// UTF-8, `reply_len` bytes, valid only during the call), or null with
/// `reply_len` 0 when there is none (read in process). Called on the
/// lister's reader thread, or on the thread that cancels or frees.
pub type CmuxFilesListerCallback =
    Option<unsafe extern "C" fn(context: *mut c_void, reply: *const u8, reply_len: usize)>;

/// One client of one child (opaque).
pub struct CmuxFilesLister {
    inner: Arc<Inner>,
}

struct Waiter {
    callback: unsafe extern "C" fn(*mut c_void, *const u8, usize),
    context: *mut c_void,
}

// SAFETY: the context is the caller's, which promises it may be used from any thread.
unsafe impl Send for Waiter {}

impl Waiter {
    fn answer(self, reply: Option<&[u8]>) {
        let (ptr, len) = reply.map_or((std::ptr::null(), 0), |r| (r.as_ptr(), r.len()));
        // SAFETY: the caller's callback and context, called once.
        unsafe { (self.callback)(self.context, ptr, len) };
    }
}

struct Running {
    feed: Sender<Vec<u8>>,
    generation: u64,
}

#[derive(Default)]
struct State {
    running: Option<Running>,
    generation: u64,
    next_id: u64,
    pending: HashMap<u64, Waiter>,
    failures: u32,
}

struct Inner {
    argv: Vec<String>,
    state: Mutex<State>,
}

/// One reply line, read only for its id and whether it is an error.
#[derive(Deserialize)]
struct Wire {
    #[serde(default)]
    id: Option<u64>,
    #[serde(default)]
    error: Option<IgnoredAny>,
}

impl Inner {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Sends one request; `None` when it was refused (the waiter is returned).
    fn request(self: &Arc<Self>, op: &str, path: &str, waiter: Waiter) -> Result<u64, Waiter> {
        let mut state = self.lock();
        if state.failures >= MAX_CONSECUTIVE_FAILURES {
            return Err(waiter);
        }
        if state.running.is_none() && !self.start(&mut state) {
            return Err(waiter);
        }
        state.next_id += 1;
        let id = state.next_id;
        let mut line = serde_json::to_vec(&serde_json::json!({ "id": id, "op": op, "path": path }))
            .unwrap_or_default();
        line.push(b'\n');
        let sent = state.running.as_ref().is_some_and(|r| r.feed.send(line).is_ok());
        if !sent {
            return Err(waiter);
        }
        state.pending.insert(id, waiter);
        Ok(id)
    }

    /// Starts the child; false (one failure more) when it cannot.
    fn start(self: &Arc<Self>, state: &mut State) -> bool {
        let Some((program, args)) = self.argv.split_first() else {
            state.failures += 1;
            return false;
        };
        let spawned = Command::new(program)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn();
        let mut child = match spawned {
            Ok(child) => child,
            Err(_) => {
                state.failures += 1;
                return false;
            }
        };
        let (Some(mut stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
            let _ = child.kill();
            let _ = child.wait();
            state.failures += 1;
            return false;
        };
        state.generation += 1;
        let generation = state.generation;
        let (feed, lines) = channel::<Vec<u8>>();
        // The writer ends when the lister drops its feed (or the child stops
        // reading), closing the child's stdin.
        let writer =
            std::thread::Builder::new().name("cmux-files-lister-write".into()).spawn(move || {
                for line in lines {
                    if stdin.write_all(&line).and_then(|()| stdin.flush()).is_err() {
                        break;
                    }
                }
            });
        let reader_inner = Arc::clone(self);
        let reader = std::thread::Builder::new()
            .name("cmux-files-lister-read".into())
            .spawn(move || reader_inner.read(stdout, child, generation));
        if writer.is_err() || reader.is_err() {
            state.failures += 1;
            return false;
        }
        state.running = Some(Running { feed, generation });
        true
    }

    /// Reads reply lines until the child closes its stdout, then reaps it.
    /// The child is owned here: it ends when the lister closes its stdin,
    /// and a reader that stops early drops (and so ends) it.
    fn read(&self, stdout: ChildStdout, mut child: Child, generation: u64) {
        let mut reader = BufReader::with_capacity(1 << 16, stdout);
        let mut line = Vec::new();
        loop {
            line.clear();
            match read_line(&mut reader, &mut line) {
                Ok(Line::Complete) => self.answer(&line),
                Ok(Line::TooLong) => {}
                Ok(Line::End) | Err(_) => break,
            }
        }
        let _ = child.wait();
        self.ended(generation);
    }

    fn answer(&self, line: &[u8]) {
        let Ok(wire) = serde_json::from_slice::<Wire>(line) else { return };
        let Some(id) = wire.id else { return };
        let waiter = {
            let mut state = self.lock();
            let Some(waiter) = state.pending.remove(&id) else { return };
            if wire.error.is_none() {
                state.failures = 0;
            } else {
                state.failures += 1;
            }
            waiter
        };
        waiter.answer(if wire.error.is_none() { Some(line) } else { None });
    }

    /// The child exited: every request it had not answered gets no reply.
    fn ended(&self, generation: u64) {
        let waiters: Vec<Waiter> = {
            let mut state = self.lock();
            if state.running.as_ref().map(|r| r.generation) != Some(generation) {
                return;
            }
            state.running = None;
            if !state.pending.is_empty() {
                state.failures += 1;
            }
            state.pending.drain().map(|(_, w)| w).collect()
        };
        for waiter in waiters {
            waiter.answer(None);
        }
    }

    fn cancel(&self, id: u64) -> bool {
        let waiter = self.lock().pending.remove(&id);
        let found = waiter.is_some();
        if let Some(waiter) = waiter {
            waiter.answer(None);
        }
        found
    }

    fn close(&self) {
        let waiters: Vec<Waiter> = {
            let mut state = self.lock();
            state.running = None;
            state.failures = MAX_CONSECUTIVE_FAILURES;
            state.pending.drain().map(|(_, w)| w).collect()
        };
        for waiter in waiters {
            waiter.answer(None);
        }
    }
}

enum Line {
    Complete,
    TooLong,
    End,
}

/// One line without its newline into `line`; a line past `MAX_REPLY_BYTES` is
/// skipped to its newline. A last line with no newline is dropped.
fn read_line(reader: &mut impl BufRead, line: &mut Vec<u8>) -> std::io::Result<Line> {
    let mut too_long = false;
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            return Ok(Line::End);
        }
        let (chunk, done) = match available.iter().position(|&b| b == b'\n') {
            Some(at) => (&available[..at], Some(at + 1)),
            None => (available, None),
        };
        if !too_long {
            if line.len() + chunk.len() > MAX_REPLY_BYTES {
                too_long = true;
                line.clear();
            } else {
                line.extend_from_slice(chunk);
            }
        }
        let used = done.unwrap_or(available.len());
        reader.consume(used);
        if done.is_some() {
            return Ok(if too_long { Line::TooLong } else { Line::Complete });
        }
    }
}

/// `CMUX_FILES_LISTER_ABI_VERSION`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_files_lister_abi_version() -> u32 {
    CMUX_FILES_LISTER_ABI_VERSION
}

/// A lister that runs `argv` (`argc` NUL-terminated strings, the first the
/// executable) at its first request. Starts nothing. Null when `argv` is null,
/// `argc` is 0 or a string is not UTF-8. Free it with `cmux_files_lister_free`.
///
/// # Safety
///
/// `argv` is null or points to `argc` NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_files_lister_new(
    argv: *const *const c_char,
    argc: usize,
) -> *mut CmuxFilesLister {
    if argv.is_null() || argc == 0 {
        return std::ptr::null_mut();
    }
    // SAFETY: `argc` readable pointers per the contract.
    let raw = unsafe { std::slice::from_raw_parts(argv, argc) };
    let mut args = Vec::with_capacity(argc);
    for &arg in raw {
        if arg.is_null() {
            return std::ptr::null_mut();
        }
        // SAFETY: NUL-terminated per the contract.
        let Ok(text) = unsafe { CStr::from_ptr(arg) }.to_str() else {
            return std::ptr::null_mut();
        };
        args.push(text.to_owned());
    }
    let inner = Arc::new(Inner { argv: args, state: Mutex::new(State::default()) });
    Box::into_raw(Box::new(CmuxFilesLister { inner }))
}

/// Sends `op` (`list` or `entry`) for `path` (both NUL-terminated), starting
/// the child when none runs. Returns the request's id (never 0), after which
/// `callback` is called exactly once with `context`; or 0, and `callback` is
/// never called, when the request was refused (no child, too many failures):
/// the app reads in process.
///
/// # Safety
///
/// `lister` is null or live; `op` and `path` are NUL-terminated; `context`
/// may be used from any thread until `callback` runs.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_files_lister_request(
    lister: *const CmuxFilesLister,
    op: *const c_char,
    path: *const c_char,
    callback: CmuxFilesListerCallback,
    context: *mut c_void,
) -> u64 {
    // SAFETY: null or live per the contract.
    let (Some(lister), Some(callback)) = (unsafe { lister.as_ref() }, callback) else { return 0 };
    if op.is_null() || path.is_null() {
        return 0;
    }
    // SAFETY: NUL-terminated per the contract.
    let (Ok(op), Ok(path)) =
        (unsafe { CStr::from_ptr(op) }.to_str(), unsafe { CStr::from_ptr(path) }.to_str())
    else {
        return 0;
    };
    lister.inner.request(op, path, Waiter { callback, context }).unwrap_or(0)
}

/// Gives request `id` no reply now: its callback runs on this thread before
/// this returns, unless it already ran. True when it had not.
///
/// # Safety
///
/// `lister` is null or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_files_lister_cancel(lister: *const CmuxFilesLister, id: u64) -> bool {
    // SAFETY: null or live per the contract.
    unsafe { lister.as_ref() }.is_some_and(|l| l.inner.cancel(id))
}

/// Frees a lister: every request it had not answered gets no reply (on this
/// thread), and the child's stdin closes, so it exits. Null is ignored.
///
/// # Safety
///
/// `lister` is null or live, and not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_files_lister_free(lister: *mut CmuxFilesLister) {
    if lister.is_null() {
        return;
    }
    // SAFETY: from `cmux_files_lister_new`, freed once.
    let lister = unsafe { Box::from_raw(lister) };
    lister.inner.close();
}

#[cfg(test)]
#[path = "files_lister_tests.rs"]
mod tests;
