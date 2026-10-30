//! Part of `Hub`; see `hub/mod.rs`. Background tasks the daemon owns (`bg_run.rs`,
//! docs/hibernation.md): an agent starts one with `_acpmux/bg/start`, and it runs under its own
//! runner, never under the harness, so a hibernated agent's tasks keep
//! running and a woken agent reads them by id (`bg_list`, `bg_output`). Leo, 2026-10-27: "also
//! when it comes to hibernation...can't you hibernate the agent but not hibernate the bg tasks?"
//!
//! A chat's tasks live in `<ACPMUX_HOME>/bg/<sessionId>/`: per task the runner's record, its
//! liveness lock, its stop FIFO and its bounded output. That folder is the only state: a task
//! runs while its runner holds the lock, so a restarted daemon lists the same tasks. A stop goes
//! through the FIFO, never a pid signal (`bg_run.rs`). They never keep a chat
//! awake (`idle.rs`): a harness's own background shells do, since its exit ends them. A task
//! runs until it ends, an agent or a person stops it, or its chat is purged.
//!
//! The folder is keyed by the chat's id, which names one chat: an import takes an id here only
//! for that same chat coming back (`transfer_in.rs` replaces a moved-away chat only when its
//! harness and agent session match), so the tasks it finds are its own.

use super::*;
use crate::bg_run::{self, Record};
use anyhow::{Context, anyhow};
use cmux_json::JsonSet as _;
use std::collections::BTreeMap;
use std::path::PathBuf;

fn internal(e: impl std::fmt::Display) -> RpcError {
    RpcError::internal(e.to_string())
}

/// The most tasks one chat runs at once.
const MAX_RUNNING: usize = 32;
/// The most a `bg/output` returns, and what one without `maxBytes` returns.
const OUTPUT_MAX: u64 = 1 << 20;
const OUTPUT_DEFAULT: u64 = 64 << 10;
/// The tail each listed task shows.
const LIST_TAIL: u64 = 1 << 10;
/// How long a start waits for its runner's answer.
const START_WAIT: std::time::Duration = std::time::Duration::from_secs(10);

impl Hub {
    fn bg_dir(&self, session: &Session) -> PathBuf {
        crate::config::home().join("bg").join(&session.id)
    }

    /// Tests run the runner from the acpmux binary they name, and a smaller spool segment.
    pub fn set_bg_runner(&self, exe: PathBuf, segment: u64) {
        *self.bg_runner.lock().unwrap_or_else(|e| e.into_inner()) =
            Some((crate::self_command::SelfCommand::new(exe, Vec::new()), segment));
    }

    /// `_acpmux/bg/start`: runs `command` in `cwd` (the chat's folder by default), in the
    /// environment the chat's agent runs with ([`Hub::bg_env`]).
    pub async fn bg_start(
        &self,
        session: &Arc<Session>,
        command: &str,
        cwd: Option<PathBuf>,
    ) -> Result<Value, RpcError> {
        if command.trim().is_empty() {
            return Err(RpcError::invalid_params("command is empty"));
        }
        // One start at a time: the running count and a purge's stop see every task.
        let _one = self.bg_starts.lock().await;
        // A chat stopped before a restart is Closed with no closing flag: both count.
        let closing = || {
            session.closing.load(Ordering::SeqCst)
                || session.purged.load(Ordering::SeqCst)
                || session.status() == SessionStatus::Closed
        };
        if closing() {
            return Err(RpcError::invalid_params("the chat is stopped; it starts no task"));
        }
        let meta = session.meta();
        if meta.remote_origin {
            return Err(RpcError::invalid_params("a remote chat runs no background task here"));
        }
        let cwd = cwd.unwrap_or(meta.cwd.clone());
        if !cwd.is_dir() {
            return Err(RpcError::invalid_params(format!("{} is not a folder", cwd.display())));
        }
        let dir = self.bg_dir(session);
        // A runner whose lock cannot be probed counts: the cap never lets an unknown one by.
        let running = self.bg_records(&dir).iter().filter(|r| !bg_gone(&dir, &r.id)).count();
        if running >= MAX_RUNNING {
            return Err(RpcError::invalid_params(format!(
                "{MAX_RUNNING} background tasks already run in this chat; stop one first"
            )));
        }
        let env = self.bg_env(session, &meta).await?;
        std::fs::create_dir_all(&dir).map_err(internal)?;
        let generation = bg_generation(&dir, true).map_err(internal)?;
        let uuid = uuid::Uuid::now_v7().simple().to_string();
        let id = format!("bg-{}", uuid.get(20..).unwrap_or(&uuid));
        let set = self.bg_runner.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let (runner, segment) = match set {
            Some(set) => set,
            None => {
                (crate::self_command::SelfCommand::current().map_err(internal)?, bg_run::SEGMENT)
            }
        };
        let spec = bg_run::Spec {
            dir: dir.clone(),
            id: id.clone(),
            session_id: session.id.clone(),
            command: command.to_owned(),
            cwd,
            env,
            segment,
            generation,
        };
        bg_spawn(&runner, &spec).await.map_err(|e| RpcError::internal(format!("{e:#}")))?;
        // A stop or purge that came meanwhile missed it: it ends here.
        if closing() {
            bg_run::request_stop(&dir, &id, &spec.generation);
            return Err(RpcError::invalid_params("the chat stopped; its task was stopped"));
        }
        let record = bg_run::read_record(&dir, &id)
            .ok_or_else(|| RpcError::internal("the task's runner wrote no record"))?;
        Ok(bg_view(&dir, &record, LIST_TAIL))
    }

    /// The environment the chat's agent runs with, so a task sees what the agent's own shell
    /// sees whatever its harness passes an MCP server (Codex passes only a few names): built by
    /// the launch's own builder (`agent::harness_command`) from the profile as a spawn builds it
    /// now (`Hub::spawn_profile_for`: defaults, preset, chat store, session env, expansions).
    /// That is the env the agent wakes with, since a hibernated agent starts again from it.
    async fn bg_env(
        &self,
        session: &Session,
        meta: &SessionMeta,
    ) -> Result<BTreeMap<String, String>, RpcError> {
        let (profile, defaults) = {
            let cfg = self.config.read().await;
            let profile =
                super::resolve::session_profile(&cfg, &meta.harness, &meta.cwd, meta.remote_origin)
                    .map_err(RpcError::invalid_params)?;
            (profile, cfg.defaults_for(&meta.harness))
        };
        let profile = self.spawn_profile_for(meta, &profile, &defaults.env).await?;
        let at = Some((session.id.as_str(), meta.name.as_str()));
        let cmd = crate::agent::harness_command(&meta.harness, &profile, &meta.cwd, None, at)
            .map_err(|e| RpcError::internal(format!("{e:#}")))?;
        Ok(crate::agent::command_env(&cmd).into_iter().collect())
    }

    /// The folder's tasks: only records of its own generation, so a runner that outlived a purge
    /// of an earlier folder of this name never shows here.
    fn bg_records(&self, dir: &std::path::Path) -> Vec<Record> {
        let Ok(generation) = bg_generation(dir, false) else { return Vec::new() };
        let mut records: Vec<Record> = std::fs::read_dir(dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| {
                let name = e.file_name().into_string().ok()?;
                bg_run::read_record(dir, name.strip_suffix(".json")?)
            })
            .filter(|r| r.generation == generation)
            .collect();
        records.sort_by_key(|r| r.started_at);
        records
    }

    /// Whether a task of the chat runs (`Hub::in_use`).
    pub(super) fn bg_running(&self, session: &Session) -> bool {
        let dir = self.bg_dir(session);
        self.bg_records(&dir).iter().any(|r| r.ended_at.is_none() && !bg_gone(&dir, &r.id))
    }

    /// `_acpmux/bg/list`: the chat's tasks, oldest first, each with the tail of its output.
    pub fn bg_list(&self, session: &Session) -> Value {
        let dir = self.bg_dir(session);
        let tasks: Vec<Value> =
            self.bg_records(&dir).iter().map(|r| bg_view(&dir, r, LIST_TAIL)).collect();
        json!({"tasks": tasks})
    }

    fn bg_record(&self, session: &Session, id: &str) -> Result<(PathBuf, Record), RpcError> {
        let dir = self.bg_dir(session);
        let known = !id.is_empty() && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
        let generation = bg_generation(&dir, false).ok();
        let record = known.then(|| bg_run::read_record(&dir, id)).flatten();
        match record.filter(|r| Some(&r.generation) == generation.as_ref()) {
            Some(r) => Ok((dir, r)),
            None => Err(RpcError::not_found(format!("background task {id}"))),
        }
    }

    /// `_acpmux/bg/output`: up to `max` bytes from `from` (`None`: the last `max`).
    pub fn bg_output(
        &self,
        session: &Session,
        id: &str,
        from: Option<u64>,
        max: Option<u64>,
    ) -> Result<Value, RpcError> {
        use base64::Engine;
        let (dir, record) = self.bg_record(session, id)?;
        let max = max.unwrap_or(OUTPUT_DEFAULT).min(OUTPUT_MAX);
        let read = bg_run::read_output(&dir, id, from, max).map_err(internal)?;
        let mut view = bg_view(&dir, &record, 0);
        // The bytes exactly (`data`), and as text for an agent to read (`text`).
        view.set("data", json!(base64::engine::general_purpose::STANDARD.encode(&read.data)));
        view.set("text", json!(String::from_utf8_lossy(&read.data)));
        view.set("fromByte", json!(read.start));
        view.set("nextByte", json!(read.start + read.data.len() as u64));
        view.set("skippedBytes", json!(from.map_or(0, |f| read.start.saturating_sub(f))));
        Ok(view)
    }

    /// `_acpmux/bg/stop`: asks the task's runner to stop it (SIGTERM to the task's group, SIGKILL
    /// to the group after the grace) and waits until the runner is gone, at most [`STOP_WAIT`].
    pub async fn bg_stop(&self, session: &Session, id: &str) -> Result<Value, RpcError> {
        let (dir, record) = self.bg_record(session, id)?;
        if bg_run::request_stop(&dir, id, &record.generation) {
            bg_wait_gone(&dir, id).await;
        }
        let record = bg_run::read_record(&dir, id).unwrap_or(record);
        Ok(bg_view(&dir, &record, LIST_TAIL))
    }

    /// A purged chat's tasks are stopped at once and its folder goes at once, moved to
    /// `bg/.purged/<chat>-<uuid>` where no chat looks, so a purge never waits with the chat still
    /// open (a prompt meanwhile could reopen it) and a chat that later takes its id (an import)
    /// finds none. The runners exit on their own; a background wait ([`STOP_WAIT`]) then removes
    /// the moved folder, and each purge also clears earlier moved folders whose runners are all
    /// gone. A runner that writes later under the old path finds no folder, or a new one whose
    /// generation is not its own (its records never show there). A folder that neither moves nor
    /// goes fails the purge, so the chat stays (stopped) rather than leave its tasks to a later
    /// chat of this id. It holds the start lock, so a start in flight is either seen here or sees
    /// the chat closing.
    pub(super) async fn bg_purge(&self, session: &Session) -> Result<(), RpcError> {
        let _one = self.bg_starts.lock().await;
        let dir = self.bg_dir(session);
        let aside = crate::config::home().join("bg").join(".purged");
        bg_sweep(&aside);
        // Every task the folder holds, from its files, not its records: a record that cannot be
        // read still has a runner to stop. A folder that cannot be listed fails the purge.
        let ids = bg_task_ids(&dir).map_err(internal)?;
        if ids.is_empty() {
            let _ = std::fs::remove_dir_all(&dir);
            return bg_cleared(&dir);
        }
        // The stops carry the folder's generation, so only its own runners act on them: a runner
        // of an earlier folder of this id whose FIFO landed here ignores them. A folder with no
        // generation started no task of its own (a start makes it first). One that cannot be
        // read fails the purge.
        let generation = match bg_generation(&dir, false) {
            Ok(g) => Some(g),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => return Err(internal(e)),
        };
        if let Some(generation) = &generation {
            for id in &ids {
                bg_run::request_stop(&dir, id, generation);
            }
        }
        let to = aside.join(format!("{}-{}", session.id, uuid::Uuid::now_v7().simple()));
        match std::fs::create_dir_all(&aside).and_then(|()| std::fs::rename(&dir, &to)) {
            // The runners' locks moved with the folder (same files), so the wait reads them there.
            Ok(()) => {
                tokio::spawn(async move {
                    let waits = ids.iter().map(|id| bg_wait_gone(&to, id));
                    futures::future::join_all(waits).await;
                    bg_sweep_one(&to);
                });
            }
            // Where no move works, the folder goes; a runner keeps its open files.
            Err(e) => {
                tracing::warn!(dir = %dir.display(), "a purged chat's tasks could not be moved aside: {e}");
                let _ = std::fs::remove_dir_all(&dir);
            }
        }
        bg_cleared(&dir)
    }
}

/// Clears the moved folders of earlier purges whose runners are all gone.
fn bg_sweep(aside: &std::path::Path) {
    for entry in std::fs::read_dir(aside).into_iter().flatten().flatten() {
        bg_sweep_one(&entry.path());
    }
}

/// Removes a purged chat's moved folder once nothing holds any of its locks. A folder that
/// cannot be listed stays.
fn bg_sweep_one(dir: &std::path::Path) {
    if bg_task_ids(dir).is_ok_and(|ids| ids.iter().all(|id| bg_gone(dir, id))) {
        let _ = std::fs::remove_dir_all(dir);
    }
}

/// The ids of every task a folder holds files of (its lock or stop FIFO); none when the folder
/// is gone, an error when it cannot be listed.
fn bg_task_ids(dir: &std::path::Path) -> std::io::Result<Vec<String>> {
    let entries = match std::fs::read_dir(dir) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        r => r?,
    };
    let mut ids = std::collections::BTreeSet::new();
    for entry in entries {
        let name = entry?.file_name();
        let name = name.to_string_lossy();
        if let Some(id) = name.strip_suffix(".lock").or_else(|| name.strip_suffix(".ctl")) {
            ids.insert(id.to_owned());
        }
    }
    Ok(ids.into_iter().collect())
}

/// The folder's generation (`.generation`, made with the folder's first task when `make`). An
/// empty file (a write a crash or a full disk cut short) is no generation: no task ever started
/// with one, and `make` replaces it. A new one appears whole (written aside, then renamed), so a
/// runner's stops always match the generation its folder holds.
fn bg_generation(dir: &std::path::Path, make: bool) -> std::io::Result<String> {
    let path = dir.join(".generation");
    let read = std::fs::read_to_string(&path).and_then(|g| match g.trim() {
        "" => Err(std::io::Error::new(std::io::ErrorKind::NotFound, "an empty generation")),
        g => Ok(g.to_owned()),
    });
    match read {
        Err(e) if make && e.kind() == std::io::ErrorKind::NotFound => {
            let generation = uuid::Uuid::now_v7().simple().to_string();
            let aside = dir.join(format!(".generation.{generation}"));
            std::fs::write(&aside, &generation)
                .and_then(|()| std::fs::rename(&aside, &path))
                .inspect_err(|_| {
                    let _ = std::fs::remove_file(&aside);
                })?;
            Ok(generation)
        }
        r => r,
    }
}

/// A purge's end: the chat's folder is gone, or the purge fails.
fn bg_cleared(dir: &std::path::Path) -> Result<(), RpcError> {
    match std::fs::symlink_metadata(dir) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        _ => Err(RpcError::internal(format!(
            "the chat's background tasks in {} could not be removed",
            dir.display()
        ))),
    }
}

/// How long a stop waits for the task's runner to exit: its two graces and 10 s.
const STOP_WAIT: std::time::Duration =
    std::time::Duration::from_secs(bg_run::GRACE.as_secs() * 2 + START_WAIT.as_secs());
/// How often that wait looks at the lock.
const STOP_LOOK: std::time::Duration = std::time::Duration::from_millis(50);

/// Whether the task's runner is surely gone: its lock is free or missing. A lock that cannot be
/// probed proves nothing, so it never counts.
fn bg_gone(dir: &std::path::Path, id: &str) -> bool {
    #[cfg(unix)]
    {
        matches!(
            crate::agent_host::liveness_of(&bg_run::lock_path(dir, id)),
            crate::agent_host::Liveness::Dead
        )
    }
    #[cfg(not(unix))]
    {
        let _ = (dir, id);
        true
    }
}

/// Waits until the task's runner exited (nothing holds its lock), at most [`STOP_WAIT`]: a
/// non-blocking look every [`STOP_LOOK`], so no thread or descriptor outlives the wait.
async fn bg_wait_gone(dir: &std::path::Path, id: &str) -> bool {
    let deadline = tokio::time::Instant::now() + STOP_WAIT;
    while !bg_gone(dir, id) {
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(STOP_LOOK).await;
    }
    true
}

/// A task as the wire carries it: `state` is `running`, `exited`, `stopped`, `killed` (a signal
/// nobody here sent) or `lost` (its runner died without a word), with its last `tail` bytes.
fn bg_view(dir: &std::path::Path, r: &Record, tail: u64) -> Value {
    // An exit the runner wrote is final; without one, only a free lock says the runner is gone.
    let running = r.ended_at.is_none() && !bg_gone(dir, &r.id);
    let state = match (running, r.ended_at, r.stopped, r.signal) {
        (true, ..) => "running",
        (_, None, ..) => "lost",
        (_, _, true, _) => "stopped",
        (_, _, _, Some(_)) => "killed",
        _ => "exited",
    };
    let read = bg_run::read_output(dir, &r.id, None, tail).unwrap_or_default();
    json!({
        "id": r.id, "sessionId": r.session_id, "command": r.command, "cwd": r.cwd,
        "state": state, "pid": r.pid, "startedAt": r.started_at, "endedAt": r.ended_at,
        "exitCode": r.exit_code, "signal": r.signal, "totalBytes": read.total,
        "keptFromByte": read.kept_from, "tail": String::from_utf8_lossy(&read.data),
        // Set when the spool failed (a full disk): output after it is gone, so it is incomplete.
        "outputError": r.output_error,
    })
}

/// Starts the runner in a session of its own and waits for its one-line answer: the task runs.
async fn bg_spawn(runner: &crate::self_command::SelfCommand, spec: &bg_run::Spec) -> Result<()> {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    let mut cmd = tokio::process::Command::from(runner.command(&[bg_run::RUN_ARG]));
    cmd.stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(false);
    // SAFETY: setsid is async-signal-safe. The runner leads its own session, so it outlives the
    // daemon and is in no harness's group.
    #[cfg(unix)]
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = cmd.spawn().context("start the task's runner")?;
    if let Some(pid) = child.id() {
        crate::agent_host::scope::place(pid).await;
    }
    let mut stdin = child.stdin.take().context("runner stdin")?;
    let stdout = child.stdout.take().context("runner stdout")?;
    let answer = tokio::time::timeout(START_WAIT, async {
        stdin.write_all(format!("{}\n", serde_json::to_string(spec)?).as_bytes()).await?;
        drop(stdin);
        let mut line = String::new();
        tokio::io::BufReader::new(stdout).read_line(&mut line).await?;
        anyhow::Ok(line)
    })
    .await;
    if !matches!(answer, Ok(Ok(_)))
        && let Some(pid) = child.id()
    {
        // SAFETY: still this process's unreaped child; its SIGTERM stops a task it started.
        #[cfg(unix)]
        unsafe {
            libc::kill(pid as i32, libc::SIGTERM);
        }
    }
    // Not this process's child for long: reaped in the background, never a zombie.
    tokio::spawn(async move {
        let _ = child.wait().await;
    });
    match answer {
        Ok(Ok(line)) if line.contains("\"pid\"") => Ok(()),
        Ok(Ok(_)) => Err(anyhow!("the task did not start")),
        Ok(Err(e)) => Err(e),
        Err(_) => Err(anyhow!("the task's runner did not answer in time")),
    }
}
