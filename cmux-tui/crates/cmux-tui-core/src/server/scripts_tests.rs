//! `script-*` gates and the script op router (no host binary needed).

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_app_host::script::ScriptRouter;
use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::scripts::router::{DaemonRouter, STREAMS};
use crate::server::{BoundedOutbound, ClientTransport, QueuedSink};

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
    let cmd = request["cmd"].as_str().expect("a cmd");
    let handler = routed(cmd).expect("a script route");
    assert!(handler(mux, client, &request.to_string(), writer));
    serde_json::from_str(&out.try_pop().expect("reply")).unwrap()
}

/// The handler `ROUTES` names for `cmd`, as server/routes.rs finds it.
fn routed(cmd: &str) -> Option<Handler> {
    ROUTES.iter().find(|(name, _)| *name == cmd).map(|(_, handler)| *handler)
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
    // Not a script command: no route here, whatever its other members say.
    assert!(routed("identify").is_none());
    assert!(routed("apps-list").is_none());
}

/// A connection frame reaches the script route by its `cmd`; a line that
/// only mentions a script command is not routed here.
#[test]
fn a_connection_frame_routes_script_commands_by_cmd() {
    let mux = Mux::new_for_test("scripts-frame", SurfaceOptions::default());
    let (client, out, writer) = connection(&mux, ClientTransport::Unix, true);
    let scheduler = Arc::new(crate::server::ConnectionSurfaceScheduler::new(
        mux.surface_operation_admission.clone(),
    ));
    let send = |line: String| {
        assert!(crate::server::handle_connection_message(&mux, client, &line, &writer, &scheduler));
        serde_json::from_str::<Value>(&out.try_pop().expect("reply")).unwrap()
    };
    let reply = send(json!({ "id": 9, "cmd": "script-run", "code": "1" }).to_string());
    assert_eq!(reply["error_code"], "script.forbidden", "{reply}");
    assert_eq!(reply["id"], 9);
    let reply = send(r#"{"id":10,"cmd":"no-such-command","x":"script-run"}"#.to_string());
    assert_ne!(reply["error_code"], "script.forbidden", "{reply}");
    assert_eq!(reply["ok"], false, "{reply}");
}

/// Every routed name is a variant of the module's `Command`, so a routed
/// request never meets an `unknown variant` refusal.
#[test]
fn every_route_names_a_script_command() {
    assert_eq!(ROUTES.len(), 4);
    for (cmd, _) in ROUTES {
        let request = json!({ "cmd": cmd, "code": "1", "session": "scr_1" });
        let parsed = serde_json::from_value::<Request>(request);
        assert!(parsed.is_ok(), "{cmd}: {:?}", parsed.err());
    }
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
