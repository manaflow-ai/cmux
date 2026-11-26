//! Codex is the in-process bridge (`codex app-server`, `codex_app_server.rs`)
//! when codex is installed; the ACP adapter stays as `codex-acp`. The user's
//! configuration still decides: the profile's or family's `CODEX_PATH` is the
//! codex binary the bridge runs, and a family `prefer` list picks the profile.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{ConnAuth, Origin, serve_connection_authed};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
use tokio::sync::mpsc;

const FAKE_APP_SERVER: &str =
    concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_codex_app_server.py");
const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("acc-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::create_dir_all(d.join("bin")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

/// An executable `name` in `d/bin` that runs `script` with its arguments.
fn shim(d: &Path, name: &str, script: &str) -> PathBuf {
    let path = d.join("bin").join(name);
    std::fs::write(
        &path,
        format!("#!/bin/sh\nexec python3 {} \"$@\"\n", daemon_env::sh_quote(script)),
    )
    .unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn hub_with(cfg: Value) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    /// The daemon's own socket (the CLI's proof: the owner-only file).
    fn local(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(
            hub.clone(),
            in_rx,
            out_tx,
            Origin::Local,
            ConnAuth::LocalSocket,
        ));
        Client(in_tx, out_rx, 0)
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("an answer in time")
                .expect("the connection stays open");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }
}

/// A new session on `head` (a profile or a family) and its harness.
async fn harness_of_new(c: &mut Client, d: &Path, head: &str) -> (String, String) {
    let r = c.call("session/new", json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": head}}})).await;
    let s = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    let list = c.call("_acpmux/sessions", json!({})).await;
    let harness = list["result"]["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["sessionId"] == s.as_str())
        .and_then(|x| x["harness"].as_str())
        .unwrap()
        .to_owned();
    (s, harness)
}

#[tokio::test]
async fn the_bridge_runs_the_codex_path_the_family_configures() {
    let d = dir("path");
    let custom = shim(&d, "cmux-codex", FAKE_APP_SERVER);
    // The profile names a codex that does not exist: only CODEX_PATH can make it run.
    let hub = hub_with(json!({
        "harnesses": {"codex": {"argv": [d.join("bin").join("missing").join("codex"), "app-server"]}},
        "defaults": {"codex": {"env": {"CODEX_PATH": custom}}},
        "defaultHarness": "codex",
        "permissionPolicy": "ask",
    }));
    let mut c = Client::local(&hub);
    let (s, harness) = harness_of_new(&mut c, &d, "codex").await;
    assert_eq!(harness, "codex");
    let r = c
        .call("session/prompt", json!({"sessionId": s, "prompt": [{"type": "text", "text": "hi"}]}))
        .await;
    assert_eq!(r["result"]["stopReason"], "end_turn", "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// A chat's Codex starts with its agent-thread limits lifted (Leo
/// 2026-10-14, no caps on subagents): `-c` overrides before `app-server`,
/// so a new chat has them without a restart. A key the profile's command
/// line sets keeps the profile's value.
#[tokio::test]
async fn a_chat_starts_codex_with_its_agent_limits_lifted_unless_the_profile_sets_one() {
    let d = dir("limits");
    let codex = shim(&d, "codex", FAKE_APP_SERVER);
    let recorded = d.join("args.json");
    // An empty codex home: the machine's own codex config is not the test's.
    let home = d.join("codex-home");
    std::fs::create_dir_all(&home).unwrap();
    let hub = hub_with(json!({
        "harnesses": {"codex": {
            "argv": [codex, "-c", "agents.max_depth=2", "app-server"],
            "env": {"FAKE_CODEX_ARGS": recorded, "CODEX_HOME": home},
        }},
        "defaultHarness": "codex",
        "permissionPolicy": "ask",
    }));
    let mut c = Client::local(&hub);
    let (s, _) = harness_of_new(&mut c, &d, "codex").await;
    let r = c
        .call("session/prompt", json!({"sessionId": s, "prompt": [{"type": "text", "text": "hi"}]}))
        .await;
    assert_eq!(r["result"]["stopReason"], "end_turn", "{r}");
    // Each start of the app-server, the chat's among them (a model probe
    // may start one too).
    let starts: Vec<Value> = std::fs::read_to_string(&recorded)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let lifted = json!([
        "-c",
        "agents.max_concurrent_threads_per_session=1000",
        "-c",
        "tools.update_plan.enabled=false",
        "-c",
        "agents.max_depth=2",
        "app-server"
    ]);
    assert!(starts.iter().map(without_rules).any(|s| s == lifted), "{starts:?}");
    // The chat's own start carries cmux's rules as Codex's developer instructions.
    assert!(
        starts.iter().any(|s| s.to_string().contains(acpmux::agent_tools::CONCURRENT_WORK_RULE)),
        "{starts:?}"
    );
    // Every override, the rules included, before the subcommand: none after it, or a codex that
    // drops the root ones then would lose the limits and a launcher's own (cmux#48354).
    assert!(!starts.iter().any(config_after_subcommand), "{starts:?}");

    // A key the project's codex config sets wins too.
    let project = d.join("project");
    std::fs::create_dir_all(project.join(".codex")).unwrap();
    std::fs::create_dir_all(project.join("work")).unwrap();
    std::fs::write(
        project.join(".codex/config.toml"),
        "[agents]\nmax_concurrent_threads_per_session = 3\n",
    )
    .unwrap();
    let recorded = d.join("project-args.json");
    let hub = hub_with(json!({
        "harnesses": {"codex": {
            "argv": [codex, "app-server"],
            "env": {"FAKE_CODEX_ARGS": recorded, "CODEX_HOME": home},
        }},
        "defaultHarness": "codex",
        "permissionPolicy": "ask",
    }));
    let mut c = Client::local(&hub);
    let (s, _) = harness_of_new(&mut c, &project, "codex").await;
    let r = c
        .call("session/prompt", json!({"sessionId": s, "prompt": [{"type": "text", "text": "hi"}]}))
        .await;
    assert_eq!(r["result"]["stopReason"], "end_turn", "{r}");
    let starts: Vec<Value> = std::fs::read_to_string(&recorded)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let lifted =
        json!(["-c", "agents.max_depth=16", "-c", "tools.update_plan.enabled=false", "app-server"]);
    assert!(starts.iter().map(without_rules).any(|s| s == lifted), "{starts:?}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Every `app-server` start recorded in `recorded` once a chat answered a prompt (other codex
/// runs the fake records, such as an `mcp get` check, are left out).
async fn starts_of_a_chat(hub: &Arc<Hub>, d: &Path, recorded: &Path) -> Vec<Value> {
    let mut c = Client::local(hub);
    let (s, _) = harness_of_new(&mut c, d, "codex").await;
    let r = c
        .call(
            "session/prompt",
            json!({"sessionId": s, "prompt": [{"type": "text", "text": "1+1"}]}),
        )
        .await;
    assert_eq!(r["result"]["stopReason"], "end_turn", "{r}");
    std::fs::read_to_string(recorded)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str::<Value>(l).unwrap())
        .map(|s| without_rules(&s))
        .filter(|s| s.as_array().is_some_and(|w| w.iter().any(|a| a == "app-server")))
        .collect()
}

/// A GUI chat's Codex starts with the model codex's config.toml names on its command line
/// (cmux#48354), as `codex` in a terminal does: a launcher that routes by `-m` (a subrouter
/// wrapper installed as `codex`) otherwise sent the model, which the chat only names later over
/// the protocol, to the plain provider, and the turn failed with 400 `model_not_found`. The active
/// codex profile's model wins over the top-level one; a model the profile's command line names
/// is kept and never doubled.
#[tokio::test]
async fn a_chat_starts_codex_with_the_configured_model_on_its_command_line() {
    let d = dir("model-argv");
    let codex = shim(&d, "codex", FAKE_APP_SERVER);
    let home = d.join("codex-home");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(
        home.join("config.toml"),
        "model = \"gpt-6.2-sol\"\nmodel_reasoning_effort = \"high\"\n",
    )
    .unwrap();
    let hub_on = |argv: Vec<Value>, recorded: &Path| {
        hub_with(json!({
            "harnesses": {"codex": {
                "argv": argv,
                "env": {"FAKE_CODEX_ARGS": recorded, "CODEX_HOME": home},
            }},
            "defaultHarness": "codex",
            "permissionPolicy": "ask",
        }))
    };
    let first_model = |start: &Value| -> Option<String> {
        let words = start.as_array()?;
        (words.first()? == "-m").then(|| words.get(1)?.as_str().map(str::to_owned)).flatten()
    };

    // The config's model, first, before acpmux's overrides and the subcommand.
    let recorded = d.join("config-args.json");
    let hub = hub_on(vec![json!(codex), json!("app-server")], &recorded);
    let starts = starts_of_a_chat(&hub, &d, &recorded).await;
    // Each start of the app-server, the chat's among them (a model probe, which has no chat,
    // may start one too, without acpmux's launch arguments).
    let chat = starts
        .iter()
        .find(|s| first_model(s).is_some())
        .unwrap_or_else(|| panic!("no start named a model: {starts:?}"));
    assert_eq!(first_model(chat).as_deref(), Some("gpt-6.2-sol"), "{starts:?}");
    assert_eq!(chat.as_array().unwrap().last().unwrap(), "app-server", "{chat}");
    assert!(starts.iter().filter_map(first_model).all(|m| m == "gpt-6.2-sol"), "{starts:?}");

    // The active profile's model.
    std::fs::write(
        home.join("config.toml"),
        "model = \"gpt-6.2-sol\"\nprofile = \"astra\"\n[profiles.astra]\nmodel = \"gpt-6-astra\"\n",
    )
    .unwrap();
    let recorded = d.join("profile-args.json");
    let hub = hub_on(vec![json!(codex), json!("app-server")], &recorded);
    let starts = starts_of_a_chat(&hub, &d, &recorded).await;
    let models: Vec<String> = starts.iter().filter_map(first_model).collect();
    assert!(!models.is_empty() && models.iter().all(|m| m == "gpt-6-astra"), "{starts:?}");

    // A model the harness's own command line names stays the only one.
    let recorded = d.join("own-args.json");
    let hub = hub_on(
        vec![json!(codex), json!("--model"), json!("gpt-6.1-sol"), json!("app-server")],
        &recorded,
    );
    let starts = starts_of_a_chat(&hub, &d, &recorded).await;
    for s in &starts {
        let words: Vec<&str> = s.as_array().unwrap().iter().filter_map(Value::as_str).collect();
        assert!(!words.contains(&"-m"), "{s}");
        assert_eq!(words.iter().filter(|w| **w == "gpt-6.1-sol").count(), 1, "{s}");
    }

    // No model configured: the launch is as before.
    std::fs::write(home.join("config.toml"), "").unwrap();
    let recorded = d.join("none-args.json");
    let hub = hub_on(vec![json!(codex), json!("app-server")], &recorded);
    let starts = starts_of_a_chat(&hub, &d, &recorded).await;
    assert!(starts.iter().all(|s| first_model(s).is_none()), "{starts:?}");
    let _ = std::fs::remove_dir_all(&d);
}

/// A start's arguments without the `-c developer_instructions=...` a chat's start carries
/// (`context_inventory::launch_args`): cmux's rules, which the limits leave alone.
fn without_rules(start: &Value) -> Value {
    let words = start.as_array().cloned().unwrap_or_default();
    let mut out = Vec::new();
    let mut i = 0;
    while i < words.len() {
        let rules = words[i] == "-c"
            && words
                .get(i + 1)
                .and_then(Value::as_str)
                .is_some_and(|w| w.starts_with("developer_instructions="));
        if rules {
            i += 2;
        } else {
            out.push(words[i].clone());
            i += 1;
        }
    }
    Value::Array(out)
}

/// Whether `start` has a config override after its `app-server` word, which some codex builds
/// (0.160, the cmux fork) answer by dropping every override before the subcommand (cmux#48354).
fn config_after_subcommand(start: &Value) -> bool {
    let words: Vec<&str> = start.as_array().unwrap().iter().filter_map(Value::as_str).collect();
    words.iter().position(|w| *w == "app-server").is_some_and(|at| {
        words[at + 1..].iter().any(|w| w.starts_with("-c") || w.starts_with("--config"))
    })
}

#[tokio::test]
async fn a_prefer_list_still_picks_the_codex_profile() {
    let d = dir("prefer");
    let codex = shim(&d, "codex", FAKE_APP_SERVER);
    let harnesses = json!({
        "codex": {"argv": [codex, "app-server"]},
        "mine": {"argv": ["python3", FAKE_AGENT], "family": "codex"},
    });
    let preferring = hub_with(json!({
        "harnesses": harnesses,
        "defaults": {"codex": {"prefer": ["mine", "codex"]}},
        "permissionPolicy": "ask",
    }));
    let (_, picked) = harness_of_new(&mut Client::local(&preferring), &d, "codex").await;
    assert_eq!(picked, "mine", "the prefer list's first profile");
    let plain = hub_with(json!({"harnesses": harnesses, "permissionPolicy": "ask"}));
    let (_, picked) = harness_of_new(&mut Client::local(&plain), &d, "codex").await;
    assert_eq!(picked, "codex", "without a preference, the profile named like the family");
    let _ = std::fs::remove_dir_all(&d);
}

/// The harnesses a real daemon discovers on the PATH `d/bin` (plus the system's).
async fn discovered_harnesses(d: &Path) -> Value {
    let home = d.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let acp_home = d.join("acpmux");
    std::fs::create_dir_all(&acp_home).unwrap();
    let socket = acp_home.join("s.sock");
    // The stand-in codex in `d/bin`, first on the bare PATH, is only listed:
    // no launch is needed.
    let mut child = daemon_env::acpmux(d)
        .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "warn"])
        .env("PATH", format!("{}:{}", d.join("bin").display(), daemon_env::bare_path(&[])))
        .env("ACPMUX_HOME", &acp_home)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("start daemon");
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let mut ready = String::new();
    while stdout.read_line(&mut ready).unwrap() > 0 && !ready.contains("\"ready\":true") {
        ready.clear();
    }
    let socket = serde_json::from_str::<Value>(&ready)
        .ok()
        .and_then(|v| v["socket"].as_str().map(PathBuf::from))
        .unwrap_or(socket);
    let stream = tokio::net::UnixStream::connect(&socket).await.expect("daemon socket");
    let (rd, mut wr) = stream.into_split();
    let mut lines = tokio::io::BufReader::new(rd).lines();
    let line = json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/harnesses", "params": {}});
    wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
    let reply = loop {
        let l = tokio::time::timeout(Duration::from_secs(30), lines.next_line())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let v: Value = serde_json::from_str(&l).unwrap();
        if v["id"] == json!(1) {
            break v;
        }
    };
    let _ = child.kill();
    let _ = child.wait();
    reply["result"]["harnesses"].clone()
}

/// The real daemon discovers its harnesses on its own PATH.
#[tokio::test]
async fn codex_on_path_is_the_bridge_and_the_adapter_becomes_codex_acp() {
    let d = dir("discover");
    shim(&d, "codex", FAKE_APP_SERVER);
    shim(&d, "codex-acp", FAKE_AGENT);
    let h = &discovered_harnesses(&d).await;
    assert_eq!(h["codex"]["argv"][1], "app-server", "{h}");
    assert!(h["codex"]["argv"][0].as_str().unwrap_or("").ends_with("/codex"), "{h}");
    assert!(h["codex-acp"]["argv"][0].as_str().unwrap_or("").ends_with("/codex-acp"), "{h}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Without a codex-acp on PATH, the pinned npx adapter is not offered beside
/// the bridge: it reads the account through codex's `account/read`, which a
/// ChatGPT login behind a routing proxy (subrouter) fails, so its chats never
/// started ("Authentication required"). `codex-acp`, the name earlier chats
/// and model picks recorded, runs the bridge instead.
#[tokio::test]
async fn without_codex_acp_on_path_the_npx_adapter_gives_way_to_the_bridge() {
    let d = dir("npx-adapter");
    shim(&d, "codex", FAKE_APP_SERVER);
    // An npx that installs nothing: discovery only needs it to exist.
    let npx = d.join("bin").join("npx");
    std::fs::write(&npx, "#!/bin/sh\nexit 1\n").unwrap();
    std::fs::set_permissions(&npx, std::fs::Permissions::from_mode(0o755)).unwrap();
    let h = &discovered_harnesses(&d).await;
    for (name, profile) in h.as_object().unwrap() {
        let program = profile["argv"][0].as_str().unwrap_or("");
        assert!(!program.ends_with("/npx"), "{name} launches through npx: {h}");
    }
    assert_eq!(h["codex"]["argv"][1], "app-server", "{h}");
    assert_eq!(h["codex-acp"]["argv"], h["codex"]["argv"], "codex-acp runs the bridge: {h}");
    let _ = std::fs::remove_dir_all(&d);
}
