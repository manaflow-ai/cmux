//! The Chief's engine and turn stop: `cmux chief engine [--harness H]
//! [--model M] [--effort E]`, `cmux chief stop`, and the chat's `/model`,
//! `/effort` and Ctrl+C. They call `chief.engine.get`, `chief.engine.set`
//! and `chief.stop`, which only the owner's own connection may call.

use serde_json::{Map, Value, json};

use super::link::{Link, LinkError};
use super::messages::messages;
use super::{GlobalArgs, Session};
use crate::cli::OutputMode;

/// What `cmux chief engine|stop` asks.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) enum Control {
    /// Show the engine, or set the given fields (harness, model, effort).
    Engine(Vec<(String, String)>),
    Stop,
}

impl Session {
    /// The engine report after setting `changes` (none: just read it).
    pub(super) fn engine(&mut self, changes: &[(String, String)]) -> Result<Value, LinkError> {
        engine(&mut self.control, changes)
    }

    /// Stops the Chief's running turn; whether one was running.
    pub(super) fn stop(&mut self) -> Result<bool, LinkError> {
        stop(&mut self.control)
    }
}

fn engine(link: &mut Link, changes: &[(String, String)]) -> Result<Value, LinkError> {
    if changes.is_empty() {
        return link.call("chief.engine.get", json!({}), None);
    }
    let params: Map<String, Value> =
        changes.iter().map(|(k, v)| (k.clone(), Value::String(v.clone()))).collect();
    let key = super::link::new_message_id();
    let result = link.call("chief.engine.set", Value::Object(params), Some(&key))?;
    Ok(result.get("value").cloned().unwrap_or(Value::Null))
}

fn stop(link: &mut Link) -> Result<bool, LinkError> {
    let key = super::link::new_message_id();
    let result = link.call("chief.stop", json!({}), Some(&key))?;
    Ok(result.pointer("/value/stopped").and_then(Value::as_bool).unwrap_or(false))
}

/// One line for an engine report: `harness · model · effort`.
pub(super) fn engine_line(report: &Value) -> String {
    let engine = report.get("engine").unwrap_or(report);
    let text = |key: &str| {
        engine.get(key).and_then(Value::as_str).filter(|s| !s.is_empty()).unwrap_or("default")
    };
    format!("{} · {} · {}", text("harness"), text("model"), text("effort"))
}

/// The text of a control refusal: an old daemon, or the brain's own reason.
pub(super) fn refusal(error: &LinkError) -> String {
    match error {
        LinkError::Rejected { code, .. } if code.starts_with("validation.invalid") => {
            messages().control_unsupported.to_owned()
        }
        other => other.to_string(),
    }
}

/// `cmux chief engine|stop`: one call on the current session, no chat.
pub(super) fn run(global: &GlobalArgs, control: &Control, output: OutputMode) -> i32 {
    let socket = match super::super::wire::resolve_socket_with_origin(global) {
        Ok(socket) => socket,
        Err(_) => {
            eprintln!("cmux: {}", crate::localization::catalog().startup.invalid_session_name);
            return 2;
        }
    };
    let mut link = match Link::connect(&socket.0, socket.1) {
        Ok(link) => link,
        Err(error) => {
            eprintln!("{}", super::super::wire::connect_failure(&socket.0, &error));
            return 3;
        }
    };
    let answer = match control {
        Control::Engine(changes) => engine(&mut link, changes),
        Control::Stop => stop(&mut link).map(|stopped| json!({"stopped": stopped})),
    };
    match answer {
        Ok(value) if super::json_output(output) => {
            println!("{value}");
            0
        }
        Ok(value) => {
            let m = messages();
            match control {
                Control::Engine(_) => println!("{}", engine_line(&value)),
                Control::Stop if value["stopped"] == true => println!("{}", m.stop_sent),
                Control::Stop => println!("{}", m.stop_idle),
            }
            0
        }
        Err(LinkError::Transport(message)) => {
            eprintln!("cmux: {message}");
            3
        }
        Err(error) => {
            eprintln!("cmux: {}", refusal(&error));
            1
        }
    }
}
