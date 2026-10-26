//! The process Kitty byte total and how terminals share it (p07-memory-073,
//! plans/cmux-next/chrome-parity/p07-memory.md).
//!
//! A terminal may store `MAX_KITTY_IMAGE_BYTES` of images, and the daemon
//! keeps them up to `KITTY_IMAGE_PERSISTENT_COPIES_PER_SURFACE` times (both
//! screens' stores and both decoded pixel maps). Each pixel map keeps only the
//! current image generations, so the unbounded axis is the number of
//! terminals; one process total bounds them all.
//!
//! With [`FEATURE`] off the total is `DaemonBudget`'s 16 GB row (128 MiB),
//! split equally over a power-of-two owner count, as before. With it on the
//! total is `DaemonBudget::kitty_total` for this machine's RAM, shared the way
//! Chromium's GPU memory manager shared its budget
//! (content/common/gpu/gpu_memory_manager.cc, `AssignSurfacesAllocations` and
//! `clients_nonvisible_mru_`): visible clients first, then hidden ones in most
//! recently used order until the budget runs out. Here every owner keeps a
//! floor; terminals a client views split what is left equally, up to the
//! per-terminal maximum; the rest goes to hidden terminals, the most recently
//! shown first. Over the total, the least recently shown lose their storage
//! first, and a viewed terminal never drops below the equal share it had
//! before this feature, so its visible placements still render.

use std::cmp::Reverse;

use cmux_memory::DaemonBudget;

use super::kitty_budget_state::{
    kitty_image_bytes_for_process_share, kitty_surface_byte_reservation,
};
use super::*;

/// The daemon feature that sizes the total from RAM and shares it by recency.
pub(crate) const FEATURE: &str = "memoryKittyShare";

/// The registry name of the pixel maps' memory consumer.
pub(crate) const PIXEL_CONSUMER_NAME: &str = "terminal.kitty-pixels";

/// A hidden owner's floor is this fraction of an equal share: what a terminal
/// uploading while nobody views it may keep.
const HIDDEN_FLOOR_DIVISOR: u64 = 4;

/// The process Kitty byte total and how it is shared.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct KittyShare {
    /// Kitty bytes across all terminals: native storage on both screens, both
    /// pixel maps and in-flight uploads.
    pub(super) total_bytes: u64,
    /// Share by viewers and recency ([`FEATURE`]) instead of equally.
    pub(super) by_recency: bool,
}

impl KittyShare {
    /// The share [`FEATURE`] selects; with it on, this machine's RAM is read
    /// once.
    pub(crate) fn for_feature(enabled: bool) -> Self {
        if enabled {
            Self::by_recency(DaemonBudget::for_host().kitty_total)
        } else {
            Self::default()
        }
    }

    /// Recency sharing of `total_bytes`.
    pub(crate) fn by_recency(total_bytes: u64) -> Self {
        Self { total_bytes, by_recency: true }
    }
}

impl Default for KittyShare {
    /// Equal shares of the 16 GB row: the daemon's fixed total before.
    fn default() -> Self {
        Self { total_bytes: DaemonBudget::default().kitty_total, by_recency: false }
    }
}

/// One quota owner as the recency share sees it.
#[derive(Clone, Copy, Debug)]
pub(super) struct KittyShareOwner {
    pub(super) id: SurfaceId,
    pub(super) viewed: bool,
    pub(super) shown_at: u64,
}

/// Reserved bytes per owner, out of `total_bytes` over `capacity` slots
/// (at least one per owner). The sum never exceeds `total_bytes`.
pub(super) fn kitty_recency_shares(
    total_bytes: u64,
    capacity: usize,
    owners: &[KittyShareOwner],
) -> Vec<(SurfaceId, u64)> {
    if owners.is_empty() {
        return Vec::new();
    }
    let slots = u64::try_from(capacity.max(owners.len())).unwrap_or(u64::MAX);
    let owner_count = u64::try_from(owners.len()).unwrap_or(u64::MAX);
    let full = kitty_surface_byte_reservation(ghostty_vt::MAX_KITTY_IMAGE_BYTES as u64);
    let equal = (total_bytes / slots).min(full);
    let hidden_floor = equal / HIDDEN_FLOOR_DIVISOR;

    let mut ranked = owners.to_vec();
    ranked.sort_unstable_by_key(|owner| (Reverse(owner.viewed), Reverse(owner.shown_at), owner.id));
    let viewed = ranked.iter().take_while(|owner| owner.viewed).count();
    let mut shares = ranked
        .iter()
        .map(|owner| (owner.id, if owner.viewed { equal } else { hidden_floor }))
        .collect::<Vec<_>>();
    // A free slot keeps a hidden floor, so a new terminal starts without
    // pushing any owner below its own floor.
    let committed = shares
        .iter()
        .map(|(_, share)| *share)
        .sum::<u64>()
        .saturating_add(hidden_floor.saturating_mul(slots - owner_count));
    let mut pool = total_bytes.saturating_sub(committed);

    if viewed > 0 {
        let viewed_count = u64::try_from(viewed).unwrap_or(u64::MAX);
        let each = (pool / viewed_count).min(full - equal);
        for (_, share) in &mut shares[..viewed] {
            *share += each;
        }
        pool -= each * viewed_count;
    }
    for (_, share) in &mut shares[viewed..] {
        if pool == 0 {
            break;
        }
        let extra = (full - *share).min(pool);
        *share += extra;
        pool -= extra;
    }
    shares
}

/// The limits for a reserved byte `share`, with the image and placement
/// counts of `counts`.
pub(super) fn kitty_image_limits_for_share(
    share: u64,
    counts: KittyGraphicsLimits,
) -> KittyGraphicsLimits {
    let image_bytes = kitty_image_bytes_for_process_share(share);
    KittyGraphicsLimits {
        image_bytes,
        inflight_bytes: ghostty_vt::kitty_inflight_replay_limit_for_image_bytes(image_bytes),
        images: counts.images,
        placements: counts.placements,
    }
}

/// The limits every budget entry should have, computed once per decision.
pub(super) struct KittyBudgetPlan {
    /// An equal share: every owner's limits without recency, and the image
    /// and placement counts with it.
    uniform: KittyGraphicsLimits,
    /// Each owner's limits with recency.
    by_owner: HashMap<SurfaceId, KittyGraphicsLimits>,
}

impl KittyBudgetPlan {
    pub(super) fn new(
        share: KittyShare,
        capacity: usize,
        entries: &HashMap<SurfaceId, KittyImageBudgetEntry>,
    ) -> Self {
        let uniform = kitty_image_limits_for_capacity_in(share.total_bytes, capacity);
        if !share.by_recency || capacity == 0 {
            return Self { uniform, by_owner: HashMap::new() };
        }
        let owners = entries
            .iter()
            .filter(|(_, entry)| entry.owns_quota && !entry.removing)
            .map(|(&id, entry)| KittyShareOwner {
                id,
                viewed: entry.viewed,
                shown_at: entry.shown_at,
            })
            .collect::<Vec<_>>();
        let by_owner = kitty_recency_shares(share.total_bytes, capacity, &owners)
            .into_iter()
            .map(|(id, bytes)| (id, kitty_image_limits_for_share(bytes, uniform)))
            .collect();
        Self { uniform, by_owner }
    }

    /// What `entry` (keyed `id`) should have applied.
    pub(super) fn desired(
        &self,
        id: SurfaceId,
        entry: &KittyImageBudgetEntry,
    ) -> KittyGraphicsLimits {
        if entry.removing || !entry.owns_quota {
            return KittyGraphicsLimits::disabled();
        }
        self.by_owner.get(&id).copied().unwrap_or(self.uniform)
    }

    /// The most `entry` may hold while a new terminal is admitted: an
    /// owner's share, and an equal share for one that owns none or is going
    /// away (it shrinks to nothing on its own).
    pub(super) fn admission_ceiling(
        &self,
        id: SurfaceId,
        entry: &KittyImageBudgetEntry,
    ) -> KittyGraphicsLimits {
        if entry.removing || !entry.owns_quota {
            return self.uniform;
        }
        self.desired(id, entry)
    }
}

impl Mux {
    /// A client showed terminal `id` (a byte or render attach): it becomes
    /// the most recently shown and counts as viewed until the budget worker
    /// next looks at its viewers.
    pub(crate) fn note_kitty_terminal_shown(self: &Arc<Self>, id: SurfaceId) {
        {
            let mut budget = self.kitty_image_budget.lock().unwrap();
            if !budget.share.by_recency || !budget.entries.contains_key(&id) {
                return;
            }
            let shown_at = budget.stamp_shown();
            if let Some(entry) = budget.entries.get_mut(&id) {
                entry.shown_at = shown_at;
                entry.viewed = true;
            }
        }
        self.start_kitty_image_budget_worker();
    }

    /// Record which owners a client views now (budget worker thread). A
    /// terminal whose last viewer left is stamped as shown now: it was on
    /// screen until then.
    pub(super) fn refresh_kitty_viewers(&self) {
        let owners = {
            let budget = self.kitty_image_budget.lock().unwrap();
            if !budget.share.by_recency {
                return;
            }
            budget
                .entries
                .iter()
                .filter(|(_, entry)| entry.owns_quota)
                .filter_map(|(&id, entry)| Some((id, entry.surface.clone()?)))
                .collect::<Vec<_>>()
        };
        // Surface locks only, with the budget lock released.
        let viewers = owners
            .into_iter()
            .filter_map(|(id, surface)| Some((id, surface.upgrade()?.has_terminal_viewers())))
            .collect::<Vec<_>>();
        let mut budget = self.kitty_image_budget.lock().unwrap();
        for (id, viewed) in viewers {
            let left = budget.entries.get(&id).is_some_and(|entry| entry.viewed && !viewed);
            let shown_at = left.then(|| budget.stamp_shown());
            if let Some(entry) = budget.entries.get_mut(&id) {
                entry.viewed = viewed;
                if let Some(shown_at) = shown_at {
                    entry.shown_at = shown_at;
                }
            }
        }
    }

    /// Critical memory pressure: the budget worker clears every terminal's
    /// decoded pixel copies.
    pub(super) fn request_kitty_pixel_release(self: &Arc<Self>) {
        self.kitty_image_budget.lock().unwrap().pixel_release_due = true;
        self.start_kitty_image_budget_worker();
    }

    /// Clear every terminal's decoded pixel copies while a release is due
    /// (budget worker thread). Returns whether the worker goes on to the
    /// limits; it stops here when a failed surface blocks them, since
    /// `start_kitty_image_budget_worker` then starts it for the release only.
    pub(super) fn release_kitty_pixels_if_due(&self) -> bool {
        loop {
            let surfaces = {
                let mut budget = self.kitty_image_budget.lock().unwrap();
                if !budget.pixel_release_due {
                    if budget.blocked_surfaces.is_empty() {
                        return true;
                    }
                    budget.expansion_in_flight = false;
                    budget.worker_running = false;
                    drop(budget);
                    self.kitty_image_budget_changed.notify_all();
                    return false;
                }
                budget.pixel_release_due = false;
                budget
                    .entries
                    .values()
                    .filter_map(|entry| entry.surface.clone())
                    .collect::<Vec<_>>()
            };
            for surface in surfaces.iter().filter_map(Weak::upgrade) {
                surface.release_kitty_pixel_caches();
            }
        }
    }

    /// With [`FEATURE`] on, register both pixel maps in this owner's memory
    /// registry and start its pressure source. The maps are rebuilt from
    /// libghostty's storage on the next frame or replay, so the consumer is
    /// lossless. Its callback only marks the release and starts the worker;
    /// the worker takes the terminal locks.
    pub(super) fn register_kitty_pixel_consumer(self: &Arc<Self>) {
        if !self.kitty_image_budget.lock().unwrap().share.by_recency {
            return;
        }
        let mux = Arc::downgrade(self);
        let consumer = cmux_memory::MemoryConsumer::new(
            PIXEL_CONSUMER_NAME,
            cmux_memory::Retention::Lossless,
            // Measured under each terminal's lock; the report does not take them.
            || None,
            move |level| {
                if level == cmux_memory::PressureLevel::Critical
                    && let Some(mux) = mux.upgrade()
                {
                    mux.request_kitty_pixel_release();
                }
            },
        );
        self.kitty_pixel_consumer.get_or_init(|| self.memory.registry().register(consumer));
        self.memory.watch_system_pressure();
    }

    #[cfg(test)]
    pub(super) fn set_kitty_share_for_test(&self, share: KittyShare) {
        self.kitty_image_budget.lock().unwrap().share = share;
    }
}
