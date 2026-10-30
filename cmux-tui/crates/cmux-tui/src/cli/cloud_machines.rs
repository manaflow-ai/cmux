//! `cmux machine list` also lists the cmux Cloud machines the app knows.
//!
//! The daemon's machine catalog holds this machine and the routes the app
//! published (ids `machine_<hex>`); a Cloud machine is named by its Cloud id
//! (`vm-…`), which only the app's Cloud store has. So after the daemon
//! answers, the CLI asks the app's control socket for `cloud.machines` (a
//! main-actor read of the store, no network) and appends one row per Cloud
//! machine, marked `kind: "cloud"`. The daemon's rows stay as they were.
//! A connected Cloud machine's daemon is also in `--catalog` under its
//! `machine_<hex>` id; the app's row names that id (`machine_id`), so the
//! machine is listed once, as the daemon's row.
//!
//! It fails open: with an app that is not running, does not own this
//! session, or refuses (Cloud turned off), the daemon's list prints alone and
//! a note on stderr says the Cloud machines are not in it. With no cmux app
//! at all (a Linux or headless host), there are none to list and no note.

use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode};

/// How long the best-effort `cloud.machines` read may take, from connect to
/// reply: a short main-actor read, so a slow app costs `machine list` at
/// most this.
const CLOUD_READ_TIMEOUT: Duration = Duration::from_secs(1);

/// The daemon's `machine.list` result with the app's Cloud machines added.
pub(super) fn merge(global: &GlobalArgs, result: Value) -> Value {
    if global.app_socket.is_none() && !app_found() {
        return result;
    }
    let cloud = super::app::socket_path(global).and_then(read_by_deadline);
    let (merged, note) = merge_rows(result, cloud);
    if let Some(reason) = note
        && global.output != OutputMode::Quiet
    {
        let messages = &crate::localization::catalog().app_control;
        eprintln!("{}", messages.cloud_machines_unlisted.replace("{reason}", &reason));
    }
    merged
}

/// Whether this process belongs to a cmux app (an app terminal's
/// environment, or the app bundle around the executable).
fn app_found() -> bool {
    let exe = std::env::current_exe().ok();
    crate::app_identity::AppIdentity::detect(|key| std::env::var(key).ok(), exe.as_deref())
        .is_some()
}

/// The app's `cloud.machines` rows from `socket`, read on a helper thread
/// so the whole read (connect included, and a reply that trickles in) ends
/// by [`CLOUD_READ_TIMEOUT`]. A read still running then is left behind, and
/// the command's exit ends it.
fn read_by_deadline(socket: PathBuf) -> Result<Vec<Value>, String> {
    let (sender, receiver) = mpsc::channel();
    std::thread::Builder::new()
        .name("cmux-cloud-machines".into())
        .spawn(move || {
            let cloud =
                super::app::connect(&socket).and_then(|mut stream| cloud_machines(&mut stream));
            let _ = sender.send(cloud);
        })
        .map_err(|error| error.to_string())?;
    receiver.recv_timeout(CLOUD_READ_TIMEOUT).unwrap_or_else(|_| {
        let messages = &crate::localization::catalog().app_control;
        Err(messages.timeout.replace("{seconds}", &CLOUD_READ_TIMEOUT.as_secs().to_string()))
    })
}

/// The app's `cloud.machines` rows, or why there are none to add. A reply
/// with no `machines` list is a failed read, not an empty one.
pub(super) fn cloud_machines(stream: &mut UnixStream) -> Result<Vec<Value>, String> {
    match super::app::request(stream, "cloud.machines", json!({}), CLOUD_READ_TIMEOUT)? {
        Ok(reply) => reply.get("machines").and_then(Value::as_array).cloned().ok_or_else(|| {
            crate::localization::catalog().app_control.cloud_machines_malformed.to_owned()
        }),
        Err(error) => Err(error
            .get("message")
            .and_then(Value::as_str)
            .or_else(|| error.get("code").and_then(Value::as_str))
            .unwrap_or("the app refused cloud.machines")
            .to_owned()),
    }
}

/// `result` (the daemon's rows: an array, or `{"items": [...]}`) with one
/// row per Cloud machine appended, unless the daemon already lists it (its
/// Cloud `id`, or the `machine_id` its connected daemon has in `--catalog`);
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
        let already = |key: &str| {
            row.get(key).is_some_and(|id| rows.iter().any(|listed| listed.get("id") == Some(id)))
        };
        if already("id") || already("machine_id") {
            continue;
        }
        rows.push(row);
    }
    (result, None)
}

/// One Cloud machine as a `machine list` row: the daemon rows' fields
/// (`id`, `name`, `origin`, `status`, `connectable`, `deleted`,
/// `recoverable`) plus `kind: "cloud"`, the `target` that names it to the
/// Cloud verbs (`--target machine:<id>`), its daemon link (`daemon`) and,
/// once its daemon has said, that daemon's machine id (`machine_id`).
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
    if let Some(machine_id) = text("machine_id").filter(|machine_id| !machine_id.is_empty()) {
        row.insert("machine_id".into(), json!(machine_id));
    }
    Some(Value::Object(row))
}

#[cfg(test)]
mod tests;
