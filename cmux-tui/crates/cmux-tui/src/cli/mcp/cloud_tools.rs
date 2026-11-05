//! The user's Cloud machines, the agent chats on them and a machine's desktop as cmux MCP
//! tools: `cloud_machines`, `cloud_chat_start`, `cloud_chat_send`, `cloud_chat_status`,
//! `cloud_computer` and `cloud_computer_control`. `cmux cloud chat …` and `cmux cloud computer …`
//! (cli/cloud_agent.rs) run these same functions, so a tool and its command never differ.
//!
//! Every step is one of the app's Cloud actions (`action.run`): `cloud list-machines`,
//! `cloud exec`, `cloud file-read`, the start-chat chain (cloud_start_chat.rs, its steps run here
//! through [`AppRunner`] instead of a child `cmux`), and `cloud.computerControl`, the Mac app's
//! per-machine control lease (`ChiefComputerControlStore`). The desktop is driven by the machine's
//! own `cua-driver` through `cloud exec`, on the desktop `/etc/cmux/desktop-env.sh` points at.
//!
//! Take-over: before every input op `cloud_computer` reads the lease and refuses with
//! `computer.human_has_control` while the person holds it; `screenshot` and `list_windows` still
//! run. An app without the action (older, no take-over UI) has no lease, so input runs there.

use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use super::{Backend, envelope, success, tool_error, v2_tools};
use crate::cli::app::{self, ActionName};
use crate::cli::cloud_start_chat::{self as chat, Outcome, Parsed, Ran, Runner};

pub(super) const MACHINES: &str = "cloud_machines";
pub(super) const CHAT_START: &str = "cloud_chat_start";
pub(super) const CHAT_SEND: &str = "cloud_chat_send";
pub(super) const CHAT_STATUS: &str = "cloud_chat_status";
pub(super) const COMPUTER: &str = "cloud_computer";
pub(super) const COMPUTER_CONTROL: &str = "cloud_computer_control";

/// The app action that holds a Cloud machine's control lease (the Mac app's
/// `ChiefComputerControlStore`; CLI name `cloud computer-control`).
pub(super) const CONTROL_ACTION: &str = "cloud.computerControl";

/// The env that names the Chief's `engine.json` (optchat-chief `host::turn_preset`, passed to
/// this server by acpmux `agent_tools::CHIEF_ENGINE_ENV`): its `computer` is `cloud_computer`'s
/// default machine.
pub(super) const CHIEF_ENGINE_ENV: &str = acpmux::agent_tools::CHIEF_ENGINE_ENV;

/// The ops of `cloud_computer`, and whether each sends input (refused while a person drives).
const OPS: &[(&str, bool)] = &[
    ("screenshot", false),
    ("list_windows", false),
    ("click", true),
    ("move", true),
    ("drag", true),
    ("scroll", true),
    ("type", true),
    ("key", true),
    ("open_url", true),
];

/// The screenshot file on the machine, overwritten by each `screenshot`.
const SCREEN_FILE: &str = "/home/cmux/.cache/cmux-computer/screen.png";

/// Every desktop step's start: the work user's home and the desktop's env, and `cua-driver`'s
/// daemon started when it is not running (bounded on the machine, as the chief-cloud-machines
/// skill's helper did; `cloud exec` itself stops after 25 s).
const DESKTOP_PRELUDE: &str = "export HOME=/home/cmux; [ -f /etc/cmux/desktop-env.sh ] && . \
    /etc/cmux/desktop-env.sh; command -v cua-driver >/dev/null 2>&1 || { echo 'this machine has \
    no cua-driver: it is too old for computer use' >&2; exit 127; }; if ! cua-driver status \
    >/dev/null 2>&1; then setsid -f cua-driver serve >/dev/null 2>&1 </dev/null; i=0; while [ \
    \"$i\" -lt 20 ] && ! cua-driver status >/dev/null 2>&1; do i=$((i+1)); sleep 0.5; done; fi; ";

pub(super) fn descriptors() -> [Value; 6] {
    let machine = json!({"type":"string","minLength":1,"description":"machine:<id> (cloud_machines lists them)."});
    let session =
        json!({"type":"string","minLength":1,"description":"session_id from cloud_chat_start."});
    [
        descriptor(
            MACHINES,
            "List the user's cmux Cloud machines (target machine:<id>, title, status), whether Cloud is signed in, and computer: the machine attached to this Chief.",
            json!({}),
            &[],
            true,
        ),
        descriptor(
            CHAT_START,
            "Start an agent chat (claude, codex) on a Cloud machine and send it a prompt. machine: machine:<id> or a name (none: a new small machine). wait: true waits for the reply. Answers machine_id and session_id for cloud_chat_send/status.",
            json!({
                "prompt":{"type":"string","minLength":1},
                "agent":{"type":"string","default":"claude"},
                "cwd":{"type":"string","description":"An absolute folder on the machine."},
                "machine":{"type":"string","minLength":1},
                "wait":{"type":"boolean","default":false},
                "timeout_s":{"type":"integer","minimum":1,"maximum":3600,"default":900},
            }),
            &["prompt"],
            false,
        ),
        descriptor(
            CHAT_SEND,
            "Send the next prompt to a Cloud agent chat. Answers after: pass it to cloud_chat_status to wait for this prompt's turn.",
            json!({"machine":machine,"session":session,"prompt":{"type":"string","minLength":1}}),
            &["machine", "session", "prompt"],
            false,
        ),
        descriptor(
            CHAT_STATUS,
            "Read a Cloud agent chat's newest turn: state starting, running, permission_waiting, ended (with reply) or failed. wait_s (up to 20) waits on the machine for it to end; after skips older turns.",
            json!({
                "machine":machine,
                "session":session,
                "after":{"type":"integer","minimum":0},
                "wait_s":{"type":"integer","minimum":0,"maximum":chat::MAX_STATUS_WAIT_SECONDS,"default":0},
            }),
            &["machine", "session"],
            true,
        ),
        descriptor(
            COMPUTER,
            "Use a Cloud machine's desktop (1440x900): screenshot (an image), list_windows, click, move, drag, scroll, type, key (ctrl+l, Return), open_url. machine defaults to this Chief's computer. Input is refused while the person has control.",
            json!({
                "op":{"type":"string","enum":OPS.iter().map(|(op, _)| *op).collect::<Vec<_>>()},
                "machine":machine,
                "x":{"type":"integer","minimum":0},
                "y":{"type":"integer","minimum":0},
                "to_x":{"type":"integer","minimum":0},
                "to_y":{"type":"integer","minimum":0},
                "button":{"type":"string","enum":["left","right","middle"]},
                "direction":{"type":"string","enum":["up","down","left","right"]},
                "amount":{"type":"integer","minimum":1,"maximum":50},
                "text":{"type":"string","minLength":1},
                "keys":{"type":"string","minLength":1},
                "url":{"type":"string","minLength":1},
            }),
            &["op"],
            false,
        ),
        descriptor(
            COMPUTER_CONTROL,
            "Who drives a Cloud machine's desktop: status, request_human (ask the person to take over, with reason: a sign-in, a payment) or hand_back. While the person has control, cloud_computer input is refused.",
            json!({
                "action":{"type":"string","enum":["status","request_human","hand_back"]},
                "machine":machine,
                "reason":{"type":"string","minLength":1,"maxLength":200},
            }),
            &["action"],
            false,
        ),
    ]
}

fn descriptor(
    name: &str,
    description: &str,
    properties: Value,
    required: &[&str],
    read: bool,
) -> Value {
    json!({"name":name,"description":description,
        "inputSchema":{"type":"object","properties":properties,"required":required,"additionalProperties":false},
        "annotations":{"readOnlyHint":read,"destructiveHint":false,"idempotentHint":read,"openWorldHint":true}})
}

/// One tool call from an MCP client; `None` for another tool.
pub(super) fn call(
    backend: &impl Backend,
    name: &str,
    arguments: &Map<String, Value>,
) -> Option<Value> {
    run(backend, name, arguments, "mcp")
}

/// One tool call; `origin` is who asks the app (`mcp`, or the CLI's `cli`/`script`).
pub(in crate::cli) fn run(
    backend: &impl Backend,
    name: &str,
    arguments: &Map<String, Value>,
    origin: &'static str,
) -> Option<Value> {
    let calls = Calls { backend, origin };
    let answer = match name {
        MACHINES => calls.machines(arguments),
        CHAT_START => calls.chat_start(arguments),
        CHAT_SEND => calls.chat_send(arguments),
        CHAT_STATUS => calls.chat_status(arguments),
        COMPUTER => calls.computer(arguments),
        COMPUTER_CONTROL => calls.control(arguments),
        _ => return None,
    };
    Some(answer.unwrap_or_else(|refusal| refusal))
}

/// A refused or failed call, as its tool result.
type Answer = Result<Value, Value>;

fn invalid(message: impl Into<String>) -> Value {
    tool_error(envelope(v2_tools::invalid(message), "not_run", None))
}

fn refused(code: &str, message: impl Into<String>, details: Value, state: &str) -> Value {
    tool_error(envelope(
        json!({"code": code, "message": message.into(), "details": details, "retryable": false}),
        state,
        None,
    ))
}

/// The arguments a tool takes, and nothing else.
fn only(arguments: &Map<String, Value>, tool: &str, allowed: &[&str]) -> Result<(), Value> {
    match arguments.keys().find(|key| !allowed.contains(&key.as_str())) {
        Some(key) => Err(invalid(format!("{tool} has no argument {key:?}"))),
        None => Ok(()),
    }
}

fn text<'a>(arguments: &'a Map<String, Value>, key: &str) -> Result<Option<&'a str>, Value> {
    match arguments.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(Some(value)),
        Some(_) => Err(invalid(format!("{key} must be a non-empty string"))),
    }
}

fn required<'a>(arguments: &'a Map<String, Value>, key: &str) -> Result<&'a str, Value> {
    text(arguments, key)?.ok_or_else(|| invalid(format!("{key} is required")))
}

fn integer(arguments: &Map<String, Value>, key: &str, max: u64) -> Result<Option<u64>, Value> {
    match arguments.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_u64()
            .filter(|value| *value <= max)
            .map(Some)
            .ok_or_else(|| invalid(format!("{key} must be an integer from 0 to {max}"))),
    }
}

/// A Cloud machine id from `machine:<id>` or the bare id: letters, digits, `-` and `_` (the
/// ids the app lists), so it is safe in a target and a shell word.
pub(in crate::cli) fn machine_id(value: &str) -> Option<String> {
    let id = value.trim();
    let id = id.strip_prefix("machine:").unwrap_or(id);
    (!id.is_empty()
        && id.len() <= 128
        && id.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_'))
    .then(|| id.to_owned())
}

/// The machine the Chief's `engine.json` (at [`CHIEF_ENGINE_ENV`]) attaches as its computer.
pub(super) fn chief_computer_from_env() -> Option<String> {
    let path = std::env::var_os(CHIEF_ENGINE_ENV)?;
    let text = std::fs::read_to_string(path).ok()?;
    let engine: Value = serde_json::from_str(&text).ok()?;
    machine_id(engine.get("computer")?.as_str()?)
}

/// What a session id may be: it goes into a shell word on the machine, quoted.
fn session_id(arguments: &Map<String, Value>) -> Result<String, Value> {
    let session = required(arguments, "session")?;
    if session.len() > 200 || session.chars().any(char::is_control) {
        return Err(invalid("session must be a chat's session_id"));
    }
    Ok(session.to_owned())
}

/// The start-chat chain's steps, as the app's actions on this backend. Each step is the CLI
/// words `cloud <verb> --flag value … --json`; the flags become the action's `target` and
/// arguments, as `cmux cloud <verb>` sends them.
struct AppRunner<'a, B: Backend> {
    backend: &'a B,
    origin: &'static str,
}

impl<B: Backend> AppRunner<'_, B> {
    fn step(&self, words: &[String]) -> Result<Value, Value> {
        let [cloud, verb, flags @ ..] = words else {
            return Err(v2_tools::invalid("a Cloud step names its verb"));
        };
        if cloud != "cloud" {
            return Err(v2_tools::invalid("a Cloud step starts with cloud"));
        }
        let name = format!("cloud {verb}");
        let mut params = app::action_run_params(&name, ActionName::Cli, self.origin);
        let mut args = Map::new();
        let mut words = flags.iter().filter(|word| *word != "--json");
        while let Some(flag) = words.next() {
            let Some(key) = flag.strip_prefix("--") else {
                return Err(v2_tools::invalid(format!("unexpected step word {flag:?}")));
            };
            let value =
                words.next().ok_or_else(|| v2_tools::invalid(format!("{flag} needs a value")))?;
            if key == "target" {
                params.insert("target".into(), json!(value));
            } else {
                args.insert(app::argument_name(key), json!(value));
            }
        }
        if !args.is_empty() {
            params.insert("args".into(), Value::Object(args));
        }
        let mutation = verb != "list-machines";
        self.backend
            .app(
                "action.run",
                Value::Object(params),
                app::waiting_run_timeout(&name),
                None,
                mutation,
            )
            .map_err(|failure| failure.error)
    }
}

impl<B: Backend> Runner for AppRunner<'_, B> {
    fn cmux(&mut self, args: &[String]) -> Ran {
        match self.step(args) {
            Ok(value) => Ran { code: 0, stdout: value.to_string(), stderr: String::new() },
            Err(error) => Ran { code: 1, stdout: String::new(), stderr: error.to_string() },
        }
    }

    fn pause(&mut self, duration: Duration) {
        // The chain's own pause before asking a machine again (cloud_start_chat `SelfRunner`).
        std::thread::sleep(duration);
    }

    fn now(&mut self) -> Instant {
        Instant::now()
    }

    fn fresh_name(&mut self) -> String {
        chat::fresh_machine_name()
    }

    fn prompt_id(&mut self) -> String {
        chat::new_prompt_id()
    }
}

/// A finished chain as its tool result: the answer, or its error (`details` keep the chat's ids).
fn outcome(outcome: Outcome, applied: bool) -> Value {
    match outcome {
        Outcome::Done(answer) => success(answer, applied),
        Outcome::Failed { error, exit } => {
            // 75: still starting, run it again later; anything else ran and failed.
            let state = if exit == 75 { "in_progress" } else { "rejected" };
            tool_error(envelope(error, state, None))
        }
    }
}

/// The app's answer to one action run: its `result`.
fn result_of(value: Value) -> Value {
    match value {
        Value::Object(mut object) if object.contains_key("result") => {
            object.remove("result").unwrap_or_default()
        }
        other => other,
    }
}

struct Calls<'a, B: Backend> {
    backend: &'a B,
    origin: &'static str,
}

impl<B: Backend> Calls<'_, B> {
    fn runner(&self) -> AppRunner<'_, B> {
        AppRunner { backend: self.backend, origin: self.origin }
    }

    /// One app action by id or CLI name, waiting for its result.
    fn action(
        &self,
        action: &str,
        name: ActionName,
        target: Option<&str>,
        args: Value,
        mutation: bool,
    ) -> Result<Value, super::CallFailure> {
        let mut params = app::action_run_params(action, name, self.origin);
        if let Some(target) = target {
            params.insert("target".into(), json!(target));
        }
        params.insert("args".into(), args);
        self.backend
            .app(
                "action.run",
                Value::Object(params),
                app::waiting_run_timeout(action),
                None,
                mutation,
            )
            .map(result_of)
    }

    fn machines(&self, arguments: &Map<String, Value>) -> Answer {
        only(arguments, MACHINES, &[])?;
        let listed = self
            .action("cloud list-machines", ActionName::Cli, None, json!({}), false)
            .map_err(super::failure_result)?;
        let machines = listed
            .get("machines")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .map(|row| {
                let mut out = Map::new();
                for key in ["machine_id", "target", "title", "status", "size"] {
                    if let Some(value) = row.get(key).filter(|value| !value.is_null()) {
                        out.insert(key.into(), value.clone());
                    }
                }
                Value::Object(out)
            })
            .collect::<Vec<_>>();
        let mut answer = json!({
            "machines": machines,
            "signed_in": listed.pointer("/account/signed_in").cloned().unwrap_or(Value::Null),
            "loaded": listed.get("loaded").cloned().unwrap_or(Value::Null),
            "computer": self.backend.chief_computer().map(|id| format!("machine:{id}")),
        });
        if let Some(creating) = listed.get("creating").filter(|value| !value.is_null())
            && let Some(object) = answer.as_object_mut()
        {
            object.insert("creating".into(), creating.clone());
        }
        Ok(success(answer, false))
    }

    fn chat_start(&self, arguments: &Map<String, Value>) -> Answer {
        only(arguments, CHAT_START, &["prompt", "agent", "cwd", "machine", "wait", "timeout_s"])?;
        let prompt = required(arguments, "prompt")?;
        if prompt == "-" {
            return Err(invalid("prompt is the text to send"));
        }
        let mut words = vec!["--prompt".to_owned(), prompt.to_owned()];
        for key in ["agent", "cwd"] {
            if let Some(value) = text(arguments, key)? {
                words.extend([format!("--{key}"), value.to_owned()]);
            }
        }
        if let Some(machine) = text(arguments, "machine")? {
            if machine.starts_with("machine:") {
                let id =
                    machine_id(machine).ok_or_else(|| invalid("machine must be machine:<id>"))?;
                words.extend(["--target".to_owned(), format!("machine:{id}")]);
            } else {
                words.extend(["--name".to_owned(), machine.to_owned()]);
            }
        }
        match arguments.get("wait") {
            None | Some(Value::Null) | Some(Value::Bool(false)) => {}
            Some(Value::Bool(true)) => words.push("--wait".to_owned()),
            Some(_) => return Err(invalid("wait must be true or false")),
        }
        if let Some(seconds) = integer(arguments, "timeout_s", 3600)? {
            words.extend(["--timeout".to_owned(), seconds.max(1).to_string()]);
        }
        let request = match chat::parse(&words, || Err("no stdin".to_owned())) {
            Ok(Parsed::Run(request)) => request,
            Ok(Parsed::Help) => return Err(invalid("cloud_chat_start takes no help flag")),
            Err(error) => return Err(invalid(error.0)),
        };
        Ok(outcome(chat::run(&mut self.runner(), &request), true))
    }

    fn chat_target(&self, arguments: &Map<String, Value>) -> Result<(String, String), Value> {
        let machine = required(arguments, "machine")?;
        let id = machine_id(machine).ok_or_else(|| invalid("machine must be machine:<id>"))?;
        Ok((id, session_id(arguments)?))
    }

    fn chat_send(&self, arguments: &Map<String, Value>) -> Answer {
        only(arguments, CHAT_SEND, &["machine", "session", "prompt"])?;
        let (machine, session) = self.chat_target(arguments)?;
        let prompt = required(arguments, "prompt")?;
        Ok(outcome(chat::send(&mut self.runner(), &machine, &session, prompt), true))
    }

    fn chat_status(&self, arguments: &Map<String, Value>) -> Answer {
        only(arguments, CHAT_STATUS, &["machine", "session", "after", "wait_s"])?;
        let (machine, session) = self.chat_target(arguments)?;
        let after = integer(arguments, "after", u64::MAX)?;
        let wait = integer(arguments, "wait_s", chat::MAX_STATUS_WAIT_SECONDS)?.unwrap_or(0);
        Ok(outcome(chat::status(&mut self.runner(), &machine, &session, after, wait), false))
    }

    /// The machine a `cloud_computer` call targets: its own, else this Chief's computer.
    fn computer_machine(&self, arguments: &Map<String, Value>) -> Result<String, Value> {
        match text(arguments, "machine")? {
            Some(machine) => machine_id(machine).ok_or_else(|| invalid("machine must be machine:<id>")),
            None => self.backend.chief_computer().ok_or_else(|| {
                invalid("name the machine (machine:<id>): this Chief has no computer attached; cloud_machines lists them")
            }),
        }
    }

    /// The control lease of `machine`: `Ok(None)` from an app without the action.
    fn lease(
        &self,
        machine: &str,
        action: &str,
        reason: Option<&str>,
    ) -> Result<Option<Value>, Value> {
        let mut args = json!({"machine": machine, "action": action});
        if let (Some(reason), Some(object)) = (reason, args.as_object_mut()) {
            object.insert("reason".into(), json!(reason));
        }
        match self.action(CONTROL_ACTION, ActionName::Any, None, args, action != "status") {
            Ok(state) => Ok(Some(state)),
            Err(failure) if lacks_action(&failure.error) => Ok(None),
            Err(failure) => Err(super::failure_result(failure)),
        }
    }

    fn control(&self, arguments: &Map<String, Value>) -> Answer {
        only(arguments, COMPUTER_CONTROL, &["action", "machine", "reason"])?;
        let action = required(arguments, "action")?;
        if !matches!(action, "status" | "request_human" | "hand_back") {
            return Err(invalid("action is status, request_human or hand_back"));
        }
        let reason = text(arguments, "reason")?;
        if reason.is_some() && action != "request_human" {
            return Err(invalid("reason goes with request_human"));
        }
        if reason.is_some_and(|reason| reason.chars().count() > 200) {
            return Err(invalid("reason is at most 200 characters"));
        }
        let machine = self.computer_machine(arguments)?;
        match self.lease(&machine, action, reason)? {
            Some(state) => Ok(success(state, action != "status")),
            None => Err(refused(
                "computer.control_unavailable",
                "this cmux app answers no cloud.computerControl, so nobody can take over: use cloud_computer directly",
                json!({"machine": format!("machine:{machine}")}),
                "not_run",
            )),
        }
    }

    fn computer(&self, arguments: &Map<String, Value>) -> Answer {
        let op = required(arguments, "op")?;
        let Some(&(op, input)) = OPS.iter().find(|(name, _)| *name == op) else {
            return Err(invalid(format!(
                "op is one of {}",
                OPS.iter().map(|(name, _)| *name).collect::<Vec<_>>().join(", ")
            )));
        };
        let step = desktop_step(op, arguments)?;
        let machine = self.computer_machine(arguments)?;
        let target = format!("machine:{machine}");
        if input
            && let Some(state) = self.lease(&machine, "status", None)?
            && state.get("holder").and_then(Value::as_str) == Some("human")
        {
            return Err(refused(
                "computer.human_has_control",
                format!(
                    "the person has control of {target}'s desktop: input is refused until they \
                     give it back (cloud_computer_control status); screenshots still work"
                ),
                json!({"machine": target, "control": state}),
                "not_run",
            ));
        }
        let script = format!("{DESKTOP_PRELUDE}{}", step.script);
        let ran = self
            .action("cloud exec", ActionName::Cli, Some(&target), json!({"command": script}), input)
            .map_err(super::failure_result)?;
        let exit = ran.get("exit_code").and_then(Value::as_i64);
        let stdout = ran.get("stdout").and_then(Value::as_str).unwrap_or_default().trim();
        let stderr = ran.get("stderr").and_then(Value::as_str).unwrap_or_default().trim();
        if exit != Some(0) {
            let message = if stderr.is_empty() { stdout } else { stderr };
            return Err(refused(
                "computer.failed",
                format!("{op} failed on {target}: {}", clip(message, 600)),
                json!({"machine": target, "op": op, "exit_code": exit}),
                if input { "rejected" } else { "not_run" },
            ));
        }
        if op == "screenshot" {
            return self.screenshot(&target);
        }
        let output =
            serde_json::from_str::<Value>(stdout).unwrap_or_else(|_| json!(clip(stdout, 4000)));
        let mut answer = json!({"machine": target, "op": op, "result": output});
        if input && let Some(object) = answer.as_object_mut() {
            object.insert("note".into(), json!("take a screenshot to see what changed"));
        }
        Ok(success(answer, input))
    }

    /// The screenshot `desktop_step` saved, read back as an image block. No structured content,
    /// so `cmux_exec` carries the image (code_mode `script_answer`), as `video_frames` does.
    fn screenshot(&self, target: &str) -> Answer {
        let read = self
            .action(
                "cloud file-read",
                ActionName::Cli,
                Some(target),
                json!({"path": SCREEN_FILE}),
                false,
            )
            .map_err(super::failure_result)?;
        let Some(data) =
            read.get("data_base64").and_then(Value::as_str).filter(|data| !data.is_empty())
        else {
            return Err(refused(
                "computer.failed",
                format!("the screenshot on {target} could not be read"),
                json!({"machine": target, "op": "screenshot"}),
                "not_run",
            ));
        };
        let text = json!({"machine": target, "op": "screenshot", "width": 1440, "height": 900})
            .to_string();
        Ok(json!({
            "content": [
                {"type": "text", "text": text},
                {"type": "image", "data": data, "mimeType": "image/png"},
            ],
            "isError": false,
        }))
    }
}

/// An app that has no such action ran nothing: an older app.
fn lacks_action(error: &Value) -> bool {
    let code = error.get("code").and_then(Value::as_str).unwrap_or_default();
    code == "action.not_found" || code == "not_found" || code.starts_with("usage.")
}

fn clip(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_owned();
    }
    let cut: String = text.chars().take(max).collect();
    format!("{cut}…")
}

/// One desktop op as the shell words after [`DESKTOP_PRELUDE`].
struct DesktopStep {
    script: String,
}

/// `cua-driver call TOOL 'ARGS'` for `op`, from the call's arguments (each op takes only its own).
fn desktop_step(op: &str, arguments: &Map<String, Value>) -> Result<DesktopStep, Value> {
    let tool = COMPUTER;
    let point = |arguments: &Map<String, Value>| -> Result<(u64, u64), Value> {
        let x = integer(arguments, "x", 10_000)?.ok_or_else(|| invalid(format!("{op} needs x")))?;
        let y = integer(arguments, "y", 10_000)?.ok_or_else(|| invalid(format!("{op} needs y")))?;
        Ok((x, y))
    };
    let call = |name: &str, args: Value| {
        format!("cua-driver call {name} {}", chat::shell_quote(&args.to_string()))
    };
    let script = match op {
        "screenshot" => {
            only(arguments, tool, &["op", "machine"])?;
            let shot = call("get_desktop_state", json!({"screenshot_out_file": SCREEN_FILE}));
            format!(
                "mkdir -p \"$(dirname {SCREEN_FILE})\" && rm -f {SCREEN_FILE} && {shot} >/dev/null \
                 2>&1; test -s {SCREEN_FILE} || {{ echo 'no screenshot saved:' >&2; cua-driver \
                 doctor 2>&1 | tail -5 >&2; exit 1; }}"
            )
        }
        "list_windows" => {
            only(arguments, tool, &["op", "machine"])?;
            call("list_windows", json!({}))
        }
        "click" => {
            only(arguments, tool, &["op", "machine", "x", "y", "button"])?;
            let (x, y) = point(arguments)?;
            let button = text(arguments, "button")?.unwrap_or("left");
            if !matches!(button, "left" | "right" | "middle") {
                return Err(invalid("button is left, right or middle"));
            }
            call("click", json!({"scope": "desktop", "x": x, "y": y, "button": button}))
        }
        "move" => {
            only(arguments, tool, &["op", "machine", "x", "y"])?;
            let (x, y) = point(arguments)?;
            call("move_cursor", json!({"scope": "desktop", "x": x, "y": y}))
        }
        "drag" => {
            only(arguments, tool, &["op", "machine", "x", "y", "to_x", "to_y"])?;
            let (x, y) = point(arguments)?;
            let to_x =
                integer(arguments, "to_x", 10_000)?.ok_or_else(|| invalid("drag needs to_x"))?;
            let to_y =
                integer(arguments, "to_y", 10_000)?.ok_or_else(|| invalid("drag needs to_y"))?;
            call(
                "drag",
                json!({"scope": "desktop", "from_x": x, "from_y": y, "to_x": to_x, "to_y": to_y}),
            )
        }
        "scroll" => {
            only(arguments, tool, &["op", "machine", "x", "y", "direction", "amount"])?;
            let (x, y) = point(arguments)?;
            let direction = required(arguments, "direction")?;
            if !matches!(direction, "up" | "down" | "left" | "right") {
                return Err(invalid("direction is up, down, left or right"));
            }
            let amount = integer(arguments, "amount", 50)?.unwrap_or(3).max(1);
            call(
                "scroll",
                json!({"scope": "desktop", "x": x, "y": y, "direction": direction,
                       "amount": amount, "by": "line"}),
            )
        }
        "type" => {
            only(arguments, tool, &["op", "machine", "text"])?;
            let typed = arguments.get("text").and_then(Value::as_str).unwrap_or_default();
            if typed.is_empty() || typed.chars().count() > 10_000 {
                return Err(invalid("type needs text (at most 10000 characters)"));
            }
            call("type_text", json!({"scope": "desktop", "text": typed}))
        }
        "key" => {
            only(arguments, tool, &["op", "machine", "keys"])?;
            let keys = required(arguments, "keys")?;
            let parts = keys.split('+').map(|key| key.trim().to_lowercase()).collect::<Vec<_>>();
            let named = |key: &String| {
                !key.is_empty()
                    && key.len() <= 24
                    && key.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '_' || ch == '-')
            };
            if parts.len() > 5 || !parts.iter().all(named) {
                return Err(invalid(
                    "keys is a key or a chord such as Return, ctrl+l or shift+Tab",
                ));
            }
            match parts.as_slice() {
                [key] => call("press_key", json!({"scope": "desktop", "key": key})),
                _ => call("hotkey", json!({"scope": "desktop", "keys": parts})),
            }
        }
        "open_url" => {
            only(arguments, tool, &["op", "machine", "url"])?;
            let url = required(arguments, "url")?;
            if !(url.starts_with("https://") || url.starts_with("http://"))
                || url.len() > 4096
                || url.chars().any(|ch| ch.is_control() || ch.is_whitespace())
            {
                return Err(invalid("url is an http or https address"));
            }
            call(
                "launch_app",
                json!({"name": "google-chrome-stable", "additional_arguments":
                       ["--new-window", "--no-first-run", "--hide-crash-restore-bubble", url]}),
            )
        }
        _ => return Err(invalid(format!("unknown op {op}"))),
    };
    Ok(DesktopStep { script })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_description_stays_short() {
        for tool in descriptors() {
            let description = tool["description"].as_str().unwrap();
            assert!(description.len() < 300, "{}: {} chars", tool["name"], description.len());
        }
    }
}
