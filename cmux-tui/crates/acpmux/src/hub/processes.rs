//! Part of `Hub`; see `hub/mod.rs`. The background-process registry
//! (`docs/background-processes.md`): one record per command a harness runs
//! in the background (a dev server, a watcher), which clients list and stop
//! (`server/processes.rs`).
//!
//! Claude Code's shells come from the translator's `background_task_update`
//! (`claude_stdio/inbound.rs`): `running` when one goes to the background,
//! then how it ended. Each change is logged as a mux `process_update`. A
//! session's table is read back from its log the first time it is needed,
//! and again when a daemon adopts a running host (`hosts.rs`); a harness that
//! exited or was replaced took its processes with it, so those still running
//! then are `lost`.

use super::*;
use serde::{Deserialize, Serialize};

/// The reason of a process that ended with its harness.
pub(super) const HARNESS_EXIT: &str = "harness_exit";

/// How long a kill waits for Claude Code to take its `stop_task`.
const STOP_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// Where a process is in its life.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum ProcessState {
    Running,
    Exited,
    Failed,
    Killed,
    /// It ended without anyone seeing how (its harness exited).
    Lost,
}

/// One background process, as `_acpmux/process/list` and
/// `_acpmux/process_update` carry it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Process {
    /// `<sessionId>/<harness task id>` (the tool call's id when the harness
    /// never named a task).
    id: String,
    session_id: String,
    /// The subagent whose tool call started it, if one did.
    subagent_session_id: Option<String>,
    tool_call_id: String,
    task_id: String,
    harness: String,
    command: String,
    cwd: String,
    /// Unix ms.
    started_at: u64,
    ended_at: Option<u64>,
    state: ProcessState,
    /// Not reported by Claude Code.
    exit_code: Option<i64>,
    signal: Option<String>,
    /// Why it stopped: `person` (`_acpmux/process/kill`), `agent`, or
    /// `harness_exit`.
    reason: Option<String>,
    /// The harness's own words on its end (Claude's reason or summary).
    detail: Option<String>,
    /// `background` (started there) or `auto_backgrounded` (moved there).
    origin: String,
    /// Not tracked yet (tail is a follow-up).
    output_bytes: Option<u64>,
    /// Its latest state is in a logged `process_update`.
    #[serde(skip)]
    logged: bool,
}

/// A session's processes, in the order they started.
#[derive(Debug, Default)]
pub(super) struct ProcessTable {
    /// Read from the session's log (`Hub::process_table`).
    loaded: bool,
    /// The last log record the table holds.
    through: u64,
    processes: Vec<Process>,
    /// Processes a person asked to stop: their end is the person's.
    stopping: std::collections::HashSet<String>,
}

impl ProcessTable {
    /// Folds in the params of one `background_task_update` record; returns
    /// the process when it changed. A process ends once: a later end or
    /// `running` is ignored.
    fn fold(&mut self, session: &Session, params: &Value, at: u64) -> Option<usize> {
        let update = params.get("update")?;
        let text = |k: &str| update.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
        let tool = text("toolCallId")?;
        // The translator's mark for a shell that ended with Claude Code.
        let with_harness =
            params.pointer("/_meta/acpmux/endedBy").and_then(Value::as_str) == Some(HARNESS_EXIT);
        let state = match text("state")? {
            "running" => ProcessState::Running,
            "completed" => ProcessState::Exited,
            "failed" => ProcessState::Failed,
            _ if with_harness => ProcessState::Lost,
            _ => ProcessState::Killed,
        };
        let found = self.processes.iter().position(|p| p.tool_call_id == tool);
        let i = match found {
            Some(i) => i,
            None => {
                let id =
                    self.unused_id(format!("{}/{}", session.id, text("taskId").unwrap_or(tool)));
                let meta = session.meta();
                let subagent = params.pointer("/_meta/acpmux/subagent").and_then(Value::as_str);
                self.processes.push(Process {
                    id,
                    session_id: session.id.clone(),
                    subagent_session_id: subagent.map(str::to_owned),
                    tool_call_id: tool.to_owned(),
                    task_id: text("taskId").unwrap_or("").to_owned(),
                    harness: crate::web_modes::family_of(&meta),
                    command: text("command").unwrap_or("").to_owned(),
                    cwd: meta.cwd.to_string_lossy().into_owned(),
                    started_at: at,
                    ended_at: None,
                    state: ProcessState::Running,
                    exit_code: None,
                    signal: None,
                    reason: None,
                    detail: None,
                    origin: text("origin").unwrap_or("background").to_owned(),
                    output_bytes: None,
                    logged: false,
                });
                self.processes.len() - 1
            }
        };
        if state == ProcessState::Running {
            return found.is_none().then_some(i);
        }
        let p = &mut self.processes[i];
        if p.state != ProcessState::Running {
            return None;
        }
        let asked = self.stopping.remove(&p.id);
        p.state = state;
        p.ended_at = Some(at);
        p.reason = match state {
            ProcessState::Lost => Some(HARNESS_EXIT.into()),
            ProcessState::Killed if asked => Some("person".into()),
            ProcessState::Killed => Some("agent".into()),
            _ => None,
        };
        if state != ProcessState::Lost {
            p.detail = text("reason").or_else(|| text("summary")).map(str::to_owned);
        }
        p.logged = false;
        Some(i)
    }

    /// `id`, or `id-2`, `id-3`, ... when a process already has it (a task id
    /// a later harness used again).
    fn unused_id(&self, id: String) -> String {
        let taken = |id: &str| self.processes.iter().any(|p| p.id == id);
        if !taken(&id) {
            return id;
        }
        let mut n = 2;
        loop {
            let next = format!("{id}-{n}");
            if !taken(&next) {
                return next;
            }
            n += 1;
        }
    }

    /// A logged `process_update`: the record as it was decided wins.
    fn upsert(&mut self, mut process: Process) {
        process.logged = true;
        match self.processes.iter_mut().find(|p| p.id == process.id) {
            Some(p) => *p = process,
            None => self.processes.push(process),
        }
    }

    /// The process `i`, marked as logged: its `process_update` is written.
    fn log(&mut self, i: usize) -> Process {
        let p = &mut self.processes[i];
        p.logged = true;
        p.clone()
    }

    /// The processes as the wire carries them.
    fn values(&self) -> Vec<Value> {
        self.processes.iter().filter_map(|p| serde_json::to_value(p).ok()).collect()
    }

    /// Every running process ends `lost` for `reason`; returns them.
    /// `logged`: their `process_update` is written now.
    fn lose_running(&mut self, at: u64, reason: &str, logged: bool) -> Vec<Process> {
        let mut lost = Vec::new();
        for p in self.processes.iter_mut().filter(|p| p.state == ProcessState::Running) {
            self.stopping.remove(&p.id);
            p.state = ProcessState::Lost;
            p.ended_at = Some(at);
            p.reason = Some(reason.to_owned());
            p.logged = logged;
            lost.push(p.clone());
        }
        lost
    }
}

impl Hub {
    /// The session's table, read from its whole log the first time.
    fn process_table<'a>(&self, session: &'a Session) -> std::sync::MutexGuard<'a, ProcessTable> {
        let mut table = session.processes.lock().unwrap_or_else(|e| e.into_inner());
        if !table.loaded {
            *table = self.read_processes(session);
        }
        table
    }

    /// The session's processes as its log says: each shell's updates, then
    /// the `process_update` records, which win. A harness that stopped or
    /// exited, or a new one, outlived none of the processes before it (a
    /// power loss logs no end).
    fn read_processes(&self, session: &Session) -> ProcessTable {
        let mut table = ProcessTable { loaded: true, ..ProcessTable::default() };
        let _ = self.store.scan(&session.id, 0, &mut |e: EventRecord| {
            table.through = table.through.max(e.seq);
            match (e.dir.as_str(), e.kind.as_str()) {
                ("in", "background_task_update") => {
                    let params = e.msg.get("params").unwrap_or(&Value::Null);
                    table.fold(session, params, e.at);
                }
                ("mux", "process_update") => {
                    let process = e.msg.get("process").cloned().unwrap_or(Value::Null);
                    if let Ok(process) = serde_json::from_value(process) {
                        table.upsert(process);
                    }
                }
                ("mux", "stopped" | "exited" | "host_started") => {
                    table.lose_running(e.at, HARNESS_EXIT, false);
                }
                _ => {}
            }
            true
        });
        table
    }

    /// Reads the session's processes from its log again: a daemon that
    /// adopted a running host lists them again (`hosts.rs`).
    pub(super) fn rebuild_processes(&self, session: &Session) {
        let table = self.read_processes(session);
        *session.processes.lock().unwrap_or_else(|e| e.into_inner()) = table;
    }

    /// A logged `background_task_update` (`tap.rs`), the session's own or a
    /// subagent's: a change is logged as `process_update`.
    pub(super) fn note_process(&self, session: &Session, rec: &EventRecord) {
        let params = rec.msg.get("params").unwrap_or(&Value::Null);
        let changed = {
            let mut table = self.process_table(session);
            let i = if rec.seq > table.through {
                table.through = rec.seq;
                table.fold(session, params, rec.at)
            } else {
                // The first read of the log folded this record already: its
                // change is logged here, once.
                let tool = params.pointer("/update/toolCallId").and_then(Value::as_str);
                table
                    .processes
                    .iter()
                    .position(|p| Some(p.tool_call_id.as_str()) == tool && !p.logged)
            };
            i.map(|i| table.log(i))
        };
        if let Some(process) = changed {
            self.append(session, "mux", "process_update", json!({"process": process}));
        }
    }

    /// The harness is gone: every process still running is `lost`.
    pub(super) fn processes_lost(&self, session: &Session, reason: &str) {
        let lost = self.process_table(session).lose_running(now_ms(), reason, true);
        for process in lost {
            self.append(session, "mux", "process_update", json!({"process": process}));
        }
    }

    /// A process still runs in the background: the chat is not idle
    /// (`idle.rs`).
    pub(super) fn any_process_running(&self, session: &Session) -> bool {
        let table = self.process_table(session);
        table.processes.iter().any(|p| p.state == ProcessState::Running)
    }

    /// `_acpmux/process/list`: the session's processes; without one, those of
    /// every chat whose processes this daemon has read (any chat that ran one
    /// since it started, or that it adopted).
    pub fn list_processes(&self, session: Option<&Session>) -> Value {
        let processes = match session {
            Some(session) => self.process_table(session).values(),
            None => self
                .sessions()
                .iter()
                .flat_map(|s| {
                    let table = s.processes.lock().unwrap_or_else(|e| e.into_inner());
                    if table.loaded { table.values() } else { Vec::new() }
                })
                .collect(),
        };
        json!({"processes": processes})
    }

    /// `_acpmux/process/kill`: asks Claude Code to stop the process
    /// (`stop_task`); its end arrives as a `process_update`. One that already
    /// ended is left alone. Never starts a harness: with none running, the
    /// process ended with it and is `lost`.
    pub async fn kill_process(&self, id: &str) -> Result<Value, RpcError> {
        let (sid, _) = id
            .split_once('/')
            .filter(|(sid, task)| !sid.is_empty() && !task.is_empty())
            .ok_or_else(|| RpcError::invalid_params("processId must be <sessionId>/<taskId>"))?;
        let unknown = || RpcError::not_found(format!("no background process {id:?}"));
        let session = self.resolve(sid).ok().filter(|s| s.id == sid).ok_or_else(unknown)?;
        let harness = session.meta().harness;
        let claude = self
            .config
            .read()
            .await
            .profile(&harness)
            .is_some_and(|p| p.kind == crate::config::HarnessKind::ClaudeStdio);
        if !claude {
            return Err(RpcError::invalid_params(
                "only Claude Code's background processes can be stopped",
            ));
        }
        let (task, running) = {
            let table = self.process_table(&session);
            let p = table.processes.iter().find(|p| p.id == id).ok_or_else(unknown)?;
            (p.task_id.clone(), p.state == ProcessState::Running)
        };
        if !running {
            return Ok(json!({}));
        }
        let child = session.child.lock().await.clone();
        let alive = match &child {
            Some(child) => child.is_alive().await,
            None => false,
        };
        let Some(child) = child.filter(|_| alive) else {
            self.processes_lost(&session, HARNESS_EXIT);
            return Ok(json!({}));
        };
        if task.is_empty() {
            return Err(RpcError::invalid_params("Claude Code has not named this process's task"));
        }
        let inserted = self.process_table(&session).stopping.insert(id.to_owned());
        let params = json!({"sessionId": session.meta().agent_session_id, "taskId": task});
        let asked = tokio::time::timeout(
            STOP_TIMEOUT,
            child.request(crate::claude_stdio::STOP_TASK, params),
        )
        .await;
        let refused = match asked {
            Ok(Ok(_)) => return Ok(json!({})),
            Ok(Err(e)) => e,
            Err(_) => RpcError::internal("Claude Code did not answer stop_task in time"),
        };
        // Another kill of this process may still wait on its own stop_task.
        if inserted {
            self.process_table(&session).stopping.remove(id);
        }
        Err(refused)
    }
}
