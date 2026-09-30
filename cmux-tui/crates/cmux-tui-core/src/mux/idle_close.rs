//! Idle-close of detached terminals (`terminal-idle-close-v1`).
//!
//! A terminal may carry a durable idle-close policy in the workspace registry.
//! The owner's reaper periodically calls [`Mux::reap_idle_terminals`] with the
//! current time; a terminal that has had no attached view for at least its
//! policy is closed through the same path as `close-terminal` and
//! `terminal.close`.
//!
//! Unattached time is measured by this owner process only. After an owner
//! restart the clock starts again at the first reaper pass, so a restart can
//! delay a close but never make it early.
//!
//! The reaper is deadline-driven: it sleeps until the earliest unattached
//! terminal's policy is due, and is woken early when a policy changes or a
//! view detaches. With no policy-bearing terminal it blocks indefinitely
//! (it used to tick every 15 s whether or not any policy existed).

use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread::JoinHandle;

use super::*;

/// Kept for API compatibility: the reaper no longer ticks. It wakes at the
/// next policy deadline or when a policy or an attachment changes.
pub const IDLE_CLOSE_REAP_INTERVAL: Duration = Duration::from_secs(15);

const IDLE_CLOSE_MUTATION_ORIGIN: &str = "cmux-tui-idle-close";

/// One policy-bearing terminal as observed by a single reaper tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct IdleCandidate<'a> {
    pub(crate) terminal_id: &'a str,
    pub(crate) idle_close: Duration,
    /// Some client holds an attach stream on one of the terminal's views.
    pub(crate) attached: bool,
    /// Newest attach epoch over the terminal's views. A change means a view
    /// attached since the previous tick, even if it detached again.
    pub(crate) attach_epoch: u64,
}

#[derive(Debug, Clone, Copy)]
struct Unattached {
    since: Instant,
    attach_epoch: u64,
}

/// Pure idle bookkeeping, driven by an injected clock.
#[derive(Debug, Default)]
pub(crate) struct IdleCloseTracker {
    unattached: HashMap<String, Unattached>,
}

impl IdleCloseTracker {
    /// Advance to `now` and return the terminals whose continuous unattached
    /// time has reached their policy. Terminals absent from `candidates` (no
    /// policy, closed, or cleared) are forgotten.
    pub(crate) fn due(&mut self, now: Instant, candidates: &[IdleCandidate<'_>]) -> Vec<String> {
        let live: HashSet<&str> =
            candidates.iter().map(|candidate| candidate.terminal_id).collect();
        self.unattached.retain(|terminal_id, _| live.contains(terminal_id.as_str()));
        let mut due = Vec::new();
        for candidate in candidates {
            if candidate.attached {
                self.unattached.remove(candidate.terminal_id);
                continue;
            }
            let fresh = Unattached { since: now, attach_epoch: candidate.attach_epoch };
            let entry = self.unattached.entry(candidate.terminal_id.to_string()).or_insert(fresh);
            if entry.attach_epoch != candidate.attach_epoch {
                *entry = fresh;
            }
            if now.saturating_duration_since(entry.since) >= candidate.idle_close {
                due.push(candidate.terminal_id.to_string());
            }
        }
        due
    }

    /// When the earliest tracked unattached terminal becomes due.
    pub(crate) fn next_deadline(&self, candidates: &[IdleCandidate<'_>]) -> Option<Instant> {
        candidates
            .iter()
            .filter(|candidate| !candidate.attached)
            .filter_map(|candidate| {
                let entry = self.unattached.get(candidate.terminal_id)?;
                entry.since.checked_add(candidate.idle_close)
            })
            .min()
    }

    pub(crate) fn forget(&mut self, terminal_id: &str) {
        self.unattached.remove(terminal_id);
    }

    #[cfg(test)]
    pub(crate) fn tracked(&self) -> usize {
        self.unattached.len()
    }
}

impl Mux {
    /// Store (`Some`) or clear (`None`, never close) one hosted terminal's
    /// idle-close policy. `terminal_id` is the stable host id.
    pub fn set_terminal_idle_policy(
        &self,
        terminal_id: &str,
        idle_close_seconds: Option<u64>,
    ) -> anyhow::Result<()> {
        let result = {
            let mut registry = self.workspace_registry.lock().unwrap();
            registry.set_terminal_idle_policy(terminal_id, idle_close_seconds)
        };
        self.wake_idle_close_reaper();
        result
    }

    /// The stored idle-close policy of one hosted terminal.
    pub fn terminal_idle_policy(&self, terminal_id: &str) -> anyhow::Result<Option<u64>> {
        self.workspace_registry.lock().unwrap().terminal_idle_policy(terminal_id)
    }

    /// One reaper tick at `now`: close every policy-bearing terminal that has
    /// had no attached view for at least its policy. Returns the host ids of
    /// the terminals it closed.
    pub fn reap_idle_terminals(&self, now: Instant) -> Vec<String> {
        self.reap_idle_terminals_until_next(now).0
    }

    /// One reaper pass, plus when the next pass is due (`None`: no
    /// unattached policy-bearing terminal, wait for a change).
    pub(crate) fn reap_idle_terminals_until_next(
        &self,
        now: Instant,
    ) -> (Vec<String>, Option<Instant>) {
        let (pruned, policies) = {
            let mut registry = self.workspace_registry.lock().unwrap();
            (registry.prune_terminal_idle_policies(), registry.live_terminal_idle_policies())
        };
        if let Err(error) = pruned {
            self.report_internal_diagnostic(format!("idle-close policy prune failed: {error}"));
        }
        let policies = match policies {
            Ok(policies) => policies,
            Err(error) => {
                self.report_internal_diagnostic(format!("idle-close policy read failed: {error}"));
                // Retry after a bounded pause; a read failure is not idle.
                return (Vec::new(), Some(now + IDLE_CLOSE_READ_RETRY));
            }
        };
        if policies.is_empty() {
            self.idle_close.lock().unwrap().due(now, &[]);
            return (Vec::new(), None);
        }
        let placements = self.terminal_placements_by_host();
        let candidates: Vec<IdleCandidate<'_>> = policies
            .iter()
            .map(|policy| {
                let surfaces = views(&placements, &policy.terminal_id);
                let (attached, attach_epoch) = self.control_clients.attach_observation(surfaces);
                IdleCandidate {
                    terminal_id: &policy.terminal_id,
                    idle_close: Duration::from_secs(policy.idle_close_seconds),
                    attached,
                    attach_epoch,
                }
            })
            .collect();
        let due = self.idle_close.lock().unwrap().due(now, &candidates);
        let any_due = !due.is_empty();
        let mut closed = Vec::with_capacity(due.len());
        for terminal_id in due {
            // Whatever happens next, this terminal's idle period is over: a
            // late attach resets it, and a failed close is retried after
            // another full period instead of on every tick.
            self.idle_close.lock().unwrap().forget(&terminal_id);
            if self.control_clients.attach_observation(views(&placements, &terminal_id)).0 {
                continue;
            }
            let incarnation = policies
                .iter()
                .find(|policy| policy.terminal_id == terminal_id)
                .and_then(|policy| policy.incarnation.clone());
            match self.close_terminal_with_mutation(
                &terminal_id,
                incarnation.as_deref(),
                None,
                None,
                &WorkspaceMutation::local(IDLE_CLOSE_MUTATION_ORIGIN),
            ) {
                Ok(_) => closed.push(terminal_id),
                Err(error) => self.report_internal_diagnostic(format!(
                    "idle-close of terminal {terminal_id} failed: {error}"
                )),
            }
        }
        // A closed or forgotten terminal is re-tracked from `now` on the
        // next pass, so the deadline below covers only live periods.
        let next = self.idle_close.lock().unwrap().next_deadline(&candidates);
        // A due terminal was forgotten even when its close failed or a view
        // attached at the recheck; without a pass now it would never be
        // re-tracked and the reaper would block with no deadline.
        let next = if !any_due && next.is_none_or(|next| next > now) {
            next
        } else {
            // Something changed this pass: evaluate again at once so the
            // tracker records fresh periods for the terminals it forgot.
            Some(now)
        };
        (closed, next)
    }

    /// Wakes the idle-close reaper (a policy or an attachment changed).
    pub(crate) fn wake_idle_close_reaper(&self) {
        if let Some(waker) = self.idle_close_waker.lock().unwrap().as_ref() {
            let _ = waker.send(ReaperMessage::Wake);
        }
    }

    /// Every surface a client can attach to for a terminal, grouped by the
    /// stable host id it presents: placed views plus the catalog runtime,
    /// which resource clients attach to even when the terminal is unplaced.
    fn terminal_placements_by_host(&self) -> HashMap<String, Vec<SurfaceId>> {
        let state = self.state.lock().unwrap();
        let mut placements: HashMap<String, Vec<SurfaceId>> = HashMap::new();
        let surfaces = state.surfaces.values().chain(state.terminal_catalog.values());
        for surface in surfaces {
            if let Some(identity) = self.resource_terminal_host_identity(surface) {
                let views = placements.entry(identity.terminal_id).or_default();
                if !views.contains(&surface.id) {
                    views.push(surface.id);
                }
            }
        }
        placements
    }
}

fn views<'a>(
    placements: &'a HashMap<String, Vec<SurfaceId>>,
    terminal_id: &str,
) -> &'a [SurfaceId] {
    placements.get(terminal_id).map(Vec::as_slice).unwrap_or(&[])
}

/// Retry pause after the registry could not read idle-close policies.
const IDLE_CLOSE_READ_RETRY: Duration = Duration::from_secs(30);

pub(crate) enum ReaperMessage {
    Wake,
    Stop,
}

/// Owner-side idle-close reaper thread. `stop` wakes and joins it; dropping
/// the handle wakes it without joining.
pub struct IdleTerminalReaper {
    stop: Option<mpsc::Sender<ReaperMessage>>,
    thread: Option<JoinHandle<()>>,
}

impl IdleTerminalReaper {
    pub fn stop(mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(ReaperMessage::Stop);
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for IdleTerminalReaper {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(ReaperMessage::Stop);
        }
    }
}

/// Start the reaper for an owner. It sleeps until the next idle-close
/// deadline, wakes early on policy or attachment changes, and runs until
/// stopped or the mux is gone. `_interval` is unused (no periodic tick).
pub fn start_idle_terminal_reaper(
    mux: Weak<Mux>,
    _interval: Duration,
) -> std::io::Result<IdleTerminalReaper> {
    let (stop, messages) = mpsc::channel::<ReaperMessage>();
    if let Some(owner) = mux.upgrade() {
        *owner.idle_close_waker.lock().unwrap() = Some(stop.clone());
        let waker = stop.clone();
        owner.control_clients.set_detach_waker(move || {
            let _ = waker.send(ReaperMessage::Wake);
        });
    }
    let thread = std::thread::Builder::new().name("mux-idle-close".into()).spawn(move || {
        loop {
            let Some(owner) = mux.upgrade() else { break };
            let now = Instant::now();
            let (_, next) = owner.reap_idle_terminals_until_next(now);
            drop(owner);
            let message = match next {
                None => messages.recv().map_err(|_| RecvTimeoutError::Disconnected),
                Some(next) => messages.recv_timeout(next.saturating_duration_since(now)),
            };
            match message {
                Ok(ReaperMessage::Wake) | Err(RecvTimeoutError::Timeout) => {}
                Ok(ReaperMessage::Stop) | Err(RecvTimeoutError::Disconnected) => break,
            }
        }
    })?;
    Ok(IdleTerminalReaper { stop: Some(stop), thread: Some(thread) })
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOUR: Duration = Duration::from_secs(60 * 60);

    fn candidate(terminal_id: &str, attached: bool, attach_epoch: u64) -> IdleCandidate<'_> {
        IdleCandidate { terminal_id, idle_close: HOUR, attached, attach_epoch }
    }

    #[test]
    fn unattached_terminal_is_due_only_once_its_policy_elapses() {
        let start = Instant::now();
        let mut tracker = IdleCloseTracker::default();
        let idle = [candidate("idle", false, 0)];

        assert!(tracker.due(start, &idle).is_empty(), "the first observation starts the clock");
        assert!(tracker.due(start + HOUR - Duration::from_secs(1), &idle).is_empty());
        assert_eq!(tracker.due(start + HOUR, &idle), vec!["idle".to_string()]);
    }

    #[test]
    fn attached_terminal_is_never_due_and_detaching_restarts_the_clock() {
        let start = Instant::now();
        let mut tracker = IdleCloseTracker::default();

        assert!(tracker.due(start, &[candidate("view", false, 1)]).is_empty());
        assert!(tracker.due(start + 10 * HOUR, &[candidate("view", true, 1)]).is_empty());
        assert_eq!(tracker.tracked(), 0, "an attached terminal carries no idle clock");

        let detached_at = start + 11 * HOUR;
        assert!(tracker.due(detached_at, &[candidate("view", false, 1)]).is_empty());
        assert!(tracker.due(detached_at + HOUR / 2, &[candidate("view", false, 1)]).is_empty());
        assert_eq!(
            tracker.due(detached_at + HOUR, &[candidate("view", false, 1)]),
            vec!["view".to_string()]
        );
    }

    #[test]
    fn reattach_between_ticks_resets_the_clock() {
        let start = Instant::now();
        let mut tracker = IdleCloseTracker::default();

        assert!(tracker.due(start, &[candidate("flicker", false, 1)]).is_empty());
        // A view attached and detached again between two ticks: the tick
        // only sees a newer attach epoch.
        let reattached = start + HOUR - Duration::from_secs(1);
        assert!(tracker.due(reattached, &[candidate("flicker", false, 2)]).is_empty());
        assert!(tracker.due(start + HOUR, &[candidate("flicker", false, 2)]).is_empty());
        assert_eq!(
            tracker.due(reattached + HOUR, &[candidate("flicker", false, 2)]),
            vec!["flicker".to_string()]
        );
    }

    #[test]
    fn terminal_without_a_policy_is_forgotten() {
        let start = Instant::now();
        let mut tracker = IdleCloseTracker::default();

        assert!(tracker.due(start, &[candidate("cleared", false, 0)]).is_empty());
        assert_eq!(tracker.tracked(), 1);
        // Clearing the policy (`null`) removes the terminal from the candidates.
        assert!(tracker.due(start + 100 * HOUR, &[]).is_empty());
        assert_eq!(tracker.tracked(), 0);
        // A policy set again later starts a fresh clock.
        assert!(tracker.due(start + 101 * HOUR, &[candidate("cleared", false, 0)]).is_empty());
    }
}
