//! Part of `Hub`; see `hub/mod.rs`. Session recap: a Claude chat the person
//! comes back to after 5+ minutes away shows a line on where it stands (Leo,
//! 2026-11-03: "lkewise with teh cli summarization thing? how do those get
//! turned on? maybe we can expose it in cmux-next too").
//!
//! Claude Code makes this recap (`away_summary`) only in its terminal UI,
//! from the terminal's focus; under `-p` it never does. So the daemon decides
//! when, the way Claude Code does:
//!
//! - The person left: no attached client shows the chat any more
//!   (`seen.rs`). A chat no person has shown since the daemon started gets
//!   no recap: an agent's or a lane's chat is never read that way. A person
//!   shows a chat by attaching to it or viewing it (`_acpmux/attach`,
//!   `_acpmux/view`), here or through a peer daemon's link; the subscription
//!   a prompt, `session/new` or a resume makes for whoever sent it (an agent
//!   driving the chat), and a link's own hidden attach, do not count.
//! - `ASK_AFTER` past the later of that and the last turn's end, while it is
//!   still not shown, idle and its Claude Code process still runs, the recap
//!   is asked for (`claude_stdio::RECAP`): Claude Code's own prompt as a
//!   transcript-free `side_question`, read from the prompt cache while it is
//!   still warm (Claude Code's 5-minute cache), so it costs a cache read
//!   instead of a fresh read of the whole conversation.
//! - An idle chat's process hibernates sooner than that (`idle.rs`, 2
//!   minutes by default): the idle reaper asks for the recap of a chat that
//!   wants one before it stops the process, and stops it after the answer.
//!   Each turn count is asked at most once, so a failed ask never keeps a
//!   process up.
//! - Only after `MIN_TURNS` turns, and `TURNS_BETWEEN` more since the last
//!   recap (Claude Code's own limits), so a short chat gets none.
//! - The person shows the chat again after `AWAY` or more: the recap is
//!   logged as a `mux` `recap` record (`{text, awayMs}`), which clients draw
//!   as a recap row. A turn since it was asked makes it stale: it is dropped.
//!
//! The recap never goes to the model as a prompt and is never in Claude
//! Code's transcript. `agents.chats.sessionRecap` (the app's chat settings
//! push, `chats/settings.rs`) turns it off; a chat's own `session-recap`
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

    /// Whether `session` may get a recap at all: it runs Claude Code through `claude_stdio` (the
    /// only harness whose recap acpmux can ask for), and its own `session-recap` choice is on, or
    /// is `default` while the app's setting is on.
    fn recap_applies(&self, session: &Session) -> bool {
        let meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        if !crate::claude_stdio::steers_by_info(meta.agent_info.as_ref()) {
            return false;
        }
        match super::model_options::current_option(&meta, crate::claude_stdio::RECAP_OPTION)
            .as_deref()
        {
            Some("on") => true,
            Some("off") => false,
            _ => self.session_recap.load(Ordering::SeqCst),
        }
    }

    /// A person shows `session`: an `_acpmux/attach` that shows it, or `_acpmux/view` `visible`
    /// (`server/view.rs`). From then on, leaving it starts an away period.
    pub(crate) fn recap_person_shows(&self, session: &Session) {
        session.away.lock().unwrap_or_else(|e| e.into_inner()).seen = true;
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
        let turns = session.meta.lock().unwrap_or_else(|e| e.into_inner()).turn_count;
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
            json!({"text": text, "awayMs": away_for.as_millis() as u64}),
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

    /// The idle reaper is about to stop the process of `session` (`idle.rs`): when it wants a
    /// recap, it is asked now instead, and true keeps the process up until it is answered.
    pub(super) fn recap_before_sleep(&self, session: &Session) -> bool {
        if self.wants_recap(session).is_none() {
            return false;
        }
        self.recap_due.lock().unwrap_or_else(|e| e.into_inner()).insert(session.id.clone(), 0);
        self.recap_wake.notify_one();
        true
    }

    /// Asks the running Claude Code process of `session` for its recap. Never starts one.
    async fn ask_recap(&self, session: &Arc<Session>, turns: u64) {
        let child = session.child.lock().await.clone();
        let Some(child) = child else { return };
        if !child.is_alive().await {
            return;
        }
        {
            let mut away = session.away.lock().unwrap_or_else(|e| e.into_inner());
            away.asking = true;
            away.asked_at_turns = Some(turns);
        }
        let answer = child.request_within(crate::claude_stdio::RECAP, json!({}), TIMEOUT).await;
        let text = match answer {
            Some(Ok(value)) => Self::side_question_text(&value).as_deref().and_then(clean),
            Some(Err(e)) => {
                tracing::debug!(session = %session.id, "recap refused: {}", e.message);
                None
            }
            None => {
                tracing::debug!(session = %session.id, "recap timed out");
                None
            }
        };
        let now_turns = session.meta.lock().unwrap_or_else(|e| e.into_inner()).turn_count;
        let mut away = session.away.lock().unwrap_or_else(|e| e.into_inner());
        away.asking = false;
        // A turn that began while it was asked makes it stale.
        if let Some(text) = text.filter(|_| now_turns == turns && away.left_at.is_some()) {
            away.ready = Some((text, turns));
        }
    }

    /// Asks for each recap when it is due, and follows turn ends.
    pub(super) fn watch_recaps(self: &Arc<Self>) {
        let mut events = self.subscribe();
        let hub = Arc::downgrade(self);
        tokio::spawn(async move {
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
        tokio::spawn(async move {
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
