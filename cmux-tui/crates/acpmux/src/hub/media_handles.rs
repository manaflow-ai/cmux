//! One connection's open media files (`hub/media_read.rs`): the descriptors that
//! `_acpmux/media_open` opened, by a random handle, until `_acpmux/media_range` reads them.
//!
//! - A handle belongs to the session it was opened for, the very one: the table keeps a weak
//!   reference to that session, so a handle of a chat that was replaced or purged since, even
//!   one with the same ID, is refused (`media.handle`).
//! - A table holds at most [`MAX_HANDLES`], and the daemon at most [`MAX_OPEN`] over all its
//!   connections (`media.handles`, `media.busy`). A peer daemon's link carries the reads of all
//!   that daemon's clients, which it caps one by one (`server/media_forward.rs`), so its table
//!   is capped only by [`MAX_OPEN`] ([`Handles::for_peer_link`]).
//! - A handle whose session is gone counts toward no cap: the insert and the sweeper drop it, and
//!   [`Handles::forget_orphan`] closes one named by a range for a chat that no longer resolves.
//! - A handle unused for [`IDLE`] is closed by the table's sweeper: one task per table, spawned
//!   by the insert that finds none, sleeping until the earliest handle's deadline. It stops when
//!   the table is empty, when the table is dropped, or at [`Handles::close_all`], which aborts it.
//! - [`Handles::close_all`] runs when the connection ends. It closes every handle and the table:
//!   an open still running then (its task outlives the connection) is refused and its file
//!   closed (`media.closed`).

use super::media_read::{Identity, Opened, refused};
use crate::rpc::RpcError;
use std::collections::HashMap;
use std::fs::File;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};
use std::time::Duration;
use tokio::task::AbortHandle;
use tokio::time::Instant;

/// The most files one connection holds open.
pub const MAX_HANDLES: usize = 8;
/// The most media files the daemon holds open over all its connections.
pub const MAX_OPEN: usize = 256;
/// A handle unused this long is closed.
pub const IDLE: Duration = Duration::from_secs(120);

static OPEN: AtomicUsize = AtomicUsize::new(0);

/// One of the daemon's [`MAX_OPEN`] places, given back when the handle closes.
struct Slot;

impl Slot {
    fn take() -> Option<Slot> {
        let next = |n: usize| (n < MAX_OPEN).then_some(n + 1);
        OPEN.fetch_update(Ordering::SeqCst, Ordering::SeqCst, next).ok().map(|_| Slot)
    }
}

impl Drop for Slot {
    fn drop(&mut self) {
        OPEN.fetch_sub(1, Ordering::SeqCst);
    }
}

struct Entry<O> {
    owner: Weak<O>,
    file: Arc<File>,
    identity: Identity,
    used: Instant,
    _slot: Slot,
}

struct State<O> {
    entries: HashMap<String, Entry<O>>,
    cap: usize,
    sweeper: Option<AbortHandle>,
    closed: bool,
}

/// One connection's open media files (module docs). `O` is the owner a handle is bound to: the
/// hub's session, or a stand-in in the tests.
pub struct Handles<O = super::Session> {
    state: Arc<Mutex<State<O>>>,
}

impl<O> Default for Handles<O> {
    fn default() -> Self {
        let state =
            State { entries: HashMap::new(), cap: MAX_HANDLES, sweeper: None, closed: false };
        Handles { state: Arc::new(Mutex::new(state)) }
    }
}

impl<O> Handles<O> {
    /// The table of a peer daemon's link: capped by the daemon's [`MAX_OPEN`] alone.
    pub fn for_peer_link() -> Self {
        let handles = Self::default();
        lock(&handles.state).cap = MAX_OPEN;
        handles
    }
}

fn lock<O>(state: &Mutex<State<O>>) -> MutexGuard<'_, State<O>> {
    state.lock().unwrap_or_else(PoisonError::into_inner)
}

fn no_handle() -> RpcError {
    refused("media.handle", "no such media handle on this connection; open the file again")
}

impl<O: Send + Sync + 'static> Handles<O> {
    /// Keeps `opened` for `owner` and answers its handle. Runs on a Tokio runtime: the first
    /// handle starts the sweeper.
    pub fn insert(&self, owner: &Arc<O>, opened: Opened) -> Result<String, RpcError> {
        let mut raw = [0u8; 16];
        getrandom::fill(&mut raw).map_err(|e| RpcError::internal(format!("no handle: {e}")))?;
        let handle: String = raw.iter().map(|b| format!("{b:02x}")).collect();
        let mut state = lock(&self.state);
        if state.closed {
            return Err(refused("media.closed", "the connection that opened the file has ended"));
        }
        state.entries.retain(|_, entry| entry.owner.strong_count() > 0);
        if state.entries.len() >= state.cap {
            let message = "too many media files are open; read one to its end";
            return Err(refused("media.handles", message));
        }
        let slot = Slot::take().ok_or_else(|| {
            refused("media.busy", "the daemon has too many media files open; try again soon")
        })?;
        let Opened { file, identity, .. } = opened;
        let entry = Entry {
            owner: Arc::downgrade(owner),
            file: Arc::new(file),
            identity,
            used: Instant::now(),
            _slot: slot,
        };
        state.entries.insert(handle.clone(), entry);
        if state.sweeper.is_none() {
            let task = tokio::spawn(sweep(Arc::downgrade(&self.state)));
            state.sweeper = Some(task.abort_handle());
        }
        Ok(handle)
    }

    /// The file behind `handle`, if `owner` opened it.
    pub fn get(&self, owner: &Arc<O>, handle: &str) -> Result<(Arc<File>, Identity), RpcError> {
        let mut state = lock(&self.state);
        let entry = state.entries.get_mut(handle).ok_or_else(no_handle)?;
        if entry.owner.upgrade().is_none()
            || !std::ptr::eq(entry.owner.as_ptr(), Arc::as_ptr(owner))
        {
            return Err(no_handle());
        }
        entry.used = Instant::now();
        Ok((entry.file.clone(), entry.identity))
    }

    /// Closes `handle` if `owner` opened it.
    pub fn close(&self, owner: &Arc<O>, handle: &str) {
        let mut state = lock(&self.state);
        let mine = state
            .entries
            .get(handle)
            .is_some_and(|entry| std::ptr::eq(entry.owner.as_ptr(), Arc::as_ptr(owner)));
        if mine {
            state.entries.remove(handle);
        }
    }

    /// Closes `handle` when the chat that opened it no longer exists, so nothing reads it again;
    /// a live chat's handle stays.
    pub fn forget_orphan(&self, handle: &str) {
        let mut state = lock(&self.state);
        if state.entries.get(handle).is_some_and(|entry| entry.owner.strong_count() == 0) {
            state.entries.remove(handle);
        }
    }

    /// The connection ended: every handle closes, the sweeper stops, and no handle opens again.
    pub fn close_all(&self) {
        let mut state = lock(&self.state);
        state.closed = true;
        state.entries.clear();
        if let Some(sweeper) = state.sweeper.take() {
            sweeper.abort();
        }
    }
}

impl<O> Drop for Handles<O> {
    fn drop(&mut self) {
        if let Some(sweeper) = lock(&self.state).sweeper.take() {
            sweeper.abort();
        }
    }
}

/// The sweeper (module docs): closes the handles unused for [`IDLE`], then sleeps until the next
/// deadline, and ends when the table is empty or gone.
async fn sweep<O>(state: Weak<Mutex<State<O>>>) {
    loop {
        let deadline = {
            let Some(state) = state.upgrade() else { return };
            let mut state = lock(&state);
            let now = Instant::now();
            state.entries.retain(|_, entry| {
                entry.owner.strong_count() > 0 && now.saturating_duration_since(entry.used) < IDLE
            });
            let Some(used) = state.entries.values().map(|entry| entry.used).min() else {
                state.sweeper = None;
                return;
            };
            used + IDLE
        };
        tokio::time::sleep_until(deadline).await;
    }
}

#[cfg(all(test, unix))]
#[path = "media_handles_tests.rs"]
mod tests;
