//! How a hosted terminal's run ended, as far as the owner can prove.
//!
//! Invariant 3 of plans/cmux-next/OWNERSHIP-PRINCIPLES.md: a terminal host's
//! death never closes a workspace or removes a tab; the tab becomes dead.
//! Only a process end (an observed exit status or signal) may detach a
//! terminal's tabs, subject to the keep policies, and only an explicit close
//! removes them otherwise. [`DetachProof`] is the type that carries this
//! rule: the exit-detach projection takes one, and only
//! [`TerminalEnd::ProcessEnded`] and [`TerminalEnd::LaunchFailed`] (the
//! owner abandoning its own unpublished launch, an explicit close) yield
//! one; [`TerminalEnd::HostLost`] never does.
//!
//! The durable exit receipt keeps its existing schema (`outcome`,
//! `exited_at`, `revision`), so older registries open unchanged and older
//! daemons can still read newer ones. A receipt carries no provenance, so a
//! persisted end is classified by its outcome: `exit` and `signal` are
//! process ends; `unknown` is a host loss.

use serde_json::Value;

use crate::terminal_host_protocol::{TerminalExit, TerminalExitOutcome};

/// The end of one terminal incarnation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TerminalEnd {
    /// The terminal's process ended and its end was observed: the host's
    /// live `Exit` frame, the host's durable exit sidecar, or the owner's
    /// wait on a direct child. The outcome is usually an exit status or a
    /// signal; an older host that omits the status still reports a real end.
    /// Its receipt then has an unknown outcome, which a later owner reads as
    /// a host loss; this only matters for a keep-policy terminal, which then
    /// stays dead after a restart instead of degrading to the detach.
    ProcessEnded(TerminalExit),
    /// The host is gone or unreachable and no exit status reached the
    /// owner: it died before adoption, its connection was lost without a
    /// sidecar, or its incarnation or record no longer matches, or a signal
    /// ended it during a session shutdown (`session-shutdown`). The tabs
    /// stay and show the terminal dead until a frontend closes them; the
    /// owner has no respawn policy and gives such a tab no relaunch record
    /// (only keep-layout tabs carry one).
    HostLost(TerminalExit),
    /// The owner abandoned a launch before the terminal was published
    /// (spawn, identity, insert, binding or geometry failure). The owner
    /// removes the runtime itself, so any view is detached with it, as by an
    /// explicit close.
    LaunchFailed(TerminalExit),
}

/// Stable reason codes for a host loss, from the free-form reasons the owner
/// records. Unknown text maps to `other`; the raw text stays in `detail`.
fn host_lost_reason(detail: &str) -> &'static str {
    match detail {
        "missing-host-record" => "missing_record",
        "host-incarnation-mismatch" => "incarnation_mismatch",
        "host-process-ended-before-adoption" => "dead_before_adoption",
        "host-exited-during-adoption" => "died_during_adoption",
        "terminal host ended without a durable exit sidecar" => "died_without_exit_status",
        "terminal exit receipt is missing" => "missing_exit_receipt",
        // A signal exit during a session shutdown (logout): "session-shutdown: signal N".
        _ if detail.starts_with("session-shutdown") => "session_shutdown",
        _ => "other",
    }
}

/// Evidence that a terminal's views may go: its process ended, or its owner
/// abandoned the launch. Constructed only by [`TerminalEnd::detach_proof`];
/// required by the exit-detach projection.
#[derive(Debug, Clone, Copy)]
pub(crate) struct DetachProof(());

impl TerminalEnd {
    pub(crate) fn host_lost(reason: impl Into<String>) -> Self {
        Self::HostLost(TerminalExit::unknown(reason))
    }

    pub(crate) fn launch_failed(reason: impl Into<String>) -> Self {
        Self::LaunchFailed(TerminalExit::unknown(reason))
    }

    /// Classify a persisted terminal exit receipt (`RegistryTerminal::exit`).
    /// A missing or unreadable receipt is a host loss.
    pub(crate) fn from_receipt(receipt: Option<&Value>) -> Self {
        let outcome = receipt.and_then(|receipt| receipt.get("outcome")).and_then(|outcome| {
            serde_json::from_value::<TerminalExitOutcome>(outcome.clone()).ok()
        });
        let exited_at_ms = receipt
            .and_then(|receipt| receipt.get("exited_at"))
            .and_then(Value::as_str)
            .and_then(|value| value.parse().ok())
            .unwrap_or_default();
        match outcome {
            Some(
                outcome @ (TerminalExitOutcome::Exit { .. } | TerminalExitOutcome::Signal { .. }),
            ) => Self::ProcessEnded(TerminalExit { outcome, exited_at_ms }),
            Some(outcome @ TerminalExitOutcome::Unknown { .. }) => {
                Self::HostLost(TerminalExit { outcome, exited_at_ms })
            }
            None => Self::host_lost("terminal exit receipt is missing"),
        }
    }

    pub(crate) fn exit(&self) -> &TerminalExit {
        match self {
            Self::ProcessEnded(exit) | Self::HostLost(exit) | Self::LaunchFailed(exit) => exit,
        }
    }

    /// The typed end clients show (tab JSON `end`; R41,
    /// plans/cmux-next/durable-sessions.md section 7). `kind` is `exited`,
    /// `signaled`, `host_lost` or `launch_failed`; a host loss names a stable
    /// `reason` so a client never words an infrastructure loss as an exit.
    pub(crate) fn wire_json(&self) -> Value {
        match self {
            Self::ProcessEnded(exit) => match &exit.outcome {
                TerminalExitOutcome::Exit { code } => {
                    serde_json::json!({"kind": "exited", "code": code})
                }
                TerminalExitOutcome::Signal { signal, core_dumped } => serde_json::json!({
                    "kind": "signaled",
                    "signal": signal,
                    "core_dumped": core_dumped,
                }),
                // An older host that omits the status still reported a real end.
                TerminalExitOutcome::Unknown { reason } => {
                    serde_json::json!({"kind": "exited", "detail": reason})
                }
            },
            Self::HostLost(exit) => {
                let detail = match &exit.outcome {
                    TerminalExitOutcome::Unknown { reason } => reason.as_str(),
                    TerminalExitOutcome::Exit { .. } | TerminalExitOutcome::Signal { .. } => "",
                };
                serde_json::json!({
                    "kind": "host_lost",
                    "reason": host_lost_reason(detail),
                    "detail": detail,
                })
            }
            Self::LaunchFailed(exit) => {
                let detail = match &exit.outcome {
                    TerminalExitOutcome::Unknown { reason } => reason.clone(),
                    outcome => format!("{outcome:?}"),
                };
                serde_json::json!({"kind": "launch_failed", "detail": detail})
            }
        }
    }

    /// The only way to obtain a [`DetachProof`]. A host loss never yields
    /// one (invariant 3).
    pub(crate) fn detach_proof(&self) -> Option<DetachProof> {
        match self {
            Self::ProcessEnded(_) | Self::LaunchFailed(_) => Some(DetachProof(())),
            Self::HostLost(_) => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn receipt(outcome: Value) -> Value {
        serde_json::json!({"outcome": outcome, "exited_at": "12", "revision": "3"})
    }

    /// R41: clients get a typed end; a host loss is never worded as an exit.
    #[test]
    fn wire_json_types_process_ends_and_host_losses() {
        let exit = |outcome| TerminalExit { outcome, exited_at_ms: 1 };
        assert_eq!(
            TerminalEnd::ProcessEnded(exit(TerminalExitOutcome::Exit { code: 3 })).wire_json(),
            serde_json::json!({"kind": "exited", "code": 3})
        );
        assert_eq!(
            TerminalEnd::ProcessEnded(exit(TerminalExitOutcome::Signal {
                signal: 9,
                core_dumped: false
            }))
            .wire_json(),
            serde_json::json!({"kind": "signaled", "signal": 9, "core_dumped": false})
        );
        for (detail, reason) in [
            ("missing-host-record", "missing_record"),
            ("host-incarnation-mismatch", "incarnation_mismatch"),
            ("host-process-ended-before-adoption", "dead_before_adoption"),
            ("host-exited-during-adoption", "died_during_adoption"),
            ("terminal host ended without a durable exit sidecar", "died_without_exit_status"),
            ("session-shutdown: signal 15", "session_shutdown"),
            ("something new", "other"),
        ] {
            let json = TerminalEnd::host_lost(detail).wire_json();
            assert_eq!(json["kind"], "host_lost");
            assert_eq!(json["reason"], reason, "{detail}");
            assert_eq!(json["detail"], detail);
        }
        assert_eq!(TerminalEnd::launch_failed("no pty").wire_json()["kind"], "launch_failed");
    }

    #[test]
    fn persisted_exit_and_signal_receipts_are_process_ends() {
        for outcome in [
            serde_json::json!({"kind":"exit","code":0}),
            serde_json::json!({"kind":"signal","signal":15,"core_dumped":false}),
        ] {
            let end = TerminalEnd::from_receipt(Some(&receipt(outcome)));
            assert!(matches!(end, TerminalEnd::ProcessEnded(_)), "{end:?}");
            assert_eq!(end.exit().exited_at_ms, 12);
            assert!(end.detach_proof().is_some());
        }
    }

    #[test]
    fn persisted_unknown_or_missing_receipts_are_host_losses() {
        let unknown = receipt(serde_json::json!({
            "kind":"unknown","reason":"host-process-ended-before-adoption",
        }));
        for end in [
            TerminalEnd::from_receipt(Some(&unknown)),
            TerminalEnd::from_receipt(None),
            TerminalEnd::from_receipt(Some(&serde_json::json!({"reason":"legacy"}))),
        ] {
            assert!(matches!(end, TerminalEnd::HostLost(_)), "{end:?}");
            assert!(end.detach_proof().is_none());
        }
    }

    #[test]
    fn a_host_loss_never_yields_a_detach_proof() {
        let real = TerminalExit::now(TerminalExitOutcome::Exit { code: 1 });
        assert!(TerminalEnd::ProcessEnded(real).detach_proof().is_some());
        // An older host's Exit frame without a status is still a real end.
        assert!(
            TerminalEnd::ProcessEnded(TerminalExit::unknown("omitted")).detach_proof().is_some()
        );
        assert!(TerminalEnd::host_lost("lost").detach_proof().is_none());
        // The owner abandoning its own launch detaches like a close.
        assert!(TerminalEnd::launch_failed("spawn").detach_proof().is_some());
    }
}
