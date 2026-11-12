//! `cloud.vm.*`, `cloud.runs.*`, `cloud.owner.*`, `cloud.previews.*` and `cloud.machine.io`
//! (capability `cloud-api-v1`): the Cloud API calls of the `cmux-cloud-api` crate as
//! `cmux.protocol/2` operations, for the app and the `cmux` CLI (`cmux cloud api`). Each
//! operation's wire name is `cloud.` and one name of `cmux_cloud_api::CALLS`.
//!
//! Fields (spec/resource-operations-v2.json): `api` (the API's base URL), `auth`
//! (`stack|owner|worker`), `access_token`, and optionally `refresh_token`, `team`, `app_version`,
//! `local_only` and `args` (the call's object). A `key_base64` (a person key) is refused: the app
//! streams `cloud.owner.acpmux_keyed_start`'s key to the API Worker itself, so the key never enters
//! a protocol line or this daemon. `cloud.machine.io`'s `args` may name `local_path`, a file of the app's in
//! its transfer folder, for a read or write too large for one request or answer
//! (`cmux_cloud_api::local_file`). The daemon keeps no
//! credential and grants none: the call runs with the request's own. Only a local socket client
//! may call, so a remote device cannot use the daemon to reach the Mac's loopback services.
//!
//! A read answers the call's body; a mutation answers it as a mutation result (revision `0`,
//! never replayed: the daemon keeps no ledger of Cloud calls, and a call that must not run twice
//! carries the Cloud API's own idempotency key in `args`, as `cloud.runs.create` does). A refusal
//! is `operation.failed` with `reason` the failure's kind (`timed_out`, `transport`, `no_backend`,
//! `http`, `plan_required`, `decoding`) and `extra.failure` the library's failure object; neither
//! credential is ever in it. Each call runs on a worker thread (32 at most; long polls, 16 at most
//! of those, so interactive calls always have 16). A long poll past its 16 waits in line, first
//! come first served, with no thread; an interactive call past 32 is `busy`.
//!
//! `args.deadline_ms` (taken out before the call runs) is how long the caller waits for the
//! answer; the app's SDK deadline is 30 s past it. The whole call, time in line included, is over
//! by then (`cmux_cloud_api::perform_by`): a waiting long poll that can no longer start in time
//! is `busy`, one that starts late is held shorter, no request outlives the deadline and a staged
//! write with no time left is aborted, never committed. Without it (the CLI) the deadline is the
//! call's longest (`cmux_cloud_api::longest`).

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
    use cmux_cloud_api::{Auth, Failure, Request};
    use serde_json::{Map, Value, json};
    use std::collections::VecDeque;
    use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, PoisonError};
    use std::time::{Duration, Instant};
    use zeroize::Zeroizing;

    /// The daemon's call slots.
    static SLOTS: Slots = Slots::new();
    /// Calls in flight at once (a sandboxed Run holds one for its whole task).
    pub(super) const MAX_WORKERS: usize = 32;
    /// Long polls in flight at once, of [`MAX_WORKERS`]: a hand-off follower holds one for each
    /// open hand-off, so without a cap of their own they could take every slot and leave the
    /// person's exec, file, preview, cancel and turn calls `busy`. The rest are always free for
    /// those.
    pub(super) const MAX_LONG_POLLS: usize = 16;

    /// The calls that hold a slot for as long as the server or the task does: a hand-off's wait
    /// (`owner.handoff_wait`), a Run's wait (`runs.wait`) and a sandboxed Run, followed to its end
    /// (`runs.sandbox`).
    pub(super) const fn long_poll(operation: ResourceOperation) -> bool {
        matches!(
            operation,
            ResourceOperation::CloudOwnerHandoffWait
                | ResourceOperation::CloudRunsWait
                | ResourceOperation::CloudRunsSandbox
        )
    }

    /// Long polls waiting for a slot at once, past which one more is `busy`.
    pub(super) const MAX_QUEUED_LONG_POLLS: usize = 256;

    /// What a call does with the slot it is given, or with the limit that refused it (`busy`).
    pub(super) type Job = Box<dyn FnOnce(Result<Slot, usize>) + Send>;

    /// The call slots: every call takes one of [`MAX_WORKERS`], and a long poll one of
    /// [`MAX_LONG_POLLS`] too. A long poll past its cap waits in line (no thread) and a freed
    /// slot goes to the oldest waiting one first, so followers that rearm at once never take
    /// every slot from a newer caller (review of #40104 at 43732a03). A waiting one that can no
    /// longer start in time for its caller's deadline (its `start_by`) is answered `busy` then, by
    /// the line's own timer, long before that deadline (review at d99396ad). An interactive call
    /// past [`MAX_WORKERS`] is `busy`; it never waits behind long polls.
    pub(super) struct Slots {
        state: Mutex<State>,
        changed: Condvar,
        timer: OnceLock<()>,
    }

    struct State {
        calls: usize,
        long_polls: usize,
        waiting: VecDeque<(Instant, Job)>,
    }

    /// A taken slot, given back when dropped (the call's thread ends, or never started).
    pub(super) struct Slot {
        slots: &'static Slots,
        long_poll: bool,
    }

    impl Slots {
        pub(super) const fn new() -> Self {
            Self {
                state: Mutex::new(State { calls: 0, long_polls: 0, waiting: VecDeque::new() }),
                changed: Condvar::new(),
                timer: OnceLock::new(),
            }
        }

        fn state(&self) -> MutexGuard<'_, State> {
            self.state.lock().unwrap_or_else(PoisonError::into_inner)
        }

        /// Runs `job` with a slot now, or (a long poll) once its turn in line comes, if that is
        /// by `start_by`; else `job` gets the limit it is past (`busy`).
        pub(super) fn admit(&'static self, long_poll: bool, start_by: Instant, job: Job) {
            let mut state = self.state();
            let free = state.calls < MAX_WORKERS
                && (!long_poll || (state.long_polls < MAX_LONG_POLLS && state.waiting.is_empty()));
            if free {
                state.calls = state.calls.saturating_add(1);
                if long_poll {
                    state.long_polls = state.long_polls.saturating_add(1);
                }
                drop(state);
                return job(Ok(Slot { slots: self, long_poll }));
            }
            let refused = if !long_poll {
                Some(MAX_WORKERS)
            } else if state.waiting.len() >= MAX_QUEUED_LONG_POLLS {
                Some(MAX_QUEUED_LONG_POLLS)
            } else if start_by <= Instant::now() {
                Some(MAX_LONG_POLLS)
            } else {
                None
            };
            if let Some(limit) = refused {
                drop(state);
                return job(Err(limit));
            }
            state.waiting.push_back((start_by, job));
            drop(state);
            self.changed.notify_all();
            self.timer.get_or_init(|| {
                // One timer thread for the line; without it a waiting call is still answered
                // when a slot frees.
                let _ = std::thread::Builder::new()
                    .name("cloud-api-line".into())
                    .spawn(move || self.time_line());
            });
        }

        /// Answers `busy` to every waiting call that could not start by `now` in time for its
        /// caller; how many it answered.
        pub(super) fn expire(&self, now: Instant) -> usize {
            let mut state = self.state();
            let (late, keep): (VecDeque<_>, VecDeque<_>) =
                std::mem::take(&mut state.waiting).into_iter().partition(|(by, _)| *by <= now);
            state.waiting = keep;
            drop(state);
            let count = late.len();
            for (_, job) in late {
                job(Err(MAX_LONG_POLLS));
            }
            count
        }

        /// The line's timer: wakes at the earliest `start_by` (or a change) and expires.
        fn time_line(&self) {
            loop {
                let now = Instant::now();
                self.expire(now);
                let state = self.state();
                let next = state.waiting.iter().map(|(by, _)| *by).min();
                // concurrency-allow: the line's own timer thread, waiting for the next start_by or a new waiting call.
                match next {
                    Some(by) => {
                        let wait = by.saturating_duration_since(Instant::now());
                        let _woken = self.changed.wait_timeout(state, wait);
                    }
                    None => {
                        let _woken = self.changed.wait(state);
                    }
                }
            }
        }
    }

    impl Drop for Slot {
        fn drop(&mut self) {
            let mut state = self.slots.state();
            state.calls = state.calls.saturating_sub(1);
            if self.long_poll {
                state.long_polls = state.long_polls.saturating_sub(1);
            }
            let now = Instant::now();
            let (mut ready, mut late) = (Vec::new(), Vec::new());
            while state.calls < MAX_WORKERS && state.long_polls < MAX_LONG_POLLS {
                let Some((by, job)) = state.waiting.pop_front() else { break };
                if by <= now {
                    late.push(job);
                    continue;
                }
                state.calls = state.calls.saturating_add(1);
                state.long_polls = state.long_polls.saturating_add(1);
                ready.push(job);
            }
            drop(state);
            for job in late {
                job(Err(MAX_LONG_POLLS));
            }
            for job in ready {
                job(Ok(Slot { slots: self.slots, long_poll: true }));
            }
        }
    }

    /// What a long poll keeps of its caller's deadline once it starts: the library's answer
    /// margin on a poll's request (15 s for a hand-off's wait, 10 s for a Run's).
    const POLL_MARGIN: Duration = Duration::from_secs(15);

    /// Whether `call` is a wait the daemon may shorten (the server answers it at its `timeoutMs`).
    fn shortens(call: &Request) -> bool {
        matches!(call.call.as_str(), "runs.wait" | "owner.handoff_wait")
    }

    /// The latest a long poll can start and still answer by `by`: a wait held at least 1 s, or
    /// a sandboxed Run's whole own time.
    pub(super) fn start_by(call: &Request, by: Instant) -> Instant {
        let need = if shortens(call) {
            POLL_MARGIN.saturating_add(Duration::from_secs(1))
        } else {
            cmux_cloud_api::own(call)
        };
        by.checked_sub(need).unwrap_or(by)
    }

    /// A wait that starts at `now` is held no longer than answers by `by`.
    pub(super) fn fit_poll(call: &mut Request, by: Instant, now: Instant) {
        if !shortens(call) {
            return;
        }
        let left = by.saturating_duration_since(now).saturating_sub(POLL_MARGIN);
        let left = i64::try_from(left.as_millis()).unwrap_or(i64::MAX);
        let held = call.args.get("timeoutMs").and_then(Value::as_i64).unwrap_or(left);
        call.args.insert("timeoutMs".into(), json!(held.min(left)));
    }

    /// The largest answer a call sends: what a `cmux.protocol/2` client reads (16 MiB), less
    /// room for the envelope.
    const MAX_REPLY_BYTES: usize = 16_711_680;

    /// Parses `request` and runs it on a worker thread, which sends the response.
    pub(super) fn start(
        mux: &Arc<Mux>,
        request: ParsedResourceRequest,
        writer: &MessageWriter,
    ) -> bool {
        let received = Instant::now();
        let id = request.envelope.id.clone();
        let operation = request.envelope.operation;
        let mut request = request;
        let (mut call, key, deadline) = match parse(operation, &mut request.fields) {
            Ok(parsed) => parsed,
            Err(error) => return send_resource_response(writer, id, operation, Err(error)),
        };
        let busy = move |limit: usize| {
            ResourceError::operation_failed(
                operation.wire_name(),
                "busy",
                json!({"limit": limit, "long_poll": long_poll(operation)}),
            )
        };
        let worker_mux = Arc::clone(mux);
        let worker_writer = writer.clone();
        let worker_id = id;
        // The slot goes with the thread's closure: given back when the call ends, or when the
        // thread cannot start (the closure is dropped then).
        // The call is over by its caller's deadline (`args.deadline_ms`, the CLI's: the call's
        // longest), time in line included.
        let by = deadline.map_or_else(
            || received.checked_add(cmux_cloud_api::longest(&call)),
            |ms| received.checked_add(Duration::from_millis(ms)),
        );
        let by = by.unwrap_or(received);
        let start_by = start_by(&call, by);
        let job: Job = Box::new(move |slot| {
            let slot = match slot {
                Ok(slot) => slot,
                Err(limit) => {
                    send_resource_response(&worker_writer, worker_id, operation, Err(busy(limit)));
                    return;
                }
            };
            fit_poll(&mut call, by, Instant::now());
            let refused_writer = worker_writer.clone();
            let refused_id = worker_id.clone();
            let spawned = std::thread::Builder::new().name("cloud-api".into()).spawn(move || {
                let _slot = slot;
                let result = answer(&worker_mux, operation, &call, key, by);
                send_resource_response(&worker_writer, worker_id, operation, result);
            });
            if spawned.is_err() {
                send_resource_response(
                    &refused_writer,
                    refused_id,
                    operation,
                    Err(busy(MAX_WORKERS)),
                );
            }
        });
        SLOTS.admit(long_poll(operation), start_by, job);
        true
    }

    fn invalid(field: &str, reason: &str) -> ResourceError {
        ResourceError::validation_invalid(Some(field), reason)
    }

    fn text(fields: &Map<String, Value>, name: &str) -> Option<String> {
        fields.get(name).and_then(Value::as_str).map(str::to_owned)
    }

    /// A parsed call: the library's request, its (empty) key and its caller's `deadline_ms`.
    type Parsed = (Request, Zeroizing<Vec<u8>>, Option<u64>);

    /// The library's request and an empty key (no key comes through the daemon). Errors never
    /// echo a field's value.
    pub(super) fn parse(
        operation: ResourceOperation,
        fields: &mut Map<String, Value>,
    ) -> Result<Parsed, ResourceError> {
        // The person key never goes through the daemon: the app streams it to the Worker itself
        // (review of #40104, F3). A key here is refused, and its text wiped.
        if let Some(key) = fields.remove("key_base64") {
            if let Value::String(text) = key {
                drop(Zeroizing::new(text));
            }
            return Err(invalid("key_base64", "the person key never goes through the daemon"));
        }
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
        let mut args = match fields.get("args") {
            None | Some(Value::Null) => Map::new(),
            Some(Value::Object(args)) => args.clone(),
            Some(_) => return Err(invalid("args", "args is an object")),
        };
        // The caller's deadline for the whole call, for the daemon only (never sent on).
        let deadline =
            match args.remove("deadline_ms") {
                None => None,
                Some(ms) => Some(ms.as_u64().ok_or_else(|| {
                    invalid("args", "args.deadline_ms is a count of milliseconds")
                })?),
            };
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
        Ok((request, Zeroizing::new(Vec::new()), deadline))
    }

    /// Runs one call on this thread: its result, or its refusal scrubbed of both credentials.
    fn answer(
        mux: &Mux,
        operation: ResourceOperation,
        request: &Request,
        key: Zeroizing<Vec<u8>>,
        by: Instant,
    ) -> Result<Value, ResourceError> {
        let result = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(runtime) => runtime.block_on(cmux_cloud_api::perform_by(request, key, by)),
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
