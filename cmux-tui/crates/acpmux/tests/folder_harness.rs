//! Folder harness profiles (BRING-YOUR-OWN-HARNESS H4) through the real
//! protocol handler: session/new starts a folder profile only when its folder
//! is trusted, the user enabled these bytes, and the chat folder is inside it.

use acpmux::config::folder_profiles::{self, FolderGate};
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, RpcError, method};
use acpmux::server::serve_connection;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::sync::mpsc;

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl Client {
    async fn request(&mut self, m: &str, params: Value) -> Result<Value, String> {
        self.call(m, params).await.map_err(|e| e.message)
    }

    async fn call(&mut self, m: &str, params: Value) -> Result<Value, RpcError> {
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
                    Some(e) => Err(e),
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

/// A scratch root with `repo/.cmux/harnesses/fakefolder.toml` (the fake agent).
fn scratch(name: &str) -> (PathBuf, PathBuf, FolderGate) {
    let root = std::env::temp_dir().join(format!("acpmux-folder-it-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let folder = root.join("repo");
    std::fs::create_dir_all(folder_profiles::profile_dir(&folder)).unwrap();
    std::fs::create_dir_all(folder.join("sub")).unwrap();
    let root = std::fs::canonicalize(&root).unwrap();
    let folder = root.join("repo");
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    write(
        &folder_profiles::profile_dir(&folder).join("fakefolder.toml"),
        &format!("schema = 1\nid = \"fakefolder\"\ncommand = \"python3\"\nargs = [{fake:?}]\n"),
    );
    let gate = FolderGate {
        enable_record: root.join("acpmux").join(folder_profiles::ENABLE_RECORD),
        trust: acpmux::trust::Paths {
            claude_json: root.join("claude.json"),
            codex_config: root.join("config.toml"),
            record: root.join("acpmux").join("trust.json"),
            agent_home: None,
        },
    };
    (root, folder, gate)
}

async fn connect(gate: &FolderGate) -> Client {
    let mut cfg = Config { folder_gate: Some(gate.clone()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub, in_rx, out_tx));
    let mut client = Client { tx: in_tx, rx: out_rx, next: 0 };
    client
        .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();
    client
}

fn new_params(cwd: &Path) -> Value {
    json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": "fakefolder"}}})
}

#[tokio::test]
async fn session_new_starts_a_folder_profile_only_when_trusted_enabled_and_inside() {
    let (root, folder, gate) = scratch("gate");
    let mut c = connect(&gate).await;
    let inside = folder.join("sub");

    let e = c.request(method::SESSION_NEW, new_params(&inside)).await.unwrap_err();
    assert!(e.contains("not trusted"), "{e}");

    acpmux::trust::set(&gate.trust, &folder.to_string_lossy(), "trusted").unwrap();
    let e = c.request(method::SESSION_NEW, new_params(&inside)).await.unwrap_err();
    assert!(e.contains("cmux harness enable fakefolder"), "{e}");

    let cfg = Config { folder_gate: Some(gate.clone()), ..Default::default() };
    let sha = folder_profiles::load_one(&cfg, &gate, &folder, "fakefolder")
        .and_then(|fp| fp.sha256)
        .expect("sha256");
    folder_profiles::enable(&cfg, &gate, &folder, "fakefolder", &sha).unwrap();

    let e = c.request(method::SESSION_NEW, new_params(&root)).await.unwrap_err();
    assert!(e.contains("unknown harness"), "{e}");

    let s = c.request(method::SESSION_NEW, new_params(&inside)).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]}),
        )
        .await
        .unwrap();
    assert_eq!(r["stopReason"], "end_turn");

    // An edit after enable stops new sessions until the user confirms again.
    let path = folder_profiles::profile_dir(&folder).join("fakefolder.toml");
    let text = std::fs::read_to_string(&path).unwrap();
    write(&path, &format!("{text}# edited\n"));
    let e = c.request(method::SESSION_NEW, new_params(&inside)).await.unwrap_err();
    assert!(e.contains("not enabled"), "{e}");
}

#[tokio::test]
async fn session_new_refusals_of_a_folder_profile_carry_data_for_the_app() {
    let (_root, folder, gate) = scratch("data");
    let mut c = connect(&gate).await;
    let inside = folder.join("sub");
    let want = |reason: &str| json!({"reason": reason, "harness": "fakefolder", "folder": folder});

    // The app offers the folder's Trust question for this one...
    let e = c.call(method::SESSION_NEW, new_params(&inside)).await.unwrap_err();
    assert_eq!(e.code, -32602, "{e:?}");
    assert!(e.message.contains("not trusted"), "{}", e.message);
    assert_eq!(e.data, Some(want("harness.needs_trust")), "{e:?}");

    // ...and its Enable harness sheet for this one. The text stays the same.
    acpmux::trust::set(&gate.trust, &folder.to_string_lossy(), "trusted").unwrap();
    let e = c.call(method::SESSION_NEW, new_params(&inside)).await.unwrap_err();
    assert_eq!(e.code, -32602, "{e:?}");
    assert!(e.message.contains("cmux harness enable fakefolder"), "{}", e.message);
    assert_eq!(e.data, Some(want("harness.needs_enable")), "{e:?}");
}
