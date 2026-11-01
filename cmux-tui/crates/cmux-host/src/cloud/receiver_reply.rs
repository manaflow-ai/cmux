//! The public agent reply uses the generated policy DTO and the same validation
//! as the original-credential HTTP read. Socket authentication happens first.
use std::time::{Duration, Instant};

use cmux_cloud_wire::BoolLit;
use cmux_link::elapsed::Elapsed;
use cmux_link::keyset::read_keyset;
use cmux_link::native_token::receiver::{Owner, Refresh};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{
    Bound, Env, ReceiverSnapshot, RequiredPolicy, SAFE, UNAVAILABLE, UniqueJson, install_point,
    validate,
};

/// Public self identity from the original protected bootstrap. No bearer,
/// original grant id, private install key or private WG key is retained here.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReceiverBinding {
    pub machine: String,
    pub host: String,
    pub epoch: u64,
    pub user: String,
    pub install: String,
    pub team: String,
    pub env: Env,
    pub wg_public_key: String,
    pub install_public_key: String,
}

impl ReceiverBinding {
    pub fn from_original(bound: &Bound, wg: &str, install_jwk: &Value) -> Result<Self, String> {
        if bound.api_origin != bound.env.api_origin() {
            return Err(UNAVAILABLE.into());
        }
        Ok(Self {
            machine: bound.machine.clone(),
            host: bound.host.clone(),
            epoch: bound.epoch,
            user: bound.user.clone(),
            install: bound.install.clone(),
            team: bound.team.clone(),
            env: bound.env,
            wg_public_key: wg.into(),
            install_public_key: install_point(install_jwk).ok_or(UNAVAILABLE)?,
        })
    }
}

#[derive(Deserialize)]
struct Reply {
    ok: BoolLit<true>,
    value: PublicValue,
}
#[derive(Deserialize)]
struct PublicValue {
    policy: RequiredPolicy,
    keyset: Value,
    issuer: String,
    issuer_time_ms: u64,
    remaining_ms: u64,
}

impl ReceiverSnapshot {
    /// Decode only after authenticating the root agent. `binding` comes from
    /// the original private bootstrap, never from this reply or the caller.
    pub fn from_public_reply(
        bytes: &[u8],
        binding: &ReceiverBinding,
        started: Instant,
        now: Instant,
    ) -> Result<Self, String> {
        Self::decode_public_reply(bytes, binding, started, now, None)
    }

    /// The source observation belongs to this exact read, captured before
    /// executor queuing or socket I/O rather than when its reply arrives.
    pub fn from_public_reply_for_refresh(
        bytes: &[u8],
        binding: &ReceiverBinding,
        refresh: &Refresh,
        now: Instant,
    ) -> Result<Self, String> {
        Self::decode_public_reply(bytes, binding, refresh.started(), now, refresh.elapsed_source())
    }

    fn decode_public_reply(
        bytes: &[u8],
        binding: &ReceiverBinding,
        started: Instant,
        now: Instant,
        source: Option<Elapsed>,
    ) -> Result<Self, String> {
        if bytes.len() > 1024 * 1024 {
            return Err(UNAVAILABLE.into());
        }
        let _: UniqueJson = serde_json::from_slice(bytes).map_err(|_| UNAVAILABLE)?;
        let reply: Reply = serde_json::from_slice(bytes).map_err(|_| UNAVAILABLE)?;
        let _ = reply.ok;
        let PublicValue {
            policy: RequiredPolicy(policy),
            keyset,
            issuer,
            issuer_time_ms,
            remaining_ms,
        } = reply.value;
        validate(&policy, binding)?;
        if issuer != format!("cmux:cloud:{}", binding.env.auth_environment())
            || issuer_time_ms > SAFE as u64
            || issuer_time_ms < policy.checked_at as u64
        {
            return Err(UNAVAILABLE.into());
        }
        let active = now.checked_duration_since(started).ok_or(UNAVAILABLE)?;
        let source_elapsed = match &source {
            Some(source) => Some(source.elapsed().ok_or(UNAVAILABLE)?),
            None => None,
        };
        let elapsed = active.max(source_elapsed.unwrap_or(active));
        let lifetime = (policy.expires_at - policy.checked_at) as u64;
        let lifetime = Duration::from_millis(lifetime);
        if remaining_ms == 0
            || remaining_ms > (policy.expires_at as u64).saturating_sub(issuer_time_ms)
            || elapsed >= lifetime
        {
            return Err(UNAVAILABLE.into());
        }
        // The whole socket round trip already includes the root agent's HTTP
        // work. Cap by both observations rather than charging that work twice.
        let consumed = elapsed
            .max(lifetime.checked_sub(Duration::from_millis(remaining_ms)).ok_or(UNAVAILABLE)?);
        // An earlier effective request start represents the stricter deadline
        // without rewriting authenticated NumericDates. It can only shorten.
        let started = now.checked_sub(consumed).ok_or(UNAVAILABLE)?;
        let elapsed = match source {
            Some(source) => Some(
                source
                    .rewind(consumed.saturating_sub(source_elapsed.ok_or(UNAVAILABLE)?))
                    .ok_or(UNAVAILABLE)?,
            ),
            None => None,
        };
        let keys = read_keyset(&keyset).map_err(|_| UNAVAILABLE)?;
        let snapshot = Self { policy, keys, started, issuer, elapsed };
        if snapshot.time(now).ok_or(UNAVAILABLE)?.unix_ms < issuer_time_ms {
            return Err(UNAVAILABLE.into());
        }
        Ok(snapshot)
    }

    /// Atomically publish one validated snapshot, retaining the owner's replay
    /// state. Errors or cancellation retire only this read's current intent.
    pub fn install(&self, owner: &Owner, refresh: Refresh, now: Instant) -> Result<(), String> {
        if self.started > refresh.started() {
            return Err(UNAVAILABLE.into());
        }
        let time = self.time(now).ok_or(UNAVAILABLE)?;
        owner
            .install(refresh, self.keys.clone(), self.native_policy(), time)
            .map_err(|_| UNAVAILABLE.into())
    }
}
