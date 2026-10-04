//! The attach ops. `cloud.machine.connect` is not a focus change (it opens
//! a carrier only). `cloud.rescue.open` asks for focus on the new terminal
//! only for origin `user` or an explicit `focus: true` (OWNERSHIP-PRINCIPLES).

use super::argv::{AttachEndpoint, link_command};
use super::supervisor::{LinkFailure, LinkState};
use crate::api::models::MachineStatus;
use crate::api::{CloudError, ControlPlane, Origin, Request, args, codes};
use crate::connector::iface::{Carrier, CarrierEvent};
use crate::ops::Server;
use crate::rescue::iface::{BackendError, Grid, OpenRequest, OpenToken, TerminalBackend};
use crate::rescue::{MISSING_ROUTE, RESCUE_KIND};
use serde_json::{Value, json};

pub const LINK_REVOKED: &str = "cmux.cloud.link_revoked";
pub const LINK_DOWN: &str = "cmux.cloud.link_down";
pub const LINK_UNAVAILABLE: &str = "cmux.cloud.link_unavailable";

pub(crate) const CONNECT: &str = "cloud.machine.connect";
pub(crate) const DISCONNECT: &str = "cloud.machine.disconnect";
pub(crate) const RESCUE_OPEN: &str = "cloud.rescue.open";

/// `cloud.link.changed` lines for the host: carrier events since the last
/// call, in order. The serve loop takes them after each op and whenever a
/// link process event wakes it (`LinkSupervisor::set_wake`).
pub(crate) fn take_event_lines<C: ControlPlane>(server: &mut Server<C>) -> Vec<Value> {
    server
        .attach_mut()
        .take_host_link_events()
        .into_iter()
        .map(|event| match event {
            CarrierEvent::Up { carrier } => json!({ "type": "event", "event": "cloud.link.changed",
                "machine": carrier.target, "state": "up", "carrier": carrier.id,
                "generation": carrier.generation }),
            CarrierEvent::Down { target, generation, retryable, reason, .. } => json!({
                "type": "event", "event": "cloud.link.changed", "machine": target,
                "state": "down", "generation": generation, "retryable": retryable,
                "reason": reason }),
            CarrierEvent::Revoked { target, reason, .. } => json!({ "type": "event",
                "event": "cloud.link.changed", "machine": target, "state": "revoked",
                "reason": reason }),
        })
        .collect()
}

/// Ops whose answer is live link state and must never be replayed.
pub(crate) fn live_state_op(name: &str) -> bool {
    matches!(name, CONNECT | DISCONNECT)
}

pub(crate) fn serves(name: &str) -> bool {
    matches!(name, CONNECT | DISCONNECT | RESCUE_OPEN)
}

pub(crate) fn run<C: ControlPlane>(
    server: &mut Server<C>,
    name: &str,
    raw: &Value,
    origin: Origin,
    key: Option<&str>,
    open_token: Option<&OpenToken>,
) -> Result<Value, CloudError> {
    match name {
        CONNECT => {
            let id = args::id(args::object(raw, &["machine"])?, "machine")?.to_owned();
            let start_key = key.map(|k| format!("{k}/start"));
            let carrier = connect(server, &id, origin, start_key)?;
            Ok(carrier_json(&carrier))
        }
        DISCONNECT => {
            let id = args::id(args::object(raw, &["machine"])?, "machine")?;
            let attach = server.attach_mut();
            attach.supervisor.pump();
            let existed = attach.supervisor.disconnect(id);
            Ok(json!({ "machine": id, "disconnected": existed }))
        }
        RESCUE_OPEN => rescue_open(server, raw, origin, key, open_token),
        _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    }
}

fn carrier_json(carrier: &Carrier) -> Value {
    json!({
        "machine": carrier.target,
        "carrier": carrier.id,
        "generation": carrier.generation,
        "state": "up",
        // TODO(fd passing): the supervisor passes a socketpair fd once the app
        // host can; until then the client dials the link's local socket.
        "socket": carrier.socket.to_string_lossy(),
    })
}

/// A typed rescue backend error (`cmux.terminal.backend/1` `errors`) as an
/// op error.
pub(crate) fn backend_error(error: BackendError) -> CloudError {
    match error {
        BackendError::Unsupported => {
            CloudError::new(codes::UNSUPPORTED, "The rescue shell cannot do this")
        }
        BackendError::Unavailable { reason, retryable } => {
            CloudError { retryable, ..CloudError::new(LINK_DOWN, reason) }
        }
        BackendError::HostKey { .. } | BackendError::Denied { .. } => {
            CloudError::new(codes::FORBIDDEN, error.to_string())
        }
        BackendError::Invalid { reason } => CloudError::invalid(reason),
    }
}

/// Opens (or returns) the one carrier of `machine`. A paused machine is
/// started first through `cloud.machine.start` (with `start_key`).
pub(crate) fn connect<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
    origin: Origin,
    start_key: Option<String>,
) -> Result<Carrier, CloudError> {
    // The interface path has no catalog arg check: check the id here, before
    // it enters a path or argv.
    args::id(&serde_json::Map::from_iter([("machine".to_owned(), json!(machine))]), "machine")?;
    let attach = server.attach_mut();
    attach.supervisor.pump();
    match attach.supervisor.state(machine) {
        Some(LinkState::Up(carrier)) => return Ok(carrier.clone()),
        Some(LinkState::Revoked { reason }) => {
            return Err(CloudError::new(LINK_REVOKED, reason.clone()));
        }
        _ => {}
    }
    let paths = server.link_paths()?;
    let attach = server.attach_mut();
    let child_env = attach.env.child_env().map_err(|e| {
        CloudError::new(LINK_UNAVAILABLE, format!("no private home for the link: {e}"))
    })?;
    let start_key = match start_key {
        Some(key) => key,
        None => format!("link-{}/start", attach.attempt_nonce()),
    };
    let answer = match ensure_running(server, machine, origin, &start_key) {
        // A start can fail for plan reasons (403): that is not a revocation.
        Err(error) => Err((error, false)),
        Ok(()) => server
            .ctx(CONNECT, None)
            .call(
                "POST",
                format!("/api/vm/{machine}/attach-endpoint"),
                Some(json!({ "transport": "cmux-remote" })),
            )
            .map_err(|e| (e, true)),
    };
    let answer = match answer {
        Ok(answer) => answer,
        Err((error, from_attach)) => {
            let supervisor = &mut server.attach_mut().supervisor;
            if error.code == codes::AUTH_REQUIRED {
                // Signed out: no link may outlive the sign-in.
                supervisor.disconnect_all("signed out of cmux Cloud");
            } else if error.code == codes::NOT_FOUND
                || (from_attach && error.code == codes::FORBIDDEN)
            {
                // The machine is gone or access ended: refuse new links to it.
                supervisor.revoke(machine, &error.message);
            }
            return Err(error);
        }
    };
    let endpoint = AttachEndpoint::decode(answer)?;
    let command = link_command(&paths, machine, &endpoint, &child_env);
    server.attach_mut().endpoints.insert(machine.to_owned(), endpoint);
    server.attach_mut().supervisor.spawn_and_wait(machine, &command).map_err(|f| match f {
        LinkFailure::Revoked(reason) => CloudError::new(LINK_REVOKED, reason),
        LinkFailure::Down { retryable, reason } => {
            CloudError { retryable, ..CloudError::new(LINK_DOWN, reason) }
        }
        LinkFailure::Spawn(why) => {
            CloudError::new(LINK_UNAVAILABLE, format!("the link process did not start: {why}"))
        }
    })
}

/// Reads the machine when the projection does not know it, and starts it
/// when it is paused.
fn ensure_running<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
    origin: Origin,
    start_key: &str,
) -> Result<(), CloudError> {
    if server.projection().get(machine).is_none() {
        server.handle(&Request::new("cloud.machine.get", json!({ "machine": machine })))?;
    }
    let paused =
        server.projection().get(machine).is_some_and(|m| m.status == MachineStatus::Paused);
    if paused {
        let start = Request::new("cloud.machine.start", json!({ "machine": machine }))
            .origin(origin)
            .key(start_key);
        server.handle(&start)?;
    }
    Ok(())
}

fn rescue_open<C: ControlPlane>(
    server: &mut Server<C>,
    raw: &Value,
    origin: Origin,
    key: Option<&str>,
    open_token: Option<&OpenToken>,
) -> Result<Value, CloudError> {
    let map = args::object(raw, &["machine", "cols", "rows", "focus"])?;
    let machine = args::id(map, "machine")?.to_owned();
    let cols = args::int(map, "cols", 1, 1000, 1)?.unwrap_or(80);
    let rows = args::int(map, "rows", 1, 1000, 1)?.unwrap_or(24);
    let focus = match map.get("focus") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(_) => return Err(CloudError::invalid("focus must be true or false")),
    };
    // The route gap is known before any Cloud API call: answer it at once,
    // without starting a paused machine for nothing.
    if !server.attach_mut().rescue_route_available() {
        return Err(CloudError::new(codes::UNSUPPORTED, MISSING_ROUTE));
    }
    // The host stamps its open token on the op line after the user's
    // gesture; without one nothing starts and nothing opens.
    let open_token = open_token.cloned().unwrap_or_else(|| OpenToken(String::new()));
    open_token.check().map_err(backend_error)?;
    let start_key = key.map_or_else(
        || format!("rescue-{}/start", server.attach_mut().attempt_nonce()),
        |k| format!("{k}/start"),
    );
    ensure_running(server, &machine, origin, &start_key)?;
    let attach = server.attach_mut();
    let terminal = attach.next_terminal_id();
    let grid = Grid::new(u16::try_from(cols).unwrap_or(80), u16::try_from(rows).unwrap_or(24));
    let opened = attach
        .rescue
        .open(OpenRequest {
            kind: RESCUE_KIND.into(),
            terminal: terminal.clone(),
            target: machine.clone(),
            open_token,
            command: None,
            cwd: None,
            env: Vec::new(),
            grid,
            actor: None,
        })
        .map_err(backend_error)?;
    attach.rescue_terminals.insert(terminal.clone(), opened);
    Ok(json!({
        "terminal": terminal,
        "machine": machine,
        "backend": attach.rescue.id().as_str(),
        "kind": RESCUE_KIND,
        "focus": origin == Origin::User || focus,
    }))
}
