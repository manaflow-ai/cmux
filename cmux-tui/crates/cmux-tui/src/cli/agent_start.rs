//! `cmux agent start NAME`, `cmux agent resume NAME` and
//! `cmux terminal <t> resume`: start a coding agent in a pane under a name,
//! wait until it can take a message, and bring it back after it exits.
//!
//! ```text
//! cmux agent start NAME [--cmd '<launcher>'] [--harness H] [--pane SEL]
//!                       [--split right|down|left|up] [--cwd DIR] [--no-focus]
//!                       [--timeout 90s] [--no-wait] [-- ARGS...]
//! cmux agent resume NAME [--cmd …] [--pane SEL] [--split DIR] [--cwd DIR] …
//! cmux terminal <t> resume [the same options]
//! cmux terminal <t> wait --until ready [--timeout D]
//! ```
//!
//! - The launcher is a shell command line: `--cmd`, else
//!   `$CMUX_AGENT_COMMAND`, else `claude` (`sr2 claude`, `codex` and any
//!   wrapper work). launch.rs builds the argv.
//! - The name (agent_names.rs grammar) is the tab's name, unique among
//!   running terminals; it selects the agent everywhere a terminal, tab or
//!   pane selector goes.
//! - The tab is placed as placement.rs says, focused unless `--no-focus`,
//!   and waited on as readiness.rs says, unless `--no-wait`.
//! - `resume` reads the exited agent's launcher (`terminal <t> process
//!   show`; not its extra arguments, which may hold the first prompt) and
//!   harness session id (`agent list --terminal <t>`), runs the same
//!   launcher with the harness's resume arguments (`claude --resume <id>`,
//!   `codex resume <id>`), in the old tab's pane unless `--pane`/`--split`
//!   say otherwise, and closes the exited tab, which gives its name to the
//!   new one.
//!
//! Output: `{name, state, reason, dialog, harness, launcher, args, cwd,
//! placement, workspace_id, screen_id, pane_id, tab_id, terminal_id,
//! waited_ms}` (plus `resumed` for a resume). `state` is `ready` (exit 0),
//! `blocked` with `dialog` and `reason` (exit 4), `timeout` (exit 124),
//! `exited` (exit 1), or `started` under `--no-wait` (exit 0).
//!
//! On main these commands are client flows over the daemon requests that
//! main already has (`pane run --on-exit keep`, `pane split`, `workspace
//! create`, `session.snapshot`, `terminal.screen.read`, `agent.list`,
//! `terminal.process.get`); daemon.rs sends them.

pub(in crate::cli) mod daemon;
pub(in crate::cli) mod launch;
pub(in crate::cli) mod placement;
pub(in crate::cli) mod readiness;
#[cfg(test)]
mod tests;

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::agent_names::{self, Found, valid_agent_name};
use super::agent_vocabulary::harness_name;
use super::command::{self, CommandPlan, RequestPlan};
use super::{GlobalArgs, OutputMode, UsageError, wire};
use daemon::{CallFailure, CliDaemon, Daemon};
use launch::Launch;
use placement::{Created, Placement};
use readiness::{Outcome, Readiness, Reads, WaitOptions};

/// The exit code of a start that stopped on a dialog.
pub(in crate::cli) const BLOCKED_EXIT: i32 = 4;
/// The exit code of a start or wait whose timeout passed, as timeout(1) has it.
const TIMEOUT_EXIT: i32 = 124;
/// `terminal <t> wait --until ready` without `--timeout`.
const UNBOUNDED_WAIT: Duration = Duration::from_secs(24 * 3_600);

/// A failed start, resume or wait: the error and its exit code.
#[derive(Debug)]
pub(in crate::cli) struct Failure {
    pub error: Value,
    pub exit: i32,
}

impl Failure {
    pub(in crate::cli) fn local(
        code: &str,
        message: impl Into<String>,
        details: Value,
        exit: i32,
    ) -> Self {
        let error = json!({
            "code": code,
            "message": message.into(),
            "details": details,
            "retryable": false,
        });
        Self { error, exit }
    }

    fn usage(message: impl Into<String>) -> Self {
        Self::local("usage.invalid", message, json!({}), 2)
    }
}

impl From<CallFailure> for Failure {
    fn from(failure: CallFailure) -> Self {
        Self { error: failure.error, exit: 1 }
    }
}

/// A daemon request from CLI words with plain ids.
pub(in crate::cli) fn plan(words: &[&str]) -> Result<RequestPlan, Failure> {
    let words: Vec<String> = words.iter().map(|word| (*word).to_owned()).collect();
    match command::parse(&words) {
        Ok(CommandPlan::Protocol(plan)) => Ok(plan),
        // `agent list` is a client command over `agent.list`; the flows read the rows.
        Ok(CommandPlan::AgentList(list)) => Ok(list.request),
        Ok(_) => Err(Failure::usage(format!("`{}` is not a daemon request", words.join(" ")))),
        Err(error) => Err(Failure::usage(error.0)),
    }
}

/// The options `start` and `resume` share.
#[derive(Clone, Debug, PartialEq)]
pub(in crate::cli) struct Options {
    pub cmd: Option<String>,
    pub harness: Option<String>,
    pub pane: Option<String>,
    pub split: Option<String>,
    pub cwd: Option<String>,
    pub focus: bool,
    pub wait: bool,
    pub timeout: Duration,
    /// Words after `--`: extra launcher arguments.
    pub args: Vec<String>,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            cmd: None,
            harness: None,
            pane: None,
            split: None,
            cwd: None,
            focus: true,
            wait: true,
            timeout: readiness::DEFAULT_TIMEOUT,
            args: Vec::new(),
        }
    }
}

impl Options {
    /// Where a start (or a resume told `--pane`/`--split`) opens the tab.
    pub(in crate::cli) fn placement(&self) -> Placement {
        match (&self.split, &self.pane) {
            (Some(direction), _) => Placement::Split(direction.clone()),
            (None, Some(_)) => Placement::Tab,
            (None, None) => Placement::Split("right".into()),
        }
    }
}

/// What a resume brings back.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) enum ResumeTarget {
    /// `agent resume NAME`.
    Agent(String),
    /// `terminal <t> resume`.
    Terminal(String),
}

/// One parsed command.
#[derive(Clone, Debug, PartialEq)]
pub(in crate::cli) enum Command {
    Start {
        name: String,
        options: Options,
    },
    Resume {
        target: ResumeTarget,
        options: Options,
    },
    /// `terminal <t> wait --until ready [--timeout D]`.
    WaitReady {
        selector: String,
        timeout: Option<Duration>,
    },
}

/// `Some` for `agent start|resume …`, `terminal <t> resume …` and
/// `terminal <t> wait …` (`words` follow the global options); `None` for any
/// other command.
pub(in crate::cli) fn parse(words: &[String]) -> Option<Result<Command, UsageError>> {
    let strs: Vec<&str> = words.iter().map(String::as_str).collect();
    let (scope, rest) = strs.split_first()?;
    match (super::canonical_scope(scope), rest) {
        ("agent", ["start", tail @ ..]) => Some(
            parse_named(tail, "agent start")
                .map(|(name, options)| Command::Start { name, options }),
        ),
        ("agent", ["resume", tail @ ..]) => {
            Some(parse_named(tail, "agent resume").map(|(name, options)| Command::Resume {
                target: ResumeTarget::Agent(name),
                options,
            }))
        }
        ("terminal", [selector, "resume", tail @ ..]) if !selector.starts_with('-') => {
            Some(parse_options(tail, "terminal resume").map(|options| Command::Resume {
                target: ResumeTarget::Terminal((*selector).to_owned()),
                options,
            }))
        }
        ("terminal", [selector, "wait", tail @ ..]) if !selector.starts_with('-') => Some(
            parse_wait(tail)
                .map(|timeout| Command::WaitReady { selector: (*selector).to_owned(), timeout }),
        ),
        _ => None,
    }
}

/// `terminal <t> wait`'s options: `--until ready` (the only condition main
/// has) and an optional `--timeout`.
fn parse_wait(words: &[&str]) -> Result<Option<Duration>, UsageError> {
    let mut until = None;
    let mut timeout = None;
    let mut words = words.iter();
    while let Some(word) = words.next() {
        let (name, inline) = match word.split_once('=') {
            Some((name, value)) if name.starts_with("--") => (name, Some((*value).to_owned())),
            _ => (*word, None),
        };
        let mut value = || {
            inline
                .clone()
                .or_else(|| words.next().map(|value| (*value).to_owned()))
                .ok_or_else(|| UsageError(format!("{name} needs a value")))
        };
        match name {
            "--until" => until = Some(value()?),
            "--timeout" => timeout = Some(duration(&value()?)?),
            other => {
                return Err(UsageError(format!(
                    "terminal wait takes --until ready and --timeout, not {other}"
                )));
            }
        }
    }
    match until.as_deref() {
        Some("ready") => Ok(timeout),
        Some(other) => Err(UsageError(format!("terminal wait --until takes ready, not {other:?}"))),
        None => Err(UsageError("terminal wait needs --until ready".into())),
    }
}

/// A `--timeout` duration: `500ms`, `30s` (or `30`), `5m` or `1h`.
fn duration(text: &str) -> Result<Duration, UsageError> {
    let invalid = || {
        UsageError(format!("--timeout takes a duration such as 500ms, 30s, 5m or 1h, not {text:?}"))
    };
    let digits = text.find(|character: char| !character.is_ascii_digit()).unwrap_or(text.len());
    let (number, unit) = text.split_at(digits);
    let number = number.parse::<u64>().map_err(|_| invalid())?;
    let millis = match unit {
        "ms" => Some(number),
        "" | "s" => number.checked_mul(1_000),
        "m" => number.checked_mul(60_000),
        "h" => number.checked_mul(3_600_000),
        _ => None,
    };
    millis.map(Duration::from_millis).ok_or_else(invalid)
}

fn parse_named(words: &[&str], command: &str) -> Result<(String, Options), UsageError> {
    let Some((name, tail)) = words.split_first().filter(|(name, _)| !name.starts_with('-')) else {
        return Err(UsageError(format!("{command} needs an agent name, like {command} alpha")));
    };
    valid_agent_name(name).map_err(UsageError)?;
    Ok(((*name).to_owned(), parse_options(tail, command)?))
}

/// `--name value`, `--name=value` and switches, then `-- ARGS…`.
pub(in crate::cli) fn parse_options(words: &[&str], command: &str) -> Result<Options, UsageError> {
    let mut options = Options::default();
    let mut words = words.iter();
    while let Some(word) = words.next() {
        if *word == "--" {
            options.args = words.by_ref().map(|word| (*word).to_owned()).collect();
            break;
        }
        let (name, inline) = match word.split_once('=') {
            Some((name, value)) if name.starts_with("--") => (name, Some(value.to_owned())),
            _ => (*word, None),
        };
        match name {
            "--focus" => options.focus = true,
            "--no-focus" => options.focus = false,
            "--no-wait" => options.wait = false,
            "--right" | "--down" | "--left" | "--up" => {
                options.split = Some(name.trim_start_matches('-').to_owned());
            }
            "--cmd" | "--harness" | "--pane" | "--split" | "--cwd" | "--timeout" => {
                let value = match inline {
                    Some(value) => value,
                    None => words
                        .next()
                        .map(|value| (*value).to_owned())
                        .ok_or_else(|| UsageError(format!("{name} needs a value")))?,
                };
                match name {
                    "--cmd" if value.trim().is_empty() => {
                        return Err(UsageError("--cmd needs a launcher, like 'sr2 claude'".into()));
                    }
                    "--cmd" => options.cmd = Some(value),
                    "--harness" => options.harness = Some(harness_name(&value)),
                    "--pane" => options.pane = Some(value),
                    "--split" if matches!(value.as_str(), "right" | "down" | "left" | "up") => {
                        options.split = Some(value);
                    }
                    "--split" => {
                        return Err(UsageError(format!(
                            "--split takes right, down, left or up, not {value:?}"
                        )));
                    }
                    "--cwd" => options.cwd = Some(value),
                    _ => options.timeout = duration(&value)?,
                }
            }
            other => {
                return Err(UsageError(format!(
                    "{command} takes --cmd, --harness, --pane, --split, --cwd, --focus, \
                     --no-focus, --timeout, --no-wait and -- ARGS, not {other}"
                )));
            }
        }
    }
    Ok(options)
}

/// What the process gives a start: the caller's terminal (only when the
/// command routes to the caller's own session), folder, shell and default
/// launcher.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(in crate::cli) struct Env {
    pub caller_terminal: Option<String>,
    pub cwd: Option<String>,
    pub shell: String,
    pub default_launcher: Option<String>,
}

impl Env {
    fn of_process(global: &GlobalArgs) -> Self {
        let var = |name: &str| std::env::var(name).ok().filter(|value| !value.is_empty());
        // The caller's terminal is in the session that its environment names;
        // an explicit `--socket` or `--session` routes elsewhere.
        let caller_route = global.socket.is_none() && global.session.is_none();
        Self {
            caller_terminal: var("CMUX_TUI_TERMINAL_ID").filter(|_| caller_route),
            cwd: std::env::current_dir().ok().map(|dir| dir.display().to_string()),
            shell: launch::shell_from(var("SHELL").as_deref()),
            default_launcher: var(launch::DEFAULT_LAUNCHER_ENV),
        }
    }
}

/// The clock a start waits on (tests pass a fake one).
pub(in crate::cli) struct Clock<'a> {
    pub now: &'a dyn Fn() -> Instant,
    pub sleep: &'a mut dyn FnMut(Duration),
    /// Unix ms now: agent records older than the start do not count.
    pub now_ms: u64,
}

/// Runs a parsed command; the exit code.
pub(in crate::cli) fn run(global: &GlobalArgs, command: &Command) -> i32 {
    let backend = CliDaemon { global: global.clone() };
    let env = Env::of_process(global);
    let mut sleep = std::thread::sleep;
    let mut clock = Clock { now: &Instant::now, sleep: &mut sleep, now_ms: now_ms() };
    let result = match command {
        Command::Start { name, options } => start(&backend, &env, &mut clock, name, options),
        Command::Resume { target, options } => resume(&backend, &env, &mut clock, target, options),
        Command::WaitReady { selector, timeout } => wait_ready(&backend, selector, *timeout),
    };
    match result {
        Ok((report, exit)) => print_report(global.output, &report, exit),
        Err(failure) => wire::print_local_error(&failure.error, global.output, failure.exit),
    }
}

/// Unix ms now: agent records older than the start do not count.
fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
}

/// Sets `key` of the report object.
fn set(report: &mut Value, key: &str, value: Value) {
    if let Some(object) = report.as_object_mut() {
        object.insert(key.to_owned(), value);
    }
}

fn print_report(output: OutputMode, report: &Value, exit: i32) -> i32 {
    use std::io::Write as _;
    let line = match output {
        OutputMode::Quiet => return exit,
        OutputMode::Json | OutputMode::JsonLines => {
            serde_json::to_string(report).unwrap_or_default()
        }
        OutputMode::Human => human(report),
    };
    let mut stdout = std::io::stdout().lock();
    match writeln!(stdout, "{line}").and_then(|()| stdout.flush()) {
        Ok(()) => exit,
        Err(error) => {
            eprintln!("stdout error: {error}");
            3
        }
    }
}

/// One line for a person: `alpha ready: term_… (tab_…, pane_…)`, and the
/// reason on a second line when it is not ready.
pub(in crate::cli) fn human(report: &Value) -> String {
    let field = |key: &str| report[key].as_str().unwrap_or("-").to_owned();
    let who = report["name"].as_str().map_or_else(|| field("terminal_id"), str::to_owned);
    let state = match report["dialog"].as_str() {
        Some(dialog) => format!("{} ({dialog})", field("state")),
        None => field("state"),
    };
    let mut line = format!(
        "{who} {state}: {} ({}, {})",
        field("terminal_id"),
        field("tab_id"),
        field("pane_id")
    );
    if let Some(reason) = report["reason"].as_str() {
        line.push_str(&format!("\n  {reason}"));
    }
    line
}

fn terminal_reads(terminal: &str) -> Result<Reads, Failure> {
    Ok(Reads {
        show: plan(&["terminal", terminal, "show"])?,
        agents: plan(&["agent", "list", "--terminal", terminal])?,
        screen: plan(&["terminal", terminal, "screen", "read"])?,
    })
}

/// Records how the wait ended in `report`; the exit code.
pub(in crate::cli) fn apply_outcome(report: &mut Value, outcome: &Outcome, who: &str) -> i32 {
    let waited = humantime(outcome.waited);
    let (state, exit, dialog, reason) = match outcome.readiness {
        Some(Readiness::Ready) => ("ready", 0, None, None),
        Some(Readiness::Blocked(dialog)) => {
            ("blocked", BLOCKED_EXIT, Some(dialog.id), Some(dialog.reason.to_owned()))
        }
        Some(Readiness::Exited) => (
            "exited",
            1,
            None,
            Some(format!(
                "the agent exited before it was ready; cmux terminal {who} screen read shows why, \
                 cmux terminal {who} resume brings it back"
            )),
        ),
        Some(Readiness::Starting) | None => (
            "timeout",
            TIMEOUT_EXIT,
            None,
            Some(format!(
                "the agent showed no input box within {waited}; read its screen with cmux \
                 terminal {who} screen read"
            )),
        ),
    };
    set(report, "state", json!(state));
    set(report, "dialog", json!(dialog));
    set(report, "reason", json!(reason));
    set(report, "waited_ms", json!(outcome.waited.as_millis().to_string()));
    exit
}

/// A short age: `12s`, `3m`, `2h`, `1d`.
fn humantime(duration: Duration) -> String {
    let seconds = duration.as_secs();
    match seconds {
        0..60 => format!("{seconds}s"),
        60..3_600 => format!("{}m", seconds / 60),
        3_600..86_400 => format!("{}h", seconds / 3_600),
        _ => format!("{}d", seconds / 86_400),
    }
}

/// Waits (unless `--no-wait`) and records the end in `report`.
fn finish<D: Daemon + ?Sized>(
    daemon: &D,
    clock: &mut Clock<'_>,
    options: &Options,
    created: &Created,
    who: &str,
    report: &mut Value,
) -> Result<i32, Failure> {
    if options.focus
        && let Ok(focus) = plan(&["tab", created.tab.as_str(), "focus"])
    {
        // The agent runs either way; a focus the session refuses is no failure.
        let _ = daemon.request(None, focus);
    }
    if !options.wait {
        set(report, "state", json!("started"));
        return Ok(0);
    }
    let reads = terminal_reads(&created.terminal)?;
    let wait = WaitOptions::new(options.timeout, clock.now_ms);
    let outcome = readiness::wait(daemon, &reads, wait, clock.now, clock.sleep)?;
    Ok(apply_outcome(report, &outcome, who))
}

fn report(
    name: Option<&str>,
    launch: &Launch,
    harness: Option<&str>,
    cwd: Option<&str>,
    placement: &Placement,
    created: &Created,
) -> Value {
    json!({
        "name": name,
        "state": "started",
        "reason": null,
        "dialog": null,
        "harness": harness,
        "launcher": launch.launcher,
        "args": launch.args,
        "cwd": cwd,
        "placement": placement.as_str(),
        "workspace_id": created.workspace,
        "screen_id": created.screen,
        "pane_id": created.pane,
        "tab_id": created.tab,
        "terminal_id": created.terminal,
        "waited_ms": "0",
    })
}

/// `agent start NAME`: the report and the exit code.
pub(in crate::cli) fn start<D: Daemon + ?Sized>(
    daemon: &D,
    env: &Env,
    clock: &mut Clock<'_>,
    name: &str,
    options: &Options,
) -> Result<(Value, i32), Failure> {
    valid_agent_name(name).map_err(Failure::usage)?;
    let snapshot = daemon::snapshot(daemon)?;
    if let Some(taken) = agent_names::places_named(&snapshot, name).into_iter().find(|p| p.live) {
        return Err(Failure::local(
            "agent.name_taken",
            format!(
                "{name} already names a running tab ({}); choose another name, or write to it \
                 with cmux terminal {name} write --text …",
                taken.terminal
            ),
            json!({"name": name, "terminal_id": taken.terminal, "tab_id": taken.tab}),
            1,
        ));
    }
    let launcher = launch::launcher_from(options.cmd.as_deref(), env.default_launcher.as_deref());
    let harness = options.harness.clone().or_else(|| launch::harness_of(&launcher));
    let launch = Launch { shell: env.shell.clone(), launcher, args: options.args.clone() };
    let cwd = options.cwd.clone().or_else(|| env.cwd.clone());
    let fresh = match options.pane {
        None => placement::empty_session_pane(daemon, &snapshot, name)?,
        Some(_) => None,
    };
    let (pane, placement) = match &fresh {
        Some((pane, _)) => (pane.clone(), Placement::Tab),
        None => (
            placement::target_pane(
                &snapshot,
                options.pane.as_deref(),
                env.caller_terminal.as_deref(),
            )?,
            options.placement(),
        ),
    };
    let created =
        placement::open(daemon, &pane, &placement, Some(name), cwd.as_deref(), &launch.argv())?;
    if let Some((_, Some(shell))) = &fresh {
        placement::end_placeholder(daemon, shell);
    }
    let mut report =
        report(Some(name), &launch, harness.as_deref(), cwd.as_deref(), &placement, &created);
    let exit = finish(daemon, clock, options, &created, name, &mut report)?;
    Ok((report, exit))
}

/// The newest agent record of `records` that names a harness session id.
fn session_record(records: &Value) -> Option<(&Value, String)> {
    records
        .as_array()?
        .iter()
        .filter_map(|record| {
            let id = record
                .pointer("/extra/agent_session_id")
                .and_then(Value::as_str)
                .or_else(|| record["agent_session_id"].as_str())?;
            Some((record, id.to_owned()))
        })
        .max_by_key(|(record, _)| {
            record["updated_at_ms"]
                .as_u64()
                .or_else(|| record["updated_at_ms"].as_str().and_then(|ms| ms.parse().ok()))
                .unwrap_or(0)
        })
}

/// The exited agent a resume brings back.
struct Exited {
    terminal: String,
    tab: Option<String>,
    pane: Option<String>,
    name: Option<String>,
    cwd: Option<String>,
    /// The harness session id the daemon kept on the terminal (`extra.agent_session_id`):
    /// the roster drops an agent's record once its session ended.
    session_id: Option<String>,
    /// The harness the daemon kept with it (`extra.agent`).
    harness: Option<String>,
}

fn exited_target(snapshot: &Value, target: &ResumeTarget) -> Result<Exited, Failure> {
    let terminals = snapshot["terminals"].as_array().map(Vec::as_slice).unwrap_or_default();
    let tabs = snapshot["tabs"].as_array().map(Vec::as_slice).unwrap_or_default();
    let terminal = match target {
        ResumeTarget::Agent(name) => match agent_names::resolve(snapshot, name) {
            Found::One(place) => {
                terminals.iter().find(|terminal| terminal["id"] == place.terminal.as_str())
            }
            Found::Ambiguous(tabs) => {
                return Err(Failure::local(
                    "selector.ambiguous",
                    format!(
                        "{} tabs are named {name}; resume one by its terminal (cmux terminal \
                         <term> resume)",
                        tabs.len()
                    ),
                    json!({"name": name, "candidates": tabs}),
                    1,
                ));
            }
            Found::Missing => None,
        }
        .ok_or_else(|| {
            Failure::local(
                "selector.not_found",
                format!("no agent is named {name}; cmux agent list lists them"),
                json!({"name": name}),
                1,
            )
        })?,
        ResumeTarget::Terminal(selector) => daemon::find_terminal(snapshot, selector)?,
    };
    let id = terminal["id"].as_str().unwrap_or_default().to_owned();
    if terminal["lifecycle"] != "exited" {
        return Err(Failure::local(
            "agent.running",
            format!(
                "the agent in {id} still runs; resume brings back an agent that exited (quit it \
                 first, or write to it with cmux terminal {id} write)"
            ),
            json!({"terminal_id": id}),
            1,
        ));
    }
    let tab_id = terminal["tab_id"].as_str();
    let tab = tabs.iter().find(|tab| tab_id.is_some_and(|id| tab["id"] == id));
    let text = |value: &Value| value.as_str().filter(|text| !text.is_empty()).map(str::to_owned);
    Ok(Exited {
        terminal: id,
        tab: tab.and_then(|tab| text(&tab["id"])),
        pane: tab.and_then(|tab| text(&tab["pane_id"])),
        name: match target {
            ResumeTarget::Agent(name) => Some(name.clone()),
            ResumeTarget::Terminal(_) => {
                tab.and_then(|tab| text(&tab["name"])).filter(|name| valid_agent_name(name).is_ok())
            }
        },
        cwd: text(&terminal["cwd"]),
        session_id: terminal.pointer("/extra/agent_session_id").and_then(text),
        harness: terminal.pointer("/extra/agent").and_then(text),
    })
}

/// The launch that resumes harness session `session_id`: `--cmd` or the
/// recorded launcher, the `-- ARGS` of this resume, then the harness's resume
/// arguments. The recorded extra arguments are not run again: they may hold
/// the first prompt (`agent start alpha -- 'Fix the test'`), which a resume
/// must not send twice. Launcher flags belong in `--cmd`.
pub(in crate::cli) fn resume_launch(
    recorded: Option<Launch>,
    env: &Env,
    options: &Options,
    harness: &str,
    session_id: &str,
) -> Result<Launch, Failure> {
    let tail = launch::resume_args(harness, session_id).ok_or_else(|| {
        Failure::local(
            "agent.resume_unsupported",
            format!("cmux does not know how {harness} resumes a session"),
            json!({"harness": harness}),
            1,
        )
    })?;
    let mut launch = match (&options.cmd, recorded) {
        (Some(cmd), _) => {
            Launch { shell: env.shell.clone(), launcher: cmd.clone(), args: options.args.clone() }
        }
        (None, Some(recorded)) => Launch { args: options.args.clone(), ..recorded },
        (None, None) => {
            let launcher = env
                .default_launcher
                .clone()
                .filter(|launcher| launch::harness_of(launcher).as_deref() == Some(harness))
                .unwrap_or_else(|| harness.to_owned());
            Launch { shell: env.shell.clone(), launcher, args: options.args.clone() }
        }
    };
    launch.args.extend(tail);
    Ok(launch)
}

/// `agent resume NAME` and `terminal <t> resume`: the report and exit code.
pub(in crate::cli) fn resume<D: Daemon + ?Sized>(
    daemon: &D,
    env: &Env,
    clock: &mut Clock<'_>,
    target: &ResumeTarget,
    options: &Options,
) -> Result<(Value, i32), Failure> {
    let target = match target {
        ResumeTarget::Terminal(selector) => {
            ResumeTarget::Terminal(daemon::terminal_keyword(daemon, selector)?)
        }
        ResumeTarget::Agent(_) => target.clone(),
    };
    let snapshot = daemon::snapshot(daemon)?;
    let exited = exited_target(&snapshot, &target)?;
    let records =
        daemon.request(None, plan(&["agent", "list", "--terminal", &exited.terminal])?)?;
    // An agent that quit has no record left; the terminal keeps its last session id.
    let none = Value::Null;
    let kept = exited.session_id.clone().map(|id| (&none, id));
    let (record, session_id) = session_record(&records).or(kept).ok_or_else(|| {
        Failure::local(
            "agent.no_session",
            format!(
                "no harness session id is on record for {}; the agent's hooks report it \
                 (cmux agent hook status)",
                exited.terminal
            ),
            json!({"terminal_id": exited.terminal}),
            1,
        )
    })?;
    if !launch::valid_session_id(&session_id) {
        return Err(Failure::local(
            "agent.no_session",
            format!("the recorded session id of {} cannot be resumed", exited.terminal),
            json!({"terminal_id": exited.terminal}),
            1,
        ));
    }
    let argv: Vec<String> = daemon
        .request(None, plan(&["terminal", &exited.terminal, "process", "show"])?)
        .ok()
        .and_then(|process| process.get("argv").and_then(Value::as_array).cloned())
        .unwrap_or_default()
        .iter()
        .filter_map(|word| word.as_str().map(str::to_owned))
        .collect();
    let recorded = Launch::from_argv(&argv);
    let harness = options
        .harness
        .clone()
        .or_else(|| record.pointer("/extra/agent").and_then(Value::as_str).map(harness_name))
        .or_else(|| exited.harness.as_deref().map(harness_name))
        .or_else(|| recorded.as_ref().and_then(|launch| launch::harness_of(&launch.launcher)))
        .or_else(|| options.cmd.as_deref().and_then(launch::harness_of))
        .ok_or_else(|| {
            Failure::local(
                "agent.unknown_harness",
                format!("which agent ran in {} is not on record; pass --harness", exited.terminal),
                json!({"terminal_id": exited.terminal}),
                2,
            )
        })?;
    let launch = resume_launch(recorded, env, options, &harness, &session_id)?;
    let cwd = options
        .cwd
        .clone()
        .or_else(|| exited.cwd.clone())
        .or_else(|| record["cwd"].as_str().map(str::to_owned))
        .or_else(|| env.cwd.clone());
    let (pane, placement) = match (&exited.pane, &options.pane, &options.split) {
        (Some(pane), None, None) => (pane.clone(), Placement::Tab),
        _ => (
            placement::target_pane(
                &snapshot,
                options.pane.as_deref(),
                env.caller_terminal.as_deref(),
            )?,
            options.placement(),
        ),
    };
    let name = exited.name.as_deref();
    let created = placement::open(daemon, &pane, &placement, name, cwd.as_deref(), &launch.argv())?;
    // The exited tab gives its name and place to the resumed agent.
    let closed = exited.tab.as_deref().is_some_and(|tab| {
        plan(&["tab", tab, "close"]).is_ok_and(|close| daemon.request(None, close).is_ok())
    });
    let mut report =
        report(name, &launch, Some(harness.as_str()), cwd.as_deref(), &placement, &created);
    set(
        &mut report,
        "resumed",
        json!({
            "terminal_id": exited.terminal,
            "tab_id": exited.tab,
            "agent_session_id": session_id,
            "tab_closed": closed,
        }),
    );
    let who = name.unwrap_or(created.terminal.as_str()).to_owned();
    let exit = finish(daemon, clock, options, &created, &who, &mut report)?;
    Ok((report, exit))
}

/// `terminal <t> wait --until ready [--timeout D]`: waits as `agent start`
/// does; exits 0 ready, 4 blocked, 1 exited, 124 timeout.
fn wait_ready<D: Daemon + ?Sized>(
    daemon: &D,
    selector: &str,
    timeout: Option<Duration>,
) -> Result<(Value, i32), Failure> {
    let selector = daemon::terminal_keyword(daemon, selector)?;
    let snapshot = daemon::snapshot(daemon)?;
    let terminal = daemon::find_terminal(&snapshot, &selector)?;
    let id = terminal["id"].as_str().unwrap_or_default().to_owned();
    let reads = terminal_reads(&id)?;
    let options = WaitOptions::new(timeout.unwrap_or(UNBOUNDED_WAIT), 0);
    let outcome = readiness::wait(daemon, &reads, options, &Instant::now, &mut std::thread::sleep)?;
    let mut report = json!({"terminal_id": id, "until": "ready"});
    let exit = apply_outcome(&mut report, &outcome, &id);
    match outcome.readiness {
        Some(Readiness::Ready | Readiness::Blocked(_)) => Ok((report, exit)),
        Some(Readiness::Exited) => Err(Failure::local(
            "terminal.exited",
            "the terminal exited before its agent was ready",
            json!({"terminal": id, "until": "ready"}),
            1,
        )),
        Some(Readiness::Starting) | None => {
            let millis = timeout.unwrap_or(UNBOUNDED_WAIT).as_millis();
            Err(Failure {
                error: json!({
                    "code": "wait.timeout",
                    "message": format!("the terminal's agent was not ready within {millis} ms"),
                    "details": {
                        "until": "ready",
                        "timeout_ms": millis.to_string(),
                        "state": outcome.last.as_str(),
                    },
                    "retryable": true,
                }),
                exit: TIMEOUT_EXIT,
            })
        }
    }
}
