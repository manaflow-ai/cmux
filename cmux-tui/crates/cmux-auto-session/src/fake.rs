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
//! The rules are the real store's (the Cloud API's `auto-sessions`), file for file: `rules.rs`
//! is its `lease.ts`, `record.rs` its `model.ts`, `check.rs` its field checks, and the routes
//! check what its routes check, in their order. In short:
//!
//! - Every holder write names a holder and an epoch. It is refused `auto.closed` once Auto is
//!   off, `auto.not_holder` when the caller cannot be that holder or the holder is another,
//!   and `auto.stale_epoch` when the epoch is not the chat's. A refusal about a chat carries
//!   the chat as it is. A machine reads only a chat it holds (any other is 404); its write to
//!   a chat it held last is `auto.stale_epoch`.
//! - A renewal is answered a role, never `auto.stale_epoch`: `holder` (go on at the answer's
//!   epoch; to a standby's renewal, import first), `standby`, or `lost` (stop, then renew as
//!   standby).
//! - A laptop's lease lasts 45 s from its last renewal. When it runs out, a chat with work
//!   (`needsRun`, or an unacked message) goes to the Auto machine with a `takeover`
//!   assignment and a machine start; an idle one is parked. With no Auto machine the work
//!   waits, parked and blocked `no_machine`, until one is set. The epoch grows by one at
//!   every change of holder and never otherwise.
//! - A parked chat: the laptop whose lease ran out takes it back as it is with a renewal that
//!   names the epoch it held. Any laptop takes it with a standby's renewal, unless it is kept
//!   in the Cloud.
//! - A machine's chat goes home at the machine's own renewal: `needsRun: false`, the inbox and
//!   the assignment acked, the newest snapshot covering the last event, a laptop standing by
//!   and the chat not kept in the Cloud. The machine is answered `lost`. A machine that said
//!   all that and then stopped renewing loses the chat to a standby at the standby's renewal.
//! - `release` gives a machine's chat to its standby laptop. Otherwise the chat is parked,
//!   unless a message is unread: then it goes to the Auto machine, or stays with the Auto
//!   machine that released it, with a `deliver` to pick up.
//! - Events append in order from seq 1. A repeat of stored seqs is skipped; a hole is
//!   `auto.seq_gap` with the store's last seq.
//! - A chunk must hash to its name (`auto.chunk_mismatch`) and be at most 1 MiB. A manifest is
//!   accepted only when every chunk it names is stored (`auto.snapshot_incomplete` names the
//!   rest) and their bytes are under the chat's limit (`auto.too_large`). It covers the chat
//!   only through the events the store has.
//! - A message's id is taken once, and a repeat is answered what the first was. A laptop that
//!   holds the chat reads it (`delivered`); a parked chat goes to the Auto machine
//!   (`resuming`) or waits for one (`queued`); a machine that runs the chat gets a `deliver`
//!   assignment unless one already waits for it.
//! - An assignment stays until the machine acks it, and an ack with a message still unread
//!   leaves a `deliver`.
//! - Turning Auto off closes the chat and drops its copy. It is refused `auto.held_in_cloud`
//!   while the Cloud has what no laptop has.
//!
//! `wait` and `assignments` are held requests: they answer when there is something to answer
//! or when the store's clock reaches their deadline, so a test releases one by changing the
//! chat or by moving the clock.
//!
//! What the fake leaves out: how a machine is started (it only records that a start was asked
//! for, in [`FakeAutoCloud::machine_starts`]), whether the owner may use a team's machines,
//! the rate limit on new chats, and every failure of the store itself. Its list and its
//! assignments are always current, where the real store's follow a chat's change a moment
//! later.

mod check;
mod copy;
mod devices;
mod inbox;
mod lease;
mod owner;
mod record;
mod routes;
mod rules;
mod store;

#[cfg(test)]
mod tests;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::task::{Context, Poll};

use devices::Install;
use store::{Caller, Store};

use crate::cloud::{AutoCloudError, CloudResult};
use crate::consts::WAIT_MAX_MS;
use crate::wire::SessionView;

/// One caller's handle on an in-memory Cloud store.
#[derive(Clone, Debug)]
pub struct FakeAutoCloud {
    store: Arc<Mutex<Store>>,
    caller: Caller,
    /// The owner's install it calls as: a laptop's holds chats, a phone's does not.
    install: Install,
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
            install: Install::Laptop("install_1".to_owned()),
            offline: Arc::new(AtomicBool::new(false)),
        }
    }

    /// The same store, called as the owner, with a network of its own (a second laptop).
    pub fn as_owner(&self) -> FakeAutoCloud {
        self.as_caller(Caller::Owner, self.install.clone())
    }

    /// The same store, called by another install of the owner's that holds chats (a second
    /// laptop), `install` its install id.
    pub fn as_install(&self, install: &str) -> FakeAutoCloud {
        self.as_caller(Caller::Owner, Install::Laptop(install.to_owned()))
    }

    /// The same store, called by an install of the owner's that never holds a chat: a phone or
    /// a browser session.
    pub fn as_phone(&self) -> FakeAutoCloud {
        self.as_caller(Caller::Owner, Install::Phone)
    }

    /// The same store, called as the VM install of `machine`, one of the owner's Cloud
    /// machines (the Auto machine or another). Its holder is `vm:<machine>`, and it reaches
    /// only the chats that machine holds.
    pub fn as_machine(&self, machine: &str) -> FakeAutoCloud {
        self.as_caller(Caller::Machine(machine.to_owned()), self.install.clone())
    }

    fn as_caller(&self, caller: Caller, install: Install) -> FakeAutoCloud {
        FakeAutoCloud {
            store: Arc::clone(&self.store),
            caller,
            install,
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

    /// A chat's size limit; the real store's is 512 MiB. It bounds three things apart: the
    /// chunks one snapshot names, the chunks waiting for their snapshot, and the chat's events.
    pub fn set_snapshot_max(&self, bytes: u64) {
        self.lock().chat_max = bytes;
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
        store.view(id)
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

    /// One holder write: refused when this handle's install may not write as `holder`
    /// (devices.rs), before the route's own checks run. `making`: the PUT that may make the chat.
    fn holder_call<T>(
        &self,
        route: &'static str,
        id: &str,
        holder: &crate::wire::Holder,
        making: bool,
        run: impl FnOnce(&mut Store, &Caller) -> CloudResult<T>,
    ) -> CloudResult<T> {
        self.call(route, |store, caller| {
            store.claim(caller, &self.install, id, holder, making)?;
            run(store, caller)
        })
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
