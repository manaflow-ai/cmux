//! Traced REQUEST frames (p05-ipc-180): the FLOW flag puts the request's
//! trace flow id in front of its body. The reply is the line's reply, the
//! daemon's ring holds the flow's flow-in at the arrival and its flow-out at
//! the reply, and a payload too short for the id is a bad message. The ring
//! case runs in a child of this test binary, so the process-wide trace state
//! never reaches another test.

use std::path::Path;

use cmux_ipc::{Aux, CallAux, CallFlags, FrameHeader, FrameKind};
use cmux_trace::{Phase, Role, decode};
use serde_json::{Value, json};

use super::tests::{Client, Got, method};
use super::{CallRefusal, FLOW_ID_BYTES, REQUEST_FLOW_CAPABILITY};
use crate::server::line_connection::{ConnectionBadMessage, ConnectionEnd};
use crate::server::{Mux, cmd_server};

/// A REQUEST frame of method `name` with the FLOW flag and `payload`
/// after the header (the flow id, then the body, for a well-formed one).
fn flagged(request_id: u32, name: &str, payload: &[u8]) -> Vec<u8> {
    let method = method(name);
    let aux = Aux::Call(CallAux {
        request_id,
        method_id: method.id.raw(),
        priority: method.priority,
        flags: CallFlags::FLOW,
    });
    let len = u32::try_from(payload.len()).unwrap();
    let mut bytes = FrameHeader::new(FrameKind::Request, 0, len, aux).unwrap().encode().to_vec();
    bytes.extend_from_slice(payload);
    bytes
}

/// A traced REQUEST frame: `flow` little endian, then `body`.
fn traced(request_id: u32, flow: u64, body: &Value) -> Vec<u8> {
    let mut payload = flow.to_le_bytes().to_vec();
    payload.extend_from_slice(body.to_string().as_bytes());
    flagged(request_id, body["cmd"].as_str().unwrap(), &payload)
}

fn frame_reply(client: &mut Client, bytes: &[u8]) -> (FrameHeader, Value) {
    client.send(bytes);
    match client.next() {
        Some(Got::Frame(header, reply)) => (header, reply),
        other => panic!("expected a frame reply: {other:?}"),
    }
}

#[test]
fn frame_flow_a_traced_request_replies_like_its_line() {
    let mut client = Client::granted_with("flow-equal", &[]);
    let ping = json!({"id": 7, "cmd": "ping"});
    let line = client.line_reply(&ping);
    let (header, framed) = frame_reply(&mut client, &traced(70, 0x0123_4567_89AB_CDEF, &ping));
    assert_eq!(framed, line, "the flow id is not part of the body");
    let call = header.call().unwrap();
    assert_eq!((header.kind(), call.request_id), (FrameKind::Reply, 70));
    assert_eq!(call.flags, CallFlags::empty(), "the reply echoes no flow");

    // A failing command fails like its line, as an ERROR frame.
    let failing = json!({"id": 8, "cmd": "read-screen", "surface": 987_654});
    let line = client.line_reply(&failing);
    let (header, framed) = frame_reply(&mut client, &traced(80, 9, &failing));
    assert_eq!((header.kind(), framed), (FrameKind::Error, line));

    // Flow 0 is a flagged request with nothing to trace.
    let (header, framed) = frame_reply(&mut client, &traced(90, 0, &json!({"cmd": "ping"})));
    assert_eq!((header.kind(), framed["ok"].clone()), (FrameKind::Reply, json!(true)));
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

/// `identify` offers the flow beside frames, and only there: a client sets
/// FLOW only on a daemon that reads it.
#[test]
fn frame_flow_identify_offers_the_flow_with_frames_only() {
    let mut client = Client::granted_with("flow-offer", &[]);
    let reply = client.line_reply(&json!({"id": 2, "cmd": "identify", "revisions": true}));
    let offered = |identity: &Value| {
        identity["capabilities"]
            .as_array()
            .is_some_and(|all| all.contains(&json!(REQUEST_FLOW_CAPABILITY)))
    };
    assert!(offered(&reply["data"]), "{reply}");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);

    let mux = Mux::new_for_test("frame-flow-no-offer", crate::SurfaceOptions::default());
    let identity = cmd_server::identify(&mux, 0, false, true).unwrap();
    assert!(!offered(&identity), "{identity}");
}

#[test]
fn frame_flow_a_flag_without_its_id_closes_with_bad_message() {
    let mut client = Client::granted_with("flow-truncated", &[]);
    let short = [0u8; FLOW_ID_BYTES - 1];
    client.send(&flagged(3, "ping", &short));
    if let Some(got) = client.next() {
        panic!("the daemon answered a bad message: {got:?}");
    }
    let refusal =
        CallRefusal::FlowTruncated { method_id: method("ping").id.raw(), len: FLOW_ID_BYTES - 1 };
    assert_eq!(refusal.reason(), "flow_truncated");
    assert_eq!(client.finish(), ConnectionEnd::BadMessage(ConnectionBadMessage::Call(refusal)));
}

/// The child half of [`frame_flow_records_one_flow_in_and_out`] (does
/// nothing in a normal run).
#[test]
fn frame_flow_child_process() {
    let Some(dir) = std::env::var_os("CMUX_FRAME_FLOW_CHILD_DIR") else { return };
    child_traced_requests(Path::new(&dir));
}

#[test]
fn frame_flow_records_one_flow_in_and_out() {
    let dir = std::env::temp_dir().join(format!("cmux-frame-flow-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    let status = std::process::Command::new(std::env::current_exe().expect("test binary"))
        .args([
            "--exact",
            "server::frame_dispatch::flow_tests::frame_flow_child_process",
            "--nocapture",
            "--test-threads=1",
        ])
        .env("CMUX_FRAME_FLOW_CHILD_DIR", &dir)
        .status()
        .expect("runs the child");
    let _ = std::fs::remove_dir_all(&dir);
    assert!(status.success(), "the child failed (see its output above)");
}

const TRACED_FLOW: u64 = 0xA3E9_5B7B_0AA2_937A;

fn child_traced_requests(dir: &Path) {
    cmux_trace::init_blackbox(dir, Role::Daemon)
        .expect("first init")
        .wait()
        .expect("the black box moved into its file");
    let mut client = Client::granted_with("flow-ring", &[]);
    let ping = json!({"cmd": "ping"});
    let (header, _) = frame_reply(&mut client, &traced(1, TRACED_FLOW, &ping));
    assert_eq!(header.kind(), FrameKind::Reply);
    // Untraced: no flow record.
    let (header, _) = client.frame_reply(2, &ping);
    assert_eq!(header.kind(), FrameKind::Reply);
    // Flagged with flow 0: no flow record either.
    let (header, _) = frame_reply(&mut client, &traced(3, 0, &ping));
    assert_eq!(header.kind(), FrameKind::Reply);
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);

    let decoded = decode(&cmux_trace::snapshot_active().expect("initialised")).expect("decodes");
    let mut flows: Vec<_> = decoded
        .records
        .iter()
        .filter(|record| decoded.name(record.name) == Some("daemon.request"))
        .filter_map(|record| match Phase::from_raw(record.phase) {
            Some(phase @ (Phase::FlowIn | Phase::FlowOut)) => Some((phase, *record)),
            _ => None,
        })
        .collect();
    flows.sort_by_key(|(_, record)| record.t_ns);
    let ping_id = u64::from(method("ping").id.raw());
    let seen: Vec<_> =
        flows.iter().map(|(phase, record)| (*phase, record.arg1, record.arg0)).collect();
    assert_eq!(
        seen,
        [(Phase::FlowIn, TRACED_FLOW, ping_id), (Phase::FlowOut, TRACED_FLOW, ping_id)],
        "the traced request's arrival, then its reply; no other request has a flow record"
    );
    assert!(flows[0].1.t_ns <= flows[1].1.t_ns);
}
