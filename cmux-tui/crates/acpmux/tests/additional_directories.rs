//! A chat started with `additionalDirectories` (ACP `session/new`) can see those folders beside
//! its own: every start of its harness, the first, a respawn and a restart, gets them. Claude
//! Code takes them as `--add-dir DIR`; an ACP harness in its `session/new` and `session/load`.
//! A chat needs no project to have them (Leo: "and you can also just start with nothing"), and
//! the session's summary lists them for the pane.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
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
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fakeclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"},
            "fake": {"argv": ["python3", FAKE_AGENT]},
        },
        "defaultHarness": "fakeclaude",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    /// The reply (Ok result or Err error object) and the text streamed before it.
    async fn call(&mut self, m: &str, params: Value) -> (Result<Value, Value>, String) {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        let mut text = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return match v.get("error") {
                    Some(e) => (Err(e.clone()), text),
                    None => (Ok(v["result"].clone()), text),
                };
            }
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
    }

    async fn new_session(
        &mut self,
        harness: &str,
        cwd: Option<&Path>,
        dirs: Value,
    ) -> Result<Value, Value> {
        let mut params = json!({"mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
        if let Some(cwd) = cwd {
            params["cwd"] = json!(cwd);
        }
        if !dirs.is_null() {
            params["additionalDirectories"] = dirs;
        }
        self.call("session/new", params).await.0
    }

    /// What a prompt streams back: the fake Claude Code its argv, the fake agent the answer to
    /// `text`.
    async fn said(&mut self, session: &str, text: &str) -> String {
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]});
        let (reply, said) = self.call("session/prompt", prompt).await;
        reply.expect("session/prompt");
        said
    }

    /// The `additionalDirectories` the fake ACP agent's last session/new or load carried.
    async fn dirs(&mut self, session: &str) -> Value {
        let said = self.said(session, "dirs").await;
        serde_json::from_str(&said).unwrap_or_else(|e| panic!("{e}: {said}"))
    }

    /// The `--add-dir` values of the fake Claude Code's argv.
    async fn add_dirs(&mut self, session: &str) -> Vec<String> {
        let said = self.said(session, "hi").await;
        let args: Vec<String> =
            serde_json::from_str(&said).unwrap_or_else(|e| panic!("{e}: {said}"));
        args.windows(2).filter(|w| w[0] == "--add-dir").map(|w| w[1].clone()).collect()
    }
}

/// Two folders made for the test, canonical (a macOS temp dir is behind `/var` -> `/private/var`).
fn folders() -> (tempfile::TempDir, PathBuf, PathBuf) {
    let root = tempfile::tempdir().unwrap();
    let a = root.path().join("notes");
    let b = root.path().join("data set");
    std::fs::create_dir_all(&a).unwrap();
    std::fs::create_dir_all(&b).unwrap();
    let (a, b) = (std::fs::canonicalize(a).unwrap(), std::fs::canonicalize(b).unwrap());
    (root, a, b)
}

fn s(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

#[tokio::test]
async fn claude_code_gets_every_folder_at_every_start() {
    let _hermetic = &HERMETIC;
    let hub = hub();
    let mut c = Client::new(&hub);
    let (_root, a, b) = folders();

    let created = c
        .new_session("fakeclaude", Some(&std::env::temp_dir()), json!([a, b]))
        .await
        .expect("session/new");
    assert_eq!(
        created.pointer("/_meta/acpmux/additionalDirectories"),
        Some(&json!([s(&a), s(&b)])),
        "the summary lists them: {created}"
    );
    let id = created["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(c.add_dirs(&id).await, [s(&a), s(&b)], "the first start");

    // Its process ends; the next prompt respawns it and resumes the conversation.
    c.call("session/close", json!({"sessionId": id})).await.0.expect("close");
    assert_eq!(c.add_dirs(&id).await, [s(&a), s(&b)], "the respawn");
    c.call("_acpmux/sessions/restart_harness", json!({"sessions": [id]})).await.0.expect("restart");
    assert_eq!(c.add_dirs(&id).await, [s(&a), s(&b)], "a restart");

    // A chat started without any keeps only its own folder.
    let plain = c
        .new_session("fakeclaude", Some(&std::env::temp_dir()), Value::Null)
        .await
        .expect("session/new");
    assert!(plain.pointer("/_meta/acpmux/additionalDirectories").is_none(), "{plain}");
    assert!(c.add_dirs(plain["sessionId"].as_str().unwrap()).await.is_empty());
}

#[tokio::test]
async fn a_chat_with_no_folder_of_its_own_still_sees_its_sources() {
    let _hermetic = &HERMETIC;
    let hub = hub();
    let mut c = Client::new(&hub);
    let (root, a, _) = folders();
    // "and you can also just start with nothing": no project, only the empty agent-home folder
    // the app gives such a chat (AcpmuxPathPolicy `noProject`).
    let home = root.path().join("agent-home");
    std::fs::create_dir_all(&home).unwrap();
    let created = c.new_session("fakeclaude", Some(&home), json!([a])).await.expect("session/new");
    let id = created["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(c.add_dirs(&id).await, [s(&a)]);
}

#[tokio::test]
async fn an_acp_harness_gets_them_in_session_new_and_load() {
    let _hermetic = &HERMETIC;
    let hub = hub();
    let mut c = Client::new(&hub);
    let (_root, a, b) = folders();

    let created = c
        .new_session("fake", Some(&std::env::temp_dir()), json!([a, b]))
        .await
        .expect("session/new");
    let id = created["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(c.dirs(&id).await, json!([s(&a), s(&b)]), "session/new");

    // A restart loads the same conversation, with the same folders.
    c.call("_acpmux/sessions/restart_harness", json!({"sessions": [id]})).await.0.expect("restart");
    assert_eq!(c.dirs(&id).await, json!([s(&a), s(&b)]), "session/load");

    // None asked: the field is left out, as before.
    let plain = c.new_session("fake", Some(&std::env::temp_dir()), Value::Null).await.expect("new");
    assert_eq!(c.dirs(plain["sessionId"].as_str().unwrap()).await, Value::Null);
}

#[tokio::test]
async fn folders_are_absolute_existing_and_listed_once() {
    let _hermetic = &HERMETIC;
    let hub = hub();
    let mut c = Client::new(&hub);
    let (root, a, _) = folders();
    let file = root.path().join("file.txt");
    std::fs::write(&file, "x").unwrap();

    for bad in [
        json!(s(&a)),
        json!([1]),
        json!(["relative/dir"]),
        json!([root.path().join("missing")]),
        json!([file]),
    ] {
        let e = c
            .new_session("fakeclaude", Some(&std::env::temp_dir()), bad.clone())
            .await
            .expect_err(&format!("{bad} is refused"));
        assert_eq!(e["code"], json!(-32602), "{bad}: {e}");
    }

    // A repeat, and the chat's own folder, are dropped; a spelling with `..` is made canonical.
    let cwd = std::env::temp_dir();
    let dotted = a.join("..").join("notes");
    let created = c
        .new_session("fakeclaude", Some(&cwd), json!([a, dotted, cwd]))
        .await
        .expect("session/new");
    let id = created["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(c.add_dirs(&id).await, [s(&a)]);
}

#[tokio::test]
async fn a_running_chat_takes_new_folders_on_its_next_start() {
    let _hermetic = &HERMETIC;
    let hub = hub();
    let mut c = Client::new(&hub);
    let (_root, a, b) = folders();

    // Started with nothing: a plain chat in a folder of its own.
    let created = c
        .new_session("fakeclaude", Some(&std::env::temp_dir()), Value::Null)
        .await
        .expect("session/new");
    let id = created["sessionId"].as_str().unwrap().to_owned();
    assert!(c.add_dirs(&id).await.is_empty());

    // Between turns: the agent restarts now, on the same conversation, with the folders.
    let set = json!({"sessionId": id, "additionalDirectories": [a, b]});
    let (reply, _) = c.call("_acpmux/set_directories", set.clone()).await;
    let reply = reply.expect("set_directories");
    assert_eq!(reply["applied"], json!("now"), "{reply}");
    assert_eq!(reply["additionalDirectories"], json!([s(&a), s(&b)]));
    assert_eq!(c.add_dirs(&id).await, [s(&a), s(&b)]);
    let (info, _) = c.call("_acpmux/info", json!({"sessionId": id})).await;
    assert_eq!(info.unwrap()["additionalDirectories"], json!([s(&a), s(&b)]));

    // The same list again changes nothing.
    let (reply, _) = c.call("_acpmux/set_directories", set).await;
    assert_eq!(reply.unwrap()["applied"], json!("unchanged"));

    // An empty list clears them; a missing one, or a bad folder, is refused.
    let clear = json!({"sessionId": id, "additionalDirectories": []});
    c.call("_acpmux/set_directories", clear).await.0.expect("clear");
    assert!(c.add_dirs(&id).await.is_empty());
    for bad in [json!({"sessionId": id}), json!({"sessionId": id, "additionalDirectories": ["x"]})]
    {
        let e = c.call("_acpmux/set_directories", bad.clone()).await.0.expect_err("refused");
        assert_eq!(e["code"], json!(-32602), "{bad}: {e}");
    }
}

#[tokio::test]
async fn an_acp_chat_loads_its_new_folders() {
    let _hermetic = &HERMETIC;
    let hub = hub();
    let mut c = Client::new(&hub);
    let (_root, a, _) = folders();
    let created =
        c.new_session("fake", Some(&std::env::temp_dir()), Value::Null).await.expect("new");
    let id = created["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(c.dirs(&id).await, Value::Null);
    let set = json!({"sessionId": id, "additionalDirectories": [a]});
    c.call("_acpmux/set_directories", set).await.0.expect("set_directories");
    assert_eq!(c.dirs(&id).await, json!([s(&a)]), "session/load");
}
