//! A receiving-policy read rooted in the VM's original enrollment. The agent
//! returns public authority only; a socket caller cannot supply a destination,
//! substitute credentials, or obtain either private key.

use std::collections::BTreeSet;
use std::time::{Duration, Instant};

use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use cmux_cloud_wire::{
    CloudVmNetworkPolicyOp, CloudVmNetworkPolicyParams, CloudVmNetworkPolicyView,
    CloudVmReceiverPeerServicesItem, Op, OpRequest, ReadResponse,
};
use cmux_link::dial::Service;
use cmux_link::elapsed::{Deadline, Elapsed};
use cmux_link::keyset::{Keyset, read_answer};
use cmux_link::native_token::{NativeBinding, NativePeer, NativePolicy, ReceiverTime};
use cmux_server::cloud_http::RequestDeadline;
use serde::Deserialize;
use serde_json::{Value, json};

use super::client::{CloudClient, Http};
use super::wire::{Bound, Env};

#[path = "receiver_reply.rs"]
mod reply;
pub use reply::ReceiverBinding;

pub const POLICY_OP: &str = CloudVmNetworkPolicyOp::NAME;
pub const REQUEST_BUDGET: Duration = Duration::from_secs(20);
const SAFE: i64 = 9_007_199_254_740_991;
const UNAVAILABLE: &str = "VM receiving authority unavailable";

// A required nullable wire field must distinguish an explicit closed generation
// from a malformed reply. Serde's generated Option alone accepts missing fields.
struct RequiredPolicy(CloudVmNetworkPolicyView);
impl<'de> Deserialize<'de> for RequiredPolicy {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let value = Value::deserialize(d)?;
        if value.get("receiver_generation").is_none() {
            return Err(serde::de::Error::missing_field("receiver_generation"));
        }
        CloudVmNetworkPolicyView::deserialize(value).map(Self).map_err(serde::de::Error::custom)
    }
}

/// An in-process snapshot retains its original monotonic request start.
/// Never cache this in place of rechecking the private files on the next read.
pub struct ReceiverSnapshot {
    policy: CloudVmNetworkPolicyView,
    keys: Keyset,
    started: Instant,
    elapsed: Option<Elapsed>,
    issuer: String,
}

impl ReceiverSnapshot {
    pub fn policy(&self) -> &CloudVmNetworkPolicyView {
        &self.policy
    }
    pub fn keys(&self) -> &Keyset {
        &self.keys
    }

    /// Active-clock scheduling projection. Authority checks must use `time`;
    /// this Instant alone cannot account for time spent suspended.
    pub fn expires(&self) -> Instant {
        self.started
            + Duration::from_millis((self.policy.expires_at - self.policy.checked_at) as u64)
    }

    /// Local age of the original request. Suspend-inclusive readings can only
    /// increase the debit; backwards or unavailable clocks close the snapshot.
    pub fn elapsed(&self, now: Instant) -> Option<Duration> {
        let active = now.checked_duration_since(self.started)?;
        Some(match &self.elapsed {
            Some(source) => active.max(source.elapsed()?),
            None => active,
        })
    }

    pub fn elapsed_deadline(&self) -> Option<Deadline> {
        self.elapsed.as_ref()?.deadline_at(Duration::from_millis(
            (self.policy.expires_at - self.policy.checked_at) as u64,
        ))
    }

    /// Conservative issuer time: debit the whole request, including auth and
    /// keyset I/O. The device's possibly skewed wall clock is not authority.
    pub fn time(&self, now: Instant) -> Option<ReceiverTime> {
        Some(self.measured_time(now)?.0)
    }

    fn measured_time(&self, now: Instant) -> Option<(ReceiverTime, Duration)> {
        let elapsed = self.elapsed(now)?;
        let lifetime =
            Duration::from_millis((self.policy.expires_at - self.policy.checked_at) as u64);
        let remaining = lifetime.checked_sub(elapsed).filter(|left| !left.is_zero())?;
        let unix_ms = (self.policy.checked_at as u64)
            .checked_add(u64::try_from(elapsed.as_millis()).ok()?)?;
        Some((ReceiverTime { unix_ms, monotonic: now }, remaining))
    }

    pub fn native_policy(&self) -> NativePolicy {
        let p = &self.policy;
        NativePolicy {
            issuer: self.issuer.clone(),
            host: p.host.clone(),
            epoch: p.epoch as u64,
            team: p.team.clone(),
            authority_version: p.authority_version.clone(),
            checked_at_ms: p.checked_at as u64,
            expires_at_ms: p.expires_at as u64,
            request_started: self.started,
            peers: p
                .peers
                .iter()
                .map(|peer| NativePeer {
                    install: peer.install.clone(),
                    binding: NativeBinding {
                        version: 1,
                        tenant: p.tenant.clone(),
                        mesh: p.mesh.clone(),
                        device: peer.device.clone(),
                        host: peer.host.clone(),
                        user: peer.user.clone(),
                        wg_public_key: peer.wg_public_key.clone(),
                        authority_version: peer.authority_version.clone(),
                        acl_version: p.acl_version as u64,
                    },
                    services: peer
                        .services
                        .iter()
                        .filter_map(|s| match s {
                            CloudVmReceiverPeerServicesItem::Daemon => Some(Service::Daemon),
                            CloudVmReceiverPeerServicesItem::Ssh => Some(Service::Ssh),
                            // Validation rejects unknown services. Keep this conversion
                            // non-panicking and never grant authority for an unknown value.
                            _ => None,
                        })
                        .collect(),
                })
                .collect(),
        }
    }

    /// Public socket reply. A consumer must start its own monotonic deadline
    /// before sending the socket request. Cap `remaining_ms` by the policy
    /// lifetime minus that entire round trip; do not subtract root work twice.
    /// Response arrival must never extend the original request's deadline.
    pub fn public_reply(&self, now: Instant) -> Result<Value, String> {
        let (time, remaining) = self.measured_time(now).ok_or(UNAVAILABLE)?;
        let keys: serde_json::Map<String, Value> = self.keys.keys.iter().map(|(kid, key)|
            (kid.clone(), json!({ "kty": "OKP", "crv": "Ed25519", "alg": "EdDSA", "kid": kid, "x": URL_SAFE_NO_PAD.encode(key) }))
        ).collect();
        Ok(json!({ "ok": true, "value": { "policy": self.policy,
            "keyset": { "version": self.keys.version, "keys": keys },
            "issuer": self.issuer, "issuer_time_ms": time.unix_ms,
            "remaining_ms": remaining.as_millis() as u64 } }))
    }
}

impl<H: Http> CloudClient<H> {
    /// Called only after the role verifies the original bound/install/WG files.
    /// No token, key, machine id or API origin comes from the socket request.
    pub fn receiving_policy(
        &mut self,
        wg_public: &str,
        now_wall_ms: u64,
    ) -> Result<ReceiverSnapshot, String> {
        let elapsed = Elapsed::system().ok_or(UNAVAILABLE)?;
        let started = Instant::now();
        self.receiving_policy_with_elapsed(wg_public, now_wall_ms, started, elapsed)
    }

    #[cfg(test)]
    pub(super) fn receiving_policy_at(
        &mut self,
        wg_public: &str,
        now_wall_ms: u64,
        started: Instant,
    ) -> Result<ReceiverSnapshot, String> {
        let elapsed = Elapsed::system().ok_or(UNAVAILABLE)?;
        self.receiving_policy_with_elapsed(wg_public, now_wall_ms, started, elapsed)
    }

    pub(super) fn receiving_policy_with_elapsed(
        &mut self,
        wg_public: &str,
        now_wall_ms: u64,
        started: Instant,
        elapsed: Elapsed,
    ) -> Result<ReceiverSnapshot, String> {
        let deadline = RequestDeadline::with_elapsed(started, elapsed.clone(), REQUEST_BUDGET)
            .ok_or(UNAVAILABLE)?;
        let token = self.token_until(now_wall_ms, Some(&deadline))?;
        let body = serde_json::to_value(OpRequest::new::<CloudVmNetworkPolicyOp>(
            CloudVmNetworkPolicyParams { machine: self.bound().machine.clone() },
        ))
        .map_err(|_| UNAVAILABLE)?;
        let (status, bytes) =
            self.request_until("/v1/read", Some(&body), Some(&token), &deadline)?;
        if status != 200 {
            self.clear_token();
            return Err(UNAVAILABLE.into());
        }
        // Check before the required-field adapter normalizes policy into Value.
        let _: UniqueJson = serde_json::from_slice(&bytes).map_err(|_| UNAVAILABLE)?;
        let read: ReadResponse<RequiredPolicy> =
            serde_json::from_slice(&bytes).map_err(|_| UNAVAILABLE)?;
        if read.op != POLICY_OP
            || read.stream != format!("cloud:{}", self.bound().team)
            || read.revision.is_empty()
            || read.revision.len() > 20
            || !read.revision.bytes().all(|b| b.is_ascii_digit())
        {
            return Err(UNAVAILABLE.into());
        }
        let binding =
            ReceiverBinding::from_original(self.bound(), wg_public, &self.install_public_jwk())?;
        validate(&read.value.0, &binding)?;
        let (status, bytes) = self.request_until("/v1/cloud/keyset", None, None, &deadline)?;
        // Reject duplicate JSON object keys, including duplicate key ids, before
        // the shared keyset parser can normalize them into a map.
        let _: UniqueJson = serde_json::from_slice(&bytes).map_err(|_| UNAVAILABLE)?;
        let keys = read_answer(status, &[], &bytes).map_err(|_| UNAVAILABLE)?;
        let snapshot = ReceiverSnapshot {
            policy: read.value.0,
            keys,
            started,
            elapsed: Some(elapsed),
            issuer: format!("cmux:cloud:{}", self.bound().env.auth_environment()),
        };
        snapshot.time(Instant::now()).ok_or(UNAVAILABLE)?;
        Ok(snapshot)
    }
}

fn validate(p: &CloudVmNetworkPolicyView, b: &ReceiverBinding) -> Result<(), String> {
    let bad = || UNAVAILABLE.to_owned();
    if p.machine != b.machine
        || p.host != b.host
        || p.epoch as u64 != b.epoch
        || p.team != b.team
        || p.user != b.user
        || p.install != b.install
        || p.wg_public_key != b.wg_public_key
        || p.install_public_key != b.install_public_key
        || !id(&p.machine, "vm_", 20)
        || !id(&p.host, "host_", 20)
        || !id(&p.user, "user_", 20)
        || !id(&p.install, "inst_", 20)
        || !id(&p.team, "team_", 20)
        || !(1..=SAFE).contains(&p.epoch)
        || !(0..=SAFE).contains(&p.acl_version)
        || p.checked_at <= 0
        || p.checked_at > SAFE
        || p.expires_at > SAFE
        || p.expires_at <= p.checked_at
        || p.expires_at - p.checked_at > 30_000
        || !hex(&p.policy_digest, 64)
        || !hex(&p.authority_version, 64)
        || p.receiver_generation.as_ref().is_some_and(|generation| !hex(generation, 64))
        || !native_id(&p.mesh, "mesh_")
        || !native_id(&p.vm, "vm_")
        || p.tenant.is_empty()
        || p.tenant.len() > 128
        || !p.tenant.as_bytes()[0].is_ascii_alphanumeric()
        || !p.tenant.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
        || p.ipv4.as_ref().is_some_and(|ip| ip.parse::<std::net::Ipv4Addr>().is_err())
        || !canonical_origin(&p.origin)
        || p.peers.len() > 128
        || !public_key(&p.wg_public_key, 32)
        || !public_key(&p.install_public_key, 65)
    {
        return Err(bad());
    }
    let mut hosts = BTreeSet::from([p.host.as_str()]);
    let mut installs = BTreeSet::from([p.install.as_str()]);
    let mut devices = BTreeSet::new();
    let mut wgs = BTreeSet::from([p.wg_public_key.as_str()]);
    let mut points = BTreeSet::from([p.install_public_key.as_str()]);
    for peer in &p.peers {
        let services: BTreeSet<_> = peer
            .services
            .iter()
            .map(|s| match s {
                CloudVmReceiverPeerServicesItem::Daemon => 1,
                CloudVmReceiverPeerServicesItem::Ssh => 2,
                _ => 0,
            })
            .collect();
        if !id(&peer.host, "host_", 20)
            || !id(&peer.user, "user_", 20)
            || !id(&peer.install, "inst_", 20)
            || !native_id(&peer.device, "dev_")
            || !hex(&peer.authority_version, 64)
            || !public_key(&peer.wg_public_key, 32)
            || !public_key(&peer.install_public_key, 65)
            || services.is_empty()
            || services.contains(&0)
            || services.len() != peer.services.len()
            || (services.contains(&1) && !services.contains(&2))
            || !hosts.insert(&peer.host)
            || !installs.insert(&peer.install)
            || !devices.insert(&peer.device)
            || !wgs.insert(&peer.wg_public_key)
            || !points.insert(&peer.install_public_key)
        {
            return Err(bad());
        }
    }
    Ok(())
}

fn canonical_origin(text: &str) -> bool {
    url::Url::parse(text).is_ok_and(|url| {
        url.scheme() == "https"
            && url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none()
            && url.origin().ascii_serialization() == text
    })
}

fn hex(text: &str, n: usize) -> bool {
    text.len() == n && text.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}
fn id(text: &str, prefix: &str, n: usize) -> bool {
    text.strip_prefix(prefix).is_some_and(|s| hex(s, n))
}
fn native_id(text: &str, prefix: &str) -> bool {
    text.strip_prefix(prefix).is_some_and(|s| {
        s.len() == 26 && s.bytes().all(|b| b"0123456789abcdefghjkmnpqrstvwxyz".contains(&b))
    })
}
fn public_key(text: &str, n: usize) -> bool {
    STANDARD.decode(text).is_ok_and(|bytes| {
        bytes.len() == n
            && bytes.iter().any(|b| *b != 0)
            && (n != 65 || bytes[0] == 4)
            && STANDARD.encode(bytes) == text
    })
}

pub(super) fn install_point(jwk: &Value) -> Option<String> {
    if jwk["kty"] != "EC" || jwk["crv"] != "P-256" {
        return None;
    }
    let mut point = vec![4];
    for name in ["x", "y"] {
        let text = jwk[name].as_str()?;
        let bytes = URL_SAFE_NO_PAD.decode(text).ok()?;
        if bytes.len() != 32 || URL_SAFE_NO_PAD.encode(&bytes) != text {
            return None;
        }
        point.extend_from_slice(&bytes);
    }
    Some(STANDARD.encode(point))
}

// Validate duplicate map members without retaining arbitrary response fields.
pub(super) struct UniqueJson;
impl<'de> Deserialize<'de> for UniqueJson {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct Visitor;
        impl<'de> serde::de::Visitor<'de> for Visitor {
            type Value = UniqueJson;
            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("JSON with unique object members")
            }
            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                mut map: A,
            ) -> Result<UniqueJson, A::Error> {
                let mut seen = BTreeSet::new();
                while let Some(key) = map.next_key::<String>()? {
                    if !seen.insert(key) {
                        return Err(serde::de::Error::custom("duplicate object member"));
                    }
                    map.next_value::<UniqueJson>()?;
                }
                Ok(UniqueJson)
            }
            fn visit_seq<A: serde::de::SeqAccess<'de>>(
                self,
                mut seq: A,
            ) -> Result<UniqueJson, A::Error> {
                while seq.next_element::<UniqueJson>()?.is_some() {}
                Ok(UniqueJson)
            }
            fn visit_str<E: serde::de::Error>(self, _: &str) -> Result<UniqueJson, E> {
                Ok(UniqueJson)
            }
            fn visit_bool<E: serde::de::Error>(self, _: bool) -> Result<UniqueJson, E> {
                Ok(UniqueJson)
            }
            fn visit_i64<E: serde::de::Error>(self, _: i64) -> Result<UniqueJson, E> {
                Ok(UniqueJson)
            }
            fn visit_u64<E: serde::de::Error>(self, _: u64) -> Result<UniqueJson, E> {
                Ok(UniqueJson)
            }
            fn visit_f64<E: serde::de::Error>(self, _: f64) -> Result<UniqueJson, E> {
                Ok(UniqueJson)
            }
            fn visit_unit<E: serde::de::Error>(self) -> Result<UniqueJson, E> {
                Ok(UniqueJson)
            }
        }
        d.deserialize_any(Visitor)
    }
}
