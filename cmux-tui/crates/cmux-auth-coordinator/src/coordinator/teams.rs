//! The team list, the selected team and team-scope recovery.

use super::{Coordinator, RateLimitStreak, Recovery};
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
        self.active_team_refresh_count += 1;
        fx.push(Effect::RefreshTeams(TeamRefreshTicket {
            generation,
            mutation_generation: self.team_mutation_generation,
            list_generation: self.team_list_generation,
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
        self.active_team_refresh_count = self.active_team_refresh_count.saturating_sub(1);
        let current = ticket.generation == self.session_generation;
        match result {
            Ok(list) if current => {
                self.team_scope_rate_limit = None;
                fx.push(Effect::SessionCheckSucceeded);
                self.authenticated_teams_session_generation = Some(ticket.generation);
                if ticket.list_generation == self.team_list_generation {
                    self.set_available_teams(list.teams, fx);
                }
                let selection_changed = ticket.mutation_generation != self.team_mutation_generation;
                let wanted = if selection_changed {
                    self.selected_team_id.clone()
                } else {
                    list.server_selected_team_id.or_else(|| self.selected_team_id.clone())
                };
                let resolved = resolve_team_id(wanted.as_deref(), &self.available_teams);
                self.set_selected_team(resolved, fx);
            }
            Err(failure) if current => {
                self.note_team_scope_failure(&failure, fx);
                self.schedule_team_scope_recovery(fx);
            }
            _ => {}
        }
        // The rest of `applySignedInUser`: a sign-out during the read skips the hook.
        if ticket.after == AfterTeams::Nothing {
            return;
        }
        if current && ticket.runs_post_sign_in_hook {
            fx.push(Effect::RunPostSignInHook(ticket));
            return;
        }
        self.after_teams(ticket.after, fx);
    }

    pub(super) fn after_teams(&mut self, after: AfterTeams, fx: &mut Vec<Effect>) {
        match after {
            AfterTeams::Nothing => {}
            AfterTeams::Restore => self.finish_restore(fx),
            AfterTeams::SignIn(flow) => self.succeed_sign_in(flow, fx),
        }
    }

    pub(super) fn set_available_teams(&mut self, teams: Vec<AuthTeam>, fx: &mut Vec<Effect>) {
        self.available_teams = teams;
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

    /// A 429 starts or extends the backoff; any other classified failure ends
    /// it; a timeout leaves it as is.
    pub(super) fn note_team_scope_failure(&mut self, failure: &AuthFailure, fx: &mut Vec<Effect>) {
        match failure {
            AuthFailure::RateLimited { retry_after } => {
                let streak = self.team_scope_rate_limit.map_or(0, |limit| limit.streak) + 1;
                let jitter = 0.5 + 0.5 * self.next_unit();
                let delay = team_scope_rate_limit_delay(*retry_after, streak, jitter);
                self.team_scope_rate_limit = Some(RateLimitStreak { streak, delay });
                fx.push(Effect::SessionCheckRateLimited {
                    retry_after: *retry_after,
                    backoff: delay,
                    attempt: streak,
                });
            }
            _ => self.team_scope_rate_limit = None,
        }
    }

    pub(super) fn schedule_team_scope_recovery(&mut self, fx: &mut Vec<Effect>) {
        if !self.needs_team_scope_recovery() || self.team_scope_recovery.is_some() {
            return;
        }
        self.next_recovery_id += 1;
        let recovery = Recovery { id: self.next_recovery_id, attempt: 0 };
        self.team_scope_recovery = Some(recovery);
        fx.push(Effect::SleepTeamScopeRecovery {
            id: recovery.id,
            delay: self.team_scope_recovery_wait(0),
        });
    }

    pub(super) fn on_recovery_due(&mut self, id: u64, fx: &mut Vec<Effect>) {
        let Some(recovery) = self.team_scope_recovery else {
            return;
        };
        if recovery.id != id {
            return;
        }
        if !self.needs_team_scope_recovery() {
            self.team_scope_recovery = None;
            return;
        }
        self.team_scope_recovery = Some(Recovery { id, attempt: recovery.attempt + 1 });
        self.check_existing_session(fx);
    }

    pub(super) fn cancel_team_scope_recovery(&mut self, fx: &mut Vec<Effect>) {
        if let Some(recovery) = self.team_scope_recovery.take() {
            fx.push(Effect::CancelTeamScopeRecovery { id: recovery.id });
        }
        self.team_scope_rate_limit = None;
    }
}
