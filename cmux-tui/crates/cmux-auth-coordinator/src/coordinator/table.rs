//! The coordinator's transition table as data (RFD 0026 rule 4): every sample
//! state against every event kind, each a transition (the state it moves to
//! and its effects' kinds) or a named [`Refusal`]. Committed as
//! `schemas/auth-coordinator/table.json`; a test fails when that copy is stale.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};

use super::Coordinator;
use super::state::{
    Backoff, DebugCredentials, Generations, Loading, PendingCode, RecoveryLoop, Restore, Session,
    Teams, TokenCache,
};
use crate::event::{
    AfterTeams, Effect, Event, RestoreTicket, RestoreTrigger, SignInFlow, SignInKind, TeamList,
    TeamRefreshTicket, TokenReadKind,
};
use crate::machine::Refusal;
use crate::model::{AuthTeam, AuthUser, LaunchOptions};

/// The session generation the sample states are in and their answers carry.
const SESSION: u64 = 7;
const SIGN_OUT_EPOCH: u64 = 3;
const RESTORE_ID: u64 = 2;
const ATTEMPT: u64 = 5;
const HIGH_WATER: u64 = 4;
const TEAM_READ: u64 = 6;
const RECOVERY: u64 = 1;

fn sample_user() -> AuthUser {
    AuthUser::new("user-a", Some("a@example.com"), Some("A"))
}

fn sample_flow() -> SignInFlow {
    SignInFlow {
        generation: SESSION,
        attempt: ATTEMPT,
        sign_out_epoch: SIGN_OUT_EPOCH,
        kind: SignInKind::Password,
        sets_loading: true,
    }
}

fn sample_ticket() -> RestoreTicket {
    RestoreTicket {
        id: RESTORE_ID,
        generation: SESSION,
        store_write_high_water: HIGH_WATER,
        retry_on_storage_available: true,
        failed_read_retries: 0,
    }
}

fn sample_team_read(after: AfterTeams) -> TeamRefreshTicket {
    TeamRefreshTicket {
        id: TEAM_READ,
        generation: SESSION,
        mutation_generation: 0,
        list_generation: 0,
        runs_post_sign_in_hook: true,
        after,
    }
}

impl Coordinator {
    /// This coordinator's state in the table: the session, the restore run
    /// and the team list, plus whether a sign-out capture is open.
    pub(crate) fn kind(&self) -> String {
        let capture = if self.pending_sign_out_captures.is_empty() { "" } else { "/capturing" };
        format!("{}/{}/{}{capture}", self.session.kind(), self.restore.kind(), self.teams.kind())
    }

    /// One coordinator in `session` with `restore` and `teams`, a sign-in
    /// flow, a team read and a recovery sleep open, under [`SESSION`].
    fn sample(session: Session, restore: Restore, teams: Teams, capturing: bool) -> Coordinator {
        let mut c = Coordinator {
            launch: LaunchOptions::default(),
            session,
            restore,
            loading: Loading::Busy,
            teams,
            selected_team_id: Some("team-a".to_owned()),
            cached_user: Some(sample_user()),
            token_cache: TokenCache::Stored,
            pending_code: PendingCode::None,
            debug_credentials: DebugCredentials::None,
            last_sign_out_reason: None,
            generations: Generations {
                session: SESSION,
                sign_out_epoch: SIGN_OUT_EPOCH,
                sign_in_attempt: ATTEMPT,
                store_write_high_water: HIGH_WATER,
                restore: RESTORE_ID,
                team_scope: 1,
                team_mutation: 0,
                team_list: 0,
                team_read: TEAM_READ,
                recovery: RECOVERY,
            },
            active_sign_in_flows: BTreeMap::from([(ATTEMPT, sample_flow())]),
            pending_sign_out_captures: if capturing {
                BTreeSet::from([SIGN_OUT_EPOCH])
            } else {
                BTreeSet::new()
            },
            last_published_team_scope: None,
            pending_team_reads: BTreeSet::from([TEAM_READ]),
            backoff: Backoff::Clear,
            recovery: RecoveryLoop::Sleeping { id: RECOVERY, attempt: 0 },
            rng: 7,
        };
        c.last_published_team_scope = c.team_scope();
        c
    }
}

/// The sample states, in the table's order: every session against every
/// restore run and team list, then the two sign-out captures.
pub(crate) fn sample_states() -> Vec<Coordinator> {
    let user = sample_user;
    let sessions = [
        Session::SignedOut { shown: None },
        Session::Restoring { shown: Some(user()) },
        Session::RestoringSignedIn { user: user() },
        Session::SignedIn { user: user() },
    ];
    let mut states = Vec::new();
    for session in &sessions {
        for restore in [Restore::Idle, Restore::Running { id: RESTORE_ID }] {
            for teams in
                [Teams::Unloaded, Teams::Loaded { teams: vec![AuthTeam::new("team-a", "A")] }]
            {
                states.push(Coordinator::sample(session.clone(), restore, teams, false));
            }
        }
    }
    for session in [Session::SignedOut { shown: None }, Session::SignedIn { user: user() }] {
        states.push(Coordinator::sample(session, Restore::Idle, Teams::Unloaded, true));
    }
    states
}

/// One event per kind, in [`Event::KINDS`] order. Answers carry the tickets
/// the sample states issued.
pub(crate) fn sample_events() -> Vec<Event> {
    let ticket = sample_ticket();
    let flow = sample_flow();
    vec![
        Event::Restore(RestoreTrigger::Launch),
        Event::Restore(RestoreTrigger::Foreground),
        Event::Restore(RestoreTrigger::TeamScopeSignal),
        Event::TokensProbed {
            ticket,
            probe: Ok(true),
            storage_was_available: true,
            read_failed: false,
        },
        Event::TokenStorageAvailability { ticket, available: true },
        Event::ProbeRetryDue { ticket, cancelled: false },
        Event::CachedSessionValidated { ticket, result: Ok(Some(sample_user())) },
        Event::SurvivingRefreshTokenRead {
            ticket,
            after_error: None,
            result: Ok(true),
            read_failed: false,
        },
        Event::StaleSessionCleared { ticket, reason: "sample".to_owned() },
        Event::AutoLoginFinished { ticket, result: Ok(()) },
        Event::SignInRequested { kind: SignInKind::Password, sets_loading: true },
        Event::TokenWorkQuiesced { flow, result: Ok(()) },
        Event::OnlineChecked { flow, online: true },
        Event::ExchangeFinished { flow, result: Ok(()) },
        Event::SignInUserFetched { flow, result: Ok(Some(sample_user())) },
        Event::TeamsRequested,
        Event::TeamsRefreshed {
            ticket: sample_team_read(AfterTeams::Nothing),
            result: Ok(TeamList {
                teams: vec![AuthTeam::new("team-a", "A")],
                server_selected_team_id: None,
            }),
        },
        Event::PostSignInHookFinished { ticket: sample_team_read(AfterTeams::SignIn(flow)) },
        Event::TeamScopeRecoveryDue { id: RECOVERY },
        Event::TeamScopeRecoveryCheckFinished { id: RECOVERY },
        Event::SetSelectedTeam(Some("team-b".to_owned())),
        Event::TeamSelectionMutated,
        Event::TeamListMutated,
        Event::SendCodeStarted,
        Event::SendCodeFinished { sent: true },
        Event::DebugCredentialsRemembered,
        Event::SignOutRequested,
        Event::SignOutLocalCleared { sign_out_epoch: SIGN_OUT_EPOCH },
        Event::TokenReadUnauthorized(TokenReadKind::AccessToken),
        Event::DevAuthAccessTokenFinished { got_token: false },
    ]
}

/// The whole table as data.
pub fn table() -> Value {
    let mut rows = Vec::new();
    for state in sample_states() {
        for event in sample_events() {
            let mut next = state.clone();
            let row = match next.step(event.clone()) {
                Ok(effects) => json!({
                    "from": state.kind(),
                    "event": event.kind(),
                    "to": next.kind(),
                    "effects": effects.iter().map(Effect::kind).collect::<Vec<_>>(),
                }),
                Err(refusal) => json!({
                    "from": state.kind(),
                    "event": event.kind(),
                    "refusal": refusal.as_str(),
                }),
            };
            rows.push(row);
        }
    }
    let states: Vec<Value> = sample_states()
        .iter()
        .map(|c| {
            json!({
                "state": c.kind(),
                "isAuthenticated": c.is_authenticated(),
                "isRestoringSession": c.is_restoring_session(),
                "teamScope": c.team_scope().is_some(),
                "tokenTransition": c.session_token_transition_is_active(),
            })
        })
        .collect();
    json!({
        "version": 1,
        "source": "cmux-tui/crates/cmux-auth-coordinator/src/coordinator/mod.rs",
        "state": "A state is session/restore/teams[/capturing]: the published session (signed_out, restoring, restoring_signed_in, signed_in), whether a restore run owns the session (idle, running) and whether this session generation's team list has loaded (unloaded, loaded); capturing is an open sign-out credential capture. Each sample state also has one sign-in flow, one team read and one recovery sleep open, so their answers are awaited.",
        "stale": "An answer carries the ticket it was issued under: a restore answer whose run id is not the running one is refused stale_restore, a sign-in answer for a flow not registered exactly as it began inactive_sign_in_flow, a team read answered already or never issued unknown_team_read, a hook whose run or flow is gone hook_owner_gone, a recovery id not the sleeping one stale_recovery, and a sign-out epoch with no open capture unknown_sign_out_capture. A refusal leaves the coordinator unchanged and runs no effect.",
        "generations": "The session generation, sign-out epoch, sign-in attempt, restore run, team read and recovery loop counters only move forward, so a ticket issued under an older one never matches again.",
        "regions": {
            "session": Session::KINDS,
            "restore": Restore::KINDS,
            "teams": Teams::KINDS,
        },
        "states": states,
        "events": Event::KINDS,
        "refusals": Refusal::ALL.map(Refusal::as_str),
        "transitions": rows,
    })
}

/// [`table`] as the committed file's text.
pub fn table_text() -> String {
    // A Value's alternate Display is the pretty form and cannot fail.
    format!("{:#}\n", table())
}

#[cfg(test)]
mod tests;
