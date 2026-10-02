//! Wire adapter for the app supervisor (`apps-v1`, plan section 13.2).
//!
//! Requests: `{id, cmd: "apps-…", origin?, …params}`; `origin` is
//! `user|cli|mcp|script|remote`, absent = cli. Replies use the normal
//! envelope: `{id, ok: true, data}` or `{id, ok: false, error, error_code}`.
//! Only local (Unix socket) connections may use apps commands. A connection
//! receives `apps-changed` and `apps-host` events after its first apps
//! command; mount events go to the mounting connection only.

use std::sync::Arc;

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
    },
    #[serde(rename = "apps-logs")]
    Logs {
        app: String,
        #[serde(default)]
        follow: bool,
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
        Err(e) => Response {
            id,
            ok: false,
            data: None,
            error: Some(e.message),
            error_code: Some(e.code),
            error_delivery: None,
        },
    };
    send_response(writer, response)
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
        Command::Run { app, op, args, idempotency_key } => {
            let writer = writer.clone();
            supervisor.run(
                &app,
                &op,
                args,
                idempotency_key,
                origin,
                Box::new(move |result| {
                    reply(&writer, id, result);
                }),
            );
            return Some(true);
        }
        Command::Logs { app, follow } => Ok(supervisor.logs(client, &app, follow)),
    };
    Some(reply(writer, id, result.map(|v| if v.is_null() { json!({}) } else { v })))
}

#[cfg(test)]
mod tests {
    use super::*;

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
    }
}
