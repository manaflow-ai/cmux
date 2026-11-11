use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::{Outcome, Parsed, Ran, Request, Runner, parse};
use super::{start, take};
use crate::carrier::drill::EventRoutes;
use crate::carrier::fault::tests::{Carrier as FakeCarrier, routes_of, turn};
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
        let outcome = start(&mut fake, &asked, relay_after(3), env, relay_only, |_| None);
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
            |_| None,
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
            start(&mut fake, &request(words), relay_after(3), Some("1"), relay_only, |_| None);
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
        |_| None,
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
/// stops at the missing event source (slice S1), the capabilities in its record listing ssh.
#[test]
fn with_ssh_on_the_device_the_fault_plan_passes_and_the_record_lists_ssh() {
    let mut fake = Fake { email: Some(PROBE), asked: Vec::new() };
    let request = request(&["--prompt", "count", "--wait"]);
    let outcome =
        start(&mut fake, &request, relay_after(3), Some("1"), || this_build(Ok(())), |_| None);
    let (error, exit) = error_of(&outcome);
    assert_eq!((error["code"].as_str(), exit), (Some("carrier_fault.no_event_source"), 2));
    let caps = &error["details"]["capabilities"];
    assert_eq!(caps, &json!({"routes": ["relay", "ssh"], "faults": ["kill-route"]}));
    assert_eq!(fake.asked.len(), 1, "no machine was made: {:?}", fake.asked);
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
        |_| Some(Box::new(routes) as Box<dyn EventRoutes>),
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
