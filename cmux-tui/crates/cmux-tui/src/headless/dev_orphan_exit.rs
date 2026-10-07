//! DEV owner orphan exit. A tagged DEV app starts its session owner
//! (`cmux-app-<tag>`) detached, so it outlives the app on purpose, and
//! scripts delete throwaway tag bundles without stopping it. In a DEV build
//! only (the bundle around this executable is `com.cmuxterm.app.debug.<tag>`)
//! the OWNER stops itself when no client of any kind has been connected for
//! [`ORPHAN_EXIT_DELAY`] AND either its own executable is gone or it has no
//! live terminal. With its executable present and a live terminal it never
//! stops. It never ends a terminal and never signals a terminal host: the
//! hosts keep running for the next owner of the session to adopt (live
//! shells are the recovery design). Release builds never start the watcher.
//!
//! One waiting thread, woken by client arrivals and departures or by its
//! deadline on an injected clock. A deleted executable sends no event, so
//! after the delay an owner that keeps live terminals looks again every
//! [`ORPHAN_RECHECK`] (the daemon's idle-close reaper uses the same kind of
//! bounded interval).

use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

/// How long an owner must have had no client before it may stop.
pub(crate) const ORPHAN_EXIT_DELAY: Duration = Duration::from_secs(60 * 60);
/// How often an owner past the delay that keeps live terminals looks for
/// its executable again.
pub(crate) const ORPHAN_RECHECK: Duration = Duration::from_secs(10 * 60);

/// Whether `bundle_id` is a DEV build's (`com.cmuxterm.app.debug[.<tag>]`).
pub(crate) fn is_dev_build(bundle_id: Option<&str>) -> bool {
    bundle_id.is_some_and(crate::app_identity::is_debug_bundle)
}

/// The bundle id of the app around `exe`, from its Info.plist only (never an
/// inherited `CMUX_BUNDLE_ID`), read once at start: once the bundle is
/// deleted it cannot be read.
pub(crate) fn bundle_id_of(exe: &Path) -> Option<String> {
    crate::app_identity::AppIdentity::detect(|_| None, Some(exe))?.bundle_id
}

/// What the owner can observe, read only when a decision needs it.
pub(crate) trait OrphanFacts: Send + Sync {
    /// Connected clients of any role.
    fn clients(&self) -> usize;
    fn executable_present(&self) -> bool;
    /// Live terminals; `None` when the registry could not be read (the owner
    /// then keeps its terminals).
    fn live_terminals(&self) -> Option<usize>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Decision {
    /// A client is connected: wait for a change.
    Serve,
    /// Look again after this long (or on a change).
    Wait(Duration),
    /// Stop the owner; terminals and their hosts keep running.
    Exit,
}

/// The policy. `idle_since` is when the owner last had no client (start, or
/// the last client's departure); `None` while one is connected.
pub(crate) fn decide(
    idle_since: Option<Instant>,
    now: Instant,
    facts: &dyn OrphanFacts,
) -> Decision {
    let Some(since) = idle_since else { return Decision::Serve };
    let idle = now.saturating_duration_since(since);
    if idle < ORPHAN_EXIT_DELAY {
        return Decision::Wait(ORPHAN_EXIT_DELAY - idle);
    }
    if orphaned(facts) { Decision::Exit } else { Decision::Wait(ORPHAN_RECHECK) }
}

/// The executable is gone, or no terminal lives (an unreadable registry
/// keeps the owner).
pub(crate) fn orphaned(facts: &dyn OrphanFacts) -> bool {
    !facts.executable_present() || facts.live_terminals() == Some(0)
}

/// The watcher's time source. Tests inject a fake.
pub(crate) trait OrphanClock: Send + Sync {
    fn now(&self) -> Instant;

    /// Waits on `changed` until it is notified or `timeout` passes on this
    /// clock (a spurious wake is fine: the caller checks again).
    fn wait_timeout<'a>(
        &self,
        changed: &Condvar,
        state: MutexGuard<'a, WatchState>,
        timeout: Duration,
    ) -> MutexGuard<'a, WatchState>;
}

pub(crate) struct SystemClock;

impl OrphanClock for SystemClock {
    fn now(&self) -> Instant {
        Instant::now()
    }

    fn wait_timeout<'a>(
        &self,
        changed: &Condvar,
        state: MutexGuard<'a, WatchState>,
        timeout: Duration,
    ) -> MutexGuard<'a, WatchState> {
        changed.wait_timeout(state, timeout).unwrap_or_else(PoisonError::into_inner).0
    }
}

#[derive(Debug, Default)]
pub(crate) struct WatchState {
    idle_since: Option<Instant>,
    stopped: bool,
}

pub(crate) struct OrphanWatch {
    clock: Arc<dyn OrphanClock>,
    facts: Arc<dyn OrphanFacts>,
    state: Mutex<WatchState>,
    changed: Condvar,
}

impl OrphanWatch {
    /// Idle from now unless a client is connected.
    pub(crate) fn new(clock: Arc<dyn OrphanClock>, facts: Arc<dyn OrphanFacts>) -> Arc<Self> {
        let watch = Arc::new(Self {
            clock,
            facts,
            state: Mutex::new(WatchState::default()),
            changed: Condvar::new(),
        });
        watch.clients_changed();
        watch
    }

    fn lock(&self) -> MutexGuard<'_, WatchState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// A client connected or left. Call it with no registry lock held. The
    /// count is read under the watch lock, so concurrent calls cannot leave
    /// a stale answer (watch lock, then registry lock; the registry never
    /// calls in while it holds its own lock).
    pub(crate) fn clients_changed(&self) {
        let mut state = self.lock();
        if self.facts.clients() > 0 {
            state.idle_since = None;
        } else if state.idle_since.is_none() {
            state.idle_since = Some(self.clock.now());
        }
        drop(state);
        self.changed.notify_all();
    }

    /// Ends [`OrphanWatch::wait`] with false.
    pub(crate) fn stop(&self) {
        self.lock().stopped = true;
        self.changed.notify_all();
    }

    /// Blocks until the policy says [`Decision::Exit`] (true) or
    /// [`OrphanWatch::stop`] (false).
    pub(crate) fn wait(&self) -> bool {
        let mut state = self.lock();
        loop {
            if state.stopped {
                return false;
            }
            let since = state.idle_since;
            // The facts may take locks of their own: read them unlocked.
            drop(state);
            let decision = decide(since, self.clock.now(), self.facts.as_ref());
            state = self.lock();
            if state.stopped {
                return false;
            }
            if state.idle_since != since {
                continue;
            }
            state = match decision {
                Decision::Exit => return true,
                Decision::Serve => self.changed.wait(state).unwrap_or_else(PoisonError::into_inner),
                Decision::Wait(timeout) => self.clock.wait_timeout(&self.changed, state, timeout),
            };
        }
    }
}

/// The real owner's facts.
pub(crate) struct OwnerFacts {
    pub(crate) mux: std::sync::Weak<cmux_tui_core::Mux>,
    pub(crate) executable: PathBuf,
}

impl OrphanFacts for OwnerFacts {
    fn clients(&self) -> usize {
        self.mux.upgrade().map_or(0, |mux| mux.client_count())
    }

    fn executable_present(&self) -> bool {
        self.executable.exists()
    }

    fn live_terminals(&self) -> Option<usize> {
        self.mux.upgrade()?.live_terminal_count().ok()
    }
}

/// The running watcher; [`OrphanExit::stop`] ends and joins it.
pub(crate) struct OrphanExit {
    watch: Arc<OrphanWatch>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl OrphanExit {
    pub(crate) fn stop(mut self) {
        self.watch.stop();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Starts the watcher for this headless owner when it is a DEV app owner.
/// On exit it stops the owner as a plain `server stop` does; terminals and
/// their hosts keep running.
pub(crate) fn start_for_owner(mux: &Arc<cmux_tui_core::Mux>) -> Option<OrphanExit> {
    let executable = std::env::current_exe().ok()?;
    let session = mux.session.clone();
    let stopping = Arc::downgrade(mux);
    start(&mux.session, executable, mux, move |facts| {
        let Some(mux) = stopping.upgrade() else { return true };
        let stopped = cmux_tui_core::server::stop_orphaned_owner(&mux, || orphaned(facts));
        if stopped {
            crate::client_log::stderr_log!(
                "lifecycle",
                "{BIN}: stopped orphaned DEV owner {session} (no client for an hour); its terminals keep running"
            );
        }
        stopped
    })
}

/// Starts the watcher for a DEV app owner; `None` for any other owner
/// (release builds, sessions other than `cmux-app-<tag>` (an untagged DEV
/// build's `cmux-app` included), no bundle). `stop_owner` runs on the
/// watcher thread when the policy says exit, with the facts to check again
/// under its fence; it returns false when it did not stop the owner (a
/// client came back, or a terminal started), and the watcher keeps watching.
pub(crate) fn start(
    session: &str,
    executable: PathBuf,
    mux: &Arc<cmux_tui_core::Mux>,
    stop_owner: impl Fn(&dyn OrphanFacts) -> bool + Send + 'static,
) -> Option<OrphanExit> {
    if !session.starts_with("cmux-app-") || !is_dev_build(bundle_id_of(&executable).as_deref()) {
        return None;
    }
    let facts = Arc::new(OwnerFacts { mux: Arc::downgrade(mux), executable });
    Some(spawn(OrphanWatch::new(Arc::new(SystemClock), facts), mux, stop_owner))
}

fn spawn(
    watch: Arc<OrphanWatch>,
    mux: &Arc<cmux_tui_core::Mux>,
    stop_owner: impl Fn(&dyn OrphanFacts) -> bool + Send + 'static,
) -> OrphanExit {
    let observer = Arc::downgrade(&watch);
    mux.set_client_presence_observer(move || {
        if let Some(watch) = observer.upgrade() {
            watch.clients_changed();
        }
    });
    // A client that connected before the observer was installed.
    watch.clients_changed();
    let waiter = watch.clone();
    let thread = std::thread::Builder::new()
        .name("dev-orphan-exit".into())
        .spawn(move || {
            while waiter.wait() {
                if stop_owner(waiter.facts.as_ref()) {
                    return;
                }
                // Not stopped (a client came back, or a terminal started):
                // start the delay again.
                waiter.restart_after_failed_exit();
            }
        })
        .ok();
    OrphanExit { watch, thread }
}

impl OrphanWatch {
    fn restart_after_failed_exit(&self) {
        self.lock().idle_since = None;
        self.clients_changed();
    }
}

#[cfg(test)]
#[path = "dev_orphan_exit_tests.rs"]
mod tests;
