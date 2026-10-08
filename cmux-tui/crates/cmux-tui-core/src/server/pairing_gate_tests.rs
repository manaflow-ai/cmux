//! Who may approve a WebSocket pairing (cx-ehrq): only a human surface.
//! The in-process TUI answers through `Mux::respond_pairing`; over a socket
//! only the verified cmux app (the `frontend` actor) may approve. Any other
//! local connection (an agent in a pane, a script, the `cmux` CLI) may deny
//! but never approve, on the legacy and the v2 protocol.

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::server::origin_gate::{
    set_peer_key_for_test, set_role_for_test, set_verified_app_for_test,
};
use crate::server::*;

struct Conn {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

fn connect(mux: &Arc<Mux>) -> Conn {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    Conn { client, writer, outbound, scheduler }
}

fn verified_app(mux: &Arc<Mux>) -> Conn {
    let conn = connect(mux);
    set_role_for_test(mux, conn.client, "main");
    set_peer_key_for_test(mux, conn.client, "token:100.1");
    set_verified_app_for_test(mux, conn.client, true);
    conn
}

fn send(mux: &Arc<Mux>, conn: &Conn, message: &Value) -> Value {
    assert!(handle_connection_message(
        mux,
        conn.client,
        &message.to_string(),
        &conn.writer,
        &conn.scheduler
    ));
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if let Some(reply) = conn.outbound.try_pop() {
            return serde_json::from_str(&reply).unwrap();
        }
        assert!(Instant::now() < deadline, "no reply");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn legacy(request: u64, approve: bool) -> Value {
    json!({"id": 1, "cmd": "pairing-response", "request": request, "approve": approve})
}

fn resolve(request: u64, decision: &str, key: &str) -> Value {
    json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": key,
        "operation": "pairing_request.resolve",
        "idempotency_key": key,
        "params": {
            "machine": "current",
            "session": "current",
            "pairing_request": format!("pairing_{request:032x}"),
            "decision": decision,
        },
    })
}

fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(format!("pairing-gate-{label}"), crate::SurfaceOptions::default())
}

#[test]
fn a_local_agent_connection_cannot_approve_a_pairing() {
    let mux = mux("agent");
    let (challenge, decision) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
    let agent = connect(&mux);

    let reply = send(&mux, &agent, &legacy(challenge.id, true));
    assert_eq!(reply["ok"], false, "legacy approve: {reply}");
    let reply = send(&mux, &agent, &resolve(challenge.id, "accept", "pairing-gate-accept"));
    assert_eq!(reply["ok"], false, "resource accept: {reply}");
    assert_eq!(mux.pending_pairings().len(), 1, "the request must stay pending");
    assert!(decision.try_recv().is_err(), "an agent connection approved a pairing");

    // Denying is harmless and stays open to local connections.
    let reply = send(&mux, &agent, &legacy(challenge.id, false));
    assert_eq!(reply["ok"], true, "legacy deny: {reply}");
    assert_eq!(decision.recv_timeout(Duration::from_secs(1)).unwrap(), crate::PairingDecision::Denied);
    let (second, second_decision) = mux.begin_pairing("127.0.0.2".parse().unwrap()).unwrap();
    let reply = send(&mux, &agent, &resolve(second.id, "reject", "pairing-gate-reject"));
    assert_eq!(reply["ok"], true, "resource reject: {reply}");
    assert_eq!(
        second_decision.recv_timeout(Duration::from_secs(1)).unwrap(),
        crate::PairingDecision::Denied
    );
}

#[test]
fn the_verified_app_approves_a_pairing_on_both_protocols() {
    let mux = mux("frontend");
    let app = verified_app(&mux);
    let (challenge, decision) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
    let reply = send(&mux, &app, &legacy(challenge.id, true));
    assert_eq!(reply["ok"], true, "legacy approve: {reply}");
    assert!(matches!(
        decision.recv_timeout(Duration::from_secs(1)),
        Ok(crate::PairingDecision::Approved { .. })
    ));

    let (second, second_decision) = mux.begin_pairing("127.0.0.2".parse().unwrap()).unwrap();
    let reply = send(&mux, &app, &resolve(second.id, "accept", "pairing-gate-frontend"));
    assert_eq!(reply["ok"], true, "resource accept: {reply}");
    assert!(matches!(
        second_decision.recv_timeout(Duration::from_secs(1)),
        Ok(crate::PairingDecision::Approved { .. })
    ));
}

#[test]
fn the_in_process_tui_approves_a_pairing() {
    let mux = mux("in-process");
    let (challenge, decision) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
    assert!(mux.respond_pairing(challenge.id, true));
    assert!(matches!(
        decision.recv_timeout(Duration::from_secs(1)),
        Ok(crate::PairingDecision::Approved { .. })
    ));
}
