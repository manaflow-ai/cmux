//! The carrier fault drill's start inside its one deadline, and the partial record it answers when it stops there.
//! A child of `tests`, so its fakes and helpers are in scope.

use super::*;

/// The carrier fault drill's start runs inside the drill's one `--timeout` deadline (`Request::until`), prompt or
/// not: a start-session that answers past it ends the drill there, before the app's credential is asked, any
/// carrier is dialed or anything is sent.
#[test]
fn a_drill_whose_start_answers_past_its_deadline_sends_nothing() {
    use crate::carrier::fault::{FaultPlan, FaultSpec, Route};
    let mut fake = Fake::new(vec![signed_in(), started()]);
    fake.costs = vec![("start-session", Duration::from_secs(120))];
    let asked = request(&["--prompt", "count", "--wait", "--timeout", "60"]);
    let caps = json!({"routes": ["relay", "ssh"], "faults": ["kill-route"]});
    let spec = FaultSpec { kill: Route::Relay, after_events: 3 };
    let plan = FaultPlan::new(spec, vec![Route::Relay, Route::Ssh], &caps).unwrap();
    let until = fake.now() + Duration::from_secs(60);
    let global = GlobalArgs::default();
    let Err(Outcome::Failed { error, .. }) =
        fault::drill_source(&mut fake, &global, &asked, false, (&plan, &caps, until))
    else {
        panic!("a late start went on: {:?}", fake.ran)
    };
    assert_ne!(error["code"], "carrier_fault.no_credential", "{error}");
    // The partial record names the step it stopped in and what that step took, beside the start's own stages:
    // a timeout never hides where the drill stopped.
    let drill = &error["details"]["drill"];
    assert_eq!(drill["stopped_in"], "start", "{error}");
    assert_eq!(drill["steps"][0]["step"], "start", "{error}");
    assert_eq!(drill["steps"][0]["ok"], false, "{error}");
    assert!(drill["steps"][0]["ms"].as_u64().is_some_and(|ms| ms >= 60_000), "{error}");
    assert_eq!(drill["timeout_ms"], 60_000, "{error}");
    assert_eq!((drill["events"].clone(), drill["resumes"].clone()), (json!([]), json!([])));
    assert!(error["details"]["stages_ms"]["steps"].is_array(), "{error}");
    assert!(fake.called.is_empty(), "nothing after the start: {:?}", fake.called);
    assert_eq!(fake.ran.len(), 2, "no exec, no send: {:?}", fake.ran);
}

/// The drill asks its relay ticket in the team its machine is in, as the app's own dial does (the machine record's
/// `team`), never in the app's active team: the app makes and lists its Cloud machines in the install's team, so a
/// credential minted for an active sign-up team asked the ticket where no such machine is (404
/// cloud.machine.not_found "no such machine of yours in this team", cmuxterm-hq run 44086216741, 2026-11-17).
#[test]
fn a_drill_mints_its_credential_for_the_team_its_machine_is_in() {
    use crate::carrier::fault::{FaultPlan, FaultSpec, Route};
    const MACHINE_TEAM: &str = "team_d9753ae7bf17ea2f6eaf";
    // The start reads where the chat runs (no prompt: `run`'s folder read), then the drill asks its credential.
    let mut fake = Fake::new(vec![signed_in(), started(), exec_out("@@cwd\n[]\n")]);
    fake.app_answers = vec![
        (
            "cloud.machines",
            Ok(json!({"loaded": true, "machines": [
                {"id": "vm-other", "team": "team_aaaaaaaaaaaaaaaaaaaa"},
                {"id": "vm-1", "team": MACHINE_TEAM},
            ]})),
        ),
        // Refused, so the drill stops at its credential and dials nothing.
        ("auth.token", Err(json!({"code": "unavailable", "message": "no token in this test"}))),
    ];
    let asked = request(&["--prompt", "count", "--wait", "--timeout", "600"]);
    let caps = json!({"routes": ["relay", "ssh"], "faults": ["kill-route"]});
    let spec = FaultSpec { kill: Route::Relay, after_events: 3 };
    let plan = FaultPlan::new(spec, vec![Route::Relay, Route::Ssh], &caps).unwrap();
    let until = fake.now() + Duration::from_secs(600);
    let global = GlobalArgs::default();
    let Err(Outcome::Failed { error, .. }) =
        fault::drill_source(&mut fake, &global, &asked, false, (&plan, &caps, until))
    else {
        panic!("a refused credential went on: {:?}", fake.called)
    };
    assert_eq!(error["code"], "carrier_fault.no_credential", "{error}");
    let minted: Vec<&Value> = fake
        .called
        .iter()
        .filter(|(method, _)| method == "auth.token")
        .map(|(_, params)| params)
        .collect();
    assert_eq!(minted, vec![&json!({"team": MACHINE_TEAM})], "{:?}", fake.called);
}

/// [`fault::machine_team_in`]: only the named machine's row, its team trimmed; none without a row or a team.
#[test]
fn the_machines_team_is_read_from_its_own_row_only() {
    let listed = json!({"machines": [
        {"id": "vm-a", "team": " team_aaaaaaaaaaaaaaaaaaaa "},
        {"id": "VM-B"},
        {"id": "vm-c", "team": ""},
    ]});
    assert_eq!(
        fault::machine_team_in(&listed, "vm-a").as_deref(),
        Some("team_aaaaaaaaaaaaaaaaaaaa")
    );
    assert_eq!(fault::machine_team_in(&listed, "vm-b"), None);
    assert_eq!(fault::machine_team_in(&listed, "vm-c"), None);
    assert_eq!(fault::machine_team_in(&listed, "vm-z"), None);
    assert_eq!(fault::machine_team_in(&json!({}), "vm-a"), None);
}
