//! Terminals an app brings: a byte-backend terminal is a catalog-owned
//! terminal with zero views on this session host. The client that made the
//! gesture gives it its first view with `terminal.project`, which also
//! writes its durable record (`resource_content.rs`); until then it has no
//! registry record, and the supervisor closes it after 60 s.

use std::sync::{Arc, Mutex};

use anyhow::Context;

#[cfg(unix)]
use super::insert_surface_checked;
use super::remove_terminal_runtime_from_state;
use super::{Mux, commit_terminal_lifecycle};
use crate::model::State;
use crate::resource::TerminalPublicId;
use crate::surface::Surface;
#[cfg(unix)]
use crate::terminal_backend::pty::BackendSide;
use crate::terminal_host::TerminalId;
use crate::terminal_host_runtime::TerminalHostIdentity;
use crate::workspace_registry::{RegistryTerminal, ResourceChange, TerminalLifecycle};
use crate::{PaneId, SurfaceId};

/// The identity a first view wrote, handed from `terminal.project`'s commit
/// plan to the code that runs once the commit succeeded.
#[derive(Clone, Default)]
pub(crate) struct FirstView(Arc<Mutex<Option<(SurfaceId, TerminalHostIdentity)>>>);

impl FirstView {
    pub(crate) fn pair() -> (Self, Self) {
        let first = Self::default();
        (first.clone(), first)
    }

    /// The first patch changes of a projection: a first view's durable
    /// record, noted for [`Mux::finish_app_terminal_first_view`].
    pub(crate) fn record(
        &self,
        first: Option<(TerminalHostIdentity, RegistryTerminal)>,
        public_id: &TerminalPublicId,
        surface: SurfaceId,
    ) -> Vec<ResourceChange> {
        let mut changes = Vec::with_capacity(4);
        if let Some((identity, terminal)) = first {
            changes.push(ResourceChange::UpsertTerminal { public_id: public_id.clone(), terminal });
            *self.0.lock().unwrap() = Some((surface, identity));
        }
        changes
    }
}

/// A backend terminal the session host created.
#[cfg(unix)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct BackendTerminal {
    pub surface: SurfaceId,
    pub terminal_id: TerminalPublicId,
}

impl Mux {
    /// Creates the catalog-owned, zero-view terminal of an app's
    /// byte-backend terminal at the daemon's default size. Unix only, like
    /// the app supervisor that calls it (`terminal_backend`).
    #[cfg(unix)]
    pub(crate) fn spawn_backend_terminal(
        self: &Arc<Self>,
        side: BackendSide,
    ) -> anyhow::Result<BackendTerminal> {
        let id = self.next_id();
        let terminal_id = TerminalPublicId::random()?;
        let opts = self.surface_options.lock().unwrap().clone();
        let cell_pixels = {
            let cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
            let cell_pixels = self.cell_pixel_creation_size();
            drop(cell_pixel_lifecycle);
            cell_pixels
        };
        let surface = Surface::spawn_backend(
            id,
            opts,
            Arc::downgrade(self),
            cell_pixels,
            terminal_id.clone(),
            side,
        )?;
        let cell_pixel_lifecycle = match self.reconcile_surface_cell_pixels_for_publish(&surface) {
            Ok(lifecycle) => lifecycle,
            Err(error) => {
                surface.kill();
                return Err(error);
            }
        };
        let insert_result =
            insert_surface_checked(&mut self.state.lock().unwrap(), surface.clone());
        drop(cell_pixel_lifecycle);
        if let Err(error) = insert_result {
            surface.kill();
            return Err(error);
        }
        self.app_terminals.lock().unwrap().insert(id);
        Ok(BackendTerminal { surface: id, terminal_id })
    }

    /// True when `surface` is an app backend terminal that has no durable
    /// record yet (it was never projected).
    pub(crate) fn is_unregistered_app_terminal(&self, surface: SurfaceId) -> bool {
        self.app_terminals.lock().unwrap().contains(&surface)
            && !self.reserved_in_process_terminals.lock().unwrap().contains_key(&surface)
    }

    /// For the first view of an app terminal (no durable record yet): a new
    /// in-process identity and its record in the destination pane's
    /// workspace. New records start launching (registry rule); the running
    /// transition follows the commit. `None` for any other terminal.
    pub(crate) fn app_terminal_first_view(
        &self,
        state: &State,
        terminal: &Surface,
        pane: PaneId,
    ) -> anyhow::Result<Option<(TerminalHostIdentity, RegistryTerminal)>> {
        if !self.is_unregistered_app_terminal(terminal.id) {
            return Ok(None);
        }
        let (workspace, _) = state.screen_of(pane).context("destination pane has no workspace")?;
        let identity = TerminalHostIdentity {
            terminal_id: TerminalId::random()?.to_hex(),
            incarnation: TerminalId::random()?.to_hex(),
        };
        let record = RegistryTerminal {
            terminal_id: identity.terminal_id.clone(),
            workspace_key: state.workspaces[workspace].key.clone(),
            incarnation: None,
            lifecycle: TerminalLifecycle::Launching,
            launch_spec: serde_json::json!({ "app_backend": true }),
            exit: None,
            on_exit: Default::default(),
        };
        Ok(Some((identity, record)))
    }

    /// After a committed first view: the terminal keeps its identity and its
    /// record becomes running with that incarnation.
    pub(crate) fn finish_app_terminal_first_view(&self, first: &FirstView) -> anyhow::Result<()> {
        let Some((surface, identity)) = first.0.lock().unwrap().take() else { return Ok(()) };
        let (terminal_id, incarnation) =
            (identity.terminal_id.clone(), identity.incarnation.clone());
        self.reserved_in_process_terminals.lock().unwrap().insert(surface, identity);
        let mut registry = self.workspace_registry.lock().unwrap();
        let (_, revision) = commit_terminal_lifecycle(
            &mut registry,
            "terminal-ready",
            "terminal-ready",
            &terminal_id,
            TerminalLifecycle::Running,
            Some(&incarnation),
            None,
        )?;
        self.emit_terminal_registry_changed(&registry, revision);
        Ok(())
    }

    /// True when `surface` ever had a view (its first projection wrote its
    /// durable record).
    #[cfg_attr(not(unix), allow(dead_code))]
    pub(crate) fn backend_terminal_viewed(&self, surface: SurfaceId) -> bool {
        self.reserved_in_process_terminals.lock().unwrap().contains_key(&surface)
    }

    /// Removes and stops a never-viewed backend terminal (its killer closes
    /// the app's terminal). A viewed or unknown surface is left alone: its
    /// views and the normal exit path own it.
    #[cfg_attr(not(unix), allow(dead_code))]
    pub(crate) fn close_backend_terminal(&self, id: SurfaceId) {
        if !self.is_unregistered_app_terminal(id) {
            return;
        }
        self.app_terminals.lock().unwrap().remove(&id);
        let removed = {
            let mut state = self.state.lock().unwrap();
            let Some(surface) = state.surfaces.get(&id).cloned() else { return };
            let (mut removed, _) = remove_terminal_runtime_from_state(self, &mut state, &surface);
            if let Some(runtime) = state.surfaces.remove(&id) {
                removed.push(runtime);
            }
            removed
        };
        for surface in removed {
            surface.kill();
            self.emit(super::MuxEvent::SurfaceExited(surface.id));
        }
    }
}

#[cfg(all(test, unix))]
#[path = "app_terminals_tests.rs"]
mod tests;
