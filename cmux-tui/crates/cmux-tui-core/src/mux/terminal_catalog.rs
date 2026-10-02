//! The terminal catalog: every live terminal runtime by public id, whether
//! or not a tab places it.

use super::*;

pub(super) fn insert_terminal_runtime_checked(
    state: &mut State,
    surface: Arc<Surface>,
) -> anyhow::Result<()> {
    anyhow::ensure!(surface.kind() == SurfaceKind::Pty, "terminal catalog requires a PTY");
    anyhow::ensure!(
        surface.resource_identity().is_none(),
        "unplaced terminal runtime cannot carry a tab identity"
    );
    register_terminal_runtime_checked(state, &surface)
}

pub(super) fn register_terminal_runtime_checked(
    state: &mut State,
    surface: &Arc<Surface>,
) -> anyhow::Result<()> {
    let Some(terminal_id) = surface.terminal_public_id() else {
        return Ok(());
    };
    let runtime_id = surface
        .terminal_runtime_id()
        .context("terminal content identity requires a PTY runtime")?;
    if let Some(existing) = state.terminal_catalog_by_runtime.get(&runtime_id) {
        anyhow::ensure!(existing == terminal_id, "terminal runtime has two content identities");
    }
    if let Some(existing) = state.terminal_catalog.get(terminal_id) {
        anyhow::ensure!(
            existing.shares_terminal_runtime(surface),
            "terminal content identity points at two runtimes"
        );
    } else {
        if let Some(identity) = surface.terminal_host_identity() {
            for existing in state.terminal_catalog.values().filter(|existing| {
                existing
                    .terminal_host_identity()
                    .is_some_and(|candidate| candidate.terminal_id == identity.terminal_id)
            }) {
                anyhow::ensure!(existing.shares_terminal_runtime(surface), "duplicate_terminal_id");
            }
        }
        state.terminal_catalog.insert(terminal_id.clone(), surface.clone());
    }
    state.terminal_catalog_by_runtime.insert(runtime_id, terminal_id.clone());
    Ok(())
}
