//! The Chief's acpmux presets are built in (P0 after cx-1l61): a Chief
//! started outside the cmux app (the always-on brain, `cmux chief -p`)
//! installs them without the person key, because the client names a built-in
//! preset and sends no env. acpmux fills the env itself: fixed flags, cache
//! keys from the name, codex paths from its own Chief home and bundle, and a
//! subagent's cmux sockets and PATH from its own process environment. Any env
//! a client sends is still the person's to set. The real daemon binary, over
//! its unix socket.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

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

    /// The agent text session `session` streams for `text`.
    async fn prompt_text(&mut self, session: &str, text: &str) -> String {
        self.next += 1;
        let id = self.next;
        let params = json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]});
        let line =
            json!({"jsonrpc": "2.0", "id": id, "method": "session/prompt", "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        let mut got = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.lines.next_line())
                .await
                .expect("daemon answered in time")
                .unwrap()
                .expect("daemon closed the socket");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{text}: {v}");
                return got;
            }
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                got.push_str(t);
            }
        }
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
        Self::start_with(tag, &[])
    }

    /// [`Daemon::start`] with `extra` in the daemon's own environment, set
    /// relative to its directory (the starter's leftovers).
    fn start_with(tag: &str, extra: &[(&str, &str)]) -> Self {
        Self::start_env(tag, extra, &[])
    }

    /// [`Daemon::start_with`], and `plain` in the daemon's own environment as given.
    fn start_env(tag: &str, extra: &[(&str, &str)], plain: &[(&str, &str)]) -> Self {
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
        // Stand-in agents (fclaude, fcodex) only; PATH stays the bare GUI one below.
        let mut child = daemon_env::command(&dir, daemon_env::Agents::StandIn, &[])
            .args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"])
            .env("ACPMUX_HOME", &dir)
            .env("ACPMUX_SOCKET", &socket)
            .env("ACPMUX_CHIEF_MUX_HOME", dir.join("mux"))
            .env("CMUX_TUI_SOCKET", "/tmp/brain-daemon.sock")
            .env("CMUX_MUX_SOCKET", "/tmp/brain-daemon.sock")
            .env("CMUX_CHIEF_OWNER_SOCKET", "/tmp/brain-owner.sock")
            .env("PATH", "/usr/bin:/bin")
            .env("ACPMUX_LOGIN_ENV", "0")
            .envs(extra.iter().map(|(k, v)| (*k, dir.join(v))))
            .envs(plain.iter().copied())
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
    // The default Chief: the id of the daemon's own Chief home.
    let id = home_id(&d.dir.join("mux"));
    // A plain socket client: the brain's Chief host, not the person.
    let mut chief = Rpc::connect(&d.socket).await;
    let compact = &format!("optchat-compact-{id}-slot-3");
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
            "SUBROUTER_SESSION_HEADER": "1",
            "SUBROUTER_SESSION_KEY": format!("optchat-{id}-compact"),
        })
    );
    // A later change of another field keeps the built-in env.
    let r = chief
        .call("_acpmux/presets", json!({"name": compact, "set": {"description": "node 7"}}))
        .await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(
        stored_env(&mut chief, compact).await["SUBROUTER_SESSION_KEY"],
        format!("optchat-{id}-compact")
    );

    // Codex: the paths come from the daemon's own Chief home, never the client.
    let turn = &format!("optchat-chief-codex-{id}");
    let r =
        chief.call("_acpmux/presets", json!({"name": turn, "set": {"harness": "fcodex"}})).await;
    assert!(r.get("error").is_none(), "{r}");
    let env = stored_env(&mut chief, turn).await;
    let mux = d.dir.join("mux");
    assert_eq!(env["CODEX_HOME"], mux.join("optchat/turn-codex").display().to_string(), "{env}");
    assert_eq!(env["CODEX_PROMPT_CACHE_KEY"], format!("optchat-{id}-turn"), "{env}");
    let slot = &format!("optchat-compact-{id}-slot-0");
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
    let sub = &format!("optchat-sub-{id}");
    let r =
        chief.call("_acpmux/presets", json!({"name": sub, "set": {"harness": "fclaude"}})).await;
    assert!(r.get("error").is_none(), "{r}");
    let env = stored_env(&mut chief, sub).await;
    assert_eq!(env["CMUX_TUI_SOCKET"], "/tmp/brain-daemon.sock", "{env}");
    assert_eq!(env["CMUX_MUX_SOCKET"], "/tmp/brain-daemon.sock", "{env}");
    assert_eq!(env["CMUX_CHIEF_OWNER_SOCKET"], "/tmp/brain-owner.sock", "{env}");
    assert_eq!(env["OPTCHAT_SUBAGENT"], "1", "{env}");
    // The daemon's own directory first: compared resolved, since its
    // `current_exe` resolves a symlinked target directory on Linux (the
    // Testbox's warm target disk) and keeps it on macOS.
    let path = env["PATH"].as_str().unwrap();
    let (first, rest) = path.split_once(':').unwrap();
    let exe = std::fs::canonicalize(daemon_env::bin()).unwrap();
    assert_eq!(std::fs::canonicalize(first).unwrap(), exe.parent().unwrap(), "{env}");
    assert_eq!(rest, "/usr/bin:/bin", "{env}");
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

/// optchat-chief `paths::home_id`: FNV-1a (32 bit) of the path's bytes.
fn home_id(home: &Path) -> String {
    let mut hash: u32 = 0x811c_9dc5;
    for b in home.as_os_str().as_encoded_bytes() {
        hash ^= u32::from(*b);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    format!("{hash:08x}")
}

/// One acpmux per Chief home (hq-6d 2026-10-14): the Chiefs the daemon's
/// supervisor starts live in `<Chief home>/c/<id tail>` and share the Chief
/// home's acpmux. A built-in codex preset of such a Chief gets that Chief's
/// own codex homes, never the default Chief's (two Chiefs never share a
/// codex history); the default Chief's id keeps the Chief home.
#[tokio::test]
async fn each_chief_of_the_chief_home_gets_its_own_codex_homes() {
    let d = Daemon::start("shared");
    let mux = d.dir.join("mux");
    let scout = mux.join("c").join("aaaa1111");
    std::fs::create_dir_all(&scout).unwrap();
    let mut chief = Rpc::connect(&d.socket).await;
    for (home, root) in [(&scout, &scout), (&mux, &mux)] {
        let id = home_id(home);
        let turn = format!("optchat-chief-codex-{id}");
        let r = chief
            .call("_acpmux/presets", json!({"name": turn, "set": {"harness": "fcodex"}}))
            .await;
        assert!(r.get("error").is_none(), "{r}");
        let env = stored_env(&mut chief, &turn).await;
        assert_eq!(
            env["CODEX_HOME"],
            root.join("optchat/turn-codex").display().to_string(),
            "{turn}: {env}"
        );
        // Its turns and subagents act as that Chief, whoever started the daemon.
        assert_eq!(env["MUX_HOME"], home.display().to_string(), "{turn}: {env}");
        let sub = format!("optchat-sub-{id}");
        let r = chief
            .call("_acpmux/presets", json!({"name": sub, "set": {"harness": "fclaude"}}))
            .await;
        assert!(r.get("error").is_none(), "{r}");
        assert_eq!(
            stored_env(&mut chief, &sub).await["MUX_HOME"],
            home.display().to_string(),
            "{sub}"
        );
        let slot = format!("optchat-compact-{id}-slot-1");
        let r = chief
            .call("_acpmux/presets", json!({"name": slot, "set": {"harness": "fcodex"}}))
            .await;
        assert!(r.get("error").is_none(), "{r}");
        let env = stored_env(&mut chief, &slot).await;
        assert_eq!(
            env["CODEX_HOME"],
            root.join("optchat/compactor-codex/slot-1").display().to_string(),
            "{slot}: {env}"
        );
    }
}

/// The Chief credential of whoever started the Chief home's acpmux (the
/// default Chief's host starts it with its own `MUX_AGENT_TOKEN_FILE` and
/// participant) reaches no session: another Chief's turn or subagent, and the
/// person's own chat, cannot bind as the default Chief (`agent_mux`). Each
/// Chief's sessions get only their own Chief's home.
#[tokio::test]
async fn no_session_gets_the_credential_of_the_chief_that_started_the_daemon() {
    let d = Daemon::start_with(
        "cred",
        &[("MUX_AGENT_TOKEN_FILE", "mux/agent-token"), ("OPTCHAT_CHIEF_PARTICIPANT", "agent_mux")],
    );
    let scout = d.dir.join("mux").join("c").join("bbbb2222");
    std::fs::create_dir_all(&scout).unwrap();
    let id = home_id(&scout);
    let mut chief = Rpc::connect(&d.socket).await;
    for preset in [Some(format!("optchat-chief-{id}")), Some(format!("optchat-sub-{id}")), None] {
        let mut params = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
        if let Some(name) = &preset {
            let r = chief
                .call("_acpmux/presets", json!({"name": name, "set": {"harness": "fclaude"}}))
                .await;
            assert!(r.get("error").is_none(), "{r}");
            params["_meta"] = json!({"acpmux": {"preset": name}});
        }
        let r = chief.call("session/new", params).await;
        assert!(r.get("error").is_none(), "{preset:?}: {r}");
        let session = r["result"]["sessionId"].as_str().unwrap().to_owned();
        for key in ["MUX_AGENT_TOKEN_FILE", "OPTCHAT_CHIEF_PARTICIPANT"] {
            assert_eq!(
                chief.prompt_text(&session, &format!("env: {key}")).await,
                format!("{key}="),
                "{preset:?}: the session got the starting Chief's {key}"
            );
        }
        if preset.is_some() {
            assert_eq!(
                chief.prompt_text(&session, "env: MUX_HOME").await,
                format!("MUX_HOME={}", scout.display()),
                "{preset:?}: the session acts as its own Chief"
            );
        }
    }
}

/// A built-in preset whose home id names no Chief of the daemon's Chief
/// home (neither the Chief home nor one of its `c/<id>` Chiefs) is refused,
/// for every role and family: it never falls back to the default Chief's
/// homes (hq-6d 2026-10-14, fail closed).
#[tokio::test]
async fn a_built_in_preset_of_an_unknown_chief_is_refused() {
    let d = Daemon::start("unknown");
    std::fs::create_dir_all(d.dir.join("mux").join("c").join("aaaa1111")).unwrap();
    let mut chief = Rpc::connect(&d.socket).await;
    for (name, harness) in [
        ("optchat-chief-0badc0de", "fclaude"),
        ("optchat-chief-codex-0badc0de", "fcodex"),
        ("optchat-compact-0badc0de-slot-1", "fclaude"),
        ("optchat-compact-0badc0de-slot-2", "fcodex"),
        ("optchat-sub-0badc0de", "fclaude"),
        ("optchat-sub-0badc0de-codex", "fcodex"),
    ] {
        let r =
            chief.call("_acpmux/presets", json!({"name": name, "set": {"harness": harness}})).await;
        let message = r["error"]["message"].as_str().unwrap_or_default();
        assert!(message.contains("0badc0de is not a Chief"), "{name}: {r}");
        let r = chief.call("_acpmux/presets", json!({"name": name})).await;
        assert!(r.get("error").is_some(), "{name} was stored: {r}");
    }
}

/// A Chief turn gets only the cmux MCP server of the agent tools (cx-4a5w2):
/// the computer use, secret and session offer servers stay out of its
/// session. In the app (whose bundle has `cmux-cua`) their tool names and
/// instructions came after the turn's cache mark, 2,905 uncached tokens per
/// turn and about 70% read from the cache; a turn reaches that work through
/// subagents, which keep every server.
#[tokio::test]
async fn a_chief_turn_gets_only_the_cmux_mcp_server() {
    let d = Daemon::start_env(
        "tools",
        &[("CMUX_AGENT_TOOLS_BIN_DIR", "tools")],
        &[("ACPMUX_SECRET_TOOLS", "1"), ("ACPMUX_OFFER_TOOLS", "1")],
    );
    let tools = d.dir.join("tools");
    std::fs::create_dir_all(&tools).unwrap();
    for name in ["cmux", "cmux-cua"] {
        use std::os::unix::fs::PermissionsExt;
        let path = tools.join(name);
        std::fs::write(&path, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let id = home_id(&d.dir.join("mux"));
    let mut chief = Rpc::connect(&d.socket).await;
    let servers = |text: String| -> Vec<String> {
        // The servers, then (with a "+") those the cmux server runs behind
        // its code mode (CMUX_MCP_UPSTREAMS).
        let list: Value = serde_json::from_str(&text).unwrap();
        let list = list.as_array().unwrap_or_else(|| panic!("mcpServers is a list: {text}"));
        let mut names: Vec<String> =
            list.iter().filter_map(|s| s["name"].as_str().map(str::to_owned)).collect();
        for server in list {
            let env = server["env"].as_array().cloned().unwrap_or_default();
            let Some(upstreams) = env.iter().find(|e| e["name"] == "CMUX_MCP_UPSTREAMS") else {
                continue;
            };
            let upstreams: Value =
                serde_json::from_str(upstreams["value"].as_str().unwrap()).unwrap();
            for upstream in upstreams.as_array().unwrap() {
                names.push(format!("+{}", upstream["name"].as_str().unwrap()));
            }
        }
        names
    };
    for (preset, want) in [
        (Some(format!("optchat-chief-{id}")), vec!["cmux"]),
        (Some(format!("optchat-chief-codex-{id}")), vec!["cmux"]),
        (
            Some(format!("optchat-sub-{id}")),
            vec![
                "cmux",
                "+cmux-cua",
                "+cmux-secrets",
                "+cmux-sessions",
                "+cmux-subsessions",
                "+cmux-forum",
                "+acpmux",
            ],
        ),
        (
            None,
            vec![
                "cmux",
                "+cmux-cua",
                "+cmux-secrets",
                "+cmux-sessions",
                "+cmux-subsessions",
                "+cmux-forum",
                "+acpmux",
            ],
        ),
    ] {
        let mut params = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
        if let Some(name) = &preset {
            let harness = if name.contains("-codex-") { "fcodex" } else { "fclaude" };
            let r = chief
                .call("_acpmux/presets", json!({"name": name, "set": {"harness": harness}}))
                .await;
            assert!(r.get("error").is_none(), "{r}");
            params["_meta"] = json!({"acpmux": {"preset": name}});
        }
        let r = chief.call("session/new", params).await;
        assert!(r.get("error").is_none(), "{preset:?}: {r}");
        let session = r["result"]["sessionId"].as_str().unwrap().to_owned();
        let text = chief.prompt_text(&session, "mcp").await;
        assert_eq!(servers(text.clone()), want, "{preset:?}");
        // A Chief turn's cmux server gets the Chief's tool list (it lists
        // only those and refuses `cmux_exec`); a subagent or plain session
        // gets code mode.
        let list: Value = serde_json::from_str(&text).unwrap();
        let cmux = list.as_array().unwrap().iter().find(|s| s["name"] == "cmux").unwrap();
        let scoped = cmux["env"].to_string().contains("agents_wait,render");
        let turn = preset.as_deref().is_some_and(|name| name.starts_with("optchat-chief-"));
        assert_eq!(scoped, turn, "{preset:?}: {cmux}");
    }
}
