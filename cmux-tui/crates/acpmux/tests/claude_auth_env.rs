//! A Claude agent the daemon starts signs in the way the person's terminal
//! does (P1: two Chief subagents failed at once with "Not logged in · Please
//! run /login"). Each case runs the real `acpmux daemon run` the way the
//! Chief, launchd or a non-login ssh shell starts it (no `ACPMUX_LOGIN_ENV`,
//! no `XPC_SERVICE_NAME`, a bare environment) with a fake HOME whose login
//! shell (`$SHELL -l -i -c`) reads `~/.zshrc`, and a stand-in Claude Code
//! (`fake_claude.py`, FAKE_CLAUDE_AUTH=1) that looks for a sign-in the way
//! Claude Code does and says what it found, or fails like Claude Code.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

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
/// (sources `~/.zshrc`, then runs the `-c` script), and `rc` as `~/.zshrc`.
fn scratch(tag: &str, rc: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("acae-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("home/.claude")).unwrap();
    let dir = std::fs::canonicalize(&dir).unwrap();
    write_executable(
        &dir.join("loginsh"),
        "#!/bin/sh\nfor a; do last=$a; done\n. \"$HOME/.zshrc\"\neval \"$last\"\n",
    );
    std::fs::write(dir.join("home/.zshrc"), rc).unwrap();
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

/// The daemon the way the Chief or launchd starts it: the hermetic test
/// environment (`daemon_env`: a bare PATH with python3, never the host's, so
/// no real codex or claude is found; the fake HOME) with its login shell, plus
/// `extra`. A fleet host's real agent CLIs would be probed, and Codex's shell
/// snapshot sources the fake `~/.zshrc`, so the login shell would seem to run
/// more often than it does (cx-w014j).
async fn start(dir: &Path, harnesses: Value, extra: &[(&str, &str)]) -> Daemon {
    let config = json!({"harnesses": harnesses, "defaultHarness": "claude", "permissionPolicy": "approve-all"});
    start_config(dir, config, extra).await
}

async fn start_config(dir: &Path, config: Value, extra: &[(&str, &str)]) -> Daemon {
    std::fs::write(dir.join("config.json"), config.to_string()).unwrap();
    let socket = dir.join("s.sock");
    // The stand-in claude (fake_claude.py) is the only agent.
    let mut cmd = daemon_env::command(dir, daemon_env::Agents::StandIn, &[]);
    cmd.args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "info"])
        .env("SHELL", dir.join("loginsh"))
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
    let parent = [
        ("CLAUDECODE", "1"),
        ("ANTHROPIC_BASE_URL", "http://127.0.0.1:9/parent-session-proxy"),
        ("ANTHROPIC_AUTH_TOKEN", "parent-session-token"),
    ];
    // The first start runs the shell; the second starts from the cache,
    // whose token value is not stored: the parent's copy must not count.
    for start_no in 1..=2 {
        let d = start(&dir, json!({"claude": claude(json!({}))}), &parent).await;
        let (reply, _) = ask(&d, "claude").await;
        let v = found(&reply);
        assert_eq!(v["base"], SUBROUTER, "start {start_no}: {v}");
        assert_eq!(v["auth"], json!(["ANTHROPIC_AUTH_TOKEN"]), "start {start_no}: {v}");
    }
}

/// (a3) The daemon's prompt-cache switches never reach an agent; a harness
/// that sets one on purpose keeps it. Before: an acpmux client run from an
/// OptChat turn (whose settings env has DISABLE_PROMPT_CACHING=1) started
/// the NIGHTLY Chief daemon, and every agent it spawned sent no cache marks
/// (2026-10-19: 277 of 756 sampled requests read and wrote no cache).
#[tokio::test]
async fn the_daemons_prompt_cache_switches_never_reach_an_agent() {
    let dir = scratch("pcache", "export EDITOR=vi\n");
    let signed_in = json!({"ANTHROPIC_API_KEY": "sk-test"});
    let on_purpose = json!({"ANTHROPIC_API_KEY": "sk-test", "DISABLE_PROMPT_CACHING": "1"});
    let harnesses = json!({"claude": claude(signed_in), "marks": claude(on_purpose)});
    let switches = [
        ("DISABLE_PROMPT_CACHING", "1"),
        ("DISABLE_PROMPT_CACHING_OPUS", "1"),
        ("FORCE_PROMPT_CACHING_5M", "1"),
        ("ENABLE_PROMPT_CACHING_1H", "1"),
    ];
    // Started from inside a Claude Code turn, and with the switches in its
    // own environment only (the live daemon's state: a scrubbed start keeps
    // no CLAUDECODE).
    let inside: Vec<(&str, &str)> =
        [("CLAUDECODE", "1")].into_iter().chain(switches.iter().copied()).collect();
    for (case, extra) in [("inside a turn", inside.as_slice()), ("own env", switches.as_slice())] {
        for (harness, want) in
            [("claude", json!({})), ("marks", json!({"DISABLE_PROMPT_CACHING": "1"}))]
        {
            let d = start(&dir, harnesses.clone(), extra).await;
            let (reply, _) = ask(&d, harness).await;
            assert_eq!(found(&reply)["promptCache"], want, "{case}, {harness}: {reply:?}");
        }
    }
}

/// The values of one turn or session of whoever started the daemon (a Chief
/// turn's subrouter session key and seal, 2026-10-19) never reach an agent
/// the daemon spawns; a profile that sets one on purpose still passes it.
#[tokio::test]
async fn the_daemons_turn_values_never_reach_an_agent() {
    let dir = scratch("turnenv", "export EDITOR=vi\n");
    let signed_in = json!({"ANTHROPIC_API_KEY": "sk-test"});
    let keyed = json!({"ANTHROPIC_API_KEY": "sk-test", "SUBROUTER_SESSION_KEY": "preset-sub"});
    let harnesses = json!({"claude": claude(signed_in), "keyed": claude(keyed)});
    let turn = [
        ("SUBROUTER_SESSION_KEY", "optchat-home-turn"),
        ("CODEX_PROMPT_CACHE_KEY", "optchat-home-turn"),
        ("OPTCHAT_TURN_SEAL", "00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff"),
        ("OPTCHAT_SUBAGENT", "1"),
        ("AI_AGENT", "claude-code"),
    ];
    let inside: Vec<(&str, &str)> =
        [("CLAUDECODE", "1")].into_iter().chain(turn.iter().copied()).collect();
    for (case, extra) in [("inside a turn", inside.as_slice()), ("own env", turn.as_slice())] {
        for (harness, want) in
            [("claude", json!({})), ("keyed", json!({"SUBROUTER_SESSION_KEY": "preset-sub"}))]
        {
            let d = start(&dir, harnesses.clone(), extra).await;
            let (reply, _) = ask(&d, harness).await;
            assert_eq!(found(&reply)["turnScoped"], want, "{case}, {harness}: {reply:?}");
        }
    }
}

/// A Chief turn or compactor runs a fresh Claude process per turn; its
/// preset's SUBROUTER_SESSION_KEY with SUBROUTER_SESSION_HEADER=1 must reach
/// the API as `X-Subrouter-Session`, next to the route's own header lines,
/// or the sr2 gateway spreads the turns over accounts and their prompt
/// cache goes cold (a226: 43% of Chief turns rewrote 38k-83k tokens). A
/// preset without the opt-in (a subagent, one long session) sends none, and
/// the daemon's own turn values never become a header.
#[tokio::test]
async fn a_turn_session_key_becomes_the_subrouter_session_header() {
    let dir = scratch("srsession", "export EDITOR=vi\n");
    let route = "X-Subrouter-Agent: claude";
    let turn = json!({"ANTHROPIC_API_KEY": "sk-test", "ANTHROPIC_CUSTOM_HEADERS": route,
        "SUBROUTER_SESSION_KEY": "optchat-c0eb-turn", "SUBROUTER_SESSION_HEADER": "1"});
    let bare = json!({"ANTHROPIC_API_KEY": "sk-test",
        "SUBROUTER_SESSION_KEY": "optchat-c0eb-compact", "SUBROUTER_SESSION_HEADER": "1"});
    let sub = json!({"ANTHROPIC_API_KEY": "sk-test", "ANTHROPIC_CUSTOM_HEADERS": route,
        "SUBROUTER_SESSION_KEY": "optchat-c0eb-sub"});
    let bad = json!({"ANTHROPIC_API_KEY": "sk-test", "ANTHROPIC_CUSTOM_HEADERS": route,
        "SUBROUTER_SESSION_KEY": "two words\nX-Evil: 1", "SUBROUTER_SESSION_HEADER": "1"});
    let harnesses = json!({"claude": claude(turn), "bare": claude(bare), "sub": claude(sub), "bad": claude(bad)});
    let daemon_turn = [("SUBROUTER_SESSION_KEY", "daemon-turn"), ("SUBROUTER_SESSION_HEADER", "1")];
    for (harness, want) in [
        ("claude", json!("X-Subrouter-Agent: claude\nX-Subrouter-Session: optchat-c0eb-turn")),
        ("bare", json!("X-Subrouter-Session: optchat-c0eb-compact")),
        ("sub", json!(route)),
        ("bad", json!(route)),
    ] {
        // One daemon per case: `ask` names every session "auth".
        let d = start(&dir, harnesses.clone(), &daemon_turn).await;
        let (reply, _) = ask(&d, harness).await;
        assert_eq!(found(&reply)["customHeaders"], want, "{harness}: {reply:?}");
    }
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
        &format!("#!/bin/sh\nexec env FAKE_CLAUDE_VIA=mise-shim python3 '{FAKE_CLAUDE}' \"$@\"\n"),
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
    let count = "echo run >> \"$HOME/shell-runs\"\n";
    let dir = scratch(
        "cache",
        &format!(
            "{count}export ANTHROPIC_AUTH_TOKEN=s3cret-value\nexport NO_PROXY=plain-value\nexport TEAM_ROUTE_NAME=not-allow-listed\n"
        ),
    );
    let runs =
        || std::fs::read_to_string(dir.join("home/shell-runs")).unwrap_or_default().lines().count();
    let harnesses = json!({"claude": claude(json!({}))});
    {
        let d = start(&dir, harnesses.clone(), &[]).await;
        let (reply, _) = ask(&d, "claude").await;
        assert_eq!(found(&reply)["auth"], json!(["ANTHROPIC_AUTH_TOKEN"]));
    }
    assert_eq!(runs(), 1);
    let cache = dir.join("login-env.json");
    let text = std::fs::read_to_string(&cache).unwrap();
    assert!(!text.contains("s3cret-value"), "a secret value in the cache: {text}");
    let v: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(v["secretNames"], json!(["ANTHROPIC_AUTH_TOKEN"]), "{v}");
    assert_eq!(v["vars"]["NO_PROXY"], "plain-value", "{v}");
    assert!(v["vars"].get("TEAM_ROUTE_NAME").is_none(), "only allow-listed names are cached: {v}");
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(std::fs::metadata(&cache).unwrap().permissions().mode() & 0o777, 0o600);
    // The token leaves the rc file: the changed file runs the shell again.
    let rc = format!("{count}export NO_PROXY=plain-value\n");
    std::fs::write(dir.join("home/.zshrc"), &rc).unwrap();
    {
        let d = start(&dir, harnesses.clone(), &[]).await;
        let (reply, _) = ask(&d, "claude").await;
        assert!(reply.is_err(), "no token is left: {reply:?}");
    }
    assert_eq!(runs(), 2);
    // Same files, no secret in the cache: no shell at all.
    {
        let d = start(&dir, harnesses.clone(), &[]).await;
        let (reply, _) = ask(&d, "claude").await;
        assert!(reply.is_err(), "no token is left: {reply:?}");
    }
    assert_eq!(runs(), 2, "a matching cache with no secret runs no shell");
    // Only the fingerprint can see this edit (the cache needs no secret).
    std::fs::write(dir.join("home/.zshrc"), format!("{rc}# edited\n")).unwrap();
    {
        let d = start(&dir, harnesses.clone(), &[]).await;
        let _ = ask(&d, "claude").await;
    }
    assert_eq!(runs(), 3, "an edited rc file runs the shell again");
}

#[tokio::test]
async fn a_linked_login_environment_cache_is_never_trusted() {
    let dir = scratch("cache-link", "echo run >> \"$HOME/shell-runs\"\nexport NO_PROXY=plain\n");
    let config = json!({"harnesses": {}, "permissionPolicy": "deny-all"});
    // The readiness line comes before the login environment resolves (the
    // shell runs in `finish_startup`), and no agent spawn waits for it here:
    // wait for startup to finish before the daemon stops.
    {
        let d = start_config(&dir, config.clone(), &[]).await;
        startup_finished(&d).await;
    }
    let runs =
        || std::fs::read_to_string(dir.join("home/shell-runs")).unwrap_or_default().lines().count();
    assert_eq!(runs(), 1);
    let cache = dir.join("login-env.json");
    let planted = dir.join("planted-login-env.json");
    std::fs::copy(&cache, &planted).unwrap();
    let mut planted_cache: Value =
        serde_json::from_slice(&std::fs::read(&planted).unwrap()).unwrap();
    planted_cache["vars"]["NO_PROXY"] = "from-linked-cache".into();
    let planted_text = serde_json::to_string(&planted_cache).unwrap();
    std::fs::write(&planted, &planted_text).unwrap();
    std::fs::remove_file(&cache).unwrap();
    std::os::unix::fs::symlink(&planted, &cache).unwrap();
    {
        let d = start_config(&dir, config, &[]).await;
        startup_finished(&d).await;
    }
    assert_eq!(runs(), 2, "the daemon trusted a linked login cache");
    assert_eq!(std::fs::read_to_string(&planted).unwrap(), planted_text);
    assert!(!std::fs::symlink_metadata(&cache).unwrap().file_type().is_symlink());
    let _ = std::fs::remove_dir_all(&dir);
}

/// Wait until the daemon reports its startup complete (`_acpmux/status`
/// `ready`): a login shell it had to wait for has run by then.
async fn startup_finished(d: &Daemon) {
    let mut rpc = Rpc::connect(&d.socket).await;
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let status = rpc.call("_acpmux/status", json!({})).await;
        if status["ready"] == true {
            return;
        }
        assert!(Instant::now() < deadline, "the daemon never finished its startup: {status}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Wait up to `limit` for the daemon's login cache to hold `NO_PROXY=want`.
async fn cached_no_proxy(dir: &Path, want: &str, limit: Duration) -> bool {
    let deadline = Instant::now() + limit;
    loop {
        let found = std::fs::read_to_string(dir.join("login-env.json"))
            .ok()
            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
            .is_some_and(|v| v["vars"]["NO_PROXY"] == want);
        if found || Instant::now() >= deadline {
            return found;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// D26: an edited shell startup file refreshes the login environment on its
/// own (a file watcher), not at the next agent spawn. No agent runs here, and
/// the edit lands inside the 10 s spawn recheck window, so only the watcher
/// can read it again.
#[tokio::test]
async fn an_edited_rc_file_refreshes_the_login_env_without_a_spawn() {
    let dir = scratch("watch", "export NO_PROXY=before-edit\n");
    let config = json!({"harnesses": {}, "permissionPolicy": "approve-all"});
    let _d = start_config(&dir, config, &[]).await;
    assert!(cached_no_proxy(&dir, "before-edit", Duration::from_secs(8)).await, "the first read");
    std::fs::write(dir.join("home/.zshrc"), "export NO_PROXY=after-the-edit\n").unwrap();
    assert!(
        cached_no_proxy(&dir, "after-the-edit", Duration::from_secs(6)).await,
        "the edited ~/.zshrc was not read again"
    );
}

/// An edit that lands while the login shell is still reading the previous
/// edit is read too: the login env ends at the last edit, never one behind.
/// Edit A marks when the shell starts reading it, then takes about 1.5 s;
/// edit B lands right after the mark, so A's read is running. The shell
/// lives in a quiet folder: the daemon's log in the scratch folder would
/// keep the watcher's burst open past A's read.
#[tokio::test]
async fn an_edited_rc_file_during_a_read_is_read_again() {
    let dir = scratch("race", "export NO_PROXY=before-edit\n");
    std::fs::create_dir_all(dir.join("sh")).unwrap();
    std::fs::copy(dir.join("loginsh"), dir.join("sh/loginsh")).unwrap();
    let shell = dir.join("sh/loginsh");
    let config = json!({"harnesses": {}, "permissionPolicy": "approve-all"});
    let _d = start_config(&dir, config, &[("SHELL", shell.to_str().unwrap())]).await;
    assert!(cached_no_proxy(&dir, "before-edit", Duration::from_secs(8)).await, "the first read");
    // The mark is in no watched folder.
    let mark = dir.join("reading-a");
    std::fs::write(
        dir.join("home/.zshrc"),
        "touch \"$HOME/../reading-a\"\nsleep 1.5\nexport NO_PROXY=edit-a\n",
    )
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(8);
    while !mark.exists() && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(mark.exists(), "edit A was never read");
    std::fs::write(dir.join("home/.zshrc"), "export NO_PROXY=edit-b-last\n").unwrap();
    assert!(
        cached_no_proxy(&dir, "edit-b-last", Duration::from_secs(10)).await,
        "the edit made during a read was dropped"
    );
}

/// `~/.zshrc -> dotfiles/zshrc`: an edit to the link's target refreshes the
/// login env (the watcher watches the target's folder too).
#[tokio::test]
async fn an_edited_rc_file_behind_a_symlink_refreshes_the_login_env() {
    let dir = scratch("link", "");
    std::fs::create_dir_all(dir.join("dotfiles")).unwrap();
    let target = dir.join("dotfiles/zshrc");
    std::fs::write(&target, "export NO_PROXY=before-edit\n").unwrap();
    std::fs::remove_file(dir.join("home/.zshrc")).unwrap();
    std::os::unix::fs::symlink(&target, dir.join("home/.zshrc")).unwrap();
    let config = json!({"harnesses": {}, "permissionPolicy": "approve-all"});
    let _d = start_config(&dir, config, &[]).await;
    assert!(cached_no_proxy(&dir, "before-edit", Duration::from_secs(8)).await, "the first read");
    std::fs::write(&target, "export NO_PROXY=after-the-edit\n").unwrap();
    assert!(
        cached_no_proxy(&dir, "after-the-edit", Duration::from_secs(6)).await,
        "the edited symlink target was not read again"
    );
}

/// A startup file the login shell rewrites on every read (a tool that
/// appends to ~/.zshrc) never settles; the daemon stops reading it again
/// instead of running login shells back to back.
#[tokio::test]
async fn an_rc_file_the_shell_rewrites_stops_being_read_again() {
    let dir = scratch(
        "rewrite",
        "echo run >> \"$HOME/../runs\"\necho '#' >> \"$HOME/.zshrc\"\nexport NO_PROXY=self-rewriting\n",
    );
    let config = json!({"harnesses": {}, "permissionPolicy": "approve-all"});
    let _d = start_config(&dir, config, &[]).await;
    assert!(
        cached_no_proxy(&dir, "self-rewriting", Duration::from_secs(8)).await,
        "the first read"
    );
    let runs = || std::fs::read_to_string(dir.join("runs")).map(|s| s.lines().count()).unwrap_or(0);
    // The watcher's burst (300 ms quiet, 2 s at most) and any re-read end well
    // within this; after it the shell runs no more.
    tokio::time::sleep(Duration::from_secs(4)).await;
    let settled = runs();
    tokio::time::sleep(Duration::from_secs(3)).await;
    assert_eq!(
        runs(),
        settled,
        "the daemon kept running the login shell ({settled} runs, then more)"
    );
}

/// The first health answer counts a Claude sign-in the login shell exports
/// (hq#2569 #2), even when it is asked before the shell has answered: the
/// health call waits for the daemon's startup, as its own check does,
/// instead of reading an environment without the login shell. (A slow
/// shell, 1.5 s here, is the case of a loaded machine or a heavy ~/.zshrc.)
#[tokio::test]
async fn the_first_health_answer_counts_a_sign_in_from_a_slow_login_shell() {
    let dir = scratch("hl", "sleep 1.5\nexport ANTHROPIC_API_KEY=from-login-shell\n");
    // A Claude CLI by path (no PATH harness finds it).
    std::fs::create_dir_all(dir.join("bin")).unwrap();
    write_executable(
        &dir.join("bin/claude"),
        "#!/bin/sh\n[ \"$1\" = --version ] && echo '2.1.0 (Claude Code)'\nexit 0\n",
    );
    let config = json!({"harnesses": {"cl": {"argv": [dir.join("bin/claude")]}},
        "defaultHarness": "cl", "permissionPolicy": "approve-all"});
    let d = start_config(&dir, config, &[]).await;
    let mut rpc = Rpc::connect(&d.socket).await;
    let health = rpc.call("_acpmux/harness/health", json!({})).await;
    let row = health["harnesses"]
        .as_array()
        .and_then(|rows| rows.iter().find(|row| row["id"] == "cl"))
        .unwrap_or_else(|| panic!("no cl row: {health}"))
        .clone();
    assert_eq!(row["auth"], "signedIn", "{health}");
    assert_eq!(row["authDetail"], "an API key (ANTHROPIC_API_KEY)", "{health}");
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

/// Only the allow-list leaves the login shell: a Claude agent gets the
/// login ANTHROPIC_AUTH_TOKEN but not GITHUB_TOKEN, GH_TOKEN or NPM_TOKEN;
/// a name the person adds to `loginEnvAllow` (NPM_TOKEN here) does reach it.
#[tokio::test]
async fn only_allow_listed_login_variables_reach_the_agent() {
    let dir = scratch(
        "allow",
        "export ANTHROPIC_AUTH_TOKEN=ignored-by-router\nexport GITHUB_TOKEN=ghp-login\nexport GH_TOKEN=gh-login\nexport NPM_TOKEN=npm-login\n",
    );
    let harnesses = json!({"claude": claude(json!({}))});
    {
        let d = start(&dir, harnesses.clone(), &[]).await;
        let (reply, _) = ask(&d, "claude").await;
        let v = found(&reply);
        assert_eq!(v["auth"], json!(["ANTHROPIC_AUTH_TOKEN"]), "{v}");
        assert_eq!(v["loginOnly"], json!([]), "{v}");
    }
    let config = json!({"harnesses": harnesses, "defaultHarness": "claude",
        "permissionPolicy": "approve-all", "loginEnvAllow": ["NPM_TOKEN"]});
    let d = start_config(&dir, config, &[]).await;
    let (reply, _) = ask(&d, "claude").await;
    assert_eq!(found(&reply)["loginOnly"], json!(["NPM_TOKEN"]));
}

/// A version-manager prefix passes, but never a secret under it: the agent
/// gets MISE_DATA_DIR, not MISE_GITHUB_TOKEN or NVM_AUTH_HEADER, unless
/// `loginEnvAllow` names one exactly.
#[tokio::test]
async fn a_secret_under_a_tool_prefix_stays_in_the_daemon() {
    let dir = scratch(
        "mise-secret",
        "export ANTHROPIC_API_KEY=sk-login\nexport MISE_DATA_DIR=\"$HOME/mise\"\nexport MISE_GITHUB_TOKEN=ghp_login\nexport NVM_AUTH_HEADER='Bearer login'\n",
    );
    let harnesses = json!({"claude": claude(json!({}))});
    {
        let d = start(&dir, harnesses.clone(), &[]).await;
        let (reply, _) = ask(&d, "claude").await;
        let v = found(&reply);
        assert_eq!(v["loginOnly"], json!([]), "{v}");
        assert_eq!(v["miseDataDir"], dir.join("home/mise").to_string_lossy().as_ref(), "{v}");
    }
    let config = json!({"harnesses": harnesses, "defaultHarness": "claude",
        "permissionPolicy": "approve-all", "loginEnvAllow": ["MISE_GITHUB_TOKEN"]});
    let d = start_config(&dir, config, &[]).await;
    let (reply, _) = ask(&d, "claude").await;
    assert_eq!(found(&reply)["loginOnly"], json!(["MISE_GITHUB_TOKEN"]));
}

/// The login shell starts from the person's identity only: a proxy in the
/// starting daemon's own environment (a sandboxed starter) never enters
/// the cache, so another daemon's agents never get it.
#[tokio::test]
async fn a_daemon_env_proxy_never_becomes_the_login_env() {
    let dir = scratch("proxy", "export ANTHROPIC_API_KEY=sk-login\n");
    let harnesses = json!({"claude": claude(json!({}))});
    {
        let d = start(&dir, harnesses.clone(), &[("HTTPS_PROXY", "http://127.0.0.1:9")]).await;
        let (reply, _) = ask(&d, "claude").await;
        found(&reply);
    }
    let cache = std::fs::read_to_string(dir.join("login-env.json")).unwrap();
    assert!(!cache.contains("127.0.0.1:9"), "the starter's proxy is in the cache: {cache}");
    let d = start(&dir, harnesses, &[]).await;
    let (reply, _) = ask(&d, "claude").await;
    assert_eq!(found(&reply)["proxy"], Value::Null);
}

/// (d2) Vertex switched on in the login shell: the agent keeps its region
/// names (CLOUD_ML_REGION, VERTEX_REGION_*); a Claude agent without Vertex
/// does not get them.
#[tokio::test]
async fn vertex_from_the_login_shell_keeps_its_regions() {
    let regions =
        "export CLOUD_ML_REGION=us-east5\nexport VERTEX_REGION_CLAUDE_OPUS=europe-west1\n";
    let dir = scratch("vertex", &format!("export CLAUDE_CODE_USE_VERTEX=1\n{regions}"));
    let d = start(&dir, json!({"claude": claude(json!({}))}), &[]).await;
    let (reply, _) = ask(&d, "claude").await;
    let v = found(&reply);
    assert_eq!(v["auth"], json!(["vertex"]), "{v}");
    assert_eq!(v["cloudMlRegion"], "us-east5", "{v}");
    assert_eq!(v["vertexRegions"], json!(["VERTEX_REGION_CLAUDE_OPUS"]), "{v}");
    drop(d);
    let dir = scratch("novertex", &format!("export ANTHROPIC_API_KEY=sk-login\n{regions}"));
    let d = start(&dir, json!({"claude": claude(json!({}))}), &[]).await;
    let (reply, _) = ask(&d, "claude").await;
    let v = found(&reply);
    assert_eq!(v["cloudMlRegion"], Value::Null, "{v}");
    assert_eq!(v["vertexRegions"], json!([]), "{v}");
}

/// A profile's own Bedrock switch (any local client can add a profile)
/// unlocks only the non-secret AWS names; the AWS keys need the person's
/// own switch in the login shell or the daemon's environment.
#[tokio::test]
async fn a_profile_bedrock_switch_gets_no_aws_secret() {
    let dir = scratch(
        "awsprof",
        "export AWS_PROFILE=work\nexport AWS_REGION=us-west-2\nexport AWS_ACCESS_KEY_ID=AKIALOGIN\nexport AWS_SECRET_ACCESS_KEY=login-secret\nexport AWS_SESSION_TOKEN=login-session\n",
    );
    let harnesses = json!({"claude": claude(json!({"CLAUDE_CODE_USE_BEDROCK": "1"}))});
    let d = start(&dir, harnesses, &[]).await;
    let (reply, _) = ask(&d, "claude").await;
    let v = found(&reply);
    assert_eq!(v["auth"], json!(["bedrock"]), "{v}");
    assert_eq!(v["awsKeys"], json!(["AWS_PROFILE", "AWS_REGION"]), "{v}");
}
