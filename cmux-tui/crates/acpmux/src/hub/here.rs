//! Who's here, machine-wide: the heartbeats each client sends for its person on one device
//! (`_acpmux/here/beat`), held by `cmux_sync::Presence`, with the agents in a turn on this daemon
//! folded in as members, so the sidebar's status icon and the phone answer "who is on this
//! machine now, and where" from one read (`_acpmux/here`).
//!
//! Leo, 2026-11-24: "i think there's even situations where we can have an icon maybe toggle
//! somewhere omnipresent... say the bottom left of the sidebar area".
//!
//! Per-chat presence (who has a chat open, who types) stays in `presence.rs`; this is its
//! machine-wide counterpart and, like it, is never persisted: a restart forgets every beat and
//! the clients' next beats (every 10 s) refill it.

use std::sync::Mutex as StdMutex;
use std::time::{SystemTime, UNIX_EPOCH};

use cmux_sync::{Activity, Beat, DeviceKind, Kind, Member, Presence, Status};
use serde_json::Value;

use super::Hub;
use super::presence::Who;
use crate::protocol::here::{
    HereActivity, HereBeatDone, HereBeatParams, HereDevice, HereDeviceKind, HereKind, HereMember,
    HereParams, HereResult, HereStatus,
};
use crate::rpc::RpcError;

/// Devices held at once: a beat for a new device past it is refused (`here.full`), so a client
/// that makes up device ids cannot grow the table.
const MAX_DEVICES: usize = 64;
const MAX_SCOPES: usize = 16;
const MAX_SCOPE_BYTES: usize = 256;
const MAX_DEVICE_BYTES: usize = 128;

/// The table, behind a leaf lock held for no await.
#[derive(Default)]
pub struct HereTable {
    table: StdMutex<Presence>,
}

fn wall_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

fn refused(code: &str, message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message.into()).with_data(serde_json::json!({ "reason": code }))
}

fn one_line(s: &str, max: usize) -> bool {
    !s.is_empty() && s.len() <= max && !s.chars().any(char::is_control)
}

impl HereTable {
    /// Take one heartbeat for `who`. Pure but for the lock; `now_ms` is the daemon's clock.
    pub fn beat(&self, who: &Who, p: HereBeatParams, now_ms: u64) -> Result<bool, RpcError> {
        if !one_line(&p.device, MAX_DEVICE_BYTES) {
            return Err(refused(
                "here.device_refused",
                "device must be one line of 1 to 128 bytes",
            ));
        }
        if p.scopes.len() > MAX_SCOPES || p.scopes.iter().any(|s| !one_line(s, MAX_SCOPE_BYTES)) {
            return Err(refused(
                "here.scopes_refused",
                "scopes: at most 16, each one line of 1 to 256 bytes",
            ));
        }
        let mut table = self.table.lock().unwrap_or_else(|e| e.into_inner());
        if p.leave {
            return Ok(table.leave(&who.id, &p.device, p.seq));
        }
        table.expire(now_ms);
        let live = table.live_beats(now_ms);
        let known = live.iter().any(|b| b.member.id == who.id && b.device == p.device);
        if !known && live.len() >= MAX_DEVICES {
            return Err(refused("here.full", "64 devices are here already"));
        }
        let beat = Beat {
            member: Member { id: who.id.clone(), name: who.name.clone(), kind: Kind::Person },
            device: p.device,
            device_kind: device_kind(p.device_kind),
            seq: p.seq,
            activity: match p.activity {
                HereActivity::Present => Activity::Present,
                HereActivity::Working => Activity::Working,
                HereActivity::Away => Activity::Away,
            },
            idle_ms: p.idle_ms,
            scopes: p.scopes,
        };
        Ok(table.beat(beat, now_ms))
    }

    /// Who is here now, people from their beats and `agents` (in a turn) folded in.
    pub fn here(&self, scope: Option<&str>, agents: Vec<Agent>, now_ms: u64) -> HereResult {
        let mut table = self.table.lock().unwrap_or_else(|e| e.into_inner());
        table.expire(now_ms);
        let mut here: Vec<HereMember> = table
            .here(scope, now_ms)
            .into_iter()
            .map(|h| HereMember {
                id: h.member.id,
                name: h.member.name,
                kind: match h.member.kind {
                    Kind::Person => HereKind::Person,
                    Kind::Agent => HereKind::Agent,
                },
                status: status(h.status),
                working: h.working,
                devices: h
                    .devices
                    .into_iter()
                    .map(|d| HereDevice {
                        device: d.device,
                        device_kind: here_device_kind(d.device_kind),
                        status: status(d.status),
                        working: d.working,
                        age_ms: d.age_ms,
                    })
                    .collect(),
            })
            .collect();
        drop(table);
        let device = this_device();
        here.extend(agents.into_iter().filter(|a| scope.is_none_or(|s| s == a.session)).map(|a| {
            HereMember {
                id: a.session,
                name: a.name,
                kind: HereKind::Agent,
                status: HereStatus::Active,
                working: true,
                devices: vec![HereDevice {
                    device: device.0.clone(),
                    device_kind: device.1,
                    status: HereStatus::Active,
                    working: true,
                    age_ms: 0,
                }],
            }
        }));
        // People's beats come sorted; the agents join them in the same order: active (all of
        // them are), people before agents, then by name.
        here.sort_by(|a, b| {
            rank(a.status)
                .cmp(&rank(b.status))
                .then((a.kind == HereKind::Agent).cmp(&(b.kind == HereKind::Agent)))
                .then_with(|| a.name.cmp(&b.name))
        });
        HereResult { here }
    }
}

/// An agent in a turn on this daemon.
pub struct Agent {
    pub session: String,
    pub name: String,
}

fn rank(s: HereStatus) -> u8 {
    match s {
        HereStatus::Active => 0,
        HereStatus::Idle => 1,
        HereStatus::Away => 2,
    }
}

fn status(s: Status) -> HereStatus {
    match s {
        Status::Active => HereStatus::Active,
        Status::Idle => HereStatus::Idle,
        Status::Away => HereStatus::Away,
    }
}

fn device_kind(k: HereDeviceKind) -> DeviceKind {
    match k {
        HereDeviceKind::Mac => DeviceKind::Mac,
        HereDeviceKind::Vm => DeviceKind::Vm,
        HereDeviceKind::Phone => DeviceKind::Phone,
        HereDeviceKind::Web => DeviceKind::Web,
        HereDeviceKind::Other => DeviceKind::Other,
    }
}

fn here_device_kind(k: DeviceKind) -> HereDeviceKind {
    match k {
        DeviceKind::Mac => HereDeviceKind::Mac,
        DeviceKind::Vm => HereDeviceKind::Vm,
        DeviceKind::Phone => HereDeviceKind::Phone,
        DeviceKind::Web => HereDeviceKind::Web,
        DeviceKind::Other => HereDeviceKind::Other,
    }
}

/// This daemon's machine, as the device its agents are on.
fn this_device() -> (String, HereDeviceKind) {
    let host = std::env::var("HOSTNAME")
        .ok()
        .filter(|h| one_line(h, MAX_DEVICE_BYTES))
        .unwrap_or_else(|| "this-machine".to_owned());
    let kind = if cfg!(target_os = "macos") { HereDeviceKind::Mac } else { HereDeviceKind::Vm };
    (host, kind)
}

impl Hub {
    /// `_acpmux/here/beat`.
    pub fn here_beat(&self, params: &Value) -> Result<HereBeatDone, RpcError> {
        let author = crate::author::author(params)?;
        let p: HereBeatParams = serde_json::from_value(params.clone())
            .map_err(|e| RpcError::invalid_params(format!("_acpmux/here/beat: {e}")))?;
        let changed = self.here.beat(&Who::of(author.as_ref()), p, wall_ms())?;
        Ok(HereBeatDone { changed })
    }

    /// `_acpmux/here`: one pass over the sessions' turn slots, no metadata read for an idle one.
    pub fn here_now(&self, params: &Value) -> Result<HereResult, RpcError> {
        let p: HereParams = serde_json::from_value(params.clone())
            .map_err(|e| RpcError::invalid_params(format!("_acpmux/here: {e}")))?;
        let agents = self
            .session_handles()
            .into_iter()
            .filter(|s| s.turn().is_some())
            .map(|s| {
                let meta = s.meta();
                let name = meta.title.filter(|t| !t.is_empty()).unwrap_or(meta.name);
                Agent { session: s.id.clone(), name }
            })
            .collect();
        Ok(self.here.here(p.scope.as_deref(), agents, wall_ms()))
    }
}

#[cfg(test)]
#[path = "here_tests.rs"]
mod tests;
