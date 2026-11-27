//! `cmux machine NAME ports [--json]`: the TCP ports listening on another of the person's
//! machines (one joined by sign-in), so a dev server just started there can be seen from here.
//!
//! The app names its acpmux (`agent.acpmux`); this asks that daemon over its own socket for
//! `_acpmux/machine_ports_call`, which it sends to the named machine's machine-call service over
//! the hub carrier, behind that machine's signed-in-machines grant (`machine_ports_relay.rs`).
//! The answer is port numbers only: `{"ports":[{"port":N}]}`. Nothing here changes state.
//!
//! Exit 0 with the list, 1 when the far machine or the relay refused, 3 when no app or acpmux
//! answered.

use std::path::Path;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{AppCommand, GlobalArgs, OutputMode, UsageError};

/// `agent.acpmux` on the app socket.
const APP_DEADLINE: Duration = Duration::from_secs(5);
/// acpmux ready, then the far machine's answer (its relay waits up to 15 s).
const CALL_DEADLINE: Duration = Duration::from_secs(25);

#[derive(Debug, PartialEq, Eq)]
pub(in crate::cli) struct Command {
    pub machine: String,
}

/// `args` is `machine NAME ports [--json]`; `None` for any other `machine` command (the mux
/// resource parser keeps those). `--json` is the global output flag, taken here too.
pub(super) fn parse(args: &[String]) -> Option<Result<AppCommand, UsageError>> {
    let words: Vec<&str> = args.iter().map(String::as_str).filter(|w| *w != "--json").collect();
    let ["machine", machine, "ports", rest @ ..] = words.as_slice() else { return None };
    if let Some(extra) = rest.first() {
        return Some(Err(UsageError::new(format!(
            "unexpected argument {extra:?}; usage: cmux machine NAME ports [--json]"
        ))));
    }
    if machine.trim().is_empty() || machine.starts_with('-') {
        return Some(Err(UsageError::new("usage: cmux machine NAME ports [--json]")));
    }
    Some(Ok(AppCommand::MachinePorts(Command { machine: (*machine).to_owned() })))
}

fn failure(code: &str, message: impl Into<String>, output: OutputMode, exit: i32) -> i32 {
    let error = json!({"code": code, "message": message.into(), "details": {}, "retryable": false});
    super::super::wire::print_local_error(&error, output, exit)
}

pub(super) fn run(global: &GlobalArgs, command: &Command) -> i32 {
    let mut stream = match super::connect_command(global) {
        Ok(stream) => stream,
        Err(error) => return super::super::wire::print_local_error(&error, global.output, 3),
    };
    let socket = match super::exchange(&mut stream, "agent.acpmux", json!({}), APP_DEADLINE) {
        Ok(Ok(answer)) => {
            answer["socket_path"].as_str().filter(|p| !p.is_empty()).map(String::from)
        }
        Ok(Err(error)) => return super::super::wire::print_local_error(&error, global.output, 3),
        Err(message) => return failure("app.transport", message, global.output, 3),
    };
    drop(stream);
    let Some(socket) = socket else {
        return failure("acpmux.none", "the app named no acpmux socket", global.output, 3);
    };
    match ask(Path::new(&socket), &command.machine) {
        Ok(answer) => {
            let shaped = shape(&answer);
            match global.output {
                OutputMode::Human => {
                    print!("{}", human(&command.machine, &shaped));
                    0
                }
                _ => super::super::wire::print_local_success(&shaped, global.output),
            }
        }
        Err(Failure::Daemon(code, message)) => failure(code, message, global.output, 3),
        Err(Failure::Refused(error)) => {
            let code = error["data"]["code"]
                .as_str()
                .or_else(|| error["data"]["reason"].as_str())
                .unwrap_or("machine.refused")
                .to_owned();
            let message = error["message"].as_str().unwrap_or("refused").to_owned();
            failure(&code, message, global.output, 1)
        }
    }
}

/// `{"ports":[{"port":N}]}` from the far answer: port numbers only, distinct and sorted, whatever
/// else a newer machine adds.
pub(super) fn shape(answer: &Value) -> Value {
    let mut ports: Vec<u64> = answer["ports"]
        .as_array()
        .map(|list| {
            list.iter().filter_map(|p| p["port"].as_u64()).filter(|p| *p <= 65535).collect()
        })
        .unwrap_or_default();
    ports.sort_unstable();
    ports.dedup();
    json!({"ports": ports.into_iter().map(|port| json!({"port": port})).collect::<Vec<_>>()})
}

fn human(machine: &str, shaped: &Value) -> String {
    let ports: Vec<String> = shaped["ports"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|p| p["port"].as_u64())
        .map(|p| p.to_string())
        .collect();
    if ports.is_empty() {
        format!("{machine}: no TCP port is listening\n")
    } else {
        format!("{machine}: {}\n", ports.join(" "))
    }
}

enum Failure {
    /// This machine's acpmux did not answer.
    Daemon(&'static str, String),
    /// It, or the far machine, answered with an error.
    Refused(Value),
}

fn ask(socket: &Path, machine: &str) -> Result<Value, Failure> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| Failure::Daemon("acpmux.runtime", error.to_string()))?;
    let until = Instant::now() + CALL_DEADLINE;
    runtime.block_on(async {
        let work = async {
            let client = acpmux::client::Client::connect_without_caller(socket)
                .await
                .map_err(|error| Failure::Daemon("acpmux.connect", format!("{error:#}")))?;
            loop {
                let status = client
                    .request(acpmux::rpc::method::MUX_STATUS, json!({}))
                    .await
                    .map_err(|error| Failure::Daemon("acpmux.status", format!("{error:#}")))?;
                if status["ready"] != Value::Bool(false) {
                    break;
                }
                if Instant::now() >= until {
                    return Err(Failure::Daemon(
                        "acpmux.not_ready",
                        "acpmux never said ready".into(),
                    ));
                }
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
            client
                .request(acpmux::rpc::method::MUX_MACHINE_PORTS_CALL, json!({"machine": machine}))
                .await
                .map_err(|error| Failure::Refused(error_value(&error)))
        };
        match tokio::time::timeout(CALL_DEADLINE, work).await {
            Ok(result) => result,
            Err(_) => Err(Failure::Daemon(
                "deadline",
                format!("no answer from {machine:?} in {} s", CALL_DEADLINE.as_secs()),
            )),
        }
    })
}

/// The RPC error's `{code, message, data}`, when the client kept it; its text otherwise.
fn error_value(error: &anyhow::Error) -> Value {
    if let Some(acpmux::client::DaemonError(rpc)) = error.downcast_ref() {
        return rpc.to_value();
    }
    json!({"message": format!("{error:#}")})
}

#[cfg(test)]
#[path = "machine_ports/tests.rs"]
mod tests;
