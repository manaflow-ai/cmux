//! The cmux-subsessions `send_message` tool's `attachments` (`subsession_mcp.rs`, `attach.rs`):
//! a parent sends its child a screenshot, which the child's agent gets as an image and its
//! transcript names, saved owner-only in the child's uploads; a file too large to go inline goes
//! as an upload named by reference. A list of anything but attachment blocks is refused. One test function: the settings file is read from this process's env.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use sha2::Digest;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    /// A connection to `hub`; with `caller`, the one that session's tools open.
    async fn new(hub: &Arc<Hub>, caller: Option<&str>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        let mut c = Client(in_tx, out_rx, 0);
        if let Some(id) = caller {
            let token = acpmux::hub::person::caller_token(id);
            let caller = json!({"callerSession": {"sessionId": id, "token": token}});
            c.ok("initialize", json!({"protocolVersion": 1, "_meta": {"acpmux": caller}})).await;
        }
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let r = self.call(m, params).await;
        assert!(r.get("error").is_none(), "{m}: {r}");
        r["result"].clone()
    }
}

#[tokio::test]
async fn send_message_carries_attachments_to_a_child() {
    let root = std::env::temp_dir().join(format!("acpmux-attach-family-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let settings = root.join("cmux-next.json");
    std::fs::write(&settings, r#"{"agents": {"subsessions": {"enabled": true}}}"#).unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
        std::env::set_var("FLEET_REGISTRY", root.join("fleet-registry.json"));
    }
    // A registry that lists no machine: this host is uncapped. A set
    // FLEET_REGISTRY that is missing refuses every create (`hub/admission.rs`).
    std::fs::write(root.join("fleet-registry.json"), r#"{"machines": {}}"#).unwrap();
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let mut app = Client::new(&hub, None).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
    let parent = app.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned();
    let mut p = Client::new(&hub, Some(&parent)).await;
    let child = p.ok("_acpmux/subsession/start", json!({"prompt": "echo hi", "name": "Kid"})).await;
    let child = child["sessionId"].as_str().unwrap().to_owned();
    let ready = json!({"sessions": [child], "until": ["ready"], "timeoutMs": 20000});
    p.ok("_acpmux/wait", ready.clone()).await;

    // What the tool sends once it read the file (`attach::blocks_for`).
    let mut shot = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
    shot.resize(1024, 5);
    let blocks = vec![acpmux::attach::block("shot.png", &shot)];
    // `send_message` asks first whether this agent may send files; the check sends nothing.
    let check = json!({"sessionId": child, "text": "", "attachCheck": true});
    assert_eq!(p.ok("_acpmux/subsession/send", check).await, json!({}));
    let send = json!({"sessionId": child, "text": "see this", "attachments": blocks});
    p.ok("_acpmux/subsession/send", send).await;
    p.ok("_acpmux/wait", ready.clone()).await;
    let sha: String = sha2::Sha256::digest(&shot).iter().map(|b| format!("{b:02x}")).collect();
    let got = p.ok("_acpmux/subsession/get", json!({"sessionId": child})).await;
    assert!(
        got["lastReply"].as_str().unwrap_or_default().contains(&format!("image:{sha}")),
        "{got}"
    );
    let page =
        app.ok("_acpmux/events", json!({"sessionId": child, "kinds": ["user_message"]})).await;
    let sent = page["events"].as_array().unwrap().last().unwrap()["msg"].clone();
    assert_eq!(sent["images"][0]["id"], sha, "{sent}");
    assert_eq!(sent["_meta"]["provenance"]["from"], parent, "{sent}");
    let uploads = root.join("home/uploads").join(&child);
    let folder = std::fs::read_dir(&uploads).unwrap().next().unwrap().unwrap().path();
    let saved = folder.join("shot.png");
    assert_eq!(std::fs::read(&saved).unwrap(), shot);
    assert_eq!(std::fs::metadata(&saved).unwrap().permissions().mode() & 0o777, 0o600);

    // A file too large to go inline: uploaded to the child first, then named by reference.
    let mut large = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
    large.resize(6 << 20, 6);
    use base64::Engine;
    let begin = json!({"sessionId": child, "fileName": "large.png", "size": large.len()});
    let up = p.ok("_acpmux/file_put_begin", begin).await["uploadId"].as_str().unwrap().to_owned();
    for (n, piece) in large.chunks(512 << 10).enumerate() {
        let data = base64::engine::general_purpose::STANDARD.encode(piece);
        let put = json!({"sessionId": child, "uploadId": up, "offset": n << 19, "data": data});
        p.ok("_acpmux/file_put_chunk", put).await;
    }
    let finish = json!({"sessionId": child, "uploadId": up, "fileName": "large.png",
        "size": large.len()});
    let path = p.ok("_acpmux/file_put_finish", finish).await["path"].as_str().unwrap().to_owned();
    let by_ref = json!({"type": "image", "mimeType": "image/png",
        "_meta": {"acpmux": {"upload": {"uploadId": up, "fileName": "large.png"}}}});
    let send = json!({"sessionId": child, "text": "and this", "attachments": [by_ref]});
    p.ok("_acpmux/subsession/send", send).await;
    p.ok("_acpmux/wait", ready.clone()).await;
    let got = p.ok("_acpmux/subsession/get", json!({"sessionId": child})).await;
    let reply = got["lastReply"].as_str().unwrap_or_default();
    assert!(reply.contains(&format!("resource_link:large.png:image/png:file://{path}")), "{got}");
    assert_eq!(std::fs::read(&path).unwrap(), large);
    let saved_dirs = std::fs::read_dir(&uploads).unwrap().count();

    // Text and inline files together past one JSON-RPC message: refused, and nothing more is
    // saved (`attach::blocks_for` sends such files by reference).
    let big = vec![acpmux::attach::block("big.bin", &vec![0u8; 8 << 20])];
    let send = json!({"sessionId": child, "text": "x".repeat(5 << 20), "attachments": big});
    let r = p.call("_acpmux/subsession/send", send).await;
    let shown: String = r.to_string().chars().take(300).collect();
    assert_eq!(r["error"]["data"]["reason"], "attach.tooLarge", "{shown}");
    assert_eq!(std::fs::read_dir(&uploads).unwrap().count(), saved_dirs);

    // Only attachment blocks: the tool reads the files, a caller never names bytes otherwise.
    let bad =
        json!({"sessionId": child, "text": "x", "attachments": [{"type": "text", "text": "t"}]});
    let r = p.call("_acpmux/subsession/send", bad).await;
    assert!(r.get("error").is_some(), "{r}");
    let _ = std::fs::remove_dir_all(&root);
}
