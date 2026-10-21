//! One agent CLI update for every chat: after `_acpmux/harness/update`
//! installed a newer version, every `_acpmux/watch` connection gets one
//! `_acpmux/harness_updated {harness, name, from, to, at, restart}` and each
//! live chat of that harness a `harness_updated` mux record. With the cmux
//! setting `agents.restartChatsAfterUpdate` on (the default) an idle chat
//! restarts at once on the same agent session and a busy one when its turn
//! ends; off, nothing restarts and each chat's record says `manual`. Also
//! `_acpmux/harness/changelog`: a loopback server stands in for the published
//! changelog, so nothing reaches the network.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents and a stand-in CLI updater.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::harness_health::changelog::Sources as ChangelogSources;
use acpmux::harness_health::{Settings, changelog_fetch, latest::Sources};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const FIXTURE: &str =
    include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/claude-changelog.md"));

fn scratch(name: &str) -> PathBuf {
    let root =
        std::env::temp_dir().join(format!("acpmux-harness-updated-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::canonicalize(&root).unwrap()
}

/// A loopback HTTP server: path -> (content type, body); every request path and its
/// `If-None-Match` are logged. A request with the `ETag` it last answered gets a 304.
fn server(answers: Vec<(&'static str, &'static str, String)>) -> (u16, Arc<Mutex<Vec<String>>>) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let asked = Arc::new(Mutex::new(Vec::new()));
    let log = asked.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            if reader.read_line(&mut line).is_err() {
                continue;
            }
            let mut tag = None;
            let mut header = String::new();
            while reader.read_line(&mut header).is_ok_and(|n| n > 0) && header.trim() != "" {
                if let Some(v) = header.to_ascii_lowercase().strip_prefix("if-none-match:") {
                    tag = Some(v.trim().to_owned());
                }
                header.clear();
            }
            let path = line.split_whitespace().nth(1).unwrap_or("").to_owned();
            log.lock().unwrap().push(format!("{path} {}", tag.clone().unwrap_or_default()));
            let reply = match answers.iter().find(|(p, _, _)| *p == path) {
                Some(_) if tag.as_deref() == Some("\"v1\"") => {
                    "HTTP/1.1 304 Not Modified\r\nETag: \"v1\"\r\nConnection: close\r\n\r\n"
                        .to_owned()
                }
                Some((_, kind, body)) => format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: {kind}\r\nETag: \"v1\"\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                ),
                None => "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    .to_owned(),
            };
            let _ = stream.write_all(reply.as_bytes());
        }
    });
    (port, asked)
}

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
    /// Notifications seen while waiting for replies.
    notes: Vec<Value>,
}

impl Client {
    fn open(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Self { tx, rx, next: 0, notes: Vec::new() }
    }

    async fn send(&mut self, m: &str, params: Value) -> i64 {
        self.next += 1;
        self.tx.send(Message::request(self.next, m, params).to_line()).await.unwrap();
        self.next
    }

    async fn line(&mut self) -> Value {
        let line = tokio::time::timeout(Duration::from_secs(60), self.rx.recv())
            .await
            .expect("nothing in 60 s")
            .unwrap();
        serde_json::from_str(&line).unwrap()
    }

    async fn reply(&mut self, id: i64) -> Value {
        loop {
            let v = self.line().await;
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
            self.notes.push(v);
        }
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let id = self.send(m, params).await;
        let reply = self.reply(id).await;
        assert!(reply.get("error").is_none(), "{m}: {reply}");
        reply["result"].clone()
    }

    async fn new_chat(&mut self) -> String {
        let new = self
            .ok(
                "session/new",
                json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                       "_meta": {"acpmux": {"harness": "claude"}}}),
            )
            .await;
        new["sessionId"].as_str().unwrap().to_owned()
    }

    /// The streamed text of a turn, up to `until`.
    async fn text_until(&mut self, until: &str) -> String {
        let mut text = String::new();
        while !text.contains(until) {
            let v = self.line().await;
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
        text
    }

    /// The pid of the harness process that answers a turn in `session`.
    async fn harness_pid(&mut self, session: &str) -> String {
        let prompt =
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "env: RUN_PID"}]});
        let id = self.send("session/prompt", prompt).await;
        let mut text = String::new();
        loop {
            let v = self.line().await;
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
            if v.get("id") == Some(&json!(id)) && text.contains("RUN_PID=") {
                break;
            }
            if v.get("id") == Some(&json!(id)) {
                text.push_str(&self.text_until("RUN_PID=").await);
                break;
            }
        }
        let at = text.rfind("RUN_PID=").unwrap_or(0);
        text[at + "RUN_PID=".len()..].split_whitespace().next().unwrap_or("").to_owned()
    }

    /// The `harness_updated` records of `session`, oldest first.
    async fn receipts(&mut self, session: &str) -> Vec<Value> {
        let events = self
            .ok(method::MUX_EVENTS, json!({"sessionId": session, "kinds": ["harness_updated"]}))
            .await;
        events["events"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .map(|e| e["msg"].clone())
            .collect()
    }

    /// The `_acpmux/harness_updated` notifications seen so far, then cleared.
    fn updates(&mut self) -> Vec<Value> {
        let seen = std::mem::take(&mut self.notes);
        seen.into_iter()
            .filter(|n| n["method"] == method::MUX_HARNESS_UPDATED)
            .map(|n| n["params"].clone())
            .collect()
    }
}

/// Claude Code's native install at `home`: `--version` prints the version in `version`,
/// `update` writes the newer one there, and anything else runs the stand-in agent.
fn claude(root: &Path, home: &Path, version: &Path) -> PathBuf {
    let real = home.join(".local/share/claude/versions/current");
    let cli = home.join(".local/bin/claude");
    std::fs::create_dir_all(real.parent().unwrap()).unwrap();
    std::fs::create_dir_all(cli.parent().unwrap()).unwrap();
    std::fs::write(version, "2.0.5 (Claude Code)\n").unwrap();
    let runs = root.join("update-runs");
    std::fs::write(
        &real,
        format!(
            "#!/bin/sh\ncase \"$1\" in\n--version) cat '{v}'; exit 0;;\nupdate) echo run >> '{r}'; echo '2.0.9 (Claude Code)' > '{v}'; echo updated; exit 0;;\nesac\nexport RUN_PID=$$\nexec python3 '{FAKE}' \"$@\"\n",
            v = version.display(),
            r = runs.display(),
        ),
    )
    .unwrap();
    std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o755)).unwrap();
    symlink(&real, &cli).unwrap();
    cli
}

fn hub(root: &Path, cli: &Path, home: &Path, npm_port: u16) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"claude": {"argv": [cli], "family": "claude"}},
        "defaultHarness": "claude",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.path = Some(root.join("config.json"));
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.health.attach(Settings {
        sources: Some(Sources {
            npm: format!("http://127.0.0.1:{npm_port}/npm"),
            brew: format!("http://127.0.0.1:{npm_port}/brew"),
        }),
        cache: None,
        home: home.into(),
        auto_update: Some(root.join("auto-update.json")),
    });
    hub
}

fn settings(path: &Path, restart: Option<bool>) {
    let body = match restart {
        Some(on) => json!({"agents": {"restartChatsAfterUpdate": on}}).to_string(),
        None => "{}".to_owned(),
    };
    std::fs::write(path, body).unwrap();
}

/// The setting off: the update reaches every watcher and every chat's record, nothing restarts.
/// Then on (the default, no key): an idle chat restarts at once on the same agent session, a busy
/// one when its turn ends, and the update's result says so.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_update_reaches_every_chat_and_restarts_them_unless_the_setting_is_off() {
    let root = scratch("restart");
    let home = root.join("home");
    let version = root.join("claude-version");
    let cli = claude(&root, &home, &version);
    let settings_file = root.join("cmux-next.json");
    settings(&settings_file, Some(false));
    // SAFETY: the only test in this binary that reads the settings file sets it before any hub
    // reads it; the other test never reads it.
    unsafe { std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings_file) };
    let (port, _) = server(vec![(
        "/npm/@anthropic-ai%2Fclaude-code/latest",
        "application/json",
        json!({"version": "2.0.9"}).to_string(),
    )]);
    let hub = hub(&root, &cli, &home, port);
    let mut local = Client::open(&hub, Origin::Local);
    let mut feed = Client::open(&hub, Origin::LocalApp);
    feed.ok(method::MUX_WATCH, json!({})).await;

    let idle = local.new_chat().await;
    let idle_pid = local.harness_pid(&idle).await;
    let health = local.ok(method::MUX_HARNESS_HEALTH, json!({"refresh": true})).await;
    assert_eq!(health["harnesses"][0]["outdated"], true, "{health}");

    // Off: installed, told, recorded; nothing restarts.
    let reply = local.ok(method::MUX_HARNESS_UPDATE, json!({"ids": ["claude"]})).await;
    let result = &reply["results"][0];
    assert_eq!((&result["ok"], &result["version"]), (&json!(true), &json!("2.0.9")), "{reply}");
    assert_eq!(
        result["restart"],
        json!({"auto": false, "now": 0, "afterTurn": 0, "failed": 0}),
        "{reply}"
    );
    let ping = feed.send(method::MUX_HARNESS_HEALTH, json!({})).await;
    feed.reply(ping).await;
    let told = feed.updates();
    assert_eq!(told.len(), 1, "one notification per update: {told:?}");
    let note = &told[0];
    assert_eq!(
        (&note["harness"], &note["name"], &note["from"], &note["to"]),
        (&json!("claude"), &json!("Claude Code"), &json!("2.0.5"), &json!("2.0.9")),
        "{note}"
    );
    assert!(note["at"].as_u64().is_some_and(|at| at > 0), "{note}");
    assert_eq!(note["restart"]["auto"], false, "{note}");
    let receipts = local.receipts(&idle).await;
    assert_eq!(receipts.len(), 1, "{receipts:?}");
    assert_eq!((&receipts[0]["to"], &receipts[0]["when"]), (&json!("2.0.9"), &json!("manual")));
    assert_eq!(local.harness_pid(&idle).await, idle_pid, "setting off: the chat keeps its process");

    // On (no key: the default). The CLI is outdated again; one chat idle, one in a turn.
    settings(&settings_file, None);
    std::fs::write(&version, "2.0.5 (Claude Code)\n").unwrap();
    local.ok(method::MUX_HARNESS_HEALTH, json!({"refresh": true})).await;
    let agent =
        local.ok(method::MUX_INFO, json!({"sessionId": idle})).await["agentSessionId"].clone();
    let busy = local.new_chat().await;
    let busy_pid = local.harness_pid(&busy).await;
    let gate = root.join("gate");
    assert!(std::process::Command::new("mkfifo").arg(&gate).status().unwrap().success());
    let mut turn = Client::open(&hub, Origin::Local);
    let prompt = json!({"sessionId": busy, "prompt": [{"type": "text", "text": format!("gate: {}", gate.display())}]});
    let turn_id = turn.send("session/prompt", prompt).await;
    turn.text_until("before-gate").await;

    let reply = local.ok(method::MUX_HARNESS_UPDATE, json!({"ids": ["claude"]})).await;
    assert_eq!(
        reply["results"][0]["restart"],
        json!({"auto": true, "now": 1, "afterTurn": 1, "failed": 0}),
        "{reply}"
    );
    let moved = local.harness_pid(&idle).await;
    assert_ne!(moved, idle_pid, "the idle chat restarted");
    let info = local.ok(method::MUX_INFO, json!({"sessionId": idle})).await;
    assert_eq!(info["agentSessionId"], agent, "on the same agent session");
    let receipt = local.receipts(&busy).await.pop().expect("the busy chat's record");
    assert_eq!(receipt["when"], "after-turn", "{receipt}");
    assert_eq!(local.receipts(&idle).await.last().unwrap()["when"], "now");

    // The turn ends; then the busy chat runs the new version.
    std::fs::write(&gate, "go").unwrap();
    let ended = turn.reply(turn_id).await;
    assert!(ended.get("error").is_none(), "{ended}");
    assert_ne!(local.harness_pid(&busy).await, busy_pid, "the busy chat restarted after its turn");

    let ping = feed.send(method::MUX_HARNESS_HEALTH, json!({})).await;
    feed.reply(ping).await;
    let told = feed.updates();
    assert_eq!(told.len(), 1, "{told:?}");
    assert_eq!(told[0]["restart"], json!({"auto": true, "now": 1, "afterTurn": 1, "failed": 0}));
    let _ = std::fs::remove_dir_all(&root);
}

/// A hub with a `claude` and a `gemini` harness whose changelogs come from the loopback `port`.
fn changelog_hub(port: u16, cache: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "claude": {"argv": ["/bin/true"], "family": "claude"},
            "other": {"argv": ["/bin/true"], "family": "gemini"},
        },
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.health.changelogs.attach(changelog_fetch::Settings {
        sources: Some(ChangelogSources {
            claude: format!("http://127.0.0.1:{port}/CHANGELOG.md"),
            codex: format!("http://127.0.0.1:{port}/releases"),
        }),
        cache: Some(cache.to_path_buf()),
    });
    hub
}

/// `_acpmux/harness/changelog`: the pending versions `(installed, newest]` of the published
/// changelog, newest first, with the full changelog's URL; asked again with its ETag (a 304
/// keeps the copy). A Web page reads the saved copy and never fetches; a peer is refused; a
/// harness without a known changelog answers no entries.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_changelog_answers_the_pending_versions_from_the_published_one() {
    let root = scratch("changelog");
    let (port, asked) = server(vec![("/CHANGELOG.md", "text/markdown", FIXTURE.to_owned())]);
    let cache = root.join("harness-changelog.json");
    let hub = changelog_hub(port, &cache);

    // A Web page before any fetch: nothing saved, nothing fetched.
    let mut web = Client::open(&hub, Origin::Web);
    let none = web
        .ok(
            method::MUX_HARNESS_CHANGELOG,
            json!({"id": "claude", "from": "2.1.303", "to": "2.1.305"}),
        )
        .await;
    assert_eq!(none["entries"], json!([]), "{none}");
    assert!(asked.lock().unwrap().is_empty(), "a Web page fetched");

    let mut app = Client::open(&hub, Origin::LocalApp);
    let reply = app
        .ok(
            method::MUX_HARNESS_CHANGELOG,
            json!({"id": "claude", "from": "2.1.303", "to": "2.1.305"}),
        )
        .await;
    assert_eq!(reply["source"], "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md");
    let versions: Vec<&str> =
        reply["entries"].as_array().unwrap().iter().filter_map(|e| e["version"].as_str()).collect();
    assert_eq!(versions, ["2.1.305", "2.1.304"], "{reply}");
    assert_eq!(
        reply["entries"][1]["items"],
        json!(["Faster startup when many MCP servers are configured"])
    );
    assert!(cache.exists(), "the copy is saved");

    // Now the Web page reads the saved copy; a peer reads nothing; another family has none.
    let saved =
        web.ok(method::MUX_HARNESS_CHANGELOG, json!({"id": "claude", "from": "2.1.304"})).await;
    assert_eq!(saved["entries"][0]["version"], "2.1.305", "{saved}");
    let mut peer = Client::open(&hub, Origin::Peer);
    let id = peer.send(method::MUX_HARNESS_CHANGELOG, json!({"id": "claude"})).await;
    assert!(peer.reply(id).await.get("error").is_some(), "a peer read the changelog");
    let other = app.ok(method::MUX_HARNESS_CHANGELOG, json!({"id": "other"})).await;
    assert_eq!(other, json!({"source": null, "entries": []}));
    let id = app.send(method::MUX_HARNESS_CHANGELOG, json!({"id": "claude", "limit": 0})).await;
    assert!(app.reply(id).await.get("error").is_some(), "a limit of 0 is refused");

    assert_eq!(asked.lock().unwrap().len(), 1, "one fetch: {:?}", asked.lock().unwrap());
    // A fresh copy is reused, even for a newer `to` (asked again only after a minute).
    let reply = app
        .ok(
            method::MUX_HARNESS_CHANGELOG,
            json!({"id": "claude", "from": "2.1.304", "to": "2.1.306"}),
        )
        .await;
    assert_eq!(reply["entries"][0]["version"], "2.1.305", "{reply}");
    assert_eq!(asked.lock().unwrap().len(), 1, "{:?}", asked.lock().unwrap());

    // A new hub on a saved copy older than 10 minutes (as after a restart): it asks again with
    // the copy's ETag, and the 304 keeps the copy.
    let mut saved: Value = serde_json::from_slice(&std::fs::read(&cache).unwrap()).unwrap();
    saved["claude"]["fetchedAt"] = json!(0);
    std::fs::write(&cache, saved.to_string()).unwrap();
    let again = changelog_hub(port, &cache);
    let mut app = Client::open(&again, Origin::LocalApp);
    let reply = app
        .ok(
            method::MUX_HARNESS_CHANGELOG,
            json!({"id": "claude", "from": "2.1.303", "to": "2.1.305"}),
        )
        .await;
    assert_eq!(reply["entries"].as_array().map(Vec::len), Some(2), "{reply}");
    let log = asked.lock().unwrap().clone();
    assert_eq!(log.len(), 2, "{log:?}");
    assert_eq!(log[1], "/CHANGELOG.md \"v1\"", "a conditional GET: {log:?}");
    let _ = std::fs::remove_dir_all(&root);
}
