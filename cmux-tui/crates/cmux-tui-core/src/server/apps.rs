//! Wire adapter for the app supervisor (`apps-v1`, plan section 13.2).
//!
//! Requests: `{id, cmd: "apps-…", origin?, …params}`; `origin` is
//! `user|cli|mcp|script|remote`, absent = cli. Replies use the normal
//! envelope: `{id, ok: true, data}` or `{id, ok: false, error, error_code}`.
//! Only local (Unix socket) connections may use apps commands. `apps-set`
//! changes apps, so it needs a verified cmux app connection whatever origin
//! it claims, and so does every request with origin `user` (Gate A2,
//! plans/cmux-next/request-origin.md; `origin.forbidden` otherwise), and so
//! does `apps-provider-register`. The verified app is proved (P8,
//! server/app_trust.rs); a connection that only declares kind `app` is not
//! it. Origin `user` from a verified connection that is bound to an agent
//! is `apps.origin_forbidden` (see `apps::provider::hosting_app_connection`). A connection
//! receives `apps-changed` and `apps-host` events after its first apps
//! command; mount events go to the mounting connection only.

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
    /// The Mac app serves ops the daemon does not own (app-op-routing.md).
    #[serde(rename = "apps-provider-register")]
    ProviderRegister { families: Vec<String> },
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
                value["error_details"] = details;
            }
            value["retryable"] = Value::Bool(e.retryable);
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

fn spawn_off_startup(job: impl FnOnce() + Send + 'static) -> std::io::Result<JoinHandle<()>> {
    std::thread::Builder::new().name("cmux-apps-start".into()).spawn(job)
}

/// What the daemon knows about `client` for the hosting-app check.
fn claim_for(mux: &Mux, client: u64) -> crate::apps::ProviderClaim {
    // Proved, never declared: the install-key hello or the app's code
    // signature (P8, server/app_trust.rs). `set-client-info kind` and a
    // page relay never count.
    let verified_app = {
        let state =
            mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.clients.get(&client).is_some_and(|record| {
            record.origin.derive() == crate::request_origin::RequestOrigin::User
        })
    };
    crate::apps::ProviderClaim {
        // An agent's conversation binding; switches to the identity lane's
        // terminal/acp_session actor with `agent` once it lands.
        agent: mux.conversation_principal(client) != crate::conversation_store::LOCAL_USER,
        verified_app,
    }
}

/// Handles an `apps-*` command; `None` when the message is not one.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("\"apps-") {
        return None;
    }
    let value: Value = serde_json::from_str(message).ok()?;
    if !value.get("cmd").and_then(Value::as_str).is_some_and(|c| c.starts_with("apps-")) {
        return None;
    }
    let id = value.get("id").cloned();
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
    // (install, uninstall, enable, disable, hide, sandbox, grant), whatever
    // origin it claims, and every request with origin user (gestures) need a
    // verified cmux app connection. A declared kind app does not count.
    let user_authority = matches!(request.command, Command::Set { .. })
        || request.origin == crate::apps::Origin::User;
    if user_authority && let Err(e) = super::origin_gate::require_user(mux, client) {
        return Some(reply(writer, request.id, Err(e)));
    }
    // Origin `user` also needs a connection that is not bound to an agent
    // (the verified app check above does not see the agent binding).
    let origin_claim = claim_for(mux, client);
    if let Err(e) = crate::apps::admit_origin(request.origin, &origin_claim) {
        return Some(reply(writer, request.id, Err(e)));
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
        Command::ProviderRegister { families } => {
            supervisor.register_provider(client, claim_for(mux, client), families)
        }
        Command::ProviderResult { request_id, ok, body } => {
            supervisor.provider_result(client, request_id, ok, body)
        }
    };
    Some(reply(writer, id, result.map(|v| if v.is_null() { json!({}) } else { v })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SurfaceOptions;
    use crate::server::{BoundedOutbound, ClientTransport, QueuedSink};

    /// A local connection with `kind`, bound to an agent when `agent`.
    fn connection(mux: &Arc<Mux>, kind: Option<&str>, agent: bool) -> (u64, Arc<BoundedOutbound>) {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let client = mux.control_clients.register(ClientTransport::Unix, writer);
        mux.control_clients.state.lock().unwrap().clients.get_mut(&client).unwrap().kind =
            kind.map(str::to_string);
        if agent {
            mux.bind_conversation_principal(client, "agent:test".to_string()).unwrap();
        }
        (client, outbound)
    }

    /// Sends `request` on `client` and returns the reply's error code
    /// (`None` when the reply is ok).
    fn error_code(
        mux: &Arc<Mux>,
        client: u64,
        outbound: &BoundedOutbound,
        request: Value,
    ) -> Option<String> {
        let writer = mux.control_clients.state.lock().unwrap().clients[&client].writer.clone();
        assert_eq!(try_handle(mux, client, &request.to_string(), &writer), Some(true));
        let reply: Value = serde_json::from_str(&outbound.try_pop().expect("reply")).unwrap();
        reply["error_code"].as_str().map(str::to_string)
    }

    fn install(origin: &str) -> Value {
        json!({ "id": 1, "cmd": "apps-set", "origin": origin, "idempotency_key": "k1", "app": "cmux/demo", "installed": true })
    }

    fn grant(origin: &str) -> Value {
        json!({ "id": 2, "cmd": "apps-set", "origin": origin, "idempotency_key": "k2", "app": "cmux/demo", "grant": { "scope": "workspace:write", "granted": true } })
    }

    const FORBIDDEN: Option<&str> = Some("apps.origin_forbidden");
    /// Gate A2 on apps-set (request-origin.md): not a verified app.
    const NOT_VERIFIED: Option<&str> = Some("origin.forbidden");

    /// Makes `client` a verified cmux app connection (what P8's proof sets).
    fn verify(mux: &Arc<Mux>, client: u64) {
        crate::server::origin_gate::set_role_for_test(mux, client, "main");
        crate::server::origin_gate::set_verified_app_for_test(mux, client, true);
    }

    #[test]
    fn apps_set_needs_the_verified_app_and_origin_user_needs_no_agent() {
        let mux = Mux::new_for_test("apps-origin-gate", SurfaceOptions::default());
        // An agent connection is refused even when it is a verified app.
        let (agent, agent_out) = connection(&mux, Some("app"), true);
        for request in [install("user"), grant("user")] {
            assert_eq!(error_code(&mux, agent, &agent_out, request).as_deref(), NOT_VERIFIED);
        }
        // A local client that is not the app is refused too.
        let (cli, cli_out) = connection(&mux, Some("cli"), false);
        for request in [install("user"), grant("user")] {
            assert_eq!(error_code(&mux, cli, &cli_out, request).as_deref(), NOT_VERIFIED);
        }
        // A self-declared kind app is not the verified app.
        let (declared, declared_out) = connection(&mux, Some("app"), false);
        for request in [install("user"), grant("user")] {
            assert_eq!(error_code(&mux, declared, &declared_out, request).as_deref(), NOT_VERIFIED);
        }
        // The verified app passes both gates (the request then reaches the
        // supervisor, or apps.unavailable in a daemon without an app host).
        let (app, app_out) = connection(&mux, Some("app"), false);
        verify(&mux, app);
        for request in [install("user"), grant("user")] {
            let code = error_code(&mux, app, &app_out, request);
            assert!(code.as_deref() != FORBIDDEN && code.as_deref() != NOT_VERIFIED, "{code:?}");
        }
        // A verified connection that is bound to an agent still cannot act
        // with origin user.
        let (agent_app, agent_app_out) = connection(&mux, Some("app"), true);
        verify(&mux, agent_app);
        for request in [install("user"), grant("user")] {
            assert_eq!(error_code(&mux, agent_app, &agent_app_out, request).as_deref(), FORBIDDEN);
        }
    }

    /// P8 3b-2: kind `app` is a self-declared label. Provider registration
    /// counts only the verified app, never a declared kind or a page relay.
    #[test]
    fn only_the_verified_app_is_the_hosting_app_for_providers() {
        let mux = Mux::new_for_test("apps-provider-claim", SurfaceOptions::default());
        let (declared, _declared_out) = connection(&mux, Some("app"), false);
        assert!(!claim_for(&mux, declared).verified_app);
        let (relay, _relay_out) = connection(&mux, Some("app"), false);
        crate::server::origin_gate::set_role_for_test(&mux, relay, "page_relay");
        crate::server::origin_gate::set_verified_app_for_test(&mux, relay, true);
        assert!(!claim_for(&mux, relay).verified_app);
        let (app, _app_out) = connection(&mux, None, false);
        verify(&mux, app);
        assert!(claim_for(&mux, app).verified_app);
    }

    #[test]
    fn hiding_needs_the_verified_app_and_listing_does_not() {
        let mux = Mux::new_for_test("apps-origin-other", SurfaceOptions::default());
        let hide = |origin: &str| json!({ "id": 3, "cmd": "apps-set", "origin": origin, "idempotency_key": format!("h-{origin}"), "app": "cmux/demo", "hidden": true });
        // apps-set changes apps, so an agent connection cannot hide either
        // (Gate A2 on every apps-set change).
        let (agent, out) = connection(&mux, None, true);
        for origin in ["cli", "script", "mcp"] {
            assert_eq!(error_code(&mux, agent, &out, hide(origin)).as_deref(), NOT_VERIFIED);
        }
        let list = json!({ "id": 4, "cmd": "apps-list" });
        assert_ne!(error_code(&mux, agent, &out, list).as_deref(), NOT_VERIFIED);
        // The verified app hides with any origin.
        let (app, app_out) = connection(&mux, Some("app"), false);
        verify(&mux, app);
        for origin in ["cli", "script", "mcp"] {
            let code = error_code(&mux, app, &app_out, hide(origin));
            assert!(code.as_deref() != FORBIDDEN && code.as_deref() != NOT_VERIFIED, "{code:?}");
        }
    }

    fn parse(value: Value) -> Request {
        serde_json::from_value(value).expect("request")
    }

    #[test]
    fn requests_parse_with_origin_defaulting_to_cli() {
        let list = parse(json!({ "id": 1, "cmd": "apps-list" }));
        assert!(matches!(list.command, Command::List) && list.origin == crate::apps::Origin::Cli);
        let set = parse(
            json!({ "id": 2, "cmd": "apps-set", "origin": "user", "idempotency_key": "k", "app": "cmux/a", "hidden": true, "grant": { "scope": "agent:read", "granted": true } }),
        );
        assert_eq!(set.origin, crate::apps::Origin::User);
        assert!(matches!(
            set.command,
            Command::Set { hidden: Some(true), grant: Some(GrantParam { granted: true, .. }), .. }
        ));
        let mount = parse(
            json!({ "cmd": "apps-mount", "app": "cmux/a", "interface": "cmux.section/1", "mount_id": "m", "context": { "preview": true } }),
        );
        assert!(
            matches!(mount.command, Command::Mount { ref context, .. } if context["preview"] == true)
        );
        assert!(
            serde_json::from_value::<Request>(json!({ "cmd": "apps-set", "app": "cmux/a" }))
                .is_err(),
            "apps-set needs an idempotency key"
        );
        let register =
            parse(json!({ "cmd": "apps-provider-register", "families": ["fs", "action"] }));
        assert!(
            matches!(register.command, Command::ProviderRegister { ref families } if families.len() == 2)
        );
        let result = parse(
            json!({ "cmd": "apps-provider-result", "request_id": 4, "ok": false, "body": { "code": "x" } }),
        );
        assert!(matches!(result.command, Command::ProviderResult { request_id: 4, ok: false, .. }));
    }

    #[test]
    fn error_replies_carry_details_and_retryable() {
        let mux = Mux::new_for_test("apps-error-details", SurfaceOptions::default());
        let (client, outbound) = connection(&mux, Some("app"), false);
        let writer = mux.control_clients.state.lock().unwrap().clients[&client].writer.clone();
        let mut error = crate::apps::ApiError::new("cmux.cloud.not_found", "no such machine");
        error.details = Some(json!({ "status": 404, "upstream_code": "vm_not_found" }));
        error.retryable = true;
        assert!(reply(&writer, Some(json!(7)), Err(error)));
        let sent: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(
            sent,
            json!({ "id": 7, "ok": false, "error": "no such machine", "error_code": "cmux.cloud.not_found",
                "error_details": { "status": 404, "upstream_code": "vm_not_found" }, "retryable": true })
        );
        // Without details the reply still says whether a retry may help.
        assert!(reply(
            &writer,
            Some(json!(8)),
            Err(crate::apps::ApiError::new("apps.unknown", "no"))
        ));
        let plain: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!((plain.get("error_details"), plain["retryable"].clone()), (None, json!(false)));
    }

    #[test]
    fn a_client_open_token_is_not_part_of_an_apps_run_request() {
        // The supervisor alone mints open tokens; a client's top-level one is
        // not a field of the request, so it is dropped while parsing.
        let run = parse(
            json!({ "id": 5, "cmd": "apps-run", "origin": "user", "app": "cmux/a", "op": "a.go", "open_token": "forged", "args": {} }),
        );
        let Command::Run { args, .. } = run.command else { panic!("apps-run") };
        assert_eq!(args, json!({}));
    }

    #[test]
    fn the_app_supervisor_starts_off_the_daemon_startup_path() {
        // The job stands in for building the supervisor; it blocks until
        // released, and the caller must already have returned.
        let (release, wait) = std::sync::mpsc::channel::<()>();
        let (done, finished) = std::sync::mpsc::channel::<()>();
        let handle = spawn_off_startup(move || {
            wait.recv().unwrap();
            done.send(()).unwrap();
        })
        .unwrap();
        assert!(finished.try_recv().is_err(), "the caller returned while the start still runs");
        release.send(()).unwrap();
        handle.join().unwrap();
        assert!(finished.try_recv().is_ok());
        // Without an app host (no apps-v1) nothing starts and nothing blocks.
        let mux = Mux::new_for_test("apps-start-off-path", SurfaceOptions::default());
        start_apps_when_ready(&mux);
    }
}
