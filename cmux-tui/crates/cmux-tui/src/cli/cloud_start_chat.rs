//! `cmux cloud start-chat [--prompt TEXT] [--agent claude] [--cwd DIR | --from-folder PATH] [--login L]
//! [--environment E] [--name MACHINE | --target machine:ID] [--wait] [--timeout SECONDS]`: one command takes
//! a Cloud chat from nothing to a reply, for a person, a script or the Chief (Leo, 2026-11-02: "we need to improve
//! the docs/instructions/commands and guidance and whatnot to make this all smoother faster more
//! efficient more exposed / cuz chief will be using this kind of flow").
//!
//! It runs the app's own verbs in turn, each as this binary with `--json`, so every step keeps
//! that verb's checks, keys and deadlines:
//!
//! 1. `cloud list-machines`: refuses at once when the app is signed out of cmux.
//!    With `--environment`, `cloud new-machine --environment E` first makes the chat's machine in it.
//! 2. `cloud start-session (--name N | --target T) --agent A [--cwd D | --from-folder P] [--login L]`: takes
//!    the machine (or creates it) and opens the chat's tab in the machine's workspace, a real chat in the app.
//!    With `--from-folder` (an existing folder on this Mac) the app copies that folder to the machine the
//!    way the agent pane composer's Cloud start copies one, and the chat starts in the copy; a retry on the
//!    same machine reuses the finished copy.
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
//!    `--timeout` counts from the command's start: a new machine and the start spend it too.
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
pub(super) const GUEST_PRELUDE: &str = "export HOME=\"${HOME:-/home/cmux}\"; c=cmux-tui; \
    [ -x \"$HOME/.cmux/bin/cmux-tui\" ] && c=\"$HOME/.cmux/bin/cmux-tui\"; ";

/// The send's read of where the chat runs on the machine (support.rs `session_cwd`), in the same
/// exec as the send, bounded so it never holds it: the answer's `cwd`, a folderless chat's too.
const SESSION_CWD: &str = "echo @@cwd; timeout 5 \"$c\" acp ls --live --machine local --json --fields sessionId,cwd 2>/dev/null; ";

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
    "--model",
    "--cwd",
    "--from-folder",
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
    /// `--model MODEL` (or `--agent HARNESS/MODEL`): the model the machine's agent starts on, as
    /// `cloud start-session --model` takes it (acpmux's `session/new` model); `None` leaves the
    /// harness's default there.
    pub model: Option<String>,
    pub cwd: Option<String>,
    /// `--from-folder`: a folder on this Mac, canonical; the chat starts in its copy on the machine.
    pub from_folder: Option<String>,
    /// `--login pass|machine|none`: the harness login the machine's agent gets, as `cloud start-session`
    /// takes it (`CloudHarnessLoginAsk`); `None` leaves the app's default.
    pub login: Option<String>,
    /// `--environment ID|NAME`: the Cloud environment (`env_…`, or its name) a new machine boots in
    /// (`cloud new-machine --environment`).
    pub environment: Option<String>,
    pub machine: Machine,
    pub wait: bool,
    pub timeout: Duration,
    /// `--make-room`: at a machine cap, free the machine the refusal offers (cap.rs [`cap::room`])
    /// and start again once.
    pub make_room: bool,
    /// `--allow-large`: copy `from_folder` even past the copy's limits (link/sync_cli/size_cap.rs).
    pub allow_large: bool,
}

// One `Parsed` is made per command line and taken apart at once, so the size gap between `Help`
// and `Run` costs nothing; boxing `Run` would only add `*` at its two dozen match sites.
#[allow(clippy::large_enum_variant)]
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
    if let Some(code) = fault::run_if_requested(&global, rest) {
        return Some(code);
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
        // A folder refused for what it is: its reason and what to do, not the whole help.
        Err(error) => {
            if let Some(code) = folder_refused(&error, global.output) {
                return Some(code);
            }
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {}\n{}", error.0, super::cloud_help::START_CHAT_USAGE),
                global.output,
                2,
            ));
        }
    };
    Some(start(&global, &request))
}

/// A `--from-folder` refused for what the folder is (home, a key folder, gone), printed as its
/// reason and what to do with [`folder::REFUSED_CODE`], never with the whole help; exit 2. None
/// for any other usage error.
pub(super) fn folder_refused(error: &UsageError, output: OutputMode) -> Option<i32> {
    let reason = folder::refusal(error)?;
    Some(super::app::failure(folder::REFUSED_CODE, &format!("cmux: {reason}"), output, 2))
}

/// Runs `request` with this binary's own app verbs and prints the answer: `cloud start-chat`
/// and `cmux chat --on vm:…` (chat_start.rs) are the same run.
pub(super) fn start(global: &GlobalArgs, request: &Request) -> i32 {
    // `--allow-large`: the copy of this folder sends it whole, whichever surface runs it.
    if request.allow_large
        && let Some(dir) = &request.from_folder
        && let Err(error) = crate::link::sync_cli::size_cap::allow(std::path::Path::new(dir))
    {
        let message = format!("cmux: {error:#}");
        return super::app::failure(folder::REFUSED_CODE, &message, global.output, 2);
    }
    // A folder too big to copy is refused before any machine is made for it.
    if let Some(dir) = &request.from_folder
        && !request.allow_large
        && let Err(large) = crate::link::sync_cli::size_cap::check_plain(std::path::Path::new(dir))
    {
        let hint = crate::link::sync_cli::size_cap::OVERRIDE_HINT;
        let message = format!("cmux: {large}{hint}");
        return super::app::failure(
            crate::link::sync_cli::size_cap::CODE,
            &message,
            global.output,
            2,
        );
    }
    let mut runner = SelfRunner { globals: forwarded_globals(global), global: global.clone() };
    let outcome = run(&mut runner, request);
    report(&outcome, global.output)
}

/// `cmux chat send SESSION` for a chat on a Cloud VM (chat_send.rs): the prompt to the chat
/// `session` already running on machine `machine_id`, and with `wait` its reply.
pub(super) fn send_existing(
    global: &GlobalArgs,
    machine_id: &str,
    session: &str,
    prompt: String,
    wait: bool,
    timeout: Option<Duration>,
) -> i32 {
    let request = Request {
        prompt: Some(prompt),
        agent: String::new(),
        model: None,
        cwd: None,
        from_folder: None,
        login: None,
        environment: None,
        machine: Machine::Target(machine_id.to_owned()),
        wait,
        timeout: timeout.unwrap_or(DEFAULT_TIMEOUT).min(MAX_TIMEOUT),
        make_room: false,
        allow_large: false,
    };
    let mut runner = SelfRunner { globals: forwarded_globals(global), global: global.clone() };
    report(&send_to(&mut runner, &request, machine_id, session), global.output)
}

/// [`send_existing`]'s run: the prompt (step 4) and, with `--wait`, the turn (step 5), in one `--timeout`
/// deadline from its start; a step that answered after it is that phase's timeout, as in [`run`].
fn send_to(runner: &mut dyn Runner, request: &Request, machine_id: &str, session: &str) -> Outcome {
    super::last_chat::remember(session, Some(machine_id));
    let answer = json!({
        "machine_id": machine_id,
        "target": format!("machine:{machine_id}"),
        "session_id": session,
        "follow_up": follow_ups(machine_id, session),
    });
    let Some(prompt) = request.prompt.as_deref() else { return Outcome::Done(answer) };
    let deadline = Deadline::of(request, runner.now());
    let mut progress = Progress {
        machine: Some(Machine::Target(machine_id.to_owned())),
        chat: Some((machine_id.to_owned(), session.to_owned(), answer.clone())),
        again: Some(send_again(request, machine_id, session)),
        ..Progress::default()
    };
    let outcome = send_prompt(
        runner,
        request,
        machine_id,
        session,
        (prompt, answer, None),
        deadline,
        &mut progress,
    );
    if deadline.passed(runner) { progress.late(request) } else { outcome }
}

/// The command that sends to `session` on `machine_id` again (`cmux chat send`): never a start, which would
/// make another session. The prompt may be private, so the command holds a placeholder for it.
fn send_again(request: &Request, machine_id: &str, session: &str) -> String {
    let mut words = vec![
        "cmux chat send".to_owned(),
        shell_quote(session),
        format!("--on vm:{}", shell_quote(machine_id)),
    ];
    if request.wait {
        words.push("--wait".to_owned());
        if !request.timeout.is_zero() {
            words.push(format!("--timeout {}", request.timeout.as_secs()));
        }
    }
    words.extend(["--json".to_owned(), "TEXT".to_owned()]);
    words.join(" ")
}

/// Whether the app is signed in to cmux Cloud now, as its own machine list answers
/// (`cloud list-machines`, the first step of every start). An unreadable answer is signed out.
pub(super) fn app_signed_in(global: &GlobalArgs) -> bool {
    app_machines(global)
        .is_ok_and(|listed| listed.pointer("/account/signed_in") != Some(&Value::Bool(false)))
}

/// The app's `cloud list-machines` answer, or its error.
pub(super) fn app_machines(global: &GlobalArgs) -> Result<Value, Value> {
    let mut runner = SelfRunner { globals: forwarded_globals(global), global: global.clone() };
    step_result(&runner.cmux(&words(&["cloud", "list-machines", "--json"])))
}

/// One app Cloud verb run as this binary's own `--json` step: its `result`, or its error object
/// (`cmux vm exec dev -- CMD` reads `exit_code`, `stdout` and `stderr` from it).
pub(super) fn app_step(global: &GlobalArgs, args: &[String]) -> Result<Value, Value> {
    let mut globals = forwarded_globals(global);
    // One step, so the caller's key is this step's: a retry with it does not run it twice.
    if let Some(key) = &global.idempotency_key {
        globals.extend(["--idempotency-key".to_owned(), key.clone()]);
    }
    let mut runner = SelfRunner { globals, global: global.clone() };
    let mut args = args.to_vec();
    args.push("--json".to_owned());
    step_result(&runner.cmux(&args))
}

/// `rest` without the output flags the global scan left in it, which set `output`. A value of
/// one of this command's own flags (`--prompt --json`) stays a value.
pub(super) fn lift_output(rest: &[String], output: &mut OutputMode) -> Vec<String> {
    lift_output_of(rest, output, TAKES_VALUE)
}

/// [`lift_output`] for a command whose flags in `takes_value` take the next word as their value.
/// Every word from `--` on is text (`cmux chat send S -- --json` sends "--json").
pub(super) fn lift_output_of(
    rest: &[String],
    output: &mut OutputMode,
    takes_value: &[&str],
) -> Vec<String> {
    let mut words = Vec::new();
    let mut value_next = false;
    let mut text = false;
    for word in rest {
        if text || value_next {
            value_next = false;
            words.push(word.clone());
            continue;
        }
        match word.as_str() {
            "--json" => *output = OutputMode::Json,
            "--jsonl" => *output = OutputMode::JsonLines,
            "--quiet" => *output = OutputMode::Quiet,
            _ => {
                text = word == "--";
                value_next = takes_value.contains(&word.as_str());
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
    let mut model = None;
    let mut cwd = None;
    let mut from_folder = None;
    let mut login = None;
    let mut environment = None;
    let mut name = None;
    let mut target = None;
    let mut wait = false;
    let mut make_room = false;
    let mut allow_large = false;
    let mut timeout = DEFAULT_TIMEOUT;
    // The prompt came after `--`: text, so `-- -` is "-", not stdin.
    let mut literal = false;
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
            "--model" => model = Some(value()?),
            "--cwd" => cwd = Some(value()?),
            "--from-folder" => from_folder = Some(value()?),
            "--login" => login = Some(value()?),
            "--environment" => environment = Some(value()?),
            "--name" => name = Some(value()?),
            "--target" => target = Some(value()?),
            "--timeout" => {
                timeout = super::chat_send::timeout_value(&value()?)?.min(MAX_TIMEOUT);
            }
            "--wait" => wait = true,
            "--make-room" => make_room = true,
            "--allow-large" => allow_large = true,
            "--no-wait" => wait = false,
            // `-- TEXT`: the prompt, read as text even when it starts with `-`.
            "--" if inline.is_none() => match words.get(index.saturating_add(1)..) {
                Some([text]) if prompt.is_none() => {
                    prompt = Some(text.clone());
                    literal = true;
                    break;
                }
                _ => return Err(UsageError::new("-- takes one prompt, in place of --prompt")),
            },
            _ => return Err(UsageError::new(format!("unexpected argument {word:?}"))),
        }
        index += 1;
    }
    let prompt = match prompt.as_deref() {
        Some("-") if !literal => {
            Some(stdin().map_err(|error| UsageError::new(format!("--prompt -: {error}")))?)
        }
        Some(text) => Some(text.to_owned()),
        None => None,
    };
    if prompt.as_deref().is_some_and(|text| text.trim().is_empty()) {
        return Err(UsageError::new("--prompt is empty"));
    }
    let agent = agent.unwrap_or_else(|| "claude".to_owned());
    // `--agent claude/claude-haiku-5-5` is the claude harness on that model, as `acp ensure -m` reads it.
    let (agent, model) = match agent.split_once('/') {
        Some(_) if model.is_some() => {
            return Err(UsageError::new(format!(
                "--agent {agent:?} names a model, and so does --model: give one"
            )));
        }
        Some((harness, named)) => (harness.to_owned(), Some(named.to_owned())),
        None => (agent, model),
    };
    let model = model.map(|word| model_word(&word)).transpose()?;
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
    let from_folder = from_folder.map(|dir| local_folder(&dir, cwd.is_some())).transpose()?;
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
            let id = super::vm_words::bare_id(&target);
            if id.is_empty() {
                return Err(UsageError::new("--target vm:VM_ID"));
            }
            Machine::Target(id.to_owned())
        }
        (None, None) => Machine::New,
    };
    Ok(Parsed::Run(Request {
        prompt,
        agent,
        model,
        cwd,
        from_folder,
        login,
        environment,
        machine,
        wait,
        timeout,
        make_room,
        allow_large,
    }))
}

/// `--model`'s word, checked as the machine's daemon checks `agent-session-start`'s `model`
/// (cmux-tui-core agent_session_start.rs): 1 to 200 bytes, not starting with `-`, no space,
/// control character, quote, backslash, `$` or brace.
pub(super) fn model_word(word: &str) -> Result<String, UsageError> {
    let model = word.trim();
    let ok = (1..=200).contains(&model.len())
        && !model.starts_with('-')
        && !model.chars().any(|c| c.is_whitespace() || c.is_control())
        // 0x22 and 0x27 are the double and single quote (as bytes: a quote character literal
        // reads as an open string to check-resource-api-boundary.py's CLI literal scan).
        && !model.bytes().any(|b| matches!(b, b'{' | b'}' | b'$' | b'\\' | 0x22 | 0x27));
    if ok {
        Ok(model.to_owned())
    } else {
        Err(UsageError::new(format!("--model {word:?}: a model id such as claude-haiku-5-5")))
    }
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
    /// A new machine's name: the run's prefix and 16 hex characters from the OS's random source, so it is another
    /// machine's only by a negligible chance ([`unused_name`] still refuses one that is).
    fn fresh_name(&mut self) -> String;
    /// One app control call (`cloud.machine_stream`): its result, or the app's refusal. None: no app answered on a
    /// socket (a runner that reaches none).
    fn app(
        &mut self,
        _method: &str,
        _params: Value,
        _timeout: Duration,
    ) -> Option<Result<Value, Value>> {
        None
    }
    /// One wait on a chat tab's records over the machine's link stream `socket` ([`link_wait::observe`]).
    fn observe(
        &mut self,
        socket: &str,
        surface: u64,
        after: u64,
        wait: Duration,
    ) -> Result<Value, link_wait::Failure> {
        link_wait::observe(std::path::Path::new(socket), surface, after, wait)
    }
}

struct SelfRunner {
    globals: Vec<String>,
    global: GlobalArgs,
}

/// This binary as the runner of another command's steps (`cmux chat cd`, chat_cd.rs), reaching the same app.
pub(super) fn self_runner(global: &GlobalArgs) -> impl Runner {
    SelfRunner { globals: forwarded_globals(global), global: global.clone() }
}

impl Runner for SelfRunner {
    fn cmux(&mut self, args: &[String]) -> Ran {
        let exe = match std::env::current_exe() {
            Ok(exe) => exe,
            Err(error) => {
                return Ran { code: 127, stdout: String::new(), stderr: error.to_string() };
            }
        };
        // A step reads the app's own words (vm_words.rs), whatever the command prints.
        let mut command = cmux_process::Command::new(exe);
        command.env(super::vm_words::STEP_ENV, "1").args(&self.globals).args(args);
        match command.output() {
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
        format!("chat-{}", id.chars().take(16).collect::<String>())
    }

    fn app(
        &mut self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Option<Result<Value, Value>> {
        let mut stream = super::app::connect_command(&self.global).ok()?;
        super::app::request(&mut stream, method, params, timeout).ok()
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
    if let Some(model) = &request.model {
        words.push(format!("--model {}", shell_quote(model)));
    }
    if let Some(cwd) = &request.cwd {
        words.push(format!("--cwd {}", shell_quote(cwd)));
    }
    if let Some(folder) = &request.from_folder {
        words.push(format!("--from-folder {}", shell_quote(folder)));
    }
    if let Some(login) = &request.login {
        words.push(format!("--login {login}"));
    }
    // The prompt may be private: the command names where it goes, not what it says.
    if request.prompt.is_some() {
        words.push("--prompt TEXT".to_owned());
    }
    if request.wait {
        words.push("--wait".to_owned());
    }
    words.push("--json".to_owned());
    words.join(" ")
}

/// One word for a POSIX shell. A word that starts with `=` is quoted too:
/// zsh expands a bare `=name` to the path of `name`.
pub(super) fn shell_quote(text: &str) -> String {
    if !text.is_empty()
        && !text.starts_with('=')
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
        || message.contains("cmux login")
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

    /// Whether it bounds anything (`--wait` with a prompt).
    pub(super) fn is_bounded(self) -> bool {
        self.0.is_some()
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
    out_of_time_again(request, again_command(request, machine), machine, answer)
}

/// [`out_of_time`] with `again` as the command to ask again.
fn out_of_time_again(
    request: &Request,
    again: String,
    machine: &Machine,
    answer: Value,
) -> Outcome {
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

/// What [`steps`] got to, for the answer [`run`] gives when a step answered after the deadline.
#[derive(Debug, Default)]
struct Progress {
    /// The machine id this run made, once it has one.
    made: Option<String>,
    /// The machine the command to ask again names, once the run has one.
    machine: Option<Machine>,
    /// The chat's machine id, session and answer so far, once a chat started.
    chat: Option<(String, String, Value)>,
    /// The prompt is on its way to the machine, or there: the send ran.
    sending: bool,
    /// The name this run gave its own `cloud new-machine`, once the app took that create: a rerun names it (in
    /// `machine` too), so a create still on its way with no machine id yet is found by name, never made twice.
    created: Option<String>,
    /// That create's `creation_id`, when the app answered it pending with no machine id.
    creation: Option<String>,
    /// The command to ask again when it is not a start (`cmux chat send SESSION`'s own send, [`send_to`]).
    again: Option<String>,
}

impl Progress {
    /// [`out_of_time`], with this run's own command to ask again when it has one.
    fn out_of_time(&self, request: &Request, machine: &Machine, answer: Value) -> Outcome {
        match &self.again {
            Some(again) => out_of_time_again(request, again.clone(), machine, answer),
            None => out_of_time(request, machine, answer),
        }
    }

    /// The request to ask again: once the app took this run's create, that machine has its environment. A create
    /// with no answer keeps it: a rerun of the name then finds the create, or makes it in the environment.
    fn rerun(&self, request: &Request) -> Request {
        let environment = if self.created.is_some() { None } else { request.environment.clone() };
        Request { environment, ..request.clone() }
    }

    /// The deadline passed during a step: that phase's timeout, whatever the step answered. Before the prompt may
    /// have reached the machine, `cloud.start_pending`; once it may have, `chat.wait_timeout` on the chat's session
    /// or, with no session, `cloud.start_pending` that says it may be there.
    fn late(&self, request: &Request) -> Outcome {
        let request = &self.rerun(request);
        let machine = self.machine.clone().unwrap_or_else(|| request.machine.clone());
        match (&self.chat, self.sending) {
            (Some((machine_id, session, answer)), true) => {
                wait_timeout(request, machine_id, session, answer.clone())
            }
            (None, true) => {
                let again = again_command(request, &machine);
                let id = if let Machine::Target(id) = &machine { id.as_str() } else { "ID" };
                failed(
                    OUT_OF_TIME,
                    format!(
                        "--timeout ({}s) ran out while the prompt was on its way, and it may have reached the \
                         machine: see its sessions with: cmux cloud exec --target machine:{id} --command \
                         '{GUEST_CMUX} acp ls', and only if it is not there run: {again}",
                        request.timeout.as_secs()
                    ),
                    json!({"again": again, "machine_id": id, "sent": "unknown"}),
                    75,
                )
            }
            (chat, false) => self.out_of_time(
                request,
                &machine,
                chat.as_ref().map_or(Value::Null, |c| c.2.clone()),
            ),
        }
    }
}

/// Runs the steps (module docs) and answers the outcome. An answer on a machine this run made itself says
/// `new_machine: true`: its own `cloud new-machine`, or a `start-session --name` of the fresh name no machine had. A
/// failure after that says it in `details` (`machine_id`, `new_machine: true`). A caller (the start matrix) may
/// delete that machine as its own; no other answer is proof of that.
///
/// A step that answered after the `--timeout` deadline ends the run as that phase's timeout ([`Progress::late`]),
/// whatever it answered: one check here, after every step, instead of one after each call.
pub(super) fn run(runner: &mut dyn Runner, request: &Request) -> Outcome {
    let outcome = run_once(runner, request);
    if request.make_room { make_room(runner, request, outcome) } else { outcome }
}

/// `--make-room` after a cap refusal: free the machine the refusal offers, then start once more. A
/// delete frees room at once. An archive keeps the machine until its disk is archived, so the run
/// ends there and says to ask again once it is gone; from the CLI the archive may also need a person
/// (cloud_retention.rs), which that step's own answer says.
fn make_room(runner: &mut dyn Runner, request: &Request, outcome: Outcome) -> Outcome {
    let Outcome::Failed { error, .. } = &outcome else { return outcome };
    if at(error, "code").as_str() != Some("cloud.machine_cap") {
        return outcome;
    }
    let Some(room) = at(at(error, "details"), "make_room").as_object().and_then(|room| {
        Some(cap::Room {
            machine: room.get("machine_id")?.as_str()?.to_owned(),
            name: room.get("name")?.as_str()?.to_owned(),
            archive: room.get("how")?.as_str()? == "archive",
        })
    }) else {
        return outcome;
    };
    // An archive picks from the Cloud app's own records (keep and last use on every one), never
    // from the list's rows alone, which have neither.
    let room = if room.archive {
        let read = ["apps", "run", "cmux/cloud", "cloud.machine.list", "--args", "{\"limit\":100}"];
        let records = step_result(&runner.cmux(&read.map(str::to_owned)));
        match records.ok().and_then(|records| cap::oldest_paused(&cap::machine_rows(&records))) {
            Some(room) => room,
            None => {
                return failed(
                    "cloud.make_room_failed",
                    "no paused machine nobody kept could be read to archive; archive one from the \
                     app's Cloud page, then run this command again",
                    json!({"make_room": room.json()}),
                    1,
                );
            }
        }
    } else {
        room
    };
    if let Err(refused) = step_result(&runner.cmux(&room.command())) {
        let message = at(&refused, "message").as_str().unwrap_or("it was refused").to_owned();
        return failed(
            "cloud.make_room_failed",
            format!("could not free {} to make room: {message}", room.name),
            json!({"make_room": room.json(), "app": refused}),
            1,
        );
    }
    if room.archive {
        return failed(
            "cloud.make_room_archiving",
            format!(
                "archiving {}: it is deleted once its archive is ready; then run `{}` again",
                room.name,
                again_command(request, &request.machine)
            ),
            json!({"make_room": room.json()}),
            1,
        );
    }
    run_once(runner, &Request { make_room: false, ..request.clone() })
}

fn run_once(runner: &mut dyn Runner, request: &Request) -> Outcome {
    let deadline = Deadline::of(request, runner.now());
    let mut progress = Progress::default();
    let mut timed = Timed::new(runner);
    let mut outcome = steps(&mut timed, request, deadline, &mut progress);
    if deadline.passed(&mut timed) {
        outcome = progress.late(request);
    }
    if let (Some(id), Outcome::Done(answer)) = (progress.made.as_deref(), &mut outcome)
        && at(answer, "machine_id").as_str() == Some(id)
    {
        answer.set("new_machine", json!(true));
    }
    // Where it ran, in `--on`'s words: `cmux chat --on cloud` lets cmux Cloud choose, and a script
    // reads the choice here rather than assuming a kind of place (chat_start.rs).
    if let Outcome::Done(answer) = &mut outcome
        && let Some(id) = at(answer, "machine_id").as_str().map(str::to_owned)
    {
        answer.set("placement", json!(format!("vm:{id}")));
    }
    // The stage trace (cmuxterm-hq#7415): each step's start and length, on a reply and on a failure alike.
    let stages = timed.stages();
    match &mut outcome {
        Outcome::Done(answer) => {
            answer.set("stages_ms", stages);
        }
        Outcome::Failed { error, .. } => {
            if let Some(details) = error.get_mut("details").and_then(Value::as_object_mut) {
                details.insert("stages_ms".to_owned(), stages);
                // A create still on its way: its id, and the name a rerun finds it by.
                if let Some(creation) = &progress.creation {
                    details.entry("creation_id").or_insert_with(|| json!(creation));
                    if let Some(name) = &progress.created {
                        details.entry("machine_name").or_insert_with(|| json!(name));
                    }
                }
                // A failure after this run made its machine names it, so the caller can delete it.
                if let Some(id) = &progress.made {
                    details.insert("machine_id".to_owned(), json!(id));
                    details.insert("new_machine".to_owned(), json!(true));
                }
            }
        }
    }
    outcome
}

/// At most this many steps in `stages_ms`; a long wait's polls past it are counted, not listed.
const STAGES_KEPT: usize = 48;

/// A [`Runner`] that times each step it runs: its words (`cloud start-session`), when it began and how long it took,
/// in milliseconds since the run began.
struct Timed<'a> {
    inner: &'a mut dyn Runner,
    began: Instant,
    stages: Vec<Value>,
    more: usize,
}

impl<'a> Timed<'a> {
    fn new(inner: &'a mut dyn Runner) -> Self {
        let began = inner.now();
        Self { inner, began, stages: Vec::new(), more: 0 }
    }

    /// A step that is not a `cmux` child (an app call, a link wait), from `from` to now.
    fn mark(&mut self, step: &str, from: Instant, code: i32) {
        let to = self.inner.now();
        if self.stages.len() < STAGES_KEPT {
            self.stages.push(json!({
                "step": step,
                "at": from.saturating_duration_since(self.began).as_millis(),
                "ms": to.saturating_duration_since(from).as_millis(),
                "code": code,
            }));
        } else {
            self.more += 1;
        }
    }

    fn stages(&mut self) -> Value {
        let total = self.inner.now().saturating_duration_since(self.began).as_millis();
        json!({"steps": self.stages, "more_steps": self.more, "total": total})
    }
}

impl Runner for Timed<'_> {
    fn cmux(&mut self, args: &[String]) -> Ran {
        let from = self.inner.now();
        let ran = self.inner.cmux(args);
        let to = self.inner.now();
        if self.stages.len() < STAGES_KEPT {
            let step = args.iter().take(2).map(String::as_str).collect::<Vec<_>>().join(" ");
            let mut entry = json!({
                "step": step,
                "at": from.saturating_duration_since(self.began).as_millis(),
                "ms": to.saturating_duration_since(from).as_millis(),
                "code": ran.code,
            });
            // The app's own split of a step it times (`cloud start-session`'s `stages_ms`: the machine, its
            // connect, the login, the tab, the agent's start), so a long step names where its time went.
            if let Some(parts) = app_stages(&ran) {
                entry.set("parts", parts);
            }
            // Every clock's step, sub-steps too, the machine's own start phases and the total (`stages_detail_ms`).
            if let Some(detail) = app_detail(&ran) {
                entry.set("detail", detail);
            }
            self.stages.push(entry);
        } else {
            self.more += 1;
        }
        ran
    }

    fn pause(&mut self, duration: Duration) {
        self.inner.pause(duration);
    }

    fn now(&mut self) -> Instant {
        self.inner.now()
    }

    fn fresh_name(&mut self) -> String {
        self.inner.fresh_name()
    }

    fn observe(
        &mut self,
        socket: &str,
        surface: u64,
        after: u64,
        wait: Duration,
    ) -> Result<Value, link_wait::Failure> {
        let from = self.inner.now();
        let answer = self.inner.observe(socket, surface, after, wait);
        self.mark("link observe", from, i32::from(answer.is_err()));
        answer
    }

    fn app(
        &mut self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Option<Result<Value, Value>> {
        let from = self.inner.now();
        let answer = self.inner.app(method, params, timeout);
        self.mark(
            method,
            from,
            match &answer {
                Some(Ok(_)) => 0,
                Some(Err(_)) => 1,
                None => 127,
            },
        );
        answer
    }
}

/// The `stages_detail_ms` object a step's app answer carries: every clock's step, the machine's phases and the
/// total (an app that reports none, or a failed step: None).
fn app_detail(ran: &Ran) -> Option<Value> {
    if ran.code != 0 || !ran.stdout.contains("stages_detail_ms") {
        return None;
    }
    step_result(ran).ok()?.get("stages_detail_ms").filter(|value| value.is_object()).cloned()
}

/// The `stages_ms` an app step answered with (on a success or in a failure's `details`): a list of
/// `{step, ms}`, as `cloud start-session` reports the app's own steps. Anything else is no split.
fn app_stages(ran: &Ran) -> Option<Value> {
    let answer = match step_result(ran) {
        Ok(result) => result,
        Err(error) => error.get("details").cloned().unwrap_or(Value::Null),
    };
    answer.get("stages_ms").filter(|stages| stages.is_array()).cloned()
}

/// [`run`]'s steps; `progress` is what they got to. `--timeout` is one deadline from the start: the list, a new
/// machine, the start, the upload, the send and the wait each start only before it and get what is left
/// of it, never a `--timeout` of their own.
fn steps(
    runner: &mut dyn Runner,
    request: &Request,
    deadline: Deadline,
    progress: &mut Progress,
) -> Outcome {
    let began = runner.now();
    // 1. Signed in, and the machine names in use.
    let mut listed = match step_result(&runner.cmux(&words(&["cloud", "list-machines", "--json"])))
    {
        Ok(listed) => listed,
        Err(error) => return app_failure(error),
    };
    if listed.pointer("/account/signed_in") == Some(&Value::Bool(false)) {
        return failed(
            "cloud.signed_out",
            "cmux is signed out: run `cmux login`, then this command again",
            json!({"sign_in": "cmux login"}),
            1,
        );
    }
    // 2. The chat's machine: one made in --environment first, else the one asked for.
    // A `--cwd` on a machine that already exists may be a repository its bootstrap is still cloning
    // (`cloud new-machine --repo`): wait for the clone rather than fail "cwd is not a directory" (clone_wait.rs).
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
    // `--environment` always makes a new machine (in_environment refuses an existing name first), so it has
    // no folder of an earlier bootstrap to wait for. A `--name` still being made is waited on until it is
    // listed, then checked like any machine.
    if request.environment.is_none()
        && let Some(cwd) = &request.cwd
    {
        let machine = match (existing, &request.machine) {
            (Some(id), _) => Some(id),
            (None, Machine::Named(name)) => {
                match clone_wait::created(runner, request, name, deadline, &mut listed, began) {
                    Ok(id) => id,
                    Err(outcome) => return outcome,
                }
            }
            (None, _) => None,
        };
        if let Some(machine) = machine {
            // A wait that answers past the deadline is `run`'s late answer: it names the machine waited on.
            progress.machine = Some(Machine::Target(machine.clone()));
            if let Some(outcome) =
                clone_wait::wait(runner, request, &machine, cwd, deadline, &listed, began)
            {
                return outcome;
            }
        }
    }
    let mut wanted = request.machine.clone();
    if request.environment.is_some() && deadline.passed(runner) {
        return out_of_time(request, &request.machine, Value::Null);
    }
    if let Some(environment) = &request.environment {
        match in_environment(runner, request, environment, &listed, deadline, progress) {
            Ok(id) => {
                progress.made = Some(id.clone());
                progress.machine = Some(Machine::Target(id.clone()));
                wanted = Machine::Target(id);
            }
            Err(outcome) => return outcome,
        }
    }
    // A name whose create is still on its way (a rerun of a pending create): `start-session --name` does not
    // see it, so it would make a second machine.
    if let (None, Machine::Named(name)) = (&request.environment, &wanted)
        && let Err(outcome) = in_flight(&listed, name)
    {
        return outcome;
    }
    // The fresh name a new machine gets (no listed machine or create has it): a start-session machine of that name is this run's.
    let mut fresh = None;
    let machine = match &wanted {
        Machine::New => {
            let name = match unused_name(runner, &listed) {
                Ok(name) => name,
                Err(outcome) => return outcome,
            };
            fresh = Some(name.clone());
            Machine::Named(name)
        }
        other => other.clone(),
    };
    progress.machine = Some(machine.clone());
    // A turn to wait on and no time left for it: nothing starts, and a machine made so far
    // is there for the same ask again.
    if deadline.passed(runner) {
        return out_of_time(request, &machine, Value::Null);
    }

    // 3. The machine and the chat.
    let mut start = vec!["cloud".to_owned(), "start-session".to_owned()];
    match &machine {
        Machine::Named(name) => start.extend(["--name".to_owned(), name.clone()]),
        Machine::Target(id) => start.extend(["--target".to_owned(), format!("machine:{id}")]),
        // Named above.
        Machine::New => {}
    }
    start.extend(["--agent".to_owned(), request.agent.clone()]);
    if let Some(model) = &request.model {
        start.extend(["--model".to_owned(), model.clone()]);
    }
    if let Some(cwd) = &request.cwd {
        start.extend(["--cwd".to_owned(), cwd.clone()]);
    }
    if let Some(folder) = &request.from_folder {
        start.extend(["--from-folder".to_owned(), folder.clone()]);
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
            .and_then(|why| cap::cap_of("", why, None));
        if let Some(found) = capped {
            let (message, mut details) = cap::at_cap(found, &listed, |id| {
                again_command(request, &Machine::Target(id.to_owned()))
            });
            if let Some(fields) = details.as_object_mut() {
                fields.insert("reason".to_owned(), json!(stage.reason));
            }
            return failed(cap::code_of(found), message, details, 1);
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
                "the machine is still starting (stuck at: {}{}); the chat opens in its workspace when it is up. \
                 Run the same command again to keep waiting: {again}",
                stage.describe(),
                request
                    .from_folder
                    .as_ref()
                    .map_or_else(String::new, |dir| format!(", or copying {dir} to it"))
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
        progress.made = Some(machine_id.to_owned());
    }
    super::last_chat::remember(session, Some(machine_id));
    let mut answer = json!({
        "machine_id": machine_id,
        "machine_name": at(&started, "machine_name"),
        "target": format!("machine:{machine_id}"),
        "session_id": session,
        "workspace_id": at(&started, "workspace_id"),
        "tab_id": at(&started, "tab_id"),
        "host": at(&started, "host"),
        "agent": request.agent,
        "folder": folder_kind(request.cwd.as_deref(), request.from_folder.as_deref()),
        "follow_up": follow_ups(machine_id, session),
    });
    if let Some(cwd) = &request.cwd {
        answer.set("cwd", json!(cwd));
    }
    if let Some(model) = &request.model {
        answer.set("model", json!(model));
    }
    progress.machine = Some(Machine::Target(machine_id.to_owned()));
    progress.chat = Some((machine_id.to_owned(), session.to_owned(), answer.clone()));

    let Some(prompt) = request.prompt.as_deref() else {
        // No prompt: the chat is ready once start-session returned; `--wait` has no turn to wait on.
        let ready_ms = runner.now().saturating_duration_since(began).as_millis();
        answer.set("sent", json!(false));
        answer.set("ready_ms", json!(u64::try_from(ready_ms).unwrap_or(u64::MAX)));
        // A chat with no `--cwd` (a fresh folder, or a copy of a Mac folder) runs where the machine put
        // it: one read says where, as the send's own exec does with a prompt. Before the deadline only;
        // a read that fails leaves the answer without `cwd`, never fails a chat that started.
        if request.cwd.is_none()
            && !deadline.passed(runner)
            && let Ok(listed) = exec(runner, machine_id, &format!("{GUEST_PRELUDE}{SESSION_CWD}"))
            && let Some(cwd) = session_cwd(sections(&listed).get("cwd"), session)
        {
            answer.set("cwd", json!(cwd));
        }
        return Outcome::Done(answer);
    };
    // start-session answered after the deadline: the chat is there, and nothing is sent to it.
    if deadline.passed(runner) {
        return out_of_time(request, &Machine::Target(machine_id.to_owned()), answer);
    }
    let tab = internal::chat_tab(&started);
    send_prompt(runner, request, machine_id, session, (prompt, answer, tab), deadline, progress)
}

/// Step 4, the prompt to `session` on `machine_id`: inside the command when it fits there, else from
/// a file on the machine; then, with `--wait`, its turn (step 5). `answer` is the answer so far. Each
/// step starts only before `deadline`, as in [`steps`].
fn send_prompt(
    runner: &mut dyn Runner,
    request: &Request,
    machine_id: &str,
    session: &str,
    (prompt, mut answer, tab): (&str, Value, Option<u64>),
    deadline: Deadline,
    progress: &mut Progress,
) -> Outcome {
    let chat = Machine::Target(machine_id.to_owned());
    // No upload and no send once the deadline has passed, whichever command came here.
    if deadline.passed(runner) {
        return progress.out_of_time(request, &chat, answer);
    }
    let quoted = shell_quote(prompt);
    // The uploaded prompt's file words, when the prompt went to a file.
    let mut uploaded = None;
    let send = if quoted.len() <= INLINE_PROMPT_BYTES {
        format!(
            "{GUEST_PRELUDE}{SESSION_CWD}echo @@history; \"$c\" acp history {sid} --json -n 1 2>&1; echo @@send; \
             printf '%s' {quoted} | \"$c\" acp send --no-wait {sid} - 2>&1; echo \"@@exit $?\"",
            sid = shell_quote(session),
        )
    } else {
        let file = match upload_prompt(runner, machine_id, session, prompt.as_bytes(), deadline) {
            Ok(file) => file,
            Err(error) if at(&error, "code").as_str() == Some(OUT_OF_TIME) => {
                return progress.out_of_time(request, &chat, answer);
            }
            Err(error) => {
                return failed(
                    "chat.send_failed",
                    format!(
                        "the prompt did not reach the chat's machine: {}",
                        at(&error, "message").as_str().unwrap_or("cloud exec failed")
                    ),
                    json!({"answer": answer, "app": error}),
                    1,
                );
            }
        };
        // The last piece answered after the deadline: the file stays unsent (it is this run's own, mode 0600).
        if deadline.passed(runner) {
            return progress.out_of_time(request, &chat, answer);
        }
        uploaded = Some(file.clone());
        format!(
            "{GUEST_PRELUDE}{file}{SESSION_CWD}echo @@history; \"$c\" acp history {sid} --json -n 1 2>&1; \
             echo @@send; \"$c\" acp send --no-wait {sid} - < \"$f\" 2>&1; echo \"@@exit $?\"; \
             rm -f \"$f\"",
            sid = shell_quote(session),
        )
    };
    // From here the prompt may reach the machine, whatever the exec answers.
    progress.sending = true;
    let mut sending = answer.clone();
    sending.set("sent", json!(true));
    progress.chat = Some((machine_id.to_owned(), session.to_owned(), sending));
    let sent = match exec(runner, machine_id, &send) {
        Ok(stdout) => stdout,
        Err(error) => {
            // Refused before it started: the uploaded prompt does not stay on the machine. Any other
            // failure (no answer) may be a send still reading the file, so the file stays.
            if let Some(file) = uploaded.as_ref().filter(|_| refused_before_start(&error)) {
                remove_prompt_file(runner, machine_id, file, deadline);
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
            format!("the prompt did not reach the chat: {}", output.trim()),
            json!({"answer": answer}),
            1,
        );
    }
    answer.set("sent", json!(true));
    if let Some(cwd) = session_cwd(reported.get("cwd"), session) {
        answer.set("cwd", json!(cwd));
    }
    if let Some(delivery) = reported.get("send").map(|text| text.trim()).filter(|t| !t.is_empty()) {
        answer.set("delivery", json!(delivery));
    }
    if !request.wait {
        return Outcome::Done(answer);
    }
    wait_turn(runner, request, machine_id, session, (baseline, tab), answer, deadline)
}

/// 4. The turn after `baseline` in `session`: its end and its reply.
fn wait_turn(
    runner: &mut dyn Runner,
    request: &Request,
    machine_id: &str,
    session: &str,
    (baseline, tab): (u64, Option<u64>),
    mut answer: Value,
    deadline: Deadline,
) -> Outcome {
    // A fresh chat's turn (no turn before the send): pushed over the machine's link in one call when the app
    // can observe the chat's tab, else read through the Cloud API below.
    // `tab`: the chat tab's handle on the machine's daemon, known for a chat this run started.
    if baseline == 0
        && let Some(tab) = tab
    {
        match pushed_turn(runner, machine_id, tab, deadline) {
            Pushed::Ended(ended) => return ended.outcome(answer),
            Pushed::Permission => return permission_waiting(answer),
            Pushed::Unavailable => {
                answer.set("wait_route", json!("exec"));
            }
            Pushed::TimedOut => return wait_timeout(request, machine_id, session, answer),
        }
    }
    // The reads in a row the Cloud API did not answer: a read only reads, so it is asked again.
    let mut unanswered = 0;
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
            Err(error) if read_again(&error) && read_again_before(deadline, runner, unanswered) => {
                unanswered += 1;
                answer.set("unanswered_reads", json!(unanswered));
                let pause = deadline.bound(runner, unanswered_pause(unanswered));
                runner.pause(pause);
                continue;
            }
            Err(error) => return sent_failure(error, answer),
        };
        unanswered = 0;
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
            return permission_waiting(answer);
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

fn permission_waiting(answer: Value) -> Outcome {
    failed(
        "chat.permission_waiting",
        "the agent asks for a permission: answer it in the chat's tab in the cmux app, \
         then wait with the follow-up commands",
        json!({"answer": answer}),
        2,
    )
}

/// The longest one wait on the link takes before it is asked again.
const PUSH_SLICE: Duration = Duration::from_secs(60);

/// What the pushed wait ([`pushed_turn`]) got to.
#[derive(Debug)]
enum Pushed {
    /// The turn ended: its records, read.
    Ended(PushedTurn),
    /// The agent asks a permission.
    Permission,
    /// No app, an app without `cloud.machine_stream`, no link, or a link that could not be read: the exec route.
    Unavailable,
    /// `--timeout` passed while the turn ran.
    TimedOut,
}

/// A pushed turn's end: its stop reason, its last reply, and when (the records' own `at`, ms) its prompt went
/// in, its first agent output came and it ended.
#[derive(Debug)]
struct PushedTurn {
    stop: String,
    reply: Option<String>,
    seq: u64,
    first_output_ms: Option<u64>,
    turn_ms: Option<u64>,
    /// A failed turn's record (`turn_error`, or a failed `turn_result`): its `msg`.
    failure: Option<Value>,
}

impl PushedTurn {
    /// The turn read from a fresh chat's records, oldest first: None until one ended.
    fn read(records: &[Value]) -> Option<Self> {
        let mut transcript = acpmux::transcript::Transcript::default();
        let (mut prompt_at, mut first_at, mut end) = (None, None, None);
        for record in records {
            transcript.apply_event(record);
            let at = record.get("at").and_then(Value::as_u64);
            let dir = record.get("dir").and_then(Value::as_str);
            let kind = record.get("kind").and_then(Value::as_str);
            if prompt_at.is_none() && dir == Some("mux") && kind == Some("user_message") {
                prompt_at = at;
            }
            if first_at.is_none()
                && prompt_at.is_some()
                && dir == Some("in")
                && is_agent_output(record)
            {
                first_at = at;
            }
            if let Some(failure) = link_wait::turn_ended(record) {
                end = Some((
                    record.get("seq").and_then(Value::as_u64).unwrap_or(0),
                    at,
                    failure.cloned(),
                ));
                break;
            }
        }
        let (seq, end_at, failure) = end?;
        let stop = transcript.items.iter().rev().find_map(|item| match item {
            acpmux::transcript::Item::TurnEnd { stop } => Some(stop.clone()),
            _ => None,
        });
        let reply = transcript.items.iter().rev().find_map(|item| match item {
            acpmux::transcript::Item::Assistant { text } if !text.trim().is_empty() => {
                Some(text.trim().to_owned())
            }
            _ => None,
        });
        let since = |to: Option<u64>| prompt_at.zip(to).map(|(from, to)| to.saturating_sub(from));
        let stop = if failure.is_some() {
            "failed".to_owned()
        } else {
            stop.unwrap_or_else(|| "end_turn".to_owned())
        };
        Some(Self {
            stop,
            reply,
            seq,
            first_output_ms: since(first_at),
            turn_ms: since(end_at),
            failure,
        })
    }

    fn outcome(self, mut answer: Value) -> Outcome {
        let status =
            if FAILED_STOPS.contains(&self.stop.as_str()) { "failed" } else { "completed" };
        answer.set("turn", json!({"seq": self.seq, "status": status, "stop_reason": self.stop}));
        answer.set("wait_route", json!("link"));
        // Felt time on the machine's clock: the prompt to the agent's first output, and to the turn's end.
        answer.set("turn_ms", json!({"first_output": self.first_output_ms, "end": self.turn_ms}));
        if let Some(failure) = self.failure {
            // The agent's own error, typed as acpmux types it (`errorKind`, `recovery`) when it is.
            let message = failure
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("the turn failed")
                .to_owned();
            for key in ["errorKind", "recovery", "code"] {
                if let Some(value) = failure.get(key) {
                    answer.set(key, value.clone());
                }
            }
            if let Some(text) = self.reply {
                answer.set("reply", json!(text));
            }
            return Outcome::Failed {
                error: json!({"code": "chat.turn_failed", "message": message, "details": answer, "retryable": false}),
                exit: 1,
            };
        }
        let Some(text) = self.reply else {
            return failed(
                "chat.read_failed",
                "the turn ended, but its reply could not be read; read it with the answer's follow_up.last",
                json!({"answer": answer}),
                1,
            );
        };
        answer.set("reply", json!(text));
        if status == "failed" {
            return Outcome::Failed {
                error: json!({"code": "chat.turn_failed", "message": format!("the turn ended {}", self.stop),
                              "details": answer, "retryable": false}),
                exit: 1,
            };
        }
        Outcome::Done(answer)
    }
}

/// Stop reasons of a turn that ended without its reply (as the history's failed statuses).
const FAILED_STOPS: &[&str] = &["cancelled", "error", "failed", "refusal"];

/// An agent's own output in an `in` record: a message chunk, a thought or a tool call (never a status the app draws).
fn is_agent_output(record: &Value) -> bool {
    let replay =
        record.get("kind").and_then(Value::as_str).is_some_and(|kind| kind.ends_with(".replay"));
    let kind = record.pointer("/msg/params/update/sessionUpdate").and_then(Value::as_str);
    !replay && matches!(kind, Some("agent_message_chunk" | "agent_thought_chunk" | "tool_call"))
}

/// A fresh chat's turn over the machine's link: the app answers the link's stream socket
/// (`cloud.machine_stream`), and [`Runner::observe`] reads the tab's records there, in slices of at most
/// [`PUSH_SLICE`] within `deadline`, each after the newest seq the one before read.
fn pushed_turn(
    runner: &mut dyn Runner,
    machine_id: &str,
    surface: u64,
    deadline: Deadline,
) -> Pushed {
    let asked =
        runner.app("cloud.machine_stream", json!({"machine": machine_id}), Duration::from_secs(10));
    let Some(socket) = asked
        .and_then(Result::ok)
        .and_then(|answer| answer.get("socket").and_then(Value::as_str).map(str::to_owned))
    else {
        return Pushed::Unavailable;
    };
    let mut records: Vec<Value> = Vec::new();
    let mut after = 0u64;
    loop {
        let slice = deadline.bound(runner, PUSH_SLICE);
        if slice.is_zero() {
            return Pushed::TimedOut;
        }
        let answer = match runner.observe(&socket, surface, after, slice) {
            Ok(answer) => answer,
            Err(link_wait::Failure::Timeout) if deadline.passed(runner) => return Pushed::TimedOut,
            Err(_) => return Pushed::Unavailable,
        };
        if let Some(page) = answer.get("records").and_then(Value::as_array) {
            records.extend(page.iter().cloned());
        }
        after = answer.get("last_seq").and_then(Value::as_u64).unwrap_or(after);
        match answer.get("ended").and_then(Value::as_str) {
            Some("turn_end") => {
                return PushedTurn::read(&records).map_or(Pushed::Unavailable, Pushed::Ended);
            }
            Some("permission") => return Pushed::Permission,
            Some("closed") => return Pushed::Unavailable,
            _ if deadline.passed(runner) => return Pushed::TimedOut,
            _ => {}
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

/// The pause between reads of the app's machine list while a new machine is being made.
const CREATE_POLL_PAUSE: Duration = Duration::from_secs(3);

/// The machine a `cloud new-machine` answered `pending` for (`creation_id`), once the app lists it: its
/// create row leaves `creating` and a machine of the run's `name`, or else the one machine the first list
/// (`listed`) did not have, appears. Waits
/// only while the `--timeout` deadline has time left, each pause bounded by it; `pending` is the answer
/// when it runs out.
fn await_created(
    runner: &mut dyn Runner,
    request: &Request,
    listed: &Value,
    created: &Value,
    name: &str,
    deadline: Deadline,
    pending: &dyn Fn() -> Outcome,
) -> Result<String, Outcome> {
    let ids = |list: &Value| -> Vec<String> {
        at(list, "machines")
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|row| at(row, "machine_id").as_str().map(str::to_owned))
            .collect()
    };
    let before = ids(listed);
    let creation = at(created, "creation_id").as_str();
    loop {
        if !deadline.is_bounded() || deadline.passed(runner) {
            return Err(pending());
        }
        let pause = deadline.bound(runner, CREATE_POLL_PAUSE);
        runner.pause(pause);
        if deadline.passed(runner) {
            return Err(pending());
        }
        let Ok(now) = step_result(&runner.cmux(&words(&["cloud", "list-machines", "--json"])))
        else {
            continue;
        };
        let row = at(&now, "creating")
            .as_array()
            .into_iter()
            .flatten()
            .find(|row| creation.is_some() && at(row, "creation_id").as_str() == creation);
        if let Some(row) = row {
            if at(row, "status").as_str() == Some("failed") {
                return Err(create_failed(request, created, row, &now));
            }
            continue;
        }
        // The run's own name, when the app lists it: that machine, whatever else appeared beside it; else the one
        // machine the first list did not have.
        let rows: Vec<&Value> = at(&now, "machines")
            .as_array()
            .into_iter()
            .flatten()
            .filter(|row| {
                at(row, "machine_id").as_str().is_some_and(|id| !before.iter().any(|b| b == id))
            })
            .collect();
        let found = match rows.iter().find(|row| at(row, "title").as_str() == Some(name)) {
            Some(row) => Some(*row),
            None => match rows.as_slice() {
                [row] => Some(*row),
                // The create row can leave the list a moment before its machine is listed: read again.
                [] => None,
                _ => return Err(pending()),
            },
        };
        let Some(row) = found else { continue };
        // A machine that failed is the create's failure, never the chat's machine.
        if at(row, "status").as_str() == Some("failed") {
            return Err(create_failed(request, created, row, &now));
        }
        if let Some(id) = at(row, "machine_id").as_str() {
            return Ok(id.to_owned());
        }
    }
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
    deadline: Deadline,
    progress: &mut Progress,
) -> Result<String, Outcome> {
    let machine = &request.machine;
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
        in_flight(listed, name)?;
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
    }
    let name = match machine {
        Machine::Named(name) => Some(name.as_str()),
        _ => None,
    };
    new_machine(runner, request, listed, name, Some(environment), deadline, progress)
}

/// A create of `name` still on its way (`list-machines`' `creating` rows) answers pending, and one that failed (it
/// waits in cmux for Retry) is refused: either way nothing makes a second machine of that name.
fn in_flight(listed: &Value, name: &str) -> Result<(), Outcome> {
    let creation = at(listed, "creating")
        .as_array()
        .into_iter()
        .flatten()
        .find(|row| at(row, "name").as_str() == Some(name));
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
                "a machine named {name} is still being made, so no second one was made; once \
                 `cmux cloud list-machines` lists it, run this command again"
            ),
            details,
            75,
        ));
    }
    Ok(())
}

/// `cloud new-machine` in `environment`, named `name` or a fresh name no machine or create has: the new machine's id
/// once the app has it. The name goes into `progress` before the call, and any id the app answers (a pending
/// create's included) after it: the command to ask again names that machine, never a new one. A pending create with
/// no id yet is asked again by its name, which a rerun finds among the creates on their way ([`in_flight`]).
fn new_machine(
    runner: &mut dyn Runner,
    request: &Request,
    listed: &Value,
    name: Option<&str>,
    environment: Option<&str>,
    deadline: Deadline,
    progress: &mut Progress,
) -> Result<String, Outcome> {
    let name = match name {
        Some(name) => name.to_owned(),
        None => unused_name(runner, listed)?,
    };
    let mut args = words(&["cloud", "new-machine", "--name"]);
    args.push(name.clone());
    if let Some(environment) = environment {
        args.extend(["--environment".to_owned(), environment.to_owned()]);
    }
    args.push("--json".to_owned());
    progress.machine = Some(Machine::Named(name.clone()));
    let made =
        step_result(&runner.cmux(&args)).map_err(|error| start_refused(error, listed, request))?;
    progress.created = Some(name.clone());
    let id = at(&made, "machine_id").as_str().map(str::to_owned);
    if let Some(id) = &id {
        progress.made = Some(id.clone());
        progress.machine = Some(Machine::Target(id.clone()));
    }
    progress.creation = at(&made, "creation_id").as_str().map(str::to_owned);
    if at(&made, "pending").as_bool() != Some(true)
        && let Some(id) = id
    {
        return Ok(id);
    }
    let machine = progress.machine.clone().unwrap_or(Machine::Named(name.clone()));
    let again = again_command(&progress.rerun(request), &machine);
    let what = id.clone().unwrap_or_else(|| name.clone());
    let pending = || {
        failed(
            "cloud.start_pending",
            format!(
                "the new machine {what} is still being made; once `cmux cloud list-machines` lists it, \
                 run: {again}"
            ),
            json!({"again": again, "machine_id": id, "machine_name": name, "app": made,
                   "list": "cmux cloud list-machines --json"}),
            75,
        )
    };
    // A slow create: `--wait` with a prompt waits for it, within what is left of `--timeout`.
    let id = await_created(runner, request, listed, &made, &name, deadline, &pending)?;
    progress.made = Some(id.clone());
    progress.machine = Some(Machine::Target(id.clone()));
    Ok(id)
}

/// A machine name for this run: a fresh one no listed machine or create on its way has. It is never one that is:
/// a fresh name that is taken anyway, or a list the app has not loaded (`loaded: false` lists no machines, which
/// says nothing), is a typed error before any `start-session --name` (which would attach to that machine) or
/// `new-machine --name`.
fn unused_name(runner: &mut dyn Runner, listed: &Value) -> Result<String, Outcome> {
    if at(listed, "loaded").as_bool() == Some(false) {
        return Err(failed(
            "cloud.list_unread",
            "the app has not loaded its Cloud machines yet, so no machine was made or started: run this \
             command again in a moment",
            json!({"list": "cmux cloud list-machines --json"}),
            75,
        ));
    }
    let name = runner.fresh_name();
    let has = |key: &str, field: &str| {
        at(listed, key)
            .as_array()
            .into_iter()
            .flatten()
            .any(|row| at(row, field).as_str() == Some(name.as_str()))
    };
    if has("machines", "title") || has("creating", "name") {
        return Err(failed(
            "cloud.name_taken",
            format!(
                "the new machine's fresh name {name} is taken already, so no machine was made or started: \
                 run this command again"
            ),
            json!({"machine_name": name, "list": "cmux cloud list-machines --json"}),
            75,
        ));
    }
    Ok(name)
}

/// The commands that go on with this chat.
pub(super) fn follow_ups(machine: &str, session: &str) -> Value {
    let on = |command: String| {
        format!("cmux cloud exec --target machine:{machine} --command {}", shell_quote(&command))
    };
    json!({
        "send": format!("cmux chat send {session} 'PROMPT' --wait"),
        // Another folder or a repository later, a folderless start's included (chat_cd.rs).
        "cd": format!("cmux chat cd {session} DIR|--repo OWNER/NAME"),
        "wait": on(format!("{GUEST_CMUX} acp wait {session} --timeout {WAIT_SLICE_SECONDS}")),
        "last": on(format!("{GUEST_CMUX} acp last {session}")),
    })
}

/// `cloud exec` of `script` on the machine: its stdout, or the error.
/// Removes this run's own prompt file after a failed upload or a send refused before it started. Not with a
/// `--timeout` deadline: `cloud exec` has no bound this command can give it, so it could hold the command past
/// `--timeout`, and the file is harmless to leave (mode 0600, in `~/.cmux/prompts` on the person's own machine,
/// holding the prompt they sent there).
fn remove_prompt_file(runner: &mut dyn Runner, machine: &str, file: &str, deadline: Deadline) {
    if deadline.is_bounded() {
        return;
    }
    let _ = exec(runner, machine, &format!("{GUEST_PRELUDE}{file}rm -f \"$f\""));
}

pub(super) fn exec(runner: &mut dyn Runner, machine: &str, script: &str) -> Result<String, Value> {
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

/// A read of a running turn ([`wait_turn`]'s `cloud exec`) that nothing answered is asked again, with backoff,
/// until `--timeout`'s deadline: a read only reads (`acp wait`, `acp history`, `acp last`), and a slow Cloud API or
/// a machine whose daemon is restarting is not a lost chat (production probe 2026-11-08 19:06Z, run 42511607383:
/// "cmux Cloud didn't answer in time" on the first read, the machine `connected` and `ready`, the prompt queued).
/// A fixed count of tries made a slow-but-working machine `chat.unreachable` with most of `--timeout` left.
/// Only a wait with no deadline (none today: [`wait_turn`] runs only under `--wait` with a prompt) stops after
/// [`UNBOUNDED_READ_TRIES`], the hang breaker.
pub(super) const UNBOUNDED_READ_TRIES: u32 = 30;
/// The longest pause between two unanswered reads.
const MAX_UNANSWERED_PAUSE: Duration = Duration::from_secs(15);

/// Whether a read that went unanswered after `unanswered` unanswered reads in a row is asked again: while the
/// deadline has time left, or, with no deadline, up to [`UNBOUNDED_READ_TRIES`] (logged when it stops).
fn read_again_before(deadline: Deadline, runner: &mut dyn Runner, unanswered: u32) -> bool {
    if deadline.is_bounded() {
        return !deadline.passed(runner);
    }
    let again = unanswered + 1 < UNBOUNDED_READ_TRIES;
    if !again {
        eprintln!(
            "cmux: cloud start-chat: {UNBOUNDED_READ_TRIES} reads in a row went unanswered with no deadline; stopping"
        );
    }
    again
}

/// The pause after the `unanswered`-th unanswered read in a row (from 1): [`NOT_STARTED_PAUSE`], doubled each
/// time, at most [`MAX_UNANSWERED_PAUSE`].
pub(super) fn unanswered_pause(unanswered: u32) -> Duration {
    NOT_STARTED_PAUSE
        .saturating_mul(2u32.saturating_pow(unanswered.saturating_sub(1).min(16)))
        .min(MAX_UNANSWERED_PAUSE)
}

/// Whether a read of a running turn that failed with `error` may be asked again: only when nothing answered it
/// (the Cloud API timed out or could not be reached). Every other failure fails at once, because another read would
/// be refused the same way. The app reports each Cloud API error as `daemon_error` with the person's text
/// (`CloudStrings.apiErrorText`), so a stopped, missing or forbidden machine has no `vm_*` code to read. The match
/// is on the no-answer codes and the app's English no-answer text. In another locale the read is not asked again,
/// and the chat fails as it did before.
fn read_again(error: &Value) -> bool {
    let code = at(error, "code").as_str().unwrap_or_default().to_lowercase();
    let message = at(error, "message").as_str().unwrap_or_default().to_lowercase();
    if command_too_long(error) {
        return false;
    }
    matches!(code.as_str(), "timeout" | "timed_out" | "vm_timeout" | "unreachable")
        || UNANSWERED_TEXT.iter().any(|text| message.contains(text))
}

/// The app's text for a Cloud API call nothing answered (`CloudStrings.apiTimedOut`, `apiUnreachable`).
const UNANSWERED_TEXT: [&str; 2] = ["didn't answer in time", "couldn't reach cmux cloud"];

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
                remove_prompt_file(runner, machine, &file, deadline);
                return Err(error);
            }
        };
        let size = sections(&stdout).get("size").and_then(|size| size.trim().parse::<usize>().ok());
        if size != Some(end) {
            remove_prompt_file(runner, machine, &file, deadline);
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
            format!("{message} (run `cmux login`, then this command again)"),
            json!({"sign_in": "cmux login", "app": error}),
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
    let resource = at(&error, "details").get("resource").and_then(Value::as_str);
    match cap::cap_of(code, message, resource) {
        Some(found) if !signed_out(&error) => cap_refusal(found, listed, request, error),
        _ => app_failure(error),
    }
}

/// `cloud.machine_cap` or `cloud.spend_cap`: the stop `found` refused, the account's machines in `listed`
/// and the commands that free one; `app` is what the app answered, its own words included.
fn cap_refusal(found: cap::Cap, listed: &Value, request: &Request, app: Value) -> Outcome {
    let (mut text, mut details) =
        cap::at_cap(found, listed, |id| again_command(request, &Machine::Target(id.to_owned())));
    let room = cap::room(found, at(&app, "details"), listed);
    if let Some(room) = &room {
        let how = if room.archive { "archives and deletes" } else { "deletes" };
        text.push_str(&format!(
            "\nMake room: `{} --make-room` {how} {} first, then starts.",
            again_command(request, &request.machine),
            room.name
        ));
    }
    if let Some(fields) = details.as_object_mut() {
        fields.insert("make_room".to_owned(), room.as_ref().map_or(Value::Null, cap::Room::json));
        fields.insert("app".to_owned(), app);
    }
    failed(cap::code_of(found), text, details, 1)
}

/// A create that failed after the app answered it pending (its row under `creating`, or the machine it became
/// under `machines`, with status `failed`): the same answer as a create refused at once. A cap reason is the cap
/// answer, on the latest list (`now`); any other is `cloud.start_failed` with the reason.
fn create_failed(request: &Request, created: &Value, row: &Value, now: &Value) -> Outcome {
    let code = at(row, "error").get("code").and_then(Value::as_str).unwrap_or_default();
    let reason = at(row, "error")
        .get("message")
        .and_then(Value::as_str)
        .or_else(|| at(row, "reason").as_str())
        .unwrap_or("no reason given");
    let resource =
        at(row, "error").get("details").and_then(|d| d.get("resource")).and_then(Value::as_str);
    let app = json!({"app": created, "creation": row});
    match cap::cap_of(code, reason, resource) {
        Some(found) => cap_refusal(found, now, request, app),
        None => failed(
            "cloud.start_failed",
            format!("the new machine's create failed: {reason}"),
            app,
            1,
        ),
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

/// Prints the outcome and answers the exit code.
fn report(outcome: &Outcome, output: OutputMode) -> i32 {
    match outcome {
        Outcome::Failed { error, exit } => super::wire::print_local_error(error, output, *exit),
        Outcome::Done(answer) if output == OutputMode::Human => {
            match at(answer, "reply").as_str() {
                // Text from the machine: no terminal controls reach this terminal.
                Some(reply) => println!("{}", super::wire::sanitize_remote_text(reply)),
                None => {
                    let machine = at(answer, "machine_id").as_str().unwrap_or_default();
                    let on = match at(answer, "machine_name").as_str() {
                        Some(name) => format!("{name} (vm:{machine})"),
                        None => format!("vm:{machine}"),
                    };
                    println!(
                        "{} {} on {on}.",
                        if at(answer, "sent").as_bool() == Some(false) {
                            "Started"
                        } else {
                            "Sent to"
                        },
                        at(answer, "session_id").as_str().unwrap_or_default()
                    );
                }
            }
            eprintln!(
                "vm {}  session_id {}  tab_id {}",
                at(answer, "machine_id").as_str().unwrap_or_default(),
                at(answer, "session_id").as_str().unwrap_or_default(),
                at(answer, "tab_id").as_str().unwrap_or_default()
            );
            0
        }
        Outcome::Done(answer) => super::wire::print_local_success(answer, output),
    }
}

mod cap;
mod clone_wait;
mod fault;
mod folder;
mod internal;
use folder::local_folder;
use internal::link_wait;
mod support;
use support::{at, folder_kind, last_turn, reply, session_cwd, words};
// `cmux chat cd` reads the same guest script sections.
pub(in crate::cli) use support::sections;

#[cfg(test)]
pub(in crate::cli) mod tests;
