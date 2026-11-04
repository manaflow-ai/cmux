//! Page-first chords (DESIGN.md section 4.7; the app's
//! `KeyRouter+PageFirstKeys.swift`): a web page keeps the shortcuts it handles,
//! as Chrome gives a page every key but its reserved window keys. A chord bound
//! to a cmux action that a page may own goes first to a page that reports the
//! keys it leaves unhandled (a Chromium page with the keys; a WebKit page never
//! reports, so its chords run at once). The action runs only when the page
//! reports the key unhandled ([`InputEvent::PageUnhandled`] names the key's
//! id): then with the key as its input, aimed at the tab the key was typed
//! for, at most once.
//!
//! An offer ends exactly once: its action runs, or [`InputEffect::OfferClosed`]
//! says why not. A page answers its own keys in key order, so an answer closes
//! that page's older offers as handled (never another page's). The offers
//! waiting for one page are bounded like a lane (the router's lane limit): past
//! the bound the oldest one closes, visibly (R9 R-L1, R-L5).
//!
//! [`InputEvent::PageUnhandled`]: super::InputEvent::PageUnhandled

use super::binding::DEV_TOOLS_ACTIONS;
use super::key::{Binding, KeyRecord, Tier};
use super::router::InputRouter;
use super::sink::Sink;
use super::{InputEffect, InputId, OfferEnd, Via};
use crate::state::{FocusState, Resolved};
use std::sync::Arc;

/// Navigation actions a page may own too: Find and its neighbors.
const PAGE_OWNABLE_ACTIONS: [&str; 4] = ["find", "findNext", "findPrevious", "useSelectionForFind"];

/// Actions that act on the window before any page, whatever chord they have
/// (Shift-Cmd-L, like Chrome's Cmd-T; #32789).
const OPENS_BROWSER_ACTIONS: [&str; 3] =
    ["openBrowser", "openBrowser.chromium", "openBrowser.webkit"];

/// A key offered to a page, with the action its unhandled report runs.
pub(super) struct Offer {
    pub(super) id: InputId,
    /// The page it went to.
    page: Sink,
    action: Arc<str>,
    tab: Option<Arc<str>>,
}

impl InputRouter {
    /// The page key `key` goes to first, with its binding `binding` held for
    /// the page's report: the page the key is aimed at (`aim`), when it is
    /// the window's focused browser page, takes keys now by AppKit's dispatch
    /// (its window has the keys), and the action is one a page may own. None:
    /// the action runs now.
    pub(super) fn offer_target(
        &self,
        binding: &Binding,
        key: &KeyRecord,
        focus: &FocusState,
        aim: Option<&Sink>,
    ) -> Option<Sink> {
        let page = aim?;
        let Sink::Content(aimed) = page else { return None };
        let Resolved::BrowserPage { tab, .. } = &focus.derived.resolved else { return None };
        if aimed.as_ref() != tab.as_str()
            || !key.page_reports_unhandled
            || focus.derived.browser_focus_mode_active
            || binding.ghostty
        {
            return None;
        }
        let action: &str = &binding.action;
        // DevTools runs its own actions: never offered to a page.
        if DEV_TOOLS_ACTIONS.contains(&action) {
            return None;
        }
        let owns = match binding.tier {
            Tier::Content => true,
            Tier::Navigation => {
                PAGE_OWNABLE_ACTIONS.contains(&action)
                    || (!OPENS_BROWSER_ACTIONS.contains(&action) && key.page_editing_chord)
            }
            Tier::System => false,
        };
        let takes_now = key.reaches.as_ref() == Some(page)
            && !self.lanes.contains_key(page)
            && self.deliverable(page, key.reaches.as_ref(), false) == Ok(Via::Responder);
        if owns && takes_now { Some(page.clone()) } else { None }
    }

    /// Offers key `id` to `page`, holding `binding` for its report. Past the
    /// bound, the page's oldest offer closes first.
    pub(super) fn offer(
        &mut self,
        id: InputId,
        binding: &Binding,
        page: Sink,
        tab: Option<Arc<str>>,
    ) {
        let waiting = self.offers.iter().filter(|offer| offer.page == page).count();
        if waiting >= self.lane_limit.keys()
            && let Some(oldest) = self.offers.iter().position(|offer| offer.page == page)
            && let Some(dropped) = self.offers.remove(oldest)
        {
            self.push(InputEffect::OfferClosed { id: dropped.id, reason: OfferEnd::Overflow });
        }
        let action = binding.action.clone();
        self.offers.push_back(Offer { id, page: page.clone(), action: action.clone(), tab });
        self.push(InputEffect::Offer { id, sink: page, via: Via::Responder, action });
    }

    /// The page answered offered key `id`: its action runs when the page left
    /// it unhandled, at most once. The same page's older offers were handled
    /// (a page answers its keys in key order) and close.
    pub(super) fn page_answered(&mut self, id: InputId, unhandled: bool) {
        let Some(index) = self.offers.iter().position(|offer| offer.id == id) else { return };
        let Some(answered) = self.offers.remove(index) else { return };
        let mut index = 0;
        while index < self.offers.len() {
            let older = self
                .offers
                .get(index)
                .is_some_and(|offer| offer.id < id && offer.page == answered.page);
            if older && let Some(handled) = self.offers.remove(index) {
                self.push(InputEffect::OfferClosed { id: handled.id, reason: OfferEnd::Handled });
            } else {
                index = index.saturating_add(1);
            }
        }
        if unhandled {
            let Offer { id, action, tab, .. } = answered;
            self.push(InputEffect::Run { id, action, tab });
        } else {
            self.push(InputEffect::OfferClosed { id, reason: OfferEnd::Handled });
        }
    }

    /// `page` ended: its offers can get no answer, and close.
    pub(super) fn close_offers_of(&mut self, page: &Sink) {
        let mut index = 0;
        while index < self.offers.len() {
            if self.offers.get(index).is_some_and(|offer| offer.page == *page)
                && let Some(closed) = self.offers.remove(index)
            {
                self.push(InputEffect::OfferClosed { id: closed.id, reason: OfferEnd::PageGone });
            } else {
                index = index.saturating_add(1);
            }
        }
    }
}
