//! Read-only work on this Chief's machine. The owner/Channels page asks for a Chief id;
//! its configured brain home supplies the ownership tag, never a path or session id from JS.
//! Background commands come from acpmux's harness process registry. Daemon-owned `bg` tasks
//! keep their separate person-proof gate; this endpoint does not bypass it.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_json::JsonGet as _;
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
            let home = home_id(&home);
            let result = match inventory_v2(&home, &socket, &link) {
                Ok(Some(work)) => Ok(work),
                // No v2 list: v1's whole list, paged and walked here (a named fallback).
                Ok(None) => inventory(&home, |method, params, timeout| {
                    link.call(method, params, timeout).map_err(|_| UNAVAILABLE)
                }),
                Err(failure) => Err(failure),
            };
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
    let (root, home) = trusted_homes(mux, chief)?;
    // SAFETY: geteuid has no preconditions; only this user's configured Chief socket is used.
    let uid = unsafe { libc::geteuid() };
    let socket =
        cmux_agent_pane_policy::environment::default_socket_path(&root.join("acpmux"), uid);
    Ok((home, PathBuf::from(socket)))
}

/// The configured root and this registered Chief's verified brain home. No directory scan.
pub(super) fn trusted_homes(mux: &Mux, chief: &str) -> Result<(PathBuf, PathBuf), Failure> {
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
    Ok((root, home))
}

/// The brain pins this id when it first starts. Older homes used the path's FNV-1a.
pub(super) fn home_id(home: &Path) -> String {
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
    work(&all, &owned, &children, ask)
}

/// The work of the Chief's chats `owned` among `all` (v1 rows, newest first), `children` its
/// subagents: the active first, at most [`MAX_SESSIONS`], and their commands, `ask` reading each
/// (under the read's one deadline).
fn work(
    all: &[Value],
    owned: &HashSet<String>,
    children: &HashSet<String>,
    mut ask: impl FnMut(&str, Value) -> Result<Value, Failure>,
) -> Result<Value, Failure> {
    let mut truncated = owned.len() > MAX_SESSIONS;
    let mut sessions: Vec<&Value> = all
        .iter()
        .filter(|s| s.get_nonempty_str("sessionId").is_some_and(|id| owned.contains(id)))
        .collect();
    // Read active sessions first; the source's newest-first order settles ties.
    sessions.sort_by_key(|s| !matches!(s.get_nonempty_str("status"), Some("running" | "waiting")));
    sessions.truncate(MAX_SESSIONS);
    let agents: Vec<Value> = sessions
        .iter()
        .filter(|s| s.get_nonempty_str("sessionId").is_some_and(|id| children.contains(id)))
        .map(|s| agent(s))
        .collect();
    let plans = chief_plans(&sessions, children);
    let mut tasks = Vec::new();
    let mut sessions = sessions.into_iter().peekable();
    while let Some(session) = sessions.next() {
        let id = session.get_nonempty_str("sessionId").ok_or(UNAVAILABLE)?;
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
                if row.get_nonempty_str("sessionId") != Some(id) {
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
        json!({"agents": agents, "plans": plans, "tasks": tasks, "truncated": truncated, "taskSources": ["harness"]}),
    )
}

/// [`inventory`] through the v2 list (row 7c), under one deadline: the Chief's chats from
/// [`chief_kin`], then the same [`work`]. `None`: the daemon serves no v2 list or no rows by id,
/// and the caller reads v1's.
fn inventory_v2(home: &str, socket: &Path, link: &AcpmuxLink) -> Result<Option<Value>, Failure> {
    let deadline = Instant::now() + TIMEOUT;
    let Some((all, owned, children)) = chief_kin(home, socket, link, deadline)? else {
        return Ok(None);
    };
    work(&all, &owned, &children, |method, params| {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(UNAVAILABLE);
        }
        link.call(method, params, left).map_err(|_| UNAVAILABLE)
    })
    .map(Some)
}

/// How a chat's `tags` place it for this Chief (v1's rule in [`family`]).
#[derive(Clone, Copy, PartialEq)]
enum Tagged {
    /// Another Chief's: never in the family, nor what is under it.
    Other,
    /// One of this Chief's roots; `child` when the Chief started it (a subagent row).
    Root { child: bool },
    /// Neither: in the family only under one of its chats.
    Untagged,
}

fn tagged(home: &str, tag: &str, tags: Option<&Value>) -> Tagged {
    let chief = tags.and_then(|tags| tags.get("cmux.chief")).and_then(Value::as_str);
    let parent = tags.and_then(|tags| tags.get("mux.parent")).and_then(Value::as_str);
    if chief.is_some_and(|chief| chief != home)
        || parent.is_some_and(|p| p.starts_with("optchat-chief:") && p != tag)
    {
        Tagged::Other
    } else if chief == Some(home) || parent == Some(tag) {
        Tagged::Root { child: parent == Some(tag) }
    } else {
        Tagged::Untagged
    }
}

/// The Chief's chats: their rows as `_acpmux/sessions` writes them (newest first), the ids it
/// owns, and those of them that are subagents.
type ChiefChats = (Vec<Value>, HashSet<String>, HashSet<String>);

/// The Chief's chats as v1's [`family`] finds them, through the v2 list: `(rows, owned,
/// children)`, the rows as `_acpmux/sessions` writes them (by id), newest first.
///
/// `mux.parent` is the Chief's tag and not the list's parent edge, so the roots come from a
/// walk of `live` for this machine's rows, picked by the two tags as v1 picks them (a summary
/// whose `extra` was bounded away is read by id first). Each root's descendants come by `page`
/// with `family` ([`list_source::kin`]), hot and cold, until more than [`MAX_SESSIONS`] are
/// held, so the answer still says `truncated`. Another Chief's chat and what is under it are
/// left out, as v1 leaves them. Where this differs from v1's whole list: a closed root is not
/// found (a walk of `live` cannot see it, and nothing walks `all` for it); past the cap the
/// chats held are the first found, where v1 held every one and kept the active first; and a
/// chat is under its one list parent (decisions 137 and 140), where v1 followed `parent`,
/// `startedBy` and `spawnedBy` alike.
fn chief_kin(
    home: &str,
    socket: &Path,
    link: &AcpmuxLink,
    deadline: Instant,
) -> Result<Option<ChiefChats>, Failure> {
    use super::agent_session_attach::agent_session_link::list_source::{
        self, INFO_ROWS, Opened, bounded_away, extras, rows_by_id,
    };
    use acpmux_client::wire::{ListFilter, ListView};
    use std::ops::ControlFlow;
    if !link.capabilities(None, TIMEOUT).iter().any(|c| c == INFO_ROWS) {
        return Ok(None);
    }
    let left = || deadline.saturating_duration_since(Instant::now());
    let mut source = match list_source::open(socket, left()).map_err(|_| UNAVAILABLE)? {
        Opened::List(source) => source,
        Opened::V1 => return Ok(None),
    };
    let tag = format!("optchat-chief:{home}");
    let mut roots: Vec<(String, bool)> = Vec::new();
    let mut unread = Vec::new();
    let local = ListFilter { origin: Some("local".into()), ..ListFilter::default() };
    source
        .walk(ListView::Live, Some(local), |rows| {
            for row in rows {
                if bounded_away(&row) {
                    unread.push(row.chat_id);
                } else if let Tagged::Root { child } = tagged(home, &tag, extras(&row).get("tags"))
                {
                    roots.push((row.chat_id, child));
                }
            }
            ControlFlow::Continue(())
        })
        .map_err(|_| UNAVAILABLE)?;
    for row in rows_by_id(link, unread, left()).map_err(|_| UNAVAILABLE)? {
        if let (Some(id), Tagged::Root { child }) =
            (row.get_nonempty_str("sessionId"), tagged(home, &tag, row.get("tags")))
        {
            roots.push((id.to_owned(), child));
        }
    }
    let (mut owned, mut children) = (HashSet::new(), HashSet::new());
    for (id, child) in &roots {
        if owned.insert(id.clone()) && *child {
            children.insert(id.clone());
        }
    }
    let mut found = Vec::new();
    for (root, _) in &roots {
        if owned.len() > MAX_SESSIONS {
            break;
        }
        let room = MAX_SESSIONS + 1 - owned.len();
        for row in list_source::kin(&mut source, root, room, true).map_err(|_| UNAVAILABLE)? {
            if owned.insert(row.chat_id.clone()) {
                children.insert(row.chat_id.clone());
                found.push(row);
            }
        }
    }
    let all = rows_by_id(link, owned.iter().cloned().collect(), left()).map_err(|_| UNAVAILABLE)?;
    let tags: HashMap<&str, Option<&Value>> = all
        .iter()
        .filter_map(|row| Some((row.get_nonempty_str("sessionId")?, row.get("tags"))))
        .collect();
    // Each kin's rows come parent first, so a chat under a left-out one is left out too.
    let mut left_out: HashSet<String> = HashSet::new();
    for row in &found {
        let under = row.parent.as_ref().is_some_and(|parent| left_out.contains(&*parent.chat_id));
        let other = tags
            .get(row.chat_id.as_str())
            .is_some_and(|tags| tagged(home, &tag, *tags) == Tagged::Other);
        if under || other {
            left_out.insert(row.chat_id.clone());
        }
    }
    owned.retain(|id| !left_out.contains(id));
    children.retain(|id| !left_out.contains(id));
    Ok(Some((all, owned, children)))
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
        let Some(id) = session.get_nonempty_str("sessionId") else { continue };
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
        for parent in ["parent", "startedBy", "spawnedBy"]
            .into_iter()
            .filter_map(|key| session.get_nonempty_str(key))
        {
            by_parent.entry(parent).or_default().push(session);
        }
    }
    let mut queue: VecDeque<String> = owned.iter().cloned().collect();
    while let Some(parent) = queue.pop_front() {
        for session in by_parent.get(parent.as_str()).into_iter().flatten() {
            let Some(id) = session.get_nonempty_str("sessionId") else { continue };
            if owned.insert(id.to_owned()) {
                children.insert(id.to_owned());
                queue.push_back(id.to_owned());
            }
        }
    }
    (owned, children)
}

fn agent(raw: &Value) -> Value {
    let state = match raw.get_nonempty_str("state").or_else(|| raw.get_nonempty_str("status")) {
        Some("running" | "stopping") => "working",
        Some("waiting") => "waiting",
        Some("stuck" | "disconnected" | "unreachable") => "failed",
        _ if matches!(raw.get_nonempty_str("indicator"), Some("failed" | "lost"))
            || raw.pointer("/lastTurn/status").and_then(Value::as_str) == Some("failed") =>
        {
            "failed"
        }
        _ => "idle",
    };
    json!({"id": raw.get("sessionId"), "name": raw.get_nonempty_str("name").or_else(|| raw.get_nonempty_str("title")).unwrap_or("Agent"),
        "state": state, "task": raw.get_nonempty_str("title").or_else(|| raw.get_nonempty_str("lastPrompt")),
        "startedAt": raw.get("createdAt"), "updatedAt": raw.get("updatedAt"), "plan": plan(raw)})
}

/// The chat's kept task list (acpmux `taskList`, task_list.rs) as its list row carries it: the
/// counts, the step in progress and the next one. Null when the chat keeps none, or an empty one.
/// The rows already hold it, so the plans cost no read of their own.
fn plan(raw: &Value) -> Value {
    let Some(list) = raw.get("taskList").filter(|list| list.is_object()) else {
        return Value::Null;
    };
    let count = |key: &str| list.get(key).and_then(Value::as_u64).unwrap_or(0);
    let (done, total) = (count("done"), count("total"));
    if total == 0 {
        return Value::Null;
    }
    let source = match list.get_nonempty_str("source") {
        Some(source @ ("agent" | "chief")) => source,
        _ => "harness",
    };
    json!({"source": source, "done": done.min(total), "total": total,
        "current": list.get_nonempty_str("current"), "next": list.get_nonempty_str("next"),
        "updatedAt": list.get("updatedAt")})
}

/// The Chief's own chats (owned, not subagents) that keep a plan: what the person asked the Chief
/// to do, as the Chief planned it.
fn chief_plans(sessions: &[&Value], children: &HashSet<String>) -> Vec<Value> {
    sessions
        .iter()
        .filter(|s| s.get_nonempty_str("sessionId").is_some_and(|id| !children.contains(id)))
        .filter_map(|s| {
            let plan = plan(s);
            (!plan.is_null()).then(|| {
                let mut row = agent(s);
                row["plan"] = plan;
                row
            })
        })
        .collect()
}

fn task(raw: &Value) -> Value {
    let status = match raw.get_nonempty_str("state") {
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
