//! The slow request log: after a slow or failed action, one read of a bounded
//! file in the session folder says which request was slow, how long each part
//! took, and which requests failed. The histograms of `server-stats` are lost
//! when the daemon exits and need a running daemon to read; this file does not.
//!
//! File: `<session dir>/slow-requests.jsonl` and `slow-requests.jsonl.1`, JSON
//! lines, each file at most [`FILE_BYTES`] (the older one is replaced by a
//! rename), so the disk bound is two files. One record for:
//!
//! - a request that took longer than [`SLOW_REQUEST_THRESHOLD`] from its line's
//!   arrival to its reply written to the socket,
//! - a request answered with an error,
//! - a request whose client left before the reply was written, or before the
//!   request ran,
//! - a hold of the session state lock or the registry lock longer than
//!   [`crate::diagnostics::LOCK_STALL_THRESHOLD`] (kind `lock`, with the holder's
//!   source site and thread),
//! - the daemon's start (kind `start`).
//!
//! Privacy: a record holds a command or operation name, numeric and public ids,
//! durations, sizes and an error code. The allow-list is `fields::ID_KEYS` and the
//! two name keys in `fields::Key`; every value passes a fixed grammar (`Label`), and a
//! name is written only for a line the daemon decoded as a known command or
//! operation (`decoded_command`; every other line's name is `other`). So no
//! terminal content, typed text, command, path, URL, token, client-chosen
//! request id or error message can reach the file.
//!
//! Cost: a request reads the monotonic clock at its arrival, at its start on
//! the dispatcher, when its reply is queued and when the reply is written, and
//! skims its line once for the allow-listed keys. A record is handed to the
//! `mux-slow-log` thread with a `try_send` on a bounded queue: a full queue
//! drops the record and counts it, the request never waits. The writer has no
//! timer and no fsync: with no slow or failed request it writes nothing.

use std::cell::RefCell;
use std::fmt::Write as _;
use std::fs::File;
use std::io::Write as _;
use std::panic::Location;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

mod fields;
#[cfg(test)]
mod tests;

pub(crate) use fields::Label;
use fields::{Allowed, ID_KEYS, allowed_fields};

/// A request slower than this, arrival to reply written, gets a record.
pub(crate) const SLOW_REQUEST_THRESHOLD: Duration = Duration::from_millis(100);
/// The newest records; the file before it is `<name>.1`.
pub(crate) const FILE_NAME: &str = "slow-requests.jsonl";
/// The most bytes of one of the two files.
pub(crate) const FILE_BYTES: u64 = 1 << 20;
/// Records that wait for the writer; more are dropped and counted.
const QUEUE_RECORDS: usize = 256;

/// How a request's record ended.
#[derive(Clone, Copy)]
enum End {
    /// The reply's bytes went to the socket.
    Written,
    /// The socket write of the reply failed.
    WriteFailed,
    /// The handler returned and sent no typed reply on this connection (`reply_follows`).
    Returned,
    /// Dropped: a queued request that never ran, or a reply nothing wrote.
    Dropped,
}

/// One request, from its line's arrival to its end.
struct Data {
    /// The connection's open flag (`MessageWriter::open`): its identity, and whether it is closed.
    connection: Arc<AtomicBool>,
    client: u64,
    client_name: Option<Label>,
    client_kind: Option<Label>,
    fields: Allowed,
    /// The name of the command or operation the daemon decoded the line as; none for every
    /// other line, whose `cmd` is the client's text.
    name: Option<Label>,
    request_bytes: usize,
    arrived: Instant,
    started: Instant,
    queued: Option<Instant>,
    reply_bytes: usize,
    lock_wait: Duration,
    registry_wait: Duration,
    error: Option<Label>,
    /// A typed reply call said that the next control message is the reply (`reply_follows`).
    reply_follows: bool,
    timed_out: bool,
    // Set when the record ends.
    at_ms: u64,
    total: Duration,
    reply: Option<Duration>,
    outcome: &'static str,
}

/// A request in progress. It ends once: when its reply is written, when its
/// handler returns with no reply, or when it is dropped.
pub(crate) struct Scope {
    log: Arc<RequestLog>,
    data: Option<Box<Data>>,
}

impl Scope {
    fn end(&mut self, end: End) {
        let Some(mut data) = self.data.take() else { return };
        let now = Instant::now();
        let open = data.connection.load(Ordering::Acquire);
        let failed = data.error.is_some();
        let verdict = if failed { ("error", true) } else { ("ok", false) };
        let (outcome, always) = match end {
            End::Written => verdict,
            // The reply was queued and never written (every reply text is written by the
            // connection's writer thread or dropped with its queue), or the request was dropped
            // with its closed connection before it ran: the client left.
            End::WriteFailed => ("client_gone", true),
            End::Dropped if data.queued.is_some() || !open => ("client_gone", true),
            End::Dropped => ("not_run", true),
            // The handler had a reply and the connection was closed before it was queued.
            End::Returned if !open && data.reply_follows => ("client_gone", true),
            // The handler returned and sent no typed reply: a reply it built itself is not timed.
            End::Returned if !failed => ("returned", false),
            End::Returned => verdict,
        };
        data.total = now.saturating_duration_since(data.arrived);
        if !always && data.total <= SLOW_REQUEST_THRESHOLD {
            return;
        }
        data.outcome = outcome;
        if matches!(end, End::Written) {
            data.reply = data.queued.map(|queued| now.saturating_duration_since(queued));
        }
        if data.timed_out && data.error.is_some_and(|error| error.as_str() == "error") {
            data.error = Label::token("timed_out");
        }
        let elapsed = u64::try_from(data.total.as_millis()).unwrap_or(u64::MAX);
        data.at_ms = crate::startup_timings::unix_now_ms().saturating_sub(elapsed);
        self.log.submit(Entry::Request(data));
    }
}

impl Drop for Scope {
    fn drop(&mut self) {
        self.end(End::Dropped);
    }
}

thread_local! {
    static CURRENT: RefCell<Option<Scope>> = const { RefCell::new(None) };
}

fn take_current() -> Option<Scope> {
    CURRENT
        .try_with(|current| current.try_borrow_mut().ok().and_then(|mut current| current.take()))
        .ok()
        .flatten()
}

fn with_current(change: impl FnOnce(&mut Data)) {
    let _ = CURRENT.try_with(|current| {
        if let Ok(mut current) = current.try_borrow_mut()
            && let Some(data) = current.as_mut().and_then(|scope| scope.data.as_deref_mut())
        {
            change(data);
        }
    });
}

/// The request this thread handles, until it drops: then a request with no reply ends.
pub(crate) struct ScopeGuard {
    owns: bool,
}

impl Drop for ScopeGuard {
    fn drop(&mut self) {
        if self.owns
            && let Some(mut scope) = take_current()
        {
            scope.end(End::Returned);
        }
    }
}

fn install(scope: Option<Scope>) -> ScopeGuard {
    let Some(scope) = scope else { return ScopeGuard { owns: false } };
    let installed = CURRENT
        .try_with(|current| {
            match current.try_borrow_mut() {
                Ok(mut current) if current.is_none() => {
                    *current = Some(scope);
                    None
                }
                // A frame handled inside another request's handler: the outer request keeps the thread.
                _ => Some(scope),
            }
        })
        .unwrap_or(None);
    match installed {
        None => ScopeGuard { owns: true },
        Some(mut inner) => {
            // Not an end of the request: it has no record.
            inner.data = None;
            ScopeGuard { owns: false }
        }
    }
}

/// A request that waits in a connection's queue, between its reader and its dispatcher.
pub(crate) struct Parked(Scope);

/// Takes this thread's request off the thread, to travel with the queued request.
pub(crate) fn park() -> Option<Parked> {
    take_current().map(Parked)
}

/// Continues a parked request on this thread; its wait in the queue ends now.
pub(crate) fn resume(parked: Option<Parked>) -> ScopeGuard {
    install(parked.map(|Parked(mut scope)| {
        if let Some(data) = scope.data.as_deref_mut() {
            data.started = Instant::now();
        }
        scope
    }))
}

/// A lock wait of this thread's request (`LockStats::acquired`).
pub(crate) fn add_lock_wait(waited: Duration) {
    with_current(|data| data.lock_wait += waited);
}

/// The next control message this thread's request sends to its connection is its reply:
/// `ok`, or an error with `code` (never its message).
pub(crate) fn reply_follows(ok: bool, code: Option<&str>) {
    let error =
        if ok { None } else { code.and_then(Label::token).or_else(|| Label::token("error")) };
    with_current(|data| {
        data.reply_follows = true;
        data.error = error;
    });
}

/// The daemon decoded the line of this thread's request as a known command: its `cmd` is that
/// command's name.
pub(crate) fn decoded_command() {
    with_current(|data| data.name = data.fields.cmd);
}

/// The daemon decoded the line of this thread's request as the operation with this wire name.
pub(crate) fn decoded_operation(wire_name: &'static str) {
    with_current(|data| data.name = Label::token(wire_name));
}

/// Moves the arrival of this thread's request `by` into the past.
#[cfg(test)]
pub(crate) fn backdate(by: Duration) {
    with_current(|data| data.arrived = data.arrived.checked_sub(by).unwrap_or(data.arrived));
}

/// A wait for the registry's journal writer on this thread, until it drops.
pub(crate) struct RegistryWait {
    started: Instant,
    deadline: Instant,
}

pub(crate) fn registry_wait(deadline: Instant) -> RegistryWait {
    RegistryWait { started: Instant::now(), deadline }
}

impl Drop for RegistryWait {
    fn drop(&mut self) {
        let now = Instant::now();
        with_current(|data| {
            data.registry_wait += now.saturating_duration_since(self.started);
            data.timed_out |= now >= self.deadline;
        });
    }
}

/// Travels with a queued reply to the thread that writes the socket.
pub(crate) struct ReplyMark(Mutex<Option<Scope>>);

impl ReplyMark {
    fn end(&self, end: End) {
        let scope = self.0.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(mut scope) = scope {
            scope.end(end);
        }
    }

    /// The reply's bytes went to the socket.
    pub(crate) fn written(&self) {
        self.end(End::Written);
    }

    /// The socket write of the reply failed.
    pub(crate) fn lost(&self) {
        self.end(End::WriteFailed);
    }
}

/// The mark for a control message of `reply_bytes` queued on `connection`: some for the
/// reply of this thread's request (the message after `reply_follows`, on its own connection).
/// An event the handler sends before its reply is not the reply.
pub(crate) fn reply_mark(connection: &Arc<AtomicBool>, reply_bytes: usize) -> Option<ReplyMark> {
    let mut scope = CURRENT
        .try_with(|current| {
            let mut current = current.try_borrow_mut().ok()?;
            let own =
                current.as_ref().and_then(|scope| scope.data.as_deref()).is_some_and(|data| {
                    data.reply_follows && Arc::ptr_eq(&data.connection, connection)
                });
            if own { current.take() } else { None }
        })
        .ok()
        .flatten()?;
    let data = scope.data.as_deref_mut()?;
    data.queued = Some(Instant::now());
    data.reply_bytes = reply_bytes;
    Some(ReplyMark(Mutex::new(Some(scope))))
}

/// What the start line says of the session.
pub(crate) struct StartInfo {
    pub(crate) session_hash: Option<Label>,
    pub(crate) workspaces: usize,
    pub(crate) surfaces: usize,
    pub(crate) clients: usize,
    pub(crate) registry_bytes: u64,
    pub(crate) registry_wal_bytes: u64,
}

enum Entry {
    Request(Box<Data>),
    Lock {
        at_ms: u64,
        lock: &'static str,
        site: &'static Location<'static>,
        thread: Option<Label>,
        request: Option<Label>,
        client: Option<u64>,
        held: Duration,
        waited: Duration,
    },
    Start(u64, StartInfo),
    #[cfg(test)]
    Flush(SyncSender<()>),
}

/// The session's slow request log (see the module documentation).
pub(crate) struct RequestLog {
    sender: SyncSender<Entry>,
    /// Records dropped at a full queue and not yet reported in the file.
    dropped: Arc<AtomicU64>,
    dropped_total: AtomicU64,
    #[cfg(test)]
    written: Arc<AtomicU64>,
    #[cfg(test)]
    gate: Arc<Mutex<()>>,
}

impl RequestLog {
    /// The log of the session whose folder is `directory`; none when its writer cannot start.
    pub(crate) fn open(directory: &Path) -> Option<Arc<Self>> {
        let (sender, receiver) = sync_channel(QUEUE_RECORDS);
        let dropped = Arc::new(AtomicU64::new(0));
        #[cfg(test)]
        let written = Arc::new(AtomicU64::new(0));
        #[cfg(test)]
        let gate = Arc::new(Mutex::new(()));
        let writer = Writer {
            ring: Ring::new(directory),
            dropped: dropped.clone(),
            #[cfg(test)]
            written: written.clone(),
            #[cfg(test)]
            gate: gate.clone(),
        };
        std::thread::Builder::new()
            .name("mux-slow-log".into())
            .spawn(move || writer.run(&receiver))
            .ok()?;
        Some(Arc::new(Self {
            sender,
            dropped,
            dropped_total: AtomicU64::new(0),
            #[cfg(test)]
            written,
            #[cfg(test)]
            gate,
        }))
    }

    /// Hands `entry` to the writer; never waits. A full queue drops it and counts it.
    fn submit(&self, entry: Entry) {
        if let Err(TrySendError::Full(_)) = self.sender.try_send(entry) {
            self.dropped.fetch_add(1, Ordering::Relaxed);
            self.dropped_total.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// Records dropped at a full queue since the start.
    #[cfg(test)]
    pub(crate) fn dropped_total(&self) -> u64 {
        self.dropped_total.load(Ordering::Relaxed)
    }

    /// Waits until the writer handled every record handed to it before this call.
    #[cfg(test)]
    pub(crate) fn settle(&self) {
        let (done, wait) = sync_channel(1);
        if self.sender.send(Entry::Flush(done)).is_ok() {
            let _ = wait.recv();
        }
    }

    /// Stops the writer before its next record, until the guard drops.
    #[cfg(test)]
    pub(crate) fn block_writer(&self) -> std::sync::MutexGuard<'_, ()> {
        self.gate.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Bytes written to the file since the start.
    #[cfg(test)]
    pub(crate) fn bytes_written(&self) -> u64 {
        self.written.load(Ordering::Relaxed)
    }

    /// Starts the record of the request in `line`, which `client` sent on `connection`
    /// (`MessageWriter::open`), on this thread.
    pub(crate) fn begin(
        self: &Arc<Self>,
        client: u64,
        labels: (Option<Label>, Option<Label>),
        connection: &Arc<AtomicBool>,
        line: &str,
    ) -> ScopeGuard {
        let now = Instant::now();
        install(Some(Scope {
            log: self.clone(),
            data: Some(Box::new(Data {
                connection: connection.clone(),
                client,
                client_name: labels.0,
                client_kind: labels.1,
                fields: allowed_fields(line),
                name: None,
                request_bytes: line.len(),
                arrived: now,
                started: now,
                queued: None,
                reply_bytes: 0,
                lock_wait: Duration::ZERO,
                registry_wait: Duration::ZERO,
                error: None,
                reply_follows: false,
                timed_out: false,
                at_ms: 0,
                total: Duration::ZERO,
                reply: None,
                outcome: "ok",
            })),
        }))
    }

    /// A hold of `lock` longer than the stall threshold, released now at `site`.
    pub(crate) fn long_hold(
        &self,
        lock: &'static str,
        site: &'static Location<'static>,
        held: Duration,
        waited: Duration,
    ) {
        let mut request = None;
        let mut client = None;
        with_current(|data| {
            request = data.name;
            client = Some(data.client);
        });
        let held_ms = u64::try_from(held.as_millis()).unwrap_or(u64::MAX);
        self.submit(Entry::Lock {
            at_ms: crate::startup_timings::unix_now_ms().saturating_sub(held_ms),
            lock,
            site,
            thread: std::thread::current().name().and_then(Label::thread),
            request,
            client,
            held,
            waited,
        });
    }

    /// The line of the daemon's start.
    pub(crate) fn started(&self, info: StartInfo) {
        self.submit(Entry::Start(crate::startup_timings::unix_now_ms(), info));
    }
}

/// The two files of the log.
struct Ring {
    path: PathBuf,
    older: PathBuf,
    file: Option<File>,
    bytes: u64,
}

impl Ring {
    fn new(directory: &Path) -> Self {
        Self {
            path: directory.join(FILE_NAME),
            older: directory.join(format!("{FILE_NAME}.1")),
            file: None,
            bytes: 0,
        }
    }

    fn open(&mut self) {
        let mut options = std::fs::OpenOptions::new();
        options.create(true).append(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        self.file = options.open(&self.path).ok();
        self.bytes =
            self.file.as_ref().and_then(|file| file.metadata().ok()).map_or(0, |meta| meta.len());
    }

    /// Appends `line` with one write; returns the bytes written.
    fn append(&mut self, line: &str) -> u64 {
        let length = line.len() as u64;
        if self.file.is_none() {
            self.open();
        }
        if self.bytes.saturating_add(length) > FILE_BYTES {
            self.file = None;
            let _ = std::fs::rename(&self.path, &self.older);
            self.open();
        }
        let Some(file) = self.file.as_mut() else { return 0 };
        if self.bytes.saturating_add(length) > FILE_BYTES {
            // The rename failed (the older name is a folder, the folder is read-only): the file is
            // emptied, and when that fails too the record goes. The file never passes the limit.
            if file.set_len(0).is_err() {
                return 0;
            }
            self.bytes = 0;
        }
        if file.write_all(line.as_bytes()).is_err() {
            self.file = None;
            return 0;
        }
        self.bytes += length;
        length
    }
}

struct Writer {
    ring: Ring,
    dropped: Arc<AtomicU64>,
    #[cfg(test)]
    written: Arc<AtomicU64>,
    #[cfg(test)]
    gate: Arc<Mutex<()>>,
}

impl Writer {
    fn run(mut self, receiver: &Receiver<Entry>) {
        let mut line = String::with_capacity(512);
        while let Ok(entry) = receiver.recv() {
            #[cfg(test)]
            let gate = self.gate.clone();
            #[cfg(test)]
            let _gate = gate.lock().unwrap_or_else(PoisonError::into_inner);
            let dropped = self.dropped.swap(0, Ordering::Relaxed);
            if dropped > 0 {
                line.clear();
                open_line(&mut line, "dropped", crate::startup_timings::unix_now_ms());
                let _ = writeln!(line, ",\"queue_full\":{dropped}}}");
                self.write(&line);
            }
            line.clear();
            match entry {
                Entry::Request(data) => request_line(&mut line, &data),
                Entry::Lock { at_ms, lock, site, thread, request, client, held, waited } => {
                    open_line(&mut line, "lock", at_ms);
                    let holder = format!("{}:{}", site.file(), site.line());
                    let _ = write!(line, ",\"lock\":\"{lock}\",\"holder\":{}", json_text(&holder));
                    push_label(&mut line, "thread", thread);
                    push_label(&mut line, "request", request);
                    if let Some(client) = client {
                        let _ = write!(line, ",\"client\":{client}");
                    }
                    push_ms(&mut line, "held_ms", held);
                    push_ms(&mut line, "wait_ms", waited);
                    line.push_str("}\n");
                }
                Entry::Start(at_ms, info) => {
                    open_line(&mut line, "start", at_ms);
                    let _ = write!(
                        line,
                        ",\"pid\":{},\"version\":{}",
                        std::process::id(),
                        json_text(crate::release::distribution_version())
                    );
                    push_label(&mut line, "session_hash", info.session_hash);
                    let _ = writeln!(
                        line,
                        ",\"workspaces\":{},\"surfaces\":{},\"clients\":{},\"registry_bytes\":{},\
                         \"registry_wal_bytes\":{},\"slow_ms\":{},\"file_bytes\":{FILE_BYTES}}}",
                        info.workspaces,
                        info.surfaces,
                        info.clients,
                        info.registry_bytes,
                        info.registry_wal_bytes,
                        SLOW_REQUEST_THRESHOLD.as_millis(),
                    );
                }
                #[cfg(test)]
                Entry::Flush(done) => {
                    let _ = done.send(());
                    continue;
                }
            }
            self.write(&line);
        }
    }

    fn write(&mut self, line: &str) {
        let _bytes = self.ring.append(line);
        #[cfg(test)]
        self.written.fetch_add(_bytes, Ordering::Relaxed);
    }
}

fn json_text(text: &str) -> String {
    serde_json::to_string(text).unwrap_or_else(|_| "\"\"".into())
}

fn open_line(line: &mut String, kind: &str, at_ms: u64) {
    let at = cmux_conversation::format_rfc3339_millis(at_ms);
    let _ =
        write!(line, "{{\"kind\":\"{kind}\",\"side\":\"daemon\",\"at\":\"{at}\",\"at_ms\":{at_ms}");
}

fn push_ms(line: &mut String, key: &str, value: Duration) {
    let _ = write!(line, ",\"{key}\":{:.1}", value.as_secs_f64() * 1000.0);
}

/// A label needs no escape: its grammar has no quote and no backslash.
fn push_label(line: &mut String, key: &str, label: Option<Label>) {
    if let Some(label) = label {
        let _ = write!(line, ",\"{key}\":\"{}\"", label.as_str());
    }
}

fn request_line(line: &mut String, data: &Data) {
    open_line(line, "request", data.at_ms);
    let name = data.name.as_ref().map_or("other", Label::as_str);
    let _ = write!(line, ",\"name\":\"{name}\",\"client\":{}", data.client);
    push_label(line, "client_name", data.client_name);
    push_label(line, "client_kind", data.client_kind);
    for (key, id) in ID_KEYS.iter().zip(data.fields.ids) {
        match id {
            Some(id) if id.is_number() => {
                let _ = write!(line, ",\"{key}\":{}", id.as_str());
            }
            id => push_label(line, key, id),
        }
    }
    let _ = write!(line, ",\"request_bytes\":{}", data.request_bytes);
    push_ms(line, "total_ms", data.total);
    push_ms(line, "queue_ms", data.started.saturating_duration_since(data.arrived));
    let handled = data.queued.unwrap_or(data.arrived + data.total);
    push_ms(line, "handler_ms", handled.saturating_duration_since(data.started));
    push_ms(line, "lock_wait_ms", data.lock_wait);
    push_ms(line, "registry_wait_ms", data.registry_wait);
    if let Some(reply) = data.reply {
        push_ms(line, "reply_ms", reply);
    }
    if data.queued.is_some() {
        let _ = write!(line, ",\"reply_bytes\":{}", data.reply_bytes);
    }
    let _ = write!(line, ",\"outcome\":\"{}\"", data.outcome);
    push_label(line, "error", data.error);
    line.push_str("}\n");
}
