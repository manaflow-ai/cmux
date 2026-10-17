//! Machine inventory stays on the trusted native owner connection. A fake
//! acpmux records every call, including the handshake before any health view.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, channel};
use std::thread::JoinHandle;

use serde_json::{Value, json};

use super::agent_session_attach_tests::{Client, assert_code, run};
use super::*;

struct Owner {
    socket: PathBuf,
    frames: Receiver<Value>,
    worker: Option<JoinHandle<()>>,
}

impl Owner {
    fn new(features: Value, inventory: Value) -> Self {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let socket = PathBuf::from(format!(
            "/tmp/cmux-ai-{}-{}.sock",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let listener = UnixListener::bind(&socket).unwrap();
        let (sent, frames) = channel();
        let worker = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            // The real link closes after its bounded calls; the cleanup
            // connection closes immediately to wake accept. No timeout is
            // set on that already-closed wake socket (EINVAL on macOS).
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            while reader.read_line(&mut line).is_ok_and(|n| n > 0) {
                let frame: Value = serde_json::from_str(&line).unwrap();
                line.clear();
                sent.send(frame.clone()).unwrap();
                let result = match frame["method"].as_str().unwrap() {
                    "initialize" => json!({"_meta":{"acpmux":{"features":features}}}),
                    "_acpmux/harness/health" => inventory.clone(),
                    other => panic!("inventory must not call {other}"),
                };
                writeln!(stream, "{}", json!({"jsonrpc":"2.0","id":frame["id"],"result":result}))
                    .unwrap();
            }
        });
        Self { socket, frames, worker: Some(worker) }
    }

    fn mux(&self, name: &str) -> Arc<Mux> {
        let mux = Mux::new_for_test(name, crate::SurfaceOptions::default());
        mux.set_acpmux_socket(Some(self.socket.clone()));
        mux
    }

    fn methods(&self) -> Vec<String> {
        self.frames.try_iter().map(|v| v["method"].as_str().unwrap().to_owned()).collect()
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        // Wake accept when a policy test correctly made no connection.
        let _ = UnixStream::connect(&self.socket);
        let result = self.worker.take().unwrap().join();
        let _ = std::fs::remove_file(&self.socket);
        if !std::thread::panicking() {
            assert!(result.is_ok(), "fake inventory owner failed");
        }
    }
}

fn snapshot() -> Value {
    json!({"view":"inventory","cached":true,"harnesses":[{
        "id":"claude","channel":"launcher","version":null,"latest":null,
        "latestCheckedAt":null,"outdated":false,"auth":"unknown","checkedAt":123,
        "program":"/private/cli","update":{"command":"private"}
    }],"diagnostics":"private"})
}

#[test]
fn cmux_next_agent_inventory_negotiates_and_reads_only_this_owner() {
    let owner = Owner::new(json!(["harnessInventory"]), snapshot());
    let mux = owner.mux("inventory-owner");
    let mut client = Client::connect(&mux, "inventory-owner");
    let reply = client.request(json!({"cmd":"agent-inventory"}));
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["data"]["view"], "inventory");
    assert_eq!(reply["data"]["cached"], true);
    let row = &reply["data"]["harnesses"][0];
    assert_eq!(row["channel"], "launcher");
    assert_eq!(row["auth"], "unknown");
    assert_eq!(row["version"], Value::Null);
    assert!(row.get("program").is_none());
    assert!(row.get("update").is_none());
    assert!(reply["data"].get("diagnostics").is_none());
    let frames: Vec<_> = owner.frames.try_iter().collect();
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["method"], "initialize");
    assert_eq!(frames[1]["method"], "_acpmux/harness/health");
    assert_eq!(frames[1]["params"], json!({"view":"inventory"}));
}

#[test]
fn cmux_next_agent_inventory_old_owners_never_receive_health() {
    for features in [
        Value::Null,
        json!([]),
        json!("harnessInventory"),
        json!(["harnessInventoryExtra"]),
        json!(["harnessInventory", 1]),
    ] {
        let owner = Owner::new(features, snapshot());
        let mux = owner.mux("inventory-old");
        let mut client = Client::connect(&mux, "inventory-old");
        assert_code(
            &client.request(json!({"cmd":"agent-inventory"})),
            "agent_inventory.unsupported",
        );
        assert_eq!(owner.methods(), ["initialize"]);
    }
}

#[test]
fn cmux_next_agent_inventory_refuses_controls_and_other_machines() {
    let owner = Owner::new(json!(["harnessInventory"]), snapshot());
    let mux = owner.mux("inventory-params");
    let mut client = Client::connect(&mux, "inventory-params");
    for key in [
        "machine",
        "socket",
        "session",
        "command",
        "initial_command",
        "tmux_start_command",
        "pane_start_command",
        "refresh",
        "rescan",
        "autoUpdate",
        "checkLatest",
        "view",
    ] {
        let mut frame = json!({"cmd":"agent-inventory"});
        frame[key] = json!(true);
        assert_code(&client.request(frame), "agent_inventory.bad_request");
    }
    assert!(owner.methods().is_empty());
}

#[test]
fn cmux_next_agent_inventory_is_refused_on_untrusted_and_remote_connections() {
    let owner = Owner::new(json!(["harnessInventory"]), snapshot());
    let mux = owner.mux("inventory-trust");
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let websocket = mux.control_clients.register(ClientTransport::WebSocket, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    assert!(handle_connection_frame(
        &mux,
        websocket,
        ClientTransport::WebSocket,
        r#"{"id":1,"cmd":"agent-inventory"}"#,
        &writer,
        &scheduler
    ));
    let reply: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_code(&reply, "agent_inventory.not_trusted");
    let remote = mux.control_clients.register(ClientTransport::Remote, writer.clone());
    assert!(handle_connection_frame(
        &mux,
        remote,
        ClientTransport::Remote,
        r#"{"id":2,"cmd":"agent-inventory"}"#,
        &writer,
        &scheduler
    ));
    let reply: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_code(&reply, "remote_denied");
    assert!(owner.methods().is_empty());
}

#[test]
fn cmux_next_agent_inventory_capability_and_unavailable_owner() {
    let owner = Owner::new(json!(["harnessInventory"]), snapshot());
    let mux = owner.mux("inventory-cap");
    assert!(
        run(&mux, json!({"cmd":"identify"}))["capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!("agent-inventory-v1"))
    );
    // A missing socket never starts acpmux or falls back to another machine.
    mux.set_acpmux_socket(Some(owner.socket.with_extension("missing")));
    let mut client = Client::connect(&mux, "inventory-missing");
    assert_code(&client.request(json!({"cmd":"agent-inventory"})), "agent_inventory.unavailable");
    mux.set_acpmux_socket(None);
    assert!(
        !run(&mux, json!({"cmd":"identify"}))["capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!("agent-inventory-v1"))
    );
    assert_code(&client.request(json!({"cmd":"agent-inventory"})), "agent_inventory.unavailable");
}

#[test]
fn cmux_next_agent_inventory_refuses_legacy_or_non_cached_answers() {
    for result in [
        json!({"harnesses":[]}),
        json!({"view":"inventory","cached":false,"harnesses":[]}),
        json!({"view":"inventory","cached":true,"harnesses":[{"id":"bad"}]}),
    ] {
        let owner = Owner::new(json!(["harnessInventory"]), result);
        let mux = owner.mux("inventory-invalid");
        let mut client = Client::connect(&mux, "inventory-invalid");
        assert_code(
            &client.request(json!({"cmd":"agent-inventory"})),
            "agent_inventory.invalid_response",
        );
        assert_eq!(owner.methods(), ["initialize", "_acpmux/harness/health"]);
    }
}

#[test]
fn cmux_next_agent_inventory_owner_matches_before_reading_the_cache() {
    let owner = Owner::new(json!(["harnessInventory"]), snapshot());
    let mux = owner.mux("inventory-fenced");
    let identity = run(&mux, json!({"cmd":"identify"}));
    let mut client = Client::connect(&mux, "inventory-fenced");
    let reply = client.request(json!({
        "cmd":"agent-inventory", "expected_machine_id":identity["machine_id"]
    }));
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["data"]["view"], "inventory");
    assert_eq!(owner.methods(), ["initialize", "_acpmux/harness/health"]);
}

#[test]
fn cmux_next_agent_inventory_owner_change_is_refused_before_any_owner_call() {
    let previous = Mux::new_for_test("previous-owner", crate::SurfaceOptions::default());
    let selected = run(&previous, json!({"cmd":"identify"}))["machine_id"].clone();
    let owner = Owner::new(json!(["harnessInventory"]), snapshot());
    let mux = owner.mux("replacement-owner");
    let mut client = Client::connect(&mux, "replacement-owner");
    let reply = client.request(json!({
        "cmd":"agent-inventory", "expected_machine_id":selected
    }));
    assert_code(&reply, "agent_inventory.owner_mismatch");
    assert!(owner.methods().is_empty());
    assert!(reply.get("data").is_none_or(Value::is_null));
    assert!(!reply.to_string().contains(mux.machine_public_id.as_str()));
    // Identity admission precedes even a check for a running acpmux.
    mux.set_acpmux_socket(None);
    assert_code(
        &client.request(json!({"cmd":"agent-inventory", "expected_machine_id":selected})),
        "agent_inventory.owner_mismatch",
    );
}

#[test]
fn cmux_next_agent_inventory_owner_rejects_malformed_fences_without_reading() {
    let owner = Owner::new(json!(["harnessInventory"]), snapshot());
    let mux = owner.mux("inventory-bad-fence");
    let mut client = Client::connect(&mux, "inventory-bad-fence");
    for value in [
        Value::Null,
        json!(1),
        json!(true),
        json!({}),
        json!(""),
        json!("local"),
        json!("machine_wrong"),
        json!("machine_00000000000000000000000000000000\n"),
    ] {
        assert_code(
            &client.request(json!({"cmd":"agent-inventory", "expected_machine_id":value})),
            "agent_inventory.bad_request",
        );
    }
    assert!(owner.methods().is_empty());
}

#[test]
fn cmux_next_agent_inventory_owner_support_is_negotiated_separately() {
    let mux = Mux::new_for_test("inventory-fence-cap", crate::SurfaceOptions::default());
    for socket in [None, Some(PathBuf::from("/not-running/acpmux.sock")), None] {
        mux.set_acpmux_socket(socket.clone());
        let identity = run(&mux, json!({"cmd":"identify"}));
        assert_eq!(
            identity["capabilities"]
                .as_array()
                .unwrap()
                .contains(&json!("agent-inventory-owner-v1")),
            socket.is_some(),
        );
    }
}
