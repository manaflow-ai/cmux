//! Reconnecting the TUI to its session after the session daemon left.
//!
//! `cmux daemon restart` (and an update or app handoff) replaces the daemon
//! of a session: the old daemon sends `daemon-shutdown`, closes every client
//! and exits, and a new daemon adopts the same terminals on the same socket.
//! A plain session client keeps its view, shows "reconnecting" in the status
//! line, and connects again until a daemon answers: quickly for the notice's
//! window, then every [`SLOW_DELAY`] for as long as it takes (it never gives
//! up and exits; the person can still detach or quit). The new session is
//! installed in place the way a machine switch installs one. Leo,
//! 2026-11-24: "let's just keep optimistically connecting and reinforcing
//! the connection". After
//! `cmux daemon stop` (the notice says `restart: false`) the client exits
//! with a message instead.

use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crossbeam_channel::{RecvTimeoutError, Sender as SyncSender};

use crate::app::App;
use crate::app::client_view::preserve_client_view;
use crate::app::events::{AppEvent, EventCancellation, send_bounded_cancelable};
use crate::app::frame_geometry::content_size_for_rect;
use crate::app::host_input::{InputClass, TerminalInput};
use crate::app::machine_worker::{MachineSessionPreparation, PreparedMachineSession};
use crate::app::mux_ingress::prepare_ordered_session;
use crate::app::render_pacing::RenderAction;
use crate::localization;
use crate::session::{DaemonShutdownNotice, Session};

/// Opens a new connection to the session this client attached to.
pub(crate) type SessionReconnector = Arc<dyn Fn() -> anyhow::Result<Session> + Send + Sync>;

/// How long the client tries quickly after the daemon announced a restart.
pub(super) const RESTART_WINDOW: Duration = Duration::from_secs(30);
/// How long the client tries quickly when the daemon announced its shutdown
/// without saying whether a replacement follows (an older daemon, an app or update
/// handoff).
pub(super) const UNANNOUNCED_WINDOW: Duration = Duration::from_secs(10);
const FIRST_DELAY: Duration = Duration::from_millis(100);
const MAX_DELAY: Duration = Duration::from_secs(1);
/// The wait between attempts once the quick window has passed: forever.
pub(super) const SLOW_DELAY: Duration = Duration::from_secs(5);

/// What the client does when its session's event stream ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum StreamLossPlan {
    /// Connect again, quickly for `window` and then slowly until it does,
    /// keeping the view.
    Reconnect { window: Duration },
    /// The session was stopped: exit and say so.
    Stopped,
    /// Not a daemon departure this client can follow: the existing exit path.
    Unchanged,
}

/// Decides what follows the end of the event stream.
///
/// `can_reconnect` is false for clients without a [`SessionReconnector`]
/// (machine, provider, scoped and in-process clients keep their own paths).
/// Only a daemon that announced its shutdown is followed: a connection that
/// closed with no notice (a crash, or this client was disconnected on
/// purpose) keeps the existing exit, so a kicked client never comes back.
pub(super) fn plan_for_stream_loss(
    can_reconnect: bool,
    notice: Option<DaemonShutdownNotice>,
) -> StreamLossPlan {
    if !can_reconnect {
        return StreamLossPlan::Unchanged;
    }
    match notice {
        Some(DaemonShutdownNotice::Restart) => StreamLossPlan::Reconnect { window: RESTART_WINDOW },
        Some(DaemonShutdownNotice::Stop) => StreamLossPlan::Stopped,
        Some(DaemonShutdownNotice::Unspecified) => {
            StreamLossPlan::Reconnect { window: UNANNOUNCED_WINDOW }
        }
        None => StreamLossPlan::Unchanged,
    }
}

/// The waits between connection attempts: 100 ms doubling to 1 s until
/// `window` from the start has passed, then [`SLOW_DELAY`], never an end.
#[derive(Debug)]
pub(super) struct ReconnectBackoff {
    quick_until: Instant,
    next: Duration,
}

impl ReconnectBackoff {
    pub(super) fn new(started: Instant, window: Duration) -> Self {
        Self { quick_until: started + window, next: FIRST_DELAY }
    }

    /// The wait before the next attempt. Inside the window the last quick
    /// wait is cut short so an attempt falls at its end; after it, every
    /// wait is [`SLOW_DELAY`].
    pub(super) fn next_delay(&mut self, now: Instant) -> Duration {
        let Some(remaining) =
            self.quick_until.checked_duration_since(now).filter(|left| !left.is_zero())
        else {
            return SLOW_DELAY;
        };
        let delay = self.next.min(remaining);
        self.next = (self.next * 2).min(MAX_DELAY);
        delay
    }
}

/// The reconnect state of one App: the way back to the session, the attempt
/// in flight, and the line printed after the TUI exits.
#[derive(Default)]
pub(super) struct DaemonReconnect {
    reconnector: Option<SessionReconnector>,
    attempt: Option<ReconnectAttempt>,
    pub(super) exit_notice: Option<String>,
}

struct ReconnectAttempt {
    cancellation: EventCancellation,
    window: Duration,
    // Detached on drop: a connect in flight ends on its own deadline, and
    // quitting the TUI never waits for it.
    _thread: JoinHandle<()>,
}

impl Drop for ReconnectAttempt {
    fn drop(&mut self) {
        self.cancellation.cancel();
    }
}

/// What a reconnect attempt reports to the event loop: it only ever ends
/// connected (or cancelled, with no outcome).
#[derive(Debug, PartialEq, Eq)]
pub(super) enum ReconnectOutcome<T> {
    Connected(T),
}

/// The outcome the worker sends: a session ready to install.
pub(super) type SessionReconnectOutcome = ReconnectOutcome<Box<PreparedMachineSession>>;

impl DaemonReconnect {
    pub(super) fn new(reconnector: Option<SessionReconnector>) -> Self {
        Self { reconnector, attempt: None, exit_notice: None }
    }

    pub(super) fn can_reconnect(&self) -> bool {
        self.reconnector.is_some()
    }

    pub(super) fn in_progress(&self) -> bool {
        self.attempt.is_some()
    }

    /// Ends the attempt in flight. Returns its window, or `None` when no
    /// attempt was running (a late outcome of a cancelled one).
    pub(super) fn finish(&mut self) -> Option<Duration> {
        self.attempt.take().map(|attempt| attempt.window)
    }

    /// Starts connecting again on a worker thread. Its outcome arrives as
    /// [`AppEvent::DaemonReconnect`].
    pub(super) fn start(
        &mut self,
        window: Duration,
        label: String,
        preparation: MachineSessionPreparation,
        app_events: SyncSender<AppEvent>,
    ) -> anyhow::Result<()> {
        let Some(reconnector) = self.reconnector.clone() else {
            anyhow::bail!("this client has no way back to its session");
        };
        let cancellation = EventCancellation::new();
        let worker_cancellation = cancellation.clone();
        let thread =
            std::thread::Builder::new().name("daemon-reconnect".into()).spawn(move || {
                let outcome = reconnect_until(window, &worker_cancellation, Instant::now, || {
                    let session = reconnector()?;
                    prepare_reconnected_session(session, label.clone(), &preparation, &app_events)
                        .map(Box::new)
                });
                if let Some(outcome) = outcome {
                    let _ = send_bounded_cancelable(
                        &app_events,
                        AppEvent::DaemonReconnect(outcome),
                        &worker_cancellation,
                    );
                }
            })?;
        self.attempt = Some(ReconnectAttempt { cancellation, window, _thread: thread });
        Ok(())
    }
}

/// Runs `connect` until it succeeds, waiting [`ReconnectBackoff`] delays
/// between attempts (quick for `window`, read on `now`, then slow). Returns
/// `None` when cancelled.
pub(super) fn reconnect_until<T>(
    window: Duration,
    cancellation: &EventCancellation,
    now: impl Fn() -> Instant,
    connect: impl FnMut() -> anyhow::Result<T>,
) -> Option<ReconnectOutcome<T>> {
    // A bounded wait that a cancellation (the TUI quitting) cuts short.
    let wait =
        |delay| matches!(cancellation.receiver.recv_timeout(delay), Err(RecvTimeoutError::Timeout));
    reconnect_until_with_wait(window, now, wait, connect)
}

/// [`reconnect_until`] with its wait given: `wait(delay)` waits, false when
/// cancelled.
pub(super) fn reconnect_until_with_wait<T>(
    window: Duration,
    now: impl Fn() -> Instant,
    mut wait: impl FnMut(Duration) -> bool,
    mut connect: impl FnMut() -> anyhow::Result<T>,
) -> Option<ReconnectOutcome<T>> {
    let mut backoff = ReconnectBackoff::new(now(), window);
    loop {
        if !wait(backoff.next_delay(now())) {
            return None;
        }
        match connect() {
            Ok(connected) => return Some(ReconnectOutcome::Connected(connected)),
            Err(error) => {
                crate::client_log::info("reconnect", &format!("attempt failed: {error:#}"));
            }
        }
    }
}

/// The reconnected session, ready to install: its event worker starts paused
/// and its tree is the new daemon's. Unlike a first start, an empty session
/// gets no new workspace: the replacement may still be restoring it.
fn prepare_reconnected_session(
    session: Session,
    label: String,
    preparation: &MachineSessionPreparation,
    app_events: &SyncSender<AppEvent>,
) -> anyhow::Result<PreparedMachineSession> {
    let (session, event_worker, mux_titles, mux_recovery_generation) = prepare_ordered_session(
        session,
        preparation.pty_input.clone(),
        app_events.clone(),
        preparation.generation,
        preparation.surface_filter,
    )?;
    let tree = session.tree();
    Ok(PreparedMachineSession {
        session,
        event_worker,
        generation: preparation.generation,
        mux_titles,
        mux_recovery_generation,
        tree,
        label,
        session_available: true,
        machine: None,
    })
}

impl App {
    /// Whether this client follows its daemon's departure: a plain session
    /// client with a way back. Machine, scoped and in-process clients keep
    /// their own paths.
    fn follows_daemon_departures(&self) -> bool {
        self.daemon_reconnect.can_reconnect()
            && self.machine_ui.is_none()
            && self.surface_only.is_none()
            && self.owner_mux.is_none()
    }

    /// Whether the daemon's shutdown notice ends the event loop now. A
    /// client that follows departures stays until the stream's end
    /// (`MuxEvent::Empty`, sent right after the notice) has reconnected it
    /// or set it to quit.
    pub(super) fn daemon_departure_ends_event_loop(&self) -> bool {
        self.session.daemon_shutdown_requested()
            && !self.daemon_reconnect.in_progress()
            && !self.follows_daemon_departures()
    }

    /// The event stream ended: reconnect, exit with the stop message, or
    /// `None` for the existing exit path. Only a plain session client
    /// reconnects; machine, scoped and in-process clients keep theirs.
    pub(super) fn follow_daemon_departure(&mut self) -> Option<RenderAction> {
        if self.daemon_reconnect.in_progress() {
            // The connection's end after the notice that started it.
            return Some(RenderAction::None);
        }
        let plan = plan_for_stream_loss(
            self.follows_daemon_departures(),
            self.session.daemon_shutdown_notice(),
        );
        let runtime = &localization::catalog().runtime;
        match plan {
            StreamLossPlan::Unchanged => None,
            StreamLossPlan::Stopped => {
                crate::client_log::info("reconnect", "the session daemon stopped");
                self.daemon_reconnect.exit_notice =
                    Some(runtime.session_stopped(&self.session_label));
                self.quit = true;
                Some(RenderAction::None)
            }
            StreamLossPlan::Reconnect { window } => {
                crate::client_log::info(
                    "reconnect",
                    &format!(
                        "the session daemon left; reconnecting (quickly for {} s, then every {} s)",
                        window.as_secs(),
                        SLOW_DELAY.as_secs()
                    ),
                );
                self.start_daemon_reconnect(window)
            }
        }
    }

    /// A connection that broke with no shutdown notice (the daemon crashed,
    /// the socket dropped) is followed the way an unannounced departure is:
    /// the client reconnects for [`UNANNOUNCED_WINDOW`] instead of exiting
    /// with "reconnect" advice whose only answer is yes. `None` when this
    /// client has no reconnector (machine, provider, scoped, in-process).
    pub(super) fn reconnect_after_transport_loss(&mut self) -> Option<RenderAction> {
        if self.daemon_reconnect.in_progress() {
            return Some(RenderAction::None);
        }
        if !self.follows_daemon_departures() || self.session.disconnected_by_peer() {
            return None;
        }
        crate::client_log::info(
            "reconnect",
            &format!(
                "the session connection broke; reconnecting for {} s",
                UNANNOUNCED_WINDOW.as_secs()
            ),
        );
        self.start_daemon_reconnect(UNANNOUNCED_WINDOW)
    }

    fn start_daemon_reconnect(&mut self, window: Duration) -> Option<RenderAction> {
        let preparation = MachineSessionPreparation {
            initial_size: content_size_for_rect(
                self.content_area,
                self.config.scrollbar.position,
                self.config.pane.padding,
            ),
            generation: self.session_generation.wrapping_add(1).max(1),
            pty_input: self.pty_input.sender(),
            surface_filter: self.surface_only,
        };
        if let Err(error) = self.daemon_reconnect.start(
            window,
            self.session_label.clone(),
            preparation,
            self.app_events.clone(),
        ) {
            crate::client_log::error("reconnect", &format!("{error:#}"));
            return None;
        }
        Some(self.show_reconnecting())
    }

    /// Puts "reconnecting" back on the status line.
    pub(super) fn show_reconnecting(&mut self) -> RenderAction {
        self.status_message =
            Some(localization::catalog().runtime.session_reconnecting(&self.session_label));
        RenderAction::Draw
    }

    /// Whether input for the departed daemon is dropped: keys, pastes and
    /// clicks while the client reconnects. Frontend actions (detach, quit)
    /// still run.
    pub(super) fn drops_input_while_reconnecting(&self, input: &TerminalInput) -> bool {
        self.daemon_reconnect.in_progress()
            && input.is_routable()
            && input.class() != InputClass::FrontendAction
    }

    pub(super) fn on_daemon_reconnect(
        &mut self,
        outcome: SessionReconnectOutcome,
    ) -> anyhow::Result<RenderAction> {
        if self.daemon_reconnect.finish().is_none() {
            return Ok(RenderAction::None);
        }
        let runtime = &localization::catalog().runtime;
        let ReconnectOutcome::Connected(prepared) = outcome;
        let mut prepared = *prepared;
        // Keep this client's workspace, screen, pane and tab where the new
        // daemon still has them.
        preserve_client_view(&self.tree, &mut prepared.tree);
        self.install_prepared_machine_session(prepared, true);
        crate::client_log::info("reconnect", "reconnected to the session daemon");
        self.status_message = Some(runtime.session_reconnected(&self.session_label));
        Ok(RenderAction::Draw)
    }
}

#[cfg(test)]
#[path = "daemon_reconnect_tests.rs"]
mod tests;
