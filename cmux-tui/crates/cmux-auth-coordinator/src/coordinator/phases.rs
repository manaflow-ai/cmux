//! Phase runs: which call may start, what its deadline or a caller's
//! cancellation leaves parked, which runs a sign-out or a sign-in cancels, and
//! what a validation or token operation that outlived a sign-out does to the
//! session (Swift's four `AuthCoordinator+*Timeout.swift` runners).
//!
//! The caller keeps the clock and the task handles: it asks for a run id with
//! [`Event::PhaseStartRequested`](crate::Event::PhaseStartRequested), races the operation against its deadline,
//! and reports the deadline, its own cancellation, the operation's end and
//! the run's end. Time is monotonic nanoseconds, passed in.

use std::collections::BTreeMap;

use super::Coordinator;
use crate::event::{AuthFailure, Effect};
use crate::phase::{AuthPhase, PhaseRunner, SIGN_OUT_CLEARED_PHASES};

/// One started phase run and the session it started in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct PhaseRun {
    phase: AuthPhase,
    runner: PhaseRunner,
    generation: u64,
    sign_out_epoch: u64,
    store_write_high_water: u64,
}

/// A token-touching phase whose run hit its deadline (or was cancelled by its
/// caller) while still running: the phase refuses new runs until that run
/// ends or `expires_at` passes with it ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct TokenGate {
    id: u64,
    expires_at: u64,
}

pub(super) type TokenGates = BTreeMap<AuthPhase, TokenGate>;

impl Coordinator {
    pub(super) fn on_phase_start_requested(
        &mut self,
        phase: AuthPhase,
        now: u64,
        fx: &mut Vec<Effect>,
    ) {
        self.phase_run_counter = self.phase_run_counter.wrapping_add(1);
        let id = self.phase_run_counter;
        let runner = phase.runner();
        let admitted = match runner {
            PhaseRunner::Validation
            | PhaseRunner::Exchange
            | PhaseRunner::Prompt { blocks_retries_while_timed_out: true } => {
                self.phase_damper.begin(phase, id, now)
            }
            PhaseRunner::TokenTouching => {
                if let Some(gate) = self.token_gates.get(&phase)
                    && now >= gate.expires_at
                    && !self.phase_runs.contains_key(&gate.id)
                {
                    self.token_gates.remove(&phase);
                }
                !self.token_gates.contains_key(&phase)
            }
            PhaseRunner::Prompt { blocks_retries_while_timed_out: false }
            | PhaseRunner::PostSignIn => true,
        };
        if !admitted {
            fx.push(Effect::PhaseRefused { phase });
            return;
        }
        self.phase_runs.insert(
            id,
            PhaseRun {
                phase,
                runner,
                generation: self.session_generation(),
                sign_out_epoch: self.generations.sign_out_epoch,
                store_write_high_water: self.generations.store_write_high_water,
            },
        );
        fx.push(Effect::PhaseStarted { id, phase });
    }

    /// The run's deadline won the race (`by_caller: false`), or the caller
    /// waiting on it was cancelled (`by_caller: true`).
    pub(super) fn on_phase_interrupted(&mut self, id: u64, by_caller: bool, now: u64) {
        let Some(run) = self.phase_runs.get(&id).copied() else {
            return;
        };
        match run.runner {
            // A cancelled validation caller parks nothing: only its deadline does.
            PhaseRunner::Validation if by_caller => {}
            PhaseRunner::Validation
            | PhaseRunner::Exchange
            | PhaseRunner::Prompt { blocks_retries_while_timed_out: true } => {
                self.phase_damper.mark_timed_out(run.phase, id, now);
            }
            PhaseRunner::TokenTouching => {
                let expires_at = now.saturating_add(self.token_gate_reset_nanos);
                self.token_gates.insert(run.phase, TokenGate { id, expires_at });
            }
            PhaseRunner::Prompt { blocks_retries_while_timed_out: false }
            | PhaseRunner::PostSignIn => {}
        }
    }

    /// The run's task finished, whether or not it won its race.
    pub(super) fn on_phase_ended(&mut self, id: u64) {
        let Some(run) = self.phase_runs.remove(&id) else {
            return;
        };
        self.phase_damper.end(run.phase, id);
        if self.token_gates.get(&run.phase).is_some_and(|gate| gate.id == id) {
            self.token_gates.remove(&run.phase);
        }
    }

    pub(super) fn supersede_timed_out_phases(&mut self) {
        self.phase_damper.supersede_timed_out();
        self.token_gates.clear();
    }

    /// The live runs of these runners, oldest first.
    pub(super) fn live_runs(&self, wanted: &[PhaseRunner]) -> Vec<u64> {
        self.phase_runs
            .iter()
            .filter(|(_, run)| wanted.contains(&run.runner))
            .map(|(id, _)| *id)
            .collect()
    }

    /// Sign-out: every run that can write tokens or run signed-in work is
    /// cancelled, and the interactive phases forget their parked runs.
    pub(super) fn cancel_runs_for_sign_out(&mut self, fx: &mut Vec<Effect>) {
        let runs = self.live_runs(&[
            PhaseRunner::Exchange,
            PhaseRunner::Validation,
            PhaseRunner::PostSignIn,
            PhaseRunner::TokenTouching,
        ]);
        fx.push(Effect::CancelInFlightWork { runs });
        self.phase_damper.clear(SIGN_OUT_CLEARED_PHASES);
    }

    /// The runs a sign-in cancels and joins before its exchange.
    pub(super) fn runs_a_sign_in_quiesces(&self) -> Vec<u64> {
        self.live_runs(&[
            PhaseRunner::Validation,
            PhaseRunner::TokenTouching,
            PhaseRunner::Exchange,
        ])
    }

    // MARK: - A run that outlived a sign-out

    /// The operation of a validation or token-touching run finished: its
    /// result stands unless a sign-out began since the run started.
    pub(super) fn on_phase_operation_finished(&mut self, id: u64, fx: &mut Vec<Effect>) {
        let Some(run) = self.phase_runs.get(&id) else {
            return;
        };
        let checked = matches!(run.runner, PhaseRunner::Validation | PhaseRunner::TokenTouching);
        if !checked || run.sign_out_epoch == self.generations.sign_out_epoch {
            fx.push(Effect::PhaseResultStands { id });
        } else {
            fx.push(Effect::AwaitSignOutCapture { id });
        }
    }

    /// The sign-out's credential capture ended: a sign-in that wrote the
    /// store since owns it; otherwise compare the surviving refresh token.
    pub(super) fn on_phase_sign_out_capture_awaited(&mut self, id: u64, fx: &mut Vec<Effect>) {
        let Some(run) = self.phase_runs.get(&id) else {
            return;
        };
        if run.store_write_high_water != self.generations.store_write_high_water {
            fx.push(Effect::PhaseResultDropped { id });
        } else {
            fx.push(Effect::CompareStaleRefreshToken { id });
        }
    }

    /// The stored refresh token was compared against the latest sign-in's
    /// (and compare-cleared when it was not that one): `cleared` when the
    /// store is empty after.
    pub(super) fn on_phase_stale_refresh_token_compared(
        &mut self,
        id: u64,
        cleared: bool,
        fx: &mut Vec<Effect>,
    ) {
        let Some(run) = self.phase_runs.get(&id).copied() else {
            return;
        };
        let same_session = run.generation == self.session_generation()
            && run.store_write_high_water == self.generations.store_write_high_water;
        if !same_session {
            if cleared && self.is_authenticated() {
                let reason = match run.runner {
                    PhaseRunner::Validation => {
                        "a validation raced a sign-out and cleared its stale refresh token"
                    }
                    _ => {
                        "a token operation raced a newer session and cleared its stale refresh token"
                    }
                };
                self.clear_auth_state(reason, true, false, fx);
            }
        } else if run.runner == PhaseRunner::Validation {
            self.clear_auth_state("a validation finished after a sign-out began", true, false, fx);
        }
        fx.push(Effect::PhaseResultDropped { id });
    }

    // MARK: - Empty token reads

    /// A token read found no usable token. Signed out only when storage was
    /// readable and every read answered: a locked store or a read that failed
    /// with a storage error is retryable.
    pub(super) fn on_token_read_empty(
        &mut self,
        storage_was_available: bool,
        read_failed: bool,
        fx: &mut Vec<Effect>,
    ) {
        let failure = if storage_was_available && !read_failed {
            AuthFailure::Unauthorized
        } else {
            AuthFailure::NetworkError
        };
        fx.push(Effect::FailTokenRead(failure));
    }
}
