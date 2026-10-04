//! The attach ops. `cloud.machine.connect` is not a focus change (it opens
//! a carrier only). `cloud.rescue.open` asks for focus on the new terminal
//! only for origin `user` or an explicit `focus: true` (OWNERSHIP-PRINCIPLES).

use super::argv::link_command;
use super::channel::{Carrier, CarrierEvent};
use super::dial::DialCode;
use super::supervisor::{LinkFailure, LinkState};
use crate::api::models::MachineStatus;
use crate::api::{CloudError, ControlPlane, Origin, Request, args, codes};
use crate::ops::Server;
use crate::rescue::{MISSING_ROUTE, RESCUE_KIND};
use cmux_terminal_iface::{BackendError, Grid, OpenRequest, OpenToken, TerminalBackend};
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
    let attach = server.attach_mut();
    let events = attach.take_host_link_events();
    // The typed `link.dial` refusal that ended a link, when one did
    // (`host_paused`: connect again, which starts the machine).
    let refusal = |machine: &str| {
        attach.supervisor.refusal(machine).map_or(Value::Null, |code| json!(code.as_str()))
    };
    events
        .into_iter()
        .map(|event| match event {
            CarrierEvent::Up { carrier } => json!({ "type": "event", "event": "cloud.link.changed",
                "machine": carrier.target, "state": "up", "carrier": carrier.id,
                "generation": carrier.generation }),
            CarrierEvent::Down { target, generation, retryable, reason, .. } => json!({
                "type": "event", "event": "cloud.link.changed", "machine": target,
                "state": "down", "generation": generation, "retryable": retryable,
                "reason": reason, "error_code": refusal(&target) }),
            CarrierEvent::Revoked { target, reason, .. } => json!({ "type": "event",
                "event": "cloud.link.changed", "machine": target, "state": "revoked",
                "reason": reason, "error_code": refusal(&target) }),
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
            // One start key per attempt: a start key reused across attempts
            // would replay an old start and never start a machine that
            // paused again (v2 review P3).
            let nonce = server.attach_mut().attempt_nonce();
            let start_key = key.map(|k| format!("{k}/start/{nonce}"));
            let carrier = connect(server, &id, origin, start_key)?;
            // The host's open token (a user run of an `openOps` op): the
            // link's bytes also get a frame link on the host channel.
            if let Some(token) = open_token {
                server.request_frame_link(&id, token);
            }
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

/// Opens (or returns) the one carrier of `machine` and waits for it. A
/// paused machine is started first through `cloud.machine.start` (with
/// `start_key`). In the serve loop (`park_link_waits`) it never waits: the
/// op that called it is parked until the link is up or ended.
pub(crate) fn connect<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
    origin: Origin,
    start_key: Option<String>,
) -> Result<Carrier, CloudError> {
    let generation = match begin_connect(server, machine, origin, start_key)? {
        Begun::Up(carrier) => return Ok(carrier),
        Begun::Connecting(generation) => generation,
    };
    let attach = server.attach_mut();
    attach.supervisor.pump();
    if let Some(outcome) = attach.supervisor.outcome(machine, generation) {
        return outcome.map_err(link_failure);
    }
    if attach.park_link_waits {
        // The serve loop never waits for a link: the op is parked and runs
        // again when this generation is up or ended (super::park).
        attach.parked = Some((machine.to_owned(), generation));
        return Err(CloudError::new(super::park::LINK_WAIT, "the link is connecting"));
    }
    attach.supervisor.wait_connect(machine, generation).map_err(link_failure)
}

/// How a connect started.
pub(crate) enum Begun {
    /// The link was already up.
    Up(Carrier),
    /// A link process of this generation connects; `up` or `down` follows.
    Connecting(u64),
}

/// A link failure as an op error.
pub(crate) fn link_failure(failure: LinkFailure) -> CloudError {
    match failure {
        LinkFailure::Revoked(reason) => CloudError::new(LINK_REVOKED, reason),
        LinkFailure::Down { retryable, reason } => {
            CloudError { retryable, ..CloudError::new(LINK_DOWN, reason) }
        }
        LinkFailure::Spawn(why) => {
            CloudError::new(LINK_UNAVAILABLE, format!("the link process did not start: {why}"))
        }
        LinkFailure::Dial(code) => dial_error(&code),
    }
}

/// A `link.dial` refusal as an op error (contract 1.7 mapping).
fn dial_error(code: &DialCode) -> CloudError {
    let retryable = |code: &'static str, message: &str| CloudError {
        retryable: true,
        ..CloudError::new(code, message.to_owned())
    };
    match code {
        DialCode::HostPaused => retryable(
            codes::MACHINE_PAUSED,
            "The machine is still paused after a start: try again when it runs",
        ),
        DialCode::UnknownHost => {
            CloudError::new(codes::NOT_FOUND, "cmux Cloud does not know this machine's host")
        }
        DialCode::NotAuthorized => {
            CloudError::new(codes::FORBIDDEN, "This Mac may not reach this machine")
        }
        DialCode::Unreachable => retryable(LINK_DOWN, "No network path reached the machine"),
        DialCode::BadRequest => {
            CloudError::new(LINK_UNAVAILABLE, "cmux link did not understand the dial")
        }
        DialCode::Unavailable(why) => retryable(LINK_UNAVAILABLE, why),
    }
}

/// Everything of a connect up to the link process start, without waiting
/// for its ready line: the up carrier, the generation that connects now,
/// or a typed error. Only the loop thread calls it.
pub(crate) fn begin_connect<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
    origin: Origin,
    start_key: Option<String>,
) -> Result<Begun, CloudError> {
    // The interface path has no catalog arg check: check the id here, before
    // it enters a path or argv.
    args::id(&serde_json::Map::from_iter([("machine".to_owned(), json!(machine))]), "machine")?;
    let attach = server.attach_mut();
    attach.supervisor.pump();
    match attach.supervisor.state(machine) {
        Some(LinkState::Up(carrier)) => {
            let carrier = carrier.clone();
            attach.paused_restarts.remove(machine);
            return Ok(Begun::Up(carrier));
        }
        Some(LinkState::Revoked { reason }) => {
            return Err(CloudError::new(LINK_REVOKED, reason.clone()));
        }
        _ => {}
    }
    // A link that already connects (another connect, a respawn): follow it.
    if let Some(generation) = attach.supervisor.connecting(machine) {
        return Ok(Begun::Connecting(generation));
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
    // The last stream found the machine paused: this connect starts it
    // once, whatever the projection says. If the next stream finds it
    // paused again, the connect after that answers machine_paused once
    // (no loop), and the one after it may start again.
    let restart = match attach.supervisor.refusal(machine) {
        Some(DialCode::HostPaused) if attach.paused_restarts.remove(machine) => {
            return Err(dial_error(&DialCode::HostPaused));
        }
        Some(DialCode::HostPaused) => {
            attach.paused_restarts.insert(machine.to_owned());
            true
        }
        _ => false,
    };
    let key = if restart { format!("{start_key}/restart") } else { start_key };
    // The readiness check is a read (connect_info), never a dial: a dial
    // mints a link token, and each mint is one real connection.
    let info = ensure_running(server, machine, origin, &key, restart)
        .and_then(|()| super::info::connect_info(server, machine))
        .and_then(|info| match info.state {
            MachineStatus::Running => Ok(info),
            state => {
                if state == MachineStatus::Paused {
                    // The record was older than the machine: start it now.
                    ensure_running(server, machine, origin, &format!("{key}/info"), true)?;
                }
                // Contract 1.7: wait for the `running` upsert, then dial. The
                // client connects again on that upsert; nothing waits here.
                Err(CloudError {
                    retryable: true,
                    ..CloudError::new(
                        LINK_DOWN,
                        "The machine is starting: connect again when it runs",
                    )
                })
            }
        });
    let info = match info {
        Ok(info) => info,
        Err(error) => {
            // A failed or unfinished start leaves the next connect free to
            // start again.
            server.attach_mut().paused_restarts.remove(machine);
            if error.code == codes::AUTH_REQUIRED {
                // Signed out: no link may outlive the sign-in.
                server.attach_mut().supervisor.disconnect_all("signed out of cmux Cloud");
            } else if error.code == codes::NOT_FOUND || error.code == codes::FORBIDDEN {
                // The machine is gone or access ended: refuse new links to it.
                server.attach_mut().supervisor.revoke(machine, &error.message);
            }
            // A start can fail for plan reasons, and a machine without a host
            // is still provisioning: neither is a revocation.
            return Err(error);
        }
    };
    if !info.services.iter().any(|s| s == "daemon") {
        return Err(CloudError::new(
            codes::FORBIDDEN,
            "This Mac may not reach the machine's cmux daemon (team policy)",
        ));
    }
    let host = info.host;
    let command = link_command(&paths, machine, &host, &child_env);
    let attach = server.attach_mut();
    attach.hosts.insert(machine.to_owned(), host);
    // The calls above may have taken a while: a link that came up or
    // started meanwhile is used, not replaced.
    attach.supervisor.pump();
    if let Some(carrier) = attach.supervisor.carrier(machine) {
        return Ok(Begun::Up(carrier.clone()));
    }
    if let Some(generation) = attach.supervisor.connecting(machine) {
        return Ok(Begun::Connecting(generation));
    }
    attach.supervisor.begin(machine, &command).map(Begun::Connecting).map_err(link_failure)
}

/// Reads the machine when the projection does not know it, and starts it
/// when it is paused.
fn ensure_running<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
    origin: Origin,
    start_key: &str,
    force_start: bool,
) -> Result<(), CloudError> {
    if server.projection().get(machine).is_none() {
        server.handle(&Request::new("cloud.machine.get", json!({ "machine": machine })))?;
    }
    let paused = force_start
        || server.projection().get(machine).is_some_and(|m| m.status == MachineStatus::Paused);
    if paused {
        let start = Request::new("cloud.machine.start", json!({ "machine": machine }))
            .origin(origin)
            .key(start_key);
        server.handle(&start)?;
        // The machine's state changed: read its link facts again.
        server.attach_mut().infos.forget(machine);
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
    ensure_running(server, &machine, origin, &start_key, false)?;
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
