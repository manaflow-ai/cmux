//! Single-parse dispatch: a line's head is read once and the
//! line goes to the one handler the head names, which parses it once more.
//! Parses are counted where they start (crate::line_parses), so these
//! counts are the real ones. No route name is a `Command`'s and no
//! page-routed operation is a catalog operation. The replies themselves
//! are pinned by dispatch_golden_tests.rs.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;

use serde_json::{Value, json};

use super::{LineFrame, dispatch_line};
use crate::diagnostics::{IpcStats, IpcTransport, JsonParseScope};
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
    /// and returns how many times it was parsed, on the reader and on the
    /// sequence (the `server-stats` `ipc` count follows the line there),
    /// and the replies it got (its own scheduler drains the sequence).
    fn dispatch(&self, mux: &Arc<Mux>, message: &str) -> (u64, Vec<Value>) {
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let stats = IpcStats::default();
        let line = LineFrame {
            mux,
            client: self.client,
            message,
            writer: &self.writer,
            scheduler: &scheduler,
            arrival: RequestArrival::parsed_now(Instant::now()),
            watched: None,
        };
        let parses = JsonParseScope::enter(&stats, IpcTransport::Lines);
        dispatch_line(&line, RequestHead::parse(message));
        drop(parses);
        scheduler.finish_and_wait();
        let counted = stats.snapshot().parses.lines;
        assert_eq!(counted.requests, 1, "{message} counts as one request");
        (counted.json_parses, self.replies())
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
    r#"{"id":4,"cmd":"agent-session-attach","bogus":true}"#,
    r#"{"id":5,"cmd":"agent-transfer-nope","note":"\"access-request\" \"agent-update-plan\""}"#,
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
fn connection_frame_parses_every_accepted_line_twice() {
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
        // Route names inside a command's members never reach a route.
        r#"{"id":101,"cmd":"ping","note":"\"loopback-open\" agent-inventory \"apps-x\" \"fs.read"}"#,
        &resource,
        &page_routed,
    ];
    lines.extend(ROUTE_LINES);
    for line in lines {
        let (parses, replies) = conn.dispatch(&mux, line);
        assert_eq!(parses, 2, "the head and one decode of {line}");
        assert_eq!(replies.len(), 1, "one reply to {line}: {replies:?}");
    }
}

#[test]
fn connection_frame_error_replies_count_their_id_parse() {
    let mux = test_mux();
    let conn = Conn::new(&mux);
    // An error reply takes its `id` from a full decode of the line, never
    // from the head (request_head.rs), so these lines are parsed 3 times:
    // head, `Command` decode, id.
    for line in [
        r#"{"id":102,"cmd":"no-such-command"}"#,
        r#"{"id":103,"cmd":"agent-update-nope"}"#,
        "not json",
    ] {
        let (parses, replies) = conn.dispatch(&mux, line);
        assert_eq!(parses, 3, "{line}");
        let [reply] = replies.as_slice() else { panic!("{line}: {replies:?}") };
        assert_eq!(reply["ok"], false, "{reply}");
    }
}

#[test]
fn connection_frame_refused_envelope_gets_the_catalog_answer() {
    let mux = test_mux();
    let conn = Conn::new(&mux);
    let refused = json!({"protocol":"cmux.protocol/2","type":"request","id":"r-3",
        "operation":"no.such.operation","params":{}})
    .to_string();
    // A routed operation in an envelope the page router refuses (an unknown
    // member) is answered by the catalog parse, as before.
    let page_refused = json!({"protocol":"cmux.protocol/2","type":"request","id":"r-4",
        "operation":"apps.catalog.list","params":{},"extra":1})
    .to_string();
    // head, envelope, its `protocol` probe, the refusal's id and operation;
    // the page router's own parse first when the operation is routed.
    for (line, expected) in [(refused, 4), (page_refused, 5)] {
        let (parses, replies) = conn.dispatch(&mux, &line);
        assert_eq!(parses, expected, "{line}");
        let [reply] = replies.as_slice() else { panic!("{replies:?}") };
        assert_eq!(reply["ok"], false, "{reply}");
        assert_eq!(reply["error"]["code"], "validation.invalid", "{reply}");
    }
}

#[test]
fn connection_frame_escaped_cmd_routes_as_written_plain() {
    let mux = test_mux();
    let conn = Conn::new(&mux);
    // The head decodes `cmd`, so an escaped spelling reaches the same route
    // (the substring sniffers it replaces sent it to the `Command` parse).
    let (_, plain) = conn.dispatch(&mux, r#"{"id":1,"cmd":"fs.stat","path":"/"}"#);
    let (parses, escaped) = conn.dispatch(&mux, r#"{"id":1,"cmd":"fs.stat","path":"/"}"#);
    assert_eq!(escaped, plain);
    assert_eq!(parses, 2);
}

#[test]
fn connection_frame_routes_names_are_disjoint() {
    let all: Vec<_> = routes::all().collect();
    let mut exact = HashMap::new();
    for (index, route) in all.iter().enumerate() {
        for name in route.names.iter().flat_map(RouteName::exact) {
            assert!(exact.insert(*name, index).is_none(), "{name} names two routes");
        }
    }
    let prefixes: Vec<(&str, usize)> = all
        .iter()
        .enumerate()
        .flat_map(|(index, route)| {
            route.names.iter().filter_map(move |name| match name {
                RouteName::Prefix(prefix) => Some((*prefix, index)),
                RouteName::Exact(_) | RouteName::OneOf(_) => None,
            })
        })
        .collect();
    for (at, (a, _)) in prefixes.iter().enumerate() {
        for (b, _) in &prefixes[at + 1..] {
            assert!(!a.starts_with(b) && !b.starts_with(a), "{a} and {b} overlap");
        }
    }
    // An exact name inside another route's family wins over the prefix; the
    // only one is agent-session-observe.
    let shadowing: Vec<&str> = exact
        .iter()
        .filter(|(name, index)| {
            prefixes.iter().any(|(prefix, owner)| name.starts_with(prefix) && owner != *index)
        })
        .map(|(name, _)| *name)
        .collect();
    assert_eq!(shadowing, ["agent-session-observe"]);
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
    let mut cases: Vec<(&str, FrameStage)> = vec![
        ("loopback-open", FrameStage::LoopbackForward),
        ("browser-runtime-start", FrameStage::BrowserRuntime),
        ("agent-session-start", FrameStage::AgentSession),
        ("agent-session-observe", FrameStage::AgentSession),
        ("agent-transfer-offer", FrameStage::AgentTransfer),
        ("access-request", FrameStage::AgentTransfer),
        ("access-request-list", FrameStage::AgentTransfer),
        ("agent-update-plan", FrameStage::AgentTransfer),
        ("agent-update-apply", FrameStage::AgentTransfer),
        ("agent-inventory", FrameStage::AgentInventory),
        ("agent-inventory-refresh", FrameStage::AgentInventory),
        ("agent-cli-update-job", FrameStage::AgentCliJob),
        ("agent-cli-update-job-resolve", FrameStage::AgentCliJob),
        ("agent-inventory-watch", FrameStage::AgentInventoryWatch),
        ("machine-catalog-publish", FrameStage::MachineCatalog),
        ("apps-store", FrameStage::Apps),
        ("cancel-request", FrameStage::Apps),
        ("script-run", FrameStage::Scripts),
    ];
    cases.extend(crate::fs_ops::FS_COMMANDS.iter().map(|cmd| (*cmd, FrameStage::Fs)));
    cases.extend(agent_cli_intents::COMMANDS.iter().map(|cmd| (*cmd, FrameStage::AgentCliIntents)));
    for (cmd, stage) in cases {
        let route = routes::find(cmd).unwrap_or_else(|| panic!("no route for {cmd}"));
        assert_eq!(route.stage, stage, "{cmd}");
    }
    for cmd in [
        "ping",
        "agent-inventor",
        "fs.",
        "fs.chmod",
        "access-requests",
        "apps",
        "agent-update-nope",
        "agent-cli-intents-nope",
        "",
    ] {
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
