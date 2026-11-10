use std::time::{Duration, Instant};

use serde_json::{Value, json};

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use super::super::internal::fault_routes::tests::{FakeSession, routes_over};
use super::super::{Outcome, Parsed, Ran, Request, Runner, failed, parse};
use super::{start, take};
use crate::carrier::drill::EventRoutes;
use crate::carrier::fault::tests::{Carrier as FakeCarrier, routes_of, turn};
use crate::carrier::fault::tests::{judged_after_kill, seqs};
use crate::carrier::fault::{Absent, Carrier, FaultSpec, Route, this_build};

const PROBE: &str = "cmux-cloud-capture-prod@manaflow.dev";

/// A device without a tunnel hub: the relay is its only carrier.
fn relay_only() -> [Carrier; 2] {
    this_build(Err(Absent::Tunnel))
}

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

/// Answers `cloud diagnostics` with `email`, and records every step asked of it.
struct Fake {
    email: Option<&'static str>,
    asked: Vec<Vec<String>>,
}

impl Runner for Fake {
    fn cmux(&mut self, args: &[String]) -> Ran {
        self.asked.push(args.to_vec());
        if args.first().map(String::as_str) != Some("cloud")
            || args.get(1).map(String::as_str) != Some("diagnostics")
        {
            return Ran { code: 1, stdout: String::new(), stderr: "unexpected step".into() };
        }
        let details = json!({"signed_in": self.email.is_some(), "email": self.email}).to_string();
        let answer = json!({"ok": true, "result": {"summary": "ok", "details": details}});
        Ran { code: 0, stdout: answer.to_string(), stderr: String::new() }
    }
    fn pause(&mut self, _: Duration) {}
    fn now(&mut self) -> Instant {
        Instant::now()
    }
    fn fresh_name(&mut self) -> String {
        "chat-0000000000000000".into()
    }
}

fn request(words: &[&str]) -> Request {
    match parse(&strings(words), || Ok(String::new())) {
        Ok(Parsed::Run(request)) => request,
        other => panic!("{words:?}: {other:?}"),
    }
}

/// A source the gates must never reach.
fn unreached(
    _: &mut dyn Runner,
    _: &crate::carrier::fault::FaultPlan,
    _: &Value,
    _: tokio::time::Instant,
) -> Result<Box<dyn EventRoutes>, Outcome> {
    panic!("the drill's source was asked before its gates passed")
}

fn relay_after(n: u32) -> FaultSpec {
    FaultSpec { kill: Route::Relay, after_events: n }
}

fn error_of(outcome: &Outcome) -> (&Value, i32) {
    match outcome {
        Outcome::Failed { error, exit } => (error, *exit),
        Outcome::Done(answer) => panic!("a drill answered {answer}"),
    }
}

#[test]
fn the_flag_is_taken_out_before_parse_and_only_outside_values_and_text() {
    let (rest, spec) = take(&strings(&[
        "--prompt",
        "count",
        "--carrier-fault",
        "kill-route=relay,after-events=3",
        "--wait",
    ]))
    .unwrap();
    assert_eq!(rest, strings(&["--prompt", "count", "--wait"]));
    assert_eq!(spec, Some(relay_after(3)));
    let (rest, spec) =
        take(&strings(&["--carrier-fault=after-events=2,kill-route=relay", "--wait"])).unwrap();
    assert_eq!((rest, spec), (strings(&["--wait"]), Some(relay_after(2))));
    // A prompt that names the flag is the prompt, after --prompt or after --.
    let (rest, spec) = take(&strings(&["--prompt", "--carrier-fault", "--wait"])).unwrap();
    assert_eq!((rest.len(), spec), (3, None));
    let (rest, spec) = take(&strings(&["--wait", "--", "--carrier-fault=x"])).unwrap();
    assert_eq!((rest.len(), spec), (3, None));
    for bad in [
        &["--carrier-fault"][..],
        &["--carrier-fault", "kill-route=relay"],
        &[
            "--carrier-fault=kill-route=relay,after-events=1",
            "--carrier-fault=kill-route=relay,after-events=1",
        ],
    ] {
        assert!(take(&strings(bad)).is_err(), "{bad:?}");
    }
}

#[test]
fn a_person_without_the_probe_switch_is_refused_before_any_step() {
    let mut fake = Fake { email: Some(PROBE), asked: Vec::new() };
    let asked = request(&["--prompt", "count", "--wait"]);
    for env in [None, Some("0"), Some("yes")] {
        let outcome = start(&mut fake, &asked, relay_after(3), env, relay_only, unreached);
        let (error, exit) = error_of(&outcome);
        assert_eq!((error["code"].as_str(), exit), (Some("carrier_fault.not_probe"), 2));
    }
    assert!(fake.asked.is_empty(), "a refused caller ran {:?}", fake.asked);
}

#[test]
fn an_account_that_is_not_a_probe_account_is_refused_with_the_same_words() {
    for email in [Some("leo@manaflow.ai"), Some("someone@example.com"), None] {
        let mut fake = Fake { email, asked: Vec::new() };
        let outcome = start(
            &mut fake,
            &request(&["--prompt", "count", "--wait"]),
            relay_after(3),
            Some("1"),
            relay_only,
            unreached,
        );
        let (error, exit) = error_of(&outcome);
        assert_eq!(
            (error["code"].as_str(), exit),
            (Some("carrier_fault.not_probe"), 2),
            "{email:?}"
        );
        assert_eq!(error["details"], json!({}));
        // Only the account was read: no machine, no chat.
        assert_eq!(fake.asked, vec![strings(&["cloud", "diagnostics", "--json"])]);
    }
}

#[test]
fn the_drill_needs_a_prompt_and_wait() {
    let mut fake = Fake { email: Some(PROBE), asked: Vec::new() };
    for words in [&["--wait"][..], &["--prompt", "count"]] {
        let outcome =
            start(&mut fake, &request(words), relay_after(3), Some("1"), relay_only, unreached);
        assert_eq!(error_of(&outcome).0["code"], "usage.invalid", "{words:?}");
    }
}

#[test]
fn killing_the_only_relay_is_a_typed_error_with_the_judges_record_not_a_hang() {
    let mut fake = Fake { email: Some(PROBE), asked: Vec::new() };
    let outcome = start(
        &mut fake,
        &request(&["--prompt", "count", "--wait"]),
        relay_after(3),
        Some("1"),
        relay_only,
        unreached,
    );
    let (error, exit) = error_of(&outcome);
    assert_eq!((error["code"].as_str(), exit), (Some("carrier_fault.no_other_route"), 2));
    let details = &error["details"];
    assert_eq!(details["capabilities"], json!({"routes": ["relay"], "faults": ["kill-route"]}));
    assert_eq!(details["fault"], json!({"kill_route": "relay", "after_events": 3}));
    assert_eq!(details["kill"], Value::Null);
    assert_eq!((details["events"].clone(), details["resumes"].clone()), (json!([]), json!([])));
    assert_eq!(fake.asked.len(), 1, "no machine was made: {:?}", fake.asked);
}

/// With ssh available on the device the fault leaves a carrier to go on over, and the drill
/// asks its source, once, with the plan and the capabilities listing ssh; a source's refusal
/// (a start that failed) is the answer as it came.
#[test]
fn with_ssh_on_the_device_the_fault_plan_passes_and_the_source_is_asked() {
    let mut fake = Fake { email: Some(PROBE), asked: Vec::new() };
    let request = request(&["--prompt", "count", "--wait"]);
    let outcome = start(
        &mut fake,
        &request,
        relay_after(3),
        Some("1"),
        || this_build(Ok(())),
        |_, plan, caps, _| {
            assert_eq!(plan.candidates, vec![Route::Relay, Route::Ssh]);
            assert_eq!(caps["routes"], json!(["relay", "ssh"]));
            Err(failed("cloud.start_pending", "the machine is starting", json!({}), 75))
        },
    );
    let (error, exit) = error_of(&outcome);
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_pending"), 75));
    assert_eq!(fake.asked.len(), 1, "only the gate's diagnostics ran: {:?}", fake.asked);
}

/// The drill over a carrier session: the stream on the relay, the relay killed inside the
/// session after 3 events, the resume over ssh after the last seq, and the finished drill's
/// answer under `drill` holds the relay's events, then ssh's, with nothing lost.
#[test]
fn a_drill_over_the_carrier_session_answers_relay_then_ssh_events_with_no_loss() {
    let mut fake = Fake { email: Some(PROBE), asked: Vec::new() };
    let request = request(&["--prompt", "count", "--wait"]);
    let session = FakeSession::new(8, Route::Relay);
    let sent = Arc::new(AtomicUsize::new(0));
    let routes = routes_over(&session, &sent);
    let outcome = start(
        &mut fake,
        &request,
        relay_after(3),
        Some("1"),
        || this_build(Ok(())),
        move |_, _, _, _| Ok(Box::new(routes) as Box<dyn EventRoutes>),
    );
    let Outcome::Done(answer) = &outcome else { panic!("not an answer: {outcome:?}") };
    let drill = &answer["drill"];
    let routes: Vec<&str> =
        drill["events"].as_array().unwrap().iter().map(|e| e["route"].as_str().unwrap()).collect();
    assert_eq!(routes, [vec!["relay"; 3], vec!["ssh"; 5]].concat());
    assert_eq!(seqs(drill), (1..=8).collect::<Vec<_>>());
    assert_eq!(judged_after_kill(drill), vec!["ssh"; 5]);
    assert_eq!(drill["resumes"][1]["from_seq"], 4);
    assert_eq!(*session.kills.lock().unwrap(), vec![Route::Relay]);
    assert_eq!(sent.load(Ordering::SeqCst), 1);
}

/// A drill that reaches the turn's last event answers its record under `drill` (exit 0), the
/// shape a refusal carries in `error.details`, duplicates and the server's from_seq included.
#[test]
fn a_drill_that_finishes_answers_its_record_under_drill() {
    let mut fake = Fake { email: Some(PROBE), asked: Vec::new() };
    let request = request(&["--prompt", "count", "--wait"]);
    let relay = FakeCarrier { events: turn(6), ..FakeCarrier::default() };
    let ssh = FakeCarrier { events: turn(6), overlap: 1, ..FakeCarrier::default() };
    let (routes, _) = routes_of(vec![relay, ssh]);
    let outcome = start(
        &mut fake,
        &request,
        relay_after(3),
        Some("1"),
        || this_build(Ok(())),
        move |_, _, _, _| Ok(Box::new(routes) as Box<dyn EventRoutes>),
    );
    let Outcome::Done(answer) = &outcome else { panic!("not an answer: {outcome:?}") };
    let drill = &answer["drill"];
    assert_eq!(
        drill["capabilities"],
        json!({"routes": ["relay", "ssh"], "faults": ["kill-route"]})
    );
    assert_eq!(drill["fault"], json!({"kill_route": "relay", "after_events": 3}));
    assert_eq!(drill["kill"]["route"], "relay");
    let seqs: Vec<u64> =
        drill["events"].as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect();
    assert_eq!(seqs, vec![1, 2, 3, 3, 4, 5, 6]);
    assert_eq!(drill["resumes"][1]["phase"], "resume");
    assert_eq!(drill["resumes"][1]["from_seq"], 3);
    assert_eq!(fake.asked.len(), 1, "only the gate's diagnostics ran: {:?}", fake.asked);
}

#[test]
fn a_prompt_on_stdin_is_not_read_before_the_gates() {
    // `run_if_requested` parses with a stand-in for stdin: a refused run never blocks on it.
    let global = crate::cli::GlobalArgs::default();
    let rest = strings(&["--carrier-fault", "kill-route=relay,after-events=3", "--prompt", "-"]);
    // No CMUX_CARRIER_PROBE_FAULTS in the test environment: refused (exit 2) without reading
    // stdin, which the test harness leaves open.
    assert_eq!(super::run_if_requested(&global, &rest), Some(2));
}
