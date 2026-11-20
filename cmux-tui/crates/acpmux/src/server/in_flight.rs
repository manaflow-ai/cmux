//! A connection's requests in flight, by id: what a client's `$/cancel_request` finds
//! (`request_cancel.rs`).
//!
//! Each entry holds its request's work slot. A cancel takes the entry, which frees the slot at
//! once, answers the request with the cancelled error and drops the future that serves it; that
//! future's own answer, if it still comes, finds no entry and is dropped. Whichever of the two
//! takes the entry first answers, so a request is answered exactly once.
//!
//! An answer sent from inside its request (a list reply, `list_reply.rs`) takes the entry as it
//! is queued, under the connection's outbound lock ([`InFlight::claim`]): a cancel read after
//! that finds nothing, and one read before it leaves the answer unsent.

use crate::rpc::Id;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::{OwnedSemaphorePermit, oneshot};

struct Entry {
    generation: u64,
    method: String,
    /// Its key among requests sent on two paths (`dual_requests.rs`): a cancel stops whichever
    /// copy runs.
    dual: Option<super::dual_requests::Key>,
    cancel: oneshot::Sender<()>,
    _slot: Option<OwnedSemaphorePermit>,
}

#[derive(Default)]
pub(crate) struct InFlight {
    next: AtomicU64,
    by_id: Mutex<HashMap<String, Entry>>,
    /// Entries of every connection of the hub together (`Hub::requests_in_flight`).
    gauge: Arc<AtomicUsize>,
}

/// One request's part in [`InFlight`]: what its task finishes with.
pub(crate) struct Ticket {
    /// Its claim on its entry; None when its id was already in flight (a client that reused
    /// one), so it is not cancellable and keeps its slot itself.
    claim: Option<Claim>,
    pub cancel: oneshot::Receiver<()>,
    _slot: Option<OwnedSemaphorePermit>,
}

/// What takes a request's entry for its own answer ([`InFlight::claim`]): its key and
/// generation, and whether it took it already.
#[derive(Clone)]
pub(crate) struct Claim {
    key: String,
    generation: u64,
    won: Arc<AtomicBool>,
}

impl Ticket {
    /// Its claim, for an answer sent before its request ends (`list_reply.rs`).
    pub(crate) fn claim(&self) -> Option<Claim> {
        self.claim.clone()
    }
}

impl InFlight {
    /// A connection's table, counted in the hub's `gauge`.
    pub(crate) fn counted(gauge: Arc<AtomicUsize>) -> Self {
        Self { next: AtomicU64::new(0), by_id: Mutex::default(), gauge }
    }

    fn map(&self) -> std::sync::MutexGuard<'_, HashMap<String, Entry>> {
        self.by_id.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn remove(&self, map: &mut HashMap<String, Entry>, key: &str) -> Option<Entry> {
        let entry = map.remove(key)?;
        self.gauge.fetch_sub(1, Ordering::Relaxed);
        Some(entry)
    }

    /// Request `id` of `method` starts, holding `slot`; `dual` is its key when it is one copy of
    /// a request sent on two paths.
    pub(crate) fn begin(
        &self,
        id: &Id,
        method: &str,
        slot: Option<OwnedSemaphorePermit>,
        dual: Option<super::dual_requests::Key>,
    ) -> Ticket {
        let (tx, rx) = oneshot::channel();
        let key = id.to_string();
        let mut map = self.map();
        if id.is_null() || map.contains_key(&key) {
            return Ticket { claim: None, cancel: rx, _slot: slot };
        }
        let generation = self.next.fetch_add(1, Ordering::Relaxed);
        map.insert(
            key.clone(),
            Entry { generation, method: method.to_owned(), dual, cancel: tx, _slot: slot },
        );
        self.gauge.fetch_add(1, Ordering::Relaxed);
        let won = Arc::default();
        Ticket { claim: Some(Claim { key, generation, won }), cancel: rx, _slot: None }
    }

    /// The client cancelled request `id`: its method and dual key when it was in flight. Its
    /// slot is free and its task told to stop; the caller answers it.
    pub(crate) fn cancel(&self, id: &Id) -> Option<(String, Option<super::dual_requests::Key>)> {
        let mut map = self.map();
        let entry = self.remove(&mut map, &id.to_string())?;
        drop(map);
        let _ = entry.cancel.send(());
        Some((entry.method, entry.dual))
    }

    /// The request takes its entry for its own answer: true when it owns the answer (now, or by
    /// an earlier claim), false when a cancel answered the request already. A cancel read after
    /// it finds nothing.
    pub(crate) fn claim(&self, claim: &Claim) -> bool {
        if claim.won.load(Ordering::SeqCst) {
            return true;
        }
        let mut map = self.map();
        match map.get(&claim.key) {
            Some(entry) if entry.generation == claim.generation => {
                self.remove(&mut map, &claim.key);
                claim.won.store(true, Ordering::SeqCst);
                true
            }
            _ => false,
        }
    }

    /// The request's task has its answer: true when it still owns it and sends it (or sent it
    /// already, [`Self::claim`]), false when a cancel answered the request already.
    pub(crate) fn finish(&self, ticket: &Ticket) -> bool {
        ticket.claim.as_ref().is_none_or(|claim| self.claim(claim))
    }

    /// How many requests are in flight now.
    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.map().len()
    }
}

impl Drop for InFlight {
    /// The connection ended: its requests still in flight leave the hub's count with it.
    fn drop(&mut self) {
        let left = self.map().len();
        self.gauge.fetch_sub(left, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tokio::sync::Semaphore;

    #[test]
    fn a_cancel_frees_the_slot_at_once_and_the_late_answer_is_not_sent() {
        let slots = Arc::new(Semaphore::new(2));
        let gauge = Arc::new(AtomicUsize::new(0));
        let flights = InFlight::counted(gauge.clone());
        let first =
            flights.begin(&json!(1), "m", Some(slots.clone().try_acquire_owned().unwrap()), None);
        let second =
            flights.begin(&json!(2), "m", Some(slots.clone().try_acquire_owned().unwrap()), None);
        assert_eq!((slots.available_permits(), gauge.load(Ordering::Relaxed)), (0, 2));
        assert_eq!(flights.cancel(&json!(1)).map(|(m, _)| m).as_deref(), Some("m"));
        assert_eq!(slots.available_permits(), 1, "freed by the cancel");
        assert!(!flights.finish(&first), "its answer is not sent");
        assert!(flights.finish(&second));
        assert_eq!((flights.len(), slots.available_permits()), (0, 2));
        assert_eq!(flights.cancel(&json!(2)), None, "nothing left to cancel");
        let _left = flights.begin(&json!(3), "m", None, None);
        assert_eq!(gauge.load(Ordering::Relaxed), 1);
        drop(flights);
        assert_eq!(gauge.load(Ordering::Relaxed), 0, "a closed connection leaves the count");
    }

    #[test]
    fn a_reused_id_keeps_its_own_slot_and_is_not_cancelled_for_the_first() {
        let flights = InFlight::default();
        let first = flights.begin(&json!("a"), "m", None, None);
        let again = flights.begin(&json!("a"), "m", None, None);
        assert!(flights.finish(&again));
        assert_eq!(flights.len(), 1);
        assert!(flights.finish(&first));
    }

    /// A list reply takes its entry as it is queued: a cancel after that finds nothing, and the
    /// request's own finish still owns the answer it sent.
    #[test]
    fn a_claimed_answer_is_not_cancelled_and_still_finishes() {
        let flights = InFlight::default();
        let sent = flights.begin(&json!(1), "_acpmux/sessions", None, None);
        let lost = flights.begin(&json!(2), "_acpmux/sessions", None, None);
        assert!(flights.claim(&sent.claim().unwrap()));
        assert_eq!(flights.cancel(&json!(1)), None, "nothing left to cancel");
        assert!(flights.finish(&sent), "it sent its answer");
        assert!(flights.cancel(&json!(2)).is_some());
        assert!(!flights.claim(&lost.claim().unwrap()), "the cancel answered it");
        assert!(!flights.finish(&lost));
        assert_eq!(flights.len(), 0);
    }
}
