//! A Claude agent the daemon starts signs in the way the person's terminal
//! does (P1: two Chief subagents failed at once with "Not logged in · Please
//! run /login"). Each case runs the real `acpmux daemon run` the way the
//! Chief, launchd or a non-login ssh shell starts it (no `ACPMUX_LOGIN_ENV`,
//! no `XPC_SERVICE_NAME`, a bare environment) with a fake HOME whose login
//! shell (`$SHELL -l -i -c`) reads `~/.fakerc`, and a stand-in Claude Code
//! (`fake_claude.py`, FAKE_CLAUDE_AUTH=1) that looks for a sign-in the way
//! Claude Code does and says what it found, or fails like Claude Code.

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
const SUBROUTER: &str = "http://100.89.225.106:31415";

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

    /// The whole answer: `result` or `error`.
    async fn answer(&mut self, method: &str, params: Value) -> Value {
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

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let v = self.answer(method, params).await;
        assert!(v.get("error").is_none(), "{method} failed: {v}");
        v["result"].clone()
    }
}

fn write_executable(path: &Path, text: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// A scratch home: `home/` (the fake HOME), its login shell `loginsh`
/// (sources `~/.fakerc`, then runs the `-c` script), and `rc` as `~/.fakerc`.
fn scratch(tag: &str, rc: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("acae-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("home/.claude")).unwrap();
    let dir = std::fs::canonicalize(&dir).unwrap();
    write_executable(
        &dir.join("loginsh"),
        "#!/bin/sh\nfor a; do last=$a; done\n. \"$HOME/.fakerc\"\neval \"$last\"\n",
    );
    std::fs::write(dir.join("home/.fakerc"), rc).unwrap();
    dir
}

struct Daemon {
    child: std::process::Child,
    socket: PathBuf,
    dir: PathBuf,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        unsafe {
            libc::kill(self.child.id() as i32, libc::SIGTERM);
        }
        let deadline = Instant::now() + Duration::from_secs(8);
        while Instant::now() < deadline {
            if self.child.try_wait().ok().flatten().is_some() {
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// The daemon the way the Chief or launchd starts it: a bare environment
/// (only PATH for python3, the fake HOME and its login shell) plus `extra`.
async fn start(dir: &Path, harnesses: Value, extra: &[(&str, &str)]) -> Daemon {
    let config = json!({"harnesses": harnesses, "defaultHarness": "claude", "permissionPolicy": "approve-all"});
    std::fs::write(dir.join("config.json"), config.to_string()).unwrap();
    let socket = dir.join("s.sock");
    let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_acpmux"));
    cmd.args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "info"])
        .env_clear()
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("HOME", dir.join("home"))
        .env("SHELL", dir.join("loginsh"))
        .env("TMPDIR", std::env::temp_dir())
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_AGENT_HOSTS", "0")
        .envs(extra.iter().copied())
        .current_dir(dir)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::fs::File::create(dir.join("daemon.stderr")).unwrap());
    let mut child = cmd.spawn().unwrap();
    // The readiness line, then the daemon's log (also on stdout) into daemon.out.
    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = tokio::sync::oneshot::channel();
    let out_path = dir.join("daemon.out");
    std::thread::spawn(move || {
        use std::io::Write;
        let mut out = std::fs::File::create(out_path).unwrap();
        let mut tx = Some(tx);
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true)
                && let Some(tx) = tx.take()
            {
                let _ = tx.send(());
            }
            let _ = writeln!(out, "{line}");
        }
    });
    let ok = tokio::time::timeout(Duration::from_secs(20), rx).await.unwrap();
    assert!(ok.is_ok(), "the daemon exited without a readiness line");
    Daemon { child, socket, dir: dir.to_path_buf() }
}

fn claude(env: Value) -> Value {
    let mut env = env;
    env["FAKE_CLAUDE_AUTH"] = json!("1");
    json!({"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio", "env": env})
}

/// One prompt in a new session on `harness`: Ok(the reply as JSON) or
/// Err(the turn's error text), plus the turn_result record.
async fn ask(d: &Daemon, harness: &str) -> (Result<Value, String>, Value) {
    let mut rpc = Rpc::connect(&d.socket).await;
    let s = rpc
        .call(
            "session/new",
            json!({"cwd": d.dir, "mcpServers": [], "_meta": {"acpmux": {"harness": harness, "name": "auth"}}}),
        )
        .await;
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let answer = rpc
        .answer(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "auth?"}]}),
        )
        .await;
    let events =
        rpc.call("_acpmux/events", json!({"sessionId": id, "kinds": ["turn_result"]})).await;
    let turn = events["events"]
        .as_array()
        .and_then(|e| e.last())
        .map(|e| e["msg"].clone())
        .unwrap_or_default();
    if let Some(e) = answer.get("error") {
        return (Err(e["message"].as_str().unwrap_or_default().to_owned()), turn);
    }
    let events = rpc
        .call("_acpmux/events", json!({"sessionId": id, "kinds": ["agent_message_chunk"]}))
        .await;
    let text: String = events["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|e| e.pointer("/msg/params/update/content/text").and_then(Value::as_str))
        .collect();
    (Ok(serde_json::from_str(&text).unwrap_or_else(|_| panic!("reply is JSON: {text}"))), turn)
}

fn found(reply: &Result<Value, String>) -> &Value {
    match reply {
        Ok(v) => v,
        Err(e) => panic!("the agent is not signed in: {e}"),
    }
}

/// (a) The team route only in the login shell rc: the agent gets it.
#[tokio::test]
async fn a_route_only_in_the_login_shell_reaches_the_agent() {
    let dir = scratch(
        "sr",
        &format!(
            "export ANTHROPIC_BASE_URL={SUBROUTER}\nexport ANTHROPIC_AUTH_TOKEN=ignored-by-router\n"
        ),
    );
    let d = start(&dir, json!({"claude": claude(json!({}))}), &[]).await;
    let (reply, _) = ask(&d, "claude").await;
    let v = found(&reply);
    assert_eq!(v["auth"], json!(["ANTHROPIC_AUTH_TOKEN"]), "{v}");
    assert_eq!(v["base"], SUBROUTER, "{v}");
}

/// (a2) A daemon started inside a Claude Code session: that session's own
/// route is dropped, and the agent gets the person's login route instead
/// (before: both were dropped, and the agent was not signed in).
#[tokio::test]
async fn a_daemon_inside_a_claude_session_gives_agents_the_login_route() {
    let dir = scratch(
        "nest",
        &format!(
            "export ANTHROPIC_BASE_URL={SUBROUTER}\nexport ANTHROPIC_AUTH_TOKEN=ignored-by-router\n"
        ),
    );
    let d = start(
        &dir,
        json!({"claude": claude(json!({}))}),
        &[
            ("CLAUDECODE", "1"),
            ("ANTHROPIC_BASE_URL", "http://127.0.0.1:9/parent-session-proxy"),
            ("ANTHROPIC_AUTH_TOKEN", "parent-session-token"),
        ],
    )
    .await;
    let (reply, _) = ask(&d, "claude").await;
    let v = found(&reply);
    assert_eq!(v["base"], SUBROUTER, "{v}");
    assert_eq!(v["auth"], json!(["ANTHROPIC_AUTH_TOKEN"]), "{v}");
}

/// (b) `apiKeyHelper` in ~/.claude/settings.json whose command is only on
/// the login shell's PATH.
#[tokio::test]
async fn an_api_key_helper_on_the_login_path_signs_in() {
    let dir = scratch("helper", "export PATH=\"$HOME/bin:$PATH\"\n");
    std::fs::create_dir_all(dir.join("home/bin")).unwrap();
    write_executable(&dir.join("home/bin/team-key"), "#!/bin/sh\necho sk-from-helper\n");
    std::fs::write(dir.join("home/.claude/settings.json"), r#"{"apiKeyHelper": "team-key"}"#)
        .unwrap();
    let d = start(&dir, json!({"claude": claude(json!({}))}), &[]).await;
    let (reply, _) = ask(&d, "claude").await;
    assert_eq!(found(&reply)["auth"], json!(["apiKeyHelper"]));
}

/// (c) CLAUDE_CONFIG_DIR set in the login shell, to a home with its own key.
#[tokio::test]
async fn a_claude_home_from_the_login_shell_is_the_agents() {
    let dir = scratch("cfg", "export CLAUDE_CONFIG_DIR=\"$HOME/work-claude\"\n");
    std::fs::create_dir_all(dir.join("home/work-claude")).unwrap();
    std::fs::write(
        dir.join("home/work-claude/settings.json"),
        r#"{"env": {"ANTHROPIC_API_KEY": "sk-work"}}"#,
    )
    .unwrap();
    let d = start(&dir, json!({"claude": claude(json!({}))}), &[]).await;
    let (reply, _) = ask(&d, "claude").await;
    let v = found(&reply);
    assert_eq!(v["home"], dir.join("home/work-claude").to_string_lossy().as_ref(), "{v}");
    assert_eq!(v["auth"], json!(["ANTHROPIC_API_KEY"]), "{v}");
}

/// (d) Bedrock switched on in the login shell, with an AWS profile.
#[tokio::test]
async fn bedrock_from_the_login_shell_reaches_the_agent() {
    let dir = scratch("bedrock", "export CLAUDE_CODE_USE_BEDROCK=1\nexport AWS_PROFILE=work\n");
    let d = start(&dir, json!({"claude": claude(json!({}))}), &[]).await;
    let (reply, _) = ask(&d, "claude").await;
    let v = found(&reply);
    assert_eq!(v["auth"], json!(["bedrock"]), "{v}");
    assert_eq!(v["awsProfile"], "work", "{v}");
}

/// (e) A `claude` that a version manager puts only on the login PATH.
#[tokio::test]
async fn a_claude_only_on_the_login_path_starts() {
    let dir = scratch(
        "mise",
        "export PATH=\"$HOME/.local/share/mise/shims:$PATH\"\nexport ANTHROPIC_API_KEY=sk-mise\n",
    );
    let shims = dir.join("home/.local/share/mise/shims");
    std::fs::create_dir_all(&shims).unwrap();
    write_executable(
        &shims.join("claude"),
        &format!("#!/bin/sh\nexec env FAKE_CLAUDE_VIA=mise-shim python3 {FAKE_CLAUDE} \"$@\"\n"),
    );
    let harness =
        json!({"argv": ["claude"], "kind": "claude-stdio", "env": {"FAKE_CLAUDE_AUTH": "1"}});
    let d = start(&dir, json!({"claude": harness}), &[]).await;
    let (reply, _) = ask(&d, "claude").await;
    let v = found(&reply);
    assert_eq!(v["via"], "mise-shim", "{v}");
    assert_eq!(v["auth"], json!(["ANTHROPIC_API_KEY"]), "{v}");
}

/// (f) No sign-in anywhere: the turn fails with a message that says so,
/// what the terminal has, and the fix; never Claude's bare line alone.
#[tokio::test]
async fn no_sign_in_says_so_and_how_to_fix_it() {
    let dir = scratch("none", "export EDITOR=vi\n");
    let d = start(&dir, json!({"claude": claude(json!({}))}), &[]).await;
    let (reply, turn) = ask(&d, "claude").await;
    let Err(text) = reply else { panic!("signed in without a sign-in: {reply:?}") };
    for part in [
        "Claude is not signed in here.",
        "This agent found no sign-in (Claude home ~/.claude).",
        "Your terminal has no Claude sign-in either.",
        "Run `claude /login` in a terminal",
        "(Claude said: Not logged in · Please run /login)",
    ] {
        assert!(text.contains(part), "missing {part:?} in {text:?}");
    }
    assert_eq!(turn["status"], "failed", "{turn}");
    assert_eq!(turn["errorText"], text.as_str(), "{turn}");
}

/// The P1 itself: a preset or profile moves the agent to another Claude
/// home with no sign-in, while the terminal signs in through
/// ~/.claude/settings.json. The message names both homes and the fix.
#[tokio::test]
async fn an_agent_on_another_claude_home_names_both_homes() {
    let dir = scratch("home", "export EDITOR=vi\n");
    std::fs::write(
        dir.join("home/.claude/settings.json"),
        format!(
            r#"{{"env": {{"ANTHROPIC_BASE_URL": "{SUBROUTER}", "ANTHROPIC_AUTH_TOKEN": "x"}}}}"#
        ),
    )
    .unwrap();
    std::fs::create_dir_all(dir.join("home/.chief/claude")).unwrap();
    let chief_home = dir.join("home/.chief/claude");
    let d =
        start(&dir, json!({"claude": claude(json!({"CLAUDE_CONFIG_DIR": chief_home}))}), &[]).await;
    let (reply, _) = ask(&d, "claude").await;
    let Err(text) = reply else { panic!("signed in on an empty home: {reply:?}") };
    for part in [
        "Claude is not signed in here.",
        "This agent found no sign-in (Claude home ~/.chief/claude).",
        "Your terminal signs in with ANTHROPIC_AUTH_TOKEN in ~/.claude/settings.json through a custom API endpoint (100.89.225.106:31415, ANTHROPIC_BASE_URL).",
        "Remove CLAUDE_CONFIG_DIR from this agent's profile",
    ] {
        assert!(text.contains(part), "missing {part:?} in {text:?}");
    }
}

/// The login shell runs at most once per start, and its cache keeps no
/// secret value: a start with a matching fingerprint and no secret to
/// fetch never runs the shell; an edited rc file runs it again.
#[tokio::test]
async fn the_login_shell_is_cached_without_secrets_and_rerun_on_change() {
    let rc = "echo run >> \"$HOME/shell-runs\"\nexport ANTHROPIC_AUTH_TOKEN=s3cret-value\nexport TEAM_ROUTE_NAME=plain-value\n";
    let dir = scratch("cache", rc);
    let runs =
        || std::fs::read_to_string(dir.join("home/shell-runs")).unwrap_or_default().lines().count();
    {
        let d = start(&dir, json!({"claude": claude(json!({}))}), &[]).await;
        let (reply, _) = ask(&d, "claude").await;
        assert_eq!(found(&reply)["auth"], json!(["ANTHROPIC_AUTH_TOKEN"]));
    }
    assert_eq!(runs(), 1);
    let cache = dir.join("login-env.json");
    let text = std::fs::read_to_string(&cache).unwrap();
    assert!(!text.contains("s3cret-value"), "a secret value in the cache: {text}");
    let v: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(v["secretNames"], json!(["ANTHROPIC_AUTH_TOKEN"]), "{v}");
    assert_eq!(v["vars"]["TEAM_ROUTE_NAME"], "plain-value", "{v}");
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(std::fs::metadata(&cache).unwrap().permissions().mode() & 0o777, 0o600);
    // No secret: the next start uses the cache and never runs the shell.
    std::fs::write(
        dir.join("home/.fakerc"),
        "echo run >> \"$HOME/shell-runs\"\nexport TEAM_ROUTE_NAME=plain-value\n",
    )
    .unwrap();
    {
        let _d = start(&dir, json!({"claude": claude(json!({}))}), &[]).await;
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert_eq!(runs(), 2, "the edited rc file ran the shell again");
    {
        let d = start(&dir, json!({"claude": claude(json!({}))}), &[]).await;
        let (reply, _) = ask(&d, "claude").await;
        assert!(reply.is_err(), "no token is left: {reply:?}");
    }
    assert_eq!(runs(), 2, "a matching cache with no secret runs no shell");
}

/// A login shell that hangs: the daemon stops waiting after 3 s, and
/// agents start without it (falling back to the daemon's environment).
#[tokio::test]
async fn a_hung_login_shell_holds_agents_at_most_three_seconds() {
    let dir = scratch("hang", "sleep 30\nexport ANTHROPIC_API_KEY=never\n");
    let started = Instant::now();
    let d =
        start(&dir, json!({"claude": claude(json!({"ANTHROPIC_API_KEY": "from-profile"}))}), &[])
            .await;
    let (reply, _) = ask(&d, "claude").await;
    let elapsed = started.elapsed();
    assert_eq!(found(&reply)["auth"], json!(["ANTHROPIC_API_KEY"]));
    assert!(elapsed < Duration::from_secs(6), "first reply after {elapsed:?}");
    let log = std::fs::read_to_string(dir.join("daemon.out")).unwrap_or_default()
        + &std::fs::read_to_string(dir.join("daemon.stderr")).unwrap_or_default();
    assert!(log.contains("login shell env: no result within 3s"), "{log}");
}
