//! The cloud lease gate (`cloud-lease-app-only-v1`, cx-59n8.7, cmux#13742)
//! at the daemon's socket. A real headless daemon starts with
//! `server ensure --install-key-stdin`, so one connection proves itself as
//! the cmux app (`client-hello`) the way the app does. That connection may
//! set and clear the human's cloud lease and send `origin: "user"`; a second
//! plain connection of the same uid (an agent or a script in a pane) is
//! refused with reason `forbidden` on all three, and nothing reaches the
//! cloud. The cloud is a loopback HTTP server that records each request.

use std::net::TcpListener;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};

use cmux_tui_core::server::frontend_proof::{NONCE_LEN, hello_proof, unhex};
use serde_json::{Value, json};

use super::*;

const KEY_HEX: &str = "4b1d2c3e5f60718293a4b5c6d7e8f901122334455667788990aabbccddeeff00";
const INSTALL: &str = "inst_lease_app";

struct Daemon {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Daemon {
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-lease-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let daemon = Self { socket: dir.join("mux.sock"), session: format!("lease-{name}"), dir };
        let mut child = daemon
            .server("ensure")
            .arg("--install-key-stdin")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let key = format!("cmuxik1 {INSTALL} {KEY_HEX}\n");
        child.stdin.take().unwrap().write_all(key.as_bytes()).unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "ensure failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        daemon
    }

    fn server(&self, action: &str) -> Command {
        let mut command = Command::new(bin());
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"));
        command
    }

    /// A plain local connection (an agent or a script in a pane).
    fn plain(&self) -> Client {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        Client { reader: BufReader::new(stream), next: 100 }
    }

    /// A connection proven as the cmux app (the `frontend` actor).
    fn app(&self) -> Client {
        let mut client = self.plain();
        let challenge =
            client.rpc(json!({"cmd": "client-hello", "role": "main", "install_id": INSTALL}));
        let nonce = unhex::<NONCE_LEN>(challenge["data"]["nonce"].as_str().unwrap()).unwrap();
        let proof = hello_proof(&unhex::<32>(KEY_HEX).unwrap(), INSTALL, &nonce);
        let proved =
            client.rpc(json!({"cmd": "client-hello", "install_id": INSTALL, "proof": proof}));
        assert_eq!(proved["data"]["verified"], true, "{proved}");
        client
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.server("stop").arg("--end-terminals").output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

struct Client {
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Client {
    /// Starts this connection's daemon event stream (`subscribe`).
    fn stream(&mut self) {
        let reply = self.rpc(json!({"cmd":"subscribe"}));
        assert_eq!(reply["ok"], true, "{reply}");
    }

    /// The `cloud-*` events this connection's stream carried before the
    /// first `tree-changed` (the marker every stream gets, in mux order).
    fn cloud_events_before_marker(&mut self) -> Vec<Value> {
        let mut cloud = Vec::new();
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "the daemon closed");
            let value: Value = serde_json::from_str(&line).unwrap();
            match value["event"].as_str() {
                Some("tree-changed") => return cloud,
                Some(name) if name.starts_with("cloud-") => cloud.push(value),
                _ => {}
            }
        }
    }

    /// One request with a fresh id; event lines and other ids are skipped.
    fn rpc(&mut self, request: Value) -> Value {
        let id = self.next;
        self.next += 1;
        let mut body = request.as_object().cloned().unwrap();
        body.insert("id".into(), json!(id));
        writeln!(self.reader.get_mut(), "{}", Value::Object(body)).unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "the daemon closed");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("event").is_none() && value["id"] == id {
                return value;
            }
        }
    }
}

/// A loopback stand-in for the cmux Cloud API: answers every request with
/// one `dm.open` result and records the request bodies.
struct FakeCloud {
    base: String,
    bodies: Arc<Mutex<Vec<Value>>>,
}

impl FakeCloud {
    fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
        let bodies = Arc::new(Mutex::new(Vec::new()));
        let seen = bodies.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                let mut reader = BufReader::new(stream);
                let mut length = 0usize;
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 {
                        break;
                    }
                    let lower = line.to_ascii_lowercase();
                    if let Some(value) = lower.strip_prefix("content-length:") {
                        length = value.trim().parse().unwrap_or(0);
                    }
                    if line == "\r\n" {
                        break;
                    }
                }
                let mut body = vec![0; length];
                if reader.read_exact(&mut body).is_ok()
                    && let Ok(value) = serde_json::from_slice::<Value>(&body)
                {
                    seen.lock().unwrap().push(value);
                }
                let reply = json!({"ok":true,"op":"dm.open",
                    "value":{"conversation":{"id":"conv_dm_0123456789ABCDEFGHJKMNPQRS","owner":"cloud"}},
                    "revision":"1","transaction":"tx-dm","idempotency_key":"dm-1","replayed":false,
                    "stream":"conv:conv_dm_0123456789ABCDEFGHJKMNPQRS","sequence":1})
                .to_string();
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}",
                    reply.len()
                );
                let _ = reader.get_mut().write_all(response.as_bytes());
            }
        });
        Self { base, bodies }
    }

    fn bodies(&self) -> Vec<Value> {
        self.bodies.lock().unwrap().clone()
    }
}

fn set(base: &str, token: &str) -> Value {
    json!({"cmd":"cloud-session-set","api_base_url":base,"access_token":token,
           "expires_at":4_102_444_800_000_u64})
}

fn user_op(key: &str) -> Value {
    json!({"cmd":"cloud-conversation-op","idempotency_key":key,"origin":"user",
           "op":{"kind":"dm.open","peer":"user_00000000000000000002"}})
}

fn assert_forbidden(reply: &Value, what: &str) {
    assert_eq!(reply["ok"], false, "{what}: {reply}");
    assert_eq!(reply["error_code"], "cloud_conversation_rejected", "{what}: {reply}");
    assert_eq!(reply["reason"], "forbidden", "{what}: {reply}");
    assert_eq!(reply["retryable"], false, "{what}: {reply}");
    assert!(
        reply["error"].as_str().unwrap_or_default().contains("verified cmux app"),
        "{what}: {reply}"
    );
}

#[test]
fn cloud_lease_only_the_verified_app_sets_clears_and_speaks_as_the_user() {
    let daemon = Daemon::start("gate");
    let cloud = FakeCloud::start();
    let mut app = daemon.app();
    let mut plain = daemon.plain();

    let identity = plain.rpc(json!({"cmd":"identify"}));
    let capabilities = identity["data"]["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == "cloud-conversations-v1"), "{identity}");
    assert!(capabilities.iter().any(|value| value == "cloud-lease-app-only-v1"), "{identity}");

    // The app leases the human's session and sends as the user.
    let leased = app.rpc(set(&cloud.base, "app.jwt"));
    assert_eq!(leased["ok"], true, "{leased}");
    let sent = app.rpc(user_op("dm-1"));
    assert_eq!(sent["ok"], true, "{sent}");
    assert_eq!(cloud.bodies().len(), 1);
    assert_eq!(cloud.bodies()[0]["origin"], "user");

    // Another same-uid connection cannot replace, clear or speak for it.
    assert_forbidden(&plain.rpc(set("https://attacker.example", "other.jwt")), "set");
    assert_forbidden(&plain.rpc(json!({"cmd":"cloud-session-clear"})), "clear");
    assert_forbidden(&plain.rpc(user_op("dm-2")), "origin user");
    assert_eq!(cloud.bodies().len(), 1, "a refused op reaches no cloud");
    let status = plain.rpc(json!({"cmd":"cloud-session-status"}));
    assert_eq!(status["data"]["state"], "active", "{status}");
    assert_eq!(status["data"]["api_base_url"], cloud.base, "{status}");

    // The app clears its own lease.
    let cleared = app.rpc(json!({"cmd":"cloud-session-clear"}));
    assert_eq!(cleared["data"], json!({"state":"signed_out"}), "{cleared}");
}

#[test]
fn cloud_lease_other_connections_cannot_use_the_apps_lease() {
    let daemon = Daemon::start("use");
    let cloud = FakeCloud::start();
    let mut app = daemon.app();
    let mut plain = daemon.plain();
    let conv = "conv_0123456789ABCDEFGHJKMNPQRS";

    assert_eq!(app.rpc(set(&cloud.base, "app.jwt"))["ok"], true);
    for request in [
        json!({"cmd":"cloud-inbox-list"}),
        json!({"cmd":"cloud-conversation-snapshot","conversation":conv,"tail":5}),
        json!({"cmd":"cloud-conversation-history","conversation":conv,"before_seq":9,"limit":5}),
        json!({"cmd":"cloud-conversation-thread","conversation":conv,"root":"msg_00000000000000000000000001"}),
        json!({"cmd":"cloud-conversation-op","conversation":conv,"idempotency_key":"k","origin":"cli",
               "op":{"kind":"title.set","title":"t"}}),
        json!({"cmd":"cloud-inbox-subscribe"}),
        json!({"cmd":"cloud-conversation-subscribe","conversation":conv}),
        json!({"cmd":"cloud-mux-subscribe"}),
        json!({"cmd":"cloud-mux-ack","conversation":conv,"seq":1}),
    ] {
        assert_forbidden(&plain.rpc(request.clone()), &request.to_string());
    }
    assert!(cloud.bodies().is_empty(), "a refused command reaches no cloud: {:?}", cloud.bodies());

    // Status and the unsubscribes stay open: they use no lease.
    let status = plain.rpc(json!({"cmd":"cloud-session-status"}));
    assert_eq!(status["data"]["state"], "active", "{status}");
    for request in [
        json!({"cmd":"cloud-inbox-unsubscribe"}),
        json!({"cmd":"cloud-conversation-unsubscribe","conversation":conv}),
        json!({"cmd":"cloud-mux-unsubscribe"}),
    ] {
        let reply = plain.rpc(request.clone());
        assert_eq!(reply["ok"], true, "{request}: {reply}");
    }

    // Once the app signs out, the lease is no longer the app's.
    assert_eq!(app.rpc(json!({"cmd":"cloud-session-clear"}))["ok"], true);
    let signed_out = plain.rpc(json!({"cmd":"cloud-inbox-list"}));
    assert_eq!(signed_out["error_code"], "cloud_signed_out", "{signed_out}");
}

/// One `tree-changed` on every stream, after everything emitted before it.
fn marker(daemon: &Daemon) {
    let reply = daemon.plain().rpc(json!({"cmd":"new-workspace"}));
    assert_eq!(reply["ok"], true, "{reply}");
}

#[test]
fn cloud_events_of_the_apps_lease_reach_only_the_app() {
    // With the app's lease, a cloud event never reaches another connection's
    // event stream (an agent in a pane cannot read the human's DMs live).
    let daemon = Daemon::start("fanout");
    let cloud = FakeCloud::start();
    let mut app = daemon.app();
    let mut plain = daemon.plain();
    app.stream();
    plain.stream();
    assert_eq!(app.rpc(set(&cloud.base, "app.jwt"))["ok"], true);
    assert_eq!(app.rpc(json!({"cmd":"cloud-inbox-subscribe"}))["ok"], true);
    marker(&daemon);
    assert!(!app.cloud_events_before_marker().is_empty(), "the app gets its events");
    let leaked = plain.cloud_events_before_marker();
    assert!(leaked.is_empty(), "a plain connection got the app's cloud events: {leaked:?}");
}

#[test]
fn cloud_lease_another_clients_lease_is_never_the_apps_and_names_a_known_origin() {
    let daemon = Daemon::start("origin");
    let cloud = FakeCloud::start();
    let mut plain = daemon.plain();

    // Without the app, a lease must name a known cmux Cloud origin (or loopback).
    let unknown = plain.rpc(set("https://attacker.example", "other.jwt"));
    assert_eq!(unknown["ok"], false, "{unknown}");
    assert_eq!(unknown["reason"], "unknown_api_origin", "{unknown}");
    assert_eq!(plain.rpc(set("https://cloud-api-staging.cmux.dev", "other.jwt"))["ok"], true);
    assert_eq!(plain.rpc(set(&cloud.base, "other.jwt"))["ok"], true);

    // The app never uses a lease that another client set: it is signed out
    // until it leases its own session.
    let mut app = daemon.app();
    let status = app.rpc(json!({"cmd":"cloud-session-status"}));
    assert_eq!(status["data"]["state"], "signed_out", "{status}");
    let refused = app.rpc(json!({"cmd":"cloud-inbox-list"}));
    assert_eq!(refused["error_code"], "cloud_signed_out", "{refused}");
    assert!(
        cloud.bodies().is_empty(),
        "the app's request used the other lease: {:?}",
        cloud.bodies()
    );

    assert_eq!(app.rpc(set(&cloud.base, "app.jwt"))["ok"], true);
    let status = app.rpc(json!({"cmd":"cloud-session-status"}));
    assert_eq!(status["data"]["state"], "active", "{status}");
}

/// cx-59n8.17: the brain's `cloud-mux-ack` (optchat-chief brain/mux_ack.rs)
/// must reach the Worker as a valid op. The Worker's `origin` schema takes
/// only user, cli, mcp, script and remote (backend protocol schemas.ts), so
/// an ack sent with `origin: "agent"` was refused before the op ran.
#[test]
fn cloud_mux_ack_reaches_the_cloud_with_a_valid_origin() {
    const VALID: [&str; 5] = ["user", "cli", "mcp", "script", "remote"];
    let daemon = Daemon::start("muxack");
    let cloud = FakeCloud::start();
    // A headless brain's daemon: no app lease, the chief token (JWT `agt`) leased by the brain's connection.
    let mut brain = daemon.plain();
    let chief_token = "e30.eyJzdWIiOiJ1c2VyXzEiLCJhZ3QiOiJhZ2VudF9sZWFzZTEifQ.sig";
    assert_eq!(brain.rpc(set(&cloud.base, chief_token))["ok"], true);
    let conv = "conv_0123456789ABCDEFGHJKMNPQRS";
    brain.rpc(json!({"cmd":"cloud-mux-ack","conversation":conv,"seq":3}));
    let bodies = cloud.bodies();
    assert_eq!(bodies.len(), 1, "{bodies:?}");
    assert_eq!(bodies[0]["op"], "mux.ack", "{bodies:?}");
    assert_eq!(bodies[0]["params"], json!({"agent":"agent_lease1","conversation":conv,"seq":3}));
    let origin = bodies[0].get("origin").and_then(Value::as_str);
    assert!(origin.is_none_or(|o| VALID.contains(&o)), "invalid origin {origin:?} for mux.ack");
}
