//! `chief-inspect` (`chief-inspect-v1`): the Chief memory inspector's
//! read-only API for a remote owner (plans/cmux-next/optchat-inspector.md,
//! "Remote brains"). The app reaches the brain's daemon through the link's
//! owner_session splice (an unstamped Unix client) and asks here; this
//! daemon forwards one line to the brain host's tools socket
//! (`CMUX_TUI_CHIEF_TOOLS_SOCKET`, the `inspect` tool of optchat-chief) and
//! answers its `{status, body | error}`. No new listener anywhere.
//!
//! Owner only: the memory holds private conversations. A link-stamped or
//! relayed (`Remote`), WebSocket, unregistered or agent-bound connection is
//! refused (`origin.forbidden`) before anything is forwarded; the remote
//! relay gate never admits the command. Read-only: the seven API paths,
//! GET only (the tool's default), an answer cap.
//!
//! Every daemon advertises `chief-inspect-v1` (it speaks the command); one
//! started without a tools socket answers the owner `chief.not_configured`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use serde::Deserialize;
use serde_json::Value;

use super::{ClientTransport, MessageWriter, Mux, Response, send_response};
use crate::conversation_store::LOCAL_USER;
use crate::request_origin::ORIGIN_FORBIDDEN;

pub(super) const CAPABILITY: &str = "chief-inspect-v1";
/// The `error_code` for the owner when this daemon has no tools socket.
pub(super) const NOT_CONFIGURED: &str = "chief.not_configured";
/// The brain host's tools socket, set by whoever starts the brain's daemon
/// (the app for a local Chief, the server's brain install script).
pub(super) const TOOLS_SOCKET_ENV: &str = "CMUX_TUI_CHIEF_TOOLS_SOCKET";
/// The paths the brain answers (optchat-chief `inspect::INSPECT_PATHS`).
const PATHS: [&str; 7] = [
    "/api/status",
    "/api/turns",
    "/api/turn",
    "/api/node",
    "/api/level",
    "/api/date",
    "/api/search",
];
/// The brain refuses answers above 4 MiB; a reply line above this is refused.
#[cfg_attr(not(unix), allow(dead_code))]
pub(super) const MAX_REPLY_BYTES: usize = 5 * 1024 * 1024;
#[cfg(unix)]
const TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
/// The tools socket taken from the environment at startup (`take_from_env`).
static TAKEN: OnceLock<Option<PathBuf>> = OnceLock::new();

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Params {
    pub path: String,
    #[serde(default)]
    pub query: BTreeMap<String, String>,
}

#[derive(Debug)]
struct NotOwner;

impl std::fmt::Display for NotOwner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("chief-inspect is for the owner's trusted connection only")
    }
}

impl std::error::Error for NotOwner {}

#[derive(Debug)]
struct NotConfigured;

impl std::fmt::Display for NotConfigured {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("no Chief tools socket on this daemon")
    }
}

impl std::error::Error for NotConfigured {}

/// The `error_code` of a refused `chief-inspect`.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    if error.downcast_ref::<NotOwner>().is_some() {
        return Some(ORIGIN_FORBIDDEN.to_string());
    }
    error.downcast_ref::<NotConfigured>().map(|_| NOT_CONFIGURED.to_string())
}

/// Reads `CMUX_TUI_CHIEF_TOOLS_SOCKET` and removes it from this process's
/// environment, so no terminal, shell or agent the daemon spawns learns the
/// brain's tools path. Later reads use the taken value.
///
/// # Safety
///
/// Call it before this process starts any thread (first thing in `main`):
/// removing an environment variable is unsound while another thread can read
/// the environment.
pub unsafe fn take_tools_socket_from_env() {
    let value = std::env::var_os(TOOLS_SOCKET_ENV).filter(|v| !v.is_empty()).map(PathBuf::from);
    // SAFETY: forwarded from this function's contract (no other thread yet).
    unsafe { std::env::remove_var(TOOLS_SOCKET_ENV) };
    let _ = TAKEN.set(value);
}

/// Whether this daemon can forward (the brain's tools socket is configured).
#[cfg(all(test, unix))]
pub(super) fn configured() -> bool {
    tools_socket().is_some()
}

/// The taken value; a library user that never took it reads the environment.
fn tools_socket() -> Option<PathBuf> {
    match TAKEN.get() {
        Some(taken) => taken.clone(),
        None => std::env::var_os(TOOLS_SOCKET_ENV).filter(|v| !v.is_empty()).map(PathBuf::from),
    }
}

/// The owner: a registered Unix client with no link peer record (local, or
/// the owner_session splice) acting as the local user (not agent-bound).
fn require_owner(mux: &Mux, client: u64) -> anyhow::Result<()> {
    let unix = matches!(mux.control_clients.transport_of(client), Some(ClientTransport::Unix));
    let owner =
        unix && !mux.is_remote_client(client) && mux.conversation_principal(client) == LOCAL_USER;
    if owner { Ok(()) } else { Err(NotOwner.into()) }
}

/// The socket, checked: a Unix socket (not a symlink) owned by this
/// daemon's user.
#[cfg(unix)]
fn checked(path: &Path) -> anyhow::Result<std::os::unix::net::UnixStream> {
    use std::os::unix::fs::{FileTypeExt, MetadataExt};
    let meta = std::fs::symlink_metadata(path)
        .map_err(|e| anyhow::anyhow!("the Chief tools socket is missing: {e}"))?;
    anyhow::ensure!(meta.file_type().is_socket(), "the Chief tools socket is not a socket");
    // SAFETY: geteuid has no preconditions.
    let uid = unsafe { libc::geteuid() };
    anyhow::ensure!(meta.uid() == uid, "the Chief tools socket belongs to another user");
    Ok(cmux_unix_socket::connect(path)?)
}

/// Checks the caller and the request, then asks the brain (blocking).
/// `socket` overrides the environment (tests).
pub(super) fn inspect_with(
    mux: &Mux,
    client: u64,
    params: Params,
    socket: Option<&Path>,
) -> anyhow::Result<Value> {
    require_owner(mux, client)?;
    anyhow::ensure!(
        PATHS.contains(&params.path.as_str()),
        "not an inspector path: {}",
        params.path
    );
    let path = match socket {
        Some(path) => path.to_owned(),
        None => tools_socket().ok_or(NotConfigured)?,
    };
    forward(&path, &params)
}

/// Sends one `inspect` line to the brain's tools socket and reads its answer.
#[cfg(unix)]
fn forward(path: &Path, params: &Params) -> anyhow::Result<Value> {
    use std::io::{BufRead, BufReader, Read, Write};
    let stream = checked(path)?;
    stream.set_read_timeout(Some(TIMEOUT))?;
    stream.set_write_timeout(Some(TIMEOUT))?;
    let request = serde_json::json!({"tool": "inspect", "method": "GET", "path": params.path, "query": params.query});
    (&stream).write_all(format!("{request}\n").as_bytes())?;
    let mut line = String::new();
    BufReader::new((&stream).take(MAX_REPLY_BYTES as u64 + 1)).read_line(&mut line)?;
    anyhow::ensure!(line.len() <= MAX_REPLY_BYTES, "the Chief's answer is too large");
    anyhow::ensure!(line.ends_with('\n'), "the Chief closed the tools socket mid-answer");
    let answer: Value = serde_json::from_str(&line)?;
    anyhow::ensure!(answer.get("status").is_some_and(Value::is_u64), "not an inspector answer");
    Ok(answer)
}

/// The brain's tools socket is a Unix socket: a daemon on another platform
/// speaks the command but is never configured for it.
#[cfg(not(unix))]
fn forward(_path: &Path, _params: &Params) -> anyhow::Result<Value> {
    Err(NotConfigured.into())
}

/// The asynchronous request path: the forward runs on its own thread (it
/// waits on another process) and answers through `writer`.
pub(super) fn start(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    params: Params,
    writer: &MessageWriter,
) -> bool {
    // Refuse at once, on this thread, before any thread or socket.
    if let Err(error) = require_owner(mux, client) {
        return respond(writer, id, Err(error));
    }
    let mux = mux.clone();
    let thread_writer = writer.clone();
    let reply_id = id.clone();
    let spawned = std::thread::Builder::new().name("mux-chief-inspect".into()).spawn(move || {
        respond(&thread_writer, reply_id, inspect_with(&mux, client, params, None));
    });
    spawned.is_ok()
        || respond(writer, id, Err(anyhow::anyhow!("cannot start the inspector request")))
}

fn respond(writer: &MessageWriter, id: Option<Value>, answer: anyhow::Result<Value>) -> bool {
    let response = match answer {
        Ok(data) => Response {
            id,
            ok: true,
            data: Some(data),
            error: None,
            error_code: None,
            error_delivery: None,
        },
        Err(error) => Response {
            id,
            ok: false,
            data: None,
            error_code: error_code(&error),
            error: Some(error.to_string()),
            error_delivery: None,
        },
    };
    send_response(writer, response)
}

#[cfg(all(test, unix))]
#[path = "chief_inspect_tests.rs"]
mod tests;
