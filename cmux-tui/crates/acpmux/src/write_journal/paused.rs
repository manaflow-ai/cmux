//! The paused machines one daemon answers for: each one's folder, replica and journal (M20).
//!
//! [`PausedFs::pause`] seeds a replica from the machine's folder ([`super::seed`]). While the
//! machine is paused, a read or write under its folder is answered here ([`PausedFs::read`],
//! [`PausedFs::write`]): the journal first, then the replica, with no resume. What neither can
//! answer is [`Routed::NeedsMachine`]: the caller resumes the machine (its [`MachineResume`])
//! and asks it directly. [`PausedFs::resumed`] is the barrier: the replica stops answering, the
//! journal is applied on the machine's folder in order ([`super::flush`]), and each conflict is
//! kept for the agent's next file call ([`PausedFs::take_notices`]).
//!
//! The replica also stops answering once the daemon itself saw a resume gap since the seed
//! (`Hub::resume_count`, the count `Hub::subscribe_resumes` watches): anything may have run.

use super::flush::{DirMachineFs, FlushReport, flush};
use super::replica::{JournalError, ReadOutcome, WriteOutcome, read_text, write_text};
use super::seed::{SeedBounds, SeedReport, SeededReplica, seed};
use super::{JournalStore, WriteJournal};
use std::collections::BTreeMap;
use std::future::Future;
use std::io;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::{Arc, Mutex};

pub use super::replica::NeedsMachine;

/// Resumes one machine; done when the machine runs again.
pub trait MachineResume: Send + Sync {
    fn resume<'a>(
        &'a self,
        machine: &'a str,
    ) -> Pin<Box<dyn Future<Output = io::Result<()>> + Send + 'a>>;
}

/// The answer for a path under a known machine's folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Routed<T> {
    /// The machine runs: ask its folder as usual.
    NotPaused,
    Answered(T),
    /// Paused, and only the machine can answer: resume it first.
    NeedsMachine(NeedsMachine),
}

struct Paused {
    replica: Arc<SeededReplica>,
    resumer: Arc<dyn MachineResume>,
    /// The daemon's resume count at the seed.
    hub_resumes: u64,
}

struct Machine {
    root: PathBuf,
    canonical: PathBuf,
    journal: WriteJournal,
    paused: Option<Paused>,
    generation: u64,
    /// For the agent's next file call: conflicts of the last flush, and a flush that stopped.
    notices: Vec<String>,
}

impl Machine {
    fn rel(&self, path: &Path) -> Option<String> {
        let rel = path.strip_prefix(&self.root).or_else(|_| path.strip_prefix(&self.canonical));
        rel.ok().and_then(|r| r.to_str()).map(str::to_owned)
    }

    fn holds(&self, path: &Path) -> bool {
        path.starts_with(&self.root) || path.starts_with(&self.canonical)
    }
}

/// Every machine this daemon has paused, by id.
pub struct PausedFs {
    store: Arc<dyn JournalStore>,
    replicas: PathBuf,
    bounds: SeedBounds,
    machines: Mutex<BTreeMap<String, Machine>>,
}

impl PausedFs {
    /// Journals in `store`; replicas in folders under `replicas` (the daemon's own).
    pub fn new(
        store: Arc<dyn JournalStore>,
        replicas: impl Into<PathBuf>,
        bounds: SeedBounds,
    ) -> Self {
        Self { store, replicas: replicas.into(), bounds, machines: Mutex::new(BTreeMap::new()) }
    }

    fn guard(&self) -> std::sync::MutexGuard<'_, BTreeMap<String, Machine>> {
        self.machines.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn replica_dir(&self, machine: &str, generation: u64) -> PathBuf {
        let name: String = machine.bytes().map(|b| format!("{b:02x}")).collect();
        self.replicas.join(name).join(generation.to_string())
    }

    /// `machine` (its working tree at `root`) is paused: seed its replica now, while nothing runs
    /// there. `hub_resumes` is the daemon's resume count now. Blocking.
    pub fn pause(
        &self,
        machine: &str,
        root: &Path,
        resumer: Arc<dyn MachineResume>,
        hub_resumes: u64,
    ) -> io::Result<SeedReport> {
        let canonical = root.canonicalize()?;
        let generation = {
            let mut all = self.guard();
            let m = match all.remove(machine) {
                Some(m) => m,
                None => Machine {
                    root: root.to_path_buf(),
                    canonical: canonical.clone(),
                    journal: WriteJournal::open(self.store.clone(), machine)?,
                    paused: None,
                    generation: 0,
                    notices: Vec::new(),
                },
            };
            let generation = m.generation.saturating_add(1);
            all.insert(machine.to_owned(), Machine { generation, ..m });
            generation
        };
        let (replica, report) =
            seed(&canonical, &self.replica_dir(machine, generation), self.bounds, generation)?;
        let mut all = self.guard();
        let Some(m) = all.get_mut(machine).filter(|m| m.generation == generation) else {
            // Paused again meanwhile: that seed is the one that answers.
            drop(all);
            let _ = crate::home_fs::remove_dir_all(replica.root());
            return Ok(report);
        };
        m.root = root.to_path_buf();
        m.canonical = canonical;
        let old = m.paused.replace(Paused { replica: Arc::new(replica), resumer, hub_resumes });
        drop(all);
        if let Some(old) = old {
            old.replica.invalidate();
            let _ = crate::home_fs::remove_dir_all(old.replica.root());
        }
        Ok(report)
    }

    /// The machine whose folder holds `cwd` (the deepest one), paused or not.
    pub fn machine_of(&self, cwd: &Path) -> Option<String> {
        let all = self.guard();
        all.iter()
            .filter(|(_, m)| m.holds(cwd))
            .max_by_key(|(_, m)| m.root.components().count())
            .map(|(id, _)| id.clone())
    }

    pub fn is_paused(&self, machine: &str) -> bool {
        self.guard().get(machine).is_some_and(|m| m.paused.is_some())
    }

    /// The resumer `pause` was given, while `machine` is paused.
    pub fn resumer(&self, machine: &str) -> Option<Arc<dyn MachineResume>> {
        self.guard().get(machine).and_then(|m| m.paused.as_ref()).map(|p| p.resumer.clone())
    }

    /// Runs `f` on a paused machine's journal and replica, with `path` relative to its folder.
    fn with_paused<T>(
        &self,
        machine: &str,
        path: &Path,
        hub_resumes: u64,
        f: impl FnOnce(&mut WriteJournal, &SeededReplica, &str) -> Result<Routed<T>, JournalError>,
    ) -> Result<Routed<T>, JournalError> {
        let mut all = self.guard();
        let Some(m) = all.get_mut(machine) else { return Ok(Routed::NotPaused) };
        let Some(paused) = &m.paused else { return Ok(Routed::NotPaused) };
        if paused.hub_resumes != hub_resumes {
            paused.replica.invalidate();
        }
        let replica = paused.replica.clone();
        let Some(rel) = m.rel(path) else {
            return Ok(Routed::NeedsMachine(NeedsMachine::MachineOnly));
        };
        f(&mut m.journal, &replica, &rel)
    }

    /// A text read of `path` (absolute) on paused `machine`. Blocking (the replica's file).
    pub fn read(
        &self,
        machine: &str,
        path: &Path,
        hub_resumes: u64,
    ) -> Result<Routed<ReadOutcome>, JournalError> {
        self.with_paused(machine, path, hub_resumes, |journal, replica, rel| {
            Ok(match read_text(journal, replica, rel)? {
                ReadOutcome::NeedsMachine(why) => Routed::NeedsMachine(why),
                read => Routed::Answered(read),
            })
        })
    }

    /// A write of `content` to `path` (absolute) on paused `machine`: durable in the journal when
    /// answered. Blocking (the store's sync).
    pub fn write(
        &self,
        machine: &str,
        path: &Path,
        content: &str,
        hub_resumes: u64,
        at_ms: u64,
    ) -> Result<Routed<u64>, JournalError> {
        self.with_paused(machine, path, hub_resumes, |journal, replica, rel| {
            Ok(match write_text(journal, replica, rel, Some(content), at_ms)? {
                WriteOutcome::Journaled(seq) => Routed::Answered(seq),
                WriteOutcome::NeedsMachine(why) => Routed::NeedsMachine(why),
            })
        })
    }

    /// `machine` runs again (resumed, or about to run a command): the replica stops answering and
    /// the journal is applied on its folder. `None` when it was not paused here. Blocking.
    pub fn resumed(&self, machine: &str) -> io::Result<Option<FlushReport>> {
        let mut all = self.guard();
        let Some(m) = all.get_mut(machine) else { return Ok(None) };
        let Some(paused) = m.paused.take() else { return Ok(None) };
        paused.replica.invalidate();
        let report = flush(&mut m.journal, &DirMachineFs::new(&m.canonical))?;
        m.notices.extend(report.conflicts.iter().map(super::flush::Conflict::message));
        if let Some((seq, error)) = &report.stopped {
            m.notices.push(format!(
                "Edits made while the machine was paused, from journal entry {seq} on, were not \
                 applied yet ({error}); they are applied at the next resume."
            ));
        }
        let dir = paused.replica.root().to_path_buf();
        drop(all);
        // The daemon's own copy; nothing answers from it any more.
        let _ = crate::home_fs::remove_dir_all(dir);
        Ok(Some(report))
    }

    /// What the agent's next file call on `machine` must say first; empty when nothing.
    pub fn take_notices(&self, machine: &str) -> Vec<String> {
        self.guard().get_mut(machine).map(|m| std::mem::take(&mut m.notices)).unwrap_or_default()
    }
}

#[cfg(all(test, unix))]
#[path = "paused_tests.rs"]
mod tests;
