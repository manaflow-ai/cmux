//! The launch ledger: the processes the daemon has seen descend from one of
//! its terminals, so an agent stays attributed after its terminal closes and
//! it is reparented or detached (`setsid`, `nohup`, an agent daemon).
//!
//! An entry is one process generation, `(pid, start time)`, never a pid
//! alone: a reused pid starts later and matches nothing. An entry holds the
//! terminal id and when a scan last saw it; never arguments, executable,
//! working directory or environment. Evidence comes only from the process
//! tree: an environment variable can be forged and a terminal device can be
//! shared, so neither is ever read.
//!
//! Entries are written after an `agent.runtime.list` scan and by one scan
//! when a terminal closes, before its process is ended. They are pruned only
//! after a complete scan, and the ledger keeps at most
//! [`MAX_LEDGER_PROCESSES`] entries. The ledger lives in memory: a daemon
//! restart forgets it.
//!
//! Locks: `close_scan` is taken first and held across its scan; `entries`
//! is a leaf held only for map updates. Neither is taken under any other
//! daemon lock, and no I/O runs under `entries`.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use crate::process_inventory::{MAX_INVENTORY_PROCESSES, scan};

use super::{CmuxTerminal, ProcessLink, cmux_started, descendants};

/// Most processes the ledger remembers. New processes are dropped while it
/// is full, until a complete scan prunes the ones that ended.
pub const MAX_LEDGER_PROCESSES: usize = 4096;

/// One process generation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ProcessKey {
    pub pid: u32,
    pub started_ms: u64,
}

/// A scan showed this process descending from this terminal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Observation {
    pub key: ProcessKey,
    pub terminal_id: String,
}

/// A copy of the ledger for one classification.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LedgerView {
    entries: HashMap<ProcessKey, String>,
}

impl LedgerView {
    /// The terminal a process generation was seen under.
    pub fn terminal_of(&self, key: ProcessKey) -> Option<&str> {
        self.entries.get(&key).map(String::as_str)
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

struct Entry {
    terminal_id: String,
    /// When the newest scan that saw it started.
    seen: Instant,
}

/// The parent links of the newest close-time scan; no arguments.
struct CloseScan {
    started: Instant,
    links: Arc<Vec<ProcessLink>>,
    complete: bool,
}

#[derive(Default)]
pub struct LaunchLedger {
    entries: Mutex<HashMap<ProcessKey, Entry>>,
    /// Serializes close-time scans so a batch close shares one scan.
    close_scan: Mutex<Option<CloseScan>>,
}

impl LaunchLedger {
    pub fn view(&self) -> LedgerView {
        let entries = self.entries.lock().unwrap_or_else(|error| error.into_inner());
        LedgerView {
            entries: entries
                .iter()
                .map(|(key, entry)| (*key, entry.terminal_id.clone()))
                .collect(),
        }
    }

    /// Record what a scan started at `scanned` showed. `present` is every
    /// process of that scan when it was complete; then entries it did not
    /// see, and no newer scan saw, are dropped.
    pub fn record(
        &self,
        scanned: Instant,
        observations: &[Observation],
        present: Option<&HashSet<ProcessKey>>,
    ) {
        let mut entries = self.entries.lock().unwrap_or_else(|error| error.into_inner());
        if let Some(present) = present {
            entries.retain(|key, entry| entry.seen > scanned || present.contains(key));
        }
        for observation in observations {
            if let Some(entry) = entries.get_mut(&observation.key) {
                // The first terminal stays: a generation never moves.
                entry.seen = entry.seen.max(scanned);
            } else if entries.len() < MAX_LEDGER_PROCESSES {
                entries.insert(
                    observation.key,
                    Entry { terminal_id: observation.terminal_id.clone(), seen: scanned },
                );
            }
        }
    }

    /// Record the process tree of a terminal about to be ended, while its
    /// child still leads it. Closes requested before the newest scan
    /// started share that scan. Runs I/O: never call it under a daemon lock.
    pub fn observe_closing(&self, terminal: &CmuxTerminal, requested: Instant) {
        let mut close_scan = self.close_scan.lock().unwrap_or_else(|error| error.into_inner());
        let fresh = close_scan.as_ref().is_some_and(|last| last.started >= requested);
        if !fresh {
            let started = Instant::now();
            let processes = scan(MAX_INVENTORY_PROCESSES);
            *close_scan = Some(CloseScan {
                started,
                links: Arc::new(processes.processes.iter().map(ProcessLink::of).collect()),
                complete: !processes.truncated && processes.unreadable == 0,
            });
        }
        let Some(last) = close_scan.as_ref() else {
            return;
        };
        let (started, links, complete) = (last.started, last.links.clone(), last.complete);
        drop(close_scan);
        let terminals = cmux_started(&links, vec![terminal.clone()]);
        let view = self.view();
        let mut observations = descendants(
            &links,
            terminals.iter().map(|terminal| (terminal.pid, terminal.terminal_id.as_str())),
        )
        .into_iter()
        .chain(ledger_descendants(&links, &view))
        .collect::<Vec<_>>();
        // A process the tree reaches keeps that terminal over a ledger one.
        let mut seen = HashSet::new();
        observations.retain(|(pid, _)| seen.insert(*pid));
        let by_pid: HashMap<u32, &ProcessLink> = links.iter().map(|link| (link.pid, link)).collect();
        let observations: Vec<Observation> = observations
            .into_iter()
            .filter_map(|(pid, terminal_id)| {
                Some(Observation {
                    key: by_pid.get(&pid)?.key(),
                    terminal_id: terminal_id.to_string(),
                })
            })
            .collect();
        let present = complete.then(|| links.iter().map(ProcessLink::key).collect::<HashSet<_>>());
        self.record(started, &observations, present.as_ref());
    }
}

/// The processes a ledger entry or its descendants cover, as `(pid,
/// terminal)`. The youngest recorded ancestor wins.
pub(super) fn ledger_descendants<'v>(
    links: &[ProcessLink],
    view: &'v LedgerView,
) -> Vec<(u32, &'v str)> {
    if view.is_empty() {
        return Vec::new();
    }
    let mut roots: Vec<(&ProcessLink, &'v str)> = links
        .iter()
        .filter_map(|link| Some((link, view.terminal_of(link.key())?)))
        .collect();
    roots.sort_unstable_by(|a, b| {
        b.0.started_ms.cmp(&a.0.started_ms).then_with(|| a.0.pid.cmp(&b.0.pid))
    });
    descendants(links, roots.into_iter().map(|(link, terminal)| (link.pid, terminal)))
}
