//! Scoped topology projection: a create restates only the workspaces it
//! changed, so its registry hold and its journal record follow the size of
//! those workspaces, not of the session (nx-scale W2c).
//!
//! The scope is the workspaces the caller names plus, when the active
//! workspace changed, the stored and the live active workspace (the focus
//! flags of their screens and panes change). The stored side is read for
//! the scope only. The full projection stays the reference: debug builds
//! (and `CMUX_TUI_PROJECTION_CROSSCHECK=1`) compare every scoped projection
//! with it and count mismatches in `server-stats`. A resource that crossed
//! the scope (moved out of or into a scoped workspace) fails the scoped
//! projection with [`ScopeEscaped`], and the full projection runs instead.

use std::collections::HashSet;
use std::sync::{Arc, OnceLock};
use std::time::Instant;

use super::projection_crosscheck::projection_difference;
use super::*;
use crate::diagnostics::ProjectionSpans;
use crate::resource::{BrowserPublicId, WorkspacePublicId};
use crate::workspace_registry::{RegistryTerminal, ResourceTopologySnapshot};

type TerminalLookup<'a> = dyn Fn(&str) -> anyhow::Result<Option<RegistryTerminal>> + 'a;
type TabOrder<'a> = dyn Fn(&State, &TerminalPublicId) -> anyhow::Result<Vec<TabPublicId>> + 'a;
type StoredLive<'a> = dyn Fn(&str, &str) -> anyhow::Result<bool> + 'a;

/// What a live-tree projection diffs against, and how it reads the rest.
pub(super) struct LiveTreeInput<'a> {
    /// The stored topology: complete, or only the scope's subtrees.
    pub(super) before: &'a ResourceTopologySnapshot,
    /// `None` walks every workspace; otherwise only these subtrees.
    pub(super) scope: Option<&'a HashSet<WorkspacePublicId>>,
    /// The non-tombstoned durable record of a terminal host id.
    pub(super) terminals: &'a TerminalLookup<'a>,
    /// A terminal's tab ids in canonical order.
    pub(super) tab_order: &'a TabOrder<'a>,
    /// Whether the store holds a live `resource` row ("screen", "pane" or
    /// "tab") with this public id.
    pub(super) stored_live: &'a StoredLive<'a>,
    /// The host of every active stored terminal row the scope's tabs show. A
    /// tab whose row, focus and terminal row are all stored as the walk would
    /// write them is not restated. `None` states each tab of the walk again:
    /// a full walk, and a scoped walk of a workspace that the registry's fold
    /// does not hold whole (`workspace_registry/public_fold.rs`).
    pub(super) active_terminal_hosts: Option<&'a HashMap<TerminalPublicId, String>>,
    /// Which workspaces outside the scope a scoped walk states again.
    pub(super) rows: WorkspaceRows,
    /// A scoped walk that also states each terminal of the catalog that has no view (the full
    /// walk states them always): the last step of the restatement after a start.
    pub(super) unplaced_terminals: bool,
}

/// The workspace rows (the row and the public value of a workspace, with its position) that a
/// scoped walk states again for the workspaces outside its scope. A workspace in the scope is
/// always stated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum WorkspaceRows {
    /// Every live workspace (a change that can move any of them).
    All,
    /// Only the workspaces at this live position and after it: the caller knows that the row and
    /// the public value of every workspace before it are stored and stated as they are (a close
    /// of the workspace that was at this position moves only the ones after it).
    From(usize),
    /// A change that added the workspaces at this live position and after it (none when the
    /// position is the count of live workspaces) and that removed and moved no workspace: a
    /// created view. Only the added workspaces are stated outside the scope, and the stored side
    /// is read for the scope only: it holds no row of another workspace.
    Added(usize),
}

impl WorkspaceRows {
    pub(super) fn states(self, position: usize) -> bool {
        match self {
            Self::All => true,
            Self::From(first) | Self::Added(first) => position >= first,
        }
    }

    /// Whether the stored side of the walk holds the workspaces of the scope only (no active
    /// screen of another workspace): the walk then has nothing to compare for a workspace that
    /// it does not state.
    pub(super) fn scope_frame(self) -> bool {
        matches!(self, Self::Added(_))
    }
}

/// A scoped projection met a resource that crossed its scope.
#[derive(Debug)]
pub(super) struct ScopeEscaped(String);

impl std::fmt::Display for ScopeEscaped {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "scoped projection escaped its scope: {}", self.0)
    }
}

impl std::error::Error for ScopeEscaped {}

fn escaped(what: String) -> anyhow::Error {
    anyhow::Error::new(ScopeEscaped(what))
}

#[cfg(test)]
thread_local! {
    static CROSSCHECK_OFF: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

#[cfg(test)]
thread_local! {
    /// Full live-tree projections run on this thread.
    pub(super) static FULL_PROJECTIONS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
    /// Workspaces that a live-tree projection (full or scoped) restated on
    /// this thread.
    pub(super) static WORKSPACES_PROJECTED: std::cell::Cell<u64> =
        const { std::cell::Cell::new(0) };
}

/// Run `body` with the cross-check off on this thread, as release builds run.
#[cfg(test)]
pub(crate) fn without_crosscheck<R>(body: impl FnOnce() -> R) -> R {
    CROSSCHECK_OFF.with(|off| off.set(true));
    let result = body();
    CROSSCHECK_OFF.with(|off| off.set(false));
    result
}

/// Debug builds always compare; release builds when the daemon runs with
/// `CMUX_TUI_PROJECTION_CROSSCHECK=1`.
pub(super) fn crosscheck_enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    #[cfg(test)]
    if CROSSCHECK_OFF.with(std::cell::Cell::get) {
        return false;
    }
    cfg!(debug_assertions)
        || *ENABLED.get_or_init(|| {
            std::env::var_os("CMUX_TUI_PROJECTION_CROSSCHECK").is_some_and(|value| value == "1")
        })
}

impl Mux {
    /// Full live-tree projections run on this thread (test hook).
    #[cfg(test)]
    pub(crate) fn full_projections_for_test() -> u64 {
        FULL_PROJECTIONS.with(std::cell::Cell::get)
    }

    /// Workspaces that live-tree projections restated on this thread (test
    /// hook).
    #[cfg(test)]
    pub(crate) fn workspaces_projected_for_test() -> u64 {
        WORKSPACES_PROJECTED.with(std::cell::Cell::get)
    }

    /// The projection for a commit whose result is `result`: a created view
    /// changed one workspace, so only that workspace is projected. That does
    /// not wait for the registry's fold of the journal: the fold only drops
    /// values the journal states already, and a fold that was lost drops none.
    pub(crate) fn created_view_projection_locked(
        &self,
        registry: &WorkspaceRegistry,
        state: &mut State,
        result: Value,
    ) -> anyhow::Result<ResourceEffectProjection> {
        match created_view_workspace(&result) {
            Some(workspace) => {
                let rows = created_view_rows(registry, state)?;
                self.resource_effect_projection_scoped_rows_locked(
                    registry,
                    state,
                    &[workspace],
                    rows,
                    result,
                )
            }
            None => self.resource_effect_projection_locked(registry, state, result),
        }
    }

    /// [`Self::created_view_projection_locked`] for several created views
    /// committed together (a creation group): the scope is all their
    /// workspaces, and `result` is the first view's.
    pub(crate) fn created_views_projection_locked(
        &self,
        registry: &WorkspaceRegistry,
        state: &mut State,
        views: &[&Value],
        result: Value,
    ) -> anyhow::Result<ResourceEffectProjection> {
        let mut workspaces = Vec::with_capacity(views.len());
        for view in views {
            match created_view_workspace(view) {
                Some(workspace) => {
                    if !workspaces.contains(&workspace) {
                        workspaces.push(workspace);
                    }
                }
                None => return self.resource_effect_projection_locked(registry, state, result),
            }
        }
        let rows = created_view_rows(registry, state)?;
        self.resource_effect_projection_scoped_rows_locked(
            registry,
            state,
            &workspaces,
            rows,
            result,
        )
    }

    /// [`Self::resource_effect_projection_locked`] for a change confined to
    /// `workspaces`. Same fence contract: the caller holds registry -> state
    /// and commits the returned patch before releasing either.
    pub(crate) fn resource_effect_projection_scoped_locked(
        &self,
        registry: &WorkspaceRegistry,
        state: &mut State,
        workspaces: &[WorkspacePublicId],
        result: Value,
    ) -> anyhow::Result<ResourceEffectProjection> {
        self.resource_effect_projection_scoped_rows_locked(
            registry,
            state,
            workspaces,
            WorkspaceRows::All,
            result,
        )
    }

    /// The projection of a change that is confined to `workspaces` and that removed and moved
    /// no workspace (it may have added some after the last one): a move in a workspace or
    /// between 2 of them, and one part of the restatement after a start. Nothing outside the
    /// scope is stated and the stored side is read for the scope only, so the hold and the
    /// journal record follow the size of those workspaces. A store that does not hold exactly
    /// the workspaces of the live list states each workspace row, as a created view does.
    pub(crate) fn changed_workspaces_projection_locked(
        &self,
        registry: &WorkspaceRegistry,
        state: &mut State,
        workspaces: &[WorkspacePublicId],
        result: Value,
    ) -> anyhow::Result<ResourceEffectProjection> {
        let rows = created_view_rows(registry, state)?;
        self.resource_effect_projection_scoped_rows_locked(
            registry, state, workspaces, rows, result,
        )
    }

    /// The projection of a change that its caller made on a copy of the state (`after`; the
    /// live state is `before`): a move of a column, a tab, a pane or a screen, a dock or row
    /// change. Only the workspaces that differ between the two are projected
    /// ([`changed_workspaces`]), so the hold and the journal record of such a move follow the
    /// size of those workspaces, not of the session. Each of these changes took the full
    /// projection before: at 826 workspaces a move of one column stated each live value of
    /// the session.
    ///
    /// The full projection stays for a change that removed or moved a workspace, that moved a
    /// pane with its tabs to another workspace (the stored workspace of its terminals is
    /// written through their rows, which a scoped walk leaves out when the tab rows are equal),
    /// or that differs in more than [`CHANGED_WORKSPACES_MAX`] workspaces.
    ///
    /// A move of a screen into a new last workspace is scoped, and it is right for one reason
    /// only: the fold never holds a new workspace whole, so the walk states each value of it
    /// and each terminal of the moved screen gets its row (the stored workspace of a terminal
    /// follows that row: `retarget_terminal_workspace` in `mux/tab_drag.rs`). A change that
    /// marks a new workspace whole before its first commit must send this move to the full
    /// projection.
    pub(crate) fn changed_state_projection_locked(
        &self,
        registry: &WorkspaceRegistry,
        before: &State,
        after: &mut State,
        result: Value,
    ) -> anyhow::Result<ResourceEffectProjection> {
        // The change can have removed a screen, a pane or a tab: its index entry would look
        // like a resource that moved out of the scope.
        after.rebuild_resource_indexes();
        let workspaces = match changed_workspaces(before, after) {
            Some(workspaces) if workspaces.is_empty() => after
                .workspaces
                .get(after.active_workspace)
                .map(|workspace| vec![workspace.public_id.clone()]),
            changed => changed,
        };
        match workspaces {
            Some(workspaces) => {
                self.changed_workspaces_projection_locked(registry, after, &workspaces, result)
            }
            None => self.resource_effect_projection_locked(registry, after, result),
        }
    }

    /// The projection of one part of the restatement after a daemon start
    /// (`mux/startup_restore/restate_parts.rs`): `workspaces` and nothing outside them, with no
    /// read of the store's workspace count. A part changes no value of the live tree, so it
    /// added, removed and moved no workspace. A stored row of a workspace that the live tree
    /// lost stays for the commit that meets it (a create states each workspace row then).
    ///
    /// `None` when the walk met a resource that crossed its scope. A part does not fall back
    /// to the full projection (that is the hold the parts exist to avoid): its workspaces stay
    /// not whole, and the next commit in one of them states it. A part also has no debug
    /// cross-check: the reference is one full projection for each part, and it writes the rows
    /// of the workspaces that no part has reached, which a part must not write.
    pub(crate) fn restate_part_projection_locked(
        &self,
        registry: &WorkspaceRegistry,
        state: &mut State,
        workspaces: &[WorkspacePublicId],
    ) -> anyhow::Result<Option<ResourceEffectProjection>> {
        let rows = WorkspaceRows::Added(state.workspaces.len());
        let result = Value::Object(Default::default());
        match self.scoped_rows_walk(registry, state, workspaces, rows, result, false) {
            Ok(projection) => Ok(Some(projection)),
            Err(error) if error.is::<ScopeEscaped>() => Ok(None),
            Err(error) => Err(error),
        }
    }

    /// The last step of the restatement after a start: each terminal of the catalog that has
    /// no view and that the registry's fold does not hold (the full walk states them; a part
    /// does not reach them, because no workspace owns them). The walk needs a scope: it is
    /// `workspace`, which states nothing when the fold holds it whole. `None` when there is no
    /// such terminal, or when the walk met a resource that crossed its scope.
    pub(crate) fn restate_unplaced_terminals_projection_locked(
        &self,
        registry: &WorkspaceRegistry,
        state: &mut State,
        workspace: &WorkspacePublicId,
    ) -> anyhow::Result<Option<ResourceEffectProjection>> {
        let placed = placed_terminals(state);
        let owed = (&state.terminal_catalog).into_iter().any(|(id, surface)| {
            !placed.contains(id)
                && !self.is_unregistered_app_terminal(surface.id)
                && !registry.fold_holds("terminal", id.as_str())
        });
        if !owed {
            return Ok(None);
        }
        let rows = WorkspaceRows::Added(state.workspaces.len());
        let result = Value::Object(Default::default());
        let scope = std::slice::from_ref(workspace);
        match self.scoped_rows_walk(registry, state, scope, rows, result, true) {
            Ok(projection) => Ok(Some(projection)),
            Err(error) if error.is::<ScopeEscaped>() => Ok(None),
            Err(error) => Err(error),
        }
    }

    /// [`Self::resource_effect_projection_scoped_locked`] that states again, of the workspaces
    /// outside the scope, only the ones `rows` names. The same scoped read, walk, fallback and
    /// cross-check; the one difference is the workspace rows it leaves out.
    ///
    /// A workspace of the scope that the registry's fold does not hold whole is stated again
    /// here, each live value of it and not only the changed ones, and the projection names the
    /// scope in `restated`: the caller marks it whole after the commit
    /// (`WorkspaceRegistry::mark_workspaces_whole`). So a change that comes before the
    /// restatement after a start reached its workspace states that workspace in its own commit.
    pub(crate) fn resource_effect_projection_scoped_rows_locked(
        &self,
        registry: &WorkspaceRegistry,
        state: &mut State,
        workspaces: &[WorkspacePublicId],
        rows: WorkspaceRows,
        result: Value,
    ) -> anyhow::Result<ResourceEffectProjection> {
        let walked =
            self.scoped_rows_walk(registry, state, workspaces, rows, result.clone(), false);
        let projection = match walked {
            Ok(projection) => projection,
            Err(error) if error.is::<ScopeEscaped>() => {
                registry.resource_projection_stats().scope_fell_back();
                return self.resource_effect_projection_locked(registry, state, result);
            }
            Err(error) => return Err(error),
        };
        if crosscheck_enabled() {
            // The reference rebuilds every index; keep the scoped walk's
            // indexes so the cross-check does not change what later
            // projections see.
            let indexes = state.resource_indexes.clone();
            let difference = self
                .full_projection_spans(registry, state, result)
                .and_then(|(full, _)| projection_difference(registry, &projection, &full))
                .unwrap_or_else(|error| Some(format!("cross-check failed: {error:#}")));
            state.resource_indexes = indexes;
            registry.resource_projection_stats().crosschecked(difference.is_none());
            if let Some(difference) = difference {
                #[cfg(test)]
                // crash-allow: unit tests only; a release daemon counts and logs it.
                panic!("scoped projection differs from the full projection: {difference}");
                #[cfg(not(test))]
                eprintln!(
                    "cmux-tui: scoped projection differs from the full projection: {difference}"
                );
            }
        }
        Ok(projection)
    }

    /// The scoped read and walk of [`Self::resource_effect_projection_scoped_rows_locked`], with
    /// no fall back and no cross-check: a walk that met a resource that crossed its scope is
    /// the error [`ScopeEscaped`].
    fn scoped_rows_walk(
        &self,
        registry: &WorkspaceRegistry,
        state: &mut State,
        workspaces: &[WorkspacePublicId],
        rows: WorkspaceRows,
        result: Value,
        unplaced_terminals: bool,
    ) -> anyhow::Result<ResourceEffectProjection> {
        let started = Instant::now();
        let mut scope = workspaces.iter().cloned().collect::<HashSet<_>>();
        let read_before = |scope: &HashSet<WorkspacePublicId>| {
            let scope = scope_list(scope);
            if rows.scope_frame() {
                registry.resource_topology_of_scope(&scope)
            } else {
                registry.resource_topology_scoped(&scope)
            }
        };
        let mut before = read_before(&scope)?;
        let live_active = state
            .workspaces
            .get(state.active_workspace)
            .map(|workspace| workspace.public_id.clone());
        if before.active_workspace != live_active {
            let mut added = false;
            for workspace in [live_active, before.active_workspace.clone()].into_iter().flatten() {
                added |= scope.insert(workspace);
            }
            if added {
                before = read_before(&scope)?;
            }
        }
        #[cfg(test)]
        crate::walk_counters::frame_rows_read(before.active_screens.len());
        let restated = if scope.iter().all(|workspace| registry.workspace_is_whole(workspace)) {
            Vec::new()
        } else {
            scope_list(&scope)
        };
        // A walk that states its workspaces again keeps no tab back, so it needs no stored host.
        let active_terminal_hosts = if restated.is_empty() {
            let panes = before.panes.iter().map(|pane| pane.public_id.clone()).collect::<Vec<_>>();
            Some(registry.active_terminal_hosts_of_panes(&panes)?)
        } else {
            None
        };
        let read = started.elapsed();
        reindex_scope(state, &scope)?;
        let index = started.elapsed().saturating_sub(read);
        let terminals = |host: &str| registry.live_terminal_record(host);
        let tab_order = |state: &State, id: &TerminalPublicId| terminal_tab_ids(state, id);
        let stored_live = |resource: &str, id: &str| registry.resource_is_live(resource, id);
        let input = LiveTreeInput {
            before: &before,
            scope: Some(&scope),
            terminals: &terminals,
            tab_order: &tab_order,
            stored_live: &stored_live,
            active_terminal_hosts: active_terminal_hosts.as_ref(),
            rows,
            unplaced_terminals,
        };
        let mut projection = self.project_live_tree(&input, state, result)?;
        projection.restated = restated;
        registry.resource_projection_stats().projected(ProjectionSpans {
            read,
            index,
            diff: started.elapsed().saturating_sub(read + index),
            changes: projection.patch.changes.len(),
            scoped: true,
        });
        Ok(projection)
    }

    /// Publish the content of scoped stored tabs that the scoped walk did
    /// not reach: a terminal that is still live elsewhere (placed outside
    /// the scope, or kept unplaced in the catalog) is restated as the full
    /// projection restates it, so it is not tombstoned or deleted.
    pub(super) fn publish_out_of_scope_content(
        &self,
        input: &LiveTreeInput<'_>,
        state: &State,
        live_terminals: &mut HashSet<TerminalPublicId>,
        live_browsers: &HashSet<BrowserPublicId>,
        changes: &mut Vec<ResourceChange>,
        public: &mut Vec<(&'static str, String, Value)>,
    ) -> anyhow::Result<()> {
        for tab in &input.before.tabs {
            let placements = state.placements_of_content(&tab.content_id);
            let id = match &tab.content_id {
                ContentPublicId::Browser(id) => {
                    if !live_browsers.contains(id) && !placements.is_empty() {
                        return Err(escaped(format!("browser {id} is placed outside the scope")));
                    }
                    continue;
                }
                ContentPublicId::Terminal(id) => id,
            };
            let catalog = state.terminal_catalog.get(id);
            if live_terminals.contains(id) || (placements.is_empty() && catalog.is_none()) {
                continue;
            }
            live_terminals.insert(id.clone());
            let runtime: Option<&Arc<crate::Surface>> =
                catalog.or_else(|| placements.first().and_then(|slot| state.surfaces.get(slot)));
            // An unplaced app terminal is published by its first view.
            if placements.is_empty()
                && runtime.is_some_and(|surface| self.is_unregistered_app_terminal(surface.id))
            {
                continue;
            }
            let host = runtime
                .and_then(|surface| self.resource_terminal_host_identity(surface))
                .map(|host| host.terminal_id)
                .or_else(|| tab.terminal_id.clone())
                .context("terminal outside the scope omitted its durable host identity")?;
            let terminal = (input.terminals)(&host)?
                .context("terminal outside the scope has no durable host")?;
            let tab_ids = (input.tab_order)(state, id)?;
            let value = public_terminal_snapshot(id, &terminal, runtime.map(Arc::as_ref), tab_ids)?;
            changes.push(ResourceChange::UpsertTerminal { public_id: id.clone(), terminal });
            public.push(("terminal", id.to_string(), value));
        }
        Ok(())
    }
}

/// Fail a scoped walk when a stored screen, pane or tab of the scope moved
/// out of it, or a live one in the scope was stored outside it: the full
/// projection would change rows the scope does not cover.
pub(super) fn check_scope_containment(
    input: &LiveTreeInput<'_>,
    state: &State,
    live_screens: &HashSet<crate::resource::ScreenPublicId>,
    live_panes: &HashSet<PanePublicId>,
    live_tabs: &HashSet<TabPublicId>,
) -> anyhow::Result<()> {
    let indexes = &state.resource_indexes;
    let before = input.before;
    for screen in before.screens.iter().map(|screen| &screen.public_id) {
        if !live_screens.contains(screen) && indexes.screens.contains_key(screen) {
            return Err(escaped(format!("screen {screen} moved out")));
        }
    }
    for pane in before.panes.iter().map(|pane| &pane.public_id) {
        if !live_panes.contains(pane) && indexes.panes.contains_key(pane) {
            return Err(escaped(format!("pane {pane} moved out")));
        }
    }
    for tab in before.tabs.iter().map(|tab| &tab.public_id) {
        if !live_tabs.contains(tab) && indexes.tabs.contains_key(tab) {
            return Err(escaped(format!("tab {tab} moved out")));
        }
    }
    let stored = |resource: &str, live: Vec<&str>, before: HashSet<&str>| {
        for id in live.into_iter().filter(|id| !before.contains(id)) {
            if (input.stored_live)(resource, id)? {
                return Err(escaped(format!("{resource} {id} moved in")));
            }
        }
        Ok(())
    };
    stored(
        "screen",
        live_screens.iter().map(|id| id.as_str()).collect(),
        before.screens.iter().map(|screen| screen.public_id.as_str()).collect(),
    )?;
    stored(
        "pane",
        live_panes.iter().map(|id| id.as_str()).collect(),
        before.panes.iter().map(|pane| pane.public_id.as_str()).collect(),
    )?;
    stored(
        "tab",
        live_tabs.iter().map(|id| id.as_str()).collect(),
        before.tabs.iter().map(|tab| tab.public_id.as_str()).collect(),
    )
}

/// The most workspaces that the projection of a changed state walks as a scope
/// ([`Mux::changed_state_projection_locked`]); a change that differs in more takes the full
/// projection.
pub(crate) const CHANGED_WORKSPACES_MAX: usize = 8;

/// The workspaces whose stored rows or public values differ between `before` and `after`: an
/// added workspace, a workspace that got or lost the focus, and a workspace whose name, screen
/// list, a screen's row (its layout, columns, rows, active and zoomed pane, as the walk would
/// write it) or a pane's name, tabs or active tab differ. `None` when the change needs the
/// full projection (see [`Mux::changed_state_projection_locked`]).
pub(crate) fn changed_workspaces(before: &State, after: &State) -> Option<Vec<WorkspacePublicId>> {
    if after.workspaces.len() < before.workspaces.len() {
        return None;
    }
    let mut changed = Vec::new();
    for (index, workspace) in after.workspaces.iter().enumerate() {
        let Some(old) = before.workspaces.get(index) else {
            changed.push(workspace.public_id.clone());
            continue;
        };
        if old.id != workspace.id || old.public_id != workspace.public_id {
            return None;
        }
        let focus = (index == before.active_workspace) != (index == after.active_workspace);
        if !focus && !workspace_differs(before, old, after, workspace) {
            continue;
        }
        // A pane that was in another workspace before: it moved here with its tabs.
        let old_panes = old
            .screens
            .iter()
            .flat_map(|screen| screen.root.pane_ids_vec())
            .collect::<HashSet<_>>();
        let moved_in = workspace
            .screens
            .iter()
            .flat_map(|screen| screen.root.pane_ids_vec())
            .any(|pane| !old_panes.contains(&pane) && before.panes.contains_key(&pane));
        if moved_in || changed.len() == CHANGED_WORKSPACES_MAX {
            return None;
        }
        changed.push(workspace.public_id.clone());
    }
    Some(changed)
}

fn workspace_differs(
    before: &State,
    old: &crate::model::Workspace,
    after: &State,
    new: &crate::model::Workspace,
) -> bool {
    use crate::model::Workspace;
    // Each field by its name and no `..`: a field that a later change adds to `Workspace` does
    // not compile here until this compare names it. The caller compares `id` and `public_id`.
    let Workspace {
        id: _,
        public_id: old_id,
        key: old_key,
        name: old_name,
        name_source: old_source,
        name_revision: old_revision,
        screens: old_screens,
        active_screen: old_active,
    } = old;
    let Workspace {
        id: _,
        public_id: new_id,
        key: new_key,
        name: new_name,
        name_source: new_source,
        name_revision: new_revision,
        screens: new_screens,
        active_screen: new_active,
    } = new;
    if old_name != new_name
        || old_source != new_source
        || old_revision != new_revision
        || old_key != new_key
        || old_active != new_active
        || old_screens.len() != new_screens.len()
    {
        return true;
    }
    old_screens.iter().zip(new_screens).enumerate().any(|(position, (old_screen, new_screen))| {
        // A row that cannot be built (an index that lags, a split with no public id yet)
        // counts as a difference: the walk then states the workspace.
        let old_row = registry_screen_from_live(before, old_id, position, old_screen);
        let new_row = registry_screen_from_live(after, new_id, position, new_screen);
        let (Ok(old_row), Ok(new_row)) = (old_row, new_row) else { return true };
        old_row != new_row
            || new_screen.root.pane_ids_vec().iter().any(|pane| {
                match (before.panes.get(pane), after.panes.get(pane)) {
                    (Some(old), Some(new)) => pane_differs(old, new),
                    _ => true,
                }
            })
    })
}

/// Whether a pane's name, tabs or active tab differ. Each field by its name and no `..`, as in
/// [`workspace_differs`]; the two focus counters are not compared (as before).
fn pane_differs(old: &crate::model::Pane, new: &crate::model::Pane) -> bool {
    use crate::model::Pane;
    let Pane {
        id: _,
        public_id: _,
        name: old_name,
        tabs: old_tabs,
        active_tab: old_active,
        active_at: _,
        focused_at: _,
    } = old;
    let Pane {
        id: _,
        public_id: _,
        name: new_name,
        tabs: new_tabs,
        active_tab: new_active,
        active_at: _,
        focused_at: _,
    } = new;
    old_name != new_name || old_tabs != new_tabs || old_active != new_active
}

/// The workspace rows that the projection of a created view states outside its scope: the
/// workspaces that the store does not hold yet. A new workspace goes after the last one, so they
/// are the last workspaces of the live list: one stored-row check for each of them and one more,
/// not one for each workspace of the session. Before this, each created view stated the row and
/// the public value of every workspace, and the journal writer checked each of those rows.
///
/// The store must hold exactly the workspaces before them (one count statement). If it does not
/// (a workspace whose first view never committed, or a stored row that the live tree lost), the
/// walk states every workspace against the whole frame, as it did before: that writes the row
/// that is absent and tombstones the one that is lost.
fn created_view_rows(registry: &WorkspaceRegistry, state: &State) -> anyhow::Result<WorkspaceRows> {
    let mut first = state.workspaces.len();
    for workspace in state.workspaces.iter().rev() {
        if registry.workspace_row_is_live(&workspace.public_id)? {
            break;
        }
        first -= 1;
    }
    if registry.live_workspace_row_count()? != first {
        return Ok(WorkspaceRows::All);
    }
    Ok(WorkspaceRows::Added(first))
}

/// The workspace of a created terminal or browser view (an effect's created
/// path), the one workspace its projection changes.
pub(crate) fn created_view_workspace(result: &Value) -> Option<WorkspacePublicId> {
    if !matches!(result["kind"].as_str(), Some("terminal" | "browser"))
        || !result["tab_id"].is_string()
    {
        return None;
    }
    WorkspacePublicId::parse(result["workspace_id"].as_str()?.to_string()).ok()
}

/// A scoped walk's test for a tab it need not restate: the stored row equals
/// the row it built, its focus did not change, and its terminal's stored
/// row is active on the same host. A full walk restates every tab.
pub(super) fn tab_row_unchanged(
    input: &LiveTreeInput<'_>,
    tab: &RegistryTab,
    before_tab: Option<&RegistryTab>,
    before_pane: Option<&RegistryPane>,
    active_position: usize,
) -> bool {
    let Some(hosts) = input.active_terminal_hosts else { return false };
    let (Some(before_tab), Some(before_pane)) = (before_tab, before_pane) else { return false };
    let was_focused = before_pane.active_tab.as_ref() == Some(&tab.public_id);
    let ContentPublicId::Terminal(terminal) = &tab.content_id else { return false };
    before_tab == tab
        && was_focused == (tab.position == active_position)
        && tab.terminal_id.as_ref().is_some_and(|host| hosts.get(terminal) == Some(host))
}

/// Bring the resource indexes of the scope's workspaces up to date from the
/// live tree (the full projection rebuilds every index instead), and check
/// that every placed tab of the scope has a durable identity.
fn reindex_scope(state: &mut State, scope: &HashSet<WorkspacePublicId>) -> anyhow::Result<()> {
    let mut indexes = std::mem::take(&mut state.resource_indexes);
    let mut splits = HashSet::new();
    for workspace in state.workspaces.iter().filter(|w| scope.contains(&w.public_id)) {
        indexes.workspaces.insert(workspace.public_id.clone(), workspace.id);
        indexes.workspace_ids.insert(workspace.id, workspace.public_id.clone());
        for screen in &workspace.screens {
            collect_screen_split_ids(screen, &mut splits);
            indexes.screens.insert(screen.public_id.clone(), screen.id);
            indexes.screen_ids.insert(screen.id, screen.public_id.clone());
            indexes.screen_workspace.insert(screen.id, workspace.id);
            for pane in screen.root.pane_ids_vec().iter().filter_map(|id| state.panes.get(id)) {
                indexes.panes.insert(pane.public_id.clone(), pane.id);
                indexes.pane_ids.insert(pane.id, pane.public_id.clone());
                indexes.pane_screen.insert(pane.id, screen.id);
                for slot in &pane.tabs {
                    // The topology's record, else the live surface's identity
                    // (`State::tab_identity_of`): a lost record is repaired,
                    // not left to fail every later mutation (cx-95uaf).
                    let identity = match (indexes.tab_ids.get(slot), indexes.content_ids.get(slot))
                    {
                        (Some(tab), Some(content)) => Some((tab.clone(), content.clone())),
                        _ => state.surfaces.get(slot).and_then(|surface| {
                            let identity = surface.resource_identity()?;
                            Some((identity.tab_id.clone(), identity.content_id.clone()))
                        }),
                    };
                    let Some((tab, content)) = identity else {
                        state.resource_indexes = indexes;
                        anyhow::bail!("tab slot {slot} has no durable identity");
                    };
                    indexes.tab_ids.insert(*slot, tab.clone());
                    indexes.content_ids.insert(*slot, content.clone());
                    indexes.tabs.insert(tab, *slot);
                    let placements = indexes.content_placements.entry(content).or_default();
                    if !placements.contains(slot) {
                        placements.push(*slot);
                    }
                    indexes.tab_pane.insert(*slot, pane.id);
                }
            }
        }
    }
    state.resource_indexes = indexes;
    split_ids::mint_split_public_ids(state, splits)
}

/// Each terminal that a pane of the live tree shows, read from the tree and from the index (an
/// index entry can lag behind the tree outside the last scoped walk).
pub(super) fn placed_terminals(state: &State) -> HashSet<TerminalPublicId> {
    let mut placed = HashSet::new();
    for slot in state.panes.values().flat_map(|pane| pane.tabs.iter()) {
        let live = state
            .surfaces
            .get(slot)
            .and_then(|surface| surface.resource_identity())
            .map(|identity| identity.content_id.clone());
        let indexed = state.resource_indexes.content_ids.get(slot).cloned();
        for content in [live, indexed].into_iter().flatten() {
            if let ContentPublicId::Terminal(id) = content {
                placed.insert(id);
            }
        }
    }
    placed
}

fn scope_list(scope: &HashSet<WorkspacePublicId>) -> Vec<WorkspacePublicId> {
    scope.iter().cloned().collect()
}

/// One terminal's tab ids in canonical order, from the live placement
/// index (the full projection computes every terminal's at once).
fn terminal_tab_ids(state: &State, id: &TerminalPublicId) -> anyhow::Result<Vec<TabPublicId>> {
    let mut tabs = Vec::new();
    for slot in state.placements_of_content(&ContentPublicId::Terminal(id.clone())) {
        // Indexes outside the scope may lag until the next full projection;
        // a view they cannot place falls back to it.
        let pane = state
            .resource_indexes
            .tab_pane
            .get(slot)
            .and_then(|pane| state.panes.get(pane))
            .ok_or_else(|| escaped(format!("terminal {id} view {slot} has no indexed pane")))?;
        let position = pane
            .tabs
            .iter()
            .position(|tab| tab == slot)
            .ok_or_else(|| escaped(format!("terminal {id} view {slot} left its pane")))?;
        let tab = state
            .resource_indexes
            .tab_ids
            .get(slot)
            .ok_or_else(|| escaped(format!("terminal {id} view {slot} has no tab identity")))?;
        tabs.push((id.clone(), pane.public_id.clone(), position, tab.clone()));
    }
    Ok(terminal_tab_ids_in_canonical_order(tabs).remove(id).unwrap_or_default())
}
