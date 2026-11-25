//! Transport-independent, consuming requests for the host credential relay.
//!
//! Preparing an operation consumes its live capability. The request retains
//! only Unknown plus the original intent, key and revision: losing an answer
//! can never restore Running. A transport may replay this exact request or
//! consume it with an authoritative response.

use super::*;
use serde_json::{Value, json};

#[derive(Debug)]
pub struct Request {
    pending: Pending<Unknown>,
}

impl Request {
    pub fn scope(&self) -> &Scope {
        self.pending.state.machine().scope()
    }

    pub fn machine(&self) -> &str {
        self.pending.state.machine().id()
    }

    pub fn revision(&self) -> &str {
        self.pending.revision()
    }

    pub fn key(&self) -> &str {
        self.pending.key()
    }

    pub fn op(&self) -> &'static str {
        match self.pending.intent {
            Intent::Pause => "cloud.machine.pause",
            Intent::Resume => "cloud.machine.start",
            Intent::Delete => "cloud.machine.delete",
        }
    }

    pub fn params(&self) -> Value {
        json!({"machine": self.machine()})
    }

    /// Validate before consuming the request, so malformed or misdirected
    /// answers retain the exact uncertain intent for replay.
    pub fn validate(&self, value: &Value, revision: &str) -> Result<(), ApiError> {
        check_revision(self.revision(), revision)?;
        if self.pending.intent == Intent::Delete {
            serde_json::from_value::<cmux_cloud_wire::CloudMachineDeleteResult>(value.clone())
                .map_err(ApiError::unreadable)?;
            return Ok(());
        }
        let record: CloudMachine =
            serde_json::from_value(value["machine"].clone()).map_err(ApiError::unreadable)?;
        let status =
            validate_record(self.pending.state.payload(), &record).map_err(ApiError::unreadable)?;
        check_revision(self.revision(), &record.revision)?;
        if record.revision.trim_start_matches('0') != revision.trim_start_matches('0') {
            return Err(ApiError::unreadable("machine and mutation revisions differ"));
        }
        match (self.pending.intent, status) {
            (Intent::Pause, Status::Pausing | Status::Paused)
            | (Intent::Resume, Status::Starting | Status::Running) => Ok(()),
            _ => Err(ApiError::unreadable("mutation answer has an unexpected lifecycle state")),
        }
    }

    /// Accepted and completed operations remain distinct observed states.
    #[allow(clippy::result_large_err)] // The Err hands the pending typestate back so the caller can retry it.
    pub fn complete(
        self,
        value: Value,
        revision: String,
    ) -> Result<ObservedMachine, (Self, ApiError)> {
        if let Err(error) = self.validate(&value, &revision) {
            return Err((self, error));
        }
        if self.pending.intent == Intent::Delete {
            let mut vm = self.pending.state.vm.delete().deleted();
            vm.payload_mut().revision = revision;
            return Ok(ObservedMachine::Deleted(Capability { vm }));
        }
        // The exact record was validated above, including subject and revision.
        let record = match serde_json::from_value::<CloudMachine>(
            value.get("machine").cloned().unwrap_or(Value::Null),
        ) {
            Ok(record) => record,
            Err(error) => return Err((self, ApiError::unreadable(error))),
        };
        match self.pending.reconcile(record) {
            Ok(result) => Ok(result.into_parts().0),
            Err((pending, error)) => Err((Self { pending }, ApiError::unreadable(error))),
        }
    }
}

pub(super) fn check_revision(previous: &str, next: &str) -> Result<(), ApiError> {
    let decimal =
        |s: &str| !s.is_empty() && s.len() <= 128 && s.bytes().all(|b| b.is_ascii_digit());
    if !decimal(previous) || !decimal(next) {
        return Err(ApiError::unreadable("lifecycle revisions must be decimal strings"));
    }
    let previous = previous.trim_start_matches('0');
    let next = next.trim_start_matches('0');
    if (next.len(), next) < (previous.len(), previous) {
        return Err(ApiError::unreadable("mutation revision predates its observation"));
    }
    Ok(())
}

impl Capability<Running> {
    pub fn prepare_pause(self, key: impl Into<String>) -> Request {
        let vm = self.vm.pause().uncertain();
        Request { pending: Pending::new(Capability { vm }, Intent::Pause, key.into()) }
    }
}

impl Capability<Ready> {
    pub fn prepare_pause(self, key: impl Into<String>) -> Request {
        let vm = self.vm.pause().uncertain();
        Request { pending: Pending::new(Capability { vm }, Intent::Pause, key.into()) }
    }
}

impl Capability<Paused> {
    pub fn prepare_resume(self, key: impl Into<String>) -> Request {
        let vm = self.vm.resume().uncertain();
        Request { pending: Pending::new(Capability { vm }, Intent::Resume, key.into()) }
    }
}

macro_rules! prepare_delete {
    ($($state:ty),+ $(,)?) => {$ (
        impl Capability<$state> {
            pub fn prepare_delete(self, key: impl Into<String>) -> Request {
                let vm = self.vm.delete().uncertain();
                Request { pending: Pending::new(Capability { vm }, Intent::Delete, key.into()) }
            }
        }
    )+};
}

prepare_delete!(
    Provisioning,
    Running,
    Ready,
    Attached,
    Pausing,
    Paused,
    Starting,
    Stopped,
    Failed,
    Unknown
);
