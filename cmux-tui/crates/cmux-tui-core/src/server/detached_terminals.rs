//! Detached terminals (`detached-terminals-v1`) and kept terminals with no
//! tab here: `create-terminal {detached:true}` and their view sizing.

use super::*;
use crate::resource::ContentPublicId;
use crate::workspace_registry::TerminalLifecycle;

/// `create-terminal {detached:true}` creates a kept terminal with no
/// workspace, pane, screen or tab (cmux-next "Open Terminal on Machine Here"
/// shows it as a remote-terminal tab in another session's layout).
pub const DETACHED_TERMINALS_CAPABILITY: &str = "detached-terminals-v1";

/// The spawn part of a detached `create-terminal` request.
pub(super) struct DetachedCreate {
    pub(super) argv: Option<Vec<String>>,
    pub(super) cwd: Option<String>,
    pub(super) name: Option<String>,
    pub(super) size: Option<(u16, u16)>,
    pub(super) env: Vec<(String, String)>,
}

/// `create-terminal {detached:true}`: the host spawns first; the resource
/// projection then commits in the same receipted mutation and gives the
/// terminal its durable public id before the host is activated. If that
/// commit fails the terminal is ended, because nothing else would end a kept
/// terminal with no tab. A daemon that dies between the two leaves a host
/// that adoption restores as a kept, tabless terminal.
pub(super) fn create(
    mux: &Arc<Mux>,
    client: u64,
    request: DetachedCreate,
    terminal_id: Option<String>,
    mutation: MutationRequest,
) -> anyhow::Result<Value> {
    let (registry_id, generation) = mux.registry_identity();
    let workspace_mutation = workspace_mutation(mux, client, &mutation)?;
    let DetachedCreate { argv, cwd, name, size, env } = request;
    let result = mux.create_detached_terminal_with_mutation(
        crate::mux::DetachedTerminalSpawn { argv, cwd, name, size, env },
        terminal_id.as_deref(),
        mutation.expected_generation.as_deref(),
        mutation.expected_revision,
        &workspace_mutation,
    )?;
    let projection = json!({"terminal_id": result.terminal_id, "detached": true});
    if let Err(error) = mux.commit_full_resource_projection_with_mutation(
        &workspace_mutation,
        "raw.terminal.create_detached",
        &projection,
        projection.clone(),
    ) {
        if let Err(close_error) = mux.end_unpublished_detached_terminal(
            &result.terminal_id,
            result.terminal_incarnation.as_deref(),
        ) {
            eprintln!(
                "cmux-tui: could not end detached terminal {} after its creation failed: \
                 {close_error:#}",
                result.terminal_id
            );
        }
        return Err(error);
    }
    mux.activate_created_terminal_surface(result.created_surface)?;
    mux.reap_created_terminal_surface(result.created_surface);
    let terminal = mux
        .resolve_terminal(&result.terminal_id)?
        .context("created terminal has no durable terminal row")?;
    let terminal_resource_id = mux.terminal_public_id_for_host(&result.terminal_id)?;
    let already_exited = terminal.terminal.lifecycle == TerminalLifecycle::Exited;
    Ok(json!({
        "surface": Value::Null,
        "terminal_id": terminal.terminal.terminal_id,
        "terminal_incarnation": terminal.terminal.incarnation,
        "terminal_resource_id": terminal_resource_id,
        "pane": Value::Null,
        "screen": Value::Null,
        "workspace": Value::Null,
        "key": crate::workspace_registry::DETACHED_TERMINAL_WORKSPACE_KEY,
        "lifecycle": terminal.terminal.lifecycle,
        "exit": terminal.terminal.exit,
        "already_exited": already_exited,
        "terminal_revision": terminal.terminal_revision,
        "replayed": result.replayed,
        "registry_id": registry_id,
        "generation": generation,
    }))
}

/// Whether a view's sizing still has a live target: a tab placement, or a
/// kept terminal with no tab here. A kept terminal may have its only view in
/// another session's layout (a remote-terminal tab), so an attached geometry
/// owner keeps sizing it; any other unplaced surface is a view whose tab
/// closed. A terminal that still has a tab here does not take a closed tab's
/// sizing, so a lease on a closed tab of it stays superseded.
pub(super) fn accepts_view_sizing(mux: &Mux, id: SurfaceId) -> bool {
    if mux.with_state(|state| state.pane_of(id).is_some()) {
        return true;
    }
    let Some(surface) = mux.surface(id).filter(|surface| !surface.is_dead()) else {
        return false;
    };
    let unplaced = surface.terminal_public_id().is_none_or(|terminal_id| {
        mux.with_state(|state| {
            state.placements_of_content(&ContentPublicId::Terminal(terminal_id.clone())).is_empty()
        })
    });
    unplaced
        && mux
            .resource_terminal_host_identity(&surface)
            .is_some_and(|identity| mux.terminal_keep(&identity.terminal_id).unwrap_or(false))
}
