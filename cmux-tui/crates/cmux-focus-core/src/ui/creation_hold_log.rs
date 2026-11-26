//! How each window's creation holds ended, by window number (Swift
//! `CreationHoldLog`; the app's `CreationInputCoordinator` keeps one, tests
//! and `debug.focus` read it). The app writes the log lines this names
//! ([`Note`]).

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// Why a window's creation hold ended (Swift `CreationHoldEnd`, R-L5).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HoldEnd {
    /// Every creation of the hold replied and the focus it asked for holds.
    FocusLanded,
    /// The hold's 2 s bound ended it first.
    LimitReached,
    /// A key went to a field outside the content.
    FocusLeft,
    WindowClosed,
    /// A creation of the hold failed; no focus landed.
    CreationFailed,
    /// A creation's reply did not come within its bound (cmux-ad m12).
    ReplyBoundReached,
}

/// The line the app logs for a hold's end ([`CreationHoldLog::note_ended`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Note {
    /// It ended at its reply bound.
    ReplyBound,
    /// It ended at its limit, not on focus.
    Limit,
    /// It ended otherwise, with keys for a new terminal lost.
    Lost,
}

/// The log. A value the app keeps and sends back.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CreationHoldLog {
    /// Windows whose current hold had a creation that failed.
    failed_creation: BTreeSet<i64>,
    /// The last end of each window's hold.
    pub last: BTreeMap<i64, HoldEnd>,
    /// How many keys of each window's last hold were lost.
    pub lost_keys: BTreeMap<i64, u64>,
    /// Held keys that ran again for a terminal that was gone, since the last hold's end began.
    gone: u64,
    /// Held New Tab / Close Tab pairs that went together, and held Close Tab
    /// keys a forced end dropped, since the log began.
    pub cancelled_tab_key_pairs: u64,
    pub lost_close_keys: u64,
    /// Tabs whose page hold ended at its bound: no new page hold opens for them.
    pub page_expired: BTreeSet<String>,
}

impl CreationHoldLog {
    /// A hold's end reduced its held keys: `pairs` went together, `lost`
    /// lone Close Tab keys were dropped (the app logs those).
    pub fn tab_keys_reduced(&mut self, pairs: u64, lost: u64) {
        self.cancelled_tab_key_pairs += pairs;
        self.lost_close_keys += lost;
    }

    /// `tab`'s page exists: a later cold show of it may hold its keys again.
    pub fn page_arrived(&mut self, tab: &str) {
        self.page_expired.remove(tab);
    }

    /// A creation of `window`'s current hold failed.
    pub fn creation_failed(&mut self, window: i64) {
        self.failed_creation.insert(window);
    }

    /// `window` is gone, and its hold with it.
    pub fn window_closed(&mut self, window: i64) {
        self.failed_creation.remove(&window);
        self.last.insert(window, HoldEnd::WindowClosed);
    }

    /// `count` held keys ran again for a terminal the person closed: lost,
    /// counted by the end of the hold that gave them out.
    pub fn went_with_terminal(&mut self, count: u64) {
        self.gone += count;
    }

    /// A hold of `window` ended `end`; `stranded` keys for a new terminal had
    /// no terminal to go to. Keeps its count of lost keys and names the line
    /// to log, with the lost count.
    pub fn note_ended(&mut self, end: HoldEnd, window: i64, stranded: u64) -> (Option<Note>, u64) {
        let untyped = stranded + self.gone;
        self.lost_keys.insert(window, untyped);
        self.gone = 0;
        let note = match end {
            HoldEnd::ReplyBoundReached => Some(Note::ReplyBound),
            HoldEnd::LimitReached => Some(Note::Limit),
            _ if untyped > 0 => Some(Note::Lost),
            _ => None,
        };
        (note, untyped)
    }

    /// `window`'s hold ends now: by `forced`, else as `creationFailed` when a
    /// creation of it failed and `focusLanded` otherwise. `page_tab`: the
    /// page a page hold waited for; ended at its limit, no new page hold
    /// opens for it.
    pub fn end(&mut self, window: i64, forced: Option<HoldEnd>, page_tab: Option<&str>) -> HoldEnd {
        self.gone = 0;
        let failed = self.failed_creation.remove(&window);
        let end =
            forced.unwrap_or(if failed { HoldEnd::CreationFailed } else { HoldEnd::FocusLanded });
        if end == HoldEnd::LimitReached
            && let Some(tab) = page_tab
        {
            self.page_expired.insert(tab.to_owned());
        }
        self.last.insert(window, end);
        end
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failed_creation_ends_its_hold_as_failed_once() {
        let mut log = CreationHoldLog::default();
        log.creation_failed(1);
        assert_eq!(log.end(1, None, None), HoldEnd::CreationFailed);
        assert_eq!(log.end(1, None, None), HoldEnd::FocusLanded);
        assert_eq!(log.end(1, Some(HoldEnd::FocusLeft), None), HoldEnd::FocusLeft);
        log.creation_failed(2);
        log.window_closed(2);
        assert_eq!(log.last[&2], HoldEnd::WindowClosed);
        assert_eq!(log.end(2, None, None), HoldEnd::FocusLanded);
    }

    #[test]
    fn a_page_hold_at_its_limit_expires_its_tab_until_the_page_arrives() {
        let mut log = CreationHoldLog::default();
        log.end(1, Some(HoldEnd::FocusLeft), Some("t"));
        assert!(log.page_expired.is_empty());
        log.end(1, Some(HoldEnd::LimitReached), Some("t"));
        assert!(log.page_expired.contains("t"));
        log.page_arrived("t");
        assert!(log.page_expired.is_empty());
    }

    #[test]
    fn keys_that_went_with_a_closed_terminal_count_as_lost_at_the_end() {
        let mut log = CreationHoldLog::default();
        log.end(1, None, None);
        log.went_with_terminal(2);
        assert_eq!(log.note_ended(HoldEnd::FocusLanded, 1, 1), (Some(Note::Lost), 3));
        assert_eq!(log.lost_keys[&1], 3);
        assert_eq!(log.note_ended(HoldEnd::FocusLanded, 1, 0), (None, 0));
        assert_eq!(log.note_ended(HoldEnd::LimitReached, 1, 0), (Some(Note::Limit), 0));
        assert_eq!(log.note_ended(HoldEnd::ReplyBoundReached, 1, 0), (Some(Note::ReplyBound), 0));
        log.tab_keys_reduced(2, 1);
        log.tab_keys_reduced(1, 0);
        assert_eq!((log.cancelled_tab_key_pairs, log.lost_close_keys), (3, 1));
    }
}
