//! `agent-session-start` (agent-session-start-v1) at the daemon's socket:
//! the host gate. A daemon on a team VM refuses the verb, a Cloud VM daemon
//! that cannot tell its kind refuses it, and any other host (an SSH machine,
//! this box) passes the gate and reaches the folder trust check.
//!
//! The host kind comes from the daemon's own identity at start, never from
//! the request. The test sets it from outside through the daemon's
//! environment (`CMUX_AGENT_START_HOST`), which can only make the daemon
//! stricter than what it detects.

use std::os::unix::net::UnixStream;

use serde_json::{Value, json};

use super::*;

#[path = "agent_chat_notices.rs"]
mod agent_chat_notices;

const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../acpmux/tests/fake_agent.py");

struct Daemon {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
    host_kind: Option<&'static str>,
}

impl Daemon {
    /// A machine whose acpmux has one harness, the test agent, as default.
    fn start(name: &str, host_kind: Option<&'static str>) -> Self {
        let config = json!({
            "harnesses": {"fake": {"argv": ["python3", FAKE_AGENT], "family": "fake"}},
            "defaultHarness": "fake",
        });
        Self::start_with(name, host_kind, Some(config))
    }

    /// With `acpmux_config`, the machine's acpmux runs that config.json.
    fn start_with(
        name: &str,
        host_kind: Option<&'static str>,
        acpmux_config: Option<Value>,
    ) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-asx-{name}-{}-{stamp}", std::process::id()));
        for sub in ["home", "acpmux", "work"] {
            fs::create_dir_all(dir.join(sub)).unwrap();
        }
        fs::set_permissions(dir.join("acpmux"), fs::Permissions::from_mode(0o700)).unwrap();
        if let Some(config) = acpmux_config {
            fs::write(dir.join("acpmux/config.json"), config.to_string()).unwrap();
        }
        let daemon =
            Self { socket: dir.join("mux.sock"), session: format!("asx-{name}"), dir, host_kind };
        let output = daemon.server("ensure").output().unwrap();
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
            .env("HOME", self.dir.join("home"))
            .env("ACPMUX_HOME", self.dir.join("acpmux"))
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env_remove("ACPMUX_SOCKET")
            .env_remove("CMUX_AGENT_START_HOST")
            .stdin(Stdio::null());
        if let Some(kind) = self.host_kind {
            command.env("CMUX_AGENT_START_HOST", kind);
        }
        command
    }

    fn rpc(&self, request: Value) -> Value {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        let mut reader = BufReader::new(stream);
        writeln!(reader.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(reader.read_line(&mut line).unwrap(), 0, "the daemon closed the connection");
            let message: Value = serde_json::from_str(&line).unwrap();
            if message.get("event").is_none() {
                return message;
            }
        }
    }

    /// A new agent tab whose record names this store as its host.
    fn own_agent_tab(&self) -> u64 {
        let identity = self.rpc(json!({"id": 1, "cmd": "identify"}));
        let session_id = identity["data"]["session_id"].as_str().unwrap().to_owned();
        let capabilities = identity["data"]["capabilities"].to_string();
        assert!(capabilities.contains("agent-session-start-v1"), "{identity}");
        assert_eq!(self.rpc(json!({"id": 2, "cmd": "new-workspace"}))["ok"], true);
        let tab = self.rpc(json!({"id": 3, "cmd": "new-conversation-tab",
                                   "agent_session": {"host": format!("registry:{session_id}")}}));
        assert_eq!(tab["ok"], true, "{tab}");
        tab["data"]["surface"].as_u64().unwrap()
    }

    fn start_chat(&self, surface: u64) -> Value {
        let work = self.dir.join("work");
        self.rpc(json!({"id": 4, "cmd": "agent-session-start", "surface": surface,
                        "cwd": work.to_str().unwrap()}))
    }

    fn start_chat_with(&self, surface: u64, harness: &str) -> Value {
        let work = self.dir.join("work");
        self.rpc(json!({"id": 5, "cmd": "agent-session-start", "surface": surface,
                        "harness": harness, "cwd": work.to_str().unwrap()}))
    }

    /// One call on this machine's acpmux unix socket (the local owner).
    fn acpmux_call(&self, method: &str, params: Value) -> Value {
        let stream = UnixStream::connect(self.dir.join("acpmux/acpmux.sock")).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        let mut reader = BufReader::new(stream);
        let request = json!({"jsonrpc": "2.0", "id": 7, "method": method, "params": params});
        writeln!(reader.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(reader.read_line(&mut line).unwrap(), 0, "acpmux closed the connection");
            let message: Value = serde_json::from_str(&line).unwrap();
            if message["id"] == 7 {
                return message;
            }
        }
    }

    /// How many sessions this machine's acpmux holds, asked on its own
    /// socket.
    fn acpmux_sessions(&self) -> usize {
        let stream = UnixStream::connect(self.dir.join("acpmux/acpmux.sock")).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        let mut reader = BufReader::new(stream);
        let request =
            json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/sessions", "params": {}});
        writeln!(reader.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(reader.read_line(&mut line).unwrap(), 0, "acpmux closed the connection");
            let message: Value = serde_json::from_str(&line).unwrap();
            if message["id"] == 1 {
                let result = &message["result"];
                let sessions = result.get("sessions").unwrap_or(result);
                return sessions.as_array().map_or(0, Vec::len);
            }
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.server("stop").arg("--end-terminals").output();
        let _ = Command::new(bin())
            .args(["acp", "daemon", "shutdown"])
            .env("HOME", self.dir.join("home"))
            .env("ACPMUX_HOME", self.dir.join("acpmux"))
            .output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn agent_session_start_is_refused_on_a_team_vm() {
    let daemon = Daemon::start("team", Some("team-vm"));
    let surface = daemon.own_agent_tab();
    let reply = daemon.start_chat(surface);
    assert_eq!(reply["error_code"], "agent_session.team_vm_blocked", "{reply}");
}

#[test]
fn agent_session_start_is_refused_on_a_cloud_vm_of_unknown_kind() {
    let daemon = Daemon::start("unknown", Some("unknown-cloud"));
    let surface = daemon.own_agent_tab();
    let reply = daemon.start_chat(surface);
    assert_eq!(reply["error_code"], "agent_session.host_unverified", "{reply}");
}

#[test]
fn agent_session_start_passes_the_host_gate_on_an_ssh_host() {
    let daemon = Daemon::start("ssh", None);
    let surface = daemon.own_agent_tab();
    // Past the host gate the next check is the folder's trust, which no one
    // answered for this new folder.
    let reply = daemon.start_chat(surface);
    assert_eq!(reply["error_code"], "agent_session.untrusted_folder", "{reply}");
}

#[test]
fn an_unknown_host_kind_value_keeps_the_detected_kind() {
    // An unknown value is no kind: the daemon keeps what it detects (here:
    // not a Cloud VM, so the gate passes).
    let daemon = Daemon::start("relax", Some("owner"));
    let surface = daemon.own_agent_tab();
    let reply = daemon.start_chat(surface);
    assert_eq!(reply["error_code"], "agent_session.untrusted_folder", "{reply}");
}

/// A harness of a refused family under another name (and as the default
/// harness) is refused from acpmux's catalog before any agent starts.
#[test]
fn agent_session_start_refuses_a_codex_alias_before_any_agent_starts() {
    let config = json!({
        "harnesses": {"fcx": {"argv": ["python3", FAKE_AGENT], "family": "codex"}},
        "defaultHarness": "fcx",
    });
    let daemon = Daemon::start_with("alias", None, Some(config));
    let surface = daemon.own_agent_tab();
    let named = daemon.start_chat_with(surface, "fcx");
    assert_eq!(named["error_code"], "agent_session.not_asking", "{named}");
    let default = daemon.start_chat(surface);
    assert_eq!(default["error_code"], "agent_session.not_asking", "{default}");
    assert_eq!(daemon.acpmux_sessions(), 0, "an agent started before the family check");
}

/// A session never leaves its machine (cx-k21v): a tab whose record names
/// this store (`registry:<id>`) gets its session only from this machine's
/// own agent-session-start. A client's bind of any session into it, and a
/// new such tab that already names a session (a Mac's chat placed into a
/// tab of this machine), are refused with a typed error.
#[test]
fn a_machine_tab_binds_no_session_from_another_machine() {
    let daemon = Daemon::start("mismatch", None);
    let surface = daemon.own_agent_tab();
    let bind = daemon.rpc(json!({"id": 6, "cmd": "bind-conversation-tab-session",
                                 "surface": surface, "session": "mac-session-1",
                                 "expected_session": null}));
    assert_eq!(bind["ok"], false, "{bind}");
    assert_eq!(bind["error_code"], "conversation_tab.machine_mismatch", "{bind}");
    let identity = daemon.rpc(json!({"id": 7, "cmd": "identify"}));
    let session_id = identity["data"]["session_id"].as_str().unwrap().to_owned();
    let placed = daemon.rpc(json!({"id": 8, "cmd": "new-conversation-tab",
                                   "agent_session": {"host": format!("registry:{session_id}"),
                                                     "session": "mac-session-1"}}));
    assert_eq!(placed["ok"], false, "{placed}");
    assert_eq!(placed["error_code"], "conversation_tab.machine_mismatch", "{placed}");
    // A tab of another install (a Mac's chat shown here) still binds as before.
    let mac_tab = daemon.rpc(json!({"id": 9, "cmd": "new-conversation-tab",
                                    "agent_session": {"host": "install:mac-test"}}));
    let mac_surface = mac_tab["data"]["surface"].as_u64().unwrap();
    let mac_bind = daemon.rpc(json!({"id": 10, "cmd": "bind-conversation-tab-session",
                                     "surface": mac_surface, "session": "mac-session-1",
                                     "expected_session": null}));
    assert_eq!(mac_bind["ok"], true, "{mac_bind}");
}

/// The sample harness (`cmux harness add sample`, cx-00p) starts remotely
/// with policy ask (cx-k21v slice C): acpmux knows it from its profile, its
/// one mode "ask" is an asking mode by the machine's `webAskingModes`, and
/// once the person trusted the folder the start answers a session.
#[test]
fn agent_session_start_starts_the_sample_harness_in_its_asking_mode() {
    let config = json!({
        "harnesses": {"sample": {"argv": ["env", "FAKE_ASK_MODE=1", "python3", FAKE_AGENT],
                                 "family": "sample"}},
        "defaultHarness": "sample",
        "webAskingModes": {"sample": ["ask"]},
    });
    let daemon = Daemon::start_with("sample", None, Some(config));
    let surface = daemon.own_agent_tab();
    // The folder's trust is the person's: the first start brings acpmux up and is refused.
    let untrusted = daemon.start_chat_with(surface, "sample");
    assert_eq!(untrusted["error_code"], "agent_session.untrusted_folder", "{untrusted}");
    let work = daemon.dir.join("work");
    let trust = daemon.acpmux_call("acp.trust.set", json!({"cwd": work, "level": "trusted"}));
    assert!(trust.get("error").is_none(), "{trust}");
    let started = daemon.start_chat_with(surface, "sample");
    assert_eq!(started["ok"], true, "{started}");
    assert!(started["data"]["session"].as_str().is_some_and(|s| !s.is_empty()), "{started}");
    assert_eq!(daemon.acpmux_sessions(), 1, "{started}");
}
