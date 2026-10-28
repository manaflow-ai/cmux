//! The daemon's dispatch decisions for one request, for the cmux-tui/fuzz
//! `dispatch_structured` target (p05-ipc-182). Built only with the `fuzz`
//! feature.
//!
//! [`dispatch`] runs, on one body, the decisions a connection makes before a
//! handler runs, with the functions the connection calls: the REQUEST
//! frame's checks on stream 0 of a fresh connection
//! (`frame_dispatch::checked_request`, `served_on_frames`, `names_method`),
//! the line's head (`RequestHead::parse`), the feature route it names
//! (`routes::find`), and the one typed decode the line reaches: the
//! `cmux.protocol/2` envelope and its catalog params, or the `Command`
//! parse. No handler runs, so no input touches a terminal, a file or the
//! journal; the stateful request fuzzer (p10-stability-176) drives handlers.
//!
//! Chrome fuzzes the same boundary: a Mojo message is validated and routed
//! by its header before any implementation sees it
//! (mojo/public/cpp/bindings/lib/interface_endpoint_client.cc,
//! `HandleValidatedMessage`), and MojoLPM drives that path with structured
//! messages (mojo/public/tools/fuzzers/mojolpm.h).

use cmux_ipc::{CallAux, MethodTables};

use super::frame_dispatch::{checked_request, names_method, served_on_frames};
use super::{Command, Request, RequestHead, routes};

/// What the daemon does with one REQUEST frame and with its body as a line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dispatched {
    /// The frame's route, or the `bad_message` reason that closes the
    /// connection.
    pub frame: Result<Framed, &'static str>,
    /// The body's head, as the line path reads it.
    pub head: Head,
    /// Whether a feature route claims the head's `cmd` before the `Command`
    /// parse (its entry may still hand the line on).
    pub feature_route: bool,
    /// The typed decode the body reaches as a line; `None` when the body is
    /// not UTF-8 (the reader closes such a line before any dispatch).
    pub line: Option<Line>,
}

/// A REQUEST frame that passed every check.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Framed {
    /// A method that answers only lines: the ERROR `method_not_framed`.
    NotFramed,
    /// A `Command` method, by its command table index; its body runs the
    /// line's path.
    Command { method: u16 },
}

/// The routing members `RequestHead` read.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Head {
    pub cmd: Option<String>,
    pub operation: Option<String>,
    pub protocol: bool,
    /// The command table index of `cmd`, when it names a `Command`.
    pub command: Option<u16>,
}

/// The typed decode a line reaches.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Line {
    /// A `cmux.protocol/2` line: its envelope's operation when the envelope
    /// parses, and whether its catalog params validate.
    Resource { operation: Option<&'static str>, accepted: bool },
    /// The `Command` parse accepted it: the command's table index.
    Command { method: u16 },
    /// The `Command` parse refused it (a `bad_request` reply).
    Refused,
}

/// The dispatch decisions for `payload` sent as a REQUEST frame with `call`
/// on stream 0, and as a line.
pub fn dispatch(call: CallAux, payload: &[u8]) -> Dispatched {
    let tables = MethodTables::schema();
    let frame = checked_request(tables, call, payload).map_err(|bad| bad.reason()).and_then(
        |(method, body)| {
            if !served_on_frames(tables, method) {
                return Ok(Framed::NotFramed);
            }
            names_method(body, method).map_err(|refusal| refusal.reason())?;
            Command::method_of_wire(method.name)
                .map(|(method, _)| Framed::Command { method })
                .ok_or("served_without_command")
        },
    );
    let Ok(text) = std::str::from_utf8(payload) else {
        return Dispatched { frame, head: Head::default(), feature_route: false, line: None };
    };
    let head = RequestHead::parse(text);
    let view = Head {
        cmd: head.cmd().map(str::to_owned),
        operation: head.operation().map(str::to_owned),
        protocol: head.is_resource(),
        command: head.cmd().and_then(Command::method_of_wire).map(|(method, _)| method),
    };
    let feature_route = head.cmd().and_then(routes::find).is_some();
    Dispatched { frame, head: view, feature_route, line: Some(line(text, &head)) }
}

/// `connection_frame::dispatch_line`'s decode: a line with `protocol` that
/// the resource router takes, else the `Command` parse.
fn line(text: &str, head: &RequestHead<'_>) -> Line {
    if head.is_resource()
        && let Some(parsed) = crate::resource_router::parse_resource_line(text)
    {
        let Ok(envelope) = parsed else {
            return Line::Resource { operation: None, accepted: false };
        };
        let operation = envelope.operation.wire_name();
        let accepted = crate::resource_router::validate_resource_envelope(
            envelope,
            crate::workspace_registry::Actor::local_user(),
        )
        .is_ok();
        return Line::Resource { operation: Some(operation), accepted };
    }
    match crate::line_parses::parse::<Request>(text) {
        Ok(request) => Line::Command { method: request.cmd.method_id() },
        Err(_) => Line::Refused,
    }
}

#[cfg(test)]
#[path = "fuzz_dispatch_tests.rs"]
mod tests;
