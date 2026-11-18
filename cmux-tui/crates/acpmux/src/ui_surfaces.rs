//! Agent UI surfaces behind `labs.agentUiSurfaces` (plans/cmux-next/agent-ui-surfaces-DESIGN.md),
//! the daemon side of a disposable prototype.
//!
//! - The tap (`hub/tap.rs`) hands every live `tool_call` / `tool_call_update` to [`annotate`].
//!   For the cmux MCP server's `ui_surface` tool, a tool result carrying an
//!   `application/a2ui+json` resource, or an MCP App tool whose `ui://` resource is cached, it
//!   runs the session's [`SurfaceStore`] and writes the normalized `cmux.ui-surface/1` surface
//!   into the logged update's `_meta.acpmux.uiSurface`. The translator (acpmux-book `v1.rs`) puts
//!   that on the tool row as body field `uiSurface`. Streaming input is coalesced to one surface
//!   per call per 16 ms; the call's last update always carries one.
//! - An MCP App's tools and resources are fetched off the tap, on the runtime ([`mcp_http`]),
//!   and cached per server: a call whose resource is not cached yet starts the fetch and draws
//!   from its next update on.
//! - The RPC methods ([`ACTION`], [`CONFIRM`], [`CANCEL`], [`BRIDGE`]) answer the page and the
//!   phone from the same store. Only a confirm sends anything.

pub(crate) mod mcp_http;

/// The pure crate, for the cmux MCP server's `ui_surface` tool (`cmux-tui` `cli/mcp`).
pub use cmux_ui_surfaces as surfaces;

use cmux_ui_surfaces::SurfaceStore;
use cmux_ui_surfaces::actions::Outbound;
use cmux_ui_surfaces::coalesce::Coalescer;
use cmux_ui_surfaces::mcp_apps::{self, ResourceView};
use cmux_ui_surfaces::model::{Source, SourceKind, Status};
use cmux_ui_surfaces::store::Bridge;
use serde_json::{Map, Value, json};
use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU8, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

pub const ACTION: &str = crate::rpc::method::MUX_UI_SURFACE_ACTION;
pub const CONFIRM: &str = crate::rpc::method::MUX_UI_SURFACE_CONFIRM;
pub const CANCEL: &str = crate::rpc::method::MUX_UI_SURFACE_CANCEL;
pub const BRIDGE: &str = crate::rpc::method::MUX_UI_SURFACE_BRIDGE;

/// The `_meta` key the tap writes the surface under, in the logged update.
pub const META_KEY: &str = "uiSurface";

/// The cmux MCP server's tool (`cmux-tui` `cli/mcp/ui_surface_tool.rs`).
pub const TOOL: &str = "ui_surface";

/// Sessions whose surfaces are held; the oldest is dropped past it.
const SESSIONS: usize = 32;
/// How long a read of `labs.agentUiSurfaces` is trusted.
const FLAG_TTL_MS: u64 = 2_000;

static FLAG: AtomicU8 = AtomicU8::new(0);
static FLAG_AT: AtomicU64 = AtomicU64::new(0);

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

/// `labs.agentUiSurfaces`, read from the settings file at most every 2 s: the tap asks per tool
/// update and must not read the disk each time.
pub fn enabled() -> bool {
    let now = now_ms();
    let cached = FLAG.load(Ordering::Relaxed);
    if cached != 0 && now.saturating_sub(FLAG_AT.load(Ordering::Relaxed)) < FLAG_TTL_MS {
        return cached == 2;
    }
    let on = crate::user_settings::agent_ui_surfaces_enabled();
    FLAG.store(if on { 2 } else { 1 }, Ordering::Relaxed);
    FLAG_AT.store(now, Ordering::Relaxed);
    on
}

/// Force the flag in tests.
#[cfg(test)]
pub(crate) fn set_enabled_for_test(on: bool) {
    FLAG.store(if on { 2 } else { 1 }, Ordering::Relaxed);
    FLAG_AT.store(u64::MAX / 2, Ordering::Relaxed);
}

#[derive(Default)]
struct Call {
    name: String,
    surfaces: Vec<String>,
    ended: bool,
    /// An MCP App call's arguments and result, which its view gets after `initialized`
    /// (`ui/notifications/tool-input`, `tool-result`): the agent saw both already.
    input: Option<Value>,
    result: Option<Value>,
    /// An MCP App call drawn without its view, which a fetch started for: `(server, tool)`.
    waiting: Option<(String, String)>,
    /// The tool row's other parts, as the translator reads them: a late surface sends them again.
    row: RowParts,
}

/// A tool row's parts a late surface's patch sends again (acpmux-book `v1.rs` `late_surface`).
#[derive(Default)]
struct RowParts {
    kind: String,
    status: String,
    tool: String,
    title: Option<Value>,
    raw_input: Option<Value>,
    content: Option<Value>,
    /// A part past [`MAX_PART_BYTES`] was not kept: a patch would drop it, so none is sent.
    lossy: bool,
}

impl RowParts {
    /// Takes an update's parts the way the translator does: each present one replaces the last.
    fn take(&mut self, update: &Value) {
        let text = |k: &str| update.get(k).and_then(Value::as_str).filter(|s| !s.is_empty());
        for (slot, k) in [(&mut self.kind, "kind"), (&mut self.status, "status")] {
            if let Some(v) = text(k) {
                *slot = v.to_string();
            }
        }
        if let Some(v) = update.pointer("/_meta/claude/tool").and_then(Value::as_str) {
            self.tool = v.to_string();
        }
        let mut keep = |slot: &mut Option<Value>, k: &str| {
            let Some(v) = update.get(k).filter(|v| !v.is_null()) else { return };
            if v.to_string().len() > MAX_PART_BYTES {
                self.lossy = true;
            } else {
                *slot = Some(v.clone());
            }
        };
        keep(&mut self.title, "title");
        keep(&mut self.raw_input, "rawInput");
        keep(&mut self.content, "content");
        if update.pointer("/_meta/terminal_output/data").is_some() {
            // Appended terminal text is not kept: a patch would drop it.
            self.lossy = true;
        }
    }
}

/// The most bytes of one tool row part kept for a late surface.
const MAX_PART_BYTES: usize = 256 * 1024;

/// What a chat's tap lends its surfaces when a fetch starts: `late` sends a late surface to a task
/// on the hub's scope that appends it to the chat's log as a mux record, and `spawn` runs a fetch
/// on that scope (its owner, which closes it). Only `late` is kept, a channel and no closure: the
/// receiving task holds the hub and chat weakly and ends when the registry drops the sender.
pub struct Host {
    pub late: LateSender,
    pub spawn: Spawn,
}

/// Where a chat's late surfaces go (`Host::late`).
pub type LateSender = tokio::sync::mpsc::UnboundedSender<Value>;

/// Runs a fetch on its owner's scope (`hub.scope`); a gone owner drops it.
pub type Spawn = std::sync::Arc<
    dyn Fn(std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>) + Send + Sync,
>;

/// The mux kind of a late surface (acpmux-book `v1.rs` `late_surface`).
pub const LATE_KIND: &str = "ui_surface";

#[derive(Default)]
struct SessionSurfaces {
    store: SurfaceStore,
    calls: HashMap<String, Call>,
    call_order: VecDeque<String>,
    coalescer: Coalescer<String>,
    harness: String,
    cwd: PathBuf,
    /// Where a late surface goes: the tap's channel to its chat (set when a fetch starts).
    late: Option<LateSender>,
}

impl SessionSurfaces {
    fn call(&mut self, id: &str) -> &mut Call {
        if !self.calls.contains_key(id) {
            self.call_order.push_back(id.to_string());
            while self.call_order.len() > 256 {
                if let Some(old) = self.call_order.pop_front() {
                    self.calls.remove(&old);
                }
            }
        }
        self.calls.entry(id.to_string()).or_default()
    }
}

fn registry() -> &'static Mutex<(HashMap<String, SessionSurfaces>, VecDeque<String>)> {
    static R: OnceLock<Mutex<(HashMap<String, SessionSurfaces>, VecDeque<String>)>> =
        OnceLock::new();
    R.get_or_init(Default::default)
}

fn with_session<T>(session_id: &str, f: impl FnOnce(&mut SessionSurfaces) -> T) -> T {
    let mut guard = registry().lock().unwrap_or_else(|e| e.into_inner());
    let (map, order) = &mut *guard;
    if !map.contains_key(session_id) {
        order.push_back(session_id.to_string());
        while order.len() > SESSIONS {
            if let Some(old) = order.pop_front() {
                map.remove(&old);
            }
        }
    }
    f(map.entry(session_id.to_string()).or_default())
}

/// The tool's name as the harness gives it: Claude's `_meta.claude.toolName`, else the title.
pub fn tool_name(update: &Value) -> Option<String> {
    let meta = update.get("_meta");
    meta.and_then(|m| m.pointer("/claude/toolName"))
        .or_else(|| meta.and_then(|m| m.pointer("/claude/tool")))
        .or_else(|| update.get("title"))
        .and_then(Value::as_str)
        .map(str::to_string)
}

/// Whether `name` is the cmux MCP server's `ui_surface` under any harness prefix
/// (`mcp__cmux__ui_surface`, `cmux.ui_surface`, `cmux/ui_surface`, a trailing `(cmux)`).
pub fn is_ui_surface_tool(name: &str) -> bool {
    let n = name.trim();
    let n = n.split(" (").next().unwrap_or(n);
    n == TOOL
        || [format!("__{TOOL}"), format!(".{TOOL}"), format!("/{TOOL}"), format!(" {TOOL}")]
            .iter()
            .any(|s| n.ends_with(s.as_str()))
}

/// `mcp__<server>__<tool>` split, for an MCP App lookup. The cmux server's own tools are not apps.
pub fn mcp_parts(name: &str) -> Option<(String, String)> {
    let rest = name.strip_prefix("mcp__")?;
    let (server, tool) = rest.split_once("__")?;
    (!server.is_empty() && !tool.is_empty() && server != "cmux")
        .then(|| (server.to_string(), tool.to_string()))
}

/// The A2UI input of a `ui_surface` call: `messages` (an array) or `jsonl` (a string).
fn call_input(raw: &Value) -> Option<Value> {
    match (raw.get("messages"), raw.get("jsonl")) {
        (Some(m @ Value::Array(_)), _) => Some(m.clone()),
        (_, Some(j @ Value::String(_))) => Some(j.clone()),
        _ => None,
    }
}

/// An `application/a2ui+json` resource anywhere shallow in a tool result.
fn a2ui_in_result(v: &Value, depth: usize) -> Option<Value> {
    if depth > 5 {
        return None;
    }
    if v.get("mimeType").and_then(Value::as_str) == Some(cmux_ui_surfaces::a2ui::MIME) {
        let text = v.get("text").and_then(Value::as_str)?;
        return Some(serde_json::from_str(text).unwrap_or(Value::String(text.to_string())));
    }
    match v {
        Value::Array(items) => items.iter().find_map(|i| a2ui_in_result(i, depth + 1)),
        Value::Object(m) => m.values().find_map(|i| a2ui_in_result(i, depth + 1)),
        _ => None,
    }
}

fn surface_id_for(call_id: &str) -> String {
    let clean: String = call_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | ':'))
        .take(100)
        .collect();
    format!("app-{clean}")
}

/// Draw an MCP App call from its server's cached view: a frame for an HTML resource, the A2UI
/// surface for an `application/a2ui+json` one. False when the view is not cached (or not one).
fn attach_view(s: &mut SessionSurfaces, call_id: &str, server: &str, tool: &str) -> bool {
    let Some((resource_uri, view, tools)) = mcp_http::cached_view(&s.harness, &s.cwd, server, tool)
    else {
        return false;
    };
    let source = Source {
        kind: SourceKind::McpApp,
        server: Some(server.to_string()),
        tool: Some(tool.to_string()),
        resource_uri: Some(resource_uri),
        ..Default::default()
    };
    let id = match view {
        ResourceView::Html { html, csp } => {
            let id = surface_id_for(call_id);
            s.store.put_frame(&id, source, html, csp, tools).ok().map(|_| id)
        }
        ResourceView::A2ui(v) => s.store.apply_value(&v, &source, true).changed.first().cloned(),
    };
    let Some(id) = id else { return false };
    s.call(call_id).surfaces.push(id);
    true
}

/// A fetch of MCP App views finished (`mcp_http::prefetch`): every call that waited for one and
/// now has it is drawn, and its surface logged as a `ui_surface` mux record with the row's other
/// parts (acpmux-book `v1.rs` `late_surface`: a body on the open row, else a patch of the settled
/// one). So the first call to a tool draws even when its result came before the fetch did.
pub(crate) fn late_views() {
    if !enabled() {
        return;
    }
    let mut sends: Vec<(LateSender, Value)> = Vec::new();
    {
        let mut guard = registry().lock().unwrap_or_else(|e| e.into_inner());
        for s in guard.0.values_mut() {
            let Some(late) = s.late.clone() else { continue };
            let waiting: Vec<(String, String, String)> = s
                .calls
                .iter()
                .filter(|(_, c)| c.surfaces.is_empty())
                .filter_map(|(id, c)| c.waiting.clone().map(|(sv, t)| (id.clone(), sv, t)))
                .collect();
            for (call_id, server, tool) in waiting {
                if !attach_view(s, &call_id, &server, &tool) {
                    continue;
                }
                let call = s.call(&call_id);
                call.waiting = None;
                let (ended, failed) = (call.ended, call.row.status == "failed");
                if call.row.lossy {
                    continue;
                }
                let ids = call.surfaces.clone();
                if ended {
                    let st = if failed { Status::Error } else { Status::Ready };
                    for id in &ids {
                        if s.store.surface(id).is_some_and(|x| x.status == Status::Streaming) {
                            s.store.set_status(id, st, None);
                        }
                    }
                }
                let Some(surface) = ids.iter().find_map(|id| s.store.surface(id)) else { continue };
                let Ok(surface) = serde_json::to_value(&surface) else { continue };
                let row = &s.call(&call_id).row;
                let mut fields = Map::new();
                fields.insert("toolCallId".into(), json!(call_id));
                fields.insert("surface".into(), json!(surface));
                for (k, v) in [("kind", &row.kind), ("status", &row.status), ("tool", &row.tool)] {
                    if !v.is_empty() {
                        fields.insert(k.into(), json!(v));
                    }
                }
                for (k, v) in
                    [("title", &row.title), ("rawInput", &row.raw_input), ("content", &row.content)]
                {
                    if let Some(v) = v {
                        fields.insert(k.into(), v.clone());
                    }
                }
                let msg = Value::Object(fields);
                sends.push((late.clone(), msg));
            }
        }
    }
    for (late, msg) in sends {
        // A chat whose task ended (its hub closed) gets nothing.
        let _ = late.send(msg);
    }
}

/// Run the session's store for one live tool update and, when a surface is due, write it into
/// the update's `_meta.acpmux.uiSurface`. `meta` gives the chat's harness and folder, read only
/// when an MCP App lookup needs them; `host` logs a late surface into the chat and runs the fetch,
/// asked for only
/// when a fetch starts. Never blocks on I/O: a fetch is spawned.
pub fn annotate(
    session_id: &str,
    update: &mut Value,
    meta: impl FnOnce() -> (String, PathBuf),
    host: impl FnOnce() -> Host,
) -> bool {
    let kind = update.get("sessionUpdate").and_then(Value::as_str).unwrap_or("");
    if !matches!(kind, "tool_call" | "tool_call_update") || !enabled() {
        return false;
    }
    let Some(call_id) = update.get("toolCallId").and_then(Value::as_str).map(str::to_string) else {
        return false;
    };
    let status = update.get("status").and_then(Value::as_str).unwrap_or("");
    let ended = matches!(status, "completed" | "failed");
    let named = tool_name(update);
    let now = now_ms();
    let surface = with_session(session_id, |s| {
        let call = s.call(&call_id);
        if let Some(n) = named {
            call.name = n;
        }
        let name = call.name.clone();
        let mut touched = false;
        if is_ui_surface_tool(&name) {
            if let Some(input) = update.get("rawInput").and_then(call_input)
                && !call.ended
            {
                let old = std::mem::take(&mut call.surfaces);
                for id in &old {
                    s.store.remove(id);
                }
                let source = Source {
                    kind: SourceKind::A2ui,
                    server: Some("cmux".into()),
                    tool: Some(TOOL.into()),
                    ..Default::default()
                };
                let out = s.store.apply_value(&input, &source, ended);
                let title = update.pointer("/rawInput/title").and_then(Value::as_str);
                for id in &out.changed {
                    s.store.set_title(id, title);
                }
                s.call(&call_id).surfaces = out.changed;
                touched = true;
            }
        } else if let Some(input) = ["rawOutput", "content"]
            .iter()
            .find_map(|k| update.get(*k).and_then(|v| a2ui_in_result(v, 0)))
        {
            let source = Source {
                kind: SourceKind::A2ui,
                server: mcp_parts(&name).map(|p| p.0),
                tool: Some(name.clone()),
                ..Default::default()
            };
            let out = s.store.apply_value(&input, &source, true);
            let call = s.call(&call_id);
            for id in out.changed {
                if !call.surfaces.contains(&id) {
                    call.surfaces.push(id);
                }
            }
            touched = true;
        } else if let Some((server, tool)) = mcp_parts(&name)
            && s.calls.get(&call_id).is_some_and(|c| c.surfaces.is_empty())
        {
            if s.harness.is_empty() {
                (s.harness, s.cwd) = meta();
            }
            if attach_view(s, &call_id, &server, &tool) {
                touched = true;
                s.call(&call_id).waiting = None;
            } else {
                // Not fetched yet: the fetch starts now, at the call's first update, and a view it
                // brings after this call's row settled is logged as a late surface.
                s.call(&call_id).waiting = Some((server.clone(), tool));
                let Host { late, spawn } = host();
                if s.late.as_ref().is_none_or(LateSender::is_closed) {
                    s.late = Some(late);
                }
                mcp_http::prefetch(&s.harness, &s.cwd, &server, &spawn);
            }
        }
        let call = s.call(&call_id);
        if mcp_parts(&call.name).is_some() {
            call.row.take(update);
            let small = |v: &&Value| !v.is_null() && v.to_string().len() <= 256 * 1024;
            if let Some(input) = update.get("rawInput").filter(small) {
                call.input = Some(input.clone());
            }
            if let Some(result) = update.get("rawOutput").filter(small) {
                call.result = Some(result.clone());
            }
        }
        let ids = call.surfaces.clone();
        if ended {
            call.ended = true;
        }
        if ids.is_empty() {
            return None;
        }
        for id in &ids {
            if ended {
                let st = if status == "failed" { Status::Error } else { Status::Ready };
                if s.store.surface(id).is_some_and(|x| x.status == Status::Streaming) {
                    s.store.set_status(id, st, None);
                }
            }
        }
        let due = if ended {
            s.coalescer.finish(&call_id);
            true
        } else {
            touched && s.coalescer.offer(call_id.clone(), now)
        };
        if !due {
            return None;
        }
        ids.iter().find_map(|id| s.store.surface(id))
    });
    let Some(surface) = surface else { return false };
    let Ok(value) = serde_json::to_value(&surface) else { return false };
    let Some(obj) = update.as_object_mut() else { return false };
    let meta = obj.entry("_meta").or_insert_with(|| Value::Object(Map::new()));
    let Some(meta) = meta.as_object_mut() else { return false };
    let acpmux = meta.entry("acpmux").or_insert_with(|| Value::Object(Map::new()));
    if let Some(m) = acpmux.as_object_mut() {
        m.insert(META_KEY.to_string(), value);
        return true;
    }
    false
}

fn refused(e: impl std::fmt::Display) -> crate::rpc::RpcError {
    crate::rpc::RpcError::invalid_params(e.to_string())
}

fn values_of(params: &Value) -> Map<String, Value> {
    params.get("values").and_then(Value::as_object).cloned().unwrap_or_default()
}

fn str_of<'a>(params: &'a Value, key: &str) -> Result<&'a str, crate::rpc::RpcError> {
    params.get(key).and_then(Value::as_str).ok_or_else(|| refused(format!("{key} is required")))
}

/// `_acpmux/ui_surface_action {sessionId, surfaceId, actionId, values}`: the Pending the card
/// shows. Sends nothing.
pub fn action(session_id: &str, params: &Value) -> Result<Value, crate::rpc::RpcError> {
    if !enabled() {
        return Err(refused("agent UI surfaces are off (labs.agentUiSurfaces)"));
    }
    let surface = str_of(params, "surfaceId")?;
    let action = str_of(params, "actionId")?;
    let values = values_of(params);
    with_session(session_id, |s| {
        if !s.store.contains(surface) {
            return Err(refused(
                "this surface is not loaded (drawn before acpmux restarted?); ask the agent to show it again",
            ));
        }
        let p = s.store.request_action(surface, action, &values).map_err(refused)?;
        serde_json::to_value(p).map_err(refused)
    })
}

/// `_acpmux/ui_surface_cancel {sessionId, surfaceId, requestId}`.
pub fn cancel(session_id: &str, params: &Value) -> Result<Value, crate::rpc::RpcError> {
    let request = str_of(params, "requestId")?;
    let cancelled = with_session(session_id, |s| s.store.cancel(request));
    Ok(json!({ "cancelled": cancelled }))
}

/// What a confirmed request does, once the store released it.
pub enum Confirmed {
    /// Send this text to the agent as the person's turn.
    Prompt(String),
    /// Call this tool on the app's server; answer the view's request with the result.
    ToolCall {
        server: Option<String>,
        tool: String,
        arguments: Value,
        view_request_id: Option<Value>,
    },
    /// The page opens the link.
    OpenLink { url: String, view_request_id: Option<Value> },
}

/// `_acpmux/ui_surface_confirm {sessionId, surfaceId, requestId, values?}`.
pub fn confirm(session_id: &str, params: &Value) -> Result<Confirmed, crate::rpc::RpcError> {
    if !enabled() {
        return Err(refused("agent UI surfaces are off (labs.agentUiSurfaces)"));
    }
    let request = str_of(params, "requestId")?;
    let values = params.get("values").and_then(Value::as_object).cloned();
    let stamp = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    let out = with_session(session_id, |s| s.store.confirm(request, values.as_ref(), &stamp))
        .map_err(refused)?;
    Ok(match out {
        Outbound::Agent { .. } => Confirmed::Prompt(out.prompt_text().unwrap_or_default()),
        Outbound::ToolCall { server, tool, arguments, view_request_id, .. } => {
            Confirmed::ToolCall { server, tool, arguments, view_request_id }
        }
        Outbound::OpenLink { url, view_request_id, .. } => {
            Confirmed::OpenLink { url, view_request_id }
        }
    })
}

/// Run a confirmed MCP App `tools/call` on its server.
pub async fn call_tool(
    session_id: &str,
    server: Option<String>,
    tool: &str,
    arguments: Value,
) -> Result<Value, crate::rpc::RpcError> {
    let server = server.ok_or_else(|| refused("the app names no server"))?;
    let (harness, cwd) = with_session(session_id, |s| (s.harness.clone(), s.cwd.clone()));
    mcp_http::call_tool(&harness, &cwd, &server, tool, arguments).await.map_err(refused)
}

/// A JSON-RPC answer to the view's request `id` (none for a notification).
pub fn view_reply(id: Option<&Value>, outcome: Result<Value, String>) -> Option<Value> {
    let id = id.filter(|v| !v.is_null())?;
    Some(match outcome {
        Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
        Err(message) => {
            json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32000, "message": message}})
        }
    })
}

/// `_acpmux/ui_surface_bridge {sessionId, surfaceId, message}`: one JSON-RPC message from an MCP
/// App view, classified (design table). The answer is
/// `{reply?, notify?[], height?, blocked?, pending?, draft?}`: `reply` is the JSON-RPC response
/// to post to the view, `notify` the host notifications to post after it, `height` the frame's
/// new clamped height, `blocked` why it was refused, `pending` the confirm strip to show, `draft`
/// text for the composer (`ui/message`; the person presses Send).
pub async fn bridge(session_id: &str, params: &Value) -> Result<Value, crate::rpc::RpcError> {
    if !enabled() {
        return Err(refused("agent UI surfaces are off (labs.agentUiSurfaces)"));
    }
    let surface = str_of(params, "surfaceId")?.to_string();
    let message = params.get("message").cloned().unwrap_or(Value::Null);
    let id = message.get("id").cloned();
    let (decision, server, harness, cwd, io) = with_session(session_id, |s| {
        let d = s.store.bridge(&surface, &message);
        let server = s.store.surface(&surface).and_then(|x| x.source.server);
        let io = s
            .calls
            .values()
            .find(|c| c.surfaces.iter().any(|x| x == &surface))
            .map(|c| (c.input.clone(), c.result.clone()));
        (d, server, s.harness.clone(), s.cwd.clone(), io)
    });
    let decision = decision.map_err(refused)?;
    let mut out = Map::new();
    match decision {
        Bridge::Refused(reason) => {
            tracing::info!(
                session = session_id,
                surface,
                reason,
                "ui surface: view message refused"
            );
            if let Some(r) = view_reply(id.as_ref(), Err(format!("blocked: {reason}"))) {
                out.insert("reply".into(), r);
            }
            out.insert("blocked".into(), Value::String(reason));
        }
        Bridge::NeedsConfirm(p) => {
            // The view's request is answered when the person confirms or cancels.
            out.insert("pending".into(), serde_json::to_value(p).map_err(refused)?);
        }
        Bridge::Allowed(a) => {
            use mcp_apps::Allowed;
            match a {
                Allowed::Initialize => {
                    let result = json!({"protocolVersion": "2026-01-26",
                        "hostInfo": {"name": "cmux", "version": crate::build_info::VERSION},
                        "hostCapabilities": {"openLinks": {}, "serverTools": {}},
                        "hostContext": {"displayMode": "inline", "availableDisplayModes": ["inline"]}});
                    if let Some(r) = view_reply(id.as_ref(), Ok(result)) {
                        out.insert("reply".into(), r);
                    }
                }
                Allowed::Initialized => {
                    // Nothing goes to the view before this; now its call's input and result.
                    let mut notify = Vec::new();
                    if let Some((input, result)) = io {
                        if let Some(arguments) = input {
                            notify.push(
                                json!({"jsonrpc": "2.0", "method": "ui/notifications/tool-input",
                                "params": {"arguments": arguments}}),
                            );
                        }
                        if let Some(result) = result {
                            notify.push(
                                json!({"jsonrpc": "2.0", "method": "ui/notifications/tool-result",
                                "params": result}),
                            );
                        }
                    }
                    out.insert("notify".into(), Value::Array(notify));
                }
                Allowed::SizeChanged { height } => {
                    out.insert("height".into(), json!(height));
                }
                Allowed::Draft { text } => {
                    if let Some(r) = view_reply(id.as_ref(), Ok(json!({}))) {
                        out.insert("reply".into(), r);
                    }
                    out.insert("draft".into(), Value::String(text));
                }
                Allowed::ResourceRead { uri } => {
                    let result = match server {
                        Some(server) => {
                            mcp_http::read_resource(&harness, &cwd, &server, &uri).await
                        }
                        None => Err("the app names no server".to_string()),
                    };
                    if let Some(r) = view_reply(id.as_ref(), result) {
                        out.insert("reply".into(), r);
                    }
                }
            }
        }
    }
    Ok(Value::Object(out))
}

#[cfg(test)]
mod tests;
