//! `cloud.<call>`: the Cloud API calls of `cmux_cloud_api` (`cloud.vm.resize`,
//! `cloud.runs.sandbox`, `cloud.owner.handoffs`, `cloud.previews.create_link`,
//! `cloud.machine.io`, …; every name of `cmux_cloud_api::CALLS` with `cloud.` before it) on the
//! daemon's local socket, for the app and the `cmux` CLI (`cmux cloud api`). The daemon keeps no
//! credential: each frame brings its own, the call runs on a worker thread, and the reply is the
//! call's answer.
//!
//! Frame: `{"id", "cmd": "cloud.<call>", "api", "auth": "stack|owner|worker", "access_token",
//! "refresh_token"?, "team"?, "app_version"?, "local_only"?, "args"?, "key_base64"?}`, where
//! `key_base64` is `cloud.owner.acpmux_keyed_start`'s person key (decoded into a buffer that is
//! wiped when the request drops it). `credential` stays the launch credential every frame may
//! carry, so the Cloud bearer is `access_token`.
//!
//! Reply: `{"id", "ok": true, "data": BODY}`, or `{"id", "ok": false, "error_code":
//! "cloud.<kind>", "error": TEXT, "failure": E}` with `E` the library's failure object
//! (`timed_out`, `transport`, `no_backend`, `http`, `plan_required`, `decoding`). A refusal never
//! carries either credential back. Only local socket clients (`ClientTransport::Unix`) may call:
//! a remote device must not use this daemon to reach the Mac's loopback services.

use super::{ClientTransport, MessageWriter, Mux};
use base64::Engine as _;
use cmux_cloud_api::{Auth, CALLS, Failure, Request};
use serde_json::{Map, Value, json};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use zeroize::Zeroizing;

/// `identify` advertises it: the daemon answers every `cloud.<call>` above.
pub(super) const CAPABILITY: &str = "cloud-api-v1";

const PREFIX: &str = "cloud.";
static WORKERS: AtomicUsize = AtomicUsize::new(0);
/// Calls in flight at once (a sandboxed Run holds one for its whole task).
const MAX_WORKERS: usize = 32;
/// The largest reply a call sends: the connection's control reserve, less room for its frame.
const MAX_REPLY_BYTES: usize = crate::REMOTE_SESSION_MESSAGE_MAX_BYTES.saturating_sub(64 * 1024);

/// One frame's fields.
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Frame {
    #[serde(default)]
    #[allow(dead_code, reason = "read as JSON before the frame is decoded")]
    id: Value,
    cmd: String,
    api: String,
    auth: Auth,
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    team: Option<String>,
    #[serde(default)]
    app_version: Option<String>,
    #[serde(default)]
    local_only: bool,
    #[serde(default)]
    args: Map<String, Value>,
    #[serde(default)]
    key_base64: Option<String>,
    /// The launch credential (an agent's identity), not a Cloud one.
    #[serde(default)]
    credential: Option<Value>,
}

/// The call `line` names, when it is a `cloud.<call>` frame this module serves (`cloud.repo.*`
/// and every other line answer none).
fn call_of(line: &str) -> Option<(&'static str, Value)> {
    if !line.contains("\"cloud.") {
        return None;
    }
    let value: Value = serde_json::from_str(line).ok()?;
    if value.get("protocol").is_some() {
        return None;
    }
    let call = value.get("cmd")?.as_str()?.strip_prefix(PREFIX)?;
    let call = CALLS.iter().copied().find(|known| *known == call)?;
    Some((call, value))
}

pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    line: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    let (call, value) = call_of(line)?;
    let id = value.get("id").cloned().unwrap_or(Value::Null);
    if !permitted(mux, client, &value) {
        return Some(
            writer
                .send_control(&json!({"id": id, "ok": false, "error_code": "remote_denied",
                    "error": "permission denied"}))
                .is_ok(),
        );
    }
    let (request, key) = match request(call, value) {
        Ok(parsed) => parsed,
        Err(message) => {
            return Some(
                writer
                    .send_control(&json!({"id": id, "ok": false, "error_code": "invalid_request",
                        "error": message}))
                    .is_ok(),
            );
        }
    };
    if WORKERS
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
            (n < MAX_WORKERS).then(|| n.saturating_add(1))
        })
        .is_err()
    {
        return Some(
            writer
                .send_control(&json!({"id": id, "ok": false, "error_code": "cloud.busy",
                    "error": "Cloud calls are busy. Retry after the current calls finish."}))
                .is_ok(),
        );
    }
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let spawned = std::thread::Builder::new().name("cloud-api".into()).spawn(move || {
        struct Done;
        impl Drop for Done {
            fn drop(&mut self) {
                WORKERS.fetch_sub(1, Ordering::AcqRel);
            }
        }
        let _done = Done;
        let reply = answer(worker_id, &request, key);
        let _ = worker_writer.send_control(&reply);
    });
    match spawned {
        Ok(_) => Some(true),
        Err(_) => {
            WORKERS.fetch_sub(1, Ordering::AcqRel);
            Some(
                writer
                    .send_control(&json!({"id": id, "ok": false, "error_code": "cloud.busy",
                        "error": "Retry the Cloud call; its worker could not start."}))
                    .is_ok(),
            )
        }
    }
}

/// A local socket client with a principal, and an agent's launch credential (when the frame
/// carries one) that the daemon accepts. The call itself grants nothing: it runs with the
/// credentials the frame brings.
fn permitted(mux: &Mux, client: u64, request: &Value) -> bool {
    if !matches!(mux.control_clients.transport_of(client), Some(ClientTransport::Unix))
        || mux.frame_principal(client).is_none()
    {
        return false;
    }
    let credential = match request.get("credential") {
        None => None,
        Some(Value::String(value)) if !value.is_empty() => Some(value.as_str()),
        Some(_) => return false,
    };
    mux.request_actor(super::origin_gate::connection_actor(mux, client), credential).is_ok()
}

/// The library's request and the keyed start's key from a frame. Errors never echo the frame.
fn request(call: &str, value: Value) -> Result<(Request, Zeroizing<Vec<u8>>), String> {
    let mut frame: Frame = serde_json::from_value(value)
        .map_err(|_| format!("{PREFIX}{call} takes api, auth, access_token and args"))?;
    debug_assert_eq!(frame.cmd.strip_prefix(PREFIX), Some(call));
    let encoded = Zeroizing::new(frame.key_base64.take().unwrap_or_default());
    let key = Zeroizing::new(
        base64::engine::general_purpose::STANDARD
            .decode(encoded.as_bytes())
            .map_err(|_| "key_base64 is not base64".to_owned())?,
    );
    let request = Request {
        call: call.to_owned(),
        api: frame.api.trim().to_owned(),
        auth: frame.auth,
        credential: frame.access_token.trim().to_owned(),
        refresh: frame.refresh_token.take(),
        team: frame.team.take(),
        app_version: frame.app_version.take(),
        local_only: frame.local_only,
        args: std::mem::take(&mut frame.args),
    };
    drop(frame.credential.take());
    Ok((request, key))
}

/// Runs one call on this thread and builds its reply.
fn answer(id: Value, request: &Request, key: Zeroizing<Vec<u8>>) -> Value {
    let result = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime.block_on(cmux_cloud_api::perform(request, key)),
        Err(e) => Err(Failure::Transport(e.to_string())),
    };
    reply(id, request, &result)
}

/// The reply for `result`; a refusal is scrubbed of both credentials.
fn reply(id: Value, request: &Request, result: &Result<Value, Failure>) -> Value {
    let too_large;
    let failure = match result {
        Ok(body) => {
            let reply = json!({"id": id, "ok": true, "data": body});
            // A reply over the connection's control reserve would close the connection: answer
            // the call's refusal instead (a machine file read past it is read in parts).
            let size = serde_json::to_vec(&reply).map_or(usize::MAX, |bytes| bytes.len());
            if size <= MAX_REPLY_BYTES {
                return reply;
            }
            too_large = Failure::Transport(format!(
                "the answer is larger than the daemon's reply limit ({MAX_REPLY_BYTES} bytes)"
            ));
            &too_large
        }
        Err(failure) => failure,
    };
    let text =
        json!({"id": id.clone(), "ok": false, "error_code": format!("{PREFIX}{}", failure.kind()),
        "error": failure.to_string(), "failure": failure.json()})
        .to_string();
    let refresh = request.refresh.as_deref().unwrap_or_default();
    let scrubbed = cmux_cloud_api::session::redact(&text, refresh, &request.credential);
    serde_json::from_str(&scrubbed).unwrap_or_else(|_| {
        json!({"id": id, "ok": false, "error_code": "cloud.transport",
            "error": "the Cloud API's refusal could not be read"})
    })
}

#[cfg(test)]
#[path = "cloud_api_tests.rs"]
mod tests;
