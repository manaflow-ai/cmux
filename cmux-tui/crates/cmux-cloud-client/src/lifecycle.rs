//! Typed, scoped I/O for Cloud machine lifecycle mutations.
//!
//! The wire client is deliberately sans-I/O at its operation layer. This
//! adapter supplies the missing boundary: a [`Machine`] is bound to the
//! backend and team that named it, the provider's status is parsed strictly,
//! and each mutation carries both the last observed revision and one stable
//! idempotency key. If the answer is lost, the consumed capability is returned
//! in [`Pending`] so the same intent can be retried without creating a second
//! mutation.

use cmux_cloud_wire::{CloudMachine, CloudMachineStatus};
#[cfg(feature = "http")]
use cmux_cloud_wire::{
    CloudMachineDeleteOp, CloudMachineDeleteParams, CloudMachinePauseOp, CloudMachinePauseParams,
    CloudMachineStartOp, CloudMachineStartParams,
};
use cmux_lifeline::vm::{
    Attached, Deleted, Deleting, Failed, Observed, Paused, Pausing, Provisioning, Ready, Running,
    Starting, Status, Stopped, Unknown, Vm,
};

use crate::ApiError;
#[cfg(feature = "http")]
use crate::BuildError;
use crate::machine::{HandleError, Machine, Scope};
#[cfg(feature = "http")]
use crate::ops::{self, Answer};

pub mod relay;

/// The identity and last owner revision carried by a lifecycle capability.
#[derive(Debug, PartialEq, Eq)]
pub struct Snapshot {
    machine: Machine,
    team: String,
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
    /// An observation named a different allocation.
    MachineMismatch,
    /// A missing, malformed or regressing owner revision cannot grant state.
    InvalidRevision,
}

impl std::fmt::Display for ObserveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidStatus => {
                f.write_str("the Cloud machine has an unrecognized lifecycle status")
            }
            Self::InvalidRevision => {
                f.write_str("Cloud observation has an invalid or stale revision")
            }
            Self::MachineMismatch => f.write_str("Cloud observation named another machine"),
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
    relay::check_revision(&record.revision, &record.revision)
        .map_err(|_| ObserveError::InvalidRevision)?;
    let status = cloud_status(&record.status)?;
    if let Some(expected) = scope.team()
        && expected != record.team
    {
        return Err(ObserveError::TeamMismatch {
            expected: expected.to_owned(),
            actual: record.team,
        });
    }
    let machine = scope.machine(&record.id).map_err(ObserveError::Handle)?;
    let snapshot = Snapshot { machine, team: record.team, revision: record.revision };
    Ok(wrap(status.bind(snapshot)))
}

/// Convert only statuses the Cloud machine wire contract can actually emit.
/// The shared lifeline vocabulary also contains `stopped`, `destroyed` and
/// `unknown` for other providers and reconciliation, but those words are not
/// Cloud machine statuses and must not grant a Cloud capability.
fn cloud_status(status: &CloudMachineStatus) -> Result<Status, ObserveError> {
    match status {
        CloudMachineStatus::Provisioning
        | CloudMachineStatus::Starting
        | CloudMachineStatus::Running
        | CloudMachineStatus::Pausing
        | CloudMachineStatus::Paused
        | CloudMachineStatus::Deleting
        | CloudMachineStatus::Failed => {
            status.as_str().parse().map_err(|_| ObserveError::InvalidStatus)
        }
        _ => Err(ObserveError::InvalidStatus),
    }
}

fn wrap(observed: Observed<Snapshot>) -> ObservedMachine {
    match observed {
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
    }
}

/// The mutation intent retained when a response is refused or lost.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Intent {
    Pause,
    Resume,
    Delete,
}

/// Authoritative result of replaying an unresolved mutation.
#[derive(Debug)]
pub enum MutationOutcome {
    Pausing(Capability<Pausing>),
    Starting(Capability<Starting>),
    Deleted(Capability<Deleted>),
}

fn validate_record(expected: &Snapshot, record: &CloudMachine) -> Result<Status, ObserveError> {
    if record.id != expected.machine.id() {
        return Err(ObserveError::MachineMismatch);
    }
    if record.team != expected.team {
        return Err(ObserveError::TeamMismatch {
            expected: expected.team.clone(),
            actual: record.team.clone(),
        });
    }
    relay::check_revision(&expected.revision, &record.revision)
        .map_err(|_| ObserveError::InvalidRevision)?;
    cloud_status(&record.status)
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

    #[cfg(feature = "http")]
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
#[cfg(feature = "http")]
trait UncertainTransition: Sized {
    fn uncertain(state: Capability<Self>) -> Capability<Unknown>;
}

#[cfg(feature = "http")]
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

#[cfg(feature = "http")]
uncertain_transition!(
    Provisioning,
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

#[cfg(feature = "http")]
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
    original_revision: String,
}

impl Reconciled {
    /// Revision used by the original intent; an observation does not rewrite it.
    pub fn original_revision(&self) -> &str {
        &self.original_revision
    }

    /// Consume the reconciliation result for typed state matching and retry.
    pub fn into_parts(self) -> (ObservedMachine, Intent, String) {
        (self.observed, self.intent, self.key)
    }
}

impl Pending<Unknown> {
    /// Reconcile this subject with a fresh authoritative Cloud record. No
    /// lifecycle action is available on `Unknown` until this succeeds.
    pub fn reconcile(
        mut self,
        record: CloudMachine,
    ) -> Result<Reconciled, Box<(Self, ObserveError)>> {
        let status = match validate_record(self.state.payload(), &record) {
            Ok(status) => status,
            Err(error) => return Err(Box::new((self, error))),
        };
        if self.revision().trim_start_matches('0') == record.revision.trim_start_matches('0') {
            return Err(Box::new((self, ObserveError::InvalidRevision)));
        }
        let original_revision = self.revision().to_owned();
        self.state.vm.payload_mut().revision = record.revision;
        let observed = wrap(self.state.vm.observed(status));
        Ok(Reconciled { observed, intent: self.intent, key: self.key, original_revision })
    }

    /// Replay the exact unresolved intent. This grants no live capability and
    /// preserves its original scope, revision, operation and idempotency key.
    #[cfg(feature = "http")]
    pub async fn retry(
        self,
        client: &LifecycleClient,
    ) -> Result<MutationOutcome, MutationError<Unknown>> {
        let Self { state, intent, key } = self;
        match intent {
            Intent::Pause => client.pause_impl(state, key).await.map(MutationOutcome::Pausing),
            Intent::Resume => client.resume_impl(state, key).await.map(MutationOutcome::Starting),
            Intent::Delete => client.delete_impl(state, key).await.map(MutationOutcome::Deleted),
        }
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
    #[cfg(feature = "http")]
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
    #[cfg(feature = "http")]
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
    #[cfg(feature = "http")]
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
            #[cfg(feature = "http")]
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

#[cfg(feature = "http")]
fn mutation_error<S: UncertainTransition>(
    pending: Pending<S>,
    source: ApiError,
) -> MutationError<S> {
    // A transport failure, proxy/server failure, or malformed success answer
    // can occur after the provider accepted the mutation. Keep the original
    // identity and key, but consume its stable capability into Unknown.
    let ambiguous = source.status.is_none()
        || source.status.is_some_and(|status| status >= 500)
        || source.code.as_deref() == Some("mutation.indeterminate");
    if ambiguous {
        MutationError::Uncertain { pending: pending.into_unknown(), source }
    } else {
        MutationError::Api { pending, source }
    }
}

/// A wire-op transport bound to one backend and team scope.
#[derive(Debug, Clone)]
#[cfg(feature = "http")]
pub struct LifecycleClient {
    scope: Scope,
    http: reqwest::Client,
}

#[cfg(feature = "http")]
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

    #[cfg(feature = "http")]
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
        pause_response(&self.scope, pending.state.payload(), record.machine, revision)
            .map_err(|source| mutation_error(pending, source))
    }

    #[cfg(feature = "http")]
    async fn resume_impl<S: UncertainTransition>(
        &self,
        state: Capability<S>,
        key: impl Into<String>,
    ) -> Result<Capability<Starting>, MutationError<S>> {
        let key = key.into();
        let pending = Pending::new(state, Intent::Resume, key.clone());
        let machine = match self.scope.id_of(pending.state.payload().machine()) {
            Ok(machine) => machine.to_owned(),
            Err(source) => {
                return Err(MutationError::Api { pending, source: ApiError::unreadable(source) });
            }
        };
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
        resume_response(&self.scope, pending.state.payload(), record.machine, revision)
            .map_err(|source| mutation_error(pending, source))
    }

    #[cfg(feature = "http")]
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
        if let Err(source) = relay::check_revision(pending.revision(), &revision) {
            return Err(mutation_error(pending, source));
        }
        let mut vm = S::delete(pending.state).vm.deleted();
        vm.payload_mut().revision = revision;
        Ok(Capability { vm })
    }
}

#[cfg(feature = "http")]
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

#[cfg(feature = "http")]
fn pause_response(
    scope: &Scope,
    expected: &Snapshot,
    record: CloudMachine,
    revision: String,
) -> Result<Capability<Pausing>, ApiError> {
    validate_record(expected, &record).map_err(ApiError::unreadable)?;
    relay::check_revision(&expected.revision, &revision)?;
    if revision.trim_start_matches('0') != record.revision.trim_start_matches('0') {
        return Err(ApiError::unreadable("machine and mutation revisions differ"));
    }
    let observed = observe(scope, record).map_err(ApiError::unreadable)?;
    match observed {
        ObservedMachine::Pausing(mut capability) if capability.machine() == expected.machine() => {
            capability.vm.payload_mut().revision = revision;
            Ok(capability)
        }
        ObservedMachine::Pausing(_) => {
            Err(ApiError::unreadable("a pause answer named another machine"))
        }
        _ => Err(ApiError::unreadable("a pause answer did not enter pausing")),
    }
}

#[cfg(feature = "http")]
fn resume_response(
    scope: &Scope,
    expected: &Snapshot,
    record: CloudMachine,
    revision: String,
) -> Result<Capability<Starting>, ApiError> {
    validate_record(expected, &record).map_err(ApiError::unreadable)?;
    relay::check_revision(&expected.revision, &revision)?;
    if revision.trim_start_matches('0') != record.revision.trim_start_matches('0') {
        return Err(ApiError::unreadable("machine and mutation revisions differ"));
    }
    let observed = observe(scope, record).map_err(ApiError::unreadable)?;
    match observed {
        ObservedMachine::Starting(mut capability) if capability.machine() == expected.machine() => {
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
#[cfg(feature = "http")]
trait DeleteTransition: Sized {
    fn delete(vm: Capability<Self>) -> Capability<Deleting>;
}

#[cfg(feature = "http")]
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

#[cfg(feature = "http")]
deletable!(
    Provisioning,
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
    #[cfg(feature = "http")]
    pub async fn pause(
        self,
        client: &LifecycleClient,
        key: impl Into<String>,
    ) -> Result<Capability<Pausing>, MutationError<Running>> {
        client.pause_impl(self, key).await
    }

    /// Delete a provider-running machine.
    #[cfg(feature = "http")]
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
    #[cfg(feature = "http")]
    pub async fn pause(
        self,
        client: &LifecycleClient,
        key: impl Into<String>,
    ) -> Result<Capability<Pausing>, MutationError<Ready>> {
        client.pause_impl(self, key).await
    }

    /// Delete a ready machine.
    #[cfg(feature = "http")]
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
    #[cfg(feature = "http")]
    pub async fn resume(
        self,
        client: &LifecycleClient,
        key: impl Into<String>,
    ) -> Result<Capability<Starting>, MutationError<Paused>> {
        client.resume_impl(self, key).await
    }

    /// Delete a paused machine.
    #[cfg(feature = "http")]
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
            #[cfg(feature = "http")]
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

delete_methods!(Provisioning, Attached, Pausing, Starting, Stopped, Failed, Unknown);

#[cfg(all(test, feature = "http"))]
mod tests;
