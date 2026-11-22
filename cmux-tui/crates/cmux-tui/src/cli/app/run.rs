//! Pieces every app request shares, the CLI's and `cmux mcp`'s: the params
//! an `action.run` starts from, its idempotency key, and the busy retry.

use std::os::unix::net::UnixStream;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{ActionName, BUSY_RETRIES, busy_before_running, busy_retry_delay, request};

/// The params every `action.run` starts from: the action, whether it is
/// named by its CLI name, `wait: true`, and who asked (`origin`). Only a run
/// with `focus: true` may move the app's focus, selection, shown workspace or
/// key window, unless the action's purpose is focus or the origin is `user`
/// (plans/cmux-next/OWNERSHIP-PRINCIPLES.md, "Clients are projections").
pub(in crate::cli) fn action_run_params(
    action: &str,
    name: ActionName,
    origin: &str,
) -> Map<String, Value> {
    let mut params = Map::new();
    params.insert("action".into(), json!(action));
    if name == ActionName::Cli {
        params.insert("cli".into(), json!(true));
    }
    params.insert("wait".into(), json!(true));
    params.insert("origin".into(), json!(origin));
    params
}

/// Gives an `action.run` its idempotency key: `given`, else a new one.
pub(in crate::cli) fn insert_run_key(
    params: &mut Value,
    given: Option<&str>,
) -> Result<String, String> {
    let key = match given {
        Some(key) => key.to_owned(),
        None => {
            super::super::command::random_prefixed("mutation").map_err(|error| error.to_string())?
        }
    };
    params["idempotency_key"] = json!(key);
    Ok(key)
}

/// One request; a `busy` app that says the run never started is asked again
/// after the delay it names, at most `BUSY_RETRIES` times.
pub(in crate::cli) fn request_with_retry(
    stream: &mut UnixStream,
    method: &str,
    params: &Value,
    timeout: impl Into<Option<Duration>>,
) -> Result<Result<Value, Value>, String> {
    let timeout = timeout.into();
    let mut retries = 0;
    loop {
        match request(stream, method, params.clone(), timeout)? {
            Err(error) if retries < BUSY_RETRIES && busy_before_running(&error) => {
                retries += 1;
                std::thread::sleep(busy_retry_delay(&error));
            }
            response => return Ok(response),
        }
    }
}
