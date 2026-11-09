//! A spawn waits for the login shell, or refuses to start, only over a login value its child's
//! final env plan takes (`login_env::ChildEnv`): never one a route unsets (a codex chat on the
//! built-in `codex-login` route) and never one a remote-origin launch, whose env is cleared, could
//! inherit. A local multi-provider harness (pi) that does take a credential-bearing base URL still
//! refuses rather than start on its default endpoint.
//!
//! One test: the login environment is process-wide (ACPMUX_HOME, HOME, SHELL).

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::login_env::{self, Outcome};
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
/// A Codex login as `codex login` leaves it.
const SIGNED_IN: &str = r#"{"tokens": {"access_token": "x"}}"#;
/// A base URL that carries a credential: the cache keeps only its name (`save_cache`).
const KEYED_URL: &str = "http://127.0.0.1:9/v1?api_key=s3cret-in-url";

fn write_executable(path: &Path, text: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn scratch() -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-child-plan-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    for sub in ["home", "acpmux", "codex", "work", "config/harnesses"] {
        std::fs::create_dir_all(root.join(sub)).unwrap();
    }
    let root = std::fs::canonicalize(&root).unwrap();
    // A login shell that sources `~/.zshrc`, then runs the `-c` script.
    write_executable(
        &root.join("loginsh"),
        "#!/bin/sh\nfor a; do last=$a; done\n. \"$HOME/.zshrc\"\neval \"$last\"\n",
    );
    std::fs::write(
        root.join("home/.zshrc"),
        format!(
            "[ -f \"$HOME/slow\" ] && sleep \"$(cat \"$HOME/slow\")\"\nexport OPENAI_BASE_URL='{KEYED_URL}'\n"
        ),
    )
    .unwrap();
    std::fs::write(root.join("codex/auth.json"), SIGNED_IN).unwrap();
    root
}

fn hub(root: &Path) -> Arc<Hub> {
    let fake = |family: &str| {
        json!({"argv": ["python3", FAKE], "family": family,
               "env": {"CODEX_HOME": root.join("codex"), "FAKE_ASK_MODE": "1"}})
    };
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake-codex": fake("codex"), "fake-pi": fake("pi")},
        "defaultHarness": "fake-codex",
        "permissionPolicy": "approve-all",
        "webRoots": [root.join("work")],
        // A remote start takes the fake agent's one mode, "ask" (`FAKE_ASK_MODE`).
        "webAskingModes": {"pi": ["ask"]},
        "autoResumeDelaysMs": [],
    }))
    .unwrap();
    cfg.path = Some(root.join("acpmux").join("config.json"));
    cfg.profile_sources.user_dir = Some(root.join("config").join("harnesses"));
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client(in_tx, out_rx, 0)
    }

    /// The reply to one call, and the agent text streamed before it.
    async fn call(&mut self, m: &str, params: Value) -> (Value, String) {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        let mut text = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("no reply in 30 s")
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return (v, text);
            }
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
    }

    /// A new chat on `harness` asked for `OPENAI_BASE_URL`: its value, or the error that refused
    /// the start; and how long that took.
    async fn base_url(&mut self, root: &Path, harness: &str) -> (Result<String, String>, Duration) {
        let started = Instant::now();
        let new = json!({"cwd": root.join("work"), "mcpServers": [],
                         "_meta": {"acpmux": {"harness": harness}}});
        let (created, _) = self.call("session/new", new).await;
        let Some(id) = created["result"]["sessionId"].as_str().map(str::to_owned) else {
            return (Err(created["error"].to_string()), started.elapsed());
        };
        let ask =
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "env: OPENAI_BASE_URL"}]});
        let (reply, mut text) = self.call("session/prompt", ask).await;
        if let Some(error) = reply.get("error") {
            return (Err(error.to_string()), started.elapsed());
        }
        // The reply can overtake the turn's last streamed update.
        while !text.contains("OPENAI_BASE_URL=") {
            let line = tokio::time::timeout(Duration::from_secs(10), self.1.recv())
                .await
                .unwrap_or_else(|_| panic!("no env text: {reply}"))
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
        let at = text.rfind("OPENAI_BASE_URL=").unwrap();
        (Ok(text[at + "OPENAI_BASE_URL=".len()..].trim().to_owned()), started.elapsed())
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn only_a_login_value_the_childs_plan_takes_holds_or_refuses_its_start() {
    let root = scratch();
    // SAFETY: the only test in this binary; nothing else reads the env now.
    unsafe {
        std::env::set_var("ACPMUX_HOME", root.join("acpmux"));
        std::env::set_var("HOME", root.join("home"));
        std::env::set_var("SHELL", root.join("loginsh"));
        std::env::remove_var("OPENAI_BASE_URL");
    }
    let _ = HERMETIC;
    // The first start reads the shell and caches it: the keyed URL by name only.
    login_env::begin();
    login_env::import().await;
    assert_eq!(login_env::outcome(), Outcome::Shell);
    let cache = std::fs::read_to_string(root.join("acpmux/login-env.json")).unwrap();
    assert!(!cache.contains("s3cret-in-url"), "a credential in the cache: {cache}");
    // A cached restart whose shell never answers within the wait.
    std::fs::write(root.join("home/slow"), "30").unwrap();
    login_env::begin();
    assert_eq!(login_env::outcome(), Outcome::Cached);
    assert!(login_env::missing_secret_names().contains(&"OPENAI_BASE_URL".to_owned()));

    let hub = hub(&root);
    // A remote-origin chat starts from a cleared env, which never inherits the local URL: a pi
    // chat that would take it locally starts at once, as a direct child.
    let mut web = Client::new(&hub, Origin::Web);
    let (base, took) = web.base_url(&root, "fake-pi").await;
    assert_eq!(base.as_deref(), Ok(""), "remote-origin chat");
    assert!(took < Duration::from_secs(3), "remote-origin chat waited {took:?}");

    // The same chat started here takes the URL from the login env: it waits, then refuses,
    // naming the variable and never its value, rather than start on its default endpoint.
    let mut local = Client::new(&hub, Origin::Local);
    let (base, took) = local.base_url(&root, "fake-pi").await;
    let error = base.expect_err("a pi chat started without its base URL");
    assert!(error.contains("OPENAI_BASE_URL"), "{error}");
    assert!(!error.contains("s3cret-in-url"), "{error}");
    assert!(took >= Duration::from_secs(3), "refused after {took:?}, before the wait ended");

    // A codex chat on the built-in codex-login route: the route unsets OPENAI_BASE_URL, so the
    // keyed URL is never its child's and it starts at once.
    let (bound, _) = local
        .call("_acpmux/route/default.set", json!({"scope": "global", "routeId": "codex-login"}))
        .await;
    assert!(bound.get("error").is_none(), "{bound}");
    let (base, took) = local.base_url(&root, "fake-codex").await;
    assert_eq!(base.as_deref(), Ok(""), "codex-login chat");
    assert!(took < Duration::from_secs(3), "codex-login chat waited {took:?}");
    let _ = std::fs::remove_dir_all(&root);
}
