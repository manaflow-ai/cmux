//! A chat's predicted next prompts are gated by the person's own tally and switch, whichever
//! machine runs the agent (Leo, 2026-11-09: "why does the right one have the prompt suggestion
//! and the left one doesn't? Like, you're both Opus."). The left chat ran on his Mac, the right
//! one on a remote machine, both drawn by the same app: each machine kept its own take/pass
//! tally and read its own `agents.promptSuggestions`, so the same person saw suggestions on one
//! and not the other.
//!
//! Two real daemons, each with its own home and settings file: A is the person's own (it holds
//! their person key), B a peer A links to. A chat on B is reached through A.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agent under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const KEY: &str = "5e1f0c2a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f";

fn person_proof(key: &str, nonce: &str, connection: &str) -> String {
    use cmux_local_auth::frontend_proof::{hex, hmac_sha256, unhex};
    let key = unhex::<32>(key).unwrap();
    let mut message = b"acpmux-person-v1\0unix\0".to_vec();
    message.extend_from_slice(nonce.as_bytes());
    message.push(0);
    message.extend_from_slice(connection.as_bytes());
    hex(&hmac_sha256(&key, &message))
}

struct Rpc {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
    notes: Vec<Value>,
}

impl Rpc {
    /// The person's connection, as the app makes it: `initialize`, then the key's proof.
    async fn person(path: &Path) -> Self {
        let s = tokio::net::UnixStream::connect(path).await.unwrap();
        let (rd, wr) = s.into_split();
        let mut c =
            Self { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0, notes: Vec::new() };
        let init = c.ok("initialize", json!({"protocolVersion": 1})).await;
        let challenge = &init["_meta"]["acpmux"]["personChallenge"];
        let proof = person_proof(
            KEY,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        );
        c.ok("_acpmux/person_prove", json!({"proof": proof})).await;
        c
    }

    async fn line(&mut self) -> Value {
        let line = tokio::time::timeout(Duration::from_secs(30), self.lines.next_line())
            .await
            .expect("the daemon answered in time")
            .unwrap()
            .expect("the daemon closed the socket");
        serde_json::from_str(&line).unwrap()
    }

    async fn ok(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        loop {
            let v = self.line().await;
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
            self.notes.push(v);
        }
    }

    /// The suggestion the chat's next `prompt_suggestion` update carries (None: withheld), and
    /// that update.
    async fn suggestion(&mut self) -> (Option<String>, Value) {
        let pick = |v: &Value| {
            v["method"] == "session/update"
                && v["params"]["update"]["sessionUpdate"] == "prompt_suggestion"
        };
        let v = match self.notes.iter().position(pick) {
            Some(i) => self.notes.remove(i),
            None => loop {
                let v = self.line().await;
                if pick(&v) {
                    break v;
                }
            },
        };
        let update = v["params"]["update"].clone();
        (update["suggestion"].as_str().map(str::to_owned), update)
    }

    /// One turn of chat `id` that ends with the agent predicting `next`.
    async fn turn(&mut self, id: &str, said: &str) -> (Option<String>, Value) {
        self.ok(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": said}]}),
        )
        .await;
        self.suggestion().await
    }
}

struct Daemon {
    child: std::process::Child,
    socket: PathBuf,
    dir: PathBuf,
    listen: Option<String>,
}

impl Daemon {
    /// A daemon on its own home and settings file (`settings`, its cmux-next.json). `person`: it
    /// holds the person key (the person's own machine). `listen`: it serves peers.
    fn start(tag: &str, settings: Value, person: bool, listen: bool) -> Self {
        let dir = std::env::temp_dir().join(format!("sgp-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("work")).unwrap();
        let dir = std::fs::canonicalize(&dir).unwrap();
        std::fs::write(
            dir.join("config.json"),
            json!({
                "harnesses": {"fake": {"argv": ["python3", FAKE]}},
                "defaultHarness": "fake",
                // A chat a peer link starts is a remote one: its folder is under a web root.
                "webRoots": [dir.join("work")],
                "webAskingModes": {"fake": ["normal"]},
            })
            .to_string(),
        )
        .unwrap();
        // The daemon refuses a config another user could write.
        use std::os::unix::fs::PermissionsExt as _;
        for path in [dir.as_path(), &dir.join("config.json")] {
            let mode = if path.is_dir() { 0o700 } else { 0o600 };
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
        }
        let settings_file = dir.join("cmux-next.json");
        std::fs::write(&settings_file, settings.to_string()).unwrap();
        let socket = dir.join("s.sock");
        let mut cmd = daemon_env::command(&dir, daemon_env::Agents::StandIn, &[]);
        cmd.args(["daemon", "run", "--ready-fd", "1", "--log", "warn"])
            .env("ACPMUX_HOME", &dir)
            .env("ACPMUX_SOCKET", &socket)
            .env("ACPMUX_LOGIN_ENV", "0")
            .env("CMUX_NEXT_CONFIG_FILE", &settings_file)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null());
        if listen {
            cmd.args(["--listen", "127.0.0.1:0"]);
        }
        let mut fds = [-1i32; 2];
        if person {
            cmd.args(["--person-key-fd", "3"]);
            // SAFETY: a fresh pipe; both ends are owned here.
            assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
            let line = format!("{KEY}\n");
            // SAFETY: the write end is open; the line fits the pipe buffer.
            let n = unsafe { libc::write(fds[1], line.as_ptr().cast(), line.len()) };
            assert_eq!(n as usize, line.len());
            // SAFETY: closing our own write end.
            unsafe { libc::close(fds[1]) };
            let read_end = fds[0];
            // SAFETY: only dup2 between fork and exec (async-signal-safe).
            unsafe {
                cmd.pre_exec(move || {
                    if libc::dup2(read_end, 3) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    Ok(())
                });
            }
        }
        let mut child = cmd.spawn().unwrap();
        if fds[0] >= 0 {
            // SAFETY: the child has its own copy on fd 3.
            unsafe { libc::close(fds[0]) };
        }
        let stdout = child.stdout.take().unwrap();
        let ready = BufReader::new(stdout).lines().map_while(Result::ok).find_map(|line| {
            serde_json::from_str::<Value>(&line).ok().filter(|v| v["ready"] == true)
        });
        let Some(ready) = ready else {
            let _ = child.kill();
            let _ = child.wait();
            panic!("the daemon exited before its ready line");
        };
        let listen = ready["listen"].as_str().map(str::to_owned);
        Daemon { child, socket, dir, listen }
    }

    /// This daemon's take/pass tallies as it saved them.
    fn tallies(&self) -> Value {
        std::fs::read(self.dir.join("prompt-suggestions.json"))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or(Value::Null)
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // SAFETY: the pid of the child this test spawned and still owns.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// A, the person's own daemon (`a_settings`), linked to peer B (`b_settings`) as `b`; the
/// person's connection to A, and the id A names B's new chat by.
async fn person_with_a_peer_chat(
    tag: &str,
    a_settings: Value,
    b_settings: Value,
) -> (Daemon, Daemon, Rpc, String) {
    let b = Daemon::start(&format!("{tag}-b"), b_settings, false, true);
    let a = Daemon::start(&format!("{tag}-a"), a_settings, true, false);
    let peer_token = std::fs::read_to_string(b.dir.join("run").join("peer.token")).unwrap();
    let config: Value =
        serde_json::from_slice(&std::fs::read(b.dir.join("config.json")).unwrap()).unwrap();
    let token = config["websocket"]["token"].as_str().unwrap().to_owned();
    let mut person = Rpc::person(&a.socket).await;
    person
        .ok(
            "_acpmux/peer_add",
            json!({"name": "b", "url": format!("ws://{}", b.listen.as_deref().unwrap()),
                   "token": token, "peerToken": peer_token, "wait": true}),
        )
        .await;
    let new = json!({"cwd": b.dir.join("work"), "mcpServers": [],
        "_meta": {"acpmux": {"name": "lane", "peer": "b"}}});
    let id = person.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned();
    (a, b, person, id)
}

/// The person passes over the suggestions of a chat on the peer until they stop coming: those
/// passes are theirs, so their own daemon's tally holds them and a chat on their own machine is
/// gated by the same tally. Before, the peer counted them in its own tally and the person's
/// machine never heard of them.
#[tokio::test]
async fn passes_through_a_peer_count_against_the_persons_own_gate() {
    let (a, b, mut person, id) = person_with_a_peer_chat("tally", json!({}), json!({})).await;
    let (first, _) = person.turn(&id, "suggest: Ship it").await;
    assert_eq!(first.as_deref(), Some("Ship it"), "a new person starts at the prior");
    let mut passes = 0;
    loop {
        // Anything but the suggestion: a pass.
        let (shown, _) = person.turn(&id, "suggest: Ship it").await;
        passes += 1;
        if shown.is_none() {
            break;
        }
        assert!(passes < 12, "the person's passes never withheld a suggestion");
    }
    let tally = &a.tallies()["fake/harness"];
    assert!(
        tally["passed"].as_f64().is_some_and(|p| p > 5.0),
        "the person's own daemon kept no tally of the passes on the peer: {}",
        a.tallies()
    );

    // A chat on the person's own machine, same harness: the same gate, so withheld too.
    let local = person
        .ok("session/new", json!({"cwd": a.dir.join("work"), "mcpServers": []}))
        .await["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let (shown, update) = person.turn(&local, "suggest: Run the tests").await;
    assert_eq!(shown, None, "the local chat's gate did not hear the passes on the peer: {update}");
    assert!(
        update["_meta"]["acpmux"]["suggestionWithheld"]["estimate"]
            .as_f64()
            .is_some_and(|e| e < 0.25),
        "{update}"
    );
    drop(b);
}

/// The person's `agents.promptSuggestions` off on their own machine turns off suggestions of a
/// chat on a peer whose own settings file leaves them on.
#[tokio::test]
async fn a_peer_chat_follows_the_persons_own_switch() {
    let off = json!({"agents": {"promptSuggestions": false}});
    let (_a, _b, mut person, id) = person_with_a_peer_chat("switch", off, json!({})).await;
    let (shown, update) = person.turn(&id, "suggest: Ship it").await;
    assert_eq!(shown, None, "the peer's switch beat the person's: {update}");
    assert_eq!(update["_meta"]["acpmux"]["suggestionWithheld"]["setting"], "off", "{update}");
}

/// The person's switch on, the peer's off (its file is not the person's): still shown.
#[tokio::test]
async fn a_peer_chat_shows_suggestions_when_the_persons_switch_is_on() {
    let off = json!({"agents": {"promptSuggestions": false}});
    let (_a, _b, mut person, id) = person_with_a_peer_chat("on", json!({}), off).await;
    let (shown, update) = person.turn(&id, "suggest: Ship it").await;
    assert_eq!(shown.as_deref(), Some("Ship it"), "{update}");
}
