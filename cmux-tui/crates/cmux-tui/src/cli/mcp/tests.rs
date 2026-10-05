use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

use cmux_tui_core::resource::{OperationClass, ResourceOperation};
use serde_json::{Map, Value, json};

use super::super::app::{ActionName, AppCommand, run_action};
use super::super::command::{CommandPlan, ParsedCommand, RequestPlan};
use super::super::wire::request_value;
use super::transport::{CallFailure, FailureKind, Prefix};
use super::*;

const WORKSPACE: &str = "ws_0123456789abcdef0123456789abcdef";

/// Records what a tool call would send; answers like an empty session.
#[derive(Default)]
struct Fake {
    actions: Value,
    fail_resources: bool,
    sent: RefCell<Vec<Value>>,
}

impl Fake {
    fn with_actions() -> Self {
        Self { actions: fixture_actions(), ..Self::default() }
    }

    fn last(&self, kind: &str) -> Value {
        self.sent
            .borrow()
            .iter()
            .rev()
            .find(|sent| sent["kind"] == kind)
            .cloned()
            .unwrap_or_else(|| panic!("nothing sent to {kind}"))
    }
}

impl Backend for Fake {
    fn resource(
        &self,
        session: Option<&str>,
        plan: RequestPlan,
        prefixes: &[Prefix],
    ) -> Result<Value, CallFailure> {
        // The request exactly as `transport::resource` builds it.
        let request = request_value(&plan).expect("a valid request");
        let key = request.get("idempotency_key").and_then(Value::as_str).map(str::to_owned);
        self.sent.borrow_mut().push(json!({
            "kind": "resource",
            "session": session,
            "request": request,
            "prefixes": prefixes.len(),
        }));
        if self.fail_resources {
            return Err(CallFailure {
                kind: FailureKind::InProgress,
                error: json!({"code": "transport.failed", "message": "read timed out"}),
                idempotency_key: key,
            });
        }
        Ok(json!([]))
    }

    fn app(
        &self,
        method: &str,
        params: Value,
        _timeout: Duration,
        idempotency_key: Option<&str>,
    ) -> Result<Value, CallFailure> {
        self.sent.borrow_mut().push(json!({
            "kind": "app",
            "method": method,
            "params": params,
            "key": idempotency_key,
        }));
        match method {
            "action.list" => Ok(self.actions.clone()),
            "snapshot.get" => Ok(json!({"topology": {"windows": [{"id": "win_a"}]}})),
            _ => Ok(json!({"ran": true})),
        }
    }

    fn browser(
        &self,
        request: browser_tools::Request,
        mutation: bool,
    ) -> Result<Value, CallFailure> {
        self.sent.borrow_mut().push(json!({
            "kind": "browser",
            "method": request.method,
            "params": request.params,
            "timeout_ms": request.timeout.as_millis() as u64,
            "mutation": mutation,
        }));
        Ok(json!({"session": "default", "output": "ok\n", "truncated": false, "error": null}))
    }
}

/// The fixture names the app's surface plan key `PLAN`; this puts the real
/// key (`ACTION_SURFACE_PLAN`) in its place.
fn with_plan_key(mut value: Value) -> Value {
    for action in value["actions"].as_array_mut().into_iter().flatten() {
        if let Some(object) = action.as_object_mut()
            && let Some(plan) = object.remove("PLAN")
        {
            object.insert(crate::app_identity::ACTION_SURFACE_PLAN.to_owned(), plan);
        }
    }
    value
}

fn fixture_actions() -> Value {
    with_plan_key(json!({"actions": [
        {
            "id": "renameWorkspace", "title": "Rename Workspace…", "cli_name": "workspace rename",
            "cli": true, "targets": ["workspace"], "requires": [], "destructive": false,
            "PLAN": {"cli": "offered", "mcp": "offered"},
            "arguments": [{"name": "name", "title": "Name", "kind": "string", "required": true}],
        },
        {
            "id": "newWindow", "title": "New Window", "cli_name": "app new-window",
            "PLAN": {"cli": "offered", "mcp": "offered"}, "targets": [], "arguments": [],
        },
        {
            "id": "closeWorkspace", "title": "Close Workspace", "cli_name": "workspace close",
            "cli": true, "destructive": true, "targets": ["workspace"],
            "PLAN": {"cli": "offered", "mcp": "offered"},
            "arguments": [{"name": "confirm", "title": "Confirm", "kind": "bool", "required": false}],
        },
        {
            "id": "accounts.connect", "title": "Connect Account", "cli_name": "accounts connect",
            "PLAN": {"cli": "offered", "mcp": "credentials"}, "targets": [],
            "arguments": [{"name": "provider", "title": "Provider", "kind": "enum", "required": true,
                           "choices": [{"value": "codex", "title": "Codex"}]}],
        },
        {
            "id": "palette.toggleSidebar", "title": "Toggle Sidebar", "cli_name": "sidebar toggle",
            "cli": false, "targets": [], "arguments": [],
        },
        {
            "id": "oldApp", "title": "Old App Action", "cli_name": "old action", "cli": true,
            "targets": [], "arguments": [],
        },
    ]}))
}

fn object(value: Value) -> Map<String, Value> {
    value.as_object().cloned().expect("an object")
}

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

fn call(server: &mut Server<Fake>, name: &str, arguments: Value) -> Value {
    let request = json!({
        "jsonrpc": "2.0",
        "id": "call-1",
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    });
    let response = server.handle(&request).expect("a response");
    assert!(response.get("error").is_none(), "{response}");
    response["result"].clone()
}

#[test]
fn every_catalog_operation_is_a_tool_or_excluded_with_a_reason() {
    let operations = v2_tools::catalog()["operations"].as_object().expect("operations");
    let tools = v2_tools::tools().iter().map(|tool| tool.wire).collect::<BTreeSet<_>>();
    let excluded = v2_tools::exclusions()
        .into_iter()
        .map(|exclusion| (exclusion.name, exclusion.reason))
        .collect::<BTreeMap<_, _>>();
    for name in operations.keys() {
        assert!(
            tools.contains(name.as_str()) != excluded.contains_key(name),
            "{name} must be exactly one of a tool or an exclusion"
        );
    }
    assert_eq!(tools.len() + excluded.len(), operations.len());
    assert!(excluded.values().all(|reason| reason.len() > 10), "every exclusion has a reason");
    for tool in v2_tools::tools() {
        assert!(matches!(tool.operation.class(), OperationClass::Read | OperationClass::Mutation));
        assert_eq!(tool.mutation, tool.operation.class() == OperationClass::Mutation);
    }
    for (name, _) in v2_tools::EXCLUDED {
        assert!(operations.contains_key(*name), "stale exclusion {name}");
    }
}

#[test]
fn every_tool_is_reachable_from_the_cmux_cli_and_no_excluded_operation_is() {
    let cases = super::super::command::cases::safe_operation_cases();
    let sends =
        |args: &[&str]| match super::super::parse(&strings(args), super::super::Surface::Cmux) {
            Ok(ParsedCommand::Command { plan: CommandPlan::Protocol(request), .. }) => {
                request.operation.name().ok()
            }
            _ => None,
        };
    for tool in v2_tools::tools() {
        let (args, _) = cases
            .iter()
            .find(|(_, operation)| *operation == tool.wire)
            .unwrap_or_else(|| panic!("the CLI has no command for {}", tool.wire));
        assert_eq!(
            sends(args.as_slice()).as_deref(),
            Some(tool.wire),
            "`cmux {}` must send {}",
            args.join(" "),
            tool.wire
        );
    }
    for (wire, _) in v2_tools::EXCLUDED {
        if let Some((args, _)) = cases.iter().find(|(_, operation)| operation == wire) {
            assert_eq!(
                sends(args.as_slice()),
                None,
                "`cmux {}` offers excluded {wire}",
                args.join(" ")
            );
        }
    }
}

#[test]
fn cli_actions_become_tools_with_the_cli_request_and_an_mcp_origin() {
    let (tools, excluded) = action_tools::from_list(&fixture_actions());
    let names = tools.iter().map(|tool| tool.name.as_str()).collect::<Vec<_>>();
    assert_eq!(names, ["app_workspace_rename", "app_new_window", "app_workspace_close"]);
    // The app decides (surfaces.mcp); an app that does not say is refused.
    assert_eq!(excluded.len(), 2);
    assert!(excluded[0].name.starts_with("accounts.connect"));
    assert!(excluded[0].reason.contains("credentials"));
    assert!(excluded[1].name.starts_with("oldApp"));
    assert!(!names.iter().any(|name| name.contains("sidebar")), "GUI-only actions stay out");

    // `cmux workspace rename --target … --name …` and the tool send the
    // same `action.run`; only the origin differs.
    let Ok(AppCommand::Call { method, params: mut cli, .. }) = run_action(
        "workspace rename",
        &strings(&["--target", "ws_1a", "--name", "Build"]),
        ActionName::Cli,
    ) else {
        panic!("the CLI did not build an action run");
    };
    assert_eq!(method, "action.run");
    let tool = tools.iter().find(|tool| tool.name == "app_workspace_rename").expect("tool");
    let (mcp, key) =
        tool.run_params(&object(json!({"target": "ws_1a", "name": "Build"}))).expect("params");
    cli["origin"] = json!("mcp");
    assert_eq!(mcp, cli);
    assert_eq!(key, None);

    let schema = tool.input_schema();
    assert_eq!(schema["required"], json!(["name"]));
    assert_eq!(schema["properties"]["focus"]["type"], "boolean");
    assert!(schema["properties"]["target"]["description"].as_str().unwrap().contains("workspace"));
    let close = tools.iter().find(|tool| tool.name == "app_workspace_close").expect("tool");
    assert_eq!(close.descriptor_json()["annotations"]["destructiveHint"], true);
}

#[test]
fn action_runs_carry_the_mcp_origin_and_focus_only_when_asked() {
    let mut server = Server::new(Fake::with_actions(), None);
    let result =
        call(&mut server, "app_workspace_rename", json!({"target": WORKSPACE, "name": "Build"}));
    assert_eq!(result["isError"], false, "{result}");
    let sent = server.backend.last("app");
    assert_eq!(sent["method"], "action.run");
    assert_eq!(sent["params"]["origin"], "mcp");
    assert_eq!(sent["params"]["wait"], true);
    assert_eq!(sent["params"]["cli"], true);
    assert_eq!(sent["params"]["action"], "workspace rename");
    assert!(sent["params"].get("focus").is_none(), "no focus unless asked: {sent}");

    call(&mut server, "app_new_window", json!({"focus": true, "idempotency_key": "run-1"}));
    let sent = server.backend.last("app");
    assert_eq!(sent["params"]["focus"], true);
    assert_eq!(sent["params"]["origin"], "mcp");
    assert_eq!(sent["key"], "run-1");

    let unknown = call(&mut server, "app_new_window", json!({"bogus": 1}));
    assert_eq!(unknown["isError"], true);
    assert_eq!(unknown["structuredContent"]["state"], "not_run");
}

#[test]
fn mutations_carry_an_idempotency_key_that_a_retry_replays() {
    let mut server = Server::new(Fake::default(), None);
    let arguments = json!({"workspace": WORKSPACE, "name": "Build"});
    call(&mut server, "workspace_rename", arguments.clone());
    let generated = server.backend.last("resource");
    let key = generated["request"]["idempotency_key"].as_str().expect("a generated key");
    assert!(key.starts_with("mutation_"), "{key}");

    let mut with_key = arguments.clone();
    with_key["idempotency_key"] = json!("retry-1");
    call(&mut server, "workspace_rename", with_key.clone());
    let first = server.backend.last("resource");
    call(&mut server, "workspace_rename", with_key);
    let second = server.backend.last("resource");
    assert_eq!(first["request"]["idempotency_key"], "retry-1");
    assert_eq!(first["request"]["operation"], second["request"]["operation"]);
    assert_eq!(first["request"]["params"], second["request"]["params"]);
    assert_eq!(second["request"]["idempotency_key"], "retry-1");

    // Reads carry no key; a key on a read is an unknown argument.
    let read = call(&mut server, "workspace_list", json!({"idempotency_key": "k"}));
    assert_eq!(read["isError"], true);

    // A failure after sending reports the key and `in_progress`.
    let mut server = Server::new(Fake { fail_resources: true, ..Fake::default() }, None);
    let failed = call(&mut server, "workspace_rename", arguments);
    assert_eq!(failed["isError"], true);
    let envelope = &failed["structuredContent"];
    assert_eq!(envelope["state"], "in_progress");
    assert!(envelope["idempotency_key"].as_str().unwrap().starts_with("mutation_"));
    assert_eq!(envelope["error"]["code"], "transport.failed", "the error passes through");
}

#[test]
fn the_server_refuses_unless_cmux_json_enables_it() {
    let directory = tempfile::tempdir().expect("temp dir");
    let path = directory.path().join("cmux.json");
    assert!(refusal(&path).is_some(), "a missing file is off");
    std::fs::write(&path, r#"{"mcp": {"enabled": false}}"#).unwrap();
    assert!(refusal(&path).is_some());
    std::fs::write(&path, r#"{"mcp": {"enabled": "yes"}}"#).unwrap();
    assert!(refusal(&path).is_some_and(|message| message.contains("mcp.enabled")));
    std::fs::write(&path, "// on\n{\"mcp\": {\"enabled\": true, /* yes */},}\n").unwrap();
    assert_eq!(refusal(&path), None);

    std::fs::write(&path, r#"{"mcp": {"enabled": false}}"#).unwrap();
    let mut server = Server::new(Fake::default(), Some(path));
    let refused = call(&mut server, "workspace_list", json!({}));
    assert_eq!(refused["isError"], true);
    assert_eq!(refused["structuredContent"]["error"]["code"], "mcp.disabled");
    assert!(server.backend.sent.borrow().is_empty(), "nothing reached an owner");
}

#[test]
fn jsonc_comments_and_trailing_commas_are_dropped_outside_strings() {
    let text = "{\"url\": \"https://a//b/*c*/\", // note\n \"list\": [1, 2,], /* x */ }";
    let value: Value = serde_json::from_str(&config::strip_jsonc(text)).expect("valid JSON");
    assert_eq!(value, json!({"url": "https://a//b/*c*/", "list": [1, 2]}));
    assert_eq!(config::enabled_in("").ok(), Some(false));
    assert_eq!(config::enabled_in("{\"mcp\": {}}").ok(), Some(false));
}

fn fake_env(
    pairs: &'static [(&'static str, &'static str)],
) -> impl Fn(&str) -> Option<std::ffi::OsString> {
    move |name| {
        pairs.iter().find(|(key, _)| *key == name).map(|(_, value)| std::ffi::OsString::from(value))
    }
}

#[test]
fn the_settings_file_follows_the_app_override() {
    assert_eq!(
        config::path_from(fake_env(&[("HOME", "/Users/u")])),
        PathBuf::from("/Users/u/.config/cmux/cmux.json")
    );
    assert_eq!(
        config::path_from(fake_env(&[
            ("HOME", "/Users/u"),
            (config::CONFIG_OVERRIDE, "~/s/c.json"),
        ])),
        PathBuf::from("/Users/u/s/c.json")
    );
}

#[test]
fn json_rpc_lifecycle_and_errors() {
    let mut server = Server::new(Fake::with_actions(), None);
    let initialize = server
        .handle(&json!({"jsonrpc": "2.0", "id": "i", "method": "initialize",
                        "params": {"protocolVersion": "2025-03-26"}}))
        .unwrap();
    assert_eq!(initialize["result"]["protocolVersion"], "2025-03-26");
    assert_eq!(initialize["result"]["capabilities"]["tools"]["listChanged"], false);
    let newest = server
        .handle(&json!({"jsonrpc": "2.0", "id": "i", "method": "initialize",
                        "params": {"protocolVersion": "1999-01-01"}}))
        .unwrap();
    assert_eq!(newest["result"]["protocolVersion"], PROTOCOL_VERSIONS[0]);
    assert_eq!(
        server.handle(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"})),
        None
    );
    let unknown = server.handle(&json!({"jsonrpc": "2.0", "id": "u", "method": "nope"})).unwrap();
    assert_eq!(unknown["error"]["code"], -32601);
    let missing = server
        .handle(&json!({"jsonrpc": "2.0", "id": "m", "method": "tools/call",
                        "params": {"name": "no_such_tool"}}))
        .unwrap();
    assert_eq!(missing["error"]["code"], -32602);

    let listed = server.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"}));
    let tools = listed.unwrap()["result"]["tools"].as_array().cloned().unwrap();
    let names = tools.iter().filter_map(|tool| tool["name"].as_str()).collect::<BTreeSet<_>>();
    for expected in ["workspace_list", "terminal_input_write", "window_list", "app_new_window"] {
        assert!(names.contains(expected), "missing {expected}");
    }
    for absent in ["machine_list", "session_shutdown", "terminal_attach", "app_accounts_connect"] {
        assert!(!names.contains(absent), "{absent} must not be a tool");
    }
    assert_eq!(names.len(), tools.len(), "tool names are unique");

    let input = "{\"jsonrpc\":\"2.0\",\"id\":\"p\",\"method\":\"ping\"}\nnot json\n\n";
    let buffer = SharedBuffer::default();
    assert_eq!(server.run(input.as_bytes(), &watch::Output::new(buffer.clone())), 0);
    let lines = buffer.text();
    let lines =
        lines.lines().map(|line| serde_json::from_str::<Value>(line).unwrap()).collect::<Vec<_>>();
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[0]["result"], json!({}));
    assert_eq!(lines[1]["error"]["code"], -32700);
}

/// A writer whose bytes a test reads back.
#[derive(Clone, Default)]
struct SharedBuffer(std::sync::Arc<std::sync::Mutex<Vec<u8>>>);

impl Write for SharedBuffer {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl SharedBuffer {
    fn text(&self) -> String {
        String::from_utf8(self.0.lock().unwrap().clone()).unwrap()
    }
}

#[test]
fn the_tool_list_changes_on_a_catalog_event_or_an_app_restart() {
    let ack = json!({"ok": true, "result": {"subscribed": true}});
    let changed = json!({"type": "event", "name": watch::CATALOG_CHANGED});
    let other = json!({"type": "event", "name": "workspace.created"});

    // The app runs when the server starts: its acknowledgement is not a change.
    let mut watch = watch::ActionWatch::default();
    assert!(!watch.frame(&ack));
    assert!(!watch.frame(&other));
    assert!(watch.frame(&changed));
    // The app quit and came back (maybe another build): list again.
    assert!(watch.lost());
    assert!(watch.frame(&ack));
    // The app was not running at start and appears later.
    let mut late = watch::ActionWatch::default();
    assert!(!late.lost());
    assert!(!late.lost());
    assert!(late.frame(&ack));
}

#[test]
fn notifications_wait_for_initialization_and_the_capability_says_so() {
    let buffer = SharedBuffer::default();
    let output = watch::Output::new(buffer.clone());
    output.tools_changed().unwrap();
    assert_eq!(buffer.text(), "", "nothing before notifications/initialized");

    let mut server = Server::new(Fake::default(), None);
    server.list_changed = true;
    let input = concat!(
        "{\"jsonrpc\":\"2.0\",\"id\":\"i\",\"method\":\"initialize\",\"params\":{}}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n",
    );
    assert_eq!(server.run(input.as_bytes(), &output), 0);
    let initialize: Value = serde_json::from_str(buffer.text().lines().next().unwrap()).unwrap();
    assert_eq!(initialize["result"]["capabilities"]["tools"]["listChanged"], true);
    output.tools_changed().unwrap();
    let last: Value = serde_json::from_str(buffer.text().lines().last().unwrap()).unwrap();
    assert_eq!(last, json!({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}));
}

#[test]
fn tool_schemas_follow_the_catalog() {
    let name_ok = |name: &str| {
        !name.is_empty()
            && name.len() <= 64
            && name
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
    };
    for tool in v2_tools::tools() {
        assert!(name_ok(&tool.name), "{}", tool.name);
        let schema = tool.input_schema();
        let properties = schema["properties"].as_object().expect("properties");
        assert_eq!(schema["additionalProperties"], false);
        assert!(!properties.contains_key("machine"), "{} exposes the machine", tool.name);
        // `git.checkpoint.get` looks a create up by the key it ran under.
        let lookup = tool.wire == "git.checkpoint.get";
        let keyed = properties.contains_key("idempotency_key");
        assert_eq!(keyed, tool.mutation || lookup, "{}", tool.name);
        assert_eq!(properties.contains_key("offset"), tool.paginated, "{}", tool.name);
        for required in schema["required"].as_array().unwrap() {
            assert!(properties.contains_key(required.as_str().unwrap()), "{}", tool.name);
        }
        let annotations = &tool.descriptor_json()["annotations"];
        assert_eq!(annotations["readOnlyHint"], !tool.mutation);
    }
    let create = v2_tools::find("workspace_create").expect("workspace_create").input_schema();
    assert_eq!(create["properties"]["initial_content"]["enum"], json!(["terminal", "empty"]));
    assert!(create["required"].as_array().unwrap().contains(&json!("initial_content")));
    assert_eq!(create["properties"]["ephemeral"]["type"], "boolean");
    assert!(v2_tools::find("workspace_list").unwrap().paginated);
    assert!(!v2_tools::find("notification_list").unwrap().paginated, "owner's own limit");
}

#[test]
fn ids_take_a_unique_prefix_and_a_session_qualifier() {
    let tool = v2_tools::find("workspace_get").expect("workspace_get");
    let call = tool.plan(&object(json!({"workspace": "build-box:ws_1a2b"}))).expect("plan");
    assert_eq!(call.session.as_deref(), Some("build-box"));
    assert_eq!(call.plan.params["workspace"], "ws_1a2b");
    assert_eq!(
        call.prefixes,
        [Prefix { field: "workspace".into(), list: ResourceOperation::WorkspaceList }]
    );
    assert_eq!(call.plan.params["machine"], "current");
    assert_eq!(call.plan.params["session"], "current");

    for whole in [WORKSPACE, "current", "name:ws_1", "workspace:ws_1a"] {
        let call = tool.plan(&object(json!({"workspace": whole}))).expect("plan");
        assert!(call.prefixes.is_empty(), "{whole}");
        assert_eq!(call.session, None, "{whole}");
        assert_eq!(call.plan.params["workspace"], whole);
    }
    let two = tool.plan(&object(json!({"workspace": "a:ws_1", "session": "b"})));
    assert!(two.is_err(), "one call reaches one session");
    assert!(tool.plan(&object(json!({"bogus": "x"}))).is_err());
}

#[test]
fn large_reads_page_and_fit_the_result_limit() {
    let page = v2_tools::paginate(json!([1, 2, 3, 4, 5]), v2_tools::Page { offset: 1, limit: 2 });
    assert_eq!(page, json!({"items": [2, 3], "total": 5, "offset": 1, "next_offset": 3}));
    let last = v2_tools::paginate(json!([1, 2, 3]), v2_tools::Page { offset: 2, limit: 9 });
    assert_eq!(last["next_offset"], Value::Null);

    let big = (0..4000).map(|index| json!({"n": index, "text": "x".repeat(200)})).collect();
    let page = v2_tools::paginate(Value::Array(big), v2_tools::Page { offset: 0, limit: 4000 });
    let result = success(page, false);
    assert_eq!(result["isError"], false);
    let content = &result["structuredContent"];
    assert_eq!(content["truncated"], true);
    let kept = content["items"].as_array().unwrap().len() as u64;
    assert_eq!(content["next_offset"], json!(kept));
    assert!(result["content"][0]["text"].as_str().unwrap().len() <= MAX_RESULT_BYTES);
}

#[test]
fn a_change_whose_result_does_not_fit_still_reports_success() {
    let big = json!({"value": "x".repeat(MAX_RESULT_BYTES + 1)});
    let read = success(big.clone(), false);
    assert_eq!(read["isError"], true);
    assert_eq!(read["structuredContent"]["error"]["code"], "result.too_large");
    let applied = success(big, true);
    assert_eq!(applied["isError"], false, "a retry must not apply the change again");
    assert_eq!(applied["structuredContent"]["applied"], true);
}

#[test]
fn terminal_waits_are_bounded() {
    let wait = v2_tools::find("terminal_wait").expect("terminal_wait");
    let terminal = "term_0123456789abcdef0123456789abcdef";
    let call = wait.plan(&object(json!({"terminal": terminal, "pattern": "ok"}))).expect("plan");
    assert_eq!(call.plan.params["timeout_ms"], "30000");
    let call = wait
        .plan(&object(json!({"terminal": terminal, "pattern": "ok", "timeout_ms": "1500"})))
        .expect("plan");
    assert_eq!(call.plan.params["timeout_ms"], "1500");
    let long = wait.plan(&object(json!({"terminal": terminal, "timeout_ms": "300001"})));
    assert!(long.is_err());
    let exit = v2_tools::find("terminal_wait_exit").expect("terminal_wait_exit");
    let call = exit.plan(&object(json!({"terminal": terminal}))).expect("plan");
    assert_eq!(call.plan.params["timeout_ms"], "30000");
}

#[test]
fn an_owner_that_says_the_run_never_started_decides_the_state() {
    let failure = CallFailure {
        kind: FailureKind::Rejected,
        error: json!({"code": "busy", "message": "busy", "data": {"state": "not_run"}}),
        idempotency_key: Some("k".into()),
    };
    let result = failure_result(failure);
    assert_eq!(result["structuredContent"]["state"], "not_run");
    assert_eq!(result["structuredContent"]["idempotency_key"], "k");
    assert_eq!(result["structuredContent"]["error"]["code"], "busy");

    let expired = CallFailure {
        kind: FailureKind::Rejected,
        error: json!({"code": "timeout", "message": "never started; retry"}),
        idempotency_key: Some("k".into()),
    };
    assert_eq!(failure_result(expired)["structuredContent"]["state"], "in_progress");
}

#[test]
fn browser_repl_tools_come_from_the_browser_host_catalog() {
    let operations = browser_tools::catalog()["operations"].as_object().expect("operations");
    let names = browser_tools::tools().iter().map(|tool| tool.name.as_str()).collect::<Vec<_>>();
    assert_eq!(names.len(), operations.len(), "every browser host op is a tool");
    for expected in ["browser_repl_open", "browser_repl_eval", "browser_repl_close"] {
        assert!(names.contains(&expected), "missing {expected}");
    }
    for name in &names {
        assert!(v2_tools::find(name).is_none(), "{name} collides with a daemon tool");
    }
    let eval = browser_tools::find("browser_repl_eval").expect("eval").input_schema();
    assert_eq!(eval["required"], json!(["code"]));
    assert_eq!(eval["properties"]["timeoutMs"]["maximum"], 300000);
    assert_eq!(eval["additionalProperties"], false);
}

#[test]
fn browser_repl_calls_reach_the_host_bounded_and_marked_mcp() {
    let mut server = Server::new(Fake::default(), None);
    let result = call(&mut server, "browser_repl_eval", json!({"code": "print(1)"}));
    assert_eq!(result["isError"], false, "{result}");
    let sent = server.backend.last("browser");
    assert_eq!(sent["method"], "browser.repl.eval");
    assert_eq!(sent["params"]["timeoutMs"], 60000, "a default bound for one serial server");
    assert_eq!(sent["timeout_ms"], 90000);
    assert_eq!(sent["mutation"], true);

    let long = call(&mut server, "browser_repl_eval", json!({"code": "1", "timeoutMs": 300001}));
    assert_eq!(long["isError"], true);
    let unknown = call(&mut server, "browser_repl_open", json!({"rawCdp": true}));
    assert_eq!(unknown["isError"], true, "the raw CDP grant is not a tool argument");
    let list = call(&mut server, "browser_repl_list", json!({}));
    assert_eq!(list["isError"], false);
    assert_eq!(server.backend.last("browser")["mutation"], false);
}

#[test]
fn keybinding_read_tools_call_the_app_and_refuse_bad_arguments() {
    let mut server = Server::new(Fake::with_actions(), None);
    let listed =
        server.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    let tools = listed["result"]["tools"].as_array().cloned().unwrap();
    for name in ["keybinding_list", "keybinding_resolve", "context_keys"] {
        let tool = tools
            .iter()
            .find(|tool| tool["name"] == name)
            .unwrap_or_else(|| panic!("missing {name}"));
        assert_eq!(tool["annotations"]["readOnlyHint"], true);
    }
    let result =
        call(&mut server, "keybinding_resolve", json!({"keys": "ctrl+k s", "window": "win_a"}));
    assert_ne!(result["isError"], true, "{result}");
    let sent = server.backend.last("app");
    assert_eq!(sent["method"], "keybinding.resolve");
    assert_eq!(sent["params"], json!({"keys": "ctrl+k s", "window": "win_a"}));
    assert_eq!(sent["key"], Value::Null, "a read carries no idempotency key");
    call(&mut server, "keybinding_list", json!({"query": "tab"}));
    assert_eq!(server.backend.last("app")["method"], "keybinding.list");
    call(&mut server, "context_keys", json!({}));
    assert_eq!(server.backend.last("app")["method"], "context.keys");
    assert_eq!(
        call(&mut server, "keybinding_resolve", json!({}))["isError"],
        true,
        "keys is required"
    );
    assert_eq!(call(&mut server, "context_keys", json!({"nope": "x"}))["isError"], true);
}
