//! `restart-tab` (`tab-restart-v1`): restart a dead terminal tab under the
//! same terminal id (`Mux::restart_dead_tab`, plans/cmux-next/ownership.md
//! section 3.2, cx-7e7b).

use super::*;
use crate::mux::terminal_respawn::manual::TabRestartError;

/// Advertises `restart-tab`: a terminal tab whose shell ended (a host loss
/// the automatic respawn refused or never covers, a process end the tab
/// kept, a keep-layout tab) gets a new shell under the same terminal id,
/// below its previous screen. The tab's id, placement, name, pin and group
/// stay. Unix owners only.
pub(super) const CAPABILITY: &str = "tab-restart-v1";

/// `restart-tab`.
#[derive(Deserialize)]
pub(super) struct Params {
    /// The tab: its numeric surface id or its public `tab_...` id.
    surface: TabRef,
}

/// Accepts the restart and starts the worker; the tree shows the tab
/// restarting, then running under a new incarnation.
pub(super) fn restart(mux: &Arc<Mux>, params: Params) -> anyhow::Result<Value> {
    let surface = resolve_tab_refs(mux, std::slice::from_ref(&params.surface))?[0];
    let accepted = mux.restart_dead_tab(surface)?;
    Ok(json!({
        "surface": surface,
        "terminal": accepted.terminal,
        "previous_incarnation": accepted.previous_incarnation,
        "state": "respawning",
    }))
}

/// The `error_code` of a refused restart: `tab-not-terminal`,
/// `tab-not-dead` or `tab-restart-unavailable`.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<TabRestartError>().map(|error| error.code().to_string())
}
