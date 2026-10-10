//! Pane focus history: the per-screen order of recently focused panes used to
//! pick the next pane after a close.

use std::collections::{HashMap, HashSet};

use cmux_tui_core::PaneId;

use crate::session::TreeView;

#[derive(Default)]
pub(super) struct PaneFocusHistory {
    pub(super) next_sequence: u64,
    pub(super) recency: HashMap<PaneId, u64>,
    pub(super) baseline: HashMap<PaneId, u64>,
    pub(super) membership_revision: Option<u64>,
    pub(super) membership_initialized: bool,
}

impl PaneFocusHistory {
    pub(super) fn record(&mut self, pane: PaneId) {
        self.next_sequence = self.next_sequence.saturating_add(1);
        self.recency.insert(pane, self.next_sequence);
    }

    pub(super) fn recency(&self, pane: PaneId) -> (bool, u64) {
        self.recency
            .get(&pane)
            .copied()
            .map(|sequence| (true, sequence))
            .unwrap_or_else(|| (false, self.baseline.get(&pane).copied().unwrap_or_default()))
    }

    pub(super) fn reconcile_membership(&mut self, tree: &TreeView) {
        let live = tree
            .workspaces()
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .map(|pane| pane.id)
            .collect::<HashSet<_>>();
        self.recency.retain(|pane, _| live.contains(pane));
        self.baseline.retain(|pane, _| live.contains(pane));
        for pane in tree
            .workspaces()
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
        {
            self.baseline.entry(pane.id).or_insert(pane.focused_at);
        }
        self.membership_revision = tree.pane_revision;
        self.membership_initialized = true;
    }

    pub(super) fn sync_membership(&mut self, tree: &TreeView) {
        if !self.membership_initialized
            || tree.pane_revision.is_some() && self.membership_revision != tree.pane_revision
        {
            self.reconcile_membership(tree);
        }
    }
}
