//! `tailnet.*` (capability `tailnet-v1`): this install as its own device on
//! the user's tailnet (plans/cmux-next/remote-desktop-v2.md, sections 1 and 4).
//!
//! The daemon owns ONE embedded Tailscale node per install
//! (`cmux_tailnet::Node`): state in `<daemon state dir>/tailnet` (0700),
//! device name `cmux-<computer name>`. The operations:
//! - `tailnet.login.start`: starts the node when it does not run and answers
//!   its state; in NeedsLogin also the sign-in link (`browse_to_url`), the
//!   onboarding "Sign in to Tailscale" button.
//! - `tailnet.state`: a stream of the node's state, one item per change on
//!   the node's IPN bus (no polling). Opening it starts a node that already
//!   has a saved login, so a signed-in Mac is back on its tailnet after a
//!   restart without a click.
//! - `tailnet.forward {target}`: a local listener (a 0600 Unix socket in a
//!   private folder, or with `transport: "tcp"` a 127.0.0.1 port) that
//!   forwards each connection over the tailnet to `target`. The viewer's
//!   signaling and TURN go through it. It lives as long as the connection
//!   that opened it.
//! - `tailnet.logout`: the device leaves the user's tailnet.
//!
//! Who may call them (skills/cmux-socket-policy/references/
//! remote-relay-authorization.md): only the frontend actor, the verified
//! cmux app on a local Unix connection of this machine. Default deny: an
//! agent, a terminal process, the CLI, a page, a link peer, a WebSocket or
//! relayed connection is refused with `origin.forbidden` before anything
//! starts. The sign-in link is a credential until someone uses it (whoever
//! opens it first owns the device), so it goes only to that actor and never
//! to a log. No parameter carries a command.
//!
//! Built without the `tailnet` cargo feature (the default: libtailscale
//! needs Go), every operation answers `operation.failed` reason `not_built`
//! after the same actor check, and the capability is not advertised.

use std::sync::Arc;

use serde_json::{Value, json};

use super::{MessageWriter, Mux, ResourceError, ResourceOperation, send_resource_response};
use crate::Actor;
use crate::resource_router::ParsedResourceRequest;

#[cfg(all(unix, feature = "tailnet"))]
mod forward;
#[cfg(all(unix, feature = "tailnet"))]
mod owner;
#[cfg(all(unix, feature = "tailnet"))]
mod stream;

/// Advertised in identify only by a daemon built with the `tailnet` feature.
pub(super) const CAPABILITY: &str = "tailnet-v1";

/// Whether this build serves `tailnet.*` (else they answer `not_built`).
pub(super) const fn built() -> bool {
    cfg!(all(unix, feature = "tailnet"))
}

pub(super) const fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::TailnetLoginStart
            | ResourceOperation::TailnetLogout
            | ResourceOperation::TailnetForward
            | ResourceOperation::TailnetState
    )
}

/// Checks the frontend actor on this thread, then answers. Work that waits
/// on the node (sign-in link, logout, the state stream) runs on its own
/// thread and answers through `writer`.
pub(super) fn handle(
    mux: &Arc<Mux>,
    client: u64,
    request: ParsedResourceRequest,
    writer: &MessageWriter,
) -> bool {
    let id = request.envelope.id.clone();
    let operation = request.envelope.operation;
    if let Err(error) = require_frontend(mux, client, &request.actor) {
        return send_resource_response(writer, id, operation, Err(error));
    }
    #[cfg(all(unix, feature = "tailnet"))]
    {
        match operation {
            ResourceOperation::TailnetState => stream::open(mux, client, request, writer),
            ResourceOperation::TailnetForward => {
                let result =
                    forward::open(client, &request.fields).map(|value| mutation_result(mux, value));
                send_resource_response(writer, id, operation, result)
            }
            _ => owner::answer_later(mux, request, writer),
        }
    }
    #[cfg(not(all(unix, feature = "tailnet")))]
    {
        let _ = client;
        send_resource_response(writer, id, operation, Err(not_built(operation)))
    }
}

/// The connection ended: its forwards close (their sockets go).
pub(super) fn disconnect(client: u64) {
    #[cfg(all(unix, feature = "tailnet"))]
    forward::disconnect(client);
    #[cfg(not(all(unix, feature = "tailnet")))]
    let _ = client;
}

/// The frontend actor: the verified cmux app (`Actor::Frontend`, which a
/// request credential or a link, WebSocket or relayed connection never
/// derives) on a local Unix connection with no link peer record.
fn require_frontend(mux: &Mux, client: u64, actor: &Actor) -> Result<(), ResourceError> {
    let frontend = matches!(actor, Actor::Frontend { .. });
    let local = mux.control_clients.is_unix(client) && !mux.is_remote_client(client);
    if frontend && local {
        return Ok(());
    }
    Err(crate::request_origin::forbidden(
        "the tailnet node is the cmux app's only: sign-in, forwards and state go to the verified app's own connection",
        json!({"derived": "agent", "required": "user", "reason": "tailnet_frontend_only"}),
    ))
}

#[cfg_attr(all(unix, feature = "tailnet"), allow(dead_code))]
fn not_built(operation: ResourceOperation) -> ResourceError {
    ResourceError::operation_failed(
        operation.wire_name(),
        "not_built",
        json!({"message": "this cmux build has no tailnet support (cargo feature tailnet)"}),
    )
}

/// A `MutationResult`: the node's change is not the session registry's, so
/// revision 0 and never replayed (as `chief.engine.set`).
#[cfg_attr(not(all(unix, feature = "tailnet")), allow(dead_code))]
fn mutation_result(mux: &Mux, value: Value) -> Value {
    let (_, generation) = mux.registry_identity();
    json!({"value": value, "generation": generation, "revision": "0", "replayed": false})
}
