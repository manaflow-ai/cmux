//! The attach ops. `cloud.machine.connect` is not a focus change (it opens
//! a carrier only). `cloud.rescue.open` asks for focus on the new terminal
//! only for origin `user` or an explicit `focus: true` (OWNERSHIP-PRINCIPLES).

use super::argv::link_command;
use super::channel::{Carrier, CarrierEvent};
use super::dial::DialCode;
use super::supervisor::{LinkFailure, LinkState};
use crate::api::models::MachineStatus;
use crate::api::{CloudError, ControlPlane, Origin, RelayError, Request, args, codes, event_line};
use crate::ops::Server;
use crate::rescue::{MISSING_ROUTE, RESCUE_KIND};
use cmux_terminal_iface::{BackendError, Grid, OpenRequest, OpenToken, TerminalBackend};
use serde_json::{Value, json};

pub const LINK_REVOKED: &str = "cmux.cloud.link_revoked";
pub const LINK_DOWN: &str = "cmux.cloud.link_down";
pub const LINK_UNAVAILABLE: &str = "cmux.cloud.link_unavailable";

/// The server event of a link change (the daemon broadcasts it to apps
/// clients as `cmux.cloud.link.changed`).
pub(crate) const LINK_CHANGED: &str = "cloud.link.changed";

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
        .map(|event| {
            let code = match &event {
                CarrierEvent::Up { .. } => Value::Null,
                CarrierEvent::Down { target, .. } | CarrierEvent::Revoked { target, .. } => {
                    refusal(target)
                }
            };
            event_line(LINK_CHANGED, link_change(event, code))
        })
        .collect()
}

/// The `data` of one `cloud.link.changed` line (`error_code`: the typed
/// `link.dial` refusal that ended the link, or null).
fn link_change(event: CarrierEvent, error_code: Value) -> Value {
    match event {
        CarrierEvent::Up { carrier } => json!({ "machine": carrier.target, "state": "up",
            "carrier": carrier.id, "generation": carrier.generation }),
        CarrierEvent::Down { target, generation, retryable, reason, .. } => json!({
            "machine": target, "state": "down", "generation": generation,
            "retryable": retryable, "reason": reason, "error_code": error_code }),
        CarrierEvent::Revoked { target, reason, .. } => json!({ "machine": target,
            "state": "revoked", "reason": reason, "error_code": error_code }),
    }
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
                server.request_frame_link(&carrier, token);
            }
            // The owner answer of this link: the connect_info read for it
            // (the info cache drops it when the link goes down or is
            // revoked, and on sign-out). A failed read is not the owner.
            let owns = owner_answer(server, &id, &carrier)?;
            Ok(carrier_json(&carrier, owns))
        }
        DISCONNECT => {
            let id = args::id(args::object(raw, &["machine"])?, "machine")?;
            let attach = server.attach_mut();
            attach.supervisor.pump();
            attach.owner_answers.remove(id);
            let existed = attach.supervisor.disconnect(id);
            Ok(json!({ "machine": id, "disconnected": existed }))
        }
        RESCUE_OPEN => rescue_open(server, raw, origin, key, open_token),
        _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    }
}

/// The owner answer of a connect (cmux-platform#89). A cached answer is
/// usable only for the same link generation and authentication epoch, so a
/// connect over an up carrier does not synchronously call Cloud. A sign-out,
/// access loss, or identity change clears the cache and links as needed.
fn owner_answer<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
    carrier: &Carrier,
) -> Result<bool, CloudError> {
    let identity = match server.control_plane_mut().session() {
        Ok(status) if status.signed_in => Some((true, status.team)),
        Ok(_) | Err(RelayError::NotSignedIn) => {
            let error = CloudError::new(codes::AUTH_REQUIRED, "Sign in to cmux Cloud first");
            end_links_after(server, machine, &error);
            return Err(error);
        }
        Err(RelayError::Unavailable(_)) => {
            let attach = server.attach_mut();
            attach.infos.forget(machine);
            attach.owner_answers.remove(machine);
            None
        }
    };
    recheck_carrier(server, machine, carrier)?;
    let Some(identity) = identity else { return Ok(false) };
    server.update_auth_identity(identity.0, identity.1);
    let epoch = server.auth_epoch();
    if let Some((generation, cached_epoch, owns)) =
        server.attach().owner_answers.get(machine).copied()
        && generation == carrier.generation
        && cached_epoch == epoch
    {
        return Ok(owns);
    }
    match super::info::connect_info(server, machine) {
        Ok(info) => {
            recheck_carrier(server, machine, carrier)?;
            let owns = info.caller_owns_vm();
            server
                .attach_mut()
                .owner_answers
                .insert(machine.to_owned(), (carrier.generation, epoch, owns));
            Ok(owns)
        }
        Err(error) if end_links_after(server, machine, &error) => Err(error),
        Err(error) if transient_owner_error(&error) => Ok(false),
        Err(error) => Err(error),
    }
}

/// Apply link events queued during a relay exchange before using its answer.
fn recheck_carrier<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
    carrier: &Carrier,
) -> Result<(), CloudError> {
    let attach = server.attach_mut();
    attach.supervisor.pump();
    if !matches!(attach.supervisor.state(machine), Some(LinkState::Up(current))
        if current.generation == carrier.generation)
    {
        attach.owner_answers.remove(machine);
        attach.infos.forget(machine);
        let failure = attach
            .supervisor
            .outcome(machine, carrier.generation)
            .and_then(Result::err)
            .unwrap_or_else(|| LinkFailure::Down {
                retryable: true,
                reason: "carrier changed during relay exchange".into(),
            });
        return Err(link_failure_for(machine, failure));
    }
    Ok(())
}

fn transient_owner_error(error: &CloudError) -> bool {
    matches!(error.code, codes::RELAY_UNAVAILABLE | codes::PROVIDER_UNAVAILABLE)
}

/// Ends the links a Cloud read's `error` says may not go on: every link on
/// a sign-out, this machine's on not-found or forbidden (refusing new
/// links to it). True when it ended any.
fn end_links_after<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
    error: &CloudError,
) -> bool {
    if error.code == codes::AUTH_REQUIRED {
        // Signed out: no link may outlive the sign-in.
        let attach = server.attach_mut();
        attach.owner_answers.clear();
        attach.supervisor.disconnect_all("signed out of cmux Cloud");
        true
    } else if error.code == codes::NOT_FOUND || error.code == codes::FORBIDDEN {
        // The machine is gone or access ended: refuse new links to it.
        let attach = server.attach_mut();
        attach.owner_answers.remove(machine);
        attach.supervisor.revoke(machine, &error.message);
        true
    } else {
        false
    }
}

fn carrier_json(carrier: &Carrier, owns: bool) -> Value {
    json!({
        "machine": carrier.target,
        "carrier": carrier.id,
        "generation": carrier.generation,
        "state": "up",
        // TODO(fd passing): the supervisor passes a socketpair fd once the app
        // host can; until then the client dials the link's local socket.
        "socket": carrier.socket.to_string_lossy(),
        "vm_kind": if owns { "owner" } else { "team" },
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
        return outcome.map_err(|failure| link_failure_for(machine, failure));
    }
    if attach.park_link_waits {
        // The serve loop never waits for a link: the op is parked and runs
        // again when this generation is up or ended (super::park).
        attach.parked = Some((machine.to_owned(), generation));
        return Err(CloudError::new(super::park::LINK_WAIT, "the link is connecting"));
    }
    attach
        .supervisor
        .wait_connect(machine, generation)
        .map_err(|failure| link_failure_for(machine, failure))
}

/// How a connect started.
pub(crate) enum Begun {
    /// The link was already up.
    Up(Carrier),
    /// A link process of this generation connects; `up` or `down` follows.
    Connecting(u64),
}

/// A link failure as an op error.
pub(crate) fn link_failure_for(machine: &str, failure: LinkFailure) -> CloudError {
    match failure {
        LinkFailure::Revoked(reason) => CloudError::new(
            LINK_REVOKED,
            format!(
                "Cloud machine {machine}'s link was revoked: {reason}; run `cmux cloud diagnostics` and ask the team admin to restore access"
            ),
        ),
        LinkFailure::Down { retryable, reason } => CloudError {
            retryable,
            ..CloudError::new(
                LINK_DOWN,
                format!(
                    "Cloud machine {machine}'s link went down: {reason}; run `cmux cloud diagnostics` and reconnect from the Cloud sidebar"
                ),
            )
        },
        LinkFailure::Spawn(why) => CloudError::new(
            LINK_UNAVAILABLE,
            format!(
                "Cloud machine {machine}'s link process did not start: {why}; run `cmux cloud diagnostics`"
            ),
        ),
        LinkFailure::Dial(code) => dial_error(machine, &code),
    }
}

/// A `link.dial` refusal as an op error (contract 1.7 mapping).
fn dial_error(machine: &str, code: &DialCode) -> CloudError {
    let retryable = |code: &'static str, message: &str| CloudError {
        retryable: true,
        ..CloudError::new(code, message.to_owned())
    };
    match code {
        DialCode::HostPaused => retryable(
            codes::MACHINE_PAUSED,
            &format!(
                "Cloud machine {machine} is still paused after a start; run `cmux cloud resume-machine --target machine:{machine}` and try again"
            ),
        ),
        DialCode::UnknownHost => CloudError::new(
            codes::NOT_FOUND,
            format!("Cloud machine {machine} has no known host; run `cmux cloud list-machines`"),
        ),
        DialCode::NotAuthorized => CloudError::new(
            codes::FORBIDDEN,
            format!(
                "this Mac may not reach Cloud machine {machine}; run `cmux cloud diagnostics` or ask the team admin to change the policy"
            ),
        ),
        DialCode::Unreachable => retryable(
            LINK_DOWN,
            &format!(
                "no network path reached Cloud machine {machine}; run `cmux cloud diagnostics`"
            ),
        ),
        DialCode::BadRequest => CloudError::new(
            LINK_UNAVAILABLE,
            format!(
                "the link to Cloud machine {machine} rejected the dial; run `cmux cloud diagnostics`"
            ),
        ),
        DialCode::Unavailable(why) => retryable(
            LINK_UNAVAILABLE,
            &format!(
                "Cloud machine {machine} link is unavailable: {why}; run `cmux cloud diagnostics`"
            ),
        ),
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
            return Err(link_failure_for(machine, LinkFailure::Revoked(reason.clone())));
        }
        _ => {
            // A down/reconnecting link cannot use the answer from the old
            // generation, even before its event is drained by the loop.
            attach.owner_answers.remove(machine);
        }
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
            return Err(dial_error(machine, &DialCode::HostPaused));
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
            end_links_after(server, machine, &error);
            // A start can fail for plan reasons, and a machine without a host
            // is still provisioning: neither is a revocation.
            return Err(error);
        }
    };
    if !info.has_service("daemon") {
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
    attach
        .supervisor
        .begin(machine, &command)
        .map(Begun::Connecting)
        .map_err(|failure| link_failure_for(machine, failure))
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
        let attach = server.attach_mut();
        attach.infos.forget(machine);
        attach.owner_answers.remove(machine);
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

#[cfg(test)]
mod hint_tests {
    use super::*;

    #[test]
    fn revoked_state_keeps_recovery_context_on_later_connects() {
        struct NoCalls;
        impl ControlPlane for NoCalls {
            fn call(&mut self, _: &crate::WireCall) -> Result<crate::WireReply, RelayError> {
                panic!("a revoked link must not call the backend")
            }
            fn session(&mut self) -> Result<crate::SessionStatus, RelayError> {
                panic!("a revoked link must not request a session")
            }
        }
        let mut server = Server::new(NoCalls);
        server.attach_mut().supervisor.revoke("vm-example", "access removed");
        let error = match begin_connect(&mut server, "vm-example", Origin::User, None) {
            Err(error) => error,
            Ok(_) => panic!("revoked link connected"),
        };
        assert!(error.message.contains("vm-example"));
        assert!(error.message.contains("cmux cloud diagnostics"));
        assert!(error.message.contains("team admin"));
    }

    #[test]
    fn disconnected_links_do_not_suggest_ssh_before_reconnection() {
        for failure in [
            LinkFailure::Revoked("policy".into()),
            LinkFailure::Down { retryable: true, reason: "offline".into() },
            LinkFailure::Spawn("missing binary".into()),
        ] {
            let error = link_failure_for("vm-example", failure);
            assert!(error.message.contains("vm-example"));
            assert!(error.message.contains("cmux cloud diagnostics"));
            assert!(!error.message.contains("cmux cloud ssh"));
        }
    }

    #[test]
    fn dial_failures_name_the_machine_and_an_offered_command() {
        for (code, hint) in [
            (DialCode::HostPaused, "cmux cloud resume-machine --target machine:vm-example"),
            (DialCode::UnknownHost, "cmux cloud list-machines"),
            (DialCode::NotAuthorized, "cmux cloud diagnostics"),
            (DialCode::Unreachable, "cmux cloud diagnostics"),
            (DialCode::BadRequest, "cmux cloud diagnostics"),
            (DialCode::Unavailable("offline".into()), "cmux cloud diagnostics"),
        ] {
            let error = dial_error("vm-example", &code);
            assert!(error.message.contains("vm-example"));
            assert!(error.message.contains(hint), "{}", error.message);
        }
    }
}
