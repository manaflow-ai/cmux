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
        json!({"id": 3, "cmd": "notify", "title": RESTORE_PREVIEW}).to_string(),
        "not json oracle-state".to_string(),
    ] {
        assert_eq!(try_handle(&mux, client, &line, &writer), None, "{line}");
    }
    assert!(out.try_pop().is_none());
    assert!(serde_json::from_value::<Command>(json!({"cmd": COMMAND})).is_err());
    assert!(serde_json::from_value::<Command>(json!({"cmd": RESTORE_PREVIEW})).is_err());
}

#[test]
fn oracle_restore_preview_answers_only_the_trusted_local_connection() {
    let root = std::env::temp_dir().join(format!(
        "cmux-oracle-restore-command-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux =
        Mux::open_persistent("oracle-restore-command", SurfaceOptions::default(), &root).unwrap();
    mux.create_journal_checkpoint("oracle_test", "checkpoint_1").unwrap();
    let local = connection(&mux, ClientTransport::Unix);
    let web = connection(&mux, ClientTransport::WebSocket);

    let reply = reply_to(&mux, &local, json!({"id": 1, "cmd": RESTORE_PREVIEW}));
    assert_eq!(reply["ok"], true, "{reply}");
    let data = &reply["data"];
    assert_eq!(data["sections"]["workspaces"], json!({"restore": "compared"}), "{data}");
    assert_eq!(data["sections"]["clients"]["restore"], "excluded", "{data}");
    assert!(data["sections"]["clients"]["reason"].as_str().is_some_and(|r| !r.is_empty()));
    assert_eq!(data["preview"]["unsupportedCount"], 0, "{data}");
    assert!(data["preview"]["session"].get("clients").is_none(), "{data}");

    let named = json!({"id": 2, "cmd": RESTORE_PREVIEW, "checkpoint": "checkpoint_missing"});
    assert_eq!(reply_to(&mux, &local, named)["data"]["preview"], Value::Null);

    // `through` is an earlier cut (an oracle-state reply's journal head):
    // later records and later checkpoints do not move its preview.
    let (_, cut) = crate::resource_api::public_session_snapshot_with_journal_head(&mux).unwrap();
    mux.create_journal_checkpoint("oracle_test", "checkpoint_2").unwrap();
    let later = mux.create_journal_checkpoint("oracle_test", "checkpoint_3").unwrap();
    let later = later.checkpoint;
    let (_, head) = crate::resource_api::public_session_snapshot_with_journal_head(&mux).unwrap();
    assert!(later.source_sequence > cut && head > later.source_sequence);
    let at_cut = reply_to(&mux, &local, json!({"id": 7, "cmd": RESTORE_PREVIEW, "through": cut}));
    let preview = &at_cut["data"]["preview"];
    assert_eq!(preview["headSequence"], cut, "{at_cut}");
    assert!(preview["checkpointSequence"].as_u64().is_some_and(|at| at <= cut), "{at_cut}");
    let at_head = reply_to(&mux, &local, json!({"id": 8, "cmd": RESTORE_PREVIEW, "through": head}));
    assert_eq!(at_head["data"]["preview"]["headSequence"], head, "{at_head}");
    assert_eq!(at_head["data"]["preview"]["checkpointId"], later.checkpoint_id, "{at_head}");
    let named = json!({"id": 9, "cmd": RESTORE_PREVIEW, "checkpoint": later.checkpoint_id,
                       "through": cut});
    let refused = reply_to(&mux, &local, named);
    assert!(refused["error"].as_str().unwrap().contains("is after journal sequence"), "{refused}");
    let ahead = json!({"id": 10, "cmd": RESTORE_PREVIEW, "through": head + 1});
    let refused = reply_to(&mux, &local, ahead);
    assert!(refused["error"].as_str().unwrap().contains("is ahead of"), "{refused}");

    for (request, error) in [
        (json!({"id": 3, "cmd": RESTORE_PREVIEW, "checkpoint": 7}), "bad request"),
        (json!({"id": 4, "cmd": RESTORE_PREVIEW, "include": []}), "bad request"),
        (json!({"id": 11, "cmd": RESTORE_PREVIEW, "through": "7"}), "bad request"),
        (json!({"id": 12, "cmd": RESTORE_PREVIEW, "through": -1}), "bad request"),
    ] {
        let refused = reply_to(&mux, &local, request);
        assert!(refused["error"].as_str().unwrap().starts_with(error), "{refused}");
    }
    let refused = reply_to(&mux, &web, json!({"id": 5, "cmd": RESTORE_PREVIEW}));
    assert!(refused["error"].as_str().unwrap().contains("trusted local connection"), "{refused}");

    let memory = Mux::new_for_test("oracle-restore-memory", SurfaceOptions::default());
    let memory_local = connection(&memory, ClientTransport::Unix);
    let refused = reply_to(&memory, &memory_local, json!({"id": 6, "cmd": RESTORE_PREVIEW}));
    assert!(refused["error"].as_str().unwrap().contains("persistent session"), "{refused}");
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}

/// The next outbound message whose `id` is `id`.
fn reply_with_id(out: &BoundedOutbound, id: &str) -> Value {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        if let Some(text) = out.try_pop() {
            let message: Value = serde_json::from_str(&text).unwrap();
            if message["id"] == id {
                return message;
            }
            continue;
        }
        assert!(std::time::Instant::now() < deadline, "no reply {id}");
        std::thread::yield_now();
    }
}

#[test]
fn oracle_state_session_is_the_wire_session_snapshot_with_its_clients() {
    let mux = Mux::new_for_test("oracle-state-wire-snapshot", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let (client, out, writer) = connection(&mux, ClientTransport::Unix);
    let scheduler = Arc::new(super::super::ConnectionSurfaceScheduler::new(
        mux.surface_operation_admission.clone(),
    ));
    let send = |id: &str, message: Value| {
        let message = message.to_string();
        let open =
            super::super::handle_connection_message(&mux, client, &message, &writer, &scheduler);
        assert!(open, "{message}");
        reply_with_id(&out, id)
    };
    let snapshot = send(
        "snapshot",
        json!({"protocol":"cmux.protocol/2","type":"request","id":"snapshot",
               "operation":"session.snapshot",
               "params":{"machine":"current","session":"current"}}),
    );
    let oracle = send("oracle", json!({"id":"oracle","cmd":COMMAND}));
    // `connected_seconds` ticks between the two reads.
    let strip = |mut session: Value| {
        for client in session["clients"].as_array_mut().into_iter().flatten() {
            client.as_object_mut().unwrap().remove("connected_seconds");
        }
        session
    };
    let wire = strip(snapshot["result"].clone());
    assert_eq!(wire["clients"].as_array().map(Vec::len), Some(1), "{snapshot:#}");
    assert_eq!(strip(oracle["data"]["session"].clone()), wire, "{oracle:#}");
}

#[test]
fn oracle_state_reports_the_muxs_switch_arms() {
    let mux = Mux::new_for_test("oracle-state-command-switches", SurfaceOptions::default());
    let arms = std::collections::BTreeMap::from([("terminal-holder", "new")]);
    mux.install_oracle_switches_for_test(arms);
    let local = connection(&mux, ClientTransport::Unix);
    let reply = reply_to(&mux, &local, json!({"id": 1, "cmd": COMMAND}));
    assert_eq!(reply["data"]["switches"], json!({"terminal-holder": "new"}), "{reply}");
}
