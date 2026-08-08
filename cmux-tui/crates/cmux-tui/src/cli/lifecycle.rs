use std::io::{BufRead, BufReader, Write};
use std::time::Duration;

use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};

#[derive(Clone, Debug)]
pub(super) struct ServerPlan {
    pub action: ServerAction,
    pub session: Option<String>,
}

#[derive(Clone, Debug)]
pub(super) enum ServerAction {
    Status,
    Stop { force: bool },
    ReloadConfig,
}

pub(super) fn run(mut global: GlobalArgs, plan: ServerPlan) -> i32 {
    if let Some(session) = plan.session {
        if global.session.as_deref().is_some_and(|global| global != session) {
            return usage_error("the session selector conflicts with --session", global.output);
        }
        global.session = Some(session);
    }
    let expected_session = global.session.clone();
    let session = expected_session.as_deref().unwrap_or("main").to_string();
    let socket = super::wire::resolve_socket(&global);
    let stream = match transport::connect(&socket) {
        Ok(stream) => stream,
        Err(error) if matches!(plan.action, ServerAction::Stop { .. }) && is_absent(&error) => {
            return print_success(
                json!({
                    "status":"not_running",
                    "session":session,
                    "socket":socket,
                    "message":crate::localization::catalog().local_server.not_running,
                }),
                global.output,
            );
        }
        Err(error) => {
            let message = crate::localization::catalog()
                .local_server
                .connect_failed
                .replace("{socket}", &socket.display().to_string())
                .replace("{error}", &error.to_string());
            return local_error("server.unavailable", &message, global.output, 3);
        }
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let mut connection = BufReader::new(stream);
    let identity = match exchange(&mut connection, json!({"id":1,"cmd":"identify"})) {
        Ok(identity) => identity,
        Err(message) => return local_error("server.identity_failed", &message, global.output, 3),
    };
    if identity["app"] != "cmux-tui" {
        return local_error(
            "server.wrong_owner",
            crate::localization::catalog().local_server.wrong_owner,
            global.output,
            1,
        );
    }
    let actual_session = identity["session"].as_str().unwrap_or_default();
    if expected_session.as_deref().is_some_and(|expected| actual_session != expected) {
        let message = crate::localization::catalog()
            .local_server
            .different_session
            .replace("{expected}", &session)
            .replace("{actual}", actual_session);
        return local_error("server.different_session", &message, global.output, 1);
    }

    match plan.action {
        ServerAction::Status => print_success(
            json!({
                "status":"running",
                "session":actual_session,
                "socket":socket,
                "pid":identity["pid"],
                "generation":identity["generation"],
                "message":crate::localization::catalog().local_server.running,
            }),
            global.output,
        ),
        ServerAction::ReloadConfig => {
            let result = match exchange(&mut connection, json!({"id":2,"cmd":"reload-config"})) {
                Ok(result) => result,
                Err(message) => {
                    return local_error("server.reload_failed", &message, global.output, 1);
                }
            };
            print_success(
                json!({
                    "reloaded":result["reloaded"].as_bool().unwrap_or(true),
                    "session":actual_session,
                    "warnings":result["warnings"].as_array().cloned().unwrap_or_default(),
                    "message":crate::localization::catalog().local_server.reloaded,
                }),
                global.output,
            )
        }
        ServerAction::Stop { force } => {
            let Some(pid) = identity["pid"].as_u64().and_then(|pid| u32::try_from(pid).ok()) else {
                return local_error(
                    "server.invalid_identity",
                    crate::localization::catalog().local_server.invalid_identity,
                    global.output,
                    3,
                );
            };
            let Some(generation) = identity["generation"].as_str() else {
                return local_error(
                    "server.invalid_identity",
                    crate::localization::catalog().local_server.invalid_identity,
                    global.output,
                    3,
                );
            };
            if force
                && !identity["capabilities"].as_array().is_some_and(|values| {
                    values.iter().any(|value| value == "daemon-handoff-force-v1")
                })
            {
                return local_error(
                    "server.force_unsupported",
                    crate::localization::catalog().local_server.force_unsupported,
                    global.output,
                    1,
                );
            }
            let result = match exchange(
                &mut connection,
                json!({
                    "id":2,
                    "cmd":"shutdown-daemon",
                    "pid":pid,
                    "generation":generation,
                    "force":force,
                }),
            ) {
                Ok(result) => result,
                Err(message) => {
                    return local_error("server.stop_failed", &message, global.output, 1);
                }
            };
            if let Err(message) = wait_for_close(&mut connection) {
                return local_error("server.stop_timeout", &message, global.output, 3);
            }
            print_success(
                json!({
                    "status":"stopped",
                    "accepted":result["accepted"].as_bool().unwrap_or(true),
                    "session":actual_session,
                    "pid":pid,
                    "generation":generation,
                    "message":crate::localization::catalog().local_server.stopped,
                }),
                global.output,
            )
        }
    }
}

fn exchange(
    connection: &mut BufReader<Box<dyn transport::Stream>>,
    request: Value,
) -> Result<Value, String> {
    writeln!(connection.get_mut(), "{request}")
        .and_then(|()| connection.get_mut().flush())
        .map_err(|error| format!("transport error: {error}"))?;
    loop {
        let mut line = String::new();
        match connection.read_line(&mut line) {
            Ok(0) => return Err("transport closed before response".to_string()),
            Ok(_) => {}
            Err(error) => return Err(format!("transport error: {error}")),
        }
        let response: Value = serde_json::from_str(&line)
            .map_err(|error| format!("protocol error: invalid response: {error}"))?;
        if response.get("event").is_some() || response["id"] != request["id"] {
            continue;
        }
        if response["ok"] == true {
            return Ok(response.get("data").cloned().unwrap_or(Value::Null));
        }
        return Err(response["error"].as_str().unwrap_or("server command failed").to_string());
    }
}

fn is_absent(error: &std::io::Error) -> bool {
    matches!(error.kind(), std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused)
}

fn wait_for_close(connection: &mut BufReader<Box<dyn transport::Stream>>) -> Result<(), String> {
    loop {
        let mut trailing = String::new();
        match connection.read_line(&mut trailing) {
            Ok(0) => return Ok(()),
            Ok(_) => {
                let event: Value = serde_json::from_str(&trailing).map_err(|_| {
                    crate::localization::catalog().local_server.unexpected_after_stop.to_string()
                })?;
                if event.get("event").is_some() {
                    continue;
                }
                return Err(crate::localization::catalog()
                    .local_server
                    .unexpected_after_stop
                    .to_string());
            }
            Err(error) => {
                return Err(crate::localization::catalog()
                    .local_server
                    .stop_timeout
                    .replace("{error}", &error.to_string()));
            }
        }
    }
}

fn usage_error(message: &str, output: OutputMode) -> i32 {
    local_error("usage.invalid", message, output, 2)
}

fn local_error(code: &str, message: &str, output: OutputMode, exit_code: i32) -> i32 {
    super::wire::print_local_error(
        &json!({"code":code,"message":message,"details":{},"retryable":false}),
        output,
        exit_code,
    )
}

fn print_success(value: Value, output: OutputMode) -> i32 {
    super::wire::print_local_success(&value, output)
}
