//! Surface sync claims: attach and resize claims with their failure backoff,
//! the resize decision, and the sidebar plugin sync claim. Each claim releases
//! its slot when dropped.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_tui_core::SurfaceId;

use crate::session::{Session, SidebarPluginSurface, SurfaceHandle};

pub(super) struct RemoteRefreshClaim(pub(super) Arc<AtomicBool>);

impl Drop for RemoteRefreshClaim {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

pub(super) struct SurfaceResizeClaim {
    pub(super) claims: Arc<Mutex<HashMap<SurfaceId, SurfaceResizeClaimState>>>,
    pub(super) surface: SurfaceId,
    pub(super) token: u64,
}

pub(super) struct SurfaceAttachClaim {
    pub(super) claims: Arc<Mutex<HashMap<SurfaceId, SurfaceAttachClaimState>>>,
    pub(super) surface: SurfaceId,
    pub(super) active: bool,
}

impl SurfaceAttachClaim {
    pub(super) fn snapshot(&self) -> Option<SurfaceAttachClaimState> {
        self.claims.lock().unwrap().get(&self.surface).copied()
    }

    pub(super) fn complete_if_revision(&mut self, revision: u64) -> bool {
        let mut claims = self.claims.lock().unwrap();
        if claims.get(&self.surface).is_none_or(|claim| claim.revision != revision) {
            return false;
        }
        claims.remove(&self.surface);
        self.active = false;
        true
    }
}

impl Drop for SurfaceAttachClaim {
    fn drop(&mut self) {
        if self.active {
            self.claims.lock().unwrap().remove(&self.surface);
        }
    }
}

#[derive(Clone, Copy, Default)]
pub(super) struct SurfaceAttachClaimState {
    pub(super) retired: bool,
    pub(super) requested_size: Option<(u16, u16)>,
    pub(super) revision: u64,
}

#[cfg(test)]
pub(super) type SurfaceAttachAfterObsoleteCheckHook =
    Arc<Mutex<Option<Arc<dyn Fn() + Send + Sync>>>>;

#[derive(Clone, Copy)]
pub(super) struct SurfaceResizeClaimState {
    pub(super) desired: (u16, u16),
    pub(super) token: u64,
}

#[derive(Clone, Copy)]
pub(super) struct SurfaceSyncFailureState {
    pub(super) attempts: u8,
    pub(super) retry_after: Option<Instant>,
    pub(super) sticky_until_reconnect: bool,
}

#[derive(Clone, Copy)]
pub(super) struct SurfaceResizeFailure {
    pub(super) desired: (u16, u16),
    pub(super) state: SurfaceSyncFailureState,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct SurfaceResizeOwnership {
    pub(super) desired: (u16, u16),
    pub(super) reservation_id: Option<u64>,
}

pub(super) fn next_surface_sync_failure(
    previous: Option<SurfaceSyncFailureState>,
    transient: bool,
    sticky_until_reconnect: bool,
) -> SurfaceSyncFailureState {
    if !transient {
        return SurfaceSyncFailureState { attempts: 0, retry_after: None, sticky_until_reconnect };
    }
    let attempts = previous.map_or(1, |state| state.attempts.saturating_add(1)).min(6);
    let delay_seconds = 1_u64 << u32::from(attempts.saturating_sub(1));
    SurfaceSyncFailureState {
        attempts,
        retry_after: (attempts < 6)
            .then(|| Instant::now() + Duration::from_secs(delay_seconds.min(30))),
        sticky_until_reconnect: sticky_until_reconnect || attempts >= 6,
    }
}

pub(super) fn surface_sync_failure_blocks(state: SurfaceSyncFailureState) -> bool {
    state.retry_after.is_none_or(|retry_after| Instant::now() < retry_after)
}

pub(super) struct SurfaceAttachResult {
    pub(super) outcome: SurfaceAttachOutcome,
    pub(super) surface: Option<SurfaceHandle>,
    pub(super) requested_size: Option<(u16, u16)>,
}

pub(super) enum SurfaceAttachOutcome {
    Attached,
    Retired { surface: SurfaceId },
    Deferred,
    Failed { surface: SurfaceId, operation: &'static str, error: String, reconnect_required: bool },
}

/// An attach request starts from an authoritative tree snapshot. If the
/// server no longer recognizes that exact surface, its lifecycle advanced
/// past the snapshot while the request was in flight. Retire both mirror
/// layers and refresh topology instead of turning normal teardown into a
/// retryable synchronization failure.
pub(super) fn retire_missing_surface_attach(
    session: &Session,
    retired_surfaces: &Mutex<HashSet<SurfaceId>>,
    attach_claims: &Mutex<HashMap<SurfaceId, SurfaceAttachClaimState>>,
    attach_failures: &Mutex<HashMap<SurfaceId, SurfaceSyncFailureState>>,
    id: SurfaceId,
) {
    {
        retired_surfaces.lock().unwrap().insert(id);
        if let Some(claim) = attach_claims.lock().unwrap().get_mut(&id) {
            claim.retired = true;
        }
    }
    attach_failures.lock().unwrap().remove(&id);
    session.forget_surface(id);
    session.invalidate_remote_tree();
}

pub(super) enum SurfaceResizeDecision {
    Noop,
    AlreadyClaimed,
    Failed,
    NeedsQueue(SurfaceResizeClaim),
}

#[derive(Default)]
pub(super) struct SidebarPluginSyncState {
    pub(super) epoch: u64,
    pub(super) claimed: Option<((u16, u16), u64, u64)>,
    pub(super) applied: Option<((u16, u16), u64, u64)>,
}

pub(super) struct SidebarPluginSyncClaim {
    pub(super) state: Arc<Mutex<SidebarPluginSyncState>>,
    pub(super) desired: ((u16, u16), u64, u64),
    pub(super) applied: bool,
}

pub(super) fn sidebar_plugin_status_settles_passive_claim(status: &SidebarPluginSurface) -> bool {
    (status.surface_id.is_some() && status.error.is_none()) || status.retry_after_ms.is_none()
}

impl SidebarPluginSyncClaim {
    pub(super) fn mark_applied(&mut self) {
        let mut state = self.state.lock().unwrap();
        if state.epoch != self.desired.2 {
            self.applied = true;
            return;
        }
        state.applied = Some(self.desired);
        if state.claimed == Some(self.desired) {
            state.claimed = None;
        }
        self.applied = true;
    }
}

impl Drop for SidebarPluginSyncClaim {
    fn drop(&mut self) {
        if self.applied {
            return;
        }
        let mut state = self.state.lock().unwrap();
        if state.claimed == Some(self.desired) {
            state.claimed = None;
        }
    }
}

impl Drop for SurfaceResizeClaim {
    fn drop(&mut self) {
        let mut claims = self.claims.lock().unwrap();
        if claims.get(&self.surface).is_some_and(|claim| claim.token == self.token) {
            claims.remove(&self.surface);
        }
    }
}

pub(super) fn record_surface_resize_dispatch_result(
    ownership: &Mutex<HashMap<SurfaceId, SurfaceResizeOwnership>>,
    surface: SurfaceId,
    desired: (u16, u16),
    reservation_id: Option<u64>,
) {
    if let Some(reservation_id) = reservation_id {
        ownership.lock().unwrap().insert(
            surface,
            SurfaceResizeOwnership { desired, reservation_id: Some(reservation_id) },
        );
    }
}
