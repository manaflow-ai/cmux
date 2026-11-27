//! `owner.fork_run`: cmux-platform's durable copy-on-write fork runs
//! (`/v1/workspaces/{workspace}/fork-runs`, `src/api/ForkRuns.ts`). One source machine is captured
//! once and restored into one child machine per harness; one ready child is then selected as the
//! run's result. `args.verb` picks the route:
//!
//! - `start` (the default): `POST …/fork-runs {clientKey, sourceMachine, session?, prompt?,
//!   harnesses}`. Retrying with the same `clientKey` answers the same run.
//! - `get`: `GET …/fork-runs/{run}`.
//! - `select`: `POST …/fork-runs/{run}/select {childId}`. Selecting another child after one was
//!   selected is the platform's `fork_run.selection_conflict`.
//!
//! Each answers the run as [`fork_run`] reads it. The platform answers the run itself; a body
//! wrapped as the Worker's `{ok: true, value}` is read too. A refusal's code is read from
//! `{error: {code, message}}` or from the body's own `code` and `message` (the platform's tagged
//! errors).

use std::time::Duration;

use reqwest::Method;
use serde_json::{Map, Value, json};

use super::http::{Body, Http, path_text};
use super::{Failure, optional_text, text};

/// The platform's id rule for a workspace, run or child (`Id` in ForkRuns.ts is 1 to 256 bytes;
/// the path parts here are also kept to bytes that need no escaping).
fn is_id(id: &str) -> bool {
    (1..=256).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.' | b':'))
}

fn id<'a>(args: &'a Map<String, Value>, name: &str, what: &str) -> Result<&'a str, Failure> {
    let value = text(args, name)?;
    if is_id(value) { Ok(value) } else { Err(Failure::Transport(format!("not a {what} id"))) }
}

pub(crate) async fn run(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let workspace = id(args, "workspace", "workspace")?;
    match optional_text(args, "verb").unwrap_or("start") {
        "start" => {
            let mut body = json!({
                "clientKey": text(args, "clientKey")?,
                "sourceMachine": id(args, "sourceMachine", "Cloud machine")?,
                "harnesses": args.get("harnesses").cloned().unwrap_or_else(|| json!([])),
            });
            for name in ["session", "prompt"] {
                let value = optional_text(args, name).filter(|v| !v.is_empty());
                if let (Some(value), Some(body)) = (value, body.as_object_mut()) {
                    body.insert(name.to_owned(), json!(value));
                }
            }
            let segments = ["v1", "workspaces", workspace, "fork-runs"];
            send(http, Method::POST, &segments, Some(body), Duration::from_secs(180)).await
        }
        "get" => {
            let run = id(args, "run", "fork run")?;
            let segments = ["v1", "workspaces", workspace, "fork-runs", run];
            send(http, Method::GET, &segments, None, Duration::from_secs(30)).await
        }
        "select" => {
            let run = id(args, "run", "fork run")?;
            let child = id(args, "childId", "fork child")?;
            let segments = ["v1", "workspaces", workspace, "fork-runs", run, "select"];
            let body = json!({ "childId": child });
            send(http, Method::POST, &segments, Some(body), Duration::from_secs(30)).await
        }
        other => Err(Failure::Transport(format!("no fork run verb {other:?}"))),
    }
}

async fn send(
    http: &Http,
    method: Method,
    segments: &[&str],
    body: Option<Value>,
    timeout: Duration,
) -> Result<Value, Failure> {
    let path = path_text(segments);
    let reply = http
        .send(method, http.url(segments, &[]), body.map(Body::Json), None, timeout, &path)
        .await?;
    let object = reply.json();
    if !reply.ok() {
        return Err(refusal(reply.status, object.as_ref()));
    }
    let value = match object {
        Some(Value::Object(mut o)) if o.get("ok") == Some(&Value::Bool(true)) => {
            o.remove("value").unwrap_or(Value::Null)
        }
        Some(Value::Object(o)) if o.get("ok") == Some(&Value::Bool(false)) => {
            return Err(refusal(reply.status, Some(&Value::Object(o))));
        }
        Some(value) => value,
        None => return Err(Failure::Decoding(format!("{path}: the answer is not JSON"))),
    };
    fork_run(value).ok_or_else(|| Failure::Decoding(format!("{path}: not a fork run")))
}

/// `{error: {code, message}}`, or a tagged error's own `{code, message}`.
fn refusal(status: u16, body: Option<&Value>) -> Failure {
    let source = body.and_then(|b| b.get("error").filter(|e| e.is_object()).or(Some(b)));
    let read =
        |name: &str| source.and_then(|e| e.get(name)).and_then(Value::as_str).map(str::to_owned);
    Failure::http(status, read("code"), read("message"))
}

/// A fork run as its callers read it: `{id, state, workspace, sourceMachine, sourceSnapshot,
/// selectedChild, version, children}`, each child `{id, harness, state, machineId, error}`; an
/// absent optional field is null. A bare list of children (or one child) is a run with only
/// `children` (and a null `id`): what the route answered before it answered the run.
pub(crate) fn fork_run(value: Value) -> Option<Value> {
    let Value::Object(object) = &value else {
        return Some(json!({ "id": null, "state": null, "children": fork_children(value)? }));
    };
    if !object.contains_key("children") || object.contains_key("harness") {
        return Some(json!({ "id": null, "state": null, "children": fork_children(value)? }));
    }
    let optional = |name: &str| match object.get(name) {
        None | Some(Value::Null) => Some(Value::Null),
        Some(v @ (Value::String(_) | Value::Number(_))) => Some(v.clone()),
        Some(_) => None,
    };
    Some(json!({
        "id": object.get("id").and_then(Value::as_str)?,
        "state": object.get("state").and_then(Value::as_str)?,
        "workspace": optional("workspace")?,
        "sourceMachine": optional("sourceMachine")?,
        "sourceSnapshot": optional("sourceSnapshot")?,
        "selectedChild": optional("selectedChild")?,
        "version": optional("version")?,
        "children": fork_children(value.clone())?,
    }))
}

/// The children of a fork run's value, each `{id, harness, state, machineId?, error?}`.
pub(crate) fn fork_children(value: Value) -> Option<Value> {
    let list = match value {
        Value::Array(list) => list,
        Value::Object(mut object) => match object.remove("children") {
            Some(Value::Array(list)) => list,
            Some(Value::Null) | None => vec![Value::Object(object)],
            Some(_) => return None,
        },
        _ => return None,
    };
    let child = |v: &Value| {
        let text = |name: &str| v.get(name).and_then(Value::as_str);
        // Absent or null is null; any other value than a string is no child.
        let optional = |name: &str| match v.get(name) {
            None | Some(Value::Null) => Some(Value::Null),
            Some(Value::String(s)) => Some(json!(s)),
            Some(_) => None,
        };
        Some(json!({
            "id": text("id")?, "harness": text("harness")?, "state": text("state")?,
            "machineId": optional("machineId")?, "error": optional("error")?,
        }))
    };
    list.iter().map(child).collect::<Option<Vec<_>>>().map(Value::Array)
}
