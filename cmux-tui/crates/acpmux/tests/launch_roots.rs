//! Launch roots (ALL-CHATS-ON-DEVICE C3, BYOH design section 7): a spawn
//! records in the session meta the chat store roots its env names, after
//! `${cwd}` expansion, and the record survives a reload of the store file.

use acpmux::config::{Config, HarnessProfile, ProfileMeta};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::serve_connection;
use acpmux::store::HarnessRoot;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::sync::mpsc;

async fn request(
    tx: &mpsc::Sender<String>,
    rx: &mut mpsc::Receiver<String>,
    id: i64,
    m: &str,
    params: Value,
) -> Result<Value, String> {
    tx.send(Message::request(id, m, params).to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(20), rx.recv())
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

fn scratch() -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-launch-roots-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("work/.claude/projects")).unwrap();
    std::fs::create_dir_all(root.join("codexhome")).unwrap();
    std::fs::create_dir_all(root.join("acme/sessions")).unwrap();
    std::fs::create_dir_all(root.join("state")).unwrap();
    std::fs::canonicalize(&root).unwrap()
}

fn config(root: &Path) -> Config {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg = Config::default();
    let env = [
        ("CLAUDE_CONFIG_DIR", "${cwd}/.claude".to_owned()),
        ("CODEX_HOME", root.join("codexhome").to_string_lossy().into_owned()),
        ("XDG_DATA_HOME", root.join("missing").to_string_lossy().into_owned()),
        ("ACME_HOME", root.join("acme").to_string_lossy().into_owned()),
        ("ACME_TOKEN", "not-a-path".to_owned()),
    ];
    cfg.harnesses.insert(
        "fakeroots".into(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
            env: env.into_iter().map(|(k, v)| (k.to_owned(), v)).collect(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    let sessions = serde_json::from_value(json!({
        "adapter": "jsonl",
        "roots": ["${ACME_HOME}/sessions", "${ACME_TOKEN}/x", "~/never-created-acpmux-root"],
        "files": "*.jsonl",
    }))
    .unwrap();
    cfg.profile_meta
        .insert("fakeroots".into(), ProfileMeta { sessions: Some(sessions), ..Default::default() });
    cfg
}

#[tokio::test]
async fn a_spawn_records_the_store_roots_its_env_names_and_they_survive_a_reload() {
    let root = scratch();
    let cfg = config(&root);
    let state = root.join("state");
    let store_cfg = cfg.store.clone();
    let store = acpmux::store::open(&store_cfg, &state).unwrap();
    let hub = Hub::new(cfg, store);
    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub, in_rx, out_tx));
    request(&tx, &mut rx, 1, method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
    let cwd = root.join("work");
    let params =
        json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": "fakeroots"}}});
    let s = request(&tx, &mut rx, 2, method::SESSION_NEW, params).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();

    // A fresh store over the same folder reads what the spawn wrote.
    let reread = acpmux::store::open(&store_cfg, &state).unwrap();
    let meta = reread.load(&id).unwrap().expect("the session meta file");
    let mut roots = meta.harness_roots.clone();
    roots.sort_by(|a, b| a.path.cmp(&b.path));
    let expected = vec![
        HarnessRoot { harness: "fakeroots".into(), path: root.join("acme/sessions") },
        HarnessRoot { harness: "codex".into(), path: root.join("codexhome") },
        HarnessRoot { harness: "claude-code".into(), path: root.join("work/.claude/projects") },
    ];
    assert_eq!(roots, expected);
    let text = serde_json::to_string(&meta).unwrap();
    assert!(text.contains("\"harnessRoots\""), "{text}");
    assert!(!text.contains("not-a-path"), "{text}");
}
