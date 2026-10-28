//! File and secret requests from a Cloud machine's agents
//! (`access-request-v1` on the machine daemon, cmux-tui-core
//! `server/agent_transfer/access_requests.rs`).
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
//!   the machine nothing about this Mac) is denied. Everything else is
//!   listed for the person (the inline card) with this Mac's view of it:
//!   where it leads (`target`, canonical), whether it may be shared, and
//!   the folder Always would share. Only requests of the chats named by
//!   `--session` are touched.
//! - `answer` carries the person's answer to one request: `--allow` copies
//!   the file once to `DIR/local/requests/<request id>/<name>`, `--always`
//!   shares its folder with the chat (a read-only grant; a grant of the chat
//!   that already covers it is kept as it is) and answers at the copy,
//!   `--deny` denies. The app names again what the card showed (the path,
//!   `--target`, and for Always `--folder`); each must still be what this
//!   Mac sees, or nothing goes (`request_changed`).
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
use super::{Failure, grant, is_secret};
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
    let mut withdraws = 0;
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
                withdraws += 1;
                if withdrawn.is_err() && withdraws < 3 {
                    cmux_blocking::thread::sleep(POLL);
                    continue;
                }
                let what =
                    if withdrawn.is_ok() { "was withdrawn" } else { "could not be withdrawn" };
                return Err(Failure::new(
                    "access_pending",
                    format!("no answer in time; secret request {request_id} {what}"),
                ));
            }
            return Err(Failure::new(
                "access_pending",
                format!("no answer yet; request {request_id} is still waiting for the person"),
            ));
        }
        cmux_blocking::thread::sleep(POLL);
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
            // here again. A file path that fails is denied (no path); a
            // secret name that fails is never answered.
            let (path, name) = match request["kind"].as_str()? {
                "file" => (text(&request["path"]).filter(|path| shown(path)), None),
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
            '\u{061C}'
                | '\u{200B}'..='\u{200F}'
                | '\u{2028}'..='\u{202E}'
                | '\u{2066}'..='\u{2069}'
                | '\u{FEFF}'
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

/// `triage --socket PATH --machine ID --session ID...`. A request that
/// fails (the machine answered it meanwhile, a link error) is reported in
/// `errors` and the others go on.
pub(super) fn triage(socket: &Path, machine: &str, sessions: &[String]) -> Result<Value, Failure> {
    let store = Store::open()?;
    let mut answered = Vec::new();
    let mut ask = Vec::new();
    let mut errors = Vec::new();
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
        match triage_one(&store, socket, machine, session, &request) {
            Ok(Triaged::Answered(line)) => answered.push(line),
            Ok(Triaged::Ask(line)) => ask.push(line),
            Err(failure) => errors.push(json!({"request_id": request.id,
                                               "error": failure.error,
                                               "error_code": failure.code})),
        }
    }
    Ok(json!({"answered": answered, "ask": ask, "errors": errors}))
}

enum Triaged {
    Answered(Value),
    Ask(Value),
}

fn triage_one(
    store: &Store,
    socket: &Path,
    machine: &str,
    session: &str,
    request: &Pending,
) -> Result<Triaged, Failure> {
    let Some(path) = request.path.as_deref().and_then(lexical) else {
        return deny(socket, request);
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
        return Ok(Triaged::Answered(json!({"request_id": request.id, "path": request.path,
                                           "outcome": "delivered", "at": at})));
    }
    if never_shared(&path) {
        return deny(socket, request);
    }
    // What the card shows is this Mac's view of the item, read here and
    // never sent to the machine: where it leads (`target`), whether it may
    // be shared, and the folder Always would share. `answer` is given them
    // back and refuses when they changed.
    let exists = cmux_blocking::fs::symlink_metadata(&path).is_ok();
    let item = grants::shareable_item(&path).ok();
    let always = item.as_ref().and_then(|(target, is_dir)| {
        covering(&store.grants, machine, session, target)
            .map(|grant| PathBuf::from(&grant.folder))
            .or_else(|| always_folder(target, *is_dir))
    });
    Ok(Triaged::Ask(json!({
        "request_id": request.id,
        "session": session,
        "kind": "file",
        "path": path,
        "reason": request.reason,
        "exists": exists,
        "shareable": item.is_some(),
        "target": item.as_ref().map(|(target, _)| target),
        "folder": item.as_ref().map(|(_, is_dir)| *is_dir),
        "always_folder": always,
    })))
}

/// Denies `request` by the rules, without the person.
fn deny(socket: &Path, request: &Pending) -> Result<Triaged, Failure> {
    answer_machine(
        socket,
        &request.id,
        json!({"outcome": "denied", "reason": "this file is never shared from the Mac"}),
    )?;
    Ok(Triaged::Answered(json!({"request_id": request.id, "path": request.path,
                                "outcome": "denied"})))
}

fn answer_machine(socket: &Path, request_id: &str, mut answer: Value) -> Result<(), Failure> {
    answer["request_id"] = json!(request_id);
    sync_cli::machine_call(socket, "access-request-answer", answer).map_err(machine_failure)?;
    Ok(())
}

/// The folder "Always" shares for the canonical item `target`: a git
/// working copy's top folder when it is in one (only a whole working copy
/// can be shared), else the folder itself, or a file's folder. None when
/// that folder may not be shared.
fn always_folder(target: &Path, is_dir: bool) -> Option<PathBuf> {
    let folder = if is_dir { target } else { target.parent()? };
    let ceiling = std::env::join_paths(grants::homes()).ok()?;
    let top = sync_cli::git_top(folder, &ceiling).unwrap_or_else(|| folder.to_path_buf());
    grants::shareable(&top).ok()
}

/// The person's answer to one request.
pub(super) enum How {
    Allow,
    Always,
    /// Shares a secret's value, read from stdin, with this one request.
    ShareSecret,
    Deny,
}

/// What the card showed the person, which `answer` checks again.
pub(super) struct Shown<'a> {
    /// The path asked for, as the machine wrote it.
    pub path: Option<&'a str>,
    /// Where it led (`triage`'s `target`).
    pub target: Option<&'a str>,
    /// The folder Always shares (`triage`'s `always_folder`).
    pub folder: Option<&'a str>,
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
    shown: Shown<'_>,
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
        if request.name.as_deref() != shown.path {
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
    let changed = |what: &str| Failure::new("request_changed", what);
    // The path the person saw must be the request's.
    let seen = shown.path.and_then(lexical);
    let Some(seen) =
        seen.filter(|seen| Some(seen) == request.path.as_deref().and_then(lexical).as_ref())
    else {
        return Err(changed("the request is not for that path"));
    };
    let root = root.ok_or_else(|| Failure::new("bad_request", "--remote-root is needed"))?;
    let (target, is_dir) =
        grants::shareable_item(&seen).map_err(|why| Failure::new("grant_refused", why))?;
    // And it must still lead where the card said.
    if shown.target.map(Path::new) != Some(target.as_path()) {
        return Err(changed("the file changed since the person was asked"));
    }
    let name = target
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "file".to_string());
    let once = format!("{root}/local/requests/{request_id}/{name}");
    let at = if let How::Allow = how {
        // Once is for one file; a folder is shared with Always, whose
        // folder the card names.
        if is_dir {
            return Err(Failure::new("grant_refused", "a folder is shared with Always, not once"));
        }
        sync_cli::copy_file(socket, &target, &once).map_err(machine_failure)?;
        once
    } else {
        always(socket, machine, session, root, &target, is_dir, shown.folder, &once)?
    };
    answer_machine(socket, request_id, json!({"outcome": "delivered", "path": at}))?;
    Ok(json!({"request_id": request_id, "outcome": "delivered", "at": at}))
}

/// The grant of `session` on `machine` that already covers `target`.
fn covering<'a>(
    grants: &'a [grants::Grant],
    machine: &str,
    session: &str,
    target: &Path,
) -> Option<&'a grants::Grant> {
    grants.iter().find(|grant| {
        grant.machine == machine && grant.session == session && target.starts_with(&grant.folder)
    })
}

/// Always: shares the folder the card named (`shown`) with the chat
/// read-only and answers at the copy of `target`. A grant of the chat that
/// already covers `target` is kept as it is (never turned read-only, never
/// nested), and the card named its folder: the file goes into a read-only
/// copy, or once (to `once`) beside a read-write one. The grants lock is
/// held until that copy is done, so a revoke that returned is never
/// followed by it.
#[allow(clippy::too_many_arguments)]
fn always(
    socket: &Path,
    machine: &str,
    session: &str,
    root: &str,
    target: &Path,
    is_dir: bool,
    shown: Option<&str>,
    once: &str,
) -> Result<String, Failure> {
    let store = Store::open()?;
    let kept = covering(&store.grants, machine, session, target).cloned();
    let folder = match &kept {
        Some(grant) => PathBuf::from(&grant.folder),
        None => always_folder(target, is_dir)
            .ok_or_else(|| Failure::new("grant_refused", "its folder may not be shared"))?,
    };
    if shown.map(Path::new) != Some(folder.as_path()) {
        return Err(Failure::new(
            "request_changed",
            "the folder to share changed since the person was asked",
        ));
    }
    let remote = match kept {
        Some(grant) if grant.mode == Mode::Write => {
            if is_dir {
                return Err(Failure::new("grant_refused", "it is in a read-write folder already"));
            }
            sync_cli::copy_file(socket, target, once).map_err(machine_failure)?;
            return Ok(once.to_string());
        }
        Some(grant) => grant.remote,
        None => {
            // `grant` takes the lock itself.
            drop(store);
            let granted = grant(socket, machine, session, root, Mode::Read, &folder)?;
            let remote = granted["grant"]["remote"].as_str().unwrap_or_default().to_string();
            // Locked again, and only while the grant is still there.
            let store = Store::open()?;
            if covering(&store.grants, machine, session, target).is_none() {
                return Err(Failure::new("grant_not_found", "the folder was revoked meanwhile"));
            }
            return at_copy(socket, &remote, &folder, target);
        }
    };
    let at = at_copy(socket, &remote, &folder, target)?;
    drop(store);
    Ok(at)
}

/// Where `target` is in the copy `remote` of `folder`; a file the copy
/// leaves out (ignored by git, or new since the last sync) still goes: the
/// person shared it.
fn at_copy(socket: &Path, remote: &str, folder: &Path, target: &Path) -> Result<String, Failure> {
    let inside = target.strip_prefix(folder).unwrap_or(Path::new(""));
    if inside.as_os_str().is_empty() {
        return Ok(remote.to_string());
    }
    let at = format!("{remote}/{}", inside.to_string_lossy());
    if !cmux_blocking::fs::metadata(target).is_ok_and(|metadata| metadata.is_dir())
        && sync_cli::remote_kind(socket, &at).map_err(machine_failure)?.is_none()
    {
        sync_cli::copy_file(socket, target, &at).map_err(machine_failure)?;
    }
    Ok(at)
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
