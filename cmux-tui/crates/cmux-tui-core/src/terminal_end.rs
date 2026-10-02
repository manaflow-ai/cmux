//! How a hosted terminal's run ended, as far as the owner can prove.
//!
//! Invariant 3 of plans/cmux-next/OWNERSHIP-PRINCIPLES.md: a terminal host's
//! death never closes a workspace or removes a tab; the tab becomes dead.
//! Only a process end (an observed exit status or signal) may detach a
//! terminal's tabs, subject to the keep policies, and only an explicit close
//! removes them otherwise. [`DetachProof`] is the type that carries this
//! rule: the exit-detach projection takes one, and only
//! [`TerminalEnd::ProcessEnded`] yields one.
//!
//! The durable exit receipt keeps its existing schema (`outcome`,
//! `exited_at`, `revision`), so older registries open unchanged and older
//! daemons can still read newer ones. A receipt carries no provenance, so a
//! persisted end is classified by its outcome: `exit` and `signal` are
//! process ends; `unknown` is a host loss.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

use crate::terminal_host_protocol::{TerminalExit, TerminalExitOutcome};

/// How long before the recorded shutdown start a signal exit still counts
/// as part of the shutdown. Logout signals every process of the session at
/// once, so a shell can die a moment before the owner records the start.
pub(crate) const SESSION_SHUTDOWN_LEAD_MS: u64 = 2_000;

/// The end of one terminal incarnation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TerminalEnd {
    /// The terminal's process ended and its end was observed: the host's
    /// live `Exit` frame, the host's durable exit sidecar, or the owner's
    /// wait on a direct child. The outcome is usually an exit status or a
    /// signal; an older host that omits the status still reports a real end.
    ProcessEnded(TerminalExit),
    /// The host is gone or unreachable and no exit status reached the
    /// owner: it died before adoption, its connection was lost without a
    /// sidecar, or its incarnation or record no longer matches. The tabs stay
    /// and show the terminal dead; no respawn policy exists in the owner, so
    /// a frontend restarts it (as for keep-layout tabs).
    HostLost(TerminalExit),
    /// The owner abandoned a launch before the terminal was published
    /// (spawn, identity, insert or geometry failure). No tab shows it yet;
    /// any view that does stays and shows it dead.
    LaunchFailed(TerminalExit),
}

/// Evidence that a terminal's process ended. Constructed only by
/// [`TerminalEnd::detach_proof`]; required by the exit-detach projection.
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

    /// The only way to obtain a [`DetachProof`].
    pub(crate) fn detach_proof(&self) -> Option<DetachProof> {
        matches!(self, Self::ProcessEnded(_)).then_some(DetachProof(()))
    }
}

/// When the owner's session was shutting down, as far as this owner knows
/// (`session-shutdown`, plans/cmux-next/ownership.md section 3.2).
///
/// A process end by signal during a session shutdown (logout, reboot,
/// `SIGTERM` to the daemon, `server stop`) is a host loss, not a real end:
/// the session ended around the shell. Exits by signal while the owner runs
/// normally (a user's `kill`, Ctrl-C ending the shell) and every exit with
/// a status stay real ends.
#[derive(Debug, Default)]
pub(crate) struct SessionShutdownClock {
    /// From the previous owner's recorded shutdown start to this owner's
    /// start, in Unix milliseconds.
    previous: Option<(u64, u64)>,
    /// This owner's own shutdown start; zero while it runs.
    own_since_ms: AtomicU64,
}

impl SessionShutdownClock {
    pub(crate) fn new(previous_shutdown_ms: Option<u64>, started_at_ms: u64) -> Self {
        Self {
            previous: previous_shutdown_ms.map(|start| (start, started_at_ms.max(start))),
            own_since_ms: AtomicU64::new(0),
        }
    }

    /// Mark the start of this owner's shutdown. Returns the start to record
    /// durably the first time, `None` when the shutdown already began.
    pub(crate) fn begin(&self, now_ms: u64) -> Option<u64> {
        let now_ms = now_ms.max(1);
        self.own_since_ms
            .compare_exchange(0, now_ms, Ordering::AcqRel, Ordering::Acquire)
            .ok()
            .map(|_| now_ms)
    }

    fn during_shutdown(&self, exited_at_ms: u64) -> bool {
        let previous = self.previous.is_some_and(|(start, end)| {
            (start.saturating_sub(SESSION_SHUTDOWN_LEAD_MS)..end).contains(&exited_at_ms)
        });
        let own = self.own_since_ms.load(Ordering::Acquire);
        previous || (own != 0 && exited_at_ms >= own.saturating_sub(SESSION_SHUTDOWN_LEAD_MS))
    }

    /// Reclassify a process end by signal during a session shutdown as a
    /// host loss. The receipt keeps the signal in its reason and an unknown
    /// outcome, so every later owner classifies it the same way.
    pub(crate) fn classify(&self, end: TerminalEnd) -> TerminalEnd {
        match end {
            TerminalEnd::ProcessEnded(TerminalExit {
                outcome: TerminalExitOutcome::Signal { signal, .. },
                exited_at_ms,
            }) if self.during_shutdown(exited_at_ms) => TerminalEnd::HostLost(TerminalExit {
                outcome: TerminalExitOutcome::Unknown {
                    reason: format!("session-shutdown: signal {signal}"),
                },
                exited_at_ms,
            }),
            other => other,
        }
    }
}

/// The current time in Unix milliseconds, the clock of exit receipts.
pub(crate) fn unix_now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u128::from(u64::MAX)) as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn signal_end(exited_at_ms: u64) -> TerminalEnd {
        TerminalEnd::ProcessEnded(TerminalExit {
            outcome: TerminalExitOutcome::Signal { signal: 1, core_dumped: false },
            exited_at_ms,
        })
    }

    fn exit_end(exited_at_ms: u64) -> TerminalEnd {
        TerminalEnd::ProcessEnded(TerminalExit {
            outcome: TerminalExitOutcome::Exit { code: 0 },
            exited_at_ms,
        })
    }

    #[test]
    fn signal_exits_during_the_previous_shutdown_are_host_losses() {
        let clock = SessionShutdownClock::new(Some(100_000), 200_000);
        for at in [100_000 - SESSION_SHUTDOWN_LEAD_MS, 100_000, 150_000, 199_999] {
            let end = clock.classify(signal_end(at));
            assert!(matches!(end, TerminalEnd::HostLost(_)), "{at}: {end:?}");
            assert!(end.detach_proof().is_none());
            assert_eq!(end.exit().exited_at_ms, at);
            let receipt = serde_json::json!({
                "outcome": end.exit().outcome,
                "exited_at": at.to_string(),
                "revision": "1",
            });
            assert!(matches!(TerminalEnd::from_receipt(Some(&receipt)), TerminalEnd::HostLost(_)));
        }
        // Before the shutdown or during this owner's run: a real end.
        for at in [100_000 - SESSION_SHUTDOWN_LEAD_MS - 1, 200_000, 300_000] {
            assert!(matches!(clock.classify(signal_end(at)), TerminalEnd::ProcessEnded(_)));
        }
        // An exit with a status is always a real end.
        assert!(matches!(clock.classify(exit_end(150_000)), TerminalEnd::ProcessEnded(_)));
    }

    #[test]
    fn signal_exits_after_this_owner_began_shutting_down_are_host_losses() {
        let clock = SessionShutdownClock::new(None, 1_000);
        assert!(matches!(clock.classify(signal_end(50_000)), TerminalEnd::ProcessEnded(_)));
        assert_eq!(clock.begin(50_000), Some(50_000));
        assert_eq!(clock.begin(60_000), None, "the earliest start wins");
        assert!(matches!(clock.classify(signal_end(50_001)), TerminalEnd::HostLost(_)));
        assert!(matches!(clock.classify(exit_end(50_001)), TerminalEnd::ProcessEnded(_)));
        assert!(matches!(
            clock.classify(signal_end(50_000 - SESSION_SHUTDOWN_LEAD_MS - 1)),
            TerminalEnd::ProcessEnded(_)
        ));
    }

    fn receipt(outcome: Value) -> Value {
        serde_json::json!({"outcome": outcome, "exited_at": "12", "revision": "3"})
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
    fn only_a_process_end_yields_a_detach_proof() {
        let real = TerminalExit::now(TerminalExitOutcome::Exit { code: 1 });
        assert!(TerminalEnd::ProcessEnded(real).detach_proof().is_some());
        // An older host's Exit frame without a status is still a real end.
        assert!(
            TerminalEnd::ProcessEnded(TerminalExit::unknown("omitted")).detach_proof().is_some()
        );
        assert!(TerminalEnd::host_lost("lost").detach_proof().is_none());
        assert!(TerminalEnd::launch_failed("spawn").detach_proof().is_none());
    }
}
