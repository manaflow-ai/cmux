//! File requests from a Cloud machine's agents (`access-request-v1` on the
//! machine daemon, cmux-tui-core `server/access_requests.rs`).
//!
//! On the machine, an agent runs `request`: it files the request with its
//! own daemon and waits for the answer. On this Mac the app runs `triage`
//! and `answer` through the machine link:
//!
//! - `triage` answers what needs no person: a path the rules never share
//!   (outside the home folder, the home folder itself, `~/Library`, a dot
//!   folder or a secret file, judged from the path as written so the answer
//!   tells the machine nothing about this Mac) is denied; a path inside a
//!   folder the chat was granted whose copy on the machine has it is
//!   delivered at that copy. Everything else is listed for the person (the
//!   inline card). Only requests of the chats named by `--session` are
//!   touched.
//! - `answer` carries the person's answer to one request: `--allow` copies
//!   the file or folder once to `DIR/local/requests/<request id>/<name>`,
//!   `--always` shares its folder with the chat (a read-only grant of the
//!   folder, or of a file's folder) and answers at the copy, `--deny` denies.
//!   The path the person saw is named again and must still be the
//!   machine's pending request of that chat; the file is checked again here
//!   (canonical, so a symlink is judged by where it leads) before anything
//!   goes.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::grants::{self, Mode, Store};
use super::{Failure, grant, is_secret, shared_file};
use crate::link::sync_cli;

/// How long `request` polls between status questions.
const POLL: Duration = Duration::from_millis(500);

/// `request`: files a request with this machine's daemon and waits for the
/// answer.
pub(super) fn request(
    socket: Option<&Path>,
    session: Option<&str>,
    reason: Option<&str>,
    timeout: Duration,
    path: &str,
) -> Result<Value, Failure> {
    let socket = match socket {
        Some(socket) => socket.to_path_buf(),
        None => default_socket()?,
    };
    let session = match session {
        Some(session) => session.to_string(),
        None => std::env::var("CMUX_AGENT_SESSION")
            .ok()
            .filter(|session| grants::plain_id(session))
            .ok_or_else(|| {
                Failure::new(
                    "no_session",
                    "no chat to ask for: set --session or CMUX_AGENT_SESSION",
                )
            })?,
    };
    if !path.starts_with('/') {
        return Err(Failure::new("bad_path", "name the file by its absolute path on the Mac"));
    }
    let made = sync_cli::machine_call(
        &socket,
        "access-request",
        json!({"kind": "file", "path": path, "session": session, "reason": reason}),
    )
    .map_err(machine_failure)?;
    let request_id = made["request_id"].as_str().unwrap_or_default().to_string();
    let deadline = Instant::now() + timeout;
    loop {
        let status = sync_cli::machine_call(
            &socket,
            "access-request-status",
            json!({"request_id": request_id}),
        )
        .map_err(machine_failure)?;
        match status["state"].as_str() {
            Some("delivered") => {
                return Ok(json!({"request_id": request_id, "state": "delivered",
                                 "path": status["path"]}));
            }
            Some("denied") => {
                let why = status["reason"].as_str().unwrap_or("the person did not share it");
                return Err(Failure::new("access_denied", why));
            }
            _ => {}
        }
        if Instant::now() >= deadline {
            return Err(Failure::new(
                "access_pending",
                format!("no answer yet; request {request_id} is still waiting for the person"),
            ));
        }
        std::thread::sleep(POLL);
    }
}

/// The machine daemon's socket when none is named: the daemon this
/// terminal or agent runs under, else the Cloud machine's session.
fn default_socket() -> Result<PathBuf, Failure> {
    if let Some(socket) = std::env::var_os("CMUX_TUI_SOCKET").filter(|socket| !socket.is_empty()) {
        return Ok(PathBuf::from(socket));
    }
    cmux_tui_core::server::try_default_socket_path("cloud")
        .map_err(|error| Failure::new("no_socket", format!("{error:#}")))
}

fn machine_failure(error: anyhow::Error) -> Failure {
    Failure::new(&sync_cli::push_failure_code(&error), format!("{error:#}"))
}

/// One pending request as the machine lists it.
struct Pending {
    id: String,
    kind: String,
    path: String,
    session: Option<String>,
    reason: Option<String>,
}

fn pending(socket: &Path) -> Result<Vec<Pending>, Failure> {
    let listed = sync_cli::machine_call(socket, "access-request-list", json!({}))
        .map_err(machine_failure)?;
    let text = |value: &Value| value.as_str().map(str::to_string);
    Ok(listed["requests"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        .filter_map(|request| {
            let id = text(&request["request_id"]).filter(|id| plain_request_id(id))?;
            Some(Pending {
                id,
                kind: text(&request["kind"])?,
                path: text(&request["path"])?,
                session: text(&request["session"]),
                reason: text(&request["reason"]),
            })
        })
        .collect())
}

/// A request id as the daemon makes them: 32 lowercase hex digits. Anything
/// else is never used (it names a folder on the machine).
fn plain_request_id(id: &str) -> bool {
    id.len() == 32 && id.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// `path` with `.` and `..` resolved as written; None when relative or when
/// it climbs above the root.
fn lexical(path: &str) -> Option<PathBuf> {
    if !path.starts_with('/') {
        return None;
    }
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop()?;
            }
            part => parts.push(part),
        }
    }
    Some(PathBuf::from(format!("/{}", parts.join("/"))))
}

/// Whether the rules never share `path` (lexical, absolute), judged from the
/// path as written: outside the home folder, the home folder itself,
/// `~/Library`, a dot folder or a secret file.
fn never_shared(path: &Path) -> bool {
    let homes = grants::homes();
    let Some(inside) = homes.iter().find_map(|home| path.strip_prefix(home).ok()) else {
        return true;
    };
    let names: Vec<String> =
        inside.components().map(|part| part.as_os_str().to_string_lossy().into_owned()).collect();
    names.is_empty()
        || names.iter().any(|name| name.starts_with('.'))
        || names[0].eq_ignore_ascii_case("Library")
        || is_secret(&names.join("/"))
}

/// `triage --socket PATH --machine ID --session ID...`.
pub(super) fn triage(socket: &Path, machine: &str, sessions: &[String]) -> Result<Value, Failure> {
    let store = Store::open()?;
    let mut answered = Vec::new();
    let mut ask = Vec::new();
    for request in pending(socket)? {
        let Some(session) = request.session.as_deref().filter(|s| sessions.iter().any(|x| x == s))
        else {
            continue;
        };
        if request.kind != "file" {
            continue;
        }
        let path = lexical(&request.path).filter(|path| !never_shared(path));
        let Some(path) = path else {
            answer_machine(
                socket,
                &request.id,
                json!({"outcome": "denied",
                "reason": "this file is never shared from the Mac"}),
            )?;
            answered.push(json!({"request_id": request.id, "path": request.path,
                                 "outcome": "denied"}));
            continue;
        };
        let granted = store.grants.iter().find_map(|grant| {
            let inside = path.strip_prefix(&grant.folder).ok()?;
            (grant.machine == machine && grant.session == session).then(|| {
                let inside = inside.to_string_lossy();
                if inside.is_empty() {
                    grant.remote.clone()
                } else {
                    format!("{}/{inside}", grant.remote)
                }
            })
        });
        if let Some(at) = granted
            && sync_cli::remote_kind(socket, &at).map_err(machine_failure)?.is_some()
        {
            answer_machine(socket, &request.id, json!({"outcome": "delivered", "path": at}))?;
            answered.push(json!({"request_id": request.id, "path": request.path,
                                 "outcome": "delivered", "at": at}));
            continue;
        }
        let here = std::fs::symlink_metadata(&path).ok();
        let is_dir = here.as_ref().is_some_and(|meta| meta.is_dir());
        ask.push(json!({
            "request_id": request.id,
            "session": session,
            "path": path,
            "reason": request.reason,
            "exists": here.is_some(),
            "folder": is_dir,
            "always_folder": here.is_some().then(|| always_folder(&path, is_dir)),
        }));
    }
    Ok(json!({"answered": answered, "ask": ask}))
}

fn answer_machine(socket: &Path, request_id: &str, mut answer: Value) -> Result<(), Failure> {
    answer["request_id"] = json!(request_id);
    sync_cli::machine_call(socket, "access-request-answer", answer).map_err(machine_failure)?;
    Ok(())
}

/// The folder "Always" shares for `path`: a git working copy's top folder
/// when it is in one (only a whole working copy can be shared), else the
/// folder itself, or a file's folder.
fn always_folder(path: &Path, is_dir: bool) -> PathBuf {
    let folder = if is_dir { path } else { path.parent().unwrap_or(path) };
    sync_cli::git_top(folder).unwrap_or_else(|| folder.to_path_buf())
}

/// The person's answer to one request.
pub(super) enum How {
    Allow,
    Always,
    Deny,
}

/// `answer`: the person's answer to request `request_id` of chat `session`.
#[allow(clippy::too_many_arguments)]
pub(super) fn answer(
    socket: &Path,
    machine: &str,
    session: &str,
    request_id: &str,
    root: Option<&str>,
    how: How,
    path: Option<&str>,
    reason: Option<&str>,
) -> Result<Value, Failure> {
    if !plain_request_id(request_id) {
        return Err(Failure::new("bad_request", "not a request id"));
    }
    let request = pending(socket)?
        .into_iter()
        .find(|request| request.id == request_id)
        .filter(|request| request.session.as_deref() == Some(session) && request.kind == "file")
        .ok_or_else(|| {
            Failure::new("request_gone", "the machine has no such pending request of this chat")
        })?;
    if let How::Deny = how {
        let reason = reason.unwrap_or("the person did not share it");
        answer_machine(socket, request_id, json!({"outcome": "denied", "reason": reason}))?;
        return Ok(json!({"request_id": request_id, "outcome": "denied"}));
    }
    // The path the person saw must be the request's.
    let seen = path.and_then(lexical);
    if seen.is_none() || seen != lexical(&request.path) {
        return Err(Failure::new("request_changed", "the request is not for that path"));
    }
    let root = root.ok_or_else(|| Failure::new("bad_request", "--remote-root is needed"))?;
    let (canonical, is_dir) = grants::shareable_item(Path::new(path.unwrap_or_default()))
        .map_err(|why| Failure::new("grant_refused", why))?;
    let at = if let How::Allow = how {
        let name = canonical
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "file".to_string());
        let at = format!("{root}/local/requests/{request_id}/{name}");
        let copied = if is_dir {
            let keep = |relative: &str, git: bool| shared_file(&canonical, relative, git);
            sync_cli::push_kept(socket, &canonical, &at, &keep).map(|_| ())
        } else {
            sync_cli::copy_file(socket, &canonical, &at)
        };
        copied.map_err(machine_failure)?;
        at
    } else {
        let folder = always_folder(&canonical, is_dir);
        let granted = grant(socket, machine, session, root, Mode::Read, &folder)?;
        let remote = granted["grant"]["remote"].as_str().unwrap_or_default().to_string();
        let inside = canonical.strip_prefix(&folder).unwrap_or(Path::new(""));
        if inside.as_os_str().is_empty() {
            remote
        } else {
            let at = format!("{remote}/{}", inside.to_string_lossy());
            // A file the copy leaves out (ignored by git) still goes: the
            // person shared it.
            if sync_cli::remote_kind(socket, &at).map_err(machine_failure)?.is_none() {
                sync_cli::copy_file(socket, &canonical, &at).map_err(machine_failure)?;
            }
            at
        }
    };
    answer_machine(socket, request_id, json!({"outcome": "delivered", "path": at}))?;
    Ok(json!({"request_id": request_id, "outcome": "delivered", "at": at}))
}
