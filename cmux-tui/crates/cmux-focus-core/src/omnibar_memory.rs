//! Chrome's per-tab omnibox focus (`OmniboxEditModel::SaveStateToTab`,
//! `RestoreState`): a browser tab left while its address bar had the
//! keyboard gets the address bar back when the user returns to the tab (a
//! tab click, a tab shortcut, a pane or workspace switch). A click in the
//! tab's page, or any other focus that lands on the tab, forgets it.
//!
//! The reducer drops a chrome target when the selected tab changes
//! (`addressBar` falls back to `content`); this memory sits above it. When
//! [`OmnibarFocusMemory::note`] says so, the window queues
//! [`return_event`] to ask for the address bar again once the tab is back.
//! The app FFI's focus handle keeps one per window and runs it on every
//! reduction.

use crate::event::{FocusEvent, Source};
use crate::state::{Resolved, Target};

/// At most this many tabs are remembered.
pub const LIMIT: usize = 64;

/// The event that asks for a remembered tab's address bar back.
pub fn return_event() -> FocusEvent {
    FocusEvent::FocusTarget { target: Target::AddressBar {}, source: Source::Programmatic }
}

fn is_return_event(event: &FocusEvent) -> bool {
    matches!(
        event,
        FocusEvent::FocusTarget { target: Target::AddressBar {}, source: Source::Programmatic }
    )
}

/// The events by which the user reaches a tab from another one: a tab or
/// pane choice, a topology change (a workspace switch), a landed
/// expectation, a drop, a closed overlay, the window becoming key.
pub fn is_return(event: &FocusEvent) -> bool {
    matches!(
        event,
        FocusEvent::SelectTab { .. }
            | FocusEvent::FocusPane { .. }
            | FocusEvent::Topology { .. }
            | FocusEvent::Expect { .. }
            | FocusEvent::DragEnded { .. }
            | FocusEvent::OverlayClosed { .. }
            | FocusEvent::WindowKey { .. }
    )
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OmnibarFocusMemory {
    /// Tabs whose address bar had the keyboard when the user left them,
    /// oldest first.
    tabs: Vec<String>,
    /// [`return_event`] is queued and not yet reduced.
    return_queued: bool,
}

fn tab_of(resolved: &Resolved) -> Option<&str> {
    match resolved {
        Resolved::Terminal { tab, .. }
        | Resolved::BrowserPage { tab, .. }
        | Resolved::AddressBar { tab, .. }
        | Resolved::FindBar { tab, .. }
        | Resolved::DevTools { tab, .. }
        | Resolved::AgentPage { tab, .. }
        | Resolved::Page { tab, .. }
        | Resolved::Conversation { tab, .. } => Some(tab),
        _ => None,
    }
}

impl OmnibarFocusMemory {
    pub fn new() -> OmnibarFocusMemory {
        OmnibarFocusMemory::default()
    }

    /// The remembered tabs, oldest first.
    pub fn tabs(&self) -> &[String] {
        &self.tabs
    }

    /// Notes one reduction of `event`, which took the keyboard target from
    /// `before` to `after`. True when it brought back a tab whose address
    /// bar had the keyboard: the caller queues [`return_event`].
    pub fn note(&mut self, event: &FocusEvent, before: &Resolved, after: &Resolved) -> bool {
        self.note_reduction(is_return(event), before, after)
    }

    /// [`OmnibarFocusMemory::note`] for an event already classified by
    /// [`is_return`] (a topology report, which the handle does not build as
    /// an event).
    pub fn note_reduction(&mut self, returning: bool, before: &Resolved, after: &Resolved) -> bool {
        let after_tab = tab_of(after);
        if let Resolved::AddressBar { tab: left, .. } = before
            && after_tab != Some(left.as_str())
        {
            // Tabs of other workspaces stay remembered; a closed tab's id
            // never comes back, so past the bound the oldest entry goes.
            if !self.tabs.contains(left) {
                if self.tabs.len() >= LIMIT {
                    self.tabs.remove(0);
                }
                self.tabs.push(left.clone());
            }
        }
        let Some(tab) = after_tab else { return false };
        let Some(index) = self.tabs.iter().position(|t| t == tab) else { return false };
        self.tabs.remove(index);
        // Only a return to the tab restores: its page, reached from another
        // tab by a tab or pane change. A click in its page is the user's
        // choice (a responder report), and so is any other target there.
        if !matches!(after, Resolved::BrowserPage { .. })
            || tab_of(before) == Some(tab)
            || !returning
        {
            return false;
        }
        self.return_queued = true;
        true
    }

    /// Whether `event`, about to be reduced, is the [`return_event`] this
    /// memory asked for: its address-bar focus is a return to the tab, which
    /// brings the edit back as it was (Chrome
    /// `OmniboxViewViews::OnTabChanged` restores the saved selection)
    /// instead of selecting all. True once per queued return event.
    pub fn take_return(&mut self, event: &FocusEvent) -> bool {
        if !self.return_queued || !is_return_event(event) {
            return false;
        }
        self.return_queued = false;
        true
    }
}
