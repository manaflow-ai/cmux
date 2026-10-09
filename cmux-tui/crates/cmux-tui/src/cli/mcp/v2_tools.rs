//! MCP tools for the session daemon's `cmux.protocol/2` operations,
//! generated from `spec/resource-operations-v2.json`: one tool per read or
//! mutation operation the curated `cmux` CLI offers, named after the
//! operation (`workspace.list` is `workspace_list`). Streams, connection
//! control and the `cmux-tui`-only scopes are excluded with a reason
//! (`exclusions`); the parity test pins both lists to the CLI.

use std::sync::OnceLock;

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

use super::super::command::{RequestPlan, WireOperation};
use super::super::federation;
use super::Exclusion;
use super::schema::{self, Generator};
use super::transport::{self, Prefix};

const CATALOG_JSON: &str =
    include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../spec/resource-operations-v2.json"));

/// A read with an array result and no `limit` of its own answers one page:
/// `limit` items (default, maximum) from `offset`.
pub(super) const DEFAULT_PAGE: usize = 100;
pub(super) const MAX_PAGE: usize = 1000;

/// `terminal_wait` and `terminal_wait_exit` wait at most this long: the
/// server answers one call at a time, so an unbounded wait would stop every
/// later call. The daemon waits forever when `timeout_ms` is absent.
const DEFAULT_WAIT_MS: u64 = 30_000;
const MAX_WAIT_MS: u64 = 300_000;

const STREAM_REASON: &str =
    "Opens a stream; MCP tools are request and response. Read the state with a list or get tool.";
const CONNECTION_REASON: &str =
    "Connection control: it applies to one socket connection, which ends with the tool call.";

/// Read and mutation operations the curated `cmux` CLI does not offer
/// (`cmux-tui`-only scopes), with the reason. The parity test checks that
/// `cmux` refuses each one too.
/// MCP clients act as the local user (an agent in a pane, the Chief's own
/// turns): conversation reads and writes would let them read the person's
/// chats and write as the person. Home, `cmux chief` and the person's own
/// scripts (`cmux-tui conversation`) use the operations instead.
const CONVERSATION_REASON: &str = "A conversation belongs to the person: MCP clients act as the local user, so conversations stay with Home, cmux chief and cmux-tui conversation.";

/// The Chief's engine and turn are the owner's (the daemon refuses an
/// agent-bound connection); an MCP client is an agent acting as the user.
const CHIEF_REASON: &str = "The Chief's engine and turn are the owner's: cmux chief, Home and the owner's scripts control them, never an agent.";

pub(super) const EXCLUDED: &[(&str, &str)] = &[
    ("conversation.list", CONVERSATION_REASON),
    ("conversation.get", CONVERSATION_REASON),
    ("conversation.history", CONVERSATION_REASON),
    ("conversation.search", CONVERSATION_REASON),
    ("conversation.send", CONVERSATION_REASON),
    ("conversation.typing", CONVERSATION_REASON),
    ("conversation.draft", CONVERSATION_REASON),
    ("chief.engine.get", CHIEF_REASON),
    ("chief.engine.set", CHIEF_REASON),
    ("chief.stop", CHIEF_REASON),
    ("machine.list", MACHINE_REASON),
    ("machine.get", MACHINE_REASON),
    ("session.list", MACHINE_REASON),
    ("session.open", MACHINE_REASON),
    ("session.get", MACHINE_REASON),
    ("session.snapshot", MACHINE_REASON),
    ("session.ping", MACHINE_REASON),
    ("session.creation.resolve", MACHINE_REASON),
    ("session.shutdown", LIFECYCLE_REASON),
    ("session.reload_config", LIFECYCLE_REASON),
    ("session.terminal_defaults.update", SESSION_SETTING_REASON),
    ("session.window.title.set", SESSION_SETTING_REASON),
    ("session.window.title.clear", SESSION_SETTING_REASON),
    ("session.journal.append", JOURNAL_REASON),
    ("session.journal.checkpoint.create", JOURNAL_REASON),
    ("session.journal.checkpoint.list", JOURNAL_REASON),
    ("session.journal.hook.list", JOURNAL_REASON),
    ("session.journal.hook.put", JOURNAL_REASON),
    ("session.journal.producer.list", JOURNAL_REASON),
    ("session.journal.producer.put", JOURNAL_REASON),
    ("session.journal.restore.preview", JOURNAL_REASON),
    ("session.journal.segment.list", JOURNAL_REASON),
    ("session.journal.segment.seal", JOURNAL_REASON),
    ("client.list", CLIENT_REASON),
    ("client.get", CLIENT_REASON),
    ("frontend_projection.get", PROJECTION_REASON),
    ("frontend_projection.put", PROJECTION_REASON),
    ("pairing_request.list", PAIRING_REASON),
    ("pairing_request.resolve", PAIRING_REASON),
    ("sidebar_view.ensure", SIDEBAR_REASON),
    ("sidebar_view.get", SIDEBAR_REASON),
    ("sidebar_view.input", SIDEBAR_REASON),
    ("sidebar_view.reload", SIDEBAR_REASON),
    ("sidebar_view.resize", SIDEBAR_REASON),
    ("window_record.list", WINDOW_RECORD_REASON),
    ("window_record.put", WINDOW_RECORD_REASON),
    ("window_record.delete", WINDOW_RECORD_REASON),
    ("sidebar_layout.get", SIDEBAR_LAYOUT_REASON),
    ("sidebar_layout.update", SIDEBAR_LAYOUT_REASON),
    ("workspace.ensure_home", HOME_REASON),
    ("workspace.agent_folder.set", AGENT_FOLDER_REASON),
];

const MACHINE_REASON: &str =
    "Machine and session plumbing in the cmux-tui-only scopes; the curated cmux CLI omits it.";
const LIFECYCLE_REASON: &str = "Session lifecycle (ends every terminal or reloads the daemon); \
     cmux-tui-only, and the cmux CLI's `server` scope does not send it.";
const SESSION_SETTING_REASON: &str = "A session-wide setting in the cmux-tui-only scope.";
const JOURNAL_REASON: &str =
    "Session journal plumbing for producers and hooks in the cmux-tui-only scope.";
const CLIENT_REASON: &str = "Connection-scoped client records in the cmux-tui-only scope.";
const PROJECTION_REASON: &str = "Frontend projection records the app writes; cmux-tui-only.";
const PAIRING_REASON: &str =
    "Device pairing approval: a person approves a pairing, never an agent; cmux-tui-only.";
const WINDOW_RECORD_REASON: &str = "A window record has one writer, the app that hosts the \
     window; the CLI omits it too, and window_list reads the app's windows.";
const SIDEBAR_LAYOUT_REASON: &str = "The Mac app's sidebar layout: agents edit it through the \
     app's sidebar actions (action tools), which keep the app's intent log.";
const SIDEBAR_REASON: &str = "TUI sidebar plugin views in the cmux-tui-only scope.";
const HOME_REASON: &str = "The hosting app creates its one home workspace on connect; the CLI \
     never offers it (workspace-kind-v1).";
const AGENT_FOLDER_REASON: &str = "Where a workspace's agents run: only the user sets it, through \
     the verified app after a gesture (gate A2); an agent never does.";

pub(super) fn catalog() -> &'static Value {
    static CATALOG: OnceLock<Value> = OnceLock::new();
    CATALOG.get_or_init(|| serde_json::from_str(CATALOG_JSON).expect("the checked-in catalog"))
}

pub(super) struct V2Tool {
    pub name: String,
    pub operation: ResourceOperation,
    pub wire: &'static str,
    pub mutation: bool,
    pub paginated: bool,
    descriptor: &'static Value,
}

/// One page of an array result.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Page {
    pub offset: usize,
    pub limit: usize,
}

/// A tool call as a request: the plan, the session it routes to (from the
/// `session` argument or a `<session>:` qualified id) and the page.
pub(super) struct CallPlan {
    pub plan: RequestPlan,
    pub session: Option<String>,
    pub page: Option<Page>,
    /// Arguments that hold a unique id prefix, resolved before sending.
    pub prefixes: Vec<Prefix>,
}

pub(super) fn tools() -> &'static [V2Tool] {
    static TOOLS: OnceLock<Vec<V2Tool>> = OnceLock::new();
    TOOLS.get_or_init(build)
}

pub(super) fn find(name: &str) -> Option<&'static V2Tool> {
    tools().iter().find(|tool| tool.name == name)
}

fn build() -> Vec<V2Tool> {
    let mut tools = Vec::new();
    for (wire, descriptor) in catalog()["operations"].as_object().into_iter().flatten() {
        let class = descriptor["class"].as_str().unwrap_or_default();
        if !matches!(class, "read" | "mutation") || excluded_reason(wire).is_some() {
            continue;
        }
        let Ok(operation) =
            serde_json::from_value::<ResourceOperation>(Value::String(wire.clone()))
        else {
            continue;
        };
        let fields = &descriptor["params"]["fields"];
        tools.push(V2Tool {
            name: tool_name(wire),
            operation,
            wire: wire.as_str(),
            mutation: class == "mutation",
            paginated: class == "read"
                && descriptor["result"]["kind"] == "array"
                && fields.get("limit").is_none(),
            descriptor,
        });
    }
    tools
}

pub(super) fn tool_name(wire: &str) -> String {
    wire.replace('.', "_")
}

fn excluded_reason(wire: &str) -> Option<&'static str> {
    EXCLUDED.iter().find(|(name, _)| *name == wire).map(|(_, reason)| *reason)
}

/// Every catalog operation that is not a tool, with the reason.
pub(super) fn exclusions() -> Vec<Exclusion> {
    let mut excluded = Vec::new();
    for (wire, descriptor) in catalog()["operations"].as_object().into_iter().flatten() {
        let reason = match descriptor["class"].as_str().unwrap_or_default() {
            "stream_open" => Some(STREAM_REASON),
            "connection_control" => Some(CONNECTION_REASON),
            _ if serde_json::from_value::<ResourceOperation>(Value::String(wire.clone()))
                .is_err() =>
            {
                Some("This binary does not know the operation.")
            }
            _ => excluded_reason(wire),
        };
        if let Some(reason) = reason {
            excluded.push(Exclusion {
                kind: "operation",
                name: wire.clone(),
                reason: reason.to_owned(),
            });
        }
    }
    excluded
}

impl V2Tool {
    pub(super) fn descriptor_json(&self) -> Value {
        let verb = self.wire.rsplit('.').next().unwrap_or_default();
        let destructive = self.mutation
            && (matches!(verb, "close" | "delete" | "clear" | "ungroup")
                || verb.starts_with("remove"));
        json!({
            "name": self.name,
            "description": self.description(),
            "inputSchema": self.input_schema(),
            "annotations": {
                "readOnlyHint": !self.mutation,
                "destructiveHint": destructive,
                "idempotentHint": !self.mutation,
                "openWorldHint": false,
            },
        })
    }

    fn selectors(&self) -> impl Iterator<Item = (&'static String, &'static Value)> {
        self.descriptor["params"]["selectors"].as_object().into_iter().flatten()
    }

    fn fields(&self) -> &'static Value {
        &self.descriptor["params"]["fields"]
    }

    fn description(&self) -> String {
        let target = self.descriptor["target"].as_str().unwrap_or("resource").replace('_', " ");
        let mut text = format!(
            "{} (cmux.protocol/2 `{}`). {}",
            summary(self.wire, &target),
            self.wire,
            if self.mutation {
                "Changes state on the cmux session daemon. A call that fails with state \
                 in_progress may have applied; retry it with the idempotency_key the error \
                 returns."
            } else {
                "Reads the cmux session daemon and changes nothing."
            }
        );
        if let Some(constraints) = schema::joined(&self.descriptor["params"]["constraints"]) {
            text.push(' ');
            text.push_str(&constraints);
        }
        if self.waits() {
            text.push_str(&format!(
                " timeout_ms defaults to {DEFAULT_WAIT_MS} and may be at most {MAX_WAIT_MS}."
            ));
        }
        if self.paginated {
            text.push_str(&format!(
                " Answers {{items, total, offset, next_offset}}; page with offset and limit \
                 (default {DEFAULT_PAGE}, at most {MAX_PAGE})."
            ));
        }
        text
    }

    pub(super) fn input_schema(&self) -> Value {
        let generator = Generator::new(catalog());
        let mut properties = Map::new();
        let mut required = Vec::new();
        properties.insert(
            "session".into(),
            json!({
                "type": "string",
                "minLength": 1,
                "description": "The named cmux session to use, as `cmux --session`. \
                    Default: the session the cmux CLI uses here.",
            }),
        );
        for (selector, requiredness) in self.selectors() {
            if matches!(selector.as_str(), "machine" | "session") {
                continue;
            }
            properties.insert(selector.clone(), schema::id(selector));
            if requiredness == "required" {
                required.push(Value::String(selector.clone()));
            }
        }
        for (name, field) in self.fields().as_object().into_iter().flatten() {
            properties.insert(name.clone(), generator.field(field));
            if field["required"] == Value::Bool(true) {
                required.push(Value::String(name.clone()));
            }
        }
        if self.mutation {
            properties.insert(
                "idempotency_key".into(),
                json!({
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 128,
                    "description": "Names this change so a retry cannot apply it twice. \
                        Generated when absent; a failed call returns it.",
                }),
            );
        }
        if self.paginated {
            properties.insert(
                "offset".into(),
                json!({"type": "integer", "minimum": 0, "description": "First item to return."}),
            );
            properties.insert(
                "limit".into(),
                json!({
                    "type": "integer",
                    "minimum": 1,
                    "maximum": MAX_PAGE,
                    "description": format!("Items to return (default {DEFAULT_PAGE})."),
                }),
            );
        }
        json!({
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false,
        })
    }

    /// The request for a tool call. Selectors and id fields take a public id,
    /// a unique prefix (resolved with a list read on the request's own
    /// connection), `<session>:<id>`, `current` or a name.
    pub(super) fn plan(&self, arguments: &Map<String, Value>) -> Result<CallPlan, Value> {
        let selectors = self.descriptor["params"]["selectors"].as_object();
        let fields = self.fields().as_object();
        let mut params = Map::new();
        for scope in ["machine", "session"] {
            if selectors.is_some_and(|selectors| selectors.contains_key(scope)) {
                params.insert(scope.into(), json!("current"));
            }
        }
        let mut session = None;
        let mut prefixes = Vec::new();
        let mut idempotency_key = None;
        let (mut offset, mut limit) = (None, None);
        for (name, value) in arguments {
            let selector = selectors.is_some_and(|selectors| selectors.contains_key(name))
                && !matches!(name.as_str(), "machine" | "session");
            let field = fields.and_then(|fields| fields.get(name));
            match name.as_str() {
                "session" => set_session(&mut session, text(name, value)?)?,
                "idempotency_key" if self.mutation => {
                    let key = text(name, value)?;
                    cmux_tui_core::resource::validate_idempotency_key(key)
                        .map_err(|error| invalid(error.message))?;
                    idempotency_key = Some(key.to_owned());
                }
                "offset" if self.paginated => offset = Some(count(name, value, usize::MAX)?),
                "limit" if self.paginated => limit = Some(count(name, value, MAX_PAGE)?.max(1)),
                _ if selector => {
                    let id = self.id_argument(name, name, text(name, value)?, &mut session)?;
                    if let Some(step) = id.1 {
                        prefixes.push(step);
                    }
                    params.insert(name.clone(), Value::String(id.0));
                }
                _ if field.is_some() => {
                    let resource = field.and_then(|field| {
                        (field["type"]["kind"] == "resource_id")
                            .then(|| field["type"]["resource"].as_str())
                            .flatten()
                    });
                    let value = match (resource, value.as_str()) {
                        (Some(resource), Some(raw)) => {
                            let id = self.id_argument(name, resource, raw, &mut session)?;
                            if let Some(step) = id.1 {
                                prefixes.push(step);
                            }
                            Value::String(id.0)
                        }
                        _ => value.clone(),
                    };
                    params.insert(name.clone(), value);
                }
                _ => return Err(invalid(format!("{} has no argument {name:?}", self.name))),
            }
        }
        if self.waits() {
            let timeout = match params.get("timeout_ms") {
                None => DEFAULT_WAIT_MS,
                Some(value) => {
                    value.as_str().and_then(|text| text.parse().ok()).unwrap_or(u64::MAX)
                }
            };
            if timeout > MAX_WAIT_MS {
                return Err(invalid(format!(
                    "timeout_ms must be a decimal string of at most {MAX_WAIT_MS} for an MCP call"
                )));
            }
            params.insert("timeout_ms".into(), Value::String(timeout.to_string()));
        }
        let page = self
            .paginated
            .then(|| Page { offset: offset.unwrap_or(0), limit: limit.unwrap_or(DEFAULT_PAGE) });
        Ok(CallPlan {
            plan: RequestPlan {
                operation: WireOperation::Typed(self.operation),
                params: Value::Object(params),
                idempotency_key,
                stream: false,
                resolve: Vec::new(),
                view: Default::default(),
            },
            session,
            page,
            prefixes,
        })
    }

    fn waits(&self) -> bool {
        matches!(
            self.operation,
            ResourceOperation::TerminalWait | ResourceOperation::TerminalWaitExit
        )
    }

    /// An id argument without its `<session>:` qualifier, and the lookup
    /// that resolves it when it is a unique prefix.
    fn id_argument(
        &self,
        field: &str,
        resource: &str,
        raw: &str,
        session: &mut Option<String>,
    ) -> Result<(String, Option<Prefix>), Value> {
        let (qualifier, id) = match federation::qualified(raw) {
            Some((session, id)) => (Some(session), id),
            None => (None, raw),
        };
        if let Some(qualifier) = qualifier {
            set_session(session, qualifier)?;
        }
        let lookup = schema::id_prefix(resource)
            .filter(|prefix| transport::is_partial_id(id, prefix))
            .and_then(|_| schema::prefix_list(resource))
            .map(|list| Prefix { field: field.to_owned(), list });
        Ok((id.to_owned(), lookup))
    }
}

fn set_session(slot: &mut Option<String>, session: &str) -> Result<(), Value> {
    match slot {
        Some(existing) if existing != session => Err(invalid(format!(
            "the arguments name two sessions, {existing:?} and {session:?}; one call reaches one session"
        ))),
        _ => {
            *slot = Some(session.to_owned());
            Ok(())
        }
    }
}

fn text<'a>(name: &str, value: &'a Value) -> Result<&'a str, Value> {
    value
        .as_str()
        .filter(|text| !text.is_empty())
        .ok_or_else(|| invalid(format!("{name} must be a non-empty string")))
}

fn count(name: &str, value: &Value, maximum: usize) -> Result<usize, Value> {
    value
        .as_u64()
        .and_then(|value| usize::try_from(value).ok())
        .filter(|value| *value <= maximum)
        .ok_or_else(|| invalid(format!("{name} must be an integer from 0 to {maximum}")))
}

/// A local validation error in the owners' error shape.
pub(super) fn invalid(message: impl Into<String>) -> Value {
    json!({
        "code": "validation.invalid",
        "message": message.into(),
        "details": {},
        "retryable": false,
    })
}

/// One page of an array result, with the total and the next offset.
pub(super) fn paginate(value: Value, page: Page) -> Value {
    let Value::Array(items) = value else { return value };
    let total = items.len();
    let offset = page.offset.min(total);
    let end = offset.saturating_add(page.limit).min(total);
    let items = items.into_iter().skip(offset).take(end - offset).collect::<Vec<_>>();
    json!({
        "items": items,
        "total": total,
        "offset": offset,
        "next_offset": if end < total { json!(end) } else { Value::Null },
    })
}

/// The lead sentence of a tool description.
fn summary(wire: &str, target: &str) -> String {
    let mut parts = wire.split('.');
    let _resource = parts.next();
    let action = parts.collect::<Vec<_>>().join(" ").replace('_', " ");
    match action.as_str() {
        "list" => format!("List the session's {target}s"),
        "get" => format!("Show one {target}"),
        "create" => format!("Create a {target}"),
        "close" => format!("Close a {target}"),
        "rename" => format!("Rename a {target}"),
        "update" => format!("Change a {target}'s properties"),
        "move" => format!("Move a {target}"),
        "focus" => format!("Focus a {target} in the session"),
        "delete" => format!("Delete a {target}"),
        "pin" | "unpin" => format!("{} a {target}", capitalized(&action)),
        "set" => format!("Set the {target}"),
        "clear" => format!("Clear the {target}"),
        "append" => format!("Append a line to the {target}"),
        "reopen" => format!("Reopen a {target}"),
        "run" => format!("Run a command in a new terminal of the {target}"),
        "create terminal" => "Open a terminal tab in a pane".into(),
        "create browser" => "Open a browser tab in a pane".into(),
        "split" => "Split a pane and open a new one beside it".into(),
        "swap" => "Swap two panes".into(),
        "zoom" => "Zoom or unzoom a pane".into(),
        "neighbor get" => "Find the pane next to a pane in a direction".into(),
        "focus direction" => "Focus the neighboring pane in a direction".into(),
        "split ratio set" => "Set the ratio of a split".into(),
        "viewport width set" => "Set a pane's column width".into(),
        "input write" => format!("Type text or bytes into a {target}"),
        "input keys" => format!("Send key presses to a {target}"),
        "input mouse" => format!("Send a mouse event to a {target}"),
        "input focus" => format!("Send a focus-in or focus-out event to a {target}"),
        "input key" => format!("Send a key press to a {target}"),
        "input text" => format!("Type text into a {target}"),
        "input wheel" => format!("Send a scroll-wheel event to a {target}"),
        "screen read" => "Read a terminal's visible screen as text".into(),
        "history read" => "Read a terminal's scrollback history".into(),
        "history clear" => "Clear a terminal's scrollback history".into(),
        "output read" => "Read a terminal's output after a cursor".into(),
        "state read" => "Read a terminal's modes and cursor state".into(),
        "process get" => "Show the process that runs in a terminal".into(),
        "wait" => "Wait until text appears on a terminal's screen, or the timeout".into(),
        "wait exit" => "Wait until a terminal's process exits, or the timeout".into(),
        "copy" => "Copy text from a terminal's screen or history".into(),
        "viewport scroll" => "Scroll a terminal's viewport".into(),
        "project" => "Show a terminal in another tab".into(),
        "layout apply" => "Replace a workspace's layout".into(),
        "layout export" => "Export a screen's layout".into(),
        "layout undo" => "Undo the last layout change of a screen".into(),
        "place" => "Place a workspace in a window or room".into(),
        "placement list" => "List where workspaces are placed".into(),
        "add tabs" | "remove tabs" | "add screens" | "remove screens" => {
            format!("{} of a {target}", capitalized(&action))
        }
        "ungroup" => format!("Dissolve a {target}, keeping its members"),
        "save" => format!("Save a {target}"),
        "follow" => format!("Follow a {target}"),
        "ack" => "Mark notifications read".into(),
        "report" => "Report an agent's state for a terminal".into(),
        "navigate" => "Navigate a browser to a URL".into(),
        "back" | "forward" => format!("Go {action} in a browser's history"),
        "reload" => "Reload a browser's page".into(),
        "activate" => format!("Activate a {target}"),
        _ => format!("{} a {target}", capitalized(&action)),
    }
}

fn capitalized(text: &str) -> String {
    let mut characters = text.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().chain(characters).collect(),
        None => String::new(),
    }
}
