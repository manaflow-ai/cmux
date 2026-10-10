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

struct Daemon {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
    host_kind: Option<&'static str>,
}

impl Daemon {
    fn start(name: &str, host_kind: Option<&'static str>) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-asx-{name}-{}-{stamp}", std::process::id()));
        for sub in ["home", "acpmux", "work"] {
            fs::create_dir_all(dir.join(sub)).unwrap();
        }
        fs::set_permissions(dir.join("acpmux"), fs::Permissions::from_mode(0o700)).unwrap();
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
