//! Wire adapter for the app supervisor (`apps-v1`, plan section 13.2).
//!
//! Requests: `{id, cmd: "apps-…", origin?, …params}`; `origin` is
//! `user|cli|mcp|script|remote`, absent = cli. Replies use the normal
//! envelope: `{id, ok: true, data}` or `{id, ok: false, error, error_code}`.
//! Only local (Unix socket) connections may use apps commands. `apps-set`
//! and the App Store mutations of `apps-store {op, args}` (`cmux.apps.set`,
//! `install`, `uninstall`, `hidden.set`, `grant.set`, `grant.revoke`;
//! apps/store.rs) change apps, so they need a
//! verified cmux app connection whatever origin they claim, and so does
//! every request with origin `user` (Gate A2, plans/cmux-next/
//! request-origin.md; `origin.forbidden` otherwise), and so does
//! `apps-provider-register`. The verified app is proved (P8,
//! server/app_trust.rs); a connection that only declares kind `app` is not
//! it. Origin `user` from a verified connection that is bound to an agent
//! is `apps.origin_forbidden` (see `apps::provider::hosting_app_connection`). A connection
//! receives `apps-changed` and `apps-host` events after its first apps
//! command; mount events go to the mounting connection only.

use crate::panic_free::JsonFields;
use crate::supervised::{self, Fatal, ShutdownBehavior, SupervisedThread};
use std::sync::Arc;

use serde::Deserialize;
use serde_json::{Value, json};

use super::routes::RouteLine;
use super::{MessageWriter, Response, send_response};
use crate::mux::Mux;

#[derive(Deserialize)]
struct GrantParam {
    scope: String,
    granted: bool,
}

#[derive(Deserialize)]
#[serde(tag = "cmd")]
enum Command {
    #[serde(rename = "apps-list")]
    List,
    #[serde(rename = "apps-set")]
    Set {
        idempotency_key: String,
        app: String,
        #[serde(default)]
        installed: Option<bool>,
        #[serde(default)]
        enabled: Option<bool>,
        #[serde(default)]
        hidden: Option<bool>,
        #[serde(default)]
        hidden_access: Option<crate::apps::HiddenAccess>,
        #[serde(default)]
        sandboxed: Option<bool>,
        #[serde(default)]
        grant: Option<GrantParam>,
    },
    /// An App Store op (`cmux.apps.*`, apps/store.rs): `{op, args}`.
    #[serde(rename = "apps-store")]
    Store {
        op: String,
        #[serde(default)]
        args: Value,
    },
    #[serde(rename = "apps-mount")]
    Mount {
        app: String,
        interface: String,
        mount_id: String,
        #[serde(default)]
        context: Value,
    },
    #[serde(rename = "apps-unmount")]
    Unmount { mount_id: String },
    #[serde(rename = "apps-dispatch")]
    Dispatch {
        mount_id: String,
        node: String,
        event: String,
        #[serde(default)]
        payload: Value,
    },
    #[serde(rename = "apps-run")]
    Run {
        app: String,
        op: String,
        #[serde(default)]
        args: Value,
        #[serde(default)]
        idempotency_key: Option<String>,
        /// A palette/keybinding invocation's own token (origin user only).
        #[serde(default)]
        gesture: Option<String>,
    },
    /// Open terminal connector links and their local sockets (for this
    /// daemon's clients; apps never get a socket path).
    #[serde(rename = "apps-terminal-links")]
    TerminalLinks,
    #[serde(rename = "apps-logs")]
    Logs {
        app: String,
        #[serde(default)]
        follow: bool,
    },
    /// The link registration changed (`cmux link ensure` or `stop` ran):
    /// tell every app server that reads the link (`cmux.host.link.changed`).
    #[serde(rename = "apps-link-changed")]
    LinkChanged,
    /// The Mac app serves ops the daemon does not own (app-op-routing.md).
    #[serde(rename = "apps-provider-register")]
    ProviderRegister {
        families: Vec<String>,
        #[serde(default)]
        inventory_watch: bool,
    },
    /// A fixed invalidation from the current verified agent_cli provider.
    #[serde(rename = "apps-agent-inventory-changed")]
    AgentInventoryChanged { demand_sequence: u64 },
    #[serde(rename = "apps-provider-result")]
    ProviderResult {
        request_id: u64,
        ok: bool,
        #[serde(default)]
        body: Value,
    },
}

#[derive(Deserialize)]
struct Request {
    #[serde(default)]
    id: Option<Value>,
    #[serde(default)]
    origin: crate::apps::Origin,
    #[serde(flatten)]
    command: Command,
}

fn reply(
    writer: &MessageWriter,
    id: Option<Value>,
    result: Result<Value, crate::apps::ApiError>,
) -> bool {
    let response = match result {
        Ok(data) => Response {
            id,
            ok: true,
            data: Some(data),
            error: None,
            error_code: None,
            error_delivery: None,
        },
        Err(e) => {
            let response = Response {
                id,
                ok: false,
                data: None,
                error: Some(e.message),
                error_code: Some(e.code),
                error_delivery: None,
            };
            // The owner's details and retryable ride next to the error,
            // unchanged (a page reads details.status, details.upstream_code).
            let Ok(mut value) = serde_json::to_value(response) else { return false };
            if let Some(details) = e.details {
                value.insert("error_details", details);
            }
            value.insert("retryable", Value::Bool(e.retryable));
            return writer.send_control(&value).is_ok();
        }
    };
    send_response(writer, response)
}

/// After the daemon is ready, starts the app supervisor on its own thread
/// when `apps-v1` is advertised, so apps with an `always` server run without
/// waiting for the first `apps-*` command. Never on the startup path.
pub fn start_apps_when_ready(mux: &Arc<Mux>) {
    if crate::apps::advertised().is_some() {
        let mux = mux.clone();
        let _ = spawn_off_startup(move || {
            mux.control_clients.apps.get_or_init(&mux);
        });
    }
}

fn spawn_off_startup(job: impl FnOnce() + Send + 'static) -> std::io::Result<SupervisedThread<()>> {
    supervised::spawn_at(
        "cmux-apps-start",
        cmux_threads::ThreadQos::Utility,
        Fatal,
        ShutdownBehavior::Continue,
        job,
    )
}

/// Whether origin `user` is allowed on `client` now: both checks of this
/// door (Gate A2, the verified app; and no agent binding). `client-hello`
/// reports it as `user_origin_allowed`, so the app claims `user` only then.
pub(super) fn user_origin_allowed(mux: &Mux, client: u64) -> bool {
    crate::apps::admit_origin(crate::apps::Origin::User, &claim_for(mux, client)).is_ok()
}

/// What the daemon knows about `client` for the hosting-app check.
fn claim_for(mux: &Mux, client: u64) -> crate::apps::ProviderClaim {
    let facts = super::origin_gate::app_connection(mux, client);
    crate::apps::ProviderClaim { agent: facts.agent, verified_app: facts.verified_app }
}

#[derive(Deserialize)]
struct CancelRequest {
    #[serde(default)]
    id: Option<Value>,
    target: Value,
}

/// `cancel-request` (spec/cli.md "apps run"): the caller cancels its own
/// `apps-run` request `target` on this connection; the run answers
/// `cmux.op.cancelled` (apps/cancel.rs). A request that is unknown, already
/// answered or another connection's changes nothing; the reply is `{}`.
fn cancel_request(mux: &Arc<Mux>, client: u64, value: Value, writer: &MessageWriter) -> bool {
    let id = value.get("id").cloned();
    let request = match serde_json::from_value::<CancelRequest>(value) {
        Ok(request) => request,
        Err(e) => {
            return reply(
                writer,
                id,
                Err(crate::apps::ApiError::new("bad-request", e.to_string())),
            );
        }
    };
    if !mux.control_clients.is_unix(client) {
        return reply(
            writer,
            request.id,
            Err(crate::apps::ApiError::new("apps.local", "apps commands need a local connection")),
        );
    }
    mux.control_clients.apps.cancel_request(client, &request.target);
    // The same frame ends a running script cell (server/scripts.rs).
    mux.control_clients.scripts.cancel_request(client, &request.target);
    reply(writer, request.id, Ok(json!({})))
}

/// The `cmd` names this module answers (server/routes.rs).
pub(in crate::server) const ROUTES: &[crate::server::routes::Route] =
    &[crate::server::routes::Route {
        names: &[
            crate::server::routes::RouteName::Prefix("apps-"),
            crate::server::routes::RouteName::Exact("cancel-request"),
        ],
        stage: crate::server::FrameStage::Apps,
        entry: handle,
    }];

/// Answers a line whose `cmd` is `cancel-request` or starts with `apps-`
/// (the route found it by name). The line's one decode is its `Value`: it
/// gives every reply the `id` as written, a refused one too, and then the
/// module's typed [`Request`]. `None` only for a line with no `Value` (a
/// number past `f64`, a lone surrogate); the `Command` parse answers it.
fn handle(line: &RouteLine<'_>) -> Option<bool> {
    let RouteLine { mux, client, message, writer, .. } = *line;
    let value: Value = crate::line_parses::parse(message).ok()?;
    let cmd = value.get("cmd").and_then(Value::as_str);
    if cmd == Some("cancel-request") {
        return Some(cancel_request(mux, client, value, writer));
    }
    let id = value.get("id").cloned();
    if cmd == Some("apps-agent-inventory-changed")
        && value.as_object().is_none_or(|fields| {
            fields.keys().any(|key| !matches!(key.as_str(), "id" | "cmd" | "demand_sequence"))
        })
    {
        return Some(reply(
            writer,
            id,
            Err(crate::apps::ApiError::new(
                "bad-request",
                "inventory invalidation accepts only demand_sequence",
            )),
        ));
    }
    let request = match serde_json::from_value::<Request>(value) {
        Ok(request) => request,
        Err(e) => {
            return Some(reply(
                writer,
                id,
                Err(crate::apps::ApiError::new("bad-request", e.to_string())),
            ));
        }
    };
    if !mux.control_clients.is_unix(client) {
        return Some(reply(
            writer,
            request.id,
            Err(crate::apps::ApiError::new("apps.local", "apps commands need a local connection")),
        ));
    }
    // Gate A2 on the legacy door (request-origin.md): every apps-set change
    // (install, uninstall, enable, disable, hide, sandbox, grant) and every
    // App Store mutation (`apps-store` set, install, uninstall), whatever
    // origin it claims, and every request with origin user (gestures) need a
    // verified cmux app connection. A declared kind app does not count.
    let changes_apps = match &request.command {
        Command::Set { .. } => true,
        Command::Store { op, .. } => crate::apps::store_op_mutates(op),
        // Only the app that runs the link reports its changes (cx-rtipa).
        Command::LinkChanged => true,
        _ => false,
    };
    let user_authority = changes_apps || request.origin == crate::apps::Origin::User;
    if user_authority && let Err(e) = super::origin_gate::require_user(mux, client) {
        return Some(reply(writer, request.id, Err(e)));
    }
    // Origin `user` also needs a connection that is not bound to an agent
    // (the verified app check above does not see the agent binding).
    let origin_claim = claim_for(mux, client);
    if matches!(request.command, Command::AgentInventoryChanged { .. })
        && !crate::apps::hosting_app_connection(&origin_claim)
    {
        return Some(reply(
            writer,
            request.id,
            Err(crate::apps::ApiError::new(
                "apps.provider.forbidden",
                "only the verified app provider invalidates inventory",
            )),
        ));
    }
    if let Err(e) = crate::apps::admit_origin(request.origin, &origin_claim) {
        return Some(reply(writer, request.id, Err(e)));
    }
    // An agent-bound connection never reports a link change, also when it
    // is the verified app's (as `apps-provider-register`).
    if matches!(request.command, Command::LinkChanged)
        && !crate::apps::hosting_app_connection(&origin_claim)
    {
        return Some(reply(
            writer,
            request.id,
            Err(crate::apps::ApiError::new(
                "apps.origin_forbidden",
                "only the verified cmux app connection reports a link change",
            )),
        ));
    }
    if crate::apps::advertised().is_none() {
        return Some(reply(
            writer,
            request.id,
            Err(crate::apps::ApiError::new("apps.unavailable", "this daemon has no app host")),
        ));
    }
    let supervisor = mux.control_clients.apps.get_or_init(mux);
    let sink_writer = writer.clone();
    supervisor.register_client(
        client,
        Arc::new(move |event: &Value| sink_writer.send_control(event).is_ok()),
    );
    let Request { id, origin, command } = request;
    let user = origin == crate::apps::Origin::User;
    let result = match command {
        Command::List => Ok(supervisor.list()),
        Command::TerminalLinks => Ok(supervisor.terminal_links_list()),
        Command::LinkChanged => Ok(json!({ "servers": supervisor.host_link_changed() })),
        Command::Set {
            idempotency_key,
            app,
            installed,
            enabled,
            hidden,
            hidden_access,
            sandboxed,
            grant,
        } => supervisor.set(
            client,
            crate::apps::SetOp {
                key: idempotency_key,
                app,
                origin,
                installed,
                enabled,
                hidden,
                hidden_access,
                sandboxed,
                grant: grant.map(|g| (g.scope, g.granted)),
            },
        ),
        Command::Store { op, args } => supervisor.store_call(client, &op, args, origin),
        Command::Mount { app, interface, mount_id, context } => {
            supervisor.mount(client, &mount_id, &app, &interface, context)
        }
        Command::Unmount { mount_id } => supervisor.unmount(client, &mount_id),
        Command::Dispatch { mount_id, node, event, payload } => {
            supervisor.dispatch(client, &mount_id, &node, &event, payload, user)
        }
        Command::Run { app, op, args, idempotency_key, gesture } => {
            let writer = writer.clone();
            supervisor.run(
                crate::apps::RunRequest {
                    app,
                    op,
                    args,
                    idempotency_key,
                    origin,
                    gesture,
                    caller: Some(crate::apps::Caller {
                        client,
                        request: id.clone().unwrap_or(Value::Null),
                    }),
                },
                Box::new(move |result| {
                    reply(&writer, id, result);
                }),
            );
            return Some(true);
        }
        Command::Logs { app, follow } => Ok(supervisor.logs(client, &app, follow)),
        Command::ProviderRegister { families, inventory_watch } => {
            if inventory_watch {
                supervisor.register_inventory_provider(client, claim_for(mux, client), families)
            } else {
                supervisor.register_provider(client, claim_for(mux, client), families)
            }
        }
        Command::AgentInventoryChanged { demand_sequence } => {
            supervisor.agent_inventory_changed(client, claim_for(mux, client), demand_sequence)
        }
        Command::ProviderResult { request_id, ok, body } => {
            supervisor.provider_result(client, request_id, ok, body)
        }
    };
    Some(reply(writer, id, result.map(|v| if v.is_null() { json!({}) } else { v })))
}

#[cfg(test)]
#[path = "apps_tests.rs"]
mod tests;
