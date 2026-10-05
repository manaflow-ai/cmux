//! `client-hello` step 1 over a real connection loop (plans/cmux-next/
//! request-origin.md, "Hello and capability"): the hello window, the role,
//! the errors, and what a connection without a hello may do.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::server::origin_gate::role_for_test;
use crate::server::*;

const WAIT: Duration = Duration::from_secs(5);

/// One connection served by the line loop on a private socket.
pub(super) struct Client {
    writer: Box<dyn transport::Stream>,
    reader: BufReader<Box<dyn transport::Stream>>,
    events: VecDeque<Value>,
    next_id: u64,
    directory: PathBuf,
    handler: Option<JoinHandle<()>>,
}

impl Client {
    pub(super) fn connect(mux: &Arc<Mux>, label: &str) -> Self {
        Self::connect_with(mux, label, ClientTransport::Unix)
    }

    pub(super) fn connect_with(mux: &Arc<Mux>, label: &str, kind: ClientTransport) -> Self {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let directory = std::env::temp_dir().join(format!(
            "cmux-hello-{label}-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("s.sock");
        let listener = transport::listen(&path).unwrap();
        let client = transport::connect(&path).unwrap();
        let server = listener.accept().unwrap();
        let server_mux = mux.clone();
        let handler = std::thread::spawn(move || {
            serve_line_connection(
                server_mux,
                server,
                Arc::new(RenderService::new()),
                None,
                kind,
                &admission::LocalAdmission,
            );
        });
        let reader = client.try_clone_box().unwrap();
        reader.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
        Self {
            writer: client,
            reader: BufReader::new(reader),
            events: VecDeque::new(),
            next_id: 1,
            directory,
            handler: Some(handler),
        }
    }

    fn read_line(&mut self, deadline: Instant) -> Option<Value> {
        let mut line = String::new();
        while Instant::now() < deadline {
            match self.reader.read_line(&mut line) {
                Ok(0) => return None,
                Ok(_) if line.ends_with('\n') => return Some(serde_json::from_str(&line).unwrap()),
                Ok(_) => continue,
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    continue;
                }
                Err(error) => panic!("read failed: {error}"),
            }
        }
        None
    }

    /// Sends `value` with a fresh numeric id and returns its reply.
    pub(super) fn request(&mut self, mut value: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        // cmux.protocol/2 ids are strings; raw command ids are numbers.
        value["id"] =
            if value.get("protocol").is_some() { json!(id.to_string()) } else { json!(id) };
        writeln!(self.writer, "{value}").unwrap();
        self.writer.flush().unwrap();
        let deadline = Instant::now() + WAIT;
        loop {
            let line = self.read_line(deadline).expect("no response before the deadline");
            if line.get("event").is_some() {
                self.events.push_back(line);
            } else if line["id"] == json!(id) || line["id"] == json!(id.to_string()) {
                return line;
            }
        }
    }

    pub(super) fn hello(&mut self, params: Value) -> Value {
        let mut request = json!({"cmd": "client-hello"});
        for (key, value) in params.as_object().unwrap() {
            request[key] = value.clone();
        }
        self.request(request)
    }

    pub(super) fn identify(&mut self) -> Value {
        let reply = self.request(json!({"cmd": "identify"}));
        assert_eq!(reply["ok"], true, "{reply}");
        reply
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.writer.shutdown(Shutdown::Both);
        if let Some(handler) = self.handler.take() {
            let _ = handler.join();
        }
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(format!("hello-{label}"), crate::SurfaceOptions::default())
}

/// The only connection registered on `mux` (each test opens one at a time).
fn only_client(mux: &Mux) -> u64 {
    let ids = mux.control_clients.client_ids();
    assert_eq!(ids.len(), 1, "{ids:?}");
    ids[0]
}

fn assert_hello_error(reply: &Value, code: &str) {
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error_code"], code, "{reply}");
}

fn assert_ok_connection_id(reply: &Value, mux: &Mux) {
    assert_eq!(reply["ok"], true, "{reply}");
    let connection_id = reply["data"]["connection_id"].as_str().expect("connection_id string");
    assert_eq!(connection_id, only_client(mux).to_string());
}

/// P8 nonce rule: a nonce exactly when role main names an install id.
fn assert_nonce(reply: &Value, expected: bool) {
    let nonce = reply["data"].get("nonce").and_then(Value::as_str);
    assert_eq!(nonce.is_some(), expected, "{reply}");
    if let Some(nonce) = nonce {
        assert!(nonce.len() == 64 && nonce.bytes().all(|b| b.is_ascii_hexdigit()), "{reply}");
    }
}

#[test]
fn hello_as_first_line_returns_the_connection_id_and_fixes_the_role() {
    let mux = mux("first");
    let mut client = Client::connect(&mux, "first");
    let reply = client.hello(json!({"role": "main"}));
    assert_ok_connection_id(&reply, &mux);
    assert_nonce(&reply, false);
    assert_eq!(role_for_test(&mux, only_client(&mux)), "main");
}

#[test]
fn hello_after_exactly_one_identify_is_accepted() {
    let mux = mux("after-identify");
    let mut client = Client::connect(&mux, "after-identify");
    client.identify();
    let reply = client.hello(json!({"role": "page_relay"}));
    assert_ok_connection_id(&reply, &mux);
    assert_eq!(role_for_test(&mux, only_client(&mux)), "page_relay");
}

#[test]
fn hello_after_any_other_line_is_window_closed() {
    let mux = mux("after-ping");
    let mut client = Client::connect(&mux, "after-ping");
    assert_eq!(client.request(json!({"cmd": "ping"}))["ok"], true);
    assert_hello_error(&client.hello(json!({"role": "main"})), "client_hello.window_closed");
    assert_eq!(role_for_test(&mux, only_client(&mux)), "legacy");
}

#[test]
fn hello_after_two_identify_lines_is_window_closed() {
    let mux = mux("two-identify");
    let mut client = Client::connect(&mux, "two-identify");
    client.identify();
    client.identify();
    assert_hello_error(&client.hello(json!({"role": "main"})), "client_hello.window_closed");
    assert_eq!(role_for_test(&mux, only_client(&mux)), "legacy");
}

#[test]
fn second_hello_is_window_closed_and_keeps_the_first_role() {
    let mux = mux("second");
    let mut client = Client::connect(&mux, "second");
    assert_ok_connection_id(&client.hello(json!({"role": "page_relay"})), &mux);
    assert_hello_error(&client.hello(json!({"role": "main"})), "client_hello.window_closed");
    assert_eq!(role_for_test(&mux, only_client(&mux)), "page_relay");
}

#[test]
fn role_is_required_and_a_bad_role_changes_nothing_and_closes_the_window() {
    for (label, params) in [
        ("missing", json!({})),
        ("unknown", json!({"role": "user"})),
        ("not-string", json!({"role": 7})),
    ] {
        let mux = mux(label);
        let mut client = Client::connect(&mux, label);
        let reply = client.hello(params);
        assert_hello_error(&reply, "client_hello.bad_request");
        assert_eq!(reply["error_details"], json!({"field": "role"}), "{reply}");
        assert_eq!(role_for_test(&mux, only_client(&mux)), "legacy");
        // The error closed the window: a good hello is now refused.
        assert_hello_error(&client.hello(json!({"role": "main"})), "client_hello.window_closed");
        assert_eq!(role_for_test(&mux, only_client(&mux)), "legacy");
    }
}

#[test]
fn install_id_is_validated_in_step_one() {
    for (label, install_id) in [
        ("empty", json!("")),
        ("long", json!("a".repeat(129))),
        ("space", json!("bad id")),
        ("slash", json!("a/b")),
        ("number", json!(5)),
    ] {
        let mux = mux(label);
        let mut client = Client::connect(&mux, label);
        let reply = client.hello(json!({"role": "main", "install_id": install_id}));
        assert_hello_error(&reply, "client_hello.bad_request");
        assert_eq!(reply["error_details"], json!({"field": "install_id"}), "{reply}");
        assert_eq!(role_for_test(&mux, only_client(&mux)), "legacy");
        assert_hello_error(&client.hello(json!({"role": "main"})), "client_hello.window_closed");
    }
    let mux = mux("good-id");
    let mut client = Client::connect(&mux, "good-id");
    let longest = "Inst_1-".repeat(19)[..128].to_string();
    let reply = client.hello(json!({"role": "main", "install_id": longest}));
    assert_ok_connection_id(&reply, &mux);
    assert_nonce(&reply, true);
}

#[test]
fn hello_on_a_non_unix_connection_is_local_only() {
    let mux = mux("remote");
    let mut client = Client::connect_with(&mux, "remote", ClientTransport::Remote);
    assert_hello_error(&client.hello(json!({"role": "main"})), "client_hello.local_only");
    assert_eq!(role_for_test(&mux, only_client(&mux)), "legacy");
    assert_hello_error(&client.hello(json!({"role": "main"})), "client_hello.window_closed");
}

#[test]
fn identify_reveals_no_per_connection_or_per_user_secret() {
    let mux = mux("identify-secret");
    let mut client = Client::connect(&mux, "identify-secret");
    let identify = client.identify();
    let data = identify["data"].as_object().unwrap().clone();
    for key in data.keys() {
        let lowered = key.to_ascii_lowercase();
        for forbidden in ["token", "nonce", "connection", "client", "secret", "socket", "install"] {
            assert!(!lowered.contains(forbidden), "identify exposes {key}: {identify}");
        }
    }
    let reply = client.hello(json!({"role": "main"}));
    assert_ok_connection_id(&reply, &mux);
    let connection_id = reply["data"]["connection_id"].clone();
    assert!(
        data.values().all(|value| *value != connection_id),
        "identify carries the connection id: {identify}"
    );
    // Static daemon facts only: a second connection sees the same keys.
    drop(client);
    let mut other = Client::connect(&mux, "identify-secret-2");
    let again = other.identify();
    let keys = |value: &Value| value.as_object().unwrap().keys().cloned().collect::<Vec<_>>();
    assert_eq!(keys(&identify["data"]), keys(&again["data"]));
}

#[test]
fn origin_claim_capability_is_advertised() {
    let mux = mux("capability");
    let mut client = Client::connect(&mux, "capability");
    let identify = client.identify();
    let capabilities = identify["data"]["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == "origin-claim-v1"), "{identify}");
}

/// A page relay is served `cmux.protocol/2` without a subscribe; its legacy
/// lines (`subscribe` and `ping` included) are refused
/// (server/untrusted_mint_tests.rs covers the default deny).
#[test]
fn page_relay_without_subscribe_is_served_and_subscribe_is_refused() {
    let mux = mux("relay-subscribe");
    let mut client = Client::connect(&mux, "relay-subscribe");
    assert_ok_connection_id(&client.hello(json!({"role": "page_relay"})), &mux);
    let legacy_ping = client.request(json!({"cmd": "ping"}));
    assert_eq!(legacy_ping["error_code"], "origin.forbidden", "{legacy_ping}");
    let ping = client.request(json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "operation": "session.ping",
        "params": {"machine": "current", "session": "current"},
    }));
    assert_eq!(ping["ok"], true, "{ping}");
    let refused = client.request(json!({"cmd": "subscribe"}));
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error_code"], "origin.forbidden", "{refused}");
}

#[test]
fn no_hello_is_the_legacy_client_role_and_set_client_info_never_sets_a_role() {
    let mux = mux("legacy");
    let mut client = Client::connect(&mux, "legacy");
    for kind in ["page_relay", "main", "app", "user"] {
        let reply = client.request(json!({"cmd": "set-client-info", "name": "x", "kind": kind}));
        assert_eq!(reply["ok"], true, "{reply}");
        assert_eq!(role_for_test(&mux, only_client(&mux)), "legacy");
    }
    // A legacy client may subscribe (never page_relay).
    assert_eq!(client.request(json!({"cmd": "subscribe"}))["ok"], true);
    // And is never user: the A2 gate refuses it with derived agent.
    let refused = client.request(json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "operation": "apps.install",
        "params": {"app": "cmux/demo"},
        "idempotency_key": "k1",
    }));
    assert_eq!(refused["error"]["code"], "origin.forbidden", "{refused}");
    assert_eq!(refused["error"]["details"]["derived"], "agent", "{refused}");
}
