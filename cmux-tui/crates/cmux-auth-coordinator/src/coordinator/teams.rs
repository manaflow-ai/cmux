//! The team list, the selected team and team-scope recovery.

use super::Coordinator;
use super::state::{Backoff, RecoveryLoop, Restore, Teams};
use crate::event::{AfterTeams, AuthFailure, Effect, TeamList, TeamRefreshTicket};
use crate::model::{AuthTeam, resolve_team_id};
use crate::phase::team_scope_rate_limit_delay;

impl Coordinator {
    // MARK: - Teams

    pub(super) fn begin_team_refresh(
        &mut self,
        generation: u64,
        runs_hook: bool,
        after: AfterTeams,
        fx: &mut Vec<Effect>,
    ) {
        self.generations.team_read = self.generations.team_read.wrapping_add(1);
        self.pending_team_reads.insert(self.generations.team_read);
        fx.push(Effect::RefreshTeams(TeamRefreshTicket {
            id: self.generations.team_read,
            generation,
            mutation_generation: self.generations.team_mutation,
            list_generation: self.generations.team_list,
            runs_post_sign_in_hook: runs_hook,
            after,
        }));
    }

    pub(super) fn on_teams_refreshed(
        &mut self,
        ticket: TeamRefreshTicket,
        result: Result<TeamList, AuthFailure>,
        fx: &mut Vec<Effect>,
    ) {
        // Each read is answered once (`step` refused a repeated answer, or
        // one for a read never issued): it would end another read's in-flight
        // count and apply its list or hook twice.
        self.pending_team_reads.remove(&ticket.id);
        let current = ticket.generation == self.generations.session;
        match result {
            Ok(_) | Err(_) if !current => {}
            Ok(list) => {
                self.backoff = Backoff::Clear;
                fx.push(Effect::SessionCheckSucceeded);
                // This session's list has loaded: a delete or rename since
                // the read began keeps the list it left.
                if self.teams == Teams::Unloaded {
                    self.teams = Teams::Loaded { teams: Vec::new() };
                }
                if ticket.list_generation == self.generations.team_list {
                    self.set_available_teams(list.teams, fx);
                }
                let selection_changed =
                    ticket.mutation_generation != self.generations.team_mutation;
                let wanted = if selection_changed {
                    self.selected_team_id.clone()
                } else {
                    list.server_selected_team_id.or_else(|| self.selected_team_id.clone())
                };
                let resolved = resolve_team_id(wanted.as_deref(), self.teams.list());
                self.set_selected_team(resolved, fx);
            }
            Err(failure) => {
                self.note_team_scope_failure(&failure, fx);
                self.schedule_team_scope_recovery(fx);
            }
        }
        // The rest of `applySignedInUser`: a sign-out during the read skips the hook.
        if ticket.after == AfterTeams::Nothing {
            return;
        }
        if current && ticket.runs_post_sign_in_hook && self.hook_owner_is_active(ticket.after) {
            fx.push(Effect::RunPostSignInHook(ticket));
            return;
        }
        self.after_teams(ticket.generation, ticket.after, fx);
    }

    /// Whether the restore run or sign-in flow a team read belongs to is
    /// still running. A plain refresh has no owner and runs no hook.
    pub(super) fn hook_owner_is_active(&self, after: AfterTeams) -> bool {
        match after {
            AfterTeams::Nothing => false,
            AfterTeams::Restore { id } => self.restore == Restore::Running { id },
            AfterTeams::SignIn(flow) => self.flow_is_active(flow),
        }
    }

    /// What the answer that finished the team read (or the hook) was for.
    /// `generation` is the session the answer was issued under: a restore run
    /// or sign-in flow that no longer owns it ignores the answer, and a
    /// sign-in whose session was replaced ends as cancelled, never a success.
    pub(super) fn after_teams(&mut self, generation: u64, after: AfterTeams, fx: &mut Vec<Effect>) {
        match after {
            AfterTeams::Nothing => {}
            AfterTeams::Restore { id } => {
                if self.restore == (Restore::Running { id }) {
                    self.finish_restore(fx);
                }
            }
            AfterTeams::SignIn(flow) => {
                if !self.flow_is_active(flow) {
                    return;
                }
                if generation == self.generations.session
                    && flow.sign_out_epoch == self.generations.sign_out_epoch
                {
                    self.succeed_sign_in(flow, fx);
                } else {
                    self.fail_sign_in(flow, AuthFailure::Cancelled, flow.sets_loading, fx);
                }
            }
        }
    }

    pub(super) fn set_available_teams(&mut self, teams: Vec<AuthTeam>, fx: &mut Vec<Effect>) {
        self.teams = Teams::Loaded { teams };
        self.publish_team_scope(fx);
    }

    pub(super) fn set_selected_team(&mut self, team_id: Option<String>, fx: &mut Vec<Effect>) {
        if team_id == self.selected_team_id {
            return;
        }
        self.selected_team_id = team_id.clone();
        fx.push(Effect::PersistSelectedTeam(team_id));
        self.publish_team_scope(fx);
    }

    /// A 429 starts or extends the backoff; any other failure ends it.
    pub(super) fn note_team_scope_failure(&mut self, failure: &AuthFailure, fx: &mut Vec<Effect>) {
        match failure {
            AuthFailure::RateLimited { retry_after } => {
                let streak = match self.backoff {
                    Backoff::Clear => 0,
                    Backoff::RateLimited { streak, .. } => streak,
                } + 1;
                let jitter = 0.5 + 0.5 * self.next_unit();
                let delay = team_scope_rate_limit_delay(*retry_after, streak, jitter);
                self.backoff = Backoff::RateLimited { streak, delay };
                fx.push(Effect::SessionCheckRateLimited {
                    retry_after: *retry_after,
                    backoff: delay,
                    attempt: streak,
                });
            }
            AuthFailure::Cancelled
            | AuthFailure::Offline
            | AuthFailure::Unauthorized
            | AuthFailure::InvalidCode
            | AuthFailure::NetworkError
            | AuthFailure::TimedOut
            | AuthFailure::Other => self.backoff = Backoff::Clear,
        }
    }

    pub(super) fn schedule_team_scope_recovery(&mut self, fx: &mut Vec<Effect>) {
        if !self.needs_team_scope_recovery() || self.recovery != RecoveryLoop::Idle {
            return;
        }
        self.generations.recovery += 1;
        let id = self.generations.recovery;
        self.recovery = RecoveryLoop::Sleeping { id, attempt: 0 };
        fx.push(Effect::SleepTeamScopeRecovery { id, delay: self.team_scope_recovery_wait(0) });
    }

    pub(super) fn on_recovery_due(&mut self, id: u64, fx: &mut Vec<Effect>) {
        // `step` refused a loop that is not the one sleeping.
        let attempt = match self.recovery {
            RecoveryLoop::Sleeping { attempt, .. } => attempt,
            RecoveryLoop::Idle => return,
        };
        if !self.needs_team_scope_recovery() {
            self.recovery = RecoveryLoop::Idle;
            return;
        }
        self.recovery = RecoveryLoop::Sleeping { id, attempt: attempt + 1 };
        // A launch that asked to clear auth starts no restore; the loop
        // still counted the attempt.
        let _ = self.check_existing_session(fx);
    }

    pub(super) fn cancel_team_scope_recovery(&mut self, fx: &mut Vec<Effect>) {
        if let RecoveryLoop::Sleeping { id, .. } =
            std::mem::replace(&mut self.recovery, RecoveryLoop::Idle)
        {
            fx.push(Effect::CancelTeamScopeRecovery { id });
        }
        self.backoff = Backoff::Clear;
    }
}
