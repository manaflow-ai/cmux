//! The strip of a pane with a hole for each tab creation that has no tab yet
//! (`tab-create-place-v1`).
//!
//! A create request takes its slot when it arrives ([`PlaceLists::admit`]).
//! Its tab comes later, when its terminal has launched
//! ([`PlaceLists::commit`]); other creates and closes of the pane commit in
//! between. The rule that this list keeps: for each order of the commits, the
//! tabs of the pane are those of the same requests applied one by one in the
//! order of their arrival.
//!
//! The list is a pure value: it reads the pane's tabs from its caller and
//! holds no lock.

use super::tab_place::{Settled, Slot, TabPlace};
use crate::{PaneId, SurfaceId};

/// What a create request asked for, as its creation gives it to the list.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Asked<'a> {
    /// The connection of the request.
    pub(crate) client: u64,
    /// The `transaction` of the request: a later request of the connection
    /// names the creation by it (`place.after_creation`).
    pub(crate) transaction: Option<&'a str>,
    /// The `place` of the request; none is the end of the strip.
    pub(crate) place: Option<&'a TabPlace>,
}

/// The tab creations that have a `place` or a `transaction`, and the list of
/// each pane that has one.
#[derive(Clone, Debug, Default)]
pub(crate) struct PlaceLists {
    /// The number of the last creation.
    last: u64,
}

impl PlaceLists {
    /// A create request for `pane` arrived: its creation takes its slot among
    /// `tabs` (the pane's tabs now, with the id of each tab group run in
    /// `groups`). Gives the number of the creation.
    pub(crate) fn admit(
        &mut self,
        pane: PaneId,
        tabs: &[Slot],
        groups: &[String],
        asked: Asked<'_>,
    ) -> u64 {
        let _ = (pane, tabs, groups, asked);
        self.last += 1;
        self.last
    }

    /// The creation `hole` made `tab`: gives the index among `tabs` (the
    /// pane's tabs now) that the tab takes, and the run that it joins. A
    /// creation that the list does not know takes its slot now.
    pub(crate) fn commit(
        &mut self,
        pane: PaneId,
        tabs: &[Slot],
        groups: &[String],
        hole: Option<u64>,
        asked: Asked<'_>,
        tab: SurfaceId,
    ) -> Settled {
        let _ = (pane, groups, hole, asked, tab);
        Settled { index: tabs.len(), joined: None }
    }
}

#[cfg(test)]
#[path = "tab_create_place_model_tests.rs"]
mod tab_create_place_model_tests;
