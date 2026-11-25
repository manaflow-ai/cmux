//! Fault scenario `pause-vm` + `http 503` (cmuxterm-hq design
//! remote-cloud-durability, row F11): a paused Cloud machine whose resume
//! fails with 502 or 503, or 404 by label, and Reconnect that must wake it.
//!
//! Within a stated bound (30 s of backoff waits, `ops::start_retry::BOUND`)
//! the resume either succeeds or names the step that failed, and no retry
//! repeats a deterministic failure:
//!
//! - a 503 (`cloud.provider.unavailable`) or a 502 (`owner.unreachable`, or a
//!   gateway answer with no declared code) is retried with growing waits and
//!   recovers once the fault clears;
//! - a 404 by label, or another final refusal, is asked once, answers at once
//!   and says which step failed and why;
//! - Reconnect wakes a paused machine through the same faults: in the app,
//!   Reconnect on a paused machine runs Resume Machine (`cloud.machine.start`,
//!   the cases above); a connect (`cloud.machine.connect`) starts a paused
//!   machine itself, which the reconnect cases below drive.
//!
//! The serve loop runs for real (`serve_with`); the platform API is the fake
//! control plane with an `http` fault script, and the loop's timers run on a
//! manual clock, so a run takes milliseconds. `FAULT_SEEDS` (default 20)
//! runs the seeded mix that many times; a failing run prints its seed.

mod attach_common;
mod common;
mod edge_common;
mod serve_common;

use attach_common::{FakeSpawner, FakeTransport, ManualClock, attach};
use cmux_cloud::WireError;
use cmux_cloud::ports::Edge;
use edge_common::{FakeTransfer, FakeTunnel};
use serde_json::{Value, json};
use serve_common::Host;
use std::sync::Arc;
use std::time::Duration;

const PAUSED: &str = "vm_beta02";
/// The resume bound the scenario holds the server to.
const BOUND: Duration = Duration::from_secs(30);
/// Retries of a fault that never clears: the waits 0.5+1+2+4+8+8 s fit in
/// [`BOUND`], one more 8 s wait does not.
const RETRIES_IN_BOUND: usize = 6;

fn host_with_clock() -> (Host, ManualClock) {
    let clock = ManualClock::default();
    let spawner = FakeSpawner::default();
    let attach =
        attach(&spawner, &FakeTransport::default()).with_wait_clock(Arc::new(clock.clone()));
    let edge = Edge::new(Arc::new(FakeTunnel::default()), Box::new(FakeTransfer::default()));
    let mut host = Host::start_with(&["vm-list", "vm-resume"], spawner, attach, edge);
    // Fault `pause-vm`: the listed machine is paused.
    host.answer_of("list", "cloud.machine.list", json!({}));
    (host, clock)
}

fn refusal(code: &str, message: &str, retryable: bool) -> WireError {
    WireError { code: code.into(), message: message.into(), details: None, retryable }
}

/// A 503 from the platform: the provider could not resume the machine now.
fn http_503() -> WireError {
    refusal("cloud.provider.unavailable", "Cloud VM temporarily unavailable", true)
}

/// A 502 from the platform: its owner object did not answer. The host marks
/// only a 503 retryable, so the body says `retryable: false`.
fn http_502_owner() -> WireError {
    refusal("owner.unreachable", "the machine's owner did not answer", false)
}

/// A 502 from a gateway in front of the platform: a code `cloud.machine.start`
/// does not declare (the outcome is unknown).
fn http_502_gateway() -> WireError {
    refusal("vm_cloud_service_unavailable", "HTTP 502: vm_cloud_service_unavailable", false)
}

/// A 404: no machine of that id (a label passed where an id goes).
fn http_404() -> WireError {
    refusal("cloud.machine.not_found", "no such machine in this team", false)
}

/// What the server answered and the backoff waits it asked for meanwhile.
struct Settled {
    result: Value,
    waits: Vec<Duration>,
}

/// Reads until op `id` answers, firing the loop's timers when it waits:
/// each pause must hold exactly one timer (one parked op).
fn settle(host: &mut Host, clock: &ManualClock, id: &str) -> Settled {
    let mut waits = Vec::new();
    // About 20 s in all on a loaded runner; a run that works takes milliseconds.
    for _ in 0..400 {
        if let Some(line) = host.next_within(Duration::from_millis(50)) {
            if line["type"] == "result" && line["id"] == id {
                assert!(clock.pending_delays().is_empty(), "a timer outlived its op: {line}");
                return Settled { result: line, waits };
            }
            continue;
        }
        let pending = clock.pending_delays();
        if pending.is_empty() {
            // Quiet but no timer yet: the op is still on its way.
            continue;
        }
        assert_eq!(pending.len(), 1, "op {id} waits on one timer, not {pending:?}");
        waits.push(pending[0]);
        assert_eq!(clock.fire_all(), 1);
    }
    panic!("op {id} never answered; waits so far {waits:?}");
}

fn start(host: &Host, id: &str, machine: &str, key: &str) {
    host.send(&json!({ "type": "op", "id": id, "op": "cloud.machine.start",
        "args": { "machine": machine }, "origin": "user", "idempotency_key": key }));
}

fn reconnect(host: &Host, id: &str) {
    host.send(&json!({ "type": "op", "id": id, "op": "cloud.machine.connect",
        "args": { "machine": PAUSED }, "origin": "user", "idempotency_key": format!("rc-{id}") }));
}

/// The waits of `n` retries: 0.5 s, doubling, at most 8 s.
fn backoff(n: usize) -> Vec<Duration> {
    (0..n)
        .map(|i| Duration::from_millis(500 * (1u64 << i.min(4))).min(Duration::from_secs(8)))
        .collect()
}

/// A resume through `faults` (each transient) recovers once they clear, with
/// growing waits inside the bound and the same idempotency key every time.
fn resume_recovers(faults: Vec<WireError>, seed: u64) {
    let (mut host, clock) = host_with_clock();
    let n = faults.len();
    host.cloud.fault_start(faults);
    start(&host, "r", PAUSED, "resume-1");
    let Settled { result, waits } = settle(&mut host, &clock, "r");
    assert_eq!(
        result["ok"], true,
        "seed {seed}: the resume recovers once the fault clears: {result}"
    );
    assert_eq!(result["result"]["machine"]["status"], "running", "seed {seed}: {result}");
    assert_eq!(waits, backoff(n), "seed {seed}: one growing wait per refusal");
    assert!(waits.iter().sum::<Duration>() <= BOUND, "seed {seed}: {waits:?}");
    let starts = host.cloud.starts();
    assert_eq!(starts.len(), n + 1, "seed {seed}: one try per refusal, then the start");
    assert!(
        starts.iter().all(|c| c.idempotency_key.as_deref() == Some("resume-1")),
        "seed {seed}: every try carries the caller's key: {starts:?}"
    );
}

/// A final refusal is asked once and answers at once, naming the step.
fn resume_refused(fault: WireError, seed: u64) -> Value {
    let (mut host, clock) = host_with_clock();
    let code = fault.code.clone();
    host.cloud.fault_start_always(fault);
    start(&host, "r", PAUSED, "resume-1");
    let Settled { result, waits } = settle(&mut host, &clock, "r");
    assert!(waits.is_empty(), "seed {seed}: {code} is final, never waited out: {waits:?}");
    assert_eq!(host.cloud.starts().len(), 1, "seed {seed}: {code} is asked once");
    assert_eq!(result["ok"], false, "{result}");
    assert_eq!(result["error"]["retryable"], false, "seed {seed}: {result}");
    assert_eq!(
        result["error"]["step"], "start",
        "seed {seed}: the answer names the step: {result}"
    );
    assert_eq!(result["error"]["upstream_code"], code.as_str(), "{result}");
    result
}

#[test]
fn a_503_resume_retries_with_growing_waits_and_recovers_when_the_fault_clears() {
    resume_recovers(vec![http_503(), http_503(), http_503()], 0);
}

#[test]
fn a_502_resume_is_retried_too() {
    resume_recovers(vec![http_502_owner(), http_502_gateway(), http_503()], 0);
}

#[test]
fn a_fault_that_never_clears_ends_inside_the_bound_and_names_the_step() {
    let (mut host, clock) = host_with_clock();
    host.cloud.fault_start_always(http_503());
    start(&host, "r", PAUSED, "resume-1");
    let Settled { result, waits } = settle(&mut host, &clock, "r");
    assert_eq!(waits, backoff(RETRIES_IN_BOUND), "{result}");
    assert!(waits.iter().sum::<Duration>() <= BOUND);
    assert_eq!(host.cloud.starts().len(), RETRIES_IN_BOUND + 1);
    assert_eq!(result["ok"], false, "{result}");
    assert_eq!(result["error"]["code"], "cmux.cloud.provider_unavailable", "{result}");
    assert_eq!(result["error"]["step"], "start", "{result}");
    assert_eq!(result["error"]["retryable"], true, "a later Resume may work: {result}");
    let message = result["error"]["message"].as_str().unwrap_or_default();
    assert!(message.contains("start step") && message.contains("7 tries"), "{message}");
}

#[test]
fn a_404_by_label_is_not_retried_and_says_which_machine_has_that_name() {
    let (mut host, clock) = host_with_clock();
    // The machine `vm ls` shows as probe-b.
    let mut labelled = common::link_machine(PAUSED, "paused");
    labelled["name"] = json!("probe-b");
    labelled["revision"] = json!("2");
    host.send(&json!({ "type": "team.event", "event": "cloud.machine.upsert",
        "data": { "machine": labelled } }));
    // Lifecycle dispatch now reads before preparing a resume. A label is
    // already absent at that boundary, so no mutation may be sent.
    let absent = http_404();
    host.cloud.wire.answer(
        "cloud.machine.get",
        json!({"machine": "probe-b"}),
        None,
        json!({"error": {"code": absent.code, "message": absent.message,
            "retryable": absent.retryable}}),
    );
    start(&host, "r", "probe-b", "resume-1");
    let Settled { result, waits } = settle(&mut host, &clock, "r");
    assert!(waits.is_empty(), "{waits:?}");
    assert!(host.cloud.starts().is_empty(), "a missing subject never reaches a mutation");
    assert_eq!(
        host.cloud.wire.calls.iter().filter(|call| call.op == "cloud.machine.get").count(),
        1,
        "the authoritative 404 is read once"
    );
    assert_eq!(result["error"]["code"], "cmux.cloud.not_found", "{result}");
    assert_eq!(result["error"]["retryable"], false, "{result}");
    assert_eq!(result["error"]["step"], "start", "{result}");
    let message = result["error"]["message"].as_str().unwrap_or_default();
    assert!(message.contains("Not retried"), "{message}");
    assert!(message.contains(PAUSED), "it names the machine called probe-b: {message}");
}

#[test]
fn reconnect_wakes_a_paused_machine_through_a_503() {
    let (mut host, clock) = host_with_clock();
    host.cloud.fault_start([http_503(), http_502_owner()]);
    reconnect(&host, "c");
    let Settled { result, waits } = settle(&mut host, &clock, "c");
    assert_eq!(result["ok"], true, "Reconnect wakes the paused machine: {result}");
    assert_eq!(result["result"]["machine"], PAUSED, "{result}");
    assert_eq!(result["result"]["state"], "up", "{result}");
    assert_eq!(waits, backoff(2));
    assert_eq!(host.cloud.starts().len(), 3);
}

#[test]
fn reconnect_on_a_final_refusal_names_the_step_and_asks_once() {
    let (mut host, clock) = host_with_clock();
    host.cloud.fault_start_always(refusal("cloud.plan.required", "this needs a paid plan", false));
    reconnect(&host, "c");
    let Settled { result, waits } = settle(&mut host, &clock, "c");
    assert!(waits.is_empty(), "{waits:?}");
    assert_eq!(host.cloud.starts().len(), 1);
    assert_eq!(result["error"]["code"], "cmux.cloud.plan_required", "{result}");
    assert_eq!(result["error"]["step"], "start", "{result}");
}

/// A small deterministic generator for the seeded mix (no dependency).
struct Seeded(u64);

impl Seeded {
    fn next(&mut self, below: u64) -> u64 {
        self.0 =
            self.0.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        (self.0 >> 33) % below
    }
}

#[test]
fn seeded_pause_vm_and_http_faults_either_recover_or_name_the_step() {
    let seeds: u64 = std::env::var("FAULT_SEEDS").ok().and_then(|s| s.parse().ok()).unwrap_or(20);
    let base: u64 = std::env::var("FAULT_SEED_BASE").ok().and_then(|s| s.parse().ok()).unwrap_or(0);
    for seed in base..base + seeds {
        let mut rng = Seeded(seed);
        if rng.next(4) == 0 {
            let fault = match rng.next(3) {
                0 => http_404(),
                1 => refusal("cloud.plan.required", "this needs a paid plan", false),
                _ => refusal("cloud.quota.exceeded", "the plan's machines are all in use", false),
            };
            resume_refused(fault, seed);
            println!("fault: seed {seed} final refusal: asked once");
            continue;
        }
        let n = rng.next(RETRIES_IN_BOUND as u64 + 1) as usize;
        let faults = (0..n)
            .map(|_| match rng.next(3) {
                0 => http_503(),
                1 => http_502_owner(),
                _ => http_502_gateway(),
            })
            .collect();
        resume_recovers(faults, seed);
        println!("fault: seed {seed} {n} transient refusals: recovered");
    }
}
