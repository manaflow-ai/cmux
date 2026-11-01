//! Part of `Hub`; see `hub/mod.rs`. Every chat's inbox: another agent's message never becomes a
//! turn or a steer of its own. Leo, 2026-10-29: "im the only one that steers... shouldn't some
//! of these messages like... you can turn on steer or queue or whatever?", "i feel like messages
//! should kinda act as pseudo threads within threads/side chats?" (a coordinator had 319 agent
//! messages queued as turns behind a turn the person's steers kept going).
//!
//! Another agent's message (`digest.rs` `agent_sender`) that is text only ([`takes`]) goes into
//! the chat's inbox, apart from its queue: an `inbox` record in its log, in a thread
//! ([`thread_key`]): the `_meta.acpmux.topic` or `pr` its sender gave, else its sender and the
//! pull request its first line names, else its sender. An image, an upload, a slash command, a
//! sub-session family message and a Web one are no inbox items: each still runs as before. So
//! far only a plain send from this host is ([`plain_send`]): a peer's or the mesh relay's forward,
//! a team message, a correction under a supersede key, a steer-only send, a `cmux agent message`
//! (the cmux daemon delivers and tracks it) and the prompts acpmux makes itself (lane reports,
//! task cards, a paused pair's release) still queue.
//!
//! Those still steer into a running turn, but never while one of the person's prompts waits
//! behind it ([`persons_prompt_waits`]; `turns.rs`, checked again as the steer is written,
//! `steer_end.rs`), as no notice does. Then the message queues behind that prompt, one sent with
//! `interrupt` stops nothing, and a steer-only one is refused (`promptWaits`). Another agent's
//! steer kept a turn going past the person's queued prompt; Leo, 2026-10-29: "but even if im
//! just queueing, your turn should still be ending". The person's own steer, the queue's Send
//! now, and an inbox digest its drain asked to steer (`inbox_digest.rs`) still go in.
//!
//! Nor does any of them, or a notice, go into a turn the person's own prompt started
//! ([`persons_prompt`], `TurnInfo::persons`, set while the inbox is on: with `agentInbox` off,
//! agents' sends steer in as they did before it, `tests/send_steer.rs`): it waits for that
//! turn's end and goes in as a turn of its own after it, the same way (`steerOnly` refused with
//! `personsTurn`). A sub-session family message still goes in: the chat's own sub-session
//! reporting to the turn that started it. A notice
//! steered into the person's turn as it started, so it went in with the person's words, and
//! other agents' steers went in at its next step; Leo, 2026-11-01: "why do the x messages from
//! y sessions seem to always piggyback on my messages instead of going on their own".
//!
//! A chat's first work is no inbox item either ([`first_work`]): the first message another agent
//! sends a chat that never ran a turn, with none running and nothing waiting (`lane-place
//! --prompt-file`, `acpmux new` with a prompt), runs as that prompt, and its sender is the chat's
//! delegator once its turn starts. The prompt holds the first work while it runs
//! ([`FirstWork`]), so of two that come at once only one is it; a refused one lets go. No notice
//! goes ahead of it while it holds the chat (`inbox_review`); a person's prompt may, and its
//! sender is the delegator still: its provenance says it is the first work ([`FIRST_WORK`]), in
//! the queue too, so across a restart as well, where it also keeps notices behind it. Messages
//! after it, and any to a chat that ran a turn, go to the inbox. A lane's brief came to it as a
//! notice of its brief (2026-10-30), so the lane read a thread where it should have read its task.
//!
//! A review box (`review_box.rs`: the `*-review-box` harness `lane-place new --review` starts, or
//! a session with a `review.` tag) has no inbox ([`review_box`]), and another agent's message
//! never steers into its turn (`turns.rs`; `inbox_digest.rs` refuses to drain one): it queues
//! behind the review and runs as a turn of its own (none joins another, `digest.rs`) once the review
//! ends, which answers its sender; one sent with `interrupt` stops no review either. Nor does a
//! notice steer into its turn: messages its inbox
//! took before it became one (a `review.` tag set later) wait for the turn's end, as an idle
//! chat's do. The person's own steer still goes in, and so does a queued message the person
//! sends with Send now: that is the person's choice, not another agent's. A coordinator
//! found notices steered into review turns (2026-10-30): "The reviewer then reads the thread
//! instead of reviewing and ends with no SHIP/BLOCK verdict."
//!
//! A chat whose agent cannot read an inbox has none either ([`reads_inbox`]): one started with no
//! cmux tools (`agent_tools::left_out`: a remote origin, `ACPMUX_AGENT_TOOLS=0`,
//! `--strict-mcp-config`). Another agent's message queues for it as before the inbox, so its agent
//! reads every word; a notice that goes to such an agent anyway (messages the inbox took before
//! it respawned without the tools, or before a restart's first spawn) carries each one whole. Nothing here waits on Labs `meshRelay.teamMessaging`: an agent reads its inbox
//! with `inbox_read`, in a shell with `acpmux session inbox`, and, while team messaging is off,
//! with the team mailbox's `team_inbox` and `acpmux inbox` too (`inbox_team_page.rs`), which an
//! agent started before the inbox has instead of `inbox_read`.
//!
//! The agent hears of its inbox as ONE notice (provenance `inbox_notice`), one line per thread
//! with new messages (how many, from whom, and the messages whole when they are short, else the
//! newest one's first line, [`render`]), blockers first, the way
//! Claude Code tells it of background work; it reads a thread whole with the `inbox_read` tool
//! (`_acpmux/inbox_thread`), which marks it read, and answers with `inbox_reply`
//! (`_acpmux/inbox_reply`), which lands in the sender's inbox under the same thread. One notice
//! is in flight at a time ([`Inbox::in_flight`]):
//!
//! - into a running turn that steers, is under its cap (`turn_cap.rs`), has none of the
//!   person's prompts waiting behind it, and was not started by the person's own prompt: as a
//!   steer, which Claude Code reads at its next tool step; what comes meanwhile goes in the next
//!   one, so a turn takes at most one per step. A prompt that waits is never held up by notices;
//! - into the next such turn that starts, as a steer at its start;
//! - an idle chat: as ONE turn of its own, at once for messages the person's own turn held back
//!   ([`Inbox::held_by_person`]), else [`WAKE_DEBOUNCE_MS`] after the oldest message that may
//!   wake it came (a burst is one turn), or [`FLUSH_MS`] after the oldest of any, so none is
//!   stranded. A message that may wake it: a blocker (a block or a question,
//!   `prompt_class.rs`), a report of work it gave (a lane's report, a task's result), or an
//!   action (a result, the default) from the session that started it
//!   (its lineage parent) or the one that first gave it work (`SessionMeta::delegator`: the
//!   sender of the first message to a chat that never ran a turn, which wakes it too). An FYI
//!   never wakes a chat; it goes with the next notice. A chat whose cut turn's automatic
//!   continuation may still fire (`auto_resume.rs` `continuation_pending`) is not woken: the
//!   inbox is looked at again [`REFUSED_RETRY_MS`] on, and goes in behind the continuation.
//!
//! An agent's `session/prompt` waits for the notice that carries it and answers with that
//! notice's answer: a steer's (`steered`, naming the turn it went into) or its own turn's; a
//! chat that closes answers it with the closing error ([`Inbox::carrying`] holds the waiting
//! senders, so a close reaches them). A notice goes in once its prompt is written to the agent
//! (the writer confirmed it), as a steer or a turn of its own; only then are its messages noticed
//! (an `inbox_noticed` record). The next notice goes no sooner than that, and behind a steer only
//! once the agent took it at its tool step (its answer). One that does not go in (a
//! steer refused or withdrawn, a turn of its own stopped or failed before its prompt was written)
//! leaves its messages new, so none is lost; it is tried again no sooner than
//! [`REFUSED_RETRY_MS`], or when a turn starts or ends. A notice that went in logs its answer (an
//! `inbox_answered` record, an error too): a resend of one of its messages, before or after a
//! restart, and after [`trim`] let go of it ([`Inbox::trimmed`]), answers with it; a resend of
//! one withdrawn before any notice carried it answers withdrawn ([`Inbox::removed`]). A withdraw
//! of a message a notice carries that is not written yet waits for it (`inbox_settled`): unsent
//! if it did not go in, retracted if it did. A restart keeps the inbox (its records), a closed
//! chat's included, and what was new is noticed again.
//!
//! The timer: one per session ([`Inbox::timer`]), for an idle chat's next wake or flush. Stop
//! condition: it wakes once, at its deadline, and ends; it is armed only while a new message
//! waits in an idle chat. Cleanup: every arm aborts the one before, a turn's start and a delivery abort it,
//! closing the session aborts it, and it holds the hub and the session weakly.

use super::*;
use crate::prompt_class::PromptClass;
use std::sync::Weak;
use std::sync::atomic::Ordering;

/// The provenance kind of a notice.
pub const NOTICE_KIND: &str = "inbox_notice";
/// On a chat's first work's provenance (module docs): set by acpmux only, as no client's
/// provenance keeps a field it does not name (`prompt_provenance.rs`).
pub const FIRST_WORK: &str = "firstWork";
/// How long after the oldest waking message an idle chat is woken: a burst is one turn.
pub const WAKE_DEBOUNCE_MS: u64 = 2_000;
/// A notice the chat refused is tried again no sooner than this.
pub const REFUSED_RETRY_MS: u64 = 30_000;
/// How long a message that wakes no one waits in an idle chat before a notice brings it anyway.
pub const FLUSH_MS: u64 = 10 * 60 * 1000;
/// A notice line shows this much of the newest message's first line, in characters.
const PREVIEW_CHARS: usize = 120;
/// A notice holds its messages whole when their text is this many bytes or less ([`render`]).
const WHOLE_BYTES: usize = 4 * 1024;
/// Messages a chat keeps in memory; the oldest read ones go first (the log keeps them all).
const KEEP: usize = 500;
/// The client a notice goes under.
const CLIENT: &str = "acpmux";

/// One message in the inbox.
pub(super) struct Item {
    pub(super) prompt_id: String,
    /// The notice that carried it, once one went in: a resend answers with its outcome.
    pub(super) notice: Option<String>,
    /// That notice's answer, once it ended (an `inbox_answered` record): a resend's answer.
    pub(super) answered: Option<super::queue::Answer>,
    pub(super) thread: String,
    /// Its sender's name, and its session when it has one here (`sender_session`).
    pub(super) from: String,
    pub(super) from_session: Option<String>,
    pub(super) class: PromptClass,
    /// A report of work this chat gave (a lane's report, a task's result): it wakes the chat
    /// as its parent's action does.
    pub(super) report: bool,
    pub(super) at: u64,
    pub(super) text: String,
    /// Machine-readable report context; kept out of the visible words.
    pub(super) details: Option<Value>,
    /// A notice told the agent of it (or carries it now).
    pub(super) noticed: bool,
    /// The agent read it (`inbox_thread` with `markRead`).
    pub(super) read: bool,
    /// The waiting `session/prompt` that sent it, answered by its notice.
    answer: Option<Waiter>,
}

#[cfg(test)]
impl Item {
    /// Message `prompt_id` from agent `from`, that a notice carries now.
    pub(super) fn carried(prompt_id: &str, from: &str, text: &str) -> Self {
        Self {
            prompt_id: prompt_id.to_owned(),
            notice: None,
            answered: None,
            thread: format!("from:{from}"),
            from: from.to_owned(),
            from_session: None,
            class: PromptClass::Result,
            report: false,
            at: now_ms(),
            text: text.to_owned(),
            details: None,
            noticed: true,
            read: false,
            answer: None,
        }
    }
}

/// The waiting `session/prompt` of an inbox message.
type Waiter = tokio::sync::watch::Sender<Option<super::queue::Answer>>;

/// A session's inbox (`Session::inbox`).
#[derive(Default)]
pub struct Inbox {
    pub(super) items: Vec<Item>,
    /// The notice in flight: its prompt id and the messages it carries. None goes after it until
    /// it ends, or, a turn of its own, until its prompt is written to the agent.
    pub(super) in_flight: Option<(String, Vec<String>)>,
    /// The idle chat's wake timer.
    pub(super) timer: Option<tokio::task::AbortHandle>,
    /// Unix ms the chat last refused a notice; 0 since one went in or a turn started or ended.
    pub(super) refused_at: u64,
    /// The notices whose prompt was written to the agent and whose task has not finished: they
    /// went in, whatever their turn's end.
    pub(super) written: Vec<String>,
    /// Every notice whose task has not finished: what it carries and the waiting senders it
    /// answers. Here, not in its task, so a close answers them (`inbox_closed`).
    pub(super) carrying: Vec<Carry>,
    /// The messages withdrawn before any notice carried them: a resend of one answers withdrawn,
    /// never puts it back. Ids only, as the prompt ledger keeps them.
    pub(super) removed: std::collections::HashSet<String>,
    /// The messages [`trim`] let go of (read, noticed and answered): a resend of one answers from
    /// the log (`logged_inbox`), never puts it back.
    pub(super) trimmed: std::collections::HashSet<String>,
    /// Woken when a notice is written or ends, or the chat closes: a withdraw waits on it for
    /// a notice that carries its message and is not written yet (`inbox_settled`).
    pub(super) settled: Arc<tokio::sync::Notify>,
    /// The prompt that holds the chat's first work ([`FirstWork`]) while it runs: another agent's
    /// message meanwhile is no first work.
    pub(super) first: Option<String>,
    /// The person's own turn held a notice back (module docs): its messages are due as a turn of
    /// their own once the chat is idle, whatever their class. Cleared when a notice goes.
    pub(super) held_by_person: bool,
}

/// How [`Hub::inbox_route`] routes a prompt.
pub(super) enum Route {
    /// Into the inbox: its sender and class.
    Inbox(String, PromptClass),
    /// The chat's first work, run as its prompt; the hold ends when this drops.
    First(FirstWork),
    /// As any prompt.
    Plain,
}

/// A prompt's hold on its chat's first work ([`Inbox::first`]), let go when the prompt ends: a
/// refused one leaves the next message free to be the first work.
pub(super) struct FirstWork {
    session: Weak<Session>,
    prompt_id: String,
}

impl Drop for FirstWork {
    fn drop(&mut self) {
        let Some(session) = self.session.upgrade() else { return };
        let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
        if inbox.first.as_deref() == Some(self.prompt_id.as_str()) {
            inbox.first = None;
        }
    }
}

/// A notice whose task has not finished (`Inbox::carrying`).
pub(super) struct Carry {
    pub(super) notice: String,
    pub(super) ids: Vec<String>,
    /// A steer: in flight until the agent took it at its tool step (its answer), so a turn
    /// takes at most one notice per step.
    steer: bool,
    waiters: Vec<(String, Waiter)>,
}

/// What [`Hub::inbox_unsend`] did with an inbox item.
pub(super) enum Unsend {
    /// A notice carries it and is not written yet: wait for it (`inbox_settled`) and ask again.
    Carried,
    /// No notice had carried it: it left the inbox.
    Unsent,
    /// A notice carried it: it stays.
    Noticed,
    /// The inbox no longer holds it (read and trimmed).
    Gone,
}

/// Whether a `session/prompt` is a plain send the inbox may take: from a connection on this host
/// (an agent's `acpmux send`, the MCP `send` tool), with no supersede key, not steer-only, and no
/// team message. A peer daemon's or the mesh relay's forward, a team message, a correction under
/// a supersede key and a steer-only send keep the queue for now, as do the prompts acpmux makes
/// itself (lane reports, task cards, a paused pair's release), which never set
/// `PromptOptions::inbox`.
///
/// Nor a prompt whose caller gave its own provenance (`prompt_provenance::of`): a `cmux agent
/// message` the cmux daemon's pump delivers (`agents_chat_send`, the app's reply in place). The
/// cmux daemon keeps that message, its delivery receipt and its Stop hold, and the chat must show
/// it as that agent message: the app's reply in place answers its `user_message`
/// (`app_reply_fits`). In the inbox it became a notice, so a reply in place was refused, a send to
/// a chat that cannot run said delivered, and a send to an idle chat ran no turn.
pub(crate) fn plain_send(
    from_peer: bool,
    team: bool,
    supersede: bool,
    steer_only: bool,
    given_provenance: bool,
) -> bool {
    !from_peer && !team && !supersede && !steer_only && !given_provenance
}

/// Whether a provenance is a plain message from another agent: none (a sender that named
/// itself, or a connection that proved its session), `agent_message` or `session_message`.
fn plain_kind(provenance: Option<&Value>) -> bool {
    match provenance.and_then(|p| p.get("kind")) {
        None => true,
        Some(kind) => matches!(kind.as_str(), Some("agent_message" | "session_message")),
    }
}

/// Whether a prompt is an inbox item: another agent's message of text only, from no Web
/// connection, that is no slash command, no sub-session family message and no notice.
pub(super) fn takes(
    agent: bool,
    released: bool,
    control: Control,
    blocks: &[Value],
    provenance: Option<&Value>,
) -> bool {
    agent
        && !released
        && control != Control::Web
        && !is_notice(provenance)
        && blocks.iter().all(|b| {
            b.get("type").and_then(Value::as_str) == Some("text")
                && b.as_object().is_some_and(|o| o.keys().all(|k| k == "type" || k == "text"))
        })
        && super::forum::slash_command(blocks).is_none()
        && !crate::prompt_uploads::any(blocks)
        && !super::subsession_guard::is_family_prompt(provenance)
}

/// Whether the chat is a review box (`review_box.rs`): it has no inbox, and another agent's
/// message waits behind its running turn instead of steering in (`turns.rs`).
pub(super) fn review_box(session: &Session) -> bool {
    crate::review_box::of_meta(&session.meta.lock().unwrap_or_else(|e| e.into_inner()))
}

/// Whether the chat's agent can read its inbox: it has cmux's tools (`inbox_read`), as its agent
/// was launched (`hub/tools.rs`), or will be by this daemon. Not one of a remote origin, nor any
/// while the daemon-wide switch turns the tools off (`agent_tools::SWITCH_ENV`).
pub(super) fn reads_inbox(session: &Session) -> bool {
    let switch = std::env::var_os(crate::agent_tools::SWITCH_ENV);
    !session.meta.lock().unwrap_or_else(|e| e.into_inner()).remote_origin
        && switch.is_none_or(|v| v != "0")
        && session.launched_with_tools.load(Ordering::SeqCst) != 2
}

/// Takes the chat's first work for `prompt_id` when a message now would be it: the chat never ran
/// a turn, none runs, nothing waits in its queue or its inbox, and no other prompt holds it. The
/// hold is taken under the inbox's lock, so of two messages that come at once only one is the
/// first work; the chat is read only once it is held, so a first work that ran and let go before
/// this took it is seen as the turn it ran.
fn first_work(session: &Arc<Session>, prompt_id: &str) -> Option<FirstWork> {
    {
        let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
        if !inbox.items.is_empty() || inbox.first.is_some() {
            return None;
        }
        inbox.first = Some(prompt_id.to_owned());
    }
    let first = FirstWork { session: Arc::downgrade(session), prompt_id: prompt_id.to_owned() };
    let idle = session.meta.lock().unwrap_or_else(|e| e.into_inner()).turn_count == 0
        && session.turn().is_none()
        && session.queue.lock().unwrap_or_else(|e| e.into_inner()).is_empty();
    // Not idle: dropping `first` lets the hold go.
    idle.then_some(first)
}

/// The refusal of a steer-only message from another agent to a review box's running turn.
pub(super) fn review_box_steer_refused() -> RpcError {
    RpcError::invalid_params(
        "steer.unavailable: a review box takes no other agent's steer; send without steer-only to queue behind its review",
    )
    .with_data(json!({"reason": "steer.unavailable", "turnCap": false, "reviewBox": true}))
}

/// The refusal of another agent's steer-only prompt while one of the person's prompts waits
/// behind the running turn (module docs).
pub(super) fn prompt_waits_steer_refused() -> RpcError {
    RpcError::invalid_params(
        "steer.unavailable: a prompt waits behind the running turn; another agent's message goes in after it, so send without steer-only to queue",
    )
    .with_data(json!({"reason": "steer.unavailable", "turnCap": false, "promptWaits": true}))
}

/// Whether a prompt's provenance is a notice's.
pub(crate) fn is_notice(provenance: Option<&Value>) -> bool {
    provenance.and_then(|p| p.get("kind")).and_then(Value::as_str) == Some(NOTICE_KIND)
}

/// The thread a message goes in: `explicit` (`pr:N` or `topic:T`, from `_meta.acpmux`), else
/// its sender and the pull request its first line names, else its sender.
pub(crate) fn thread_key(explicit: Option<&str>, sender: &str, text: &str) -> String {
    if let Some(key) = explicit.filter(|k| !k.is_empty()) {
        return key.to_owned();
    }
    match first_pr(text.lines().next().unwrap_or_default()) {
        Some(n) => format!("from:{sender}/pr:{n}"),
        None => format!("from:{sender}"),
    }
}

/// The explicit thread of `_meta.acpmux`: `pr` (a number, or a `#N` string) or `topic`.
pub(crate) fn explicit_thread(mux: Option<&Value>) -> Result<Option<String>, RpcError> {
    let Some(mux) = mux else { return Ok(None) };
    let bad = |what: &str| {
        RpcError::invalid_params(what.to_owned())
            .with_data(json!({"reason": "thread.value_refused"}))
    };
    match mux.get("pr") {
        None | Some(Value::Null) => {}
        Some(Value::Number(n)) => match n.as_u64() {
            Some(n) if n > 0 => return Ok(Some(format!("pr:{n}"))),
            _ => return Err(bad("pr must be a pull request number")),
        },
        Some(Value::String(s)) => match s.trim_start_matches('#').parse::<u64>() {
            Ok(n) if n > 0 => return Ok(Some(format!("pr:{n}"))),
            _ => return Err(bad("pr must be a pull request number")),
        },
        Some(_) => return Err(bad("pr must be a pull request number")),
    }
    match mux.get("topic") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(t)) => {
            let t = t.trim();
            if t.is_empty() || t.len() > 200 || t.contains('\n') {
                return Err(bad("topic must be one line of 1 to 200 bytes"));
            }
            // A thread id from `inbox_threads` names itself.
            if t.starts_with("pr:") || t.starts_with("topic:") || t.starts_with("from:") {
                return Ok(Some(t.to_owned()));
            }
            Ok(Some(format!("topic:{t}")))
        }
        Some(_) => Err(bad("topic must be a string")),
    }
}

/// The first pull request a line names: `#N`, or `pull/N` in a link.
fn first_pr(line: &str) -> Option<u64> {
    let digits = |s: &str| {
        let n: String = s.chars().take_while(char::is_ascii_digit).collect();
        n.parse::<u64>().ok().filter(|n| *n > 0)
    };
    let mut best: Option<(usize, u64)> = None;
    for marker in ["#", "pull/"] {
        for (i, _) in line.match_indices(marker) {
            if let Some(n) = line.get(i..).and_then(|s| s.strip_prefix(marker)).and_then(digits)
                && best.is_none_or(|(at, _)| i < at)
            {
                best = Some((i, n));
            }
        }
    }
    best.map(|(_, n)| n)
}

/// How a thread reads in a notice: `#N`, the topic, or "messages".
fn label(key: &str) -> String {
    if let Some(n) = key.strip_prefix("pr:") {
        return format!("#{n}");
    }
    if let Some(t) = key.strip_prefix("topic:") {
        return format!("\"{t}\"");
    }
    match key.rsplit_once("/pr:") {
        Some((_, n)) => format!("#{n}"),
        None => "messages".to_owned(),
    }
}

/// Whether a prompt's provenance marks it a chat's first work ([`FIRST_WORK`]).
pub(super) fn is_first_work(provenance: Option<&Value>) -> bool {
    provenance.and_then(|p| p.get(FIRST_WORK)).and_then(Value::as_bool) == Some(true)
}

/// The session a message came from, when its provenance names one (not a sender that only
/// named itself).
pub(super) fn sender_session(provenance: Option<&Value>) -> Option<String> {
    let from = provenance?.get("from")?.as_str()?;
    if from == crate::prompt_provenance::NAMED_SENDER || from.is_empty() {
        return None;
    }
    Some(from.strip_prefix("acp:").unwrap_or(from).to_owned())
}

/// Whether a message reports work this chat gave: a lane's report (`lane_reports.rs`) or a task's
/// result (`tasks.rs`).
fn is_report(provenance: Option<&Value>) -> bool {
    let kind = provenance.and_then(|p| p.get("kind")).and_then(Value::as_str);
    kind == Some(super::lane_reports::KIND) || kind == Some("task_result")
}

/// The wire name of what a class asks: `blocker` (a block or a question), `action` (a result) or
/// `fyi`.
fn kind_of(class: PromptClass) -> &'static str {
    match class {
        PromptClass::Block | PromptClass::Question => "blocker",
        PromptClass::Result => "action",
        PromptClass::Fyi => "fyi",
    }
}

/// The first line of `text`, cut to [`PREVIEW_CHARS`].
fn preview(text: &str) -> String {
    let line = text.lines().find(|l| !l.trim().is_empty()).unwrap_or_default().trim();
    let cut: String = line.chars().take(PREVIEW_CHARS).collect();
    if cut.len() < line.len() { format!("{cut}…") } else { cut }
}

/// The notice of `items` (the new ones, in their order): one line per thread, blockers first,
/// then the thread with the newest message first. When their text is [`WHOLE_BYTES`] or less,
/// the notice holds every message whole: a one-line message alone in its thread on its thread's
/// line, the others quoted under it, oldest first. Otherwise each line has the newest one's
/// preview, and the notice says how to read a thread whole: the `inbox_read` tool, or the shell
/// for an agent that has no such tool (one started before the inbox, a harness without acpmux's
/// MCP server). What the inbox is (no turn of its own, answer or leave it) is the tools' to say,
/// not every notice's (Leo, 2026-10-31: "why is there so much additional text?").
///
/// The parts (the notice's provenance `threads`) are what the transcript draws: per thread its
/// id, label, senders, new messages, whether it holds a blocker, the newest one's preview and its
/// sender's session, and the messages whole when the notice holds them.
pub(super) fn render(items: &[&Item]) -> (String, Value) {
    let mut threads: Vec<(&str, Vec<&Item>)> = Vec::new();
    for item in items {
        match threads.iter_mut().find(|(k, _)| *k == item.thread) {
            Some((_, list)) => list.push(item),
            None => threads.push((&item.thread, vec![item])),
        }
    }
    let blocker = |list: &[&Item]| list.iter().any(|i| i.class.urgent());
    let newest = |list: &[&Item]| list.iter().map(|i| i.at).max().unwrap_or(0);
    threads.sort_by_key(|(_, list)| (!blocker(list), std::cmp::Reverse(newest(list))));
    let whole = items.iter().map(|i| i.text.len()).sum::<usize>() <= WHOLE_BYTES;
    let n = threads.len();
    let mut text = format!(
        "[inbox] New messages from other agents in {n} thread{}.",
        if n == 1 { "" } else { "s" }
    );
    if !whole {
        text.push_str(
            " Read one whole with inbox_read (its thread id), or at a shell: \
             acpmux session inbox \"$ACPMUX_SESSION_ID\" --thread ID --mark-read",
        );
    }
    let mut parts = Vec::new();
    for (key, list) in &threads {
        let last = list.iter().max_by_key(|i| i.at).copied();
        let mut from: Vec<&str> = Vec::new();
        for i in list {
            if !from.contains(&i.from.as_str()) {
                from.push(&i.from);
            }
        }
        let tag = if blocker(list) { "[blocker] " } else { "" };
        let head = format!("{tag}{} new in {} from {}", list.len(), label(key), from.join(", "));
        let one_line = match list.as_slice() {
            [only] if whole && !body(&only.text).is_empty() && !body(&only.text).contains('\n') => {
                Some(body(&only.text))
            }
            _ => None,
        };
        if let Some(line) = one_line {
            text.push_str(&format!("\n- {head}: {line} (thread {key})"));
        } else if whole {
            text.push_str(&format!("\n- {head} (thread {key}):"));
            for (at, item) in list.iter().enumerate() {
                if at > 0 {
                    text.push_str("\n  >");
                }
                // Several messages each name their sender first.
                let lead = if list.len() > 1 { format!("{}: ", item.from) } else { String::new() };
                // A message of no text still gets its quote line, so none goes missing.
                let mut lines: Vec<&str> = body(&item.text).lines().collect();
                if lines.is_empty() {
                    lines.push("");
                }
                for (row, line) in lines.into_iter().enumerate() {
                    let lead = if row == 0 { lead.as_str() } else { "" };
                    let quoted = format!("  > {lead}{line}");
                    text.push('\n');
                    text.push_str(quoted.trim_end());
                }
            }
        } else {
            let line = last.map(|i| preview(&i.text)).unwrap_or_default();
            text.push_str(&format!("\n- {head}: {line} (thread {key})"));
        }
        let ids: Vec<&str> = list.iter().map(|i| i.prompt_id.as_str()).collect();
        let mut part = json!({
            "threadId": key, "label": label(key), "new": list.len(), "from": from,
            "promptIds": ids, "blocker": blocker(list),
            "preview": last.map(|i| preview(&i.text)), "newestAt": newest(list),
        });
        if let Some(session) = last.and_then(|i| i.from_session.as_deref()) {
            part.set("fromSession", json!(session));
        }
        if whole {
            let messages: Vec<Value> = list
                .iter()
                .map(|i| json!({"promptId": i.prompt_id, "from": i.from, "at": i.at, "text": i.text}))
                .collect();
            part.set("messages", json!(messages));
        }
        parts.push(part);
    }
    (text, json!(parts))
}

/// A message's text as the notice quotes it: without the blank lines around it, and with the first
/// line's indent kept (an indented code block stays one).
fn body(text: &str) -> &str {
    text.trim_start_matches(['\n', '\r']).trim_end()
}

/// Whether `item` may wake the idle chat of `meta`.
fn wakes(meta: &SessionMeta, item: &Item) -> bool {
    match item.class {
        PromptClass::Block | PromptClass::Question => true,
        PromptClass::Fyi => false,
        PromptClass::Result => {
            let parent = meta.lineage.as_ref().map(|l| l.parent.as_str());
            let from = item.from_session.as_deref();
            meta.turn_count == 0
                || item.report
                || (from.is_some() && (from == parent || from == meta.delegator.as_deref()))
        }
    }
}

/// Whether the person's (or any) prompt waits in the queue: no notice steers into the running
/// turn then, so it is never held up behind them.
fn prompt_waits(session: &Session) -> bool {
    session.queue.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|q| !q.held)
}

/// Whether one of the person's prompts waits in the queue (not held, no agent's message): no other
/// agent's steer goes into the running turn then (`turns.rs`), so the turn can end for it.
/// Other agents' messages waiting do not hold one: they never held each other up.
pub(super) fn persons_prompt_waits(session: &Session) -> bool {
    let queue = session.queue.lock().unwrap_or_else(|e| e.into_inner());
    queue.iter().any(|q| !q.held && q.run.agent.is_none())
}

/// Whether a chat's first work waits in its queue ([`FIRST_WORK`] on its provenance), as one a
/// person's prompt went ahead of does, and one a restart rebuilt with no hold of its own.
fn first_work_waits(session: &Session) -> bool {
    let queue = session.queue.lock().unwrap_or_else(|e| e.into_inner());
    queue.iter().any(|q| !q.held && is_first_work(q.run.provenance.as_ref()))
}

/// Whether a prompt is the person's own (module docs): no other agent's message, and none of
/// acpmux's own prompts (a notice, a digest, the turn cap's notice, a subagent's retry, a cut
/// turn's automatic continuation), whose turns take notices and steers as before.
pub(super) fn persons_prompt(agent: Option<&str>, provenance: Option<&Value>) -> bool {
    let auto_resume =
        provenance.and_then(|p| p.get("kind")).and_then(Value::as_str) == Some("auto_resume");
    agent.is_none()
        && !auto_resume
        && !is_notice(provenance)
        && !super::digest::inbox_digest::is_digest(provenance)
        && !super::turn_cap::is_notice(provenance)
        && !super::subagent_retry::is_retry(provenance)
}

/// Whether the running turn is one the person's own prompt started: no notice and no other
/// agent's steer goes into it (module docs).
pub(super) fn persons_turn(session: &Session) -> bool {
    session.turn().is_some_and(|t| t.persons)
}

/// The refusal of another agent's steer-only prompt while the person's own turn runs (module
/// docs): it goes in after that turn, as a turn of its own.
pub(super) fn persons_turn_steer_refused() -> RpcError {
    RpcError::invalid_params(
        "steer.unavailable: the person's own turn runs; another agent's message goes in after it, as a turn of its own, so send without steer-only to queue",
    )
    .with_data(json!({"reason": "steer.unavailable", "turnCap": false, "personsTurn": true}))
}

/// Whether a notice may not steer into the running turn now: a prompt waits, the person's own
/// prompt started the turn, or the turn is past its cap (`turns.rs` checks it again at dispatch).
pub(super) fn notice_held(session: &Session) -> bool {
    let turn = session.turn();
    prompt_waits(session)
        || review_box(session)
        || turn.as_ref().is_some_and(|t| t.persons)
        || turn.is_some_and(|t| capped(&session.meta(), t.started_at, now_ms()))
}

/// Whether the session's running turn is past its cap.
fn capped(meta: &SessionMeta, started_at: u64, now: u64) -> bool {
    super::turn_cap::turn_cap_ms(meta).is_some_and(|cap| now.saturating_sub(started_at) >= cap)
}

/// What the inbox does now.
#[derive(Clone, Copy)]
enum Next {
    Nothing,
    /// A steer into the running turn.
    Steer,
    /// A turn of its own, now.
    Wake,
    /// A turn of its own at this time.
    WakeAt(u64),
}

impl Hub {
    /// Whether a prompt goes into the inbox ([`takes`]): its sender and class when it does. Out
    /// of line, so the prompt's future holds no sender lookup.
    #[inline(never)]
    #[allow(clippy::too_many_arguments)]
    pub(super) fn inbox_route(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        blocks: &[Value],
        control: Control,
        send_now: bool,
        class: Option<PromptClass>,
        provenance: Option<&Value>,
        agent: Option<&str>,
        plain: bool,
    ) -> Route {
        // A chat closing or closed takes a message as it did before the inbox: none waits in
        // the inbox of a chat that will not wake. A review box has no inbox, nor a chat whose
        // agent cannot read one (module docs).
        if !plain
            || !plain_kind(provenance)
            || super::queue::closing(session)
            || review_box(session)
            || !reads_inbox(session)
        {
            return Route::Plain;
        }
        let Some(agent) = super::digest::agent_sender(provenance, agent) else {
            return Route::Plain;
        };
        if !takes(true, send_now, control, blocks, provenance) {
            return Route::Plain;
        }
        // A chat's first work runs as its prompt, not as a notice of it (module docs). Its sender
        // is the delegator once its turn starts (`turns.rs`), not before: a refused one is not.
        if let Some(first) = first_work(session, prompt_id) {
            return Route::First(first);
        }
        let class = crate::prompt_class::of_message(class, true).unwrap_or(PromptClass::Result);
        Route::Inbox(agent, class)
    }

    /// `session/prompt` of another agent's message the inbox takes (`turns.rs`): logged, put in
    /// its thread, and answered by the notice that carries it.
    #[allow(clippy::too_many_arguments)]
    pub(super) async fn inbox_accept(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: &[Value],
        client: &str,
        prompt_id: &str,
        sender: &str,
        class: PromptClass,
        explicit: Option<&str>,
        provenance: Option<&Value>,
        accept: &mut impl FnMut(Value),
    ) -> Result<Value, RpcError> {
        let text = prompt_text(blocks);
        let thread = thread_key(explicit, sender, &text);
        let (tx, mut rx) = tokio::sync::watch::channel(None);
        let mut resent: Option<Option<super::queue::Answer>> = None;
        let mut withdrawn = false;
        let mut from_log = false;
        let fresh = {
            let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            // Read under the inbox's lock: `kill` marks the chat closed before `inbox_closed`
            // takes it, so a message either sees the close or is answered by it.
            if session.meta().status == SessionStatus::Closed {
                return Err(super::queue::closing_error());
            }
            let carry = inbox.carrying.iter_mut().find(|c| c.ids.iter().any(|id| id == prompt_id));
            if let Some(carry) = carry {
                // A resend of one a notice carries now: answered with that notice.
                match carry.waiters.iter().find(|(id, _)| id == prompt_id) {
                    Some((_, waiter)) => rx = waiter.subscribe(),
                    None => carry.waiters.push((prompt_id.to_owned(), tx.clone())),
                }
                false
            } else if inbox.removed.contains(prompt_id) {
                // A resend of one withdrawn before a notice carried it: never back in.
                withdrawn = true;
                false
            } else if inbox.trimmed.contains(prompt_id) {
                // A resend of one answered and let go of: answered from the log.
                from_log = true;
                false
            } else {
                match inbox.items.iter_mut().find(|i| i.prompt_id == prompt_id) {
                    // A resend of one it holds: answered with it.
                    Some(item) if !item.noticed || item.answer.is_some() => {
                        rx = item.answer.get_or_insert_with(|| tx.clone()).subscribe();
                        false
                    }
                    // A resend of one a notice carried and answered already (or before a restart):
                    // answered with that notice's answer, as a resend of a logged prompt is
                    // (`logged_prompt`).
                    Some(item) => {
                        resent = Some(item.answered.clone());
                        false
                    }
                    None => {
                        inbox.items.push(Item {
                            prompt_id: prompt_id.to_owned(),
                            notice: None,
                            answered: None,
                            thread: thread.clone(),
                            from: sender.to_owned(),
                            from_session: sender_session(provenance),
                            class,
                            report: is_report(provenance),
                            at: now_ms(),
                            text: text.clone(),
                            details: provenance.and_then(|p| p.get("details")).cloned(),
                            noticed: false,
                            read: false,
                            answer: Some(tx.clone()),
                        });
                        trim(&mut inbox);
                        true
                    }
                }
            }
        };
        if from_log {
            let answer = self.logged_inbox_answer(session, prompt_id);
            accept(
                json!({"sessionId": session.id, "promptId": prompt_id, "queued": false, "inbox": true, "duplicate": true}),
            );
            return answer.unwrap_or_else(|| Ok(interrupted(prompt_id)));
        }
        if withdrawn {
            accept(
                json!({"sessionId": session.id, "promptId": prompt_id, "queued": false, "inbox": true, "withdrawn": true}),
            );
            return Ok(super::queue::withdrawn_reply(prompt_id, ""));
        }
        if let Some(answered) = resent {
            // Noticed, carried by no notice now and with no answer: a notice of the daemon before
            // a restart carried it and never ended, as `logged_inbox` answers.
            let answer = answered.unwrap_or_else(|| Ok(interrupted(prompt_id)));
            let answer = answer.map(|mut done| {
                merge_mux_meta(&mut done, json!({"duplicate": true, "noticed": true}));
                done
            });
            tx.send_replace(Some(answer));
        }
        if fresh {
            let mut msg = json!({"promptId": prompt_id, "threadId": thread, "from": sender, "class": class, "kind": kind_of(class), "client": client, "text": text, "prompt": blocks});
            if let Some(from) = sender_session(provenance) {
                msg.set("fromSession", json!(from));
            }
            if is_report(provenance) {
                msg.set("report", json!(true));
            }
            let msg = crate::prompt_provenance::marked(msg, provenance);
            self.append(session, "mux", "inbox", msg);
            self.note_delegator(session, provenance);
        }
        accept(
            json!({"sessionId": session.id, "promptId": prompt_id, "queued": true, "inbox": true, "threadId": thread}),
        );
        self.inbox_review(session);
        let answer = match rx.wait_for(Option::is_some).await {
            Ok(answer) => answer.clone().unwrap_or_else(|| Err(RpcError::internal("no answer"))),
            Err(_) => Err(super::queue::closing_error()),
        };
        answer.map(|mut v| {
            merge_mux_meta(
                &mut v,
                json!({"promptId": prompt_id, "inbox": true, "threadId": thread}),
            );
            v
        })
    }

    /// Archive a lane result the parent already consumed through a wait or transcript read.
    /// It is durable and available in its thread, but has no notice, queued turn or waiter.
    pub(super) fn lane_report_delivered_read(
        self: &Arc<Self>,
        session: &Arc<Session>,
        lane: &str,
        prompt_id: &str,
        text: &str,
        provenance: &Value,
    ) {
        let from = provenance.get("fromName").and_then(Value::as_str).unwrap_or(lane);
        let thread = thread_key(None, from, text);
        let at = now_ms();
        let fresh = {
            let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            if inbox.items.iter().any(|i| i.prompt_id == prompt_id)
                || inbox.trimmed.contains(prompt_id)
            {
                false
            } else {
                inbox.items.push(Item {
                    prompt_id: prompt_id.to_owned(),
                    notice: None,
                    answered: None,
                    thread: thread.clone(),
                    from: from.to_owned(),
                    from_session: Some(lane.to_owned()),
                    class: PromptClass::Result,
                    report: true,
                    at,
                    text: text.to_owned(),
                    details: provenance.get("details").cloned(),
                    noticed: true,
                    read: true,
                    answer: None,
                });
                trim(&mut inbox);
                true
            }
        };
        if !fresh {
            return;
        }
        let mut opts = PromptOptions {
            provenance: Some(provenance.clone()),
            agent: Some(from.to_owned()),
            message_id: Some(prompt_id.to_owned()),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": text})];
        // Rebuild the projection from the removed prompt's id. The queued acceptance path may
        // already have written this message; using the canonical prompt id here lets the journal
        // index deduplicate the read archive instead of creating a second projection when the
        // transcript page races the queue removal.
        let message =
            super::message_events::message_context(self, session, &blocks, &opts, prompt_id);
        super::message_events::embed_message_context(&mut opts, message.as_ref(), &session.id);
        let msg = json!({
            "promptId": prompt_id, "threadId": thread, "from": from, "fromSession": lane,
            "class": "result", "kind": kind_of(PromptClass::Result), "client": "acpmux", "text": text,
            "prompt": [{"type": "text", "text": text}], "report": true, "deliveredRead": true,
        });
        self.append(
            session,
            "mux",
            "inbox",
            crate::prompt_provenance::marked(msg, opts.provenance.as_ref()),
        );
        if let Some(message) = message.as_ref() {
            super::message_events::record_message_context(self, &session.id, message);
        }
        // Existing readers can replay these marks without knowing the new deliveredRead flag.
        self.append(
            session,
            "mux",
            "inbox_read",
            json!({"threadId": thread, "promptIds": [prompt_id]}),
        );
        self.append(
            session,
            "mux",
            "inbox_noticed",
            json!({"promptIds": [prompt_id], "noticePromptId": prompt_id}),
        );
    }

    /// The first message to a chat that never ran a turn names its delegator: its later actions
    /// wake the chat too.
    fn note_delegator(&self, session: &Arc<Session>, provenance: Option<&Value>) {
        let Some(from) = sender_session(provenance) else { return };
        let set = {
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let set = meta.turn_count == 0 && meta.delegator.is_none() && from != meta.id;
            if set {
                meta.delegator = Some(from);
            }
            set
        };
        if set {
            self.save_meta(session);
        }
    }

    /// Delivers the inbox when it may (module docs), else arms the wake timer.
    pub(super) fn inbox_review(self: &Arc<Self>, session: &Arc<Session>) {
        let meta = session.meta();
        let now = now_ms();
        // Read before the inbox's lock: the retry's own lock is never taken under it.
        // Taken first: a continuation let go after `continuing` is read still wakes the timer.
        let released = session.auto_resume.released();
        let continuing = self.continuation_pending(session);
        let next = {
            let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            // Set once `new` lets go of the inbox (below).
            let mut held_by_person = false;
            let next = {
                let new: Vec<&Item> = inbox.items.iter().filter(|i| !i.noticed).collect();
                if new.is_empty()
                    || inbox.in_flight.is_some()
                    || meta.status == SessionStatus::Closed
                {
                    Next::Nothing
                } else {
                    match session.turn() {
                        Some(turn) => {
                            let steers = session.steering.load(Ordering::SeqCst);
                            let retry = match inbox.refused_at {
                                0 => 0,
                                at => at.saturating_add(REFUSED_RETRY_MS),
                            };
                            // A review box's turn takes no notice: what its inbox held before
                            // it became one waits for the turn's end (module docs). Nor does
                            // the person's own: the notice goes in as a turn after it, never
                            // into a turn carried on from it (`carried_turn.rs`).
                            held_by_person = turn.persons;
                            if !steers
                                || turn.persons
                                || inbox.held_by_person
                                || capped(&meta, turn.started_at, now)
                                || prompt_waits(session)
                                || crate::review_box::of_meta(&meta)
                            {
                                Next::Nothing
                            } else if retry > now {
                                // A refused steer is tried again no sooner than the backoff: no
                                // loop of refusals within a turn.
                                Next::WakeAt(retry)
                            } else {
                                Next::Steer
                            }
                        }
                        // A first work holds the chat, or waits in its queue (a restart rebuilds
                        // it with no hold), and has no turn yet: no notice goes ahead of it.
                        // Looked at again after the debounce, until its turn takes the notice,
                        // its hold is let go, or it leaves the queue.
                        None if inbox.first.is_some() || first_work_waits(session) => {
                            Next::WakeAt(now.saturating_add(WAKE_DEBOUNCE_MS))
                        }
                        None => {
                            // A waking message after the debounce; anything after the flush, so no
                            // message is stranded in an idle chat.
                            // Messages the person's own turn held back are due now: they would
                            // have gone into that turn.
                            let waking = new.iter().filter(|i| wakes(&meta, i)).map(|i| i.at).min();
                            let oldest = new.iter().map(|i| i.at).min().unwrap_or(now);
                            let flush = oldest.saturating_add(FLUSH_MS);
                            let due = if inbox.held_by_person {
                                now
                            } else {
                                waking.map_or(flush, |at| {
                                    at.saturating_add(WAKE_DEBOUNCE_MS).min(flush)
                                })
                            };
                            let retry = match inbox.refused_at {
                                0 => 0,
                                at => at.saturating_add(REFUSED_RETRY_MS),
                            };
                            let at = due.max(retry);
                            if continuing {
                                // The cut turn's continuation may still fire (`auto_resume.rs`):
                                // a turn of its own now would supersede it. Looked at again
                                // later; a continuation that runs ends its timer when its turn
                                // starts (`inbox_turn_started`) and reviews it as it ends.
                                Next::WakeAt(at.max(now.saturating_add(REFUSED_RETRY_MS)))
                            } else if at <= now {
                                Next::Wake
                            } else {
                                Next::WakeAt(at)
                            }
                        }
                    }
                }
            };
            if held_by_person {
                inbox.held_by_person = true;
            }
            match next {
                Next::Nothing => {
                    if let Some(timer) = inbox.timer.take() {
                        timer.abort();
                    }
                }
                Next::WakeAt(at) => self.arm_locked(&mut inbox, session, at, now, released),
                Next::Steer | Next::Wake => {}
            }
            next
        };
        match next {
            // Disarmed and armed under the lock the decision was made under (above), so a review
            // that decided earlier never aborts a timer a later one armed.
            Next::Nothing | Next::WakeAt(_) => {}
            Next::Steer => self.deliver_notice(session, true),
            Next::Wake => self.deliver_notice(session, false),
        }
    }

    /// Sends the notice of every new message, as a steer or (`steer` false) a turn of its own,
    /// and answers their waiting `session/prompt`s with how it went in.
    fn deliver_notice(self: &Arc<Self>, session: &Arc<Session>, steer: bool) {
        let notice_id = format!("inbox-notice-{}", uuid::Uuid::now_v7());
        let (text, whole, parts, ids) = {
            let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            if inbox.in_flight.is_some() {
                return;
            }
            if inbox.items.iter().all(|i| i.noticed) {
                return;
            }
            // The wake timer is done: this notice carries what it waited for.
            if let Some(timer) = inbox.timer.take() {
                timer.abort();
            }
            inbox.held_by_person = false;
            let new: Vec<&Item> = inbox.items.iter().filter(|i| !i.noticed).collect();
            let (text, parts) = render(&new);
            let whole = team_page::whole_notice(&new);
            let ids: Vec<String> = new.iter().map(|i| i.prompt_id.clone()).collect();
            let mut waiters = Vec::new();
            for item in inbox.items.iter_mut().filter(|i| !i.noticed) {
                item.noticed = true;
                if let Some(answer) = item.answer.take() {
                    waiters.push((item.prompt_id.clone(), answer));
                }
            }
            inbox.in_flight = Some((notice_id.clone(), ids.clone()));
            let carry = Carry { notice: notice_id.clone(), ids: ids.clone(), steer, waiters };
            inbox.carrying.push(carry);
            (text, whole, parts, ids)
        };
        let provenance = json!({"kind": NOTICE_KIND, "noticeId": notice_id, "threads": parts});
        let opts = PromptOptions {
            prompt_id: Some(notice_id.clone()),
            provenance: Some(provenance),
            // Into the running turn or not at all: a turn that ended leaves the messages new.
            steer_only: steer,
            ..PromptOptions::default()
        };
        let (hub, s) = (self.clone(), session.clone());
        tokio::spawn(async move {
            // An agent that can open no thread gets each message whole (`inbox_team_page.rs`).
            let text = if hub.notice_reader_has_tools(&s).await { text } else { whole };
            let blocks = vec![json!({"type": "text", "text": text})];
            let result = Box::pin(hub.run_prompt(&s, blocks, CLIENT, steer, opts)).await;
            // In once its prompt was written to the agent (`inbox_prompt_written`), as a steer
            // or a turn of its own, however it then ended (a Stop after the agent read it).
            hub.notice_done(&s, &notice_id, &ids, result);
        });
    }

    /// A notice ended: in (its prompt was written), its senders are answered with its answer;
    /// not in, its messages are new again and wait on, and the refusal holds the next try back.
    fn notice_done(
        self: &Arc<Self>,
        session: &Arc<Session>,
        notice_id: &str,
        ids: &[String],
        result: super::queue::Answer,
    ) {
        let answered = {
            let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            if inbox.in_flight.as_ref().is_some_and(|(id, _)| id == notice_id) {
                inbox.in_flight = None;
            }
            let at = inbox.written.iter().position(|id| id == notice_id);
            let went_in = at.map(|i| inbox.written.remove(i)).is_some();
            let at = inbox.carrying.iter().position(|c| c.notice == notice_id);
            let waiters = at.map(|i| inbox.carrying.remove(i).waiters).unwrap_or_default();
            // Read under the inbox's lock, as `inbox_accept` reads it: a chat closed since
            // answers its waiting senders here, else `inbox_closed` did or will.
            let closed = super::queue::closing(session);
            if went_in {
                inbox.refused_at = 0;
                let answer = if closed { Err(super::queue::closing_error()) } else { result };
                for item in inbox.items.iter_mut().filter(|i| ids.contains(&i.prompt_id)) {
                    item.answered = Some(answer.clone());
                }
                for (_, waiter) in waiters {
                    waiter.send_replace(Some(answer.clone()));
                }
                inbox.settled.notify_waiters();
                Some(answer)
            } else {
                // Tried again after the backoff, or sooner when a turn starts or ends.
                inbox.refused_at = now_ms();
                for item in inbox.items.iter_mut().filter(|i| ids.contains(&i.prompt_id)) {
                    item.noticed = false;
                }
                // One waiter per message while carried (`inbox_accept`): back on its message.
                for (id, waiter) in waiters {
                    match inbox.items.iter_mut().find(|i| i.prompt_id == id) {
                        Some(item) if !closed => item.answer = Some(waiter),
                        _ => {
                            waiter.send_replace(Some(Err(super::queue::closing_error())));
                        }
                    }
                }
                inbox.settled.notify_waiters();
                None
            }
        };
        // Its messages wait again. The cap's timer saw them carried, and the inbox steers none
        // into a turn past its cap: that turn gets the cap's notice (`turn_cap.rs`).
        if answered.is_none() && !ids.is_empty() && !super::queue::closing(session) {
            self.turn_cap_recheck(session);
        }
        if let Some(answer) = answered {
            let mut msg = json!({"noticePromptId": notice_id, "promptIds": ids});
            match answer {
                Ok(answer) => {
                    msg.set("answer", answer);
                }
                Err(error) => {
                    msg.set("error", json!(error));
                }
            }
            self.append(session, "mux", "inbox_answered", msg);
        }
        self.inbox_review(session);
    }

    /// Ends notice `notice_id`, carrying `ids`, as one refused before its prompt was written.
    #[cfg(test)]
    pub(super) fn inbox_notice_refused(
        self: &Arc<Self>,
        session: &Arc<Session>,
        notice_id: &str,
        ids: &[String],
    ) {
        let refused = Err(RpcError::invalid_params("steer refused"));
        self.notice_done(session, notice_id, ids, refused);
    }

    /// A turn started (`run_prompt_joined`): a refusal before it no longer holds the next try
    /// back, and its wake timer is done.
    pub(super) fn inbox_turn_started(self: &Arc<Self>, session: &Arc<Session>) {
        self.disarm_inbox(session);
        let persons = persons_turn(session);
        let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
        inbox.refused_at = 0;
        // What waits as the person's own turn starts would have gone into it: due at its end. A
        // notice in flight that is refused comes back new, and its review marks it so.
        if persons && inbox.items.iter().any(|i| !i.noticed) {
            inbox.held_by_person = true;
        }
    }

    /// A prompt was written to its agent (a turn's in `run_prompt_joined`, a steer's in
    /// `steer_turn`): the notice in flight that is it went in, its messages are noticed (logged),
    /// and what is new may follow it.
    pub(super) fn inbox_prompt_written(self: &Arc<Self>, session: &Arc<Session>, prompt_id: &str) {
        let landed = {
            let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            // A turn of its own lets the next notice steer in behind it now; a steer is in
            // flight until the agent took it (`notice_done`).
            let steer = inbox.carrying.iter().any(|c| c.notice == prompt_id && c.steer);
            let landed = match &inbox.in_flight {
                Some((id, _)) if id == prompt_id && steer => inbox.in_flight.clone(),
                Some((id, _)) if id == prompt_id => inbox.in_flight.take(),
                _ => None,
            };
            if let Some((id, ids)) = &landed {
                inbox.written.push(id.clone());
                for item in inbox.items.iter_mut().filter(|i| ids.contains(&i.prompt_id)) {
                    item.notice = Some(id.clone());
                }
                inbox.settled.notify_waiters();
            }
            landed
        };
        if let Some((id, ids)) = landed {
            let msg = json!({"noticePromptId": id, "promptIds": ids});
            self.append(session, "mux", "inbox_noticed", msg);
        }
        self.inbox_review(session);
    }

    /// A turn ended (`finish_turn`, `fail_unstarted_turn`): a refusal during it no longer holds
    /// the next try back.
    pub(super) fn inbox_turn_ended(self: &Arc<Self>, session: &Arc<Session>) {
        session.inbox.lock().unwrap_or_else(|e| e.into_inner()).refused_at = 0;
        self.inbox_review(session);
    }

    /// A closed chat's inbox: its timer stops and its waiting senders are answered.
    pub(super) fn inbox_closed(&self, session: &Session) {
        self.disarm_inbox(session);
        let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
        let carried = inbox.carrying.iter_mut().flat_map(|c| c.waiters.drain(..).map(|(_, w)| w));
        let waiting: Vec<Waiter> = carried.collect();
        let held = inbox.items.iter_mut().filter_map(|i| i.answer.take());
        for answer in waiting.into_iter().chain(held.collect::<Vec<_>>()) {
            answer.send_replace(Some(Err(super::queue::closing_error())));
        }
        inbox.settled.notify_waiters();
    }

    /// Arms the wake timer for `at`, aborting the one before (module docs), under the inbox's
    /// lock `inbox` the caller holds. A continuation that may still fire puts a wake off
    /// (`inbox_review`), so the timer also looks again as soon as one is let go, however it went
    /// (`released`, `auto_resume.rs` `Pending`).
    fn arm_locked(
        self: &Arc<Self>,
        inbox: &mut Inbox,
        session: &Arc<Session>,
        at: u64,
        now: u64,
        mut released: tokio::sync::watch::Receiver<u64>,
    ) {
        let hub = Arc::downgrade(self);
        let weak: Weak<Session> = Arc::downgrade(session);
        let task = tokio::spawn(async move {
            let wait = std::time::Duration::from_millis(at.saturating_sub(now));
            tokio::select! {
                () = tokio::time::sleep(wait) => {}
                Ok(()) = released.changed() => {}
            }
            let (Some(hub), Some(session)) = (hub.upgrade(), weak.upgrade()) else { return };
            hub.inbox_review(&session);
        });
        if let Some(previous) = inbox.timer.replace(task.abort_handle()) {
            previous.abort();
        }
    }

    /// Aborts the wake timer, if one waits.
    fn disarm_inbox(&self, session: &Session) {
        let timer = session.inbox.lock().unwrap_or_else(|e| e.into_inner()).timer.take();
        if let Some(timer) = timer {
            timer.abort();
        }
    }

    /// The record kinds `restore_inbox` reads (a log load's, so `store/kind_index.rs` copies them).
    pub(crate) const INBOX_KINDS: &[&str] =
        &["inbox", "inbox_noticed", "inbox_answered", "inbox_read", "inbox_removed"];

    /// The inbox from the session's log (`restore_queue`): every message, read and noticed as
    /// the log says. Run again, it adds only what it does not hold.
    pub(super) fn restore_inbox(&self, session: &Arc<Session>) {
        let mut items: Vec<Item> = Vec::new();
        let mut noticed: std::collections::HashMap<String, String> = Default::default();
        let mut read: std::collections::HashSet<String> = Default::default();
        let mut removed: std::collections::HashSet<String> = Default::default();
        let mut answered: std::collections::HashMap<String, super::queue::Answer> =
            Default::default();
        let kinds = Self::INBOX_KINDS;
        let scanned = self.store.scan_kinds(&session.id, kinds, &mut |e: EventRecord| {
            let ids = || {
                let ids = e.msg.get("promptIds").and_then(Value::as_array).cloned();
                ids.unwrap_or_default().into_iter().filter_map(|v| v.as_str().map(str::to_owned))
            };
            match e.kind.as_str() {
                "inbox" => {
                    let field = |k: &str| e.msg.get(k).and_then(Value::as_str).unwrap_or("");
                    let class =
                        crate::prompt_class::recorded(&e.msg).unwrap_or(PromptClass::Result);
                    items.push(Item {
                        prompt_id: field("promptId").to_owned(),
                        notice: None,
                        answered: None,
                        thread: field("threadId").to_owned(),
                        from: field("from").to_owned(),
                        from_session: e
                            .msg
                            .get("fromSession")
                            .and_then(Value::as_str)
                            .map(str::to_owned),
                        class,
                        report: e.msg.get("report") == Some(&Value::Bool(true)),
                        at: e.at,
                        text: field("text").to_owned(),
                        details: crate::prompt_provenance::recorded(&e.msg)
                            .and_then(|p| p.get("details").cloned()),
                        noticed: e.msg.get("deliveredRead") == Some(&Value::Bool(true)),
                        read: e.msg.get("deliveredRead") == Some(&Value::Bool(true)),
                        answer: None,
                    });
                }
                "inbox_noticed" => {
                    let notice = e.msg.get("noticePromptId").and_then(Value::as_str);
                    let notice = notice.unwrap_or_default().to_owned();
                    noticed.extend(ids().map(|id| (id, notice.clone())));
                }
                "inbox_answered" => {
                    if let Some((notice, answer)) = answered_record(&e.msg) {
                        answered.insert(notice, answer);
                    }
                }
                "inbox_read" => read.extend(ids()),
                "inbox_removed" => {
                    let id = e.msg.get("promptId").and_then(Value::as_str).unwrap_or_default();
                    removed.insert(id.to_owned());
                }
                _ => {}
            }
            true
        });
        if scanned.is_err() || items.is_empty() {
            return;
        }
        let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
        for mut item in items {
            if removed.contains(&item.prompt_id) {
                inbox.removed.insert(item.prompt_id.clone());
            }
            if item.prompt_id.is_empty()
                || removed.contains(&item.prompt_id)
                || inbox.trimmed.contains(&item.prompt_id)
                || inbox.items.iter().any(|i| i.prompt_id == item.prompt_id)
            {
                continue;
            }
            item.notice = noticed.get(&item.prompt_id).cloned().filter(|n| !n.is_empty());
            item.answered = item.notice.as_ref().and_then(|n| answered.get(n).cloned());
            item.noticed |= noticed.contains_key(&item.prompt_id);
            item.read |= read.contains(&item.prompt_id);
            inbox.items.push(item);
        }
        trim(&mut inbox);
    }

    /// `_acpmux/prompt_withdraw` of an inbox item (`withdraw.rs`): one no notice carried yet
    /// leaves the inbox, with an `inbox_removed` record (so a restart drops it too), and its
    /// sender's `session/prompt` answers withdrawn; one a notice carried stays, and the withdraw
    /// sends a notice into its thread.
    pub(super) fn inbox_unsend(&self, session: &Arc<Session>, prompt_id: &str) -> Unsend {
        let removed = {
            let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            let found = inbox.items.iter().enumerate().find(|(_, i)| i.prompt_id == prompt_id);
            match found.map(|(at, i)| (at, i.noticed, i.notice.is_none())) {
                None => return Unsend::Gone,
                Some((_, true, true)) => return Unsend::Carried,
                Some((_, true, false)) => return Unsend::Noticed,
                Some((i, false, _)) => {
                    inbox.removed.insert(prompt_id.to_owned());
                    inbox.items.remove(i)
                }
            }
        };
        let why = json!({"promptId": prompt_id, "threadId": removed.thread, "reason": "withdrawn"});
        self.append(session, "mux", "inbox_removed", why);
        if let Some(answer) = removed.answer {
            answer.send_replace(Some(Ok(super::queue::withdrawn_reply(prompt_id, ""))));
        }
        Unsend::Unsent
    }

    /// Waits until no notice that is not written yet carries `prompt_id` (`Unsend::Carried`):
    /// it was written (the message went in) or it ended (the message is new again).
    pub(super) async fn inbox_settled(&self, session: &Session, prompt_id: &str) {
        loop {
            let settled = session.inbox.lock().unwrap_or_else(|e| e.into_inner()).settled.clone();
            let woken = settled.notified();
            tokio::pin!(woken);
            woken.as_mut().enable();
            let carried = {
                let inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
                let item = inbox.items.iter().find(|i| i.prompt_id == prompt_id);
                item.is_some_and(|i| i.noticed && i.notice.is_none())
                    && inbox.carrying.iter().any(|c| c.ids.iter().any(|id| id == prompt_id))
            };
            if !carried || super::queue::closing(session) {
                return;
            }
            woken.await;
        }
    }

    /// A resent inbox message the log holds (`logged_prompt`), as the prompt ledger answers a
    /// logged prompt: [`Hub::logged_inbox_answer`], a failure as `status: "failed"`.
    pub(super) fn logged_inbox(&self, session: &Session, prompt_id: &str) -> Option<Value> {
        Some(match self.logged_inbox_answer(session, prompt_id)? {
            Ok(v) => v,
            Err(e) => json!({
                "stopReason": Value::Null,
                "_meta": {"acpmux": {"promptId": prompt_id, "inbox": true, "duplicate": true, "status": "failed", "error": e}},
            }),
        })
    }

    /// The answer of a resent inbox message the log holds: withdrawn, its notice's answer (an
    /// error too), or `interrupted` when a notice carried it and the daemon stopped before it
    /// ended. None while the inbox still holds it unanswered (`inbox_accept` answers then), or
    /// when the log has no such message.
    pub(super) fn logged_inbox_answer(
        &self,
        session: &Session,
        prompt_id: &str,
    ) -> Option<super::queue::Answer> {
        let names = |m: &Value| {
            let ids = m.get("promptIds").and_then(Value::as_array);
            ids.is_some_and(|ids| ids.iter().any(|v| v.as_str() == Some(prompt_id)))
        };
        let (mut found, mut removed, mut noticed) = (false, false, false);
        let mut answer: Option<super::queue::Answer> = None;
        let kinds = ["inbox", "inbox_noticed", "inbox_answered", "inbox_removed"];
        let _ = self.store.scan_kinds(&session.id, &kinds, &mut |e: EventRecord| {
            let own = e.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id);
            match e.kind.as_str() {
                "inbox" if own => found = true,
                "inbox_removed" if own => removed = true,
                "inbox_noticed" if names(&e.msg) => noticed = true,
                "inbox_answered" if names(&e.msg) => answer = answered_record(&e.msg).map(|a| a.1),
                _ => {}
            }
            true
        });
        if !found {
            return None;
        }
        if removed {
            return Some(Ok(super::queue::withdrawn_reply(prompt_id, "")));
        }
        let meta = json!({"promptId": prompt_id, "inbox": true, "duplicate": true});
        match answer {
            Some(answer) => Some(answer.map(|mut v| {
                merge_mux_meta(&mut v, meta);
                v
            })),
            None => {
                let held = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
                if !noticed || held.items.iter().any(|i| i.prompt_id == prompt_id) {
                    return None;
                }
                Some(Ok(interrupted(prompt_id)))
            }
        }
    }

    /// `_acpmux/inbox_threads`: the chat's threads, the one with the newest message first.
    pub fn inbox_threads(&self, session: &Session) -> Value {
        let inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
        let mut threads: Vec<(&str, Vec<&Item>)> = Vec::new();
        for item in &inbox.items {
            match threads.iter_mut().find(|(k, _)| *k == item.thread) {
                Some((_, list)) => list.push(item),
                None => threads.push((&item.thread, vec![item])),
            }
        }
        let newest = |list: &[&Item]| list.iter().map(|i| i.at).max().unwrap_or(0);
        threads.sort_by_key(|(_, list)| std::cmp::Reverse(newest(list)));
        let rows: Vec<Value> = threads
            .iter()
            .map(|(key, list)| {
                let mut from: Vec<&str> = Vec::new();
                for i in list {
                    if !from.contains(&i.from.as_str()) {
                        from.push(&i.from);
                    }
                }
                let unread: Vec<&&Item> = list.iter().filter(|i| !i.read).collect();
                let last = list.iter().max_by_key(|i| i.at);
                let class = if unread.iter().any(|i| i.class.urgent()) {
                    "blocker"
                } else if unread.iter().any(|i| i.class == PromptClass::Result) {
                    "action"
                } else {
                    "fyi"
                };
                json!({
                    "threadId": key, "key": key, "label": label(key), "from": from,
                    "unread": unread.len(), "new": list.iter().filter(|i| !i.noticed).count(),
                    "count": list.len(), "newestAt": newest(list),
                    "newestPreview": last.map(|i| preview(&i.text)), "class": class,
                })
            })
            .collect();
        json!({"sessionId": session.id, "threads": rows})
    }

    /// `_acpmux/inbox_thread`: a thread's messages, newest first; `mark_read` marks them read.
    pub fn inbox_thread(&self, session: &Session, thread: &str, mark_read: bool) -> Value {
        let (messages, marked) = {
            let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            let mut marked = Vec::new();
            let mut messages = Vec::new();
            for item in inbox.items.iter_mut().rev().filter(|i| i.thread == thread) {
                messages.push(json!({
                    "promptId": item.prompt_id, "from": item.from, "fromSession": item.from_session,
                    "class": item.class, "kind": kind_of(item.class), "at": item.at,
                    "text": item.text, "read": item.read, "details": item.details,
                }));
                if mark_read && !item.read {
                    item.read = true;
                    marked.push(item.prompt_id.clone());
                }
            }
            (messages, marked)
        };
        if !marked.is_empty() {
            let msg = json!({"threadId": thread, "promptIds": marked});
            self.append(session, "mux", "inbox_read", msg);
        }
        json!({"sessionId": session.id, "threadId": thread, "label": label(thread), "messages": messages})
    }

    /// `_acpmux/inbox_reply`: `text` from this chat's agent to the thread's newest sender here,
    /// into that sender's inbox under the same thread.
    pub async fn inbox_reply(
        self: &Arc<Self>,
        session: &Arc<Session>,
        thread: &str,
        text: &str,
    ) -> Result<Value, RpcError> {
        let to = {
            let inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            let newest = inbox.items.iter().rev().filter(|i| i.thread == thread);
            newest.filter_map(|i| i.from_session.clone()).next()
        };
        let Some(to) = to else {
            return Err(RpcError::invalid_params(
                "inbox.no_sender: no message in that thread names a session here to answer",
            )
            .with_data(json!({"reason": "inbox.no_sender"})));
        };
        let target = self.resolve(&to)?;
        let name = session.meta().name;
        let prompt_id = uuid::Uuid::now_v7().to_string();
        let provenance = crate::prompt_provenance::session_message(&session.id, &name, &target.id);
        // A thread named by its sender's key here is named by ours there.
        let key = match thread.strip_prefix("from:") {
            Some(rest) => match rest.rsplit_once("/pr:") {
                Some((_, n)) => format!("from:{name}/pr:{n}"),
                None => format!("from:{name}"),
            },
            None => thread.to_owned(),
        };
        let (tx, rx) = tokio::sync::oneshot::channel();
        let opts = PromptOptions {
            prompt_id: Some(prompt_id.clone()),
            provenance: Some(provenance),
            agent: Some(name),
            thread: Some(key.clone()),
            inbox: true,
            on_accepted: Some(Box::new(move |v| {
                let _ = tx.send(v);
            })),
            ..PromptOptions::default()
        };
        let (hub, t) = (self.clone(), target.clone());
        let blocks = vec![json!({"type": "text", "text": text})];
        tokio::spawn(async move { hub.prompt_with(&t, blocks, "acpmux-inbox", true, opts).await });
        let accepted = rx.await.map_err(|_| RpcError::internal("the reply was refused"))?;
        Ok(
            json!({"sessionId": target.id, "promptId": prompt_id, "threadId": key, "accepted": accepted}),
        )
    }
}

/// The answer of an inbox message whose notice went in under a daemon that stopped before it
/// ended.
fn interrupted(prompt_id: &str) -> Value {
    json!({
        "stopReason": Value::Null,
        "_meta": {"acpmux": {"promptId": prompt_id, "inbox": true, "duplicate": true, "status": "interrupted"}},
    })
}

/// An `inbox_answered` record's notice and answer.
fn answered_record(msg: &Value) -> Option<(String, super::queue::Answer)> {
    let notice = msg.get("noticePromptId").and_then(Value::as_str)?.to_owned();
    if let Some(answer) = msg.get("answer") {
        return Some((notice, Ok(answer.clone())));
    }
    let error = serde_json::from_value::<RpcError>(msg.get("error")?.clone()).ok()?;
    Some((notice, Err(error)))
}

/// Keeps at most [`KEEP`] messages: the oldest read and noticed ones go first.
fn trim(inbox: &mut Inbox) {
    // A message a notice carries that has not gone in yet may be new again: never trimmed.
    let carried: std::collections::HashSet<String> = inbox
        .in_flight
        .iter()
        .map(|(_, ids)| ids)
        .chain(inbox.carrying.iter().map(|c| &c.ids))
        .flat_map(|ids| ids.iter().cloned())
        .collect();
    while inbox.items.len() > KEEP {
        let gone = |i: &Item| {
            i.read && i.noticed && i.answered.is_some() && !carried.contains(&i.prompt_id)
        };
        match inbox.items.iter().position(gone) {
            Some(i) => {
                let item = inbox.items.remove(i);
                inbox.trimmed.insert(item.prompt_id);
            }
            None => break,
        }
    }
}

#[path = "inbox_team_page.rs"]
mod team_page;

#[cfg(test)]
#[path = "inbox_tests.rs"]
mod tests;
