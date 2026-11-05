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
    /// Size the Kitty image budget for the terminal that will reserve as
    /// `slot` ([`KittyImageSurfaceExpectation`]); within a wave it takes over
    /// one of the wave's terminals. It respawns `old_runtime` (none: a new
    /// terminal), whose dead runtime gives its share up in the same budget
    /// step: kept, the terminal counted twice (its old entry and its
    /// expectation), and the hysteresis kept the larger bucket after it.
    /// In one step, the worker never grows the other terminals in between
    /// only to shrink them again before the respawn may reserve.
    pub(crate) fn expect_kitty_image_respawn(
        self: &Arc<Self>,
        old_runtime: Option<&Arc<Surface>>,
        slot: SurfaceId,
    ) -> KittyImageSurfaceExpectation {
        {
            let mut budget = self.kitty_image_budget.lock().unwrap();
            if let Some(old) = old_runtime {
                Self::remove_kitty_image_entry(&mut budget, old);
            }
            if budget.expected.insert(slot) {
                budget.expected_in_wave = budget.expected_in_wave.saturating_sub(1);
            }
            Self::rebalance_kitty_image_budget_owners(&mut budget);
        }
        // Terminals that already run shrink now, before the respawns reserve.
        self.kitty_image_budget_changed.notify_all();
        self.start_kitty_image_budget_worker();
        KittyImageSurfaceExpectation { mux: Arc::downgrade(self), surface: slot }
    }

    /// Size the Kitty image budget for `count` terminals a respawn wave will
    /// add before any of them is planned ([`KittyImageWaveExpectation`]).
    pub(crate) fn expect_kitty_image_wave(
        self: &Arc<Self>,
        count: usize,
    ) -> KittyImageWaveExpectation {
        {
            let mut budget = self.kitty_image_budget.lock().unwrap();
            budget.expected_in_wave = budget.expected_in_wave.saturating_add(count);
            Self::rebalance_kitty_image_budget_owners(&mut budget);
        }
        self.start_kitty_image_budget_worker();
        KittyImageWaveExpectation { mux: Arc::downgrade(self) }
    }

    /// Give back an expectation no reservation took: `surface`'s, and up to
    /// `wave` of a wave's.
    pub(super) fn forget_kitty_image_expectation(
        self: &Arc<Self>,
        surface: Option<SurfaceId>,
        wave: usize,
    ) {
        {
            let mut budget = self.kitty_image_budget.lock().unwrap();
            let named = surface.is_some_and(|surface| budget.expected.remove(&surface));
            let unnamed = budget.expected_in_wave.min(wave);
            if !named && unnamed == 0 {
                return;
            }
            budget.expected_in_wave -= unnamed;
            Self::rebalance_kitty_image_budget_owners(&mut budget);
        }
        // A reservation waiting on the larger bucket may fit now, and the
        // terminals that run may grow back.
        self.kitty_image_budget_changed.notify_all();
        self.start_kitty_image_budget_worker();
    }

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
            // The expectation of this terminal becomes its reservation in
            // this lock: the bucket never drops below the wave between them.
            let was_expected = budget.expected.remove(&surface);
            let owner_count = Self::kitty_image_budget_owner_count(&budget);
            let owns_quota =
                budget.blocked_surfaces.is_empty() && owner_count < KITTY_IMAGE_BUDGET_OWNER_LIMIT;
            if owns_quota {
                let sized_for = budget.sized_for(owner_count + 1);
                budget.capacity = kitty_image_budget_capacity(sized_for, budget.capacity);
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
            if was_expected && !owns_quota {
                Self::rebalance_kitty_image_budget_owners(&mut budget);
            }
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
