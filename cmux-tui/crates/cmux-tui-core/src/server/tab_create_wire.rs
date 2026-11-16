//! `new-tab`: the fields of the request and the create that they ask for.

use std::collections::BTreeMap;
use std::sync::Arc;

use serde::Deserialize;
use serde_json::Value;

use super::frontend_shell;
use super::optional_surface_size;
use super::placed_terminal_result;
use super::placement_spawn_options;
use crate::Actor;
use crate::Mux;
use crate::PaneId;

/// `new-tab`: a new terminal tab in a pane (default: the active pane).
#[derive(Deserialize)]
pub(super) struct NewTabParams {
    #[serde(default)]
    pub(super) pane: Option<PaneId>,
    #[serde(default)]
    pub(super) cwd: Option<String>,
    /// Extra environment for the new terminal's child only.
    #[serde(default)]
    pub(super) env: Option<BTreeMap<String, String>>,
    /// Expected content size in cells (spawn-at-size avoids shell redraw artifacts).
    #[serde(default)]
    pub(super) cols: Option<u16>,
    #[serde(default)]
    pub(super) rows: Option<u16>,
    /// Mark the new terminal `keep` so it survives with no tab.
    #[serde(default)]
    keep: bool,
    /// Caller-chosen terminal host id (`terminal-placement-env-v1`).
    #[serde(default)]
    pub(super) terminal_id: Option<String>,
    /// `terminal-shell-args-v1`: arguments for the terminal's shell (its
    /// `SHELL` in `env`, else the daemon's default shell).
    #[serde(default)]
    pub(super) shell_args: Option<Vec<String>>,
}

impl NewTabParams {
    /// The prelaunched host's id, so the create adopts it.
    pub(super) fn set_terminal_id(&mut self, terminal_hex: String) {
        self.terminal_id = Some(terminal_hex);
    }

    /// The caller-minted terminal host id, if the request names one.
    pub(super) fn terminal_id(&self) -> Option<&str> {
        self.terminal_id.as_deref()
    }
}

pub(super) fn create(
    mux: &Arc<Mux>,
    client: u64,
    actor: Actor,
    params: NewTabParams,
) -> anyhow::Result<Value> {
    let NewTabParams { pane, cwd, env, cols, rows, keep, terminal_id, shell_args } = params;
    let spawn = placement_spawn_options(
        cwd,
        env.as_ref(),
        terminal_id,
        shell_args,
        frontend_shell(mux, client),
    )?;
    let surface =
        mux.new_tab_with_options_as(&actor, pane, spawn, optional_surface_size(cols, rows))?;
    placed_terminal_result(mux, &surface, keep)
}

#[cfg(test)]
#[path = "tab_create_place_tests.rs"]
mod tab_create_place_tests;

#[cfg(test)]
#[path = "tab_create_place_chain_tests.rs"]
mod tab_create_place_chain_tests;

#[cfg(test)]
#[path = "tab_create_place_fuzz_tests.rs"]
mod tab_create_place_fuzz_tests;
