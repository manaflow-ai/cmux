//! The surfaces a frontend does not show, in its subscription's mailbox
//! (`frontend.visibility.set`, server/frontend_visibility.rs).
//!
//! A hidden surface's field events (its title, agent, program status, output
//! and scroll slots) wait in held slots, still coalesced per
//! [`CoalescedEventKey`], and all of them flush together on the mailbox's
//! aligned 1 s grid, or at once when their surface shows. Structural events
//! (exits, tree deltas, bells, notifications) never wait, and the frontend's
//! own change is never held. Blink throttles a hidden page's timers the same
//! way: they run together at one aligned wake per second
//! (third_party/blink/renderer/platform/scheduler/common/throttling/wake_up_budget_pool.cc,
//! `WakeUpBudgetPool::GetNextAllowedRunTime`), and a page that shows runs its
//! work at once (`PageSchedulerImpl::SetPageVisible`).

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

use super::{CoalescedEventKey, MuxEventMailboxState};
use crate::event_cause::EventCause;
use crate::{MuxEvent, SurfaceId};

/// How long a hidden surface's field change waits at most.
pub(crate) const HIDDEN_FLUSH_INTERVAL: Duration = Duration::from_secs(1);

/// The monotonic clock a scope reads; tests pass a fake.
pub(crate) type MailboxClock = Arc<dyn Fn() -> Instant + Send + Sync>;

/// When held slots flush: on a grid of `interval` from the scope's start, by
/// `clock`.
#[derive(Clone)]
pub(crate) struct HiddenFlush {
    interval: Duration,
    clock: MailboxClock,
}

impl HiddenFlush {
    /// [`HIDDEN_FLUSH_INTERVAL`] on the system's monotonic clock.
    pub(crate) fn system() -> Self {
        Self { interval: HIDDEN_FLUSH_INTERVAL, clock: Arc::new(Instant::now) }
    }

    /// `interval` on `clock` (tests).
    #[cfg(test)]
    pub(crate) fn new(interval: Duration, clock: MailboxClock) -> Self {
        Self { interval: interval.max(Duration::from_nanos(1)), clock }
    }

    fn now(&self) -> Instant {
        (self.clock)()
    }
}

/// One subscription's visible surfaces and the held slots of the others.
pub(super) struct VisibilityScope {
    visible: HashSet<SurfaceId>,
    /// Held slots by sequence, so a flush keeps their order.
    held: BTreeMap<u128, (CoalescedEventKey, Arc<MuxEvent>, EventCause)>,
    held_sequences: HashMap<CoalescedEventKey, u128>,
    /// The grid's origin: the scope's start.
    origin: Instant,
    flush: HiddenFlush,
    /// The grid point the held slots flush at; `None` while none is held.
    flush_at: Option<Instant>,
}

impl VisibilityScope {
    fn new(flush: &HiddenFlush) -> Self {
        Self {
            visible: HashSet::new(),
            held: BTreeMap::new(),
            held_sequences: HashMap::new(),
            origin: flush.now(),
            flush: flush.clone(),
            flush_at: None,
        }
    }

    fn hides(&self, key: CoalescedEventKey) -> bool {
        key.surface().is_some_and(|surface| !self.visible.contains(&surface))
    }

    /// The first grid point after `now`.
    fn next_grid_point(&self, now: Instant) -> Instant {
        let interval = self.flush.interval.as_nanos().max(1);
        let elapsed = now.saturating_duration_since(self.origin).as_nanos();
        let next = (elapsed / interval + 1) * interval;
        self.origin + Duration::from_nanos(u64::try_from(next).unwrap_or(u64::MAX))
    }
}

impl MuxEventMailboxState {
    /// Whether `key`'s change of `cause` waits for the flush: the frontend
    /// does not show its surface and it is not the frontend's own change.
    pub(super) fn holds(&self, key: CoalescedEventKey, cause: EventCause) -> bool {
        cause != EventCause::Frontend
            && self.visibility.as_ref().is_some_and(|scope| scope.hides(key))
    }

    /// Holds `event` in `key`'s slot ([`Self::holds`] said so). Returns
    /// whether it set the flush deadline (a waiter must learn it).
    pub(super) fn hold(
        &mut self,
        sequence: u128,
        key: CoalescedEventKey,
        event: Arc<MuxEvent>,
        cause: EventCause,
    ) -> bool {
        let Some(scope) = self.visibility.as_mut() else { return false };
        scope.held_sequences.insert(key, sequence);
        scope.held.insert(sequence, (key, event, cause));
        if scope.flush_at.is_some() {
            return false;
        }
        scope.flush_at = Some(scope.next_grid_point(scope.flush.now()));
        true
    }

    /// Takes `key`'s held slot, if any.
    pub(super) fn take_held(
        &mut self,
        key: CoalescedEventKey,
    ) -> Option<(CoalescedEventKey, Arc<MuxEvent>, EventCause)> {
        let scope = self.visibility.as_mut()?;
        let sequence = scope.held_sequences.remove(&key)?;
        let slot = scope.held.remove(&sequence);
        if scope.held.is_empty() {
            scope.flush_at = None;
        }
        slot
    }

    pub(super) fn held_len(&self) -> usize {
        self.visibility.as_ref().map_or(0, |scope| scope.held.len())
    }

    pub(super) fn clear_held(&mut self) {
        if let Some(scope) = self.visibility.as_mut() {
            scope.held.clear();
            scope.held_sequences.clear();
            scope.flush_at = None;
        }
    }

    /// Makes every held slot ready once the flush deadline has passed.
    pub(super) fn release_due(&mut self) {
        let Some(scope) = self.visibility.as_ref() else { return };
        let Some(flush_at) = scope.flush_at else { return };
        if scope.flush.now() >= flush_at {
            self.release_held(|_| true);
        }
    }

    /// How long a waiter may sleep before the held slots flush; `None`
    /// while none is held.
    pub(super) fn flush_wait(&self) -> Option<Duration> {
        let scope = self.visibility.as_ref()?;
        let flush_at = scope.flush_at?;
        Some(flush_at.saturating_duration_since(scope.flush.now()))
    }

    /// Makes the held slots of the surfaces `released` picks ready, in their
    /// order; returns how many.
    pub(super) fn release_held(&mut self, released: impl Fn(SurfaceId) -> bool) -> usize {
        let Some(scope) = self.visibility.as_mut() else { return 0 };
        let sequences: Vec<u128> = scope
            .held
            .iter()
            .filter(|(_, (key, ..))| key.surface().is_some_and(&released))
            .map(|(sequence, _)| *sequence)
            .collect();
        for sequence in &sequences {
            let Some((key, event, cause)) = scope.held.remove(sequence) else { continue };
            scope.held_sequences.remove(&key);
            self.coalesced_sequences.insert(key, *sequence);
            self.coalesced.insert(*sequence, (key, event, cause));
        }
        if scope.held.is_empty() {
            scope.flush_at = None;
        }
        sequences.len()
    }

    /// Makes `surface`'s held slots ready: O(its slots), not O(every held one).
    pub(super) fn release_surface(&mut self, surface: SurfaceId) {
        let Some(scope) = self.visibility.as_mut() else { return };
        for key in CoalescedEventKey::of_surface(surface) {
            let Some(sequence) = scope.held_sequences.remove(&key) else { continue };
            let Some(slot) = scope.held.remove(&sequence) else { continue };
            self.coalesced_sequences.insert(key, sequence);
            self.coalesced.insert(sequence, slot);
        }
        if scope.held.is_empty() {
            scope.flush_at = None;
        }
    }

    /// Sets the surfaces the frontend shows (`None`: all of them) and
    /// releases the held slots of the ones it shows now; returns how many.
    pub(super) fn set_visible(
        &mut self,
        visible: Option<&HashSet<SurfaceId>>,
        flush: &HiddenFlush,
    ) -> usize {
        let Some(visible) = visible else {
            let released = self.release_held(|_| true);
            self.visibility = None;
            return released;
        };
        self.visibility.get_or_insert_with(|| VisibilityScope::new(flush)).visible =
            visible.clone();
        self.release_held(|surface| visible.contains(&surface))
    }
}

#[cfg(test)]
#[path = "frontend_visibility_tests.rs"]
mod frontend_visibility_tests;
