//! Public host identity projection from the authenticated backend. This is not
//! a dial credential or serving grant; a receiver still needs live authority.
use std::collections::BTreeSet;

use crate::pairing::native::{opaque, origin, tenant};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};
use serde_json::Value;

const INVALID: &str = "server.pair.invalid_network_policy";
pub const MAX_POLICY_BYTES: usize = 1_048_576;

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Protocol {
    Tcp,
    Udp,
    Icmp,
    Any,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Allow {
    pub protocol: Protocol,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Peer {
    pub host: String,
    pub user: String,
    pub install: String,
    pub device: String,
    pub wg_public_key: String,
    pub install_public_key: String,
    pub authority_version: String,
    pub inbound: Vec<Allow>,
    pub outbound: Vec<Allow>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct HostNetworkPolicy {
    pub schema_version: u8,
    pub host: String,
    pub user: String,
    pub install: String,
    pub team: String,
    pub origin: String,
    pub tenant: String,
    pub mesh: String,
    pub device: String,
    pub wg_public_key: String,
    pub install_public_key: String,
    pub authority_version: String,
    pub checked_at: u64,
    pub expires_at: u64,
    pub acl_version: u64,
    pub policy_digest: String,
    pub peers: Vec<Peer>,
}
pub struct Expected<'a> {
    pub host: &'a str,
    pub user: &'a str,
    pub install: &'a str,
    pub team: &'a str,
}

fn id(value: &str, prefix: &str, size: usize) -> bool {
    value.strip_prefix(prefix).is_some_and(|s| {
        s.len() == size && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
    })
}
fn version(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn key(value: &str, size: usize) -> bool {
    STANDARD.decode(value).is_ok_and(|bytes| {
        bytes.len() == size && (size != 65 || bytes[0] == 4) && STANDARD.encode(bytes) == value
    })
}
fn rules(values: &[Allow]) -> bool {
    values.len() <= 4096
        && values.iter().all(|r| match r.protocol {
            Protocol::Tcp | Protocol::Udp => r.port != Some(0),
            Protocol::Icmp | Protocol::Any => r.port.is_none(),
        })
}
impl HostNetworkPolicy {
    pub fn parse(value: &Value, expected: &Expected<'_>) -> Result<Self, &'static str> {
        let policy: Self = serde_json::from_value(value.clone()).map_err(|_| INVALID)?;
        if policy.schema_version != 1
            || policy.host != expected.host
            || policy.team != expected.team
            || policy.user != expected.user
            || policy.install != expected.install
            || !id(&policy.host, "host_", 20)
            || !id(&policy.user, "user_", 20)
            || !id(&policy.install, "inst_", 20)
            || !id(&policy.team, "team_", 20)
            || !opaque(&policy.mesh, "mesh_")
            || !opaque(&policy.device, "dev_")
            || !tenant(&policy.tenant)
            || !origin(&policy.origin)
            || !key(&policy.wg_public_key, 32)
            || !key(&policy.install_public_key, 65)
            || !version(&policy.authority_version)
            || !version(&policy.policy_digest)
            || policy.checked_at == 0
            || policy.expires_at > 9_007_199_254_740_991
            || policy.expires_at <= policy.checked_at
            || policy.expires_at - policy.checked_at > 30_000
            || policy.peers.len() > 128
        {
            return Err(INVALID);
        }
        let mut hosts = BTreeSet::from([policy.host.as_str()]);
        let mut installs = BTreeSet::from([policy.install.as_str()]);
        let mut devices = BTreeSet::from([policy.device.as_str()]);
        let mut keys = BTreeSet::from([policy.wg_public_key.as_str()]);
        let mut points = BTreeSet::from([policy.install_public_key.as_str()]);
        for peer in &policy.peers {
            if !id(&peer.host, "host_", 20)
                || !id(&peer.user, "user_", 20)
                || !id(&peer.install, "inst_", 20)
                || !opaque(&peer.device, "dev_")
                || !key(&peer.wg_public_key, 32)
                || !key(&peer.install_public_key, 65)
                || !version(&peer.authority_version)
                || !rules(&peer.inbound)
                || !rules(&peer.outbound)
                || !hosts.insert(&peer.host)
                || !installs.insert(&peer.install)
                || !devices.insert(&peer.device)
                || !keys.insert(&peer.wg_public_key)
                || !points.insert(&peer.install_public_key)
            {
                return Err(INVALID);
            }
        }
        Ok(policy)
    }
    pub fn lifetime_ms(&self) -> u64 {
        self.expires_at - self.checked_at
    }
}

#[cfg(test)]
#[path = "network_policy_tests.rs"]
mod tests;
