//! Who made a workspace, space or tab, and why (`created-by-detail-v1`; Leo, 2026-11-19:
//! "acpmux should expose these a lot better"). A create sent from an acpmux agent session (its
//! shell's `ACPMUX_SESSION_ID`, or the cmux MCP server's `CMUX_AGENT_SESSION`) gets
//! `created_by {kind: "agent", session, session_name, host, purpose}`: the session's name and
//! title come from the running acpmux daemon, the purpose defaults to that title, and the host is
//! this machine's short name. `--purpose` (or a `created_by.purpose` the caller sent) wins over
//! the title. A create outside an agent session gets nothing new, so a workspace a person makes
//! shows nothing new. A daemon without the capability gets the request it took before.
//! `wire::run_once` and the agents/MCP transport (`mcp/transport.rs`) both send through here.

use std::io::BufReader;
use std::path::Path;

use serde_json::{Map, Value, json};

use cmux_tui_core::platform::transport;
use cmux_tui_core::server::{CREATED_BY_DETAIL_CAPABILITY, WORKSPACE_CREATED_BY_CAPABILITY};

/// The creates that take `created_by`.
const CREATES: [&str; 4] =
    ["workspace.create", "room.create", "tab.create_terminal", "tab.create_browser"];
/// The `created_by` fields `created-by-detail-v1` added; an older daemon refuses them.
const DETAIL: [&str; 3] = ["session_name", "host", "purpose"];
/// The longest purpose kept: one line, not a prompt.
const MAX_PURPOSE: usize = 200;

/// The acpmux session a create runs in, from its environment.
fn agent_session() -> Option<String> {
    ["CMUX_AGENT_SESSION", "ACPMUX_SESSION_ID"]
        .into_iter()
        .filter_map(|name| std::env::var(name).ok())
        .find(|value| !value.trim().is_empty())
}

/// What acpmux says of session `id`: its name, title and host.
#[derive(Default)]
struct SessionFacts {
    name: Option<String>,
    title: Option<String>,
    host: Option<String>,
}

#[cfg(unix)]
fn session_facts(id: &str) -> SessionFacts {
    let read = async {
        let client = acpmux::deliver::connect().await.ok()?;
        client.request(acpmux::rpc::method::MUX_INFO, json!({"sessionId": id})).await.ok()
    };
    // A create never waits long on acpmux: without an answer it names the session by id.
    let info = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .ok()
        .and_then(|runtime| {
            runtime.block_on(async {
                tokio::time::timeout(std::time::Duration::from_millis(800), read)
                    .await
                    .ok()
                    .flatten()
            })
        })
        .unwrap_or(Value::Null);
    let text = |value: &Value| {
        value.as_str().map(str::trim).filter(|text| !text.is_empty()).map(str::to_owned)
    };
    SessionFacts {
        name: info.get("name").and_then(text),
        title: info
            .get("title")
            .and_then(text)
            .or_else(|| info.get("summary").and_then(|s| s.get("title")).and_then(text)),
        host: info.get("host").and_then(text),
    }
}

#[cfg(not(unix))]
fn session_facts(_id: &str) -> SessionFacts {
    SessionFacts::default()
}

/// This machine's name, without its domain.
fn short_host() -> Option<String> {
    let name = acpmux::hand::pair::hostname();
    let short = name.split('.').next().unwrap_or_default().trim();
    (!short.is_empty()).then(|| short.to_owned())
}

/// One line of at most [`MAX_PURPOSE`] characters.
fn one_line(text: &str) -> Option<String> {
    let line = text.lines().map(str::trim).find(|line| !line.is_empty())?;
    Some(line.chars().take(MAX_PURPOSE).collect())
}

/// Adds the agent session's `created_by` to a create sent from one; true when the request
/// changed. A `created_by` of kind `person` is left alone.
pub(in crate::cli) fn stamp(request: &mut Value) -> bool {
    let Some(session) = agent_session() else { return false };
    stamp_with(request, &session, || {
        let mut facts = session_facts(&session);
        // The shell's own name for its session, when acpmux did not answer.
        if facts.name.is_none()
            && std::env::var("ACPMUX_SESSION_ID").ok().as_deref() == Some(&session)
        {
            facts.name = std::env::var("ACPMUX_SESSION_NAME").ok().filter(|n| !n.is_empty());
        }
        if facts.host.is_none() {
            facts.host = short_host();
        }
        facts
    })
}

fn stamp_with(request: &mut Value, session: &str, facts: impl FnOnce() -> SessionFacts) -> bool {
    let Some(operation) = request["operation"].as_str() else { return false };
    if !CREATES.contains(&operation) {
        return false;
    }
    let Some(params) = request.get_mut("params").and_then(Value::as_object_mut) else {
        return false;
    };
    let created_by = params.entry("created_by").or_insert_with(|| Value::Object(Map::new()));
    let Some(created_by) = created_by.as_object_mut() else { return false };
    if created_by.get("kind").and_then(Value::as_str) == Some("person") {
        return false;
    }
    let facts = facts();
    created_by.insert("kind".into(), json!("agent"));
    created_by.entry("session").or_insert_with(|| json!(session));
    if let Some(name) = facts.name {
        created_by.entry("session_name").or_insert_with(|| json!(name));
    }
    if let Some(host) = facts.host {
        created_by.entry("host").or_insert_with(|| json!(host));
    }
    let purpose = created_by
        .get("purpose")
        .and_then(Value::as_str)
        .and_then(one_line)
        .or_else(|| facts.title.as_deref().and_then(one_line));
    match purpose {
        Some(purpose) => created_by.insert("purpose".into(), json!(purpose)),
        None => created_by.remove("purpose"),
    };
    true
}

/// Fits a create's `created_by` to the daemon: without `workspace-created-by-v1` none is sent;
/// without `created-by-detail-v1` a workspace keeps `kind`, `workspace` and `session` and a space
/// or tab sends none. True when the request changed.
pub(in crate::cli) fn drop_unsupported(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    socket: &Path,
    request: &mut Value,
) -> bool {
    let Some(operation) = request["operation"].as_str().map(str::to_owned) else { return false };
    if !CREATES.contains(&operation.as_str()) || request["params"].get("created_by").is_none() {
        return false;
    }
    let advertises = |reader: &mut _, capability| {
        super::super::launch_credential::advertises(reader, socket, capability)
    };
    if advertises(reader, CREATED_BY_DETAIL_CAPABILITY) {
        return false;
    }
    let Some(params) = request.get_mut("params").and_then(Value::as_object_mut) else {
        return false;
    };
    if operation != "workspace.create" || !advertises(reader, WORKSPACE_CREATED_BY_CAPABILITY) {
        return params.remove("created_by").is_some();
    }
    let Some(created_by) = params.get_mut("created_by").and_then(Value::as_object_mut) else {
        return false;
    };
    let before = created_by.len();
    created_by.retain(|key, _| !DETAIL.contains(&key.as_str()));
    created_by.len() != before
}

/// The line a list shows for who made a row: `desktop-helper@studio-mac: Demo project`, a
/// script's `script: <purpose>`; None for the person's own (no record, kind `person`, or a
/// script that named no purpose).
pub(in crate::cli) fn creator_line(created_by: &Value) -> Option<String> {
    let field = |name: &str| created_by.get(name).and_then(Value::as_str).filter(|v| !v.is_empty());
    let who = match field("kind")? {
        "agent" => {
            let session = field("session_name")
                .map(str::to_owned)
                .or_else(|| field("session").map(|id| id.chars().take(8).collect()))
                .unwrap_or_else(|| "agent".to_owned());
            match field("host") {
                Some(host) => format!("{session}@{host}"),
                None => session,
            }
        }
        // A bare script record is also what a person typing `cmux workspace create` in a cmux
        // terminal leaves: it says nothing new unless the script named a purpose.
        "script" if field("purpose").is_some() => "script".to_owned(),
        _ => return None,
    };
    Some(match field("purpose") {
        Some(purpose) => format!("{who}: {purpose}"),
        None => who,
    })
}

/// A workspace, space or tab list's rows as the human table shows them: `created_by` is the
/// [`creator_line`], one column after the row's own, not inside the EXTRA blob. `--json` keeps
/// the whole object.
pub(in crate::cli) fn human_rows(plan: &super::RequestPlan, result: &mut Value) {
    use cmux_tui_core::resource::ResourceOperation as Op;
    let super::WireOperation::Typed(Op::WorkspaceList | Op::TabList | Op::RoomList) =
        &plan.operation
    else {
        return;
    };
    let Some(rows) = result.as_array_mut() else { return };
    for row in rows {
        let Some(row) = row.as_object_mut() else { continue };
        let created_by = row
            .remove("created_by")
            .or_else(|| row.get_mut("extra").and_then(Value::as_object_mut)?.remove("created_by"));
        if let Some(line) = created_by.as_ref().and_then(creator_line) {
            row.insert("created_by".into(), json!(line));
        }
    }
}

#[cfg(test)]
#[path = "created_by_stamp_tests.rs"]
mod tests;
