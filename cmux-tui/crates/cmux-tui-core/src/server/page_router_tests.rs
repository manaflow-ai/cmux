//! The page router is reached through its v2 operation route
//! (server/routes.rs): the line's `operation` names the route
//! in spec/page-router.json, and each page's allow list still decides what
//! the page may call.

use std::sync::Arc;

use serde_json::{Value, json};

use super::OPERATION_ROUTES;
use crate::server::routes;
use crate::server::tests::{captured_writer, test_mux};
use crate::server::*;

const PAGE_ROUTER_JSON: &str = include_str!("../../../../spec/page-router.json");

/// Every operation a routed namespace of the spec names.
fn routed_operations() -> Vec<String> {
    let table: Value = serde_json::from_str(PAGE_ROUTER_JSON).expect("the page router table");
    let namespaces = table["namespaces"].as_object().expect("namespaces");
    namespaces
        .values()
        .flat_map(|namespace| ["read", "mutation"].map(|kind| namespace[kind].clone()))
        .flat_map(|names| names.as_array().cloned().unwrap_or_default())
        .map(|name| name.as_str().expect("an operation name").to_owned())
        .collect()
}

#[test]
fn page_router_operation_route_names_every_routed_operation() {
    let operations = routed_operations();
    assert!(operations.iter().any(|operation| operation == "apps.catalog.list"), "{operations:?}");
    for operation in &operations {
        let route = routes::find_operation(operation)
            .unwrap_or_else(|| panic!("{operation} has no operation route"));
        assert_eq!(route.stage, FrameStage::PageRouter, "{operation}");
        assert!((OPERATION_ROUTES[0].names)(operation), "{operation}");
    }
    // A catalog operation, an unlisted name of a routed namespace and a
    // namespace alone are no page-routed operations.
    for operation in ["session.ping", "apps.nope", "apps", "agent_session.trust"] {
        assert!(routes::find_operation(operation).is_none(), "{operation}");
    }
}

/// A local connection with its writer and the replies it gets.
struct Conn {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
}

/// A local connection that serves `page` as a page relay (`None`: a page
/// relay that named no page).
fn page_relay(mux: &Arc<Mux>, page: Option<&str>) -> Conn {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    origin_gate::set_role_for_test(mux, client, "page_relay");
    let mut state = mux.control_clients.state.lock().unwrap();
    state.clients.get_mut(&client).expect("registered").origin.page = page.map(str::to_owned);
    drop(state);
    Conn { client, writer, outbound }
}

/// Sends `line` through the frame dispatch and returns its one reply and
/// the JSON parses it took.
fn send(mux: &Arc<Mux>, conn: &Conn, line: &Value) -> (Value, u64) {
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
            conn.client,
            ClientTransport::Unix,
            &line.to_string(),
            &conn.writer,
            &scheduler,
        ));
    }
    let reply = serde_json::from_str(&conn.outbound.try_pop().expect("a reply")).unwrap();
    assert!(conn.outbound.try_pop().is_none(), "one reply to {line}");
    (reply, stats.snapshot().parses.lines.json_parses)
}

fn request(id: &str, operation: &str, params: Value) -> Value {
    json!({"protocol": "cmux.protocol/2", "type": "request", "id": id,
           "operation": operation, "params": params})
}

fn assert_forbidden(reply: &Value) {
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["code"], "origin.forbidden", "{reply}");
}

/// The page allow list is checked on the routed path: a page relay with no
/// page, or a page whose list does not name the operation, is refused; a
/// mutation its page may call only after confirmation is refused without
/// one; a read its page lists passes the gate. Every line takes the head
/// and the route's one envelope decode.
#[test]
fn page_router_keeps_the_page_allow_list_on_its_operation_route() {
    let mux = test_mux();

    let pageless = page_relay(&mux, None);
    let (reply, parses) = send(&mux, &pageless, &request("r-1", "apps.catalog.list", json!({})));
    assert_forbidden(&reply);
    assert_eq!(reply["id"], "r-1", "{reply}");
    assert_eq!(parses, 2, "{reply}");

    let history = page_relay(&mux, Some("history"));
    let (reply, parses) = send(&mux, &history, &request("r-2", "apps.catalog.list", json!({})));
    assert_forbidden(&reply);
    assert_eq!(reply["error"]["details"]["reason"], "page_not_allowed", "{reply}");
    assert_eq!(parses, 2, "{reply}");

    let apps = page_relay(&mux, Some("apps"));
    let mut install = request("r-3", "apps.set", json!({"app": "cmux/demo", "installed": true}));
    install["idempotency_key"] = json!("k-1");
    let (reply, parses) = send(&mux, &apps, &install);
    assert_forbidden(&reply);
    assert_eq!(reply["error"]["details"]["reason"], "confirmation_required", "{reply}");
    assert_eq!(parses, 2, "{reply}");

    let (reply, parses) = send(&mux, &apps, &request("r-4", "apps.catalog.list", json!({})));
    assert_ne!(reply["error"]["code"], "origin.forbidden", "{reply}");
    assert_eq!(reply["id"], "r-4", "{reply}");
    assert_eq!(parses, 2, "{reply}");
}
