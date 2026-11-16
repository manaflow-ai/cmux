//! The daemon's public dock record and the transport of a client against the
//! strict types of the Rust SDK and the request catalog.
//!
//! The first item of a session event stream is the snapshot of the whole
//! session: the layout of each screen and each connected client are in it.
//! The Rust SDK decodes the dock of a column with a type that refuses a
//! member it does not know, and the transport of a client with an enum that
//! refuses a value it does not know. One such member or value, anywhere in
//! the session, ends the stream of each SDK client with a decode error; the
//! bundled screen detector then ends each of its passes
//! (`crates/cmux-tui/tests/detector_wake_streams.rs`).
//!
//! These tests name each member of the daemon's dock record and each
//! transport of a client. A new member or a new value does not compile here
//! until the test names it; then the catalog and the SDK's type must know
//! it, or the test fails.

#![cfg(unix)]

use super::*;
use crate::{ColumnDock, DockEdge, DockMode, DockRole};

const CATALOG: &str = include_str!("../../../../../spec/resource-operations-v2.json");

/// Each mode of a dock. `dock_mode_name` does not compile with a new mode:
/// name it there and in this list.
const DOCK_MODES: [DockMode; 2] = [DockMode::Docked, DockMode::Overlay];

fn dock_mode_name(mode: DockMode) -> &'static str {
    match mode {
        DockMode::Docked => "docked",
        DockMode::Overlay => "overlay",
    }
}

/// Each role of a dock. `dock_role_name` does not compile with a new role:
/// name it there and in this list.
const DOCK_ROLES: [DockRole; 1] = [DockRole::AgentChat];

fn dock_role_name(role: DockRole) -> &'static str {
    match role {
        DockRole::AgentChat => "agent_chat",
    }
}

/// Each transport of a client. `transport_name` does not compile with a new
/// transport: name it there and in this list.
const TRANSPORTS: [ClientTransport; 3] =
    [ClientTransport::Unix, ClientTransport::WebSocket, ClientTransport::Remote];

/// The name of a transport in a public client record.
fn transport_name(transport: ClientTransport) -> &'static str {
    match transport {
        ClientTransport::Unix => "unix",
        ClientTransport::WebSocket => "websocket",
        ClientTransport::Remote => "remote",
    }
}

fn catalog() -> Value {
    serde_json::from_str(CATALOG).expect("the request catalog is JSON")
}

/// The values of the catalog enum at `pointer`.
fn catalog_values(catalog: &Value, pointer: &str) -> Vec<String> {
    catalog
        .pointer(pointer)
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("the catalog has no enum values at {pointer}"))
        .iter()
        .filter_map(|value| value.as_str().map(str::to_owned))
        .collect()
}

/// The SDK's dock type decodes `record` and writes the same record again:
/// it holds each member, it does not only read past it.
fn sdk_keeps_the_dock(record: &Value) {
    let decoded =
        serde_json::from_value::<cmux::LayoutColumnDock>(record.clone()).unwrap_or_else(|error| {
            panic!("the SDK's LayoutColumnDock refuses the daemon's dock record {record}: {error}")
        });
    let written = serde_json::to_value(decoded).expect("the SDK's dock is JSON");
    assert_eq!(
        &written, record,
        "the SDK's LayoutColumnDock does not keep each member of the daemon's dock record"
    );
}

#[test]
fn detector_wake_streams_guard_each_dock_member_is_in_the_sdk_and_the_catalog() {
    let catalog = catalog();
    let members = catalog
        .pointer("/types/LayoutColumnDock/fields")
        .and_then(Value::as_object)
        .expect("the catalog has the members of LayoutColumnDock");
    let edges = catalog_values(&catalog, "/types/LayoutColumnDock/fields/edge/type/values");
    let modes = catalog_values(&catalog, "/types/LayoutColumnDock/fields/mode/type/values");
    let roles = catalog_values(&catalog, "/types/LayoutColumnDock/fields/role/type/values");
    for edge in DockEdge::ALL {
        for mode in DOCK_MODES {
            for role in DOCK_ROLES {
                // Each member has its name here and a value that the record
                // does not omit: a new member of the daemon's type does not
                // compile until this literal names it.
                let dock = ColumnDock {
                    edge,
                    mode,
                    role: Some(role),
                    permanent: true,
                    pinned: true,
                    allow_tabs: true,
                };
                let record = serde_json::to_value(dock).expect("the daemon's dock is JSON");
                let object = record.as_object().expect("the daemon's dock record is an object");
                for member in object.keys() {
                    assert!(
                        members.contains_key(member),
                        "the catalog's LayoutColumnDock has no member `{member}` of the \
                         daemon's dock record {record}"
                    );
                }
                assert_eq!(record["mode"], dock_mode_name(mode));
                assert_eq!(record["role"], dock_role_name(role));
                assert!(
                    edges.iter().any(|value| record["edge"] == value.as_str()),
                    "the catalog's dock edges {edges:?} do not hold {}",
                    record["edge"]
                );
                assert!(
                    modes.iter().any(|value| record["mode"] == value.as_str()),
                    "the catalog's dock modes {modes:?} do not hold {}",
                    record["mode"]
                );
                assert!(
                    roles.iter().any(|value| record["role"] == value.as_str()),
                    "the catalog's dock roles {roles:?} do not hold {}",
                    record["role"]
                );
                sdk_keeps_the_dock(&record);
            }
            // The plain dock: the record omits each optional member.
            let plain = serde_json::to_value(ColumnDock::new(edge, mode))
                .expect("the daemon's plain dock is JSON");
            sdk_keeps_the_dock(&plain);
        }
    }
}

#[test]
fn detector_wake_streams_guard_each_client_transport_is_in_the_sdk_and_the_catalog() {
    let catalog = catalog();
    let values = catalog_values(&catalog, "/types/ClientTransport/values");
    let mux = test_mux();
    // One client of each transport, each with its own writer. The first one
    // sends the request.
    let mut reader = None;
    for transport in TRANSPORTS {
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(transport, writer.clone());
        if reader.is_none() {
            reader = Some((client, writer, outbound));
        }
    }
    let (reader, writer, outbound) = reader.expect("the daemon has a transport");
    let mut wanted = TRANSPORTS.map(transport_name).to_vec();
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let list = resource_request(
        "guard-client-list",
        "client.list",
        json!({"machine":"current","session":"current"}),
        None,
    );
    assert!(handle_connection_message(&mux, reader, &list, &writer, &scheduler));
    let listed = pop_json(&outbound);
    let records =
        listed["result"].as_array().unwrap_or_else(|| panic!("client.list failed: {listed}"));
    let mut seen =
        records.iter().filter_map(|record| record["transport"].as_str()).collect::<Vec<_>>();
    seen.sort();
    wanted.sort();
    assert_eq!(seen, wanted, "client.list does not hold one client of each transport: {listed}");
    for record in records {
        let transport = record["transport"].as_str().unwrap_or_default();
        assert!(
            values.iter().any(|value| value == transport),
            "the catalog's ClientTransport {values:?} does not hold the transport `{transport}` \
             of the daemon's client record {record}"
        );
        if let Err(error) = serde_json::from_value::<cmux::ClientSnapshot>(record.clone()) {
            panic!("the SDK's ClientSnapshot refuses the daemon's client record {record}: {error}");
        }
    }
}
