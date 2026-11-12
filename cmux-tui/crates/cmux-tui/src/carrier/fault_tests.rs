use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::time::Instant;

use super::super::drill::{EventRoutes, EventStream, Opened, TurnEvent, run_drill};
use super::super::ssh::Absent;
use super::{
    FaultPlan, FaultSpec, GateRefusal, Route, capabilities, parse_spec, probe_account, probe_gate,
    routes, this_build,
};

pub(crate) fn turn(last: u64) -> Vec<TurnEvent> {
    (1..=last).map(|seq| TurnEvent { seq, last: seq == last }).collect()
}

/// One fake carrier: the whole turn, and how it misbehaves.
#[derive(Clone, Default)]
pub(crate) struct Carrier {
    pub(crate) events: Vec<TurnEvent>,
    /// A resume replays this many events the client already has.
    pub(crate) overlap: u64,
    /// A resume skips this many events the client never had.
    pub(crate) skip: u64,
    /// Its answer says the seq its stream starts at (else only its first event tells).
    pub(crate) states_from: bool,
    pub(crate) refuse: bool,
    /// The stream never yields after this many events.
    pub(crate) stall_after: Option<usize>,
    pub(crate) killed: Arc<AtomicBool>,
}

/// Every open the drill asked for: the carrier's index, its route and `afterSeq`.
pub(crate) type Opens = Arc<Mutex<Vec<(usize, Route, Option<u64>)>>>;

pub(crate) struct Routes {
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
    ) -> Result<Opened, String> {
        self.opens.lock().unwrap().push((index, route, after_seq));
        let carrier = self.carriers.get(index).cloned().ok_or("no such carrier")?;
        if carrier.refuse {
            return Err("refused".into());
        }
        let from = after_seq
            .map_or(0, |after| after.saturating_sub(carrier.overlap).saturating_add(carrier.skip));
        let events: Vec<_> = carrier.events.into_iter().filter(|e| e.seq > from).collect();
        let stated = events.first().map(|e| e.seq).filter(|_| carrier.states_from);
        let stream = Box::new(Stream {
            events: events.into_iter(),
            stall_after: carrier.stall_after,
            sent: 0,
            killed: carrier.killed,
        });
        Ok(Opened { stream, from_seq: stated })
    }
}

pub(crate) fn routes_of(carriers: Vec<Carrier>) -> (Routes, Opens) {
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
    let caps = capabilities(&this_build(Err(Absent::Tunnel)));
    assert_eq!(caps["routes"], json!(["relay"]));
    assert_eq!(caps["faults"], json!(["kill-route"]));
    assert_eq!(caps["carriers"]["relay"]["available"], true);
    assert_eq!(caps["carriers"]["relay"]["probe"], true);
    assert_eq!(caps["carriers"]["relay"]["faults"], json!(["kill-route"]));
    assert_eq!(caps["carriers"]["ssh"]["available"], false);
    assert_eq!(caps["carriers"]["ssh"]["faults"], json!([]));
    assert_eq!(caps["carriers"]["ssh"]["code"], "no_tunnel");
    assert!(caps["carriers"]["ssh"]["reason"].as_str().unwrap().contains("tunnel hub"));
    assert_eq!(caps["fault_gate"]["env"], "CMUX_CARRIER_PROBE_FAULTS");
    assert_eq!(routes(&this_build(Err(Absent::Key))), vec![Route::Relay]);
}

/// With the dial's check passing, ssh is a route after the relay: what the
/// probe's capability gate needs (`routes` with ssh, `faults` with kill-route).
#[test]
fn the_capability_line_lists_ssh_after_the_relay_when_the_device_has_it() {
    let caps = capabilities(&this_build(Ok(())));
    assert_eq!(caps["routes"], json!(["relay", "ssh"]));
    assert_eq!(caps["faults"], json!(["kill-route"]));
    assert_eq!(caps["carriers"]["ssh"]["available"], true);
    assert_eq!(caps["carriers"]["ssh"]["probe"], true);
    assert_eq!(caps["carriers"]["ssh"].get("reason"), None);
    assert_eq!(caps["carriers"]["ssh"].get("code"), None);
    assert_eq!(routes(&this_build(Ok(()))), vec![Route::Relay, Route::Ssh]);
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
    let carriers = this_build(Err(Absent::Tunnel));
    let caps = capabilities(&carriers);
    let refused = FaultPlan::new(spec(3), routes(&carriers), &caps).unwrap_err();
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
    let second = Carrier { events: turn(10), ..Carrier::default() };
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

/// A server that replays events the client already had across the switch: the record has
/// them twice, as they arrived (the judge's failover.repeated), and the resume's from_seq is
/// where the server started, not the last seq plus one.
#[tokio::test]
async fn a_duplicate_delivered_across_the_switch_is_in_the_record() {
    let relay = Carrier { events: turn(9), ..Carrier::default() };
    let ssh = Carrier { events: turn(9), overlap: 2, ..Carrier::default() };
    let (mut fake, opens) = routes_of(vec![relay, ssh]);
    let plan = FaultPlan::new(spec(5), vec![Route::Relay, Route::Ssh], &caps_with_ssh()).unwrap();
    let record = run_drill(&plan, &mut fake, caps_with_ssh(), deadline()).await.unwrap();
    assert_eq!(opens.lock().unwrap()[1], (1, Route::Ssh, Some(5)), "the client asked after 5");
    assert_eq!(seqs(&record), vec![1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9]);
    let routes: Vec<&str> =
        record["events"].as_array().unwrap().iter().map(|e| e["route"].as_str().unwrap()).collect();
    assert_eq!(routes, [vec!["relay"; 5], vec!["ssh"; 6]].concat());
    assert_eq!(record["resumes"][1]["after_seq"], 5);
    assert_eq!(record["resumes"][1]["from_seq"], 4, "the seq the server resumed from");
    assert_eq!(record["events"].as_array().unwrap().last().unwrap()["final"], true);
}

/// A server that resumes past the seq the client asked from: the record's from_seq is the
/// server's, whether its answer states it or only its first event tells, and the gap shows.
#[tokio::test]
async fn a_server_resuming_from_the_wrong_seq_is_in_the_record() {
    for states_from in [false, true] {
        let relay = Carrier { events: turn(9), ..Carrier::default() };
        let ssh = Carrier { events: turn(9), skip: 2, states_from, ..Carrier::default() };
        let (mut fake, _) = routes_of(vec![relay, ssh]);
        let plan =
            FaultPlan::new(spec(5), vec![Route::Relay, Route::Ssh], &caps_with_ssh()).unwrap();
        let record = run_drill(&plan, &mut fake, caps_with_ssh(), deadline()).await.unwrap();
        assert_eq!(seqs(&record), vec![1, 2, 3, 4, 5, 8, 9], "states_from={states_from}");
        let resume = &record["resumes"][1];
        assert_eq!((resume["after_seq"].as_u64(), resume["from_seq"].as_u64()), (Some(5), Some(8)));
    }
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
            "route": "ssh", "phase": "resume", "outcome": "ok", "after_seq": 5, "from_seq": 6,
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
    // The server never resumed: the record says what the client asked, and no from_seq.
    assert_eq!(error.record["resumes"][1]["after_seq"], 2);
    assert_eq!(error.record["resumes"][1].get("from_seq"), None);
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
fn capabilities_takes_its_json_flag_and_the_dial_s_hub_flag() {
    let words = |text: &str| text.split_whitespace().map(str::to_owned).collect::<Vec<_>>();
    let parse = |text: &str| super::super::parse_capabilities(&words(text));
    assert_eq!(parse("capabilities"), Some(None));
    assert_eq!(parse("capabilities --json"), Some(None));
    let hub = Some(Some(std::path::PathBuf::from("/tmp/hub.sock")));
    assert_eq!(parse("capabilities --wg-hub /tmp/hub.sock"), hub);
    assert_eq!(parse("capabilities --json --wg-hub /tmp/hub.sock"), hub);
    assert_eq!(parse("capabilities --wg-hub relative.sock"), None);
    assert_eq!(parse("capabilities --wg-hub"), None);
    assert_eq!(parse("capabilities --wg-hub /tmp/a.sock --wg-hub /tmp/b.sock"), None);
    assert_eq!(parse("capabilities --wg-hub /tmp/hub.sock --json"), None);
    assert_eq!(parse("capabilities --json --json"), None);
    assert_eq!(parse("capabilities --machine vm_x"), None);
    assert_eq!(parse("capability"), None);
}

/// The provisioner's `Target(...)` calls in scripts/ci/cloud_capture_provision.py: each one's
/// email and whether it names a `team_id` (the account is made a member of a shared team).
fn provisioned_targets() -> Vec<(String, bool)> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../scripts/ci/cloud_capture_provision.py");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    text.split("Target(\"")
        .skip(1)
        .filter_map(|rest| {
            let email = rest.split('"').next()?;
            // The call's arguments run to its closing `)` outside a string: display names
            // such as "cmux cloud probe (production, team)" hold parentheses of their own.
            // `rest` starts inside the email's string.
            let mut in_string = true;
            let close = rest.char_indices().find_map(|(at, c)| match c {
                '"' => {
                    in_string = !in_string;
                    None
                }
                ')' if !in_string => Some(at),
                _ => None,
            })?;
            let args = &rest[..close];
            let team = args.contains("team_id=") && !args.contains("team_id=None");
            email.ends_with("@manaflow.dev").then(|| (email.to_owned(), team))
        })
        .collect()
}

/// The accepted test accounts are exactly the ones the provisioner makes in no shared team
/// (`Target("…@manaflow.dev"` without `team_id=` in scripts/ci/cloud_capture_provision.py), so a
/// renamed or added account fails here rather than refusing its probe. An account the
/// provisioner puts in a team (`team_id=`, such as cmux-cloud-capture-prod-team in the production
/// company team) shares that team's machines with its people, and `cloud start-chat --target`
/// can reach them, so it never takes a carrier fault. The probe teams `--probe-teams` makes are
/// not a `team_id`: they hold only the capture account, which the provisioner checks on every run.
#[test]
fn the_probe_accounts_are_the_provisioners_accounts() {
    let targets = provisioned_targets();
    assert!(targets.len() >= 5, "the provisioner lost its targets: {targets:?}");
    let mut solo: Vec<&str> =
        targets.iter().filter(|(_, team)| !team).map(|(email, _)| email.as_str()).collect();
    solo.sort_unstable();
    let mut accepted = super::PROBE_ACCOUNTS.to_vec();
    accepted.sort_unstable();
    assert_eq!(accepted, solo);
    assert!(solo.iter().all(|email| probe_account(email)));
    let teamed: Vec<&str> =
        targets.iter().filter(|(_, team)| *team).map(|(email, _)| email.as_str()).collect();
    assert!(
        teamed.contains(&"cmux-cloud-capture-prod-team@manaflow.dev"),
        "the provisioner's team account lost its team_id: {targets:?}"
    );
    for email in teamed {
        assert!(!probe_account(email), "{email} is in a shared team and must not take faults");
    }
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
