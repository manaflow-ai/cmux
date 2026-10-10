//! The Chief's acpmux presets are built in (P0 after cx-1l61): a Chief
//! started outside the cmux app (the always-on brain, `cmux chief -p`)
//! installs them without the person key, because the client names a built-in
//! preset and sends no env. acpmux fills the env itself: fixed flags, cache
//! keys from the name, codex paths from its own Chief home and bundle, and a
//! subagent's cmux sockets and PATH from its own process environment. Any env
//! a client sends is still the person's to set. The real daemon binary, over
//! its unix socket.
#![cfg(unix)]

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const REASON: &str = "permission.person_required";

struct Rpc {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
}

impl Rpc {
    async fn connect(path: &Path) -> Self {
        let s = tokio::net::UnixStream::connect(path).await.expect("connect to daemon socket");
        let (rd, wr) = s.into_split();
        Self { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0 }
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.lines.next_line())
                .await
                .expect("daemon answered in time")
                .unwrap()
                .expect("daemon closed the socket");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }
}

struct Daemon {
    child: std::process::Child,
    socket: PathBuf,
    dir: PathBuf,
}

impl Daemon {
    /// The real daemon, started the way the brain's LaunchAgent starts it:
    /// its Chief home and the cmux sockets in its own environment.
    fn start(tag: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("acb-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("mux")).unwrap();
        let dir = std::fs::canonicalize(&dir).unwrap();
        std::fs::write(
            dir.join("config.json"),
            json!({
                "harnesses": {
                    "fclaude": {"argv": ["python3", FAKE], "family": "claude"},
                    "fcodex": {"argv": ["python3", FAKE], "family": "codex"},
                },
                "defaultHarness": "fclaude",
                "permissionPolicy": "ask",
            })
            .to_string(),
        )
        .unwrap();
        let socket = dir.join("s.sock");
        let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_acpmux"))
            .args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"])
            .env("ACPMUX_HOME", &dir)
            .env("ACPMUX_SOCKET", &socket)
            .env("ACPMUX_CHIEF_MUX_HOME", dir.join("mux"))
            .env("CMUX_TUI_SOCKET", "/tmp/brain-daemon.sock")
            .env("CMUX_MUX_SOCKET", "/tmp/brain-daemon.sock")
            .env("CMUX_CHIEF_OWNER_SOCKET", "/tmp/brain-owner.sock")
            .env("PATH", "/usr/bin:/bin")
            .env_remove("ACPMUX_LOGIN_ENV")
            .env_remove("CMUX_BUNDLED_CLI_PATH")
            .env_remove("CMUX_SOCKET_PATH")
            .env_remove("CMUX_APP_DAEMON_SOCKET")
            .env_remove("XPC_SERVICE_NAME")
            .env_remove("CLAUDECODE")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let ready = BufReader::new(stdout)
            .lines()
            .map_while(Result::ok)
            .any(|line| serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true));
        assert!(ready, "the daemon exited before its ready line");
        Daemon { child, socket, dir }
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

fn reason(v: &Value) -> &str {
    v["error"]["data"]["reason"].as_str().unwrap_or_default()
}

/// The env of preset `name` as the daemon stored it.
async fn stored_env(c: &mut Rpc, name: &str) -> Value {
    let r = c.call("_acpmux/presets", json!({"name": name})).await;
    assert!(r.get("error").is_none(), "{name}: {r}");
    r["result"]["env"].clone()
}

#[tokio::test]
async fn a_chief_outside_the_app_installs_its_built_in_presets_without_env() {
    let d = Daemon::start("install");
    // A plain socket client: the brain's Chief host, not the person.
    let mut chief = Rpc::connect(&d.socket).await;
    let compact = "optchat-compact-1a2b3c4d-slot-3";
    let r = chief
        .call(
            "_acpmux/presets",
            json!({"name": compact, "set": {"harness": "fclaude", "description": "compactor slot"}}),
        )
        .await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(
        stored_env(&mut chief, compact).await,
        json!({
            "ACPMUX_AGENT_TOOLS": "0",
            "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
            "CLAUDE_CODE_DISABLE_BUNDLED_SKILLS": "1",
            "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
            "CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK": "1",
            "DISABLE_AUTOUPDATER": "1",
            "SUBROUTER_SESSION_KEY": "optchat-1a2b3c4d-compact",
        })
    );
    // A later change of another field keeps the built-in env.
    let r = chief
        .call("_acpmux/presets", json!({"name": compact, "set": {"description": "node 7"}}))
        .await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(
        stored_env(&mut chief, compact).await["SUBROUTER_SESSION_KEY"],
        "optchat-1a2b3c4d-compact"
    );

    // Codex: the paths come from the daemon's own Chief home, never the client.
    let turn = "optchat-chief-codex-1a2b3c4d";
    let r =
        chief.call("_acpmux/presets", json!({"name": turn, "set": {"harness": "fcodex"}})).await;
    assert!(r.get("error").is_none(), "{r}");
    let env = stored_env(&mut chief, turn).await;
    let mux = d.dir.join("mux");
    assert_eq!(env["CODEX_HOME"], mux.join("optchat/turn-codex").display().to_string(), "{env}");
    assert_eq!(env["CODEX_PROMPT_CACHE_KEY"], "optchat-1a2b3c4d-turn", "{env}");
    let slot = "optchat-compact-1a2b3c4d-slot-0";
    let r =
        chief.call("_acpmux/presets", json!({"name": slot, "set": {"harness": "fcodex"}})).await;
    assert!(r.get("error").is_none(), "{r}");
    let env = stored_env(&mut chief, slot).await;
    assert_eq!(
        env["CODEX_HOME"],
        mux.join("optchat/compactor-codex/slot-0").display().to_string(),
        "{env}"
    );
    assert_eq!(
        env["HOME"],
        mux.join("optchat/compactor-codex/home").display().to_string(),
        "{env}"
    );

    // A subagent: the daemon's own cmux sockets and its bundle first on PATH.
    let sub = "optchat-sub-1a2b3c4d";
    let r =
        chief.call("_acpmux/presets", json!({"name": sub, "set": {"harness": "fclaude"}})).await;
    assert!(r.get("error").is_none(), "{r}");
    let env = stored_env(&mut chief, sub).await;
    assert_eq!(env["CMUX_TUI_SOCKET"], "/tmp/brain-daemon.sock", "{env}");
    assert_eq!(env["CMUX_MUX_SOCKET"], "/tmp/brain-daemon.sock", "{env}");
    assert_eq!(env["CMUX_CHIEF_OWNER_SOCKET"], "/tmp/brain-owner.sock", "{env}");
    assert_eq!(env["OPTCHAT_SUBAGENT"], "1", "{env}");
    let bundle = std::path::Path::new(env!("CARGO_BIN_EXE_acpmux")).parent().unwrap();
    assert_eq!(env["PATH"], format!("{}:/usr/bin:/bin", bundle.display()), "{env}");
}

#[tokio::test]
async fn any_env_a_client_sends_stays_the_persons_to_set() {
    let d = Daemon::start("refuse");
    let mut chief = Rpc::connect(&d.socket).await;
    for (name, env) in [
        // A built-in name with a changed value, an added key, or a PATH.
        ("optchat-compact-1a2b3c4d-slot-3", json!({"SUBROUTER_SESSION_KEY": "other"})),
        ("optchat-chief-1a2b3c4d", json!({"NODE_OPTIONS": "--require /tmp/x.js"})),
        ("optchat-sub-1a2b3c4d", json!({"PATH": "/tmp/evil:/usr/bin"})),
        ("optchat-chief-codex-1a2b3c4d", json!({"CODEX_HOME": "/tmp/attacker"})),
        // A name outside the built-in grammar.
        ("optchat-compact-1a2b3c4d-slot-x", json!({"ACPMUX_AGENT_TOOLS": "0"})),
        ("my-preset", json!({"CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"})),
    ] {
        let r = chief
            .call(
                "_acpmux/presets",
                json!({"name": name, "set": {"harness": "fclaude", "env": env}}),
            )
            .await;
        assert_eq!(reason(&r), REASON, "{name} {env}: {r}");
    }
}
