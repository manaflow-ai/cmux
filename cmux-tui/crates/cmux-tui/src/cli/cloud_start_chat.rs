//! `cmux cloud start-chat [--prompt TEXT] [--agent claude] [--cwd DIR] [--login L] [--environment E]
//! [--name MACHINE | --target machine:ID] [--wait] [--timeout SECONDS]`: one command takes a Cloud chat from
//! nothing to a reply, for a person, a script or the Chief (Leo, 2026-11-02: "we need to improve
//! the docs/instructions/commands and guidance and whatnot to make this all smoother faster more
//! efficient more exposed / cuz chief will be using this kind of flow").
//!
//! It runs the app's own verbs in turn, each as this binary with `--json`, so every step keeps
//! that verb's checks, keys and deadlines:
//!
//! 1. `cloud list-machines`: refuses at once when the app is signed out of cmux.
//!    With `--environment`, `cloud new-machine --environment E` first makes the chat's machine in it.
//! 2. `cloud start-session (--name N | --target T) --agent A [--cwd D] [--login L]`: takes the machine (or
//!    creates it) and opens the chat's tab in the machine's workspace, a real chat in the app.
//!    Without `--name` or `--target` it creates a new small machine with a new name, so the chat
//!    never lands on a machine another workspace uses (leo-workspace `design/cloud.md`, "One
//!    workspace per small machine").
//!    With no prompt the command answers here: the chat's ids, `ready_ms` and the follow-ups.
//! 3. `cloud exec` on that machine: hands the prompt to the chat's session in the machine's own
//!    acpmux (`cmux-tui acp send --no-wait`), which the chat's tab shows like any send. A prompt
//!    of any length works: one too long to go in one command goes to a file on the machine first,
//!    in pieces, and the send reads it from there ([`upload_prompt`]).
//! 4. With `--wait`, `cloud exec` again until the turn ends (`cmux-tui acp wait`, under the
//!    exec's own 25 s limit each time), then the turn's last reply (`cmux-tui acp last`).
//!    `--timeout` counts from the command's start: a new machine, the start and the relay
//!    spend it too.
//!
//! Output: one JSON object (`--json`): the reply text with `machine_id`, `session_id`,
//! `workspace_id`, `tab_id` and the follow-up commands. A failure names what
//! to do next: sign in, run the same command again for a machine still starting, or answer
//! the question the app is asking the person.

use std::io::Read as _;
use std::time::{Duration, Instant};

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode, UsageError};

/// The longest the app's `cloud relay-chat` may take to answer: `action.run`'s result deadline.
const RELAY_ANSWER_WINDOW: Duration = Duration::from_secs(40);
/// The longest `--wait` takes by default, and at most.
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(900);
const MAX_TIMEOUT: Duration = Duration::from_secs(4 * 60 * 60);
/// `cmux-tui acp wait`'s own timeout inside one `cloud exec` (the exec stops after 25 s).
const WAIT_SLICE_SECONDS: u64 = 20;
/// The pause before asking again when the machine's acpmux had not started the turn yet.
const NOT_STARTED_PAUSE: Duration = Duration::from_secs(2);
/// The machine's own binary: the guest `cmux` wrapper takes no `acp`. `cmux-tui` on `PATH` is a
/// link to the daemon's own `~/.cmux/bin/cmux-tui` on a NEXT image; the script prefers that one, so
/// the client is the build the machine's acpmux runs.
const GUEST_CMUX: &str = "cmux-tui";
/// An exec may run without a login profile: the work user's home holds the acpmux socket
/// (`~/.acpmux/acpmux.sock`).
const GUEST_PRELUDE: &str = "export HOME=\"${HOME:-/home/cmux}\"; c=cmux-tui; \
    [ -x \"$HOME/.cmux/bin/cmux-tui\" ] && c=\"$HOME/.cmux/bin/cmux-tui\"; ";

/// The most of a prompt that goes inside the send's own command, quoted. Longer prompts go to a
/// file on the machine first. The cmux API takes a command of at most 64 KiB, and this one has
/// the script around it.
const INLINE_PROMPT_BYTES: usize = 60 * 1024;
/// One upload piece of a long prompt, as raw bytes; it travels as base64, a third larger. Its
/// `cloud exec` stays well inside this Mac's room for a child's arguments (1 MiB).
const PROMPT_PIECE_BYTES: usize = 384 * 1024;
/// The piece once a route refuses the large one as too long a command (a cmux API that takes
/// at most 64 KiB per command): its base64 and the script around it fit there.
const SMALL_PROMPT_PIECE_BYTES: usize = 45 * 1024;

/// This command's flags that take the next word as their value.
const TAKES_VALUE: &[&str] = &[
    "--prompt",
    "-p",
    "--agent",
    "--cwd",
    "--login",
    "--environment",
    "--name",
    "--target",
    "--timeout",
];

/// `--login`'s words, as `cloud start-session` takes them (`CloudHarnessLoginAsk.choice`): the person's
/// login, the machine's own, or none.
const LOGINS: &[&str] = &["pass", "machine", "none"];

/// Which machine the chat starts on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Machine {
    /// `--name`: that machine, created when none has the name.
    Named(String),
    /// `--target machine:ID`.
    Target(String),
    /// Neither: a new machine, named when the command runs.
    New,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Request {
    /// `None`: start the chat and send nothing (`ready_ms` and `follow_up.send` in the answer).
    pub prompt: Option<String>,
    pub agent: String,
    pub cwd: Option<String>,
    /// `--login pass|machine|none`: the harness login the machine's agent gets, as `cloud start-session`
    /// takes it (`CloudHarnessLoginAsk`); `None` leaves the app's default.
    pub login: Option<String>,
    /// `--environment ID|NAME`: the Cloud environment (`env_…`, or its name) a new machine boots in
    /// (`cloud new-machine --environment`).
    pub environment: Option<String>,
    pub machine: Machine,
    pub wait: bool,
    pub timeout: Duration,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Parsed {
    Help,
    Run(Request),
}

/// `Some(exit code)` when `args` is `cloud start-chat …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, verb, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || verb != "start-chat" {
        return None;
    }
    // `--wait --json`: the global scan takes `--json` as `--wait`'s value.
    let words = lift_output(rest, &mut global.output);
    let parsed = parse(&words, || {
        let mut text = String::new();
        std::io::stdin().read_to_string(&mut text).map(|_| text).map_err(|e| e.to_string())
    });
    let request = match parsed {
        Ok(Parsed::Help) => {
            print!("{}", super::cloud_help::START_CHAT_USAGE);
            return Some(0);
        }
        Ok(Parsed::Run(request)) => request,
        Err(error) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {}\n{}", error.0, super::cloud_help::START_CHAT_USAGE),
                global.output,
                2,
            ));
        }
    };
    let mut runner = SelfRunner { globals: forwarded_globals(&global) };
    let outcome = run(&mut runner, &request);
    Some(report(&outcome, global.output))
}

/// `rest` without the output flags the global scan left in it, which set `output`. A value of
/// one of this command's own flags (`--prompt --json`) stays a value.
pub(super) fn lift_output(rest: &[String], output: &mut OutputMode) -> Vec<String> {
    let mut words = Vec::new();
    let mut value_next = false;
    for word in rest {
        if value_next {
            value_next = false;
            words.push(word.clone());
            continue;
        }
        match word.as_str() {
            "--json" => *output = OutputMode::Json,
            "--jsonl" => *output = OutputMode::JsonLines,
            "--quiet" => *output = OutputMode::Quiet,
            _ => {
                value_next = TAKES_VALUE.contains(&word.as_str());
                words.push(word.clone());
            }
        }
    }
    words
}

/// The words after `cloud start-chat`. `stdin` reads the prompt for `--prompt -`.
pub(super) fn parse(
    words: &[String],
    stdin: impl FnOnce() -> Result<String, String>,
) -> Result<Parsed, UsageError> {
    let mut prompt = None;
    let mut agent = None;
    let mut cwd = None;
    let mut login = None;
    let mut environment = None;
    let mut name = None;
    let mut target = None;
    let mut wait = false;
    let mut timeout = DEFAULT_TIMEOUT;
    let mut index = 0;
    while index < words.len() {
        let Some(word) = words.get(index).map(String::as_str) else { break };
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word, None),
        };
        let mut value = || -> Result<String, UsageError> {
            if let Some(value) = inline.clone() {
                return Ok(value);
            }
            index += 1;
            words
                .get(index)
                .cloned()
                .ok_or_else(|| UsageError::new(format!("{flag} needs a value")))
        };
        match flag {
            "-h" | "--help" => return Ok(Parsed::Help),
            "--prompt" | "-p" => prompt = Some(value()?),
            "--agent" => agent = Some(value()?),
            "--cwd" => cwd = Some(value()?),
            "--login" => login = Some(value()?),
            "--environment" => environment = Some(value()?),
            "--name" => name = Some(value()?),
            "--target" => target = Some(value()?),
            "--timeout" => {
                let text = value()?;
                let seconds =
                    text.parse::<u64>().ok().filter(|seconds| *seconds > 0).ok_or_else(|| {
                        UsageError::new(format!("--timeout {text}: give seconds"))
                    })?;
                timeout = Duration::from_secs(seconds).min(MAX_TIMEOUT);
            }
            "--wait" => wait = true,
            "--no-wait" => wait = false,
            _ => return Err(UsageError::new(format!("unexpected argument {word:?}"))),
        }
        index += 1;
    }
    let prompt = match prompt.as_deref() {
        Some("-") => {
            Some(stdin().map_err(|error| UsageError::new(format!("--prompt -: {error}")))?)
        }
        Some(text) => Some(text.to_owned()),
        None => None,
    };
    if prompt.as_deref().is_some_and(|text| text.trim().is_empty()) {
        return Err(UsageError::new("--prompt is empty"));
    }
    let agent = agent.unwrap_or_else(|| "claude".to_owned());
    if agent.is_empty()
        || !agent
            .chars()
            .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || "._-".contains(ch))
    {
        return Err(UsageError::new(format!(
            "--agent {agent:?}: a harness id such as claude or codex"
        )));
    }
    if let Some(dir) = &cwd
        && !dir.starts_with('/')
    {
        return Err(UsageError::new(format!("--cwd {dir}: an absolute folder on the machine")));
    }
    let login = match login.map(|word| word.trim().to_lowercase()) {
        Some(word) if !LOGINS.contains(&word.as_str()) => {
            return Err(UsageError::new(format!("--login {word:?}: pass, machine or none")));
        }
        login => login,
    };
    let environment = match environment.map(|word| word.trim().to_owned()) {
        Some(word) if word.is_empty() => return Err(UsageError::new("--environment is empty")),
        environment => environment,
    };
    if environment.is_some() && target.is_some() {
        return Err(UsageError::new(
            "--environment makes a new machine; not with --target, whose environment is set",
        ));
    }
    let machine = match (name, target) {
        (Some(_), Some(_)) => return Err(UsageError::new("give --name or --target, not both")),
        (Some(name), None) if name.trim().is_empty() => {
            return Err(UsageError::new("--name is empty"));
        }
        (Some(name), None) => Machine::Named(name.trim().to_owned()),
        (None, Some(target)) => {
            let id = target.strip_prefix("machine:").unwrap_or(&target);
            if id.is_empty() {
                return Err(UsageError::new("--target machine:MACHINE_ID"));
            }
            Machine::Target(id.to_owned())
        }
        (None, None) => Machine::New,
    };
    Ok(Parsed::Run(Request { prompt, agent, cwd, login, environment, machine, wait, timeout }))
}

/// One run of this binary: its exit code and what it printed.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct Ran {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

/// How the steps run: this binary in a child process, or a fake in tests.
pub(super) trait Runner {
    fn cmux(&mut self, args: &[String]) -> Ran;
    fn pause(&mut self, duration: Duration);
    fn now(&mut self) -> Instant;
    /// A new machine's name (unique enough that no other machine has it).
    fn fresh_name(&mut self) -> String;
    /// A new prompt id: acpmux runs a prompt id once.
    fn prompt_id(&mut self) -> String;
}

struct SelfRunner {
    globals: Vec<String>,
}

impl Runner for SelfRunner {
    fn cmux(&mut self, args: &[String]) -> Ran {
        let exe = match std::env::current_exe() {
            Ok(exe) => exe,
            Err(error) => {
                return Ran { code: 127, stdout: String::new(), stderr: error.to_string() };
            }
        };
        match cmux_process::Command::new(exe).args(&self.globals).args(args).output() {
            Ok(output) => Ran {
                code: output.status.code().unwrap_or(1),
                stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
                stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            },
            Err(error) => Ran { code: 127, stdout: String::new(), stderr: error.to_string() },
        }
    }

    fn pause(&mut self, duration: Duration) {
        std::thread::sleep(duration);
    }

    fn now(&mut self) -> Instant {
        Instant::now()
    }

    fn fresh_name(&mut self) -> String {
        let id = uuid::Uuid::new_v4().simple().to_string();
        format!("chat-{}", id.chars().take(8).collect::<String>())
    }

    fn prompt_id(&mut self) -> String {
        format!("start-chat-{}", uuid::Uuid::new_v4().simple())
    }
}

/// The globals a step needs to reach the same app.
fn forwarded_globals(global: &GlobalArgs) -> Vec<String> {
    let mut words = Vec::new();
    if let Some(socket) = &global.app_socket {
        words.extend(["--app-socket".to_owned(), socket.display().to_string()]);
    }
    if let Some(socket) = &global.socket {
        words.extend(["--socket".to_owned(), socket.display().to_string()]);
    }
    words
}

/// What the command answers: the result object, or an error object and its exit code.
#[derive(Debug, PartialEq)]
pub(super) enum Outcome {
    Done(Value),
    Failed { error: Value, exit: i32 },
}

fn failed(code: &str, message: impl Into<String>, details: Value, exit: i32) -> Outcome {
    Outcome::Failed {
        error: json!({"code": code, "message": message.into(), "details": details,
                      "retryable": false}),
        exit,
    }
}

/// The app's answer to one `--json` step: its `result`, or its error object.
pub(super) fn step_result(ran: &Ran) -> Result<Value, Value> {
    let parsed = |text: &str| -> Option<Value> {
        let text = text.trim();
        serde_json::from_str::<Value>(text).ok().or_else(|| {
            text.lines().rev().find_map(|line| serde_json::from_str::<Value>(line.trim()).ok())
        })
    };
    if ran.code == 0
        && let Some(value) = parsed(&ran.stdout)
    {
        return Ok(value.get("result").cloned().unwrap_or(value));
    }
    let error = parsed(&ran.stderr)
        .or_else(|| parsed(&ran.stdout))
        .filter(|value| value.get("code").is_some() || value.get("message").is_some())
        .unwrap_or_else(|| {
            let text = if ran.stderr.trim().is_empty() { &ran.stdout } else { &ran.stderr };
            json!({"code": "step.failed", "message": text.trim()})
        });
    Err(error)
}

/// The command that asks for this again, for a pending start or a person's answer.
pub(super) fn again_command(request: &Request, machine: &Machine) -> String {
    let mut words = vec!["cmux cloud start-chat".to_owned()];
    match machine {
        Machine::Named(name) => words.push(format!("--name {}", shell_quote(name))),
        Machine::Target(id) => words.push(format!("--target machine:{}", shell_quote(id))),
        Machine::New => {}
    }
    // A machine already made keeps the environment it has.
    if let Some(environment) =
        request.environment.as_ref().filter(|_| !matches!(machine, Machine::Target(_)))
    {
        words.push(format!("--environment {}", shell_quote(environment)));
    }
    if request.agent != "claude" {
        words.push(format!("--agent {}", request.agent));
    }
    if let Some(cwd) = &request.cwd {
        words.push(format!("--cwd {}", shell_quote(cwd)));
    }
    if let Some(login) = &request.login {
        words.push(format!("--login {login}"));
    }
    if let Some(prompt) = &request.prompt {
        words.push(format!("--prompt {}", shell_quote(prompt)));
    }
    if request.wait {
        words.push("--wait".to_owned());
    }
    words.push("--json".to_owned());
    words.join(" ")
}

/// One word for a POSIX shell.
pub(super) fn shell_quote(text: &str) -> String {
    if !text.is_empty()
        && text.chars().all(|ch| ch.is_ascii_alphanumeric() || "-_./:@=+,".contains(ch))
    {
        return text.to_owned();
    }
    format!("'{}'", text.replace('\'', "'\\''"))
}

/// Whether an app error is the cmux account being signed out. A harness's own sign-in (acpmux's `auth.*`
/// kinds, "Claude is not signed in here") is the machine's agent, never this account: `cmux cloud sign-in`
/// does not fix it, so it keeps its own error. Beside the codes, only the app's own refusal
/// (`CloudStrings.signInFirst`) is read from the message.
fn signed_out(error: &Value) -> bool {
    let code = at(error, "code").as_str().unwrap_or_default();
    let harness = |key: &str| at(error, key).as_str().is_some_and(|k| k.starts_with("auth."));
    if harness("errorKind")
        || harness("error_kind")
        || (code.starts_with("auth.") && code != "auth.required")
    {
        return false;
    }
    let message = at(error, "message").as_str().unwrap_or_default().to_lowercase();
    code.contains("signed_out")
        || code.contains("not_signed_in")
        || code == "auth.required"
        || message.contains("sign in to use cloud")
        || message.contains("cmux cloud sign-in")
}

/// Where a start the app answered `pending` for is stuck, read from the app's own machine list
/// (`cloud list-machines`, `CloudHandlers+List.swift`): the listed machine's status, or its
/// create still on the way (`creating` rows: `name`, `status` `creating` or `failed`, `reason`),
/// or neither. A machine that is listed and running is waiting on its link (the machine's
/// acpmux), not on the provider.
#[derive(Debug, Default, PartialEq)]
pub(super) struct StartStage {
    pub(super) machine_id: Option<String>,
    pub(super) status: Option<String>,
    pub(super) creating: bool,
    pub(super) listed: bool,
    /// Why the create failed, as the app's `creating` row says.
    pub(super) reason: Option<String>,
    /// The machine list could not be read.
    pub(super) unread: bool,
}

impl StartStage {
    /// The machine will not come up: asking again cannot help.
    pub(super) fn is_final(&self) -> bool {
        matches!(self.status.as_deref(), Some("failed" | "destroyed" | "deleting" | "deleted"))
    }

    pub(super) fn describe(&self) -> String {
        let base = match (self.listed, self.status.as_deref()) {
            (_, Some("failed")) if self.creating => "the machine's create failed".to_owned(),
            (_, Some("failed")) => "the machine failed".to_owned(),
            (true, Some("running")) => {
                "the machine is running; waiting for the link to its agent daemon".to_owned()
            }
            (true, Some(status)) => format!("the machine is {status}"),
            (true, None) => "the machine is listed with no status".to_owned(),
            (false, _) if self.creating => "the create request is still in flight".to_owned(),
            (false, _) if self.unread => {
                "unknown (the app's machine list could not be read)".to_owned()
            }
            (false, _) => "the machine is not in the app's machine list yet".to_owned(),
        };
        match &self.reason {
            Some(reason) => format!("{base}: {reason}"),
            None => base,
        }
    }

    fn json(&self) -> Value {
        json!({"describe": self.describe(), "machine_id": self.machine_id, "status": self.status,
               "creating": self.creating, "listed": self.listed, "reason": self.reason})
    }
}

/// Reads [`StartStage`] for the machine a pending `start-session` names (by id, else by name).
pub(super) fn start_stage(runner: &mut dyn Runner, started: &Value) -> StartStage {
    let id = at(started, "machine_id").as_str().map(str::to_owned);
    let name = at(started, "machine_name").as_str().map(str::to_owned);
    let Ok(listed) = step_result(&runner.cmux(&words(&["cloud", "list-machines", "--json"])))
    else {
        return StartStage { machine_id: id, unread: true, ..StartStage::default() };
    };
    let row = at(&listed, "machines").as_array().into_iter().flatten().find(|row| {
        id.as_deref().is_some_and(|id| at(row, "machine_id").as_str() == Some(id))
            || name.as_deref().is_some_and(|name| at(row, "title").as_str() == Some(name))
    });
    if let Some(row) = row {
        return StartStage {
            machine_id: at(row, "machine_id").as_str().map(str::to_owned).or(id),
            status: at(row, "status").as_str().map(str::to_owned),
            listed: true,
            // A failed machine's own error (`list-machines`' `error`), e.g. the VM API's machine cap.
            reason: at(row, "error").get("message").and_then(Value::as_str).map(str::to_owned),
            ..StartStage::default()
        };
    }
    // A create on its way names the machine it asks for; a nameless one (the server picks the
    // name) is this start's only when it is the only create on its way.
    let creations: Vec<&Value> = at(&listed, "creating").as_array().into_iter().flatten().collect();
    let creation = creations
        .iter()
        .find(|row| name.as_deref().is_some_and(|name| at(row, "name").as_str() == Some(name)))
        .or_else(|| match creations.as_slice() {
            [only] if at(only, "name").is_null() => Some(only),
            _ => None,
        });
    StartStage {
        machine_id: id,
        status: creation.and_then(|row| at(row, "status").as_str().map(str::to_owned)),
        creating: creation.is_some(),
        reason: creation.and_then(|row| at(row, "reason").as_str().map(str::to_owned)),
        ..StartStage::default()
    }
}

/// `--timeout` as one deadline from the command's start, for a `--wait` with a prompt (none otherwise: without a
/// turn to wait on, `--timeout` bounds nothing). Every step that does I/O or pauses checks it first and gets at
/// most what is left of it; a step that answers after it is a timeout, never a success.
#[derive(Clone, Copy, Debug)]
pub(super) struct Deadline(Option<Instant>);

impl Deadline {
    pub(super) fn of(request: &Request, began: Instant) -> Self {
        let bounded = request.wait && request.prompt.is_some();
        Self(bounded.then(|| began.checked_add(request.timeout).unwrap_or(began)))
    }

    /// What is left of it; `None` with no deadline.
    pub(super) fn left(self, runner: &mut dyn Runner) -> Option<Duration> {
        self.0.map(|end| end.saturating_duration_since(runner.now()))
    }

    pub(super) fn passed(self, runner: &mut dyn Runner) -> bool {
        self.left(runner).is_some_and(|left| left.is_zero())
    }

    /// `own`, or what is left when that is less.
    pub(super) fn bound(self, runner: &mut dyn Runner, own: Duration) -> Duration {
        self.left(runner).map_or(own, |left| left.min(own))
    }
}

/// The code an upload past the deadline fails with (`upload_prompt`): the caller answers it as a start out of time.
const OUT_OF_TIME: &str = "cloud.start_pending";

/// The deadline passed before the prompt was sent: nothing more starts or is sent, and `machine` (one made so far,
/// or the chat's) is there for the same ask again. `answer` holds the chat's ids once it started.
fn out_of_time(request: &Request, machine: &Machine, answer: Value) -> Outcome {
    let again = again_command(request, machine);
    let machine_id = if let Machine::Target(id) = machine { json!(id) } else { Value::Null };
    failed(
        OUT_OF_TIME,
        format!(
            "--timeout ({}s) ran out before the prompt was sent, so nothing was sent. Run it again: {again}",
            request.timeout.as_secs()
        ),
        json!({"again": again, "machine_id": machine_id, "answer": answer}),
        75,
    )
}

/// Runs the steps (module docs) and answers the outcome. An answer on a machine this run made itself says
/// `new_machine: true`: its own `cloud new-machine`, or a `start-session --name` of the fresh name no machine had. A
/// caller (the start matrix) may delete that machine as its own; no other answer is proof of that.
pub(super) fn run(runner: &mut dyn Runner, request: &Request) -> Outcome {
    let mut made = None;
    let mut outcome = steps(runner, request, &mut made);
    if let (Some(id), Outcome::Done(answer)) = (made.as_deref(), &mut outcome)
        && at(answer, "machine_id").as_str() == Some(id)
    {
        answer.set("new_machine", json!(true));
    }
    outcome
}

/// [`run`]'s steps; `made` is the machine id this run made, once it has one.
fn steps(runner: &mut dyn Runner, request: &Request, made: &mut Option<String>) -> Outcome {
    let began = runner.now();
    // `--timeout` is one deadline from here: the list, a new machine, the start, the relay, the upload, the send
    // and the wait each get what is left of it, never a `--timeout` of their own.
    let deadline = Deadline::of(request, began);
    // 1. Signed in, and the machine names in use.
    let listed = match step_result(&runner.cmux(&words(&["cloud", "list-machines", "--json"]))) {
        Ok(listed) => listed,
        Err(error) => return app_failure(error),
    };
    if listed.pointer("/account/signed_in") == Some(&Value::Bool(false)) {
        return failed(
            "cloud.signed_out",
            "cmux is signed out: run `cmux cloud sign-in`, then this command again",
            json!({"sign_in": "cmux cloud sign-in"}),
            1,
        );
    }
    // 2. The relay-first chat (cmuxterm-hq#7086): the prompt goes over HTTPS and down the socket the machine
    // holds from boot, with no link to the machine. Whatever kept it from the machine (an app or a machine
    // without the relay) leaves the link path below, on the machine it found or made.
    // A `--cwd` on a machine that already exists may be a repository its bootstrap is still cloning
    // (`cloud new-machine --repo`): wait for the clone rather than fail "cwd is not a directory" (folder.rs).
    let existing = match &request.machine {
        Machine::Target(id) => Some(id.clone()),
        Machine::Named(name) => at(&listed, "machines")
            .as_array()
            .into_iter()
            .flatten()
            .find(|row| at(row, "title").as_str() == Some(name.as_str()))
            .and_then(|row| at(row, "machine_id").as_str().map(str::to_owned)),
        Machine::New => None,
    };
    if let (Some(machine), Some(cwd)) = (existing, &request.cwd)
        && let Some(outcome) = folder::wait(runner, request, &machine, cwd, deadline, &listed)
    {
        return outcome;
    }
    let mut wanted = request.machine.clone();
    if request.environment.is_some() && deadline.passed(runner) {
        return out_of_time(request, &request.machine, Value::Null);
    }
    if let Some(environment) = &request.environment {
        match in_environment(runner, request, environment, &listed) {
            Ok(id) => {
                *made = Some(id.clone());
                wanted = Machine::Target(id);
            }
            Err(outcome) => return outcome,
        }
    }
    // No prompt: nothing to relay, so the chat starts over the link alone.
    if request.wait && request.prompt.is_some() {
        match relay_chat(runner, request, &wanted, &listed, deadline, made) {
            Relayed::Answered(outcome) => return outcome,
            Relayed::Fallback(Some(id)) => wanted = Machine::Target(id),
            Relayed::Fallback(None) => {}
        }
    }
    // The fresh name a new machine gets, when no listed machine has it: a start-session machine of that name is this run's.
    let mut fresh = None;
    let machine = match &wanted {
        Machine::New => {
            let taken = |name: &str| {
                at(&listed, "machines")
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|row| at(row, "title").as_str() == Some(name))
            };
            let mut name = runner.fresh_name();
            for _ in 0..3 {
                if !taken(&name) {
                    break;
                }
                name = runner.fresh_name();
            }
            fresh = (!taken(&name)).then(|| name.clone());
            Machine::Named(name)
        }
        other => other.clone(),
    };
    // A turn to wait on and no time left for it: nothing starts, and a machine made so far
    // is there for the same ask again.
    if deadline.passed(runner) {
        return out_of_time(request, &machine, Value::Null);
    }

    // 3. The machine and the chat, over the link.
    let mut start = vec!["cloud".to_owned(), "start-session".to_owned()];
    match &machine {
        Machine::Named(name) => start.extend(["--name".to_owned(), name.clone()]),
        Machine::Target(id) => start.extend(["--target".to_owned(), format!("machine:{id}")]),
        // Named above.
        Machine::New => {}
    }
    start.extend(["--agent".to_owned(), request.agent.clone()]);
    if let Some(cwd) = &request.cwd {
        start.extend(["--cwd".to_owned(), cwd.clone()]);
    }
    if let Some(login) = &request.login {
        start.extend(["--login".to_owned(), login.clone()]);
    }
    start.push("--json".to_owned());
    let started = match step_result(&runner.cmux(&start)) {
        Ok(started) => started,
        Err(error) => return start_refused(error, &listed, request),
    };
    if at(&started, "pending").as_bool() == Some(true) {
        let again = again_command(request, &machine);
        // Past the deadline the machine list is not read for the stage.
        let stage = if deadline.passed(runner) {
            StartStage {
                machine_id: at(&started, "machine_id").as_str().map(str::to_owned),
                unread: true,
                reason: Some("--timeout ran out before it was read".to_owned()),
                ..StartStage::default()
            }
        } else {
            start_stage(runner, &started)
        };
        let capped = stage
            .reason
            .as_deref()
            .filter(|_| stage.is_final())
            .and_then(|why| cap::cap_of("", why));
        if let Some(found) = capped {
            let why = stage.reason.as_deref().unwrap_or_default();
            let (message, details) = cap::at_cap(found, why, &listed, |id| {
                again_command(request, &Machine::Target(id.to_owned()))
            });
            return failed("cloud.machine_cap", message, details, 1);
        }
        if stage.is_final() {
            return failed(
                "cloud.start_failed",
                format!(
                    "the machine failed to start ({}); running the command again will not help. \
                     Start a new one: {}",
                    stage.describe(),
                    again_command(request, &Machine::New)
                ),
                json!({"stage": stage.json(), "machine_name": at(&started, "machine_name"),
                       "machine_id": stage.machine_id.map_or_else(|| at(&started, "machine_id").clone(), Value::String),
                       "app": at(&started, "text")}),
                1,
            );
        }
        return failed(
            "cloud.start_pending",
            format!(
                "the machine is still starting (stuck at: {}); the chat opens in its workspace when it is up. \
                 Run the same command again to keep waiting: {again}",
                stage.describe()
            ),
            json!({"again": again, "machine_name": at(&started, "machine_name"),
                   "machine_id": stage.machine_id.clone().map_or_else(|| at(&started, "machine_id").clone(), Value::String),
                   "stage": stage.json(), "app": at(&started, "text")}),
            75,
        );
    }
    let (Some(machine_id), Some(session)) =
        (at(&started, "machine_id").as_str(), at(&started, "session_id").as_str())
    else {
        return failed(
            "cloud.start_incomplete",
            "cloud start-session answered without a machine_id and session_id",
            json!({"answer": started}),
            1,
        );
    };
    if fresh.is_some() && at(&started, "machine_name").as_str() == fresh.as_deref() {
        *made = Some(machine_id.to_owned());
    }
    let mut answer = json!({
        "machine_id": machine_id,
        "machine_name": at(&started, "machine_name"),
        "target": format!("machine:{machine_id}"),
        "session_id": session,
        "workspace_id": at(&started, "workspace_id"),
        "tab_id": at(&started, "tab_id"),
        "host": at(&started, "host"),
        "agent": request.agent,
        "follow_up": follow_ups(machine_id, session),
    });

    let Some(prompt) = request.prompt.as_deref() else {
        // No prompt: the chat is ready once start-session returned; `--wait` has no turn to wait on.
        let ready_ms = runner.now().saturating_duration_since(began).as_millis();
        answer.set("sent", json!(false));
        answer.set("ready_ms", json!(u64::try_from(ready_ms).unwrap_or(u64::MAX)));
        return Outcome::Done(answer);
    };
    // start-session answered after the deadline: the chat is there, and nothing is sent to it.
    let chat = Machine::Target(machine_id.to_owned());
    if deadline.passed(runner) {
        return out_of_time(request, &chat, answer);
    }
    // 4. The prompt: inside the command when it fits there, else from a file on the machine.
    let quoted = shell_quote(prompt);
    // The uploaded prompt's file words, when the prompt went to a file.
    let mut uploaded = None;
    let send = if quoted.len() <= INLINE_PROMPT_BYTES {
        format!(
            "{GUEST_PRELUDE}echo @@history; \"$c\" acp history {sid} --json -n 1 2>&1; echo @@send; \
             printf '%s' {quoted} | \"$c\" acp send --no-wait {sid} - 2>&1; echo \"@@exit $?\"",
            sid = shell_quote(session),
        )
    } else {
        let file = match upload_prompt(runner, machine_id, session, prompt.as_bytes(), deadline) {
            Ok(file) => file,
            Err(error) if at(&error, "code").as_str() == Some(OUT_OF_TIME) => {
                return out_of_time(request, &chat, answer);
            }
            Err(error) => {
                return failed(
                    "chat.send_failed",
                    format!(
                        "the chat started, but the prompt did not reach its machine: {}",
                        at(&error, "message").as_str().unwrap_or("cloud exec failed")
                    ),
                    json!({"answer": answer, "app": error}),
                    1,
                );
            }
        };
        // The last piece answered after the deadline: the file stays unsent (it is this run's own, mode 0600).
        if deadline.passed(runner) {
            return out_of_time(request, &chat, answer);
        }
        uploaded = Some(file.clone());
        format!(
            "{GUEST_PRELUDE}{file}echo @@history; \"$c\" acp history {sid} --json -n 1 2>&1; \
             echo @@send; \"$c\" acp send --no-wait {sid} - < \"$f\" 2>&1; echo \"@@exit $?\"; \
             rm -f \"$f\"",
            sid = shell_quote(session),
        )
    };
    let sent = match exec(runner, machine_id, &send) {
        Ok(stdout) => stdout,
        Err(error) => {
            // Refused before it started: the uploaded prompt does not stay on the machine. Any other
            // failure (no answer) may be a send still reading the file, so the file stays.
            if let Some(file) = uploaded.as_ref().filter(|_| refused_before_start(&error)) {
                let _ = exec(runner, machine_id, &format!("{GUEST_PRELUDE}{file}rm -f \"$f\""));
            }
            return sent_failure(error, answer);
        }
    };
    let reported = sections(&sent);
    let baseline = last_turn(reported.get("history")).map_or(0, |turn| turn.seq);
    if reported.get("exit").map(String::as_str).map(str::trim) != Some("0") {
        let output = reported.get("send").cloned().unwrap_or_default();
        return failed(
            "chat.send_failed",
            format!("the chat started, but the prompt did not reach it: {}", output.trim()),
            json!({"answer": answer}),
            1,
        );
    }
    answer.set("sent", json!(true));
    if let Some(delivery) = reported.get("send").map(|text| text.trim()).filter(|t| !t.is_empty()) {
        answer.set("delivery", json!(delivery));
    }
    if !request.wait {
        return Outcome::Done(answer);
    }
    wait_turn(runner, request, machine_id, session, baseline, answer, deadline)
}

/// 5. The turn after `baseline` in `session`: its end and its reply.
fn wait_turn(
    runner: &mut dyn Runner,
    request: &Request,
    machine_id: &str,
    session: &str,
    baseline: u64,
    mut answer: Value,
    deadline: Deadline,
) -> Outcome {
    loop {
        // Each wait is bounded by exec's own limit and by what is left of `--timeout`, in whole seconds: with
        // less than one left (the steps before spent it), no wait past the deadline.
        let slice = deadline.bound(runner, Duration::from_secs(WAIT_SLICE_SECONDS)).as_secs();
        if slice == 0 {
            return wait_timeout(request, machine_id, session, answer);
        }
        let poll = format!(
            "{GUEST_PRELUDE}\"$c\" acp wait {sid} --timeout {slice} >/dev/null 2>&1; \
             echo \"@@wait $?\"; echo @@history; \"$c\" acp history {sid} --json -n 1 2>&1; \
             echo @@last; \"$c\" acp last {sid} --json 2>&1; echo \"@@lastexit $?\"",
            sid = shell_quote(session),
        );
        let polled = match exec(runner, machine_id, &poll) {
            Ok(stdout) => stdout,
            Err(error) => return sent_failure(error, answer),
        };
        let polled = sections(&polled);
        let turn = last_turn(polled.get("history")).filter(|turn| turn.seq > baseline);
        if let Some(turn) = turn.as_ref().filter(|turn| turn.ended) {
            answer.set("turn", turn.value.clone());
            let read = polled.get("lastexit").map(|code| code.trim()) == Some("0");
            let Some(text) = reply(polled.get("last")).filter(|_| read) else {
                return failed(
                    "chat.read_failed",
                    "the turn ended, but its reply could not be read; read it with the \
                     answer's follow_up.last",
                    json!({"answer": answer, "output": polled.get("last")}),
                    1,
                );
            };
            answer.set("reply", json!(text));
            if turn.failed() {
                return Outcome::Failed {
                    error: json!({"code": "chat.turn_failed",
                                  "message": format!("the turn ended {}", turn.status),
                                  "details": answer, "retryable": false}),
                    exit: 1,
                };
            }
            return Outcome::Done(answer);
        }
        // `acp wait` exits 0 (ended), 2 (a permission) or 3 (its own timeout); anything else
        // (the session gone, acpmux down) with no readable turn is not work still running.
        let waited = polled.get("wait").map(|code| code.trim().to_owned()).unwrap_or_default();
        if turn.is_none()
            && !matches!(waited.as_str(), "0" | "2" | "3")
            && last_turn(polled.get("history")).is_none()
        {
            return failed(
                "chat.lost",
                format!(
                    "the chat's session on the machine does not answer (acp wait exit {waited})"
                ),
                json!({"answer": answer, "history": polled.get("history")}),
                1,
            );
        }
        if waited == "2" {
            return failed(
                "chat.permission_waiting",
                "the agent asks for a permission: answer it in the chat's tab in the cmux app, \
                 then wait with the follow-up commands",
                json!({"answer": answer}),
                2,
            );
        }
        if deadline.passed(runner) {
            return wait_timeout(request, machine_id, session, answer);
        }
        if turn.is_none() {
            let pause = deadline.bound(runner, NOT_STARTED_PAUSE);
            runner.pause(pause);
        }
    }
}

fn wait_timeout(request: &Request, machine_id: &str, session: &str, answer: Value) -> Outcome {
    failed(
        "chat.wait_timeout",
        format!(
            "the turn is still running after {}s; wait on with: cmux cloud exec \
             --target machine:{machine_id} --command '{GUEST_CMUX} acp wait {session} \
             --timeout {WAIT_SLICE_SECONDS}'",
            request.timeout.as_secs()
        ),
        json!({"answer": answer}),
        3,
    )
}

/// What the relay-first chat came to.
enum Relayed {
    /// The command's answer: the reply, a failure, or a turn the link path waits on.
    Answered(Outcome),
    /// Nothing reached the machine: the link path runs, on this machine when there is one.
    Fallback(Option<String>),
}

/// The largest prompt the relay chat takes as an argument (Linux takes 128 KiB per argument; the platform
/// 256 KiB). A larger one goes the link path, which uploads it.
const RELAY_PROMPT_BYTES: usize = 96 * 1024;

fn relay_chat(
    runner: &mut dyn Runner,
    request: &Request,
    machine: &Machine,
    listed: &Value,
    deadline: Deadline,
    made: &mut Option<String>,
) -> Relayed {
    let Some(prompt) = request.prompt.as_deref().filter(|p| p.len() <= RELAY_PROMPT_BYTES) else {
        return Relayed::Fallback(None);
    };
    let machine_id = match machine {
        Machine::Target(id) => id.clone(),
        Machine::Named(name) => {
            let row = at(listed, "machines")
                .as_array()
                .into_iter()
                .flatten()
                .find(|row| at(row, "title").as_str() == Some(name.as_str()));
            match row.and_then(|row| at(row, "machine_id").as_str()) {
                Some(id) => id.to_owned(),
                // A name no machine has yet: `cloud start-session --name` makes it.
                None => return Relayed::Fallback(None),
            }
        }
        // No time left to make one: the start below says so.
        Machine::New if deadline.passed(runner) => return Relayed::Fallback(None),
        Machine::New => match new_machine(runner, request, listed, &[]) {
            Ok(id) => {
                *made = Some(id.clone());
                id
            }
            Err(outcome) => return Relayed::Answered(outcome),
        },
    };
    let mut args = words(&["cloud", "relay-chat", "--target"]);
    args.push(format!("machine:{machine_id}"));
    args.extend(["--agent".to_owned(), request.agent.clone()]);
    args.extend(["--prompt".to_owned(), prompt.to_owned()]);
    if let Some(cwd) = &request.cwd {
        args.extend(["--cwd".to_owned(), cwd.clone()]);
    }
    if let Some(login) = &request.login {
        args.extend(["--login".to_owned(), login.clone()]);
    }
    args.extend(["--prompt-id".to_owned(), runner.prompt_id()]);
    args.push("--json".to_owned());
    // The app may take its whole answer window: with less of `--timeout` left, the link path keeps to it.
    if deadline.bound(runner, RELAY_ANSWER_WINDOW) < RELAY_ANSWER_WINDOW {
        return Relayed::Fallback(Some(machine_id));
    }
    let relayed = match step_result(&runner.cmux(&args)) {
        Ok(relayed) => relayed,
        Err(error) if signed_out(&error) => return Relayed::Answered(app_failure(error)),
        // An app without the action ran nothing.
        Err(error) if lacks_action(&error) => return Relayed::Fallback(Some(machine_id)),
        // Anything else (a broken connection, a late answer) may have reached the machine: sending it again could
        // run it twice, so say so instead.
        Err(error) => {
            let message = at(&error, "message").as_str().unwrap_or("the relay chat failed");
            return Relayed::Answered(failed(
                "chat.relay_failed",
                format!(
                    "the relay chat failed, and the prompt may have reached the machine, so it was not sent again: \
                     {message}. See its sessions with: cmux cloud exec --target machine:{machine_id} --command \
                     '{GUEST_CMUX} acp ls'"
                ),
                json!({"machine_id": machine_id, "app": error}),
                1,
            ));
        }
    };
    // The app gave the machine no usable login before the send (`cloud.relay.login_*`): the link path would only
    // reach the same signed-out agent, so the app's typed answer and its recovery command are the outcome.
    let undelivered = at(&relayed, "delivered").as_bool() == Some(false);
    if let Some(code) = at(&relayed, "error_code")
        .as_str()
        .filter(|code| undelivered && code.starts_with(RELAY_LOGIN_CODES))
    {
        let message =
            at(&relayed, "error_message").as_str().unwrap_or("the machine has no login").to_owned();
        let exit = if code == "cloud.relay.login_pending" { 75 } else { 1 };
        return Relayed::Answered(failed(
            code,
            message,
            json!({"machine_id": machine_id, "command": at(&relayed, "command"),
                   "login_reason": at(&relayed, "login_reason"), "sent": false}),
            exit,
        ));
    }
    // Certainly never on the machine (the relay refused it, no machine took it, an image without the relay): the
    // link path sends it.
    if at(&relayed, "delivered").as_bool() == Some(false) {
        return Relayed::Fallback(Some(machine_id));
    }
    let error_code = at(&relayed, "error_code").as_str();
    let Some(session) = at(&relayed, "session_id").as_str() else {
        // On its way to the machine, but no session yet: it failed there, or it is still starting.
        let (code, message, exit) = match error_code {
            Some(code) => (
                code.to_owned(),
                at(&relayed, "error_message").as_str().unwrap_or("the chat failed").to_owned(),
                1,
            ),
            None => (
                "chat.relay_pending".to_owned(),
                format!(
                    "the chat is on its way to the machine or waiting for it, and has not started yet; do not \
                     send it again. See its sessions with: cmux cloud exec --target machine:{machine_id} \
                     --command '{GUEST_CMUX} acp ls'"
                ),
                75,
            ),
        };
        return Relayed::Answered(failed(
            &code,
            message,
            json!({"machine_id": machine_id, "relay": relayed, "error": typed_error(&relayed)}),
            exit,
        ));
    };
    let mut answer = json!({
        "machine_id": machine_id,
        "target": format!("machine:{machine_id}"),
        "session_id": session,
        "agent": request.agent,
        "path": "relay",
        "queued": at(&relayed, "queued"),
        "first_text_ms": at(&relayed, "first_text_ms"),
        "follow_up": follow_ups(&machine_id, session),
        "sent": true,
    });
    // The relay answered after the deadline: the turn is on the machine, and its answer is a timeout, not a reply.
    if deadline.passed(runner) {
        return Relayed::Answered(wait_timeout(request, &machine_id, session, answer));
    }
    if at(&relayed, "ended").as_bool() != Some(true) {
        // Still running after the app's answer: the link path waits on the session (a new one, so no turn before).
        return Relayed::Answered(wait_turn(
            runner,
            request,
            &machine_id,
            session,
            0,
            answer,
            deadline,
        ));
    }
    answer.set("reply", at(&relayed, "reply").clone());
    answer.set("total_ms", at(&relayed, "total_ms").clone());
    let Some(code) = error_code else {
        answer.set("stop_reason", at(&relayed, "stop_reason").clone());
        return Relayed::Answered(Outcome::Done(answer));
    };
    let exit = match code {
        "chat.permission_waiting" => 2,
        "chat.timeout" | "cloud.relay.timeout" => 3,
        _ => 1,
    };
    let message = at(&relayed, "error_message").as_str().unwrap_or("the turn failed").to_owned();
    Relayed::Answered(failed(
        code,
        message,
        json!({"answer": answer, "error": typed_error(&relayed)}),
        exit,
    ))
}

/// `--environment`: the chat's machine, made first in that environment (`--name`'s name when no machine
/// has it yet); its id. A machine that exists already has its environment, so that is a usage error. The
/// name is made only on a list the app loaded (`loaded: false` lists no machines, which says nothing) with no
/// create of it on its way: one in flight answers pending, one that failed (it waits in cmux for Retry) is
/// refused, so a rerun or a second start never makes a second machine of that name.
fn in_environment(
    runner: &mut dyn Runner,
    request: &Request,
    environment: &str,
    listed: &Value,
) -> Result<String, Outcome> {
    let machine = &request.machine;
    let mut extra = Vec::new();
    if let Machine::Named(name) = machine {
        if at(listed, "loaded").as_bool() == Some(false) {
            return Err(failed(
                "cloud.list_unread",
                format!(
                    "the app has not loaded its Cloud machines yet, so no machine was made in the environment: \
                     one named {name} may exist already. Run this command again in a moment"
                ),
                json!({"machine_name": name, "list": "cmux cloud list-machines --json"}),
                75,
            ));
        }
        let creation = at(listed, "creating")
            .as_array()
            .into_iter()
            .flatten()
            .find(|row| at(row, "name").as_str() == Some(name.as_str()));
        if let Some(creation) = creation {
            let details = json!({"machine_name": name, "creation": creation,
                                 "list": "cmux cloud list-machines --json"});
            if at(creation, "status").as_str() == Some("failed") {
                let reason = at(creation, "reason").as_str().unwrap_or("no reason given");
                return Err(failed(
                    "cloud.start_failed",
                    format!(
                        "the create of {name} failed ({reason}) and waits in cmux for Retry, so no second one \
                         was made: retry or dismiss it there, or give a new --name"
                    ),
                    details,
                    1,
                ));
            }
            return Err(failed(
                "cloud.start_pending",
                format!(
                    "a machine named {name} is still being made, so no second one was made; find it with \
                     `cmux cloud list-machines`, then run this command again with --target machine:ID"
                ),
                details,
                75,
            ));
        }
        let mut rows = at(listed, "machines").as_array().into_iter().flatten();
        if rows.any(|row| at(row, "title").as_str() == Some(name.as_str())) {
            return Err(failed(
                "usage.invalid",
                format!(
                    "--environment makes a new machine, and {name} exists already: give a new --name, \
                     or leave out --environment"
                ),
                json!({"machine_name": name}),
                2,
            ));
        }
        extra.extend(["--name".to_owned(), name.clone()]);
    }
    extra.extend(["--environment".to_owned(), environment.to_owned()]);
    new_machine(runner, request, listed, &extra)
}

/// `cloud new-machine` with `extra`: the new machine's id once the app has it.
fn new_machine(
    runner: &mut dyn Runner,
    request: &Request,
    listed: &Value,
    extra: &[String],
) -> Result<String, Outcome> {
    let mut args = words(&["cloud", "new-machine"]);
    args.extend_from_slice(extra);
    args.push("--json".to_owned());
    let made =
        step_result(&runner.cmux(&args)).map_err(|error| start_refused(error, listed, request))?;
    match at(&made, "machine_id").as_str() {
        Some(id) if at(&made, "pending").as_bool() != Some(true) => Ok(id.to_owned()),
        _ => Err(failed(
            "cloud.start_pending",
            "the new machine is still being made; find it with `cmux cloud list-machines`, \
             then run this command again with --target machine:ID",
            json!({"app": made, "list": "cmux cloud list-machines --json"}),
            75,
        )),
    }
}

/// The machine's typed error the app relayed (`CloudStartSession.relayFields`): acpmux's detail, a closed
/// daemon's cause, the error's kind, what to do and whether a retry may work; only the fields the app sent.
fn typed_error(relayed: &Value) -> Value {
    let mut typed = serde_json::Map::new();
    for (from, to) in [
        ("error_detail", "detail"),
        ("error_cause", "cause"),
        ("error_kind", "kind"),
        ("error_recovery", "recovery"),
    ] {
        if let Some(text) = at(relayed, from).as_str() {
            typed.insert(to.to_owned(), json!(text));
        }
    }
    if let Some(retryable) = at(relayed, "error_retryable").as_bool() {
        typed.insert("retryable".to_owned(), json!(retryable));
    }
    Value::Object(typed)
}

/// The app's `cloud relay-chat` refusals about the machine's harness login (refused, missing, declined, failed,
/// pending, account changed, skipped, unverified): nothing was sent, and nothing else is. Each answer carries the
/// start-session command that recovers it.
const RELAY_LOGIN_CODES: &str = "cloud.relay.login_";

/// The app has no `cloud relay-chat` (an older app): the CLI's own usage error, or the app's unknown action.
fn lacks_action(error: &Value) -> bool {
    let code = at(error, "code").as_str().unwrap_or_default();
    code.starts_with("usage.") || code == "action.not_found"
}

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

/// The commands that go on with this chat.
fn follow_ups(machine: &str, session: &str) -> Value {
    let on = |command: String| {
        format!("cmux cloud exec --target machine:{machine} --command {}", shell_quote(&command))
    };
    json!({
        "send": on(format!("{GUEST_CMUX} acp send --no-wait {session} 'PROMPT'")),
        "wait": on(format!("{GUEST_CMUX} acp wait {session} --timeout {WAIT_SLICE_SECONDS}")),
        "last": on(format!("{GUEST_CMUX} acp last {session}")),
    })
}

/// `cloud exec` of `script` on the machine: its stdout, or the error.
fn exec(runner: &mut dyn Runner, machine: &str, script: &str) -> Result<String, Value> {
    let args = vec![
        "cloud".to_owned(),
        "exec".to_owned(),
        "--target".to_owned(),
        format!("machine:{machine}"),
        "--command".to_owned(),
        script.to_owned(),
        "--json".to_owned(),
    ];
    let result = step_result(&runner.cmux(&args))?;
    Ok(at(&result, "stdout").as_str().unwrap_or_default().to_owned())
}

/// The shell words that set `f` to the prompt file `name` on the machine (after
/// [`GUEST_PRELUDE`], which sets `HOME`): `f=...; `.
fn prompt_file(name: &str) -> String {
    let name: String = name
        .chars()
        .map(|ch| if ch.is_ascii_alphanumeric() || "-_.".contains(ch) { ch } else { '_' })
        .collect();
    format!("f=\"$HOME/.cmux/prompts/\"{}; ", shell_quote(&format!("{name}.prompt")))
}

/// Whether a `cloud exec` was refused before its command started: the machine busy, stopped or
/// gone, the caller not allowed, or the command too long.
fn refused_before_start(error: &Value) -> bool {
    let code = at(error, "code").as_str().unwrap_or_default();
    matches!(code, "vm_busy" | "vm_not_running" | "vm_not_found" | "vm_forbidden")
        || command_too_long(error)
}

/// Whether a refused `cloud exec` was refused for its command's length (nothing of it ran).
fn command_too_long(error: &Value) -> bool {
    let code = at(error, "code").as_str().unwrap_or_default().to_lowercase();
    let message = at(error, "message").as_str().unwrap_or_default().to_lowercase();
    code.contains("too_large")
        || code.contains("too_long")
        || message.contains("too large")
        || message.contains("too long")
        || message.contains("command is over")
        || message.contains("413")
}

/// Writes `prompt` to the session's prompt file on the machine (0600, in the work user's
/// `~/.cmux/prompts`, a file of this upload's own), one `cloud exec` per piece, each piece's base64 decoded there and
/// appended. There is no limit on the prompt: a route that refuses a large piece as too long a
/// command gets small ones, as many as it takes. Answers the [`prompt_file`] words for the send.
pub(super) fn upload_prompt(
    runner: &mut dyn Runner,
    machine: &str,
    session: &str,
    prompt: &[u8],
    deadline: Deadline,
) -> Result<String, Value> {
    use base64::Engine as _;
    // A file of this upload's own: two starts can share a session id, and neither may send the other's text.
    let file = prompt_file(&format!("{session}-{}", uuid::Uuid::new_v4().simple()));
    let mut piece = PROMPT_PIECE_BYTES;
    let mut sent = 0;
    while sent < prompt.len() {
        // No piece past the deadline; the pieces so far stay in this run's own file (mode 0600), never sent.
        if deadline.passed(runner) {
            return Err(
                json!({"code": OUT_OF_TIME, "message": "--timeout ran out during the prompt's upload"}),
            );
        }
        let end = sent.saturating_add(piece).min(prompt.len());
        let chunk = prompt.get(sent..end).unwrap_or_default();
        let encoded = base64::engine::general_purpose::STANDARD.encode(chunk);
        // The first piece starts the file over: a retry of this run's upload never appends twice.
        let start = if sent == 0 { ": > \"$f\" && " } else { "" };
        let script = format!(
            "{GUEST_PRELUDE}umask 077; mkdir -p \"$HOME/.cmux/prompts\" && {file}{start}\
             printf '%s' '{encoded}' | base64 -d >> \"$f\" && echo \"@@size $(wc -c < \"$f\")\""
        );
        let stdout = match exec(runner, machine, &script) {
            Ok(stdout) => stdout,
            Err(error) if command_too_long(&error) && piece > SMALL_PROMPT_PIECE_BYTES => {
                piece = SMALL_PROMPT_PIECE_BYTES;
                continue;
            }
            Err(error) => {
                let _ = exec(runner, machine, &format!("{GUEST_PRELUDE}{file}rm -f \"$f\""));
                return Err(error);
            }
        };
        let size = sections(&stdout).get("size").and_then(|size| size.trim().parse::<usize>().ok());
        if size != Some(end) {
            let _ = exec(runner, machine, &format!("{GUEST_PRELUDE}{file}rm -f \"$f\""));
            return Err(json!({
                "code": "chat.upload_failed",
                "message": format!(
                    "the prompt file on the machine holds {} bytes after {end} were sent",
                    size.map_or_else(|| "an unknown number of".to_owned(), |size| size.to_string())
                ),
            }));
        }
        sent = end;
    }
    Ok(file)
}

/// A failure of a step before the chat existed.
fn app_failure(error: Value) -> Outcome {
    let message = at(&error, "message").as_str().unwrap_or("the cmux app refused").to_owned();
    if signed_out(&error) {
        return failed(
            "cloud.signed_out",
            format!("{message} (run `cmux cloud sign-in`, then this command again)"),
            json!({"sign_in": "cmux cloud sign-in", "app": error}),
            1,
        );
    }
    // An agent chat's start asks nobody (`cloud.agentsStartWithoutAsking`, on by default), so a
    // refusal here is the app's own; when the person turned asking back on, the app's refusal (Not
    // now, or no answer) already names the command to run again.
    let details = json!({"app": error});
    let code = at(&error, "code").as_str().unwrap_or("cloud.start_failed").to_owned();
    failed(&code, message, details, 1)
}

/// A start the app refused: a machine cap names the account's machines and the commands that
/// make room ([`cap`]); any other refusal is [`app_failure`].
fn start_refused(error: Value, listed: &Value, request: &Request) -> Outcome {
    let code = at(&error, "code").as_str().unwrap_or_default();
    let message = at(&error, "message").as_str().unwrap_or_default();
    match cap::cap_of(code, message) {
        Some(found) if !signed_out(&error) => {
            let (text, mut details) = cap::at_cap(found, message, listed, |id| {
                again_command(request, &Machine::Target(id.to_owned()))
            });
            if let Some(fields) = details.as_object_mut() {
                fields.insert("app".to_owned(), error);
            }
            failed("cloud.machine_cap", text, details, 1)
        }
        _ => app_failure(error),
    }
}

/// A failure after the chat started: the answer so far goes with it.
fn sent_failure(error: Value, answer: Value) -> Outcome {
    let message = at(&error, "message").as_str().unwrap_or("cloud exec failed");
    failed(
        "chat.unreachable",
        format!("the chat started, but its machine did not answer: {message}"),
        json!({"answer": answer, "app": error}),
        1,
    )
}

/// The `@@name` sections a step's script printed: `@@exit 0` is the section `exit` with `0`.
pub(super) fn sections(stdout: &str) -> std::collections::HashMap<String, String> {
    let mut out = std::collections::HashMap::new();
    let mut current: Option<String> = None;
    for line in stdout.lines() {
        if let Some(header) = line.strip_prefix("@@") {
            let (name, rest) = header.split_once(' ').unwrap_or((header, ""));
            out.insert(name.to_owned(), rest.to_owned());
            current = Some(name.to_owned());
            continue;
        }
        if let Some(name) = &current {
            let text: &mut String = out.entry(name.clone()).or_default();
            if !text.is_empty() {
                text.push('\n');
            }
            text.push_str(line);
        }
    }
    out
}

/// The newest turn `acp history --json` lists.
#[derive(Debug, PartialEq)]
pub(super) struct Turn {
    pub seq: u64,
    pub ended: bool,
    pub status: String,
    pub value: Value,
}

impl Turn {
    /// A turn that ended without its reply: failed, cancelled or of unknown outcome.
    pub(super) fn failed(&self) -> bool {
        matches!(self.status.as_str(), "failed" | "error" | "cancelled" | "outcome_unknown")
            || self.value.get("error").is_some_and(|error| !error.is_null())
    }
}

pub(super) fn last_turn(history: Option<&String>) -> Option<Turn> {
    let value: Value = serde_json::from_str(history?.trim()).ok()?;
    let turn = at(&value, "turns").as_array()?.last()?.clone();
    Some(Turn {
        seq: at(&turn, "seq").as_u64().unwrap_or(0),
        ended: turn.get("endedAt").is_some_and(|at| !at.is_null()),
        status: at(&turn, "status").as_str().unwrap_or("completed").to_owned(),
        value: turn,
    })
}

/// The newest reply `acp last --json` printed (`{"sessionId", "replies": [...]}`).
pub(super) fn reply(last: Option<&String>) -> Option<String> {
    let value: Value = serde_json::from_str(last?.trim()).ok()?;
    at(&value, "replies").as_array()?.last()?.as_str().map(str::to_owned)
}

/// Prints the outcome and answers the exit code.
fn report(outcome: &Outcome, output: OutputMode) -> i32 {
    match outcome {
        Outcome::Failed { error, exit } => super::wire::print_local_error(error, output, *exit),
        Outcome::Done(answer) if output == OutputMode::Human => {
            match at(answer, "reply").as_str() {
                // Text from the machine: no terminal controls reach this terminal.
                Some(reply) => println!("{}", super::wire::sanitize_remote_text(reply)),
                None => println!(
                    "{} {} on {} (machine:{}).",
                    if at(answer, "sent").as_bool() == Some(false) { "Started" } else { "Sent to" },
                    at(answer, "session_id").as_str().unwrap_or_default(),
                    at(answer, "machine_name").as_str().unwrap_or_default(),
                    at(answer, "machine_id").as_str().unwrap_or_default()
                ),
            }
            eprintln!(
                "machine_id {}  session_id {}  tab_id {}",
                at(answer, "machine_id").as_str().unwrap_or_default(),
                at(answer, "session_id").as_str().unwrap_or_default(),
                at(answer, "tab_id").as_str().unwrap_or_default()
            );
            0
        }
        Outcome::Done(answer) => super::wire::print_local_success(answer, output),
    }
}

/// `value[key]` without indexing: `Null` when absent.
fn at<'a>(value: &'a Value, key: &str) -> &'a Value {
    const NULL: &Value = &Value::Null;
    value.get(key).unwrap_or(NULL)
}

mod cap;
mod folder;

#[cfg(test)]
pub(in crate::cli) mod tests;
