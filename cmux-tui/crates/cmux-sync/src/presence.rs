//! Who's here: people and agents, on which devices, active or not, in which scope.
//!
//! Chat-gateway presence, small: each device of each member sends a [`Beat`] every few seconds
//! (a heartbeat carrying its status), the table keeps the newest per (member, device), and a device
//! that stops beating is gone after [`Presence::ttl_ms`]. Nothing is persisted: a restart starts
//! empty and fills within one beat interval. A beat has a per-device sequence number, so the same
//! beat arriving twice (gossiped through two peers, or replayed on reconnect) counts once and an
//! older one never overwrites a newer one.
//!
//! Ages are measured on the receiver's clock from when a beat arrived, never from the sender's wall
//! time, so a phone whose clock is off cannot keep itself alive or vanish early.
//!
//! [`Presence::here`] folds the table into one [`Here`] per member: every device it is on, and its
//! best status across them (a person active on the phone is active, whatever the Mac says). That is
//! the sidebar's "who's here" and what agents read to know who can answer.
//!
//! It extends what acpmux keeps per chat (`acpmux/src/hub/presence.rs`: who views and types in one
//! chat) to agents and to scopes wider than a chat: a workspace, a machine, a team.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// A person or an agent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Person,
    Agent,
}

/// Who a beat is for.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct Member {
    /// Stable id: `person:<login>` or `agent:<host>/<session name>`.
    pub id: String,
    pub name: String,
    pub kind: Kind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DeviceKind {
    Mac,
    Vm,
    Phone,
    Web,
    Other,
}

/// What the member is doing on that device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Activity {
    /// Present; [`Status`] then follows the time since the last input.
    Present,
    /// Typing (a person) or in a turn (an agent): active regardless of input age.
    Working,
    /// Stepped away on purpose (screen locked, app in the background).
    Away,
}

/// One heartbeat.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Beat {
    pub member: Member,
    /// The device's stable id (an install id, a machine id).
    pub device: String,
    pub device_kind: DeviceKind,
    /// Per (member, device), increasing; an older or equal one is ignored.
    pub seq: u64,
    pub activity: Activity,
    /// Milliseconds since the last input on the device, as the device measured it at send time.
    pub idle_ms: u64,
    /// Where the member is: a chat id, a workspace id, a machine. Empty is "on the machine, nowhere
    /// in particular".
    pub scopes: Vec<String>,
}

/// A member's status, best first (the derived order is the ranking).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Status {
    Active,
    Idle,
    Away,
}

/// One device in a member's [`Here`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HereDevice {
    pub device: String,
    pub device_kind: DeviceKind,
    pub status: Status,
    pub working: bool,
    /// Milliseconds since this device's beat arrived.
    pub age_ms: u64,
}

/// One member who is here.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Here {
    pub member: Member,
    /// Best across devices.
    pub status: Status,
    /// Typing or in a turn on any device.
    pub working: bool,
    pub devices: Vec<HereDevice>,
}

#[derive(Debug, Clone)]
struct Seen {
    beat: Beat,
    at_ms: u64,
}

/// The presence table.
#[derive(Debug, Clone)]
pub struct Presence {
    /// A device with no beat for this long is gone.
    pub ttl_ms: u64,
    /// No input for this long: idle.
    pub idle_after_ms: u64,
    /// No input for this long: away.
    pub away_after_ms: u64,
    seen: BTreeMap<(String, String), Seen>,
}

impl Default for Presence {
    fn default() -> Self {
        // Beats every 10 s; three missed is gone, as a chat gateway closes a session that misses
        // its heartbeat ack. Idle at 2 minutes and away at 10, as chat apps do.
        Self {
            ttl_ms: 30_000,
            idle_after_ms: 120_000,
            away_after_ms: 600_000,
            seen: BTreeMap::new(),
        }
    }
}

impl Presence {
    /// Take a beat that arrived at `now_ms`. Returns whether it changed what [`here`](Self::here)
    /// would say about its member's device set or status (a fresher beat with the same status
    /// returns false, so a host can fan out only real changes).
    pub fn beat(&mut self, beat: Beat, now_ms: u64) -> bool {
        let key = (beat.member.id.clone(), beat.device.clone());
        let before = self.seen.get(&key).map(|s| self.device_view(s, now_ms));
        if let Some(old) = self.seen.get(&key)
            && old.beat.seq >= beat.seq
        {
            return false;
        }
        let seen = Seen { beat, at_ms: now_ms };
        let after = self.device_view(&seen, now_ms);
        let scopes_changed =
            self.seen.get(&key).is_none_or(|old| old.beat.scopes != seen.beat.scopes);
        self.seen.insert(key, seen);
        scopes_changed
            || before.is_none_or(|b| (b.status, b.working) != (after.status, after.working))
    }

    /// A device said goodbye (closed the app, ended the session). `seq` must be newer than its
    /// last beat, as a late beat must not bring it back.
    pub fn leave(&mut self, member: &str, device: &str, seq: u64) -> bool {
        let key = (member.to_owned(), device.to_owned());
        match self.seen.get(&key) {
            Some(s) if s.beat.seq < seq => {
                self.seen.remove(&key);
                true
            }
            _ => false,
        }
    }

    /// Drop devices past the time to live; returns the members that lost a device.
    pub fn expire(&mut self, now_ms: u64) -> Vec<String> {
        let ttl = self.ttl_ms;
        let mut gone: Vec<String> = Vec::new();
        self.seen.retain(|(member, _), s| {
            let keep = now_ms.saturating_sub(s.at_ms) < ttl;
            if !keep {
                gone.push(member.clone());
            }
            keep
        });
        gone.sort();
        gone.dedup();
        gone
    }

    fn device_view(&self, s: &Seen, now_ms: u64) -> HereDevice {
        let age_ms = now_ms.saturating_sub(s.at_ms);
        let idle = s.beat.idle_ms.saturating_add(age_ms);
        let working = s.beat.activity == Activity::Working;
        let status = match s.beat.activity {
            Activity::Away => Status::Away,
            Activity::Working => Status::Active,
            Activity::Present if idle >= self.away_after_ms => Status::Away,
            Activity::Present if idle >= self.idle_after_ms => Status::Idle,
            Activity::Present => Status::Active,
        };
        HereDevice {
            device: s.beat.device.clone(),
            device_kind: s.beat.device_kind,
            status,
            working,
            age_ms,
        }
    }

    /// Who's here in `scope` (`None`: anywhere), at `now_ms`: active first, then idle, then away,
    /// people before agents, then by name. Devices past the time to live are left out even before
    /// [`expire`](Self::expire) runs.
    pub fn here(&self, scope: Option<&str>, now_ms: u64) -> Vec<Here> {
        let mut by_member: BTreeMap<&str, Here> = BTreeMap::new();
        for ((member, _), s) in &self.seen {
            if now_ms.saturating_sub(s.at_ms) >= self.ttl_ms {
                continue;
            }
            if let Some(scope) = scope
                && !s.beat.scopes.iter().any(|x| x == scope)
            {
                continue;
            }
            let device = self.device_view(s, now_ms);
            let here = by_member.entry(member).or_insert_with(|| Here {
                member: s.beat.member.clone(),
                status: device.status,
                working: false,
                devices: Vec::new(),
            });
            here.status = here.status.min(device.status);
            here.working |= device.working;
            here.devices.push(device);
        }
        let mut out: Vec<Here> = by_member.into_values().collect();
        for h in &mut out {
            h.devices.sort_by(|a, b| a.status.cmp(&b.status).then(a.age_ms.cmp(&b.age_ms)));
        }
        out.sort_by(|a, b| {
            (a.status, a.member.kind, &a.member.name).cmp(&(
                b.status,
                b.member.kind,
                &b.member.name,
            ))
        });
        out
    }

    /// Every beat still alive, to hand a peer that just connected (its catch-up, like a gateway's
    /// READY payload), with each one's `idle_ms` advanced by its age here.
    pub fn live_beats(&self, now_ms: u64) -> Vec<Beat> {
        self.seen
            .values()
            .filter(|s| now_ms.saturating_sub(s.at_ms) < self.ttl_ms)
            .map(|s| {
                let mut b = s.beat.clone();
                b.idle_ms = b.idle_ms.saturating_add(now_ms.saturating_sub(s.at_ms));
                b
            })
            .collect()
    }
}

#[cfg(test)]
#[path = "presence_tests.rs"]
mod tests;
