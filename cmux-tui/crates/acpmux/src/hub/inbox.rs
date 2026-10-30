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
//! a team message, a correction under a supersede key, a steer-only send, and the prompts acpmux
//! makes itself (lane reports, task cards, a paused pair's release) still queue.
//!
//! The agent hears of its inbox as ONE notice (provenance `inbox_notice`), one line per thread
//! with new messages (how many, from whom, the newest one's first line), blockers first, the way
//! Claude Code tells it of background work; it reads a thread whole with the `inbox_read` tool
//! (`_acpmux/inbox_thread`), which marks it read, and answers with `inbox_reply`
//! (`_acpmux/inbox_reply`), which lands in the sender's inbox under the same thread. One notice
//! is in flight at a time ([`Inbox::in_flight`]):
//!
//! - into a running turn that steers, is under its cap (`turn_cap.rs`), and has none of the
//!   person's prompts waiting behind it: as a steer, which Claude Code reads at its next tool
//!   step; what comes meanwhile goes in the next one, so a turn takes at most one per step. A
//!   prompt that waits is never held up by notices: the notice goes into its turn instead;
//! - into the next turn that starts, as a steer at its start;
//! - an idle chat: as ONE turn of its own, [`WAKE_DEBOUNCE_MS`] after the oldest message that
//!   may wake it came (a burst is one turn), or [`FLUSH_MS`] after the oldest of any, so none is
//!   stranded. A message that may wake it: a blocker (a block or a question,
//!   `prompt_class.rs`), a report of work it gave (a lane's report, a task's result), or an
//!   action (a result, the default) from the session that started it
//!   (its lineage parent) or the one that first gave it work (`SessionMeta::delegator`: the
//!   sender of the first message to a chat that never ran a turn, which wakes it too). An FYI
//!   never wakes a chat; it goes with the next notice.
//!
//! An agent's `session/prompt` waits for the notice that carries it and answers with that
//! notice's answer: a steer's (`steered`, naming the turn it went into) or its own turn's. A
//! notice that does not go in (the turn ended, a Stop, a refusal) leaves its messages new, so
//! none is lost; a refused one is tried again no sooner than [`REFUSED_RETRY_MS`]. A restart
//! keeps the inbox (its records), and what was new is noticed again.
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
/// How long after the oldest waking message an idle chat is woken: a burst is one turn.
pub const WAKE_DEBOUNCE_MS: u64 = 2_000;
/// A notice the chat refused is tried again no sooner than this.
pub const REFUSED_RETRY_MS: u64 = 30_000;
/// How long a message that wakes no one waits in an idle chat before a notice brings it anyway.
pub const FLUSH_MS: u64 = 10 * 60 * 1000;
/// A notice line shows this much of the newest message's first line, in characters.
const PREVIEW_CHARS: usize = 120;
/// Messages a chat keeps in memory; the oldest read ones go first (the log keeps them all).
const KEEP: usize = 500;
/// The client a notice goes under.
const CLIENT: &str = "acpmux";

/// One message in the inbox.
pub(super) struct Item {
    pub(super) prompt_id: String,
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
    /// A notice told the agent of it (or carries it now).
    pub(super) noticed: bool,
    /// The agent read it (`inbox_thread` with `markRead`).
    pub(super) read: bool,
    /// The waiting `session/prompt` that sent it, answered by its notice.
    answer: Option<tokio::sync::watch::Sender<Option<super::queue::Answer>>>,
}

/// A session's inbox (`Session::inbox`).
#[derive(Default)]
pub struct Inbox {
    pub(super) items: Vec<Item>,
    /// The notice in flight: its prompt id and the messages it carries.
    pub(super) in_flight: Option<(String, Vec<String>)>,
    /// The idle chat's wake timer.
    pub(super) timer: Option<tokio::task::AbortHandle>,
    /// Unix ms the chat last refused a notice; 0 since one went in.
    pub(super) refused_at: u64,
}

/// What [`Hub::inbox_unsend`] did with an inbox item.
pub(super) enum Unsend {
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
pub(crate) fn plain_send(from_peer: bool, team: bool, supersede: bool, steer_only: bool) -> bool {
    !from_peer && !team && !supersede && !steer_only
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
    for (marker, skip) in [("#", 1), ("pull/", 5)] {
        for (i, _) in line.match_indices(marker) {
            if let Some(n) = digits(&line[i + skip..])
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

/// The session a message came from, when its provenance names one (not a sender that only
/// named itself).
fn sender_session(provenance: Option<&Value>) -> Option<String> {
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
/// then the thread with the newest message first.
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
    let n = threads.len();
    let mut text = format!(
        "[inbox] New messages from other agents in {n} thread{}. They need no turn of your own: \
         read a thread whole with the inbox_read tool (its thread id), answer in it with \
         inbox_reply, or leave it for later.",
        if n == 1 { "" } else { "s" }
    );
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
        let line = last.map(|i| preview(&i.text)).unwrap_or_default();
        text.push_str(&format!(
            "\n- {tag}{} new in {} from {}: {line} (thread {key})",
            list.len(),
            label(key),
            from.join(", ")
        ));
        let ids: Vec<&str> = list.iter().map(|i| i.prompt_id.as_str()).collect();
        parts.push(json!({"threadId": key, "new": list.len(), "from": from, "promptIds": ids}));
    }
    (text, json!(parts))
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

/// Whether the session's running turn is past its cap.
fn capped(meta: &SessionMeta, started_at: u64, now: u64) -> bool {
    super::turn_cap::turn_cap_ms(meta).is_some_and(|cap| now.saturating_sub(started_at) >= cap)
}

/// What the inbox does now.
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
        blocks: &[Value],
        control: Control,
        send_now: bool,
        class: Option<PromptClass>,
        provenance: Option<&Value>,
        agent: Option<&str>,
        plain: bool,
    ) -> Option<(String, PromptClass)> {
        if !plain || !plain_kind(provenance) {
            return None;
        }
        let agent = super::digest::agent_sender(provenance, agent)?;
        if !takes(true, send_now, control, blocks, provenance) {
            return None;
        }
        let class = crate::prompt_class::of_message(class, true).unwrap_or(PromptClass::Result);
        Some((agent, class))
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
        let fresh = {
            let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            match inbox.items.iter_mut().find(|i| i.prompt_id == prompt_id) {
                // A resend of one it holds: answered with it.
                Some(item) if !item.noticed || item.answer.is_some() => {
                    rx = item.answer.get_or_insert_with(|| tx.clone()).subscribe();
                    false
                }
                Some(_) => {
                    let done = json!({"stopReason": "end_turn", "_meta": {"acpmux": {"promptId": prompt_id, "inbox": true, "threadId": thread}}});
                    tx.send_replace(Some(Ok(done)));
                    false
                }
                None => {
                    inbox.items.push(Item {
                        prompt_id: prompt_id.to_owned(),
                        thread: thread.clone(),
                        from: sender.to_owned(),
                        from_session: sender_session(provenance),
                        class,
                        report: is_report(provenance),
                        at: now_ms(),
                        text: text.clone(),
                        noticed: false,
                        read: false,
                        answer: Some(tx),
                    });
                    trim(&mut inbox.items);
                    true
                }
            }
        };
        if fresh {
            let mut msg = json!({"promptId": prompt_id, "threadId": thread, "from": sender, "class": class, "kind": kind_of(class), "client": client, "text": text, "prompt": blocks});
            if let Some(from) = sender_session(provenance) {
                msg["fromSession"] = json!(from);
            }
            if is_report(provenance) {
                msg["report"] = json!(true);
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
        let next = {
            let inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            let new: Vec<&Item> = inbox.items.iter().filter(|i| !i.noticed).collect();
            if new.is_empty() || inbox.in_flight.is_some() || meta.status == SessionStatus::Closed {
                Next::Nothing
            } else {
                match session.turn() {
                    Some(turn) => {
                        let steers = session.steering.load(Ordering::SeqCst);
                        if steers && !capped(&meta, turn.started_at, now) && !prompt_waits(session)
                        {
                            Next::Steer
                        } else {
                            Next::Nothing
                        }
                    }
                    None => {
                        // A waking message after the debounce; anything after the flush, so no
                        // message is stranded in an idle chat.
                        let waking = new.iter().filter(|i| wakes(&meta, i)).map(|i| i.at).min();
                        let oldest = new.iter().map(|i| i.at).min().unwrap_or(now);
                        let flush = oldest.saturating_add(FLUSH_MS);
                        let due = waking
                            .map_or(flush, |at| at.saturating_add(WAKE_DEBOUNCE_MS).min(flush));
                        let retry = match inbox.refused_at {
                            0 => 0,
                            at => at.saturating_add(REFUSED_RETRY_MS),
                        };
                        let at = due.max(retry);
                        if at <= now { Next::Wake } else { Next::WakeAt(at) }
                    }
                }
            }
        };
        match next {
            Next::Nothing => self.disarm_inbox(session),
            Next::Steer => self.deliver_notice(session, true),
            Next::Wake => self.deliver_notice(session, false),
            Next::WakeAt(at) => self.arm_inbox(session, at, now),
        }
    }

    /// Sends the notice of every new message, as a steer or (`steer` false) a turn of its own,
    /// and answers their waiting `session/prompt`s with how it went in.
    fn deliver_notice(self: &Arc<Self>, session: &Arc<Session>, steer: bool) {
        self.disarm_inbox(session);
        let notice_id = format!("inbox-notice-{}", uuid::Uuid::now_v7());
        let (text, parts, ids, waiters) = {
            let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            if inbox.in_flight.is_some() {
                return;
            }
            let new: Vec<&Item> = inbox.items.iter().filter(|i| !i.noticed).collect();
            if new.is_empty() {
                return;
            }
            let (text, parts) = render(&new);
            let ids: Vec<String> = new.iter().map(|i| i.prompt_id.clone()).collect();
            let mut waiters = Vec::new();
            for item in inbox.items.iter_mut().filter(|i| !i.noticed) {
                item.noticed = true;
                if let Some(answer) = item.answer.take() {
                    waiters.push((item.prompt_id.clone(), answer));
                }
            }
            inbox.in_flight = Some((notice_id.clone(), ids.clone()));
            (text, parts, ids, waiters)
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
            let blocks = vec![json!({"type": "text", "text": text})];
            let result = Box::pin(hub.run_prompt(&s, blocks, CLIENT, steer, opts)).await;
            let went_in = match &result {
                Ok(v) => {
                    !matches!(
                        v.get("stopReason").and_then(Value::as_str),
                        Some("withdrawn") | Some("cancelled")
                    ) || !steer
                }
                Err(_) => false,
            };
            hub.notice_done(&s, &notice_id, &ids, waiters, result, went_in, steer);
        });
    }

    /// A notice ended: in, its messages are noticed (logged) and their senders answered; not in,
    /// they are new again and wait on, and a refusal holds the next try back.
    #[allow(clippy::too_many_arguments)]
    fn notice_done(
        self: &Arc<Self>,
        session: &Arc<Session>,
        notice_id: &str,
        ids: &[String],
        waiters: Vec<(String, tokio::sync::watch::Sender<Option<super::queue::Answer>>)>,
        result: super::queue::Answer,
        went_in: bool,
        steer: bool,
    ) {
        let first = {
            let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            // Its turn's start logged it already (`inbox_turn_started`).
            let first = inbox.in_flight.as_ref().is_some_and(|(id, _)| id == notice_id);
            if first {
                inbox.in_flight = None;
            }
            if went_in {
                inbox.refused_at = 0;
            } else {
                let unavailable = result.as_ref().err().is_some_and(|e| {
                    e.message.starts_with("steer.unavailable")
                        || e.message.starts_with(crate::claude_stdio::STEER_NO_TURN)
                });
                if !(steer && (unavailable || result.is_ok())) {
                    inbox.refused_at = now_ms();
                }
                for item in inbox.items.iter_mut().filter(|i| ids.contains(&i.prompt_id)) {
                    item.noticed = false;
                }
                for (id, answer) in waiters {
                    if let Some(item) = inbox.items.iter_mut().find(|i| i.prompt_id == id) {
                        item.answer = Some(answer);
                    }
                }
                drop(inbox);
                self.inbox_review(session);
                return;
            }
            first
        };
        if first {
            self.log_noticed(session, notice_id, ids);
        }
        for (_, answer) in waiters {
            answer.send_replace(Some(result.clone()));
        }
        self.inbox_review(session);
    }

    fn log_noticed(&self, session: &Session, notice_id: &str, ids: &[String]) {
        let msg = json!({"noticePromptId": notice_id, "promptIds": ids});
        self.append(session, "mux", "inbox_noticed", msg);
    }

    /// A turn started (`run_prompt_joined`): the notice that is it went in. What is new steers
    /// into it once its prompt is written (`inbox_review` there).
    pub(super) fn inbox_turn_started(self: &Arc<Self>, session: &Arc<Session>, prompt_id: &str) {
        self.disarm_inbox(session);
        let landed = {
            let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            match &inbox.in_flight {
                Some((id, ids)) if id == prompt_id => {
                    let ids = ids.clone();
                    inbox.in_flight = None;
                    inbox.refused_at = 0;
                    Some(ids)
                }
                _ => None,
            }
        };
        if let Some(ids) = landed {
            self.log_noticed(session, prompt_id, &ids);
        }
    }

    /// A turn ended (`finish_turn`, `fail_unstarted_turn`).
    pub(super) fn inbox_turn_ended(self: &Arc<Self>, session: &Arc<Session>) {
        self.inbox_review(session);
    }

    /// A closed chat's inbox: its timer stops and its waiting senders are answered.
    pub(super) fn inbox_closed(&self, session: &Session) {
        self.disarm_inbox(session);
        let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
        for item in &mut inbox.items {
            if let Some(answer) = item.answer.take() {
                answer.send_replace(Some(Err(super::queue::closing_error())));
            }
        }
    }

    /// Arms the wake timer for `at`, aborting the one before (module docs).
    fn arm_inbox(self: &Arc<Self>, session: &Arc<Session>, at: u64, now: u64) {
        let hub = Arc::downgrade(self);
        let weak: Weak<Session> = Arc::downgrade(session);
        let task = tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(at.saturating_sub(now))).await;
            let (Some(hub), Some(session)) = (hub.upgrade(), weak.upgrade()) else { return };
            hub.inbox_review(&session);
        });
        let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
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

    /// The inbox from the session's log (`restore_queue`): every message, read and noticed as
    /// the log says. Run again, it adds only what it does not hold.
    pub(super) fn restore_inbox(&self, session: &Arc<Session>) {
        let mut items: Vec<Item> = Vec::new();
        let mut noticed: std::collections::HashSet<String> = Default::default();
        let mut read: std::collections::HashSet<String> = Default::default();
        let mut removed: std::collections::HashSet<String> = Default::default();
        let kinds = ["inbox", "inbox_noticed", "inbox_read", "inbox_removed"];
        let scanned = self.store.scan_kinds(&session.id, &kinds, &mut |e: EventRecord| {
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
                        noticed: false,
                        read: false,
                        answer: None,
                    });
                }
                "inbox_noticed" => noticed.extend(ids()),
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
            if item.prompt_id.is_empty()
                || removed.contains(&item.prompt_id)
                || inbox.items.iter().any(|i| i.prompt_id == item.prompt_id)
            {
                continue;
            }
            item.noticed = noticed.contains(&item.prompt_id);
            item.read = read.contains(&item.prompt_id);
            inbox.items.push(item);
        }
        trim(&mut inbox.items);
    }

    /// `_acpmux/prompt_withdraw` of an inbox item (`withdraw.rs`): one no notice carried yet
    /// leaves the inbox, with an `inbox_removed` record (so a restart drops it too), and its
    /// sender's `session/prompt` answers withdrawn; one a notice carried stays, and the withdraw
    /// sends a notice into its thread.
    pub(super) fn inbox_unsend(&self, session: &Arc<Session>, prompt_id: &str) -> Unsend {
        let removed = {
            let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            match inbox.items.iter().position(|i| i.prompt_id == prompt_id) {
                None => return Unsend::Gone,
                Some(i) if inbox.items[i].noticed => return Unsend::Noticed,
                Some(i) => inbox.items.remove(i),
            }
        };
        let why = json!({"promptId": prompt_id, "threadId": removed.thread, "reason": "withdrawn"});
        self.append(session, "mux", "inbox_removed", why);
        if let Some(answer) = removed.answer {
            answer.send_replace(Some(Ok(super::queue::withdrawn_reply(prompt_id, ""))));
        }
        Unsend::Unsent
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
                    "text": item.text, "read": item.read,
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

/// Keeps at most [`KEEP`] messages: the oldest read and noticed ones go first.
fn trim(items: &mut Vec<Item>) {
    while items.len() > KEEP {
        match items.iter().position(|i| i.read && i.noticed && i.answer.is_none()) {
            Some(i) => {
                items.remove(i);
            }
            None => break,
        }
    }
}

#[cfg(test)]
#[path = "inbox_tests.rs"]
mod tests;
