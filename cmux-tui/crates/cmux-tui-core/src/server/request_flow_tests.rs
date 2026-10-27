//! Request flows (p09-observability task 103): the hash both sides derive,
//! and the daemon's flow-in and flow-out of each request it answers. The
//! traced case runs in a child of this test binary, so the process-wide
//! trace state never reaches another test.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;

use cmux_trace::{Phase, Role, decode};
use serde_json::{Value, json};

use super::super::Mux;
use super::super::client_registry::ClientTransport;
use super::super::connection_frame::handle_connection_frame;
use super::super::connection_scheduler::ConnectionSurfaceScheduler;
use super::super::tests::{captured_writer, test_mux};
use super::RequestFlowSeed;

/// The app's own value for pid 1234, request 1 (LineTransportTests
/// `eachRequestSendsItsFlowFromThePidAndTheRequestID`): both sides derive the
/// same flow.
#[test]
fn request_flow_matches_the_apps_hash() {
    let seed = RequestFlowSeed::of_pid(1234);
    assert_eq!(seed.flow_of(1), 0xa3e9_5b7b_0aa2_937a);
    assert_eq!(seed.flow(Some(&json!(1))), 0xa3e9_5b7b_0aa2_937a);
    assert_eq!(seed.flow(Some(&json!("1"))), 0xa3e9_5b7b_0aa2_937a, "a v2 envelope's id");
}

#[test]
fn request_flow_needs_a_peer_pid_and_a_numeric_id() {
    assert_eq!(RequestFlowSeed::default().flow(Some(&json!(1))), 0);
    assert_eq!(RequestFlowSeed::of_peer_key(None).flow(Some(&json!(1))), 0);
    assert_eq!(RequestFlowSeed::of_peer_key(Some("token:1234.7")), RequestFlowSeed::of_pid(1234));
    let seed = RequestFlowSeed::of_pid(1234);
    for id in [None, Some(json!("r-1")), Some(json!(-1)), Some(json!(1.5)), Some(json!(null))] {
        assert_eq!(seed.flow(id.as_ref()), 0, "{id:?}");
    }
    assert_ne!(seed.flow_of(1), seed.flow_of(2));
    assert_ne!(seed.flow_of(1), RequestFlowSeed::of_pid(1235).flow_of(1));
}

/// The pid the traced connection's peer has.
const PEER_PID: u32 = 4242;

/// Sends each line through the frame handler of a new connection to `mux`
/// whose writer derives flows from `seed`, then drains its dispatcher; the
/// replies.
fn run_lines(mux: &Arc<Mux>, seed: RequestFlowSeed, lines: &[String]) -> Vec<Value> {
    let (writer, outbound) = captured_writer();
    let writer = writer.with_request_flows(seed);
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    for line in lines {
        assert!(handle_connection_frame(
            mux,
            client,
            ClientTransport::Unix,
            line,
            &writer,
            &scheduler
        ));
    }
    scheduler.finish_and_wait();
    std::iter::from_fn(|| outbound.try_pop())
        .map(|text| serde_json::from_str(&text).expect("a JSON reply"))
        .collect()
}

/// The child half of [`request_flow_each_request_is_one_chain`] (does nothing
/// in a normal run).
#[test]
fn request_flow_child_process() {
    let Some(dir) = std::env::var_os("CMUX_REQUEST_FLOW_CHILD_DIR") else { return };
    child_requests(Path::new(&dir));
}

#[test]
fn request_flow_each_request_is_one_chain() {
    let dir = std::env::temp_dir().join(format!("cmux-request-flow-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    let status = std::process::Command::new(std::env::current_exe().expect("test binary"))
        .args([
            "--exact",
            "server::request_flow::tests::request_flow_child_process",
            "--nocapture",
            "--test-threads=1",
        ])
        .env("CMUX_REQUEST_FLOW_CHILD_DIR", &dir)
        .status()
        .expect("runs the child");
    let _ = std::fs::remove_dir_all(&dir);
    assert!(status.success(), "the child failed (see its output above)");
}

fn child_requests(dir: &Path) {
    cmux_trace::init_blackbox(dir, Role::Daemon)
        .expect("first init")
        .wait()
        .expect("the black box moved into its file");
    let resource = json!({"protocol":"cmux.protocol/2","type":"request","id":"7",
        "operation":"session.ping","params":{"machine":"current","session":"current"}});
    let lines: Vec<String> = [
        json!({"id":1,"cmd":"ping"}),
        json!({"id":2,"cmd":"ping"}),
        json!({"id":3,"cmd":"ping"}),
        // Answered by a worker (an async reply).
        json!({"id":5,"cmd":"url-open","terminal_id":"t-none","url":"https://example.com"}),
        resource,
        // A string id that is no number: no flow.
        json!({"id":"r-1","cmd":"ping"}),
    ]
    .iter()
    .map(Value::to_string)
    .collect();

    // No wire change: the replies are the same with and without flows.
    let mux = test_mux();
    let plain = run_lines(&mux, RequestFlowSeed::default(), &lines);
    let flowing = run_lines(&mux, RequestFlowSeed::of_pid(PEER_PID), &lines);
    assert_eq!(flowing.len(), lines.len(), "{flowing:?}");
    assert_eq!(flowing, plain, "flows changed a reply");

    let decoded = decode(&cmux_trace::snapshot_active().expect("initialised")).expect("decodes");
    // Each flow's records in write order: (phase, time).
    let mut flows: BTreeMap<u64, Vec<(Phase, u64)>> = BTreeMap::new();
    for record in &decoded.records {
        let phase = Phase::from_raw(record.phase);
        if decoded.name(record.name) == Some("daemon.request")
            && matches!(phase, Some(Phase::FlowIn | Phase::FlowOut))
        {
            flows.entry(record.arg1).or_default().push((phase.expect("matched"), record.t_ns));
        }
    }
    for chain in flows.values_mut() {
        chain.sort_by_key(|(_, at)| *at);
    }
    let seed = RequestFlowSeed::of_pid(PEER_PID);
    let expected: BTreeMap<u64, u64> = [1, 2, 3, 5, 7].map(|id| (seed.flow_of(id), id)).into();
    assert_eq!(
        flows.keys().collect::<Vec<_>>(),
        expected.keys().collect::<Vec<_>>(),
        "one flow per numeric request id, none from the unseeded connection: {flows:?}"
    );
    for (flow, chain) in &flows {
        let phases: Vec<Phase> = chain.iter().map(|(phase, _)| *phase).collect();
        assert_eq!(
            phases,
            [Phase::FlowIn, Phase::FlowOut],
            "request {} is not received then answered once: {chain:?}",
            expected[flow]
        );
    }
}
