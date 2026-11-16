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

use super::{Screen, ScreenLayoutSnapshot};
use crate::PaneId;

impl Screen {
    /// The floating panes of the screen, back to front, by the rules: only panes of the tree, each once, frames in
    /// the screen, and at least one tiled pane.
    pub(crate) fn floating_panes(&self) -> Vec<Floating<PaneId>> {
        if self.floating.is_empty() {
            return Vec::new();
        }
        rules::normalized(&self.root.pane_ids_vec(), &self.floating)
    }

    /// Replaces the list with `floating` as the rules read it against the tree of now. Every change of the tree
    /// that takes a pane away ends here, so an entry of a pane that became tiled by the rules never comes back.
    pub(crate) fn set_floating_panes(&mut self, floating: Vec<Floating<PaneId>>) {
        self.floating = if floating.is_empty() {
            floating
        } else {
            rules::normalized(&self.root.pane_ids_vec(), &floating)
        };
    }

    /// [`Self::set_floating_panes`] of the list the screen has.
    pub(crate) fn settle_floating_panes(&mut self) {
        let floating = std::mem::take(&mut self.floating);
        self.set_floating_panes(floating);
    }

    /// Whether `pane` never floats: a member of a stack, and a pane of a docked column or of a column with rows.
    pub(crate) fn pane_never_floats(&self, pane: PaneId) -> bool {
        self.root.contains_stack_pane(pane)
            || self
                .layout_columns
                .iter()
                .find(|column| column.root.contains(pane))
                .is_some_and(|column| column.dock.is_some() || !column.rows.is_empty())
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
            if self.zoomed_pane == Some(pane) {
                self.zoomed_pane = None;
            }
        }
        let changed = next != self.floating;
        self.floating = next;
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
    /// The snapshot's list as the rules read it against the snapshot's tree: after a pane left the tree.
    pub(crate) fn settle_floating_panes(&mut self) {
        if !self.floating.is_empty() {
            self.floating = rules::normalized(&self.root.pane_ids_vec(), &self.floating);
        }
    }

    /// Brings a floating `pane` to the front of the snapshot's list.
    pub(crate) fn raise_floating_pane(&mut self, pane: PaneId) {
        if self.floating.iter().any(|entry| entry.pane == pane) {
            self.floating = rules::raised(&self.root.pane_ids_vec(), &self.floating, &pane);
        }
    }
}
