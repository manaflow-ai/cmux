//! The Chief's Memory Inspector (`ChiefMemoryInspectorModel` and its `ChiefMemory*` values): decoding
//! the memory server's answers with Swift's defaults, which calls each action makes, and how the trail,
//! the edit text and the undo pick follow. Swift makes the calls and keeps the model's state.

use super::text::trim;
use crate::ops::{OpError, parse, reply};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Value, json};

pub const UNREACHABLE_TEXT: &str = "The Chief’s memory did not answer. Start the Chief (send it a message in Chief), then try again.";
pub const MALFORMED_TEXT: &str =
    "The Chief answered in a way this version of cmux does not understand.";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Status {
    #[serde(default)]
    pub messages: u64,
    #[serde(default, rename = "nodes_built")]
    pub nodes_built: u64,
    #[serde(default)]
    pub stale: Vec<String>,
    #[serde(default)]
    pub editable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Line {
    pub name: String,
    pub level: i64,
    pub start: u64,
    pub n: u64,
    #[serde(default)]
    pub built: bool,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub stale: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Message {
    pub id: u64,
    pub kind: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Node {
    #[serde(flatten)]
    pub line: Line,
    #[serde(default)]
    pub children: Vec<Line>,
    #[serde(default)]
    pub message: Option<Message>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchHit {
    pub name: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub snippet: String,
}

impl SearchHit {
    pub fn id(&self) -> String {
        format!("{}:{}", self.kind, self.name)
    }
}

/// `ChiefMemoryTarget`: a message by id or a summary line by name; on the wire `{message}` or `{node}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    Message(u64),
    Line(String),
}

impl Target {
    pub fn query_value(&self) -> String {
        match self {
            Target::Message(id) => format!("message:{id}"),
            Target::Line(name) => format!("node:{name}"),
        }
    }
}

#[derive(Deserialize, Serialize)]
struct RawTarget {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    message: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    node: Option<String>,
}

impl Serialize for Target {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        match self {
            Target::Message(id) => RawTarget { message: Some(*id), node: None },
            Target::Line(name) => RawTarget { message: None, node: Some(name.clone()) },
        }
        .serialize(s)
    }
}

impl<'de> Deserialize<'de> for Target {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let raw = RawTarget::deserialize(d)?;
        // A message wins when both are there, as in Swift.
        match (raw.message, raw.node) {
            (Some(id), _) => Ok(Target::Message(id)),
            (None, Some(name)) => Ok(Target::Line(name)),
            (None, None) => Err(serde::de::Error::custom("no message or node")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Change {
    pub id: u64,
    #[serde(default)]
    pub at: String,
    pub op: String,
    pub target: Target,
    #[serde(default)]
    pub old: String,
    #[serde(default)]
    pub new: String,
    #[serde(default)]
    pub stale: Vec<String>,
    #[serde(default)]
    pub undone: bool,
}

#[derive(Deserialize)]
struct ViewBody {
    lines: Vec<Line>,
}

#[derive(Deserialize)]
struct SearchBody {
    hits: Vec<SearchHit>,
}

#[derive(Deserialize)]
struct ChangesBody {
    changes: Vec<Change>,
}

/// One call to the memory server.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Call {
    pub path: &'static str,
    pub query: serde_json::Map<String, Value>,
}

fn call_to(path: &'static str, pairs: &[(&str, String)]) -> Call {
    Call {
        path,
        query: pairs.iter().map(|(k, v)| ((*k).to_string(), Value::String(v.clone()))).collect(),
    }
}

fn node_call(name: &str) -> Call {
    call_to("/api/node", &[("name", name.to_string())])
}

/// Decodes one answer (`status`, `view`, `node`, `search` or `changes`) the way Swift's decoders do;
/// `None` is `ChiefMemoryError.malformed`.
pub fn decode(kind: &str, body: &Value) -> Option<Value> {
    fn go<T: for<'de> Deserialize<'de> + Serialize>(body: &Value) -> Option<Value> {
        serde_json::to_value(T::deserialize(body).ok()?).ok()
    }
    match kind {
        "status" => go::<Status>(body),
        "node" => go::<Node>(body),
        "view" => ViewBody::deserialize(body).ok().map(|b| json!({"lines": b.lines})),
        "search" => SearchBody::deserialize(body).ok().map(|b| {
            let hits: Vec<Value> = b
                .hits
                .iter()
                .map(
                    |h| json!({"id": h.id(), "name": h.name, "type": h.kind, "snippet": h.snippet}),
                )
                .collect();
            json!({"hits": hits})
        }),
        "changes" => ChangesBody::deserialize(body).ok().map(|b| json!({"changes": b.changes})),
        _ => None,
    }
}

/// `reload()`'s calls in order: status, the view, the changes, then the open line if any.
pub fn reload_calls(trail: &[String]) -> Vec<Call> {
    let mut calls = vec![
        call_to("/api/status", &[]),
        call_to("/api/view", &[]),
        call_to("/api/memory/changes", &[]),
    ];
    if let Some(name) = trail.last() {
        calls.push(node_call(name));
    }
    calls
}

/// `open(_:)`'s trail once the node arrives: back to a name already on it, else one deeper.
pub fn open_trail(trail: &[String], name: &str) -> Vec<String> {
    let mut next = trail.to_vec();
    match next.iter().position(|n| n == name) {
        Some(k) => next.truncate(k + 1),
        None => next.push(name.to_string()),
    }
    next
}

/// `text(of:)`: the text an edit starts from, from the open node, its children, then the view.
pub fn text_of(target: &Target, detail: Option<&Node>, lines: &[Line]) -> Option<String> {
    match target {
        Target::Message(id) => {
            detail?.message.as_ref().filter(|m| m.id == *id).map(|m| m.text.clone())
        }
        Target::Line(name) => {
            if let Some(d) = detail.filter(|d| &d.line.name == name) {
                return d.line.text.clone();
            }
            let children = detail.map(|d| d.children.as_slice()).unwrap_or(&[]);
            match children.iter().find(|l| &l.name == name) {
                Some(child) => child.text.clone(),
                None => lines.iter().find(|l| &l.name == name).and_then(|l| l.text.clone()),
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TrailRequest {
    #[serde(default)]
    trail: Vec<String>,
    #[serde(default)]
    name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DecodeRequest {
    kind: String,
    #[serde(default)]
    data: Option<Value>,
    #[serde(default)]
    body: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TextOfRequest {
    target: Target,
    #[serde(default)]
    detail: Option<Node>,
    #[serde(default)]
    lines: Vec<Line>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChangeRequest {
    action: String,
    #[serde(default)]
    target: Option<Target>,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    change: Option<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
#[serde(tag = "kind")]
enum ErrorKind {
    #[serde(rename = "unreachable")]
    Unreachable,
    #[serde(rename = "refused")]
    Refused {
        #[serde(default)]
        message: String,
    },
    #[serde(rename = "malformed")]
    Malformed,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DescribeRequest {
    error: ErrorKind,
    #[serde(default)]
    unreachable_text: Option<String>,
    #[serde(default)]
    malformed_text: Option<String>,
}

pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "memoryDecode" => {
            let req: DecodeRequest = parse(request)?;
            let body = match (req.data, req.body) {
                (Some(v), _) => Some(v),
                (None, Some(text)) => serde_json::from_str(&text).ok(),
                _ => None,
            };
            let value = body.as_ref().and_then(|b| decode(&req.kind, b));
            reply(&json!({"malformed": value.is_none(), "value": value}))
        }
        "memoryReloadCalls" => {
            let req: TrailRequest = parse(request)?;
            reply(&json!({"calls": reload_calls(&req.trail)}))
        }
        "memoryOpen" => {
            let req: TrailRequest = parse(request)?;
            reply(
                &json!({"call": node_call(&req.name), "trail": open_trail(&req.trail, &req.name)}),
            )
        }
        "memoryBack" => {
            let req: TrailRequest = parse(request)?;
            if req.trail.is_empty() {
                return reply(
                    &json!({"changed": false, "trail": [], "clearDetail": false, "call": null}),
                );
            }
            let mut trail = req.trail;
            trail.pop();
            let call = trail.last().map(|n| node_call(n));
            reply(
                &json!({"changed": true, "clearDetail": call.is_none(), "call": call, "trail": trail}),
            )
        }
        "memorySearch" => {
            #[derive(Deserialize)]
            struct Req {
                #[serde(default)]
                query: String,
            }
            let req: Req = parse(request)?;
            let words = trim(&req.query);
            if words.is_empty() {
                return reply(&json!({"clearHits": true, "call": null}));
            }
            reply(
                &json!({"clearHits": false, "call": call_to("/api/search", &[("q", words.to_string())])}),
            )
        }
        "memoryTextOf" => {
            let req: TextOfRequest = parse(request)?;
            reply(&json!({"text": text_of(&req.target, req.detail.as_ref(), &req.lines)}))
        }
        "memoryChangeCall" => {
            let req: ChangeRequest = parse(request)?;
            let need_target =
                || req.target.clone().ok_or_else(|| OpError::Invalid("target".into()));
            let call = match req.action.as_str() {
                "edit" => call_to(
                    "/api/memory/edit",
                    &[
                        ("target", need_target()?.query_value()),
                        ("text", req.text.clone().unwrap_or_default()),
                    ],
                ),
                "delete" => {
                    call_to("/api/memory/delete", &[("target", need_target()?.query_value())])
                }
                "undo" => {
                    let id = req.change.ok_or_else(|| OpError::Invalid("change".into()))?;
                    call_to("/api/memory/undo", &[("change", id.to_string())])
                }
                other => return Err(OpError::Invalid(format!("action {other}"))),
            };
            // A change that went through reloads; an edit that went through ends.
            reply(&json!({"call": call, "reloadAfter": true, "endEditAfter": req.action == "edit"}))
        }
        "memoryUndoLast" => {
            #[derive(Deserialize)]
            struct Req {
                #[serde(default)]
                changes: Vec<Change>,
            }
            let req: Req = parse(request)?;
            let call = req
                .changes
                .iter()
                .find(|c| !c.undone)
                .map(|c| call_to("/api/memory/undo", &[("change", c.id.to_string())]));
            reply(&json!({"call": call}))
        }
        "memoryIsStale" => {
            #[derive(Deserialize)]
            struct Req {
                #[serde(default)]
                status: Option<Status>,
                name: String,
            }
            let req: Req = parse(request)?;
            let stale = req.status.is_some_and(|s| s.stale.contains(&req.name));
            reply(&json!({"stale": stale}))
        }
        "memoryDescribe" => {
            let req: DescribeRequest = parse(request)?;
            let text = match req.error {
                ErrorKind::Unreachable => {
                    req.unreachable_text.unwrap_or_else(|| UNREACHABLE_TEXT.into())
                }
                ErrorKind::Refused { message } => message,
                ErrorKind::Malformed => req.malformed_text.unwrap_or_else(|| MALFORMED_TEXT.into()),
            };
            reply(&json!({"text": text}))
        }
        "memoryTargetQuery" => {
            #[derive(Deserialize)]
            struct Req {
                target: Target,
            }
            let req: Req = parse(request)?;
            reply(&json!({"query": req.target.query_value()}))
        }
        _ => Err(OpError::Unknown),
    }
}
