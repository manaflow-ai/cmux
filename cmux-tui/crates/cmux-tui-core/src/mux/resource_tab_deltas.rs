//! v1 tree deltas for resource commits that change tab membership or order.
//!
//! [`Mux::commit_resource_mutation_plan`] publishes the v2 journal only.
//! Delta clients (the Mac app) build their tree from v1 deltas, so without
//! this a tab that a resource commit added or moved stayed invisible to them
//! until a later delta rewrote its pane. The commit captures the tab lists
//! of every pane its patch touches before the plan's state step, compares
//! them after the commit, and emits one delta per change:
//!
//! - a new tab view: `tab-added` at its index;
//! - a tab adopted from another pane, or the one tab a reorder moved:
//!   `tab-changed` naming its pane and index (the app's move contract).
//!
//! When the commit also moved the selection (the focused workspace, screen
//! or pane, or a captured pane's active tab), a selection resync follows
//! the deltas, as it does after a new tab that takes focus.
//!
//! A change these deltas cannot express (a removed tab, a pane that appeared
//! or vanished, a reorder of more than one tab, a pane that both gains and
//! loses tabs) emits `tree-changed`, which makes delta clients resync.
//! Deriving the deltas from the plan's patch here, rather than in each
//! operation, keeps a future resource operation from forgetting them.

use std::collections::{BTreeMap, HashSet};

use super::presentation::tab_delta;
use super::{Mux, MuxEvent, TreeDelta, TreeDeltaKind};
use crate::resource::TabPublicId;
use crate::workspace_registry::{ResourceChange, ResourcePatch, ResourcePatchCommit};
use crate::{PaneId, ScreenId, State, SurfaceId, WorkspaceId};

/// Tab lists of the panes a resource patch touches, before its state step.
pub(super) struct TabMembership {
    panes: BTreeMap<PaneId, Vec<SurfaceId>>,
    /// Tabs the patch names that did not exist before it (new views).
    created: HashSet<TabPublicId>,
    /// Tabs the patch names, to find panes they land in that were not
    /// captured (a pane the commit created).
    named: Vec<TabPublicId>,
    selection: Selection,
}

/// The focused workspace, screen and pane, and the active tab of each
/// captured pane in pane order.
#[derive(PartialEq, Eq, Default)]
struct Selection {
    focus: Option<(WorkspaceId, ScreenId, PaneId)>,
    active: Vec<Option<SurfaceId>>,
}

impl Selection {
    fn of<'a>(state: &State, panes: impl Iterator<Item = &'a PaneId>) -> Self {
        let focus = state.workspaces.get(state.active_workspace).and_then(|workspace| {
            let screen = workspace.active_screen_ref()?;
            Some((workspace.id, screen.id, screen.active_pane))
        });
        let active = panes
            .map(|pane| {
                let record = state.panes.get(pane)?;
                record.tabs.get(record.active_tab).copied()
            })
            .collect();
        Self { focus, active }
    }
}

/// What a commit's tab membership change sends to v1 subscribers.
pub(super) enum TabDeltas {
    Deltas { deltas: Vec<TreeDelta>, selection_changed: bool },
    Resync,
}

impl TabMembership {
    /// The membership of every pane `patch` touches, or `None` when it
    /// changes no tab.
    pub(super) fn capture(state: &State, patch: &ResourcePatch) -> Option<Self> {
        let mut membership = Self {
            panes: BTreeMap::new(),
            created: HashSet::new(),
            named: Vec::new(),
            selection: Selection::default(),
        };
        for change in &patch.changes {
            match change {
                ResourceChange::UpsertTab(tab) => {
                    membership.note_pane(state, &tab.pane_id);
                    membership.note_tab(state, &tab.public_id);
                }
                ResourceChange::TombstoneTab { tab_id, .. } => membership.note_tab(state, tab_id),
                ResourceChange::SetTabOrder { pane_id, tab_ids } => {
                    membership.note_pane(state, pane_id);
                    for tab in tab_ids {
                        membership.note_tab(state, tab);
                    }
                }
                ResourceChange::TombstonePane { pane_id } => membership.note_pane(state, pane_id),
                _ => {}
            }
        }
        if membership.named.is_empty() && membership.panes.is_empty() {
            return None;
        }
        membership.selection = Selection::of(state, membership.panes.keys());
        Some(membership)
    }

    fn note_pane(&mut self, state: &State, pane: &crate::resource::PanePublicId) {
        if let Some(pane) = state.resource_indexes.panes.get(pane) {
            self.capture_pane(state, *pane);
        }
    }

    fn note_tab(&mut self, state: &State, tab: &TabPublicId) {
        match state.resource_indexes.tabs.get(tab) {
            Some(surface) => {
                if let Some(pane) = state.pane_of(*surface) {
                    self.capture_pane(state, pane);
                }
            }
            None => {
                self.created.insert(tab.clone());
            }
        }
        self.named.push(tab.clone());
    }

    fn capture_pane(&mut self, state: &State, pane: PaneId) {
        if let Some(record) = state.panes.get(&pane) {
            self.panes.entry(pane).or_insert_with(|| record.tabs.clone());
        }
    }

    /// The deltas that carry the change from the captured membership to
    /// `state`, or `None` when tab membership and order did not change or
    /// the commit replayed (a replay changes nothing).
    pub(super) fn deltas(
        self,
        mux: &Mux,
        state: &State,
        commit: &ResourcePatchCommit,
    ) -> Option<TabDeltas> {
        if commit.replayed {
            return None;
        }
        match self.changes(state) {
            Changes::None => None,
            Changes::Resync => Some(TabDeltas::Resync),
            Changes::Tabs(changes) => {
                let decorations = mux.tree_decorations_in_state(state);
                let deltas = changes
                    .into_iter()
                    .map(|(kind, surface)| tab_delta(state, &decorations, kind, surface))
                    .collect::<Option<Vec<_>>>();
                let selection_changed = Selection::of(state, self.panes.keys()) != self.selection;
                Some(deltas.map_or(TabDeltas::Resync, |deltas| TabDeltas::Deltas {
                    deltas,
                    selection_changed,
                }))
            }
        }
    }

    fn changes(&self, state: &State) -> Changes {
        let mut after = BTreeMap::new();
        for pane in self.panes.keys() {
            let Some(record) = state.panes.get(pane) else { return Changes::Resync };
            after.insert(*pane, &record.tabs);
        }
        // A named tab in a pane the capture does not hold: a new pane.
        for tab in &self.named {
            if let Some(surface) = state.resource_indexes.tabs.get(tab)
                && state.pane_of(*surface).is_none_or(|pane| !self.panes.contains_key(&pane))
            {
                return Changes::Resync;
            }
        }
        let before_tabs = self.panes.values().flatten().copied().collect::<HashSet<_>>();
        let after_tabs = after.values().copied().flatten().copied().collect::<HashSet<_>>();
        // A tab that left every captured pane was removed (no tab delta
        // carries a closed tab's entity) or moved to an uncaptured pane.
        if !before_tabs.is_subset(&after_tabs) {
            return Changes::Resync;
        }
        let mut changes = Vec::new();
        for (pane, before) in &self.panes {
            let after = after[pane];
            if before == after {
                continue;
            }
            match pane_changes(before, after, &before_tabs) {
                Some(pane_changes) => changes.extend(pane_changes),
                None => return Changes::Resync,
            }
        }
        for (kind, surface) in &changes {
            let created = state
                .resource_indexes
                .tab_ids
                .get(surface)
                .is_some_and(|tab| self.created.contains(tab));
            // An "added" tab the patch did not create existed somewhere the
            // capture does not hold.
            if *kind == TreeDeltaKind::TabAdded && !created {
                return Changes::Resync;
            }
        }
        if changes.is_empty() { Changes::None } else { Changes::Tabs(changes) }
    }
}

enum Changes {
    None,
    Resync,
    Tabs(Vec<(TreeDeltaKind, SurfaceId)>),
}

/// The deltas that turn one pane's `before` tabs into `after`, in the order
/// a client applies them, or `None` when tab deltas cannot express it.
/// `known` holds every captured tab: a tab outside it is a new view.
fn pane_changes(
    before: &[SurfaceId],
    after: &[SurfaceId],
    known: &HashSet<SurfaceId>,
) -> Option<Vec<(TreeDeltaKind, SurfaceId)>> {
    let kept_after = after.iter().filter(|tab| before.contains(tab)).collect::<Vec<_>>();
    let kept_before = before.iter().filter(|tab| after.contains(tab)).collect::<Vec<_>>();
    let gains = kept_after.len() < after.len();
    let losses = kept_before.len() < before.len();
    if kept_after == kept_before {
        // Only arrivals or only departures. Departures need nothing here:
        // the adopting pane's `tab-changed` takes the tab away. Arrivals in
        // ascending index each land at their final index.
        if gains && losses {
            return None;
        }
        return Some(
            after
                .iter()
                .filter(|tab| !before.contains(tab))
                .map(|tab| {
                    let kind = if known.contains(tab) {
                        TreeDeltaKind::TabChanged
                    } else {
                        TreeDeltaKind::TabAdded
                    };
                    (kind, *tab)
                })
                .collect(),
        );
    }
    if gains || losses {
        return None;
    }
    single_relocation(before, after).map(|tab| vec![(TreeDeltaKind::TabChanged, tab)])
}

/// The one tab whose move turns `before` into `after` (same tabs), if one
/// move explains the reorder.
fn single_relocation(before: &[SurfaceId], after: &[SurfaceId]) -> Option<SurfaceId> {
    let first = before.iter().zip(after).position(|(left, right)| left != right)?;
    fn without(tabs: &[SurfaceId], tab: SurfaceId) -> impl Iterator<Item = SurfaceId> + '_ {
        tabs.iter().copied().filter(move |candidate| *candidate != tab)
    }
    [before[first], after[first]]
        .into_iter()
        .find(|tab| without(before, *tab).eq(without(after, *tab)))
}

impl Mux {
    /// Send a resource commit's tab deltas, if any, to v1 subscribers.
    pub(super) fn emit_resource_tab_deltas(&self, deltas: Option<TabDeltas>) {
        let Some(deltas) = deltas else { return };
        match deltas {
            TabDeltas::Deltas { deltas, selection_changed } => {
                for delta in deltas {
                    self.emit(MuxEvent::TreeDelta(delta));
                }
                if selection_changed {
                    self.emit(MuxEvent::TreeSelectionChanged);
                }
            }
            TabDeltas::Resync => self.emit(MuxEvent::TreeChanged),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{pane_changes, single_relocation};
    use crate::mux::TreeDeltaKind::{TabAdded, TabChanged};
    use std::collections::HashSet;

    #[test]
    fn one_relocation_is_found_in_either_direction_and_two_are_not() {
        assert_eq!(single_relocation(&[1, 2, 3], &[2, 3, 1]), Some(1));
        assert_eq!(single_relocation(&[1, 2, 3], &[3, 1, 2]), Some(3));
        assert_eq!(single_relocation(&[1, 2, 3, 4], &[2, 1, 4, 3]), None);
    }

    #[test]
    fn arrivals_are_added_or_adopted_and_a_pane_that_gains_and_loses_resyncs() {
        let known = HashSet::from([1, 2, 3, 9]);
        assert_eq!(
            pane_changes(&[1, 2], &[7, 1, 9, 2], &known),
            Some(vec![(TabAdded, 7), (TabChanged, 9)])
        );
        assert_eq!(pane_changes(&[1, 2, 3], &[1, 3], &known), Some(Vec::new()));
        assert_eq!(pane_changes(&[1, 2], &[1, 9], &known), None);
        assert_eq!(pane_changes(&[1, 2, 3], &[2, 1, 3, 7], &known), None);
    }
}
