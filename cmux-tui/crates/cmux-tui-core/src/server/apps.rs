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
use std::sync::Arc;
use std::thread::JoinHandle;

use serde::Deserialize;
use serde_json::{Value, json};

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
    /// The capability manifest (`apps.capabilities`, read): every op an app
    /// may call with its scope, class, risk class, consent text, gesture and
    /// escalation, the ops apps never reach, the API version and the typed
    /// global `cmux-app.d.ts` (cmux_app_manifest::capabilities). `op` asks
    /// for one op's row. Needs no app host: it is this daemon's own table.
    /// `brief` answers the API version and the types digest only.
    #[serde(rename = "apps-capabilities")]
    Capabilities {
        #[serde(default)]
        op: Option<String>,
        #[serde(default)]
        brief: bool,
    },
    /// `cmux <cli.name> <path…>`: the installed app whose manifest
    /// `cli.name` is `name`, and its op whose `cli.path` the words start
    /// with (apps/cli_commands.rs). The CLI then runs the op with `apps-run`.
    #[serde(rename = "apps-cli")]
    Cli {
        name: String,
        #[serde(default)]
        words: Vec<String>,
    },
    #[serde(rename = "apps-place")]
    Place {
        contribution: String,
        #[serde(default)]
        region: Option<cmux_layout_reducer::sidebar_doc::Region>,
    },
    /// Reads the local app folders again now and reloads `app`, or every
    /// local app, as a save would (`Supervisor::reload_local_now`). No
    /// gesture: it changes no install, grant or placement, only reruns
    /// scripts the person already installed.
    #[serde(rename = "apps-reload")]
    Reload {
        #[serde(default)]
        app: Option<String>,
    },
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
    /// Safe mode (apps/safe_mode.rs): `op` is `safe_mode.get`,
    /// `safe_mode.set {on}` (leaving needs origin user),
    /// `safe_mode.launch_began` or `safe_mode.launch_settled {reason?}` (the
    /// launch ops from the verified app connection only).
    #[serde(rename = "apps-safe-mode")]
    SafeMode {
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
    /// A clicked link (`cmux.opener/1`, apps/openers.rs): the matching
    /// app's opener runs with `{url}`; `{handled: false}` sends the caller
    /// to its usual open.
    #[serde(rename = "apps-open-link")]
    OpenLink { url: String },
    /// Open terminal connector links and their local sockets (for this
    /// daemon's clients; apps never get a socket path).
    #[serde(rename = "apps-terminal-links")]
    TerminalLinks,
    /// Read the local app folders again now and apply what changed, as the
    /// file watch does on a save (`Supervisor::reload_local_apps_now`): the
    /// caller that just wrote an app's files (`cmux ext dev`) asks, so its
    /// reload never waits on file events. The `apps-changed` and
    /// `apps-reload-failed` events of the pass go out before the reply.
    /// `folders` names the package folders the caller wrote: the pass reads
    /// only those when each is a watched one, else every folder.
    #[serde(rename = "apps-reload-local")]
    ReloadLocal {
        #[serde(default)]
        folders: Option<Vec<std::path::PathBuf>>,
    },
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
    /// One Cloud event the app received pushed (a machine's state socket):
    /// the daemon passes it to the first-party Cloud server as a
    /// `team.event` line (`Supervisor::team_event`). Verified app only.
    #[serde(rename = "apps-team-event")]
    TeamEvent { event: String, data: Value },
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
    /// The verified app's provider of `family` says its data changed (`<family>.changed`).
    #[serde(rename = "apps-provider-changed")]
    ProviderChanged { family: String },
    /// One bridge message of an app's web pane (`render: web`,
    /// apps/page_calls.rs), from the Mac app that hosts the page: `page`
    /// names the open page, `message` is the page's raw `{id, op, params}`
    /// (the size limit applies before it is parsed). Verified app only. The
    /// reply is the page's answer `{id, ok, value | error}`.
    #[serde(rename = "apps-page-call")]
    PageCall { app: String, page: String, message: String },
    /// The person approves a credential for an app's `external` server
    /// (apps/server_external.rs): origin user, the verified app only.
    #[serde(rename = "apps-server-credential")]
    ServerCredential { app: String },
    /// A process the person started serves `app` on this connection, with
    /// the credential they approved.
    #[serde(rename = "apps-server-attach")]
    ServerAttach { app: String, credential: String },
    /// One `result` or `event` line of the external server on this connection.
    #[serde(rename = "apps-server-line")]
    ServerLine { app: String, line: Value },
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

/// Runs `job` on a thread of its own and replies to `id` with its result
/// when it ends; the connection reads its next request meanwhile.
fn answer_off_thread(
    writer: &MessageWriter,
    id: Option<Value>,
    job: impl FnOnce() -> Result<Value, crate::apps::ApiError> + Send + 'static,
) -> bool {
    let answer = writer.clone();
    let asked = id.clone();
    let spawned = std::thread::Builder::new()
        .name("cmux-apps-reload".into())
        .spawn(move || reply(&answer, asked, job()));
    match spawned {
        Ok(_) => true,
        Err(error) => reply(
            writer,
            id,
            Err(crate::apps::ApiError::new("operation.failed", error.to_string())),
        ),
    }
}

fn spawn_off_startup(job: impl FnOnce() + Send + 'static) -> std::io::Result<JoinHandle<()>> {
    std::thread::Builder::new().name("cmux-apps-start".into()).spawn(job)
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

/// `apps-capabilities`: the manifest, one op's row, or (`brief`) the API
/// version and types digest.
fn capabilities(op: Option<&str>, brief: bool) -> Result<Value, crate::apps::ApiError> {
    let table = cmux_app_manifest::Capabilities::get();
    if let Some(error) = cmux_app_manifest::Capabilities::load_error() {
        return Err(crate::apps::ApiError::new("apps.capabilities", error));
    }
    if brief {
        return Ok(table.summary_json());
    }
    table.manifest_json(op).ok_or_else(|| {
        crate::apps::ApiError::new(
            "apps.op.unknown",
            format!("{} is not an op of this cmux", op.unwrap_or_default()),
        )
    })
}

/// Handles an `apps-*` command or `cancel-request`; `None` when the message
/// is neither.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("\"apps-") && !message.contains("\"cancel-request\"") {
        return None;
    }
    let value: Value = serde_json::from_str(message).ok()?;
    let cmd = value.get("cmd").and_then(Value::as_str)?;
    if cmd == "cancel-request" {
        return Some(cancel_request(mux, client, value, writer));
    }
    if !cmd.starts_with("apps-") {
        return None;
    }
    let id = value.get("id").cloned();
    // An invalidation carries its one field and nothing else (no stream, owner or rows).
    let only = match cmd {
        "apps-agent-inventory-changed" => Some("demand_sequence"),
        "apps-provider-changed" => Some("family"),
        _ => None,
    };
    if let Some(only) = only
        && value.as_object().is_none_or(|fields| {
            fields.keys().any(|key| key != "id" && key != "cmd" && key != only)
        })
    {
        return Some(reply(
            writer,
            id,
            Err(crate::apps::ApiError::new(
                "bad-request",
                format!("this invalidation accepts only {only}"),
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
        Command::Set { .. } | Command::ServerCredential { .. } => true,
        Command::Store { op, .. } => crate::apps::store_op_mutates(op),
        // Only the app that runs the link reports its changes (cx-rtipa).
        Command::LinkChanged | Command::TeamEvent { .. } => true,
        _ => false,
    };
    // The capability manifest is this daemon's own read-only table: no
    // grant, gate or app host decides it.
    if let Command::Capabilities { op, brief } = &request.command {
        return Some(reply(writer, request.id, capabilities(op.as_deref(), *brief)));
    }
    let user_authority = changes_apps || request.origin == crate::apps::Origin::User;
    if user_authority && let Err(e) = super::origin_gate::require_user(mux, client) {
        return Some(reply(writer, request.id, Err(e)));
    }
    // Origin `user` also needs a connection that is not bound to an agent
    // (the verified app check above does not see the agent binding).
    let origin_claim = claim_for(mux, client);
    if matches!(
        request.command,
        Command::AgentInventoryChanged { .. } | Command::ProviderChanged { .. }
    ) && !crate::apps::hosting_app_connection(&origin_claim)
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
    // Only the app itself reports its launches: an agent cannot fake a
    // crash loop, nor settle one away.
    if let Command::SafeMode { op, .. } = &request.command
        && op.contains("launch_")
        && !crate::apps::hosting_app_connection(&origin_claim)
    {
        return Some(reply(
            writer,
            request.id,
            Err(crate::apps::ApiError::new(
                "apps.origin_forbidden",
                "only the verified cmux app connection reports its launches",
            )),
        ));
    }
    // An agent-bound connection never reports a link change, also when it
    // is the verified app's (as `apps-provider-register`).
    if matches!(request.command, Command::LinkChanged | Command::TeamEvent { .. })
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
    // A web pane's call runs with its app's grant: only the app that hosts
    // the page may send it, so no other connection borrows that grant.
    if matches!(request.command, Command::PageCall { .. })
        && !crate::apps::hosting_app_connection(&origin_claim)
    {
        return Some(reply(
            writer,
            request.id,
            Err(crate::apps::ApiError::new(
                "apps.origin_forbidden",
                "only the verified cmux app connection hosts an extension's web pane",
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
    // A forced reload reads every local folder and may wait on a load trial
    // per open view (seconds): it answers from its own thread, so this
    // connection's mounts and events go on meanwhile (`apps-reload`, and the
    // app's Reload Custom Views, the App Store op `apps.local.reload`).
    let command = match command {
        Command::Reload { app } => {
            return Some(answer_off_thread(writer, id, move || {
                supervisor.reload_local_now(app.as_deref())
            }));
        }
        Command::Store { op, args } if op == "apps.local.reload" => {
            return Some(answer_off_thread(writer, id, move || {
                supervisor.store_call(client, &op, args, origin)
            }));
        }
        command => command,
    };
    let result = match command {
        Command::List => Ok(supervisor.list()),
        Command::ReloadLocal { folders } => Ok(supervisor.reload_local_apps_named(folders)),
        Command::Capabilities { op, brief } => capabilities(op.as_deref(), brief),
        Command::Cli { name, words } => supervisor.cli_resolve(&name, &words),
        Command::Place { contribution, region } => supervisor.place_sidebar(&contribution, region),
        // Answered on its own thread above.
        Command::Reload { .. } => Err(crate::apps::ApiError::new(
            "operation.failed",
            "apps-reload is answered off this thread",
        )),
        Command::TerminalLinks => Ok(supervisor.terminal_links_list()),
        Command::LinkChanged => Ok(json!({ "servers": supervisor.host_link_changed() })),
        Command::TeamEvent { event, data } => supervisor.team_event(&event, &data),
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
                grant_optional: false,
            },
        ),
        Command::Store { op, args } => supervisor.store_call(client, &op, args, origin),
        Command::SafeMode { op, args } => supervisor.safe_mode_call(&op, args, origin),
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
        Command::PageCall { app, page, message } => {
            let writer = writer.clone();
            supervisor.page_call(
                client,
                &app,
                &page,
                &message,
                Box::new(move |result| {
                    reply(&writer, id, result);
                }),
            );
            return Some(true);
        }
        Command::OpenLink { url } => {
            let writer = writer.clone();
            supervisor.open_link(
                url,
                origin,
                Box::new(move |result| {
                    reply(&writer, id, result);
                }),
            );
            return Some(true);
        }
        Command::Logs { app, follow } => {
            // A follow outlives its request (`server/message_writer/long_connection.rs`).
            if follow && let Err(full) = writer.long.hold() {
                Err(crate::apps::ApiError::new("operation.failed", full.to_string()))
            } else {
                Ok(supervisor.logs(client, &app, follow))
            }
        }
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
        Command::ProviderChanged { family } => {
            supervisor.provider_changed(client, claim_for(mux, client), &family)
        }
        Command::ProviderResult { request_id, ok, body } => {
            supervisor.provider_result(client, request_id, ok, body)
        }
        Command::ServerCredential { app } => supervisor.server_credential(&app, origin),
        Command::ServerAttach { app, credential } => {
            supervisor.server_attach(client, claim_for(mux, client).agent, &app, &credential)
        }
        Command::ServerLine { app, line } => supervisor.server_line_from(client, &app, line),
    };
    Some(reply(writer, id, result.map(|v| if v.is_null() { json!({}) } else { v })))
}

#[cfg(test)]
#[path = "apps_tests.rs"]
mod tests;
