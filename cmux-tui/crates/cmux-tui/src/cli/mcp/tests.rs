use std::cell::RefCell;
use std::collections::BTreeSet;
use std::time::Duration;

use serde_json::{Value, json};

use super::super::command::{CommandPlan, ParsedCommand, RequestPlan};
use super::super::wire::request_value;
use super::transport::{CallFailure, FailureKind, Prefix};
use super::*;

/// Records what a tool call would send; answers like an empty session.
#[derive(Default)]
struct Fake {
    actions: Value,
    fail_resources: bool,
    fail_apps: bool,
    daemon_snapshot: Option<Value>,
    sent: RefCell<Vec<Value>>,
}

impl Fake {}

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
        Ok(self.daemon_snapshot.clone().unwrap_or_else(|| json!([])))
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
        if self.fail_apps {
            return Err(CallFailure {
                kind: FailureKind::NotRun,
                error: json!({"code": "transport.unavailable", "message": "app is down"}),
                idempotency_key: None,
            });
        }
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
fn agents_snapshot_pages_large_topologies_without_losing_objects() {
    let tabs = (0..250)
        .map(|i| json!({"id": format!("tab_{i:032x}"), "title": "x".repeat(2048)}))
        .collect::<Vec<_>>();
    let mut server =
        Server::new(Fake { daemon_snapshot: Some(json!({"tabs": tabs})), ..Fake::default() }, None);
    let mut offset = 0;
    let mut seen = BTreeSet::new();
    for _ in 0..300 {
        let result = call(&mut server, "agents_snapshot", json!({"offset": offset, "limit": 1000}));
        assert_eq!(result["isError"], false, "{result}");
        let page = &result["structuredContent"];
        assert!(serde_json::to_vec(page).unwrap().len() <= MAX_RESULT_BYTES);
        for item in page["items"].as_array().expect("paged objects") {
            if item["kind"] == "tab" {
                assert!(seen.insert(item["value"]["id"].as_str().unwrap().to_owned()));
            }
        }
        let Some(next) = page["next_offset"].as_u64() else { break };
        assert!(next > offset);
        offset = next;
    }
    assert_eq!(seen.len(), 250);
}

#[test]
fn jsonc_comments_and_trailing_commas_are_dropped_outside_strings() {
    let text = "{\"url\": \"https://a//b/*c*/\", // note\n \"list\": [1, 2,], /* x */ }";
    let value: Value = serde_json::from_str(&config::strip_jsonc(text)).expect("valid JSON");
    assert_eq!(value, json!({"url": "https://a//b/*c*/", "list": [1, 2]}));
    assert_eq!(config::enabled_in("").ok(), Some(false));
    assert_eq!(config::enabled_in("{\"mcp\": {}}").ok(), Some(false));
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
