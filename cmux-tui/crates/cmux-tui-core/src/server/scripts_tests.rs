//! `script-*` gates and the script op router (no host binary needed).

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_app_host::script::ScriptRouter;
use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::scripts::router::{DaemonRouter, STREAMS};
use crate::server::{
    BoundedOutbound, ClientTransport, ConnectionSurfaceScheduler, QueuedSink,
    handle_connection_frame,
};

/// A connection over `transport`, bound to an agent when `agent`.
fn connection(
    mux: &Arc<Mux>,
    transport: ClientTransport,
    agent: bool,
) -> (u64, Arc<BoundedOutbound>, MessageWriter) {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(transport, writer.clone());
    if agent {
        mux.bind_conversation_principal(client, "agent:test".to_string()).unwrap();
    }
    (client, outbound, writer)
}

fn reply_to(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    out: &BoundedOutbound,
    request: Value,
) -> Value {
    let message = request.to_string();
    let head = crate::server::RequestHead::parse(&message);
    let line = RouteLine { mux, client, message: &message, writer, head: &head };
    assert_eq!(handle(&line), Some(true));
    serde_json::from_str(&out.try_pop().expect("reply")).unwrap()
}

/// Sends `line` on the local connection `client` through the daemon's frame
/// dispatch, so it reaches this module by its route as a real line does.
/// Returns the reply and the JSON parses the line took.
fn send_line(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    out: &BoundedOutbound,
    line: &str,
) -> (Value, u64) {
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let stats = crate::diagnostics::IpcStats::default();
    {
        let _parses = crate::diagnostics::JsonParseScope::enter(
            &stats,
            crate::diagnostics::IpcTransport::Lines,
        );
        assert!(handle_connection_frame(
            mux,
            client,
            ClientTransport::Unix,
            line,
            writer,
            &scheduler
        ));
    }
    let reply = serde_json::from_str(&out.try_pop().expect("reply")).unwrap();
    (reply, stats.snapshot().parses.lines.json_parses)
}

#[test]
fn agent_bound_and_remote_connections_cannot_run_scripts() {
    let mux = Mux::new_for_test("scripts-gates", SurfaceOptions::default());
    let (agent, agent_out, agent_writer) = connection(&mux, ClientTransport::Unix, true);
    let reply = reply_to(
        &mux,
        agent,
        &agent_writer,
        &agent_out,
        json!({ "id": 1, "cmd": "script-run", "code": "1" }),
    );
    assert_eq!(reply["ok"], false);
    assert_eq!(reply["error_code"], "script.forbidden");
    assert_eq!(reply["id"], 1);
    let (remote, remote_out, remote_writer) = connection(&mux, ClientTransport::WebSocket, false);
    let reply = reply_to(
        &mux,
        remote,
        &remote_writer,
        &remote_out,
        json!({ "id": 2, "cmd": "script-repl-open" }),
    );
    assert_eq!(reply["error_code"], "script.forbidden");
}

#[test]
fn malformed_requests_and_other_commands() {
    let mux = Mux::new_for_test("scripts-malformed", SurfaceOptions::default());
    let (client, out, writer) = connection(&mux, ClientTransport::Unix, false);
    let reply = reply_to(&mux, client, &writer, &out, json!({ "id": 3, "cmd": "script-run" }));
    assert_eq!(reply["error_code"], "bad-request");
    // Not a script command: the route is found by `cmd`, never by a
    // `script-` anywhere else in the line.
    let scripts_route = |cmd: &str| {
        crate::server::routes::find(cmd)
            .is_some_and(|route| route.stage == crate::server::FrameStage::Scripts)
    };
    assert!(scripts_route("script-run"));
    assert!(!scripts_route("identify"));
    let message = r#"{"id":5,"cmd":"apps-list","x":"script-"}"#;
    let head = crate::server::RequestHead::parse(message);
    assert!(!head.cmd().is_some_and(scripts_route));
}

/// The route is found by the line's decoded `cmd`, never a substring of the
/// raw line: a `script-*` name spelled with a JSON escape
/// answers as its plain spelling, and every line takes two parses (the
/// head and the route's one decode).
#[test]
fn scripts_route_by_the_decoded_cmd_and_decode_once() {
    let mux = Mux::new_for_test("scripts-decoded-cmd", SurfaceOptions::default());
    let (client, out, writer) = connection(&mux, ClientTransport::Unix, false);
    let (agent, agent_out, agent_writer) = connection(&mux, ClientTransport::Unix, true);
    // The JSON escape of `-`.
    let dash = "\\u002d";
    // An agent connection is refused by the gate; a line with no `code` by
    // the typed parse.
    for (id, rest) in [(1, r#","code":"1""#), (2, "")] {
        let plain = format!(r#"{{"id":{id},"cmd":"script-run"{rest}}}"#);
        let escaped = format!(r#"{{"id":{id},"cmd":"script{dash}run"{rest}}}"#);
        let (plain_reply, plain_parses) = send_line(&mux, agent, &agent_writer, &agent_out, &plain);
        let (escaped_reply, escaped_parses) =
            send_line(&mux, agent, &agent_writer, &agent_out, &escaped);
        assert_eq!(escaped_reply, plain_reply, "{escaped}");
        assert_eq!((plain_parses, escaped_parses), (2, 2), "{escaped}");
        assert_eq!(plain_reply["id"], id, "{plain_reply}");
        assert_eq!(plain_reply["ok"], false, "{plain_reply}");
    }
    let (reply, parses) =
        send_line(&mux, client, &writer, &out, &format!(r#"{{"id":3,"cmd":"script{dash}open"}}"#));
    assert_eq!((reply["error_code"].clone(), parses), (json!("bad-request"), 2), "{reply}");
}

#[test]
fn a_connection_closes_only_its_own_sessions() {
    let mux = Mux::new_for_test("scripts-close", SurfaceOptions::default());
    let (client, _out, _writer) = connection(&mux, ClientTransport::Unix, false);
    assert!(!mux.control_clients.scripts.close(client, "scr_99"));
    // Cancelling an unknown request and disconnecting are no-ops.
    mux.control_clients.scripts.cancel_request(client, &json!(7));
    mux.control_clients.scripts.disconnect(client);
    assert_eq!(mux.control_clients.scripts.open_sessions(), 0);
}

#[test]
fn the_router_admits_only_ops_this_daemon_owns() {
    let mux = Mux::new_for_test("scripts-router-admit", SurfaceOptions::default());
    let router = DaemonRouter::new(&mux, "scr_t");
    for op in ["net.fetch", "app.storage.get", "action.run", "integration.request", "made.up"] {
        let error = router.call(op, json!({}), json!({})).unwrap_err();
        assert_eq!(error["code"], "operation.unsupported", "{op}");
    }
}

#[test]
fn the_router_runs_daemon_reads_with_current_selectors() {
    let mux = Mux::new_for_test("scripts-router-read", SurfaceOptions::default());
    let router = DaemonRouter::new(&mux, "scr_t");
    let body = router.call("workspace.list", json!({}), json!({})).expect("workspace.list");
    assert!(body["value"].is_array(), "{body}");
}

#[test]
fn the_router_publishes_every_family_stream_on_a_committed_change_until_dropped() {
    let mux = Mux::new_for_test("scripts-router-watch", SurfaceOptions::default());
    let router = DaemonRouter::new(&mux, "scr_t");
    let seen: Arc<Mutex<Vec<String>>> = Arc::default();
    let sink = seen.clone();
    let guard =
        router.watch(Arc::new(move |stream: &str| sink.lock().unwrap().push(stream.to_string())));
    let deadline = Instant::now() + Duration::from_secs(10);
    // The watcher reads the epoch when it starts; bump until it has seen one.
    while seen.lock().unwrap().is_empty() {
        assert!(Instant::now() < deadline, "no stream published");
        mux.publish_journal_event();
        std::thread::sleep(Duration::from_millis(20));
    }
    let first: Vec<String> = seen.lock().unwrap().iter().take(STREAMS.len()).cloned().collect();
    assert_eq!(first, STREAMS);
    drop(guard);
    std::thread::sleep(Duration::from_millis(100));
    let count = seen.lock().unwrap().len();
    mux.publish_journal_event();
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(seen.lock().unwrap().len(), count, "a dropped watch kept publishing");
}

#[test]
fn page_relay_connections_cannot_run_scripts() {
    let mux = Mux::new_for_test("scripts-page", SurfaceOptions::default());
    let (client, out, writer) = connection(&mux, ClientTransport::Unix, false);
    crate::server::origin_gate::set_role_for_test(&mux, client, "page_relay");
    let reply =
        reply_to(&mux, client, &writer, &out, json!({ "id": 8, "cmd": "script-run", "code": "1" }));
    assert_eq!(reply["error_code"], "script.forbidden");
}

#[test]
fn cells_need_a_request_id() {
    let mux = Mux::new_for_test("scripts-id", SurfaceOptions::default());
    let (client, out, writer) = connection(&mux, ClientTransport::Unix, false);
    let reply = reply_to(&mux, client, &writer, &out, json!({ "cmd": "script-run", "code": "1" }));
    assert_eq!(reply["error_code"], "bad-request");
}

#[test]
fn a_start_in_progress_is_abandoned_on_disconnect_and_on_cancel() {
    let mux = Mux::new_for_test("scripts-starting", SurfaceOptions::default());
    let scripts = &mux.control_clients.scripts;
    scripts.begin_start_for_test(1, "\"open-1\"").unwrap();
    scripts.begin_start_for_test(1, "\"open-2\"").unwrap();
    scripts.begin_start_for_test(2, "\"open-1\"").unwrap();
    // The same request id cannot start twice.
    assert_eq!(scripts.begin_start_for_test(1, "\"open-1\"").unwrap_err().code, "script.busy");
    // A cancel during the start marks it: the session ends when the host is up.
    scripts.cancel_request(1, &json!("open-2"));
    assert!(!scripts.start_wanted(1, "\"open-2\""));
    assert!(scripts.start_wanted(1, "\"open-1\""));
    // The connection closes during the start: the start is no longer wanted.
    scripts.disconnect(1);
    assert!(!scripts.start_wanted(1, "\"open-1\""));
    // Another connection's start is untouched.
    assert!(scripts.start_wanted(2, "\"open-1\""));
}
