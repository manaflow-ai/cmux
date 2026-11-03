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
    /// `--chief ID` (else `CMUX_CHIEF_PARTICIPANT`, a stable Chief session's
    /// env): that Chief's conversation, not the default Chief's.
    chief: Option<String>,
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
            "--chief" => options.chief = Some(value()?),
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
    /// The Chief whose turn sent it (`_meta.acpmux.sender.chief`), when one did.
    sender_chief: Option<String>,
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
        Ok(mut options) => {
            if options.chief.is_none() {
                options.chief = std::env::var(CHIEF_ENV).ok().filter(|c| !c.trim().is_empty());
            }
            options
        }
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
                let sender_chief = sender_chief(&params);
                Job {
                    id,
                    session: session().unwrap_or_default(),
                    text,
                    generation,
                    sender,
                    sender_chief,
                }
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
    let name = field("name")?;
    // Another Chief's turn: shown as that Chief (`[from chief:codex-chief]`),
    // the way local Chiefs name each other.
    let name = match sender_chief(params) {
        Some(_) => format!("chief:{}", handle(name)),
        None => name.to_owned(),
    };
    AgentSender::new(&name, field("class"), field("threadId"))
}

/// The chat this adapter serves: the default Chief's, or with `--chief` that
/// Chief's own conversation.
fn open_chief(global: &GlobalArgs, options: &Options) -> Result<Session, (i32, String)> {
    let home = options.chief_home.as_deref();
    let Some(chief) = options.chief.as_deref() else {
        return Session::open(global, 0, home, &ChatTarget::default());
    };
    let mut session = Session::connect(global, home, &ChatTarget::default())?;
    let conversation = chief_conversation(&mut session, chief)?;
    session.open_chat(Some(&conversation), 0)?;
    Ok(session)
}

/// The id of Chief `chief`'s own conversation on `session`'s daemon.
fn chief_conversation(session: &mut Session, chief: &str) -> Result<String, (i32, String)> {
    let chats = session.client.chats().map_err(|e| session.failed(e))?;
    super::link::select_chief_of(&chats, chief)
        .and_then(|c| c.get("id").and_then(Value::as_str))
        .map(str::to_owned)
        .ok_or_else(|| (1, format!("Chief {chief} has no conversation on this Mac yet")))
}

/// Posts `reply` into Chief `to`'s conversation as `back` (no wait: a
/// result takes no answer).
fn send_back(
    global: &GlobalArgs,
    options: &Options,
    to: &str,
    back: AgentSender,
    reply: &str,
) -> Result<(), String> {
    let text = if reply.trim().is_empty() { "(no reply)" } else { reply };
    let mut session =
        Session::connect(global, options.chief_home.as_deref(), &ChatTarget::default())
            .map_err(|(_, why)| why)?;
    let conversation = chief_conversation(&mut session, to).map_err(|(_, why)| why)?;
    session.select(Some(&conversation)).map_err(|(_, why)| why)?;
    session.sender = Some(back);
    session.send(text).map(|_| ()).map_err(|e| e.to_string())
}

/// The env a stable Chief session names its Chief by (optchat-chief
/// brain/chief_inbox.rs, acpmux session_env.rs).
const CHIEF_ENV: &str = "CMUX_CHIEF_PARTICIPANT";

/// The Chief whose turn sent the prompt (acpmux `prompt_provenance::stamp_chief`).
fn sender_chief(params: &Value) -> Option<String> {
    let chief = params.pointer("/_meta/acpmux/sender/chief")?.as_str()?.trim();
    chief.starts_with("agent_").then(|| chief.to_owned())
}

/// A name as one lowercase word: each run of other characters becomes `-`.
fn handle(name: &str) -> String {
    let mut out = String::new();
    for c in name.trim().chars().flat_map(char::to_lowercase) {
        if c.is_ascii_alphanumeric() || c == '.' || c == '_' {
            out.push(c);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    let out = out.trim_matches('-');
    if out.is_empty() { "chief".to_owned() } else { out.to_owned() }
}

/// Where this Chief's reply to another Chief's message goes: that Chief's
/// conversation (`to`), as this Chief (`chief:<own name>`, class `result`, the
/// same thread). None for a lane's message (acpmux shows it the reply), a
/// result or fyi (a reply is never answered again, so two Chiefs cannot
/// ping-pong) and a message this Chief sent itself.
fn reply_route(
    sender: &AgentSender,
    sender_chief: Option<&str>,
    own_chief: &str,
    own_name: &str,
) -> Option<(String, AgentSender)> {
    let to = sender_chief?;
    if to == own_chief || matches!(sender.class.as_str(), "result" | "fyi") {
        return None;
    }
    let back = AgentSender::new(
        &format!("chief:{}", handle(own_name)),
        Some("result"),
        sender.thread.as_deref(),
    )?;
    Some((to.to_owned(), back))
}

/// A Chief's display name in a conversation's summary, else "Chief".
fn chief_name(summary: &Value, chief: &str) -> String {
    summary
        .get("participants")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .find(|p| p.get("id").and_then(Value::as_str) == Some(chief))
        .and_then(|p| p.get("display_name").and_then(Value::as_str))
        .map(str::trim)
        .filter(|n| !n.is_empty())
        .unwrap_or("Chief")
        .to_owned()
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
    for Job { id, session: session_id, text, generation, sender, sender_chief } in inbox {
        if chief.is_none() {
            if cmux_tui_core::agent_launch::disabled() {
                out.error(&id, CHIEF_ERROR, m.agents_disabled);
                continue;
            }
            match open_chief(global, options) {
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
        let route = sender.as_ref().and_then(|s| {
            let own = session.chief.clone();
            reply_route(s, sender_chief.as_deref(), &own, &chief_name(&session.summary, &own))
        });
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
            Ending::Done => {
                // Another Chief's question: its reply goes back into that
                // Chief's own chat, as this Chief's message.
                if let Some((to, back)) = route {
                    let reply = sink.replies.join("\n\n");
                    if let Err(why) = send_back(global, options, &to, back, &reply) {
                        eprintln!("cmux chief acp: the reply did not reach {to}: {why}");
                    }
                }
                out.result(&id, json!({"stopReason": "end_turn"}));
            }
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
    /// The text of each reply message posted, oldest first.
    replies: Vec<String>,
    /// Draft text already sent for the current reply.
    streamed: String,
    wrote: bool,
}

impl Updates {
    fn new(out: Out, session: String) -> Self {
        Self { out, session, replies: Vec::new(), streamed: String::new(), wrote: false }
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
        if !text.trim().is_empty() {
            self.replies.push(text.clone());
        }
        let rest = match text.strip_prefix(self.streamed.as_str()) {
            Some(rest) if !self.streamed.is_empty() => rest.to_owned(),
            // A second reply, or one that is not its draft, is a new paragraph.
            _ if self.wrote => format!("\n\n{text}"),
            _ => text,
        };
        self.chunk(&rest);
        self.streamed.clear();
    }

    fn not_read(&mut self, _busy: bool) {}

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
    fn another_chiefs_prompt_is_labelled_chief_and_its_reply_goes_back_to_it() {
        // Chief-to-Chief on this Mac: Codex Chief's turn `acpmux_send`s to
        // this Chief's stable session; acpmux names the sending Chief.
        let params = json!({"sessionId": "s", "prompt": [],
            "_meta": {"acpmux": {"sender": {"name": "Codex Chief", "class": "question",
                                            "threadId": "t2", "chief": "agent_codex"}}}});
        let sender = prompt_sender(&params).expect("sender");
        assert_eq!(sender.name, "chief:codex-chief");
        assert_eq!(sender_chief(&params).as_deref(), Some("agent_codex"));
        let (to, back) = reply_route(&sender, Some("agent_codex"), "agent_mux", "Chief")
            .expect("a question from a Chief gets its reply back");
        assert_eq!(to, "agent_codex");
        assert_eq!(back, AgentSender::new("chief:chief", Some("result"), Some("t2")).unwrap());
        // A reply is never answered again (no ping-pong), a Chief never
        // routes to itself, and a lane's message has no Chief to go back to.
        let result = AgentSender::new("chief:codex-chief", Some("result"), None).unwrap();
        assert_eq!(reply_route(&result, Some("agent_codex"), "agent_mux", "Chief"), None);
        let fyi = AgentSender::new("chief:codex-chief", Some("fyi"), None).unwrap();
        assert_eq!(reply_route(&fyi, Some("agent_codex"), "agent_mux", "Chief"), None);
        assert_eq!(reply_route(&sender, Some("agent_mux"), "agent_mux", "Chief"), None);
        let lane = AgentSender::new("lane-a", Some("question"), None).unwrap();
        assert_eq!(reply_route(&lane, None, "agent_mux", "Chief"), None);
        // A lane's name is kept as acpmux gave it.
        let lane_params = json!({"sessionId": "s", "prompt": [],
            "_meta": {"acpmux": {"sender": {"name": "lane-a"}}}});
        assert_eq!(prompt_sender(&lane_params).unwrap().name, "lane-a");
        assert_eq!(sender_chief(&lane_params), None);
    }

    #[test]
    fn a_stable_chief_session_opens_that_chiefs_conversation() {
        let words = |w: &[&str]| w.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            parse(&words(&["--chief", "agent_codex"])).unwrap().chief.as_deref(),
            Some("agent_codex")
        );
        let conv = |id: &str, at: &str, who: &str| json!({"id": id, "created_at": at, "participants": [{"id": "user_local"}, {"id": who}]});
        let chats = vec![
            conv("c-mux", "2026-01-01", "agent_mux"),
            conv("c-codex-new", "2026-03-01", "agent_codex"),
            conv("c-codex", "2026-02-01", "agent_codex"),
        ];
        assert_eq!(
            super::super::link::select_chief_of(&chats, "agent_codex").unwrap()["id"],
            "c-codex"
        );
        assert_eq!(
            super::super::link::select_chief_of(&chats, "agent_mux").unwrap()["id"],
            "c-mux"
        );
        assert!(super::super::link::select_chief_of(&chats, "agent_other").is_none());
        // Another Chief answers in its DM with the person, never in a group
        // it is in (optchat-chief `daemon::select_chief_of`).
        let group = json!({"id": "c-group", "created_at": "2025-01-01", "participants": [
            {"id": "user_local"}, {"id": "agent_codex"}, {"id": "agent_mux"}]});
        let with_group = [vec![group], chats].concat();
        assert_eq!(
            super::super::link::select_chief_of(&with_group, "agent_codex").unwrap()["id"],
            "c-codex"
        );
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
