//! `_acpmux/harness_enable` (BRING-YOUR-OWN-HARNESS H4): the app's "Enable
//! harness" sheet gets the same prompt the CLI shows, and records only the
//! bytes the user saw. The unix socket and the local app only: never a Web
//! or peer connection.

use acpmux::config::folder_profiles::{self, FolderGate};
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl Client {
    async fn request(&mut self, m: &str, params: Value) -> Result<Value, String> {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout waiting for response")
                .expect("connection closed");
            if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
                && rid == id
            {
                return match error {
                    Some(e) => Err(e.message),
                    None => Ok(result.unwrap_or(Value::Null)),
                };
            }
        }
    }
}

fn write(path: &Path, text: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

const PROFILE: &str = r#"schema = 1
id = "acme"
command = "/bin/echo"
args = ["acp"]

[env]
ACME_REGION = "us-east-1"
ACME_API_KEY = { keychain = "cmux-harness/acme/ACME_API_KEY" }
NODE_OPTIONS = "--require ./x.js"
"#;

fn scratch(name: &str) -> (PathBuf, FolderGate) {
    let root = std::env::temp_dir().join(format!("acpmux-enable-op-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(folder_profiles::profile_dir(&root.join("repo"))).unwrap();
    let root = std::fs::canonicalize(&root).unwrap();
    let folder = root.join("repo");
    write(&folder_profiles::profile_dir(&folder).join("acme.toml"), PROFILE);
    let gate = FolderGate {
        enable_record: root.join("acpmux").join(folder_profiles::ENABLE_RECORD),
        trust: acpmux::trust::Paths {
            claude_json: root.join("claude.json"),
            codex_config: root.join("config.toml"),
            record: root.join("acpmux").join("trust.json"),
            agent_home: None,
        },
    };
    (folder, gate)
}

fn hub(gate: &FolderGate) -> Arc<Hub> {
    let mut cfg = Config { folder_gate: Some(gate.clone()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

async fn connect(hub: &Arc<Hub>, origin: Origin) -> Client {
    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    Client { tx, rx, next: 0 }
}

#[tokio::test]
async fn the_enable_op_shows_the_cli_prompt_and_records_only_the_shown_bytes() {
    let (folder, gate) = scratch("local");
    let hub = hub(&gate);
    let mut c = connect(&hub, Origin::Local).await;
    let ask = json!({"folder": folder, "id": "acme"});

    let e = c.request(method::MUX_HARNESS_ENABLE, ask.clone()).await.unwrap_err();
    assert!(e.contains("not trusted"), "{e}");

    acpmux::trust::set(&gate.trust, &folder.to_string_lossy(), "trusted").unwrap();
    let shown = c.request(method::MUX_HARNESS_ENABLE, ask.clone()).await.unwrap();
    let prompt = &shown["prompt"];
    assert_eq!(prompt["state"], "needs-enable");
    assert_eq!(prompt["argv"], json!(["/bin/echo", "acp"]));
    let env = prompt["env"].as_array().unwrap();
    let source = |key: &str| {
        env.iter().find(|e| e["key"] == key).map(|e| e["source"].clone()).unwrap_or(Value::Null)
    };
    assert_eq!(source("ACME_API_KEY"), "keychain");
    assert_eq!(source("ACME_REGION"), "plain");
    let text = prompt["text"].as_str().unwrap();
    assert!(text.contains("/bin/echo acp"), "{text}");
    assert!(text.contains("NODE_OPTIONS changes which code"), "{text}");
    assert!(
        prompt["warnings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|w| w.as_str().unwrap().contains("NODE_OPTIONS")),
        "{prompt}"
    );
    let sha = prompt["sha256"].as_str().unwrap().to_owned();
    // Showing the prompt enables nothing.
    let cfg = Config { folder_gate: Some(gate.clone()), ..Default::default() };
    let state =
        |cfg: &Config| folder_profiles::load_one(cfg, &gate, &folder, "acme").unwrap().state;
    assert_eq!(state(&cfg), folder_profiles::FolderState::NeedsEnable);

    // A file changed after the prompt is not enabled with the old hash.
    let path = folder_profiles::profile_dir(&folder).join("acme.toml");
    write(&path, &format!("{PROFILE}# edited\n"));
    let e = c
        .request(method::MUX_HARNESS_ENABLE, json!({"folder": folder, "id": "acme", "sha256": sha}))
        .await
        .unwrap_err();
    assert!(e.contains("changed"), "{e}");
    assert_eq!(state(&cfg), folder_profiles::FolderState::NeedsEnable);

    let shown = c.request(method::MUX_HARNESS_ENABLE, ask.clone()).await.unwrap();
    let sha = shown["prompt"]["sha256"].as_str().unwrap().to_owned();
    let done = c
        .request(method::MUX_HARNESS_ENABLE, json!({"folder": folder, "id": "acme", "sha256": sha}))
        .await
        .unwrap();
    assert_eq!(done["enabled"]["state"], "enabled");
    assert_eq!(state(&cfg), folder_profiles::FolderState::Enabled);
    let reply = serde_json::to_string(&done).unwrap();
    assert!(!reply.contains("${keychain:"), "{reply}");
}

#[tokio::test]
async fn web_and_peer_connections_cannot_see_or_enable_a_folder_harness() {
    let (folder, gate) = scratch("remote");
    acpmux::trust::set(&gate.trust, &folder.to_string_lossy(), "trusted").unwrap();
    let hub = hub(&gate);
    let cfg = Config { folder_gate: Some(gate.clone()), ..Default::default() };
    let sha = folder_profiles::load_one(&cfg, &gate, &folder, "acme").unwrap().sha256.unwrap();
    for origin in [Origin::Web, Origin::Peer] {
        let mut c = connect(&hub, origin).await;
        for params in [
            json!({"folder": folder, "id": "acme"}),
            json!({"folder": folder, "id": "acme", "sha256": sha}),
        ] {
            let e = c.request(method::MUX_HARNESS_ENABLE, params).await.unwrap_err();
            assert!(e.contains("never from"), "{origin:?}: {e}");
        }
    }
    let state = folder_profiles::load_one(&cfg, &gate, &folder, "acme").unwrap().state;
    assert_eq!(state, folder_profiles::FolderState::NeedsEnable);

    // The local app gets the same prompt (its native relay asks for a fresh
    // user gesture before it sends the confirmation).
    let mut app = connect(&hub, Origin::LocalApp).await;
    let shown =
        app.request(method::MUX_HARNESS_ENABLE, json!({"folder": folder, "id": "acme"})).await;
    assert_eq!(shown.unwrap()["prompt"]["sha256"], sha);
}

#[tokio::test]
async fn the_cli_confirmation_is_the_enable_op_prompt_text() {
    use acpmux::cli::harness_folder::{Confirmation, confirmation};
    use std::os::unix::fs::PermissionsExt;
    let (folder, gate) = scratch("cli");
    let dir = folder_profiles::profile_dir(&folder);
    // An absolute program that is a file but not executable: a spawn cannot
    // run it, so neither prompt may name it as the program.
    let tool = folder.join("tool");
    write(&tool, "#!/bin/sh\n");
    write(&dir.join("plain.toml"), &format!("schema = 1\nid = \"plain\"\ncommand = {tool:?}\n"));
    // A bare program found on the profile's own PATH (relative to the
    // folder), as the spawn finds it.
    std::fs::create_dir_all(folder.join("bin")).unwrap();
    let agent = folder.join("bin").join("acme-agent");
    std::fs::write(&agent, "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(&agent, std::fs::Permissions::from_mode(0o700)).unwrap();
    write(
        &dir.join("onpath.toml"),
        "schema = 1\nid = \"onpath\"\ncommand = \"acme-agent\"\n\n[env]\nPATH = \"bin\"\n",
    );
    acpmux::trust::set(&gate.trust, &folder.to_string_lossy(), "trusted").unwrap();
    let hub = hub(&gate);
    let mut c = connect(&hub, Origin::Local).await;
    let cfg = Config { folder_gate: Some(gate.clone()), ..Default::default() };
    let mut programs = std::collections::BTreeMap::new();
    for id in ["acme", "plain", "onpath"] {
        let shown =
            c.request(method::MUX_HARNESS_ENABLE, json!({"folder": folder, "id": id})).await;
        let prompt = shown.unwrap()["prompt"].clone();
        let Confirmation::Ask { text, sha256 } = confirmation(&cfg, &folder, id).unwrap() else {
            panic!("{id}: the CLI found it already enabled");
        };
        assert_eq!(Some(text.as_str()), prompt["text"].as_str(), "{id}: CLI and app differ");
        assert_eq!(Some(sha256.as_str()), prompt["sha256"].as_str(), "{id}");
        programs.insert(id, prompt["program"].clone());
    }
    assert_eq!(programs["acme"], json!("/bin/echo"));
    assert_eq!(programs["plain"], Value::Null, "a file without the execute bit is no program");
    assert_eq!(programs["onpath"], json!(agent), "the profile's own PATH decides, as at spawn");
}
