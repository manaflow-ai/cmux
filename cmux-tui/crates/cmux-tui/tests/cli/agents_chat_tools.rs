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

/// An acpmux config with the test agent as `fake` (the default) and, when
/// `doomed`, as `doomed` too.
fn acpmux_config(doomed: bool) -> Value {
    let harness = json!({"argv": ["python3", FAKE_AGENT], "family": "fake"});
    let mut harnesses = json!({"fake": harness});
    if doomed {
        harnesses["doomed"] = harness;
    }
    json!({"harnesses": harnesses, "defaultHarness": "fake"})
}

/// A machine whose acpmux runs the test agent, its work folder trusted.
fn machine(name: &str) -> Daemon {
    let daemon = Daemon::start_with(name, None, Some(acpmux_config(true)));
    let work = fs::canonicalize(daemon.dir.join("work")).unwrap();
    let trust = json!({work.to_str().unwrap(): "trusted"});
    fs::write(daemon.dir.join("acpmux/trust.json"), trust.to_string()).unwrap();
    acpmux_daemon(&daemon, &["start"]);
    daemon
}

/// `cmux acp daemon <action...>` for the acpmux the daemon reaches (the app
/// starts it at launch).
fn acpmux_daemon(daemon: &Daemon, action: &[&str]) {
    let done = Command::new(bin())
        .args(["acp", "daemon"])
        .args(action)
        .env("HOME", daemon.dir.join("home"))
        .env("ACPMUX_HOME", daemon.dir.join("acpmux"))
        .env_remove("ACPMUX_SOCKET")
        .output()
        .unwrap();
    assert!(done.status.success(), "{action:?}: {}", String::from_utf8_lossy(&done.stderr));
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
        let id = self.send(method, params);
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "acpmux closed");
            let message: Value = serde_json::from_str(&line).unwrap();
            if message["id"] == id {
                return message;
            }
        }
    }

    /// Sends a request without waiting for its answer; its id.
    fn send(&mut self, method: &str, params: Value) -> u64 {
        let id = self.next;
        self.next += 1;
        let request = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        writeln!(self.reader.get_mut(), "{request}").unwrap();
        id
    }
}

/// A chat started as the app starts one in `workspace` (none: a chat that
/// runs in no workspace of this daemon).
fn chat(daemon: &Daemon, workspace: Option<&str>) -> String {
    chat_of(daemon, workspace, "fake")
}

/// `chat`, run by acpmux harness `harness`.
fn chat_of(daemon: &Daemon, workspace: Option<&str>, harness: &str) -> String {
    let work = fs::canonicalize(daemon.dir.join("work")).unwrap();
    let mut params = json!({"cwd": work.to_str().unwrap(), "mcpServers": [],
                            "_meta": {"acpmux": {"harness": harness}}});
    if let Some(workspace) = workspace {
        params["_meta"]["acpmux"]["env"] = json!({"CMUX_WORKSPACE_ID": workspace});
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
    chat_json(cmux(daemon, caller), args)
}

/// `command --json agents chat <args>`, as `agents_chat`.
fn chat_json(mut command: Command, args: &[&str]) -> (Option<i32>, Value) {
    let output = command.args(["--json", "agents", "chat"]).args(args).output().unwrap();
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

/// `cmux mcp serve --all-tools` as chat `caller`'s agent: `tools/list`, then
/// each call in order; the listed tools and every call's result. Plain
/// `serve` is code mode, which lists only `cmux_docs` and `cmux_exec`;
/// `--all-tools` lists each tool with its schema and annotations.
fn mcp(daemon: &Daemon, caller: &str, calls: &[(&str, Value)]) -> (Vec<Value>, Vec<Value>) {
    let mut child = cmux(daemon, Some(caller))
        .arg("--app-socket")
        .arg(daemon.dir.join("no-app.sock"))
        .args(["mcp", "serve", "--all-tools"])
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

/// The tool item of tool call `id`.
fn tool_item<'a>(items: &'a [Value], id: &str) -> Option<&'a Value> {
    items.iter().find(|item| item["tool"]["id"] == id)
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
    // Every item is finished, so the next read starts after the last one
    // (or after the events read past it).
    assert!(page["next_after"].as_u64() >= items.last().unwrap()["id"].as_u64(), "{page}");

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
    // A harness's title can quote the tool's input; a read never shows it.
    assert_eq!(calls[0]["text"], "", "{next}");
    assert_eq!(calls[0]["tool"]["kind"], "read", "{next}");
    assert_eq!(calls[0]["tool"]["status"], "completed", "{next}");
}

#[test]
fn a_chat_send_refuses_its_own_chat_unknown_or_unscoped_chats_and_bad_text() {
    let daemon = machine("chat-refuse");
    // A workspace of another cmux session.
    let other = Daemon::start_with("chat-refuse-other", None, None);
    let other_workspace = workspace(&other);
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

    // The text is one argument, or follows --: a flag in unquoted text is
    // never taken as cmux's own (`--session other`).
    let (code, split) = agents_chat(
        &daemon,
        Some(&sender),
        &["send", &receiver, "run", "it", "--session", "other"],
    );
    assert_eq!(code, Some(2), "{split}");
    assert_eq!(error_of(&split)["code"], "usage.invalid", "{split}");
    let (code, words) = agents_chat(&daemon, Some(&sender), &["send", &receiver, "two", "words"]);
    assert_eq!(code, Some(2), "{words}");

    // The caller's own chat named by its name or an id prefix, and a caller
    // that only acpmux names (ACPMUX_SESSION_ID).
    let info = Acp::connect(&daemon).call("_acpmux/info", json!({"sessionId": sender}));
    let name = info["result"]["name"].as_str().unwrap_or_else(|| panic!("{info}")).to_owned();
    // Chat ids share their time prefix: a unique prefix is most of one.
    for own_name in [name.as_str(), &sender[..sender.len() - 4]] {
        let (code, own) =
            agents_chat(&daemon, Some(&sender), &["send", own_name, "--", "hello me"]);
        assert_eq!(code, Some(3), "{own_name}: {own}");
        assert_eq!(error_of(&own)["code"], "chat.own_chat", "{own_name}: {own}");
    }
    let mut acpmux_agent = cmux(&daemon, None);
    acpmux_agent.env("ACPMUX_SESSION_ID", &sender);
    let (code, own) = chat_json(acpmux_agent, &["send", &sender, "--", "hello me"]);
    assert_eq!(code, Some(3), "{own}");
    assert_eq!(error_of(&own)["code"], "chat.own_chat", "{own}");

    // A chat in a workspace of another cmux session is out of scope.
    let foreign = chat(&daemon, Some(&other_workspace));
    let (code, outside) = agents_chat(&daemon, Some(&sender), &["send", &foreign, "--", "hi"]);
    assert_eq!(code, Some(3), "{outside}");
    assert_eq!(error_of(&outside)["code"], "chat.out_of_scope", "{outside}");

    // Nothing was sent anywhere.
    let (code, page) = agents_chat(&daemon, None, &["read", &receiver]);
    assert_eq!(code, Some(0), "{page}");
    assert_eq!(page["items"], json!([]), "a refused send reaches no chat: {page}");
    for chat in [&sender, &elsewhere, &foreign] {
        let events = Acp::connect(&daemon).call("_acpmux/events", json!({"sessionId": chat}));
        let prompts = events["result"]["events"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|event| event["kind"] == "user_message")
            .count();
        assert_eq!(prompts, 0, "{chat} got a prompt: {events}");
    }

    // One key is one message: the same key with other text is refused.
    let keyed = |text: &str| {
        agents_chat(
            &daemon,
            Some(&sender),
            &["--idempotency-key", "chat-conflict", "send", &receiver, "--", text],
        )
    };
    let (code, first) = keyed("first");
    assert_eq!(code, Some(0), "{first}");
    let (code, conflict) = keyed("second");
    assert_eq!(code, Some(3), "{conflict}");
    assert_eq!(error_of(&conflict)["code"], "idempotency.conflict", "{conflict}");
}

#[test]
fn a_read_holds_back_a_running_tool_call_and_never_shows_tool_titles() {
    let daemon = machine("chat-tools");
    let workspace = workspace(&daemon);
    let reader = chat(&daemon, Some(&workspace));
    let worker = chat(&daemon, Some(&workspace));
    let gate = daemon.dir.join("gate");
    assert!(Command::new("mkfifo").arg(&gate).status().unwrap().success());
    // Two tool calls run at once; the second ends while the first runs on.
    let mut person = Acp::connect(&daemon);
    person.send(
        "session/prompt",
        json!({"sessionId": worker, "prompt": [{"type": "text",
               "text": format!("parallel-tools: {}", gate.display())}]}),
    );
    let page = read_until(&daemon, &reader, json!({"target": worker}), |items| {
        tool_item(items, "fast-1").is_some_and(|fast| fast["tool"]["status"] == "completed")
    });
    let items = page["items"].as_array().unwrap();
    let slow = tool_item(items, "slow-1").unwrap_or_else(|| panic!("{page}"));
    assert_eq!(slow["tool"]["status"], "pending", "{page}");
    assert_eq!(slow["partial"], true, "a running tool call is not finished: {page}");
    assert!(tool_item(items, "fast-1").unwrap().get("partial").is_none(), "{page}");
    let next_after = page["next_after"].as_u64().unwrap();
    assert!(
        next_after < slow["id"].as_u64().unwrap(),
        "next_after never passes a running item: {page}"
    );
    // A harness titles a call with its input (a command, a path): a read
    // shows only the call's kind and status.
    for item in items_of(items, "tool") {
        assert_eq!(item["text"], "", "{page}");
    }
    assert!(!page.to_string().contains("fake-secret"), "{page}");
    assert!(!page.to_string().contains("secret-notes"), "{page}");

    fs::write(&gate, "go").unwrap();
    let next =
        read_until(&daemon, &reader, json!({"target": worker, "after": next_after}), |items| {
            items.iter().any(|item| item["role"] == "turn_end")
        });
    let later = next["items"].as_array().unwrap();
    let slow = tool_item(later, "slow-1").unwrap_or_else(|| panic!("read again whole: {next}"));
    assert_eq!(slow["tool"]["status"], "completed", "{next}");
    assert!(slow.get("partial").is_none(), "{next}");
    assert!(!next.to_string().contains("fake-secret"), "{next}");
    drop(person);
}

#[test]
fn a_read_moves_past_a_long_run_of_events_with_no_items() {
    let daemon = machine("chat-thoughts");
    let workspace = workspace(&daemon);
    let thinker = chat(&daemon, Some(&workspace));
    // More thought chunks than one read scans, then the answer.
    let prompted = Acp::connect(&daemon).call(
        "session/prompt",
        json!({"sessionId": thinker, "prompt": [{"type": "text", "text": "thoughts: 10500"}]}),
    );
    assert!(prompted.get("error").is_none(), "{prompted}");

    let mut after = 0;
    let mut items = Vec::new();
    for _ in 0..6 {
        let (code, page) =
            agents_chat(&daemon, None, &["read", &thinker, "--after", &after.to_string()]);
        assert_eq!(code, Some(0), "{page}");
        items.extend(page["items"].as_array().cloned().unwrap_or_default());
        if items.iter().any(|item| item["role"] == "turn_end") {
            break;
        }
        assert_eq!(page["has_more"], true, "{page}");
        after = page["next_after"].as_u64().unwrap_or_else(|| panic!("{page}"));
    }
    assert!(
        items.iter().any(|item| item["role"] == "turn_end"),
        "the reads never got past the thoughts: {items:?}"
    );
    let answers = items_of(&items, "assistant");
    assert_eq!(answers.len(), 1, "{items:?}");
    assert_eq!(answers[0]["text"], "thought through", "{items:?}");
}

#[test]
fn a_chat_send_that_cannot_reach_its_chat_fails_with_its_receipt() {
    let daemon = machine("chat-undelivered");
    let workspace = workspace(&daemon);
    let sender = chat(&daemon, Some(&workspace));
    let doomed = chat_of(&daemon, Some(&workspace), "doomed");
    // acpmux restarts without the chat's harness: the chat stays, but no
    // prompt can start its agent, so acpmux refuses one. Its agent ends too:
    // a hosted agent outlives a plain shutdown, and the next daemon adopts it.
    acpmux_daemon(&daemon, &["shutdown", "--end-agents"]);
    fs::write(daemon.dir.join("acpmux/config.json"), acpmux_config(false).to_string()).unwrap();
    acpmux_daemon(&daemon, &["start"]);

    let (code, receipt) =
        agents_chat(&daemon, Some(&sender), &["send", &doomed, "--", "are you there"]);
    assert_eq!(code, Some(1), "{receipt}");
    assert_eq!(receipt["action"], "chat.send", "{receipt}");
    assert_eq!(receipt["result"]["state"], "failed", "{receipt}");
    assert!(receipt["result"]["message_id"].is_string(), "{receipt}");

    let (_, results) =
        mcp(&daemon, &sender, &[("agents_chat_send", json!({"target": doomed, "text": "there?"}))]);
    assert_eq!(results[0]["isError"], true, "{}", results[0]);
    let receipt = &results[0]["structuredContent"];
    assert_eq!(receipt["result"]["state"], "failed", "{receipt}");
    assert!(receipt["result"]["message_id"].is_string(), "{receipt}");
}

#[test]
fn a_read_masks_secrets_in_another_chats_text() {
    let daemon = machine("chat-secrets");
    let workspace = workspace(&daemon);
    let reader = chat(&daemon, Some(&workspace));
    let holder = chat(&daemon, Some(&workspace));
    // The person pastes a key into one chat; the test agent echoes it back.
    let key = format!("AKIA{}", "Q7ZJ4XK2MD5P3WRT");
    let prompted = Acp::connect(&daemon).call(
        "session/prompt",
        json!({"sessionId": holder, "prompt": [{"type": "text",
               "text": format!("deploy with {key} please")}]}),
    );
    assert!(prompted.get("error").is_none(), "{prompted}");

    // Another chat's agent reads it, over MCP and over the CLI.
    let page = read_until(&daemon, &reader, json!({"target": holder}), |items| {
        items.iter().any(|item| item["role"] == "turn_end")
    });
    let (code, cli) = agents_chat(&daemon, Some(&reader), &["read", &holder]);
    assert_eq!(code, Some(0), "{cli}");
    for page in [&page, &cli] {
        assert!(!page.to_string().contains(&key), "a read shows another chat's key: {page}");
        let items = page["items"].as_array().unwrap();
        for role in ["user", "assistant"] {
            let item = items_of(items, role);
            let text = item.first().and_then(|item| item["text"].as_str()).unwrap_or_default();
            assert!(text.contains("[AWS access key]"), "{role} not masked: {page}");
        }
    }
}

/// `cmux agents chat new` started by another chat's agent (#23026): a chat in
/// a workspace of this session, with the harness asked for, whose first
/// prompt goes in as the chat's own (typed into New Agent Chat); then `state`, `continue` and
/// `interrupt` reach it. With no app to show it, the chat still runs and the
/// receipt says no tab shows it.
#[test]
fn an_agent_starts_a_chat_in_a_workspace_and_drives_it_without_the_app() {
    let daemon = machine("chat-new");
    let workspace = workspace(&daemon);
    let caller = chat(&daemon, Some(&workspace));
    let work = fs::canonicalize(daemon.dir.join("work")).unwrap();
    let no_app = daemon.dir.join("no-app.sock");
    let as_caller = || {
        let mut command = cmux(&daemon, Some(&caller));
        command.arg("--app-socket").arg(&no_app);
        command
    };

    let (code, created) = chat_json(
        as_caller(),
        &[
            "new",
            "--workspace",
            &workspace.to_lowercase(),
            "--harness",
            "fake",
            "--cwd",
            work.to_str().unwrap(),
            "--name",
            "helper",
            "--",
            "please list the files",
        ],
    );
    assert_eq!(code, Some(0), "{created}");
    assert_eq!(created["action"], "chat.new", "{created}");
    let result = &created["result"];
    let started = result["chat"].as_str().unwrap_or_else(|| panic!("{created}")).to_owned();
    assert_ne!(started, caller, "{created}");
    assert_eq!(result["opened"], false, "no app shows it: {created}");
    assert!(result["open_error"].is_object(), "{created}");
    // The first prompt is the chat's own, as a person types it into New Agent Chat.
    assert_eq!(result["prompt"]["state"], "accepted", "{created}");

    // The chat runs in that workspace, so this session's chat verbs reach it.
    let info = Acp::connect(&daemon).call("_acpmux/info", json!({"sessionId": started}));
    assert_eq!(
        info["result"]["sessionEnv"]["CMUX_WORKSPACE_ID"].as_str().map(str::to_uppercase),
        Some(workspace.clone()),
        "{info}"
    );
    let page = read_until(&daemon, &caller, json!({"target": started}), |items| {
        items.iter().any(|item| item["role"] == "turn_end")
    });
    let prompts = items_of(page["items"].as_array().unwrap(), "user");
    assert_eq!(prompts[0]["origin"], Value::Null, "the chat's own prompt: {page}");
    assert_eq!(prompts[0]["text"], "please list the files", "{page}");

    let (code, state) = chat_json(as_caller(), &["state", &started]);
    assert_eq!(code, Some(0), "{state}");
    assert_eq!(state["result"]["chat"], started.as_str(), "{state}");
    assert_eq!(state["result"]["running"], false, "{state}");

    // A nudge is an agent message with the default text.
    let (code, nudged) = chat_json(as_caller(), &["continue", &started]);
    assert_eq!(code, Some(0), "{nudged}");
    assert_eq!(nudged["result"]["state"], "delivered", "{nudged}");
    let after = page["next_after"].clone();
    let next = read_until(&daemon, &caller, json!({"target": started, "after": after}), |items| {
        items.iter().any(|item| item["role"] == "turn_end")
    });
    let nudges = items_of(next["items"].as_array().unwrap(), "user");
    assert!(nudges[0]["text"].as_str().unwrap().contains("Continue."), "{next}");

    let (code, stopped) = chat_json(as_caller(), &["interrupt", &started]);
    assert_eq!(code, Some(0), "{stopped}");
    assert_eq!(stopped["result"]["state"], "cancel_requested", "{stopped}");

    // Never the caller's own chat, never a chat outside this session.
    let (code, own) = chat_json(as_caller(), &["interrupt", &caller]);
    assert_eq!(code, Some(3), "{own}");
    assert_eq!(error_of(&own)["code"], "chat.own_chat", "{own}");
    let elsewhere = chat(&daemon, None);
    let (code, outside) = chat_json(as_caller(), &["state", &elsewhere]);
    assert_eq!(code, Some(3), "{outside}");
    assert_eq!(error_of(&outside)["code"], "chat.out_of_scope", "{outside}");

    // In a pane of that workspace, named by its pane_ id.
    let output = as_caller().args(["--json", "agents", "snapshot"]).output().unwrap();
    let snapshot: Value = serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|_| panic!("snapshot: {}", String::from_utf8_lossy(&output.stderr)));
    let daemon_snapshot = snapshot.get("daemon").unwrap_or(&snapshot);
    let workspace_id = daemon_snapshot["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|item| item["extra"]["key"].as_str().is_some_and(|key| uuid_form(key) == workspace))
        .map(|item| item["id"].clone())
        .unwrap_or_else(|| panic!("no workspace {workspace} in {snapshot}"));
    let screen_ids: Vec<Value> = daemon_snapshot["screens"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|screen| screen["workspace_id"] == workspace_id)
        .map(|screen| screen["id"].clone())
        .collect();
    let pane = daemon_snapshot["panes"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|pane| screen_ids.contains(&pane["screen_id"]))
        .and_then(|pane| pane["id"].as_str())
        .unwrap_or_else(|| panic!("no pane of {workspace_id} in {snapshot}"))
        .to_owned();
    let (code, in_pane) =
        chat_json(as_caller(), &["new", "--pane", &pane, "--cwd", work.to_str().unwrap()]);
    assert_eq!(code, Some(0), "{in_pane}");
    let second = in_pane["result"]["chat"].as_str().unwrap_or_else(|| panic!("{in_pane}"));
    let (code, _) = chat_json(as_caller(), &["state", second]);
    assert_eq!(code, Some(0), "a chat started in a pane is in this session's scope");

    // An agent never starts a chat that approves edits without asking.
    let (code, policy) = chat_json(as_caller(), &["new", "--policy", "approve-all"]);
    assert_eq!(code, Some(2), "{policy}");

    // A workspace this session does not have starts nothing.
    let (code, unknown) = chat_json(as_caller(), &["new", "--workspace", "ws_nope", "--", "hi"]);
    assert_eq!(code, Some(3), "{unknown}");
    assert_eq!(error_of(&unknown)["code"], "selector.not_found", "{unknown}");
    let (code, both) = chat_json(as_caller(), &["new", "--workspace", "a", "--pane", "b"]);
    assert_eq!(code, Some(2), "{both}");

    // The MCP tools list the new verbs with the right annotations.
    let (tools, _) = mcp(&daemon, &caller, &[]);
    let tool = |name: &str| {
        tools.iter().find(|tool| tool["name"] == name).cloned().unwrap_or_else(|| panic!("{name}"))
    };
    assert_eq!(tool("agents_chat_state")["annotations"]["readOnlyHint"], true);
    assert_eq!(tool("agents_chat_interrupt")["annotations"]["destructiveHint"], true);
    assert_eq!(tool("agents_chat_new")["inputSchema"]["additionalProperties"], false);
}

/// A fake cmux app control socket at `socket`: `agent.acpmux` names `acpmux` (the app's own
/// acpmux), `action.run` answers a run with a tab, anything else is not in this app. Serves
/// until the test process ends.
fn fake_app_with_acpmux(socket: &std::path::Path, acpmux: PathBuf) {
    let listener = UnixListener::bind(socket).unwrap();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let acpmux = acpmux.clone();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut writer = stream;
                let mut line = String::new();
                while reader.read_line(&mut line).unwrap_or(0) > 0 {
                    let request: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
                    line.clear();
                    let response = match request["method"].as_str() {
                        Some("agent.acpmux") => json!({"id": request["id"], "ok": true,
                            "result": {"socket_path": acpmux.to_str().unwrap()}}),
                        Some("action.run") => json!({"id": request["id"], "ok": true,
                            "result": {"action": request["params"]["action"], "ran": true,
                                       "result": {"tab": "tab_fake"}}}),
                        _ => json!({"id": request["id"], "ok": false, "error": {
                            "code": "unavailable", "message": "not in this fake app", "data": {}}}),
                    };
                    if writeln!(writer, "{response}").is_err() {
                        break;
                    }
                }
            });
        }
    });
}

/// A caller whose own acpmux is another one, as a Chief turn's is (its home's; its `cmux` calls
/// reach the app's daemon session): `chat new` starts the chat in the app's own acpmux
/// (`agent.acpmux`), an ordinary chat of the app and not a subagent of the caller's, and
/// `state`, `read` and `interrupt` find it there; a `send` goes through the daemon, whose pump
/// delivers it in that acpmux, under the daemon's agent message policy (#23026).
#[test]
fn a_caller_with_its_own_acpmux_starts_and_drives_a_chat_of_the_apps_acpmux() {
    let daemon = machine("chat-app-acpmux");
    let workspace = workspace(&daemon);
    let work = fs::canonicalize(daemon.dir.join("work")).unwrap();
    let app_socket = daemon.dir.join("app.sock");
    fake_app_with_acpmux(&app_socket, daemon.dir.join("acpmux/acpmux.sock"));
    let chief = || {
        let mut command = cmux(&daemon, None);
        // The caller's own acpmux: none listens there.
        command.env("ACPMUX_SOCKET", daemon.dir.join("chief-home/acpmux.sock"));
        command.arg("--app-socket").arg(&app_socket);
        command
    };

    let (code, created) = chat_json(
        chief(),
        &[
            "new",
            "--workspace",
            &workspace,
            "--cwd",
            work.to_str().unwrap(),
            "--",
            "hello from chief",
        ],
    );
    assert_eq!(code, Some(0), "{created}");
    assert_eq!(created["result"]["opened"], true, "{created}");
    assert_eq!(created["result"]["tab"], "tab_fake", "{created}");
    assert_eq!(created["result"]["prompt"]["state"], "accepted", "{created}");
    let started = created["result"]["chat"].as_str().unwrap().to_owned();
    // The chat runs in the app's acpmux.
    let info = Acp::connect(&daemon).call("_acpmux/info", json!({"sessionId": started}));
    assert!(info.get("error").is_none(), "{info}");

    let (code, state) = chat_json(chief(), &["state", &started]);
    assert_eq!(code, Some(0), "{state}");
    assert_eq!(state["result"]["chat"], started.as_str(), "{state}");

    let (code, sent) = chat_json(chief(), &["send", &started, "--", "and one more"]);
    assert_eq!(code, Some(0), "{sent}");
    assert_eq!(sent["result"]["state"], "delivered", "{sent}");

    let deadline = Instant::now() + Duration::from_secs(20);
    let items = loop {
        let (code, page) = chat_json(chief(), &["read", &started]);
        assert_eq!(code, Some(0), "{page}");
        let items = page["items"].as_array().cloned().unwrap_or_default();
        if items.iter().filter(|item| item["role"] == "turn_end").count() >= 2 {
            break items;
        }
        assert!(Instant::now() < deadline, "the chat never answered both: {page}");
        std::thread::sleep(Duration::from_millis(100));
    };
    let prompts = items_of(&items, "user");
    assert_eq!(prompts[0]["text"], "hello from chief", "the chat's own prompt: {items:?}");
    assert_eq!(prompts[0]["origin"], Value::Null, "{items:?}");
    assert_eq!(prompts[1]["origin"], "agent_message", "a send is another agent's: {items:?}");
    assert!(prompts[1]["text"].as_str().unwrap().contains("and one more"), "{items:?}");

    let (code, stopped) = chat_json(chief(), &["interrupt", &started]);
    assert_eq!(code, Some(0), "{stopped}");
}

/// A chat the person started, then restored after a restart and shown by no tab yet (#25571):
/// acpmux keeps it with no agent running and no client attached. A Chief-like caller (its own
/// acpmux elsewhere) finds it in the app's acpmux, and its send resumes the chat's harness and
/// runs as that chat's next turn, after the person's earlier one.
#[test]
fn a_caller_sends_to_a_restored_chat_no_tab_has_shown() {
    let daemon = machine("chat-restored");
    let workspace = workspace(&daemon);
    let app_socket = daemon.dir.join("app.sock");
    fake_app_with_acpmux(&app_socket, daemon.dir.join("acpmux/acpmux.sock"));
    let chief = || {
        let mut command = cmux(&daemon, None);
        command.env("ACPMUX_SOCKET", daemon.dir.join("chief-home/acpmux.sock"));
        command.arg("--app-socket").arg(&app_socket);
        command
    };
    let restored = chat(&daemon, Some(&workspace));
    let prompted = Acp::connect(&daemon).call(
        "session/prompt",
        json!({"sessionId": restored, "prompt": [{"type": "text", "text": "the person's turn"}]}),
    );
    assert!(prompted.get("error").is_none(), "{prompted}");

    // The app quits and acpmux restarts with the chat's agent ended: the chat is restored, and
    // nothing attaches to it until a tab shows it.
    acpmux_daemon(&daemon, &["shutdown", "--end-agents"]);
    acpmux_daemon(&daemon, &["start"]);
    let (code, before) = chat_json(chief(), &["read", &restored]);
    assert_eq!(code, Some(0), "{before}");
    let items = before["items"].as_array().cloned().unwrap_or_default();
    assert_eq!(items_of(&items, "user")[0]["text"], "the person's turn", "{before}");
    let after = before["next_after"].as_u64().unwrap_or_else(|| panic!("{before}"));

    let (code, sent) = chat_json(chief(), &["send", &restored, "--", "pick this back up"]);
    assert_eq!(code, Some(0), "{sent}");
    assert_eq!(sent["result"]["chat"], restored.as_str(), "{sent}");
    assert_eq!(sent["result"]["state"], "delivered", "{sent}");

    let deadline = Instant::now() + Duration::from_secs(20);
    let later = loop {
        let (code, page) = chat_json(chief(), &["read", &restored, "--after", &after.to_string()]);
        assert_eq!(code, Some(0), "{page}");
        let items = page["items"].as_array().cloned().unwrap_or_default();
        if items.iter().any(|item| item["role"] == "turn_end") {
            break items;
        }
        assert!(Instant::now() < deadline, "the restored chat never ran the send: {page}");
        std::thread::sleep(Duration::from_millis(100));
    };
    let prompts = items_of(&later, "user");
    assert_eq!(prompts.len(), 1, "one new turn: {later:?}");
    assert_eq!(prompts[0]["origin"], "agent_message", "{later:?}");
    assert!(prompts[0]["text"].as_str().unwrap().contains("pick this back up"), "{later:?}");
    let answers = items_of(&later, "assistant");
    assert!(
        answers.iter().any(|item| item["text"].as_str().unwrap_or_default().starts_with("echo: ")),
        "the resumed agent answered the send: {later:?}"
    );
}
