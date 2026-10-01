//! Reads the CLI runs on a request's own connection before it sends the
//! request, to fill parameters the command named indirectly: the caller's
//! workspace and rooms or groups named by their exact name. The request then
//! carries only ids, so a retry with `--idempotency-key` sends the same
//! fingerprint.

use std::io::{BufReader, Write};

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::{PROTOCOL, ResourceOperation, ResponseEnvelope};
use serde_json::{Map, Value, json};

use super::OutputMode;
use super::command::{RequestPlan, Resolve};
use super::wire::{print_operation_error, random_request_id, read_envelope};

type Reader = BufReader<Box<dyn transport::Stream>>;

pub(super) enum Failure {
    /// A resource error from the daemon, or a local one in that shape.
    Resource(Value),
    Transport(String),
}

impl Failure {
    pub(super) fn report(self, output: OutputMode) -> i32 {
        match self {
            Self::Resource(error) => print_operation_error(&error, output),
            Self::Transport(message) => {
                eprintln!("{message}");
                3
            }
        }
    }
}

/// Applies every pending lookup of `plan` and clears them.
pub(super) fn apply(
    reader: &mut Reader,
    plan: &mut RequestPlan,
    caller_route: bool,
) -> Result<(), Failure> {
    let steps = std::mem::take(&mut plan.resolve);
    let params = plan
        .params
        .as_object_mut()
        .ok_or_else(|| Failure::Transport("cmux: request params are not an object".into()))?;
    let route = route(params);
    for step in steps {
        match step {
            Resolve::CallerWorkspace { terminal } => {
                let workspace = if caller_route {
                    caller_workspace(reader, &route, &terminal)?
                } else {
                    "current".to_string()
                };
                params.insert("workspace".into(), Value::String(workspace));
            }
            Resolve::StateName { field, list } => {
                let Some(value) = params.get(field).and_then(Value::as_str).map(str::to_owned)
                else {
                    continue;
                };
                let records = read(reader, list, route.clone())?;
                if let Some(id) = state_id(field, &value, &records)? {
                    params.insert(field.into(), Value::String(id));
                }
            }
        }
    }
    Ok(())
}

fn route(params: &Map<String, Value>) -> Map<String, Value> {
    ["machine", "session"]
        .into_iter()
        .filter_map(|key| params.get(key).map(|value| (key.to_string(), value.clone())))
        .collect()
}

/// The workspace that holds `terminal`: terminal -> tab -> pane -> screen.
fn caller_workspace(
    reader: &mut Reader,
    route: &Map<String, Value>,
    terminal: &str,
) -> Result<String, Failure> {
    let mut id = terminal.to_string();
    for (operation, selector, parent) in [
        (ResourceOperation::TerminalGet, "terminal", "tab_id"),
        (ResourceOperation::TabGet, "tab", "pane_id"),
        (ResourceOperation::PaneGet, "pane", "screen_id"),
        (ResourceOperation::ScreenGet, "screen", "workspace_id"),
    ] {
        let mut params = route.clone();
        params.insert(selector.into(), Value::String(id));
        let snapshot = read(reader, operation, params)?;
        id = snapshot.get(parent).and_then(Value::as_str).map(str::to_owned).ok_or_else(|| {
            Failure::Resource(json!({
                "code": "selector.not_found",
                "message": format!(
                    "the caller's terminal {terminal} is not in a workspace; name one: \
                     cmux workspace <workspace> …"
                ),
                "details": {"terminal": terminal},
                "retryable": false,
            }))
        })?;
    }
    Ok(id)
}

/// `Some(id)` when `value` is not an id but the exact name of one record.
/// An id, or a name nothing has, goes to the daemon unchanged, which reports
/// `resource.not_found` for an unknown one.
fn state_id(field: &str, value: &str, records: &Value) -> Result<Option<String>, Failure> {
    let records = records.as_array().map(Vec::as_slice).unwrap_or_default();
    if records.iter().any(|record| record.get("id").and_then(Value::as_str) == Some(value)) {
        return Ok(None);
    }
    let named = records
        .iter()
        .filter(|record| record.get("name").and_then(Value::as_str) == Some(value))
        .filter_map(|record| record.get("id").and_then(Value::as_str))
        .collect::<Vec<_>>();
    match named.as_slice() {
        [] => Ok(None),
        [id] => Ok(Some((*id).to_string())),
        candidates => Err(Failure::Resource(json!({
            "code": "selector.ambiguous",
            "message": format!(
                "more than one {} is named {value:?}; use its id",
                field.replace('_', " ")
            ),
            "details": {"field": field, "candidates": candidates},
            "retryable": false,
        }))),
    }
}

/// One read on the connection; returns its result.
fn read(
    reader: &mut Reader,
    operation: ResourceOperation,
    params: Map<String, Value>,
) -> Result<Value, Failure> {
    call(reader, operation, params, None)
}

/// One request on the connection; returns its result. A mutation carries
/// `idempotency_key`.
pub(super) fn call(
    reader: &mut Reader,
    operation: ResourceOperation,
    params: Map<String, Value>,
    idempotency_key: Option<&str>,
) -> Result<Value, Failure> {
    let id = random_request_id().map_err(|error| Failure::Transport(format!("cmux: {error}")))?;
    let mut request = json!({
        "protocol": PROTOCOL,
        "type": "request",
        "id": id,
        "operation": operation.wire_name(),
        "params": params,
    });
    if let Some(key) = idempotency_key {
        request["idempotency_key"] = Value::String(key.to_owned());
    }
    let mut encoded = serde_json::to_vec(&request).expect("JSON values serialize");
    encoded.push(b'\n');
    reader
        .get_mut()
        .write_all(&encoded)
        .and_then(|()| reader.get_mut().flush())
        .map_err(|error| Failure::Transport(format!("transport error: {error}")))?;
    loop {
        let value = read_envelope(reader, false)
            .map_err(Failure::Transport)?
            .ok_or_else(|| Failure::Transport("transport closed before response".into()))?;
        if value.get("type").and_then(Value::as_str) != Some("response") {
            continue;
        }
        let response: ResponseEnvelope = serde_json::from_value(value).map_err(|error| {
            Failure::Transport(format!("protocol error: invalid response envelope: {error}"))
        })?;
        if response.id.as_str() != id {
            continue;
        }
        if let Err(error) = response.validate() {
            return Err(Failure::Transport(format!("protocol error: {}", error.message)));
        }
        if response.ok {
            return Ok(response.result.unwrap_or(Value::Null));
        }
        let error = response.error.map(|error| serde_json::to_value(error).unwrap_or_default());
        return Err(Failure::Resource(
            error.unwrap_or_else(
                || json!({"code": "operation.failed", "message": "request failed"}),
            ),
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_unique_exact_name_becomes_its_id_and_an_id_stays() {
        let records = json!([
            {"id": "room-a", "name": "Work"},
            {"id": "room-b", "name": "Home"},
            {"id": "room-c", "name": "room-a"},
        ]);
        assert_eq!(state_id("room", "Work", &records).ok().flatten().as_deref(), Some("room-a"));
        // An id wins over a record named like it.
        assert_eq!(state_id("room", "room-a", &records).ok().flatten(), None);
        assert_eq!(state_id("room", "Nowhere", &records).ok().flatten(), None);
    }

    #[test]
    fn a_shared_name_is_ambiguous_with_candidates() {
        let records = json!([
            {"id": "g1", "name": "agents"},
            {"id": "g2", "name": "agents"},
        ]);
        let Err(Failure::Resource(error)) = state_id("tab_group", "agents", &records) else {
            panic!("a shared name resolved");
        };
        assert_eq!(error["code"], "selector.ambiguous");
        assert_eq!(error["details"]["candidates"], json!(["g1", "g2"]));
        assert!(error["message"].as_str().unwrap().contains("tab group"));
    }

    #[test]
    fn route_keeps_only_machine_and_session() {
        let params = json!({"machine": "current", "session": "s", "room": "x"});
        assert_eq!(
            Value::Object(route(params.as_object().unwrap())),
            json!({"machine": "current", "session": "s"})
        );
    }
}
