//! The page router's v2 route: the routed namespaces of spec/page-router.json
//! are its op table, and a line that is not exactly one routed request gets
//! the catalog parse's answer.

use std::sync::Arc;

use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::server::{
    BoundedOutbound, ClientTransport, ConnectionSurfaceScheduler, QueuedSink,
    handle_connection_message,
};

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

/// The reply to `line` on a connection frame.
fn send(mux: &Arc<Mux>, conn: &Conn, line: &str) -> Value {
    assert!(handle_connection_message(mux, conn.client, line, &conn.writer, &conn.scheduler));
    serde_json::from_str(&conn.outbound.try_pop().expect("a synchronous reply")).unwrap()
}

fn request(operation: &str) -> Value {
    json!({
        "protocol": PROTOCOL,
        "type": "request",
        "id": "r1",
        "operation": operation,
        "params": {},
    })
}

#[test]
fn the_routed_namespaces_are_the_op_table() {
    for operation in ["apps.catalog.list", "apps.install", "agent_session.trust.get"] {
        assert!(route(operation).is_some(), "{operation}");
    }
    // Catalog operations, unknown members of a routed namespace and
    // unknown namespaces are not routed here.
    for operation in ["workspace.list", "apps.made_up", "made.up", "apps", ""] {
        assert!(route(operation).is_none(), "{operation}");
    }
}

#[test]
fn a_routed_operation_reaches_its_owner() {
    let mux = Mux::new_for_test("page-router-owner", SurfaceOptions::default());
    let conn = connect(&mux);
    let reply = send(&mux, &conn, &request("apps.catalog.list").to_string());
    assert_eq!(reply["id"], "r1", "{reply}");
    // The owner answered (no app host in a test daemon), not the catalog.
    assert_ne!(reply["error"]["code"], "validation.invalid", "{reply}");
}

#[test]
fn a_routed_line_with_an_unknown_member_gets_the_catalog_answer() {
    let mux = Mux::new_for_test("page-router-unknown-member", SurfaceOptions::default());
    let conn = connect(&mux);
    let mut routed = request("apps.catalog.list");
    routed["extra"] = json!(true);
    let mut unrouted = request("made.up");
    unrouted["extra"] = json!(true);
    let routed = send(&mux, &conn, &routed.to_string());
    assert_eq!(routed["ok"], false, "{routed}");
    assert_eq!(routed["error"]["code"], "validation.invalid", "{routed}");
    assert_eq!(routed, send(&mux, &conn, &unrouted.to_string()));
}

#[test]
fn a_routed_line_with_a_numeric_id_names_the_id() {
    let mux = Mux::new_for_test("page-router-numeric-id", SurfaceOptions::default());
    let conn = connect(&mux);
    let mut line = request("apps.catalog.list");
    line["id"] = json!(7);
    let reply = send(&mux, &conn, &line.to_string());
    assert_eq!(reply["id"], 7, "{reply}");
    assert_eq!(reply["error"]["code"], "validation.invalid", "{reply}");
}
