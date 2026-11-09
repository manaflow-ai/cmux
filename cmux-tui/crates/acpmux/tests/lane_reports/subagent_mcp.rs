//! A Claude Code subagent that reaches acpmux through MCP tools (`mcp__acpmux__*`, or cmux's
//! `acpmux_*` and `cmux_exec` in front of them), not through Bash (W5-M follow-up, 2026-11-08).
//! The incident's subagent started `acpmux run` and `acpmux send --wait` with
//! `cmux.acpmux_bg_start` in a `cmux_exec` script: no Bash call, so no hook mark, and every
//! report went to its lead. Claude Code names each tool call by its tool use id, in the hook's
//! input (with the subagent's `agent_id`) and in the MCP request's
//! `_meta["claudecode/toolUseId"]`, so acpmux's PreToolUse hook records which subagent made the
//! call and acpmux's MCP server reads it there:
//!
//! - `send` names that subagent as its sender, so its no-wait report reaches the subagent, after
//!   its next tool call (the PostToolUse hook of that MCP call too), not the lead.
//! - `bg_start` runs its command as the subagent's Bash would (`ACPMUX_CALLER_SUBAGENT`), so the
//!   `acpmux run` / `send` it starts carries the subagent too.
//! - The lead's own call (no `agent_id`) and a call whose record its PostToolUse removed name
//!   no subagent.
use super::*;
use std::io::{BufRead, Write};

const SUB: &str = "a0a68e7af3df5967e";
const MARK: &str = "general-purpose:a0a68e7af3df5967e";
const WAIT: Duration = Duration::from_secs(20);

/// The hook's answer to `input` in session `session` (`acpmux __bg-hook HOME`).
fn hook(session: &str, input: Value) -> Option<Value> {
    let scratch = std::env::temp_dir().join(format!("w5m-mcp-hook-{}", std::process::id()));
    std::fs::create_dir_all(&scratch).unwrap();
    let mut child = daemon_env::acpmux(&scratch)
        .arg("__bg-hook")
        .arg(acpmux::config::home())
        .env("ACPMUX_SESSION_ID", session)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input.to_string().as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success(), "{out:?}");
    let text = String::from_utf8(out.stdout).unwrap();
    let text = text.trim();
    (!text.is_empty()).then(|| serde_json::from_str(text).unwrap())
}

/// The hook input of tool call `tool_use_id` of `tool`: the subagent's, or the lead's own when
/// `subagent` is false.
fn call_input(event: &str, tool: &str, tool_use_id: &str, subagent: bool) -> Value {
    let mut input = json!({"hook_event_name": event, "tool_name": tool,
        "tool_use_id": tool_use_id, "cwd": std::env::temp_dir(), "tool_input": {}});
    if subagent {
        input["agent_id"] = json!(SUB);
        input["agent_type"] = json!("general-purpose");
    }
    input
}

/// The in-process daemon on a socket of its own, as an agent's MCP server reaches it.
async fn socket(hub: &Arc<Hub>, name: &str) -> std::path::PathBuf {
    let path =
        std::env::temp_dir().join(format!("w5m-{name}-{}.sock", std::process::id() % 100_000));
    let _ = std::fs::remove_file(&path);
    let listener = acpmux::server::bind_unix(&path).await.unwrap();
    tokio::spawn(acpmux::server::serve_unix(hub.clone(), listener));
    path
}

/// One `tools/call` of `name` to a fresh `acpmux acpmux-mcp` of chat `session`, run as its
/// harness runs it (its caller token, this daemon's socket), with `meta` as Claude Code's
/// `_meta`; the call's result.
async fn mcp(sock: &Path, session: &str, name: &str, arguments: Value, meta: Value) -> Value {
    let scratch = std::env::temp_dir().join(format!("w5m-mcp-{}", std::process::id()));
    std::fs::create_dir_all(&scratch).unwrap();
    let mut command = daemon_env::acpmux(&scratch);
    command
        .arg("acpmux-mcp")
        .env("ACPMUX_HOME", acpmux::config::home())
        .env("ACPMUX_SOCKET", sock)
        .env("ACPMUX_SESSION_ID", session)
        .env(acpmux::hub::person::CALLER_TOKEN_ENV, acpmux::hub::person::caller_token(session))
        .env(acpmux::hub::person::CALLER_SOCKET_ENV, sock)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped());
    let requests = [
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion":
            "2025-06-18", "capabilities": {}, "clientInfo": {"name": "claude-code", "version": "2"}}}),
        json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
        json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
               "params": {"name": name, "arguments": arguments, "_meta": meta}}),
    ];
    tokio::task::spawn_blocking(move || {
        let mut child = command.spawn().unwrap();
        let mut stdin = child.stdin.take().unwrap();
        for request in requests {
            writeln!(stdin, "{request}").unwrap();
        }
        let mut lines = std::io::BufReader::new(child.stdout.take().unwrap()).lines();
        let result = loop {
            let line = lines.next().expect("an MCP reply").unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v["id"] == 2 {
                break v["result"].clone();
            }
        };
        drop(stdin);
        let _ = child.kill();
        let _ = child.wait();
        result
    })
    .await
    .unwrap()
}

/// What a file a background task writes holds once it is there.
async fn written(path: &Path) -> String {
    tokio::time::timeout(WAIT, async {
        loop {
            if let Ok(text) = std::fs::read_to_string(path)
                && text.ends_with('\n')
            {
                return text;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .expect("the background task wrote its file")
}

#[tokio::test]
async fn lane_report_subagent_mcp_send_reports_to_the_subagent_that_called_it() {
    let hub = hub();
    let sock = socket(&hub, "send").await;
    let mut person = Client::new(&hub);
    let gate = super::subagents::fifo("mcp-send");
    let parent = super::subagents::parent_with_a_running_subagent(&hub, &mut person, &gate).await;
    let lane = Client::as_session(&hub, &parent).await.new_session("mcp-lane", json!({})).await;
    let tool = "mcp__cmux__cmux_exec";
    assert_eq!(hook(&parent, call_input("PreToolUse", tool, "toolu_01send", true)), None);
    let sent = mcp(
        &sock,
        &parent,
        "send",
        json!({"to": "mcp-lane", "text": "mcp finding"}),
        json!({"claudecode/toolUseId": "toolu_01send", "progressToken": 2}),
    )
    .await;
    assert_eq!(sent["isError"], false, "{sent}");
    super::subagents::turn_ended(&hub, &lane, 1).await;
    // The lane reads the subagent as its sender.
    let page = person.ok("_acpmux/events", json!({"sessionId": lane, "limit": 5000})).await;
    let prompts: String = page["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["dir"] == "out" && e["kind"] == "session/prompt")
        .map(|e| e["msg"]["params"]["prompt"].to_string())
        .collect();
    assert!(prompts.contains("parent's general-purpose subagent a0a68e7a"), "{prompts}");
    // Its report reaches the subagent as that MCP call ends, and the lead gets none.
    let deadline = Instant::now() + WAIT;
    let handed = loop {
        if let Some(out) = hook(&parent, call_input("PostToolUse", tool, "toolu_01send", true)) {
            break out;
        }
        assert!(Instant::now() < deadline, "no notice for the subagent");
        tokio::time::sleep(Duration::from_millis(100)).await;
    };
    let context = handed["hookSpecificOutput"]["additionalContext"].as_str().unwrap();
    assert!(context.contains("[mcp-lane]") && context.contains("echo: mcp finding"), "{context}");
    assert!(super::subagents::queued_reports(&mut person, &parent).await.is_empty());
    std::fs::write(&gate, "go").unwrap();
}

#[tokio::test]
async fn lane_report_subagent_mcp_bg_start_runs_as_the_subagent_that_called_it() {
    let hub = hub();
    hub.set_bg_runner(daemon_env::bg_runner(), acpmux::bg_run::SEGMENT);
    let sock = socket(&hub, "bg").await;
    let mut person = Client::new(&hub);
    let parent = person.new_session("parent", json!({})).await;
    let dir = std::env::temp_dir().join(format!("w5m-mcp-bg-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let start = |file: &str| {
        json!({"command": format!("printenv ACPMUX_CALLER_SUBAGENT > {file}; echo >> {file}"),
               "cwd": dir, "notify": false})
    };
    let meta = |id: &str| json!({"claudecode/toolUseId": id});
    let tool = "mcp__acpmux__bg_start";
    assert_eq!(hook(&parent, call_input("PreToolUse", tool, "toolu_01bg", true)), None);
    let r = mcp(&sock, &parent, "bg_start", start("sub.txt"), meta("toolu_01bg")).await;
    assert_eq!(r["isError"], false, "{r}");
    assert_eq!(written(&dir.join("sub.txt")).await.trim(), MARK);
    // The lead's own call names none.
    assert_eq!(hook(&parent, call_input("PreToolUse", tool, "toolu_01lead", false)), None);
    let r = mcp(&sock, &parent, "bg_start", start("lead.txt"), meta("toolu_01lead")).await;
    assert_eq!(r["isError"], false, "{r}");
    assert_eq!(written(&dir.join("lead.txt")).await.trim(), "");
    // Once the subagent's call ended, its id names nobody: no later call takes the subagent's name.
    hook(&parent, call_input("PostToolUse", tool, "toolu_01bg", true));
    let r = mcp(&sock, &parent, "bg_start", start("after.txt"), meta("toolu_01bg")).await;
    assert_eq!(r["isError"], false, "{r}");
    assert_eq!(written(&dir.join("after.txt")).await.trim(), "");
}
