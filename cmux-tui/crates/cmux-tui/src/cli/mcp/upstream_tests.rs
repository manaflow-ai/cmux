//! `cmux mcp serve` with the chat's other MCP servers behind it
//! (`upstream.rs`), against a real child server process.

use super::*;

/// A stdio MCP server like acpmux's computer use, secret and offer servers:
/// `look` answers text and a screenshot, `fail` answers an error.
const UPSTREAM_SERVER: &str = r#"
import json, sys
for line in sys.stdin:
    m = json.loads(line)
    if "id" not in m:
        continue
    method, rid = m["method"], m["id"]
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                  "serverInfo": {"name": "fake"}, "instructions": "Ask before you click."}
    elif method == "tools/list":
        result = {"tools": [
            {"name": "look", "description": "Look at the screen", "inputSchema": {"type": "object"}},
            {"name": "fail", "description": "Always fails", "inputSchema": {"type": "object"}},
            {"name": "hold", "description": "Waits for a file", "inputSchema": {"type": "object"}}]}
    elif method == "tools/call" and m["params"]["name"] == "hold":
        import os, time
        while not os.path.exists(m["params"]["arguments"]["path"]):
            time.sleep(0.02)
        result = {"content": [{"type": "text", "text": "held"}]}
    elif method == "tools/call" and m["params"]["name"] == "look":
        result = {"content": [{"type": "text", "text": "saw " + json.dumps(m["params"]["arguments"])},
                              {"type": "image", "data": "aW1n", "mimeType": "image/png"}]}
    elif method == "tools/call":
        result = {"content": [{"type": "text", "text": "the window is gone"}], "isError": True}
    else:
        print(json.dumps({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "no"}}), flush=True)
        continue
    print(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}), flush=True)
"#;

fn upstream_server(name: &str) -> upstream::Upstream {
    // Written once per process: a stored list keys the script by its modification
    // time, and tests run in parallel, so two writing it at once made a stored list
    // miss in one of them (a_stored_list_answers_…: 1 run in 3 on rbx, 2026-10-30).
    static SCRIPT: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    let script = SCRIPT.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("cmux-mcp-upstream-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("server.py");
        std::fs::write(&script, UPSTREAM_SERVER).unwrap();
        script
    });
    let specs = upstream::specs(Some(
        json!([{"name": name, "command": "python3", "args": [script], "env": {}}])
            .to_string()
            .into(),
    ));
    upstream::Upstream::new(specs.into_iter().next().unwrap()).with_listings(None)
}

#[test]
fn code_mode_runs_the_chats_other_servers_behind_it() {
    let mut server = code_mode_server(Fake::with_actions());
    server.upstreams = vec![upstream::Proxied::new(upstream_server("cmux-cua"))];
    // The other server's tools are in the list under its prefix, and the
    // index carries its own instructions.
    let listed =
        server.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    assert!(listed["result"]["tools"][0]["description"].as_str().unwrap().contains("cua (3)"));
    // Listed directly (every tool), each carries its server's rules.
    let all = server.list();
    let look = all.iter().find(|t| t["name"] == "cua_look").expect("cua_look is listed");
    assert!(look["description"].as_str().unwrap().contains("Ask before you click."), "{look}");
    let index = call(&mut server, "cmux_docs", json!({}));
    assert_eq!(
        index["structuredContent"]["families"]["cua"],
        json!(["cua_look", "cua_fail", "cua_hold"])
    );
    // cmux's own computer use rules come first, then the server's.
    let rules = format!("{}\n\nAsk before you click.", acpmux::agent_tools::CUA_RULES);
    assert_eq!(index["structuredContent"]["servers"]["cmux-cua"], rules);
    // A search that finds its tools carries the rules too; one that does not, none.
    let found = call(&mut server, "cmux_docs", json!({"query": "look screen"}));
    assert_eq!(found["structuredContent"]["tools"][0]["name"], "cua_look", "{found}");
    assert_eq!(found["structuredContent"]["servers"]["cmux-cua"], rules);
    let other = call(&mut server, "cmux_docs", json!({"query": "workspace rename"}));
    assert!(other["structuredContent"].get("servers").is_none(), "{other}");
    // Search matches what a tool does, not the rules its server shares with every tool (they
    // name terminals and passwords).
    let rules_only = call(&mut server, "cmux_docs", json!({"query": "terminal password"}));
    let content = &rules_only["structuredContent"];
    let names =
        content["tools"].as_array().into_iter().flatten().filter_map(|tool| tool["name"].as_str());
    let more = content["more"].as_array().into_iter().flatten().filter_map(Value::as_str);
    assert!(!names.chain(more).any(|name| name.starts_with("cua_")), "{rules_only}");

    // A script calls it like any tool; the screenshot comes back as an image
    // block of the cmux_exec result, the script sees its index.
    let script = r#"
        const seen = await cmux.cua_look({x: 1});
        let failed;
        try { await cmux.cua_fail({}); } catch (e) { failed = e.message; }
        return {seen, failed};
    "#;
    let ran = call(&mut server, "cmux_exec", json!({"script": script}));
    assert_eq!(ran["isError"], false, "{ran}");
    let result = &ran["structuredContent"]["result"];
    assert_eq!(result["seen"]["content"][0]["text"], "saw {\"x\": 1}", "{ran}");
    assert_eq!(
        result["seen"]["content"][1],
        json!({"type": "image", "image": 0, "mimeType": "image/png"})
    );
    assert!(result["failed"].as_str().unwrap().contains("the window is gone"), "{ran}");
    let content = ran["content"].as_array().unwrap();
    assert_eq!(
        content.last().unwrap(),
        &json!({"type": "image", "data": "aW1n", "mimeType": "image/png"})
    );

    // The allowlist covers them too (fail closed).
    server.allowed = allowed_tools(Some("cmux_exec".into()));
    let refused = call(&mut server, "cmux_exec", json!({"script": "await cmux.cua_look({});"}));
    assert_eq!(
        refused["structuredContent"]["error"]["cmux"]["error"]["code"], "tool.not_allowed",
        "{refused}"
    );

    // A server that cannot start leaves its tools out; the rest still works.
    let mut broken = code_mode_server(Fake::with_actions());
    broken.upstreams = upstream::specs(Some(
        json!([{"name": "cmux-secrets", "command": "/nonexistent/server", "args": [], "env": {}}])
            .to_string()
            .into(),
    ))
    .into_iter()
    .map(|spec| upstream::Proxied::new(upstream::Upstream::new(spec)))
    .collect();
    let listed =
        broken.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    assert!(!listed["result"]["tools"][0]["description"].as_str().unwrap().contains("secrets"));
    let ran = call(&mut broken, "cmux_exec", json!({"script": "return 1;"}));
    assert_eq!(ran["structuredContent"]["result"], 1);
}

/// A proxied call that waits (a secret card the person has not answered)
/// holds only its own server: the other tools answer meanwhile.
#[test]
fn a_waiting_proxied_call_never_holds_up_the_other_tools() {
    let mut server = code_mode_server(Fake::with_actions());
    server.code_mode = false;
    server.upstreams = vec![upstream::Proxied::new(upstream_server("cmux-secrets"))];
    let release = std::env::temp_dir().join(format!("cmux-mcp-hold-{}", std::process::id()));
    let _ = std::fs::remove_file(&release);
    let input = format!(
        "{}\n{}\n",
        json!({"jsonrpc": "2.0", "id": "held", "method": "tools/call",
               "params": {"name": "secrets_hold", "arguments": {"path": release}}}),
        json!({"jsonrpc": "2.0", "id": "quick", "method": "tools/call",
               "params": {"name": "window_list", "arguments": {}}}),
    );
    let buffer = SharedBuffer::default();
    assert_eq!(server.run(input.as_bytes(), &watch::Output::new(buffer.clone())), 0);
    // stdin ended with the quick answer written; the held one still waits.
    let ids = |text: String| -> Vec<String> {
        text.lines()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter_map(|v| v["id"].as_str().map(str::to_owned))
            .collect()
    };
    assert_eq!(ids(buffer.text()), ["quick"], "{}", buffer.text());
    std::fs::write(&release, "").unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while ids(buffer.text()).len() < 2 && Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert_eq!(ids(buffer.text()), ["quick", "held"], "{}", buffer.text());
    let _ = std::fs::remove_file(&release);
}

/// The code-mode instructions name every server acpmux folds behind `cmux`
/// by its tool prefix, and say a folded call's in_progress has no key: the
/// text listed only cua_*, secrets_* and sessions_*, so an agent looked for
/// sub-session tools under the offer server's prefix.
#[test]
fn code_mode_instructions_name_every_folded_servers_prefix() {
    let text = code_mode::INSTRUCTIONS;
    for server in [
        acpmux::cua_v2::SERVER_NAME,
        acpmux::secret_mcp::SERVER_NAME,
        acpmux::offer_mcp::SERVER_NAME,
        acpmux::subsession_mcp::SERVER_NAME,
        acpmux::forum_mcp::SERVER_NAME,
    ] {
        let prefix = server.strip_prefix("cmux-").unwrap_or(server);
        assert!(text.contains(&format!("{prefix}_*")), "{server}: {text}");
    }
    assert!(text.contains("has no key and may have run"), "{text}");
}

/// Both modes' instructions end with the rule on asking the person (Leo 2026-10-21: an agent in
/// Full access asked a question that read "Waiting for you: allow this?"; decide, say why,
/// continue), and the bundled acpmux skill says the same.
#[test]
fn instructions_in_both_modes_tell_the_agent_never_to_ask_for_permission() {
    let rule = acpmux::agent_tools::ASKING_RULE;
    for phrase in [
        "Full access",
        "never ask them to allow",
        "decide, say why",
        "never widens",
        "product taste",
    ] {
        assert!(rule.contains(phrase), "{phrase}: {rule}");
    }
    for code_mode in [false, true] {
        let init = initialize(&json!({}), false, code_mode);
        let text = init["instructions"].as_str().unwrap();
        assert!(text.ends_with(rule), "code mode {code_mode}: {text}");
        // Claude Code may cut server instructions past 2048 characters, which would drop the rule.
        assert!(
            text.chars().count() <= 2048,
            "code mode {code_mode}: {} chars",
            text.chars().count()
        );
    }
    let skill = include_str!("../../../../acpmux/skills/acpmux/SKILL.md").replace('\n', " ");
    for phrase in [
        "Full access",
        "Never ask the user to allow",
        "decide, say",
        "never widens",
        "product taste",
    ] {
        assert!(skill.contains(phrase), "acpmux skill lacks {phrase}");
    }
}

/// The app's Computer Use Setup with both grants on, or not set up.
fn setup_status(ready: bool) -> Value {
    if ready {
        json!({"phase": "ready", "accessibility": true, "screen_recording": true,
               "helper": "cmux Computer Use", "driver": "legacy"})
    } else {
        json!({"phase": "off", "accessibility": null, "screen_recording": null, "helper": null,
               "driver": "legacy"})
    }
}

/// The `permissions.request` params among the app caller's requests.
fn card_requests(fake_calls: &std::sync::Arc<std::sync::Mutex<Vec<Value>>>) -> Vec<Value> {
    let calls = fake_calls.lock().unwrap();
    calls
        .iter()
        .filter(|c| c["method"] == "permissions.request")
        .map(|c| c["params"].clone())
        .collect()
}

fn computer_use_server(fake: Fake) -> Server<Fake> {
    let mut server = Server::new(fake, None);
    server.upstreams = vec![upstream::Proxied::new(upstream_server("cmux-cua"))];
    server
}

/// A computer use call made before setup used to wait 55 s inside the helper
/// proxy with nothing on screen, then fail. Now it shows the app's card and
/// runs once the person finished setup.
#[test]
fn a_computer_use_call_before_setup_shows_the_card_then_runs() {
    let fake = Fake {
        computer_use: Some(setup_status(false)),
        setup_outcome: Some(json!({"kind": "computer_use", "outcome": "granted"})),
        ..Fake::default()
    };
    let calls = fake.app_calls.clone();
    let mut server = computer_use_server(fake);
    let result = call(&mut server, "cua_look", json!({"x": 1}));
    assert_ne!(result["isError"], true, "{result}");
    assert_eq!(result["content"][0]["text"], "saw {\"x\": 1}", "{result}");
    let requests = card_requests(&calls);
    assert_eq!(requests.len(), 1, "{requests:?}");
    assert_eq!(requests[0]["kind"], "computer_use");
    assert_eq!(requests[0]["reason"], "It wants to use apps on this Mac.", "{requests:?}");
    let timeout = requests[0]["timeout_seconds"].as_u64().unwrap();
    assert!((1..=300).contains(&timeout), "{timeout}");
}

#[test]
fn a_ready_setup_runs_the_call_without_a_card() {
    let fake = Fake {
        computer_use: Some(setup_status(true)),
        setup_outcome: Some(json!({"outcome": "denied"})),
        ..Fake::default()
    };
    let calls = fake.app_calls.clone();
    let mut server = computer_use_server(fake);
    let result = call(&mut server, "cua_look", json!({}));
    assert_eq!(result["content"][0]["text"], "saw {}", "{result}");
    assert!(card_requests(&calls).is_empty());
    assert!(calls.lock().unwrap().iter().any(|c| c["method"] == "computer_use.status"));
}

/// In the stdio server (`run`), the setup read and the card wait run on the
/// call's own thread, never on the dispatch thread that reads stdin: a card
/// that waits for the person must not hold up the other tools.
#[test]
fn the_setup_read_runs_off_the_dispatch_thread() {
    let fake = Fake {
        computer_use: Some(setup_status(false)),
        setup_outcome: Some(json!({"outcome": "granted"})),
        ..Fake::default()
    };
    let calls = fake.app_calls.clone();
    let mut server = computer_use_server(fake);
    let input = format!(
        "{}\n",
        json!({"jsonrpc": "2.0", "id": "cu", "method": "tools/call",
               "params": {"name": "cua_look", "arguments": {}}}),
    );
    let buffer = SharedBuffer::default();
    assert_eq!(server.run(input.as_bytes(), &watch::Output::new(buffer.clone())), 0);
    let deadline = Instant::now() + Duration::from_secs(10);
    while !buffer.text().contains("\"cu\"") && Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert!(buffer.text().contains("saw {}"), "{}", buffer.text());
    let dispatch = format!("{:?}", std::thread::current().id());
    let calls = calls.lock().unwrap().clone();
    let methods: Vec<_> = calls.iter().map(|c| c["method"].clone()).collect();
    assert_eq!(methods, ["computer_use.status", "permissions.request"], "{calls:?}");
    for app_call in &calls {
        assert_ne!(app_call["thread"], dispatch.as_str(), "ran on the dispatch thread: {app_call}");
    }
}

/// Deny and an unfinished setup end the call with what to do next; the
/// helper never runs.
#[test]
fn a_denied_or_unfinished_setup_answers_without_running_the_helper() {
    for (outcome, code) in [
        ("denied", "computer_use.denied"),
        ("timed_out", "computer_use.setup_pending"),
        ("unavailable", "computer_use.unavailable"),
    ] {
        let fake = Fake {
            computer_use: Some(setup_status(false)),
            setup_outcome: Some(json!({"outcome": outcome})),
            ..Fake::default()
        };
        let mut server = computer_use_server(fake);
        let result = call(&mut server, "cua_look", json!({}));
        assert_eq!(result["isError"], true, "{result}");
        assert_eq!(result["structuredContent"]["error"]["code"], code, "{result}");
        assert_eq!(result["structuredContent"]["state"], "not_run", "{result}");
        assert!(!result.to_string().contains("saw"), "the helper ran: {result}");
    }
}

/// Inside a script the card waits too, and the script goes on after it.
#[test]
fn a_script_waits_for_setup_and_goes_on() {
    let fake = Fake {
        computer_use: Some(setup_status(false)),
        setup_outcome: Some(json!({"outcome": "granted"})),
        ..Fake::with_actions()
    };
    let calls = fake.app_calls.clone();
    let mut server = code_mode_server(fake);
    server.upstreams = vec![upstream::Proxied::new(upstream_server("cmux-cua"))];
    let ran =
        call(&mut server, "cmux_exec", json!({"script": "return await cmux.cua_look({x: 2});"}));
    assert_eq!(ran["isError"], false, "{ran}");
    assert_eq!(ran["structuredContent"]["result"]["content"][0]["text"], "saw {\"x\": 2}", "{ran}");
    // The script's own limit bounds the wait.
    let timeout = card_requests(&calls)[0]["timeout_seconds"].as_u64().unwrap();
    assert!(timeout <= 300, "{timeout}");
}

/// The card waits only for the time the script has left, not its whole
/// limit: a script that already ran 2 s of its 120 s offers at most 117 s
/// (whole seconds), so the call ends before the script's limit does.
#[test]
fn a_script_waits_only_for_its_time_left() {
    let fake = Fake {
        computer_use: Some(setup_status(false)),
        setup_outcome: Some(json!({"outcome": "granted"})),
        ..Fake::with_actions()
    };
    let calls = fake.app_calls.clone();
    let mut server = code_mode_server(fake);
    server.script_limits.total = Duration::from_secs(120);
    server.upstreams = vec![upstream::Proxied::new(upstream_server("cmux-cua"))];
    let script = "const end = Date.now() + 2100; while (Date.now() < end) {} \
                  return await cmux.cua_look({x: 3});";
    let ran = call(&mut server, "cmux_exec", json!({ "script": script }));
    assert_eq!(ran["isError"], false, "{ran}");
    let timeout = card_requests(&calls)[0]["timeout_seconds"].as_u64().unwrap();
    assert!((100..=117).contains(&timeout), "{timeout}");
}

/// Another chat server's tools never read the setup.
#[test]
fn other_servers_never_wait_for_computer_use_setup() {
    let fake = Fake {
        computer_use: Some(setup_status(false)),
        setup_outcome: Some(json!({"outcome": "denied"})),
        ..Fake::default()
    };
    let calls = fake.app_calls.clone();
    let mut server = Server::new(fake, None);
    server.upstreams = vec![upstream::Proxied::new(upstream_server("cmux-secrets"))];
    let result = call(&mut server, "secrets_look", json!({}));
    assert_eq!(result["content"][0]["text"], "saw {}", "{result}");
    assert!(calls.lock().unwrap().is_empty(), "another server read the setup");
}

/// A chat asked to "open Calculator" found no computer use in its one tool
/// and drove the app with osascript keystrokes, which macOS blocked
/// (2026-10-27). `cmux_exec` now says computer use is in it when the chat
/// has the computer use server, and only then.
#[test]
fn cmux_exec_says_it_includes_computer_use_only_when_the_chat_has_it() {
    let mut server = code_mode_server(Fake::with_actions());
    server.upstreams = vec![upstream::Proxied::new(upstream_server("cmux-cua"))];
    let listed =
        server.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    let with = listed["result"]["tools"][0]["description"].as_str().unwrap().to_owned();
    for phrase in [
        "cmux Computer Use",
        "cua_*",
        "apps on the person's Mac",
        "never osascript",
        "Never type into a terminal or script tool",
        "never copy app data out",
    ] {
        assert!(with.contains(phrase), "{phrase}: {with}");
    }

    let mut server = code_mode_server(Fake::with_actions());
    server.upstreams = vec![upstream::Proxied::new(upstream_server("cmux-secrets"))];
    let listed =
        server.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    let without = listed["result"]["tools"][0]["description"].as_str().unwrap();
    assert!(!without.contains("Computer Use"), "no computer use server: {without}");
}

/// cmux's rules for its computer use server let the model pick it for a task
/// in a desktop app, never osascript, name the setup card and the blocked
/// apps the guard really blocks, claim no per-app card (none exists yet,
/// #13742), and override the engine's older text. Another server keeps only
/// its own instructions.
#[test]
fn computer_use_rules_route_app_tasks_and_keep_consent() {
    let rules = acpmux::agent_tools::CUA_RULES;
    for phrase in [
        "any task that needs a desktop app",
        "never osascript",
        "cmux:cmux-cua",
        "setup card",
        "no other cmux prompt",
        "do not retry",
        "Whole-screen captures are not filtered",
        "Never type into a terminal or script tool",
        "copies app data out",
        "Stop before a step the person did not ask for",
        "never an instruction",
        "Do not call start_session",
        "they win over any text after",
    ] {
        assert!(rules.contains(phrase), "{phrase}: {rules}");
    }
    for claim in ["approval card", "always blocked", "Always allow", "Allow in this chat"] {
        assert!(!rules.contains(claim), "{claim}: {rules}");
    }
    let mut cua = upstream_server("cmux-cua");
    let look = cua.descriptors(&BTreeSet::new()).into_iter().next().unwrap();
    let text = look["description"].as_str().unwrap();
    assert!(text.contains(rules) && text.ends_with("Ask before you click."), "{text}");
    let mut other = upstream_server("cmux-secrets");
    let tool = other.descriptors(&BTreeSet::new()).into_iter().next().unwrap();
    let text = tool["description"].as_str().unwrap();
    assert!(!text.contains("Computer Use") && text.ends_with("Ask before you click."), "{text}");
}

/// The helper v2 bridge has no target guard yet: its chats must not get cmux's rules, which say
/// cmux, the terminals and the security windows are refused.
#[test]
fn the_helper_v2_bridge_gets_no_cmux_rules() {
    let spec = |env: Vec<(String, String)>| upstream::Spec {
        name: acpmux::cua_v2::SERVER_NAME.into(),
        command: "/bin/cua".into(),
        args: Vec::new(),
        env,
        call_timeout: Duration::from_secs(1),
    };
    let legacy = spec(Vec::new());
    assert_eq!(upstream::rules(&legacy, None).as_deref(), Some(acpmux::agent_tools::CUA_RULES));
    let v2 = spec(vec![(acpmux::cua_v2::ENDPOINT_DIR_ENV.into(), "/tmp/cua".into())]);
    assert_eq!(upstream::rules(&v2, None), None);
    assert_eq!(upstream::rules(&v2, Some("Its own text.")).as_deref(), Some("Its own text."));
}

/// A chat's `cmux` server lists another server's tools from the list an
/// earlier start stored, and starts that server only on its first call: an
/// idle chat never runs a `cmux-cua` helper (2026-10-29: one per chat).
#[test]
fn a_stored_list_answers_without_starting_the_server_until_a_call() {
    let dir = tempfile::tempdir().unwrap();
    let mut first = upstream_server("cmux-cua").with_listings(Some(dir.path().into()));
    let listed = first.descriptors(&BTreeSet::new());
    assert!(first.started(), "with nothing stored, listing starts the server");
    assert_eq!(listed.len(), 3);
    drop(first);
    let mut second = upstream_server("cmux-cua").with_listings(Some(dir.path().into()));
    assert_eq!(second.descriptors(&BTreeSet::new()), listed, "the stored list, rules included");
    assert!(!second.started(), "a stored list starts nothing");
    let result = second.call("look", json!({"at": 1}), None).unwrap();
    assert!(second.started(), "the first call starts it");
    assert_eq!(result["content"][0]["text"], "saw {\"at\": 1}");
}

/// A tool the stored list has but the started server no longer lists is
/// refused before it is sent, as not run.
#[test]
fn a_stored_tool_the_server_dropped_is_not_sent() {
    let dir = tempfile::tempdir().unwrap();
    let mut first = upstream_server("cmux-secrets").with_listings(Some(dir.path().into()));
    first.descriptors(&BTreeSet::new());
    drop(first);
    // Add a tool to the stored list that the server does not have.
    for entry in std::fs::read_dir(dir.path()).unwrap().filter_map(Result::ok) {
        let mut stored: Value =
            serde_json::from_slice(&std::fs::read(entry.path()).unwrap()).unwrap();
        stored["tools"]
            .as_array_mut()
            .unwrap()
            .push(json!({"name": "gone", "inputSchema": {"type": "object"}}));
        std::fs::write(entry.path(), stored.to_string()).unwrap();
    }
    let mut server = code_mode_server(Fake::with_actions());
    server.upstreams = vec![upstream::Proxied::new(
        upstream_server("cmux-secrets").with_listings(Some(dir.path().into())),
    )];
    let job = server.proxied_tool("secrets_gone", &Map::new()).expect("the stored list has it");
    let result = job.run(None);
    assert_eq!(result["isError"], true, "{result}");
    assert!(result.to_string().contains("no longer lists"), "{result}");
}
