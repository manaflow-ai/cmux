//! The invariant check of one op, scoped to what the op touches
//! (https://github.com/manaflow-ai/cmux/issues/45007).
//!
//! An op changes the layout of the workspaces holding the tabs, panes and
//! columns it names, and of the workspace it creates; nothing else. So
//! [`apply_mut`](crate::apply_mut) checks I1-I3 on those workspaces (their
//! *region*: the panes their layout places, those panes' tabs, and every
//! pane and tab the op names) before and after the op, instead of on the
//! whole state, and checks that the number of panes and tabs outside the
//! region did not change. For an op that keeps to its region that is the
//! whole-state check's verdict (the crate's unit tests assert it on every
//! op they apply); it costs the region, not the corpus.
//!
//! The same region, captured before the op, is what a rejection restores.

use std::collections::{BTreeMap, BTreeSet};

use crate::{
    LayoutOpKind, LayoutState, PaneId, TabContent, TabId, Violation, Workspace, WorkspaceId,
    row_layout_is_valid,
};

/// What one op may touch: workspaces by id, and the panes and tabs it
/// names (some not created yet).
pub(crate) struct Scope {
    workspaces: Vec<WorkspaceId>,
    panes: BTreeSet<PaneId>,
    tabs: BTreeSet<TabId>,
}

/// The region of a scope before the op: its check, and what a rejection
/// restores.
pub(crate) struct Before {
    violations: BTreeSet<Violation>,
    /// Region panes and tabs (with their content).
    panes: BTreeSet<PaneId>,
    tabs: BTreeMap<TabId, TabContent>,
    /// Panes and tabs outside the region.
    outside_panes: usize,
    outside_tabs: usize,
    /// The scope's workspaces as they were, with their positions.
    workspaces: Vec<(usize, Workspace)>,
    /// Every pane entry and tab entry the op may write, as it was.
    pane_entries: Vec<(PaneId, Option<Vec<TabId>>)>,
    tab_entries: Vec<(TabId, Option<TabContent>)>,
}

/// I2/I3 on a region, and the region's panes and tabs.
struct Region {
    violations: BTreeSet<Violation>,
    panes: BTreeSet<PaneId>,
    tabs: BTreeSet<TabId>,
}

impl Scope {
    /// The scope of `kind` on `state`, or `None` for an op that may touch
    /// every tab (a runtime's exit), which the whole-state check covers.
    pub(crate) fn of(state: &LayoutState, kind: &LayoutOpKind) -> Option<Self> {
        let mut scope =
            Self { workspaces: Vec::new(), panes: BTreeSet::new(), tabs: BTreeSet::new() };
        match kind {
            LayoutOpKind::MoveTab { tab, pane, .. } => {
                scope.tab(state, *tab);
                scope.pane(state, *pane);
            }
            LayoutOpKind::MoveTabToSplit { tab, pane, new_pane, respawn, .. } => {
                scope.tab(state, *tab);
                scope.pane(state, *pane);
                scope.panes.insert(*new_pane);
                scope.tabs.extend(respawn.as_ref().map(|respawn| respawn.tab));
            }
            LayoutOpKind::MoveTabToColumn { tab, anchor, new_pane, .. } => {
                scope.tab(state, *tab);
                scope.pane(state, *anchor);
                scope.panes.insert(*new_pane);
            }
            LayoutOpKind::MoveTabToNewWorkspace { tab, new_workspace, new_pane, .. } => {
                scope.tab(state, *tab);
                scope.workspace(*new_workspace);
                scope.panes.insert(*new_pane);
            }
            LayoutOpKind::MoveTabToWorkspace { tab, workspace, pane, new_pane, .. } => {
                scope.tab(state, *tab);
                scope.workspace(*workspace);
                if let Some(pane) = pane {
                    scope.pane(state, *pane);
                }
                scope.panes.insert(*new_pane);
            }
            LayoutOpKind::InsertRow { after_pane, new_pane, new_tab, .. } => {
                scope.pane(state, *after_pane);
                scope.panes.insert(*new_pane);
                scope.tabs.insert(new_tab.tab);
            }
            LayoutOpKind::MoveTabToRow { tab, anchor, new_pane, respawn, .. } => {
                scope.tab(state, *tab);
                scope.pane(state, *anchor);
                scope.panes.insert(*new_pane);
                scope.tabs.extend(respawn.as_ref().map(|respawn| respawn.tab));
            }
            LayoutOpKind::SetRowHeights { column, .. } | LayoutOpKind::FlattenRows { column } => {
                let workspace = state.workspaces.iter().find(|workspace| {
                    workspace.screens.iter().any(|screen| {
                        screen.columns_active && screen.columns.iter().any(|c| c.id == *column)
                    })
                });
                if let Some(workspace) = workspace {
                    scope.workspace(workspace.id);
                }
            }
            LayoutOpKind::CloseTab { tab } => scope.tab(state, *tab),
            LayoutOpKind::RuntimeExited { .. } => return None,
        }
        Some(scope)
    }

    fn workspace(&mut self, workspace: WorkspaceId) {
        if !self.workspaces.contains(&workspace) {
            self.workspaces.push(workspace);
        }
    }

    fn tab(&mut self, state: &LayoutState, tab: TabId) {
        self.tabs.insert(tab);
        if let Some(pane) = state.pane_of(tab) {
            self.pane(state, pane);
        }
    }

    fn pane(&mut self, state: &LayoutState, pane: PaneId) {
        self.panes.insert(pane);
        if let Some(workspace) = state.workspace_of_pane(pane) {
            self.workspace(workspace);
        }
    }

    /// The scope's workspaces that `state` has, with their positions (one
    /// to three ids, each found by its position).
    fn workspaces<'a>(
        &'a self,
        state: &'a LayoutState,
    ) -> impl Iterator<Item = (usize, &'a Workspace)> + 'a {
        self.workspaces.iter().filter_map(|id| {
            let position = state.workspace_position(*id)?;
            Some((position, &state.workspaces[position]))
        })
    }

    /// The region's check and members in `state`; `panes` and `tabs` are
    /// named besides those the region's layout places.
    fn region(
        &self,
        state: &LayoutState,
        panes: impl IntoIterator<Item = PaneId>,
        tabs: impl IntoIterator<Item = TabId>,
    ) -> Region {
        let mut violations = BTreeSet::new();
        let mut positions = BTreeMap::<PaneId, usize>::new();
        for (_, workspace) in self.workspaces(state) {
            for screen in &workspace.screens {
                if screen.columns.is_empty() {
                    violations.insert(Violation::EmptyScreen { screen: screen.id });
                }
                for column in &screen.columns {
                    if column.panes.is_empty() {
                        violations.insert(Violation::EmptyColumn {
                            column: column.id,
                            screen: screen.id,
                        });
                    }
                    if !row_layout_is_valid(column) {
                        violations.insert(Violation::RowLayout { column: column.id });
                    }
                    for pane in &column.panes {
                        *positions.entry(*pane).or_default() += 1;
                    }
                }
            }
        }
        // Each pane and tab is looked up once: the maps hold the whole corpus.
        let mut region_panes = BTreeMap::new();
        for (pane, count) in &positions {
            match state.panes.get(pane) {
                Some(tabs) => {
                    region_panes.insert(*pane, tabs);
                }
                None => {
                    violations.insert(Violation::LayoutPaneMissing { pane: *pane });
                }
            }
            if *count > 1 {
                violations.insert(Violation::PanePlacedTwice { pane: *pane });
            }
        }
        for pane in panes {
            if positions.contains_key(&pane) || region_panes.contains_key(&pane) {
                continue;
            }
            if let Some(tabs) = state.panes.get(&pane) {
                region_panes.insert(pane, tabs);
                violations.insert(Violation::PaneOutsideLayout { pane });
            }
        }
        let mut placed = BTreeSet::new();
        let mut region_tabs = BTreeSet::new();
        for (pane, tabs) in &region_panes {
            if tabs.is_empty() {
                violations.insert(Violation::EmptyPane { pane: *pane });
            }
            for tab in *tabs {
                let first = placed.insert(*tab);
                if !first {
                    violations.insert(Violation::TabPlacedTwice { tab: *tab });
                }
                if !state.tabs.contains_key(tab) {
                    violations.insert(Violation::TabWithoutContent { tab: *tab, pane: *pane });
                } else if first {
                    region_tabs.insert(*tab);
                }
            }
        }
        let region_panes = region_panes.into_keys().collect::<BTreeSet<_>>();
        for tab in tabs {
            if state.tabs.contains_key(&tab) && region_tabs.insert(tab) && !placed.contains(&tab) {
                violations.insert(Violation::TabWithoutPane { tab });
            }
        }
        Region { violations, panes: region_panes, tabs: region_tabs }
    }

    /// The region before the op, and every entry the op may write.
    pub(crate) fn capture(&self, state: &LayoutState, created: &BTreeSet<TabId>) -> Before {
        let region = self.region(state, self.panes.iter().copied(), self.tabs.iter().copied());
        let pane_entries = region
            .panes
            .iter()
            .chain(&self.panes)
            .collect::<BTreeSet<_>>()
            .into_iter()
            .map(|pane| (*pane, state.panes.get(pane).cloned()))
            .collect();
        let tab_entries = region
            .tabs
            .iter()
            .chain(&self.tabs)
            .chain(created)
            .collect::<BTreeSet<_>>()
            .into_iter()
            .map(|tab| (*tab, state.tabs.get(tab).cloned()))
            .collect();
        Before {
            outside_panes: state.panes.len() - region.panes.len(),
            outside_tabs: state.tabs.len() - region.tabs.len(),
            tabs: region.tabs.iter().map(|tab| (*tab, state.tabs[tab].clone())).collect(),
            panes: region.panes,
            violations: region.violations,
            workspaces: self
                .workspaces(state)
                .map(|(position, workspace)| (position, workspace.clone()))
                .collect(),
            pane_entries,
            tab_entries,
        }
    }

    /// Every I1 violation from `before` to `after` and every I2/I3 violation
    /// of the region after the op that it did not have before, where exactly
    /// the tabs in `closed` close and those in `created` appear.
    pub(crate) fn introduced(
        &self,
        before: &Before,
        after: &LayoutState,
        closed: &BTreeSet<TabId>,
        created: &BTreeSet<TabId>,
    ) -> BTreeSet<Violation> {
        let region = self.region(
            after,
            self.panes.iter().chain(&before.panes).copied(),
            self.tabs.iter().chain(before.tabs.keys()).chain(created).copied(),
        );
        let mut violations = region
            .violations
            .into_iter()
            .filter(|violation| !before.violations.contains(violation))
            .collect::<BTreeSet<_>>();
        // I1 on the region, as `check_conservation_creating` on the state.
        for (tab, content) in &before.tabs {
            match (closed.contains(tab), after.tabs.get(tab)) {
                (true, Some(_)) => {
                    violations.insert(Violation::TabNotClosed { tab: *tab });
                }
                (false, None) => {
                    violations.insert(Violation::TabLost { tab: *tab });
                }
                (false, Some(after)) if !after.same_identity(content) => {
                    violations.insert(Violation::TabContentChanged { tab: *tab });
                }
                _ => {}
            }
        }
        for tab in &region.tabs {
            if !before.tabs.contains_key(tab) && !created.contains(tab) {
                violations.insert(Violation::TabAdded { tab: *tab });
            }
        }
        for tab in created {
            if !after.tabs.contains_key(tab) {
                violations.insert(Violation::TabLost { tab: *tab });
            }
        }
        // Outside the region nothing may appear or go.
        if after.panes.len() - region.panes.len() != before.outside_panes
            || after.tabs.len() - region.tabs.len() != before.outside_tabs
        {
            violations.insert(Violation::ChangedOutsideOp);
        }
        violations
    }

    /// Index the scope's workspaces after an applied op.
    pub(crate) fn reindex(&self, state: &mut LayoutState, before: &Before) {
        let mut placed = Vec::new();
        for (_, workspace) in self.workspaces(state) {
            for pane in workspace.pane_ids() {
                placed.push((pane, workspace.id));
            }
        }
        // Write only what changed: a reorder changes no entry.
        let index = &mut state.index;
        for pane in before.panes.iter().chain(&self.panes) {
            if !state.panes.contains_key(pane) {
                index.pane_workspace.remove(pane);
            }
        }
        for tab in before.tabs.keys().chain(&self.tabs) {
            if !state.tabs.contains_key(tab) {
                index.tab_pane.remove(tab);
            }
        }
        for (pane, workspace) in placed {
            if index.pane_workspace.get(&pane) != Some(&workspace) {
                index.pane_workspace.insert(pane, workspace);
            }
            for tab in state.panes.get(&pane).into_iter().flatten() {
                if index.tab_pane.get(tab) != Some(&pane) {
                    index.tab_pane.insert(*tab, pane);
                }
            }
        }
    }

    /// Put back what the op changed: the scope's workspaces (dropping one
    /// it created) and every pane and tab entry it may have written.
    pub(crate) fn restore(&self, state: &mut LayoutState, before: Before) {
        let kept = before.workspaces.iter().map(|(_, w)| w.id).collect::<BTreeSet<_>>();
        state.workspaces.retain(|workspace| {
            !self.workspaces.contains(&workspace.id) || kept.contains(&workspace.id)
        });
        for (position, workspace) in before.workspaces {
            state.workspaces[position] = workspace;
        }
        for (pane, entry) in before.pane_entries {
            match entry {
                Some(tabs) => state.panes.insert(pane, tabs),
                None => state.panes.remove(&pane),
            };
        }
        for (tab, entry) in before.tab_entries {
            match entry {
                Some(content) => state.tabs.insert(tab, content),
                None => state.tabs.remove(&tab),
            };
        }
    }
}
