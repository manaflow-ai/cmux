//! `cmux chat --on cloud|vm|vm:new` as a hybrid start (Leo, 2026-11-23: "we don't have to wait
//! for cloud machines to be up and running before we start a model ... start them all in
//! parallel, in tandem"). When [`hybrid::enabled`] says so, the chat starts here at once, as
//! `cmux chat` does with no `--on`, and a detached driver (`cmux cloud hybrid-drive`) readies its
//! Cloud machine meanwhile. Once the machine is up and the chat is between turns, the driver moves
//! it there with the app's own Move to Cloud. Every decision is cmux-cloud-start-core's
//! [`hybrid::step`]; this file only runs its effects.
//!
//! On for a Pro plan, `CMUX_HYBRID_START=1`, or cmux-next.json `cloud.autoCloud: true` with no env.
//! Off (no Pro plan, `CMUX_HYBRID_START=0`, `hybrid-chat-start` disabled, signed out, or no agent
//! here the chat could start with: [`local_harness`]), or a start the chat here cannot take
//! ([`takes`]), the Cloud start runs exactly as before.
//!
//! What the driver feeds [`hybrid::step`]: `TurnStarted` and `TurnEnded` from acpmux's own
//! `_acpmux/wait` (`running`, then `ready`), and `ToolStarted`/`ToolEnded` from the chat's updates
//! ([`tool_event`]), so a move is due between turns or between tool calls. The machine: `cmux vm new --wait`'s create and wait ([`vm_ready::new_and_wait`]), or for
//! an existing machine a resume and the same wait ([`vm_ready::wait_until_ready`]).
//!
//! Each Show also sets the chat's acpmux tags to the stage and machine
//! ([`hybrid_tools::STAGE_TAG`], [`hybrid_tools::MACHINE_TAG`]): acpmux holds the chat's tool calls
//! while the machine boots and runs them there once it is ready (acpmux `hub/hybrid_hold.rs`),
//! each one the same call, longer (Leo, 2026-11-23: "It's like an extended tool call"). The
//! drive's end sets the stage to its last (`none` when the chat stays here), so no call waits on
//! a driver that is gone.

use std::collections::VecDeque;
use std::io::Write as _;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use cmux_cloud_start_core::hybrid::{
    self, Account, AutoStore, Cloud, Effect, Event, Off, Refusal, State,
};
use cmux_cloud_start_core::{hybrid_show, hybrid_tools};
use serde_json::{Value, json};

use super::super::agents::chat;
use super::super::cloud_start_chat::{self, Machine, Runner, step_result};
use super::super::{GlobalArgs, OutputMode, vm_ready};
use super::Start;

/// The hidden verb the start spawns: `cmux cloud hybrid-drive ID new|MACHINE`. The chat and its
/// target are plain words: `--session` and `--machine` are globals that name a daemon, and the
/// global parser takes them before the verb sees them.
pub(in crate::cli) const DRIVE_VERB: &str = "hybrid-drive";
/// The hidden verb the nightly read-back runs: `cmux cloud hybrid-status`, `{enabled, off, ...}`.
pub(in crate::cli) const STATUS_VERB: &str = "hybrid-status";
/// The hidden verb the app runs once its Cloud send's first turn started here
/// (cmux-cloud-start-core `hybrid_gui`): `cmux cloud hybrid-begin ID new|MACHINE`, the same
/// driver a `cmux chat --on cloud` start spawns, detached; it prints `{log}`.
pub(in crate::cli) const BEGIN_VERB: &str = "hybrid-begin";
/// How long a driver runs at most: the machine's own wait (`vm new --wait`, 20 min) and a move
/// (the app's 20 min) fit. Past it the chat stays here.
const DRIVE_DEADLINE: Duration = Duration::from_secs(60 * 60);
/// One `_acpmux/wait` of the turn watcher; a wait that ends with no change is made again.
const TURN_SLICE: Duration = Duration::from_secs(10 * 60);
/// The plan's read on the start path (`billing.status`, a network call in the app).
const PLAN_TIMEOUT: Duration = Duration::from_secs(5);
/// How old a cached plan that grants the hybrid start may be and still decide it. The driver reads
/// the plan again after each start, so this bounds only a plan that changed with no start since.
const PLAN_CACHE_AGE: Duration = Duration::from_secs(7 * 24 * 60 * 60);
/// How long a driver past its deadline still waits for a machine on its way, to pause it: the
/// machine start's own waits end well before this.
const MACHINE_GRACE: Duration = Duration::from_secs(30 * 60);

/// The driver's `--machine` word for a Cloud route a chat here can stand in for: `new`, or the
/// machine's id. None: the Cloud start runs as before (a named machine, `--environment`,
/// `--from-folder`, `--no-folder`, `--cwd` on the machine, `--wait`, `--timeout`, `--timings`,
/// `--name`, `--attach`, no prompt: each is the Cloud start's own, or its refusal).
pub(super) fn takes(start: &Start, machine: &Machine) -> Option<String> {
    let plain = start.prompt.is_some()
        && start.environment.is_none()
        && start.from_folder.is_none()
        && !start.no_folder
        && start.cwd.is_none()
        && start.repo.is_none()
        && start.name.is_none()
        && start.attach.is_empty()
        && !start.wait
        && start.timeout.is_none()
        && !start.allow_large
        && !start.timings;
    match machine {
        _ if !plain => None,
        Machine::New => Some("new".to_owned()),
        Machine::Target(id) => Some(id.clone()),
        Machine::Named(_) => None,
    }
}

/// The plan id in a `cloud.plan.get` answer (`/v1/read` answers `{value}`; the plan is its
/// `plan_id`): `plan_id`, `planId` or `id`, at the top, under `value` or under `plan`, or `plan`
/// itself as text.
pub(super) fn plan_of(answer: &Value) -> Option<String> {
    let answer = answer.get("value").filter(|value| value.is_object()).unwrap_or(answer);
    let inner = answer.get("plan");
    [answer, inner.unwrap_or(&Value::Null)]
        .iter()
        .flat_map(|value| [value.get("plan_id"), value.get("planId"), value.get("id")])
        .flatten()
        .chain(inner.filter(|plan| plan.is_string()))
        .find_map(Value::as_str)
        .map(str::to_owned)
}

/// [`hybrid::Account`] from what the Cloud start already reads: the flag
/// ([`crate::feature_flags::hybrid_chat_start_flag`]), `cloud list-machines` (signed in; a
/// `cloud_disabled` refusal), and the plan, read only when no flag decides.
pub(super) fn account(
    flag: Option<bool>,
    listed: Result<Value, Value>,
    plan: impl FnOnce() -> Option<String>,
) -> Account {
    let code = listed.as_ref().err().and_then(|error| error.get("code")).and_then(Value::as_str);
    Account {
        plan: if flag.is_none() { plan() } else { None },
        flag,
        cloud_disabled: code.is_some_and(|code| code.contains("cloud_disabled")),
        signed_in: listed
            .as_ref()
            .is_ok_and(|listed| listed.pointer("/account/signed_in") != Some(&Value::Bool(false))),
    }
}

fn flag() -> Option<bool> {
    crate::feature_flags::hybrid_chat_start_flag(
        &|name| std::env::var(name).ok(),
        &crate::feature_flags::disables,
        &cmux_tui_core::user_settings::auto_cloud,
    )
}

/// The team's plan: `cloud.plan.get` (the team's grant, from its billing owner; never `account.me`,
/// the person's own plan), read with a token the app mints for its current team. None when either
/// read fails: the start stays the Cloud one.
fn read_plan() -> Option<String> {
    let token = super::super::auth_token::app_token_in(None).ok()?;
    let platform =
        super::super::Platform::new(token.api_origin, token.token.to_string(), PLAN_TIMEOUT)
            .ok()?
            .with_team(Some(token.team));
    let answer = platform.post("/v1/read", json!({"op": "cloud.plan.get", "params": {}})).ok()?;
    plan_of(&answer)
}

fn account_of(global: &GlobalArgs, flag: Option<bool>) -> Account {
    account(flag, cloud_start_chat::app_machines(global), read_plan)
}

/// The plan cache: the last plan `cloud.plan.get` answered and when (`{plan, read_at_ms}`, Unix
/// milliseconds), so a start decides with no network read in front of the chat.
fn plan_cache() -> Result<PathBuf, String> {
    Ok(root()?.join("plan.json"))
}

fn unix_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| u64::try_from(since.as_millis()).unwrap_or(u64::MAX))
}

/// The cached plan when it grants the hybrid start and is fresh at `now_ms`. A cached plan that
/// does not grant it decides nothing: the start reads the plan again (a plan just bought counts).
pub(super) fn cached_plan(cache: &Value, now_ms: u64) -> Option<String> {
    let read_at = cache.get("read_at_ms").and_then(Value::as_u64)?;
    let fresh = now_ms.saturating_sub(read_at) <= PLAN_CACHE_AGE.as_millis() as u64;
    let plan = cache.get("plan").and_then(Value::as_str)?;
    (fresh && read_at <= now_ms && hybrid::PLANS.contains(&plan)).then(|| plan.to_owned())
}

fn read_cached_plan() -> Option<String> {
    let text = std::fs::read_to_string(plan_cache().ok()?).ok()?;
    cached_plan(&serde_json::from_str(&text).ok()?, unix_ms())
}

/// Reads the plan and keeps it in the cache (written whole, then renamed). None: unread.
fn refresh_plan() -> Option<String> {
    let plan = read_plan()?;
    if let Ok(path) = plan_cache() {
        let line = json!({"plan": plan, "read_at_ms": unix_ms()}).to_string();
        let staged = path.with_extension(format!("json.{}", std::process::id()));
        let wrote = path.parent().is_some_and(|parent| std::fs::create_dir_all(parent).is_ok())
            && std::fs::write(&staged, line).is_ok();
        if !wrote || std::fs::rename(&staged, &path).is_err() {
            let _ = std::fs::remove_file(&staged);
        }
    }
    Some(plan)
}

/// The account as a start reads it now: the flag, else the plan (cached when fresh).
pub(super) fn account_now(global: &GlobalArgs) -> Account {
    account_for_start(global, flag())
}

/// [`account_of`] for a start: the cached plan when it grants it, else the plan read beside the
/// machine list (both bounded as before), never one after the other.
fn account_for_start(global: &GlobalArgs, flag: Option<bool>) -> Account {
    let cached = if flag.is_none() { read_cached_plan() } else { None };
    if cached.is_some() || flag.is_some() {
        return account(flag, cloud_start_chat::app_machines(global), || cached);
    }
    std::thread::scope(|scope| {
        let plan = scope.spawn(refresh_plan);
        let listed = cloud_start_chat::app_machines(global);
        account(flag, listed, || plan.join().ok().flatten())
    })
}

/// Whether this machine's acpmux can start the chat's agent (cmux-cloud-start-core, shared with
/// the app's Cloud send).
pub(super) use cmux_cloud_start_core::hybrid_gui::local_harness;

/// How long the start waits for the local acpmux's harness catalog: it answers from memory
/// (milliseconds); only a daemon still reading its login shell takes longer.
const HARNESS_TIMEOUT: Duration = Duration::from_secs(3);

/// [`local_harness`] for `named`, asked of the acpmux the chat here would start in (the app's own,
/// else the one `cmux acp` reaches), and what asking cost in ms.
fn local_harness_of(global: &GlobalArgs, named: Option<&str>) -> (Result<(), Off>, u64) {
    let asked = Instant::now();
    let socket = chat::app_acpmux(global);
    let catalog = chat::acp::harnesses(socket.as_deref(), HARNESS_TIMEOUT).ok();
    let decided = local_harness(catalog.as_ref(), named);
    (decided, u64::try_from(asked.elapsed().as_millis()).unwrap_or(u64::MAX))
}

/// The hybrid start of a Cloud route, when it is on and takes this start: its exit code. None: the
/// Cloud start runs as before. A flag that says off reads nothing. The local harness is asked
/// beside the account, never after it.
pub(super) fn start(global: &GlobalArgs, start: &Start, machine: &Machine) -> Option<i32> {
    let target = takes(start, machine)?;
    let flag = flag();
    if flag == Some(false) {
        return None;
    }
    let gate = Instant::now();
    let (account, (local, harness_ms)) = std::thread::scope(|scope| {
        let local = scope.spawn(|| local_harness_of(global, start.agent.as_deref()));
        let account = account_for_start(global, flag);
        (account, local.join().unwrap_or((Err(Off::NoLocalHarness), 0)))
    });
    let gate_ms = u64::try_from(gate.elapsed().as_millis()).unwrap_or(u64::MAX);
    // Off for want of a local harness: the Cloud start, as before, says nothing new
    // (`cmux cloud hybrid-status` says why and what asking cost).
    hybrid::enabled(&account).and(local).ok()?;
    Some(begin(global, start, &target, gate_ms, harness_ms))
}

/// The chat here, in a fresh empty folder (a Cloud chat with no folder starts in one), then the
/// driver beside it.
fn begin(global: &GlobalArgs, start: &Start, target: &str, gate_ms: u64, harness_ms: u64) -> i32 {
    let here = match fresh_folder() {
        Ok(folder) => here_of(start, &folder.display().to_string()),
        Err(error) => {
            let error = json!({"code": "hybrid.folder", "message": error, "details": {},
                               "retryable": true});
            return super::super::wire::print_local_error(&error, global.output, 1);
        }
    };
    let words = match super::here_words(&super::global_words(global), &here) {
        Ok(words) => words,
        Err(error) => return super::usage_failure(&error, global.output),
    };
    let code = super::super::agents::run_if_requested(&words).unwrap_or(2);
    if code != 0 {
        return code;
    }
    let Some(started) = chat::last_started() else { return code };
    let said = match spawn(global, &started.id, target, gate_ms, harness_ms) {
        Ok(log) => format!(
            "cmux: the chat runs here while its Cloud machine starts; it moves there between \
             turns (log: {})",
            log.display()
        ),
        Err(error) => {
            format!("cmux: the chat stays here: its Cloud machine was not started ({error})")
        }
    };
    if global.output == OutputMode::Human {
        eprintln!("{said}");
    }
    code
}

/// The chat here a hybrid start runs: the same start with no target, in `folder`.
pub(super) fn here_of(start: &Start, folder: &str) -> Start {
    Start { on: None, cwd: Some(folder.to_owned()), ..start.clone() }
}

/// The words of the driver for `session` on `target` (`new` or a machine id), after the globals
/// that reach the same app and daemon.
/// `gate_ms`: what deciding the start cost, for the driver's log.
pub(super) fn drive_words(
    global: &GlobalArgs,
    session: &str,
    target: &str,
    gate_ms: u64,
) -> Vec<String> {
    let mut words = cloud_start_chat::forwarded_globals(global);
    let gate = gate_ms.to_string();
    words.extend(["cloud", DRIVE_VERB, session, target, "--gate-ms", &gate].map(str::to_owned));
    words
}

fn sessions_dir() -> Result<PathBuf, String> {
    cmux_tui_core::platform::workspace_state_dir().ok_or_else(|| "no state folder".to_owned())
}

fn root() -> Result<PathBuf, String> {
    Ok(hybrid_show::folder(&sessions_dir()?))
}

fn fresh_folder() -> Result<PathBuf, String> {
    let folder = root()?.join("folders").join(cloud_start_chat::fresh_machine_name());
    std::fs::create_dir_all(&folder).map_err(|error| format!("{}: {error}", folder.display()))?;
    Ok(folder)
}

/// The driver's log: its `Log` lines and `Show` states, one per line ([`hybrid_show::log_file`]).
fn log_path(session: &str) -> Result<PathBuf, String> {
    Ok(hybrid_show::log_file(&sessions_dir()?, session))
}

/// Replaces the session's `.show` file with `line` by a rename: the change the app's watch on the
/// folder wakes on to read the start again ([`hybrid_show`]). A failure costs only that wake.
fn signal_show(session: &str, line: &str) -> Result<(), String> {
    let path = hybrid_show::show_file(&sessions_dir()?, session);
    let next = path.with_extension("show.next");
    std::fs::write(&next, format!("{line}\n")).map_err(|error| error.to_string())?;
    std::fs::rename(&next, &path).map_err(|error| error.to_string())
}

fn spawn(
    global: &GlobalArgs,
    session: &str,
    target: &str,
    gate_ms: u64,
    harness_ms: u64,
) -> Result<PathBuf, String> {
    let path = log_path(session)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let mut log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .map_err(|error| error.to_string())?;
    // What asking the local acpmux for its harnesses cost, inside the gate (side by side with the
    // account read), first in the driver's log.
    let _ = writeln!(log, "{}", json!({"harness_ms": harness_ms}));
    let err = log.try_clone().map_err(|error| error.to_string())?;
    let exe = std::env::current_exe().map_err(|error| error.to_string())?;
    let mut child = cmux_process::Command::new(exe)
        .args(drive_words(global, session, target, gate_ms))
        .stdin(cmux_process::Stdio::null())
        .stdout(log)
        .stderr(err)
        .process_group(0)
        .spawn()
        .map_err(|error| error.to_string())?;
    child.detach("the hybrid start's driver outlives the `cmux chat` that started it");
    Ok(path)
}

/// What the driver runs, so the loop is tested with fakes.
pub(super) trait Drive {
    /// Milliseconds since the driver began, monotonic.
    fn now_ms(&mut self) -> u64;
    /// Starts the machine's create or resume; it answers `MachineReady` or `MachineFailed`
    /// through [`Drive::next`].
    fn create_machine(&mut self);
    /// The next event: the machine's, or the chat's turn starting, ending or its chat closing
    /// (`Stop`). None: the driver's deadline passed.
    fn next(&mut self) -> Option<Event>;
    /// The move: Ok when the chat runs on the machine, else why and whether to try again.
    fn move_chat(&mut self) -> Result<(), (String, bool)>;
    /// What the Auto store can do for this chat, read once at the drive's start
    /// ([`hybrid::route`]): absent, the transfer above is the move.
    fn auto_store(&mut self) -> AutoStore;
    /// One planned holder change `device -> vm` asked of the Auto store: its answer, as
    /// [`Event::HolderGiven`], [`Event::HolderRefused`] or [`Event::HolderLost`].
    fn ask_holder_move(&mut self) -> Event;
    fn pause_machine(&mut self);
    fn show(&mut self, cloud: Cloud, reason: Option<&str>);
    fn log(&mut self, line: &str);
}

/// Whether the drive is over: the chat lives on the machine, stays here for good, or was stopped
/// with no machine still on its way (one that comes is paused first).
fn done(state: &State) -> bool {
    matches!(state.cloud, Cloud::Live | Cloud::Failed)
        || (state.stopped && state.cloud != Cloud::Booting)
}

/// The driver's loop: each event through [`hybrid::step`], each effect run. The chat here was
/// started with its first prompt, so its turn runs. Its last state.
pub(super) fn drive(driver: &mut dyn Drive) -> State {
    let mut state = State { route: hybrid::route(&driver.auto_store()), ..State::default() };
    let mut queue = VecDeque::from([Event::Begin, Event::TurnStarted]);
    loop {
        let event = match queue.pop_front() {
            Some(event) => event,
            None if done(&state) => return state,
            None => match driver.next() {
                Some(event) => event,
                None if state.stopped => return state,
                None => Event::Stop,
            },
        };
        let answer = hybrid::step(state, event, driver.now_ms());
        state = answer.state;
        let (mut moving, mut asking) = (false, false);
        for effect in answer.effects {
            match effect {
                // The chat already started here; prompts go to the chat itself, which acpmux
                // holds while it moves, so none passes through the driver.
                Effect::StartHere | Effect::Deliver { .. } | Effect::Hold { .. } => {}
                Effect::CreateMachine => driver.create_machine(),
                // Run once this answer's effects are (its `Show moving` first).
                Effect::Move => moving = true,
                Effect::AskHolderMove => asking = true,
                Effect::PauseMachine => driver.pause_machine(),
                Effect::Show { cloud, reason } => driver.show(cloud, reason.as_deref()),
                Effect::Log { line } => driver.log(&line),
            }
        }
        if moving {
            queue.push_back(match driver.move_chat() {
                Ok(()) => Event::MoveCommitted,
                Err((reason, again)) => Event::MoveFailed { reason, again },
            });
        }
        if asking {
            queue.push_back(driver.ask_holder_move());
        }
    }
}

/// The app's Move to Cloud of `session` onto `machine`, as `cmux move` runs it (agent_move_cloud.rs):
/// it finds the chat's tab, runs the move and waits until the app shows the chat there. No
/// `--interrupt`: the driver moves only at a boundary (between turns, or between tool calls).
pub(super) fn move_words(session: &str, machine: &str) -> Vec<String> {
    ["move", session, "--to", &format!("vm:{machine}"), "--json"].map(str::to_owned).to_vec()
}

/// The one move the driver runs: the chat onto `machine`, at the boundary the driver chose (the
/// turn's end, or between tool calls; the app's move cuts there and continues the turn on the
/// machine). Ok when the chat runs there, else why and whether to try again. The one place a
/// silent carry or a lazy history read changes how the chat moves (cmux#52209: a 62 MB move is
/// about 3 s on loopback, and a mid-turn move writes one continuation prompt today).
fn move_once(global: &GlobalArgs, session: &str, machine: &str) -> Result<(), (String, bool)> {
    let mut runner = cloud_start_chat::SelfRunner::new(global);
    move_outcome(step_result(&runner.cmux(&move_words(session, machine))))
}

/// What the driver makes of the move's answer: why it failed (the app's own reason, as a move
/// refused for the owner's login names its step and cause) and whether to try again.
pub(super) fn move_outcome(answer: Result<Value, Value>) -> Result<(), (String, bool)> {
    let error = answer.err();
    error.map_or(Ok(()), |error| {
        let again = error.get("retryable").and_then(Value::as_bool) == Some(true);
        Err((reason_of(&error), again))
    })
}

/// The pause of a machine whose chat stayed here.
pub(super) fn pause_words(machine: &str) -> Vec<String> {
    ["cloud", "pause-machine", "--target", &format!("machine:{machine}"), "--json"]
        .map(str::to_owned)
        .to_vec()
}

enum Msg {
    Event(Event),
    Machine(Result<String, String>),
}

struct Live {
    global: GlobalArgs,
    session: String,
    target: String,
    machine: Option<String>,
    began: Instant,
    deadline: Instant,
    /// The app's acpmux, where the chat runs and its tags live.
    socket: Option<PathBuf>,
    send: mpsc::Sender<Msg>,
    events: mpsc::Receiver<Msg>,
    /// The turn watcher and the machine's start: this driver owns them, and they end with its
    /// process (the drive's own deadline bounds it).
    threads: Vec<std::thread::JoinHandle<()>>,
    /// The machine's start is under way: no answer from it yet.
    pending: bool,
}

fn reason_of(error: &Value) -> String {
    error.get("message").and_then(Value::as_str).map_or_else(|| error.to_string(), str::to_owned)
}

/// The machine for `target`: a new one through `vm new --wait`'s own create and wait, or an
/// existing one resumed (when it is not running) and waited on the same way.
fn ready_machine(runner: &mut dyn Runner, target: &str) -> Result<String, Value> {
    let ready = if target == "new" {
        let tail = ["--wait".to_owned()];
        let request = vm_ready::parse(&tail, vm_ready::fresh_vm_name)
            .unwrap_or_else(|| Err("no wait".to_owned()))
            .map_err(|error| json!({"message": error}))?;
        vm_ready::new_and_wait(runner, &request)?
    } else {
        let listed = step_result(&runner.cmux(&words(&["cloud", "list-machines", "--json"])))?;
        let running = listed.get("machines").and_then(Value::as_array).is_some_and(|rows| {
            rows.iter().any(|row| {
                row.get("machine_id").and_then(Value::as_str) == Some(target)
                    && row.get("status").and_then(Value::as_str) == Some("running")
            })
        });
        if !running {
            let target = format!("machine:{target}");
            step_result(&runner.cmux(&words(&[
                "cloud",
                "resume-machine",
                "--target",
                &target,
                "--json",
            ])))?;
        }
        let started = runner.now();
        vm_ready::wait_until_ready(
            runner,
            vm_ready::Ready {
                id: Some(target.to_owned()),
                name: target,
                configured: false,
                started,
                timeout: vm_ready::DEFAULT_TIMEOUT,
                created: &Value::Null,
                replaces: None,
            },
        )?
    };
    ready
        .get("machine_id")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| json!({"message": "the machine's answer names no machine_id"}))
}

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

/// The turn watcher: `TurnEnded` when the chat's turn ends, `TurnStarted` when the next one
/// starts, `Stop` when the chat closes or cannot be read; each one acpmux wait.
fn watch_turns(session: String, socket: Option<PathBuf>, send: mpsc::Sender<Msg>) {
    let mut until = ["ready", "closed"];
    loop {
        let answer = match chat::acp::wait_until(&session, &until, TURN_SLICE, socket.as_deref()) {
            Ok(answer) => answer,
            Err(_) => {
                let _ = send.send(Msg::Event(Event::Stop));
                return;
            }
        };
        if answer.get("timedOut").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let row = answer
            .pointer("/resolved/0")
            .or_else(|| answer.pointer("/sessions/0"))
            .unwrap_or(&Value::Null);
        let closed = row.get("missing") == Some(&Value::Bool(true))
            || matches!(
                row.get("status").and_then(Value::as_str),
                Some("closed" | "disconnected" | "failed")
            );
        let event = match until[0] {
            _ if closed => Event::Stop,
            "ready" => Event::TurnEnded,
            _ => Event::TurnStarted,
        };
        let stop = event == Event::Stop;
        if send.send(Msg::Event(event)).is_err() || stop {
            return;
        }
        until[0] = if until[0] == "ready" { "running" } else { "ready" };
    }
}

/// The tool event a `session/update` is, with `open` the tool calls still running: a new
/// `tool_call` starts one, a `tool_call_update` that is `completed` or `failed` ends it. A call
/// seen twice, or an end of one never seen, is no event.
pub(super) fn tool_event(
    update: &Value,
    open: &mut std::collections::BTreeSet<String>,
) -> Option<Event> {
    let update = update.get("update").unwrap_or(update);
    let id = update.get("toolCallId").and_then(Value::as_str)?;
    let status = update.get("status").and_then(Value::as_str);
    let ended = matches!(status, Some("completed" | "failed"));
    match update.get("sessionUpdate").and_then(Value::as_str)? {
        "tool_call" if ended => None,
        "tool_call" => open.insert(id.to_owned()).then_some(Event::ToolStarted),
        "tool_call_update" if ended => open.remove(id).then_some(Event::ToolEnded),
        _ => None,
    }
}

/// Feeds the chat's tool calls to the driver until its deadline, so a long turn can move at a tool
/// boundary. A failed follow feeds none: the move waits for the turn's end, as before.
fn watch_tools(session: String, socket: Option<PathBuf>, send: mpsc::Sender<Msg>, until: Instant) {
    let mut open = std::collections::BTreeSet::new();
    let followed = chat::acp::follow_updates(&session, socket.as_deref(), until, |update| {
        tool_event(update, &mut open).is_none_or(|event| send.send(Msg::Event(event)).is_ok())
    });
    if let Err(error) = followed {
        println!("{}", json!({"log": format!("no tool events: {error}")}));
    }
}

impl Live {
    fn new(global: &GlobalArgs, session: &str, target: &str) -> Self {
        let (send, events) = mpsc::channel();
        let began = Instant::now();
        let socket = chat::app_acpmux(global);
        let watcher = send.clone();
        let watched = session.to_owned();
        let (tools, tooled, tool_socket) = (send.clone(), session.to_owned(), socket.clone());
        let deadline = began + DRIVE_DEADLINE;
        let turn_socket = socket.clone();
        let spawned = std::thread::Builder::new()
            .name("hybrid-start-turns".into())
            .spawn(move || watch_turns(watched, turn_socket, watcher));
        let mut threads = match spawned {
            Ok(thread) => vec![thread],
            // No turn events: the chat is taken as closed, so nothing moves it.
            Err(_) => {
                let _ = send.send(Msg::Event(Event::Stop));
                Vec::new()
            }
        };
        let followed = std::thread::Builder::new()
            .name("hybrid-start-tools".into())
            .spawn(move || watch_tools(tooled, tool_socket, tools, deadline));
        threads.extend(followed.ok());
        Self {
            global: global.clone(),
            session: session.to_owned(),
            target: target.to_owned(),
            machine: (target != "new").then(|| target.to_owned()),
            began,
            deadline,
            socket,
            send,
            events,
            threads,
            pending: false,
        }
    }
}

/// The chat's tags for `cloud` on `machine` (module docs): the machine only once it is known.
pub(super) fn boot_tags(cloud: Cloud, machine: Option<&str>) -> Value {
    let mut tags = json!({hybrid_tools::STAGE_TAG: hybrid_tools::stage_tag(cloud)});
    if let Some(machine) = machine.filter(|machine| !machine.is_empty()) {
        tags[hybrid_tools::MACHINE_TAG] = json!(machine);
    }
    tags
}

/// The stage tag the drive leaves behind: its last stage, or `none` when the chat stays here
/// (stopped before the machine was ready, or the drive ran out), so no tool call waits on it.
pub(super) fn end_stage(state: &State) -> Cloud {
    match state.cloud {
        Cloud::Live | Cloud::Failed => state.cloud,
        _ => Cloud::None,
    }
}

impl Live {
    /// Sets the chat's stage tags (module docs); they live until the drive could still run.
    fn tag(&self, cloud: Cloud) {
        let left = (self.deadline + MACHINE_GRACE).saturating_duration_since(Instant::now());
        let tags = boot_tags(cloud, self.machine.as_deref());
        let set = chat::acp::set_tags(
            &self.session,
            &tags,
            left.as_secs().max(1),
            self.socket.as_deref(),
        );
        if let Err(error) = set {
            println!("{}", json!({"log": format!("no stage tag: {error}")}));
        }
    }
}

impl Drive for Live {
    fn now_ms(&mut self) -> u64 {
        u64::try_from(self.began.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    fn create_machine(&mut self) {
        let (global, target, send) = (self.global.clone(), self.target.clone(), self.send.clone());
        let failed = send.clone();
        let spawned =
            std::thread::Builder::new().name("hybrid-start-machine".into()).spawn(move || {
                let mut runner = cloud_start_chat::SelfRunner::new(&global);
                let made = ready_machine(&mut runner, &target).map_err(|error| reason_of(&error));
                let _ = send.send(Msg::Machine(made));
            });
        match spawned {
            Ok(thread) => {
                self.threads.push(thread);
                self.pending = true;
            }
            Err(error) => {
                let _ = failed.send(Msg::Machine(Err(format!("the machine start: {error}"))));
            }
        }
    }

    fn next(&mut self) -> Option<Event> {
        let now = Instant::now();
        let message = match self.deadline.checked_duration_since(now) {
            Some(left) => self.events.recv_timeout(left).ok()?,
            // Past the deadline only a machine on its way is waited on, so the one that comes is
            // paused, never left awake with no chat on it.
            None if self.pending => {
                let end = self.deadline + MACHINE_GRACE;
                loop {
                    let left = end.checked_duration_since(Instant::now())?;
                    match self.events.recv_timeout(left).ok()? {
                        Msg::Event(_) => {}
                        machine => break machine,
                    }
                }
            }
            None => return None,
        };
        match message {
            Msg::Event(event) => Some(event),
            Msg::Machine(Ok(id)) => {
                (self.machine, self.pending) = (Some(id), false);
                Some(Event::MachineReady)
            }
            Msg::Machine(Err(reason)) => {
                self.pending = false;
                Some(Event::MachineFailed { reason })
            }
        }
    }

    fn move_chat(&mut self) -> Result<(), (String, bool)> {
        let Some(machine) = self.machine.clone() else {
            return Err(("no machine".to_owned(), false));
        };
        move_once(&self.global, &self.session, &machine)
    }

    /// No Auto store yet for a hybrid start: the store's planned move (`/v1/auto-sessions`,
    /// cmux#52931) is not wired, so every start takes the transfer, as before.
    fn auto_store(&mut self) -> AutoStore {
        AutoStore::default()
    }

    /// Never asked while [`Live::auto_store`] is absent; were it, `auto.off` sends the chat
    /// back to the transfer.
    fn ask_holder_move(&mut self) -> Event {
        Event::HolderRefused { code: Refusal::Off }
    }

    fn pause_machine(&mut self) {
        let Some(machine) = self.machine.clone() else { return };
        // Live sync with a paused machine would only redial it: it stops first.
        #[cfg(unix)]
        if let Err(error) = crate::link::live_stop_chat(&self.session) {
            eprintln!("cmux chat start: stopping live sync of {}: {error:#}", self.session);
        }
        let mut runner = cloud_start_chat::SelfRunner::new(&self.global);
        let paused = step_result(&runner.cmux(&pause_words(&machine)));
        println!("{}", json!({"paused": machine, "ok": paused.is_ok()}));
    }

    fn show(&mut self, cloud: Cloud, reason: Option<&str>) {
        let show = hybrid_show::show_line(
            cloud,
            &self.session,
            reason,
            self.machine.as_deref(),
            unix_ms(),
        )
        .to_string();
        // The log first, then the signal: a watcher woken by the rename reads this Show.
        println!("{show}");
        let _ = std::io::Write::flush(&mut std::io::stdout());
        if let Err(error) = signal_show(&self.session, &show) {
            println!("{}", json!({"log": format!("no show signal: {error}")}));
        }
        self.tag(cloud);
    }

    fn log(&mut self, line: &str) {
        println!("{line}");
    }
}

/// `cmux cloud hybrid-drive …` and `cmux cloud hybrid-status`, hidden verbs.
pub(in crate::cli) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command) = super::super::parse_globals(args).ok()?;
    let [cloud, verb, rest @ ..] = command.as_slice() else { return None };
    if cloud != "cloud" {
        return None;
    }
    match verb.as_str() {
        DRIVE_VERB => Some(run_drive(&global, rest)),
        STATUS_VERB => Some(status(&global)),
        BEGIN_VERB => Some(run_begin(&global, rest)),
        _ => None,
    }
}

/// The driver's chat, target and gate cost, from the words after its verb.
pub(super) fn drive_args(rest: &[String]) -> Option<(String, String, String)> {
    let [session, target, flags @ ..] = rest else { return None };
    if session.starts_with('-') || target.starts_with('-') {
        return None;
    }
    let gate = flags
        .iter()
        .position(|word| word == "--gate-ms")
        .and_then(|at| flags.get(at + 1))
        .cloned()
        .unwrap_or_else(|| "unknown".to_owned());
    Some((session.clone(), target.clone(), gate))
}

fn run_drive(global: &GlobalArgs, rest: &[String]) -> i32 {
    let Some((session, target, gate)) = drive_args(rest) else {
        eprintln!("usage: cmux cloud {DRIVE_VERB} ID new|MACHINE");
        return 2;
    };
    // The start's own cost, then the plan read again for the next start (off the start's path).
    println!("{}gate {gate} ms", hybrid::PREFIX);
    let plan = refresh_plan();
    println!("{}", json!({"plan": plan}));
    let mut live = Live::new(global, &session, &target);
    let state = drive(&mut live);
    live.tag(end_stage(&state));
    // A thread still waiting (a turn watch's slice) ends with this process.
    let left = live.threads.iter().filter(|thread| !thread.is_finished()).count();
    println!("{}", json!({"done": state, "threads_left": left}));
    0
}

/// The app's begin: the driver for a chat that already runs here, detached, its log's path out.
fn run_begin(global: &GlobalArgs, rest: &[String]) -> i32 {
    let Some((session, target, _)) = drive_args(rest) else {
        eprintln!("usage: cmux cloud {BEGIN_VERB} ID new|MACHINE");
        return 2;
    };
    match spawn(global, &session, &target, 0, 0) {
        Ok(log) => super::super::wire::print_local_success(
            &json!({"log": log.display().to_string()}),
            global.output,
        ),
        Err(error) => {
            let error = json!({"code": "hybrid.begin", "message": error, "details": {},
                               "retryable": true});
            super::super::wire::print_local_error(&error, global.output, 1)
        }
    }
}

/// `{enabled, off, plan, flag, signed_in, cloud_disabled, local_harness, harness_ms}`: what the
/// hybrid start decides for this account and machine now, read as the start reads it (the plan
/// too, for the read-back), for a start that names no harness. `off` is the account's reason
/// first, then `no-local-harness`.
fn status(global: &GlobalArgs) -> i32 {
    let flag = flag();
    let mut account = account_of(global, flag);
    if account.plan.is_none() {
        account.plan = read_plan();
    }
    let (local, harness_ms) = local_harness_of(global, None);
    let decided = hybrid::enabled(&account).and(local);
    let answer = json!({
        "enabled": decided.is_ok(),
        "off": decided.err(),
        "plan": account.plan,
        "flag": account.flag,
        "signed_in": account.signed_in,
        "cloud_disabled": account.cloud_disabled,
        "local_harness": local.is_ok(),
        "harness_ms": harness_ms,
    });
    super::super::wire::print_local_success(&answer, global.output)
}

#[cfg(test)]
#[path = "hybrid_start_tests.rs"]
mod tests;
