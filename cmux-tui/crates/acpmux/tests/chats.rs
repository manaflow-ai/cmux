//! ALL-CHATS-ON-DEVICE S4: the daemon wires the chat index. Every store is
//! a synthetic fixture in a temp home; no test reads a real harness store.

use acpmux::chats::{ChatSources, launch_roots, lookup, refusal};
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const A: &str = "11111111-1111-4111-8111-111111111111";
const B: &str = "22222222-2222-4222-8222-222222222222";
const C: &str = "33333333-3333-4333-8333-333333333333";

struct Home(PathBuf);

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn home(tag: &str) -> Home {
    let base = std::env::temp_dir().join(format!("acpmux-chats-{tag}-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&base).unwrap();
    Home(std::fs::canonicalize(&base).unwrap())
}

fn user(id: &str, cwd: &str, text: &str) -> Value {
    json!({"type":"user","isSidechain":false,"cwd":cwd,"sessionId":id,
           "timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"user","content":text}})
}

fn write_session(projects: &Path, id: &str, records: &[Value]) -> PathBuf {
    let file = projects.join("-work-app").join(format!("{id}.jsonl"));
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let text: String = records.iter().map(|r| format!("{r}\n")).collect();
    std::fs::write(&file, text).unwrap();
    file
}

fn append(file: &Path, record: &Value) {
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new().append(true).open(file).unwrap();
    writeln!(f, "{record}").unwrap();
}

fn sources(home: &Path, env: &[(&str, PathBuf)]) -> ChatSources {
    let env: HashMap<String, String> =
        env.iter().map(|(k, v)| ((*k).to_owned(), v.display().to_string())).collect();
    ChatSources {
        home: home.to_path_buf(),
        acpmux_home: home.join(".acpmux"),
        env: Arc::new(move |key| env.get(key).cloned()),
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

    async fn next(&mut self) -> Value {
        let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv())
            .await
            .expect("a message within 20 s")
            .expect("connection open");
        serde_json::from_str(&line).unwrap()
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let v = self.next().await;
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let reply = self.call(m, params).await;
        assert!(reply.get("error").is_none(), "{m}: {reply}");
        reply["result"].clone()
    }

    /// The next `_acpmux/chat_changed` for `key` that `pred` accepts.
    async fn change(&mut self, key: &str, pred: impl Fn(&Value) -> bool) -> Value {
        loop {
            let v = self.next().await;
            if v["method"] == "_acpmux/chat_changed"
                && v["params"]["key"] == key
                && pred(&v["params"])
            {
                return v["params"].clone();
            }
        }
    }
}

fn keys(result: &Value) -> Vec<String> {
    result["chats"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["key"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn env_lookup_prefers_the_daemon_env_then_the_login_env() {
    let process =
        |k: &str| (k == "A").then(|| "daemon".to_owned()).or_else(|| (k == "E").then(String::new));
    let login = |k: &str| matches!(k, "A" | "B" | "E").then(|| "login".to_owned());
    assert_eq!(lookup("A", process, login).as_deref(), Some("daemon"));
    assert_eq!(lookup("B", process, login).as_deref(), Some("login"));
    assert_eq!(lookup("E", process, login).as_deref(), Some("login"), "empty counts as unset");
    assert_eq!(lookup("C", process, login), None);
}

#[test]
fn refusal_covers_guarded_folders_and_other_daemon_homes() {
    let home = Path::new("/Users/me");
    let acpmux = Path::new("/Users/me/.acpmux/tags/dev");
    for path in [
        "/Users/me/Documents/claude/projects",
        "/Users/me/.acpmux/tags/other/claude",
        "/Users/me/.cmux/chief/projects",
        "/Users/me/Library/Application Support/cmux/tags/x",
        "/Volumes/ext/.claude/projects",
    ] {
        assert!(refusal(Path::new(path), home, acpmux).is_some(), "{path} must be refused");
    }
    for path in ["/Users/me/.claude/projects", "/Users/me/.codex", "/opt/agents/.codex"] {
        assert_eq!(refusal(Path::new(path), home, acpmux), None, "{path} must be allowed");
    }
}

#[test]
fn launch_roots_come_from_profile_and_family_env() {
    let cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "claude-alt": {"argv": ["claude"], "env": {"CLAUDE_CONFIG_DIR": "/opt/alt-claude"}},
            "codex-alt": {"argv": ["codex"], "env": {"CODEX_HOME": "/opt/alt-codex"}},
            "rel": {"argv": ["claude"], "env": {"CLAUDE_CONFIG_DIR": "relative"}},
        },
        "defaults": {"claude": {"env": {"CLAUDE_CONFIG_DIR": "/opt/alt-claude"}}},
    }))
    .unwrap();
    let roots: Vec<(String, PathBuf)> =
        launch_roots(&cfg).into_iter().map(|r| (r.harness.id().to_owned(), r.path)).collect();
    assert_eq!(
        roots,
        vec![
            ("claude-code".to_owned(), PathBuf::from("/opt/alt-claude/projects")),
            ("codex".to_owned(), PathBuf::from("/opt/alt-codex")),
        ]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn chats_lists_synthetic_roots_with_filters_and_pages() {
    let h = home("list");
    let projects = h.0.join(".claude/projects");
    write_session(&projects, A, &[user(A, "/work/app", "fix the build")]);
    write_session(&projects, B, &[user(B, "/work/other", "write docs")]);
    let hub = hub();
    hub.start_chats(sources(&h.0, &[])).await.unwrap();
    let mut c = Client::new(&hub, Origin::Local);

    let all = c.ok("_acpmux/chats", json!({})).await;
    assert_eq!(all["ready"], true);
    let mut got = keys(&all);
    got.sort();
    assert_eq!(got, vec![format!("claude-code:{A}"), format!("claude-code:{B}")]);
    let a = all["chats"].as_array().unwrap().iter().find(|c| c["sessionId"] == A).unwrap();
    assert_eq!(
        (a["title"].as_str(), a["cwd"].as_str()),
        (Some("fix the build"), Some("/work/app"))
    );

    assert_eq!(
        keys(&c.ok("_acpmux/chats", json!({"query": "BUILD"})).await),
        vec![format!("claude-code:{A}")]
    );
    assert_eq!(
        keys(&c.ok("_acpmux/chats", json!({"folder": "/work/other/"})).await),
        vec![format!("claude-code:{B}")]
    );
    assert!(keys(&c.ok("_acpmux/chats", json!({"harness": "codex"})).await).is_empty());
    let first = c.ok("_acpmux/chats", json!({"limit": 1})).await;
    assert_eq!(keys(&first).len(), 1);
    let cursor = first["nextCursor"].as_str().unwrap().to_owned();
    let second = c.ok("_acpmux/chats", json!({"limit": 1, "cursor": cursor})).await;
    assert_eq!(keys(&second).len(), 1);
    assert_ne!(keys(&first), keys(&second));
    assert!(second["nextCursor"].is_null());
    let bad = c.call("_acpmux/chats", json!({"harness": "nope"})).await;
    assert!(bad["error"]["message"].as_str().unwrap().contains("unknown"), "{bad}");

    // The cache is written, owner-only.
    let cache = h.0.join(".acpmux/chat-index/v1.json");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&cache).unwrap().permissions().mode() & 0o777, 0o600);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn login_env_roots_are_used_and_guarded_roots_refused_unread() {
    let h = home("roots");
    let alt = h.0.join("alt-claude");
    write_session(&alt.join("projects"), A, &[user(A, "/work/app", "from the alt home")]);
    let guarded = h.0.join("Documents/codex-home");
    std::fs::create_dir_all(&guarded).unwrap();
    let hub = hub();
    hub.start_chats(sources(
        &h.0,
        &[("CLAUDE_CONFIG_DIR", alt.clone()), ("CODEX_HOME", guarded.clone())],
    ))
    .await
    .unwrap();
    let mut c = Client::new(&hub, Origin::Local);

    assert_eq!(keys(&c.ok("_acpmux/chats", json!({})).await), vec![format!("claude-code:{A}")]);
    let roots = c.ok("_acpmux/chat_roots", json!({})).await;
    let listed: Vec<&str> =
        roots["roots"].as_array().unwrap().iter().map(|r| r["path"].as_str().unwrap()).collect();
    assert_eq!(listed, vec![alt.join("projects").to_str().unwrap()]);
    assert_eq!(roots["roots"][0]["source"], "env");
    let refused = roots["refused"].as_array().unwrap();
    assert_eq!(refused.len(), 1, "{roots}");
    assert_eq!(refused[0]["path"].as_str(), guarded.to_str());
    assert!(refused[0]["reason"].as_str().unwrap().contains("privacy-protected"), "{roots}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn watch_pushes_new_grown_and_removed_chats() {
    let h = home("watch");
    let projects = h.0.join(".claude/projects");
    write_session(&projects, A, &[user(A, "/work/app", "first chat")]);
    let hub = hub();
    hub.start_chats(sources(&h.0, &[])).await.unwrap();
    let mut c = Client::new(&hub, Origin::Local);

    let snapshot = c.ok("_acpmux/chats_watch", json!({})).await;
    assert_eq!(keys(&snapshot), vec![format!("claude-code:{A}")]);

    let file = write_session(&projects, C, &[user(C, "/work/app", "a new chat")]);
    let key = format!("claude-code:{C}");
    let added = c.change(&key, |p| p["kind"] == "upsert").await;
    assert_eq!(added["chat"]["title"], "a new chat");
    let count = added["chat"]["messageCount"].as_u64().unwrap();

    append(&file, &user(C, "/work/app", "a second prompt"));
    c.change(&key, |p| p["chat"]["messageCount"].as_u64().is_some_and(|n| n > count)).await;

    std::fs::remove_file(&file).unwrap();
    c.change(&key, |p| p["kind"] == "removed").await;

    let off = c.ok("_acpmux/chats_watch", json!({"enabled": false})).await;
    assert_eq!(off["watching"], false);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reported_transcript_adds_its_root_and_persists() {
    let h = home("record");
    let odd = h.0.join("odd-home/projects");
    let file = write_session(&odd, B, &[user(B, "/work/app", "odd home chat")]);
    let hub = hub();
    hub.start_chats(sources(&h.0, &[])).await.unwrap();
    let mut c = Client::new(&hub, Origin::Local);
    assert!(keys(&c.ok("_acpmux/chats", json!({})).await).is_empty());

    let added = c
        .ok("_acpmux/chat_roots_record", json!({"harness": "claude-code", "transcriptPath": file}))
        .await;
    assert_eq!(added["added"], true);
    assert_eq!(keys(&c.ok("_acpmux/chats", json!({})).await), vec![format!("claude-code:{B}")]);
    let roots = c.ok("_acpmux/chat_roots", json!({})).await;
    assert_eq!(roots["roots"][0]["source"], "recorded");

    // Another tag's daemon home is never recorded.
    let other = h.0.join(".acpmux/tags/other/claude/projects/-x").join(format!("{C}.jsonl"));
    let refused = c
        .call(
            "_acpmux/chat_roots_record",
            json!({"harness": "claude-code", "transcriptPath": other}),
        )
        .await;
    assert!(
        refused["error"]["message"].as_str().unwrap().contains("acpmux daemon home"),
        "{refused}"
    );

    // A new daemon on the same acpmux home finds the recorded root in its file.
    let again = self::hub();
    again.start_chats(sources(&h.0, &[])).await.unwrap();
    let mut c2 = Client::new(&again, Origin::Local);
    assert_eq!(keys(&c2.ok("_acpmux/chats", json!({})).await), vec![format!("claude-code:{B}")]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn websocket_origins_never_get_chats() {
    let h = home("remote");
    write_session(&h.0.join(".claude/projects"), A, &[user(A, "/work/app", "private title")]);
    let hub = hub();
    hub.start_chats(sources(&h.0, &[])).await.unwrap();
    for origin in [Origin::Web, Origin::LocalApp, Origin::Peer] {
        let mut c = Client::new(&hub, origin);
        for m in [
            "_acpmux/chats",
            "_acpmux/chats_watch",
            "_acpmux/chat_roots",
            "_acpmux/chat_roots_record",
            "_acpmux/chat_open",
        ] {
            let reply = c.call(m, json!({})).await;
            assert_eq!(reply["error"]["code"], -32601, "{origin:?} {m}: {reply}");
            assert!(!reply.to_string().contains("private title"));
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn chats_answer_not_ready_before_the_index_starts() {
    let hub = hub();
    let mut c = Client::new(&hub, Origin::Local);
    let reply = c.ok("_acpmux/chats", json!({})).await;
    assert_eq!((reply["ready"].clone(), reply["chats"].clone()), (json!(false), json!([])));
}
