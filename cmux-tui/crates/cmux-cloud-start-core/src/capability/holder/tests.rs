//! The holder's flows, ported from the app's CloudCapabilityRelayTests (cmux#40172): sign-in mints
//! once and every call carries it, a call never waits, a team switch, a refusal, a sign-out during
//! intent's token wait, a failed refresh that retries, and sign-out.

use super::*;

const TOKEN: &str = "cc1.eyJ2IjoxfQ.c2lnbmF0dXJl";
const A: &str = "team_a";
const B: &str = "team_b";

/// The mint route's answer for `team` (server times: 5 min life, refresh at 4).
fn answer(team: &str) -> String {
    format!(
        r#"{{"ok":true,"value":{{"capability":"{TOKEN}","team":"{team}","plan_id":"max","cloud":true,"company":false,"limits":null,"issued_at":1000,"expires_at":301000,"refresh_at":241000}}}}"#
    )
}

fn team(team: &str) -> Option<String> {
    Some(team.to_owned())
}

/// The app's side: the state it keeps, the mints it posted and the timer it armed.
#[derive(Default)]
struct App {
    state: Holder,
    mints: Vec<(String, u64)>,
    timer: Option<(i64, u64)>,
}

impl App {
    fn run(&mut self, event: Event, now: i64) -> Option<String> {
        let step = step(std::mem::take(&mut self.state), event, now);
        self.state = step.state;
        for effect in step.effects {
            match effect {
                Effect::Mint { team, generation } => self.mints.push((team, generation)),
                Effect::Schedule { after_ms, generation } => {
                    self.timer = Some((now + after_ms, generation));
                }
                Effect::CancelTimer => self.timer = None,
                Effect::CancelMint => {}
            }
        }
        step.send
    }

    /// Sign-in, a team switch or intent with `team`'s install token: `Use`, then `Intent`.
    fn intent(&mut self, team: &str, now: i64) {
        self.run(Event::Use, now);
        let generation = self.state.generation;
        self.run(Event::Intent { team: Some(team.to_owned()), generation }, now);
    }

    /// The last mint posted answers `status` (a 200 with its team's capability).
    fn answer(&mut self, status: Option<u16>, now: i64) {
        let (team, generation) = self.mints.last().cloned().expect("a mint was posted");
        let body = status.map(|_| answer(&team));
        self.run(Event::Minted { team, generation, status, body }, now);
    }

    /// The armed timer fires with `team`'s install token.
    fn wake(&mut self, team: &str) -> i64 {
        let (at, generation) = self.timer.take().expect("the timer is armed");
        self.run(Event::Wake { team: Some(team.to_owned()), generation }, at);
        at
    }
}

#[test]
fn sign_in_mints_once_and_every_call_carries_it() {
    let mut app = App::default();
    app.intent(A, 0);
    assert_eq!(app.mints, vec![(A.to_owned(), 0)]);
    app.answer(Some(200), 10);
    assert!(app.state.held.is_some());
    for now in [20, 30, 40] {
        assert_eq!(app.run(Event::Call { team: team(A) }, now).as_deref(), Some(TOKEN));
    }
    assert_eq!(app.mints.len(), 1, "minted once");
    // Armed at the refresh time: 240 s after its arrival.
    assert_eq!(app.timer, Some((10 + 240_000, 0)));
}

#[test]
fn a_call_before_any_mint_goes_without_one_and_starts_the_mint() {
    let mut app = App::default();
    assert_eq!(app.run(Event::Call { team: team(A) }, 0), None, "today's full checks; never waits");
    assert_eq!(app.mints.len(), 1);
    // Intent while that mint is in flight joins it: no second mint.
    app.intent(A, 5);
    assert_eq!(app.mints.len(), 1);
    app.answer(Some(200), 10);
    assert_eq!(app.run(Event::Call { team: team(A) }, 20).as_deref(), Some(TOKEN));
    assert_eq!(app.mints.len(), 1);
}

#[test]
fn after_a_team_switch_the_old_teams_capability_is_never_sent() {
    let mut app = App::default();
    app.intent(A, 0);
    app.answer(Some(200), 10);
    assert_eq!(app.run(Event::Call { team: team(B) }, 20), None);
    // The call for the new team starts its own mint.
    assert_eq!(app.mints.last(), Some(&(B.to_owned(), 0)));
}

#[test]
fn a_refused_mint_sends_nothing_and_the_call_still_goes() {
    let mut app = App::default();
    app.intent(A, 0);
    app.answer(Some(403), 10);
    assert_eq!(app.state.held, None);
    assert_eq!(app.state.failed_team.as_deref(), Some(A));
    assert_eq!(app.run(Event::Call { team: team(A) }, 20), None);
    assert_eq!(app.mints.len(), 1, "the backoff holds the next mint");
    // Nothing held: no timer.
    assert_eq!(app.timer, None);
}

#[test]
fn a_mint_whose_post_failed_counts_as_failed() {
    let mut app = App::default();
    app.intent(A, 0);
    app.answer(None, 10);
    assert_eq!(app.state.held, None);
    assert_eq!(app.state.failed_at, Some(10));
    assert!(!app.state.minting);
}

#[test]
fn a_sign_out_while_intent_waits_for_the_token_keeps_nothing() {
    let mut app = App::default();
    app.run(Event::Use, 0);
    let generation = app.state.generation;
    // The install token is still being read when the person signs out.
    app.run(Event::Clear, 1);
    app.run(Event::Intent { team: team(A), generation }, 2);
    assert!(app.mints.is_empty(), "no mint for the signed-out account");
    assert_eq!(app.state.held, None);
}

#[test]
fn a_sign_out_while_a_mint_is_in_flight_keeps_nothing_it_answers() {
    let mut app = App::default();
    app.intent(A, 0);
    let effects = step(app.state.clone(), Event::Clear, 1).effects;
    assert_eq!(effects, vec![Effect::CancelMint, Effect::CancelTimer]);
    app.run(Event::Clear, 1);
    app.answer(Some(200), 2);
    assert_eq!(app.state.held, None, "the signed-out account's capability came back");
    assert_eq!(app.timer, None);
}

#[test]
fn a_failed_refresh_is_retried_and_recovers() {
    let mut app = App::default();
    app.intent(A, 0);
    app.answer(Some(200), 0);
    // Cloud stays in use: a call just before the refresh time.
    app.run(Event::Call { team: team(A) }, 239_000);
    let at = app.wake(A);
    assert_eq!(app.mints.len(), 2, "the timer's refresh");
    app.answer(Some(403), at);
    // The held one is still sent until its margin, and the timer is re-armed for the retry.
    let (retry, _) = app.timer.expect("re-armed after a failed refresh");
    assert_eq!(retry, at + crate::capability::RETRY_AFTER_MS);
    let at = app.wake(A);
    assert_eq!(app.mints.len(), 3, "the retry");
    app.answer(Some(200), at);
    let held = app.state.held.clone().expect("held again");
    assert_eq!(held.expires_at, at + 300_000);
    assert_eq!(app.state.failed_at, None);
}

#[test]
fn the_timer_stops_refreshing_once_cloud_is_idle() {
    let mut app = App::default();
    app.intent(A, 0);
    app.answer(Some(200), 0);
    // No call for longer than the idle stop: the wake mints nothing and arms nothing more.
    let mut now = 0;
    while let Some((at, generation)) = app.timer.take() {
        now = at;
        app.run(Event::Wake { team: team(A), generation }, at);
        if app.state.minting {
            app.answer(Some(200), at);
        }
        assert!(now <= crate::capability::IDLE_STOP_MS + 300_000, "refreshes while idle");
        if app.mints.len() > 20 {
            break;
        }
    }
    assert!(now >= crate::capability::IDLE_STOP_MS - 300_000);
}

#[test]
fn a_wake_from_before_a_sign_out_mints_nothing() {
    let mut app = App::default();
    app.intent(A, 0);
    app.answer(Some(200), 0);
    let (at, generation) = app.timer.expect("armed");
    app.run(Event::Clear, 1);
    app.run(Event::Wake { team: team(A), generation }, at);
    assert_eq!(app.mints.len(), 1);
}

#[test]
fn sign_out_forgets_it() {
    let mut app = App::default();
    app.intent(A, 0);
    app.answer(Some(200), 0);
    app.run(Event::Clear, 5);
    assert_eq!(app.state, Holder { generation: 1, ..Holder::default() });
    assert_eq!(app.run(Event::Clear, 6), None);
}

#[test]
fn the_timer_is_never_armed_sooner_than_its_floor() {
    // An answer whose refresh time is its issue time asks to wake at once; the timer waits its floor.
    let state = Holder { minting: true, last_use: Some(0), ..Holder::default() };
    let body = answer(A).replace("241000", "1000");
    let step = step(
        state,
        Event::Minted { team: A.to_owned(), generation: 0, status: Some(200), body: Some(body) },
        0,
    );
    assert_eq!(step.effects, vec![Effect::Schedule { after_ms: MIN_WAKE_MS, generation: 0 }]);
}

#[test]
fn the_wire_names_the_app_reads() {
    let step = step(Holder::default(), Event::Call { team: team(A) }, 0);
    let wire = serde_json::to_value(&step).expect("serializes");
    assert_eq!(wire["effects"][0], serde_json::json!({"do": "mint", "team": A, "generation": 0}));
    assert_eq!(wire["state"]["minting"], true);
    let event: Event =
        serde_json::from_value(serde_json::json!({"on": "wake", "team": null, "generation": 3}))
            .expect("an event");
    assert_eq!(event, Event::Wake { team: None, generation: 3 });
    let armed =
        serde_json::to_value(Effect::Schedule { after_ms: 5, generation: 1 }).expect("an effect");
    assert_eq!(armed, serde_json::json!({"do": "schedule", "afterMs": 5, "generation": 1}));
    assert_eq!(
        serde_json::to_value(Effect::CancelTimer).expect("an effect"),
        serde_json::json!({"do": "cancelTimer"})
    );
}
