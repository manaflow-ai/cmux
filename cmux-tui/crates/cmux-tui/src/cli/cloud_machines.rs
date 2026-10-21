//! `cmux machine list` also lists the cmux Cloud machines the app knows.
//!
//! The daemon's machine catalog holds this machine and the routes the app
//! published (ids `machine_<hex>`); a Cloud machine is named by its Cloud id
//! (`vm-…`), which only the app's Cloud store has. So after the daemon
//! answers, the CLI asks the app's control socket for `cloud.machines` (a
//! main-actor read of the store, no network) and appends one row per Cloud
//! machine, marked `kind: "cloud"`. The daemon's rows stay as they were.
//!
//! It fails open: with no app, an app that does not own this session, or a
//! refusal (Cloud turned off), the daemon's list prints alone and a note on
//! stderr says the Cloud machines are not in it.

use std::os::unix::net::UnixStream;

use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode};

/// The daemon's `machine.list` result with the app's Cloud machines added.
pub(super) fn merge(global: &GlobalArgs, result: Value) -> Value {
    let cloud = super::app::socket_path(global)
        .and_then(|socket| super::app::connect(&socket))
        .and_then(|mut stream| cloud_machines(&mut stream));
    let (merged, note) = merge_rows(result, cloud);
    if let Some(reason) = note
        && global.output != OutputMode::Quiet
    {
        let messages = &crate::localization::catalog().app_control;
        eprintln!("{}", messages.cloud_machines_unlisted.replace("{reason}", &reason));
    }
    merged
}

/// The app's `cloud.machines` rows, or why there are none to add.
pub(super) fn cloud_machines(stream: &mut UnixStream) -> Result<Vec<Value>, String> {
    match super::app::request(stream, "cloud.machines", json!({}), super::app::READ_TIMEOUT)? {
        Ok(reply) => {
            Ok(reply.get("machines").and_then(Value::as_array).cloned().unwrap_or_default())
        }
        Err(error) => Err(error
            .get("message")
            .and_then(Value::as_str)
            .or_else(|| error.get("code").and_then(Value::as_str))
            .unwrap_or("the app refused cloud.machines")
            .to_owned()),
    }
}

/// `result` (the daemon's rows: an array, or `{"items": [...]}`) with one
/// row per Cloud machine appended, unless the daemon already lists its id;
/// the note's reason when the Cloud machines could not be read.
pub(super) fn merge_rows(
    mut result: Value,
    cloud: Result<Vec<Value>, String>,
) -> (Value, Option<String>) {
    let machines = match cloud {
        Ok(machines) => machines,
        Err(reason) => return (result, Some(reason)),
    };
    let rows = match &mut result {
        Value::Array(rows) => rows,
        Value::Object(object) => match object.get_mut("items") {
            Some(Value::Array(rows)) => rows,
            _ => return (result, None),
        },
        _ => return (result, None),
    };
    for machine in &machines {
        let Some(row) = cloud_row(machine) else { continue };
        if rows.iter().any(|listed| listed.get("id") == row.get("id")) {
            continue;
        }
        rows.push(row);
    }
    (result, None)
}

/// One Cloud machine as a `machine list` row: the daemon rows' fields
/// (`id`, `name`, `origin`, `status`, `connectable`, `deleted`,
/// `recoverable`) plus `kind: "cloud"`, the `target` that names it to the
/// Cloud verbs (`--target machine:<id>`) and its daemon link (`daemon`).
fn cloud_row(machine: &Value) -> Option<Value> {
    let id = machine.get("id").and_then(Value::as_str).filter(|id| !id.is_empty())?;
    let text = |key: &str| machine.get(key).and_then(Value::as_str);
    let status = text("status").unwrap_or("unknown");
    let daemon = text("daemon").unwrap_or("disconnected");
    let mut row = Map::new();
    row.insert("id".into(), json!(id));
    row.insert("name".into(), json!(text("title").filter(|title| !title.is_empty()).unwrap_or(id)));
    row.insert("origin".into(), json!("cloud"));
    row.insert("kind".into(), json!("cloud"));
    row.insert("status".into(), json!(status));
    row.insert("connectable".into(), json!(daemon == "connected"));
    row.insert("deleted".into(), json!(status == "destroyed"));
    row.insert("recoverable".into(), json!(false));
    row.insert("target".into(), json!(format!("machine:{id}")));
    row.insert("daemon".into(), json!(daemon));
    Some(Value::Object(row))
}

#[cfg(test)]
mod tests;
