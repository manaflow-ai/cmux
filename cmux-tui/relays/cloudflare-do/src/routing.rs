use cmux_remote_protocol::{RelayPermission, RelayRole, RelayTicketClaims};
use worker::{Date, Env, Method, Request, Response, Result};

use crate::auth::{DEFAULT_TICKET_ISSUER, MAX_TICKET_BYTES, verify_ticket_claims};
use crate::wire::{valid_circuit_id, valid_opaque_identifier, websocket_upgrade};

const MAX_SLOT_ID_BYTES: usize = 128;

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

    if !authorized_at_edge(&request, &env, admission)? {
        return Response::error("Unauthorized", 401);
    }

    match admission {
        AdmissionRoute::DaemonControl { slot } | AdmissionRoute::ClientControl { slot } => {
            let namespace = env.durable_object("RELAY_SLOTS")?;
            let stub = namespace.id_from_name(slot)?.get_stub()?;
            stub.fetch_with_request(request).await
        }
        AdmissionRoute::Circuit { circuit } => {
            let namespace = env.durable_object("RELAY_CIRCUITS")?;
            let stub = namespace.id_from_string(circuit)?.get_stub()?;
            stub.fetch_with_request(request).await
        }
    }
}

fn authorized_at_edge(request: &Request, env: &Env, route: AdmissionRoute<'_>) -> Result<bool> {
    let Some(ticket) = bearer_ticket(request)? else {
        return Ok(false);
    };
    let key = env.secret("CMUX_RELAY_TICKET_KEY")?.to_string();
    let issuer = env
        .var("CMUX_RELAY_TICKET_ISSUER")
        .map(|value| value.to_string())
        .unwrap_or_else(|_| DEFAULT_TICKET_ISSUER.into());
    let now = Date::now().as_millis() / 1_000;
    let Ok(claims) = verify_ticket_claims(&ticket, key.as_bytes(), &issuer, now) else {
        return Ok(false);
    };
    Ok(claims_authorize_route(&claims, route))
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
mod tests {
    use cmux_remote_protocol::{CircuitId, LaneToken};

    use super::*;

    fn claims(permission: RelayPermission, role: RelayRole) -> RelayTicketClaims {
        RelayTicketClaims {
            version: RelayTicketClaims::VERSION,
            issuer: "issuer".into(),
            permission,
            role,
            slot: "slot-a".into(),
            circuit: None,
            lane: None,
            generation: None,
            expires_at_unix: 100,
        }
    }

    #[test]
    fn provider_tickets_cannot_materialize_other_slot_objects() {
        let register = claims(RelayPermission::Register, RelayRole::Daemon);
        assert!(claims_authorize_route(
            &register,
            AdmissionRoute::DaemonControl { slot: "slot-a" },
        ));
        assert!(!claims_authorize_route(
            &register,
            AdmissionRoute::DaemonControl { slot: "slot-b" },
        ));
        assert!(!claims_authorize_route(
            &register,
            AdmissionRoute::ClientControl { slot: "slot-a" },
        ));
    }

    #[test]
    fn join_ticket_only_materializes_its_bound_circuit_object() {
        let mut join = claims(RelayPermission::Join, RelayRole::Client);
        join.circuit = Some(CircuitId("ab".repeat(32)));
        join.lane = Some(LaneToken("lane".into()));
        join.generation = Some(3);
        assert!(claims_authorize_route(
            &join,
            AdmissionRoute::Circuit { circuit: &"ab".repeat(32) },
        ));
        assert!(!claims_authorize_route(
            &join,
            AdmissionRoute::Circuit { circuit: &"cd".repeat(32) },
        ));
    }
}
