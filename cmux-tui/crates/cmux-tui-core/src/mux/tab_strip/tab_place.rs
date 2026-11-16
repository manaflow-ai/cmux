//! The place of a new tab in its create request (`tab-create-place-v1`).
//!
//! `new-tab`, `new-conversation-tab` and `new-frontend-browser-tab` take
//! `place`: where the tab goes in the strip of its pane. The client that
//! makes the tab and the daemon then hold the same list, and no move follows
//! the create.

use crate::SurfaceId;

/// The tab or the strip end that a new tab is put next to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Anchor {
    After(SurfaceId),
    AfterCreation(String),
    Before(SurfaceId),
    Start,
}

/// The checked `place` of a create request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct TabPlace {
    pub(crate) anchor: Anchor,
    pub(crate) joins: bool,
}

/// One entry of a pane's strip as the place rules see it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Slot {
    /// The tab of the entry.
    pub(crate) tab: Option<SurfaceId>,
    /// A pinned tab: no placed tab goes before it.
    pub(crate) pinned: bool,
    /// The tab group run of the entry: entries with one number are one run.
    pub(crate) group: Option<usize>,
}

/// The index of a strip that a new tab takes, and the run that it joins.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Settled {
    pub(crate) index: usize,
    pub(crate) joined: Option<usize>,
}
