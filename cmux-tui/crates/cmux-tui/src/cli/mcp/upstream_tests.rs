//! `cmux mcp serve` with the chat's other MCP servers behind it
//! (`upstream.rs`), against a real child server process.

use super::*;

/// A stdio MCP server like acpmux's secret and offer servers:
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
            {"name": "hold", "description": "Waits for a file", "inputSchema": {"type": "object"}},
            {"name": "meta", "description": "Echoes the call's _meta", "inputSchema": {"type": "object"}}]}
    elif method == "tools/call" and m["params"]["name"] == "meta":
        result = {"content": [{"type": "text", "text": json.dumps(m["params"].get("_meta"))}]}
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
    server.upstreams = vec![upstream::Proxied::new(upstream_server("cmux-probe"))];
    // The other server's tools are in the list under its prefix, and the
    // index carries its own instructions.
    let listed =
        server.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    let families = exec_families(&listed["result"]["tools"][0]);
    assert!(families.iter().any(|family| family == "probe"), "{families:?}");
    // Listed directly (every tool), each carries its server's rules.
    let all = server.list();
    let look = all.iter().find(|t| t["name"] == "probe_look").expect("probe_look is listed");
    assert!(look["description"].as_str().unwrap().contains("Ask before you click."), "{look}");
    let index = call(&mut server, "cmux_docs", json!({}));
    assert_eq!(
        index["structuredContent"]["families"]["probe"],
        json!(["probe_look", "probe_fail", "probe_hold", "probe_meta"])
    );
    // The server's own instructions.
    let rules = "Ask before you click.";
    assert_eq!(index["structuredContent"]["servers"]["cmux-probe"], rules);
    // A search that finds its tools carries the rules too; one that does not, none.
    let found = call(&mut server, "cmux_docs", json!({"query": "look screen"}));
    assert_eq!(found["structuredContent"]["tools"][0]["name"], "probe_look", "{found}");
    assert_eq!(found["structuredContent"]["servers"]["cmux-probe"], rules);
    let other = call(&mut server, "cmux_docs", json!({"query": "workspace rename"}));
    assert!(other["structuredContent"].get("servers").is_none(), "{other}");
    // Search matches what a tool does, not the rules its server shares with every tool (they
    // name terminals and passwords).
    let rules_only = call(&mut server, "cmux_docs", json!({"query": "terminal password"}));
    let content = &rules_only["structuredContent"];
    let names =
        content["tools"].as_array().into_iter().flatten().filter_map(|tool| tool["name"].as_str());
    let more = content["more"].as_array().into_iter().flatten().filter_map(Value::as_str);
    assert!(!names.chain(more).any(|name| name.starts_with("probe_")), "{rules_only}");

    // A script calls it like any tool; the screenshot comes back as an image
    // block of the cmux_exec result, the script sees its index.
    let script = r#"
        const seen = await cmux.probe_look({x: 1});
        let failed;
        try { await cmux.probe_fail({}); } catch (e) { failed = e.message; }
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
    let refused = call(&mut server, "cmux_exec", json!({"script": "await cmux.probe_look({});"}));
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
/// text listed only cu_*, secrets_* and sessions_*, so an agent looked for
/// sub-session tools under the offer server's prefix.
#[test]
fn code_mode_instructions_name_every_folded_servers_prefix() {
    let text = code_mode::INSTRUCTIONS;
    assert!(text.contains(&format!("{}_*", acpmux::computer_use::tools::TOOL_PREFIX)), "{text}");
    for server in [
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
        "Decide, say why",
        "never widens",
        "product taste",
    ] {
        assert!(rule.contains(phrase), "{phrase}: {rule}");
    }
    for code_mode in [false, true] {
        let init = initialize(&json!({}), false, code_mode);
        let text = init["instructions"].as_str().unwrap();
        assert!(text.contains(rule), "code mode {code_mode}: {text}");
        if code_mode {
            // cmux_exec's description, always loaded, says each of these once.
            for repeated in ["This chat runs in cmux", "acpmux_wrap_up", "sessions_offer_session"] {
                assert!(!text.contains(repeated), "{repeated}: {text}");
            }
        }
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

/// A chat asked to "open Calculator" found no computer use in its one tool
/// and drove the app with osascript keystrokes, which macOS blocked
/// (2026-10-27). `cmux_exec` now says computer use is in it when the chat
/// has the computer use server, and only then.
#[test]
fn cmux_exec_says_it_includes_computer_use_only_when_the_chat_has_it() {
    let mut server = code_mode_server(Fake::with_actions());
    server.upstreams = vec![upstream::Proxied::new(computer_use_server())];
    let listed =
        server.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    let with = listed["result"]["tools"][0]["description"].as_str().unwrap().to_owned();
    for phrase in [
        "cmux Computer Use, built into cmux",
        "nothing to install",
        "prefer it over any other computer-use driver",
        "cu_*",
        "other machines",
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

/// The Computer Use server as acpmux folds it, with a command that cannot
/// start: listing must never need it.
fn computer_use_server() -> upstream::Upstream {
    let specs = upstream::specs(Some(
        json!([{"name": acpmux::computer_use::tools::SERVER_NAME,
                "command": "/nonexistent/acpmux", "args": ["computer-use-mcp"], "env": {}}])
        .to_string()
        .into(),
    ));
    upstream::Upstream::new(specs.into_iter().next().unwrap()).with_listings(None)
}

/// The Computer Use tools fold as `cu_*` from the catalog compiled into this
/// binary, with the server's instructions on each, without starting the
/// bridge: the list is stable whether or not anything runs.
#[test]
fn computer_use_folds_as_cu_from_the_compiled_catalog() {
    let mut cu = computer_use_server();
    let listed = cu.descriptors(&BTreeSet::new());
    assert!(!cu.started(), "listing Computer Use starts nothing");
    let names: Vec<&str> = listed.iter().filter_map(|t| t["name"].as_str()).collect();
    let catalog = acpmux::computer_use::tools::mcp_list();
    let want: Vec<String> = catalog["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| format!("cu_{}", t["name"].as_str().unwrap()))
        .collect();
    assert_eq!(names, want);
    for name in ["cu_screenshot", "cu_click", "cu_list_machines", "cu_status"] {
        assert!(names.contains(&name), "{name}: {names:?}");
    }
    let text = listed[0]["description"].as_str().unwrap();
    assert!(text.ends_with(acpmux::computer_use::tools::INSTRUCTIONS), "{text}");
    // A call that cannot reach the bridge says so, as not run, and is retryable.
    let mut server = code_mode_server(Fake::with_actions());
    server.code_mode = false;
    server.upstreams = vec![upstream::Proxied::new(computer_use_server())];
    let result = call(&mut server, "cu_status", json!({}));
    assert_eq!(result["isError"], true, "{result}");
    assert!(result.to_string().contains("not_run"), "{result}");
}

/// A chat's `cmux` server lists another server's tools from the list an
/// earlier start stored, and starts that server only on its first call: an
/// idle chat never runs its other servers (2026-10-29: one helper per chat).
#[test]
fn a_stored_list_answers_without_starting_the_server_until_a_call() {
    let dir = tempfile::tempdir().unwrap();
    let mut first = upstream_server("cmux-probe").with_listings(Some(dir.path().into()));
    let listed = first.descriptors(&BTreeSet::new());
    assert!(first.started(), "with nothing stored, listing starts the server");
    // look, fail, hold and meta: every tool the fake server lists.
    assert_eq!(listed.len(), 4);
    drop(first);
    let mut second = upstream_server("cmux-probe").with_listings(Some(dir.path().into()));
    assert_eq!(second.descriptors(&BTreeSet::new()), listed, "the stored list, rules included");
    assert!(!second.started(), "a stored list starts nothing");
    let result = second.call("look", json!({"at": 1}), None, None).unwrap();
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

/// The tool use id Claude Code names a call by (`_meta["claudecode/toolUseId"]`) reaches the
/// server behind cmux, for a call of its tool and for each call a `cmux_exec` script makes: its
/// PreToolUse hook recorded which subagent made that call, and acpmux's server reads it there
/// (W5-M, 2026-11-08: a subagent's `cmux.acpmux_bg_start` and its lane reports went to the lead).
/// Nothing else of the call's `_meta` (its progress token) goes on.
#[test]
fn subagent_mcp_a_proxied_call_passes_on_the_tool_use_id_its_caller_was_named_by() {
    let echoed = |result: &Value| -> Value {
        serde_json::from_str(result["content"][0]["text"].as_str().unwrap_or("null")).unwrap()
    };
    let meta = json!({"claudecode/toolUseId": "toolu_01direct", "progressToken": 3});
    let request = |name: &str, arguments: Value| {
        json!({"jsonrpc": "2.0", "id": "m", "method": "tools/call",
               "params": {"name": name, "arguments": arguments, "_meta": meta}})
    };
    let mut server = Server::new(Fake::with_actions(), None);
    server.upstreams = vec![upstream::Proxied::new(upstream_server("cmux-probe"))];
    let direct = server.handle(&request("probe_meta", json!({}))).unwrap();
    assert_eq!(
        echoed(&direct["result"]),
        json!({"claudecode/toolUseId": "toolu_01direct"}),
        "{direct}"
    );
    // A call with no tool use id passes on no `_meta`.
    let plain = call(&mut server, "probe_meta", json!({}));
    assert_eq!(echoed(&plain), Value::Null, "{plain}");

    let mut server = code_mode_server(Fake::with_actions());
    server.upstreams = vec![upstream::Proxied::new(upstream_server("cmux-probe"))];
    let script =
        "const a = await cmux.probe_meta({}); const b = await cmux.probe_meta({}); return [a, b];";
    let ran = server.handle(&request("cmux_exec", json!({"script": script}))).unwrap();
    // A script reads a call's JSON text as its value.
    let passed = json!({"claudecode/toolUseId": "toolu_01direct"});
    assert_eq!(ran["result"]["structuredContent"]["result"], json!([passed, passed]), "{ran}");
    // The next script, with none, passes on none.
    let none = "const r = await cmux.probe_meta({}); return {r};";
    let ran = call(&mut server, "cmux_exec", json!({"script": none}));
    assert_eq!(ran["structuredContent"]["result"], json!({"r": null}), "{ran}");
}

/// One process for the servers whose specs name the same `shared` launch (acpmux's own five,
/// `acpmux tools-mcp`): each request names its server in `_meta`, each server lists and calls
/// its own tools there, and a call that waits on one server holds no other server's call.
#[cfg(unix)]
#[test]
fn servers_with_one_shared_launch_run_in_one_process() {
    const SHARED_SERVER: &str = r#"
import json, os, sys, threading
with open(os.environ["STARTS"], "a") as f:
    f.write("%d\n" % os.getpid())
lock = threading.Lock()
def say(m):
    with lock:
        print(json.dumps(m), flush=True)
def answer(m):
    server = ((m.get("params") or {}).get("_meta") or {}).get("cmux/server")
    method, rid = m["method"], m["id"]
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                  "serverInfo": {"name": server}, "instructions": "rules of " + server}
    elif method == "tools/list":
        result = {"tools": [{"name": "who", "description": "of " + server, "inputSchema": {"type": "object"}},
                            {"name": "hold", "description": "waits", "inputSchema": {"type": "object"}}]}
    elif m["params"]["name"] == "hold":
        import time
        while not os.path.exists(m["params"]["arguments"]["path"]):
            time.sleep(0.02)
        result = {"content": [{"type": "text", "text": "held"}]}
    else:
        result = {"content": [{"type": "text", "text": server}]}
    say({"jsonrpc": "2.0", "id": rid, "result": result})
for line in sys.stdin:
    m = json.loads(line)
    if "id" in m:
        threading.Thread(target=answer, args=(m,)).start()
"#;
    let dir = std::env::temp_dir().join(format!("cmux-mcp-shared-{}", uuid_like()));
    std::fs::create_dir_all(&dir).unwrap();
    let script = dir.join("shared.py");
    std::fs::write(&script, SHARED_SERVER).unwrap();
    let starts = dir.join("starts");
    let shared = json!({"command": "python3", "args": [script], "env": {"STARTS": starts}});
    let specs = upstream::specs(Some(
        json!([
            {"name": "cmux-forum", "command": "/unused", "args": ["forum-mcp"], "env": {}, "shared": shared},
            {"name": "acpmux", "command": "/unused", "args": ["acpmux-mcp"], "env": {}, "shared": shared},
        ])
        .to_string()
        .into(),
    ));
    assert_eq!(specs.len(), 2);
    assert!(specs.iter().all(|s| s.shared.is_some()));
    let mut ups: Vec<upstream::Upstream> =
        specs.into_iter().map(|s| upstream::Upstream::new(s).with_listings(None)).collect();
    let forum = ups[0].descriptors(&BTreeSet::new());
    let acpmux = ups[1].descriptors(&BTreeSet::new());
    // Each server's own tools under its own prefix, with its own rules.
    let names = |tools: &[Value]| -> Vec<String> {
        tools.iter().map(|t| t["name"].as_str().unwrap().to_owned()).collect()
    };
    assert_eq!(names(&forum), ["forum_who", "forum_hold"]);
    assert_eq!(names(&acpmux), ["acpmux_who", "acpmux_hold"]);
    assert!(forum[0]["description"].as_str().unwrap().contains("rules of cmux-forum"));
    assert!(acpmux[0]["description"].as_str().unwrap().contains("rules of acpmux"));
    // One process for both.
    let started = std::fs::read_to_string(&starts).unwrap();
    assert_eq!(started.lines().count(), 1, "{started}");
    // A call that waits on one server holds no call of the other.
    let gate = dir.join("go");
    let (forum, acpmux) = (ups.remove(0), ups.remove(0));
    let held = std::thread::spawn({
        let gate = gate.clone();
        move || {
            let mut forum = forum;
            forum.call("hold", json!({"path": gate}), None, None).map(|_| forum)
        }
    });
    let mut acpmux = acpmux;
    let who = acpmux.call("who", json!({}), None, None).unwrap();
    assert_eq!(who["content"][0]["text"], "acpmux", "{who}");
    std::fs::write(&gate, b"").unwrap();
    let forum = held.join().unwrap().unwrap();
    drop(forum);
    // The process stays while a server holds it.
    let mut acpmux = acpmux;
    assert_eq!(acpmux.call("who", json!({}), None, None).unwrap()["content"][0]["text"], "acpmux");
    assert_eq!(std::fs::read_to_string(&starts).unwrap().lines().count(), 1);
    let _ = std::fs::remove_dir_all(&dir);
}

fn uuid_like() -> String {
    let nanos =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    format!("{}-{nanos}", std::process::id())
}

/// Whether `pid` has exited: not in the process table, or there only as a zombie or exiting
/// (`ps` state `Z`, `X`, macOS `E`), so a probe never counts an unreaped child as running
/// (the same reading as acpmux's `durable_agents.rs`).
#[cfg(unix)]
fn process_gone(pid: u32) -> bool {
    let Ok(out) =
        std::process::Command::new("ps").args(["-o", "stat=", "-p", &pid.to_string()]).output()
    else {
        return false;
    };
    let stat = String::from_utf8_lossy(&out.stdout);
    let stat = stat.trim();
    stat.is_empty()
        || stat.starts_with('Z')
        || stat.starts_with('X')
        || (cfg!(target_os = "macos") && stat.contains('E'))
}

/// Whether `pid` exits within `within`.
#[cfg(unix)]
fn gone_within(pid: u32, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    while !process_gone(pid) {
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    true
}

/// A harness keeps an idle chat's `cmux mcp serve` running for days, and that kept its
/// computer use proxy running too: 15 `cmux-cua mcp` proxies on Leo's Mac (2026-11-14), each
/// under a live serve no one called. A server with no call for `IDLE_STOP` ends now; its tools
/// stay listed, and the next call starts it again.
#[cfg(unix)]
#[test]
fn an_idle_servers_process_ends_and_the_next_call_starts_it_again() {
    const IDLE: Duration = Duration::from_millis(300);
    let mut servers: Vec<_> = (0..3).map(|_| upstream_server("cmux-cua")).collect();
    for server in &mut servers {
        assert_eq!(server.descriptors(&BTreeSet::new()).len(), 4, "listing starts it");
    }
    let pids: Vec<u32> = servers.iter().map(|s| s.pid().expect("started")).collect();
    let running = |pids: &[u32]| pids.iter().filter(|pid| !process_gone(**pid)).count();
    let before = running(&pids);
    assert_eq!(before, 3);
    let servers: Vec<_> =
        servers.into_iter().map(|s| std::sync::Arc::new(std::sync::Mutex::new(s))).collect();
    let watcher =
        upstream::stop_idle(servers.iter().map(std::sync::Arc::downgrade).collect(), IDLE).unwrap();
    for pid in &pids {
        assert!(gone_within(*pid, Duration::from_secs(10)), "idle server {pid} still runs");
    }
    let after = running(&pids);
    eprintln!("idle proxies running: before {before}, after {after}");
    assert_eq!(after, 0);
    // Still listed, and a call starts a new process.
    let mut first = servers[0].lock().unwrap();
    assert!(!first.started());
    assert_eq!(first.descriptors(&BTreeSet::new()).len(), 4, "its tools stay listed");
    assert!(!first.started(), "listing an idle server starts nothing");
    let result = first.call("look", json!({"at": 2}), None, None).unwrap();
    assert_eq!(result["content"][0]["text"], "saw {\"at\": 2}");
    let restarted = first.pid().unwrap();
    assert!(!pids.contains(&restarted));
    drop(first);
    // The watcher ends once every server is gone, and takes the restarted one's process along
    // when that is idle again.
    assert!(
        gone_within(restarted, Duration::from_secs(10)),
        "the restarted server never idled out"
    );
    drop(servers);
    let start = Instant::now();
    while !watcher.is_finished() {
        assert!(start.elapsed() < Duration::from_secs(10), "the idle watcher outlived its servers");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// A server a call holds is never ended for idling, however long the call takes.
#[cfg(unix)]
#[test]
fn a_server_in_a_call_is_never_ended_as_idle() {
    let dir = tempfile::tempdir().unwrap();
    let gate = dir.path().join("go");
    let mut server = upstream_server("cmux-cua");
    server.descriptors(&BTreeSet::new());
    let pid = server.pid().unwrap();
    let server = std::sync::Arc::new(std::sync::Mutex::new(server));
    let _watcher =
        upstream::stop_idle(vec![std::sync::Arc::downgrade(&server)], Duration::from_millis(100))
            .unwrap();
    let held = std::thread::spawn({
        let (server, gate) = (server.clone(), gate.clone());
        move || server.lock().unwrap().call("hold", json!({"path": gate}), None, None)
    });
    std::thread::sleep(Duration::from_millis(600));
    assert!(!process_gone(pid), "a server in a call was ended as idle");
    std::fs::write(&gate, b"").unwrap();
    let result = held.join().unwrap().unwrap();
    assert_eq!(result["content"][0]["text"], "held");
    assert!(gone_within(pid, Duration::from_secs(10)), "idle after its call, it still runs");
    // Ended for idling, not by the server's drop: this test still holds it.
    assert!(!server.lock().unwrap().started());
}

/// What a loopback HTTP MCP server got: each request's headers (names in lower case) and body.
type HttpSeen = std::sync::Arc<std::sync::Mutex<Vec<(Vec<(String, String)>, Value)>>>;

/// A loopback streamable HTTP MCP server, as acpmux's daemon serves its own servers: it names a
/// session at `initialize`, lists `look` and `stream` (a chunked answer), answers `look` as one
/// JSON message and `stream` as an event stream with a progress notification first, and takes
/// a notification with 202. Each answer names the server `_meta` routed it to.
fn http_server() -> (String, HttpSeen) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/mcp/acpmux", listener.local_addr().unwrap());
    let seen = HttpSeen::default();
    let log = seen.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            let log = log.clone();
            std::thread::spawn(move || http_answer(stream, &log));
        }
    });
    (url, seen)
}

fn http_answer(mut stream: std::net::TcpStream, log: &HttpSeen) {
    use std::io::{BufRead, Read, Write};
    let mut reader = io::BufReader::new(stream.try_clone().unwrap());
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    assert!(line.starts_with("POST /mcp/acpmux HTTP/1.1"), "{line}");
    let mut headers = Vec::new();
    loop {
        line.clear();
        reader.read_line(&mut line).unwrap();
        let Some((name, value)) = line.trim_end().split_once(':') else { break };
        headers.push((name.trim().to_ascii_lowercase(), value.trim().to_owned()));
    }
    let length = headers.iter().find(|(k, _)| k == "content-length").unwrap().1.parse().unwrap();
    let mut body = vec![0; length];
    reader.read_exact(&mut body).unwrap();
    let message: Value = serde_json::from_slice(&body).unwrap();
    log.lock().unwrap().push((headers, message.clone()));
    let Some(id) = message.get("id").cloned() else {
        stream.write_all(b"HTTP/1.1 202 Accepted\r\ncontent-length: 0\r\n\r\n").unwrap();
        return;
    };
    let params = &message["params"];
    let server = params["_meta"]["cmux/server"].as_str().unwrap_or("nobody").to_owned();
    let reply = |result: Value| json!({"jsonrpc": "2.0", "id": id, "result": result}).to_string();
    let text = |text: String| json!({"content": [{"type": "text", "text": text}]});
    let json_answer = |body: String, extra: &str| {
        format!(
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n{extra}content-length: {}\r\n\r\n{body}",
            body.len()
        )
    };
    let answer = match (message["method"].as_str().unwrap(), params["name"].as_str()) {
        ("initialize", _) => json_answer(
            reply(json!({"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                "serverInfo": {"name": "acpmux"}, "instructions": format!("rules of {server}")})),
            "mcp-session-id: s-1\r\n",
        ),
        ("tools/list", _) => {
            let body = reply(json!({"tools": [
                {"name": "look", "description": "Looks", "inputSchema": {"type": "object"}},
                {"name": "stream", "description": "Streams", "inputSchema": {"type": "object"}}]}));
            let (a, b) = body.split_at(body.len() / 2);
            format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ntransfer-encoding: chunked\r\n\r\n\
                 {:x}\r\n{a}\r\n{:x}\r\n{b}\r\n0\r\n\r\n",
                a.len(),
                b.len()
            )
        }
        ("tools/call", Some("stream")) => {
            let note = json!({"jsonrpc": "2.0", "method": "notifications/progress",
                "params": {"progressToken": 1, "progress": 1}});
            let body = reply(text(format!("streamed by {server}")));
            // No length: the stream ends when the server closes it.
            format!(
                "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n\
                 event: message\r\ndata: {note}\r\n\r\nevent: message\r\ndata: {body}\r\n\r\n"
            )
        }
        ("tools/call", _) => {
            json_answer(reply(text(format!("{server} saw {}", params["arguments"]))), "")
        }
        _ => json_answer(
            json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "no"}})
                .to_string(),
            "",
        ),
    };
    stream.write_all(answer.as_bytes()).unwrap();
}

fn http_upstream(name: &str, url: &str) -> upstream::Upstream {
    let specs = upstream::specs(Some(
        json!([{"name": name, "command": "/unused", "args": ["acpmux-mcp"], "env": {},
                "http": {"url": url, "headers": {"Authorization": "Bearer t0k"}}}])
        .to_string()
        .into(),
    ));
    upstream::Upstream::new(specs.into_iter().next().unwrap()).with_listings(None)
}

/// A spec with `http` (acpmux's daemon serving its servers over loopback HTTP) needs no process:
/// its tools list and run over POSTs, with the spec's headers, the server's session and the
/// server's name in `_meta` (the daemon routes by it), whether the answer is JSON or a stream.
#[test]
fn an_http_upstream_lists_and_calls_its_tools_with_no_process() {
    let (url, seen) = http_server();
    let mut server = http_upstream("acpmux", &url);
    let tools = server.descriptors(&BTreeSet::new());
    let names: Vec<&str> = tools.iter().filter_map(|t| t["name"].as_str()).collect();
    assert_eq!(names, ["acpmux_look", "acpmux_stream"]);
    assert!(tools[0]["description"].as_str().unwrap().contains("rules of acpmux"), "{tools:?}");
    let looked = server.call("look", json!({"at": 1}), None, None).unwrap();
    assert_eq!(looked["content"][0]["text"], r#"acpmux saw {"at":1}"#, "{looked}");
    let streamed = server.call("stream", json!({}), None, None).unwrap();
    assert_eq!(streamed["content"][0]["text"], "streamed by acpmux", "{streamed}");
    // No process, so nothing to end when idle.
    assert_eq!(server.pid(), None);
    assert_eq!(server.stop_if_idle(Duration::ZERO), None);
    assert!(server.started());

    let seen = seen.lock().unwrap();
    let methods: Vec<&str> = seen.iter().filter_map(|(_, m)| m["method"].as_str()).collect();
    assert_eq!(
        methods,
        ["initialize", "notifications/initialized", "tools/list", "tools/call", "tools/call"]
    );
    for (at, (headers, message)) in seen.iter().enumerate() {
        let header = |name: &str| {
            headers.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str()).unwrap_or_default()
        };
        assert_eq!(header("authorization"), "Bearer t0k", "{message}");
        assert_eq!(header("content-type"), "application/json", "{message}");
        assert_eq!(header("accept"), "application/json, text/event-stream", "{message}");
        // The session the server named at `initialize` goes back on every later request.
        assert_eq!(header("mcp-session-id"), if at == 0 { "" } else { "s-1" }, "{message}");
        if message.get("id").is_some() {
            assert_eq!(message["params"]["_meta"]["cmux/server"], "acpmux", "{message}");
        }
    }
}

/// An HTTP upstream is loopback only: the spec's headers carry a token. A url anywhere else is
/// never connected to, and a loopback server that is down is a failed start.
#[test]
fn an_http_upstream_off_loopback_is_refused() {
    for url in [
        "http://10.0.0.1:8080/mcp",
        "http://example.com/mcp",
        "https://127.0.0.1:8080/mcp",
        "http://user@127.0.0.1:8080/mcp",
        "http://127.0.0.1.example.com/mcp",
        "http://::1/mcp",
        "http://127.0.0.1:notaport/mcp",
    ] {
        let error = upstream::upstream_http::endpoint(url).expect_err(url);
        assert!(error.contains("loopback"), "{url}: {error}");
        let mut server = http_upstream("acpmux", url);
        assert!(server.descriptors(&BTreeSet::new()).is_empty(), "{url}");
        let error = server.connect().expect_err(url);
        assert!(error.contains("loopback"), "{url}: {error}");
    }
    for url in ["http://127.0.0.1:9/mcp", "http://localhost:9/mcp/x?y=1", "http://[::1]:9/mcp"] {
        assert!(upstream::upstream_http::endpoint(url).is_ok(), "{url}");
    }
    // Loopback, but nothing listens there.
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let mut server = http_upstream("acpmux", &format!("http://127.0.0.1:{port}/mcp"));
    assert!(server.descriptors(&BTreeSet::new()).is_empty());
    let error = server.connect().expect_err("nothing listens");
    assert!(error.contains("cannot reach"), "{error}");
}
