//! Part of `Hub`; see `hub/mod.rs`. The background-process registry
//! (`docs/background-processes.md`): one record per command a harness runs
//! in the background (a dev server, a watcher), which clients list and stop
//! (`server/processes.rs`).
//!
//! Claude Code's shells come from the translator's `background_task_update`
//! (`claude_stdio/inbound.rs`): `running` when one goes to the background,
//! then how it ended. Codex's background terminals come the same way from
//! the bridge (`codex_app_server/background.rs`). Each change is logged as
//! a mux `process_update`. A session's table is read back from its log the
//! first time it is needed, and again when a daemon adopts a running host
//! (`hosts.rs`); a harness that exited or was replaced took its processes
//! with it, so those still running then are `lost`.
//!
//! `_acpmux/process/background` is Ctrl-B: Claude Code moves the chat's
//! foreground work to the background, which then arrives here as above.
//!
//! Claude Code writes each shell's output to a file it names
//! (`output_file`), which `_acpmux/process/tail` reads. The agent host runs
//! on this machine, so the daemon reads the file itself.

use super::*;
use serde::{Deserialize, Serialize};

/// The reason of a process that ended with its harness.
pub(super) const HARNESS_EXIT: &str = "harness_exit";

/// How long a kill waits for Claude Code's `stop_task` or Codex's terminate,
/// and Ctrl-B for Claude Code's `background_tasks` (`Hub::set_background_timeout`).
pub(super) const STOP_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// What a tail without `maxBytes` reads: the last 64 KiB.
const TAIL_DEFAULT: u64 = 64 << 10;

/// The most one tail reads, whatever `maxBytes` asks.
const TAIL_MAX: u64 = 1 << 20;

/// Leave ample room for JSON-RPC framing and a potentially long cursor. A page never
/// constructs or sends the full completed-process history.
const PROCESS_PAGE_BUDGET: usize = crate::rpc::MAX_MESSAGE_BYTES - (64 << 10);

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
    /// Reported by Codex, not by Claude Code.
    exit_code: Option<i64>,
    signal: Option<String>,
    /// Why it stopped: `person` (`_acpmux/process/kill`), `agent`, or
    /// `harness_exit`.
    reason: Option<String>,
    /// The harness's own words on its end (Claude's reason or summary).
    detail: Option<String>,
    /// `background` (started there), `auto_backgrounded` (Claude Code moved
    /// it there) or `user_backgrounded` (the person did, Ctrl-B).
    origin: String,
    /// The length of its output file when it was listed; null while
    /// Claude Code has named no file.
    output_bytes: Option<u64>,
    /// The file Claude Code writes its output to (`output_file`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    output_file: Option<String>,
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
    /// Stable slots in `processes`: entries never move, even when an update replaces one.
    by_id: std::collections::HashMap<String, usize>,
    /// First process with a tool-call ID (the historical Vec::position behavior).
    by_tool: std::collections::HashMap<String, usize>,
    /// Only live process slots, ascending by append order. Completed history can grow
    /// without making idle checks or lost-process propagation scan every old task.
    running: std::collections::BTreeSet<usize>,
    /// Processes a person asked to stop: their end is the person's.
    stopping: std::collections::HashSet<String>,
}

#[cfg(test)]
#[path = "processes_index_tests.rs"]
mod process_index_tests;

#[cfg(test)]
#[path = "processes_active_tests.rs"]
mod process_active_tests;

impl ProcessTable {
    /// All appends go here, including records replayed from a logged process update.
    fn insert(&mut self, process: Process) -> usize {
        let at = self.processes.len();
        self.by_id.insert(process.id.clone(), at);
        self.by_tool.entry(process.tool_call_id.clone()).or_insert(at);
        if process.state == ProcessState::Running {
            self.running.insert(at);
        }
        self.processes.push(process);
        at
    }

    fn find_tool(&self, tool: &str) -> Option<usize> {
        self.by_tool.get(tool).copied()
    }

    fn find_id(&self, id: &str) -> Option<&Process> {
        self.by_id.get(id).and_then(|&at| self.processes.get(at))
    }

    /// Folds in the params of one `background_task_update` record, and the
    /// output file the update named (`take_output_file`); returns the
    /// process when it changed. A process ends once: a later end or
    /// `running` is ignored.
    fn fold(
        &mut self,
        session: &Session,
        params: &Value,
        at: u64,
        output: Option<&str>,
    ) -> Option<usize> {
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
        let found = self.find_tool(tool);
        let i = match found {
            Some(i) => i,
            None => {
                let id =
                    self.unused_id(format!("{}/{}", session.id, text("taskId").unwrap_or(tool)));
                let meta = session.meta();
                let subagent = params.pointer("/_meta/acpmux/subagent").and_then(Value::as_str);
                let process = Process {
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
                    output_file: None,
                    logged: false,
                };
                self.insert(process)
            }
        };
        // The output file may be named late (Claude's notification): it is
        // kept once, and logged with the record.
        let p = &mut self.processes[i];
        let named = match output.filter(|f| !f.is_empty()) {
            Some(file) if p.output_file.is_none() => {
                p.output_file = Some(file.to_owned());
                p.logged = false;
                true
            }
            _ => false,
        };
        if state == ProcessState::Running {
            return (found.is_none() || named).then_some(i);
        }
        if p.state != ProcessState::Running {
            return named.then_some(i);
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
            p.exit_code = update.get("exitCode").and_then(Value::as_i64);
        }
        p.logged = false;
        self.running.remove(&i);
        Some(i)
    }

    /// `id`, or `id-2`, `id-3`, ... when a process already has it (a task id
    /// a later harness used again).
    fn unused_id(&self, id: String) -> String {
        let taken = |id: &str| self.by_id.contains_key(id);
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

    /// A logged `process_update`: the record as it was decided wins. A rare
    /// replacement with a changed tool ID keeps the *first* matching row in the index.
    fn upsert(&mut self, mut process: Process) {
        process.logged = true;
        if let Some(at) = self.by_id.get(&process.id).copied()
            && let Some(slot) = self.processes.get_mut(at)
        {
            let new_tool = process.tool_call_id.clone();
            let live = process.state == ProcessState::Running;
            let old_tool = std::mem::replace(slot, process).tool_call_id;
            if live {
                self.running.insert(at);
            } else {
                self.running.remove(&at);
            }
            if old_tool == new_tool {
                return;
            }
            if self.by_tool.get(&old_tool) == Some(&at) {
                // A logged row can correct its tool-call ID. Repoint the old key to
                // its next occurrence, if any; this exceptional correction may scan.
                match self.processes.iter().position(|p| p.tool_call_id == old_tool) {
                    Some(next) => {
                        self.by_tool.insert(old_tool, next);
                    }
                    None => {
                        self.by_tool.remove(&old_tool);
                    }
                }
            }
            self.by_tool
                .entry(new_tool)
                .and_modify(|first| *first = (*first).min(at))
                .or_insert(at);
        } else {
            self.insert(process);
        }
    }

    /// The process `i`, marked as logged: its `process_update` is written.
    fn log(&mut self, i: usize) -> Process {
        let p = &mut self.processes[i];
        p.logged = true;
        p.clone()
    }

    /// Snapshot the rows while the process table is locked. Output-file metadata may hit
    /// a slow filesystem, so it is read only after the caller releases that lock.
    fn snapshot(&self) -> Vec<Process> {
        self.processes.clone()
    }

    /// A narrow append-order window from the same table the full list reads.
    /// The id cursor survives status updates, because process slots never move.
    fn page_snapshot(
        &self,
        limit: usize,
        after: Option<&str>,
    ) -> Result<(Vec<Process>, bool), RpcError> {
        let start = match after {
            Some(id) => self.by_id.get(id).copied().ok_or_else(|| {
                RpcError::invalid_params("cursor is not a process ID in this session")
            })?.saturating_add(1),
            None => 0,
        };
        let end = start.saturating_add(limit).min(self.processes.len());
        Ok((self.processes[start..end].to_vec(), end < self.processes.len()))
    }

    /// Every running process ends `lost` for `reason`; returns them.
    /// `logged`: their `process_update` is written now.
    fn lose_running(&mut self, at: u64, reason: &str, logged: bool) -> Vec<Process> {
        let mut lost = Vec::new();
        // The ordered slots retain the original oldest-first notification order.
        for index in std::mem::take(&mut self.running) {
            let p = &mut self.processes[index];
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

/// Serialize a process-list snapshot after releasing the session's process-table mutex.
/// Keep outputBytes live, even for completed tasks whose output file changes after exit.
fn process_values(processes: Vec<Process>, length: impl Fn(&str) -> u64) -> Vec<Value> {
    processes
        .into_iter()
        .filter_map(|mut process| {
            process.output_bytes = process.output_file.as_deref().map(&length);
            serde_json::to_value(process).ok()
        })
        .collect()
}

/// A byte-bounded process page. Resolve file sizes and serialize after releasing the
/// table mutex, stopping as soon as the page fills. An oversized command/detail becomes
/// an explicit identity-preserving stub; a cursor/identity too large even for a stub is
/// reported as an ordinary RPC error.
fn process_page_values(
    processes: Vec<Process>,
    has_more: bool,
    budget: usize,
) -> Result<Value, RpcError> {
    let mut rows = Vec::new();
    let (mut used, mut last_id, mut next) = (64_usize, None::<String>, has_more);
    for mut process in processes {
        let id = process.id.clone();
        let cursor_bytes = serde_json::to_string(&id)
            .map_err(|e| RpcError::internal(format!("cannot encode process cursor: {e}")))?
            .len();
        process.output_bytes = process.output_file.as_deref().map(output_len);
        let mut row = serde_json::to_value(process)
            .map_err(|e| RpcError::internal(format!("cannot encode process row: {e}")))?;
        let mut bytes = row.to_string().len();
        if bytes.saturating_add(cursor_bytes).saturating_add(64) > budget {
            let full_bytes = bytes;
            row = json!({
                "id": row["id"], "sessionId": row["sessionId"],
                "toolCallId": row["toolCallId"], "taskId": row["taskId"],
                "harness": row["harness"], "command": "",
                "startedAt": row["startedAt"], "endedAt": row["endedAt"],
                "state": row["state"], "origin": row["origin"],
                "omitted": {"reason": "too_large", "bytes": full_bytes}
            });
            bytes = row.to_string().len();
            if bytes.saturating_add(cursor_bytes).saturating_add(64) > budget {
                return Err(RpcError::too_large(full_bytes));
            }
        }
        if !rows.is_empty() && used.saturating_add(bytes).saturating_add(cursor_bytes) > budget {
            next = true;
            break;
        }
        used = used.saturating_add(bytes).saturating_add(1);
        last_id = Some(id);
        rows.push(row);
    }
    Ok(json!({"processes": rows, "nextCursor": if next { last_id } else { None }}))
}

/// Takes the output file a shell's session update names
/// (`_meta.acpmux.outputFile`, `claude_stdio/inbound.rs`) off it, before it
/// is logged: the update reaches every client of the chat, a remote one
/// too, and the path is local state.
pub(super) fn take_output_file(msg: &mut Value) -> Option<String> {
    let meta = msg.pointer_mut("/params/_meta")?.as_object_mut()?;
    let acpmux = meta.get_mut("acpmux")?.as_object_mut()?;
    let file = acpmux.remove("outputFile")?;
    if acpmux.is_empty() {
        meta.remove("acpmux");
    }
    if meta.is_empty()
        && let Some(params) = msg.get_mut("params").and_then(Value::as_object_mut)
    {
        params.remove("_meta");
    }
    file.as_str().map(str::to_owned)
}

/// The length of an output file; a missing one, or one that is not a
/// regular file, is empty.
fn output_len(file: &str) -> u64 {
    std::fs::metadata(file).ok().filter(|m| m.is_file()).map_or(0, |m| m.len())
}

/// Up to `max` bytes of `file` from `from` (`None`: its last `max`), where
/// they start, and the file's length. A missing file is empty, and so is
/// anything but a regular file, which is never opened: a FIFO's open waits
/// for a writer.
async fn read_output(
    file: Option<&str>,
    from: Option<u64>,
    max: u64,
) -> std::io::Result<(Vec<u8>, u64, u64)> {
    use tokio::io::{AsyncReadExt, AsyncSeekExt};
    let Some(file) = file else { return Ok((Vec::new(), 0, 0)) };
    match tokio::fs::metadata(file).await {
        Ok(m) if m.is_file() => {}
        Ok(_) => return Ok((Vec::new(), 0, 0)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((Vec::new(), 0, 0)),
        Err(e) => return Err(e),
    }
    let opened = tokio::fs::File::open(file).await;
    let mut f = match opened {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((Vec::new(), 0, 0)),
        Err(e) => return Err(e),
    };
    let len = f.metadata().await?.len();
    let start = from.map_or(len.saturating_sub(max), |from| from.min(len));
    f.seek(std::io::SeekFrom::Start(start)).await?;
    let mut data = Vec::new();
    f.take(max).read_to_end(&mut data).await?;
    Ok((data, start, len))
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
        // The log's last whole record, read from its end: a head alone could be a line a crash
        // cut short, which a whole-record read skips. Read first, so a record logged meanwhile
        // that the scan below does not fold is never counted as folded.
        let _ = self.store.scan_back(&session.id, 0, u64::MAX, &|_, _| false, &mut |e| {
            table.through = e.seq;
            false
        });
        // Only the kinds folded here are parsed (`Store::scan_heads`): an adoption after a
        // restart reads this from the whole log.
        let _ = self.store.scan_heads(&session.id, &mut |head| {
            if !matches!(
                (head.dir, head.kind),
                ("in", "background_task_update")
                    | ("mux", "process_update" | "stopped" | "exited" | "host_started")
            ) {
                return true;
            }
            let Some(e) = head.record() else { return true };
            table.through = table.through.max(e.seq);
            match (e.dir.as_str(), e.kind.as_str()) {
                ("in", "background_task_update") => {
                    let params = e.msg.get("params").unwrap_or(&Value::Null);
                    table.fold(session, params, e.at, None);
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
    /// subagent's, with the output file taken off it: a change is logged as
    /// `process_update`.
    pub(super) fn note_process(&self, session: &Session, rec: &EventRecord, output: Option<&str>) {
        let params = rec.msg.get("params").unwrap_or(&Value::Null);
        let changed = {
            let mut table = self.process_table(session);
            let i = if rec.seq > table.through {
                table.through = rec.seq;
                table.fold(session, params, rec.at, output)
            } else {
                // The first read of the log folded this record already: its
                // change is logged here, once. The log has no output file,
                // so it is kept here.
                let tool = params.pointer("/update/toolCallId").and_then(Value::as_str);
                let i = tool.and_then(|tool| table.find_tool(tool));
                let p = i.map(|i| &mut table.processes[i]);
                if let (Some(p), Some(file)) = (p, output.filter(|f| !f.is_empty()))
                    && p.output_file.is_none()
                {
                    p.output_file = Some(file.to_owned());
                    p.logged = false;
                }
                i.filter(|&i| !table.processes[i].logged)
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
        !table.running.is_empty()
    }

    /// How many of the session's background processes run, from a table this
    /// daemon has read already: never a log scan (`host_load.rs` asks for every chat).
    pub(super) fn running_processes_read(&self, session: &Session) -> usize {
        let table = session.processes.lock().unwrap_or_else(|e| e.into_inner());
        table.running.len()
    }

    /// `_acpmux/process/list`: the session's processes; without one, those of
    /// every chat whose processes this daemon has read (any chat that ran one
    /// since it started, or that it adopted).
    pub fn list_processes(&self, session: Option<&Session>) -> Value {
        // Taking the snapshot is the only operation that needs the process-table lock.
        // File metadata reads and JSON conversion must not hold it: process updates
        // from a running harness need to acquire the same mutex.
        let processes: Vec<Process> = match session {
            Some(session) => self.process_table(session).snapshot(),
            None => self
                .sessions()
                .iter()
                .flat_map(|s| {
                    let table = s.processes.lock().unwrap_or_else(|e| e.into_inner());
                    if table.loaded { table.snapshot() } else { Vec::new() }
                })
                .collect(),
        };
        json!({"processes": process_values(processes, output_len)})
    }

    /// Optional byte-bounded process-list pages, scoped to one session. The caller
    /// passes the last id it received, never a numeric offset that can shift.
    pub fn list_processes_page(
        &self,
        session: &Session,
        limit: usize,
        after: Option<&str>,
    ) -> Result<Value, RpcError> {
        let (window, has_more) = self.process_table(session).page_snapshot(limit, after)?;
        process_page_values(window, has_more, PROCESS_PAGE_BUDGET)
    }

    /// The session of the process `id` (`<sessionId>/<taskId>`).
    fn process_session(&self, id: &str) -> Result<Arc<Session>, RpcError> {
        let (sid, _) = id
            .split_once('/')
            .filter(|(sid, task)| !sid.is_empty() && !task.is_empty())
            .ok_or_else(|| RpcError::invalid_params("processId must be <sessionId>/<taskId>"))?;
        self.resolve(sid).ok().filter(|s| s.id == sid).ok_or_else(|| unknown_process(id))
    }

    /// `_acpmux/process/tail`: up to `max` bytes (at most 1 MiB; default
    /// 64 KiB) of the process's output from byte `from` (default: its last
    /// `max`). `eof`: the process ended and this read reached the end of
    /// its output. A file Claude Code has not named or written yet reads
    /// empty. A Codex process is refused: its output is not kept yet.
    pub async fn tail_process(
        &self,
        id: &str,
        from: Option<u64>,
        max: Option<u64>,
    ) -> Result<Value, RpcError> {
        use base64::Engine;
        let session = self.process_session(id)?;
        let (file, running) = {
            let table = self.process_table(&session);
            let p = table.find_id(id).ok_or_else(|| unknown_process(id))?;
            if p.harness == "codex" {
                return Err(RpcError::invalid_params("tail is Claude Code only for now"));
            }
            (p.output_file.clone(), p.state == ProcessState::Running)
        };
        let max = max.unwrap_or(TAIL_DEFAULT).min(TAIL_MAX);
        let (data, start, len) = read_output(file.as_deref(), from, max)
            .await
            .map_err(|e| RpcError::internal(format!("cannot read the process's output: {e}")))?;
        let next = start + data.len() as u64;
        Ok(json!({
            "data": base64::engine::general_purpose::STANDARD.encode(&data),
            "fromByte": start,
            "nextByte": next,
            "eof": !running && next >= len,
        }))
    }

    /// `_acpmux/process/kill`: asks Claude Code to stop the process
    /// (`stop_task`), or Codex (`thread/backgroundTerminals/terminate`); its
    /// end arrives as a `process_update`. One that already ended is left
    /// alone. Never starts a harness: with none running, the
    /// process ended with it and is `lost`.
    pub async fn kill_process(&self, id: &str) -> Result<Value, RpcError> {
        let unknown = || unknown_process(id);
        let session = self.process_session(id)?;
        let harness = session.meta().harness;
        let (claude, codex) = match self.config.read().await.profile(&harness) {
            Some(p) => (
                p.kind == crate::config::HarnessKind::ClaudeStdio,
                p.kind == crate::config::HarnessKind::Acp
                    && crate::codex_app_server::is_profile_launch(&p.argv),
            ),
            None => (false, false),
        };
        if !claude && !codex {
            return Err(RpcError::invalid_params(
                "only Claude Code's and Codex's background processes can be stopped",
            ));
        }
        let (task, running, subagent) = {
            let table = self.process_table(&session);
            let p = table.find_id(id).ok_or_else(unknown)?;
            (p.task_id.clone(), p.state == ProcessState::Running, p.subagent_session_id.clone())
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
        let agent_session = session.meta().agent_session_id;
        // Codex: the app-server's terminate (`codex_app_server/background.rs`),
        // on the thread that runs it (a subagent's session is its thread).
        let (stop, params, harness) = if codex {
            let thread = subagent.or(agent_session);
            let params = json!({"threadId": thread, "processId": task});
            (crate::codex_app_server::TERMINATE, params, "Codex")
        } else {
            let params = json!({"sessionId": agent_session, "taskId": task});
            (crate::claude_stdio::STOP_TASK, params, "Claude Code")
        };
        let asked = tokio::time::timeout(STOP_TIMEOUT, child.request(stop, params)).await;
        let refused = match asked {
            Ok(Ok(_)) => return Ok(json!({})),
            Ok(Err(e)) => e,
            Err(_) => RpcError::internal(format!("{harness} did not answer {stop} in time")),
        };
        // Another kill of this process may still wait on its own stop_task.
        if inserted {
            self.process_table(&session).stopping.remove(id);
        }
        Err(refused)
    }

    /// How long Ctrl-B waits for Claude Code's `background_tasks` answer
    /// (`STOP_TIMEOUT` until set; tests shorten it).
    pub fn set_background_timeout(&self, timeout: std::time::Duration) {
        *self.background_timeout.lock().unwrap_or_else(|e| e.into_inner()) = timeout;
    }

    /// `_acpmux/process/background` (Ctrl-B): asks Claude Code to move the
    /// chat's running work to the background (`background_tasks`): the task
    /// tool call `tool` started, or every foreground task. What moved
    /// arrives as `process_update`s with origin `user_backgrounded`. Codex
    /// moves long commands there itself, and other agents have no such
    /// request: refused. With no turn running, nothing runs in the
    /// foreground: `backgrounded: false`, and Claude Code is not asked.
    pub async fn background_work(&self, key: &str, tool: Option<&str>) -> Result<Value, RpcError> {
        let session = self.resolve(key)?;
        if !session.backgrounds_work.load(Ordering::SeqCst) {
            return Err(RpcError::invalid_params(
                "only Claude Code can move running work to the background",
            ));
        }
        let nothing = json!({"backgrounded": false});
        if session.turn().is_none() {
            return Ok(nothing);
        }
        let child = session.child.lock().await.clone();
        let alive = match &child {
            Some(child) => child.is_alive().await,
            None => false,
        };
        let Some(child) = child.filter(|_| alive) else { return Ok(nothing) };
        let timeout = *self.background_timeout.lock().unwrap_or_else(|e| e.into_inner());
        // The translator drops the request's marks when this wait ends (`timeoutMs`).
        let params = json!({
            "sessionId": session.meta().agent_session_id,
            "toolCallId": tool,
            "timeoutMs": u64::try_from(timeout.as_millis()).unwrap_or(u64::MAX),
        });
        let ask = child.request(crate::claude_stdio::BACKGROUND_TASKS, params);
        match tokio::time::timeout(timeout, ask).await {
            Ok(Ok(answer)) => {
                let moved = answer.get("backgrounded").and_then(Value::as_bool).unwrap_or(true);
                Ok(json!({"backgrounded": moved}))
            }
            Ok(Err(e)) => Err(e),
            Err(_) => {
                Err(RpcError::internal("Claude Code did not answer background_tasks in time"))
            }
        }
    }
}

/// Whether `_acpmux/process/background` moves the foreground work of a
/// chat whose harness started as `kind`: Claude Code (claude-stdio), whatever
/// its profile's name (the `cmux` model router's too). Decided at each start
/// (`Session::backgrounds_work`), so a config write or reload never flips it;
/// every session summary says it (`backgroundsWork`), so a client offers
/// Ctrl-B exactly where this takes it.
pub(super) fn backgrounds_work(kind: crate::config::HarnessKind) -> bool {
    kind == crate::config::HarnessKind::ClaudeStdio
}

/// No process has the id.
fn unknown_process(id: &str) -> RpcError {
    RpcError::not_found(format!("no background process {id:?}"))
}

#[cfg(test)]
mod process_list_snapshot_tests {
    use super::*;

    #[test]
    fn a_process_list_reads_output_metadata_after_releasing_its_table() {
        let process: Process = serde_json::from_value(json!({
            "id": "chat/task", "sessionId": "chat", "toolCallId": "call",
            "taskId": "task", "harness": "claude", "command": "cargo test",
            "cwd": "/tmp", "startedAt": 100, "endedAt": 200,
            "state": "exited", "origin": "background", "outputFile": "/tmp/task-output"
        }))
        .unwrap();
        let table = std::sync::Mutex::new(ProcessTable {
            loaded: true,
            processes: vec![process],
            ..ProcessTable::default()
        });
        // Every caller first takes its snapshot, then drops the guard before
        // collecting live file sizes and serializing the reply.
        let snapshot = table.lock().unwrap().snapshot();
        let rows = process_values(snapshot, |path| {
            assert_eq!(path, "/tmp/task-output");
            assert!(table.try_lock().is_ok(), "filesystem metadata read under process-table lock");
            42
        });
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["id"], "chat/task");
        assert_eq!(rows[0]["state"], "exited");
        assert_eq!(rows[0]["outputBytes"], 42);
        // The saved table remains unchanged: a later list re-reads the file size.
        assert_eq!(table.lock().unwrap().processes[0].output_bytes, None);
    }
}
