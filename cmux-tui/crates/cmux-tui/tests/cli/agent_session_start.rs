//! `agent-session-start` (agent-session-start-v1) at the daemon's socket:
//! the host gate. A daemon on a team VM refuses the verb, a Cloud VM daemon
//! that cannot tell its kind refuses it, and any other host (an SSH machine,
//! this box) passes the gate and reaches the folder trust check.
//!
//! The host kind comes from the daemon's own identity at start, never from
//! the request. The test sets it from outside through the daemon's
//! environment (`CMUX_AGENT_START_HOST`), which can only make the daemon
//! stricter than what it detects.

use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc;

use serde_json::{Value, json};

use super::*;

#[path = "agent_chat_notices.rs"]
mod agent_chat_notices;
#[path = "agent_focus_cli.rs"]
mod agent_focus_cli;
#[path = "agent_home_reopen.rs"]
mod agent_home_reopen;
#[path = "agent_input_hint.rs"]
mod agent_input_hint;
#[path = "agents_chat_tools.rs"]
mod agents_chat_tools;
#[path = "agents_cli_receipt.rs"]
mod agents_cli_receipt;
#[path = "agents_events_cli.rs"]
mod agents_events_cli;
#[path = "agents_wait_cli.rs"]
mod agents_wait_cli;

const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../acpmux/tests/fake_agent.py");
/// The app's install key, so one connection can prove itself the verified
/// cmux app (it mints a page's gesture confirmations).
const KEY_HEX: &str = "7e0d1c2b3a4958677665544332211000ffeeddccbbaa99887766554433221101";
const INSTALL_ID: &str = "inst_agent_trust";

struct Daemon {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
    host_kind: Option<&'static str>,
    /// A Cloud VM's records (debug-only `CMUX_TEST_CLOUD_ETC`).
    cloud_etc: Option<PathBuf>,
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
        Self::start_in(name, host_kind, acpmux_config, None)
    }

    /// A Cloud VM (an image stamp) whose own `vm-kind` record reads `kind`.
    fn start_cloud(name: &str, kind: &str) -> Self {
        let config = json!({
            "harnesses": {"fake": {"argv": ["python3", FAKE_AGENT], "family": "fake"}},
            "defaultHarness": "fake",
        });
        Self::start_in(name, None, Some(config), Some(kind))
    }

    fn start_in(
        name: &str,
        host_kind: Option<&'static str>,
        acpmux_config: Option<Value>,
        vm_kind: Option<&str>,
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
        let cloud_etc = vm_kind.map(|kind| {
            let etc = dir.join("etc-cmux");
            fs::create_dir_all(&etc).unwrap();
            fs::set_permissions(&etc, fs::Permissions::from_mode(0o755)).unwrap();
            for (file, text) in
                [("image-stamp", "test\n".to_owned()), ("vm-kind", format!("{kind}\n"))]
            {
                fs::write(etc.join(file), text).unwrap();
                fs::set_permissions(etc.join(file), fs::Permissions::from_mode(0o644)).unwrap();
            }
            etc
        });
        let daemon = Self {
            socket: dir.join("mux.sock"),
            session: format!("asx-{name}"),
            dir,
            host_kind,
            cloud_etc,
        };
        let mut child = daemon
            .server("ensure")
            .arg("--install-key-stdin")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let key = format!("cmuxik1 {INSTALL_ID} {KEY_HEX}\n");
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
            .env("HOME", self.dir.join("home"))
            .env("ACPMUX_HOME", self.dir.join("acpmux"))
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env_remove("ACPMUX_SOCKET")
            .env_remove("CMUX_AGENT_START_HOST")
            .env_remove("CMUX_TEST_CLOUD_ETC")
            .env_remove("CMUX_VM_ID")
            .stdin(Stdio::null());
        if let Some(kind) = self.host_kind {
            command.env("CMUX_AGENT_START_HOST", kind);
        }
        if let Some(etc) = &self.cloud_etc {
            command.env("CMUX_TEST_CLOUD_ETC", etc);
        }
        command
    }

    /// A connection that stays open (hello state lives on it).
    fn client(&self) -> Conn {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        Conn { reader: BufReader::new(stream), next: 100 }
    }

    /// The verified cmux app connection (install-key hello).
    fn verified_app(&self) -> Conn {
        use cmux_tui_core::server::frontend_proof::{NONCE_LEN, hello_proof, unhex};
        let mut app = self.client();
        let challenge =
            app.rpc(json!({"cmd": "client-hello", "role": "main", "install_id": INSTALL_ID}));
        let nonce = unhex::<NONCE_LEN>(challenge["data"]["nonce"].as_str().unwrap()).unwrap();
        let proof = hello_proof(&unhex::<32>(KEY_HEX).unwrap(), INSTALL_ID, &nonce);
        let proved =
            app.rpc(json!({"cmd": "client-hello", "install_id": INSTALL_ID, "proof": proof}));
        assert_eq!(proved["data"]["verified"], true, "{proved}");
        app
    }

    /// A page relay of `page` and its connection id.
    fn page_relay(&self, page: &str) -> (Conn, String) {
        let mut relay = self.client();
        let hello = relay.rpc(json!({"cmd": "client-hello", "role": "page_relay", "page": page}));
        let id = hello["data"]["connection_id"].as_str().unwrap().to_owned();
        (relay, id)
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

    /// A start with the caller's `vm_kind` (the Cloud API's answer it read).
    fn start_chat_as(&self, surface: u64, vm_kind: impl Into<Value>) -> Value {
        let work = self.dir.join("work");
        self.rpc(json!({"id": 6, "cmd": "agent-session-start", "surface": surface,
                        "cwd": work.to_str().unwrap(), "vm_kind": vm_kind.into()}))
    }

    fn start_chat_with(&self, surface: u64, harness: &str) -> Value {
        let work = self.dir.join("work");
        self.rpc(json!({"id": 5, "cmd": "agent-session-start", "surface": surface,
                        "harness": harness, "cwd": work.to_str().unwrap()}))
    }

    fn start_chat_with_model(&self, surface: u64, harness: &str, model: &str) -> Value {
        let work = self.dir.join("work");
        self.rpc(json!({"id": 8, "cmd": "agent-session-start", "surface": surface,
                        "harness": harness, "model": model, "cwd": work.to_str().unwrap()}))
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

struct Conn {
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Conn {
    /// Sends `request` with a fresh id and returns the reply with that id.
    fn rpc(&mut self, mut request: Value) -> Value {
        self.next += 1;
        request["id"] = json!(self.next);
        self.send(&request, json!(self.next))
    }

    /// A `cmux.protocol/2` request as a page host sends it (selectors
    /// `current`); `extra` adds envelope members.
    fn v2(&mut self, operation: &str, params: &Value, extra: Value) -> Value {
        self.next += 1;
        let id = format!("v2-{}", self.next);
        let mut request = json!({"protocol": "cmux.protocol/2", "type": "request", "id": id,
                                 "operation": operation, "params": params});
        for (key, value) in extra.as_object().unwrap() {
            request[key] = value.clone();
        }
        self.send(&request, json!(id))
    }

    fn send(&mut self, request: &Value, id: Value) -> Value {
        writeln!(self.reader.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "the daemon closed");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == id {
                return reply;
            }
        }
    }
}

/// The SHA-256 of `params` in canonical JSON (keys sorted), as the daemon
/// hashes a confirmed request.
fn params_digest(params: &Value) -> String {
    use sha2::Digest;
    let sorted: std::collections::BTreeMap<String, Value> =
        params.as_object().unwrap().iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    let digest = sha2::Sha256::digest(serde_json::to_string(&sorted).unwrap().as_bytes());
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.server("stop").arg("--end-terminals").output();
        let _ = Command::new(bin())
            .args(["acp", "daemon", "shutdown", "--end-agents"])
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

/// The guest's own `owner` record never allows a start on a Cloud VM (its
/// agents keep sudo): only the caller's `vm_kind: "owner"`, the Cloud API's
/// answer for it, does. On a team VM that word is the creator's (the Cloud
/// API gives it to nobody else), so it goes on there too; any other word or
/// none is still `team_vm_blocked`. A machine that is not a Cloud VM needs no
/// word.
#[test]
fn a_cloud_vm_start_needs_the_callers_owner_word_not_the_vms_record() {
    let owner = Daemon::start_cloud("vmowner", "owner");
    let surface = owner.own_agent_tab();
    let reply = owner.start_chat(surface);
    assert_eq!(reply["error_code"], "agent_session.host_unverified", "{reply}");
    for other in ["team", "Owner", "", "owner "] {
        let reply = owner.start_chat_as(surface, other);
        assert_eq!(reply["error_code"], "agent_session.host_unverified", "{other:?}: {reply}");
    }
    // Past the host gate the next check is the folder's trust.
    let reply = owner.start_chat_as(surface, "owner");
    assert_eq!(reply["error_code"], "agent_session.untrusted_folder", "{reply}");

    let team = Daemon::start_cloud("vmteam", "team");
    let surface = team.own_agent_tab();
    // The creator's word: past the host gate, the next check is the folder's trust.
    let reply = team.start_chat_as(surface, "owner");
    assert_eq!(reply["error_code"], "agent_session.untrusted_folder", "{reply}");
    let reply = team.start_chat(surface);
    assert_eq!(reply["error_code"], "agent_session.team_vm_blocked", "{reply}");
    let reply = team.start_chat_as(surface, "team");
    assert_eq!(reply["error_code"], "agent_session.team_vm_blocked", "{reply}");

    let ssh = Daemon::start("vmssh", None);
    let surface = ssh.own_agent_tab();
    let reply = ssh.start_chat_as(surface, "owner");
    assert_eq!(reply["error_code"], "agent_session.untrusted_folder", "{reply}");
    // A machine whose root removed every Cloud sign still reads as a Cloud VM
    // when the caller says so: only `owner` goes on.
    let reply = ssh.start_chat_as(surface, "team");
    assert_eq!(reply["error_code"], "agent_session.host_unverified", "{reply}");
    // An explicit null is a word, and not `owner`: refused like any other.
    let reply = ssh.start_chat_as(surface, Value::Null);
    assert_eq!(reply["error_code"], "agent_session.host_unverified", "{reply}");
    let identity = owner.rpc(json!({"id": 1, "cmd": "identify"}));
    let capabilities = identity["data"]["capabilities"].to_string();
    assert!(capabilities.contains("agent-session-start-vm-kind-v1"), "{identity}");
}

/// Folder trust on a Cloud VM takes the start's rule: only the caller's
/// `vm_kind: "owner"` reaches it, never the VM's own record; on a team VM
/// that word is the creator's and reaches it too. A page cannot vouch for the Cloud API's
/// answer, so its routed operations never reach a Cloud VM's trust.
#[test]
fn agent_session_trust_on_a_cloud_vm_needs_the_callers_owner_word() {
    // `kind` null leaves the param out.
    let trust = |daemon: &Daemon, surface: u64, kind: Value| {
        let cwd = daemon.dir.join("work");
        let mut request =
            json!({"id": 30, "cmd": "agent-session-trust", "surface": surface, "cwd": cwd});
        if !kind.is_null() {
            request["vm_kind"] = kind;
        }
        daemon.rpc(request)
    };
    let owner = Daemon::start_cloud("trustvm", "owner");
    let surface = owner.own_agent_tab();
    for kind in [json!(null), json!("team"), json!("Owner")] {
        let reply = trust(&owner, surface, kind);
        assert_eq!(reply["error_code"], "agent_session.host_unverified", "{reply}");
    }
    let read = trust(&owner, surface, json!("owner"));
    assert_eq!(read["ok"], true, "{read}");
    let identity = owner.rpc(json!({"id": 31, "cmd": "identify"}));
    let capabilities = identity["data"]["capabilities"].to_string();
    assert!(capabilities.contains("agent-session-trust-vm-kind-v1"), "{identity}");
    assert!(capabilities.contains("agent-transfer-vm-kind-v1"), "{identity}");
    assert!(capabilities.contains("agent-transfer-continues-v1"), "{identity}");
    let cwd = owner.dir.join("work").to_str().unwrap().to_owned();
    let read = json!({"surface": surface, "cwd": cwd, "machine": "current", "session": "current"});
    let (mut page, _) = owner.page_relay("agent");
    let got = page.v2("agent_session.trust.get", &read, json!({}));
    assert_eq!(got["error"]["details"]["extra"]["code"], "agent_session.host_unverified", "{got}");
    let mut vouched = read.clone();
    vouched["vm_kind"] = json!("owner");
    let got = page.v2("agent_session.trust.get", &vouched, json!({}));
    assert_eq!(got["error"]["details"]["extra"]["code"], "agent_session.bad_request", "{got}");

    let team = Daemon::start_cloud("trustteam", "team");
    let surface = team.own_agent_tab();
    for kind in [json!(null), json!("team")] {
        let reply = trust(&team, surface, kind);
        assert_eq!(reply["error_code"], "agent_session.team_vm_blocked", "{reply}");
    }
    // The creator's word (the Cloud API's owner answer) reaches the trust read.
    let read = trust(&team, surface, json!("owner"));
    assert_eq!(read["ok"], true, "{read}");

    // A machine that shows no Cloud sign (its root may have removed them):
    // a word that is not `owner`, an explicit `null` included, refuses.
    let plain = Daemon::start("trustplain", None);
    let surface = plain.own_agent_tab();
    let cwd = plain.dir.join("work");
    for kind in [json!(null), json!("team")] {
        let request = json!({"id": 32, "cmd": "agent-session-trust", "surface": surface,
                             "cwd": cwd, "vm_kind": kind});
        let reply = plain.rpc(request);
        assert_eq!(reply["error_code"], "agent_session.host_unverified", "{kind}: {reply}");
    }
    let read = trust(&plain, surface, Value::Null);
    assert_eq!(read["ok"], true, "{read}");
}

/// Leo: "whenever i start a chat it should be able to send me to cloud
/// automatically". On the caller's own Cloud VM (the owner word; on a team VM
/// the creator's) a new chat with no folder of the person's own, which the
/// app sends as the workspace's first terminal folder (`$HOME` on a new
/// machine), starts in the machine's work folder, and that work folder reads
/// trusted with no question. A person's "Don't trust" still wins, and a
/// machine that is not a Cloud VM keeps the home folder rule.
#[test]
fn a_first_chat_on_the_callers_own_cloud_vm_starts_in_its_trusted_work_folder() {
    let start_at_home = |daemon: &Daemon, surface: u64| {
        let home = daemon.dir.join("home");
        daemon.rpc(json!({"id": 40, "cmd": "agent-session-start", "surface": surface,
                          "cwd": home.to_str().unwrap(), "vm_kind": "owner"}))
    };
    for kind in ["owner", "team"] {
        let vm = Daemon::start_cloud(&format!("ownwork{kind}"), kind);
        let work = vm.dir.join("home/work");
        let surface = vm.own_agent_tab();
        // The trust read the app's page asks before a send: no question for the work folder.
        fs::create_dir_all(&work).unwrap();
        let read = vm.rpc(json!({"id": 41, "cmd": "agent-session-trust", "surface": surface,
                                 "cwd": work.to_str().unwrap(), "vm_kind": "owner"}));
        assert_eq!(read["data"]["level"], "trusted", "{kind}: {read}");
        assert_eq!(read["data"]["auto"], "cloud_work", "{kind}: {read}");
        // Without the owner word nothing is read (the machine kind gate).
        let read = vm.rpc(json!({"id": 42, "cmd": "agent-session-trust", "surface": surface,
                                 "cwd": work.to_str().unwrap()}));
        assert_eq!(read["ok"], false, "{kind}: {read}");
        fs::remove_dir(&work).unwrap();
        // The start at the home folder runs in the work folder (made for it), with no question.
        let started = start_at_home(&vm, surface);
        if kind == "owner" {
            assert_eq!(started["ok"], true, "{kind}: {started}");
        } else {
            // Past the folder and its trust; a team VM then runs only an agent that asks
            // before acting (#28613), which the test agent has no mode for.
            assert_eq!(started["error_code"], "agent_session.not_asking", "{kind}: {started}");
        }
        assert!(work.is_dir(), "{kind}: the work folder was not made");
        // Another folder of that machine still asks.
        let surface = vm.own_agent_tab();
        let reply = vm.start_chat_as(surface, "owner");
        assert_eq!(reply["error_code"], "agent_session.untrusted_folder", "{kind}: {reply}");
    }

    // The person's "Don't trust" for the work folder wins over the rule.
    let vm = Daemon::start_cloud("ownworknot", "owner");
    let work = vm.dir.join("home/work");
    fs::create_dir_all(&work).unwrap();
    let surface = vm.own_agent_tab();
    let set = vm.rpc(json!({"id": 43, "cmd": "agent-session-trust", "surface": surface,
                            "cwd": work.to_str().unwrap(), "level": "untrusted", "vm_kind": "owner"}));
    assert_eq!(set["ok"], true, "{set}");
    let reply = start_at_home(&vm, surface);
    assert_eq!(reply["error_code"], "agent_session.untrusted_folder", "{reply}");

    // Not a Cloud VM: the home folder still needs Use Home Folder.
    let plain = Daemon::start("ownworkplain", None);
    let surface = plain.own_agent_tab();
    let reply = start_at_home(&plain, surface);
    assert_eq!(reply["error_code"], "agent_session.home_unconfirmed", "{reply}");
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

/// On the caller's own Cloud VM (its `vm_kind: "owner"`, the Cloud API's
/// answer) a Codex or opencode chat starts: that VM is the person's own
/// disposable sandbox. The same harness stays refused without the word, on
/// an SSH host (not a sandbox of theirs) and on a team VM.
#[test]
fn agent_session_start_starts_codex_on_the_callers_own_cloud_vm_only() {
    let config = json!({
        "harnesses": {
            "fcx": {"argv": ["python3", FAKE_AGENT], "family": "codex"},
            "fop": {"argv": ["python3", FAKE_AGENT], "family": "opencode"},
        },
        "defaultHarness": "fcx",
    });
    let start = |daemon: &Daemon, surface: u64, harness: &str, kind: Option<&str>| {
        let work = daemon.dir.join("work");
        let mut request = json!({"id": 40, "cmd": "agent-session-start", "surface": surface,
                                 "harness": harness, "cwd": work.to_str().unwrap()});
        if let Some(kind) = kind {
            request["vm_kind"] = json!(kind);
        }
        daemon.rpc(request)
    };
    let trust = |daemon: &Daemon| {
        let work = daemon.dir.join("work");
        let set = daemon.acpmux_call("acp.trust.set", json!({"cwd": work, "level": "trusted"}));
        assert!(set.get("error").is_none(), "{set}");
    };

    let owner = Daemon::start_in("cxowner", None, Some(config.clone()), Some("owner"));
    let identity = owner.rpc(json!({"id": 1, "cmd": "identify"}));
    let capabilities = identity["data"]["capabilities"].to_string();
    assert!(capabilities.contains("agent-session-start-owner-cloud-v1"), "{identity}");
    let surface = owner.own_agent_tab();
    let refused = start(&owner, surface, "fcx", None);
    assert_eq!(refused["error_code"], "agent_session.host_unverified", "{refused}");
    // The first start brings acpmux up; the folder's trust is the person's.
    let untrusted = start(&owner, surface, "fcx", Some("owner"));
    assert_eq!(untrusted["error_code"], "agent_session.untrusted_folder", "{untrusted}");
    trust(&owner);
    let started = start(&owner, surface, "fcx", Some("owner"));
    assert_eq!(started["ok"], true, "{started}");
    assert!(started["data"]["session"].as_str().is_some_and(|s| !s.is_empty()), "{started}");
    let opencode_tab = owner.own_agent_tab();
    let started = start(&owner, opencode_tab, "fop", Some("owner"));
    assert_eq!(started["ok"], true, "{started}");
    assert_eq!(owner.acpmux_sessions(), 2, "{started}");

    // Not a Cloud VM: the caller's word does not make a Mac or SSH host a sandbox.
    let ssh = Daemon::start_with("cxssh", None, Some(config.clone()));
    let identity = ssh.rpc(json!({"id": 2, "cmd": "identify"}));
    let capabilities = identity["data"]["capabilities"].to_string();
    assert!(!capabilities.contains("agent-session-start-owner-cloud-v1"), "{identity}");
    let surface = ssh.own_agent_tab();
    let refused = start(&ssh, surface, "fcx", Some("owner"));
    assert_eq!(refused["error_code"], "agent_session.not_asking", "{refused}");
    let refused = start(&ssh, surface, "fop", Some("owner"));
    assert_eq!(refused["error_code"], "agent_session.not_asking", "{refused}");
    assert_eq!(ssh.acpmux_sessions(), 0, "an agent started on an SSH host");

    let team = Daemon::start_in("cxteam", None, Some(config), Some("team"));
    let identity = team.rpc(json!({"id": 3, "cmd": "identify"}));
    let capabilities = identity["data"]["capabilities"].to_string();
    assert!(!capabilities.contains("agent-session-start-owner-cloud-v1"), "{identity}");
    let surface = team.own_agent_tab();
    let refused = start(&team, surface, "fcx", None);
    assert_eq!(refused["error_code"], "agent_session.team_vm_blocked", "{refused}");
    // The creator's owner word takes a team VM's chat (#29107), but only one that asks first.
    let refused = start(&team, surface, "fcx", Some("owner"));
    assert_eq!(refused["error_code"], "agent_session.not_asking", "{refused}");
    let refused = start(&team, surface, "fop", Some("owner"));
    assert_eq!(refused["error_code"], "agent_session.not_asking", "{refused}");
    assert_eq!(team.acpmux_sessions(), 0, "an agent started on a team VM");
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

/// An acpmux stand-in on the machine's socket that answers a start's calls
/// with a trusted folder and an asking session, and hands every `session/new`
/// params it receives to the test.
fn fake_acpmux(socket: PathBuf) -> mpsc::Receiver<Value> {
    let listener = UnixListener::bind(&socket).unwrap();
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            let sender = sender.clone();
            std::thread::spawn(move || {
                let mut writer = stream.try_clone().unwrap();
                for line in BufReader::new(stream).lines() {
                    let Ok(line) = line else { return };
                    let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
                    let Some(id) = message.get("id").cloned() else { continue };
                    let params = &message["params"];
                    let modes = json!({"refusedFamilies": [], "families": {"fake": ["ask"]}});
                    let result = match message["method"].as_str().unwrap_or_default() {
                        "_acpmux/web_modes" if params.get("sessionId").is_some() => json!({
                            "refusedFamilies": [], "families": {"fake": ["ask"]},
                            "session": {"family": "fake", "mode": "ask"},
                        }),
                        "_acpmux/web_modes" => modes,
                        "_acpmux/harnesses" => {
                            json!({"defaultHarness": "fake", "families": {"fake": {}}})
                        }
                        "acp.trust.get" => {
                            json!({"cwd": params["cwd"], "decided": true, "level": "trusted"})
                        }
                        "session/new" => {
                            let _ = sender.send(params.clone());
                            json!({"sessionId": "fake-session-1"})
                        }
                        _ => json!({}),
                    };
                    let reply = json!({"jsonrpc": "2.0", "id": id, "result": result});
                    if writeln!(writer, "{reply}").is_err() {
                        return;
                    }
                }
            });
        }
    });
    receiver
}

/// The agent of a chat started on this machine works in the workspace of
/// its tab (cx-ncc.5): the daemon names that workspace to acpmux on
/// `session/new` (`_meta.acpmux.workspaceId`, which picks the session's
/// display), with no session env. The client never names it.
#[test]
fn agent_session_start_sends_the_tab_workspace_to_acpmux() {
    let daemon = Daemon::start_with("wsid", None, None);
    let new_sessions = fake_acpmux(daemon.dir.join("acpmux/acpmux.sock"));
    let identity = daemon.rpc(json!({"id": 1, "cmd": "identify"}));
    let session_id = identity["data"]["session_id"].as_str().unwrap().to_owned();
    let workspace = daemon.rpc(json!({"id": 2, "cmd": "create-workspace", "name": "wsid"}));
    assert_eq!(workspace["ok"], true, "{workspace}");
    let key = workspace["data"]["key"].as_str().unwrap().to_owned();
    let tab = daemon.rpc(json!({"id": 3, "cmd": "new-conversation-tab",
                               "workspace": workspace["data"]["workspace"],
                               "agent_session": {"host": format!("registry:{session_id}")}}));
    assert_eq!(tab["ok"], true, "{tab}");
    let surface = tab["data"]["surface"].as_u64().unwrap();
    let started = daemon.start_chat(surface);
    assert_eq!(started["ok"], true, "{started}");
    let new = new_sessions.recv_timeout(Duration::from_secs(5)).unwrap();
    let acpmux = &new["_meta"]["acpmux"];
    assert_eq!(acpmux["workspaceId"], json!(key), "{new}");
    assert_eq!(acpmux.get("env"), None, "{new}");
    assert_eq!(acpmux["policy"], "ask", "{new}");
    let _ = fs::remove_file(daemon.dir.join("acpmux/acpmux.sock"));
}

/// The optional model chosen by `cmux agent new-chat --model` reaches the remote
/// machine's first `session/new`, while the daemon still validates the folder and
/// keeps the model behind its additive capability.
#[test]
fn agent_session_start_relays_the_requested_model() {
    let daemon = Daemon::start_with("model", None, None);
    let new_sessions = fake_acpmux(daemon.dir.join("acpmux/acpmux.sock"));
    let surface = daemon.own_agent_tab();
    let started = daemon.start_chat_with_model(surface, "fake", "model-x");
    assert_eq!(started["ok"], true, "{started}");
    let new = new_sessions.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(new["_meta"]["acpmux"]["model"], "model-x", "{new}");
    assert!(new["cwd"].as_str().unwrap().ends_with("/work"), "{new}");
    let _ = fs::remove_file(daemon.dir.join("acpmux/acpmux.sock"));
}

/// The person answers the folder trust question of a chat of this machine
/// from the app (cx-1bhjj): `agent-session-trust` reads the folder's trust
/// on this machine and records the person's Trust in its acpmux, and the
/// start that was refused for the untrusted folder then runs. Only an agent
/// tab of this store and only acpmux's three levels are taken.
#[test]
fn agent_session_trust_records_the_persons_answer_and_the_start_runs() {
    let config = json!({
        "harnesses": {"sample": {"argv": ["env", "FAKE_ASK_MODE=1", "python3", FAKE_AGENT],
                                 "family": "sample"}},
        "defaultHarness": "sample",
        "webAskingModes": {"sample": ["ask"]},
    });
    let daemon = Daemon::start_with("trust", None, Some(config));
    let surface = daemon.own_agent_tab();
    let identity = daemon.rpc(json!({"id": 10, "cmd": "identify"}));
    assert!(identity["data"]["capabilities"].to_string().contains("agent-session-trust-v1"));
    let untrusted = daemon.start_chat_with(surface, "sample");
    assert_eq!(untrusted["error_code"], "agent_session.untrusted_folder", "{untrusted}");
    let work = daemon.dir.join("work");
    let cwd = work.to_str().unwrap();
    let trust = |id: u64, extra: Value| {
        let mut request = json!({"id": id, "cmd": "agent-session-trust", "surface": surface,
                                 "cwd": cwd});
        request.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        daemon.rpc(request)
    };
    let read = trust(11, json!({}));
    assert_eq!(read["ok"], true, "{read}");
    assert_ne!(read["data"]["level"], "trusted", "{read}");
    let bad = trust(12, json!({"level": "always"}));
    assert_eq!(bad["error_code"], "agent_session.bad_request", "{bad}");
    let other = daemon.rpc(json!({"id": 13, "cmd": "agent-session-trust", "surface": 999_999,
                                  "cwd": cwd, "level": "trusted"}));
    assert_eq!(other["error_code"], "agent_session.unknown_tab", "{other}");
    // One click never trusts a whole home folder: `/` and the folders above the home folder
    // never, the home folder only once the person chose it as the chat's folder.
    let home = daemon.dir.join("home");
    let above = daemon.rpc(json!({"id": 16, "cmd": "agent-session-trust", "surface": surface,
                                  "cwd": "/", "level": "trusted"}));
    assert_eq!(above["error_code"], "agent_session.above_home", "{above}");
    let home_click = daemon.rpc(json!({"id": 17, "cmd": "agent-session-trust", "surface": surface,
                                       "cwd": home, "level": "trusted"}));
    assert_eq!(home_click["error_code"], "agent_session.home_unconfirmed", "{home_click}");
    let home_chosen = daemon
        .rpc(json!({"id": 18, "cmd": "agent-session-trust", "surface": surface,
                                        "cwd": home, "level": "trusted", "home_confirmed": true}));
    assert_eq!(home_chosen["ok"], true, "{home_chosen}");
    // A chat starts in the home folder only with the person's choice of it, trusted or not.
    let home_start = daemon.rpc(json!({"id": 19, "cmd": "agent-session-start", "surface": surface,
                                       "harness": "sample", "cwd": home}));
    assert_eq!(home_start["error_code"], "agent_session.home_unconfirmed", "{home_start}");
    let set = trust(14, json!({"level": "trusted"}));
    assert_eq!(set["ok"], true, "{set}");
    let again = trust(15, json!({}));
    assert_eq!(again["data"]["level"], "trusted", "{again}");
    let started = daemon.start_chat_with(surface, "sample");
    assert_eq!(started["ok"], true, "{started}");
    assert_eq!(daemon.acpmux_sessions(), 1, "{started}");
}

/// hq-6d: pages reach the folder trust only as the routed operations of
/// page `agent` (the agent pane and its New Tab page). Another page is
/// refused even the read (the trust state tells a page which folders the
/// person works in), a page relay cannot send the legacy line, and the
/// answer needs the person's gesture, a confirmation the DAEMON checks for
/// exactly that request; it is spent once.
#[test]
fn only_the_agent_page_reads_folder_trust_and_its_answer_needs_the_persons_gesture() {
    let config = json!({
        "harnesses": {"sample": {"argv": ["env", "FAKE_ASK_MODE=1", "python3", FAKE_AGENT],
                                 "family": "sample"}},
        "defaultHarness": "sample",
        "webAskingModes": {"sample": ["ask"]},
    });
    let daemon = Daemon::start_with("page", None, Some(config));
    let surface = daemon.own_agent_tab();
    let cwd = daemon.dir.join("work").to_str().unwrap().to_owned();
    let read = json!({"surface": surface, "cwd": cwd, "machine": "current", "session": "current"});
    let (mut history, _) = daemon.page_relay("history");
    let refused = history.v2("agent_session.trust.get", &read, json!({}));
    assert_eq!(refused["error"]["code"], "origin.forbidden", "{refused}");
    assert_eq!(refused["error"]["details"]["reason"], "page_not_allowed", "{refused}");
    let (mut page, relay_id) = daemon.page_relay("agent");
    let legacy = page.rpc(json!({"cmd": "agent-session-trust", "surface": surface, "cwd": cwd}));
    assert_eq!(legacy["error_code"], "origin.forbidden", "{legacy}");
    let got = page.v2("agent_session.trust.get", &read, json!({}));
    assert_eq!(got["ok"], true, "{got}");
    assert_ne!(got["result"]["level"], "trusted", "{got}");
    let mut set = read.clone();
    set["level"] = json!("trusted");
    let bare = page.v2("agent_session.trust.set", &set, json!({"idempotency_key": "t1"}));
    assert_eq!(bare["error"]["details"]["reason"], "gesture_required", "{bare}");
    // Forgetting the answer (`unknown`) is an answer too: it needs the gesture.
    let mut forget = read.clone();
    forget["level"] = json!("unknown");
    let forget = page.v2("agent_session.trust.set", &forget, json!({"idempotency_key": "t0"}));
    assert_eq!(forget["error"]["details"]["reason"], "gesture_required", "{forget}");
    // A page cannot prove the person chose the home folder: it never sends home_confirmed.
    let mut home = set.clone();
    home["home_confirmed"] = json!(true);
    let home = page.v2("agent_session.trust.get", &home, json!({}));
    assert_eq!(home["error"]["details"]["extra"]["code"], "agent_session.bad_request", "{home}");
    let mut read_level = read.clone();
    read_level["level"] = json!("trusted");
    let bad = page.v2("agent_session.trust.get", &read_level, json!({}));
    assert_eq!(bad["error"]["details"]["extra"]["code"], "agent_session.bad_request", "{bad}");
    // The person's gesture: the verified app mints a confirmation for exactly this request.
    let mut app = daemon.verified_app();
    let issued = app.v2(
        "origin.confirmation.issue",
        &json!({"operation": "agent_session.trust.set", "params_sha256": params_digest(&set),
                "relay_connection_id": relay_id, "machine": "current", "session": "current"}),
        json!({}),
    );
    assert_eq!(issued["ok"], true, "{issued}");
    let token = issued["result"]["token"].as_str().unwrap().to_owned();
    let confirmed =
        json!({"idempotency_key": "t2", "origin": {"claim": "user", "confirmation": token}});
    let answered = page.v2("agent_session.trust.set", &set, confirmed.clone());
    assert_eq!(answered["ok"], true, "{answered}");
    assert_eq!(answered["result"]["level"], "trusted", "{answered}");
    let replayed = page.v2("agent_session.trust.set", &set, confirmed);
    assert_eq!(replayed["error"]["code"], "origin.forbidden", "{replayed}");
    let mut other = read.clone();
    other["surface"] = json!(999_999);
    let unknown = page.v2("agent_session.trust.get", &other, json!({}));
    assert_eq!(
        unknown["error"]["details"]["extra"]["code"], "agent_session.unknown_tab",
        "{unknown}"
    );
}

/// A person key as `acp daemon start --person-key-fd 0` reads it (test value).
const PERSON_KEY_HEX: &str = "5a0d1c2b3a4958677665544332211000ffeeddccbbaa99887766554433221109";

impl Daemon {
    /// `agent-session-start` as an app that signs relayed allows sends it
    /// (cx-0w0jj): it needs a person key for `instance` in acpmux.
    fn keyed_start(&self, surface: u64, instance: Option<&str>) -> Value {
        let work = self.dir.join("work");
        let mut request = json!({"id": 30, "cmd": "agent-session-start", "surface": surface,
                                 "cwd": work.to_str().unwrap(), "require_person_key": true});
        if let Some(instance) = instance {
            request["person_instance"] = json!(instance);
        }
        self.rpc(request)
    }

    fn acpmux_status(&self) -> Value {
        self.acpmux_call("_acpmux/status", json!({}))["result"].clone()
    }

    /// Polls this machine's acpmux status until `done` holds (bounded).
    fn acpmux_status_until(&self, done: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let status = self.acpmux_status();
            if done(&status) || Instant::now() > deadline {
                return status;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}

/// The typed refusal of a start that needs this app's person key: its code
/// and the facts the daemon read; never a run id or any key material.
fn needs_keyed_start(reply: &Value, safe: bool, live: u64, remote: u64) {
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error_code"], "agent_session.needs_keyed_start", "{reply}");
    assert_eq!(
        reply["data"],
        json!({"reason": "needs_keyed_start", "safe_to_restart": safe,
               "live_agents": live, "remote_sessions": remote}),
        "{reply}"
    );
    assert!(!reply.to_string().contains(PERSON_KEY_HEX), "{reply}");
}

/// cx-0w0jj (hq-6d): the daemon decides whether a keyed restart of its
/// acpmux can lose nothing. No key and acpmux down or idle: safe, and the
/// check never starts an acpmux without a key; no key and a live agent: not
/// safe. A start without `require_person_key` runs as before.
#[test]
fn a_start_that_needs_the_person_key_says_whether_a_restart_is_safe() {
    let config = json!({
        "harnesses": {"sample": {"argv": ["env", "FAKE_ASK_MODE=1", "python3", FAKE_AGENT],
                                 "family": "sample"}},
        "defaultHarness": "sample",
        "webAskingModes": {"sample": ["ask"]},
    });
    let daemon = Daemon::start_with("keyed", None, Some(config));
    let surface = daemon.own_agent_tab();
    let identity = daemon.rpc(json!({"id": 20, "cmd": "identify"}));
    let capabilities = identity["data"]["capabilities"].to_string();
    assert!(capabilities.contains("agent-session-start-keyed-reason-v1"), "{identity}");
    let socket = daemon.dir.join("acpmux/acpmux.sock");
    // acpmux does not run: safe, and the check leaves it down.
    needs_keyed_start(&daemon.keyed_start(surface, None), true, 0, 0);
    assert!(UnixStream::connect(&socket).is_err(), "the keyed check started acpmux");
    // A plain start brings acpmux up without a key (the folder is not trusted yet).
    let untrusted = daemon.start_chat(surface);
    assert_eq!(untrusted["error_code"], "agent_session.untrusted_folder", "{untrusted}");
    let status = daemon.acpmux_status_until(|status| status["ready"] == true);
    assert_eq!(status["personKey"], false, "{status}");
    let idle = daemon.keyed_start(surface, Some("not-this-run"));
    needs_keyed_start(&idle, true, 0, 0);
    let instance = status["personInstance"].as_str().unwrap();
    assert!(!idle.to_string().contains(instance), "{idle}");
    // A live agent: not safe.
    let work = daemon.dir.join("work");
    let trust = daemon.acpmux_call("acp.trust.set", json!({"cwd": work, "level": "trusted"}));
    assert!(trust.get("error").is_none(), "{trust}");
    let started = daemon.start_chat(surface);
    assert_eq!(started["ok"], true, "{started}");
    let status = daemon.acpmux_status_until(|status| status["liveAgents"] == 1);
    assert_eq!(status["liveAgents"], 1, "{status}");
    let other = daemon.own_agent_tab();
    needs_keyed_start(&daemon.keyed_start(other, None), false, 1, 0);
}

/// cx-0w0jj: a session proxied from a peer acpmux makes a keyed restart
/// unsafe too (a restart would end the peer link the person uses).
#[test]
fn a_peer_session_makes_the_keyed_restart_unsafe() {
    let daemon = Daemon::start("keyedpeer", None);
    let surface = daemon.own_agent_tab();
    // The peer: a second acpmux of the same user with one session, on a loopback listener.
    let peer_home = daemon.dir.join("peer");
    fs::create_dir_all(&peer_home).unwrap();
    fs::set_permissions(&peer_home, fs::Permissions::from_mode(0o700)).unwrap();
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let configured = "p".repeat(32);
    let config = json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE_AGENT], "family": "fake"}},
        "defaultHarness": "fake",
        "websocket": {"listen": format!("127.0.0.1:{port}"), "token": configured},
    });
    fs::write(peer_home.join("config.json"), config.to_string()).unwrap();
    let peer = PeerAcpmux { home: daemon.dir.join("home"), acpmux: peer_home.clone() };
    let up = peer.command(&["acp", "--json", "daemon", "start"]).output().unwrap();
    assert!(up.status.success(), "{}", String::from_utf8_lossy(&up.stderr));
    // The peer's dashboard token as the daemon reports it (its web URL).
    let peer_status = peer.call("_acpmux/status", json!({}));
    let web_url = peer_status["result"]["webUrl"].as_str().expect("the peer's web URL").to_owned();
    let token = web_url.split("token=").nth(1).expect("a token in the web URL").to_owned();
    let listen = peer_status["result"]["listen"].as_str().expect("the peer's listen").to_owned();
    let work = daemon.dir.join("work");
    let created = peer.call("session/new", json!({"cwd": work, "mcpServers": []}));
    assert!(created["result"]["sessionId"].is_string(), "{created}");
    // This machine's acpmux, up without a key, mirrors the peer's session.
    let untrusted = daemon.start_chat(surface);
    assert_eq!(untrusted["error_code"], "agent_session.untrusted_folder", "{untrusted}");
    let peer_token = fs::read_to_string(peer_home.join("run/peer.token")).unwrap();
    let added = daemon.acpmux_call(
        "_acpmux/peer_add",
        json!({"name": "other", "url": format!("ws://{listen}"), "token": token,
               "peerToken": peer_token.trim(), "wait": true}),
    );
    assert!(added.get("error").is_none(), "{added}");
    let status = daemon.acpmux_status_until(|status| status["remoteSessions"] == 1);
    assert_eq!(status["remoteSessions"], 1, "{status}");
    assert_eq!(status["liveAgents"], 0, "{status}");
    needs_keyed_start(&daemon.keyed_start(surface, None), false, 0, 1);
}

/// cx-0w0jj: a caller that holds the key of the running acpmux passes the
/// keyed check (the start goes on to the folder trust check); the same
/// daemon run named wrongly, or not at all, is refused, and the refusal
/// names neither the run nor the key.
#[test]
fn a_keyed_caller_passes_the_keyed_check() {
    let daemon = Daemon::start("keyedok", None);
    let surface = daemon.own_agent_tab();
    let acpmux = PeerAcpmux { home: daemon.dir.join("home"), acpmux: daemon.dir.join("acpmux") };
    let mut child = acpmux
        .command(&["acp", "--json", "daemon", "start", "--person-key-fd", "0"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(format!("{PERSON_KEY_HEX}\n").as_bytes()).unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let status = daemon.acpmux_status_until(|status| status["ready"] == true);
    assert_eq!(status["personKey"], true, "{status}");
    let instance = status["personInstance"].as_str().unwrap().to_owned();
    let passed = daemon.keyed_start(surface, Some(&instance));
    assert_eq!(passed["error_code"], "agent_session.untrusted_folder", "{passed}");
    let wrong = daemon.keyed_start(surface, Some("another-run"));
    needs_keyed_start(&wrong, true, 0, 0);
    let unnamed = daemon.keyed_start(surface, None);
    needs_keyed_start(&unnamed, true, 0, 0);
    assert!(!wrong.to_string().contains(&instance), "{wrong}");
    // A bad run id is a bad request.
    let bad = daemon.keyed_start(surface, Some("no spaces"));
    assert_eq!(bad["error_code"], "agent_session.bad_request", "{bad}");
}

/// An acpmux of this test's user other than the daemon's own (a peer), or
/// the daemon's own acpmux driven through the CLI; stopped on drop.
struct PeerAcpmux {
    home: PathBuf,
    acpmux: PathBuf,
}

impl PeerAcpmux {
    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(bin());
        command
            .args(args)
            .env("HOME", &self.home)
            .env("ACPMUX_HOME", &self.acpmux)
            .env_remove("ACPMUX_SOCKET")
            .stdin(Stdio::null());
        command
    }

    fn call(&self, method: &str, params: Value) -> Value {
        let stream = UnixStream::connect(self.acpmux.join("acpmux.sock")).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        let mut reader = BufReader::new(stream);
        let request = json!({"jsonrpc": "2.0", "id": 9, "method": method, "params": params});
        writeln!(reader.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(reader.read_line(&mut line).unwrap(), 0, "acpmux closed the connection");
            let message: Value = serde_json::from_str(&line).unwrap();
            if message["id"] == 9 {
                return message;
            }
        }
    }
}

impl Drop for PeerAcpmux {
    fn drop(&mut self) {
        let _ = self.command(&["acp", "daemon", "shutdown", "--end-agents"]).output();
    }
}
