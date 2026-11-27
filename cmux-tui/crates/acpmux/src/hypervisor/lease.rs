//! Leases enforced on the host (RFD 0100 section 6): no hosted reaper can reach a
//! customer's hypervisor, so the host agent judges every slot's lease with its own clock.
//!
//! - delete-after passed: destroy (the only automatic delete);
//! - max run, idle, or the hub not renewing in time: pause to disk, never delete;
//! - a `cmux-*` VM with no lease (an orphan): pause to disk and report it.

use super::{SlotName, SlotState};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;

/// The hub's lease on a slot, the shape of Freestyle's `idleTimeoutSeconds`,
/// `maxRunSeconds` and `autoDeleteSeconds`. A field left out never fires.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Lease {
    /// Pause to disk after this long with no activity (`touch`).
    pub idle_secs: Option<u64>,
    /// Pause to disk after running this long since its create or last resume.
    pub max_run_secs: Option<u64>,
    /// Destroy this long after the create.
    pub delete_after_secs: Option<u64>,
    /// Pause to disk when the hub has not renewed the lease for this long.
    pub renew_within_secs: Option<u64>,
    /// At session end (`end`), destroy instead of pausing to disk.
    pub delete_on_end: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LeaseRecord {
    pub lease: Lease,
    pub created_ms: u64,
    pub renewed_ms: u64,
    pub active_ms: u64,
    pub running_since_ms: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Reason {
    DeleteAfter,
    MaxRun,
    Idle,
    NotRenewed,
    Orphan,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Verdict {
    PauseToDisk,
    Destroy,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Action {
    pub slot: SlotName,
    pub verdict: Verdict,
    pub reason: Reason,
}

/// Every slot's lease, kept in `leases.json` so a restart keeps the clocks.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LeaseBook {
    pub slots: BTreeMap<SlotName, LeaseRecord>,
}

fn after(start_ms: u64, secs: Option<u64>, now_ms: u64) -> bool {
    secs.is_some_and(|s| now_ms >= start_ms.saturating_add(s.saturating_mul(1000)))
}

impl LeaseBook {
    pub fn load(path: &Path) -> anyhow::Result<Self> {
        match std::fs::read(path) {
            Ok(bytes) => Ok(serde_json::from_slice(&bytes)?),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(e) => Err(e.into()),
        }
    }

    /// Write through a temp file and rename, so a crash never leaves half a book.
    pub fn save(&self, path: &Path) -> anyhow::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        std::fs::rename(&tmp, path)?;
        Ok(())
    }

    /// A create: a slot already leased keeps its clocks and takes the new lease.
    pub fn create(&mut self, slot: &SlotName, lease: Lease, now_ms: u64) {
        let rec = self.slots.entry(slot.clone()).or_insert(LeaseRecord {
            lease: Lease::default(),
            created_ms: now_ms,
            renewed_ms: now_ms,
            active_ms: now_ms,
            running_since_ms: now_ms,
        });
        rec.lease = lease;
        rec.renewed_ms = now_ms;
    }

    /// The hub renewed (optionally with a new lease).
    pub fn renew(&mut self, slot: &SlotName, lease: Option<Lease>, now_ms: u64) -> bool {
        let Some(rec) = self.slots.get_mut(slot) else { return false };
        if let Some(lease) = lease {
            rec.lease = lease;
        }
        rec.renewed_ms = now_ms;
        true
    }

    /// The guest reported activity (a turn ran, something queued).
    pub fn touch(&mut self, slot: &SlotName, now_ms: u64) -> bool {
        let Some(rec) = self.slots.get_mut(slot) else { return false };
        rec.active_ms = now_ms;
        true
    }

    /// A resume restarts the run and idle clocks.
    pub fn resumed(&mut self, slot: &SlotName, now_ms: u64) {
        if let Some(rec) = self.slots.get_mut(slot) {
            rec.running_since_ms = now_ms;
            rec.active_ms = now_ms;
        }
    }

    pub fn remove(&mut self, slot: &SlotName) {
        self.slots.remove(slot);
    }

    /// Drop the records of slots the hypervisor no longer has.
    pub fn retain_present(&mut self, present: &[(SlotName, SlotState)]) -> Vec<SlotName> {
        let gone: Vec<SlotName> =
            self.slots.keys().filter(|k| !present.iter().any(|(n, _)| n == *k)).cloned().collect();
        for g in &gone {
            self.slots.remove(g);
        }
        gone
    }

    /// What the host must do now, for the slots the hypervisor reports.
    pub fn judge(&self, present: &[(SlotName, SlotState)], now_ms: u64) -> Vec<Action> {
        let mut actions = Vec::new();
        for (slot, state) in present {
            let live = matches!(state, SlotState::Running | SlotState::Paused);
            let act = |verdict, reason| Action { slot: slot.clone(), verdict, reason };
            let Some(rec) = self.slots.get(slot) else {
                if live {
                    actions.push(act(Verdict::PauseToDisk, Reason::Orphan));
                }
                continue;
            };
            let l = &rec.lease;
            if after(rec.created_ms, l.delete_after_secs, now_ms) {
                actions.push(act(Verdict::Destroy, Reason::DeleteAfter));
                continue;
            }
            if !live {
                continue;
            }
            let pause = if after(rec.running_since_ms, l.max_run_secs, now_ms) {
                Some(Reason::MaxRun)
            } else if after(rec.active_ms, l.idle_secs, now_ms) {
                Some(Reason::Idle)
            } else if after(rec.renewed_ms, l.renew_within_secs, now_ms) {
                Some(Reason::NotRenewed)
            } else {
                None
            };
            if let Some(reason) = pause {
                actions.push(act(Verdict::PauseToDisk, reason));
            }
        }
        actions
    }
}
