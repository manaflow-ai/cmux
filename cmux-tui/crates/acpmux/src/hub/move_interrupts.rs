//! `_acpmux/transfer_interrupts {sessionId}`: what a move of the chat would interrupt, asked of
//! the daemon that holds the chat before the move begins (RFD 0063, "Nothing lives only on the
//! VM", item 6: "Process state is not carried (RFD 0028 owns that); a move says what it will
//! interrupt before it does").
//!
//! The answer is versioned ([`SCHEMA`]) and read-only: nothing is frozen, stopped or copied. It
//! names, each with the words a client shows:
//! - the running turn (a move takes it along between tool calls; `--interrupt` cuts it);
//! - the background processes its harness runs (they end with the harness on this machine);
//! - the background tasks this daemon runs for it (`bg_start`: they stay on this machine);
//! - the TCP ports those processes listen on (Linux reads the trees' sockets; elsewhere only the
//!   ports a process printed, and `portsComplete` is false);
//! - its checkout's unsynced files: uncommitted changes, and commits no remote holds.
//!
//! A daemon older than this method answers method-not-found; the move then goes on as before,
//! saying nothing it could not ask (`cli/run/session_move_interrupts.rs`).

use super::*;
use crate::bg_run::Record;
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// The answer's schema. A field added later keeps v1; a field whose meaning changes is v2.
pub(crate) const SCHEMA: &str = "acpmux.move-interrupts.v1";

/// One listening port and who holds it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Port {
    pub port: u16,
    pub pid: Option<u32>,
}

/// The checkout's unsynced state; `None` fields could not be read.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Files {
    pub checkout: bool,
    pub changed: Option<u64>,
    /// Commits on HEAD that no remote-tracking ref holds; `None` without a remote.
    pub unpushed: Option<u64>,
}

/// What the daemon read, before it is said.
#[derive(Debug, Clone, Default)]
pub(crate) struct Parts {
    pub session_id: String,
    pub turn: Option<(u64, String)>,
    /// `(command, description, cwd, started_at)`.
    pub processes: Vec<(String, Option<String>, String, u64)>,
    pub tasks: Vec<Record>,
    pub ports: Vec<Port>,
    pub ports_complete: bool,
    pub cwd: String,
    pub files: Files,
}

impl Hub {
    /// `_acpmux/transfer_interrupts {sessionId}` → [`render`]'s answer.
    pub(super) async fn transfer_interrupts(&self, params: &Value) -> Result<Value, RpcError> {
        let key = params.get("sessionId").and_then(Value::as_str).unwrap_or_default();
        if key.is_empty() {
            return Err(RpcError::invalid_params("transfer_interrupts: `sessionId` is required"));
        }
        let session = self.resolve(key)?;
        let turn = session.turn().map(|t| (t.started_at, t.masked_preview));
        let running = self.running_for_move(&session);
        let printed: Vec<Port> =
            running.iter().filter_map(|r| r.4).map(|port| Port { port, pid: None }).collect();
        let processes = running.into_iter().map(|(c, d, w, s, _)| (c, d, w, s)).collect();
        let tasks = self.bg_running_records(&session);
        let harness = session.child.try_lock().ok().and_then(|c| c.as_ref().and_then(|c| c.pid));
        let mut roots: Vec<u32> = harness.into_iter().collect();
        roots.extend(tasks.iter().map(|t| t.pid).filter(|p| *p > 0));
        let cwd = session.read_meta(|m| m.cwd.clone());
        let read = tokio::task::spawn_blocking(move || {
            let tree = tree_ports(&roots);
            let files = files_of(&cwd);
            (tree, files, cwd)
        })
        .await
        .map_err(|e| RpcError::internal(format!("transfer_interrupts: {e}")))?;
        let (tree, files, cwd) = read;
        let ports_complete = tree.is_some();
        let ports = merge_ports(tree.unwrap_or_default(), printed);
        Ok(render(&Parts {
            session_id: session.id.clone(),
            turn,
            processes,
            tasks,
            ports,
            ports_complete,
            cwd: cwd.to_string_lossy().into_owned(),
            files,
        }))
    }
}

/// The ports of the trees and the printed ones, each port once (a tree's pid wins).
pub(crate) fn merge_ports(tree: Vec<Port>, printed: Vec<Port>) -> Vec<Port> {
    let mut by: BTreeMap<u16, Option<u32>> = BTreeMap::new();
    for p in tree.into_iter().chain(printed) {
        let at = by.entry(p.port).or_insert(p.pid);
        if at.is_none() {
            *at = p.pid;
        }
    }
    by.into_iter().map(|(port, pid)| Port { port, pid }).collect()
}

/// The answer: the parts, a `lines` list in the words a client shows, and `nothing` when the
/// move interrupts none of them.
pub(crate) fn render(p: &Parts) -> Value {
    let lines = lines(p);
    json!({
        "schema": SCHEMA,
        "sessionId": p.session_id,
        "nothing": lines.is_empty(),
        "turn": p.turn.as_ref().map(|(at, prompt)| json!({"startedAt": at, "prompt": prompt})),
        "processes": p.processes.iter().map(|(command, description, cwd, at)| json!({
            "command": command, "description": description, "cwd": cwd, "startedAt": at,
        })).collect::<Vec<_>>(),
        "backgroundTasks": p.tasks.iter().map(|t| json!({
            "id": t.id, "command": t.command, "description": t.description, "cwd": t.cwd,
            "startedAt": t.started_at,
        })).collect::<Vec<_>>(),
        "ports": p.ports.iter().map(|x| json!({"port": x.port, "pid": x.pid})).collect::<Vec<_>>(),
        "portsComplete": p.ports_complete,
        "files": {
            "cwd": p.cwd,
            "checkout": p.files.checkout,
            "changed": p.files.changed,
            "unpushedCommits": p.files.unpushed,
        },
        "lines": lines,
    })
}

fn plural(n: usize, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

fn cut(text: &str, max: usize) -> String {
    let line = text.lines().next().unwrap_or_default().trim();
    if line.chars().count() <= max {
        return line.to_owned();
    }
    let mut out: String = line.chars().take(max.saturating_sub(1)).collect();
    out.push('…');
    out
}

/// One line per thing the move interrupts, in the order a person weighs them.
pub(crate) fn lines(p: &Parts) -> Vec<String> {
    let mut out = Vec::new();
    if let Some((_, prompt)) = &p.turn {
        let what = if prompt.trim().is_empty() {
            String::new()
        } else {
            format!(" (\"{}\")", cut(prompt, 60))
        };
        out.push(format!(
            "a running turn{what}: it moves at its next tool call, or is cut with --interrupt"
        ));
    }
    if !p.processes.is_empty() {
        let first = &p.processes[0];
        let name = first.1.as_deref().filter(|d| !d.trim().is_empty()).unwrap_or(&first.0);
        let more = if p.processes.len() > 1 {
            format!(" and {} more", p.processes.len() - 1)
        } else {
            String::new()
        };
        out.push(format!(
            "{} the agent started ({}{more}): they end with its harness here",
            plural(p.processes.len(), "background process", "background processes"),
            cut(name, 50)
        ));
    }
    if !p.tasks.is_empty() {
        let first = &p.tasks[0];
        let name = first.description.as_deref().filter(|d| !d.trim().is_empty());
        let more = if p.tasks.len() > 1 {
            format!(" and {} more", p.tasks.len() - 1)
        } else {
            String::new()
        };
        out.push(format!(
            "{} ({}{more}): they keep running here, no longer the chat's",
            plural(p.tasks.len(), "background task", "background tasks"),
            cut(name.unwrap_or(&first.command), 50)
        ));
    }
    if !p.ports.is_empty() {
        let list: Vec<String> = p.ports.iter().take(6).map(|x| x.port.to_string()).collect();
        let more = if p.ports.len() > 6 {
            format!(" and {} more", p.ports.len() - 6)
        } else {
            String::new()
        };
        out.push(format!(
            "{} it serves ({}{more}): not reachable at the new home until started there",
            plural(p.ports.len(), "listening port", "listening ports"),
            list.join(", ")
        ));
    }
    if let Some(n) = p.files.changed.filter(|n| *n > 0) {
        out.push(format!(
            "{} not committed: a move refuses unless --carry-changes or --leave-dirty",
            plural(n as usize, "changed file", "changed files")
        ));
    }
    if let Some(n) = p.files.unpushed.filter(|n| *n > 0) {
        out.push(format!(
            "{} no remote holds: the move pushes the branch first",
            plural(n as usize, "commit", "commits")
        ));
    }
    out
}

/// The TCP ports the processes under `roots` listen on; `None` where this cannot be read
/// (not Linux). A bounded walk from the roots, never a scan of the machine.
fn tree_ports(roots: &[u32]) -> Option<Vec<Port>> {
    #[cfg(target_os = "linux")]
    {
        let mut pids = BTreeSet::new();
        for &root in roots {
            pids.extend(crate::cpu_class::own_tree(root));
        }
        let mut listening: HashMap<u64, u16> = HashMap::new();
        for table in ["/proc/net/tcp", "/proc/net/tcp6"] {
            if let Ok(text) = std::fs::read_to_string(table) {
                crate::placement::command_sampler::parse_listening(&text, &mut listening);
            }
        }
        let mut out = Vec::new();
        if listening.is_empty() {
            return Some(out);
        }
        for pid in pids {
            let Ok(dir) = std::fs::read_dir(format!("/proc/{pid}/fd")) else { continue };
            for link in dir.flatten().filter_map(|e| std::fs::read_link(e.path()).ok()) {
                let inode = link
                    .to_str()
                    .and_then(|l| l.strip_prefix("socket:["))
                    .and_then(|l| l.strip_suffix(']'))
                    .and_then(|l| l.parse::<u64>().ok());
                if let Some(port) = inode.and_then(|i| listening.get(&i)) {
                    out.push(Port { port: *port, pid: Some(pid) });
                }
            }
        }
        Some(out)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (roots, BTreeSet::<u32>::new(), HashMap::<u64, u16>::new());
        None
    }
}

/// The checkout's unsynced state at `cwd`: changed files (`git status --porcelain`) and commits
/// on HEAD that no remote-tracking ref holds (none counted without a remote).
pub(crate) fn files_of(cwd: &std::path::Path) -> Files {
    let git = |args: &[&str]| super::wip_ref::git(cwd, None, args);
    if git(&["rev-parse", "--is-inside-work-tree"]).as_deref() != Some("true") {
        return Files::default();
    }
    let changed = git(&["status", "--porcelain"]).map(|s| s.lines().count() as u64);
    let remotes = git(&["remote"]).is_some_and(|r| !r.trim().is_empty());
    let unpushed = remotes
        .then(|| git(&["rev-list", "--count", "HEAD", "--not", "--remotes"]))
        .flatten()
        .and_then(|n| n.trim().parse().ok());
    Files { checkout: true, changed, unpushed }
}

#[cfg(test)]
#[path = "move_interrupts_tests.rs"]
mod tests;
