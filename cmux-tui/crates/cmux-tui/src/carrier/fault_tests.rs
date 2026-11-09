use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::time::Instant;

use super::super::drill::{EventRoutes, EventStream, TurnEvent, run_drill};
use super::{
    FaultPlan, FaultSpec, GateRefusal, Route, capabilities, parse_spec, probe_account, probe_gate,
    routes, this_build,
};

fn turn(last: u64) -> Vec<TurnEvent> {
    (1..=last).map(|seq| TurnEvent { seq, last: seq == last }).collect()
}

/// One fake carrier: the whole turn, and how it misbehaves.
#[derive(Clone, Default)]
struct Carrier {
    events: Vec<TurnEvent>,
    /// A resume replays this many events the client already has.
    overlap: u64,
    refuse: bool,
    /// The stream never yields after this many events.
    stall_after: Option<usize>,
    killed: Arc<AtomicBool>,
}

/// Every open the drill asked for: the carrier's index, its route and `afterSeq`.
type Opens = Arc<Mutex<Vec<(usize, Route, Option<u64>)>>>;

struct Routes {
    carriers: Vec<Carrier>,
    opens: Opens,
}

struct Stream {
    events: std::vec::IntoIter<TurnEvent>,
    stall_after: Option<usize>,
    sent: usize,
    killed: Arc<AtomicBool>,
}

#[async_trait]
impl EventStream for Stream {
    async fn next(&mut self) -> Option<Result<TurnEvent, String>> {
        assert!(!self.killed.load(Ordering::SeqCst), "a killed carrier was read again");
        if self.stall_after.is_some_and(|n| self.sent >= n) {
            std::future::pending::<()>().await;
        }
        self.sent += 1;
        self.events.next().map(Ok)
    }

    async fn kill(self: Box<Self>) {
        self.killed.store(true, Ordering::SeqCst);
    }
}

#[async_trait]
impl EventRoutes for Routes {
    async fn open(
        &mut self,
        index: usize,
        route: Route,
        after_seq: Option<u64>,
    ) -> Result<Box<dyn EventStream>, String> {
        self.opens.lock().unwrap().push((index, route, after_seq));
        let carrier = self.carriers.get(index).cloned().ok_or("no such carrier")?;
        if carrier.refuse {
            return Err("refused".into());
        }
        let from = after_seq.map_or(0, |after| after.saturating_sub(carrier.overlap));
        let events: Vec<_> = carrier.events.into_iter().filter(|e| e.seq > from).collect();
        Ok(Box::new(Stream {
            events: events.into_iter(),
            stall_after: carrier.stall_after,
            sent: 0,
            killed: carrier.killed,
        }))
    }
}

fn routes_of(carriers: Vec<Carrier>) -> (Routes, Opens) {
    let opens = Arc::new(Mutex::new(Vec::new()));
    (Routes { carriers, opens: opens.clone() }, opens)
}

fn spec(after_events: u32) -> FaultSpec {
    FaultSpec { kill: Route::Relay, after_events }
}

fn caps_with_ssh() -> Value {
    json!({"routes": ["relay", "ssh"], "faults": ["kill-route"]})
}

fn deadline() -> Instant {
    Instant::now() + Duration::from_secs(30)
}

fn seqs(record: &Value) -> Vec<u64> {
    record["events"].as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect()
}

/// The probe judge's rules (cloud_carrier_failover_probe.py judge_drill) that do not
/// depend on the route being ssh: one clock in arrival order, the kill strictly
/// after the last event before it, seqs 1..N once each, the resume from the last
/// seq before the kill plus one, a final event. Answers the route events took
/// after the kill.
fn judged_after_kill(record: &Value) -> Vec<String> {
    let events = record["events"].as_array().unwrap();
    let times: Vec<u64> = events.iter().map(|e| e["at_ms"].as_u64().unwrap()).collect();
    assert!(times.windows(2).all(|w| w[0] <= w[1]), "events out of arrival order: {times:?}");
    let kill_at = record["kill"]["at_ms"].as_u64().unwrap();
    assert_eq!(record["kill"]["route"], "relay");
    let before: Vec<&Value> =
        events.iter().filter(|e| e["at_ms"].as_u64().unwrap() < kill_at).collect();
    let after: Vec<&Value> =
        events.iter().filter(|e| e["at_ms"].as_u64().unwrap() >= kill_at).collect();
    assert!(!before.is_empty() && !after.is_empty(), "{record}");
    assert!(before.iter().all(|e| e["route"] == "relay"), "{record}");
    let all = seqs(record);
    assert_eq!(all, (1..=all.len() as u64).collect::<Vec<_>>(), "seqs lost or repeated");
    let last_before = before.last().unwrap()["seq"].as_u64().unwrap();
    let resume = record["resumes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["phase"] == "resume" && r["outcome"] == "ok")
        .expect("an ok resume");
    assert_eq!(resume["from_seq"].as_u64(), Some(last_before + 1));
    assert_eq!(events.last().unwrap()["final"], true);
    after.iter().map(|e| e["route"].as_str().unwrap().to_owned()).collect()
}

#[test]
fn the_capability_line_has_the_probe_gates_fields_and_ssh_is_unavailable() {
    let caps = capabilities(&this_build());
    assert_eq!(caps["routes"], json!(["relay"]));
    assert_eq!(caps["faults"], json!(["kill-route"]));
    assert_eq!(caps["carriers"]["relay"]["available"], true);
    assert_eq!(caps["carriers"]["relay"]["probe"], true);
    assert_eq!(caps["carriers"]["relay"]["faults"], json!(["kill-route"]));
    assert_eq!(caps["carriers"]["ssh"]["available"], false);
    assert_eq!(caps["carriers"]["ssh"]["faults"], json!([]));
    assert!(caps["carriers"]["ssh"]["reason"].as_str().unwrap().contains("ssh"));
    assert_eq!(caps["fault_gate"]["env"], "CMUX_CARRIER_PROBE_FAULTS");
    assert_eq!(routes(&this_build()), vec![Route::Relay]);
}

#[test]
fn the_fault_spec_parses_both_keys_once() {
    assert_eq!(parse_spec("kill-route=relay,after-events=3"), Ok(spec(3)));
    assert_eq!(parse_spec("after-events=7,kill-route=relay"), Ok(spec(7)));
    assert_eq!(
        parse_spec("kill-route=ssh,after-events=1"),
        Ok(FaultSpec { kill: Route::Ssh, after_events: 1 })
    );
    for bad in [
        "",
        "kill-route=relay",
        "after-events=3",
        "kill-route=relay,after-events=0",
        "kill-route=relay,after-events=10001",
        "kill-route=relay,after-events=-1",
        "kill-route=wg,after-events=3",
        "kill-route=relay,after-events=3,kill-route=relay",
        "kill-route=relay,after-events=3,extra=1",
        "kill-route relay",
    ] {
        assert!(parse_spec(bad).is_err(), "{bad:?} parsed");
    }
}

#[test]
fn only_probe_accounts_pass_the_gate() {
    for probe in [
        "cmux-cloud-capture-prod@manaflow.dev",
        " CMUX-Cloud-Capture-Prod@manaflow.dev ",
        "cmux-cloud-capture@manaflow.dev",
        "cmux-cloud-capture-journey@manaflow.dev",
        "cmux-cloud-capture-guest@manaflow.dev",
        "cmux-cloud-capture-journey-prod@manaflow.dev",
        "cmux-prod-smoke+run1@manaflow.dev",
        "cmux-staging-bench+x@manaflow.dev",
    ] {
        assert!(probe_account(probe), "{probe}");
    }
    for person in [
        "leo@manaflow.ai",
        "someone@gmail.com",
        "cmux-cloud-capture-prod@manaflow.dev.evil.com",
        "cmux-cloud-capture-prod@evil.manaflow.dev",
        "x-cmux-cloud-capture-prod@manaflow.dev",
        "cmux-prod-smoke@manaflow.dev",
        "cmux-prod-other+a@manaflow.dev",
        "cmux-cloud-capture-prod+a@manaflow.dev",
        "cmux-cloud-capture-staging@manaflow.dev",
        "cmux-cloud-capture-other@manaflow.dev",
        "",
    ] {
        assert!(!probe_account(person), "{person}");
    }
    let probe = Some("cmux-cloud-capture-prod@manaflow.dev");
    assert_eq!(probe_gate(Some("1"), probe), Ok(()));
    assert_eq!(probe_gate(None, probe), Err(GateRefusal::NotProbeRun));
    assert_eq!(probe_gate(Some("true"), probe), Err(GateRefusal::NotProbeRun));
    assert_eq!(probe_gate(Some("1"), Some("leo@manaflow.ai")), Err(GateRefusal::NotProbeAccount));
    assert_eq!(probe_gate(Some("1"), None), Err(GateRefusal::NotProbeAccount));
}

#[test]
fn killing_the_relay_with_no_other_route_is_a_typed_refusal_before_the_turn() {
    let caps = capabilities(&this_build());
    let refused = FaultPlan::new(spec(3), routes(&this_build()), &caps).unwrap_err();
    assert_eq!(refused.code, "carrier_fault.no_other_route");
    assert!(refused.message.contains("ssh"), "{}", refused.message);
    assert_eq!(
        refused.record["capabilities"],
        json!({"routes": ["relay"], "faults": ["kill-route"]})
    );
    assert_eq!(refused.record["kill"], Value::Null);
    assert_eq!(refused.record["events"], json!([]));
    assert_eq!(refused.record["resumes"], json!([]));
    assert_eq!(refused.record["fault"], json!({"kill_route": "relay", "after_events": 3}));

    let ssh_first = FaultPlan::new(spec(3), vec![Route::Ssh, Route::Relay], &caps).unwrap_err();
    assert_eq!(ssh_first.code, "carrier_fault.route_not_in_use");
    let none = FaultPlan::new(spec(3), Vec::new(), &caps).unwrap_err();
    assert_eq!(none.code, "carrier_fault.no_route");
}

#[tokio::test]
async fn a_relay_to_relay_drill_loses_and_repeats_nothing() {
    let first = Carrier { events: turn(10), ..Carrier::default() };
    // The second relay replays two events the client already has: they are not delivered again.
    let second = Carrier { events: turn(10), overlap: 2, ..Carrier::default() };
    let killed = first.killed.clone();
    let (mut fake, opens) = routes_of(vec![first, second]);
    let plan = FaultPlan::new(spec(4), vec![Route::Relay, Route::Relay], &caps_with_ssh()).unwrap();
    let record = run_drill(&plan, &mut fake, caps_with_ssh(), deadline()).await.unwrap();
    assert!(killed.load(Ordering::SeqCst), "the first relay was not killed");
    assert_eq!(
        *opens.lock().unwrap(),
        vec![(0, Route::Relay, None), (1, Route::Relay, Some(4))],
        "the resume asks from the last seq the client had"
    );
    assert_eq!(seqs(&record), (1..=10).collect::<Vec<_>>());
    assert_eq!(record["resumes"][0]["phase"], "connect");
    assert_eq!(record["resumes"][1]["route"], "relay");
    // The judge's other rules hold; the route after the kill is the relay again, which the
    // judge reads as failover.carrier_not_killed, never as an ssh failover.
    assert!(judged_after_kill(&record).iter().all(|route| route == "relay"));
}

#[tokio::test]
async fn a_relay_to_ssh_drill_is_the_record_the_judge_passes() {
    let relay = Carrier { events: turn(9), ..Carrier::default() };
    let ssh = Carrier { events: turn(9), ..Carrier::default() };
    let (mut fake, _) = routes_of(vec![relay, ssh]);
    let plan = FaultPlan::new(spec(5), vec![Route::Relay, Route::Ssh], &caps_with_ssh()).unwrap();
    let record = run_drill(&plan, &mut fake, caps_with_ssh(), deadline()).await.unwrap();
    assert_eq!(judged_after_kill(&record), vec!["ssh"; 4]);
    assert_eq!(record["capabilities"], caps_with_ssh());
    assert_eq!(
        record["resumes"][1],
        json!({
            "route": "ssh", "phase": "resume", "outcome": "ok", "from_seq": 6,
            "ms": record["resumes"][1]["ms"],
        })
    );
}

#[tokio::test]
async fn a_refused_resume_is_a_typed_error_with_the_record() {
    let relay = Carrier { events: turn(9), ..Carrier::default() };
    let ssh = Carrier { refuse: true, ..Carrier::default() };
    let (mut fake, _) = routes_of(vec![relay, ssh]);
    let plan = FaultPlan::new(spec(2), vec![Route::Relay, Route::Ssh], &caps_with_ssh()).unwrap();
    let error = run_drill(&plan, &mut fake, caps_with_ssh(), deadline()).await.unwrap_err();
    assert_eq!(error.code, "carrier_fault.resume_failed");
    assert_eq!(seqs(&error.record), vec![1, 2]);
    assert_eq!(error.record["kill"]["route"], "relay");
    assert_eq!(error.record["resumes"][1]["outcome"], "error");
    assert_eq!(error.record["resumes"][1]["from_seq"], 3);
}

#[tokio::test(start_paused = true)]
async fn a_stalled_carrier_ends_at_the_deadline_never_hangs() {
    let relay = Carrier { events: turn(9), ..Carrier::default() };
    let ssh = Carrier { events: turn(9), stall_after: Some(1), ..Carrier::default() };
    let (mut fake, _) = routes_of(vec![relay, ssh]);
    let plan = FaultPlan::new(spec(3), vec![Route::Relay, Route::Ssh], &caps_with_ssh()).unwrap();
    let error = run_drill(&plan, &mut fake, caps_with_ssh(), deadline()).await.unwrap_err();
    assert_eq!(error.code, "carrier_fault.timeout");
    assert_eq!(seqs(&error.record), vec![1, 2, 3, 4]);
}

#[tokio::test]
async fn a_turn_that_ends_before_the_kill_says_so() {
    let relay = Carrier { events: turn(3), ..Carrier::default() };
    let ssh = Carrier { events: turn(3), ..Carrier::default() };
    let (mut fake, opens) = routes_of(vec![relay, ssh]);
    let plan = FaultPlan::new(spec(5), vec![Route::Relay, Route::Ssh], &caps_with_ssh()).unwrap();
    let record = run_drill(&plan, &mut fake, caps_with_ssh(), deadline()).await.unwrap();
    // No kill: the judge reads failover.drill_missing, never a pass.
    assert_eq!(record["kill"], Value::Null);
    assert_eq!(opens.lock().unwrap().len(), 1);
}

#[test]
fn capabilities_takes_only_its_json_flag() {
    let words = |text: &str| text.split_whitespace().map(str::to_owned).collect::<Vec<_>>();
    assert!(super::super::parse_capabilities(&words("capabilities")));
    assert!(super::super::parse_capabilities(&words("capabilities --json")));
    assert!(!super::super::parse_capabilities(&words("capabilities --json --json")));
    assert!(!super::super::parse_capabilities(&words("capabilities --machine vm_x")));
    assert!(!super::super::parse_capabilities(&words("capability")));
}

/// The accepted test accounts are exactly the ones the provisioner makes
/// (`Target("…@manaflow.dev"` in scripts/ci/cloud_capture_provision.py), so a
/// renamed or added account fails here rather than refusing its probe.
#[test]
fn the_probe_accounts_are_the_provisioners_accounts() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../scripts/ci/cloud_capture_provision.py");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    let mut provisioned: Vec<&str> = text
        .split("Target(\"")
        .skip(1)
        .filter_map(|rest| rest.split('"').next())
        .filter(|email| email.ends_with("@manaflow.dev"))
        .collect();
    provisioned.sort_unstable();
    let mut accepted = super::PROBE_ACCOUNTS.to_vec();
    accepted.sort_unstable();
    assert!(provisioned.len() >= 5, "the provisioner lost its targets: {provisioned:?}");
    assert_eq!(accepted, provisioned);
    assert!(provisioned.iter().all(|email| probe_account(email)));
}

/// The canary rule is web's `isSyntheticAccountEmail` (web/services/analytics/syntheticAccounts.ts,
/// `^cmux-(?:prod|staging)-(?:smoke|stress|bench)\+[^@\s]*@manaflow\.dev$`, case-insensitive, on the
/// trimmed address). It has no TS test of its own, so these examples pin that regex's answers, including
/// the shapes web/scripts/cloud-vm mints (`cmux-${stage}-stress+${suffix}`, `-bench+`).
#[test]
fn canary_accounts_follow_webs_synthetic_account_rule() {
    for synthetic in [
        "cmux-prod-smoke+1730000000000@manaflow.dev",
        "cmux-staging-stress+abc-123@manaflow.dev",
        "cmux-prod-bench+run.7@manaflow.dev",
        "cmux-prod-smoke+@manaflow.dev",
        "cmux-prod-smoke+a+b@manaflow.dev",
        "CMUX-PROD-SMOKE+X@MANAFLOW.DEV",
        "  cmux-staging-smoke+x@manaflow.dev\n",
    ] {
        assert!(probe_account(synthetic), "{synthetic:?}");
    }
    for person in [
        "cmux-prod-smoke@manaflow.dev",
        "cmux-dev-smoke+x@manaflow.dev",
        "cmux-prod-load+x@manaflow.dev",
        "cmux-prod-smoke+a b@manaflow.dev",
        "cmux-prod-smoke+a@b@manaflow.dev",
        "cmux-prod-smoke+x@manaflow.dev.evil",
        "cmux-prod-smoke+x@evil.manaflow.dev",
        "xcmux-prod-smoke+x@manaflow.dev",
    ] {
        assert!(!probe_account(person), "{person:?}");
    }
}
