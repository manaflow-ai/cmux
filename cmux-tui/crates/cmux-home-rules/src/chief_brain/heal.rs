//! `ChiefAcpmuxHeal`: what a Chief-home acpmux that runs from a replaced bundle does.

use serde::{Deserialize, Serialize};

/// `AcpmuxChiefHandoff.handOffReplaced`'s answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HandoffAction {
    Keep,
    WaitForHost,
    HandOff,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum HealEffect {
    /// Detach `finishAfterTurn` (driven by `heal_finish_step`).
    FinishAfterTurn,
    /// `stopHost(home:)` (SIGTERM the host, wait up to 15 s for its exit).
    StopHost,
    /// `ensureHost()`.
    EnsureHost,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HealRequest {
    pub action: HandoffAction,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HealReply {
    pub effects: Vec<HealEffect>,
    /// `heal()`'s answer: healed now.
    pub healed: bool,
}

/// `heal()` after `handOffReplaced` answered.
pub fn heal(action: HandoffAction) -> HealReply {
    match action {
        HandoffAction::Keep => HealReply { effects: Vec::new(), healed: false },
        HandoffAction::WaitForHost => {
            HealReply { effects: vec![HealEffect::FinishAfterTurn], healed: false }
        }
        HandoffAction::HandOff => {
            HealReply { effects: vec![HealEffect::StopHost, HealEffect::EnsureHost], healed: true }
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FinishPhase {
    /// Waiting for the host to end its turn and exit.
    #[default]
    WaitingForExit,
    /// Asking `handOffReplaced(waitFor: { false })` again.
    HandingOff,
    StoppingHost,
    EnsuringHost,
    Done,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum FinishEvent {
    /// The host exit wait answered (`exited` false: it never did).
    #[serde(rename_all = "camelCase")]
    HostExit { exited: bool },
    /// `handOffReplaced` again: `handOff` true when it answered `.handOff`.
    #[serde(rename_all = "camelCase")]
    HandOff { handed_off: bool },
    /// The last effect (`stopHost`, `ensureHost`) finished.
    Done,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum FinishEffect {
    /// `handOffReplaced(waitFor: { false })`; send `handOff`.
    HandOff,
    StopHost,
    EnsureHost,
    #[serde(rename_all = "camelCase")]
    Log {
        error: bool,
        message: String,
    },
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FinishRequest {
    #[serde(default)]
    pub phase: FinishPhase,
    pub event: FinishEvent,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FinishReply {
    pub phase: FinishPhase,
    pub effects: Vec<FinishEffect>,
}

/// One step of `finishAfterTurn`.
pub fn finish_step(phase: FinishPhase, event: FinishEvent) -> (FinishPhase, Vec<FinishEffect>) {
    use FinishPhase as P;
    match (phase, event) {
        (P::WaitingForExit, FinishEvent::HostExit { exited: false }) => (
            P::Done,
            vec![FinishEffect::Log {
                error: true,
                message: "Chief host did not end its turn in time; its acpmux keeps running from a replaced bundle".into(),
            }],
        ),
        (P::WaitingForExit, FinishEvent::HostExit { exited: true }) => {
            (P::HandingOff, vec![FinishEffect::HandOff])
        }
        (P::HandingOff, FinishEvent::HandOff { handed_off: true }) => (
            P::StoppingHost,
            vec![
                FinishEffect::Log {
                    error: false,
                    message: "Chief acpmux handed off after the Chief host's turn ended".into(),
                },
                FinishEffect::StopHost,
            ],
        ),
        (P::HandingOff, FinishEvent::HandOff { handed_off: false })
        | (P::StoppingHost, FinishEvent::Done) => (P::EnsuringHost, vec![FinishEffect::EnsureHost]),
        (P::EnsuringHost, FinishEvent::Done) => (P::Done, Vec::new()),
        (phase, _) => (phase, Vec::new()),
    }
}
