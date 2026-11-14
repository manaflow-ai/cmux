//! Part of `Hub`; see `hub/mod.rs`. A peer's purge that its session list,
//! read before the purge, must not undo.
//!
//! A peer answers `_acpmux/watch` with a list it read before it answered,
//! while its watch already sends `session_changed` notices from another task
//! (`server/requests.rs` `MUX_WATCH`, `server/mod.rs` `deliver`): a session
//! purged after the list was read can have its purge written to the link
//! before the reply. The hub takes notices in the order the link gives them
//! (`peer.rs` `serve`), so the purge removes the row and the older list puts
//! it back. Every peer in the fleet answers this way, older daemons too, so
//! this daemon decides it: a purge it took on the link before that link's
//! list is a tombstone the list cannot revive.
//!
//! What can never be hidden: only a purge that comes before its link's list
//! is kept, and only until that list, so none outlives the list. A link that
//! ends with no list (`Disconnected`; the next link's list is read after the
//! purge, so a row in it was made again) drops its tombstones, and any other
//! notice of that session lifts its tombstone. A session made again under the
//! purged id after the peer started watching sends such a notice on this link
//! (`server/change_kind.rs`), so the list loses only rows the peer no longer
//! has, or one that notice puts back. A lag (`_acpmux/lagged`) changes
//! nothing here: the list is still older than the purge, and a dropped notice
//! leaves a row out of date on base too.
//!
//! The tombstones live on the peer instance (`Peer::purge_tombstones`), so
//! they go with it: a removed or replaced peer's never reach another instance
//! of the name. Every change starts from a peer Arc found current; callers use that Arc directly so
//! the rows writer lock is never held while looking up `peers` again.

use std::collections::HashSet;
use std::sync::Mutex;

/// One peer instance's link: whether its list came, and the sessions it
/// purged before. This mutex is independent of the hub's shared lock order.
#[derive(Default)]
pub(crate) struct PurgeTombstones(Mutex<Link>);

#[derive(Default)]
struct Link {
    listed: bool,
    purged: HashSet<String>,
}

impl PurgeTombstones {
    fn link(&self) -> std::sync::MutexGuard<'_, Link> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Session `id` was purged: the link's list, if it has not come yet,
    /// leaves `id` out.
    pub(super) fn purged(&self, id: &str) {
        let mut link = self.link();
        if !link.listed {
            link.purged.insert(id.to_owned());
        }
    }

    /// Any other notice of session `id`: the peer has it now.
    pub(super) fn changed(&self, id: &str) {
        self.link().purged.remove(id);
    }

    /// The link ended: the next one's list is read after every purge so far.
    pub(super) fn link_ended(&self) {
        *self.link() = Link::default();
    }

    /// The link's list is applied now: the sessions to leave out of it. None
    /// are kept after it.
    pub(super) fn take(&self) -> HashSet<String> {
        let mut link = self.link();
        link.listed = true;
        std::mem::take(&mut link.purged)
    }

    /// Reads the current tombstones without consuming them. A full-list projection may have to
    /// retry after a concurrent purge, so it cannot mark the link listed until its row swap wins.
    pub(super) fn peek(&self) -> HashSet<String> {
        self.link().purged.clone()
    }
}

#[cfg(test)]
mod tests;
