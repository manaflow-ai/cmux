//! The LocalApp origin through a real daemon and WebSocket clients: only the
//! app's pane (loopback, its page origin, this launch's token in the first
//! frame) is served as local, the session pool serves it, and the token
//! never comes back in any reply. A paired or relayed device's hello (no
//! Origin header, or another page) stays remote-origin even with the token.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::Duration;
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const PANE: &str = "cmux-agent://pane";

struct Daemon {
    child: Option<Child>,
    home: PathBuf,
    /// Added to the daemon's environment at every launch.
    env: Vec<(&'static str, &'static str)>,
    /// `ws://127.0.0.1:<port>/` and the listener token, from the ready line.
    ws: String,
    listener_token: String,
}

impl Daemon {
    fn start(tag: &str) -> Self {
        Self::start_with(tag, &[])
    }

    fn start_with(tag: &str, env: &[(&'static str, &'static str)]) -> Self {
        let home = std::env::temp_dir().join(format!("ala-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(
            home.join("config.json"),
            json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}}, "defaultHarness": "fake",
                "permissionPolicy": "approve-all", "pool": {"debounceMs": 0}})
            .to_string(),
        )
        .unwrap();
        let mut d = Self {
            child: None,
            home,
            env: env.to_vec(),
            ws: String::new(),
            listener_token: String::new(),
        };
        d.launch();
        d
    }

    fn launch(&mut self) {
        let mut child = daemon_env::command(&self.home, daemon_env::Agents::StandIn, &[])
            .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "error"])
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", self.home.join("s.sock"))
            .env("ACPMUX_LOGIN_ENV", "0")
            .envs(self.env.iter().copied())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        self.child = Some(child);
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut ready = String::new();
            let _ = BufReader::new(stdout).read_line(&mut ready);
            let _ = tx.send(ready);
        });
        let ready: Value =
            serde_json::from_str(&rx.recv_timeout(Duration::from_secs(20)).unwrap()).unwrap();
        let url = ready["webUrl"].as_str().unwrap();
        let (base, token) = url.split_once("/#token=").unwrap();
        self.ws = format!("{}/", base.replace("http://", "ws://"));
        self.listener_token = token.to_owned();
    }

    fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            // SAFETY: this test's own child.
            unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
            let _ = child.wait();
        }
    }

    fn local_token(&self) -> String {
        std::fs::read_to_string(self.home.join("run/localapp.token")).unwrap()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        for dir in [self.home.join("hosts"), self.home.join("hosts/pool")] {
            for r in std::fs::read_dir(dir).into_iter().flatten().flatten() {
                if let Ok(v) =
                    serde_json::from_slice::<Value>(&std::fs::read(r.path()).unwrap_or_default())
                {
                    for pid in
                        [v["harness_pid"].as_i64(), v["host_pid"].as_i64()].into_iter().flatten()
                    {
                        // SAFETY: process groups this test's daemon created.
                        unsafe { libc::killpg(pid as i32, libc::SIGKILL) };
                    }
                }
            }
        }
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// A WebSocket client with the listener token, `origin` (None: no header),
/// and a first frame `initialize` carrying `local_token`.
async fn hello(d: &Daemon, origin: Option<&str>, local_token: Option<&str>) -> (Ws, Value) {
    let mut req = d.ws.as_str().into_client_request().unwrap();
    let h = req.headers_mut();
    h.insert("authorization", format!("Bearer {}", d.listener_token).parse().unwrap());
    if let Some(o) = origin {
        h.insert("origin", o.parse().unwrap());
    }
    let (mut ws, _) = tokio_tungstenite::connect_async(req).await.expect("upgrade");
    let mut meta = json!({});
    if let Some(t) = local_token {
        meta["localAppToken"] = json!(t);
    }
    let init = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": 1, "clientInfo": {"name": "test"}, "_meta": {"acpmux": meta}}});
    ws.send(Message::Text(init.to_string().into())).await.unwrap();
    let reply = answer(&mut ws, 1).await;
    (ws, reply)
}

async fn answer(ws: &mut Ws, id: i64) -> Value {
    loop {
        let frame = tokio::time::timeout(Duration::from_secs(30), ws.next())
            .await
            .expect("an answer in time")
            .expect("open")
            .unwrap();
        if let Message::Text(t) = frame {
            let v: Value = serde_json::from_str(&t).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }
}

async fn call(ws: &mut Ws, id: i64, method: &str, params: Value) -> Value {
    let req = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
    ws.send(Message::Text(req.to_string().into())).await.unwrap();
    answer(ws, id).await
}

fn origin_of(init: &Value) -> &str {
    init["result"]["_meta"]["acpmux"]["origin"].as_str().unwrap_or("absent")
}

#[tokio::test(flavor = "multi_thread")]
async fn the_app_pane_is_local_and_the_pool_serves_it() {
    let d = Daemon::start("app");
    let token = d.local_token();
    let (mut ws, init) = hello(&d, Some(PANE), Some(&token)).await;
    assert_eq!(origin_of(&init), "local", "{init}");
    let trust = call(&mut ws, 2, "acp.trust.set", json!({"cwd": d.home, "level": "trusted"})).await;
    assert!(trust.get("error").is_none(), "{trust}");
    let warmed = call(
        &mut ws,
        3,
        "_acpmux/prewarm",
        json!({"harness": "fake", "cwd": d.home, "wait": true}),
    )
    .await;
    assert_eq!(warmed["result"]["accepted"], true, "{warmed}");
    let status = call(&mut ws, 4, "_acpmux/status", json!({})).await;
    let text = status.to_string();
    assert!(!text.contains(&token), "the LocalApp token came back");
    assert!(!text.contains(&d.listener_token), "the listener token came back");
    assert!(status["result"].get("webUrl").is_none());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_paired_or_relayed_hello_with_the_token_stays_remote() {
    let d = Daemon::start("relay");
    let token = d.local_token();
    // Peers, ssh tunnels and relays send no Origin header.
    let (mut ws, init) = hello(&d, None, Some(&token)).await;
    assert_eq!(origin_of(&init), "remote", "{init}");
    let refused = call(&mut ws, 2, "_acpmux/prewarm", json!({"harness": "fake"})).await;
    assert!(refused.get("error").is_some(), "the pool refuses a remote origin: {refused}");
    // The dashboard page (the listener's own origin) is not the app either.
    let own = d.ws.replace("ws://", "http://");
    let (_, init) = hello(&d, Some(own.trim_end_matches('/')), Some(&token)).await;
    assert_eq!(origin_of(&init), "remote", "{init}");
    // The app's page without the token.
    let (_, init) = hello(&d, Some(PANE), None).await;
    assert_eq!(origin_of(&init), "remote", "{init}");
}

#[tokio::test(flavor = "multi_thread")]
async fn the_token_is_new_at_every_launch_private_and_never_in_a_reply() {
    use std::os::unix::fs::PermissionsExt;
    let mut d = Daemon::start("launch");
    let first = d.local_token();
    let mode = std::fs::metadata(d.home.join("run/localapp.token")).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
    // Not in the saved config, and not in the unix socket's status either.
    assert!(!std::fs::read_to_string(d.home.join("config.json")).unwrap().contains(&first));
    let status = unix_status(&d.home);
    assert!(!status.contains(&first), "status over the unix socket carried it");
    d.stop();
    assert!(!d.home.join("run/localapp.token").exists(), "removed when the daemon stops");
    d.launch();
    let second = d.local_token();
    assert_ne!(first, second);
    let (_, init) = hello(&d, Some(PANE), Some(&first)).await;
    assert_eq!(origin_of(&init), "remote", "the previous launch's token opens nothing");
    let (_, init) = hello(&d, Some(PANE), Some(&second)).await;
    assert_eq!(origin_of(&init), "local");
}

/// The agent pane's chat menu (cx-jlzsf): Archive and Mark as Unread are
/// acpmux requests the page sends on its own connection, the app's pane
/// (LocalApp) and a plain browser tab on the listener (the dev host, remote
/// origin) alike; no host bridge call is left between the page and the chat.
#[tokio::test(flavor = "multi_thread")]
async fn the_pane_archives_and_marks_a_chat_unread_over_its_own_connection() {
    let d = Daemon::start("chat-state");
    let token = d.local_token();
    let (mut app, init) = hello(&d, Some(PANE), Some(&token)).await;
    assert_eq!(origin_of(&init), "local", "{init}");
    let trust =
        call(&mut app, 2, "acp.trust.set", json!({"cwd": d.home, "level": "trusted"})).await;
    assert!(trust.get("error").is_none(), "{trust}");
    let new = call(&mut app, 3, "session/new", json!({"cwd": d.home, "mcpServers": []})).await;
    let id = new["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{new}")).to_owned();
    let summary = |reply: &Value| -> Value {
        reply["result"]["sessions"]
            .as_array()
            .and_then(|all| all.iter().find(|s| s["sessionId"] == json!(id)).cloned())
            .unwrap_or_else(|| panic!("no summary for {id}: {reply}"))
    };

    // Archive: acpmux sets the `archived` tag to when (milliseconds); Unarchive removes it.
    let before =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis();
    let archived =
        call(&mut app, 4, "_acpmux/archive", json!({"sessionId": id, "archived": true})).await;
    let when =
        archived["result"]["tags"]["archived"].as_str().unwrap_or_else(|| panic!("{archived}"));
    assert!(when.parse::<u128>().is_ok_and(|ms| ms >= before), "{archived}");
    let unread = call(&mut app, 5, "_acpmux/markUnread", json!({"sessionId": id})).await;
    assert!(unread.get("error").is_none(), "{unread}");
    let seen = call(&mut app, 6, "_acpmux/watch", json!({})).await;
    assert_eq!(summary(&seen)["unread"], json!(true), "{seen}");
    assert!(summary(&seen)["tags"]["archived"].is_string(), "{seen}");

    // The same requests from a plain browser tab on the listener (no Swift in between).
    let (mut tab, init) = hello(&d, None, None).await;
    assert_eq!(origin_of(&init), "remote", "{init}");
    let restored =
        call(&mut tab, 2, "_acpmux/archive", json!({"sessionId": id, "archived": false})).await;
    assert!(restored["result"]["tags"].get("archived").is_none(), "{restored}");
    let again = call(&mut tab, 3, "_acpmux/markUnread", json!({"sessionId": id})).await;
    assert!(again.get("error").is_none(), "{again}");
    let seen = call(&mut tab, 4, "_acpmux/watch", json!({})).await;
    assert!(summary(&seen)["tags"].get("archived").is_none(), "{seen}");
    assert_eq!(summary(&seen)["unread"], json!(true), "{seen}");
    // Only true or false: the request never names another tag.
    let odd =
        call(&mut tab, 6, "_acpmux/archive", json!({"sessionId": id, "archived": "yes"})).await;
    assert!(odd.get("error").is_some(), "{odd}");
    // An unknown chat is an error, never a silent success the menu would show as done.
    let missing =
        call(&mut tab, 5, "_acpmux/markUnread", json!({"sessionId": "no-such-chat"})).await;
    assert!(missing.get("error").is_some(), "{missing}");
}

/// New side chat (cx-jlzsf): the pane tags the fork it made as a side chat
/// of its chat with `_acpmux/side`, which sets only the `side` tag.
#[tokio::test(flavor = "multi_thread")]
async fn the_pane_marks_a_fork_as_its_chats_side_chat() {
    let d = Daemon::start("side-chat");
    let token = d.local_token();
    let (mut app, init) = hello(&d, Some(PANE), Some(&token)).await;
    assert_eq!(origin_of(&init), "local", "{init}");
    let trust =
        call(&mut app, 2, "acp.trust.set", json!({"cwd": d.home, "level": "trusted"})).await;
    assert!(trust.get("error").is_none(), "{trust}");
    let mut ids = Vec::new();
    for id in [3, 4] {
        let new = call(&mut app, id, "session/new", json!({"cwd": d.home, "mcpServers": []})).await;
        ids.push(new["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{new}")).to_owned());
    }
    let (chat, fork) = (&ids[0], &ids[1]);
    let side = call(&mut app, 5, "_acpmux/side", json!({"sessionId": fork, "chat": chat})).await;
    assert_eq!(side["result"]["tags"]["side"], json!(chat), "{side}");
    assert!(side["result"]["tags"].as_object().is_some_and(|t| t.len() == 1), "{side}");
    // Never its own side chat, never of an unknown chat, and the chat is required.
    for (id, params) in [
        (6, json!({"sessionId": chat, "chat": chat})),
        (7, json!({"sessionId": fork, "chat": "no-such-chat"})),
        (8, json!({"sessionId": fork})),
        // The exact id only: a prefix or a name never resolves another chat.
        (9, json!({"sessionId": fork, "chat": &chat[..chat.len().min(6)]})),
    ] {
        let refused = call(&mut app, id, "_acpmux/side", params.clone()).await;
        assert!(refused.get("error").is_some(), "{params}: {refused}");
    }
}

/// A stop right after the ready line is a clean stop: SIGTERM ends the
/// daemon through its shutdown path (exit 0, run/localapp.token removed).
/// The daemon installed its SIGTERM handler only after the ready line, so a
/// SIGTERM in between ended it by the default action and left the token
/// file, the pid file and the socket: the test above failed that way in 16
/// of 96 parallel runs on the rbx builder. The debug-only seam holds the
/// daemon right after the ready line.
#[tokio::test(flavor = "multi_thread")]
async fn a_sigterm_right_after_the_ready_line_is_a_clean_stop() {
    let mut d = Daemon::start_with("ready-term", &[("ACPMUX_TEST_HOLD_AFTER_READY_MS", "2000")]);
    let token = d.home.join("run/localapp.token");
    assert!(token.exists(), "the token is written before the ready line");
    let mut child = d.child.take().unwrap();
    // SAFETY: this test's own child.
    unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
    let status = child.wait().unwrap();
    assert_eq!(status.code(), Some(0), "the daemon ended by the signal: {status:?}");
    assert!(!token.exists(), "removed when the daemon stops");
    assert!(!d.home.join("daemon.pid").exists(), "the pid file is removed too");
}

/// A stop does not leave the daemon lock to a child. A forked child shares
/// the daemon's descriptors until it execs, and startup forks model probes
/// and agent hosts right after the ready line. On a loaded runner a stop in
/// that window left the lock held after the daemon exited, and the next
/// launch exited with "another acpmux daemon holds" (the token test above
/// failed that way on Linux CI). The debug-only seam forks a child that
/// sleeps without exec, as such a spawn.
#[tokio::test(flavor = "multi_thread")]
async fn a_relaunch_after_a_stop_is_not_held_off_by_a_forked_child() {
    let mut d = Daemon::start_with("fork-hold", &[("ACPMUX_TEST_FORK_HOLD_MS", "4000")]);
    d.stop();
    d.env.clear();
    d.launch();
    assert!(d.home.join("run/localapp.token").exists(), "the relaunched daemon serves");
}

fn unix_status(home: &Path) -> String {
    use std::io::Write;
    let mut s = std::os::unix::net::UnixStream::connect(home.join("s.sock")).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    writeln!(s, "{}", json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/status", "params": {}}))
        .unwrap();
    let mut line = String::new();
    BufReader::new(s).read_line(&mut line).unwrap();
    line
}
