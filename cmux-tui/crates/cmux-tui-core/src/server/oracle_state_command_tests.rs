//! `oracle-state` on the wire: the trusted local connection gets the facet
//! extras, a WebSocket client and a request with fields are refused, other
//! lines and the `Command` parse are left alone.

use std::sync::Arc;

use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::server::{BoundedOutbound, ClientTransport, Command, QueuedSink};

fn connection(
    mux: &Arc<Mux>,
    transport: ClientTransport,
) -> (u64, Arc<BoundedOutbound>, MessageWriter) {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(transport, writer.clone());
    (client, outbound, writer)
}

fn reply_to(
    mux: &Arc<Mux>,
    (client, out, writer): &(u64, Arc<BoundedOutbound>, MessageWriter),
    request: Value,
) -> Value {
    assert_eq!(try_handle(mux, *client, &request.to_string(), writer), Some(true));
    serde_json::from_str(&out.try_pop().expect("reply")).unwrap()
}

#[test]
fn oracle_state_answers_only_the_trusted_local_connection() {
    let mux = Mux::new_for_test("oracle-state-command", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let local = connection(&mux, ClientTransport::Unix);
    let web = connection(&mux, ClientTransport::WebSocket);

    let reply = reply_to(&mux, &local, json!({"id": 7, "cmd": COMMAND}));
    assert_eq!((reply["ok"].clone(), reply["id"].clone()), (json!(true), json!(7)), "{reply}");
    let data = &reply["data"];
    for key in ["journal_head", "session", "switches", "terminalAttach", "liveObjects", "panicLog"]
    {
        assert!(data.get(key).is_some(), "{key}: {data}");
    }
    assert_eq!(data["terminalAttach"]["attached"], 1, "{data}");
    assert_eq!(data["session"]["workspaces"].as_array().map(Vec::len), Some(1), "{data}");

    let refused = reply_to(&mux, &web, json!({"id": 8, "cmd": COMMAND}));
    assert_eq!(refused["ok"], false, "{refused}");
    assert!(refused["error"].as_str().unwrap().contains("trusted local connection"), "{refused}");

    let extra = reply_to(&mux, &local, json!({"id": 9, "cmd": COMMAND, "include": []}));
    assert_eq!(extra["ok"], false, "{extra}");
    assert!(extra["error"].as_str().unwrap().starts_with("bad request"), "{extra}");
}

#[test]
fn other_lines_pass_and_the_command_enum_has_no_oracle_state() {
    let mux = Mux::new_for_test("oracle-state-other", SurfaceOptions::default());
    let (client, out, writer) = connection(&mux, ClientTransport::Unix);
    for line in [
        json!({"id": 1, "cmd": "ping"}).to_string(),
        json!({"id": 2, "cmd": "notify", "title": COMMAND}).to_string(),
        "not json oracle-state".to_string(),
    ] {
        assert_eq!(try_handle(&mux, client, &line, &writer), None, "{line}");
    }
    assert!(out.try_pop().is_none());
    assert!(serde_json::from_value::<Command>(json!({"cmd": COMMAND})).is_err());
}
