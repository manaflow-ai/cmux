//! An ask: open (or go on with) the draft, hand an agent the brief in a
//! chat, and say where to watch.
//!
//! The chat is `cmux chat` itself, run as this binary with `--json`, so an
//! ask places, names and waits for a chat exactly as `cmux chat` does and
//! shows up in the app as an ordinary chat tab the person can talk to. The
//! draft remembers the chat, so the next ask refines in the same one.

use cmux_customize::Customize;
use serde_json::Value;

use super::render::Answer;
use super::{AskOptions, Failure};

/// What a finished `cmux chat …` child said.
pub(in crate::cli) struct ChatResult {
    pub ok: bool,
    pub stdout: String,
    pub stderr: String,
}

/// Runs `cmux WORDS…`. A trait so the flow is tested without an app.
pub(in crate::cli) trait Chat {
    fn run(&self, words: &[String]) -> Result<ChatResult, String>;
}

/// The real thing: this binary, with the caller's global options.
pub(in crate::cli) struct Child {
    pub globals: Vec<String>,
}

impl Chat for Child {
    fn run(&self, words: &[String]) -> Result<ChatResult, String> {
        let program =
            std::env::current_exe().map_err(|error| format!("cannot find cmux: {error}"))?;
        let mut command = cmux_process::Command::new(program);
        command.args(&self.globals).args(words).stdin(cmux_process::Stdio::null());
        let output =
            command.output().map_err(|error| format!("cannot start cmux chat: {error}"))?;
        Ok(ChatResult {
            ok: output.status.success(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
    }
}

/// Where no chat may start (an MCP tool: the calling agent does the work).
pub(in crate::cli) struct NoChat;

impl Chat for NoChat {
    fn run(&self, _words: &[String]) -> Result<ChatResult, String> {
        Err("no chat can start here".to_owned())
    }
}

/// Where the chat runs: this machine, whatever `CMUX_ON` or the saved
/// `chat.on` say. The brief names this machine's files, so an agent on a
/// Cloud VM would edit a setup nobody is looking at.
const HERE: [&str; 2] = ["--on", "here"];

/// `cmux chat` words for a first ask.
pub(super) fn new_chat_words(wish: &str, brief: &str, options: &AskOptions) -> Vec<String> {
    let mut words =
        vec!["--json".to_owned(), "chat".to_owned(), "--name".to_owned(), chat_name(wish)];
    words.extend(HERE.map(str::to_owned));
    for (flag, value) in [("--harness", &options.harness), ("--model", &options.model)] {
        if let Some(value) = value {
            words.extend([flag.to_owned(), value.clone()]);
        }
    }
    wait_words(&mut words, options);
    words.extend(["--prompt".to_owned(), brief.to_owned()]);
    words
}

/// `cmux chat send` words for a refinement in the draft's chat.
pub(super) fn send_words(session: &str, brief: &str, options: &AskOptions) -> Vec<String> {
    let mut words =
        vec!["--json".to_owned(), "chat".to_owned(), "send".to_owned(), session.to_owned()];
    words.extend(HERE.map(str::to_owned));
    wait_words(&mut words, options);
    // The brief starts with a word, never a dash, so it is the TEXT.
    words.push(brief.to_owned());
    words
}

fn wait_words(words: &mut Vec<String>, options: &AskOptions) {
    if options.wait {
        words.push("--wait".to_owned());
        if let Some(timeout) = &options.timeout {
            words.extend(["--timeout".to_owned(), timeout.clone()]);
        }
    }
}

/// The chat tab's name: what was asked, short.
pub(super) fn chat_name(wish: &str) -> String {
    let line = wish.split_whitespace().collect::<Vec<_>>().join(" ");
    let short: String = line.chars().take(48).collect();
    if short.len() < line.len() {
        format!("Customize: {short}…")
    } else {
        format!("Customize: {short}")
    }
}

/// The first value under `key` anywhere in a JSON answer (`cmux chat`
/// answers flat here and nested for a Cloud chat).
fn find<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    match value {
        Value::Object(object) => object
            .get(key)
            .and_then(Value::as_str)
            .or_else(|| object.values().find_map(|inner| find(inner, key))),
        Value::Array(items) => items.iter().find_map(|inner| find(inner, key)),
        _ => None,
    }
}

/// The chat an answer names. A waited turn answers `session_id`; with no
/// `--wait`, `cmux chat` prints the receipt of the chat it made or sent to,
/// which names it as `result.chat`.
fn chat_of(answer: &Value) -> Option<&str> {
    find(answer, "session_id")
        .or_else(|| answer.pointer("/result/chat").and_then(Value::as_str))
        .or_else(|| answer.get("chat").and_then(Value::as_str))
}

/// The last JSON object a child printed (`--json` answers are one line).
fn last_json(text: &str) -> Option<Value> {
    text.lines()
        .rev()
        .find_map(|line| serde_json::from_str::<Value>(line.trim()).ok().filter(Value::is_object))
}

pub(super) fn ask(
    customize: &Customize,
    wish: &str,
    options: &AskOptions,
    origin: &str,
    now_ms: u64,
    chat: &dyn Chat,
) -> Result<Answer, Failure> {
    let begun = customize.begin(wish, origin, now_ms)?;
    let brief = cmux_customize::brief(wish, customize.roots(), &customize.status()?);
    let session = begun.draft.session.clone().filter(|_| !options.new_chat);
    let mut result = None;
    if let Some(session) = &session {
        let sent = chat.run(&send_words(session, &brief, options)).map_err(chat_failed)?;
        // Only a chat that is gone (closed, another machine) hands the ask
        // to a new one: `chat send` looks the session up before it sends
        // anything, so nothing was delivered. Any other failure may have
        // come after delivery (a turn that ran out of `--timeout`, a failed
        // turn), and a second chat would do the same edits twice.
        if sent.ok || code(&sent).as_deref() != Some(GONE) {
            result = Some((sent, Some(session.clone())));
        }
    }
    let (result, sent_to) = match result {
        Some(result) => result,
        None => (chat.run(&new_chat_words(wish, &brief, options)).map_err(chat_failed)?, None),
    };
    let answer = last_json(&result.stdout);
    if !result.ok {
        let error = last_json(&result.stderr);
        let said = error
            .as_ref()
            .and_then(|error| find(error, "message"))
            .map(str::to_owned)
            .unwrap_or_else(|| result.stderr.trim().to_owned());
        // The chat that has the ask: the one sent to, or the new one a
        // timed-out wait names.
        let has_it = sent_to.or_else(|| error.as_ref().and_then(chat_of).map(str::to_owned));
        let timed_out = code(&result).as_deref() == Some(TIMED_OUT);
        return Err(match has_it {
            Some(session) => {
                customize.set_session(&session)?;
                delivered(&session, &said, timed_out)
            }
            None => chat_failed(said),
        });
    }
    let session = answer.as_ref().and_then(chat_of).map(str::to_owned).or(session);
    if let Some(session) = &session {
        customize.set_session(session)?;
    }
    if options.wait {
        // The agent's turn is over: what changes from here was done by hand.
        customize.end_turn()?;
    }
    Ok(Answer::Asked {
        reply: answer.as_ref().and_then(|answer| find(answer, "reply")).map(str::to_owned),
        session,
        waited: options.wait,
        begun,
        status: customize.status()?,
    })
}

/// `cmux chat send`'s code for a session no chat has.
const GONE: &str = "selector.not_found";
/// `cmux chat --wait`'s code for a turn that outlived `--timeout`.
const TIMED_OUT: &str = "chat.wait_timeout";

/// The error code a failed `cmux chat` printed.
fn code(result: &ChatResult) -> Option<String> {
    last_json(&result.stderr).as_ref().and_then(|error| find(error, "code")).map(str::to_owned)
}

/// Chat `session` was sent the ask and did not see it through. It is not
/// sent again: the agent may be working on it, or may have made part of it.
fn delivered(session: &str, why: &str, timed_out: bool) -> Failure {
    let (code, exit, what) = if timed_out {
        ("customize.chat_unfinished", 3, "has the ask, and the agent is still working on it")
    } else {
        ("customize.chat_failed", 1, "was sent the ask and did not finish it")
    };
    Failure {
        code: code.to_owned(),
        message: format!(
            "chat {session} {what}: {why}\nit was not sent again. `cmux chat wait {session}` waits for the turn, `cmux customize` shows what changed so far, and `cmux customize --new 'WISH'` asks in a fresh chat"
        ),
        details: serde_json::json!({ "session_id": session, "delivered": timed_out }),
        exit,
    }
}

/// The draft stays open when the chat does not start: any agent can take it
/// up from the brief, and the person can still edit by hand.
fn chat_failed(why: String) -> Failure {
    Failure {
        code: "customize.chat_failed".to_owned(),
        message: format!(
            "the agent chat did not start: {why}\nthe draft is open: `cmux customize brief 'WISH'` prints the brief for any agent, and your own edits preview the same way"
        ),
        details: serde_json::json!({}),
        exit: 1,
    }
}
