//! Kitty graphics budget state: process budget constants, per-surface capacity math, budget entries and pending operations, surface reservations, and render attachment permits.

use super::*;

pub(super) const KITTY_IMAGE_BUDGET_RETRY_INITIAL: Duration = Duration::from_millis(25);

pub(super) const KITTY_IMAGE_BUDGET_RETRY_MAX: Duration = Duration::from_secs(1);

pub(super) const KITTY_IMAGE_BUDGET_RETRY_MAX_ATTEMPTS: u32 = 4;

pub(crate) const RENDER_ATTACHMENT_LIMIT: usize = 64;

pub(super) const KITTY_IMAGE_PROCESS_BUDGET_BYTES: u64 = 128 * 1024 * 1024;

// libghostty owns independent primary and alternate screen stores. cmux also
// keeps one replay pixel cache and one render pixel cache per PTY surface.
// A grayscale native image expands by up to 3x in either RGB pixel cache.
pub(super) const KITTY_IMAGE_PERSISTENT_COPIES_PER_SURFACE: u64 = 2 + 3 + 3;

// Image and placement limits are independent on the primary and alternate screens.
pub(super) const KITTY_OBJECT_OWNERS_PER_SURFACE: u64 = 2;

pub(super) const KITTY_IMAGE_PROCESS_BUDGET_COUNT: u64 = ghostty_vt::MAX_KITTY_IMAGES;

pub(super) const KITTY_PLACEMENT_PROCESS_BUDGET_COUNT: u64 = ghostty_vt::MAX_KITTY_PLACEMENTS;

pub(super) const KITTY_IMAGE_BUDGET_OWNER_LIMIT: usize = {
    let image_limit = KITTY_IMAGE_PROCESS_BUDGET_COUNT / KITTY_OBJECT_OWNERS_PER_SURFACE;
    let placement_limit = KITTY_PLACEMENT_PROCESS_BUDGET_COUNT / KITTY_OBJECT_OWNERS_PER_SURFACE;
    if image_limit < placement_limit { image_limit as usize } else { placement_limit as usize }
};

pub(super) fn kitty_image_budget_capacity(surface_count: usize, current: usize) -> usize {
    if surface_count == 0 {
        return 0;
    }
    // Keep hysteresis for larger buckets, but always restore the sole
    // survivor's full share instead of stranding it in the two-surface bucket.
    if current == 0
        || surface_count > current
        || surface_count <= current / 4
        || (surface_count == 1 && current > 1)
    {
        return surface_count.checked_next_power_of_two().unwrap_or(usize::MAX);
    }
    current
}

pub(super) fn kitty_surface_byte_reservation(image_bytes: u64) -> u64 {
    image_bytes
        .saturating_mul(KITTY_IMAGE_PERSISTENT_COPIES_PER_SURFACE)
        .saturating_add(ghostty_vt::kitty_inflight_replay_limit_for_image_bytes(image_bytes))
}

pub(super) fn kitty_image_bytes_for_process_share(process_share: u64) -> u64 {
    let mut lower = 0;
    let mut upper = process_share.min(ghostty_vt::MAX_KITTY_IMAGE_BYTES as u64);
    while lower < upper {
        let candidate = lower + (upper - lower).div_ceil(2);
        if kitty_surface_byte_reservation(candidate) <= process_share {
            lower = candidate;
        } else {
            upper = candidate - 1;
        }
    }
    lower
}

pub(super) fn kitty_image_limits_for_capacity(capacity: usize) -> KittyGraphicsLimits {
    if capacity == 0 {
        return KittyGraphicsLimits::disabled();
    }
    let surface_count = u64::try_from(capacity).unwrap_or(u64::MAX);
    let process_share = KITTY_IMAGE_PROCESS_BUDGET_BYTES.checked_div(surface_count).unwrap_or(0);
    let image_bytes = kitty_image_bytes_for_process_share(process_share);
    let inflight_bytes = ghostty_vt::kitty_inflight_replay_limit_for_image_bytes(image_bytes);
    let object_owners = surface_count.saturating_mul(KITTY_OBJECT_OWNERS_PER_SURFACE);
    let images = KITTY_IMAGE_PROCESS_BUDGET_COUNT
        .checked_div(object_owners)
        .unwrap_or(0)
        .min(ghostty_vt::MAX_KITTY_IMAGES);
    let placements = KITTY_PLACEMENT_PROCESS_BUDGET_COUNT
        .checked_div(object_owners)
        .unwrap_or(0)
        .min(ghostty_vt::MAX_KITTY_PLACEMENTS);
    KittyGraphicsLimits { image_bytes, inflight_bytes, images, placements }
}

#[derive(Clone)]
pub(super) struct KittyImageBudgetEntry {
    pub(super) surface: Option<Weak<Surface>>,
    pub(super) applied: KittyGraphicsLimits,
    pub(super) owns_quota: bool,
    pub(super) removing: bool,
}

#[derive(Default)]
pub(super) struct KittyImageBudgetState {
    pub(super) entries: HashMap<SurfaceId, KittyImageBudgetEntry>,
    pub(super) blocked_surfaces: HashSet<SurfaceId>,
    pub(super) capacity: usize,
    pub(super) worker_running: bool,
    pub(super) expansion_in_flight: bool,
}

pub(super) struct PendingKittyImageBudgetOperation {
    pub(super) surface_id: SurfaceId,
    pub(super) surface: Weak<Surface>,
    pub(super) limits: KittyGraphicsLimits,
    pub(super) expanding: bool,
    pub(super) result: DeadlinePending<anyhow::Result<()>>,
}

pub(crate) struct KittyImageBudgetReservation {
    pub(super) mux: Weak<Mux>,
    pub(super) surface: SurfaceId,
    pub(super) initial_limits: KittyGraphicsLimits,
    pub(super) committed: bool,
}

impl KittyImageBudgetReservation {
    pub(crate) fn initial_limits(&self) -> KittyGraphicsLimits {
        self.initial_limits
    }

    pub(crate) fn commit(
        mut self,
        surface: &Arc<Surface>,
        applied: KittyGraphicsLimits,
    ) -> anyhow::Result<()> {
        if let Some(mux) = self.mux.upgrade() {
            mux.commit_kitty_image_surface(self.surface, surface, applied)?;
        }
        self.committed = true;
        Ok(())
    }
}

impl Drop for KittyImageBudgetReservation {
    fn drop(&mut self) {
        if self.committed {
            return;
        }
        if let Some(mux) = self.mux.upgrade() {
            mux.cancel_kitty_image_surface_reservation(self.surface);
        }
    }
}

pub(crate) struct RenderAttachmentPermit {
    pub(super) active: Arc<AtomicUsize>,
}

impl Drop for RenderAttachmentPermit {
    fn drop(&mut self) {
        self.active.fetch_sub(1, Ordering::AcqRel);
    }
}
