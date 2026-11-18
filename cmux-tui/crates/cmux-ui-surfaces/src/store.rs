//! The stateful side: surfaces by id, their component definitions and the
//! host-held data model, and at most one pending action per surface.

use crate::a2ui::{self, Message};
use crate::actions::Outbound;
use crate::catalog::{ActionDef, Builder, Built, Catalog};
use crate::functions::{self, Ctx};
use crate::mcp_apps::{self, Allowed, Proposal, ToolInfo, ViewContext, ViewDecision};
use crate::model::*;
use crate::{Refusal, caps, pointer, text};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, VecDeque};

#[derive(Clone, Debug)]
enum CatalogChoice {
    Known(Catalog),
    Unknown(String),
}

#[derive(Clone, Debug)]
struct A2uiState {
    catalog: CatalogChoice,
    send_data_model: bool,
    comps: BTreeMap<String, Value>,
    dropped: usize,
    model: Value,
}

#[derive(Clone, Debug)]
struct FrameState {
    html: String,
    csp: String,
    height: u32,
    tools: Vec<ToolInfo>,
    initialized: bool,
}

#[derive(Clone, Debug)]
enum Body {
    A2ui(A2uiState),
    Frame(FrameState),
}

#[derive(Clone, Debug)]
struct Held {
    pending: Pending,
    outbound: Outbound,
}

#[derive(Clone, Debug)]
struct Entry {
    source: Source,
    title: Option<String>,
    status: Status,
    error: Option<String>,
    body: Body,
    held: Option<Held>,
}

/// What applying a batch of messages did.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ApplyOutcome {
    /// Surfaces created or changed, in first-touch order.
    pub changed: Vec<String>,
    pub deleted: Vec<String>,
    pub errors: Vec<String>,
    /// A2UI client messages to send back to the agent with the tool result
    /// (`rendererFunctionResponse`, `error`). Never user actions.
    pub replies: Vec<Value>,
}

/// The decision on one MCP App view message, with any Pending registered.
#[derive(Clone, Debug, PartialEq)]
pub enum Bridge {
    Allowed(Allowed),
    NeedsConfirm(Pending),
    Refused(String),
}

#[derive(Clone, Debug, Default)]
pub struct SurfaceStore {
    entries: BTreeMap<String, Entry>,
    order: VecDeque<String>,
    next_request: u64,
}

fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id.chars().all(|c| c.is_alphanumeric() || matches!(c, '_' | '-' | '.' | ':'))
}

fn short(s: &str) -> String {
    if s.chars().count() <= 120 {
        return s.to_string();
    }
    let mut out: String = s.chars().take(117).collect();
    out.push('…');
    out
}

impl SurfaceStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn ids(&self) -> impl Iterator<Item = &str> {
        self.order.iter().map(String::as_str)
    }

    pub fn contains(&self, surface_id: &str) -> bool {
        self.entries.contains_key(surface_id)
    }

    fn insert(&mut self, id: String, entry: Entry) {
        if self.entries.insert(id.clone(), entry).is_none() {
            self.order.push_back(id);
            while self.order.len() > caps::SURFACES {
                if let Some(old) = self.order.pop_front() {
                    self.entries.remove(&old);
                }
            }
        }
    }

    pub fn remove(&mut self, surface_id: &str) -> bool {
        self.order.retain(|s| s != surface_id);
        self.entries.remove(surface_id).is_some()
    }

    /// Apply A2UI input: a message, an array, `{messages: [...]}`, or JSONL
    /// text in a JSON string. `complete == false` while input still streams.
    pub fn apply_value(&mut self, input: &Value, source: &Source, complete: bool) -> ApplyOutcome {
        let msgs = match input {
            Value::String(s) => a2ui::parse_jsonl(s, complete),
            other => a2ui::parse_value(other),
        };
        self.apply_all(msgs, source)
    }

    pub fn apply_all(
        &mut self,
        msgs: Vec<Result<Message, Refusal>>,
        source: &Source,
    ) -> ApplyOutcome {
        let mut out = ApplyOutcome::default();
        for m in msgs {
            let res = m.and_then(|m| self.apply(m, source, &mut out));
            if let Err(e) = res {
                out.errors.push(e.0);
            }
        }
        out
    }

    fn touch(out: &mut ApplyOutcome, id: &str) {
        if !out.changed.iter().any(|c| c == id) {
            out.changed.push(id.to_string());
        }
    }

    fn a2ui_mut(&mut self, id: &str) -> Result<&mut A2uiState, Refusal> {
        match self.entries.get_mut(id).map(|e| &mut e.body) {
            Some(Body::A2ui(s)) => Ok(s),
            Some(Body::Frame(_)) => {
                Err(Refusal::new(format!("surface {id:?} is an MCP App frame")))
            }
            None => Err(Refusal::new(format!(
                "no surface {:?} (send createSurface first)",
                text::clean(id)
            ))),
        }
    }

    fn apply(
        &mut self,
        msg: Message,
        source: &Source,
        out: &mut ApplyOutcome,
    ) -> Result<(), Refusal> {
        match msg {
            Message::CreateSurface {
                surface_id,
                catalog_id,
                send_data_model,
                components,
                data_model,
            } => {
                if !valid_id(&surface_id) {
                    return Err(Refusal::new("surfaceId must be 1-128 letters, digits, _ - . :"));
                }
                if self.entries.contains_key(&surface_id) {
                    return Err(Refusal::new(format!("surface {surface_id:?} already exists")));
                }
                // The spec makes a missing catalogId an error; agents using
                // the ui_surface tool often omit it, so it means basic here.
                let catalog = match catalog_id.as_deref() {
                    None => CatalogChoice::Known(Catalog::Basic),
                    Some(id) => match Catalog::from_id(id) {
                        Some(Catalog::Mcp) | None => CatalogChoice::Unknown(id.to_string()),
                        Some(c) => CatalogChoice::Known(c),
                    },
                };
                let mut src = source.clone();
                src.catalog_id = catalog_id.map(|c| text::clean(&c));
                self.insert(
                    surface_id.clone(),
                    Entry {
                        source: src,
                        title: None,
                        status: Status::Streaming,
                        error: None,
                        body: Body::A2ui(A2uiState {
                            catalog,
                            send_data_model,
                            comps: BTreeMap::new(),
                            dropped: 0,
                            model: Value::Object(Map::new()),
                        }),
                        held: None,
                    },
                );
                Self::touch(out, &surface_id);
                if let Some(model) = data_model {
                    self.set_model(&surface_id, None, model)?;
                }
                if !components.is_empty() {
                    self.update_components(&surface_id, components, out)?;
                }
            }
            Message::UpdateComponents { surface_id, components } => {
                self.update_components(&surface_id, components, out)?;
                Self::touch(out, &surface_id);
            }
            Message::UpdateDataModel { surface_id, path, value } => {
                self.set_model(&surface_id, path.as_deref(), value)?;
                Self::touch(out, &surface_id);
            }
            Message::DeleteSurface { surface_id } => {
                if self.remove(&surface_id) {
                    out.deleted.push(surface_id.clone());
                    out.changed.retain(|c| c != &surface_id);
                }
            }
            Message::CallRendererFunction { function_call_id, call, surface_id } => {
                let name = call.get("@call").and_then(Value::as_str).unwrap_or("");
                let reply = if name == "openUrl" || !functions::ALLOWED.contains(&name) {
                    json!({"code": "NOT_ALLOWED", "message": format!("{name} cannot be called by the agent on this host")})
                } else {
                    let model = surface_id
                        .as_deref()
                        .and_then(|s| self.a2ui_mut(s).ok().map(|st| st.model.clone()))
                        .unwrap_or(Value::Null);
                    let mut args = Map::new();
                    for (k, v) in call.get("args").and_then(Value::as_object).into_iter().flatten()
                    {
                        args.insert(k.clone(), functions::eval(v, Ctx::root(&model)));
                    }
                    let value = functions::call(name, &args, Ctx::root(&model), 0);
                    out.replies.push(json!({"version": "1.0", "rendererFunctionResponse": {"functionCallId": function_call_id, "value": value}}));
                    return Ok(());
                };
                out.replies.push(json!({"version": "1.0", "rendererFunctionResponse": {"functionCallId": function_call_id, "error": reply}}));
            }
            Message::AgentFunctionResponse(_) => {
                // This host never sends callAgentFunction, so there is
                // nothing to match a response to.
            }
        }
        Ok(())
    }

    fn update_components(
        &mut self,
        id: &str,
        components: Vec<Value>,
        out: &mut ApplyOutcome,
    ) -> Result<(), Refusal> {
        let st = self.a2ui_mut(id)?;
        let mut bad = 0usize;
        for c in components {
            let ok =
                c.get("id").and_then(Value::as_str).filter(|i| valid_id(i)).map(str::to_string);
            let has_kind =
                c.get("component").and_then(Value::as_str).is_some_and(|k| !k.is_empty());
            let Some(cid) = ok.filter(|_| has_kind) else {
                bad += 1;
                continue;
            };
            if !st.comps.contains_key(&cid) && st.comps.len() >= caps::COMPONENTS {
                st.dropped += 1;
                continue;
            }
            st.comps.insert(cid, c);
        }
        if bad > 0 {
            out.errors.push(format!(
                "{bad} component(s) without a valid id and component name were skipped"
            ));
        }
        Ok(())
    }

    fn set_model(&mut self, id: &str, path: Option<&str>, value: Value) -> Result<(), Refusal> {
        let st = self.a2ui_mut(id)?;
        let before = st.model.clone();
        if !pointer::set(&mut st.model, path.unwrap_or(""), value) {
            return Err(Refusal::new(format!(
                "cannot write data model path {:?}",
                text::clean(path.unwrap_or(""))
            )));
        }
        if serde_json::to_string(&st.model).map_or(usize::MAX, |s| s.len()) > caps::SURFACE_BYTES {
            st.model = before;
            return Err(Refusal::new("the data model is over its 256 KB cap; update ignored"));
        }
        Ok(())
    }

    pub fn set_status(&mut self, surface_id: &str, status: Status, error: Option<String>) {
        if let Some(e) = self.entries.get_mut(surface_id) {
            e.status = status;
            e.error = error.map(|s| text::clean(&s));
        }
    }

    /// Mark every surface ready (the tool call finished).
    pub fn finish_all(&mut self) {
        for e in self.entries.values_mut() {
            if e.status == Status::Streaming {
                e.status = Status::Ready;
            }
        }
    }

    pub fn set_title(&mut self, surface_id: &str, title: Option<&str>) {
        if let Some(e) = self.entries.get_mut(surface_id) {
            e.title = title.map(text::clean).filter(|t| !t.is_empty());
        }
    }

    /// An MCP App HTML resource drawn in the sandboxed frame.
    pub fn put_frame(
        &mut self,
        surface_id: &str,
        source: Source,
        html: String,
        csp: String,
        tools: Vec<ToolInfo>,
    ) -> Result<(), Refusal> {
        if !valid_id(surface_id) {
            return Err(Refusal::new("invalid surface id"));
        }
        if html.len() > caps::SURFACE_BYTES * 4 {
            return Err(Refusal::new("the app's HTML is over 1 MB"));
        }
        self.remove(surface_id);
        self.insert(
            surface_id.to_string(),
            Entry {
                source,
                title: None,
                status: Status::Ready,
                error: None,
                body: Body::Frame(FrameState { html, csp, height: 320, tools, initialized: false }),
                held: None,
            },
        );
        Ok(())
    }

    fn built(st: &A2uiState) -> Option<Built> {
        match st.catalog {
            CatalogChoice::Known(cat) => {
                Some(Builder::new(&st.comps, cat, &st.model).build(st.dropped))
            }
            CatalogChoice::Unknown(_) => None,
        }
    }

    /// The normalized surface the renderers draw.
    pub fn surface(&self, surface_id: &str) -> Option<Surface> {
        let e = self.entries.get(surface_id)?;
        let mut status = e.status;
        let mut error = e.error.clone();
        let (root, frame) = match &e.body {
            Body::A2ui(st) => match (&st.catalog, Self::built(st)) {
                (CatalogChoice::Known(_), Some(b)) => {
                    if !st.comps.contains_key("root") && status != Status::Streaming {
                        status = Status::Error;
                        error.get_or_insert_with(|| "The surface has no root component".into());
                    }
                    (b.root, None)
                }
                (CatalogChoice::Unknown(id), _) => {
                    let id = text::clean(id);
                    status = Status::Error;
                    error = Some(format!("Unsupported catalog {id}"));
                    (
                        Node::fallback(
                            "root",
                            format!("This surface uses a catalog cmux does not draw: {id}"),
                        ),
                        None,
                    )
                }
                (CatalogChoice::Known(_), None) => {
                    (Node::fallback("root", "Nothing to draw"), None)
                }
            },
            Body::Frame(f) => (
                Node::fallback("root", "Open on Mac: this app runs in a web frame"),
                Some(Frame { html: f.html.clone(), csp: f.csp.clone(), height: f.height }),
            ),
        };
        let mut s = Surface {
            schema: SCHEMA.to_string(),
            surface_id: surface_id.to_string(),
            source: e.source.clone(),
            status,
            error,
            title: e.title.clone(),
            root,
            frame,
            pending: e.held.as_ref().map(|h| h.pending.clone()),
        };
        if s.frame.is_none()
            && serde_json::to_string(&s).map_or(usize::MAX, |j| j.len()) > caps::SURFACE_BYTES
        {
            s.root =
                Node::fallback("root", "This surface is over the 256 KB cap and was not drawn");
        }
        Some(s)
    }

    pub fn surfaces(&self) -> Vec<Surface> {
        self.order.iter().filter_map(|id| self.surface(id)).collect()
    }

    fn apply_values(
        st: &mut A2uiState,
        binds: &std::collections::BTreeSet<String>,
        values: &Map<String, Value>,
    ) -> Result<(), Refusal> {
        for (path, v) in values {
            if !binds.contains(path) {
                return Err(Refusal::new(format!(
                    "{:?} is not a field on this surface",
                    text::clean(path)
                )));
            }
            let ok = match v {
                Value::String(s) => s.len() <= caps::STRING_BYTES,
                Value::Bool(_) | Value::Number(_) | Value::Null => true,
                Value::Array(items) => {
                    items.len() <= caps::TABLE_ROWS
                        && items
                            .iter()
                            .all(|i| i.as_str().is_some_and(|s| s.len() <= caps::STRING_BYTES))
                }
                Value::Object(_) => false,
            };
            if !ok {
                return Err(Refusal::new(format!(
                    "value for {:?} is not a field value",
                    text::clean(path)
                )));
            }
            pointer::set(&mut st.model, path, v.clone());
        }
        Ok(())
    }

    /// Resolve an action to what Confirm would send, with the summary.
    fn compose(
        surface_id: &str,
        st: &A2uiState,
        built: &Built,
        action_id: &str,
    ) -> Result<(Outbound, String, Vec<Send>, String), Refusal> {
        let def = built.actions.get(action_id).ok_or_else(|| {
            Refusal::new(format!("no action {:?} on this surface", text::clean(action_id)))
        })?;
        match def {
            ActionDef::OpenUrl { url, scope, index } => {
                let raw = functions::eval_text(url, Ctx { model: &st.model, scope, index: *index });
                let url = mcp_apps::https_url(&raw)
                    .ok_or_else(|| Refusal::new("only https links open"))?;
                let summary = format!("Open {url}");
                let sends = vec![Send { label: "link".into(), value: url.clone() }];
                Ok((
                    Outbound::OpenLink {
                        surface_id: surface_id.into(),
                        url: url.clone(),
                        view_request_id: None,
                    },
                    summary,
                    sends,
                    format!("link:{url}"),
                ))
            }
            ActionDef::Event {
                name,
                user_message,
                context,
                extra,
                scope,
                index,
                source_component,
                checks,
            } => {
                let ctx = Ctx { model: &st.model, scope, index: *index };
                for (cond, msg) in checks {
                    let ok = match functions::eval(cond, ctx) {
                        Value::Bool(b) => b,
                        Value::Object(m) => {
                            m.get("valid").and_then(Value::as_bool).unwrap_or(false)
                        }
                        _ => false,
                    };
                    if !ok {
                        return Err(Refusal::new(text::clean(msg)));
                    }
                }
                let mut resolved = Map::new();
                let mut sends = Vec::new();
                for (k, v) in context {
                    let val = functions::eval(v, ctx);
                    sends.push(Send {
                        label: text::clean(k),
                        value: text::clean(&text::display(&val)),
                    });
                    resolved.insert(k.clone(), val);
                }
                for (k, path) in extra {
                    let val = pointer::get(&st.model, path).cloned().unwrap_or(Value::Null);
                    sends.push(Send { label: k.clone(), value: text::clean(&text::display(&val)) });
                    resolved.insert(k.clone(), val);
                }
                let mut action = json!({
                    "name": name,
                    "surfaceId": surface_id,
                    "sourceComponentId": source_component,
                    "timestamp": "",
                    "context": resolved,
                });
                let user_text = user_message
                    .as_ref()
                    .map(|m| text::clean(&functions::eval_text(m, ctx)))
                    .filter(|m| !m.is_empty());
                if let Some(m) = &user_text {
                    if let Some(fields) = action.as_object_mut() {
                        fields.insert("userMessage".into(), Value::String(m.clone()));
                    }
                    sends.push(Send { label: "message".into(), value: m.clone() });
                }
                let metadata = st.send_data_model.then(|| {
                    for (path, v) in pointer::leaves(&st.model) {
                        sends.push(Send { label: path, value: text::clean(&text::display(v)) });
                    }
                    json!({"a2uiRendererDataModel": {"version": "1.0", "surfaces": {surface_id: st.model}}})
                });
                let listed = sends
                    .iter()
                    .map(|s| format!("{} = {}", s.label, short(&s.value)))
                    .collect::<Vec<_>>();
                let summary = if listed.is_empty() {
                    format!("Send \"{name}\" to the agent (no values)")
                } else {
                    format!("Send \"{name}\" to the agent with: {}", listed.join(", "))
                };
                let message = json!({"version": "1.0", "action": action});
                Ok((
                    Outbound::Agent {
                        surface_id: surface_id.into(),
                        message,
                        metadata,
                        summary: summary.clone(),
                    },
                    summary,
                    sends,
                    "agent".into(),
                ))
            }
        }
    }

    fn next_request_id(&mut self) -> String {
        self.next_request += 1;
        format!("r{}", self.next_request)
    }

    /// The person pressed a button. `values` are the renderer's current field
    /// values keyed by `bind`. Nothing is sent: the answer is the Pending the
    /// card shows; it replaces any earlier Pending on the surface.
    pub fn request_action(
        &mut self,
        surface_id: &str,
        action_id: &str,
        values: &Map<String, Value>,
    ) -> Result<Pending, Refusal> {
        let request_id = self.next_request_id();
        let e = self.entries.get_mut(surface_id).ok_or_else(|| Refusal::new("no such surface"))?;
        e.held = None;
        let Body::A2ui(st) = &mut e.body else {
            return Err(Refusal::new("an MCP App's actions come through its bridge"));
        };
        let built = Self::built(st).ok_or_else(|| Refusal::new("unsupported catalog"))?;
        Self::apply_values(st, &built.binds, values)?;
        let built = Self::built(st).ok_or_else(|| Refusal::new("unsupported catalog"))?;
        let (outbound, summary, sends, target) = Self::compose(surface_id, st, &built, action_id)?;
        let pending =
            Pending { request_id, action_id: action_id.to_string(), summary, sends, target };
        e.held = Some(Held { pending: pending.clone(), outbound });
        Ok(pending)
    }

    /// The renderer's field values changed (no button pressed). A held
    /// Pending whose sends would change is dropped. Returns whether it was.
    pub fn values_changed(
        &mut self,
        surface_id: &str,
        values: &Map<String, Value>,
    ) -> Result<bool, Refusal> {
        let e = self.entries.get_mut(surface_id).ok_or_else(|| Refusal::new("no such surface"))?;
        let Body::A2ui(st) = &mut e.body else { return Ok(false) };
        let built = Self::built(st).ok_or_else(|| Refusal::new("unsupported catalog"))?;
        Self::apply_values(st, &built.binds, values)?;
        let Some(held) = &e.held else { return Ok(false) };
        let fresh = Self::compose(surface_id, st, &built, &held.pending.action_id).ok();
        if fresh.is_none_or(|(o, ..)| o.fingerprint() != held.outbound.fingerprint()) {
            e.held = None;
            return Ok(true);
        }
        Ok(false)
    }

    /// The person confirmed `request_id`. `values` (optional) are the
    /// renderer's field values now; if they, or the agent's data model
    /// updates, change what would be sent, the request is stale and dropped.
    /// `timestamp` is ISO 8601, stamped into an A2UI action.
    pub fn confirm(
        &mut self,
        request_id: &str,
        values: Option<&Map<String, Value>>,
        timestamp: &str,
    ) -> Result<Outbound, Refusal> {
        let (surface_id, e) = self
            .entries
            .iter_mut()
            .find(|(_, e)| e.held.as_ref().is_some_and(|h| h.pending.request_id == request_id))
            .ok_or_else(|| Refusal::new("this request was cancelled or replaced"))?;
        let surface_id = surface_id.clone();
        let held =
            e.held.take().ok_or_else(|| Refusal::new("this request was cancelled or replaced"))?;
        if let Body::A2ui(st) = &mut e.body {
            let built = Self::built(st).ok_or_else(|| Refusal::new("unsupported catalog"))?;
            if let Some(v) = values {
                Self::apply_values(st, &built.binds, v)?;
            }
            let built = Self::built(st).ok_or_else(|| Refusal::new("unsupported catalog"))?;
            let fresh = Self::compose(&surface_id, st, &built, &held.pending.action_id)
                .map_err(|_| Refusal::new("this action is no longer on the surface"))?;
            if fresh.0.fingerprint() != held.outbound.fingerprint() {
                return Err(Refusal::new(
                    "the values changed since the summary; press the button again",
                ));
            }
        }
        let mut out = held.outbound;
        if let Outbound::Agent { message, .. } = &mut out
            && let Some(action) = message.get_mut("action").and_then(Value::as_object_mut)
        {
            action.insert("timestamp".into(), Value::String(timestamp.to_string()));
        }
        Ok(out)
    }

    pub fn cancel(&mut self, request_id: &str) -> bool {
        for e in self.entries.values_mut() {
            if e.held.as_ref().is_some_and(|h| h.pending.request_id == request_id) {
                e.held = None;
                return true;
            }
        }
        false
    }

    /// One JSON-RPC message from an MCP App view.
    pub fn bridge(&mut self, surface_id: &str, msg: &Value) -> Result<Bridge, Refusal> {
        let request_id = self.next_request_id();
        let e = self.entries.get_mut(surface_id).ok_or_else(|| Refusal::new("no such surface"))?;
        let Body::Frame(f) = &mut e.body else {
            return Err(Refusal::new("this surface has no app frame"));
        };
        let decision = mcp_apps::classify_view_message(
            ViewContext { tools: &f.tools, initialized: f.initialized },
            msg,
        );
        let view_id = msg.get("id").cloned();
        Ok(match decision {
            ViewDecision::Allowed(a) => {
                match &a {
                    Allowed::Initialized => f.initialized = true,
                    Allowed::SizeChanged { height } => f.height = *height,
                    _ => {}
                }
                Bridge::Allowed(a)
            }
            ViewDecision::Refused(r) => Bridge::Refused(r),
            ViewDecision::NeedsConfirm(p) => {
                let server = e.source.server.clone();
                let sid = surface_id.to_string();
                let (outbound, summary, sends, target) = match p {
                    Proposal::ToolCall { tool, arguments } => {
                        let sends: Vec<Send> = match &arguments {
                            Value::Object(m) => m
                                .iter()
                                .map(|(k, v)| Send {
                                    label: text::clean(k),
                                    value: text::clean(&text::display(v)),
                                })
                                .collect(),
                            other => vec![Send {
                                label: "arguments".into(),
                                value: text::clean(&other.to_string()),
                            }],
                        };
                        let listed = sends
                            .iter()
                            .map(|s| format!("{} = {}", s.label, short(&s.value)))
                            .collect::<Vec<_>>()
                            .join(", ");
                        let summary = format!(
                            "Call tool \"{}\" on {} with: {}",
                            text::clean(&tool),
                            server
                                .as_deref()
                                .map(text::clean)
                                .unwrap_or_else(|| "its server".into()),
                            if listed.is_empty() { "no arguments".into() } else { listed }
                        );
                        let target = format!("tool:{}", text::clean(&tool));
                        (
                            Outbound::ToolCall {
                                surface_id: sid,
                                server,
                                tool,
                                arguments,
                                view_request_id: view_id,
                            },
                            summary,
                            sends,
                            target,
                        )
                    }
                    Proposal::OpenLink { url } => (
                        Outbound::OpenLink {
                            surface_id: sid,
                            url: url.clone(),
                            view_request_id: view_id,
                        },
                        format!("Open {url}"),
                        vec![Send { label: "link".into(), value: url.clone() }],
                        format!("link:{url}"),
                    ),
                };
                let pending =
                    Pending { request_id, action_id: "bridge".into(), summary, sends, target };
                e.held = Some(Held { pending: pending.clone(), outbound });
                Bridge::NeedsConfirm(pending)
            }
        })
    }
}
