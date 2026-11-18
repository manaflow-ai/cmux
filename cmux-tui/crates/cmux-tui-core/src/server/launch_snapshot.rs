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

/// The file name inside the session's state directory.
pub const LAUNCH_SNAPSHOT_FILE: &str = "launch-snapshot.json";
const LAUNCH_SNAPSHOT_SCHEMA_VERSION: u32 = 1;
/// A snapshot larger than this drops its projections, then is not written.
/// The app reads the file before it connects (`LaunchSnapshot.maximumBytes`).
pub(crate) const MAX_LAUNCH_SNAPSHOT_BYTES: usize = 8 * 1024 * 1024;
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

fn launch_snapshot_value(mux: &Mux, include_projections: bool) -> anyhow::Result<Value> {
    let tree = list_workspaces_reply(mux)?;
    let (registry_id, generation) = mux.registry_identity();
    // Rooms, pins and personal groups filter and group the sidebar, so a
    // provisional sidebar drawn without them regroups when live data lands.
    // Room default env can hold credentials; the sidebar does not need it.
    // A session's capability list (up to `MAX_SESSION_CAPABILITIES_BYTES`
    // each) is not drawn either, and the file has its own size bound.
    let personal = match mux.personal_snapshot() {
        Ok(personal) => {
            let mut personal = serde_json::to_value(personal)?;
            for profile in
                personal.get_mut("profiles").and_then(Value::as_array_mut).into_iter().flatten()
            {
                if let Some(defaults) = profile.get_mut("defaults").and_then(Value::as_object_mut) {
                    defaults.remove("env");
                }
            }
            for session in
                personal.get_mut("sessions").and_then(Value::as_array_mut).into_iter().flatten()
            {
                if let Some(session) = session.as_object_mut() {
                    session.remove("capabilities");
                }
            }
            personal
        }
        Err(error) => {
            eprintln!("cmux-tui: launch snapshot without personal state: {error:#}");
            Value::Null
        }
    };
    let projections = if include_projections {
        serde_json::to_value(mux.launch_snapshot_frontend_projections()?)?
    } else {
        json!([])
    };
    // The sidebar document (`sidebar.get`'s reply): its Pinned band draws in
    // the app's first frame, not after this daemon's restore and handshake
    // (seconds on a large registry). A pin bumps `personal_revision`, so a
    // pin change rewrites the snapshot. Left out of the smaller retry.
    let sidebar_doc = if include_projections { launch_sidebar_doc(mux) } else { Value::Null };
    Ok(json!({
        "schema_version": LAUNCH_SNAPSHOT_SCHEMA_VERSION,
        "app": "cmux-tui",
        "version": env!("CARGO_PKG_VERSION"),
        "session": mux.session,
        "registry_id": registry_id,
        "generation": generation,
        "written_at_ms": std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
            .unwrap_or_default(),
        "tree": tree,
        "personal": personal,
        "frontend_projections": projections,
        "sidebar_doc": sidebar_doc,
    }))
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

/// Whether the snapshot at `path` holds what `bytes` holds, apart from `written_at_ms`.
fn same_snapshot_on_disk(path: &Path, bytes: &[u8]) -> bool {
    let parse = |bytes: &[u8]| {
        serde_json::from_slice::<Value>(bytes).ok().map(|mut value| {
            if let Some(object) = value.as_object_mut() {
                object.remove("written_at_ms");
            }
            value
        })
    };
    let Ok(stored) = std::fs::read(path) else { return false };
    matches!((parse(&stored), parse(bytes)), (Some(stored), Some(next)) if stored == next)
}

/// Writes the snapshot; returns the projections left out to fit its bound
/// (`frontend/scope/subject`), empty when all fit, and the bytes written
/// (0 when the file already holds this snapshot).
fn write_launch_snapshot(mux: &Mux, path: &Path) -> anyhow::Result<(Vec<String>, usize)> {
    let mut value = launch_snapshot_value(mux, true)?;
    let mut bytes = serde_json::to_vec(&value)?;
    let mut dropped = Vec::new();
    if bytes.len() > MAX_LAUNCH_SNAPSHOT_BYTES {
        dropped = drop_largest_projections(&mut value, bytes.len());
        bytes = serde_json::to_vec(&value)?;
    }
    if bytes.len() > MAX_LAUNCH_SNAPSHOT_BYTES {
        // The tree and personal state alone: the smaller form, as before.
        bytes = serde_json::to_vec(&launch_snapshot_value(mux, false)?)?;
        dropped.push("sidebar_doc".to_string());
    }
    anyhow::ensure!(
        bytes.len() <= MAX_LAUNCH_SNAPSHOT_BYTES,
        "launch snapshot exceeds {MAX_LAUNCH_SNAPSHOT_BYTES} bytes"
    );
    // Most wakeups change nothing the snapshot holds: the same contents (its write time aside)
    // are not written and synced again.
    if same_snapshot_on_disk(path, &bytes) {
        return Ok((dropped, 0));
    }
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

/// Removes native projections from `value`, largest first, until the
/// snapshot fits [`MAX_LAUNCH_SNAPSHOT_BYTES`]; returns their names. The
/// registry keeps them: the app reads them after it connects.
fn drop_largest_projections(value: &mut Value, mut bytes: usize) -> Vec<String> {
    let Some(projections) = value.get_mut("frontend_projections").and_then(Value::as_array_mut)
    else {
        return Vec::new();
    };
    let mut sized: Vec<(usize, usize)> = projections
        .iter()
        .enumerate()
        .map(|(index, projection)| (serde_json::to_vec(projection).map_or(0, |b| b.len()), index))
        .collect();
    sized.sort_unstable_by(|a, b| b.cmp(a));
    let mut removed = Vec::new();
    for (size, index) in sized {
        if bytes <= MAX_LAUNCH_SNAPSHOT_BYTES {
            break;
        }
        bytes = bytes.saturating_sub(size + 1);
        removed.push(index);
    }
    removed.sort_unstable_by(|a, b| b.cmp(a));
    removed
        .into_iter()
        .map(|index| {
            let projection = projections.remove(index);
            let field = |key: &str| {
                projection.get(key).and_then(Value::as_str).unwrap_or_default().to_string()
            };
            format!("{}/{}/{}", field("frontend"), field("scope"), field("subject_key"))
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
mod tests {
    use super::*;
    use crate::SurfaceOptions;

    fn temp_root(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "cmux-launch-snapshot-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ))
    }

    fn read_snapshot(path: &Path) -> Option<Value> {
        serde_json::from_slice(&std::fs::read(path).ok()?).ok()
    }

    /// Waits until the snapshot file satisfies `accept` (the writer settles
    /// on its own schedule; tests may wait).
    fn wait_for_snapshot(path: &Path, accept: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Some(snapshot) = read_snapshot(path)
                && accept(&snapshot)
            {
                return snapshot;
            }
            assert!(Instant::now() < deadline, "snapshot never matched: {:?}", read_snapshot(path));
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn workspace_names(snapshot: &Value) -> Vec<String> {
        snapshot["tree"]["workspaces"]
            .as_array()
            .map(|workspaces| {
                workspaces
                    .iter()
                    .filter_map(|workspace| workspace["name"].as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Over its bound, the snapshot leaves out the largest projections first,
    /// only as many as it must, and names them.
    #[test]
    fn an_oversized_snapshot_drops_the_largest_projections_first() {
        let projection = |subject: &str, bytes: usize| {
            json!({"frontend":"cmux-next","scope":"personal","subject_key":subject,
                   "projection":{"pad":"x".repeat(bytes)}})
        };
        let big = MAX_LAUNCH_SNAPSHOT_BYTES / 2;
        let mut value = json!({"tree":{},"frontend_projections":[
            projection("windows", 1000),
            projection("history", big),
            projection("bookmarks", big),
        ]});
        let bytes = serde_json::to_vec(&value).unwrap().len();
        assert!(bytes > MAX_LAUNCH_SNAPSHOT_BYTES);
        let dropped = drop_largest_projections(&mut value, bytes);
        assert_eq!(dropped.len(), 1, "only as many as needed: {dropped:?}");
        assert!(dropped[0].ends_with("/history") || dropped[0].ends_with("/bookmarks"));
        assert!(serde_json::to_vec(&value).unwrap().len() <= MAX_LAUNCH_SNAPSHOT_BYTES);
        let kept: Vec<_> = value["frontend_projections"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| p["subject_key"].as_str().unwrap().to_string())
            .collect();
        assert!(kept.contains(&"windows".to_string()), "the small window state is kept: {kept:?}");
    }

    #[test]
    fn cmux_next_launch_snapshot_follows_the_tree_after_it_settles() {
        let root = temp_root("tree");
        let mux =
            Mux::open_persistent("launch-snapshot-tree", SurfaceOptions::default(), &root).unwrap();
        let writer = start_launch_snapshot_writer_with(
            &mux,
            LaunchSnapshotTiming {
                settle: Duration::from_millis(50),
                max_delay: Duration::from_millis(500),
                max_bytes_per_second: u64::MAX,
            },
        )
        .unwrap()
        .expect("a persistent session has a snapshot path");
        let path = writer.path().to_path_buf();
        assert_eq!(path.file_name().unwrap(), "launch-snapshot.json");
        assert_eq!(mux.launch_snapshot_path().as_deref(), Some(path.as_path()));

        let identify = run_command(&mux, json!({"cmd":"identify"}));
        assert!(
            identify["capabilities"]
                .as_array()
                .unwrap()
                .iter()
                .any(|capability| capability == LAUNCH_SNAPSHOT_CAPABILITY)
        );
        assert_eq!(identify["launch_snapshot_path"], json!(path.to_string_lossy()));

        let placement = mux.create_empty_workspace(Some("first".into()), None, None).unwrap();
        let snapshot = wait_for_snapshot(&path, |snapshot| {
            workspace_names(snapshot).contains(&"first".to_string())
        });
        assert_eq!(snapshot["schema_version"], json!(1));
        assert_eq!(snapshot["app"], json!("cmux-tui"));
        assert_eq!(snapshot["session"], json!("launch-snapshot-tree"));
        let (registry_id, generation) = mux.registry_identity();
        assert_eq!(snapshot["registry_id"], json!(registry_id));
        assert_eq!(snapshot["generation"], json!(generation));
        assert!(snapshot["written_at_ms"].as_u64().is_some());
        // The tree is the list-workspaces reply, so frontends decode it with
        // the decoder they already have.
        let listed = run_command(&mux, json!({"cmd":"list-workspaces"}));
        assert_eq!(snapshot["tree"]["workspaces"], listed["workspaces"]);

        assert!(mux.rename_workspace(placement.workspace, "renamed".into()));
        wait_for_snapshot(&path, |snapshot| {
            workspace_names(snapshot) == vec!["renamed".to_string()]
        });

        // Written atomically: no temporary file is left next to it.
        let leftovers = std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| {
                entry.file_name().to_string_lossy().starts_with("launch-snapshot.json.")
            })
            .count();
        assert_eq!(leftovers, 0);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600, "tab titles and paths are private to the user");
        }

        drop(writer);
        mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    /// A quit's last save asks for the file at once (`flush-launch-snapshot`):
    /// with a settle, delay and byte budget far past the wait, only that request
    /// writes the moved window in time, and its answer says it landed. A quick
    /// relaunch then draws the move, not the write before it.
    #[test]
    fn cmux_next_launch_snapshot_flush_writes_at_once_without_waiting_to_settle() {
        let root = temp_root("flush");
        let mux = Mux::open_persistent("launch-snapshot-flush", SurfaceOptions::default(), &root)
            .unwrap();
        let writer = start_launch_snapshot_writer_with(
            &mux,
            LaunchSnapshotTiming {
                settle: Duration::from_secs(10),
                max_delay: Duration::from_secs(30),
                max_bytes_per_second: 1,
            },
        )
        .unwrap()
        .unwrap();
        let identify = run_command(&mux, json!({"cmd":"identify"}));
        assert!(
            identify["capabilities"]
                .as_array()
                .unwrap()
                .iter()
                .any(|capability| capability == LAUNCH_SNAPSHOT_FLUSH_CAPABILITY)
        );
        // The start write: from here the byte budget alone holds the next one
        // back for (its size / 1) seconds.
        let start = run_command(&mux, json!({"cmd":"flush-launch-snapshot"}));
        assert_eq!(start["flushed"], json!(true));
        let started = read_snapshot(writer.path()).expect("the start write");
        assert!(!workspace_names(&started).contains(&"moved".to_string()));

        let save = |name: &str| {
            run_command(
                &mux,
                json!({
                    "cmd":"put-frontend-projection",
                    "frontend":"cmux-next",
                    "scope":"personal",
                    "subject_key":"windows",
                    "schema_version":1,
                    "projection":{"windows":[{"id":"w1","frame":name}]},
                    "origin":"test",
                    "mutation_id":format!("launch-snapshot-flush-{name}"),
                }),
            );
        };
        let frame = |snapshot: &Value| {
            snapshot["frontend_projections"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|projection| projection["subject_key"] == "windows")
                .map(|projection| projection["projection"]["windows"][0]["frame"].clone())
        };
        mux.create_empty_workspace(Some("moved".into()), None, None).unwrap();
        save("moved");
        // The normal path waits out its 10 s settle.
        std::thread::sleep(Duration::from_millis(300));
        let lagging = read_snapshot(writer.path()).unwrap();
        assert_eq!(frame(&lagging), frame(&started), "the settle holds the normal write back");

        let asked = Instant::now();
        let reply = run_command(&mux, json!({"cmd":"flush-launch-snapshot"}));
        let took = asked.elapsed();
        assert_eq!(reply["flushed"], json!(true));
        assert!(took < Duration::from_secs(1), "the flush took {took:?}");
        // The file holds the save when the answer comes, with no wait.
        let flushed = read_snapshot(writer.path()).unwrap();
        assert_eq!(frame(&flushed), Some(json!("moved")));
        assert!(workspace_names(&flushed).contains(&"moved".to_string()));
        // One write a request: a second one with nothing new writes no bytes.
        let bytes = writer.bytes_written();
        assert_eq!(
            run_command(&mux, json!({"cmd":"flush-launch-snapshot"}))["flushed"],
            json!(true)
        );
        assert_eq!(writer.bytes_written(), bytes);

        drop(writer);
        // With no writer, the request answers at once.
        assert_eq!(
            run_command(&mux, json!({"cmd":"flush-launch-snapshot"}))["flushed"],
            json!(false)
        );
        mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    /// The app quits, is force quit, crashes or is killed right after a window
    /// record save, and sends nothing more: its socket closes. That close
    /// writes the snapshot at once, so a relaunch draws the save. The close of
    /// a connection that wrote no native projection (a CLI call) waits as before.
    #[test]
    fn cmux_next_launch_snapshot_writes_at_once_when_the_app_connection_closes() {
        let root = temp_root("app-close");
        let mux =
            Mux::open_persistent("launch-snapshot-app-close", SurfaceOptions::default(), &root)
                .unwrap();
        let writer = start_launch_snapshot_writer_with(
            &mux,
            LaunchSnapshotTiming {
                settle: Duration::from_secs(10),
                max_delay: Duration::from_secs(30),
                max_bytes_per_second: 1,
            },
        )
        .unwrap()
        .unwrap();
        // The start write; the byte budget alone then holds the next one back.
        assert_eq!(
            run_command(&mux, json!({"cmd":"flush-launch-snapshot"}))["flushed"],
            json!(true)
        );
        let frame = |snapshot: &Value| {
            snapshot["frontend_projections"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|projection| projection["subject_key"] == "windows")
                .map(|projection| projection["projection"]["windows"][0]["frame"].clone())
        };
        let started = frame(&read_snapshot(writer.path()).unwrap());
        assert_eq!(started, None);

        const APP: u64 = 41;
        const CLI: u64 = 42;
        run_command_as(
            &mux,
            APP,
            json!({
                "cmd":"put-frontend-projection",
                "frontend":"cmux-next",
                "scope":"personal",
                "subject_key":"windows",
                "schema_version":1,
                "projection":{"windows":[{"id":"w1","frame":"moved"}]},
                "origin":"test",
                "mutation_id":"launch-snapshot-app-close",
            }),
        );
        run_command_as(&mux, CLI, json!({"cmd":"ping"}));
        // Another connection's close writes nothing early.
        assert!(disconnect_client(&mux, CLI, false));
        std::thread::sleep(Duration::from_millis(300));
        assert_eq!(frame(&read_snapshot(writer.path()).unwrap()), started);

        let closed = Instant::now();
        assert!(disconnect_client(&mux, APP, false));
        let deadline = closed + Duration::from_secs(1);
        loop {
            if frame(&read_snapshot(writer.path()).unwrap()) == Some(json!("moved")) {
                break;
            }
            assert!(Instant::now() < deadline, "the app's close did not write the snapshot in 1 s");
            std::thread::sleep(Duration::from_millis(10));
        }

        drop(writer);
        mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    /// The app draws the Pinned band from the snapshot before it connects
    /// (Lawrence 2026-10-29: pins came back minutes after an update), so the
    /// snapshot holds the sidebar document as `sidebar.get` returns it, and a
    /// pin rewrites it.
    #[test]
    fn cmux_next_launch_snapshot_carries_the_sidebar_document() {
        let root = temp_root("sidebar-doc");
        let mux =
            Mux::open_persistent("launch-snapshot-sidebar-doc", SurfaceOptions::default(), &root)
                .unwrap();
        let writer = start_launch_snapshot_writer_with(
            &mux,
            LaunchSnapshotTiming {
                settle: Duration::from_millis(50),
                max_delay: Duration::from_millis(500),
                max_bytes_per_second: u64::MAX,
            },
        )
        .unwrap()
        .unwrap();
        let request = |operation: &str, params: Value, key: Option<&str>| {
            let mut params = params;
            params["machine"] = json!("current");
            params["session"] = json!("current");
            let mut envelope = json!({"protocol":"cmux.protocol/2","type":"request","id":operation,
                                      "operation":operation,"params":params});
            if let Some(key) = key {
                envelope["idempotency_key"] = json!(key);
            }
            let response =
                crate::resource_router::handle_resource_message(&mux, &envelope.to_string())
                    .unwrap();
            assert_eq!(response["ok"], true, "{operation}: {response}");
            response["result"].clone()
        };
        mux.create_empty_workspace(Some("pinned-one".into()), None, None).unwrap();
        let doc = request("sidebar.get", json!({}), None);
        let item = doc["items"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|item| item["body"]["type"] == "workspace")
            .map(|item| item["id"].clone());
        let item = match item {
            Some(item) => item,
            None => {
                let (registry_id, _) = mux.registry_identity();
                let listed = run_command(&mux, json!({"cmd":"list-workspaces"}));
                let workspace = listed["workspaces"][0]["resource_id"].clone();
                request(
                    "sidebar.adopt",
                    json!({"refs":[{"session_id":registry_id,"workspace_id":workspace}]}),
                    Some("launch-snapshot-adopt"),
                );
                let doc = request("sidebar.get", json!({}), None);
                doc["items"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|item| item["body"]["type"] == "workspace")
                    .map(|item| item["id"].clone())
                    .expect("the adopted workspace has an item")
            }
        };
        request("sidebar.pin", json!({"items":[item]}), Some("launch-snapshot-pin"));
        let expected = request("sidebar.get", json!({}), None);
        let snapshot = wait_for_snapshot(writer.path(), |snapshot| {
            snapshot["sidebar_doc"]["items"].as_array().is_some_and(|items| {
                items.iter().any(|entry| entry["id"] == item && entry["section"] == "sec_pinned")
            })
        });
        assert_eq!(snapshot["sidebar_doc"], expected, "the snapshot's document is sidebar.get's");

        drop(writer);
        mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cmux_next_launch_snapshot_carries_frontend_projections() {
        let root = temp_root("projection");
        let mux =
            Mux::open_persistent("launch-snapshot-projection", SurfaceOptions::default(), &root)
                .unwrap();
        let writer = start_launch_snapshot_writer_with(
            &mux,
            LaunchSnapshotTiming {
                settle: Duration::from_millis(50),
                max_delay: Duration::from_millis(500),
                max_bytes_per_second: u64::MAX,
            },
        )
        .unwrap()
        .unwrap();
        run_command(
            &mux,
            json!({
                "cmd":"put-frontend-projection",
                "frontend":"cmux-next",
                "scope":"personal",
                "subject_key":"windows",
                "schema_version":1,
                "projection":{"windows":[{"id":"w1","workspace_keys":[]}]},
                "origin":"test",
                "mutation_id":"launch-snapshot-projection",
            }),
        );
        let snapshot = wait_for_snapshot(writer.path(), |snapshot| {
            snapshot["frontend_projections"].as_array().is_some_and(|projections| {
                projections.iter().any(|projection| projection["subject_key"] == "windows")
            })
        });
        let projection = snapshot["frontend_projections"]
            .as_array()
            .unwrap()
            .iter()
            .find(|projection| projection["subject_key"] == "windows")
            .unwrap()
            .clone();
        assert_eq!(projection["frontend"], "cmux-next");
        assert_eq!(projection["scope"], "personal");
        assert_eq!(projection["projection"]["windows"][0]["id"], "w1");

        drop(writer);
        mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cmux_next_launch_snapshot_carries_personal_state() {
        let root = temp_root("personal");
        let mux =
            Mux::open_persistent("launch-snapshot-personal", SurfaceOptions::default(), &root)
                .unwrap();
        let writer = start_launch_snapshot_writer_with(
            &mux,
            LaunchSnapshotTiming {
                settle: Duration::from_millis(50),
                max_delay: Duration::from_millis(500),
                max_bytes_per_second: u64::MAX,
            },
        )
        .unwrap()
        .unwrap();
        wait_for_snapshot(writer.path(), |snapshot| snapshot["personal"].is_object());
        // A personal change alone (no tree change) rewrites the snapshot.
        run_command(
            &mux,
            json!({"cmd":"create-profile","profile":"prof_work","name":"Work",
                   "defaults":{"cwd":"/tmp","env":{"TOKEN":"secret"}}}),
        );
        let snapshot = wait_for_snapshot(writer.path(), |snapshot| {
            snapshot["personal"]["profiles"]
                .as_array()
                .is_some_and(|profiles| profiles.iter().any(|profile| profile["id"] == "prof_work"))
        });
        let work = snapshot["personal"]["profiles"]
            .as_array()
            .unwrap()
            .iter()
            .find(|profile| profile["id"] == "prof_work")
            .unwrap();
        assert_eq!(work["defaults"]["cwd"], "/tmp");
        assert!(work["defaults"].get("env").is_none(), "room env stays out of the file");
        // A session's capability list stays out of the file too.
        run_command(
            &mux,
            json!({"cmd":"put-session","session_id":"remote-1","transport":{"kind":"ssh"},
                   "capabilities":["profiles-v1"]}),
        );
        let snapshot = wait_for_snapshot(writer.path(), |snapshot| {
            snapshot["personal"]["sessions"].as_array().is_some_and(|sessions| {
                sessions.iter().any(|session| session["session_id"] == "remote-1")
            })
        });
        assert!(
            snapshot["personal"]["sessions"]
                .as_array()
                .unwrap()
                .iter()
                .all(|session| session.get("capabilities").is_none()),
            "session capabilities stay out of the file"
        );
        assert_eq!(
            snapshot["personal"]["personal_revision"],
            run_command(&mux, json!({"cmd":"list-personal"}))["personal_revision"]
        );

        drop(writer);
        mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cmux_next_launch_snapshot_writes_nothing_while_nothing_changes() {
        let root = temp_root("idle");
        let mux =
            Mux::open_persistent("launch-snapshot-idle", SurfaceOptions::default(), &root).unwrap();
        let writer = start_launch_snapshot_writer_with(
            &mux,
            // A settle window well above one rename keeps the burst inside it
            // on a loaded runner.
            LaunchSnapshotTiming {
                settle: Duration::from_millis(250),
                max_delay: Duration::from_secs(2),
                max_bytes_per_second: u64::MAX,
            },
        )
        .unwrap()
        .unwrap();
        // The first write happens at start, so a relaunch finds a file.
        wait_for_snapshot(writer.path(), |_| true);
        let settled = writer.writes();
        assert!(settled >= 1);
        std::thread::sleep(Duration::from_millis(400));
        assert_eq!(writer.writes(), settled, "an idle session must not rewrite its snapshot");

        mux.create_empty_workspace(Some("burst".into()), None, None).unwrap();
        for index in 0..20 {
            let workspace = mux.with_state(|state| state.workspaces[0].id);
            mux.rename_workspace(workspace, format!("burst-{index}"));
        }
        wait_for_snapshot(writer.path(), |snapshot| {
            workspace_names(snapshot) == vec!["burst-19".to_string()]
        });
        // 21 changes settle into a few writes, never one per change. The
        // bound leaves room for a slow runner splitting the burst.
        let burst = writer.writes() - settled;
        assert!(burst <= 5, "writes: {burst} for 21 changes");

        drop(writer);
        mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cmux_next_launch_snapshot_has_no_path_without_a_persistent_registry() {
        let mux = Mux::new_for_test("launch-snapshot-memory", SurfaceOptions::default());
        assert!(start_launch_snapshot_writer(&mux).unwrap().is_none());
        assert_eq!(mux.launch_snapshot_path(), None);
        let identify = run_command(&mux, json!({"cmd":"identify"}));
        assert_eq!(identify["launch_snapshot_path"], Value::Null);
    }

    fn run_command(mux: &Arc<Mux>, request: Value) -> Value {
        run_command_as(mux, 0, request)
    }

    fn run_command_as(mux: &Arc<Mux>, client: u64, request: Value) -> Value {
        let command: Command = serde_json::from_value(request).unwrap();
        let writer = MessageWriter::new(QueuedSink {
            outbound: Arc::new(BoundedOutbound::default()),
            control: None,
        });
        handle_command(mux, mux.local_test_client(client), command, &writer).unwrap()
    }
}
