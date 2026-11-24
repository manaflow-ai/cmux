//! A chat that moved to a peer still answers here, for the clients that hold it by this
//! daemon's connection: its tombstone (`SessionMeta::moved_to`, `transfer_out.rs`) names the
//! peer, and a request for it goes on to the copy there (`server/peer_forward.rs`) instead of
//! being refused as `transfer.moved`. The chat's stream follows it too (`server/follow.rs`).

use super::*;

/// The most moves one request follows, peer to peer (the outbox's own bound for a message,
/// `server/outbox.rs` `MAX_MOVES_FOLLOWED`).
pub const MAX_MOVES_FOLLOWED: u64 = 16;

/// `_meta.acpmux` field: how many tombstones this request was forwarded through.
pub const MOVED_HOPS_FIELD: &str = "movedHops";

impl Hub {
    /// The peer copy of the chat `key` names here, when that chat is this daemon's tombstone
    /// of a move (`moved_to`) whose `host` is a peer of this daemon with its link up: the peer,
    /// the chat's id there, and its row from that peer's list (`Null` before the row came).
    /// None for any other chat, for a host that is no peer's name, and for a peer that is
    /// down: the caller then answers as before (`transfer.moved`).
    pub fn moved_forward(&self, key: &str) -> Option<(Arc<crate::peer::Peer>, String, Value)> {
        let (peer, id, entry) = self.moved_forward_entry(key)?;
        Some((peer, id, entry.map_or(Value::Null, |r| r.summary.value())))
    }

    fn moved_forward_entry(
        &self,
        key: &str,
    ) -> Option<(Arc<crate::peer::Peer>, String, Option<Arc<RemoteSession>>)> {
        let session = self.resolve(key).ok()?;
        let to = session.read_meta(|m| m.moved_to.clone())?;
        let peer = self.peer_by_name(to.get("host")?.as_str()?)?;
        if !peer.ready() {
            return None;
        }
        let id = to
            .get("sessionId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .unwrap_or(&session.id)
            .to_owned();
        let row = self
            .resolve_remote_entry(&format!("{}/{id}", peer.name))
            .filter(|(p, row)| p.name == peer.name && row.receipt.mux_session_id == id)
            .map(|(_, row)| row);
        Some((peer, id, row))
    }

    /// The state of local chat `id` where it runs now, when it moved away: its row from the
    /// peer its tombstone names ([`Self::moved_forward`]), as the chat looked before it moved
    /// (no `peer`, no second id). None for a chat that is here, and while the peer is down or
    /// its row has not come: the caller reads this daemon's own row then.
    /// A wait reads it (`server/wait.rs`): the tombstone is closed, so without it a wait for a
    /// moved chat's turn to end answered at once, while the turn ran on the other machine.
    pub fn moved_row(&self, id: &str) -> Option<Value> {
        let (_, _, mut row) = self.moved_forward(id)?;
        let fields = row.as_object_mut()?;
        fields.remove("peer");
        fields.remove("qualifiedSessionId");
        Some(row)
    }

    /// Where a request for `key` goes when not here: a peer's chat (`resolve_remote`, for a key
    /// that names no chat of this daemon), or the peer copy of a chat that moved away
    /// ([`Self::moved_forward`]), with whether it is that one.
    pub fn remote_or_moved(
        &self,
        key: &str,
    ) -> Option<(Arc<crate::peer::Peer>, String, Value, bool)> {
        let (peer, id, row, moved) = self.remote_or_moved_entry(key)?;
        Some((peer, id, row.map_or(Value::Null, |r| r.summary.value()), moved))
    }

    pub(crate) fn remote_or_moved_entry(
        &self,
        key: &str,
    ) -> Option<(Arc<crate::peer::Peer>, String, Option<Arc<RemoteSession>>, bool)> {
        if self.resolve(key).is_err() {
            let (peer, row) = self.resolve_remote_entry(key)?;
            return Some((peer, row.receipt.mux_session_id.clone(), Some(row), false));
        }
        self.moved_forward_entry(key).map(|(peer, id, row)| (peer, id, row, true))
    }
}
