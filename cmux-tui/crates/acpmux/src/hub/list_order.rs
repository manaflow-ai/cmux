//! Part of `Hub`; see `hub/mod.rs`. This daemon's own rows in list order (newest first, ties by
//! id), kept as they change, so a first page reads its own rows and not every chat's: Leo's bar is
//! a god daemon's (11,000 chats) first page at most 1.2x a small one's (525), in one harness.
//! Sorting every chat for each page was what grew with the chats (#42131).
//!
//! The order is patched from the row log (`row_log.rs`) when a page is read: every change a
//! client may see takes a list position, a change no record carries is stamped before the
//! position is read, and a row that went is a removal. So the rows changed since the order's own
//! position are exactly those that may have moved, and each is placed again from its metadata.
//! A cursor the log can no longer follow (a barrier, removals past its bound) or a session count
//! the order does not match (a session put in place with no position, as a test may) sorts every
//! chat again, once.

use super::*;
use std::cmp::Reverse;
use std::collections::BTreeMap;

/// This daemon's rows in list order, as of a list position.
#[derive(Default)]
pub(crate) struct ListOrder(StdMutex<Order>);

#[derive(Default)]
struct Order {
    built: bool,
    /// The list position the order is current to.
    head: u64,
    sorted: BTreeMap<(Reverse<u64>, String), Arc<Session>>,
    /// Each row's `updatedAt` as it is placed: its key in `sorted`.
    at: HashMap<String, u64>,
}

impl Order {
    /// Places row `id` again: where `session`'s `updatedAt` puts it, or nowhere when it is gone.
    fn place(&mut self, id: &str, session: Option<Arc<Session>>) {
        if let Some(old) = self.at.remove(id) {
            self.sorted.remove(&(Reverse(old), id.to_owned()));
        }
        if let Some(session) = session {
            let updated = session.read_meta(|m| m.updated_at);
            self.at.insert(id.to_owned(), updated);
            self.sorted.insert((Reverse(updated), id.to_owned()), session);
        }
    }
}

type Placed<'a> = (&'a (Reverse<u64>, String), &'a Arc<Session>);

/// A row of the order and the `updatedAt` it is placed by.
fn row(((Reverse(at), _), session): Placed<'_>) -> (Arc<Session>, u64) {
    (session.clone(), *at)
}

impl Hub {
    /// At most `most` of this daemon's rows in list order, each with the `updatedAt` it is
    /// placed by, from the first no newer than `from` (every row when None); and whether they
    /// are all the rows from there. Costs the rows changed since the last read, and `most`.
    pub(super) fn own_rows_from(
        &self,
        from: Option<u64>,
        most: usize,
    ) -> (Vec<(Arc<Session>, u64)>, bool) {
        let mut order = self.list_order.0.lock().unwrap_or_else(|e| e.into_inner());
        let since = if order.built { self.events.list_since(order.head) } else { None };
        let patched = since.is_some_and(|since| {
            for (_, key, _) in since.rows {
                if let row_log::RowKey::Own(id) = key {
                    let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
                    let session = sessions.get(&id).cloned();
                    drop(sessions);
                    order.place(&id, session);
                }
            }
            order.head = since.head;
            order.at.len() == self.session_count()
        });
        if !patched {
            // Read first: a change after it is placed again by the next read, and its metadata
            // read now is as new or newer.
            order.head = self.events.list_head();
            order.sorted.clear();
            order.at.clear();
            for session in self.session_handles() {
                let id = session.id.clone();
                order.place(&id, Some(session));
            }
            order.built = true;
        }
        let rows: Vec<(Arc<Session>, u64)> = match from {
            None => order.sorted.iter().take(most).map(row).collect(),
            Some(from) => {
                order.sorted.range((Reverse(from), String::new())..).take(most).map(row).collect()
            }
        };
        let all = rows.len() < most;
        (rows, all)
    }

    /// The order's rows, in order, sorting nothing: what a test compares with a sort of every chat.
    #[cfg(test)]
    pub(crate) fn kept_order_for_test(&self) -> Vec<String> {
        let (rows, _) = self.own_rows_from(None, usize::MAX);
        rows.into_iter().map(|(session, _)| session.id.clone()).collect()
    }
}

#[cfg(test)]
#[path = "list_order_tests.rs"]
mod tests;
