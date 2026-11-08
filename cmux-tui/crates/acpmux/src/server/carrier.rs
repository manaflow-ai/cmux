//! Connections through the Cloud carrier (`docs/carrier-roles.md`).
//!
//! On a Cloud VM, the session host serves the carrier's acpmux service (CMXR
//! `Service::Acpmux`) by bridging each stream to this daemon's carrier socket,
//! [`socket_path`] (`ACPMUX_HOME/run/carrier.sock`, mode 0600 in a 0700
//! directory, served on a Cloud VM only: [`wanted`]). The
//! bridge opens a WebSocket over that socket and its upgrade request carries
//! exactly one [`HEADER`], `{vmk, sub, team, chats, name?}`, which the session host
//! MUST copy from the verified carrier grant the platform signed, never from
//! the client: `vmk` is `owner` (the VM is the person's own) or `team` (the
//! person is a teammate of the VM's team, given the chats `chats` names).
//!
//! - Only this socket reads the header. The daemon's unix socket speaks
//!   JSON-RPC lines, and an HTTP request on it ends the connection
//!   (`stream.rs`); the WebSocket listener refuses an upgrade that carries it
//!   (`mod.rs`). An upgrade on this socket without it, with two, or with one
//!   that does not parse is refused before any session or data.
//! - Who may connect: a process of this daemon's own user (the socket's mode,
//!   and the peer's uid checked at accept). Only the VM's session host is
//!   meant to; any other process of the user already reaches the daemon's own
//!   unix socket, which serves it as `Origin::Local` with every right, so a
//!   header it writes here gives it nothing it lacks (an owner gets less than
//!   Local, a teammate far less).
//! - A carrier connection is never a local client: it never spawns a process,
//!   reads or writes a path of its choice, names `mcpServers` or changes the
//!   policy or the rules beyond the Peer origin's (`remote_guard.rs`).
//! - `owner`: [`ConnAuth::CarrierOwner`], served as `Origin::Peer` with every
//!   rule of an authenticated peer daemon (`ConnAuth::peer_daemon`).
//! - `team`: [`ConnAuth::CarrierTeam`], served as `Origin::Web`, and every
//!   request first passes [`gate`]: only the teammate's verbs
//!   (`cmux_agent_pane_policy::share_roles::TEAMMATE_VERBS`), as the acpmux
//!   methods of [`TEAMMATE_METHODS`], each on a chat of `chats` by its exact id, and a prompt
//!   only in the strictest asking modes ([`TEAM_PROMPT_VIA`]). Notifications but
//!   `session/cancel` and answers to the daemon's own requests are dropped.
//! - Audit: each prompt and permission answer logs the carrier, `vmk`, `sub`
//!   and `team` (target `acpmux::carrier_audit`), a carrier prompt's
//!   provenance says `transport: carrier`, and a teammate's prompt names them
//!   as its author (`author.rs`), stamped here from the header, never from
//!   the request.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::{Value, json};

use super::{Conn, ConnAuth, Origin};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};

/// The upgrade request header the session host writes from the carrier grant.
pub const HEADER: &str = "x-acpmux-carrier";

/// The JSON-RPC error code of a request a teammate may not make.
pub const NOT_A_TEAMMATE_VERB: i64 = -32003;

/// Where the carrier socket of `home` lives.
pub fn socket_path(home: &Path) -> PathBuf {
    home.join("run").join("carrier.sock")
}

/// What the carrier grant says the person is to this VM.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// The VM is the person's own.
    Owner,
    /// The person is a teammate of the VM's team.
    Team,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Role::Owner => "owner",
            Role::Team => "team",
        }
    }
}

/// The person the carrier attested for one connection, from its upgrade header only.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attested {
    pub role: Role,
    /// The platform's subject id of the person.
    pub sub: String,
    /// The team the grant names (required for a teammate).
    pub team: Option<String>,
    /// The chats the grant gives a teammate, by exact session id (required and non-empty for a
    /// teammate; an owner's is ignored and kept empty). A chat's forks, side chats and subagent
    /// children are not in it unless the grant names them.
    pub chats: Vec<String>,
    /// The person's display name, optional: the author stamp and the transcript show it (one
    /// line, at most 64 characters, `author.rs`), else `sub`. 1 to [`MAX_ID_BYTES`] bytes, not
    /// blank, no control character.
    pub name: Option<String>,
}

/// Longest `sub`, `team`, chat id or `name`, in bytes.
const MAX_ID_BYTES: usize = 256;
/// Longest header value, in bytes.
const MAX_HEADER_BYTES: usize = 8 * 1024;
/// Most chats one grant names.
const MAX_CHATS: usize = 64;

impl Attested {
    /// Parse the [`HEADER`] values of one upgrade request: exactly one, a JSON object with
    /// `vmk` (`owner` or `team`), `sub`, `team`, `chats` and an optional `name`, nothing else. The error is a stable
    /// reason for the refusal body; it never repeats the value.
    pub fn parse(values: &[&str]) -> Result<Self, &'static str> {
        let [value] = values else {
            return Err(if values.is_empty() {
                "carrier.header_missing"
            } else {
                "carrier.header_repeated"
            });
        };
        if value.len() > MAX_HEADER_BYTES {
            return Err("carrier.header_malformed");
        }
        let Ok(Value::Object(fields)) = serde_json::from_str::<Value>(value) else {
            return Err("carrier.header_malformed");
        };
        if fields.keys().any(|k| !matches!(k.as_str(), "vmk" | "sub" | "team" | "chats" | "name")) {
            return Err("carrier.header_malformed");
        }
        let role = match fields.get("vmk").and_then(Value::as_str) {
            Some("owner") => Role::Owner,
            Some("team") => Role::Team,
            _ => return Err("carrier.header_malformed"),
        };
        let id = |key: &str| -> Result<Option<String>, &'static str> {
            match fields.get(key) {
                None => Err("carrier.header_malformed"),
                Some(Value::Null) => Ok(None),
                Some(Value::String(s)) if valid_id(s) => Ok(Some(s.clone())),
                Some(_) => Err("carrier.header_malformed"),
            }
        };
        let sub = id("sub")?.ok_or("carrier.header_malformed")?;
        let team = id("team")?;
        let name = match fields.get("name") {
            None | Some(Value::Null) => None,
            Some(Value::String(n))
                if (1..=MAX_ID_BYTES).contains(&n.len())
                    && !n.trim().is_empty()
                    && !n.chars().any(char::is_control) =>
            {
                Some(n.clone())
            }
            Some(_) => return Err("carrier.header_malformed"),
        };
        if role == Role::Owner {
            // The owner reaches every chat, as a peer daemon does: a list names nothing for it.
            return Ok(Self { role, sub, team, chats: Vec::new(), name });
        }
        let chats: Vec<String> = match fields.get("chats") {
            Some(Value::Array(list)) if (1..=MAX_CHATS).contains(&list.len()) => list
                .iter()
                .map(|c| c.as_str().filter(|c| valid_id(c)).map(str::to_owned))
                .collect::<Option<_>>()
                .ok_or("carrier.header_malformed")?,
            _ => return Err("carrier.header_malformed"),
        };
        if team.is_none() {
            return Err("carrier.header_malformed");
        }
        Ok(Self { role, sub, team, chats, name })
    }

    /// The proof and origin a connection with this header is served with.
    pub fn served_as(&self) -> (Origin, ConnAuth) {
        match self.role {
            Role::Owner => (Origin::Peer, ConnAuth::CarrierOwner),
            Role::Team => (Origin::Web, ConnAuth::CarrierTeam),
        }
    }

    /// The author a teammate's prompt runs under (`author.rs`): `user_<sub>`, named by the
    /// header's `name`, else by its sub.
    pub fn author(&self) -> Value {
        let id = if self.sub.starts_with("user_") {
            self.sub.clone()
        } else {
            format!("user_{}", self.sub)
        };
        // One line an author name may be: other spaces become a space, format marks go.
        let shown = |s: &str| -> String {
            let line: String = s
                .chars()
                .filter_map(|c| match c {
                    c if c.is_whitespace() => Some(' '),
                    c if crate::author::unshown(c) => None,
                    c => Some(c),
                })
                .collect();
            line.trim().chars().take(crate::author::MAX_NAME_CHARS).collect::<String>()
        };
        let name = self
            .name
            .as_deref()
            .map(shown)
            .filter(|n| !n.trim().is_empty())
            .unwrap_or_else(|| shown(&self.sub));
        json!({"id": id, "name": name})
    }

    /// The audit fields of a request from this connection.
    pub fn audit(&self) -> Value {
        json!({"carrier": true, "vmk": self.role.as_str(), "sub": self.sub, "team": self.team, "name": self.name})
    }
}

/// One line of printable ASCII, no spaces, 1 to [`MAX_ID_BYTES`].
fn valid_id(s: &str) -> bool {
    (1..=MAX_ID_BYTES).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_graphic())
}

/// Each teammate verb (`share_roles::TEAMMATE_VERBS`, cmux-tui's agent-session proxy names) and
/// the acpmux methods that do it. The handshake (`initialize`) is not a verb and is always
/// allowed. Every other method, those added later included, is refused.
pub const TEAMMATE_METHODS: &[(&str, &[&str])] = &[
    // Attach to the chat: its detail, a page of events and its live records (always hidden:
    // a teammate never changes the owner's unread or seen state).
    ("agent-session-attach", &[method::MUX_ATTACH]),
    // Watch it without writing: the same hidden attach, and its detail.
    ("agent-session-observe", &[method::MUX_ATTACH, method::MUX_INFO]),
    // Page through its log, and the images its prompts sent.
    ("agent-session-events", &[method::MUX_EVENTS, method::MUX_ATTACHMENT]),
    ("agent-session-prompt", &[method::SESSION_PROMPT]),
    ("agent-session-cancel", &[method::SESSION_CANCEL]),
    ("agent-session-detach", &[method::MUX_DETACH]),
];

/// The `_meta.acpmux.via` a teammate's prompt runs under, in place of any it named: the Cloud
/// mobile floor, the strictest asking modes (`remote_guard::cloud_mobile`).
pub const TEAM_PROMPT_VIA: &str = "cloud-mobile";

/// Whether a teammate through the carrier may call `m`.
pub fn team_allows(m: &str) -> bool {
    m == method::INITIALIZE
        || cmux_agent_pane_policy::share_roles::TEAMMATE_VERBS.iter().any(|verb| {
            TEAMMATE_METHODS.iter().any(|(v, methods)| v == verb && methods.contains(&m))
        })
}

/// Whether a carrier connection of `role` passes the carrier's own gate with `m`. An owner
/// always does, and is then held to the Peer origin's rules like any peer daemon.
pub fn allows(role: Role, m: &str) -> bool {
    match role {
        Role::Owner => true,
        Role::Team => team_allows(m),
    }
}

/// The refusal of a teammate's request: `why` says what was wrong with it.
fn team_refused(m: &str, why: &str) -> RpcError {
    RpcError::new(
        NOT_A_TEAMMATE_VERB,
        format!("{m} {why}: a teammate through the Cloud carrier watches, prompts and stops the chats its grant names, nothing else"),
    )
    .with_data(json!({"reason": "carrier.team_refused"}))
}

/// A teammate prompts only a chat in the strictest asking modes, checked here and again at
/// dispatch (`TEAM_PROMPT_VIA`). A chat this daemon does not have is left to the dispatcher.
fn strictest_modes(hub: &Hub, who: &Attested, m: &str, params: &Value) -> Result<(), RpcError> {
    if who.role != Role::Team || m != method::SESSION_PROMPT {
        return Ok(());
    }
    match params.get("sessionId").and_then(Value::as_str).map(|id| hub.resolve(id)) {
        Some(Ok(s)) if !hub.cloud_mobile_mode_asks(&s.meta()) => Err(team_mode_refused()),
        _ => Ok(()),
    }
}

/// The refusal of a teammate's prompt to a chat whose mode does not ask before each change.
fn team_mode_refused() -> RpcError {
    RpcError::new(
        NOT_A_TEAMMATE_VERB,
        "session/prompt: a teammate prompts a chat only while it runs in a mode that asks before each change (Claude's default or plan, Codex's ask)",
    )
    .with_data(json!({"reason": TEAM_MODE_NOT_ASKING}))
}

/// The reason a teammate's prompt is refused for the chat's mode.
pub const TEAM_MODE_NOT_ASKING: &str = "carrier.team_mode_not_asking";

/// What the carrier lets `who` send as `m`: a refusal, or the params the request runs with. A
/// teammate's request outside its verbs is refused, and so is one that names no chat or a chat
/// outside the grant's `chats` (by its exact `sessionId`: no name, prefix or `HOST/NAME`). Its
/// attach is hidden; its prompt carries the attested author in place of any it named. An
/// owner's goes on as it came, to the Peer origin's rules.
pub fn admit(who: &Attested, m: &str, mut params: Value) -> Result<Value, RpcError> {
    if who.role == Role::Owner {
        return Ok(params);
    }
    if !team_allows(m) {
        return Err(team_refused(m, "is not a teammate's verb"));
    }
    if m == method::INITIALIZE {
        return Ok(params);
    }
    let Some(obj) = params.as_object_mut() else {
        return Err(team_refused(m, "names no chat"));
    };
    // Only `sessionId` names the chat: `session`, `name` and `host` would let a name or another
    // machine's chat stand in for it.
    if ["session", "name", "host"].iter().any(|k| obj.get(*k).is_some_and(|v| !v.is_null())) {
        return Err(team_refused(m, "names a chat other than by its sessionId"));
    }
    match obj.get("sessionId").and_then(Value::as_str) {
        Some(id) if who.chats.iter().any(|c| c == id) => {}
        Some(_) => return Err(team_refused(m, "names a chat this teammate was not given")),
        None => return Err(team_refused(m, "names no chat")),
    }
    if m == method::MUX_ATTACH {
        obj.insert("visible".into(), Value::Bool(false));
    }
    if m == method::SESSION_PROMPT {
        // `via: cloud-mobile` holds the prompt to the strictest asking modes, whatever the
        // owner's `webAskingModes` add or the Codex bridge's any-mode exception allows: Claude's
        // `default` or `plan`, the bridge's `ask`, nothing else (`Hub::cloud_mobile_mode_asks`,
        // checked by the remote guard and again at dispatch), and it never goes on to a peer.
        crate::hub::merge_mux_meta(
            &mut params,
            json!({"author": who.author(), "via": TEAM_PROMPT_VIA}),
        );
    }
    Ok(params)
}

/// The carrier gate, before any dispatcher (`chats.rs`): [`admit`] for a carrier connection, and
/// for a teammate the chat it names must be that very session here (an id no session has must
/// not resolve to another by name or prefix). Each refusal, prompt, cancel and permission answer
/// is logged with who the carrier attested.
pub(super) fn gate(hub: &Hub, conn: &Conn, m: &str, params: Value) -> Result<Value, RpcError> {
    let Some(carrier) = conn.carrier.as_ref() else {
        return Ok(params);
    };
    let admitted = scoped(hub, carrier, m, params);
    match &admitted {
        Ok(params) => audit(conn, carrier, m, params, None),
        Err(e) => audit(conn, carrier, m, &Value::Null, Some(e)),
    }
    admitted
}

/// [`gate`] without the log: [`admit`], then for a teammate the chat it names must be that very
/// session here, and a prompt runs only in the strictest asking modes.
fn scoped(hub: &Hub, carrier: &Attested, m: &str, params: Value) -> Result<Value, RpcError> {
    let params = admit(carrier, m, params)?;
    if carrier.role == Role::Team
        && let Some(id) = params.get("sessionId").and_then(Value::as_str)
        && hub.resolve(id).is_ok_and(|s| s.id != id)
    {
        return Err(team_refused(m, "names a chat this teammate was not given"));
    }
    strictest_modes(hub, carrier, m, &params)?;
    Ok(params)
}

/// Whether a carrier connection's notification goes on: a teammate's only when it is a
/// `session/cancel` that passes [`gate`] (a chat it was given, by the exact id of a session
/// here), logged like the request form.
pub(super) fn takes_notification(hub: &Hub, conn: &Conn, m: &str, params: Option<&Value>) -> bool {
    match conn.carrier.as_ref() {
        Some(c) if c.role == Role::Team && m == method::SESSION_CANCEL => {
            gate(hub, conn, m, params.cloned().unwrap_or(Value::Null)).is_ok()
        }
        carrier => notification_admitted(hub, carrier, m, params),
    }
}

/// [`takes_notification`] for the person a connection's carrier attested, if any, without the log.
fn notification_admitted(
    hub: &Hub,
    carrier: Option<&Attested>,
    m: &str,
    params: Option<&Value>,
) -> bool {
    let Some(carrier) = carrier.filter(|c| c.role == Role::Team) else {
        return true;
    };
    m == method::SESSION_CANCEL
        && scoped(hub, carrier, m, params.cloned().unwrap_or(Value::Null)).is_ok()
}

/// How a Web or Peer connection's prompt reached this daemon (`prompt_provenance::TRANSPORT`):
/// `carrier` through the carrier socket.
pub(super) fn transport(conn: &Conn) -> &'static str {
    match (&conn.carrier, conn.origin) {
        (Some(_), _) => "carrier",
        (None, Origin::Peer) => "peer",
        (None, _) => "web",
    }
}

/// Log a refusal, prompt, cancel or permission answer, and a teammate's attach or events call,
/// with the person the carrier attested.
pub(super) fn audit(
    conn: &Conn,
    carrier: &Attested,
    m: &str,
    params: &Value,
    refused: Option<&RpcError>,
) {
    let logged = matches!(
        m,
        method::SESSION_PROMPT
            | method::SESSION_CANCEL
            | method::MUX_PERMISSION_RESPOND
            | method::MUX_PERMISSION_GROUP_RESPOND
    );
    // A teammate's reads of a chat are logged too: who watched which chat.
    let team_read =
        carrier.role == Role::Team && matches!(m, method::MUX_ATTACH | method::MUX_EVENTS);
    if !logged && !team_read && refused.is_none() {
        return;
    }
    let text = |k: &str| params.get(k).and_then(Value::as_str).unwrap_or_default();
    let prompt =
        params.pointer("/_meta/acpmux/promptId").and_then(Value::as_str).unwrap_or_default();
    let reason = refused
        .and_then(|e| e.data.as_ref())
        .and_then(|d| d.get("reason"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    tracing::info!(
        target: "acpmux::carrier_audit",
        conn = %conn.id,
        method = m,
        vmk = carrier.role.as_str(),
        sub = %carrier.sub,
        team = carrier.team.as_deref().unwrap_or_default(),
        name = carrier.name.as_deref().unwrap_or_default(),
        session = text("sessionId"),
        prompt,
        permission = text("permissionId"),
        option = text("optionId"),
        refused = reason,
        "carrier request"
    );
}

/// The stable reason a carrier header gets anywhere but the carrier socket.
pub const WRONG_SOCKET: &str = "carrier.wrong_socket";

/// The WebSocket listener's refusal of an upgrade that carries [`HEADER`].
pub(super) fn wrong_socket_response()
-> tokio_tungstenite::tungstenite::handshake::server::ErrorResponse {
    let mut refusal = tokio_tungstenite::tungstenite::handshake::server::ErrorResponse::new(Some(
        WRONG_SOCKET.to_owned(),
    ));
    *refusal.status_mut() = tokio_tungstenite::tungstenite::http::StatusCode::FORBIDDEN;
    refusal
}

// ---------------------------------------------------------------- socket

/// Set to `1` to serve the carrier socket on a machine that is no Cloud VM (a test, a dev VM).
pub const ENV: &str = "ACPMUX_CARRIER_SOCKET";

/// Whether this daemon serves the carrier socket: on a Cloud VM (its creation marker
/// `/etc/cmux/vm-kind` exists, owner or team), or when [`ENV`] is `1`. The marker is
/// guest-writable, which is fine here: the socket gives no process more than the daemon's own
/// unix socket already does (module docs).
pub fn wanted(hub: &Hub) -> bool {
    std::env::var(ENV).is_ok_and(|v| v == "1")
        || (cfg!(target_os = "linux") && hub.vm_marker_root().join("etc/cmux/vm-kind").exists())
}

/// Bind and serve the carrier socket when [`wanted`]: its path, which the daemon removes at
/// stop. A failed bind leaves the carrier's acpmux service refused, never the daemon down.
pub async fn start(hub: &Arc<Hub>, home: &Path) -> Option<PathBuf> {
    if !wanted(hub) {
        return None;
    }
    #[cfg(unix)]
    {
        let path = socket_path(home);
        match bind(&path).await {
            Ok(listener) => {
                tokio::spawn(serve(hub.clone(), listener));
                Some(path)
            }
            Err(e) => {
                tracing::warn!("no carrier socket this run: {e:#}");
                None
            }
        }
    }
    #[cfg(not(unix))]
    {
        let _ = home;
        tracing::warn!("the carrier socket is served on unix only");
        None
    }
}

/// Bind the carrier socket (mode 0600 in a 0700 directory), replacing a stale one no live
/// daemon answers on.
#[cfg(unix)]
pub async fn bind(path: &Path) -> anyhow::Result<tokio::net::UnixListener> {
    use anyhow::Context;
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    cmux_unix_socket::check_path(path)?;
    if let Some(parent) = path.parent() {
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(parent)?;
    }
    if path.exists() {
        if tokio::net::UnixStream::connect(path).await.is_ok() {
            anyhow::bail!("another acpmux daemon serves the carrier socket {}", path.display());
        }
        std::fs::remove_file(path)?;
    }
    let listener =
        tokio::net::UnixListener::bind(path).with_context(|| format!("bind {}", path.display()))?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    tracing::info!("carrier socket listening on {}", path.display());
    Ok(listener)
}

/// Serve the carrier socket: one WebSocket per connection, admitted by its [`HEADER`].
#[cfg(unix)]
pub async fn serve(hub: Arc<Hub>, listener: tokio::net::UnixListener) -> anyhow::Result<()> {
    loop {
        let stream = match listener.accept().await {
            Ok((stream, _)) => stream,
            Err(e) => {
                tracing::warn!("carrier socket accept failed: {e}");
                tokio::time::sleep(super::accept_retry_delay(&e)).await;
                continue;
            }
        };
        // The socket's mode admits this user only; the peer's uid says so again.
        // SAFETY: geteuid has no preconditions and cannot fail.
        let own = unsafe { libc::geteuid() };
        if stream.peer_cred().map(|c| c.uid()).ok() != Some(own) {
            tracing::warn!("carrier socket: refused a connection from another user");
            continue;
        }
        tokio::spawn(serve_one(hub.clone(), stream));
    }
}

/// One carrier connection: the upgrade with its header, then the protocol.
pub async fn serve_one<S>(hub: Arc<Hub>, stream: S)
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Frame;
    use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};

    let attested: Arc<std::sync::Mutex<Option<Attested>>> = Arc::default();
    let record = attested.clone();
    let callback = move |req: &Request, resp: Response| -> Result<Response, ErrorResponse> {
        let values: Vec<&str> =
            req.headers().get_all(HEADER).iter().map(|v| v.to_str().unwrap_or("\u{0}")).collect();
        match Attested::parse(&values) {
            Ok(who) => {
                *record.lock().unwrap_or_else(|e| e.into_inner()) = Some(who);
                Ok(resp)
            }
            Err(reason) => {
                tracing::warn!(reason, "carrier socket: refused an upgrade");
                let mut refusal = ErrorResponse::new(Some(reason.to_owned()));
                *refusal.status_mut() = tokio_tungstenite::tungstenite::http::StatusCode::FORBIDDEN;
                Err(refusal)
            }
        }
    };
    let ws = match tokio::time::timeout(
        super::WS_HANDSHAKE_TIMEOUT,
        tokio_tungstenite::accept_hdr_async_with_config(stream, callback, Some(super::ws_config())),
    )
    .await
    {
        Ok(Ok(ws)) => ws,
        _ => return,
    };
    let Some(who) = attested.lock().unwrap_or_else(|e| e.into_inner()).take() else {
        return;
    };
    let (mut sink, mut source) = ws.split();
    let (in_tx, in_rx) = tokio::sync::mpsc::channel::<String>(256);
    let (out_tx, mut out_rx) = tokio::sync::mpsc::channel::<String>(4096);
    let reader = tokio::spawn(async move {
        while let Some(Ok(frame)) = source.next().await {
            match frame {
                Frame::Text(t) if in_tx.send(t.to_string()).await.is_err() => break,
                Frame::Close(_) => break,
                _ => {}
            }
        }
    });
    let (stop, mut stopped) = tokio::sync::oneshot::channel::<()>();
    let writer = tokio::spawn(async move {
        loop {
            let line = tokio::select! {
                line = out_rx.recv() => line,
                _ = &mut stopped => None,
            };
            let Some(line) = line else { break };
            let text = line.trim_end_matches('\n').to_owned();
            if sink.send(Frame::Text(text.into())).await.is_err() {
                break;
            }
        }
        let _ = sink.close().await;
    });
    serve_attested(hub, in_rx, out_tx, who).await;
    let _ = stop.send(());
    reader.abort();
    let _ = writer.await;
}

/// A carrier connection whose header the caller checked (the socket above, or a test).
pub async fn serve_attested(
    hub: Arc<Hub>,
    inbound: tokio::sync::mpsc::Receiver<String>,
    out: tokio::sync::mpsc::Sender<String>,
    who: Attested,
) {
    let (origin, auth) = who.served_as();
    tracing::info!(
        target: "acpmux::carrier_audit",
        vmk = who.role.as_str(),
        sub = %who.sub,
        team = who.team.as_deref().unwrap_or_default(),
        "carrier connection"
    );
    super::serve_connection_from(
        hub,
        inbound,
        out,
        origin,
        auth,
        None,
        false,
        crate::sender_harness::SocketPeer::Unknown,
        None,
        None,
        Some(who),
    )
    .await
}

#[cfg(test)]
#[path = "carrier_tests.rs"]
mod tests;
