//! Single-parse dispatch (p05-ipc-062): a line's head is read once and the
//! line goes to the one handler the head names, which parses it once more;
//! a feature route answers exactly as its entry does; no route name is a
//! `Command`'s and no page-routed operation is a catalog operation.

use std::sync::Arc;
use std::time::Instant;

use serde_json::{Value, json};

use super::{LineFrame, dispatch_line};
use crate::request_origin::page_router_table;
use crate::resource::ResourceOperation;
use crate::server::command_names::COMMANDS;
use crate::server::routes::{self, RouteName};
use crate::server::tests::{captured_writer, test_mux};
use crate::server::*;

struct Conn {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
}

impl Conn {
    fn new(mux: &Arc<Mux>) -> Self {
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        Self { client, writer, outbound }
    }

    /// Dispatches `message` as the frame handler does after its preamble
    /// and returns how many times it was parsed and the replies it got
    /// (its own scheduler drains a queued `Command`).
    fn dispatch(&self, mux: &Arc<Mux>, message: &str) -> (u8, Vec<Value>) {
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let line = LineFrame {
            mux,
            client: self.client,
            message,
            writer: &self.writer,
            scheduler: &scheduler,
            arrived: Instant::now(),
            watched: None,
        };
        let mut parses = JsonParses::default();
        dispatch_line(&line, &mut parses);
        scheduler.finish_and_wait();
        (parses.get(), self.replies())
    }

    fn replies(&self) -> Vec<Value> {
        std::iter::from_fn(|| self.outbound.try_pop())
            .map(|text| serde_json::from_str(&text).expect("a JSON reply"))
            .collect()
    }
}

/// One line of each feature route that answers without changing state.
const ROUTE_LINES: &[&str] = &[
    r#"{"id":1,"cmd":"agent-inventory","unknown_field":1}"#,
    r#"{"id":2,"cmd":"loopback-status"}"#,
    r#"{"id":3,"cmd":"browser-runtime-status"}"#,
    r#"{"id":4,"cmd":"agent-session-observe","bogus":true}"#,
    r#"{"id":5,"cmd":"agent-transfer-nope"}"#,
    r#"{"id":6,"cmd":"access-request-list"}"#,
    r#"{"id":7,"cmd":"agent-update-plan"}"#,
    r#"{"id":8,"cmd":"agent-cli-update-job"}"#,
    r#"{"id":9,"cmd":"agent-cli-intents-list"}"#,
    r#"{"id":10,"cmd":"agent-inventory-watch"}"#,
    r#"{"id":11,"cmd":"machine-catalog-publish"}"#,
    r#"{"id":12,"cmd":"apps-nope"}"#,
    r#"{"id":13,"cmd":"script-nope"}"#,
    r#"{"id":14,"cmd":"fs.stat","path":"/"}"#,
];

#[test]
fn connection_frame_parses_each_line_at_most_twice() {
    let mux = test_mux();
    let conn = Conn::new(&mux);
    let resource = json!({"protocol":"cmux.protocol/2","type":"request","id":"r-1",
        "operation":"session.ping","params":{"machine":"current","session":"current"}})
    .to_string();
    let page_routed = json!({"protocol":"cmux.protocol/2","type":"request","id":"r-2",
        "operation":"apps.catalog.list","params":{}})
    .to_string();
    let mut lines: Vec<&str> = vec![
        r#"{"id":100,"cmd":"ping"}"#,
        // Route names inside a command's members no longer reach a route.
        r#"{"id":101,"cmd":"ping","note":"\"loopback-open\" agent-inventory \"apps-x\" \"fs.read"}"#,
        r#"{"id":102,"cmd":"no-such-command"}"#,
        "not json",
        &resource,
        &page_routed,
    ];
    lines.extend(ROUTE_LINES);
    for line in lines {
        let (parses, replies) = conn.dispatch(&mux, line);
        assert!(parses <= 2, "{parses} parses of {line}");
        assert_eq!(replies.len(), 1, "one reply to {line}: {replies:?}");
    }
}

#[test]
fn connection_frame_refused_envelope_gets_the_catalog_answer() {
    let mux = test_mux();
    let conn = Conn::new(&mux);
    // A routed operation in an envelope the page router refuses (an unknown
    // member) is answered by the catalog parse, as before.
    let line = json!({"protocol":"cmux.protocol/2","type":"request","id":"r-3",
        "operation":"apps.catalog.list","params":{},"extra":1})
    .to_string();
    let (parses, replies) = conn.dispatch(&mux, &line);
    assert_eq!(parses, 4, "head, page router, envelope and its protocol probe");
    let [reply] = replies.as_slice() else { panic!("{replies:?}") };
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["code"], "validation.invalid", "{reply}");
}

#[test]
fn connection_frame_route_replies_are_their_entry_replies() {
    let mux = test_mux();
    let conn = Conn::new(&mux);
    for line in ROUTE_LINES {
        let head = RequestHead::parse(line);
        let route = head.cmd().and_then(routes::find).unwrap_or_else(|| panic!("{line}"));
        assert_eq!((route.entry)(&mux, conn.client, line, &conn.writer), Some(true), "{line}");
        let direct = conn.replies();
        let (parses, dispatched) = conn.dispatch(&mux, line);
        assert_eq!(parses, 2, "{line}");
        assert_eq!(dispatched, direct, "{line}");
    }
}

#[test]
fn connection_frame_routes_names_are_disjoint() {
    let all: Vec<_> = routes::all().collect();
    let overlap = |a: RouteName, b: RouteName| match (a, b) {
        (RouteName::Exact(a), RouteName::Exact(b)) => a == b,
        (RouteName::Exact(name), RouteName::Prefix(prefix))
        | (RouteName::Prefix(prefix), RouteName::Exact(name)) => name.starts_with(prefix),
        (RouteName::Prefix(a), RouteName::Prefix(b)) => a.starts_with(b) || b.starts_with(a),
    };
    for (index, route) in all.iter().enumerate() {
        for other in &all[index + 1..] {
            for &a in route.names {
                for &b in other.names {
                    assert!(!overlap(a, b), "{a:?} and {b:?} name the same cmd");
                }
            }
        }
    }
    // A route never shadows a `Command`: the head's lookup and the
    // `Command` parse agree on who answers every command name.
    for command in COMMANDS {
        for wire in std::iter::once(command.wire).chain(command.aliases.iter().copied()) {
            assert!(routes::find(wire).is_none(), "route shadows command {wire}");
        }
    }
}

#[test]
fn connection_frame_routes_find_every_sniffed_cmd() {
    let cases: &[(&str, FrameStage)] = &[
        ("loopback-open", FrameStage::LoopbackForward),
        ("browser-runtime-start", FrameStage::BrowserRuntime),
        ("agent-session-start", FrameStage::AgentSession),
        ("agent-session-observe", FrameStage::AgentSession),
        ("agent-transfer-offer", FrameStage::AgentTransfer),
        ("access-request", FrameStage::AgentTransfer),
        ("access-request-list", FrameStage::AgentTransfer),
        ("agent-update-apply", FrameStage::AgentTransfer),
        ("agent-inventory", FrameStage::AgentInventory),
        ("agent-inventory-refresh", FrameStage::AgentInventory),
        ("agent-cli-update-job", FrameStage::AgentCliJob),
        ("agent-cli-update-job-resolve", FrameStage::AgentCliJob),
        ("agent-cli-intents-record", FrameStage::AgentCliIntents),
        ("agent-inventory-watch", FrameStage::AgentInventoryWatch),
        ("machine-catalog-publish", FrameStage::MachineCatalog),
        ("apps-store", FrameStage::Apps),
        ("cancel-request", FrameStage::Apps),
        ("script-run", FrameStage::Scripts),
        ("fs.read", FrameStage::Fs),
    ];
    for (cmd, stage) in cases {
        let route = routes::find(cmd).unwrap_or_else(|| panic!("no route for {cmd}"));
        assert_eq!(route.stage, *stage, "{cmd}");
    }
    #[cfg(any(debug_assertions, feature = "oracle"))]
    assert!(routes::find("oracle-state").is_some());
    for cmd in ["ping", "agent-inventor", "fs.", "fs.chmod", "access-requests", "apps", ""] {
        assert!(routes::find(cmd).is_none(), "{cmd}");
    }
}

#[test]
fn connection_frame_page_routed_operations_are_not_catalog_operations() {
    for operation in ResourceOperation::ALL {
        assert!(
            page_router_table::routed(operation.wire_name()).is_none(),
            "{} is both a catalog and a page-routed operation",
            operation.wire_name()
        );
    }
}
