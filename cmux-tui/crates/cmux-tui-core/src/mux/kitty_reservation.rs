//! Kitty image budget reservation for a new terminal.

use super::*;

/// How long creating a terminal waits for existing terminals to shrink their
/// Kitty quota before the new terminal starts with graphics disabled (the
/// budget worker promotes it once the shrink completes). A shrink takes a few
/// milliseconds; waiting the 2 s control timeout here held every creation
/// that changed the budget bucket for 2 s when a host was slow to answer.
/// Above 250 ms so a shrink already in flight is still awaited
/// (kitty_quota_updates_delay_terminal_creation_until_startup_is_safe).
const KITTY_RESERVATION_WAIT: Duration = Duration::from_millis(500);

impl Mux {
    pub(crate) fn reserve_kitty_image_surface(
        self: &Arc<Self>,
        surface: SurfaceId,
    ) -> anyhow::Result<KittyImageBudgetReservation> {
        {
            let mut budget = self.kitty_image_budget.lock().unwrap();
            Self::prune_dead_kitty_image_surfaces(&mut budget);
            anyhow::ensure!(
                !budget.entries.contains_key(&surface),
                "Kitty image budget already reserved for surface {surface}"
            );
            let owner_count = Self::kitty_image_budget_owner_count(&budget);
            let owns_quota =
                budget.blocked_surfaces.is_empty() && owner_count < KITTY_IMAGE_BUDGET_OWNER_LIMIT;
            if owns_quota {
                budget.capacity = kitty_image_budget_capacity(owner_count + 1, budget.capacity);
            }
            budget.entries.insert(
                surface,
                KittyImageBudgetEntry {
                    surface: None,
                    applied: KittyGraphicsLimits::disabled(),
                    owns_quota,
                    removing: false,
                },
            );
        }
        self.start_kitty_image_budget_worker();
        let deadline = Instant::now() + KITTY_RESERVATION_WAIT;
        let initial_limits =
            loop {
                let mut budget = self.kitty_image_budget.lock().unwrap();
                if !budget.blocked_surfaces.is_empty() {
                    let entry = budget.entries.get_mut(&surface).ok_or_else(|| {
                        anyhow::anyhow!("Kitty image budget reservation disappeared")
                    })?;
                    entry.owns_quota = false;
                    entry.applied = KittyGraphicsLimits::disabled();
                    Self::rebalance_kitty_image_budget_owners(&mut budget);
                    break KittyGraphicsLimits::disabled();
                }
                let owns_quota = budget
                    .entries
                    .get(&surface)
                    .ok_or_else(|| anyhow::anyhow!("Kitty image budget reservation disappeared"))?
                    .owns_quota;
                if !owns_quota {
                    break KittyGraphicsLimits::disabled();
                }
                let target = kitty_image_limits_for_capacity(budget.capacity);
                if !budget.expansion_in_flight
                    && kitty_image_limits_enabled(target)
                    && budget.entries.iter().all(|(&id, entry)| {
                        id == surface || kitty_image_limits_within(entry.applied, target)
                    })
                {
                    let entry = budget.entries.get_mut(&surface).ok_or_else(|| {
                        anyhow::anyhow!("Kitty image budget reservation disappeared")
                    })?;
                    entry.applied = target;
                    break target;
                }
                if self.shutting_down.load(Ordering::Acquire) {
                    drop(budget);
                    self.cancel_kitty_image_surface_reservation(surface);
                    anyhow::bail!("multiplexer shut down while reserving Kitty image quota");
                }
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    // Kitty graphics are optional. Keep the terminal admission
                    // alive when an existing host does not acknowledge its
                    // quota update in time. The worker can apply the target
                    // limits after the outstanding update recovers.
                    let entry = budget.entries.get_mut(&surface).ok_or_else(|| {
                        anyhow::anyhow!("Kitty image budget reservation disappeared")
                    })?;
                    entry.owns_quota = false;
                    entry.applied = KittyGraphicsLimits::disabled();
                    Self::rebalance_kitty_image_budget_owners(&mut budget);
                    self.kitty_image_budget_changed.notify_all();
                    break KittyGraphicsLimits::disabled();
                }
                let (next, _) =
                    self.kitty_image_budget_changed.wait_timeout(budget, remaining).unwrap();
                drop(next);
            };
        Ok(KittyImageBudgetReservation {
            mux: Arc::downgrade(self),
            surface,
            initial_limits,
            committed: false,
        })
    }
}

pub(super) fn kitty_image_limits_within(
    candidate: KittyGraphicsLimits,
    ceiling: KittyGraphicsLimits,
) -> bool {
    candidate.image_bytes <= ceiling.image_bytes
        && candidate.inflight_bytes <= ceiling.inflight_bytes
        && candidate.images <= ceiling.images
        && candidate.placements <= ceiling.placements
}

pub(super) fn kitty_image_limits_exceed(
    candidate: KittyGraphicsLimits,
    ceiling: KittyGraphicsLimits,
) -> bool {
    !kitty_image_limits_within(candidate, ceiling)
}

fn kitty_image_limits_enabled(limits: KittyGraphicsLimits) -> bool {
    limits.image_bytes > 0
        && limits.inflight_bytes > 0
        && limits.images > 0
        && limits.placements > 0
}
