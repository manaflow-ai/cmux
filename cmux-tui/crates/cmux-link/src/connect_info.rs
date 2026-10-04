//! `cloud.machine.connect_info` as `cmux link` uses it
//! (plans/cmux-next/cloud-client-contract.md section 1.7): the record, its
//! checks, the cache rules and the mapping of its errors to `link.dial`.
//!
//! The link resolves a Cloud host id itself, through the host credential
//! relay (decision LINK-RESOLVE). The caller passes only the host id; it
//! never holds peer keys, link tokens or the install token.

use std::collections::HashMap;
use std::net::{Ipv6Addr, SocketAddr};
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};

use crate::dial::{DialError, Service};
use crate::overlay_addr::overlay_address;

/// How long a record (without its token) stays usable.
pub const CACHE_TTL: Duration = Duration::from_secs(300);

/// The prefix of a Cloud overlay host id.
pub const HOST_PREFIX: &str = "host_";

/// True for an id the link resolves through connect_info.
pub fn is_cloud_host(id: &str) -> bool {
    id.starts_with(HOST_PREFIX)
}

/// The VM endpoint's peer data. Unknown fields are ignored, so the backend
/// may add fields.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PeerData {
    pub wg_public_key: String,
    pub overlay_address: Ipv6Addr,
    #[serde(default)]
    pub vpc_endpoint: Option<SocketAddr>,
    #[serde(default)]
    pub public_ipv6: Option<Ipv6Addr>,
}

/// This install's Freestyle tunnel, when it may reach the VM's VPC.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Gateway {
    pub tunnel_id: String,
    pub endpoint: String,
    pub server_public_key: String,
    pub client_address: String,
    pub allowed_ips: Vec<String>,
}

/// A single-use link token: one `hello`, never cached.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LinkToken {
    pub token: String,
    pub expires_at: String,
}

impl std::fmt::Debug for LinkToken {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("LinkToken").field("expires_at", &self.expires_at).finish()
    }
}

/// One `cloud.machine.connect_info` result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnectInfo {
    pub machine: String,
    pub host: String,
    pub epoch: u64,
    pub state: String,
    pub peer: PeerData,
    #[serde(default)]
    pub gateway: Option<Gateway>,
    pub services: Vec<Service>,
    #[serde(default)]
    pub link_token: Option<LinkToken>,
    pub revision: u64,
}

/// Why a record cannot be used.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InvalidInfo {
    /// The record names another host than the one asked for.
    HostMismatch,
    /// `peer.overlay_address` is not this link's derivation of the host id.
    OverlayMismatch,
    /// `peer.wg_public_key` is not 32 bytes of base64.
    BadKey,
}

impl ConnectInfo {
    /// Check the record for `host` before any of it is used.
    pub fn validate(&self, host: &str) -> Result<[u8; 32], InvalidInfo> {
        if self.host != host {
            return Err(InvalidInfo::HostMismatch);
        }
        // RED stub: the overlay address is not checked yet.
        let _ = overlay_address;
        STANDARD
            .decode(&self.peer.wg_public_key)
            .ok()
            .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())
            .ok_or(InvalidInfo::BadKey)
    }

    pub fn is_paused(&self) -> bool {
        self.state == "paused"
    }

    pub fn allows(&self, service: Service) -> bool {
        self.services.contains(&service)
    }
}

/// The errors `cloud.machine.connect_info` answers, and the link's own.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectInfoError {
    /// `cloud.machine.not_found`.
    NotFound,
    /// `cloud.machine.not_bound`: still provisioning.
    NotBound,
    /// `auth.forbidden`.
    Forbidden,
    /// The relay or the backend could not answer.
    Unavailable(String),
    /// The record failed [`ConnectInfo::validate`].
    Invalid(InvalidInfo),
}

impl ConnectInfoError {
    /// The wire error code of the backend, if it is one of the known ones.
    pub fn from_code(code: &str, message: &str) -> Self {
        match code {
            "cloud.machine.not_found" => Self::NotFound,
            "cloud.machine.not_bound" => Self::NotBound,
            "auth.forbidden" => Self::Forbidden,
            _ => Self::Unavailable(format!("{code}: {message}")),
        }
    }

    /// The `link.dial` error (contract section 1.7, "Mapping").
    pub fn dial_error(&self) -> DialError {
        match self {
            Self::NotFound => DialError::UnknownHost,
            Self::Forbidden => DialError::NotAuthorized,
            Self::NotBound | Self::Unavailable(_) | Self::Invalid(_) => DialError::Unreachable,
        }
    }
}

struct Entry {
    info: ConnectInfo,
    fetched_at: Instant,
}

/// Records by host id, without their tokens: at most [`CACHE_TTL`] old, and
/// never older than a revision the link has seen announced.
#[derive(Default)]
pub struct ConnectInfoCache {
    entries: HashMap<String, Entry>,
}

impl ConnectInfoCache {
    /// The cached record of `host`, if it is still fresh at `now`.
    pub fn get(&self, host: &str, now: Instant) -> Option<&ConnectInfo> {
        let entry = self.entries.get(host)?;
        (now.saturating_duration_since(entry.fetched_at) <= CACHE_TTL).then_some(&entry.info)
    }

    /// Store `info` (fetched at `now`) without its token and hand the token
    /// back for its one use. An older revision than the cached one keeps the
    /// cached peer data.
    pub fn insert(&mut self, mut info: ConnectInfo, now: Instant) -> Option<LinkToken> {
        // RED stub: the token stays in the cache.
        let token = info.link_token.clone();
        let keep_cached = self
            .entries
            .get(&info.host)
            .is_some_and(|cached| cached.info.revision > info.revision);
        if !keep_cached {
            self.entries.insert(info.host.clone(), Entry { info, fetched_at: now });
        }
        token
    }

    /// A `cloud.machine.upsert` announced `revision` for `host`: a cached
    /// record older than that is dropped. True when one was dropped.
    pub fn observe_revision(&mut self, host: &str, revision: u64) -> bool {
        let stale = self.entries.get(host).is_some_and(|entry| entry.info.revision < revision);
        if stale {
            self.entries.remove(host);
        }
        stale
    }

    /// `cloud.machine.removed`: drop the record at once. True when one existed.
    pub fn remove(&mut self, host: &str) -> bool {
        self.entries.remove(host).is_some()
    }
}

#[cfg(test)]
#[path = "connect_info_tests.rs"]
mod tests;
