//! Pieces every app request shares, the CLI's and `cmux mcp`'s: the params
//! an `action.run` starts from, its idempotency key, and the busy retry.

use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use super::{ActionName, busy_retry_delay, request, retry_before_running};

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

/// The longest wait before one retry.
const MAX_RETRY_WAIT: Duration = Duration::from_secs(2);

/// The least time a not-run refusal is asked again for, whatever the request's own timeout: the app's
/// daemon connection takes this long to come back (`DaemonConnection.defaultRequestTimeout`), and a
/// refusal that says nothing ran costs only a wait, so a short read still outlasts a reconnecting
/// daemon instead of failing after a fixed count of tries.
pub(in crate::cli) const NOT_RUN_DEADLINE_FLOOR: Duration = Duration::from_secs(30);

/// How long [`request_with_retry`] keeps asking again after not-run refusals: the request's own
/// timeout, never less than [`NOT_RUN_DEADLINE_FLOOR`]. A request with no timeout gets the floor:
/// the hang breaker for an app that refuses forever, logged when it fires.
pub(in crate::cli) fn not_run_deadline(timeout: Option<Duration>) -> Duration {
    timeout.map_or(NOT_RUN_DEADLINE_FLOOR, |timeout| timeout.max(NOT_RUN_DEADLINE_FLOOR))
}

/// One request; an app that says the run never started and why it may pass
/// (`retry_before_running`) is asked again after the delay it names, doubled
/// each time up to [`MAX_RETRY_WAIT`], until [`not_run_deadline`] has passed.
/// The caller sees only the last answer; a refusal still standing at the
/// deadline is that answer, with a stderr line naming the wait.
pub(in crate::cli) fn request_with_retry(
    stream: &mut UnixStream,
    method: &str,
    params: &Value,
    timeout: impl Into<Option<Duration>>,
) -> Result<Result<Value, Value>, String> {
    let timeout = timeout.into();
    let deadline = not_run_deadline(timeout);
    let started = Instant::now();
    let mut retries = 0u32;
    loop {
        match request(stream, method, params.clone(), timeout)? {
            Err(error) if retry_before_running(&error) => {
                let wait = retry_wait(&error, retries);
                if started.elapsed() + wait > deadline {
                    eprintln!(
                        "cmux: {method}: the app still said nothing ran after {} ms of tries ({retries} retries); \
                         this is its answer",
                        started.elapsed().as_millis()
                    );
                    return Ok(Err(error));
                }
                std::thread::sleep(wait);
                retries += 1;
            }
            response => return Ok(response),
        }
    }
}

/// The wait before retry number `retries` (from 0): the app's `retry_after_ms`, doubled each time, at most
/// [`MAX_RETRY_WAIT`].
pub(in crate::cli) fn retry_wait(error: &Value, retries: u32) -> Duration {
    busy_retry_delay(error).saturating_mul(2u32.saturating_pow(retries.min(16))).min(MAX_RETRY_WAIT)
}

/// Whether a request may be sent again on a new connection after the app
/// dropped the first one: a read, or a run with its idempotency key (the app
/// replays a finished run and joins one still running).
pub(in crate::cli) fn safe_to_resend(method: &str, params: &Value) -> bool {
    super::is_retryable_read(method)
        || params.get("idempotency_key").and_then(Value::as_str).is_some()
}
