//! The cause a connection's requests give their events (crate::event_cause),
//! driven through the connection frame handler as a reader drives it: a CLI
//! (agent) split is automation and the verified app's split is frontend,
//! both committed by the terminal work pool off the frame's thread; a v2
//! `origin` claim only lowers the cause; a script's op, run on the script
//! host's own thread, is automation; and only an `event-cause-v1`
//! subscriber sees `cause` on its event lines.

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::handle_connection_frame;
use crate::event_bus::MuxEventReceiver;
use crate::event_cause::{EventCause, EventCauseScope};
use crate::server::origin_gate::{set_role_for_test, set_verified_app_for_test};
use crate::server::tests::captured_writer;
use crate::server::*;

struct Conn {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

impl Conn {
    fn new(mux: &Arc<Mux>) -> Self {
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        Self { client, writer, outbound, scheduler }
    }

    /// The verified cmux app connection (origin `user`).
    fn app(mux: &Arc<Mux>) -> Self {
        let conn = Self::new(mux);
        set_role_for_test(mux, conn.client, "main");
        set_verified_app_for_test(mux, conn.client, true);
        conn
    }

    fn frame(&self, mux: &Arc<Mux>, line: &Value) {
        assert!(handle_connection_frame(
            mux,
            self.client,
            ClientTransport::Unix,
            &line.to_string(),
            &self.writer,
            &self.scheduler,
        ));
    }

    /// The next line this connection received, waiting for one written by
    /// another thread (a pool commit or the events-out thread).
    fn next_line(&self) -> Value {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Some(line) = self.outbound.try_pop() {
                return serde_json::from_str(&line).unwrap();
            }
            assert!(Instant::now() < deadline, "no line");
            std::thread::sleep(Duration::from_millis(2));
        }
    }
}

fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(format!("event-cause-{label}"), crate::SurfaceOptions::default())
}

fn drain(events: &MuxEventReceiver) -> Vec<(MuxEvent, EventCause)> {
    std::iter::from_fn(|| events.try_recv_caused().ok()).collect()
}

/// The causes of the structural events a create commits.
fn structural_causes(events: &MuxEventReceiver) -> Vec<EventCause> {
    drain(events)
        .into_iter()
        .filter(|(event, _)| {
            matches!(
                event,
                MuxEvent::TreeDelta(delta)
                    if matches!(
                        delta.kind,
                        TreeDeltaKind::WorkspaceAdded
                            | TreeDeltaKind::PaneAdded
                            | TreeDeltaKind::TabAdded
                    )
            ) || matches!(event, MuxEvent::LayoutChanged(..))
        })
        .map(|(_, cause)| cause)
        .collect()
}

/// Splits the only pane through `conn` and returns the causes of the
/// structural events it committed. A split creates a terminal, so the
/// dispatcher hands it to the terminal work pool and its commit runs there.
fn split_causes(mux: &Arc<Mux>, conn: &Conn) -> Vec<EventCause> {
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(surface.id)).unwrap();
    let events = mux.subscribe();
    conn.frame(mux, &json!({"id": 1, "cmd": "split", "pane": pane, "dir": "right"}));
    conn.scheduler.finish_and_wait();
    let reply = conn.next_line();
    assert_eq!(reply["ok"], true, "{reply}");
    structural_causes(&events)
}

#[test]
fn event_cause_of_a_cli_split_is_automation() {
    let mux = mux("cli-split");
    let causes = split_causes(&mux, &Conn::new(&mux));
    assert!(!causes.is_empty(), "the split committed no structural event");
    assert!(causes.iter().all(|cause| *cause == EventCause::Automation), "{causes:?}");
    mux.shutdown();
}

#[test]
fn event_cause_of_an_app_split_is_frontend() {
    let mux = mux("app-split");
    let causes = split_causes(&mux, &Conn::app(&mux));
    assert!(!causes.is_empty(), "the split committed no structural event");
    assert!(causes.iter().all(|cause| *cause == EventCause::Frontend), "{causes:?}");
    mux.shutdown();
}

fn workspace_create(name: &str, claim: Option<&str>) -> Value {
    let mut request = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": name,
        "operation": "workspace.create",
        "params": {"machine": "current", "session": "current", "name": name,
                   "initial_content": "empty"},
        "idempotency_key": name,
    });
    if let Some(claim) = claim {
        request["origin"] = json!({"claim": claim});
    }
    request
}

/// The verified app's own v2 request is frontend; with an `agent` claim it
/// is automation, as the claim narrows its origin.
#[test]
fn event_cause_of_a_v2_request_is_narrowed_by_its_claim() {
    let mux = mux("claim");
    let app = Conn::app(&mux);
    for (name, claim, expected) in [
        ("as-user", None, EventCause::Frontend),
        ("as-agent", Some("agent"), EventCause::Automation),
    ] {
        let events = mux.subscribe();
        app.frame(&mux, &workspace_create(name, claim));
        let reply = app.next_line();
        assert_eq!(reply["ok"], true, "{reply}");
        let causes = structural_causes(&events);
        assert!(!causes.is_empty(), "{name}: no structural event");
        assert!(causes.iter().all(|cause| *cause == expected), "{name}: {causes:?}");
    }
    mux.shutdown();
}

/// With request classes on (crate::request_qos), the reader runs the
/// verified app's line at USER_INITIATED and the same line with an `agent`
/// claim at UTILITY, the class of the narrowed cause the dispatcher would
/// also use.
#[test]
fn request_qos_of_a_claimed_line_follows_the_narrowed_cause() {
    use cmux_threads::ThreadQos::{UserInitiated, Utility};
    let mux = mux("claim-qos");
    mux.set_request_qos_for_test(true);
    let app = Conn::app(&mux);
    let _ = crate::request_qos::tests::take_entered();
    app.frame(&mux, &workspace_create("qos-as-user", None));
    assert_eq!(app.next_line()["ok"], true);
    let entered = crate::request_qos::tests::take_entered();
    assert_eq!(entered.first(), Some(&UserInitiated), "{entered:?}");
    assert!(!entered.contains(&Utility), "the app's own line: {entered:?}");

    app.frame(&mux, &workspace_create("qos-as-agent", Some("agent")));
    assert_eq!(app.next_line()["ok"], true);
    let entered = crate::request_qos::tests::take_entered();
    assert_eq!(entered.get(..2), Some(&[UserInitiated, Utility][..]), "claimed: {entered:?}");
    mux.shutdown();
}

/// A script's op runs on a thread of the script host (`DaemonRouter::call`),
/// outside every connection frame: what it sets off is automation, also on
/// a thread whose own cause is frontend.
#[test]
fn event_cause_of_a_script_op_is_automation() {
    use cmux_app_host::script::ScriptRouter;
    let mux = mux("script-router");
    let router = crate::scripts::router::DaemonRouter::new(&mux, "scr_cause");
    for (name, outer) in [("unscoped", None), ("in-frontend", Some(EventCause::Frontend))] {
        let events = mux.subscribe();
        {
            let _outer = outer.map(EventCauseScope::enter);
            router
                .call(
                    "workspace.create",
                    json!({"name": name, "initial_content": "empty"}),
                    json!({}),
                )
                .unwrap_or_else(|e| panic!("{name}: {e}"));
        }
        let causes = structural_causes(&events);
        assert!(!causes.is_empty(), "{name}: no structural event");
        assert!(causes.iter().all(|cause| *cause == EventCause::Automation), "{name}: {causes:?}");
    }
    mux.shutdown();
}

/// The next `bell` event line `conn` received.
fn next_bell(conn: &Conn) -> Value {
    loop {
        let line = conn.next_line();
        if line["event"] == "bell" {
            return line;
        }
    }
}

/// `cause` is on the wire only for an `event-cause-v1` subscriber, and a
/// program cause is left out.
#[test]
fn event_cause_reaches_the_wire_only_when_echoed() {
    let mux = mux("wire");
    let caused = Conn::new(&mux);
    let plain = Conn::new(&mux);
    let subscribe = |conn: &Conn, capabilities: Value| {
        for command in [
            json!({"cmd": "set-client-info", "capabilities": capabilities}),
            json!({"cmd": "subscribe"}),
        ] {
            let command: Command = serde_json::from_value(command).unwrap();
            handle_command(&mux, conn.client, command, &conn.writer).unwrap();
        }
    };
    subscribe(&caused, json!([crate::event_cause::CAPABILITY]));
    subscribe(&plain, json!([]));
    for cause in [EventCause::Frontend, EventCause::Automation, EventCause::Program] {
        let _scope = EventCauseScope::enter(cause);
        mux.emit(MuxEvent::Bell(9));
    }
    let wire = |conn: &Conn| (0..3).map(|_| next_bell(conn)["cause"].clone()).collect::<Vec<_>>();
    assert_eq!(wire(&caused), vec![json!("frontend"), json!("automation"), Value::Null]);
    assert_eq!(wire(&plain), vec![Value::Null, Value::Null, Value::Null]);
    assert!(advertised_capabilities(false).contains(&crate::event_cause::CAPABILITY));
    mux.shutdown();
}
