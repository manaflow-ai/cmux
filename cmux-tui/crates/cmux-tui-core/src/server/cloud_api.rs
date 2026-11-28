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
//! carries its own idempotency key in `args`, as `cloud.runs.create` does). `cloud.runs.*` are the
//! daemon's own sandboxed Runs (`cloud_runs.rs`): a Cloud chat on a machine made for the task,
//! never a classic call (an incognito send's create is refused: `run_incognito_unavailable`). A refusal
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
            | Op::CloudVmAgentKeyCreate
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
            | Op::CloudOwnerGithubRepos
            | Op::CloudOwnerGithubConnect
            | Op::CloudOwnerOp
            | Op::CloudOwnerGithubComplete
            | Op::CloudOwnerGithubList
            | Op::CloudOwnerGithubCloneToken
            | Op::CloudOwnerSlack
            | Op::CloudOwnerSlackAwake
            | Op::CloudOwnerTurnCheckpoint
            | Op::CloudOwnerTurnRewind
            | Op::CloudOwnerTurns
            | Op::CloudPreviewsRefresh
            | Op::CloudPreviewsCreateLink
            | Op::CloudPreviewsRevokeLink
            | Op::CloudMachineIo
            | Op::CloudMachineChatAccess
            | Op::CloudMachineShareChat
            | Op::CloudMachineChiefStart
            | Op::CloudMachineChiefResize
            | Op::CloudMachineSetupDesktop
            | Op::CloudMachineFork
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
        // Only the verified app's own read may change the team layer: the `api` URL is the
        // caller's, so an agent or another local client could otherwise answer it.
        let app = super::apps::user_origin_allowed(mux, client);
        calls::start(mux, request, writer, app)
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

/// A `team.device.policy` read the verified app made through `cloud.owner.op` (the install
/// principal's `POST /v1/read`) becomes the settings owner's team layer (RFD 0211): the owner
/// enforces it in every effective read and saves it for the next start. An unmanaged answer
/// clears it; any other call, and a refused read, changes nothing. True when the layer was set.
#[cfg(unix)]
pub(super) fn learn_team_policy(
    mux: &Arc<Mux>,
    args: &serde_json::Map<String, serde_json::Value>,
    answer: &serde_json::Value,
) -> bool {
    let schema = cmux_config::Schema::embedded();
    let Some(layer) = cmux_config::TeamPolicyLayer::from_owner_op(args, answer, schema) else {
        return false;
    };
    match mux.settings_apply(cmux_config::Op::TeamPolicySet { layer }) {
        Ok(_) => true,
        Err(refusal) => {
            eprintln!("cmux-tui: team policy not applied: {refusal:?}");
            false
        }
    }
}

/// How often the daemon reads the team policy again, at most (RFD 0211).
#[cfg(unix)]
pub(super) const TEAM_POLICY_EVERY_SECS: u64 = 15 * 60;
/// When the daemon last read it (Unix seconds; 0: not yet since this daemon started).
#[cfg(unix)]
static TEAM_POLICY_READ_AT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Claims this read when the last one is `TEAM_POLICY_EVERY_SECS` old (or none ran yet).
#[cfg(unix)]
pub(super) fn team_policy_due(clock: &std::sync::atomic::AtomicU64, now: u64) -> bool {
    use std::sync::atomic::Ordering;
    clock
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |last| {
            (last == 0 || now.saturating_sub(last) >= TEAM_POLICY_EVERY_SECS).then_some(now.max(1))
        })
        .is_ok()
}

/// Whether `token` is an install token (`FeedInstallPrincipal.install(ofToken:)`: a JWT whose
/// payload has an `inst` claim). `team.device.policy` answers for the install principal only.
#[cfg(unix)]
pub(super) fn is_install_token(token: &str) -> bool {
    use base64::Engine as _;
    let mut parts = token.split('.');
    let (Some(_), Some(payload), Some(_), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return false;
    };
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
        .and_then(|claims| claims.get("inst").and_then(|inst| inst.as_str()).map(str::len))
        .is_some_and(|len| len > 0)
}

/// The arguments of the daemon's own `owner.op` read of `team.device.policy`.
#[cfg(unix)]
pub(super) fn team_policy_read_args(
    client_version: Option<&serde_json::Value>,
) -> serde_json::Map<String, serde_json::Value> {
    let mut args = serde_json::Map::new();
    args.insert("route".into(), "read".into());
    args.insert("body".into(), serde_json::json!({"op": "team.device.policy", "params": {}}));
    if let Some(version) = client_version {
        args.insert("client_version".into(), version.clone());
    }
    args
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
        app: bool,
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
            let learned = app && call.call == "owner.op" && {
                // The reply as the call answered it (a mutation's wraps it in `value`).
                let body = result.as_ref().ok().map(|reply| {
                    reply.get("value").filter(|_| operation.is_mutation()).unwrap_or(reply)
                });
                body.is_some_and(|body| super::learn_team_policy(&worker_mux, &call.args, body))
            };
            send_resource_response(&worker_writer, worker_id, operation, result);
            if app && !learned {
                read_team_policy(&worker_mux, &call);
            }
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

    /// RFD 0211: the app signs in and its feed calls `owner.op` with this Mac's install token; at
    /// most every `TEAM_POLICY_EVERY_SECS`, the daemon reads `team.device.policy` with that same
    /// request's credential (kept for no longer than this read) and applies the answer, so a
    /// policy the team changes reaches the settings owner without the app asking.
    fn read_team_policy(mux: &Arc<Mux>, call: &Request) {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| since.as_secs());
        if call.call != "owner.op"
            || !super::is_install_token(&call.credential)
            || !super::team_policy_due(&super::TEAM_POLICY_READ_AT, now)
        {
            return;
        }
        let mut read = call.clone();
        read.args = super::team_policy_read_args(call.args.get("client_version"));
        if let Ok(answer) = block_on(cmux_cloud_api::perform(&read, Zeroizing::new(Vec::new()))) {
            super::learn_team_policy(mux, &read.args, &answer);
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
        let result = if request.call.starts_with("runs.") {
            // The daemon's own sandboxed Runs (cloud_runs.rs): whose Run it is comes from the app's
            // signed-in account, never from this call; its credential is not used.
            super::super::cloud_runs::engine(mux).perform(&request.call, &request.args)
        } else {
            block_on(cmux_cloud_api::perform(request, key))
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
    /// One library call on a runtime of its own (this is a worker thread).
    fn block_on(future: impl Future<Output = Result<Value, Failure>>) -> Result<Value, Failure> {
        match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(runtime) => runtime.block_on(future),
            Err(e) => Err(Failure::Transport(e.to_string())),
        }
    }

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
