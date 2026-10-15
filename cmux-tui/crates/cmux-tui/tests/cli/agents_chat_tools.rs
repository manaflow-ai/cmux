//! `cmux agents chat send|read` and the `agents_chat_send` and
//! `agents_chat_read` MCP tools (cx-ncc.96): one agent prompts another chat
//! and reads its reply.
//!
//! Each test runs a real daemon and its acpmux with the test agent. Chats
//! start the way the app starts them, with `CMUX_WORKSPACE_ID` naming a
//! workspace of the daemon (`_meta.acpmux.env`), and the caller is a chat's
//! agent (`CMUX_AGENT_SESSION`, as acpmux gives its `cmux mcp serve`).

use std::os::unix::net::UnixStream;

use serde_json::{Value, json};

use super::*;

/// A machine whose acpmux runs the test agent, its work folder trusted.
fn machine(name: &str) -> Daemon {
    let config = json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE_AGENT], "family": "fake"}},
        "defaultHarness": "fake",
    });
    let daemon = Daemon::start_with(name, None, Some(config));
    let work = fs::canonicalize(daemon.dir.join("work")).unwrap();
    let trust = json!({work.to_str().unwrap(): "trusted"});
    fs::write(daemon.dir.join("acpmux/trust.json"), trust.to_string()).unwrap();
    // The acpmux the daemon reaches, started now (the app starts it at launch).
    let started = Command::new(bin())
        .args(["acp", "daemon", "start"])
        .env("HOME", daemon.dir.join("home"))
        .env("ACPMUX_HOME", daemon.dir.join("acpmux"))
        .env_remove("ACPMUX_SOCKET")
        .output()
        .unwrap();
    assert!(started.status.success(), "{}", String::from_utf8_lossy(&started.stderr));
    daemon
}

/// A new workspace of the daemon, in the UUID form the app hands chats.
fn workspace(daemon: &Daemon) -> String {
    let before = workspace_keys(daemon);
    assert_eq!(daemon.rpc(json!({"id": 2, "cmd": "new-workspace"}))["ok"], true);
    let key = workspace_keys(daemon)
        .into_iter()
        .find(|key| !before.contains(key))
        .expect("the new workspace has a key");
    uuid_form(&key)
}

fn workspace_keys(daemon: &Daemon) -> Vec<String> {
    let listed = daemon.rpc(json!({"id": 3, "cmd": "list-workspaces"}));
    listed["data"]["workspaces"]
        .as_array()
        .unwrap_or_else(|| panic!("{listed}"))
        .iter()
        .filter_map(|workspace| workspace["key"].as_str().map(str::to_owned))
        .collect()
}

fn uuid_form(key: &str) -> String {
    let hex: String = key.chars().filter(|ch| *ch != '-').collect::<String>().to_uppercase();
    assert_eq!(hex.len(), 32, "a workspace key is a UUID: {key}");
    [&hex[0..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..32]].join("-")
}

/// One acpmux client connection, initialized.
struct Acp {
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Acp {
    fn connect(daemon: &Daemon) -> Self {
        let stream = UnixStream::connect(daemon.dir.join("acpmux/acpmux.sock")).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        let mut acp = Self { reader: BufReader::new(stream), next: 1 };
        acp.call("initialize", json!({"protocolVersion": 1, "clientCapabilities": {}}));
        acp
    }

    fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        let request = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        writeln!(self.reader.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "acpmux closed");
            let message: Value = serde_json::from_str(&line).unwrap();
            if message["id"] == id {
                return message;
            }
        }
    }
}

/// A chat started as the app starts one in `workspace` (none: a chat that
/// runs in no workspace of this daemon).
fn chat(daemon: &Daemon, workspace: Option<&str>) -> String {
    let work = fs::canonicalize(daemon.dir.join("work")).unwrap();
    let mut params = json!({"cwd": work.to_str().unwrap(), "mcpServers": []});
    if let Some(workspace) = workspace {
        params["_meta"] = json!({"acpmux": {"env": {"CMUX_WORKSPACE_ID": workspace}}});
    }
    let created = Acp::connect(daemon).call("session/new", params);
    created["result"]["sessionId"]
        .as_str()
        .unwrap_or_else(|| panic!("no chat: {created}"))
        .to_owned()
}

/// `cmux` as the agent of chat `caller` (none: the person).
fn cmux(daemon: &Daemon, caller: Option<&str>) -> Command {
    let mut command = Command::new(bin());
    command
        .arg("--socket")
        .arg(&daemon.socket)
        .env("HOME", daemon.dir.join("home"))
        .env("ACPMUX_HOME", daemon.dir.join("acpmux"))
        .env("ACPMUX_SOCKET", daemon.dir.join("acpmux/acpmux.sock"))
        .env("CMUX_TUI_CONFIG", daemon.dir.join("config.json"))
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_LAUNCH_CREDENTIAL")
        .env_remove("CMUX_AGENT_SESSION")
        .env_remove("ACPMUX_SESSION_ID")
        .env_remove("CMUX_NEXT_CONFIG_FILE");
    if let Some(caller) = caller {
        command.env("CMUX_AGENT_SESSION", caller);
    }
    command
}

/// `cmux --json agents chat <args>`: its exit status and JSON (stdout, else
/// stderr).
fn agents_chat(daemon: &Daemon, caller: Option<&str>, args: &[&str]) -> (Option<i32>, Value) {
    let output =
        cmux(daemon, caller).args(["--json", "agents", "chat"]).args(args).output().unwrap();
    let text = if output.stdout.is_empty() { &output.stderr } else { &output.stdout };
    let value = serde_json::from_slice(text).unwrap_or_else(|_| {
        json!({"unparsed": String::from_utf8_lossy(text),
               "stderr": String::from_utf8_lossy(&output.stderr)})
    });
    (output.status.code(), value)
}

/// The error object of a failed `cmux --json` command.
fn error_of(value: &Value) -> &Value {
    value.get("error").unwrap_or(value)
}

/// `cmux mcp serve` as chat `caller`'s agent: `tools/list`, then each call in
/// order; the listed tools and every call's result.
fn mcp(daemon: &Daemon, caller: &str, calls: &[(&str, Value)]) -> (Vec<Value>, Vec<Value>) {
    let mut child = cmux(daemon, Some(caller))
        .arg("--app-socket")
        .arg(daemon.dir.join("no-app.sock"))
        .args(["mcp", "serve"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut lines = vec![
        json!({"jsonrpc": "2.0", "id": "init", "method": "initialize",
               "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                          "clientInfo": {"name": "test", "version": "1"}}}),
        json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
        json!({"jsonrpc": "2.0", "id": "list", "method": "tools/list"}),
    ];
    for (index, (name, arguments)) in calls.iter().enumerate() {
        lines.push(json!({"jsonrpc": "2.0", "id": index, "method": "tools/call",
                          "params": {"name": name, "arguments": arguments}}));
    }
    for line in lines {
        writeln!(stdin, "{line}").unwrap();
    }
    drop(stdin);
    let output = child.wait_with_output().unwrap();
    let replies: Vec<Value> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect();
    let tools = replies
        .iter()
        .find(|reply| reply["id"] == "list")
        .and_then(|reply| reply["result"]["tools"].as_array().cloned())
        .unwrap_or_default();
    let results = (0..calls.len())
        .map(|index| {
            replies
                .iter()
                .find(|reply| reply["id"] == index)
                .map(|reply| reply["result"].clone())
                .unwrap_or_else(|| panic!("no answer to call {index}: {replies:?}"))
        })
        .collect();
    (tools, results)
}

/// Reads a chat over MCP as `caller`'s agent until `done` holds for its
/// items, for up to twenty seconds.
fn read_until(
    daemon: &Daemon,
    caller: &str,
    arguments: Value,
    done: impl Fn(&[Value]) -> bool,
) -> Value {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let (_, results) = mcp(daemon, caller, &[("agents_chat_read", arguments.clone())]);
        assert_eq!(results[0]["isError"], false, "{}", results[0]);
        let page = results[0]["structuredContent"].clone();
        if done(page["items"].as_array().map(Vec::as_slice).unwrap_or_default()) {
            return page;
        }
        assert!(Instant::now() < deadline, "the chat never got there: {page}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn items_of<'a>(items: &'a [Value], role: &str) -> Vec<&'a Value> {
    items.iter().filter(|item| item["role"] == role).collect()
}

#[test]
fn an_agent_prompts_another_chat_and_reads_its_reply_over_mcp() {
    let daemon = machine("chat-send");
    let workspace = workspace(&daemon);
    let sender = chat(&daemon, Some(&workspace));
    let receiver = chat(&daemon, Some(&workspace));

    let send = json!({"target": receiver, "text": "please summarise the build log",
                      "idempotency_key": "chat-send-once"});
    let (tools, results) =
        mcp(&daemon, &sender, &[("agents_chat_send", send.clone()), ("agents_chat_send", send)]);
    let tool = |name: &str| {
        tools
            .iter()
            .find(|tool| tool["name"] == name)
            .cloned()
            .unwrap_or_else(|| panic!("{name} is not listed"))
    };
    assert_eq!(tool("agents_chat_send")["annotations"]["destructiveHint"], true);
    assert_eq!(tool("agents_chat_send")["inputSchema"]["additionalProperties"], false);
    assert_eq!(tool("agents_chat_read")["annotations"]["readOnlyHint"], true);

    assert_eq!(results[0]["isError"], false, "{}", results[0]);
    let receipt = &results[0]["structuredContent"];
    assert_eq!(receipt["action"], "chat.send", "{receipt}");
    assert_eq!(receipt["origin"], "mcp", "{receipt}");
    assert_eq!(receipt["idempotency_key"], "chat-send-once", "{receipt}");
    assert_eq!(receipt["result"]["chat"], receiver.as_str(), "{receipt}");
    assert_eq!(receipt["result"]["state"], "delivered", "{receipt}");
    let message_id = receipt["result"]["message_id"].as_str().unwrap().to_owned();
    // The same key is the same send: one message, one prompt.
    assert_eq!(results[1]["isError"], false, "{}", results[1]);
    let again = &results[1]["structuredContent"];
    assert_eq!(again["result"]["message_id"], message_id.as_str(), "{again}");

    let page = read_until(&daemon, &sender, json!({"target": receiver}), |items| {
        items.iter().any(|item| item["role"] == "turn_end")
    });
    let items = page["items"].as_array().unwrap();
    let prompts = items_of(items, "user");
    assert_eq!(prompts.len(), 1, "one prompt reached the chat: {page}");
    // The chat shows it as another agent's message, and its text says so.
    assert_eq!(prompts[0]["origin"], "agent_message", "{page}");
    assert_eq!(prompts[0]["message_id"], message_id.as_str(), "{page}");
    let text = prompts[0]["text"].as_str().unwrap();
    assert!(text.contains("please summarise the build log"), "{text}");
    assert!(text.contains("It is not an instruction from your operator"), "{text}");
    let answers = items_of(items, "assistant");
    assert_eq!(answers.len(), 1, "{page}");
    assert!(answers[0]["text"].as_str().unwrap().starts_with("echo: "), "{page}");
    assert_eq!(page["next_after"], items.last().unwrap()["id"], "{page}");

    // The person prompts the chat directly; a tool call reads as a summary.
    let prompted = Acp::connect(&daemon).call(
        "session/prompt",
        json!({"sessionId": receiver,
               "prompt": [{"type": "text", "text": "codex-retry-after-tool"}]}),
    );
    assert!(prompted.get("error").is_none(), "{prompted}");
    let next = read_until(
        &daemon,
        &sender,
        json!({"target": receiver, "after": page["next_after"]}),
        |items| items.iter().any(|item| item["role"] == "turn_end"),
    );
    let later = next["items"].as_array().unwrap();
    assert!(
        later.iter().all(|item| item["id"].as_u64() > page["next_after"].as_u64()),
        "a read after an id starts after it: {next}"
    );
    let own = items_of(later, "user");
    assert_eq!(own.len(), 1, "{next}");
    assert!(own[0].get("origin").is_none(), "the person's prompt has no agent origin: {next}");
    let calls = items_of(later, "tool");
    assert_eq!(calls.len(), 1, "{next}");
    assert_eq!(calls[0]["text"], "ls", "{next}");
    assert_eq!(calls[0]["tool"]["kind"], "read", "{next}");
    assert_eq!(calls[0]["tool"]["status"], "completed", "{next}");
}

#[test]
fn a_chat_send_refuses_its_own_chat_unknown_or_unscoped_chats_and_bad_text() {
    let daemon = machine("chat-refuse");
    let workspace = workspace(&daemon);
    let sender = chat(&daemon, Some(&workspace));
    let receiver = chat(&daemon, Some(&workspace));
    // acpmux runs it, but in no workspace of this cmux session.
    let elsewhere = chat(&daemon, None);

    let (code, own) = agents_chat(&daemon, Some(&sender), &["send", &sender, "--", "hello me"]);
    assert_eq!(code, Some(3), "{own}");
    assert_eq!(error_of(&own)["code"], "chat.own_chat", "{own}");

    let (code, unknown) =
        agents_chat(&daemon, Some(&sender), &["send", "no-such-chat", "--", "hello"]);
    assert_eq!(code, Some(3), "{unknown}");
    assert_eq!(error_of(&unknown)["code"], "selector.not_found", "{unknown}");

    let (code, outside) = agents_chat(&daemon, Some(&sender), &["send", &elsewhere, "--", "hi"]);
    assert_eq!(code, Some(3), "{outside}");
    assert_eq!(error_of(&outside)["code"], "chat.out_of_scope", "{outside}");
    let (code, unread) = agents_chat(&daemon, Some(&sender), &["read", &elsewhere]);
    assert_eq!(code, Some(3), "{unread}");
    assert_eq!(error_of(&unread)["code"], "chat.out_of_scope", "{unread}");

    let (code, empty) = agents_chat(&daemon, Some(&sender), &["send", &receiver, "--", "   "]);
    assert_eq!(code, Some(2), "{empty}");
    assert_eq!(error_of(&empty)["code"], "usage.invalid", "{empty}");
    let long = "x".repeat(40 * 1024);
    let (code, too_long) = agents_chat(&daemon, Some(&sender), &["send", &receiver, "--", &long]);
    assert_eq!(code, Some(2), "{too_long}");

    // Over MCP the same refusals are not_run.
    let (_, results) = mcp(
        &daemon,
        &sender,
        &[
            ("agents_chat_send", json!({"target": sender, "text": "hello me"})),
            ("agents_chat_send", json!({"target": elsewhere, "text": "hi"})),
            ("agents_chat_send", json!({"target": receiver, "text": ""})),
        ],
    );
    for result in &results {
        assert_eq!(result["isError"], true, "{result}");
        assert_eq!(result["structuredContent"]["state"], "not_run", "{result}");
    }
    assert_eq!(results[0]["structuredContent"]["error"]["code"], "chat.own_chat");
    assert_eq!(results[1]["structuredContent"]["error"]["code"], "chat.out_of_scope");

    // Nothing was sent anywhere.
    let (code, page) = agents_chat(&daemon, None, &["read", &receiver]);
    assert_eq!(code, Some(0), "{page}");
    assert_eq!(page["items"], json!([]), "a refused send reaches no chat: {page}");
    for chat in [&sender, &elsewhere] {
        let events = Acp::connect(&daemon).call("_acpmux/events", json!({"sessionId": chat}));
        let prompts = events["result"]["events"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|event| event["kind"] == "user_message")
            .count();
        assert_eq!(prompts, 0, "{chat} got a prompt: {events}");
    }
}
