//! Terminals of a terminal holder that was late at a daemon start.
//!
//! A start gives the holder one deadline for all its terminals together
//! ([`ADOPTION_BOUND`], mux/holder_adoption.rs). A holder that took the
//! connect and did not answer in that time (it is stopped, or the machine is
//! loaded) may still run every shell, so the start ends none of its
//! terminals: they stay `adopting`, the start goes on, and one thread waits
//! here for the holder's answer.
//!
//! The thread waits on the connect the start made (or, when the holder
//! ended or refused that one before the start was over, on a connect of its
//! own), for as long as the holder is silent: no timer ends a terminal. When
//! the holder ends a kept connect, or refuses it because another connect
//! took its link, a new connect is made at once. When the holder also ends
//! or so refuses a new connect before its answer, the next one is made after
//! a pause ([`RECONNECT_INITIAL`], doubled up to [`RECONNECT_MAX`]), each
//! time. When the holder answers, each terminal re-attaches as it does in
//! the start pass (or ends, when the holder does not run it). A terminal
//! ends without an answer only when no holder can be asked any more (a
//! connect that no holder takes, a missing socket, a holder that refuses the
//! token or the version of this daemon, or another error of the ask). The
//! person can close the tab of a terminal that waits; the holder ends that
//! shell when it answers.
//!
//! A creation that a crash interrupted settles here when its terminal
//! re-attached or ended. While its terminal is kept for the next start it
//! stays pending: a client's ask for its result gets pending again, and a
//! later start that re-attaches or ends the terminal settles it.

use super::*;
use crate::holder_runtime::{HolderReach, HolderService};

/// How long a start waits for the terminal holder, for its answer and every
/// re-attach together. A terminal whose turn comes later re-attaches after
/// the start.
pub(in crate::mux) const ADOPTION_BOUND: Duration = Duration::from_millis(250);
/// One wait of the late thread on the holder's answer. Between two waits the
/// holder service is free for another caller (a new tab's own ask).
const LATE_WAIT: Duration = Duration::from_secs(1);
/// The pause between two waits.
const LATE_PAUSE: Duration = Duration::from_millis(10);
/// First and longest pause before a new connect, after a holder that ended
/// the connect before its answer.
const RECONNECT_INITIAL: Duration = Duration::from_millis(250);
const RECONNECT_MAX: Duration = Duration::from_secs(5);
/// How long a creation that waited on a late terminal may take to settle
/// after the terminal re-attached or ended.
const SETTLE_WAIT: Duration = Duration::from_secs(15);

/// The time the start pass and the late thread wait by. The daemon uses the
/// system's clock; a test steps its own, so its result is a count of asks
/// and not a time.
pub(in crate::mux) trait HolderClock: Send + Sync {
    fn now(&self) -> Instant;
    /// The longest single read of the holder's socket: how soon a wait
    /// notices a shutdown.
    fn read_slice(&self) -> Duration;
    fn pause(&self, pause: Duration);
}

struct SystemHolderClock;

impl HolderClock for SystemHolderClock {
    fn now(&self) -> Instant {
        Instant::now()
    }

    fn read_slice(&self) -> Duration {
        Duration::from_millis(100)
    }

    fn pause(&self, pause: Duration) {
        std::thread::sleep(pause);
    }
}

/// The clocks tests gave to the holders of their own host roots.
#[cfg(test)]
static TEST_CLOCKS: Mutex<Vec<(std::path::PathBuf, Arc<dyn HolderClock>)>> = Mutex::new(Vec::new());

/// Give the start and the late thread of the daemon at `host_root` this
/// clock. Call it before the mux opens.
#[cfg(test)]
pub(in crate::mux) fn set_holder_clock_for_test(host_root: &Path, clock: Arc<dyn HolderClock>) {
    TEST_CLOCKS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .push((host_root.to_path_buf(), clock));
}

/// The clock of the holder at `host_root`.
pub(in crate::mux) fn holder_clock(host_root: Option<&Path>) -> Arc<dyn HolderClock> {
    #[cfg(test)]
    if let Some(host_root) = host_root
        && let Some((_, clock)) = TEST_CLOCKS
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .find(|(root, _)| root == host_root)
    {
        return clock.clone();
    }
    #[cfg(not(test))]
    let _ = host_root;
    Arc::new(SystemHolderClock)
}

impl Mux {
    /// Start the thread that waits for the late holder of this start and
    /// then re-attaches `late` (host ids the pass marked adopting and put in
    /// `late_holder_terminals`). With no terminal kept it still does the end
    /// of the pass's holder part for a holder that has not answered.
    pub(in crate::mux) fn adopt_late_holder_terminals(
        self: &Arc<Self>,
        options: SurfaceOptions,
        clock: Arc<dyn HolderClock>,
        late: Vec<String>,
    ) {
        let mux = Arc::downgrade(self);
        let spawned = std::thread::Builder::new()
            .name("holder-late-adopt".into())
            .spawn(move || wait_for_late_holder(&mux, &options, clock.as_ref(), &late));
        if let Err(error) = spawned {
            // The terminals stay adopting: the next start re-attaches them.
            eprintln!("cmux-tui: could not start the late terminal holder thread: {error}");
        }
    }

    /// The holder answered: re-attach each terminal the start kept, as the
    /// start pass does, then do the end of the pass's holder part.
    fn attach_late_holder_terminals(
        self: &Arc<Self>,
        options: &SurfaceOptions,
        clock: &dyn HolderClock,
        late: &[String],
    ) {
        // The terminals that no longer wait: re-attached, or ended.
        let mut done = Vec::new();
        for terminal_id in late {
            let row = self
                .workspace_registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .terminal_record(terminal_id);
            // Whether the terminal still waits for a start to re-attach it.
            let waits = match row {
                Ok(Some(row))
                    if matches!(
                        row.lifecycle,
                        TerminalLifecycle::Running | TerminalLifecycle::Adopting
                    ) =>
                {
                    self.adopt_from_reached_holder_or_end(&row, options).unwrap_or_else(|error| {
                        eprintln!(
                            "cmux-tui: re-attach late holder terminal {terminal_id}: {error:#}"
                        );
                        self.row_still_live(terminal_id)
                    })
                }
                // The row ended while the holder was silent (the person
                // closed the tab), or it is gone.
                Ok(_) => false,
                Err(error) => {
                    eprintln!("cmux-tui: read late holder terminal {terminal_id}: {error:#}");
                    true
                }
            };
            if !waits {
                self.clear_adopting_marker(terminal_id);
                done.push(terminal_id.clone());
            }
        }
        // A terminal kept for the next start stays in the set: its creation
        // stays pending, and nothing waits for it.
        self.forget_late_holder_terminals(&done);
        self.release_unclaimed_holder_terminals(options);
        self.settle_creations_after_late_holder(clock);
    }

    /// No holder serves the socket any more: its shells are gone. End each
    /// terminal the start kept, as the start pass ends a terminal whose
    /// holder is gone, and respawn it as the start does.
    fn end_late_holder_terminals(
        self: &Arc<Self>,
        options: &SurfaceOptions,
        clock: &dyn HolderClock,
        late: &[String],
    ) {
        for terminal_id in late {
            if !self.row_still_live(terminal_id) {
                self.clear_adopting_marker(terminal_id);
                continue;
            }
            if let Err(error) = self.mark_terminal_ended(
                terminal_id,
                "terminal-record-missing",
                "missing-host-record",
                options,
            ) {
                eprintln!("cmux-tui: end late holder terminal {terminal_id}: {error:#}");
                continue;
            }
            let row = self
                .workspace_registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .terminal_record(terminal_id);
            if let Ok(Some(row)) = row
                && row.lifecycle == TerminalLifecycle::Exited
            {
                self.schedule_terminal_respawn(
                    terminal_id,
                    row.incarnation.as_deref(),
                    &TerminalEnd::from_receipt(row.exit.as_ref()),
                );
            }
        }
        self.forget_late_holder_terminals(late);
        self.settle_creations_after_late_holder(clock);
    }

    fn forget_late_holder_terminals(&self, late: &[String]) {
        let mut kept = self.late_holder_terminals.lock().unwrap_or_else(PoisonError::into_inner);
        for terminal_id in late {
            kept.remove(terminal_id);
        }
    }

    /// Settle the creations a crash interrupted whose terminal waited on the
    /// late holder: the start did not wait for them
    /// (`reconcile_interrupted_resource_creations`).
    fn settle_creations_after_late_holder(&self, clock: &dyn HolderClock) {
        let deadline = clock.now() + SETTLE_WAIT;
        loop {
            match self.reconcile_interrupted_resource_creations() {
                Ok(false) => return,
                Ok(true) => {}
                Err(error) => {
                    eprintln!("cmux-tui: settle the creations of late holder terminals: {error:#}");
                    return;
                }
            }
            if self.shutting_down.load(Ordering::Acquire) {
                return;
            }
            if clock.now() >= deadline {
                eprintln!(
                    "cmux-tui: an interrupted creation of a late holder terminal did not settle"
                );
                return;
            }
            clock.pause(Duration::from_millis(25));
        }
    }
}

/// The late thread. In its wait for the holder it holds the mux weakly: a
/// mux that is dropped or shuts down ends it at the next read slice, or at
/// the end of its pause between two asks. After the holder's answer, or
/// when no holder serves the socket, it keeps the mux for the re-attach (or
/// the end of the terminals) and for the wait of
/// `settle_creations_after_late_holder`. With the terminal journal on (the
/// registry has a database file), the reader of a holder terminal also
/// holds the mux while it waits for output (`LocalOutput::read` takes its
/// journal target before the read), so a drop with no `shutdown()` does not
/// end such a mux whose holder terminal re-attached.
fn wait_for_late_holder(
    mux: &Weak<Mux>,
    options: &SurfaceOptions,
    clock: &dyn HolderClock,
    late: &[String],
) {
    let live = || mux.upgrade().filter(|mux| !mux.shutting_down.load(Ordering::Acquire));
    // As a start's adoption threads: after the owner says ready, so the
    // re-attach does not hold the rest of the start back. A mux that never
    // says ready (a bare test mux) goes on after STARTUP_READY_WAIT.
    let ready_by = clock.now() + terminal_adoption::STARTUP_READY_WAIT;
    loop {
        let Some(mux) = live() else { return };
        if mux.server_lifecycle_ready()
            || mux.startup_adoptions_released.load(Ordering::Acquire)
            || clock.now() >= ready_by
        {
            break;
        }
        drop(mux);
        clock.pause(Duration::from_millis(5));
    }
    let Some(host_root) = options.terminal_host_root.as_deref() else { return };
    let service = match HolderService::for_root(host_root) {
        Ok(service) => service,
        Err(error) => {
            eprintln!("cmux-tui: reach the terminal holder: {error}");
            if let Some(mux) = live() {
                mux.end_late_holder_terminals(options, clock, late);
            }
            return;
        }
    };
    let mut reconnect_pause = RECONNECT_INITIAL;
    loop {
        // A daemon another one replaced does not reach the holder again: its
        // terminals are the new daemon's.
        if live().is_none() || service.gave_way() {
            return;
        }
        let until = clock.now() + LATE_WAIT;
        // The closure runs under the holder service's `connecting` lock.
        // When its stop check has the last reference of the mux, the mux
        // drops on this thread under that lock, so no drop of a mux or of a
        // surface may take `connecting` or wait for a thread that takes it
        // (the service's `close`, `detach` and `untrack`, which a surface
        // calls at its end, do not take it).
        let reach = service.reach(&|| {
            if live().is_none() {
                return Duration::ZERO;
            }
            until.saturating_duration_since(clock.now()).min(clock.read_slice())
        });
        let Some(mux) = live() else { return };
        match reach {
            HolderReach::Linked => {
                eprintln!(
                    "cmux-tui: the terminal holder answered after the start: {} terminals \
                     re-attach",
                    late.len()
                );
                mux.attach_late_holder_terminals(options, clock, late);
                return;
            }
            HolderReach::Silent => {
                drop(mux);
                clock.pause(LATE_PAUSE);
            }
            HolderReach::Dropped => {
                drop(mux);
                clock.pause(reconnect_pause);
                reconnect_pause = (reconnect_pause * 2).min(RECONNECT_MAX);
            }
            HolderReach::Absent => {
                if !service.gave_way() {
                    mux.end_late_holder_terminals(options, clock, late);
                }
                return;
            }
        }
    }
}
