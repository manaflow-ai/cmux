//! The v2 request origin on a connection (plans/cmux-next/request-origin.md):
//! every `cmux.protocol/2` line is parsed ONCE into a typed request
//! (`resource_router::parse_resource_line`); the origin rules check that
//! value and the dispatcher acts on the same value. A line that does not
//! parse is refused, and a refused line is never dispatched.
//! `origin.confirmation.issue` is answered here. The rules themselves live
//! in `crate::request_origin`.

use super::*;
use crate::Actor;
use crate::panic_free::RecoverPoison;
use crate::request_origin::{
    CONFIRMATION_TTL_MS, HelloRole, LocalPeer, RequestOrigin, forbidden, mint_token, needs_user,
    valid_sha256_hex,
};
use crate::resource::RequestEnvelope;

/// Applies the origin rules to one parsed `cmux.protocol/2` line, then
/// validates and dispatches the same parse. The origin rules run before
/// the envelope and catalog validation, so a refused origin learns nothing
/// from validation.
pub(super) fn handle_resource_line(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    envelope: Result<RequestEnvelope, ResourceError>,
    writer: &MessageWriter,
) -> bool {
    let mut envelope = match envelope {
        Ok(envelope) => envelope,
        Err(error) => {
            let response = crate::resource_router::malformed_resource_response(message, error);
            return writer.send_control(&response).is_ok();
        }
    };
    let (id, operation) = (envelope.id.clone(), envelope.operation);
    // The launch credential leaves the envelope here; it is verified after
    // the clients lock is released and before any owner takes its locks.
    let credential = envelope.credential.take();
    let admitted = check(mux, client, &envelope)
        .and_then(|actor| {
            check_credential_owner(mux, client, operation, &actor, credential.is_some())?;
            if credential.is_some() && derived_origin(mux, client) == RequestOrigin::Page {
                // A page relay forwards a page's requests: never a terminal.
                let reason = "credential_not_local";
                return Err(ResourceError::validation_invalid(Some("credential"), reason));
            }
            mux.request_actor(actor, credential.as_ref().map(|c| c.as_str()))
        })
        .and_then(|actor| check_pairing_accept(mux, client, &envelope, &actor).map(|()| actor))
        .and_then(|actor| crate::resource_router::validate_resource_envelope(envelope, actor));
    crate::debug_spans::mark("origin.admitted");
    match admitted {
        Ok(request) => handle_resource_connection_message(mux, client, request, writer),
        Err(error) => {
            if operation == ResourceOperation::HistoryTrailRecord {
                // The trail's failure log (cx-hnmbt.14): an origin refusal
                // never reaches the history module.
                crate::history_ops::log_trail_refusal(mux, client, &error);
            }
            send_resource_response(writer, id, operation, Err(error))
        }
    }
}

/// The actor of `envelope` on `client` once its origin passes, or why it is
/// refused. A client
/// with no registry record (a connection detached while its reader still
/// held a line) has no known role, so it is refused (fail closed).
fn check(mux: &Mux, client: u64, envelope: &RequestEnvelope) -> Result<Actor, ResourceError> {
    let now_ms = mux.control_clients.origin_clock.monotonic_ms();
    let mut state = mux.control_clients.state.lock().recover_poison();
    let Some(record) = state.clients.get_mut(&client) else {
        return Err(forbidden(
            "the connection is not registered",
            // No record, no role: name the least the connection could be
            // without a hello (the catalog requires `derived`).
            json!({
                "derived": RequestOrigin::Agent.wire_name(),
                "reason": "connection_not_registered",
            }),
        ));
    };
    record.origin.request_origin(
        envelope.operation,
        &envelope.params,
        envelope.origin.as_ref(),
        now_ms,
    )?;
    let (transport, local) = (record.transport, record.origin.actor());
    drop(state);
    Ok(peer_or_local(mux, client, transport, local))
}

/// Classifies one accepted local peer while its kernel PID evidence is live.
fn classify_local_peer(
    mux: &Mux,
    peer_key: Option<&str>,
    session_for_pid: impl FnOnce(u32) -> Option<u32>,
) -> LocalPeer {
    let Some(process) = peer_key.and_then(peer_pid) else { return LocalPeer::Unknown };
    let Some(session) = session_for_pid(process) else { return LocalPeer::Unknown };
    let terminal = mux.with_state(|state| {
        state
            .surfaces
            .values()
            .chain(state.terminal_catalog.values())
            .find(|surface| surface.process_id() == Some(session))
            .and_then(|surface| surface.terminal_public_id())
            .map(|terminal| terminal.as_str().to_string())
    });
    if let Some(terminal) = terminal {
        return LocalPeer::Terminal(terminal);
    }
    LocalPeer::Other
}

pub(super) fn peer_pid(key: &str) -> Option<u32> {
    let (pid, version) = key.strip_prefix("token:")?.split_once('.')?;
    let pid = pid.parse().ok()?;
    (!version.is_empty() && pid > 0).then_some(pid)
}

#[cfg(unix)]
pub(super) fn peer_session_id(pid: u32) -> Option<u32> {
    let pid = libc::pid_t::try_from(pid).ok()?;
    // SAFETY: getsid only reads kernel process metadata for the positive pid.
    let session = unsafe { libc::getsid(pid) };
    u32::try_from(session).ok().filter(|session| *session > 0)
}

#[cfg(not(unix))]
pub(super) fn peer_session_id(_pid: u32) -> Option<u32> {
    None
}

/// `credential.mint` and `credential.rotate` require the verified frontend.
/// Unknown, terminal-bound and other local peers fail closed. Acpmux treats a
/// mint refusal as non-fatal until the frontend can delegate mint authority.
fn check_credential_owner(
    mux: &Mux,
    client: u64,
    operation: ResourceOperation,
    actor: &Actor,
    presents_credential: bool,
) -> Result<(), ResourceError> {
    if !matches!(operation, ResourceOperation::CredentialMint | ResourceOperation::CredentialRotate)
    {
        return Ok(());
    }
    let owner = matches!(actor, Actor::Frontend { .. });
    let local = mux.control_clients.is_unix(client) && !mux.is_remote_client(client);
    let principal = mux.conversation_principal(client) == crate::conversation_store::LOCAL_USER;
    if owner && local && principal && !presents_credential {
        return Ok(());
    }
    Err(forbidden(
        "minting and rotating launch credentials is for the owner's own connection only",
        json!({"derived": "agent", "required": "user", "reason": "credential_owner_only"}),
    ))
}

/// Refusal text when a connection that is not a human surface approves a
/// WebSocket pairing.
pub(super) const PAIRING_APPROVAL_NEEDS_HUMAN: &str =
    "only the cmux app or the TUI that runs this daemon can approve a pairing";

/// Whether `client` may APPROVE a WebSocket pairing (cx-ehrq). Approval
/// admits a browser to the whole daemon, so it must come from a human
/// surface: the in-process TUI (which calls `Mux::respond_pairing` and never
/// reaches this check) or the verified cmux app, the `frontend` actor. Any
/// other local connection (an agent in a pane, a script, the CLI) is the
/// plain local user to the daemon and may only deny.
pub(super) fn may_approve_pairing(mux: &Mux, client: u64) -> bool {
    matches!(connection_actor(mux, client), Actor::Frontend { .. })
}

/// Whether `client` derives origin `user` (the verified cmux app). On every
/// platform; a client with no record, or one with no proof, is not.
pub(super) fn is_user(mux: &Mux, client: u64) -> bool {
    derived_origin(mux, client) == RequestOrigin::User
}

/// Whether `client` derives the page origin (a page WebSocket or the host's
/// page relay, with or without a page id).
pub(super) fn is_page(mux: &Mux, client: u64) -> bool {
    derived_origin(mux, client) == RequestOrigin::Page
}

/// The origin `client` derives; a client with no record is an agent.
pub(super) fn derived_origin(mux: &Mux, client: u64) -> RequestOrigin {
    let state = mux.control_clients.state.lock().recover_poison();
    state.clients.get(&client).map_or(RequestOrigin::Agent, |record| record.origin.derive())
}

/// The v2 form of [`may_approve_pairing`]: `pairing_request.resolve` with
/// `decision: accept` needs the `frontend` actor. A connection that is not a
/// local Unix one is left to the trusted-local refusal.
fn check_pairing_accept(
    mux: &Mux,
    client: u64,
    envelope: &RequestEnvelope,
    actor: &Actor,
) -> Result<(), ResourceError> {
    let accept = envelope.operation == ResourceOperation::PairingRequestResolve
        && envelope.params.get("decision").and_then(Value::as_str) == Some("accept");
    if !accept || !mux.control_clients.is_unix(client) || matches!(actor, Actor::Frontend { .. }) {
        return Ok(());
    }
    let derived = {
        let state = mux.control_clients.state.lock().recover_poison();
        state.clients.get(&client).map_or(RequestOrigin::Agent, |record| record.origin.derive())
    };
    Err(forbidden(
        PAIRING_APPROVAL_NEEDS_HUMAN,
        json!({"derived": derived.wire_name(), "required": "user", "reason": "pairing_approval_needs_human"}),
    ))
}

/// The actor of a durable mutation that `client` asks for on the legacy
/// control protocol. A client with no record is never the local user.
pub(super) fn connection_actor(mux: &Mux, client: u64) -> Actor {
    let state = mux.control_clients.state.lock().recover_poison();
    let Some(record) = state.clients.get(&client) else {
        return Actor::Peer { id: "unregistered".to_string() };
    };
    let (transport, local) = (record.transport, record.origin.actor());
    drop(state);
    peer_or_local(mux, client, transport, local)
}

/// A link peer (`peer:link:<install>`), any other WebSocket or remote-entry
/// connection (`peer:websocket`, `peer:remote`), else the local connection's
/// own actor. Read after the clients lock is released: the peers lock is
/// never taken under it.
fn peer_or_local(mux: &Mux, client: u64, transport: ClientTransport, local: Actor) -> Actor {
    match mux.remote_relay().peer_checked(client) {
        Ok(Some(peer)) => return Actor::Peer { id: format!("link:{}", peer.install) },
        // A poisoned peers lock cannot say the client is local: fail closed.
        Err(_) => return Actor::Peer { id: "remote".to_string() },
        Ok(None) => {}
    }
    match transport {
        ClientTransport::Unix => local,
        ClientTransport::WebSocket => Actor::Peer { id: "websocket".to_string() },
        ClientTransport::Remote => Actor::Peer { id: "remote".to_string() },
    }
}

/// What the daemon knows about a connection for the hosting-app check
/// (`crate::apps::hosting_app_connection`, the door of origin `user`).
pub(super) struct AppConnection {
    /// Bound to an agent's conversation; switches to the identity lane's
    /// terminal/acp_session actor with `agent` once it lands.
    pub(super) agent: bool,
    /// Proved, never declared: the install-key hello or the app's code
    /// signature (P8, server/app_trust.rs). `set-client-info kind` and a
    /// page relay never count.
    pub(super) verified_app: bool,
}

pub(super) fn app_connection(mux: &Mux, client: u64) -> AppConnection {
    let verified_app = {
        let state = mux.control_clients.state.lock().recover_poison();
        state
            .clients
            .get(&client)
            .is_some_and(|record| record.origin.derive() == RequestOrigin::User)
    };
    AppConnection {
        agent: mux.conversation_principal(client) != crate::conversation_store::LOCAL_USER,
        verified_app,
    }
}

/// A WebSocket connection admitted with a page-bound credential
/// (`page-credential {page}`): fixed at accept, with its page.
pub(super) fn set_scoped_page(mux: &Mux, client: u64, page: String) {
    let mut state = mux.control_clients.state.lock().recover_poison();
    if let Some(record) = state.clients.get_mut(&client) {
        record.origin.page = Some(page);
        record.origin.scoped_page = true;
    }
}

/// The conversation events a page-bound connection of the Channels page
/// hears (and `chief-changed`, its Chiefs, and `participant-avatar-changed`,
/// the pictures it draws); every other page-bound connection hears none.
static CHANNELS_SCOPED_EVENTS: std::sync::LazyLock<[String; 8]> = std::sync::LazyLock::new(|| {
    [
        "conversation-changed",
        "conversation-typing",
        "conversation-draft",
        "conversation-run-changed",
        "conversation-live",
        "conversation-inbox-changed",
        "chief-changed",
        "participant-avatar-changed",
    ]
    .map(String::from)
});

/// The subscribe events a page relay connection hears (page-router.json
/// `events` of its page; none for a relay without a page), a page-bound
/// connection's (its page's conversation events), or `None` for any other
/// connection, whose stream stays as it was.
pub(super) fn page_relay_events(mux: &Mux, client: u64) -> Option<&'static [String]> {
    let state = mux.control_clients.state.lock().recover_poison();
    let origin = &state.clients.get(&client)?.origin;
    if origin.scoped_page {
        let channels = origin.page.as_deref() == Some("home-channels");
        return Some(if channels { &CHANNELS_SCOPED_EVENTS[..] } else { &[] });
    }
    (origin.role == HelloRole::PageRelay).then(|| {
        origin
            .page
            .as_deref()
            .map_or(&[][..], crate::request_origin::page_router_table::page_events)
    })
}

#[cfg(unix)]
/// Gate A2 on the legacy `apps-*` door: `Err` unless `client` derives
/// origin `user` (a verified cmux app connection).
pub(super) fn require_user(mux: &Mux, client: u64) -> Result<(), crate::apps::ApiError> {
    let derived = {
        let state = mux.control_clients.state.lock().recover_poison();
        state.clients.get(&client).map_or(RequestOrigin::Agent, |record| record.origin.derive())
    };
    if derived == RequestOrigin::User {
        return Ok(());
    }
    let refusal = needs_user(derived);
    let mut error = crate::apps::ApiError::new(&refusal.code, refusal.message);
    error.details = Some(refusal.details);
    Err(error)
}

/// Fixes `client`'s hello role (step 1), and `verified_app` when prover A
/// (the app's code signature) passed for a role-main hello. False when the
/// client is gone or already has a role; nothing changes then.
pub(super) fn set_hello(
    mux: &Mux,
    client: u64,
    role: HelloRole,
    peer_key: Option<String>,
    signature_proved: bool,
    page: Option<String>,
) -> bool {
    let mut state = mux.control_clients.state.lock().recover_poison();
    let Some(record) = state.clients.get_mut(&client) else { return false };
    if record.origin.role != HelloRole::Legacy {
        return false;
    }
    record.origin.role = role;
    if peer_key.is_some() {
        record.origin.peer_key = peer_key;
    }
    record.origin.page = page;
    record.origin.verified_app = role == HelloRole::Main && signature_proved;
    true
}

/// Records kernel peer identity at accept, before a legacy client can skip hello.
pub(super) fn set_peer_identity_at_accept(
    mux: &Mux,
    client: u64,
    peer_key: Option<String>,
    peer_token: Option<cmux_link::app_caller::PeerToken>,
) {
    let local_peer = classify_local_peer(mux, peer_key.as_deref(), peer_session_id);
    let mobile_host = peer_executable(peer_key.as_deref(), peer_token.as_ref())
        .is_some_and(|path| is_bundled_mobile_host_path(&path));
    let mut state = mux.control_clients.state.lock().recover_poison();
    if let Some(record) = state.clients.get_mut(&client) {
        record.origin.peer_key = peer_key;
        record.origin.local_peer = local_peer;
        record.origin.mobile_host = mobile_host;
    }
}

/// Name of the phone host beside the daemon's executable
/// (`Contents/Resources/bin/cmux-mobile-host` next to `.../bin/cmux-tui`).
const MOBILE_HOST_NAME: &str = "cmux-mobile-host";

/// Whether `path` (a peer's executable) is this build's bundled
/// `cmux-mobile-host`: by real path, the regular file of that name beside
/// the daemon's own (canonical) executable. Any lookup failure is false (a
/// daemon with no hostd beside it, such as a development build run from
/// another folder, has no phone lane that may write the host policy).
fn is_bundled_mobile_host_path(path: &Path) -> bool {
    static SIBLING: std::sync::OnceLock<Option<PathBuf>> = std::sync::OnceLock::new();
    let sibling = SIBLING.get_or_init(|| {
        let own = std::fs::canonicalize(std::env::current_exe().ok()?).ok()?;
        let sibling = std::fs::canonicalize(own.parent()?.join(MOBILE_HOST_NAME)).ok()?;
        std::fs::metadata(&sibling).ok()?.is_file().then_some(sibling)
    });
    let Some(sibling) = sibling else { return false };
    std::fs::canonicalize(path).is_ok_and(|path| &path == sibling)
}

/// The executable of the accepted peer, read so that a process that reused
/// the peer's pid never answers for it. macOS reads it by the peer's audit
/// token (the kernel refuses a token whose pid version is stale; exec gives
/// a process a new pid version). Linux reads the peer pid's executable and
/// then checks the pid still has the start time in the peer key
/// (`platform::peer_executable`, the peer authentication module); a process that
/// exec'd after it connected keeps its pid and start time there, which
/// PROTOCOL.md lists as the residual risk.
fn peer_executable(
    peer_key: Option<&str>,
    peer_token: Option<&cmux_link::app_caller::PeerToken>,
) -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        let _ = peer_key;
        cmux_link::app_caller::executable_path(peer_token?)
    }
    #[cfg(target_os = "linux")]
    {
        let _ = peer_token;
        platform::peer_executable(peer_key?)
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        let _ = (peer_key, peer_token);
        None
    }
}

/// Whether `client` is a phone's lane spliced by this build's
/// cmux-mobile-host (fixed at accept; a client with no record is not).
pub(super) fn is_mobile_host_lane(mux: &Mux, client: u64) -> bool {
    let state = mux.control_clients.state.lock().recover_poison();
    state.clients.get(&client).is_some_and(|record| record.origin.mobile_host)
}

/// The page a WebSocket connection serves, from its handshake Origin
/// (`page-router-v1`): fixed at accept, before the connection's first line.
pub(super) fn set_page(mux: &Mux, client: u64, page: String) {
    let mut state = mux.control_clients.state.lock().recover_poison();
    if let Some(record) = state.clients.get_mut(&client) {
        record.origin.page = Some(page);
    }
}

/// The page id of `client` (a page WebSocket's handshake Origin, or a page
/// relay's hello), or `None` (also for a client with no record). For the
/// audit actor only: an access decision reads [`websocket_admission`].
pub(super) fn connection_page(mux: &Mux, client: u64) -> Option<String> {
    let state = mux.control_clients.state.lock().recover_poison();
    state.clients.get(&client).and_then(|record| record.origin.page.clone())
}

/// How a WebSocket connection was admitted, for the Chief registry
/// (`chief-profile-ws-v1`): `None` for a client with no record or a poisoned
/// registry lock (fail closed).
pub(super) struct WebSocketAdmission {
    /// A pairing-store credential (an approved pairing, or the verified app's
    /// person page credential).
    pub(super) person: bool,
    /// The page of the handshake Origin.
    pub(super) page: Option<String>,
    /// Admitted with a credential bound to that page (`page-credential {page}`).
    pub(super) scoped_page: bool,
}

pub(super) fn websocket_admission(mux: &Mux, client: u64) -> Option<WebSocketAdmission> {
    let state = mux.control_clients.state.lock().ok()?;
    let record = state.clients.get(&client)?;
    matches!(record.transport, ClientTransport::WebSocket).then(|| WebSocketAdmission {
        person: record.person,
        page: record.origin.page.clone(),
        scoped_page: record.origin.scoped_page,
    })
}

/// Step 2 passed (prover B): `client`, a role-main connection, is the
/// verified app. Its `peer_key` stays the audit-token key, so its page
/// relay (same process, same token) still matches it. False when the client
/// is gone or is not role main.
pub(super) fn set_install_proved(mux: &Mux, client: u64, install_id: &str) -> bool {
    let mut state = mux.control_clients.state.lock().recover_poison();
    let Some(record) = state.clients.get_mut(&client) else { return false };
    if record.origin.role != HelloRole::Main {
        return false;
    }
    record.origin.verified_app = true;
    record.origin.install_id = Some(install_id.to_string());
    true
}

/// `origin.confirmation.issue {operation, params_sha256,
/// relay_connection_id}` from the verified app: a token the relay
/// connection of the same peer can present once, within the TTL, for
/// exactly that operation and params.
pub(super) fn handle_issue(
    mux: &Arc<Mux>,
    client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
    id: ResourceRequestId,
    writer: &MessageWriter,
) -> bool {
    let result = issue(mux, client, request);
    send_resource_response(writer, id, ResourceOperation::OriginConfirmationIssue, result)
}

fn issue(
    mux: &Mux,
    client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    mux.resolve_resource_path(crate::ResourceTarget::Session, &request.selectors)?;
    // A catalog operation, or a routed one (page-router-v1 namespaces).
    let operation = string_field(request, "operation");
    let known = serde_json::from_value::<ResourceOperation>(json!(operation)).is_ok()
        || crate::request_origin::page_router_table::routed(operation).is_some();
    if !known {
        return Err(ResourceError::validation_invalid(
            Some("operation"),
            "operation must be a cmux.protocol/2 catalog or routed operation",
        ));
    }
    let operation = operation.to_owned();
    let params_sha256 = string_field(request, "params_sha256").to_string();
    if !valid_sha256_hex(&params_sha256) {
        return Err(ResourceError::validation_invalid(
            Some("params_sha256"),
            "params_sha256 must be 64 lowercase hex digits",
        ));
    }
    let relay = string_field(request, "relay_connection_id").parse::<u64>().map_err(|_| {
        ResourceError::validation_invalid(
            Some("relay_connection_id"),
            "relay_connection_id must be a connection id from client-hello",
        )
    })?;
    let token = mint_token()?;
    // Validity uses the monotonic deadline; expires_at is for display.
    let now_ms = mux.control_clients.origin_clock.monotonic_ms();
    let deadline_ms = now_ms.saturating_add(CONFIRMATION_TTL_MS);
    let expires_at_ms =
        mux.control_clients.origin_clock.wall_ms().saturating_add(CONFIRMATION_TTL_MS);
    let mut state = mux.control_clients.state.lock().recover_poison();
    let caller = state.clients.get(&client).map(|record| &record.origin);
    let Some(caller) = caller else { return Err(needs_user(RequestOrigin::Agent)) };
    let derived = caller.derive();
    if caller.role == HelloRole::PageRelay {
        return Err(forbidden(
            "a page relay connection cannot issue confirmations",
            json!({"derived": derived.wire_name()}),
        ));
    }
    if derived != RequestOrigin::User {
        return Err(needs_user(derived));
    }
    let caller_peer = caller.peer_key.clone();
    let same_peer_relay = state.clients.get_mut(&relay).filter(|record| {
        relay != client
            && record.origin.role == HelloRole::PageRelay
            && caller_peer.is_some()
            && record.origin.peer_key == caller_peer
    });
    let Some(relay_record) = same_peer_relay else {
        return Err(forbidden(
            "the relay connection is not a page relay of the same app",
            json!({"required": "user", "derived": derived.wire_name(), "reason": "relay_mismatch"}),
        ));
    };
    relay_record.origin.store_named_confirmation(
        token.clone(),
        operation,
        params_sha256,
        deadline_ms,
        now_ms,
    );
    Ok(json!({"token": token, "expires_at": expires_at_ms.to_string()}))
}

/// A string field the catalog already validated ("" if absent).
fn string_field<'a>(
    request: &'a crate::resource_router::ParsedResourceRequest,
    name: &str,
) -> &'a str {
    request.fields.get(name).and_then(Value::as_str).unwrap_or_default()
}

#[cfg(test)]
pub(super) use test_hooks::*;

/// Test hooks: set what client-hello and P8 would set.
#[cfg(test)]
mod test_hooks {
    use super::*;
    use crate::request_origin::ConnectionOrigin;

    fn with_origin(mux: &Arc<Mux>, client: u64, change: impl FnOnce(&mut ConnectionOrigin)) {
        let mut state = mux.control_clients.state.lock().recover_poison();
        change(&mut state.clients.get_mut(&client).expect("registered client").origin);
    }

    pub(in crate::server) fn set_role_for_test(mux: &Arc<Mux>, client: u64, role: &str) {
        let role = HelloRole::declared(role).expect("main or page_relay");
        with_origin(mux, client, |origin| origin.role = role);
    }

    pub(in crate::server) fn set_verified_app_for_test(
        mux: &Arc<Mux>,
        client: u64,
        verified: bool,
    ) {
        with_origin(mux, client, |origin| origin.verified_app = verified);
    }

    /// What accept sets for a connection from the bundled cmux-mobile-host.
    pub(in crate::server) fn set_mobile_host_peer_for_test(mux: &Arc<Mux>, client: u64) {
        with_origin(mux, client, |origin| origin.mobile_host = true);
    }

    pub(in crate::server) fn set_peer_key_for_test(mux: &Arc<Mux>, client: u64, peer_key: &str) {
        with_origin(mux, client, |origin| origin.peer_key = Some(peer_key.to_string()));
    }

    pub(in crate::server) fn set_local_peer_for_test(mux: &Arc<Mux>, client: u64, peer: LocalPeer) {
        with_origin(mux, client, |origin| origin.local_peer = peer);
    }

    pub(in crate::server) fn advance_origin_clock_for_test(mux: &Arc<Mux>, ms: u64) {
        mux.control_clients.origin_clock.advance(ms);
    }

    /// Moves only the wall clock (an NTP step or a user change).
    pub(in crate::server) fn jump_origin_wall_clock_for_test(mux: &Arc<Mux>, delta_ms: i64) {
        mux.control_clients.origin_clock.jump_wall(delta_ms);
    }

    pub(in crate::server) fn role_for_test(mux: &Arc<Mux>, client: u64) -> String {
        let role = {
            let state = mux.control_clients.state.lock().recover_poison();
            state.clients.get(&client).map_or(HelloRole::Legacy, |record| record.origin.role)
        };
        match role {
            HelloRole::Legacy => "legacy",
            HelloRole::Main => "main",
            HelloRole::PageRelay => "page_relay",
        }
        .to_string()
    }
}

#[cfg(all(test, unix))]
#[path = "origin_gate_tests.rs"]
mod tests;

#[cfg(all(test, unix))]
#[path = "page_access_tests.rs"]
mod page_access_tests;

#[cfg(all(test, unix))]
#[path = "pairing_gate_tests.rs"]
mod pairing_gate_tests;

#[cfg(all(test, unix))]
#[path = "chief_profile_ws_tests.rs"]
mod chief_profile_ws_tests;

/// The peer executable is read only while the peer key or token still
/// names the same process (review 2 finding 3): a stale pid version, as a
/// process that reused the pid would have, reads nothing.
#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
mod peer_executable_tests {
    use super::peer_executable;
    use crate::platform::transport::Stream;

    #[test]
    fn peer_executable_needs_the_peers_own_pid_version() {
        let (ours, _theirs) = std::os::unix::net::UnixStream::pair().unwrap();
        let key = Stream::peer_process_key(&ours);
        let token = Stream::peer_token(&ours);
        let own = std::fs::canonicalize(std::env::current_exe().unwrap()).unwrap();
        let read = peer_executable(key.as_deref(), token.as_ref()).expect("our own executable");
        assert_eq!(std::fs::canonicalize(read).unwrap(), own);
        let key = key.unwrap();
        let (pid, _) = key.split_once('.').unwrap();
        let stale_key = format!("{pid}.1");
        let stale_token = token.map(|token| token.with_pid_version_for_test(1));
        assert_eq!(peer_executable(Some(&stale_key), stale_token.as_ref()), None);
    }
}
