//! A quick relation through the press of a close. The press hides the row
//! and selects the pick at once; the close can still be cancelled (the
//! question) or refused. The selection the press makes does not end the
//! quick relation of the hidden workspace; the committed close ends it
//! (`left`, `settle`), and so does the next selection of another workspace
//! in that window. A window that shows the hidden workspace again (the close
//! was cancelled) has its relation as before the press.

use super::{RepairStart, WindowCloseSelection};
use crate::close_selection::{OpenerKind, Relation};
use std::hash::Hash;

impl<T: Eq + Hash + Clone, W: Eq + Hash + Clone> WindowCloseSelection<T, W> {
    /// The workspace `repair` hid at the press of a close, when it holds a
    /// quick relation. One map read, and one read of `members` only for a
    /// press whose `shown` holds a quick relation.
    pub(super) fn hidden_by(&self, repair: &RepairStart<'_, T>) -> Option<T> {
        if !repair.pressed {
            return None;
        }
        let shown = repair.shown?;
        let quick = self.quick_relation(shown).is_some();
        (quick && !repair.members.contains(shown)).then(|| shown.clone())
    }

    fn quick_relation(&self, workspace: &T) -> Option<&Relation<T>> {
        self.openers.relation.get(workspace).filter(|relation| relation.kind == OpenerKind::Quick)
    }

    /// A repair that runs hid `workspace` at the press of a close.
    fn hides(&self, workspace: &T) -> bool {
        self.repairs.iter().any(|repair| repair.hidden.as_ref() == Some(workspace))
    }

    /// The quick relation of `old` to keep while the selection leaves it:
    /// only inside the repair of the press that hid `old`.
    pub(super) fn kept_at_press<'a>(&self, old: &'a T) -> Option<(&'a T, Relation<T>)> {
        if self.repairs.is_empty() || !self.hides(old) {
            return None;
        }
        Some((old, self.quick_relation(old)?.clone()))
    }

    /// The selection left `hidden` inside the repair of its press: its quick
    /// relation, which that move ended, is held again.
    pub(super) fn keep_pressed(&mut self, hidden: &T, relation: Relation<T>, window: &W) {
        self.openers.relation.insert(hidden.clone(), relation);
        self.pressed.insert(hidden.clone(), window.clone());
    }

    /// `window` shows `new` now. A workspace of `window` that a press hid
    /// with its quick relation kept: when `new` is that workspace the close
    /// was cancelled and the relation goes on; else the selection went on to
    /// another workspace, which ends a quick relation. The selection of the
    /// press's own repair is neither. O(workspaces a press keeps), no
    /// allocation while none is of `window`.
    pub(super) fn pressed_window_shows(&mut self, new: &T, window: &W) {
        let ended: Vec<T> = self
            .pressed
            .iter()
            .filter(|&(workspace, at)| at == window && !self.hides(workspace))
            .map(|(workspace, _)| workspace.clone())
            .collect();
        for workspace in &ended {
            self.pressed.remove(workspace);
            if workspace != new && self.quick_relation(workspace).is_some() {
                self.openers.relation.remove(workspace);
            }
        }
    }
}
