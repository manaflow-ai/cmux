//! File and secret requests from a Cloud machine's agents
//! (`access-request-v1` on the machine daemon, cmux-tui-core
//! `server/access_requests.rs`).
//!
//! On the machine, an agent runs `request`: it files the request with its
//! own daemon and waits for the answer. On this Mac the app runs `triage`
//! and `answer` through the machine link:
//!
//! - `triage` answers what needs no person: a path inside a folder the chat
//!   was granted whose copy on the machine has it is delivered at that copy;
//!   otherwise a path the rules never share on its own (outside the home
//!   folder, the home folder itself, `~/Library`, anything in a dot folder
//!   or a secret file, judged from the path as written so the answer tells
//!   the machine nothing about this Mac) is denied. Everything else is listed for the person (the
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
//! - A secret request (`request --secret NAME`) is never answered without
//!   the person: `triage` always lists it, and only `answer --share-secret
//!   NAME`, naming the secret the person saw, answers it, with the value
//!   the app writes to its stdin. The value is for that one request: it is
//!   never in argv, never printed, logged or written here, and no grant or
//!   "always" keeps it. The machine daemon answers it to the asking
//!   agent's first status read only.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use zeroize::{Zeroize as _, Zeroizing};

use super::grants::{self, Mode, Store};
use super::{Failure, grant, is_secret, shared_file};
use crate::link::sync_cli;

/// How long `request` polls between status questions.
const POLL: Duration = Duration::from_millis(500);
/// The largest secret value shared (the machine daemon's limit too).
const MAX_SECRET_BYTES: usize = 64 * 1024;

/// What an agent asks for.
#[derive(Clone, Copy)]
pub(super) enum Asked<'a> {
    /// A file or folder of the Mac, by its absolute path there.
    File(&'a str),
    /// A secret, by name.
    Secret(&'a str),
}

/// `request`: files a request with this machine's daemon and waits for the
/// answer.
pub(super) fn request(
    socket: Option<&Path>,
    session: Option<&str>,
    reason: Option<&str>,
    timeout: Duration,
    asked: Asked<'_>,
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
    let params = match asked {
        Asked::File(path) if path.starts_with('/') => {
            json!({"kind": "file", "path": path, "session": session, "reason": reason})
        }
        Asked::File(_) => {
            return Err(Failure::new("bad_path", "name the file by its absolute path on the Mac"));
        }
        Asked::Secret(name) => {
            json!({"kind": "secret", "name": name, "session": session, "reason": reason})
        }
    };
    let made =
        sync_cli::machine_call(&socket, "access-request", params).map_err(machine_failure)?;
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
                return match asked {
                    Asked::File(_) => Ok(json!({"request_id": request_id, "state": "delivered",
                                                "path": status["path"]})),
                    // The value is this agent's to use; the daemon has
                    // forgotten it.
                    Asked::Secret(name) => match status["value"].as_str() {
                        Some(value) => Ok(json!({"request_id": request_id, "state": "delivered",
                                                 "name": name, "value": value})),
                        None => Err(Failure::new(
                            "secret_taken",
                            "the secret was shared, but another read took it first",
                        )),
                    },
                };
            }
            Some("denied") => {
                let why = status["reason"].as_str().unwrap_or("the person did not share it");
                return Err(Failure::new("access_denied", why));
            }
            _ => {}
        }
        if Instant::now() >= deadline {
            // A secret shared after this agent stopped waiting must not sit
            // unread on this machine: withdraw the request. When the person
            // answered meanwhile, the next status read has the answer.
            if let Asked::Secret(_) = asked {
                let withdrawn = sync_cli::machine_call(
                    &socket,
                    "access-request-answer",
                    json!({"request_id": request_id, "outcome": "denied",
                           "reason": "the agent stopped waiting"}),
                );
                if withdrawn.is_err() {
                    continue;
                }
                return Err(Failure::new(
                    "access_pending",
                    format!("no answer in time; secret request {request_id} was withdrawn"),
                ));
            }
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
    /// A file request's path; None for a secret.
    path: Option<String>,
    /// A secret request's name; None for a file.
    name: Option<String>,
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
            // The machine is not trusted: what the card shows is checked
            // here again, and a request that fails is never answered.
            let (path, name) = match request["kind"].as_str()? {
                "file" => (Some(text(&request["path"]).filter(|path| shown(path))?), None),
                "secret" => (None, Some(text(&request["name"]).filter(|name| secret_name(name))?)),
                _ => return None,
            };
            Some(Pending {
                id,
                path,
                name,
                session: text(&request["session"]),
                reason: text(&request["reason"])
                    .map(|reason| reason.chars().filter(|c| shown_char(*c)).collect()),
            })
        })
        .collect())
}

/// A secret's name as the daemon takes them: `A-Za-z0-9._-`, 1 to 128 bytes.
fn secret_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 128
        && name.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

/// Whether `text` is shown to the person as the machine wrote it: no
/// control or bidirectional formatting character that could make it read
/// as something else.
fn shown(text: &str) -> bool {
    text.chars().all(shown_char)
}

fn shown_char(c: char) -> bool {
    !c.is_control()
        && !matches!(
            c,
            '\u{200E}' | '\u{200F}' | '\u{061C}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}'
        )
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
        // A secret is only ever the person's to share.
        if let Some(name) = &request.name {
            ask.push(json!({
                "request_id": request.id,
                "session": session,
                "kind": "secret",
                "name": name,
                "reason": request.reason,
            }));
            continue;
        }
        let Some(path) = request.path.as_deref().and_then(lexical) else {
            deny(socket, &request, &mut answered)?;
            continue;
        };
        // Inside a folder the chat was granted, and in its copy: it is on the
        // machine already (a copy holds no secret file or repository).
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
        if never_shared(&path) {
            deny(socket, &request, &mut answered)?;
            continue;
        }
        let here = std::fs::symlink_metadata(&path).ok();
        let is_dir = here.as_ref().is_some_and(|meta| meta.is_dir());
        ask.push(json!({
            "request_id": request.id,
            "session": session,
            "kind": "file",
            "path": path,
            "reason": request.reason,
            "exists": here.is_some(),
            "folder": is_dir,
            "always_folder": here.is_some().then(|| always_folder(&path, is_dir)),
        }));
    }
    Ok(json!({"answered": answered, "ask": ask}))
}

/// Denies `request` by the rules, without the person.
fn deny(socket: &Path, request: &Pending, answered: &mut Vec<Value>) -> Result<(), Failure> {
    answer_machine(
        socket,
        &request.id,
        json!({"outcome": "denied", "reason": "this file is never shared from the Mac"}),
    )?;
    answered.push(json!({"request_id": request.id, "path": request.path, "outcome": "denied"}));
    Ok(())
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
    /// Shares a secret's value, read from stdin, with this one request.
    ShareSecret,
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
        .filter(|request| request.session.as_deref() == Some(session))
        .ok_or_else(|| {
            Failure::new("request_gone", "the machine has no such pending request of this chat")
        })?;
    if let How::Deny = how {
        let reason = reason.unwrap_or("the person did not share it");
        answer_machine(socket, request_id, json!({"outcome": "denied", "reason": reason}))?;
        return Ok(json!({"request_id": request_id, "outcome": "denied"}));
    }
    if let How::ShareSecret = how {
        // The secret the person saw must be the request's.
        if request.name.as_deref() != path {
            return Err(Failure::new("request_changed", "the request is not for that secret"));
        }
        let value = secret_from_stdin()?;
        answer_machine(
            socket,
            request_id,
            json!({"outcome": "delivered", "value": value.as_str()}),
        )?;
        return Ok(json!({"request_id": request_id, "outcome": "delivered", "name": request.name}));
    }
    // The path the person saw must be the request's.
    let seen = path.and_then(lexical);
    if seen.is_none() || seen != request.path.as_deref().and_then(lexical) {
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

/// The secret value on stdin: UTF-8, not empty, at most
/// [`MAX_SECRET_BYTES`]. Never part of an error.
fn secret_from_stdin() -> Result<Zeroizing<String>, Failure> {
    use std::io::Read as _;
    // Room for one byte past the limit up front, so reading never moves
    // (and leaves behind) a copy.
    let mut bytes = Zeroizing::new(Vec::with_capacity(MAX_SECRET_BYTES + 1));
    std::io::stdin()
        .lock()
        .take(MAX_SECRET_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| Failure::new("bad_secret", format!("cannot read the secret: {error}")))?;
    if bytes.is_empty() || bytes.len() > MAX_SECRET_BYTES {
        return Err(Failure::new("bad_secret", "the secret is empty or larger than 64 KiB"));
    }
    match String::from_utf8(std::mem::take(&mut *bytes)) {
        Ok(value) => Ok(Zeroizing::new(value)),
        Err(error) => {
            error.into_bytes().zeroize();
            Err(Failure::new("bad_secret", "the secret is not UTF-8 text"))
        }
    }
}
