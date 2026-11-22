//! Terminal runtime indexes in state: checked surface and runtime inserts and removals, terminal matching, and runtime placement lookups.

use super::*;

pub(super) fn insert_surface_checked(
    state: &mut State,
    surface: Arc<Surface>,
) -> anyhow::Result<()> {
    if state.surfaces.contains_key(&surface.id) {
        anyhow::bail!("duplicate_surface_id");
    }
    if let Some(expected_tab) = state.resource_indexes.tab_ids.get(&surface.id) {
        let expected_content = state
            .resource_indexes
            .content_ids
            .get(&surface.id)
            .ok_or_else(|| anyhow::anyhow!("reserved tab has no content identity"))?;
        let actual = surface
            .resource_identity()
            .ok_or_else(|| anyhow::anyhow!("public tab slot received auxiliary content"))?;
        if &actual.tab_id != expected_tab || &actual.content_id != expected_content {
            anyhow::bail!("surface resource identity does not match its reserved tab slot");
        }
    } else if let Some(identity) = surface.resource_identity() {
        if state.resource_indexes.tabs.contains_key(&identity.tab_id) {
            anyhow::bail!("duplicate_tab_id");
        }
        if matches!(identity.content_id, ContentPublicId::Browser(_))
            && state.resource_indexes.content_placements.contains_key(&identity.content_id)
        {
            anyhow::bail!("duplicate_content_id");
        }
    }
    if let Some(identity) = surface.resource_identity()
        && let ContentPublicId::Terminal(terminal_id) = &identity.content_id
    {
        anyhow::ensure!(
            surface.terminal_public_id() == Some(terminal_id),
            "terminal placement identity does not match its runtime"
        );
    }
    register_terminal_runtime_checked(state, &surface)?;
    // Surface insertion is the only way a tab placement enters live state, so
    // it is also where the topology takes ownership of that tab's identity.
    // Every later reader takes identity from the topology, never from here.
    if let Some(identity) = surface.resource_identity().cloned() {
        state.register_tab_identity(surface.id, &identity);
    }
    state.surfaces.insert(surface.id, surface);
    Ok(())
}

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

pub(super) fn insert_restored_terminal_runtime_checked(
    state: &mut State,
    surface: Arc<Surface>,
) -> anyhow::Result<()> {
    let terminal_id = surface
        .terminal_public_id()
        .cloned()
        .context("restored terminal omitted its public content identity")?;
    let content_id = ContentPublicId::Terminal(terminal_id);
    let placements = state.placements_of_content(&content_id).to_vec();
    if placements.is_empty() {
        return insert_terminal_runtime_checked(state, surface);
    }

    anyhow::ensure!(
        placements.contains(&surface.id),
        "restored terminal runtime is not one of its durable placements"
    );
    insert_surface_checked(state, surface.clone())?;
    for placement in placements.into_iter().filter(|placement| *placement != surface.id) {
        anyhow::ensure!(
            !state.surfaces.contains_key(&placement),
            "restored terminal placement is already materialized"
        );
        let tab_id = state
            .resource_indexes
            .tab_ids
            .get(&placement)
            .cloned()
            .context("restored terminal placement has no tab identity")?;
        let projected = surface
            .project_terminal(placement, TabResourceIdentity::new(tab_id, content_id.clone()))?;
        insert_surface_checked(state, projected)?;
    }
    Ok(())
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
        state.insert_catalog_terminal(terminal_id, surface)?;
    }
    state.terminal_catalog_by_runtime.insert(runtime_id, terminal_id.clone());
    Ok(())
}

/// Remove a terminal catalog owner and every view that projects it. Durable
/// exit and explicit close share this path so multiview teardown cannot leave
/// a reverse catalog entry or a secondary placement behind. The runtime is
/// optional because restored topology exists before host adoption.
pub(super) fn remove_terminal_content_from_state(
    mux: &Mux,
    state: &mut State,
    terminal_id: &TerminalPublicId,
) -> (Option<Arc<Surface>>, Vec<Arc<Surface>>, bool) {
    let runtime = state.remove_catalog_terminal(terminal_id);
    let mut targets =
        state.placements_of_content(&ContentPublicId::Terminal(terminal_id.clone())).to_vec();
    if let Some(runtime_id) = runtime.as_ref().and_then(|runtime| runtime.terminal_runtime_id()) {
        targets.extend(state.surfaces.iter().filter_map(|(placement, candidate)| {
            (candidate.terminal_runtime_id() == Some(runtime_id)).then_some(*placement)
        }));
    }
    targets.sort_unstable();
    targets.dedup();
    let mut removed = Vec::with_capacity(targets.len());
    let mut split_index_dirty = false;
    for target in targets {
        let (candidate, topology_changed) = remove_surface(mux, state, target);
        split_index_dirty |= topology_changed;
        if let Some(candidate) = candidate {
            removed.push(candidate);
        }
    }
    if split_index_dirty {
        Mux::rebuild_split_screen_index(state);
    }
    (runtime, removed, split_index_dirty)
}

/// Remove one known terminal runtime and every placement that projects it.
/// Ordinary topology removal must leave the catalog owner alive so a terminal
/// can have zero views and be projected again later.
pub(super) fn remove_terminal_runtime_from_state(
    mux: &Mux,
    state: &mut State,
    runtime: &Surface,
) -> (Vec<Arc<Surface>>, bool) {
    let Some(terminal_id) = runtime.terminal_public_id().cloned() else {
        return (Vec::new(), false);
    };
    if !state
        .terminal_catalog
        .get(&terminal_id)
        .is_some_and(|catalogued| catalogued.shares_terminal_runtime(runtime))
    {
        return (Vec::new(), false);
    }
    let (_, removed, split_index_dirty) =
        remove_terminal_content_from_state(mux, state, &terminal_id);
    (removed, split_index_dirty)
}

pub(super) fn validate_terminal_hex(value: &str, error: &'static str) -> anyhow::Result<()> {
    if TerminalId::from_hex(value).is_none() {
        anyhow::bail!(error);
    }
    Ok(())
}

pub(super) fn unique_terminal_match<T>(
    terminal_id: &str,
    identities: impl IntoIterator<Item = (T, TerminalHostIdentity)>,
) -> anyhow::Result<Option<(T, TerminalHostIdentity)>> {
    let mut found = None;
    for (value, identity) in identities {
        if identity.terminal_id != terminal_id {
            continue;
        }
        anyhow::ensure!(found.is_none(), "duplicate_terminal_id");
        found = Some((value, identity));
    }
    Ok(found)
}

/// Return one materialized view of `runtime`. The public reverse index is the
/// steady-state fast path. The runtime scan also admits a newly-created view
/// before it has been inserted into a pane: creation must bind that reserved
/// tab exactly once, while a detached zero-view terminal has no entry in
/// `state.surfaces` and therefore remains detached.
pub(super) fn terminal_placement_for_runtime(
    state: &State,
    runtime: &Surface,
) -> Option<SurfaceId> {
    let terminal_id = runtime.terminal_public_id()?;
    state
        .placements_of_content(&ContentPublicId::Terminal(terminal_id.clone()))
        .iter()
        .copied()
        .find(|placement| {
            state
                .surfaces
                .get(placement)
                .is_some_and(|surface| surface.shares_terminal_runtime(runtime))
        })
        .or_else(|| {
            state
                .surfaces
                .iter()
                .filter_map(|(placement, surface)| {
                    (surface.shares_terminal_runtime(runtime)
                        && surface.resource_identity().is_some())
                    .then_some(*placement)
                })
                .min()
        })
}

/// Return one representative for each content runtime plus every nonterminal
/// surface. Runtime-wide mutations must not repeat host I/O or render work for
/// every terminal view, and catalog-only terminals still need those updates.
pub(super) fn unique_surface_runtimes(state: &State) -> Vec<Arc<Surface>> {
    let mut seen_terminals = HashSet::new();
    state
        .terminal_catalog
        .values()
        .chain(state.surfaces.values())
        .filter(|surface| {
            surface.terminal_runtime_id().is_none_or(|runtime| seen_terminals.insert(runtime))
        })
        .cloned()
        .collect()
}
