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
mod chat;
mod control;
mod editor;
mod home;
mod launch;
mod link;
mod messages;
mod pipe;
mod render;
mod shutdown;
#[cfg(test)]
mod tests;
mod tui;
mod turn;

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
    /// `cmux chief shutdown` (shutdown.rs).
    pub shutdown: bool,
    /// `--no-wait-agents`: pipe mode ends with the turn that answers the
    /// message, not after the subagents it started (E22).
    pub no_wait_agents: bool,
}

/// `cmux [global options] chief …`; `None` when `args` names another scope.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let (scope, rest) = command_args.split_first()?;
    (scope == "chief").then(|| run(global, rest))
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
            "--harness" | "--model" | "--effort" | "--speed" | "--compactor-speed" => {
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
            "--no-wait-agents" => parsed.no_wait_agents = true,
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
    if args.shutdown {
        return shutdown::run(&global, args.chief_home.as_deref());
    }
    if let Some(control) = &args.control {
        return control::run(&global, args.chief_home.as_deref(), control, global.output);
    }
    let stdin_tty = std::io::stdin().is_terminal();
    let pipe_mode = args.prompt.is_some() || !stdin_tty;
    if !pipe_mode && !std::io::stdout().is_terminal() {
        eprintln!("cmux: {}", m.needs_tty);
        return 2;
    }
    let tail = if pipe_mode { 0 } else { args.history };
    let session = match Session::open(&global, tail, args.chief_home.as_deref()) {
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

/// The Chief conversation on one daemon: a request connection, and the
/// `conversation.events` stream on its own connection feeding `rx`.
struct Session {
    control: Link,
    conversation: String,
    socket: std::path::PathBuf,
    derived: bool,
    tx: Sender<Input>,
    rx: Receiver<Input>,
}

impl Session {
    /// Opens the Chief conversation; its event stream starts with a snapshot
    /// of the last `tail` messages.
    fn open(
        global: &GlobalArgs,
        tail: usize,
        chief_home: Option<&std::path::Path>,
    ) -> Result<Self, (i32, String)> {
        let m = messages();
        if global.machine.is_some() {
            return Err((2, m.machine_unsupported.into()));
        }
        let (socket, derived) = match target(global, chief_home)? {
            Target::Explicit(socket, derived) => (socket, derived),
            Target::Home(home) => (launch::ensure(&home).map_err(|why| (3, why))?, true),
        };
        let connect = || {
            Link::connect(&socket, derived)
                .map_err(|error| (3, super::wire::connect_failure(&socket, &error)))
        };
        let failed = |error: LinkError| match error {
            LinkError::Transport(message) => (3, message),
            LinkError::Rejected { code, .. } if code.starts_with("validation.invalid") => {
                // A daemon of another build: run its CLI (cli/skew.rs), else
                // name the exact fix. Stopping is enough: opening the Chief
                // again starts the home daemon with this build.
                let _ = super::skew::reexec_at_dead_end_on(&socket);
                let stop =
                    super::fix_command::stop_daemon(&super::fix_command::this_cli(), &socket);
                (1, m.no_conversations.replace("{stop}", &stop))
            }
            rejected => (1, rejected.to_string()),
        };
        let mut control = connect()?;
        let listed = control.call("conversation.list", json!({}), None).map_err(failed)?;
        let conversations = listed.as_array().cloned().unwrap_or_default();
        let chief = link::select_chief(&conversations).ok_or((1, m.no_chief.to_owned()))?;
        let conversation = chief.get("id").and_then(Value::as_str).unwrap_or("").to_owned();
        let (tx, rx) = channel();
        connect()?.into_events(&conversation, tail, tx.clone()).map_err(failed)?;
        Ok(Self { control, conversation, socket, derived, tx, rx })
    }

    /// Opens the event stream again after it ended with a gap: a fresh
    /// snapshot of the last `tail` messages, then live items.
    fn reopen(&mut self, tail: usize) -> Result<(), LinkError> {
        let link = Link::connect(&self.socket, self.derived)
            .map_err(|e| LinkError::Transport(e.to_string()))?;
        link.into_events(&self.conversation, tail, self.tx.clone())
    }

    /// Sends `text` as the person; the new message's seq.
    /// Sends `text`; the new message's seq and id.
    fn send(&mut self, text: &str) -> Result<(u64, String), LinkError> {
        let key = link::new_message_id();
        let result = self.control.call(
            "conversation.send",
            link::send_params(&self.conversation, text),
            Some(&key),
        )?;
        let message = result.pointer("/value/message");
        let seq = message.and_then(|m| m.get("seq")).and_then(Value::as_u64).unwrap_or(0);
        let id = message.and_then(|m| m.get("id")).and_then(Value::as_str).unwrap_or_default();
        Ok((seq, id.to_owned()))
    }

    /// Messages with seq in `after+1 .. before`, oldest first.
    fn between(&mut self, after: u64, before: u64) -> Result<Vec<Value>, LinkError> {
        let limit = before.saturating_sub(after + 1).clamp(1, 500);
        let params =
            json!({"conversation": self.conversation, "before_seq": before, "limit": limit});
        let messages = self.control.call("conversation.history", params, None)?;
        Ok(messages
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|m| m.get("seq").and_then(Value::as_u64).is_some_and(|s| s > after))
            .collect())
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
        let (socket, derived) = super::wire::resolve_socket_with_origin(global).map_err(|_| {
            (2, crate::localization::catalog().startup.invalid_session_name.to_owned())
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
    Ok(Target::Home(home))
}

/// Whether the output mode prints JSON.
pub(super) fn json_output(output: OutputMode) -> bool {
    matches!(output, OutputMode::Json | OutputMode::JsonLines)
}
