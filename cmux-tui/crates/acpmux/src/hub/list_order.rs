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
    sorted: BTreeMap<(Reverse<u64>, String), OrderRow>,
    /// Each row's `updatedAt` as it is placed: its key in `sorted`.
    at: HashMap<String, u64>,
    /// How many times every chat was sorted again (`Hub::list_order_rebuilds_for_test`).
    #[cfg(test)]
    rebuilds: u64,
}

/// A row of the order: a session in memory, or an evicted chat's row (`evict.rs`).
#[derive(Clone)]
pub(crate) enum OrderRow {
    Own(Arc<Session>),
    Evicted(Arc<super::evict::Evicted>),
}

impl OrderRow {
    pub(crate) fn id(&self) -> &str {
        match self {
            Self::Own(session) => &session.id,
            Self::Evicted(row) => row.id(),
        }
    }

    fn updated_at(&self) -> u64 {
        match self {
            Self::Own(session) => session.read_meta(|m| m.updated_at),
            Self::Evicted(row) => row.updated_at(),
        }
    }

    /// The session, when it is in memory.
    pub(crate) fn live(&self) -> Option<&Arc<Session>> {
        match self {
            Self::Own(session) => Some(session),
            Self::Evicted(_) => None,
        }
    }
}

impl Order {
    /// Places row `id` again: where its `updatedAt` puts it, or nowhere when it is gone.
    fn place(&mut self, id: &str, row: Option<OrderRow>) {
        if let Some(old) = self.at.remove(id) {
            self.sorted.remove(&(Reverse(old), id.to_owned()));
        }
        if let Some(row) = row {
            let updated = row.updated_at();
            self.at.insert(id.to_owned(), updated);
            self.sorted.insert((Reverse(updated), id.to_owned()), row);
        }
    }

    /// Row `id`'s entry, when it is placed.
    fn entry_mut(&mut self, id: &str) -> Option<&mut OrderRow> {
        let at = *self.at.get(id)?;
        self.sorted.get_mut(&(Reverse(at), id.to_owned()))
    }
}

/// The order's lock, held by an eviction across its map change (`evict.rs`).
pub(super) struct OrderGuard<'a>(std::sync::MutexGuard<'a, Order>);

type Placed<'a> = (&'a (Reverse<u64>, String), &'a OrderRow);

/// A row of the order and the `updatedAt` it is placed by.
fn row(((Reverse(at), _), placed): Placed<'_>) -> (OrderRow, u64) {
    (placed.clone(), *at)
}

impl Hub {
    /// The order, patched to the row log's head: the rows changed since its last read placed
    /// again, or every chat sorted once when the log cannot be followed or the count is off.
    fn patched_order(&self) -> std::sync::MutexGuard<'_, Order> {
        let mut order = self.list_order.0.lock().unwrap_or_else(|e| e.into_inner());
        let since = if order.built { self.events.list_since(order.head) } else { None };
        let patched = since.is_some_and(|since| {
            for (_, key, _) in since.rows {
                if let row_log::RowKey::Own(id) = key {
                    let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
                    let session = sessions.get(&id).cloned();
                    drop(sessions);
                    let row = session
                        .map(OrderRow::Own)
                        .or_else(|| self.evicted.get(&id).map(OrderRow::Evicted));
                    order.place(&id, row);
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
                order.place(&id, Some(OrderRow::Own(session)));
            }
            for evicted in self.evicted.rows() {
                let id = evicted.id().to_owned();
                order.place(&id, Some(OrderRow::Evicted(evicted)));
            }
            order.built = true;
            #[cfg(test)]
            {
                order.rebuilds += 1;
            }
        }
        order
    }

    /// At most `most` of this daemon's rows in list order, each with the `updatedAt` it is
    /// placed by, from the first no newer than `from` (every row when None); and whether they
    /// are all the rows from there. Costs the rows changed since the last read, and `most`.
    pub(super) fn own_rows_from(
        &self,
        from: Option<u64>,
        most: usize,
    ) -> (Vec<(OrderRow, u64)>, bool) {
        let order = self.patched_order();
        let rows: Vec<(OrderRow, u64)> = match from {
            None => order.sorted.iter().take(most).map(row).collect(),
            Some(from) => {
                order.sorted.range((Reverse(from), String::new())..).take(most).map(row).collect()
            }
        };
        let all = rows.len() < most;
        (rows, all)
    }

    /// This daemon's rows placed by an `updatedAt` at or after `cutoff`, newest first: the head
    /// of the order, read until its first older row. Costs the rows changed since the last read
    /// and the rows it answers (the usage pass's chats changed in the last day,
    /// `usage_view.rs`), never a walk of every chat.
    pub(super) fn own_rows_since(&self, cutoff: u64) -> Vec<Arc<Session>> {
        let order = self.patched_order();
        order
            .sorted
            .iter()
            .take_while(|((Reverse(at), _), _)| *at >= cutoff)
            // An evicted chat did nothing for its idle period: its usage is in its stored row.
            .filter_map(|(_, row)| row.live().cloned())
            .collect()
    }

    /// The order, patched, held across an eviction's map change (lock order: the order, then
    /// the map, as [`Self::patched_order`] takes them).
    pub(super) fn list_order_lock(&self) -> OrderGuard<'_> {
        OrderGuard(self.patched_order())
    }

    /// Row `id` is an evicted chat's from now on; whether it was placed.
    pub(super) fn order_evict(
        order: &mut OrderGuard<'_>,
        id: &str,
        row: &Arc<super::evict::Evicted>,
    ) -> bool {
        match order.0.entry_mut(id) {
            Some(entry) => {
                *entry = OrderRow::Evicted(row.clone());
                true
            }
            None => false,
        }
    }

    /// An eviction that did not happen gives row `id` its session back.
    pub(super) fn order_restore(order: &mut OrderGuard<'_>, id: &str, session: &Arc<Session>) {
        if let Some(entry) = order.0.entry_mut(id) {
            *entry = OrderRow::Own(session.clone());
        }
    }

    /// Sorts the order if it is not sorted yet, else patches it: the daemon's start task does it
    /// first, before any log is read (`daemon.rs`), and the load pass again once every log is
    /// read (`log_load.rs`), where it patches what the logs moved.
    pub(crate) fn sort_list_order(&self) {
        drop(self.patched_order());
    }

    /// Reads the order as a daemon's load pass does once every log is read (`log_load.rs`): a
    /// seed that puts sessions in place goes through no load pass.
    #[cfg(test)]
    pub(crate) fn warm_list_order_for_test(&self) {
        self.sort_list_order();
    }

    /// The order as a deferred start holds it before its load pass (`Hub::new` sorts it at
    /// once): never sorted, so the first reader sorts every chat.
    #[cfg(test)]
    pub(crate) fn unsort_list_order_for_test(&self) {
        let mut order = self.list_order.0.lock().unwrap_or_else(|e| e.into_inner());
        *order = Order::default();
    }

    /// How many times the order sorted every chat (its first read, a cursor the log could not
    /// follow, a count that did not match): a gate's timed read must be none of those.
    #[cfg(test)]
    pub(crate) fn list_order_rebuilds_for_test(&self) -> u64 {
        self.list_order.0.lock().unwrap_or_else(|e| e.into_inner()).rebuilds
    }

    /// The order's rows, in order, sorting nothing: what a test compares with a sort of every chat.
    #[cfg(test)]
    pub(crate) fn kept_order_for_test(&self) -> Vec<String> {
        let (rows, _) = self.own_rows_from(None, usize::MAX);
        rows.into_iter().map(|(row, _)| row.id().to_owned()).collect()
    }
}

#[cfg(test)]
#[path = "list_order_tests.rs"]
mod tests;
