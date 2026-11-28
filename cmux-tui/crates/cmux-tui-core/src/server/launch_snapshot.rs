//! The launch snapshot (`launch-snapshot-v1`): a small read-only file with
//! the last settled tree (`list-workspaces`), the personal state
//! (`list-personal`) and the native frontend projections, next to the session registry, so a frontend can draw the
//! last known layout before it connects and then swap to live state. The
//! daemon never reads it back: it is a cache of the registry and the live
//! tree, never a second source of truth.
//!
//! The writer is event-driven. It sleeps on the event bus until the tree,
//! the layout, the personal state or a projection changes (a title change alone does not wake
//! it; titles are those of the last write), then writes once changes settle
//! (`settle` after the last one, `max_delay` after the first at the latest):
//! one computed deadline per burst and no timer while idle. Each write goes
//! to a temporary file that is renamed over the old one, owner-only.
//!
//! Each write is the whole file, so the writer has a byte budget
//! (`max_bytes_per_second`): after a write it waits in proportion to the
//! bytes it wrote, and a clean stop writes what that wait held back. A
//! session whose snapshot is megabytes and whose tabs change state every few
//! seconds then costs a bounded number of bytes an hour, not one whole file
//! per change.
//!
//! Two things write the file at once, with no settle, delay or byte-budget
//! wait: the close of a connection that wrote a native frontend projection
//! (the app quit, was force quit, crashed or was killed), and an explicit
//! `flush-launch-snapshot` (`launch-snapshot-flush-v1`). The writer wakes and
//! writes on that pass, so a quick relaunch on the same daemon draws the
//! window records the app saved last, not the write before them. Everything
//! else keeps the timing above.

use crate::panic_free::RecoverPoison;
use std::sync::Condvar;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::RecvTimeoutError;
use std::thread::JoinHandle;

use super::*;
use crate::MuxEventReceiver;

pub(crate) use crate::server_protocol::LAUNCH_SNAPSHOT_FILE;
const LAUNCH_SNAPSHOT_SCHEMA_VERSION: u32 = 1;
pub(crate) use crate::server_protocol::MAX_LAUNCH_SNAPSHOT_BYTES;
/// Failed writes back off (a full disk must not turn into a write loop).
const WRITE_RETRY_INITIAL: Duration = Duration::from_secs(1);
const WRITE_RETRY_MAX: Duration = Duration::from_secs(60);
/// How long `flush-launch-snapshot` waits for its write before it answers
/// `flushed:false` (the write still happens; a quit does not wait for it).
pub(crate) const LAUNCH_SNAPSHOT_FLUSH_WAIT: Duration = Duration::from_secs(1);

/// Requests for an immediate write (`flush-launch-snapshot`) and their
/// answers. The Mux holds it while the writer runs.
pub(crate) struct LaunchSnapshotFlush {
    /// The writer's events, to wake it (replaced in place when it resubscribes).
    events: Arc<Mutex<MuxEventReceiver>>,
    state: Mutex<FlushState>,
    answered: Condvar,
}

#[derive(Default)]
struct FlushState {
    /// The newest request, and the newest one a write pass answered.
    requested: u64,
    answered: u64,
    /// Whether that pass left the file holding the current snapshot.
    current: bool,
    /// The writer stopped: nothing answers a later request.
    stopped: bool,
    /// Open connections that wrote a native frontend projection.
    writers: HashSet<u64>,
}

impl LaunchSnapshotFlush {
    fn new(events: Arc<Mutex<MuxEventReceiver>>) -> Self {
        Self { events, state: Mutex::new(FlushState::default()), answered: Condvar::new() }
    }

    /// Asks the writer to write now and waits up to `wait` for it. True once
    /// the file holds the snapshot as of this request (written now, or
    /// already the same); false when the write failed, the writer stopped or
    /// `wait` passed.
    pub(crate) fn flush(&self, wait: Duration) -> bool {
        let Some(ticket) = self.request() else { return false };
        let deadline = Instant::now() + wait;
        let mut state = self.state.lock().recover_poison();
        while state.answered < ticket && !state.stopped {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return false;
            };
            state = self.answered.wait_timeout(state, remaining).recover_poison().0;
        }
        state.answered >= ticket && state.current
    }

    /// Asks for an immediate write and wakes the writer; its ticket, or None
    /// once the writer stopped.
    fn request(&self) -> Option<u64> {
        let ticket = {
            let mut state = self.state.lock().recover_poison();
            if state.stopped {
                return None;
            }
            state.requested += 1;
            state.requested
        };
        self.events.lock().recover_poison().wake();
        Some(ticket)
    }

    /// `client` wrote a native frontend projection (`put-frontend-projection`):
    /// it is the frontend whose window records the snapshot carries.
    pub(crate) fn projection_writer(&self, client: u64) {
        self.state.lock().recover_poison().writers.insert(client);
    }

    /// A connection closed. When it wrote a native frontend projection (the
    /// app quit, was force quit, crashed or was killed: each closes its
    /// socket), the writer writes at once, as on `flush-launch-snapshot`,
    /// so a relaunch draws the records it saved last. Nothing waits for it.
    pub(crate) fn client_left(&self, client: u64) {
        let wrote = self.state.lock().recover_poison().writers.remove(&client);
        if wrote {
            let _ = self.request();
        }
    }

    /// The newest unanswered request, if any.
    fn pending(&self) -> Option<u64> {
        let state = self.state.lock().recover_poison();
        (state.requested > state.answered).then_some(state.requested)
    }

    fn answer(&self, ticket: u64, current: bool) {
        let mut state = self.state.lock().recover_poison();
        state.answered = state.answered.max(ticket);
        state.current = current;
        self.answered.notify_all();
    }

    fn stop(&self) {
        self.state.lock().recover_poison().stopped = true;
        self.answered.notify_all();
    }
}

/// When the writer writes after a change.
#[derive(Debug, Clone, Copy)]
pub struct LaunchSnapshotTiming {
    /// Quiet time after the last change.
    pub settle: Duration,
    /// Longest wait after the first unwritten change, so a terminal whose
    /// title changes all the time still gets its layout written.
    pub max_delay: Duration,
    /// The most bytes a second the writer writes, on average: after a write
    /// of `n` bytes the next one waits `n / max_bytes_per_second` seconds.
    /// A small session keeps its snapshot seconds fresh; a session whose
    /// snapshot is megabytes rewrites it every few minutes, not on every
    /// change. A clean stop writes what the wait held back.
    pub max_bytes_per_second: u64,
}

impl Default for LaunchSnapshotTiming {
    fn default() -> Self {
        Self {
            settle: Duration::from_millis(500),
            max_delay: Duration::from_secs(3),
            // 56 MiB an hour at most; a 50 KB snapshot still follows a change in 3 s.
            max_bytes_per_second: 16 * 1024,
        }
    }
}

/// The writer thread. Dropping it stops the thread and clears the path from
/// `identify`.
pub struct LaunchSnapshotWriter {
    path: PathBuf,
    stop: Arc<AtomicBool>,
    events: Arc<Mutex<MuxEventReceiver>>,
    writes: Arc<AtomicU64>,
    bytes: Arc<AtomicU64>,
    mux: Weak<Mux>,
    flush: Arc<LaunchSnapshotFlush>,
    thread: Option<JoinHandle<()>>,
}

impl LaunchSnapshotWriter {
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Completed writes, for tests and diagnostics.
    pub fn writes(&self) -> u64 {
        self.writes.load(Ordering::Acquire)
    }

    /// Bytes written to the file so far (a wakeup that changes nothing writes none).
    pub fn bytes_written(&self) -> u64 {
        self.bytes.load(Ordering::Acquire)
    }

    /// Stop the thread and wait for it.
    pub fn stop(mut self) {
        self.signal_stop();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }

    fn signal_stop(&self) {
        self.stop.store(true, Ordering::Release);
        self.events.lock().recover_poison().close();
        self.flush.stop();
        if let Some(mux) = self.mux.upgrade() {
            mux.set_launch_snapshot_path(None);
            mux.set_launch_snapshot_flush(None);
        }
    }
}

impl Drop for LaunchSnapshotWriter {
    fn drop(&mut self) {
        self.signal_stop();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Start the writer with the default timing. None for a session without a
/// durable registry (nothing to relaunch into).
pub fn start_launch_snapshot_writer(
    mux: &Arc<Mux>,
) -> std::io::Result<Option<LaunchSnapshotWriter>> {
    start_launch_snapshot_writer_with(mux, LaunchSnapshotTiming::default())
}

pub fn start_launch_snapshot_writer_with(
    mux: &Arc<Mux>,
    timing: LaunchSnapshotTiming,
) -> std::io::Result<Option<LaunchSnapshotWriter>> {
    let Some(directory) = mux.session_state_directory() else { return Ok(None) };
    let path = directory.join(LAUNCH_SNAPSHOT_FILE);
    let stop = Arc::new(AtomicBool::new(false));
    let writes = Arc::new(AtomicU64::new(0));
    let bytes = Arc::new(AtomicU64::new(0));
    let events = Arc::new(Mutex::new(mux.subscribe_launch_snapshot()));
    let weak = Arc::downgrade(mux);
    let thread_path = path.clone();
    let thread_stop = stop.clone();
    let thread_writes = writes.clone();
    let thread_bytes = bytes.clone();
    let shared_events = events.clone();
    let mut thread_events = events.lock().recover_poison().clone();
    let flush = Arc::new(LaunchSnapshotFlush::new(events.clone()));
    let thread_flush = flush.clone();
    let thread =
        std::thread::Builder::new().name("mux-launch-snapshot".into()).spawn(move || {
            // Write once at start, so a relaunch finds the current layout even
            // if nothing changes while this daemon runs.
            let mut dirty_since = Some(Instant::now());
            let mut last_change =
                Instant::now().checked_sub(timing.settle).unwrap_or_else(Instant::now);
            let mut retry = WRITE_RETRY_INITIAL;
            let mut retry_at: Option<Instant> = None;
            // The earliest next write: the last write's size over the byte budget.
            let mut budget_at: Option<Instant> = None;
            // The projections the last written snapshot left out (reported when it changes).
            let mut last_dropped: Vec<String> = Vec::new();
            loop {
                if thread_stop.load(Ordering::Acquire) {
                    break;
                }
                // A flush request writes on this pass: what is queued is in
                // the snapshot it computes, and no settle, delay, retry or
                // byte-budget wait holds it back.
                let urgent = thread_flush.pending();
                if urgent.is_some() {
                    while thread_events.try_recv().is_ok() {}
                    dirty_since.get_or_insert_with(Instant::now);
                }
                let now = Instant::now();
                let due = dirty_since.map(|first| {
                    let settled = last_change + timing.settle;
                    let latest = first + timing.max_delay;
                    let due = settled.min(latest);
                    let due = retry_at.map_or(due, |retry_at| due.max(retry_at));
                    budget_at.map_or(due, |budget_at| due.max(budget_at))
                });
                if urgent.is_some() || due.is_some_and(|due| now >= due) {
                    let Some(mux) = weak.upgrade() else { break };
                    let result = write_launch_snapshot(&mux, &thread_path);
                    if let Some(ticket) = urgent {
                        thread_flush.answer(ticket, result.is_ok());
                    }
                    match result {
                        Ok((dropped, written)) => {
                            if written > 0 {
                                budget_at = Some(
                                    Instant::now()
                                        + budget_wait(written, timing.max_bytes_per_second),
                                );
                            }
                            thread_bytes.fetch_add(written as u64, Ordering::AcqRel);
                            if dropped != last_dropped {
                                report_dropped_projections(&mux, &dropped);
                                last_dropped = dropped;
                            }
                            thread_writes.fetch_add(1, Ordering::AcqRel);
                            dirty_since = None;
                            retry = WRITE_RETRY_INITIAL;
                            retry_at = None;
                        }
                        Err(error) => {
                            mux.report_internal_diagnostic("launch snapshot not written");
                            eprintln!("cmux-tui: launch snapshot not written: {error:#}");
                            retry_at = Some(Instant::now() + retry);
                            retry = (retry * 2).min(WRITE_RETRY_MAX);
                        }
                    }
                    drop(mux);
                    continue;
                }
                let event = match due {
                    Some(due) => thread_events.recv_timeout(due.saturating_duration_since(now)),
                    None => thread_events.recv().map_err(|_| RecvTimeoutError::Disconnected),
                };
                match event {
                    Ok(_) => {
                        // Coalesce everything already queued into this change.
                        while thread_events.try_recv().is_ok() {}
                        last_change = Instant::now();
                        dirty_since.get_or_insert(last_change);
                    }
                    Err(RecvTimeoutError::Timeout) => {}
                    Err(RecvTimeoutError::Disconnected) => {
                        if thread_stop.load(Ordering::Acquire) {
                            break;
                        }
                        // The mailbox overflowed: resubscribe and write again.
                        let Some(mux) = weak.upgrade() else { break };
                        thread_events = mux.subscribe_launch_snapshot();
                        *shared_events.lock().recover_poison() = thread_events.clone();
                        last_change = Instant::now();
                        dirty_since.get_or_insert(last_change);
                    }
                }
            }
            // A clean stop writes what the byte budget still held back, so a
            // relaunch draws the last layout. Not when the file is gone (a
            // stop that ends the session removed it).
            if dirty_since.is_some()
                && thread_path.exists()
                && let Some(mux) = weak.upgrade()
                && let Ok((_, written)) = write_launch_snapshot(&mux, &thread_path)
            {
                thread_bytes.fetch_add(written as u64, Ordering::AcqRel);
                thread_writes.fetch_add(1, Ordering::AcqRel);
            }
            thread_flush.stop();
        })?;
    mux.set_launch_snapshot_path(Some(path.clone()));
    mux.set_launch_snapshot_flush(Some(flush.clone()));
    Ok(Some(LaunchSnapshotWriter {
        path,
        stop,
        events,
        writes,
        bytes,
        mux: Arc::downgrade(mux),
        flush,
        thread: Some(thread),
    }))
}

/// `flush-launch-snapshot`: writes the launch snapshot now and answers once it
/// landed (`flushed:true`), or after [`LAUNCH_SNAPSHOT_FLUSH_WAIT`], or at
/// once without a writer (`flushed:false`).
pub(super) fn flush_command(mux: &Mux) -> anyhow::Result<Value> {
    Ok(json!({"flushed": mux.flush_launch_snapshot(LAUNCH_SNAPSHOT_FLUSH_WAIT)}))
}

/// How long the writer waits after it wrote `written` bytes.
fn budget_wait(written: usize, max_bytes_per_second: u64) -> Duration {
    Duration::from_secs_f64(written as f64 / max_bytes_per_second.max(1) as f64)
}

/// What the snapshot holds, read once a write. It is serialized straight from
/// these parts, never through a whole-file `serde_json::Value` (at 1,000 items
/// that tree of values, and the two parses that compared it with the file,
/// were tens of MB of transient heap the allocator kept: goal infinite-items-flat).
struct LaunchSnapshotParts {
    registry_id: String,
    generation: String,
    tree: Value,
    personal: Option<crate::workspace_registry::PersonalSnapshot>,
    projections: Vec<crate::workspace_registry::FrontendProjection>,
    sidebar_doc: Value,
}

fn launch_snapshot_parts(
    mux: &Mux,
    include_projections: bool,
) -> anyhow::Result<LaunchSnapshotParts> {
    let tree = list_workspaces_reply(mux)?;
    let (registry_id, generation) = mux.registry_identity();
    let personal = match mux.personal_snapshot() {
        Ok(personal) => Some(personal),
        Err(error) => {
            eprintln!("cmux-tui: launch snapshot without personal state: {error:#}");
            None
        }
    };
    let projections =
        if include_projections { mux.launch_snapshot_frontend_projections()? } else { Vec::new() };
    // The sidebar document (`sidebar.get`'s reply): its Pinned band draws in
    // the app's first frame, not after this daemon's restore and handshake
    // (seconds on a large registry). A pin bumps `personal_revision`, so a
    // pin change rewrites the snapshot. Left out of the smaller retry.
    let sidebar_doc = if include_projections { launch_sidebar_doc(mux) } else { Value::Null };
    Ok(LaunchSnapshotParts { registry_id, generation, tree, personal, projections, sidebar_doc })
}

/// A native projection as the file holds it: its keys in the sorted order a
/// `serde_json::Value` object gives them, so the bytes are those of the
/// `Value` form the file had before.
#[derive(Serialize)]
struct SortedProjection<'a> {
    frontend: &'a str,
    projection: &'a Value,
    projection_revision: u64,
    schema_version: u32,
    scope: &'a str,
    subject_key: &'a str,
}

impl<'a> From<&'a crate::workspace_registry::FrontendProjection> for SortedProjection<'a> {
    fn from(projection: &'a crate::workspace_registry::FrontendProjection) -> Self {
        Self {
            frontend: &projection.frontend,
            projection: &projection.projection,
            projection_revision: projection.projection_revision,
            schema_version: projection.schema_version,
            scope: &projection.scope,
            subject_key: &projection.subject_key,
        }
    }
}

/// The key that ends the file: everything before its value is the snapshot's
/// contents, and a write that would change only it is skipped.
const WRITTEN_AT_KEY: &[u8] = b"\"written_at_ms\":";

fn write_key(out: &mut Vec<u8>, first: bool, key: &str) -> anyhow::Result<()> {
    if !first {
        out.push(b',');
    }
    serde_json::to_writer(&mut *out, key)?;
    out.push(b':');
    Ok(())
}

/// One array, an element at a time: each element goes through a `Value`
/// (sorted keys, and `fixup` drops what the file leaves out), never the
/// whole array at once.
fn write_sorted_array<T: Serialize>(
    out: &mut Vec<u8>,
    items: &[T],
    fixup: impl Fn(&mut Value),
) -> anyhow::Result<()> {
    out.push(b'[');
    for (index, item) in items.iter().enumerate() {
        if index > 0 {
            out.push(b',');
        }
        let mut value = serde_json::to_value(item)?;
        fixup(&mut value);
        serde_json::to_writer(&mut *out, &value)?;
    }
    out.push(b']');
    Ok(())
}

/// `list-personal`'s reply as the file holds it. Rooms, pins and personal
/// groups filter and group the sidebar, so a provisional sidebar drawn
/// without them regroups when live data lands. Room default env can hold
/// credentials; the sidebar does not need it. A session's capability list
/// (up to `MAX_SESSION_CAPABILITIES_BYTES` each) is not drawn either, and
/// the file has its own size bound. Keys sorted, as the `Value` form had them.
fn write_personal(
    out: &mut Vec<u8>,
    personal: &crate::workspace_registry::PersonalSnapshot,
) -> anyhow::Result<()> {
    let keep = |_: &mut Value| {};
    out.push(b'{');
    write_key(out, true, "browser_profiles")?;
    write_sorted_array(out, &personal.browser_profiles, keep)?;
    write_key(out, false, "groups")?;
    write_sorted_array(out, &personal.groups, keep)?;
    write_key(out, false, "personal_revision")?;
    serde_json::to_writer(&mut *out, &personal.personal_revision)?;
    write_key(out, false, "pins")?;
    write_sorted_array(out, &personal.pins, keep)?;
    write_key(out, false, "profiles")?;
    write_sorted_array(out, &personal.profiles, |profile| {
        if let Some(defaults) = profile.get_mut("defaults").and_then(Value::as_object_mut) {
            defaults.remove("env");
        }
    })?;
    write_key(out, false, "sessions")?;
    write_sorted_array(out, &personal.sessions, |session| {
        if let Some(session) = session.as_object_mut() {
            session.remove("capabilities");
        }
    })?;
    write_key(out, false, "terminals")?;
    write_sorted_array(out, &personal.terminals, keep)?;
    write_key(out, false, "workspaces")?;
    write_sorted_array(out, &personal.workspaces, keep)?;
    out.push(b'}');
    Ok(())
}

/// The file's bytes up to and including [`WRITTEN_AT_KEY`], keys in sorted
/// order (`written_at_ms` last), the projections whose `keep` is true. The
/// same bytes the `serde_json::Value` form serialized to, built without it.
fn launch_snapshot_body(
    mux: &Mux,
    parts: &LaunchSnapshotParts,
    keep: &[bool],
) -> anyhow::Result<Vec<u8>> {
    let mut out = Vec::new();
    out.push(b'{');
    write_key(&mut out, true, "app")?;
    serde_json::to_writer(&mut out, "cmux-tui")?;
    write_key(&mut out, false, "frontend_projections")?;
    out.push(b'[');
    let mut first = true;
    for (projection, _) in parts.projections.iter().zip(keep).filter(|(_, keep)| **keep) {
        if !first {
            out.push(b',');
        }
        first = false;
        serde_json::to_writer(&mut out, &SortedProjection::from(projection))?;
    }
    out.push(b']');
    write_key(&mut out, false, "generation")?;
    serde_json::to_writer(&mut out, &parts.generation)?;
    write_key(&mut out, false, "personal")?;
    match &parts.personal {
        Some(personal) => write_personal(&mut out, personal)?,
        None => out.extend_from_slice(b"null"),
    }
    write_key(&mut out, false, "registry_id")?;
    serde_json::to_writer(&mut out, &parts.registry_id)?;
    write_key(&mut out, false, "schema_version")?;
    serde_json::to_writer(&mut out, &LAUNCH_SNAPSHOT_SCHEMA_VERSION)?;
    write_key(&mut out, false, "session")?;
    serde_json::to_writer(&mut out, &mux.session)?;
    write_key(&mut out, false, "sidebar_doc")?;
    serde_json::to_writer(&mut out, &parts.sidebar_doc)?;
    write_key(&mut out, false, "tree")?;
    serde_json::to_writer(&mut out, &parts.tree)?;
    write_key(&mut out, false, "version")?;
    serde_json::to_writer(&mut out, env!("CARGO_PKG_VERSION"))?;
    out.push(b',');
    out.extend_from_slice(WRITTEN_AT_KEY);
    Ok(out)
}

/// The write time and the closing brace that end the file after its body.
fn launch_snapshot_tail() -> Vec<u8> {
    let written_at_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or_default();
    format!("{written_at_ms}}}").into_bytes()
}

/// The sidebar document, or null before its migration or on a read error
/// (the snapshot is a cache: the app then waits for `sidebar.get`).
fn launch_sidebar_doc(mux: &Mux) -> Value {
    let read = mux.personal_state_read(|connection| {
        if !crate::state::sidebar_doc_store::is_migrated(connection)? {
            return Ok(Value::Null);
        }
        crate::state::sidebar_doc_store::snapshot(connection)
    });
    match read {
        Ok(value) => value,
        Err(error) => {
            eprintln!("cmux-tui: launch snapshot without the sidebar document: {error:?}");
            Value::Null
        }
    }
}

/// Whether the file at `path` holds `body` (a [`launch_snapshot_body`]),
/// apart from the `written_at_ms` that ends it: a byte compare, streamed
/// from the file, with no parse of either side.
fn same_snapshot_on_disk(path: &Path, body: &[u8]) -> bool {
    let Ok(file) = std::fs::File::open(path) else { return false };
    let mut reader = BufReader::with_capacity(64 * 1024, file);
    let mut offset = 0;
    while offset < body.len() {
        let chunk = match reader.fill_buf() {
            Ok([]) | Err(_) => return false,
            Ok(chunk) => chunk,
        };
        let take = chunk.len().min(body.len() - offset);
        if chunk[..take] != body[offset..offset + take] {
            return false;
        }
        offset += take;
        reader.consume(take);
    }
    // What is left is the write time and the closing brace.
    let mut tail = Vec::new();
    if reader.take(24).read_to_end(&mut tail).is_err() {
        return false;
    }
    matches!(tail.split_last(), Some((b'}', digits))
        if !digits.is_empty() && digits.iter().all(u8::is_ascii_digit))
}

/// Writes the snapshot; returns the projections left out to fit its bound
/// (`frontend/scope/subject`), empty when all fit, and the bytes written
/// (0 when the file already holds this snapshot).
fn write_launch_snapshot(mux: &Mux, path: &Path) -> anyhow::Result<(Vec<String>, usize)> {
    let parts = launch_snapshot_parts(mux, true)?;
    let tail = launch_snapshot_tail();
    let mut keep = vec![true; parts.projections.len()];
    let mut body = launch_snapshot_body(mux, &parts, &keep)?;
    let finished = |body: &[u8]| body.len() + tail.len();
    let mut dropped = Vec::new();
    if finished(&body) > MAX_LAUNCH_SNAPSHOT_BYTES {
        dropped = drop_largest_projections(&parts.projections, &mut keep, finished(&body));
        body = launch_snapshot_body(mux, &parts, &keep)?;
    }
    drop(parts);
    if finished(&body) > MAX_LAUNCH_SNAPSHOT_BYTES {
        // The tree and personal state alone: the smaller form, as before.
        drop(body);
        body = launch_snapshot_body(mux, &launch_snapshot_parts(mux, false)?, &[])?;
        dropped.push("sidebar_doc".to_string());
    }
    anyhow::ensure!(
        finished(&body) <= MAX_LAUNCH_SNAPSHOT_BYTES,
        "launch snapshot exceeds {MAX_LAUNCH_SNAPSHOT_BYTES} bytes"
    );
    // Most wakeups change nothing the snapshot holds: the same contents (its write time aside)
    // are not written and synced again.
    if same_snapshot_on_disk(path, &body) {
        return Ok((dropped, 0));
    }
    let mut bytes = body;
    bytes.extend_from_slice(&tail);
    let directory = path.parent().context("launch snapshot path has no directory")?;
    let temporary = directory.join(format!("{LAUNCH_SNAPSHOT_FILE}.{}.tmp", std::process::id()));
    let result = (|| -> anyhow::Result<()> {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_data()?;
        drop(file);
        std::fs::rename(&temporary, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result.map(|()| (dropped, bytes.len()))
}

/// Counts what a serializer writes, keeping none of it.
#[derive(Default)]
struct ByteCount(usize);

impl Write for ByteCount {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0 += bytes.len();
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Clears `keep` for native projections, largest first, until a snapshot of
/// `bytes` fits [`MAX_LAUNCH_SNAPSHOT_BYTES`]; returns their names, last
/// index first. The registry keeps them: the app reads them after it
/// connects.
fn drop_largest_projections(
    projections: &[crate::workspace_registry::FrontendProjection],
    keep: &mut [bool],
    mut bytes: usize,
) -> Vec<String> {
    let mut sized: Vec<(usize, usize)> = projections
        .iter()
        .enumerate()
        .map(|(index, projection)| {
            let mut count = ByteCount::default();
            let size = serde_json::to_writer(&mut count, &SortedProjection::from(projection))
                .map_or(0, |()| count.0);
            (size, index)
        })
        .collect();
    sized.sort_unstable_by(|a, b| b.cmp(a));
    let mut removed = Vec::new();
    for (size, index) in sized {
        if bytes <= MAX_LAUNCH_SNAPSHOT_BYTES {
            break;
        }
        bytes = bytes.saturating_sub(size + 1);
        keep[index] = false;
        removed.push(index);
    }
    removed.sort_unstable_by(|a, b| b.cmp(a));
    removed
        .into_iter()
        .map(|index| {
            let projection = &projections[index];
            format!("{}/{}/{}", projection.frontend, projection.scope, projection.subject_key)
        })
        .collect()
}

/// Logs and reports the projections the launch snapshot left out: the app's
/// first frame draws without them (the registry keeps them).
fn report_dropped_projections(mux: &Mux, dropped: &[String]) {
    if dropped.is_empty() {
        return;
    }
    let message = format!(
        "launch snapshot over {MAX_LAUNCH_SNAPSHOT_BYTES} bytes: left out {}",
        dropped.join(", ")
    );
    eprintln!("cmux-tui: {message}");
    mux.report_internal_diagnostic(message);
}

#[cfg(test)]
#[path = "launch_snapshot_size_tests.rs"]
mod size_tests;

#[cfg(test)]
#[path = "launch_snapshot_budget_tests.rs"]
mod budget_tests;

#[cfg(test)]
#[path = "launch_snapshot_tests.rs"]
mod tests;
