//! Pipe mode: send one message, print the Chief's reply, exit at the turn's
//! end. On a terminal the reply streams from the live drafts; into a pipe
//! only the posted messages are written, so scripts read the final text.

use std::io::{IsTerminal, Write};
use std::sync::mpsc::RecvTimeoutError;
use std::time::{Duration, Instant};

use serde_json::Value;

use super::adapter::{Drafts, UiEvent, adapt};
use super::link::LinkError;
use super::messages::messages;
use super::render::message_text;
use super::turn::TurnWatch;
use super::{Args, Input, Session, json_output};
use crate::cli::OutputMode;

/// How long before pipe mode says the Chief has not read the message.
const NOT_READ_AFTER: Duration = Duration::from_secs(30);
/// How long pipe mode waits for a reply after the turn's typing went off
/// with none posted (a turn may end without a reply).
const REPLY_GRACE: Duration = Duration::from_secs(60);
/// Messages in the snapshot of a stream reopened after a gap.
const GAP_TAIL: usize = 50;

pub(super) fn run(mut session: Session, text: &str, args: &Args, output: OutputMode) -> i32 {
    let m = messages();
    let text = text.trim_end_matches(['\n', '\r']);
    if text.trim().is_empty() {
        eprintln!("cmux: {}", m.empty_message);
        return 2;
    }
    session.sender = args.sender(super::acpmux_session().as_deref());
    let (seq, id) = match session.send(text) {
        Ok(sent) => sent,
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
    let links = !json && super::hyperlink::enabled();
    let mut out = Printer { streamed: String::new(), wrote: false, json, links };
    let watch = Follow {
        seq,
        id: &id,
        wait_agents: !args.no_wait_agents,
        stream,
        timeout_secs: args.timeout_secs,
    };
    match follow(&mut session, &watch, &mut out, &|| false) {
        Ending::Done => 0,
        Ending::TimedOut => {
            let secs = args.timeout_secs.unwrap_or_default().to_string();
            eprintln!("cmux: {}", m.timed_out.replace("{secs}", &secs));
            124
        }
        Ending::Lost => {
            eprintln!("cmux: {}", m.lost);
            3
        }
        // Pipe mode has no cancel; it ends on a signal.
        Ending::Cancelled => 130,
    }
}

/// Where the Chief's reply goes as it comes: pipe mode's stdout, or the ACP
/// adapter's `session/update` notifications.
pub(super) trait ReplySink {
    /// The live draft of the reply so far (its whole talk text).
    fn draft(&mut self, talk: &str);
    /// A posted reply message.
    fn message(&mut self, message: &Value);
    /// The Chief has not read the message after a while.
    fn not_read(&mut self);
    /// The wait ended (any way).
    fn end(&mut self);
}

/// How [`follow`] watches for the reply to one sent message.
pub(super) struct Follow<'a> {
    /// The sent message's seq and id.
    pub seq: u64,
    pub id: &'a str,
    /// Wait for the subagents the message started (E22).
    pub wait_agents: bool,
    /// Stream the live drafts, not only the posted messages.
    pub stream: bool,
    pub timeout_secs: Option<u64>,
}

/// How a [`follow`] ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Ending {
    /// The turn that answers the message ended.
    Done,
    TimedOut,
    /// The event stream ended before the turn did.
    Lost,
    /// `cancelled()` said so, on an [`CANCEL`] wake.
    Cancelled,
}

/// The `Input::Closed` reason that wakes [`follow`] to check `cancelled`.
pub(super) const CANCEL: &str = "cancel";

/// Follows the Chief's turn that answers message `watch.seq` into `out`, until
/// the turn ends, the deadline passes, the stream is lost, or `cancelled()`
/// answers true after an `Input::Closed(CANCEL)` wake.
pub(super) fn follow(
    session: &mut Session,
    watch: &Follow<'_>,
    out: &mut dyn ReplySink,
    cancelled: &dyn Fn() -> bool,
) -> Ending {
    let mut turn =
        TurnWatch::new(watch.seq).of_chief(&session.chief).answering(watch.id, watch.wait_agents);
    let mut drafts = Drafts::default();
    let started = Instant::now();
    let deadline = watch.timeout_secs.map(|s| started + Duration::from_secs(s));
    let mut hinted = false;
    let mut printed = 0;
    let mut ended_at: Option<Instant> = None;
    while !turn.done {
        let now = Instant::now();
        let mut wait =
            deadline.map_or(Duration::from_secs(3600), |d| d.saturating_duration_since(now));
        if !hinted && !turn.read {
            wait = wait.min((started + NOT_READ_AFTER).saturating_duration_since(now));
        }
        if !turn.ended {
            // A reply to other messages undoes a typing-off (E22).
            ended_at = None;
        } else {
            let since = *ended_at.get_or_insert(now);
            if now >= since + REPLY_GRACE {
                break;
            }
            wait = wait.min((since + REPLY_GRACE).saturating_duration_since(now));
        }
        let input = match session.rx.recv_timeout(wait) {
            Ok(input) => input,
            Err(RecvTimeoutError::Timeout) => {
                if deadline.is_some_and(|d| Instant::now() >= d) {
                    out.end();
                    return Ending::TimedOut;
                }
                if !hinted && !turn.read && Instant::now() >= started + NOT_READ_AFTER {
                    hinted = true;
                    out.not_read();
                }
                continue;
            }
            Err(RecvTimeoutError::Disconnected) => break,
        };
        let line = match input {
            Input::Daemon(line) => line,
            Input::Closed(reason) if reason == CANCEL => {
                if cancelled() {
                    out.end();
                    return Ending::Cancelled;
                }
                // A cancel of an earlier wait, read late.
                continue;
            }
            // The reopened stream's snapshot carries the missed state
            // (cursor, replies, typing), so a lost item never stalls it.
            Input::Closed(reason) if reason == "gap" && session.reopen(GAP_TAIL).is_ok() => {
                continue;
            }
            Input::Closed(_) => break,
            Input::Term(_) => continue,
        };
        let Some(event) = adapt(&line, &session.conversation) else { continue };
        turn.on(&event);
        // A snapshot after a gap can add several replies at once.
        for reply in turn.replies.get(printed..).unwrap_or_default() {
            out.message(reply);
            drafts.on_message(reply);
        }
        printed = turn.replies.len();
        if let UiEvent::Draft(draft) = &event
            && watch.stream
            && turn.working
            && draft.participant == session.chief
        {
            drafts.apply(draft);
            if let Some(t) = drafts.turns.iter().find(|t| t.turn == draft.turn) {
                out.draft(&t.talk());
            }
        }
    }
    out.end();
    if turn.done || turn.ended { Ending::Done } else { Ending::Lost }
}

/// Writes the reply: live draft text first, then what the posted message
/// adds to it.
struct Printer {
    /// Draft text already written for the current reply.
    streamed: String,
    wrote: bool,
    json: bool,
    /// Subagent links become terminal hyperlinks (`hyperlink`).
    links: bool,
}

impl ReplySink for Printer {
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
        let rest = if self.links { super::hyperlink::render(&rest) } else { rest };
        self.write(&rest);
        self.write("\n");
        self.streamed.clear();
    }

    fn not_read(&mut self) {
        eprintln!("cmux: {}", messages().not_read);
    }

    fn end(&mut self) {
        if !self.streamed.is_empty() {
            self.write("\n");
            self.streamed.clear();
        }
    }
}

impl Printer {
    fn write(&mut self, text: &str) {
        let mut stdout = std::io::stdout().lock();
        let _ = stdout.write_all(text.as_bytes());
        let _ = stdout.flush();
        self.wrote = self.wrote || !text.is_empty();
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
