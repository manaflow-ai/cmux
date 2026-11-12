//! The session recap's small-model call (`hub/away_recap.rs` `fallback_recap`, through
//! `Hub::complete_own_strict`) runs on the route the chat itself runs on: its own binding, else
//! its workspace's, as its spawn applies them, never the global default instead. A chat bound to
//! a private endpoint never has its recent turns sent to another provider; a chat whose route
//! cannot be applied gets no recap at all.
//!
//! The real completion runs here (no `set_recap_writer`): the chat's harness is a shell script
//! that runs the stand-in ACP agent for the chat's turns and, called as `opencode run` (the
//! headless recipe), answers with the endpoint its environment names.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (fake_agent.py behind a shell script).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::routes;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
/// The default (global) route's endpoint: the provider the chat was never sent to.
const ROUTE_A: &str = "http://route-a.invalid/v1";
/// The chat's own route's endpoint.
const ROUTE_B: &str = "http://route-b.invalid/v1";

struct Chat {
    hub: Arc<Hub>,
    c: Client,
    id: String,
    clock: Arc<acpmux::clock::ManualClock>,
    root: PathBuf,
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    async fn ok(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("no reply in 30 s")
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{m}: {v}");
                return v["result"].clone();
            }
        }
    }
}

fn scratch(name: &str) -> PathBuf {
    let root =
        std::env::temp_dir().join(format!("acpmux-recap-route-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("config").join("harnesses")).unwrap();
    std::fs::canonicalize(&root).unwrap()
}

fn routes_dir(root: &Path) -> PathBuf {
    root.join("config").join("routes")
}

fn add_route(root: &Path, id: &str, url: &str) {
    let file = routes::file_from_json(&json!({
        "kind": "custom-openai", "families": ["opencode"], "openaiBaseUrl": url,
    }))
    .unwrap();
    routes::add(Some(&routes_dir(root)), id, &file, false).unwrap();
}

fn bind(root: &Path, scope: &str, route: &str) {
    routes::set_binding(&root.join("home"), scope, Some(route)).unwrap();
}

/// The file the harness's headless run touches: it ran at all.
fn ran(root: &Path) -> PathBuf {
    root.join("ran")
}

/// A chat with 3 finished turns on a harness whose headless run answers with its
/// `OPENAI_BASE_URL`, shown by a person's pane, on a manual clock; the global default route
/// is A. `env`: the chat's session env.
/// The acpmux home every chat here shares, set once before any hub starts: under `/tmp`, whose
/// sticky bit the completion's run folders require of every writable ancestor (`target/tmp`
/// has none, and the completion refuses it).
fn acpmux_home() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let home = Path::new("/tmp").join(format!("acpmux-recap-route-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        // SAFETY: set once, before any hub in this binary reads it.
        unsafe { std::env::set_var("ACPMUX_HOME", &home) };
    });
}

async fn chat(name: &str, env: Value) -> Chat {
    chat_with(name, env, |root| {
        add_route(root, "route-a", ROUTE_A);
        bind(root, "global", "route-a");
        json!({"fake": {"argv": [root.join("agent.sh")], "family": "opencode"}})
    })
    .await
}

/// [`chat`] with the harnesses `setup` writes (`fake` is the chat's) and its routes and bindings.
async fn chat_with(name: &str, env: Value, setup: impl FnOnce(&Path) -> Value) -> Chat {
    acpmux_home();
    let root = scratch(name);
    let script = root.join("agent.sh");
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\nif [ \"$1\" = run ]; then\n  echo \"$* ${{OPENAI_BASE_URL:-no-route}}\" >> '{}'\n  printf 'Recap from %s\\n' \"${{OPENAI_BASE_URL:-no-route}}\"\n  exit 0\nfi\nexec python3 '{FAKE}' \"$@\"\n",
            ran(&root).display()
        ),
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let harnesses = setup(&root);
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": harnesses,
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.path = Some(root.join("home").join("config.json"));
    cfg.profile_sources.user_dir = Some(root.join("config").join("harnesses"));
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(None);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    let mut c = Client(in_tx, out_rx, 0);
    c.ok(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "pane"}})).await;
    let new =
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"env": env}}});
    let id = c.ok(method::SESSION_NEW, new).await["sessionId"].as_str().unwrap().to_owned();
    c.ok("_acpmux/view", json!({"sessionId": id, "visible": true})).await;
    for n in 0..3 {
        let text = format!("step {n}");
        let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
        c.ok(method::SESSION_PROMPT, prompt).await;
    }
    Chat { hub, c, id, clock, root }
}

impl Chat {
    fn recaps(&self) -> Vec<Value> {
        self.hub
            .events(&self.id, 0, 10_000)
            .unwrap()
            .iter()
            .filter(|e| e.dir == "mux" && e.kind == "recap")
            .map(|e| e.msg.clone())
            .collect()
    }

    /// The person leaves, the recap is asked 3 minutes later (the real small-model call), and
    /// they come back after 5: the recap it made, if any.
    async fn away_and_back(&mut self) -> Vec<Value> {
        self.c.ok("_acpmux/view", json!({"sessionId": self.id, "visible": false})).await;
        self.clock.advance(Duration::from_secs(3 * 60));
        // The call runs in the background, after the daemon's startup settles: wait until its
        // recap is ready (30 s at most), so a run that never happens is told from a slow one.
        for _ in 0..1500 {
            if self.hub.recap_ready(&self.id) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        self.clock.advance(Duration::from_secs(2 * 60));
        self.c.ok("_acpmux/view", json!({"sessionId": self.id, "visible": true})).await;
        self.recaps()
    }
}

/// The recap's text carries route B's endpoint, never the default route A's.
fn assert_on_route_b(recaps: &[Value]) {
    assert_eq!(recaps.len(), 1, "{recaps:?}");
    let text = recaps[0]["text"].as_str().unwrap();
    assert!(text.contains(ROUTE_B), "the chat's own route: {text}");
    assert!(!text.contains(ROUTE_A), "the default route got the chat's text: {text}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_chat_bound_to_its_own_route_gets_its_recap_on_that_route() {
    let mut a = chat("chat", json!({})).await;
    add_route(&a.root, "route-b", ROUTE_B);
    bind(&a.root, &format!("chat:{}", a.id), "route-b");
    let recaps = a.away_and_back().await;
    assert!(ran(&a.root).exists(), "the small model was asked");
    assert_on_route_b(&recaps);
    let _ = std::fs::remove_dir_all(&a.root);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_chat_in_a_bound_workspace_gets_its_recap_on_the_workspaces_route() {
    let workspace = "4f1c2a3b-5d6e-4f70-8a9b-0c1d2e3f4a5b";
    let mut a = chat("workspace", json!({"CMUX_WORKSPACE_ID": workspace})).await;
    add_route(&a.root, "route-b", ROUTE_B);
    bind(&a.root, &format!("workspace:{workspace}"), "route-b");
    let recaps = a.away_and_back().await;
    assert!(ran(&a.root).exists(), "the small model was asked");
    assert_on_route_b(&recaps);
    let _ = std::fs::remove_dir_all(&a.root);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_chat_whose_route_is_gone_gets_no_recap_and_nothing_is_sent() {
    let mut a = chat("gone", json!({})).await;
    // Bound to a route whose file is gone: its spawn would refuse it, and so does the recap,
    // never falling back to the default route A.
    bind(&a.root, &format!("chat:{}", a.id), "route-gone");
    let recaps = a.away_and_back().await;
    assert!(
        !ran(&a.root).exists(),
        "the harness ran on another route: {}",
        std::fs::read_to_string(ran(&a.root)).unwrap_or_default()
    );
    assert!(recaps.is_empty(), "{recaps:?}");
    let _ = std::fs::remove_dir_all(&a.root);
}

/// An account route of the Codex family: its chats run in `home` (`CODEX_HOME`).
fn add_account_route(root: &Path, id: &str, home: &Path) {
    std::fs::create_dir_all(home).unwrap();
    let file = routes::file_from_json(&json!({
        "kind": "direct-subscription", "families": ["codex"], "accountHome": home,
    }))
    .unwrap();
    routes::add(Some(&routes_dir(root)), id, &file, false).unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_chat_with_a_recorded_account_home_gets_its_recap_in_that_home() {
    // A Codex chat started in account A's home, which it keeps as its store
    // (`route_account::record`); the default route then moves to account B. Its spawn stays in
    // A (`route_account::keep_home`), and so does its recap, never B's login.
    let home_a = std::env::temp_dir().join(format!("acpmux-recap-home-a-{}", std::process::id()));
    let home_b = std::env::temp_dir().join(format!("acpmux-recap-home-b-{}", std::process::id()));
    let mut a = chat_with("account", json!({}), |root| {
        add_account_route(root, "account-a", &home_a);
        add_account_route(root, "account-b", &home_b);
        bind(root, "global", "account-a");
        // `codex exec` (the headless recipe) answers with the home it runs in.
        let headless = root.join("codex-headless.sh");
        std::fs::write(
            &headless,
            format!(
                "#!/bin/sh\nout=\nwhile [ $# -gt 0 ]; do\n  if [ \"$1\" = --output-last-message ]; then out=$2; fi\n  shift\ndone\necho \"exec ${{CODEX_HOME:-no-home}}\" >> '{}'\nprintf 'Recap from %s\\n' \"${{CODEX_HOME:-no-home}}\" > \"$out\"\n",
                ran(root).display()
            ),
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&headless, std::fs::Permissions::from_mode(0o755)).unwrap();
        json!({"fake": {"argv": ["python3", FAKE], "family": "codex",
                        "env": {"CODEX_PATH": headless}}})
    })
    .await;
    assert_eq!(
        a.hub.resolve(&a.id).unwrap().meta().chat_store,
        Some(home_a.clone()),
        "the chat keeps account A's home as its store"
    );
    bind(&a.root, "global", "account-b");
    let recaps = a.away_and_back().await;
    let ran_with = std::fs::read_to_string(ran(&a.root)).unwrap_or_default();
    assert!(ran_with.contains(&home_a.display().to_string()), "ran in A's home: {ran_with}");
    assert!(!ran_with.contains(&home_b.display().to_string()), "ran in B's home: {ran_with}");
    assert_eq!(recaps.len(), 1, "{recaps:?}");
    let text = recaps[0]["text"].as_str().unwrap();
    assert!(text.contains(&home_a.display().to_string()), "{text}");
    for dir in [&a.root, &home_a, &home_b] {
        let _ = std::fs::remove_dir_all(dir);
    }
}
