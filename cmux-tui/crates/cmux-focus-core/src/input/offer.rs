//! Page-first chords (DESIGN.md section 4.7; the app's
//! `KeyRouter+PageFirstKeys.swift`): a web page keeps the shortcuts it handles,
//! as Chrome gives a page every key but its reserved window keys. A chord bound
//! to a cmux action that a page may own goes to the page first, and the action
//! runs only when Chromium reports that the page left the key unhandled
//! ([`InputEvent::PageUnhandled`] names the key's id). The action then runs with
//! the key as its input and aimed at the tab the key was typed for, at most once.
//!
//! [`InputEvent::PageUnhandled`]: super::InputEvent::PageUnhandled

use super::key::{Binding, KeyRecord, Tier};
use super::router::{DEV_TOOLS_ACTIONS, InputRouter};
use super::sink::Sink;
use super::{InputEffect, InputId, Via};
use crate::state::{FocusState, Resolved};
use std::sync::Arc;

/// Navigation actions a page may own too: Find and its neighbors.
const PAGE_OWNABLE_ACTIONS: [&str; 4] = ["find", "findNext", "findPrevious", "useSelectionForFind"];

/// Actions that act on the window before any page, whatever chord they have
/// (Shift-Cmd-L, like Chrome's Cmd-T; #32789).
const OPENS_BROWSER_ACTIONS: [&str; 3] =
    ["openBrowser", "openBrowser.chromium", "openBrowser.webkit"];

/// Offers kept at most: an older one's page handled it or never reports it.
pub(super) const OFFER_LIMIT: usize = 16;

/// A key offered to a page, with the action its unhandled report runs.
pub(super) struct Offer {
    pub(super) id: InputId,
    pub(super) action: Arc<str>,
    pub(super) tab: Option<Arc<str>>,
}

impl InputRouter {
    /// The page key `key` goes to first, with its binding `binding` held for
    /// the page's report: the focused page's when that page takes keys now by
    /// AppKit's dispatch (its window has the keys), and the action is one a
    /// page may own. None: the action runs now.
    pub(super) fn offer_target(
        &self,
        binding: &Binding,
        key: &KeyRecord,
        focus: &FocusState,
    ) -> Option<Sink> {
        // Today: a bound chord runs its action at once.
        let _ = (binding, key, focus);
        None
    }

    /// Offers key `id` to `page`, holding `binding` for its report.
    pub(super) fn offer(
        &mut self,
        id: InputId,
        binding: &Binding,
        page: Sink,
        tab: Option<Arc<str>>,
    ) {
        self.offers.push_back(Offer { id, action: binding.action.clone(), tab });
        while self.offers.len() > OFFER_LIMIT {
            self.offers.pop_front();
        }
        self.push(InputEffect::Offer {
            id,
            sink: page,
            via: Via::Responder,
            action: binding.action.clone(),
        });
    }

    /// The page left key `id` unhandled: its held action runs, once. Every
    /// older offer was handled by its page (a page reports in key order) and
    /// is forgotten.
    pub(super) fn page_unhandled(&mut self, id: InputId) {
        let Some(index) = self.offers.iter().position(|offer| offer.id == id) else { return };
        let held = self.offers.drain(..=index).next_back();
        if let Some(offer) = held {
            self.push(InputEffect::Run { id: offer.id, action: offer.action, tab: offer.tab });
        }
    }
}
