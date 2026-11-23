//! The Cloud store in memory, under the real store's rules (feature `test-support`).
//!
//! [`FakeAutoCloud`] implements [`AutoCloud`](crate::cloud::AutoCloud) for tests of the code
//! that drives a chat. Another crate turns it on in its dev-dependencies:
//! `cmux-auto-session = { workspace = true, features = ["test-support"] }`.
//!
//! One store has one owner. A handle calls as the owner
//! ([`FakeAutoCloud::new`], the laptop's daemon) or as a machine ([`FakeAutoCloud::as_machine`],
//! a Cloud machine's daemon); every handle of one store sees the same chats.
//!
//! Time is the test's: the store's clock starts at 0 and moves only with
//! [`FakeAutoCloud::set_now`] and [`FakeAutoCloud::advance`]. The lease alarm runs at that clock
//! before every call, so a laptop that stopped renewing loses its chat once the test moves the
//! clock past the lease.
//!
//! The rules, as `plans/cmux-next/auto-mode/DESIGN.md` gives them:
//!
//! - Every holder write names a holder and an epoch. It is refused `auto.not_holder` when the
//!   caller cannot be that holder, `auto.stale_epoch` when they are not the chat's current ones
//!   and `auto.closed` once Auto is off.
//! - A laptop's lease lasts 45 s from its last renewal. When it runs out, a chat that needed to
//!   run (or has messages waiting) goes to the Auto machine with a `takeover` assignment and a
//!   machine start; an idle one is parked. Either way the epoch grows by one. A machine's lease
//!   does not run out.
//! - With no Auto machine the chat is parked, blocked `no_machine`, until one is set.
//! - A renewal answers `holder` to the chat's holder, and to a laptop that renews a parked
//!   chat without `standby` (the epoch grows). It answers `standby` to a laptop that renews
//!   with `standby: true` and lists it for 45 s; anyone else is `lost`.
//! - `release` moves the chat to a laptop standing by (the one that renewed last), unless a
//!   machine releases a chat kept in the Cloud; with none it is parked.
//! - Events append in order from seq 1. A repeat of stored seqs is accepted; a gap is
//!   `auto.seq_gap` with the store's last seq.
//! - A chunk must hash to its name (`auto.chunk_mismatch`) and be at most 1 MiB
//!   (`auto.too_large`). A manifest is accepted only when every chunk it names is stored
//!   (`auto.snapshot_incomplete` names the rest), its chunks are under the cap
//!   (`auto.too_large`) and the store has its events (`auto.seq_gap`).
//! - A message's id is stored once. A message for a parked chat makes the Auto machine its
//!   holder; a message for a chat a machine runs gives that machine a `deliver` assignment.
//! - An assignment stays until the machine acks it.
//!
//! `wait` and `assignments` are held requests: they answer when there is something to answer
//! or when the store's clock reaches their deadline, so a test releases one by changing the
//! chat or by moving the clock.

mod copy;
mod inbox;
mod lease;
mod owner;
mod routes;
mod store;

#[cfg(test)]
mod tests;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::task::{Context, Poll};

use store::{Caller, Store};

use crate::cloud::{AutoCloudError, CloudResult};
use crate::consts::WAIT_MAX_MS;
use crate::wire::SessionView;

/// One caller's handle on an in-memory Cloud store.
#[derive(Clone, Debug)]
pub struct FakeAutoCloud {
    store: Arc<Mutex<Store>>,
    caller: Caller,
    /// This caller has no network. Clones of the handle share it.
    offline: Arc<AtomicBool>,
}

impl Default for FakeAutoCloud {
    fn default() -> Self {
        FakeAutoCloud::new()
    }
}

impl FakeAutoCloud {
    /// A new empty store, called as its owner. The clock is at 0 and no Auto machine is set.
    pub fn new() -> FakeAutoCloud {
        FakeAutoCloud {
            store: Arc::new(Mutex::new(Store::new())),
            caller: Caller::Owner,
            offline: Arc::new(AtomicBool::new(false)),
        }
    }

    /// The same store, called as the owner, with a network of its own (a second laptop).
    pub fn as_owner(&self) -> FakeAutoCloud {
        self.as_caller(Caller::Owner)
    }

    /// The same store, called as the VM install of `machine`. Its holder is `vm:<machine>`,
    /// and the store answers it only while `machine` is the owner's Auto machine.
    pub fn as_machine(&self, machine: &str) -> FakeAutoCloud {
        self.as_caller(Caller::Machine(machine.to_owned()))
    }

    fn as_caller(&self, caller: Caller) -> FakeAutoCloud {
        FakeAutoCloud {
            store: Arc::clone(&self.store),
            caller,
            offline: Arc::new(AtomicBool::new(false)),
        }
    }

    /// The store's clock (ms).
    pub fn now(&self) -> u64 {
        self.lock().now
    }

    /// Moves the store's clock to `now` and runs the lease alarm. The clock never goes back.
    pub fn set_now(&self, now: u64) {
        let mut store = self.lock();
        store.now = store.now.max(now);
        store.alarm();
        // A held request may be at its deadline.
        store.wake();
    }

    /// Moves the store's clock on by `ms` and runs the lease alarm.
    pub fn advance(&self, ms: u64) {
        let now = self.now().saturating_add(ms);
        self.set_now(now);
    }

    /// With `true`, every call through this handle (and its clones) fails as a transport error
    /// and does not reach the store.
    pub fn set_offline(&self, offline: bool) {
        self.offline.store(offline, Ordering::SeqCst);
        self.lock().wake();
    }

    /// The most bytes a snapshot's chunks may have; the real store's is 512 MiB.
    pub fn set_snapshot_max(&self, bytes: u64) {
        self.lock().snapshot_max = bytes;
    }

    /// Every machine start the store asked for, oldest first, by machine id: one for each
    /// `takeover`, `create` and `deliver` assignment it made.
    pub fn machine_starts(&self) -> Vec<String> {
        self.lock().starts.clone()
    }

    /// Every call that reached the store, oldest first, by route name: `machine`,
    /// `set_machine`, `put`, `create`, `list`, `get`, `wait`, `lease`, `release`,
    /// `append_events`, `events`, `put_chunk`, `chunk`, `post_snapshot`, `snapshot`,
    /// `post_inbox`, `inbox`, `ack_inbox`, `keep`, `assignments`, `ack_assignment`.
    pub fn calls(&self) -> Vec<&'static str> {
        self.lock().calls.clone()
    }

    /// The chat as the store has it now, whoever asks and with no call counted. None when the
    /// store has no such chat.
    pub fn peek(&self, id: &str) -> Option<SessionView> {
        let mut store = self.lock();
        store.alarm();
        store.answer(id).ok()
    }

    fn lock(&self) -> MutexGuard<'_, Store> {
        self.store.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn no_network<T>(&self) -> CloudResult<T> {
        Err(AutoCloudError::transport("the fake is offline"))
    }

    /// One call that answers at once.
    fn call<T>(
        &self,
        route: &'static str,
        run: impl FnOnce(&mut Store, &Caller) -> CloudResult<T>,
    ) -> CloudResult<T> {
        if self.offline.load(Ordering::SeqCst) {
            return self.no_network();
        }
        let mut guard = self.lock();
        let store: &mut Store = &mut guard;
        store.alarm();
        store.calls.push(route);
        run(store, &self.caller)
    }

    /// When a request held for `timeout_ms` from now answers at the latest.
    fn deadline(&self, route: &'static str, timeout_ms: u64) -> CloudResult<u64> {
        self.call(route, |store, _| Ok(store.now.saturating_add(timeout_ms.min(WAIT_MAX_MS))))
    }

    /// One look of a held request. `look` answers None while there is nothing to answer; at the
    /// deadline it is told so and must answer.
    fn held<T>(
        &self,
        cx: &mut Context<'_>,
        deadline: u64,
        look: impl FnOnce(&mut Store, &Caller, bool) -> Option<CloudResult<T>>,
    ) -> Poll<CloudResult<T>> {
        if self.offline.load(Ordering::SeqCst) {
            return Poll::Ready(self.no_network());
        }
        let mut guard = self.lock();
        let store: &mut Store = &mut guard;
        store.alarm();
        let due = store.now >= deadline;
        match look(&mut *store, &self.caller, due) {
            Some(answer) => Poll::Ready(answer),
            None => {
                if !store.wakers.iter().any(|waker| waker.will_wake(cx.waker())) {
                    store.wakers.push(cx.waker().clone());
                }
                Poll::Pending
            }
        }
    }
}
