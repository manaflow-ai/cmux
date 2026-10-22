//! `cmux mcp serve` with the chat's other MCP servers behind it
//! (`upstream.rs`), against a real child server process.

use super::*;

/// A stdio MCP server like acpmux's computer use, secret and offer servers:
/// `look` answers text and a screenshot, `fail` answers an error.
const UPSTREAM_SERVER: &str = r#"
import json, os, sys
if os.environ.get("START_LOG"):
    with open(os.environ["START_LOG"], "a") as log:
        log.write("started\n")
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
    let dir = std::env::temp_dir().join(format!("cmux-mcp-upstream-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let script = dir.join("server.py");
    std::fs::write(&script, UPSTREAM_SERVER).unwrap();
    let specs = upstream::specs(Some(
        json!([{"name": name, "command": "python3", "args": [script], "env": {}}])
            .to_string()
            .into(),
    ));
    upstream::Upstream::new(specs.into_iter().next().unwrap())
}

/// A server run from `script` whose starts are logged to `log`, its last
/// list kept in `cache` when `keep_list`.
fn logged_server(
    script: &str,
    log: &std::path::Path,
    cache: &std::path::Path,
    keep_list: bool,
) -> upstream::Upstream {
    let file = log.with_file_name("server.py");
    std::fs::write(&file, script).unwrap();
    let specs = upstream::specs(Some(
        json!([{"name": "cmux-cua", "command": "python3", "args": [file],
                "env": {"START_LOG": log}, "keepList": keep_list}])
        .to_string()
        .into(),
    ));
    upstream::Upstream::new(specs.into_iter().next().unwrap()).with_listing_cache(cache.to_owned())
}

/// A test's own folder: its start log and its cache.
fn lazy_dir(test: &str) -> (std::path::PathBuf, std::path::PathBuf, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("cmux-mcp-{test}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    (dir.clone(), dir.join("starts.log"), dir.join("cache"))
}

fn starts(log: &std::path::Path) -> usize {
    std::fs::read_to_string(log).unwrap_or_default().lines().count()
}

/// The chat's other servers start on first use, not when a harness lists
/// the tools (ask-a3c16b28b7: every chat kept its computer use, secret,
/// offer, sub-session and forum servers running from launch). The first
/// chat starts each server once to learn its tools; later chats list them
/// from that and start a server only when a tool of its is called.
#[test]
fn listing_the_tools_starts_no_server_once_its_list_is_known() {
    let (dir, log, cache) = lazy_dir("lazy");

    // The first chat: nothing known yet, so listing starts the server.
    let mut first = code_mode_server(Fake::with_actions());
    let server = logged_server(UPSTREAM_SERVER, &log, &cache, true);
    first.upstreams = vec![upstream::Proxied::new(server)];
    assert!(first.list().iter().any(|t| t["name"] == "cua_look"));
    assert_eq!(starts(&log), 1);
    drop(first);

    // A later chat lists the same tools, with the server's rules, and
    // starts nothing.
    let mut later = code_mode_server(Fake::with_actions());
    let server = logged_server(UPSTREAM_SERVER, &log, &cache, true);
    later.upstreams = vec![upstream::Proxied::new(server)];
    let all = later.list();
    let look = all.iter().find(|t| t["name"] == "cua_look").expect("cua_look is listed");
    assert!(look["description"].as_str().unwrap().contains("Ask before you click."), "{look}");
    let index = call(&mut later, "cmux_docs", json!({}));
    assert_eq!(index["structuredContent"]["servers"]["cmux-cua"], "Ask before you click.");
    assert_eq!(starts(&log), 1, "listing started the server");

    // Its first call starts it and gets the server's own answer.
    let ran =
        call(&mut later, "cmux_exec", json!({"script": "return await cmux.cua_look({x: 2});"}));
    assert_eq!(ran["structuredContent"]["result"]["content"][0]["text"], "saw {\"x\": 2}", "{ran}");
    assert_eq!(starts(&log), 2);

    // A server whose spec does not say keepList (computer use forwards its
    // helper's list) starts to list, kept list or not.
    let mut unkept = logged_server(UPSTREAM_SERVER, &log, &cache, false);
    assert!(!unkept.descriptors(&BTreeSet::new()).is_empty());
    assert_eq!(starts(&log), 3);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A tool only the kept list names (the server dropped it since) does not
/// run: the start that would run it gets the server's own list, which
/// replaces the kept one and tells the client to list again.
#[test]
fn a_kept_tool_the_server_dropped_does_not_run() {
    let (dir, log, cache) = lazy_dir("dropped");
    logged_server(UPSTREAM_SERVER, &log, &cache, true).descriptors(&BTreeSet::new());
    let kept = std::fs::read_dir(&cache).unwrap().next().unwrap().unwrap().path();
    let mut listing: Value =
        serde_json::from_str(&std::fs::read_to_string(&kept).unwrap()).unwrap();
    listing["tools"].as_array_mut().unwrap().push(json!({"name": "gone", "inputSchema": {}}));
    std::fs::write(&kept, listing.to_string()).unwrap();

    let mut server = logged_server(UPSTREAM_SERVER, &log, &cache, true);
    let listed = server.descriptors(&BTreeSet::new());
    assert!(listed.iter().any(|t| t["name"] == "cua_gone"), "{listed:?}");
    let (message, state) = server.call("gone", json!({}), None).unwrap_err();
    assert!(message.contains("no longer lists gone"), "{message}");
    assert_eq!(state, "not_run");
    assert!(server.take_changed(), "the client lists again");
    assert!(!server.descriptors(&BTreeSet::new()).iter().any(|t| t["name"] == "cua_gone"));
    assert!(!std::fs::read_to_string(&kept).unwrap().contains("gone"), "the kept list is replaced");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A kept server that does not start is not started again on every call:
/// the same backoff as a list.
#[test]
fn a_kept_server_that_cannot_start_waits_before_starting_again() {
    let (dir, log, cache) = lazy_dir("broken");
    logged_server(UPSTREAM_SERVER, &log, &cache, true).descriptors(&BTreeSet::new());
    assert_eq!(starts(&log), 1);
    // The same server, broken since: it exits at once.
    let broken = "import os\nopen(os.environ['START_LOG'], 'a').write('started\\n')\n";
    let mut server = logged_server(broken, &log, &cache, true);
    assert!(!server.descriptors(&BTreeSet::new()).is_empty(), "listed from the kept list");
    for _ in 0..2 {
        let (_, state) = server.call("look", json!({}), None).unwrap_err();
        assert_eq!(state, "not_run");
    }
    assert_eq!(starts(&log), 2, "one start in the backoff");
    let _ = std::fs::remove_dir_all(&dir);
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
    assert_eq!(index["structuredContent"]["servers"]["cmux-cua"], "Ask before you click.");
    // A search that finds its tools carries the rules too; one that does not, none.
    let found = call(&mut server, "cmux_docs", json!({"query": "look screen"}));
    assert_eq!(found["structuredContent"]["tools"][0]["name"], "cua_look", "{found}");
    assert_eq!(found["structuredContent"]["servers"]["cmux-cua"], "Ask before you click.");
    let other = call(&mut server, "cmux_docs", json!({"query": "workspace rename"}));
    assert!(other["structuredContent"].get("servers").is_none(), "{other}");

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
