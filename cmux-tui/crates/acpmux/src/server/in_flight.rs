//! A connection's requests in flight, by id: what a client's `$/cancel_request` finds
//! (`request_cancel.rs`).
//!
//! Each entry holds its request's work slot. A cancel takes the entry, which frees the slot at
//! once, answers the request with the cancelled error and drops the future that serves it; that
//! future's own answer, if it still comes, finds no entry and is dropped. Whichever of the two
//! takes the entry first answers, so a request is answered exactly once.

use crate::rpc::Id;
use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::sync::{OwnedSemaphorePermit, oneshot};

struct Entry {
    generation: u64,
    method: String,
    cancel: oneshot::Sender<()>,
    _slot: Option<OwnedSemaphorePermit>,
}

#[derive(Default)]
pub(crate) struct InFlight {
    next: AtomicU64,
    by_id: Mutex<HashMap<String, Entry>>,
}

/// One request's part in [`InFlight`]: what its task finishes with.
pub(crate) struct Ticket {
    /// Its key and generation; None when its id was already in flight (a client that reused
    /// one), so it is not cancellable and keeps its slot itself.
    key: Option<(String, u64)>,
    pub cancel: oneshot::Receiver<()>,
    _slot: Option<OwnedSemaphorePermit>,
}

impl InFlight {
    fn map(&self) -> std::sync::MutexGuard<'_, HashMap<String, Entry>> {
        self.by_id.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Request `id` of `method` starts, holding `slot`.
    pub(crate) fn begin(
        &self,
        id: &Id,
        method: &str,
        slot: Option<OwnedSemaphorePermit>,
    ) -> Ticket {
        let (tx, rx) = oneshot::channel();
        let key = id.to_string();
        let mut map = self.map();
        if id.is_null() || map.contains_key(&key) {
            return Ticket { key: None, cancel: rx, _slot: slot };
        }
        let generation = self.next.fetch_add(1, Ordering::Relaxed);
        map.insert(
            key.clone(),
            Entry { generation, method: method.to_owned(), cancel: tx, _slot: slot },
        );
        Ticket { key: Some((key, generation)), cancel: rx, _slot: None }
    }

    /// The client cancelled request `id`: its method when it was in flight. Its slot is free
    /// and its task told to stop; the caller answers it.
    pub(crate) fn cancel(&self, id: &Id) -> Option<String> {
        let entry = self.map().remove(&id.to_string())?;
        let _ = entry.cancel.send(());
        Some(entry.method)
    }

    /// The request's task has its answer: true when it still owns it and sends it, false when a
    /// cancel answered the request already.
    pub(crate) fn finish(&self, ticket: &Ticket) -> bool {
        let Some((key, generation)) = &ticket.key else { return true };
        let mut map = self.map();
        match map.get(key) {
            Some(entry) if entry.generation == *generation => {
                map.remove(key);
                true
            }
            _ => false,
        }
    }

    /// How many requests are in flight now.
    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.map().len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Arc;
    use tokio::sync::Semaphore;

    #[test]
    fn a_cancel_frees_the_slot_at_once_and_the_late_answer_is_not_sent() {
        let slots = Arc::new(Semaphore::new(2));
        let flights = InFlight::default();
        let first = flights.begin(&json!(1), "m", Some(slots.clone().try_acquire_owned().unwrap()));
        let second =
            flights.begin(&json!(2), "m", Some(slots.clone().try_acquire_owned().unwrap()));
        assert_eq!(slots.available_permits(), 0);
        assert_eq!(flights.cancel(&json!(1)).as_deref(), Some("m"));
        assert_eq!(slots.available_permits(), 1, "freed by the cancel");
        assert!(!flights.finish(&first), "its answer is not sent");
        assert!(flights.finish(&second));
        assert_eq!((flights.len(), slots.available_permits()), (0, 2));
        assert_eq!(flights.cancel(&json!(2)), None, "nothing left to cancel");
    }

    #[test]
    fn a_reused_id_keeps_its_own_slot_and_is_not_cancelled_for_the_first() {
        let flights = InFlight::default();
        let first = flights.begin(&json!("a"), "m", None);
        let again = flights.begin(&json!("a"), "m", None);
        assert!(flights.finish(&again));
        assert_eq!(flights.len(), 1);
        assert!(flights.finish(&first));
    }
}
