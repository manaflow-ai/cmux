//! How many connections the session daemon admits, on which lane, and to whom
//! (#27698, P-AUSTIN B1).
//!
//! Austin's nightly-next (2026-10-29): about 80 terminal agents held all 64 of
//! the daemon's connections, 55,162 connections were refused in 2.5 hours, and
//! the app's own connections were refused with them. Three rules replace the
//! one shared pool of 64:
//!
//! - **The app has a lane of its own.** The app connects on its own socket
//!   (`<session socket>.app`, `server::app_lane_socket_path`); every other
//!   local client (terminals, agents, hooks, the CLI) connects on the session
//!   socket. Each lane has its own budget, so clients of the session socket
//!   cannot take the app's connections however many they open. This is
//!   Chromium's split: the browser process's own IPC channels never compete
//!   with renderer connections (each renderer gets its own channel from the
//!   browser, `content/browser/renderer_host/render_process_host_impl.cc`).
//! - **A fair share per client on the session socket.** A client is the
//!   process session of the connecting process (`getsid`): a terminal's shell,
//!   the agent in it, its hooks and a `cmux` run in it share one. A client may
//!   take a connection only while it then holds fewer connections than the
//!   lane still has free, so no client takes the last half of what is left:
//!   one terminal opening connection after connection stops at half of the
//!   lane, and every new client still finds room.
//! - **The budget comes from the open-file limit.** The owner raises its soft
//!   `RLIMIT_NOFILE` at start (`cmux_pty::raise_open_file_limit`, to the hard
//!   limit, at most `kern.maxfilesperproc` / `OPEN_MAX` on macOS); the budget
//!   is read after that, from the descriptors left (see
//!   [`ConnectionBudget::from_limits`]).

use std::collections::HashMap;
use std::sync::PoisonError;
use std::sync::atomic::Ordering;

use super::ConnectionStats;

/// Descriptors one admitted connection can hold: the socket, the writer's and
/// the control handle's duplicates (`line_connection`) and the hang-up
/// watcher's (`claim_watched_connection`).
const FDS_PER_CONNECTION: u64 = 4;
/// A connection whose client hung up keeps its descriptors in the hung-up pool
/// (`connection_leases`) while its slot serves the next client: the pool is
/// bounded by the budget, so each slot may stand for two connections.
const CONNECTIONS_PER_SLOT: u64 = 2;
/// Threads one admitted connection runs: its reader and its writer.
const THREADS_PER_CONNECTION: u64 = 2;

/// The connections the daemon admits at once, per lane.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ConnectionBudget {
    app: u64,
    shared: u64,
}

impl ConnectionBudget {
    /// The budget of this process, from its open-file limit now. The owner
    /// raises the limit before it builds its session (`owner_start::prepare`).
    pub fn of_process() -> Self {
        Self::from_limits(soft_open_file_limit(), open_descriptors(), thread_limit())
    }

    /// The budget for `soft` descriptors of which `held` are open, and at most
    /// `threads` threads (`None`: no per-process thread limit).
    ///
    /// Connections may take half of the descriptors left: the other half stays
    /// for what grows with the session (terminal host sockets and their
    /// duplicates, journal and registry files, listeners, the log). Each slot
    /// may stand for two connections (one in the hung-up pool) of
    /// `FDS_PER_CONNECTION` descriptors, so a slot costs eight descriptors. A
    /// thread limit bounds it the same way (two threads per connection, two
    /// connections per slot, half of the threads). The lanes share it equally:
    /// the app's views each have a connection of their own, the agents in
    /// terminals as many as they open. Each lane has at least one slot.
    pub fn from_limits(soft: u64, held: u64, threads: Option<u64>) -> Self {
        let per_slot_fds = FDS_PER_CONNECTION * CONNECTIONS_PER_SLOT;
        let by_fds = soft.saturating_sub(held) / 2 / per_slot_fds;
        let per_slot_threads = THREADS_PER_CONNECTION * CONNECTIONS_PER_SLOT;
        let by_threads = threads.map_or(u64::MAX, |threads| threads / 2 / per_slot_threads);
        let slots = by_fds.min(by_threads);
        let lane = (slots / 2).max(1);
        Self { app: lane, shared: lane }
    }

    /// `per_lane` connections on each lane, for tests that fill a small one.
    pub fn for_test(per_lane: u64) -> Self {
        Self { app: per_lane, shared: per_lane }
    }

    /// Connections admitted at once, both lanes together.
    pub fn total(self) -> u64 {
        self.app + self.shared
    }

    /// Connections admitted at once on `lane`.
    pub fn lane(self, lane: ConnectionLane) -> u64 {
        match lane {
            ConnectionLane::App => self.app,
            ConnectionLane::Shared => self.shared,
        }
    }
}

/// Which socket a connection came in on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ConnectionLane {
    /// The app's own socket (`<session socket>.app`).
    App,
    /// The session socket every other local client uses, and the remote entry
    /// and WebSocket listeners.
    Shared,
}

/// One admitted connection's place: its lane and the client it counts against
/// (`None`: no fair share; the lane's budget still applies).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ConnectionSlot {
    pub lane: ConnectionLane,
    pub identity: Option<u32>,
}

/// What each lane holds now; read and changed under one lock.
#[derive(Default)]
pub(super) struct LaneCounts {
    app: u64,
    shared: u64,
    by_identity: HashMap<u32, u64>,
}

impl LaneCounts {
    fn held(&self, lane: ConnectionLane) -> u64 {
        match lane {
            ConnectionLane::App => self.app,
            ConnectionLane::Shared => self.shared,
        }
    }

    fn held_mut(&mut self, lane: ConnectionLane) -> &mut u64 {
        match lane {
            ConnectionLane::App => &mut self.app,
            ConnectionLane::Shared => &mut self.shared,
        }
    }

    /// Whether `slot` may be admitted under `budget`: its lane has room, and
    /// its client then holds fewer connections than the lane has left free.
    fn admits(&self, budget: ConnectionBudget, slot: ConnectionSlot) -> bool {
        let limit = budget.lane(slot.lane);
        let held = self.held(slot.lane);
        if held >= limit {
            return false;
        }
        let Some(identity) = slot.identity else { return true };
        let mine = self.by_identity.get(&identity).copied().unwrap_or_default();
        mine + 1 < limit - held
    }

    fn take(&mut self, slot: ConnectionSlot) {
        *self.held_mut(slot.lane) += 1;
        if let Some(identity) = slot.identity {
            *self.by_identity.entry(identity).or_default() += 1;
        }
    }

    fn give_back(&mut self, slot: ConnectionSlot) {
        let held = self.held_mut(slot.lane);
        *held = held.saturating_sub(1);
        if let Some(identity) = slot.identity
            && let Some(count) = self.by_identity.get_mut(&identity)
        {
            *count -= 1;
            if *count == 0 {
                self.by_identity.remove(&identity);
            }
        }
    }
}

impl ConnectionStats {
    /// Claims a connection on `lane` for the client `identity` (`None`: no
    /// fair share). At the lane's limit or the client's share it first takes
    /// back the slots of clients that hung up (`reclaim_hung_up`, #27669).
    pub fn try_claim_in(
        &self,
        lane: ConnectionLane,
        identity: Option<u32>,
    ) -> Option<ConnectionSlot> {
        let slot = ConnectionSlot { lane, identity };
        let claimed = self.claim_slot(slot)
            || (self.reclaim_hung_up(self.budget().lane(lane)) > 0 && self.claim_slot(slot));
        if !claimed {
            self.refused.fetch_add(1, Ordering::Relaxed);
            return None;
        }
        let active = self.active.fetch_add(1, Ordering::AcqRel) + 1;
        self.peak.fetch_max(active, Ordering::Relaxed);
        self.accepted.fetch_add(1, Ordering::Relaxed);
        Some(slot)
    }

    fn claim_slot(&self, slot: ConnectionSlot) -> bool {
        let budget = self.budget();
        let mut lanes = self.lanes.lock().unwrap_or_else(PoisonError::into_inner);
        if !lanes.admits(budget, slot) {
            return false;
        }
        lanes.take(slot);
        true
    }

    /// Gives `slot` back: its lane and its client hold one connection less.
    pub fn release_slot(&self, slot: ConnectionSlot) {
        self.lanes.lock().unwrap_or_else(PoisonError::into_inner).give_back(slot);
        self.active.fetch_sub(1, Ordering::AcqRel);
    }

    /// Connections this process admits at once, per lane.
    pub fn budget(&self) -> ConnectionBudget {
        *self.budget.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Replaces the budget (tests that fill a small one).
    pub fn set_budget_for_test(&self, budget: ConnectionBudget) {
        *self.budget.lock().unwrap_or_else(PoisonError::into_inner) = budget;
    }

    /// Connections admitted at once, both lanes together.
    pub fn limit(&self) -> u64 {
        self.budget().total()
    }
}

#[cfg(unix)]
fn soft_open_file_limit() -> u64 {
    let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: `limit` is valid writable storage for one rlimit.
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &raw mut limit) } != 0 {
        // The documented POSIX minimum: a budget that still admits clients.
        return 256;
    }
    limit.rlim_cur
}

#[cfg(not(unix))]
fn soft_open_file_limit() -> u64 {
    // Windows has no per-process descriptor limit like RLIMIT_NOFILE; handles
    // are bounded far higher (16 M per process). The CRT's own default
    // (`_getmaxstdio`, 512) is the closest stable figure.
    512
}

/// Descriptors this process has open now.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn open_descriptors() -> u64 {
    let dir = if cfg!(target_os = "macos") { "/dev/fd" } else { "/proc/self/fd" };
    // The listing's own descriptor is counted too: one too many is safe.
    std::fs::read_dir(dir).map_or(0, |entries| entries.count() as u64)
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn open_descriptors() -> u64 {
    0
}

/// `kern.num_taskthreads`: macOS refuses a thread past it in one process.
#[cfg(target_os = "macos")]
fn thread_limit() -> Option<u64> {
    let mut value: libc::c_int = 0;
    let mut size = size_of::<libc::c_int>();
    // SAFETY: the name is NUL-terminated and `value`/`size` describe valid storage.
    let ok = unsafe {
        libc::sysctlbyname(
            c"kern.num_taskthreads".as_ptr(),
            (&raw mut value).cast(),
            &raw mut size,
            std::ptr::null_mut(),
            0,
        )
    } == 0;
    (ok && value > 0).then_some(value as u64)
}

#[cfg(not(target_os = "macos"))]
fn thread_limit() -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_budget_is_half_the_descriptors_left_at_eight_per_slot() {
        // 4096 soft, 96 open: 4000 left, 2000 for connections, 250 slots.
        let budget = ConnectionBudget::from_limits(4096, 96, None);
        assert_eq!(budget.total(), 250);
        assert_eq!(budget.lane(ConnectionLane::App), 125);
        assert_eq!(budget.lane(ConnectionLane::Shared), 125);
    }

    #[test]
    fn a_thread_limit_bounds_the_budget_too() {
        // macOS's default 8192 threads: half for connections, 4 per slot.
        let budget = ConnectionBudget::from_limits(65_536, 0, Some(8192));
        assert_eq!(budget.total(), 1024);
    }

    #[test]
    fn each_lane_keeps_one_slot_at_any_limit() {
        let budget = ConnectionBudget::from_limits(16, 64, Some(1));
        assert_eq!(budget.lane(ConnectionLane::App), 1);
        assert_eq!(budget.lane(ConnectionLane::Shared), 1);
    }

    #[test]
    fn a_released_slot_serves_its_lane_and_client_again() {
        let stats = ConnectionStats::with_budget(ConnectionBudget::for_test(4));
        let slots: Vec<_> =
            std::iter::from_fn(|| stats.try_claim_in(ConnectionLane::Shared, Some(7)))
                .take(8)
                .collect();
        assert_eq!(slots.len(), 2, "one client takes no more than the lane leaves free");
        stats.release_slot(slots[0]);
        assert!(stats.try_claim_in(ConnectionLane::Shared, Some(7)).is_some());
        assert_eq!(stats.active(), 2);
    }
}
