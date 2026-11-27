//! The size lease (`size-lease-v1`): a connection that lists the capability
//! in `set-client-info` keeps each terminal size it reports only while it
//! refreshes it. Every `resize-surface` (the same size is a refresh and never
//! resizes the terminal) and every sized `attach-surface` renews the lease of
//! that terminal for [`SIZE_LEASE`]; when a lease ends unrenewed the daemon
//! releases the size as `release-surface-size` would. The view stays
//! attached and stops counting, so the grid follows the other views at once
//! (no departed-view hold), and the view's next report claims a size again.
//!
//! A phone refreshes while its terminal is on screen and releases on purpose
//! when it leaves (cmux-next-ios/PROTOCOL.md, "Terminal size claims"). The
//! lease is the safety net for a phone that can no longer say so: a
//! suspended app whose link has not timed out yet, or a bug that never
//! releases. A dead phone can never pin a Mac's grid for longer than the
//! lease: when a connection that left without releasing reaches its lease's
//! end, the departed-view grid hold its departure set ends too (a later
//! departure's hold runs on).
//!
//! One worker thread serves every lease of the daemon. It runs while any
//! lease exists and waits for the earliest deadline; renewals wake it. An
//! expiry and its release happen under the sizing lifecycle lock, and a
//! report renews its lease before its size applies, so an expiry never
//! releases a size reported after it.

use super::*;
use std::collections::HashMap;
use std::sync::Condvar;
use std::sync::Mutex;
use std::sync::PoisonError;
use std::sync::Weak;
use std::time::Duration;
use std::time::Instant;

/// Listed by the daemon in `identify` and by a client in `set-client-info`.
pub const SIZE_LEASE_CAPABILITY: &str = "size-lease-v1";

/// How long a reported size counts without a refresh. A phone refreshes
/// every 15 s, so two missed refreshes still keep it.
const SIZE_LEASE: Duration = Duration::from_secs(45);
/// Debug builds only: the lease in milliseconds, read once.
#[cfg(debug_assertions)]
const SIZE_LEASE_ENV: &str = "CMUX_TUI_TEST_SIZE_LEASE_MS";

fn size_lease() -> Duration {
    #[cfg(debug_assertions)]
    {
        static LEASE: std::sync::OnceLock<Duration> = std::sync::OnceLock::new();
        *LEASE.get_or_init(|| {
            std::env::var(SIZE_LEASE_ENV)
                .ok()
                .and_then(|value| value.parse::<u64>().ok())
                .filter(|ms| *ms > 0)
                .map_or(SIZE_LEASE, Duration::from_millis)
        })
    }
    #[cfg(not(debug_assertions))]
    SIZE_LEASE
}

#[derive(Clone, Copy)]
struct Lease {
    until: Instant,
    /// When its connection left without releasing (the departed-view hold
    /// that departure set ends with the lease).
    left_at: Option<Instant>,
}

#[derive(Default)]
struct LeaseState {
    leases: HashMap<(u64, SurfaceId), Lease>,
    worker: bool,
}

/// Each leased (connection, terminal placement).
#[derive(Default)]
pub(crate) struct SizeLeases {
    state: Mutex<LeaseState>,
    changed: Condvar,
}

/// What an expired lease does.
enum Expired {
    /// The connection is still here: release its size.
    Release(u64, SurfaceId),
    /// It left at this instant: end the hold its departure set.
    EndHold(SurfaceId, Instant),
}

impl SizeLeases {
    fn lock(&self) -> std::sync::MutexGuard<'_, LeaseState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Renews the lease; true when the worker must be started.
    fn renew(&self, client: u64, surface: SurfaceId, until: Instant) -> bool {
        let mut state = self.lock();
        state.leases.insert((client, surface), Lease { until, left_at: None });
        self.changed.notify_all();
        !std::mem::replace(&mut state.worker, true)
    }

    /// Ends the lease without releasing (the client released on purpose).
    pub(super) fn end(&self, client: u64, surface: SurfaceId) {
        self.lock().leases.remove(&(client, surface));
    }

    /// `client` disconnected: its leases now end the holds its departure set.
    pub(super) fn client_left(&self, client: u64) {
        let now = Instant::now();
        let mut state = self.lock();
        for ((owner, _), lease) in state.leases.iter_mut() {
            if *owner == client {
                lease.left_at = Some(now);
            }
        }
    }

    /// Removes and returns the leases that ended by `now`.
    fn take_expired(&self, now: Instant) -> Vec<Expired> {
        let mut state = self.lock();
        let expired = state
            .leases
            .iter()
            .filter(|(_, lease)| lease.until <= now)
            .map(|(key, lease)| (*key, *lease))
            .collect::<Vec<_>>();
        expired
            .into_iter()
            .map(|((client, surface), lease)| {
                state.leases.remove(&(client, surface));
                match lease.left_at {
                    Some(left_at) => Expired::EndHold(surface, left_at),
                    None => Expired::Release(client, surface),
                }
            })
            .collect()
    }

    /// The daemon is gone: no worker runs and no lease is left.
    fn stop_worker(&self) {
        let mut state = self.lock();
        state.leases.clear();
        state.worker = false;
    }

    /// Waits until the earliest lease ends (or a renewal changes it). False
    /// when no lease is left: the worker stops.
    fn wait_for_expiry(&self) -> bool {
        let mut state = self.lock();
        loop {
            let Some(next) = state.leases.values().map(|lease| lease.until).min() else {
                state.worker = false;
                return false;
            };
            let now = Instant::now();
            if next <= now {
                return true;
            }
            state = self
                .changed
                .wait_timeout(state, next - now)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }
}

/// `client` is about to report a size of `surface`: renew its lease, when
/// it opted in.
pub(super) fn renew_size_lease(mux: &Arc<Mux>, client: u64, surface: SurfaceId) {
    if !mux.control_clients.supports_capability(client, SIZE_LEASE_CAPABILITY) {
        return;
    }
    let until = Instant::now() + size_lease();
    if !mux.control_clients.size_leases.renew(client, surface, until) {
        return; // The worker is running and reads the new deadline.
    }
    // The worker holds the leases, never the Mux, while it waits: a daemon
    // that is going away is not kept alive by a lease (as exit_settle's worker).
    let weak = Arc::downgrade(mux);
    let leases = Arc::clone(&mux.control_clients.size_leases);
    let spawned = std::thread::Builder::new()
        .name("terminal-size-lease".into())
        .spawn(move || run_worker(&leases, &weak));
    if spawned.is_err() {
        // No timer can run: no leases (sizes stay until their views leave).
        mux.control_clients.size_leases.stop_worker();
    }
}

fn run_worker(leases: &SizeLeases, mux: &Weak<Mux>) {
    loop {
        // The lease's own bounded wait, on a condition variable that
        // renewals signal; not a synchronization sleep. No Mux reference
        // is held across it.
        if !leases.wait_for_expiry() {
            return;
        }
        let Some(owner) = mux.upgrade() else {
            leases.stop_worker();
            return;
        };
        expire(&owner);
    }
}

fn expire(mux: &Arc<Mux>) {
    let mut holds = Vec::new();
    {
        // Expire and release in one step: a report waits for this lock to
        // apply, and renewed its lease before (renew_size_lease).
        let _lifecycle = mux.lock_client_sizing_lifecycle();
        for expired in mux.control_clients.size_leases.take_expired(Instant::now()) {
            match expired {
                Expired::Release(client, surface) => {
                    if !mux.control_clients.contains(client) {
                        continue;
                    }
                    eprintln!(
                        "cmux-tui: client {client}'s size of surface {surface:?} was not refreshed for {:?}: released",
                        size_lease()
                    );
                    if let Err(error) =
                        cmd_sizing::release_surface_size_locked(mux, client, surface)
                    {
                        eprintln!(
                            "cmux-tui: releasing client {client}'s expired size of {surface:?}: {error:#}"
                        );
                    }
                }
                Expired::EndHold(surface, left_at) => holds.push((surface, left_at)),
            }
        }
    }
    // Takes the lifecycle lock itself.
    for (surface, left_at) in holds {
        mux.end_terminal_grid_hold_of_departure(surface, left_at);
    }
}
