//! The attach ops. `cloud.machine.connect` is not a focus change (it opens
//! a carrier only). `cloud.rescue.open` asks for focus on the new terminal
//! only for origin `user` or an explicit `focus: true` (OWNERSHIP-PRINCIPLES).

use super::argv::{AttachEndpoint, link_command};
use super::supervisor::{LinkFailure, LinkState};
use crate::api::models::MachineStatus;
use crate::api::{CloudError, ControlPlane, Origin, Request, args, codes};
use crate::connector::iface::{BackendError, Carrier};
use crate::ops::Server;
use crate::rescue::iface::{Grid, OpenRequest, TerminalBackend};
use crate::rescue::{MISSING_ROUTE, RESCUE_KIND};
use serde_json::{Value, json};

pub const LINK_REVOKED: &str = "cmux.cloud.link_revoked";
pub const LINK_DOWN: &str = "cmux.cloud.link_down";
pub const LINK_UNAVAILABLE: &str = "cmux.cloud.link_unavailable";
pub const KIND_REFUSED: &str = "cmux.cloud.kind_refused";
pub const TERMINAL_CLOSED: &str = "cmux.cloud.terminal_closed";

pub(crate) const CONNECT: &str = "cloud.machine.connect";
pub(crate) const DISCONNECT: &str = "cloud.machine.disconnect";
pub(crate) const RESCUE_OPEN: &str = "cloud.rescue.open";

pub(crate) fn serves(name: &str) -> bool {
    matches!(name, CONNECT | DISCONNECT | RESCUE_OPEN)
}

pub(crate) fn run<C: ControlPlane>(
    server: &mut Server<C>,
    name: &str,
    raw: &Value,
    origin: Origin,
    key: Option<&str>,
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
        RESCUE_OPEN => rescue_open(server, raw, origin, key),
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

pub(crate) fn backend_error(error: BackendError) -> CloudError {
    match error {
        BackendError::KindRefused { kind } => {
            CloudError::new(KIND_REFUSED, format!("kind {kind} is not served by cmux/cloud"))
        }
        BackendError::Unavailable { reason, retryable } => {
            CloudError { retryable, ..CloudError::new(LINK_DOWN, reason) }
        }
        BackendError::Revoked { reason } => CloudError::new(LINK_REVOKED, reason),
        BackendError::Closed => CloudError::new(TERMINAL_CLOSED, "The terminal is not open"),
        BackendError::Unsupported(why) => CloudError::new(codes::UNSUPPORTED, why),
        BackendError::Invalid(why) => CloudError::invalid(why),
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
    let Some(paths) = attach.paths.clone() else {
        return Err(CloudError::new(
            LINK_UNAVAILABLE,
            "cmux did not give the Cloud app a link binary and network hub",
        ));
    };
    let start_key = match start_key {
        Some(key) => key,
        None => format!("link-attempt-{}/start", attach.next_attempt()),
    };
    let answer = ensure_running(server, machine, origin, &start_key).and_then(|()| {
        server.ctx(CONNECT, None).call(
            "POST",
            format!("/api/vm/{machine}/attach-endpoint"),
            Some(json!({ "transport": "cmux-remote" })),
        )
    });
    let answer = match answer {
        Ok(answer) => answer,
        Err(error) => {
            // The machine is gone or access ended: refuse new links to it.
            if error.code == codes::NOT_FOUND || error.code == codes::FORBIDDEN {
                server.attach_mut().supervisor.revoke(machine, &error.message);
            }
            return Err(error);
        }
    };
    let endpoint = AttachEndpoint::decode(answer)?;
    let command = link_command(&paths, machine, &endpoint);
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
    let start_key = key.map_or_else(
        || format!("rescue-attempt-{}/start", server.attach_mut().next_attempt()),
        |k| format!("{k}/start"),
    );
    ensure_running(server, &machine, origin, &start_key)?;
    let attach = server.attach_mut();
    let terminal = attach.next_terminal_id();
    let grid =
        Grid { cols: u16::try_from(cols).unwrap_or(80), rows: u16::try_from(rows).unwrap_or(24) };
    let opened = attach
        .rescue
        .open(OpenRequest {
            kind: RESCUE_KIND.into(),
            terminal: terminal.clone(),
            target: machine.clone(),
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
