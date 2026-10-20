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
//! Claude Code writes each shell's output to a file it names
//! (`output_file`), which `_acpmux/process/tail` reads. The agent host runs
//! on this machine, so the daemon reads the file itself.

use super::*;
use serde::{Deserialize, Serialize};

/// The reason of a process that ended with its harness.
pub(super) const HARNESS_EXIT: &str = "harness_exit";

/// How long a kill waits for Claude Code's `stop_task` or Codex's terminate.
const STOP_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// What a tail without `maxBytes` reads: the last 64 KiB.
const TAIL_DEFAULT: u64 = 64 << 10;

/// The most one tail reads, whatever `maxBytes` asks.
const TAIL_MAX: u64 = 1 << 20;

/// Authority presented by one local connection to the process API. A bare same-uid connection
/// has none: agents run as this uid too, so only the person proof, a caller token, or the App's
/// process-viewer capability establishes scope.
#[derive(Debug, Clone, Copy)]
pub(crate) enum ProcessAccess<'a> {
    Person,
    Caller(&'a str),
    Viewer { session: &'a str, tool_call: &'a str },
}

impl<'a> ProcessAccess<'a> {
    fn allows(self, process: &Process) -> bool {
        match self {
            Self::Person => true,
            Self::Caller(session) => {
                process.session_id == session
                    || process.subagent_session_id.as_deref() == Some(session)
            }
            Self::Viewer { session, tool_call } => {
                (process.session_id == session
                    || process.subagent_session_id.as_deref() == Some(session))
                    && process.tool_call_id == tool_call
            }
        }
    }

    pub(crate) fn session(self) -> Option<&'a str> {
        match self {
            Self::Person => None,
            Self::Caller(session) | Self::Viewer { session, .. } => Some(session),
        }
    }
}

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
    /// `background` (started there) or `auto_backgrounded` (moved there).
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
    /// Processes a person asked to stop: their end is the person's.
    stopping: std::collections::HashSet<String>,
}

impl ProcessTable {
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
                    output_file: None,
                    logged: false,
                });
                self.processes.len() - 1
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

    /// The processes as the wire carries them, each with its output's
    /// length now.
    fn values(&self, access: ProcessAccess<'_>) -> Vec<Value> {
        let listed = |p: &Process| {
            let mut p = p.clone();
            p.output_bytes = p.output_file.as_deref().map(|file| output_len(file, &p.task_id));
            serde_json::to_value(p).ok()
        };
        self.processes.iter().filter(|process| access.allows(process)).filter_map(listed).collect()
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
fn output_len(file: &str, task_id: &str) -> u64 {
    open_output_file(file, task_id)
        .ok()
        .flatten()
        .and_then(|file| file.metadata().ok())
        .filter(|metadata| metadata.is_file())
        .map_or(0, |metadata| metadata.len())
}

/// The harness may name only its own `tasks/<task id>.output` shape. Traversal is refused before
/// opening anything. macOS spells `/tmp` as a symlink to `/private/tmp`; normalize that one
/// system-owned alias before the no-follow component walk.
fn allowed_output_path(file: &str, task_id: &str) -> std::io::Result<std::path::PathBuf> {
    use std::path::{Component, Path, PathBuf};

    let path = Path::new(file);
    let invalid = || {
        std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "background output is not the harness task's output path",
        )
    };
    let expected = std::ffi::OsString::from(format!("{task_id}.output"));
    if task_id.is_empty()
        || !path.is_absolute()
        || path.file_name() != Some(expected.as_os_str())
        || path.parent().and_then(Path::file_name) != Some(std::ffi::OsStr::new("tasks"))
    {
        return Err(invalid());
    }
    if path.components().any(|component| {
        !matches!(component, Component::RootDir | Component::Prefix(_) | Component::Normal(_))
    }) {
        return Err(invalid());
    }

    #[cfg(target_os = "macos")]
    let path: PathBuf = match path.strip_prefix("/tmp") {
        Ok(relative) => Path::new("/private/tmp").join(relative),
        Err(_) => path.to_owned(),
    };
    #[cfg(not(target_os = "macos"))]
    let path: PathBuf = path.to_owned();

    Ok(path)
}

/// Opens an allowed task-output file without following a symlink in any component. The returned
/// descriptor is the one later measured and read, closing check/open and rename races.
#[cfg(unix)]
fn open_output_file(file: &str, task_id: &str) -> std::io::Result<Option<std::fs::File>> {
    use std::ffi::CString;
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::OpenOptionsExt;
    use std::path::Component;

    let path = allowed_output_path(file, task_id)?;
    let mut current = {
        let mut options = std::fs::OpenOptions::new();
        options.read(true).custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC);
        options.open("/")?
    };
    let mut components = path
        .components()
        .filter_map(|component| match component {
            Component::Normal(name) => Some(name),
            _ => None,
        })
        .peekable();
    while let Some(component) = components.next() {
        let name = CString::new(component.as_bytes()).map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::InvalidInput, "NUL in background output path")
        })?;
        let last = components.peek().is_none();
        let flags = libc::O_RDONLY
            | libc::O_NOFOLLOW
            | libc::O_CLOEXEC
            | if last { libc::O_NONBLOCK } else { libc::O_DIRECTORY };
        // SAFETY: `current` is an open directory descriptor for every non-final step, `name` is a
        // NUL-terminated single component, and a successful descriptor is immediately owned.
        let descriptor = unsafe { libc::openat(current.as_raw_fd(), name.as_ptr(), flags) };
        if descriptor < 0 {
            let error = std::io::Error::last_os_error();
            return if error.kind() == std::io::ErrorKind::NotFound {
                Ok(None)
            } else {
                Err(error)
            };
        }
        // SAFETY: `openat` returned a new owned descriptor.
        current = unsafe { std::fs::File::from_raw_fd(descriptor) };
        let metadata = current.metadata()?;
        if (last && !metadata.is_file()) || (!last && !metadata.is_dir()) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "background output path is not a regular file",
            ));
        }
    }
    Ok(Some(current))
}

/// Non-Unix builds have no remote Seatbelt boundary. Refuse a final symlink and keep the same
/// root/type policy; their process-output producer does not currently expose tail bytes.
#[cfg(not(unix))]
fn open_output_file(file: &str, task_id: &str) -> std::io::Result<Option<std::fs::File>> {
    let path = allowed_output_path(file, task_id)?;
    let metadata = match std::fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "background output path is not a regular file",
        ));
    }
    std::fs::File::open(path).map(Some)
}

/// Up to `max` bytes of `file` from `from` (`None`: its last `max`), where
/// they start, and the file's length. A missing file is empty, and so is
/// anything but a regular file, which is never opened: a FIFO's open waits
/// for a writer.
async fn read_output(
    file: Option<&str>,
    task_id: &str,
    from: Option<u64>,
    max: u64,
) -> std::io::Result<(Vec<u8>, u64, u64)> {
    use tokio::io::{AsyncReadExt, AsyncSeekExt};
    let Some(file) = file else { return Ok((Vec::new(), 0, 0)) };
    let Some(opened) = tokio::task::spawn_blocking({
        let file = file.to_owned();
        let task_id = task_id.to_owned();
        move || open_output_file(&file, &task_id)
    })
    .await
    .map_err(std::io::Error::other)??
    else {
        return Ok((Vec::new(), 0, 0));
    };
    let mut f = tokio::fs::File::from_std(opened);
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
        let _ = self.store.scan(&session.id, 0, &mut |e: EventRecord| {
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
                let i = table.processes.iter().position(|p| Some(p.tool_call_id.as_str()) == tool);
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
        table.processes.iter().any(|p| p.state == ProcessState::Running)
    }

    /// `_acpmux/process/list`: the session's processes; without one, those of
    /// every chat whose processes this daemon has read (any chat that ran one
    /// since it started, or that it adopted).
    pub(crate) fn list_processes(
        &self,
        access: ProcessAccess<'_>,
        session: Option<&Session>,
    ) -> Value {
        let processes = match session {
            Some(session) => self.process_table(session).values(access),
            None => self
                .sessions()
                .iter()
                .flat_map(|s| {
                    let table = s.processes.lock().unwrap_or_else(|e| e.into_inner());
                    if table.loaded { table.values(access) } else { Vec::new() }
                })
                .collect(),
        };
        json!({"processes": processes})
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
    pub(crate) async fn tail_process(
        &self,
        access: ProcessAccess<'_>,
        id: &str,
        from: Option<u64>,
        max: Option<u64>,
    ) -> Result<Value, RpcError> {
        use base64::Engine;
        let session = self.process_session(id)?;
        let (file, task, running) = {
            let table = self.process_table(&session);
            let p = table.processes.iter().find(|p| p.id == id);
            let p = p.ok_or_else(|| unknown_process(id))?;
            if !access.allows(p) {
                return Err(process_access_required());
            }
            if p.harness == "codex" {
                return Err(RpcError::invalid_params("tail is Claude Code only for now"));
            }
            (p.output_file.clone(), p.task_id.clone(), p.state == ProcessState::Running)
        };
        let max = max.unwrap_or(TAIL_DEFAULT).min(TAIL_MAX);
        let (data, start, len) = read_output(file.as_deref(), &task, from, max)
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
    pub(crate) async fn kill_process(
        &self,
        access: ProcessAccess<'_>,
        id: &str,
    ) -> Result<Value, RpcError> {
        let unknown = || unknown_process(id);
        let session = self.process_session(id)?;
        let (task, running, subagent) = {
            let table = self.process_table(&session);
            let p = table.processes.iter().find(|p| p.id == id).ok_or_else(unknown)?;
            if !access.allows(p) {
                return Err(process_access_required());
            }
            (p.task_id.clone(), p.state == ProcessState::Running, p.subagent_session_id.clone())
        };
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
}

/// No process has the id.
fn unknown_process(id: &str) -> RpcError {
    RpcError::not_found(format!("no background process {id:?}"))
}

/// Process output and stops need the person's proof, a caller token for the owning session, or a
/// scoped viewer capability. Same uid alone is deliberately not authority (`hub/person.rs`).
pub(crate) fn process_access_required() -> RpcError {
    crate::hub::person::person_required("reading or stopping background processes")
}
