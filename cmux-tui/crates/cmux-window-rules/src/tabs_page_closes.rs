//! Closes of several tabs that wait for pages deciding their own close, so
//! each close stays one Reopen Closed step (the Mac app's
//! `PageDecidedCloses`, its bookkeeping). Pure: the app keeps each gesture's
//! prepared local halves, its deadline timer and its panes; this says which
//! gesture a page's own close joins, and when a gesture is done.
//!
//! Lawrence 2026-10-23: "if i close a bunch of tabs with cmd opt t, then cmd
//! shift t, it needs to bring it all back".

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// Tabs of one pane; `pane` is the app's name for the pane object.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Part {
    pub pane: String,
    pub ids: Vec<String>,
}

/// One gesture's bookkeeping.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Gesture {
    /// The pane the gesture's one close is sent from.
    pub first: String,
    pub user_close: bool,
    /// The pages still deciding, by tab.
    pub waiting: BTreeSet<String>,
    /// Pages that closed, by pane, in the order they closed.
    pub decided: Vec<Part>,
}

/// Every waiting gesture, by id.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Closes {
    pub gestures: BTreeMap<u64, Gesture>,
    pub next_id: u64,
}

/// What ``Closes::absorb`` did: the tabs no gesture took (they close as
/// usual) and the gestures it finished, in id order.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Absorbed {
    pub rest: Vec<Part>,
    pub finished: Vec<Finished>,
}

/// A finished gesture: the app prepares `decided` of its live panes, adds them
/// to the halves prepared at `begin`, and sends them from `first` (or the
/// first live decided pane).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Finished {
    pub id: u64,
    pub first: String,
    pub user_close: bool,
    pub decided: Vec<Part>,
}

impl Closes {
    /// Whether a gesture still waits for a page.
    pub fn is_waiting(&self) -> bool {
        !self.gestures.is_empty()
    }

    /// Starts a gesture: `closing` run their local half now (the app), and
    /// `deciding` are pages that started their own close. None (no gesture)
    /// without a part; else the gesture's id, which the deadline finishes.
    pub fn begin(&mut self, closing: &[Part], deciding: &[Part], user_close: bool) -> Option<u64> {
        let first = closing.first().or(deciding.first())?.pane.clone();
        let id = self.next_id;
        self.next_id += 1;
        let waiting = deciding.iter().flat_map(|part| part.ids.iter().cloned()).collect();
        self.gestures.insert(id, Gesture { first, user_close, waiting, decided: Vec::new() });
        Some(id)
    }

    /// Takes the tabs of `parts` a waiting gesture waits for (the page closed
    /// its tab): they join that gesture's one close. A tab two gestures wait
    /// for joins the older one.
    pub fn absorb(&mut self, parts: &[Part]) -> Absorbed {
        if self.gestures.is_empty() {
            return Absorbed { rest: parts.to_vec(), finished: Vec::new() };
        }
        let mut rest = Vec::new();
        let mut done = BTreeSet::new();
        for part in parts {
            let mut kept = Vec::new();
            for tab in &part.ids {
                let Some((&id, gesture)) =
                    self.gestures.iter_mut().find(|(_, gesture)| gesture.waiting.contains(tab))
                else {
                    kept.push(tab.clone());
                    continue;
                };
                gesture.waiting.remove(tab);
                match gesture.decided.iter_mut().find(|decided| decided.pane == part.pane) {
                    Some(decided) => decided.ids.push(tab.clone()),
                    None => gesture
                        .decided
                        .push(Part { pane: part.pane.clone(), ids: vec![tab.clone()] }),
                }
                if gesture.waiting.is_empty() {
                    done.insert(id);
                }
            }
            if !kept.is_empty() {
                rest.push(Part { pane: part.pane.clone(), ids: kept });
            }
        }
        let finished = done.into_iter().filter_map(|id| self.finish(id)).collect();
        Absorbed { rest, finished }
    }

    /// Ends gesture `id` (its deadline, or its last page closed): the pages
    /// still deciding are let go. None when it already ended.
    pub fn finish(&mut self, id: u64) -> Option<Finished> {
        let gesture = self.gestures.remove(&id)?;
        Some(Finished {
            id,
            first: gesture.first,
            user_close: gesture.user_close,
            decided: gesture.decided,
        })
    }
}

#[cfg(test)]
#[path = "tabs_page_closes_tests.rs"]
mod tests;
