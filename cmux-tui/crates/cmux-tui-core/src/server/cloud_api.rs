//! `cloud.vm.*`, `cloud.runs.*`, `cloud.owner.*`, `cloud.previews.*` and `cloud.machine.io`
//! (capability `cloud-api-v1`): the Cloud API calls of the `cmux-cloud-api` crate as
//! `cmux.protocol/2` operations, for the app and the `cmux` CLI (`cmux cloud api`). Each
//! operation's wire name is `cloud.` and one name of `cmux_cloud_api::CALLS`.
//!
//! Fields (spec/resource-operations-v2.json): `api` (the API's base URL), `auth`
//! (`stack|owner|worker`), `access_token`, and optionally `refresh_token`, `team`, `app_version`,
//! `local_only`, `args` (the call's object) and `key_base64` (`cloud.owner.acpmux_keyed_start`'s
//! person key, decoded into a buffer the request body owns and wipes). The daemon keeps no
//! credential and grants none: the call runs with the request's own. Only a local socket client
//! may call, so a remote device cannot use the daemon to reach the Mac's loopback services.
//!
//! A read answers the call's body; a mutation answers it as a mutation result (revision `0`,
//! never replayed: the daemon keeps no ledger of Cloud calls, and a call that must not run twice
//! carries the Cloud API's own idempotency key in `args`, as `cloud.runs.create` does). A refusal
//! is `operation.failed` with `reason` the failure's kind (`timed_out`, `transport`, `no_backend`,
//! `http`, `plan_required`, `decoding`) and `extra.failure` the library's failure object; neither
//! credential is ever in it. Each call runs on a worker thread (32 at most).

use super::{MessageWriter, Mux, ResourceOperation, send_resource_response};
use crate::resource_router::ParsedResourceRequest;
use std::sync::Arc;

use ResourceOperation as Op;

/// `identify` advertises it: the daemon answers every operation of [`handles`].
pub(super) const CAPABILITY: &str = "cloud-api-v1";

/// Whether `operation` is one of this module's.
pub(super) const fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        Op::CloudVmScpEndpoint
            | Op::CloudVmTunnelEnroll
            | Op::CloudVmTunnelRevoke
            | Op::CloudVmTunnelAttach
            | Op::CloudVmTunnelDetach
            | Op::CloudVmTunnelRotateKey
            | Op::CloudVmFirewallList
            | Op::CloudVmFirewallGet
            | Op::CloudVmFirewallCreate
            | Op::CloudVmFirewallDelete
            | Op::CloudVmNetworks
            | Op::CloudVmDomains
            | Op::CloudVmPublications
            | Op::CloudVmProvisionApi
            | Op::CloudVmPublicationApiKeys
            | Op::CloudVmRevokePublicationApiKey
            | Op::CloudRunsCreate
            | Op::CloudRunsStart
            | Op::CloudRunsWait
            | Op::CloudRunsCancel
            | Op::CloudRunsSandbox
            | Op::CloudOwnerAcpmuxPersonHolds
            | Op::CloudOwnerAcpmuxKeyedStart
            | Op::CloudOwnerForkRun
            | Op::CloudOwnerHandoffWait
            | Op::CloudOwnerHandoffs
            | Op::CloudOwnerHandoffOpen
            | Op::CloudOwnerHandoffBeginTurn
            | Op::CloudOwnerHarnessLoginCopy
            | Op::CloudOwnerGithubApp
            | Op::CloudOwnerTurnCheckpoint
            | Op::CloudOwnerTurnRewind
            | Op::CloudOwnerTurns
            | Op::CloudPreviewsRefresh
            | Op::CloudPreviewsCreateLink
            | Op::CloudPreviewsRevokeLink
            | Op::CloudMachineIo
    )
}
pub(super) fn handle(
    mux: &Arc<Mux>,
    client: u64,
    request: ParsedResourceRequest,
    writer: &MessageWriter,
) -> bool {
    let id = request.envelope.id.clone();
    let operation = request.envelope.operation;
    if let Err(error) = super::resource_trust::trusted_local_resource_client(mux, client, operation)
    {
        return send_resource_response(writer, id, operation, Err(error));
    }
    #[cfg(unix)]
    {
        calls::start(mux, request, writer)
    }
    #[cfg(not(unix))]
    {
        let _ = request;
        let error = super::ResourceError::operation_failed(
            operation.wire_name(),
            "unsupported",
            serde_json::json!({"platform": std::env::consts::OS}),
        );
        send_resource_response(writer, id, operation, Err(error))
    }
}

#[cfg(unix)]
mod calls {
    use super::super::{
        MessageWriter, Mux, ResourceError, ResourceOperation, send_resource_response,
    };
    use crate::resource_router::ParsedResourceRequest;
    use base64::Engine as _;
    use cmux_cloud_api::{Auth, Failure, Request};
    use serde_json::{Map, Value, json};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use zeroize::Zeroizing;

    static WORKERS: AtomicUsize = AtomicUsize::new(0);
    /// Calls in flight at once (a sandboxed Run holds one for its whole task).
    const MAX_WORKERS: usize = 32;
    /// The largest answer a call sends: what a `cmux.protocol/2` client reads (16 MiB), less
    /// room for the envelope.
    const MAX_REPLY_BYTES: usize = 16_711_680;

    /// Parses `request` and runs it on a worker thread, which sends the response.
    pub(super) fn start(
        mux: &Arc<Mux>,
        request: ParsedResourceRequest,
        writer: &MessageWriter,
    ) -> bool {
        let id = request.envelope.id.clone();
        let operation = request.envelope.operation;
        let (call, key) = match parse(operation, &request.fields) {
            Ok(parsed) => parsed,
            Err(error) => return send_resource_response(writer, id, operation, Err(error)),
        };
        if WORKERS
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                (n < MAX_WORKERS).then(|| n.saturating_add(1))
            })
            .is_err()
        {
            let error = ResourceError::operation_failed(
                operation.wire_name(),
                "busy",
                json!({"limit": MAX_WORKERS}),
            );
            return send_resource_response(writer, id, operation, Err(error));
        }
        let worker_mux = Arc::clone(mux);
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
            let result = answer(&worker_mux, operation, &call, key);
            send_resource_response(&worker_writer, worker_id, operation, result);
        });
        match spawned {
            Ok(_) => true,
            Err(_) => {
                WORKERS.fetch_sub(1, Ordering::AcqRel);
                let error = ResourceError::operation_failed(
                    operation.wire_name(),
                    "busy",
                    json!({"limit": MAX_WORKERS}),
                );
                send_resource_response(writer, id, operation, Err(error))
            }
        }
    }

    fn invalid(field: &str, reason: &str) -> ResourceError {
        ResourceError::validation_invalid(Some(field), reason)
    }

    fn text(fields: &Map<String, Value>, name: &str) -> Option<String> {
        fields.get(name).and_then(Value::as_str).map(str::to_owned)
    }

    /// The library's request and the keyed start's key. Errors never echo a field's value.
    pub(super) fn parse(
        operation: ResourceOperation,
        fields: &Map<String, Value>,
    ) -> Result<(Request, Zeroizing<Vec<u8>>), ResourceError> {
        let call = operation
            .wire_name()
            .strip_prefix("cloud.")
            .filter(|call| cmux_cloud_api::CALLS.contains(call))
            .ok_or_else(|| invalid("operation", "not a Cloud API call"))?;
        let auth: Auth = fields
            .get("auth")
            .cloned()
            .and_then(|auth| serde_json::from_value(auth).ok())
            .ok_or_else(|| invalid("auth", "auth is stack, owner or worker"))?;
        let api = text(fields, "api").ok_or_else(|| invalid("api", "api is the API's base URL"))?;
        let credential = text(fields, "access_token")
            .map(|token| token.trim().to_owned())
            .filter(|token| !token.is_empty())
            .ok_or_else(|| invalid("access_token", "access_token is required"))?;
        let args = match fields.get("args") {
            None | Some(Value::Null) => Map::new(),
            Some(Value::Object(args)) => args.clone(),
            Some(_) => return Err(invalid("args", "args is an object")),
        };
        let encoded = Zeroizing::new(text(fields, "key_base64").unwrap_or_default());
        let key = Zeroizing::new(
            base64::engine::general_purpose::STANDARD
                .decode(encoded.as_bytes())
                .map_err(|_| invalid("key_base64", "key_base64 is not base64"))?,
        );
        let request = Request {
            call: call.to_owned(),
            api: api.trim().to_owned(),
            auth,
            credential,
            refresh: text(fields, "refresh_token"),
            team: text(fields, "team"),
            app_version: text(fields, "app_version"),
            local_only: fields.get("local_only").and_then(Value::as_bool).unwrap_or(false),
            args,
        };
        Ok((request, key))
    }

    /// Runs one call on this thread: its result, or its refusal scrubbed of both credentials.
    fn answer(
        mux: &Mux,
        operation: ResourceOperation,
        request: &Request,
        key: Zeroizing<Vec<u8>>,
    ) -> Result<Value, ResourceError> {
        let result = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(runtime) => runtime.block_on(cmux_cloud_api::perform(request, key)),
            Err(e) => Err(Failure::Transport(e.to_string())),
        };
        let result = result.and_then(|body| {
            let size = serde_json::to_vec(&body).map_or(usize::MAX, |bytes| bytes.len());
            if size <= MAX_REPLY_BYTES {
                Ok(body)
            } else {
                Err(Failure::Transport(format!(
                    "the answer is larger than the reply limit ({MAX_REPLY_BYTES} bytes)"
                )))
            }
        });
        match result {
            Ok(body) if operation.is_mutation() => {
                let (_, generation) = mux.registry_identity();
                Ok(json!({"value": body, "generation": generation, "revision": "0",
                    "replayed": false}))
            }
            Ok(body) => Ok(body),
            Err(failure) => Err(refusal(operation, request, &failure)),
        }
    }

    /// `operation.failed` for `failure`, with neither credential in it.
    pub(super) fn refusal(
        operation: ResourceOperation,
        request: &Request,
        failure: &Failure,
    ) -> ResourceError {
        let refresh = request.refresh.as_deref().unwrap_or_default();
        let scrub =
            |text: &str| cmux_cloud_api::session::redact(text, refresh, &request.credential);
        let detail = scrub(&failure.json().to_string());
        let detail = serde_json::from_str::<Value>(&detail)
            .unwrap_or_else(|_| json!({"kind": failure.kind()}));
        let mut error = ResourceError::operation_failed(
            operation.wire_name(),
            failure.kind(),
            json!({"failure": detail}),
        );
        error.message = scrub(&failure.to_string());
        error
    }
}

#[cfg(all(test, unix))]
#[path = "cloud_api_tests.rs"]
mod tests;
