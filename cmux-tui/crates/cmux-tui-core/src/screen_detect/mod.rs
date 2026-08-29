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

use std::collections::HashMap;
use std::time::Instant;

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
    /// Agent the foreground process matched on the previous scan; identity
    /// edges trigger immediate evaluation, before any quiescence.
    foreground_agent: Option<String>,
    /// Last (agent, state) journaled; emissions are edges over this.
    emitted: Option<(String, AgentState)>,
}

/// Pure edge-trigger state for the scanner. All timing is passed in, so
/// tests drive it deterministically.
#[derive(Debug, Default)]
pub(crate) struct ScreenDetectTracker {
    terminals: HashMap<String, TrackedTerminal>,
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
        if entry.foreground_agent.as_deref() == agent {
            return false;
        }
        entry.foreground_agent = agent.map(str::to_string);
        true
    }

    /// Prepare one evaluated detection. The returned emission is a proposal:
    /// callers must append it to the journal and call `commit_detection` only
    /// after that append succeeds. This keeps in-memory edge state aligned
    /// with the durable journal when storage is unavailable.
    pub(crate) fn prepare_detection(
        &mut self,
        terminal_id: &str,
        detection: Option<(&str, Detection)>,
    ) -> Option<ScreenDetectEmission> {
        let entry = self.terminals.entry(terminal_id.to_string()).or_default();
        let Some((agent, detection)) = detection else {
            let (agent, _) = entry.emitted.as_ref()?.clone();
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
        Some(ScreenDetectEmission {
            terminal_id: terminal_id.to_string(),
            agent: agent.to_string(),
            state,
        })
    }

    /// Record a detection for callers that do not have a separate durable
    /// append. The scanner uses `prepare_detection` plus `commit_detection`
    /// so a failed journal append remains retryable.
    pub(crate) fn record_detection(
        &mut self,
        terminal_id: &str,
        detection: Option<(&str, Detection)>,
    ) -> Option<ScreenDetectEmission> {
        let emission = self.prepare_detection(terminal_id, detection);
        self.commit_detection(terminal_id, emission.as_ref());
        emission
    }

    /// Commit a prepared detection after its journal append succeeds. A
    /// missing emission still marks the revision evaluated, which prevents
    /// repeated scans of an unchanged screen.
    pub(crate) fn commit_detection(
        &mut self,
        terminal_id: &str,
        emission: Option<&ScreenDetectEmission>,
    ) {
        let entry = self.terminals.entry(terminal_id.to_string()).or_default();
        entry.evaluated_revision = Some(entry.revision);
        let Some(emission) = emission else { return };
        debug_assert_eq!(emission.terminal_id, terminal_id);
        if emission.state == AgentState::Done {
            if entry
                .emitted
                .as_ref()
                .is_some_and(|(agent, _)| agent == &emission.agent)
            {
                entry.emitted = None;
            }
        } else {
            entry.emitted = Some((emission.agent.clone(), emission.state));
        }
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
    use std::time::Duration;

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
    fn prepared_emission_is_retryable_until_the_journal_append_commits() {
        let mut tracker = ScreenDetectTracker::default();
        let first = tracker.prepare_detection(
            "term_a",
            Some(("codex", detection(ScreenState::Working))),
        );
        assert!(first.is_some());
        assert!(!tracker.has_live_emission("term_a"));

        // A failed append does not consume the edge. The next scan can make
        // the same proposal again.
        let retry = tracker.prepare_detection(
            "term_a",
            Some(("codex", detection(ScreenState::Working))),
        );
        assert_eq!(retry, first);

        tracker.commit_detection("term_a", retry.as_ref());
        assert!(tracker.has_live_emission("term_a"));
        assert_eq!(
            tracker.prepare_detection("term_a", Some(("codex", detection(ScreenState::Working)))),
            None
        );
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
    fn screen_detect_tracker_drops_closed_terminals_silently() {
        let mut tracker = ScreenDetectTracker::default();
        tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Working))));
        tracker.retain_terminals(|terminal_id| terminal_id != "term_a");
        assert!(!tracker.has_live_emission("term_a"));
    }
}
