//! `cmux chief`: the Chief conversation in a terminal. The CLI is one more
//! client of the conversation Home shows and the Chief's brain answers, in
//! the session daemon (no second store): a message sent here is a
//! `user_local` `message.send`, so Home shows it at once and the brain
//! wakes as for Home; Home's messages and the Chief's replies (with the
//! live drafts) arrive on the subscribe stream.
//!
//! Pipe mode (`-p TEXT`, or text on stdin) sends one message, prints the
//! reply and exits when the Chief's turn ends. On a terminal it opens the
//! chat (`tui`).

mod adapter;
mod avatar;
mod backend;
mod chat;
mod control;
mod editor;
mod home;
mod hyperlink;
mod launch;
mod link;
mod messages;
mod pipe;
pub(in crate::cli) mod registry;
mod relocate;
mod render;
mod script;
mod script_text;
mod shutdown;
#[cfg(test)]
mod tests;
mod tui;
mod turn;
mod usage;

use std::io::IsTerminal;
use std::sync::mpsc::{Receiver, Sender, channel};

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};
use link::{Link, LinkError};
use messages::messages;

/// What the chat's single receive loop hears.
#[derive(Debug)]
pub(super) enum Input {
    /// A `conversation.events` item.
    Daemon(Value),
    /// The event stream ended (its end reason, or "closed").
    Closed(String),
    /// A terminal event (chat only).
    Term(crossterm::event::Event),
}

/// How long pipe mode waits for the Chief's turn by default: a Chief turn
/// can take long, but a script must never wait forever.
pub(super) const DEFAULT_TIMEOUT_SECS: u64 = 30 * 60;

/// The client kind of an open `cmux chief` chat (pipe or terminal), in `client.list`.
const CHAT_CLIENT_KIND: &str = "chief-chat";

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct Args {
    pub prompt: Option<String>,
    pub timeout_secs: Option<u64>,
    pub history: usize,
    /// `--chief-home DIR`: an isolated Chief (its own daemon and brain).
    pub chief_home: Option<std::path::PathBuf>,
    pub help: bool,
    /// `chief engine …` or `chief stop`.
    pub control: Option<control::Control>,
    /// `--chief ID` with `engine` or `stop`: that Chief (chief-brains-v1), not the default (cx-mbbee).
    pub chief: Option<String>,
    /// `cmux chief shutdown` (shutdown.rs).
    pub shutdown: bool,
    /// `--no-wait-agents`: pipe mode ends with the turn that answers the
    /// message, not after the subagents it started (E22).
    pub no_wait_agents: bool,
    /// `--chat`, `--cloud` and the cloud lease flags (script.rs).
    pub target: script::TargetArgs,
}

/// `cmux [global options] chief …`; `None` when `args` names another scope.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let (scope, rest) = command_args.split_first()?;
    (scope == "chief").then(|| run(global, rest))
}

/// `cmux avatar set|get` (participant-avatars-v1): a person's or a Chief's picture.
pub(super) fn run_avatar_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let (scope, rest) = command_args.split_first()?;
    (scope == "avatar").then(|| avatar::run(&global, rest))
}

pub(super) fn parse_args(args: &[String]) -> Result<Args, String> {
    let mut parsed =
        Args { history: 20, timeout_secs: Some(DEFAULT_TIMEOUT_SECS), ..Args::default() };
    let mut index = 0;
    while index < args.len() {
        let arg = args[index].as_str();
        let (flag, inline) = match arg.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (arg, None),
        };
        let first = parsed.control.is_none() && parsed.prompt.is_none();
        let mut value = || -> Result<String, String> {
            if let Some(value) = inline.clone() {
                return Ok(value);
            }
            index += 1;
            args.get(index).cloned().ok_or_else(|| format!("{flag} needs a value"))
        };
        match flag {
            "engine" if first => parsed.control = Some(control::Control::Engine(Vec::new())),
            "stop" if first => parsed.control = Some(control::Control::Stop(None)),
            "shutdown" if first => parsed.shutdown = true,
            name if !name.starts_with('-')
                && matches!(parsed.control, Some(control::Control::Stop(None))) =>
            {
                parsed.control = Some(control::Control::Stop(Some(name.to_owned())));
            }
            "--harness"
            | "--model"
            | "--effort"
            | "--speed"
            | "--compactor-speed"
            | "--compactor-harness"
            | "--compactor-model"
            | "--reactions-can-wake"
            | "--classifier-harness"
            | "--classifier-model"
            | "--classifier-prompt" => {
                let key = flag.trim_start_matches("--").replace('-', "_");
                let value = value()?;
                match &mut parsed.control {
                    Some(control::Control::Engine(changes)) => changes.push((key, value)),
                    _ => return Err(format!("{flag} goes with `cmux chief engine`")),
                }
            }
            "-h" | "--help" | "help" => parsed.help = true,
            "-p" | "--prompt" => parsed.prompt = Some(value()?),
            "--timeout" => {
                let text = value()?;
                let secs: u64 =
                    text.parse().map_err(|_| format!("--timeout takes seconds, not {text}"))?;
                parsed.timeout_secs = (secs > 0).then_some(secs);
            }
            "--chief-home" => parsed.chief_home = Some(value()?.into()),
            "--chief" => {
                let id = value()?;
                // `--chief --json` is a missing id, not a Chief named `--json`.
                if inline.is_none() && id.starts_with('-') {
                    return Err("--chief needs a Chief id (cmux chief list)".into());
                }
                parsed.chief = Some(id);
            }
            "--no-wait-agents" => parsed.no_wait_agents = true,
            "--chat" | "--cloud" | "--cloud-api" | "--cloud-token-file" | "--cloud-auth" => {
                parsed.target.flag(flag, &mut value)?;
            }
            "--history" => {
                let text = value()?;
                let n: usize =
                    text.parse().map_err(|_| format!("--history takes a count, not {text}"))?;
                parsed.history = n.min(500);
            }
            other => return Err(format!("unknown argument {other}")),
        }
        index += 1;
    }
    if parsed.chief.is_some() && parsed.control.is_none() {
        return Err("--chief goes with `cmux chief engine` or `cmux chief stop`".into());
    }
    Ok(parsed)
}

fn run(global: GlobalArgs, args: &[String]) -> i32 {
    // The CLI as a whole defers termination signals to its own watchers;
    // the chat and pipe mode end at once on SIGTERM, SIGINT or SIGHUP (the
    // chat reads Ctrl+C as a key in raw mode).
    if crate::restore_default_termination_signals().is_err() {
        return 130;
    }
    let m = messages();
    if args.first().is_some_and(|word| registry::WORDS.contains(&word.as_str())) {
        return registry::run(&global, args);
    }
    if args.first().is_some_and(|word| word == "move") {
        return relocate::run(&global, &args[1..]);
    }
    if args.first().is_some_and(|word| word == "usage") {
        return usage::run(&global, &args[1..]);
    }
    if args.first().is_some_and(|word| script::WORDS.contains(&word.as_str())) {
        return script::run(&global, args);
    }
    let args = match parse_args(args) {
        Ok(args) => args,
        Err(error) => {
            eprintln!("cmux: {error}\n\n{}", m.usage);
            return 2;
        }
    };
    if args.help {
        println!("{}", m.usage);
        return 0;
    }
    let word = match &args.control {
        _ if args.shutdown => Some("shutdown"),
        Some(control::Control::Engine(changes)) if !changes.is_empty() => Some("engine"),
        Some(control::Control::Stop(_)) => Some("stop"),
        _ => None,
    };
    if let Some(refusal) =
        word.and_then(|word| registry::agent_control_refusal(&format!("cmux chief {word}"), word))
    {
        return super::wire::print_operation_error(&refusal, global.output);
    }
    if args.shutdown {
        return shutdown::run(&global, args.chief_home.as_deref());
    }
    if let Some(control) = &args.control {
        return control::run(
            &global,
            args.chief_home.as_deref(),
            control,
            args.chief.as_deref(),
            global.output,
        );
    }
    // cx-tgf4h: with agents off in this build session no Chief turn can
    // run; refuse before anything starts or is sent (a send would wait for
    // a reply that never comes).
    if cmux_tui_core::agent_launch::disabled() {
        let refusal = cmux_tui_core::agent_launch::refusal(m.agents_disabled);
        return super::wire::print_operation_error(&refusal, global.output);
    }
    let stdin_tty = std::io::stdin().is_terminal();
    let pipe_mode = args.prompt.is_some() || !stdin_tty;
    if !pipe_mode && !std::io::stdout().is_terminal() {
        eprintln!("cmux: {}", m.needs_tty);
        return 2;
    }
    let tail = if pipe_mode { 0 } else { args.history };
    let target = match args.target.resolve() {
        Ok(target) => target,
        Err(error) => {
            eprintln!("cmux: {error}");
            return 2;
        }
    };
    let session = match Session::open(&global, tail, args.chief_home.as_deref(), &target) {
        Ok(session) => session,
        Err((code, message)) => {
            eprintln!("cmux: {message}");
            return code;
        }
    };
    if pipe_mode {
        let text = match args.prompt.clone() {
            Some(text) => text,
            None => {
                let mut text = String::new();
                if let Err(error) = std::io::Read::read_to_string(&mut std::io::stdin(), &mut text)
                {
                    eprintln!("cmux: {error}");
                    return 2;
                }
                text
            }
        };
        pipe::run(session, &text, &args, global.output)
    } else {
        tui::run(session)
    }
}

/// Which chat a `cmux chief` command opens, and on which owner.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct ChatTarget {
    /// `--chat ID`: that conversation; none: the Chief conversation (local)
    /// or the newest chat with a Chief (cloud).
    pub chat: Option<String>,
    /// `--cloud`: the cloud owners through the daemon's cloud proxy.
    pub cloud: bool,
    /// `--cloud-api` with a token or tailnet auth: the lease to set first.
    pub lease: Option<backend::CloudLease>,
}

/// The chat on one daemon: a request connection, and the event stream on
/// its own connection feeding `rx`.
struct Session {
    client: backend::ChatClient,
    conversation: String,
    /// The chat's summary when it opened (title, participants).
    summary: Value,
    /// The chat's Chief (`backend::chief_of`).
    chief: String,
    socket: std::path::PathBuf,
    derived: bool,
    tx: Sender<Input>,
    rx: Receiver<Input>,
    /// Ends the current event stream when replaced or dropped.
    _events: Option<link::EventsHandle>,
}

impl Session {
    /// Opens the chat `target` names; its event stream starts with a
    /// snapshot of the last `tail` messages.
    fn open(
        global: &GlobalArgs,
        tail: usize,
        chief_home: Option<&std::path::Path>,
        target: &ChatTarget,
    ) -> Result<Self, (i32, String)> {
        let mut session = Self::connect(global, chief_home, target)?;
        session.open_chat(target.chat.as_deref(), tail)?;
        Ok(session)
    }

    /// The request connection only (scripts that need no stream yet).
    fn connect(
        global: &GlobalArgs,
        chief_home: Option<&std::path::Path>,
        chat: &ChatTarget,
    ) -> Result<Self, (i32, String)> {
        let m = messages();
        if global.machine.is_some() {
            return Err((2, m.machine_unsupported.into()));
        }
        let (socket, derived) = match target(global, chief_home)? {
            Target::Explicit(socket, derived) => (socket, derived),
            Target::Home(home) => (launch::ensure(&home).map_err(|why| (3, why))?, true),
        };
        let mut control = Link::connect(&socket, derived)
            .map_err(|error| (3, super::wire::connect_failure(&socket, &error)))?;
        // The chat names its connection `chief-chat` for as long as it runs: a DEV app restarts a
        // keyless Chief owner only while no such client is attached (CmuxNextDaemon
        // OwnerIdleProbe). Best effort: a daemon that refuses it still serves the chat.
        let named = json!({"client": "current", "name": "cmux chief", "kind": CHAT_CLIENT_KIND});
        let _ = control.call("client.metadata.update", named, None);
        let owner = if chat.cloud { backend::Owner::Cloud } else { backend::Owner::Local };
        let mut client = backend::ChatClient { link: control, owner };
        if let Some(lease) = &chat.lease {
            client.lease(lease).map_err(|e| {
                (1, script_text::text().lease_failed.replace("{reason}", &e.to_string()))
            })?;
        }
        let (tx, rx) = channel();
        Ok(Self {
            client,
            conversation: String::new(),
            summary: Value::Null,
            chief: adapter::AGENT_MUX.into(),
            socket,
            derived,
            tx,
            rx,
            _events: None,
        })
    }

    /// The daemon refusal of a chat request as the CLI says it.
    fn failed(&self, error: LinkError) -> (i32, String) {
        let m = messages();
        match error {
            LinkError::Transport(message) => (3, message),
            LinkError::Rejected { code, .. } if code.starts_with("validation.invalid") => {
                // A daemon of another build: run its CLI (cli/skew.rs), else
                // name the exact fix. Stopping is enough: opening the Chief
                // again starts the home daemon with this build.
                let _ = super::skew::reexec_at_dead_end_on(&self.socket);
                let stop =
                    super::fix_command::stop_daemon(&super::fix_command::this_cli(), &self.socket);
                (1, m.no_conversations.replace("{stop}", &stop))
            }
            LinkError::Rejected { code, .. } if code.contains("forbidden") => {
                (1, script_text::text().cloud_app_lease.to_owned())
            }
            rejected => (1, rejected.to_string()),
        }
    }

    /// Finds the chat `chat` names (or the default one) and opens its event
    /// stream, ending the stream of the chat open before.
    fn open_chat(&mut self, chat: Option<&str>, tail: usize) -> Result<(), (i32, String)> {
        self.select(chat)?;
        self._events = None;
        self.reopen(tail).map_err(|e| self.failed(e))
    }

    /// Makes the chat `chat` names (or the default one) current, with no
    /// event stream.
    fn select(&mut self, chat: Option<&str>) -> Result<(), (i32, String)> {
        let chats = self.client.chats().map_err(|e| self.failed(e))?;
        let summary = pick_chat(&chats, chat, self.client.owner).map_err(|why| (1, why))?;
        self.conversation = summary.get("id").and_then(Value::as_str).unwrap_or("").to_owned();
        self.chief = backend::chief_of(&summary);
        self.summary = summary;
        Ok(())
    }

    /// Opens the event stream again after it ended with a gap: a fresh
    /// snapshot of the last `tail` messages, then live items.
    fn reopen(&mut self, tail: usize) -> Result<(), LinkError> {
        let link = Link::connect(&self.socket, self.derived)
            .map_err(|e| LinkError::Transport(e.to_string()))?;
        let client = backend::ChatClient { link, owner: self.client.owner };
        self._events = Some(client.into_events(&self.conversation, tail, self.tx.clone())?);
        Ok(())
    }

    /// Sends `text` as the person; the new message's seq and id.
    fn send(&mut self, text: &str) -> Result<(u64, String), LinkError> {
        self.send_parts(vec![json!({"type": "text", "text": text})], None, None)
    }

    /// Sends `parts` (a reply to `reply_to`, in the thread of `thread_root`,
    /// when given); the new message's seq and id.
    fn send_parts(
        &mut self,
        parts: Vec<Value>,
        reply_to: Option<Value>,
        thread_root: Option<&str>,
    ) -> Result<(u64, String), LinkError> {
        let message = match self.client.owner {
            // `conversation.send` takes no thread root: a thread reply is the op.
            backend::Owner::Local if thread_root.is_none() => {
                let key = link::new_message_id();
                let params = link::send_parts_params(&self.conversation, parts, reply_to);
                let result = self.client.link.call("conversation.send", params, Some(&key))?;
                result.pointer("/value/message").cloned().unwrap_or(Value::Null)
            }
            _ => self.client.send(&self.conversation, parts, reply_to, thread_root)?,
        };
        let seq = message.get("seq").and_then(Value::as_u64).unwrap_or(0);
        let id = message.get("id").and_then(Value::as_str).unwrap_or_default();
        Ok((seq, id.to_owned()))
    }

    /// Messages with seq in `after+1 .. before`, oldest first.
    fn between(&mut self, after: u64, before: u64) -> Result<Vec<Value>, LinkError> {
        let limit = before.saturating_sub(after + 1).clamp(1, 200) as usize;
        let messages = self.client.history(&self.conversation, before, limit)?;
        Ok(messages
            .into_iter()
            .filter(|m| m.get("seq").and_then(Value::as_u64).is_some_and(|s| s > after))
            .collect())
    }
}

/// The chat `chat` names among `chats` (an id, or a unique title), or the
/// default chat: the Chief conversation (local), the newest chat with an
/// agent (cloud).
fn pick_chat(chats: &[Value], chat: Option<&str>, owner: backend::Owner) -> Result<Value, String> {
    let t = script_text::text();
    let text = |c: &Value, key: &str| c.get(key).and_then(Value::as_str).unwrap_or("").to_owned();
    if let Some(wanted) = chat {
        if let Some(found) = chats.iter().find(|c| text(c, "id") == wanted) {
            return Ok(found.clone());
        }
        let titled: Vec<&Value> =
            chats.iter().filter(|c| text(c, "title").eq_ignore_ascii_case(wanted)).collect();
        return match titled.as_slice() {
            [one] => Ok((*one).clone()),
            [] => Err(t.no_such_chat.replace("{chat}", wanted)),
            _ => Err(t.ambiguous_chat.replace("{chat}", wanted)),
        };
    }
    match owner {
        backend::Owner::Local => {
            link::select_chief(chats).cloned().ok_or_else(|| messages().no_chief.to_owned())
        }
        backend::Owner::Cloud => chats
            .iter()
            .find(|c| {
                c.pointer("/inbox/dm_peer")
                    .and_then(Value::as_str)
                    .is_some_and(|peer| peer.starts_with("agent_"))
            })
            .or_else(|| chats.first())
            .cloned()
            .ok_or_else(|| t.no_cloud_chats.to_owned()),
    }
}

/// Where `cmux chief` connects.
pub(super) enum Target {
    /// `--socket` or `--session`: connect only, start nothing.
    Explicit(std::path::PathBuf, bool),
    /// The Chief home's conversation owner, started with its brain when
    /// they are not running.
    Home(home::ChiefHome),
}

fn target(
    global: &GlobalArgs,
    chief_home: Option<&std::path::Path>,
) -> Result<Target, (i32, String)> {
    let m = messages();
    if global.socket.is_some() || global.session.is_some() {
        if chief_home.is_some() {
            return Err((2, m.home_and_socket.into()));
        }
        let (socket, derived) =
            super::wire::resolve_socket_with_origin(global).map_err(|error| {
                (super::wire::RESOLVE_FAILURE_EXIT, super::wire::resolve_failure_message(&error))
            })?;
        if link::is_brain_socket(&socket) {
            return Err((1, m.brain_socket.replace("{socket}", &socket.display().to_string())));
        }
        return Ok(Target::Explicit(socket, derived));
    }
    let user_home = std::env::var_os("HOME").map(std::path::PathBuf::from).unwrap_or_default();
    let cwd = std::env::current_dir().unwrap_or_default();
    let home = home::ChiefHome::resolve(chief_home, |k| std::env::var(k).ok(), &user_home, &cwd);
    if link::is_brain_socket(&home.root) {
        return Err((1, m.brain_socket.replace("{socket}", &home.root.display().to_string())));
    }
    // cmux NEXT adopts the shared Chief home once (build_adopt.rs).
    if !home.isolated {
        crate::build_adopt::chief_for_cli(&home.root);
    }
    Ok(Target::Home(home))
}

/// Whether the output mode prints JSON.
pub(super) fn json_output(output: OutputMode) -> bool {
    matches!(output, OutputMode::Json | OutputMode::JsonLines)
}

/// The person's Chief home this build resolves (no `--chief-home`; None for
/// an isolated launch or without `HOME`): the app's one-time adoption at
/// launch (build_adopt.rs).
pub(crate) fn home_for_adopt() -> Option<std::path::PathBuf> {
    let user_home = std::env::var_os("HOME").map(std::path::PathBuf::from)?;
    let cwd = std::env::current_dir().unwrap_or_default();
    let home = home::ChiefHome::resolve(None, |k| std::env::var(k).ok(), &user_home, &cwd);
    (!home.isolated).then_some(home.root)
}
