//! `share-host screens|start|stop|move` (`cmux share screens|start|stop|move`): the screen shares
//! of this account, as the device hub keeps them (one record per share: host, viewer, scope), read
//! and changed with this machine's device and machine credential, so no app has to run on either
//! side (cmuxterm-hq docs/design/screen-share-under-100ms.md, D9).
//!
//! - `screens`: the live shares this machine hosts or views (`GET /v1/sessions`).
//! - `start --to DEVICE`: this machine shares its screen to DEVICE (`POST /v1/sessions` with
//!   `viewerId`); the viewer's app opens it with no click. Never a prompt: a share that would need
//!   one is refused (`needs_approval`).
//! - `stop SESSION`: ends a share this machine hosts.
//! - `move SESSION --to DEVICE` hands the viewer side to DEVICE; `--host DEVICE` hands the host
//!   side, so the viewer now sees DEVICE's screen (`POST /v1/sessions/:id/move`). The hub starts
//!   the new share before it ends the old one, and a move it refuses leaves the old one running.
//!
//! DEVICE is a device id, an id prefix or a name (any case); SESSION a session id or its prefix.

use cmux_hub_host::Res;
use cmux_hub_host::hub::HubError;
use serde_json::{Value, json};

/// One share's JSON schema.
pub(crate) const RECORD_SCHEMA: &str = "cmux.share.record/1";
/// The list's JSON schema.
pub(crate) const LIST_SCHEMA: &str = "cmux.share.list/1";

/// A signed hub call: method, path, body.
pub(crate) type Call<'a> = &'a dyn Fn(&str, &str, Option<&Value>) -> Res<Value>;

/// Which side of a share `move` hands to another device.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Side {
    Viewer,
    Host,
}

/// `screens`: the live shares, oldest first.
pub(crate) fn list(call: Call<'_>) -> Res<Value> {
    let answer = call("GET", "/v1/sessions", None)?;
    let shares: Vec<Value> = answer
        .get("sessions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(record)
        .collect();
    Ok(json!({"schema": LIST_SCHEMA, "shares": shares}))
}

/// `start --to DEVICE`: this device (`own_id`) shares its screen to `to`.
pub(crate) fn start(call: Call<'_>, own_id: &str, to: &str, view_only: bool) -> Res<Value> {
    let viewer = device(call, own_id, to)?;
    let scope = if view_only { "view" } else { "full" };
    let body = json!({"hostId": own_id, "viewerId": viewer.id, "scope": scope});
    let answer = call("POST", "/v1/sessions", Some(&body)).map_err(|e| explain(e, &viewer.name))?;
    Ok(record(answer.get("session").unwrap_or(&Value::Null)))
}

/// `stop SESSION`.
pub(crate) fn stop(call: Call<'_>, session: &str) -> Res<Value> {
    let id = session_id(call, session)?;
    call("POST", &format!("/v1/sessions/{id}/end"), Some(&json!({"reason": "stopped"})))?;
    Ok(json!({"schema": RECORD_SCHEMA, "id": id, "state": "ended"}))
}

/// `move SESSION --to|--host DEVICE`.
pub(crate) fn move_share(
    call: Call<'_>,
    own_id: &str,
    session: &str,
    side: Side,
    to: &str,
) -> Res<Value> {
    let id = session_id(call, session)?;
    let target = device(call, own_id, to)?;
    let key = match side {
        Side::Viewer => "viewerId",
        Side::Host => "hostId",
    };
    let answer = call("POST", &format!("/v1/sessions/{id}/move"), Some(&json!({key: target.id})))
        .map_err(|e| explain(e, &target.name))?;
    Ok(record(answer.get("session").unwrap_or(&Value::Null)))
}

/// The hub's session as this CLI prints it.
fn record(session: &Value) -> Value {
    let text = |key: &str| session.get(key).cloned().unwrap_or(Value::Null);
    json!({
        "schema": RECORD_SCHEMA,
        "id": text("id"),
        "state": text("state"),
        "scope": text("scope"),
        "hostId": text("hostId"),
        "hostName": text("hostName"),
        "viewerId": text("viewerId"),
        "viewerName": text("viewerName"),
        "createdAt": text("createdAt"),
        "startedAt": text("startedAt"),
        "movedFrom": text("movedFrom"),
    })
}

/// One device of the account.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Device {
    pub id: String,
    pub name: String,
}

/// The account's device `target` names, other than this one.
fn device(call: Call<'_>, own_id: &str, target: &str) -> Res<Device> {
    let answer = call("GET", "/v1/devices", None)?;
    let devices: Vec<Device> = answer
        .get("devices")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|d| {
            let id = d.get("id")?.as_str()?;
            let name = d.get("name").and_then(Value::as_str).unwrap_or_default();
            (id != own_id).then(|| Device { id: id.to_owned(), name: name.to_owned() })
        })
        .collect();
    pick_device(&devices, target).map_err(Into::into)
}

/// The device named `target`: an exact id, else an id prefix, else a name in any case; exactly
/// one, or an error that lists them.
pub(crate) fn pick_device(devices: &[Device], target: &str) -> Result<Device, String> {
    let target = target.trim();
    if target.is_empty() {
        return Err("name a device".to_owned());
    }
    if let Some(exact) = devices.iter().find(|d| d.id == target) {
        return Ok(exact.clone());
    }
    let lower = target.to_lowercase();
    let mut found: Vec<&Device> = devices.iter().filter(|d| d.id.starts_with(&lower)).collect();
    if found.is_empty() {
        found = devices.iter().filter(|d| d.name.to_lowercase() == lower).collect();
    }
    let names = |list: &[&Device]| {
        list.iter()
            .map(|d| format!("{} ({})", cmux_hub_host::printable(&d.name), short_id(&d.id)))
            .collect::<Vec<_>>()
            .join(", ")
    };
    match found.as_slice() {
        [one] => Ok((*one).clone()),
        [] => {
            let all: Vec<&Device> = devices.iter().collect();
            Err(format!(
                "no other device of this account is {}; they are: {}",
                cmux_hub_host::printable(target),
                if all.is_empty() { "none".to_owned() } else { names(&all) }
            ))
        }
        many => Err(format!(
            "{} names several devices: {}",
            cmux_hub_host::printable(target),
            names(many)
        )),
    }
}

/// The live share `session` names: its whole id or a prefix of exactly one.
fn session_id(call: Call<'_>, session: &str) -> Res<String> {
    let session = session.trim();
    let listed = list(call)?;
    let ids: Vec<&str> = listed
        .get("shares")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|s| s.get("id").and_then(Value::as_str))
        .collect();
    pick_session(&ids, session).map_err(Into::into)
}

pub(crate) fn pick_session(ids: &[&str], session: &str) -> Result<String, String> {
    if session.is_empty() {
        return Err("name a share: its session id from `cmux share screens`".to_owned());
    }
    if ids.contains(&session) {
        return Ok(session.to_owned());
    }
    let found: Vec<&&str> = ids.iter().filter(|id| id.starts_with(session)).collect();
    match found.as_slice() {
        [one] => Ok((**one).to_owned()),
        [] => Err(format!(
            "no live share {} on this machine (`cmux share screens` lists them)",
            cmux_hub_host::printable(session)
        )),
        _ => Err(format!("{} starts several shares' ids", cmux_hub_host::printable(session))),
    }
}

/// The hub's refusal in a person's words, naming `device`.
fn explain(
    e: Box<dyn std::error::Error + Send + Sync>,
    device: &str,
) -> Box<dyn std::error::Error + Send + Sync> {
    let Some(h) = e.downcast_ref::<HubError>() else { return e };
    let device = cmux_hub_host::printable(device);
    match h.code.as_str() {
        "host_offline" => format!("{device} is offline").into(),
        "not_shared" => format!("{device} does not share its screen").into(),
        "permission_none" => format!("{device} does not let this device in").into(),
        "needs_approval" => format!(
            "this needs {device}'s person to allow it first; a share never asks on the way (device hub {})",
            h.status
        )
        .into(),
        "session_not_active" => "that share has already ended".into(),
        "not_found" if h.message.contains("session") => "that share has already ended".into(),
        _ => e,
    }
}

fn short_id(id: &str) -> &str {
    id.get(..8).unwrap_or(id)
}

/// One line per share, for a person.
pub(crate) fn print_list(list: &Value) {
    let shares = list.get("shares").and_then(Value::as_array).cloned().unwrap_or_default();
    if shares.is_empty() {
        println!("No screen share is live on this machine.");
        return;
    }
    for share in shares {
        let text = |k: &str| share.get(k).and_then(Value::as_str).unwrap_or("-").to_owned();
        let moved = share.get("movedFrom").and_then(Value::as_str);
        println!(
            "{}  {} -> {}  {} {}{}",
            text("id"),
            cmux_hub_host::printable(&text("hostName")),
            cmux_hub_host::printable(&text("viewerName")),
            text("scope"),
            text("state"),
            moved.map(|m| format!("  (moved from {})", short_id(m))).unwrap_or_default()
        );
    }
}

/// One share, for a person.
pub(crate) fn print_record(verb: &str, share: &Value) {
    let text = |k: &str| share.get(k).and_then(Value::as_str).unwrap_or("-").to_owned();
    match verb {
        "stop" => println!("Stopped share {}.", text("id")),
        _ => println!(
            "Share {}: {} -> {} ({}, {}).",
            text("id"),
            cmux_hub_host::printable(&text("hostName")),
            cmux_hub_host::printable(&text("viewerName")),
            text("scope"),
            text("state")
        ),
    }
}

#[cfg(test)]
#[path = "verbs_tests.rs"]
mod tests;
