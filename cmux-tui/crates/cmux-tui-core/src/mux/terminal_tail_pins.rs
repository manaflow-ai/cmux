//! Terminal tail pins (`terminal-tail-pin-v1`): a pinned terminal's last
//! non-empty output line shows under its workspace in the sidebar, as the
//! workspace status entry `tail:<term id>` (icon `terminal`). The sidebar
//! already draws status entries; nothing here is a new view.
//!
//! The output reader only feeds the line in memory (`TailPinSlot::feed`) and,
//! when it changed, queues the terminal here. One thread commits the entries,
//! at most once per `PUBLISH_INTERVAL` per terminal, so the reader never waits
//! for the registry (#35413). The thread exists only while a terminal is
//! pinned: it ends when the last pin goes. An unpin clears the entry; the
//! entry names its terminal as its owner, so the terminal's exit clears it
//! too (`status_owners.rs`), and an ended terminal's pin is dropped
//! (`forget_terminal_tail`). Pins live in memory: a daemon start clears the
//! entries an earlier run left (`clear_stale_terminal_tails`).

use std::collections::HashMap;
use std::time::Instant;

use serde_json::json;

use super::*;
use crate::state::WorkspaceStatusChange;
use crate::state::status_meta::StatusMeta;
use crate::terminal_tail::Throttle;
use crate::workspace_registry::WorkspaceMutation;

/// The status key prefix of a tail entry.
pub(crate) const TAIL_KEY_PREFIX: &str = "tail:";
const TAIL_ICON: &str = "terminal";

#[derive(Default)]
pub(crate) struct TerminalTailPins {
    state: Mutex<PinsState>,
    wake: Condvar,
}

#[derive(Default)]
struct PinsState {
    /// By terminal runtime id.
    pins: HashMap<SurfaceId, Pin>,
    /// Runtimes whose tail changed, waiting for their throttle.
    due: HashMap<SurfaceId, Instant>,
    worker: bool,
}

struct Pin {
    /// The tab the pin was made from, for its workspace.
    view: SurfaceId,
    surface: Weak<Surface>,
    terminal: TerminalPublicId,
    throttle: Throttle,
    /// The workspace whose status holds the entry now.
    workspace: Option<String>,
}

impl Pin {
    fn key(&self) -> String {
        format!("{TAIL_KEY_PREFIX}{}", self.terminal.as_str())
    }
}

impl Mux {
    /// Pin or unpin `view`'s terminal. A pin publishes the screen's last line
    /// at once. Returns the terminal's public id.
    pub(crate) fn set_terminal_tail_pin(
        self: &Arc<Self>,
        view: SurfaceId,
        pinned: bool,
    ) -> anyhow::Result<TerminalPublicId> {
        let surface = self.surface(view).ok_or_else(|| anyhow::anyhow!("surface_not_found"))?;
        let slot = surface.tail_pin().ok_or_else(|| anyhow::anyhow!("not_a_terminal"))?;
        let id = surface.terminal_runtime_id().ok_or_else(|| anyhow::anyhow!("not_a_terminal"))?;
        let terminal = surface
            .terminal_public_id()
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("terminal_not_hosted"))?;
        if pinned {
            let seed = surface
                .try_with_terminal(|term| term.viewport_text())
                .ok()
                .and_then(|text| text.ok());
            let seed = seed.as_deref().and_then(|text| {
                text.lines().rev().find(|line| !line.trim().is_empty()).map(str::to_owned)
            });
            if slot.set_pinned(true, seed.as_deref()) {
                let mut state = self.terminal_tail_pins.lock();
                state.pins.insert(
                    id,
                    Pin {
                        view,
                        surface: Arc::downgrade(&surface),
                        terminal: terminal.clone(),
                        throttle: Throttle::default(),
                        workspace: None,
                    },
                );
                drop(state);
                self.queue_terminal_tail(id);
            }
        } else if slot.set_pinned(false, None) {
            let pin = {
                let mut state = self.terminal_tail_pins.lock();
                state.due.remove(&id);
                state.pins.remove(&id)
            };
            if let Some(pin) = pin {
                self.clear_terminal_tail(&pin);
            }
            self.terminal_tail_pins.wake.notify_all();
        }
        Ok(terminal)
    }

    /// A tab that shows terminal `terminal` (its public `term_` id), for a pin
    /// named by terminal.
    pub(crate) fn placed_surface_of_terminal(&self, terminal: &str) -> Option<SurfaceId> {
        self.with_state(|state| {
            state.surfaces.iter().find_map(|(id, surface)| {
                let shows = surface.terminal_public_id().is_some_and(|public| public.as_str() == terminal);
                (shows && state.pane_of(*id).is_some()).then_some(*id)
            })
        })
    }

    /// Whether `view`'s terminal is pinned.
    pub(crate) fn terminal_tail_pinned(&self, view: SurfaceId) -> bool {
        self.surface(view).and_then(|surface| surface.tail_pin().map(|slot| slot.is_pinned()))
            == Some(true)
    }

    /// The output reader's side: `runtime`'s tail changed. Never waits for
    /// the registry; starts the publisher thread when none runs.
    pub(crate) fn queue_terminal_tail(self: &Arc<Self>, runtime: SurfaceId) {
        let pins = &self.terminal_tail_pins;
        let mut state = pins.lock();
        let Some(pin) = state.pins.get(&runtime) else { return };
        let at = pin.throttle.next_at(Instant::now());
        state.due.entry(runtime).or_insert(at);
        if state.worker {
            pins.wake.notify_all();
            return;
        }
        let weak = Arc::downgrade(self);
        match std::thread::Builder::new()
            .name("terminal-tail-pins".into())
            .spawn(move || run_publisher(&weak))
        {
            Ok(_) => state.worker = true,
            Err(error) => eprintln!("cmux-tui: terminal tail publisher did not start: {error}"),
        }
    }

    /// `surface`'s terminal ended: drop its pin and its entry (the owner
    /// watch would too, later).
    pub(crate) fn forget_terminal_tail(&self, surface: &Surface) {
        let (Some(slot), Some(id)) = (surface.tail_pin(), surface.terminal_runtime_id()) else {
            return;
        };
        if !slot.set_pinned(false, None) {
            return;
        }
        let pin = {
            let mut state = self.terminal_tail_pins.lock();
            state.due.remove(&id);
            state.pins.remove(&id)
        };
        if let Some(pin) = pin {
            self.clear_terminal_tail(&pin);
        }
        self.terminal_tail_pins.wake.notify_all();
    }

    /// Remove the tail entries an earlier daemon run left (pins do not
    /// outlive the daemon). Runs once at daemon start.
    pub(crate) fn clear_stale_terminal_tails(&self) {
        let stale = self.read_registry_state(|connection| {
            let mut statement = connection.prepare(
                "SELECT workspace_id, status_key FROM workspace_status_entries
                 WHERE substr(status_key, 1, 5) = ?1",
            )?;
            let rows = statement.query_map([TAIL_KEY_PREFIX], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?;
            Ok(rows.collect::<Result<Vec<_>, _>>()?)
        });
        match stale {
            Ok(stale) => {
                for (workspace, key) in stale {
                    self.commit_terminal_tail(
                        &workspace,
                        WorkspaceStatusChange::Clear { key: Some(key) },
                    );
                }
            }
            Err(error) => eprintln!("cmux-tui: reading stale terminal tails failed: {error}"),
        }
    }

    /// Publish the tail of `runtime` now, if it changed. Returns false when
    /// the pin is gone (its terminal closed).
    fn publish_terminal_tail(self: &Arc<Self>, runtime: SurfaceId) -> bool {
        let (view, surface, key, previous) = {
            let state = self.terminal_tail_pins.lock();
            let Some(pin) = state.pins.get(&runtime) else { return false };
            (pin.view, pin.surface.clone(), pin.key(), pin.workspace.clone())
        };
        let Some(surface) = surface.upgrade().filter(|surface| !surface.is_dead()) else {
            return false;
        };
        let Some(slot) = surface.tail_pin() else { return false };
        let Some(text) = slot.take_change() else { return true };
        let Some(workspace) = self.workspace_public_id_of_surface(view) else { return true };
        let Some(terminal) = surface.terminal_public_id().cloned() else { return false };
        // The tab moved to another workspace: its old row drops the line.
        if let Some(previous) = previous.filter(|previous| *previous != workspace) {
            self.commit_terminal_tail(
                &previous,
                WorkspaceStatusChange::Clear { key: Some(key.clone()) },
            );
        }
        let meta = StatusMeta {
            owner_terminal: Some(terminal.as_str().to_owned()),
            target_terminal: Some(terminal.as_str().to_owned()),
            ..StatusMeta::default()
        };
        let committed = self.commit_terminal_tail(
            &workspace,
            WorkspaceStatusChange::Set {
                key,
                text,
                icon: Some(TAIL_ICON.into()),
                color: None,
                meta: Box::new(meta),
            },
        );
        if committed {
            crate::state::status_owners::watch_owners(self, Some(terminal.as_str()), None, false);
        }
        let mut state = self.terminal_tail_pins.lock();
        if let Some(pin) = state.pins.get_mut(&runtime) {
            pin.workspace = Some(workspace);
        }
        true
    }

    fn clear_terminal_tail(&self, pin: &Pin) {
        let workspace = pin.workspace.clone().or_else(|| self.workspace_public_id_of_surface(pin.view));
        if let Some(workspace) = workspace {
            self.commit_terminal_tail(&workspace, WorkspaceStatusChange::Clear { key: Some(pin.key()) });
        }
    }

    fn commit_terminal_tail(&self, workspace: &str, change: WorkspaceStatusChange) -> bool {
        let selectors =
            crate::ResourceSelectors { workspace: Some(workspace.to_owned()), ..Default::default() };
        let mutation = WorkspaceMutation::daemon_local("terminal.tail_pin");
        let operation = match change {
            WorkspaceStatusChange::Clear { .. } => "workspace_status.clear",
            _ => "workspace_status.set",
        };
        match self.state_workspace_status(&mutation, operation, None, &selectors, change) {
            Ok(_) => true,
            Err(error) => {
                eprintln!("cmux-tui: terminal tail publication failed: {error}");
                false
            }
        }
    }

    fn workspace_public_id_of_surface(&self, view: SurfaceId) -> Option<String> {
        let workspace = self.surface_workspace(view)?;
        self.with_state(|state| {
            let index = state.workspace_index(workspace)?;
            Some(state.workspaces[index].public_id.to_string())
        })
    }
}

impl TerminalTailPins {
    fn lock(&self) -> std::sync::MutexGuard<'_, PinsState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    #[cfg(test)]
    pub(crate) fn worker_running(&self) -> bool {
        self.lock().worker
    }
}

/// The publisher thread: commits each due tail, sleeping until the next one
/// is due. Ends when no terminal is pinned, or the mux is gone.
fn run_publisher(weak: &Weak<Mux>) {
    loop {
        let Some(mux) = weak.upgrade() else { return };
        let pins = &mux.terminal_tail_pins;
        let mut state = pins.lock();
        if state.pins.is_empty() || mux.daemon_shutdown_requested() {
            state.worker = false;
            state.due.clear();
            return;
        }
        let now = Instant::now();
        let ready: Vec<SurfaceId> =
            state.due.iter().filter(|(_, at)| **at <= now).map(|(id, _)| *id).collect();
        if ready.is_empty() {
            // Bounded, and the mux is let go after it, so a dropped mux or a
            // shutdown ends the thread.
            let wait = state
                .due
                .values()
                .min()
                .map_or(PIN_IDLE_WAIT, |at| at.saturating_duration_since(now))
                .min(PIN_IDLE_WAIT);
            drop(pins.wake.wait_timeout(state, wait).unwrap_or_else(PoisonError::into_inner));
            continue;
        }
        for id in &ready {
            state.due.remove(id);
            if let Some(pin) = state.pins.get_mut(id) {
                pin.throttle.ran(now);
            }
        }
        drop(state);
        for id in ready {
            if !mux.publish_terminal_tail(id) {
                let mut state = pins.lock();
                state.pins.remove(&id);
                state.due.remove(&id);
            }
        }
    }
}

const PIN_IDLE_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

#[cfg(test)]
#[path = "terminal_tail_pins_tests.rs"]
mod tests;
