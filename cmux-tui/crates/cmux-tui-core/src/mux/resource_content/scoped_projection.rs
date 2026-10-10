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

use super::*;
use super::projection_crosscheck::projection_difference;
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
    /// Scoped walks only: the host of every active stored terminal row the
    /// scope's tabs show. A tab whose row, focus and terminal row are all
    /// stored as the walk would write them is not restated.
    pub(super) active_terminal_hosts: Option<&'a HashMap<TerminalPublicId, String>>,
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

/// Run `body` with the cross-check off on this thread, as release builds run.
#[cfg(test)]
pub(super) fn without_crosscheck<R>(body: impl FnOnce() -> R) -> R {
    CROSSCHECK_OFF.with(|off| off.set(true));
    let result = body();
    CROSSCHECK_OFF.with(|off| off.set(false));
    result
}

/// Debug builds always compare; release builds when the daemon runs with
/// `CMUX_TUI_PROJECTION_CROSSCHECK=1`.
fn crosscheck_enabled() -> bool {
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
    /// The projection for a commit whose result is `result`: a created view
    /// changed one workspace, so once the public fold is seeded (a full
    /// projection seeds it) only that workspace is projected.
    pub(crate) fn created_view_projection_locked(
        &self,
        registry: &WorkspaceRegistry,
        state: &mut State,
        result: Value,
    ) -> anyhow::Result<ResourceEffectProjection> {
        match created_view_workspace(&result) {
            Some(workspace) if registry.public_fold_seeded() => {
                self.resource_effect_projection_scoped_locked(registry, state, &[workspace], result)
            }
            _ => self.resource_effect_projection_locked(registry, state, result),
        }
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
        let started = Instant::now();
        let mut scope = workspaces.iter().cloned().collect::<HashSet<_>>();
        let mut before = registry.resource_topology_scoped(&scope_list(&scope))?;
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
                before = registry.resource_topology_scoped(&scope_list(&scope))?;
            }
        }
        let panes = before.panes.iter().map(|pane| pane.public_id.clone()).collect::<Vec<_>>();
        let active_terminal_hosts = registry.active_terminal_hosts_of_panes(&panes)?;
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
            active_terminal_hosts: Some(&active_terminal_hosts),
        };
        let projection = match self.project_live_tree(&input, state, result.clone()) {
            Ok(projection) => projection,
            Err(error) if error.is::<ScopeEscaped>() => {
                registry.resource_projection_stats().scope_fell_back();
                return self.resource_effect_projection_locked(registry, state, result);
            }
            Err(error) => return Err(error),
        };
        registry.resource_projection_stats().projected(ProjectionSpans {
            read,
            index,
            diff: started.elapsed().saturating_sub(read + index),
            changes: projection.patch.changes.len(),
            scoped: true,
        });
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
            split_ids::collect_screen_split_ids(screen, &mut splits);
            indexes.screens.insert(screen.public_id.clone(), screen.id);
            indexes.screen_ids.insert(screen.id, screen.public_id.clone());
            indexes.screen_workspace.insert(screen.id, workspace.id);
            for pane in screen.root.pane_ids_vec().iter().filter_map(|id| state.panes.get(id)) {
                indexes.panes.insert(pane.public_id.clone(), pane.id);
                indexes.pane_ids.insert(pane.id, pane.public_id.clone());
                indexes.pane_screen.insert(pane.id, screen.id);
                for slot in &pane.tabs {
                    let (Some(tab), Some(content)) = (
                        indexes.tab_ids.get(slot).cloned(),
                        indexes.content_ids.get(slot).cloned(),
                    ) else {
                        state.resource_indexes = indexes;
                        anyhow::bail!("tab slot {slot} has no durable identity");
                    };
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
