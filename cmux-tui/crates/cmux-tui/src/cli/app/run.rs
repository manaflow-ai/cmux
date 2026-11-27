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

/// The shortest wait between not-run retries, whatever `retry_after_ms` says.
const MIN_RETRY_WAIT: Duration = Duration::from_millis(10);
/// The longest wait before one retry.
const MAX_RETRY_WAIT: Duration = Duration::from_secs(2);

/// The least time a not-run refusal is asked again for, whatever the request's own timeout: the app's
/// daemon connection takes this long to come back (`DaemonConnection.defaultRequestTimeout`), and a
/// refusal that says nothing ran costs only a wait, so a short read still outlasts a reconnecting
/// daemon instead of failing after a fixed count of tries.
pub(in crate::cli) const NOT_RUN_DEADLINE_FLOOR: Duration = Duration::from_secs(30);

/// How long [`request_with_retry`] keeps asking again after not-run refusals: the request's own
/// timeout, never less than [`NOT_RUN_DEADLINE_FLOOR`]. A request with no timeout gets the floor:
/// the hang breaker for an app that refuses forever, named in the refusal it ends with (`not_run_waited_ms`).
/// A test build reads `CMUX_TEST_NOT_RUN_DEADLINE_MS` instead (a release build ignores it), so a test of an app that
/// refuses forever ends in milliseconds.
pub(in crate::cli) fn not_run_deadline(timeout: Option<Duration>) -> Duration {
    #[cfg(debug_assertions)]
    if let Some(ms) = std::env::var("CMUX_TEST_NOT_RUN_DEADLINE_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
    {
        return Duration::from_millis(ms);
    }
    timeout.map_or(NOT_RUN_DEADLINE_FLOOR, |timeout| timeout.max(NOT_RUN_DEADLINE_FLOOR))
}

/// One request; an app that did not get to it for a cause that passes
/// (`retry_before_running`; never a refusal the app decided) is asked again after the delay it names, doubled
/// each time up to [`MAX_RETRY_WAIT`], until [`not_run_deadline`] from now.
/// The caller sees only the last answer.
pub(in crate::cli) fn request_with_retry(
    stream: &mut UnixStream,
    method: &str,
    params: &Value,
    timeout: impl Into<Option<Duration>>,
) -> Result<Result<Value, Value>, String> {
    let timeout = timeout.into();
    request_with_retry_until(
        stream,
        method,
        params,
        timeout,
        Instant::now() + not_run_deadline(timeout),
    )
}

/// [`request_with_retry`] for a caller with its own shorter budget (an MCP tool call, which its client times
/// out): not-run refusals are asked again only until `timeout` from now, never the
/// [`NOT_RUN_DEADLINE_FLOOR`] a person's command waits.
pub(in crate::cli) fn request_with_retry_within(
    stream: &mut UnixStream,
    method: &str,
    params: &Value,
    timeout: Duration,
) -> Result<Result<Value, Value>, String> {
    let budget = timeout.min(not_run_deadline(Some(timeout)));
    request_with_retry_until(stream, method, params, Some(timeout), Instant::now() + budget)
}

/// [`request_with_retry`] against one absolute `deadline` that a caller's reconnects share. The last wait is cut
/// to what is left of the deadline, so the last try comes at it, never a backoff early. A refusal still standing at
/// the deadline is the answer, with `data.not_run_waited_ms` naming how long it was asked again (the hang
/// breaker's log, in the error a `--json` caller already reads).
pub(in crate::cli) fn request_with_retry_until(
    stream: &mut UnixStream,
    method: &str,
    params: &Value,
    timeout: Option<Duration>,
    deadline: Instant,
) -> Result<Result<Value, Value>, String> {
    let started = Instant::now();
    let mut retries = 0u32;
    loop {
        match request(stream, method, params.clone(), timeout)? {
            Err(mut error) if retry_before_running(&error) => {
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    if let Some(data) = error.get_mut("data").and_then(Value::as_object_mut) {
                        data.insert(
                            "not_run_waited_ms".into(),
                            json!(started.elapsed().as_millis()),
                        );
                        data.insert("not_run_retries".into(), json!(retries));
                    }
                    return Ok(Err(error));
                }
                std::thread::sleep(retry_wait(&error, retries).min(left));
                retries += 1;
            }
            response => return Ok(response),
        }
    }
}

/// The wait before retry number `retries` (from 0): the app's `retry_after_ms`, doubled each time, at most
/// [`MAX_RETRY_WAIT`].
pub(in crate::cli) fn retry_wait(error: &Value, retries: u32) -> Duration {
    // A floor keeps an app that asks for 0 ms from turning the wait into a spin.
    busy_retry_delay(error)
        .max(MIN_RETRY_WAIT)
        .saturating_mul(2u32.saturating_pow(retries.min(16)))
        .min(MAX_RETRY_WAIT)
}

/// Whether a request may be sent again on a new connection after the app
/// dropped the first one: a read, or a run with its idempotency key (the app
/// replays a finished run and joins one still running).
pub(in crate::cli) fn safe_to_resend(method: &str, params: &Value) -> bool {
    super::is_retryable_read(method)
        || params.get("idempotency_key").and_then(Value::as_str).is_some()
}
