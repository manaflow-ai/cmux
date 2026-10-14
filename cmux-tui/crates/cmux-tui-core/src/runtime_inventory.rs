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
//!   through a chain of parents, each started before its child.
//! - **probable**: the process was reparented out of that chain but is still
//!   in the session a live cmux terminal's child leads.
//! - **unattributed**: anything else. A shared controlling terminal is never
//!   evidence on its own (#11004).
//!
//! Phase 1 is read-only: [`Runtime::can_stop_safely`] is always false, and a
//! scan that was cut or partly unreadable is reported as incomplete.

mod redact;
mod vendor;

#[cfg(test)]
mod tests;

use std::collections::{HashMap, HashSet};

use serde::Serialize;

use crate::process_inventory::{InventoryProcess, ProcessInventory};

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
}

/// Recognize and attribute the agent processes of one scan. `home` turns
/// the home directory into `~` in paths.
pub fn classify(
    scan: &ProcessInventory,
    terminals: &[CmuxTerminal],
    home: Option<&str>,
) -> RuntimeInventory {
    let by_pid: HashMap<u32, &InventoryProcess> =
        scan.processes.iter().map(|process| (process.pid, process)).collect();
    let owners = tree_owners(scan, terminals, &by_pid);
    let mut runtimes: Vec<Runtime> = scan
        .processes
        .iter()
        .filter_map(|process| {
            let (vendor, role) = recognize(process)?;
            let attribution = owners
                .get(&process.pid)
                .map(|terminal| Attribution {
                    status: AttributionStatus::Verified,
                    source: AttributionSource::TerminalProcessTree,
                    terminal_id: Some(terminal.terminal_id.clone()),
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
    }
}

/// The terminal each process descends from. A child counts only when it
/// started no earlier than its parent: a reused parent pid started later
/// and is not the parent.
fn tree_owners<'t>(
    scan: &ProcessInventory,
    terminals: &'t [CmuxTerminal],
    by_pid: &HashMap<u32, &InventoryProcess>,
) -> HashMap<u32, &'t CmuxTerminal> {
    let mut children: HashMap<u32, Vec<&InventoryProcess>> = HashMap::new();
    for process in &scan.processes {
        if process.pid != process.ppid {
            children.entry(process.ppid).or_default().push(process);
        }
    }
    let mut owners = HashMap::new();
    for terminal in terminals {
        let Some(root) = by_pid.get(&terminal.pid) else {
            continue;
        };
        let mut seen = HashSet::from([root.pid]);
        let mut stack = vec![*root];
        while let Some(parent) = stack.pop() {
            owners.entry(parent.pid).or_insert(terminal);
            for child in children.get(&parent.pid).into_iter().flatten() {
                if child.started_ms.saturating_add(START_SLACK_MS) >= parent.started_ms
                    && seen.insert(child.pid)
                {
                    stack.push(child);
                }
            }
        }
    }
    owners
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
