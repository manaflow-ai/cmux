//! Terminals of an incognito (ephemeral) workspace keep nothing on disk
//! (leo-workspace design/spaces.md "Incognito": nothing kept, never
//! restored, deleted at close, quit and crash):
//!
//! - their shells start with history off ([`crate::shell_integration::keep_no_history`]);
//! - their screen and scrollback stay in memory: the output store writes no
//!   snapshot or segment for them and their exit stores no replay
//!   (`OutputStore::mark_private`);
//! - they get no relaunch record (`terminal_relaunch`: cwd, argv, title,
//!   agent session).
//!
//! A terminal belongs to the workspace it was created in
//! (`terminal_hosts.workspace_key`); content never moves between an
//! ephemeral and a normal workspace (`state::ephemeral_moves`).

use super::*;

impl Mux {
    /// Workspace `workspace_key` is being created incognito.
    pub(super) fn note_incognito_workspace(&self, workspace_key: &str) {
        self.incognito_workspace_keys
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(workspace_key.to_string());
    }

    /// Whether workspace `workspace_key` is incognito. A registry error
    /// reads as not incognito.
    pub(crate) fn workspace_key_is_ephemeral(&self, workspace_key: &str) -> bool {
        if self
            .incognito_workspace_keys
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains(workspace_key)
        {
            return true;
        }
        self.workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .read_state(|connection| {
                crate::state::store::workspace_key_is_ephemeral(connection, workspace_key)
            })
            .unwrap_or(false)
    }

    /// [`Self::terminal_spawn_options`] for a terminal of `workspace_key`:
    /// an incognito workspace's shell starts with history off.
    pub(crate) fn terminal_spawn_options_in(
        &self,
        cwd: Option<String>,
        command: Option<Vec<String>>,
        size: Option<(u16, u16)>,
        env: &[(String, String)],
        workspace_key: Option<&str>,
    ) -> (SurfaceOptions, (u16, u16)) {
        let incognito = workspace_key.is_some_and(|key| self.workspace_key_is_ephemeral(key));
        self.terminal_spawn_options_for(cwd, command, size, env, incognito)
    }

    /// [`Self::terminal_spawn_options`], with history off when `incognito`.
    pub(super) fn terminal_spawn_options_for(
        &self,
        cwd: Option<String>,
        command: Option<Vec<String>>,
        size: Option<(u16, u16)>,
        env: &[(String, String)],
        incognito: bool,
    ) -> (SurfaceOptions, (u16, u16)) {
        let (mut options, cell_pixels) = self.terminal_spawn_options(cwd, command, size, env);
        if incognito {
            crate::shell_integration::keep_no_history(&mut options.extra_env);
        }
        (options, cell_pixels)
    }

    /// An incognito terminal was created: it is kept in memory only from
    /// now on, also after its workspace's flag row is gone.
    pub(super) fn note_incognito_terminal(&self, surface: &Surface) {
        if let Some(public_id) = surface.terminal_public_id() {
            self.output_store.mark_private(public_id);
        }
    }
}
