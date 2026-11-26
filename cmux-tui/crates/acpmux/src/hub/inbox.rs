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
//! far only a plain send is ([`plain_send`]), from this host or forwarded by a peer daemon or the
//! mesh relay: a team message, a correction under a supersede key, a steer-only send, a `cmux agent message`
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
//! it respawned without the tools, or before a restart's first spawn) carries each one whole. Nothing here waits on `meshRelay.teamMessaging`: an agent reads its inbox
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
//!   one, so a turn takes at most one per step. A prompt that waits is never held up by notices.
//!   FYIs alone steer in no sooner than [`FLUSH_MS`] after the oldest came: a message that is no
//!   FYI brings them sooner, in its notice, and a Stop's [`Inbox::due_now`] still lets them in
//!   at once. A coordinator, busy most of the day, took 204 of its 305 notices in 24 h as
//!   steers, most of them tool FYIs (2026-11-08). Results steer in no sooner than
//!   [`STEER_COALESCE_MS`] after the oldest of them came, so a burst is one steer; a block, a
//!   question or a message from the chat's parent or delegator ([`steers_at_once`]) brings
//!   every new message at once. Each steer re-ran the harness's prompt hooks (1-3 KB each), and
//!   3 results in 3 minutes went into one turn as 3 steers (2026-11-21). A turn that ends first
//!   leaves them to the idle chat's rules below;
//! - into the next such turn that starts, as a steer at its start, on the same terms;
//! - an idle chat: as ONE turn of its own, at once for messages the person's own turn held back
//!   ([`Inbox::held_by_person`]; FYIs alone are not held so, they wait for the flush as they
//!   would have in that turn), else [`WAKE_DEBOUNCE_MS`] after the oldest message that may
//!   wake it came (a burst is one turn). What may not wake it waits for its next turn, never a
//!   flush of its own (a cold prompt cache rewritten to carry FYIs), except a coordinator's held
//!   status, which goes [`FLUSH_MS`] after it came (`inbox_page_rule.rs`). A message that may wake it: a blocker (a block or a question,
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
//! leaves its messages new, so none is lost (a steer logged but never written leaves
//! `steer_withdrawn`, so neither the chat nor the log shows it went in); it is tried again no
//! sooner than [`REFUSED_RETRY_MS`], or when a turn starts or ends. A notice that went in logs its answer (an
//! `inbox_answered` record, an error too): a resend of one of its messages, before or after a
//! restart, and after [`trim`] let go of it ([`Inbox::trimmed`]), answers with it; a resend of
//! one withdrawn before any notice carried it answers withdrawn ([`Inbox::removed`]). A withdraw
//! of a message a notice carries that is not written yet waits for it (`inbox_settled`): unsent
//! if it did not go in, retracted if it did. A restart keeps the inbox (its records), a closed
//! chat's included, and what was new is noticed again.
//!
//! Deadlines: no held message waits forever ([`Item::due`], `prompt_class::due_at`). A block or a
//! question is due at once; a result (an action) within 15 minutes of coming; an FYI within 60.
//! The sender may tighten it (`acpmux send --within 5m`, `_meta.acpmux.within`, kept on the
//! inbox record's provenance), never loosen it. When the oldest new message's deadline comes, an
//! idle chat is woken (and a running turn that takes notices is steered) with ONE notice that
//! carries every new message, due or not: a quiet chat costs one turn per deadline at most. The
//! accept answer names `dueAt`; NOW reads overdue ones from `acpmux session inbox` (`overdue`).
//! Leo, 2026-11-25: "is there a timeout where it can always check again at some point, like a
//! promise of "i'll respond within x minutes since this isn't urgent"".
//!
//! The timer: one per session ([`Inbox::timer`]), for an idle chat's next wake or flush, or the
//! flush of FYIs alone that wait for a running turn. Stop condition: it wakes once, at its
//! deadline, and ends; it is armed only while a new message waits in an idle chat, or only FYIs
//! (or a refused steer's backoff) wait for a running turn that takes notices. Cleanup: every
//! arm aborts the one before, a turn's start and a delivery abort it (a turn's start reviews the
//! inbox again as its prompt is written, `inbox_prompt_written`, which arms it anew), a review
//! that finds nothing to time aborts it, closing the session aborts it, and it holds the hub and
//! the session weakly.

use super::*;
#[path = "inbox_admit.rs"]
mod admit;
#[path = "inbox_page_rule.rs"]
pub(super) mod page_rule;
#[path = "inbox_reader.rs"]
pub(super) mod reader;
#[path = "inbox_restore.rs"]
mod restore;
#[path = "inbox_surge.rs"]
mod surge;
#[path = "inbox_topic.rs"]
mod topics;
use crate::prompt_class::PromptClass;
use std::sync::Weak;
use std::sync::atomic::Ordering;
pub(super) use topics::topic as surge_topic;

/// The provenance kind of a notice.
pub const NOTICE_KIND: &str = "inbox_notice";

/// What every notice's prompt id starts with (`deliver_notice`).
const NOTICE_ID_PREFIX: &str = "inbox-notice-";
/// On a chat's first work's provenance (module docs): set by acpmux only, as no client's
/// provenance keeps a field it does not name (`prompt_provenance.rs`).
pub const FIRST_WORK: &str = "firstWork";
/// How long after the oldest waking message an idle chat is woken: a burst is one turn.
pub const WAKE_DEBOUNCE_MS: u64 = 2_000;
/// A notice the chat refused is tried again no sooner than this.
pub const REFUSED_RETRY_MS: u64 = 30_000;
/// How long a message that wakes no one waits in an idle chat, or FYIs alone wait for a running
/// turn, before a notice brings them anyway.
/// The minimum interval between turns started solely to carry FYIs. Keeping the
/// interval at fifteen minutes bounds a quiet coordinator to at most four
/// notice turns per hour while urgent classes still wake immediately.
pub const FLUSH_MS: u64 = 15 * 60 * 1000;
/// How long results wait to steer into a running turn after the oldest new one came, so a burst
/// goes in as ONE steer at a tool step instead of one each: every steer is a new user message,
/// which re-runs the harness's prompt hooks (1-3 KB of injected context each, measured
/// 2026-11-21: 3 results in 3 minutes interrupted one turn singly). A block, a
/// question, a message from the chat's parent or delegator ([`steers_at_once`]) and a Stop's
/// `due_now` bring the batch at once.
pub const STEER_COALESCE_MS: u64 = 2 * 60 * 1000;
/// A notice line shows this much of the newest message's first line, in characters.
const PREVIEW_CHARS: usize = 120;
/// A notice holds its messages whole when their text is this many bytes or less ([`render`]).
const WHOLE_BYTES: usize = 4 * 1024;
/// Past [`WHOLE_BYTES`], a thread's part still holds its newest message whole (`newest`) when that
/// message is this many bytes or less, so the transcript draws it at once instead of a first line
/// that grows into it when the thread is read ([`render`]).
const NEWEST_BYTES: usize = 8 * 1024;
/// The most the parts of one notice hold of newest messages past [`WHOLE_BYTES`], in bytes: the
/// threads past it draw their preview and read the rest, as before.
const NEWEST_TOTAL_BYTES: usize = 32 * 1024;
/// Messages a chat keeps in memory; the oldest read ones go first (the log keeps them all).
pub(super) const KEEP: usize = 500;
/// The client a notice goes under.
const CLIENT: &str = "acpmux";

/// One message in the inbox.
pub(super) struct Item {
    /// Archived for batch triage. An ordinary notice must never carry this item.
    pub(super) surge_held: bool,
    pub(super) prompt_id: String,
    /// The notice that carried it, once one went in: a resend answers with its outcome.
    pub(super) notice: Option<String>,
    /// That notice's answer, once it ended (an `inbox_answered` record): a resend's answer.
    pub(super) answered: Option<super::queue::Answer>,
    pub(super) thread: String,
    /// Its sender's name, and its session when it has one here (`sender_session`).
    pub(super) from: String,
    pub(super) from_session: Option<String>,
    /// The session that asked, as the daemon bound the send (`question_replies::asker_of`): the
    /// only one its reply goes back to. None for a sender no caller token proved.
    pub(super) asker: Option<String>,
    /// Additive, daemon-derived sender identity. Old records derive this on restore and are not
    /// rewritten.
    pub(super) sender: Value,
    pub(super) class: PromptClass,
    /// A report of work this chat gave (a lane's report, a task's result): it wakes the chat
    /// as its parent's action does.
    pub(super) report: bool,
    /// It waited for this machine to come back (`prompt_provenance::waited`): it wakes the chat
    /// rather than sit to a flush a parked machine never reaches.
    pub(super) waited: bool,
    pub(super) at: u64,
    /// The sender's own deadline (`acpmux send --within`), which tightens its class's
    /// ([`Item::due`]).
    pub(super) within: Option<u64>,
    pub(super) text: String,
    /// Machine-readable report context; kept out of the visible words.
    pub(super) details: Option<Value>,
    /// A tool's notice it is (`prompt_provenance::notice`): its `{sender, host?, severity, title,
    /// links?}`, so a notice of it and its thread still draw it as one.
    pub(super) tool_notice: Option<Value>,
    /// A fire notice that wakes the chat and never waits as an FYI: only with the surge preview
    /// on (`surge_inbox_on`); with it off a notice is its class alone, as before the surge inbox.
    pub(super) fire: bool,
    /// The page rule's verdict, in a chat on the coordinator list (`inbox_page_rule.rs`): it
    /// decides whether the item wakes the chat. None: not on the list, unreadable or restored,
    /// so it wakes as before the rule (fail open).
    pub(super) verdict: Option<page_rule::Verdict>,
    /// A notice told the agent of it (or carries it now).
    pub(super) noticed: bool,
    /// The agent read it (`inbox_thread` with `markRead`).
    pub(super) read: bool,
    /// The waiting `session/prompt` that sent it, answered by its notice.
    answer: Option<Waiter>,
    /// Its sender's caller waits for the reply and prints it (`PromptOptions::reply_reader`):
    /// `true` once that caller left. None for a send nobody reads the reply of (`--no-wait`, the
    /// outbox, a restored message): its notice says no one waits, and a question's reply goes
    /// back to its asker (`question_replies.rs`).
    pub(super) reader: Option<tokio::sync::watch::Receiver<bool>>,
}

#[cfg(test)]
impl Item {
    /// Message `prompt_id` from agent `from`, that a notice carries now.
    pub(super) fn carried(prompt_id: &str, from: &str, text: &str) -> Self {
        Self {
            surge_held: false,
            verdict: None,
            prompt_id: prompt_id.to_owned(),
            notice: None,
            answered: None,
            thread: format!("from:{from}"),
            from: from.to_owned(),
            from_session: None,
            asker: None,
            sender: crate::prompt_provenance::sender_record(None, None, None),
            class: PromptClass::Result,
            report: false,
            waited: false,
            at: now_ms(),
            within: None,
            text: text.to_owned(),
            details: None,
            tool_notice: None,
            fire: false,
            noticed: true,
            read: false,
            answer: None,
            reader: None,
        }
    }
}

/// The waiting `session/prompt` of an inbox message.
type Waiter = tokio::sync::watch::Sender<Option<super::queue::Answer>>;

impl Inbox {
    /// The surge row's needYou as last journaled.
    pub(super) fn surge_counts_need_you(&self) -> u64 {
        self.surge_counts.lock().unwrap_or_else(|e| e.into_inner()).need_you()
    }
}

/// A session's inbox (`Session::inbox`).
#[derive(Default)]
pub struct Inbox {
    /// The page rule's fold table (`inbox_page_rule.rs`): a program's repeated alarm text.
    pub(super) folds: page_rule::Folds,
    surge_rate: surge::SurgeRate,
    surge_counts: Arc<StdMutex<surge::Counts>>,
    pub(super) items: Vec<Item>,
    /// Replies to questions no caller waits for: due under the prompt that carries them until
    /// its turn is known, then sent to their askers when that turn ends (`question_replies.rs`).
    pub(super) replies_due: Vec<super::question_replies::ReplyDue>,
    /// The notice in flight: its prompt id and the messages it carries. None goes after it until
    /// it ends, or, a turn of its own, until its prompt is written to the agent.
    pub(super) in_flight: Option<(String, Vec<String>)>,
    /// The idle chat's wake timer, or a running turn's FYI flush or steer retry.
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
    /// The threads whose surge-held messages [`trim`] let go of. Those stay whole in the log
    /// (`persist_surge_event`), so a thread read (`inbox_thread_whole`) reads them from there.
    pub(super) held_evicted: std::collections::HashSet<String>,
    /// Woken when a notice is written or ends, or the chat closes: a withdraw waits on it for
    /// a notice that carries its message and is not written yet (`inbox_settled`).
    pub(super) settled: Arc<tokio::sync::Notify>,
    /// The prompt that holds the chat's first work ([`FirstWork`]) while it runs: another agent's
    /// message meanwhile is no first work.
    pub(super) first: Option<String>,
    /// The person's own turn held a notice back (module docs): its messages are due as a turn of
    /// their own once the chat is idle, whatever their class, unless all are FYIs. Cleared when a
    /// notice goes, or when the idle chat finds only FYIs new.
    pub(super) held_by_person: bool,
    /// A Stop kept a notice out of the turn it ended, or the turn's end answered it before the
    /// agent read it (`cancel.rs` module docs): its messages are due as a turn of their own once
    /// the chat is idle, whatever their class. Cleared when a notice goes.
    pub(super) due_now: bool,
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
        let mut inbox = session.inbox();
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

/// Whether a `session/prompt` is a plain send the inbox may take: an agent's `acpmux send`, the MCP
/// `send` tool, or either forwarded by a peer daemon or the mesh relay (the lane-gh broker's
/// relay reaches a lane VM's chat that way), with no supersede key, not steer-only, and no team
/// message. A team message, a correction under a supersede key and a steer-only send keep the
/// queue for now, as do the prompts acpmux makes itself (lane reports, task cards, a paused
/// pair's release), which never set `PromptOptions::inbox`.
///
/// A peer's forward kept the queue until 2026-11-21, so a message from another machine never met
/// the inbox's classes: each one woke an idle chat as a turn of its own, or, if it came while
/// the chat was busy, went in after that turn. Of 482 no-op wake turns in 48 h across the fleet
/// (a turn that made no tool call), about 84 were single forwards sent with no class
/// (cmuxterm-hq#15820).
/// In the inbox, an unclassified one is an FYI that waits for the next notice; a block or a
/// question still wakes the chat at once, and the session that started it or first gave it work
/// still sends a prompt of its own (`Hub::inbox_route`).
///
/// Nor a prompt whose caller gave its own provenance (`prompt_provenance::of`): a `cmux agent
/// message` the cmux daemon's pump delivers (`agents_chat_send`, the app's reply in place). The
/// cmux daemon keeps that message, its delivery receipt and its Stop hold, and the chat must show
/// it as that agent message: the app's reply in place answers its `user_message`
/// (`app_reply_fits`). In the inbox it became a notice, so a reply in place was refused, a send to
/// a chat that cannot run said delivered, and a send to an idle chat ran no turn.
pub(crate) fn plain_send(
    team: bool,
    supersede: bool,
    steer_only: bool,
    given_provenance: bool,
) -> bool {
    !team && !supersede && !steer_only && !given_provenance
}

/// Whether a provenance is a plain message from another agent: none (a sender that named
/// itself, or a connection that proved its session), `agent_message`, `session_message` or a
/// tool's `notice` (`prompt_provenance::notice`).
fn plain_kind(provenance: Option<&Value>) -> bool {
    match provenance.and_then(|p| p.get("kind")) {
        None => true,
        Some(kind) => matches!(
            kind.as_str(),
            Some("agent_message" | "session_message" | crate::prompt_provenance::NOTICE_KIND)
        ),
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
        let mut inbox = session.inbox();
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

/// The tool's notice a message's provenance carries (`prompt_provenance::notice`).
fn tool_notice_of(provenance: Option<&Value>) -> Option<Value> {
    provenance
        .filter(|p| crate::prompt_provenance::is_notice(Some(p)))
        .and_then(|p| p.get("notice"))
        .cloned()
}

/// A message's notice: its provenance's, else the one its text renders (`notice_read.rs`: relayed
/// by the lane-gh broker or a peer, or sent by an older client), so the chat draws and folds it as
/// the notice it is.
fn notice_of(provenance: Option<&Value>, text: &str) -> Option<Value> {
    tool_notice_of(provenance).or_else(|| crate::notice_read::read(text))
}

/// A notice's condition (`notice_read::condition_key`): its sender and its title past its counts.
fn notice_key(notice: &Value) -> Option<String> {
    let field = |k: &str| notice.get(k).and_then(Value::as_str);
    Some(crate::notice_read::condition_key(field("sender").unwrap_or_default(), field("title")?))
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
    let prefix = if let Some(sender) = sender.strip_prefix("declared:") {
        format!("declared:{sender}")
    } else {
        let sender = sender
            .strip_prefix("session:")
            .or_else(|| sender.strip_prefix("raw:"))
            .unwrap_or(sender);
        format!("from:{sender}")
    };
    match first_pr(text.lines().next().unwrap_or_default()) {
        Some(n) => format!("{prefix}/pr:{n}"),
        None => prefix,
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
    if let Some(name) = key.strip_prefix("declared:") {
        if let Some((_, n)) = name.rsplit_once("/pr:") {
            return format!("#{n} (self-declared, unauthenticated)");
        }
        return format!("{name} (self-declared, unauthenticated)");
    }
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

/// How a thread reads in the transcript: [`label`] without the agent's words for a self-declared
/// sender (its mark says that).
fn shown_label(key: &str) -> String {
    match key.strip_prefix("declared:") {
        Some(name) => match name.rsplit_once("/pr:") {
            Some((_, n)) => format!("#{n}"),
            None => "messages".to_owned(),
        },
        None => label(key),
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

/// A relayed sender's name, `MACHINE/SESSION` as the relay vouched for it
/// (`prompt_provenance::FROM_RELAY`).
fn relayed_name(sender: &Value) -> Option<String> {
    let relay = sender.get("relay").filter(|r| r.is_object())?;
    let machine = relay.get("machine").and_then(Value::as_str).filter(|m| !m.is_empty())?;
    Some(match relay.get("session").and_then(Value::as_str).filter(|s| !s.is_empty()) {
        Some(session) => format!("{machine}/{session}"),
        None => machine.to_owned(),
    })
}

/// A sender's name as the transcript draws it: the relayed or declared name alone. Whether it is
/// verified is the sender record's (`verification`), drawn as a mark beside the name, never words
/// in it (Leo, 2026-11-07: "Why does it say it's self-declared if we can just detect the thing?").
fn shown_sender(sender: &Value, fallback: &str) -> String {
    if let Some(name) = relayed_name(sender) {
        return name;
    }
    let label = sender.get("label").and_then(Value::as_str).filter(|v| !v.is_empty());
    let declared = sender.get("labelDeclared").and_then(Value::as_bool) == Some(true);
    match label {
        Some(label) if declared && fallback.is_empty() => label.to_owned(),
        Some(label) if declared && sender.get("authenticated") != Some(&Value::Bool(true)) => {
            label.to_owned()
        }
        _ => fallback.to_owned(),
    }
}

/// A sender's display name keeps a self-declared label visibly separate from a real session.
/// This is the agent's text (the notice, `inbox_read`); the transcript draws [`shown_sender`].
fn display_sender(sender: &Value, fallback: &str) -> String {
    let shown = display_sender_name(sender, fallback);
    match subagent_label(sender) {
        Some(sub) => format!("{shown}'s {sub}"),
        None => shown,
    }
}

fn display_sender_name(sender: &Value, fallback: &str) -> String {
    if let Some(name) = relayed_name(sender) {
        return name;
    }
    let label = sender.get("label").and_then(Value::as_str).filter(|v| !v.is_empty());
    let declared = sender.get("labelDeclared").and_then(Value::as_bool) == Some(true);
    let authenticated = sender.get("authenticated").and_then(Value::as_bool) == Some(true);
    // A name this host's sender token proved (`sender_token.rs`) is no self-declared label.
    let token = sender.get(crate::sender_token::VERIFIED_BY_KEY).and_then(Value::as_str)
        == Some(crate::sender_token::VERIFIED_BY);
    match (label, declared, authenticated) {
        (Some(label), true, false) if token => label.to_owned(),
        (Some(label), true, false) => format!("{label} (self-declared, unauthenticated)"),
        (Some(label), true, true) if fallback.is_empty() => label.to_owned(),
        (Some(label), true, true) => format!("{fallback} (label: {label})"),
        // A session with a given name reads by it, with the name it was known by
        // (`Mango · HOST/NAME`, `prompt_provenance::display_label`).
        _ => crate::prompt_provenance::display_label(
            sender.get("displayName").and_then(Value::as_str),
            fallback,
        ),
    }
}

fn thread_sender(provenance: Option<&Value>, sender: &str) -> String {
    let identity = crate::prompt_provenance::sender_record(
        provenance,
        sender_session(provenance).as_deref(),
        None,
    );
    if identity.get("authenticated") == Some(&Value::Bool(false))
        && identity.get("labelDeclared") == Some(&Value::Bool(true))
        && let Some(label) = identity.get("label").and_then(Value::as_str)
    {
        return format!("declared:{label}");
    }
    // Keep authenticated conversations keyed by the sender's stable display name.  The
    // stamped session id remains in the additive sender record and is used for routing replies,
    // but changing the thread key to that id would split existing `from:<name>` threads.
    if identity.get("authenticated") == Some(&Value::Bool(true)) {
        if sender.starts_with("declared:")
            || sender.starts_with("session:")
            || sender.starts_with("raw:")
        {
            return format!("session:{sender}");
        }
        return sender.to_owned();
    }
    if sender.starts_with("declared:")
        || sender.starts_with("session:")
        || sender.starts_with("raw:")
    {
        format!("raw:{sender}")
    } else {
        sender.to_owned()
    }
}

/// Re-key a historical bare sender thread in memory when its old provenance proves that the
/// name was only self-declared. The append-only event keeps its original thread id unchanged.
fn legacy_thread_key(provenance: Option<&Value>, from: &str, thread: String) -> String {
    let prefix = format!("from:{from}");
    let Some(suffix) = thread.strip_prefix(&prefix) else { return thread };
    let declared = thread_sender(provenance, from);
    declared.strip_prefix("declared:").map(|_| format!("{declared}{suffix}")).unwrap_or(thread)
}

/// A client may retain the old `from:<label>` key after a declared-only thread was re-keyed in
/// memory. Keep that handle readable without merging it with an authenticated session thread.
fn thread_matches(item: &Item, requested: &str, allow_declared_fallback: bool) -> bool {
    item.thread == requested
        || (allow_declared_fallback
            && item
                .thread
                .strip_prefix("declared:")
                .is_some_and(|rest| requested == format!("from:{rest}")))
}

/// The receiver's sender thread becomes the reply author's sender thread on the other inbox.
/// Keep the peer's display name in the key so replies join the same stable conversation after
/// sender provenance gains a session id.
fn reply_thread_key(thread: &str, sender_name: &str) -> String {
    match thread.strip_prefix("from:") {
        Some(rest) => match rest.rsplit_once("/pr:") {
            Some((_, n)) => format!("from:{sender_name}/pr:{n}"),
            None => format!("from:{sender_name}"),
        },
        None => thread.to_owned(),
    }
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

/// Unclassified notices are informational and can wait for the FYI flush window.
fn default_notice_class(class: Option<PromptClass>) -> PromptClass {
    class.unwrap_or(PromptClass::Fyi)
}

/// The first line of `text`, cut to [`PREVIEW_CHARS`]: of the message inside a relay's label
/// ([`relay_body`]), never the label's own words.
fn preview(text: &str) -> String {
    let line = relay_body(text).lines().find(|l| !l.trim().is_empty()).unwrap_or_default().trim();
    let cut: String = line.chars().take(PREVIEW_CHARS).collect();
    if cut.len() < line.len() { format!("{cut}…") } else { cut }
}

/// The message inside the lane-gh broker's label (`[message N from VM/LANE (an agent, not Leo),
/// relayed by the lane-gh broker; its text ends at "[end of message N]"]`, the text, then
/// `[end of message N]`), else `text` as written. The agent still gets the label (it keeps a lane's
/// words from reading as Leo's); only what the transcript previews leaves it out. The web reads the
/// same form (webviews relayEnvelope.ts).
pub(crate) fn relay_body(text: &str) -> &str {
    let trimmed = text.trim();
    let Some((head, rest)) = trimmed.split_once('\n') else { return text };
    let head = head.trim_end();
    let Some(nonce) = head.strip_prefix("[message ").and_then(|h| h.split(' ').next()) else {
        return text;
    };
    let nonce_ok = (4..=64).contains(&nonce.len())
        && nonce.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
    let ends = format!("; its text ends at \"[end of message {nonce}]\"]");
    if !nonce_ok || !head.contains(" (an agent, not Leo), relayed by ") || !head.ends_with(&ends) {
        return text;
    }
    // The closing marker is the last line, a line of its own; one inside the text never ends it.
    match rest.strip_suffix(format!("[end of message {nonce}]").as_str()) {
        Some(body) if body.is_empty() || body.ends_with('\n') => body.trim(),
        _ => text,
    }
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
/// sender's session, and the messages whole when the notice holds them; past that, the newest one
/// whole (`newest`) while it is [`NEWEST_BYTES`] or less and the notice's newest ones stay within
/// [`NEWEST_TOTAL_BYTES`]. Only the parts carry it: the agent's text keeps its previews.
#[cfg(test)]
pub(super) fn render(items: &[&Item]) -> (String, Value) {
    render_read(items, &reader::Summaries::new())
}

/// [`render`] with the inbox reader's `summaries` (`inbox_reader.rs`), by message id: a thread
/// with no blocker whose newest message has one shows it in place of that message's preview, and
/// such threads go by how much the reader says they matter to the chat's goal, then the newest
/// first. A blocker's thread, and a notice that holds every message whole, read as before.
pub(super) fn render_read(items: &[&Item], summaries: &reader::Summaries) -> (String, Value) {
    let mut threads: Vec<(&str, Vec<&Item>)> = Vec::new();
    for item in items {
        match threads.iter_mut().find(|(k, _)| *k == item.thread) {
            Some((_, list)) => list.push(item),
            None => threads.push((&item.thread, vec![item])),
        }
    }
    // A folded repeat of a program's page (`inbox_page_rule.rs`) is no blocker again.
    let blocker = |list: &[&Item]| list.iter().any(|i| i.class.urgent() && !folded(i));
    let newest = |list: &[&Item]| list.iter().map(|i| i.at).max().unwrap_or(0);
    let whole = items.iter().map(|i| i.text.len()).sum::<usize>() <= WHOLE_BYTES;
    let summary = |list: &[&Item]| {
        let last = list.iter().max_by_key(|i| i.at)?;
        summaries.get(&last.prompt_id).filter(|_| !whole && !blocker(list))
    };
    // Unread by the reader: in the middle, as background is not noise.
    let score = |list: &[&Item]| summary(list).map_or(1, |s| s.score);
    threads.sort_by_key(|(_, list)| {
        (!blocker(list), std::cmp::Reverse(score(list)), std::cmp::Reverse(newest(list)))
    });
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
    let mut newest_left = NEWEST_TOTAL_BYTES;
    for (key, list) in &threads {
        let last = list.iter().max_by_key(|i| i.at).copied();
        // The agent's text names a self-declared sender so; the transcript's parts name it alone.
        let mut from: Vec<String> = Vec::new();
        let mut names: Vec<String> = Vec::new();
        for i in list {
            let shown = display_sender(&i.sender, &i.from);
            if !from.contains(&shown) {
                from.push(shown);
            }
            let name = shown_sender(&i.sender, &i.from);
            if !names.contains(&name) {
                names.push(name);
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
                let shown = display_sender(&item.sender, &item.from);
                let lead = if list.len() > 1 { format!("{shown}: ") } else { String::new() };
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
            let line = match summary(list) {
                // Marked, so the agent never takes the reader's words for the sender's.
                Some(s) => format!("(summary) {}", s.line),
                None => last.map(|i| preview(&i.text)).unwrap_or_default(),
            };
            text.push_str(&format!("\n- {head}: {line} (thread {key})"));
        }
        let ids: Vec<&str> = list.iter().map(|i| i.prompt_id.as_str()).collect();
        let mut part = json!({
            "threadId": key, "label": shown_label(key), "new": list.len(), "from": names,
            "promptIds": ids, "blocker": blocker(list),
            "preview": last.map(|i| preview(&i.text)), "newestAt": newest(list),
        });
        if let Some(last) = last.filter(|item| item.sender.is_object()) {
            part.set("sender", last.sender.clone());
        }
        if let Some(s) = summary(list) {
            part.set("summary", json!(s.line));
            part.set("relevance", json!(s.score));
        }
        if let Some(session) = last.and_then(|i| i.from_session.as_deref()) {
            part.set("fromSession", json!(session));
        }
        // The newest notice's compact row (Leo, 2026-11-25, on a notice drawn under its relay host
        // with its raw head: "how can we improve this?"): its detector, severity and title, and how
        // often its condition came in this thread (`notice_read::condition_key`), "×3, last 09:40Z".
        if let Some((last, notice)) = last.and_then(|i| Some((i, i.tool_notice.as_ref()?))) {
            let key = notice_key(notice);
            let same: Vec<&&Item> = list
                .iter()
                .filter(|i| i.tool_notice.as_ref().and_then(notice_key) == key)
                .collect();
            let mut row = json!({
                "sender": notice.get("sender"), "severity": notice.get("severity"),
                "title": notice.get("title"), "repeats": same.len(),
                "lastAt": same.iter().map(|i| i.at).max().unwrap_or(last.at),
            });
            if let Some(host) = notice.get("host") {
                row.set("host", host.clone());
            }
            part.set("notice", row);
        }
        // A thread of tools' notices says its loudest severity, so a fold of it never hides a fire.
        if let Some(severity) = loudest(list) {
            part.set("severity", json!(severity));
        }
        if whole {
            let messages: Vec<Value> = list
                .iter()
                .map(|i| {
                    let shown = shown_sender(&i.sender, &i.from);
                    let mut m =
                        json!({"promptId": i.prompt_id, "from": shown, "at": i.at, "text": i.text});
                    if i.sender.is_object() {
                        m.set("sender", i.sender.clone());
                    }
                    if let Some(notice) = &i.tool_notice {
                        m.set("notice", notice.clone());
                    }
                    m
                })
                .collect();
            part.set("messages", json!(messages));
        } else if let Some(last) = last.filter(|i| i.text.len() <= NEWEST_BYTES.min(newest_left)) {
            newest_left -= last.text.len();
            part.set("newest", json!(last.text));
        }
        parts.push(part);
    }
    (text, json!(parts))
}

/// The loudest severity of the tools' notices among `items` (`prompt_provenance::NOTICE_SEVERITIES`).
fn loudest(items: &[&Item]) -> Option<&'static str> {
    let rank = |i: &&Item| {
        let severity = i.tool_notice.as_ref()?.get("severity")?.as_str()?;
        crate::prompt_provenance::NOTICE_SEVERITIES.iter().position(|s| *s == severity)
    };
    let top = items.iter().filter_map(rank).max()?;
    crate::prompt_provenance::NOTICE_SEVERITIES.get(top).copied()
}

impl Item {
    /// When the daemon wakes an idle receiver to deliver it (module docs, "Deadlines").
    pub(super) fn due(&self) -> u64 {
        crate::prompt_class::due_at(self.class, self.at, self.within)
    }
}

/// A message's text as the notice quotes it: without the blank lines around it, and with the first
/// line's indent kept (an indented code block stays one).
fn body(text: &str) -> &str {
    text.trim_start_matches(['\n', '\r']).trim_end()
}

/// Whether `item` may wake the idle chat of `meta`.
fn wakes(meta: &SessionMeta, item: &Item) -> bool {
    match item.verdict {
        Some(verdict) => verdict == page_rule::Verdict::Page,
        None => {
            item.fire
                || wakes_as(
                    meta,
                    item.class,
                    item.report,
                    item.waited,
                    item.from_session.as_deref(),
                )
        }
    }
}

/// The soonest deadline of `new` messages ([`Item::due`]); `u64::MAX` when there are none. A
/// folded repeat of a page that already went in (`inbox_page_rule.rs`) has none: it goes with
/// the next notice.
fn earliest_due(new: &[&Item]) -> u64 {
    new.iter().filter(|i| !folded(i)).map(|i| i.due()).min().unwrap_or(u64::MAX)
}

/// Whether `item` is a folded repeat of a program's page (`inbox_page_rule.rs`): it starts no
/// flush of its own and goes with the next notice.
/// A session's held-message deadlines for its `ls` row: how many new messages are past their
/// deadline, and the soonest one's (module docs, "Deadlines"). NOW reads `inboxOverdue` from
/// `acpmux ls --live --fields` in one call and counts each such session red.
pub(super) fn deadline_row(session: &Session) -> (usize, Option<u64>) {
    deadline_counts(&session.inbox().items, now_ms())
}

fn deadline_counts(items: &[Item], now: u64) -> (usize, Option<u64>) {
    let mut overdue = 0;
    let mut due_at: Option<u64> = None;
    for item in items.iter().filter(|i| !i.noticed && !folded(i)) {
        let due = item.due();
        if due < now {
            overdue += 1;
        }
        due_at = Some(due_at.map_or(due, |d| d.min(due)));
    }
    (overdue, due_at)
}

fn folded(item: &Item) -> bool {
    item.verdict == Some(page_rule::Verdict::Fold)
}

fn fire_notice(notice: Option<&Value>) -> bool {
    notice.and_then(|n| n.get("severity")).and_then(Value::as_str) == Some("fire")
}

fn ordinary_fyi(item: &Item) -> bool {
    item.class == PromptClass::Fyi && !item.fire && item.verdict != Some(page_rule::Verdict::Page)
}

/// [`wakes`] for a message of `class` from session `from` not in the inbox yet; `report` is a
/// report of work this chat gave, `waited` a message that waited for this machine
/// (`prompt_provenance::waited`). A waited message wakes the chat whatever its class, an FYI
/// too: an idle chat takes no flush turn for what wakes nobody (#55196), so a message sent while
/// the hub was down (an unclassed one files as an FYI) would otherwise never run.
fn wakes_as(
    meta: &SessionMeta,
    class: PromptClass,
    report: bool,
    waited: bool,
    from: Option<&str>,
) -> bool {
    match class {
        PromptClass::Block | PromptClass::Question => true,
        PromptClass::Fyi => waited,
        PromptClass::Result => meta.turn_count == 0 || report || waited || controls(meta, from),
    }
}

/// Whether `item` steers into a running turn at once, bringing every new message with it: a
/// blocker (a block or a question), or a message from the chat's parent or delegator, which
/// directs the work the turn does, or a fire notice. Any other result waits [`STEER_COALESCE_MS`]
/// for others to join it; an ordinary FYI waits for its flush.
fn steers_at_once(meta: &SessionMeta, item: &Item) -> bool {
    match item.class {
        PromptClass::Block | PromptClass::Question => true,
        PromptClass::Fyi => item.fire,
        PromptClass::Result => controls(meta, item.from_session.as_deref()),
    }
}

/// Whether session `from` started the chat of `meta` (its lineage parent) or first gave it work
/// (its delegator): its message is the next step of that work.
fn controls(meta: &SessionMeta, from: Option<&str>) -> bool {
    let parent = meta.lineage.as_ref().map(|l| l.parent.as_str());
    from.is_some() && (from == parent || from == meta.delegator.as_deref())
}

/// Whether a message of `class` that no class or sender of its own wakes would sit in the inbox
/// until a flush ([`FLUSH_MS`]): nothing new there wakes it or is due now, and the chat is idle
/// (or runs a turn that takes no notice and is not the person's, whose end would bring it), or
/// it is an FYI and only FYIs are new, which wait for the flush in any chat (`inbox_review`).
fn would_strand(session: &Session, inbox: &Inbox, meta: &SessionMeta, class: PromptClass) -> bool {
    // Before the first work's hold: FYIs alone wait for the flush after its turn too.
    if fyis_alone_wait(inbox, class) {
        return true;
    }
    if inbox.due_now || inbox.held_by_person || inbox.first.is_some() {
        return false;
    }
    if inbox.items.iter().any(|i| !i.noticed && wakes(meta, i)) {
        return false;
    }
    match session.turn() {
        None => true,
        Some(turn) => !turn.persons && !session.steering.load(Ordering::SeqCst),
    }
}

/// Whether an FYI (`class`) would wait for the flush whatever the chat does next: only FYIs are
/// new and no Stop made them due now (`inbox_review`). A first work's turn or a cut turn's
/// continuation brings them no sooner.
fn fyis_alone_wait(inbox: &Inbox, class: PromptClass) -> bool {
    class == PromptClass::Fyi
        && !inbox.due_now
        && inbox.items.iter().filter(|i| !i.noticed).all(ordinary_fyi)
}

/// The refusal of a waiting send whose message the receiver's inbox would hold without waking it
/// (`PromptOptions::wake_or_fail`). Nothing was delivered. Exit 1 at the CLI, never a hang: the
/// round-2 eval's `send --wait --timeout 300` waited all 300 s for an idle receiver.
pub(super) fn not_woken(receiver: &str, sender: &str, class: PromptClass) -> RpcError {
    let message = match class {
        PromptClass::Fyi => format!(
            "send.not_woken: an fyi from {sender} neither wakes {receiver} nor interrupts its \
             turn: it waits for its next notice (at the latest 60 minutes on, its deadline). \
             Nothing was delivered. Send it again with --class question to have it read now, or with \
             --no-wait to leave it in its inbox."
        ),
        _ => format!(
            "send.not_woken: {receiver} is idle, and a result or action from {sender} does not \
             wake it (only a question or blocker does, or a message from the session that started \
             it or first gave it work). Nothing was delivered. Send it again with --class question \
             to wake it, or with --no-wait to leave it in its inbox (delivered within 15 minutes)."
        ),
    };
    RpcError::new(-32000, message)
        .with_data(json!({"reason": "send.not_woken", "retryable": false, "receiver": receiver}))
}

/// Whether a turn comes for the idle chat without anyone sending more: its inbox holds a message
/// that wakes it, a notice of its own goes in now, or a first work holds it. A waiter for the
/// chat's turn end does not take it for done meanwhile (`server/wait.rs`): a `wait` right after a
/// `send --no-wait` read the old idle state (round-2 eval, A4).
pub(super) fn turn_coming(session: &Session) -> bool {
    if session.turn().is_some() || session.stop_hold.load(Ordering::SeqCst) != 0 {
        return false;
    }
    let meta = session.meta();
    if meta.status == SessionStatus::Closed {
        return false;
    }
    let inbox = session.inbox();
    inbox.in_flight.is_some()
        || inbox.first.is_some()
        || ((inbox.held_by_person || inbox.due_now) && inbox.items.iter().any(|i| !i.noticed))
        || inbox.items.iter().any(|i| !i.noticed && wakes(&meta, i))
}

/// A sending subagent as a notice names it, "general-purpose subagent a0a68e7a"
/// (`prompt_provenance::FROM_SUBAGENT`, kept on the sender record as `subagent`).
fn subagent_label(sender: &Value) -> Option<String> {
    let sub = sender.get("subagent")?;
    let id = sub.get("id").and_then(Value::as_str)?;
    let kind = sub.get("type").and_then(Value::as_str).unwrap_or("subagent");
    Some(format!("{kind} subagent {}", id.chars().take(8).collect::<String>()))
}

/// Whether `item`'s sender waits for the reply now: its caller reads it
/// (`PromptOptions::reply_reader`) and is still connected. An open request alone is no reader:
/// the outbox's delivery of a `--no-wait` send keeps one open (bench round 4, A5).
pub(super) fn reader_waits(item: &Item) -> bool {
    item.answer.as_ref().is_some_and(|tx| tx.receiver_count() > 0)
        && item.reader.as_ref().is_some_and(|ended| !*ended.borrow())
}

/// Whether the reply to `item` goes back to its asker when the turn ends
/// (`question_replies.rs`): a question or a block from a session here that no caller waits for.
pub(super) fn reply_goes_back(item: &Item) -> bool {
    asks_a_session(item) && !reader_waits(item)
}

/// A question or a block from a session here the daemon bound the send to (`Item::asker`), not
/// a report.
fn asks_a_session(item: &Item) -> bool {
    matches!(item.class, PromptClass::Question | PromptClass::Block)
        && item.asker.is_some()
        && !item.from.is_empty()
        && !item.report
}

/// The line a notice ends with that says how its senders get an answer, or None when none can:
/// a sender that waits gets this turn's reply; a question nobody waits for gets it too, sent back
/// when the turn ends; another session, `inbox_reply` or `acpmux send`; a subagent only the reply
/// to its own send. Without it the round-2 eval's receiver tried its harness's own SendMessage,
/// failed, and answered with apologies.
fn reply_hint(items: &[&Item]) -> Option<String> {
    let mut waiting: Vec<String> = Vec::new();
    let mut sent_back: Vec<String> = Vec::new();
    let mut later: Vec<String> = Vec::new();
    let mut leads: Vec<String> = Vec::new();
    fn add(list: &mut Vec<String>, name: String) {
        if !list.contains(&name) {
            list.push(name);
        }
    }
    for item in items {
        let session = item.from_session.is_some() && !item.from.is_empty();
        let sub = subagent_label(&item.sender);
        let shown = || match &sub {
            Some(sub) => format!("{}'s {sub}", item.from),
            None => display_sender(&item.sender, &item.from),
        };
        if reader_waits(item) {
            add(&mut waiting, shown());
        } else if reply_goes_back(item) {
            add(&mut sent_back, shown());
        } else if session && sub.is_none() {
            add(&mut later, item.from.clone());
        }
        if session && sub.is_some() {
            add(&mut leads, item.from.clone());
        }
    }
    let mut parts = Vec::new();
    if !waiting.is_empty() {
        parts.push(format!(
            "Your reply to this turn goes back to {}, waiting for it.",
            waiting.join(", ")
        ));
    }
    if !sent_back.is_empty() {
        parts.push(format!(
            "End your turn with your answer: acpmux sends this turn's reply to {} when it ends; \
             do not send it yourself as well.",
            sent_back.join(", ")
        ));
    }
    for name in &later {
        parts.push(format!(
            "To answer {name}, inbox_reply or the send tool (to: \"{name}\"); `acpmux send \
             {name}` in a shell only without them."
        ));
    }
    for lead in &leads {
        parts.push(format!(
            "A subagent reads only the reply to its own send; the send tool (to: \"{lead}\") \
             reaches {lead} itself."
        ));
    }
    (!parts.is_empty()).then(|| {
        format!("Reply with acpmux, not your harness's own messaging: {}", parts.join(" "))
    })
}

/// Whether the person's (or any) prompt waits in the queue: no notice steers into the running
/// turn then, so it is never held up behind them. One a failed turn holds or that waits for the
/// owner (`QueuedPrompt::aside`) runs nothing, so it holds no notice back.
fn prompt_waits(session: &Session) -> bool {
    session.queue.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|q| !q.aside())
}

/// Whether one of the person's prompts waits in the queue (not held, no agent's message): no other
/// agent's steer goes into the running turn then (`turns.rs`), so the turn can end for it.
/// Other agents' messages waiting do not hold one: they never held each other up.
pub(super) fn persons_prompt_waits(session: &Session) -> bool {
    let queue = session.queue.lock().unwrap_or_else(|e| e.into_inner());
    queue.iter().any(|q| !q.aside() && q.run.agent.is_none())
}

/// Whether a chat's first work waits in its queue ([`FIRST_WORK`] on its provenance), as one a
/// person's prompt went ahead of does, and one a restart rebuilt with no hold of its own.
fn first_work_waits(session: &Session) -> bool {
    let queue = session.queue.lock().unwrap_or_else(|e| e.into_inner());
    queue.iter().any(|q| !q.aside() && is_first_work(q.run.provenance.as_ref()))
}

/// Whether a prompt is the person's own (module docs): no other agent's message, and none of
/// acpmux's own prompts (a notice, a digest, the turn cap's notice, a subagent's retry, a cut
/// turn's continuation, the cache compaction), whose turns take notices and steers as before.
pub(super) fn persons_prompt(agent: Option<&str>, provenance: Option<&Value>) -> bool {
    let kind = provenance.and_then(|p| p.get("kind")).and_then(Value::as_str);
    let auto_resume = matches!(
        kind,
        Some("auto_resume" | super::idle::cache_compact::KIND | super::cold_wake::KIND)
    );
    agent.is_none()
        && !auto_resume
        && !is_notice(provenance)
        && !super::digest::inbox_digest::is_digest(provenance)
        && !super::turn_cap::is_notice(provenance)
        && !super::subagent_retry::is_retry(provenance)
        && !is_subagent_resume(provenance)
}

/// Whether a prompt is the Resume of a stopped subagent (`subagent_resume.rs`): acpmux's own ask
/// of the chat's agent, never the person's words.
fn is_subagent_resume(provenance: Option<&Value>) -> bool {
    provenance.and_then(|p| p.get("kind")).and_then(Value::as_str)
        == Some(super::subagent_resume::PROVENANCE_KIND)
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
    /// Sends the notice of every new message, as a steer or (`steer` false) a turn of its own,
    /// and answers their waiting `session/prompt`s with how it went in.
    fn deliver_notice(self: &Arc<Self>, session: &Arc<Session>, steer: bool) {
        let notice_id = format!("{NOTICE_ID_PREFIX}{}", uuid::Uuid::now_v7());
        let (text, whole, parts, ids, reads) = {
            let mut inbox = session.inbox();
            if inbox.in_flight.is_some() {
                return;
            }
            if inbox.items.iter().all(|i| i.noticed) {
                return;
            }
            // The reader's summaries that are cached (`inbox_reader.rs`): the notice never waits
            // for one. `reads` are the ones no read started for yet (a message from before a
            // restart), started once the lock is let go.
            let (summaries, reads) = {
                let new: Vec<&Item> = inbox.items.iter().filter(|i| !i.noticed).collect();
                reader::lookup(&session.id, &new)
            };
            // The wake timer is done: this notice carries what it waited for.
            if let Some(timer) = inbox.timer.take() {
                timer.abort();
            }
            inbox.held_by_person = false;
            inbox.due_now = false;
            let new: Vec<&Item> = inbox.items.iter().filter(|i| !i.noticed).collect();
            let started = std::time::Instant::now();
            let (mut text, parts) = render_read(&new, &summaries);
            if !summaries.is_empty() {
                let us = u64::try_from(started.elapsed().as_micros()).unwrap_or(u64::MAX);
                tracing::debug!(session = %session.id, summaries = summaries.len(), us, "inbox notice rendered");
            }
            let mut whole = team_page::whole_notice(&new);
            if let Some(hint) = reply_hint(&new) {
                for notice in [&mut text, &mut whole] {
                    notice.push('\n');
                    notice.push_str(&hint);
                }
            }
            let ids: Vec<String> = new.iter().map(|i| i.prompt_id.clone()).collect();
            let mut waiters = Vec::new();
            for item in inbox.items.iter_mut().filter(|i| !i.noticed) {
                item.noticed = true;
                if let Some(answer) = item.answer.take() {
                    waiters.push((item.prompt_id.clone(), answer));
                }
            }
            // A question nobody may wait for: the turn this notice reaches answers its asker,
            // unless its caller reads the reply on the send then (`question_replies.rs`).
            let due: Vec<_> = inbox
                .items
                .iter()
                .filter(|i| ids.contains(&i.prompt_id) && asks_a_session(i))
                .filter_map(|i| {
                    let sub = i.sender.get("subagent").filter(|s| s.is_object()).cloned();
                    let mut due = super::question_replies::ReplyDue::pending(
                        &notice_id,
                        i.asker.clone()?,
                        sub,
                    );
                    due.reader = i.reader.clone();
                    Some(due)
                })
                .collect();
            for d in due {
                super::question_replies::keep_due(&mut inbox, d);
            }
            inbox.in_flight = Some((notice_id.clone(), ids.clone()));
            let carry = Carry { notice: notice_id.clone(), ids: ids.clone(), steer, waiters };
            inbox.carrying.push(carry);
            (text, whole, parts, ids, reads)
        };
        self.inbox_read_jobs(session, reads);
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
            let mut inbox = session.inbox();
            if inbox.in_flight.as_ref().is_some_and(|(id, _)| id == notice_id) {
                inbox.in_flight = None;
            }
            let at = inbox.written.iter().position(|id| id == notice_id);
            let went_in = at.map(|i| inbox.written.remove(i)).is_some();
            let at = inbox.carrying.iter().position(|c| c.notice == notice_id);
            let carry = at.map(|i| inbox.carrying.remove(i));
            let waiters = carry.map(|c| c.waiters).unwrap_or_default();
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
            } else if super::steer_end::is_stopped_steer_refused(&result) {
                // A Stop kept it out of its turn, or took it back unread: no refusal of the agent's,
                // so no backoff; it goes in as the next turn (`inbox_review`).
                inbox.due_now = true;
                for item in inbox.items.iter_mut().filter(|i| ids.contains(&i.prompt_id)) {
                    item.noticed = false;
                }
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
        // into a turn past its cap: that turn gets the cap's notice (`turn_cap.rs`), unless they
        // are FYIs alone, which end no turn sooner.
        if answered.is_none() && !ids.is_empty() && !super::queue::closing(session) {
            let fyis_only = {
                let inbox = session.inbox();
                let mut carried = inbox.items.iter().filter(|i| ids.contains(&i.prompt_id));
                carried.all(|i| i.class == PromptClass::Fyi)
            };
            if !fyis_only {
                self.turn_cap_recheck(session);
            }
        }
        // Its questions that reached no turn get no reply (`question_replies.rs`).
        self.question_replies_settled(session, notice_id, answered.is_some());
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

    /// A notice's own turn that a restart adopted ended (`hosts.rs` `recover_work`): the
    /// messages it carried get the turn's answer, and the log says so (`inbox_answered`), as
    /// `notice_done` writes it for a notice this daemon started. A sender's resend of one of them
    /// is answered from that record (`logged_inbox_answer`); without it, the resend answered
    /// "interrupted" for a message its agent had read and answered. Nothing for a turn that was
    /// no notice's, or a notice answered already.
    pub(super) fn recovered_notice_done(
        &self,
        session: &Arc<Session>,
        notice_id: &str,
        result: &super::queue::Answer,
    ) {
        // Every notice's prompt id has the prefix: another turn's end reads no log.
        if !notice_id.starts_with(NOTICE_ID_PREFIX) {
            return;
        }
        let (mut ids, mut answered) = (None::<Vec<String>>, false);
        let kinds = ["inbox_noticed", "inbox_answered"];
        let scanned = self.scan_for_rebuild(session, &kinds, &mut |e: EventRecord| {
            if e.dir == "mux"
                && e.msg.get("noticePromptId").and_then(Value::as_str) == Some(notice_id)
            {
                if e.kind == "inbox_answered" {
                    answered = true;
                } else {
                    let carried = e.msg.get("promptIds").and_then(Value::as_array);
                    let carried = carried.into_iter().flatten().filter_map(Value::as_str);
                    ids = Some(carried.map(str::to_owned).collect());
                }
            }
            true
        });
        let Some(ids) = ids.filter(|ids| scanned.is_ok() && !answered && !ids.is_empty()) else {
            return;
        };
        let answer = if super::queue::closing(session) {
            Err(super::queue::closing_error())
        } else {
            result.clone()
        };
        {
            let mut inbox = session.inbox();
            for item in inbox.items.iter_mut().filter(|i| ids.contains(&i.prompt_id)) {
                item.answered = Some(answer.clone());
            }
            inbox.settled.notify_waiters();
        }
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
        self.cold_batch_turn_started(session);
        let persons = persons_turn(session);
        let mut inbox = session.inbox();
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
            let mut inbox = session.inbox();
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

    /// Notice `notice_id`, written as a steer, was taken back by a Stop before the agent read it
    /// (`steer_end.rs` `steer_turn`): it did not go in. Its messages are no notice's now, and the
    /// log says so (`inbox_returned`), so a restart finds them new too; `notice_done` makes them
    /// new again.
    pub(super) fn inbox_notice_unwritten(&self, session: &Arc<Session>, notice_id: &str) {
        let ids: Vec<String> = {
            let mut inbox = session.inbox();
            let Some(at) = inbox.written.iter().position(|id| id == notice_id) else { return };
            inbox.written.remove(at);
            let mut ids = Vec::new();
            for item in inbox.items.iter_mut().filter(|i| i.notice.as_deref() == Some(notice_id)) {
                item.notice = None;
                ids.push(item.prompt_id.clone());
            }
            ids
        };
        let msg = json!({"noticePromptId": notice_id, "promptIds": ids, "reason": "stopped"});
        self.append(session, "mux", "inbox_returned", msg);
    }

    /// A turn ended (`finish_turn`, `fail_unstarted_turn`): a refusal during it no longer holds
    /// the next try back.
    /// `turn_id` and `turn` name the turn that ended; `started`: its agent got its prompt.
    pub(super) fn inbox_turn_ended(
        self: &Arc<Self>,
        session: &Arc<Session>,
        turn_id: &str,
        turn: u64,
        started: bool,
    ) {
        session.inbox().refused_at = 0;
        self.question_replies_turn_ended(session, turn_id, turn, started);
        self.inbox_review(session);
    }

    /// A closed chat's inbox: its timer stops and its waiting senders are answered.
    pub(super) fn inbox_closed(&self, session: &Session) {
        self.disarm_inbox(session);
        let mut inbox = session.inbox();
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
        let timer = session.inbox().timer.take();
        if let Some(timer) = timer {
            timer.abort();
        }
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
            let inbox = session.inbox();
            let allow_declared_fallback = thread.starts_with("from:")
                && !inbox.items.iter().any(|item| item.thread == thread);
            let newest = inbox
                .items
                .iter()
                .rev()
                .filter(|i| thread_matches(i, thread, allow_declared_fallback));
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
        let key = reply_thread_key(thread, &name);
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
    if inbox.items.len() <= KEEP {
        return;
    }
    // A message a notice carries that has not gone in yet may be new again: never trimmed.
    let carried: std::collections::HashSet<String> = inbox
        .in_flight
        .iter()
        .map(|(_, ids)| ids)
        .chain(inbox.carrying.iter().map(|c| &c.ids))
        .flat_map(|ids| ids.iter().cloned())
        .collect();
    let gone = |i: &Item| {
        i.surge_held
            || (i.read && i.noticed && i.answered.is_some() && !carried.contains(&i.prompt_id))
    };
    // The oldest `excess` messages that may go, in one pass. One `Vec::remove` each moved every
    // later message, so restoring a long inbox cost its length squared.
    let mut excess = inbox.items.len() - KEEP;
    let items = std::mem::take(&mut inbox.items);
    let mut kept = Vec::with_capacity(items.len() - excess);
    for item in items {
        if excess > 0 && gone(&item) {
            excess -= 1;
            // The archive reader and resend ledger still resolve an evicted held post.
            if item.surge_held {
                inbox.held_evicted.insert(item.thread);
            } else {
                inbox.trimmed.insert(item.prompt_id);
            }
        } else {
            kept.push(item);
        }
    }
    inbox.items = kept;
}

#[path = "inbox_team_page.rs"]
mod team_page;

#[cfg(test)]
#[path = "inbox_tests.rs"]
mod tests;

/// The kinds a resent inbox message's answer is read from (`Hub::logged_inbox_answer`): each is in
/// `store` `KEYED_KINDS`, so the read takes the chat's held heads (a test keeps them there).
pub(crate) const INBOX_ANSWER_KINDS: &[&str] =
    &["inbox", "inbox_noticed", "inbox_answered", "inbox_removed"];
