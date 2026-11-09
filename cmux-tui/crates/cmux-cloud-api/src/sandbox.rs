//! Sandboxed Runs on NEXT Cloud, owned by the cmux daemon: one task on a machine made for it and
//! deleted after. The daemon's `cloud.runs.*` ops answer from here; nothing goes to classic Cloud.
//!
//! A Run is a Cloud chat on a new small machine through the app's own `cloud start-chat` path (the
//! same verbs, checks and logins), with the task as its prompt and the turn's reply as the answer.
//! The [`Steps`] the daemon gives say how: its own runs those verbs as child processes; a test's
//! fake answers at once. This module keeps the rules: what a create takes, one Run per
//! idempotency key, the deadline, a cancel, the snapshot a wait answers (the classic shape the app
//! reads: `{run, attempts, artifacts, receipt}`) and the cleanup.
//!
//! Cleanup: the machine is deleted on every path (a reply, a failure, a timeout, a cancel). A
//! delete that fails is tried again with a growing pause (at most [`Timing::retry_max`]) until the
//! machine is deleted or confirmed gone, or for [`Timing::give_up`] after the Run ended. "Gone"
//! counts only after the Run's settle time: when the start was cut off (a cancel, a timeout, a
//! daemon restart), the app may still be making the machine, so a list without it is read again
//! until the start's own bound has passed.
//!
//! Persistence: the Runs live in one JSON file (0600) in the daemon's state directory, written on
//! every change. A daemon that starts again reads it: a Run that was still going ends `failed`
//! ("the cmux daemon restarted during the Run") and its cleanup goes on. The task text is never
//! written there; the reply is (a wait after a restart answers it).
//!
//! Stop conditions: a Run's thread ends when its cleanup is done or given up; a wait ends at its
//! own bound (10 s at most); ended Runs are dropped [`Timing::keep_ended`] after they ended.

use std::collections::HashMap;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest as _, Sha256};

use super::{Failure, optional_int, optional_text};

/// The longest one wait holds.
pub const WAIT_LIMIT_MS: i64 = 10_000;
pub const DEFAULT_TIMEOUT_MS: i64 = 600_000;
pub const MIN_TIMEOUT_MS: i64 = 30_000;
pub const MAX_TIMEOUT_MS: i64 = 720_000;
/// A `runs.sandbox` call's room past the task's timeout: the machine's start and its delete.
pub const DEFAULT_TEARDOWN_MS: i64 = 180_000;
pub const DEFAULT_CALLS_MARGIN_MS: i64 = 60_000;
/// The longest a cancel waits for the Run to stop before it answers.
const CANCEL_WAIT: Duration = Duration::from_secs(30);
const TASK_MAX_CHARS: usize = 16_000;
const KEY_MAX_CHARS: usize = 128;
/// The receipt's reply: the end of the agent's answer, at most this many characters.
pub const REPLY_MAX_CHARS: usize = 4_000;
const ERROR_MAX_CHARS: usize = 500;
pub const AGENTS: [&str; 4] = ["claude", "codex", "opencode", "pi"];
pub const DEFAULT_AGENT: &str = "codex";
/// A Run's machine is named this and the Run's id, so a cleanup finds it by name.
pub const MACHINE_PREFIX: &str = "sandbox-";
/// The label a lost Run's timeout names.
const PATH: &str = "cloud.runs";
const STORE_VERSION: u32 = 1;

/// One Run's task, as the steps start it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Task {
    pub run: String,
    /// The machine's name ([`MACHINE_PREFIX`] and the Run's id): new, so the start makes it.
    pub machine_name: String,
    pub prompt: String,
    pub agent: String,
    /// The task's own bound: the start and the turn together.
    pub timeout: Duration,
}

/// How the task ended. `machine` is the machine's id when the steps learned it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Replied { reply: String, machine: Option<String> },
    Failed { code: String, message: String, reply: Option<String>, machine: Option<String> },
    TimedOut { machine: Option<String> },
    Cancelled { machine: Option<String> },
}

/// One delete of a Run's machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Removal {
    Deleted,
    /// No machine has the name (or the id).
    Gone,
    /// Not now (the app not running, a refusal): try again later.
    Later(String),
}

/// What a Run does on Cloud. Each call may block for its whole bound; `cancel` set means stop now.
pub trait Steps: Send + Sync {
    fn run(&self, task: &Task, cancel: &AtomicBool) -> Outcome;
    fn remove(&self, machine_name: &str, machine: Option<&str>) -> Removal;
}

/// The engine's pauses and ages.
#[derive(Debug, Clone, Copy)]
pub struct Timing {
    pub retry_first: Duration,
    pub retry_max: Duration,
    /// How long after its end a Run's cleanup keeps being tried.
    pub give_up: Duration,
    /// How long an ended Run is kept for a wait.
    pub keep_ended: Duration,
    /// After a cut-off start: how long past the task's timeout the app may still be making the machine.
    pub start_settle: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Timing {
            retry_first: Duration::from_secs(30),
            retry_max: Duration::from_secs(600),
            give_up: Duration::from_secs(3 * 24 * 60 * 60),
            keep_ended: Duration::from_secs(24 * 60 * 60),
            start_settle: Duration::from_secs(120),
        }
    }
}

/// One Run as the store keeps it (milliseconds since 1970).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
struct Run {
    id: String,
    /// The scope (`team`) and the caller's idempotency key.
    key: String,
    digest: String,
    agent: String,
    timeout_ms: i64,
    machine_name: String,
    machine: Option<String>,
    /// `queued`, `running`, `cancelling`, `succeeded`, `failed` or `cancelled`.
    status: String,
    timed_out: bool,
    reply: Option<String>,
    error: Option<String>,
    exit_code: Option<i64>,
    created_ms: i64,
    updated_ms: i64,
    started_ms: Option<i64>,
    finished_ms: Option<i64>,
    cancel_requested_ms: Option<i64>,
    /// `pending`, `destroyed` or `abandoned` (cleanup given up).
    cleanup: String,
    /// "Gone" counts only from this time on.
    settle_ms: i64,
}

impl Run {
    fn ended(&self) -> bool {
        matches!(self.status.as_str(), "succeeded" | "failed" | "cancelled")
    }
}

#[derive(Serialize, Deserialize)]
struct Stored {
    version: u32,
    runs: Vec<Run>,
}

#[derive(Default)]
struct State {
    runs: HashMap<String, Run>,
    cancels: HashMap<String, Arc<AtomicBool>>,
}

/// The daemon's Runs.
pub struct Engine {
    state: Mutex<State>,
    changed: Condvar,
    steps: Arc<dyn Steps>,
    store: Option<PathBuf>,
    timing: Timing,
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

fn ms(duration: Duration) -> i64 {
    i64::try_from(duration.as_millis()).unwrap_or(i64::MAX)
}

fn iso(ms: Option<i64>) -> Value {
    let Some(ms) = ms else { return Value::Null };
    let secs = ms.div_euclid(1000);
    let millis = ms.rem_euclid(1000);
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    // Civil date from days since 1970 (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    json!(format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{millis:03}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    ))
}

fn refused(status: u16, code: &str, message: &str) -> Failure {
    Failure::http(status, Some(code.to_owned()), Some(message.to_owned()))
}

fn capped(text: &str, max: usize) -> String {
    let count = text.chars().count();
    if count <= max {
        return text.to_owned();
    }
    let tail: String = text.chars().skip(count - (max - 1)).collect();
    format!("…{tail}")
}

/// The agent's answer as a receipt keeps it: no terminal controls (escape sequences, other C0
/// characters but newline and tab), trimmed, and its last [`REPLY_MAX_CHARS`] characters.
pub fn clean_reply(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            '\u{1b}' => match chars.peek() {
                // CSI: parameters and intermediates, then one final byte.
                Some('[') => {
                    chars.next();
                    for c in chars.by_ref() {
                        if ('\u{40}'..='\u{7e}').contains(&c) {
                            break;
                        }
                    }
                }
                // OSC: up to BEL or ST.
                Some(']') => {
                    chars.next();
                    while let Some(c) = chars.next() {
                        if c == '\u{7}' {
                            break;
                        }
                        if c == '\u{1b}' && chars.peek() == Some(&'\\') {
                            chars.next();
                            break;
                        }
                    }
                }
                _ => {
                    chars.next();
                }
            },
            '\n' | '\t' => out.push(ch),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    capped(out.trim(), REPLY_MAX_CHARS)
}

impl Engine {
    /// The Runs `store` keeps (none: in memory only); Runs a former daemon left going end now and
    /// their cleanup starts again.
    pub fn open(store: Option<PathBuf>, steps: Arc<dyn Steps>, timing: Timing) -> Arc<Self> {
        let mut state = State::default();
        let now = now_ms();
        let mut resumed = Vec::new();
        if let Some(runs) = store.as_deref().and_then(load) {
            for mut run in runs {
                if !run.ended() {
                    run.status = "failed".into();
                    run.error = Some("the cmux daemon restarted during the Run".into());
                    run.finished_ms = Some(now);
                    run.updated_ms = now;
                    run.exit_code = None;
                    // The start may still be making the machine.
                    run.settle_ms = run
                        .settle_ms
                        .max(run.created_ms + run.timeout_ms + ms(timing.start_settle));
                }
                if run.cleanup == "pending" {
                    resumed.push(run.id.clone());
                }
                state.runs.insert(run.id.clone(), run);
            }
        }
        let engine = Arc::new(Engine {
            state: Mutex::new(state),
            changed: Condvar::new(),
            steps,
            store,
            timing,
        });
        {
            let mut state = engine.lock();
            engine.prune(&mut state, now);
            engine.save(&state);
        }
        for id in resumed {
            let engine = Arc::clone(&engine);
            let _ = std::thread::Builder::new()
                .name("cloud-run-cleanup".into())
                .spawn(move || engine.clean(&id));
        }
        engine
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// `runs.create|start|wait|cancel|sandbox`.
    pub fn perform(
        self: &Arc<Self>,
        call: &str,
        team: Option<&str>,
        args: &Map<String, Value>,
    ) -> Result<Value, Failure> {
        match call {
            "runs.create" | "runs.start" => self.create(team, args),
            "runs.wait" => {
                let id = id_arg(args)?;
                let held = optional_int(args, "timeoutMs").unwrap_or(WAIT_LIMIT_MS);
                self.wait(
                    id,
                    Duration::from_millis(u64::try_from(held.clamp(0, WAIT_LIMIT_MS)).unwrap_or(0)),
                )
            }
            "runs.cancel" => self.cancel(id_arg(args)?),
            "runs.sandbox" => self.sandbox(team, args),
            other => Err(Failure::Transport(format!("no cloud api call {other:?}"))),
        }
    }

    fn create(
        self: &Arc<Self>,
        team: Option<&str>,
        args: &Map<String, Value>,
    ) -> Result<Value, Failure> {
        let task = optional_text(args, "task").map(str::trim).unwrap_or_default();
        if task.is_empty() || task.chars().count() > TASK_MAX_CHARS {
            return Err(refused(400, "run_task_required", "task: the task, 1 to 16000 characters"));
        }
        let agent = optional_text(args, "agent").filter(|a| !a.is_empty()).unwrap_or(DEFAULT_AGENT);
        if !AGENTS.contains(&agent) {
            return Err(refused(400, "run_agent_invalid", "agent: claude, codex, opencode or pi"));
        }
        let timeout_ms = optional_int(args, "timeoutMs").unwrap_or(DEFAULT_TIMEOUT_MS);
        if !(MIN_TIMEOUT_MS..=MAX_TIMEOUT_MS).contains(&timeout_ms) {
            return Err(refused(400, "run_timeout_invalid", "timeoutMs: 30000 to 720000"));
        }
        if optional_text(args, "image").is_some_and(|image| !image.is_empty()) {
            return Err(refused(
                400,
                "run_image_invalid",
                "image: a NEXT Run starts from the Cloud machine's own image",
            ));
        }
        let key = optional_text(args, "idempotencyKey").unwrap_or_default();
        if key.is_empty() || key.chars().count() > KEY_MAX_CHARS {
            return Err(refused(
                400,
                "run_idempotency_required",
                "idempotencyKey: 1 to 128 characters",
            ));
        }
        let scoped = format!("{}\u{0}{key}", team.unwrap_or_default());
        let digest = hex(&Sha256::digest(
            serde_json::to_vec(&json!([task, agent, timeout_ms])).unwrap_or_default(),
        ));
        let mut state = self.lock();
        if let Some(run) = state.runs.values().find(|run| run.key == scoped) {
            if run.digest != digest {
                return Err(refused(
                    409,
                    "run_idempotency_conflict",
                    "this idempotency key named another Run",
                ));
            }
            return Ok(created(run));
        }
        let id = format!("run_{}", &uuid::Uuid::new_v4().simple().to_string()[..20]);
        let now = now_ms();
        let run = Run {
            id: id.clone(),
            key: scoped,
            digest,
            agent: agent.to_owned(),
            timeout_ms,
            machine_name: format!("{MACHINE_PREFIX}{id}"),
            machine: None,
            status: "queued".into(),
            timed_out: false,
            reply: None,
            error: None,
            exit_code: None,
            created_ms: now,
            updated_ms: now,
            started_ms: None,
            finished_ms: None,
            cancel_requested_ms: None,
            cleanup: "pending".into(),
            settle_ms: now,
        };
        let answer = created(&run);
        let cancel = Arc::new(AtomicBool::new(false));
        state.cancels.insert(id.clone(), Arc::clone(&cancel));
        state.runs.insert(id.clone(), run);
        self.prune(&mut state, now);
        self.save(&state);
        drop(state);
        let engine = Arc::clone(self);
        let prompt = task.to_owned();
        let spawned = std::thread::Builder::new()
            .name("cloud-run".into())
            .spawn(move || engine.drive(&id, prompt, &cancel));
        if spawned.is_err() {
            return Err(Failure::Transport("the Run could not start".into()));
        }
        Ok(answer)
    }

    /// The Run's whole life on its own thread: the task, its end, then the cleanup.
    fn drive(&self, id: &str, prompt: String, cancel: &AtomicBool) {
        let task = {
            let mut state = self.lock();
            let Some(run) = state.runs.get_mut(id) else { return };
            if cancel.load(Ordering::Acquire) {
                None
            } else {
                run.status = "running".into();
                run.started_ms = Some(now_ms());
                run.updated_ms = now_ms();
                let task = Task {
                    run: run.id.clone(),
                    machine_name: run.machine_name.clone(),
                    prompt,
                    agent: run.agent.clone(),
                    timeout: Duration::from_millis(u64::try_from(run.timeout_ms).unwrap_or(0)),
                };
                self.save(&state);
                self.changed.notify_all();
                Some(task)
            }
        };
        let outcome = match &task {
            Some(task) => self.steps.run(task, cancel),
            None => Outcome::Cancelled { machine: None },
        };
        // A cancel that came while the task ran is a cancel, whatever the steps said.
        let outcome = if cancel.load(Ordering::Acquire) {
            match outcome {
                Outcome::Replied { machine, .. }
                | Outcome::Failed { machine, .. }
                | Outcome::TimedOut { machine }
                | Outcome::Cancelled { machine } => Outcome::Cancelled { machine },
            }
        } else {
            outcome
        };
        self.finish(id, outcome);
        self.clean(id);
    }

    fn finish(&self, id: &str, outcome: Outcome) {
        let mut state = self.lock();
        state.cancels.remove(id);
        let timing = self.timing;
        let Some(run) = state.runs.get_mut(id) else { return };
        let now = now_ms();
        let (status, machine, cut) = match outcome {
            Outcome::Replied { reply, machine } => {
                run.reply = Some(clean_reply(&reply));
                run.exit_code = Some(0);
                ("succeeded", machine, false)
            }
            Outcome::Failed { code, message, reply, machine } => {
                run.reply = reply.map(|r| clean_reply(&r));
                run.error =
                    Some(capped(&clean_reply(&format!("{code}: {message}")), ERROR_MAX_CHARS));
                run.exit_code = Some(1);
                ("failed", machine, false)
            }
            Outcome::TimedOut { machine } => {
                run.timed_out = true;
                run.error = Some("the task did not end by its timeout".into());
                ("failed", machine, true)
            }
            Outcome::Cancelled { machine } => ("cancelled", machine, true),
        };
        run.status = status.into();
        if machine.is_some() {
            run.machine = machine;
        }
        run.finished_ms = Some(now);
        run.updated_ms = now;
        // A start cut off may still be making the machine: a list without it is not proof until then.
        if cut {
            run.settle_ms = run.created_ms + run.timeout_ms + ms(timing.start_settle);
        }
        self.save(&state);
        self.changed.notify_all();
    }

    /// Deletes the Run's machine until it is deleted or confirmed gone, or until the cleanup is given up.
    fn clean(&self, id: &str) {
        let mut pause = self.timing.retry_first;
        loop {
            let (name, machine, settle, finished) = {
                let state = self.lock();
                let Some(run) = state.runs.get(id) else { return };
                if run.cleanup != "pending" {
                    return;
                }
                (run.machine_name.clone(), run.machine.clone(), run.settle_ms, run.finished_ms)
            };
            let removal = self.steps.remove(&name, machine.as_deref());
            let now = now_ms();
            let done = matches!(removal, Removal::Deleted | Removal::Gone) && now >= settle;
            let given_up = finished.is_some_and(|at| now - at >= ms(self.timing.give_up));
            if done || given_up {
                let mut state = self.lock();
                if let Some(run) = state.runs.get_mut(id) {
                    run.cleanup = if done { "destroyed" } else { "abandoned" }.into();
                    run.updated_ms = now;
                }
                self.prune(&mut state, now);
                self.save(&state);
                self.changed.notify_all();
                return;
            }
            let wait = match removal {
                // Deleted or gone, before the settle time: read again then.
                Removal::Deleted | Removal::Gone => {
                    Duration::from_millis(u64::try_from(settle - now).unwrap_or(0))
                        .min(self.timing.retry_max)
                }
                Removal::Later(_) => {
                    let wait = pause;
                    pause = (pause * 2).min(self.timing.retry_max);
                    wait
                }
            };
            std::thread::sleep(wait.max(Duration::from_millis(1)));
        }
    }

    fn wait(&self, id: &str, held: Duration) -> Result<Value, Failure> {
        let deadline = Instant::now() + held;
        let mut state = self.lock();
        loop {
            let run = state.runs.get(id).ok_or_else(not_found)?;
            if run.ended() {
                return Ok(snapshot(run));
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Ok(snapshot(run));
            }
            state = self
                .changed
                .wait_timeout(state, left)
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .0;
        }
    }

    fn cancel(&self, id: &str) -> Result<Value, Failure> {
        {
            let mut state = self.lock();
            let flag = state.cancels.get(id).cloned();
            let run = state.runs.get_mut(id).ok_or_else(not_found)?;
            if run.ended() {
                return Ok(snapshot(run));
            }
            if let Some(flag) = flag {
                flag.store(true, Ordering::Release);
            }
            run.status = "cancelling".into();
            run.cancel_requested_ms = Some(now_ms());
            run.updated_ms = now_ms();
            self.save(&state);
            self.changed.notify_all();
        }
        self.wait(id, CANCEL_WAIT)
    }

    fn sandbox(
        self: &Arc<Self>,
        team: Option<&str>,
        args: &Map<String, Value>,
    ) -> Result<Value, Failure> {
        let timeout_ms = optional_int(args, "timeoutMs").unwrap_or(DEFAULT_TIMEOUT_MS);
        let teardown = optional_int(args, "teardownMs").unwrap_or(DEFAULT_TEARDOWN_MS);
        let margin = optional_int(args, "callsMarginMs").unwrap_or(DEFAULT_CALLS_MARGIN_MS);
        let created = self.create(team, args)?;
        let id = created["id"].as_str().unwrap_or_default().to_owned();
        let bound = timeout_ms.max(0).saturating_add(teardown.max(0)).saturating_add(margin.max(0));
        let deadline = Instant::now() + Duration::from_millis(u64::try_from(bound).unwrap_or(0));
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(Failure::TimedOut(format!("{PATH}/{id}")));
            }
            let snapshot = self.wait(&id, left.min(Duration::from_millis(10_000)))?;
            if snapshot["receipt"].is_object() {
                return Ok(snapshot);
            }
        }
    }

    /// Drops ended Runs past [`Timing::keep_ended`] whose cleanup is over.
    fn prune(&self, state: &mut State, now: i64) {
        let keep = ms(self.timing.keep_ended);
        state.runs.retain(|_, run| {
            !(run.ended()
                && run.cleanup != "pending"
                && run.finished_ms.is_some_and(|at| now - at > keep))
        });
    }

    fn save(&self, state: &State) {
        let Some(path) = &self.store else { return };
        let mut runs: Vec<Run> = state.runs.values().cloned().collect();
        runs.sort_by(|a, b| a.created_ms.cmp(&b.created_ms).then_with(|| a.id.cmp(&b.id)));
        let Ok(bytes) = serde_json::to_vec(&Stored { version: STORE_VERSION, runs }) else {
            return;
        };
        let _ = write_private(path, &bytes);
    }
}

fn id_arg(args: &Map<String, Value>) -> Result<&str, Failure> {
    optional_text(args, "id")
        .filter(|id| !id.is_empty())
        .ok_or_else(|| Failure::Transport("the call needs id".into()))
}

fn not_found() -> Failure {
    refused(404, "run_not_found", "no such Run on this Mac")
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn load(path: &Path) -> Option<Vec<Run>> {
    let bytes = std::fs::read(path).ok()?;
    let stored: Stored = serde_json::from_slice(&bytes).ok()?;
    (stored.version == STORE_VERSION).then_some(stored.runs)
}

/// Writes `bytes` to `path` whole (a temporary file renamed over it), readable by its owner only.
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(dir)?;
    let mut file = tempfile::NamedTempFile::new_in(dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        file.as_file().set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    file.write_all(bytes)?;
    file.as_file().sync_all()?;
    file.persist(path).map_err(|e| e.error)?;
    Ok(())
}

fn attempt_status(run: &Run) -> &'static str {
    match run.status.as_str() {
        "queued" => "queued",
        "running" | "cancelling" => "running",
        "succeeded" => "succeeded",
        "cancelled" => "cancelled",
        _ if run.timed_out => "expired",
        _ => "failed",
    }
}

fn attempt_id(run: &Run) -> String {
    format!("{}_a1", run.id)
}

/// The create's answer.
fn created(run: &Run) -> Value {
    json!({
        "id": run.id,
        "status": run.status,
        "attempts": [{ "id": attempt_id(run), "ordinal": 1, "status": attempt_status(run) }],
        "createdAt": iso(Some(run.created_ms)),
        "environment": "sandboxed",
        "image": null,
    })
}

/// A wait's answer: `{run, attempts, artifacts, receipt}`; the receipt once the Run ended.
fn snapshot(run: &Run) -> Value {
    let receipt = run.ended().then(|| {
        let total = run.finished_ms.map(|end| end - run.created_ms);
        let ran = run.finished_ms.zip(run.started_ms).map(|(end, start)| end - start);
        json!({
            "schema": "cmux.run.receipt/v1",
            "runId": run.id,
            "environment": "sandboxed",
            "status": run.status,
            "image": null,
            "exitCode": run.exit_code,
            "signal": null,
            "timedOut": run.timed_out,
            "reply": run.reply,
            "error": run.error,
            "artifacts": [],
            "timings": {
                "createdAt": iso(Some(run.created_ms)),
                "startedAt": iso(run.started_ms),
                "finishedAt": iso(run.finished_ms),
                "bootMs": null,
                "runMs": ran,
                "totalMs": total,
            },
            "cost": null,
            "cleanup": if run.cleanup == "destroyed" { "destroyed" } else { "pending" },
        })
    });
    json!({
        "run": {
            "id": run.id,
            "status": run.status,
            "environment": "sandboxed",
            "image": null,
            "executionProvider": "cloud-machine",
            "error": run.error,
            "cancelRequestedAt": iso(run.cancel_requested_ms),
            "completedAt": iso(run.finished_ms),
            "createdAt": iso(Some(run.created_ms)),
            "updatedAt": iso(Some(run.updated_ms)),
        },
        "attempts": [{
            "id": attempt_id(run),
            "ordinal": 1,
            "status": attempt_status(run),
            "attachable": false,
            "exitCode": run.exit_code,
            "error": run.error,
            "startedAt": iso(run.started_ms),
            "finishedAt": iso(run.finished_ms),
            "createdAt": iso(Some(run.created_ms)),
            "updatedAt": iso(Some(run.updated_ms)),
        }],
        "artifacts": [],
        "receipt": receipt.unwrap_or(Value::Null),
    })
}

#[cfg(test)]
#[path = "sandbox_tests.rs"]
mod tests;
