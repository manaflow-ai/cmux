//! A small driver: it feeds events and answers the I/O effects the way the
//! Swift shell would, so each test reads as the flow it ports.

#![allow(dead_code)]

use cmux_auth_coordinator::{
    AuthFailure, AuthTeam, AuthUser, Coordinator, Effect, Event, LaunchOptions, Persisted,
    RestoreTicket, RestoreTrigger, SignInFlow, SignInKind, TeamList, TeamRefreshTicket,
};

pub fn user(id: &str) -> AuthUser {
    AuthUser::new(id, Some(&format!("{id}@example.com")), Some(id))
}

pub fn team(id: &str) -> AuthTeam {
    AuthTeam::new(id, id)
}

pub fn teams(ids: &[&str]) -> TeamList {
    TeamList { teams: ids.iter().copied().map(team).collect(), server_selected_team_id: None }
}

pub struct Driver {
    pub c: Coordinator,
    /// Every effect since the driver was built, in order.
    pub log: Vec<Effect>,
}

impl Driver {
    pub fn new(launch: LaunchOptions, persisted: Persisted) -> Self {
        let (c, fx) = Coordinator::new(launch, persisted, 7);
        Self { c, log: fx }
    }

    pub fn signed_out() -> Self {
        Self::new(LaunchOptions::default(), Persisted::default())
    }

    /// A launch with a cached user and stored tokens.
    pub fn cached(id: &str) -> Self {
        Self::new(
            LaunchOptions::default(),
            Persisted { cached_user: Some(user(id)), has_tokens: true, selected_team_id: None },
        )
    }

    pub fn send(&mut self, event: Event) -> Vec<Effect> {
        let fx = self.c.reduce(event);
        self.log.extend(fx.iter().cloned());
        fx
    }

    pub fn clear_log(&mut self) {
        self.log.clear();
    }

    pub fn count(&self, wanted: &Effect) -> usize {
        self.log.iter().filter(|effect| *effect == wanted).count()
    }

    pub fn logged(&self, wanted: &Effect) -> bool {
        self.count(wanted) > 0
    }

    pub fn sign_out_reasons(&self) -> Vec<String> {
        self.log
            .iter()
            .filter_map(|effect| match effect {
                Effect::LogSignOut { reason } => Some(reason.clone()),
                _ => None,
            })
            .collect()
    }

    /// Starts a restore and returns its probe ticket.
    pub fn start_restore(&mut self, trigger: RestoreTrigger) -> RestoreTicket {
        let fx = self.send(Event::Restore(trigger));
        probe_ticket(&fx).expect("the restore probes the stored tokens")
    }

    pub fn probe(&mut self, ticket: RestoreTicket, has_tokens: bool) -> Vec<Effect> {
        self.send(Event::TokensProbed {
            ticket,
            probe: Ok(has_tokens),
            storage_was_available: true,
            read_failed: false,
        })
    }

    /// Starts a sign-in and runs it to its exchange's end.
    pub fn sign_in_through_exchange(&mut self, kind: SignInKind) -> (SignInFlow, Vec<Effect>) {
        let flow = self.begin_sign_in(kind);
        self.send(Event::TokenWorkQuiesced { flow, result: Ok(()) });
        self.send(Event::OnlineChecked { flow, online: true });
        let fx = self.send(Event::ExchangeFinished { flow, result: Ok(()) });
        (flow, fx)
    }

    pub fn begin_sign_in(&mut self, kind: SignInKind) -> SignInFlow {
        let fx = self.send(Event::SignInRequested { kind, sets_loading: true });
        match fx.as_slice() {
            [Effect::QuiesceTokenWork(flow)] => *flow,
            other => panic!("expected a quiesce, got {other:?}"),
        }
    }

    /// A whole password sign-in for `id`, with `team_list` as the team read.
    pub fn sign_in(&mut self, id: &str, team_list: Result<TeamList, AuthFailure>) -> Vec<Effect> {
        let (flow, _) = self.sign_in_through_exchange(SignInKind::Password);
        let fx = self.send(Event::SignInUserFetched { flow, result: Ok(Some(user(id))) });
        let ticket = refresh_ticket(&fx).expect("sign-in reads the teams");
        let fx = self.send(Event::TeamsRefreshed { ticket, result: team_list });
        match hook_ticket(&fx) {
            Some(ticket) => self.send(Event::PostSignInHookFinished { ticket }),
            None => fx,
        }
    }

    pub fn sign_out(&mut self) -> Vec<Effect> {
        let mut fx = self.send(Event::SignOutRequested);
        fx.extend(self.send(Event::SignOutLocalCleared));
        fx
    }
}

pub fn probe_ticket(fx: &[Effect]) -> Option<RestoreTicket> {
    fx.iter().find_map(|effect| match effect {
        Effect::ProbeStoredTokens(ticket) => Some(*ticket),
        _ => None,
    })
}

pub fn refresh_ticket(fx: &[Effect]) -> Option<TeamRefreshTicket> {
    fx.iter().find_map(|effect| match effect {
        Effect::RefreshTeams(ticket) => Some(*ticket),
        _ => None,
    })
}

pub fn hook_ticket(fx: &[Effect]) -> Option<TeamRefreshTicket> {
    fx.iter().find_map(|effect| match effect {
        Effect::RunPostSignInHook(ticket) => Some(*ticket),
        _ => None,
    })
}

pub fn recovery_sleep(fx: &[Effect]) -> Option<(u64, std::time::Duration)> {
    fx.iter().find_map(|effect| match effect {
        Effect::SleepTeamScopeRecovery { id, delay } => Some((*id, *delay)),
        _ => None,
    })
}

pub fn sign_in_failure(fx: &[Effect]) -> Option<AuthFailure> {
    fx.iter().find_map(|effect| match effect {
        Effect::SignInFailed { failure, .. } => Some(failure.clone()),
        _ => None,
    })
}
