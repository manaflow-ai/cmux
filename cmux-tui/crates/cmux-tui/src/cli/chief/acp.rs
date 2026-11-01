//! `cmux chief acp`: the Chief as an ACP agent on stdin and stdout, so the
//! agent chat's harness picker offers a chat with the Chief (acpmux's
//! built-in `chief` harness runs this; user, 2026-10-30).
//!
//! It is one more client of the conversation Home shows, like pipe mode: a
//! prompt is a `user_local` `message.send` in the Chief conversation, so Home
//! shows it at once and the brain wakes as for Home, and the reply streams
//! back as `agent_message_chunk` updates (live drafts, then the posted
//! message) until the turn that answers it ends ([`super::pipe::follow`]).
//!
//! The Chief keeps one chat that never ends, so every ACP session is that one
//! chat: `session/new` and `session/load` (any id) answer at once, and the
//! link to the Chief opens at the first prompt, so acpmux's model probe
//! (spawn, `initialize`, `session/new`, kill) never starts a Chief. A prompt's text
//! blocks (and the text of embedded resources and links) are the message;
//! images are not offered (`promptCapabilities.image` is false).
//! `session/cancel` ends the wait with `cancelled`; the message stays in the
//! conversation and the Chief still answers it in Home, as when a person
//! leaves Home mid-turn. Replies the Chief posts later (its subagents'
//! reports) show in Home; with `--wait-agents` a prompt waits for them too.
//!
//! Wire: newline-delimited JSON-RPC 2.0, ACP protocol version 1. The prompt
//! runs on its own thread, so a cancel read on stdin reaches it.

use std::io::{BufRead, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};

use cmux_conversation::agent_sender::AgentSender;
use serde_json::{Value, json};

use super::messages::messages;
use super::pipe::{CANCEL, Ending, Follow, ReplySink, follow};
use super::render::message_text;
use super::{ChatTarget, DEFAULT_TIMEOUT_SECS, Input, Session};
use crate::cli::GlobalArgs;

/// The ACP protocol version this adapter speaks.
const PROTOCOL_VERSION: u64 = 1;

/// JSON-RPC: the method is not one this agent has.
const METHOD_NOT_FOUND: i64 = -32601;
/// JSON-RPC: the params are wrong (an empty prompt).
const INVALID_PARAMS: i64 = -32602;
/// The Chief could not take or answer the message.
const CHIEF_ERROR: i64 = -32000;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Options {
    chief_home: Option<std::path::PathBuf>,
    timeout_secs: Option<u64>,
    wait_agents: bool,
}

fn parse(args: &[String]) -> Result<Options, String> {
    let mut options = Options { timeout_secs: Some(DEFAULT_TIMEOUT_SECS), ..Options::default() };
    let mut words = args.iter();
    while let Some(word) = words.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word.as_str(), None),
        };
        let mut value = || {
            inline.clone().or_else(|| words.next().cloned()).ok_or(format!("{flag} needs a value"))
        };
        match flag {
            "--chief-home" => options.chief_home = Some(value()?.into()),
            "--timeout" => {
                let text = value()?;
                let secs: u64 =
                    text.parse().map_err(|_| format!("--timeout takes seconds, not {text}"))?;
                options.timeout_secs = (secs > 0).then_some(secs);
            }
            "--wait-agents" => options.wait_agents = true,
            other => return Err(format!("unknown argument {other}")),
        }
    }
    Ok(options)
}

/// Writes one JSON-RPC line to stdout; every writer shares it.
#[derive(Clone)]
struct Out(Arc<Mutex<std::io::Stdout>>);

impl Out {
    fn send(&self, value: &Value) {
        let mut stdout = self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let _ = writeln!(stdout, "{value}");
        let _ = stdout.flush();
    }

    fn result(&self, id: &Value, result: Value) {
        self.send(&json!({"jsonrpc": "2.0", "id": id, "result": result}));
    }

    fn error(&self, id: &Value, code: i64, message: &str) {
        self.send(
            &json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}),
        );
    }
}

/// A prompt for the thread that owns the Chief connection.
struct Job {
    id: Value,
    session: String,
    text: String,
    generation: u64,
    /// Another agent that sent the prompt (`_meta.acpmux.sender`), None for
    /// the person.
    sender: Option<AgentSender>,
}

/// What the main thread shares with the Chief thread to cancel a prompt.
#[derive(Default)]
struct Cancel {
    /// The running prompt's generation (0: none).
    running: AtomicU64,
    /// The generation a `session/cancel` named.
    cancelled: AtomicU64,
    /// Wakes the running wait (the Chief session's input channel).
    wake: Mutex<Option<Sender<Input>>>,
}

pub(super) fn run(global: &GlobalArgs, args: &[String]) -> i32 {
    let options = match parse(args) {
        Ok(options) => options,
        Err(error) => {
            eprintln!("cmux: {error}\n\n{}", messages().usage);
            return 2;
        }
    };
    let out = Out(Arc::new(Mutex::new(std::io::stdout())));
    let cancel = Arc::new(Cancel::default());
    let (jobs, inbox) = channel::<Job>();
    {
        let (global, out, cancel) = (global.clone(), out.clone(), cancel.clone());
        std::thread::spawn(move || chief_thread(&global, &options, &out, &cancel, inbox));
    }
    let mut generation = 0u64;
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let Ok(request) = serde_json::from_str::<Value>(&line) else {
            out.send(&json!({"jsonrpc": "2.0", "id": null,
                             "error": {"code": -32700, "message": "parse error"}}));
            continue;
        };
        let method = request.get("method").and_then(Value::as_str).unwrap_or("");
        let params = request.get("params").cloned().unwrap_or(Value::Null);
        let Some(id) = request.get("id").cloned() else {
            // A notification: only a cancel means anything here.
            if method == "session/cancel" {
                let running = cancel.running.load(Ordering::SeqCst);
                cancel.cancelled.store(running, Ordering::SeqCst);
                let wake = cancel.wake.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                if let Some(wake) = wake.as_ref() {
                    let _ = wake.send(Input::Closed(CANCEL.into()));
                }
            }
            continue;
        };
        let session = || params.get("sessionId").and_then(Value::as_str).map(str::to_owned);
        let job = match method {
            "initialize" => {
                out.result(&id, initialize());
                continue;
            }
            "authenticate" => {
                out.result(&id, json!({}));
                continue;
            }
            // Answered at once: the Chief link opens at the first prompt, so acpmux's model
            // probe (spawn, initialize, session/new, kill) never starts or wakes a Chief.
            "session/new" => {
                let session_id = format!("chief-{}", super::link::new_message_id());
                out.result(&id, json!({"sessionId": session_id}));
                continue;
            }
            "session/load" => {
                out.result(&id, json!({}));
                continue;
            }
            "session/prompt" => {
                let text = prompt_text(params.get("prompt"));
                if text.trim().is_empty() {
                    out.error(&id, INVALID_PARAMS, messages().empty_message);
                    continue;
                }
                generation += 1;
                cancel.running.store(generation, Ordering::SeqCst);
                let sender = prompt_sender(&params);
                Job { id, session: session().unwrap_or_default(), text, generation, sender }
            }
            other => {
                out.error(&id, METHOD_NOT_FOUND, &format!("cmux chief acp has no method {other}"));
                continue;
            }
        };
        if jobs.send(job).is_err() {
            break;
        }
    }
    0
}

/// The `initialize` result: protocol 1, sessions that load, text prompts.
fn initialize() -> Value {
    json!({
        "protocolVersion": PROTOCOL_VERSION,
        "agentCapabilities": {
            "loadSession": true,
            "promptCapabilities": {"image": false, "audio": false, "embeddedContext": true},
        },
        "authMethods": [],
        "agentInfo": {"name": "cmux-chief", "title": messages().chief,
                      "version": env!("CARGO_PKG_VERSION")},
    })
}

/// The agent acpmux says sent a prompt (`_meta.acpmux.sender`, from
/// another session's `acpmux send` or task): its message goes to the Chief
/// as that agent's, never as the owner's. None for the person's prompt.
fn prompt_sender(params: &Value) -> Option<AgentSender> {
    let sender = params.pointer("/_meta/acpmux/sender")?;
    let field = |key: &str| sender.get(key).and_then(Value::as_str);
    AgentSender::new(field("name")?, field("class"), field("threadId"))
}

/// The message a prompt's content blocks make: text blocks, an embedded
/// resource's text and a link's target, joined by blank lines.
fn prompt_text(prompt: Option<&Value>) -> String {
    let str_of = |v: &Value, key: &str| v.get(key).and_then(Value::as_str).map(str::to_owned);
    let pieces: Vec<String> = prompt
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|block| match block.get("type").and_then(Value::as_str) {
            Some("text") => str_of(block, "text"),
            Some("resource") => block.get("resource").and_then(|r| str_of(r, "text")),
            Some("resource_link") => {
                let uri = str_of(block, "uri")?;
                Some(match str_of(block, "name") {
                    Some(name) if name != uri => format!("[{name}]({uri})"),
                    _ => uri,
                })
            }
            _ => None,
        })
        .filter(|piece| !piece.trim().is_empty())
        .collect();
    pieces.join("\n\n")
}

/// Owns the Chief connection: opens it at the first prompt (and again after
/// it was lost), then runs each prompt to its turn's end.
fn chief_thread(
    global: &GlobalArgs,
    options: &Options,
    out: &Out,
    cancel: &Cancel,
    inbox: std::sync::mpsc::Receiver<Job>,
) {
    let m = messages();
    let mut chief: Option<Session> = None;
    for Job { id, session: session_id, text, generation, sender } in inbox {
        if chief.is_none() {
            if cmux_tui_core::agent_launch::disabled() {
                out.error(&id, CHIEF_ERROR, m.agents_disabled);
                continue;
            }
            match Session::open(global, 0, options.chief_home.as_deref(), &ChatTarget::default()) {
                Ok(session) => {
                    *cancel.wake.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
                        Some(session.tx.clone());
                    chief = Some(session);
                }
                Err((_, message)) => {
                    out.error(&id, CHIEF_ERROR, &message);
                    continue;
                }
            }
        }
        let Some(session) = chief.as_mut() else { continue };
        session.sender = sender;
        let (seq, message_id) = match session.send(&text) {
            Ok(sent) => sent,
            Err(error) => {
                out.error(&id, CHIEF_ERROR, &m.rejected.replace("{reason}", &error.to_string()));
                // A lost connection opens the chat again at the next prompt.
                if matches!(error, super::link::LinkError::Transport(_)) {
                    chief = None;
                }
                continue;
            }
        };
        let watch = Follow {
            seq,
            id: &message_id,
            wait_agents: options.wait_agents,
            stream: true,
            timeout_secs: options.timeout_secs,
        };
        let mut sink = Updates::new(out.clone(), session_id);
        let cancelled = || cancel.cancelled.load(Ordering::SeqCst) == generation;
        match follow(session, &watch, &mut sink, &cancelled) {
            Ending::Done => out.result(&id, json!({"stopReason": "end_turn"})),
            Ending::Cancelled => out.result(&id, json!({"stopReason": "cancelled"})),
            Ending::TimedOut => {
                let secs = options.timeout_secs.unwrap_or_default().to_string();
                out.error(&id, CHIEF_ERROR, &m.timed_out.replace("{secs}", &secs));
            }
            Ending::Lost => {
                out.error(&id, CHIEF_ERROR, m.lost);
                // The next prompt opens the chat again.
                chief = None;
            }
        }
        let _ = cancel.running.compare_exchange(generation, 0, Ordering::SeqCst, Ordering::SeqCst);
    }
}

/// The reply as `session/update` `agent_message_chunk` notifications: the
/// live draft's new text, then what the posted message adds to it.
struct Updates {
    out: Out,
    session: String,
    /// Draft text already sent for the current reply.
    streamed: String,
    wrote: bool,
}

impl Updates {
    fn new(out: Out, session: String) -> Self {
        Self { out, session, streamed: String::new(), wrote: false }
    }

    fn chunk(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        self.out.send(&json!({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": self.session,
            "update": {"sessionUpdate": "agent_message_chunk",
                       "content": {"type": "text", "text": text}},
        }}));
        self.wrote = true;
    }
}

impl ReplySink for Updates {
    fn draft(&mut self, talk: &str) {
        if let Some(rest) = talk.strip_prefix(self.streamed.as_str())
            && !rest.is_empty()
        {
            let rest = rest.to_owned();
            self.chunk(&rest);
            self.streamed = talk.to_owned();
        }
    }

    fn message(&mut self, message: &Value) {
        let text = message_text(message);
        let rest = match text.strip_prefix(self.streamed.as_str()) {
            Some(rest) if !self.streamed.is_empty() => rest.to_owned(),
            // A second reply, or one that is not its draft, is a new paragraph.
            _ if self.wrote => format!("\n\n{text}"),
            _ => text,
        };
        self.chunk(&rest);
        self.streamed.clear();
    }

    fn not_read(&mut self) {}

    fn end(&mut self) {
        self.streamed.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_acpmux_agents_prompt_names_its_sender_and_a_persons_none() {
        let params = json!({"sessionId": "s", "prompt": [],
            "_meta": {"acpmux": {"sender": {"name": "lane-a", "class": "question", "threadId": "t1"}}}});
        let sender = prompt_sender(&params).expect("sender");
        assert_eq!(sender, AgentSender::new("lane-a", Some("question"), Some("t1")).unwrap());
        assert_eq!(prompt_sender(&json!({"sessionId": "s", "prompt": []})), None);
    }

    #[test]
    fn a_prompt_is_its_text_resources_and_links() {
        let prompt = json!([
            {"type": "text", "text": "look at"},
            {"type": "resource_link", "uri": "file:///a.md", "name": "a.md"},
            {"type": "resource", "resource": {"uri": "file:///b", "text": "body"}},
            {"type": "image", "data": "AAAA", "mimeType": "image/png"},
            {"type": "text", "text": "  "},
        ]);
        assert_eq!(prompt_text(Some(&prompt)), "look at\n\n[a.md](file:///a.md)\n\nbody");
        assert_eq!(prompt_text(None), "");
    }

    #[test]
    fn options_take_a_home_a_timeout_and_wait_agents() {
        let words = |w: &[&str]| w.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let parsed =
            parse(&words(&["--chief-home=/h", "--timeout", "0", "--wait-agents"])).unwrap();
        assert_eq!(parsed.chief_home.as_deref(), Some(std::path::Path::new("/h")));
        assert_eq!(parsed.timeout_secs, None);
        assert!(parsed.wait_agents);
        assert_eq!(parse(&[]).unwrap().timeout_secs, Some(DEFAULT_TIMEOUT_SECS));
        assert!(parse(&words(&["--bogus"])).is_err());
    }
}
