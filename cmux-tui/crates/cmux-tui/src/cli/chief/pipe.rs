//! Pipe mode: send one message, print the Chief's reply, exit at the turn's
//! end. On a terminal the reply streams from the live drafts; into a pipe
//! only the posted messages are written, so scripts read the final text.

use std::io::{IsTerminal, Write};
use std::sync::mpsc::RecvTimeoutError;
use std::time::{Duration, Instant};

use serde_json::Value;

use super::adapter::{AGENT_MUX, Drafts, UiEvent, adapt};
use super::link::LinkError;
use super::messages::messages;
use super::render::message_text;
use super::turn::TurnWatch;
use super::{Args, Input, Session, json_output};
use crate::cli::OutputMode;

/// How long before pipe mode says the Chief has not read the message.
const NOT_READ_AFTER: Duration = Duration::from_secs(30);

pub(super) fn run(mut session: Session, text: &str, args: &Args, output: OutputMode) -> i32 {
    let m = messages();
    let text = text.trim_end_matches(['\n', '\r']);
    if text.trim().is_empty() {
        eprintln!("cmux: {}", m.empty_message);
        return 2;
    }
    let seq = match session.send(text) {
        Ok(seq) => seq,
        Err(LinkError::Transport(message)) => {
            eprintln!("cmux: {message}");
            return 3;
        }
        Err(error) => {
            eprintln!("cmux: {}", m.rejected.replace("{reason}", &error.to_string()));
            return 1;
        }
    };
    let json = json_output(output);
    let stream = !json && std::io::stdout().is_terminal();
    let mut out = Printer { streamed: String::new(), wrote: false, json };
    let mut watch = TurnWatch::new(seq);
    let mut drafts = Drafts::default();
    let started = Instant::now();
    let deadline = args.timeout_secs.map(|s| started + Duration::from_secs(s));
    let mut hinted = false;
    while !watch.done {
        let now = Instant::now();
        let mut wait =
            deadline.map_or(Duration::from_secs(3600), |d| d.saturating_duration_since(now));
        if !hinted && !watch.read {
            wait = wait.min((started + NOT_READ_AFTER).saturating_duration_since(now));
        }
        let input = match session.rx.recv_timeout(wait) {
            Ok(input) => input,
            Err(RecvTimeoutError::Timeout) => {
                if deadline.is_some_and(|d| Instant::now() >= d) {
                    out.end();
                    eprintln!("cmux: {}", m.timed_out);
                    return 124;
                }
                if !hinted && !watch.read && Instant::now() >= started + NOT_READ_AFTER {
                    hinted = true;
                    eprintln!("cmux: {}", m.not_read);
                }
                continue;
            }
            Err(RecvTimeoutError::Disconnected) => break,
        };
        let line = match input {
            Input::Daemon(line) => line,
            Input::Closed(reason) if reason == "gap" && session.reopen(0).is_ok() => continue,
            Input::Closed(_) => break,
            Input::Term(_) => continue,
        };
        let Some(event) = adapt(&line, &session.conversation) else { continue };
        if let Some(reply) = watch.on(&event) {
            out.message(&reply);
            drafts.on_message(&reply);
        }
        if let UiEvent::Draft(draft) = &event
            && stream
            && watch.working
            && draft.participant == AGENT_MUX
        {
            drafts.apply(draft);
            if let Some(turn) = drafts.turns.iter().find(|t| t.turn == draft.turn) {
                out.draft(&turn.talk());
            }
        }
    }
    out.end();
    if watch.done {
        0
    } else {
        eprintln!("cmux: {}", m.lost);
        3
    }
}

/// Writes the reply: live draft text first, then what the posted message
/// adds to it.
struct Printer {
    /// Draft text already written for the current reply.
    streamed: String,
    wrote: bool,
    json: bool,
}

impl Printer {
    fn draft(&mut self, talk: &str) {
        if let Some(rest) = talk.strip_prefix(self.streamed.as_str())
            && !rest.is_empty()
        {
            self.write(rest);
            self.streamed = talk.to_owned();
        }
    }

    fn message(&mut self, message: &Value) {
        if self.json {
            println!("{message}");
            return;
        }
        let text = message_text(message);
        let rest = finish_text(&self.streamed, &text, self.wrote);
        self.write(&rest);
        self.write("\n");
        self.streamed.clear();
    }

    fn write(&mut self, text: &str) {
        let mut stdout = std::io::stdout().lock();
        let _ = stdout.write_all(text.as_bytes());
        let _ = stdout.flush();
        self.wrote = self.wrote || !text.is_empty();
    }

    fn end(&mut self) {
        if !self.streamed.is_empty() {
            self.write("\n");
            self.streamed.clear();
        }
    }
}

/// What to write for a posted reply `text` after `streamed` draft text: the
/// rest when the draft was its start, else the whole text on a new line.
/// A second reply is set off by a blank line.
pub(super) fn finish_text(streamed: &str, text: &str, wrote: bool) -> String {
    if !streamed.is_empty() {
        return match text.strip_prefix(streamed) {
            Some(rest) => rest.to_owned(),
            None => format!("\n{text}"),
        };
    }
    if wrote { format!("\n{text}") } else { text.to_owned() }
}
