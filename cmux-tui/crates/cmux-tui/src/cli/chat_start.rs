//! `cmux chat [--on TARGET] [flags] [PROMPT]`: start an agent chat, here by default, or on a
//! device, a Cloud VM or in cmux Cloud (Leo, 2026-11-07: "the goal is like... cmux chat is normal,
//! and cmux chat with the flag/arguments can separate if you want it on a different
//! device/vm/cloud/whatevret"; the one-flag shape, Leo, 2026-11-07: "i think this will be good").
//!
//! One flag, `--on`, whose value decides the kind of target, so it is learned once for every verb
//! that runs something somewhere:
//!
//! - no `--on` (and no `CMUX_ON` and no `chat.on` setting), or `--on here`: right here, as
//!   `cmux agents chat new` starts it (a chat tab in the app, in this machine's acpmux);
//! - `--on vm`: my Cloud VM: my one VM (or the one running of several), a new one when I have
//!   none (`my_vm`);
//! - `--on cloud`: cmux Cloud decides where it runs (Leo, 2026-11-07: "in the future, the cloud
//!   kind of namespace will be a bit reserved"). Today that is `--on vm`'s VM; the answer's
//!   `placement` (`vm:ID`) names what it chose, so nothing depends on `cloud` meaning a VM;
//! - `--on vm:new`: a new Cloud VM; `--on vm:ID|NAME`: the app's existing Cloud VM with that id,
//!   or the one VM with that title, never one made for it. Both are the run `cmux cloud
//!   start-chat` does (cloud_start_chat.rs), which stays as that run's old name;
//! - `--on DEVICE`: a device of the daemon's machine catalog by its id, or the one device with
//!   that name. It goes through the SDK's [`cmux::resolve_chat_target`] first, with the catalog
//!   and the app's cloud sign-in read now, so a device the person may not use, one that does not
//!   run agent chats or one not running is refused before anything starts. Nothing here keeps a
//!   device list of its own.
//!
//! `CMUX_ON` names the target when `--on` is absent, as `DOCKER_CONTEXT` does, and the app's
//! `chat.on` setting (`cmux config set on cloud`) when both are: `--on` > `CMUX_ON` > `chat.on` >
//! here ([`pick_target`]). The setting is read from the app (`settings.get`) only then, with a
//! short deadline; no app (CI, a headless VM) is here. A refusal says what to run next. `cloud`,
//! `here`, `vm` and `vm:…` are selectors, never device names: a device called "cloud" is reached
//! by its id.

use std::os::unix::net::UnixStream;
use std::time::Duration;

use cmux::{CallKind, ChatTarget, ChatTargetRefusal};
use serde_json::{Value, json};

use super::agents::turn::{self, Begin};
use super::cloud_start_chat::{self, Machine};
use super::{GlobalArgs, OutputMode, UsageError};

/// This command's flags that take the next word as their value.
const TAKES_VALUE: &[&str] = &[
    "--on",
    "--prompt",
    "-p",
    "--agent",
    "--harness",
    "--model",
    "--cwd",
    "--name",
    "--timeout",
    "--attach",
    "--environment",
];

/// `--wait` and `--no-wait` take no value in `cmux chat …` and `cloud start-chat` (unlike
/// `terminal send --wait none`), so the global scan reads the word after them as its own:
/// `cmux chat send S --wait -- --json` keeps `--` and sends "--json". (`vm start-chat` is
/// refused for `cmux chat --on vm:…`, vm.rs.)
pub(super) fn own_switch(command: &[String], flag: &str) -> bool {
    let ours = match command {
        [scope, ..] if scope == "chat" => true,
        [scope, verb, ..] => scope == "cloud" && verb == "start-chat",
        _ => false,
    };
    ours && matches!(flag, "--wait" | "--no-wait")
}

/// The `chat` verbs other modules own (chief/chat_scope.rs, chat_cd.rs and the app's `chat …` actions).
pub(super) const OTHER_VERBS: &[&str] =
    &["send", "cd", "read", "wait", "list", "create", "replies", "colors"];

/// The environment variable that names the target when `--on` is absent.
pub(super) const TARGET_ENV: &str = "CMUX_ON";

/// The app setting that names the target when `--on` and `CMUX_ON` are both absent
/// (`cmux config set on TARGET` writes it; settings.rs reads `on` as this key).
pub(super) const TARGET_SETTING: &str = "chat.on";

/// How long the `chat.on` read may take: an app that does not answer by then is no setting.
// timeout: an app that does not answer counts as no setting; the chat still starts.
const SETTING_TIMEOUT: Duration = Duration::from_millis(1500);

/// How long the catalog read may take.
// timeout: a daemon that never answers the catalog read fails the start with an error.
const CATALOG_TIMEOUT: Duration = Duration::from_secs(10);

/// What a refusal says to run next.
const LIST_DEVICES: &str = "run `cmux machine list` for your devices and their ids";
const LIST_VMS: &str = "run `cmux vm list-machines` for your VMs, or use --on vm:new";

pub(super) const USAGE: &str = "\
usage: cmux chat [--on TARGET] [--environment ENV] [--agent AGENT] [--model MODEL]
                 [--cwd DIR] [--name NAME] [--attach FILE]... [--wait] [--timeout SECONDS]
                 [--json] [[--prompt] TEXT]

Starts an agent chat, right here unless --on names another target:

  --on here          This machine, as a tab in the cmux app (the default)
  --on cloud         cmux Cloud runs it; where may change (the answer's placement says)
  --on vm            Your Cloud VM, or a new one when you have none
  --on vm:new        A new Cloud VM
  --on vm:ID|NAME    Your Cloud VM with that id or name (`cmux vm list-machines`)
  --on DEVICE        A connected device by its id or name (`cmux machine list`);
                     it must be yours, running, and run agent chats
  CMUX_ON=TARGET names the target when --on is absent.
  `cmux config set on TARGET` saves a default target (the chat.on setting),
  used when neither --on nor CMUX_ON names one; `cmux config reset on` clears it.

  --environment ENV  The Cloud environment (its env_ id or its name) a Cloud chat's
                     new machine boots in, with --on cloud or --on vm:new; without
                     it, Auto, as in the app's composer

  --agent AGENT      claude (default), codex, ...
  --attach FILE      A file the first prompt carries; repeat for more (a chat here).
                     Any type and size: small files go inline, larger ones are uploaded
                     to the chat first. A missing or unreadable file starts nothing
                     and exits non-zero (attach.not_found, not_a_file, unreadable)
  --model MODEL      The agent's model (a chat here)
  --cwd DIR          The chat's folder (absolute)
  --name NAME        The chat's name (a chat here)
  --prompt TEXT      A first prompt (`-` reads it from stdin); a Cloud chat needs one
  --wait             Wait for the chat's turn to end and print the reply
  --timeout SECONDS  How long --wait waits (default 900, at most 14400)

EXAMPLES
  cmux chat 'Summarize README.md'
  cmux chat --prompt 'Summarize README.md' --wait --json
  cmux chat --on studio-mac 'Run the tests'
  cmux chat --on vm:new --prompt 'Summarize README.md' --wait --json
  cmux chat --on cloud --environment staging-db --prompt 'Run the migrations' --wait
  cmux chat --on vm:dev --cwd /home/cmux/work --prompt 'Run the tests' --json

With --wait the answer has session_id, workspace_id, tab_id and reply, here
and in Cloud. The chat goes on with cmux chat send SESSION TEXT --wait,
cmux chat wait SESSION and cmux chat read SESSION (`cmux chat send --help`).
Another folder or repository for a Cloud chat: cmux chat cd SESSION DIR|--repo REPO
(`cmux chat cd --help`).
A refused target exits 1 and says what to run next (chat_target.unknown_device,
ambiguous_device, unknown_vm, which_vm, vm_starting, not_permitted, unavailable,
signed_out, no_route).
Exit codes: 0 ok, 1 refused or the turn failed, 2 bad arguments or the agent
waits on a permission (chat.permission_waiting), 3 --timeout passed
(chat.wait_timeout; its details.answer has timed_out: true).
";

/// A parsed `cmux chat …` start.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Start {
    /// `--on`'s value, else `CMUX_ON`'s, else the `chat.on` setting's; None is here.
    pub on: Option<String>,
    pub agent: Option<String>,
    pub model: Option<String>,
    pub cwd: Option<String>,
    pub name: Option<String>,
    pub prompt: Option<String>,
    /// `--attach` files for the first prompt (a chat here; a Cloud chat refuses them).
    pub attach: Vec<String>,
    /// `--environment ENV`: the Cloud environment a new machine boots in (`cloud start-chat
    /// --environment`); None is Auto, as the composer's Environment chip defaults to.
    pub environment: Option<String>,
    pub wait: bool,
    pub timeout: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Parsed {
    Help,
    Run(Start),
}

/// Where a resolved target runs the chat.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Route {
    /// This machine's acpmux and app (`agents chat new`).
    Here,
    /// A Cloud VM (`cloud start-chat`'s run).
    Cloud(Machine),
}

/// `Some(exit code)` when `args` is a chat start: `cmux chat` with no words, `cmux chat new …`,
/// or `cmux chat` followed by a flag or the prompt. Every other `chat` verb runs where it did.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, command) = super::parse_globals(args).ok()?;
    let (scope, rest) = command.split_first()?;
    if scope != "chat" {
        return None;
    }
    let rest = start_words(rest)?;
    let words = cloud_start_chat::lift_output_of(rest, &mut global.output, TAKES_VALUE);
    let env = std::env::var(TARGET_ENV).ok();
    let start = match parse_with(&words, env, || setting_target(&global)) {
        Ok(Parsed::Help) => {
            print!("{USAGE}");
            return Some(0);
        }
        Ok(Parsed::Run(start)) => start,
        Err(error) => return Some(usage_failure(&error, global.output)),
    };
    Some(run(&global, start))
}

/// The start's words after `chat`, or `None` for another chat verb. Anything but a verb (a flag,
/// or the prompt itself: `cmux chat 'fix the tests'`) is a start.
fn start_words(rest: &[String]) -> Option<&[String]> {
    match rest.split_first() {
        Some((first, after)) if first == "new" => Some(after),
        Some((first, _)) if OTHER_VERBS.contains(&first.as_str()) => None,
        _ => Some(rest),
    }
}

/// The words after `chat` (or `chat new`); `env_target` is `CMUX_ON`, read when `--on` is
/// absent (an empty one is unset). No setting is read: [`parse_with`] reads one. Tests only: the
/// CLI runs [`parse_with`].
#[cfg(test)]
pub(super) fn parse(words: &[String], env_target: Option<String>) -> Result<Parsed, UsageError> {
    parse_with(words, env_target, || None)
}

/// [`parse`], with `setting` the `chat.on` read, called only when neither `--on` nor `CMUX_ON`
/// names a target (and never for `--help`).
pub(super) fn parse_with(
    words: &[String],
    env_target: Option<String>,
    setting: impl FnOnce() -> Option<String>,
) -> Result<Parsed, UsageError> {
    let mut start = Start {
        on: None,
        agent: None,
        model: None,
        cwd: None,
        name: None,
        prompt: None,
        attach: Vec::new(),
        environment: None,
        wait: false,
        timeout: None,
    };
    let mut index = 0;
    while let Some(word) = words.get(index).map(String::as_str) {
        if word == "--" {
            match words.get(index + 1..).unwrap_or_default() {
                [] => {}
                [text] => set_prompt(&mut start.prompt, text.clone())?,
                _ => return Err(UsageError::new("give the prompt as one quoted argument")),
            }
            break;
        }
        if !word.starts_with('-') || word == "-" {
            if index + 1 != words.len() {
                return Err(UsageError::new(format!("unexpected argument {word:?}")));
            }
            set_prompt(&mut start.prompt, word.to_owned())?;
            break;
        }
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
            "--on" => {
                if start.on.is_some() {
                    return Err(UsageError::new("give --on once"));
                }
                let on = value()?.trim().to_owned();
                if on.is_empty() {
                    return Err(UsageError::new(
                        "--on needs a target: here, cloud, vm, vm:new, vm:ID|NAME or a device",
                    ));
                }
                start.on = Some(on);
            }
            "--prompt" | "-p" => {
                let text = value()?;
                set_prompt(&mut start.prompt, text)?;
            }
            "--agent" | "--harness" => start.agent = Some(value()?),
            "--model" => start.model = Some(value()?),
            "--cwd" => start.cwd = Some(value()?),
            "--name" => start.name = Some(value()?),
            "--attach" => start.attach.push(value()?),
            "--environment" => {
                let environment = value()?.trim().to_owned();
                if environment.is_empty() {
                    return Err(UsageError::new("--environment needs an environment's id or name"));
                }
                start.environment = Some(environment);
            }
            "--timeout" => start.timeout = Some(value()?),
            "--wait" => start.wait = true,
            "--no-wait" => start.wait = false,
            _ => return Err(UsageError::new(format!("unexpected argument {word:?}"))),
        }
        index += 1;
    }
    start.on = pick_target(start.on.take(), env_target, setting);
    if start.on.as_deref() == Some("vm:") {
        return Err(UsageError::new("--on vm: needs new, or a VM's id or name"));
    }
    Ok(Parsed::Run(start))
}

/// The chat's target: `--on` (`flag`), else `CMUX_ON` (`env`), else the `chat.on` setting, else
/// None (here). A blank value is unset. `setting` is called only when the first two are unset, so
/// the app is asked only then.
pub(super) fn pick_target(
    flag: Option<String>,
    env: Option<String>,
    setting: impl FnOnce() -> Option<String>,
) -> Option<String> {
    let given = |value: Option<String>| {
        value.map(|target| target.trim().to_owned()).filter(|target| !target.is_empty())
    };
    given(flag).or_else(|| given(env)).or_else(|| given(setting()))
}

/// The app's `chat.on` value (`settings.get`, as `cmux settings get chat.on` reads it), or None:
/// no app, an app that does not answer within [`SETTING_TIMEOUT`], an unset key or a value that
/// is not a string. The `--socket` kind probe and the read share that one deadline.
fn setting_target(global: &GlobalArgs) -> Option<String> {
    let deadline = std::time::Instant::now().checked_add(SETTING_TIMEOUT)?;
    let left = || {
        deadline.checked_duration_since(std::time::Instant::now()).filter(|left| !left.is_zero())
    };
    let mut stream = setting_stream(
        || super::app::connect_command_within(global, Some(SETTING_TIMEOUT)),
        || super::app::socket_path(global).and_then(|path| super::app::connect(&path)),
    )?;
    let left = left()?;
    stream.set_write_timeout(Some(left)).ok()?;
    let answer = super::app::exchange_within(
        &mut stream,
        "settings.get",
        json!({ "path": TARGET_SETTING }),
        left,
    )
    .ok()?
    .ok()?;
    answer.get("value").and_then(Value::as_str).map(str::to_owned)
}

/// The app to read `chat.on` from: the one `--app-socket`, `--socket` or the environment names
/// (`named`, [`super::app::connect_command`]), or, when `--socket` names a daemon
/// (`socket.wrong_kind`), the app that owns it (`owner`, [`super::app::socket_path`]), which is
/// the app the chat itself reaches. Any other failure reads nothing.
fn setting_stream(
    named: impl FnOnce() -> Result<UnixStream, Value>,
    owner: impl FnOnce() -> Result<UnixStream, String>,
) -> Option<UnixStream> {
    match named() {
        Ok(stream) => Some(stream),
        Err(error) if error.get("code").and_then(Value::as_str) == Some("socket.wrong_kind") => {
            owner().ok()
        }
        Err(_) => None,
    }
}

fn set_prompt(slot: &mut Option<String>, text: String) -> Result<(), UsageError> {
    if slot.is_some() {
        return Err(UsageError::new("give the prompt once"));
    }
    *slot = Some(text);
    Ok(())
}

/// What `route` reads, each only when the target needs it.
pub(super) struct Reads<C, S, L> {
    /// The daemon's machine catalog (`machine.list`, `catalog: true`).
    pub catalog: C,
    /// The app's cloud sign-in now.
    pub signed_in: S,
    /// The app's `cloud list-machines` answer.
    pub cloud_machines: L,
}

/// Where target `on` runs a chat (module docs). A device is checked by the SDK's
/// [`cmux::resolve_chat_target`] against the catalog read now; a name that names exactly one
/// device is read as its id, and the id is what the check sees.
pub(super) fn route<C, S, L>(on: Option<&str>, reads: Reads<C, S, L>) -> Result<Route, Value>
where
    C: FnOnce() -> Result<Value, Value>,
    S: FnOnce() -> bool,
    L: FnOnce() -> Result<Value, Value>,
{
    let Some(on) = on else { return Ok(Route::Here) };
    if on == "here" {
        return Ok(Route::Here);
    }
    // `cloud` is cmux Cloud's choice of place; today it is `vm`'s (module docs).
    if on == "cloud" || on == "vm" {
        if let Err(refusal) = cmux::resolve_chat_target("cloud", &Value::Null, (reads.signed_in)())
        {
            return Err(refused(&refusal));
        }
        return my_vm(&(reads.cloud_machines)()?).map(Route::Cloud);
    }
    if let Some(vm) = on.strip_prefix("vm:") {
        if vm == "new" {
            return Ok(Route::Cloud(Machine::New));
        }
        let vm = vm.strip_prefix("machine:").unwrap_or(vm);
        let listed = (reads.cloud_machines)()?;
        // Signed out, the app lists no VMs: say to sign in, not that the VM is unknown.
        if listed.pointer("/account/signed_in") == Some(&Value::Bool(false)) {
            return Err(refused(&ChatTargetRefusal::SignedOut));
        }
        // Not loaded yet, the app lists no VMs: say to retry, not that the VM is unknown.
        if let Some(error) = not_loaded(&listed) {
            return Err(error);
        }
        return existing_vm(vm, Some(vm), &listed).map(Route::Cloud).map_err(|found| {
            refusal(
                "chat_target.unknown_vm",
                format!("no one VM of yours has the id or name {vm}"),
                LIST_VMS,
                json!({"vm": vm, "matches": found}),
            )
        });
    }
    let catalog = (reads.catalog)()?;
    let id = device_id(on, &catalog)?;
    let record = machines(&catalog).iter().find(|machine| text(machine, "id") == Some(id.as_str()));
    let origin = record.and_then(|machine| text(machine, "origin")).unwrap_or("local");
    let signed_in = origin == "cloud" && (reads.signed_in)();
    match cmux::resolve_chat_target(&id, &catalog, signed_in) {
        Err(refusal) => Err(refused(&refusal)),
        Ok(ChatTarget::Cloud) => Ok(Route::Cloud(Machine::New)),
        Ok(ChatTarget::Device { local: true, .. }) => Ok(Route::Here),
        Ok(ChatTarget::Device { id, local: false }) => match (origin, record) {
            ("cloud", Some(machine)) => {
                let listed = (reads.cloud_machines)()?;
                // Not loaded yet, the app lists no VMs: say to retry, as `vm` and `vm:NAME` do.
                if let Some(error) = not_loaded(&listed) {
                    return Err(error);
                }
                existing_vm(&id, text(machine, "name"), &listed).map(Route::Cloud).map_err(
                    |found| {
                        refusal(
                            "chat_target.unavailable",
                            format!("device {id} is a Cloud VM the app does not list as one VM"),
                            LIST_VMS,
                            json!({"device": id, "matches": found}),
                        )
                    },
                )
            }
            _ => Err(refusal(
                "chat_target.no_route",
                format!(
                    "device {id} ({origin}) runs agent chats, but the CLI cannot start one there yet"
                ),
                "open a workspace on it in the cmux app and start the chat there",
                json!({"device": id, "origin": origin}),
            )),
        },
    }
}

/// A retryable refusal when the app has not loaded its VM list yet (`loaded: false`).
fn not_loaded(listed: &Value) -> Option<Value> {
    (listed.get("loaded") == Some(&Value::Bool(false))).then(|| {
        retryable(refusal(
            "chat_target.unavailable",
            "the cmux app has not loaded your Cloud VMs yet".to_owned(),
            "run this command again in a moment",
            json!({}),
        ))
    })
}

/// `error`, marked retryable.
fn retryable(mut error: Value) -> Value {
    if let Some(map) = error.as_object_mut() {
        map.insert("retryable".to_owned(), json!(true));
    }
    error
}

/// The VM statuses `--on vm` does not reuse: a VM that is failing or going away.
const NOT_REUSED: &[&str] = &["failed", "deleting", "deleted", "destroyed"];

/// `--on vm`, "my VM" (Leo's CLI walkthrough, 2026-11-07; and `--on cloud` today): the one VM
/// of yours the app lists, a new one when you have none, or the one running VM of several. Several VMs and not
/// one running is refused with their names, never guessed; a paused VM resumes when the chat
/// starts on it (the app's `start-chat --target`).
fn my_vm(listed: &Value) -> Result<Machine, Value> {
    if listed.pointer("/account/signed_in") == Some(&Value::Bool(false)) {
        return Err(refused(&ChatTargetRefusal::SignedOut));
    }
    if let Some(error) = not_loaded(listed) {
        return Err(error);
    }
    let rows = listed.get("machines").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
    let usable: Vec<&Value> = rows
        .iter()
        .filter(|row| !text(row, "status").is_some_and(|status| NOT_REUSED.contains(&status)))
        .collect();
    let running: Vec<&Value> =
        usable.iter().copied().filter(|row| text(row, "status") == Some("running")).collect();
    // A VM the app is still making (`creating`, not failed) is mine too: never start a second.
    let making = listed
        .get("creating")
        .and_then(Value::as_array)
        .is_some_and(|rows| rows.iter().any(|row| text(row, "status") != Some("failed")));
    let id = match (usable.as_slice(), running.as_slice()) {
        ([], _) if making => {
            return Err(retryable(refusal(
                "chat_target.vm_starting",
                "your Cloud VM is still being made".to_owned(),
                "run this command again once `cmux vm list-machines` lists it",
                json!({}),
            )));
        }
        ([], _) => return Ok(Machine::New),
        ([only], _) | (_, [only]) => text(only, "machine_id"),
        _ => None,
    };
    if let Some(id) = id {
        return Ok(Machine::Target(id.to_owned()));
    }
    let names: Vec<&str> = usable
        .iter()
        .map(|row| text(row, "title").or(text(row, "machine_id")).unwrap_or(""))
        .collect();
    Err(refusal(
        "chat_target.which_vm",
        format!("you have {} Cloud VMs: {}", usable.len(), names.join(", ")),
        "name one with --on vm:NAME (`cmux vm list-machines`), or use --on vm:new",
        json!({"names": names}),
    ))
}

/// The app's existing Cloud VM with machine id `id`, else the one VM titled `name`, from its
/// `cloud list-machines` answer. Err: the ids that matched (none, or several).
pub(super) fn existing_vm(
    id: &str,
    name: Option<&str>,
    listed: &Value,
) -> Result<Machine, Vec<String>> {
    let rows = listed.get("machines").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
    if rows.iter().any(|row| text(row, "machine_id") == Some(id)) {
        return Ok(Machine::Target(id.to_owned()));
    }
    let titled: Vec<String> = rows
        .iter()
        .filter(|row| name.is_some() && text(row, "title") == name)
        .filter_map(|row| text(row, "machine_id").map(str::to_owned))
        .collect();
    match titled.as_slice() {
        [machine] => Ok(Machine::Target(machine.clone())),
        _ => Err(titled),
    }
}

/// The id `selector` names: a catalog machine with that id, else the one machine with that name.
fn device_id(selector: &str, catalog: &Value) -> Result<String, Value> {
    let machines = machines(catalog);
    if machines.iter().any(|machine| text(machine, "id") == Some(selector)) {
        return Ok(selector.to_owned());
    }
    let named: Vec<&str> = machines
        .iter()
        .filter(|machine| text(machine, "name") == Some(selector))
        .filter_map(|machine| text(machine, "id"))
        .collect();
    match named.as_slice() {
        [id] => Ok((*id).to_owned()),
        [] => Err(refused(&ChatTargetRefusal::UnknownDevice { id: selector.to_owned() })),
        ids => Err(refusal(
            "chat_target.ambiguous_device",
            format!("{} devices are named {selector}", ids.len()),
            &format!("give one id: {}", ids.join(", ")),
            json!({"name": selector, "ids": ids}),
        )),
    }
}

/// The SDK's refusal, with what to run next.
fn refused(refusal: &ChatTargetRefusal) -> Value {
    let next = match refusal {
        ChatTargetRefusal::SignedOut => "run `cmux login`, then this command again",
        _ => LIST_DEVICES,
    };
    self::refusal(refusal.code(), refusal.to_string(), next, json!({}))
}

/// A refusal whose message and `details.next` say what to run next.
fn refusal(code: &str, message: String, next: &str, mut details: Value) -> Value {
    if let Some(map) = details.as_object_mut() {
        map.insert("next".to_owned(), json!(next));
    }
    json!({"code": code, "message": format!("{message}; {next}"), "details": details,
           "retryable": false})
}

fn machines(catalog: &Value) -> &[Value] {
    cmux::catalog_machines(catalog)
}

fn text<'a>(machine: &'a Value, key: &str) -> Option<&'a str> {
    machine.get(key).and_then(Value::as_str)
}

fn run(global: &GlobalArgs, start: Start) -> i32 {
    let reads = Reads {
        catalog: || read_catalog(global),
        signed_in: || cloud_start_chat::app_signed_in(global),
        cloud_machines: || cloud_start_chat::app_machines(global),
    };
    let route = match route(start.on.as_deref(), reads) {
        Ok(route) => route,
        Err(error) => return super::wire::print_local_error(&error, global.output, 1),
    };
    let route = match in_environment(&start, route) {
        Ok(route) => route,
        Err(error) => return usage_failure(&error, global.output),
    };
    match route {
        Route::Here => match here_wait(&start) {
            // `--wait`: start, wait for the turn and print the reply (agents/turn.rs).
            Ok(Some(timeout)) => match new_args(&start) {
                Ok(args) => turn::run(global, &Begin::New(args), timeout),
                Err(error) => usage_failure(&error, global.output),
            },
            Ok(None) => match here_words(&global_words(global), &start) {
                Ok(words) => super::agents::run_if_requested(&words).unwrap_or(2),
                Err(error) => usage_failure(&error, global.output),
            },
            Err(error) => usage_failure(&error, global.output),
        },
        Route::Cloud(machine) => match cloud_words(&start, &machine) {
            Ok(words) => {
                let parsed = cloud_start_chat::parse(&words, read_stdin);
                match parsed {
                    Ok(cloud_start_chat::Parsed::Run(request)) => {
                        cloud_start_chat::start(global, &request)
                    }
                    Ok(cloud_start_chat::Parsed::Help) => {
                        print!("{USAGE}");
                        0
                    }
                    Err(error) => usage_failure(&error, global.output),
                }
            }
            Err(error) => usage_failure(&error, global.output),
        },
    }
}

/// The route once `--environment` is read: an environment makes the chat's machine, so `--on cloud`
/// (cmux Cloud's choice of place) takes a new machine in it instead of the VM it would reuse, and
/// `--on vm:new` makes its machine there. A chat here or on a machine that exists has no
/// environment to pick: refused, never dropped. Without `--environment` the route is unchanged.
pub(super) fn in_environment(start: &Start, route: Route) -> Result<Route, UsageError> {
    if start.environment.is_none() {
        return Ok(route);
    }
    match route {
        Route::Cloud(Machine::New) => Ok(Route::Cloud(Machine::New)),
        Route::Cloud(_) if start.on.as_deref() == Some("cloud") => Ok(Route::Cloud(Machine::New)),
        Route::Cloud(_) => Err(UsageError::new(
            "--environment makes a new machine; with --on cloud or --on vm:new, not a VM that \
             already has its environment",
        )),
        Route::Here => {
            Err(UsageError::new("--environment picks a Cloud chat's environment; add --on cloud"))
        }
    }
}

/// The daemon's machine catalog, read now through the SDK (`machine.list`, `catalog: true`).
fn read_catalog(global: &GlobalArgs) -> Result<Value, Value> {
    let (socket, _) = super::wire::resolve_socket_with_origin(global).map_err(|error| {
        json!({"code": "daemon.unreachable",
               "message": super::wire::resolve_failure_message(&error),
               "details": {}, "retryable": true})
    })?;
    let unreachable = |error: cmux::Error| {
        json!({"code": "daemon.unreachable", "message": error.to_string(), "details": {},
               "retryable": true})
    };
    let client =
        cmux::Client::connect(cmux::Config::from_socket_path(socket).with_timeout(CATALOG_TIMEOUT))
            .map_err(unreachable)?;
    client.call("machine.list", CallKind::Read, json!({"catalog": true})).map_err(unreachable)
}

/// The global options `global` holds, as words: the chat here runs with them wherever they were
/// typed (`cmux chat --prompt hi --json`, `cmux --socket S chat hi`).
pub(super) fn global_words(global: &GlobalArgs) -> Vec<String> {
    let mut words = Vec::new();
    let paths = [("--socket", &global.socket), ("--app-socket", &global.app_socket)];
    for (flag, value) in paths {
        if let Some(value) = value {
            words.extend([flag.to_owned(), value.to_string_lossy().into_owned()]);
        }
    }
    let texts = [
        ("--session", &global.session),
        ("--machine", &global.machine),
        ("--idempotency-key", &global.idempotency_key),
    ];
    for (flag, value) in texts {
        if let Some(value) = value {
            words.extend([flag.to_owned(), value.clone()]);
        }
    }
    if global.all_sessions {
        words.push("--all-sessions".to_owned());
    }
    match global.output {
        OutputMode::Human => {}
        OutputMode::Json => words.push("--json".to_owned()),
        OutputMode::JsonLines => words.push("--jsonl".to_owned()),
        OutputMode::Quiet => words.push("--quiet".to_owned()),
    }
    words
}

/// How long a chat here waits for its turn: None without `--wait`. `--timeout` is seconds, as
/// a Cloud chat takes it (default 900, at most 4 h), and goes only with `--wait`.
pub(super) fn here_wait(start: &Start) -> Result<Option<Duration>, UsageError> {
    if !start.wait {
        return match start.timeout {
            Some(_) => Err(UsageError::new("--timeout says how long --wait waits; add --wait")),
            None => Ok(None),
        };
    }
    let Some(text) = &start.timeout else { return Ok(Some(turn::DEFAULT_TIMEOUT)) };
    let seconds = text
        .parse::<u64>()
        .ok()
        .filter(|seconds| *seconds > 0)
        .ok_or_else(|| UsageError::new(format!("--timeout {text}: give seconds")))?;
    Ok(Some(Duration::from_secs(seconds).min(turn::MAX_TIMEOUT)))
}

/// `agents chat new …` with this start's settings, after the same globals.
pub(super) fn here_words(prefix: &[String], start: &Start) -> Result<Vec<String>, UsageError> {
    let mut words = prefix.to_vec();
    words.extend(["agents", "chat", "new"].map(str::to_owned));
    words.extend(new_args(start)?);
    Ok(words)
}

/// The words after `agents chat new` for this start (`-` read from stdin now).
pub(super) fn new_args(start: &Start) -> Result<Vec<String>, UsageError> {
    let mut words = Vec::new();
    for (flag, value) in [
        ("--harness", &start.agent),
        ("--model", &start.model),
        ("--cwd", &start.cwd),
        ("--name", &start.name),
    ] {
        if let Some(value) = value {
            words.extend([flag.to_owned(), value.clone()]);
        }
    }
    // Inline, so a path that starts with `-` stays a path.
    words.extend(start.attach.iter().map(|file| format!("--attach={file}")));
    if let Some(prompt) = &start.prompt {
        let prompt =
            if prompt == "-" { read_stdin().map_err(UsageError::new)? } else { prompt.clone() };
        words.extend(["--".to_owned(), prompt]);
    }
    Ok(words)
}

/// The `cloud start-chat` words for this start on `machine`.
pub(super) fn cloud_words(start: &Start, machine: &Machine) -> Result<Vec<String>, UsageError> {
    if start.model.is_some() || start.name.is_some() {
        return Err(UsageError::new(
            "--model and --name name a chat here; a Cloud chat takes --agent, --cwd and --prompt",
        ));
    }
    // Refused, never dropped: a Cloud chat's first prompt is text only (`cloud start-chat`).
    if !start.attach.is_empty() {
        return Err(UsageError::new(
            "--attach sends files with a chat here; a Cloud chat's first prompt is text only, so \
             nothing was started (put the files in the VM's folder, or start the chat here)",
        ));
    }
    let Some(prompt) = &start.prompt else {
        return Err(UsageError::new("a Cloud chat needs a first prompt: --prompt TEXT"));
    };
    let mut words = vec!["--prompt".to_owned(), prompt.clone()];
    match machine {
        Machine::Named(name) => words.extend(["--name".to_owned(), name.clone()]),
        Machine::Target(id) => words.extend(["--target".to_owned(), format!("machine:{id}")]),
        Machine::New => {}
    }
    for (flag, value) in [
        ("--agent", &start.agent),
        ("--cwd", &start.cwd),
        ("--environment", &start.environment),
        ("--timeout", &start.timeout),
    ] {
        if let Some(value) = value {
            words.extend([flag.to_owned(), value.clone()]);
        }
    }
    if start.wait {
        words.push("--wait".to_owned());
    }
    Ok(words)
}

pub(super) fn read_stdin() -> Result<String, String> {
    use std::io::Read as _;
    let mut text = String::new();
    std::io::stdin().read_to_string(&mut text).map(|_| text).map_err(|error| error.to_string())
}

fn usage_failure(error: &UsageError, output: OutputMode) -> i32 {
    super::app::failure("usage.invalid", &format!("cmux: {}\n{USAGE}", error.0), output, 2)
}

#[cfg(test)]
mod tests;
