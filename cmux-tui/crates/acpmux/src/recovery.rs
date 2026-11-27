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
use cmux_json::JsonSet as _;

/// Build the reply while the failed write still has its typed I/O cause.
pub(crate) fn write_error(
    operation: &str,
    cause: anyhow::Error,
    fallback_reason: Option<&str>,
) -> RpcError {
    let message = format!("{operation}: {cause:#}");
    if is_out_of_space(&cause) {
        return RpcError::new(crate::rpc::BUSY_CODE, message)
            .with_data(json!({"reason": "disk_full", "retryable": true}));
    }
    let error = RpcError::internal(message);
    match fallback_reason {
        Some(reason) => error.with_data(json!({"reason": reason, "retryable": true})),
        None => error,
    }
}

/// A full disk or quota anywhere in the error's chain.
pub(crate) fn is_out_of_space(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| cause.downcast_ref::<std::io::Error>().is_some_and(io_out_of_space))
}

fn io_out_of_space(error: &std::io::Error) -> bool {
    if matches!(error.kind(), std::io::ErrorKind::StorageFull | std::io::ErrorKind::QuotaExceeded) {
        return true;
    }
    #[cfg(unix)]
    if matches!(error.raw_os_error(), Some(code) if code == libc::ENOSPC || code == libc::EDQUOT) {
        return true;
    }
    false
}

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
    /// The two ends of a connection share no wire ABI revision (`protocol/range.rs`): `details`
    /// names both ranges and which side (`update`: `self` or `peer`) to update.
    pub const VERSION_INCOMPATIBLE: &str = "version.incompatible";
    /// The agent's program could not be started.
    pub const SPAWN_FAILED: &str = "spawn.failed";
    /// The agent's process ended in the middle of a turn.
    pub const AGENT_EXITED: &str = "agent.exited";
    /// The agent has no usable sign-in: "Not logged in", an invalid API key ([`super::auth_kind`]).
    pub const AUTH_SIGNED_OUT: &str = "auth.signed_out";
    /// The agent's sign-in expired: an expired OAuth token or credential ([`super::auth_kind`]).
    pub const AUTH_EXPIRED: &str = "auth.expired";
    /// A Cloud machine's model call found the owner's own gateway (their Mac) not connected:
    /// the Mac is asleep, offline or not running cmux (`inference.gateway_offline`, `_gone`).
    pub const GATEWAY_OFFLINE: &str = "gateway.offline";
    /// The owner's gateway answered, but the agent's sign-in on their Mac is missing or expired
    /// (`inference.gateway_login`).
    pub const GATEWAY_LOGIN: &str = "gateway.login";
    /// The agent does not know the model it was asked to run (Claude Code's
    /// `unrecognized_model`, an API's `model_not_found`; `model_catalog::is_model_error`). acpmux
    /// retries such a turn once under the model's catalog id when it has one
    /// (`hub/auto_resume/model_reroute.rs`); a sweeper reads this kind for the rest.
    pub const MODEL_UNRECOGNIZED: &str = "model.unrecognized";
    /// The agent's account used up a usage limit that resets later (Claude Code's "You've hit
    /// your weekly limit · resets ..."; `usage_limit.rs`): a retry fails the same way until then.
    pub const USAGE_LIMIT: &str = "usage.limit";
    /// The agent's provider disabled or suspended its account (`usage_limit.rs`).
    pub const ACCOUNT_DISABLED: &str = "account.disabled";
}

/// The `errorKind` of a model call the owner's own gateway could not answer, by the code the
/// Cloud service or the gateway put in the agent's error text.
pub fn gateway_kind(message: &str) -> Option<&'static str> {
    if message.contains("inference.gateway_offline") || message.contains("inference.gateway_gone") {
        Some(kind::GATEWAY_OFFLINE)
    } else if message.contains("inference.gateway_login") {
        Some(kind::GATEWAY_LOGIN)
    } else {
        None
    }
}

/// What an agent's error says about its sign-in: `auth.expired` when it says a credential
/// expired (`claude_auth::is_expired_credential`), `auth.signed_out` when it says there is no
/// usable sign-in (`claude_auth::is_sign_in_failure`), else None. An error that says the
/// provider had no capacity, a gateway failed or the connection dropped
/// (`turn_errors::says_unreachable`) is never a sign-in state, whatever words
/// about a sign-in it also carries ("HTTP 503: authentication_failed").
pub fn auth_kind(message: &str) -> Option<&'static str> {
    if crate::turn_errors::says_unreachable(message) {
        return None;
    }
    if crate::claude_auth::is_expired_credential(message) {
        Some(kind::AUTH_EXPIRED)
    } else if crate::claude_auth::is_sign_in_failure(message) || says_missing_openai_key(message) {
        Some(kind::AUTH_SIGNED_OUT)
    } else {
        None
    }
}

/// Whether a sign-in failure's `message` is about an API key a provider issued, not the agent's
/// own login: it names an API key ("This API key has expired", `api_key_expired`, "Invalid API
/// key · Fix external API key") and does not send the person to a login ("Invalid API key ·
/// Please run /login" is Claude Code's own sign-in). A new key fixes it; signing in does not.
pub fn says_api_key(message: &str) -> bool {
    let m = message.to_lowercase();
    let key = ["api key", "api_key", "apikey", "x-api-key"].iter().any(|k| m.contains(k));
    let login =
        ["/login", "auth login", "please log in", "run login"].iter().any(|k| m.contains(k));
    key && !login
}

/// Whether `message` is codex's "Missing environment variable: `OPENAI_API_KEY`.": its provider
/// has no key, so a Codex with no sign-in of its own (own mode with no login, or team mode with
/// no placeholder) is signed out ([`auth_kind`]), and the chat shows Codex's Sign in card.
pub fn says_missing_openai_key(message: &str) -> bool {
    message.to_lowercase().contains("missing environment variable: `openai_api_key`")
}

/// The refusal of a spawn once the shutdown has begun (`recovery.rs` types it).
pub const SHUTTING_DOWN: &str = "acpmux is shutting down; no agent starts now";

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
    object_data(e);
    let Some(Value::Object(data)) = &mut e.data else { return };
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
    let wrapped = object_data(e);
    let Some(Value::Object(data)) = &mut e.data else { return };
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
    } else if wrapped && data.len() == 1 {
        // Nothing typed it: the agent's own data goes back as it sent it.
        e.data = data.remove(AGENT_DATA);
    }
}

/// The key an agent's own error `data` moves under when it is not an object ([`object_data`]).
pub const AGENT_DATA: &str = "agentData";

/// Make `e.data` an object this module can type: none (or null) becomes empty, and an agent's
/// own data that is not an object (grok 1.0.77 answers `session/new` with "Authentication
/// required" and the string data "no auth method id provided") moves under [`AGENT_DATA`], so
/// typing never fails for the shape of what the agent sent. Returns whether it moved it.
pub(crate) fn object_data(e: &mut RpcError) -> bool {
    match e.data.take() {
        Some(Value::Object(data)) => {
            e.data = Some(Value::Object(data));
            false
        }
        None | Some(Value::Null) => {
            e.data = Some(Value::Object(Map::new()));
            false
        }
        Some(other) => {
            let mut data = Map::new();
            data.insert(AGENT_DATA.into(), other);
            e.data = Some(Value::Object(data));
            true
        }
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
            details.insert("lastSeenAt".into(), json!(crate::clock_text::iso(at)));
        }
        let recovery = format!(
            "Check that {peer} is on and online in `tailscale status`; `acpmux machine doctor \
             {peer}` checks the link step by step. acpmux reconnects by itself, and this request \
             was not sent, so send it again once `acpmux machine ls` shows {peer} connected."
        );
        return Some((kind::PEER_UNREACHABLE, recovery, details));
    }
    // Before the sign-in kinds: the fix is on the owner's Mac, not a login on this machine.
    if let Some(kind) = gateway_kind(message) {
        let recovery = if kind == kind::GATEWAY_OFFLINE {
            "Your Mac answers this chat's model calls, and it isn't reachable right now: it may be \
             asleep, offline, or not running cmux. Wake your Mac and open cmux on it, then send \
             the message again."
        } else {
            "The agent's sign-in on your Mac is missing or expired. Open the agent on your Mac once \
             so it signs in or renews its sign-in, then send the message again."
        };
        return Some((kind, recovery.into(), Map::new()));
    }
    // Before the sign-in kinds: an account out of usage, or one its provider turned off, is not
    // signed out (another account or agent goes on; cmux#55066).
    if let Some(limit) = crate::usage_limit::account_limit(message) {
        return Some((limit.error_kind(), limit.sentence(None), limit.details()));
    }
    // Before `agent.exited`: an agent that died saying it is not signed in needs a sign-in, and
    // sending again would fail the same way.
    if let Some(kind) = auth_kind(message) {
        let recovery = if says_api_key(message) {
            "The provider refused the agent's API key (expired or no longer valid), and signing in \
             again does not renew it. Create a new key with that provider and enter it where the \
             agent reads it (`cmux harness login <harness>`, or the harness's own login in a \
             terminal on this machine), then send the message again."
        } else if kind == kind::AUTH_EXPIRED {
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
    if crate::model_catalog::is_model_error(message) {
        return Some((
            kind::MODEL_UNRECOGNIZED,
            "The agent does not know this chat's model. Pick one it lists in the chat's model \
             picker, or set it with `acpmux session set <session> model=<id>`, then send the \
             message again."
                .into(),
            Map::new(),
        ));
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
    if message == SHUTTING_DOWN {
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
/// `acpmux session stop NAME --purge --now` removes a chat you no longer need.` The chats' size is
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
            " acpmux's chats in {} use {}; `acpmux session stop <session> --purge --now` removes \
             a chat you no longer need.",
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
        v.set("errorKind", json!(kind::DISK_LOW));
        v.set(
            "recovery",
            json!(format!(
                "The disk is nearly full; agents fail once it is. {}",
                free_space_sentence(&space, true)
            )),
        );
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

/// The `data.reason` of a start whose agent answered `session/new` that it is not signed in.
/// cmux-tui passes it on as `agent_session.sign_in_required`, so a client names the agent and
/// offers its sign-in instead of a bare refusal (hq#11225). Never rename it.
pub const SIGN_IN_REQUIRED: &str = "agent.sign_in_required";

/// ACP's `auth_required` error code: an agent answers `session/new` with it when it has no
/// usable sign-in (cursor-agent's "Authentication required").
pub const ACP_AUTH_REQUIRED: i64 = -32000;

/// Type `e`, the agent's own answer to `session/new` for `harness`, as a missing or expired
/// sign-in when it is one: ACP's `auth_required`, a sign-in failure [`auth_kind`] knows, or an
/// agent's own "API key missing" or "Authentication required". It gains `reason`
/// [`SIGN_IN_REQUIRED`], `errorKind`, a `recovery` naming the harness's login, and
/// `details.harness`. Only the agent's own answer is typed here: acpmux's own -32000 refusals
/// never reach this. Returns whether it was typed.
pub fn start_sign_in(e: &mut RpcError, harness: &str) -> bool {
    let lower = e.message.to_ascii_lowercase();
    let kind = match auth_kind(&e.message) {
        Some(kind) => kind,
        None if crate::turn_errors::says_unreachable(&e.message) => return false,
        // -32000 is also JSON-RPC's generic server error, so the code alone is never a sign-in:
        // only with the agent's own words for one (an adapter's quota error stays as it is).
        None if lower.contains("authentication required")
            || lower.contains("api key missing")
            || lower.contains("api key is missing")
            || (e.code == ACP_AUTH_REQUIRED && lower.contains("not authenticated")) =>
        {
            kind::AUTH_SIGNED_OUT
        }
        None => return false,
    };
    object_data(e);
    let Some(Value::Object(data)) = &mut e.data else { return false };
    data.insert("reason".into(), json!(SIGN_IN_REQUIRED));
    data.insert("errorKind".into(), json!(kind));
    data.insert(
        "recovery".into(),
        json!(format!(
            "{harness} is not signed in on this machine. Sign in with `cmux harness login \
             {harness}` (or the harness's own login in a terminal on this machine), then start \
             the chat again."
        )),
    );
    data.insert("details".into(), json!({"harness": harness}));
    true
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
#[path = "recovery_tests.rs"]
mod tests;
