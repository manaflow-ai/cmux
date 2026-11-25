//! Starts an `on_demand` journal plugin (the bundled screen detector) at the
//! first program a terminal runs, not with the daemon.
//!
//! The screen detector reads only the screens of running programs, so a
//! daemon whose terminals all sit at a shell prompt (or that has none, as the
//! Chief daemon usually does) runs no detector process: about 7 MB per daemon
//! on macOS (`goals/ram-baseline.md`, kind `agent screen detection`).
//!
//! A terminal "runs a program" when its foreground job is not its shell
//! (`platform::foreground_job_name`), or when its own PTY child is not a
//! shell (a command terminal such as `cmux claude`), and the same job still
//! holds the terminal [`CONFIRM`] later: a quick `ls` never starts the
//! detector, an agent, a build or an editor does. An agent hook or status
//! report (`AgentChanged`, `AgentPresenceChanged`) starts it at once. The rule
//! names no agent vendor, as the plugin runtime does not.
//!
//! The watch is event-driven. While the plugin is held, a [`DemandTap`]
//! hands it each terminal output (from the output reader: `SurfaceOutput` is
//! published once until a renderer takes the output, so it misses a terminal
//! nobody draws) and each mux event it wakes on; at any other time the tap
//! costs one atomic load per output and per event. The watch wakes on a timer
//! only for a terminal it saw: a program's confirmation, or one more look
//! [`RECHECK`] after output that found the shell (a typed command's echo
//! comes before the shell forks it). It checks one terminal at most once per
//! [`RECHECK`], with one PTY query and one process-name read, never a process
//! scan. Once the plugin is demanded the watch ends; the plugin then runs for
//! the daemon's life.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use super::*;

/// How long the same foreground job must hold a terminal before the plugin
/// starts. Long enough that a quick command never starts it.
const CONFIRM: Duration = Duration::from_secs(2);
/// The least time between two checks of one terminal.
const RECHECK: Duration = Duration::from_secs(1);

/// Wakes queued for the watch before the tap counts a miss.
const TAP_CAPACITY: usize = 256;

/// Shells (by basename, a login shell's leading `-` removed): a terminal whose
/// PTY child is one of these and holds its own foreground runs no program.
const SHELLS: [&str; 15] = [
    "sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "xonsh", "pwsh",
    "elvish", "login", "busybox",
];

pub(crate) fn wakes(event: &MuxEvent) -> bool {
    matches!(
        event,
        MuxEvent::SurfaceOutput(_)
            | MuxEvent::TitleChanged { .. }
            | MuxEvent::ProgramStatusChanged { .. }
            | MuxEvent::AgentChanged { .. }
            | MuxEvent::AgentPresenceChanged { .. }
            | MuxEvent::TerminalRegistryChanged { .. }
    )
}

/// What one event asks of the watch.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Wake {
    /// An agent reported itself: start now.
    Agent,
    /// Check this surface's terminal.
    Surface(SurfaceId),
    /// The terminal set changed: check every terminal.
    All,
    /// Nothing to do.
    None,
}

pub(crate) fn wake_of(event: &MuxEvent) -> Wake {
    match event {
        MuxEvent::AgentChanged { .. }
        | MuxEvent::AgentPresenceChanged { presence: Some(_), .. } => Wake::Agent,
        MuxEvent::SurfaceOutput(surface)
        | MuxEvent::TitleChanged { surface, .. }
        | MuxEvent::ProgramStatusChanged { surface, .. } => Wake::Surface(*surface),
        MuxEvent::TerminalRegistryChanged { .. } => Wake::All,
        _ => Wake::None,
    }
}

/// Open taps in this process: the output reader's and `Mux::emit`'s gate.
static OPEN_TAPS: AtomicUsize = AtomicUsize::new(0);

/// Whether a held plugin's watch listens: one load, on every terminal output
/// and every mux event.
pub(crate) fn demand_tapped() -> bool {
    OPEN_TAPS.load(Ordering::Relaxed) != 0
}

/// Where terminal output and mux events reach the watch while it runs.
#[derive(Default)]
pub(crate) struct DemandTap {
    inner: Arc<TapInner>,
}

#[derive(Default)]
struct TapInner {
    sender: Mutex<Option<SyncSender<Wake>>>,
    /// A wake was dropped on a full queue: the watch checks every terminal.
    missed: AtomicBool,
}

/// An open [`DemandTap`]; closing it (on drop) stops the sends.
pub(crate) struct OpenTap {
    inner: Arc<TapInner>,
}

impl DemandTap {
    pub(crate) fn open(&self) -> (OpenTap, Receiver<Wake>) {
        let (sender, wakes) = std::sync::mpsc::sync_channel(TAP_CAPACITY);
        let mut slot = self.inner.sender.lock().unwrap_or_else(PoisonError::into_inner);
        if slot.replace(sender).is_none() {
            OPEN_TAPS.fetch_add(1, Ordering::Relaxed);
        }
        (OpenTap { inner: self.inner.clone() }, wakes)
    }

    pub(crate) fn send(&self, wake: Wake) {
        let slot = self.inner.sender.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(sender) = slot.as_ref()
            && let Err(TrySendError::Full(_)) = sender.try_send(wake)
        {
            self.inner.missed.store(true, Ordering::Relaxed);
        }
    }
}

impl OpenTap {
    /// Whether a wake was dropped since the last call.
    pub(crate) fn take_missed(&self) -> bool {
        self.inner.missed.swap(false, Ordering::Relaxed)
    }
}

impl Drop for OpenTap {
    fn drop(&mut self) {
        let mut slot = self.inner.sender.lock().unwrap_or_else(PoisonError::into_inner);
        if slot.take().is_some() {
            OPEN_TAPS.fetch_sub(1, Ordering::Relaxed);
        }
    }
}

/// Whether `name` (a process name or path, as `platform::process_executable`
/// gives it) is a shell.
pub(crate) fn is_shell(name: &str) -> bool {
    let first = name.split_whitespace().next().unwrap_or_default();
    let base = first.rsplit('/').next().unwrap_or(first);
    let base = base.strip_prefix('-').unwrap_or(base);
    SHELLS.contains(&base)
}

/// The process that holds the terminal whose PTY child is `pid`, when it is a
/// program and not the shell: its process-group leader.
fn running_program(pid: u32) -> Option<u32> {
    if crate::platform::foreground_job_name(pid).is_some() {
        return crate::platform::foreground_leader(pid);
    }
    let leader = crate::platform::foreground_leader(pid)?;
    if leader != pid {
        // login(1)'s shell holds the terminal: `foreground_job_name` said so.
        return None;
    }
    let name = crate::platform::process_executable(pid)?;
    (!is_shell(&name)).then_some(pid)
}

/// One terminal the watch has seen.
#[derive(Default)]
struct Seen {
    checked_at: Option<Instant>,
    /// The program that held it at the first check that found one, and when.
    candidate: Option<(u32, Instant)>,
    /// A check is due at this time (a candidate's confirmation, or a recheck
    /// of an event that came within [`RECHECK`] of the last check).
    due: Option<Instant>,
}

/// The watch's per-terminal state, keyed by the PTY child's pid.
#[derive(Default)]
pub(crate) struct DemandWatch {
    seen: HashMap<u32, Seen>,
}

impl DemandWatch {
    /// Check the terminal whose PTY child is `pid` at `now`, with `program`
    /// telling who holds it. True: the plugin should start. `event`: an event
    /// of this terminal asked for the check. One that finds the shell still
    /// holding it checks once more [`RECHECK`] later: the echo of a typed
    /// command arrives before the shell forks it, and a silent program
    /// (`sleep`, a quiet build) sends no further event.
    pub(crate) fn check(
        &mut self,
        pid: u32,
        now: Instant,
        event: bool,
        program: impl FnOnce(u32) -> Option<u32>,
    ) -> bool {
        let seen = self.seen.entry(pid).or_default();
        if let Some(at) = seen.checked_at
            && now.duration_since(at) < RECHECK
        {
            seen.due = Some(seen.due.map_or(at + RECHECK, |due| due.min(at + RECHECK)));
            return false;
        }
        seen.checked_at = Some(now);
        seen.due = None;
        match (program(pid), seen.candidate) {
            (Some(leader), Some((held, since))) if leader == held => {
                if now.duration_since(since) >= CONFIRM {
                    return true;
                }
                seen.due = Some(since + CONFIRM);
            }
            (Some(leader), _) => {
                seen.candidate = Some((leader, now));
                seen.due = Some(now + CONFIRM);
            }
            (None, _) => {
                seen.candidate = None;
                if event {
                    seen.due = Some(now + RECHECK);
                }
            }
        }
        false
    }

    /// The earliest due check.
    pub(crate) fn next_due(&self) -> Option<Instant> {
        self.seen.values().filter_map(|seen| seen.due).min()
    }

    /// The pids whose check is due at `now`.
    pub(crate) fn due(&self, now: Instant) -> Vec<u32> {
        self.seen
            .iter()
            .filter(|(_, seen)| seen.due.is_some_and(|due| due <= now))
            .map(|(pid, _)| *pid)
            .collect()
    }

    /// Forget terminals no longer live.
    pub(crate) fn retain(&mut self, live: &HashSet<u32>) {
        self.seen.retain(|pid, _| live.contains(pid));
    }
}

impl Mux {
    /// Watch for the first running program while an `on_demand` journal plugin
    /// is held, and release it then. Called once, when the plugin's
    /// supervisor starts. While no `on_demand` plugin is configured (none, an
    /// explicit `agents.plugin`) the watch blocks on the plugin's
    /// configuration and reads no events.
    pub(super) fn watch_journal_plugin_demand(self: &Arc<Self>) {
        let waiter = self.journal_plugin.hold_waiter();
        let mux = Arc::downgrade(self);
        let spawned = std::thread::Builder::new().name("cmux-journal-plugin-demand".into()).spawn(
            move || {
                while waiter.wait_until_held() {
                    if !watch_held(&mux) {
                        return;
                    }
                }
            },
        );
        if let Err(error) = spawned {
            // Without the watch the detector would never start: start it now.
            eprintln!("cmux-tui: journal plugin demand watch did not start: {error}");
            self.journal_plugin.demand();
        }
    }

    /// Output of the terminal shown as `surface`, for the watch (the reader
    /// calls it when [`demand_tapped`]).
    pub(crate) fn note_journal_plugin_demand_output(&self, surface: SurfaceId) {
        self.journal_plugin_demand.send(Wake::Surface(surface));
    }

    /// A mux event, for the watch (`Mux::emit` calls it when [`demand_tapped`]).
    pub(crate) fn note_journal_plugin_demand_event(&self, event: &MuxEvent) {
        if wakes(event) {
            self.journal_plugin_demand.send(wake_of(event));
        }
    }

    /// The PTY child pids of every live terminal.
    fn terminal_pids(&self) -> Vec<u32> {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let mut pids: Vec<u32> = state
            .surfaces
            .values()
            .chain(state.terminal_catalog.values())
            .filter_map(|surface| surface.process_id())
            .collect();
        pids.sort_unstable();
        pids.dedup();
        pids
    }
}

/// Watch while the plugin is held. Returns true to wait for the next hold
/// (the plugin is no longer `on_demand`), false when the watch is over
/// (released, or the daemon is gone).
fn watch_held(mux: &Weak<Mux>) -> bool {
    let Some(strong) = mux.upgrade() else { return false };
    // Open before the first sweep so no output between them is lost.
    let (tap, events) = strong.journal_plugin_demand.open();
    drop(strong);
    let mut watch = DemandWatch::default();
    let mut sweep = true;
    loop {
        let Some(strong) = mux.upgrade() else { return false };
        if !strong.journal_plugin.held() {
            return !strong.journal_plugin.demanded();
        }
        let now = Instant::now();
        let mut pids = Vec::new();
        if sweep {
            sweep = false;
            pids = strong.terminal_pids();
            watch.retain(&pids.iter().copied().collect());
        }
        pids.extend(watch.due(now));
        for pid in pids {
            if watch.check(pid, now, false, running_program) {
                release(&strong, "a terminal runs a program");
                return false;
            }
        }
        let timeout = watch.next_due().map(|due| due.saturating_duration_since(Instant::now()));
        drop(strong);
        let event = match timeout {
            Some(timeout) => match events.recv_timeout(timeout) {
                Ok(event) => Some(event),
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => None,
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return false,
            },
            None => match events.recv() {
                Ok(event) => Some(event),
                Err(_) => return false,
            },
        };
        if tap.take_missed() {
            sweep = true;
        }
        let Some(event) = event else { continue };
        let Some(strong) = mux.upgrade() else { return false };
        if !strong.journal_plugin.held() {
            continue;
        }
        match event {
            Wake::Agent => {
                release(&strong, "an agent reported its state");
                return false;
            }
            Wake::Surface(surface) => {
                if let Some(pid) = strong.surface(surface).and_then(|s| s.process_id())
                    && watch.check(pid, Instant::now(), true, running_program)
                {
                    release(&strong, "a terminal runs a program");
                    return false;
                }
            }
            Wake::All => sweep = true,
            Wake::None => {}
        }
    }
}

fn release(mux: &Mux, why: &str) {
    if mux.journal_plugin.demand() {
        eprintln!("cmux-tui: starting the journal plugin: {why}");
    }
}

#[cfg(test)]
#[path = "journal_plugin_demand_tests.rs"]
mod tests;
