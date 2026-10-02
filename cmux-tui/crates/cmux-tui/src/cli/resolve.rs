//! Reads the CLI runs on a request's own connection before it sends the
//! request, to fill parameters the command named indirectly: the caller's
//! workspace and rooms or groups named by their exact name. The request then
//! carries only ids, so a retry with `--idempotency-key` sends the same
//! fingerprint.

use std::io::{BufReader, Write};

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::{PROTOCOL, ResourceOperation};
use serde_json::{Map, Value, json};

use super::OutputMode;
use super::command::{RequestPlan, Resolve};
use super::wire::{print_operation_error, random_request_id, read_response};

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
            Resolve::IdPrefix { field, list } => {
                let Some(value) = params.get(&field).and_then(Value::as_str).map(str::to_owned)
                else {
                    continue;
                };
                let records = read(reader, list, route.clone())?;
                params
                    .insert(field.clone(), Value::String(unique_prefix(&field, &value, &records)?));
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

/// Public id prefixes a `<session>:` qualifier may precede.
const QUALIFIABLE_PREFIXES: &[&str] =
    &["ws", "screen", "pane", "tab", "term", "browser", "notification", "agent", "split"];

/// `build-box:ws_1a2b…` is `(Some("build-box"), "ws_1a2b…")`: a session name
/// before a whole or partial public id (cli.md, Remaining 12). Anything else
/// is unqualified, so a name that contains a colon, the daemon's `name:`
/// escape and a `kind:id` target (`workspace:ws_…`) never pick a session.
#[cfg_attr(not(unix), allow(dead_code))]
pub(super) fn split_session(value: &str) -> (Option<&str>, &str) {
    if let Some((session, rest)) = value.split_once(':')
        && !session.is_empty()
        && session != "name"
        && !cmux_tui_core::resource::is_reserved_selector_token(session)
        && QUALIFIABLE_PREFIXES.iter().any(|prefix| is_id_or_prefix(rest, prefix))
    {
        return (Some(session), rest);
    }
    (None, value)
}

/// `ws_` followed by 1 to 32 lowercase hex digits.
fn is_id_or_prefix(value: &str, prefix: &str) -> bool {
    hex_after(value, prefix).is_some_and(|hex| !hex.is_empty() && hex.len() <= 32)
}

/// `ws_1a2b`: fewer than 32 lowercase hex digits after the prefix, so not a
/// whole id but a unique prefix of one (`Resolve::IdPrefix`).
#[cfg_attr(not(unix), allow(dead_code))]
pub(super) fn is_partial_id(value: &str, prefix: &str) -> bool {
    hex_after(value, prefix).is_some_and(|hex| !hex.is_empty() && hex.len() < 32)
}

fn hex_after<'a>(value: &'a str, prefix: &str) -> Option<&'a str> {
    let hex = value.strip_prefix(prefix)?.strip_prefix('_')?;
    hex.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)).then_some(hex)
}

/// The one id in `records` that starts with `prefix`. No match is
/// `selector.not_found`; more than one is `selector.ambiguous` with the
/// candidates, as the daemon reports for a name.
fn unique_prefix(field: &str, prefix: &str, records: &Value) -> Result<String, Failure> {
    let records = records.as_array().map(Vec::as_slice).unwrap_or_default();
    let matches = records
        .iter()
        .filter_map(|record| record.get("id").and_then(Value::as_str))
        .filter(|id| id.starts_with(prefix))
        .collect::<Vec<_>>();
    match matches.as_slice() {
        [id] => Ok((*id).to_string()),
        [] => Err(Failure::Resource(json!({
            "code": "selector.not_found",
            "message": format!("no {field} id starts with {prefix:?}"),
            "details": {"field": field, "prefix": prefix},
            "retryable": false,
        }))),
        candidates => Err(Failure::Resource(json!({
            "code": "selector.ambiguous",
            "message": format!("more than one {field} id starts with {prefix:?}; use more of it"),
            "details": {"field": field, "prefix": prefix, "candidates": candidates},
            "retryable": false,
        }))),
    }
}

/// Writes one encoded request line and flushes it.
pub(super) fn send(reader: &mut Reader, encoded: &[u8]) -> Result<(), String> {
    let stream = reader.get_mut();
    stream
        .write_all(encoded)
        .and_then(|()| stream.write_all(b"\n"))
        .and_then(|()| stream.flush())
        .map_err(|error| format!("transport error: {error}"))
}

/// One read on the connection; returns its result.
fn read(
    reader: &mut Reader,
    operation: ResourceOperation,
    params: Map<String, Value>,
) -> Result<Value, Failure> {
    let id = random_request_id().map_err(|error| Failure::Transport(format!("cmux: {error}")))?;
    let request = json!({
        "protocol": PROTOCOL,
        "type": "request",
        "id": id,
        "operation": operation.wire_name(),
        "params": params,
    });
    let encoded = serde_json::to_vec(&request).expect("JSON values serialize");
    send(reader, &encoded).map_err(Failure::Transport)?;
    match read_response(reader, &id).map_err(Failure::Transport)? {
        Ok(result) => Ok(result),
        Err(error) => Err(Failure::Resource(error)),
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
    fn an_id_prefix_resolves_only_when_unique() {
        let records = json!([
            {"id": "ws_1a2b0000000000000000000000000000"},
            {"id": "ws_1a2c0000000000000000000000000000"},
            {"id": "ws_9f000000000000000000000000000000"},
        ]);
        assert_eq!(
            unique_prefix("workspace", "ws_9", &records).ok().as_deref(),
            Some("ws_9f000000000000000000000000000000")
        );
        let Err(Failure::Resource(error)) = unique_prefix("workspace", "ws_1a", &records) else {
            panic!("a shared prefix resolved");
        };
        assert_eq!(error["code"], "selector.ambiguous");
        assert_eq!(error["details"]["candidates"].as_array().map(Vec::len), Some(2));
        let Err(Failure::Resource(error)) = unique_prefix("workspace", "ws_77", &records) else {
            panic!("an unknown prefix resolved");
        };
        assert_eq!(error["code"], "selector.not_found");
    }

    #[test]
    fn a_session_qualifier_needs_a_public_id_after_it() {
        assert_eq!(split_session("build-box:ws_1a2b"), (Some("build-box"), "ws_1a2b"));
        assert_eq!(
            split_session("mini:term_0123456789abcdef0123456789abcdef"),
            (Some("mini"), "term_0123456789abcdef0123456789abcdef")
        );
        // A kind before an id is a target form, not a session.
        assert_eq!(split_session("workspace:ws_1a"), (None, "workspace:ws_1a"));
        // A name that contains a colon, and the name escape, stay names.
        assert_eq!(split_session("prod:ws_backup"), (None, "prod:ws_backup"));
        assert_eq!(split_session("name:ws_1a"), (None, "name:ws_1a"));
        assert_eq!(split_session(":ws_1a"), (None, ":ws_1a"));
        assert!(is_partial_id("ws_1a", "ws"));
        assert!(!is_partial_id("ws_0123456789abcdef0123456789abcdef", "ws"));
        assert!(!is_partial_id("ws_", "ws"));
        assert!(!is_partial_id("ws_XY", "ws"));
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
