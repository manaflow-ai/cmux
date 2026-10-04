//! What the host gives this app through handles (app-platform.md 12.1 V6).
//!
//! The app never sees a host name typed by an agent, a known_hosts file or a
//! private key. The user picks a host in the host's connect sheet; the host
//! gives the app an opaque `connection` handle. The host answers three
//! questions about that handle:
//!
//! - where to connect ([`SshTarget`]),
//! - whether a host key is the one the user accepted ([`HostKeyPolicy`]),
//! - how to prove the user's identity ([`CredentialHandle`]): the host signs;
//!   the private key stays in the host.
//!
//! These traits are a model. The real handle calls go over the app provider
//! channel, which is not defined yet (README, "Interface gaps").

use crate::iface::BackendError;
use russh::keys::{HashAlg, PublicKey, ssh_key::Signature};
use std::fmt;
use std::sync::Arc;

/// Where an `ssh` connection handle points.
#[derive(Clone, PartialEq, Eq)]
pub struct SshTarget {
    pub host: String,
    pub port: u16,
    pub user: String,
}

impl fmt::Debug for SshTarget {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}@{}:{}", self.user, self.host, self.port)
    }
}

/// The host's answer for a server host key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostKeyDecision {
    /// The user accepted this exact key for this target before.
    Trusted,
    /// No key is recorded for this target. The app refuses; the host may ask
    /// the user out of band and the user opens the terminal again.
    Unknown,
    /// A different key is recorded for this target. The app refuses.
    Changed,
}

/// Host key verification, answered by the connection handle's owner.
///
/// The app calls it once per connection, during key exchange, before it
/// authenticates and before any channel opens. The app never accepts a key
/// by itself and never writes a known_hosts file.
pub trait HostKeyPolicy: Send + Sync {
    fn check(&self, target: &SshTarget, key: &PublicKey) -> HostKeyDecision;
}

/// A credential handle that signs without giving the key to the app.
pub trait CredentialHandle: Send + Sync {
    /// The public half; the server checks it before it asks for a signature.
    fn public_key(&self) -> PublicKey;
    /// Signs the SSH user-auth payload. `hash_alg` is set for RSA keys.
    fn sign(&self, hash_alg: Option<HashAlg>, data: &[u8]) -> Result<Signature, BackendError>;
}

/// What a resolved `ssh` connection handle gives the backend.
#[derive(Clone)]
pub struct SshConnection {
    pub target: SshTarget,
    pub host_keys: Arc<dyn HostKeyPolicy>,
    pub credential: Arc<dyn CredentialHandle>,
}

/// Resolves the opaque handle in `OpenRequest::target`. An unknown or
/// revoked handle is an error; the app never falls back to parsing the string.
pub trait ConnectionHandles: Send + Sync {
    fn resolve(&self, kind: &str, handle: &str) -> Result<SshConnection, BackendError>;
}
