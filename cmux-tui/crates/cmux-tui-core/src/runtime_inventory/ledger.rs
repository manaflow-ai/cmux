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
//! Entries are written after an `agent.runtime.list` scan and by one
//! links-only scan (no arguments) when a terminal closes, before its process
//! is ended. The ledger also keeps when each of its terminals closed: a
//! process that started after its ledger terminal closed gets no ledger
//! attribution, even when it descends from a recorded process, so a
//! long-lived detached agent does not lend its old terminal to everything
//! it starts later.
//!
//! A `launch_ledger` attribution says who launched a process; it must never
//! by itself authorise stopping it (RFC #20149 phase 2).
//!
//! An entry is dropped when a scan proves the process exited: its pid was
//! not listed, or was read with another start time. When the ledger is full
//! ([`MAX_LEDGER_PROCESSES`]), the entries no scan has seen for longest go
//! first. The ledger lives in memory: a daemon restart forgets it
//! (persistence is a follow-up).
//!
//! Follow-up: Linux start times are boot time plus the start in clock ticks,
//! and boot time is derived from the wall clock; a wall-clock step shifts
//! every start time, so no key matches and attributions fall back to the
//! live tree (fails safe). Keying on boot id and ticks would avoid that.
//!
//! Locks: `close_scan` is taken first and held across its scan; `state` is
//! a leaf held only for map updates. Neither is taken under any other daemon
//! lock (the close paths run after the close released the state, registry
//! and creation locks), and no I/O runs under `state`.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use crate::process_inventory::{
    LinkInventory, MAX_INVENTORY_PROCESSES, ProcessKey, ProcessLink, scan_links,
};

use super::{CmuxTerminal, START_SLACK_MS, cmux_started, descendants};

/// Most processes the ledger remembers.
pub const MAX_LEDGER_PROCESSES: usize = 4096;

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
    closed: HashMap<String, u64>,
}

impl LedgerView {
    /// The terminal a process generation was seen under.
    pub fn terminal_of(&self, key: ProcessKey) -> Option<&str> {
        self.entries.get(&key).map(String::as_str)
    }

    /// When a ledger terminal closed, in wall-clock milliseconds.
    pub fn closed_ms(&self, terminal_id: &str) -> Option<u64> {
        self.closed.get(terminal_id).copied()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

/// What one scan proves about which processes exited.
pub struct ScanFacts<'a> {
    /// When the scan started.
    pub scanned: Instant,
    pub links: &'a [ProcessLink],
    /// See [`LinkInventory::listed`].
    pub listed: Option<&'a [u32]>,
}

impl ScanFacts<'_> {
    fn exited(&self, key: ProcessKey, started: &HashMap<u32, u64>) -> bool {
        match started.get(&key.pid) {
            Some(started_ms) => *started_ms != key.started_ms,
            None => self.listed.is_some_and(|listed| listed.binary_search(&key.pid).is_err()),
        }
    }
}

struct Entry {
    terminal_id: String,
    /// When the newest scan that saw it started.
    seen: Instant,
}

#[derive(Default)]
struct LedgerState {
    entries: HashMap<ProcessKey, Entry>,
    /// When each terminal an entry names closed, wall-clock milliseconds.
    closed: HashMap<String, u64>,
}

/// The newest close-time scan; links only.
struct CloseScan {
    started: Instant,
    links: Arc<LinkInventory>,
}

#[derive(Default)]
pub struct LaunchLedger {
    state: Mutex<LedgerState>,
    /// Serializes close-time scans so a batch close shares one scan.
    close_scan: Mutex<Option<CloseScan>>,
}

impl LaunchLedger {
    pub fn view(&self) -> LedgerView {
        let state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        LedgerView {
            entries: state
                .entries
                .iter()
                .map(|(key, entry)| (*key, entry.terminal_id.clone()))
                .collect(),
            closed: state.closed.clone(),
        }
    }

    /// Record what a scan showed. Entries the scan proves exited are
    /// dropped, unless a newer scan saw them.
    pub fn record(&self, facts: &ScanFacts<'_>, observations: &[Observation]) {
        let started: HashMap<u32, u64> =
            facts.links.iter().map(|link| (link.pid, link.started_ms)).collect();
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        state
            .entries
            .retain(|key, entry| entry.seen > facts.scanned || !facts.exited(*key, &started));
        for observation in observations {
            let entry = state.entries.entry(observation.key).or_insert_with(|| Entry {
                terminal_id: observation.terminal_id.clone(),
                seen: facts.scanned,
            });
            // The first terminal stays: a generation never moves.
            entry.seen = entry.seen.max(facts.scanned);
        }
        if state.entries.len() > MAX_LEDGER_PROCESSES {
            let mut by_age: Vec<(Instant, ProcessKey)> =
                state.entries.iter().map(|(key, entry)| (entry.seen, *key)).collect();
            by_age.sort_unstable_by_key(|(seen, _)| *seen);
            let excess = state.entries.len() - MAX_LEDGER_PROCESSES;
            for (_, key) in by_age.into_iter().take(excess) {
                state.entries.remove(&key);
            }
        }
        let LedgerState { entries, closed } = &mut *state;
        let named: HashSet<&str> =
            entries.values().map(|entry| entry.terminal_id.as_str()).collect();
        closed.retain(|terminal_id, _| named.contains(terminal_id.as_str()));
    }

    /// A terminal is about to be ended. When its child still leads it
    /// (`terminal` is `Some`), record its process tree first; then record
    /// when it closed. Closes requested before the newest close scan started
    /// share that scan. Runs I/O: never call it under a daemon lock.
    pub fn observe_closing(
        &self,
        terminal_id: &str,
        terminal: Option<&CmuxTerminal>,
        requested: Instant,
    ) {
        if let Some(terminal) = terminal {
            self.observe_tree(terminal, requested);
        }
        let closed_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |since| u64::try_from(since.as_millis()).unwrap_or(u64::MAX));
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        state.closed.entry(terminal_id.to_string()).or_insert(closed_ms);
    }

    fn observe_tree(&self, terminal: &CmuxTerminal, requested: Instant) {
        let mut close_scan = self.close_scan.lock().unwrap_or_else(|error| error.into_inner());
        if close_scan.as_ref().is_none_or(|last| last.started < requested) {
            let started = Instant::now();
            let links = Arc::new(scan_links(MAX_INVENTORY_PROCESSES));
            *close_scan = Some(CloseScan { started, links });
        }
        let Some((started, scan)) =
            close_scan.as_ref().map(|last| (last.started, last.links.clone()))
        else {
            return;
        };
        drop(close_scan);
        let terminals = cmux_started(&scan.links, vec![terminal.clone()]);
        let view = self.view();
        let mut owned = descendants(
            &scan.links,
            terminals.iter().map(|terminal| (terminal.pid, terminal.terminal_id.as_str())),
        );
        owned.extend(ledger_descendants(&scan.links, &view));
        // A process the tree reaches keeps that terminal over a ledger one.
        let mut seen = HashSet::new();
        owned.retain(|(pid, _)| seen.insert(*pid));
        let by_pid: HashMap<u32, &ProcessLink> =
            scan.links.iter().map(|link| (link.pid, link)).collect();
        let observations: Vec<Observation> = owned
            .into_iter()
            .filter_map(|(pid, terminal_id)| {
                Some(Observation {
                    key: by_pid.get(&pid)?.key(),
                    terminal_id: terminal_id.to_string(),
                })
            })
            .collect();
        let facts =
            ScanFacts { scanned: started, links: &scan.links, listed: scan.listed.as_deref() };
        self.record(&facts, &observations);
    }
}

/// The processes a ledger entry or its descendants cover, as `(pid,
/// terminal)`. The youngest recorded ancestor wins. A process that started
/// after its terminal closed is left out.
pub(super) fn ledger_descendants<'v>(
    links: &[ProcessLink],
    view: &'v LedgerView,
) -> Vec<(u32, &'v str)> {
    if view.is_empty() {
        return Vec::new();
    }
    let mut roots: Vec<(&ProcessLink, &'v str)> =
        links.iter().filter_map(|link| Some((link, view.terminal_of(link.key())?))).collect();
    roots.sort_unstable_by(|a, b| {
        b.0.started_ms.cmp(&a.0.started_ms).then_with(|| a.0.pid.cmp(&b.0.pid))
    });
    let started: HashMap<u32, u64> = links.iter().map(|link| (link.pid, link.started_ms)).collect();
    let mut owned =
        descendants(links, roots.into_iter().map(|(link, terminal)| (link.pid, terminal)));
    owned.retain(|(pid, terminal)| {
        view.closed_ms(terminal).is_none_or(|closed| {
            started.get(pid).is_some_and(|start| *start <= closed.saturating_add(START_SLACK_MS))
        })
    });
    owned
}
