//! Sub-sessions with real agents: a real `acpmux daemon run` starts a real
//! Claude Code session and a real Codex session; each agent calls the
//! `cmux-subsessions` tools (`subsession_mcp.rs`) it gets by default, starts
//! one child, and the daemon refuses the second child (width) and the
//! child's own child (depth) with advice the agent reads back.
//!
//! Needs the agent CLIs and a model route (the subrouter ignores the key):
//!
//! ```text
//! ACPMUX_SUBSESSIONS_LIVE_CLAUDE=/abs/claude ANTHROPIC_BASE_URL=http://127.0.0.1:31415 \
//! ACPMUX_SUBSESSIONS_LIVE_CODEX=/abs/codex CODEX_HOME=/path/to/home \
//!   cargo nextest run -p acpmux --test subsessions_live
//! ```
//!
//! Without the variable for an agent its test says so and passes (CI has no model).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// Live by design (only with the variables above): the real agent CLIs and
// their model route are kept; nothing else of the host.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "ACPMUX_SUBSESSIONS_LIVE_CLAUDE",
    "ACPMUX_SUBSESSIONS_LIVE_CODEX",
    "ANTHROPIC_BASE_URL",
    "CODEX_HOME",
]);

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const TURN: Duration = Duration::from_secs(600);

struct Daemon {
    child: Option<Child>,
    home: PathBuf,
    socket: PathBuf,
    project: PathBuf,
}

impl Daemon {
    /// A daemon whose one harness is `profile`, with sub-session limits
    /// width 1 and depth 1 in the settings file.
    fn start(tag: &str, cli: &Path, harness: &str, profile: Value) -> Self {
        assert!(cli.is_absolute(), "the agent CLI path must be absolute");
        let home = std::env::temp_dir().join(format!("asl-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let project = home.join("p");
        std::fs::create_dir_all(&project).unwrap();
        let _ =
            std::process::Command::new("git").args(["init", "-q"]).current_dir(&project).status();
        std::fs::write(
            home.join("config.json"),
            json!({"harnesses": {harness: profile}, "defaultHarness": harness, "permissionPolicy": "approve-all"})
                .to_string(),
        )
        .unwrap();
        let settings = home.join("cmux-next.json");
        std::fs::write(
            &settings,
            r#"{"agents": {"subsessions": {"maxChildren": 1, "maxDepth": 1}}}"#,
        )
        .unwrap();
        let socket = home.join("s.sock");
        let path = format!(
            "{}:{}:/usr/bin:/bin:/usr/sbin:/sbin",
            daemon_env::tool_dir(&["git"]).display(),
            cli.parent().expect("the CLI's directory").display()
        );
        let mut child = daemon_env::command(&home, daemon_env::Agents::StandIn, &[])
            .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "warn"])
            .env("PATH", path)
            .env("ACPMUX_PROBE_HARNESSES", harness)
            .env("ACPMUX_HOME", &home)
            .env("ACPMUX_SOCKET", &socket)
            .env("CMUX_NEXT_CONFIG_FILE", &settings)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("start daemon");
        let mut stdout = BufReader::new(child.stdout.take().unwrap());
        let mut ready = String::new();
        while stdout.read_line(&mut ready).unwrap() > 0 && !ready.contains("\"ready\":true") {
            ready.clear();
        }
        assert!(ready.contains("\"ready\":true"), "daemon not ready");
        let socket = serde_json::from_str::<Value>(&ready)
            .ok()
            .and_then(|v| v["socket"].as_str().map(PathBuf::from))
            .unwrap_or(socket);
        Self { child: Some(child), home, socket, project }
    }

    async fn rpc(&self) -> Rpc {
        Rpc::connect(&self.socket).await
    }

    /// The agent's own text in the session's log.
    fn text(&self, session: &str) -> String {
        let dir = self.home.join("sessions").join(session).join("events");
        let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
            .map(|d| d.filter_map(|e| e.ok().map(|e| e.path())).collect())
            .unwrap_or_default();
        files.sort();
        files
            .iter()
            .flat_map(|f| {
                std::fs::read_to_string(f)
                    .unwrap_or_default()
                    .lines()
                    .map(str::to_owned)
                    .collect::<Vec<_>>()
            })
            .filter_map(|l| serde_json::from_str::<Value>(&l).ok())
            .filter(|e| e["kind"] == "agent_message_chunk")
            .filter(|e| e["msg"]["params"]["_meta"]["acpmux"]["subagent"].is_null())
            .filter_map(|e| {
                e["msg"]["params"]["update"]["content"]["text"].as_str().map(str::to_owned)
            })
            .collect()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        if let Ok(dir) = std::fs::read_dir(self.home.join("hosts")) {
            for path in dir.filter_map(|e| e.ok().map(|e| e.path())) {
                if path.extension().and_then(|e| e.to_str()) != Some("json") {
                    continue;
                }
                if let Ok(r) =
                    serde_json::from_slice::<Value>(&std::fs::read(&path).unwrap_or_default())
                {
                    for pid in
                        [r["harness_pid"].as_i64(), r["host_pid"].as_i64()].into_iter().flatten()
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
            let line = tokio::time::timeout(TURN, self.lines.next_line())
                .await
                .expect("daemon answered in time")
                .unwrap()
                .expect("daemon closed the socket");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
        }
    }
}

const PARENT_TASK: &str = "You have tools from the MCP server named cmux-subsessions. Use them exactly as follows, and do nothing else (no files, no shell):
1. Call start_session with name \"kid\" and this prompt: \"You have tools from the MCP server named cmux-subsessions. Call its start_session tool once with name grandkid and prompt say hi. Then reply with one line: GRANDKID: followed by the exact text the tool returned.\"
2. Call start_session a second time, with name \"kid2\" and prompt \"say hi\".
3. Call wait_for_sessions with no arguments. If it says timedOut, call it again, until kid has finished.
4. Reply with two lines: SECOND: followed by the exact text the second start_session call returned, then KID: followed by kid's lastReply.";

/// The parent starts one child; the second start is refused for width and
/// the child's own start for depth; the session list shows the one link.
async fn agents_start_one_child_and_are_refused_beyond_the_limits(d: &Daemon) {
    let mut c = d.rpc().await;
    let parent =
        c.call("session/new", json!({"cwd": d.project, "mcpServers": []})).await["sessionId"]
            .as_str()
            .expect("session id")
            .to_owned();
    let r = c
        .call(
            "session/prompt",
            json!({"sessionId": parent, "prompt": [{"type": "text", "text": PARENT_TASK}]}),
        )
        .await;
    assert_eq!(r["stopReason"], "end_turn", "{r}");

    let list = c.call("_acpmux/sessions", json!({})).await;
    let sessions = list["sessions"].as_array().expect("sessions").clone();
    let children: Vec<&Value> =
        sessions.iter().filter(|s| s["startedBy"] == parent.as_str()).collect();
    assert_eq!(children.len(), 1, "one child within width 1: {list}");
    let kid = children[0];
    assert_eq!(kid["depth"], 1, "{kid}");
    assert_eq!(kid["shortName"], "kid", "{kid}");
    assert!(
        sessions.iter().all(|s| s["depth"].as_u64().unwrap_or(0) <= 1),
        "nothing deeper than 1: {list}"
    );
    let parent_row =
        sessions.iter().find(|s| s["sessionId"] == parent.as_str()).expect("parent row");
    assert_eq!(parent_row["depth"], 0, "{parent_row}");
    assert_eq!(parent_row["children"], 1, "{parent_row}");

    // The child's turn may outlast the parent's when the agent did not wait.
    let kid_id = kid["sessionId"].as_str().unwrap().to_owned();
    c.call(
        "_acpmux/wait",
        json!({"sessions": [kid_id], "until": ["ready", "closed"], "timeoutMs": 300_000}),
    )
    .await;
    let parent_text = d.text(&parent).to_lowercase();
    let kid_text = d.text(&kid_id).to_lowercase();
    eprintln!("parent said: {parent_text}\nkid said: {kid_text}");
    assert!(
        parent_text.contains("width limit"),
        "the parent read the width refusal: {parent_text}"
    );
    assert!(kid_text.contains("depth limit"), "the child read the depth refusal: {kid_text}");
}

#[tokio::test(flavor = "multi_thread")]
async fn claude_code_starts_sub_sessions_within_the_limits() {
    let Ok(claude) = std::env::var("ACPMUX_SUBSESSIONS_LIVE_CLAUDE") else {
        eprintln!("ACPMUX_SUBSESSIONS_LIVE_CLAUDE is not set; no live Claude Code run");
        return;
    };
    let base = std::env::var("ANTHROPIC_BASE_URL").expect("ANTHROPIC_BASE_URL: the model route");
    let d = Daemon::start(
        "claude",
        Path::new(&claude),
        "claude",
        json!({"argv": [claude], "kind": "claude-stdio",
               "env": {"ANTHROPIC_BASE_URL": base, "ANTHROPIC_API_KEY": "route-ignores-this"}}),
    );
    agents_start_one_child_and_are_refused_beyond_the_limits(&d).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn codex_starts_sub_sessions_within_the_limits() {
    let Ok(codex) = std::env::var("ACPMUX_SUBSESSIONS_LIVE_CODEX") else {
        eprintln!("ACPMUX_SUBSESSIONS_LIVE_CODEX is not set; no live Codex run");
        return;
    };
    let codex_home = std::env::var("CODEX_HOME").expect("CODEX_HOME with model access");
    let d = Daemon::start(
        "codex",
        Path::new(&codex),
        "codex-app-server",
        json!({"argv": [codex, "app-server"], "env": {"CODEX_HOME": codex_home}}),
    );
    agents_start_one_child_and_are_refused_beyond_the_limits(&d).await;
}
