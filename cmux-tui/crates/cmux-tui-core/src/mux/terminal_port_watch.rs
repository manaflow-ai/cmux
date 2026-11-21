//! Terminal ports on the sidebar: a dev server a workspace's terminal shows
//! (`Local: http://localhost:5173/`) appears as the workspace's status entry
//! `ports` (":3000, :5173"), which the app's sidebar row and hover card
//! already draw (`SidebarMapping.portsKey`). Every machine's daemon writes
//! the entries of its own workspaces, so a server started on another machine
//! shows on that machine's workspace in the app, the same as one on this Mac.
//!
//! No process scanning (plans/cmux-next/pty-holder.md section 4): discovery is
//! `terminal-ports` (`cmux-local-url`): the text a terminal shows, then a
//! loopback connect (plans/cmux-next/workspace-proxy-DESIGN.md section 6).
//!
//! Mark and wake. The output reader only sets the terminal's [`PortMark`]
//! and, when it was clear, queues the terminal here; it reads no text and
//! probes nothing. One worker thread takes the queued terminals, at most one
//! pass per [`PASS_INTERVAL`], so a pass costs what the terminals that printed
//! cost, never a sweep of every terminal. A pass reads each queued terminal's
//! live screen (the rows its new output wrote to, not the scrollback), finds
//! its loopback URLs, and probes those ports and the ports it already knew
//! for the terminal: a server that exited drops off at the terminal's next
//! output (the shell prompt after it). The worker ends once nothing was queued
//! for [`IDLE_LINGER`], when the mux is dropped, or at shutdown; the next
//! output starts it again.
//!
//! The daemon's entry carries the icon [`PORTS_ICON`]. A `ports` entry with
//! another icon (or none) is a person's or a hook's
//! (`cmux workspace status set ports ...`): it is never replaced or cleared.
//! At daemon start the entries an earlier run left are re-probed
//! ([`Mux::reconcile_terminal_ports`]): ports still accepting stay, the rest go.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError, Weak};
use std::time::{Duration, Instant};

use super::*;
use crate::state::WorkspaceStatusChange;
use crate::state::status_meta::StatusMeta;
use crate::workspace_registry::WorkspaceMutation;

/// The status key the sidebar's ports element reads.
pub(crate) const PORTS_KEY: &str = "ports";
/// Marks the entry as the daemon's.
pub(crate) const PORTS_ICON: &str = "network";
/// At most one pass per interval.
pub(crate) const PASS_INTERVAL: Duration = Duration::from_secs(1);
/// How long the worker waits for output before it ends.
const IDLE_LINGER: Duration = Duration::from_secs(5);
/// How long a pass that met a busy registry or a busy connection of the
/// store waits before it looks again.
const REGISTRY_BUSY_LOOK: Duration = Duration::from_millis(20);
/// Passes a terminal gets without new output while its screen names a port
/// that does not accept yet (a server that prints before it listens).
const UNCONFIRMED_RETRIES: u8 = 3;

/// A terminal's "printed since the last pass" flag, set by the output reader.
#[derive(Default)]
pub(crate) struct PortMark(AtomicBool);

impl PortMark {
    /// The reader's side: true when the terminal was not marked yet, so the
    /// caller queues it once per pass, not once per output chunk.
    pub(crate) fn mark(&self) -> bool {
        !self.0.swap(true, Ordering::AcqRel)
    }

    /// The pass's side, before it reads the screen: output after the read
    /// marks the terminal again.
    fn take(&self) {
        self.0.store(false, Ordering::Release);
    }
}

#[derive(Default)]
pub(crate) struct TerminalPortWatch {
    state: Mutex<WatchState>,
    wake: Condvar,
}

#[derive(Default)]
struct WatchState {
    /// Terminal runtimes queued since the last pass.
    queued: HashSet<SurfaceId>,
    /// Retries used by terminals whose screen names a port not accepting yet.
    retries: HashMap<SurfaceId, u8>,
    /// A daemon start asked for the stale entries to be re-probed.
    reconcile: bool,
    worker: bool,
    last_pass: Option<Instant>,
    /// A pass met a busy registry or a busy connection of the store: when
    /// the worker looks again, in place of the next [`PASS_INTERVAL`].
    look_again: Option<Instant>,
    /// The terminal a pass is reading now, and whether it ended meanwhile:
    /// an end during the read wins over what the read saw.
    reading: Option<(SurfaceId, bool)>,
    /// The workspace each watched terminal counted for.
    terminal_workspace: HashMap<SurfaceId, String>,
    /// By workspace public id.
    workspaces: HashMap<String, WorkspacePorts>,
}

#[derive(Default, Debug, PartialEq, Eq)]
struct WorkspacePorts {
    /// The accepting ports each terminal showed.
    terminals: HashMap<SurfaceId, BTreeSet<u16>>,
    /// Ports of an entry an earlier daemon run left, still accepting.
    carried: BTreeSet<u16>,
    /// The text this daemon last wrote, to skip a pass that changed nothing.
    written: Option<String>,
}

impl WorkspacePorts {
    fn ports(&self) -> BTreeSet<u16> {
        self.terminals.values().flatten().chain(&self.carried).copied().collect()
    }

    /// Nothing to show and nothing written: the watch can forget it.
    fn is_idle(&self) -> bool {
        self.carried.is_empty()
            && self.written.is_none()
            && self.terminals.values().all(BTreeSet::is_empty)
    }
}

/// The entry's text, in the sidebar's documented form: ":3000, :5173".
pub(crate) fn ports_text(ports: &BTreeSet<u16>) -> String {
    ports.iter().map(|port| format!(":{port}")).collect::<Vec<_>>().join(", ")
}

/// The ports of an entry's text, the inverse of [`ports_text`].
pub(crate) fn parse_ports_text(text: &str) -> BTreeSet<u16> {
    text.split(',')
        .filter_map(|part| part.trim().strip_prefix(':')?.parse().ok())
        .filter(|port| *port != 0)
        .collect()
}

/// A `ports` entry as stored: its text and icon.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct StoredPorts {
    pub(crate) text: String,
    pub(crate) icon: Option<String>,
}

/// One write a pass makes.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum PortsChange {
    Set(String),
    Clear,
}

/// The write that makes a workspace's stored entry show `wanted`, touching
/// only the daemon's own entry (icon [`PORTS_ICON`]) or none.
pub(crate) fn plan(stored: Option<&StoredPorts>, wanted: Option<&str>) -> Option<PortsChange> {
    let ours = |entry: &StoredPorts| entry.icon.as_deref() == Some(PORTS_ICON);
    match (wanted, stored) {
        (Some(text), None) => Some(PortsChange::Set(text.to_owned())),
        (Some(text), Some(entry)) if ours(entry) && entry.text != text => {
            Some(PortsChange::Set(text.to_owned()))
        }
        (None, Some(entry)) if ours(entry) => Some(PortsChange::Clear),
        _ => None,
    }
}

/// What a pass learned about one queued terminal.
enum Seen {
    /// The terminal counts for `workspace` with these accepting ports;
    /// `unconfirmed` when its screen names a port that did not accept.
    Ports { workspace: String, ports: BTreeSet<u16>, unconfirmed: bool },
    /// Ended, closed, private or not in a workspace: it counts for none.
    Gone,
}

impl Mux {
    /// The output reader's side: `runtime` printed. Takes only this
    /// watch's lock (never `Mux::state`), so the reader may hold `term`.
    pub(crate) fn queue_terminal_ports(self: &Arc<Self>, runtime: SurfaceId) {
        let mut state = self.terminal_port_watch.lock();
        state.queued.insert(runtime);
        state.retries.remove(&runtime);
        self.ensure_terminal_port_worker(&mut state);
    }

    /// `runtime`'s terminal ended: its ports leave its workspace's entry now.
    pub(crate) fn forget_terminal_ports(&self, runtime: SurfaceId) {
        let workspace = {
            let mut state = self.terminal_port_watch.lock();
            state.queued.remove(&runtime);
            state.retries.remove(&runtime);
            if let Some((reading, ended)) = state.reading.as_mut()
                && *reading == runtime
            {
                *ended = true;
            }
            let Some(workspace) = state.terminal_workspace.remove(&runtime) else { return };
            if let Some(entry) = state.workspaces.get_mut(&workspace) {
                entry.terminals.remove(&runtime);
            }
            workspace
        };
        self.write_terminal_ports(&workspace);
    }

    /// At daemon start: re-probe the `ports` entries an earlier run wrote.
    pub(crate) fn reconcile_terminal_ports(self: &Arc<Self>) {
        let mut state = self.terminal_port_watch.lock();
        state.reconcile = true;
        self.ensure_terminal_port_worker(&mut state);
    }

    fn ensure_terminal_port_worker(self: &Arc<Self>, state: &mut WatchState) {
        if state.worker {
            self.terminal_port_watch.wake.notify_all();
            return;
        }
        let weak = Arc::downgrade(self);
        let watch = Arc::clone(&self.terminal_port_watch);
        match std::thread::Builder::new()
            .name("terminal-port-watch".into())
            .spawn(move || run_worker(&weak, &watch))
        {
            Ok(_) => state.worker = true,
            Err(error) => eprintln!("cmux-tui: terminal port watch did not start: {error}"),
        }
    }

    /// One pass over the queued terminals (and, once, the stale entries).
    /// `Err` gives `queued` back: the registry or the store's connection
    /// was busy for the read of the stale entries, and the pass did nothing.
    fn terminal_ports_pass(
        &self,
        queued: Vec<SurfaceId>,
        reconcile: bool,
    ) -> Result<(), Vec<SurfaceId>> {
        let mut touched: BTreeSet<String> = BTreeSet::new();
        if reconcile {
            let Some(carried) = self.carry_stale_terminal_ports() else { return Err(queued) };
            touched.extend(carried);
        }
        for runtime in queued {
            let known: BTreeSet<u16> = {
                let mut state = self.terminal_port_watch.lock();
                state.reading = Some((runtime, false));
                state
                    .terminal_workspace
                    .get(&runtime)
                    .and_then(|workspace| state.workspaces.get(workspace))
                    .and_then(|ports| ports.terminals.get(&runtime))
                    .cloned()
                    .unwrap_or_default()
            };
            let seen = self.see_terminal_ports(runtime, &known);
            let mut state = self.terminal_port_watch.lock();
            // The terminal ended while it was read: its forget already ran.
            let seen = match state.reading.take() {
                Some((_, true)) => Seen::Gone,
                _ => seen,
            };
            if matches!(seen, Seen::Gone) {
                state.retries.remove(&runtime);
            }
            let previous = state.terminal_workspace.remove(&runtime);
            if let Some(previous) = previous {
                if let Some(entry) = state.workspaces.get_mut(&previous) {
                    entry.terminals.remove(&runtime);
                }
                touched.insert(previous);
            }
            if let Seen::Ports { workspace, ports, unconfirmed } = seen {
                if unconfirmed {
                    let used = state.retries.entry(runtime).or_default();
                    if *used < UNCONFIRMED_RETRIES {
                        *used += 1;
                        state.queued.insert(runtime);
                    }
                } else {
                    state.retries.remove(&runtime);
                }
                state.terminal_workspace.insert(runtime, workspace.clone());
                state
                    .workspaces
                    .entry(workspace.clone())
                    .or_default()
                    .terminals
                    .insert(runtime, ports);
                touched.insert(workspace);
            }
        }
        // The carried ports of a workspace whose terminal printed are
        // re-probed with it: a server from before the restart that exited.
        for workspace in &touched {
            let carried = {
                let state = self.terminal_port_watch.lock();
                state.workspaces.get(workspace).map(|entry| entry.carried.clone())
            };
            let Some(carried) = carried.filter(|carried| !carried.is_empty()) else { continue };
            let accepting: BTreeSet<u16> =
                carried.into_iter().filter(|port| cmux_local_url::probe(*port).is_some()).collect();
            if let Some(entry) = self.terminal_port_watch.lock().workspaces.get_mut(workspace) {
                entry.carried = accepting;
            }
        }
        for workspace in touched {
            self.write_terminal_ports(&workspace);
        }
        Ok(())
    }

    /// The accepting ports `runtime`'s live screen names, plus those of
    /// `known` that still accept. Reads the screen outside every watch lock.
    fn see_terminal_ports(&self, runtime: SurfaceId, known: &BTreeSet<u16>) -> Seen {
        let Some(surface) = self.surface(runtime).filter(|surface| !surface.is_dead()) else {
            return Seen::Gone;
        };
        if surface.terminal_runtime_id() != Some(runtime) {
            return Seen::Gone;
        }
        let Some(mark) = surface.port_mark() else { return Seen::Gone };
        // First, so output from here on queues the terminal again.
        mark.take();
        // An incognito terminal's output stays off disk; a status entry is durable.
        if surface
            .terminal_public_id()
            .is_some_and(|terminal| self.output_store.is_private(self, terminal))
        {
            return Seen::Gone;
        }
        let Some(workspace) = self.workspace_public_id_of_surface(runtime) else {
            return Seen::Gone;
        };
        let text =
            surface.try_with_terminal(|terminal| terminal.active_text()).ok().and_then(Result::ok);
        drop(surface);
        let shown: BTreeSet<u16> = text
            .map(|text| {
                cmux_local_url::candidates(&text).into_iter().map(|found| found.port).collect()
            })
            .unwrap_or_default();
        let ports: BTreeSet<u16> = known
            .union(&shown)
            .copied()
            .filter(|port| cmux_local_url::probe(*port).is_some())
            .collect();
        let unconfirmed = !shown.is_subset(&ports);
        Seen::Ports { workspace, ports, unconfirmed }
    }

    /// Commit `workspace`'s entry if what it should show changed.
    fn write_terminal_ports(&self, workspace: &str) {
        let (wanted, written) = {
            let state = self.terminal_port_watch.lock();
            let Some(entry) = state.workspaces.get(workspace) else { return };
            let ports = entry.ports();
            ((!ports.is_empty()).then(|| ports_text(&ports)), entry.written.clone())
        };
        if wanted == written {
            self.forget_idle_workspace_ports(workspace);
            return;
        }
        let stored = self.read_registry_state(|connection| {
            let mut statement = connection.prepare(
                "SELECT text, icon FROM workspace_status_entries
                 WHERE workspace_id = ?1 AND status_key = ?2",
            )?;
            let mut rows = statement.query_map([workspace, PORTS_KEY], |row| {
                Ok(StoredPorts { text: row.get(0)?, icon: row.get(1)? })
            })?;
            Ok(rows.next().transpose()?)
        });
        let stored = match stored {
            Ok(stored) => stored,
            Err(error) => {
                eprintln!("cmux-tui: terminal ports: reading the entry failed: {error}");
                return;
            }
        };
        let committed = match plan(stored.as_ref(), wanted.as_deref()) {
            Some(change) => self.commit_terminal_ports(workspace, change),
            None => true,
        };
        // A failed write is tried again at the workspace's next pass.
        if committed {
            if let Some(entry) = self.terminal_port_watch.lock().workspaces.get_mut(workspace) {
                entry.written = wanted;
            }
            self.forget_idle_workspace_ports(workspace);
        }
    }

    /// A workspace with no ports and nothing written leaves the map, so the
    /// watch holds only workspaces that show ports.
    fn forget_idle_workspace_ports(&self, workspace: &str) {
        let mut state = self.terminal_port_watch.lock();
        if !state.workspaces.get(workspace).is_some_and(WorkspacePorts::is_idle) {
            return;
        }
        if let Some(entry) = state.workspaces.remove(workspace) {
            for runtime in entry.terminals.keys() {
                state.terminal_workspace.remove(runtime);
            }
        }
    }

    fn commit_terminal_ports(&self, workspace: &str, change: PortsChange) -> bool {
        let mutation = WorkspaceMutation::daemon_local("terminal.ports");
        let (operation, change) = match change {
            PortsChange::Set(text) => (
                "workspace_status.set",
                WorkspaceStatusChange::Set {
                    key: PORTS_KEY.into(),
                    text,
                    icon: Some(PORTS_ICON.into()),
                    color: None,
                    meta: Box::new(StatusMeta::default()),
                },
            ),
            PortsChange::Clear => (
                "workspace_status.clear",
                WorkspaceStatusChange::Clear { key: Some(PORTS_KEY.into()) },
            ),
        };
        let selectors = self.local_workspace_selectors(workspace);
        match self.state_workspace_status(&mutation, operation, None, &selectors, change) {
            Ok(_) => true,
            Err(error) => {
                eprintln!("cmux-tui: terminal ports: {operation} failed: {error}");
                false
            }
        }
    }

    /// The daemon's own `ports` entries an earlier run left: their ports
    /// that still accept are carried, the rest go at this pass. Returns the
    /// workspaces to write. `None`: another thread has the registry or the
    /// store's connection, and the read did not run. This read takes each
    /// of them with one try and never waits for one, because the worker
    /// holds the mux here: a wait would keep a mux that its owner dropped,
    /// and with it the session, for as long as the lock is busy. A wait for
    /// the connection would also be a wait with the registry's lock: each
    /// thread that takes the registry would wait for the connection's
    /// holder (the journal writer at a commit) too.
    fn carry_stale_terminal_ports(&self) -> Option<Vec<String>> {
        let registry =
            self.workspace_registry.try_lock_free()?.unwrap_or_else(PoisonError::into_inner);
        let stale = registry.try_read_state(|connection| {
            let mut statement = connection.prepare(
                "SELECT workspace_id, text FROM workspace_status_entries
                 WHERE status_key = ?1 AND icon = ?2",
            )?;
            let rows = statement.query_map([PORTS_KEY, PORTS_ICON], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?;
            Ok(rows.collect::<Result<Vec<_>, _>>()?)
        });
        drop(registry);
        let stale = match stale? {
            Ok(stale) => stale,
            Err(error) => {
                eprintln!("cmux-tui: terminal ports: reading stale entries failed: {error}");
                return Some(Vec::new());
            }
        };
        let mut touched = Vec::new();
        for (workspace, text) in stale {
            let accepting: BTreeSet<u16> = parse_ports_text(&text)
                .into_iter()
                .filter(|port| cmux_local_url::probe(*port).is_some())
                .collect();
            let mut state = self.terminal_port_watch.lock();
            let entry = state.workspaces.entry(workspace.clone()).or_default();
            entry.carried.extend(accepting);
            entry.written.get_or_insert(text);
            touched.push(workspace);
        }
        Some(touched)
    }
}

impl TerminalPortWatch {
    fn lock(&self) -> MutexGuard<'_, WatchState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The worker: one pass per [`PASS_INTERVAL`] while terminals print. Ends
/// after [`IDLE_LINGER`] with nothing queued, when the mux is gone, or at
/// shutdown; its waits are bounded.
///
/// It holds the mux only for the shutdown check and for a pass, never across
/// a wait on the watch: a mux its owner dropped is freed at once (with the
/// registry's session lease), not after [`IDLE_LINGER`]. A pass whose read
/// of the stale entries meets a busy registry or a busy connection of the
/// store does not wait for it with the mux: it puts its work back, gives
/// the mux back and looks again after [`REGISTRY_BUSY_LOOK`]. Each look is
/// one try for each of the 2 and the worker is no waiter of them, so a
/// registry or a connection that stays busy holds the pass back with no
/// bound. The other waits of a pass keep the mux: a terminal's privacy
/// read that is not cached and the write of an entry wait for the registry
/// and then, with its lock, for the connection.
///
/// The watch it waits on is its own `Arc`. The strong mux is let go after
/// the watch's lock, so a mux whose last reference ends here never drops
/// under that lock. A pass takes its mux before it lets the watch's lock
/// go, and a pass that met a busy lock puts its request back before it
/// lets its mux go. So a taken request with no mux of the worker, read
/// under the watch's lock, is a pass that ended (it ran to its end or it
/// panicked).
fn run_worker(weak: &Weak<Mux>, watch: &TerminalPortWatch) {
    // A pass that panics leaves no stale `worker`: the next output starts one.
    struct OnPanic<'a>(&'a TerminalPortWatch);
    impl Drop for OnPanic<'_> {
        fn drop(&mut self) {
            if std::thread::panicking() {
                self.0.lock().worker = false;
            }
        }
    }
    let _on_panic = OnPanic(watch);
    loop {
        let Some(shutdown) = weak.upgrade().map(|mux| mux.daemon_shutdown_requested()) else {
            return;
        };
        let mut state = watch.lock();
        if shutdown {
            state.worker = false;
            state.queued.clear();
            return;
        }
        let now = Instant::now();
        if state.queued.is_empty() && !state.reconcile {
            let (mut state, waited) =
                watch.wake.wait_timeout(state, IDLE_LINGER).unwrap_or_else(PoisonError::into_inner);
            if waited.timed_out() && state.queued.is_empty() && !state.reconcile {
                state.worker = false;
                return;
            }
            continue;
        }
        let due = state
            .look_again
            .unwrap_or_else(|| state.last_pass.map_or(now, |last| last + PASS_INTERVAL));
        if due > now {
            let _ =
                watch.wake.wait_timeout(state, due - now).unwrap_or_else(PoisonError::into_inner);
            continue;
        }
        let Some(mux) = weak.upgrade() else { return };
        state.look_again = None;
        state.last_pass = Some(now);
        let queued: Vec<SurfaceId> = state.queued.drain().collect();
        let reconcile = std::mem::take(&mut state.reconcile);
        drop(state);
        let Err(queued) = mux.terminal_ports_pass(queued, reconcile) else { continue };
        // The registry or the connection was busy. The request goes back
        // first, then the watch's lock goes, then the mux: it never drops
        // under that lock.
        let mut state = watch.lock();
        state.queued.extend(queued);
        state.reconcile = true;
        state.look_again = Some(Instant::now() + REGISTRY_BUSY_LOOK);
        drop(state);
        drop(mux);
    }
}

#[cfg(test)]
#[path = "terminal_port_watch_tests.rs"]
mod tests;
