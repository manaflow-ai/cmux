//! Screen-derived agent lifecycle detection.
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

use std::collections::{HashMap, HashSet, VecDeque};
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

/// A failed viewport read must not turn the scanner into a hot retry loop.
/// Backoff is short enough to recover after a PTY transition and capped so a
/// permanently inaccessible terminal has bounded work.
const SCREEN_READ_RETRY_INITIAL_MS: u64 = 100;
const SCREEN_READ_RETRY_MAX_MS: u64 = 2_000;

/// Foreground process identity is sampled independently from output. A
/// bounded interval prevents one terminal per 100 ms from becoming a procfs
/// storm while still making process swaps visible promptly.
const FOREGROUND_CHECK_INTERVAL_MS: u64 = 500;
const FOREGROUND_CHECK_RETRY_MAX_MS: u64 = 2_000;

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
    /// Earliest time at which a failed screen read may be retried.
    retry_not_before: Option<Instant>,
    /// Exponential retry delay, capped by `SCREEN_READ_RETRY_MAX_MS`.
    retry_delay_ms: u64,
    /// Earliest time at which foreground process identity may be sampled.
    identity_check_not_before: Option<Instant>,
    /// Exponential retry delay for inaccessible process metadata.
    identity_check_delay_ms: u64,
    /// Agent the foreground process matched on the previous scan; identity
    /// edges trigger immediate evaluation, before any quiescence.
    foreground_agent: Option<String>,
    /// Whether `foreground_agent` came from a successful process lookup. A
    /// missing value can mean either a known shell or no sample yet.
    foreground_identity_known: bool,
    /// Last (agent, state) journaled; emissions are edges over this.
    emitted: Option<(String, AgentState)>,
}

/// Pure edge-trigger state for the scanner. All timing is passed in, so
/// tests drive it deterministically.
#[derive(Debug, Default)]
pub(crate) struct ScreenDetectTracker {
    terminals: HashMap<String, TrackedTerminal>,
    /// Stable logical order for foreground lookups. The live catalog is a
    /// HashMap, so its vector index can change whenever a terminal is added or
    /// removed. Keeping IDs here makes the lookup budget fair across reorder.
    scan_order: VecDeque<String>,
}

impl ScreenDetectTracker {
    /// Record the terminal's current output revision. Returns `true` when
    /// the screen changed since the last evaluation and either output has
    /// been quiet for the debounce window or the max-interval pacer is due
    /// (a never-quiet spinner screen still evaluates at 1Hz; quiescence
    /// alone starves detection during the exact phase it must report). A
    /// `true` return arms the pacer: the caller always evaluates then.
    pub(crate) fn observe_revision(
        &mut self,
        terminal_id: &str,
        revision: u64,
        now: Instant,
    ) -> bool {
        let entry = self.terminals.entry(terminal_id.to_string()).or_default();
        if entry.quiet_since.is_none() || entry.revision != revision {
            entry.revision = revision;
            entry.quiet_since = Some(now);
        }
        if entry.evaluated_revision == Some(entry.revision) {
            return false;
        }
        if entry.retry_not_before.is_some_and(|not_before| now < not_before) {
            return false;
        }
        // A failed viewport read explicitly arms a retry. Once that
        // deadline is reached, retry the pending revision even when the
        // terminal has not been quiet for the debounce window.
        let retry_due = entry.retry_not_before.take().is_some();
        if retry_due {
            entry.last_evaluated_at = Some(now);
            return true;
        }
        let quiet_since = entry.quiet_since.expect("anchored above");
        let quiesced = now.duration_since(quiet_since).as_millis() as u64 >= QUIESCENCE_DEBOUNCE_MS;
        let overdue = entry.last_evaluated_at.is_none_or(|evaluated_at| {
            now.duration_since(evaluated_at).as_millis() as u64 >= MAX_EVAL_INTERVAL_MS
        });
        if quiesced || overdue {
            entry.last_evaluated_at = Some(now);
            return true;
        }
        false
    }

    /// Record a failed viewport read. The revision remains unevaluated, but
    /// retries follow an explicit bounded backoff instead of every scanner
    /// tick.
    pub(crate) fn note_evaluation_failure(&mut self, terminal_id: &str, now: Instant) {
        let entry = self.terminals.entry(terminal_id.to_string()).or_default();
        let delay_ms = if entry.retry_delay_ms == 0 {
            SCREEN_READ_RETRY_INITIAL_MS
        } else {
            entry.retry_delay_ms.saturating_mul(2).min(SCREEN_READ_RETRY_MAX_MS)
        };
        entry.retry_delay_ms = delay_ms;
        entry.retry_not_before = Some(now + Duration::from_millis(delay_ms));
        entry.last_evaluated_at = Some(now);
    }

    /// Return whether the foreground process should be resolved now. The
    /// first lookup is immediate; later lookups are paced per terminal.
    pub(crate) fn foreground_check_due(&self, terminal_id: &str, now: Instant) -> bool {
        self.terminals
            .get(terminal_id)
            .is_none_or(|entry| entry.identity_check_not_before.is_none_or(|at| now >= at))
    }

    /// Return the last successful identity lookup. `Some(None)` means a
    /// known non-agent shell, while `None` means that no usable sample exists.
    pub(crate) fn cached_foreground_identity(&self, terminal_id: &str) -> Option<Option<&str>> {
        let entry = self.terminals.get(terminal_id)?;
        entry.foreground_identity_known.then(|| entry.foreground_agent.as_deref())
    }

    /// Keep the last successful identity when platform metadata is
    /// temporarily inaccessible, and schedule a bounded retry.
    pub(crate) fn note_foreground_unavailable(&mut self, terminal_id: &str, now: Instant) {
        self.note_foreground_check(terminal_id, now, true);
    }

    /// Arm the next foreground lookup. Inaccessible process metadata backs
    /// off exponentially because the kernel can keep a process entry
    /// unavailable for the lifetime of a terminal.
    pub(crate) fn note_foreground_check(&mut self, terminal_id: &str, now: Instant, retry: bool) {
        let entry = self.terminals.entry(terminal_id.to_string()).or_default();
        let delay_ms = if retry {
            if entry.identity_check_delay_ms == 0 {
                FOREGROUND_CHECK_INTERVAL_MS
            } else {
                entry.identity_check_delay_ms.saturating_mul(2).min(FOREGROUND_CHECK_RETRY_MAX_MS)
            }
        } else {
            FOREGROUND_CHECK_INTERVAL_MS
        };
        entry.identity_check_delay_ms = delay_ms;
        entry.identity_check_not_before = Some(now + Duration::from_millis(delay_ms));
    }

    /// Return live terminal indices in stable logical order and reserve the
    /// next lookup slice. The catalog's HashMap order may change between
    /// passes, so indexing directly into its snapshot can starve a terminal
    /// that is repeatedly moved past the current budget window.
    pub(crate) fn scan_indices(
        &mut self,
        terminal_ids: &[&str],
        lookup_budget: usize,
    ) -> Vec<usize> {
        if terminal_ids.is_empty() {
            self.scan_order.clear();
            return Vec::new();
        }

        let live_ids = terminal_ids.iter().copied().collect::<HashSet<_>>();
        self.scan_order.retain(|terminal_id| live_ids.contains(terminal_id.as_str()));
        let mut queued_ids = self.scan_order.iter().cloned().collect::<HashSet<_>>();
        for terminal_id in terminal_ids {
            if queued_ids.insert((*terminal_id).to_owned()) {
                self.scan_order.push_back((*terminal_id).to_owned());
            }
        }

        let index_by_id = terminal_ids
            .iter()
            .enumerate()
            .map(|(index, terminal_id)| (*terminal_id, index))
            .collect::<HashMap<_, _>>();
        let mut indices = Vec::with_capacity(terminal_ids.len());
        for terminal_id in &self.scan_order {
            if let Some(index) = index_by_id.get(terminal_id.as_str()) {
                indices.push(*index);
            }
        }

        let step = lookup_budget.max(1).min(self.scan_order.len());
        self.scan_order.rotate_left(step);
        indices
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
        if entry.foreground_identity_known && entry.foreground_agent.as_deref() == agent {
            return false;
        }
        entry.foreground_identity_known = true;
        entry.foreground_agent = agent.map(str::to_string);
        // The identity edge forces an immediate screen read. If that read
        // fails, keep the revision pending so the next scan retries it even
        // when the PTY produced no new bytes.
        entry.evaluated_revision = None;
        entry.last_evaluated_at = None;
        entry.retry_not_before = None;
        entry.retry_delay_ms = 0;
        true
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
        entry.retry_not_before = None;
        entry.retry_delay_ms = 0;
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
    fn screen_detect_tracker_backs_off_failed_screen_reads() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();

        assert!(tracker.observe_revision("term_a", 1, t0));
        tracker.note_evaluation_failure("term_a", t0);
        assert!(!tracker.observe_revision("term_a", 1, t0 + Duration::from_millis(99)));
        assert!(tracker.observe_revision("term_a", 1, t0 + Duration::from_millis(100)));

        tracker.note_evaluation_failure("term_a", t0 + Duration::from_millis(100));
        assert!(!tracker.observe_revision("term_a", 1, t0 + Duration::from_millis(299)));
        assert!(tracker.observe_revision("term_a", 1, t0 + Duration::from_millis(300)));
    }

    #[test]
    fn foreground_identity_cache_distinguishes_unknown_shells_and_paces_lookups() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();

        assert!(tracker.foreground_check_due("term_a", t0));
        tracker.note_foreground_check("term_a", t0, false);
        tracker.note_foreground_agent("term_a", None);
        assert_eq!(tracker.cached_foreground_identity("term_a"), Some(None));
        assert!(!tracker.foreground_check_due("term_a", t0 + Duration::from_millis(499)));
        assert!(tracker.foreground_check_due("term_a", t0 + Duration::from_millis(500)));

        // A failed platform lookup keeps the last successful identity. It
        // cannot spuriously close an agent row, and retries back off.
        tracker.note_foreground_agent("term_a", Some("codex"));
        tracker.note_foreground_check("term_a", t0 + Duration::from_millis(500), false);
        tracker.note_foreground_unavailable("term_a", t0 + Duration::from_millis(500));
        assert_eq!(tracker.cached_foreground_identity("term_a"), Some(Some("codex")));
        assert!(!tracker.foreground_check_due("term_a", t0 + Duration::from_millis(999)));
        assert!(tracker.foreground_check_due("term_a", t0 + Duration::from_millis(1_000)));
    }

    #[test]
    fn scan_queue_advances_by_lookup_budget_for_bounded_batches() {
        let mut tracker = ScreenDetectTracker::default();
        let terminal_ids = (0..100).map(|index| format!("term_{index:03}")).collect::<Vec<_>>();
        let terminal_refs = terminal_ids.iter().map(String::as_str).collect::<Vec<_>>();
        assert_eq!(&tracker.scan_indices(&terminal_refs, 64)[..3], &[0, 1, 2]);
        assert_eq!(&tracker.scan_indices(&terminal_refs, 64)[..3], &[64, 65, 66]);
        assert_eq!(&tracker.scan_indices(&terminal_refs, 64)[..3], &[28, 29, 30]);
        assert!(tracker.scan_indices(&[], 64).is_empty());
        assert_eq!(&tracker.scan_indices(&terminal_refs, 64)[..3], &[0, 1, 2]);
    }

    #[test]
    fn scan_cursor_covers_large_catalog_before_repeating_a_lookup_slice() {
        let mut tracker = ScreenDetectTracker::default();
        let terminal_count = 1_000;
        let lookup_budget = 64;
        let passes = terminal_count.div_ceil(lookup_budget);
        let mut covered = std::collections::HashSet::new();

        let terminal_ids =
            (0..terminal_count).map(|index| format!("term_{index:04}")).collect::<Vec<_>>();
        let terminal_refs = terminal_ids.iter().map(String::as_str).collect::<Vec<_>>();
        for _ in 0..passes {
            let indices = tracker.scan_indices(&terminal_refs, lookup_budget);
            for &index in &indices[..lookup_budget] {
                covered.insert(index);
            }
        }

        assert_eq!(covered.len(), terminal_count);
    }

    #[test]
    fn scan_queue_preserves_fairness_when_catalog_order_changes() {
        let mut tracker = ScreenDetectTracker::default();
        let first_catalog = ["term_a", "term_b", "term_c", "term_d", "term_e", "term_f"];
        let reordered_catalog = ["term_f", "term_e", "term_d", "term_c", "term_b", "term_a"];

        let first_indices = tracker.scan_indices(&first_catalog, 2);
        assert_eq!(&first_indices[..2], &[0, 1]);
        let second_indices = tracker.scan_indices(&reordered_catalog, 2);
        assert_eq!(&second_indices[..2], &[3, 2]);

        let mut seen = std::collections::HashSet::new();
        for &index in &first_indices[..2] {
            seen.insert(first_catalog[index]);
        }
        for &index in &second_indices[..2] {
            seen.insert(reordered_catalog[index]);
        }
        let third_indices = tracker.scan_indices(&first_catalog, 2);
        for &index in &third_indices[..2] {
            seen.insert(first_catalog[index]);
        }
        assert_eq!(seen.len(), first_catalog.len());
    }

    #[test]
    fn identity_edge_stays_pending_when_screen_evaluation_fails() {
        let mut tracker = ScreenDetectTracker::default();
        let now = Instant::now();
        assert!(tracker.observe_revision("term_a", 7, now));
        // The scanner would normally call record_detection after a successful
        // viewport read. Simulate the failed read by leaving it unevaluated.
        assert!(tracker.note_foreground_agent("term_a", Some("codex")));
        assert!(tracker.note_foreground_agent("term_a", Some("claude")));
        assert!(tracker.observe_revision("term_a", 7, now + Duration::from_millis(1)));
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
