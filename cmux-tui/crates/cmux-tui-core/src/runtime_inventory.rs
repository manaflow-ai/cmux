//! Agent runtimes (RFC #20149 phase 1): which coding-agent processes of this
//! user are running, and what cmux can prove about who launched them.
//!
//! A runtime is one OS process, not an agent session: a session can exit
//! while its backend lives on, and one shared backend can serve several
//! sessions. [`classify`] is pure. It takes one process scan and the live
//! cmux terminals, recognizes vendor processes ([`vendor`]), and attributes
//! each one:
//!
//! - **verified**: the process descends from a live cmux terminal's child
//!   through a chain of parents, each started before its child; or the
//!   daemon saw it (or an ancestor) so descend earlier, and its terminal has
//!   since closed or it left the terminal's tree ([`ledger`]). A ledger
//!   attribution never by itself makes a runtime safe to stop.
//! - **probable**: the process was reparented out of that chain but is still
//!   in the session a live cmux terminal's child leads.
//! - **unattributed**: anything else. A shared controlling terminal is never
//!   evidence on its own (#11004).
//!
//! Phase 1 is read-only: [`Runtime::can_stop_safely`] is always false, and a
//! scan that was cut or partly unreadable is reported as incomplete.

pub mod ledger;
mod redact;
mod vendor;

#[cfg(test)]
mod tests;

use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};

use serde::Serialize;

use crate::process_inventory::{InventoryProcess, ProcessInventory};
use crate::process_resources::Sampler;

use ledger::{LedgerView, Observation, ledger_descendants};

pub use crate::process_inventory::{ProcessKey, ProcessLink};
pub use redact::{redact_args, redact_path};
pub use vendor::{Role, Vendor, recognize};

/// Clock granularity allowed between a parent's and a child's start times.
const START_SLACK_MS: u64 = 1_000;

/// A live cmux terminal: the PTY child cmux started for it. The caller
/// passes only a child it has shown is still that process (its parent is
/// the daemon or a terminal host), so a reused pid is never a terminal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CmuxTerminal {
    /// The terminal's public resource id.
    pub terminal_id: String,
    /// The terminal's PTY child (the shell or command), the session leader.
    pub pid: u32,
}

/// How sure cmux is about who launched a runtime.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AttributionStatus {
    Verified,
    Probable,
    Unattributed,
}

/// The evidence behind an attribution.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AttributionSource {
    /// An unbroken parent chain from a live cmux terminal's child.
    TerminalProcessTree,
    /// Seen descending from a cmux terminal earlier, by this daemon: the
    /// terminal closed or the process left its tree.
    LaunchLedger,
    /// Reparented, but still in a live cmux terminal's session.
    TerminalSession,
    /// No evidence.
    None,
}

/// Who launched a runtime, as far as cmux can tell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attribution {
    pub status: AttributionStatus,
    pub source: AttributionSource,
    /// The cmux terminal named by the evidence.
    pub terminal_id: Option<String>,
}

impl Attribution {
    const NONE: Self = Self {
        status: AttributionStatus::Unattributed,
        source: AttributionSource::None,
        terminal_id: None,
    };
}

/// One recognized agent process.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Runtime {
    /// `local:<pid>:<start ms>`: one process generation. A reused pid gets
    /// a different id.
    pub runtime_id: String,
    pub vendor: Vendor,
    pub role: Role,
    pub pid: u32,
    pub ppid: u32,
    pub started_ms: u64,
    /// Executable path with the home directory shown as `~`.
    pub executable_path: Option<String>,
    /// Executable version, when the install layout names it.
    pub executable_version: Option<String>,
    /// Arguments with values redacted ([`redact_args`]).
    pub args: Vec<String>,
    pub cpu_ns: Option<u64>,
    pub memory_bytes: Option<u64>,
    pub attribution: Attribution,
    /// cmux terminals that run a client of the same vendor. Only filled for
    /// servers, as a probable relationship: cmux sees processes, not
    /// connections.
    pub known_cmux_clients: Vec<String>,
    /// Every client of a server, cmux's or not. cmux cannot count them, so
    /// this is `None`: zero known cmux clients never means zero clients.
    pub total_clients: Option<u32>,
    /// Phase 1 never stops anything.
    pub can_stop_safely: bool,
}

/// The runtimes of one scan.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeInventory {
    pub runtimes: Vec<Runtime>,
    /// The scan saw every process of this user. When false, a runtime may be
    /// missing and attributions may be weaker than the truth.
    pub complete: bool,
    pub scanned_processes: usize,
    /// Every process the scan showed descending from a cmux terminal (live,
    /// or through the ledger), agent or not, for the launch ledger.
    pub observations: Vec<Observation>,
}

/// Recognize and attribute the agent processes of one scan. `ledger` is
/// what the daemon saw before; `home` turns the home directory into `~` in
/// paths.
pub fn classify(
    scan: &ProcessInventory,
    terminals: &[CmuxTerminal],
    ledger: &LedgerView,
    home: Option<&str>,
) -> RuntimeInventory {
    let by_pid: HashMap<u32, &InventoryProcess> =
        scan.processes.iter().map(|process| (process.pid, process)).collect();
    let links: Vec<ProcessLink> = scan.processes.iter().map(ProcessLink::of).collect();
    let tree = descendants(
        &links,
        terminals.iter().map(|terminal| (terminal.pid, terminal.terminal_id.as_str())),
    );
    let ledgered = ledger_descendants(&links, ledger);
    let mut observations = Vec::with_capacity(tree.len() + ledgered.len());
    let mut owners: HashMap<u32, (AttributionSource, &str)> = HashMap::new();
    for (source, list) in [
        (AttributionSource::TerminalProcessTree, &tree),
        (AttributionSource::LaunchLedger, &ledgered),
    ] {
        for &(pid, terminal_id) in list {
            let Entry::Vacant(slot) = owners.entry(pid) else {
                continue;
            };
            slot.insert((source, terminal_id));
            if let Some(process) = by_pid.get(&pid) {
                observations.push(Observation {
                    key: ProcessLink::of(process).key(),
                    terminal_id: terminal_id.to_string(),
                });
            }
        }
    }
    let mut runtimes: Vec<Runtime> = scan
        .processes
        .iter()
        .filter_map(|process| {
            let (vendor, role) = recognize(process)?;
            let attribution = owners
                .get(&process.pid)
                .map(|(source, terminal_id)| Attribution {
                    status: AttributionStatus::Verified,
                    source: *source,
                    terminal_id: Some((*terminal_id).to_string()),
                })
                .or_else(|| session_owner(process, terminals, &by_pid))
                .unwrap_or(Attribution::NONE);
            Some(Runtime {
                runtime_id: format!("local:{}:{}", process.pid, process.started_ms),
                vendor,
                role,
                pid: process.pid,
                ppid: process.ppid,
                started_ms: process.started_ms,
                executable_path: process.exe.as_deref().map(|path| redact_path(path, home)),
                executable_version: vendor::version(vendor, process),
                args: redact_args(&process.args),
                cpu_ns: process.cpu_ns,
                memory_bytes: process.memory_bytes,
                attribution,
                known_cmux_clients: Vec::new(),
                total_clients: None,
                can_stop_safely: false,
            })
        })
        .collect();
    link_clients(&mut runtimes);
    RuntimeInventory {
        runtimes,
        complete: !scan.truncated && scan.unreadable == 0,
        scanned_processes: scan.processes.len(),
        observations,
    }
}

/// The processes each root reaches, as `(pid, root's owner)`, roots
/// first: a child counts only when it started no earlier than its parent (a
/// reused parent pid started later and is not the parent). A process belongs
/// to the first root that reaches it; a root missing from the scan reaches
/// nothing.
pub(crate) fn descendants<'t>(
    links: &[ProcessLink],
    roots: impl IntoIterator<Item = (u32, &'t str)>,
) -> Vec<(u32, &'t str)> {
    let by_pid: HashMap<u32, &ProcessLink> = links.iter().map(|link| (link.pid, link)).collect();
    let mut children: HashMap<u32, Vec<&ProcessLink>> = HashMap::new();
    for link in links {
        if link.pid != link.ppid {
            children.entry(link.ppid).or_default().push(link);
        }
    }
    let mut owned = Vec::new();
    let mut seen = HashSet::new();
    for (pid, owner) in roots {
        let Some(root) = by_pid.get(&pid) else {
            continue;
        };
        if !seen.insert(root.pid) {
            continue;
        }
        let mut stack = vec![*root];
        while let Some(parent) = stack.pop() {
            owned.push((parent.pid, owner));
            for child in children.get(&parent.pid).into_iter().flatten() {
                if child.started_ms.saturating_add(START_SLACK_MS) >= parent.started_ms
                    && seen.insert(child.pid)
                {
                    stack.push(child);
                }
            }
        }
    }
    owned
}

/// The terminals whose child is still the process cmux started: its parent
/// is this daemon (an in-daemon PTY) or runs this daemon's executable (a
/// terminal host). A surface's pid outlives its child until the exit is
/// noticed; a reused pid has some other parent, and its tree must not be
/// attributed to the terminal. An adopted child whose parent cannot be
/// shown is left out, so the error is a missing attribution, never a false
/// one.
pub fn cmux_started(links: &[ProcessLink], terminals: Vec<CmuxTerminal>) -> Vec<CmuxTerminal> {
    let sampler = Sampler::new();
    let own = std::process::id();
    terminals
        .into_iter()
        .filter(|terminal| {
            links.iter().find(|link| link.pid == terminal.pid).is_some_and(|child| {
                child.ppid == own || (child.ppid > 1 && sampler.runs_own_executable(child.ppid))
            })
        })
        .collect()
}

/// A reparented process still in the session a live cmux terminal leads.
/// The leader must be the terminal's child itself (see [`CmuxTerminal`]),
/// alive and started before the process.
fn session_owner(
    process: &InventoryProcess,
    terminals: &[CmuxTerminal],
    by_pid: &HashMap<u32, &InventoryProcess>,
) -> Option<Attribution> {
    let terminal = terminals.iter().find(|terminal| {
        process.sid == terminal.pid
            && by_pid.get(&terminal.pid).is_some_and(|leader| {
                leader.sid == leader.pid
                    && process.started_ms.saturating_add(START_SLACK_MS) >= leader.started_ms
            })
    })?;
    Some(Attribution {
        status: AttributionStatus::Probable,
        source: AttributionSource::TerminalSession,
        terminal_id: Some(terminal.terminal_id.clone()),
    })
}

/// For each server, the cmux terminals that run a same-vendor client.
fn link_clients(runtimes: &mut [Runtime]) {
    let mut clients: HashMap<Vendor, Vec<String>> = HashMap::new();
    for runtime in runtimes.iter().filter(|runtime| runtime.role.is_client()) {
        if let Some(terminal) = &runtime.attribution.terminal_id {
            clients.entry(runtime.vendor).or_default().push(terminal.clone());
        }
    }
    for list in clients.values_mut() {
        list.sort_unstable();
        list.dedup();
    }
    for runtime in runtimes.iter_mut().filter(|runtime| runtime.role.is_server()) {
        runtime.known_cmux_clients = clients.get(&runtime.vendor).cloned().unwrap_or_default();
    }
}
