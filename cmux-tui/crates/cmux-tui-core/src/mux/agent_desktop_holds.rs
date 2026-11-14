//! One notification per agent event for an agent's own desktop
//! notification (W6-D, bench r5: one Claude permission request was three
//! unread rows).
//!
//! Claude Code (OSC 777) and Codex (OSC 9) print their own desktop
//! notification for a permission wait or a finished turn, and their hooks
//! post the same event (`agent_hook_notification`). The two arrive in
//! either order: a hook is a separate process, the desktop notification is
//! terminal output. A desktop notification carries no app and no kind, so it
//! is dropped only as a copy: when the same terminal's hooks posted a
//! permission or done notification within [`AGENT_DESKTOP_DEDUPE_WINDOW`]
//! before it, or post one within that window after it. Until then a desktop
//! notification of a terminal whose notifying hooks are live
//! (`Mux::notifying_agent_hooks_for`) is held; at the end of the window it
//! posts. Every other desktop notification posts at once, and so does every
//! notification of any other terminal.
//!
//! A deadline is a one-shot condition-variable wait on a worker thread, never
//! a polling loop. The window is read from an injected
//! [`AgentNotificationClock`]: tests move it by hand.

use super::*;
use crate::terminal_metadata::TerminalNotification;

/// How far apart an agent's own desktop notification and its hook
/// notification may be and still count as one event.
pub(crate) const AGENT_DESKTOP_DEDUPE_WINDOW: Duration = Duration::from_secs(2);

/// The time source of the dedupe window.
pub(crate) trait AgentNotificationClock: Send + Sync {
    /// Now, on this clock.
    fn now(&self) -> Instant;

    /// Moves a hand-driven test clock forward; the system clock ignores it.
    #[cfg(test)]
    fn advance(&self, _by: Duration) {}
}

/// The monotonic system clock: the daemon's clock.
// Test builds construct the manual clock instead.
#[cfg_attr(test, allow(dead_code))]
pub(crate) struct SystemAgentNotificationClock;

impl AgentNotificationClock for SystemAgentNotificationClock {
    fn now(&self) -> Instant {
        Instant::now()
    }
}

/// A clock that moves only when a test advances it, so a test passes the
/// window without real waiting.
#[cfg(test)]
pub(crate) struct ManualAgentNotificationClock {
    now: Mutex<Instant>,
}

#[cfg(test)]
impl Default for ManualAgentNotificationClock {
    fn default() -> Self {
        Self { now: Mutex::new(Instant::now()) }
    }
}

#[cfg(test)]
impl AgentNotificationClock for ManualAgentNotificationClock {
    fn now(&self) -> Instant {
        *self.now.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn advance(&self, by: Duration) {
        *self.now.lock().unwrap_or_else(PoisonError::into_inner) += by;
    }
}

/// The held desktop notifications and the recent hook notifications, per
/// terminal. Its lock is a leaf: nothing else is locked while it is held.
pub(crate) struct AgentDesktopHolds {
    clock: Arc<dyn AgentNotificationClock>,
    state: Mutex<HoldState>,
    /// Wakes the worker: a new hold, a clock move, or the close.
    changed: Condvar,
    /// The owner, bound once right after it is built.
    mux: OnceLock<Weak<Mux>>,
}

#[derive(Default)]
struct HoldState {
    /// When each terminal's hooks last posted a permission or done
    /// notification.
    hook_posted: HashMap<TerminalPublicId, Instant>,
    held: Vec<HeldDesktop>,
    worker_running: bool,
    closed: bool,
}

/// A desktop notification that waits for its window.
struct HeldDesktop {
    terminal: TerminalPublicId,
    /// The surface the terminal's reader posted it for.
    surface: SurfaceId,
    notification: TerminalNotification,
    until: Instant,
}

impl AgentDesktopHolds {
    /// Holds read the window from `clock`.
    pub(crate) fn new(clock: Arc<dyn AgentNotificationClock>) -> Self {
        Self {
            clock,
            state: Mutex::new(HoldState::default()),
            changed: Condvar::new(),
            mux: OnceLock::new(),
        }
    }

    pub(super) fn bind(&self, mux: Weak<Mux>) {
        let _ = self.mux.set(mux);
    }

    fn lock(&self) -> MutexGuard<'_, HoldState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// `terminal`'s hooks posted a permission or done notification: a
    /// desktop notification held for it is its copy and is dropped, and one
    /// within the window after now will be.
    pub(super) fn hook_posted(&self, terminal: &TerminalPublicId) {
        let now = self.clock.now();
        let mut state = self.lock();
        state.hook_posted.retain(|_, at| within_window(now, *at));
        state.hook_posted.insert(terminal.clone(), now);
        state.held.retain(|held| held.terminal != *terminal);
        self.changed.notify_all();
    }

    /// A desktop notification of `terminal`, whose notifying hooks are live:
    /// dropped when its hooks posted a permission or done notification
    /// within the window, else held until the window ends. Returns it when
    /// it must post now (the session ends and holds nothing more).
    fn admit(
        self: &Arc<Self>,
        terminal: TerminalPublicId,
        surface: SurfaceId,
        notification: TerminalNotification,
    ) -> Option<TerminalNotification> {
        let now = self.clock.now();
        let mut state = self.lock();
        if state.hook_posted.get(&terminal).is_some_and(|at| within_window(now, *at)) {
            return None;
        }
        if state.closed {
            return Some(notification);
        }
        state.held.push(HeldDesktop {
            terminal,
            surface,
            notification,
            until: now + AGENT_DESKTOP_DEDUPE_WINDOW,
        });
        self.changed.notify_all();
        if state.worker_running {
            return None;
        }
        // An owner not bound yet (construction) posts it at the terminal's
        // end or the session's.
        let mux = self.mux.get().cloned()?;
        state.worker_running = true;
        drop(state);
        let holds = Arc::clone(self);
        let spawned = std::thread::Builder::new()
            .name("agent-desktop-holds".into())
            .spawn(move || run_worker(&holds, &mux));
        if spawned.is_err() {
            // No worker: what is held posts at the next admit that starts
            // one, the terminal's end or the session's.
            self.lock().worker_running = false;
        }
        None
    }

    /// Takes the held notifications that are due now, or all of `terminal`'s
    /// (its output ended), or all (`everything`, the shutdown).
    fn take(&self, terminal: Option<&TerminalPublicId>, everything: bool) -> Vec<HeldDesktop> {
        let now = self.clock.now();
        let mut state = self.lock();
        let (due, kept): (Vec<_>, Vec<_>) =
            std::mem::take(&mut state.held).into_iter().partition(|held| {
                everything
                    || held.until <= now
                    || terminal.is_some_and(|terminal| held.terminal == *terminal)
            });
        state.held = kept;
        due
    }

    /// The worker ends: nothing it held posts (the owner is gone).
    fn stop_worker(&self) {
        let mut state = self.lock();
        state.held.clear();
        state.worker_running = false;
    }
}

/// Whether `at` is at most the window before `now`.
fn within_window(now: Instant, at: Instant) -> bool {
    now.saturating_duration_since(at) <= AGENT_DESKTOP_DEDUPE_WINDOW
}

/// The worker: post what is due, then wait for the earliest hold's end. It
/// holds only a weak owner reference while it waits, and ends when nothing
/// is held, at the close, or when the owner is gone.
fn run_worker(holds: &AgentDesktopHolds, mux: &Weak<Mux>) {
    loop {
        let due = holds.take(None, false);
        if !due.is_empty() {
            let Some(owner) = mux.upgrade() else {
                holds.stop_worker();
                return;
            };
            for held in due {
                owner.post_terminal_notification_now(held.surface, held.notification);
            }
        }
        if mux.strong_count() == 0 {
            holds.stop_worker();
            return;
        }
        let mut state = holds.lock();
        let next = state.held.iter().map(|held| held.until).min();
        let Some(next) = next.filter(|_| !state.closed) else {
            state.worker_running = false;
            return;
        };
        let left = next.saturating_duration_since(holds.clock.now());
        if !left.is_zero() {
            drop(holds.changed.wait_timeout(state, left));
        }
    }
}

impl Mux {
    /// Hold or drop a desktop notification of `terminal`, whose notifying
    /// hooks are live (see the module docs).
    pub(super) fn admit_agent_desktop_notification(
        &self,
        terminal: TerminalPublicId,
        surface: SurfaceId,
        notification: TerminalNotification,
    ) {
        if let Some(notification) = self.agent_desktop_holds.admit(terminal, surface, notification)
        {
            self.post_terminal_notification_now(surface, notification);
        }
    }

    /// `terminal`'s output ended: post its held desktop notifications now,
    /// while the terminal still has its tab.
    pub(super) fn release_agent_desktop_notifications_of(&self, terminal: &TerminalPublicId) {
        for held in self.agent_desktop_holds.take(Some(terminal), false) {
            self.post_terminal_notification_now(held.surface, held.notification);
        }
    }

    /// A view client announced its attach, or a view client that did so
    /// left: post every held desktop notification now, so the person sees
    /// it on the client they use now. A plain client (a CLI call, a status
    /// query or a hook emit) does not call this. The dedupe keeps working
    /// for later notifications.
    pub(crate) fn post_held_agent_desktop_notifications(&self) {
        for held in self.agent_desktop_holds.take(None, true) {
            self.post_terminal_notification_now(held.surface, held.notification);
        }
    }

    /// The session ends: post every held desktop notification now and hold
    /// no more. Every stop reaches it first (`shutdown`,
    /// `request_daemon_shutdown`), and again after the terminal readers
    /// stopped (`finish_terminal_publications`). A post is a durable
    /// notification: `notification list` shows it after the restart.
    pub(super) fn release_all_agent_desktop_notifications(&self) {
        self.agent_desktop_holds.lock().closed = true;
        self.agent_desktop_holds.changed.notify_all();
        for held in self.agent_desktop_holds.take(None, true) {
            self.post_terminal_notification_now(held.surface, held.notification);
        }
    }
}

#[cfg(test)]
impl Mux {
    /// How many desktop notifications wait in the agent dedupe hold now.
    pub(crate) fn held_agent_desktop_notifications_for_test(&self) -> usize {
        self.agent_desktop_holds.lock().held.len()
    }

    /// Moves the clock of the agent desktop notification dedupe forward by
    /// `by`, then posts the held desktop notifications that are due, before
    /// it returns.
    pub(crate) fn advance_agent_notification_clock_for_test(&self, by: Duration) {
        self.agent_desktop_holds.clock.advance(by);
        self.agent_desktop_holds.changed.notify_all();
        for held in self.agent_desktop_holds.take(None, false) {
            self.post_terminal_notification_now(held.surface, held.notification);
        }
    }
}
