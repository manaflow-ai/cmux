//! The LocalApp origin: the app's own agent pane on this machine, which the
//! session pool serves. Every WebSocket connection is remote-origin
//! (`Origin::Web`) unless ALL of these hold:
//!
//! 1. the listener is bound to a loopback address only, and the peer
//!    address is loopback;
//! 2. the connection's first frame is `initialize` carrying this launch's
//!    LocalApp token in `_meta.acpmux.localAppToken`, compared in constant
//!    time. The token is 32 random bytes made at every daemon start, kept
//!    only in `ACPMUX_HOME/run/localapp.token` (mode 0600, created with
//!    `O_EXCL`), never returned by any RPC, never sent to or stored by a
//!    peer, a relay or `acpmux host setup`;
//! 3. the WebSocket `Origin` header is exactly the bundled page's origin
//!    (`cmux-agent://pane`) or an explicit `--allow-dev-origin` value, one
//!    header, never a wildcard;
//! 4. an absent `Origin` header is never local: local clients that are not
//!    browsers use the unix socket. Peer daemons, ssh tunnels and relays
//!    send none, so they stay remote-origin even with the token.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};

/// Where the LocalApp token of `home` lives.
pub fn token_path(home: &Path) -> PathBuf {
    home.join("run").join("localapp.token")
}

/// The `_meta.acpmux` field the first frame carries the token in.
pub const TOKEN_FIELD: &str = "localAppToken";

/// This launch's LocalApp token and the page origins it may come from.
pub struct LocalAppAuth {
    token: String,
    page_origins: Vec<String>,
    path: PathBuf,
}

/// What one WebSocket connection presented.
pub struct Hello<'a> {
    /// The listener's bound address.
    pub listener: SocketAddr,
    pub peer: SocketAddr,
    /// Every `Origin` header value of the upgrade request.
    pub origins: &'a [String],
    /// The first text frame, if one arrived.
    pub first_frame: Option<&'a str>,
}

impl LocalAppAuth {
    /// Make this launch's token: remove any file a previous launch left
    /// (never following a link), then create it fresh with `O_EXCL` and mode
    /// 0600 in a private `run` directory. `page_origins` are the bundled
    /// page's origin and the explicit `--allow-dev-origin` values.
    pub fn create(home: &Path, page_origins: &[String]) -> anyhow::Result<Self> {
        let path = token_path(home);
        let token = create_secret(&path)?;
        let page_origins =
            page_origins.iter().filter_map(|o| cmux_local_auth::parse_origin(o)).collect();
        Ok(Self { token, page_origins, path })
    }

    /// Whether `hello` is the local app: every condition in the module docs.
    pub fn is_local_app(&self, hello: &Hello<'_>) -> bool {
        let loopback = hello.listener.ip().is_loopback() && hello.peer.ip().is_loopback();
        let origin = match hello.origins {
            [one] => cmux_local_auth::parse_origin(one)
                .is_some_and(|o| self.page_origins.iter().any(|p| p == &o)),
            _ => false,
        };
        loopback && origin && hello.first_frame.is_some_and(|f| self.frame_has_token(f))
    }

    fn frame_has_token(&self, frame: &str) -> bool {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(frame) else { return false };
        v.get("method").and_then(serde_json::Value::as_str) == Some(crate::rpc::method::INITIALIZE)
            && v.pointer(&format!("/params/_meta/acpmux/{TOKEN_FIELD}"))
                .and_then(serde_json::Value::as_str)
                .is_some_and(|t| cmux_local_auth::tokens_match(t, &self.token))
    }

    /// The file this launch's token is in (removed when the daemon stops).
    pub fn path(&self) -> &Path {
        &self.path
    }
}

/// Write a new 32-byte random token to `path` (in `home/run`, a private
/// directory): remove any file a previous launch left (never following a
/// link), then create it with `O_EXCL`, `O_NOFOLLOW` and mode 0600. Returns
/// the token as hex.
#[cfg(unix)]
pub(crate) fn create_secret(path: &Path) -> anyhow::Result<String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    if let Some(dir) = path.parent() {
        crate::agent_host::ensure_private_dir(dir)?;
    }
    match std::fs::remove_file(path) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(anyhow::anyhow!("remove stale {}: {e}", path.display())),
    }
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes)
        .map_err(|e| anyhow::anyhow!("the OS random generator for {}: {e}", path.display()))?;
    let token: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|e| anyhow::anyhow!("create {}: {e}", path.display()))?;
    f.write_all(token.as_bytes())?;
    f.sync_all()?;
    Ok(token)
}
/// Windows: as on Unix, with an owner-only access list for the private
/// folder and the file (created new, never through a link).
#[cfg(windows)]
pub(crate) fn create_secret(path: &Path) -> anyhow::Result<String> {
    use std::io::Write;
    if let Some(dir) = path.parent() {
        crate::agent_host::ensure_private_dir(dir)?;
    }
    match std::fs::remove_file(path) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(anyhow::anyhow!("remove stale {}: {e}", path.display())),
    }
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes)
        .map_err(|e| anyhow::anyhow!("the OS random generator for {}: {e}", path.display()))?;
    let token: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    let mut f = crate::owner_only::create_new(path)
        .map_err(|e| anyhow::anyhow!("create {}: {e}", path.display()))?;
    f.write_all(token.as_bytes())?;
    f.sync_all()?;
    Ok(token)
}

/// `frame` without the token field, so the token never reaches the
/// protocol handler, a log or a reply.
pub fn strip_token(frame: &str) -> String {
    let Ok(mut v) = serde_json::from_str::<serde_json::Value>(frame) else {
        return frame.to_owned();
    };
    let removed = v
        .pointer_mut("/params/_meta/acpmux")
        .and_then(serde_json::Value::as_object_mut)
        .and_then(|m| m.remove(TOKEN_FIELD))
        .is_some();
    if removed { v.to_string() } else { frame.to_owned() }
}

/// Request fields that would shape a preset's harness command. The local
/// app names a preset by id only (`session/new {preset}`); with a preset,
/// any of these is refused, like a Web client's preset that shapes one.
const SHAPING_FIELDS: &[&str] = &[
    "args",
    "systemPrompt",
    "system_prompt",
    "env",
    "argv",
    "command",
    "harness",
    "harnessCommand",
];

/// Whether a `session/new` names a preset.
pub(super) fn names_preset(params: &serde_json::Value, meta: Option<&serde_json::Value>) -> bool {
    meta.and_then(|m| m.get("preset"))
        .or_else(|| params.get("preset"))
        .is_some_and(|p| !p.is_null())
}

/// The cwd a LocalApp preset session runs in: the caller's path must be
/// absolute and resolve to an existing directory; the harness gets the
/// canonical path (symlinks resolved, no `..`), never the caller's string.
pub(super) async fn canonical_cwd(
    given: &std::path::Path,
) -> Result<std::path::PathBuf, crate::rpc::RpcError> {
    let refused = || {
        crate::rpc::RpcError::invalid_params(
            "the local app starts a preset by its id only; cwd is refused (not an existing directory)",
        )
    };
    if !given.is_absolute() {
        return Err(refused());
    }
    let canonical = tokio::fs::canonicalize(given).await.map_err(|_| refused())?;
    match tokio::fs::metadata(&canonical).await {
        Ok(m) if m.is_dir() => Ok(canonical),
        _ => Err(refused()),
    }
}

pub(super) fn preset_by_id_only(
    params: &serde_json::Value,
    meta: Option<&serde_json::Value>,
) -> Result<(), crate::rpc::RpcError> {
    let preset = meta
        .and_then(|m| m.get("preset"))
        .or_else(|| params.get("preset"))
        .is_some_and(|p| !p.is_null());
    if !preset {
        return Ok(());
    }
    for field in SHAPING_FIELDS {
        if params.get(*field).is_some() || meta.is_some_and(|m| m.get(*field).is_some()) {
            return Err(crate::rpc::RpcError::invalid_params(format!(
                "the local app starts a preset by its id only; {field} is refused"
            )));
        }
    }
    Ok(())
}
