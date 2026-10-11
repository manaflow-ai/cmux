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
        let challenge = client
            .rpc(json!({"cmd": "client-hello", "role": "main", "install_id": INSTALL}));
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
