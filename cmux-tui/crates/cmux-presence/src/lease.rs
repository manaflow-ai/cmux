use serde::{Deserialize, Serialize};

use crate::{Doing, FileTarget, Kind, Presence, PresenceId, Status};

/// Only the fields changed since `base`. An empty list with a newer epoch renews the lease.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Delta {
    id: PresenceId,
    base: u64,
    epoch: u64,
    changes: Vec<Change>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum Change {
    Kind(Kind),
    Name(Box<str>),
    Color(Option<Box<str>>),
    AvatarRef(Option<Box<str>>),
    Status(Status),
    Space(Option<Box<str>>),
    Workspace(Option<Box<str>>),
    Chat(Option<Box<str>>),
    File(Option<FileTarget>),
    Doing(Doing),
    Following(Option<PresenceId>),
    LeaseMs(u32),
}

impl Delta {
    pub fn between(old: &Presence, new: &Presence) -> Option<Self> {
        if old.id != new.id || old.epoch >= new.epoch {
            return None;
        }
        let mut changes = Vec::new();
        macro_rules! changed {
            ($variant:ident, $($field:ident).+) => {
                if old.$($field).+ != new.$($field).+ {
                    changes.push(Change::$variant(new.$($field).+.clone()));
                }
            };
        }
        changed!(Kind, kind);
        changed!(Name, name);
        changed!(Color, color);
        changed!(AvatarRef, avatar_ref);
        changed!(Status, status);
        changed!(Space, location.space);
        changed!(Workspace, location.workspace);
        changed!(Chat, location.chat);
        changed!(File, location.file);
        changed!(Doing, doing);
        changed!(Following, following);
        changed!(LeaseMs, lease_ms);
        Some(Self { id: old.id.clone(), base: old.epoch, epoch: new.epoch, changes })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Merge {
    Applied,
    Stale,
    WrongOwner,
    WrongId,
    /// A field delta cannot fill a gap. Request one current full snapshot from the owner.
    NeedSnapshot,
}

/// One subscription to an id in an owner's session. Keep its epoch watermark until the subscription
/// closes, including while offline. A new owner session starts from a fresh authoritative snapshot.
pub struct Lease {
    owner: Box<str>,
    id: PresenceId,
    epoch: u64,
    until_ms: u64,
    record: Option<Presence>,
}

impl Lease {
    pub fn new(owner: impl Into<Box<str>>, record: Presence, now_ms: u64) -> Self {
        Self {
            owner: owner.into(),
            id: record.id.clone(),
            epoch: record.epoch,
            until_ms: now_ms.saturating_add(u64::from(record.lease_ms)),
            record: Some(record),
        }
    }

    pub fn get(&self, now_ms: u64) -> Option<&Presence> {
        self.record.as_ref().filter(|_| now_ms < self.until_ms)
    }

    /// The caller schedules this deadline or calls expire when advancing a virtual clock.
    pub fn deadline(&self) -> Option<u64> {
        self.record.as_ref().map(|_| self.until_ms)
    }

    pub fn expire(&mut self, now_ms: u64) -> bool {
        now_ms >= self.until_ms && self.record.take().is_some()
    }

    fn reject(&self, owner: &str, id: &PresenceId, epoch: u64) -> Option<Merge> {
        if self.owner.as_ref() != owner {
            Some(Merge::WrongOwner)
        } else if *id != self.id {
            Some(Merge::WrongId)
        } else if epoch <= self.epoch {
            Some(Merge::Stale)
        } else {
            None
        }
    }

    pub fn merge(&mut self, owner: &str, record: Presence, now_ms: u64) -> Merge {
        if let Some(reason) = self.reject(owner, &record.id, record.epoch) {
            return reason;
        }
        self.epoch = record.epoch;
        self.until_ms = now_ms.saturating_add(u64::from(record.lease_ms));
        self.record = Some(record);
        Merge::Applied
    }

    pub fn apply(&mut self, owner: &str, delta: Delta, now_ms: u64) -> Merge {
        if let Some(reason) = self.reject(owner, &delta.id, delta.epoch) {
            return reason;
        }
        if self.epoch != delta.base || now_ms >= self.until_ms {
            return Merge::NeedSnapshot;
        }
        let Some(record) = &mut self.record else { return Merge::NeedSnapshot };
        for field in delta.changes {
            match field {
                Change::Kind(v) => record.kind = v,
                Change::Name(v) => record.name = v,
                Change::Color(v) => record.color = v,
                Change::AvatarRef(v) => record.avatar_ref = v,
                Change::Status(v) => record.status = v,
                Change::Space(v) => record.location.space = v,
                Change::Workspace(v) => record.location.workspace = v,
                Change::Chat(v) => record.location.chat = v,
                Change::File(v) => record.location.file = v,
                Change::Doing(v) => record.doing = v,
                Change::Following(v) => record.following = v,
                Change::LeaseMs(v) => record.lease_ms = v,
            }
        }
        record.epoch = delta.epoch;
        self.epoch = delta.epoch;
        self.until_ms = now_ms.saturating_add(u64::from(record.lease_ms));
        Merge::Applied
    }
}
