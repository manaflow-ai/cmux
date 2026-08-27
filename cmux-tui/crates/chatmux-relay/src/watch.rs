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
use std::sync::{Arc, Mutex, OnceLock};
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
const WATCH_SETUP_CONCURRENCY: usize = 2;
/// A replacement can keep one retired watcher in synchronous teardown while
/// all sessions and setup slots are occupied. This hard cap bounds detached
/// owner threads even if a platform backend blocks in its destructor.
const WATCH_TEARDOWN_CONCURRENCY: usize = WATCH_MAX_SESSIONS + WATCH_SETUP_CONCURRENCY + 1;

static WATCH_TEARDOWN_SLOTS: OnceLock<Arc<Semaphore>> = OnceLock::new();

fn watcher_teardown_slots() -> Arc<Semaphore> {
    Arc::clone(
        WATCH_TEARDOWN_SLOTS.get_or_init(|| Arc::new(Semaphore::new(WATCH_TEARDOWN_CONCURRENCY))),
    )
}

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
    fn new(watcher: notify::RecommendedWatcher) -> Result<Self, String> {
        Self::new_with_slots(watcher, watcher_teardown_slots())
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
    serde_json::to_string(&wire::RelayFsWatchError {
        version: WORKSPACE_FRAME_VERSION,
        r#type: wire::TagFsWatchError::FsWatchError,
        watch_id: watch_id.to_owned(),
        code,
        message: message.map(str::to_owned),
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
    pub(crate) fn new(outbound: OutboundSink) -> WatchRegistry {
        WatchRegistry {
            outbound,
            sessions: Arc::new(Mutex::new(HashMap::new())),
            next_generation: Arc::new(AtomicU64::new(0)),
            setup_slots: Arc::new(Semaphore::new(WATCH_SETUP_CONCURRENCY)),
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
                    let task_id = watch_id.clone();
                    let task_cancellation = opening_cancellation.clone();
                    let task = tokio::spawn(coordinate_open(
                        task_id,
                        frame,
                        local_roots_for_task,
                        generation,
                        Arc::clone(&opening_live),
                        task_cancellation,
                        Arc::clone(&sessions),
                        outbound,
                        setup_slots,
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
        let mut prepared = prepare_watch(&root).map_err(SetupFailure::Failed)?;
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
    watch_id: String,
    frame: wire::RelayFsWatchOpen,
    local_roots: Option<Vec<String>>,
    generation: u64,
    live: Arc<AtomicBool>,
    cancellation: CancellationToken,
    sessions: Sessions,
    outbound: OutboundSink,
    setup_slots: Arc<Semaphore>,
) {
    let setup = setup_watch(frame, local_roots, cancellation.clone(), setup_slots.clone()).await;
    match setup {
        Ok((root, prepared)) => {
            commit_open(
                watch_id,
                root,
                prepared,
                generation,
                live,
                cancellation,
                sessions,
                outbound,
                setup_slots,
            );
        }
        Err(SetupFailure::Cancelled) => {}
        Err(SetupFailure::Refused { code, message }) => {
            finish_open_failure(
                &watch_id,
                generation,
                live,
                cancellation,
                sessions,
                outbound,
                code,
                Some(message),
            );
        }
        Err(SetupFailure::Failed(_message)) => {
            finish_open_failure(
                &watch_id,
                generation,
                live,
                cancellation,
                sessions,
                outbound,
                wire::WorkspaceErrorCode::Failed,
                None,
            );
        }
    }
}

/// Publish the acknowledgement and active task as one state transition.
/// `prepared` stays outside the mutex on every rejection path so dropping a
/// notify watcher cannot run while registry state is locked.
fn commit_open(
    watch_id: String,
    root: PathBuf,
    prepared: PreparedWatch,
    generation: u64,
    live: Arc<AtomicBool>,
    cancellation: CancellationToken,
    sessions: Sessions,
    outbound: OutboundSink,
    setup_slots: Arc<Semaphore>,
) {
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
            let run_root = root.clone();
            let run_outbound = outbound.clone();
            let run_sessions = Arc::clone(&sessions);
            let run_setup_slots = Arc::clone(&setup_slots);
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

fn finish_open_failure(
    watch_id: &str,
    generation: u64,
    live: Arc<AtomicBool>,
    cancellation: CancellationToken,
    sessions: Sessions,
    outbound: OutboundSink,
    code: wire::WorkspaceErrorCode,
    message: Option<String>,
) {
    let text = watch_error_frame(watch_id, code, message.as_deref());
    if let Ok(mut state) = sessions.lock() {
        let remove_slot = if let Some(slot) = state.get_mut(watch_id)
            && slot.opening.as_ref().is_some_and(|opening| {
                opening.generation == generation && !opening.cancellation.is_cancelled()
            }) {
            // Keep the active watch intact while the refusal is queued.
            // Holding the state lock orders this frame before a subsequent
            // replacement.
            // This is a terminal response for the open request. Do not attach
            // the opening token: it is retired immediately below, and a token
            // would make the writer discard the error before the client sees it.
            let _ = outbound.try_critical_text(text);
            slot.opening.take();
            live.store(false, Ordering::Release);
            slot.active.is_none()
        } else {
            false
        };
        if remove_slot {
            state.remove(watch_id);
        }
    }
    cancellation.cancel();
}

fn finish_active(watch_id: &str, generation: u64, sessions: Sessions) {
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

fn prepare_watch(root: &Path) -> Result<PreparedWatch, String> {
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
    let watcher = WatcherOwner::new(watcher)?;
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
mod tests {
    use super::*;
    use crate::session::{OutboundFrame, OutboundSink};
    use notify::Watcher as _;
    use serde_json::Value;

    #[cfg(unix)]
    #[test]
    fn repeated_teardown_attempts_hit_the_hard_worker_cap() {
        let slots = Arc::new(Semaphore::new(WATCH_TEARDOWN_CONCURRENCY));
        let mut owners = Vec::new();
        let mut rejected = 0;
        for _ in 0..(WATCH_TEARDOWN_CONCURRENCY * 3) {
            let watcher = notify::RecommendedWatcher::new(|_| {}, notify::Config::default())
                .expect("create test watcher");
            match WatcherOwner::new_with_slots(watcher, Arc::clone(&slots)) {
                Ok(owner) => owners.push(owner),
                Err(_) => rejected += 1,
            }
        }
        assert_eq!(owners.len(), WATCH_TEARDOWN_CONCURRENCY);
        assert_eq!(rejected, WATCH_TEARDOWN_CONCURRENCY * 2);
        drop(owners);
    }

    fn scratch(name: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!("chatmux-watch-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("scratch dir");
        std::fs::canonicalize(&path).expect("canonical scratch")
    }

    fn open_frame(watch_id: &str, root: &Path) -> wire::RelayFsWatchOpen {
        wire::RelayFsWatchOpen {
            version: WORKSPACE_FRAME_VERSION,
            r#type: wire::TagFsWatchOpen::FsWatchOpen,
            watch_id: watch_id.to_owned(),
            root: None,
            actor_id: "user_1".to_owned(),
            trust: wire::TrustLevel::Observe,
            allowed_roots: Some(vec![root.to_string_lossy().into_owned()]),
        }
    }

    async fn next_frame(
        critical: &mut Receiver<OutboundFrame>,
        watch: &mut Receiver<OutboundFrame>,
        what: &str,
    ) -> Value {
        let frame = tokio::time::timeout(Duration::from_secs(10), async {
            tokio::select! { biased; frame = critical.recv() => frame, frame = watch.recv() => frame }
        })
            .await
            .unwrap_or_else(|_| panic!("no {what} frame within 10s"))
            .expect("channel open");
        serde_json::from_str(&frame.text).expect("valid frame json")
    }

    async fn wait_for_opening_to_finish(registry: &WatchRegistry, watch_id: &str) {
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let finished = registry
                    .sessions
                    .lock()
                    .map(|state| {
                        state.get(watch_id).map(|slot| slot.opening.is_none()).unwrap_or(true)
                    })
                    .unwrap_or(true);
                if finished {
                    return;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("watch setup did not finish");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn watch_streams_debounced_changes_for_a_write() {
        let root = scratch("stream");
        std::fs::write(root.join("seed.txt"), "seed\n").expect("seed");
        let (sink, mut critical, mut watch) = OutboundSink::channels();
        let registry = WatchRegistry::new(sink);
        registry.open(open_frame("w1", &root), None);
        let opened = next_frame(&mut critical, &mut watch, "opened").await;
        assert_eq!(opened["type"], "fs_watch_opened");
        assert_eq!(opened["watchId"], "w1");
        assert_eq!(opened["root"].as_str(), root.to_str());
        // Give the watcher backend a beat to arm before mutating.
        tokio::time::sleep(Duration::from_millis(400)).await;
        std::fs::write(root.join("fresh.txt"), "hello\n").expect("write");
        let event = loop {
            let frame = next_frame(&mut critical, &mut watch, "change").await;
            assert_eq!(frame["type"], "fs_watch_event");
            let changes = frame["changes"].as_array().expect("changes").clone();
            if changes.iter().any(|change| change["path"] == "fresh.txt") {
                break frame;
            }
        };
        assert_eq!(event["watchId"], "w1");
        registry.close("w1");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn invalid_replacement_preserves_the_existing_watch() {
        let root = scratch("invalid-replacement");
        let (sink, mut critical, mut watch) = OutboundSink::channels();
        let registry = WatchRegistry::new(sink);

        registry.open(open_frame("same", &root), None);
        let opened = next_frame(&mut critical, &mut watch, "first opened").await;
        assert_eq!(opened["type"], "fs_watch_opened");

        let mut invalid = open_frame("same", &root);
        invalid.root = Some(root.join("missing").to_string_lossy().into_owned());
        registry.open(invalid, None);
        let refusal = next_frame(&mut critical, &mut watch, "replacement refusal").await;
        assert_eq!(refusal["type"], "fs_watch_error");
        assert_eq!(refusal["code"], "not_found");

        // Validation happens before registry mutation. A change in the
        // original root proves that the refused replacement kept it active.
        tokio::time::sleep(Duration::from_millis(400)).await;
        std::fs::write(root.join("still-watched.txt"), "kept\n").expect("write");
        loop {
            let event = next_frame(&mut critical, &mut watch, "existing watch event").await;
            if event["type"] == "fs_watch_event"
                && event["changes"].as_array().is_some_and(|changes| {
                    changes.iter().any(|change| change["path"] == "still-watched.txt")
                })
            {
                break;
            }
        }
        registry.close("same");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn pending_openings_count_toward_the_session_cap() {
        let root = scratch("pending-cap");
        let (sink, mut critical, mut watch) = OutboundSink::channels();
        let registry = WatchRegistry::new(sink);

        // `open` reserves synchronously and only then yields to its setup
        // coordinator. Filling all slots back-to-back therefore exercises the
        // cap while every setup is still pending.
        for index in 0..WATCH_MAX_SESSIONS {
            registry.open(open_frame(&format!("pending-{index}"), &root), None);
        }
        let mut over_cap = open_frame("pending-over-cap", &root);
        over_cap.root = Some(root.to_string_lossy().into_owned());
        registry.open(over_cap, None);

        let mut saw_limit = false;
        for _ in 0..=WATCH_MAX_SESSIONS {
            let frame = next_frame(&mut critical, &mut watch, "pending cap response").await;
            if frame["type"] == "fs_watch_error" && frame["code"] == "watch_limit" {
                saw_limit = true;
                break;
            }
        }
        assert!(saw_limit, "a pending opening must consume a watch slot");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn failed_opened_enqueue_preserves_the_existing_watch() {
        let root = scratch("opened-queue-full");
        let (sink, mut critical, mut watch) = OutboundSink::channels();
        let registry = WatchRegistry::new(sink);

        registry.open(open_frame("same", &root), None);
        let opened = next_frame(&mut critical, &mut watch, "first opened").await;
        assert_eq!(opened["type"], "fs_watch_opened");
        let old_generation = registry
            .sessions
            .lock()
            .expect("state")
            .get("same")
            .and_then(|slot| slot.active.as_ref())
            .map(|active| active.generation)
            .expect("active watch");

        // Keep the critical queue full while the replacement prepares. The
        // replacement must not retire the old watch when its acknowledgement
        // cannot be admitted.
        for _ in 0..256 {
            assert!(registry.outbound.try_critical_text("{}".to_owned()).is_ok());
        }
        registry.open(open_frame("same", &root), None);
        wait_for_opening_to_finish(&registry, "same").await;
        let current_generation = registry
            .sessions
            .lock()
            .expect("state")
            .get("same")
            .and_then(|slot| slot.active.as_ref())
            .map(|active| active.generation);
        assert_eq!(current_generation, Some(old_generation));

        tokio::time::sleep(Duration::from_millis(400)).await;
        std::fs::write(root.join("still-watched.txt"), "kept\n").expect("write");
        let frame = tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let frame = watch.recv().await.expect("watch channel open");
                let value: Value = serde_json::from_str(&frame.text).expect("watch json");
                if value["type"] == "fs_watch_event"
                    && value["changes"].as_array().is_some_and(|changes| {
                        changes.iter().any(|change| change["path"] == "still-watched.txt")
                    })
                {
                    return value;
                }
            }
        })
        .await
        .expect("old watch did not survive queue failure");
        assert_eq!(frame["watchId"], "same");
        registry.close("same");
    }

    #[tokio::test]
    async fn completed_watch_invalidates_queued_frames() {
        let sessions = Arc::new(Mutex::new(HashMap::new()));
        let live = Arc::new(AtomicBool::new(true));
        let cancellation = CancellationToken::new();
        let task = tokio::spawn(async {});
        sessions.lock().unwrap().insert(
            "finished".to_owned(),
            WatchSlot {
                active: Some(ActiveWatch {
                    generation: 1,
                    live: Arc::clone(&live),
                    cancellation,
                    abort: task.abort_handle(),
                }),
                opening: None,
            },
        );
        finish_active("finished", 1, Arc::clone(&sessions));
        assert!(!live.load(Ordering::Acquire));
        assert!(sessions.lock().unwrap().is_empty());
    }

    #[test]
    fn failed_open_keeps_its_error_frame_live_until_delivery() {
        let (sink, mut critical, _) = OutboundSink::channels();
        let sessions = Arc::new(Mutex::new(HashMap::new()));
        let live = Arc::new(AtomicBool::new(true));
        let cancellation = CancellationToken::new();
        sessions.lock().unwrap().insert(
            "failed".to_owned(),
            WatchSlot {
                active: None,
                opening: Some(Opening {
                    generation: 1,
                    live: Arc::clone(&live),
                    cancellation: cancellation.clone(),
                    abort: None,
                }),
            },
        );
        finish_open_failure(
            "failed",
            1,
            live,
            cancellation,
            Arc::clone(&sessions),
            sink,
            wire::WorkspaceErrorCode::Failed,
            None,
        );
        let frame = critical.try_recv().expect("failure frame");
        assert!(frame.live.is_none(), "failure must not be fenced before delivery");
        let value: Value = serde_json::from_str(&frame.text).expect("failure json");
        assert_eq!(value["code"], "failed");
        assert!(value["message"].is_null(), "internal failure copy stays out of the wire frame");
    }

    #[tokio::test]
    async fn saturated_watch_bytes_reports_a_terminal_error() {
        let (sink, mut critical, _watch) = OutboundSink::channels();
        let payload = "x".repeat(2 << 20);
        let mut filled = 0;
        while filled < 8 && sink.try_watch_text(payload.clone()).is_ok() {
            filled += 1;
        }
        assert!(filled >= 3, "watch bytes must admit multiple frames");
        assert!(filled < 8, "watch bytes must stop before global bytes are exhausted");
        let cancellation = CancellationToken::new();
        let live = Arc::new(AtomicBool::new(true));
        let mut report = Box::pin(report_watch_failure("saturated", &sink, &cancellation, &live));
        let frame = tokio::select! {
            frame = critical.recv() => frame.expect("terminal error frame"),
            _ = &mut report => panic!("terminal report returned before delivery ack"),
        };
        let value: Value = serde_json::from_str(&frame.text).expect("error json");
        assert_eq!(value["type"], "fs_watch_error");
        assert_eq!(value["watchId"], "saturated");
        assert_eq!(value["code"], "failed");
        assert!(value["message"].is_null(), "terminal copy is localized by the client");
        frame.ack.expect("terminal delivery ack").send(()).expect("ack receiver");
        report.await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn watch_refuses_typed_and_respects_the_session_cap() {
        let root = scratch("refuse");
        let (sink, mut critical, mut watch) = OutboundSink::channels();
        let registry = WatchRegistry::new(sink);
        // A root outside the allowed list refuses path_forbidden.
        let mut outside = open_frame("w-out", &root);
        outside.root = Some("/etc".to_owned());
        registry.open(outside, None);
        let refusal = next_frame(&mut critical, &mut watch, "refusal").await;
        assert_eq!(refusal["type"], "fs_watch_error");
        assert_eq!(refusal["code"], "path_forbidden");
        // Session cap: the 17th watch refuses watch_limit.
        for index in 0..WATCH_MAX_SESSIONS {
            registry.open(open_frame(&format!("w{index}"), &root), None);
            let opened = next_frame(&mut critical, &mut watch, "opened").await;
            assert_eq!(opened["type"], "fs_watch_opened", "watch {index}");
        }
        let mut over_cap = open_frame("w-past-cap", &root);
        over_cap.root = Some(root.to_string_lossy().into_owned());
        registry.open(over_cap, None);
        let capped = next_frame(&mut critical, &mut watch, "watch_limit").await;
        assert_eq!(capped["type"], "fs_watch_error");
        assert_eq!(capped["code"], "watch_limit");
    }

    #[cfg(not(unix))]
    #[tokio::test]
    async fn scoped_watch_answers_typed_unsupported() {
        let root = scratch("unsupported-scope");
        let (sink, mut critical, mut watch) = OutboundSink::channels();
        let registry = WatchRegistry::new(sink);
        registry.open(open_frame("w-unsupported", &root), None);
        let refusal = next_frame(&mut critical, &mut watch, "unsupported refusal").await;
        assert_eq!(refusal["type"], "fs_watch_error");
        assert_eq!(refusal["watchId"], "w-unsupported");
        assert_eq!(refusal["code"], "unsupported_verb");
    }

    #[test]
    fn bursts_merge_and_cap_with_overflow() {
        let root = scratch("merge");
        let matcher = build_ignore_matcher(&root);
        let mut changes = Vec::new();
        let mut index = HashMap::new();
        let mut saw_ignore = false;
        let created =
            notify::Event::new(notify::EventKind::Create(notify::event::CreateKind::File))
                .add_path(root.join("a.txt"));
        let modified = notify::Event::new(notify::EventKind::Modify(
            notify::event::ModifyKind::Data(notify::event::DataChange::Content),
        ))
        .add_path(root.join("a.txt"));
        collect_changes(&root, &matcher, &created, &mut changes, &mut index, &mut saw_ignore);
        collect_changes(&root, &matcher, &modified, &mut changes, &mut index, &mut saw_ignore);
        assert_eq!(changes.len(), 1, "one path, one change");
        assert_eq!(changes[0].kind, wire::FsWatchChangeKind::Created, "created wins");
        // .git churn never leaks.
        let git_noise =
            notify::Event::new(notify::EventKind::Create(notify::event::CreateKind::File))
                .add_path(root.join(".git/index.lock"));
        collect_changes(&root, &matcher, &git_noise, &mut changes, &mut index, &mut saw_ignore);
        assert_eq!(changes.len(), 1);
        // A rename pair carries oldPath.
        let renamed = notify::Event::new(notify::EventKind::Modify(
            notify::event::ModifyKind::Name(notify::event::RenameMode::Both),
        ))
        .add_path(root.join("a.txt"))
        .add_path(root.join("b.txt"));
        collect_changes(&root, &matcher, &renamed, &mut changes, &mut index, &mut saw_ignore);
        let rename = changes.iter().find(|change| change.path == "b.txt").expect("rename");
        assert_eq!(rename.kind, wire::FsWatchChangeKind::Renamed);
        assert_eq!(rename.old_path.as_deref(), Some("a.txt"));
    }

    #[test]
    fn gitignored_paths_are_filtered_but_ignore_files_pass() {
        let root = scratch("ignore");
        std::fs::write(root.join(".gitignore"), "dist/\n").expect("gitignore");
        std::fs::create_dir_all(root.join(".git")).expect("fake repo marker");
        std::fs::create_dir_all(root.join("dist")).expect("dist");
        let matcher = build_ignore_matcher(&root);
        let mut changes = Vec::new();
        let mut index = HashMap::new();
        let mut saw_ignore = false;
        let ignored =
            notify::Event::new(notify::EventKind::Create(notify::event::CreateKind::File))
                .add_path(root.join("dist/bundle.js"));
        collect_changes(&root, &matcher, &ignored, &mut changes, &mut index, &mut saw_ignore);
        assert!(changes.is_empty(), "gitignored churn stays quiet: {changes:?}");
        let gitignore_edit = notify::Event::new(notify::EventKind::Modify(
            notify::event::ModifyKind::Data(notify::event::DataChange::Content),
        ))
        .add_path(root.join(".gitignore"));
        collect_changes(
            &root,
            &matcher,
            &gitignore_edit,
            &mut changes,
            &mut index,
            &mut saw_ignore,
        );
        assert_eq!(changes.len(), 1, "the ignore file itself reports");
        assert!(saw_ignore, "and schedules a matcher rebuild");
    }

    #[test]
    fn bounded_notify_queue_marks_overflow_without_losing_the_marker() {
        let (sender, mut receiver) = channel::<u8>(1);
        let overflowed = AtomicBool::new(false);
        let notify = Notify::new();
        try_enqueue_notify_event(&sender, &overflowed, &notify, 1);
        try_enqueue_notify_event(&sender, &overflowed, &notify, 2);
        assert!(overflowed.load(Ordering::Acquire));
        assert_eq!(receiver.try_recv().expect("first event"), 1);
        assert!(receiver.try_recv().is_err());
        assert!(overflowed.swap(false, Ordering::AcqRel));
        assert!(!overflowed.load(Ordering::Acquire));
    }
}
