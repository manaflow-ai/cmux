//! `new-tab`: the fields of the request and the create that they ask for.
//!
//! `tab-create-place-v1`: the request says where its tab goes (`place`) and
//! names its creation (`transaction`). The creation takes its slot when the
//! request arrives ([`Command::admit_tab_place`]), before its terminal
//! launches: a tab that comes late lands where its request asked, also when
//! other tabs came in between.

use std::collections::BTreeMap;
use std::sync::Arc;

use serde::Deserialize;
use serde_json::Value;

use super::Command;
use super::frontend_shell;
use super::optional_surface_size;
use super::placed_terminal_result;
use super::placement_spawn_options;
use super::validate_client_transaction;
use crate::Actor;
use crate::Mux;
use crate::PaneId;
use crate::mux::tab_strip::tab_place::{CreateRequest, TabPlaceRequest};

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
    /// `tab-create-place-v1`: where the tab goes in the strip of `pane`.
    #[serde(default)]
    place: Option<TabPlaceRequest>,
    /// `tab-create-place-v1`: the name of this creation. The `tab-added` of
    /// the tab and the reply carry it, and a later request of the connection
    /// names the creation by it (`place.after_creation`).
    #[serde(default)]
    transaction: Option<String>,
    /// The slot that the creation took when its request arrived.
    #[serde(skip)]
    hole: Option<u64>,
}

impl NewTabParams {
    /// A plain shell that may wait for its first need
    /// (mux/terminal_respawn/lazy.rs): no shell of the app's, environment,
    /// shell arguments or caller-chosen terminal id.
    pub(super) fn may_start_lazily(&self, frontend_shell: bool) -> bool {
        !frontend_shell
            && self.env.as_ref().is_none_or(BTreeMap::is_empty)
            && self.shell_args.is_none()
            && self.terminal_id.is_none()
    }
}

impl Command {
    /// A `new-tab` with a `place` or a `transaction` takes its slot in the
    /// list of its pane now, when the request arrives. Its terminal launches
    /// later; the requests that arrive before the launch ends keep their
    /// order against it. A request that its handler refuses takes no slot.
    pub(super) fn admit_tab_place(&mut self, mux: &Mux, client: u64) -> Option<u64> {
        let Self::NewTab(params) = self else { return None };
        validate_client_transaction(params.transaction.as_deref()).ok()?;
        params.hole = mux.admit_tab_creation(CreateRequest {
            client,
            pane: params.pane,
            place: params.place.as_ref(),
            transaction: params.transaction.as_deref(),
        });
        params.hole
    }
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
    let frontend_shell = frontend_shell(mux, client);
    let may_start_lazily = params.may_start_lazily(frontend_shell);
    let NewTabParams {
        pane,
        cwd,
        env,
        cols,
        rows,
        keep,
        terminal_id,
        shell_args,
        place,
        transaction,
        hole,
    } = params;
    validate_client_transaction(transaction.as_deref())?;
    // Before the spawn options: a creation that fails there keeps the slot
    // that a later request names.
    let request =
        CreateRequest { client, pane, place: place.as_ref(), transaction: transaction.as_deref() };
    let placing = mux.place_tab_creation(request, hole, true)?;
    // A plain shell from a creator not showing it may wait for its first
    // need (mux/terminal_respawn/lazy.rs).
    let _lazy = crate::mux::terminal_respawn::lazy::lazy_create_scope(
        mux,
        may_start_lazily
            && !crate::mux::terminal_respawn::lazy::actor_shows_what_it_creates(&actor),
    );
    let spawn =
        placement_spawn_options(cwd, env.as_ref(), terminal_id, shell_args, frontend_shell)?;
    let surface =
        mux.new_tab_with_options_as(&actor, pane, spawn, optional_surface_size(cols, rows))?;
    placing.made(surface.id);
    let mut reply = placed_terminal_result(mux, &surface, keep)?;
    if let (Some(transaction), Some(fields)) = (transaction, reply.as_object_mut()) {
        fields.insert("transaction".to_string(), Value::String(transaction));
    }
    Ok(reply)
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

#[cfg(test)]
#[path = "tab_create_place_restart_tests.rs"]
mod tab_create_place_restart_tests;
