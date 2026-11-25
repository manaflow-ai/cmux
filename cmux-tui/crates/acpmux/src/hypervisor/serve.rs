//! The host agent's loop: take commands, apply them, then judge every lease against what
//! the hypervisor actually runs, and write the slot list the heartbeat will carry
//! (RFD 0100 section 6, "Reconcile").

use super::lease::{Action, LeaseBook, Reason, Verdict};
use super::source::{Command, CommandSource, Envelope, Outcome};
use super::{HypervisorDriver, PauseMode, Slot, SlotName, SlotState};
use anyhow::Result;
use serde::Serialize;
use std::path::PathBuf;

pub struct HostAgent<D, S> {
    pub driver: D,
    pub source: S,
    /// `leases.json`; `status.json` beside it.
    pub state_dir: PathBuf,
    pub book: LeaseBook,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Applied {
    pub id: String,
    pub outcome: Outcome,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Enforced {
    pub action: Action,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// One pass: what ran, and the slots after it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Tick {
    pub at_ms: u64,
    pub applied: Vec<Applied>,
    pub enforced: Vec<Enforced>,
    pub slots: Vec<Slot>,
    /// `cmux-*` VMs with no lease: reported, paused to disk, never deleted.
    pub orphans: Vec<SlotName>,
    /// Leases whose VM is gone from the hypervisor (the hub marks the record `gone`).
    pub gone: Vec<SlotName>,
}

impl<D: HypervisorDriver, S: CommandSource> HostAgent<D, S> {
    pub fn open(driver: D, source: S, state_dir: PathBuf) -> Result<Self> {
        let book = LeaseBook::load(&state_dir.join("leases.json"))?;
        Ok(Self { driver, source, state_dir, book })
    }

    fn apply(&mut self, env: &Envelope, now_ms: u64) -> Result<Option<SlotState>> {
        match &env.command {
            Command::Create { slot, spec, lease } => {
                let state = self.driver.create(slot, spec)?;
                self.book.create(slot, lease.clone(), now_ms);
                Ok(Some(state))
            }
            Command::Pause { slot, mode } => Ok(Some(self.driver.pause(slot, *mode)?)),
            Command::Resume { slot } => {
                let state = self.driver.resume(slot)?;
                self.book.resumed(slot, now_ms);
                Ok(Some(state))
            }
            Command::Destroy { slot } => {
                self.driver.destroy(slot)?;
                self.book.remove(slot);
                Ok(None)
            }
            Command::Renew { slot, lease } => {
                anyhow::ensure!(
                    self.book.renew(slot, lease.clone(), now_ms),
                    "no lease on slot {slot}"
                );
                Ok(None)
            }
            Command::Touch { slot } => {
                anyhow::ensure!(self.book.touch(slot, now_ms), "no lease on slot {slot}");
                Ok(None)
            }
            Command::End { slot } => {
                let delete = self.book.slots.get(slot).is_some_and(|r| r.lease.delete_on_end);
                if delete {
                    self.driver.destroy(slot)?;
                    self.book.remove(slot);
                    Ok(None)
                } else {
                    Ok(Some(self.driver.pause(slot, PauseMode::Disk)?))
                }
            }
        }
    }

    /// One pass at `now_ms`. A failed command or action is reported, never fatal; only a
    /// failed `list` or state write ends the pass with an error.
    pub fn tick(&mut self, now_ms: u64) -> Result<Tick> {
        let mut applied = Vec::new();
        for env in self.source.take()? {
            let outcome = match self.apply(&env, now_ms) {
                Ok(state) => Outcome { ok: true, state, error: None },
                Err(e) => Outcome { ok: false, state: None, error: Some(format!("{e:#}")) },
            };
            self.source.ack(&env, &outcome)?;
            applied.push(Applied { id: env.id.clone(), outcome });
        }

        let present: Vec<(SlotName, SlotState)> =
            self.driver.list()?.into_iter().map(|s| (s.name, s.state)).collect();
        let gone = self.book.retain_present(&present);
        let orphans: Vec<SlotName> = present
            .iter()
            .filter(|(n, _)| !self.book.slots.contains_key(n))
            .map(|(n, _)| n.clone())
            .collect();

        let mut enforced = Vec::new();
        for action in self.book.judge(&present, now_ms) {
            let result = match action.verdict {
                Verdict::Destroy => self.driver.destroy(&action.slot).map(|()| {
                    self.book.remove(&action.slot);
                }),
                Verdict::PauseToDisk => {
                    self.driver.pause(&action.slot, PauseMode::Disk).map(|_| ())
                }
            };
            enforced.push(Enforced { action, error: result.err().map(|e| format!("{e:#}")) });
        }

        let slots =
            if enforced.is_empty() { present_slots(&present) } else { self.driver.list()? };
        self.book.save(&self.state_dir.join("leases.json"))?;
        let tick = Tick { at_ms: now_ms, applied, enforced, slots, orphans, gone };
        write_status(&self.state_dir, &tick)?;
        Ok(tick)
    }
}

fn present_slots(present: &[(SlotName, SlotState)]) -> Vec<Slot> {
    present.iter().map(|(name, state)| Slot { name: name.clone(), state: *state }).collect()
}

fn write_status(dir: &std::path::Path, tick: &Tick) -> Result<()> {
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join("status.json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(tick)?)?;
    std::fs::rename(&tmp, dir.join("status.json"))?;
    Ok(())
}

/// A one-line summary of what an action did, for the serve log.
pub fn action_line(e: &Enforced) -> String {
    let verb = match e.action.verdict {
        Verdict::Destroy => "destroyed",
        Verdict::PauseToDisk => "paused to disk",
    };
    let why = match e.action.reason {
        Reason::DeleteAfter => "its delete-after passed",
        Reason::MaxRun => "it ran its max run time",
        Reason::Idle => "it was idle past its lease",
        Reason::NotRenewed => "the hub did not renew its lease",
        Reason::Orphan => "no lease names it (orphan)",
    };
    match &e.error {
        None => format!("{} {verb}: {why}", e.action.slot),
        Some(err) => format!("{} not {verb} ({why}): {err}", e.action.slot),
    }
}
