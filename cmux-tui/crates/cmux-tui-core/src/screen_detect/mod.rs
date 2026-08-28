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
/// mid-redraw frames are never matched.
pub(crate) const QUIESCENCE_DEBOUNCE_MS: u64 = 300;

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
    /// the terminal has been quiet for the debounce window and its screen
    /// still needs evaluation for this revision.
    pub(crate) fn observe_revision(&mut self, terminal_id: &str, revision: u64, now: Instant) -> bool {
        let entry = self.terminals.entry(terminal_id.to_string()).or_default();
        if entry.quiet_since.is_none() || entry.revision != revision {
            entry.revision = revision;
            entry.quiet_since = Some(now);
            return false;
        }
        let quiet_since = entry.quiet_since.expect("anchored above");
        now.duration_since(quiet_since).as_millis() as u64 >= QUIESCENCE_DEBOUNCE_MS
            && entry.evaluated_revision != Some(revision)
    }

    /// True when this terminal previously journaled a screen-derived state
    /// that has not been closed out by an exit emission.
    pub(crate) fn has_live_emission(&self, terminal_id: &str) -> bool {
        self.terminals.get(terminal_id).is_some_and(|entry| entry.emitted.is_some())
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
        if detection.skip_state_update {
            // Agent-owned viewer (transcript scroll etc.): keep prior state.
            return None;
        }
        let state = match detection.state {
            ScreenState::Working => AgentState::Working,
            ScreenState::Blocked => AgentState::Blocked,
            ScreenState::Idle => AgentState::Idle,
            // A matched unknown-state rule asserts nothing; keep prior state.
            ScreenState::Unknown => return None,
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
