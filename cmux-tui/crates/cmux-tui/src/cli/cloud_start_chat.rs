//! `cmux cloud start-chat --prompt TEXT [--agent claude] [--cwd DIR] [--name MACHINE |
//! --target machine:ID] [--wait] [--timeout SECONDS]`: one command takes a Cloud chat from
//! nothing to a reply, for a person, a script or the Chief (Leo, 2026-11-02: "we need to improve
//! the docs/instructions/commands and guidance and whatnot to make this all smoother faster more
//! efficient more exposed / cuz chief will be using this kind of flow").
//!
//! It runs the app's own verbs in turn, each as this binary with `--json`, so every step keeps
//! that verb's checks, keys and deadlines:
//!
//! 1. `cloud list-machines`: refuses at once when the app is signed out of cmux.
//! 2. `cloud start-session (--name N | --target T) --agent A [--cwd D]`: takes the machine (or
//!    creates it) and opens the chat's tab in the machine's workspace, a real chat in the app.
//!    Without `--name` or `--target` it creates a new small machine with a new name, so the chat
//!    never lands on a machine another workspace uses (leo-workspace `design/cloud.md`, "One
//!    workspace per small machine").
//! 3. `cloud exec` on that machine: hands the prompt to the chat's session in the machine's own
//!    acpmux (`cmux-tui acp send --no-wait`), which the chat's tab shows like any send.
//! 4. With `--wait`, `cloud exec` again until the turn ends (`cmux-tui acp wait`, under the
//!    exec's own 25 s limit each time), then the turn's last reply (`cmux-tui acp last`).
//!
//! Output: one JSON object (`--json`): the reply text with `machine_id`, `session_id`,
//! `workspace_id`, `tab_id`, `surface_id` and the follow-up commands. A failure names what
//! to do next: sign in, run the same command again for a machine still starting, or answer
//! the question the app is asking the person.

use std::io::Read as _;
use std::process::Command as Process;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode, UsageError};


/// The longest `--wait` takes by default, and at most.
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(900);
const MAX_TIMEOUT: Duration = Duration::from_secs(4 * 60 * 60);
/// `cmux-tui acp wait`'s own timeout inside one `cloud exec` (the exec stops after 25 s).
const WAIT_SLICE_SECONDS: u64 = 20;
/// The pause before asking again when the machine's acpmux had not started the turn yet.
const NOT_STARTED_PAUSE: Duration = Duration::from_secs(2);
/// The machine's own binary: the guest `cmux` wrapper takes no `acp`.
const GUEST_CMUX: &str = "cmux-tui";

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
    pub prompt: String,
    pub agent: String,
    pub cwd: Option<String>,
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
    let mut words = Vec::new();
    for word in rest {
        match word.as_str() {
            "--json" => global.output = OutputMode::Json,
            "--jsonl" => global.output = OutputMode::JsonLines,
            "--quiet" => global.output = OutputMode::Quiet,
            _ => words.push(word.clone()),
        }
    }
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

/// The words after `cloud start-chat`. `stdin` reads the prompt for `--prompt -`.
pub(super) fn parse(
    words: &[String],
    stdin: impl FnOnce() -> Result<String, String>,
) -> Result<Parsed, UsageError> {
    let mut prompt = None;
    let mut agent = None;
    let mut cwd = None;
    let mut name = None;
    let mut target = None;
    let mut wait = false;
    let mut timeout = DEFAULT_TIMEOUT;
    let mut index = 0;
    while index < words.len() {
        let word = words[index].as_str();
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
            "--name" => name = Some(value()?),
            "--target" => target = Some(value()?),
            "--timeout" => {
                let text = value()?;
                let seconds = text
                    .parse::<u64>()
                    .ok()
                    .filter(|seconds| *seconds > 0)
                    .ok_or_else(|| UsageError::new(format!("--timeout {text}: give seconds")))?;
                timeout = Duration::from_secs(seconds).min(MAX_TIMEOUT);
            }
            "--wait" => wait = true,
            "--no-wait" => wait = false,
            _ => return Err(UsageError::new(format!("unexpected argument {word:?}"))),
        }
        index += 1;
    }
    let prompt = match prompt.as_deref() {
        Some("-") => stdin().map_err(|error| UsageError::new(format!("--prompt -: {error}")))?,
        Some(text) => text.to_owned(),
        None => return Err(UsageError::new("--prompt TEXT is required")),
    };
    if prompt.trim().is_empty() {
        return Err(UsageError::new("--prompt is empty"));
    }
    let agent = agent.unwrap_or_else(|| "claude".to_owned());
    if agent.is_empty()
        || !agent.chars().all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || "._-".contains(ch))
    {
        return Err(UsageError::new(format!("--agent {agent:?}: a harness id such as claude or codex")));
    }
    if let Some(dir) = &cwd
        && !dir.starts_with('/')
    {
        return Err(UsageError::new(format!("--cwd {dir}: an absolute folder on the machine")));
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
    Ok(Parsed::Run(Request { prompt, agent, cwd, machine, wait, timeout }))
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
        match Process::new(exe).args(&self.globals).args(args).output() {
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
        format!("chat-{}", &id[..8])
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
    if request.agent != "claude" {
        words.push(format!("--agent {}", request.agent));
    }
    if let Some(cwd) = &request.cwd {
        words.push(format!("--cwd {}", shell_quote(cwd)));
    }
    words.push(format!("--prompt {}", shell_quote(&request.prompt)));
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

/// Whether an app error is the account being signed out.
fn signed_out(error: &Value) -> bool {
    let code = error["code"].as_str().unwrap_or_default();
    let message = error["message"].as_str().unwrap_or_default().to_lowercase();
    code.contains("signed_out")
        || code.contains("not_signed_in")
        || code == "auth.required"
        || message.contains("sign in")
        || message.contains("signed out")
        || message.contains("not signed in")
}

/// Whether this run comes from an agent chat (whose `cloud start-session` asks the person).
fn from_agent_chat() -> bool {
    ["CMUX_AGENT_SESSION", "ACPMUX_SESSION_ID"]
        .iter()
        .any(|name| std::env::var(name).is_ok_and(|value| !value.trim().is_empty()))
}

/// Runs the steps (module docs) and answers the outcome.
pub(super) fn run(runner: &mut dyn Runner, request: &Request) -> Outcome {
    // 1. Signed in, and the machine names in use.
    let listed = match step_result(&runner.cmux(&words(&["cloud", "list-machines", "--json"]))) {
        Ok(listed) => listed,
        Err(error) => return app_failure(error, request, &request.machine),
    };
    if listed.pointer("/account/signed_in") == Some(&Value::Bool(false)) {
        return failed(
            "cloud.signed_out",
            "cmux is signed out: run `cmux cloud sign-in`, then this command again",
            json!({"sign_in": "cmux cloud sign-in"}),
            1,
        );
    }
    let machine = match &request.machine {
        Machine::New => {
            let taken = |name: &str| {
                listed["machines"].as_array().into_iter().flatten().any(|row| row["title"] == name)
            };
            let mut name = runner.fresh_name();
            for _ in 0..3 {
                if !taken(&name) {
                    break;
                }
                name = runner.fresh_name();
            }
            Machine::Named(name)
        }
        other => other.clone(),
    };

    // 2. The machine and the chat.
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
    start.push("--json".to_owned());
    let started = match step_result(&runner.cmux(&start)) {
        Ok(started) => started,
        Err(error) => return app_failure(error, request, &machine),
    };
    if started["pending"] == true {
        let again = again_command(request, &machine);
        return failed(
            "cloud.start_pending",
            format!(
                "the machine is still starting; the chat opens in its workspace when it is up. \
                 Run the same command again to keep waiting: {again}"
            ),
            json!({"again": again, "machine_name": started["machine_name"],
                   "machine_id": started["machine_id"], "app": started["text"]}),
            75,
        );
    }
    let (Some(machine_id), Some(session)) =
        (started["machine_id"].as_str(), started["session_id"].as_str())
    else {
        return failed(
            "cloud.start_incomplete",
            "cloud start-session answered without a machine_id and session_id",
            json!({"answer": started}),
            1,
        );
    };
    let mut answer = json!({
        "machine_id": machine_id,
        "machine_name": started["machine_name"],
        "target": format!("machine:{machine_id}"),
        "session_id": session,
        "workspace_id": started["workspace_id"],
        "tab_id": started["tab_id"],
        "surface_id": started["surface_id"],
        "host": started["host"],
        "agent": request.agent,
        "follow_up": follow_ups(machine_id, session),
    });

    // 3. The prompt.
    let send = format!(
        "echo @@history; {GUEST_CMUX} acp history {sid} --json -n 1 2>&1; echo @@send; \
         printf '%s' {prompt} | {GUEST_CMUX} acp send --no-wait {sid} - 2>&1; echo \"@@exit $?\"",
        sid = shell_quote(session),
        prompt = shell_quote(&request.prompt),
    );
    let sent = match exec(runner, machine_id, &send) {
        Ok(stdout) => stdout,
        Err(error) => return sent_failure(error, answer),
    };
    let sections = sections(&sent);
    let baseline = last_turn(sections.get("history")).map_or(0, |turn| turn.seq);
    if sections.get("exit").map(String::as_str).map(str::trim) != Some("0") {
        let output = sections.get("send").cloned().unwrap_or_default();
        return failed(
            "chat.send_failed",
            format!("the chat started, but the prompt did not reach it: {}", output.trim()),
            json!({"answer": answer}),
            1,
        );
    }
    answer["sent"] = json!(true);
    if let Some(delivery) = sections.get("send").map(|text| text.trim()).filter(|t| !t.is_empty()) {
        answer["delivery"] = json!(delivery);
    }
    if !request.wait {
        return Outcome::Done(answer);
    }

    // 4. The turn's end and its reply.
    let deadline = runner.now() + request.timeout;
    let poll = format!(
        "{GUEST_CMUX} acp wait {sid} --timeout {WAIT_SLICE_SECONDS} >/dev/null 2>&1; \
         echo \"@@wait $?\"; echo @@history; {GUEST_CMUX} acp history {sid} --json -n 1 2>&1; \
         echo @@last; {GUEST_CMUX} acp last {sid} --json 2>&1",
        sid = shell_quote(session),
    );
    loop {
        let polled = match exec(runner, machine_id, &poll) {
            Ok(stdout) => stdout,
            Err(error) => return sent_failure(error, answer),
        };
        let sections = sections(&polled);
        let turn = last_turn(sections.get("history")).filter(|turn| turn.seq > baseline);
        if let Some(turn) = turn.as_ref().filter(|turn| turn.ended) {
            answer["reply"] = json!(reply(sections.get("last")).unwrap_or_default());
            answer["turn"] = turn.value.clone();
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
        if sections.get("wait").map(|code| code.trim()) == Some("2") {
            return failed(
                "chat.permission_waiting",
                "the agent asks for a permission: answer it in the chat's tab in the cmux app, \
                 then wait with the follow-up commands",
                json!({"answer": answer}),
                2,
            );
        }
        if runner.now() >= deadline {
            return failed(
                "chat.wait_timeout",
                format!(
                    "the turn is still running after {}s; wait on with: cmux cloud exec \
                     --target machine:{machine_id} --command '{GUEST_CMUX} acp wait {session} \
                     --timeout {WAIT_SLICE_SECONDS}'",
                    request.timeout.as_secs()
                ),
                json!({"answer": answer}),
                3,
            );
        }
        if turn.is_none() {
            runner.pause(NOT_STARTED_PAUSE);
        }
    }
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
    Ok(result["stdout"].as_str().unwrap_or_default().to_owned())
}

/// A failure of a step before the chat existed.
fn app_failure(error: Value, request: &Request, machine: &Machine) -> Outcome {
    let message = error["message"].as_str().unwrap_or("the cmux app refused").to_owned();
    if signed_out(&error) {
        return failed(
            "cloud.signed_out",
            format!("{message} (run `cmux cloud sign-in`, then this command again)"),
            json!({"sign_in": "cmux cloud sign-in", "app": error}),
            1,
        );
    }
    let mut details = json!({"app": error});
    let mut message = message;
    if from_agent_chat() {
        let again = again_command(request, machine);
        message.push_str(&format!(
            ". From an agent chat the app asks the person first: they answer Start on the card \
             in this chat (`cmux agents dialog list` lists it); then run {again}"
        ));
        details["again"] = json!(again);
    }
    let code = error["code"].as_str().unwrap_or("cloud.start_failed").to_owned();
    failed(&code, message, details, 1)
}

/// A failure after the chat started: the answer so far goes with it.
fn sent_failure(error: Value, answer: Value) -> Outcome {
    let message = error["message"].as_str().unwrap_or("cloud exec failed");
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
    let turn = value["turns"].as_array()?.last()?.clone();
    Some(Turn {
        seq: turn["seq"].as_u64().unwrap_or(0),
        ended: turn.get("endedAt").is_some_and(|at| !at.is_null()),
        status: turn["status"].as_str().unwrap_or("completed").to_owned(),
        value: turn,
    })
}

/// The newest reply `acp last --json` printed (`{"sessionId", "replies": [...]}`).
pub(super) fn reply(last: Option<&String>) -> Option<String> {
    let value: Value = serde_json::from_str(last?.trim()).ok()?;
    value["replies"].as_array()?.last()?.as_str().map(str::to_owned)
}

/// Prints the outcome and answers the exit code.
fn report(outcome: &Outcome, output: OutputMode) -> i32 {
    match outcome {
        Outcome::Failed { error, exit } => super::wire::print_local_error(error, output, *exit),
        Outcome::Done(answer) if output == OutputMode::Human => {
            match answer["reply"].as_str() {
                Some(reply) => println!("{reply}"),
                None => println!(
                    "Sent to {} on {} (machine:{}).",
                    answer["session_id"].as_str().unwrap_or_default(),
                    answer["machine_name"].as_str().unwrap_or_default(),
                    answer["machine_id"].as_str().unwrap_or_default()
                ),
            }
            eprintln!(
                "machine_id {}  session_id {}  tab_id {}",
                answer["machine_id"].as_str().unwrap_or_default(),
                answer["session_id"].as_str().unwrap_or_default(),
                answer["tab_id"].as_str().unwrap_or_default()
            );
            0
        }
        Outcome::Done(answer) => super::wire::print_local_success(answer, output),
    }
}

#[cfg(test)]
mod tests;
