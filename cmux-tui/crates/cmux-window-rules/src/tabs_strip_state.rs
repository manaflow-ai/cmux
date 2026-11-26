//! A tab strip's small state rules: what an inline rename commits
//! (`TabInlineRename.commit`), where each tab sits in one layout
//! (`TabSlotIndex`), and when a strip leaves its model's change for later and
//! owes one sync (`TabStripSyncHold`).

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use unicode_normalization::UnicodeNormalization;

/// The name an inline rename of a tab now titled `title` (None: the tab is
/// gone) sends for `text`, trimmed of whitespace and newlines; None when it
/// names the tab as it is.
pub fn rename_commit(title: Option<&str>, text: &str) -> Option<String> {
    let name = text.trim_matches(char::is_whitespace);
    if title.is_some_and(|title| title == name || title.nfd().eq(name.nfd())) {
        return None;
    }
    Some(name.to_owned())
}

/// One slot of a layout, as the index reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Slot {
    pub id: String,
    pub is_collapsed: bool,
}

/// Where each tab sits in one layout: its slot (by position in the layout's
/// slots) and its place in the row of drawn tabs.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SlotIndex {
    /// Each tab's slot; duplicate ids (bad model data) keep the first.
    pub slots: BTreeMap<String, usize>,
    /// The drawn row, left to right (collapsed group members are out of it).
    pub row: Vec<String>,
    /// Each drawn tab's place in `row`.
    pub row_index: BTreeMap<String, usize>,
}

pub fn slot_index(slots: &[Slot]) -> SlotIndex {
    let mut index = SlotIndex::default();
    for (position, slot) in slots.iter().enumerate() {
        index.slots.entry(slot.id.clone()).or_insert(position);
        if slot.is_collapsed || index.row_index.contains_key(&slot.id) {
            continue;
        }
        index.row_index.insert(slot.id.clone(), index.row.len());
        index.row.push(slot.id.clone());
    }
    index
}

/// What the strip is, as the hold reads it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct StripFacts {
    pub in_window: bool,
    pub shown_in_window: bool,
    /// The model has no tabs.
    pub model_empty: bool,
    /// The strip shows no cells.
    pub cells_empty: bool,
    /// No gesture, drop or order override is in flight on the strip.
    pub at_rest: bool,
    /// No shown cell is a tab that left by a move to another pane.
    pub departures_disjoint: bool,
    /// The strip's pane leaves at the layout's next frame.
    pub in_a_leaving_pane: bool,
}

/// The times a tab strip does not follow its model at once, and the one
/// sync it owes for them.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SyncHold {
    /// The model changed while the strip was out of sight.
    pub changed_out_of_sight: bool,
    /// The strip kept the tabs of a pane that leaves, while its model had none.
    pub kept_tabs_of_leaving_pane: bool,
}

impl SyncHold {
    /// Whether the strip leaves its model's change for later, now.
    pub fn holds(&mut self, strip: &StripFacts) -> bool {
        if strip.in_window && !strip.shown_in_window {
            self.changed_out_of_sight = true;
            return true;
        }
        if !(strip.model_empty
            && !strip.cells_empty
            && strip.at_rest
            && strip.departures_disjoint
            && strip.in_a_leaving_pane)
        {
            return false;
        }
        self.kept_tabs_of_leaving_pane = true;
        true
    }

    /// Whether the strip owes a sync now that it shows. The hold ends.
    pub fn take_owed_sync(&mut self) -> bool {
        let owed = self.changed_out_of_sight || self.kept_tabs_of_leaving_pane;
        *self = Self::default();
        owed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_rename_trims_and_sends_only_a_change() {
        assert_eq!(rename_commit(Some("a"), "  b \n"), Some("b".into()));
        assert_eq!(rename_commit(Some("b"), "\u{3000}b\t"), None);
        assert_eq!(rename_commit(Some("caf\u{e9}"), "cafe\u{301}"), None);
        assert_eq!(rename_commit(None, " x "), Some("x".into()));
        assert_eq!(rename_commit(Some("x"), "   "), Some(String::new()));
    }

    fn slot(id: &str, collapsed: bool) -> Slot {
        Slot { id: id.into(), is_collapsed: collapsed }
    }

    #[test]
    fn collapsed_members_are_out_of_the_row_and_duplicates_keep_the_first() {
        let index =
            slot_index(&[slot("a", false), slot("b", true), slot("c", false), slot("a", false)]);
        assert_eq!(index.row, ["a", "c"]);
        assert_eq!(index.row_index["c"], 1);
        assert_eq!(index.slots["a"], 0);
        assert_eq!(index.slots["b"], 1);
        assert!(!index.row_index.contains_key("b"));
    }

    #[test]
    fn a_collapsed_first_copy_lets_a_later_one_into_the_row() {
        let index = slot_index(&[slot("a", true), slot("a", false)]);
        assert_eq!(index.slots["a"], 0);
        assert_eq!(index.row, ["a"]);
    }

    #[test]
    fn out_of_sight_holds_and_owes_one_sync() {
        let mut hold = SyncHold::default();
        let hidden = StripFacts { in_window: true, ..StripFacts::default() };
        assert!(hold.holds(&hidden));
        assert!(hold.take_owed_sync());
        assert!(!hold.take_owed_sync());
        // A strip in no window yet lays out as usual.
        assert!(!hold.holds(&StripFacts::default()));
    }

    #[test]
    fn a_leaving_pane_keeps_its_tabs_only_at_rest() {
        let leaving = StripFacts {
            in_window: true,
            shown_in_window: true,
            model_empty: true,
            at_rest: true,
            departures_disjoint: true,
            in_a_leaving_pane: true,
            ..StripFacts::default()
        };
        let mut hold = SyncHold::default();
        assert!(hold.holds(&leaving));
        assert!(hold.kept_tabs_of_leaving_pane);
        assert!(hold.take_owed_sync());
        for facts in [
            StripFacts { at_rest: false, ..leaving },
            StripFacts { departures_disjoint: false, ..leaving },
            StripFacts { cells_empty: true, ..leaving },
            StripFacts { model_empty: false, ..leaving },
            StripFacts { in_a_leaving_pane: false, ..leaving },
        ] {
            assert!(!hold.holds(&facts), "{facts:?}");
        }
        assert!(!hold.take_owed_sync());
    }
}
