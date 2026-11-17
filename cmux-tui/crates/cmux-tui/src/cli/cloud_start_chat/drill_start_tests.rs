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
