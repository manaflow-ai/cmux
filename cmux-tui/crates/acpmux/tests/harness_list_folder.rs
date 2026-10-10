//! `_acpmux/harnesses {cwd}` (BRING-YOUR-OWN-HARNESS H4): the harness list
//! also names the folder profiles a chat in `cwd` would see, with their
//! state, so the app can show them and offer Trust or Enable. It never shows
//! a folder file's command line or env, and a Web or peer connection never
//! gets the list.

use acpmux::config::folder_profiles::{self, FolderGate};
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::collections::BTreeMap;
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
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

const SECRET_ARGS: &str = "--token-file ./very-private-arg";

fn profile(id: &str, name: &str) -> String {
    format!(
        "schema = 1\nid = \"{id}\"\nname = \"{name}\"\ncommand = \"/bin/echo\"\nargs = [\"{SECRET_ARGS}\"]\n\n[env]\nNODE_OPTIONS = \"--require ./hidden.js\"\n"
    )
}

/// root/.cmux/harnesses: outer, acme (hidden by repo's acme).
/// root/repo/.cmux/harnesses: acme, fresh, broken. Records in root/acpmux.
fn scratch() -> (PathBuf, PathBuf, FolderGate) {
    let root = std::env::temp_dir().join(format!("acpmux-list-folder-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("repo").join("sub")).unwrap();
    let root = std::fs::canonicalize(&root).unwrap();
    let repo = root.join("repo");
    let outer = folder_profiles::profile_dir(&root);
    write(&outer.join("outer.toml"), &profile("outer", "Outer"));
    write(&outer.join("acme.toml"), &profile("acme", "Far Acme"));
    let inner = folder_profiles::profile_dir(&repo);
    write(&inner.join("acme.toml"), &profile("acme", "Acme"));
    write(&inner.join("fresh.toml"), &profile("fresh", "Fresh"));
    write(&inner.join("broken.toml"), "schema = 1\nid = \"broken\"\n");
    let gate = FolderGate {
        enable_record: root.join("acpmux").join(folder_profiles::ENABLE_RECORD),
        trust: acpmux::trust::Paths {
            claude_json: root.join("claude.json"),
            codex_config: root.join("config.toml"),
            record: root.join("acpmux").join("trust.json"),
            agent_home: None,
        },
    };
    (root, repo, gate)
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
async fn the_harness_list_names_folder_profiles_of_a_cwd_with_their_states() {
    let (root, repo, gate) = scratch();
    acpmux::trust::set(&gate.trust, &repo.to_string_lossy(), "trusted").unwrap();
    let cfg = Config { folder_gate: Some(gate.clone()), ..Default::default() };
    let sha = folder_profiles::load_one(&cfg, &gate, &repo, "acme").unwrap().sha256.unwrap();
    folder_profiles::enable(&cfg, &gate, &repo, "acme", &sha).unwrap();
    let hub = hub(&gate);
    let mut c = connect(&hub, Origin::Local).await;

    let plain = c.request(method::MUX_HARNESSES, json!({})).await.unwrap();
    assert!(plain.get("folderProfiles").is_none(), "no cwd, no folder profiles: {plain}");

    let cwd = repo.join("sub");
    let reply = c.request(method::MUX_HARNESSES, json!({"cwd": cwd})).await.unwrap();
    let rows = reply["folderProfiles"].as_array().expect("folderProfiles").clone();
    let by_id: BTreeMap<String, Value> =
        rows.iter().map(|r| (r["id"].as_str().unwrap().to_owned(), r.clone())).collect();
    let state = |id: &str| by_id[id]["state"].as_str().unwrap().to_owned();
    assert_eq!(rows.len(), 4, "{rows:#?}");
    assert_eq!(state("acme"), "enabled");
    assert_eq!(state("fresh"), "needs-enable");
    assert_eq!(state("broken"), "error");
    assert_eq!(state("outer"), "needs-trust");
    // The nearest folder wins an id.
    assert_eq!(by_id["acme"]["folder"], json!(repo));
    assert_eq!(by_id["acme"]["displayName"], "Acme");
    assert_eq!(by_id["outer"]["folder"], json!(root));
    assert_eq!(by_id["fresh"]["kind"], "acp");
    assert_eq!(by_id["fresh"]["family"], "fresh");
    assert!(by_id["broken"]["diagnostics"].as_array().is_some_and(|d| !d.is_empty()));
    let text = serde_json::to_string(&rows).unwrap();
    for hidden in ["/bin/echo", SECRET_ARGS, "hidden.js", "argv", "\"env\""] {
        assert!(!text.contains(hidden), "the list shows {hidden:?}: {text}");
    }

    // A relative cwd is refused.
    let e = c.request(method::MUX_HARNESSES, json!({"cwd": "repo/sub"})).await.unwrap_err();
    assert!(e.contains("absolute"), "{e}");

    // A Web or peer connection never gets folder profiles.
    for origin in [Origin::Web, Origin::Peer] {
        let mut remote = connect(&hub, origin).await;
        if let Ok(reply) = remote.request(method::MUX_HARNESSES, json!({"cwd": cwd})).await {
            assert!(reply.get("folderProfiles").is_none(), "{origin:?}: {reply}");
        }
    }
}
