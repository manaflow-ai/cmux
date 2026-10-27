//! Request flows (p09-observability task 103): the hash both sides derive,
//! and the daemon's flow-in and flow-out of each request it answers. The
//! traced case runs in a child of this test binary, so the process-wide
//! trace state never reaches another test.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::{Arc, Mutex};

use cmux_trace::{Phase, Role, decode};
use serde_json::{Value, json};

use super::super::client_hello::tests::Client;
use super::super::client_hello::{HelloGate, Peer};
use super::super::client_registry::ClientTransport;
use super::super::connection_frame::handle_connection_frame;
use super::super::connection_scheduler::ConnectionSurfaceScheduler;
use super::super::tests::{captured_writer, test_mux};
use super::super::{
    BoundedOutbound, BudgetedText, MessageSink, MessageWriter, Mux, OutboundStream, QueuedSink,
};
use super::{RequestFlowSeed, send_reader_reply};

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

/// When the first control line with each numeric id (or the decimal string
/// of one) went into the outbound queue, on the trace clock.
type Queued = Arc<Mutex<BTreeMap<u64, u64>>>;

/// A captured writer's sink that also stamps when each reply is queued.
struct StampedSink {
    inner: QueuedSink,
    queued: Queued,
}

impl MessageSink for StampedSink {
    fn send_initial(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.inner.send_initial(text, stream)
    }

    fn send_stream(&self, text: Arc<BudgetedText>, stream: &OutboundStream) -> std::io::Result<()> {
        self.inner.send_stream(text, stream)
    }

    fn send_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()> {
        let at = cmux_trace::clock::now_ns();
        let id = serde_json::from_str::<Value>(&text).ok().and_then(|line| match line.get("id") {
            Some(Value::Number(number)) => number.as_u64(),
            Some(Value::String(text)) => text.parse().ok(),
            _ => None,
        });
        if let Some(id) = id {
            self.queued.lock().expect("queued").entry(id).or_insert(at);
        }
        self.inner.send_control(text)
    }

    fn send_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.inner.send_terminal(text, stream)
    }

    fn send_ordered_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.inner.send_ordered_terminal(text, stream)
    }

    fn is_open(&self) -> bool {
        self.inner.is_open()
    }

    fn close(&self) {
        self.inner.close();
    }
}

/// A writer that captures its lines and stamps when each reply is queued.
fn stamped_writer() -> (MessageWriter, Arc<BoundedOutbound>, Queued) {
    let outbound = Arc::new(BoundedOutbound::default());
    let queued = Queued::default();
    let sink = StampedSink {
        inner: QueuedSink { outbound: outbound.clone(), control: None },
        queued: queued.clone(),
    };
    (MessageWriter::new(sink), outbound, queued)
}

/// Sends each line through the frame handler of a new connection to `mux`
/// on `writer`, then drains its dispatcher; the replies.
fn run_lines(
    mux: &Arc<Mux>,
    (writer, outbound): (MessageWriter, Arc<BoundedOutbound>),
    lines: &[String],
) -> Vec<Value> {
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

/// The child half of the traced tests (does nothing in a normal run): its
/// mode names the test.
#[test]
fn request_flow_child_process() {
    let Some(dir) = std::env::var_os("CMUX_REQUEST_FLOW_CHILD_DIR") else { return };
    cmux_trace::init_blackbox(Path::new(&dir), Role::Daemon)
        .expect("first init")
        .wait()
        .expect("the black box moved into its file");
    match std::env::var("CMUX_REQUEST_FLOW_CHILD_MODE").as_deref() {
        Ok("lines") => child_requests(),
        Ok("socket") => child_hello_over_a_connection(),
        mode => panic!("unknown child mode {mode:?}"),
    }
}

/// Runs [`request_flow_child_process`] in `mode` in a child of this binary.
fn run_child(mode: &str) {
    let dir = std::env::temp_dir().join(format!("cmux-request-flow-{mode}-{}", std::process::id()));
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
        .env("CMUX_REQUEST_FLOW_CHILD_MODE", mode)
        .status()
        .expect("runs the child");
    let _ = std::fs::remove_dir_all(&dir);
    assert!(status.success(), "the child failed (see its output above)");
}

#[test]
fn request_flow_each_request_is_one_chain() {
    run_child("lines");
}

/// A client-hello on a real connection: the reader answers it, as the
/// line's flow (finding: replies the reader wrote itself had no flow).
#[test]
fn request_flow_client_hello_over_a_connection_is_one_chain() {
    run_child("socket");
}

/// Each `daemon.request` flow in the trace so far: its records' (phase,
/// time), in time order.
fn recorded_flows() -> BTreeMap<u64, Vec<(Phase, u64)>> {
    let decoded = decode(&cmux_trace::snapshot_active().expect("initialised")).expect("decodes");
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
    flows
}

/// Each flow of `expected` (flow -> what it is) is one flow-in then one
/// flow-out, and no other flow was recorded.
fn assert_chains(flows: &BTreeMap<u64, Vec<(Phase, u64)>>, expected: &BTreeMap<u64, String>) {
    assert_eq!(
        flows.keys().collect::<Vec<_>>(),
        expected.keys().collect::<Vec<_>>(),
        "one flow per numeric request id, none from an unseeded connection: {flows:?}"
    );
    for (flow, chain) in flows {
        let phases: Vec<Phase> = chain.iter().map(|(phase, _)| *phase).collect();
        assert_eq!(
            phases,
            [Phase::FlowIn, Phase::FlowOut],
            "{} is not received then answered once: {chain:?}",
            expected[flow]
        );
    }
}

fn child_hello_over_a_connection() {
    let mux = test_mux();
    // The peer is this process, as the kernel reports it at accept.
    let seed = RequestFlowSeed::of_pid(std::process::id());
    let mut client = Client::connect(&mux, "request-flow");
    let hello = client.request(json!({"cmd": "client-hello", "role": "main"}));
    let hello_read = cmux_trace::clock::now_ns();
    assert_eq!(hello["ok"], true, "{hello}");
    assert_eq!(client.request(json!({"cmd": "ping"}))["ok"], true);
    drop(client);

    let flows = recorded_flows();
    let expected: BTreeMap<u64, String> = [
        (seed.flow_of(1), "the client-hello".to_owned()),
        (seed.flow_of(2), "the ping after the hello".to_owned()),
    ]
    .into();
    assert_chains(&flows, &expected);
    let hello_out = flows[&seed.flow_of(1)][1].1;
    assert!(hello_out <= hello_read, "the client read the hello's reply before its flow-out");
}

fn child_requests() {
    let resource = json!({"protocol":"cmux.protocol/2","type":"request","id":"7",
        "operation":"session.ping","params":{"machine":"current","session":"current"}});
    let lines: Vec<String> = [
        json!({"id":1,"cmd":"ping"}),
        json!({"id":2,"cmd":"ping"}),
        json!({"id":3,"cmd":"ping"}),
        // Answered by a worker (an async reply).
        json!({"id":5,"cmd":"url-open","terminal_id":"t-none","url":"https://example.com"}),
        // A v2 resource line: its handler queues the reply.
        resource,
        // A feature route: it queues its own reply.
        json!({"id":8,"cmd":"energy.status"}),
        // A string id that is no number: no flow.
        json!({"id":"r-1","cmd":"ping"}),
    ]
    .iter()
    .map(Value::to_string)
    .collect();

    // No wire change: the replies are the same with and without flows.
    let mux = test_mux();
    let plain = run_lines(&mux, captured_writer(), &lines);
    let (writer, outbound, queued) = stamped_writer();
    let writer = writer.with_request_flows(RequestFlowSeed::of_pid(PEER_PID));
    let flowing = run_lines(&mux, (writer, outbound), &lines);
    assert_eq!(flowing.len(), lines.len(), "{flowing:?}");
    // By id: the worker's reply (request 5) may come before or after the
    // lines after it.
    let by_id = |replies: Vec<Value>| -> BTreeMap<String, Value> {
        replies.into_iter().map(|reply| (reply["id"].to_string(), reply)).collect()
    };
    assert_eq!(by_id(flowing), by_id(plain), "flows changed a reply");

    // The reader answers a client-hello itself (server/line_connection.rs):
    // the hello gate's reply, sent as the line's flow.
    let (writer, outbound, queued_hello) = stamped_writer();
    let hello_seed = RequestFlowSeed::of_pid(PEER_PID + 1);
    let writer = writer.with_request_flows(hello_seed);
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let mut gate = HelloGate::new(ClientTransport::Unix);
    let line = json!({"id": 1, "cmd": "client-hello", "role": "main"}).to_string();
    let reply = gate.observe(&mux, client, &line, Peer::unknown).expect("the gate answers");
    assert!(send_reader_reply(&writer, &reply));
    let hello: Value = serde_json::from_str(&outbound.try_pop().expect("a reply")).expect("JSON");
    assert_eq!(hello["ok"], true, "{hello}");

    let flows = recorded_flows();
    let seed = RequestFlowSeed::of_pid(PEER_PID);
    let mut expected: BTreeMap<u64, String> =
        [1, 2, 3, 5, 7, 8].map(|id| (seed.flow_of(id), format!("request {id}"))).into();
    expected.insert(hello_seed.flow_of(1), "the client-hello".into());
    assert_chains(&flows, &expected);

    // The client may read a reply as soon as it is queued, so the daemon's
    // flow-out comes first: a route's, a resource handler's and the
    // reader's too.
    let queued = queued.lock().expect("queued");
    for id in [1, 2, 3, 5, 7, 8] {
        let flow_out = flows[&seed.flow_of(id)][1].1;
        let at = queued.get(&id).copied().unwrap_or_else(|| panic!("request {id} was not queued"));
        assert!(flow_out <= at, "request {id}'s flow-out came {}ns after its reply", flow_out - at);
    }
    let hello_out = flows[&hello_seed.flow_of(1)][1].1;
    let hello_queued = queued_hello.lock().expect("queued")[&1];
    assert!(hello_out <= hello_queued, "the hello's flow-out came after its reply");
}
