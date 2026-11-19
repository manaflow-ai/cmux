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
pub type ObservedMachine = Observed<Snapshot>;

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
    Ok(status.bind(Snapshot { machine, revision: record.revision }))
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

    /// Recover the capability and key for a retry. The caller chooses the
    /// operation method matching [`Self::intent`].
    pub fn into_parts(self) -> (Capability<S>, String) {
        (self.state, self.key)
    }
}

/// A mutation failure that keeps the consumed capability available for a
/// deliberate retry or cleanup action.
#[derive(Debug)]
pub enum MutationError<S> {
    /// The request was refused, unreadable, or got no answer. The same key is
    /// safe to retry when `source.retryable` is true; it is always retained so
    /// an indeterminate network outcome cannot silently lose the handle.
    Api { pending: Pending<S>, source: ApiError },
}

impl<S> MutationError<S> {
    /// The retained mutation and its source error.
    pub fn parts(&self) -> (&Pending<S>, &ApiError) {
        match self {
            Self::Api { pending, source } => (pending, source),
        }
    }

    /// Consume the failure and recover the retryable operation state.
    pub fn into_parts(self) -> (Pending<S>, ApiError) {
        match self {
            Self::Api { pending, source } => (pending, source),
        }
    }
}

impl<S> std::fmt::Display for MutationError<S> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Api { source, .. } => source.fmt(f),
        }
    }
}

impl<S: std::fmt::Debug + 'static> std::error::Error for MutationError<S> {}

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

    async fn pause_impl<S>(
        &self,
        state: Capability<S>,
        key: impl Into<String>,
    ) -> Result<Capability<Pausing>, MutationError<S>> {
        let key = key.into();
        let pending = Pending::new(state, Intent::Pause, key.clone());
        let params =
            CloudMachinePauseParams { machine: pending.state.payload().machine().id().to_owned() };
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
            Err(source) => return Err(MutationError::Api { pending, source }),
        };
        let (record, revision) = match mutation_value(answer) {
            Ok(value) => value,
            Err(source) => return Err(MutationError::Api { pending, source }),
        };
        pause_response(&self.scope, record.machine, revision)
            .map_err(|source| MutationError::Api { pending, source })
    }

    async fn resume_impl(
        &self,
        state: Capability<Paused>,
        key: impl Into<String>,
    ) -> Result<Capability<Starting>, MutationError<Paused>> {
        let key = key.into();
        let pending = Pending::new(state, Intent::Resume, key.clone());
        let params =
            CloudMachineStartParams { machine: pending.state.payload().machine().id().to_owned() };
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
            Err(source) => return Err(MutationError::Api { pending, source }),
        };
        let (record, revision) = match mutation_value(answer) {
            Ok(value) => value,
            Err(source) => return Err(MutationError::Api { pending, source }),
        };
        resume_response(&self.scope, record.machine, revision)
            .map_err(|source| MutationError::Api { pending, source })
    }

    async fn delete_impl<S: DeleteTransition>(
        &self,
        state: Capability<S>,
        key: impl Into<String>,
    ) -> Result<Capability<Deleted>, MutationError<S>> {
        let key = key.into();
        let pending = Pending::new(state, Intent::Delete, key.clone());
        let params =
            CloudMachineDeleteParams { machine: pending.state.payload().machine().id().to_owned() };
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
            Err(source) => return Err(MutationError::Api { pending, source }),
        };
        let (_, revision) = match mutation_value(answer) {
            Ok(value) => value,
            Err(source) => return Err(MutationError::Api { pending, source }),
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
        Answer::Refused(error) => {
            Err(Answer::<T, E>::Refused(error).into_result().expect_err("refused answer"))
        }
    }
}

fn pause_response(
    scope: &Scope,
    record: CloudMachine,
    revision: String,
) -> Result<Capability<Pausing>, ApiError> {
    let observed = observe(scope, record).map_err(|error| ApiError::unreadable(error))?;
    match observed {
        Observed::Pausing(mut vm) => {
            vm.payload_mut().revision = revision;
            Ok(Capability { vm })
        }
        _ => Err(ApiError::unreadable("a pause answer did not enter pausing")),
    }
}

fn resume_response(
    scope: &Scope,
    record: CloudMachine,
    revision: String,
) -> Result<Capability<Starting>, ApiError> {
    let observed = observe(scope, record).map_err(|error| ApiError::unreadable(error))?;
    match observed {
        Observed::Starting(mut vm) => {
            vm.payload_mut().revision = revision;
            Ok(Capability { vm })
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
    async fn a_lost_mutation_answer_keeps_the_same_key_and_revision() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("listener");
        let origin = format!("http://{}", listener.local_addr().expect("address"));
        tokio::spawn(async move {
            if let Ok((stream, _)) = listener.accept().await {
                drop(stream);
            }
        });
        let scope = Scope::new(&origin, Some("team_a")).expect("scope");
        let client = LifecycleClient::new(scope.clone(), "token", "test").expect("client");
        let observed = observe(&scope, record("running", "7")).expect("running");
        let Observed::Running(vm) = observed else { panic!("running status") };
        let error = Capability { vm }.pause(&client, "ck_lost").await.expect_err("lost answer");
        let (pending, source) = error.into_parts();
        assert_eq!(pending.key(), "ck_lost");
        assert_eq!(pending.revision(), "7");
        assert_eq!(pending.intent(), Intent::Pause);
        assert!(source.retryable, "a missing answer is safe to retry");
    }
}
