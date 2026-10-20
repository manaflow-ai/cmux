//! Ed25519 receiver for Native-bound Cloud tokens. Policy and keys come from
//! authenticated control-plane reads rooted in the host's original enrollment;
//! nothing in a token can install a peer or extend that policy's lease.
//!
//! This verifier does not start a listener or fetch policy. Its owner must retire
//! existing streams on revocation/expiry and bind checked stamps to its supervised
//! child before enabling serving. The daemon's default remains deny-all.

use std::collections::{BTreeMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use ring::signature;
use serde::{Deserialize, Serialize};

use crate::dial::Service;
use crate::keyset::Keyset;
use crate::stamp::LinkPeer;
use crate::stream_lease::{LeaseControl, StreamLease};
use crate::token::{Expected, TokenRefused, TokenVerifier, VerifiedToken};

#[path = "native_streams.rs"]
mod streams;
use streams::{reconcile_streams, stream_deadline, wake_streams};

const MAX_TOKEN_BYTES: usize = 8192;
const MAX_PEERS: usize = 128;
const MAX_REPLAY: usize = 4096;
const MAX_STREAMS: usize = 4096;
const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;

/// The nine signed fields defined by the backend's NativeLinkBinding schema.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NativeBinding {
    pub version: u64,
    pub tenant: String,
    pub mesh: String,
    pub device: String,
    /// Source client host, distinct from the destination JWT audience.
    pub host: String,
    pub user: String,
    pub wg_public_key: String,
    /// Opaque peer authority version, never a raw grant or private stamp.
    pub authority_version: String,
    pub acl_version: u64,
}

/// One unique live peer and its currently granted services, supplied by the owner.
#[derive(Debug, Clone)]
pub struct NativePeer {
    pub install: String,
    pub binding: NativeBinding,
    pub services: Vec<Service>,
}

/// A bounded authenticated policy snapshot. No deserializer is provided: the
/// owner must authenticate, pin and validate its control-plane response first.
#[derive(Debug, Clone)]
pub struct NativePolicy {
    pub issuer: String,
    pub host: String,
    pub epoch: u64,
    pub team: String,
    /// Opaque receiving-generation stamp, including the VM's original
    /// authority and destination keys. Renewal timestamps are not a stamp.
    pub authority_version: String,
    pub peers: Vec<NativePeer>,
    pub checked_at_ms: u64,
    pub expires_at_ms: u64,
    /// Start of the authenticated request, not the time its response arrived.
    pub request_started: Instant,
}

/// Both clocks are sampled together. Wall time checks JWT NumericDate; monotonic
/// time prevents a stalled response or clock rollback from extending a lease.
#[derive(Debug, Clone, Copy)]
pub struct ReceiverTime {
    pub unix_ms: u64,
    pub monotonic: Instant,
}

type Clock = dyn Fn() -> Option<ReceiverTime> + Send + Sync;

struct State {
    keys: Keyset,
    policy: Option<NativePolicy>,
    last_policy_check: Option<u64>,
    clock_high_water: u64,
    // Retained across policy/key replacement and revocation. Never evict a live jti.
    spent: BTreeMap<String, u64>,
    streams: Vec<StreamAuthority>,
}

/// Captured under the same lock as signature, current-policy and replay checks.
/// Matching only install/user after verification would let a replacement grant
/// adopt an older stream during the admission-to-handoff race.
struct StreamAuthority {
    issuer: String,
    host: String,
    epoch: u64,
    team: String,
    authority_version: String,
    peer: NativePeer,
    service: Service,
    kid: String,
    signing_key: [u8; 32],
    lease: LeaseControl,
}

/// Signature, current-authority and atomic single-use checks for one owned host.
/// Keep this instance for the listener lifetime; replacing a policy or keyset
/// must never construct a fresh replay owner.
pub struct NativeTokenVerifier {
    state: Mutex<State>,
    clock: Arc<Clock>,
    replay_capacity: usize,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Header {
    alg: String,
    kid: String,
    typ: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Claims {
    iss: String,
    aud: String,
    sub: String,
    svc: Vec<Service>,
    epoch: u64,
    iat: u64,
    exp: u64,
    jti: String,
    team: String,
    network: NativeBinding,
}

impl NativeBinding {
    fn key(&self) -> Option<[u8; 32]> {
        let bytes = STANDARD.decode(&self.wg_public_key).ok()?;
        if STANDARD.encode(&bytes) != self.wg_public_key {
            return None;
        }
        let key: [u8; 32] = bytes.try_into().ok()?;
        key.iter().any(|b| *b != 0).then_some(key)
    }

    fn valid(&self) -> bool {
        self.version == 1
            && !self.tenant.is_empty()
            && self.tenant.len() <= 128
            && self.tenant.as_bytes()[0].is_ascii_alphanumeric()
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
    fn valid(&self, now: ReceiverTime) -> bool {
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
                && (p.services.len() != 2 || p.services[0] != p.services[1])
                && installs.insert(&p.install)
                && hosts.insert(&p.binding.host)
                && devices.insert(&p.binding.device)
                && keys.insert(&p.binding.wg_public_key)
        })
    }
}

impl NativeTokenVerifier {
    /// Construct a closed receiver with a bounded replay owner and an injected
    /// clock. No stream is accepted until `replace_authority` installs fresh policy.
    pub fn new(
        keys: Keyset,
        clock: impl Fn() -> Option<ReceiverTime> + Send + Sync + 'static,
        replay_capacity: usize,
    ) -> Result<Self, TokenRefused> {
        if !valid_keys(&keys) || !(1..=MAX_REPLAY).contains(&replay_capacity) {
            return Err(TokenRefused::Invalid);
        }
        Ok(Self {
            state: Mutex::new(State {
                keys,
                policy: None,
                last_policy_check: None,
                clock_high_water: 0,
                spent: BTreeMap::new(),
                streams: Vec::new(),
            }),
            clock: Arc::new(clock),
            replay_capacity,
        })
    }

    /// The production clock; construction still installs no policy or listener.
    pub fn with_system_clock(keys: Keyset) -> Result<Self, TokenRefused> {
        Self::new(
            keys,
            || {
                let unix_ms = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .ok()?
                    .as_millis()
                    .try_into()
                    .ok()?;
                Some(ReceiverTime { unix_ms, monotonic: Instant::now() })
            },
            MAX_REPLAY,
        )
    }

    /// Atomically replace current authority without resetting replay history.
    /// Out-of-order responses and expired snapshots are refused; the owner must
    /// call `clear_authority` when a refresh fails or authority is invalidated.
    pub fn replace_authority(&self, policy: NativePolicy) -> Result<(), TokenRefused> {
        let mut state = self.state.lock().map_err(|_| TokenRefused::Invalid)?;
        let now = self.sample(&mut state)?;
        if !policy.valid(now)
            || state.last_policy_check.is_some_and(|old| policy.checked_at_ms <= old)
        {
            return Err(TokenRefused::Invalid);
        }
        state.last_policy_check = Some(policy.checked_at_ms);
        state.policy = Some(policy);
        let wake = reconcile_streams(&mut state, Some(now));
        drop(state);
        wake_streams(wake);
        Ok(())
    }

    /// Immediately revoke existing leases and refuse new streams; retain replay
    /// and response-order fences.
    pub fn clear_authority(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.policy = None;
            let wake = reconcile_streams(&mut state, None);
            drop(state);
            wake_streams(wake);
        }
    }

    /// Install an authenticated keyset without reviving spent tokens.
    pub fn replace_keys(&self, keys: Keyset) -> Result<(), TokenRefused> {
        if !valid_keys(&keys) {
            return Err(TokenRefused::Invalid);
        }
        let mut state = self.state.lock().map_err(|_| TokenRefused::Invalid)?;
        state.keys = keys;
        let now = self.sample(&mut state).ok();
        let wake = reconcile_streams(&mut state, now);
        drop(state);
        wake_streams(wake);
        Ok(())
    }

    fn sample(&self, state: &mut State) -> Result<ReceiverTime, TokenRefused> {
        let now = (self.clock)().ok_or(TokenRefused::Invalid)?;
        if now.unix_ms < state.clock_high_water {
            return Err(TokenRefused::Invalid);
        }
        state.clock_high_water = now.unix_ms;
        Ok(now)
    }
}

impl TokenVerifier for NativeTokenVerifier {
    fn verify(&self, token: &str, expected: &Expected<'_>) -> Result<VerifiedToken, TokenRefused> {
        if token.is_empty() || token.len() > MAX_TOKEN_BYTES {
            return Err(TokenRefused::Invalid);
        }
        let mut state = self.state.lock().map_err(|_| TokenRefused::Invalid)?;
        let now = self.sample(&mut state)?;
        let policy = state.policy.as_ref().ok_or(TokenRefused::NoVerifier)?;
        if !policy.valid(now) {
            return Err(TokenRefused::Expired);
        }
        if expected.host != policy.host || expected.epoch != policy.epoch {
            return Err(TokenRefused::Invalid);
        }

        let mut parts = token.split('.');
        let h = parts.next().ok_or(TokenRefused::Invalid)?;
        let p = parts.next().ok_or(TokenRefused::Invalid)?;
        let s = parts.next().ok_or(TokenRefused::Invalid)?;
        if parts.next().is_some() {
            return Err(TokenRefused::Invalid);
        }
        let header: Header =
            serde_json::from_slice(&decode(h)?).map_err(|_| TokenRefused::Invalid)?;
        if header.alg != "EdDSA" || header.typ != "cmux-link+jwt" || !kid(&header.kid) {
            return Err(TokenRefused::Invalid);
        }
        let key = state.keys.keys.get(&header.kid).ok_or(TokenRefused::UnknownKey)?;
        let sig = decode(s)?;
        if sig.len() != 64 {
            return Err(TokenRefused::Invalid);
        }
        let signed = token.get(..h.len() + 1 + p.len()).ok_or(TokenRefused::Invalid)?;
        signature::UnparsedPublicKey::new(&signature::ED25519, key)
            .verify(signed.as_bytes(), &sig)
            .map_err(|_| TokenRefused::Invalid)?;
        let c: Claims = serde_json::from_slice(&decode(p)?).map_err(|_| TokenRefused::Invalid)?;
        if c.iss != policy.issuer
            || c.aud != policy.host
            || c.epoch != policy.epoch
            || c.team != policy.team
            || !id(&c.sub, "inst_")
            || !c.network.valid()
            || c.iat == 0
            || c.iat > MAX_SAFE_INTEGER
            || c.exp > MAX_SAFE_INTEGER
            || c.iat > now.unix_ms / 1000
            || c.exp <= c.iat
            || c.exp - c.iat > 300
            || URL_SAFE_NO_PAD
                .decode(&c.jti)
                .ok()
                .is_none_or(|b| b.len() != 16 || URL_SAFE_NO_PAD.encode(b) != c.jti)
        {
            return Err(TokenRefused::Invalid);
        }
        if c.exp <= now.unix_ms / 1000 {
            return Err(TokenRefused::Expired);
        }
        if c.svc.is_empty()
            || c.svc.len() > 2
            || c.svc.iter().any(|s| !matches!(s, Service::Daemon | Service::Ssh))
            || (c.svc.len() == 2 && c.svc[0] == c.svc[1])
        {
            return Err(TokenRefused::Invalid);
        }
        let peer = policy
            .peers
            .iter()
            .find(|p| {
                p.install == c.sub
                    && p.binding == c.network
                    && p.binding.key().as_ref() == Some(expected.peer_key)
            })
            .ok_or(TokenRefused::Invalid)?;
        if !c.svc.contains(&expected.service) || !peer.services.contains(&expected.service) {
            return Err(TokenRefused::ServiceNotAllowed);
        }
        let deadline = stream_deadline(policy, now).ok_or(TokenRefused::Expired)?;
        let (lease, control) = StreamLease::controlled(deadline);
        let authority = StreamAuthority {
            issuer: policy.issuer.clone(),
            host: policy.host.clone(),
            epoch: policy.epoch,
            team: policy.team.clone(),
            authority_version: policy.authority_version.clone(),
            peer: peer.clone(),
            service: expected.service,
            kid: header.kid,
            signing_key: *key,
            lease: control,
        };
        let verified = VerifiedToken {
            peer: LinkPeer { install: c.sub, user: c.network.user, team: c.team },
            issued_at_ms: c.iat.checked_mul(1000).ok_or(TokenRefused::Invalid)?,
            lease: Some(lease),
        };
        state.spent.retain(|_, exp| *exp > now.unix_ms / 1000);
        if state.spent.contains_key(&c.jti) {
            return Err(TokenRefused::Replayed);
        }
        if state.spent.len() >= self.replay_capacity {
            return Err(TokenRefused::ReplayCapacity);
        }
        state.streams.retain(|stream| stream.lease.deadline().is_some());
        if state.streams.len() >= MAX_STREAMS {
            return Err(TokenRefused::Invalid);
        }
        state.spent.insert(c.jti, c.exp);
        state.streams.push(authority);
        Ok(verified)
    }
}

impl Drop for NativeTokenVerifier {
    fn drop(&mut self) {
        let state = self.state.get_mut().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.policy = None;
        wake_streams(reconcile_streams(state, None));
    }
}

fn decode(value: &str) -> Result<Vec<u8>, TokenRefused> {
    let bytes = URL_SAFE_NO_PAD.decode(value).map_err(|_| TokenRefused::Invalid)?;
    if value.is_empty() || URL_SAFE_NO_PAD.encode(&bytes) != value {
        return Err(TokenRefused::Invalid);
    }
    Ok(bytes)
}

fn id(value: &str, prefix: &str) -> bool {
    value.strip_prefix(prefix).is_some_and(|s| {
        s.len() == 20 && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
    })
}

fn native_id(value: &str, prefix: &str) -> bool {
    value.strip_prefix(prefix).is_some_and(|s| {
        s.len() == 26 && s.bytes().all(|b| b"0123456789abcdefghjkmnpqrstvwxyz".contains(&b))
    })
}

fn kid(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

fn valid_keys(keys: &Keyset) -> bool {
    (1..=2).contains(&keys.keys.len())
        && keys.keys.keys().all(|s| kid(s))
        && keys.version.len() == 16
        && keys.version.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
