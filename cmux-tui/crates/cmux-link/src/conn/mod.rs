//! `conn_…` connection records (finder.md 3.1, transport.md 12c item 4).
//!
//! `cmux link` is the single writer. A record says what a connection points
//! at, which credential reference it uses, the state of the host key and the
//! state of the path. Records belong to one (user, app) pair: another app of
//! the same user cannot see or use them. Every change is a typed op with an
//! idempotency key, applied by the pure [`reducer`] and committed by the
//! durable [`store`].

pub mod reducer;
pub mod store;
#[cfg(test)]
mod tests;

use serde::{Deserialize, Serialize};

use crate::host_key::HostKey;

pub use reducer::{ConnState, Outcome, reduce};
pub use store::{ConnStore, StoreError};

/// Prefix of a connection handle.
pub const CONN_PREFIX: &str = "conn_";

/// The principal that owns a record: the user and the app holding the
/// handle. Both are opaque ids checked by equality.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct Principal {
    pub user: String,
    pub app: String,
}

/// Who issued a request (OWNERSHIP-PRINCIPLES "origin"). Host key
/// confirmation accepts only `User`, the host-owned sheet's gesture.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Origin {
    User,
    Cli,
    Mcp,
    Script,
    Remote,
    /// The link itself, for observations from its own connect attempts.
    Link,
}

/// What kind of endpoint a connection reaches.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnKind {
    Local,
    CmuxHost,
    CloudVm,
    TeamVm,
    Ssh,
}

/// How a live connection reaches its host. The overlay's path events
/// (transport.md 12a) and the SSH kind fill it; apps get [`ConnPath::display`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnPath {
    pub kind: PathKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rtt_ms: Option<u32>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PathKind {
    DirectLan,
    DirectWan,
    ViaCloudRegion,
    DoRelay,
    Ssh,
}

impl ConnPath {
    /// The display string (`"direct · 3 ms"`), never parsed.
    #[must_use]
    pub fn display(&self) -> String {
        let label = match self.kind {
            PathKind::DirectLan | PathKind::DirectWan => "direct",
            PathKind::ViaCloudRegion => "tunnel",
            PathKind::DoRelay => "relay",
            PathKind::Ssh => "ssh",
        };
        match self.rtt_ms {
            Some(rtt) => format!("{label} · {rtt} ms"),
            None => label.to_owned(),
        }
    }
}

/// Where a connection points. Never sent to the app as anything but a
/// display label.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Target {
    /// This machine.
    Local,
    /// An enrolled cmux endpoint (`host_…`), reached over the overlay.
    Host { host: String },
    /// A plain SSH host reached with the system OpenSSH client.
    Ssh(SshTarget),
}

/// A plain SSH target: a destination the user's ssh config resolves
/// (`user@host`, `host`, or a `Host` alias) and an optional port.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SshTarget {
    pub destination: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
}

impl SshTarget {
    /// Checks that `destination` can only be read as a destination: not
    /// empty, at most 255 bytes, no leading `-` (an ssh option), and no
    /// whitespace, control characters or quotes.
    pub fn validate(&self) -> Result<(), Reject> {
        let destination = &self.destination;
        let valid = !destination.is_empty()
            && destination.len() <= 255
            && !destination.starts_with('-')
            && destination
                .chars()
                .all(|character| !character.is_whitespace() && !character.is_control())
            && !destination.contains(['"', '\'', '\\', '%'])
            && self.port != Some(0);
        if valid { Ok(()) } else { Err(Reject::TargetInvalid) }
    }
}

/// Which credential the link uses for this connection. The app never sees
/// the secret behind it (finder.md 3.3).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum CredentialRef {
    /// The user's ssh config and agent decide.
    SshConfig,
    /// A `cred_…` handle issued by the link's credential broker.
    Cred { cred: String },
    /// The team VM SSH certificate the link fetches itself.
    TeamCert,
}

/// The host key of a connection. Only SSH connections have one.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum HostKeyState {
    /// Not an SSH connection: the overlay authenticates the host.
    NotApplicable,
    /// No connect attempt has seen a key yet.
    None,
    /// The host offered a key nobody confirmed. The sheet shows it.
    Unknown { offered: HostKey },
    /// The user confirmed this key; the link's known-hosts file holds it.
    Confirmed { key: HostKey },
    /// The host offered a different key from the confirmed one. Hard stop:
    /// connect is refused until the user confirms the new key.
    Changed { confirmed: HostKey, offered: HostKey },
}

/// One connection record.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnRecord {
    pub conn: String,
    pub principal: Principal,
    pub kind: ConnKind,
    pub target: Target,
    pub credential: Option<CredentialRef>,
    pub host_key: HostKeyState,
    pub state: ConnState,
    /// The live path, while connected.
    pub path: Option<ConnPath>,
    /// Incremented on every change to this record.
    pub revision: u64,
}

/// A typed op. The store fills in nothing: ids are chosen before the op
/// reaches the reducer, so the reducer stays pure and replay is exact.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum ConnOp {
    /// `conn.create`. `conn` is a fresh id from [`crate::ids::random_id`].
    Create { conn: String, kind: ConnKind, target: Target, credential: Option<CredentialRef> },
    /// `conn.revoke`.
    Revoke { conn: String },
    /// What one connect attempt saw. Only the link issues it.
    Observe { conn: String, observation: Observation },
    /// `host.key.confirm {conn, fingerprint}` from the host-owned sheet.
    ConfirmHostKey { conn: String, fingerprint: String },
}

/// What a connect attempt of the link saw.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "outcome", rename_all = "snake_case")]
pub enum Observation {
    /// The attempt started; the path is being set up.
    Connecting,
    /// OpenSSH accepted the offered key and authenticated.
    Connected { offered: Option<HostKey>, path: Option<ConnPath> },
    /// OpenSSH refused the offered key under strict checking.
    /// `known_elsewhere` is a key of the same type for this host in the
    /// user's own known-hosts files (read-only input), if any.
    HostKeyRejected { offered: HostKey, known_elsewhere: Option<HostKey> },
    /// The key was accepted but authentication failed.
    AuthFailed,
    /// The host could not be reached.
    Unreachable,
    /// A live connection ended.
    Disconnected,
}

/// A request to the store: the principal, the origin and an idempotency key
/// chosen by the client.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnRequest {
    pub idempotency_key: String,
    pub principal: Principal,
    pub origin: Origin,
    pub op: ConnOp,
}

/// An event a committed op produced. `revision` is the record's revision
/// after the change.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnEvent {
    pub conn: String,
    pub principal: Principal,
    pub revision: u64,
    pub change: ConnChange,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "change", rename_all = "snake_case")]
pub enum ConnChange {
    Created,
    Revoked,
    StateChanged {
        state: ConnState,
        path: Option<ConnPath>,
    },
    /// `host_key.unknown`: the sheet shows `fingerprint` and asks.
    HostKeyUnknown {
        key_type: String,
        fingerprint: String,
    },
    /// `host_key.changed`: hard stop, both fingerprints, no continue.
    HostKeyChanged {
        key_type: String,
        old_fingerprint: String,
        new_fingerprint: String,
    },
    HostKeyConfirmed {
        key_type: String,
        fingerprint: String,
    },
}

/// Why an op was refused. Codes are the wire error codes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "code")]
pub enum Reject {
    #[serde(rename = "conn.unknown")]
    ConnUnknown,
    #[serde(rename = "conn.revoked")]
    ConnRevoked,
    #[serde(rename = "conn.exists")]
    ConnExists,
    #[serde(rename = "conn.id_invalid")]
    ConnIdInvalid,
    #[serde(rename = "target.invalid")]
    TargetInvalid,
    #[serde(rename = "origin.not_user")]
    OriginNotUser,
    #[serde(rename = "origin.not_link")]
    OriginNotLink,
    #[serde(rename = "host_key.not_pending")]
    HostKeyNotPending,
    #[serde(rename = "host_key.fingerprint_mismatch")]
    HostKeyFingerprintMismatch,
    /// A changed key is a hard stop.
    #[serde(rename = "host_key.changed")]
    HostKeyChanged { old_fingerprint: String, new_fingerprint: String },
    #[serde(rename = "idempotency.conflict")]
    IdempotencyConflict,
}

impl Reject {
    /// The wire error code.
    #[must_use]
    pub fn code(&self) -> &'static str {
        match self {
            Self::ConnUnknown => "conn.unknown",
            Self::ConnRevoked => "conn.revoked",
            Self::ConnExists => "conn.exists",
            Self::ConnIdInvalid => "conn.id_invalid",
            Self::TargetInvalid => "target.invalid",
            Self::OriginNotUser => "origin.not_user",
            Self::OriginNotLink => "origin.not_link",
            Self::HostKeyNotPending => "host_key.not_pending",
            Self::HostKeyFingerprintMismatch => "host_key.fingerprint_mismatch",
            Self::HostKeyChanged { .. } => "host_key.changed",
            Self::IdempotencyConflict => "idempotency.conflict",
        }
    }
}

impl std::fmt::Display for Reject {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.code())
    }
}

impl std::error::Error for Reject {}
