//! Adding your own harness from the app, the CLI and MCP
//! (BRING-YOUR-OWN-HARNESS H2; Lawrence 2026-10-08: "ensure people are able
//! to add their own ACP stuff, via UI, cli, mcp, cmd shift p"). The daemon
//! methods `_acpmux/harness/add|remove|restore|doctor` and `_acpmux/registry`
//! write and check profile files in the user folder, reload the catalog and
//! tell `_acpmux/watch` connections.
//!
//! One test: the methods read acpmux's home from ACPMUX_HOME, a process-wide
//! setting.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

use acpmux::config::{Config, ProfileSources, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

fn write(path: &Path, text: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

fn scratch() -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-admin-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("config")).unwrap();
    std::fs::canonicalize(&root).unwrap()
}

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl Client {
    fn open(hub: &std::sync::Arc<Hub>, origin: Origin) -> Self {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Self { tx, rx, next: 1 }
    }

    /// The reply to one request: Ok(result) or Err(error object). Notifications
    /// that arrive first are kept for `note`.
    async fn call(
        &mut self,
        m: &str,
        params: Value,
        notes: &mut Vec<Value>,
    ) -> Result<Value, Value> {
        let id = self.next;
        self.next += 1;
        self.tx.send(Message::request(id, m, params).to_line()).await.unwrap();
        let end = Instant::now() + Duration::from_secs(60);
        loop {
            let left = end.checked_duration_since(Instant::now()).expect("no reply in 60 s");
            let line = tokio::time::timeout(left, self.rx.recv()).await.expect("no reply").unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return match v.get("error") {
                    Some(e) => Err(e.clone()),
                    None => Ok(v["result"].clone()),
                };
            }
            if v.get("method").is_some() {
                notes.push(v);
            }
        }
    }

    /// The first harnesses_changed (kept or new) whose harness list passes `wanted`.
    async fn changed(
        &mut self,
        notes: &mut Vec<Value>,
        wanted: impl Fn(&[String]) -> bool,
    ) -> bool {
        let names = |n: &Value| -> Vec<String> {
            n["params"]["harnesses"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        };
        let hit = |n: &Value| n["method"] == method::MUX_HARNESSES_CHANGED && wanted(&names(n));
        if notes.iter().any(hit) {
            notes.clear();
            return true;
        }
        let end = Instant::now() + Duration::from_secs(10);
        while let Some(left) = end.checked_duration_since(Instant::now()) {
            let Ok(Some(line)) = tokio::time::timeout(left, self.rx.recv()).await else { break };
            let v: Value = serde_json::from_str(&line).unwrap();
            if hit(&v) {
                return true;
            }
        }
        false
    }
}

fn reason(error: &Value) -> &str {
    error["data"]["reason"].as_str().unwrap_or("")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn people_add_check_remove_and_restore_their_own_harness() {
    let root = scratch();
    let acpmux_home = root.join("acpmux-home");
    // SAFETY: the only test in this binary; nothing else reads the env now.
    unsafe { std::env::set_var("ACPMUX_HOME", &acpmux_home) };
    let user = root.join("config").join("harnesses");
    let managed = root.join("managed");
    write(
        &managed.join("company.toml"),
        "schema = 1\nid = \"company\"\nname = \"Company Agent\"\ncommand = \"/bin/echo\"\n",
    );
    let sources = ProfileSources {
        managed: vec![managed.clone()],
        user_dir: Some(user.clone()),
        cmux_json: Some(root.join("config").join("cmux.json")),
    };
    write(&root.join("home").join("config.json"), "{}");
    let mut cfg = Config::load_from_with(&root.join("home").join("config.json"), &sources).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);

    let mut app = Client::open(&hub, Origin::Local);
    let mut notes = Vec::new();
    app.call(method::MUX_WATCH, json!({"enabled": true}), &mut notes).await.unwrap();

    // Add: a command with arguments, a display name, a plain env value and a
    // Keychain reference. The file is written, loads, and watchers hear of it.
    let added = app
        .call(
            "_acpmux/harness/add",
            json!({"id": "acme", "displayName": "Acme Agent", "command": "/bin/echo",
                   "args": ["acp", "--fast"], "protocol": "acp",
                   "env": {"REGION": "zzplainmarker", "ACME_API_KEY": "keychain:acme-key"}}),
            &mut notes,
        )
        .await
        .expect("add");
    assert_eq!(added["id"], "acme", "{added}");
    let path = PathBuf::from(added["path"].as_str().unwrap());
    assert_eq!(path, user.join("acme.toml"));
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(text.contains("Acme Agent") && text.contains("keychain"), "{text}");
    assert!(added["diagnostics"].as_array().is_some_and(Vec::is_empty), "{added}");
    assert!(
        app.changed(&mut notes, |h| h.iter().any(|n| n == "acme")).await,
        "no harnesses_changed"
    );
    {
        let cfg = hub.config.read().await;
        assert_eq!(cfg.harnesses["acme"].argv, vec!["/bin/echo", "acp", "--fast"]);
    }

    // The same id again is refused unless replace is set.
    let dup = app
        .call("_acpmux/harness/add", json!({"id": "acme", "command": "/bin/echo"}), &mut notes)
        .await
        .expect_err("duplicate add");
    assert_eq!(reason(&dup), "harness.exists", "{dup}");
    app.call(
        "_acpmux/harness/add",
        json!({"id": "acme", "displayName": "Acme Agent", "command": "/bin/echo", "args": ["acp"],
               "env": {"REGION": "zzplainmarker"}, "replace": true}),
        &mut notes,
    )
    .await
    .expect("replace");

    // A literal value under a secret-looking key never reaches a file.
    let secret = app
        .call(
            "_acpmux/harness/add",
            json!({"id": "leaky", "command": "/bin/echo", "env": {"OPENAI_API_KEY": "sk-zzz"}}),
            &mut notes,
        )
        .await
        .expect_err("inline secret");
    assert_eq!(reason(&secret), "harness.secret_inline", "{secret}");
    assert!(!user.join("leaky.toml").exists());
    // Exactly one of command, registry and example.
    let both = app
        .call(
            "_acpmux/harness/add",
            json!({"id": "two", "command": "/bin/echo", "example": "gemini"}),
            &mut notes,
        )
        .await
        .expect_err("command and example");
    assert!(both["message"].as_str().unwrap_or("").contains("one of"), "{both}");

    // Doctor reports its steps as data and never an env value.
    let report = app
        .call(
            "_acpmux/harness/doctor",
            json!({"id": "acme", "noPrompt": true, "timeoutSecs": 5}),
            &mut notes,
        )
        .await
        .expect("doctor");
    assert_eq!(report["id"], "acme");
    assert!(report["ok"].is_boolean(), "{report}");
    let steps = report["steps"].as_array().unwrap();
    assert!(!steps.is_empty());
    for s in steps {
        assert!(s["name"].is_string() && s["ok"].is_boolean() && s["detail"].is_string(), "{s}");
    }
    assert!(!report.to_string().contains("zzplainmarker"), "doctor leaked an env value: {report}");

    // Remove moves the file to a backup; restore brings it back.
    let removed = app
        .call("_acpmux/harness/remove", json!({"id": "acme"}), &mut notes)
        .await
        .expect("remove");
    assert_eq!(removed["id"], "acme");
    let backup = removed["backup"].as_str().unwrap().to_owned();
    assert!(!user.join("acme.toml").exists());
    assert!(acpmux_home.join("harness-backups").read_dir().unwrap().next().is_some());
    assert!(app.changed(&mut notes, |h| !h.iter().any(|n| n == "acme")).await);
    assert!(!hub.config.read().await.harnesses.contains_key("acme"));
    let restored = app
        .call("_acpmux/harness/restore", json!({"backup": backup}), &mut notes)
        .await
        .expect("restore");
    assert_eq!(restored["id"], "acme");
    assert!(user.join("acme.toml").exists());
    assert!(app.changed(&mut notes, |h| h.iter().any(|n| n == "acme")).await);
    // A backup name is a name, never a path.
    let escape = app
        .call("_acpmux/harness/restore", json!({"backup": "../../etc/passwd"}), &mut notes)
        .await
        .expect_err("path backup");
    assert!(escape["message"].is_string());

    // Managed (company) profiles and unknown ids are not removable.
    let company = app
        .call("_acpmux/harness/remove", json!({"id": "company"}), &mut notes)
        .await
        .expect_err("managed");
    assert_eq!(reason(&company), "harness.not_removable", "{company}");
    assert!(managed.join("company.toml").exists());

    // The ACP Registry from the cached copy: each agent and how it starts here.
    acpmux::registry::save(&acpmux_home, include_bytes!("fixtures/acp-registry.json")).unwrap();
    let reg = app.call("_acpmux/registry", json!({}), &mut notes).await.expect("registry");
    let agents = reg["agents"].as_array().unwrap();
    let copilot = agents.iter().find(|a| a["id"] == "github-copilot-cli").expect("copilot");
    assert!(copilot["name"].is_string() && copilot["version"].is_string(), "{copilot}");
    assert!(
        ["path", "npx", "uvx", "none"].contains(&copilot["launch"].as_str().unwrap()),
        "{copilot}"
    );
    assert!(copilot["installed"].is_boolean(), "{copilot}");
    let grok = agents.iter().find(|a| a["id"] == "grok-build").expect("grok");
    assert_eq!(grok["harnessId"], "grok");

    // A remote WebSocket connection may not add or remove harnesses.
    let mut web = Client::open(&hub, Origin::Web);
    let refused = web
        .call("_acpmux/harness/add", json!({"id": "web", "command": "/bin/echo"}), &mut Vec::new())
        .await
        .expect_err("web add");
    assert!(refused["message"].is_string());
    assert!(!user.join("web.toml").exists());
}
