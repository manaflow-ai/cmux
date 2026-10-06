//! Renderer grants: `mint-terminal-renderer`,
//! `mint-terminal-renderer-by-terminal` and the v2
//! `terminal.renderer_grant.create`.
//!
//! A grant is a one-use credential for the terminal host's local socket, and
//! its holder can view the terminal. Only a trusted local caller may mint one:
//! a registered Unix socket connection whose origin is not `page`. Every other
//! caller (a WebSocket, a page relay, an unknown client) is refused with
//! `origin.forbidden` before any surface is resolved. The remote relay never
//! reaches this point (its frame gate denies these commands), and app
//! routers never get the v2 operation (`never` in the app scopes).

use super::*;
use crate::request_origin::RequestOrigin;
use crate::terminal_host_runtime::RendererGrantFailure;

const FORBIDDEN: &str = "origin.forbidden";
/// A mint the terminal host did not answer (retryable).
const HOST_UNAVAILABLE: &str = "terminal_host.unavailable";
const LEGACY_HOST_UNAVAILABLE: &str = "terminal_host_unavailable";
/// `reason` of a refusal off a local Unix connection. The details follow
/// the catalog's `OriginForbiddenDetails` (no extra fields), also on the
/// legacy commands.
const LOCAL_ONLY: &str = "local_only";

/// The refusal of a mint by an untrusted caller.
#[derive(Debug)]
pub(super) struct MintRefused {
    message: &'static str,
    details: Value,
}

impl std::fmt::Display for MintRefused {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.message)
    }
}

impl std::error::Error for MintRefused {}

/// `None` when `client` may mint; otherwise why not. A client with no
/// registry record is refused (fail closed).
fn refusal(mux: &Mux, client: u64) -> Option<MintRefused> {
    let state = mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(record) = state.clients.get(&client) else {
        return Some(MintRefused {
            message: "a renderer grant needs a registered local connection",
            details: json!({"derived": RequestOrigin::Agent.wire_name(), "reason": LOCAL_ONLY}),
        });
    };
    let derived = record.origin.derive();
    if !matches!(record.transport, ClientTransport::Unix) {
        return Some(MintRefused {
            message: "a renderer grant needs a local Unix socket connection",
            details: json!({"derived": derived.wire_name(), "reason": LOCAL_ONLY}),
        });
    }
    (derived == RequestOrigin::Page).then(|| MintRefused {
        message: "a page relay connection cannot mint a renderer grant",
        details: json!({"required": "agent", "derived": derived.wire_name()}),
    })
}

/// `mint-terminal-renderer {surface, ttl_ms}`.
pub(super) fn mint_by_surface(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    ttl_ms: u64,
) -> anyhow::Result<Value> {
    if let Some(refused) = refusal(mux, client) {
        return Err(refused.into());
    }
    mint_legacy(mux, surface, ttl_ms)
}

/// `mint-terminal-renderer-by-terminal {terminal, ttl_ms}`.
pub(super) fn mint_by_terminal(
    mux: &Mux,
    client: u64,
    terminal: String,
    ttl_ms: u64,
) -> anyhow::Result<Value> {
    if let Some(refused) = refusal(mux, client) {
        return Err(refused.into());
    }
    let terminal = TerminalPublicId::parse(terminal)?;
    let surface = mux
        .resource_surface_for_terminal(&terminal)
        .ok_or_else(|| anyhow::anyhow!("terminal {terminal} is not live"))?;
    mint_legacy(mux, surface, ttl_ms)
}

fn mint_legacy(mux: &Mux, surface: SurfaceId, ttl_ms: u64) -> anyhow::Result<Value> {
    let surface = get_surface(mux, surface)?;
    require_pty(&surface)?;
    let grant = surface.mint_renderer_grant(Duration::from_millis(ttl_ms))?;
    Ok(json!({
        "endpoint": grant.endpoint,
        "terminal_id": grant.terminal_id,
        "incarnation": grant.incarnation,
        "token": grant.token,
        "rights": grant.rights.bits(),
        "protocol_version": grant.protocol_version,
        "ttl_ms": ttl_ms,
    }))
}

/// `terminal.renderer_grant.create`. The origin gate already refused a
/// page-origin request; this refuses the caller classes it cannot see.
pub(super) fn create(
    mux: &Mux,
    client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    if let Some(refused) = refusal(mux, client) {
        return Err(ResourceError::new(FORBIDDEN, refused.message, refused.details, false));
    }
    let operation = "terminal.renderer_grant.create";
    let (terminal_id, surface) = resource_terminal_surface(mux, &request.selectors)?;
    let ttl_ms = request.fields.get("ttl_ms").and_then(Value::as_u64).unwrap_or(30_000);
    let grant = surface.mint_renderer_grant(Duration::from_millis(ttl_ms)).map_err(|error| {
        match error.downcast_ref::<RendererGrantFailure>() {
            Some(failure) => ResourceError::new(
                HOST_UNAVAILABLE,
                failure.to_string(),
                json!({"terminal_id":terminal_id,"reason":failure.unavailable().reason()}),
                true,
            ),
            None => ResourceError::operation_failed(operation, format!("{error:#}"), json!({})),
        }
    })?;
    Ok(json!({
        "endpoint":grant.endpoint,
        "terminal_id":terminal_id,
        "token":grant.token,
        "rights":["render"],
        "ttl_ms":u32::try_from(ttl_ms).unwrap_or(u32::MAX),
    }))
}

/// The legacy `error_code` of a refused or unanswered mint.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    if error.downcast_ref::<RendererGrantFailure>().is_some() {
        return Some(LEGACY_HOST_UNAVAILABLE.to_string());
    }
    error.downcast_ref::<MintRefused>().map(|_| FORBIDDEN.to_string())
}

/// The legacy `error_details` of a refused or unanswered mint. An unanswered
/// mint carries `reason` (`timeout` or `disconnected`), as v2 does.
pub(super) fn error_details(error: &anyhow::Error) -> Option<Value> {
    if let Some(failure) = error.downcast_ref::<RendererGrantFailure>() {
        return Some(json!({"reason":failure.unavailable().reason()}));
    }
    error.downcast_ref::<MintRefused>().map(|refused| refused.details.clone())
}
