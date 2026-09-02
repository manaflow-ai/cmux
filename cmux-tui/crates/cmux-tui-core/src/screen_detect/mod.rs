//! Screen-derived agent lifecycle detection.
//!
//! Detection semantics derived from herdr (https://github.com/herdrdev/herdr),
//! Apache-2.0, commit 7b675f42af35, modified by manaflow.
//!
//! The daemon watches every PTY's output stream; when a terminal goes
//! quiet (debounced), the foreground process name selects a vendored
//! herdr manifest and the terminal tail is evaluated against it. State
//! TRANSITIONS (never per-scan states) append `agent.*` journal events
//! with `native_event = "ScreenDetect"`, so the journal-derived roster
//! covers agents that expose no hooks (codex today). The engine port
//! lives in [`manifest`]; this module owns the pure edge-trigger
//! bookkeeping and the daemon-side scanner loop.

pub(crate) mod manifest;
pub(crate) mod scanner;

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::AgentState;
use manifest::{Detection, ScreenState};

/// Output must be quiet this long before the screen is evaluated, so
/// mid-redraw frames are rarely matched.
pub(crate) const QUIESCENCE_DEBOUNCE_MS: u64 = 300;

/// A screen that never goes quiet (agent spinners animate every ~100ms,
/// so a working codex never quiesces) is still evaluated at this pace.
/// Without it, quiescence gating starves detection during the exact
/// phase it exists to report.
pub(crate) const MAX_EVAL_INTERVAL_MS: u64 = 1_000;

/// Foreground identity is coalesced per terminal, with process-id changes
/// forcing an immediate refresh. The cached identity is never used while a
/// refresh is due, so stale metadata fails closed.
pub(crate) const PROCESS_LOOKUP_INTERVAL_MS: u64 = 500;

const PENDING_RETRY_INTERVAL_MS: u64 = 1_000;
/// Re-emit an unchanged screen state so it can claim a terminal after the
/// hook owner's freshness window expires.
const SCREEN_REEMIT_INTERVAL_MS: u64 = 30_000;

/// Failed viewport reads are retried at a bounded cadence until output
/// changes, instead of retrying on every scanner tick.
const VIEWPORT_RETRY_INTERVAL_MS: u64 = 1_000;

/// The `native_event` value screen-detection journal events carry.
pub(crate) const SCREEN_DETECT_NATIVE_EVENT: &str = "ScreenDetect";

/// One state transition the scanner must journal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ScreenDetectEmission {
    pub(crate) terminal_id: String,
    /// Manifest id of the detected agent (`codex`, `claude`, ...).
    pub(crate) agent: String,
    pub(crate) state: AgentState,
}

#[derive(Debug, Default)]
struct TrackedTerminal {
    /// Last observed output-stream revision.
    revision: u64,
    /// When that revision was first observed (debounce anchor).
    quiet_since: Option<Instant>,
    /// Revision already evaluated; skip re-evaluating identical screens.
    evaluated_revision: Option<u64>,
    /// When the screen was last evaluated (the max-interval pacer anchor).
    last_evaluated_at: Option<Instant>,
    /// Start of the current continuously-changing revision burst. The
    /// max-interval pacer is allowed only inside such a burst, never on the
    /// first revision after an idle gap.
    changing_since: Option<Instant>,
    last_revision_at: Option<Instant>,
    /// Agent the foreground process matched on the previous scan; identity
    /// edges trigger immediate evaluation, before any quiescence.
    foreground_agent: Option<String>,
    /// Last process metadata refresh and PID observed for this terminal.
    last_process_lookup_at: Option<Instant>,
    last_process_id: Option<u32>,
    /// Whether the cached foreground identity came from a successful lookup.
    foreground_identity_known: bool,
    /// Earliest time to retry a failed viewport read.
    retry_after: Option<Instant>,
    /// Last (agent, state) journaled; emissions are edges over this.
    emitted: Option<(String, AgentState)>,
}

/// Pure edge-trigger state for the scanner. All timing is passed in, so
/// tests drive it deterministically.
#[derive(Debug, Default)]
pub(crate) struct ScreenDetectTracker {
    terminals: HashMap<String, TrackedTerminal>,
    pending_emissions: HashMap<String, ScreenDetectEmission>,
    pending_retry_after: HashMap<String, Instant>,
    catalog_revision: Option<u64>,
}

impl ScreenDetectTracker {
    /// Record the terminal's current output revision. Returns `true` when
    /// the screen changed since the last evaluation and either output has
    /// been quiet for the debounce window or a continuously changing screen
    /// has reached the max-interval pacer. A revision after an idle gap always
    /// starts with the quiet debounce.
    pub(crate) fn observe_revision(
        &mut self,
        terminal_id: &str,
        revision: u64,
        now: Instant,
    ) -> bool {
        let entry = self.terminals.entry(terminal_id.to_string()).or_default();
        if entry.quiet_since.is_none() || entry.revision != revision {
            let continuously_changing = entry.last_revision_at.is_some_and(|last| {
                now.duration_since(last).as_millis() as u64 <= QUIESCENCE_DEBOUNCE_MS
            });
            entry.changing_since = continuously_changing
                .then(|| entry.changing_since.or(entry.last_revision_at).unwrap_or(now));
            entry.revision = revision;
            entry.quiet_since = Some(now);
            entry.last_revision_at = Some(now);
        } else {
            entry.changing_since = None;
            // A stable revision breaks the continuous-change burst. The
            // next revision must earn the debounce window again.
            entry.last_revision_at = None;
        }
        if entry.evaluated_revision == Some(entry.revision) {
            return false;
        }
        if let Some(retry_after) = entry.retry_after {
            if now < retry_after {
                return false;
            }
            entry.retry_after = None;
        }
        let quiet_since = entry.quiet_since.expect("anchored above");
        let quiesced = now.duration_since(quiet_since).as_millis() as u64 >= QUIESCENCE_DEBOUNCE_MS;
        let overdue = entry.changing_since.is_some_and(|changing_since| {
            now.duration_since(changing_since).as_millis() as u64 >= MAX_EVAL_INTERVAL_MS
                && entry.last_evaluated_at.is_none_or(|evaluated_at| {
                    now.duration_since(evaluated_at).as_millis() as u64 >= MAX_EVAL_INTERVAL_MS
                })
        });
        if quiesced || overdue {
            entry.last_evaluated_at = Some(now);
            return true;
        }
        false
    }

    /// True when this terminal previously journaled a screen-derived state
    /// that has not been closed out by an exit emission.
    pub(crate) fn has_live_emission(&self, terminal_id: &str) -> bool {
        self.terminals.get(terminal_id).is_some_and(|entry| entry.emitted.is_some())
    }

    /// Record which agent the foreground process currently matches. Returns
    /// `true` on an identity edge (spawn, swap, or exit), which evaluates
    /// the screen immediately: presence comes from the process, so the row
    /// appears the moment `codex` starts, not after its first quiet screen.
    pub(crate) fn note_foreground_agent(&mut self, terminal_id: &str, agent: Option<&str>) -> bool {
        let entry = self.terminals.entry(terminal_id.to_string()).or_default();
        entry.foreground_identity_known = true;
        if entry.foreground_agent.as_deref() == agent {
            return false;
        }
        let previous = entry.foreground_agent.as_deref();
        entry.foreground_agent = agent.map(str::to_string);
        // A supported-agent swap must not retain the old agent's last emitted
        // state. A transition to None keeps it so the caller can emit Done.
        if agent.is_some() && previous.is_some() && previous != agent {
            entry.emitted = None;
        }
        true
    }

    /// Return true when process metadata should be refreshed for this
    /// terminal. PID changes invalidate the cached identity immediately;
    /// unchanged PIDs refresh on a bounded cadence to catch in-place `exec`.
    pub(crate) fn should_lookup_foreground_agent(
        &mut self,
        terminal_id: &str,
        process_id: Option<u32>,
        now: Instant,
    ) -> bool {
        let entry = self.terminals.entry(terminal_id.to_string()).or_default();
        if entry.last_process_id != process_id {
            entry.last_process_id = process_id;
            entry.last_process_lookup_at = Some(now);
            entry.foreground_identity_known = false;
            entry.foreground_agent = None;
            entry.emitted = None;
            return true;
        }
        let due = entry.last_process_lookup_at.is_none_or(|last| {
            now.duration_since(last).as_millis() as u64 >= PROCESS_LOOKUP_INTERVAL_MS
        });
        if due {
            entry.last_process_lookup_at = Some(now);
        }
        due
    }

    pub(crate) fn foreground_agent(&self, terminal_id: &str) -> Option<String> {
        self.terminals.get(terminal_id).and_then(|entry| entry.foreground_agent.clone())
    }

    pub(crate) fn foreground_identity_known(&self, terminal_id: &str) -> bool {
        self.terminals.get(terminal_id).is_some_and(|entry| entry.foreground_identity_known)
    }

    pub(crate) fn invalidate_foreground_identity(&mut self, terminal_id: &str) -> Option<String> {
        if let Some(entry) = self.terminals.get_mut(terminal_id) {
            entry.foreground_identity_known = false;
            // A failed lookup must not leave the previous process identity
            // available to a later screen evaluation. Return it so the
            // scanner can retire a detected durable row fail-closed.
            let previous = entry.foreground_agent.take();
            entry.emitted = None;
            previous
        } else {
            None
        }
    }

    pub(crate) fn rearm_stale_emission(&mut self, terminal_id: &str, now: Instant) -> bool {
        let Some(entry) = self.terminals.get_mut(terminal_id) else { return false };
        let Some(last_evaluated_at) = entry.last_evaluated_at else { return false };
        if entry.emitted.is_none()
            || (now.duration_since(last_evaluated_at).as_millis() as u64)
                < SCREEN_REEMIT_INTERVAL_MS
        {
            return false;
        }
        entry.emitted = None;
        // Advance the pacer anchor with the re-arm. Otherwise every 100 ms
        // scan after the first 30-second interval would re-open the same
        // emission and repeatedly read the viewport.
        entry.last_evaluated_at = Some(now);
        true
    }

    /// Re-arm the current revision after a transient viewport read failure.
    pub(crate) fn retry_detection(&mut self, terminal_id: &str, now: Instant) {
        if let Some(entry) = self.terminals.get_mut(terminal_id) {
            entry.evaluated_revision = None;
            entry.retry_after = Some(now + Duration::from_millis(VIEWPORT_RETRY_INTERVAL_MS));
        }
    }

    pub(crate) fn stage_failed_emission(&mut self, emission: ScreenDetectEmission) {
        self.pending_emissions.insert(emission.terminal_id.clone(), emission);
    }

    pub(crate) fn pending_emission(&self, terminal_id: &str) -> Option<ScreenDetectEmission> {
        self.pending_emissions.get(terminal_id).cloned()
    }

    pub(crate) fn clear_pending_emission(&mut self, terminal_id: &str) {
        self.pending_emissions.remove(terminal_id);
    }

    pub(crate) fn clear_emitted_state(&mut self, terminal_id: &str) {
        if let Some(entry) = self.terminals.get_mut(terminal_id) {
            entry.emitted = None;
        }
    }

    pub(crate) fn pending_retry_due(&self, terminal_id: &str, now: Instant) -> bool {
        self.pending_retry_after.get(terminal_id).is_none_or(|retry_after| now >= *retry_after)
    }

    pub(crate) fn defer_pending_retry(&mut self, terminal_id: &str, now: Instant) {
        self.pending_retry_after.insert(
            terminal_id.to_string(),
            now + Duration::from_millis(PENDING_RETRY_INTERVAL_MS),
        );
    }

    pub(crate) fn clear_pending_retry(&mut self, terminal_id: &str) {
        self.pending_retry_after.remove(terminal_id);
    }

    /// Fold one evaluated detection. `None` detection means the foreground
    /// process is not a supported agent (or is gone): a live screen-derived
    /// entry is closed with a session-ended-equivalent `Done` emission.
    pub(crate) fn record_detection(
        &mut self,
        terminal_id: &str,
        detection: Option<(&str, Detection)>,
    ) -> Option<ScreenDetectEmission> {
        let entry = self.terminals.entry(terminal_id.to_string()).or_default();
        entry.evaluated_revision = Some(entry.revision);
        let Some((agent, detection)) = detection else {
            let (agent, _) = entry.emitted.take()?;
            return Some(ScreenDetectEmission {
                terminal_id: terminal_id.to_string(),
                agent,
                state: AgentState::Done,
            });
        };
        let asserted = if detection.skip_state_update {
            // Agent-owned viewer (transcript scroll etc.): keep prior state.
            None
        } else {
            match detection.state {
                ScreenState::Working => Some(AgentState::Working),
                ScreenState::Blocked => Some(AgentState::Blocked),
                ScreenState::Idle => Some(AgentState::Idle),
                // A matched unknown-state rule asserts nothing.
                ScreenState::Unknown => None,
            }
        };
        let state = match (asserted, &entry.emitted) {
            (Some(state), _) => state,
            // The screen asserts nothing but the process IS the agent:
            // presence must not wait for a stable screen, so the first
            // emission for a terminal is idle until a later scan refines.
            (None, None) => AgentState::Idle,
            // A live emission keeps its prior state through viewer screens.
            (None, Some(_)) => return None,
        };
        let next = (agent.to_string(), state);
        if entry.emitted.as_ref() == Some(&next) {
            return None;
        }
        entry.emitted = Some(next);
        Some(ScreenDetectEmission {
            terminal_id: terminal_id.to_string(),
            agent: agent.to_string(),
            state,
        })
    }

    /// Drop terminals that left the session. Closed terminals are retired
    /// from the roster by the terminal lifecycle, not by an exit emission.
    pub(crate) fn retain_terminals(&mut self, live: impl Fn(&str) -> bool) {
        self.terminals.retain(|terminal_id, _| live(terminal_id));
        self.pending_emissions.retain(|terminal_id, _| live(terminal_id));
        self.pending_retry_after.retain(|terminal_id, _| live(terminal_id));
    }

    pub(crate) fn catalog_revision_changed(&self, revision: u64) -> bool {
        self.catalog_revision != Some(revision)
    }

    pub(crate) fn note_catalog_revision(&mut self, revision: u64) {
        self.catalog_revision = Some(revision);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{HashSet, hash_map::DefaultHasher};
    use std::hash::BuildHasher;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    #[derive(Clone)]
    struct CountingBuildHasher {
        builds: Arc<AtomicUsize>,
    }

    impl BuildHasher for CountingBuildHasher {
        type Hasher = DefaultHasher;

        fn build_hasher(&self) -> Self::Hasher {
            self.builds.fetch_add(1, Ordering::Relaxed);
            DefaultHasher::new()
        }
    }

    fn detection(state: ScreenState) -> Detection {
        Detection { state, skip_state_update: false, matched_rule: Some("rule".into()) }
    }

    #[test]
    fn screen_detect_tracker_debounces_quiescence_per_revision() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();
        let at = |milliseconds: u64| t0 + Duration::from_millis(milliseconds);

        // A never-evaluated terminal evaluates on first sight.
        assert!(tracker.observe_revision("term_a", 1, t0));
        tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Idle))));
        // An unchanged screen never re-evaluates.
        assert!(!tracker.observe_revision("term_a", 1, at(400)));

        // New output re-arms the debounce; inside the window with a recent
        // evaluation nothing fires.
        assert!(!tracker.observe_revision("term_a", 2, at(500)));
        assert!(!tracker.observe_revision("term_a", 2, at(700)));
        // Quiet long enough: evaluate exactly once per revision.
        assert!(tracker.observe_revision("term_a", 2, at(900)));
        tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Idle))));
        assert!(!tracker.observe_revision("term_a", 2, at(1_100)));
    }

    #[test]
    fn screen_detect_tracker_does_not_bypass_debounce_after_idle_gap() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();
        let at = |milliseconds: u64| t0 + Duration::from_millis(milliseconds);

        assert!(tracker.observe_revision("term_a", 1, at(0)));
        tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Idle))));
        // The old screen is idle for longer than the max-interval pacer.
        assert!(!tracker.observe_revision("term_a", 2, at(2_000)));
        // The new revision must still complete the 300 ms quiet debounce.
        assert!(!tracker.observe_revision("term_a", 2, at(2_200)));
        assert!(tracker.observe_revision("term_a", 2, at(2_300)));
    }

    #[test]
    fn screen_detect_tracker_paces_evaluation_of_never_quiet_spinner_screens() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();
        let at = |milliseconds: u64| t0 + Duration::from_millis(milliseconds);

        assert!(tracker.observe_revision("term_a", 1, t0));
        tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Idle))));

        // A working spinner redraws every ~100ms, so the screen never goes
        // quiet for the debounce window. The pacer still evaluates at 1Hz;
        // without it a working codex would stay idle forever.
        let mut evaluations = 0;
        for tick in 1..=25u64 {
            if tracker.observe_revision("term_a", 1 + tick, at(tick * 100)) {
                evaluations += 1;
                tracker
                    .record_detection("term_a", Some(("codex", detection(ScreenState::Working))));
            }
        }
        assert_eq!(evaluations, 2, "1Hz pacer under 2.5s of continuous output");
        assert!(tracker.has_live_emission("term_a"));
    }

    #[test]
    fn screen_detect_tracker_emits_only_state_edges() {
        let mut tracker = ScreenDetectTracker::default();

        let first =
            tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Working))));
        assert_eq!(
            first,
            Some(ScreenDetectEmission {
                terminal_id: "term_a".into(),
                agent: "codex".into(),
                state: AgentState::Working,
            })
        );
        // Same state again: no event (edge-triggered, never per-scan).
        let repeat =
            tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Working))));
        assert_eq!(repeat, None);
        // Transition to blocked emits.
        let blocked =
            tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Blocked))));
        assert_eq!(blocked.map(|emission| emission.state), Some(AgentState::Blocked));
    }

    #[test]
    fn screen_detect_tracker_closes_departed_agents_with_done() {
        let mut tracker = ScreenDetectTracker::default();
        assert!(
            tracker.record_detection("term_a", None).is_none(),
            "a terminal that never emitted stays silent"
        );

        tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Working))));
        assert!(tracker.has_live_emission("term_a"));
        let done = tracker.record_detection("term_a", None);
        assert_eq!(
            done,
            Some(ScreenDetectEmission {
                terminal_id: "term_a".into(),
                agent: "codex".into(),
                state: AgentState::Done,
            })
        );
        assert!(!tracker.has_live_emission("term_a"));
        assert_eq!(tracker.record_detection("term_a", None), None, "done is an edge too");
    }

    #[test]
    fn screen_detect_tracker_keeps_prior_state_for_viewers_and_unknowns() {
        let mut tracker = ScreenDetectTracker::default();
        tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Working))));

        let viewer = Detection {
            state: ScreenState::Unknown,
            skip_state_update: true,
            matched_rule: Some("transcript_viewer".into()),
        };
        assert_eq!(tracker.record_detection("term_a", Some(("codex", viewer))), None);

        let unknown = detection(ScreenState::Unknown);
        assert_eq!(tracker.record_detection("term_a", Some(("codex", unknown))), None);
        assert!(tracker.has_live_emission("term_a"), "working emission still owns the terminal");
    }

    #[test]
    fn screen_detect_tracker_flags_identity_edges_for_immediate_evaluation() {
        let mut tracker = ScreenDetectTracker::default();
        // Shell pane: no agent means no edge, first scan included.
        assert!(!tracker.note_foreground_agent("term_a", None));
        assert!(!tracker.note_foreground_agent("term_a", None));
        // codex launches: edge fires once, then the identity is steady.
        assert!(tracker.note_foreground_agent("term_a", Some("codex")));
        assert!(!tracker.note_foreground_agent("term_a", Some("codex")));
        // Swapping agents in place is an edge, and so is exiting.
        assert!(tracker.note_foreground_agent("term_a", Some("claude")));
        assert!(tracker.note_foreground_agent("term_a", None));
    }

    #[test]
    fn screen_detect_tracker_replaces_emitted_agent_on_identity_swap() {
        let mut tracker = ScreenDetectTracker::default();
        tracker.note_foreground_agent("term_a", Some("codex"));
        tracker.observe_revision("term_a", 1, Instant::now());
        tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Working))));

        tracker.note_foreground_agent("term_a", Some("claude"));
        let emission = tracker
            .record_detection("term_a", Some(("claude", detection(ScreenState::Idle))))
            .expect("a foreground-agent swap emits the new identity");
        assert_eq!(emission.agent, "claude");
        assert_eq!(emission.state, AgentState::Idle);
    }

    #[test]
    fn screen_detect_tracker_refreshes_process_lookup_each_scan() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();
        assert!(tracker.should_lookup_foreground_agent("term_a", Some(10), t0));
        assert!(!tracker.should_lookup_foreground_agent(
            "term_a",
            Some(10),
            t0 + Duration::from_millis(1),
        ));
        assert!(tracker.should_lookup_foreground_agent(
            "term_a",
            Some(10),
            t0 + Duration::from_millis(PROCESS_LOOKUP_INTERVAL_MS),
        ));
        assert!(tracker.should_lookup_foreground_agent(
            "term_a",
            Some(11),
            t0 + Duration::from_millis(1),
        ));
    }

    #[test]
    fn screen_detect_tracker_backs_off_viewport_retry() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();
        assert!(tracker.observe_revision("term_a", 1, t0));
        tracker.retry_detection("term_a", t0);
        assert!(!tracker.observe_revision(
            "term_a",
            1,
            t0 + Duration::from_millis(VIEWPORT_RETRY_INTERVAL_MS - 1),
        ));
        assert!(tracker.observe_revision(
            "term_a",
            1,
            t0 + Duration::from_millis(VIEWPORT_RETRY_INTERVAL_MS),
        ));
    }

    #[test]
    fn screen_detect_tracker_rearms_stale_emission_once_per_interval() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();
        tracker.observe_revision("term_a", 1, t0);
        tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Idle))));

        assert!(
            tracker.rearm_stale_emission(
                "term_a",
                t0 + Duration::from_millis(SCREEN_REEMIT_INTERVAL_MS),
            )
        );
        assert!(!tracker.rearm_stale_emission(
            "term_a",
            t0 + Duration::from_millis(SCREEN_REEMIT_INTERVAL_MS + 100),
        ));
        assert!(tracker.rearm_stale_emission(
            "term_a",
            t0 + Duration::from_millis(2 * SCREEN_REEMIT_INTERVAL_MS),
        ));
    }

    #[test]
    fn screen_detect_tracker_emits_idle_presence_when_the_first_screen_asserts_nothing() {
        let mut tracker = ScreenDetectTracker::default();
        // First evaluation right after spawn hits a viewer/unknown screen:
        // presence must not wait for a stable screen.
        let viewer = Detection {
            state: ScreenState::Unknown,
            skip_state_update: true,
            matched_rule: Some("transcript_viewer".into()),
        };
        let presence = tracker.record_detection("term_a", Some(("codex", viewer)));
        assert_eq!(
            presence,
            Some(ScreenDetectEmission {
                terminal_id: "term_a".into(),
                agent: "codex".into(),
                state: AgentState::Idle,
            })
        );

        let unknown = detection(ScreenState::Unknown);
        assert_eq!(
            tracker
                .record_detection("term_b", Some(("codex", unknown)))
                .map(|emission| emission.state),
            Some(AgentState::Idle)
        );
    }

    #[test]
    fn screen_detect_tracker_prunes_closed_terminals_with_one_lookup_each() {
        const LIVE_COUNT: usize = 1_024;
        const CLOSED_COUNT: usize = 1_024;

        let mut tracker = ScreenDetectTracker::default();
        let live_ids: Vec<String> = (0..LIVE_COUNT).map(|index| format!("live-{index}")).collect();
        let closed_ids: Vec<String> =
            (0..CLOSED_COUNT).map(|index| format!("closed-{index}")).collect();
        for terminal_id in live_ids.iter().chain(&closed_ids) {
            tracker.record_detection(terminal_id, Some(("codex", detection(ScreenState::Working))));
        }

        let builds = Arc::new(AtomicUsize::new(0));
        let mut live = HashSet::with_capacity_and_hasher(
            LIVE_COUNT,
            CountingBuildHasher { builds: builds.clone() },
        );
        live.extend(live_ids.iter().map(String::as_str));
        builds.store(0, Ordering::Relaxed);

        tracker.retain_terminals(|terminal_id| live.contains(terminal_id));

        assert_eq!(
            builds.load(Ordering::Relaxed),
            LIVE_COUNT + CLOSED_COUNT,
            "retention must make one indexed membership lookup per tracked terminal",
        );
        assert!(live_ids.iter().all(|terminal_id| tracker.has_live_emission(terminal_id)));
        assert!(closed_ids.iter().all(|terminal_id| !tracker.has_live_emission(terminal_id)));
    }
}
