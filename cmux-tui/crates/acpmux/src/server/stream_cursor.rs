//! Where each chat a connection attached stands in that chat's log, so a connection that fell
//! behind the hub's event ring reads what it missed from the store instead of skipping it.
//!
//! The ring (`list_guard::Events`, 8,192 events shared by every chat) drops the oldest events for
//! a connection that reads slower than all chats write together. Before, the connection's
//! fan-out then went on from the oldest event still in the ring and sent only
//! `_acpmux/lagged {dropped}`: a follower that did not page back itself (coord-sim's) had a
//! silent hole, 10,697 agent updates at 20 coordinators x 10 followers (cmux#47266).
//!
//! Now each attachment of this daemon's own chat keeps the seq of the last record the live path
//! handed it (`advance`). On a lap the fan-out reads each attached chat's records past that seq
//! from the store, in bounded pages, and sends them as the live path would (`catch_up`), up to
//! the chat's last seq then. The ring's own copies of those records, which come after, are at or
//! below the cursor and go no second time. A chat appends and broadcasts under its append lock
//! (`Hub::append_at_locked`), so one chat's records reach the ring in seq order: a live record at
//! or below the cursor was always handed on already.
//!
//! The cost of a lap is the records the connection missed of the chats it attached, read once,
//! whatever the number of chats on the daemon: a watcher of 2,000 chats that attaches one reads
//! that one.

use super::{Conn, Hub, StdMutex};
use crate::hub::{EventFilter, HubEvent};
use std::collections::HashMap;
use std::sync::Arc;

/// Most records in one catch-up page, and its bytes: the pane's own older page
/// (`webviews` `olderPage`).
const PAGE_RECORDS: usize = 2000;
const PAGE_BYTES: usize = 1 << 20;

#[derive(Default)]
pub(super) struct StreamCursors(StdMutex<HashMap<String, u64>>);

impl StreamCursors {
    fn map(&self) -> std::sync::MutexGuard<'_, HashMap<String, u64>> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// An attachment starts at `seq`, the chat's last seq before it subscribed: every record
    /// after it comes live (or from a catch-up).
    pub(super) fn start(&self, id: &str, seq: u64) {
        self.map().insert(id.to_owned(), seq);
    }

    /// The attachment's page covers the log through `seq`.
    pub(super) fn raise(&self, id: &str, seq: u64) {
        if let Some(at) = self.map().get_mut(id) {
            *at = (*at).max(seq);
        }
    }

    pub(super) fn forget(&self, id: &str) {
        self.map().remove(id);
    }

    /// Whether a live record of chat `id` goes on to the connection: false for one at or below
    /// where its stream stands (a catch-up sent it). Moves the cursor to it. A record with no
    /// seq, or of a chat with no cursor (not attached, or a peer's), always goes on.
    pub(super) fn advance(&self, id: &str, seq: u64) -> bool {
        if seq == 0 {
            return true;
        }
        match self.map().get_mut(id) {
            Some(at) if seq <= *at => false,
            Some(at) => {
                *at = seq;
                true
            }
            None => true,
        }
    }

    fn at(&self, id: &str) -> Option<u64> {
        self.map().get(id).copied()
    }
}

/// After the ring dropped events for `conn`: each of this daemon's chats it attached, its records
/// past its cursor read from the store and handed to `deliver`, oldest first, through the chat's
/// last seq now. Off the runtime's workers: it reads the disk.
pub(super) async fn catch_up(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    deliver: impl Fn(&Arc<Hub>, &Arc<Conn>, HubEvent),
) {
    let attached: Vec<(String, EventFilter)> = {
        let subs = conn.subs.lock().unwrap_or_else(|e| e.into_inner());
        subs.iter()
            .filter(|(_, opts)| !opts.remote)
            .map(|(id, opts)| {
                // A stream hears its own kinds; the ACP path hears every record it maps.
                let filter =
                    if opts.event_stream { opts.filter.clone() } else { EventFilter::default() };
                (id.clone(), filter)
            })
            .collect()
    };
    for (id, filter) in attached {
        let Ok(session) = hub.resolve(&id) else { continue };
        let through = session.meta().last_seq;
        while let Some(after) = conn.stream_cursors.at(&id) {
            if after >= through {
                break;
            }
            let (h, sid, f) = (hub.clone(), id.clone(), filter.clone());
            let read = tokio::task::spawn_blocking(move || {
                h.events_page(
                    &sid,
                    after,
                    Some(through.saturating_add(1)),
                    PAGE_RECORDS,
                    Some(PAGE_BYTES),
                    false,
                    &f,
                )
            })
            .await;
            let Ok(Ok(page)) = read else {
                tracing::warn!(session = %id, "catch-up after a lag could not read the log");
                break;
            };
            let last = page.events.last().map(|r| r.seq);
            for record in page.events {
                if !conn.stream_cursors.advance(&id, record.seq) {
                    continue;
                }
                deliver(
                    hub,
                    conn,
                    HubEvent {
                        session_id: id.clone(),
                        record: Arc::new(record),
                        remote: None,
                        update_line: Default::default(),
                        row: Default::default(),
                        list_seq: 0,
                        peer_batch: false,
                    },
                );
            }
            // Records the filter left out are skipped over too: the stream stands at the end.
            if !page.has_more || last.is_none() {
                conn.stream_cursors.raise(&id, through);
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::StreamCursors;

    #[test]
    fn a_record_at_or_below_the_cursor_goes_once() {
        let c = StreamCursors::default();
        assert!(c.advance("a", 5), "a chat with no cursor is not this one's");
        c.start("a", 3);
        assert!(!c.advance("a", 2));
        assert!(!c.advance("a", 3));
        assert!(c.advance("a", 4));
        assert!(!c.advance("a", 4), "the same record twice goes once");
        assert!(c.advance("a", 0), "a record with no seq always goes");
        c.raise("a", 10);
        assert!(!c.advance("a", 9));
        assert!(c.advance("a", 11));
        c.forget("a");
        assert!(c.advance("a", 1));
    }
}
