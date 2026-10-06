#![cfg(unix)]
//! P8 slice 3b-2 over a real session socket: a role-main `client-hello`
//! with the install-key proof makes a connection the verified app, and only
//! the verified app reaches origin `user` (`apps-set`). Every other order,
//! role or proof fails closed.

use cmux_local_auth::frontend_proof::{NONCE_LEN, hello_proof, unhex};
use cmux_tui_core::server::{FrontendKey, install_frontend_key};
use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

const INSTALL_ID: &str = "inst_frontend-test";
const KEY_HEX: &str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
const FORBIDDEN: &str = "origin.forbidden";

fn key() -> Vec<u8> {
    unhex::<32>(KEY_HEX).unwrap().to_vec()
}

fn daemon(name: &str, with_key: bool) -> (Arc<Mux>, PathBuf) {
    let mux = Mux::new(name, SurfaceOptions::default());
    if with_key {
        let key = FrontendKey::parse(&format!("cmuxik1 {INSTALL_ID} {KEY_HEX}\n")).unwrap();
        assert!(install_frontend_key(&mux, key));
        let again = FrontendKey::parse(&format!("cmuxik1 inst_other {KEY_HEX}")).unwrap();
        assert!(!install_frontend_key(&mux, again), "the first key wins");
    }
    let socket = std::env::temp_dir()
        .join(format!("cmux-hello-{}-{name}", std::process::id()))
        .join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    (mux, socket)
}

struct Client(BufReader<UnixStream>);

impl Client {
    fn connect(path: &Path) -> Self {
        let stream = UnixStream::connect(path).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(12))).unwrap();
        Self(BufReader::new(stream))
    }

    fn rpc(&mut self, value: Value) -> Value {
        writeln!(self.0.get_mut(), "{value}").unwrap();
        let mut line = String::new();
        assert_ne!(self.0.read_line(&mut line).unwrap(), 0);
        serde_json::from_str(&line).unwrap()
    }

    fn challenge(&mut self, install_id: &str) -> Value {
        self.rpc(
            json!({ "id": 1, "cmd": "client-hello", "role": "main", "install_id": install_id }),
        )
    }

    fn prove(&mut self, install_id: &str, proof: &str) -> Value {
        self.rpc(
            json!({ "id": 2, "cmd": "client-hello", "install_id": install_id, "proof": proof }),
        )
    }

    /// Full two-step hello with the right key; returns the second reply.
    fn hello(&mut self) -> Value {
        let nonce = nonce_of(&self.challenge(INSTALL_ID));
        self.prove(INSTALL_ID, &hello_proof(&key(), INSTALL_ID, &nonce))
    }

    /// The error code of an origin-user `apps-set` (None when ok).
    fn origin_user(&mut self) -> Option<String> {
        let reply = self.rpc(json!({ "id": 3, "cmd": "apps-set", "origin": "user",
            "idempotency_key": "k", "app": "cmux/demo", "installed": true }));
        reply["error_code"].as_str().map(str::to_string)
    }
}

fn nonce_of(reply: &Value) -> [u8; NONCE_LEN] {
    assert_eq!(reply["ok"], true, "{reply}");
    unhex::<NONCE_LEN>(reply["data"]["nonce"].as_str().unwrap()).unwrap()
}

#[test]
fn only_a_proved_hello_reaches_origin_user() {
    let (_mux, socket) = daemon("hello-proved", true);

    let mut app = Client::connect(&socket);
    // One identify may come first, so a client can check capabilities.
    assert_eq!(app.rpc(json!({ "id": 0, "cmd": "identify" }))["ok"], true);
    let proved = app.hello();
    assert_eq!(proved["data"]["verified"], true, "{proved}");
    assert_eq!(proved["data"]["install_id"], INSTALL_ID, "{proved}");
    assert!(proved["data"]["connection_id"].as_str().is_some_and(|id| !id.is_empty()), "{proved}");
    assert_ne!(app.origin_user().as_deref(), Some(FORBIDDEN));

    // A page relay connection proves nothing, whatever it sends.
    let mut relay = Client::connect(&socket);
    let started = relay.rpc(json!({ "id": 1, "cmd": "client-hello", "role": "page_relay",
        "install_id": INSTALL_ID }));
    assert_eq!(started["ok"], true, "{started}");
    assert!(started["data"].get("nonce").is_none(), "{started}");
    assert!(started["data"]["connection_id"].is_string(), "{started}");
    assert_eq!(relay.origin_user().as_deref(), Some(FORBIDDEN));

    // A hello without a role is refused, and the connection stays unverified.
    let mut roleless = Client::connect(&socket);
    let refused = roleless.rpc(json!({ "id": 1, "cmd": "client-hello", "install_id": INSTALL_ID }));
    assert_ne!(refused["ok"], true, "{refused}");
    assert_eq!(roleless.origin_user().as_deref(), Some(FORBIDDEN));

    // A connection that only declares itself the app proves nothing.
    let mut claimant = Client::connect(&socket);
    claimant.rpc(json!({ "id": 1, "cmd": "set-client-info", "kind": "app", "name": "cmux" }));
    assert_eq!(claimant.origin_user().as_deref(), Some(FORBIDDEN));
}

#[test]
fn a_wrong_proof_or_install_id_fails_closed_for_the_whole_connection() {
    let (_mux, socket) = daemon("hello-wrong", true);

    let mut wrong_key = Client::connect(&socket);
    let nonce = nonce_of(&wrong_key.challenge(INSTALL_ID));
    let mut other = key();
    other[0] ^= 1;
    let refused = wrong_key.prove(INSTALL_ID, &hello_proof(&other, INSTALL_ID, &nonce));
    assert_eq!(refused["error_code"], "client_hello.refused", "{refused}");
    // No second try on the same connection, even with the right proof.
    assert_ne!(wrong_key.prove(INSTALL_ID, &hello_proof(&key(), INSTALL_ID, &nonce))["ok"], true);
    assert_eq!(wrong_key.origin_user().as_deref(), Some(FORBIDDEN));

    // An unknown install id still gets a nonce (no oracle) and fails only
    // at step 2, even with a proof made with the right key.
    let mut wrong_id = Client::connect(&socket);
    let nonce = nonce_of(&wrong_id.challenge("inst_someone-else"));
    let refused =
        wrong_id.prove("inst_someone-else", &hello_proof(&key(), "inst_someone-else", &nonce));
    assert_eq!(refused["error_code"], "client_hello.refused", "{refused}");
    assert_eq!(wrong_id.origin_user().as_deref(), Some(FORBIDDEN));

    // Step 2 must name the install id of step 1.
    let mut switched = Client::connect(&socket);
    let nonce = nonce_of(&switched.challenge("inst_someone-else"));
    let refused = switched.prove(INSTALL_ID, &hello_proof(&key(), INSTALL_ID, &nonce));
    assert_eq!(refused["error_code"], "client_hello.refused", "{refused}");

    // A proof in the first line proves nothing: without a role it is a bad
    // request, with a role it is only step 1 (a challenge, never verified).
    let guessed = hello_proof(&key(), INSTALL_ID, &[0; NONCE_LEN]);
    let mut unchallenged = Client::connect(&socket);
    assert_ne!(unchallenged.prove(INSTALL_ID, &guessed)["ok"], true);
    assert_eq!(unchallenged.origin_user().as_deref(), Some(FORBIDDEN));
    let mut early = Client::connect(&socket);
    let started = early.rpc(json!({ "id": 1, "cmd": "client-hello", "role": "main",
        "install_id": INSTALL_ID, "proof": guessed }));
    assert!(started["data"].get("verified").is_none(), "{started}");
    assert_eq!(early.origin_user().as_deref(), Some(FORBIDDEN));
}

#[test]
fn the_hello_must_be_the_first_request_after_at_most_one_identify() {
    let (_mux, socket) = daemon("hello-late", true);
    let mut late = Client::connect(&socket);
    assert_eq!(late.rpc(json!({ "id": 1, "cmd": "set-client-info", "kind": "app" }))["ok"], true);
    let challenge = late.challenge(INSTALL_ID);
    assert_ne!(challenge["ok"], true, "{challenge}");
    assert_eq!(late.origin_user().as_deref(), Some(FORBIDDEN));

    // Two identify lines close the window.
    let mut chatty = Client::connect(&socket);
    for id in [1, 2] {
        assert_eq!(chatty.rpc(json!({ "id": id, "cmd": "identify" }))["ok"], true);
    }
    assert_ne!(chatty.challenge(INSTALL_ID)["ok"], true);
    assert_eq!(chatty.origin_user().as_deref(), Some(FORBIDDEN));

    // Between the two steps nothing else may come.
    let mut interleaved = Client::connect(&socket);
    let nonce = nonce_of(&interleaved.challenge(INSTALL_ID));
    interleaved.rpc(json!({ "id": 9, "cmd": "identify" }));
    assert_ne!(interleaved.prove(INSTALL_ID, &hello_proof(&key(), INSTALL_ID, &nonce))["ok"], true);
    assert_eq!(interleaved.origin_user().as_deref(), Some(FORBIDDEN));
}

#[test]
fn nonces_are_per_connection_and_a_proof_never_replays() {
    let (_mux, socket) = daemon("hello-replay", true);
    let mut first = Client::connect(&socket);
    let first_nonce = nonce_of(&first.challenge(INSTALL_ID));
    let mut second = Client::connect(&socket);
    let second_nonce = nonce_of(&second.challenge(INSTALL_ID));
    assert_ne!(first_nonce, second_nonce);
    // The first connection's proof does not verify the second.
    let replayed = second.prove(INSTALL_ID, &hello_proof(&key(), INSTALL_ID, &first_nonce));
    assert_eq!(replayed["error_code"], "client_hello.refused");
    assert_eq!(second.origin_user().as_deref(), Some(FORBIDDEN));
    // The proved identity cannot change: a second hello is not handled.
    assert_eq!(first.prove(INSTALL_ID, &hello_proof(&key(), INSTALL_ID, &first_nonce))["ok"], true);
    assert_ne!(first.challenge(INSTALL_ID)["ok"], true);
    assert_ne!(first.origin_user().as_deref(), Some(FORBIDDEN));
}

#[test]
fn a_daemon_the_app_did_not_start_has_no_install_key() {
    let (_mux, socket) = daemon("hello-nokey", false);
    let mut app = Client::connect(&socket);
    let refused = app.hello();
    assert_eq!(refused["error_code"], "client_hello.refused", "{refused}");
    assert_eq!(app.origin_user().as_deref(), Some(FORBIDDEN));
}

fn v2(operation: &str, params: Value, origin: Option<Value>) -> Value {
    let mut request = json!({ "protocol": "cmux.protocol/2", "type": "request", "id": "r1",
        "operation": operation, "params": params, "idempotency_key": "k1" });
    if let Some(origin) = origin {
        request["origin"] = origin;
    }
    request
}

/// P8 over real sockets (DEV build, prover B): the app's proved main
/// connection and its page relay come from one process, so they share the
/// audit-token peer key, and the main connection can confirm a relay call.
#[test]
fn a_proved_app_confirms_for_its_own_page_relay() {
    let (_mux, socket) = daemon("hello-confirm", true);
    let mut app = Client::connect(&socket);
    assert_eq!(app.hello()["data"]["verified"], true);
    let mut relay = Client::connect(&socket);
    let started = relay.rpc(json!({ "id": 1, "cmd": "client-hello", "role": "page_relay" }));
    let relay_id = started["data"]["connection_id"].as_str().expect("connection id").to_string();
    let params = json!({ "app": "cmux/demo", "version": "1.0.0" });
    // SHA-256 of the params in canonical JSON (sorted keys, no whitespace).
    let sha = sha256_hex(br#"{"app":"cmux/demo","version":"1.0.0"}"#);
    let issued = app.rpc(json!({ "protocol": "cmux.protocol/2", "type": "request", "id": "i1",
        "operation": "origin.confirmation.issue", "params": { "machine": "current",
        "session": "current", "operation": "apps.install", "params_sha256": sha,
        "relay_connection_id": relay_id } }));
    assert_eq!(issued["ok"], true, "{issued}");
    let token = issued["result"]["token"].as_str().expect("token").to_string();
    let claim = json!({ "claim": "user", "confirmation": token });
    let confirmed = relay.rpc(v2("apps.install", params.clone(), Some(claim.clone())));
    assert_ne!(confirmed["error"]["code"], FORBIDDEN, "{confirmed}");
    // Single use.
    let replayed = relay.rpc(v2("apps.install", params, Some(claim)));
    assert_eq!(replayed["error"]["code"], FORBIDDEN, "{replayed}");
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::Digest;
    sha2::Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Each `client-hello` reply says whether origin `user` is allowed on the
/// connection (`user_origin_allowed`), so the app sends `user` only then
/// and never resends a refused click as `script`. The value equals what an
/// origin-user request then gets.
#[test]
fn hello_replies_say_whether_origin_user_is_allowed() {
    let allowed = |reply: &Value| {
        assert_eq!(reply["ok"], true, "{reply}");
        reply["data"]["user_origin_allowed"].as_bool().unwrap_or_else(|| panic!("no bool: {reply}"))
    };
    let (_mux, socket) = daemon("hello-allowed", true);

    // Prover B: step 1 is not yet proved, step 2 is.
    let mut app = Client::connect(&socket);
    let started = app.challenge(INSTALL_ID);
    assert!(!allowed(&started));
    let proved = app.prove(INSTALL_ID, &hello_proof(&key(), INSTALL_ID, &nonce_of(&started)));
    assert!(allowed(&proved));
    assert_ne!(app.origin_user().as_deref(), Some(FORBIDDEN));

    // Role main without a proof (an unsigned build with no install id).
    let mut unproved = Client::connect(&socket);
    assert!(!allowed(&unproved.rpc(json!({ "id": 1, "cmd": "client-hello", "role": "main" }))));
    assert_eq!(unproved.origin_user().as_deref(), Some(FORBIDDEN));

    // A page relay never.
    let mut relay = Client::connect(&socket);
    assert!(!allowed(&relay.rpc(json!({ "id": 1, "cmd": "client-hello", "role": "page_relay" }))));
    assert_eq!(relay.origin_user().as_deref(), Some(FORBIDDEN));

    // A daemon with no install key: step 1 is not allowed, step 2 is refused.
    let (_mux, socket) = daemon("hello-allowed-nokey", false);
    let mut keyless = Client::connect(&socket);
    assert!(!allowed(&keyless.challenge(INSTALL_ID)));
    assert_eq!(keyless.origin_user().as_deref(), Some(FORBIDDEN));
}
