use cmux_remote_protocol::{RelayPermission, RelayRole, RelayTicketClaims};
use worker::{Date, Env, Method, Request, Response, Result};

use crate::auth::{DEFAULT_TICKET_ISSUER, MAX_TICKET_BYTES, verify_ticket_claims};
use crate::placement::{REGION_HEADER, hint_of, is_region};
use crate::wire::{valid_circuit_id, valid_opaque_identifier, websocket_upgrade};

const MAX_SLOT_ID_BYTES: usize = 128;

/// The commit this Worker was built from, set at deploy with
/// `wrangler deploy --var CMUX_SOURCE_REVISION:<sha>` (.github/workflows/cloudflare-relay.yml).
/// A deploy that does not set it answers `unknown`.
const SOURCE_REVISION_VAR: &str = "CMUX_SOURCE_REVISION";

#[derive(Debug, Clone, Copy)]
enum AdmissionRoute<'a> {
    DaemonControl { slot: &'a str },
    ClientControl { slot: &'a str },
    Circuit { circuit: &'a str },
}

pub(crate) async fn route(request: Request, env: Env) -> Result<Response> {
    let path = request.path();
    if path == "/healthz" {
        return Response::ok("ok");
    }
    if path == "/version" {
        let revision = env.var(SOURCE_REVISION_VAR).map(|value| value.to_string()).ok();
        return Response::from_json(&version_body(revision.as_deref()));
    }
    if request.method() != Method::Get {
        return Response::error("Method not allowed", 405);
    }
    if !websocket_upgrade(&request)? {
        return Response::error("WebSocket upgrade required", 426);
    }

    let segments: Vec<_> = path.split('/').filter(|part| !part.is_empty()).collect();
    let admission = match segments.as_slice() {
        ["v1", "slots", slot, "control"] if valid_opaque_identifier(slot, MAX_SLOT_ID_BYTES) => {
            AdmissionRoute::DaemonControl { slot }
        }
        ["v1", "slots", slot, "connect"] if valid_opaque_identifier(slot, MAX_SLOT_ID_BYTES) => {
            AdmissionRoute::ClientControl { slot }
        }
        ["v1", "circuits", circuit] if valid_circuit_id(circuit) => {
            AdmissionRoute::Circuit { circuit }
        }
        _ => return Response::error("Not found", 404),
    };

    let Some(claims) = authorized_at_edge(&request, &env, admission)? else {
        return Response::error("Unauthorized", 401);
    };

    match admission {
        AdmissionRoute::DaemonControl { slot } | AdmissionRoute::ClientControl { slot } => {
            // The caller's place (the viewer's on a connect, the daemon's on a control socket) goes to the
            // slot beside the request, never from the caller: what it sent is dropped.
            // The runtime's request is immutable (`headers_mut` on it is an error, a 500 on every Register and
            // Connect: cmux#54175 on staging 11-25 22:06Z); the slot gets a mutable copy.
            let caller = hint_of(&request);
            let mut request = request.clone_mut()?;
            let headers = request.headers_mut()?;
            headers.delete(REGION_HEADER)?;
            if let Some(region) = caller {
                headers.set(REGION_HEADER, region)?;
            }
            let namespace = env.durable_object("RELAY_SLOTS")?;
            let id = namespace.id_from_name(slot)?;
            // A slot the daemon creates is placed near the daemon (`crate::placement`).
            let stub = match (admission, caller) {
                (AdmissionRoute::DaemonControl { .. }, Some(hint)) => {
                    id.get_stub_with_location_hint(hint)?
                }
                _ => id.get_stub()?,
            };
            stub.fetch_with_request(request).await
        }
        AdmissionRoute::Circuit { circuit } => {
            let namespace = env.durable_object("RELAY_CIRCUITS")?;
            let id = namespace.id_from_string(circuit)?;
            // The first end to join creates the object, near the viewer when the ticket names a region.
            // The hint is ignored once the object exists.
            let stub = match claims.region.as_deref().filter(|region| is_region(region)) {
                Some(region) => id.get_stub_with_location_hint(region)?,
                None => id.get_stub()?,
            };
            stub.fetch_with_request(request).await
        }
    }
}

/// GET /version: what the deploy healthcheck compares with the commit it shipped.
fn version_body(revision: Option<&str>) -> serde_json::Value {
    let revision = revision.filter(|value| is_commit_sha(value)).unwrap_or("unknown");
    serde_json::json!({ "service": "cmux-remote-relay", "source_revision": revision })
}

fn is_commit_sha(value: &str) -> bool {
    value.len() == 40 && value.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

fn authorized_at_edge(
    request: &Request,
    env: &Env,
    route: AdmissionRoute<'_>,
) -> Result<Option<RelayTicketClaims>> {
    let Some(ticket) = bearer_ticket(request)? else {
        return Ok(None);
    };
    let key = env.secret("CMUX_RELAY_TICKET_KEY")?.to_string();
    let issuer = env
        .var("CMUX_RELAY_TICKET_ISSUER")
        .map(|value| value.to_string())
        .unwrap_or_else(|_| DEFAULT_TICKET_ISSUER.into());
    let now = Date::now().as_millis() / 1_000;
    let Ok(claims) = verify_ticket_claims(&ticket, key.as_bytes(), &issuer, now) else {
        return Ok(None);
    };
    Ok(claims_authorize_route(&claims, route).then_some(claims))
}

fn bearer_ticket(request: &Request) -> Result<Option<String>> {
    let Some(value) = request.headers().get("Authorization")? else {
        return Ok(None);
    };
    let Some((scheme, ticket)) = value.split_once(' ') else {
        return Ok(None);
    };
    if !scheme.eq_ignore_ascii_case("bearer")
        || ticket.is_empty()
        || ticket.len() > MAX_TICKET_BYTES
        || ticket.contains(char::is_whitespace)
    {
        return Ok(None);
    }
    Ok(Some(ticket.into()))
}

fn claims_authorize_route(claims: &RelayTicketClaims, route: AdmissionRoute<'_>) -> bool {
    match route {
        AdmissionRoute::DaemonControl { slot } => {
            claims.permission == RelayPermission::Register
                && claims.role == RelayRole::Daemon
                && claims.slot == slot
        }
        AdmissionRoute::ClientControl { slot } => {
            claims.permission == RelayPermission::Connect
                && claims.role == RelayRole::Client
                && claims.slot == slot
        }
        AdmissionRoute::Circuit { circuit } => {
            claims.permission == RelayPermission::Join
                && claims.circuit.as_ref().is_some_and(|claimed| claimed.0 == circuit)
        }
    }
}

#[cfg(test)]
#[path = "routing_tests.rs"]
mod tests;
