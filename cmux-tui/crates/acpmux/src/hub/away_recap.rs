//! Part of `Hub`; see `hub/mod.rs`. Session recap: a chat the person comes back
//! to after 5+ minutes away shows a line on where it stands (Leo, 2026-11-03:
//! "lkewise with teh cli summarization thing? how do those get turned on? maybe
//! we can expose it in cmux-next too"; 2026-11-12: "and also a gui enableable
//! recap feature").
//!
//! Claude Code makes this recap (`away_summary`) only in its terminal UI,
//! from the terminal's focus; under `-p` it never does. So the daemon decides
//! when, the way Claude Code does:
//!
//! - The person left: no attached client shows the chat any more
//!   (`seen.rs`). A chat no person has shown since the daemon started gets
//!   no recap: an agent's or a lane's chat is never read that way. A person
//!   shows a chat by attaching to it with `visible: true` or viewing it
//!   (`_acpmux/view`), here or through a peer daemon's link, from a
//!   connection no agent may be behind (`server/view.rs` `shows_person`,
//!   #34075). An attach that says nothing about what it shows (a supervisor,
//!   a script, an agent's CLI following the chat), the subscription a prompt,
//!   `session/new` or a resume makes for whoever sent it, and a link's own
//!   hidden attach, do not count: each recap is one more model call.
//! - `ASK_AFTER` past the later of that and the last turn's end, while it is
//!   still not shown and idle, the recap is asked for:
//!   - a Claude Code chat (`claude_stdio`) whose process still runs is asked
//!     itself (`claude_stdio::RECAP`): Claude Code's own prompt as a
//!     transcript-free `side_question`, read from the prompt cache while it is
//!     still warm (Claude Code's 5-minute cache), so it costs a cache read
//!     instead of a fresh read of the whole conversation;
//!   - any other chat (Codex, OpenCode, pi, ..., or a Claude chat whose
//!     process is gone) is recapped by one headless call of its own harness's
//!     small model (`Hub::complete_own`, `crate::complete`): from its
//!     last few prompts and the final reply to each ([`recent_said`]), newest
//!     kept, the whole prompt under `complete::MAX_PROMPT_BYTES`
//!     ([`recap_prompt`]), never the whole history. A harness with no headless
//!     recipe (Gemini, an ACP adapter) gets none. No process is started or
//!     kept up for it.
//! - An idle Claude Code process hibernates sooner than that (`idle.rs`, 2
//!   minutes by default): the idle reaper asks for the recap of a chat that
//!   wants one before it stops the process, and stops it after the answer.
//!   Each turn count is asked at most once, so a failed ask never keeps a
//!   process up and is not asked again of the small model.
//! - Only after `MIN_TURNS` turns, and `TURNS_BETWEEN` more since the last
//!   recap (Claude Code's own limits), so a short chat gets none.
//! - The person shows the chat again after `AWAY` or more: the recap is
//!   logged as a `mux` `recap` record (`{text, awayMs, since}`), which clients
//!   draw with the "New since you looked" divider at `since` (`seen.rs`). A
//!   turn since it was asked makes it stale: it is dropped.
//!
//! The recap never goes to the chat's agent as a prompt and is never in its
//! transcript. `agents.chats.sessionRecap` (the app's chat settings push,
//! `chats/settings.rs`) turns it off; a Claude chat's own `session-recap`
//! option (the composer's Options, `claude_stdio::RECAP_OPTION`) overrides that.

use super::*;
use std::time::Duration;

/// How long the person is away before a recap shows (Claude Code's own 5 minutes).
pub(super) const AWAY: Duration = Duration::from_secs(5 * 60);
/// How long after the person left, or the turn ended, the recap is asked for: Claude Code's own
/// delay, inside its 5-minute prompt cache.
pub(super) const ASK_AFTER: Duration = Duration::from_secs(3 * 60);
/// Turns a chat has before its first recap (Claude Code's own 3).
pub(super) const MIN_TURNS: u64 = 3;
/// Turns between two recaps (Claude Code's own 2).
pub(super) const TURNS_BETWEEN: u64 = 2;
/// The longest a recap request waits for Claude Code.
const TIMEOUT: Duration = Duration::from_secs(60);
/// The longest recap kept (Claude Code caps its own at 400 characters).
const MAX_CHARS: usize = 400;
/// The small model's recap answer, in tokens (`complete::finish` cuts it to about that).
const MAX_TOKENS: u32 = 128;
/// What the small model is asked (`recap_prompt`): Claude Code's ask (`claude_stdio::RECAP_PROMPT`)
/// in the form its terminal recap takes ("The goal is ... Next, I'll ...").
const INSTRUCTION: &str = "The person stepped away from this chat with a coding agent and is coming back. From the recent turns below, say the overall goal and the one next step in at most two plain sentences, no markdown, like \"The goal is X. Next, Y.\" Answer with those sentences only.";
/// The most of one prompt or reply the small model reads: one long paste or report never
/// crowds out the turns before it.
const MAX_SAID_BYTES: usize = 1024;
/// An older line cut shorter than this to fit is left out instead.
const MIN_SAID_BYTES: usize = 64;
/// The record kinds the small model's recap is read from (`recent_said`).
const READ_KINDS: [&str; 3] = ["user_message", "agent_message_chunk", "turn_result"];
/// The most records, and about the most bytes, read back from the log's end for it.
const READ_RECORDS: usize = 4000;
const READ_BYTES: usize = 512 * 1024;

/// What writes a fallback recap from its prompt in place of the small model (tests).
pub type RecapWriter = Arc<dyn Fn(String) -> Option<String> + Send + Sync>;

/// One line of the conversation the small model's recap reads.
#[derive(Debug, Clone, PartialEq)]
enum Said {
    /// A prompt or a steer.
    Prompt(String),
    /// The agent's last reply text after a prompt.
    Reply(String),
}

/// A chat's away state, this daemon run only.
#[derive(Debug, Default)]
pub(crate) struct Away {
    /// A person has shown the chat since the daemon started (`recap_person_shows`).
    seen: bool,
    /// Hub clock nanos when the person stopped showing the chat; None while it is shown, or
    /// when nobody has shown it since the daemon started.
    left_at: Option<u64>,
    /// Hub clock nanos when its last turn ended.
    turn_ended_at: Option<u64>,
    /// A recap request is running.
    asking: bool,
    /// The turn count last asked about, answered or not: never asked twice.
    asked_at_turns: Option<u64>,
    /// The recap made while the person was away, and the turn count it describes.
    ready: Option<(String, u64)>,
    /// The turn count of the last recap shown.
    shown_at_turns: Option<u64>,
}

/// The saved `sessionRecap` (`chat-settings.json`), on when there is none.
pub(super) fn saved_setting() -> bool {
    crate::chats::ChatSettings::load(&crate::config::home().join("chat-settings.json"))
        .session_recap
}

/// The prompts and the last reply after each, oldest first, from a chat's records in log order
/// (folded as the transcript draws them, `crate::rows`). Hidden (superseded) replies are out.
fn recent_said(records: &[crate::store::EventRecord]) -> Vec<Said> {
    let table = crate::rows::RowTable::fold(records);
    let mut said = Vec::new();
    for row in table.rows() {
        let text = row.text.trim();
        if row.head.hidden || text.is_empty() {
            continue;
        }
        match row.head.kind {
            crate::rows::RowKind::Prompt => said.push(Said::Prompt(text.to_owned())),
            crate::rows::RowKind::Reply => match said.last_mut() {
                Some(Said::Reply(last)) => *last = text.to_owned(),
                _ => said.push(Said::Reply(text.to_owned())),
            },
            _ => {}
        }
    }
    said
}

/// Chat `id`'s recent prompts and replies: its newest `READ_KINDS` records only, at most
/// `READ_RECORDS` and about `READ_BYTES` of them, read back from the log's end.
fn read_recent(hub: &Hub, id: &str) -> Vec<Said> {
    let filter = EventFilter::parse(Some(&json!(READ_KINDS))).unwrap_or_default();
    match hub.events_page(id, 0, None, READ_RECORDS, Some(READ_BYTES), true, &filter) {
        Ok(page) => recent_said(&page.events),
        Err(e) => {
            tracing::debug!(session = %id, "recap: the log read failed: {e:#}");
            Vec::new()
        }
    }
}

/// `s` cut to at most `max` bytes from its end, on a character boundary.
fn cut_end(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut start = s.len() - max;
    while !s.is_char_boundary(start) {
        start += 1;
    }
    s.get(start..).unwrap_or("")
}

/// The small model's recap prompt: `INSTRUCTION`, then the newest of `said` that fit in
/// `max_bytes` in all, oldest first. A prompt keeps its start and a reply its end (where it says
/// what it did), each at most `MAX_SAID_BYTES`. None when not one line fits.
fn recap_prompt(said: &[Said], max_bytes: usize) -> Option<String> {
    let head = format!("{INSTRUCTION}\n\n<recent_turns>\n");
    let tail = "</recent_turns>\n";
    let mut room = max_bytes.checked_sub(head.len() + tail.len())?;
    let mut kept = Vec::new();
    for line in said.iter().rev() {
        let (label, text) = match line {
            Said::Prompt(text) => ("Person: ", text.as_str()),
            Said::Reply(text) => ("Agent: ", text.as_str()),
        };
        // The label and the blank line after it.
        let Some(left) = room.checked_sub(label.len() + 2) else { break };
        let max = left.min(MAX_SAID_BYTES);
        let whole = text.trim();
        let text = match line {
            Said::Prompt(_) => crate::complete::cut(whole, max),
            Said::Reply(_) => cut_end(whole, max),
        }
        .trim();
        // Too little left of a line cut to the room left: it and every older one stay out.
        if text.is_empty() || (text.len() < whole.len() && text.len() < MIN_SAID_BYTES) {
            break;
        }
        room -= label.len() + text.len() + 2;
        kept.push(format!("{label}{text}\n\n"));
    }
    if kept.is_empty() {
        return None;
    }
    kept.reverse();
    Some(format!("{head}{}{tail}", kept.concat()))
}

/// Trimmed and capped recap text, or None for an empty answer.
fn clean(text: &str) -> Option<String> {
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    Some(match text.char_indices().nth(MAX_CHARS) {
        Some((end, _)) => format!("{}…", text.get(..end).unwrap_or(text).trim_end()),
        None => text.to_owned(),
    })
}

impl Hub {
    /// The app's `agents.chats.sessionRecap`. Off drops every waiting recap.
    pub fn set_session_recap(&self, on: bool) {
        self.session_recap.store(on, Ordering::SeqCst);
        if !on {
            for session in self.sessions().into_iter().filter(|s| !self.recap_applies(s)) {
                self.recap_due.lock().unwrap_or_else(|e| e.into_inner()).remove(&session.id);
                session.away.lock().unwrap_or_else(|e| e.into_inner()).ready = None;
            }
        }
    }

    /// Whether `session` may get a recap at all: its own `session-recap` choice is on, or is
    /// `default` while the app's setting is on. Any harness: one with no way to make it gets none
    /// when it is asked (`ask_recap`).
    fn recap_applies(&self, session: &Session) -> bool {
        Self::recap_chat_choice(session)
            .unwrap_or_else(|| self.session_recap.load(Ordering::SeqCst))
    }

    /// The chat's own `session-recap` choice: Some(true) `on`, Some(false) `off`, None `default`.
    fn recap_chat_choice(session: &Session) -> Option<bool> {
        let meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        match super::model_options::current_option(&meta, crate::claude_stdio::RECAP_OPTION)
            .as_deref()
        {
            Some("on") => Some(true),
            Some("off") => Some(false),
            _ => None,
        }
    }

    /// A person shows `session`: an `_acpmux/attach` that shows it, or `_acpmux/view` `visible`
    /// (`server/view.rs`). From then on, leaving it starts an away period.
    pub(crate) fn recap_person_shows(&self, session: &Session) {
        session.away.lock().unwrap_or_else(|e| e.into_inner()).seen = true;
    }

    /// Whether chat `id` has a recap ready for the person's return (tests).
    #[doc(hidden)]
    pub fn recap_ready(&self, id: &str) -> bool {
        self.resolve(id)
            .is_ok_and(|s| s.away.lock().unwrap_or_else(|e| e.into_inner()).ready.is_some())
    }

    /// Whether a person has shown chat `id` since the daemon started (`recap_person_shows`).
    #[doc(hidden)]
    pub fn recap_person_seen(&self, id: &str) -> bool {
        self.resolve(id).is_ok_and(|s| s.away.lock().unwrap_or_else(|e| e.into_inner()).seen)
    }

    /// Whether some client shows `session` changed (`seen.rs`). Leaving it starts the away
    /// period; showing it again after `AWAY` logs the recap made meanwhile.
    pub(super) fn recap_visibility(&self, session: &Session) {
        let now = self.clock_now();
        let shown = self.shown(session);
        let mut away = session.away.lock().unwrap_or_else(|e| e.into_inner());
        if !shown {
            if away.seen && away.left_at.is_none() {
                away.left_at = Some(now);
                drop(away);
                self.schedule_recap(session);
            }
            return;
        }
        let Some(left_at) = away.left_at.take() else { return };
        self.recap_due.lock().unwrap_or_else(|e| e.into_inner()).remove(&session.id);
        let away_for = Duration::from_nanos(now.saturating_sub(left_at));
        if away_for < AWAY {
            return;
        }
        let (turns, since) = session.read_meta(|meta| (meta.turn_count, meta.seen_seq));
        let Some((text, at_turns)) = away.ready.take() else { return };
        if at_turns != turns || !self.recap_applies(session) {
            return;
        }
        away.shown_at_turns = Some(turns);
        drop(away);
        self.append(
            session,
            "mux",
            "recap",
            // `since`: where the person left off, so a client draws the recap with its
            // "New since you looked" divider instead of twice (`seen.rs`).
            // `chatOn`: the chat's own option is on, so a pane with the app setting off still
            // draws it (webviews rows/RecapRow.tsx), as the daemon made it under that override.
            json!({
                "text": text,
                "awayMs": away_for.as_millis() as u64,
                "since": since,
                "chatOn": Self::recap_chat_choice(session) == Some(true),
            }),
        );
    }

    /// A turn of `session` ended: a recap made before it is stale, and one is asked for
    /// `ASK_AFTER` from now if the person is away.
    fn recap_turn_ended(&self, session: &Session) {
        let mut away = session.away.lock().unwrap_or_else(|e| e.into_inner());
        away.turn_ended_at = Some(self.clock_now());
        away.ready = None;
        let left = away.left_at.is_some();
        drop(away);
        if left {
            self.schedule_recap(session);
        }
    }

    /// When the recap of `session` is asked for, if it may get one.
    fn schedule_recap(&self, session: &Session) {
        if !self.recap_applies(session) {
            return;
        }
        let due = {
            let away = session.away.lock().unwrap_or_else(|e| e.into_inner());
            let Some(left_at) = away.left_at else { return };
            left_at.max(away.turn_ended_at.unwrap_or(0)) + ASK_AFTER.as_nanos() as u64
        };
        self.recap_due.lock().unwrap_or_else(|e| e.into_inner()).insert(session.id.clone(), due);
        self.recap_wake.notify_one();
    }

    /// Whether `session` wants a recap now: still away, idle, enough turns since the last one,
    /// none made or asked for this turn.
    fn wants_recap(&self, session: &Session) -> Option<u64> {
        if !self.recap_applies(session) || self.shown(session) {
            return None;
        }
        let idle = matches!(session.status(), SessionStatus::Ready | SessionStatus::Idle)
            && session.turn().is_none()
            && session.queued() == 0;
        if !idle {
            return None;
        }
        let turns = session.meta.lock().unwrap_or_else(|e| e.into_inner()).turn_count;
        let away = session.away.lock().unwrap_or_else(|e| e.into_inner());
        let enough = match away.shown_at_turns {
            Some(last) => turns >= last + TURNS_BETWEEN,
            None => turns >= MIN_TURNS,
        };
        let asked = away.asked_at_turns == Some(turns);
        (away.left_at.is_some() && enough && !asked && !away.asking).then_some(turns)
    }

    /// Whether `session` runs Claude Code through `claude_stdio`, whose live process makes the
    /// recap itself.
    fn native_recap(session: &Session) -> bool {
        let meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        crate::claude_stdio::steers_by_info(meta.agent_info.as_ref())
    }

    /// The idle reaper is about to stop the process of `session` (`idle.rs`): when it is a
    /// Claude Code chat that wants a recap, it is asked now instead, and true keeps the process
    /// up until it is answered. Any other chat's recap needs no process.
    pub(super) fn recap_before_sleep(&self, session: &Session) -> bool {
        if !Self::native_recap(session) || self.wants_recap(session).is_none() {
            return false;
        }
        self.recap_due.lock().unwrap_or_else(|e| e.into_inner()).insert(session.id.clone(), 0);
        self.recap_wake.notify_one();
        true
    }

    /// Makes the recap of `session` at `turns`: its running Claude Code process asked, else its
    /// harness's small model (`fallback_recap`). Never starts or keeps up a process.
    async fn ask_recap(self: &Arc<Self>, session: &Arc<Session>, turns: u64) {
        let child = match Self::native_recap(session) {
            true => session.child.lock().await.clone(),
            false => None,
        };
        let child = match child {
            Some(child) if child.is_alive().await => Some(child),
            _ => None,
        };
        {
            let mut away = session.away.lock().unwrap_or_else(|e| e.into_inner());
            if away.asking {
                return;
            }
            away.asking = true;
            away.asked_at_turns = Some(turns);
        }
        let text = match child {
            Some(child) => Self::claude_recap(session, &child).await,
            None => self.fallback_recap(session).await,
        };
        let now_turns = session.meta.lock().unwrap_or_else(|e| e.into_inner()).turn_count;
        let mut away = session.away.lock().unwrap_or_else(|e| e.into_inner());
        away.asking = false;
        // A turn that began while it was asked makes it stale.
        if let Some(text) = text.filter(|_| now_turns == turns && away.left_at.is_some()) {
            away.ready = Some((text, turns));
        }
    }

    /// Claude Code's own recap, from its running process.
    async fn claude_recap(session: &Session, child: &ChildAgent) -> Option<String> {
        match child.request_within(crate::claude_stdio::RECAP, json!({}), TIMEOUT).await {
            Some(Ok(value)) => Self::side_question_text(&value).as_deref().and_then(clean),
            Some(Err(e)) => {
                tracing::debug!(session = %session.id, "recap refused: {}", e.message);
                None
            }
            None => {
                tracing::debug!(session = %session.id, "recap timed out");
                None
            }
        }
    }

    /// The recap of a chat no live Claude Code can make: one headless call of its own harness's
    /// small model on its recent turns (`recap_prompt`). None when it has nothing to read, its
    /// harness has no headless recipe, or the call fails.
    async fn fallback_recap(self: &Arc<Self>, session: &Arc<Session>) -> Option<String> {
        let said = {
            let hub = self.clone();
            let id = session.id.clone();
            tokio::task::spawn_blocking(move || read_recent(&hub, &id)).await.ok()?
        };
        let prompt = recap_prompt(&said, crate::complete::MAX_PROMPT_BYTES)?;
        let writer = self.recap_writer.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let answer = match writer {
            Some(write) => write(prompt),
            None => {
                let chat = super::complete::ChatRoute::of(session);
                match self.complete_own(&chat, prompt, MAX_TOKENS, TIMEOUT).await {
                    Ok(text) => Some(text),
                    Err(e) => {
                        tracing::debug!(session = %session.id, reason = e.reason(), "recap: no small-model answer");
                        None
                    }
                }
            }
        };
        answer.as_deref().and_then(clean)
    }

    /// Writes fallback recaps with `writer` instead of the small model (tests).
    #[doc(hidden)]
    pub fn set_recap_writer(&self, writer: Option<RecapWriter>) {
        *self.recap_writer.lock().unwrap_or_else(|e| e.into_inner()) = writer;
    }

    /// Asks for each recap when it is due, and follows turn ends.
    pub(super) fn watch_recaps(self: &Arc<Self>) {
        let mut events = self.subscribe();
        let hub = Arc::downgrade(self);
        self.scope.spawn_until_cancelled("recap-events", async move {
            loop {
                let ev = match events.recv().await {
                    Ok(ev) => ev,
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => return,
                };
                let rec = &ev.record;
                if rec.dir != "mux" || rec.kind != "turn_result" || ev.remote.is_some() {
                    continue;
                }
                let Some(hub) = hub.upgrade() else { return };
                if let Ok(session) = hub.resolve(&ev.session_id) {
                    hub.recap_turn_ended(&session);
                }
            }
        });
        let hub = Arc::downgrade(self);
        let wake = self.recap_wake.clone();
        self.scope.spawn_until_cancelled("recap-timer", async move {
            loop {
                let next = {
                    let Some(hub) = hub.upgrade() else { return };
                    let now = hub.clock_now();
                    let due: Vec<String> = {
                        let mut due = hub.recap_due.lock().unwrap_or_else(|e| e.into_inner());
                        let ready: Vec<String> = due
                            .iter()
                            .filter(|(_, at)| **at <= now)
                            .map(|(id, _)| id.clone())
                            .collect();
                        for id in &ready {
                            due.remove(id);
                        }
                        ready
                    };
                    for id in due {
                        let Ok(session) = hub.resolve(&id) else { continue };
                        let Some(turns) = hub.wants_recap(&session) else { continue };
                        let hub = hub.clone();
                        tokio::spawn(async move { hub.ask_recap(&session, turns).await });
                    }
                    let next = hub
                        .recap_due
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .values()
                        .min()
                        .copied();
                    next.map(|at| {
                        hub.clock
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .sleep_until(Duration::from_nanos(at))
                    })
                };
                match next {
                    Some(sleep) => {
                        tokio::select! {
                            _ = sleep => {}
                            _ = wake.notified() => {}
                        }
                    }
                    None => wake.notified().await,
                }
            }
        });
    }
}

#[cfg(test)]
#[path = "away_recap_tests.rs"]
mod tests;
