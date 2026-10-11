//! P8 slice 3b-2: the app hands its install key to the daemon it starts.
//! `server ensure --install-key-stdin` reads the key from stdin (never argv
//! or env) and passes it to the owner it spawns on an inherited pipe; a
//! connection then proves itself with `client-hello`.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cmux_tui_core::server::frontend_proof::{NONCE_LEN, hello_proof, unhex};
use serde_json::{Value, json};

const KEY_HEX: &str = "8f0e1d2c3b4a59687766554433221100ffeeddccbbaa99887766554433221100";
const OTHER_KEY_HEX: &str = "1111111111111111111111111111111111111111111111111111111111111111";

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-ik-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        Self { socket: dir.join("mux.sock"), session: format!("ik-{name}"), dir }
    }

    fn command(&self, action: &str) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"));
        command
    }

    /// `server ensure --install-key-stdin` with `payload` on stdin.
    fn ensure_with_key(&self, payload: &str) -> Output {
        let mut child = self
            .command("ensure")
            .arg("--install-key-stdin")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(payload.as_bytes()).unwrap();
        child.wait_with_output().unwrap()
    }

    fn connect(&self) -> Client {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(12))).unwrap();
        Client(BufReader::new(stream))
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.command("stop").output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

struct Client(BufReader<UnixStream>);

impl Client {
    fn rpc(&mut self, value: Value) -> Value {
        writeln!(self.0.get_mut(), "{value}").unwrap();
        let mut line = String::new();
        assert_ne!(self.0.read_line(&mut line).unwrap(), 0);
        serde_json::from_str(&line).unwrap()
    }

    /// The two-step hello; returns the last reply.
    fn hello(&mut self, install_id: &str, key_hex: &str) -> Value {
        let challenge = self.rpc(
            json!({ "id": 1, "cmd": "client-hello", "role": "main", "install_id": install_id }),
        );
        let Some(nonce) = challenge["data"]["nonce"].as_str() else { return challenge };
        let nonce = unhex::<NONCE_LEN>(nonce).unwrap();
        let key = unhex::<32>(key_hex).unwrap();
        let proof = hello_proof(&key, install_id, &nonce);
        self.rpc(
            json!({ "id": 2, "cmd": "client-hello", "install_id": install_id, "proof": proof }),
        )
    }
}

fn success(output: &Output) -> Value {
    assert!(
        output.status.success(),
        "ensure failed: {:?}\nstdout: {}\nstderr: {}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

fn owner_command_line(pid: u64) -> String {
    let output =
        Command::new("ps").args(["-o", "command=", "-p", &pid.to_string()]).output().unwrap();
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

#[test]
fn the_spawned_owner_holds_the_key_and_a_running_owner_never_takes_another() {
    let fixture = Fixture::new("handoff");
    let started = success(&fixture.ensure_with_key(&format!("cmuxik1 inst_app {KEY_HEX}\n")));
    assert_eq!(started["status"], "started", "{started}");
    let command_line = owner_command_line(started["pid"].as_u64().unwrap());
    assert!(command_line.contains("--owner-install-key-fd"), "{command_line}");
    assert!(
        !command_line.contains(KEY_HEX) && !command_line.contains("inst_app"),
        "{command_line}"
    );

    let proved = fixture.connect().hello("inst_app", KEY_HEX);
    assert_eq!(proved["data"]["verified"], true, "{proved}");
    assert_ne!(fixture.connect().hello("inst_app", OTHER_KEY_HEX)["ok"], true);

    // A later ensure finds the owner running; its key never reaches it.
    let again = success(&fixture.ensure_with_key(&format!("cmuxik1 inst_other {OTHER_KEY_HEX}\n")));
    assert_eq!(again["status"], "running", "{again}");
    assert_eq!(
        fixture.connect().hello("inst_other", OTHER_KEY_HEX)["error_code"],
        "client_hello.refused"
    );
    assert_eq!(fixture.connect().hello("inst_app", KEY_HEX)["data"]["verified"], true);
}

#[test]
fn an_owner_started_without_a_key_has_none() {
    let fixture = Fixture::new("nokey");
    let output = fixture.command("ensure").output().unwrap();
    assert_eq!(success(&output)["status"], "started");
    let refused = fixture.connect().hello("inst_app", KEY_HEX);
    assert_eq!(refused["error_code"], "client_hello.refused", "{refused}");
}

#[test]
fn a_malformed_key_starts_nothing() {
    let fixture = Fixture::new("badkey");
    let bare_key = format!("{KEY_HEX}\n");
    for payload in ["", "cmuxik1 inst_app abc\n", bare_key.as_str()] {
        let output = fixture.ensure_with_key(payload);
        assert!(!output.status.success(), "ensure accepted {payload:?}");
        let reply: Value = serde_json::from_slice(&output.stdout).unwrap_or(Value::Null);
        assert!(
            reply.to_string().contains("server.install_key_invalid")
                || String::from_utf8_lossy(&output.stderr).contains("install_key_invalid"),
            "stdout {} stderr {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert_ne!(fixture.command("status").output().unwrap().status.code(), Some(0));
    }
}
