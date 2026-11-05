//! A connect to a machine that does not run yet (a new machine still
//! binding) waits in the server, not in the client: the op parks until the
//! projection shows the machine running (a team `cloud.machine.upsert`) or
//! its next read is due, and answers once. After `MAX_READS` reads it
//! answers that the machine is starting.

mod attach_common;
mod common;
mod edge_common;
mod serve_common;

use attach_common::{FakeSpawner, FakeTransport, ManualClock, attach};
use cmux_cloud::ports::Edge;
use edge_common::{FakeTransfer, FakeTunnel};
use serde_json::{Value, json};
use serve_common::Host;
use std::sync::Arc;
use std::time::Duration;

const MACHINE: &str = "vm-alpha01";

fn host_with_clock() -> (Host, ManualClock) {
    let clock = ManualClock::default();
    let spawner = FakeSpawner::default();
    let attach =
        attach(&spawner, &FakeTransport::default()).with_wait_clock(Arc::new(clock.clone()));
    let edge = Edge::new(Arc::new(FakeTunnel::default()), Box::new(FakeTransfer::default()));
    (Host::start_with(&["vm-get-unbound"], spawner, attach, edge), clock)
}

fn connect(host: &Host, id: &str) {
    host.send(&json!({ "type": "op", "id": id, "op": "cloud.machine.connect",
        "args": { "machine": MACHINE }, "origin": "user", "idempotency_key": format!("c-{id}") }));
}

/// The result line of op `id` within `wait`, reading past other lines.
fn result_within(host: &mut Host, id: &str, wait: Duration) -> Option<Value> {
    while let Some(line) = host.next_within(wait) {
        if line["type"] == "result" && line["id"] == id {
            return Some(line);
        }
    }
    None
}

fn connect_infos(host: &Host) -> usize {
    host.cloud.ops().iter().filter(|op| *op == "cloud.machine.connect_info").count()
}

#[test]
fn a_connect_to_a_binding_machine_answers_once_its_running_upsert_lands() {
    let (mut host, clock) = host_with_clock();
    connect(&host, "1");
    assert_eq!(result_within(&mut host, "1", Duration::from_millis(300)), None, "it waits");
    let reads = connect_infos(&host);
    // The machine binds; the team event says so (no timer fired, no list read).
    host.cloud.bind_now();
    let mut running = common::link_machine(MACHINE, "running");
    running["revision"] = json!("2");
    host.send(&json!({ "type": "team.event", "event": "cloud.machine.upsert",
        "data": { "machine": running } }));
    let result = result_within(&mut host, "1", serve_common::WAIT).expect("connect answers");
    assert_eq!(result["ok"], true, "{result}");
    assert_eq!(result["result"]["machine"], MACHINE);
    assert!(connect_infos(&host) > reads, "a fresh read after the upsert");
    assert_eq!(clock.fire_all(), 0, "the upsert answered it, not a due read");
    assert!(!host.cloud.ops().iter().any(|op| op == "cloud.machine.list"), "no list read");
}

#[test]
fn a_waiting_connect_reads_its_machine_again_when_the_read_is_due() {
    let (mut host, clock) = host_with_clock();
    connect(&host, "1");
    assert_eq!(result_within(&mut host, "1", Duration::from_millis(300)), None, "it waits");
    host.cloud.bind_now();
    assert_eq!(clock.fire_all(), 1, "one read is due");
    let result = result_within(&mut host, "1", serve_common::WAIT).expect("connect answers");
    assert_eq!(result["ok"], true, "{result}");
}

#[test]
fn a_machine_that_never_runs_answers_starting_after_the_last_read() {
    let (mut host, clock) = host_with_clock();
    connect(&host, "1");
    let mut fired = 0;
    let mut result = None;
    for _ in 0..2000 {
        fired += clock.fire_all();
        if let Some(line) = result_within(&mut host, "1", Duration::from_millis(5)) {
            result = Some(line);
            break;
        }
    }
    let result = result.expect("the connect gives up");
    assert_eq!(fired, 45, "one timer per read (MAX_READS)");
    assert_eq!(result["ok"], false, "{result}");
    assert_eq!(result["error"]["code"], "cmux.cloud.link_down", "{result}");
    assert_eq!(result["error"]["retryable"], true, "{result}");
}

#[test]
fn a_cancelled_waiting_connect_answers_cancelled_and_reads_no_more() {
    let (mut host, clock) = host_with_clock();
    connect(&host, "1");
    assert_eq!(result_within(&mut host, "1", Duration::from_millis(300)), None, "it waits");
    host.send(&json!({ "type": "op.cancel", "id": "1" }));
    let result = result_within(&mut host, "1", serve_common::WAIT).expect("cancel answers");
    assert_eq!(result["error"]["code"], "cmux.op.cancelled", "{result}");
    assert_eq!(clock.fire_all(), 0, "the cancelled op's read timer was dropped");
}

/// One frame of the machine's pushed state (cmux-platform MachineState), as
/// the host passes it on (`apps-team-event`).
fn pushed(host: &Host, status: &str, revision: &str) {
    let mut record = common::link_machine(MACHINE, status);
    record["revision"] = json!(revision);
    host.send(&json!({ "type": "team.event", "event": "cloud.machine.state",
        "data": { "v": 1, "t": "state", "machine": MACHINE, "revision": 1,
            "state": { "machine": MACHINE, "status": status, "awake": status == "running",
                "connected": false, "ready": false, "error": null, "record": record } } }));
}

/// The pushed state reaches the projection with no read: a machine the
/// server never listed nor read shows the pushed record in its watch events.
#[test]
fn a_pushed_state_reaches_the_projection_with_no_read() {
    let (mut host, _clock) = host_with_clock();
    pushed(&host, "paused", "7");
    let watch = loop {
        let line = host.next_within(serve_common::WAIT).expect("a watch event");
        if line["type"] == "event" && line["event"] == "cloud.machine.watch" {
            break line;
        }
    };
    assert_eq!(watch["data"]["type"], "upsert", "{watch}");
    assert_eq!(watch["data"]["machine"]["id"], MACHINE, "{watch}");
    assert_eq!(watch["data"]["machine"]["status"], "paused", "{watch}");
    assert!(host.cloud.ops().is_empty(), "no read at all: {:?}", host.cloud.ops());
    // An older push never undoes a newer one.
    pushed(&host, "running", "6");
    pushed(&host, "running", "8");
    let next = loop {
        let line = host.next_within(serve_common::WAIT).expect("a watch event");
        if line["type"] == "event" && line["event"] == "cloud.machine.watch" {
            break line;
        }
    };
    assert_eq!(next["data"]["machine"]["revision"], "8", "the stale push made no event: {next}");
    assert!(host.cloud.ops().is_empty(), "still no read: {:?}", host.cloud.ops());
}

/// A connect parked on a machine whose state is pushed answers on the push,
/// and reads again only as a 10 s fallback, not every second.
#[test]
fn a_connect_to_a_pushed_machine_answers_on_the_push_not_on_a_read() {
    let (mut host, clock) = host_with_clock();
    pushed(&host, "starting", "2");
    connect(&host, "1");
    assert_eq!(result_within(&mut host, "1", Duration::from_millis(300)), None, "it waits");
    assert_eq!(clock.pending_delays(), vec![Duration::from_secs(10)], "one fallback read, 10 s out");
    host.cloud.bind_now();
    pushed(&host, "running", "3");
    let result = result_within(&mut host, "1", serve_common::WAIT).expect("connect answers");
    assert_eq!(result["ok"], true, "{result}");
    assert_eq!(clock.fire_all(), 0, "the push answered it, not a due read");
}

/// A pushed removal is final: the machine leaves the projection, and a
/// stale state frame that comes after it never brings it back.
#[test]
fn a_pushed_removal_is_final() {
    let (mut host, _clock) = host_with_clock();
    let watch = |host: &mut Host| loop {
        let line = host.next_within(serve_common::WAIT).expect("a watch event");
        if line["type"] == "event" && line["event"] == "cloud.machine.watch" {
            break line;
        }
    };
    pushed(&host, "running", "4");
    assert_eq!(watch(&mut host)["data"]["type"], "upsert");
    host.send(&json!({ "type": "team.event", "event": "cloud.machine.state",
        "data": { "v": 1, "t": "removed", "machine": MACHINE, "revision": 2 } }));
    let removed = watch(&mut host);
    assert_eq!(removed["data"]["type"], "removed", "{removed}");
    pushed(&host, "running", "5");
    pushed(&host, "paused", "3");
    while let Some(line) = host.next_within(Duration::from_millis(300)) {
        assert!(
            !(line["type"] == "event" && line["event"] == "cloud.machine.watch"),
            "a stale frame after the removal made no event: {line}"
        );
    }
    assert!(host.cloud.ops().is_empty(), "no read at all: {:?}", host.cloud.ops());
}
