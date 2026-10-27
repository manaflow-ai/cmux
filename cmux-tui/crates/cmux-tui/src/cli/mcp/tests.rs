use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant};

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
    fail_apps: bool,
    daemon_snapshot: Option<Value>,
    /// The answer to every daemon request but `session.snapshot`; else
    /// `daemon_snapshot`.
    resource_result: Option<Value>,
    /// The app's transport drops after a `feed.*` request is sent, as
    /// `transport::app_method` reports it.
    lose_app_transport: bool,
    /// Owner state that changes while a call waits (`agents_wait`).
    live: RefCell<Live>,
    /// This daemon operation answers `selector.not_found` after the delay,
    /// as a wait on a terminal that closes.
    fail_after: Option<(&'static str, Duration)>,
    /// The app's `feed.list` and `snapshot.get` take this long, and fail
    /// when it is longer than the caller's timeout.
    app_delay: Option<Duration>,
    /// What `Backend::caller` answers: `None` for a client with no caller
    /// identity, `Some(Null)` for one the app cannot place.
    caller: Option<Value>,
    /// The app's `beside` with `caller`: the column right of the chat.
    beside: Value,
    /// What `Backend::focus` answers.
    focus: Option<Value>,
    sent: RefCell<Vec<Value>>,
}

/// The daemon's snapshot and the app's pending dialogs at set times after
/// the test starts, as when an agent finishes or asks while a wait runs.
#[derive(Default)]
struct Live {
    daemon: Option<Value>,
    feed: Option<Value>,
    /// The app's topology (`snapshot.get`); a fixed window without it.
    topology: Option<Value>,
    /// The daemon's journal: batch `i` is revision `i + 1` of
    /// [`GENERATION`]. With it, the snapshot carries a cursor and the event
    /// stream resumes from one (`agents_events`).
    journal: Option<Vec<Value>>,
    /// The journal's generation; [`GENERATION`] when unset.
    generation: Option<String>,
    /// Revisions before this one are no longer kept: an older cursor
    /// expired.
    oldest: usize,
    /// Every daemon read fails.
    daemon_down: bool,
    changes: Vec<(Instant, Change)>,
}

impl Live {
    fn generation(&self) -> String {
        self.generation.clone().unwrap_or_else(|| GENERATION.to_owned())
    }
}

/// The fake daemon's journal generation.
const GENERATION: &str = "gen_fake";

enum Change {
    Daemon(Value),
    Feed(Value),
    Topology(Value),
    /// One journal batch: its changes.
    Journal(Value),
    /// The daemon restarted with a new journal generation.
    Generation(&'static str),
    /// The journal dropped the revisions before this one.
    Expire(usize),
    /// Daemon reads fail (true) or answer again (false).
    DaemonDown(bool),
}

impl Live {
    /// Applies the changes that are due.
    fn settle(&mut self) {
        let now = Instant::now();
        let (due, later) = std::mem::take(&mut self.changes)
            .into_iter()
            .partition::<Vec<_>, _>(|(at, _)| *at <= now);
        self.changes = later;
        for (_, change) in due {
            match change {
                Change::Daemon(value) => self.daemon = Some(value),
                Change::Feed(value) => self.feed = Some(value),
                Change::Topology(value) => self.topology = Some(value),
                Change::Journal(changes) => self.journal.get_or_insert_with(Vec::new).push(changes),
                Change::Generation(generation) => self.generation = Some(generation.to_owned()),
                Change::Expire(oldest) => self.oldest = oldest,
                Change::DaemonDown(down) => self.daemon_down = down,
            }
        }
    }
}

impl Fake {
    fn with_actions() -> Self {
        Self { actions: fixture_actions(), ..Self::default() }
    }

    /// A daemon snapshot and pending dialogs that `then` changes later.
    fn live(daemon: Option<Value>, feed: Option<Value>) -> Self {
        Self { live: RefCell::new(Live { daemon, feed, ..Live::default() }), ..Self::default() }
    }

    fn then(self, after: Duration, change: Change) -> Self {
        self.live.borrow_mut().changes.push((Instant::now() + after, change));
        self
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
        if let Some((operation, delay)) = self.fail_after
            && request["operation"] == operation
        {
            std::thread::sleep(delay);
            return Err(CallFailure {
                kind: FailureKind::Rejected,
                error: json!({"code": "selector.not_found", "message": "the terminal closed"}),
                idempotency_key: None,
            });
        }
        if request["operation"] != "session.snapshot"
            && let Some(result) = &self.resource_result
        {
            return Ok(result.clone());
        }
        let mut live = self.live.borrow_mut();
        live.settle();
        if live.daemon_down {
            return Err(CallFailure::local(FailureKind::NotRun, "transport.unavailable", "down"));
        }
        if let Some(daemon) = &live.daemon {
            let mut daemon = daemon.clone();
            if let Some(journal) = &live.journal {
                daemon["cursor"] =
                    json!({"generation": live.generation(), "revision": journal.len().to_string()});
            }
            return Ok(daemon);
        }
        Ok(self.daemon_snapshot.clone().unwrap_or_else(|| json!([])))
    }

    fn app(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
        idempotency_key: Option<&str>,
        mutation: bool,
    ) -> Result<Value, CallFailure> {
        if let Some(delay) = self.app_delay
            && matches!(method, "feed.list" | "snapshot.get")
        {
            std::thread::sleep(delay.min(timeout));
            if delay > timeout {
                return Err(CallFailure::local(FailureKind::NotRun, "app.timeout", "no answer"));
            }
        }
        self.sent.borrow_mut().push(json!({
            "kind": "app",
            "method": method,
            "params": params,
            "key": idempotency_key,
            "mutation": mutation,
        }));
        if self.lose_app_transport && method.starts_with("feed.") {
            let keyed = idempotency_key.is_some();
            return Err(CallFailure {
                kind: if keyed || mutation { FailureKind::InProgress } else { FailureKind::NotRun },
                error: json!({"code": "app.transport", "message": "connection reset",
                              "retryable": keyed || !mutation}),
                idempotency_key: idempotency_key.map(str::to_owned),
            });
        }
        if self.fail_apps {
            return Err(CallFailure {
                kind: FailureKind::NotRun,
                error: json!({"code": "transport.unavailable", "message": "app is down"}),
                idempotency_key: None,
            });
        }
        match method {
            "action.list" => Ok(self.actions.clone()),
            "snapshot.get" => {
                let mut live = self.live.borrow_mut();
                live.settle();
                Ok(live
                    .topology
                    .clone()
                    .unwrap_or_else(|| json!({"topology": {"windows": [{"id": "win_a"}]}})))
            }
            "feed.list" => {
                let mut live = self.live.borrow_mut();
                live.settle();
                Ok(live.feed.clone().unwrap_or_else(|| json!({"ran": true})))
            }
            _ => Ok(json!({"ran": true})),
        }
    }

    /// The daemon's stream: its snapshot, then a delta when a daemon change
    /// is due (a dialog is the app's and has none), and a tick without one.
    fn session_events(
        &self,
        _session: Option<&str>,
        cursor: Option<&Value>,
        deadline: Instant,
        tick: Duration,
        on_wake: &mut dyn FnMut(Option<&Value>) -> bool,
    ) -> Result<(), CallFailure> {
        self.sent.borrow_mut().push(json!({"kind": "events", "cursor": cursor}));
        if self.fail_resources || self.live.borrow().daemon_down {
            return Err(CallFailure::local(FailureKind::NotRun, "transport.unavailable", "down"));
        }
        if self.live.borrow().journal.is_some() {
            return self.journal_events(cursor, deadline, tick, on_wake);
        }
        if on_wake(Some(&json!({"kind": "snapshot"}))) {
            return Ok(());
        }
        loop {
            let now = Instant::now();
            if now >= deadline {
                return Ok(());
            }
            let next_change = self
                .live
                .borrow()
                .changes
                .iter()
                .filter(|(_, change)| matches!(change, Change::Daemon(_)))
                .map(|(at, _)| *at)
                .min();
            let wake = next_change.unwrap_or(deadline).min(now + tick).min(deadline);
            std::thread::sleep(wake.saturating_duration_since(now));
            let delta = next_change.is_some_and(|at| at <= wake);
            let item = json!({"kind": "delta"});
            if on_wake(delta.then_some(&item)) {
                return Ok(());
            }
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

    fn identity(&self) -> Result<Option<Value>, CallFailure> {
        self.sent.borrow_mut().push(json!({"kind": "caller"}));
        Ok(self.caller.clone().map(|caller| json!({"caller": caller, "beside": self.beside})))
    }

    fn focus(&self) -> Result<Option<Value>, CallFailure> {
        self.sent.borrow_mut().push(json!({"kind": "focus"}));
        Ok(self.focus.clone())
    }

    fn acpmux(
        &self,
        method: &str,
        params: Value,
        _timeout: Duration,
        idempotency_key: Option<&str>,
        mutation: bool,
    ) -> Result<Value, CallFailure> {
        self.sent.borrow_mut().push(json!({
            "kind": "acpmux",
            "method": method,
            "params": params,
            "key": idempotency_key,
            "mutation": mutation,
        }));
        Ok(json!({
            "brief": {
                "briefId": "brief_qwen_1",
                "title": "Qwen task",
                "from": "acp:opus",
                "to": "acp:qwen",
                "target": "auto",
                "host": "cmux16",
                "stopCondition": "Report findings",
                "status": "running",
                "sessionId": "session_qwen_1"
            },
            "event": {"kind": "dispatch", "briefId": "brief_qwen_1"}
        }))
    }
}

impl Fake {
    /// `session.events` over the fake journal, as the daemon streams it:
    /// a snapshot without a cursor (or with another generation's), else the
    /// batches after the cursor, then each batch as it is due.
    fn journal_events(
        &self,
        cursor: Option<&Value>,
        deadline: Instant,
        tick: Duration,
        on_wake: &mut dyn FnMut(Option<&Value>) -> bool,
    ) -> Result<(), CallFailure> {
        let head = || {
            let mut live = self.live.borrow_mut();
            live.settle();
            live.journal.as_ref().map_or(0, Vec::len)
        };
        let generation = self.live.borrow().generation();
        let oldest = self.live.borrow().oldest;
        let mut next = match cursor {
            Some(cursor)
                if cursor["generation"] == generation.as_str()
                    && cursor["revision"].as_str().unwrap().parse::<usize>().unwrap() >= oldest =>
            {
                let revision = cursor["revision"].as_str().unwrap().parse::<usize>().unwrap();
                if revision > head() {
                    return Err(CallFailure {
                        kind: FailureKind::Rejected,
                        error: json!({"code": "cursor.invalid", "message": "ahead"}),
                        idempotency_key: None,
                    });
                }
                revision
            }
            other => {
                let revision = head();
                let item = json!({
                    "kind": "snapshot",
                    "cursor": {"generation": generation, "revision": revision.to_string()},
                    "reset_reason": match other {
                        None => "initial",
                        Some(cursor) if cursor["generation"] == generation.as_str() => {
                            "cursor_expired"
                        }
                        Some(_) => "generation_changed",
                    },
                    "snapshot": self.live.borrow().daemon.clone().unwrap_or_else(|| json!({})),
                });
                if on_wake(Some(&item)) {
                    return Ok(());
                }
                revision
            }
        };
        loop {
            let pending = head();
            while next < pending {
                let changes = self.live.borrow().journal.as_ref().unwrap()[next].clone();
                let item = json!({
                    "kind": "delta",
                    "cursor": {"generation": generation, "revision": (next + 1).to_string()},
                    "previous_revision": next.to_string(),
                    "revision": (next + 1).to_string(),
                    "changes": changes,
                });
                next += 1;
                if on_wake(Some(&item)) {
                    return Ok(());
                }
            }
            let now = Instant::now();
            if now >= deadline {
                return Ok(());
            }
            let due = self
                .live
                .borrow()
                .changes
                .iter()
                .filter(|(_, change)| matches!(change, Change::Journal(_)))
                .map(|(at, _)| *at)
                .min();
            let wake = due.unwrap_or(deadline).min(now + tick).min(deadline);
            std::thread::sleep(wake.saturating_duration_since(now));
            if head() == next && on_wake(None) {
                return Ok(());
            }
        }
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
fn agent_dispatch_tools_route_one_harness_agnostic_call_without_shell() {
    let mut server = Server::new(Fake::default(), None);
    let result = call(
        &mut server,
        "agent_dispatch",
        json!({
            "title": "Qwen task",
            "brief": "Inspect the fixture and report the result.",
            "target": "auto",
            "harness": "qwen",
            "stop_condition": "Report findings",
            "idempotency_key": "brief-qwen-1"
        }),
    );
    assert_eq!(result["isError"], false, "{result}");
    assert_eq!(result["structuredContent"]["briefId"], "brief_qwen_1");
    assert_eq!(result["structuredContent"]["event"]["kind"], "dispatch");
    let sent = server.backend.last("acpmux");
    assert_eq!(sent["method"], "_acpmux/dispatch");
    assert_eq!(sent["params"]["model"], "qwen");
    assert_eq!(sent["params"]["target"], "auto");
    assert!(sent["params"].get("shell").is_none());
    assert!(sent["params"].get("ssh").is_none());
    assert_eq!(sent["key"], "brief-qwen-1");
}

#[test]
fn agent_brief_tools_use_the_brief_id_for_steer_list_and_report() {
    let mut server = Server::new(Fake::default(), None);
    let _ =
        call(&mut server, "agent_steer", json!({"brief_id": "brief_qwen_1", "text": "Keep going"}));
    assert_eq!(server.backend.last("acpmux")["method"], "_acpmux/steer");
    assert_eq!(server.backend.last("acpmux")["params"]["briefId"], "brief_qwen_1");
    let _ = call(&mut server, "agent_briefs_list", json!({"status": "running"}));
    assert_eq!(server.backend.last("acpmux")["method"], "_acpmux/briefs");
    let _ = call(
        &mut server,
        "agent_report",
        json!({"brief_id": "brief_qwen_1", "summary": "Done", "status": "reported"}),
    );
    assert_eq!(server.backend.last("acpmux")["method"], "_acpmux/report");
    assert_eq!(server.backend.last("acpmux")["params"]["briefId"], "brief_qwen_1");
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
fn agents_snapshot_reports_total_owner_outage() {
    let mut server =
        Server::new(Fake { fail_resources: true, fail_apps: true, ..Fake::with_actions() }, None);
    let result = call(&mut server, "agents_snapshot", json!({}));
    assert_eq!(result["isError"], true);
    assert_eq!(result["structuredContent"]["error"]["code"], "agents.unavailable");
    assert_eq!(result["structuredContent"]["state"], "not_run");
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
fn agents_snapshot_rejects_invalid_pagination_before_reading_owners() {
    for args in [
        json!({"offset": -1}),
        json!({"limit": 0}),
        json!({"limit": 1001}),
        json!({"offset": "one"}),
    ] {
        let mut server = Server::new(Fake::default(), None);
        let result = call(&mut server, "agents_snapshot", args);
        assert_eq!(result["isError"], true);
        assert!(server.backend.sent.borrow().is_empty());
    }
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
        PathBuf::from("/Users/u/.config/cmux/cmux-next.json")
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
    for expected in [
        "workspace_list",
        "machine_list",
        "machine_get",
        "terminal_input_write",
        "window_list",
        "agents_snapshot",
        "app_new_window",
    ] {
        assert!(names.contains(expected), "missing {expected}");
    }
    for absent in ["session_list", "session_shutdown", "terminal_attach", "app_accounts_connect"] {
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

const AGENT_ACTION_TOOLS: [&str; 8] = [
    "agents_workspace_select",
    "agents_workspace_create",
    "agents_tab_select",
    "agents_terminal_focus",
    "agents_terminal_split",
    "agents_palette_open",
    "agents_dialog_list",
    "agents_dialog_answer",
];

fn sent_of(server: &Server<Fake>, kind: &str) -> Vec<Value> {
    server.backend.sent.borrow().iter().filter(|sent| sent["kind"] == kind).cloned().collect()
}

#[test]
fn agents_action_tools_are_listed_with_strict_schemas() {
    let mut server = Server::new(Fake::with_actions(), None);
    let listed =
        server.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    let tools = listed["result"]["tools"].as_array().cloned().unwrap();
    let names = tools.iter().filter_map(|tool| tool["name"].as_str()).collect::<BTreeSet<_>>();
    assert_eq!(names.len(), tools.len(), "tool names are unique");
    for name in AGENT_ACTION_TOOLS {
        let tool = tools
            .iter()
            .find(|tool| tool["name"] == name)
            .unwrap_or_else(|| panic!("missing {name}"));
        let schema = &tool["inputSchema"];
        assert_eq!(schema["type"], "object", "{name}");
        assert_eq!(schema["additionalProperties"], false, "{name}");
        let keyed = !matches!(name, "agents_dialog_list" | "agents_dialog_answer");
        assert_eq!(schema["properties"].get("idempotency_key").is_some(), keyed, "{name}");
        assert_eq!(
            tool["annotations"]["readOnlyHint"],
            name == "agents_dialog_list",
            "{name} annotations"
        );
    }
    let find = |name: &str| tools.iter().find(|tool| tool["name"] == name).unwrap().clone();
    assert_eq!(find("agents_workspace_select")["inputSchema"]["required"], json!(["workspace"]));
    assert_eq!(find("agents_tab_select")["inputSchema"]["required"], json!(["tab"]));
    assert_eq!(find("agents_dialog_answer")["inputSchema"]["required"], json!(["request_id"]));
    assert_eq!(
        find("agents_terminal_split")["inputSchema"]["properties"]["direction"]["enum"],
        json!(["left", "right", "up", "down"])
    );
}

#[test]
fn agents_doctor_is_a_read_only_tool_that_changes_nothing() {
    let mut server = Server::new(Fake::with_actions(), None);
    let listed =
        server.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    let tools = listed["result"]["tools"].as_array().cloned().unwrap();
    let tool = tools
        .iter()
        .find(|tool| tool["name"] == "agents_doctor")
        .unwrap_or_else(|| panic!("agents_doctor is not listed"));
    assert_eq!(tool["annotations"]["readOnlyHint"], true, "{tool}");
    assert_eq!(tool["annotations"]["destructiveHint"], false, "{tool}");
    assert_eq!(tool["inputSchema"]["additionalProperties"], false, "{tool}");
    assert_eq!(
        tool["inputSchema"]["properties"].as_object().unwrap().keys().collect::<Vec<_>>(),
        ["checks"],
        "{tool}"
    );
    server.backend.sent.borrow_mut().clear();
    let result = call(&mut server, "agents_doctor", json!({}));
    assert_eq!(result["isError"], false, "{result}");
    // At most the one read of the app's Computer Use grants; no run, no change.
    let sent = server.backend.sent.borrow().clone();
    assert!(
        sent.iter().all(|sent| sent["kind"] == "app" && sent["method"] == "computer_use.status"),
        "{sent:?}"
    );
}

#[test]
fn agents_workspace_select_focuses_through_the_owners_and_returns_a_receipt() {
    let mut server = Server::new(
        Fake {
            daemon_snapshot: Some(json!({
                "id": WORKSPACE,
                "workspaces": [{"id": WORKSPACE, "focused": true}],
            })),
            ..Fake::default()
        },
        None,
    );
    let result = call(
        &mut server,
        "agents_workspace_select",
        json!({"workspace": WORKSPACE, "idempotency_key": "select-1"}),
    );
    assert_eq!(result["isError"], false, "{result}");
    let resources = sent_of(&server, "resource");
    let request = &resources[0]["request"];
    assert_eq!(request["operation"], "workspace.focus");
    assert_eq!(request["params"]["workspace"], WORKSPACE);
    assert_eq!(request["idempotency_key"], "select-1");
    let apps = sent_of(&server, "app");
    assert_eq!(apps[0]["method"], "action.run", "the app shows the workspace: {apps:?}");
    assert_eq!(apps[0]["params"]["action"], "goToWorkspace");
    assert_eq!(apps[0]["params"]["args"]["workspace"], WORKSPACE);
    assert_eq!(apps[0]["params"]["focus"], true);
    // The receipt: the owner's result and a fresh composed snapshot.
    let receipt = &result["structuredContent"];
    assert_eq!(receipt["action"], "workspace.select");
    assert_eq!(receipt["result"]["id"], WORKSPACE);
    assert_eq!(receipt["state"]["workspaces"][0]["id"], WORKSPACE);
    assert_eq!(receipt["state"]["windows"][0]["id"], "win_a");
    assert_eq!(receipt["state"]["sources"]["daemon"]["available"], true);
    assert_eq!(receipt["state"]["sources"]["app"]["available"], true);
    assert_eq!(resources.last().unwrap()["request"]["operation"], "session.snapshot");
    assert_eq!(apps.last().unwrap()["method"], "snapshot.get");
}

#[test]
fn agents_action_tools_send_the_cli_requests_and_move_focus_only_by_purpose() {
    let tab = "tab_0123456789abcdef0123456789abcdef";
    let pane = "pane_0123456789abcdef0123456789abcdef";
    let mut server = Server::new(Fake::default(), None);

    let result = call(&mut server, "agents_tab_select", json!({"tab": format!("build-box:{tab}")}));
    assert_eq!(result["isError"], false, "{result}");
    let sent = &sent_of(&server, "resource")[0];
    assert_eq!(sent["session"], "build-box", "a qualified id routes to its session");
    assert_eq!(sent["request"]["operation"], "tab.focus");
    assert_eq!(sent["request"]["params"]["tab"], tab);
    assert!(
        sent["request"]["idempotency_key"].as_str().unwrap().starts_with("mutation_"),
        "a mutation without a key gets one: {sent}"
    );

    server.backend.sent.borrow_mut().clear();
    let result = call(
        &mut server,
        "agents_workspace_create",
        json!({"name": "--Build", "empty": true, "idempotency_key": "create-1"}),
    );
    assert_eq!(result["isError"], false, "{result}");
    assert_eq!(result["structuredContent"]["action"], "workspace.create");
    let request = &sent_of(&server, "resource")[0]["request"];
    assert_eq!(request["operation"], "workspace.create");
    assert_eq!(request["params"]["name"], "--Build");
    assert_eq!(request["params"]["initial_content"], "empty");
    assert_eq!(request["idempotency_key"], "create-1");
    assert!(
        sent_of(&server, "app").iter().all(|sent| sent["method"] != "action.run"),
        "creating a workspace leaves the user's focus alone"
    );

    server.backend.sent.borrow_mut().clear();
    let result =
        call(&mut server, "agents_terminal_split", json!({"direction": "right", "pane": pane}));
    assert_eq!(result["isError"], false, "{result}");
    let request = &sent_of(&server, "resource")[0]["request"];
    assert_eq!(request["operation"], "pane.split");
    assert_eq!(request["params"]["pane"], pane);
    assert!(sent_of(&server, "app").iter().all(|sent| sent["method"] != "action.run"));

    server.backend.sent.borrow_mut().clear();
    let result = call(&mut server, "agents_palette_open", json!({"idempotency_key": "palette-1"}));
    assert_eq!(result["isError"], false, "{result}");
    let run = &sent_of(&server, "app")[0];
    assert_eq!(run["method"], "action.run");
    assert_eq!(run["params"]["action"], "palette.open");
    assert_eq!(run["key"], "palette-1");

    server.backend.sent.borrow_mut().clear();
    call(&mut server, "agents_dialog_list", json!({"all": true}));
    let list = &sent_of(&server, "app")[0];
    assert_eq!(list["method"], "feed.list");
    assert_eq!(list["params"]["pending_only"], false);

    server.backend.sent.borrow_mut().clear();
    let result = call(
        &mut server,
        "agents_dialog_answer",
        json!({"request_id": "request_a", "selections": ["one", "two"]}),
    );
    assert_eq!(result["structuredContent"]["action"], "dialog.answer", "{result}");
    let reply = &sent_of(&server, "app")[0];
    assert_eq!(reply["method"], "feed.question.reply");
    assert_eq!(reply["params"], json!({"request_id": "request_a", "selections": ["one", "two"]}));
}

#[test]
fn agents_action_tools_refuse_invalid_arguments_before_reaching_an_owner() {
    for (name, arguments) in [
        ("agents_workspace_select", json!({})),
        ("agents_workspace_select", json!({"workspace": WORKSPACE, "bogus": 1})),
        ("agents_workspace_select", json!({"workspace": "--all"})),
        ("agents_workspace_select", json!({"workspace": 7})),
        ("agents_workspace_create", json!({"empty": "yes"})),
        ("agents_tab_select", json!({"tab": "a:tab_x", "session": "b"})),
        ("agents_terminal_split", json!({"direction": "diagonal"})),
        ("agents_dialog_list", json!({"idempotency_key": "k"})),
        ("agents_dialog_answer", json!({"request_id": "r"})),
        ("agents_dialog_answer", json!({"request_id": "r", "mode": "allow", "selections": ["a"]})),
        ("agents_dialog_answer", json!({"request_id": "r", "selections": []})),
    ] {
        let mut server = Server::new(Fake::default(), None);
        let result = call(&mut server, name, arguments.clone());
        assert_eq!(result["isError"], true, "{name} {arguments}: {result}");
        assert_eq!(result["structuredContent"]["state"], "not_run", "{name} {arguments}");
        assert!(server.backend.sent.borrow().is_empty(), "{name} {arguments} reached an owner");
    }
}

#[test]
fn agents_action_tools_report_a_failing_owner_with_its_state_and_key() {
    let mut server = Server::new(Fake { fail_resources: true, ..Fake::default() }, None);
    let result = call(
        &mut server,
        "agents_workspace_select",
        json!({"workspace": WORKSPACE, "idempotency_key": "select-1"}),
    );
    assert_eq!(result["isError"], true);
    let envelope = &result["structuredContent"];
    assert_eq!(envelope["state"], "in_progress");
    assert_eq!(envelope["idempotency_key"], "select-1");
    assert_eq!(envelope["error"]["code"], "transport.failed", "the error passes through");

    let mut server = Server::new(Fake { fail_apps: true, ..Fake::default() }, None);
    let result = call(&mut server, "agents_palette_open", json!({}));
    assert_eq!(result["isError"], true);
    assert_eq!(result["structuredContent"]["state"], "not_run");
    assert_eq!(result["structuredContent"]["error"]["code"], "transport.unavailable");
}

#[test]
fn agents_dialog_answer_only_denies_permissions_over_mcp() {
    for mode in ["bypassPermissions", "always", "allow", "acceptEdits", "default"] {
        let mut server = Server::new(Fake::default(), None);
        let result = call(
            &mut server,
            "agents_dialog_answer",
            json!({"request_id": "request_a", "mode": mode}),
        );
        assert_eq!(result["isError"], true, "{mode}: {result}");
        assert_eq!(result["structuredContent"]["state"], "not_run", "{mode}");
        let message = result["structuredContent"]["error"]["message"].as_str().unwrap();
        assert!(message.contains("approve permissions in cmux, not over MCP"), "{message}");
        assert!(server.backend.sent.borrow().is_empty(), "{mode} reached the app");
    }
    let mut server = Server::new(Fake::default(), None);
    let result = call(
        &mut server,
        "agents_dialog_answer",
        json!({"request_id": "request_a", "mode": "deny"}),
    );
    assert_eq!(result["isError"], false, "{result}");
    let reply = &sent_of(&server, "app")[0];
    assert_eq!(reply["method"], "feed.permission.reply");
    assert_eq!(reply["params"], json!({"request_id": "request_a", "mode": "deny"}));

    let listed =
        server.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    let tools = listed["result"]["tools"].as_array().cloned().unwrap();
    let find = |name: &str| tools.iter().find(|tool| tool["name"] == name).unwrap().clone();
    let answer = find("agents_dialog_answer");
    assert_eq!(answer["annotations"]["destructiveHint"], true);
    assert_eq!(answer["inputSchema"]["properties"]["mode"]["enum"], json!(["deny"]));
    assert!(answer["description"].as_str().unwrap().contains("other agents"), "{answer}");
    let list = find("agents_dialog_list");
    assert!(list["description"].as_str().unwrap().contains("other agents"), "{list}");
}

#[test]
fn agents_dialog_answer_reports_a_reply_lost_after_sending_as_in_progress() {
    let mut server = Server::new(Fake { lose_app_transport: true, ..Fake::default() }, None);
    let result = call(
        &mut server,
        "agents_dialog_answer",
        json!({"request_id": "request_a", "selections": ["one"]}),
    );
    assert_eq!(result["isError"], true, "{result}");
    assert_eq!(result["structuredContent"]["state"], "in_progress", "{result}");
    assert_eq!(result["structuredContent"]["error"]["retryable"], false);
    assert_eq!(sent_of(&server, "app")[0]["mutation"], true);

    // A list is a read: nothing changed, so it never ran.
    let mut server = Server::new(Fake { lose_app_transport: true, ..Fake::default() }, None);
    let result = call(&mut server, "agents_dialog_list", json!({}));
    assert_eq!(result["structuredContent"]["state"], "not_run", "{result}");
    assert_eq!(sent_of(&server, "app")[0]["mutation"], false);
}

#[test]
fn agents_oversized_receipt_keeps_the_action_result_and_key() {
    let created = "ws_fedcba9876543210fedcba9876543210";
    let tabs = (0..250)
        .map(|i| json!({"id": format!("tab_{i:032x}"), "title": "x".repeat(2048)}))
        .collect::<Vec<_>>();
    let mut server = Server::new(
        Fake {
            daemon_snapshot: Some(json!({"tabs": tabs})),
            resource_result: Some(json!({"id": created, "name": "Build"})),
            ..Fake::default()
        },
        None,
    );
    let result = call(
        &mut server,
        "agents_workspace_create",
        json!({"name": "Build", "idempotency_key": "create-big"}),
    );
    assert_eq!(result["isError"], false, "{result}");
    let receipt = &result["structuredContent"];
    assert!(serde_json::to_vec(receipt).unwrap().len() <= MAX_RESULT_BYTES);
    assert_eq!(receipt["action"], "workspace.create");
    assert_eq!(receipt["result"]["id"], created);
    assert_eq!(receipt["idempotency_key"], "create-big");
    assert_eq!(receipt["state"], json!({"truncated": true, "hint": "call agents_snapshot"}));

    // Without a key the receipt names the one the daemon request carried.
    let result = call(&mut server, "agents_workspace_create", json!({"name": "Build"}));
    let sent = &sent_of(&server, "resource")
        .into_iter()
        .rfind(|sent| sent["request"]["operation"] == "workspace.create")
        .unwrap();
    let key = sent["request"]["idempotency_key"].as_str().unwrap();
    assert!(key.starts_with("mutation_"), "{key}");
    assert_eq!(result["structuredContent"]["idempotency_key"], key);
}

#[test]
fn agents_palette_open_over_mcp_carries_the_mcp_origin() {
    let mut server = Server::new(Fake::default(), None);
    let result = call(&mut server, "agents_palette_open", json!({}));
    assert_eq!(result["isError"], false, "{result}");
    let run = &sent_of(&server, "app")[0];
    assert_eq!(run["params"]["action"], "palette.open");
    assert_eq!(run["params"]["origin"], "mcp", "{run}");
    assert_eq!(run["params"]["focus"], true);
}

#[test]
fn render_shows_a_page_in_the_chat_without_reaching_an_owner() {
    let mut server = Server::new(Fake::default(), None);
    let tools = server.list();
    let tool = tools.iter().find(|tool| tool["name"] == "render").expect("render is listed");
    assert_eq!(tool["inputSchema"]["required"], json!(["html"]));
    let sent = server.backend.sent.borrow().len();

    let page = "<title>Desk clamp</title><canvas></canvas>";
    let result = call(&mut server, "render", json!({"html": page, "title": "Desk clamp"}));
    assert_eq!(result["isError"], false, "{result}");
    assert_eq!(result["structuredContent"]["rendered"], true);
    assert_eq!(result["structuredContent"]["bytes"], page.len());
    assert_eq!(
        server.backend.sent.borrow().len(),
        sent,
        "the chat draws the call; no owner is asked"
    );

    for arguments in [
        json!({"html": "  "}),
        json!({}),
        json!({"html": page, "url": "x"}),
        json!({"html": page, "title": "t".repeat(201)}),
    ] {
        let refused = call(&mut server, "render", arguments.clone());
        assert_eq!(refused["isError"], true, "{arguments}");
        assert_eq!(refused["structuredContent"]["state"], "not_run");
    }
}

mod agent_events;
mod agent_wait;

mod caller_scope;
mod catalog;
mod machine_catalog;

fn code_mode_server(fake: Fake) -> Server<Fake> {
    let mut server = Server::new(fake, None);
    server.code_mode = true;
    server
}

#[test]
fn code_mode_lists_only_cmux_exec_and_a_script_reaches_every_tool() {
    let mut server = code_mode_server(Fake::with_actions());
    let initialize =
        server.handle(&json!({"jsonrpc": "2.0", "id": "i", "method": "initialize"})).unwrap();
    assert!(initialize["result"]["instructions"].as_str().unwrap().contains("cmux_exec"));
    let listed =
        server.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    let tools = listed["result"]["tools"].as_array().cloned().unwrap();
    let names = tools.iter().filter_map(|tool| tool["name"].as_str()).collect::<Vec<_>>();
    // Only cmux_exec (Lawrence 2026-10-23): a script searches with
    // `cmux.docs(query)`, and `cmux_docs` stays callable for old prompts.
    assert_eq!(names, ["cmux_exec"]);
    let bytes = serde_json::to_vec(&tools).unwrap().len();
    assert!(bytes < 8 << 10, "the code-mode list is {bytes} bytes");
    let all = server.list();
    assert!(all.len() > 100, "the full list stays the API");
    assert!(tools[0]["description"].as_str().unwrap().contains("app (3)"));

    // Docs returns a matching tool's schema, best match first.
    let found = call(&mut server, "cmux_docs", json!({"query": "workspace rename"}));
    let first = &found["structuredContent"]["tools"][0];
    assert_eq!(first["name"], "app_workspace_rename", "{found}");
    assert_eq!(first["inputSchema"]["required"], json!(["name"]));
    let index = call(&mut server, "cmux_docs", json!({}));
    assert!(index["structuredContent"]["families"]["workspace"].is_array(), "{index}");
    let exact = call(&mut server, "cmux_docs", json!({"names": ["window_list", "nope"]}));
    assert_eq!(exact["structuredContent"]["unknown"], json!(["nope"]));

    // One script calls a daemon tool and an app action through `call`: the
    // app sees the same MCP-origin action run as a direct tool call.
    let script = r#"
        const workspaces = await cmux.workspace_list({});
        console.log("workspaces", workspaces.items.length);
        const run = await cmux.call("app_workspace_rename", {target: "ws_1a", name: "Build"});
        return {run, found: cmux.docs("new window").tools[0].name};
    "#;
    let ran = call(&mut server, "cmux_exec", json!({"script": script}));
    assert_eq!(ran["isError"], false, "{ran}");
    let content = &ran["structuredContent"];
    assert_eq!(content["calls"], 2);
    assert_eq!(content["logs"], json!(["workspaces 0"]));
    assert_eq!(content["result"]["run"]["ran"], true);
    assert_eq!(content["result"]["found"], "app_new_window");
    // `cmux.docs` reads `action.list` after the run, so find the run itself.
    let runs = sent_of(&server, "app");
    let sent = runs.iter().rev().find(|sent| sent["method"] == "action.run").expect("a run");
    assert_eq!(sent["params"]["origin"], "mcp");
    assert_eq!(sent["params"]["action"], "workspace rename");
}

#[test]
fn code_mode_scripts_see_failed_calls_and_report_partial_runs() {
    let mut server = code_mode_server(Fake { fail_resources: true, ..Fake::with_actions() });
    // A failed call throws with the owner's error, state and key.
    let caught = call(
        &mut server,
        "cmux_exec",
        json!({"script": "try { await cmux.workspace_list({}); } catch (e) { return e.cmux.state; }"}),
    );
    assert_eq!(caught["structuredContent"]["result"], "in_progress", "{caught}");

    // An uncaught one fails the script and says calls already ran.
    let failed = call(
        &mut server,
        "cmux_exec",
        json!({"script": "await cmux.app_new_window({}); await cmux.workspace_list({});"}),
    );
    assert_eq!(failed["isError"], true);
    let content = &failed["structuredContent"];
    assert_eq!(content["state"], "partial");
    assert_eq!(content["calls"], 2);
    assert_eq!(content["error"]["cmux"]["state"], "in_progress", "{failed}");

    // No nested scripts, unknown tools throw, syntax errors run nothing.
    let nested = call(
        &mut server,
        "cmux_exec",
        json!({"script": "return await cmux.cmux_exec({script: 'return 1'});"}),
    );
    assert_eq!(nested["isError"], true);
    let unknown = call(&mut server, "cmux_exec", json!({"script": "await cmux.no_such_tool({});"}));
    assert!(
        unknown["structuredContent"]["error"]["message"].as_str().unwrap().contains("unknown tool"),
        "{unknown}"
    );
    let syntax = call(&mut server, "cmux_exec", json!({"script": "return (;"}));
    assert_eq!(syntax["structuredContent"]["state"], "not_run");
    // The engine has no file, network or process access.
    let sandboxed = call(
        &mut server,
        "cmux_exec",
        json!({"script": "return [typeof require, typeof fetch, typeof process, typeof setTimeout];"}),
    );
    assert_eq!(
        sandboxed["structuredContent"]["result"],
        json!(["undefined", "undefined", "undefined", "undefined"])
    );
}

#[test]
fn code_mode_stops_a_script_that_loops_or_allocates_without_end() {
    let mut server = code_mode_server(Fake::with_actions());
    server.script_limits = code_mode::Limits {
        memory: 16 << 20,
        compute: Duration::from_millis(300),
        ..code_mode::Limits::default()
    };
    let started = Instant::now();
    let looped = call(&mut server, "cmux_exec", json!({"script": "while (true) {}"}));
    assert_eq!(looped["isError"], true);
    assert_eq!(looped["structuredContent"]["error"]["code"], "script.timeout", "{looped}");
    assert!(started.elapsed() < Duration::from_secs(10), "the loop was stopped");

    let grew = call(
        &mut server,
        "cmux_exec",
        json!({"script": "const kept = []; while (true) kept.push('x'.repeat(1 << 20) + kept.length);"}),
    );
    assert_eq!(grew["isError"], true);
    let code = grew["structuredContent"]["error"]["code"].as_str().unwrap_or_default().to_owned();
    assert!(matches!(code.as_str(), "script.memory" | "script.timeout"), "{grew}");
    assert_eq!(grew["structuredContent"]["state"], "not_run");

    // The server still answers after both.
    let after = call(&mut server, "cmux_exec", json!({"script": "return 2 + 2;"}));
    assert_eq!(after["structuredContent"]["result"], 4, "{after}");
}

#[test]
fn an_allowlist_lists_only_its_tools_and_refuses_every_other_call() {
    let mut server = code_mode_server(Fake::with_actions());
    server.allowed = allowed_tools(Some("agents_snapshot, window_list,app_new_window".into()));
    let listed =
        server.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    let names = listed["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|tool| tool["name"].as_str().map(str::to_owned))
        .collect::<BTreeSet<_>>();
    assert_eq!(
        names,
        BTreeSet::from(["agents_snapshot", "window_list", "app_new_window"].map(str::to_owned))
    );
    let allowed = call(&mut server, "window_list", json!({}));
    assert_eq!(allowed["isError"], false, "{allowed}");
    for refused in ["cmux_exec", "cmux_docs", "workspace_list", "app_workspace_rename"] {
        let arguments =
            if refused == "cmux_exec" { json!({"script": "return 1"}) } else { json!({}) };
        let result = call(&mut server, refused, arguments);
        assert_eq!(result["structuredContent"]["error"]["code"], "tool.not_allowed", "{refused}");
    }
    // Inside a script too (`cmux_exec` is refused before a script starts;
    // the check is in `call`, which every script call goes through).
    server.allowed.as_mut().unwrap().insert("cmux_exec".into());
    let script =
        call(&mut server, "cmux_exec", json!({"script": "await cmux.workspace_list({});"}));
    assert_eq!(
        script["structuredContent"]["error"]["cmux"]["error"]["code"], "tool.not_allowed",
        "{script}"
    );

    // Fail closed: an empty value allows nothing; no env is code mode.
    let mut empty = code_mode_server(Fake::with_actions());
    empty.allowed = allowed_tools(Some(" , ".into()));
    let listed =
        empty.handle(&json!({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})).unwrap();
    assert_eq!(listed["result"]["tools"], json!([]));
    assert_eq!(allowed_tools(None), None);
}

/// An agent that asks `cmux_docs` how to show its work to the user gets the
/// guide that names the tools, although no one tool matches every word.
#[test]
fn cmux_docs_answers_a_task_with_its_guide() {
    let mut server = code_mode_server(Fake::with_actions());
    let found = call(&mut server, "cmux_docs", json!({"query": "show the user my work"}));
    let guides = found["structuredContent"]["guides"].as_array().cloned().unwrap_or_default();
    assert_eq!(guides.len(), 1, "{found}");
    let text = guides[0]["text"].as_str().unwrap_or_default();
    assert!(text.contains("app_agent_open") && text.contains("workspace_status_set"), "{text}");
    let plain = call(&mut server, "cmux_docs", json!({"query": "pane split"}));
    assert!(plain["structuredContent"].get("guides").is_none(), "{plain}");
}

/// The tools the acpmux sub-session server's instructions point agents at
/// (`acpmux::subsession_mcp::CMUX_TOOLS`) stay tools of this server, and the
/// instructions reach them the way an agent's `cmux mcp serve` does: in
/// code mode, through a `cmux_exec` script, with `cmux.docs` for arguments.
#[test]
fn the_subsession_servers_instructions_name_real_cmux_tools() {
    let mut server = code_mode_server(Fake::with_actions());
    let rules = acpmux::subsession_mcp::instructions();
    assert!(rules.contains("cmux_exec") && rules.contains("cmux.docs"), "{rules}");
    let names = acpmux::subsession_mcp::CMUX_TOOLS;
    let found = call(&mut server, "cmux_docs", json!({"names": names}));
    assert_eq!(found["structuredContent"]["unknown"], json!([]), "{found}");
    for name in names {
        assert!(rules.contains(&format!("cmux.{name}(")), "the instructions no longer call {name}");
    }
}

#[path = "upstream_tests.rs"]
mod upstream_tests;
