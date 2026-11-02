//! A person's trust decision applies to the folder, whatever spelling reaches it
//! (`trust.rs`): a folder moved behind a link, a decision made before its folder existed under a
//! link, or (on a volume that ignores case) another letter case. A `no` missed under another
//! spelling would let an agent's inherited trust start a full-access sub-session there; a `trust`
//! missed would ask again. Follow-up of #22471.
//!
//! Stand-in agents (fake_agent.py).

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

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const START: &str = "_acpmux/subsession/start";

/// The process environment every test here shares: an empty settings file.
fn env_once() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let root =
            std::env::temp_dir().join(format!("acpmux-trust-canon-env-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&root).unwrap();
        let settings = root.join("cmux-next.json");
        std::fs::write(&settings, "{}").unwrap();
        // SAFETY: set once, before any test of this binary starts a session.
        unsafe {
            std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings);
            std::env::set_var("ACPMUX_HOME", root.join("home"));
        }
    });
}

/// One test's scratch folder, canonical, with its trust files.
struct Scratch {
    root: PathBuf,
    trust: acpmux::trust::Paths,
}

impl Scratch {
    fn new(name: &str) -> Self {
        let root = std::env::temp_dir()
            .join(format!("acpmux-trust-canon-{name}-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&root).unwrap();
        let root = std::fs::canonicalize(&root).unwrap();
        let trust = acpmux::trust::Paths {
            claude_json: root.join("claude.json"),
            codex_config: root.join("codex.toml"),
            record: root.join("acpmux").join("trust.json"),
            agent_home: None,
            cmux_worktrees: None,
        };
        Scratch { root, trust }
    }

    fn dir(&self, rel: &str) -> PathBuf {
        let d = self.root.join(rel);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// The person's own decision for `dir` (`acp.trust.set`).
    fn decide(&self, dir: &Path, level: &str) {
        acpmux::trust::set(&self.trust, &dir.to_string_lossy(), level).unwrap();
    }

    /// Claude Code and Codex both trust the scratch folder, so every folder in it inherits
    /// their trust.
    fn agents_trust_everything(&self) {
        let key = self.root.to_string_lossy().into_owned();
        let claude = json!({"projects": {(key.clone()): {"hasTrustDialogAccepted": true}}});
        std::fs::write(&self.trust.claude_json, claude.to_string()).unwrap();
        let codex = format!("[projects.{key:?}]\ntrust_level = \"trusted\"\n");
        std::fs::write(&self.trust.codex_config, codex).unwrap();
    }

    /// `rel`, decided `level` by the person, then moved to `moved` with a link left at `rel`:
    /// the decision was recorded under what is now the link's spelling. Returns both spellings.
    fn decided_then_moved(&self, rel: &str, moved: &str, level: &str) -> [PathBuf; 2] {
        let folder = self.dir(&format!("{rel}/app"));
        self.decide(&folder, level);
        std::fs::rename(self.root.join(rel), self.root.join(moved)).unwrap();
        std::os::unix::fs::symlink(self.root.join(moved), self.root.join(rel)).unwrap();
        [folder, self.root.join(moved).join("app")]
    }

    /// A decision made for `<link>/later` before that folder existed, `link` pointing at `real`;
    /// the folder is made afterwards. Returns both spellings.
    fn decided_before_it_existed(&self, link: &str, real: &str, level: &str) -> [PathBuf; 2] {
        let real = self.dir(real);
        std::os::unix::fs::symlink(&real, self.root.join(link)).unwrap();
        let typed = self.root.join(link).join("later");
        self.decide(&typed, level);
        std::fs::create_dir_all(real.join("later")).unwrap();
        [typed, real.join("later")]
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn hub(s: &Scratch) -> Arc<Hub> {
    env_once();
    let fake =
        |family: &str, env: Value| json!({"argv": ["python3", FAKE], "family": family, "env": env});
    let doc = json!({
        "harnesses": {
            "fake": fake("fake", json!({})),
            "fake-full": fake("fake", json!({"FAKE_FULL_ACCESS": "1"})),
        },
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    });
    let mut cfg: Config = serde_json::from_value(doc).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_trust_gate(Some(s.trust.clone()));
    hub
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    /// The connection an agent's tools open: `initialize` with its caller token.
    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::new(hub);
        let token = acpmux::hub::person::caller_token(id);
        let params = json!({"protocolVersion": 1,
            "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}});
        let r = c.call("initialize", params).await;
        assert!(r.get("error").is_none(), "{r}");
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

    async fn refused(&mut self, m: &str, params: Value) -> Value {
        let r = self.call(m, params).await;
        assert!(r.get("error").is_some(), "{m} should be refused: {r}");
        r["error"].clone()
    }

    /// A session the person starts in `cwd` on `harness`.
    async fn new_session(&mut self, cwd: &Path, harness: &str) -> String {
        let new = json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
        self.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned()
    }

    /// `acp.trust.get` for `cwd`: the level the pane shows, and whether acpmux decided it.
    async fn trust(&mut self, cwd: &Path) -> (String, bool) {
        let reply = self.ok("acp.trust.get", json!({"cwd": cwd})).await;
        (reply["level"].as_str().unwrap_or_default().to_owned(), reply["decided"] == true)
    }
}

/// Every spelling of each folder the person said no to is refused to a full-access caller that
/// the agents' inherited trust would otherwise let in, and `acp.trust.get` shows the no.
async fn refused_everywhere(s: &Scratch, folders: &[PathBuf]) {
    let hub = hub(s);
    let mut app = Client::new(&hub);
    let own = s.dir("own");
    let full = app.new_session(&own, "fake-full").await;
    let mut f = Client::as_session(&hub, &full).await;
    for cwd in folders {
        let e = f.refused(START, json!({"prompt": "echo x", "cwd": cwd})).await;
        assert_eq!(e["data"]["reason"], "subsessions.folder_untrusted", "{}: {e}", cwd.display());
        let (level, decided) = app.trust(cwd).await;
        assert_eq!((level.as_str(), decided), ("untrusted", true), "{}", cwd.display());
    }
}

/// Every spelling of each folder the person trusted reads as their decision, and an asking
/// caller starts a sub-session there with no card.
async fn trusted_everywhere(s: &Scratch, folders: &[PathBuf]) {
    let hub = hub(s);
    let mut app = Client::new(&hub);
    let own = s.dir("own");
    s.decide(&own, "trusted");
    let parent = app.new_session(&own, "fake").await;
    let mut p = Client::as_session(&hub, &parent).await;
    for cwd in folders {
        let (level, decided) = app.trust(cwd).await;
        assert_eq!((level.as_str(), decided), ("trusted", true), "{}", cwd.display());
        p.ok(START, json!({"prompt": "echo x", "cwd": cwd})).await;
    }
}

#[tokio::test]
async fn a_persons_no_holds_across_spellings() {
    let s = Scratch::new("no");
    s.agents_trust_everything();
    let mut folders = Vec::new();
    folders.extend(s.decided_then_moved("projects", "disk", "untrusted"));
    folders.extend(s.decided_before_it_existed("linked", "target", "untrusted"));
    refused_everywhere(&s, &folders).await;
}

#[tokio::test]
async fn a_persons_trust_holds_across_spellings() {
    let s = Scratch::new("yes");
    let mut folders = Vec::new();
    folders.extend(s.decided_then_moved("projects", "disk", "trusted"));
    folders.extend(s.decided_before_it_existed("linked", "target", "trusted"));
    trusted_everywhere(&s, &folders).await;
}

/// On a volume that ignores case (APFS by default), a folder renamed to another letter case, and
/// a folder typed in yet another, is the folder the person decided for.
#[cfg(target_os = "macos")]
#[tokio::test]
async fn a_persons_answer_holds_in_another_letter_case_across_spellings() {
    let s = Scratch::new("case");
    std::fs::create_dir_all(s.root.join("a")).unwrap();
    if !s.root.join("A").exists() {
        // A case-sensitive volume: another case is another folder.
        return;
    }
    let renamed = |from: &str, to: &str, level: &str| -> Vec<PathBuf> {
        let folder = s.dir(&format!("{from}/app"));
        s.decide(&folder, level);
        std::fs::rename(s.root.join(from), s.root.join(to)).unwrap();
        let typed = s.root.join(from.to_lowercase()).join("APP");
        vec![folder, s.root.join(to).join("app"), typed]
    };
    let no = renamed("Work", "WORK", "untrusted");
    let yes = renamed("Docs", "DOCS", "trusted");
    s.agents_trust_everything();
    refused_everywhere(&s, &no).await;
    // The agents' trust is gone, so only the person's own trust lets the asking caller in.
    std::fs::remove_file(&s.trust.claude_json).unwrap();
    std::fs::remove_file(&s.trust.codex_config).unwrap();
    trusted_everywhere(&s, &yes).await;
}
