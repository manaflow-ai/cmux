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
