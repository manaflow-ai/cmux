//! Wire adapter for the app supervisor (`apps-v1`, plan section 13.2).
//!
//! Requests: `{id, cmd: "apps-…", origin?, …params}`; `origin` is
//! `user|cli|mcp|script|remote`, absent = cli. Replies use the normal
//! envelope: `{id, ok: true, data}` or `{id, ok: false, error, error_code}`.
//! Only local (Unix socket) connections may use apps commands, and only the
//! verified app connection (server/app_trust.rs) may send origin `user`
//! (`apps.origin_forbidden` otherwise; see
//! `apps::provider::hosting_app_connection`). A connection
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
    crate::apps::ProviderClaim {
        // An agent's conversation binding; switches to the identity lane's
        // terminal/acp_session actor with `agent` once it lands.
        agent: mux.conversation_principal(client) != crate::conversation_store::LOCAL_USER,
        // Proved, never declared: install-key hello or app code signature
        // (server/app_trust.rs). `set-client-info kind` does not count.
        verified_app: mux.control_clients.app_trust.verified_app(client),
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
    // Origin `user` installs apps, grants scopes and mints gestures: only the
    // hosting app connection may claim it (A2). Checked before anything else
    // so a refused request changes nothing.
    if let Err(e) = crate::apps::admit_origin(request.origin, &claim_for(mux, client)) {
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
                crate::apps::RunRequest { app, op, args, idempotency_key, origin, gesture },
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
            mux.bind_conversation_principal(client, "agent:test".to_string());
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

    #[test]
    fn origin_user_needs_the_hosting_app_connection() {
        let mux = Mux::new_for_test("apps-origin-gate", SurfaceOptions::default());
        // An agent connection is refused even when it is a verified app.
        let (agent, agent_out) = connection(&mux, Some("app"), true);
        mux.control_clients.app_trust.prove_for_test(agent, "inst_test");
        for request in [install("user"), grant("user")] {
            assert_eq!(error_code(&mux, agent, &agent_out, request).as_deref(), FORBIDDEN);
        }
        // A local client that is not the app is refused too.
        let (cli, cli_out) = connection(&mux, Some("cli"), false);
        for request in [install("user"), grant("user")] {
            assert_eq!(error_code(&mux, cli, &cli_out, request).as_deref(), FORBIDDEN);
        }
        // The verified app passes the gate (the request then reaches the
        // supervisor, or apps.unavailable in a daemon without an app host).
        let (app, app_out) = connection(&mux, Some("app"), false);
        mux.control_clients.app_trust.prove_for_test(app, "inst_test");
        for request in [install("user"), grant("user")] {
            assert_ne!(error_code(&mux, app, &app_out, request).as_deref(), FORBIDDEN);
        }
    }

    /// P8 3b-2: kind `app` is a self-declared label. A local connection that
    /// declares it but proved nothing (no install-key hello, no app code
    /// signature) never acts with origin user.
    #[test]
    fn a_self_declared_app_kind_never_reaches_origin_user() {
        let mux = Mux::new_for_test("apps-origin-self-declared", SurfaceOptions::default());
        let (app, app_out) = connection(&mux, Some("app"), false);
        for request in [install("user"), grant("user")] {
            assert_eq!(error_code(&mux, app, &app_out, request).as_deref(), FORBIDDEN);
        }
    }

    #[test]
    fn other_origins_pass_from_any_local_connection() {
        let mux = Mux::new_for_test("apps-origin-other", SurfaceOptions::default());
        let (agent, out) = connection(&mux, None, true);
        // Hiding works from any origin (D55); cli and script are unchanged.
        for origin in ["cli", "script", "mcp"] {
            let hide = json!({ "id": 3, "cmd": "apps-set", "origin": origin, "idempotency_key": format!("h-{origin}"), "app": "cmux/demo", "hidden": true });
            assert_ne!(error_code(&mux, agent, &out, hide).as_deref(), FORBIDDEN);
        }
        let list = json!({ "id": 4, "cmd": "apps-list" });
        assert_ne!(error_code(&mux, agent, &out, list).as_deref(), FORBIDDEN);
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
