//! `client-hello` step 1 over a real connection loop (plans/cmux-next/
//! request-origin.md, "Hello and capability"): the hello window, the role,
//! the errors, and what a connection without a hello may do.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::server::origin_gate::role_for_test;
use crate::server::*;

const WAIT: Duration = Duration::from_secs(5);

/// One connection served by the line loop on a private socket.
pub(in crate::server) struct Client {
    writer: Box<dyn transport::Stream>,
    reader: BufReader<Box<dyn transport::Stream>>,
    events: VecDeque<Value>,
    next_id: u64,
    directory: PathBuf,
    handler: Option<JoinHandle<()>>,
}

impl Client {
    pub(in crate::server) fn connect(mux: &Arc<Mux>, label: &str) -> Self {
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
            serve_connection(
                server_mux,
                server,
                Arc::new(RenderService::new()),
                None,
                kind,
                Box::new(admission::LocalAdmission),
                Box::<frame_dispatch::RequestFrames>::default(),
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
    pub(in crate::server) fn request(&mut self, mut value: Value) -> Value {
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

    /// The next event `wanted` accepts within `wait`; the other events
    /// stay queued in arrival order. None: none came.
    pub(in crate::server) fn event_within(
        &mut self,
        wait: Duration,
        wanted: impl Fn(&Value) -> bool,
    ) -> Option<Value> {
        if let Some(at) = self.events.iter().position(&wanted) {
            return self.events.remove(at);
        }
        let deadline = Instant::now() + wait;
        while let Some(line) = self.read_line(deadline) {
            if line.get("event").is_none() {
                continue;
            }
            if wanted(&line) {
                return Some(line);
            }
            self.events.push_back(line);
        }
        None
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

/// `bridge-hello`: a bridge's first line, which keeps the
/// far client's hello window open, and only there.
#[test]
fn bridge_hello_first_keeps_the_far_clients_window_open() {
    let mux = mux("bridge-first");
    let mut client = Client::connect(&mux, "bridge-first");
    let reply = client.request(json!({"cmd": "bridge-hello", "features": ["bridge-frames-v1"]}));
    assert_eq!(reply["ok"], true, "{reply}");
    // The test binary is the daemon's own executable: a kernel byte bridge.
    assert_eq!(reply["data"]["features"], json!(["bridge-frames-v1"]), "{reply}");
    assert!(frame_bridge(&mux, only_client(&mux)));
    client.identify();
    assert_ok_connection_id(&client.hello(json!({"role": "main"})), &mux);
    assert_eq!(role_for_test(&mux, only_client(&mux)), "main");
}

#[test]
fn a_second_bridge_hello_is_window_closed() {
    let mux = mux("bridge-twice");
    let mut client = Client::connect(&mux, "bridge-twice");
    let first = client.request(json!({"cmd": "bridge-hello", "features": ["bridge-frames-v1"]}));
    assert_eq!(first["ok"], true, "{first}");
    let again = client.request(json!({"cmd": "bridge-hello", "features": ["bridge-frames-v1"]}));
    assert_hello_error(&again, "bridge_hello.window_closed");
}

#[test]
fn bridge_hello_after_any_line_is_window_closed_and_changes_nothing() {
    let mux = mux("bridge-late");
    let mut client = Client::connect(&mux, "bridge-late");
    client.identify();
    let reply = client.request(json!({"cmd": "bridge-hello", "features": ["bridge-frames-v1"]}));
    assert_hello_error(&reply, "bridge_hello.window_closed");
    assert!(!frame_bridge(&mux, only_client(&mux)));
}

/// Whether `client` counts as a framed bridge for the grant rule.
fn frame_bridge(mux: &Mux, client: u64) -> bool {
    let state = mux.control_clients.state.lock().unwrap();
    state.clients.get(&client).is_some_and(|record| record.origin.frame_bridge)
}

#[test]
fn bridge_hello_validates_its_features_and_ignores_unknown_ones() {
    let mux = mux("bridge-bad");
    let mut bad = Client::connect(&mux, "bridge-bad");
    let reply = bad.request(json!({"cmd": "bridge-hello", "features": "bridge-frames-v1"}));
    assert_hello_error(&reply, "bridge_hello.bad_request");
    drop(bad);
    let mut unknown = Client::connect(&mux, "bridge-unknown");
    let reply = unknown.request(json!({"cmd": "bridge-hello", "features": ["later-v9"]}));
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["data"]["features"], json!([]), "{reply}");
}

#[test]
fn bridge_hello_on_a_non_unix_connection_is_local_only() {
    let mux = mux("bridge-remote");
    let mut client = Client::connect_with(&mux, "bridge-remote", ClientTransport::Remote);
    let reply = client.request(json!({"cmd": "bridge-hello", "features": ["bridge-frames-v1"]}));
    assert_hello_error(&reply, "bridge_hello.local_only");
    assert!(!frame_bridge(&mux, only_client(&mux)));
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
        // Present but null is malformed too (sdk-schema: not nullable).
        ("null", json!({"role": null})),
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
        // Present but null is malformed too (sdk-schema: not nullable).
        ("null", Value::Null),
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

/// Step 2 needs `install_id` and `proof` as strings (spec/sdk-schema.json:
/// not nullable): a null one is client_hello.refused even when the other
/// member and the key would prove the install.
#[test]
fn step_two_refuses_a_null_install_id_or_proof() {
    use cmux_local_auth::frontend_proof::{NONCE_LEN, hello_proof, unhex};
    const KEY_HEX: &str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    let key = unhex::<32>(KEY_HEX).unwrap();
    for (label, null_install_id, null_proof) in
        [("null-install-id", true, false), ("null-proof", false, true), ("both-set", false, false)]
    {
        let mux = mux(label);
        let frontend_key = FrontendKey::parse(&format!("cmuxik1 inst_s2 {KEY_HEX}")).unwrap();
        assert!(install_frontend_key(&mux, frontend_key));
        let mut client = Client::connect(&mux, label);
        let started = client.hello(json!({"role": "main", "install_id": "inst_s2"}));
        let nonce = unhex::<NONCE_LEN>(started["data"]["nonce"].as_str().unwrap()).unwrap();
        let proof = hello_proof(&key, "inst_s2", &nonce);
        let reply = client.hello(json!({
            "install_id": if null_install_id { Value::Null } else { json!("inst_s2") },
            "proof": if null_proof { Value::Null } else { json!(proof) },
        }));
        if null_install_id || null_proof {
            assert_hello_error(&reply, "client_hello.refused");
        } else {
            assert_eq!(reply["data"]["verified"], true, "{reply}");
        }
    }
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

/// A page relay needs no subscribe; its legacy lines (`subscribe` and
/// `ping` included) are refused (server/untrusted_mint_tests.rs), and its
/// catalog requests reach page_access.rs, which refuses every catalog
/// operation for a page (the allow list is empty).
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
    assert_eq!(ping["error"]["code"], "origin.forbidden", "{ping}");
    assert_eq!(ping["error"]["details"]["derived"], "page", "{ping}");
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
    // And is never user: a user claim is refused with derived agent.
    let refused = client.request(json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "operation": "session.ping",
        "params": {"machine": "current", "session": "current"},
        "origin": {"claim": "user"},
    }));
    assert_eq!(refused["error"]["code"], "origin.forbidden", "{refused}");
    assert_eq!(refused["error"]["details"]["derived"], "agent", "{refused}");
}

/// The daemon features of the hello tests: a
/// `process=daemon` kill switch, a perfPath and a `process=both` kill switch.
mod features {
    use super::*;
    use cmux_features::{Channel, Defaults, FeatureDef, Kind, Live, Process, Snapshot, Source};

    const TABLE: &[FeatureDef] = &[
        FeatureDef {
            name: "flagsFetch",
            defaults: Defaults { dev: true, nightly: true, release: true },
            kind: Kind::KillSwitch,
            process: Process::Daemon,
        },
        FeatureDef {
            name: "terminalHolder",
            defaults: Defaults { dev: false, nightly: false, release: false },
            kind: Kind::PerfPath,
            process: Process::Both,
        },
        FeatureDef {
            name: "holderKill",
            defaults: Defaults { dev: true, nightly: true, release: true },
            kind: Kind::KillSwitch,
            process: Process::Both,
        },
    ];
    const KEY_HEX: &str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

    fn installed(label: &str) -> Arc<Mux> {
        let mux = mux(label);
        let snapshot = Snapshot::defaults_of(TABLE, Channel::Release);
        assert!(install_daemon_features(&mux, Live::new(snapshot)));
        mux
    }

    /// `installed` with the app's install key, so step 2 can prove it.
    fn keyed(label: &str) -> Arc<Mux> {
        let mux = installed(label);
        let frontend_key = FrontendKey::parse(&format!("cmuxik1 inst_f {KEY_HEX}")).unwrap();
        assert!(install_frontend_key(&mux, frontend_key));
        mux
    }

    fn live(mux: &Mux) -> &Live {
        daemon_features(mux).expect("installed")
    }

    fn enabled(mux: &Mux, name: &str) -> bool {
        let live = live(mux);
        live.is_enabled(live.snapshot().feature(name).unwrap())
    }

    /// Step 2 of an install-key hello whose step 1 reply is `started`.
    fn prove(client: &mut Client, started: &Value) -> Value {
        use cmux_local_auth::frontend_proof::{NONCE_LEN, hello_proof, unhex};
        let key = unhex::<32>(KEY_HEX).unwrap();
        let nonce = unhex::<NONCE_LEN>(started["data"]["nonce"].as_str().unwrap()).unwrap();
        client.hello(json!({"install_id": "inst_f", "proof": hello_proof(&key, "inst_f", &nonce)}))
    }

    #[test]
    fn a_proved_hello_turns_a_daemon_kill_switch_off_at_once() {
        let mux = keyed("features-kill");
        let mut client = Client::connect(&mux, "features-kill");
        let values = json!({"flagsFetch": false, "terminalHolder": false, "holderKill": true});
        let started = client.hello(json!({
            "role": "main",
            "install_id": "inst_f",
            "features": {"hash": "0000000000000000", "values": values},
        }));
        // Not proved yet: the kill switch is reported pending, not applied.
        assert_eq!(started["data"]["features"]["applied"], json!([]), "{started}");
        assert_eq!(
            started["data"]["features"]["pending"],
            json!([{"name": "flagsFetch", "app": false, "daemon": true}]),
            "{started}"
        );
        assert!(enabled(&mux, "flagsFetch"));

        let proved = prove(&mut client, &started);
        assert_eq!(proved["data"]["verified"], true, "{proved}");
        assert_eq!(proved["data"]["features"]["applied"], json!(["flagsFetch"]), "{proved}");
        assert_eq!(proved["data"]["features"]["pending"], json!([]), "{proved}");
        assert!(!enabled(&mux, "flagsFetch"));
        let live = live(&mux);
        assert_eq!(live.source(live.snapshot().feature("flagsFetch").unwrap()), Source::Hello);
        assert_eq!(proved["data"]["features"]["hash"], json!(live.hash()), "{proved}");
    }

    #[test]
    fn a_perf_path_or_both_mismatch_is_pending_and_keeps_the_daemon_value() {
        let mux = keyed("features-pending");
        let mut client = Client::connect(&mux, "features-pending");
        let started = client.hello(json!({
            "role": "main",
            "install_id": "inst_f",
            "features": {"values": {"flagsFetch": true, "terminalHolder": true, "holderKill": false}},
        }));
        let proved = prove(&mut client, &started);
        assert_eq!(proved["data"]["verified"], true, "{proved}");
        assert_eq!(proved["data"]["features"]["applied"], json!([]), "{proved}");
        let mut pending = proved["data"]["features"]["pending"].as_array().unwrap().clone();
        pending.sort_by_key(|item| item["name"].as_str().unwrap().to_owned());
        assert_eq!(
            pending,
            [
                json!({"name": "holderKill", "app": false, "daemon": true}),
                json!({"name": "terminalHolder", "app": true, "daemon": false}),
            ],
            "{proved}"
        );
        // A `both` feature is read from the daemon's start value only.
        assert!(!enabled(&mux, "terminalHolder"));
        assert!(enabled(&mux, "holderKill"));
    }

    #[test]
    fn an_unverified_hello_kills_nothing() {
        let mux = installed("features-unverified");
        let mut client = Client::connect(&mux, "features-unverified");
        let reply =
            client.hello(json!({"role": "main", "features": {"values": {"flagsFetch": false}}}));
        assert_eq!(reply["ok"], true, "{reply}");
        assert_eq!(reply["data"]["features"]["applied"], json!([]), "{reply}");
        assert_eq!(
            reply["data"]["features"]["pending"],
            json!([{"name": "flagsFetch", "app": false, "daemon": true}]),
            "{reply}"
        );
        assert!(enabled(&mux, "flagsFetch"));
    }

    /// The hello's feature step gets only the hello's values and the
    /// daemon's in-memory `Live`: no mux, no path, no flags reader and no
    /// fetcher. The fn type below fails to compile if that step ever takes
    /// one, and cmux-features checks that `Live` itself does no I/O
    /// (`hello::tests::the_reconcile_module_does_no_io`).
    #[test]
    fn the_daemon_never_fetches_on_a_hello() {
        use super::super::HelloFeatures;
        let report: fn(&HelloFeatures, &Live, bool) -> Value = HelloFeatures::report;
        let hello = HelloFeatures {
            hash: Some("0000000000000000".into()),
            values: vec![("flagsFetch".into(), false), ("terminalHolder".into(), true)],
        };
        let live = Live::new(Snapshot::defaults_of(TABLE, Channel::Release));
        let unverified = report(&hello, &live, false);
        assert_eq!(unverified["applied"], json!([]), "{unverified}");
        let mut pending = unverified["pending"].as_array().unwrap().clone();
        pending.sort_by_key(|item| item["name"].as_str().unwrap().to_owned());
        assert_eq!(
            pending,
            [
                json!({"name": "flagsFetch", "app": false, "daemon": true}),
                json!({"name": "terminalHolder", "app": true, "daemon": false}),
            ],
            "{unverified}"
        );
        let proved = report(&hello, &live, true);
        assert_eq!(proved["applied"], json!(["flagsFetch"]), "{proved}");
        assert_eq!(
            proved["pending"],
            json!([{"name": "terminalHolder", "app": true, "daemon": false}]),
            "{proved}"
        );
        assert_eq!(proved["hash"], json!(live.hash()), "{proved}");
    }

    #[test]
    fn a_daemon_without_features_answers_with_no_report() {
        let mux = mux("features-none");
        let mut client = Client::connect(&mux, "features-none");
        let reply =
            client.hello(json!({"role": "main", "features": {"values": {"flagsFetch": false}}}));
        assert_eq!(reply["ok"], true, "{reply}");
        assert!(reply["data"].get("features").is_none(), "{reply}");
        assert!(daemon_features(&mux).is_none());
    }

    #[test]
    fn malformed_features_or_a_page_relay_with_features_is_a_bad_request() {
        for (label, params) in [
            ("not-object", json!({"role": "main", "features": "x"})),
            ("no-values", json!({"role": "main", "features": {"hash": "h"}})),
            ("not-bool", json!({"role": "main", "features": {"values": {"flagsFetch": 0}}})),
            ("extra-key", json!({"role": "main", "features": {"values": {}, "kill": true}})),
            ("page-relay", json!({"role": "page_relay", "features": {"values": {}}})),
        ] {
            let mux = installed(label);
            let mut client = Client::connect(&mux, label);
            let reply = client.hello(params);
            assert_hello_error(&reply, "client_hello.bad_request");
            assert_eq!(reply["error_details"], json!({"field": "features"}), "{reply}");
            assert_eq!(role_for_test(&mux, only_client(&mux)), "legacy");
            assert!(enabled(&mux, "flagsFetch"));
        }
    }
}
