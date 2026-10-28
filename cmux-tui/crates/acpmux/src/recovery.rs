//! What kind of failure an error is and how to recover from it (Leo 2026-10-22: "good
//! recoverable/informative disk errors tailscale erros for acpmux").
//!
//! An error a client sees gains three keys, additively, wherever it travels: the JSON-RPC
//! error's `data` (every request reply, `server/mod.rs`) and the `turn_error` and `turn_result`
//! records of a failed turn (`hub/turns.rs`), hence `lastTurn` too:
//!
//! - `errorKind`: one of the [`kind`] names. A client treats a kind it does not know as a
//!   plain error.
//! - `recovery`: one sentence saying what to do, e.g. "Free space on the disk that holds
//!   /home/leo/.acpmux: 0.9 GB free of 252 GB. ...".
//! - `details`: only the keys that apply: `path`, `freeBytes`, `totalBytes`, `peer`,
//!   `lastSeenAt` (RFC 3339), `binary`, `cwd`, `exitCode`, `signal`, `queued`, `retryAfterMs`.
//!
//! The error's own message stays a whole sentence, so a client that reads only the message
//! still reads well. An error that already has a kind (one a peer typed, or a site that knew
//! more) keeps it. Nothing here deletes anything: a disk error names what acpmux keeps and the
//! command that removes it.

use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

use crate::rpc::RpcError;

/// The `errorKind` names. Clients match on these; never rename one.
pub mod kind {
    /// A write failed because the disk (or the user's quota) is full.
    pub const DISK_FULL: &str = "disk.full";
    /// The disk acpmux writes to is nearly full (`daemon status`).
    pub const DISK_LOW: &str = "disk.low";
    /// The peer machine did not answer; the request was not sent.
    pub const PEER_UNREACHABLE: &str = "peer.unreachable";
    /// The daemon is restarting or shutting down.
    pub const DAEMON_RESTARTING: &str = "daemon.restarting";
    /// The agent's program could not be started.
    pub const SPAWN_FAILED: &str = "spawn.failed";
    /// The agent's process ended in the middle of a turn.
    pub const AGENT_EXITED: &str = "agent.exited";
    /// The agent has no usable sign-in: "Not logged in", an invalid API key ([`super::auth_kind`]).
    pub const AUTH_SIGNED_OUT: &str = "auth.signed_out";
    /// The agent's sign-in expired: an expired OAuth token or credential ([`super::auth_kind`]).
    pub const AUTH_EXPIRED: &str = "auth.expired";
}

/// What an agent's error says about its sign-in: `auth.expired` when it says a credential
/// expired (`claude_auth::is_expired_credential`), `auth.signed_out` when it says there is no
/// usable sign-in (`claude_auth::is_sign_in_failure`), else None. An error that says the
/// provider had no capacity, a gateway failed or the connection dropped
/// (`turn_errors::says_unreachable`) is never a sign-in state, whatever words
/// about a sign-in it also carries ("HTTP 503: authentication_failed").
pub fn auth_kind(message: &str) -> Option<&'static str> {
    if crate::hub::turn_errors::says_unreachable(message) {
        return None;
    }
    if crate::claude_auth::is_expired_credential(message) {
        Some(kind::AUTH_EXPIRED)
    } else if crate::claude_auth::is_sign_in_failure(message) {
        Some(kind::AUTH_SIGNED_OUT)
    } else {
        None
    }
}

/// Free space under this is `disk.low` unless the config sets `diskLowBytes`.
pub const DISK_LOW_DEFAULT_BYTES: u64 = 1 << 30;

/// Give `e` its kind, recovery and details when its cause is one this module knows. `near` is
/// the folder the failing work wrote to (a session's folder), checked beside acpmux's home.
/// Only an error that says the agent's process closed is `agent.exited` here: a short internal
/// error is a dead agent only at the end of a turn (`annotate_as`, `hub/turns.rs`).
pub fn annotate(e: &mut RpcError, near: Option<&Path>) {
    annotate_as(e, near, false);
}

/// Type an error a peer answered with before this daemon's [`annotate`] sees it: a full disk
/// there names that peer, never this machine's disk. A peer that typed it already keeps its kind.
pub fn annotate_peer(e: &mut RpcError, peer: &str) {
    if !is_disk_full(&e.message) {
        return;
    }
    let data = match &mut e.data {
        Some(Value::Object(data)) => data,
        Some(_) => return,
        None => {
            e.data = Some(Value::Object(Map::new()));
            let Some(Value::Object(data)) = &mut e.data else { return };
            data
        }
    };
    if data.contains_key("errorKind") {
        return;
    }
    data.insert("errorKind".into(), json!(kind::DISK_FULL));
    data.insert(
        "recovery".into(),
        json!(format!(
            "The disk on {peer} is full. Free some space there (`acpmux daemon status` on {peer} \
             shows it), then send again."
        )),
    );
    data.insert("details".into(), json!({"peer": peer}));
}

/// At the end of a turn, an error that says only that the agent's process went away: ACP's bare
/// "agent process closed", a bare "Internal error", or another short -32603. The turn finalizer
/// (`hub/turns.rs`) adds the agent's last stderr line to these, and they are `agent.exited`.
pub fn dead_process(e: &RpcError) -> bool {
    e.message == "agent process closed"
        || e.message == "Internal error"
        || (e.code == -32603 && e.message.len() < 40)
}

/// [`annotate`], for an error the caller already found [`dead_process`] before it rewrote the
/// message (the turn finalizer adds the agent's last stderr line). A stronger cause in the new
/// message (a full disk) still wins.
pub fn annotate_as(e: &mut RpcError, near: Option<&Path>, dead: bool) {
    let dead = dead || e.message.starts_with("agent process closed");
    let data = match &mut e.data {
        Some(Value::Object(data)) => data,
        Some(_) => return,
        None => {
            e.data = Some(Value::Object(Map::new()));
            let Some(Value::Object(data)) = &mut e.data else { return };
            data
        }
    };
    if data.contains_key("errorKind") {
        return;
    }
    if let Some((kind, recovery, details)) = classify(&e.message, data, near, dead) {
        data.insert("errorKind".into(), json!(kind));
        data.insert("recovery".into(), json!(recovery));
        data.insert("details".into(), Value::Object(details));
    }
    if data.is_empty() {
        e.data = None;
    }
}

/// The typed keys of an annotated error, for a turn record (`turn_error`, `turn_result`).
pub fn fields(e: &RpcError) -> Map<String, Value> {
    let mut out = Map::new();
    if let Some(data) = e.data.as_ref().and_then(Value::as_object) {
        for key in ["errorKind", "recovery", "details"] {
            if let Some(v) = data.get(key) {
                out.insert(key.into(), v.clone());
            }
        }
    }
    out
}

fn classify(
    message: &str,
    data: &Map<String, Value>,
    near: Option<&Path>,
    dead: bool,
) -> Option<(&'static str, String, Map<String, Value>)> {
    if is_disk_full(message) {
        let (recovery, details) = disk_full(near);
        return Some((kind::DISK_FULL, recovery, details));
    }
    if data.get("reason").and_then(Value::as_str) == Some("peer_unreachable") {
        let peer = data.get("peer").and_then(Value::as_str).unwrap_or("the peer");
        let mut details = Map::new();
        details.insert("peer".into(), json!(peer));
        if let Some(at) = data.get("lastSeen").and_then(Value::as_u64) {
            details.insert("lastSeenAt".into(), json!(crate::server::iso(at)));
        }
        let recovery = format!(
            "Check that {peer} is on and online in `tailscale status`; `acpmux host doctor \
             {peer}` checks the link step by step. acpmux reconnects by itself, and this request \
             was not sent, so send it again once `acpmux host ls` shows {peer} connected."
        );
        return Some((kind::PEER_UNREACHABLE, recovery, details));
    }
    // Before `agent.exited`: an agent that died saying it is not signed in needs a sign-in, and
    // sending again would fail the same way.
    if let Some(kind) = auth_kind(message) {
        let recovery = if kind == kind::AUTH_EXPIRED {
            "The agent's sign-in expired. Sign in again with its login command (`cmux harness \
             login <harness>`, or the harness's own login in a terminal on this machine), then \
             send the message again."
        } else {
            "The agent is not signed in. Sign in with its login command (`cmux harness login \
             <harness>`, or the harness's own login in a terminal on this machine), then send \
             the message again."
        };
        return Some((kind, recovery.into(), Map::new()));
    }
    if dead {
        return Some((
            kind::AGENT_EXITED,
            "The agent stopped in the middle of the turn. Send the message again to start it \
             again; `acpmux tail <session>` shows what it printed last."
                .into(),
            Map::new(),
        ));
    }
    if message.contains("spawn harness process") {
        return Some((
            kind::SPAWN_FAILED,
            "The agent's program could not start. Check that it is installed and on the \
             daemon's PATH; `acpmux harness doctor <harness>` checks it step by step."
                .into(),
            Map::new(),
        ));
    }
    if message == crate::hub::SHUTTING_DOWN {
        return Some((
            kind::DAEMON_RESTARTING,
            "The daemon is restarting. Run the command again in a few seconds; a send with the \
             same --prompt-id never runs twice."
                .into(),
            Map::new(),
        ));
    }
    None
}

/// ENOSPC or EDQUOT in an error's text, as Rust's io::Error prints them on Linux and macOS
/// (Linux EDQUOT is 122, macOS 69), or as an agent quotes them.
fn is_disk_full(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    lower.contains("no space left on device")
        || lower.contains("os error 28)")
        || lower.contains("disk quota exceeded")
        || lower.contains("disc quota exceeded")
        || lower.contains("enospc")
}

/// One disk's space, as `statvfs` reports it for the nearest folder that exists.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Space {
    pub path: PathBuf,
    pub free: u64,
    pub total: u64,
}

/// The space of the disk holding `path` (or its nearest existing parent).
pub fn space(path: &Path) -> Option<Space> {
    let mut at = path;
    loop {
        if at.exists() {
            let (free, total) = statvfs(at)?;
            return Some(Space { path: path.to_owned(), free, total });
        }
        at = at.parent()?;
    }
}

#[cfg(unix)]
fn statvfs(path: &Path) -> Option<(u64, u64)> {
    use std::os::unix::ffi::OsStrExt as _;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `c` is a valid NUL-terminated path and `st` a writable statvfs.
    if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
        return None;
    }
    let block = st.f_frsize as u64;
    Some((st.f_bavail as u64 * block, st.f_blocks as u64 * block))
}

#[cfg(not(unix))]
fn statvfs(_path: &Path) -> Option<(u64, u64)> {
    None
}

/// The fuller of acpmux's home and `near`: the disk a failed write most likely hit.
fn tightest(near: Option<&Path>) -> Option<Space> {
    let home = space(&crate::config::home());
    let near = near.and_then(space);
    match (home, near) {
        (Some(h), Some(n)) => Some(if n.free < h.free { n } else { h }),
        (h, n) => h.or(n),
    }
}

fn disk_full(near: Option<&Path>) -> (String, Map<String, Value>) {
    let mut details = Map::new();
    let Some(space) = tightest(near) else {
        return ("The disk is full. Free some space, then send again.".into(), details);
    };
    details.insert("path".into(), json!(space.path));
    details.insert("freeBytes".into(), json!(space.free));
    details.insert("totalBytes".into(), json!(space.total));
    (format!("The disk is full. {}", free_space_sentence(&space, false)), details)
}

/// `Free space on the disk that holds P: 0.9 GB free of 252 GB. acpmux's chats in H use 3.0 GB;
/// `acpmux session stop NAME --purge` removes a chat you no longer need.` The chats' size is
/// measured only when `measure` (a blocking walk: `daemon status`, off the async workers);
/// otherwise a size measured in the last minute is used, or none.
pub fn free_space_sentence(space: &Space, measure: bool) -> String {
    let mut text = format!(
        "Free space on the disk that holds {}: {} free of {}.",
        space.path.display(),
        gb(space.free),
        gb(space.total)
    );
    let home = crate::config::home();
    let chats = home.join("sessions");
    if same_disk(&home, &space.path)
        && let Some(size) = chats_size(&chats, measure)
        && size >= 100 << 20
    {
        text.push_str(&format!(
            " acpmux's chats in {} use {}; `acpmux session stop <session> --purge` removes a \
             chat you no longer need.",
            chats.display(),
            gb(size)
        ));
    }
    text
}

/// The `disk` entry of `daemon status`: the space of acpmux's home, and when it is under
/// `low_bytes` the `disk.low` kind with its recovery. Blocking (statvfs, and the chats folder's
/// size when low): call it off the async workers.
pub fn disk_status(low_bytes: u64) -> Value {
    let Some(space) = space(&crate::config::home()) else { return Value::Null };
    let mut v = json!({"path": space.path, "freeBytes": space.free, "totalBytes": space.total, "low": space.free < low_bytes});
    if space.free < low_bytes {
        v["errorKind"] = json!(kind::DISK_LOW);
        v["recovery"] = json!(format!(
            "The disk is nearly full; agents fail once it is. {}",
            free_space_sentence(&space, true)
        ));
    }
    v
}

/// `0.9 GB`, `252 GB`.
pub fn gb(bytes: u64) -> String {
    let g = bytes as f64 / 1e9;
    if g < 10.0 { format!("{g:.1} GB") } else { format!("{g:.0} GB") }
}

#[cfg(unix)]
fn same_disk(a: &Path, b: &Path) -> bool {
    use std::os::unix::fs::MetadataExt as _;
    let dev = |p: &Path| p.ancestors().find_map(|p| std::fs::metadata(p).ok()).map(|m| m.dev());
    matches!((dev(a), dev(b)), (Some(x), Some(y)) if x == y)
}

#[cfg(not(unix))]
fn same_disk(a: &Path, b: &Path) -> bool {
    a.components().next() == b.components().next()
}

/// How long a measured size of the chats folder is reused: a low disk polled by `daemon
/// status`, or a burst of disk-full errors, walks the folder once a minute at most.
const CHATS_SIZE_TTL: std::time::Duration = std::time::Duration::from_secs(60);

type SizeCache = std::sync::Mutex<Option<(std::time::Instant, PathBuf, Option<u64>)>>;

/// [`dir_size`] of `dir`, reused for [`CHATS_SIZE_TTL`]; with `measure` false only a reused
/// size (an error path in a request task never walks the folder). Blocking when `measure`.
fn chats_size(dir: &Path, measure: bool) -> Option<u64> {
    static CACHE: SizeCache = std::sync::Mutex::new(None);
    if let Some((at, path, size)) = CACHE.lock().unwrap_or_else(|e| e.into_inner()).as_ref()
        && path == dir
        && at.elapsed() < CHATS_SIZE_TTL
    {
        return *size;
    }
    if !measure {
        return None;
    }
    let size = dir_size(dir);
    *CACHE.lock().unwrap_or_else(|e| e.into_inner()) =
        Some((std::time::Instant::now(), dir.to_owned(), size));
    size
}

/// The bytes under `dir`, from at most 200,000 entries (an error path, so bounded). Blocking.
fn dir_size(dir: &Path) -> Option<u64> {
    let mut total = 0u64;
    let mut seen = 0usize;
    let mut stack = vec![dir.to_owned()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else {
            if d == dir {
                return None;
            }
            continue;
        };
        for entry in entries.flatten() {
            seen += 1;
            if seen > 200_000 {
                return Some(total);
            }
            let Ok(meta) = entry.metadata() else { continue };
            if meta.is_dir() {
                stack.push(entry.path());
            } else {
                total += meta.len();
            }
        }
    }
    Some(total)
}

/// A harness whose process could not start: `spawn.failed` naming the program and folder,
/// when the cause is the OS refusing the start (a missing program or folder, a permission). Any
/// other start error (a terminal harness, an empty command) stays as it was.
pub fn spawn_failed(e: &anyhow::Error, harness: &str, program: &str, cwd: &Path) -> RpcError {
    let Some(io) = e.chain().find_map(|c| c.downcast_ref::<std::io::Error>()) else {
        return RpcError::internal(format!("{e:#}"));
    };
    let message =
        format!("could not start the {harness} agent ({program} in {}): {io}", cwd.display());
    // A full disk (or quota) is not the program's fault: say to free space, as any local write.
    if matches!(io.kind(), std::io::ErrorKind::StorageFull | std::io::ErrorKind::QuotaExceeded)
        || is_disk_full(&io.to_string())
    {
        let (recovery, details) = disk_full(Some(cwd));
        return RpcError::internal(message).with_data(json!({
            "errorKind": kind::DISK_FULL,
            "recovery": recovery,
            "details": details,
        }));
    }
    let recovery = if !cwd.is_dir() {
        format!(
            "The folder {} is gone; restore it, or start the chat in another folder.",
            cwd.display()
        )
    } else if io.kind() == std::io::ErrorKind::NotFound {
        format!(
            "{program} is not installed or not on the daemon's PATH. Install it, or fix the \
             {harness} harness's command; `acpmux harness doctor {harness}` checks it step by \
             step. Then send again."
        )
    } else {
        format!(
            "Check that {program} can run for this user ({io}); `acpmux harness doctor \
             {harness}` checks it step by step. Then send again."
        )
    };
    RpcError::internal(message).with_data(json!({
        "errorKind": kind::SPAWN_FAILED,
        "recovery": recovery,
        "details": {"binary": program, "cwd": cwd},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An error path never walks the chats folder (a request task must not block on it);
    /// a size `daemon status` measured is reused.
    #[test]
    fn only_a_measure_walks_the_chats_folder() {
        let dir = std::env::temp_dir().join(format!("acpmux-chats-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("a"), vec![0u8; 4096]).unwrap();
        assert_eq!(chats_size(&dir, false), None, "an error path must not walk");
        let measured = chats_size(&dir, true);
        assert!(measured.is_some_and(|n| n >= 4096));
        assert_eq!(chats_size(&dir, false), measured, "then it reuses the measure");
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn kind_of(e: &RpcError) -> Option<&str> {
        e.data.as_ref()?.get("errorKind")?.as_str()
    }

    /// Every form the turn finalizer treats as a dead process is `agent.exited`: the bare ACP
    /// closes, "Internal error" and a short -32603. A long -32603 is the agent's own answer.
    #[test]
    fn the_finalizers_dead_process_forms_are_agent_exited() {
        for e in [
            RpcError::internal("agent process closed"),
            RpcError::new(-32603, "Internal error"),
            RpcError::new(-32000, "Internal error"),
            RpcError::new(-32603, "simulated internal error"),
        ] {
            let mut typed = e.clone();
            annotate_as(&mut typed, None, dead_process(&e));
            assert_eq!(kind_of(&typed), Some(kind::AGENT_EXITED), "{e:?}");
        }
        let answer = RpcError::new(
            -32603,
            "stream disconnected before completion: error sending request for url",
        );
        let mut typed = answer.clone();
        annotate_as(&mut typed, None, dead_process(&answer));
        assert_eq!(kind_of(&typed), None);
    }

    /// A request's reply is not a turn: a short internal error there is the daemon's own
    /// failure, not a dead agent, and keeps no kind.
    #[test]
    fn a_short_request_error_is_not_agent_exited() {
        for e in [
            RpcError::internal("no agent session"),
            RpcError::internal("session/new returned no sessionId"),
            RpcError::new(-32603, "Internal error"),
        ] {
            let mut typed = e.clone();
            annotate(&mut typed, None);
            assert_eq!(kind_of(&typed), None, "{e:?}");
        }
        let mut closed = RpcError::internal("agent process closed");
        annotate(&mut closed, None);
        assert_eq!(kind_of(&closed), Some(kind::AGENT_EXITED));
    }

    /// An agent that cannot start because the disk is full says to free space, with the
    /// disk's details; any other start failure is still `spawn.failed`.
    #[test]
    fn a_full_disk_at_spawn_is_disk_full() {
        let cwd = std::env::temp_dir();
        let errors = [std::io::ErrorKind::StorageFull, std::io::ErrorKind::QuotaExceeded]
            .map(std::io::Error::from);
        #[cfg(unix)]
        let errors = errors
            .into_iter()
            .chain([libc::ENOSPC, libc::EDQUOT].map(std::io::Error::from_raw_os_error));
        for error in errors {
            let e = anyhow::Error::from(error);
            let typed = spawn_failed(&e, "claude", "claude", &cwd);
            assert_eq!(kind_of(&typed), Some(kind::DISK_FULL), "{typed:?}");
            let data = typed.data.as_ref().unwrap();
            assert!(data["recovery"].as_str().unwrap().starts_with("The disk is full."), "{data}");
            assert!(data["details"]["freeBytes"].is_u64(), "{data}");
        }
        let e = anyhow::Error::from(std::io::Error::from_raw_os_error(libc::ENOENT));
        let typed = spawn_failed(&e, "claude", "claude", &cwd);
        assert_eq!(kind_of(&typed), Some(kind::SPAWN_FAILED), "{typed:?}");
    }

    /// A full disk a peer reported names that peer, never this machine's disk.
    #[test]
    fn a_peers_full_disk_names_the_peer_not_this_disk() {
        let mut e = RpcError::internal("write chat log: No space left on device (os error 28)");
        annotate_peer(&mut e, "big-blue");
        annotate(&mut e, None);
        assert_eq!(kind_of(&e), Some(kind::DISK_FULL));
        let data = e.data.as_ref().unwrap();
        assert_eq!(data["details"], json!({"peer": "big-blue"}), "{data}");
        assert!(data["recovery"].as_str().unwrap().contains("big-blue"), "{data}");
        let mut other = RpcError::internal("no agent session");
        annotate_peer(&mut other, "big-blue");
        assert!(other.data.is_none(), "{other:?}");
    }

    /// The finalizer adds the agent's last stderr line before typing: a dead process stays
    /// `agent.exited` under its longer message, and a full disk in that line wins.
    #[test]
    fn a_dead_process_with_its_stderr_line_is_still_typed() {
        let mut e = RpcError::new(-32603, "Internal error (claude): model client crashed");
        annotate_as(&mut e, None, true);
        assert_eq!(kind_of(&e), Some(kind::AGENT_EXITED));
        let mut e =
            RpcError::new(-32603, "Internal error (claude): write: No space left on device");
        annotate_as(&mut e, None, true);
        assert_eq!(kind_of(&e), Some(kind::DISK_FULL));
    }

    /// A turn whose agent says it is not signed in is `auth.signed_out`, one whose credential
    /// expired `auth.expired`, before `agent.exited` when the agent died of it. A connection
    /// or capacity error is never an auth kind, whatever word about a token it carries.
    #[test]
    fn a_sign_in_failure_is_typed_and_a_transport_error_is_not() {
        for (message, dead, want) in [
            ("Not logged in · Please run /login", false, Some(kind::AUTH_SIGNED_OUT)),
            ("Invalid API key · Fix external API key", false, Some(kind::AUTH_SIGNED_OUT)),
            (
                "agent process closed (claude): Not logged in · Please run /login",
                true,
                Some(kind::AUTH_SIGNED_OUT),
            ),
            (
                "API Error: 401 OAuth token has expired. Please obtain a new token.",
                false,
                Some(kind::AUTH_EXPIRED),
            ),
            (
                "Provided authentication token is expired. Please try signing in again.",
                false,
                Some(kind::AUTH_EXPIRED),
            ),
            ("API Error: Connection error.", false, None),
            ("HTTP 503: authentication_failed", false, None),
            ("HTTP 502: authentication_failed", false, None),
            ("HTTP 504: credential expired", false, None),
            ("Not logged in · Please run /login (connection error)", false, None),
            ("HTTP 400: invalid token expiry value", false, None),
            ("stream disconnected before completion: the token stream expired", false, None),
            (
                "API Error: 503 no non-exhausted claude accounts; the login pool expires soon",
                false,
                None,
            ),
            ("agent process closed", true, Some(kind::AGENT_EXITED)),
        ] {
            let mut e = RpcError::new(-32000, message);
            annotate_as(&mut e, None, dead);
            assert_eq!(kind_of(&e), want, "{message}");
            if want.is_some_and(|k| k.starts_with("auth.")) {
                let recovery = e.data.as_ref().unwrap()["recovery"].as_str().unwrap().to_owned();
                assert!(recovery.contains("cmux harness login"), "{recovery}");
            }
        }
    }
}
