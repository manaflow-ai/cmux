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
//! lease.

use super::*;
use std::collections::HashMap;
use std::sync::Mutex;
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

/// Each leased (connection, terminal placement) and when its lease ends.
#[derive(Default)]
pub(crate) struct SizeLeases {
    deadlines: Mutex<HashMap<(u64, SurfaceId), Instant>>,
}

impl SizeLeases {
    /// Renews the lease; true when none was running (start its timer).
    fn renew(&self, client: u64, surface: SurfaceId, until: Instant) -> bool {
        self.deadlines
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert((client, surface), until)
            .is_none()
    }

    fn deadline(&self, client: u64, surface: SurfaceId) -> Option<Instant> {
        self.deadlines
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(&(client, surface))
            .copied()
    }

    /// Ends the lease without releasing (the client released, or left).
    pub(super) fn end(&self, client: u64, surface: SurfaceId) {
        self.deadlines
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&(client, surface));
    }

    /// Takes the lease when it ended by `now` (the timer then releases).
    fn take_expired(&self, client: u64, surface: SurfaceId, now: Instant) -> bool {
        let mut deadlines =
            self.deadlines.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        match deadlines.get(&(client, surface)) {
            Some(until) if *until <= now => {
                deadlines.remove(&(client, surface));
                true
            }
            _ => false,
        }
    }
}

/// `client` reported a size of `surface` that was applied: renew its lease,
/// when it opted in.
pub(super) fn renew_size_lease(mux: &Arc<Mux>, client: u64, surface: SurfaceId) {
    if !mux.control_clients.supports_capability(client, SIZE_LEASE_CAPABILITY) {
        return;
    }
    let until = Instant::now() + size_lease();
    if !mux.control_clients.size_leases.renew(client, surface, until) {
        return; // Its timer is running and reads the new deadline.
    }
    let weak = Arc::downgrade(mux);
    let spawned = std::thread::Builder::new().name("terminal-size-lease".into()).spawn(move || {
        // The lease's own bounded wait: sleep to the deadline, read it again
        // (a refresh moves it), release once it passed unrenewed.
        loop {
            let Some(mux) = weak.upgrade() else { return };
            let Some(until) = mux.control_clients.size_leases.deadline(client, surface) else {
                return;
            };
            let now = Instant::now();
            if until > now {
                drop(mux);
                std::thread::sleep(until - now);
                continue;
            }
            if !mux.control_clients.size_leases.take_expired(client, surface, now) {
                continue;
            }
            if !mux.control_clients.contains(client) {
                return;
            }
            eprintln!(
                "cmux-tui: client {client}'s size of surface {surface:?} was not refreshed for {:?}: released",
                size_lease()
            );
            if let Err(error) = cmd_sizing::release_surface_size(&mux, client, surface) {
                eprintln!("cmux-tui: releasing client {client}'s expired size of {surface:?}: {error:#}");
            }
            return;
        }
    });
    if spawned.is_err() {
        // No timer can run: no lease (the size stays until the view leaves).
        mux.control_clients.size_leases.end(client, surface);
    }
}
