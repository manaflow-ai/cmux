//! A seeded random walk over the coordinator (RFD 0026's proof): requests and
//! answers to tickets it issued, fresh or long stale, in random order. After
//! every step the invariants hold, and a refused event changes nothing.

use cmux_auth_coordinator::{
    AuthFailure, AuthTeam, AuthUser, Coordinator, Effect, Event, LaunchOptions, Persisted, Refusal,
    RestoreTicket, RestoreTrigger, SignInFlow, SignInKind, TeamList, TeamRefreshTicket,
    TokenReadKind,
};

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }

    fn pick<T: Clone>(&mut self, items: &[T]) -> Option<T> {
        if items.is_empty() { None } else { Some(items[self.below(items.len())].clone()) }
    }
}

fn user(id: &str) -> AuthUser {
    AuthUser::new(id, Some("x@example.com"), None)
}

/// Every ticket the coordinator ever issued, so the walk can answer it late.
#[derive(Default)]
struct Issued {
    restores: Vec<RestoreTicket>,
    flows: Vec<SignInFlow>,
    team_reads: Vec<TeamRefreshTicket>,
    recoveries: Vec<u64>,
    captures: Vec<u64>,
}

impl Issued {
    fn note(&mut self, fx: &[Effect]) {
        for effect in fx {
            match effect {
                Effect::ProbeStoredTokens(t)
                | Effect::ValidateCachedSession(t)
                | Effect::CheckTokenStorageAvailable(t) => self.restores.push(*t),
                Effect::ReadSurvivingRefreshToken { ticket, .. }
                | Effect::RetryProbeAfter { ticket, .. }
                | Effect::AutoLogin { ticket, .. }
                | Effect::ClearStaleSession { ticket, .. } => self.restores.push(*ticket),
                Effect::QuiesceTokenWork { flow: f, .. }
                | Effect::CheckOnline(f)
                | Effect::FetchUser(f)
                | Effect::RunExchange { flow: f, .. } => self.flows.push(*f),
                Effect::RefreshTeams(t) | Effect::RunPostSignInHook(t) => self.team_reads.push(*t),
                Effect::SleepTeamScopeRecovery { id, .. } => self.recoveries.push(*id),
                Effect::CaptureTeardownCredentialsAndClearLocalSession { sign_out_epoch } => {
                    self.captures.push(*sign_out_epoch);
                }
                _ => {}
            }
        }
    }
}

fn failure(rng: &mut Rng) -> AuthFailure {
    match rng.below(6) {
        0 => AuthFailure::Cancelled,
        1 => AuthFailure::TimedOut,
        2 => AuthFailure::Unauthorized,
        3 => AuthFailure::RateLimited { retry_after: None },
        4 => AuthFailure::NetworkError,
        _ => AuthFailure::Other,
    }
}

fn event(rng: &mut Rng, issued: &Issued) -> Event {
    let ok = rng.below(3) != 0;
    let accounts = ["a", "b"];
    let account = accounts[rng.below(2)];
    let teams = || TeamList {
        teams: vec![AuthTeam::new("t1", "T1"), AuthTeam::new("t2", "T2")],
        server_selected_team_id: None,
    };
    for _ in 0..4 {
        let pick = rng.below(24);
        let e = match pick {
            0 => Some(Event::Restore(RestoreTrigger::Launch)),
            1 => Some(Event::Restore(RestoreTrigger::Foreground)),
            2 => Some(Event::Restore(RestoreTrigger::TeamScopeSignal)),
            3 => rng.pick(&issued.restores).map(|ticket| Event::TokensProbed {
                ticket,
                probe: if ok { Ok(rng.below(2) == 0) } else { Err(AuthFailure::Other) },
                storage_was_available: rng.below(4) != 0,
                read_failed: rng.below(4) == 0,
            }),
            4 => rng.pick(&issued.restores).map(|ticket| Event::CachedSessionValidated {
                ticket,
                result: if ok { Ok(Some(user(account))) } else { Err(failure(rng)) },
            }),
            5 => rng.pick(&issued.restores).map(|ticket| Event::SurvivingRefreshTokenRead {
                ticket,
                after_error: if rng.below(2) == 0 { None } else { Some(failure(rng)) },
                result: Ok(rng.below(2) == 0),
                read_failed: false,
            }),
            6 => rng
                .pick(&issued.restores)
                .map(|ticket| Event::StaleSessionCleared { ticket, reason: "walk".to_owned() }),
            7 => rng
                .pick(&issued.restores)
                .map(|ticket| Event::ProbeRetryDue { ticket, cancelled: rng.below(2) == 0 }),
            8 => Some(Event::SignInRequested {
                kind: [
                    SignInKind::VerifyCode,
                    SignInKind::Password,
                    SignInKind::Oauth,
                    SignInKind::External,
                ][rng.below(4)],
                sets_loading: rng.below(2) == 0,
            }),
            9 => rng.pick(&issued.flows).map(|flow| Event::TokenWorkQuiesced {
                flow,
                result: if ok { Ok(()) } else { Err(AuthFailure::Cancelled) },
            }),
            10 => rng.pick(&issued.flows).map(|flow| Event::OnlineChecked { flow, online: ok }),
            11 => rng.pick(&issued.flows).map(|flow| Event::ExchangeFinished {
                flow,
                result: if ok { Ok(()) } else { Err(failure(rng)) },
            }),
            12 => rng.pick(&issued.flows).map(|flow| Event::SignInUserFetched {
                flow,
                result: if ok { Ok(Some(user(account))) } else { Err(failure(rng)) },
            }),
            13 => Some(Event::TeamsRequested),
            14 => rng.pick(&issued.team_reads).map(|ticket| Event::TeamsRefreshed {
                ticket,
                result: if ok { Ok(teams()) } else { Err(failure(rng)) },
            }),
            15 => {
                rng.pick(&issued.team_reads).map(|ticket| Event::PostSignInHookFinished { ticket })
            }
            16 => rng.pick(&issued.recoveries).map(|id| Event::TeamScopeRecoveryDue { id }),
            17 => {
                rng.pick(&issued.recoveries).map(|id| Event::TeamScopeRecoveryCheckFinished { id })
            }
            18 => Some(Event::SetSelectedTeam(
                [None, Some("t1".to_owned()), Some("t2".to_owned())][rng.below(3)].clone(),
            )),
            19 => Some([Event::TeamSelectionMutated, Event::TeamListMutated][rng.below(2)].clone()),
            20 => Some(
                [Event::SendCodeStarted, Event::SendCodeFinished { sent: ok }][rng.below(2)]
                    .clone(),
            ),
            21 => Some(Event::SignOutRequested),
            22 => rng
                .pick(&issued.captures)
                .map(|sign_out_epoch| Event::SignOutLocalCleared { sign_out_epoch }),
            _ => Some(Event::TokenReadUnauthorized(TokenReadKind::AccessToken)),
        };
        if let Some(e) = e {
            return e;
        }
    }
    Event::Restore(RestoreTrigger::Foreground)
}

#[derive(Default, Clone, Copy)]
struct Counters {
    session: u64,
    sign_out: u64,
    team_scope: u64,
}

fn check(c: &Coordinator, before: Counters, fx: &[Effect]) -> Counters {
    let now = Counters {
        session: c.session_generation(),
        sign_out: c.sign_out_revision(),
        team_scope: c.team_scope_generation(),
    };
    assert!(now.session >= before.session, "session generation only moves forward");
    assert!(now.sign_out >= before.sign_out, "sign-out epoch only moves forward");
    assert!(now.team_scope >= before.team_scope, "team-scope generation only moves forward");
    let state = c.state();
    assert_eq!(state.is_authenticated, c.is_authenticated());
    if c.is_authenticated() {
        assert!(c.current_user().is_some(), "signed in always has a user");
    }
    if let Some(identity) = c.published_session_identity() {
        assert!(c.is_authenticated());
        assert_eq!(identity.generation, c.session_generation());
    }
    if c.session_identity().is_some() {
        assert!(!c.session_token_transition_is_active());
    }
    if let Some(scope) = c.team_scope() {
        assert!(c.available_teams().iter().any(|team| team.id == scope.team_id));
        assert_eq!(scope.session.generation, c.session_generation());
    }
    if c.needs_team_scope_recovery() {
        assert!(c.is_authenticated());
    }
    // A published team scope is the one the coordinator reads now.
    if let Some(Effect::PublishTeamScope(scope)) =
        fx.iter().rev().find(|e| matches!(e, Effect::PublishTeamScope(_)))
    {
        assert_eq!(scope, &c.team_scope());
    }
    // At most one restore run's probe starts per step.
    let probes = fx.iter().filter(|e| matches!(e, Effect::ProbeStoredTokens(t) if t.failed_read_retries == 0 && t.retry_on_storage_available)).count();
    assert!(probes <= 1);
    now
}

fn walk(seed: u64, steps: usize, launch: LaunchOptions, persisted: Persisted) -> Vec<String> {
    let mut rng = Rng(seed | 1);
    let (mut c, fx) = Coordinator::new(launch, persisted, seed);
    let mut issued = Issued::default();
    issued.note(&fx);
    let mut counters = check(&c, Counters::default(), &fx);
    let mut trace = Vec::new();
    for _ in 0..steps {
        let e = event(&mut rng, &issued);
        let before = c.clone();
        let kind = e.kind();
        match c.step(e.clone()) {
            Ok(fx) => {
                issued.note(&fx);
                counters = check(&c, counters, &fx);
                trace.push(format!("{kind}:{}", fx.len()));
            }
            Err(refusal) => {
                assert!(Refusal::ALL.contains(&refusal));
                assert_eq!(c, before, "{kind} refused {refusal} but changed the coordinator");
                // `reduce` runs nothing for a refused event.
                let mut again = before.clone();
                assert!(again.reduce(e).is_empty());
                assert_eq!(again, before);
                trace.push(format!("{kind}:{refusal}"));
            }
        }
    }
    trace
}

#[test]
fn seeded_walks_keep_the_invariants() {
    let launches = [
        (LaunchOptions::default(), Persisted::default()),
        (
            LaunchOptions::default(),
            Persisted {
                cached_user: Some(user("a")),
                has_tokens: true,
                selected_team_id: Some("t1".to_owned()),
            },
        ),
    ];
    let mut refused = 0;
    let mut stepped = 0;
    for seed in 1..=64u64 {
        for (launch, persisted) in &launches {
            let trace = walk(seed, 400, launch.clone(), persisted.clone());
            refused +=
                trace.iter().filter(|line| !line.contains(|c: char| c.is_ascii_digit())).count();
            stepped += trace.len();
        }
    }
    assert!(refused > 0 && refused < stepped, "the walk meets both transitions and refusals");
    println!("auth walk: {stepped} steps, {refused} refused");
}

#[test]
fn a_seed_replays_the_same_walk() {
    let a = walk(42, 300, LaunchOptions::default(), Persisted::default());
    let b = walk(42, 300, LaunchOptions::default(), Persisted::default());
    assert_eq!(a, b);
}

/// A restore answer that arrives after its run ended is refused and changes nothing.
#[test]
fn a_restore_ticket_answered_after_its_run_is_refused() {
    let (mut c, fx) = Coordinator::new(
        LaunchOptions::default(),
        Persisted { cached_user: Some(user("a")), has_tokens: true, selected_team_id: None },
        1,
    );
    let mut issued = Issued::default();
    issued.note(&fx);
    let fx = c.step(Event::Restore(RestoreTrigger::Launch)).expect("restore starts");
    issued.note(&fx);
    let ticket = issued.restores[0];
    c.step(Event::TokensProbed {
        ticket,
        probe: Err(AuthFailure::Other),
        storage_was_available: true,
        read_failed: false,
    })
    .expect("the probe failure ends the run");
    let before = c.clone();
    assert_eq!(
        c.step(Event::CachedSessionValidated { ticket, result: Ok(Some(user("b"))) }),
        Err(Refusal::StaleRestore)
    );
    assert_eq!(c, before);
}
