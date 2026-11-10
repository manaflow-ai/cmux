//! cmux Computer Use through the `cmux` server: scripted in `cmux_exec`
//! (`cu.*`), served alone to a terminal agent while the cmux tools are off,
//! and second choice for Codex. The Computer Use bridge is replaced by a
//! child process that serves the compiled catalog and logs every call.

use super::*;

/// A stand-in for `cmux computer-use mcp`: the catalog in `CU_CATALOG`, one
/// form window whose Next button must be clicked three times before Done
/// shows, every `tools/call` logged as one JSON line in `CU_LOG`.
const FAKE_WORKER: &str = r#"
import json, os, sys
state = {"clicks": 0, "email": ""}
def text(value, image=None, error=False):
    content = [{"type": "text", "text": json.dumps(value)}]
    if image:
        content.append({"type": "image", "data": image, "mimeType": "image/png"})
    return {"content": content, "isError": error}
def tree():
    children = [{"id": "e1", "role": "text_field", "name": "Email", "value": state["email"]},
                {"id": "t1", "role": "text", "name": "Total", "value": "42"}]
    if state["clicks"] < 3:
        children.append({"id": "b1", "role": "button", "name": "Next"})
    else:
        children.append({"id": "d1", "role": "text", "name": "Done"})
    return {"window_id": "w1", "root": {"id": "r", "role": "window", "children": [
        {"id": "g", "role": "group", "children": children}]}}
for line in sys.stdin:
    m = json.loads(line)
    if "id" not in m:
        continue
    method, rid = m["method"], m["id"]
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                  "serverInfo": {"name": "cmux-computer-use"}, "instructions": "bridge rules"}
    elif method == "tools/list":
        result = json.loads(os.environ["CU_CATALOG"])
    elif method == "tools/call":
        name, args = m["params"]["name"], m["params"].get("arguments", {})
        with open(os.environ["CU_LOG"], "a") as log:
            log.write(json.dumps({"name": name, "arguments": args}) + "\n")
        if name == "list_windows":
            result = text({"windows": [{"window_id": "w1", "app_id": "com.example.form", "title": "Sign up"}]})
        elif name == "get_ui_tree":
            result = text(tree())
        elif name == "set_value":
            state["email"] = args["value"]
            result = text({"ok": True})
        elif name == "click":
            state["clicks"] += 1
            if args.get("observe", True):
                result = text({"ok": True, "state": {"window_id": "w1", "clicks": state["clicks"]}}, "c3RhdGU=")
            else:
                result = text({"ok": True})
        elif name == "wait":
            result = text({"window_id": "w1", "waited": args.get("ms")}, "d2FpdA==")
        elif name == "screenshot":
            result = text({"window_id": "w1", "width": 800}, "c2hvdA==")
        elif name == "perform_action":
            result = text({"error": "com.example.form is on the deny list", "code": "app_denied"}, error=True)
        else:
            result = text({"ok": True})
    else:
        print(json.dumps({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "no"}}), flush=True)
        continue
    print(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}), flush=True)
"#;

/// The fake worker as acpmux folds Computer Use (`cmux-computer-use`), with
/// its call log at `log`.
fn fake_worker(log: &std::path::Path) -> upstream::Proxied {
    static SCRIPT: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    let script = SCRIPT.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("cmux-mcp-cu-fake-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("worker.py");
        std::fs::write(&script, FAKE_WORKER).unwrap();
        script
    });
    let catalog = acpmux::computer_use::tools::mcp_list().to_string();
    let specs = upstream::specs(Some(
        json!([{"name": acpmux::computer_use::tools::SERVER_NAME, "command": "python3",
                "args": [script], "env": {"CU_LOG": log, "CU_CATALOG": catalog}}])
        .to_string()
        .into(),
    ));
    let spec = specs.into_iter().next().unwrap();
    upstream::Proxied::new(upstream::Upstream::new(spec).with_listings(None))
}

/// The calls the fake worker got, in order.
fn logged(log: &std::path::Path) -> Vec<Value> {
    std::fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

fn image_blocks(result: &Value) -> Vec<Value> {
    result["content"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|block| block["type"] == "image")
        .cloned()
        .collect()
}

/// One `cmux_exec` call fills a form, clicks Next until Done shows, reads a
/// value, meets a refusal and returns one screenshot: every step is its own
/// worker call through `Server::call`, acting calls skip their settle
/// screenshot unless the script asks, and only the returned image reaches
/// the agent.
#[test]
fn one_script_drives_a_multi_step_computer_use_task() {
    let dir = tempfile::tempdir().unwrap();
    let log = dir.path().join("calls.jsonl");
    let mut server = code_mode_server(Fake::with_actions());
    server.upstreams = vec![fake_worker(&log)];
    let script = r#"
        const [w] = (await cu.listWindows({})).windows;
        const window_id = w.window_id;
        let t = await cu.get_ui_tree({window_id});
        await cu.set_value({window_id, value: "ada@example.com",
          element_id: cu.find(t, {role: "text_field", name: /email/i}).id});
        let pages = 0;
        while (!cu.find(t, {name: "Done"})) {
          await cu.click({window_id, element_id: cu.find(t, {role: "button", name: "Next"}).id});
          await cu.wait({window_id, ms: 10});
          t = await cu.get_ui_tree({window_id});
          pages++;
        }
        const observed = await cmux.call("cu_click", {window_id, element_id: "d1", observe: true});
        let refused;
        try {
          await cu.perform_action({window_id, element_id: "d1", action: "press"});
        } catch (e) {
          refused = {message: e.message, code: e.cmux.error.code};
        }
        const shot = await cu.screenshot({window_id});
        return {
          pages,
          email: cu.find(t, {role: "text_field"}).value,
          total: cu.find(t, {role: "text", name: "Total"}).value,
          texts: cu.findAll(t, {role: "text"}).length,
          clicks: observed.state.clicks,
          refused,
          shot,
        };
    "#;
    let ran = call(&mut server, "cmux_exec", json!({"script": script}));
    assert_eq!(ran["isError"], false, "{ran}");
    let result = &ran["structuredContent"]["result"];
    assert_eq!(result["pages"], 3, "{ran}");
    assert_eq!(result["email"], "ada@example.com");
    assert_eq!(result["total"], "42");
    assert_eq!(result["texts"], 2);
    assert_eq!(result["clicks"], 4);
    assert_eq!(result["refused"]["code"], "app_denied", "{ran}");
    assert!(result["refused"]["message"].as_str().unwrap().contains("deny list"), "{ran}");
    // A screenshot result is its JSON with its image as a placeholder.
    assert_eq!(result["shot"]["window_id"], "w1");
    assert_eq!(result["shot"]["width"], 800);
    let placeholder = &result["shot"]["images"][0];
    assert_eq!(placeholder["type"], "image");
    assert!(placeholder["image"].is_u64(), "{placeholder}");
    // Only the returned screenshot comes back: not the waits' or the observed click's.
    assert_eq!(
        image_blocks(&ran),
        [json!({"type": "image", "data": "c2hvdA==", "mimeType": "image/png"})],
        "{ran}"
    );

    // Every call is its own worker call, in order (the bridge gives each its own call id).
    let calls = logged(&log);
    let names: Vec<&str> = calls.iter().map(|c| c["name"].as_str().unwrap()).collect();
    let mut want = vec!["list_windows", "get_ui_tree", "set_value"];
    for _ in 0..3 {
        want.extend(["click", "wait", "get_ui_tree"]);
    }
    want.extend(["click", "perform_action", "screenshot"]);
    assert_eq!(names, want);
    assert_eq!(ran["structuredContent"]["calls"], want.len());
    // Acting calls default to observe: false in a script; an explicit observe stays.
    for (index, call) in calls.iter().enumerate() {
        let observe = &call["arguments"]["observe"];
        match (call["name"].as_str().unwrap(), index) {
            ("click", 12) => assert_eq!(observe, &json!(true), "{call}"),
            ("click" | "set_value" | "perform_action", _) => {
                assert_eq!(observe, &json!(false), "{call}");
            }
            _ => assert!(observe.is_null(), "a reading call gets no observe: {call}"),
        }
    }
}

/// A Claude Code or Codex in a cmux terminal while cmux's MCP tools are off
/// gets only Computer Use from its `cmux` server: the cu_* tools, scriptable
/// in cmux_exec, and a refusal for every other cmux tool.
#[test]
fn a_terminal_agent_with_the_cmux_tools_off_gets_only_computer_use() {
    let dir = tempfile::tempdir().unwrap();
    let log = dir.path().join("calls.jsonl");
    let mut server = code_mode_server(Fake::with_actions());
    server.computer_use_only = true;
    server.upstreams = vec![fake_worker(&log)];
    let init = server
        .handle(&json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"clientInfo": {"name": "claude-code"}}}))
        .unwrap();
    let instructions = init["result"]["instructions"].as_str().unwrap();
    assert!(instructions.starts_with(acpmux::computer_use::tools::INSTRUCTIONS), "{instructions}");
    assert!(instructions.contains("cu.click"), "{instructions}");

    let listed =
        server.handle(&json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})).unwrap();
    let exposed = listed["result"]["tools"].as_array().unwrap();
    assert_eq!(exposed.len(), 1, "{listed}");
    assert_eq!(exposed[0]["name"], "cmux_exec");
    let description = exposed[0]["description"].as_str().unwrap();
    assert!(description.contains("cu.click"), "{description}");
    assert!(!description.contains("workspace_list"), "{description}");
    let all = server.list();
    assert!(!all.is_empty());
    assert!(all.iter().all(|t| t["name"].as_str().unwrap().starts_with("cu_")), "{all:?}");
    assert!(server.backend.sent.borrow().is_empty(), "no app or daemon call to list");

    let refused =
        call(&mut server, "cmux_exec", json!({"script": "await cmux.workspace_list({});"}));
    let error = &refused["structuredContent"]["error"]["cmux"]["error"];
    assert_eq!(error["code"], "tool.not_allowed", "{refused}");
    assert!(error["message"].as_str().unwrap().contains("mcp.enabled"), "{refused}");
    let direct = call(&mut server, "workspace_list", json!({}));
    assert_eq!(direct["structuredContent"]["error"]["code"], "tool.not_allowed", "{direct}");
    assert!(server.backend.sent.borrow().is_empty(), "nothing reached an owner");

    let ran = call(
        &mut server,
        "cmux_exec",
        json!({"script": "return (await cu.list_windows({})).windows.map((w) => w.title);"}),
    );
    assert_eq!(ran["structuredContent"]["result"], json!(["Sign up"]), "{ran}");
    // Listed directly (--all-tools), a cu_* tool is called as itself.
    server.code_mode = false;
    let direct = call(&mut server, "cu_list_windows", json!({}));
    assert_eq!(direct["isError"], false, "{direct}");
    assert_eq!(logged(&log).len(), 2);
}

/// `cmux.docs("cu")` answers the Computer Use tools, not every name with
/// "cu" in it, with the scripting guide and the server's rules once.
#[test]
fn docs_for_cu_answer_the_family_with_example_scripts() {
    let mut server = code_mode_server(Fake::with_actions());
    server.upstreams = vec![upstream::Proxied::new(unstartable_computer_use())];
    let docs = call(&mut server, "cmux_docs", json!({"query": "cu"}));
    let answer = &docs["structuredContent"];
    let names: Vec<&str> =
        answer["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
    assert_eq!(names.len(), acpmux::computer_use::tools::TOOLS.len(), "{answer}");
    assert!(names.iter().all(|name| name.starts_with("cu_")), "{names:?}");
    for tool in answer["tools"].as_array().unwrap() {
        let text = tool["description"].as_str().unwrap();
        assert!(!text.contains(acpmux::computer_use::tools::INSTRUCTIONS), "rules once: {text}");
    }
    assert_eq!(
        answer["servers"][acpmux::computer_use::tools::SERVER_NAME],
        acpmux::computer_use::tools::INSTRUCTIONS
    );
    let guide = answer["guides"][0]["text"].as_str().unwrap();
    for example in ["Fill and submit a form", "Click until a condition holds", "Read a value"] {
        assert!(guide.contains(example), "{example}: {guide}");
    }
}

/// Codex has its own Computer Use: through the `cmux` server too, the cu_*
/// tools and their rules say cmux's is the second choice; Claude Code keeps
/// cmux's first.
#[test]
fn codex_keeps_its_own_computer_use_first_through_the_cmux_server() {
    for (client, defer) in [("codex-mcp-client", true), ("claude-code", false)] {
        let mut server = code_mode_server(Fake::with_actions());
        server.upstreams = vec![upstream::Proxied::new(unstartable_computer_use())];
        server.handle(&json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                              "params": {"clientInfo": {"name": client}}}));
        let listed =
            server.handle(&json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})).unwrap();
        let exec = listed["result"]["tools"][0]["description"].as_str().unwrap();
        assert_eq!(exec.contains("a second option"), defer, "{client}: {exec}");
        assert_eq!(exec.contains("prefer it over any other computer-use driver"), !defer);
        let all = server.list();
        let click = all.iter().find(|t| t["name"] == "cu_click").unwrap();
        let text = click["description"].as_str().unwrap();
        assert_eq!(text.contains(acpmux::computer_use::mcp::DEFER_PREFIX), defer, "{text}");
        let rules = if defer {
            acpmux::computer_use::mcp::DEFER_INSTRUCTIONS
        } else {
            acpmux::computer_use::tools::INSTRUCTIONS
        };
        assert!(text.ends_with(rules), "{client}: {text}");
        let docs = call(&mut server, "cmux_docs", json!({"query": "cu"}));
        assert_eq!(
            docs["structuredContent"]["servers"][acpmux::computer_use::tools::SERVER_NAME],
            rules
        );
    }
}

/// The Computer Use server as acpmux folds it, with a command that cannot start.
fn unstartable_computer_use() -> upstream::Upstream {
    let specs = upstream::specs(Some(
        json!([{"name": acpmux::computer_use::tools::SERVER_NAME,
                "command": "/nonexistent/acpmux", "args": ["computer-use-mcp"], "env": {}}])
        .to_string()
        .into(),
    ));
    upstream::Upstream::new(specs.into_iter().next().unwrap()).with_listings(None)
}
