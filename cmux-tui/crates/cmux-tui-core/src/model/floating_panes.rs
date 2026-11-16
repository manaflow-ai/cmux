//! Floating panes of a screen (`floating-panes-v1`).
//!
//! A floating pane stays a leaf of the screen's split tree; `Screen::floating` names the leaves the tiled layout
//! leaves out, back to front, each with its frame. So every walk of the tree still finds every pane, and a client
//! or a build without the capability shows the pane tiled at its leaf. The rules of the list are the layout
//! reducer's (`cmux_layout_reducer::floating_panes`); this file applies them to a screen and to a layout snapshot,
//! and names the panes that never float.
//!
//! Until the layout projection reads this list, a floating pane keeps its tiled rectangle and each client shows
//! it tiled.

use cmux_layout_reducer::floating_panes::{
    self as rules, FloatFrame, FloatMode, FloatRefusal, Floating,
};

use super::{LayoutColumn, Node, Screen, ScreenLayoutSnapshot};
use crate::PaneId;

/// Whether `pane` never floats in a layout of `root` and `columns`: a member of a stack, and a pane of a docked
/// column or of a column with rows.
fn never_floats(root: &Node, columns: &[LayoutColumn], pane: PaneId) -> bool {
    root.contains_stack_pane(pane)
        || columns
            .iter()
            .find(|column| column.root.contains(pane))
            .is_some_and(|column| column.dock.is_some() || !column.rows.is_empty())
}

impl Screen {
    /// `list` as a layout of `root` and `columns` keeps it: no entry of a pane that never floats, then the rules
    /// of the list (only panes of the tree, each once, frames in the screen, and at least one tiled pane). The
    /// live screen, a layout snapshot and the stored record of a screen all take their list from here.
    pub(crate) fn settled_floating_panes(
        root: &Node,
        columns: &[LayoutColumn],
        list: &[Floating<PaneId>],
    ) -> Vec<Floating<PaneId>> {
        if list.is_empty() {
            return Vec::new();
        }
        let kept = list
            .iter()
            .filter(|entry| !never_floats(root, columns, entry.pane))
            .copied()
            .collect::<Vec<_>>();
        rules::normalized(&root.pane_ids_vec(), &kept)
    }

    /// The zoom of a layout whose floating panes are `floating`: a floating pane is never zoomed, so the zoom of
    /// one ends. The zoom request, each settle of a list and the load take the rule from here, for the panes of
    /// the live screen and for the panes of its stored record.
    pub(crate) fn zoom_beside_floating_panes<P: PartialEq>(
        zoomed: Option<P>,
        floating: &[Floating<P>],
    ) -> Option<P> {
        zoomed.filter(|pane| !floating.iter().any(|entry| entry.pane == *pane))
    }

    /// The floating panes of the screen, back to front, by [`Self::settled_floating_panes`].
    pub(crate) fn floating_panes(&self) -> Vec<Floating<PaneId>> {
        Self::settled_floating_panes(&self.root, &self.layout_columns, &self.floating)
    }

    /// Replaces the list with `floating` as [`Self::settled_floating_panes`] reads it against the layout of now.
    /// Every change of the layout that takes a pane away, or that gives a pane a place where it never floats,
    /// ends here, so an entry of a pane that became tiled by the rules never comes back. The zoom of a pane of
    /// the list ends ([`Self::zoom_beside_floating_panes`]).
    pub(crate) fn set_floating_panes(&mut self, floating: Vec<Floating<PaneId>>) {
        self.floating = Self::settled_floating_panes(&self.root, &self.layout_columns, &floating);
        self.zoomed_pane = Self::zoom_beside_floating_panes(self.zoomed_pane, &self.floating);
    }

    /// [`Self::set_floating_panes`] of the list the screen has.
    pub(crate) fn settle_floating_panes(&mut self) {
        let floating = std::mem::take(&mut self.floating);
        self.set_floating_panes(floating);
    }

    /// Whether `pane` never floats: a member of a stack, and a pane of a docked column or of a column with rows.
    pub(crate) fn pane_never_floats(&self, pane: PaneId) -> bool {
        never_floats(&self.root, &self.layout_columns, pane)
    }

    /// Gives `pane` the focus of the screen. A floating pane that gets the focus comes to the front, as a focus
    /// request does it.
    pub(crate) fn set_active_pane(&mut self, pane: PaneId) {
        self.active_pane = pane;
        self.raise_floating_pane(pane);
    }

    /// Floats `pane`, puts it back into the tiled layout, or moves it, by `mode` and `frame`. False when the
    /// request matched the list and changed nothing.
    ///
    /// A pane that leaves the tiled layout ends the screen's creation-order auto layout, as a manual split does,
    /// and ends its own zoom.
    pub(crate) fn place_floating_pane(
        &mut self,
        pane: PaneId,
        mode: FloatMode,
        frame: Option<FloatFrame>,
    ) -> Result<bool, FloatRefusal> {
        let panes = self.root.pane_ids_vec();
        let before = rules::normalized(&panes, &self.floating);
        let next = rules::place(&panes, &before, &pane, mode, frame)?;
        let floats = |list: &[Floating<PaneId>]| list.iter().any(|entry| entry.pane == pane);
        if !floats(&before) && floats(&next) {
            self.creation_order_auto_layout = None;
            if let Some(column) = self.layout_column_for_pane_mut(pane) {
                column.creation_order_auto_layout = None;
            }
        }
        let changed = next != self.floating;
        self.floating = next;
        self.zoomed_pane = Self::zoom_beside_floating_panes(self.zoomed_pane, &self.floating);
        Ok(changed)
    }

    /// Whether `pane` floats behind another floating pane: a focus of it changes the list.
    pub(crate) fn floating_pane_is_behind(&self, pane: PaneId) -> bool {
        self.floating.last().is_some_and(|front| front.pane != pane)
            && self.floating.iter().any(|entry| entry.pane == pane)
    }

    /// Brings a floating `pane` to the front. False when the list did not change.
    pub(crate) fn raise_floating_pane(&mut self, pane: PaneId) -> bool {
        if !self.floating.iter().any(|entry| entry.pane == pane) {
            return false;
        }
        let next = rules::raised(&self.root.pane_ids_vec(), &self.floating, &pane);
        let changed = next != self.floating;
        self.floating = next;
        changed
    }
}

impl ScreenLayoutSnapshot {
    /// The snapshot's list as [`Screen::settled_floating_panes`] reads it against the snapshot's layout: after
    /// a pane left the tree, and after a pane got a place where it never floats. The zoom of a pane of the
    /// list ends ([`Screen::zoom_beside_floating_panes`]).
    pub(crate) fn settle_floating_panes(&mut self) {
        if !self.floating.is_empty() {
            self.floating =
                Screen::settled_floating_panes(&self.root, &self.layout_columns, &self.floating);
            self.zoomed_pane = Screen::zoom_beside_floating_panes(self.zoomed_pane, &self.floating);
        }
    }

    /// Gives `pane` the focus of the snapshot, as [`Screen::set_active_pane`] does it.
    pub(crate) fn set_active_pane(&mut self, pane: PaneId) {
        self.active_pane = pane;
        self.raise_floating_pane(pane);
    }

    /// Brings a floating `pane` to the front of the snapshot's list.
    pub(crate) fn raise_floating_pane(&mut self, pane: PaneId) {
        if self.floating.iter().any(|entry| entry.pane == pane) {
            self.floating = rules::raised(&self.root.pane_ids_vec(), &self.floating, &pane);
        }
    }
}
