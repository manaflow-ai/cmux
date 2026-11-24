use std::path::PathBuf;

use super::*;

fn table_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../schemas/auth-coordinator/table.json")
}

/// The committed table is the one `step` answers. `CMUX_UPDATE_AUTH_COORDINATOR_TABLE=1`
/// rewrites it.
#[test]
fn committed_auth_table_is_current() {
    let path = table_path();
    let now = table_text();
    if std::env::var("CMUX_UPDATE_AUTH_COORDINATOR_TABLE").as_deref() == Ok("1") {
        std::fs::create_dir_all(path.parent().expect("parent")).expect("schemas dir");
        std::fs::write(&path, &now).expect("write table");
        return;
    }
    let committed = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!("{}: {e}; run with CMUX_UPDATE_AUTH_COORDINATOR_TABLE=1", path.display())
    });
    assert!(
        committed == now,
        "{} is stale: rerun `CMUX_UPDATE_AUTH_COORDINATOR_TABLE=1 cargo test -p cmux-auth-coordinator committed_auth_table` and commit it",
        path.display()
    );
}

/// Every sample state against every event kind is a transition or a named
/// refusal, a refusal changes nothing, and the table holds exactly those pairs.
#[test]
fn every_auth_state_against_every_event_is_decided() {
    let states = sample_states();
    let events = sample_events();
    assert_eq!(events.len(), Event::KINDS.len());
    for (event, kind) in events.iter().zip(Event::KINDS) {
        assert_eq!(event.kind(), kind);
    }
    let kinds: BTreeSet<String> = states.iter().map(Coordinator::kind).collect();
    assert_eq!(kinds.len(), states.len(), "every sample state has its own name");
    let mut refusals = 0;
    for state in &states {
        for event in &events {
            let mut next = state.clone();
            match next.step(event.clone()) {
                Ok(_) => {}
                Err(refusal) => {
                    assert!(Refusal::ALL.contains(&refusal));
                    assert_eq!(
                        &next,
                        state,
                        "{} refused {} but changed",
                        state.kind(),
                        event.kind()
                    );
                    refusals += 1;
                }
            }
        }
    }
    let table = table();
    let rows = table["transitions"].as_array().expect("transitions");
    assert_eq!(rows.len(), states.len() * events.len());
    assert_eq!(rows.iter().filter(|row| row.get("refusal").is_some()).count(), refusals);
    println!(
        "auth table: {} states x {} events = {} pairs, {refusals} refusals",
        states.len(),
        events.len(),
        rows.len()
    );
}

/// Every answer under a ticket other than the awaited one is refused, in every state.
#[test]
fn answers_under_other_tickets_are_refused_everywhere() {
    let ticket = RestoreTicket { id: RESTORE_ID + 1, ..sample_ticket() };
    let flow = SignInFlow { attempt: ATTEMPT + 1, ..sample_flow() };
    let changed_flow = SignInFlow { sets_loading: false, ..sample_flow() };
    let stale = [
        (
            Event::TokensProbed {
                ticket,
                probe: Ok(true),
                storage_was_available: true,
                read_failed: false,
            },
            Refusal::StaleRestore,
        ),
        (Event::AutoLoginFinished { ticket, result: Ok(()) }, Refusal::StaleRestore),
        (Event::StaleSessionCleared { ticket, reason: String::new() }, Refusal::StaleRestore),
        (Event::ExchangeFinished { flow, result: Ok(()) }, Refusal::InactiveSignInFlow),
        (Event::OnlineChecked { flow: changed_flow, online: true }, Refusal::InactiveSignInFlow),
        (
            Event::TeamsRefreshed {
                ticket: TeamRefreshTicket {
                    id: TEAM_READ + 1,
                    ..sample_team_read(AfterTeams::Nothing)
                },
                result: Ok(TeamList { teams: Vec::new(), server_selected_team_id: None }),
            },
            Refusal::UnknownTeamRead,
        ),
        (
            Event::PostSignInHookFinished { ticket: sample_team_read(AfterTeams::SignIn(flow)) },
            Refusal::HookOwnerGone,
        ),
        (Event::TeamScopeRecoveryDue { id: RECOVERY + 1 }, Refusal::StaleRecovery),
        (Event::TeamScopeRecoveryCheckFinished { id: RECOVERY + 1 }, Refusal::StaleRecovery),
        (
            Event::SignOutLocalCleared { sign_out_epoch: SIGN_OUT_EPOCH + 1 },
            Refusal::UnknownSignOutCapture,
        ),
    ];
    for state in sample_states() {
        for (event, refusal) in &stale {
            let mut next = state.clone();
            assert_eq!(
                next.step(event.clone()),
                Err(*refusal),
                "{} {}",
                state.kind(),
                event.kind()
            );
            assert_eq!(next, state);
        }
    }
}

/// A restore answer outside a restore run is refused even with the right id.
#[test]
fn restore_answers_need_a_running_restore() {
    for state in sample_states() {
        let mut next = state.clone();
        let result = next.step(Event::ProbeRetryDue { ticket: sample_ticket(), cancelled: false });
        match state.restore {
            Restore::Idle => assert_eq!(result, Err(Refusal::StaleRestore)),
            Restore::Running { .. } => assert!(result.is_ok()),
        }
    }
}
