//! A lane of connections from the session's terminals, with a fair share
//! for each terminal.
//!
//! `ConnectionStats` has two: the lane of the short connections (#27698,
//! #28343) and the lane of the long ones (`long_connections`).

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, PoisonError};

#[derive(Default)]
pub(super) struct TerminalLane {
    active: AtomicU64,
    /// Of `active`, the connections each terminal holds (by its process
    /// session). A terminal with none is not listed.
    clients: Mutex<HashMap<u32, u64>>,
}

impl TerminalLane {
    /// One place under `limit`, within `client`'s fair share.
    ///
    /// `client`: the terminal the connection comes from (its process session).
    /// A terminal's first connection gets in whenever the lane has room; a
    /// further one only while that terminal then holds no more than the lane
    /// has left free. One terminal (an agent's hooks in a loop, a script
    /// running `cmux`) stops at half the lane, so a second terminal still finds
    /// room; several terminals in a loop together can still fill the lane. A
    /// connection whose terminal is unknown is bounded by the lane alone.
    ///
    /// The share and the count change together under `clients`, so two claims
    /// never both take the last place a share allows.
    pub(super) fn claim(&self, limit: u64, client: Option<u32>) -> bool {
        let mut clients = self.clients.lock().unwrap_or_else(PoisonError::into_inner);
        let active = self.active.load(Ordering::Acquire);
        if active >= limit {
            return false;
        }
        if let Some(client) = client {
            let held = clients.get(&client).copied().unwrap_or(0);
            let free_after = limit.saturating_sub(active.saturating_add(1));
            if held > 0 && held.saturating_add(1) > free_after {
                return false;
            }
        }
        self.count(&mut clients, client);
        true
    }

    /// One place for a connection that is open already: the daemon admitted
    /// it before it knew its terminal (`ConnectionLease::join_terminal`). No
    /// limit and no share apply, because nothing can be refused now: the
    /// connection holds its thread and its socket. The count says what is
    /// true, and each later `claim` sees it.
    pub(super) fn enter(&self, client: Option<u32>) {
        let mut clients = self.clients.lock().unwrap_or_else(PoisonError::into_inner);
        self.count(&mut clients, client);
    }

    fn count(&self, clients: &mut HashMap<u32, u64>, client: Option<u32>) {
        if let Some(client) = client {
            let held = clients.entry(client).or_insert(0);
            *held = held.saturating_add(1);
        }
        self.active.fetch_add(1, Ordering::AcqRel);
    }

    pub(super) fn release(&self, client: Option<u32>) {
        if let Some(client) = client {
            let mut clients = self.clients.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(held) = clients.get_mut(&client) {
                *held = held.saturating_sub(1);
                if *held == 0 {
                    clients.remove(&client);
                }
            }
        }
        self.active.fetch_sub(1, Ordering::AcqRel);
    }

    pub(super) fn active(&self) -> u64 {
        self.active.load(Ordering::Acquire)
    }
}
