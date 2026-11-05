//! Read-only work on this Chief's machine. The owner/Channels page asks for a Chief id;
//! its configured brain home supplies the ownership tag, never a path or session id from JS.
//! Background commands come from acpmux's harness process registry. Daemon-owned `bg` tasks
//! keep their separate person-proof gate; this endpoint does not bypass it.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::agent_session_attach::agent_session_link::AcpmuxLink;
use super::{ClientTransport, MessageWriter, Mux, Response, send_response};
use crate::chief_registry::{ChiefStore, DEFAULT_CHIEF};
use crate::conversation_store::LOCAL_USER;

pub(super) const CAPABILITY: &str = "chief-work-v1";
const TIMEOUT: Duration = Duration::from_secs(15);
const MAX_SESSIONS: usize = 200;
const MAX_TASKS: usize = 500;
const PAGE: u64 = 100;

type Failure = (&'static str, &'static str);
const UNAVAILABLE: Failure = ("chief.work_unavailable", "The Chief's work could not be read.");

pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("chief-work") {
        return None;
    }
    let Ok(Value::Object(mut fields)) = serde_json::from_str::<Value>(message) else {
        return None;
    };
    if fields.get("cmd").and_then(Value::as_str) != Some("chief-work") {
        return None;
    }
    let id = fields.remove("id");
    fields.remove("cmd");
    if !reader(mux, client) {
        return Some(answer(writer, id, Err(("origin.forbidden", "The Chief's work is private."))));
    }
    let chief = fields.remove("chief").and_then(|v| v.as_str().map(str::to_owned));
    let Some(chief) = chief.filter(|id| !id.is_empty()) else {
        return Some(answer(writer, id, Err(("bad_request", "chief is required."))));
    };
    if !fields.is_empty() {
        return Some(answer(writer, id, Err(("bad_request", "Unknown Chief work field."))));
    }
    let (mux, reply_writer, reply_id) = (mux.clone(), writer.clone(), id.clone());
    let spawned = std::thread::Builder::new().name("mux-chief-work".into()).spawn(move || {
        let result = target(&mux, &chief).and_then(|(home, socket)| {
            let link = AcpmuxLink::connect(&socket, |_| {}).map_err(|_| UNAVAILABLE)?;
            let result = inventory(&home_id(&home), |method, params, timeout| {
                link.call(method, params, timeout).map_err(|_| UNAVAILABLE)
            });
            link.close();
            result
        });
        answer(&reply_writer, reply_id, result);
    });
    Some(spawned.is_ok() || answer(writer, id, Err(UNAVAILABLE)))
}

fn reader(mux: &Mux, client: u64) -> bool {
    if mux.is_remote_client(client) || mux.conversation_principal(client) != LOCAL_USER {
        return false;
    }
    match mux.control_clients.transport_of(client) {
        Some(ClientTransport::Unix) => true,
        Some(ClientTransport::WebSocket) => {
            super::chief_registry_resource::person_page(mux, client)
        }
        _ => false,
    }
}

fn answer(writer: &MessageWriter, id: Option<Value>, result: Result<Value, Failure>) -> bool {
    let (data, error_code, error) = match result {
        Ok(value) => (Some(value), None, None),
        Err((code, message)) => (None, Some(code.to_owned()), Some(message.to_owned())),
    };
    send_response(
        writer,
        Response { id, ok: error.is_none(), data, error, error_code, error_delivery: None },
    )
}

/// Resolve only records this daemon owns. Named homes also carry their complete Chief id,
/// so a colliding short directory never makes one Chief's work look like another's.
fn target(mux: &Mux, chief: &str) -> Result<(PathBuf, PathBuf), Failure> {
    let mut slot = mux.chiefs().store.lock().map_err(|_| UNAVAILABLE)?;
    if slot.is_none() {
        *slot = Some(
            ChiefStore::open(mux.session_state_directory().as_deref()).map_err(|_| UNAVAILABLE)?,
        );
    }
    let known = slot.as_ref().ok_or(UNAVAILABLE)?.get(chief).map_err(|_| UNAVAILABLE)?.is_some();
    drop(slot);
    if !known {
        return Err(("chief.work_not_found", "This Chief is no longer available."));
    }
    let root = super::chief_engine_mirror::engine_file(
        DEFAULT_CHIEF,
        crate::chief_brains::configured_home().as_deref(),
        super::chief_inspect::tools_socket().as_deref(),
    )
    .and_then(|file| file.parent()?.parent().map(Path::to_path_buf))
    .ok_or(("chief.work_not_configured", "This machine does not host the Chief's work."))?;
    let home = if chief == DEFAULT_CHIEF {
        root.clone()
    } else {
        let home = crate::chief_brains::brain_home(&root, chief);
        if std::fs::read_to_string(home.join("chief-id")).ok().as_deref().map(str::trim)
            != Some(chief)
        {
            return Err(UNAVAILABLE);
        }
        home
    };
    // SAFETY: geteuid has no preconditions; only this user's configured Chief socket is used.
    let uid = unsafe { libc::geteuid() };
    let socket =
        cmux_agent_pane_policy::environment::default_socket_path(&root.join("acpmux"), uid);
    Ok((home, PathBuf::from(socket)))
}

/// The brain pins this id when it first starts. Older homes used the path's FNV-1a.
fn home_id(home: &Path) -> String {
    if let Ok(text) = std::fs::read_to_string(home.join("optchat/home-id")) {
        let id = text.trim();
        if id.len() == 8 && id.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()) {
            return id.to_owned();
        }
    }
    let hash = home
        .as_os_str()
        .as_encoded_bytes()
        .iter()
        .fold(0x811c_9dc5_u32, |hash, b| (hash ^ u32::from(*b)).wrapping_mul(0x0100_0193));
    format!("{hash:08x}")
}

fn string<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str).filter(|v| !v.is_empty())
}

/// All reads share a deadline. A failed later page is an error, never an empty or partial
/// success. The explicit truncation flag covers bounded inventory, not failed reads.
fn inventory(
    home: &str,
    mut call: impl FnMut(&str, Value, Duration) -> Result<Value, Failure>,
) -> Result<Value, Failure> {
    let deadline = Instant::now() + TIMEOUT;
    let mut ask = |method: &str, params: Value| {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(UNAVAILABLE);
        }
        call(method, params, left)
    };
    let mut all = Vec::new();
    let mut cursor: Option<String> = None;
    let mut cursors = HashSet::new();
    loop {
        let mut params = json!({"limit": PAGE});
        if let (Some(cursor), Some(fields)) = (&cursor, params.as_object_mut()) {
            fields.insert("cursor".into(), Value::String(cursor.clone()));
        }
        let reply = ask("_acpmux/sessions", params)?;
        all.extend(
            reply.get("sessions").and_then(Value::as_array).ok_or(UNAVAILABLE)?.iter().cloned(),
        );
        cursor = next_cursor(&reply, &mut cursors)?;
        if cursor.is_none() {
            break;
        }
    }
    let (owned, children) = family(home, &all);
    let mut truncated = owned.len() > MAX_SESSIONS;
    let mut sessions: Vec<&Value> = all
        .iter()
        .filter(|s| string(s, "sessionId").is_some_and(|id| owned.contains(id)))
        .collect();
    // Read active sessions first; the source's newest-first order settles ties.
    sessions.sort_by_key(|s| !matches!(string(s, "status"), Some("running" | "waiting")));
    sessions.truncate(MAX_SESSIONS);
    let agents: Vec<Value> = sessions
        .iter()
        .filter(|s| string(s, "sessionId").is_some_and(|id| children.contains(id)))
        .map(|s| agent(s))
        .collect();
    let mut tasks = Vec::new();
    let mut sessions = sessions.into_iter().peekable();
    while let Some(session) = sessions.next() {
        let id = string(session, "sessionId").ok_or(UNAVAILABLE)?;
        let mut cursor: Option<String> = None;
        let mut cursors = HashSet::new();
        loop {
            let mut params = json!({"sessionId": id, "limit": PAGE});
            if let (Some(cursor), Some(fields)) = (&cursor, params.as_object_mut()) {
                fields.insert("cursor".into(), Value::String(cursor.clone()));
            }
            let reply = ask("_acpmux/process/list", params)?;
            let rows = reply.get("processes").and_then(Value::as_array).ok_or(UNAVAILABLE)?;
            for row in rows {
                if string(row, "sessionId") != Some(id) {
                    return Err(UNAVAILABLE);
                }
                if tasks.len() < MAX_TASKS {
                    tasks.push(task(row));
                } else {
                    truncated = true;
                }
            }
            cursor = next_cursor(&reply, &mut cursors)?;
            if cursor.is_none() {
                break;
            }
            if tasks.len() >= MAX_TASKS {
                truncated = true;
                break;
            }
        }
        if tasks.len() >= MAX_TASKS {
            truncated |= sessions.peek().is_some();
            break;
        }
    }
    Ok(
        json!({"agents": agents, "tasks": tasks, "truncated": truncated, "taskSources": ["harness"]}),
    )
}

fn next_cursor(reply: &Value, seen: &mut HashSet<String>) -> Result<Option<String>, Failure> {
    match reply.get("nextCursor") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(cursor)) if !cursor.is_empty() && seen.insert(cursor.clone()) => {
            Ok(Some(cursor.clone()))
        }
        _ => Err(UNAVAILABLE),
    }
}

/// Parent links extend ownership to any depth; peers and a differently tagged Chief never
/// join the family. Chief turn/compactor roots provide task scope but are not subagent rows.
fn family(home: &str, sessions: &[Value]) -> (HashSet<String>, HashSet<String>) {
    let tag = format!("optchat-chief:{home}");
    let mut owned = HashSet::new();
    let mut children = HashSet::new();
    let mut by_parent: HashMap<&str, Vec<&Value>> = HashMap::new();
    for session in sessions.iter().filter(|s| s.get("peer").is_none_or(Value::is_null)) {
        let Some(id) = string(session, "sessionId") else { continue };
        let chief = session.pointer("/tags/cmux.chief").and_then(Value::as_str);
        let parent = session.pointer("/tags/mux.parent").and_then(Value::as_str);
        if chief.is_some_and(|chief| chief != home)
            || parent.is_some_and(|p| p.starts_with("optchat-chief:") && p != tag)
        {
            continue;
        }
        if chief == Some(home) || parent == Some(tag.as_str()) {
            owned.insert(id.to_owned());
            if parent == Some(tag.as_str()) {
                children.insert(id.to_owned());
            }
        }
        for parent in
            ["parent", "startedBy", "spawnedBy"].into_iter().filter_map(|key| string(session, key))
        {
            by_parent.entry(parent).or_default().push(session);
        }
    }
    let mut queue: VecDeque<String> = owned.iter().cloned().collect();
    while let Some(parent) = queue.pop_front() {
        for session in by_parent.get(parent.as_str()).into_iter().flatten() {
            let Some(id) = string(session, "sessionId") else { continue };
            if owned.insert(id.to_owned()) {
                children.insert(id.to_owned());
                queue.push_back(id.to_owned());
            }
        }
    }
    (owned, children)
}

fn agent(raw: &Value) -> Value {
    let state = match string(raw, "state").or_else(|| string(raw, "status")) {
        Some("running" | "stopping") => "working",
        Some("waiting") => "waiting",
        Some("stuck" | "disconnected" | "unreachable") => "failed",
        _ if matches!(string(raw, "indicator"), Some("failed" | "lost"))
            || raw.pointer("/lastTurn/status").and_then(Value::as_str) == Some("failed") =>
        {
            "failed"
        }
        _ => "idle",
    };
    json!({"id": raw.get("sessionId"), "name": string(raw, "name").or_else(|| string(raw, "title")).unwrap_or("Agent"),
        "state": state, "task": string(raw, "title").or_else(|| string(raw, "lastPrompt")),
        "startedAt": raw.get("createdAt"), "updatedAt": raw.get("updatedAt")})
}

fn task(raw: &Value) -> Value {
    let status = match string(raw, "state") {
        Some("running") => "running",
        Some("exited") if raw.get("exitCode").and_then(Value::as_i64).is_none_or(|c| c == 0) => {
            "done"
        }
        Some("failed" | "exited") => "failed",
        Some("killed") => "cancelled",
        _ => "unknown",
    };
    json!({"id": raw.get("id"), "sessionId": raw.get("sessionId"), "title": raw.get("command"), "command": raw.get("command"),
        "status": status, "startedAt": raw.get("startedAt"), "endedAt": raw.get("endedAt"), "detail": raw.get("detail")})
}

#[cfg(test)]
#[path = "chief_work_tests.rs"]
mod tests;
