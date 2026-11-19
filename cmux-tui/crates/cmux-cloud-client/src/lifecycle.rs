//! Typed, scoped I/O for Cloud machine lifecycle mutations.
//!
//! The wire client is deliberately sans-I/O at its operation layer. This
//! adapter supplies the missing boundary: a [`Machine`] is bound to the
//! backend and team that named it, the provider's status is parsed strictly,
//! and each mutation carries both the last observed revision and one stable
//! idempotency key. If the answer is lost, the consumed capability is returned
//! in [`Pending`] so the same intent can be retried without creating a second
//! mutation.

use cmux_cloud_wire::{
    CloudMachine, CloudMachineDeleteOp, CloudMachineDeleteParams, CloudMachinePauseOp,
    CloudMachinePauseParams, CloudMachineStartOp, CloudMachineStartParams,
};
use cmux_lifeline::vm::{
    Attached, Claimed, Deleted, Deleting, Failed, Observed, Paused, Pausing, Preclaimed,
    Provisioning, Ready, Running, Starting, Status, Stopped, Unknown, Vm,
};

use crate::machine::{HandleError, Machine, Scope};
use crate::ops::{self, Answer};
use crate::{ApiError, BuildError};

/// The identity and last owner revision carried by a lifecycle capability.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    machine: Machine,
    revision: String,
}

impl Snapshot {
    /// The scoped machine handle. The scope is never inferred again for an
    /// operation, so a handle cannot cross backends or teams accidentally.
    pub fn machine(&self) -> &Machine {
        &self.machine
    }

    /// The owner's revision used as the next mutation's precondition.
    pub fn revision(&self) -> &str {
        &self.revision
    }
}

/// A lifecycle capability whose state is enforced by [`cmux_lifeline`].
///
/// This local wrapper is where the transport methods live; the underlying
/// `Vm` remains owned by the shared lifeline crate and cannot be forged by a
/// client caller.
#[derive(Debug)]
pub struct Capability<S> {
    vm: Vm<S, Snapshot>,
}

impl<S> Capability<S> {
    fn payload(&self) -> &Snapshot {
        self.vm.payload()
    }

    /// The scoped machine handle.
    pub fn machine(&self) -> &Machine {
        self.payload().machine()
    }

    /// The last owner revision carried by this capability.
    pub fn revision(&self) -> &str {
        self.payload().revision()
    }
}

/// The result of strictly binding a provider observation to a scoped handle.
///
/// The raw lifeline observation is kept inside this adapter so callers cannot
/// bypass the Cloud client's scoped capability wrapper.
#[derive(Debug)]
pub enum ObservedMachine {
    Provisioning(Capability<Provisioning>),
    Running(Capability<Running>),
    Pausing(Capability<Pausing>),
    Paused(Capability<Paused>),
    Starting(Capability<Starting>),
    Stopped(Capability<Stopped>),
    Deleting(Capability<Deleting>),
    Deleted(Capability<Deleted>),
    Failed(Capability<Failed>),
    Unknown(Capability<Unknown>),
}

/// Why an observed Cloud machine could not become a lifecycle capability.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ObserveError {
    /// The provider returned a status outside the shared lifecycle vocabulary.
    InvalidStatus,
    /// The record did not carry a valid scoped machine id or origin.
    Handle(HandleError),
    /// A team-scoped credential was handed a record owned by another team.
    TeamMismatch { expected: String, actual: String },
}

impl std::fmt::Display for ObserveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidStatus => {
                f.write_str("the Cloud machine has an unrecognized lifecycle status")
            }
            Self::Handle(error) => error.fmt(f),
            Self::TeamMismatch { expected, actual } => {
                write!(f, "Cloud machine belongs to team {actual}, expected {expected}")
            }
        }
    }
}

impl std::error::Error for ObserveError {}

/// Bind one generated Cloud record at the provider boundary.
///
/// `CloudMachineStatus` is forward-compatible and therefore accepts an
/// `Unknown` variant. That is useful for display, but it must not grant a
/// lifecycle capability; parsing through the shared lifeline status rejects
/// it before any operation is available.
pub fn observe(scope: &Scope, record: CloudMachine) -> Result<ObservedMachine, ObserveError> {
    let status: Status = record.status.as_str().parse().map_err(|_| ObserveError::InvalidStatus)?;
    if let Some(expected) = scope.team() {
        if expected != record.team {
            return Err(ObserveError::TeamMismatch {
                expected: expected.to_owned(),
                actual: record.team,
            });
        }
    }
    let machine = scope.machine(&record.id).map_err(ObserveError::Handle)?;
    let snapshot = Snapshot { machine, revision: record.revision };
    Ok(match status.bind(snapshot) {
        Observed::Provisioning(vm) => ObservedMachine::Provisioning(Capability { vm }),
        Observed::Running(vm) => ObservedMachine::Running(Capability { vm }),
        Observed::Pausing(vm) => ObservedMachine::Pausing(Capability { vm }),
        Observed::Paused(vm) => ObservedMachine::Paused(Capability { vm }),
        Observed::Starting(vm) => ObservedMachine::Starting(Capability { vm }),
        Observed::Stopped(vm) => ObservedMachine::Stopped(Capability { vm }),
        Observed::Deleting(vm) => ObservedMachine::Deleting(Capability { vm }),
        Observed::Deleted(vm) => ObservedMachine::Deleted(Capability { vm }),
        Observed::Failed(vm) => ObservedMachine::Failed(Capability { vm }),
        Observed::Unknown(vm) => ObservedMachine::Unknown(Capability { vm }),
    })
}

/// The mutation intent retained when a response is refused or lost.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Intent {
    Pause,
    Resume,
    Delete,
}

/// The consumed capability and key for one mutation intent.
#[derive(Debug)]
pub struct Pending<S> {
    state: Capability<S>,
    intent: Intent,
    key: String,
}

impl<S> Pending<S> {
    fn new(state: Capability<S>, intent: Intent, key: String) -> Self {
        Self { state, intent, key }
    }

    /// The key to reuse when retrying this same intent.
    pub fn key(&self) -> &str {
        &self.key
    }

    /// The mutation that may be retried with [`Self::key`].
    pub fn intent(&self) -> Intent {
        self.intent
    }

    /// The revision that was sent as the optimistic-concurrency precondition.
    pub fn revision(&self) -> &str {
        self.state.payload().revision()
    }

    fn into_unknown(self) -> Pending<Unknown>
    where
        S: UncertainTransition,
    {
        let Pending { state, intent, key } = self;
        Pending { state: UncertainTransition::uncertain(state), intent, key }
    }
}

/// A local conversion used when a mutation answer is ambiguous. The shared
/// lifeline owns the same transition; this adapter only carries its snapshot
/// payload through the client wrapper.
trait UncertainTransition: Sized {
    fn uncertain(state: Capability<Self>) -> Capability<Unknown>;
}

macro_rules! uncertain_transition {
    ($($state:ty),+ $(,)?) => {
        $(
        impl UncertainTransition for $state {
            fn uncertain(state: Capability<Self>) -> Capability<Unknown> {
                Capability { vm: state.vm.uncertain() }
            }
        }
        )+
    };
}

uncertain_transition!(
    Provisioning,
    Preclaimed,
    Claimed,
    Running,
    Ready,
    Attached,
    Pausing,
    Paused,
    Starting,
    Stopped,
    Deleting,
    Failed,
);

impl UncertainTransition for Unknown {
    fn uncertain(state: Capability<Self>) -> Capability<Unknown> {
        state
    }
}

/// The authoritative observation and original mutation identity after an
/// ambiguous answer has been reconciled.
#[derive(Debug)]
pub struct Reconciled {
    observed: ObservedMachine,
    intent: Intent,
    key: String,
}

impl Reconciled {
    /// Consume the reconciliation result for typed state matching and retry.
    pub fn into_parts(self) -> (ObservedMachine, Intent, String) {
        (self.observed, self.intent, self.key)
    }
}

impl Pending<Unknown> {
    /// Reconcile this subject with a fresh authoritative Cloud record. No
    /// lifecycle action is available on `Unknown` until this succeeds.
    pub fn reconcile(self, record: CloudMachine) -> Result<Reconciled, ObserveError> {
        let scope = self.state.machine().scope().clone();
        let observed = observe(&scope, record)?;
        Ok(Reconciled { observed, intent: self.intent, key: self.key })
    }
}

/// A mutation failure that keeps the consumed capability available for a
/// deliberate retry or cleanup action.
#[derive(Debug)]
pub enum MutationError<S> {
    /// The request was refused before the provider could have committed it.
    Api { pending: Pending<S>, source: ApiError },
    /// The provider may have committed the mutation. The stable capability was
    /// consumed into `Unknown`; reconcile it before another live operation.
    Uncertain { pending: Pending<Unknown>, source: ApiError },
}

impl<S> MutationError<S> {
    /// The underlying transport or refusal error.
    pub fn source(&self) -> &ApiError {
        match self {
            Self::Api { source, .. } | Self::Uncertain { source, .. } => source,
        }
    }

    /// Consume the failure and recover either stable or uncertain state.
    pub fn into_parts(self) -> MutationErrorParts<S> {
        match self {
            Self::Api { pending, source } => MutationErrorParts::Api { pending, source },
            Self::Uncertain { pending, source } => {
                MutationErrorParts::Uncertain { pending, source }
            }
        }
    }
}

/// Owned state returned when consuming a [`MutationError`].
#[derive(Debug)]
pub enum MutationErrorParts<S> {
    /// The mutation was refused without an ambiguous provider outcome.
    Api { pending: Pending<S>, source: ApiError },
    /// The mutation may have committed and must be reconciled first.
    Uncertain { pending: Pending<Unknown>, source: ApiError },
}

impl<S> std::fmt::Display for MutationError<S> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Api { source, .. } | Self::Uncertain { source, .. } => source.fmt(f),
        }
    }
}

impl<S: std::fmt::Debug + 'static> std::error::Error for MutationError<S> {}

impl Pending<Running> {
    /// Retry the same pause intent with the same key after reconciling the
    /// uncertain answer.
    pub async fn retry_pause(
        self,
        client: &LifecycleClient,
    ) -> Result<Capability<Pausing>, MutationError<Running>> {
        if self.intent != Intent::Pause {
            return Err(MutationError::Api {
                pending: self,
                source: ApiError::unreadable("the pending intent is not pause"),
            });
        }
        let Pending { state, key, .. } = self;
        client.pause_impl(state, key).await
    }
}

impl Pending<Ready> {
    /// Retry the same pause intent with the same key after reconciling the
    /// uncertain answer.
    pub async fn retry_pause(
        self,
        client: &LifecycleClient,
    ) -> Result<Capability<Pausing>, MutationError<Ready>> {
        if self.intent != Intent::Pause {
            return Err(MutationError::Api {
                pending: self,
                source: ApiError::unreadable("the pending intent is not pause"),
            });
        }
        let Pending { state, key, .. } = self;
        client.pause_impl(state, key).await
    }
}

impl Pending<Paused> {
    /// Retry the same resume intent with the same key after reconciling the
    /// uncertain answer.
    pub async fn retry_resume(
        self,
        client: &LifecycleClient,
    ) -> Result<Capability<Starting>, MutationError<Paused>> {
        if self.intent != Intent::Resume {
            return Err(MutationError::Api {
                pending: self,
                source: ApiError::unreadable("the pending intent is not resume"),
            });
        }
        let Pending { state, key, .. } = self;
        client.resume_impl(state, key).await
    }
}

macro_rules! pending_delete_retry {
    ($($state:ty),+ $(,)?) => {
        $(
        impl Pending<$state> {
            /// Retry the same delete intent with the same key after
            /// reconciling the uncertain answer.
            pub async fn retry_delete(
                self,
                client: &LifecycleClient,
            ) -> Result<Capability<Deleted>, MutationError<$state>> {
                if self.intent != Intent::Delete {
                    return Err(MutationError::Api {
                        pending: self,
                        source: ApiError::unreadable("the pending intent is not delete"),
                    });
                }
                let Pending { state, key, .. } = self;
                client.delete_impl(state, key).await
            }
        }
        )+
    };
}

pending_delete_retry!(
    Provisioning,
    Preclaimed,
    Claimed,
    Running,
    Ready,
    Attached,
    Pausing,
    Paused,
    Starting,
    Stopped,
    Failed,
    Unknown,
);

fn mutation_error<S: UncertainTransition>(
    pending: Pending<S>,
    source: ApiError,
) -> MutationError<S> {
    // A transport failure, proxy/server failure, or malformed success answer
    // can occur after the provider accepted the mutation. Keep the original
    // identity and key, but consume its stable capability into Unknown.
    let ambiguous = source.status.is_none() || source.status.is_some_and(|status| status >= 500);
    if ambiguous {
        MutationError::Uncertain { pending: pending.into_unknown(), source }
    } else {
        MutationError::Api { pending, source }
    }
}

/// A wire-op transport bound to one backend and team scope.
#[derive(Debug, Clone)]
pub struct LifecycleClient {
    scope: Scope,
    http: reqwest::Client,
}

impl LifecycleClient {
    /// Build a client whose bearer and team header are fixed to `scope`.
    pub fn new(scope: Scope, bearer: &str, user_agent: &str) -> Result<Self, BuildError> {
        let (_, http) = crate::http(
            scope.origin(),
            Some(bearer),
            scope.team(),
            user_agent,
            crate::REQUEST_TIMEOUT,
        )?;
        Ok(Self { scope, http })
    }

    /// The scope used for every operation.
    pub fn scope(&self) -> &Scope {
        &self.scope
    }

    async fn pause_impl<S: UncertainTransition>(
        &self,
        state: Capability<S>,
        key: impl Into<String>,
    ) -> Result<Capability<Pausing>, MutationError<S>> {
        let key = key.into();
        let pending = Pending::new(state, Intent::Pause, key.clone());
        let machine = match self.scope.id_of(pending.state.payload().machine()) {
            Ok(machine) => machine.to_owned(),
            Err(source) => {
                return Err(MutationError::Api { pending, source: ApiError::unreadable(source) });
            }
        };
        let expected = pending.state.payload().machine().clone();
        let params = CloudMachinePauseParams { machine };
        let answer = match ops::call_with_options::<CloudMachinePauseOp>(
            &self.http,
            self.scope.origin(),
            params,
            Some(&key),
            None,
            Some(pending.revision()),
        )
        .await
        {
            Ok(answer) => answer,
            Err(source) => return Err(mutation_error(pending, source)),
        };
        let (record, revision) = match mutation_value(answer) {
            Ok(value) => value,
            Err(source) => return Err(mutation_error(pending, source)),
        };
        pause_response(&self.scope, &expected, record.machine, revision)
            .map_err(|source| mutation_error(pending, source))
    }

    async fn resume_impl(
        &self,
        state: Capability<Paused>,
        key: impl Into<String>,
    ) -> Result<Capability<Starting>, MutationError<Paused>> {
        let key = key.into();
        let pending = Pending::new(state, Intent::Resume, key.clone());
        let machine = match self.scope.id_of(pending.state.payload().machine()) {
            Ok(machine) => machine.to_owned(),
            Err(source) => {
                return Err(MutationError::Api { pending, source: ApiError::unreadable(source) });
            }
        };
        let expected = pending.state.payload().machine().clone();
        let params = CloudMachineStartParams { machine };
        let answer = match ops::call_with_options::<CloudMachineStartOp>(
            &self.http,
            self.scope.origin(),
            params,
            Some(&key),
            None,
            Some(pending.revision()),
        )
        .await
        {
            Ok(answer) => answer,
            Err(source) => return Err(mutation_error(pending, source)),
        };
        let (record, revision) = match mutation_value(answer) {
            Ok(value) => value,
            Err(source) => return Err(mutation_error(pending, source)),
        };
        resume_response(&self.scope, &expected, record.machine, revision)
            .map_err(|source| mutation_error(pending, source))
    }

    async fn delete_impl<S: DeleteTransition + UncertainTransition>(
        &self,
        state: Capability<S>,
        key: impl Into<String>,
    ) -> Result<Capability<Deleted>, MutationError<S>> {
        let key = key.into();
        let pending = Pending::new(state, Intent::Delete, key.clone());
        let machine = match self.scope.id_of(pending.state.payload().machine()) {
            Ok(machine) => machine.to_owned(),
            Err(source) => {
                return Err(MutationError::Api { pending, source: ApiError::unreadable(source) });
            }
        };
        let params = CloudMachineDeleteParams { machine };
        let answer = match ops::call_with_options::<CloudMachineDeleteOp>(
            &self.http,
            self.scope.origin(),
            params,
            Some(&key),
            None,
            Some(pending.revision()),
        )
        .await
        {
            Ok(answer) => answer,
            Err(source) => return Err(mutation_error(pending, source)),
        };
        let (_, revision) = match mutation_value(answer) {
            Ok(value) => value,
            Err(source) => return Err(mutation_error(pending, source)),
        };
        let mut vm = S::delete(pending.state).vm.deleted();
        vm.payload_mut().revision = revision;
        Ok(Capability { vm })
    }
}

fn mutation_value<T, E>(answer: Answer<T, E>) -> Result<(T, String), ApiError>
where
    E: cmux_cloud_wire::WireError,
{
    match answer {
        Answer::Value { value, revision, .. } => match revision {
            Some(revision) => Ok((value, revision)),
            None => Err(ApiError::unreadable("a mutation answer omitted its revision")),
        },
        Answer::Refused(error) => match Answer::<T, E>::Refused(error).into_result() {
            Err(source) => Err(source),
            Ok(_) => Err(ApiError::unreadable("refused answer carried a value")),
        },
    }
}

fn pause_response(
    scope: &Scope,
    expected: &Machine,
    record: CloudMachine,
    revision: String,
) -> Result<Capability<Pausing>, ApiError> {
    let observed = observe(scope, record).map_err(|error| ApiError::unreadable(error))?;
    match observed {
        ObservedMachine::Pausing(mut capability) if capability.machine() == expected => {
            capability.vm.payload_mut().revision = revision;
            Ok(capability)
        }
        ObservedMachine::Pausing(_) => {
            Err(ApiError::unreadable("a pause answer named another machine"))
        }
        _ => Err(ApiError::unreadable("a pause answer did not enter pausing")),
    }
}

fn resume_response(
    scope: &Scope,
    expected: &Machine,
    record: CloudMachine,
    revision: String,
) -> Result<Capability<Starting>, ApiError> {
    let observed = observe(scope, record).map_err(|error| ApiError::unreadable(error))?;
    match observed {
        ObservedMachine::Starting(mut capability) if capability.machine() == expected => {
            capability.vm.payload_mut().revision = revision;
            Ok(capability)
        }
        ObservedMachine::Starting(_) => {
            Err(ApiError::unreadable("a resume answer named another machine"))
        }
        _ => Err(ApiError::unreadable("a resume answer did not enter starting")),
    }
}

/// States from which the lifeline permits a delete. `Deleted` is deliberately
/// absent, so a second delete is rejected by the type checker.
trait DeleteTransition: Sized {
    fn delete(vm: Capability<Self>) -> Capability<Deleting>;
}

macro_rules! deletable {
    ($($state:ty),+ $(,)?) => {
        $(
        impl DeleteTransition for $state {
            fn delete(vm: Capability<Self>) -> Capability<Deleting> {
                Capability { vm: vm.vm.delete() }
            }
        }
        )+
    };
}

deletable!(
    Provisioning,
    Preclaimed,
    Claimed,
    Running,
    Ready,
    Attached,
    Pausing,
    Paused,
    Starting,
    Stopped,
    Failed,
    Unknown,
);

impl Capability<Running> {
    /// Record that the caller completed the agent readiness handshake.
    ///
    /// The Cloud provider only reports power state; callers must establish
    /// readiness through their own handshake before using this transition.
    pub fn ready(self) -> Capability<Ready> {
        Capability { vm: self.vm.ready() }
    }

    /// Pause a provider-running machine. The capability is consumed.
    pub async fn pause(
        self,
        client: &LifecycleClient,
        key: impl Into<String>,
    ) -> Result<Capability<Pausing>, MutationError<Running>> {
        client.pause_impl(self, key).await
    }

    /// Delete a provider-running machine.
    pub async fn delete(
        self,
        client: &LifecycleClient,
        key: impl Into<String>,
    ) -> Result<Capability<Deleted>, MutationError<Running>> {
        client.delete_impl(self, key).await
    }
}

impl Capability<Ready> {
    /// Pause a machine whose agent has completed readiness.
    pub async fn pause(
        self,
        client: &LifecycleClient,
        key: impl Into<String>,
    ) -> Result<Capability<Pausing>, MutationError<Ready>> {
        client.pause_impl(self, key).await
    }

    /// Delete a ready machine.
    pub async fn delete(
        self,
        client: &LifecycleClient,
        key: impl Into<String>,
    ) -> Result<Capability<Deleted>, MutationError<Ready>> {
        client.delete_impl(self, key).await
    }
}

impl Capability<Paused> {
    /// Resume a paused machine; readiness must be established again afterwards.
    pub async fn resume(
        self,
        client: &LifecycleClient,
        key: impl Into<String>,
    ) -> Result<Capability<Starting>, MutationError<Paused>> {
        client.resume_impl(self, key).await
    }

    /// Delete a paused machine.
    pub async fn delete(
        self,
        client: &LifecycleClient,
        key: impl Into<String>,
    ) -> Result<Capability<Deleted>, MutationError<Paused>> {
        client.delete_impl(self, key).await
    }
}

macro_rules! delete_methods {
    ($($state:ty),+ $(,)?) => {
        $(
        impl Capability<$state> {
            /// Delete this machine. The `Deleted` capability has no such method.
            pub async fn delete(
                self,
                client: &LifecycleClient,
                key: impl Into<String>,
            ) -> Result<Capability<Deleted>, MutationError<$state>> {
                client.delete_impl(self, key).await
            }
        }
        )+
    };
}

delete_methods!(
    Provisioning,
    Preclaimed,
    Claimed,
    Attached,
    Pausing,
    Starting,
    Stopped,
    Failed,
    Unknown
);

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_cloud_wire::{CloudMachine, CloudMachineStatus};
    use serde_json::json;

    fn scope() -> Scope {
        Scope::new("https://cloud-api.cmux.dev", Some("team_a")).expect("scope")
    }

    fn record(status: &str, revision: &str) -> CloudMachine {
        serde_json::from_value(json!({
            "id": "vm_test",
            "team": "team_a",
            "creator": "user_a",
            "name": null,
            "size": {"cpu": null, "memory_mb": null, "disk_mb": null},
            "status": status,
            "image": {"id": "img", "daemon_version": null},
            "host": null,
            "classic": false,
            "created_at": 0,
            "last_active_at": null,
            "idle_policy": {"idle_seconds": 0},
            "error": null,
            "revision": revision
        }))
        .expect("CloudMachine record")
    }

    #[test]
    fn provider_status_is_strict_at_the_capability_boundary() {
        let mut future = record("running", "7");
        future.status = CloudMachineStatus::Unknown("ready".to_owned());
        assert!(matches!(observe(&scope(), future), Err(ObserveError::InvalidStatus)));
    }

    #[test]
    fn a_record_from_another_team_is_refused_before_any_operation() {
        let mut other = record("running", "7");
        other.team = "team_b".to_owned();
        assert!(matches!(observe(&scope(), other), Err(ObserveError::TeamMismatch { .. })));
    }

    #[tokio::test]
    async fn a_foreign_capability_is_refused_before_the_request_is_sent() {
        let owner = scope();
        let other = Scope::new("https://cloud-api.cmux.dev", Some("team_b")).expect("scope");
        let client = LifecycleClient::new(other, "token", "test").expect("client");
        let ObservedMachine::Running(capability) =
            observe(&owner, record("running", "7")).expect("running")
        else {
            panic!("running status")
        };
        let error = capability.pause(&client, "ck_foreign").await.expect_err("foreign handle");
        let MutationErrorParts::Api { source, .. } = error.into_parts() else {
            panic!("a foreign handle is a local refusal")
        };
        assert_eq!(source.code.as_deref(), Some("cloud.client.unreadable"));
        assert!(source.status.is_none(), "the foreign handle was rejected locally");
    }

    #[test]
    fn a_mutation_answer_must_name_the_mutated_machine() {
        let expected = scope().machine("vm_test").expect("machine");
        let mut other = record("pausing", "8");
        other.id = "vm_other".to_owned();
        let error = pause_response(&scope(), &expected, other, "8".to_owned())
            .expect_err("identity mismatch");
        assert!(error.message.contains("another machine"));
    }

    #[tokio::test]
    async fn a_lost_mutation_answer_keeps_the_same_key_and_revision() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("listener");
        let origin = format!("http://{}", listener.local_addr().expect("address"));
        let (seen_tx, seen_rx) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                use tokio::io::AsyncReadExt;
                let mut request = Vec::new();
                let mut chunk = [0; 4096];
                loop {
                    let length = stream.read(&mut chunk).await.unwrap_or(0);
                    if length == 0 {
                        break;
                    }
                    request.extend_from_slice(&chunk[..length]);
                    let lower = String::from_utf8_lossy(&request).to_ascii_lowercase();
                    let complete = lower.find("\r\n\r\n").is_some_and(|headers_end| {
                        let body_length = lower[..headers_end]
                            .lines()
                            .find_map(|line| line.strip_prefix("content-length: "))
                            .and_then(|value| value.trim().parse::<usize>().ok())
                            .unwrap_or(0);
                        request.len() >= headers_end + 4 + body_length
                    });
                    if complete {
                        break;
                    }
                }
                let _ = seen_tx.send(String::from_utf8_lossy(&request).into_owned());
                drop(stream);
            }
        });
        let scope = Scope::new(&origin, Some("team_a")).expect("scope");
        let client = LifecycleClient::new(scope.clone(), "token", "test").expect("client");
        let observed = observe(&scope, record("running", "7")).expect("running");
        let ObservedMachine::Running(capability) = observed else { panic!("running status") };
        let error = capability.pause(&client, "ck_lost").await.expect_err("lost answer");
        let MutationErrorParts::Uncertain { pending, source } = error.into_parts() else {
            panic!("a lost answer must consume the stable capability")
        };
        assert_eq!(pending.key(), "ck_lost");
        assert_eq!(pending.revision(), "7");
        assert_eq!(pending.intent(), Intent::Pause);
        assert!(source.retryable, "a missing answer is safe to retry");
        let request = seen_rx.await.expect("request captured");
        assert!(request.contains("\"idempotency_key\":\"ck_lost\""));
        assert!(request.contains("\"expected_revision\":\"7\""));

        let (reconciled, intent, key) =
            pending.reconcile(record("pausing", "8")).unwrap().into_parts();
        assert_eq!(intent, Intent::Pause);
        assert_eq!(key, "ck_lost");
        assert!(matches!(reconciled, ObservedMachine::Pausing(_)));
    }
}
