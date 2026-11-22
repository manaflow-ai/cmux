//! `cmux app publish|versions|rollback|ls` (the `cmux-apps` crate) on this Cloud machine, through
//! the agent socket, so the machine's `vm-self` token never leaves this agent:
//!
//! - `{"apps.call": {"method", "path", "body", "idempotencyKey"}}`: one platform request as this
//!   machine's bound VM install. Only the apps routes (`/v1/cloud/apps` and paths under it) are
//!   sent; the agent adds the bearer and answers `{ok: true, status, body, machine}`, `machine`
//!   being the one the install speaks for (a version's only allowed target).
//! - `{"apps.listener": {"port": P}}`: the process listening on P (pid, cwd, argv), read by the
//!   agent, which can see every process; answered only when that process belongs to the asking
//!   user (the socket's peer credentials), so no user reads another's command line.

#[cfg(unix)]
use std::os::unix::fs::MetadataExt as _;
#[cfg(unix)]
use std::os::unix::net::UnixStream;
#[cfg(unix)]
use std::path::Path;

use serde_json::{Value, json};

use super::github::refusal;
use super::sender::Answer;

/// The socket line keys.
pub const CALL_KEY: &str = "apps.call";
pub const LISTENER_KEY: &str = "apps.listener";
/// The only routes `apps.call` sends.
pub const APPS_PATH: &str = "/v1/cloud/apps";
const METHODS: [&str; 4] = ["GET", "POST", "PUT", "DELETE"];
const MAX_PATH: usize = 256;
const MAX_BODY: usize = 64 * 1024;
const MAX_KEY: usize = 256;

/// One checked `apps.call`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppsCall {
    pub method: String,
    pub path: String,
    pub body: Option<Value>,
    pub idempotency_key: Option<String>,
}

/// Whether `path` is an apps route: `/v1/cloud/apps` or under `/v1/cloud/apps/`, plain segments
/// only (letters, digits, `-`, `_`), so no `..`, query, fragment or escape reaches another route.
pub fn allowed_path(path: &str) -> bool {
    let Some(rest) = path.strip_prefix(APPS_PATH) else { return false };
    if rest.is_empty() {
        return true;
    }
    let Some(rest) = rest.strip_prefix('/') else { return false };
    path.len() <= MAX_PATH
        && !rest.is_empty()
        && rest.split('/').all(|segment| {
            !segment.is_empty()
                && segment.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        })
}

/// The `apps.call` object of a socket line, checked.
pub fn check_call(value: &Value) -> Result<AppsCall, String> {
    let text = |key: &str| value.get(key).and_then(Value::as_str);
    let method = text("method").unwrap_or_default();
    if !METHODS.contains(&method) {
        return Err(format!("apps.call method must be one of {}", METHODS.join(", ")));
    }
    let path = text("path").unwrap_or_default();
    if !allowed_path(path) {
        return Err(format!("apps.call sends only {APPS_PATH} and the paths under it"));
    }
    let body = match value.get("body") {
        None | Some(Value::Null) => None,
        Some(body @ Value::Object(_)) => {
            if body.to_string().len() > MAX_BODY {
                return Err("apps.call body is over 64 KiB".to_owned());
            }
            Some(body.clone())
        }
        Some(_) => return Err("apps.call body must be a JSON object".to_owned()),
    };
    let idempotency_key = match value.get("idempotencyKey") {
        None | Some(Value::Null) => None,
        Some(Value::String(key))
            if !key.is_empty()
                && key.len() <= MAX_KEY
                && key.bytes().all(|b| b.is_ascii_graphic()) =>
        {
            Some(key.clone())
        }
        Some(_) => return Err("apps.call idempotencyKey must be printable ASCII".to_owned()),
    };
    Ok(AppsCall { method: method.to_owned(), path: path.to_owned(), body, idempotency_key })
}

/// The reply line for the platform's answer: its status and body, never the bearer.
pub fn reply_for(answer: &Answer, machine: &str) -> Value {
    match answer {
        Answer::Http { status, body } => {
            json!({ "ok": true, "status": status, "body": body, "machine": machine })
        }
        Answer::Transport => refusal(
            "integration.unreachable",
            "Check this machine's connection and retry the apps request.",
        ),
    }
}

/// The `apps.listener` object of a socket line: its port.
pub fn check_listener(value: &Value) -> Result<u16, String> {
    value
        .get("port")
        .and_then(Value::as_u64)
        .and_then(|port| u16::try_from(port).ok())
        .filter(|port| *port != 0)
        .ok_or_else(|| "apps.listener needs a port from 1 to 65535".to_owned())
}

/// The asking process's uid, from the socket's peer credentials.
#[cfg(all(unix, not(target_os = "linux")))]
pub fn peer_uid(stream: &UnixStream) -> Option<u32> {
    use std::os::fd::AsRawFd as _;
    let (mut uid, mut gid) = (0, 0);
    // SAFETY: getpeereid writes two ids for a connected Unix socket.
    let rc = unsafe { libc::getpeereid(stream.as_raw_fd(), &raw mut uid, &raw mut gid) };
    (rc == 0).then_some(uid)
}

/// The asking process's uid, from the socket's peer credentials.
#[cfg(target_os = "linux")]
pub fn peer_uid(stream: &UnixStream) -> Option<u32> {
    use std::os::fd::AsRawFd as _;
    let mut cred = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut len = size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: SO_PEERCRED fills a ucred of `len` bytes on a connected Unix socket.
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&raw mut cred).cast(),
            &raw mut len,
        )
    };
    (rc == 0).then_some(cred.uid)
}

/// The reply for `apps.listener`: the process on `port` under `proc_root`, when it is the
/// asking user's (`peer_uid`; root may read any), else a refusal naming `--cmd` and `--dir`.
#[cfg(unix)]
pub fn listener_reply(proc_root: &Path, port: Result<u16, String>, peer_uid: Option<u32>) -> Value {
    let port = match port {
        Ok(port) => port,
        Err(why) => return refusal("request.invalid", &why),
    };
    let found = match cmux_apps::infer::infer(&cmux_apps::system::RealFs, proc_root, port) {
        Ok(found) => found,
        Err(e) => return refusal("app.infer", &e.to_string()),
    };
    let owner = std::fs::metadata(proc_root.join(found.pid.to_string())).map(|m| m.uid()).ok();
    let mine = match (peer_uid, owner) {
        (Some(0), Some(_)) => true,
        (Some(peer), Some(owner)) => peer == owner,
        _ => false,
    };
    if !mine {
        let message =
            format!("port {port} is held by another user's process; pass --cmd CMD and --dir DIR");
        return refusal("app.infer", &message);
    }
    json!({
        "ok": true,
        "pid": found.pid,
        "dir": found.dir.display().to_string(),
        "argv": found.argv,
        "command": found.command,
    })
}
