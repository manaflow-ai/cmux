//! The provider contract: every lifecycle operation takes an idempotency key
//! and returns a receipt bound to provider, project, machine and generation.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fmt;

/// The caller's name for one logical operation. Retrying with the same key
/// and the same request returns the one committed result; the same key with
/// another request is a conflict.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct IdempotencyKey(String);

impl IdempotencyKey {
    /// 1 to 128 bytes of `[A-Za-z0-9_-]`, so a key is safe in a file name, a
    /// label and a log line.
    pub fn new(key: &str) -> Result<Self, ProviderError> {
        let ok = !key.is_empty()
            && key.len() <= 128
            && key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
        if ok {
            Ok(Self(key.to_owned()))
        } else {
            Err(ProviderError::Refused(
                "an idempotency key is 1 to 128 characters of letters, digits, - and _".into(),
            ))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// A short stable digest of the key, for names and labels that must not
    /// carry the key itself.
    pub fn digest(&self, salt: &str) -> String {
        let mut hash = Sha256::new();
        hash.update(salt.as_bytes());
        hash.update([0]);
        hash.update(self.0.as_bytes());
        hex::encode(hash.finalize())
    }

    /// The first `len` hex digits of [`Self::digest`] (64 at most).
    pub fn digest_prefix(&self, salt: &str, len: usize) -> String {
        self.digest(salt).chars().take(len).collect()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Op {
    Create,
    Start,
    Stop,
    Snapshot,
    Delete,
}

/// What `create` asks for. The setup sheet shows all of it before the first
/// create; nothing here is a secret.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateSpec {
    /// A digest-pinned image (`projects/P/global/images/NAME` or a family is
    /// refused: the image must be the exact one the sheet showed).
    pub image: String,
    pub machine_type: String,
    pub zone: String,
    pub disk_gb: u32,
    /// Guest-owned idle stop grace (minutes); the design's default is 30.
    pub idle_grace_minutes: u32,
    pub labels: BTreeMap<String, String>,
}

impl CreateSpec {
    pub fn validate(&self) -> Result<(), ProviderError> {
        if self.image.contains("/family/") {
            return Err(ProviderError::Refused(
                "the image must be pinned (an image, not an image family)".into(),
            ));
        }
        if self.idle_grace_minutes == 0 {
            return Err(ProviderError::Refused("idle stop needs a grace above 0 minutes".into()));
        }
        for (key, value) in &self.labels {
            let label_ok = |s: &str, min: usize| {
                s.len() >= min
                    && s.len() <= 63
                    && s.bytes().all(|b| {
                        b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_'
                    })
            };
            let starts_lower = key.bytes().next().is_some_and(|b| b.is_ascii_lowercase());
            if !starts_lower || !label_ok(key, 1) || !label_ok(value, 0) || key.starts_with("cmux-")
            {
                return Err(ProviderError::Refused(format!("label {key:?} is not allowed")));
            }
        }
        Ok(())
    }
}

/// One lifecycle request. `machine` names an existing machine for every op
/// but `create`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Request {
    pub op: Op,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub machine: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spec: Option<CreateSpec>,
}

impl Request {
    pub fn create(spec: CreateSpec) -> Self {
        Self { op: Op::Create, machine: None, spec: Some(spec) }
    }

    pub fn on(op: Op, machine: &str) -> Self {
        Self { op, machine: Some(machine.to_owned()), spec: None }
    }

    /// The request's identity for conflict checks: the same key may only
    /// ever mean these exact bytes.
    pub fn fingerprint(&self) -> String {
        let bytes = serde_json::to_vec(self).unwrap_or_default();
        hex::encode(Sha256::digest(&bytes))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MachineState {
    Provisioning,
    Running,
    Stopping,
    Stopped,
    /// The provider accepted the delete; the machine is not gone yet.
    Deleting,
    Deleted,
    Unknown,
}

/// A redacted record of one committed operation. It names no credential.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Receipt {
    pub provider: String,
    pub project: String,
    /// The zone or region the machine lives in.
    pub location: String,
    pub machine: String,
    pub generation: u64,
    pub op: Op,
    pub key: IdempotencyKey,
    pub state: MachineState,
    /// The snapshot an op made, when it made one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artifact: Option<String>,
    /// True when the ledger settled this op by looking at the provider after a
    /// lost answer, not from the call's own reply.
    #[serde(default)]
    pub reconciled: bool,
    pub at_unix_ms: u64,
}

/// Separate running, stopped and egress estimates, each with its source.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CostEstimate {
    pub machine_type: String,
    pub zone: String,
    pub running_per_hour: f64,
    pub stopped_disk_per_month: f64,
    pub egress_per_gb: f64,
    pub currency: String,
    /// Where the numbers came from and when; an estimate never claims more.
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProviderError {
    /// The key was used for another request, or the resource belongs to
    /// another key.
    Conflict(String),
    /// The call may or may not have taken effect (timeout, 5xx, lost reply).
    /// The ledger keeps the op pending and reconciles before reissuing.
    Indeterminate(String),
    /// Refused before or by the provider (Labs off, bad input, 401/403).
    Refused(String),
    NotFound(String),
    Api {
        status: u16,
        message: String,
    },
}

impl fmt::Display for ProviderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Conflict(m) => write!(f, "conflict: {m}"),
            Self::Indeterminate(m) => write!(f, "indeterminate: {m}"),
            Self::Refused(m) => write!(f, "refused: {m}"),
            Self::NotFound(m) => write!(f, "not found: {m}"),
            Self::Api { status, message } => write!(f, "provider error {status}: {message}"),
        }
    }
}

impl std::error::Error for ProviderError {}

/// One machine provider. Implementations make each call safe to repeat with
/// the same key (the provider-side request id), and the ledger makes the
/// whole operation safe across process restarts.
pub trait MachineProvider {
    /// `gcp`, `freestyle`, `fake`.
    fn provider(&self) -> &str;
    /// The project or account the machines and the bill belong to.
    fn project(&self) -> &str;
    /// The zone or region its calls address. Part of every key's scope.
    fn location(&self) -> &str;
    /// The machine name a `create` with this key makes. Deterministic, so a
    /// retried create after a lost answer finds the machine it made.
    fn machine_for(&self, key: &IdempotencyKey) -> String;
    /// Run one op. Returns the machine's state as the call left it, and the
    /// artifact it made (a snapshot name).
    fn apply(
        &self,
        key: &IdempotencyKey,
        request: &Request,
    ) -> Result<(MachineState, Option<String>), ProviderError>;
    /// What the provider shows for a machine now: `None` when it is gone.
    fn observe(&self, machine: &str) -> Result<Option<MachineState>, ProviderError>;
    fn cost_estimate(&self, spec: &CreateSpec) -> CostEstimate;
}
