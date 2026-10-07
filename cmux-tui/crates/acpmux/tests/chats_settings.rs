//! ALL-CHATS-ON-DEVICE S8: the app's chat settings (`_acpmux/chat_settings`):
//! cmux.json `agents.chats.enabled`, `.discovery`, `.roots` and the roots
//! managed config adds. Every store is a synthetic fixture in a temp home.

use acpmux::chats::{ChatService, ChatSources};
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const A: &str = "11111111-1111-4111-8111-111111111111";
const B: &str = "22222222-2222-4222-8222-222222222222";

struct Home(PathBuf);

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn home(tag: &str) -> Home {
    let base = std::env::temp_dir().join(format!("acpmux-chatset-{tag}-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&base).unwrap();
    Home(std::fs::canonicalize(&base).unwrap())
}

/// A Claude session file under `<claude home>/projects`.
fn claude_session(claude_home: &Path, id: &str, text: &str) {
    let file = claude_home.join("projects/-work-app").join(format!("{id}.jsonl"));
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let record = json!({"type":"user","isSidechain":false,"cwd":"/work/app","sessionId":id,
        "timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"user","content":text}});
    std::fs::write(&file, format!("{record}\n")).unwrap();
}

fn sources(home: &Path) -> ChatSources {
    ChatSources {
        home: home.to_path_buf(),
        acpmux_home: home.join(".acpmux"),
        env: Arc::new(|_| None),
        launch_roots: Vec::new(),
        user_roots: Vec::new(),
    }
}

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", "-c", "pass"]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
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

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv())
                .await
                .expect("a message within 20 s")
                .expect("connection open");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    /// The next notification named `method`.
    async fn notification(&mut self, method: &str) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv())
                .await
                .expect("a message within 20 s")
                .expect("connection open");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v["method"] == method {
                return v["params"].clone();
            }
        }
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let reply = self.call(m, params).await;
        assert!(reply.get("error").is_none(), "{m}: {reply}");
        reply["result"].clone()
    }
}

fn keys(result: &Value) -> Vec<String> {
    let mut keys: Vec<String> = result["chats"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["key"].as_str().unwrap().to_owned())
        .collect();
    keys.sort();
    keys
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn turning_chats_off_hides_every_chat_and_survives_a_restart() {
    let h = home("off");
    claude_session(&h.0.join(".claude"), A, "fix the build");
    let hub = hub();
    hub.start_chats(sources(&h.0)).await.unwrap();
    let mut c = Client::new(&hub, Origin::Local);
    let on = c.ok("_acpmux/chats", json!({})).await;
    assert_eq!((on["enabled"].clone(), keys(&on)), (json!(true), vec![format!("claude-code:{A}")]));

    let applied = c.ok("_acpmux/chat_settings", json!({"enabled": false})).await;
    assert_eq!(applied["applied"], true);
    assert_eq!(applied["roots"], json!([]), "{applied}");
    let off = c.ok("_acpmux/chats", json!({})).await;
    assert_eq!((off["enabled"].clone(), keys(&off)), (json!(false), Vec::<String>::new()));

    // The settings are in the daemon's file (owner-only), so a restart keeps them.
    let file = h.0.join(".acpmux/chat-settings.json");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
    }
    let restarted = ChatService::start(sources(&h.0));
    assert!(!restarted.enabled());
    assert!(restarted.list(&Default::default()).0.is_empty());

    let back = c.ok("_acpmux/chat_settings", json!({"enabled": true})).await;
    assert_eq!(back["roots"].as_array().map(Vec::len), Some(1), "{back}");
    let again = c.ok("_acpmux/chats", json!({})).await;
    assert_eq!(keys(&again), vec![format!("claude-code:{A}")]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn with_discovery_off_only_the_listed_roots_are_read() {
    let h = home("disc");
    claude_session(&h.0.join(".claude"), A, "default store");
    let work = h.0.join("work-claude");
    claude_session(&work, B, "work store");
    let hub = hub();
    hub.start_chats(sources(&h.0)).await.unwrap();
    let mut c = Client::new(&hub, Origin::Local);

    // Discovery on: the default store and the listed folder (a Claude home).
    let both = c
        .ok(
            "_acpmux/chat_settings",
            json!({"discovery": true, "roots": [work.display().to_string()]}),
        )
        .await;
    assert_eq!(both["settingsRefused"], json!([]), "{both}");
    let all = c.ok("_acpmux/chats", json!({})).await;
    assert_eq!(keys(&all), vec![format!("claude-code:{A}"), format!("claude-code:{B}")]);

    // Discovery off: only the listed folder.
    c.ok(
        "_acpmux/chat_settings",
        json!({"discovery": false, "roots": [work.display().to_string()]}),
    )
    .await;
    assert_eq!(keys(&c.ok("_acpmux/chats", json!({})).await), vec![format!("claude-code:{B}")]);

    // A listed folder that is also a default store stays when discovery is off.
    let claude = h.0.join(".claude").display().to_string();
    let view =
        c.ok("_acpmux/chat_settings", json!({"discovery": false, "managedRoots": [claude]})).await;
    assert_eq!(view["roots"][0]["source"], "user", "{view}");
    assert_eq!(keys(&c.ok("_acpmux/chats", json!({})).await), vec![format!("claude-code:{A}")]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn refused_settings_roots_carry_their_reason() {
    let h = home("refuse");
    let empty = h.0.join("empty");
    std::fs::create_dir_all(&empty).unwrap();
    let hub = hub();
    hub.start_chats(sources(&h.0)).await.unwrap();
    let mut c = Client::new(&hub, Origin::Local);
    let roots = [
        h.0.display().to_string(),
        h.0.join("Documents/agents").display().to_string(),
        empty.display().to_string(),
        "relative/claude".to_owned(),
    ];
    let managed = [h.0.join("Library/Mail").display().to_string()];
    let view =
        c.ok("_acpmux/chat_settings", json!({"roots": roots, "managedRoots": managed})).await;
    let refused = view["settingsRefused"].as_array().unwrap();
    let reason = |path: &str| {
        refused
            .iter()
            .find(|r| r["path"] == path)
            .map(|r| (r["reason"].as_str().unwrap_or("").to_owned(), r["managed"] == true))
            .unwrap_or_else(|| panic!("{path} not refused: {view}"))
    };
    assert!(reason(&roots[0]).0.contains("home folder"), "{view}");
    assert!(reason(&roots[1]).0.contains("privacy-protected"), "{view}");
    assert!(reason(&roots[2]).0.contains("no chat folder"), "{view}");
    assert!(reason(&roots[3]).0.contains("absolute"), "{view}");
    assert!(reason(&managed[0]).1, "a managed root says so: {view}");
    assert_eq!(view["roots"], json!([]));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn chat_settings_reject_bad_params_and_remote_callers() {
    let h = home("params");
    let hub = hub();
    hub.start_chats(sources(&h.0)).await.unwrap();
    let mut local = Client::new(&hub, Origin::Local);
    for bad in [json!({"enabled": "yes"}), json!({"roots": "/x"}), json!({"roots": [1]})] {
        let reply = local.call("_acpmux/chat_settings", bad.clone()).await;
        assert!(reply.get("error").is_some(), "{bad} must fail: {reply}");
    }
    let mut web = Client::new(&hub, Origin::Web);
    let reply = web.call("_acpmux/chat_settings", json!({"enabled": false})).await;
    assert_eq!(reply["error"]["code"], -32601, "{reply}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_watch_that_arrives_before_the_index_starts_is_served_once_it_starts() {
    let h = home("early");
    claude_session(&h.0.join(".claude"), A, "fix the build");
    let hub = hub();
    // The app connects at launch, before the daemon has started its index.
    let mut c = Client::new(&hub, Origin::Local);
    let early = c.ok("_acpmux/chats_watch", json!({})).await;
    assert_eq!(early["ready"], false, "{early}");
    hub.start_chats(sources(&h.0)).await.unwrap();
    // The waiting watch is told to list again, then gets live changes.
    c.notification("_acpmux/chats_lagged").await;
    assert_eq!(keys(&c.ok("_acpmux/chats", json!({})).await), vec![format!("claude-code:{A}")]);
    claude_session(&h.0.join(".claude"), B, "write docs");
    let changed = c.notification("_acpmux/chat_changed").await;
    assert_eq!(changed["key"], format!("claude-code:{B}"), "{changed}");
}
