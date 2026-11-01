//! Real native owners, a proved frontend, acpmux installation preparation,
//! a stand-in updater PTY and durable creation/exit receipts across restart.
#![cfg(unix)]

#[path = "../../acpmux/tests/support/daemon_env.rs"]
mod daemon_env;
mod journey_support;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

use acpmux::config::{Config, ProfileSources, StoreMode};
use acpmux::harness_health::Settings;
use acpmux::hub::Hub;
use cmux_tui_core::server::frontend_proof::{NONCE_LEN, hello_proof, unhex};
use journey_support::Machine;
use serde_json::{Value, json};
use tokio::task::JoinHandle;

// Test-only enrollment keys. No host credential store or existing key is read.
const INSTALL: &str = "inst_owner_job_journey";
const KEY: &str = "8f0e1d2c3b4a59687766554433221100ffeeddccbbaa99887766554433221100";

struct AcpmuxOwner {
    socket: PathBuf,
    cli: PathBuf,
    marker: PathBuf,
    task: JoinHandle<anyhow::Result<()>>,
}

impl AcpmuxOwner {
    async fn start(dir: &Path) -> Self {
        let home = dir.join("home");
        let real = home.join(".local/share/claude/versions/current");
        let cli = home.join(".local/bin/claude with 'quotes' and \u{03c0}");
        let marker = dir.join("argv-ran");
        fs::create_dir_all(real.parent().unwrap()).unwrap();
        fs::create_dir_all(cli.parent().unwrap()).unwrap();
        fs::write(
            &real,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$0\" \"$@\" >> {}\n[ \"$#\" = 1 ] && [ \"$1\" = update ] || exit 91\nprintf 'update failed with test status 23\\n'\nexit 23\n",
                acpmux::harness_health::channel::quote(marker.to_str().unwrap())
            ),
        )
        .unwrap();
        fs::set_permissions(&real, fs::Permissions::from_mode(0o755)).unwrap();
        symlink(&real, &cli).unwrap();
        let config = dir.join("hub.json");
        fs::write(&config, "{\"harnesses\":{}}").unwrap();
        let mut config = Config::load_from_with(&config, &ProfileSources::none()).unwrap();
        config.store.mode = StoreMode::Memory;
        // The cmux-tui binary installs acpmux's build id at start (main.rs); so
        // does this in-process hub, or it reports `unstamped`.
        acpmux::hub::install_build(acpmux_build_id::BUILD);
        let hub = Hub::new(config.clone(), acpmux::store::open(&config.store, dir).unwrap());
        let cache = dir.join("health.json");
        fs::write(
            &cache,
            json!([{"id":"work-profile", "program":"claude", "path":cli,
                "channel":"native", "package":"@anthropic-ai/claude-code",
                "version":"2.0.5", "latest":"2.0.9", "latestCheckedAt":1,
                "outdated":true, "auth":"unknown", "checkedAt":1,
                "authDetail":"private@example.test secret-token", "autoUpdate":true,
                "update":{"argv":[cli,"update"],"command":"private command","elevated":false}}])
            .to_string(),
        )
        .unwrap();
        let preferences = dir.join("auto.json");
        fs::write(&preferences, "[\"work-profile\"]").unwrap();
        hub.health.attach(Settings {
            cache: Some(cache),
            home,
            auto_update: Some(preferences),
            ..Settings::default()
        });
        let socket = dir.join("a.sock");
        let listener = acpmux::server::bind_unix(&socket).await.unwrap();
        let task = tokio::spawn(acpmux::server::serve_unix(hub, listener));
        Self { socket, cli, marker, task }
    }

    fn stop(&self) {
        self.task.abort();
        let _ = fs::remove_file(&self.socket);
    }
}

impl Drop for AcpmuxOwner {
    fn drop(&mut self) {
        self.stop();
    }
}

fn ensure(machine: &Machine) {
    let mut child = machine
        .server("ensure")
        .arg("--install-key-stdin")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(format!("cmuxik1 {INSTALL} {KEY}\n").as_bytes()).unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success(), "ensure: {}", String::from_utf8_lossy(&output.stderr));
}

fn native(root: &Path, name: &str, acpmux: &Path, state: Option<&Path>) -> Machine {
    let dir = root.join(name);
    fs::create_dir_all(dir.join("acpmux")).unwrap();
    fs::write(dir.join("acpmux/config.json"), "{\"harnesses\":{}}").unwrap();
    let mut machine = Machine {
        socket: dir.join("mux.sock"),
        session: format!("owner-job-{name}"),
        dir,
        env: vec![
            ("ACPMUX_SOCKET", acpmux.to_string_lossy().into_owned()),
            ("ACPMUX_CATALOG_FETCH", "0".into()),
            ("ACPMUX_HEALTH_FETCH", "0".into()),
            ("ACPMUX_REGISTRY_FETCH", "0".into()),
            ("ACPMUX_PROBE_HARNESSES", "".into()),
            ("CMUX_APPS_DEFAULT", "".into()),
        ],
    };
    if let Some(state) = state {
        machine.env.push(("CMUX_TUI_STATE_DIR", state.to_string_lossy().into_owned()));
    }
    ensure(&machine);
    machine
}

struct Client(BufReader<UnixStream>);

impl Client {
    fn connect(machine: &Machine) -> Self {
        let stream = UnixStream::connect(&machine.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        Self(BufReader::new(stream))
    }

    fn proved(machine: &Machine) -> Self {
        let mut client = Self::connect(machine);
        let hello = client.rpc(json!({"cmd":"client-hello","role":"main","install_id":INSTALL}));
        let nonce = unhex::<NONCE_LEN>(hello["data"]["nonce"].as_str().unwrap()).unwrap();
        let proof = hello_proof(&unhex::<32>(KEY).unwrap(), INSTALL, &nonce);
        let proved = client.rpc(json!({"cmd":"client-hello","install_id":INSTALL,"proof":proof}));
        assert_eq!(proved["data"]["verified"], true, "{proved}");
        assert_eq!(proved["data"]["user_origin_allowed"], true, "{proved}");
        client
    }

    fn rpc(&mut self, mut request: Value) -> Value {
        if request.get("id").is_none() {
            request["id"] = json!(1);
        }
        writeln!(self.0.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(self.0.read_line(&mut line).unwrap(), 0, "owner closed");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply.get("event").is_none() {
                return reply;
            }
        }
    }

    fn v2(
        &mut self,
        operation: &str,
        mut params: Value,
        machine: &Value,
        key: Option<&str>,
    ) -> Value {
        params["machine"] = machine.clone();
        params["session"] = json!("current");
        let mut request = json!({"protocol":"cmux.protocol/2","type":"request","id":"job-resource",
            "operation":operation,"params":params});
        if let Some(key) = key {
            request["idempotency_key"] = json!(key);
        }
        let reply = self.rpc(request);
        assert_eq!(reply["ok"], true, "{operation}: {reply}");
        reply["result"].clone()
    }
}

fn identity(machine: &Machine) -> Value {
    let reply = machine.rpc(json!({"id":1,"cmd":"identify","machine_metadata":true}));
    assert_eq!(reply["ok"], true, "{reply}");
    assert!(
        reply["data"]["capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!("agent-cli-update-job-v1"))
    );
    reply["data"].clone()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn cmux_next_agent_cli_job_journey_exec_exit_and_restart_replay_stay_on_owner() {
    let scratch = tempfile::Builder::new().prefix("cn-job-").tempdir_in("/tmp").unwrap();
    let root = scratch.path().canonicalize().unwrap();
    let selected_acp = AcpmuxOwner::start(&root.join("selected")).await;
    let other_acp = AcpmuxOwner::start(&root.join("other")).await;
    let selected = native(&root, "selected", &selected_acp.socket, None);
    let other = native(&root, "other", &other_acp.socket, None);
    let another_session =
        native(&root, "another-session", &other_acp.socket, Some(&selected.dir.join("state")));
    let selected_identity = identity(&selected);
    let machine = selected_identity["machine_id"].clone();
    let session = selected_identity["session_resource_id"].clone();
    assert!(session.as_str().is_some_and(|id| id.starts_with("session_") && id.len() == 40));
    let home_identity = identity(&other);
    assert_ne!(machine, home_identity["machine_id"]);
    let same_machine = identity(&another_session);
    assert_eq!(same_machine["machine_id"], machine);
    assert_ne!(same_machine["session_resource_id"], session);
    let intent = json!({"cmd":"agent-cli-update-job","expected_machine_id":machine,
        "expected_session_id":session,"cli":"claude","idempotency_key":"original-update-intent"});
    let unverified = Client::connect(&selected).rpc(intent.clone());
    assert_eq!(unverified["error_code"], "agent_cli_job.not_trusted", "{unverified}");
    let mut foreign = Client::proved(&other);
    assert_eq!(foreign.rpc(intent.clone())["error_code"], "agent_cli_job.owner_mismatch");
    let mut wrong_session = Client::proved(&another_session);
    assert_eq!(wrong_session.rpc(intent.clone())["error_code"], "agent_cli_job.session_mismatch");
    assert!(!selected_acp.marker.exists() && !other_acp.marker.exists());
    // A separate home daemon keeps the intent before the remote owner sees it.
    let ledger_request = |command: &str| {
        json!({"cmd":command,
        "expected_machine_id":home_identity["machine_id"],
        "expected_session_id":home_identity["session_resource_id"]})
    };
    let mut retained = ledger_request("agent-cli-intents-record");
    retained["intents"] = json!([{"key":"original-update-intent","root_key":"original-root",
        "machine":machine,"session":session,"cli":"claude","profiles":["work-profile"]}]);
    assert_eq!(foreign.rpc(retained)["ok"], true);
    let mut client = Client::proved(&selected);
    let mut commands = intent.clone();
    commands["argv"] = json!(["/bin/sh", "-c", "false"]);
    assert_eq!(client.rpc(commands)["error_code"], "agent_cli_job.bad_request");
    // Lose the creation reply with the client connection. Recovery only reads;
    // it must never submit the execution RPC to discover whether it happened.
    writeln!(client.0.get_mut(), "{intent}").unwrap();
    drop(client);
    let mut client = Client::proved(&selected);
    let mut lookup = intent.clone();
    lookup["cmd"] = json!("agent-cli-update-job-resolve");
    let until = Instant::now() + Duration::from_secs(20);
    let started = loop {
        let resolved = client.rpc(lookup.clone());
        assert_eq!(resolved["ok"], true, "{resolved}");
        if resolved["data"]["state"] == "created" {
            break json!({"data":resolved["data"]["receipt"]});
        }
        assert!(
            matches!(
                resolved["data"]["state"].as_str(),
                Some("not_found" | "prepared" | "pending")
            ),
            "{resolved}"
        );
        assert!(Instant::now() < until, "original job was not recoverable: {resolved}");
        std::thread::sleep(Duration::from_millis(2));
    };
    assert_eq!(started["data"]["machine"], machine);
    assert_eq!(started["data"]["session"], session);
    assert_eq!(started["data"]["replayed"], true);
    let mut attach = ledger_request("agent-cli-intents-attach");
    attach["key"] = json!("original-update-intent");
    attach["receipt"] = started["data"].clone();
    assert_eq!(foreign.rpc(attach)["ok"], true);
    assert!(!started.to_string().contains("secret-token"));
    let path = started["data"]["path"].clone();
    let terminal = path["terminal_id"].clone();
    let wait = json!({"terminal":terminal,"timeout_ms":"10000"});
    let exited = client.v2("terminal.wait_exit", wait.clone(), &machine, None);
    assert_eq!(exited["state"], "exited", "{exited}");
    assert_eq!(exited["outcome"], json!({"kind":"exit","code":23}));
    let lines = || {
        fs::read_to_string(&selected_acp.marker)
            .unwrap()
            .lines()
            .map(str::to_owned)
            .collect::<Vec<_>>()
    };
    assert_eq!(lines(), [selected_acp.cli.to_str().unwrap(), "update"]);
    let visible = client.v2("terminal.get", json!({"terminal":terminal}), &machine, None);
    assert!(
        !visible["tab_ids"].as_array().unwrap().is_empty(),
        "job view must remain after exit: {visible}"
    );
    client.v2(
        "workspace.close",
        json!({"workspace":path["workspace_id"]}),
        &machine,
        Some("close-job-view"),
    );
    selected_acp.stop();
    other_acp.stop();
    let replay = client.rpc(intent);
    assert_eq!(replay["ok"], true, "{replay}");
    assert_eq!(replay["data"]["path"], path);
    assert_eq!(replay["data"]["replayed"], true);
    let same_exit = client.v2("terminal.wait_exit", wait.clone(), &machine, None);
    assert_eq!(same_exit, exited);
    drop(client);
    let stopped = selected.server("stop").output().unwrap();
    assert!(stopped.status.success(), "stop: {}", String::from_utf8_lossy(&stopped.stderr));
    ensure(&selected);
    let restarted = identity(&selected);
    assert_eq!(restarted["machine_id"], machine, "restart must retain canonical owner");
    assert_eq!(restarted["session_resource_id"], session, "restart must retain canonical session");
    let mut reconnected = Client::proved(&selected);
    let resolution = reconnected.rpc(lookup);
    assert_eq!(resolution["ok"], true, "{resolution}");
    assert_eq!(resolution["data"]["state"], "created");
    let recovered = json!({"ok":true,"data":resolution["data"]["receipt"]});
    assert_eq!(recovered["ok"], true, "{recovered}");
    assert_eq!(recovered["data"]["path"], path);
    assert_eq!(recovered["data"]["replayed"], true);
    assert_eq!(reconnected.v2("terminal.wait_exit", wait, &machine, None), exited);
    assert_eq!(lines(), [selected_acp.cli.to_str().unwrap(), "update"], "replay must not rerun");
    assert!(!other_acp.marker.exists(), "another owner cannot satisfy the job");
    drop(foreign);
    assert!(other.server("stop").output().unwrap().status.success());
    ensure(&other);
    let mut home = Client::proved(&other);
    let restored = home.rpc(ledger_request("agent-cli-intents-list"));
    assert_eq!(restored["ok"], true, "{restored}");
    assert_eq!(restored["data"]["intents"][0]["key"], "original-update-intent");
    assert_eq!(restored["data"]["intents"][0]["machine"], machine);
    assert_eq!(restored["data"]["intents"][0]["session"], session);
    assert_eq!(restored["data"]["intents"][0]["receipt"]["path"], path);
    assert_eq!(
        lines(),
        [selected_acp.cli.to_str().unwrap(), "update"],
        "ledger recovery must not execute"
    );
    assert_eq!(fs::read_to_string(root.join("selected/auto.json")).unwrap(), "[\"work-profile\"]");
}
