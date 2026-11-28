//! fs_watch stream family (relay wire v6): `fs_watch_open` starts a
//! recursive, gitignore-aware watch under a scoped root and streams
//! debounced `fs_watch_event` frames until `fs_watch_close` or the socket
//! drops. Designed like the pty_* frames: errors are typed
//! (`fs_watch_error`), never socket closes. Backend: the `notify` crate
//! (FSEvents/inotify/ReadDirectoryChanges).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{SyncSender, sync_channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::Notify;
use tokio::sync::mpsc::{Receiver, Sender, channel};
use tokio::sync::{Semaphore, oneshot};
use tokio::task::AbortHandle;
use tokio_util::sync::CancellationToken;

use crate::actions::{RootLists, ensure_scoped_file_roots_available};
use crate::relay_wire as wire;
use crate::session::OutboundSink;
use crate::workspace::{Refusal, Scope, WORKSPACE_FRAME_VERSION, slash_path};

/// Concurrent watch sessions per machine (WORKSPACE_WATCH_MAX_SESSIONS).
pub const WATCH_MAX_SESSIONS: usize = 16;
/// Most changes one event frame may carry (WORKSPACE_WATCH_MAX_CHANGES); a
/// burst past this sets `overflow` and the client re-pulls the tree.
pub const WATCH_MAX_CHANGES: usize = 256;

/// Quiet window before a burst flushes, and the ceiling one flush may lag
/// behind the first change in its burst.
const DEBOUNCE_QUIET: Duration = Duration::from_millis(150);
const DEBOUNCE_MAX_LATENCY: Duration = Duration::from_millis(500);
const MAX_PENDING_NOTIFY_EVENTS: usize = 1024;
/// Recursive watcher startup and ignore-file discovery are synchronous
/// filesystem operations. Keep them off the relay executor and bound the
/// number of concurrent setup walks per connection.
pub const WATCH_SETUP_CONCURRENCY: usize = 2;
/// A replacement can keep one retired watcher in synchronous teardown while
/// all sessions and setup slots are occupied. This hard cap bounds detached
/// owner threads even if a platform backend blocks in its destructor.
pub const WATCH_TEARDOWN_CONCURRENCY: usize = WATCH_MAX_SESSIONS + WATCH_SETUP_CONCURRENCY + 1;

/// All fallible watcher setup happens before a watch is published in the
/// registry. A failed replacement therefore leaves the existing watch intact.
struct PreparedWatch {
    watcher: WatcherOwner,
    event_rx: Receiver<Result<notify::Event, notify::Error>>,
    overflowed: Arc<AtomicBool>,
    overflow_notify: Arc<Notify>,
    latched_error: Arc<Mutex<Option<String>>>,
    matcher: ignore::gitignore::Gitignore,
}

/// Owns a notify watcher on a dedicated thread because some backends perform
/// synchronous thread joins from `Drop`. The relay task only sends the bounded
/// shutdown signal and never drops the backend itself. One owner thread exists
/// per prepared or active watch, bounded by the 16-session registry cap plus
/// the two setup slots.
struct WatcherOwner {
    shutdown: Option<SyncSender<()>>,
}

impl WatcherOwner {
    fn new(watcher: notify::RecommendedWatcher, slots: Arc<Semaphore>) -> Result<Self, String> {
        Self::new_with_slots(watcher, slots)
    }

    fn new_with_slots(
        watcher: notify::RecommendedWatcher,
        slots: Arc<Semaphore>,
    ) -> Result<Self, String> {
        let teardown_permit = slots
            .try_acquire_owned()
            .map_err(|_| "watch teardown capacity exhausted".to_owned())?;
        let (shutdown, wait) = sync_channel(1);
        std::thread::Builder::new()
            .name("cmux-watch-teardown".to_owned())
            .spawn(move || {
                let _teardown_permit = teardown_permit;
                let watcher = watcher;
                let _ = wait.recv();
                drop(watcher);
            })
            .map_err(|error| format!("could not start watcher teardown: {error}"))?;
        Ok(Self { shutdown: Some(shutdown) })
    }
}

impl Drop for WatcherOwner {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            // The channel has one slot and only this owner sends, so this
            // cannot block the relay task even if teardown is still running.
            let _ = shutdown.try_send(());
        }
    }
}

struct ActiveWatch {
    generation: u64,
    live: Arc<AtomicBool>,
    cancellation: CancellationToken,
    abort: AbortHandle,
}

struct Opening {
    generation: u64,
    live: Arc<AtomicBool>,
    cancellation: CancellationToken,
    /// The coordinator is detached, so the registry retains only its abort
    /// handle. It may be absent briefly while `open` installs the handle.
    abort: Option<AbortHandle>,
}

struct WatchSlot {
    active: Option<ActiveWatch>,
    opening: Option<Opening>,
}

type Sessions = Arc<Mutex<HashMap<String, WatchSlot>>>;

/// Registry handles one `fs_watch_open` attempt carries from reservation
/// through commit or failure. `generation` and `live` identify the attempt;
/// a newer replacement cancels `cancellation` and retires `live`.
struct OpenContext {
    watch_id: String,
    generation: u64,
    live: Arc<AtomicBool>,
    cancellation: CancellationToken,
    sessions: Sessions,
    outbound: OutboundSink,
}

enum RetiredWatch {
    Active(ActiveWatch),
    Opening(Opening),
}

enum Reservation {
    Accepted { previous: Option<Opening> },
    Limit,
}

impl RetiredWatch {
    fn stop(self) {
        match self {
            RetiredWatch::Active(active) => {
                active.live.store(false, Ordering::Release);
                active.cancellation.cancel();
                active.abort.abort();
            }
            RetiredWatch::Opening(opening) => {
                opening.live.store(false, Ordering::Release);
                opening.cancellation.cancel();
                if let Some(abort) = opening.abort {
                    abort.abort();
                }
            }
        }
    }
}

impl WatchSlot {
    fn retire(self) -> impl Iterator<Item = RetiredWatch> {
        self.active
            .into_iter()
            .map(RetiredWatch::Active)
            .chain(self.opening.into_iter().map(RetiredWatch::Opening))
    }
}

pub struct WatchRegistry {
    outbound: OutboundSink,
    sessions: Sessions,
    next_generation: Arc<AtomicU64>,
    setup_slots: Arc<Semaphore>,
    teardown_slots: Arc<Semaphore>,
    cancellation: CancellationToken,
}

impl Drop for WatchRegistry {
    fn drop(&mut self) {
        // The socket died with this registry; the Worker re-opens watches
        // on the next connection.
        self.cancellation.cancel();
        let retired = self
            .sessions
            .lock()
            .map(|mut sessions| sessions.drain().flat_map(|(_, slot)| slot.retire()).collect())
            .unwrap_or_else(|_| Vec::new());
        for watch in retired {
            watch.stop();
        }
    }
}

fn watch_error_frame(
    watch_id: &str,
    code: wire::WorkspaceErrorCode,
    message: Option<&str>,
) -> String {
    let message = match code {
        wire::WorkspaceErrorCode::PathForbidden => {
            Some("path is forbidden by the workspace policy".to_owned())
        }
        _ => message.map(str::to_owned),
    };
    serde_json::to_string(&wire::RelayFsWatchError {
        version: WORKSPACE_FRAME_VERSION,
        r#type: wire::TagFsWatchError::FsWatchError,
        watch_id: watch_id.to_owned(),
        code,
        message,
    })
    .unwrap_or_else(|_| String::new())
}

/// Terminal response for a watch that cannot enqueue another lossy event. The
/// critical lane lets the client re-open the stream instead of retaining a
/// permanently silent watch ID.
async fn report_watch_failure(
    watch_id: &str,
    outbound: &OutboundSink,
    cancellation: &CancellationToken,
    live: &Arc<AtomicBool>,
) {
    let text = watch_error_frame(watch_id, wire::WorkspaceErrorCode::Failed, None);
    tokio::select! {
        biased;
        _ = cancellation.cancelled() => {}
        _ = outbound.critical_text_with_token(text, Some(Arc::clone(live))) => {}
    }
}

impl WatchRegistry {
    #[cfg(test)]
    pub(crate) fn new(outbound: OutboundSink) -> WatchRegistry {
        Self::new_with_teardown_slots(
            outbound,
            Arc::new(Semaphore::new(WATCH_TEARDOWN_CONCURRENCY)),
        )
    }

    #[cfg(test)]
    pub(crate) fn new_with_teardown_slots(
        outbound: OutboundSink,
        teardown_slots: Arc<Semaphore>,
    ) -> WatchRegistry {
        Self::new_with_resource_slots(
            outbound,
            Arc::new(Semaphore::new(WATCH_SETUP_CONCURRENCY)),
            teardown_slots,
        )
    }

    pub(crate) fn new_with_resource_slots(
        outbound: OutboundSink,
        setup_slots: Arc<Semaphore>,
        teardown_slots: Arc<Semaphore>,
    ) -> WatchRegistry {
        WatchRegistry {
            outbound,
            sessions: Arc::new(Mutex::new(HashMap::new())),
            next_generation: Arc::new(AtomicU64::new(0)),
            setup_slots,
            teardown_slots,
            cancellation: CancellationToken::new(),
        }
    }

    pub fn refuse(&self, watch_id: &str, code: wire::WorkspaceErrorCode, message: &str) {
        let text = watch_error_frame(watch_id, code, Some(message));
        let _ = self.outbound.try_critical_text(text);
    }

    pub fn close(&self, watch_id: &str) {
        let retired = self
            .sessions
            .lock()
            .ok()
            .and_then(|mut sessions| sessions.remove(watch_id))
            .map(|slot| slot.retire().collect::<Vec<_>>())
            .unwrap_or_default();
        for watch in retired {
            watch.stop();
        }
    }

    /// Reserve an ID and start asynchronous setup. The active watch, if any,
    /// remains live until setup succeeds and `fs_watch_opened` is queued.
    /// Watching is read-only: observe trust is admitted.
    pub fn open(&self, frame: wire::RelayFsWatchOpen, local_roots: Option<&[String]>) {
        let watch_id = frame.watch_id.clone();
        let generation = self.next_generation.fetch_add(1, Ordering::Relaxed);
        let opening_cancellation = self.cancellation.child_token();
        let opening_live = Arc::new(AtomicBool::new(true));
        let sessions = Arc::clone(&self.sessions);
        let outbound = self.outbound.clone();
        let setup_slots = Arc::clone(&self.setup_slots);
        let teardown_slots = Arc::clone(&self.teardown_slots);
        let local_roots_for_task = local_roots.map(<[String]>::to_vec);
        let reservation = match self.sessions.lock() {
            Ok(mut state) => {
                let existing = state.contains_key(&watch_id);
                if !existing && state.len() >= WATCH_MAX_SESSIONS {
                    Reservation::Limit
                } else {
                    let slot = state
                        .entry(watch_id.clone())
                        .or_insert_with(|| WatchSlot { active: None, opening: None });
                    let previous = slot.opening.replace(Opening {
                        generation,
                        live: Arc::clone(&opening_live),
                        cancellation: opening_cancellation.clone(),
                        abort: None,
                    });
                    // Spawn while the state lock is held, then install the
                    // abort handle before another caller can close/replace
                    // this slot. Tokio guarantees `spawn` does not poll the
                    // future synchronously as part of this call.
                    let context = OpenContext {
                        watch_id: watch_id.clone(),
                        generation,
                        live: Arc::clone(&opening_live),
                        cancellation: opening_cancellation,
                        sessions: Arc::clone(&sessions),
                        outbound,
                    };
                    let task = tokio::spawn(coordinate_open(
                        context,
                        frame,
                        local_roots_for_task,
                        setup_slots,
                        teardown_slots,
                    ));
                    slot.opening.as_mut().expect("opening was just reserved").abort =
                        Some(task.abort_handle());
                    Reservation::Accepted { previous }
                }
            }
            Err(_) => Reservation::Limit,
        };
        let previous = match reservation {
            Reservation::Accepted { previous } => previous,
            Reservation::Limit => {
                self.refuse(
                    &watch_id,
                    wire::WorkspaceErrorCode::WatchLimit,
                    &format!("this machine already streams {WATCH_MAX_SESSIONS} watches"),
                );
                return;
            }
        };
        if let Some(previous) = previous {
            RetiredWatch::Opening(previous).stop();
        }
    }
}

enum SetupFailure {
    Cancelled,
    Refused { code: wire::WorkspaceErrorCode, message: String },
    Failed(String),
}

/// Resolve the scoped root, install notify, and discover ignore files on a
/// blocking worker. The semaphore permit is moved into that worker so a
/// started walk continues to count against the setup bound until it exits.
async fn setup_watch(
    frame: wire::RelayFsWatchOpen,
    local_roots: Option<Vec<String>>,
    cancellation: CancellationToken,
    setup_slots: Arc<Semaphore>,
    teardown_slots: Arc<Semaphore>,
) -> Result<(PathBuf, PreparedWatch), SetupFailure> {
    let permit = tokio::select! {
        biased;
        _ = cancellation.cancelled() => return Err(SetupFailure::Cancelled),
        result = setup_slots.acquire_owned() => result
            .map_err(|error| SetupFailure::Failed(format!("watch setup lane closed: {error}")))?,
    };
    let blocking_cancellation = cancellation.clone();
    let setup = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        if blocking_cancellation.is_cancelled() {
            return Err(SetupFailure::Cancelled);
        }
        let root = watch_root(&frame, local_roots.as_deref()).map_err(|refusal| {
            SetupFailure::Refused { code: refusal.code, message: refusal.message }
        })?;
        if blocking_cancellation.is_cancelled() {
            return Err(SetupFailure::Cancelled);
        }
        let mut prepared = prepare_watch(&root, teardown_slots).map_err(SetupFailure::Failed)?;
        if blocking_cancellation.is_cancelled() {
            drop(prepared);
            return Err(SetupFailure::Cancelled);
        }
        prepared.matcher = build_ignore_matcher(&root);
        if blocking_cancellation.is_cancelled() {
            drop(prepared);
            return Err(SetupFailure::Cancelled);
        }
        Ok((root, prepared))
    });
    let setup_abort = setup.abort_handle();
    tokio::select! {
        biased;
        _ = cancellation.cancelled() => {
            // Aborting the join future does not stop an already-running
            // blocking closure. Its permit and watcher are released when it
            // returns, and the bounded lane prevents unbounded accumulation.
            setup_abort.abort();
            Err(SetupFailure::Cancelled)
        }
        result = setup => match result {
            Ok(result) => result,
            Err(error) => Err(SetupFailure::Failed(format!("watch setup crashed: {error}"))),
        },
    }
}

async fn coordinate_open(
    context: OpenContext,
    frame: wire::RelayFsWatchOpen,
    local_roots: Option<Vec<String>>,
    setup_slots: Arc<Semaphore>,
    teardown_slots: Arc<Semaphore>,
) {
    let setup = setup_watch(
        frame,
        local_roots,
        context.cancellation.clone(),
        Arc::clone(&setup_slots),
        teardown_slots,
    )
    .await;
    match setup {
        Ok((root, prepared)) => commit_open(context, root, prepared, setup_slots),
        Err(SetupFailure::Cancelled) => {}
        Err(SetupFailure::Refused { code, message }) => {
            finish_open_failure(context, code, Some(message)).await;
        }
        Err(SetupFailure::Failed(_message)) => {
            finish_open_failure(context, wire::WorkspaceErrorCode::Failed, None).await;
        }
    }
}

/// Publish the acknowledgement and active task as one state transition.
/// `prepared` stays outside the mutex on every rejection path so dropping a
/// notify watcher cannot run while registry state is locked.
fn commit_open(
    context: OpenContext,
    root: PathBuf,
    prepared: PreparedWatch,
    setup_slots: Arc<Semaphore>,
) {
    let OpenContext { watch_id, generation, live, cancellation, sessions, outbound } = context;
    let opened = serde_json::to_string(&wire::RelayFsWatchOpened {
        version: WORKSPACE_FRAME_VERSION,
        r#type: wire::TagFsWatchOpened::FsWatchOpened,
        watch_id: watch_id.clone(),
        root: root.to_string_lossy().into_owned(),
    })
    .unwrap_or_else(|_| String::new());
    let mut prepared = Some(prepared);
    let mut retired = Vec::new();
    let mut start = None;
    let mut committed = false;
    if let Ok(mut state) = sessions.lock() {
        let mut remove_slot = false;
        if let Some(slot) = state.get_mut(&watch_id)
            && slot.opening.as_ref().is_some_and(|opening| {
                opening.generation == generation && !opening.cancellation.is_cancelled()
            })
            && outbound.try_critical_text_with_token(opened, Some(Arc::clone(&live))).is_ok()
        {
            let (start_tx, start_rx) = oneshot::channel();
            let run_id = watch_id.clone();
            let run_root = root;
            let run_outbound = outbound;
            let run_sessions = Arc::clone(&sessions);
            let run_setup_slots = setup_slots;
            let run_cancellation = cancellation.clone();
            let run_live = Arc::clone(&live);
            let run_prepared = prepared.take().expect("prepared watch present");
            let task = tokio::spawn(async move {
                // Install the active slot before allowing the runner to poll.
                // This closes the fast-exit race where cleanup could otherwise
                // run before the registry stores the task generation.
                if start_rx.await.is_err() {
                    return;
                }
                run_watch(
                    &run_id,
                    &run_root,
                    &run_outbound,
                    run_prepared,
                    run_cancellation.clone(),
                    run_live,
                    run_setup_slots,
                )
                .await;
                finish_active(&run_id, generation, run_sessions);
            });
            let previous = slot.active.replace(ActiveWatch {
                generation,
                live: Arc::clone(&live),
                cancellation: cancellation.clone(),
                abort: task.abort_handle(),
            });
            slot.opening.take();
            if let Some(previous) = previous {
                retired.push(RetiredWatch::Active(previous));
            }
            start = Some(start_tx);
            committed = true;
        } else if state.get(&watch_id).is_some_and(|slot| {
            slot.opening.as_ref().is_some_and(|opening| opening.generation == generation)
        }) {
            // A full/closed queue rejects the replacement while preserving
            // the currently active watch. Clear only this generation.
            if let Some(slot) = state.get_mut(&watch_id) {
                slot.opening.take();
                remove_slot = slot.active.is_none();
            }
        }
        if remove_slot {
            state.remove(&watch_id);
        }
    }
    if !committed {
        live.store(false, Ordering::Release);
        cancellation.cancel();
    }
    for watch in retired {
        watch.stop();
    }
    if let Some(start) = start {
        let _ = start.send(());
    }
    // Explicitly drop after the lock has been released. See the helper's
    // comment above; notify watcher teardown can perform synchronous work.
    drop(prepared);
}

async fn finish_open_failure(
    context: OpenContext,
    code: wire::WorkspaceErrorCode,
    message: Option<String>,
) {
    let OpenContext { watch_id, generation, live, cancellation, sessions, outbound } = context;
    let watch_id = watch_id.as_str();
    let text = watch_error_frame(watch_id, code, message.as_deref());
    let should_report = sessions.lock().ok().is_some_and(|state| {
        state.get(watch_id).is_some_and(|slot| {
            slot.opening.as_ref().is_some_and(|opening| {
                opening.generation == generation && !opening.cancellation.is_cancelled()
            })
        })
    });
    if !should_report {
        cancellation.cancel();
        return;
    }

    // Keep the opening reservation until the terminal frame is admitted. The
    // liveness token lets a newer replacement cancel this send without
    // delivering a stale error after its own opened frame.
    tokio::select! {
        biased;
        _ = cancellation.cancelled() => return,
        _ = outbound.critical_text_with_token(text, Some(Arc::clone(&live))) => {}
    }

    let remove_slot = if let Ok(mut state) = sessions.lock() {
        let remove_slot = if let Some(slot) = state.get_mut(watch_id)
            && slot.opening.as_ref().is_some_and(|opening| {
                opening.generation == generation && !opening.cancellation.is_cancelled()
            }) {
            slot.opening.take();
            live.store(false, Ordering::Release);
            slot.active.is_none()
        } else {
            false
        };
        if remove_slot {
            state.remove(watch_id);
        }
        remove_slot
    } else {
        false
    };
    if remove_slot {
        cancellation.cancel();
    }
}

fn finish_active(watch_id: &str, generation: u64, sessions: Sessions) {
    // Every runner exit retires its liveness token. Replacement, close, and
    // watcher failure must discard queued events from a dead generation; a
    // terminal critical frame is awaited before those paths return, so it is
    // delivered before this token is retired.
    let mut live = None;
    if let Ok(mut state) = sessions.lock() {
        let mut remove_slot = false;
        if let Some(slot) = state.get_mut(watch_id)
            && slot.active.as_ref().is_some_and(|active| active.generation == generation)
        {
            live = slot.active.take().map(|active| active.live);
            remove_slot = slot.opening.is_none();
        }
        if remove_slot {
            state.remove(watch_id);
        }
    }
    if let Some(live) = live {
        live.store(false, Ordering::Release);
    }
}

fn prepare_watch(root: &Path, teardown_slots: Arc<Semaphore>) -> Result<PreparedWatch, String> {
    use notify::Watcher as _;

    let (event_tx, event_rx) =
        channel::<Result<notify::Event, notify::Error>>(MAX_PENDING_NOTIFY_EVENTS);
    let overflowed = Arc::new(AtomicBool::new(false));
    let overflow_notify = Arc::new(Notify::new());
    let latched_error = Arc::new(Mutex::new(None::<String>));
    let callback_overflowed = Arc::clone(&overflowed);
    let callback_notify = Arc::clone(&overflow_notify);
    let callback_error = Arc::clone(&latched_error);
    let mut watcher = notify::recommended_watcher(
        move |event: Result<notify::Event, notify::Error>| match event {
            Ok(event) => try_enqueue_notify_event(
                &event_tx,
                &callback_overflowed,
                &callback_notify,
                Ok(event),
            ),
            Err(error) => {
                if let Ok(mut latched) = callback_error.lock() {
                    *latched = Some(error.to_string());
                }
                callback_notify.notify_one();
            }
        },
    )
    .map_err(|error| format!("could not start the watcher: {error}"))?;
    watcher
        .watch(root, notify::RecursiveMode::Recursive)
        .map_err(|error| format!("could not watch {}: {error}", root.display()))?;
    let watcher = WatcherOwner::new(watcher, teardown_slots)?;
    Ok(PreparedWatch {
        watcher,
        event_rx,
        overflowed,
        overflow_notify,
        latched_error,
        matcher: ignore::gitignore::Gitignore::empty(),
    })
}

fn watch_root(
    frame: &wire::RelayFsWatchOpen,
    local_roots: Option<&[String]>,
) -> Result<PathBuf, Refusal> {
    watch_root_with_capabilities(frame, local_roots, cfg!(unix))
}

fn watch_root_with_capabilities(
    frame: &wire::RelayFsWatchOpen,
    local_roots: Option<&[String]>,
    supports_descriptor_scoping: bool,
) -> Result<PathBuf, Refusal> {
    let roots: RootLists<'_> = [local_roots, frame.allowed_roots.as_deref()];
    ensure_scoped_file_roots_available(supports_descriptor_scoping, &roots)
        .map_err(|message| Refusal::new(wire::WorkspaceErrorCode::UnsupportedVerb, message))?;
    let scope = Scope::build(frame.allowed_roots.as_deref(), local_roots)?;
    let root = match &frame.root {
        Some(raw) => scope.resolve(raw, false)?,
        None => scope.existing_workdir()?,
    };
    if root.is_dir() {
        Ok(root)
    } else {
        Err(Refusal::new(
            wire::WorkspaceErrorCode::NotFound,
            format!("{} is not a directory", root.display()),
        ))
    }
}

// ---------------------------------------------------------------------------
// The watch task: notify events -> debounce -> gitignore filter -> frames
// ---------------------------------------------------------------------------

async fn run_watch(
    watch_id: &str,
    root: &Path,
    outbound: &OutboundSink,
    prepared: PreparedWatch,
    cancellation: CancellationToken,
    live: Arc<AtomicBool>,
    setup_slots: Arc<Semaphore>,
) {
    let PreparedWatch {
        watcher,
        mut event_rx,
        overflowed,
        overflow_notify,
        latched_error,
        mut matcher,
    } = prepared;
    'watch: loop {
        let notified = overflow_notify.notified();
        let first = tokio::select! {
            biased;
            _ = cancellation.cancelled() => break 'watch,
            event = event_rx.recv() => event,
            _ = notified => None,
        };
        let mut burst = first.into_iter().collect::<Vec<_>>();
        let has_latched_error = latched_error.lock().map(|error| error.is_some()).unwrap_or(false);
        if burst.is_empty() && !overflowed.load(Ordering::Acquire) && !has_latched_error {
            break;
        }
        drain_burst(&mut event_rx, &mut burst, &cancellation).await;
        if cancellation.is_cancelled() {
            break 'watch;
        }
        let mut fatal: Option<notify::Error> = None;
        let mut overflow = overflowed.swap(false, Ordering::AcqRel);
        // Include drops that happened while the quiet-window drain was
        // collecting this burst. A later burst must not hide this loss.
        overflow |= overflowed.swap(false, Ordering::AcqRel);
        let mut changes: Vec<wire::FsWatchChange> = Vec::new();
        let mut change_index: HashMap<String, usize> = HashMap::new();
        let mut saw_ignore_file = false;
        for event in burst {
            match event {
                Ok(event) => {
                    if event.need_rescan() {
                        overflow = true;
                    }
                    collect_changes(
                        root,
                        &matcher,
                        &event,
                        &mut changes,
                        &mut change_index,
                        &mut saw_ignore_file,
                    );
                }
                Err(error) => fatal = Some(error),
            }
        }
        if changes.len() > WATCH_MAX_CHANGES {
            changes.truncate(WATCH_MAX_CHANGES);
            overflow = true;
        }
        if overflow {
            let text = watch_error_frame(
                watch_id,
                wire::WorkspaceErrorCode::Failed,
                Some("watch event burst overflowed; refresh the tree"),
            );
            tokio::select! {
                biased;
                _ = cancellation.cancelled() => break 'watch,
                _ = outbound.critical_text_with_token(text, Some(Arc::clone(&live))) => {}
            }
        }
        let latched_error = latched_error.lock().ok().and_then(|mut error| error.take());
        if !changes.is_empty() || overflow {
            let frame = serde_json::to_string(&wire::RelayFsWatchEvent {
                version: WORKSPACE_FRAME_VERSION,
                r#type: wire::TagFsWatchEvent::FsWatchEvent,
                watch_id: watch_id.to_owned(),
                changes,
                overflow: overflow.then_some(true),
            })
            .unwrap_or_else(|_| String::new());
            if outbound.try_watch_text_with_token(frame, Some(Arc::clone(&live))).is_err() {
                // The outbound sink is saturated or closed. Retrying by
                // latching overflow would wake this loop immediately and
                // spin forever while producing no observable frame. The
                // event is explicitly lost, so terminate this watch task.
                // Tell the client why its stream ended. Watch frames cannot
                // consume the critical byte reserve, so this response remains
                // available when event delivery is saturated.
                report_watch_failure(watch_id, outbound, &cancellation, &live).await;
                break 'watch;
            }
        }
        if saw_ignore_file {
            if let Some(updated) =
                rebuild_ignore_matcher(root, Arc::clone(&setup_slots), &cancellation).await
            {
                matcher = updated;
            } else if cancellation.is_cancelled() {
                break 'watch;
            }
        }
        if let Some(_error) = fatal {
            let text = watch_error_frame(watch_id, wire::WorkspaceErrorCode::Failed, None);
            tokio::select! {
                biased;
                _ = cancellation.cancelled() => break 'watch,
                _ = outbound.critical_text_with_token(text, Some(Arc::clone(&live))) => {}
            }
            break;
        }
        if let Some(_error) = latched_error {
            let text = watch_error_frame(watch_id, wire::WorkspaceErrorCode::Failed, None);
            tokio::select! {
                biased;
                _ = cancellation.cancelled() => break 'watch,
                _ = outbound.critical_text_with_token(text, Some(Arc::clone(&live))) => {}
            }
            break;
        }
    }
    drop(watcher);
}

/// Rebuild an ignore matcher without pausing the async relay worker. The same
/// setup semaphore as initial admission keeps repeated `.gitignore` edits from
/// creating an unbounded blocking-worker queue.
async fn rebuild_ignore_matcher(
    root: &Path,
    setup_slots: Arc<Semaphore>,
    cancellation: &CancellationToken,
) -> Option<ignore::gitignore::Gitignore> {
    let permit = tokio::select! {
        biased;
        _ = cancellation.cancelled() => return None,
        result = setup_slots.acquire_owned() => result.ok()?,
    };
    let root = root.to_owned();
    let blocking_cancellation = cancellation.clone();
    let task = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        if blocking_cancellation.is_cancelled() { None } else { Some(build_ignore_matcher(&root)) }
    });
    let task_abort = task.abort_handle();
    tokio::select! {
        biased;
        _ = cancellation.cancelled() => {
            task_abort.abort();
            None
        }
        result = task => result.ok().flatten(),
    }
}

async fn drain_burst(
    event_rx: &mut Receiver<Result<notify::Event, notify::Error>>,
    burst: &mut Vec<Result<notify::Event, notify::Error>>,
    cancellation: &CancellationToken,
) {
    let flush_at = tokio::time::Instant::now() + DEBOUNCE_MAX_LATENCY;
    loop {
        let now = tokio::time::Instant::now();
        if now >= flush_at {
            return;
        }
        let quiet = DEBOUNCE_QUIET.min(flush_at - now);
        tokio::select! {
            biased;
            _ = cancellation.cancelled() => return,
            result = tokio::time::timeout(quiet, event_rx.recv()) => match result {
                Ok(Some(event)) => burst.push(event),
                Ok(None) | Err(_) => return,
            },
        }
    }
}

fn try_enqueue_notify_event<T>(
    sender: &Sender<T>,
    overflowed: &AtomicBool,
    notify: &Notify,
    event: T,
) {
    if sender.try_send(event).is_err() {
        overflowed.store(true, Ordering::Release);
        notify.notify_one();
    }
}

/// Gitignore filter matching fs_tree's semantics: every .gitignore/.ignore
/// under the root (plus git's own exclude file), .git itself always
/// filtered separately. Rebuilt when an ignore file changes.
fn build_ignore_matcher(root: &Path) -> ignore::gitignore::Gitignore {
    let mut builder = ignore::gitignore::GitignoreBuilder::new(root);
    let exclude = root.join(".git/info/exclude");
    if exclude.is_file() {
        let _ = builder.add(exclude);
    }
    let mut walker = ignore::WalkBuilder::new(root);
    walker
        .hidden(false)
        .follow_links(false)
        .filter_entry(|entry| entry.file_name() != std::ffi::OsStr::new(".git"));
    let mut seen = 0_usize;
    for entry in walker.build() {
        let Ok(entry) = entry else { continue };
        seen += 1;
        if seen > 50_000 {
            break;
        }
        let name = entry.file_name();
        if (name == ".gitignore" || name == ".ignore")
            && entry.file_type().is_some_and(|kind| kind.is_file())
        {
            let _ = builder.add(entry.path());
        }
    }
    builder.build().unwrap_or_else(|_| ignore::gitignore::Gitignore::empty())
}

fn relative_watch_path(root: &Path, path: &Path) -> Option<String> {
    let relative = path.strip_prefix(root).ok()?;
    if relative.components().any(|part| part.as_os_str() == ".git") {
        return None;
    }
    let text = slash_path(relative);
    if text.is_empty() { None } else { Some(text) }
}

fn record(
    changes: &mut Vec<wire::FsWatchChange>,
    change_index: &mut HashMap<String, usize>,
    change: wire::FsWatchChange,
) {
    match change_index.get(&change.path) {
        Some(&index) => {
            let existing = &mut changes[index];
            // Merge within one burst: created-then-modified stays created;
            // anything ending deleted is deleted; a rename target wins.
            existing.kind = match (existing.kind, change.kind) {
                (wire::FsWatchChangeKind::Created, wire::FsWatchChangeKind::Modified) => {
                    wire::FsWatchChangeKind::Created
                }
                (_, kind) => kind,
            };
            if change.old_path.is_some() {
                existing.old_path = change.old_path;
            }
        }
        None => {
            change_index.insert(change.path.clone(), changes.len());
            changes.push(change);
        }
    }
}

fn collect_changes(
    root: &Path,
    matcher: &ignore::gitignore::Gitignore,
    event: &notify::Event,
    changes: &mut Vec<wire::FsWatchChange>,
    change_index: &mut HashMap<String, usize>,
    saw_ignore_file: &mut bool,
) {
    use notify::EventKind;
    use notify::event::{ModifyKind, RenameMode};
    let admit = |path: &Path, relative: &str| -> bool {
        let name = path.file_name().and_then(|name| name.to_str()).unwrap_or_default();
        if name == ".gitignore" || name == ".ignore" {
            return true;
        }
        let is_dir = path.is_dir();
        !matcher.matched_path_or_any_parents(relative, is_dir).is_ignore()
    };
    let mut push = |path: &Path, kind: wire::FsWatchChangeKind, old: Option<&Path>| {
        let Some(relative) = relative_watch_path(root, path) else { return };
        if path.file_name().is_some_and(|name| name == ".gitignore" || name == ".ignore") {
            *saw_ignore_file = true;
        }
        if !admit(path, &relative) {
            return;
        }
        let old_path = old.and_then(|old| relative_watch_path(root, old));
        record(changes, change_index, wire::FsWatchChange { path: relative, kind, old_path });
    };
    match event.kind {
        EventKind::Create(_) => {
            for path in &event.paths {
                push(path, wire::FsWatchChangeKind::Created, None);
            }
        }
        EventKind::Remove(_) => {
            for path in &event.paths {
                push(path, wire::FsWatchChangeKind::Deleted, None);
            }
        }
        EventKind::Modify(ModifyKind::Name(RenameMode::Both)) if event.paths.len() == 2 => {
            push(&event.paths[1], wire::FsWatchChangeKind::Renamed, Some(&event.paths[0]));
        }
        EventKind::Modify(ModifyKind::Name(RenameMode::From)) => {
            for path in &event.paths {
                push(path, wire::FsWatchChangeKind::Deleted, None);
            }
        }
        EventKind::Modify(ModifyKind::Name(RenameMode::To)) => {
            for path in &event.paths {
                push(path, wire::FsWatchChangeKind::Created, None);
            }
        }
        EventKind::Modify(ModifyKind::Name(_)) | EventKind::Any | EventKind::Other => {
            // FSEvents reports both halves of a rename as Name(Any) with
            // one path each: probe the disk to tell which half this is.
            for path in &event.paths {
                let kind = if path.symlink_metadata().is_ok() {
                    wire::FsWatchChangeKind::Created
                } else {
                    wire::FsWatchChangeKind::Deleted
                };
                push(path, kind, None);
            }
        }
        EventKind::Modify(_) => {
            for path in &event.paths {
                push(path, wire::FsWatchChangeKind::Modified, None);
            }
        }
        EventKind::Access(_) => {}
    }
}

#[cfg(test)]
mod tests;
