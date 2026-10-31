//! Ed25519 receiver for Native-bound Cloud tokens. Policy and keys come from
//! authenticated control-plane reads rooted in the host's original enrollment;
//! nothing in a token can install a peer or extend that policy's lease.
//!
//! This verifier does not start a listener or fetch policy. Its owner must retire
//! existing streams on revocation/expiry and bind checked stamps to its supervised
//! child before enabling serving. The daemon's default remains deny-all.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ring::signature;
use serde::{Deserialize, Serialize};

use crate::dial::Service;
use crate::keyset::Keyset;
use crate::stamp::LinkPeer;
use crate::stream_lease::StreamLease;
use crate::token::{Expected, TokenRefused, TokenVerifier, VerifiedToken};

#[path = "native_policy.rs"]
mod policy;

#[path = "native_streams.rs"]
mod streams;
use streams::{
    StreamAuthority, StreamProof, elapsed_deadline, reconcile_streams, stream_deadline,
    wake_streams,
};

#[path = "native_handshake.rs"]
mod handshake;

#[path = "receiver_owner.rs"]
pub mod receiver;

const MAX_TOKEN_BYTES: usize = crate::dial::MAX_LINK_TOKEN_BYTES;
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
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NativePeer {
    pub install: String,
    pub binding: NativeBinding,
    pub services: Vec<Service>,
}

/// A bounded authenticated policy snapshot. No deserializer is provided: the
/// owner must authenticate, pin and validate its control-plane response first.
#[derive(Debug, Clone, PartialEq, Eq)]
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

pub enum PolicyDeadline {
    Superseded,
    Closed,
    Live(Option<crate::elapsed::Deadline>),
}

struct State {
    keys: Keyset,
    policy: Option<NativePolicy>,
    last_policy_check: Option<u64>,
    clock_high_water: u64,
    // Retained across policy/key replacement and revocation. Never evict a live jti.
    spent: BTreeMap<String, u64>,
    streams: Vec<StreamAuthority>,
    receiver: Option<receiver::ReceiverState>,
}

/// Signature, current-authority and atomic single-use checks for one owned host.
/// Keep this instance for the listener lifetime; replacing a policy or keyset
/// must never construct a fresh replay owner.
pub struct NativeTokenVerifier {
    state: Mutex<State>,
    clock: Arc<Clock>,
    replay_capacity: usize,
    receiver_generation: Option<String>,
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
    receiver: Option<ReceiverGeneration>,
    #[serde(default, deserialize_with = "present_vm_kind")]
    vmk: Option<crate::token::VmKind>,
}

// Missing vmk retains old-token compatibility. A present claim must be one
// of the two signed roles; explicit null is malformed, like the Worker verifier.
fn present_vm_kind<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<crate::token::VmKind>, D::Error> {
    crate::token::VmKind::deserialize(deserializer).map(Some)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReceiverGeneration {
    version: u8,
    generation: String,
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
                receiver: None,
            }),
            clock: Arc::new(clock),
            replay_capacity,
            receiver_generation: None,
        })
    }

    /// A v2 receiver pins its generation from the original private root frame.
    /// The pin never comes from a JWT and cannot change within this owner.
    pub fn new_for_receiver(
        keys: Keyset,
        generation: String,
        clock: impl Fn() -> Option<ReceiverTime> + Send + Sync + 'static,
        replay_capacity: usize,
    ) -> Result<Self, TokenRefused> {
        if generation.len() != 64
            || !generation.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(TokenRefused::Invalid);
        }
        let mut verifier = Self::new(keys, clock, replay_capacity)?;
        verifier.receiver_generation = Some(generation);
        Ok(verifier)
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

    /// A queued topology update may use only its exact current publication's
    /// clock budget. A stale update cannot adopt a newer owner's deadline.
    pub fn policy_deadline(&self, expected: &NativePolicy) -> PolicyDeadline {
        let Ok((state, now)) = self.current() else { return PolicyDeadline::Closed };
        let Some(policy) = state.policy.as_ref() else { return PolicyDeadline::Closed };
        if policy != expected {
            return PolicyDeadline::Superseded;
        }
        if !policy.valid(now) {
            return PolicyDeadline::Closed;
        }
        match elapsed_deadline(&state, policy) {
            Some(budget) => PolicyDeadline::Live(budget),
            None => PolicyDeadline::Closed,
        }
    }

    /// Atomically replace current authority without resetting replay history.
    /// Out-of-order responses and expired snapshots are refused; the owner must
    /// call `clear_authority` when a refresh fails or authority is invalidated.
    pub fn replace_authority(&self, policy: NativePolicy) -> Result<(), TokenRefused> {
        let (mut state, now) = self.current()?;
        if state.receiver.is_some() {
            return Err(TokenRefused::Invalid);
        }
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
            receiver::invalidate_state(&mut state);
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
        if state.receiver.is_some() {
            return Err(TokenRefused::Invalid);
        }
        state.keys = keys;
        let now = self.sample(&mut state).ok();
        if now.is_none() {
            state.policy = None;
        }
        let wake = reconcile_streams(&mut state, now);
        drop(state);
        wake_streams(wake);
        Ok(())
    }

    /// Clock trust is shared by admission and already open streams. Observing
    /// its loss clears authority until a fresh snapshot arrives; it cannot
    /// silently recover an old lease when the wall clock catches up.
    fn current(&self) -> Result<(std::sync::MutexGuard<'_, State>, ReceiverTime), TokenRefused> {
        let mut state = self.state.lock().map_err(|_| TokenRefused::Invalid)?;
        if state.receiver.as_ref().is_some_and(|r| !r.ready()) {
            return Err(TokenRefused::NoVerifier);
        }
        match self.sample(&mut state) {
            Ok(now) => Ok((state, now)),
            Err(error) => {
                receiver::invalidate_state(&mut state);
                let wake = reconcile_streams(&mut state, None);
                drop(state);
                wake_streams(wake);
                Err(error)
            }
        }
    }

    fn sample(&self, state: &mut State) -> Result<ReceiverTime, TokenRefused> {
        let raw = (self.clock)().ok_or(TokenRefused::Invalid)?;
        let now = match &state.receiver {
            Some(receiver) => receiver.sample(raw.monotonic).ok_or(TokenRefused::Invalid)?,
            None => raw,
        };
        if now.unix_ms < state.clock_high_water {
            return Err(TokenRefused::Invalid);
        }
        state.clock_high_water = now.unix_ms;
        Ok(now)
    }
}

impl TokenVerifier for NativeTokenVerifier {
    fn begin_handshake(
        &self,
        host: &str,
        epoch: u64,
        peer_key: &[u8; 32],
    ) -> Result<StreamLease, TokenRefused> {
        handshake::begin(self, host, epoch, peer_key)
    }

    fn verify(&self, token: &str, expected: &Expected<'_>) -> Result<VerifiedToken, TokenRefused> {
        if token.is_empty() || token.len() > MAX_TOKEN_BYTES {
            return Err(TokenRefused::Invalid);
        }
        let (mut state, now) = self.current()?;
        let policy = state.policy.as_ref().ok_or(TokenRefused::NoVerifier)?;
        if !policy.valid(now) {
            state.policy = None;
            let wake = reconcile_streams(&mut state, None);
            drop(state);
            wake_streams(wake);
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
        let typ = if self.receiver_generation.is_some() {
            "cmux-native-link-v2+jwt"
        } else {
            "cmux-link+jwt"
        };
        if header.alg != "EdDSA" || header.typ != typ || !kid(&header.kid) {
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
        let receiving = match (&self.receiver_generation, &c.receiver) {
            (None, None) => true,
            (Some(expected), Some(receiver)) => {
                receiver.version == 2 && receiver.generation == *expected
            }
            _ => false,
        };
        if c.iss != policy.issuer
            || !receiving
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
        let elapsed = elapsed_deadline(&state, policy).ok_or(TokenRefused::Expired)?;
        let (lease, control) = StreamLease::with_budget(deadline, elapsed);
        let authority = StreamAuthority {
            issuer: policy.issuer.clone(),
            host: policy.host.clone(),
            epoch: policy.epoch,
            team: policy.team.clone(),
            authority_version: policy.authority_version.clone(),
            peer: peer.clone(),
            proof: StreamProof::Token {
                service: expected.service,
                kid: header.kid,
                signing_key: *key,
            },
            lease: control,
        };
        let verified = VerifiedToken {
            peer: LinkPeer { install: c.sub, user: c.network.user, team: c.team },
            vm_kind: c.vmk,
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
