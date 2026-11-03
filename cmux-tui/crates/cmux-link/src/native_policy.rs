//! Shared current-policy and peer-binding validation. No transport or clock owner.
use super::{
    MAX_PEERS, MAX_SAFE_INTEGER, NativeBinding, NativePolicy, ReceiverTime, id, native_id,
};
use crate::dial::Service;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use std::collections::HashSet;
use std::time::Duration;

impl NativeBinding {
    pub(super) fn key(&self) -> Option<[u8; 32]> {
        let bytes = STANDARD.decode(&self.wg_public_key).ok()?;
        if STANDARD.encode(&bytes) != self.wg_public_key {
            return None;
        }
        let key: [u8; 32] = bytes.try_into().ok()?;
        key.iter().any(|b| *b != 0).then_some(key)
    }

    pub(super) fn valid(&self) -> bool {
        self.version == 1
            && !self.tenant.is_empty()
            && self.tenant.len() <= 128
            && self.tenant.as_bytes().first().is_some_and(u8::is_ascii_alphanumeric)
            && self.tenant.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
            && native_id(&self.mesh, "mesh_")
            && native_id(&self.device, "dev_")
            && id(&self.host, "host_")
            && id(&self.user, "user_")
            && self.authority_version.len() == 64
            && self
                .authority_version
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            && self.acl_version <= MAX_SAFE_INTEGER
            && self.key().is_some()
    }
}

impl NativePolicy {
    pub(super) fn valid(&self, now: ReceiverTime) -> bool {
        self.issuer.starts_with("cmux:cloud:")
            && self.issuer.len() > "cmux:cloud:".len()
            && self.issuer.len() <= 128
            && self.issuer.bytes().all(|b| b.is_ascii_graphic())
            && id(&self.host, "host_")
            && id(&self.team, "team_")
            && self.authority_version.len() == 64
            && self
                .authority_version
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            && self.epoch > 0
            && self.epoch <= MAX_SAFE_INTEGER
            && self.checked_at_ms > 0
            && self.checked_at_ms <= now.unix_ms
            && self.expires_at_ms <= MAX_SAFE_INTEGER
            && self.expires_at_ms > now.unix_ms
            && self.expires_at_ms.checked_sub(self.checked_at_ms).is_some_and(|ms| ms <= 30_000)
            && now.monotonic.checked_duration_since(self.request_started).is_some_and(|elapsed| {
                elapsed < Duration::from_millis(self.expires_at_ms - self.checked_at_ms)
            })
            && self.peers.len() <= MAX_PEERS
            && self.unique_peers()
    }

    fn unique_peers(&self) -> bool {
        let mut installs = HashSet::new();
        let mut hosts = HashSet::new();
        let mut devices = HashSet::new();
        let mut keys = HashSet::new();
        let locator =
            self.peers.first().map(|p| (&p.binding.tenant, &p.binding.mesh, p.binding.acl_version));
        self.peers.iter().all(|p| {
            id(&p.install, "inst_")
                && p.binding.valid()
                && Some((&p.binding.tenant, &p.binding.mesh, p.binding.acl_version)) == locator
                && !p.services.is_empty()
                && p.services.len() <= 2
                && p.services.iter().all(|s| matches!(s, Service::Daemon | Service::Ssh))
                && !matches!(p.services.as_slice(), [first, second] if first == second)
                && installs.insert(&p.install)
                && hosts.insert(&p.binding.host)
                && devices.insert(&p.binding.device)
                && keys.insert(&p.binding.wg_public_key)
        })
    }
}
